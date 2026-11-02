# Mac popover design QA — 1 November 2026

final result: passed

## Findings

No actionable P0/P1/P2 findings remain. The final native app exposes provider rows as buttons, opens the selected provider's insights, returns to the overview, and retains the selected style after relaunch.

## Source and implementation evidence

- Source visual truth: `~/Documents/Tokenroom/design-variants-20261101/05.png` (Orbit), `09.png` (Instrument), `07.png` (Strata), and `04.png` (Aurora). Classic retains the existing `ProviderCard` presentation.
- Implementation captures: `~/Documents/Tokenroom/popover-validation-20261101/screenshots/`. `popover-{style}.png` and `popover-{style}-detail.png` cover each selected design; `-dark` variants cover dark appearance. The same folder contains many-provider, balance, stale, reset-pending, secondary-limit and expired-session fixtures.
- Combined reference/native comparisons: `~/Documents/Tokenroom/popover-validation-20261101/comparisons/{orbit,instrument,strata,aurora}.png`. Each board places reference overview, native overview, reference detail and native detail together.
- Source boards are 1342 × 1172 pixels. Each approximately 588-pixel-wide reference panel is normalized to 420 pixels. Native panels are 420 points wide at 2× density: Orbit overview 840 × 1334, Instrument/Aurora 840 × 1246, Strata 840 × 1302, and details 840 × 1344. Native captures are downsampled to 420 pixels for the combined boards. Classic remains 360 points wide. CSS viewport is not applicable to this native AppKit/SwiftUI app.
- Reference boards include decorative popover chrome and mock data. Fixture captures render the SwiftUI content; installed-app inspection also confirmed the actual NSPopover chrome. Exact reset times, history and forecast content intentionally differ because the implementation uses typed sample readings and the existing calculation APIs.
- The normalized boards are readable at native point size. Full-resolution captures were also inspected for percentage typography, ring caps, segmented fills and clipping; no additional focused crop is needed to judge those details.

## Comparison history

1. P2: the initial detail hero and pace sections pushed useful history too far down, and the Instrument overview clipped its final row. The hero was reduced to 128 points, history moved before the pace explanation, and row spacing was tightened. Revised evidence is retained in `/tmp/tokenroom-popover-qa-r2/` and `/tmp/tokenroom-popover-qa-r3/`.
2. P2: the first overview percentage could shrink to make the first `ViewThatFits` candidate fit vertically. Giving that candidate its natural vertical size lets the bounded scroll candidate handle overflow. The final screenshots and combined boards show consistent headline sizes and visible footer controls.
3. P1: an expired session with a cached reading lost its recovery controls in the new presentation. Expired sessions now use the original recovery card; `popover-orbit-expired.png` and a regression test cover this state.
4. P2: the visible primary pace warning was absent from the summary's accessibility label. The label now includes the warning, with tests for live, exhausted and stale readings.
5. P2: native inspection exposed the grouped provider row as an unknown accessibility role despite keyboard activation working. The final revision adds the button trait. Installed-app AX inspection confirms Button roles; activation opens OpenAI and Grok Bot details, and Back returns to the overview.

## Fidelity surfaces

- **Typography:** native system type, tabular/proportional percentage hierarchy, smaller percent signs, 16-point provider names and enlarged 32–36-point overview figures. The 128-point Orbit detail ring leaves room for the requested KPIs. This is an intentional adaptation of the mock, rather than reproducing its much taller hero.
- **Spacing and layout:** 420-point new styles, 20-point side insets, consistent row separators, pinned header/footer and a bounded 520-point scroll viewport. Many-provider captures retain access to every row. Classic retains its compact original presentation.
- **Colors and tokens:** all usage levels use the existing semantic Tokenroom colors. Instrument keeps its navy surface and segmented meters; Strata its broad bands and fill-edge marker; Orbit its circular meters; Aurora its tinted native material. Material appearance adapts to macOS rather than baking the reference's decorative background into a bitmap.
- **Assets:** existing provider assets and SF Symbols remain sharp at native density. No invented brand marks or screenshot backgrounds are used as application content.
- **Copy and content:** remaining quota, daily allowance, seven-day history, pace and projected limit use real model values. Daily allowance is remaining quota divided by days to reset, not a predicted usage rate. Stale or elapsed readings do not produce live advice; monetary balances retain their units. The requested KPI sections intentionally move secondary limits below the initial viewport; they remain reachable by scrolling.

## Runtime and verification

- Installed a Developer ID signed, Apple-notarized build with Production iCloud entitlements. Previous installed apps remain in the local release rollback directory. Installation and source receipts are under `~/Documents/Tokenroom/popover-validation-20261101/`.
- Exercised all five styles through the popover palette. Exercised the Settings > Menu Bar picker and restored Orbit. Relaunch retained Orbit without altering the menu-bar meter preference.
- Verified provider detail, Back, keyboard activation, accessible scroll-to-bottom, Classic expansion and refresh. Observed current readings from all four enabled providers, including Grok Bot, and the app's iCloud-sent status. This does not claim physical iPhone/Watch delivery or App Store publication.
- Full Mac suite: 955 tests, zero failures. Shared typechecks, iOS/widgets/Watch build-for-testing and Command Line Tools fallback passed. The final accessibility-only delta also compiled in a signed archive and received a fresh static review with zero findings; targeted popover tests are recorded separately.
- Live account screenshots were not added to the repository or PR. Published/reusable visual evidence uses synthetic fixtures only. Browser console checks are not applicable to this native app.

## Follow-up polish

- The banked-reset highlight opens the first applicable provider in the existing provider order. `QuotaStore.bankedResets.providers` is an ordered array, not a set. A provider chooser could improve this shortcut when several providers have banked resets; every provider remains directly accessible from the overview.
- Human VoiceOver listening and additional physical screen sizes were not attested. Native AX roles, labels and actions were checked on this Mac.

## Implementation checklist

- [x] Orbit default plus Instrument, Strata, Aurora and Classic choices.
- [x] Saved preference and native palette/settings controls.
- [x] Useful, freshness-aware usage insights and original recovery behavior.
- [x] Light/dark, density, overflow and exceptional-state visual comparison.
- [x] Installed-app navigation, accessibility role and relaunch validation.
- [x] Fresh review and local build/test evidence.

Public distribution remains a separate maintainer merge and release step.
