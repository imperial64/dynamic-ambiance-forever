# One-stop UI — scope (2026-09-24)

## The user's request, verbatim

> make a one stop ui for this, it should include a zone creator that has a drawable map where
> you click to put down corners to create a custom shape, check indoors true or false, set
> priority, set values. write notes, name it, description, version number. the zones should be
> editable, shareable, import exportable. have a settings tab for all the settings of the addon.
> make the ui be able to have different themes. make one classic/forever vibe compatible theme,
> make a modern theme, make themes import/exportable. ask me any question you have, or tell me if
> we need to do something in game first?

## Scoping answers, verbatim

- Q: Where should the one-stop UI live? — A: "In game (Recommended)"
  (option text: addon frames, draw corners on the WoW world map at real coordinates, edit and
  save in place if per-character read-back holds, themes use Blizzard-style art; import/export
  as copy-paste strings)
- Q: Fix the probe's persistence check first so the in-game run gives a clean answer? —
  A: "Yes, fix it first (Recommended)"

## Facts established this session (orchestrator, from the WTF files)

- `/amb probe` has never been run (no `probe` key in either SavedVariables file).
- The probe's persistence marker is stamped at file-execution time (`Probe.lua:106`), which is
  before the client loads SavedVariables, so `loadCount` could never exceed 1. Being fixed.
- Evidence from 2026-09-21 sessions (13:48 login, 13:51 reload, 14:13 logout):
  - per-character file (`DynamicAmbianceCharDB`) at 14:13 still carries the 13:48:15 marker →
    **per-character read-back appears to work**
  - account file (`DynamicAmbianceDB`) was re-stamped 13:51:09 and its de-duplicated
    `probeInstances` row re-recorded at 13:51:10 → **account-wide appears still write-only**
  - Not yet confirmed by a clean probe run. Addon messaging, custom chat hyperlinks and the
    three-button popup are all still unmeasured.

## Out of scope unless the design says otherwise

- An external/desktop companion app (user chose in-game only).
- The party/raid wire itself until the probe answers addon messaging; copy-paste strings are
  the transport that works regardless.
