# Tokenroom UI overhaul

Date: 6 November 2026. Status: approved by the design council in rounds; see the pull request.

## Goal

The iPhone, Mac, and Watch apps look far better and are lighter and gentler on the eyes, with every
area of each app scoring at least 9 of 10 for Design Quality and Visual Quality from all council
members. Behaviour, data, and the meaning of the numbers don't change.

## Direction: colour is data, everything else recedes

The baseline's main fault, named by every reviewer, is that orange is both the brand accent and
the "tight" level, so a healthy account looks like an alarm.

1. **Only readings carry colour.** Blue, yellow, orange, and red appear on a meter or ring, and in
   a short caption about that reading. Tabs, links, switches, titles, and icons don't use them.
2. **Numbers are ink** until a limit is critical. The meter says the level; the figure says how much.
3. **One anatomy everywhere.** Mark and name, one figure, one caption (window · reset), then a flat
   meter or ring with a quiet pace tick.
4. **Fewer boxes.** Hairlines and space instead of a filled box inside a card inside a window.
5. **Exceptions are designed.** Expired, stale, reset-pending, and limit-reached states keep the
   surface's layout rather than swapping in another.
6. **Lighter means less competing emphasis.** It never means dimmer captions, hidden warnings, or
   a stale reading that looks live.

## Tokens

| Token | Before | After |
|---|---|---|
| Track | primary 0.12 | primary 0.08 |
| Fill tint at start | white mix 0.34 | white mix 0.14 |
| Meter sheen, ring tip bead and shadow | on | removed |
| Past-pace stripes | hatch | flat lighter stretch |
| Pace mark | 2 pt, primary 0.8, overhangs | 1.5 pt, primary 0.5, notch 3 pt |
| Percent ink | orange from 75% used | primary until 90% used, then critical |
| Charts | provider's tint or green | neutral line, faint area, a level-coloured dot on the latest reading |
| App accent | brand orange | system blue, for controls only |
| Selected tab, Watch titles | accent | primary ink |
| Fact tiles | filled boxes, uppercase labels | no fill, sentence-case labels |

The level colours and their thresholds are unchanged. Brand orange stays in the app icon and on
the one News action.

## Scope

- Mac: all five popover styles keep working and share the calmer language; Orbit gets compact rows
  so more providers fit, a horizontal detail hero, and in-style expired rows. Settings loses repeated
  titles and tag noise. News loses nested boxes.
- iPhone: Usage stops alarming twice, tiles fit their names, detail flattens, onboarding shows every
  choice without scrolling, Settings and News follow the tokens.
- Watch: detail leads with the reading, plan moves below, captions shorten.
- Widgets and complications follow the tokens, and sparklines lose their rainbow.

## Out of scope

Removing popover styles. Two reviewers asked for it and two did not; it deletes a saved preference,
so it's the maintainer's product decision. Provider marks are never recoloured or redrawn. The
copy-owned rules (errors start with "Couldn't…", sample labels) stay.

## Decisions

- The iPhone's "Turn on alerts" chip shows once there are readings. With none, there's nothing to
  alert on and the first action should be connecting; Alerts stays in Settings.
- In widgets the system tints, the monogram stands in for a provider's mark, since a mark can't be
  tinted without recolouring it.

- News's text actions (Check collection, Mark these stories read, Add the tools I use, Choose what to
  follow, Explore skills.sh) are ink at a medium weight. Caption grey read as status, and system
  blue shares a hue with a healthy reading; News's one coloured control is Read article. A link
  that stands alone adds the app's own glyph: a chevron into the app, an arrow out of it.

## Evidence

`./scripts/ui-snapshots.sh <folder>` renders every screen from sample data. No login, key, or
iCloud data is read.
