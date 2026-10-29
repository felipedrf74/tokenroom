## Change

-

This PR cannot land on `main` until the maintainer approves it. Do not push to `main`.

## Testing

<!-- Which AGENTS.md test commands ran, with their output. CI only compiles
TokenroomMobileTests, so say whether you ran them locally. For UI changes, a
screenshot of the extra and the popover, or simulator or device evidence. -->

## Risk

<!-- Low, Medium, or High, and which boundaries it touches: the menu bar extra
or popover, provider sessions and token renewal, Keychain groups, the iCloud
relay, entitlements and signing, versioning, personal data. -->

## How to revert

<!-- A revert commit is enough, or what else a rollback needs: a shipped
TestFlight or App Store build, relay records already written in the new
format, migrated settings. -->

## Check

- [ ] No names, emails, user IDs, or tokens in source, fixtures, or screenshots
- [ ] Menu bar extra still fits without overflowing
- [ ] A missing provider session does not blank the others
