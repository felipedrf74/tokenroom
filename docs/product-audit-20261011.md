# Tokenroom product and code audit — 11 October 2026

Historical initial product/source audit. Later fixes and execution supersede its findings and coverage limits; see [current release checks](news-release-checks-20261011.md) and [completion audit](news-redesign-completion-audit-20261011.md). The original audit below is retained as evidence.

The biggest gains come from helping people avoid a limit, trust the reading, and recover a disconnected collector. The urgent-window branch addresses the first two, but the review found regressions that needed correction before shipping it.

Reviewed `tokenroom/urgent-window-projected-pace`, based on `adbb201`, including its existing uncommitted changes. Work continued in the improvements checkout. Nothing was committed, pushed, installed, or released. Release facts in the handoff were treated as supplied facts; App Store and GitHub release state were not independently checked.

## Changes made during this review

| Priority | Reproduction / defect | Result |
| --- | --- | --- |
| P1 | A weekly window projected to run out in two days beat a session projected to run out in 90 minutes because relative severity bands preceded chronological run-out. | `UsageRanking.leadWindow` now selects reached limit, then earliest run-out, then percent. Primary provider-card headlines and the severity-based Highest policy remain as specified. |
| P1 | A collector measured no run-out, relayed `RelayPace(runsOutAt: nil)`, and the stale reader invented one from older hourly history. | An explicit no-run-out measurement stays authoritative. |
| P1 | Stale fallback combined an older sample's date with the newer displayed percentage, moving the forecast earlier. | Fallback evaluates the last sample's own time and percentage. |
| P2 | Watch complications still drew the primary window while phone widgets and Watch rows drew the urgent one. | Usage complication families use the shared lead window and their presentation date. Primary Mac captions and circular-widget accessibility explicitly describe their drawn window. |
| P2 | A stale spend-budget window raised a subscription run-out alert, including when balance alerts were off. | Money windows are excluded from subscription run-out rules. |
| P2 | A projected alert remained urgent two hours after its forecast, or failed to become urgent while waiting through quiet hours. | Pending projections recompute the strict one-hour urgency bounds before quiet-hour filtering. Live alert bodies remain unchanged. |
| P2 | A reset moved across an alert-ID rounding bucket, producing another run-out for the same logical window. | The local ledger retains the logical run-out instance across pending/delivered persistence and reset drift. An actual new window re-arms it. |
| P2 | Phone and widget claims could both succeed for a provider with no minimum interval. Timestamp-only restoration could also erase a newer claim at the same date. | A claim returns a receipt with an atomic prior attempt, unique ownership, and an in-flight process/file lease. |
| P2 | Releasing that lease at timeout, or before the caller persisted a 429, permitted another physical request or lost Retry-After. | The detached worker retains the lease through physical completion and writes its result's cooldown before release. Cancellation restores only its owned attempt; a key reset fences old cooldown writes. |
| P2 | An open iPhone detail became blank after its provider disappeared through removal, account change, or aging. | A missing-reading explanation remains on the detail destination. Rendering remains unverified. |
| P2 | The Mac settings summary said Sending whenever sync was enabled, even when unavailable, paused, failed, or waiting. | The summary reflects the actual relay state. The existing detailed error remains in the same settings page. Rendering remains unverified. |

The README now reflects the supplied shipped mobile status and uses the latest Mac release link without naming an obsolete archive. The changelog and both repository skills describe the final behavior. Version numbers were not bumped.

Relevant implementation: [Pace](../Shared/Core/Pace.swift), [ranking](../Shared/Core/UsageRanking.swift), [alerts](../Shared/Core/Alerts.swift), [fetch gate](../Shared/Core/KeyFetchGate.swift), [physical completion](../Shared/Core/TokenroomHTTP.swift), [phone collection](../TokenroomMobile/MobileStore.swift), [widget collection](../Shared/Widgets/WidgetRefresher.swift), [Watch complications](../TokenroomWatchWidgets/TokenroomWatchWidgets.swift), [phone navigation](../TokenroomMobile/UsageView.swift), and [Mac settings](../Tokenroom/Views/SettingsView.swift).

## Highest-impact next work

These are product priorities inferred from the existing flows, rather than measured conversion or retention results.

