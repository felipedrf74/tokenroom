# Mac 2.5.0 and iPhone 1.2.0 — delivery record, 22 October 2026

Status on 22 October 2026: **Mac 2.5.0(1) is publicly released** and installed on this Mac. **iPhone, widgets and Apple Watch 1.2.0(1) is Waiting for Review**, set to release automatically once Apple approves it. Felipe authorized finishing, installing and releasing in chat that day.

**Outcome (recorded 30 October 2026):** Apple approved 1.2.0, and it was released automatically on 22 October at 18:08 UTC (App Store lookup). Mac 2.5.1 replaced 2.5.0 as the latest release on 30 October; [the 30 October record](release-delivery-20261030.md) covers that release. The App Store description was not updated with 1.2.0 (see iPhone, below).

## Source

| | |
|---|---|
| Changes | #39 (product audit fixes, faster News), #38 (iPhone plan sign-in), #40 (version bump) |
| Merged | #39 as `0165c2a`, #38 as `8afc826`, #40 as `89296cacb5db56fb273398f98b0349d87e221bcd` |
| Released tree | `3fd99f970cd51171dfa977735de146694a4f0eab`; tag `v2.5.0` |
| Merge path | The "Protect main" ruleset asks for one code-owner approval; the author is the only maintainer, so all three used the ruleset's existing admin bypass, as Mac 2.4.1 did. The agent ran each merge on the maintainer's instruction in chat, after that PR's head passed CI. No rule changed. |
| CI | Each PR head passed "Build and test" on GitHub's `macos-26` runner (Xcode 26.6): Shared typecheck, Mac tests, iPhone build, iPhone test compile, Command Line Tools build. #40's head has the released tree: [run 39754847477](https://github.com/felipedrf74/tokenroom/actions/runs/39754847477). |
| Local (Xcode 27.0) | On the released code: 916 Mac tests and the full iPhone suite (42 tests, iPhone 18 Pro simulator), 0 failures. |
| CloudKit | No field or record type changed; the Production schema needed nothing. |

Both binaries were built from `69842ca`, whose tree differs from the released one only in one `CHANGELOG.md` sentence, which isn't compiled; `production-source-inputs.json` hashes the compiled inputs at the released commit. `69842ca` is #40's head before it was amended to `331eebd`. It is on no published branch; a local ref, `refs/keep/ios-1.2.0-build`, keeps it from being pruned in this Mac's clone.

## Mac 2.5.0 (1)

- `scripts/release.sh`: Developer ID signature, Production iCloud, notarization Accepted (submission `49d7604a-2b50-4d7f-b065-fd5f3ad83afe`), stapled, Gatekeeper "Notarized Developer ID". Universal arm64/x86_64. CDHash `209ca7a8f2ed0089b527b449dd030dab436de30e`.
- [GitHub release v2.5.0](https://github.com/felipedrf74/tokenroom/releases/tag/v2.5.0), marked latest: `Tokenroom-2.5.0.zip` (SHA-256 `0dc7e57b1a0c5707254ad641b8056dd6f431159ed783528ba725531fe4f73a38`), its `.sha256`, `release-source.json`, and `production-source-inputs.json` (208 inputs, digest `ed478158611856d7ccd2049c9a1a63399902878c56fa46cd4faec24e5fde286a`).
- An anonymous download of the published zip matches the checksum, and `/releases/latest` points to v2.5.0.
- Installed on this Mac from that download: the staged and installed app both passed version, bundle ID, signature, staple and Gatekeeper checks. The running 2.4.1 was stopped by its exact path and 2.5.0 relaunched. A verified copy and the original of 2.4.1 are kept under `~/Library/Application Support/TokenroomReleaseRollback/20261022T093538Z/`. The second Mac was not updated.

## iPhone, widgets, and Apple Watch 1.2.0 (1)

- Archived (Release) and exported for App Store Connect. All four components are 1.2.0 (1), with Production iCloud, production push on the app, no `get-task-allow`, valid signatures, and `ITSAppUsesNonExemptEncryption = NO`. Uploaded with Xcode on 22 October at 09:20 UTC; processed.
- App Store Connect, version 1.2.0: build 1.2.0 (1); What's New, promotional text and review notes from `docs/app-store.md`; name **Tokenroom: AI News & Usage** and subtitle **Usage limits, resets & alerts** (submitted with the version); automatic release, to all users at once, keeping existing ratings. Keywords, screenshots, privacy ("Data Not Collected") and age rating unchanged. The description was left unchanged too, which was a miss: its privacy bullet still says "Logins never leave your Mac, and keys never leave your iPhone", which plan sign-in made untrue, and the draft's replacement bullet wasn't entered. `docs/app-store.md` › Description has the text to enter.
- Submitted for review on 22 October at about 09:33 UTC: "1 Item Submitted", status Waiting for Review.

Review notes as submitted:

> Tokenroom works without an account. To look around quickly: Settings › Sample Data (or "Try sample data" on the welcome screen) turns on realistic sample readings for every screen, widget, and the Live Activity.
>
> Real readings come from three places:
>
> 1. Tokenroom for Mac (free, open source; https://github.com/felipedrf74/tokenroom). It reads usage from the AI tools on the Mac and syncs the readings through the user's own iCloud private database.
> 2. Plan sign-ins on the iPhone (Settings › Plans), new in 1.2.0: Claude, Codex, Grok Build, Cursor, and Grok Bot. The user signs in on each company's own page (Safari for Claude and Cursor, a short code for Codex and Grok Build; Grok Bot uses the Cursor sign-in). The app only reads usage with the sign-in, from the same endpoints each company's own command-line tool or app uses; the sign-in stays in the iPhone's Keychain and is never synced. Real readings need the user's own plan with that company; Sample Data shows the same screens without one.
> 3. API keys the user pastes on the iPhone (for example an OpenRouter key, or a GitHub fine-grained token with the Plan permission for Copilot). The app only reads usage and balances with them. Most are read through the provider's documented API; Z.ai, Kimi Code, OpenCode Go, and MiniMax's older Coding Plan are read from the usage endpoints their own tools call, which those providers haven't documented.
>
> The Watch app reads the same iCloud records. Notifications are optional and come from the user's own devices through iCloud. There are no in-app purchases.
>
> News (Today, Following, Skills and Saved) reads public feeds only and works without a Mac, API key, or sign-in. Following lets users opt in to curated voices and official release/status feeds; X links there open public profiles, and News has no X sign-in. Skills reads public ClawHub listing metadata only and does not download, install or execute skills. Saved story metadata is local to this device. Version 1.2.0 adds release feeds for Gemini CLI, Copilot CLI, OpenCode, Claude Code, Claude Agent SDK, Claude Skills and Google DeepMind. News content retains its original source and publication date; skill ranks and metrics are supplied by ClawHub.

## Still open

- App Review: done. Approved and released on 22 October (see Outcome).
- App Store description: the privacy bullet above still needs replacing. App Store Connect changes a description only with a new version, or with a version taken back out of review.
- Vendor terms: plan sign-in uses each vendor's own CLI/app public client. Anthropic's consumer terms (February 2026) bar third-party apps from offering Claude.ai sign-in; App Review or a vendor may object. The owner took that risk for all five plans on 21 October (`docs/iphone-login-without-a-mac.md` › Decision change), naming Claude the riskiest; OpenAI's, xAI's and Cursor's terms weren't checked. Removing a provider means taking it out of `PhoneConnect.productionAllowlist` and `PhoneSignIn.providers`, and out of the tests that pin those sets.
- Renewal rule: on the iPhone, a 4xx OAuth error other than `invalid_grant` keeps the session ready, to retry with the same refresh token (RFC 6749 §5.2), as #38's Risk section says. That is looser than `docs/session-security-assessment-20261004.md`, which says only a sender-proven `notDispatched` restores `ready`. Keeping it needs the maintainer's decision, written into that assessment.
- Not exercised: a real plan sign-in, renewal and usage read against the live vendors from an iPhone; physical-device checks of Mac wake and toggles, Watch and widget reloads, and live feeds. 2.5.0 was relaunched on this Mac, but its behaviour there was not inspected.
- Test preference files: #39's description says the Mac tests now delete the `tokenroom.tests.*` files they create. Only suites made with `TestDefaults` are swept; most tests name their own suites, and their files stay in `~/Library/Preferences` (about 3,900 on this Mac on 30 October).
