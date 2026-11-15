# Usage ingestion: decision record (2026-11-15)

Usage kept showing stale on the iPhone, its widgets and the Watch, and sometimes on the Mac.
Earlier fixes (#66, #69) tuned when surfaces reload and how caches reconcile. They did not
touch the read path, which was where it actually failed.

## How the decision was made

Three models from different providers worked as a council:

- Claude Opus 5.5 at high effort.
- GPT-6.1 Sol at high effort.
- Grok 4.7 Fast at xhigh effort.

Each wrote a proposal independently: a root-cause map, a critique, a target architecture, a
migration plan and the main risk. A debate then settled every divergence. Each seat saw the
other positions without names and had to challenge them with evidence or concede. The
moderator verified the disputed facts in the code before accepting them.

## Evidence (Mac 2.6.1, Production build, 15 November)

- `relay sent 4 providers` appeared about every 5 minutes, so the Mac's writes were succeeding.
- Every send was followed by `relay pruning failed: ICloudTimeout()`.
  - Pruning reads the whole zone with `contents()`, inside the sharing round, under a 20-second limit.
  - It never finished, so `eventsPrunedAt` stopped moving.
  - Alert records then piled up, which made the next read even longer.
- `refresh failed claude` was logged 93 times in 24 hours.
  - The Claude Code status line isn't installed on this Mac.
  - So every check calls `oauth/usage`, which answers 429 to frequent calls.
- No iPhone logs were available. The iPhone path below is established from the code. The
  runtime error codes on the device are unverified.

## Root cause

Every reader called `CloudRelay.contents()`: the iPhone app, the widgets, the Watch app and
the complications. `contents()` is a `recordZoneChanges` read of the whole zone.

- The zone mixes a few small `Source` records with history, alert records and
  delivery-coordination records.
- The change token was kept only in memory, so every new process started from nothing.
- A read committed only after its last page. A timeout discarded every page already received.

So once a full download took longer than a reader's limit, no read ever completed. The limits
were 5 s for widgets, 6 s for complications, 10 s for the Watch and 20 s for the iPhone app.
Fresh data was in iCloud, and the surfaces never got it.

Two smaller causes added to it:

- A failed attempt marked a recent reading stale immediately, or as rate limited. On the Mac,
  Claude's 429s faded the reading and flipped the relayed state many times a day.
- Pruning, a maintenance task, ran inside the sharing round.

## Decisions

| | Decision | Rejected, and why |
|---|---|---|
| Transport | Keep `RelayZoneReader`, made durable. It commits at each page boundary once a read has made progress. Each app persists the zone and the cursor (`RelayZoneArchive`), tied to the account fingerprint. Pages are capped at 100 records. A pass that restarts from the beginning keeps the records it holds until it completes, then drops the ones it didn't see. | `CKSyncEngine`. Its subscription covers the whole database, and fetches can't be limited to `Source`. It would push on every history and alert write. Alert claims and preference merges need direct, immediate saves, not an outbox. (Debate D1; two of three seats, the third conceded on claims.) |
| Freshness | Readers that know their collectors read the `Source` records by name (`records(for:desiredKeys:)`, `RelaySourceRefresh`). That is one request however much else the zone holds. Widgets and complications read only by name once they know a collector. The iPhone app and the Watch app run the zone read with a read by name beside it, and use the result by name when the zone read runs out of time. | Bounded zone reads. A page can be all alerts and no `Source`. A daily full scan in an extension is the read that already times out. (D2.) |
| Membership | A read by name keeps the last complete read's membership and its date, and never claims a new collector. A collector it confirms gone is recorded as a removal with its own date (`RelaySnapshot.removed`, optional JSON). On reconcile, membership follows the newer complete read, minus removals confirmed after it. Each collector takes its newest copy from either side (one writer per collector). A complete read after a removal supersedes it. | Compare-and-swap on `savedAt`. A widget stamps `savedAt` even when it kept old cloud data. (D3.) |
| Failures | A transient failure (429, offline, unreadable answer) within an hour of the last success leaves the reading live. It ages from its own check time. Retry-After comes from the error, not the status. The Mac logs the class of every failure. | Fading on every 429. It shows the same readings as stale on every surface and flips what is relayed. A rate-limited state never showed its age. (D5, unanimous.) |
| Upkeep | Pruning runs after the sharing round, one at a time, never awaited. It has a 120 s limit, a one-hour retry after a failure, and is cancelled on sleep. Its zone read keeps its pages, so it completes over several attempts. | — |
| Heartbeat | Unchanged at 9 minutes. The zone subscription already filters on `Source` (`CloudRelay.swift`, `changes.recordType`), so pushes are a few per hour, and the outage was the read. | 40 minutes. It brings back "checked 40m ago" on the iPhone for a Mac that just checked. (D4, smaller change.) |
| Server | None. WidgetKit push and Live Activity push both need an APNs sender: an owner decision, deferred until this change is measured on devices. | — |

## Follow-ups (not in this change)

1. A cross-process file lock around read–merge–write of the App Group cache. Today the app
   reconciles before it rebuilds, and the widgets merge source by source, but a write can still
   land between another process's read and write. (Council consensus 4.)
2. Show why a reading is old: "Mac not seen since …", "Claude rate-limited; last reading …",
   "Can't reach iCloud since …". Show it from an attempt state carried in the payload JSON, which
   needs no schema deploy.
3. Claude: make the status-line bridge the routine source where it's installed, and persist the
   429 back-off across launches. If two Macs read one account, let only one call the endpoint.
4. Delete expired `alert-coordination-*` Prefs records in pruning.
5. Measure on signed devices: record counts per type in the Production zone, and how long a
   first zone read takes. Then decide on the APNs server.

## Verification

- Mac suite: 1,051 tests, 0 failures. The tests that encoded the old behaviour were changed
  deliberately: whole-read rollback, and a failure fading a recent reading. New tests cover:
  - reads cut short that build up progress across processes;
  - a restarted pass;
  - reads by name;
  - the zone archive's account fence;
  - reconciling source by source;
  - pruning apart from sharing.
- iPhone hosted suite: 62 tests, 0 failures. That includes the zone read timing out while the
  read by name keeps the readings current, and a collector a widget confirmed gone staying gone.
  Both fail without the change.
- `./scripts/typecheck-shared.sh`, the iPhone scheme build (widgets and Watch), and the Command
  Line Tools build all passed. `git diff --check` is clean.
- Reviewed with sol-loop: 4 rounds with GPT-6.1 Sol (high). Verdict: approved. Fixed along the
  way: a confirmed deletion ignored by the app (S1), and membership found by a newer read
  dropped by a deletion (S2, now dated removals reconciled with or without a phone handover).
- No CloudKit schema change: `records(for:)` and `resultsLimit` use existing record types and fields.
