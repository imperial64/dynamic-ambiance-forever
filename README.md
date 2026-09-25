# Dynamic Ambiance Forever

A World of Warcraft: Forever addon that sets your display **brightness**, **contrast** and
**gamma** from where you are standing. You choose the values once per zone, and per area
within a zone, and the addon eases between them as you move, so walking from Duskwood's
canopy into Westfall at noon no longer means opening the graphics panel.

```
Duskwood            contrast 60  brightness 40     (zone default)
  Raven Hill        contrast 65  brightness 32     (darker still)
  Darkshire         contrast 55  brightness 48     (lit town, lift it)
Westfall            contrast 50  brightness 55
```

Crossing a boundary takes about a second and never snaps or flickers. An area can be a whole
subzone by name, a circle or a polygon you draw on the map, and it can apply indoors only or
outdoors only. The addon steps back in dungeons, raids and battlegrounds, and it puts your
screen back to your normal settings when you log out.

## Requirements

- **WoW: Forever beta, build 1.60.1.70009 or later** (interface 16001). Earlier beta builds do
  not keep addon settings between sessions; see [Saving](#saving).
- No other addons or libraries.

## Install

1. Download `DynamicAmbiance-<version>-forever.zip` (for example
   `DynamicAmbiance-v0.3.0-forever.zip`) from the latest
   [GitHub Release](https://github.com/imperial64/dynamic-ambiance-forever/releases/latest).
2. Extract it into the game's `Interface\AddOns` folder (for the beta client, under
   `World of Warcraft\_classic_beta_`), so that you end up with
   `Interface\AddOns\DynamicAmbiance\DynamicAmbiance.toc`.
3. Start the game, or type `/reload` if it is already running.

The addon is also on [CurseForge](https://www.curseforge.com/wow/addons/dynamic-ambiance) and
[Wago](https://addons.wago.io/addons/dynamic-ambiance-forever), where the CurseForge and Wago
apps can install and update it.

## Quick start

1. Log in. The addon announces itself in chat. `/amb` shows what it is doing.
2. Stand somewhere that looks wrong and type `/amb try 60 40` (contrast, then brightness, and
   optionally gamma) until it looks right. `/amb auto` lets go again.
3. Type `/amb ui` to open the editor. Pick the zone, then draw an area on the map, or add a
   subzone by name, and give it the values you settled on. Every change is saved as you make
   it, and the screen previews it live.
4. Walk around. `/amb debug` prints one line per change, which is how you learn what the
   subzones along your route are called.

The addon ships with one example zone, **Elwynn Forest**, whose values are deliberately
exaggerated to show that the addon works. Change it or delete it in the editor.

The neutral values the addon returns to (contrast 50, brightness 50, gamma 1.0, the client
defaults) are set in `Config.lua` in the addon folder. If your own neutral is different, edit
`Config.baseline` there and `/reload`. `/amb status` prints what the client currently has.

## Commands

`/amb` and `/ambiance` are the same command.

| | |
|---|---|
| `/amb` | what it is doing: mode, zone, subzone, current → target, writes so far |
| `/amb ui` | the editor: draw areas on the map, saved as you go |
| `/amb ui export` | a zone's preset string to copy |
| `/amb ui import` | paste a preset too long for the chat box |
| `/amb here` | a paste-ready config entry for wherever you are standing |
| `/amb try 60 40 [gamma]` | hold contrast 60 / brightness 40 (and a gamma) so you can look at them |
| `/amb auto` | release a hold and follow the map again |
| `/amb on` / `/amb off` | `off` eases back to the baseline and then stops the loop entirely |
| `/amb reset` | snap to the baseline without stopping |
| `/amb config` | the zones and areas currently loaded |
| `/amb debug` | one line per change: zone, subzone, indoor flag, target |
| `/amb status` | the same as `/amb`; its last lines say whether this build keeps saved settings and whether Export could copy |
| `/amb settings` | the toggles, including the instance auto-toggles |
| `/amb set <key> on` | flip one; saved for this character (`/amb settings reset` goes back to `Config.lua`) |
| `/amb export [zone]` | a preset string for a zone, ready to paste |
| `/amb import <str>` | offer one to yourself, with the confirmation |
| `/amb ignore <name>` | or `all`, or `list`; `/amb unignore <name>` or `/amb unignore all` undoes it |
| `/amb help` | this list, in game |

### Instance auto-toggles

In dungeons, raids and battlegrounds the addon eases back to the baseline and picks up again
when you leave. Each kind is a toggle: `/amb settings` lists them, and for example
`/amb set dungeon off` keeps the addon running in dungeons. `/amb set all on` is a master
switch that suspends it in every instance; it is off by default. A `/amb try` hold outranks all of them.

## Saving

**Build 1.60.1.70009 keeps addon settings**, account-wide and per character, across
`/reload` and across a full exit and relaunch. On earlier beta builds it did not. So each
character's zones, areas and toggles are stored, and every edit in the editor, every
`/amb set` and every ignore is saved as you make it.

The client writes the file to disk at `/reload` and at logout and at no other time, so a
crash loses that session's edits.

Blizzard has not announced the fix, so the addon checks at every login whether the build
still keeps settings, and `/amb status` prints what it found. If a later build stops keeping
them, the addon says so at login, and the editor brings back a **Save to file** panel with
copy-paste steps until a build restores saving again.

### If you installed a SavedVariables workaround

While saving was broken, several workarounds circulated: the ForeverSVFix and WTFix tools,
the svshim watcher, a hand-added `.toc` line such as `SavedVariablesLink.lua` that lists a
SavedVariables file as addon code, and symbolic links or directory junctions from an addon
folder into `WTF`. If you used any of them for this addon, remove them on 70009 or later. The
client now restores `DynamicAmbianceDB` and `DynamicAmbianceCharDB` itself, so a workaround
becomes a second mechanism writing the same globals. Depending on the order, it either loads
the data a second time or overwrites what the client restored with an older copy.

That is **reasoning from the measured load order, not a measurement**. None of those tools
was tested with this addon or in the plugin repo. The removal steps are the plugin repo's
SavedVariables guide's, in short:

1. Remove the workaround addon or tool itself. Disabling it is not enough for a tool that
   edited other addons' `.toc` files. Stop any watcher process or scheduled task it
   installed.
2. Delete any leftover `.toc` line that lists a SavedVariables file, or a link to one, as
   addon code. Reinstalling this addon from a clean copy also removes them.
3. Remove symbolic links and junctions under `WTF` and `Interface\AddOns`. Remove the link
   itself, not the file it points at. In PowerShell, `Get-ChildItem` with
   `-Attributes ReparsePoint -Recurse` over those two folders lists them.

The addon cannot detect any of these tools, so it does not mention them in game.

## Sharing a preset

A preset is **one zone** — its defaults and all of its areas. `/amb export` prints a string,
`/amb import` takes one back, and the receiver gets a confirmation showing the values before
anything is applied. Nothing a sender offers is written without a human saying yes. The
editor's **Export** and **Import** buttons do the same, and take strings too long for the chat
box.

The format is plain text rather than compressed base64:

```
DA2~Duskwood~60~40~~~m:My Duskwood:::1::2026-09-25~s:Raven Hill:10:65:32::::~s:Darkshire:10:55:48::::~e334
```

That is the Duskwood from the top of this page: the zone at 60 / 40, Raven Hill and
Darkshire as subzone layers, and a name and version. Neither layer is positional, so there is
no map ID.

Readable, greppable, pasteable into a forum post as-is, and cheap on a Lua 5.1 interpreter
with no `string.buffer`. A Fletcher-16 checksum catches the real failure mode, which is a
paste that lost its tail to a chat line limit. It is not security — the confirmation is.

The confirmation **previews live**: the sender's values go on the screen while the dialog is
open and come back off on decline, on timeout, on escape and at logout. A contrast number
read off a dialog tells you nothing, and trying someone's Duskwood on the spot is most of the
point. That is only defensible because of what these CVars are. Three buttons — Import,
Never from them, Decline — so the per-player ignore lives where the annoyance is.

**Sending to party and raid is not wired up yet, on purpose.** Whether this client has
addon-to-addon messaging at all is unmeasured, and the transport gets built against a
measurement rather than a guess. `/amb share` says exactly that rather than failing quietly.
Everything above already works on a preset that arrived by any route, so the wire plugs in
without reopening any of it.

An accepted preset is saved for the character, and the string it arrived as becomes that
zone's revert point. The accept line says so, or, on a build where the addon has not yet
seen saved settings come back, says that instead — see [Saving](#saving).

The shipped Northshire example set, as a preset string. `Zones.lua` seeds only a character's
first login, so this is how an existing character gets the set (or a later fix to it). Its
values are deliberately exaggerated; it proves the addon reacts and is not for keeping:

```
DA2~Elwynn Forest~35~78~~1429~m:Elwynn, Northshire test set:Proves the addon reacts. Not for looking good.:VALUES ARE DELIBERATELY EXAGGERATED - this set proves the addon reacts; nobody should keep these. Yellow%3A Elwynn proper (the zone default). Blue%3A Northshire Valley. Red%3A every interior, by Config.indoors. EVERY NAME HERE WAS WALKED, not guessed%3A /amb debug on 2026-09-20 returned Northshire Valley, Main Hall, Hall of Arms, Main Hall, Northshire Valley, nil, Northshire Valley. The nil is the unnamed pocket (purple)%3A no subzone, so it needs a polygon walked in the editor. Map 1429 is measured.:1::2026-09-24~s:Northshire Valley:10:55:45::::BLUE. Measured subzone name, from two selftest runs.~s:Hall of Arms:60:70:58::1::A room that differs from the indoor rule and outranks it. Gated indoors, so it cannot fire over the same spot outside.~c:chapel forecourt:0.492:0.4143:11.3:56.7:20:85:25::0:Centre%3A mean of three /amb here captures in the chapel, 2026-09-20. RADII ARE A GUESS - 0.0040/0.0200 normalized, converted to yards by the geometric mean. Outdoors only.~f822
```

## Credit

The idea is **Fabqt**'s. She posted about changing contrast and brightness per zone and per
area within a zone — <https://x.com/fabqt/status/2100967616080740707> — and this addon exists
to do that automatically. (2026-09-18).

## Support

The addon is free. If it made Duskwood look the way it should, you can
[buy me a coffee](https://buymeacoffee.com/imperial64).

## License

[MIT](LICENSE), © 2026 imperial64.

## For developers

[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) is the developer and measurement record: how the
engine works (layers, priority, the ease), what was measured on the client and how, the test
suite (`lua tests/run.lua`), installing from a clone with `scripts/install-addon.ps1`, and the
relationship to the forever-addon-dev research repo. [`CHANGELOG.md`](CHANGELOG.md) lists
the releases, [`RELEASING.md`](RELEASING.md) is how a release is cut, and
[`IDEAS.md`](IDEAS.md) holds parked ideas. `design/`, `handoff/` and `measurements/` hold the
design documents, the handoffs and the raw in-game records.
