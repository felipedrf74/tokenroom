# Independent QA — iPhone News Editorial Briefing

Independently review the iPhone News change in the Tokenroom checkout at `/Users/felipedominguez/Developer/tokenroom-improvements-20261004`, from `ac66a4966b3779657be2cefe50d319a201b4e61f` through source commit `740f9a0a1d23210bfe25bd9220f30d86fca08515`, including any later uncommitted delivery documentation. Inspect tracked and untracked files. Do not assume implementation notes, prior review or green tests establish the behavior you are checking. Do not edit, commit, push, upload, release, install production apps or use provider credentials. Source review may be read-only; report separately whether runtime checks were actually executed. Follow repository AGENTS and Apple/macOS skills. Never use `scripts/build.sh` or operate another workflow's Simulator.

## Goal and selected design

Felipe reported that iPhone News lost its earlier visual quality and selected **option 1**: a compact native editorial briefing with charcoal/warm-orange styling, portrait lead artwork, official source marks, grouped releases and inline actions. Carry that art/style into Following, Skills, Saved, collections and readers according to their distinct needs. Preserve local account-free following/saved behavior, curated public voices/X profile links, official release/status feeds, source provenance and truthful skill rankings. No Tokenroom account, copied Mac credentials, phone OAuth for Mac-only tools, X API integration or skill installation/execution.

Exact selected visual: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-design-20261012/03-option-1.png`, SHA-256 `f3356dbdc58ac1589f662e047a7a9fc58b28885d93c420ecc4d7ee438e2c63ee`. Native source/current combined comparisons are in `ios-news-implementation-20261012/49-source-vs-native-reviewed.png` and `50-focused-lead-reviewed.png`; section board `58-iphone-news-sections.png`. All evidence paths in this prompt are relative to `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/` unless absolute.

## Implemented and changed files

- New mobile components: `Shared/UI/NewsMobileStyle.swift`, `NewsMobileContent.swift`, `NewsMobileDiscovery.swift`.
- Platform routes/readers: `Shared/UI/NewsReaderContent.swift`, `NewsReadingViews.swift`, `SkillViews.swift`.
- Root presentation/search: `TokenroomMobile/NewsView.swift`; News-specific accessible native tint: `TokenroomMobile/RootView.swift`.
- Exact approved Mac artwork copy: `TokenroomMobile/Assets.xcassets/NewsEditorialArt.imageset/{Contents.json,NewsEditorialArt.png}`; artwork SHA-256 `1e602ee9993b68c81bd673ecc751e9ad4e44a617b71c00fd19dfd15bfec6039a`.
- Metadata: `Config/Version.xcconfig`.
- Docs: `docs/app-store.md`, `docs/ios-news-release-checks-20261012.md`, `CHANGELOG.md`, Apple/macOS skills, `docs/ios-news-editorial-redesign-20261012.md`, this prompt, root `design-qa.md`, preserved `docs/mac-news-visual-qa-20261012.md` and historical Mac report pointers.

No feed/auth/notification/relay/storage-schema change is intended. Mobile version metadata now identifies the privately uploaded 1.1.1(1) candidate; Mac stays 2.4.1(1). Existing root-owned stores and production adapters remain responsible for those actions. Obsolete generic phone markup is replaced by platform-specific routing; Mac keeps its existing desktop presentation.

## Expected behavior and careful inspection

1. Today has compact masthead/date/search/settings, four section choices, compact source-health navigation, complete genuine serif lead title/art/read/save, grouped release rows, model/voice/status/retirement shelves and truthful recovery. Lead is not duplicated in its supporting release list.
2. Search opens natively on demand. Pushed readers/settings/source/collection pages restore visible navigation and Back; source/collection search stays discoverable. Check no hidden Back, stale search/focus or accidental nested action activation.
3. Following retains independent source navigation and follow switches, group-aware search, model lab choices, opt-in voices/status, source-family semantics and targeted recovery. Profile-only voices must not promise an X timeline or public feed.
4. Skills has three correctly labeled distinct sorts, actual owner/rank/raw metric definitions, supplied check/error/cooldown and compatibility/requirements details. Preview summaries are short; readers retain full supplied content. No fabricated popularity numbers, false successful check or installation path.
5. Saved shows attributed local snapshots and kind/search filters; remove and Undo preserve identity/saved date. Failed persistence/Undo remains action-scoped and retryable. Existing warning semantics are not hidden by the new compact controls.
6. **Previously found P2:** hero/detail Save must have one stable state owner across horizontal/stacked reflow. Unsave → change width/Dynamic Type → Undo must remain available and restore the same snapshot. Inspect AnyLayout child identity; no duplicate Save inside ViewThatFits.
7. **Previously found P2:** zero article feeds with followed model labs must say No article feeds followed, retain models and show the model check separately in Source Health. Failed sources must retain prior items and keep targeted retries honest.
8. Largest type stacks controls/art/metrics and uses menus for section/rank choices. Full accessible names, reachable 44-point targets, no clipped lifetime-download qualifier or enormous browsing summary wall. Ordinary segments expose correct AX selection.
9. Light/dark native links/tab label use the accessible News tint; Usage/Settings retain their default accent. White primary-action text uses the darker action fill. Catalog marks/voice initials are honest and decorative art is not read as editorial content.
10. Cross-platform compile/routing remains valid; shared reader changes must not regress Mac window/navigation/actions, widgets or Watch. Account/credentials/cloud/XCTest isolation must remain untouched.

## Executed evidence, not release proof

Current evidence root: `ios-news-release-20261012/`. Earlier visual/selected-suite evidence remains under `ios-news-implementation-20261012/`.

- Final full Mac suite: 780 passed, zero failures/skips — `mac-final.xcresult`, `mac-final-summary.json`, `logs/mac-final.log`.
- Full hosted iOS suite: 34 passed, zero failures/skips — `ios-full.xcresult`, `ios-full-summary.json`, `logs/ios-full.log`.
- Shared macOS/iOS/watchOS typecheck, final version Debug build and optimized Mac fallback passed; no installer or production app launch.
- Both earlier P2s remain fixed. Two fresh P3s were fixed and independently re-reviewed: short hero headline label has a 44-point rectangular hit area; Undo names the retained removed snapshot after hero replacement. Native lower-title tap and lead-promotion/Undo/Saved restoration receipts passed.
- Native Skills-unavailable Retry completed, Share cancelled without sending, and Reduce Motion reader/Back completed with off restored. Earlier full-section, ordinary/largest/light/dark/search/follow/source recovery and hero/detail adaptive Undo receipts remain applicable.
- Signed 1.1.1(1) archive/export/private upload passed. The exact uploaded IPA SHA is `1d1be79d15bddd6be6ab45850e04768c85fb64496ab16d5b569496f947d2af2c`; all four signatures/Production capabilities/profiles passed. Re-signing makes the export and uploaded ZIP hashes differ; UUIDs and all bytes outside code-signature payloads match, and plist values match.
- Apple processed build `12b15493-c81e-4a63-b826-d1178056b33d` as Ready to Submit/Validated. The private version draft has manual release selected. Source/input hashes, draft metadata and native screenshot preparation must be checked separately from upload success.

See `docs/ios-news-release-checks-20261012.md` for exact receipt filenames, qualification limits and remaining gates. Those are the historical pre-integration receipts. Source `740f9a0` is now on main with passing CI run 38298286634, and Apple accepted submission `16200897-ca51-4994-817d-04ce82c1f1ed`; current status is Waiting for Review. See `docs/ios-news-release-delivery-20261012.md` and the separate source/CI/submission receipts. Approval/public 1.1.1 availability remains unproven; earlier public 1.1.0 is a different build.

Use the task-owned UUID `C409E3C9-807D-4F67-AB32-6E1ADAD7FCF3` only. DEBUG launch must include `-TokenroomSnapshotNews <fixture>/news.json -onboarded YES -TokenroomOpen tokenroom://news`; fixtures are in `mac-news-visual-audit-20261011/fixtures-v2/`. These factories use inert stores, mocked keys, isolated defaults and nil production cloud/disk effects. Library saves intentionally remain in memory. Fixtures must remain read-only. An explicit `-newsDestination Skills` argument pins that preference, so omit it for cross-section navigation. Model-only launch arguments are inert preview inputs, not production preference edits.

