# One-stop UI - design interview, round 1 (2026-09-24)

This is not a design. It is the set of decisions the user has to make before one can be
written, each with a recommended default, plus what the designer will decide alone, and
what has to be measured in game first.

**How to read the labels.** Every statement below is tagged so nothing here can be mistaken
for something it is not:

| Label | Meaning |
|---|---|
| **Authority** | Repository-confirmed: README, DESIGN-settings-and-sharing.md, Config.lua, or a measured finding in the forever-addon-dev research repo's `research\findings.md` (cited by section) |
| **User decision, not canonicalized** | Something the user said in `design/ui/scope.md` that no canonical document yet carries |
| **Proposal** | The designer's recommendation. Not decided until the user says so |
| **Example** | Illustrative only; not a spec |
| **Open** | Needs a measurement or an answer; the design will branch on it |
| **TBD** | Deliberately left unset; no value has been invented for it |

Each question is written to be put to the user unchanged, one at a time, so each repeats the
context it needs. Options are concrete; the recommendation is listed first; every list ends
with `Something else`.

---

## Facts the design will rest on

**Authority.** The engine's model is *layers with priorities*, not shapes. A layer is one of:
a named subzone (weight 1 inside / 0 outside), a positional circle (centre, inner radius,
falloff radius, smoothstep band, in the map's normalized 0-1 space on a recorded `uiMapID`),
or a whole-zone rule (which is what `Config.indoors` is). Any layer may be gated
`indoors = true` / `false` / unset. `evaluate` walks a per-zone sorted layer list, costs
about 0.17 microseconds per area, and allocates nothing. (README, "Layers, highest priority
last"; "Measuring the cost"; Config.lua header.)

**Authority.** A shared preset is **one game zone**: its default values and all of its
areas. Format `DA1~zone~c~b~map~<areas>~checksum`, plain text, Fletcher-16, caps of 64 areas
/ 4096 bytes / 64-character names. Import raises a confirmation with live preview and three
buttons; nothing is applied without a human saying yes; an accept **replaces the whole
zone**. (DESIGN-settings-and-sharing.md sections 2 and 4; Preset.lua; Share.lua.)

**Authority.** Persistence, as measured on build 69913 (plugin repo, findings.md P.23 and
P.27, and `reference/guides/savedvariables.md`):

| Across | account-wide `## SavedVariables` | per-character `## SavedVariablesPerCharacter` |
|---|---|---|
| `/reload` inside one client run | not restored | **restored** |
| full client exit and restart | not restored | **not restored** |

The plugin repo's summary is: "there is no persistence across sessions, but `/reload` is
survivable." The account-wide failure is tracked as forever-bugs#34, open, no Blizzard
reply, so it carries an expiry - any build could fix it.

**Discrepancy to surface, not resolve here.** `design/ui/scope.md` records "per-character
read-back appears to work", from a 13:48 login / 13:51 reload / 14:13 logout sequence on
2026-09-21. That evidence is consistent with P.27 (the marker crossed a `/reload`) and does
not test a cold restart. The scoping answer "edit and save in place if per-character read-back
holds" was therefore given against a broader reading than the measurement supports. The
design below branches on all three outcomes (restart-persistent / reload-only / none) and
the fixed probe's cold-restart run decides which branch is live at ship time. See
measurement M1.

**Authority.** The client contradicts retail. Retail CVar names are absent; `SetAttribute`
is allowed in combat while `UseAction` is not; an unknown event name raises and aborts the
rest of the file; `ReloadUI` is forbidden to addons; `tostring()` does not launder a secret.
Nothing about Blizzard's *FrameXML* layer (WorldMapFrame, UIParent, font objects,
BackdropTemplate, ColorPickerFrame, the Settings panel, dropdown and scroll templates) has
been measured on this client. The generated API reference covers C-side functions and the
widget method surface (Frame:CreateLine, Texture:SetColorTexture, Texture:SetGradient,
EditBox:SetMultiLine / HighlightText / SetMaxLetters, FontString:SetFont, C_Map map-art
calls, C_Texture.GetAtlasExists all exist in the documentation) but its global dump lists
functions only, so **every named frame or mixin is Open** until measured. The measurements
section lists them precisely.

**User decision, not canonicalized** (scope.md): the UI lives in game; corners are drawn on
the game's world map at real coordinates; import/export are copy-paste strings; no desktop
companion; the party/raid wire stays out until the probe answers addon messaging.

**Authority.** Version 0.1.0 in the `.toc`; the README describes one operator's machine and
no distribution. *Assumption, flagged:* there is no installed base running the DA1 format
other than the author. If that is wrong, Q6's compatibility note changes.

---

## Questions for the user

### Q1. What is the thing you create, name and share - a shape, or a zone's bundle of shapes?

**Context.** The addon has two levels. The game's *zone* is Duskwood or Elwynn Forest; the
addon cannot rename those, they are the keys it matches on. Inside a zone are the pieces
that carry your values: a shape you draw, a named subzone like Raven Hill, or the
one-rule-for-every-building indoors layer. Today what gets shared is the whole zone bundle -
"here is my Duskwood" - with all its pieces, and a receiver who already has a Duskwood is
asked whether to replace it. Your request says to draw a shape, then name it, describe it,
write notes and give it a version number, and that "zones" should be shareable. Those words
fit either level, and the answer decides what a name, a version and an export string are
attached to.

**Options**

1. **(Recommended)** A drawn shape is an *area*. A game zone's default values plus all of
   its areas is a *preset*. Name, description, notes, version and author live on the preset;
   every area also has its own short name and notes. What you share is a preset - and
   sharing a single area is simply a preset that contains one area, so "send just my
   Darkshire square" works with the same format and the same confirmation.
2. Every drawn shape is its own standalone thing carrying the full name / description /
   notes / version, and that is what gets shared. There is no bundle; a receiver collects
   shapes one at a time.
3. Both levels are first-class: a bundle has its own metadata and a shape has its own, with
   two different kinds of export string.
4. Something else.

**Why the recommendation.** It matches what is already built and measured (one zone, one
conflict story), it keeps one format and one validator, and it still gives you single-shape
sharing for free. Option 2 makes "my Duskwood" a dozen strings; option 3 doubles the format
surface for a distinction the receiver rarely cares about.

---

### Q2. Anything you draw is lost when you quit the game unless it reaches Config.lua. Build now with that, or wait?

**Context.** You said the UI should edit and save in place *if* per-character saving holds.
Here is what was measured on this client (2026-09-20, build 69913): the game **never reads
back** the account-wide saved-settings file, and it reads the per-character one back **only
across `/reload`, not across quitting and relaunching**. So today: everything you draw
survives reloads inside one play session and is gone the next time you start the game -
unless it is copied into the addon's `Config.lua` file, which the game does read at startup.
Blizzard has an open bug report about this; a later client build may fix it, with no date.

**Options**

1. **(Recommended)** Build it now, honestly. The UI is a live editor for the session. A
   "Save to file" panel shows a paste-ready block for `Config.lua` (and preset strings), you
   select-all, copy, paste it in, and it is there next launch. The addon checks at every
   login whether saving works on that build and labels things "Saved" or "This session only"
   accordingly, so if Blizzard fixes the bug the same UI becomes a true editor with nothing
   redesigned.
2. Option 1 plus a small script you run outside the game between sessions, which lifts what
   the UI wrote into the saved-settings file (the game does *write* it) into `Config.lua`
   automatically - no copy-paste. It is out-of-game and you chose in-game only, so it would
   be strictly opt-in and could come later.
3. Wait for Blizzard to fix saving before building any of it. Nothing in the request -
   editor, settings tab, theme choice - can remember itself across a restart until then.
4. Something else.

**Why the recommendation.** The addon already works this way (`/amb here` prints an entry to
paste, and every import says "this lasts until /reload"), so option 1 removes the typing of
coordinates without promising what the client cannot deliver. Option 3 blocks on a date
nobody has.

---

### Q3. Where do you draw - in a dedicated editor window with its own copy of the zone map, or on the game's world map itself?

**Context.** Both draw at real map coordinates, so a shape made either way is identical.
They differ in what is on screen while you work. A dedicated window can show the zone map on
one side and the list of areas with their values on the other, and can show *any* zone's
map, not only the one you are standing in. Drawing on the game's own world map (the M key)
means an "Edit areas" mode with a toolbar and a side panel next to Blizzard's map. Note: the
dedicated window depends on the game letting an addon display the zone map's artwork; the
function for that exists in this client's documentation but has not been tried. If it does
not render, the world-map overlay is the fallback either way.

**Options**

1. **(Recommended)** A dedicated editor window: zone map drawn from the game's own map art
   on the left, areas and their values on the right, browse any zone. Falls back to option 2
   if the map art cannot be drawn.
2. An overlay on the game's world map: open the map, toggle "Edit areas", draw on it, values
   in a panel docked beside the map.
3. Both: draw wherever the map is open, one shared side panel.
4. Something else.

**Why the recommendation.** The world map on this client is an unmeasured Blizzard frame
(size, maximize behaviour, quest panels, ping handling), and an editor built on top of it
inherits every one of those unknowns. A window the addon owns is a fixed surface that can be
laid out for editing. Option 3 is two editors to keep consistent.

---

### Q4. Themes: how far should theme-making go in this round?

**Context.** A theme would set the colours (panel, border, text, one accent, and the colour
each priority band gets on the map), the font (from whatever fonts this client is measured
to have), and the frame style. Two ship: **Classic / Forever** - the game's own dialog
artwork and the same font the default UI uses, so it looks like it came with the game - and
**Modern** - flat dark panels, thin one-pixel borders, one accent colour, no ornament (the
designer's proposal; you correct the look at review). A theme can be exported as a text
string and imported from one, the same way presets are.

**Options**

1. **(Recommended)** A theme picker plus import/export strings. The string is readable
   `key=value` text, so anyone can make a new theme by editing the text of an exported one.
   No colour-picker screen in game this round.
2. Option 1 plus a "Customize" panel in game with colour pickers and a font choice that saves
   as a new theme. (Depends on the game's colour picker being usable by addons here - not yet
   measured.)
3. Only the two built-in themes. Still exportable as strings, but no third theme.
4. Something else.

**Why the recommendation.** It delivers the two themes and the sharing you asked for, and it
puts the colour-picker screen - which needs its own measurements and its own layout - in a
later round without blocking this one.

---

### Q5. The share format is changing anyway. Should it carry Gamma now, before there is a Gamma slider?

**Context.** The addon drives two sliders, Contrast and Brightness, both 0-100. Fabqt's
observation (recorded in IDEAS.md) is that lowering **Gamma** may be the better lever,
because it keeps interiors readable where lowering Brightness makes them too dark. Gamma is
present and writable on this client but its useful range has not been measured, so a slider
for it would be guessing. The share format must grow regardless (polygons and the new
metadata), and a value added to the format *later* means every preset anyone has shared
needs converting.

**Options**

1. **(Recommended)** Reserve Gamma now: the format and the editor's data carry an optional
   third value per zone and per area, "not set" meaning "leave Gamma alone". No slider is
   shown until its range has been measured. Presets made now never need converting.
2. Add the slider now as well, measuring the sensible range first.
3. Leave Gamma out entirely; convert presets later if it is ever added.
4. Something else.

---

### Q6. When someone sends you a zone you already have, what choices should the confirmation offer?

**Context.** Today the confirmation is a small game popup with three buttons: Import,
Decline, Never from this player - and Import **replaces your whole zone** with theirs,
after a warning listing which of your areas overlap. With a proper window instead of the
popup, more choices fit. Overlapping areas are legitimate in this addon: layers coexist and
the higher priority wins, so keeping both is a real answer, not a compromise.

**Options**

1. **(Recommended)** Two ways to accept: **Replace mine** (as today) and **Add alongside
   mine** (their areas join yours as extra layers; if a name clashes, theirs gets the
   sender's name appended; your zone default values stay yours). Plus Decline and Never from
   them, as today. The preset's version is shown as newer / older / same as yours, and never
   replaces anything on its own.
2. Replace only, as today, but in the new window.
3. A full per-area merge: for each overlapping area, choose keep mine or take theirs.
4. Something else.

**Why the recommendation.** IDEAS.md idea 1 named keep-both as the interesting merge and the
one this engine can honour. Option 3 is a real merge UI and its own project.

---

### Q7. What does "version number" mean to you?

**Context.** You asked for a version number on what you create. It will be shown in the
export string and in the receiver's confirmation ("newer than yours" / "older" / "same"),
and never used to replace anything automatically.

**Options**

1. **(Recommended)** A whole number the UI raises by one each time you save a change to the
   preset, and which you can type over. Nothing to remember, and two copies with different
   numbers are always distinguishable.
2. Free text you type yourself - "1.2", "beta 3" - shown as-is; the addon cannot say which
   of two is newer.
3. No manual number: a date-and-time stamp taken automatically on each save.
4. Something else.

---

### Q8. If it has to arrive in pieces, which piece first?

**Context.** The request is several features: the drawing editor with polygon shapes and the
new format; the settings tab; the two themes and theme strings; the import/export window
with the merge choices. Each can be built and used on its own, and the slash commands keep
working throughout. Building them in an order means you get something usable sooner and
each piece can be corrected before the next is built on it.

**Options**

1. **(Recommended)** First the new format, polygon support in the engine, and the editor
   window (Q3) with live preview and the Save-to-file panel. Second the settings tab. Third
   the two themes and theme strings. Fourth the import/export window with Q6's choices.
2. Settings tab and themes first (fast and visible), the editor after.
3. Everything in one delivery.
4. Something else.

**Why the recommendation.** The editor is the part with the most unknowns (map art, drawing
primitives, clipboard) and the most measurements, so starting it first surfaces what the
client refuses while the rest is still cheap to change. The format has to come first
regardless, because everything else stores into it.

---

## Decided by the designer (not put to the user)

Each with the one-line reason. Any of these can be reopened at review.

- **Vocabulary.** *Zone* is the game's zone; *area* is one layer of any kind (polygon,
  circle, named subzone, whole-zone rule); *preset* is the shareable bundle. Matches the
  engine and every existing document, and avoids the word "zone" meaning two things.
- **Polygon weight.** Inside the polygon, weight 1; outside, smoothstep over a single
  `falloff` distance measured to the nearest edge; beyond it, 0. Point-in-polygon by ray
  casting. Both walk the corner list once with no allocation, so the shape of the cost is
  known; the number is measured (M8) before the corner cap is set. Corner cap: **TBD** from
  that measurement.
- **Circles stay.** Existing positional circles remain valid, editable (centre and two radius
  handles), and the circle tool stays: a pocket is one click and a radius. Removing them
  would break every DA1 string and the one live positional layer in Config.lua.
- **Corner placement is both ways.** Click on the map, and "drop a corner where I stand".
  A corner is one x,y either way, and Config.lua's own note records that the Northshire
  pocket could not be placed from a picture of the map.
- **Coordinates stay normalized 0-1 on the zone's `uiMapID`,** exactly as circles are.
  `C_Map.GetMapWorldSize` (documented; M6) is used only to *display* a radius in yards, if it
  returns numbers.
- **Priority is a number,** shown with the existing bands (10 zone feature, 50 indoors, 60
  room) as hints, and the map renders the stack: fill per priority, the winner under the
  cursor read out. IDEAS.md idea 3 says rendering the stack is part of the feature, not
  polish.
- **Indoors is tri-state in the UI:** "anywhere / indoors only / outdoors only", which is the
  engine's unset / true / false. The request said true-or-false; the engine has three states
  and hiding the third would make the whole-zone indoors rule unauthorable.
- **Editing previews live** by the same zone-table swap Share.lua uses, and says so when you
  are not in the zone being edited. Presets are judged by eye; that principle is already
  canonical.
- **Format: DA2.** Import accepts DA1 and DA2; export writes DA2 only (see the flagged
  assumption about the installed base). DA2 adds a polygon area kind and a metadata header
  (name, description, notes, version, author, date); escaping and Fletcher-16 unchanged.
  The 4096-byte cap and the 64-area cap are **TBD** pending M5 (what can actually be pasted).
- **Theme strings** use the same escaping and checksum family under their own marker. A
  theme is named colour slots, a font choice from the measured set, and a style token. The
  Classic theme reads the default UI's font from a live font object at runtime (M4) rather
  than hardcoding a file path the client may not have.
- **The settings tab covers everything:** the five instance toggles, sharing accept /
  preview / ignore list, the baseline, and the global indoors rule (edited as a special area).
  **Tuning belongs in the UI, under a collapsed "Advanced"**: `easeRate` is a genuine
  preference; `pollHz`, `writeHz`, `writeEpsilon`, `freezeInCombat` are shown with their
  measured defaults, the reason each default is what it is, and a reset. `epicBattleground
  MinPlayers` is read-only with the `/amb probe coverage` hint until it is measured, because
  a value here would be a guess. The baseline is the one setting every user must change
  today by editing a file, which is the strongest case for the tab at all.
- **Config.lua stays the shipped set;** UI-authored data is a per-character overlay keyed by
  zone name for as long as the client keeps it; the Save-to-file panel emits the *merged*
  result so Config.lua remains the single file a person maintains. Which of the three
  persistence branches is live is detected at login (M1), never assumed.
- **Author stamp** is the character name plus normalized realm, taken from the client; it is
  already the provenance the chat link shows.
- **Opening the UI:** `/amb ui`, plus an entry in the game's AddOns options panel *if* the
  registration API exists here (M7). No minimap button this round.
- **Import and export use edit boxes,** not chat lines: paste into a box, copy from a
  select-all box. `/amb import` and `/amb export` keep working.
- **Out of scope, per scope.md:** the party/raid wire, a desktop companion.
- **Undo, keyboard shortcuts, snapping, corner limits per drag:** TBD in the design proper.

---

## Must be measured in game before building

The repo's pattern is a probe that writes PASS/FAIL to SavedVariables, then `/reload`, so
the result is a record. The recommendation is one new command, `/amb probe ui`, that runs
M2-M7 in one go and leaves the eye-checks as plain questions in chat. M1 and M8 are separate
runs. Nothing below writes a CVar.

**M1. Persistence, all three branches** (decides Q2's runtime labelling and the whole
save-in-place branch). With the fixed probe (marker captured on `ADDON_LOADED`):
1. `/amb probe` - note per-character `loadCount`.
2. `/reload`, `/amb probe` - per-character count must read one higher (P.27 predicts it
   will; account-wide will not).
3. **Fully exit the client, relaunch, log in, `/amb probe`** - this is the run the design
   hinges on. P.27 predicts the per-character count falls back to 1. If it does not, the
   README's central constraint is stale for this build and the design's "Saved" branch is
   live.

**M2. The map surface for Q3.** With the map closed and then open on Elwynn Forest:
- `WorldMapFrame` exists; `type(WorldMapFrame.GetMapID)`, `.AddDataProvider`,
  `.GetCanvas`, `.ScrollContainer`, and
  `.ScrollContainer.GetNormalizedCursorPosition` (the retail pin/canvas API - each may be
  absent). With the map open on Elwynn, `WorldMapFrame:GetMapID()` should return 1429.
- `C_Map.MapHasArt(1429)`, `C_Map.GetMapArtID(1429)`, `C_Map.GetMapArtLayers(1429)`,
  `C_Map.GetMapArtLayerTextures(1429, 1)` - and then the eye check: a frame with those
  fileIDs set on textures in the documented tile grid **visibly shows the Elwynn map**.
  This is the whole basis of option 1 in Q3.
- `C_Map.GetMapChildrenInfo(<continent id from GetMapInfo(1429).parentMapID>)` returns the
  zone list, for browsing zones you are not standing in.

**M3. Drawing primitives.** On a plain frame: `CreateLine()` returns an object;
`SetThickness`, `SetColorTexture`, `SetStartPoint`/`SetEndPoint` produce a **visible**
coloured line between two points (eye check); `CreateTexture():SetColorTexture(r,g,b,a)`
draws a translucent filled rectangle; `SetGradient` accepts the documented arguments;
`CreateMaskTexture` exists. Also: does an unknown *template* name passed to `CreateFrame`
raise, or silently produce a plain frame? That decides how feature detection has to be
written.

**M4. Frame art and fonts for Q4.**
- `type(BackdropTemplateMixin)`; `pcall(CreateFrame, "Frame", nil, UIParent,
  "BackdropTemplate")`; whether a plain frame has `SetBackdrop` without the template.
- `Texture:SetTexture(path)` return value for each classic art path the Classic theme would
  use (dialog background, dialog border, gold border, tooltip background and border,
  `Interface\Buttons\WHITE8X8`) and for a deliberately bogus path, so absence is detectable.
- `C_Texture.GetAtlasExists` for the modern frame atlases.
- Font objects: `type(GameFontNormal)`, `GameFontHighlight`, `ChatFontNormal`,
  `NumberFontNormal`; and `GameFontNormal:GetFont()` to learn the default UI's real font path
  and size. Font files: `FontString:SetFont(path, 12, "")` return value for the four classic
  font files and a bogus one.
- Templates the settings tab would lean on, each by `pcall(CreateFrame, ...)`:
  `UIPanelButtonTemplate`, `InputBoxTemplate`, `OptionsSliderTemplate`,
  `UICheckButtonTemplate`, `UIDropDownMenuTemplate`, `UIPanelScrollFrameTemplate`,
  `BasicFrameTemplateWithInset`, `ButtonFrameTemplate`. Also `type(ColorPickerFrame)` and
  `type(ColorPickerFrame.SetupColorPickerAndShow)` for Q4 option 2.

**M5. Clipboard, the thing import/export cannot work without.** An `EditBox` with
`SetMaxLetters(0)` and 4000 characters set: Ctrl+A, Ctrl+C, then paste into Notepad - does
all of it arrive (eye check)? Then paste a 4000-character line from Notepad into the box and
read `#GetText()`. Then the same in a `SetMultiLine(true)` box inside a scroll frame. The
result sets DA2's length cap and whether a Config.lua block can be copied out in one go.

**M6. Map scale.** `C_Map.GetMapWorldSize(1429)` returns two numbers; `UnitPosition("player")`
returns world coordinates; `C_Map.GetWorldPosFromMapPos(1429, {x=0.4920, y=0.4143})` returns
a point near the chapel forecourt. Yards-per-normalized-unit follows and the UI can label a
radius in yards. Purely informational if any of it fails.

**M7. Options panel registration.** `type(Settings)`,
`type(Settings.RegisterCanvasLayoutCategory)`, `type(Settings.RegisterAddOnCategory)`,
`type(InterfaceOptions_AddCategory)`. Absent means `/amb ui` only.

**M8. Polygon evaluate cost** (sets the corner cap and confirms zero allocation). First
headless in `tests/` under LuaJIT: point-in-polygon plus distance-to-edge for 4, 8, 16 and
32 corners, asserting zero bytes allocated the way `evaluate` is asserted today. Then in
game: extend `addons/AmbianceCost` `/acost areas` with polygon variants at the same corner
counts and record microseconds per area beside the existing 0.17 for circles. Run on the low
preset, uncapped, per the README's rule.

**Eye checks that need a person** (the probe asks, the person answers): the Elwynn map
visibly appears in the addon's own frame (M2); a coloured line and a translucent fill
visibly appear (M3); the copied text lands in Notepad in full (M5).

---

## Open and TBD, listed so they are not lost

- **Open (M1):** which persistence branch is live at ship time.
- **Open (M2):** whether the addon can draw the zone map itself; decides Q3's default.
- **Open (M5):** paste and copy limits; sets the DA2 length cap.
- **TBD:** polygon corner cap (after M8); DA2 area and length caps (after M5 and M8); the
  Modern theme's exact colours (designer proposes at review); undo depth; the Gamma slider
  range (only if Q5 answers 2; needs its own measurement, not listed above).
- **Assumption, flagged:** no installed base speaks DA1 except the author (affects whether
  export must also emit DA1).
