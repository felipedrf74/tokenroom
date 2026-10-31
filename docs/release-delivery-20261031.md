# Mac 2.5.2 and iPhone 1.2.2 — delivery record, 31 October 2026

Status on 31 October 2026: **Mac 2.5.2(1) is publicly released** and installed on this Mac. **iPhone, widgets and Apple Watch 1.2.2(1) is in TestFlight for internal testers and Waiting for Review**, set to release automatically once Apple approves it. Felipe asked for the merge, the release, TestFlight and the App Store submission in chat that day.

1.2.1, submitted on 30 October, was approved and released on the App Store the same day (the App Store lookup for US, PT and BR shows 1.2.1 released 30 October 2026 at 18:01 UTC, and App Store Connect shows it Ready for Distribution), so this release is 1.2.2.

## Source

| | |
|---|---|
| Changes | #50 (30 fixes from an audit of the app, with 13 new tests), #51 (version bump). #46–#49, merged after 2.5.1, change tests and records only. |
| Merged | #50 as `8f9be898b3e77c744abde5539534ac5ba8f4a59a`, #51 as `0da242c5f474ff8bd63f13ae484f9cad221e449f` |
| Released tree | `af5d59236bba16592c52079c5fae851b63eda812`; tag `v2.5.2` |
| Merge path | The "Protect main" ruleset asks for one code-owner approval; the author is the only maintainer, so both used the ruleset's existing admin bypass, as 2.5.1 did. No rule changed. |
| CI | Each PR head passed "Build and test" on GitHub's `macos-26` runner. #51's head has the released tree: [run 41192435339](https://github.com/felipedrf74/tokenroom/actions/runs/41192435339). #51's advisory review found one Nit (the skills' delivery lines), fixed by this record. |
| Local (Xcode 27.0) | On #50's code: Shared typecheck (macOS, iOS, watchOS), 929 Mac tests, the iPhone app, widgets and Watch build, the iPhone tests build, and the Command Line Tools build, 0 failures. The iPhone suite on the iPhone 18 Pro simulator: 46 tests, 0 failures. Each of #50's 13 new tests failed with its fix reverted. |
| CloudKit | No field or record type changed; the Production schema needed nothing. Readers now also read `minReader` from a payload that doesn't decode (#50), which needs no schema change. |

Both binaries were built from `ebcee5a`, #51's head, whose tree is the released tree exactly; `production-source-inputs.json` hashes the compiled inputs at the released commit.

## Mac 2.5.2 (1)

- `scripts/release.sh`: Developer ID signature, Production iCloud, notarization Accepted (submission `c164fcb9-c560-42a8-a439-4c4c492f3685`), stapled, Gatekeeper "Notarized Developer ID". Universal arm64/x86_64. CDHash `16e3d9c924aa2bd0ca7c312ec1b74a34b2271a09`.
- [GitHub release v2.5.2](https://github.com/felipedrf74/tokenroom/releases/tag/v2.5.2), marked latest: `Tokenroom-2.5.2.zip` (SHA-256 `be56d6afd3b6bc6e19519ede0051a8c5abc9157cc10b1842ded596ca386091b7`), its `.sha256`, `release-source.json`, and `production-source-inputs.json` (209 inputs, digest `f005b03c4a747f5f4bb8bf0ad106551bd71682cc38b46fa96bccf96c39240c6c`). The input rule reproduces 2.5.1's 209-input manifest and digest exactly.
- An anonymous download of the published zip matches the checksum, and `/releases/latest` points to v2.5.2.
- Installed on this Mac from that download: the staged and installed app both passed version, bundle ID, signature, staple and Gatekeeper checks. The running 2.5.1 was quit by its exact path and 2.5.2 launched; within six minutes it had written new readings (`snapshots.json`, `checked.json`). The 2.5.1 app, verified, is kept at `~/Library/Application Support/TokenroomReleaseRollback/20261031T103407Z/Tokenroom-2.5.1.app`. The second Mac was not updated.

## iPhone, widgets, and Apple Watch 1.2.2 (1)

- Archived (Release) and exported for App Store Connect. All four components (app, widgets, Watch app, Watch widgets) are 1.2.2 (1); the app has `ITSAppUsesNonExemptEncryption = NO`. Uploaded with `xcodebuild -exportArchive` (`destination` upload, `PATH=/usr/bin:/bin:/usr/sbin:/sbin` for the MacPorts `rsync` problem) on 31 October at 10:35 UTC: "Upload succeeded"; processed (App Store Connect build `37f8edbc-a145-40b6-80f6-436ba182d758`).
- TestFlight: build 1.2.2 (1) is in the internal group, with its tester invited automatically.
- App Store Connect, version 1.2.2: build 1.2.2 (1); What's New and the promotional text from `docs/app-store.md`; the description from `docs/app-store.md` › Description, which replaces the old privacy bullet ("Logins never leave your Mac, and keys never leave your iPhone") with the current one. The live description was checked line by line first: only that bullet differed. Automatic release, to all users at once, keeping existing ratings. Name, subtitle, keywords, screenshots, privacy ("Data Not Collected"), age rating and review notes carried over from 1.2.1 unchanged.
- Submitted for review on 31 October at about 10:39 UTC: "1 Item Submitted", status Waiting for Review.

## Still open

- App Review: approval, then automatic public release. Waiting for Review is not public availability; check the live App Store page after release.
- Vendor terms, as recorded for 1.2.0: plan sign-in uses each vendor's own CLI/app public client, the risk the owner took on 21 October, and the iPhone's renewal rule is looser than `docs/session-security-assessment-20261004.md` says. The 1.2.0 record has what is still open on both.
- Found by #50's audit and left for follow-up: Sign In finishing at once for Copilot, Devin or Antigravity when a refused login file is still there; a refused Copilot editor token blocking the gh login; Antigravity errors when `agy` exits non-zero.
- Not exercised: the fixes on a real iPhone, Watch and widgets (covered by tests and builds), and the relay change between a real Mac and iPhone.
