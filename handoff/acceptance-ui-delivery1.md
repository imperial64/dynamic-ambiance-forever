# In-game acceptance — UI delivery 1

> **Superseded for build 70009 (2026-09-25).** This checklist was written for build 69977,
> where the client wrote SavedVariables and never read them back. Build 70009 reads them back,
> and the addon now saves every edit in place (`design/ui/DESIGN-ui.md`, revision 2). Sections
> 9-11 below (Save to file, the recovery draft, the unsaved-zones popup) now appear only on a
> build where saving has regressed, or with `/amb persistence force unverified`. The
> current checklist is `design/ui/DESIGN-ui.md` 9.4. The rest stands as the record of the
> 2026-09-24 run.
>
> **Instruments removed (2026-09-25).** User decision, 2026-09-25: remove the probes
> completely; User decision, 2026-09-25: remove selftest and ambiancecost. `/amb selftest`
> (step 1), the `/acost` commands ("Also, while you are there") and the AmbianceCost addon no
> longer exist, and the install no longer puts AmbianceCost beside the addon; those lines are
> the record of what was run then.

design/ui/DESIGN-ui.md 9.4, adapted to what was built. Northshire, level-1 safe, with the
shipped test set. Each step names what your eyes should confirm. Any refusal, taint line or
Lua error is the interesting result: copy it verbatim.

Installed by `scripts/install-addon.ps1` to
`F:\World of Warcraft\_classic_beta_\Interface\AddOns\DynamicAmbiance` (and AmbianceCost
beside it).

**Two rules for this run.**

- **Run, then reload.** On build 69977, where this run happened, the client wrote
  SavedVariables at `/reload` and never read them back, and a reload replaced the file.
  Anything to be collected from the WTF file was collected after the reload that followed it.
  On 70009 the file is read back, so results survive; the client still writes it only at
  `/reload` or logout.
- **Do not re-run `install-addon.ps1` after pasting into Zones.lua** without first copying
  that Zones.lua back into the repo: the install copies the repo's Zones.lua over it.

What changed for you, in one line each:

- `/amb ui` opens the editor. `/amb ui save`, `/amb ui import`, `/amb ui corner` go
  straight to those.
- Gamma is a third axis, baseline **1.0**. If your client's Gamma is not 1.0, the addon
  will ease it to 1.0 wherever nothing sets gamma — step 1 tells you what yours is.
- Zones now live in `Zones.lua`, which the editor's Save to file writes for you.
  `Config.lua` keeps everything else.

---

## 1. Load, banner, self test

`/reload`.

- The banner reads `... baseline c=50 b=50 g=1. Client is at c=NN b=NN g=N.NN.` — **three**
  client values. If the `g=` is not 1.00, write it down; it goes into
  `Config.baseline.gamma` if you want the addon to hold your Gamma rather than 1.0.
- `/amb selftest` passes, and now includes `Gamma is writable`, `Gamma readback`,
  `Gamma restore`. Run it once out of combat and once in combat (a training dummy is
  fine) — that is the record that the third CVar may be written in combat.

## 2. The editor opens on Elwynn

`/amb ui`.

- The window titled **Dynamic Ambiance** opens on **Elwynn Forest**; the map art is
  visible on the left.
- Tabs top right: **Zones** live; **Settings**, **Themes**, **Share** greyed, with the
  tooltip "next delivery".
- The area list reads, top to bottom: `p60 Hall of Arms (by name) in`,
  `p50 All interiors (global rule) in`, `p20 chapel forecourt (circle) out`,
  `p10 Northshire Valley (by name)`.
- The chapel forecourt shows on the map as a filled circle with a fainter outer ring (the
  band). It ships already in yards (11.3 / 56.7), so its properties do **not** say "radii
  converted" — that line appears only for an area loaded in the old normalized units.
- The yellow dot is you.
- Look at the window as a whole: size, colours, fonts, the priority colours (blue 0-19,
  green 20-49, amber 50-59, red 60+). They are proposals; say what you would change. If
  your screen is smaller than 1360 x 780 the whole window is scaled down — say if that
  made it unusable.

## 3. The readout

Move the mouse over the map. The line under the map changes. Over the forecourt it reads
`wins here: chapel forecourt (p20) [outdoors] w=1.00`, and lists
`Northshire Valley (by name)` and the rules under "cannot be located on the map".

## 4. Draw a polygon

