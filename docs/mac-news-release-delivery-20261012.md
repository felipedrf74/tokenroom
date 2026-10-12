# Mac News editorial release — 12 October 2026

Mac 2.4.1(1) is [publicly released](https://github.com/felipedrf74/tokenroom/releases/tag/v2.4.1) and installed on this Mac and Maquinho Pro (Apple M2 Pro). It implements the approved Editorial Briefing redesign. Mobile 1.1.0(1) is unchanged; this release did not upload or submit another Apple build.

## Scope and qualification

Today, Following, Skills, Saved, collections and reading details use native desktop layouts, branded source marks, compact controls and decorative editorial art. Source freshness distinguishes delayed feeds from current ones; parser-boundary excerpt cleanup preserves supplied summaries and literal code examples. [The implementation note](mac-news-editorial-redesign-20261011.md) and [visual QA](mac-news-visual-qa-20261012.md) contain the complete behavior, interactions, comparisons and independent review findings.

The source base is `d94a60ab1732524e211073c74789eb561321dd9c`. The released commit is `79d0b41f729fa48a0935d53e1e5383a0692b2a3b`, tree `172dbc88e346414e8ef99ebb6c08c2d2cdfa83dd`. All 20 reviewed Swift/art changes match the final visual-review receipt. All 211 committed production inputs match the archive manifest, excluding local signing configuration and user workspace state; SHA-256 digest `16bb1dce131f282e68fddd86f032c8b800846074eb8da9ceb365538e34d22d81`. The version was promoted before archiving. Main was fast-forward pushed using the account's existing configured admin bypass; no protection rules changed.

| Gate | Delivery evidence |
|---|---|
| Independent source and visual review | Passed; no remaining P0/P1/P2. Optional P3: more explicit centering for the Skills unavailable message. |
| Current Mac suite | 780 tests, zero failures, no exclusions. |
| Shared checks | macOS/iOS/watchOS typecheck and optimized Swift 6 fallback passed on identical reviewed source. |
| Mobile compilation | Generic Simulator app/widgets/Watch build passed; release-turn `build-for-testing` passed. |
| Signed archive and export | Release archive and Developer ID export succeeded with existing authorized Apple credentials. |
| Signature and capabilities | Strict/deep signature, universal arm64/x86_64, hardened runtime, no debug entitlement, bundle/version/build and Production CloudKit/profile checks passed. |
| Notarization | Apple Accepted submission `35952d88-8033-48b7-a471-c06cdd67fbc5`; stapling and Gatekeeper Notarized Developer ID passed. |
| Final package round trip | All nine stapled app files match after ZIP extraction; strict signature and staple validate again. |
| Commit and main CI | Released commit `79d0b41` is on main. [CI run 38186957040](https://github.com/felipedrf74/tokenroom/actions/runs/38186957040) passed all five required stages for that exact SHA. |
| Public release | Published 12 October at 00:19:49 UTC, latest and non-prerelease. Annotated `v2.4.1` dereferences to the released commit. Independent anonymous checks passed 21/21; the downloaded app passed another 27/27 package checks. |
| Installation | Both installed apps are 2.4.1(1), with all nine file hashes, CDHash, entitlements, universal architectures, strict signature, staple and Gatekeeper matching the public package. All 14 installation checks and fresh independent 25/25 installed-path checks passed on each Mac; previous 2.4.0 originals and verified rollback copies are retained. |

Public `Tokenroom-2.4.1.zip` SHA-256: `61eefdb22d79b618d6897010f4e9d6e4b9aac145dbdffca764c51014fe140b91`. All four anonymously downloaded assets match the qualified bytes and published sizes/digests. Public `release-source.json`, `production-source-inputs.json` and the checksum bind package, source commit/tree, all 211 inputs, CI and notarization. Packaging used an unsynced temporary folder because File Provider added FinderInfo to the evidence-folder export. The clean copy has exactly the same application file bytes and was not re-signed. The original failed strict-verification receipt remains retained.

Private evidence is under `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/mac-news-release-20261012/`: `qualified/` contains source/commit bindings, exact-CI receipt, sanitized archive/export/notary logs, full-suite and mobile compilation logs, signature/copy bindings, notarized package and retained test-result ZIP. `public-release-receipt.json` records the actual anonymous publication check; `independent-review/` separately records source, package and public-download reviews. `installation/` contains both 14-check install receipts and prepared recovery paths. Archives, dSYMs, sealed distributables, rollback copies and qualification evidence are retained.

## Bounded cleanup

After publication and both installations, eight exact task-owned DerivedData/module-cache/duplicate-extraction directories were removed following fresh canonical-path, ownership, symlink and no-handle checks. Their pre-removal allocation totaled 2,071,612 KiB (about 1.98 GiB); shared APFS extents mean this is not a claim of net recovered capacity. Installation staging on both Macs was removed only after ZIP hashes, state files and remaining installed/rollback bundles were checked. State files were copied into retained evidence. No Simulator was created or removed in this Mac release; shared devices and runtimes were untouched.

`after-release-local-cleanup-receipt.json` names every deleted path and exact retained archive, dSYM, distributable, evidence and rollback path. `installation/local-staging-cleanup-receipt.json` and `installation/m2-staging-cleanup-receipt.json` record staging removal separately. The sealed Mac test-result ZIP retains all 7,211 original result files. Source, worktrees, user caches/preferences, provider credentials, provisioning profiles and historical release evidence remain outside cleanup.

## Acceptance limits

Native isolated News journeys, actual public fixtures, light/dark/narrow views and failure/empty recovery passed within the recorded scope. Spoken VoiceOver and complete keyboard traversal are not newly attested; native Back was executed, while Command-[ remains source-reviewed because the input backend did not dispatch that chord. No custom motion was added.

Production app startup, provider authentication, notifications, signed App Group behavior and same-account CloudKit delivery were not exercised by this Mac visual check. The actual devices use different private iCloud accounts, no Watch is available, and Felipe stopped further physical phone work. These unchanged limits are distinct from the finite approved Mac News acceptance. Installation did not launch either production app or inspect provider credentials. Both apps are installed and closed; start them normally to use the update. The previous 2.4.0 delivery and mobile submission receipts remain historical evidence.

This after-release documentation update does not change application source, version configuration, signing inputs, package bytes or the release tag. Its later main revision is separate from the released application commit; it does not imply a rebuild, re-sign or another upload.
