# Usage sync: measured cause and the direct read (2026-11-16)

Usage still showed stale on the iPhone, its widgets and the Watch after #66, #69 and #73.
Those changes were decided from the code and from Mac logs. Nobody had measured what a
reader actually gets from iCloud. This record has the measurement, what it showed, and the
change that follows from it. It supersedes the transport and freshness rows of
`usage-ingestion-council-20261115.md`; the rest of that record stands.

## What was measured

A Production-signed Mac build ran a read-only probe (`-TokenroomSyncProbe YES`, see
"Checking it again") against the real zone, five times on 16 November. The iPhone's App
Group preferences were read over `devicectl` to see what the phone itself recorded.

| Read | Requests | Time |
|---|---|---|
| The collectors' `Source` records by name | 1 | 0.22–0.34 s |
| The whole zone from the beginning (`recordZoneChanges`) | 66 | 20.3–24.8 s |
| The same without a page limit | 66 | 20.2–23.1 s |
| The zone from a saved cursor | 1 | 0.26–0.30 s |
| A query for every `Source` (`schema > 0`) | 1 | 0.31–0.38 s |
| A query for every `Event` (`alertKey != ""`) | 1 | 0.35–0.48 s |

The zone held 33 records: 2 `Source`, 2 `History`, 12 coordination `Prefs`, 17 `Event`.

- The first 14 pages of the zone read were empty: no record, no deletion, only a new cursor.
  Most of the 66 were.
- The two `Source` records arrived on pages 64 and 66. They are saved every few minutes, so
  they are always the newest changes, at the end.
- A page limit changed nothing. The server decides where a page ends.
- The length follows how much has ever been written to the zone, not how much it holds. A
  collector saves its `Source` about 160 times a day, so the read gets longer every day.

## What that explains

Every reader built before #73 waited for the whole zone read: 5 s in a widget, 6 s in a
complication, 10 s on the Watch, 20 s in the iPhone app. A read that needs 20 s or more and
delivers the readings last can't finish in any of them. A process that stayed alive kept its
cursor and read in 0.3 s, which is why the app sometimes worked and a relaunch broke it again.

The Mac was sending the whole time: 101 sends in 23 hours, none failed.

## What the iPhone showed, and what is still open

The iPhone (1.3.3) had recorded, in its App Group preferences:

- widgets holding four providers, all read on the iPhone itself, and nothing from the Mac;
- no plan paused because a Mac reads it, though the Mac was reading three of them;
- a cloud read that succeeded at 20:52 UTC, and alert pruning done at 14:29 UTC that day.

In the Mac's iCloud database, the iPhone's own `Source` record was 34 hours old and last
written by 1.3.2.

Those don't fit together in one database. The iPhone prunes only after its send went
through or wasn't due, and a successful read of the Mac's zone would have brought the Mac's
readings. So on 16 November the iPhone was reading and sending somewhere the Mac's database
doesn't show. The usual reason is a different Apple Account on one of the two devices, and no
code change fixes that. This is unconfirmed: nothing readable from the Mac says which account
the iPhone uses. Compare the Apple Account on each device before judging this change by
whether the iPhone shows the Mac's readings.

**Settled on 18 November:** it wasn't the Apple Account. The iPhone was running a
development build of 1.3.3, installed over the App Store's 1.3.2 after 11:09 UTC on
15 November, and a
development build uses CloudKit's Development environment while the Mac release uses
Production. The evidence is in `release-delivery-20261116.md`, "Correction (18 November)".

#73 (Mac 2.6.2, iPhone 1.3.4) made the read by name the fallback and kept the zone read as
the complete one. That fixes freshness for collectors a reader already knows. It left three
gaps, all of which grow with the zone:

1. A reader that knows no collector (a new install, a Watch without a handover, a widget
   without a cache) still needs the whole zone read.
2. The app used the read by name only after the zone read had run out its 20 seconds.
3. A page was kept only once the read had "made progress". The zone opens with empty pages,
   so a reader whose limit is shorter than that run kept nothing and started over each time.

## The change

Readers no longer use the zone read. `CloudRelay.contents(known:)` reads directly:

1. A query lists the name of every `Source` (`schema > 0`, a field every version has written,
   queryable in Production already; no schema change).
2. At the same time, one request by name fetches the collectors the reader already knows,
   their `History` records (`hist-<source>`) and the alert choices (`prefs-alerts`).
3. A collector the query found that the reader didn't know is fetched by name in a second
   request.

Records always come from the requests by name, which read the record itself. The query only
says which names exist. So:

- a collector the query leaves out (its index can trail a save) stays while its record is
  there;
- a collector is gone only when its record is confirmed missing;
- a record that could be neither read nor confirmed missing fails the read, and the reader
  keeps what it had.

Measured against Production: 0.52 to 0.58 s knowing no collector, 0.31 to 0.35 s after that. It doesn't
depend on the zone's age, and it fits in a widget's seconds.

Around it:

- The iPhone app, its widgets, the Watch app and the complications all call it, passing the
  collectors in their cache. Widgets and complications that know their collectors now get
  complete membership too, not only newer copies.
- The read by name alone (`sources(named:)`, from #73) stays as the second line: readers run
  it beside the direct read and use it when the direct read runs out of time, or fails
  without a wait iCloud asked for and without a sign-out.
- Pruning old alert records uses the `Event` query on the Mac and the iPhone. The iPhone
  used the events from its zone read, which it no longer makes.
- The zone read remains as the fallback when a query is refused (`invalidArguments`, a schema
  without the index) and when the zone isn't there, so a zone the user deleted in iCloud
  settings is found exactly as before. It now keeps its cursor on every page, empty ones
  included, so any limit makes progress.
- The iPhone records how its own send went (`SyncHealth` channel `cloudWrite`), beside
  `cloudRead`.

## Not changed

- No CloudKit schema change, no new record type or field, no server.
- What collectors write, and when (`RelayPublishPolicy`).
- Membership and removal rules when reconciling caches (#73).
- Old alert records without an `alertKey` aren't found by the query, so they stay. They no
  longer cost a reader anything.

## Checking it again

- Mac: `Tokenroom.app/Contents/MacOS/Tokenroom -TokenroomSyncProbe YES` prints the timings
  above for the signed-in account and exits. It starts no collector, reads no login, writes
  nothing, and prints counts, states and ages only. It needs a build signed for iCloud.
- iPhone: `SyncHealth` is in the App Group preferences, which `devicectl` can copy from a
  paired device (`--domain-type appGroupDataContainer --domain-identifier group.app.tokenroom`,
  source `Library/Preferences/group.app.tokenroom.plist`). The cache files sit outside what
  it allows.

## Verification

- The direct read ran against Production from the probe build, before and after review:
  2 collectors, 2 histories, 0.52 and 0.58 s cold, 0.31 to 0.35 s after; a name that
  doesn't exist was left out.
- Mac suite: 1,060 tests, 0 failures. New: the direct read's membership rules
  (`RelayDirectReadTests`) and a zone read cut short among empty pages.
- iPhone hosted suite: 63 tests, 0 failures, with the iPhone scheme build (widgets and
  Watch). `typecheck-shared.sh` and the Command Line Tools build passed.
- A fresh-context review of the diff found no blocking problem. Its smaller findings were
  applied: a missing zone goes through the zone read, the incomplete-read error carries no
  record name, and the query loops stop at their page limit.
- Not verified here: the change running on a signed iPhone, widget or Watch. That needs a
  build Apple has processed; the probe measured the same CloudKit calls from the Mac.
