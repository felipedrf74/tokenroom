# iPhone News Editorial Briefing — visual QA

Scope: native iPhone News presentation implementing Felipe's selected option 1. Source based on `ac66a4966b3779657be2cefe50d319a201b4e61f`, reviewed 12 October 2026 and integrated as `740f9a0`. This is a presentation/source gate, not release qualification. Historical Mac QA is preserved at [docs/mac-news-visual-qa-20261012.md](docs/mac-news-visual-qa-20261012.md); the published Mac package is unchanged.

## Visual truth and captured implementation

Evidence root: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-implementation-20261012/`.

Earlier captures 01–41 are under its `screenshots/` directory; current captures 44–58 and their AX records are at the evidence root.

- Exact selected source: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-design-20261012/03-option-1.png`, 853 × 1844 pixels; SHA-256 `f3356dbdc58ac1589f662e047a7a9fc58b28885d93c420ecc4d7ee438e2c63ee`.
- Native Today: `47-dark-reviewed.png` and `44-light-reviewed.png`, each 1170 × 2532 pixels from the task-owned iPhone 13 Simulator, 390 × 844 logical points at 3× density, iOS 27.
- Full source/current comparison: `49-source-vs-native-reviewed.png`, selected source plus native dark and light in one image, normalized to 390 × 844 each. Reviewed together, then at the lead scale in `50-focused-lead-reviewed.png`.
- Other current sections: `48-following-reviewed.png`, `53-skills-reviewed.png`, `55-saved-reviewed.png`. `58-iphone-news-sections.png` shows all four native sections at a common scale.
- Adaptive evidence: `screenshots/38-largest-metrics-fixed.png`, `45-hero-undo-largest-window.png`, `45-hero-undo-largest.ax.txt`, `46-detail-undo-largest.ax.txt`; earlier maximum-size navigation/health/model captures 31–36 supplement these.
- Model-only follows: `51-models-only-window.png` and `52-models-only-health-window.png`, with paired AX records.
- Recovery: `56-source-failure-window.png` and `56-source-failure-retry.ax.txt`; `57-skills-unavailable-window.png` renders the honest cold-unavailable state. Its earlier Retry-response capture was interrupted; the later release-check receipt below closes that interaction.

Native viewport images were saved through Device Hub's Screenshot control. Files ending `-window.png` include the Device Hub frame, typically 784 × 1684 pixels; they are not same-density app screenshots. There is no CSS viewport. The source omits OS chrome; native status/notch/navigation/tab bars remain. The comparison checks composition and visual style, not pixel-perfect type or identical publisher data. Native genuine titles are longer than some illustrative mock rows, and check/published clocks differ. Native rows scroll beneath the system floating tab bar with bottom padding allowing final actions to clear it.

The approved Mac portrait artwork is reused byte-for-byte in the mobile asset catalog, SHA-256 `1e602ee9993b68c81bd673ecc751e9ad4e44a617b71c00fd19dfd15bfec6039a`. It is decorative artwork, not a claimed publisher image. Official source/lab marks use the catalog; unsupported identity uses honest initials. No new generated logo or voice portrait is introduced.

## Findings, corrections and post-fix evidence

| Finding | Correction | Evidence |
|---|---|---|
| Generic uniform cards, tall navigation chrome and oversized separate actions lost the selected editorial hierarchy | Dedicated mobile views, compact masthead, branded lead/artwork, grouped release rows and inline actions | Full/focused source comparison 49–50; sections 58 |
| First lead layout put its actions in a separate full-width band | Integrate Read/Save in its text column; keep genuine complete headline | 05–06, final 47/50 |
| Enlarged masthead/control glyphs overlapped; source-status columns became narrow fragments | Stack masthead/status at larger type; fix icon sizes inside 44-point targets | 30 before, 31/36/45 after |
| Accessibility cards grew into excessively long summary walls; lifetime-download qualifier clipped | Bounded browsing previews, full reader summaries, stacked metrics and vertically wrapping download label | 35/37 before, 38 after; native reader actions 26 |
| Independent source review: duplicate state-owning Save controls could lose Undo during reflow | One stable Save child under AnyLayout in hero and detail | Native Unsave → largest text → normal → Undo restored in both; 45–46 AX records |
| Independent source review: model-only follows could say No sources followed | Explicit No article feeds followed; model catalog check remains separate | Native models retained in 51; Models checked with zero article feeds in 52 |
| Small native light-mode News links and selected tab inherited the lower-contrast generic accent | Scope the existing accessible accent text token to the selected News tab | Before 41; after 44, final combined 49; independent source review |
| Source-health failure AX label appended an extra final period | Preserve an existing final period before appending Source check details | Final source review and closeout build/typechecks; punctuation-only change after the visual captures |

