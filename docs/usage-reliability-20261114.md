# Usage recovery on Mac and iPhone — 14 November 2026

Usage could stop advancing after sleep, an offline check, a delayed iCloud send,
or a Keychain lookup. A living iPhone app could also overwrite a widget's newer
cloud reading with its older in-memory copy. The change repairs these paths
without treating retained usage as a new measurement.

## Reproduced failures and corrections

| Trigger | Before | After |
| --- | --- | --- |
| A Mac with one networked provider is offline, or another enabled provider has no login | No recovery attempt until the normal collection timer | One additional attempt after 45 seconds, with ordinary provider spacing and Retry-After |
| Sleep cancels a queued forced refresh; wake requests another | Wake joins the cancelled task and returns without checking | The cancelled work settles, then wake starts a new check |
| Usage changes before the iCloud send allowance opens | The reading waits for another collection, potentially 10–30 minutes | One deferred sharing task sends the latest reading at the existing allowance; no additional provider request |
| A widget reads newer cloud usage while the iPhone app is suspended; the app's next cloud read fails | The app writes its old percentage and membership over the widget cache | The app adopts the newer validated complete source snapshot, including removals, and retains its connection error |
| Security does not finish key/session discovery | All later full refreshes queue behind it | Each discovery wait ends within 20 seconds; later cloud reads continue while sharing one physical lookup |
| Key metadata returns a temporary unreadable error | The iPhone removes the provider from its cache and source | The provider remains; no usage request or allowance is consumed until discovery recovers; actual not-found still removes it |

The original failure scenarios were exercised before their fixes. In the cache
regression, a newer synthetic 84% reading reverted to 42%, a removed source returned,
and the successful cloud-read date moved back. The corrected scenario retains 84%,
the removal, device-local providers and the newer cloud-read date. A newer successful
app cloud read still replaces the older widget snapshot. Account-generation mismatches
cannot restore old-account data.

The blocked-discovery regression separately holds key and session metadata reads.
Two full passes now return and the second cloud result appears, with one physical
blocked lookup in each path. Removing credentials or changing the cloud account
while a lookup is held cannot restore the removed credentials or prior cloud data.

## Delivery limits

`RelayPublishPolicy` still allows status/threshold changes after one minute,
material changes after five minutes, and reconfirmed unchanged readings after nine
minutes. A deferred round coalesces to the latest data and stops on sleep or quit.
Already-sent checks do not start repeating heartbeats. The send does not advance
any provider's successful-check timestamp.

Cloud retries count from the response and respect explicit waits longer than an
hour. An actual backward clock change invalidates the old wall-clock wait. Invalid
or zero waits fall back to five minutes; short valid waits have a one-minute floor.
Permanent failures do not create an immediate retry loop.

For the default ten-minute collection setting, the repaired offline scenario can
request recovery after 45 seconds instead of waiting roughly 600 seconds. This is
a scheduling bound, not a measured API response time or a promise of fresh usage
when the network/provider is unavailable.

## Verification

- Complete Mac suite: **1,034 tests, zero failures**, including 10 added methods.
- Complete hosted iPhone suite: **60 tests, zero failures**, including seven added methods.
- Shared typechecks: macOS, iOS and watchOS passed.
- Optimized Command Line Tools build passed with installation skipped.
- CI change-selection tests: three passed; pre-push tests: four passed.
- `git diff --check` passed.

Mac tests use `TOKENROOM_MAC_SIGNING=adhoc` because this machine's development
profile does not cover its device. The app test host remains inert. The iPhone
tests ran locally on iPhone 18 Pro / iOS 27 Simulator with the repository's local
signing configuration. DerivedData stayed outside the repository.

```sh
xcodebuild test -project Tokenroom.xcodeproj -scheme Tokenroom \
  -destination 'platform=macOS' TOKENROOM_MAC_SIGNING=adhoc \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Tokenroom-FreshnessMacAgent"
xcodebuild test -project Tokenroom.xcodeproj -scheme TokenroomMobile \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Tokenroom-FreshnessMobile"
./scripts/typecheck-shared.sh
TOKENROOM_SKIP_INSTALL=1 TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh
```

## Human QA

The separate `ios-human-qa` skill referenced by `full-send` was absent on both
development Macs. The repository's inert snapshot composition was used for native
Simulator acceptance: Usage displayed the sample meters; tapping the OpenAI tile
opened weekly/session details and history; Back returned to the same provider list.
The Device panel carried the native interaction. Mac sample renders retained meters,
provider rows and explicit stale/rate-limit treatment. These checks validate
presentation/navigation, independently of the hosted recovery regressions.

The affected installed Mac environment also had a development collector without
iCloud entitlements running. It was stopped and the existing Production-signed
installation was started. Its local successful-check dates advanced, but its actual
CloudKit calls returned `Not Authenticated`. An authenticated matching Apple Account
is still needed for physical Mac-to-iPhone delivery. Test publishers' successful
log lines were kept separate from the installed process's evidence.

No credentials, Keychain groups, relay schema fields, versions or CI gates changed.
This source verification is not a new Mac release, TestFlight upload, App Store
publication, physical push-delivery result or WidgetKit execution-time guarantee.

## Revert

Revert the source commit and distribute the previous app build if a release has
already included it. The cache uses an existing optional snapshot field; there is
no server migration or destructive data conversion to reverse.
