<p align="center">
  <img src="docs/images/icon.png" width="96" height="96" alt="Tokenroom icon">
</p>

<h1 align="center">Tokenroom</h1>

<p align="center">
  <strong>AI plan usage in the macOS menu bar, on your iPhone, and on your wrist.</strong><br>
  Claude, Codex, Grok, Cursor, Copilot, and 14 more: used percent, pace, and reset time on your Mac, iPhone, and Apple Watch.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/privacy-local--first-5a9e6f?style=flat-square" alt="Local-first">
  <img src="https://img.shields.io/badge/license-MIT-4b6bfb?style=flat-square" alt="MIT">
</p>

<p align="center">
  <img src="docs/images/hero.png" width="920" alt="Tokenroom's popover on the Mac, the Usage tab on iPhone, and the Apple Watch app">
</p>

Tokenroom is a menu-bar extra. It does not live in the Dock. It reuses logins you already have. For pay-as-you-go and organization billing you can add an API key, which stays in your Keychain. It does not keep private account names, emails, or tokens on disk. News retains public publisher and skill-owner names for attribution.

Tokenroom was called Headroom until 2.0. On first launch it brings over Headroom’s settings and last readings; quit Headroom and move it to the Trash afterwards.

<p align="center">
  <img src="docs/images/menubar.png" width="277" alt="Tokenroom in the macOS menu bar: percents, meters, highest only, and meters in dark mode">
</p>

## Glance first

The extra shows **used %** for every provider you turned on, leading with its open window that needs attention soonest. Provider cards keep their primary window headline.

| Provider | What you see | Connect with |
| --- | --- | --- |
| Grok Build | Weekly pool | `grok login` |
| Grok Bot | Weekly pool | Grok Bot app |
| Claude | 7-day window | `claude login` |
| OpenAI (Codex) | Weekly window | `codex login` |
| Cursor | Billing cycle | Cursor app |
| GitHub Copilot | Monthly AI credits | `gh auth login`, a Copilot editor extension, or a fine-grained token |
| Antigravity | Gemini weekly | Antigravity, and `agy` 1.1.11 or later |
| Devin | Weekly quota | Devin app |
| Z.ai, MiniMax | Weekly or 5-hour | The key in Claude Code’s settings, or add one |
| Kimi Code | Weekly | `kimi` login, or add a key |
| OpenCode Go | Weekly | OpenCode’s login, or add a key |
| OpenRouter | Key limit, or spend | API key |
| DeepSeek, Moonshot, Vercel AI Gateway | Balance | API key |
| OpenAI, Anthropic, and xAI organizations | This month’s spend | Admin key |

Click the extra for the popover. Each provider shows its meter with a tick where an even pace would be, so you can see at a glance whether you're running ahead. With more than five providers connected, each gets one line.

<p align="center">
  <img src="docs/images/popover.png" width="400" alt="Tokenroom popover with ten providers on one line each">
  <img src="docs/images/popover-details.png" width="400" alt="An expanded card: every window, a week of history, pace, and banked resets">
</p>

Click a provider for its details:

- **Every window**: weekly, session, per-model limits, and extra usage, each with its reset time.
- **Pace**: "Ahead of pace · runs out Sat 11:37" when you'd hit the limit before it resets.
- **A week of history**, with the resets marked.
- **Forecasts**: how many days a balance lasts at this week's rate, and where this month's spend is heading.
- **Banked resets** (Codex) and when each expires.

The footer strip counts banked resets, new models, and updates; click one to open it. Cursor is labeled **This cycle**, never Weekly.

## News

News has four destinations on iPhone and Mac: **Today**, **Following**, **Skills**, and **Saved**. Today leads with a recent official update, then new models, public articles from voices you follow, opt-in provider status, and upcoming model retirements. Open a story for its full title, publisher dates and available excerpt, then save it, share its link, or open the original. Search covers retained followed-source items and saved metadata.

Following preserves your existing tools and labs. You can add curated voices such as Simon Willison, Ethan Mollick, Andrej Karpathy, Boris Cherny and Alexander Embiricos. Available public article feeds appear in Tokenroom; **Open on X** opens their profile. Following is a local reading choice and does not follow an account on X. Profile-only entries say so. Provider status reports are separate and opt in; your personal reset times remain in Usage.

Skills shows ClawHub's public **Trending**, **Most downloaded**, and **Newest** listings, with owner, ranking definition and check time. Details show available version and declared requirements. Popularity does not establish compatibility. Tokenroom reads listing metadata and never downloads or runs a skill. Each shelf searches up to 30 loaded entries; rankings are transient and refresh when needed on entry or on request. Displayed positions preserve the original response order even when invalid records are omitted; saved positions retain their check date. Malformed rankings keep the last usable shelf; valid empty rankings clear it. Readers share one eight-second request deadline, and late responses cannot replace the shelf after it expires. Mac Skills checks require News to remain enabled at dispatch.

