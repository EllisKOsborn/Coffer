# Coffer

A gold-per-hour tracker for **World of Warcraft: Forever**, in the style of Fojicore's
`Campfires` / `GPH` panel. Coffer tracks exactly where your gold comes from — raw loot,
quest hand-ins, vendor sales, and the estimated value of items still sitting in your
bags — and keeps a running history of your dungeon runs so you can see what's actually
worth farming.

## Features

- **Live gold/hour** computed from a session that persists across logout/relog (reset
  it manually with the `reset` button or `/coffer reset` whenever you want a clean read).
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

Copy (or symlink) this folder into your WoW `Interface/AddOns` directory so the addon
folder is named `Coffer`:

```bash
cp -r Coffer "/path/to/World of Warcraft/_retail_/Interface/AddOns/Coffer"
```

Then enable "Coffer" on the character-select AddOns screen.

## Usage

- `/coffer` — toggle the panel.
- `/coffer reset` — reset the current session's totals (run history is kept).
- `/coffer lock` / `/coffer unlock` — lock the panel in place so it stops being
  draggable.

## How values are classified

WoW doesn't tell addons *why* your money changed, so Coffer infers it:

- A `PLAYER_MONEY` increase right after `QUEST_TURNED_IN` → **quest** gold.
- A `PLAYER_MONEY` increase while the merchant window is open → **vendor** gold
  (selling junk).
- Any other increase → **loot** gold (mobs, chests, pickpocketing, etc.).
- Any decrease → **spent** (repairs, purchases, training, AH deposits, ...).

Item drops are parsed directly out of the item hyperlink in `CHAT_MSG_LOOT` (not the
surrounding sentence), so detection works regardless of client locale.

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
