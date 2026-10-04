# Cross-platform reliability and architecture assessment

Reviewed on 4 October 2026 from main `5787047`. Changes are isolated on `codex/cross-platform-reliability-20261004`; the primary checkout and installed Mac application were preserved. This is a source, regression, build, and simulator assessment. It is not a production deployment or physical-device acceptance.

## Decision

Keep the native shared-Swift architecture and private CloudKit model. There is no Tokenroom account or hosted backend to scale. The Mac and iPhone collect provider readings; private CloudKit stores only usage, and Watch reads it independently. A separate product login would not remove the vendor-session dependency and would add credential custody and operating cost.

The architecture is appropriate for a personal usage product, but it is not yet evidence of optimal performance at arbitrary scale. Long-lived readers previously fetched the full zone, including retained alert history; they now apply in-memory deltas. The main remaining scalability boundary is vendor request coordination across separate app/widget processes, rather than the number of Tokenroom customers sharing one server.

## Evaluated scope and implementation

| Requested area | Assessment and resulting work |
|---|---|
| Mac, iPhone, Watch quality | Preserve native UI and shared domain logic. Fix clock/refresh ownership, show collector and successful-check age, expose iCloud failure beside retained data, and make retries available. |
| Frontend bugs and gaps | Serialize key removal against replacement, surface removal and permission errors, serialize iCloud deletion actions, use a coherent presentation date for reset/pace/Follow state, and align Mac News search trimming. |
| Sessions and login | Keep local tool-owned Mac sessions and device-local phone keys. Cancelled login attempts cannot announce success or overwrite newer attempts. Ambiguous token responses no longer trigger a second endpoint exchange. |
| Security | Reject cleartext credential dispatch and credential-bearing cross-origin redirects. Save replacement API keys atomically. Reject delayed account-generation caches and late cancelled CloudKit results. |
| Backend and sync | CloudKit remains the backend. Add complete-snapshot delta reads, record/page failure propagation, deletion handling, expired-cursor recovery, account invalidation, and serialized notification subscription writes. |
| Missing features implemented | Watch-requested paired-phone refresh/readings reply; per-provider source/check-age visibility; retained-data sync warnings and Retry; reliable retry of rejected local notification scheduling. |
| Notifications | Mark local alerts sent only after notification scheduling succeeds or CloudKit claims prior delivery. Persist completed schedules despite later background cancellation; preserve pending alerts after failure or before dispatch. Account/cancellation fences prevent old subscription filters overtaking newer writes. |
| iPhone and Watch usage freshness | The iPhone already collects key-based providers without Mac. Watch can ask that phone to collect while independently reading iCloud. Source membership preserves unpublished phone providers without reviving removed keys or unrelated collectors. Unchanged percentages no longer pin handoff freshness to an old retained cache. |

The backend changes add no CloudKit record fields or record types. Optional local cache metadata records collector membership and a device-local random generation; it contains no credentials or account identity. Old cache formats remain readable before the first observed account invalidation; invalidated generations cannot be replayed through phone widgets, shortcuts, Live Activity startup, or Watch handoff.

## Remaining work and architecture boundaries

