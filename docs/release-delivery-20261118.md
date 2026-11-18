# Mobile 1.3.6 submission — 18 November 2026

**iPhone, widgets and Watch 1.3.6 (1) is Waiting for Review**, submitted at 17:19 UTC
with automatic release after approval to all users. Apple accepted its upload at
17:08:17 UTC. Approval and public availability remain pending; submission is not
publication.

There is no Mac release in this delivery. Nothing in the Mac app changed with the
widget work, so **Mac 2.6.3 (1) stays the current Mac release** (`v2.6.3`, 16 November).
Apple's public US and Portugal listings show the preceding mobile 1.3.5 released on
17 November at 20:52:29 UTC.

## Source and verification

| Item | Evidence |
| --- | --- |
| Behavior change | #77, merged as `2924eb5ab9ba657cf064b0a039c5805b453cd2b5` |
| Release metadata | #78, candidate `bbb5308379ddfcb857d5ae6f7736b7411fbf2bdd` |
| Released source | `0bb9022d6413aa49d229686e1c328c5e98d7ec5e` |
| Identical candidate/merge tree | `9003516e4f8568d39c7520290613a394c474b3ab` |
| Archived commit | `3659578576a3ce6536b07bd18708da1600d6e6e4`; it differs from the released source only in `docs/app-store.md`, which no target builds |
| Behavior tests | 1,076 Mac and 66 hosted iPhone tests passed on the candidate, with no failures |
| Release CI | [All seven checks passed](https://github.com/felipedrf74/tokenroom/actions/runs/44350585174) on the exact candidate, on the second attempt: GitHub never assigned a runner to the Mac tests and the Shared typecheck on the first |
| Fresh review | One fresh-context review of #78: no blocking finding, three nits, two fixed in `bbb5308`. The repository's advisory review was clean in both rounds. #77 had its own council review |

What changed is in the changelog's 1.3.6 entry and in the "Widget arrangement and
styles" section of the `tokenroom-apple` skill.

## Signed mobile package and upload

The iPhone app, widgets, Watch app and complications are all 1.3.6 (1), exported for
App Store Connect on Maquinho Pro with Xcode 27.0. All four passed a strict signature
check with an Apple Distribution certificate, and carry the Production iCloud
environment for `iCloud.app.tokenroom`, the `group.app.tokenroom` App Group and no
debug entitlement. The iPhone app carries the production push environment.

Local-export IPA SHA-256:
`4c8ed784f37ac6602b5b88dac7344013d60619af226665fb2540bc03307e91b0`.

The Xcode account on that Mac completed one upload from the same archive, exit code 0,
at **17:08:17 UTC** ("Upload succeeded"). TestFlight showed the build as Processing
straight after and as Ready to Submit by 17:16 UTC. The upload re-export was not
kept, so its checksum is not recorded here. **Do not upload 1.3.6 (1) again.**

The archive, both option files, the local export and the archive, export and upload
logs remain on Maquinho Pro under
`~/Library/Developer/Xcode/Archives/Tokenroom-Widgets-20261118/`.

## Accepted App Review submission

- App Review submission ID: `8c6be1a7-21cb-421f-b903-c28f9aecb130`.
- Accepted: **18 November 2026, 17:19 UTC**.
- Observed state: **Waiting for Review**.
- Release mode: **automatic after approval, all users**.

Version 1.3.6 was created in App Store Connect, the three What's New paragraphs from
`docs/app-store.md` were saved and read back unchanged (702 characters), and build 1
was attached. Description, keywords, review notes and release mode came over from
1.3.5 unchanged. The promotional text field was empty on 1.3.5 and is empty on 1.3.6;
the text in `docs/app-store.md` is not in the listing. Screenshots were not touched:
the Home Screen widgets screenshot still shows the earlier widget design.

Apple must review and approve the submission. Public 1.3.6 availability was not
observed at this checkpoint.

## Macs

| Mac | Installed | Verification |
| --- | --- | --- |
| Maquinho Pro | 2.6.3 (1), since 16 November | Executable SHA-256 `181020e63aa3f2c65ccdc9e2814e8b88e96024139b06663ebc2ee8e8062b4433` matches the public `v2.6.3` package's; strict signature, Gatekeeper (Notarized Developer ID) and a running process |
| MacBook Pro | Not checked | It could not be reached on 18 November; its installed version is unverified |

## Not verified

A physical iPhone, a widget installed before this change, a tinted Home Screen on a
device and the Watch were not exercised. A real widget was checked on a Simulator
Home Screen for #77.

## Revert

Mobile 1.3.6 (1) is consumed by the successful upload. Until Apple approves it, the
submission can be withdrawn in App Store Connect (App Review › the submission ›
Remove). Any replacement package must use a new build number and pass the release
process; do not reupload this build. After release, a correction needs a new version.
