# iPhone News 1.1.1(1) — release qualification

Qualification checkpoint: 12 October 2026. Implementation and local qualification are complete. Source `740f9a0` is committed on main and exact-source CI passed; Apple accepted 1.1.1(1), now Waiting for Review. See the [submission record](ios-news-release-delivery-20261012.md) for current states. The detailed pre-integration checks below remain timestamped qualification evidence, not public-release proof.

Checkout: `/Users/felipedominguez/Developer/tokenroom-improvements-20261004`.
Current evidence: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-release-20261012/`.
Earlier visual evidence: `/Users/felipedominguez/Documents/ChatGPT/TokenRoom/ios-news-implementation-20261012/`.

## Source and independent QA

The selected option 1 is implemented across Today, Following, Skills, Saved, collections and readers. Account-free local follows/saves, real public provenance, profile-only X links, supplied skill ranks/metrics, full reader summaries and source recovery retain their existing stores/contracts. No phone OAuth, credential transfer, X API, skill execution, relay/storage-schema or provider-adapter change.

Both earlier P2 fixes remain: adaptive hero/reader layouts retain one Save state owner; model-only follows distinguish article health from model freshness. A fresh independent read-only review found two P3 defects, both corrected and re-reviewed:

- Short hero titles now have a 44-point minimum rectangular hit area. Native tapping below the short title's glyphs opened the reader.
- Undo uses the retained removed snapshot's title. Save/Unsave the Copilot lead, unfollow Copilot so Codex becomes lead, then Undo: the accessible label still names Copilot, and Saved restores the original Copilot snapshot.

No remaining confirmed actionable source defect was reported. Read-only source review does not itself establish execution or delivery.

## Executed checks

| Check | Result | Evidence under current root |
|---|---|---|
| Full final Mac suite, after both P3 fixes | 780 passed; zero failed/skipped | `mac-final.xcresult`, `mac-final-summary.json`, `logs/mac-final.log` |
| Full hosted iOS suite, after both P3 fixes | 34 passed; zero failed/skipped; no exclusions | `ios-full.xcresult`, `ios-full-summary.json`, `logs/ios-full.log` |
| Shared typecheck | macOS, iOS, watchOS passed | `logs/shared-final.log` |
| Final version Debug Simulator build | Succeeded, app/widgets/Watch/complications | `logs/mobile-final-version-build.log` |
| Optimized Swift 6 Mac fallback | 125 source inputs compiled; binary unlaunched | `fallback-final.json`, `logs/fallback-final.log` |
| Live public Skills contract | HTTP 200 for Trending, Downloads, Newest; current parser decoded 30 entries per sort | `live-skills/http-receipt.json`, responses/decoded bodies and parser logs |
| Signed Release archive | Succeeded, 1.1.1(1) throughout all four components | `signed/mobile-archive-result.json`, filtered log |
| Export | Succeeded with scoped Apple-system PATH | `signed/mobile-export-system-path-result.json` |
| Private upload | Succeeded; observed uploaded IPA retained and hashed | `signed/mobile-upload-result.json`, filtered log |
| Exact uploaded IPA verification | All four strict signatures, Production capabilities, matching IDs/roles, unexpired distribution profiles, no debugging | `signed/uploaded-verification.json` |
| Apple processing | Ready to Submit; binary metadata Validated | `asc-build-processing-receipt.json`, `asc-1.1.1-processed.png`, `asc-build-metadata.png` |

Test suites precede the metadata-only version change from 1.1.0(1) to unused 1.1.1(1). The final Debug build and signed Release archive compile that final version. Existing Mac test-only State-outside-View and QoS warnings remain recorded; no failing test. No installer script or production app launch was used.

Native acceptance preserves the earlier ordinary/largest text, light/dark, four-section, source/search/follow, distinct ranking/detail, save/remove/Undo, model-only, empty/no-match and source-failure receipts. Current root adds:

- `short-title-lower-target.ax.txt` — enlarged short-title hit target.
- `undo-after-hero-change.ax.txt/.png`, `undo-original-story-restored.ax.txt/.png` — correct retained label and restoration after lead replacement.
- `skills-unavailable-after-retry.ax.txt/.png` — Retry completes honestly with no invented successful-check date.
- `share-dismissed.ax.txt/.png` — Share closes through Cancel, no item sent.
- `reduce-motion-before-current.ax.txt`, `reduce-motion-on-reader.ax.txt/.png`, `reduce-motion-on-back.ax.txt`, `reduce-motion-restored.ax.txt` — on-state reader/Back and verified restoration to off. Ordinary off-state navigation was already captured.
- `store-news-today-native.png` — native 1320 × 2868 current Today UI on a task-owned iPhone 18 Pro Max, ordinary text/dark and 9:41 status bar. Public fixture provenance remains under `mac-news-visual-audit-20261011/fixtures-v2/`; publisher/capture dates were retained, not updated for marketing.

## Exact candidate binding

`Config/Version.xcconfig` uses mobile 1.1.1 build 1; Mac stays 2.4.1 build 1. Signing configuration and `project.pbxproj` were not changed. Existing Apple signing credentials were authorized by Felipe; provider credentials were untouched.

`signed/production-inputs.json` records 198 source/resource/config/project inputs. Machine-local signing configuration is excluded. Recheck those hashes before committing; compiled input changes require a new qualified build, not a relabeling of this uploaded binary.

The qualified export SHA-256 is `c74880dffd5916e64b08829e6a38ac6e4dce45bc17f198e15f17c0100e436645`. Xcode's upload creates a separately re-signed IPA, whose actual captured SHA-256 is **`1d1be79d15bddd6be6ab45850e04768c85fb64496ab16d5b569496f947d2af2c`**. They are not byte-identical ZIPs. Independent verification proves all four executable UUIDs and every byte outside the corresponding code-signature payloads match; decoded Info.plist values match. Resource-signature differences correspond to re-signed children and plist serialization. All other file bytes match. The uploaded binary is bound to Apple build **`12b15493-c81e-4a63-b826-d1178056b33d`**, version 1.1.1(1), with symbols and no non-exempt encryption.

A first export failed because Homebrew rsync rejected Apple's `--extended-attributes` argument. A read-only path probe isolated this tooling cause. A PATH scoped only to Xcode's export/upload child (`/usr/bin:/bin:/usr/sbin:/sbin`) solved it; no system setting, signing policy, project source or installed tool was changed. The first failure and successful retry remain separate receipts.

The first verifier assumed an incorrect App Group suffix; it was corrected to source-defined `group.app.tokenroom`, with no candidate change. Phone/widgets have the existing shared keychain group; Watch components have none. This verifies declared capabilities, not production delivery.

## Apple qualification checkpoint and publication gates

Public mobile **1.1.0** was approved and released on 12 October 2026 at **15:07:19 UTC**, confirmed by official US/PT lookup receipts `public-store-us.json` and `public-store-pt.json`. Its prior submission history is preserved, not rewritten as candidate 1.1.1 evidence.

At the private draft checkpoint, **1.1.1(1)** was processed and attached to a Prepare for Submission draft. Accurate What's New and review notes were saved with manual release selected. The later submission record confirms accepted Waiting for Review status; approval cannot automatically publish this candidate. At the saved-draft checkpoint, the asset list contained seven screenshots, in order: Usage, detail, Home Screen widgets, Lock Screen, API keys, welcome, then the current native Today screenshot. The obsolete Following placement is absent and its source asset is retained in Asset Library. Smaller sizes inherit this set; unchanged Watch assets remain applicable. A reload confirms saved build/notes/assets and manual release in `asc-1.1.1-draft-receipt.json`; `asc-new-news-preview.png` shows the uploaded News asset.

Pre-integration sequence (source/CI/submission stages are now completed in the submission record):

1. Complete final independent documentation/source/diff review. Spoken VoiceOver is an accepted recorded limitation, per Felipe’s explicit reply on 12 October.
2. Recheck clean scope and signed input hashes; commit the qualified change, push main without overwriting unrelated work, and wait for exact-revision CI.
3. Only after the source/CI/store gates pass, submit that exact Apple build for App Review.
4. Wait for approval, manually release, then verify official public version 1.1.1 availability. Upload, Ready to Submit or Waiting for Review is not public release.
5. Preserve signed archives/dSYMs/IPAs and evidence. Clean only proven redundant task-owned temporary files/devices; never globally shut down/delete Simulators or another workflow's artifacts.

Mac 2.4.1 publication/install evidence remains in its dedicated delivery record. This iPhone-only release does not publish or reinstall a new Mac binary.

## Explicit limits and assumptions

Current native AX labels, controls and largest text passed. Spoken VoiceOver focus needs a person; the earlier human attestation was for the previous presentation and is not relabeled as current. Felipe explicitly chose “Proceed with this limitation recorded” on 12 October. It remains unverified and is not claimed as a passing check.

No Watch hardware and no shared-account device set are available; the user stopped physical iPhone work. Real private-iCloud coordination, notification/push delivery, signed App Group effects, Watch runtime and production persistence remain the approved finite News scope's existing integration limits. Mocked suites and isolated fixtures cannot prove those effects. Skills live responses were parsed locally; that is not a live iOS transport or production deadline measurement. The working Trending endpoint advertises deprecation without a sunset; replacement tracking remains a maintenance assumption, not fabricated rank data.

External simctl processes continued shutting down the owned iPhone 13 after the user reported global cleanup paused. Successful native journeys have their own receipts; stopped-device trees are not counted as passes. Operated devices are only `C409E3C9-807D-4F67-AB32-6E1ADAD7FCF3` and store-capture device `7E3C5A9B-9DE4-44B7-A23C-C8BF18A8579D`.
