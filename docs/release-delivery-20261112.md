# iPhone 1.3.2 (1) — App Store submission, 12 November 2026

Checkpoint at 17:22 UTC: **iPhone, widgets and Apple Watch 1.3.2 (1) is Waiting for Review**,
with automatic release after approval. This is an accepted App Review submission,
not public availability. The distributed version observed in App Store Connect was 1.3.0.

## Source and gates

| Item | Evidence |
|---|---|
| Freshness correction | #66, merged as `ccb0cb76516a66f7cc604f4316e0b72617300817` |
| Release metadata | #67, head `5ad85324f1c89965680afcdaf7f344dbbe46582a` |
| Release merge | `7e5a94ff071c2054e963888d8ad8b89731df823e`; identical tree to the archived head |
| Mobile versions | iPhone, widgets, Watch and Watch widgets: 1.3.2 (1) |
| Mac | Version configuration unchanged at 2.6.1 (1); no new Mac release or installation |
| Checks | All seven final-head GitHub checks passed on both #66 and #67 |
| Local behavior checks | 1,024 Mac tests and 53 hosted iPhone tests passed; Shared typechecks and optimized fallback passed |
| Final version | Simulator build passed for all four mobile components |
| Independent review | Fresh-context review of the fix and release metadata found no blocking issue; #67 advisory review was clean |
| CloudKit | No new record type or field; no Production schema deployment |

The fix renews widget timelines for reconfirmed readings, retains reload decisions
across app relaunches, dates successful cloud reads separately from cache saves,
bounds recovery retries, and presents cloud readings before slower local checks finish.
The implementation and remaining device-timing limits are in
[the freshness decision record](ios-widget-freshness-20261112.md).

## Signed package and Apple receipt

The canonical signing MacBook Pro prepared a new Release archive and App Store Connect
export using the existing authorized automatic-signing setup. All four exported
components passed Distribution signature/profile, bundle/version, entitlement and
executable UUID checks. Verification included Production iCloud, the source-defined
App Group/Keychain roles, production push where required, no `get-task-allow`, and
`ITSAppUsesNonExemptEncryption = NO`.

- Upload succeeded: **17:18:04 UTC**, 12 November 2026.
- Apple processed and validated **1.3.2 (1)**, with symbols included.
- Apple build: `4d5409e9-9b8d-459e-98a5-58c9208326e2`.
- App Review submission: `ec2c67bc-b06c-4788-bb47-c7973deeb75c`.
- Submission accepted around **17:22 UTC**: “1 Item Submitted”, then **Waiting for Review**.
- Release mode: **automatic after approval**.
- Exported IPA SHA-256: `78fc03035fd98e1c8af0bb4576e992afa479fa10381a6447d1e20986302b4c0c`.

Artifacts remain on the canonical MacBook under
`~/Library/Developer/Xcode/Archives/Tokenroom-1.3.2-20261112/`:
`READINESS.md` holds the complete receipt and source hashes,
`export/TokenroomMobile.ipa` is the verified export, and
`TokenroomMobile.xcarchive` retains the archive and dSYMs.
Credentials were not copied between machines or added to the repository.

## Store metadata and the earlier draft

The live private portal resolved a discrepancy in the older source notes:
**1.3.1 was an unsubmitted Prepare for Submission draft**, not a version waiting for
App Review. Its build had been uploaded on 7 November; upload did not submit the draft.
The draft was updated to 1.3.2, without withdrawing an active review submission.

The submitted What's New combines the previously unreleased 1.3.1 changes with the
freshness correction: News cadence/sources/offline handling, retained Skills lists,
Watch/widget/Live Activity sync and sign-in recovery, and removal of Claude sign-in
from iPhone. The existing screenshots, review information and privacy metadata were
preserved. [The listing](app-store.md) records the combined submitted text.

## Remaining external step

Apple must review and approve the submission; publication is configured to follow
automatically. Approval and public App Store availability were not observed at this
checkpoint. Physical private-iCloud delivery and locked-device WidgetKit timing remain
unverified integration limits; signed checks, tests and Apple's processing do not
establish those effects.

This receipt changes no compiled input, package byte, version or uploaded build.
