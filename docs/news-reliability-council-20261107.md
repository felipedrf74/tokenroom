# News, Skills and Following: reliability decision (2026-11-07)

Four independent reviewers proposed designs from different angles: reliability, editorial, Apple platform, and a skeptical maintainer. Each then reviewed the other three blind and ranked them, without voting for their own. Borda count, 2 points for first and 1 for second: Apple platform 6, reliability 3, skeptical maintainer 3, editorial 0. Where the ballots tied, the decision follows the evidence, as noted.

## Verified facts (checked live on 2026-11-07)

- **The ChatGPT & Codex changelog fails every check.** The feed is 4,761,262 bytes decoded, over its 4 MiB limit (`Feeds.swift`), so every pass takes the truncated path. That path:
  - marks the feed failed and unreadable;
  - clears its ETag;
  - keeps "Couldn't read ChatGPT & Codex" on screen.

  One production cache had 340 consecutive failures, with the last success about 14 days earlier.
- **Nothing can cancel a News pass.** It runs in an unstructured `Task` (`NewsStore.refresh`) that no owner holds. As a result:
  - The cancellation guards in `NewsFeed` never fire.
  - iPhone background-task expiry and Mac sleep don't stop the pass. Requests they interrupt are recorded as source failures.
  - A wake refresh that arrives during that pass is dropped by the coalescing rule.
- **Being offline counts as a failure for every source.** `NewsFetcher.download` turns every error into `.unreachable`. `TokenroomHTTP.meansOffline` exists, but only the usage path uses it.
- **Pull to refresh returns before the pass it queued has run.**
- **Every feed has the same cadence:** hourly in the background and when the app comes forward, every 5 minutes on screen. Status feeds are too slow; voices are polled far more than they need.
- **The OpenRouter model list is about 81 KB on the wire**, gzipped from 827 KB, with `max-age=120`. It is cheaper than the code comment assumes.
- **Skills lives only in memory**, with an 8-second deadline. ClawHub's `sort=trending` is deprecated, and its successor is `/api/v1/trending?kind=skills`.
- **The catalog is almost entirely vendor changelogs.** Nothing covers industry, research, or what is being discussed.
- **Voices is thin.** It is off by default, and one of its five voices has no feed.

## Decisions

| Topic | Decision | Vote |
|---|---|---|
| Server or aggregator | No. Everything stays on the device. | 4/4 |
| Catalog format | Compiled Swift with contract tests. No remote override for now. | 4/4 |
| Cadence tiers | Adopt `FeedSource.interval` (numbers below). | 4/4 |
| Default follows | New installs: Simon Willison, Interconnects, Import AI, Latent Space. Upgraders: nothing turns on silently; a dismissible "New sources" suggestion instead. | 4/4 |
| Story clustering and scored Today | Later. Fold by `linkKey` only. | 4/4 |
| Skills | Keep the last good list; GitHub skills-repo shelf next; ClawHub labelled community and unreviewed. | 4/4 |
| Mac scheduler | A News loop owned by `QuotaStore`, outside `shareReadings`, with intervals from a pure `NewsCadence`. The vote tied 2–2. This option won because the platform reviewer who first proposed `NSBackgroundActivityScheduler` switched to it, and it is simpler to test. | 2/2 |
| Release notifications through CloudKit | Not now. It would add a write path to the P0 relay. | 4/4 |
| Feed-health probe | A separate weekly workflow that is advisory only. `ci.yml` is not touched. | 4/4 |

### Cadence

| Kind | Off screen or in background | On screen |
|---|---|---|
| Official announcements and releases | 15 min | 5 min |
| Status (followed only) | 10 min | 5 min |
| Voices and discussion | 3 h | 30 min |
| Model list | 30 min | 15 min |

When the iPhone comes forward on any tab, it checks feeds older than 15 minutes; before this change the threshold was 60. iOS decides when background refresh runs, so the design aims to make each granted run succeed, not to shorten the interval.

## What ships in this change

