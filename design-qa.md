# Mac News Editorial Briefing — visual QA

final result: passed

Scope: the new uncommitted native Mac News presentation, based on `d94a60ab1732524e211073c74789eb561321dd9c`. Review started 11 October and final captures/checks crossed into 12 October 2026 (Europe/Lisbon). This receipt is separate from the already released Mac 2.4.0 and submitted mobile 1.1.0 candidate.

## Visual truth and comparison

Evidence directory: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/mac-news-visual-audit-20261011/`.

- Source visual truth: `selected-editorial-briefing.png`, 1487 × 1058 pixels, SHA-256 `0ddc3f7aaef01efbc494bd069e12c7474cd671131cd8799d5e586e47f0d075e3`.
- Final implementation: `70-editorial-today-v9.png`, 2320 × 1600 pixels, native 1160 × 800 point outer window at 2× density.
- Full-view comparison: `73-reference-vs-native-v9.png`, source and implementation in the same comparison image, each normalized by width to 1160 pixels with aspect preserved.
- Focused comparison: `74-hero-comparison-v9.png`, real source and implementation lead regions together, each normalized by width to 780 pixels with aspect preserved. This checked readable headline, source mark, excerpt, art crop and action rather than relying on the reduced full view.
- Final other sections: `71-editorial-following-v9.png`, `72-editorial-skills-v9.png`, `75-editorial-saved-v9.png`; summary board `76-editorial-sections-final.png`.
- Narrow light/failure: `60-editorial-light-failure-v9.png`, 1640 × 1224 pixels, native 820 × 612 point outer window at 2×. The SwiftUI minimum is 820 × 560; native toolbar chrome clamps the observed outer height to 612. This is not a claim of a 560-point outer-window capture.
- Skills unavailable: `61-editorial-skills-unavailable-v9.png`, same narrow/light window. Missing fixture Skills bodies deliberately simulate unreachable, with an explicit README; no real registry outage is claimed.

There is no CSS viewport or browser deviceScaleFactor: the implementation is SwiftUI/AppKit. The source's pixel density was not supplied. Width normalization permits composition/style comparison, not pixel-perfect typography or same-data precision. Publisher copy, followed sources, dates, New/read metadata and native toolbar/selection chrome differ. Captures use retained actual public fixtures, with capture/check dates preserved; clocks naturally crossed midnight. The real Tokenroom icon replaces the mock's Anthropic icon in the app toolbar. System selection/accent and missing-logo monograms remain native and honest.

## Findings and iteration history

| Finding | Correction | Post-fix evidence |
|---|---|---|
| Earlier desktop used one stacked phone-style card format and oversized controls; source marks and the rail were lost | Dedicated desktop views; native-sized controls; branded inline rows; lead plus rail; grouped update columns and model grid | 20–32, then final 70–75 |
| First implementation stacked at default width and failed to show the asset; raw appended HTML appeared in the lead | Responsive desktop composition; catalog/loose-resource-compatible `NewsEditorialArt.png`; first meaningful excerpt at parser boundary | 11–12, final 70 and 74; excerpt regression logs |
| Narrow child-width feedback hid sidebar/rail | Width comes from containing scroll viewport, independent of already-sized children | 13 before, 14 after; final 60 |
| Following's visible segmented label wrapped into fragments | Visually hidden segmented labels retain accessible names | 16 before, 21 and final 71 after |
| Decoded code tokens were stripped on repeated HTML cleaning; markup-empty description hid real content | Parser distinguishes raw HTML and flattened XML, finalizes each candidate semantically, never re-cleans display/save text; due legacy caches revalidate body once | Failing `excerpt-provenance-red.log` and `legacy-excerpt-red.log`, passing regression and full-suite logs |
| Saved models used a generic publisher letter despite an available lab asset | Resolve known public lab names through existing `LabMark`, retaining an explicit SpaceXAI alias | 31 before, 51 and final 75 after |
| White prominent labels on the dark orange text token measured about 2.63:1 | Separate darker `newsActionFill` for Mac button/monogram backgrounds | 50 and 53, final 60 and 70; measured 5.03:1 |
| Separated date/freshness and generous shelf spacing pushed all new-model context below first window | Group the header, combine wide date/freshness and tighten update-row padding; retain genuine long publisher titles | 40 before, 55 and final 73 after; New models heading reaches initial window |
| Flat panels and off-center Retiring empty view weakened presentation | Existing subtle card fill and centered empty collection state | 54, then final captures |
| Light secondary text measured about 3.8–4.0:1 | Dedicated Mac secondary text: light 100/100/100, dark 170/170/170; iOS retains its original semantic secondary | 57 before, final 60 after; measured light 5.35–5.92:1 and dark about 6.10:1 |

The independent visual reviewer inspected full/focused combined images and final native captures and reported **passed**, with no remaining P0/P1/P2. Earlier blocked findings were fixed and recaptured. Optional P3: the native Skills unavailable message can be centered across the reader more explicitly. This does not prevent use or hide an action.

## Five fidelity surfaces

- **Typography:** native system serif lead/detail titles and SF controls/metadata preserve the editorial hierarchy. Genuine longer feed titles wrap; complete titles remain in details. Compact shelves and the release rail use smaller optical weights appropriate to scanning.
- **Spacing/layout:** matching lead/rail panel heights, grouped columns, 12-point corners, subtle borders and restrained section spacing. Parent-width reflow retains persistent controls at the actual supported minimum. Following, Skills and Saved use layouts suited to their distinct tasks.
- **Colors/tokens:** semantic primary text, existing card fill, orange text kept separate from button fill. Screenshot color profiles were converted to sRGB before independent contrast sampling: button 5.03:1; app metadata light 5.35–5.92:1; dark about 6.10:1. OS toolbar/disabled controls/default empty-view grays were not presented as app-wide compliance proof.
- **Image quality/icons:** generated decorative portrait artwork is sharp and cleanly cropped; it does not pretend to be a publisher photo. Provider/lab marks reuse the approved catalog, with honest monograms where missing. Known Saved lab identity matches Models. SF icons serve controls and generic skill identity; no fabricated portraits or logos.
- **Copy/content:** actual public publisher titles/excerpts, owner-qualified skill metadata, truthful separate freshness and explicit public-feed/X-profile distinctions. Popularity and compatibility are not equated. Missing dates/metrics/requirements and simulated failure/unavailable states retain explicit meaning.

## Native interactions and validation

Executed in the input-only DEBUG preview with production app left intact:

- Today → story → native Back, read marker, Save → Saved → Remove → Undo.
- Following group-scoped query: Tools & Labs + Simon gives no results; Voices reveals the profile; voice detail → Back retains group/query.
- Skills: three distinct captured sorts, correct first-row/rank/definition changes, detail, save and persistent root library across section navigation.
- Models: adaptive grid, real detail/context/prices and save. Announcement/commentary/status collections remain distinct; empty retirements are truthful.
- Source detail: native search finds retained weekly story; unfollow empties it; refollow restores the retained match.
- Native share menu opens and dismisses without sending. Public original links retain publisher/owner-qualified destinations; no skill install/execute path exists.
- Light/narrow failure Details shows the failed source, retained-article explanation and targeted Retry. Inert retries preserve the simulated state. Skills unreachable stays honestly unloaded with reachable Retry; no fake successful-check date appears.
- Preview closes cleanly; its process exits and owned suite/temp directory are removed. No production installation, credential read, provider check or cloud relay is part of this preview.

Current final source checks (all unsigned; DerivedData outside repository):

| Check | Result / evidence in the audit `logs/` directory |
|---|---|
| Full Mac suite | 780 tests, 0 failures; `editorial-final-v9-mac-tests.log` and its xcresult path |
| Freshness/preview/excerpt regressions | Failing-first cases followed by green relevant tests; final suite includes all 14 new regression methods |
| Shared typecheck | macOS, iOS, watchOS; `editorial-qualified-shared-typecheck.log` |
| Generic iOS Simulator build | Includes widgets and Watch; `editorial-qualified-mobile-build.log` |
| Native Mac build | `editorial-native-v9-build.log`; final test build also compiled the current source |
| Optimized Swift 6 fallback | Compile-only manual invocation, no installer/sign/launch; `editorial-final-v9-swiftc-fallback.log` and external `fallback/Tokenroom` |
| Loose art resource | Filename matches imageset/fallback lookup; exact-byte copy checked |
| Diff/source review | `git diff --check` passes; independent tracked/untracked source and preview-isolation sweep found no concrete defect |

Independent source review and native visual review are different evidence. Regression tests cover real parsing/HTTP migration and existing persistence/permission contracts; screenshots do not establish server delivery.

## Remaining validation limits

Spoken VoiceOver and complete keyboard traversal are not newly attested. Native Back was executed; Command-[ stayed source-reviewed, while this pass's computer-input backend rejected the literal bracket spelling and its alternate spelling did not dispatch the chord. The existing shortcut code was retained. No system Reduce Motion preference was changed; no custom animation was introduced.

At this visual checkpoint the work was uncommitted and unreleased. The subsequent [12 October release record](docs/mac-news-release-delivery-20261012.md) tracks Mac 2.4.1(1) signing, source binding, CI, publication and installation separately. Provider authentication, signed App Group behavior, notifications and cross-device CloudKit/device delivery were not exercised by these isolated News previews. Mobile/Watch compile evidence does not replace hardware acceptance. Original shipped-build receipts remain separate.

Implementation details, changed files and the reusable independent QA prompt are in [the redesign note](docs/mac-news-editorial-redesign-20261011.md).