No confirmed P0/P1/P2 remains in the reviewed presentation sources or captured layouts. Source review and rendered visual review have distinct scopes. The earlier external Simulator interruption is historical; the release-check addendum below records the completed retry response.

## Fidelity surfaces

- **Typography:** scaled native serif lead/reader titles and SF controls/metadata preserve the selected editorial hierarchy. Actual full lead headlines wrap; ordinary compact rows may show a bounded title, with full content in readers. Section/ranking menus retain full accessible labels at larger sizes.
- **Layout:** 20-point gutters, compact date/masthead, restrained section spacing, grouped divider rows and 18-point card corners. Artwork sits beside the ordinary lead's text column, then stacks for narrower widths/larger text. Following, Skills and Saved use layouts suited to choosing sources, scanning rankings and managing reading snapshots.
- **Color:** dark charcoal and warm orange follow the selected style; light uses grouped-system-like canvas and white panels. Secondary text is light 100/100/100 and dark 170/170/170. White primary-action text uses the darker 177/84/42 fill (approximately 5.03:1). Native News links use the existing accessible text accent; this is not a claim that every OS-generated disabled/control color was audited.
- **Images/icons:** approved portrait illustration is sharp, correctly clipped and decorative/AX-hidden. Catalog source marks, truthful initials and SF Symbols serve distinct identity/action roles. Control symbols remain fixed-size inside 44-point targets.
- **Content:** actual supplied title/excerpt/date/source, read/New metadata, owner-qualified skill attribution, actual ranking/metric definitions and separate article/model freshness. Public voice articles and X profile-only sources remain distinguishable. Reset times stay in Usage; no fabricated X timeline or skill compatibility claim is added.

## Native interactions observed

All app runs used DEBUG snapshot composition with inert stores and isolated preferences; no production app or provider check was launched.

- Today → native reader → Back; read marker and complete supplied summary. Hero Save/Unsave/Undo and reader Unsave/Undo, including transitions to the largest accessibility text size and back, restored the saved item.
- Saved remove → empty → Undo restored the displayed saved date; query no-match and closing search recovered the list. Final unpinned Today → Saved was captured in 55.
- Following source navigation and independent follow switch changed off/on. Source search for a retained version filtered the source family; closing recovered results. Curated voice directory and a profile-only voice detail were checked.
- Trending, Downloads and Newest loaded distinct fixture order/definitions; skill detail showed owner/requirements/version/original/actions and returned to its shelf. Skills Save changed the bookmark state. Ordinary ranking choices have explicit AX names/selection; larger type uses menus.
- Maximum text showed readable masthead/status, reachable section/rank menus and model/reader bottom actions. Final lifetime-download text wrapped completely. No spoken VoiceOver attestation is inferred from AX labels.
- Native Share sheet opened. An attempted dismissal selected the public Open Safari action; the public GitHub original opened and returned through the system Tokenroom Back control. No share was sent. A later dismissal-only check passed; see the release-check addendum.
- Model-only follow launch retained model cards and qualified zero article feeds; health retained its model checked date.
- Simulated source failure retained previous stories, identified the source, and targeted Retry left the inert failed fixture honest. Skills missing-fixture bodies rendered No skills loaded with a reachable Retry skills control and no successful-check date; its later Retry completed with the honest failed state and no successful-check date.

A `-newsDestination Skills` launch argument pins that AppStorage value, so its section-switch attempt is not navigation evidence (`54-skills-pinned-destination-window.png`). A subsequent launch without the argument proved section navigation to Saved. Model-only preferences were supplied solely to the inert launch's argument domain; production defaults were untouched.

## Earlier visual checkpoint — executed checks and source review

| Check | Result and evidence |
|---|---|
| Selected Mac News/Library/Discovery/source-contract/Skills/QA/presentation tests | 101 passed, zero failed/skipped; `news-final.xcresult`, `news-tests-summary.json`, `logs/news-tests-final.log` |
| Hosted iOS MobileRuntimeTests | Five passed, zero failed/skipped; `mobile-runtime.xcresult`, `mobile-runtime-summary.json`, `logs/mobile-runtime-tests.log` |
| Final shared typecheck | macOS/iOS/watchOS passed; `logs/shared-typecheck-closeout.log` |
| Final unsigned generic iOS Simulator build | Build succeeded, including embedded widgets/Watch; `logs/mobile-build-closeout.log` |
| Independent dirty-source review | Two P2 findings fixed/re-reviewed; no remaining concrete actionable bug. Additional RootView tint and AX-punctuation changes reviewed separately |
| Final diff | Tracked/untracked source and documentation reviewed; whitespace check passed; HEAD unchanged, no version/signing change |

