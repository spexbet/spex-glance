# Spex Glance

A macOS menu bar app and desktop widget that shows your **open Kalshi sports bets** —
positions, resting orders, and unrealized P&L — with live prices streaming in the menu bar.
(iOS is on the roadmap; this build is Mac only.)

Sports only, on purpose. Kalshi tags every series with a category; anything not
`Sports` (politics, economics, weather…) is counted in a small "n non-sports not shown"
footer and otherwise ignored. Sports are recognized from Kalshi's own tags (Baseball,
Tennis, Hockey, Football…), so new leagues appear without a code change.

Read-only by construction. The app signs requests with a Kalshi API key that is
**read-only and lives only in your device's Keychain**. There is no code path that
places, amends, or cancels orders — and the app checks the key's scopes against Kalshi's
`GET /api_keys` when you connect: the key must have **Read all data** checked and nothing
else — not Full access, Trade, Transfers, or Accept block trades — or it is refused, so a
forgotten checkbox on Kalshi's key page can't slip through. (The two greyed read-side boxes
Kalshi auto-includes with Read are fine.) The check repeats on every launch.

Companion to [Haruspex / Spex](https://spex.bet). Works
standalone; does not need a Spex server.

## What it looks like

Every row reads as the market sees it: **Dodgers 63% — Giants 37%**. Favorite in bold,
your side tinted green (YES) or red (NO). Percentages are the bid/ask midpoint, i.e. the
market-implied win probability.

| Size | Shows |
|---|---|
| Small | A cobalt tile: net unrealized P&L, games held and how many are live, sports total |
| Medium | Top 3 games: status, each position with its chance, P&L |
| Large | Cash / Positions / Total tiles, up to 6 games and 2 resting orders |

Expand a game on the Positions tab for its live scoreboard from Kalshi's live-data feed
(`GET /live_data/batch`, one public request every 15 s for all your games, only while one is
on): score, period/quarter/inning/set and clock, possession or server, down and distance,
runners and count, power plays, red cards, the last play. The LIVE tag on a collapsed card
reads from the same feed.

Every widget size stamps "as of 2:41 PM": WidgetKit refreshes on a budget, so the widget is
never truly live. The menu bar is.

On the **Positions** tab, the **Live** checkbox (left of the sport pills) narrows the list
to games that have started and haven't settled yet: games in progress, plus finished games
still marked *Final · awaiting settlement*. A finished game stays until Kalshi pays it out,
then drops off. A combo shows as soon as any one of its legs is live. The checkbox works
together with the sport pills and is remembered across launches. **⌘L** toggles it (Positions →
Live Games Only); from another tab it jumps to Positions with Live on.

Positions in the same game (YES "Dodgers win" + NO "Giants win") fold into one row with a net
line; the app list expands each game to its markets.

**Combos** (Kalshi's multi-leg "parlay" contracts) show as one row —
`COMBO Vegas · Atlanta ✓ · Vacherot 12%` — where each leg is colored by whether it has hit or
missed and the percentage is the combo's own market price. Expand the row for per-leg odds. A
combo counts as sports when every leg is a sports market; it appears under All, under a
"Combos" pill, and under each sport it touches. Leg quotes stream live like everything else. Clicking a game on the
widget opens the Spex Glance window on that game; clicking anywhere else opens it on Positions.

## Requirements

- macOS 15 or later (15, 26, 27 — the releases Apple currently supports), Apple silicon only
- To build from source: Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`), and a paid Apple developer account ($99/yr) — the widget needs
  App Groups, which Apple does not offer to free "Personal Team" accounts. To just run it,
  see *Install without building* below; no Apple account needed.
- A Kalshi account

## Build (about 10 minutes)

1. Clone this repo and open a terminal in it.
2. Required for your own build: change every `bet.spex.glance` in `project.yml` to your own reverse-DNS
   prefix (also in `Shared/KalshiEnvironment.swift` and both `.entitlements`). Bundle IDs must be unique per Apple account.
3. `scripts/gen.sh` — asks for your 10-character Team ID once (Xcode → Settings → Accounts),
   stores it in an untracked `.team` file, renders the app icon, and generates
   `SpexGlance.xcodeproj`.
4. Open the project in Xcode, pick the **SpexGlance** scheme, press Run — or run
   `scripts/install-mac.sh`, which does a Release build into `/Applications` and launches it.
5. The app launches. Click **Connect Kalshi** and follow the three steps (below).
6. Add the widget: right-click the desktop → Edit Widgets, search "Spex".

## Install without building (macOS)

Download the latest `SpexGlance-<version>.dmg` from
[Releases](https://github.com/spexbet/spex-glance/releases), drag it to Applications,
launch. The app is notarized. It checks GitHub once a day for updates (Settings → Updates, or
Spex Glance → Check for Updates…); each update is verified with an EdDSA key built into the app,
so a hijacked download link cannot hand you a bad build.

Or with Homebrew:

```sh
brew tap spexbet/tap
brew install --cask spex-glance
```

`brew uninstall --zap --cask spex-glance` removes the app and its settings (the Kalshi key stays in your login keychain).

## Connect Kalshi (the wizard)

Kalshi has no "Sign in with Kalshi" for third-party apps, so the key is created by hand on
their website, once. The wizard walks you through it:

1. **Key setup.** Leave *Create the key on Kalshi* selected.
2. **Private key.** Click *Open Kalshi API keys page* (opens in your browser), sign in
   however you normally do (Google / Apple / passkey / 2FA — the app never sees this), click
   *Create New API Key*, set it to **Read only**, name it "Spex Glance", save. Kalshi
   downloads a `.txt` with the private key — an Ed25519 key for keys made since October 2026,
   RSA for older ones; both work. Back in the app: *Open file…* and pick it. It goes into
   your Keychain.
3. **Key ID.** Kalshi shows a UUID next to the new key. Copy it; the app auto-fills from
   the clipboard. Click *Test connection* → green check → *Finish*.

The app talks to Kalshi production. The demo exchange is still wired in
(`KalshiEnvironment.demo`) for anyone who wants to build a play-money variant.

Optional path: *Generate on this device* makes an Ed25519 pair locally so only the public
half is ever registered with Kalshi, and the private half never passes through a browser
download. It's the same key type Kalshi's own button now makes, so pick it only if you'd
rather the private key never leave this Mac; the default path is just as strong.

To disconnect: tap *Disconnect* in the app, then delete the key on Kalshi's profile page.

## Live updates on the Mac (menu bar)

On macOS the app also installs a menu bar item: net unrealized P&L in the bar, and a
dropdown in the app's colors: Cash / Positions / Total tiles, then one card per game with
its status, each position's chance, and the game's P&L. Work Mode drops the tiles and every
`$` there too. One WebSocket connection
to Kalshi carries four read-only channels:

- `ticker`, filtered to the markets you hold — a trade shows up within about a second.
- `market_positions` and `user_orders`, unfiltered — a fill, a sale, a new resting order
  or a payout changes the list within a couple of seconds. A market the app hasn't seen
  yet (a brand-new buy) triggers one full reload for its names and sport.
- `market_lifecycle_v2` — Kalshi's `determined` event flips "Final · awaiting settlement"
  to Won/Lost the moment a game is decided; `settled` triggers a reload for the new cash
  balance. This channel has no server-side filter, so the app drops everything that
  isn't one of its markets.

The socket sends nothing but `subscribe`; it is read-only like everything else here.
Every message carries Kalshi's own send timestamp; if the feed falls more than 15 s
behind, the live dot turns amber and says how far. If the socket drops it retries with
backoff, and the 5-minute REST poll reconciles in the meantime, so a missed message can
never leave stale numbers up for long.

## When Kalshi has a bad day

Kalshi runs no official status page. Instead of scraping a third-party one, the app asks
Kalshi directly: `GET /exchange/status` (public, no key) once a minute and right after any
failed refresh, plus its own view of things (failed refreshes, socket drops, feed lag).
The verdict tints the menu bar:

- Ember icon and text, "slow": something is impaired but data still flows — trading paused,
  a shard paused, two refreshes in a row failed, the socket stuck in retry, or the status
  check itself failing.
- Red, "down": the exchange is halted, or three refreshes in a row have failed, or the status
  check and the data paths are both failing.
- Gray, "maint": Kalshi reports a maintenance window or gave an estimated resume time.
- Gray, "offline": this Mac has no network path (NWPathMonitor). Nothing is polled and Kalshi is
  not blamed; the window says "Computer network offline" until the connection returns.

Kalshi's own trouble is counted in consecutive failures, so one dropped packet never
tints the bar. Two cases are not Kalshi's and say so plainly, judged by the *last attempt*
rather than the last success:

- Amber, "network": the last call couldn't get out of this Mac — DNS failed, a VPN or
  firewall blocked it, or it timed out. The window says which in one line, e.g. *Can't look
  up Kalshi's address — check your VPN or DNS.* It clears on the next call that gets through.
- Red, "key": Kalshi rejected the key (401/403). This is the one thing only you can fix.

429 (rate limited) never moves the dot.

The dropdown and the main window show the reason and since when. When Kalshi itself is
the subject, a *Status page* button opens kalshistatus.com in your browser — an unofficial community page, opened only
when you click it. The app itself still talks to nobody but Kalshi.

## Troubleshooting

**Positions stopped updating.** Check for a VPN first. A VPN that changes DNS or blocks
Kalshi stops the 5-minute refresh, and the footer says *Can't look up Kalshi's address —
check your VPN or DNS* (or similar) with an amber dot. A WebSocket opened *before* the VPN
came up can keep streaming prices (an open socket needs no DNS), so "Live" may stay green
while the refresh fails — the "Updated N min ago" stamp is the honest signal. Turn the VPN
off, or split-tunnel `*.kalshi.com`, and it recovers on its own; no relaunch needed.

**A finished game is still there with Live checked.** That's on purpose. Live means
started and not yet settled, so a game stays through *Final · awaiting settlement* with its
Won/Lost until Kalshi pays it out. For a late game that can be the next morning. Once
Kalshi settles it, it moves to the Settled tab.

**The menu bar is red and says "key".** Kalshi rejected your key: it was deleted on
Kalshi's site, or it lost *Read all data*. Disconnect, create a new key with only *Read all
data* checked, and connect again.

More in [docs/setup.md](docs/setup.md#troubleshooting).

## How refresh works

- Widget: WidgetKit decides when it updates; the app asks for every ~15 minutes and
  macOS usually honors it within a 15–30 minute window. When the app has refreshed
  within the last two minutes the widget reuses that data instead of calling Kalshi again.
- App: loads on launch and on ⌘R; positions, orders, prices and results then stream in
  over the WebSocket, with a full reload every 5 minutes (and 2 s after any push the app
  can't apply in place) as reconciliation.
- Menu bar and widget (macOS): read the same live snapshot; the widget cache is refreshed
  on every position/order/result change and at most once a minute for price ticks.

Each refresh makes 4–6 read-only calls: balance, positions, resting orders, a batched
market lookup, plus one event lookup per new event and one series lookup per new series
(cached after first sight; series never expire). If an event or series lookup fails, the
refresh is treated as failed and the last good snapshot stays on screen — positions are
never silently reclassified.

## Security notes

- Private key: Keychain (data-protection keychain on macOS),
  `AfterFirstUnlockThisDeviceOnly` — readable by the widget in the background, never
  included in backups or iCloud Keychain.
- Nothing is sent anywhere except Kalshi: `api.elections.kalshi.com` / `demo-api.kalshi.co`
  (REST) and `external-api-ws.kalshi.com` / `external-api-ws.demo.kalshi.co` (WebSocket),
  the hosts in Kalshi's own docs.
- No analytics, no crash reporting, no third-party dependencies.
- Kalshi's pre-sign text is `timestampMs + "GET" + path` with the query string stripped,
  per their docs. See `Shared/KalshiClient.swift`.

## Known gaps / verify against your account

- Order direction is read from Kalshi's canonical `outcome_side`/`book_side`, falling back
  to the deprecated `side`/`action` pair only when those are missing. If resting orders
  show wrong sides or prices, open an issue with one redacted order JSON.
- Event titles come from `GET /events/{ticker}`; for combo (MVE) markets the title may be
  generic.
- Unrealized P&L marks to the bid/ask midpoint (last trade when there is no book). Thin
  markets can make this jumpy; that's the market, not the math.
- "LIVE" comes from Kalshi's game record (`GET /milestones`): its start time, its end time, and
  its status when Kalshi has updated that in the last 15 minutes. Tennis statuses often go
  stale, so for those the start time decides, capped at six hours. A match running behind
  its scheduled time can light up a little early.
- "Realized" sums only markets you still hold; settled markets aren't included.

## Layout

```
project.yml        XcodeGen spec (app + widget, macOS); Team ID comes from untracked .team
scripts/           gen.sh (generate project), install-mac.sh (Release → /Applications), render-icon.swift
Shared/            Kalshi client, signing, Keychain, models, snapshot builder — compiled into both targets
App/               SwiftUI app: welcome, Connect wizard, positions list with sport filter, settings, menu bar
Widget/            WidgetKit extension: provider + views for every family
docs/              End-user docs (mirror of the wiki page)
```

## Releasing (maintainers)

`scripts/release.sh setup` once (Sparkle keys, notary credentials), then
`scripts/release.sh 0.5.0 --publish`: archive → Developer ID export → notarize → staple → dmg →
Sparkle signature → `appcast.xml` → git tag → GitHub Release. Details in the script header.

## Support the project

Spex Glance is free and MIT. If it saves you a browser tab, [Ko-fi](https://ko-fi.com/U4B527UPTU)
keeps the developer account paid.

## Disclaimer

Not affiliated with Kalshi. Informational only, not trading advice; data is relayed as-is and can be late or wrong. Full text: [DISCLAIMER.md](DISCLAIMER.md). Problem gambling help: 1-800-GAMBLER.

## License and third-party notices

Spex Glance is MIT licensed (see `LICENSE`): free to use, copy, modify and redistribute, and
provided **as-is, without warranty of any kind** — the authors are not liable for anything that
follows from using it, including stale or incorrect data relayed from Kalshi.

It bundles two open-source components; their full license texts ship inside the app
(`Acknowledgements.txt`, reachable from Settings → About → Third-party licenses):

| Component | Use | License |
|---|---|---|
| [Sparkle](https://sparkle-project.org) | in-app updates from GitHub Releases | MIT |
| [Space Grotesk](https://github.com/floriankarsten/space-grotesk) | display typeface | SIL Open Font License 1.1 |

XcodeGen is a build-time tool only and is not distributed with the app.

Not affiliated with or endorsed by Kalshi. Informational only; nothing here is trading advice.
If gambling is a problem for you or someone you know, call 1-800-GAMBLER.
