# Mac News editorial release — 12 October 2026

Mac 2.4.1(1) is the signed, notarized release candidate for the approved Editorial Briefing redesign. Publication and both-Mac installation remain pending at this qualification checkpoint. Mobile 1.1.0(1) is unchanged; this release does not upload or submit another Apple build.

## Scope and qualification

Today, Following, Skills, Saved, collections and reading details use native desktop layouts, branded source marks, compact controls and decorative editorial art. Source freshness distinguishes delayed feeds from current ones; parser-boundary excerpt cleanup preserves supplied summaries and literal code examples. [The implementation note](mac-news-editorial-redesign-20261011.md) and [visual QA](../design-qa.md) contain the complete behavior, interactions, comparisons and independent review findings.

The source base is `d94a60ab1732524e211073c74789eb561321dd9c`. All 20 reviewed Swift/art changes match the final visual-review receipt. The release manifest covers 211 production inputs, excluding local signing configuration and user workspace state; SHA-256 digest `16bb1dce131f282e68fddd86f032c8b800846074eb8da9ceb365538e34d22d81`. The version was promoted before archiving. Full source binding must be rechecked against the committed revision.

| Gate | Evidence at this checkpoint |
|---|---|
| Independent source and visual review | Passed; no remaining P0/P1/P2. Optional P3: more explicit centering for the Skills unavailable message. |
| Current Mac suite | 780 tests, zero failures, no exclusions. |
| Shared checks | macOS/iOS/watchOS typecheck and optimized Swift 6 fallback passed on identical reviewed source. |
| Mobile compilation | Generic Simulator app/widgets/Watch build passed; release-turn `build-for-testing` passed. |
| Signed archive and export | Release archive and Developer ID export succeeded with existing authorized Apple credentials. |
| Signature and capabilities | Strict/deep signature, universal arm64/x86_64, hardened runtime, no debug entitlement, bundle/version/build and Production CloudKit/profile checks passed. |
| Notarization | Apple Accepted submission `35952d88-8033-48b7-a471-c06cdd67fbc5`; stapling and Gatekeeper Notarized Developer ID passed. |
| Final package round trip | All nine stapled app files match after ZIP extraction; strict signature and staple validate again. |
| Commit, main CI, publication | Pending. Public release requires successful CI for the exact source commit. |
| Installation | Pending. Both Macs must receive the verified public package with fresh rollback copies and independent installed-path checks. |

Candidate `Tokenroom-2.4.1.zip` SHA-256: `61eefdb22d79b618d6897010f4e9d6e4b9aac145dbdffca764c51014fe140b91`. Packaging uses an unsynced temporary folder because File Provider added FinderInfo to the evidence-folder export. The clean copy has exactly the same application file bytes and was not re-signed. The original failed strict-verification receipt remains retained.

Private evidence is under `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/mac-news-release-20261012/qualified`: source inputs, sanitized archive/export/notary logs, full-suite and mobile compilation logs, signature/copy bindings and notarized-package verification. Archives, dSYMs, sealed distributables, rollback copies and qualification evidence are retained.

## Acceptance limits

Native isolated News journeys, actual public fixtures, light/dark/narrow views and failure/empty recovery passed within the recorded scope. Spoken VoiceOver and complete keyboard traversal are not newly attested; native Back was executed, while Command-[ remains source-reviewed because the input backend did not dispatch that chord. No custom motion was added.

Production app startup, provider authentication, notifications, signed App Group behavior and same-account CloudKit delivery were not exercised by this Mac visual check. The actual devices use different private iCloud accounts, no Watch is available, and Felipe stopped further physical phone work. These unchanged limits are distinct from the finite approved Mac News acceptance. Installation will not launch the production app or inspect provider credentials. The previous 2.4.0 delivery and mobile submission receipts remain historical evidence.
