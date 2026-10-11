# Tokenroom News redesign

Date: 11 October 2026. Status: specification and direct implementation plan approved; implemented, with final review and acceptance recorded separately. Final review clarified identity, timestamp and persistence behavior below without expanding the approved feature scope.

## Purpose and scope

Help a person using AI tools answer three questions quickly: what changed in the tools I follow, whose analysis is useful, and which agent skills are worth exploring? Build a readable native iPhone experience with clear provenance and useful return visits. The Mac uses the same source and reading models with native sidebar navigation.

The approved direction is account-free: curated profiles and public feeds, Today / Following / Skills / Saved, compact stories with details and save/share/open-original actions, official release/status sources, and correctly attributed skill rankings. No Tokenroom account, paid X integration, social posting, or installation of discovered skills is in scope. News does not change measured quotas or individual reset dates. Provider credentials and usage relay contracts remain unchanged.

Use the existing dirty checkout `tokenroom-improvements-20261004`, branch `tokenroom/urgent-window-projected-pace`. Preserve all prior work. No commit, push, release, installed-app replacement, provider authentication, or login Keychain operations. Existing shipped version numbers must not be reused. Build products stay outside the source tree.

## Evidence and highest-impact fixes

Current-source iPhone screens were captured from the previously built debug app in a new iOS 27 simulator using an inert News fetcher, synthetic news, and the unit-test startup guard. These are UI evidence, not live-provider or release evidence. Captures live in the chat workspace's `news-design-20261011` folder.

1. Today: the context-window illustration dominates the first viewport. Following is represented by a filter icon. Keep a recognizable serif headline style and amber accent, while making the actual story lead.
2. Follow: a long toggle form offers no source discovery, voice identity, or source health. Turn it into a useful Following destination.
3. Announcements: chronological rows are readable at ordinary text sizes, but no detail/save flow exists.
4. Accessibility text size: the fixed time gutter breaks `23:12` into three lines and headline text truncates. Use an adaptive vertical row and a complete detail title.

Source review also found extension hazards: feed IDs are unscoped across publishers; grouping uses display names; repeated titles are globally removed within each feed; search runs after an 80-story global limit; future catalog feeds automatically become followed. Fix these deliberately before adding people or incidents.

The largest gains come from reading hierarchy, visible Following, saved stories, trustworthy source identity, and a small real skills catalog. Additional decorative artwork or a large social backend is unnecessary for this version.

## Native navigation and visual design

Keep the app-wide Usage, News, Settings tabs. Inside News, offer Today, Following, Skills, Saved with short text labels. At ordinary sizes all four can fit in an adaptive selector. At accessibility sizes use a native menu showing the current destination, rather than giant horizontally clipped chips.

Use native NavigationStack titles, searchable content, refresh controls, system backgrounds, semantic foreground colors, SF Symbols and existing approved provider assets. Story headlines use the system serif; labels, summaries and controls use system text styles. Controls have at least 44-point touch targets. Content cards have restrained spacing and corner radii; no fake photographs, faces, or ranking badges. Reduce Motion disables nonessential animation. The meaning of official, commentary, saved, and failed states is expressed in text as well as color.

At large text sizes, section actions move below headings, metadata becomes a vertical flow, and no fixed-width time gutter remains. Detail titles and source names wrap without a line limit. VoiceOver exposes a story heading plus explicit save/share/open actions; decorative marks are hidden. Preserve logical focus after following, saving, filtering and returning from a detail.

## Today

Today is a short briefing from followed sources, with a latest-updates continuation list. It contains recent official releases/announcements, recent model additions, followed voices' public articles, and upcoming retirements. Every limited shelf has See All. Models older than the established 14-day recent window belong in the model archive and are not labelled new.

Lead with the newest recent official announcement from followed sources; if none exists, lead with a recent model addition. Label the shelf Latest rather than implying an editorial importance judgment. Rank official status separately and do not let repeated incident updates crowd out the release list. Source details expose the reason an item appears: the followed publisher, not an opaque recommendation score.

