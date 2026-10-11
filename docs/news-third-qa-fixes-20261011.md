# Third News QA fixes — 11 October 2026

Historical closeout, superseded by the QA4 rerun. See [current fourth corrections](news-fourth-qa-fixes-20261011.md). Counts, evidence pointers and final-review conclusions below describe the QA3 snapshot only.

Checkout: `/Users/felipedominguez/Developer/tokenroom-improvements-20261004`, branch `tokenroom/urgent-window-projected-pace`, HEAD `adbb201fb82e235bee9422e06a7e1208cc4736a9` plus the entire dirty working tree. Felipe authorized direct fixes and final review, and explicitly prohibited tests and commits.

## Current status

The three confirmed P2 defects, both source gaps, two documentation gaps and the malformed Retry-After robustness concern from the QA3 rerun have source corrections below. There are **48 later added regression methods, all uncompiled and unexecuted**: the prior 34 plus 14 in `NewsThirdQAFixTests`. Existing News test constructors and two Skills concurrency cases and fixed-date badge assertions were also amended; their current versions need compilation/execution. Historical green runs predate these corrections. This is a source disposition, not runtime or release acceptance.

No tests, test compilation, typechecks, builds, app launches, UI exercises, live probes, credential operations, commits, pushes, releases, version changes or cleanup occurred. Only source/document review, file inventory/hashes and whitespace checks are permitted in this pass.

## Findings and source dispositions

| QA3 item | Source correction | Regression/check source |
|---|---|---|
| QA3-01 P2: Skills dispatch after Mac News disable | `NewsWindowView.init` binds a weak live owner policy before child tasks. `SkillsStore` checks permission/caller cancellation before presentation mutation, then checks request identity, live cancellation flags, worker cancellation, expiry and permission immediately before fetch. Fetch and the production GET entry share MainActor isolation; entry rejects cancelled work. Vetoed unissued work releases its slot without inventing a failure or modifying the cached shelf/cooldown. Already-issued results and authoritative late 429 remain request-owned. | Disabled entry/queued dispatch/re-enable, cancelled queued reader and already-cancelled caller sources. Native disable behavior remains unexecuted. |
| QA3-02 P2: all-invalid Skills page erases usable shelf | `SkillFeed.parse` rejects a nonempty input with no valid listing in the inspected first 30 records. Explicit empty, short and mixed pages remain successful; original provider ranks remain intact. Parse failure retains previous listings/check date and reports unreadable data. | Bounded-invalid/empty/mixed page and retained-shelf→explicit-empty sources. |
| QA3-03 P2: Atom XHTML title/excerpt lost | `FeedXMLDelegate` keeps the owning direct-entry field active across nested markup, collecting descendants only for title/excerpt fields. Scalar IDs/links/dates still use direct text. Nested author/card titles remain excluded. Markup boundaries separate words; excerpt accumulation has one 2,000-character bound. | XHTML text before/inside/after markup, separate dates/alternate links, prefixed Atom, RSS QName/CDATA, unrelated titles/scalar descendants, cumulative limit, successful feed refresh and broken-retry cache retention. |
| QA3-G01: per-reader budget can extend physical request | One monotonic absolute eight-second deadline and one shared answer task are created per physical request. Later readers observe the same answer/deadline. Expiry synchronously fences body publication, cancels physical work and stops progress. Completion also checks the absolute deadline if the timer callback is delayed. The physical slot remains until its worker ends; its UUID-matched late 429 still owns cooldown. | Joined-reader original deadline, noncooperative late body, retained physical slot, late 429 and delayed-timer sources use acknowledged gates/injected clock. They do not prove elapsed wall-clock URLSession behavior. |
| QA3-G02: manually constructed News tests keep production dependencies | All 25 omitted fetch/notifier arguments now explicitly inject dependencies. Every manually constructed News store in both test directories supplies preferences, cache, fetch and notifier. Four transport tests explicitly forward to `NewsFetcher` through installed ephemeral URLProtocol fixtures; other added dependencies are inert. Named temporary defaults domains are removed by teardown/defer. Root XCTest inert composition remains unchanged. | Static constructor inventory and source review; hosted app startup and actual transport isolation remain unexecuted. |
| QA3-D01: stale evidence pointer | Current documents point to this separate QA3 evidence package. `qa-fixes` and `qa2-fixes` are explicitly historical snapshots, not current hashes or runtime validation. | Separate before/after copies, inventories, hashes and final review record. |
| QA3-D02: stale Show More description | Settings/Usage/News validation now describes the complete retained model collection and search. | Compared with `NewsReaderContent`; no native layout run. |
| Retry-After robustness | Skills-local validation rejects nonfinite dates and dates beyond the existing year-9999 metadata ceiling, falling back to 15 minutes. Valid delta/date directives remain authoritative; zero/past directives permit immediate eligibility. Shared provider HTTP behavior is unchanged. | Invalid/missing/huge directives, valid delta/future date, zero/past date sources, plus late-429 deadline case. |

