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

Build settings live in `Config/*.xcconfig`, not in `project.pbxproj`. Never add `DEVELOPMENT_TEAM` or `CODE_SIGN_*` to the project file: they would override `Config/Local.xcconfig` (git-ignored; team ID and `TOKENROOM_MAC_SIGNING`). `TOKENROOM_SKIP_INSTALL=1 TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh` checks the Command Line Tools fallback; without `TOKENROOM_SKIP_INSTALL=1`, `build.sh` replaces the installed `Tokenroom.app` with that ad-hoc build, which can't use iCloud.

On the Mac, Tokenroom renews Claude, Grok Build, and Codex access tokens in each tool's own login and writes the new tokens back. It does not keep a separate copy, and it does not refresh any other provider there. On the iPhone, a plan signed in to there (Claude, Codex, Grok Build, Cursor, Grok Bot) is Tokenroom's own session in the iPhone app's Keychain group, renewed by `PhoneSessionRefresher`; it is never a copy of a Mac login.

## Test

```bash
xcodebuild test -project Tokenroom.xcodeproj -scheme Tokenroom -destination 'platform=macOS'
./scripts/typecheck-shared.sh
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator'
xcodebuild test -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Shared logic (relay, alerts, ranking, parsers, forecasts) is tested on the Mac in `TokenroomTests`; `TokenroomMobileTests` covers what only the iPhone app does. The iPhone build also builds the widgets, the Watch app, and its complications. A debug Mac build renders its UI from sample data with `-TokenroomSnapshots <folder>`. CI (`.github/workflows/ci.yml`), on the newest Xcode on the runner (26 or 27), typechecks `Shared`, runs the Mac tests, builds the iPhone app, compiles `TokenroomMobileTests` without running them (they need a signed host with iCloud, App Group, and Keychain entitlements, so run them locally), and builds the Command Line Tools fallback (`TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh`).

## Code Review Rules

Every reviewer follows these rules: Codex, Claude Code, Grok Build, the advisory CI review (`.github/workflows/claude-review.yml`), and fresh-context review sessions. A review reports evidence; it never approves or merges. The merge gate stays the maintainer's code-owner approval on `main`. The `CI` workflow's `Build and test` job is expected to pass, but it is not a required check.

### Important (P0/P1)

- The menu bar extra or its popover breaks: the extra overflows, disappears, or stops updating, or the popover fails to open, clips, or loses its meters.
- One provider blanks the others: a missing, expired, or failing session or adapter for one provider empties, hides, or stalls the rest.
- The iCloud relay breaks: the iPhone, widgets, Live Activity, or Watch stop receiving readings, show stale readings as current, or read or write anything outside the user's private iCloud database.
- Keychain or data isolation breaks: a renewed Claude, Grok Build, or Codex token written to the wrong login or corrupting that tool's own login, a separate copy of a Mac login, or an iPhone session that leaves the iPhone app's Keychain group or comes from a Mac login.
- Personal names, emails, user IDs, or tokens in source, fixtures, logs, screenshots, the snapshot cache (`snapshots.json`), or pull request text.
- `DEVELOPMENT_TEAM` or `CODE_SIGN_*` in `Tokenroom.xcodeproj/project.pbxproj`, or build products in the source tree. Build settings belong in `Config/*.xcconfig`.
- Any change that relaxes a gate: `.github/workflows/ci.yml` (a removed or skipped step, `continue-on-error`, a narrower trigger), or disabled or deleted tests in `TokenroomTests` or `TokenroomMobileTests`.
- Style, naming, and refactoring suggestions are Nit at most.

### Evidence

- Cite `file:line` and a concrete failure scenario for every finding.
- Mark a finding Pre-existing when `git blame` shows the code predates the change. Pre-existing findings never block the change.
- When one bug appears in several places, name the bug class and list every instance once.

### Do not report

- What the `CI` workflow already checks, since its result shows on the pull request: compile errors in `Shared` for macOS, iOS, and watchOS, the Mac tests, the iPhone app, widgets, and Watch build, the `TokenroomMobileTests` compile, and the Command Line Tools build.
- Formatting, generated assets (`*.xcassets`, `AppIcon.icon`, `docs/images/`), and Xcode's own churn in `project.pbxproj` other than build settings.

### Output

- Start with the finding count. When there is nothing to fix, say "No issues found."
- Order findings Important, then Nit (at most five), then Pre-existing.
- After three rounds on the same change, review only the new commits, do not repeat earlier findings, and say whether the approach should change.
