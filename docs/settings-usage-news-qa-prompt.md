# Independent QA: Tokenroom Settings, usage, and News

This is the independent source-review prompt for the pre-release working tree at committed head `4b47cf4`. A later user request authorized Git and App Store publication and updating the Mac installation. Its SHA, file inventory, and authorization notes below describe the earlier QA snapshot, not the later release state. Independently review that snapshot against base `56f57708aa797ef4004a4ef3483a693b5a5739ca`, including its then-uncommitted edits and this document. Treat the implementation summary as claims to verify against source, not proof of correctness.

**Authorization at the time of this source review:** Do not commit or run tests unless the user separately and explicitly authorizes them. This includes test suites, hosted execution, interactive app QA, simulator/device exercises, and acceptance captures. Read-only source review is permitted. Compiler checks are distinct from test execution, but the reviewed tree already had successful compilation evidence below. This review did not install/replace the app, alter provider sessions, publish, merge, release, or delete generated folders. Report blocked checks instead of treating them as passes. The later publication request changed release authorization; it did not authorize executing tests.

## Original goal and scope

Implement the user's plan, “Tokenroom: fix and refine Settings, usage, and News,” across Mac, iPhone, widgets, Watch, and complications. Improve correctness, reading freshness, key validation, cross-device consistency, failure recovery, accessibility, discovery, and readability while preserving the local-first architecture, read-only provider sessions, native platform styling, colors/icons, shared serif/SF News typography, relay payload compatibility, and usage-focused Watch app.

The delivery plan has three reviewable stages: Settings correctness → usage/Watch reliability → News recovery/polish. Existing commits are `0990ed7`, `392c729`, and `4b47cf4`. Two independent review rounds added uncommitted fixes; reviewing only HEAD omits them. Cleanup, new providers, Watch News, deployment, and release submission are outside scope.

## Implemented behavior to verify against the plan

1. **Key validation:** Mac/iPhone test an immutable key/account attempt. Any input revision invalidates warnings and Save Anyway, including changing away and back. Superseded answers cannot save; saves capture tested credentials and block overlap. Both save actions disable without required admin acknowledgement; it is also rechecked; leaving the editor invalidates validation.
2. **Preferences:** Reuse the fetched CloudKit record/change tag, save with `.ifServerRecordUnchanged`, and retry the original field-level delta against the newest record for at most three total attempts. Top-level and partial-failure record conflicts are recognized. Exhausted conflicts leave local edits pending. Edits during asynchronous synchronization survive.
3. **Budgets:** Locale-aware, full-string parsing, including native decimal digits. Empty explicitly clears; finite positive amounts save; invalid/zero/negative/nonfinite input preserves the prior budget and shows an inline error. Both persistence setters reject invalid numeric values.
4. **Settings refinements:** Named provider toggles with connection status accessibility values, Enabled grouping, resizable Mac Settings, provider/lab/source search, Claude Advanced disclosure, native grouped forms.
5. **Freshness:** Age each provider using its own successful-check time, with fetched/envelope fallback for older payloads. Older than one hour becomes stale; older than seven days disappears. Summaries include stale counts and the oldest shown check; provider details show their last successful check. Apply to iPhone, Watch, widgets, complications.
6. **Watch recovery:** The newest envelope controls membership/removals; older handovers can still advance newer checks for retained providers. A delayed cache cannot undo removals. Connection failure remains visible beside retained readings. Confirmed iCloud sign-out clears account caches/reloads complications. Phone caches require account revalidation and cannot restore pre-sign-out data. A still-running Watch process also adopts a newly validated complication cache when resuming or when its own iCloud read fails, while retaining the failure banner and keeping phone handovers gated until its own successful read. A persistent validation gate and cutoff protect Watch initialization and every complication snapshot/timeline/relevance disk read; failed cache writes cannot reopen it. Account changes also invalidate old cached data and in-flight outcomes before revalidation. Retry/Refresh is visible.
7. **Urgency:** Rank by the most urgent active metered window, using that window's percentage for ties and its own history. Preserve primary headlines. Explain an exhausted secondary window with a short warning on Mac cards/compact rows, Watch rows, and automatic widget summaries. iPhone tiles remain stable while visible.
8. **Resets/readability:** Preserve measured data without synthesizing a live zero. An elapsed window shows a dash and Reset / “Reset · awaiting reading” until replaced. Suppress that window's pace, forecasts, and alerts. Live Activities retain measured data with optional awaitingReading state, including ended activities and every Lock Screen/Dynamic Island/supplemental Watch presentation. Missing/expired pinned providers show their own named empty state. The Mac clock re-arms at reset/stale boundaries independently of polling and feeds cards, forecasts, ranking, and menu meters. Reset Soon uses a single render-time date and best-effort Watch background scheduling/reload when a reset passes; WidgetKit may defer it. Include reset/stale/expiry timeline boundaries; pass clock dates through Watch/iPhone rows and details. Use one iPhone column at XXL and above. Dim pending Mac card/menu meters; menu-bar Highest prefers a current meter but falls back to the first when all are pending/placeholders; that fallback still shows a dash/placeholder.
9. **News recovery:** Optional per-source success/failure metadata; independent retry scheduling; one-hour failure cooldown; immediate newly followed uncached sources, including re-follows after a failed uncached request. Preserve conditional GETs and download limits. Transport/parsing/truncation failures affect health while retaining usable cache. Manual requests during refresh coalesce into one follow-up; queued source IDs union without losing manual maxAge or notification intent; latest preferences determine notification eligibility. The store-owned unstructured refresh task drains queued work even if the originating News page task is cancelled.
10. **News health/empty states:** Today and Retiring explain their own freshness/failures. Distinguish nothing followed, no matches, no upcoming retirements, and failed loading. Follow, Show All, Retry remain reachable. Today uses the visible edition, so a retirement beyond 30 days does not suppress an otherwise empty page.
11. **Visits:** Begin/end visits at iPhone tab entry/exit and Mac News window opening/closing. Opening clears the badge while retaining New markers for the visit; Follow/internal navigation does not replace the baseline.
12. **Discovery/model clarity:** iPhone local title/source search; Show More beyond cached-model page sizes of 50/60; prices explicitly identify input/output per million tokens; narrow cards/specification grids adapt to larger text.