The fresh final reviewer confirmed one additional P2 in the prior News enablement fix: permission returned from MainActor before a generic-executor GET entry. `NewsFetcher.permittedGet` now checks the live predicate/cancellation on MainActor immediately before calling the same-actor transport entry. Veto returns nil and preserves cached check/failure state. A direct transport-veto/cache-retention regression source was added.

The final reviewer also confirmed a source-validation defect: fixed September News badge assertions now incorrectly use wall-clock recency and fail after the 14-day cutoff. `NewsStore.unseenCount(now:)` shares an explicit render date with the model count, and Feed/NewsLive assertions use their fixture dates. The archive regression additionally checks the combined count with supplied dates. These amended cases remain unexecuted.

## Regression source inventory

`NewsThirdQAFixTests` adds these 14 methods (none compiled or executed):

- `testAtomXHTMLKeepsDirectFieldTextAndSeparateDates`
- `testPrefixedAtomAndRSSKeepExistingScalarAndHTMLContracts`
- `testNestedExcerptHasOneCumulativeBound`
- `testXHTMLFeedRefreshKeepsUsableContentAndBrokenRetryRetainsIt`
- `testNewsTransportEntryVetoSkipsGETAndPreservesFailureState`
- `testAllRejectedBoundedSkillPagesFailButEmptyAndMixedPagesSucceed`
- `testMalformedSkillsRetainShelfAndDateThenExplicitEmptyClearsThem`
- `testDisabledSkillsOwnerBlocksEntryAndQueuedDispatchThenReenables`
- `testCancelledQueuedSkillsReaderDoesNotDispatchOrInventFailure`
- `testAlreadyCancelledSkillsCallerDoesNotCreateARequest`
- `testJoinedReadersShareOriginalDeadlineAndRejectLateBody`
- `testExpiredPhysicalSlotRetainsAuthoritativeLate429`
- `testAbsoluteDeadlineRejectsBodyEvenBeforeTimerCallbackResumes`
- `testInvalidSkillsRetryAfterFallsBackAndValidDirectivesRemainUsable`

All 43 manually constructed News test stores now supply every dependency explicitly; 25 constructors needed amendments. The four forwarding transports remain fixture-bound.

The older cancellation regression now uses acknowledged gates and a captured physical task instead of blocking MainActor on a semaphore. The early injected-timeout regression waits until physical dispatch before expiring its reader; this preserves its intended already-issued late-429 contract under the new preflight gate. Fixed yields in older News follow cases and all actual native/executor scheduling remain validation limitations.

## Evidence and preservation

Current evidence package: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/news-implementation-20261011/qa3-fixes-20261011T152913Z`. `baseline.json` and `before/` preserve the 67-path starting dirty snapshot; `supplemental-before.json` binds the initially clean Foundation/NewsLive test files to exact HEAD before contents; `after-hashes.json`, `after/` and `working-tree-inventory.json` describe the final complete dirty tree. `incremental.diff` attributes this pass separately from adjacent uncommitted work. `final-review.md` and `execution-ledger.md` record review findings/rulings; hashes are source evidence only.

Historical QA report: `qa3-rerun-20261011T142808Z/qa-report.md` under the same parent evidence root. Historical first and second fix packages remain intact. No protected usage/pace/alerts/key-fetch/relay/Watch/version path is intentionally changed in this increment.

## Final review disposition

A fresh reviewer read the whole tracked/untracked working tree and current fix increment. It confirmed all QA3 source corrections and found two further actionable defects: the News transport permission hop and date-sensitive existing badge assertions. Both are corrected in source and re-read by that reviewer. It also caught documentation identifier substitutions from a count update; exact current/historical SHAs are restored and compared with immutable before copies. No further confirmed actionable source defect was reported after those corrections. Final evidence/whitespace/preservation closeout accompanies this report; current executable validation remains unfinished under the explicit no-tests instruction.

## Remaining validation

Current production/test compilation; all 48 added methods and amended existing cases; affected and broader suites with the eight historical Keychain exclusions; shared platform checks and unsigned builds; actual eight-second elapsed streaming/cancellation; hosted inert XCTest startup; disabled→queued→enabled Mac interaction; native collection/save/undo/navigation; narrow/largest text, light/dark, Reduce Motion and physical VoiceOver remain unverified and prohibited in this pass. Live feed/registry availability, signed App Group/flock, notifications, iCloud, paired Watch and distribution are separate acceptance boundaries. No original requirement is waived.
