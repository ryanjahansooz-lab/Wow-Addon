# Wow-Addon
World of warcraft forever addons

## SoulSource (Warlock)

Remembers **whose soul is inside each Soul Shard**. When your Drain Soul kills
something and a Soul Shard appears, SoulSource records the victim and shows it
in the game.

### Features
- **Shard tooltips**: hover a Soul Shard in your bags or bank to see
  *Soul of Defias Pillager · Level 17 Elite Humanoid · Westfall - The Molsen Farm · Captured 12m ago*.
  Players you drain show up in their class color with race and class.
- **Chat message** when a soul is captured (turn it off with `/shards announce`).
- **`/shards` window** lists every shard you're carrying, newest first, with its
  soul, where it was taken, how long ago, and which bag slot it's in.
- Shards keep their soul when you move them between bag slots, bags, and the bank.
- Lifetime stats and a history of recent captures for each character.

### Commands
| Command | What it does |
| --- | --- |
| `/shards` | Show or hide the Soul Shard window |
| `/shards list` | Print every shard and its soul to chat |
| `/shards history` | Recently captured souls (and when each was used) |
| `/shards stats` | Your most-captured souls |
| `/shards announce` | Turn the capture chat message on or off |
| `/shards reset` | Clear stats and history |

### Install
Copy the `SoulSource` folder into `World of Warcraft/_classic_era_/Interface/AddOns/`
(or the AddOns folder of the client you play), then restart the game or `/reload`.

### Notes
- Built for the Classic client (Interface 11507). If the game says the addon
  is out of date, tick **Load out of date AddOns** or change the `## Interface:`
  line in `SoulSource.toc` to match your client.
- Shards you already had before installing are marked as *unknown soul*.
- Shards don't stack, so each one is tracked by its bag slot. If you swap two
  shards directly onto each other, their souls stay in the old slots.
- Bank shards are checked only while the bank is open.