The test runs include the functional Undo/freshness fixes and News tint. Only the final punctuation-only accessibility label change followed them; its final compile/typecheck/source review passed without rerunning the suites. The selected Mac suite emits the existing test-only State-outside-installed-View warning in NewsDiscoveryTests, with no failure. A full product suite was not rerun for this scoped presentation change. All DerivedData stays outside source; the installer script was not used.

## Validation limits and release boundary

Another Simulator workflow repeatedly shut down this task's device, confirmed by Felipe. Only the owned UUID `C409E3C9-807D-4F67-AB32-6E1ADAD7FCF3` was provisioned/operated; no other workflow's device was stopped or deleted. The stopped-device AX record is not a successful retry result. A subsequent uninterrupted Retry response is recorded in the addendum.

At this earlier visual checkpoint, human VoiceOver speech/focus, a fresh Reduce Motion toggle/restoration, share dismissal alone and live feeds/registry delivery were unverified. The addendum closes motion, Share cancellation and the public registry contract check without claiming device transport or spoken VoiceOver. No custom animation was introduced. The fixtures cannot prove production disk persistence, notifications, private iCloud, provider authentication, signed App Group behavior or physical Watch acceptance. Existing focused tests cover persistence/isolation contracts; native fixtures deliberately keep saves in memory.

At the earlier visual checkpoint, no signing/version/publication action had occurred. The later qualification used unused mobile 1.1.1(1), documented below; its subsequent public release is recorded separately in the [delivery record](docs/ios-news-release-delivery-20261012.md). Historical Mac publication/installation receipts remain in their dedicated report. See the [implementation note](docs/ios-news-editorial-redesign-20261012.md) and [independent QA prompt](docs/ios-news-independent-qa-prompt-20261012.md).

## Release-check addendum — 12 October 2026

The current source retains the selected composition. Two fresh independent P3 findings were fixed: the short hero headline label has a 44-point minimum height and rectangular hit region; Undo’s accessible name uses the retained removed snapshot, even if the lead is replaced. Native `short-title-lower-target.ax.txt`, `undo-after-hero-change.ax.txt` and `undo-original-story-restored.ax.txt` confirm those journeys.

Current evidence root: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-release-20261012/`.

- `skills-unavailable-after-retry.ax.txt/.png`: completed cold Retry retains the unavailable message and no invented successful-check date.
- `share-dismissed.ax.txt/.png`: native Share closes via Cancel, returns to the reader and sends nothing.
- `reduce-motion-before-current.ax.txt`, `reduce-motion-on-reader.ax.txt/.png`, `reduce-motion-on-back.ax.txt`, `reduce-motion-restored.ax.txt`: Reduce Motion on, reader/Back, off restored. Previous ordinary reader/Back evidence covers motion off. External shutdowns do not count as navigation results.
- `store-news-today-native.png`: current candidate’s native iPhone 18 Pro Max viewport, 1320 × 2868, ordinary text/dark, status bar 9:41. Actual retained public data and approved decorative artwork; no content or freshness dates redrawn. Prior iPhone 13/light/largest/four-section evidence remains valid.
- Full final Mac suite: 780 passed; full hosted iOS suite: 34 passed; zero failed/skipped. Shared typechecks, final version Simulator build and optimized fallback pass. These supersede the smaller earlier qualification scope. Existing Mac test-only State/QoS warnings are recorded in the result bundle; no new failing test.
- At the 12 October qualification checkpoint, signed 1.1.1(1) archive/export/private upload and exact uploaded artifact checks passed; Apple processed the candidate with manual release selected. These packaging/processing receipts are distinct from the later App Review and public-availability receipts.

Delivery update, 13 October: Apple approved the exact 1.1.1(1) build, the authorized manual release completed, and live official US/PT App Store pages show public 1.1.1 and its matching release notes. Both pre-publication CI runs, all 198 production inputs and retained signed-package hashes were freshly rechecked. Conservative cache cleanup completed with source, packages, logs and unique evidence retained; the two owned phone Simulators were already absent. See the [delivery record](docs/ios-news-release-delivery-20261012.md). Approval and publication do not extend the scoped visual/device acceptance.

See [release checks](docs/ios-news-release-checks-20261012.md) for signatures/source-input binding and the [delivery record](docs/ios-news-release-delivery-20261012.md) for passing pre-publication CI, exact approval, manual release and verified public availability. Current spoken VoiceOver focus remains unverified; Felipe explicitly accepted proceeding with that limitation recorded. Native AX/large-text checks do not claim it. No production Mac was launched or installed for this iPhone change.

final result: passed