See `docs/settings-usage-news-validation.md` for the complete plan-to-implementation disposition table, evidence, and blocked acceptance criteria. Independently confirm its coverage rather than assuming that every “source complete” row is correct.

## Files changed

Full inventory relative to the repository root, including the three earlier stages and the uncommitted completion fixes/documentation:

```text
.grok/skills/tokenroom-apple/SKILL.md
.grok/skills/tokenroom-macos/SKILL.md
Shared/APIKeys/KeyValidationRevision.swift
Shared/Core/Alerts.swift
Shared/Core/BudgetInput.swift
Shared/Core/Forecast.swift
Shared/Core/NewsEdition.swift
Shared/Core/NewsFeed.swift
Shared/Core/NewsPresentation.swift
Shared/Core/NewsStore.swift
Shared/Core/ReadingAssembler.swift
Shared/Core/ReadingCache.swift
Shared/Core/ReadingFreshness.swift
Shared/Core/ReadingText.swift
Shared/Core/RelayMerge.swift
Shared/Core/SampleData.swift
Shared/Core/UsageRanking.swift
Shared/Core/UsageTiles.swift
Shared/Relay/CloudRelay.swift
Shared/Relay/RelayReadings.swift
Shared/UI/NewsEditionViews.swift
Shared/Widgets/ReadingsEntry.swift
Shared/Widgets/SessionActivity.swift
Shared/Widgets/SessionActivityViews.swift
Shared/Widgets/UsageWidgetView.swift
Shared/Widgets/WidgetRefresher.swift
Tokenroom/App/AppDelegate.swift
Tokenroom/Domain/Provider+Mac.swift
Tokenroom/Refresh/AppSettings.swift
Tokenroom/Refresh/QuotaStore.swift
Tokenroom/Refresh/RelayPublisher.swift
Tokenroom/Views/MenuBarLabel.swift
Tokenroom/Views/NewsWindowView.swift
Tokenroom/Views/PopoverView.swift
Tokenroom/Views/ProviderCard.swift
Tokenroom/Views/SettingsView.swift
TokenroomMobile/MobileAppDelegate.swift
TokenroomMobile/MobileSettingsView.swift
TokenroomMobile/MobileStore.swift
TokenroomMobile/NewsView.swift
TokenroomMobile/ProviderDetailView.swift
TokenroomMobile/RootView.swift
TokenroomMobile/UsageTileView.swift
TokenroomMobile/UsageView.swift
TokenroomMobileTests/MobileStoreTests.swift
TokenroomTests/APIKeyTests.swift
TokenroomTests/AlertTests.swift
TokenroomTests/FeedTests.swift
TokenroomTests/GoldenFixtureTests.swift
TokenroomTests/MobileLogicTests.swift
TokenroomTests/NewsEditionTests.swift
TokenroomTests/ReadingReliabilityTests.swift
TokenroomTests/SettingsCorrectnessTests.swift
TokenroomWatch/TokenroomWatchApp.swift
TokenroomWatch/WatchStore.swift
TokenroomWatch/WatchViews.swift
TokenroomWatchWidgets/TokenroomWatchWidgets.swift
TokenroomWidgets/SessionActivityWidget.swift
TokenroomWidgets/TokenroomWidgets.swift
docs/settings-usage-news-qa-prompt.md
docs/settings-usage-news-validation.md
```

