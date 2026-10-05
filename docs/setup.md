# Spex Glance — setup guide (wiki copy)

Who this is for: you already trade sports on Kalshi and you want your open bets visible
without opening the app. Non-sports positions are deliberately not shown. You have a Mac with Xcode. You can follow a short recipe.

Who this is not for: anyone who wants trading from a widget. This is read-only on purpose.

## 1. One-time build

1. `brew install xcodegen`
2. `git clone <this repo> && cd spex-glance`
3. `scripts/gen.sh` — enter your Team ID when asked (it's kept in an untracked `.team` file).
4. `open SpexGlance.xcodeproj`
5. Select the SpexGlance scheme → My Mac → Run.
   Or: `scripts/install-mac.sh` builds Release straight into /Applications.

If Xcode complains about signing: Signing & Capabilities → both targets → tick "Automatically manage signing" and pick your team. App Groups and Keychain Sharing are already declared; Xcode will register them on first build.

## 2. Connect (two minutes)

Kalshi offers no in-app sign-in for third-party apps, so this is a one-time manual step on
their website. Follow the in-app wizard. Short version:

1. Leave "Create the key on Kalshi" selected.
2. Open Kalshi (your browser) → Create New API Key → **Read only** → name it → save. Kalshi downloads a .txt with the private key (Ed25519 for new keys, RSA for older ones — both work). In the app: Open file… → pick it.
3. Copy the Key ID Kalshi shows (a UUID, not the long MC…/BEGIN… blob) → back in the app → Test → Finish.

## 3. Add the widget

Right-click the desktop → Edit Widgets → search "Spex" → pick a size. (The app must have
been launched at least once.) The menu bar item is there from first launch.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Widget says "Open Spex Glance to connect" after you connected | Both targets must sign with the same (paid) team so they share the keychain access group. On macOS a free Personal Team can't do App Groups at all. |
| Menu bar dot says "socket: …" | Kalshi rejected the price subscription (usually a settled ticker). It clears on the next 5-minute refresh. |
| Live dot is amber, "Ns behind" | Kalshi's messages are arriving late (their timestamps vs. your clock). Usually your network; also check your Mac's clock is set automatically. |
| Menu bar icon is ember or red | Kalshi is degraded ("slow") or down; open the dropdown for the reason. Numbers on screen are the last good ones. It clears on its own when Kalshi recovers. |
| Menu bar says "maint" | Kalshi is in a maintenance window (usually Thursday early morning ET). Nothing to do. |
| A fill or payout didn't show up right away | Position and order pushes fall back to the 5-minute refresh if Kalshi rejects those channels for your key. Prices still stream. |
| Footer says "Can't look up Kalshi's address — check your VPN or DNS", dot amber | A VPN or DNS filter is blocking Kalshi. Turn it off or split-tunnel `*.kalshi.com`. It clears on its own on the next refresh. "Live" may stay green meanwhile — an open socket needs no DNS — so trust the "Updated N min ago" stamp. |
| Menu bar red, says "key" | Kalshi rejected the key (deleted, or lost Read all data). Disconnect, make a new Read-only key, connect again. |
| A finished game stays with Live checked | By design: Live = started and not yet settled. It drops off when Kalshi pays it out and appears on the Settled tab. |
| 401 on Test connection | The Key ID doesn't belong to the private key you imported. Make sure you opened the .txt for *that* key. |
| A position you hold isn't listed | It's not a sports market. The footer says how many were skipped. |
| Widget stale for an hour | Normal WidgetKit budgeting. Open the app to force a refresh. Low Power Mode slows it further. |
| Sides/prices on resting orders look wrong | Kalshi order schema drift — see README "Known gaps". |

## Revoking access

App → Disconnect. Then Kalshi → Profile → API Keys → delete "Spex Glance". Both steps; the app can't delete the key on Kalshi for you (that would need write scope).
