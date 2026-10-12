# iPhone News Editorial Briefing — implementation

Status: implementation complete and integrated as `740f9a0`; exact-source CI passed. Apple accepted mobile 1.1.1(1), now Waiting for Review with manual release selected. Approval and public availability remain pending. [Submission record](ios-news-release-delivery-20261012.md) is the current delivery authority; [release checks](ios-news-release-checks-20261012.md) preserve detailed qualification. Public mobile 1.1.0 and the published Mac 2.4.1 package are distinct releases.

## Selected direction

Felipe selected option 1 from the iPhone concepts. Visual truth: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-design-20261012/03-option-1.png`, SHA-256 `f3356dbdc58ac1589f662e047a7a9fc58b28885d93c420ecc4d7ee438e2c63ee`. It restores the editorial hierarchy lost when the old illustrated phone cards were replaced by a uniform reader-card layout.

This is native SwiftUI. The mock omits OS chrome and uses illustrative copy; production views retain native status/navigation/tab bars, actual supplied titles/excerpts/dates and official catalog assets. The decorative portrait artwork is the exact already-approved Mac asset, SHA-256 `1e602ee9993b68c81bd673ecc751e9ad4e44a617b71c00fd19dfd15bfec6039a`, reused in the mobile catalog. Voices use honest initials; no fabricated portrait or X feed is introduced.

## Implemented scope

- Today: compact masthead/date/search/settings, section selector, compact truthful freshness link, side-by-side lead at ordinary sizes, grouped releases, models, followed voices/status and retirement shelves, collection/recovery links. Lead is excluded from its supporting release list.
- Following: grouped official tools/labs, curated voices and provider status; actual marks and independent source navigation/follow actions. Filters, full source health/retry and existing choices are preserved.
- Skills: native ranking choices, supplied owner/rank/metrics, short previews and clear ranking/check/error semantics. Full details retain declared requirements, version, compatibility limitations and owner-qualified original links.
- Saved: attributed grouped snapshots, kind/search filters, atomic removal/Undo and proper empty/no-match states. Saved metadata stays local; original content needs a connection.
- Reader/collections: editorial titles, source/lab marks, shared canvas, complete supplied summaries, native original/save/share controls, visible source/collection search and native Back.
- Larger text: selectors become menus; story/model/skill/saved action rows stack; lead artwork stacks; freshness text and Details stack; compact control glyphs stay inside 44-point targets. Card excerpts are bounded previews, with complete text in readers.
- Save/Undo retains one state-owning control through adaptive hero and detail layouts. Article freshness is explicitly qualified when only model labs are followed; Source Health reports the model catalog separately. News uses the existing accessible accent text token for native links and its selected tab in light and dark mode.

No feed parsing, notification, auth, storage schema, account, X API, skill execution or relay changes. The existing stores own all actions. Obsolete generic phone root/follow/saved/skills markup is removed in favor of platform routes.

## Changed files

Source: `Shared/UI/NewsMobileStyle.swift`, `NewsMobileContent.swift`, `NewsMobileDiscovery.swift`, `NewsReaderContent.swift`, `NewsReadingViews.swift`, `SkillViews.swift`, `TokenroomMobile/NewsView.swift`, `TokenroomMobile/RootView.swift`, and `TokenroomMobile/Assets.xcassets/NewsEditorialArt.imageset/{Contents.json,NewsEditorialArt.png}`.

Metadata: `Config/Version.xcconfig`. Documentation: changelog, Apple/macOS skills, `docs/app-store.md`, this note, `docs/ios-news-release-checks-20261012.md`, root visual QA and the independent QA prompt. The historical Mac report is preserved at `docs/mac-news-visual-qa-20261012.md`; its implementation/delivery/skill pointers follow that copy.

## Validation boundary

Evidence root: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-implementation-20261012/`. DerivedData remains outside source. Root [visual QA](../design-qa.md) is the current authority for exact checks, captures and dispositions.

A task-owned iPhone 13 Simulator on iOS 27 (`C409E3C9-807D-4F67-AB32-6E1ADAD7FCF3`) runs with `-TokenroomSnapshotNews <fixture>/news.json -onboarded YES -TokenroomOpen tokenroom://news`. This selects inert stores, isolated preferences, mocked keys, nil cloud/disk storage and no device SDK effects. Public fixture files are inputs, not modified outputs; saves are intentionally memory-only there. Registry fixture check times represent an inert fetch, not a live ranking refresh.

The final full Mac suite passed 780 tests and the full hosted iOS suite passed 34, with zero failures/skips. Shared macOS/iOS/watchOS typechecks, the final Simulator build, optimized Swift fallback, signed Release archive, export and private Apple upload passed. Exact uploaded signatures/entitlements/profiles and executable equivalence are verified independently of upload success. Apple processed build `12b15493-c81e-4a63-b826-d1178056b33d` as Ready to Submit; manual release is selected.

The independent source review confirmed both earlier P2 fixes and found two P3 issues, now fixed and re-reviewed: short hero titles have a 44-point rectangular tap target, and retained Undo speaks the removed snapshot's title after hero promotion. Native captures demonstrate both behaviors. Skills-unavailable Retry completed honestly without a successful-check date; Share dismissed without sending; Reduce Motion reader/Back passed and its original off setting was restored. Repeated external Simulator shutdowns are recorded separately from app behavior.

Current qualification evidence: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-release-20261012/`. Earlier visual evidence remains under the implementation root. Test runs follow both source fixes; version metadata subsequently changed to unused 1.1.1(1), which the final Debug build and signed Release archive compile. The production-input manifest binds 198 source/resource/config/project files to the signed candidate.

The design gate remains separate from publication. Spoken VoiceOver focus, production iCloud/notifications/App Group effects, physical phone/Watch delivery and real device persistence are not established by isolated native captures. The user stopped physical phone work and has no Watch/shared-account device set. These are explicit integration limits of the approved finite News scope. Current accessibility labels/large-text/native navigation and mocked persistence/isolation tests are distinct evidence. Felipe accepted proceeding with spoken VoiceOver recorded as an unverified limitation.

The reusable [independent QA prompt](ios-news-independent-qa-prompt-20261012.md) asks for separate source, visual and release verdicts.
