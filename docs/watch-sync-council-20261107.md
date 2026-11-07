# Watch, widget and iPhone sign-in sync: decision record (2026-11-07)

## How the decision was made

Four reviewers each wrote a proposal without seeing the others. Each took a different lens: sync, security and identity, watchOS and WidgetKit, and a skeptical user advocate. Each then reviewed the other three blind and ranked them, never voting for their own. The Borda count (2 points for first place, 1 for second) came out:

| Proposal | Points |
|---|---|
| watchOS/WidgetKit | 5 |
| Security | 4 |
| Sync | 3 |
| User advocate | 0 |

Every fact below was checked against `origin/main` 0c58b28.

## Verified facts

- **A cold Watch process holds the iPhone's handover in memory only.**
  - `WatchAccountGate.validated` is set only by an iCloud read.
  - `receiveBackgroundHandoff` never reads iCloud.
  - So `pendingPhone` keeps the handover without saving it or reloading complications.
  - WatchConnectivity delivers it again at the next activation, so the reading arrives late; it is not lost.
  - The same happens after a failed iCloud read, and when the Watch has no iCloud account.
- **The Watch waits for the iPhone's reply before applying a finished iCloud read.** The wait can last up to 16 s.
- **A reading the Mac re-confirms with the same numbers never reaches the Watch.** `materialHash` ignores `checkedAt`, and the handover is sent only when that hash changes. The Watch then fades a re-confirmed reading to stale after an hour. Widgets reload 1 s *after* the stale moment.
- **The Live Activity marks itself stale only at the window's reset.** `staleDate = resetsAt`, `pushType: nil`. A reading hours old can show as current.
- **`WatchLink` swallows `updateApplicationContext` errors with `try?`.** The payload size is never checked.
- **One answer from a token host can force a new sign-in.**
  - A 429 or 5xx is treated as unclear and leaves the session `exchanging`.
  - The next pass finds no recovery item and marks it rejected.
  - Result: a single 429 or 503 means "Sign in again".
- **`readSessions` ignores Mac coverage.** A Mac and an iPhone signed in to the same plan both call the vendor, and the tile can flip between them.

## Decisions

| Topic | Decision | Vote |
|---|---|---|
| Claude sign-in on the iPhone | All four recommend removing it. Anthropic's terms say third parties may not "offer Claude.ai login" or "collect, store, or intermediate Claude.ai credentials or session tokens". This is the owner's call, so it ships separately. | 4/4 |
| 429 and 503 from a token host | Count them as "not dispatched": the session stays ready. `invalid_client` and `unauthorized_client` mean rejected, with their own message. Replay once after a timeout: later. | 4/4 |
| Mac coverage | Pause the iPhone's session read while a live Mac reading is at most 15 min old. Resume after 25 min. A manual refresh overrides. | 3/4 |
| 20-minute "aging" tier | No. | 4/4 |
| Heartbeat 9 → 15 min | No. The Mac checks every 10 min, so 15 would act like 20. | 4/4 |
| `transferCurrentComplicationUserInfo` | Later, once the plain path is measured. | 4/4 |
| Read keys and sessions on silent push | No, for now. | 4/4 |
| Live Activity `checkedAt` / `staleDate` | Yes. The refresh intent comes later. | 4/4 |
| Watch with iCloud off | Accept iPhone handovers saved after the sign-out cutoff. | 4/4 |
| Sync health | A local record of dates and enum codes, plus logging. The UI comes in a later change. | 4/4 |

## What ships in this change

1. **Watch handover acceptance**, a pure function in `Shared`. A handover is applied when either:
   - `accountStatus()` returns `.available` within 5 s, or
   - the Watch has no account, or its iCloud read failed, *and* the handover was saved after the sign-out cutoff.

   A pending handover is saved to the App Group, and complications reload.
2. **The Watch applies iCloud first**, then the iPhone reply. `.unreachable` clears once iPhone data has been applied.
3. **The iPhone also hands over when the oldest shown check has moved forward 30 min or more**, even with an unchanged hash.
4. **Widgets and complications reload 5 min before the stale boundary.**
5. **Live Activity.** `ContentState` gains an optional `checkedAt`; older saved states still decode. `staleDate = min(reset, checkedAt + 60 min)`. "Stale before the reset" is shown differently from "reset, awaiting reading".
6. **Watch payload.** It is capped at 48 KB by trimming history, and send errors and sizes are logged.
7. **Renewal answers**: as in the decisions table. The existing test is rewritten, not deleted.
8. **Recovery item.** A read error (for example `errSecInteractionNotAllowed`) no longer counts as missing; only `errSecItemNotFound` leads to rejection.
9. **Mac-coverage pause** with the 15/25-minute hysteresis.
10. **Minimal `SyncHealth` record** in the App Group (dates and enum codes only), plus logging.

## Later

- Replay a refresh once after a timeout.
- `transferCurrentComplicationUserInfo`.
- A Live Activity refresh intent.
- A sync health row in iPhone Settings and on the Watch.
- Saving the CloudKit change cursor between launches.
- Removing Claude sign-in from the iPhone, if the owner approves.

## As implemented, and deviations

Branch `tokenroom/watch-sync-20261107`. Claude stays on the iPhone allowlist: removing it waits for the owner. Nothing under "Later" was built. The decision logic is pure code in `Shared` and tested in `TokenroomTests/WatchSyncDecisionTests.swift`, `PhoneSignInTests.swift`, `PhoneSessionTests.swift`, and `MobileLogicTests.swift`; the Watch, widget, and iPhone code only calls it.

