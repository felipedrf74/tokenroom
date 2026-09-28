# Settings, usage, Watch, and News implementation

Completion audit: 2026-09-27. Implemented on `codex/settings-usage-news`, starting at `56f57708aa797ef4004a4ef3483a693b5a5739ca`. This records the pre-release QA snapshot; subsequent Git/App Store publication and local installation were separately authorized on 2026-09-28. References below to the "current" uncommitted diff describe that snapshot, not publication status. The later request did not authorize executing tests.

The requested behavior is implemented in source, with independent review fixes described below. The completion audit found and closed additional gaps in ranking, reset presentation, widget summaries, localized budgets, Today empty states, and uncached feed follows. These follow-up edits are **uncommitted**. Source completion is distinct from acceptance: test execution and interactive/device QA are blocked in this pass by the user's explicit instruction, “Don't commit or run any tests unless if I specify to do it so.” Those checks are not passed or waived.

## Full plan disposition

“Source complete” means implementation and call-site wiring have been reviewed; it does not certify runtime behavior. Compilation results are recorded separately.

| Plan item | Implementation / evidence | Disposition |
| --- | --- | --- |
| Immutable key/account validation on Mac and iPhone | `KeyValidationRevision`, both key editors. Changes invalidate warnings and Save Anyway; superseded answers are ignored. Saves capture tested credentials, guard admin acknowledgement, disable inputs during persistence, and block overlap. | Source complete; interactive race checks blocked below. |
| Concurrent alert preference protection | `AlertPreferencesSync.synchronize`, `CloudRelay.preferenceRevision` / `savePreferences`, `RelayPublisher`, `MobileStore`. Fetched change tag survives the `.ifServerRecordUnchanged` write. Original field delta remerged for at most three total attempts. Failures leave edits pending; edits made during synchronization survive. | Source complete; real multi-device conflicts blocked below. |
| Localized budgets without destructive invalid input | `BudgetInput`, both editors/setters. Empty clears; complete finite positive input saves; invalid/zero/negative/nonfinite preserves the saved amount with inline error. Native decimal digits normalize; fractions/superscripts remain invalid. | Source complete. |
| Settings navigation/accessibility | Named provider switches with connection status values, Enabled group, resizable Mac Settings, provider/lab/source search, Claude Advanced disclosure; grouped forms retained. | Source complete; keyboard/VoiceOver/window acceptance blocked below. |
| Per-provider freshness | `ReadingFreshness`, `RelayMerge`, `ReadingCache`, `ReadingsEntry`, mobile/Watch clocks and views. Older than one hour is stale; older than seven days is hidden; last check is per provider. Summaries use the oldest shown success and stale counts. | Source complete; clock/device acceptance blocked below. |
| Watch recovery and account consistency | `WatchAccountGate`, `WatchCacheAccess`, `WatchStore`, `RelayReadings`. The newest envelope controls membership/removals; retained providers keep their newest readings. Globally delayed caches cannot restore removals. Unreachable errors remain beside saved readings with Retry/Refresh. Confirmed sign-out clears caches/reloads complications; handovers require revalidation and post-sign-out dates; account changes invalidate in-flight outcomes. | Source complete after living-process disk adoption; signed-device acceptance blocked below. |
| Urgency across every metered window | `UsageRanking`, assembler/cache/sample paths, Mac `connectedProviders`. Severity and percentage come from the same most urgent window; headline preserved. Secondary warnings on Mac cards/compact rows, iPhone tiles, Watch rows, widget summaries. iPhone tiles remain stable while visible. | Source complete; ordering/layout acceptance blocked below. |
| Resets, forecasts, alerts, and readability | Elapsed data retained; headline dash plus Reset / “Reset · awaiting reading”; forecasts/pace/alerts suppressed until replaced. Usage complication timelines include reset/stale/expiry boundaries. The relevance-based Reset Soon widget schedules a best-effort background refresh near a reset and shows pending copy on its next render; WidgetKit controls when it redraws. XXL and above uses one iPhone column. A separate Mac clock drives reset/stale presentation without polling. Menu-bar pending percentages are withheld; Highest prefers a current meter; if all meters are pending/placeholders, it falls back to the first and still shows its dash/placeholder instead of inventing usage. | Source complete; device/reset-timing acceptance blocked below. |
| Independent News recovery | Optional per-source dates; independent scheduling, conditional GETs, byte limits; transport/parsing failures affect health and retry after one hour. Uncached follows fetch immediately, including re-follows after failure. Local `forcedSources` requests union through a queued pass without losing manual refreshes; an unstructured worker keeps those passes running when the requesting view task is cancelled. | Source complete; live-feed acceptance blocked below. |
| News health and empty states | Today/Retiring health and cached-content explanations; separate nothing-followed/no-match/no-retirement/failure states with Follow/Show All/Retry. Today uses the visible edition, including the 30-day retirement horizon. | Source complete; visual/interaction acceptance blocked below. |
| News visit continuity | `beginVisit` / `endVisit` at root tab-entry and Mac window-opening/closing boundaries. Opening clears badge; internal Follow navigation retains the New baseline. | Source complete; navigation acceptance blocked below. |
| Discovery/model clarity | iPhone title/source search; Show More beyond 50/60 cached model rows; explicit input/output per million tokens; adaptive cards/specifications; serif/SF typography and native navigation retained. | Source complete; narrow/large-text acceptance blocked below. |
| Regression source for all changed domains | Settings/preference conflicts/budgets, mixed ages, Watch account gate/cache merging, secondary limits/resets, per-feed failures/follows, visit continuity, mobile store regressions. Twenty uncommitted regression methods in the current diff (18 Mac/shared, two hosted iPhone); nine were part of the first completion pass. | Source complete; latest methods unexecuted. |
| Repeat Mac/shared tests | Historical 430-test pass belongs to the earlier committed implementation. | Impossible within current authorization: user forbids test execution. |
| Repeat shared typechecks and Mac/iOS/Watch/widget compilation | Compiler checks only; no tests or apps launched. | Results below. |
| Run hosted iPhone tests locally | Eleven hosted tests compiled previously but did not execute. | Impossible within current authorization: test execution forbidden. Previous simulator failures are historical, not current availability evidence. |
| Light/dark, small iPhone, XXL/accessibility, both Watch sizes, keyboard/VoiceOver captures | Historical Mac renderings have limitations. No interactive acceptance or new captures in this pass. | Impossible within current authorization: these are runtime QA tests. Layout acceptance remains open. |
| Paired signed-device relay, alerts, complications, Live Activities | Compilation/source cannot prove delivery or account behavior. | Impossible in this pass: runtime testing forbidden; real account/device operations also require attended signed pairing and owner-controlled sessions. |
| Three reviewable implementation changes | Existing commits: `0990ed7` Settings; `392c729` usage/Watch; `4b47cf4` News/refinements. Closure fixes remain a working-tree diff. | Existing stages complete; additional commits prohibited. |
| Compatibility/architecture | Relay/cache version 1; optional News metadata and Live Activity pending state; local-first/read-only provider sessions; platform styling; usage-focused Watch. | Source complete. Older preference writers can still overwrite changes. |
| Documentation and independent QA prompt | This acceptance record, both repository skills, `docs/settings-usage-news-qa-prompt.md`; complete committed plus uncommitted file inventory. | Complete: final source/compilation review and inventory check recorded below. |
| Cleanup, new providers, Watch News, deployment/release | Explicit exclusions in the original plan. | Outside scope; no unfinished cleanup/release work implied. |