## Gaps, assumptions and edge cases to verify

Another workflow repeatedly shuts down Simulators, confirmed in system logs even after the reported pause. Stopped-device captures are not results. The Skills Retry, Share cancellation and Reduce Motion gaps are now closed by uninterrupted native receipts. The only additionally created device is store-capture UUID `7E3C5A9B-9DE4-44B7-A23C-C8BF18A8579D`; do not operate other workflows' devices.

Check both earlier P2s and both fresh P3s independently. Inspect short/missing/long titles, retained Undo after reflow/hero replacement, complete alias restoration, source/model-only health, cold/retained/malformed/empty rankings, fast sort changes/cancellation/deadline/cooldown, saved no-match/removal failure, search cancellation, reader Back and summary reachability. Verify all six presentation areas reflect the selected style without changing their store contracts.

Spoken VoiceOver focus remains unverified; Felipe explicitly accepted proceeding with this limitation recorded on 12 October. Public registry response parsing is proven, not live iOS transport. Physical phone/Watch, same-account iCloud, push/notifications, production App Group and device persistence remain explicitly unverified integration limits; the user stopped physical phone work and has no Watch/shared account. AX labels, test hosts and embedded builds do not establish those effects. The working Trending endpoint advertises deprecation, with no sunset observed.

Report concrete bugs with priority, exact file/line, trigger, expected/actual result and evidence. Separate missing implementation items from validation gaps and optional polish. Give separate **source**, **visual**, **local qualification** and **publication** verdicts. Confirm final tracked/untracked docs and compiled-input hashes match the current candidate. A qualified private upload is not a public release; source main CI and submission are proven separately; approval/manual release/public availability are outstanding publication gates. Do not reuse consumed 1.1.0(1) or 1.1.1(1) for a different binary.
