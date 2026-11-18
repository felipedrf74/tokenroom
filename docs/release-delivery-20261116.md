# Mac 2.6.3 delivery and mobile 1.3.5 submission — 16 November 2026

**Mac 2.6.3 (1) is public. Mobile 1.3.5 (1) is Waiting for Review**, submitted at 23:19 UTC
with automatic release after approval to all users. Approval and public availability of
1.3.5 are pending; submission is not publication. Mobile 1.3.4 was publicly released on
16 November at 17:46 UTC, and Mac 2.6.2 on 15 November; neither had a record of its own.

## Source and verification

| Item | Evidence |
| --- | --- |
| Change | #74, merged as `71134cfe12833bb7a4f6ebb1aac44d05cb9ab9e5` |
| Tree | `62c63076d86e56fdd2c0bfe37fd2dc7ddf9cc5e5` |
| Tests | 1,060 Mac and 63 hosted iPhone tests passed on the branch head |
| CI | [All jobs passed](https://github.com/felipedrf74/tokenroom/actions/runs/43976227238) on the merged commit |
| Review | One fresh-context review, no blocking finding; the maintainer merged |
| Behaviour | [The direct read](usage-direct-read-20261116.md), measured against Production |

## Public Mac package

[GitHub release v2.6.3](https://github.com/felipedrf74/tokenroom/releases/tag/v2.6.3) is
neither a draft nor a prerelease and is marked latest. Its assets are `Tokenroom-2.6.3.zip`,
`Tokenroom-2.6.3.zip.sha256`, `release-source.json` and `production-source-inputs.json`.

- ZIP SHA-256: `9972849f1d4243fa03bf52eb30a6573e4190c273f28e8ff81aaecf5e8b8baa6d`.
- Executable SHA-256: `181020e63aa3f2c65ccdc9e2814e8b88e96024139b06663ebc2ee8e8062b4433`.
- Universal arm64/x86_64, Developer ID, Production iCloud container, no debug entitlement.
- Notarization `f0d43072-1211-4408-8a58-77f06084df45` accepted; stapled; Gatekeeper says
  "Notarized Developer ID". The public download matched the checksum and passed the same checks.

## Installations

Both use the public package and keep the app they replaced for rollback. Preferences and
tool logins were left as they were.

| Mac | Previous | Installed | Verification |
| --- | --- | --- | --- |
| MacBook Pro | 2.6.2 (1) | 2.6.3 (1), 23:14 UTC | Executable checksum, signature, Gatekeeper, running process, first send to iCloud at 23:14:26 UTC |
| Maquinho Pro | 2.6.1 (1) | 2.6.3 (1) | Reported by the agent that installed it there: zip and executable checksums, signature, staple, Gatekeeper and running process; receipt in that Mac's `~/Documents/Tokenroom Reports/release-delivery-20261116/` |

## Signed mobile package and upload

The iPhone app, widgets, Watch app and complications are all 1.3.5 (1), signed with Apple
Distribution for the Production iCloud environment, with no debug entitlement.

- Local export IPA SHA-256: `da53a89e0580125fbe173572c34c1463d9766027ea8f4deca90d817be078a35f`.
- One upload through the existing Xcode account succeeded at 23:13:09 UTC.
- Apple's processed build: `6af218be-f1ca-473d-872e-991e835b8092`, `VALID`, no export-compliance
  question open. **Do not upload 1.3.5 (1) again.**

## App Review submission

Done in the maintainer's own App Store Connect session, which he signed in to himself.

- App Store version `70d522a0-d231-4414-80d8-1dc7b4e194aa`, 1.3.5, created after 1.3.4 was
  Ready for Sale.
- The two What's New paragraphs from `docs/app-store.md` were saved and read back identical.
  Description, keywords, URLs and the seven iPhone and two Watch screenshots carried over from
  1.3.4 and weren't changed. Promotional text was empty before and stays empty.
- Build 1.3.5 (1) attached; release type automatic after approval; no phased release.
- Review submission `9b45faf7-1ccf-4c86-812a-c83401d4353d`, accepted
  **16 November 2026, 23:19:27 UTC**, state **Waiting for Review**.

## Not shown by this delivery

- That the iPhone shows this Mac's readings. On 16 November the two weren't using the same
  iCloud database ([what the iPhone showed](usage-direct-read-20261116.md)). The cause, found
  on 18 November, is a development build on the iPhone, not the Apple Account: see
  "Correction (18 November)" below.
- The direct read running on a signed iPhone, widget or Watch. It ran against Production
  from the Mac only.

## Which iCloud each device used (16 November, 23:25 UTC)

Checked after the delivery, with the probe on both Macs and the iPhone's App Group
preferences. No account was read or compared by name; this is what each device's own
Tokenroom saw.

| Device | iCloud for Tokenroom | Evidence |
| --- | --- | --- |
| MacBook Pro (2.6.3) | Signed in, sending | Account available; a send every few minutes, none failed; its zone holds this Mac and one iPhone record last written on 15 November at 11:09 UTC by 1.3.2 |
| Maquinho Pro (2.6.3) | No iCloud account | The probe answers "no account"; every send in 30 minutes failed with CloudKit's "Not Authenticated"; Claude is signed out there too |
| iPhone (1.3.3) | Signed in, to a database with no Mac in it | A successful cloud read at 23:22:18 UTC built a cache with only the four plans it reads itself, 96 seconds after the MacBook Pro's send; nothing it sent that day is in the MacBook Pro's zone |

Version 1.3.3 reads the whole zone, so a read that succeeds returns every collector in that
database. The MacBook Pro's record was there and fresh, so the iPhone wasn't reading that
database. The three devices don't share one iCloud account for Tokenroom, and until they do
no version makes the iPhone or the Watch show a Mac's readings.

What only the owner can do: sign the iPhone and the MacBook Pro in to the same Apple Account
(Settings, at the top, on the iPhone; System Settings, at the top, on the Mac), and sign
Maquinho Pro in to it too, with iCloud on for it.

### Correction (18 November)

The paragraph above blamed the Apple Account. That was an inference nobody checked, and for
the iPhone it was wrong. Measured on 18 November at 12:38 UTC:

- `devicectl device info apps` lists Tokenroom on the iPhone as built by a developer, 1.3.3 (1).
  It lists only developer installs, so the iPhone was not running the App Store build. A
  development-signed build uses CloudKit's Development environment; the Mac release and the
  App Store build use Production. Same Apple Account, two databases.
- The iPhone's collector ID in its App Group preferences is the ID of the one iPhone record
  in the MacBook Pro's Production zone. So this iPhone wrote there until 15 November at
  11:09 UTC, as the App Store's 1.3.2, and stopped when the development build replaced it in
  place (the App Group, and so the ID, stayed).
- The iPhone recorded a successful cloud read at 12:36:04 UTC and still held only the four
  plans it reads itself, while the MacBook Pro's record in Production was 93 seconds old with
  Claude live.
- That the App Group preferences could be copied over `devicectl` at all, on 16 November
  too, was already the sign: it only reaches a development install's containers.

A development install doesn't update from the App Store on its own, which is why the iPhone
stayed on 1.3.3 while 1.3.4 and 1.3.5 were released. Which run installed it isn't recorded.

What the owner does: update Tokenroom from the App Store on the iPhone (1.3.5), or delete it
and install it again from there. Then a Mac probe shows an iPhone record written by 1.3.5.
Maquinho Pro's row stands: it has no iCloud account. The rule that follows is in the
`tokenroom-apple` skill, under "iCloud environments".

## Revert

The previous public Mac release and both rollback apps remain. Put the kept app back to
reverse an installation. A correction to a public package needs a new version; don't
overwrite its assets or retag it. Mobile 1.3.5 (1) is consumed by its upload: a replacement
needs a new build number. The submission can be withdrawn in App Store Connect while it
waits for review.

Local receipts are under `~/Library/Developer/Xcode/Archives/Tokenroom-DirectRead-20261116/`
(`READINESS.md`, the archives, exports, logs and the rollback app).
