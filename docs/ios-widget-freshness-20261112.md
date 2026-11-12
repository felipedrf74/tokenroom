# iPhone and widget freshness (12 November 2026)

## Cause and decision

A CloudKit heartbeat could update `readings.json` without requesting a widget timeline.
`MobileStore` compared each save with the previous save, although WidgetKit only reads
the file when building a timeline. Unchanged checks therefore never renewed its one-hour
stale boundary. A deferred background reload also disappeared on process death.

An independent Claude Fable 5.2 review at High effort identified this delivery gap,
the one-hour retry after a failed widget read, the phone's five-minute network backoff,
and presentation waiting for unrelated key/session requests. The implemented solution
follows that proposal, with these boundaries:

- `WidgetReloadSchedule` keeps a small durable baseline of the last reload request,
  scoped to the phone cache's random account generation. It contains provider readings,
  with no collector labels, history, credentials or account identifiers.
- Background reloads still prioritize membership, status, threshold and reset changes.
  Re-confirmed live checks renew the timeline after 45 minutes, per provider, while below
  the existing 32-build allowance. A fast collector's date is bounded by the request date.
  Foreground activation compares the current validated cache with the durable baseline,
  including after a relaunch or an extension write.
- `ReadingCache.cloudReadAt` is optional and dates only a complete successful cloud read.
  Rebuilding presentation after a failed read no longer makes the cloud cache recent.
  Older caches remain readable and get a cloud check on their next timeline.
- A failed due widget read requests another opportunity after five minutes, or an hour
  after 16 timeline builds, reserving room for hourly recovery for the rest of an offline
  day. An explicit CloudKit Retry-After remains the earliest
  retry time. Timelines still fade and expire real old readings.
- The iPhone retries a connection failure after 15 seconds, with at most one additional
  foreground recovery attempt. Activation and manual refresh can bypass this connection
  wait, while server-directed rate limits, busy responses and container waits remain.
- A completed cloud read is presented before key/session collection finishes. Publication,
  alerts and final activity completion still wait for the complete refresh pass.

No relay schema, token ownership, signing settings, version or CI gate changed.

## Verification

Two new hosted regressions failed before the implementation: unchanged 9-minute
heartbeats never renewed the widget, and a deferred percentage change was lost across
a new `MobileStore` over the same defaults/cache. Both pass after the change.

`WidgetFreshnessTests` covers the 45-minute boundary, a stale sibling provider, fast clocks,
durable/generation-scoped baselines, a day of heartbeats plus timeline scheduling,
bounded widget retries, legacy caches and connection-versus-server retry policy.
Hosted tests cover activation after relaunch, cloud presentation while key lookup is
blocked, and manual/activation retry with network failure versus a server rate limit.
The two existing heartbeat tests now assert the Watch's already-shipped check handovers
and the new bounded widget renewals instead of expecting no delivery at all.

Exact command results and simulator acceptance are recorded in the pull request.

Local final checks: 1,023 Mac tests and 53 hosted iPhone tests passed, Shared typechecked
for macOS/iOS/watchOS, and the optimized Swift fallback built with installation skipped.
Fresh-context review reported no remaining findings after correcting response-time
Retry-After deadlines, monotonic partial/final presentation, and the separate short-retry
allowance (38 timeline builds in a continuously offline day).

On iPhone 18 Pro / iOS 27 Simulator, the inert sample Home and Lock Screen widget
galleries rendered their meters and sample labels; native Usage-to-provider navigation
opened the retained weekly and session details. These are presentation/navigation
checks, separate from the hosted recovery and cache-delivery regressions.

## Remaining integration limit

WidgetKit's `after` policy makes a timeline eligible for a reload; it does not promise
execution at that instant. See Apple's [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
and [Timeline](https://developer.apple.com/documentation/widgetkit/timeline).
Tests establish the app's requests and retained data, not production push delivery or
the system's timing on a locked physical iPhone. With no awake collector, a Mac-only
provider remains honestly stale. A physical lock/unlock and airplane-mode recovery pass
remains useful release acceptance; no TestFlight or App Store delivery is claimed here.