1. A truncated feed that parsed at least one complete item counts as a success and keeps its validator. The truncation is recorded for source health. The ChatGPT & Codex limit goes up to 8 MiB.
2. Cancellation scoped to the owner, and opt-in. iPhone background expiry and Mac sleep cancel the pass, and the cancelled pass records no failures. A view going away still doesn't cancel it.
3. A wake refresh that arrives during a pass waits for that pass instead of being dropped.
4. A new `.offline` outcome for News and Skills: no failure count, no backoff, no "Couldn't read".
5. Pull to refresh and Retry wait for the follow-up pass.
6. The banner names a feed only after a permanent error (404, 410, or a body that isn't a feed), or after 3 or more failures spanning more than an hour.
7. Cadence tiers as above, with the freshness caption measured against each kind's interval.
8. iPhone background: usage and News run at the same time, and News has a 20-second deadline. When the app comes forward, News no longer waits behind usage.
9. Mac: a News loop separate from usage and iCloud sharing, cancelled on sleep.
10. Skills: the last good list is saved for each sort, with a "Checked …" caption. Other changes:
    - the budget is 20 seconds;
    - a 5xx triggers backoff;
    - an oversized response gets its own error;
    - Trending uses the successor endpoint;
    - a note says community uploads aren't reviewed.
11. Sources:
    - New voices: Import AI, Interconnects, Latent Space, Armin Ronacher, Mitchell Hashimoto.
    - New discussion and industry sources: Techmeme, Hugging Face.
    - New lab news: Mistral.
    - New status feeds: GitHub, OpenRouter, and xAI (which Cursor's status page redirects to).
    - Removed: the voice with no feed.
    - `PRIVACY.md` lists the new hosts.
12. A weekly advisory feed-health workflow.

## Later

- A GitHub skills-repo shelf, built on `isCommitLog`: `anthropics/skills`, `anthropics/claude-plugins-official`, `github/awesome-copilot`, `vercel-labs/agent-skills`.
- Press feeds (TechCrunch, The Verge, MIT Technology Review), with story clustering once the probe shows real duplicates.
- Bluesky voices, which need a title taken from the description.
- A remote kill switch, limited to existing IDs and hosts.

## Implementation notes and deviations (branch `tokenroom/news-reliability-20261107`)

Everything in "What ships in this change" is implemented; nothing under "Later" is. Where the code needed a choice the decision didn't make, or where it reads differently from the decision's words, it's noted here.

1. **Truncation.** A feed counts as read when its body stopped at its size limit (`data.count >= sizeLimit`) and at least one whole entry parsed. A body cut off partway (a timeout, a dropped connection) is still a failure, as before (`testAFeedCutOffPartwayShowsWhatArrived`). The note for source health is `SourceCheck.truncatedAt`, surfaced as `NewsSourceFreshness.truncatedIDs`; it isn't drawn in the UI yet.
2. **Cancellation.** Two owner-only entry points: `NewsStore.refresh(cancellable: true)`, which ties a pass to the caller that started it (iPhone background refresh), and `NewsStore.cancelPass()`, which the Mac calls on sleep for whatever pass is under way, the window's live check included. A cancelled pass keeps what it read and drops what was queued behind it; the owner's next pass checks what's due. Views never call either, so the existing contract holds: a view going away doesn't cancel or drop a queued manual or follow pass (`testCancelledRefreshOwnerStillRunsQueuedManualAndFollowRequest`).
3. **Waiting.** Items 3 and 5 share one opt-in flag, `waitsForFollowUp`: during a pass, the request always joins the single follow-up and returns when the work (including that follow-up) ends. It's passed by pull to refresh, Retry, Check Now, the Mac's News loop (its "wake refresh") and the iPhone coming forward. The default stays "return at once", because two existing tests call `retrySources` during a paused pass and would otherwise deadlock.
4. **Offline.** `TokenroomHTTP.meansOffline` includes `cannotFindHost` and `cannotConnectToHost`, so a source whose host disappears from DNS isn't counted as failing in the app. The weekly probe (item 12) reports it.
5. **Banner.** The rule applies to the Today banner (`announcementProblem`). Source and collection health still show a single failure, with Retry, and the model-list banner is unchanged. Permanent means 404, 410, or a body that isn't an RSS channel or Atom feed (`SourceCheck.isPermanent`), so a captive-portal page also counts as permanent while it lasts.
6. **Cadence.** `NewsCadence.interval(for:maxAge:)` = `min(background, max(maxAge, onScreen))`, so the iPhone's 15-minute activation checks status feeds by their own 10 minutes, and a live 5-minute check leaves voices to 30 and the model list to 15. Freshness is measured against each kind's background interval plus a download (16 minutes for official feeds). `NewsFetcher.modelInterval` and `announcementInterval` remain as aliases of the model and official background intervals.
7. **iPhone background.** `NewsLifecycle` (Shared, so the Mac's tests cover it) runs usage and News with `async let`; News runs under `TimeLimit.run(20)` with `cancellable: true`. `MobileAppDelegate.backgroundRefresh()` calls it, because the `.backgroundTask` closure isn't main-actor isolated.
8. **Mac loop.** `QuotaStore.startNewsLoop()` starts from `start()` and again on wake (before the usage check). It waits `NewsCadence.nextCheck`, clamped to 1–15 minutes. "Waits for network on wake" is done without `NWPathMonitor`: an offline pass records nothing, and the loop tries again a minute later. `refreshNews` is no longer called from `shareReadings`.
9. **Skills.**
   - Saved as `News/skills.json` in the app's Application Support, beside the saved library: device-local, outside the App Group and iCloud.
   - 5xx backoff is 5, then 15 minutes, for automatic checks only; Retry always asks.
   - The successor endpoint reports a 24-hour window, so the label "Trending · 7 days" became "Trending" (saved skill rankings now read "Trending · Rank N").
   - The successor mixes in skills.sh entries, which have no ClawHub page or verdict. Only ClawHub's own uploads that its scan calls clean are kept, at the rank ClawHub gave them, showing lifetime installs instead of downloads.
   - The per-request timeout is now 12 s (`TokenroomHTTP.timeout`), and downloads use News's session, whose whole-download timeout isn't capped at 12 s. The 20-second budget is the absolute deadline.
10. **Sources.**
    - Techmeme and Hugging Face are `NewsVoice` entries with `role: .discussion` (kind `.commentary`, the voices' cadence, followed through `followedVoices`), listed in their own "Discussion & industry" section. There is no new `NewsSourceKind`, because a new raw value in the cache would make older builds fail to decode `news.json`.
    - Mistral (`mistral-news`) is a catalog feed with `startsOnForUpgraders: false`: a new install follows it, while an update offers it in "New sources". Feeds added to the catalog before this change keep the old rule (on for upgraders). This follows "Upgraders: nothing turns on silently" over the older catalog rule. Its URL is the candidate `https://mistral.ai/rss.xml`, which redirects to `/news/rss` and is served as `text/plain`.
    - The xAI status page calls itself "SpaceXAI System Status" and reports Grok, Grok Bot and Cursor, and Cursor's status page redirects to it. So it is named "SpaceXAI status (Grok, Cursor)".
    - New installs are detected by the absence of every earlier News key (`newsSeenAt` included, which every earlier release wrote on first launch). The defaults are applied only through `NewsRuntime.liveNewsStore`, so test stores keep empty voices.
11. **Feed health.** `scripts/feed-health.py` reads the catalog from the Swift sources, so there's no second list.
    - It flags a source that doesn't answer 200, isn't a feed (or the JSON shape Tokenroom reads), is over 80% of its size limit, or is stale: 30 days for official feeds, 60 for voices and discussion, none for status.
    - The workflow runs Mondays and on dispatch, opens or updates one `feed-health` issue, and closes it when everything is healthy.
    - The first run, on 2026-11-07, flagged "Claude Code what's new" (last entry 2026-09-15) and Z.ai (2026-08-26) as stale. They were left in place, since removing them isn't in this change.
12. **Verified live on 2026-11-07.** All eleven candidate feeds answered 200 as RSS/Atom with entries from that week. The largest is Latent Space at 1.24 MB decoded, under the 2 MB limit. None was dropped. The identity pages of the new voices link the X handles used.