Models older than 14 days remain in the archive without increasing new-model counts. Collections show when their sources were checked and offer targeted retry after a failure, including paired feeds for a tool. Checking News indicates the shared refresh in progress. Empty collections link to Following. Today’s retirement shelf follows your lab choices; All labs expands the full collection.

Saved titles, links, bounded excerpts and reading choices stay on this device. They can be revisited offline; original pages still need a connection. Saves survive unfollowing or feed rotation. This version does not sync News choices or saves through iCloud. Mac News remains off until you turn it on in **Settings → News** or the News window. Public source requests use no Tokenroom account or provider credentials.

## Alerts

At 80% and 95% of a limit, set apart for 5-hour limits and for weekly and monthly ones; when a limit is on course to run out before it resets; when a busy window resets, when a banked reset arrives or is about to expire, and when a balance or budget runs low. Each alert goes out once, from whichever device sees it first. Quiet hours hold the ones that can wait until morning. Set them in **Settings → Alerts** on the Mac or in the iPhone app; the choices are shared through iCloud.

## Why it exists

Each of those tools already knows how much quota you have left. None of them put it next to the clock. Tokenroom does, as tiny percents or iStat-style meters, then gets out of the way.

- **Local-first.** No Tokenroom account, no Tokenroom server, no telemetry.
- **Your logins.** Sessions stay where each tool keeps them. Claude, Grok Build, and Codex are renewed there; every other login is only read.
- **Independent meters.** One provider failing never blanks the others.
- **Three looks.** Percents, vertical used-bars, or only the highest, for the providers you pick. Refresh every 5, 10, 15, or 30 minutes. Launch at login if you want.

Numbers in the screenshots are sample data.

## iPhone and Apple Watch

<p align="center">
  <img src="docs/images/iphone.png" width="860" alt="Tokenroom for iPhone: the Usage tab, a provider's detail with a week of history, and Lock Screen widgets with the Live Activity">
</p>

Tokenroom for iPhone shows the same meters, pace, and a week of history. They come from your Mac through your own iCloud. The iPhone also reads coding plans (including GitHub Copilot with a fine-grained token), pay-as-you-go balances, and organization spend itself, with keys you add there, so it's useful without a Mac. Plans whose only login lives in a tool on a Mac (Claude, Codex, Grok Build, Grok Bot, Cursor, Antigravity, Devin) need Tokenroom for Mac; the iPhone doesn't sign in to them. A login on your Mac stays on your Mac, keys stay on your iPhone, and only usage syncs. It adds:

- a tile for every plan: its weekly (or monthly) limit as a ring and its 5-hour limit as a bar, each with the even-pace mark and when it resets or runs out
- **Close to a limit**: every limit at 80% or more, or on course to run out before it resets, most urgent first, with Follow on Lock Screen
- Home Screen and Lock Screen widgets, with countdowns that tick without draining the widget budget
- a Live Activity that follows a session, or a nearly spent week, to its reset; start it from the app, Control Center, the Action button, or Siri ("Follow usage in Tokenroom")
- the alerts above, as notifications, even when the app isn't running
- News with Today, Following, Skills and Saved: source-attributed stories, curated public voices, skill discovery, native sharing and a local reading library

The Apple Watch app and its complications read the same iCloud records, so they keep working with the iPhone away. Refresh on the Watch also asks a reachable paired iPhone to check its own providers and share its newest readings. Provider tiles identify the collecting device and its last successful check; sync failures remain visible beside saved readings. Plans collected only on a Mac still need that Mac running to obtain new usage. The Smart Stack shows a limit as it nears its reset or passes 80%. The signed download of Tokenroom for Mac sends its readings on its own (**Settings → iPhone & Watch** turns that off). A copy you build and sign yourself can't use iCloud.

Tokenroom for iPhone and Apple Watch is available on the App Store. It has a sample mode for looking around first.

## Install