Keep Models, Releases, Voices, Status and Retirements as collection filters or See All destinations, rather than adding them all to the top selector. Search includes retained followed-source items before applying rendering limits and includes saved records. Models may retain the current explicit All Labs option. Search is scoped and does not imply an Internet-wide archive.

Preserve current visit continuity: opening News clears its new-item badge while keeping this visit's New markers. Saved state and read state are independent. Opening a story records it as read; a bulk mark-read action is explicit. First fetch still does not notify the existing catalog as new. Skill ranking movement never contributes to model-release notifications or the News badge.

## Story details and Saved

Tapping a story opens a native detail with the full title, publisher, authority class, original publication time when present, update time when available, and source URL. Publication time is optional; an Atom updated value does not become a publication time. Show a plain-text feed excerpt only when actually supplied. No invented summary, reading time, or full-article scraping. Open Original opens the publisher in the browser. Save and Share remain available whether or not an excerpt exists.

Save retains a local metadata snapshot: stable ID, kind, title, publisher, original URL, optional excerpt, source dates, and saved time. A saved record survives feed rotation and unfollowing. Saved defaults to newest saved first and supports story/skill filtering and search. Removing a saved item is an explicit action with undo; saving an existing item is idempotent. Limit the library to 500 saved records, with excerpts bounded to 2,000 characters. At capacity, explain the limit rather than silently deleting older saves. Use atomic persistence and keep the last valid saved collection when a write fails.

Repeated saves preserve savedAt. Saved skills include owner, slug, version, requirements and the displayed ranking snapshot where supplied, with its checked time; these remain historical metadata when the live shelf rotates. Corrupt or unsupported library data produces an explicit problem and preserves the file rather than loading an empty library and overwriting it.

Local saved metadata can be revisited offline. Original articles and skill pages require the network; do not imply downloaded full content. News choices, read state and saves stay on this device in this version. No new CloudKit relay records are introduced. This limitation is visible in source/help settings.

## Following and voices

Following has Tools & Labs, Voices, and Status groups, with clear search and source details. Existing tool/lab follows are preserved. Suggested tools can be based on currently available readings; applying a preset is explicit and does not overwrite choices silently.

New voice and status sources start unfollowed. Do not put them into the existing migration rule that enables newly added official tool feeds. Following in Tokenroom is a local content preference; it does not follow an account on X.

Initial curated voices, with identity links checked from their own public sites/profiles:

| Voice | Public articles | X profile |
| --- | --- | --- |
| Simon Willison | `https://simonwillison.net/tags/llms.atom` | `https://x.com/simonw` |
| Ethan Mollick | `https://www.oneusefulthing.org/feed` | `https://x.com/emollick` |
| Andrej Karpathy | `https://karpathy.bearblog.dev/feed/` | `https://x.com/karpathy` |
| Boris Cherny | `https://borischerny.com/feed.xml` | `https://x.com/bcherny` |
| Alexander Embiricos | Profile only | `https://x.com/embirico` |

These are curated suggestions, not a follower-count ranking. Public blog entries are labelled Articles, not X posts. A profile-only source says Profile only and exposes Open on X; it cannot produce a pretend timeline or unread count. Profile records have stable publisher IDs, identity evidence and external URLs independent of an optional feed; profile-only records never enter refresh queues or show failed/not-yet-checked feed health. X may require sign-in in the external browser. Author identity evidence and verification dates live in the catalog. Official organization profiles can accompany existing official feeds with the same navigation action.

A newly followed voice's first successful feed check establishes its baseline without marking its existing archive New. Later observed entries can become New; it never schedules a model-release notification.

The first version uses the reviewed catalog. Arbitrary RSS URLs and custom X accounts are deferred: unrestricted source entry needs its own validation, persistence and URL-fetch policy. Users can follow/unfollow catalog voices and inspect each source's availability, latest successful check and latest problem.

## Releases, status and resets