## Expected user-visible examples

- Editing key/account while a check is pending leaves the new input untested; the earlier result cannot save it or enable Save Anyway. Invalid budget text does not delete a saved amount.
- Two devices changing different alert fields preserve both changes after a conflict retry; persistent conflicts leave edits queued locally.
- A fresh reading alongside a two-hour-old reading yields one live and one stale provider, with a truthful aggregate time. An eight-day-old provider is absent.
- A healthy weekly headline beside an exhausted 5-hour session retains the weekly value but ranks urgently and says “5-hour limit reached.” Two equally urgent sessions rank by their own percentages, not unrelated weekly percentages.
- Passing a reset boundary without new data displays an awaiting-reading state and suppresses forecasts/alerts for that window. An exhausted *other* window can still warn while the primary awaits its reset reading.
- Watch shows an iCloud connection error alongside retained readings and lets the user retry; confirmed sign-out clears those readings and complications, and delayed pre-sign-out phone data cannot restore them. If a complication validates and saves a reading while the Watch app remains alive, resume or a failed app read adopts that file and shows it beside the error.
- A Claude-pinned widget with only Cursor available shows Claude’s no-recent-reading state and opens Claude; automatic selection still shows Cursor.
- A Live Activity measured at 96% shows a dash and awaiting-reading caption after reset, while retaining its measured 96 internally; no stale threshold or pace alert is emitted.
- Mac cards/menu/Highest and stale labels change at their presentation boundaries even if provider polling is ten minutes away.
- A cancelled News page refresh does not drop a queued manual/follow pass. A successful News feed does not postpone a failed feed or an uncached follow. A failed uncached re-follow retries selectively; many manual refreshes during a pass result in one follow-up pass.
- Returning from Follow keeps New markers for the same visit. Empty News sections explain the reason and retain actions. Every cached model remains reachable via Show More.

## Checks already performed — keep snapshots distinct

**First-review findings to verify independently:** The supplied review's findings 1–7 have source fixes described in the validation record: delayed handover checks, Mac boundary clock, Live Activity resets, pinned-provider absence, durable Watch account gate, pending iPhone label, and queued notification intent. Also inspect both admin-key save buttons and partial-failure CloudKit conflict recognition. This is a request for re-review, not approval or runtime acceptance.

**First-review compiler checks — passed before the second-review source edits:**

- Shared macOS/iOS/watchOS typechecks: `/tmp/tokenroom-review-fixes-shared-final.log`.
- Unsigned Mac app build: `/tmp/tokenroom-review-fixes-mac-final.log`.
- Unsigned generic iOS Simulator build, including Watch and both widget targets: `/tmp/tokenroom-review-fixes-apple-final.log`. The final incremental build compiled the last Watch account-fence guard for arm64 and x86_64.
- No compiler errors/warnings in successful logs. `git diff --check 56f5770` is clean; the inventory below matches all 61 changed/new files.

Initial shared compilation was invalidated by a file changing during compilation; the final check was restarted after those edits stopped. No tests, test-target compilation, runtime/device QA, simulator boot, signing/install, or new commits accompanied these checks. Keep these results separate from historical logs and do not infer runtime acceptance.

**Second independent review findings:** Recheck the living Watch process after complication validation, including a throttled resume and a failed in-flight iCloud read; cancellation of the original News page task while manual/follow requests are queued; and Reset Soon rendering after a reset. The Reset Soon widget uses a relevance provider without a timeline callback, so exact WidgetKit redraw timing remains open for device QA. Inspect the source fixes and regression methods independently; do not infer runtime proof from compiler success.

**Current second-review checks — all compiler-only, all passed:**

- Shared macOS/iOS/watchOS typechecks: `/tmp/tokenroom-qa2-shared.log`.
- Unsigned Mac app build: `/tmp/tokenroom-qa2-mac.log`.
- Unsigned generic iOS Simulator build, including Watch and both widget targets: `/tmp/tokenroom-qa2-apple.log`.
- Mac/shared test-target compilation without execution: `/tmp/tokenroom-qa2-mac-tests-build.log` (`TEST BUILD SUCCEEDED`).
- Hosted iPhone test-target compilation without execution: `/tmp/tokenroom-qa2-apple-tests-build.log` (`TEST BUILD SUCCEEDED`).

