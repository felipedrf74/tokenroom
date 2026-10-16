# Tokenroom

AI usage for 19 providers: a macOS menu-bar app that reads each tool's login, plus an iPhone app with widgets and a Live Activity, and an Apple Watch app with complications, fed through the user's private iCloud. Formerly Headroom (renamed in 2.0; `LegacyMigration` imports Headroom 1.x settings).

Read `.grok/skills/tokenroom-macos/SKILL.md` before changing the Mac app's UI, tokens, MenuBarExtra behavior, or provider adapters, and `.grok/skills/tokenroom-apple/SKILL.md` before changing the iPhone, widgets, Watch, alerts, or the iCloud relay. Those skills are the source of truth.

Do not put personal names, emails, user IDs, or tokens in source, fixtures, logs, or the snapshot cache. Bundle ID is `app.tokenroom.mac`.

## Build

Xcode 27 is preferred. `./scripts/build.sh` falls back to `swiftc` when Xcode is not installed.

```bash
./scripts/build.sh
```

DerivedData must stay local (`~/Library/Developer/Xcode/DerivedData/Tokenroom`). Do not let Xcode put build products in the source tree.

Build settings live in `Config/*.xcconfig`, not in `project.pbxproj`. Never add `DEVELOPMENT_TEAM` or `CODE_SIGN_*` to the project file: they would override `Config/Local.xcconfig` (git-ignored; team ID and `TOKENROOM_MAC_SIGNING`). `TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh` checks the Command Line Tools fallback.

Tokenroom renews Claude, Grok Build, and Codex access tokens in each tool's own login and writes the new tokens back. It does not keep a separate copy, and it does not refresh any other provider.

## Test

```bash
xcodebuild test -project Tokenroom.xcodeproj -scheme Tokenroom -destination 'platform=macOS'
./scripts/typecheck-shared.sh
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator'
xcodebuild test -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Shared logic (relay, alerts, ranking, parsers, forecasts) is tested on the Mac in `TokenroomTests`; `TokenroomMobileTests` covers what only the iPhone app does. The iPhone build also builds the widgets, the Watch app, and its complications. A debug Mac build renders its UI from sample data with `-TokenroomSnapshots <folder>`. CI (`.github/workflows/ci.yml`), on the newest Xcode on the runner (26 or 27), typechecks `Shared`, runs the Mac tests, builds the iPhone app, compiles `TokenroomMobileTests` without running them (they need a signed host with iCloud, App Group, and Keychain entitlements, so run them locally), and builds the Command Line Tools fallback (`TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh`).

## Code Review Rules

Every reviewer follows these rules: Codex, Claude Code, Grok Build, the
advisory `Claude Review` workflow, and fresh-context review sessions. A review
reports evidence; it never approves or merges. The merge gate stays the `CI`
workflow plus the maintainer's code-owner approval.

### Important (P0/P1)

- A credential leak or misuse: tokens or keys in source, logs, the snapshot
  cache, CloudKit records, the Watch, or widgets; a Claude, Codex, or Grok
  Build token renewal that keeps a copy or writes to the wrong tool's store;
  an authorization header, cookie, or body sent across a redirect or over
  plain HTTP.
- Personal names, emails, or user IDs in source, fixtures, logs, or
  screenshots.
- One provider failure that blanks or corrupts the other providers, or a
  refresh that resends a used refresh token.
- Wrong usage numbers, forecasts, or alerts shown to the user.
- `DEVELOPMENT_TEAM` or `CODE_SIGN_*` in `project.pbxproj`, build products in
  the source tree, or a menu bar extra that overflows.
- Any change that relaxes a gate: `.github/workflows/`, test targets, or
  `scripts/build.sh` and `scripts/typecheck-shared.sh`.
- Style, naming, and refactoring suggestions are Nit at most.

### Evidence

- Cite `file:line` and a concrete failure scenario for every finding. Do not
  infer behavior from names.
- Mark a finding Pre-existing when `git blame` shows the code predates the
  change. Pre-existing findings never block the change.
- When one bug appears in several places, name the bug class and list every
  instance once.

### Do not report

- Compiler errors and test failures that CI already catches.
- Formatting, `project.pbxproj` ordering or identifier churn, and asset
  catalog JSON.

### Output

- Start with the finding count. When there is nothing to fix, say
  "No issues found."
- Order findings Important, then Nit (at most five), then Pre-existing.
- After three rounds on the same change, review only the new commits, do not
  repeat earlier findings, and say whether the approach should change.
