# Changelog

## v0.3.0 (2026-09-25)

The first public release. For WoW: Forever beta build 1.60.1.70009 and later.

### New

- **Your settings are saved.** Build 70009 keeps addon saved settings across `/reload` and a
  full restart, so each character's zones, areas and toggles are now stored and survive a
  relaunch. The client writes them to disk at `/reload` and at logout, so a crash loses that
  session's edits.
- **The editor, `/amb ui`.** A window with the zone's map: draw polygon, circle and
  named-subzone areas, set contrast, brightness and gamma for each, order them by priority,
  and preview the result live. Every edit is saved as you make it. Undo and redo, delete a
  zone, and revert a zone to its last export. The window hides in combat and comes back
  afterwards.
- **Gamma** is a third setting beside contrast and brightness.
- **Sharing.** Export a zone as a text string and import one from another player, from the
  editor's Export and Import buttons or with `/amb export` and `/amb import`. An import shows
  the values on your screen first and applies nothing until you accept. `/amb ignore` blocks
  a player, or everyone.
- **Instance auto-toggles.** The addon steps back in dungeons, raids and battlegrounds, each
  switchable with `/amb set`.
- `/amb status` says whether your build keeps saved settings. If a later build stops, the
  addon warns you at login and the editor offers a Save to file fallback.

### Removed

- The self test, the in-game probes and the separate AmbianceCost measurement addon. They
  were development instruments; their results are kept in the repository.
- The old copy-paste flow for saving zones to `Zones.lua`. It is no longer needed on
  build 70009, and comes back on its own only on a build that stops saving.

### Known limits

- Sending a preset to your party or raid directly is not built yet. Share the export string
  instead.
- The zone that ships with the addon, Elwynn Forest, uses deliberately exaggerated values to
  show that the addon works. Change it or delete it in the editor.
