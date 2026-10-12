# Mac News editorial redesign

This change was reviewed on top of `d94a60ab1732524e211073c74789eb561321dd9c`, in `tokenroom-improvements-20261004`. The 11 October visual checkpoint was uncommitted and unsigned. On 12 October the release candidate was promoted to Mac 2.4.1(1), signed and notarized; [the release record](mac-news-release-delivery-20261012.md) tracks the separate commit, CI, publication and installation gates. The submitted mobile 1.1.0(1) remains separate.

## Goal and visual target

Felipe selected the Editorial Briefing concept and asked that its art and style extend to the other News sections, with presentation appropriate to each section. The target is preserved at `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/mac-news-visual-audit-20261011/selected-editorial-briefing.png` (SHA-256 `0ddc3f7aaef01efbc494bd069e12c7474cd671131cd8799d5e586e47f0d075e3`).

The earlier Mac regression came from routing desktop content through the same stacked cards as the phone, removing source marks and the release rail, and applying phone control heights to Mac controls. The system serif headline was already intentional. This change restores a separate desktop composition while retaining the shared reader stores and actions.

## Implementation

- Today: editorial lead with decorative indigo artwork and a real supplied excerpt, a release rail, six additional updates in grouped columns, recent model cards, followed voices, opt-in status and the existing retirement horizon. Each story has one position in the briefing; See all opens the complete collection.
- Following: native source-group segments, compact branded tool rows, lab switches, voice cards with public-feed/X-profile attribution and separate opt-in status. Group-specific search has a real no-results state.
- Skills: adaptive cards, raw registry rank, owner, supplied summary, available lifetime downloads/stars, three original ranking definitions, check time and the existing error/cooldown behavior. Details remain owner-qualified and never install or execute a skill.
- Saved: kind segments, attributed compact rows, original saved dates, native detail, transitive Unsave and exact Undo through the existing library. The root owns library and Skills state across navigation.
- Collections and details: branded model grids, grouped announcement/commentary/status rows, truthful empty retirements, native search, Back, original links and sharing. Mac controls use pointer-appropriate sizes; iOS keeps its 44-point minimums and existing composition.
- Visual tokens: native system serif and SF typography, existing provider/lab assets, honest monograms when an asset is unavailable, subtle existing card fill, 12-point corners and inline bookmark/overflow actions. Desktop orange button fills are separate from orange text so white action labels have sufficient contrast.
- Width comes from the scroll viewport, rather than measuring already-sized child columns. The release rail and update columns stack when space is limited. The default window is 1160 × 800 points; the SwiftUI minimum is 820 × 560. On this macOS 27 host the native toolbar clamps the minimum observed outer window to 820 × 612 points. Captures report that actual size.

## Freshness and excerpt correctness

The earlier global source timestamp was the oldest successful followed-feed timestamp. A failed ChatGPT & Codex check made the whole page look ten hours old even though other feeds were recent. One targeted public-source retry in the installed app succeeded and cleared its warning. The transient failure's original cause was not established; this is not evidence of a stuck global worker.

`NewsSourceFreshness` counts distinct followed feeds separately as current (within the existing 15-minute visible interval), delayed or not loaded. First failure stays not loaded; an old/future success cannot claim current; a later success clears an earlier failure. Model freshness remains separate. Existing open/visible refresh intervals, one-hour failure cooldown, targeted retry and dispatch permission fences are retained.

Excerpt cleanup happens at the feed boundary. Raw HTML has markup/chrome removed before entities are decoded; XML/Atom XHTML text has already been flattened and decoded and only needs whitespace normalization. The first semantically nonempty field wins, so empty markup does not hide useful later content. Display and saving never reinterpret already-plain `<button>` or `<script>` examples as markup. Optional `excerptIsPlainText` metadata decodes older caches compatibly. A legacy nonnil excerpt causes an unconditional body revalidation only on its source's next due check, after the same permission/due checks. Successful reparsing resumes normal conditional GETs, retains first-seen dates and aliases, and does not rewrite old saved snapshots.

## Isolation and evidence

The DEBUG-only `-TokenroomNewsPreview YES` entry returns before migrations, status items, collectors and production lifecycle effects. It requires an input fixture and fails closed without one. It uses its own defaults suite, defaultAppStorage, memory-only library/Skills, nil relay and an owned temporary cache directory. Settings is disabled. Closing removes only that suite and temporary directory. The production app was never replaced or terminated.

