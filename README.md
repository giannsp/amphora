# IPSW Mirror

Keeps the latest signed iOS and iPadOS restore files (IPSWs) on your service desk Mac, so restoring an iPhone or iPad never starts with a 12 GB download.

Free and open source (MIT). Built by an Apple admin, for Apple admins.

> **Status: early.** Curated, on-demand and Jamf Pro modes work. See the [roadmap](#roadmap).

## What it does

1. Reads the current iOS/iPadOS releases from [SOFA](https://sofa.macadmins.io), the MacAdmins community feed.
2. Works out, for each model you care about, the latest release of the newest OS that still supports it.
3. Finds the signed IPSW for that release and downloads it. Interrupted downloads resume.
4. Verifies every file against its published SHA-256 before using it.
5. Deletes IPSWs your models no longer need, but **only after every download succeeded**, so you're never left without a usable file.

Several models usually share one IPSW, so 40 models might need only 15 files.

## What it deletes

Pick a **dedicated folder** for IPSW Mirror. During a sync it deletes any `.ipsw` file in that folder that the selected models don't need. It never touches other file types, and in Apple Configurator's cache it only removes files it placed there itself.

On-demand downloads of a model you haven't ticked are removed at the next sync.

## Install

**App:** download the latest release from [Releases](../../releases) (signed and notarized builds arrive with v0.2). Until then, build from source.

**Command line:**

```sh
swift build -c release
.build/release/ipsw-mirror models --filter "iPhone 15"
.build/release/ipsw-mirror sync --models iPhone16,1,iPhone16,2,iPad14,3 --dry-run
```

```text
ipsw-mirror sync   --models <id,id,...> [--store <dir>] [--no-prune] [--configurator] [--dry-run]
ipsw-mirror sync   --from-jamf          [--include-unmanaged] [same options as above]
ipsw-mirror jamf   [--include-unmanaged]
ipsw-mirror get    <model-identifier>   [--store <dir>] [--configurator]
ipsw-mirror plan   --models <id,id,...> [--store <dir>]
ipsw-mirror models [--filter <text>]
```

The default folder is `/Users/Shared/IPSW Mirror`.

## Using the app

- **My Devices** is your fleet: models from Jamf Pro, or the ones you tick under **All Models**. Each shows whether its restore file is ready.
- **Runs in the background.** IPSW Mirror opens at login and lives in the menu bar; closing the window keeps it syncing (every 6 hours by default, and at launch when a sync is due). Downloads keep the Mac from idle sleep until they finish. **Sync Now** (⌘R) any time.
- **Download now** (↓ on any row) fetches one model immediately. Use it for the odd device that walks in.
- **Restore:** with Full Disk Access (below), IPSWs are placed in Apple Configurator's cache and its restores start without a download. Without it, drag a model (or a file from **Downloaded**) onto the device in Configurator.
- **Downloaded** lists every IPSW on disk. Select files and press Delete to remove them; you're told which models use a file first.
- **Settings** → choose the folder, turn cleanup on or off, and see whether the Apple Configurator cache is working.

Model identifiers are the ones Jamf Pro shows as *Model Identifier* (for example `iPhone16,1`).

## Jamf Pro

Instead of ticking models by hand, let Jamf Pro decide: IPSW Mirror keeps every iPhone and iPad model in your inventory current, and drops IPSWs for models you no longer have.

1. In Jamf Pro → Settings → **API Roles and Clients**, create a role with only **Read Mobile Devices**.
2. Create an API client with that role, enable it, and generate a client secret.
3. In IPSW Mirror → Settings → Models, choose **Jamf Pro inventory**, enter the address, client ID and secret, and click **Test Connection**.

What it does and doesn't do:

- Reads model identifiers only (and whether each device is managed). No serial numbers, users or locations are stored.
- Never writes anything to Jamf Pro.
- The secret lives in your login Keychain, never in preferences or logs.
- If Jamf Pro can't be reached, or returns no devices, IPSW Mirror keeps using the last good inventory and deletes nothing because of it.
- Models no signed iOS/iPadOS release supports any more are listed in Settings and skipped.

From the command line, set `JAMF_URL`, `JAMF_CLIENT_ID` and `JAMF_CLIENT_SECRET` (or save the secret once in the app) and run `ipsw-mirror sync --from-jamf`.

## Managed settings

Settings live in the `consulting.techne.ipswmirror` preference domain, so an MDM configuration profile can set them. Values set by a profile show as locked in the app.

| Key | Type | Meaning |
| --- | --- | --- |
| `ModelSource` | string | `curated` (models ticked in the app) or `jamf` (Jamf Pro inventory) |
| `SelectedModels` | array of strings | Model identifiers to keep current in `curated` mode |
| `JamfURL` | string | Jamf Pro address, e.g. `https://yourorg.jamfcloud.com` |
| `JamfClientID` | string | API client ID. The secret is entered once in the app and kept in the Keychain |
| `JamfManagedDevicesOnly` | boolean | Count only managed devices (default `true`) |
| `StorePath` | string | Folder for IPSWs |
| `PruneOldIPSWs` | boolean | Delete IPSWs no longer needed (default `true`) |
| `ExportToConfigurator` | boolean | Place IPSWs in Apple Configurator's cache (default `true`) |
| `SyncIntervalHours` | integer | Hours between automatic syncs: 1, 3, 6, 12 or 24 (default `6`) |
| `ShowInMenuBar` | boolean | Keep running in the menu bar when the window is closed (default `true`) |

Open at login is registered on first launch. On managed Macs, a Managed Login Items payload (bundle ID `consulting.techne.ipswmirror`) keeps users from turning it off.

## Apple Configurator cache and Full Disk Access

IPSW Mirror places each verified IPSW in Apple Configurator's firmware cache:

```
~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware
```

so Configurator's restores start immediately. On APFS the copy is a clone and uses no extra space.

macOS protects that folder. IPSW Mirror needs **Full Disk Access** to write there, and macOS does not prompt for it; without it, writes simply fail. The app tells you when that happens.

- **One Mac:** System Settings → Privacy & Security → Full Disk Access → add IPSW Mirror, then reopen it.
- **Managed Macs (Jamf Pro):** deploy a Privacy Preferences Policy Control profile:

| Field | Value |
| --- | --- |
| Identifier | `consulting.techne.ipswmirror` |
| Identifier type | Bundle ID |
| Code requirement | output of `codesign -dr - "/Applications/IPSW Mirror.app"` |
| App or service | SystemPolicyAllFiles |
| Access | Allow |

The code requirement is only stable for a Developer ID-signed release, so use a released build for the profile.

Full Disk Access is a broad permission. If your security team won't grant it, turn the setting off and drag models onto devices in Configurator instead.

## Privacy and network

IPSW Mirror talks only to:

- `sofafeed.macadmins.io` (release data),
- `api.ipsw.me` (download links and checksums),
- Apple's CDN (the IPSWs themselves).

No telemetry and no accounts. Requests carry a `User-Agent` of `IPSWMirror/<version>` so the services can see who's calling.

## Roadmap

- **v0.1 — Usable without Jamf.** Curated and on-demand modes, app and CLI, verify and prune, drag to restore, manual delete.
- **v0.2 — Jamf-driven.** Model list from Jamf Pro inventory through a read-only API client, Keychain storage *(done)*; signed and notarized `.pkg`.
- **v0.3 — Runs on its own.** Menu bar, open at login, background sync *(done)*; notifications, Universal Mac IPSWs for Apple Silicon.

## Building from source

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
swift test                      # engine tests
cd App && xcodegen && open IPSWMirror.xcodeproj
```

The engine (`Sources/IPSWMirrorCore`) is a Swift package with no UI. The app (`App/`) and the CLI (`Sources/ipsw-mirror`) are thin layers on top of it.

## Credits

- [SOFA](https://sofa.macadmins.io) by the MacAdmins Open Source community, for release data.
- [ipsw.me](https://ipsw.me) for firmware links and checksums.

Please be kind to both: IPSW Mirror makes one request at a time and only syncs every few hours.

## License

MIT. See [LICENSE](LICENSE).