The successful logs contain no compiler errors/warnings. **No tests ran.** No app or test host was launched; no simulator was booted. `git diff --check 56f5770` is clean. The earlier review-fix logs below predate these source edits.

**Earlier completion tree, before independent-review fixes:**

- Shared typechecks passed macOS/iOS/watchOS: `/tmp/tokenroom-completion-shared.log`.
- Unsigned Mac app build passed: `/tmp/tokenroom-completion-mac-build.log`.
- Unsigned generic iOS Simulator build passed, including Watch and both widget targets: `/tmp/tokenroom-completion-apple-build.log`; final incremental build also passed: `/tmp/tokenroom-completion-apple-build-final.log`.
- Successful build logs contain no compiler errors/warnings. The initial ranking type-inference failure was fixed before successful checks.
- Source/diff/call-site review and `git diff --check` completed. No tests, test-host launch, simulator boot, interactive QA, installed-app replacement, or new commits in this completion pass.

**Earlier implementation, before the current uncommitted fixes:**

- 430 Mac/shared tests passed, zero failed/skipped. Result: `~/Library/Developer/Xcode/DerivedData/TokenroomImplementation/Logs/Test/Test-Tokenroom-2026.09.27_17-39-44-+0100.xcresult`; summary `/tmp/tokenroom-implementation-20260927/mac-test-summary.json`.
- Shared typechecks and iOS/Watch/widget build passed; hosted iPhone test bundle compiled. All 11 hosted tests then remained unexecuted after historical simulator failures; the current 13-method bundle is compiled but still unexecuted. Do not infer current simulator availability from those failures.
- Sample Mac light/dark usage/News/Settings renders at `/tmp/tokenroom-implementation-20260927/mac`. Black sidebar/selection artifacts limit offscreen rendering evidence; these are not interactive native-window acceptance.

The uncommitted diff adds 20 regression methods relative to HEAD: 18 Mac/shared and two hosted iPhone methods. All remain unexecuted. Both current test targets compile, but no test runner executed them. Coverage includes delayed handover membership, failed cache writes/restart/account changes, the production complication outcome path, living Watch cache adoption, reset scheduling boundaries, cancelled News owner tasks, Mac clock reset/stale boundaries, old Live Activity state and pending resets, pinned widgets, queued notification intent/latest preferences, partial CloudKit conflicts, and the earlier completion cases. Do not add methods to the historical 430-test pass. The hosted iPhone bundle has 13 compiled methods (11 earlier and two new), all unexecuted.

## Inspect particularly carefully

- Key editor state transitions, lifecycle invalidation, admin acknowledgement, overlapping tasks, and the distinction between captured credentials and editable text.
- Real CloudKit revision preservation/error propagation, bounded retry semantics, base/local delta handling, and local edits while a synchronization request is suspended.
- Every production ranking/presentation call site; per-window history; stale/expired data; legacy missing timestamps; clock inputs reaching unchanged rows/details without resetting navigation or tile ordering.
- Watch account-change races, persisted validation flag/cutoff, failed disk writes, every snapshot/relevance path, available-to-available account changes, phone context replay, incoming provider removal, delayed cache rejection, complication reload/relevance invalidation, and retained-cache errors. Verify gate recovery after a complication validates and saves while the app is suspended.
- All widget families and their `ViewThatFits` fallbacks: critical text, pending reset explanations, stale counts, selected-provider behavior, and accessibility values. Pay special attention to narrow Watch/circular families and amount-only windows.
- Per-feed success/failure migration, validators after broken/truncated/304 responses, grouped sources (`partOf`), selectively forced follows, and queued manual/source requests during cancellation or follow changes.
- Today/Retiring/search/lab/tool empty states, health provenance, badge/visit boundaries, model paging, native text sizing, explicit price units, and reachable actions.
- Debug snapshot/bootstrap paths must remain isolated from real migrations, preferences, cached account data, and credential lookup. Release behavior must not depend on debug fixtures.
- Regression source should exercise failures and invariants, not only mirror helper implementation. Identify coverage gaps without executing prohibited tests.

## Edge cases to verify after explicit runtime-test authorization