Download Tokenroom from the [latest release](https://github.com/felipedrf74/tokenroom/releases/latest), unzip it, and move Tokenroom.app to Applications. It's signed with a Developer ID and notarized by Apple, so it opens without warnings, and it's the build that can sync with the iPhone and Apple Watch apps.

Or build it on the Mac that will run it (a build signed on your Mac works, but can't sync with iPhone):

```bash
git clone https://github.com/felipedrf74/tokenroom.git
cd tokenroom
./scripts/build.sh
open /Applications/Tokenroom.app
```

Xcode 27 is preferred. Command Line Tools are enough for the `swiftc` fallback.

After opening, look at the **right side of the menu bar**. Opening the app again from Finder re-shows the popover.

The build is ad-hoc signed and **not sandboxed** — it has to read CLI credential files. If macOS blocks the first launch: **System Settings → Privacy & Security → Open Anyway**.

## Sign in

1. Click Tokenroom in the menu bar.
2. On a provider that isn’t connected, click **Sign In**, or **Add Key** for key-based providers.
3. Finish login in the browser, Terminal, or app that opens.
4. Tokenroom picks up the session and shows usage.

The same controls live in **Settings → Providers**. Turning a provider off hides it from Tokenroom; it does not log you out of that provider.

Tokenroom uses the login you already have. Claude, Grok Build, and Codex access tokens expire after a few hours; Tokenroom renews them in that tool’s own login and writes the new tokens back, so you stay signed in and the tool does too. It doesn’t keep a copy. Other logins are read only. A session whose refresh token is no longer accepted keeps its last reading, faded, for up to a day.

## Privacy

Tokenroom caches readings (percentages, reset times, window labels, and any balance or spend) and a week of hourly history in `~/Library/Application Support/Tokenroom/`. See [PRIVACY.md](PRIVACY.md). What changed between releases: [CHANGELOG.md](CHANGELOG.md).

## Settings

- **General**: launch at login, and what's left of Headroom.
- **Providers**: what's connected, what Tokenroom found signed in on this Mac, and what's available, plus organization billing.
- **API Keys**: coding-plan keys, a fine-grained token for Copilot, pay-as-you-go keys with a reference amount, and organization keys with a monthly budget.
- **Alerts** and **News**: as above.
- **Menu Bar**: Percents, Meters, or Highest, and which providers show.
- **iPhone & Watch**: sync through iCloud.

Bundle ID is `app.tokenroom.mac`.

## Develop

```bash
./scripts/build.sh
```

DerivedData is forced to `~/Library/Developer/Xcode/DerivedData/Tokenroom`. UI, tokens, and provider contracts: [`.grok/skills/tokenroom-macos/SKILL.md`](.grok/skills/tokenroom-macos/SKILL.md). The iPhone, widgets, and Watch: [`.grok/skills/tokenroom-apple/SKILL.md`](.grok/skills/tokenroom-apple/SKILL.md).

Tests: `TokenroomTests` (on the Mac, including all the shared logic) and `TokenroomMobileTests` (in the iPhone app). The images above come from sample data: a debug build of the Mac app renders them with `-TokenroomSnapshots <folder>`.

The app icons come from one drawing in `scripts/make-icons.py`: it writes the Icon Composer files for the iPhone, Watch, and Mac, and the Mac PNGs the Command Line Tools build needs. Change the script and run it, rather than editing the icons.

Build settings live in `Config/*.xcconfig`. Builds are ad-hoc signed by default. To sign with your own team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and set `TOKENROOM_TEAM_ID` and `TOKENROOM_MAC_SIGNING = team`. `TOKENROOM_SKIP_INSTALL=1 TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh` exercises the Command Line Tools fallback.

`main` is protected. Send a change as a pull request from a fork; the maintainer has to approve it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Tokenroom isn't affiliated with any of the providers it shows. Their names are used only to identify the services you connect.

The [cross-platform assessment](docs/cross-platform-assessment-20261004.md) records the reliability changes, current architecture, verification, and remaining device and provider constraints.

[Current release checks](docs/news-release-checks-20261011.md) record the News redesign and earlier Mac navigation, currency/history and alert fixes. Complete suites pass 766 Mac tests with no exclusions and 34 hosted iOS tests; shared platform checks and Release builds pass. Current signed r2 artifacts, Mac notarization and private mobile upload/processing pass. The finite approved News fixture acceptance passes ordinary/largest text, light/dark/narrow layouts, native navigation, sharing, saved actions and representative error recovery. Human VoiceOver attestation retains its earlier component scope. Further physical phone work stopped at Felipe's request; real Production iCloud/notification/widget/Live Activity/App Group and Watch runtime remain unverified integration limits. The approved News plan's Watch compilation passes; it requires no new hardware. [Mac 2.4.0 is public](https://github.com/felipedrf74/tokenroom/releases/tag/v2.4.0) and installed on both validated Macs. Mobile 1.1.0(1) is Waiting for Review, with automatic release after approval selected. [The delivery record](docs/news-release-delivery-20261011.md) binds the released source, successful CI, public package, installations and remaining limits. [QA6](docs/news-sixth-qa-validation-20261011.md) remains historical evidence.
