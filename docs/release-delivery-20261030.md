# Mac 2.5.1 and iPhone 1.2.1 — delivery record, 30 October 2026

Status on 30 October 2026: **Mac 2.5.1(1) is publicly released** and installed on this Mac. **iPhone, widgets and Apple Watch 1.2.1(1) is in TestFlight for internal testers and Waiting for Review**, set to release automatically once Apple approves it. Felipe authorized merging, releasing, TestFlight, the App Store submission and the install in chat that day.

1.2.0, submitted on 22 October, was approved and released on the App Store the same day (the App Store lookup shows 1.2.0 released 22 October 2026 at 18:08 UTC), so this release is 1.2.1.

## Source

| | |
|---|---|
| Changes | #42 (meters, rings, icons and popover finish; fresher iPhone readings), #43 (code review setup, no app change), #44 (version bump) |
| Merged | #41 as `ebb4095`, #42 as `35fd6ad`, #43 as `6b2919b`, #44 as `2a2849e46b34e2541e72d90662aa0a1ead2bf443` |
| Released tree | `20a21ae1f53f4e3113b4b31be9d62e2312ebdbd8`; tag `v2.5.1` |
| Merge path | The "Protect main" ruleset asks for one code-owner approval; the author is the only maintainer, so all four used the ruleset's existing admin bypass, as 2.5.0 did. No rule changed. |
| CI | Each PR head passed "Build and test" on GitHub's `macos-26` runner. #44's head has the released tree: [run 41038066146](https://github.com/felipedrf74/tokenroom/actions/runs/41038066146). #44's advisory review found one Nit (the skills' delivery lines), fixed by this record. |
| Local (Xcode 27.0) | On #42's code: Shared typecheck, 916 Mac tests and the Command Line Tools build, 0 failures. On the released code, the iPhone suite on the iPhone 18 Pro simulator: 43 tests, 42 pass, including the new `testKeepCurrentRefreshesAfterEachWaitUntilCancelled`; `testSigningOutRemovesBothPlans` fails (2 assertions: "Sessions here don't need renewing"). It fails the same way today on 2.5.0's commit `89296ca`, which passed it on 22 October, so #42 didn't cause it. Cause, found after this record was written: the test before it, `testGrokBotNotOnTheCursorPlanStaysOutQuietlyUntilTheNextSignIn`, signs in with `saveSession`, whose follow-up refresh ran on the real clock and outlived that test. It found the Cursor session, dated 25 September plus 30 days, expired and sent it for renewal while the sign-out test ran. #46 makes that refresh run on the sign-in's clock. Test-only: the app always runs on the real clock. CI compiles these tests without running them, so it didn't show. |
| CloudKit | No field or record type changed; the Production schema needed nothing. |

Both binaries were built from `d6431d5`, #44's head, whose tree is the released tree exactly; `production-source-inputs.json` hashes the compiled inputs at the released commit.

## Mac 2.5.1 (1)

- `scripts/release.sh`: Developer ID signature, Production iCloud, notarization Accepted (submission `b012660e-cf37-4b6e-9a55-f6556fcbfd06`), stapled, Gatekeeper "Notarized Developer ID". Universal arm64/x86_64. CDHash `63c2d6efa0ea25911ff29700aa06c19a289c47d0`.
- [GitHub release v2.5.1](https://github.com/felipedrf74/tokenroom/releases/tag/v2.5.1), marked latest: `Tokenroom-2.5.1.zip` (SHA-256 `674f8c1d259150746b6cd256172e5e6286d974ab71fd6b8748423f57ce24c5b0`), its `.sha256`, `release-source.json`, and `production-source-inputs.json` (209 inputs, digest `1cdc68961631f561b77e339a507c391bd8970a466fe8dc086d1603bf60a867b6`; the input rule reproduces 2.5.0's 208-input manifest exactly).
- An anonymous download of the published zip matches the checksum, and `/releases/latest` points to v2.5.1.
- Installed on this Mac from that download: the staged and installed app both passed version, bundle ID, signature, staple and Gatekeeper checks. The running 2.5.0 was stopped by its exact path and 2.5.1 launched. The 2.5.0 app, verified, is kept at `~/Library/Application Support/TokenroomReleaseRollback/20261030T101518Z/Tokenroom-2.5.0.app`. The second Mac was not updated.

## iPhone, widgets, and Apple Watch 1.2.1 (1)

- Archived (Release) and exported for App Store Connect. All four components (app, widgets, Watch app, Watch widgets) are 1.2.1 (1), signed Apple Distribution, with Production iCloud, production push on the app, no `get-task-allow`, and `ITSAppUsesNonExemptEncryption = NO`. Uploaded with `xcodebuild -exportArchive` on 30 October at 10:10 UTC (delivery `5f05d77d-ce5e-49c3-9668-84611b6db1ee`); processed (Valid).
- The export needs `PATH=/usr/bin:/bin:/usr/sbin:/sbin`: with MacPorts' `rsync` 3.2.7 on PATH, Xcode's IPA step fails with "Copy failed" (`--extended-attributes: unknown option`).
- TestFlight: the build is in testing for internal testers, with testers notified automatically.
- App Store Connect, version 1.2.1: build 1.2.1 (1); What's New from `docs/app-store.md`; the promotional text from `docs/app-store.md`, unchanged from 1.2.0 (the new version started with it empty); automatic release, to all users at once, keeping existing ratings. Name, subtitle, description, keywords, screenshots, privacy ("Data Not Collected"), age rating and review notes carried over from 1.2.0 unchanged, so the description still has the old privacy bullet ([the 22 October record](release-delivery-20261022.md) has why).
- Submitted for review on 30 October, shortly before 10:30 UTC: "1 Item Submitted", status Waiting for Review.

## Still open

- App Review: approval, then automatic public release. Waiting for Review is not public availability; check the live App Store page after release.
- Vendor terms, as recorded for 1.2.0: plan sign-in uses each vendor's own CLI/app public client, the risk the owner took on 21 October, and the iPhone's renewal rule is looser than `docs/session-security-assessment-20261004.md` says. The 1.2.0 record has what is still open on both. Removing a provider means taking it out of `PhoneConnect.productionAllowlist` and `PhoneSignIn.providers`, and out of the tests that pin those sets.
- `testSigningOutRemovesBothPlans` fails on `main` until #46 merges (see Source › Local).
- App Store description: its privacy bullet still says logins never leave the Mac. It changes with the next version, or by taking 1.2.1 back out of review; `docs/app-store.md` › Description has the text.
- Not exercised: the 2-minute refresh and the 9-minute heartbeat between a real Mac and iPhone, push throttling at the higher heartbeat rate, and Watch and widget rendering on devices. 2.5.1 was launched on this Mac, but its behaviour there was not inspected.