| Item | Where |
|---|---|
| 1. Handover acceptance | `WatchHandoffAcceptance`, `WatchAccountGate.decision`, `WatchPendingHandoff` (`readings-pending.json` in the Watch's App Group), `RelayReadings.accountCheck`; `WatchStore.settlePendingPhone` |
| 2. iCloud first | `WatchRefreshOrder`, `WatchProblem.afterPhoneData` |
| 3. Re-confirmed readings | `WatchHandoffSchedule` (`checkStep` 30 min), `MobileStore.saveCache` |
| 4. Reload before stale | `ReadingFreshness.staleLead` (5 min), `WidgetSchedule.nextReload`, `ReadingCache.nearsStale` in `RelayReadings.isRecent` and `WidgetRefresher.cache` |
| 5. Live Activity | `SessionActivityState` (the `ContentState`, now in Shared/Core), `LiveActivityFreshness`, `SessionResetCaption` |
| 6. Watch payload | `WatchHandoff.encodedReadings` (`payloadLimit` 48 KB, `historySteps` 48, 24, 0 hours), `UsageHistory.trimmed`, `WatchLink.flush` |
| 7. Renewal answers | `PhoneSignIn.refreshAnswer`, `PhoneSessionRefresher.Grant.clientRefused`, `retrySpacing`, `PhoneSessionClient.clientRefused` |
| 8. Recovery item | `PhoneSessionStore.recoveryLookup`, `PhoneSessionRefresher.Outcome.unreadable` |
| 9. Mac-coverage pause | `MacCoveragePause`, `PhoneConnect.macReadingAge`, `PhoneSignIn.plansToRead(paused:)`, `MobileStore.readSessions(manual:)`, `ConnectView.sessionDetail` |
| 10. Sync health | `SyncHealth`, `SyncHealthLog` (key `syncHealth` in each device's App Group defaults) |

Deviations and choices the decision left open:

- **Item 1, complications with iCloud off.** A complication that read iCloud and found no account used to close the gate again every time (a new sign-out cutoff each read), which would have hidden the iPhone's handovers about 15 minutes after each one. `WatchCacheAccess.confirmNoAccount` now records a confirmed no-account sign-out (`watchConfirmedNoAccount`) and treats a later no-account as the same sign-out, until an account answers or it changes. Without this, item 1's "the Watch has no account" case would not hold.
- **Item 1, a failed account check.** In a cold background launch, an `accountStatus()` that errs or takes longer than 5 seconds counts as a failed iCloud read, so a handover saved after the cutoff is applied. A build with no iCloud container keeps holding it.
- **Item 3, which check.** The decision says "the oldest shown check". Implemented per provider instead: a handover goes when any shown reading's check has moved 30 minutes or more since it was last handed over. The oldest check overall is pinned by any reading nobody re-checks (a stale or signed-out provider, up to a week), so with one of those the rule would never fire. When every provider is re-checked together, as a Mac does, the two rules are the same.
- **Item 4.** A widget or complication reload 5 minutes before the stale boundary only helps if it reads again, but a cache saved minutes earlier counted as fresh. A cache holding a live reading within 5 minutes of going stale now counts as due for a read. Only live readings get the early boundary. `testWidgetsReloadHalfHourlyOnlyWhileAWindowIsBusy` now expects the calm reload at 55 minutes for a reading checked just then.
- **Item 5.** The activity is updated when only its check moved, once it has moved 5 minutes (`LiveActivityFreshness.checkStep`), so the stale date follows the reading without an update on every refresh. A stale activity from an earlier version, with no `checkedAt`, still reads as reset, because its stale date was its reset.
- **Item 6.** History is cut to 48, then 24, then 0 hours, whichever fits first. A cache still over 48 KB with no history is sent anyway and logged as `tooLarge`, because membership is never cut. The 19-provider fixture (three windows each, 168 hours) is 66.8 KB whole and 44.1 KB at 48 hours. `UsageHistory.bucket(for:)` fills a shortened history out to the week before recording, so a trimmed history can't index out of range.
- **Item 7.** After any answer that issued no token (429, 503, another OAuth error, or never sent), the refresher doesn't send the refresh token again for 60 seconds (`retrySpacing`). Otherwise Cursor's and Grok Bot's readers, which renew one session in the same pass, would send it twice to a host that had just said it was busy. 500, 502, and other 5xx answers are still unclear. `invalid_client` and `unauthorized_client` mark the session rejected with `PhoneSessionMetadata.clientRefused`, and the plan shows "Couldn't refresh this session: the provider turned down this sign-in. Sign in again, or read this plan on a Mac."
- **Item 8.** A recovery item that's read but holds no usable session also counts as missing, because it can never become usable. Only a Keychain read error counts as unreadable.
- **Item 9.** The pause is decided per plan, from the Mac's live reading of that plan. A paused plan stays listed, keeps its last reading, and isn't renewed. It isn't rechecked either, if it's one left out as not on its sign-in's plan. The state the hysteresis keeps is saved in the App Group (`sessionsPausedByMac`), so a relaunch between 15 and 25 minutes keeps it. Only the Usage tab's pull to refresh counts as manual. Open risk: a session paused for weeks isn't renewed meanwhile, so a refresh token that expires during that time asks for a new sign-in when the Mac stops.
- **Item 10.** Recorded on the iPhone: iCloud reads, handovers sent (and why one wasn't), background refreshes. On the Watch: iCloud reads, handovers received (applied, held, dropped), replies to its requests, background refreshes. Sizes are logged, not stored.
