#!/bin/zsh
#
# ipsw-mirror.zsh
# Keeps a local mirror of the latest *signed* iOS/iPadOS restore IPSWs.
#
#   Version source : SOFA  (sofafeed.macadmins.io/v1/ios_data_feed.json)
#   Download source: ipsw.me API (SOFA's iOS feed carries no IPSW URLs)
#
#   - Each device gets the Latest version of the HIGHEST OS major SOFA lists it under.
#   - Matching is by ProductVersion, not build (per-device builds can differ from SOFA's).
#   - New files are downloaded and checksum-verified BEFORE anything is deleted.
#   - Cleanup only runs when every device resolved and downloaded cleanly.
#   - DEST_DIR must be dedicated: any *.ipsw not in the current set gets deleted.
#
# Usage: ipsw-mirror.zsh [--dry-run] [--force]
#   --dry-run  show what would be downloaded/deleted, change nothing
#   --force    ignore the "SOFA unchanged" short-circuit (e.g. after deleting files by hand)
#
# Env overrides: DEST_DIR, MODELS, MIN_FREE_GB

setopt pipe_fail no_unset

# ---------------- config ----------------
DEST_DIR="${DEST_DIR:-/Users/Shared/IPSW}"
# Space-separated model identifiers, e.g. "iPhone16,1 iPhone17,3 iPad14,3".
# Empty = every device SOFA lists (~85 identifiers, roughly 600+ GB).
MODELS="${MODELS:-}"
MIN_FREE_GB="${MIN_FREE_GB:-25}"

SOFA_URL="https://sofafeed.macadmins.io/v1/ios_data_feed.json"
IPSWME_API="https://api.ipsw.me/v4/device"
UA="ipsw-mirror/1.0 (+techne.consulting)"
STATE_DIR="$DEST_DIR/.state"
LOG_FILE="$STATE_DIR/ipsw-mirror.log"
LOCK_DIR="$STATE_DIR/lock"

# ---------------- args ----------------
DRY_RUN=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) print -u2 "Unknown option: $a"; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR" || { print -u2 "Cannot create $STATE_DIR"; exit 1; }

log() { local m="$(date '+%F %T') [$1] $2"; print -r -- "$m"; print -r -- "$m" >> "$LOG_FILE"; }
die() { log ERROR "$1"; exit 1; }

for bin in curl jq shasum df stat; do
  command -v $bin >/dev/null || die "Missing dependency: $bin (jq ships in /usr/bin on macOS 15+)"
done

# ---------------- lock ----------------
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    log INFO "Another run (pid $lock_pid) is active — exiting."; exit 0
  fi
  log WARN "Removing stale lock"
  rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" || die "Cannot acquire lock"
fi
print $$ > "$LOCK_DIR/pid"
TMP=$(mktemp -d /tmp/ipsw-mirror.XXXXXX)
trap 'rm -rf "$LOCK_DIR" "$TMP"' EXIT
trap 'exit 130' INT TERM

fetch_json() { curl -fsSL --retry 3 --retry-delay 5 --max-time 60 -A "$UA" -o "$2" "$1"; }

verify() { # path sha256 sha1
  local p=$1 want256=$2 want1=$3 got
  if [[ -n "$want256" ]]; then
    got=$(shasum -a 256 "$p" | awk '{print $1}'); [[ "$got" == "$want256" ]]
  elif [[ -n "$want1" ]]; then
    got=$(shasum -a 1 "$p" | awk '{print $1}'); [[ "$got" == "$want1" ]]
  else
    log WARN "${p:t}: no checksum published — size check only"; return 0
  fi
}

(( DRY_RUN )) && log INFO "=== DRY RUN ==="

# ---------------- 1. SOFA ----------------
fetch_json "$SOFA_URL" "$TMP/sofa.json" || die "SOFA fetch failed"
jq -e '.OSVersions | length > 0' "$TMP/sofa.json" >/dev/null || die "SOFA feed malformed"

HASH=$(jq -r '.UpdateHash // empty' "$TMP/sofa.json")
if (( ! FORCE )) && [[ -n "$HASH" && "$HASH" == "$(cat "$STATE_DIR/last_hash" 2>/dev/null)" ]]; then
  log INFO "SOFA unchanged ($HASH), last run clean — nothing to do."
  exit 0
fi

# device -> latest version of the highest major that supports it
typeset -A target_ver
while IFS=$'\t' read -r dev ver; do
  target_ver[$dev]=$ver
