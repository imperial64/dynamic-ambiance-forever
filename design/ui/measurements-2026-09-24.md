# UI measurements, 2026-09-24, build 69977

Answers M1-M8 from `interview-1.md`. Raw records: `measurements/partA-2026-09-24/` and
`measurements/probeui-2026-09-24/`. The client updated from 69913 to 69977 at 18:36 the same
day; every result below is on 69977.

## M1. Persistence — none at all on 69977

- Account-wide: not restored across `/reload` (as before).
- **Per-character: not restored across `/reload` either** — a change from 69913, where it was
  (P.27, and the 2026-09-21 files). Marker stamped on `ADDON_LOADED`, arrived nil after
  every reload, in three consecutive sessions.
- Cold restart not tested separately: it cannot restore more than a reload does.
- Each reload **replaces** the file with that session's table, so anything a session did not
  itself write is gone. Only `Config.lua` (and other shipped addon files) survives.
- So the "Saved" branch is not live on this build; the "This session only" branch is, and the
  session ends at `/reload`, not at logout. The UI must say that plainly (user's Q2 answer).

## M2. Map surface — the dedicated editor window works

- `C_Map.MapHasArt(1429)` true, `GetMapArtID` 2153, one art layer 1002x668 in 256px tiles
  (4x3 = 12 fileIDs from `GetMapArtLayerTextures`), `minScale` 1, `maxScale` 2.14,
  `additionalZoomSteps` 2.
- 12/12 tiles accepted on textures in the addon's own frame; **operator confirms the Elwynn
  map visibly rendered.**
- `GetMapInfo(1429).parentMapID` 1415; `GetMapChildrenInfo(1415)` lists 26 zones, including
  one not in vanilla: **2548 Riverglades**. Browsing other zones is possible.
- `WorldMapFrame` exists with the retail canvas API (`GetMapID`, `AddDataProvider`,
  `GetCanvas`, `ScrollContainer.GetNormalizedCursorPosition`); `GetMapID()` reads 1429 on
  Elwynn with the map open. The overlay fallback is available if ever needed.

## M3. Drawing primitives

- `CreateLine` + `SetThickness` / `SetColorTexture` / `SetStartPoint` / `SetEndPoint` work;
  **red line visibly drawn** (operator).
- `CreateTexture():SetColorTexture(r,g,b,0.4)` works; **translucent fill visible, line
  visible through it** (operator). Note: that is a rectangle; arbitrary polygon fill is not a
  primitive — needs triangles or another approach (designer's call).
- `SetGradient` takes the ColorMixin form (`CreateColor` exists); the six-number form raises.
  `SetGradientAlpha` is absent.
- `CreateMaskTexture` exists.
- An unknown template in `CreateFrame` **raises** ("Couldn't find inherited node") and the
  error carries a "Lua Taint: DynamicAmbiance" line, so `pcall(CreateFrame, ...)` is a valid
  feature test.

## M4. Frame art, fonts, templates

- `BackdropTemplateMixin` present; `BackdropTemplate` creates; `SetBackdrop` exists on it and
  not on a plain frame.
- Classic art paths all load: dialog background (131071), dialog border (131072), gold border
  (131076), tooltip background (137056) and border (137057), `WHITE8X8` (130871). A bogus
  path: `SetTexture` still returns **true**, but `GetTexture` returns **nil**, so absence is
  detected by `GetTexture`, not by the return value.
- Atlases present: `UI-Frame-Metal-CornerTopLeft`, `UI-Frame-DiamondMetal-CornerTopLeft`,
  `Options_InnerFrame`, `common-dropdown-bg`, `128-RedButton-UP`; the bogus atlas returns
  false, so these are meaningful.
- Font objects `GameFontNormal`, `GameFontHighlight`, `ChatFontNormal`, `NumberFontNormal`
  present. `GameFontNormal:GetFont()` = `Fonts\FRIZQT__.TTF`, 12. Fonts that load:
  FRIZQT__, ARIALN, MORPHEUS, SKURRI. A missing font **raises** in `SetFont`.
- Templates that create: `UIPanelButtonTemplate`, `InputBoxTemplate`,
  `OptionsSliderTemplate`, `UICheckButtonTemplate`, `UIDropDownMenuTemplate`,
  `UIPanelScrollFrameTemplate`, `BasicFrameTemplateWithInset`, `ButtonFrameTemplate`.
- `ColorPickerFrame:SetupColorPickerAndShow` present. (Q4 chose no Customize panel this
  round; recorded for later.)

## M5. Clipboard

- Single-line (`InputBoxTemplate`) and multi-line (in `UIPanelScrollFrameTemplate`) edit
  boxes both hold 4000 characters after `SetText` with `SetMaxLetters(0)`.
- **Copy out: all 4000 characters reached Notepad, from both boxes** (operator).
- **Paste in: 4000 characters arrive intact in both boxes.** Measured by the probe's "Measure
  paste" (`#GetText()` = 4000, identical to the original, ending `0399.ABCDE`), single-line
  and multi-line. The record reached chat but not the SavedVariables file; the operator's
  screenshot of the PASS lines, 2026-09-24, is the record. 4000 was the size tested, not a
  ceiling found.

## M6. Map scale

- `C_Map.GetMapWorldSize(1429)` = 3470.83 x 2314.58 yards; `GetWorldPosFromMapPos` (takes a
  `CreateVector2D`) agrees exactly. So on Elwynn one normalized unit is ~3471 yd in x and
  ~2315 yd in y — **the axes are not square**, which matters for any radius or edge distance
  measured in normalized units.
- `UnitPosition("player")` returns world coordinates.

## M7. Options panel

- `Settings.RegisterCanvasLayoutCategory` and `Settings.RegisterAddOnCategory` present;
  `InterfaceOptions_AddCategory` absent. Use the `Settings` API.

## M8. Polygon cost (in game, `/acost areas`, low preset uncapped, 12 areas)

| | µs per area | vs circle | alloc |
|---|---|---|---|
| circle | 0.192 | 1x | none |
| 4 corners | 0.983 | 5.1x | none |
| 8 corners | 1.882 | 9.8x | none |
| 16 corners | 3.214 | 16.8x | none |
| 32 corners | 6.042 | 31.5x | none |

At the 10 Hz poll even twelve 32-corner areas are ~725 µs/s. Headless (`ns.polygonWeight`,
LuaJIT JIT off): 0.25 / 0.45 / 0.8 / 1.5 µs for 4 / 8 / 16 / 32 corners.

## Also measured: Gamma

Writable, not locked; 0.3-3.0 all read back exactly. Usable by eye, operator verbatim:
"0.7 minimum, 3.0 maximum". 3.0 was the top rung, so the client may accept more.

**User decision (answers-1.md, Q5 follow-up):** the slider spans the client's own limits, not
the usable-by-eye range.

**Client limits, measured 18:51 with `/amb probe gamma edges`** (record:
`measurements/gamma-edges-2026-09-24/`): the CVar **stores anything** — 0.2, 0.1, 0.05, 0,
-0.5, 3.5, 4, 5, 7.5, 10, 20, 50 and 100 all read back exactly, nothing raised or returned
false, no clamp found. But the **renderer clamps**: operator, verbatim, "the screen didnt
change below 0.3 and above 3.0". So the range the game actually applies is **0.3 to 3.0**,
and that is the slider's range — values outside it are accepted by the CVar and do nothing
on screen. The eye range 0.7-3.0 may be shown as a hint but must not bound the slider.
Caveat: the renderer limit is judged by eye at the rungs tried (0.3 → 0.2, 3.0 → 3.5); the
exact edge could sit anywhere in those gaps. The same principle applies to
Contrast and Brightness (0-100 is the client's measured scale).

## Also measured: sharing

Addon messaging works (207-byte whisper round trip intact; PARTY / RAID / INSTANCE_CHAT /
GUILD / SAY sends accepted). Three-button `StaticPopup` shows three buttons. Custom hyperlink
renders and its click is catchable; delivery to another player untested.
