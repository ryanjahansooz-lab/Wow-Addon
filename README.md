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
- **Shard numbers**: every soul you capture gets a number that counts up over
  your character's whole life (#1, #2, ... #842). The number shows in the
  tooltip, the window and chat, and `/shards reset` never resets it.
- **Lucky numbers**: when a shard with a special number is made you /say it:
  - #69 or #420: *Nice*
  - #69420 or #42069: *Very Nice*
  - numbers ending in a run of the same digit: *Dubs!* (#77, #100),
    *Trips!* (#1333), *Quads!*, *Quints!*, *Sexts!*, *Septs!*, *Octs!*...
- **/say when a shard is consumed**: when a spell (Healthstone, Soulstone,
  summons, Shadowburn, Soul Fire...) uses up a shard you say, for example:
  *Soul Shard #42 consumed by Create Healthstone: the soul of Defias Pillager, taken in Westfall - The Molsen Farm.*
  Shards you delete, sell or trade aren't announced.
- **Chat message** when a soul is captured (turn it off with `/shards announce`).
- **`/shards` window** lists every shard you're carrying, newest first, with its
  soul, where it was taken, how long ago, and which bag slot it's in.
- Shards keep their soul when you move them between bag slots, bags, and the bank.
- Lifetime stats and a history of recent captures for each character.

### Options window, minimap button and tutorial
- **Open the options** by typing `/soulsource` or left-clicking the minimap
  button (it's also listed in the game's Interface/AddOns settings). Each
  setting has a checkbox, and you can hover one to see what it does:
  - Announce captured souls in chat
  - Show the soul in Soul Shard tooltips
  - /say when a shard is consumed
  - /say lucky shard numbers (Nice, Very Nice, Dubs!...): untick this to turn off just the lucky-number messages
  - Show the minimap button

  The window also has buttons for the shard list, the tutorial and resetting stats.
- **Minimap button**: left-click opens the options, right-click opens the shard
  list, and you can drag it around the edge of the minimap.
- **Tutorial**: a short walkthrough that pops up the first time you log in.
  Open it again from the options window or with `/shards tutorial`.

### Commands
| Command | What it does |
| --- | --- |
| `/soulsource` | Open the options window |
| `/shards` | Show or hide the Soul Shard window |
| `/shards tutorial` | Show the tutorial again |
| `/shards list` | Print every shard and its soul to chat |
| `/shards history` | Recently captured souls (and when each was used) |
| `/shards stats` | Your most-captured souls |
| `/shards announce` | Turn the capture chat message on or off |
| `/shards say` | Turn the /say message for consumed shards on or off (when off, only you see it) |
| `/shards lucky` | Turn the Nice / Very Nice / Dubs! messages on or off |
| `/shards reset` | Clear stats and history (shard numbering keeps going) |

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
- Outside dungeons and raids, the game only lets addons use /say when you
  press a key or click, so the message goes out on your next key press or
  click (usually right away). Inside instances it goes out immediately.
- Numbering starts when you install SoulSource; shards from before that have no number.
