# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-15

First release. Signed with Developer ID, not yet notarized: deploy it with Jamf Pro (packages Jamf installs aren't quarantined). A notarized build will follow before public downloads are recommended.

### Added

- **Keeps restore files ready.** For every iPhone and iPad model you support, IPSW Mirror downloads the latest signed IPSW, verifies its SHA-256, and replaces it when Apple releases a new version. Interrupted downloads resume. Files no model needs are cleaned up, but only after every download succeeded.
- **Jamf Pro inventory as the model list.** A read-only API client (Read Mobile Devices only) supplies the models you own, with device counts. The secret is stored in the Keychain. If Jamf Pro is unreachable or returns no devices, the last good inventory stays in use and nothing is deleted because of it.
- **Or choose models yourself**, and download any single model on demand.
- **Older models** that current releases no longer support get the final release Apple still signs for them. Models Apple signs nothing for are listed, so the fleet adds up, and skipped.
- **Apple Configurator cache.** Verified IPSWs are placed in Configurator's firmware cache (an APFS clone, no extra space), so restores start without a download. Needs Full Disk Access: a setup window guides users through it, and each release ships a Jamf PPPC profile that grants it silently. Without it, drag a model onto a device in Configurator instead.
- **Runs in the background.** Opens at login, lives in the menu bar when the window is closed, syncs at launch when due and then every 1–24 hours (default 6), and keeps the Mac from idle sleep during downloads.
- **App:** Overview with a clear "ready to restore" status, My Devices, All Models, Downloaded (including partial downloads, with delete), Activity with a warning badge, and Settings.
- **Command-line tool** `ipsw-mirror` with `sync` (from a model list or `--from-jamf`), `get`, `plan`, `models` and `jamf`, for scripts and Jamf policies.
- **Managed settings** in the `consulting.techne.ipswmirror` domain; enforced values show as locked in the app.
- **Release tooling and docs:** `scripts/release.sh` (signed, notarized or Jamf-only builds, plus the PPPC profile), a Jamf deployment guide, and an example managed-preferences file.