- Press **Polygon**. The properties panel shows **NEW POLYGON** with **Fade (yd)** already
  set to **5** ("past the edges"). Along the bottom of the map a strip reads
  `Left click: place a corner. Right click: remove the last corner. Click any corner to finish.`
- Click four corners **well around** the forecourt's outer ring (so part of the polygon is
  clear of the forecourt, which outranks it for now).
- Close it by clicking **any** corner you placed (not only the first), or Enter, or
  **Finish** — nothing asks for a number. Right-click removes the last corner while
  drawing; **Cancel** drops the shape.
- Fill, outline and band are visible. It is selected and named `area 4`.
- A new area inherits everything, so give it values: in its properties set Contrast about
  20 and Brightness about 90.
- Walk into it at a spot away from the forecourt ring: the screen eases to its values.
  Walk out through the band: gradual. `/amb debug` shows the target change.

## 5. Drag a corner

Select the polygon (**Select**, click inside it). Drag a corner handle: the fill re-draws
as you drag. Walk to the moved edge: the boundary has moved with it. Drag the body too.

## 6. Gamma

Standing inside the polygon, move its **Gamma** slider to something inside the "usable by
eye" marks (say 1.8): the screen changes. The slider runs 0.3 to 3.0 with ticks at 0.30,
1.00, 3.00 and two marks at 0.70 and 3.00. Tick **Inherit default**: it goes back.

## 7. Corner here — the unnamed pocket

Stand in the unnamed pocket (the purple one, where `/amb debug` shows no subzone). Press
**Polygon**, then walk its edge pressing **Corner here** (or `/amb ui corner`) four times.
`/amb here` in the pocket also offers "Corner here" while the polygon is being drawn.
Close it (the fade is already 5), give it the old values (Contrast 78, Brightness 18). Walk
out and in.

## 8. Priority

Set the step-4 polygon to 60 (type it, or the step buttons under the box: `+10` x5 from 10)
and the forecourt to 10 (`-10` from 20).
The list reorders; the readout's winner over the overlap changes; standing in the overlap
the screen follows the new winner.

Note: at 60 it now outranks the interior rule (50), so it also applies inside the chapel.
If that is wrong, set **Applies** to "outdoors only".

## 9. Save to file

*(69977. On 70009 this panel is shown only on a regressed build; the footer button reads
Export.)*

- Before saving: the footer says `N unsaved zones ...` and the title shows `*`.
- Press **Save to file**. A popup says `Your changes are not saved yet. Read the steps on
  the right of the editor to save them to file.` with **OK**; the steps are behind it. Read
  the text: it must say why the copy-paste exists and that it becomes automatic once
  Blizzard fixes saving. Say if any word should change.
- **Select all**, Ctrl+C. Open
  `F:\World of Warcraft\_classic_beta_\Interface\AddOns\DynamicAmbiance\Zones.lua`, replace
  everything, save. The unsaved count goes to 0.
- In the pasted text, Elwynn's `version` went from 1 to **2**. Press **Save to file**
  again without changing anything: the version stays 2.
- `/reload`. `/amb ui` shows the same shapes. Walk the pocket: it still works.
- Copy that Zones.lua back into the repo if you want to keep it.

## 10. Recovery draft

*(69977. On 70009 the draft is written only on a regressed build.)*

Make one change in the editor, do **not** save, `/reload`. Open
`F:\World of Warcraft\_classic_beta_\WTF\Account\<your account>\SavedVariables\DynamicAmbiance.lua`
— the **Account** folder, not `WTF\SavedVariables\` — and find `editor` → `draftLines`: one
quoted line per line of Zones.lua, including that change, with no `\"` inside them.

## 11. Closing with unsaved changes

*(69977. On 70009 this popup appears only on a regressed build, and its middle sentence
reads "Saving is not yet verified on this build - they may be lost at /reload.")*

Make a change, then close the window with its close button: a popup says
`You have 1 unsaved zone. They are lost at /reload. Open Save to file?` with **Save to
file** and **Close anyway**. Each does what it says.

Then press **Escape** with the window open. Escape-to-close is FrameXML behaviour and was
not measured: record whether it closed the window (and raised the same popup if there was
an unsaved change). If it did nothing, the close button still works.

## 12. Export and import a DA2 string

- **Save to file**, then the mode dropdown → `Preset string: Elwynn Forest`. The box now
  holds one `DA2~Elwynn Forest~...` line. **Select all**, Ctrl+C.
