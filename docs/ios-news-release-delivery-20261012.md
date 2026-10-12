# iPhone News 1.1.1(1) — submission record

Status on 12 October 2026: source committed and pushed to main; exact-source CI passed; Apple accepted 1.1.1(1) and it is **Waiting for Review**. It is **not publicly released**. Manual release is selected. App Review approval, the manual release action and official public-version verification remain pending.

## Qualified source and candidate

- Source commit: [`740f9a0a1d23210bfe25bd9220f30d86fca08515`](https://github.com/felipedrf74/tokenroom/commit/740f9a0a1d23210bfe25bd9220f30d86fca08515), based on `ac66a4966b3779657be2cefe50d319a201b4e61f`.
- [Exact-source CI](https://github.com/felipedrf74/tokenroom/actions/runs/38298286634): all steps passed, completed 12 October at 19:43:24 UTC. Shared macOS/iOS/watchOS typechecks, Mac suite, mobile/widgets/Watch build, mobile test compilation and fallback build passed. The hosted iOS suite was executed locally, separately.
- Local qualification: 780 full Mac and 34 full hosted iOS tests passed, zero failures/skips. Independent source/diff/documentation review passed. Both P2 and fresh P3 findings are closed. Native ordinary/largest, light/dark, four-section, source/search/follow, ranking/details, Saved/Undo, recovery, Share cancellation and Reduce Motion checks have scoped receipts.
- All 198 production-input hashes match the signed source after integration. No new source/runtime change followed qualification.
- Apple build: `12b15493-c81e-4a63-b826-d1178056b33d`, version 1.1.1 build 1; four components share that version. Exact uploaded IPA SHA-256: `1d1be79d15bddd6be6ab45850e04768c85fb64496ab16d5b569496f947d2af2c`.
- All four strict signatures, Production entitlements, distribution profiles and executable UUID/non-signature-byte equivalence passed. Archive dSYM UUIDs match all uploaded executable architectures. The separately qualified export is preserved; its ZIP hash differs because Xcode re-signs the upload, not because source changed.

The push was a fast-forward. GitHub reported a PR-rule bypass for the user-authorized direct main push; no force push or branch-rule configuration change occurred. The existing branch/checkout remains intact.

## Apple submission

[Submission `16200897-ca51-4994-817d-04ce82c1f1ed`](https://appstoreconnect.apple.com/apps/6816126110/distribution/reviewsubmissions/details/16200897-ca51-4994-817d-04ce82c1f1ed) was accepted on 12 October at 20:46 Europe/Lisbon (19:46 UTC), with one item: **iOS App 1.1.1(1)**. The portal says Waiting for Review. Its submission validation passed; that is not approval.

Accurate What's New and review notes are saved. The native Today screenshot replaces the obsolete Following placement; its original stays in Asset Library. Seven saved iPhone screenshots are ordered Usage, detail, Home Screen widgets, Lock Screen, API keys, welcome, current Today. Smaller sizes inherit the large-display set. Existing Watch assets remain applicable. Manual release prevents approval alone from publishing this candidate.

Public mobile remains 1.1.0 at this checkpoint; its official US/PT lookup receipts show release on 12 October at 15:07:19 UTC. Mac 2.4.1 is a separate prior release; no new Mac package or production installation was made for this iPhone presentation change.

## Evidence and retained recovery material

Root: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-release-20261012/`.

- `implementation-closeout.json`, final tracked/untracked diffs — reviewed pre-integration snapshot; timestamped historical uncommitted state.
- `source-integration-receipt.json`, `ci-passed-receipt.json` — commit/main binding and actual CI success.
- `signed/production-inputs.json`, `signed/production-inputs-recheck.json`, `signed/uploaded-verification.json`, `signed/symbol-verification.json` — source, exact upload and symbols.
- `asc-1.1.1-draft-receipt.json`, `asc-submission-receipt.json`, `asc-waiting-for-review.png` — saved draft and accepted submission, kept as distinct states.
- `store-screenshot-receipt.json`, `store-news-today-native.png`, `asc-new-news-preview.png` — truthful native current News asset and provenance.
- `signed/retention-receipt.json` — persistent archive ZIP, qualified export and actual uploaded IPA. Archive/dSYMs/source/evidence remain preserved.
- `motion-housekeeping-receipt.json`, `motion-final-housekeeping.png` — final owned-Simulator Reduce Motion off and Auto-Play Message Effects on, matching original settings.

[Release qualification](ios-news-release-checks-20261012.md) retains the detailed checks and integration limits; [visual QA](../design-qa.md) distinguishes its earlier checkpoint from the final qualification. The [independent QA prompt](ios-news-independent-qa-prompt-20261012.md) remains reusable for the source change and later delivery evidence.

## Remaining external work and limits

Apple must approve the exact submitted build before it can be manually released. Then verify official version 1.1.1 availability before calling it public. No approval or public availability is inferred from processing, green CI or submission acceptance.

Spoken VoiceOver focus remains unverified; the user explicitly accepted proceeding with that limitation recorded. Existing same-account production iCloud/notification/App Group/device/Watch integration limits remain separate from this finite News presentation scope. No physical phone/Watch checks or new production app launches are claimed.

Post-release cleanup is deferred until public-version verification. Preserve source, signed archive/dSYMs/IPAs and receipts. Only proven redundant task-owned caches/captures and the two owned phone Simulators may be cleaned. Never globally stop/delete devices. The pre-existing Watch `27B4FF6C-73F3-4B3E-B1CB-077FB8A5DCA8` predates this task and must be retained; its association with the store-capture phone does not make it task-owned.
