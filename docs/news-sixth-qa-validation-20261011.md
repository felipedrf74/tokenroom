# Sixth independent QA and P2 remediation — 11 October 2026

Checkout: `/Users/felipedominguez/Developer/tokenroom-improvements-20261004`, branch `tokenroom/urgent-window-projected-pace`, HEAD `adbb201fb82e235bee9422e06a7e1208cc4736a9` plus the complete uncommitted tree. Felipe authorized fixing the three remaining QA5 P2 findings, relevant tests and fresh independent QA. Commit, main push and public distribution require **all release checks to pass**. No commit, push, version bump or release occurred.

## Findings and implemented contracts

| Finding | Correction and observed result |
|---|---|
| QA5-01 Mac reader return | `NewsNavigationLink` adds Back/Command-[ and shared Check Now/News Settings commands to actual pushed destinations. Direct split-view roots remain clean; iOS keeps native navigation. Back pops one level and preserves parent queries/read state. Repeated external requests reset the outer split identity while retaining library/Skills stores. Three hosted toolbar tests pass. The inert production-shaped native fixture witnesses story/model/skill/Saved/source/collection/voice/recovery routes, click/keyboard Back, query retention/source reset, one toolbar command set, mocked command dispatch and repeated Today requests. |
| QA5-02 reference currency | `BudgetReference` binds amount and USD/CNY. All application consumers use typed APIs; naked-number convenience APIs live only in test targets. Editors label the proposed region, preserve different/unknown saved references and require explicit replacement or Clear. Unresolved/mismatched reference cache meters are removed, with raw balances/provider-owned meters retained. Known USD-only legacy references migrate; ambiguous Moonshot/DeepSeek references stay inactive until explicit entry. Mac/phone/widget/Watch paths enforce the guard. |
| QA5-03 reset identity | Updated writers coordinate one stable private `Prefs` payload per provider/window/alert key with atomic revision-checked ownership + Event creation. Immutable reset anchors tolerate less than 30 minutes of jitter, while distinct levels/windows remain separate. Reset ownership uses the ended reset, independently of the next displayed reset. Threshold, run-out, reset and reset-bound low-balance alerts participate. Existing Events are adopted without notification aliases. Current alert tests and broad suite pass; signed two-device delivery is unverified. |
| QA6 monetary-history runway | Independent QA found USD and CNY samples sharing a bare `balance` history. Optional `amountUnit`/`amountCheckedAt` provenance now clears only monetary samples on unit transition, rejects older opposite-currency samples and persists the newest fence even for the same balance/hour. Legacy ambiguous histories cannot seed another unit's forecast; known USD-only histories migrate. Disk/widget-pending/relay routes share the policy. Forecasts require a matching unit. Seven dedicated history regressions and final integration suites pass. |
| QA6 unchanged-snapshot reset | The first broad run found budget normalization replacing a valid top-level reset/headline even when the primary window was unchanged. Aggregate normalization now occurs only when that window actually changes. The resting-provider regression and final broad suite pass. |

Previous QA4 queued preferences, full transitive Unsave/exact batch Undo, complete Mac paired-family search/query reset, app-owned XCTest storage/effects isolation and multi-group folding remain covered by the current suite. `qa6-independent-plan-final-review.md` confirms every previous finding fixed and no remaining confirmed P0–P2 or missing source implementation item within its review scope. `independent-alerts-currency-review.md` independently confirms the alert/reference/history/reset corrections. Both retain reviewed-file hashes and separately conclude acceptance incomplete/public release NO_GO. Source review and executable receipts are separate authorities. The [updated independent QA prompt](news-redesign-qa-prompt-20261011.md) was run read-only against this final tree.

## Compatibility and failure behavior

Cloud coordination uses existing `Prefs.payload`, Event fields/names and subscription; no new record type/column or alias Event. Old preference readers consume only `prefs-alerts`. Exact and bounded neighboring legacy Events are validated and adopted without rewriting them. Legacy instance IDs count 600-second units, including hourly multiples of six; optional reported periods preserve reset-rounding migration. Reset presentation still names the next reset, while ownership names the ended reset.

Ownership retains pushed/shown mode beyond Event pruning for active monthly windows. Conflict retry rereads the revision and is bounded to three attempts; atomic sibling failures prioritize the actual revision conflict. Damaged/unsupported/capacity payloads fail closed and leave delivery pending. Cancellation/account epochs are fenced throughout, including final receipt return. Missing zones invalidate cached readiness; write-time disappearance retries with a fresh revision. `userDeletedZone` is not recreated.

**Rolling-upgrade limit:** old writers bypass coordination and can create an adjacent-bucket Event after new ownership. Updated-writer guarantees do not apply to mixed old writers. Nil-reset balance and banked alerts keep legacy exact-ID/day/count semantics. No login, secret, account identity or News metadata enters ownership.

`budgetReferences` atomically binds amount+unit; `budgets` remains a numeric compatibility mirror. Disagreement after a downgraded/partial write becomes unresolved. No conversion is performed. Amount-history metadata is optional usage-only data in the existing History payload. Old readers ignore it and cannot enforce currency safety. Currency binds units, not account identity: same-currency key/account replacement retains existing local references/history. Cached collector-owned references remain collector-owned.

## Current executed checks

All final automated commands below completed after production/test source was frozen. DerivedData is external. Exact commands, source inventories/hashes, whole/incremental diffs, logs, xcresults, native fixtures/captures and negative attempts are retained privately at:

`/Users/felipedominguez/Documents/ChatGPT/TokenRoom/news-implementation-20261011/qa6-p2-fixes-20261011T180955Z`

| Check | Current result / artifact |
|---|---|
| Safe Mac suite | **758 tests, zero failures**, `logs/mac-tests-final.log`, `mac-tests-final.xcresult`, `/tmp/tr-qa6-full-mac-dd` |
| Selected hosted iOS | **14 tests, zero failures**: five MobileRuntime, five isolated currency, four mocked notification/account scheduling cases; `logs/mobile-tests-final.log`, `mobile-tests-final.xcresult`, `/tmp/tr-qa6-final-ios-dd` |
| Shared checks | macOS/iOS/watchOS typecheck passed, `logs/typecheck-shared-complete.log` |
| Unsigned Release Mac | Build passed, `logs/mac-release-build.log`, `/tmp/tr-qa6-release-mac-dd` |
| Unsigned generic iOS Simulator Release | Build passed including widgets/Watch, `logs/ios-release-build.log`, `/tmp/tr-qa6-release-ios-dd` |
| Direct Swift 6 fallback compile | Passed, `logs/fallback-compile.log`; external executable retained, never launched/installed. Existing credential-reader deprecation warnings remain; compilation does not execute Keychain code. |
| Mac native navigation | Passed within inert AppKit/SwiftUI fixture, `mac-navigation-fix-report.md`, guarded hosts and source-hash receipts. Unit tests establish toolbar presentation; native interactions separately establish actual navigation. |
| Cross-process fetch lease | Production gate passed HELD → overlapping BLOCKED → RELEASED → new CLAIMED in an external synthetic directory/defaults suite; `fetch-cross-process/result.json`. Signed App Group placement remains unproved. |

Eight known login-Keychain Mac cases are explicitly **excluded**, not passed:

- APIKeyTests/testKeyStoreRoundTripShowsOnlyTheLastFour
- APIKeyTests/testAKeysWarningIsKeptWithIt
- APIKeyTests/testReplacingAKeyStartsFromTheChoiceSavedWithIt
- APIKeyTests/testMissingKeyReadsAsSignedOut
- CodingPlanTests/testAPastedKeyWinsOverOneFoundOnTheMac
- CodingPlanTests/testAnExpiredLocalLoginReportsExpired
- MobileLogicTests/testNoKeyMaterialReachesAnyRecord
- RequestTests/testCopilotFallsBackToAPastedTokenOnlyWhenTheLoginCantBeUsed

Other hosted mobile cases compiled but were not selected. XCTest app roots use isolated storage/mocked keys/nil CloudKit/inert effects; explicitly injected scheduling tests preserve their tested semantics. Unsigned selected tests emit entitlement diagnostics, which do not establish signed App Group behavior. The Mac suite succeeds despite the test-host exit-barrier diagnostic; no test failure is hidden.

The initial broad Mac run executed 749 with one unchanged-snapshot failure. That failure, history/legacy/cold-cache/reset-kind/navigation reds, harness/AX limitations and overlapping-input compile attempts are retained and never counted green. Targeted final history/reference follow-up passed 53, and final navigation passed three; the broad 758 run includes the final regressions. QA5 actual elapsed localhost Skills streaming and iPhone narrow/largest-dark/actions remain historical evidence for unchanged code; they were not rerun and prove neither signed/iOS transport nor complete current UI acceptance. Private diagnostic bundles must not be published wholesale.

## Remaining acceptance and release gates

**Source repairs complete; acceptance incomplete; public release NO_GO.** No confirmed source finding is knowingly deferred. The [completion audit](news-redesign-completion-audit-20261011.md) maps every T1–T7 step/eight spec bullets and leaves missing acceptance explicit.

`Config/Local.xcconfig` is absent; team/profile/notary configuration is not established. Standing instructions prohibit login-Keychain/provider authentication. No signed Production-iCloud Developer ID archive, notarization/staple/Gatekeeper receipt or signed mobile device/App Store artifact/upload/App Review exists for this tree. These distribution checks cannot be completed without signing setup and external release evidence.

Real two-device CloudKit CAS races (both winner modes, legacy adoption, rolling upgrades), subscription/notification delivery, signed App Group/flock placement, paired iPhone/Watch/iCloud acceptance and native currency-editor/provider region changes remain unverified. Physical VoiceOver/focus is unverified; the Mac fixture sometimes reports window focus after return. Runtime Reduce Motion and complete current largest-text/persistent-link/error/recovery journeys still need dedicated native/device acceptance. Helper tests and unsigned builds cannot satisfy these requirements.

New versions/builds must exceed shipped Mac 2.3.1/mobile 1.0.3. Old upload-time Config values stay unpromoted until qualification. Draft future News store notes exist; signed screenshots/upload/review do not. Main push does not automatically distribute these releases. The Nexus release workflow is irrelevant.

No build/install or release script, production app replacement, provider auth, login Keychain access, destructive cleanup, commit, push or public release occurred. Task-owned native fixtures are stopped; external evidence is preserved. Existing production usage storage may change as its already-running app operates; whole-production-storage invariance is not claimed.
