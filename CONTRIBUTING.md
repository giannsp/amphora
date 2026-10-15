# Contributing

Thanks for helping. Bug reports from real service desks are the most valuable contribution of all.

## Reporting a problem

Open an issue with the bug template. Include your macOS version, which mode you used, and the activity log lines around the problem (Show Activity in the app, or the CLI output). Remove anything identifying your organization first.

## Making a change

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Fork, branch from `main`, and keep one change per pull request.
3. Run `swift test` and build the app (`cd App && xcodegen && xcodebuild -scheme IPSWMirror build`).
4. Add a line under **Unreleased** in `CHANGELOG.md`.

## Ground rules

- The engine (`Sources/IPSWMirrorCore`) has no UI code and no third-party dependencies. Keep it that way.
- Anything that deletes files must be safe by default: dry-run first, never delete what we didn't create.
- Be polite to upstream services: one request at a time, identified User-Agent, no tighter polling.