## Independent review findings and source fixes

The pasted independent review was not approval. Its seven findings have source fixes; runtime acceptance remains open. No commits or test execution occurred while addressing the review.

| Review finding | Source correction / regression source |
| --- | --- |
| 1. Pending phone handover lost after iCloud validation | The newest envelope determines membership. An older envelope can advance newer checks for retained providers, but cannot restore removed providers or remove newer members. `ReadingReliabilityTests` covers delayed handover and removal. |
| 2. Mac presentation waits for polling | A dedicated `QuotaStore` clock publishes reset and one-hour aging boundaries, re-arms when readings/check timestamps change, updates once a minute between boundaries, and cancels on stop. Cards, ranking, forecasts, menu text/Highest, and accessibility use its date without fetching providers or rewriting collector state. `APIKeyTests` covers injected clock boundaries. |
| 3. Live Activities synthesize zero | Optional `awaitingReading` preserves compatibility with old activity state. Ended/stale/reset activities retain measured usage, show a dash and awaiting-reading caption on Lock Screen, Dynamic Island, and supplemental Watch activity; pace and stale threshold alerts are suppressed. Hosted regression source covers preserved data and old-state decoding. |
| 4. Pinned widget substitutes another provider | Missing/expired selected providers produce a named no-recent-reading entry and link to that provider. Automatic widgets still choose urgency; a present pinned provider still leads list widgets. Hosted regression source covers missing, expired, present, and automatic selection. |
| 5. Watch sign-out disappears on restart | `WatchCacheAccess` persists a validation gate and cutoff, used by Watch initialization and all complication snapshot/timeline/relevance reads. The gate opens only after a validated cache is successfully saved; failed writes preserve the block. Account-change notifications also invalidate cached data before revalidation; a complication-established fence is checked before app presentation and phone acceptance. Shared regression source covers retained disk files, write failure, account change, and the production complication outcome path. |
| 6. iPhone detail says “— used” | Hide the used label and dim the meter while its reset is pending. |
| 7. Queued Follow disables manual notifications | Coalesced notification intent uses logical OR, source IDs union, manual maxAge stays zero, and latest preferences control notification eligibility. An injected notification sink tests the manual-then-Follow path without delivery side effects. |
| Additional key-editor UX and CloudKit risk | Both Save Anyway buttons disable when the admin acknowledgement is unchecked. Conflict detection also recognizes nested CloudKit partial-failure record conflicts; regression source covers conflict versus network/permission failure. |

