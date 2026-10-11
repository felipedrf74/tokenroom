# News QA fixes — 11 October 2026

**Historical first QA fix pass.** Its no-further-gap conclusion was superseded by the second independent QA. See [the current stabilization report](news-second-qa-fixes-20261011.md) for the five additional P2 fixes, three Minor corrections, 12 further regression sources and current review/validation disposition. The 22-case and 65-file counts below describe this earlier snapshot only.

Checkout: `/Users/felipedominguez/Developer/tokenroom-improvements-20261004`, branch `tokenroom/urgent-window-projected-pace`, HEAD `adbb201fb82e235bee9422e06a7e1208cc4736a9` plus the uncommitted working tree. This is the follow-up to the independent QA, authorized by Felipe: “Fix all confirmed bugs and source gaps from this QA, including XCTest isolation. Correct the completion docs and review the final diff before stopping. Don’t run tests or commit.”

## Current disposition

All nine confirmed P2 findings, the progress-state Minor, and the confirmed source/coverage gaps have fixes in source. A fresh final reviewer found an additional Skills cancellation ordering defect; the fix uses a synchronous lock-protected cancellation marker for each waiter. Final source and documentation review is complete; no further confirmed actionable source gap was found within the read-only boundary. **Current production changes and 22 added test cases are uncompiled and unexecuted.** Nineteen cases were added in this fix pass; three were added by the prior completion audit. Historical passing runs establish their recorded snapshot only.

No tests, typechecks, builds, app launches, UI acceptance exercises, network probes, credential reads, commits, pushes or releases were performed in this pass. No version bump or installed-app replacement occurred. Source inspection, file hashes and whitespace checks are the permitted evidence. Runtime acceptance is not 100% complete and no release verdict is given.

## Finding-to-fix mapping

| Confirmed QA issue | Source correction | Added regression source, not executed |
|---|---|---|
| Source retry overwrote a queued notification preference with default preferences | `NewsStore.retrySources` preserves `lastPreferences`, requests a non-notifying targeted retry, and the existing queue retains the latest real preference and notification intent. `NewsSourceHealth` calls that entry point. | `NewsQAFixTests.testSourceRetryPreservesQueuedNotificationPreferences` checks disabled notifications and custom quiet hours. |
| Old same-sort Skills waiter could replace newer data/check time or clear a newer cooldown | Only request-ID-matched physical `completed` publishes data/errors/cooldown before releasing its slot. Waiters cannot publish bodies. | `testOlderWaiterCannotReplaceNewerSameSortResult`, `testOlderSuccessfulWaiterCannotClearNewerRetryAfter`. |
| Well-formed HTML/non-feed XML was treated as a successful empty feed | `FeedParser` requires an RSS channel or Atom feed and accepts entries only in their direct feed container. Invalid XML content retains cached items; a failed initial zero-item response does not create a usable bucket. Valid empty RSS/Atom remains successful. | `testWellFormedNonFeedIsRejectedButEmptyRSSAndAtomAreValid`, `testNonFeedRetainsCacheAndInitiallyBrokenFeedDoesNotCreateUsableBucket`. |
| First voice/status archive could become New after an in-flight unfollow or an empty failed bucket | `NewsStore` normalizes the captured request sources and establishes silence from the absence of a previous successful check, independent of bucket presence/current follows. Publisher dates remain untouched. | `testUnfollowDuringFirstSuccessfulVoiceFetchStillEstablishesQuietBaseline`, `testFirstSuccessfulVoiceCheckAfterAnEmptyFailedBucketIsQuiet`. |
| Failed remove/resave could discard pending undo | Shared `NewsRemovalUndo` replaces the pending snapshot only after a successful removal and clears it only after a successful save/restore. Both story and Saved controls use it. | `testFailedRemoveAndResavePreservePendingUndo`. |
| Skills failure disappeared when returning to a still-fresh cached sort | Per-sort problems are retained independently of cached items/check date and restored by `presentSelection`. | `testSwitchingBackToFreshCacheKeepsItsLatestFailure`. |
| Today retirement shelf and See All used different follow scopes | `retiringModels(all:)` supplies both surfaces; default is followed labs, explicit All labs expands the collection. | `testRetirementScopeAndMacReleaseCountMatchDestinations`. |
| Mac updates pill counted voice/status items but opened official releases | `PopoverView` uses `unseenReleaseCount`; News's broader unseen count still includes followed voices/status. | Same scope/count case above. Native pill interaction remains untested. |
| Mac page request made while News was disabled was lost | Request observation lives on the outer enabled/disabled group and sets the requested page/search state, including an existing request on initial presentation. | Source inspection only; native disabled → request → enabled acceptance remains blocked. |
| Fresh-cache Skills re-entry cleared progress while a forced request remained active | Refresh joins an existing physical request before consulting cache. Progress follows live interested waiters. | `testFreshCacheReentrySharesForcedRequestAndKeepsProgress`. |
| Final reviewer: queued Skills completion could publish after the sole reader cancelled but before MainActor cleanup | `onCancel` marks the waiter synchronously under a lock; completion and progress consult live interest. A cancelled physical request retains its slot until completion; 429 remains authoritative regardless of waiter cancellation. | `testCancelledLastWaiterCannotPublishNonCooperativeBody`, `testCancellingOneWaiterDoesNotCancelAnotherLiveWaiter`, `testTimedOutWaiterKeepsPhysicalSlotAndLateRetryAfter`. The contention case exercises the contract; it does not prove every executor schedule. |