| Order | Improvement | Why it matters | Scope / effort |
| --- | --- | --- | --- |
| 1 | Direct recovery from disconnected providers | Phone disconnected rows explain the problem but require finding the provider again in Settings. An expired phone key should open that key's editor; Mac-only tools should explain which collector needs attention; entitlement errors should retain their distinct remedy. | Small. Reuse the existing key editor and settings routes. |
| 2 | Confirm the first reading during setup | Connect Mac closes and marks onboarding complete before its refresh answers. Show whether a real Mac reading arrived, with Check Again and Continue Later. Surface actionable sync failure in the Mac popover as well as settings. | Small to medium. Use existing relay state and collector metadata. |
| 3 | Show another usable plan beside an approaching limit | Urgency currently tells the user where they may get blocked. Showing another connected plan's fresh headroom and next reset helps them act. Let users choose suitable substitutes; do not treat percentages from different plans as equivalent capacity. | Medium. Build on shared ranking and existing readings; no account or credentials move. |
| 4 | Keep references attached to their currency | A Moonshot China key can initially show Reference (USD), then interpret the saved number as CNY. Replacing a regional key can similarly reinterpret an old reference. Persist the reference's unit, label the selected region correctly, and require an explicit choice when the currency changes. | Medium. Coordinate Mac/phone budget persistence, relay application, and widget consumers. |
| 5 | Make optional News relevant to connected tools | Initial follows include the full source catalog. Offer an explicit Follow my connected tools preset while preserving manual follows and Show All. | Small. Reuse provider/feed mappings. |

Evidence for these priorities: [disconnected rows](../TokenroomMobile/UsageView.swift), [Mac setup](../TokenroomMobile/OnboardingView.swift), [key/reference editor](../TokenroomMobile/MobileSettingsView.swift), [budget application](../Shared/Core/Budget.swift), [Moonshot parsing](../Shared/APIKeys/APIKeyParsers.swift), and [News defaults](../Shared/Core/NewsStore.swift).

After these, a weekly utilization summary from existing local history could add value. Broad restructuring of `MobileStore` should follow a concrete collection or sync need; this audit does not justify rewriting the architecture. Keep the current local-first collectors and private usage-only relay.

## Remaining defects and limits

- **Source-confirmed, unmodified:** the Moonshot reference/currency mismatch above. The actual editor interaction was not exercised.
- **UNCONFIRMED runtime behavior:** `FollowButton` refreshes its cached following state only on appearance and local taps. An ActivityKit dismissal or automatic ending may leave Stop Following displayed until the view refreshes. Validate foreground/dismissal/reset behavior before choosing an observation fix.
- **Cross-device alert identity remains open:** the ledger fix prevents repeats on one device, including relaunches. Independent collectors can still create different exact IDs if their first reset measurements fall in different rounding buckets. Production CloudKit deduplication was not tested.
- **Device acceptance remains open:** signed App Group access, real iCloud account transitions, phone-to-Watch delivery, notifications/quiet hours, widget timing, Live Activity dismissal, VoiceOver, and rendered urgent-window labels.
- The shipped `60823b4` object was not present in this checkout. This review binds to its local `adbb201` base and final uncommitted files, and does not claim an exact source comparison against the shipped artifact.

## Verification

| Check | Result / boundary |
| --- | --- |
| Mac XCTest after final code edits | **628 tests, zero failures.** Eight tests were explicitly excluded because they read/write real Keychain items. This is not an unrestricted full-suite pass. |
| Shared Swift typechecks | Passed for macOS, iOS, and watchOS. An earlier run was invalidated by an edit during compilation; the final stable-source run passed. |
| iPhone simulator build | Passed, including widgets, Watch app, and complications. Signing disabled; no installation or normal app launch. |
| Two-process fetch lease | Passed using actual final `KeyFetchGate.swift`, inert provider types, a throwaway defaults suite, and a temporary shared folder. A second process was excluded while the first held the lease; releasing allowed the next check. This does not prove signed iOS App Group integration. |
| Regression evidence | Forecast/ranking, projected alerts, reset-drift deduplication, and overlapping fetch behavior failed under their prior implementations and passed after correction. Timeout/cancellation, same-timestamp ownership, late 429, and key reset fencing passed integrated XCTest. |
| Diff | `git diff --check` passed. |

New regression files: [CompactSurfaceTests](../TokenroomTests/CompactSurfaceTests.swift), [AlertProjectionRegressionTests](../TokenroomTests/AlertProjectionRegressionTests.swift), and [KeyFetchConcurrencyTests](../TokenroomTests/KeyFetchConcurrencyTests.swift).

Excluded tests: `APIKeyTests/testKeyStoreRoundTripShowsOnlyTheLastFour`, `APIKeyTests/testAKeysWarningIsKeptWithIt`, `APIKeyTests/testReplacingAKeyStartsFromTheChoiceSavedWithIt`, `APIKeyTests/testMissingKeyReadsAsSignedOut`, `CodingPlanTests/testAPastedKeyWinsOverOneFoundOnTheMac`, `CodingPlanTests/testAnExpiredLocalLoginReportsExpired`, `MobileLogicTests/testNoKeyMaterialReachesAnyRecord`, and `RequestTests/testCopilotFallsBackToAPastedTokenOnlyWhenTheLoginCantBeUsed`.

No real provider/auth hosts or login Keychain were accessed. The Mac app ran only as an idle XCTest host with stubbed collectors. `scripts/build.sh` was not run. All DerivedData stayed outside the checkout.