- `/amb ui import`, paste into the box, **Import**. The confirmation appears and the screen
  previews it live. **Decline** puts everything back.
- Import it again and choose **Import**: it replaces Elwynn.
- Paste some garbage and press Import: the reason is shown under the box.

## 13. Record the falloff

Done at the first run: **5 yards** ("default fade yard should be 5"). It is now
`Config.editor.defaultFadeYards`. If 5 looks wrong once you use it, say what does.

## 14. The review fixes (commit 7e8f92a)

- Type `nan` into the zone's Contrast box and press Enter: it is refused and the screen
  does not change. Same in the Priority box.
- Draw a polygon and give it **no** values: the list labels it "does nothing yet", and the
  Save panel names it. Its DA2 string imports back without an error.
- Open an import confirmation (step 12) and, while it is open, try to drag an area or press
  Save to file: the footer says "import preview open - accept or decline first" and nothing
  changes. Decline: your zone is exactly as before.
- **Named** tool outside a subzone: it refuses to add an empty name.
  `/amb ui named Northshire Valley` adds one by name from anywhere.
- Start a polygon, then pull a mob (or hit a training dummy): **WASD keeps working** in
  combat. Since feedback round 1 the window also hides for the fight (below); when it comes
  back, Enter/Escape shortcuts work again. The keyboard part is still built blind - it
  guesses how this client gates keyboard input in combat, so say exactly what happened.

## 15. Feedback round 1 — what to re-check

Your acceptance notes (`design/ui/feedback-1.md`), one line each. The steps above already
use the new behaviour; these are the checks for the changes themselves.

1. **Zoom and pan.** Mouse wheel over the map zooms about the cursor (fit to 4x). The `-`,
   `+` and `Reset` buttons at the map's top right do the same about the centre, with the
   zoom in % beside them. Zoomed in, drag the map with the left button: it moves, stops at
   the map's edge, and places nothing. Everything (fills, outlines, bands, handles, your dot)
   stays on the art, nothing spills outside the map area. Past about 2x the art may look
   soft; say if it is too soft to use.
2. **Close on any corner.** Draw 4 corners, then click corner 1 or 2: it closes as Finish
   does. With only 2 corners, clicking one says it needs 3.
3. **Hints.** The strip at the bottom of the map says what left and right click do while
   drawing a polygon, and how the circle works while drawing one.
4. **Edit polygon.** Select a polygon: small grey handles sit at the middle of each edge.
   Click one: a new corner appears there. Drag one: the new corner follows. Right-click a
   corner: it goes. At 3 corners it refuses and says why on the map; at 32 a midpoint
   refuses and says why. **Undo** takes each one back.
5. **Inherit default** is the checkbox's label beside every slider.
6. **Priority buttons** `-10 -5 -1 0 +1 +5 +10`: each adds; `0` sets 0. The typed box still
   works.
7. **Notes** (preset and area) are tall text areas; Enter makes a new line.
8. **Save to file** raises the popup (step 9).
9. **Recovery draft**: small print names the Account folder; `draftLines` as in step 10.
10. **Fade 5**: every new shape starts with Fade (yd) 5.
11. **Fade on top.** Circle tool: drag an inner radius, press **Finish** straight away — no
    error; the outer ring is 5 yd beyond the inner one. Select it: Fade (yd) shows 5; change
    Inner (yd) and the ring keeps its 5 yd. Type `-3` into Fade: the reason appears beside
    the box and in a popup with OK, and nothing changes.
12. **Combat hides the editor.** With a polygon half drawn, zoomed in, pull a mob: the window
    disappears and chat says why. After the fight it comes back with the same corners, tool
    and zoom, and you can keep clicking. `/amb ui` during the fight says it opens after.

## Also, while you are there (DESIGN-ui.md 9.3 and 11)

- `/acost areas` — the polygon section now has a second set of rows, "polygons in yards",
  beside the M8 rows.
- `/acost bench` — now has a `SetCVar Gamma new` row. Gamma is put back afterwards.
- With the editor open on this zone and **12 filled areas** drawn: `/acost editor`.
- Optional, for DESIGN-ui.md 8.3:
  `/run print(ChatFrame1EditBox:GetMaxLetters())` — why `/amb import` from chat is limited.

Then `/reload` and send `DynamicAmbiance.lua` and `AmbianceCost.lua` from the
SavedVariables folder.
