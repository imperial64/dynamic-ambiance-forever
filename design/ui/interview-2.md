# One-stop UI - design interview, round 2: saving works now (2026-09-25)

This is not a design revision. It is the set of decisions the user has to make before
`DESIGN-ui.md` can be revised for a client that reads SavedVariables back, each with a
recommended default, plus the engineering choices the designer will make alone and what the
revision will leave TBD.

**How to read the labels.** Same conventions as `interview-1.md`:

| Label | Meaning |
|---|---|
| **Authority** | Repository-confirmed: a measured finding in the forever-addon-dev research repo's `research\findings.md` (cited by section), that repo's `reference/guides/savedvariables.md`, this repo's code, `DESIGN-ui.md`, or a file on disk read for this interview |
| **User decision, not canonicalized** | Something the user said (`answers-1.md`, `feedback-1.md`, or the instructions for this revision) that no canonical document yet carries |
| **Proposal** | The designer's recommendation. Not decided until the user says so |
| **Example** | Illustrative only; not a spec |
| **Open** | Needs a measurement or an answer; the design will branch on it |
| **TBD** | Deliberately left unset; no value has been invented for it |

Each question is written to be put to the user unchanged, one at a time, so each repeats the
context it needs. The recommendation is marked **(Rec.)**; every list ends with `Something
else`. Questions are ordered by how much of the revision hangs on the answer.

---

## Facts the design will rest on

**Authority - persistence on build 1.60.1.70009** (findings.md §P.30, §P.31; guide
`savedvariables.md`, measured 2026-09-25). Both `## SavedVariables` and
`## SavedVariablesPerCharacter` are restored across `/reload` **and** across a full exit and
relaunch through Battle.net. Under the default load order (no directive) every saved global is
`nil` while the addon's files run, and at `ADDON_LOADED` the client **replaces** the global
with the restored table: retail's order. `## LoadSavedVariablesFirst: 1` moves the restore
ahead of file scope; under it an unconditional file-scope assignment destroys saved data. An
addon cannot ask which order it is in (`GetAddOnMetadata` returns nil for the directive). The
client writes the files at `/reload` and at logout, and nowhere else. Blizzard has not
announced the fix; §P.30 says explicitly that it says nothing about later builds and to
re-check on every one. The two exotic WTF paths are still neither read nor written (§P.33).

