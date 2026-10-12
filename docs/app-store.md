# App Store listing: Tokenroom for iPhone and Apple Watch

A draft for App Store Connect. Provider names appear only in the description, as facts, never in the name, subtitle, or keywords. Tokenroom isn't affiliated with any provider.

## What's New — 1.0.3

Submitted and released 5 October 2026. Preserved historical text; current public version is 1.1.0, below.

This update improves usage sync and reliability across iPhone, Apple Watch, and Mac.

• More reliable iCloud updates and fresher Apple Watch readings.
• Better recovery when your iCloud account changes.
• Notification fixes to prevent repeated accepted alerts and retry alerts that could not be scheduled.
• More accurate last-checked times and clearer refresh errors.
• Safer API key replacement and sign-in handling.

## What's New — 1.0.2

Meters show the even pace as a notch, and the part past it is striped when you're using a limit faster than it lasts. Each provider's page opens with a ring, when it resets, how the pace looks, and your plan. Settings shows iCloud's status at the top. The News tab keeps itself current while it's open. On Apple Watch, a provider's page leads with a ring, and readings from your iPhone say so.

## What's New — 1.0.1

Usage readings now show when each provider was last checked and flag stale data. Secondary limits get clearer warnings, and reset windows wait for a confirmed new reading. Settings protects key validation and shared alert preferences during edits. News retries feeds independently and adds search and Show More. Apple Watch, widgets, and Live Activities present the same freshness and reset states. Tokenroom for Mac 2.2.1 keeps Claude, Grok Build, and Codex signed in, so the readings it sends keep updating without a fresh login.

## App information

| Field | Value |
|---|---|
| Name (30) | Tokenroom: AI Usage & Limits |
| Subtitle (30) | Plan limits, resets & alerts |
| Bundle ID | `app.tokenroom.ios` (Watch: `app.tokenroom.ios.watchkitapp`) |
| SKU | `tokenroom-ios` |
| Primary category | Utilities |
| Secondary category | Developer Tools |
| Price | Free |
| Age rating | 4+ (no restricted content; links open in Safari) |
| Support URL | https://github.com/felipedrf74/tokenroom/issues |
| Marketing URL | https://github.com/felipedrf74/tokenroom |
| Privacy policy URL | https://github.com/felipedrf74/tokenroom/blob/main/PRIVACY.md |
| Copyright | 2026 Felipe Dominguez |
| Availability | Every country and region except mainland China |
| Content rights | Yes: shows third-party content (provider names, model and feed titles) it has the right to use |
| EU trader status (DSA) | Non-trader |
| Tracking | None |
| Release | 1.1.1 candidate: manual release after qualification, CI and App Review approval |

## App privacy

**Data Not Collected.** Tokenroom has no server and no analytics. Readings sync through the user's own iCloud private database, which the developer can't read. API keys stay in the device's Keychain. News requests go to public pages without identifiers.