| Priority | Gap | Concrete next step |
|---|---|---|
| P1 capability limit | Claude, Codex, Grok Build/Bot, Cursor, Antigravity, and Devin still depend on a Mac tool login or CLI. Transport improvements cannot collect new vendor usage while that collector is off. | Seek documented vendor plan-meter APIs; continue supported direct phone key paths. Do not copy Mac tokens into CloudKit or invent a public-client grant. |
| P2 missing feature | Copilot still requires a pasted fine-grained token on iPhone. Official GitHub App device flow can support a better login, but no real app registration/client ID is available in the repository. | Register a Tokenroom GitHub App with Plan read and device flow, then implement and validate the actual client. See the session assessment for primary sources. |
| P2 coordination | `KeyFetchGate` separates provider keys and shares cooldowns, but check-then-record is not an atomic cross-process lease. Simultaneous app/widget work can both dispatch. | Introduce a provider-scoped App Group transaction/lease with expiry, generation fencing, and physical-dispatch regression tests. Measure overlap before broad refactoring. |
| P2 account acceptance | Durable fences cover observed account notifications, confirmed no-account responses, failed clearing, and delayed writes. An account switch while every app/widget process is absent still needs cold-launch validation on signed devices. | Exercise switched accounts with retained caches and unavailable network; choose a privacy-preserving cold-launch scope policy without persisting account identity. |
| P2 background delivery | iOS and WidgetKit decide when background tasks, silent pushes, and timeline reloads run. Watch notifications currently depend on iPhone notification mirroring. | Physical paired-device tests for suspended apps, phone away, collector asleep, missed pushes, quiet hours, reset boundaries, and denied permissions. Do not promise continuous real-time refresh. |
| P2 maintainability | `MobileStore` still owns collection, relay, history, notification and presentation state. Its tested seams improved, but the audit did not benchmark broad architectural rewrites. | Extract scheduler/transport responsibilities when the remaining concurrency work needs those boundaries; keep shared logic and per-provider failure isolation. |

Apple documents that [background push delivery is not guaranteed](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app) and describes [WidgetKit's discretionary refresh budgets](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date). Delta reads follow Apple's [record-zone change-token model](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation/recordzonefetchresultblock).

## Companion assessments

- [Login and security assessment](session-security-assessment-20261004.md): supported authentication paths, provider constraints, credential-save behavior and refresh dispatch evidence.
- [Platform sync assessment](platform-sync-assessment-20261004.md): Watch handoff, timing, membership and signed-device acceptance.

## Validation

All provider/session regressions use mocked transport/storage. No real keys, vendor refreshes, production CloudKit writes, App Store submission, or installed-app replacement were performed. Xcode 27.0 was used; DerivedData stayed outside the source tree.

| Check | Result |
|---|---|
| Mac XCTest suite | 589 tests passed, zero failures |
| iPhone XCTest suite | 18 tests passed, zero failures; unsigned simulator host with CloudKit disabled |
| Shared Swift source | Typechecked for macOS, iOS, and watchOS |
| iPhone build | App, widgets, Watch app, and complications built through the iPhone test scheme |
| Command Line Tools fallback | Built with `TOKENROOM_SKIP_INSTALL=1 TOKENROOM_FORCE_SWIFTC=1`; existing legacy Keychain deprecation warnings remain |
| Diff / build script | `git diff --check` and `zsh -n scripts/build.sh` passed |

Regression coverage includes complete/delta page rollback and deletions; expired and cancelled cursors; late account scope results; old shared-file generations and observer orderings; paired-source membership and removals; failed key replacement; credential redirects; cancelled login ownership; physical token refresh dispatch count; phone-reply cancellation isolation; and notification acceptance followed by cancellation/relaunch. One provider's failure continues to preserve the others.

### Visual checks

Debug/sample screenshots were inspected for the Mac menu bar and popover, the iPhone Usage screen, and the Watch usage list. A compact iPhone tile now falls back to the provider's short name, so "Copilot" fits rather than truncating "GitHub Copilot". The Mac settings snapshot renderer did not reproduce a usable full native sidebar, so these screenshots do not establish settings interaction acceptance.

These are sample presentation checks. They do not verify real paired-device transport, signed entitlements, actual notification delivery, or production account transitions.

| Platform | Evidence |
|---|---|
| Mac | [Menu bar](validation-20261004/mac-menu-bar.png), [popover](validation-20261004/mac-popover.png), [dark popover](validation-20261004/mac-popover-dark.png) |
| iPhone | [Usage screen](validation-20261004/iphone-usage.png) |
| Watch | [Usage list](validation-20261004/watch-usage.png) |