Continue official RSS/Atom changelogs and release feeds. Add opt-in official OpenAI status (`https://status.openai.com/feed.atom`) and Claude status (`https://status.claude.com/history.atom`) as provider reports. Use an incident identity and retain the latest publisher update plus up to five distinct observed update snapshots per incident. Do not claim to possess updates never fetched. A failed or empty fetch does not establish that an incident is resolved.

Show a dated provider-status update; show an active/resolved status only when explicitly supplied by authoritative structured content. Plain titles alone are not a reliable machine-readable incident state. Reported aggregate status may differ from an individual user's experience.

Reset-policy announcements can appear when publishers actually report them. Personal reset countdowns continue to come from Usage readings, not commentary or news titles. No article causes a quota reset, synthesizes a new limit, or schedules a usage alert. Existing new-model notification behavior and quiet hours remain; voices, status and skill rankings do not gain automatic notifications in this version.

## Skills

Use a separate SkillListing model and a small public ClawHub adapter. This is a discovery shelf for the ClawHub ecosystem, not an exhaustive ranking of all Codex/Claude skills. Also expose Open skills.sh as an external exploration link; do not depend on its authenticated documented API or on an undocumented anonymous search endpoint for the main feature.

Offer Trending · 7 days, Most downloaded, and Newest. Fetch up to 30 records for the selected shelf from `https://clawhub.ai/api/v1/skills`, with `sort=trending`, `sort=downloads`, or `sort=createdAt`, `limit=30`, and `nonSuspiciousOnly=true`. Refresh on entering Skills when its session result is over 15 minutes old and on explicit pull to refresh; do not poll in the background. The official skills endpoint defines Trending as seven-day install telemetry; cumulative downloads are a separate metric. Preserve the returned ranking order and display its source and checked time. Do not invent a seven-day install count from lifetime statistics. Search initially filters the loaded shelf and says Search these skills; it does not promise registry-wide search.

Rows show name, owner, publisher-supplied summary, ranking source, correctly labelled metric, and save action. Details show version, update time, declared requirements/compatibility when returned, the metric definition, Save, Share and Open on ClawHub. Missing agent compatibility says Not specified; neither name nor popularity establishes compatibility. Use owner + slug as identity. Validate both returned ownerHandle and slug and construct only the documented `https://clawhub.ai/<owner>/skills/<slug>` route; reject an ownerless record. A valid short first page is the bounded shelf even when nextCursor is non-null; do not automatically crawl more pages to reach 30.

Fetch only public listing metadata. No download, install command, shell execution, SKILL.md activation, or auto-update exists. Request `nonSuspiciousOnly=true` where supported; do not turn that moderation filter into a Safe badge. All publisher strings remain inert text.

The catalog store is separate from NewsCache. Use an ephemeral URLSession, bounded 2 MB responses, an eight-second request budget, coalescing per shelf, and server-directed Retry-After. Respect the endpoint's current no-store response policy: do not persist HTTP/catalog responses or invent ETag support. User-selected saved title/summary/URL metadata is persisted separately. Unavailable rankings show retry timing and any still-visible session result with its checked time, rather than fictional curated results labelled live.

## Shared data and migration

Extend feed metadata with stable source ID, content kind and authority (`officialAnnouncement`, `officialStatus`, `commentary`). Use source-scoped item identity even when publishers reuse the same GUID or display name. Keep original publisher time, updated time and first-seen time separate. First-seen controls New bookkeeping; it must not erase source dates. Provide compatibility decoding for old news.json records and saved choices. Recover legacy source identity from its cache bucket, preserve legacy stored bookkeeping dates without pretending to recover a previously clamped publisher date, and populate the new publisher timestamp fields on fresh fetches. Fresh checks retain the earlier first-seen bookkeeping date. Existing visit baselines remain authoritative during migration.