## Source and coverage gaps

- Collections now show source/model check state, unchecked counts, failures, progress and targeted recovery. Cold/valid-empty states can Check this collection; failures can Retry failed sources; empty collections link to Following. `NewsCollectionHealth`, `NewsCollectionHealthView` and `NewsStore.retrySources` provide shared iOS/Mac behavior. Targeted model retry honors the model ID without forcing other fresh feeds. Added `testCollectionHealthDistinguishesColdFailureAndValidEmpty` and `testTargetedModelRetryDoesNotForceOtherFeeds`.
- Mobile root News composition now calls `NewsRuntime.newsStore`. Without a snapshot, XCTest receives isolated defaults, no disk cache, an inert fetcher and a no-op notifier. Explicit snapshot directories remain supported without real requests; sample mode is still insufficient to suppress other collectors. Added `testTestHostNewsIsInertWithoutSnapshotAndDoesNotUseLaunchChoices`. Source inspection is not executed startup proof.
- Added `testReadEvictionKeepsSavedSnapshotAndReopens`: seed 5,000 dated read entries, add a new read, reopen, assert the oldest read entry is evicted while its saved snapshot survives. The bound is **5,000 read entries with alias sets**, not 5,000 distinct alias strings. Earlier executed library coverage did not assert this eviction contract.
- Added `testFractionalBooleanAndInvalidNumericMetadataStayUnknown` to explicitly cover fractional/boolean/negative/overflow/string metrics and invalid timestamp metadata. The existing parser already rejects them; execution remains blocked.
- Three prior audit additions remain unexecuted: observed five-update status history, profile-only follow isolation, and skill rank movement isolation (`NewsSourceContractTests`, `NewsDiscoveryTests`).

## Changed files in this fix pass

Production:

- `Shared/Core/Feeds.swift`, `NewsFeed.swift`, `NewsStore.swift`, `NewsLibrary.swift`, `NewsPresentation.swift`, `SkillsStore.swift`, `NewsRuntime.swift`.
- `Shared/UI/NewsReaderContent.swift`, `NewsReadingViews.swift`.
- `Tokenroom/Views/NewsWindowView.swift`, `PopoverView.swift`.
- `TokenroomMobile/MobileAppDelegate.swift`.

Regression source:

- `TokenroomTests/NewsQAFixTests.swift` — eleven cases.
- `TokenroomTests/SkillsQAFixTests.swift` — eight cases.

Documentation:

- This report, completion audit, validation, independent QA prompt, spec status and approved plan.
- `README.md`, `CHANGELOG.md`, both `.grok/skills/`, `docs/settings-usage-news-validation.md`, and an appended ruling in the ignored execution ledger.

The complete dirty-branch inventory includes pre-existing urgent-window, pace, alerts, KeyFetchGate, widgets/Watch and version/store-history work. This list describes this fix increment, not authorship of every dirty line. Those adjacent changes must remain intact.

## Plan and validation boundaries

All seven plan tasks and eight original specification acceptance bullets are mapped in [the corrected completion audit](news-redesign-completion-audit-20261011.md). Previously executed evidence is described in [validation](news-redesign-validation-20261011.md). The [updated independent QA prompt](news-redesign-qa-prompt-20261011.md) includes the current source changes, race schedules and startup boundary.

Blocked by the explicit no-tests instruction in this pass: compilation of changed production/new test sources; execution of affected regressions and broader integration suites; shared platform checks/builds; narrow-device, Reduce Motion, physical VoiceOver and interactive Mac acceptance; actual native collection recovery/startup behavior. These are unfinished validation requirements with a specific reason, not passed checks or permanently impossible work.

Live public feed/ClawHub availability and external X browser access remain unverified. Curated identity checks are dated catalog evidence, not current popularity rankings. The injected Skills deadline test checks result handling, not real eight-second elapsed timing. Signed App Group/flock, notifications, iCloud, paired Watch and distribution/store acceptance remain separate release boundaries. No new Tokenroom account, phone OAuth, social follow, News sync, skill install or skill execution exists.

## Evidence and final review

Before-fix copies/hashes are retained outside the checkout at `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/news-implementation-20261011/qa-fixes/before` and `before-hashes.json`; all 60 prior changed/untracked paths were captured without replacing earlier evidence. After-fix copies, hashes, full working-tree inventory, incremental diffs and final static review are retained in the same `qa-fixes` directory.

A fresh read-only reviewer inspected the whole dirty branch, including untracked source/tests and completion documents. The additional cancellation race was fixed and rechecked; a status-history wording mismatch was corrected to allow missing publisher dates. No further confirmed actionable source/documentation defect remains in that review. Root also reviewed the twelve-file production fix diff. Tracked and untracked whitespace checks are clean; 19 protected adjacent paths match the before-fix hashes; HEAD is unchanged. The final inventory contains 65 dirty paths (20 original paths changed, five newly dirty paths); the ignored ledger is retained separately. `final-review.md`, `static-checks.json`, `production-fix.diff`, `incremental-fix.diff`, `after-hashes.json`, `working-tree-inventory.json` and full after copies are retained outside the checkout. Prior 658-test/eight-exclusion, shared typecheck and unsigned build results predate this production fix pass and all 22 added cases. They must never be presented as validation of the current working tree.