**Authority - this addon on 70009, read from disk for this interview** (2026-09-25, 14:33
files in `F:\World of Warcraft\_classic_beta_\WTF\Account\<account>\`):

- `DynamicAmbianceDB.persistenceMarker.loadCount` is **7** and `DynamicAmbianceCharDB`'s is
  **7**; `probe.savedVariables.accountMarker` and `charMarker` hold the previous load's
  marker (load 6, 14:32:04), so `/amb probe` itself reported "READ-BACK WORKS" on the 14:33
  load. (The orchestrator's audit saw 5; two loads have happened since. Same conclusion.)
- `DynamicAmbianceDB.imported` holds one entry stamped **2026-09-24 20:27:38** - written on
  build 69977 and read back by 70009. `captures` and `exports` are absent from the file
  today. `probeInstances` holds **7 rows, one per load**, every one triggered by
  `PLAYER_ENTERING_WORLD`: the `+3s` snapshot is de-duplicated within a session by
  `Probe.lua`'s `seen` signature set, so growth is one row per load rather than two, but that
  set is rebuilt empty every session, so the list grows without bound across loads.
- `DynamicAmbianceDB.editor` holds a draft from **14:24 today** with `unsavedZones = 1`: the
  recovery draft is present and is now restored every load, so the "unsaved" state persists
  from session to session with nothing acting on it.
- The per-character file holds only the marker (123 bytes). `AmbianceCostDB` is empty.
- The installed `Interface\AddOns\DynamicAmbiance\Zones.lua` (20:24 yesterday) **differs from
  the repo's**: Elwynn at version 2, author stamped, the chapel forecourt moved and resized
  (0.5138, 0.4438, 111.4 / 295.8 yd, priority 10) and two polygons, "area 4" and "area 5",
  that the repo's file does not have. That is the operator's own work from the copy-paste
  flow and `scripts/install-addon.ps1` refuses to overwrite it without `-OverwriteZones`.

**Authority - what the code does today.** Every binding of `DynamicAmbianceDB` /
`DynamicAmbianceCharDB` / `AmbianceCostDB` sits inside a command or event handler; nothing
touches them at file scope and no file-scope local aliases them. Nothing reads zones or
settings from either DB: zones come only from the shipped `Zones.lua`, executed at file
scope into `Config.zones`; `/amb set` toggles mutate `Config.settings` for the session. The
engine resolves a zone on `PLAYER_LOGIN` / `PLAYER_ENTERING_WORLD` and on zone change
(`resolveZone`, `onLogin`), never at file scope. `Settings.lua` and `Share.lua` take
`local settings = Config.settings` at file scope and `defineKey` captures
`settings.instances` / `settings.sharing` **by table reference**. `ProbeUI.lua` and the
editor's `mapcheck` mirror one table under both DBs. The editor writes `draftLines` on every
dirty change and clears `__dirty` on Select all (`Editor.lua` 1271-1290, 1365-1382).

**Authority - what the design and the code say about persistence, all of it now stale for
70009:** `DESIGN-ui.md` §0 (M1), §1.3 ("with no persistence, save means export"), §6.8, §7
(the whole Save to file panel and its §7.2 wording), §9.4 steps 9-11, §10.1-10.3
("session-scoped like everything else"); `interview-1.md` lines 41-59, 119-148, 341-344,
363-371, 440; `Config.lua` lines 4-7 and 120-123; `Editor.lua` lines 24-29 and the
`E.SAVE_TEXT` block; `Serialize.lua` lines 3-5; `Settings.lua` 272-273 and 319;
`Share.lua` 45-48, 143-144, 172, 446, 453-455; `Probe.lua` 45-51, 541-543, 574-575;
`SelfTest.lua` 29-31, 253-254; `ProbeUI.lua` 43-46; `DynamicAmbiance.lua` 35-36, 1027-1029,
1038; `README.md` 167-169, 485-500, 548; `DESIGN-settings-and-sharing.md` "Blocked on the
probe"; `handoff/acceptance-ui-delivery1.md` 13-15, 124-137; `IDEAS.md` 58, 117, 153, 264.

**User decision, not canonicalized** (the instructions for this revision, verbatim intent):
the live branch is now restart-persistent; **keep runtime detection** rather than hardcoding
it, because a later beta could regress; change which branch the UI treats as normal; make
"save" mean save in place, not export; whether the export flow stays, is demoted or goes is
the user's call and is asked below.

**User decision, not canonicalized** (`answers-1.md` Q2): the Save-to-file flow must
"emphasize that it will be automatic once blizzard fixes saving". `DESIGN-ui.md` §7.2 turned
that into a promise to the player: "The addon already saves your work on every change, and
it will load it back the instant the game lets it. Nothing you paste today will need to be
redone." That promise is now due, and it constrains Q2 and Q4 below.

**User decision, not canonicalized** (`answers-1.md` Q7, verbatim option text): the version
is "a whole number the UI raises by one each time you save a change to the preset". "Save"
meant export when that was answered. Q6 asks what it means now.

**Authority - `interview-1.md` line 58 planned three persistence branches** - restart-
persistent / reload-only / none - "detected at login (M1), never assumed". Only "none" was
ever live (69977). All three stay in the design; which one the UI treats as normal flips.

**Discrepancies with the orchestrator's audit, surfaced not resolved.** None contradict its
conclusions. (1) `loadCount` is 7, not 5 - newer loads. (2) `probeInstances` grows one row
per load, not two: the `+3s` snapshot is de-duplicated within the session. (3) `captures` and
`exports` are not in the file today, so the only lists that have actually grown are
`probeInstances` (7) and `imported` (1). (4) `Serialize.lua` and `Editor.lua` carry the
69977 wording in their headers too, not only `Config.lua`.

---

## Questions for the user

### Q1. Where do your zones live now, and which copy wins: the saved settings, or the Zones.lua file?

**Context.** Today your zones live in one place: `Interface\AddOns\DynamicAmbiance\Zones.lua`,
a file the game executes at startup, and the only way an edit reached it was the copy-paste
in Save to file. Your installed copy of that file already holds your own work - Elwynn at
version 2, the moved forecourt, "area 4" and "area 5" - and it differs from the one the repo
ships. From now on the game restores what the addon saves, so zones can live in the addon's
saved settings and every edit can stay without a paste. That leaves two copies of "your
zones" - the file and the saved settings - and the design has to say which one is real, what
happens the first time you log in with the new version (nothing you have drawn may be lost),
and what happens when a later addon update ships a changed `Zones.lua`.

**Options**

1. **(Rec.)** **The saved settings are your zones; `Zones.lua` is a seed.** The first login
   with no saved zones copies every zone the file defines into the saved settings, so your
   installed `Zones.lua` - including area 4 and area 5 - migrates automatically. After that
   the file is only a seed: it is never merged over your saved zones, a zone you delete stays
   deleted, and if an addon update ships a `Zones.lua` with zones you do not have, the addon
   says so once in chat and the editor offers "Import from Zones.lua" for the ones you want.
   Zones you hand-edit in the file after migration are ignored until you import them.
2. **The file wins, the saved settings fill the gaps.** `Zones.lua` stays the authority for
   every zone it defines; saved settings hold only zones the file does not have. Editing a
   shipped zone in the editor keeps working but the edit is lost at the next login, unless it
   is exported to the file. This is the current model with save-in-place bolted on for new
   zones only.
3. **Saved settings only.** Once anything is saved, `Zones.lua` is ignored entirely; the
   shipped example set and any future shipped zones reach you only through the import box.
   The first login still migrates your installed file as in option 1.
4. Something else.

**What each option changes.** Option 1: `DESIGN-ui.md` §1.2 is rewritten (the file is a seed
and an export target, not the store); §6.8's `__origin = "file"` gains `"saved"`; a one-time
migration step and a "zones in the file you do not have" notice are specified; deleting a
zone becomes a real action. Option 2: §1.2 stays, and the editor has to show, per zone,
whether an edit will survive login - which is the "This session only" labelling of
interview-1 Q2 again, per zone. Option 3: as option 1 minus the notice and the import
button; a shipped fix to the example set never reaches anyone automatically.

**Why the recommendation.** Your own drawings are already in the file and must not be lost,
so the first-run migration is common to every option. After that, one authority is the only
model the footer can state in one word ("Saved"). Option 2 makes the answer to "is this
kept?" depend on which zone is selected. Option 3 throws away the only path by which a
corrected shipped set can reach a player, for no gain.

---

### Q2. Is saving automatic on every edit, or is there a Save button?

**Context.** The editor edits the live zone table, so the screen previews every change as
you make it; there is no working copy. The game writes an addon's saved settings to disk only
at `/reload` and at logout, and there is no call an addon can make to write them sooner - so
a Save button cannot make anything reach the disk earlier than the next reload or logout, and
a crash loses the session's edits either way. What a Save button *can* do is separate "what
I am trying" from "what I keep": with one, closing the editor without saving would put the
zone back the way it was. Yesterday's Save to file text promised players that "the addon
already saves your work on every change" once Blizzard fixed saving. Undo and redo exist in
the editor either way.

**Options**

1. **(Rec.)** **Automatic.** Every edit is saved the moment it is made; the footer reads
   "Saved - written to disk at /reload or logout" and there is no Save button, no unsaved
   counter and no "unsaved zones" popup on close. Undo is how you take an edit back within
   the session; there is no "revert the whole session".
2. **A Save button, with a working copy.** Edits preview live but are kept only when you
   press Save (or answer "Save" to the popup on close). "Close anyway" restores the zone as
   it was when you opened it. The footer keeps its unsaved counter, now meaning "not yet
   kept", not "lost at /reload".
3. **Automatic, plus a per-zone "Revert to last export"** that puts a zone back to the state
   of its last exported string or file. A safety net without a working copy.
4. Something else.

**What each option changes.** Option 1: `DESIGN-ui.md` §5's footer line, §6.8 (the dirty
counter, the `*` in the title, the close popup and the recovery draft all go on the normal
branch), §7.1's popup, §9.4 steps 10-11. Option 2: §6.8 is rewritten around a working copy;
Share.lua's preview swap and the editor's live-table rule (§3.3) must coexist with it, which
is new engineering; the recovery draft stays as the crash net for unsaved work. Option 3: as
option 1 plus a stored "last exported" copy per zone and a button.

**Why the recommendation.** It is what the player was promised, it matches the editor's
existing no-working-copy model, and a Save button here would imply a control over the disk
that the client does not give an addon. If a whole-session revert turns out to matter in use,
option 3 can be added without changing the model.

---

### Q3. Save to file - the copy-paste into Zones.lua - stays as a sharing feature, is demoted, or goes?

**Context.** The Save to file panel exists because there was no other way to keep a zone:
it generates the whole `Zones.lua`, you select all, copy, paste it over the file and
`/reload`, and the panel carries a paragraph explaining why you have to. With saving working,
that paragraph is false and the paste is unnecessary for keeping your work. But the same
panel is also where the DA2 preset string of one zone is copied from (the sharing format,
which is unchanged), and the generated file is still the only way to move *all* your zones at
once - to another account, to a friend, into a backup, or into a repo - and it is the only
thing that keeps your zones if a later beta build breaks saving again (the addon keeps
checking for that at every login, whatever you choose here).

**Options**

1. **(Rec.)** **Demote it to "Export".** The footer button and `/amb ui save` become
   "Export"; the panel offers the DA2 string of one zone (sharing) and the whole `Zones.lua`
   text (backup, moving everything, or seeding a fresh install), with one line saying what
   each is for and no popup. The old wording and steps are kept in the design but shown
   **only** when the addon detects at login that this build does not read saved settings
   back (Q4): then the panel returns as "Save to file", steps and all, and says that saving
   has regressed on this build.
2. **Keep it as it is, beside save-in-place.** Two ways to keep a zone, both called saving;
   the paragraph is reworded to say the paste is optional.
3. **Remove the Zones.lua export.** Sharing is preset strings only, one zone at a time;
   moving all your zones is copying the WTF file by hand; if saving regresses, the copy-paste
   flow has to be rebuilt.
4. Something else.

**What each option changes.** Option 1: `DESIGN-ui.md` §7 is retitled and its §7.2 wording
becomes the regressed-branch text; §7.3's generator is unchanged; the "Preset string"
dropdown becomes the panel's first mode; `Serialize.exportFile` keeps stamping versions (Q6);
`feedback-1.md` item 8's popup is dropped on the normal branch (Q7). Option 2: §7 keeps its
shape, wording changes only, and the footer has to explain two kinds of "saved". Option 3:
§7.3 and its tests go; §1.2's "the file is a seed" (Q1) loses its export half, so a player
can never regenerate `Zones.lua` from the editor.

**Why the recommendation.** The file export costs nothing to keep (it is built and tested)
and is the only complete backup and the only fallback for a regression, which §P.30 says is
possible. Calling it "Save" beside a real save is the confusion to remove, not the feature.

---

### Q4. If a later beta build stops reading saved settings back again, what should the addon do?

**Context.** The fix arrived without an announcement, in build 70009, and the plugin repo's
finding says outright that it says nothing about later builds. You asked to keep detecting
at login rather than assuming, so the addon will always know, from the second load on a
build onward, which of three states it is in: saved settings come back after a restart
(normal, today); they come back after `/reload` only (as on build 69913); or never (as on
69977). On the very first load on a new install there is nothing to compare against, so
that load is "not yet verified" until the first `/reload` or relaunch. The question is what
the player sees in each state.

**Options**

1. **(Rec.)** **Normal:** nothing is said about persistence beyond the footer's "Saved".
   **Not yet verified** (first load only): the footer says "saving not yet verified on this
   build - verified after your first /reload", once. **Regressed** (reload-only or none): one
   chat line at login saying which, the footer changes to "this build does not keep saved
   settings across a restart / at all - export to keep your zones", and the Export panel
   comes back as Save to file with the copy-paste steps (Q3 option 1). Everything else in the
   editor keeps working; the recovery draft (Q7) is kept only on this branch.
2. **Warn at login only.** One chat line on a regressed build; the editor is unchanged and
   says "Saved" regardless, which would be untrue.
3. **Lock the editor on a regressed build** until the player exports, so nothing can be
   drawn that cannot be kept.
4. Something else.

**What each option changes.** Option 1: `DESIGN-ui.md` §0 gains the three-state detection
as authority-with-expiry, §5's footer gets three texts, §7 keeps the 69977 wording as the
regressed branch, and the test plan gains a stub for each state. Option 2: §7's old wording
is deleted entirely. Option 3: a lock state in §5 and §6, and the acceptance run has to
simulate a regression to see it.

**Why the recommendation.** It is the design interview-1 line 58 already committed to - every
branch handled, the live one detected - with the normal branch swapped. Option 2 says
"Saved" on a build that will lose the work, which is the exact failure `feedback-1.md` item 8
was written to prevent. Option 3 punishes the player for Blizzard's regression.

---

### Q5. Are your zones and settings shared by every character on the account, or kept per character?

**Context.** The game offers two saved files per addon: one for the whole account and one
per character. Both work on this build. Zones describe the world - Duskwood is Duskwood
whichever character walks through it - and the three sliders the addon drives are display
settings that belong to the machine, not the character. The `/amb set` toggles (suspend in
dungeons, raids, battlegrounds; accept sharing; live preview) and the ignore list could
plausibly differ between an alt you raid on and one you level. Today the toggles live in
`Config.lua` and reset every session; the ignore list too. The choice decides which file
each thing is written to, and it is hard to change later without a migration.

**Options**

1. **(Rec.)** **Everything account-wide.** Zones, toggles, ignore list and (in delivery 3)
   the theme are in `DynamicAmbianceDB`, so every character sees the same. The per-character
   file keeps only the probe marker.
2. **Zones account-wide, toggles and ignore list per character.** One set of drawings, but
   each character chooses its own instance behaviour and its own ignore list.
3. **Everything per character.**
4. Something else.

**What each option changes.** Option 1: one store, one migration (Q1), one footer word.
Option 2: `DESIGN-ui.md` §10.1 says which file each setting goes to, the settings tab shows
"this character" where it applies, and the ignore list's "Never from this player" becomes
per character. Option 3: the Q1 migration runs once per character, and a zone drawn on one
alt is invisible on another unless exported and imported.

**Why the recommendation.** The data is about places and a screen, not a character, and one
store keeps the "is this kept?" answer to one word. Per-character toggles are a real
preference some players will have; delivery 2 can add a "this character only" override for a
toggle later without moving the store.

---

### Q6. What raises the version number now that saving and exporting are different things?

**Context.** Yesterday you chose "a whole number the UI raises by one each time you save a
change to the preset, and which you can type over". Then saving *was* exporting - a preset
string or the Zones.lua text - so the design bumps the version at export, once, if the zone
changed since its last export. Now every edit is saved (Q2), and if the version rose on every
saved change a corner drag would push it up by dozens. The version is shown in the export
string and in a receiver's confirmation as "newer / older / same than yours", and never
replaces anything by itself.

**Options**

1. **(Rec.)** **Bump on export only**, as built: the version goes up by one when a preset
   string or the zones file is generated, if the zone changed since the last export. The
   version means "what others may have seen"; `date` stays the last export date. Saving in
   place never touches it.
2. **Bump once per editing session in which the zone changed**, at the moment the editor is
   closed or the game reloads. The version then counts sessions of work, whether or not the
   zone was ever shared.
3. **Bump on export and show a separate "last saved" time** in the properties panel, so the
   player can see both without the version moving on a save.
4. Something else.

**What each option changes.** Option 1: `DESIGN-ui.md` §1.3's sentence "with no persistence,
save means export, so that is the event that bumps it" is replaced by the reason above; the
tests in §9.1 stand. Option 2: `Serialize.stampExport` splits into a session stamp and an
export stamp; a receiver's "newer than yours" can then be true of a zone the sender never
changed in any way they shared. Option 3: option 1 plus a saved `meta.savedAt` field and a
label.

---

### Q7. The two popups you asked for yesterday - "Your changes are not saved yet" and "You have N unsaved zones" - keep them, drop them, or keep them only on a regressed build?

**Context.** At the delivery 1 acceptance run you said that Save to file "does not provide
enough visual feedback that there is something the user has to do" and asked for a popup
telling the player to read the steps on the right; the design also raises "You have N
unsaved zones. They are lost at /reload. Open Save to file?" when the editor is closed with
changes. Both exist to stop work being lost to the copy-paste step. With saving automatic
(Q2, option 1) there is no step left for the player and the popups would be warning about
nothing; on a build where saving has regressed (Q4) they would be warning about exactly the
right thing.

**Options**

1. **(Rec.)** **Drop both on the normal branch; keep both, unchanged, on a regressed build**
   (Q4 option 1), where the copy-paste step is back and the warning is true.
2. **Drop both entirely**, on every branch.
3. **Keep the close popup on the normal branch, reworded** to "Your changes are saved and
   reach the disk at /reload or logout. Close?", so closing the editor always says what
   happens to the work.
4. Something else.

**What each option changes.** Option 1: `feedback-1.md` items 8 and 9 are recorded as
"resolved differently: superseded by saving in place on 70009, retained for the regressed
branch"; `DESIGN-ui.md` §6.8 and §7.1 carry both texts under their branch. Option 2: the
texts are deleted and the regressed branch relies on the footer alone. Option 3: a popup on
every close, which the acceptance run did not ask for.

---

## Proposals (not questions)

Each is the designer's call, labelled **Proposal**, and any can be reopened at review.

- **Proposal - no `## LoadSavedVariablesFirst`; bind at `ADDON_LOADED`; only mutate.** The
  orchestrator's intent is confirmed against the code: no consumer needs saved values at file
  scope. `Config.lua` and `Zones.lua` build `Config.zones` at file scope from shipped code,
  which is not saved data; the engine resolves a zone at `PLAYER_LOGIN` /
  `PLAYER_ENTERING_WORLD` and on zone change, both after `ADDON_LOADED`; the editor is built
  lazily on first open. The directive would buy nothing and would turn any future
  unconditional file-scope assignment into data loss (§P.31). The rule is safe under either
  order, which is what matters if Blizzard changes the default.
- **Proposal - merge saved settings *into* the existing tables, never replace them.**
  `Settings.lua` and `Share.lua` take `local settings = Config.settings` at file scope and
  `defineKey` captures `settings.instances` and `settings.sharing` by reference. At
  `ADDON_LOADED` the saved toggles are copied key by key into those tables
  (`fillDefaults`-style), so every existing reference stays valid. `Config.settings` in
  `Config.lua` becomes the defaults; the saved values overlay them; `/amb set` writes both
  the live table and the saved copy; a "reset to Config.lua" command returns to the file's
  values. The same principle as Q1's answer applies to settings: the saved copy wins over a
  later hand-edit of `Config.lua`, and the settings tab (delivery 2) says so.
- **Proposal - the saved zone store is a clean copy, written by the existing draft path.**
  The zone tables in `Config.zones` carry engine caches (`__layers`, `__areas`, `__W`,
  `__H`, the editor's `__origin`, `__dirty`) that must not reach the file, and `__layers`
  holds the same area tables again, which the client would serialise twice. So the store is
  not the live table: on every edit the editor writes a clean structured copy
  (`DynamicAmbianceDB.zones[name]`, the field lists `Serialize.lua` already owns, no
  `__` keys) - the `flushDraft` mechanism retargeted from lines to tables - and at
  `ADDON_LOADED` the saved copies are deep-copied into `Config.zones`, replacing the seeded
  entries by key. `Serialize.draftLines` goes on the normal branch (Q7 keeps it on the
  regressed one). Round trip (live → store → live) is tested field-for-field in `tests/`
  like the file generator is. A store written this way is also the answer to the orchestrator's
  point that the draft duplicates the save: the draft *becomes* the save.
- **Proposal - detection at login, three states with expiry.** `Probe.lua`'s marker is the
  instrument, moved into the addon proper and stamped on both DBs at `ADDON_LOADED` as now,
  and extended with what kind of load wrote it: the `PLAYER_ENTERING_WORLD` arguments
  `isInitialLogin` / `isReloadingUi` (§P.30 records the companions reading both on this
  client - **Open:** this addon has not read them itself; a nil pair degrades to "unknown load
  kind" and the state falls back to "restored / not restored"). A marker that comes back on a
  cold start proves restart-persistent; one that comes back only after a `/reload`, whose
  writer recorded arriving nil on its own cold start, proves reload-only; nil on the second
  load proves none. The first load on a fresh install is "not yet verified". The result is
  `ns.persistence = { state, verifiedOn = <build>, when }`, stored, and re-measured on every
  load - so a regression shows up on its second load. The build string is read from
  `GetBuildInfo` through `pcall` and `plain`, and a state measured on one build is
  reported as unverified on the next until re-measured.
- **Proposal - `LoadSavedVariablesFirst` stays out of the `.toc` and the linter keeps
  running** on both addons; `AmbianceCost` binds inside its command already.
- **Proposal - cap the append-only lists.** `probeInstances` rebuilds its `seen` signature set
  from the saved list at `ADDON_LOADED`, so the same open-world snapshot is not re-recorded
  every load (that alone stops the growth seen today: 7 rows for 7 loads, all identical in
  kind). `captures`, `imported`, `exports` and `selftest`/`probe`/`probeUI` results keep the
  most recent entries only; the number is **TBD** - a proposal at review, not a measurement,
  and the design will name one with its reasoning rather than leave it to the implementer.
  `AmbianceCostDB.runs` is an operator's measurement log and is left alone.
- **Proposal - ProbeUI's mirror under both DBs stays** (it is a probe record, and mirroring
  was the 69913-era hedge), but the editor's `mapcheck` writes to the account DB only.
- **Proposal - `/amb here` stops saying "/reload or log out to write the file"** and instead
  says the capture is saved; its `captures` log is kept as the raw record it always was.
- **Proposal - the ignore list moves into the store** (`/amb ignore <name>` and the popup's
  third button now persist, per Q5); `/amb ignore all` becomes a real setting
  (`sharing.accept`), which closes DESIGN-settings-and-sharing.md's "cannot be built as
  asked" note.
- **Proposal - wording sweep, one pass, with the branch as the switch.** Every chat line,
  comment, README paragraph and design sentence listed under "all of it now stale" says what
  is true on the detected branch, and the README's constraints section is rewritten to: the
  client reads SavedVariables back on 70009 (§P.30), the addon binds at `ADDON_LOADED`
  (§P.31), and the addon detects a regression at login. The README gains a short "If you
  installed a SavedVariables workaround" note that points at the plugin guide's list
  (ForeverSVFix, WTFix, svshim, link lines, junctions) and repeats the guide's own caveat
  that none of those tools was measured; the addon itself says nothing about other tools,
  because it cannot detect them.
- **Proposal - Deliveries 2-4 lose "session-scoped like everything else".** The settings
  tab, the theme choice and the Share tab's ignore list save in place; the "Config.lua block
  box" of §10.1 becomes part of the Export panel (Q3), not a save path.
- **Proposal - the first-run migration is one function, tested headlessly:** given a
  `Config.zones` from the file and an empty store, the store afterwards equals the file's
  zones field-for-field with `__origin = "file"` recorded as the seed source; given a
  non-empty store, the file's zones not in the store are listed, not merged (Q1 option 1).
- **Proposal - version bookkeeping flags (`__unexported`, `__versionManual`,
  `__exportedOnce`) become saved fields** under `meta` rather than `__` caches, or the bump
  rule cannot survive a session (a zone edited today and exported tomorrow would not bump).
  Which fields, and their names, are the design's to set at revision.

---

## Open and TBD, listed so they are not lost

- **Open:** the `isInitialLogin` / `isReloadingUi` arguments of `PLAYER_ENTERING_WORLD` as
  read by this addon (the plugin's companions read them; `DynamicAmbiance.lua` ignores the
  arguments today). One login and one `/reload` with `/amb status` answer it (this said
  `/amb probe`, removed on 2026-09-25).
- **Open:** whether the client writes SavedVariables on any event other than `/reload` and
  logout (a crash, a disconnect). The guide says those two; nothing else is measured. The
  footer wording in Q2 rests on it.
- **Open:** the current build string as `GetBuildInfo` returns it on this client, for the
  "verified on build" stamp (the `.build.info` file says 70009; the Lua-side value is
  unmeasured here).
- **TBD:** the cap on each append-only list (Proposal at review, with reasoning).
- **TBD:** the exact field names of the saved store (`DynamicAmbianceDB.zones`,
  `.settings`, `.persistence`, `.migratedFrom`) - set in the revision, not here.
- **TBD:** whether the shipped Northshire example set keeps shipping in `Zones.lua` as the
  seed for a fresh install, given its notes say its values are deliberately exaggerated.
  Not asked, because it is unchanged by this revision; flagged so it is not forgotten.
- **Assumption, flagged:** the plugin guide's advice to remove ForeverSVFix / WTFix / svshim
  is reasoning from the measured load order, not a measurement of those tools. The README
  repeats the caveat.

---

## Follow-up questions (after `answers-2.md`, 2026-09-25)

The seven answers are recorded verbatim in `design/ui/answers-2.md`. Six combine cleanly.
One does not, and the orchestrator's note on Q4 records it as unresolved: **Q3 option 3
removed the Zones.lua export, while Q4 option 1 and Q7 option 1, both chosen, bring "Save to
file with the copy-paste steps" back on a regressed build**, and the recovery draft Q7 keeps
on that build is Zones.lua text from the same generator. Q1 option 3 adds a second wrinkle:
"once anything is saved, `Zones.lua` is ignored", so on a build that keeps saved settings
across `/reload` but not across a restart, a file the player pasted would be ignored at the
next `/reload` because the store is still there, and only take effect at the next restart.

What the revision resolves on its own, from the option texts as chosen, and does not ask:
Q2's "revert to last export" reverts a zone to its last exported **preset string** (the only
export left); a zone never exported has nothing to revert to and the button says so. Q1 with
Q5: each character's first login with an empty store seeds it from `Zones.lua`, so a fresh
alt sees the file's zones - the shipped example set, or whatever the installed file holds -
not the main's drawings; a zone moves between characters as a preset string, exported on one
and imported on the other, as Q5 option 3's text said. The regressed-branch footer says
"copy each zone's preset string to keep it" unless FQ1 below says otherwise.

### FQ1. On a build where saving has regressed, what is the way to keep your zones?

**Context.** You chose to remove the Zones.lua export (Q3), and separately chose that on a
build that stops reading saved settings back the addon should say so at login, change the
footer, and bring the copy-paste panel and its two popups back (Q4, Q7). Those two answers
pull against each other, because the copy-paste panel *is* the Zones.lua export. The addon
will keep detecting the state at every login whichever way this goes; the question is only
what it offers when the state is bad. Today that generator is built and tested
(`Serialize.lua`, `Editor.lua`'s Save panel, the line-by-line recovery draft), so keeping it
hidden costs nothing; removing it means a regression has no file path until one is rebuilt.

**Options**

1. **(Rec.)** **Keep the Zones.lua generator in the code, hidden on a normal build, and
   shown only on a regressed build** - the panel, its steps, the two popups and the
   line-by-line recovery draft exactly as delivery 1 built them, under the title "Save to
   file". On such a build `Zones.lua` is the authority again at every load (the store is
   re-seeded from it each time, so a paste takes effect at the next `/reload` on the
   reload-only branch too), and the footer says "this build does not keep saved settings -
   Save to file to keep your zones". On a normal build none of it is reachable and there is
   no file export, as you chose in Q3.
2. **No file path at all.** On a regressed build the footer and login line say the work is
   lost at restart (or at `/reload`), the two popups are reworded to point at preset strings,
   and keeping a zone means copying its preset string out and importing it next time, one
   zone at a time. The generator and the recovery draft are deleted.
3. **Delete the generator now and rebuild the copy-paste flow only if a regression
   actually happens**, taking option 2's behaviour in the meantime.
4. Something else.

**What each option changes.** Option 1: `DESIGN-ui.md` §7 survives as the regressed-branch
panel with the 69977 wording; §1.2's seed rule gains "at every load on a regressed build";
Q7's popups keep their present text; the test plan covers the panel under a stubbed
regression. Option 2: §7 and §7.3, `Serialize.zonesFile`, `draftLines` and their tests go;
§6.8 and §7.1's popups are reworded around preset strings; the only multi-zone backup is the
WTF file. Option 3: as option 2 in the design, with a note that the deleted code is in git
history at commit `7810e9b` and earlier.

**Why the recommendation.** It is what Q4 and Q7 asked for, it keeps Q3's normal-branch
outcome (no file export a player can see), and it costs nothing today. Option 2 makes a
Blizzard regression cost the player one paste per zone per session.
