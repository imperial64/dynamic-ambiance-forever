# Developing Dynamic Ambiance Forever

The developer and measurement record: how the addon was built, what was measured on the
client, and why the design is the way it is. The player-facing guide is the
[README](../README.md).

## Status history

Status: **working in game, verified 2026-09-20.** The addon is in
[`addons/DynamicAmbiance/`](../addons/DynamicAmbiance/). `/amb selftest` was run on build 69913
in Elwynn Forest and every check passed — the CVars carry no lock flags, a write reads back
exactly, a three-second ease of both of them from `OnUpdate` ran 809 frames at 270 fps with a
worst frame gap of 10 ms, nothing was refused, and everything was restored. The operator
confirmed the part no addon can check: the screen visibly changed, smoothly, with no flicker
or stutter. The record is archived at
[`measurements/selftest-2026-09-20.lua`](../measurements/selftest-2026-09-20.lua). (The self
test, and the other in-game instruments, were removed on 2026-09-25 by the user's decision;
the records they produced stay in `measurements/`.)

The same test was then run **in combat** and came back identical — writes are permitted
mid-fight on this client, so the ease no longer freezes. That was the last open question.
See [Using it](#using-it).

## The idea

Forever's new lighting looks markedly better at settings that are wrong for everywhere
else. A player who sets contrast 60 / brightness 40 for Duskwood's canopy then walks into
Westfall at noon and it is washed out. The manual fix is to keep opening the graphics
panel, which nobody does.

So: declare the values once per place, and let the addon ride the slider.

```
Duskwood            contrast 60  brightness 40     (zone default)
  Raven Hill        contrast 65  brightness 32     (darker still)
  Darkshire         contrast 55  brightness 48     (lit town, lift it)
Westfall            contrast 50  brightness 55
```

Crossing from Duskwood into Darkshire should not snap. It should take about a second, and
standing on the boundary should land somewhere between the two — not flicker between them.

## Using it

From a clone of this repository, on Windows:

```powershell
.\scripts\install-addon.ps1          # syntax-gates, then copies into _classic_beta_
```

Then `/reload` in game. It announces itself, says how many zones it has, and prints what the
client's `Brightness` and `Contrast` currently are — which is what you copy into
`Config.baseline` if 50/50 is not your neutral.

The full command list is in the [README](../README.md#commands).

**Authoring is `try` then `here`.** Stand somewhere, `/amb try` until the screen looks right,
then `/amb here` — it prints an entry carrying the values you settled on, and logs the same
thing to `DynamicAmbianceDB.captures` (the newest 20 are kept) so captures can be collected
from the file instead of retyped out of the chat log. Add the entry in the editor
(`/amb ui`), which saves every edit for the character. `Zones.lua` is read only on a
character's first login, as the seed its saved zones start from, so a paste there reaches an
existing character only on a build that has stopped reading saved settings back.

Layers come in three kinds, and each carries a `priority` — highest present wins, so they may
overlap deliberately. A **subzone** layer matches `GetSubZoneText()` by name and needs no
coordinates or map ID, so it is the one to reach for first; the ease is what stops its
boundary snapping. A **positional** layer is a centre and two radii in the map's normalized
0–1 space, for places with no subzone of their own — the Northshire pocket between the valley
and Elwynn proper is one, and it is why they exist. If the client hands back a different
`uiMapID` than the one recorded beside the coordinates, positional layers are skipped rather
than applied to the wrong space, and it says so. A layer with **neither** claims the whole
zone, which is what `Config.indoors` is.

Any layer can be tagged `indoors = true` or `false` to gate it to one side of a door. That
gate is not cosmetic: a building and the grass in front of it share a map coordinate, and the
client reports subzone names outdoors too, so it is the only thing that can tell them apart.

### Instance auto-toggles

The addon gets out of the way in group content. Five entries in `Config.settings.instances` —
`dungeon`, `raid`, `battleground`, `epicBattleground`, and `all` as a master that overrides
the four — and on means **suspend**: stop driving, ease back to `Config.baseline` for as long
as you are inside, then pick up again on the way out. It is a suspension and not a stop, so
the loop keeps running, both edges are smooth, and leaving needs no reload. An explicit
`/amb try` hold outranks it, because holding is something a person typed.

`epicBattleground` **cannot currently fire, and says so.** Separating an epic battleground
from an ordinary one needs `epicBattlegroundMinPlayers`, and that threshold is deliberately
`nil`: "epic battleground" is a retail bracket name and whether this client has the bracket
at all is unmeasured. Alterac Valley at 40 against Warsong Gulch at 10 is the obvious guess,
and guessing is what this repo does not do — assuming retail's behaviour has already been
wrong twice here. `/amb settings`, run inside a battleground, shows its `maxPlayers`; once
two different sizes have been seen, the threshold goes between them. Until then every battleground uses
`battleground`, which costs nothing while both default on, and `/amb settings` escalates its
warning the moment you set them differently.

### Sharing a preset

The player-facing description, the format and the example strings are in the
[README](../README.md#sharing-a-preset).

## Tests

```bash
luajit tests/run.lua     # or: lua tests/run.lua
```

204 cases and 3416 checks on 2026-09-25, passing on LuaJIT (Lua 5.1 semantics, which is what this client
runs) and on 5.4. [`tests/wow_stub.lua`](../tests/wow_stub.lua) stands in for the parts of the
client the addon touches, including the three failure modes known to bite here: a position
read that returns nothing, an event name that raises on registration, and a value that comes
back secret.

The suite covers the blend (inside, outside, the falloff band, two and three overlapping
areas, and that no step anywhere along a walk through them is large enough to see), priority
order including the chapel-stairway case that forced it, the indoor gate in both directions,
the ease, the write cap, the epsilon skip, restore-on-logout, and every slash command. It pins the combat
behaviour both ways: that the ease keeps running by default, and that setting
`freezeInCombat` back to `true` still freezes, so the escape hatch cannot rot. It also
asserts `evaluate` allocates nothing and that a zone with no positional areas never pays for
a position read.

**What it cannot tell you**, and what still needs a human in the world: that the screen
visibly changed, that the ease looks right rather than merely converging, and that the
example values in `Config.lua` are any good. The first two are for the operator's eyes. The
third is taste.

[`handoff/first-run-checklist.md`](../handoff/first-run-checklist.md) is the acceptance run.

## Measured 2026-09-18

Measured with `/fprobe video` and `/fprobe video ramp` on client 1.60.1 build 69913,
recorded as §P.22 in the plugin repo's `research/findings.md` and as the
`graphics-cvars-writable` restriction entry.

**The CVars are not called what retail calls them.** `gxBrightness`, `gxContrast` and
`gxGamma` are all **absent** on this client. Building on those names would have produced an
addon that silently did nothing. The real names, enumerated out of
`ConsoleGetAllCommands()`:

| CVar | Default | Scale |
|---|---|---|
| `Brightness` | 50 | **0–100** |
| `Contrast` | 50 | **0–100** |
| `Gamma` | 1.0 | centred on 1.0 |
| `HDRBrightness`, `HDRPeakBrightness`, `useHDRBrightness`, `useHDRPeakBrightness` | 203 / 400 / 0 / 0 | HDR path, not used here |

The 0–100 scale is the one the community already talks in — "contrast 60, brightness 40" is
literally `Contrast = 60`, `Brightness = 40`. Config values need no conversion.

**Writable, with no lock flags.** `GetCVarInfo` reports `isLockedFromUser`, `isSecure` and
`isReadOnly` all false. Writes land through both `C_CVar.SetCVar` and the undocumented
global `SetCVar`, identically, and read back exactly. No block or forbidden event.

**A write is a cheap live post-process.** This is what makes the ease possible. A
four-second sweep of `Brightness` 50 → 30 → 50, writing every frame from `OnUpdate`:

```
443 frames in 4.01s (111/s), 442 writes, 0 failures
frame gap min 8.0 ms, max 31.0 ms
```

442 writes cost nothing measurable, the frame rate never moved, and the screen changed
smoothly by eye. No device restart, no hitch.

**Windowed is fine.** Measured at `gxMaximize=1`, 1920x1080 — maximized windowed, not
exclusive fullscreen. The old "gamma is fullscreen-only" limitation does not apply here.

### Closed 2026-09-20: combat

This was the last open question, and it was worth not assuming — the same client already
surprised everyone by *allowing* `SecureActionButton:SetAttribute` in combat and
*forbidding* `UseAction` out of it, so its gating is not retail's.

`/amb selftest` was run mid-fight on build 69913. **Writes are permitted in combat here:**
1742 `SetCVar` calls while in combat, both CVars read back exactly and restored, no lock
flags, and no `ADDON_ACTION_BLOCKED` or `ADDON_ACTION_FORBIDDEN`. 871 frames in 3.00 s at
290 fps, worst frame gap 9 ms — indistinguishable from the out-of-combat run, which is the
point. Record:
[`measurements/selftest-combat-2026-09-20.lua`](../measurements/selftest-combat-2026-09-20.lua).

So `freezeInCombat` ships **off** and the ease runs through a fight. The freeze is still in
the code behind that flag, because a later build could start refusing.

## How it works

### Where am I

Two signals, coarse and fine.

- **Coarse, always available.** `ZONE_CHANGED`, `ZONE_CHANGED_INDOORS` and
  `ZONE_CHANGED_NEW_AREA` all exist, and `GetZoneText()` / `GetSubZoneText()` name the
  place. This alone gives per-zone and per-subzone values with no math, and it is the
  fallback path.
- **Fine, when the client gives it.** `C_Map.GetBestMapForUnit("player")` plus
  `C_Map.GetPlayerMapPosition(uiMapID, "player")` return normalized 0–1 coordinates on that
  map. Areas are defined in that space, so a config entry is portable and readable.

`GetPlayerMapPosition` returns a nilable position and is known to return nothing in
instances on retail. Every read is guarded and falls back to the subzone name.

### Layers, highest priority last

Every layer carries a **priority**. They are applied lowest first, each painting over what is
underneath by its own weight, so the highest-priority layer present wins and regions are free
to overlap:

```
nothing claims the spot          the baseline
approaching a positional layer   the nearer you are, the more of it applies
inside it                        its values, flat
a higher-priority layer on top   that one instead
...and tagged indoors            only while the client says you are inside
```

A layer's weight comes from whichever way it is defined. A **positional** layer carries a
centre, an inner radius and a falloff radius:

```
w = 1                                     inside inner radius
w = smoothstep(falloff → inner, distance) in the falloff band
w = 0                                     beyond falloff
```

A **named** layer — a subzone — is binary, 1 inside and 0 out, because the client reports the
name rather than a distance to it; the ease is what stops that boundary snapping. A layer
with neither claims the whole zone, which is what the indoors rule is.

There is still no explicit "transition between A and B" state. A partial weight fades over
*the result of everything below it*, not over the baseline, so a layer appearing on top of
another hands over smoothly rather than through some third value.

**Why priority rather than a weighted average.** The first version averaged every area with
`w > 0` over the zone default. It was symmetric and it was wrong in a way that only showed up
in game: on the Northshire chapel stairway the client reports the subzone `Northshire Valley`
while `IsIndoors()` is already true, so the named subzone — weight 1 — painted over the
indoors rule and the screen snapped back to outdoor values while still inside the building.
Averaging has no way to express "this one outranks that one". Priority does, and it is also
what lets regions overlap deliberately instead of accidentally.

What it gives up: two overlapping layers at the same priority no longer blend symmetrically.
The later one paints over the earlier one, and order in the file decides. That is the trade
priority buys.

The sort happens once per zone change and is cached on the zone; `evaluate` only walks the
list, and still allocates nothing.

### The ease

The weighted target is not applied directly. A single exponential approach runs on
`OnUpdate`:

```lua
current = current + (target - current) * (1 - math.exp(-rate * elapsed))
```

Frame-rate independent, and it smooths two different things at once: gradual movement
through a falloff band, and a hard subzone boundary that the coarse path reports as an
instant jump. Default around one second to settle.

The ramp measurement says a per-frame write is affordable, so this can run at full frame
rate rather than on a throttled timer. Writes are still skipped when the value has not
moved by more than a small epsilon, so a stationary player generates no CVar traffic.

## Measuring the cost

The ramp above proves a write does not spike a frame. It does not say what each piece costs,
and it says nothing about the position read, which runs whether or not the value moved.
`AmbianceCost` was a standalone addon in this repo that measured the three numbers that decide
the poll rate. It was removed on 2026-09-25 by the user's decision; the results below, its
records in `measurements/` and the handoffs in `handoff/` are what it left.

It reported, per preset:

1. **Microseconds per call**, loop overhead subtracted, for `GetBestMapForUnit`,
   `GetPlayerMapPosition`, the twelve-area weighted evaluation, the ease step, and a
   `SetCVar` write — each benched on its own frame so the measurement does not create the
   hitch it is looking for.
2. **Bytes allocated per position read.** If `GetPlayerMapPosition` returns an object rather
   than two numbers, polling every frame is GC pressure for a value that changes meaningfully
   a few times a second. This number is why the loop polls at 10 Hz and eases every frame.
3. **Frame-gap p50/p99/max** across three ten-second phases — `control` (no work), `naive`
   (poll every frame) and `tuned` (poll at 10 Hz, ease every frame) — so the cost shows up as
   a distribution rather than an average that hides hitches.

### Results 2026-09-18

Five runs on build 69913, 1920x1080, D3D12: low / medium / high at 119 fps (vsync), then two
uncapped. Per-call microseconds, loop overhead subtracted:

| Call | low | medium | high | high, uncapped | **low, uncapped** |
|---|---|---|---|---|---|
| `GetBestMapForUnit` | 0.62 | 0.62 | 0.64 | 0.62 | 0.61 |
| `GetPlayerMapPosition` | 4.42 | 5.71 | 5.37 | 4.49 | 4.38 |
| `readPos` (API call + unpack) | 4.91 | 5.94 | 7.51 | 7.91 | 5.11 |
| `evaluate`, 12 areas | 2.20 | 2.19 | 2.44 | 2.29 | 2.04 |
| ease step | 0.09 | 0.09 | 0.09 | 0.09 | 0.09 |
| `SetCVar`, new value | 0.81 | 0.82 | 0.81 | 0.82 | 0.79 |
| `SetCVar`, same value | 0.30 | 0.31 | 0.32 | 0.30 | 0.31 |
| bytes per position read | 1864 | 1864 | 1864 | 1864 | 1864 |
| **per frame, polling every frame** | **8.63** | **9.66** | **11.48** | **11.74** | **8.64** |

The worst case is the last column: low preset, every frame limit off, 274 fps, a 4.2 ms frame
budget. The per-frame work is **0.21% of a frame** there, and about **0.02%** on the tuned
path that polls at 10 Hz. Graphics quality does not move these numbers; frame rate does, and
only by shrinking the budget the same fixed cost is measured against.

**Write rate does not fall with frame rate.** Every run wrote 342-365 times in a ten second
phase - about 35/s - from 119 fps up to 238. Only the *share of frames* reaching a write fell,
29% to 17%, because there were more frames. Write rate is set by how fast the target moves
against `WRITE_EPSILON`, not by how often the loop runs, so the epsilon skip does not buy
anything at high frame rates. Capping the write rate explicitly would.

**The position read is the expensive call, not the write.** A write is 0.81 µs; reading the
player's position is 5 to 7.5 µs, six times more. The ramp measurement made the write look
like the thing to worry about and it is not.

### Allocation is the real constraint, and the write is most of it

CPU is settled: the whole loop is ~0.014% of a frame. Garbage is where the numbers are large
enough to design against. Measured with the collector stopped, 2000 calls each:

| Call | bytes |
|---|---|
| `SetCVar`, string value | 822 |
| `SetCVar`, numeric value | 827 |
| `C_Map.GetPlayerMapPosition` | 1864 |
| `("%.2f"):format(v)`, varying `v` | 38 |
| `UnitPosition` | **0** |
| `evaluate`, any area count | **0** |

The addon drives **two** CVars, Brightness and Contrast, so a write costs 822 bytes twice.
The poll is not doubled: `evaluate` returns both values from one pass. At the measured
~35 writes/s and a 10 Hz poll that is **~76 KB/s, about 268 MB per hour** - 57 from writes,
19 from position reads. Standing still it drops to the poll alone, ~19 KB/s.

Nothing here threatens frame time, but it is the one figure large enough to be worth reducing.

Three independent levers, all cheap (and see
[`handoff/audit-2026-09-18.md`](../handoff/audit-2026-09-18.md) - an independent audit found the
per-call CPU figures are measured with the collector running, so they are slight
overestimates; the allocation figures are unaffected):

- **Cap the write rate at 20-30/s.** Brightness steps faster than that are not visible, and
  this is the largest single reduction.
- **Raise `WRITE_EPSILON` from 0.25 to 0.5.** Imperceptible on a 0-100 scale, roughly halves
  write count on its own.
- **Read position with `UnitPosition` instead of `C_Map.GetPlayerMapPosition`.** It allocates
  nothing, which removes the remaining 18.6 KB/s outright and with it the reason for the
  10 Hz poll. The cost is coordinate space: world coordinates rather than normalized 0-1 map
  coordinates, so areas become less readable to author. A config decision, not a performance
  one.

Together those land around 16 KB/s.

**Passing a number to `SetCVar` does not avoid the allocation** - 827 bytes versus 822 for a
preformatted string. The conversion happens internally either way, and the Lua-side format
string is only 38 of those bytes.

Two earlier conclusions in this file were corrected by these numbers, which is worth noting
before trusting any single measurement here: the write looked cheap because only its frame
cost had been measured, and the position read looked like the dominant allocation because
only it had been measured.

**The frame-gap phases are not usable and the microbench is.** Two independent reasons, both
visible in the stored runs:

- Runs 1-3 were pinned at a ~119.9 fps cap with CPU headroom to spare. Work injected into a
  frame that is waiting on the cap moves the wall-clock gap by nothing, so those runs could
  not have shown an effect whatever its size.
- Every percentile comes back a whole number, so this client delivers `OnUpdate` deltas at
  1 ms granularity - a hundred times coarser than a 0.0086 ms effect.
- In the uncapped run the phases reported control 238.8 fps, naive 214.0, tuned 190.2. Tuned
  polls 22 times less often than naive for the same writes and cannot cost more, so that
  ordering is the machine drifting across the 30 second run, not the workload. The predicted
  cost of naive is half a frame per second; the phases reported twenty-five.

They are good for one thing, which is confirming no hitch: no phase in any run produced a
gap a player would feel. Anything finer has to come off the microbench.

Two known defects in those phases, if they are ever worth trusting: the first frames of a
phase are not discarded, so the control run carries a 72-136 ms max that flatters every
phase measured after it, and phases run once in sequence cannot separate drift from effect.
A warm-up discard and an A-B-A ordering would fix both.

**The frame-limit checkboxes do not zero their CVar.** `maxFPS` still reads 120 and
`targetFPS` 60 with both limits off; the enable flags are `useMaxFPS` and `useTargetFPS`,
paired with the slider value the way `useHDRBrightness` pairs with `HDRBrightness`. A run
that only records `maxFPS` cannot tell whether it was capped.

**Sweep frame rate, not image quality.** The cost here is main-thread Lua and does not care
about resolution or shadows. What the preset changes is frame rate, and low preset is the
worst case, not the best: the same fixed per-frame cost runs more often and against a smaller
budget, so low uncapped is the run that counts. The one thing the high preset genuinely tests is whether a write
gets more expensive when there is more post-process to reconfigure.

`Brightness` was snapshotted and restored at the end of every phase, on `PLAYER_LOGOUT`, and
from a `C_Timer` fallback if `OnUpdate` stalled mid-phase.

## Constraints inherited from the client

Measured on beta build 1.60.1.69893 (interface 16001) and recorded in the plugin repo's
`research/findings.md`.

- **SavedVariables are read back on build 1.60.1.70009**, account-wide and per character,
  across `/reload` and across a full exit and relaunch (the plugin repo's `research/findings.md`
  §P.30; this addon's own marker went load 5 → 6 across a relaunch,
  [`design/ui/measurements-2026-09-25.md`](../design/ui/measurements-2026-09-25.md)). On 69977
  nothing was read back, and on 69913 only the per-character file survived a `/reload`. What
  follows from 70009:
  - **A character's zones and settings live in its saved store**
    (`DynamicAmbianceCharDB.store`), and every edit in the editor, every `/amb set` and every
    ignore is saved in place. The client writes the file at `/reload` and at logout and
    nowhere else, so a crash loses the session's edits. `Zones.lua` is the seed a character's
    first login starts from; the installed copy, with anything pasted into it under the old
    copy-paste flow, is migrated on that login and nothing is redone.
  - **The addon binds its saved globals at `ADDON_LOADED` and only mutates them**, with no
    `## LoadSavedVariablesFirst`. Under the default load order every saved global is `nil`
    while the addon's files run, and the client replaces it with the restored table at
    `ADDON_LOADED` (§P.31). A file-scope `local db = SomeDB` would point at a table the client
    throws away. The plugin's linter checks for it.
  - **The addon checks at every login whether this build still reads them back**, because
    Blizzard has not announced the fix and §P.30 says nothing about later builds. `/amb status`
    prints what it found. If a later build stops reading them back, the addon says so at login
    and the editor brings back the old Save to file panel, with its copy-paste steps, until a
    build restores again.
  - **The player's neutral baseline must still be declared explicitly in `Config.lua`.** It
    cannot be captured at first login, because the addon is what wrote the value the client
    persisted. Getting this wrong means the addon slowly ratchets someone's brightness
    somewhere they never chose. `Brightness = 50`, `Contrast = 50` are the client defaults
    and the sane starting baseline.
  - `measurements/` holds archived copies of the SavedVariables files from each run. On 69977
    a reload before a run wrote an empty table over the last results, and that cost one
    dataset on 2026-09-18. On 70009 the results survive, but the archive stays the record.
- **An unknown event name raises and aborts the rest of the file.** Every `RegisterEvent`
  goes through a `pcall` wrapper.
- **`ReloadUI` is forbidden to addons.** Config changes need a human to type `/reload`.
- **Secret values survive `tostring()`.** Not expected to bite here — no unit data is read
  — but anything that comes out of the game goes through a `plain()`-style helper before it
  is printed or stored.
- **Always restore on the way out.** The CVar the addon writes is the one the client
  persists to `Config.wtf`. An addon that exits mid-ease leaves the player's screen where it
  put it.

### If you installed a SavedVariables workaround

Moved to the [README](../README.md#if-you-installed-a-savedvariables-workaround), since
it is for players.

## Relationship to forever-addon-dev

This repo is a **consumer** of the forever-addon-dev research repo and plugin (public; it was
`wow-addon-experimentation` before the rename), and its first outside-in dogfood test. The
boundary is one-directional:

```
here: hit an unknown about what the client permits
  →  plugin repo: add a probe test, measure it in game, record it in research/
  →  regenerate  →  here: pull the updated plugin and keep building
```

That loop has already run once: `/fprobe video` exists in the probe because this addon
needed an answer, and the answer now lives in the plugin's restriction list where every
future addon gets it for free. This repo never edits the API reference or the restriction
list. The plugin repo never learns that this addon is about lighting.

Two handoffs have gone the other way, and both are snapshots of what was offered rather than
records of what was accepted — classification and placement are that repo's call:

| | |
|---|---|
| [`handoff/forever-addon-dev-2026-09-18.md`](../handoff/forever-addon-dev-2026-09-18.md) | **Merged**, closed. Per-call costs, the frame-limit CVar trap |
| [`handoff/forever-addon-dev-2026-09-20.md`](../handoff/forever-addon-dev-2026-09-20.md) | **Ready to send.** Nine items, headed by writes being permitted in combat — which closes a caveat §P.22 states outright |

[`handoff/pending-forever-addon-dev.md`](../handoff/pending-forever-addon-dev.md) is the running
notes the second one was built from, now closed. Batching was worth it: one entry in it
reverses a conclusion from the first handoff, and the combat result did not exist when most of
it was written, so sending piecemeal would have meant retracting two thirds of it.

## Parked ideas

[`IDEAS.md`](../IDEAS.md) holds things worth doing that are not designed yet: an in-game
drawing UI for creating areas, driving `Gamma` as a third axis — possibly *instead* of
`Brightness`, which may make the interior problem disappear — and a group of sharing ideas:
import/export with a conflict prompt on overlapping areas, shift-clicking a preset to link it
in chat, and a public library to publish presets to. Nothing there is committed. The sharing
ideas were written when SavedVariables were write-only; build 70009 reads them back, which
lifts the part of each that was blocked on remembering anything.

The priority / inverse-area entry came off that list on 2026-09-20 and is now
[Layers, highest priority last](#layers-highest-priority-last). Its own closing note is why:
it said to check whether `IsIndoors()` exists before building geometry, because that would
make the expensive version unnecessary. It does, and it did.

## Not doing

- **Shaders, color grading, tinting the scene.** Addons cannot touch the renderer. This
  moves two sliders the player could have moved themselves.
- **HDR.** `HDRBrightness` and `HDRPeakBrightness` are writable too, but they are a
  different pipeline with different units (nits) and `useHDRBrightness` is 0 on the test
  machine. Out of scope until someone with an HDR display asks.
- **Per-time-of-day or per-weather values.** Possibly interesting later; it multiplies the
  config surface.
- **Auto-detecting good values.** The addon has no way to see the rendered frame. Values
  are authored by a human who looked at the screen.
