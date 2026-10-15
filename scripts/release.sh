#!/bin/zsh
#
# release.sh — build, sign, package and notarize an Amphora release.
#
# Produces in dist/:
#   Amphora-<version>.pkg            app → /Applications, CLI → /usr/local/bin/amphora
#   Amphora-<version>.pkg.sha256
#   Amphora-FullDiskAccess.mobileconfig   Jamf PPPC profile with this build's code requirement
#
# One-time setup (see docs/RELEASING.md):
#   - "Developer ID Application" and "Developer ID Installer" certificates in your login keychain
#   - xcrun notarytool store-credentials amphora --apple-id <id> --team-id <team>  (not for --no-notarize)
#
# Usage:
#   scripts/release.sh                 public release: Developer ID signed, notarized, stapled
#   scripts/release.sh --no-notarize   Developer ID signed, not notarized: for Jamf deployments only
#   scripts/release.sh --unsigned      local test package: no Developer ID, no notarization
#
# Env: TEAM_ID (detected from the certificate if unset), NOTARY_PROFILE (default amphora),
#      DEVELOPER_DIR to pick an Xcode.

set -euo pipefail

ROOT=${0:A:h:h}
BUILD="$ROOT/build"
DIST="$ROOT/dist"
BUNDLE_ID="consulting.techne.amphora"
APP_NAME="Amphora"
NOTARY_PROFILE=${NOTARY_PROFILE:-amphora}
UNSIGNED=0
NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --unsigned)    UNSIGNED=1; NOTARIZE=0 ;;
        --no-notarize) NOTARIZE=0 ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *)             print -u2 "Unknown option: $arg"; exit 2 ;;
    esac
done

step() { print -P "\n%F{blue}==>%f %B$1%b"; }

# Command Line Tools alone have no XCTest or xcodebuild: use a full Xcode if one is installed.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
    [[ -n "$XCODE" ]] && export DEVELOPER_DIR="$XCODE/Contents/Developer"
fi
fail() { print -P "%F{red}error:%f $1" >&2; exit 1; }

# ---------------- version: one source of truth, checked ----------------
VERSION=$(awk -F': ' '/MARKETING_VERSION/ {print $2; exit}' "$ROOT/App/project.yml" | tr -d '"[:space:]')
CORE_VERSION=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' "$ROOT/Sources/AmphoraCore/Models.swift")
[[ -n "$VERSION" ]] || fail "MARKETING_VERSION not found in App/project.yml"
[[ "$VERSION" == "$CORE_VERSION" ]] || fail "Version mismatch: project.yml $VERSION, Models.swift $CORE_VERSION"
grep -q "## \[$VERSION\]" "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md has no section for $VERSION"
PKG="$DIST/Amphora-$VERSION.pkg"

# ---------------- identities ----------------
if (( UNSIGNED )); then
    APP_IDENTITY="-"
    print -P "%F{yellow}Unsigned test build: not for distribution.%f"
