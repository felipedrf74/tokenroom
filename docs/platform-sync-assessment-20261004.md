# Tokenroom platform sync assessment

Assessment date: 4 October 2026. This describes the local implementation and its remaining acceptance work. It does not establish installation, TestFlight distribution, App Store submission, or release.

Tokenroom already supports collection without a Mac for providers the iPhone reads with its own API keys. The Watch reads the private CloudKit relay directly, so transporting a published reading does not require either the Mac or a nearby iPhone. Mac-only login providers still need an operating Mac collector. The changes below improve freshness, isolation, and recovery within that architecture; they do not promise continuous background collection on Apple platforms.

## Collection and transport

| Platform | Collects provider usage | Reads and shares usage |
| --- | --- | --- |
| Mac | Existing tool logins and supported provider keys | Publishes its own Source and History in private CloudKit |
| iPhone | Supported provider keys in its device-local Keychain | Reads every collector; publishes its own Source and History; hands readings to the paired Watch |
| iPhone widgets | Supported phone keys when permitted by shared spacing and deadlines | Reads CloudKit and the phone cache; saves readings and queued history locally; never writes CloudKit |
| Watch and complications | No keys or login sessions | Reads CloudKit directly and a durable local cache; Watch also receives the paired phone cache |

There is no Tokenroom backend account or server. Provider credentials stay with their collecting device. `PhoneConnect.productionAllowlist` is empty: the prepared phone session infrastructure does not enable production OAuth collection for Mac-only providers. See [the session assessment](session-security-assessment-20261004.md) and [the phone collector design](iphone-login-without-a-mac.md).

## Implemented reliability changes

- A Watch refresh can ask a reachable paired iPhone to collect, while independently reading CloudKit. The message carries only a fixed refresh request; the reply carries the readings cache and the existing connect availability flag.
- The phone reply has a 15-second waiting budget; the Watch waits at most 16 seconds for that transport. Timing out the reply no longer cancels the phone collection. Successful key checks can finish and reach the saved cache after the Watch has stopped waiting.
- Handover selection reconciles the retained payload with the newest saved phone cache. An unchanged amount no longer forces a Watch pull to use the last material-change timestamp. Each provider keeps its measured `checkedAt`; cache save time is never substituted for a successful check.
- A phone cache carries its exact local collector envelope, including an empty membership after removal. A successful complete cloud read carries its raw collector envelopes and completion time. Reconciliation keeps the newest envelope for the paired phone while the newest complete cloud snapshot controls every other collector. An unpublished phone-only provider therefore survives a later cloud read, and newer local or published removals cannot be revived by an older snapshot.
- These optional cache fields use existing anonymous collector record IDs, with the local snapshot scoped to the phone's cache generation. They add neither credentials nor Apple/provider account identities and require no CloudKit schema field. Prior-format caches still decode and retain their established whole-cache membership policy until both inputs carry exact provenance.
- Phone caches carry a local account generation. App, widgets, and handover reject previous-generation files and late writes, including when clearing a file fails. A widget refresh also rejects a previous cache captured before its current generation.
- Watch refreshes requested during another refresh coalesce into one follow-up. Clock rollback does not suppress foreground refreshes indefinitely. Confirmed CloudKit sign-out hides the old account immediately rather than waiting for an unrelated phone reply.
- The Watch handles SwiftUI WatchConnectivity background tasks by reconciling received context and scheduling its next normal refresh. Sample data and unreadable/newer cache formats cannot replace its real handover data.
- CloudKit reads use a complete in-memory zone snapshot and subsequent change tokens. Failed or cancelled reads do not commit partial pages or a stale abandoned result. Phone local notification requests retain retry state when scheduling fails.

Source entry points: [WatchHandoff](../Shared/Core/WatchHandoff.swift), [WatchLink](../TokenroomMobile/WatchLink.swift), [WatchStore](../TokenroomWatch/WatchStore.swift), [ReadingCache](../Shared/Core/ReadingCache.swift), [RelayReadings](../Shared/Relay/RelayReadings.swift), [MobileStore](../TokenroomMobile/MobileStore.swift), [PhoneCacheAccess](../Shared/Core/PhoneCacheAccess.swift), [WidgetRefresher](../Shared/Widgets/WidgetRefresher.swift), and [RelayZoneReader](../Shared/Relay/RelayZoneReader.swift).

## Remaining structural gaps

Mac-only subscription readings cannot become current while their Mac collector is unavailable. A future implementation needs a supported provider usage API or authorized phone authentication flow; copying existing CLI sessions to the Watch is not an implementation of that feature.

Watch notifications currently follow the companion iPhone's delivery and mirroring behavior. The Watch has no independent push/event subscription or notification permission flow. Phone-off Watch alerts would require a separate delivery design with cross-device deduplication and provisioning validation.

CloudKit silent pushes, Watch background refreshes, and WidgetKit redraws are controlled by the operating system. They can be delayed. Provider minimum call intervals and rate-limit cooldowns also apply to an explicit Watch refresh. “Latest” means the most recent successfully collected reading, with its age and failure state visible; it does not guarantee a new provider request on every platform at every moment. Apple documents these constraints in [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity) and [Watch background scheduling](https://developer.apple.com/documentation/watchkit/wkapplication/schedulebackgroundrefresh(withpreferreddate:userinfo:scheduledcompletion:)).

## Verification and device acceptance

Nine pure handover/refresh-policy XCTest regressions passed in a standalone macOS harness after six baseline tests produced seven failed assertions. Ten source-provenance regressions cover unpublished membership, local and published deletion, unrelated-source deletion, fresher own readings, history retention, generation separation, two complete cloud snapshots without a phone snapshot, and actual prior-format JSON with optional keys absent. The first five exposed ten failed baseline assertions before the fix. A separate async regression confirmed that a timed-out reply lets its phone collector complete: the baseline cancelled collection; the corrected helper does not. Swift 6 source typechecks passed for the full Watch target with read-only relay compilation and for Shared plus the iPhone WatchLink. Integrated root builds and test results belong in the final validation record.

Paired-device acceptance still needs:

1. The same Apple Account and CloudKit environment on every participating device: development-signed builds together, or production Mac with TestFlight/App Store phone and Watch builds. Confirm real container, App Group, and Keychain entitlements.
2. With the Mac closed, a supported phone key provider updates on iPhone, its widgets, Watch, and complications. Compare each provider's check time and value, not only the cache save date.
3. With the phone away, Watch CloudKit refresh reads already-published usage. Document the expected age of Mac-only providers.
4. An unchanged usage recheck advances the Watch's reported check time after a Watch pull. A lost phone reply returns within budget while collection can finish afterward. A phone-only reading not yet published survives a newer complete cloud read; a later empty local/published membership removes it; deletion of an unrelated cloud collector stays deleted after a delayed phone handover.
5. Sign-out and Apple Account switching clear prior-account readings immediately, across a living app, widget process, Watch app, and complications. Retained files and delayed old-generation callbacks cannot reappear.
6. Refresh during an existing refresh, reconnect, Watch installation or switching, and incoming context while suspended recover without duplicate or permanently dropped refresh work.
7. Notification permission denied/enabled, a failed local notification schedule, quiet hours, and mirrored Watch delivery behave as described. Source/test success does not prove physical notification delivery.
8. Reset, one-hour staleness, seven-day expiry, and complication/Smart Stack changes remain honest when the operating system postpones background work. Record actual device timing separately from requested scheduling dates.
