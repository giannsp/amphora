# IPSW Mirror

Keeps the latest signed iOS and iPadOS restore files (IPSWs) on your service desk Mac, so restoring an iPhone or iPad never starts with a 12 GB download.

Free and open source (MIT). Built by an Apple admin, for Apple admins.

> **Status: v0.1, early.** Curated and on-demand modes work. Jamf Pro integration arrives in v0.2. See the [roadmap](#roadmap).

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
ipsw-mirror get    <model-identifier>   [--store <dir>] [--configurator]
ipsw-mirror plan   --models <id,id,...> [--store <dir>]
ipsw-mirror models [--filter <text>]
```

The default folder is `/Users/Shared/IPSW Mirror`.

## Using the app

- **Tick** the models you want kept current. They sync on launch, every 6 hours while the app is open, and on **Sync Now** (⌘R).
- **Download now** (↓ on any row) fetches one model immediately. Use it for the odd device that walks in.
- **Settings** → choose the folder, turn cleanup on or off, and optionally place IPSWs in Apple Configurator's cache.

Model identifiers are the ones Jamf Pro shows as *Model Identifier* (for example `iPhone16,1`).

## Managed settings

Settings live in the `consulting.techne.ipswmirror` preference domain, so an MDM configuration profile can set them. Values set by a profile show as locked in the app.

| Key | Type | Meaning |
| --- | --- | --- |
| `SelectedModels` | array of strings | Model identifiers to keep current |
| `StorePath` | string | Folder for IPSWs |
| `PruneOldIPSWs` | boolean | Delete IPSWs no longer needed (default `true`) |
| `ExportToConfigurator` | boolean | Also place IPSWs in Apple Configurator's cache (default `false`) |

## Apple Configurator cache (experimental)

With this setting on, verified IPSWs are also placed in Apple Configurator's firmware cache so its restores start without a download. On APFS the copy is a clone and takes no extra space. The cache location is still being verified across Configurator versions, which is why it's off by default. Reports welcome.

## Privacy and network

IPSW Mirror talks only to:

- `sofafeed.macadmins.io` (release data),
- `api.ipsw.me` (download links and checksums),
- Apple's CDN (the IPSWs themselves).

No telemetry and no accounts. Requests carry a `User-Agent` of `IPSWMirror/<version>` so the services can see who's calling.

## Roadmap

- **v0.1 — Usable without Jamf.** Curated and on-demand modes, app and CLI, verify and prune, Configurator export.
- **v0.2 — Jamf-driven.** Model list from Jamf Pro inventory through a read-only API client, Keychain storage, signed and notarized `.pkg`.
- **v0.3 — Runs on its own.** Menu bar agent with background sync, notifications, Universal Mac IPSWs for Apple Silicon.

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
