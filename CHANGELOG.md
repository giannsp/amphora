# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - unreleased

### Added

- Swift engine: SOFA release data, ipsw.me firmware lookup, resumable downloads, SHA-256 verification, safe cleanup and a manifest of what is on disk.
- Curated mode: tick models to keep current; syncs on launch, every 6 hours while open and on demand.
- On-demand mode: download one model now.
- Optional export to Apple Configurator's firmware cache (experimental).
- `ipsw-mirror` command-line tool with `sync`, `get`, `plan` and `models`.
- Settings readable from a configuration profile (`consulting.techne.ipswmirror`).
