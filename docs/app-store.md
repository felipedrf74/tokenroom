# App Store listing: Tokenroom for iPhone and Apple Watch

A draft for App Store Connect. Provider names appear only in the description, as facts, never in the name, subtitle, or keywords. Tokenroom isn't affiliated with any provider.

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
| Release | Automatic, as soon as App Review approves it |

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
