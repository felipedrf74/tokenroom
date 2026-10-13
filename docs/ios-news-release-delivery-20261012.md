# iPhone News 1.1.1(1) — public release record

Status on 13 October 2026: **1.1.1(1) is publicly released**. Apple approved the exact submitted build, the authorized manual release completed, and the live official [Portugal](https://apps.apple.com/pt/app/tokenroom-ai-usage-limits/id6816126110) and [US](https://apps.apple.com/us/app/tokenroom-ai-usage-limits/id6816126110) pages both show 1.1.1 and the matching editorial release notes. Source, CI and all 198 signed inputs were rechecked before publication. Authorized cleanup is complete; signed packages, symbols, source and unique evidence are retained.

## Qualified source and candidate

- Source commit: [`740f9a0a1d23210bfe25bd9220f30d86fca08515`](https://github.com/felipedrf74/tokenroom/commit/740f9a0a1d23210bfe25bd9220f30d86fca08515), based on `ac66a4966b3779657be2cefe50d319a201b4e61f`.
- [Exact-source CI](https://github.com/felipedrf74/tokenroom/actions/runs/38298286634): all steps passed, completed 12 October at 19:43:24 UTC. Shared macOS/iOS/watchOS typechecks, Mac suite, mobile/widgets/Watch build, mobile test compilation and fallback build passed. The hosted iOS suite was executed locally, separately.
- Documentation follow-up `a48f1bcfa2728254ea5b71ec75810318a5ed0b12` also passed [CI run 38300999977](https://github.com/felipedrf74/tokenroom/actions/runs/38300999977). Before publication on 13 October, both runs were freshly confirmed successful, main and the clean checkout matched that documentation revision, all 198 compiled inputs matched, and the retained archive/export/upload hashes matched. `prepublication-recheck-20261013.json` records the checks.
- Local qualification: 780 full Mac and 34 full hosted iOS tests passed, zero failures/skips. Independent source/diff/documentation review passed. Both P2 and fresh P3 findings are closed. Native ordinary/largest, light/dark, four-section, source/search/follow, ranking/details, Saved/Undo, recovery, Share cancellation and Reduce Motion checks have scoped receipts.
- All 198 production-input hashes match the signed source after integration. No new source/runtime change followed qualification.
- Apple build: `12b15493-c81e-4a63-b826-d1178056b33d`, version 1.1.1 build 1; four components share that version. Exact uploaded IPA SHA-256: `1d1be79d15bddd6be6ab45850e04768c85fb64496ab16d5b569496f947d2af2c`.
- All four strict signatures, Production entitlements, distribution profiles and executable UUID/non-signature-byte equivalence passed. Archive dSYM UUIDs match all uploaded executable architectures. The separately qualified export is preserved; its ZIP hash differs because Xcode re-signs the upload, not because source changed.

The push was a fast-forward. GitHub reported a PR-rule bypass for the user-authorized direct main push; no force push or branch-rule configuration change occurred. The existing branch/checkout remains intact.

## Apple submission

[Submission `16200897-ca51-4994-817d-04ce82c1f1ed`](https://appstoreconnect.apple.com/apps/6816126110/distribution/reviewsubmissions/details/16200897-ca51-4994-817d-04ce82c1f1ed) was accepted on 12 October at 20:46 Europe/Lisbon (19:46 UTC), with one item: **iOS App 1.1.1(1)**. Waiting for Review and In Review checkpoints remain separate receipts. On 13 October, the exact submission showed Review Completed / Approved and the same Apple build ID.

The manual release confirmation covered the existing 174 countries/regions. The portal showed **Ready for Distribution** by 08:09:25 UTC (09:09 Europe/Lisbon). Public 1.1.1 was independently observed on the live Portugal page at 08:13:57 UTC and US page at 08:15:59 UTC. The public page supplies a release date of 13 October, not an exact release-second timestamp. A transient US-page error resolved on reload and was retained as its own observation.

The iTunes lookup endpoints still returned cached 1.1.0 responses with Akamai `TCP_HIT` and a long cache lifetime. Those observations are preserved; they are not relabeled as 1.1.1 checks. Live unauthenticated official App Store pages provide the current public-version evidence.

Accurate What's New and review notes are saved. The native Today screenshot replaces the obsolete Following placement; its original stays in Asset Library. Seven saved iPhone screenshots are ordered Usage, detail, Home Screen widgets, Lock Screen, API keys, welcome, current Today. Smaller sizes inherit the large-display set. Existing Watch assets remain applicable. Manual release prevents approval alone from publishing this candidate.

Mobile 1.1.0 was the prior public version; its official US/PT lookup receipts show release on 12 October at 15:07:19 UTC. Mac 2.4.1 is a separate prior release. Fresh read-only checks on 13 October confirm both installed Mac apps still match all nine qualified public-package file hashes and pass strict signatures at 2.4.1(1); GitHub's latest public Mac release remains v2.4.1. No new Mac package, installation or production app launch was performed for this iPhone presentation change.

## Evidence and retained recovery material

Root: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-release-20261012/`.

- `implementation-closeout.json`, final tracked/untracked diffs — reviewed pre-integration snapshot; timestamped historical uncommitted state.
- `source-integration-receipt.json`, `ci-passed-receipt.json` — commit/main binding and actual CI success.
- `signed/production-inputs.json`, `signed/production-inputs-recheck.json`, `signed/uploaded-verification.json`, `signed/symbol-verification.json` — source, exact upload and symbols.
- `asc-1.1.1-draft-receipt.json`, `asc-submission-receipt.json`, `asc-waiting-for-review.png` — saved draft and accepted submission, kept as distinct states.
- `asc-approval-receipt.json`, `asc-approved-20261013.png`, `asc-manual-release-receipt.json`, `asc-ready-for-distribution-20261013.png` — exact approval and successful manual release.
- `public-release-verification-20261013.json`, `public-1.1.1-{pt,us}-live-page.json/.png` — live official public availability, distinct from cached lookup observations.
- `store-screenshot-receipt.json`, `store-news-today-native.png`, `asc-new-news-preview.png` — truthful native current News asset and provenance.
- `signed/retention-receipt.json` — persistent archive ZIP, qualified export and actual uploaded IPA. Archive/dSYMs/source/evidence remain preserved.
- `motion-housekeeping-receipt.json`, `motion-final-housekeeping.png` — final owned-Simulator Reduce Motion off and Auto-Play Message Effects on, matching original settings.

[Release qualification](ios-news-release-checks-20261012.md) retains the detailed checks and integration limits; [visual QA](../design-qa.md) distinguishes its earlier checkpoint from the final qualification. The [independent QA prompt](ios-news-independent-qa-prompt-20261012.md) remains reusable for the source change and later delivery evidence.

## Post-release cleanup and retained recovery

After official public availability, four manifest-owned build/cache directories were removed following canonical-path, ownership, workspace, no-active-builder and fresh open-handle checks. Pre-removal allocation totaled 2,011,664 KiB (about 1.92 GiB); this is not a claim of net reclaimed capacity. Ten potentially unique DerivedData log/result files were retained in a ZIP and verified byte-for-byte before removal. `cleanup-final-preconditions-20261013.json`, `retained-deriveddata-logs-receipt.json` and `post-release-cleanup-receipt-20261013.json` identify the exact paths and preserved recovery hashes.

Both task-owned phone UUIDs were already absent at the fresh inventory; no Simulator operation was performed during this release closeout. The pre-existing Watch `27B4FF6C-73F3-4B3E-B1CB-077FB8A5DCA8`, other devices/runtimes and their current pairing remain intact. No task-prefixed duplicate Desktop capture was present. Source, archive ZIP/dSYMs, qualified export, exact upload, the signing workspace and all unique evidence remain retained.

This post-release documentation update changes no compiled input, signing configuration, version, package byte or uploaded build. The released application remains bound to source `740f9a0`; later documentation revisions do not imply a rebuild or another upload.

## Acceptance limits

Spoken VoiceOver focus remains unverified; the user explicitly accepted proceeding with that limitation recorded. Existing same-account production iCloud/notification/App Group/device/Watch integration limits remain separate from this finite News presentation scope. No physical phone/Watch checks or new production app launches are claimed.

No additional device acceptance is inferred from App Review approval or public availability. Fresh Mac installation checks are recorded separately in `mac-241-fresh-{local,m2}-20261013.json`; these were read-only and did not start the apps.
