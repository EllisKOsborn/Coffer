# Coffer

A gold-per-hour tracker for **World of Warcraft: Forever**, in the style of Fojicore's
`Campfires` / `GPH` panel. Coffer tracks exactly where your gold comes from — raw loot,
quest hand-ins, vendor sales, and the estimated value of items still sitting in your
bags — and keeps a running history of your dungeon runs so you can see what's actually
worth farming.

![Coffer panel preview](screenshots/panel-preview.png)

> This is a rendered mockup of the panel's actual layout and colors (built straight
> from `UI.lua`'s structure, not a photoshop), used here to preview the design before
> installing — **not** a live in-game screenshot. The real in-game font (Friz Quadrata)
> and exact pixel spacing will look slightly different; numbers shown are sample data.

## Features

- **Live gold/hour** computed from a session that persists across logout/relog (reset
  it manually by right-clicking the "This Session" header, or with `/coffer reset`,
  whenever you want a clean read).
- **Income broken out by source**: loot, quest rewards, and vendor sales are tracked
  separately under the hood (see `CofferDB.session`), with Earned/Spent/Total shown
  in the UI.
- **Item drops**, valued via TradeSkillMaster or Auctionator market data when either
  is installed, falling back automatically to vendor sell price for anything with no
  scanned auction data.
- **Recent Runs**: every 5-player dungeon you clear gets its own record — duration and
  net gold — built by watching instance entry/exit, so Stratholme, Blackmaw Hold, and
  the rest of Forever's new dungeons all show up automatically with no setup.

## Install

**Important:** World of Warcraft: Forever has its own, separate install folder —
`_forever_` — not `_retail_` or `_classic_era_`. An addon dropped into the wrong one
simply won't be seen by the client; there's no error, it just never loads.

Copy (or symlink) this folder into Forever's AddOns directory so the addon folder is
named exactly `Coffer`:

```bash
cp -r Coffer "/path/to/World of Warcraft/_forever_/Interface/AddOns/Coffer"
```

Then, at the character-select screen, click **AddOns** (bottom left) and make sure
**Coffer** is checked. If it's unchecked and labeled out of date, tick "Load out of
date AddOns" too (see the Compatibility note below).

If you downloaded the GitHub ZIP instead of using git, the extracted folder will be
named `Coffer-main` — rename it to `Coffer` before copying it in; the folder name has
to match the addon's `.toc` file exactly.

## Usage

- `/coffer` — toggle the panel.
- Right-click the **THIS SESSION** header (or `/coffer reset`) — reset the current
  session's totals (run history is kept).
- The gear icon in the panel's header (or `/coffer lock` / `/coffer unlock`) — lock the
  panel in place so it stops being draggable.
- `/coffer debug` — prints load/diagnostic info to chat (version, whether
  SavedVariables and the panel loaded, session/run counts). Useful whenever `/coffer`
  seems to do nothing — see Troubleshooting below.

## Troubleshooting "`/coffer` does nothing"

1. **Log in and watch the chat window.** On a successful load, Coffer prints
   `Coffer vX.X.X loaded. Type /coffer to open it...`. If you never see that line at
   all, the addon isn't loading — it's not a bug in the panel, something's stopping it
   from starting. Go to step 2.
2. **If it never loads:** open the AddOns list at character select and check:
   - The folder is `.../​_forever_/Interface/AddOns/Coffer/` (not `_retail_`, and not
     nested as `AddOns/Coffer/Coffer/` or left named `Coffer-main`).
   - "Coffer" is ticked in the list.
   - It isn't greyed out / flagged out of date — if it is, enable "Load out of date
     AddOns" (near the bottom of the AddOns list) and relog.
3. **If it does load** (you saw the chat message) **but `/coffer` still shows
   nothing:** run `/coffer debug` and send me what it prints — that tells us whether
   the panel frame is even being built, and we can go from there.

## How values are classified

Rather than inferring money sources from `PLAYER_MONEY` deltas and timing heuristics,
Coffer reads the dedicated event/argument each source actually provides (the same
technique production addons like [KiwiFarm](https://github.com/michaelnpsp/KiwiFarm)
use):

- **Loot gold** is parsed directly out of `CHAT_MSG_MONEY`, using Blizzard's own
  localized `GOLD_AMOUNT`/`SILVER_AMOUNT`/`COPPER_AMOUNT` message templates turned into
  Lua patterns - this event fires specifically for money looted, so there's no need to
  guess whether a balance change was loot.
- **Quest gold** comes straight from `QUEST_TURNED_IN`'s own `moneyReward` argument.
- **Vendor gold** and **spending** are the one case with no dedicated event: a
  `PLAYER_MONEY` increase while the merchant window is open is a sale, any decrease is
  spending (repairs, purchases, training, AH deposits, ...). By the time this handler
  runs, loot and quest gold are already accounted for above, so it only has these two
  cases left to classify - nothing is double-counted.

**Item drops** are matched against Blizzard's own localized `LOOT_ITEM_SELF` /
`LOOT_ITEM_SELF_MULTIPLE` / `LOOT_ITEM_PUSHED_SELF(_MULTIPLE)` chat templates (again,
turned into Lua patterns) rather than any item link appearing in `CHAT_MSG_LOOT`. Since
those templates are specifically the "You receive loot: ..." phrasing - distinct from
"PlayerName receives loot: ..." for other party/raid members - this only ever matches
your own loot, with no need to compare sender names or GUIDs against the player at all,
and no risk of ambiguity from World of Warcraft: Forever's two-part name system (every
character gets a Main Name *and* a Secondary Name).

## Testing without a WoW client

`tests/` runs every `.lua` file through [fengari](https://fengari.io) (a Lua VM
implemented in JS) outside the game: first a real syntax check on each file, then a
full simulated playthrough (load → `/coffer` → `/coffer debug` → loot an item → have a
party member loot something that must be ignored → turn in a quest → enter and leave a
dungeon) against a mock of the WoW API, asserting the tracked numbers come out right at
each step. It's not a substitute for actually playing with the addon loaded, but it
catches load-time syntax errors and broken control flow before they ever reach a real
client - which is exactly the kind of bug (a single invalid statement that silently
killed all of `UI.lua`) that shipped undetected for several versions before this
existed.

```bash
cd tests
npm install
npm test
```

## Compatibility note

This addon targets World of Warcraft: Forever (patch 1.60.x), which runs on the same
client as modern retail, so it uses the modern `Item` mixin and `C_AddOns` APIs. The
`## Interface` number in `Coffer.toc` is set from community reporting around launch;
if the game refuses to load the addon as "out of date," check your real interface
number in-game with `/run print(select(4, GetBuildInfo()))` and update the TOC.

## Known limitations / ideas for later

- If you log out mid-dungeon, that in-progress run's gold is still counted in your
  overall session total, but it won't appear as its own entry in Recent Runs (the run
  only gets recorded once you leave the instance normally).
- The Items and Recent Runs panels currently show the top 8 entries by value/recency;
  a scrollable "show all" view would be a natural follow-up.
- Raid support (10/25-man "party"→"raid" instance type) isn't tracked yet — only
  5-player dungeons.
