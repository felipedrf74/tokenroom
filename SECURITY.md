# Security

Tokenroom is a macOS menu-bar extra with an iPhone app, widgets, and an Apple Watch app. It has no account and no server of its own: readings pass between your devices through your private iCloud.

## What to report

- Unexpected network destinations
- Token, email, or name persistence in Tokenroom storage or logs
- A way to read another user's session files
- Readings or credentials leaving your private iCloud database, or an iPhone sign-in leaving the iPhone app's Keychain group

## What not to report

- Quota numbers that look wrong because a provider API changed
- Gatekeeper warnings on an ad-hoc signed local build

## How to report

Use [GitHub Security Advisories](https://github.com/felipedrf74/tokenroom/security/advisories/new) on this repository.

Do not open a public issue with tokens, cookies, or session files.
