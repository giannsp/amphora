# Security policy

Amphora runs on service desk Macs with Full Disk Access and holds a Jamf Pro API secret, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue.** Report it privately through GitHub: **Security → Report a vulnerability** on this repository. That reaches the maintainer only.

Include what you found, how to reproduce it, and the Amphora and macOS versions. You'll get an answer within a week. Once a fix is released, you'll be credited in the release notes unless you prefer otherwise.

## Supported versions

Fixes go into the latest release only. Please update before reporting.

## What Amphora does, for your review

- **Network:** talks only to `sofafeed.macadmins.io`, `api.ipsw.me`, Apple's CDN (`updates.cdn-apple.com` and related hosts) and the Jamf Pro address you configure. No telemetry.
- **Jamf Pro:** uses an API client you create with only *Read Mobile Devices*. It reads model identifiers and whether each device is managed, and never writes to Jamf Pro.
- **Secrets:** the API client secret is stored in the login Keychain, never in preferences, logs or configuration profiles.
- **Files:** every IPSW is checked against its published SHA-256 before use. Amphora deletes only `.ipsw` files in its own folder, and in Apple Configurator's cache only files it placed there.
- **Permissions:** Full Disk Access is used only to write into Apple Configurator's firmware cache. Turn off "Place restore files in Apple Configurator's folder" and Amphora doesn't need it.
- **Distribution:** releases are signed with Developer ID and notarized by Apple.
