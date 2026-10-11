# Fifth independent QA and authorized validation — historical QA5 snapshot

Current remediation and validation: [sixth QA report](news-sixth-qa-validation-20261011.md). Findings and counts below describe the QA5 tree, before those fixes.

Checkout: `/Users/felipedominguez/Developer/tokenroom-improvements-20261004`, branch `tokenroom/urgent-window-projected-pace`, HEAD `adbb201fb82e235bee9422e06a7e1208cc4736a9` plus the complete uncommitted tree. The initial 79-path snapshot matches the prior QA4 closeout. Three independent reviewers inspected the five repairs and surrounding source before controlled validation. Felipe's latest instruction conditionally authorized testing, committing, pushing main and public release if release confidence was established. Testing was used to evaluate that condition; it supersedes the earlier no-tests restriction for this pass. Release confidence was **not established**. Nothing was committed, pushed, versioned, installed over the production app or publicly released.

## Goal and implementation

Deliver a clearer native, account-free News reader on iPhone and Mac: Today / Following / Skills / Saved, attributed stories and full details, local read/save/undo, native sharing/original links, curated voices through public articles and X profiles, opt-in official status, and truthful public skill rankings. Existing follows and urgent-window/pace/alerts/relay work must survive. Personal resets remain in Usage. No X API/timeline/social action, account, article scraping, skill execution or News CloudKit sync.

## Prior findings confirmed corrected

| Finding | Independent source review and current evidence |
|---|---|
| QA4-01 queued preferences | Every accepted slower/cached request updates an existing queue's preferences while keeping notify OR, permission, age and forced-source contracts. `NewsFourthQAFixTests` queue regressions pass. |
| QA4-02 complete Unsave | Complete transitive saved identity groups are removed atomically. Batch Undo restores exact snapshots/savedAt, rejects conflicts/capacity/write failures without partial state, and remains pending after failure. Current regressions pass; native iPhone Save → Unsave → Undo works. |
| QA4-03 Mac source search | Native source toolbar search uses the complete paired family before filtering/caps. Current regressions pass. In the inert Mac fixture, Claude Code's paired-family health shows 1/2, an unmatched query shows an explicit empty state, and selecting Codex clears the query and displays its retained story. Return navigation has a separate defect below. |
| QA4-04 app-owned XCTest storage | Mobile root uses isolated AppStorage/defaults, mocked keys, nil cache/history/ledger/lock directory/CloudKit and inert effects. Lifecycle, push, background registration and UI paths respect it. Hosted runtime cases pass after the compile and test-isolation repairs below. Unsigned simulator checks do not prove signed App Group isolation. |
| Related bridge folding | One paired entry merges every matched group, unions identities, redirects inherited keys and preserves the newest winner/earliest bookkeeping. Bridge, persistence, removal and Undo regressions pass. |

All 66 later regression methods are now compiled and executed: 61 in the 719-case Mac run, including the direct status-history and two discovery-isolation cases, and five hosted mobile runtime cases. Modified existing cases in the selected suites also ran. This replaces the QA4 statement that these sources were uncompiled/unexecuted; it does not imply a demonstrated historical RED for every added case.

## New defects repaired during validation

1. **P1 mobile compile blocker:** SwiftUI's SceneBuilder could not build the conditional `WindowGroup` / background-task scene branches in `TokenroomMobileApp.swift`. The app now chooses separate production/inert App compositions at its main entry, sharing `MobileWindowScene`; only production registers the background handler. Production scene behavior remains, and the inert host actually compiles and launches.
2. **P2 test contamination:** named defaults suites share the process-wide `NSArgumentDomain`. The ordinary-sample test left `sampleMode=YES` visible to the later no-fixture test. `MobileRuntimeTests` now snapshots/restores that volatile domain per test. The failed first retry and the later five-case passing run are both retained. The failed retry's diagnostic collection hung and was stopped; its command ended interrupted, not successful.
3. **Public documentation gap:** `PRIVACY.md` and README now distinguish private account identity from public publisher/skill names and document local saved/read/skill snapshot metadata, public voices/status/ClawHub requests and browser-only X links. Final source review additionally corrected the distinction between iPhone News cache/follows in the App Group and its saved/read library in app-owned Application Support. No account, telemetry or News relay was added.

