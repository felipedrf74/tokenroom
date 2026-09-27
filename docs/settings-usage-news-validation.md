# Settings, usage, Watch, and News implementation

Implemented on `codex/settings-usage-news`, starting at `56f5770`.

## Behavior

- Key tests authorize an immutable key/account revision. Editing either invalidates warnings and Save Anyway; saving captures the tested input and prevents overlapping writes.
- Alert preferences retain CloudKit change tags, use `ifServerRecordUnchanged`, and retry the original field-level delta against the latest record for at most three attempts. Failed writes leave local edits pending.
- Localized budget parsing accepts complete, finite, positive numbers. Empty clears; invalid input preserves the saved amount and shows an error.
- Settings has named provider switches, an Enabled group, provider/source search, resizable Mac windows, and Claude Advanced disclosure.
- Every provider ages independently: stale after one hour, hidden after seven days. Summaries date the oldest shown check. Watch and widget presentations include stale states and check times.
- Watch caches merge the newest reading per incoming provider while honoring removals. Confirmed sign-out empties account caches and reloads complications; phone handovers require account validation and cannot replay pre-sign-out caches. Connection errors remain visible beside retained readings, with Refresh/Retry actions.
- Ranking considers all metered windows. Exhausted secondary windows receive a short warning; iPhone tile order remains stable while visible. XXL and larger text uses one column.
- Scheduled resets show “Reset · awaiting reading”; no live zero is synthesized. Elapsed windows produce no forecast or usage alert. Widget timelines include reset, stale, and expiry boundaries.
- News has optional per-source success/failure metadata, independent retries, immediate uncached follows, conditional GETs, and existing byte limits. Parsing and transport failures are visible; partial answers preserve cached content. Manual refreshes coalesce into a follow-up pass.
- News visits survive internal navigation. Today and Retiring show section health; empty states retain Follow, Show All, and Retry. iPhone search covers titles/sources, cached model lists have Show More, and prices label input/output per million tokens. Cards/specs adapt to larger text.

## Validation

- Final Mac/shared suite: **430 tests passed**, zero failed or skipped. Result: `~/Library/Developer/Xcode/DerivedData/TokenroomImplementation/Logs/Test/Test-Tokenroom-2026.09.27_17-39-44-+0100.xcresult`. The suite covers credential revision changes, bounded concurrent preference conflicts, localized/invalid budgets, mixed reading ages, individual cache updates/removals, the Watch sign-out gate, secondary-window urgency, reset/freshness boundaries, independent feed retries, transport/parsing failures, cache migration, manual refresh coalescing, and visit continuity.
- The final iOS Simulator build, including Watch and both widget targets, passed with provider search and complication warning refinements.
- The final standalone shared typecheck passed on macOS, iOS, and watchOS (`./scripts/typecheck-shared.sh`).
- The hosted iPhone test bundle compiled successfully (`xcodebuild build-for-testing`, unsigned simulator build), including two new store regressions for persisted invalid budgets and aging while Usage stays open. All 11 hosted tests remain **unexecuted** because no usable simulator was available.

Generated sample captures are at `/tmp/tokenroom-implementation-20260927/mac`. They include light/dark usage and News, plus Settings tabs. Native sidebar/selection rendering in this offscreen harness has black selection artifacts; these captures do not validate native window interaction. The snapshot bootstrap bypasses real migrations/settings/cache and credential lookup; the iPhone snapshot fixture path is debug-only.

Hosted iPhone testing was attempted locally. The first attempt stalled during severe host load; additional QA simulator boots reported `launchd failed to respond` / `could not bind to session`. Only task-owned QA commands/simulators were targeted for stopping; no shared simulator service or other project was stopped. The single-worker retry failed before running tests: Xcode could not find an available matching simulator. Hosted execution is **not passed**.

## Remaining runtime acceptance

Until simulator or device checks complete, small iPhone / large accessibility text layouts, both Watch sizes, interactive keyboard/VoiceOver navigation, paired signed-device relay/sign-out, alerts, complications, and Live Activities remain unverified. Mac rendered captures are layout evidence, not a substitute for those checks.

Relay payload version remains 1. News metadata is optional for old caches. Preference conflict protection applies to updated writers; older releases can still overwrite changes.

No cleanup, installed-app replacement, publishing, deployment, release submission, new providers, or Watch News is part of this change.

## Reproduction commands

```sh
xcodebuild test -project Tokenroom.xcodeproj -scheme Tokenroom -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementation -jobs 2 CODE_SIGNING_ALLOWED=NO
./scripts/typecheck-shared.sh
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementationMobileBuild CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementationMobile -jobs 2 CODE_SIGNING_ALLOWED=NO
```

Logs: `/tmp/tokenroom-verified-mac-tests.log`, `/tmp/tokenroom-frozen-shared.log`, `/tmp/tokenroom-verified-apple-build.log`, `/tmp/tokenroom-verified-hosted-build.log`. Simulator attempt logs: `/tmp/tokenroom-hosted-mobile.log`, `/tmp/tokenroom-hosted-mobile-retry.log`.
