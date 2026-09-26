# Tokenroom 2.1 plan

What's left from the design review of September 26, 2026: the Usage tab, alerts, provider icons, News, and the release. The designs live in the Tokenroom Design System artifact (sections "Usage tab — review and variations" and "News — iOS and Mac redesign"). Each milestone below is one branch and one pull request, in this order; each keeps `./scripts/typecheck-shared.sh`, the Mac tests, the iPhone build, and the Command Line Tools fallback green, as CI does.

| Milestone | What | Status |
| --- | --- | --- |
| M13 | Usage tab: tiles (variation E3) and Close to a limit | Done on `tokenroom/usage-tiles-e3`; follow-ups done in the audit |
| M14 | Alerts: "5-hour limit", the pace alert, separate switches (iPhone, Mac, Live Activity) | Done on `tokenroom/alerts-m14`; the iPhone's history and the Live Activity alert done in the audit |
| M15 | Text-safe accent and critical colours | Done with M14 |
| M16 | Provider icons on every platform | Done on `tokenroom/provider-icons-m16`; Watch rings done in the audit; the Copilot icon added after release (xAI API stays a monogram, waiting on its kit) |
| M17 | News on iPhone: the Today edition (River as an option) | Done on `tokenroom/news-ios-m17`; "Also in …" done in the audit |
| M18 | News on the Mac: the News window | Done on `tokenroom/news-mac-m18`; pill routing fixed in the audit |
| M19 | Release 2.1: docs, screenshots, App Store copy, TestFlight | Prepared on `tokenroom/release-m19`, README images retaken in the audit; the rest needs your accounts |

The audit's changes (see "Completion audit" at the end) are the last commit on `tokenroom/release-m19` (#19).

## M13 — Usage tiles (done)

- `Shared/Core/UsageTiles.swift`: which window a tile shows as its ring (the long window) and its bar (the 5-hour session), "5-hour" naming, what counts as close to a limit (80% used, the limit reached, or ahead of pace with a run-out before the reset), and the urgency order. Tested in `TokenroomTests/UsageTileTests.swift`.
- `TokenroomMobile/UsageTileView.swift`: `UsageTileView`, `WindowStatus`, `CloseToLimitCard`. `UsageView` is a scroll view: Close to a limit, chips (banked resets, alerts off), a two-column `Grid` of tiles, Not connected. Freshness moved to the navigation subtitle. Next up and the news chips are gone.
- `UsageRing` takes a `paceMark` (a notch), `MeterTrack` a `solid` fill by level, `FollowButton` a compact label.
- Follow-ups, done in the audit: tiles keep their order between looks (`UsageTiles.ordered`: they re-rank when the tab appears, the app comes forward, or a pull to refresh ends), one tile a row at the accessibility text sizes, and Close to a limit stacks the limit's name under the provider's there. Checked in the simulator at Accessibility Large. Still for a device: a VoiceOver pass.

## M14 — Alerts on iPhone and Mac

Today `AlertRules` (in `Shared/Core/Alerts.swift`) raises 80% and 95% alerts for every window, 5-hour sessions included, and the Live Activity follows a session. The design adds three things.