## Remaining confirmed defects

### QA5-01 — P2: Mac reader loses Back navigation

Location: `Tokenroom/Views/NewsWindowView.swift:97–109`; related `Shared/UI/NewsReadingViews.swift:74`, `Tokenroom/App/AppDelegate.swift:138`, `Tokenroom/App/TokenroomApp.swift:11`.

Today → story and source → story push into a detail that removes the root toolbar, supplies no visible Back control and does not respond to Command-[. The production-shaped SwiftUI fixture's View menu contains only tab/full-screen commands. Selecting another sidebar page and returning recovers the list, discarding continuity. The root-only toolbar and unbound NavigationStack have no explicit return path for the AppKit-hosted window. Preserve a Mac return path and window commands across story/model/skill/Saved/source/collection pushes, including nested returns; resetting sidebar selection alone would lose continuity.

**Evidence boundary:** reproduced using the current production module in two external inert native fixtures, including the production SwiftUI scene/menu shape and AppKit toolbar/title bridge. A separate reviewer confirmed the source path and severity. The full production app/collectors were not launched. Native component defect confirmed; production startup/delivery remain unverified. T6.S4 executed and failed; specification acceptance 4 is partial and 7 fails its usable Mac detail requirement.

### QA5-02 — P2, inherited: Moonshot reference amount changes currency silently

`TokenroomMobile/MobileSettingsView.swift:371`, `MobileStore.swift:1300–1316`, `Tokenroom/Refresh/AppSettings.swift` and `Budget.swift` retain a numeric provider reference without its unit. The editor labels it from the last reading/default USD, independently of the newly selected China region; the China parser supplies CNY. A saved USD 100 reference can therefore become CNY 100 after regional key replacement without an explicit choice. This changes meters, ranking and low-balance alerts; it does not alter the raw reported balance. Persist/validate the reference unit and present a deliberate regional replacement policy. Source-confirmed in inherited HEAD, not introduced by News; no real key or provider call used.

### QA5-03 — P2, inherited: adjacent reset buckets permit duplicate device alerts

`Shared/Core/Alerts.swift:611–617` rounds short-window reset times to ten minutes (long windows to an hour). Two devices observing the same session at 12:04:59 and 12:05:01 generate different instance/event IDs. The local first-reset anchor cannot reconcile independent devices; `CloudRelay.claimAlert` and event records coordinate exact IDs, allowing two different records/pushes. Use shared logical window identity/coordination rather than a different rounding threshold. Source-confirmed in inherited HEAD; actual CloudKit delivery was not exercised.

## Current executed checks

Evidence directory: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/news-implementation-20261011/qa5-release-evaluation-20261011T172031Z`. All DerivedData is outside the checkout. Exact command lines are in each log; xcresults are retained privately.

| Check | Current result / artifact |
|---|---|
| Shared typecheck | macOS / iOS / watchOS pass; `logs/typecheck-shared.log`. |
| Mac tests, signing off | 719 tests, zero failures; `logs/mac-tests.log`, `mac-tests.xcresult`; eight Keychain cases explicitly excluded below. |
| Hosted MobileRuntimeTests, serial/no diagnostic collection | Five tests, zero failures after both repairs; `logs/mobile-runtime-final.log`, `mobile-runtime-final.xcresult`. Actual app-owned inert composition launches. |
| Four existing mocked mobile notification/account-change cases | Four tests, zero failures; `logs/mobile-notification-tests.log`, `mobile-notification-tests.xcresult`. Real notification delivery is not implied. |
| Unsigned generic iOS Simulator Release build | Succeeded, includes phone widgets, Watch app and Watch widgets; `logs/ios-release-build.log`. |
| Unsigned Mac Release build | Succeeded; `logs/mac-release-build.log`. |
| Actual elapsed localhost Skills streaming | Production clocks/deadline/default get exercised on macOS: expiry about 8.01 seconds, joined reader shares it, one physical request, late valid body rejected, no second GET until physical completion, later retry succeeds; probe exit 0. `skills-streaming/result.md` and hashed source/server/execution logs. |
| Native current fixture journeys | Narrow iPhone SE (375-point width), light/default and largest-accessibility dark top layouts inspected. Save/Unsave/Undo, read marker, Saved, system Share sheet (cancelled), Skills detail and profile-only local Follow observed. Mac source search/query reset and detail Save/Unsave/Undo observed; Mac Back journey failed above. `native-observations.md`, captures and external harness sources. |

Mac exclusions (not passed): `APIKeyTests/testKeyStoreRoundTripShowsOnlyTheLastFour`, `testAKeysWarningIsKeptWithIt`, `testReplacingAKeyStartsFromTheChoiceSavedWithIt`, `testMissingKeyReadsAsSignedOut`; `CodingPlanTests/testAPastedKeyWinsOverOneFoundOnTheMac`, `testAnExpiredLocalLoginReportsExpired`; `MobileLogicTests/testNoKeyMaterialReachesAnyRecord`; `RequestTests/testCopilotFallsBackToAPastedTokenOnlyWhenTheLoginCantBeUsed`. Other mobile cases compiled but were not selected, because several default to real Keychain operations. The four selected notification cases explicitly mock keys/CloudKit/scheduling.

The streaming probe is localhost-only and contains no Authorization header. It does not validate iOS/watchOS elapsed transport timing, public availability or synchronous decoding performance near the deadline. QA4-R01 decode-inclusive timing remains **UNCONFIRMED**, not a confirmed source defect. Mixed malformed SkillFeed container policy and cumulative reset-anchor drift were also not confirmed as additional P2s.

## Plan and release disposition

See [the step-by-step completion audit](news-redesign-completion-audit-20261011.md). Automated acceptance 8 passes within the explicit exclusions and unsigned/inert scope. Tasks 1–4 have implemented contracts with current test evidence. Task 5's narrow/layout/actions acceptance is partial: physical VoiceOver/focus, Reduce Motion, all current empty/offline/retry states and complete largest-text journeys remain unverified. Task 6's return navigation fails. Task 7's current automated integration/documentation are present; the overall plan is **not 100% accepted**.

**Public release: NO_GO.** The Mac defect must be repaired/rechecked; inherited usage/alert defects need disposition; native accessibility/error/recovery acceptance and signed App Group/flock, iCloud/notification/Watch acceptance remain open. `Config/Local.xcconfig` is absent, signing team/profile setup and distribution credentials are not established, and no signed/notarized/stapled/Gatekeeper-tested Mac archive or signed device/App Store artifact exists. No Keychain credentials were inspected. New versions/builds must exceed the supplied shipped Mac 2.3.1 and mobile 1.0.3; Config still has the older upload-time values and was not bumped. Future App Store News notes/screenshots and review/upload remain unfinished. CI does not automatically publish a release; Mac and App Store releases are separate flows.

Read-only fetch found `origin/main` at `60823b495bed4ccb9abb78c451265c524edbab33`, one merge descendant of HEAD with an identical tracked tree. GitHub Mac v2.3.1 is public. App Store 1.0.3 remains supplied handoff context, not fresh portal verification. No main update was attempted.

## Preservation and review boundary

The initial 79-file hashes, final full inventory/hashes and tracked/incremental diffs bind source independently of mutable branch names. Only the two Swift repairs and documentation were changed in this pass. Earlier evidence remains. Native fixture input hashes remain checked separately; unsigned simulator standard preference/News files and Mac News/preferences hashes are compared without exposing contents. Four live Mac usage/history/ledger hashes changed while the already-running `/Applications/Tokenroom.app` process (started before this task) continued operating. This confounds a whole-storage unchanged assertion: do not claim production usage storage preservation proved. Signed App Group storage was not measured. No production app was replaced/stopped, login Keychain touched, provider authentication requested or release script run. Task-owned fixture apps were stopped; evidence/DerivedData/simulators are retained for follow-up.

Final review, whitespace, inventory and preservation results are retained in `final-review.md` and `final-state.json`. No source/test success implies signed delivery or release readiness.