done < <(jq -r '
  [ .OSVersions[] | { major: (.OSVersion | tonumber), ver: .Latest.ProductVersion, devs: (.Latest.SupportedDevices // []) } ]
  | sort_by(.major) | reverse
  | reduce .[] as $o ({}; reduce $o.devs[] as $d (.; if has($d) then . else .[$d] = $o.ver end))
  | to_entries[] | "\(.key)\t\(.value)"' "$TMP/sofa.json")

if [[ -n "$MODELS" ]]; then
  typeset -A filtered
  for m in ${=MODELS}; do
    if [[ -n "${target_ver[$m]:-}" ]]; then
      filtered[$m]=${target_ver[$m]}
    else
      log WARN "$m not in SOFA (unsupported or typo) — skipped"
    fi
  done
  target_ver=("${(@kv)filtered}")
fi
(( ${#target_ver} )) || die "No devices to process"
log INFO "Devices in scope: ${#target_ver}"

# ---------------- 2. resolve IPSWs via ipsw.me ----------------
typeset -A f_url f_sha256 f_sha1 f_size f_ver f_devs
FAILURES=0

for dev in ${(ko)target_ver}; do
  ver=${target_ver[$dev]}
  if ! fetch_json "$IPSWME_API/$dev?type=ipsw" "$TMP/dev.json"; then
    log WARN "$dev: ipsw.me lookup failed"; FAILURES=$((FAILURES + 1)); continue
  fi
  line=$(jq -r --arg v "$ver" '
    [ .firmwares[] | select(.version == $v and .signed == true) ] | .[0] // empty
    | [ .url, (.sha256sum // ""), (.sha1sum // ""), (.filesize | tostring) ] | @tsv' "$TMP/dev.json")
  if [[ -z "$line" ]]; then
    log WARN "$dev: no signed IPSW for $ver on ipsw.me yet"; FAILURES=$((FAILURES + 1)); continue
  fi
  IFS=$'\t' read -r url sha256 sha1 size <<< "$line"
  file=${url:t}
  f_url[$file]=$url; f_sha256[$file]=$sha256; f_sha1[$file]=$sha1; f_size[$file]=$size; f_ver[$file]=$ver
  f_devs[$file]="${f_devs[$file]:-}${f_devs[$file]:+ }$dev"
  sleep 0.5
done

log INFO "Unique IPSWs required: ${#f_url}"

# ---------------- 3. space check ----------------
need_kb=0
for file in ${(k)f_url}; do
  [[ -f "$DEST_DIR/$file" ]] && continue
  sz=${f_size[$file]}; have=0
  [[ -f "$DEST_DIR/$file.part" ]] && have=$(stat -f %z "$DEST_DIR/$file.part")
  need_kb=$(( need_kb + (sz - have) / 1024 ))
done
free_kb=$(df -Pk "$DEST_DIR" | awk 'NR==2{print $4}')
reserve_kb=$(( MIN_FREE_GB * 1024 * 1024 ))
log INFO "Need $(( need_kb / 1048576 )) GB, free $(( free_kb / 1048576 )) GB (reserve ${MIN_FREE_GB} GB)"
if (( need_kb + reserve_kb > free_kb )) && (( ! DRY_RUN )); then
  die "Not enough space. Narrow MODELS, free space, or point DEST_DIR at a bigger volume."
fi

# ---------------- 4. download ----------------
for file in ${(ko)f_url}; do
  dst="$DEST_DIR/$file"; part="$dst.part"; want=${f_size[$file]}

  if [[ -f "$dst" ]]; then
    if [[ "$(stat -f %z "$dst")" == "$want" ]]; then
      log INFO "OK   $file"; continue
    fi
    log WARN "$file size mismatch — re-downloading"
    (( DRY_RUN )) || rm -f "$dst"
  fi

  log INFO "GET  $file ($(( want / 1073741824 )) GB, ${f_ver[$file]}) for: ${f_devs[$file]}"
  (( DRY_RUN )) && continue

  if [[ ! -f "$part" || "$(stat -f %z "$part")" != "$want" ]]; then
    if ! curl -fL --silent --show-error --retry 5 --retry-delay 30 --retry-all-errors \
              -C - -A "$UA" -o "$part" "${f_url[$file]}"; then
      log ERROR "$file: download failed (partial kept for resume)"
      FAILURES=$((FAILURES + 1)); continue
    fi
  fi

  psize=$(stat -f %z "$part")
  if [[ "$psize" != "$want" ]]; then
    log ERROR "$file: size $psize != expected $want — discarded"
    rm -f "$part"; FAILURES=$((FAILURES + 1)); continue
  fi

  if verify "$part" "${f_sha256[$file]}" "${f_sha1[$file]}"; then
    mv -f "$part" "$dst" && log INFO "DONE $file"
  else
    log ERROR "$file: checksum mismatch — discarded"
    rm -f "$part"; FAILURES=$((FAILURES + 1))
  fi
done

# ---------------- 5. cleanup (only on a fully clean run) ----------------
if (( FAILURES )); then
  log WARN "$FAILURES problem(s) — skipping cleanup so no usable IPSW is removed. Will retry next run."
else
  for f in "$DEST_DIR"/*.ipsw(N) "$DEST_DIR"/*.ipsw.part(N); do
    base=${f:t}; base=${base%.part}
    [[ -n "${f_url[$base]:-}" ]] && continue
    if (( DRY_RUN )); then
      log INFO "DEL  ${f:t} (dry-run)"
    else
      rm -f "$f" && log INFO "DEL  ${f:t}"
    fi
  done
fi

# ---------------- 6. manifest + state ----------------
if (( ! DRY_RUN )); then
  for file in ${(ko)f_url}; do
    [[ -f "$DEST_DIR/$file" ]] || continue
    print -r -- "$file"$'\t'"${f_ver[$file]}"$'\t'"${f_devs[$file]}"
  done | jq -R -s --arg hash "$HASH" --arg date "$(date -u +%FT%TZ)" '{
      generated: $date,
      sofa_hash: $hash,
      files: [ split("\n")[] | select(length > 0) | split("\t")
               | { file: .[0], version: .[1], devices: (.[2] | split(" ")) } ]
    }' > "$STATE_DIR/manifest.json"

  (( FAILURES )) || print -r -- "$HASH" > "$STATE_DIR/last_hash"
fi

log INFO "Finished — failures: $FAILURES"
(( FAILURES == 0 ))