At the first independent review, the uncommitted diff added **17 regression methods** relative to `4b47cf4` (15 Mac/shared, two hosted iPhone). The current count after the second review is 20. The 17 were unexecuted and their test targets had not been compiled at that point. Do not add new methods to historical pass counts.

Compiler checks **passed for the earlier review-fix source, before the second-review edits:**

- Shared typecheck on macOS, iOS, and watchOS: `/tmp/tokenroom-review-fixes-shared-final.log`.
- Unsigned Mac app build: `/tmp/tokenroom-review-fixes-mac-final.log`.
- Unsigned generic iOS Simulator build, including Watch and both widget targets: `/tmp/tokenroom-review-fixes-apple-final.log`. The last incremental build compiled the final Watch account-fence guard for arm64 and x86_64.
- No compiler errors or warnings appear in those earlier successful logs. Current compiler results are tracked separately.

An initial shared check was invalidated because source changed during compilation and was restarted after those source edits stopped. Those first-review checks did not run tests, launch applications, boot simulators, exercise accounts, sign/install builds, or commit changes. They cannot close runtime acceptance.

## Second independent review: living Watch process and cancellation

The second source review confirmed one additional defect: a running Watch process could retain `cache = nil` after a complication revalidated iCloud and saved a reading. `WatchStore.refresh` now checks the durable gate and reconciles the complication file before throttling a resume refresh, before applying an incoming iCloud reading, and after a failed iCloud read. `WatchCacheRecovery` keeps the newest provider checks and the newest envelope's membership. It does **not** unlock phone handovers merely because a persisted file exists; this process still waits for its own successful iCloud read. The Watch displays the recovered reading beside its existing unreachable message. A shared regression method covers nil in-memory state, validated disk recovery, and a later account cutoff; it cannot execute the Watch UI under the no-tests instruction.