1. Change key/account repeatedly during validation; change away and back; close the editor; retry after failure; acknowledge/unacknowledge an admin key; double-tap Save Anyway; persistence fails.
2. Concurrent different-field and same-field preference edits; first sync with missing base/record; malformed payload; exactly three conflicts; cancellation; edit locally while a write is suspended; older writer changes the record; nested partial-failure errors that do not bridge as `CKError`.
3. Empty/whitespace budget, localized separators/grouping/native digits, tiny positive amounts, zero, negative, NaN/infinity/overflow, incomplete or malformed text; leave/reopen with an invalid draft.
4. Exact one-hour/seven-day boundaries, legacy envelope fallback, future clocks, mixtures of fresh/stale/expired providers, expiry while rows/details remain open, all readings expired, a chosen widget provider absent/removed/expired in every family; automatic and list behavior.
5. Cache update with provider A older, B newer, and C removed; globally delayed cache; equal timestamps; Watch relaunch after sign-out with failed empty-cache write; complication snapshot/relevance reads while the gate is closed and an already-issued timeline after it closes; available-to-available account switch, including whether `.CKAccountChanged` arrives; phone context before validation; old handover after revalidation; account changes during a read; failure with usable cache; recovery via Retry. Keep the Watch app process alive with empty memory, then have a complication validate/save a reading: check both a throttled resume and a failed in-flight app read show that reading beside the connection error without admitting an old phone handover. While the app remains visible, check the adoption timing when no refresh occurs.
6. Primary healthy/secondary exhausted; equal urgency with unrelated high weekly usage; balance/no-reset limit; stale exhausted window; primary reset pending while secondary still exhausted; reset exactly now, moved reset date, fresh post-reset data, and disabled alerts; ActivityKit marks stale before clock rollover, lingering ended activity, old state without awaitingReading. Confirm no synthesized zero or unconfirmed forecast/alert.
7. One good/one failed/newly followed feed; failure less than one hour old; uncached failed re-follow; grouped feed; HTTP/transport/parse/truncation failures; valid empty feed; 304 with and without cached content; old metadata; rapid Follow changes; cancellation of the originating page task while a manual/source pass is queued; several queued manual/source refreshes; manual notifies=true followed by Follow notifies=false; newest preferences disable new-model alerts; no duplicate delivery.
8. Today with no follows, cached content plus failures, only distant retirements, no matching search, no upcoming retirements; zero/50/51/60/61/many models; internal Follow navigation versus leaving/re-entering News or closing/reopening its Mac window.
9. Small iPhones and both Watch sizes, light/dark, XXL and accessibility text, long titles/source names, keyboard and VoiceOver, widget rendering/fallbacks. Verify navigation inside the periodic iPhone/Watch views and the circular “no recent reading” label; information and actions must remain readable/reachable.
10. On paired signed devices, exercise relay, alerts/deduplication/quiet hours, Watch sign-out and complications, and Live Activities. Compilation or simulator renders cannot prove these integrations.

## Known risks and assumptions

- Runtime acceptance is **not complete**: the user's no-tests instruction prevents current test execution and interactive/device QA. Report that block explicitly; do not silently waive it or label the full plan 100% validated.
- Preference conflict protection requires updated writers; older releases can still overwrite fields.
- Legacy News caches lack individual historic success times. Migration freezes old aggregate timestamps for cached sources rather than inventing precise past per-source history.
- Reading freshness/sign-out cutoffs depend on device clocks. Payload compatibility is preserved without introducing account identities. Observed account changes invalidate cached state, but cross-device identity agreement and missed platform account notifications cannot be proved by static review; signed-device account transitions require independent scrutiny.
- WidgetKit refresh/relevance budgets, iCloud delivery, Live Activities, accessibility usability, and small-device visual fit need runtime evidence. Reset Soon uses a relevance provider without an exact-time timeline callback; its scheduled Watch background refresh is only a request, so redraw at the reset boundary remains system-dependent. Native Mac offscreen renders have known artifacts.
- The current app and test-target builds compile production and regression source, but do not execute any of the 20 new methods. Earlier test results do not cover the completion diff.

## Review output requested

Provide findings first, ordered by severity, with repository-relative file/line, the concrete failure trigger, expected versus actual behavior, and the smallest relevant evidence. Independently map each original plan item to implemented behavior and report any omitted integration, documentation, regression source, or acceptance criterion. Separate confirmed source defects, plausible risks needing runtime reproduction, passed compiler evidence, historical test evidence, and blocked checks. If source review finds no defects, say so while keeping runtime acceptance explicitly open. Do not claim approval or 100% validated completion from a clean static review alone.