Deduplication is source-aware: current paired changelog/release folding remains for the same tool; commentary attribution is retained even when it links to the same original page. A folded release has a deterministic product/release identity and retains underlying source-item aliases, so winner changes preserve saved/read state. Version-bearing paired releases use the normalized product/version key. Other folded entries retain alias identity matching. Repeated-title suppression is an explicit legacy changelog policy, not a rule for all sources. Status items deduplicate by publisher and incident identity; a new incident sharing a title remains distinct.

Keep the existing NewsStore refresh queue, immediate uncached follows, visit baseline and per-source retry behavior. Preserve conditional GETs and byte limits for feeds. Separate source health from item age: checked time and publication time answer different questions. A valid empty feed is distinct from failed, malformed, truncated and not-yet-checked. Failure retains usable previous items and offers targeted retry.

Core ownership remains small: NewsStore orchestrates feeds and follows; a reading library owns saved/read metadata; a skills store owns transient ranked listings; shared presentation builds sections; native iPhone and Mac views render them. Avoid mixing skill popularity into ModelRelease or usage ranking.

## Acceptance before completion

- Migration keeps old cache/follow choices, first-fetch silence, queued refresh intent and visit continuity. New voices/status stay off until chosen.
- Two publishers using the same item GUID both render and save independently; same-named voices remain separate. Repeated-title incidents survive, updates retain dates, and legacy tool duplicate folding still works.
- Search can find a quiet followed source beyond the global display cap. No old model is labelled new merely because it appears in the archive.
- Follow/unfollow, source details, article details, save/unsave/undo, saved persistence, share and original/profile navigation all work. Feed turnover does not remove saved records.
- Skills decoding covers duplicate slugs across owners, missing metrics/version/requirements, numeric overflow or invalid timestamps, partial responses, rate limits, cancellation, and schema failures. Ranking does not raise a news notification.
- Feed errors and catalog errors are isolated. Cold, empty, offline, stale, malformed and retry states are understandable; cache failures are not treated as successful saves.
- iPhone ordinary and largest accessibility text sizes, light/dark, VoiceOver labels/actions, Reduce Motion and narrow layouts are inspected. Mac sidebar/detail remains usable with the new collections.
- Run the shared typecheck, targeted News/library/skills tests, complete safe Mac tests and unsigned generic iPhone Simulator build including Watch/widgets. The original recipe used eight Keychain exclusions; the current explicit fake-operations fixtures allow all 766 Mac cases with no exclusions. Use fixture launches for UI acceptance; never start real provider checks under XCTest.

Implementation and validation are recorded in [News validation](news-redesign-validation-20261011.md). The concept board remains illustrative; simulator and Mac captures are separate fixture evidence.