Cancellation of a News page `.task` could abandon its queued manual/follow requests. `NewsStore` now runs the refresh sequence in a separate unstructured task owned by the store. It keeps the one-follow-up coalescing rules, the union of forced sources, the manual zero-age request, and notification intent. A regression method cancels the original request while a probe is suspended, then checks the queued pass is still performed. [Swift's concurrency guide](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) describes unstructured tasks as having no parent task; this is the intended lifetime here.

The Watch's Reset Soon widget uses `RelevanceEntriesProvider`, which supplies a single configured entry rather than a timeline. It now uses one render-time date for headline/caption, shows “Reset · awaiting reading” when the rendered entry is pending, and the Watch app requests a background turn at the next reset within 15 minutes and reloads that widget if a reset crossed since its last refresh. [Apple's WidgetKit documentation](https://developer.apple.com/documentation/widgetkit/relevanceentriesprovider) confirms that provider has no timeline callback; [Apple's timeline guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/) makes clear the system controls actual redraw timing. Exact-time presentation remains a **runtime/platform limitation**, not an acceptance pass. The ordinary usage complication retains its precomputed reset entries.

The current uncommitted diff adds **20 regression methods** relative to `4b47cf4`: 18 Mac/shared and two hosted iPhone. Both test targets now compile, but **no tests were executed**. The first completion pass's nine-method count below is historical and is no longer the current count.

The compiler logs from the first independent-review fixes predate these second-review source edits. The final source was checked again with:

- Shared macOS/iOS/watchOS typecheck: `/tmp/tokenroom-qa2-shared.log` — passed.
- Unsigned Mac app build: `/tmp/tokenroom-qa2-mac.log` — passed.
- Unsigned generic iOS Simulator build, including Watch and both widget targets: `/tmp/tokenroom-qa2-apple.log` — passed.
- Compile-only Mac/shared test-target build: `/tmp/tokenroom-qa2-mac-tests-build.log` — `TEST BUILD SUCCEEDED`.
- Compile-only hosted iPhone test-target build: `/tmp/tokenroom-qa2-apple-tests-build.log` — `TEST BUILD SUCCEEDED`. The hosted bundle has 13 methods (11 earlier and two new), all unexecuted.

These successful logs contain no `error:` or `warning:` diagnostics. Build-for-testing compiles targets and does not execute a test runner, launch the host app, or boot a simulator. `git diff --check 56f5770` is clean. Compiler evidence remains distinct from signed-device/visual acceptance.

## Third independent source review: no confirmed defect

The subsequent review of the same base, committed head, and 61-file working tree found **no confirmed source defect**. It checked the living Watch cache adoption, store-owned News refresh, Reset Soon reset-date handling, and the remaining Settings, usage, and News plan items. This is a source verdict, **not approval or runtime acceptance**. The recovery regression method exercises `WatchCacheRecovery`, not `WatchStore.refresh` itself; both it and the News cancellation method remain unexecuted. The historical 430-pass result still predates this diff.

The reviewer identified cases for runtime scrutiny rather than proven failures: WidgetKit may defer a Reset Soon redraw; an already-issued complication timeline may render once after the account gate closes; available-to-available account switches depend on `.CKAccountChanged`; nonbridging nested CloudKit errors may not enter the conflict retry; and navigation inside periodic iPhone/Watch views plus the circular no-recent-reading label need device inspection. An already-visible Watch app adopts a newly validated complication file when `refresh` runs, not through continuous file polling. The blocked test, simulator, accessibility, and paired-device checks in the plan table remain open and are not waived.

## Completion-pass fixes and checks

Ranking now breaks ties using the urgent window's own percentage and per-window history, including Mac ordering. Mac full/expanded/compact cards and menu-bar accessibility withhold elapsed percentages. Rectangular iPhone widget fallbacks retain warning/pending explanations and stale counts; circular/corner families show Reset and accessibility explanations. Watch summaries exclude expired hidden readings. Watch/iPhone presentation dates are passed into rows and details so SwiftUI receives an explicit update input even when measured data is unchanged; amount-only iPhone tiles explain pending resets too. Native budget digits parse strictly. Today bases its empty state on the visible edition, and an uncached failed re-follow fetches selectively without losing queued requests.

The first completion pass added nine regression methods and **did not execute them**: two Mac store/menu cases; three ranking/reset attention cases; one distant-retirement edition case; one native-digit budget case; one selective uncached follow retry; one queued follow/manual refresh union case.

Earlier completion-pass compilation results (before the independent-review fixes):

- Shared standalone typecheck **passed** on macOS, iOS, and watchOS: `/tmp/tokenroom-completion-shared.log`.
- Unsigned Mac app `xcodebuild build` **passed**: `/tmp/tokenroom-completion-mac-build.log`.
- Unsigned generic iOS Simulator `xcodebuild build` **passed**, including the Watch app and both widget targets: `/tmp/tokenroom-completion-apple-build.log`. An incremental build after the final source edits also **passed**: `/tmp/tokenroom-completion-apple-build-final.log`.
- The successful build logs contain no compiler errors or warnings. The initial shared check rejected a complex ranking inference expression; it was split into explicitly typed steps before the successful retry. This was a compilation fix, not a test run.

No test runner, test-host launch, simulator boot, or interactive QA has run in that earlier completion pass. Its app compilation did not include the later test-target builds. Static review covered the completion diff, call sites, metadata decoding, relay version preservation, and regression-source additions. `git diff --check` reports no whitespace errors; this is not runtime validation.

Compiler commands used (no test execution):

```sh
./scripts/typecheck-shared.sh
xcodebuild build -project Tokenroom.xcodeproj -scheme Tokenroom -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementation -jobs 2 CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementationMobileBuild -jobs 2 CODE_SIGNING_ALLOWED=NO
```

## Behavior

- Key tests authorize an immutable key/account revision. Editing either invalidates warnings and Save Anyway; saving captures the tested input and prevents overlapping writes.
- Alert preferences retain CloudKit change tags, use `ifServerRecordUnchanged`, and retry the original field-level delta against the latest record for at most three attempts. Failed writes leave local edits pending.
- Localized budget parsing accepts complete, finite, positive numbers, including native decimal digits. Empty clears; invalid input preserves the saved amount and shows an error.
- Settings has named provider switches, an Enabled group, provider/source search, resizable Mac windows, and Claude Advanced disclosure.
- Every provider ages independently: stale after one hour, hidden after seven days. Summaries date the oldest shown check. Watch and widget presentations include stale states and check times.
- Watch caches merge the newest check for retained providers while the newest envelope controls membership/removals. Confirmed sign-out empties account caches and reloads complications; phone handovers require account validation and cannot replay pre-sign-out caches. The persisted validation gate protects disk caches across restart and every complication read, even if writing the cleared cache fails. Account-change notifications invalidate prior cached readings. Connection errors remain visible beside retained or newly adopted complication readings, with Refresh/Retry actions.
- Ranking considers all metered windows and ties use the urgent window's percentage. Exhausted secondary windows receive a short warning; iPhone tile order remains stable while visible. XXL and larger text uses one column.
- Scheduled resets show “Reset · awaiting reading”; no live zero is synthesized, including lingering/stale Live Activities. Mac presentation time advances independently of provider polling. Pinned widgets never replace a missing/expired choice with another provider. Elapsed windows produce no forecast or usage alert. Widget timelines include reset, stale, and expiry boundaries.
- News has optional per-source success/failure metadata, independent retries, immediate uncached follows, conditional GETs, and existing byte limits. Parsing and transport failures are visible; partial answers preserve cached content. Manual refreshes coalesce into a follow-up pass while preserving any queued notification request and applying the latest preferences, even when the requesting News page task is cancelled.
- News visits survive internal navigation. Today and Retiring show section health; empty states retain Follow, Show All, and Retry. iPhone search covers titles/sources, cached model lists have Show More, and prices label input/output per million tokens. Cards/specs adapt to larger text.

## Historical validation — earlier committed implementation only

These results precede the uncommitted completion fixes and **do not establish that the current tree passes tests**.

- Prior Mac/shared suite: **430 tests passed**, zero failed or skipped. Result: `~/Library/Developer/Xcode/DerivedData/TokenroomImplementation/Logs/Test/Test-Tokenroom-2026.09.27_17-39-44-+0100.xcresult`. The suite covers credential revision changes, bounded concurrent preference conflicts, localized/invalid budgets, mixed reading ages, individual cache updates/removals, the Watch sign-out gate, secondary-window urgency, reset/freshness boundaries, independent feed retries, transport/parsing failures, cache migration, manual refresh coalescing, and visit continuity.
- The prior iOS Simulator build, including Watch and both widget targets, passed with provider search and complication warning refinements.
- The prior standalone shared typecheck passed on macOS, iOS, and watchOS (`./scripts/typecheck-shared.sh`).
- The hosted iPhone test bundle compiled successfully (`xcodebuild build-for-testing`, unsigned simulator build), including two new store regressions for persisted invalid budgets and aging while Usage stays open. Those 11 hosted tests were **unexecuted** at that historical point; the current 13-method hosted target compiles but remains unexecuted under the user instruction.

Generated sample captures are at `/tmp/tokenroom-implementation-20260927/mac`. They include light/dark usage and News, plus Settings tabs. Native sidebar/selection rendering in this offscreen harness has black selection artifacts; these captures do not validate native window interaction. The snapshot bootstrap bypasses real migrations/settings/cache and credential lookup; the iPhone snapshot fixture path is debug-only.

Hosted iPhone testing was attempted locally. The first attempt stalled during severe host load; additional QA simulator boots reported `launchd failed to respond` / `could not bind to session`. Only task-owned QA commands/simulators were targeted for stopping; no shared simulator service or other project was stopped. The single-worker retry failed before running tests: Xcode could not find an available matching simulator. Hosted execution is **not passed**.

## Remaining runtime acceptance

Every plan item has a disposition, and the source is ready for independent QA. **The full plan is not 100% runtime-validated.** Test execution, small iPhone/large text layouts, both Watch sizes, keyboard/VoiceOver, and paired signed-device relay/sign-out/alerts/complications/Live Activities cannot be performed under the current no-tests instruction. These remain open acceptance criteria with the specific reasons in the table, not successes or waived checks. Prior simulator failures do not establish that the simulator is currently unusable. Mac rendered captures are limited evidence, not a substitute for interactive checks.

Relay payload version remains 1. News metadata is optional for old caches. Preference conflict protection applies to updated writers; older releases can still overwrite changes.

Legacy feeds lack individual historical dates, so migration freezes existing aggregate times for cached sources. Reading times depend on device clocks; confirmed Watch sign-out uses a local cutoff and account revalidation without changing relay identity. WidgetKit scheduling/size limits and iCloud delivery require device proof. Source review and compiler checks cannot establish visual fit, accessibility usability, or live account behavior.

No cleanup, installed-app replacement, publishing, deployment, release submission, new providers, or Watch News is part of this change.

## Reproduction commands

Test commands below require renewed explicit authorization. They are recorded for future QA and were not executed in this completion pass. Do not use `scripts/build.sh` for QA: it can replace the installed app.

```sh
xcodebuild test -project Tokenroom.xcodeproj -scheme Tokenroom -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementation -jobs 2 CODE_SIGNING_ALLOWED=NO
./scripts/typecheck-shared.sh
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementationMobileBuild CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomImplementationMobile -jobs 2 CODE_SIGNING_ALLOWED=NO
```

Logs: `/tmp/tokenroom-verified-mac-tests.log`, `/tmp/tokenroom-frozen-shared.log`, `/tmp/tokenroom-verified-apple-build.log`, `/tmp/tokenroom-verified-hosted-build.log`. Simulator attempt logs: `/tmp/tokenroom-hosted-mobile.log`, `/tmp/tokenroom-hosted-mobile-retry.log`.