else
    APP_IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
    INSTALLER_IDENTITY=$(security find-identity -v | sed -nE 's/.*"(Developer ID Installer: [^"]+)".*/\1/p' | head -1)
    [[ -n "$APP_IDENTITY" ]] || fail "No \"Developer ID Application\" certificate in the keychain."
    [[ -n "$INSTALLER_IDENTITY" ]] || fail "No \"Developer ID Installer\" certificate in the keychain."
    TEAM_ID=${TEAM_ID:-$(print -r -- "$APP_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')}
    [[ -n "$TEAM_ID" ]] || fail "Couldn't read the team ID from \"$APP_IDENTITY\". Set TEAM_ID."
    if (( NOTARIZE )); then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
            || fail "No notarytool credentials named \"$NOTARY_PROFILE\". See docs/RELEASING.md, or use --no-notarize for a Jamf-only build."
    else
        print -P "%F{yellow}Not notarized: fine for Jamf deployments, not for public downloads.%f"
    fi
    print "App:       $APP_IDENTITY"
    print "Installer: $INSTALLER_IDENTITY"
fi

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

# ---------------- tests ----------------
step "Running tests"
print "Xcode: ${DEVELOPER_DIR:-$(xcode-select -p)}"
if ! (cd "$ROOT" && swift test >"$BUILD/test.log" 2>&1); then
    grep -E "error|failed" "$BUILD/test.log" | head -20
    fail "Tests failed. Full output: build/test.log"
fi
grep -E "Executed [0-9]+ tests" "$BUILD/test.log" | tail -1

# ---------------- app ----------------
step "Building $APP_NAME $VERSION"
command -v xcodegen >/dev/null || fail "xcodegen not found (brew install xcodegen)"
(cd "$ROOT/App" && xcodegen -q)
xcodebuild -project "$ROOT/App/Amphora.xcodeproj" -scheme Amphora -configuration Release \
    -destination "generic/platform=macOS" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    -derivedDataPath "$BUILD/dd" CODE_SIGNING_ALLOWED=NO build -quiet
APP="$BUILD/$APP_NAME.app"
ditto "$BUILD/dd/Build/Products/Release/$APP_NAME.app" "$APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME"

# ---------------- CLI (universal) ----------------
step "Building amphora CLI"
(cd "$ROOT" && swift build -c release --arch arm64 --arch x86_64 -q)
BIN_DIR=$(cd "$ROOT" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
CLI="$BUILD/amphora"
cp "$BIN_DIR/amphora" "$CLI"
lipo -info "$CLI"

# ---------------- sign ----------------
step "Signing"
if (( UNSIGNED )); then
    codesign --force -s - "$CLI"
    codesign --force --deep -s - "$APP"
else
    codesign --force --options runtime --timestamp -s "$APP_IDENTITY" "$CLI"
    codesign --force --options runtime --timestamp -s "$APP_IDENTITY" "$APP"
    codesign --verify --strict --deep "$APP"
fi

# ---------------- package ----------------
step "Packaging"
PAYLOAD="$BUILD/payload"
mkdir -p "$PAYLOAD/Applications" "$PAYLOAD/usr/local/bin"
ditto "$APP" "$PAYLOAD/Applications/$APP_NAME.app"
cp "$CLI" "$PAYLOAD/usr/local/bin/amphora"

# Install exactly where we say: don't "upgrade" a copy the user moved elsewhere.
LOG="$BUILD/package.log"
pkgbuild --analyze --root "$PAYLOAD" "$BUILD/component.plist" >>"$LOG" 2>&1
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/component.plist"

pkgbuild --root "$PAYLOAD" --component-plist "$BUILD/component.plist" \
    --identifier "$BUNDLE_ID.pkg" --version "$VERSION" --install-location / \
    "$BUILD/component.pkg" >>"$LOG" 2>&1

if (( UNSIGNED )); then
    productbuild --package "$BUILD/component.pkg" "$PKG" >>"$LOG" 2>&1
else
    productbuild --package "$BUILD/component.pkg" --sign "$INSTALLER_IDENTITY" --timestamp "$PKG" >>"$LOG" 2>&1
fi

# ---------------- notarize ----------------
if (( NOTARIZE )); then
    step "Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
    spctl --assess --type install -v "$PKG"
fi

# ---------------- PPPC profile for Jamf ----------------
step "Generating Full Disk Access profile"
# Ad-hoc test builds print "# designated => cdhash …"; signed builds print "designated => identifier …".
REQUIREMENT=$(codesign -dr - "$APP" 2>&1 | sed -nE 's/^(# )?designated => //p')
[[ -n "$REQUIREMENT" ]] || fail "Couldn't read the app's code requirement"
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
REQ_XML=$(print -r -- "$REQUIREMENT" | xml_escape)
PROFILE="$DIST/Amphora-FullDiskAccess.mobileconfig"
cat > "$PROFILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadIdentifier</key>
            <string>$BUNDLE_ID.pppc.tcc</string>
            <key>PayloadUUID</key>
            <string>$(uuidgen)</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadDisplayName</key>
            <string>Amphora Full Disk Access</string>
            <key>Services</key>
            <dict>
                <key>SystemPolicyAllFiles</key>
                <array>
                    <dict>
                        <key>Identifier</key>
                        <string>$BUNDLE_ID</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                        <key>CodeRequirement</key>
                        <string>$REQ_XML</string>
                        <key>Allowed</key>
                        <true/>
                        <key>StaticCode</key>
                        <false/>
                        <key>Comment</key>
                        <string>Lets Amphora place restore files in Apple Configurator's cache.</string>
                    </dict>
                </array>
            </dict>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>Amphora: Full Disk Access</string>
    <key>PayloadDescription</key>
    <string>Allows Amphora to place verified IPSW files in Apple Configurator's firmware cache.</string>
    <key>PayloadIdentifier</key>
    <string>$BUNDLE_ID.pppc</string>
    <key>PayloadOrganization</key>
    <string>Amphora</string>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>$(uuidgen)</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF
plutil -lint "$PROFILE" >>"$LOG" 2>&1 || fail "Generated profile is not a valid plist"

# ---------------- checksum ----------------
(cd "$DIST" && shasum -a 256 "${PKG:t}" > "${PKG:t}.sha256")

step "Done"
ls -lh "$DIST"
(( UNSIGNED )) && print -P "\n%F{yellow}Unsigned: the PPPC profile's code requirement only matches this test build.%f"
(( ! UNSIGNED && ! NOTARIZE )) && print -P "\n%F{yellow}Not notarized: deploy with Jamf only. Downloads from the web would be blocked by Gatekeeper.%f"
(( NOTARIZE )) && print "\nNext: create GitHub release v$VERSION with the .pkg, its .sha256 and the .mobileconfig (docs/RELEASING.md)."
