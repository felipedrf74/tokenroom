# Mac 2.6.4 delivery and mobile 1.3.7 submission — 21 November 2026

**Mac 2.6.4 (1) is public. Mobile 1.3.7 (1) is Waiting for Review**, submitted at 10:42:12 UTC
with automatic release after approval to all users. Approval and public availability of
1.3.7 are pending; submission is not publication. Mobile 1.3.6 was ready for distribution
when 1.3.7 was created.

Both carry the polish overhaul (#80): readings and News say what they know on every surface.
What changed is in the changelog's 2.6.4 / 1.3.7 entry.

## Source and verification

| Item | Evidence |
| --- | --- |
| Behaviour change | #80, merged as `9324d703e3e9b60b87a6a0054540d2b9d30152a0`; council of three GPT-6.2 Astra seats satisfied after eight rounds, sol loop (GPT-6.2 Sol) approved |
| Release metadata | #81, merged as `ccb906ca9fb543562b1985372f9806c193d81f5a`, tree `81bfe063463c7b7b393866f4a205e0fd65796d90` |
| Built source | `ccb906c` for both the Mac and the mobile package |
| Tests | 1,127 Mac tests passed on the #80 branch; `TokenroomMobileTests` compiled, not run (they need a signed host) |
| CI | All seven checks passed on #80's head `19b2b92` and on #81's head `686aca3` |
| Review | #81 had one fresh-context review: one finding (release copy overstated which missing numbers keep the last reading), fixed in `c01e3be` and confirmed. The advisory review found no issues |

## Public Mac package

[GitHub release v2.6.4](https://github.com/felipedrf74/tokenroom/releases/tag/v2.6.4) was
published at 10:20:05 UTC: not a draft or prerelease, marked latest, tag on `ccb906c`. Its
assets are `Tokenroom-2.6.4.zip`, `Tokenroom-2.6.4.zip.sha256`, `release-source.json` and
`production-source-inputs.json` (242 source inputs).

- ZIP SHA-256: `94e7f2f1522c67a13f927dc76116563f066980e6e0017f7b5a920d9455fbeff7`.
- Executable SHA-256: `6704166d7524baac0e84d0cb4fec715b236c4c83890b7900db7a55d2158b119e`.
- Universal arm64/x86_64, Developer ID, Production iCloud container `iCloud.app.tokenroom`,
  no debug entitlement, embedded provisioning profile.
- Notarization `a29bca88-54fd-41a7-bc97-a3fe87cecdf7` accepted; stapled; Gatekeeper says
  "Notarized Developer ID". The public download matched the checksum.
- Extract the zip with Finder or `ditto -x -k`. Info-ZIP `unzip` drops parts of the bundle
  and Gatekeeper then reports "a sealed resource is missing or invalid"; with `ditto` the same
  zip passes the strict signature check and Gatekeeper.

## Installations

| Mac | Previous | Installed | Verification |
| --- | --- | --- | --- |
| MacBook Pro | 2.6.3 (1) | 2.6.4 (1), 10:20:29 UTC | Installed from the public download; executable checksum, Gatekeeper and a running process. 2.6.3 kept for rollback |
| Maquinho Pro | 2.6.3 (1) | Not installed | Not reached in this delivery |

## Signed mobile package and upload

The iPhone app, widgets, Watch app and Watch widgets are all 1.3.7 (1), exported for App Store
Connect on the MacBook Pro with Xcode 27. All four passed a strict signature check with Apple
Distribution, carry the Production iCloud environment and the App Group, and have no debug
entitlement. The iPhone app carries the production push environment.

- Local-export IPA SHA-256: `81ed8474e3dcd65f1954b8a57352da0ec584e7dbc320cf62a05c14036c18c9b8`.
- One upload through the Xcode account succeeded at 10:21:26 UTC.
- Apple's processed build: `2ade830f-a560-45bc-b73c-a1358b501282`, `VALID`, no export-compliance
  question open. **Do not upload 1.3.7 (1) again.**

## App Review submission

Done with the App Store Connect API.

- App Store version `95426bb1-2732-4fee-ac8a-1c36ad93fb10`, 1.3.7, created from 1.3.6's
  metadata without its What's New.
- The three What's New paragraphs from `docs/app-store.md` were saved and read back identical
  (841 characters). Description and keywords carried over from 1.3.6. Promotional text was
  empty before and stays empty. Screenshots were not touched.
- Build 1.3.7 (1) attached; release type automatic after approval; no phased release.
- Review submission `c9c3f95b-43c2-4114-b92a-443ab198cab9`, submitted at 10:42:12 UTC;
  read back as **Waiting for Review** with no blocking issue.

## Not verified

A physical iPhone, Watch and widget, and delivery of readings between devices through iCloud,
were not exercised with these packages.

## Revert

The Mac: reinstall 2.6.3 from its public release, or from the rollback copy kept on the
MacBook Pro, and publish a corrected version; don't overwrite v2.6.4's assets or retag it.
Mobile 1.3.7 (1) is consumed by its upload. Until Apple approves it, the submission can be
withdrawn in App Store Connect (App Review › the submission › Remove). After release, a
correction needs a new version.

Local receipts are under `~/Library/Developer/Xcode/Archives/Tokenroom-Polish-20261121/` on
the MacBook Pro (`READINESS.md`, the archive, exports, logs, option files and the rollback app).
