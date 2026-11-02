# Mac 2.5.3 — delivery record, 2 November 2026

**Mac 2.5.3(1) is publicly released**, with Orbit, selectable popover styles, usage insights and the native Grok Bot connection fix. The iPhone, widgets and Watch source and versions are unchanged; this Mac release did not create an App Store submission. The Mac distribution is the signed, notarized download on GitHub.

## Source and merge

| Item | Verified result |
|---|---|
| Grok Bot fix | #53, already merged as `1248b850b4b19d78c1674c54ac515c4fe921f267` |
| Popover styles and insights | #55, head `3503126e8c696ce7f2a089a050bd8690682b4e38`, merged as `76df128d65f3176748a35dac545e28ee2174d7d6` |
| Combined release preparation | #54, head `c2229fbe156a4be5c4e5bb9f5e4fc912ec483719`, merged as `a44486be9f915a9638ca6d10b15acee60949641e` |
| Released source | `a44486be9f915a9638ca6d10b15acee60949641e`, tag `v2.5.3` |
| Package build source | `c2229fbe156a4be5c4e5bb9f5e4fc912ec483719`; its entire tree is identical to the released merge commit |
| Production inputs | All 229 hashes match the released source. Only `Config/Version.xcconfig` differs from the previously qualified UI revision `3503126`. |

Both PRs merged normally after the maintainer explicitly requested removal of mandatory human approval for this solo-maintainer repository. No administrative merge bypass, force-push or direct push to `main` was used.

## Verification

- Both hosted checks passed on #55 head `3503126` and #54 head `c2229fb`. The release head's [Build and test run](https://github.com/felipedrf74/tokenroom/actions/runs/41420553526) and [advisory review](https://github.com/felipedrf74/tokenroom/actions/runs/41420553449) are successful.
- Reusable local evidence for the unchanged application inputs: 955 Mac tests passed, Shared typechecks passed, iOS/widgets/Watch build-for-testing passed, and the Command Line Tools fallback passed. The final accessibility trait passed eight targeted popover tests and native accessibility inspection.
- Fresh-context source review and final release-delta review found no remaining issues. The advisory review's recovery-card side-margin Nit was checked in the native expired-session fixture: Sign In and recovery controls remain reachable. It is cosmetic and does not block release.
- Native UI validation covered all five styles, Settings and palette selection, provider details and Back, keyboard/accessibility activation, scrolling and preference persistence. Live Grok Bot readings remained available. This is not a new physical iPhone/Watch delivery attestation.
- The combined release archive and Developer ID export passed. The app is universal arm64/x86_64, uses Production iCloud, includes its provisioning profile and has no debug-task entitlement.
- Apple notarization: **Accepted**, submission `a2dafb8f-9099-46ae-9ce8-0740f094136b`. Staple validation, strict/deep signature verification and Gatekeeper assessment passed.
- The final ZIP was extracted again. Its version, signature, staple, Gatekeeper assessment and executable equivalence passed.

## Public package

[GitHub release v2.5.3](https://github.com/felipedrf74/tokenroom/releases/tag/v2.5.3) was published on 2 November at 09:51:57 UTC, is not a draft or prerelease, and is marked latest.

- `Tokenroom-2.5.3.zip`
- `Tokenroom-2.5.3.zip.sha256`
- `release-source.json`
- `production-source-inputs.json`

ZIP SHA-256: `c86b0d2e644a0b535944bea4929aa8010fccae793f995932502c9b22bdb4091c`.

An anonymous download of the public asset returned HTTP 200 and matched that checksum. The latest-release API also returned `v2.5.3`. Signing, source, package and download receipts are retained locally under `~/Library/Developer/Xcode/Archives/Tokenroom-2.5.3-Orbit-20261102/` and `~/Documents/Tokenroom/release-delivery-20261102/`.

The previously installed local validation build already contains the same application code as this release, but retains its earlier version metadata. This publication pass did not replace that installed app with the public ZIP. The earlier app and validation receipts remain preserved; local installation and public distribution are separate evidence.

## Solo-maintainer policy

The active `Protect main` ruleset (`22651790`) still requires a pull request and blocks deletion and non-fast-forward updates to `main`. At the maintainer's explicit request:

- Required approving reviews changed from 1 to 0.
- Required code-owner review was disabled.
- Extra approval for unattributed changes was disabled.

The ruleset's target, enforcement, allowed merge methods and existing bypass-actor configuration were preserved. The bypass was not used. CI jobs, tests, triggers and the advisory AI-review behavior were not changed. `CODEOWNERS` retains ownership and optional review routing; it is no longer a human approval gate.

## Remaining distinctions

- The iPhone/Watch release remains a separate App Store product and was not re-submitted for these Mac-only changes. Its current App Review/public status was not rechecked here.
- Physical iPhone/Watch relay and notification delivery were not newly qualified by this release pass.
- The previous public Mac package remains available for rollback. Any subsequent binary correction must use a new release version; do not overwrite the published ZIP or retag `v2.5.3`.
