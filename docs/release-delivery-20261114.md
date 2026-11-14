# Mac 2.6.1 delivery and mobile 1.3.3 submission — 14 November 2026

**Mac 2.6.1 (1) is public and installed on both Macs. Mobile 1.3.3 (1) is Waiting
for Review**, submitted at 16:59 UTC with automatic release after approval to all
users. Apple accepted its upload at 16:30:36 UTC. Approval and public availability
of 1.3.3 remain pending; submission is not publication.
Apple's public US/PT listings confirm the preceding mobile 1.3.2 released on
13 November at 03:20:05 UTC.

## Source and verification

| Item | Evidence |
| --- | --- |
| Behavior fix | #69, merged as `50601aa99bd352cff49e813098d24e03da5e1eae` |
| Release metadata | #70, candidate `8ab09ecb0a4e032ebb729d4bb1221cad530204b3` |
| Released source | `aa66b9bce51508fdb7428a403db93d62fe892f9d` |
| Identical candidate/merge tree | `843e67d4d0697872d6a34474247a50acfd4a630d` |
| Source binding | All 509 tracked input hashes matched before delivery |
| Behavior tests | 1,034 Mac and 60 hosted iPhone tests passed, with 17 regression methods added |
| Release build | All four Simulator components verified as 1.3.3 (1) |
| Release CI | [All six CI jobs passed](https://github.com/felipedrf74/tokenroom/actions/runs/43611045881) on the exact candidate |
| Fresh review | Three GPT-6.1 Sol release reviews: 9/10 each, no findings; the separate repository advisory review was also clean |

The behavior fixes restore wake collection, single-provider offline recovery,
deferred cloud publication and newer widget cache adoption, and bound credential
discovery without treating an unreadable item as removed. The behavior evidence
and limits remain in [the usage recovery report](usage-reliability-20261114.md).

## Public Mac package

[GitHub release v2.6.1](https://github.com/felipedrf74/tokenroom/releases/tag/v2.6.1)
was published at 16:16:08 UTC, is neither a draft nor a prerelease, and is marked
latest. Its immutable assets are:

- `Tokenroom-2.6.1.zip`
- `Tokenroom-2.6.1.zip.sha256`
- `release-source.json`
- `production-source-inputs.json`

ZIP SHA-256: `692d2be9ddbeba68cbefa87eb550dea8c1acb8198c0ec6847723c087b51bd385`.
Executable SHA-256: `8847116f2bc5d7315cdbb8da2313b6be8db1b86fe9a17ecd995dd561633aa3a8`.

The universal arm64/x86_64 export passed Developer ID signature, Production iCloud
container/profile, no-debug entitlement and archive/dSYM UUID checks. Apple accepted
notarization; stapling, strict/deep signature verification and Gatekeeper passed.
Public downloads on both Macs matched the published ZIP checksum.

## Installation receipts

Both installations use the exact public package and retain the preceding app for
rollback. The installed executables match the release manifest and were observed
running after replacement. Preferences and tool logins were preserved.

| Mac | Previous version | Installed | Verification |
| --- | --- | --- | --- |
| MacBook Pro | 2.5.3 (1) | 2.6.1 (1) | Public bundle equivalence, signature, staple, Gatekeeper and running process |
| Maquinho Pro | 2.6.0 (1) | 2.6.1 (1), 16:24:21 UTC | Executable checksum, signature, staple, Gatekeeper and running process |

Canonical signing and MacBook receipts remain under
`~/Library/Developer/Xcode/Archives/Tokenroom-UsageRecovery-20261114/`;
`READINESS.md` records artifact paths and the rollback app. Maquinho Pro retains
`local-installation.json`, package verification, the public download and its rollback
app under `~/Documents/Tokenroom Reports/release-delivery-20261114/`.

## Signed mobile package and upload

The iPhone app, widgets, Watch app and complications are all 1.3.3 (1), exported for
App Store Connect. All four passed Distribution profile, version, entitlement,
no-debug and UUID verification. Production iCloud/push and App Group/Keychain roles
were checked against the source-defined roles; export compliance is unchanged.

Original local-export IPA SHA-256:
`729fd64576d985d0b74502a491a2649e73097a7e9f29c034ba2e2c933b30f99d`.
That verified IPA remains unchanged in the canonical artifact directory's
`export/TokenroomMobile.ipa` beside its archive and receipts.

The existing Xcode account completed one upload successfully, without a web login,
at **16:30:36.111 UTC**, exit code 0. Apple reported `PROCESSING`, with no errors or
warnings. The upload reexport was captured and matched Apple's checksum; all four
components retained their approved versions, signatures, Production entitlements and
archive/dSYM UUIDs, with all 509 source input hashes rechecked.

- Uploaded IPA SHA-256: `d4929da79a6a4c331c17c4ac9590c4cbc429e9b9fc80249a7e8fcf009636108d`.
- Upload/archive identifier: `e8f96ee7-ad2e-4b74-82f6-aeb2a70cd38c`.
- Receipts: canonical artifact directory's `mobile-upload-20261114T162708Z/`,
  including `verified-upload-receipt.json`, `READINESS.md` and the redacted upload log.

The processed build ID was unconfirmed at the upload checkpoint. The subsequent
authenticated App Store Connect build link confirmed that same identifier as the
processed build selected for review. It is distinct from the submission ID below.
**Do not upload 1.3.3 (1) again.**

## Accepted App Review submission

After the authenticated Safari context became accessible, TestFlight showed the
existing 1.3.3 (1) build as Ready to Submit and its metadata as Validated. That exact
build was attached to the new 1.3.3 version, reusing the successful upload.

- Apple processed-build ID: `e8f96ee7-ad2e-4b74-82f6-aeb2a70cd38c`.
- App Review submission ID: `3b105c79-375e-4539-8743-c6659cb6ced7`.
- Accepted: **14 November 2026, 16:59 UTC**.
- Observed state: **Waiting for Review**.
- Release mode: **automatic after approval, all users**.

The two What's New paragraphs from `docs/app-store.md` were saved exactly.
Description, promotional text, review information and the existing seven iPhone
and two Watch screenshots were preserved. The attached build and release mode were
checked again after submission. No second upload or source change was required.

The redacted receipt is retained in the canonical artifact directory as
`mobile-submission/app-review-receipt-20261114T170020Z.md`. Earlier authentication
checkpoints remain separately dated; they no longer describe a current blocker.
Apple must review and approve the submission. Public 1.3.3 availability was not
observed at this checkpoint.

No schema deployment, credential copying, source behavior or CI gate change was
needed for packaging. Physical private-iCloud delivery and background WidgetKit/
Watch execution remain distinct unverified integration limits.

## Revert

The previous public Mac release and both local rollback apps remain available.
Restore the preceding signed app to reverse an installation. Any correction to a
public package must use a new version; do not overwrite its assets or retag it.
Mobile 1.3.3 (1) is consumed by the successful upload. Any replacement package must
use a new build number and pass the release process; do not reupload this build.