[QA6 remediation and validation](news-sixth-qa-validation-20261011.md) is a **dated historical snapshot**: it fixed the three QA5 P2s plus currency-history/unchanged-snapshot regressions and passed 758 Mac cases with eight exclusions, 14 selected hosted iOS cases and shared checks. Native Mac Back/Command-[, commands, query continuity and repeated requests passed in its inert fixture. Those receipts are preserved, not relabelled current.

[Final-source release checks](news-release-checks-20261011.md) now pass **766 complete Mac tests with no exclusions, 34 complete hosted iOS tests, affected Skills 16/shared checks, unsigned Release builds and optimized fallback compilation**. Explicit credential/platform fixtures close the old coverage gaps. Confirmed Save-capacity/global-caption and cold malformed Skills P3s are fixed; scoped actual native error/retry/Undo/reopen witnesses pass. Independent full review plus final Skills delta review/source binding is recorded. Distribution export capability is proved; final r2 archives/exports, signatures/entitlements, all 257 production inputs and sealed-artifact verification and Mac Accepted notarization/staple/Gatekeeper pass. Felipe's requested largest-text/VoiceOver/Reduce Motion journeys are human-attested without reported problems on the initial pre-Save-P3 inert Development iPhone 13 candidate. Do not generalize this to current Production acceptance.

Current anonymous public Skills qualification passes all three shelves: HTTP200, 30 raw/30 rows decoded by the exact current parser with ranks1–30 and owner-qualified URLs; one generated detail route returns HTTP200. Missing metadata stays unspecified. Trending's successful endpoint declares deprecation and a successor, recorded as a future maintenance risk. This smoke is distinct from actual app/iOS transport/decode timing and does not execute skills; exact receipts and limits are in the release checklist.

**SOURCE / APPROVED LOCAL ACCEPTANCE / SIGNING / UPLOAD-PROCESSING PASS. Integration is CONDITIONAL_GO after final independent diff/docs approval; Mac publication also requires green CI for the exact pushed revision.** Implementation, automated qualification and finite approved native News scope are complete. Current Simulator ordinary/largest/light/dark/narrow journeys, AX labels/actions, Share/Open Original, scene-state save/follow continuity and Reduce Motion0→1→0 pass. Current guarded Mac representative state/retry branches pass; shared Library tests and native disk reopen establish persistence separately from the Simulator's memory-only library. Exact receipts and scope are in the release checklist and `acceptance-final-scope-verdict.json`. Further phone work stopped at Felipe's request. Physical Production TestFlight/push/widgets/Live Activity/signed App Group and real same-account relay/alerts remain unverified; all three accounts differ. Physical Watch runtime is unavailable; original watchOS typecheck/embedded builds pass without a hardware requirement. Private upload/processing1.1.0(1) passes; public mobile availability requires separate App Review/approval. Version/source-equivalence is recorded; final independent diff/docs review and exact-revision CI precede publication. No commit/main push, production Mac replacement, public release or cleanup occurred. [The updated QA prompt](news-redesign-qa-prompt-20261011.md) requests independent source/evidence review and precise remaining limits.

`Config/Version.xcconfig` is prepared as Mac **2.4.0(1)** and mobile **1.1.0(1)**, exactly matching the qualified archive overrides and all five exported bundles. `version-config-equivalence.json` records **256/257 byte-identical production inputs**, with only version configuration/comments changed; no Swift behavior or package bytes changed. The original 257-input manifest is preserved. Mobile build1 is uploaded/processed/consumed and must not be reused for a new archive.

## Primary references

- [Apple native layout and touch guidance](https://developer.apple.com/design/tips/), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- [Apple News following](https://support.apple.com/en-euro/guide/iphone/iph0a16d1e29/ios), [saving stories](https://support.apple.com/en-ie/guide/iphone/iphd1b6c7270/ios), [NetNewsWire Today/Unread/Starred](https://netnewswire.com/help/ios/6.0/en/smart-feeds.html).
- [X application authentication](https://docs.x.com/fundamentals/authentication/oauth-2-0/application-only), [pricing](https://docs.x.com/x-api/getting-started/pricing), [developer policy](https://docs.x.com/developer-terms/policy).
- [ClawHub API reuse](https://docs.openclaw.ai/clawhub/api), [ranking and identity contract](https://docs.openclaw.ai/clawhub/http-api), [telemetry](https://docs.openclaw.ai/clawhub/telemetry), [skills.sh API authentication](https://www.skills.sh/docs/api).
- [Simon Willison identity](https://simonwillison.net/about/), [Ethan Mollick identity](https://www.oneusefulthing.org/about), [Karpathy identity](https://karpathy.ai/), [Boris Cherny identity](https://borischerny.com/about/), [Alexander Embiricos identity](https://github.com/embirico).

QA4 source corrections preserve latest queued preferences, logical alias-group Unsave/exact Undo, complete paired-family native search and app-owned mobile test/snapshot isolation. Inputs remain read-only; ordinary production sample mode keeps its behavior. QA4-R01 decode-inclusive Skills timing remains UNCONFIRMED. QA5's actual elapsed localhost macOS streaming demonstrates shared expiry/late-body/physical-slot behavior, without proving large-input decode performance or iOS transport timing.

QA6 repairs Mac reader Back/window commands/repeated request return and binds amount/history units without changing News account/privacy scope. Private alert ownership contains usage identity only; it does not sync News. The full completion audit still accounts for physical/signed/error/recovery acceptance without waiving it.