Export compliance: `ITSAppUsesNonExemptEncryption = NO` (only Apple's HTTPS and CloudKit).

Provider icons: the app shows each provider's own icon, used under its owner's published terms (sources in `docs/provider-icons.md`). If App Review asks about third-party marks (guideline 5.2), point to those terms; returning `nil` from `Provider.assetName` brings back monograms without other changes.

## Promotional text (170)

See how much of your AI plans you've used, your pace, and when each limit resets, from your Mac or your API keys. Widgets, Live Activity, alerts, and Apple Watch.

## Description

Tokenroom shows how much of your AI coding and chat plans you've used, whether you're on pace, and when each limit resets, on your iPhone, your Lock Screen, and your wrist.

YOUR PLANS AT A GLANCE
• Close to a limit: every limit at 80% or more, or on course to run out before it resets, most urgent first
• A tile for every plan: the weekly limit as a ring and the 5-hour limit as a bar, each with your pace and when it resets
• When you'd run out at the current pace, and a week of history for each window
• Banked resets, credits, balances, and this month's spend, with how long a balance lasts

FROM YOUR MAC, OR RIGHT FROM YOUR IPHONE
• Tokenroom for Mac reads the tools you already use (Claude, Codex, Cursor, GitHub Copilot, Grok, Antigravity, Devin, and more) and sends only the readings to your iPhone and Apple Watch through your own iCloud.
• Add API keys on your iPhone for coding plans (GitHub Copilot, Z.ai, Kimi Code, MiniMax, OpenCode Go), pay-as-you-go balances (OpenRouter, DeepSeek, Moonshot, Vercel AI Gateway), and organization spend (OpenAI, Anthropic, xAI). Keys stay in this iPhone's Keychain.

WIDGETS AND LIVE ACTIVITY
• Home Screen and Lock Screen widgets with ticking countdowns, and a refresh button
• Follow a session, or a nearly spent week, on the Lock Screen and in the Dynamic Island until it resets. Start it from the app, Control Center, the Action button, or Siri.

ALERTS THAT DON'T NAG
• At 80% and 95%, set apart for 5-hour and weekly limits, and before a limit runs out at your current pace
• When a busy window resets, for banked resets, and when a balance runs low
• Once per event, however many devices notice it
• Quiet hours hold what can wait until morning

NEWS
• Today: a short daily paper with what's new since you last looked, a top story, and models retiring soon
• New models from the labs you follow, with context window and prices
• Each tool's official changelog and releases, grouped by tool, or newest first by day

APPLE WATCH
• Rings for every plan, complications, and a Smart Stack widget when a limit nears its reset
• Works with your iPhone away: it reads your iCloud directly

PRIVATE BY DESIGN
• No account, no Tokenroom server, no analytics
• Logins never leave your Mac, and keys never leave your iPhone. Only usage, reset times, and plan names sync, through your iCloud.
• Try it first with sample data.

Tokenroom isn't affiliated with any of the providers it shows. Their names are used only to identify the services you connect.

## Keywords (100)

`ai,usage,quota,limit,tokens,coding,assistant,meter,reset,pace,widget,api,credits,balance,llm,spend`

## For a later listing

Not for 1.0.1, 1.0.2, or 1.0.3; leave their listings and notes as submitted.

The next version can say that the Watch, widgets, and Lock Screen lead with the limit that is closest to running out, and that a pace measured on the Mac stays visible, marked projected, after that Mac sleeps.

- "Logins never leave your Mac, and keys never leave your iPhone" stays true while the iPhone has no plan login (`PhoneConnect.productionAllowlist` is empty). Before a version that adds one is submitted, replace it with: "A login you add on your iPhone stays on that iPhone. A login on your Mac stays on your Mac. Only usage, reset times, and plan names sync, through your iCloud."
- A later description can say the iPhone works without a Mac for every provider read with a key, Copilot's fine-grained token included, and lists the plans that need Tokenroom for Mac.

## Review notes

Tokenroom works without an account. To look around quickly: Settings › Sample Data (or "Try sample data" on the welcome screen) turns on realistic sample readings for every screen, widget, and the Live Activity.

Real readings come from two places:

1. **Tokenroom for Mac** (free, open source; https://github.com/felipedrf74/tokenroom). It reads usage from the AI tools on the Mac and syncs the readings through the user's own iCloud private database.
2. **API keys** the user pastes on the iPhone (for example an OpenRouter key, or a GitHub fine-grained token with the Plan permission for Copilot). The app only reads usage and balances with them. Most are read through the provider's documented API; Z.ai, Kimi Code, OpenCode Go, and MiniMax's older Coding Plan are read from the usage endpoints their own tools call, which those providers haven't documented.

The Watch app reads the same iCloud records. Notifications are optional and come from the user's own devices through iCloud. The News tab reads public feeds only. There are no in-app purchases.

## Screenshots

6.9" iPhone (1320 × 2868), from sample data on the iPhone 18 Pro Max simulator in US English, with the status bar set to 9:41:

1. Usage: Close to a limit and the plan tiles
2. Detail with pace and a week of history (OpenAI)
3. Home Screen widgets
4. Lock Screen widgets and the Live Activity
5. News: Today
6. API keys
7. Welcome

Apple Watch, from sample data: Ultra (49mm, 422 × 514) and Series (46mm, 416 × 496), the plan list and a detail (Claude).

Regenerate them from a debug build:

```bash
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomSim
```

```bash
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
```

Use US English formats so prices and dates match the listing ("$12.40", "Sep 28"); a simulator set to another region shows "US$12,40". Once per simulator, including the Watch:

```bash
xcrun simctl spawn booted defaults write -g AppleLocale en_US
```

Then for each screen, launch with sample data and a destination, and take the screenshot:

```bash
xcrun simctl launch booted app.tokenroom.ios -sampleMode YES -onboarded YES -TokenroomOpen tokenroom://provider/openai
```

```bash
xcrun simctl io booted screenshot 2-detail.png
```

Other destinations: `-TokenroomGallery home`, `-TokenroomGallery lock`, `-TokenroomOpen tokenroom://news`, and `-TokenroomOpen tokenroom://keys`; `-sampleMode NO -onboarded NO` for the welcome screen. The Watch app takes `-sampleMode YES` and `-TokenroomOpen tokenroom://provider/claude` the same way.

## Mobile 1.1.0 — released 12 October 2026

Mobile 1.1.0(1) was submitted on 11 October and released on 12 October 2026 at 15:07:19 UTC. Official US/PT public lookups and App Store Connect Ready for Distribution confirm it. Submission `982fe0ca-d959-4411-a434-751652a1fc06` is Approved/Review Completed; build `e37ecc7d-9eef-41a7-9a94-41692a62838b` is consumed. The [earlier delivery record](news-release-delivery-20261011.md) retains its dated Waiting for Review checkpoint. Current lookup receipts are in the [1.1.1 release checks](ios-news-release-checks-20261012.md). This is the current public What's New text:

Read your AI briefing in Today, Following, Skills and Saved. Follow curated voices and public release/status feeds, save stories locally, and explore clearly sourced ClawHub rankings. Larger text, source search and recovery controls make news easier to browse. Saved balance references now keep their currency when you change an account region. Updated devices coordinate reset-window alerts to avoid duplicate notifications.

The qualified 1.1.0(1) build is attached, accurate version metadata and the native Following screenshot are saved, and Apple's submission validation passed. The approved finite News fixture/native acceptance and source/sign/package/upload checks are recorded in docs/news-release-checks-20261011.md; further physical phone work stopped at Felipe's request. Different-account real iCloud/notification coordination, Production push/widgets/Live Activity/App Group effects and physical Watch runtime remain explicitly unverified integration limits, not new hardware requirements for the approved News plan. Apple App Review approval and public availability were pending at that historical checkpoint; the fresh 12 October lookup and portal records now confirm both for 1.1.0.

At the 1.1.0 checkpoint, tracked versions matched the qualified archive overrides: Mac 2.4.0(1), iPhone/widgets/Watch 1.1.0(1). `version-config-equivalence.json` records the effective version match while preserving the original signed-source manifest.

## Mobile 1.1.1 — submitted, awaiting review

Version 1.1.1 build 1 is privately uploaded and processed; Apple build `12b15493-c81e-4a63-b826-d1178056b33d`. Apple accepted submission `16200897-ca51-4994-817d-04ce82c1f1ed` on 12 October at 20:46 Europe/Lisbon; it is Waiting for Review. The attached exact build has manual release selected and is not publicly released. [The submission record](ios-news-release-delivery-20261012.md) binds source, CI, package and portal evidence. Current versions are Mac 2.4.1(1), mobile/widgets/Watch 1.1.1(1). Both mobile build numbers are consumed.

Saved draft What's New:

News has a fresh editorial design with illustrated lead stories, source icons and compact release lists. Following, Skills and Saved are easier to browse, with clearer rankings, inline actions and layouts that adapt to larger text. Reader navigation, contrast and Undo accessibility are improved.

Review notes retain the existing account-free/sample-data/key/Mac/iCloud explanation. They now identify 1.1.1 and explain decorative lead artwork, adaptive editorial presentation, original story attribution/dates and ClawHub-supplied ranks. No X sign-in, skill execution or credential transfer is introduced. Sign-in-required/contact fields are unchanged.

The new native Today screenshot is `ios-news-release-20261012/store-news-today-native.png` (1320 × 2868). It uses retained actual public fixture content and capture dates; no fake fresh source check. The obsolete Following placement is removed from this private version while its original remains in Asset Library. Usage, detail, widgets, Lock Screen, API keys, welcome and Watch assets remain applicable. Reloaded final saved order: Usage, detail, Home Screen widgets, Lock Screen, API keys, welcome, current Today. Smaller sizes inherit this large-display set; the saved draft receipt confirms it. See [release checks](ios-news-release-checks-20261012.md) for exact source/sign/upload binding and publication gates.
