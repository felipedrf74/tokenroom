# Tokenroom 2.1 plan

What's left from the design review of September 26, 2026: the Usage tab, alerts, provider icons, News, and the release. The designs live in the Tokenroom Design System artifact (sections "Usage tab — review and variations" and "News — iOS and Mac redesign"). Each milestone below is one branch and one pull request, in this order; each keeps `./scripts/typecheck-shared.sh`, the Mac tests, the iPhone build, and the Command Line Tools fallback green, as CI does.

| Milestone | What | Status |
| --- | --- | --- |
| M13 | Usage tab: tiles (variation E3) and Close to a limit | Done on `tokenroom/usage-tiles-e3` |
| M14 | Alerts: "5-hour limit", the pace alert, separate switches (iPhone, Mac, Live Activity) | Next |
| M15 | Text-safe accent and critical colours | Small; can ride with M14 |
| M16 | Provider icons on every platform | Blocked on the decisions below |
| M17 | News on iPhone: the Today edition (River as an option) | Approved design |
| M18 | News on the Mac: the News window | Approved design |
| M19 | Release 2.1: docs, screenshots, App Store copy, TestFlight | Last |

## M13 — Usage tiles (done)

- `Shared/Core/UsageTiles.swift`: which window a tile shows as its ring (the long window) and its bar (the 5-hour session), "5-hour" naming, what counts as close to a limit (80% used, the limit reached, or ahead of pace with a run-out before the reset), and the urgency order. Tested in `TokenroomTests/UsageTileTests.swift`.
- `TokenroomMobile/UsageTileView.swift`: `UsageTileView`, `WindowStatus`, `CloseToLimitCard`. `UsageView` is a scroll view: Close to a limit, chips (banked resets, alerts off), a two-column `Grid` of tiles, Not connected. Freshness moved to the navigation subtitle. Next up and the news chips are gone.
- `UsageRing` takes a `paceMark` (a notch), `MeterTrack` a `solid` fill by level, `FollowButton` a compact label.
- Follow-ups kept for later: a stable tile order (today tiles re-rank by urgency on refresh), a larger text size check for the two-column grid, and a VoiceOver pass on a device.

## M14 — Alerts on iPhone and Mac

Today `AlertRules` (in `Shared/Core/Alerts.swift`) raises 80% and 95% alerts for every window, 5-hour sessions included, and the Live Activity follows a session. The design adds three things.