Preview arguments are `-TokenroomSnapshotNews <fixture-directory>/news.json`, `-TokenroomNewsPreviewAppearance dark|light`, and optional `-TokenroomNewsPreviewWidth`/`-TokenroomNewsPreviewHeight`. Width/height arguments clamp to the supported SwiftUI minimum. Use an external DerivedData app; do not use the installer build script.

Public fixtures and logs live under `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/mac-news-visual-audit-20261011/`. `fixtures-v2/provenance-receipt.json` binds the exact parser to six retained public feed bodies, 117 parsed items, 35 models and three distinct actual ClawHub ranking responses. It preserves publisher/capture dates and all IDs. The failure fixture explicitly simulates the Copilot failure; it is not a newly observed outage. Original fixtures and receipts are retained. Frozen feed checks age honestly in screenshots. Skills' inert response check time means a fixture was read, not that the registry was contacted at that moment.

`design-qa.md` contains the actual visual comparison, iteration history and final acceptance status. Screenshots represent native SwiftUI/AppKit, not a browser recreation. Screen-sharing chrome and window activation vary independently of product layout.

## Changed files

- Shared core: `Feeds.swift`, `NewsFeed.swift`, `NewsPresentation.swift`, `NewsRuntime.swift`, new `NewsSourceFreshness.swift`.
- Shared UI: `NewsNavigation.swift`, `NewsReaderContent.swift`, `NewsReadingViews.swift`, `SkillViews.swift`, `TokenroomTokens.swift`, new `NewsDesktopContent.swift`, `NewsDesktopDiscovery.swift`, `NewsDesktopStyle.swift`.
- Mac: `AppDelegate.swift`, `DebugSnapshots.swift`, `NewsWindowView.swift`, new `NewsEditorialArt.imageset`.
- Tests: `FeedTests.swift`, new `MacNewsPresentationTests.swift`.
- Documentation: both `.grok` platform skills, `CHANGELOG.md`, this document and `design-qa.md`.

## Validation boundaries

Current validation receipts and the independent source/visual reviews are listed in `design-qa.md`. Meaningful regressions cover source freshness, preview inertness, HTML summaries, code-token preservation and the real conditional-fetch migration. Native checks cover Today/story/Back/read/save, Saved Remove/Undo, group-scoped Following search, public voice detail, all three Skills sorts, skill/model details and saves, source search/follow/refollow, sharing, separate collections, narrow/light layouts and retained failure controls.

This is an unsigned isolated News presentation check. It does not prove spoken VoiceOver, real production provider checks, notifications, CloudKit, signed App Group behavior or cross-device delivery. These are separate from this Mac-only visual change and from the earlier release's receipts. The retained Command-[ implementation is source-reviewed; this pass's native automation could not verify that chord because the input backend rejected the literal bracket key and its alternate key spelling did not dispatch it. Native Back buttons were executed successfully.

## Independent QA prompt

Review the final uncommitted checkout in `tokenroom-improvements-20261004` against `d94a60ab1732524e211073c74789eb561321dd9c`. The original goal is to implement Felipe's selected Editorial Briefing visual concept throughout native Mac News while preserving the product's account-free reader behavior and phone presentation.

Read this document, `design-qa.md`, both `.grok` platform skills and the actual tracked/untracked diff. Open the selected reference and the native implementation captures together; distinguish current evidence from older release results. Report concrete bugs, missing scope and validation gaps with file/line, trigger, consequence and smallest fix. Do not edit, commit, release, access credentials or launch production checks. Do not run more tests unless Felipe authorizes that review to do so.

Inspect carefully: root library/Skills lifetime, Back and source search, transitive Unsave/Undo, raw ranking positions and sort-specific fixtures, real source freshness, first-nonempty excerpt selection, code examples and old-cache migration, viewport-derived columns, detail controls at narrow width, button contrast and known lab/source marks. Verify stale/empty/failed feeds, unfollow/refollow, missing publication/link/metrics, long/non-Latin titles, offline saved snapshots, first failure, paired-source partial health and simultaneous Skills readers. Preview/XCTest must stay isolated even if only the preview boolean is provided. No auth, login migration, cloud writes or skill execution may start.

Expected behavior is the implementation above. The app should remain native and useful with sparse or failed sources; dates, excerpts, popularity and source identity must not be fabricated for visual fidelity. Outstanding device/accessibility/integration limits must remain explicitly unverified rather than promoted from unsigned build/test success.