1. **Say "5-hour limit".** Add one display name for windows, shared by the tiles, alerts, the Live Activity, the provider detail, widgets, the Watch and the Mac popover (today the providers' own title, "Session", shows everywhere). Alert titles become "Claude: 80% of 5-hour limit used". Alert IDs don't change (they use the window ID), so no duplicates across devices.
2. **A pace alert.** A new `UsageAlert.Kind.runsOut`: "Claude: 5-hour limit runs out at 10:18 AM" / "86% used, 35 min before it resets at 10:53 AM." It's raised once per window instance, when the run-out first comes before the reset. For weekly and monthly limits it has to be at least a day early. It's urgent (it breaks quiet hours) only when the run-out is within the hour. It's skipped when the 95% alert for that instance has already gone out. Macs use their measured run-out (`RelayPace`); the iPhone uses `Pace.evaluate` with its own recent readings (`HistoryStore.samples`, the same readings the Mac's pace uses; hourly week points can't give a 5-hour pace), passed to `AlertLedger.process(samples:)`. ID: `evt-<provider>-<window>-runsOut-<instance>`.
3. **Separate switches.** `AlertPreferences` gains session thresholds, "before it runs out" for sessions, and the same for weekly and monthly limits. Decoding is lenient, and the new fields default from today's `thresholds`, so existing choices carry over. They're shared through the `prefs-alerts` record as today. Older builds keep fields they don't know, so there's no schema deployment.

Work:

- `Shared/Core/Alerts.swift`: the new kind, rule, preferences and subscription keys (`alertKey` for the new kind). Tests in `TokenroomTests/AlertLimitTests.swift` (new) and `AlertTests.swift` (updated), covering the rule, recent readings, dedupe across devices, quiet hours, held alerts, and decoding old and new preferences.
- iPhone `TokenroomMobile/AlertsSettingsView.swift`: the sections from the design ("5-hour limits", "Weekly and monthly limits", "Also notify me when", Quiet Hours). Mac: the Alerts tab in `Tokenroom/Views/SettingsView.swift`, same switches.
- Mac `Tokenroom/Refresh/MacAlerts.swift` and `RelayPublisher` post and save the new kind like the others.
- Live Activity (`Shared/Widgets/SessionActivityViews.swift`, `SessionActivity.swift`): "5-hour" as the window title, a `MeterTrack` with the pace tick instead of `ProgressView`, and an alert when the pace alert fires, if on (once per activity, `ContentState.warnedRunsOut`; not in the same update as a level; quiet hours hold it unless it's urgent).
- Checked: readers of `Event` records use only their names and dates, and a push shows the record's own title and body, so an older iPhone is unaffected by the new kind (its subscription doesn't list `runsOut`, so it simply doesn't get those pushes). Older Macs apply `thresholds` to sessions until they update.

## M15 — Text-safe accent and critical colours

The brand orange (`#c47a2c`) is 3.4:1 on white as small text, and `critical` is 3.2:1 on dark cells. Add `TokenroomTokens.accentText` (`#9a5518` light, `#d98f4a` dark) and `criticalText` (`#c23b22` light, `#ff6b4f` dark) as dynamic colours. Use them for small orange and red text only: pace captions, "Runs out …", New labels, the banked badge, the Close to a limit header. The brand orange stays for controls, large numbers and the icon. `PaceStyle` and `TokenroomTokens.ink` are where most of it lands.

## M16 — Provider icons (done)

Decided: each provider's own icon replaces its monogram on iPhone, Watch, widgets, the Live Activity and the Mac popover. The monogram remains as the fallback, and the menu bar keeps its template glyphs.

Files: the Mac's 5 app icons (moved from `Tokenroom/Assets.xcassets`) and 11 official marks from the providers' brand pages, in `Shared/UI/ProviderIcons.xcassets`. Sources and terms: `docs/provider-icons.md` and the design system's "Provider icons" asset group.

**Decisions (made September 26, 2026: icons from the providers' press and brand pages, on every platform):**

- **GitHub Copilot:** GitHub's logo terms require written permission for use. The icon was added on September 26, 2026 at the owner's direction (`ProviderCopilot`, from the GitHub Logos kit).
- **OpenAI:** its logo kit asks you to accept usage terms. The repo's OpenAI icon covers OpenAI and OpenAI API for now.
- **xAI:** the kit at x.ai/legal/brand-guidelines refuses scripted downloads; xAI API keeps its monogram until it's downloaded in a browser.
- **DeepSeek:** its terms allow the mark where you integrate DeepSeek, which Tokenroom does.
- **App Store:** third-party logos can draw questions in review (guideline 5.2). Decided: iPhone and Watch ship with icons in 2.1, with "Tokenroom isn't affiliated…" in the listing. The repo's old rule ("never provider logos on iPhone and Watch") is replaced in `.grok/skills/tokenroom-apple/SKILL.md`.

**Work (done):**

- One asset catalog under `Shared/UI` (a synchronized folder, so every target that compiles `Shared/UI` gets it). `scripts/build.sh` copies the same files into the Command Line Tools fallback's loose resources, since `TokenroomImage` loads them there.
- A `ProviderMark` view in `Shared/UI`. It shows the icon when the catalog has one: marks that come without their own tile sit centred on a white tile with 18% clear space. Otherwise it falls back to `MonogramMark`. It replaces `MonogramMark` in the Usage tiles, Close to a limit, the provider detail, News rows, widgets, the Watch (inside each metered row's ring, since the audit) and the Live Activity (looked up by `providerID`).
- Accessory widget families and complications render desaturated or accented: `ProviderMark` falls back to the monogram whenever `widgetRenderingMode` isn't full colour, and accessory complications keep their monograms.

## M17 — News on iPhone (done)

The Today edition from the design:

- **Dateline and filter chips:** Today · Models · Announcements · Retiring. `@AppStorage("newsSection")` gains a `today` case, and a stored unknown value falls back to Today.
- **"Since you last looked":** three counts from `NewsStore` (unseen models, unseen updates, retiring within 30 days), each opening its filter.
- **Top story:** the newest model from a lab you follow, one per visit. The art band is the lab's tint, the context window set large, and meter capsules.
- **More new models:** a row of model cards.
- **From your tools:** one card per followed tool, newest first. Up to three headlines each, with folded releases noted ("Also in Claude Code releases", `FeedItem.alsoIn`, set by `NewsCache.announcements`; done in the audit, in the River too).
- **Retiring soon**, and the attribution footer.
- **River** as the Announcements filter's layout (chronological, by day). A setting to use it for Today too can come later if people ask.

Work:

- `NewsStore` or a pure helper in `Shared/Core`: digest counts, the top-story choice, and grouping announcements by tool (`FeedSource` already maps sources to providers and folds a product's feeds).
- Views in `Shared/UI/NewsEditionViews.swift` (`NewsDigestView`, `TopStoryView`, `ModelCardView`, `ToolNewsCard`, `RetiringModelRow`, `RiverRow`, `NewsRiver`), so the Mac reuses them. Headlines use `.design(.serif)`. One change from the design: the date is the navigation subtitle, not a dateline above the title.
- `TokenroomMobile/NewsView.swift` rebuilt around a `ScrollView`.
- Tests in `TokenroomTests/NewsEditionTests.swift` for the counts, the top-story choice and the grouping, and in `FeedTests.swift` for the "Also in" note.

## M18 — News on the Mac (done)

`Tokenroom/Views/NewsWindowView.swift` becomes a `NavigationSplitView`:

- **Sidebar:** Today, Models, Announcements and Retiring with unread counts, then Labs and Your tools you follow.
- **Today page:** the same pieces as the iPhone in a `Grid`.
- **Toolbar:** Search (titles), Check now, Follow….

The window's minimum size goes from 460 × 520 to 820 × 560. The popover's pills open the window at their section, as today: through `NewsPageRequest` since the audit, so a pill for the section last asked for still leaves a lab, a tool, or a search. News stays off until turned on.

## M19 — Release 2.1

Prepared on `tokenroom/release-m19`: versions (Mac 2.1.0 build 3; iPhone and Watch build 3), the CHANGELOG heading, and the App Store copy and screenshot list. What's left needs your accounts and devices:

1. **Review and merge** #14 → #15 → #16 → #17 → #18 → #19 in order (each is stacked on the one before; GitHub retargets the next to `main` as each merges).
2. **Check on devices:**
   - Usage tiles at large Dynamic Type and with VoiceOver.
   - A run-out alert and a 5-hour 80% alert arriving from a Mac, and quiet hours holding the non-urgent ones.
   - The Live Activity's pace tick.
   - The Mac News window's sidebar selection in a real window.
   - Provider icons in tinted and clear Home Screen modes; widgets fall back to monograms there.
3. **CloudKit:** no schema change is expected (new alert kinds and choices are values inside existing fields). Confirm in CloudKit Console that Production matches Development before a Production build.
4. **Mac:** done on September 26, 2026. `./scripts/release.sh` built the notarized Developer ID zip, the CHANGELOG is dated, and v2.1.0 is published on GitHub.
5. **iPhone and Watch:** archive the TokenroomMobile scheme in Xcode (build 3) and upload it to TestFlight. Regenerate the App Store screenshots with the steps in `docs/app-store.md`; the list there is updated.
6. **README images:** done in the audit. `hero.png`, `iphone.png`, `popover.png` and `popover-details.png` retaken from sample data (the Mac with `-TokenroomSnapshots`, the iPhone 18 Pro and Apple Watch Ultra 4 simulators with `-sampleMode YES`), framed like the old ones. `menubar.png` is unchanged in 2.1.
7. **Design system:** done. The Tokenroom Design System artifact (version 6) marks every built piece as built, keeps E1, E2 and E4 as unchosen proposals, shows Copilot's monogram as the app does, and has the retaken screens.
8. **Waiting on owners:** xAI's logo kit (browser download); add it as in `docs/provider-icons.md`. The Copilot icon is in, added at the owner's direction.

## Completion audit (September 26, 2026)

Every milestone was checked against this plan. Gaps found and closed, committed on `tokenroom/release-m19`:

| Milestone | Gap | Done |
| --- | --- | --- |
| M13 | Tiles re-ranked on every refresh | `UsageTiles.ordered`; `UsageView` ranks on appear, on coming forward, after pull to refresh, and when the set of readings changes. Test: `UsageTileTests.testTilesKeepTheirPlacesUntilRankedAgain`. |
| M13 | Two columns at large text sizes | One column at accessibility sizes; Close to a limit stacks names. Checked in the simulator at Accessibility Large. |
| M14 | The iPhone's run-out used only the rate so far | `AlertRules.alerts(samples:)`, `runsOut(samples:)`, `AlertLedger.process(samples:)`, `UsageRanking.pace(for:isStale:samples:)`; `MobileStore.recentSamples(for:)`. Test: `AlertLimitTests.testRecentReadingsDecideTheRunOutWhenTheReadingHasNoMeasuredPace`. |
| M14 | No Live Activity alert for the pace alert | `LiveActivities.update(samples:)` alerts once per activity (`ContentState.warnedRunsOut`, optional so older activities decode). |
| M16 | The Watch list still drew monograms in its rings | `WatchRow` puts `ProviderMark` inside the ring. |
| M17 | No "Also in …" line | `FeedItem.alsoIn` (never stored), `NewsCache.announcements` records the folded feed, `NewsCache.name(of:besides:)`; shown in `ToolNewsCard` and `RiverRow`. Tests in `FeedTests`. |
| M18 | A pill for the section last asked for didn't leave a lab, tool, or search | `NewsPageRequest` (counts requests) replaces writing `macNewsSection` from `AppDelegate`. |
| All | Two deprecated `Text +` concatenations | Text interpolation in `RetiringModelRow` and `CloseToLimitCard`. |
| Docs | Stale plan, CHANGELOG, App Store News copy, skills, README images, design system | Updated. |

Checked: `./scripts/typecheck-shared.sh` (macOS, iOS, watchOS), `xcodebuild build-for-testing` for the Tokenroom and TokenroomMobile schemes (every app, widget, Watch and test target compiles, no warnings), Mac snapshots, and the iPhone and Watch in the simulator with sample data. Then the tests: 410 Mac tests and the 9 iPhone tests (iPhone 18 Pro simulator) pass, the audit's new ones included.

Not possible without you, and why:

- **Merging #14–#19:** your call.
- **A VoiceOver pass, and alerts arriving from a Mac through iCloud:** need a signed build with iCloud, App Group and Keychain entitlements on your devices and account.
- **The Mac News window's sidebar selection in a real window:** offscreen snapshots draw the selected row as a black bar, and launching a second Tokenroom here would read your real logins.
- **Provider icons in tinted and clear Home Screen modes:** need widgets placed on a Home Screen by hand.
- **CloudKit Console, notarization (`./scripts/release.sh`), TestFlight, App Store screenshots upload:** need your Apple Developer account and credentials.
- **xAI API's mark:** needs xAI's kit downloaded in a browser after accepting its terms, which is yours to accept. (The Copilot icon was added at your direction.)