1. **Say "5-hour limit".** Add one display name for windows, shared by the tiles, alerts, the Live Activity, the provider detail, widgets, the Watch and the Mac popover (today the providers' own title, "Session", shows everywhere). Alert titles become "Claude: 80% of 5-hour limit used". Alert IDs don't change (they use the window ID), so no duplicates across devices.
2. **A pace alert.** A new `UsageAlert.Kind.runsOut`: "Claude: 5-hour limit runs out at 10:18 AM" / "86% used, 35 min before it resets at 10:53 AM." It's raised once per window instance, when the run-out first comes before the reset. For weekly and monthly limits it has to be at least a day early. It's urgent (it breaks quiet hours) only when the run-out is within the hour. It's skipped when the 95% alert for that instance has already gone out. Macs use their measured run-out (`RelayPace`); the iPhone uses `Pace.evaluate` with the week's history. ID: `evt-<provider>-<window>-runsOut-<instance>`.
3. **Separate switches.** `AlertPreferences` gains session thresholds, "before it runs out" for sessions, and the same for weekly and monthly limits. Decoding is lenient, and the new fields default from today's `thresholds`, so existing choices carry over. They're shared through the `prefs-alerts` record as today. Older builds keep fields they don't know, so there's no schema deployment.

Work:

- `Shared/Core/Alerts.swift`: the new kind, rule, preferences and subscription keys (`alertKey` for the new kind). Tests in `TokenroomTests/AlertTests.swift`, covering the rule, dedupe across devices, quiet hours, held alerts, and decoding old and new preferences.
- iPhone `TokenroomMobile/AlertsSettingsView.swift`: the sections from the design ("5-hour limits", "Weekly and monthly limits", "Also notify me when", Quiet Hours). Mac: the Alerts tab in `Tokenroom/Views/SettingsView.swift`, same switches.
- Mac `Tokenroom/Refresh/MacAlerts.swift` and `RelayPublisher` post and save the new kind like the others.
- Live Activity (`Shared/Widgets/SessionActivityViews.swift`): "5-hour" as the window title, a `MeterTrack` with the pace tick instead of `ProgressView`, and an alert when the pace alert fires, if on.
- To check before merging: an older iPhone receiving an `Event` with an unknown `alertKind` (the push still shows its title and body; make sure the ledger and claim paths skip it instead of failing). If they fail, add a `minReader` bump or keep the new kind off the shared record until readers update.

## M15 — Text-safe accent and critical colours

The brand orange (`#c47a2c`) is 3.4:1 on white as small text, and `critical` is 3.2:1 on dark cells. Add `TokenroomTokens.accentText` (`#9a5518` light, `#d98f4a` dark) and `criticalText` (`#c23b22` light, `#ff6b4f` dark) as dynamic colours. Use them for small orange and red text only: pace captions, "Runs out …", New labels, the banked badge, the Close to a limit header. The brand orange stays for controls, large numbers and the icon. `PaceStyle` and `TokenroomTokens.ink` are where most of it lands.

## M16 — Provider icons (blocked on decisions)

Decided: each provider's own icon replaces its monogram on iPhone, Watch, widgets, the Live Activity and the Mac popover. The monogram remains as the fallback, and the menu bar keeps its template glyphs.

Files: 5 app icons already in `Tokenroom/Assets.xcassets`, plus 12 official marks gathered from the providers' brand pages. The sources and terms are listed in the design system's "Provider icons" asset group.

**Decisions needed first:**

- **GitHub Copilot:** GitHub's logo terms require written permission for use. Ask GitHub, or keep the monogram.
- **OpenAI:** its logo kit asks you to accept usage terms. The repo's OpenAI icon covers OpenAI and OpenAI API for now.
- **xAI:** download the kit from x.ai/legal/brand-guidelines in a browser (the server refuses scripted downloads).
- **DeepSeek:** its terms allow the mark where you integrate DeepSeek, which Tokenroom does.
- **App Store:** third-party logos can draw questions in review (guideline 5.2). Decide whether iPhone and Watch ship with icons in 2.1, or the Mac gets them first. The repo's rule ("never provider logos on iPhone and Watch" in `.grok/skills/tokenroom-apple/SKILL.md`) changes with that decision.

**Work, once decided:**

- One asset catalog under `Shared/UI` (a synchronized folder, so every target that compiles `Shared/UI` gets it). Add the same files to the Command Line Tools fallback's loose resources, since `TokenroomImage` loads them there.
- A `ProviderMark` view in `Shared/UI`. It shows the icon when the catalog has one: marks that come without their own tile sit centred on a white tile with 18% clear space. Otherwise it falls back to `MonogramMark`. It replaces `MonogramMark` in the Usage tiles, Close to a limit, the provider detail, News rows, widgets, the Watch and the Live Activity (looked up by `providerID`).
- Accessory widget families and complications render desaturated or accented. Keep monograms or template glyphs there unless an icon reads well in those modes.

## M17 — News on iPhone (approved)

The Today edition from the design:

- **Dateline and filter chips:** Today · Models · Announcements · Retiring. `@AppStorage("newsSection")` gains a `today` case, and a stored unknown value falls back to Today.
- **"Since you last looked":** three counts from `NewsStore` (unseen models, unseen updates, retiring within 30 days), each opening its filter.
- **Top story:** the newest model from a lab you follow, one per visit. The art band is the lab's tint, the context window set large, and meter capsules.
- **More new models:** a row of model cards.
- **From your tools:** one card per followed tool, newest first. Up to three headlines each, with folded releases noted ("Also in Claude Code releases").
- **Retiring soon**, and the attribution footer.
- **River** as an optional layout for Announcements (a choice in Follow).

Work:

- `NewsStore` or a pure helper in `Shared/Core`: digest counts, the top-story choice, and grouping announcements by tool (`FeedSource` already maps sources to providers and folds a product's feeds).
- Views in `Shared/UI/NewsRows.swift` (`TopStory`, `ModelCard`, `SourceCluster`, `RetiringRow`, `RiverItem`), so the Mac can reuse them. Headlines use `.design(.serif)`.
- `TokenroomMobile/NewsView.swift` rebuilt around a `ScrollView`.
- Tests in `TokenroomTests/FeedTests.swift` for the counts, the top-story choice and the grouping.

## M18 — News on the Mac (approved)

`Tokenroom/Views/NewsWindowView.swift` becomes a `NavigationSplitView`:

- **Sidebar:** Today, Models, Announcements and Retiring with unread counts, then Labs and Your tools you follow.
- **Today page:** the same pieces as the iPhone in a `Grid`.
- **Toolbar:** Search (titles), Check now, Follow….

The window's minimum size goes from 460 × 520 to 820 × 560. The popover's pills open the window at their section, as today. News stays off until turned on.

## M19 — Release 2.1

- **Docs:** `docs/app-store.md` (copy and the screenshot list still mention Next up), README images regenerated with `-TokenroomSnapshots` and the iPhone sample mode, and the CHANGELOG dated.
- **Skill files:** the iPhone and Mac skill files updated for icons, alerts and News.
- **Design system:** the artifact marked as implemented.
- **CloudKit:** the new data is values inside existing fields (alert kinds, preferences in the payload), so no schema deployment is expected. Confirm in CloudKit Console before a Production build.
- **Builds and testing:** iPhone and Watch build 3 to TestFlight. Run `TokenroomMobileTests` locally on a signed host. Walk through alerts, the Live Activity, quiet hours and the new News on devices.
