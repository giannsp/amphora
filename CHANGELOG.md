# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Jamf Pro mode: keep every iPhone and iPad model in your Jamf Pro inventory current, through a read-only API client (Read Mobile Devices). Secret in the Keychain, connection test, device counts per model, last good inventory kept when Jamf is unreachable or returns nothing, so no IPSW is ever deleted because of a Jamf problem.
- Models current releases no longer support keep the final release Apple still signs for them (for example a 2017 iPad Pro on its last iPadOS). Only models Apple signs nothing for are skipped, and they're still listed so the fleet adds up.
- CLI: `sync --from-jamf` and `jamf`, with credentials from `JAMF_URL`, `JAMF_CLIENT_ID`, `JAMF_CLIENT_SECRET` or the app's Keychain entry.
- Apple Configurator cache is on by default, checks whether macOS allows it (Full Disk Access) and says so in the Overview and Settings, with a button to the right Privacy setting.
- Setup sheet for Full Disk Access, which macOS never prompts for: opens the right Privacy setting, offers the app icon to drag into the list, and confirms by itself when access is granted.
- Drag to restore: drag a model or a downloaded file onto a device in Apple Configurator, as a fallback when Full Disk Access isn't granted. Show IPSW in Finder in each model's menu.
- Activity shows a badge when a sync logged warnings you haven't seen.
- Manual delete: a Downloaded pane listing every IPSW on disk, including unfinished (partial) downloads, (multi-select, Delete key, Show in Finder) and Delete Downloaded IPSW in each model's menu. Confirms first, names every model a shared file serves, and offers to stop keeping those models current. Deleting during a sync stops the sync first.

### Changed

- Redesigned app: sidebar with Overview, iPhone, iPad, Kept Current and Activity; a status card that says whether restores are ready; models grouped by the OS release they get; overall download progress; hover and context-menu actions.

## [0.1.0] - unreleased

### Added

- Swift engine: SOFA release data, ipsw.me firmware lookup, resumable downloads, SHA-256 verification, safe cleanup and a manifest of what is on disk.
- Curated mode: tick models to keep current; syncs on launch, every 6 hours while open and on demand.
- On-demand mode: download one model now.
- Optional export to Apple Configurator's firmware cache (experimental).
- `ipsw-mirror` command-line tool with `sync`, `get`, `plan` and `models`.
- Settings readable from a configuration profile (`consulting.techne.ipswmirror`).
