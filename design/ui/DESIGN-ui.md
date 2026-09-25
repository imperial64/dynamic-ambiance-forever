# One-stop UI - design (2026-09-24, revised 2026-09-25 for build 70009)

Written against `design/ui/answers-1.md` and `design/ui/answers-2.md` (the user's answers),
`design/ui/measurements-2026-09-24.md` (M2-M8 on build 69977),
`design/ui/measurements-2026-09-25.md` (persistence re-measured on build 70009, which
supersedes M1), `design/ui/feedback-1.md` and `handoff/pending-forever-addon-dev-2.md`. The
engine as it stands is `addons/DynamicAmbiance/`, commit `7810e9b`.

**Revision 2 (2026-09-25).** Build 70009 reads SavedVariables back. This revision makes
"save" mean save in place, moves zones and settings into a per-character saved store seeded
once from `Zones.lua`, removes the Zones.lua export from the normal build, keeps the whole
copy-paste flow hidden for a build where saving regresses, and keeps runtime detection of
which persistence branch is live. Everything a player sees about persistence is decided by
the branch detected at login, never assumed (section 0.1). The questions and answers are in
`interview-2.md` and `answers-2.md`.

**Removed instruments (2026-09-25).** **User decision, 2026-09-25: remove the probes
completely.** `Probe.lua` and `ProbeUI.lua` are gone, with every `/amb probe` subcommand (the
settings/sharing/instance probe, `where`, `coverage`, `ui`, `gamma`). **User decision,
2026-09-25: remove selftest and ambiancecost.** `SelfTest.lua` (`/amb selftest`) and the
whole `addons/AmbianceCost/` addon (`/acost`) are gone too. What survives, moved: the
persistence report (state, load count, build, whether each marker came back, the clipboard
outcome for the build) is printed by `/amb status`, and the section 9.4 test hook is `/amb
persistence force <restart | reload | unverified | off>`. The keys only those instruments
wrote (`probe`, `probeUI`, `probeGamma`, `probeInstances`, `selftest`) are dropped from both
DBs at `ADDON_LOADED`. Their past measurements stay where they were recorded; where this
document cites one, the command named is the one that was run then.

**Delivery 1 is specified in full** (sections 1-9): the DA2 format, Gamma as a third axis,
polygons and yard-based falloff in the engine, the editor window with live preview, the
saved store and export panel, and the test plan. Deliveries 2-4 are outlined in section 10.

Labels, as in round 1: **Authority** (repository-confirmed or measured), **User decision**
(from answers-1.md, feedback-1.md or answers-2.md), **Proposal** (designer's choice,
correctable at review), **Example**, **Open** (needs a measurement), **TBD** (deliberately
unset).

---

## 0. What the design rests on

**Authority - persistence, build 1.60.1.70009** (`measurements-2026-09-25.md`, this addon's
own persistence marker: load 5 read back across a full `/quit` and relaunch through
Battle.net, then load 6 read back across `/reload`, on both `DynamicAmbianceDB` and
`DynamicAmbianceCharDB`; and forever-addon-dev `research/findings.md` §P.30, the same build
measured with twelve saved globals across two launches). Both `## SavedVariables` and
`## SavedVariablesPerCharacter` come back across `/reload` and across a full restart. The
client writes the files at `/reload` and at logout only; an addon cannot flush them sooner.
**This has an expiry:** Blizzard has not announced the fix, §P.30 says nothing about builds
after 70009, and the previous two builds behaved differently from each other (69913: per-
character survived `/reload` only; 69977: nothing at all). So the design keeps all three
branches of interview-1 M1 and detects the live one at every login (0.1).

**Authority - load order** (§P.31, guide `savedvariables.md`). Under the default order every
saved global is `nil` while the addon's files run; at `ADDON_LOADED` the client **replaces**
the global with the restored table. `## LoadSavedVariablesFirst: 1` restores before file
scope, and under it an unconditional file-scope assignment destroys the saved data. An addon
cannot ask which order it is in. Both addons bind inside handlers only, nothing at file
scope, linter clean (`measurements-2026-09-25.md`, load-order audit). **Decision (designer,
confirming the orchestrator's intent):** no directive; bind at `ADDON_LOADED`; only mutate.
Nothing in this addon needs a saved value at file scope: `Config.zones` is built at file
scope from shipped code, the engine resolves a zone at `PLAYER_LOGIN` /
`PLAYER_ENTERING_WORLD` and on zone change, and the editor is built on first open.

**User decision (answers-1 Q2), fulfilled.** The 69977 Save-to-file text promised "the addon
already saves your work on every change, and it will load it back the instant the game lets
it. Nothing you paste today will need to be redone." Section 1.2's seed step is that
promise kept: the operator's installed `Zones.lua`, pasted under the old flow, is read into
the store on the first login and nothing is redone.

**User decisions (answers-2.md, 2026-09-25), the ones this revision rests on:**

| | Chosen | Carried in |
|---|---|---|
| Q1 | Saved settings only: once a character's store exists, `Zones.lua` is ignored; the first login still migrates the installed file | 1.2 |
| Q2 | Automatic save on every edit, plus a per-zone "Revert to last export" | 6.10 |
| Q3 | Remove the Zones.lua export; sharing is preset strings, one zone at a time | 7, 8 |
| Q4 | Regressed build: one login line, the footer changes, the copy-paste panel returns | 0.1, 7.2 |
| Q5 | Everything per character: zones, toggles, ignore list, theme | 1.4 |
| Q6 | The version bumps on export only | 1.3 |
| Q7 | The "not saved yet" and "unsaved zones" popups exist only on a regressed build | 7.2 |
| FQ1 | The Zones.lua generator, panel, popups and recovery draft stay in the code, hidden on a normal build, shown only on a regressed one; on such a build `Zones.lua` is the authority at every load | 1.2, 7.3, 7.2 |
| FQ2 | "Treat reload as normal": a state proven only across `/reload` counts as normal, with a one-line caveat in the footer and no Save to file panel or popups; only `unverified` is regressed. Accepted with its cost: a reload-only build would lose work at restart with only that footer line as the warning | 0.1, 5, 6.8, 7.2, 9 |

### 0.1 The persistence branches, and how the live one is detected

**Authority (interview-1 M1, this revision):** three branches - `restart` (saved settings
come back across a restart; 70009), `reload` (across `/reload` only; 69913, per-character),
`none` (never; 69977) - plus `unverified` for a load the addon cannot yet judge. The normal
branch is `restart`, and **`reload` counts as normal too** (User decision FQ2), with a one-line
caveat in the footer (5). A `none` build is never judged as such: every load on it arrives nil
and shows as `unverified` (rule 1 below), so **`unverified` is the one regressed state** and
carries the regressed behaviour (7.2).

**The instrument** is the `persistenceMarker`, which lives in the addon proper (`Store.lua`,
section 4; it began in the since-removed `Probe.lua`, User decision, 2026-09-25: remove the
probes completely) and is stamped on both DBs at `ADDON_LOADED`; `/amb status` reports it.
It carries four
more fields: `arrivedNil` (whether the load that wrote it found the global nil), `loadKind`
(`"login"`, `"reload"` or `nil`, from the `PLAYER_ENTERING_WORLD` arguments `isInitialLogin`
/ `isReloadingUi` read through `pcall` and `plain` - **Open**, section 11: §P.30's companion
addons read both on this client, this addon has not), `build` (`GetBuildInfo`, through
`pcall` and `plain` - **Open**, section 11; nil when unreadable) and **`best`**: the best
state proven on the writer's build, carried forward from load to load so that the state
never drops without evidence. The marker is stamped before `loadKind` is known, so
`loadKind` and `best` are filled in at `PLAYER_ENTERING_WORLD` and describe the load that
wrote it.

**The judgement, at `PLAYER_ENTERING_WORLD`, from the marker that came back at
`ADDON_LOADED` (if any).** States order `restart` > `reload` > `unverified`; a restored
marker can only raise the state or keep it, never lower it. Rules, first match wins:

| # | Came back | Condition | State | Why |
|---|---|---|---|---|
| 1 | nil | - | `unverified` | nothing came back. A fresh install, a wiped WTF, or a build that does not read saved settings back: indistinguishable from inside the game (below) |
| 2 | marker | this load's kind is `login` | `restart` | the file was read back across a full restart, on this build. Proof on its own |
| 3 | marker | `marker.build` and this build are both known and differ | `restart` | a client patch always relaunches the client, so a marker written by another build could only have come back across a restart. This is what happened at 70009's first launch (§P.30) |
| 4 | marker | `marker.build` equals this build, or either is unknown | `max(marker.best, reload)` | came back across `/reload` (or a load of unknown kind); the best state already proven on this build is kept. On a restart-verified build every `/reload` stays `restart` |

So on 70009 today: a restart judges `restart` (rule 2); the next `/reload` restores a marker
whose `best` is `restart` and stays `restart` (rule 4); a patch to a build that still reads
saved settings back judges `restart` on its very first load (rule 3, or rule 2 when the
load kind is readable), so **no player passes through regressed wording after a patch that
works.** A patch to a build that does not read them back arrives nil and judges
`unverified` (rule 1), which is the truth. A fresh install on a working build goes
`unverified` (first load) → `reload` (after its first `/reload`, rule 4 with `best =
unverified`) → `restart` (its first relaunch, rule 2), and then never lower on that build.

**Downgrade is by evidence only, and the only evidence is a nil marker** (rule 1). There is
no in-game memory apart from the marker, so a nil marker cannot say whether an earlier load
on this build wrote one; the state is `unverified`, and its wording says how to tell (below).

**What separates a genuinely reload-only build from "no restart seen yet on this build":
nothing, until the next cold start.** Both show `reload` after a `/reload`. On a reload-only
build every cold start arrives nil (rule 1) and the marker it writes has `best =
unverified`, so that build cycles `unverified` at each launch, `reload` after each reload,
and never reaches `restart`. On a working build the first relaunch settles it. The `reload`
state's wording therefore claims only what is proven - "kept across /reload, not yet
verified across a restart on this build" - and never says "reload-only". The result is
`ns.persistence = { state, build, when }`, written to both DBs and printed by `/amb status`.

**Which states are regressed (User decision FQ2, "Treat reload as normal").** `restart` and
`reload` are the normal branch; `unverified` alone is treated as regressed for everything
below (7.2). A state proven only across `/reload` gets one line of caveat in the footer (5)
and nothing else: no Save to file panel, no popups, no login line. With the rules above the
regressed wording appears on a working build in exactly one case: **a fresh install (or a
wiped WTF), from the first load until the first `/reload`**; after that the footer carries
the `reload` caveat until the first relaunch settles it. The cost, accepted with the
answer: on a genuinely reload-only build the player sees the regressed wording only on each
cold start, and after their first `/reload` of a session is warned by the footer line alone
that the work will be lost at restart.

**`unverified` is honest about its own limit.** A `none` build makes every load look like a
fresh install. So the `unverified` footer text (5) says: "saving not yet verified on this
build - if this line is still here after a /reload, this build is not keeping saved
settings." The player can read the answer off the screen. The regressed-branch panel (7.2)
is reachable only on a regressed branch: on a normal build none of it is (User decision,
FQ1), and `/amb ui save` opens the Export panel. **Proposal, Open:** a registered
CVar (`C_CVar.RegisterCVar`, present with read/write per the plugin guide, which records
that CVars persist; not measured for a custom CVar on this client) holding a load counter
would separate `none` from a fresh install; it is taken up only if the counter is measured
to come back, and the wording above works without it.

**Where it is used:** the login banner (one line, only when the state is `unverified`), the
footer (5), the export panel's title and contents (7), the popups (7.2), the seed rule
(1.2), and `/amb status`, which always prints the state and the build it was judged on.

**Authority - the surface (M2-M7).** The addon can draw the zone map itself from
`C_Map.GetMapArtLayerTextures` (Elwynn: 1002 x 668 px, 4 x 3 tiles of 256 px; operator saw
the map). `CreateLine` and `SetColorTexture` fills work and are visible; there is no polygon
fill primitive. `BackdropTemplate`, the classic art files, the four fonts, and the templates
`UIPanelButtonTemplate`, `InputBoxTemplate`, `OptionsSliderTemplate`, `UICheckButtonTemplate`,
`UIDropDownMenuTemplate`, `UIPanelScrollFrameTemplate`, `BasicFrameTemplateWithInset`,
`ButtonFrameTemplate` all create. An unknown template **raises**, so `pcall(CreateFrame, ...)`
is a valid feature test. A missing font **raises** in `SetFont`. A bogus texture path is
detected by `GetTexture()` returning nil, not by `SetTexture`'s return. Copy-out of 4000
characters from an edit box reaches the OS clipboard. `Settings.RegisterAddOnCategory` exists.

**Authority - scale (M6).** `C_Map.GetMapWorldSize(1429)` = 3470.83 x 2314.58 yards. One
normalized unit is ~3471 yd in x and ~2315 yd in y: **the axes are not square.** The map art's
pixel aspect (1002/668 = 1.500) matches the world aspect (1.4995), so **on the canvas a yard
is the same length in x and in y** - a fact the fill and band drawing rely on (section 6.4).

**Authority - cost (M8).** Polygon weight costs 0.98 / 1.88 / 3.21 / 6.04 us per area at
4 / 8 / 16 / 32 corners, circle 0.19 us, nothing allocates.

**Authority - Gamma.** `Gamma` is writable, not locked, default 1.0. **The CVar clamps
nothing:** -0.5 through 100 all store and read back exactly, nothing raises. **The screen
clamps:** operator verbatim, "the screen didnt change below 0.3 and above 3.0"
(`/amb probe gamma edges`, `measurements/gamma-edges-2026-09-24/`). So the range the game
actually applies is **0.3 to 3.0**; the exact edges are uncertain - somewhere in 0.2-0.3 at
the low end and 3.0-3.5 at the high end, because those were the ladder's rungs. Usable by
eye, operator verbatim: "0.7 minimum, 3.0 maximum". **User decision (Q5 and follow-up):**
the Gamma slider ships now and spans the game's own limits, never the eye range. The eye
range may appear as a hint only.

**Authority - paste (M5).** 4000 characters pasted into a single-line and a multi-line edit
box arrive intact (`#GetText()` = 4000, identical). 4000 was the size tested, not a ceiling
found.

**Authority - sharing.** Addon messaging works (207-byte round trip intact; PARTY / RAID /
INSTANCE_CHAT / GUILD / SAY sends accepted, solo). The three-button popup shows three
buttons. A custom hyperlink renders and its click is caught; delivery to another player is
untested. The wire is therefore buildable and is placed in delivery 4 (section 10.3).

---

## 1. Vocabulary and data model

**Zone** - the game's zone, keyed by `GetZoneText()`. **Area** - one layer inside a zone: a
named subzone, a circle, a polygon, or a whole-zone rule. **Preset** - a zone's default
values, its metadata, and all of its areas: the unit that is shared (**User decision, Q1**).
Sharing a single area is a preset containing one area.

### 1.1 The zone table (Lua form, what the engine reads)

```lua
Config.zones["Elwynn Forest"] = {
    contrast = 35, brightness = 78, gamma = nil,     -- zone defaults; nil = inherit baseline
    map = 1429,                                        -- uiMapID the coordinates belong to
    meta = {
        name = "Elwynn, Northshire test set",          -- preset title (not the zone key)
        description = "",                              -- one line
        notes = "",                                    -- free text
        version = 3,                                   -- whole number, see 1.3
        author = "<character>-<realm>",                -- character-realm, stamped by the addon
        date = "2026-09-24",                           -- last export
    },
    indoors = nil,                                     -- per-zone override of Config.indoors, unchanged
    areas = {
        -- named subzone
        { subzone = "Northshire Valley", name = nil, notes = "",
          priority = 10, contrast = 55, brightness = 45, gamma = nil, indoors = nil },
        -- circle, radii in yards
        { name = "chapel forecourt", notes = "",
          x = 0.4920, y = 0.4143, innerYards = 11.3, falloffYards = 56.7,
          priority = 20, contrast = 85, brightness = 25, gamma = nil, indoors = false },
        -- polygon, corners normalized, falloff in yards
        { name = "the unnamed pocket", notes = "",
          corners = { 0.4102, 0.5210, 0.4180, 0.5205, 0.4191, 0.5302, 0.4098, 0.5311 },
          falloffYards = 25,
          priority = 10, contrast = 78, brightness = 18, gamma = nil, indoors = nil },
        -- whole-zone rule (no location)
        { name = "everything else indoors here", priority = 55, gamma = 0.8, indoors = true },
    },
}
```

(Example values above are illustrative; the pocket's corners are invented for the example and
must not be shipped - Config.lua records that the pocket needs a real capture.)

Rules:

- **Kind is implied by fields**, as today: `subzone` → named; `x` → circle; `corners` →
  polygon; none → whole-zone rule. Exactly one of `subzone` / `x` / `corners` may be present.
- **`corners` is flat** `{ x1, y1, x2, y2, ... }`, normalized 0-1 on `map`, which is what
  `ns.polygonWeight` already takes (Authority, DynamicAmbiance.lua). Minimum 3 corners.
  **Proposal:** maximum 32 corners per polygon, from M8 (twelve 32-corner areas cost ~725 us
  per second at the 10 Hz poll).
- **Radii and falloff are in yards** (`innerYards`, `falloffYards`), never normalized units,
  because a normalized radius is an ellipse in the world (section 0). Legacy `inner` /
  `falloff` (normalized) are still accepted and converted at load - section 3.4.
- **`gamma`** everywhere `contrast` and `brightness` go: baseline, zone, area. `nil` inherits.
- **`priority`, `indoors`, `contrast`, `brightness`** unchanged in meaning. `indoors` is
  tri-state: `nil` anywhere, `true` indoors only, `false` outdoors only.
- **`name`** on any kind (for a named subzone it is optional; the subzone string is the
  default display name). **`notes`** on any kind.
- Fields beginning `__` are engine caches and never serialized (`__layers`, `__rule`,
  `__areas`, `__W`, `__H`, and, on a regressed branch only, the editor's `__dirty`). The
  zone's `origin` and `export` fields (1.4) are saved with it but are not part of the DA2
  string or of `Zones.lua`.

### 1.2 Where zones live: the per-character store, seeded once from `Zones.lua`

**User decision (answers-2 Q1, Q5, FQ1).** A character's zones live in its saved store
(`DynamicAmbianceCharDB.store.zones`, 1.4). `Zones.lua` stays a shipped file, loaded after
`Config.lua` and executed by the client into `Config.zones` as today, but it is a **seed**:

- **Seeding.** At `ADDON_LOADED`, if the character's store has never been seeded
  (`store.seed == nil`), every zone the file defined is copied into the store, clean (1.4),
  and `store.seed = { when, checksum, from = "Zones.lua" }` is recorded, where `checksum` is
  Fletcher-16 over the DA2 strings of the file's zones sorted by name (existing code,
  `Preset.serialize`; **Proposal**). This is the migration: the operator's installed
  `Zones.lua`, pasted under the 69977 flow, is read in on that character's first login and
  nothing is redone. A fresh character on the same account seeds from whatever `Zones.lua`
  holds at that time, not from another character's store; zones move between characters as
  preset strings (Q5 option 3's text).
- **After seeding, on the normal branch, the file is ignored.** A zone the player deletes
  stays deleted; a hand-edit of the file after seeding is not read; a changed `Zones.lua`
  shipped by an addon update reaches an existing character only as a preset string through
  the import box (Q1 option 3). **Proposal:** the repo publishes the example set as a DA2
  string beside the file (README or `presets/`), since that is now the only route to an
  existing character.
- **On a regressed branch (0.1: `unverified`) the file is the authority again**
  (FQ1): at `PLAYER_ENTERING_WORLD`, once the state is judged, if the file's checksum differs
  from `store.seed.checksum` the store's zones are replaced by the file's and the seed record
  updated, then `refreshTarget(true)`. A store that did not come back at all was already
  seeded at `ADDON_LOADED`. Since `reload` is normal (User decision FQ2), a `/reload` keeps
  the store whatever the file holds, so a fresh install on a good build keeps its first
  session's edits across its first `/reload`, and on a reload-only build a pasted `Zones.lua`
  takes effect at the next cold start, when the store arrives nil and is seeded from it (the
  restored store already holds the same edits until then). **Decision (designer):** the
  checksum rule rather than "replace at every load", because a blind replace would discard a
  good build's first-session edits.
- The shipped `Zones.lua` remains generated content, so its header comment now says it is
  the seed for a character's first login and is otherwise not read (the generator, 7.3,
  writes that header); `Config.lua` initialises `Config.zones = {}` and points at it as
  before. The shipped Northshire test set stays in it as the seed (TBD in interview-2: whether
  it should; unchanged here).

**Proposal (unchanged from revision 1):** `Config.lua` keeps baseline, tuning, settings
defaults, limits and the global indoors rule; zones never return to it.

`Zones.lua` looks like:

```lua
-- Dynamic Ambiance - zones. GENERATED by the in-game editor, 2026-09-25 14:24, addon 0.2.0.
-- Read once, on a character's first login, to seed its saved zones; after that the
-- character's saved settings are the zones and this file is not read - except on a build
-- that does not read saved settings back, where it is read at every load. Config.lua holds
-- everything that is not a zone.
local _, ns = ...
local Config = ns.Config
Config.zones = Config.zones or {}

Config.zones["Elwynn Forest"] = {
    ...
}
```

Rules:

- `Config.lua` initialises `Config.zones = {}` with a comment pointing at `Zones.lua`. Any
  zone a user still defines in `Config.lua` is seeded like the file's (it is in
  `Config.zones` at `ADDON_LOADED`).
- The shipped Northshire test set stays in `Zones.lua`; the "VALUES ARE DELIBERATELY
  EXAGGERATED" warning and the "every name was walked" record survive as notes (done, commit
  `8d67e77`).
- Every consumer reads `Config.zones` unchanged: engine, Preset.lua, Share.lua, the editor.
  The store is loaded *into* `Config.zones` at `ADDON_LOADED` (1.4), so nothing downstream
  knows the store exists.

### 1.3 Metadata semantics

- **`version`** (User decision, answers-1 Q7 and answers-2 Q6): a whole number, raised by
  one **each time the preset is exported** - a DA2 string from the export panel or
  `/amb export`, or, on a regressed build only, a Save-to-file generation - *if it changed
  since its last export*; editable in the properties panel. Saving in place never touches it:
  the version means "what others may have seen", which is what the receiver's newer / older /
  same comparison needs, and a version that rose on every saved edit would climb by dozens
  in one corner drag. A preset never exported shows version 1. The bookkeeping behind the
  bump (`__unexported`, `__versionManual`, `__exportedOnce` in revision 1) is now **saved**
  with the zone as `export = { pending, manual, once }` (1.4), or a zone edited today and
  exported tomorrow would not bump.
- **`author`**: `UnitName("player") .. "-" .. GetNormalizedRealmName()` (both documented for
  this client), stamped when a preset is created in the editor or first exported; not stamped
  over an imported preset's author (provenance belongs to the sender).
- **`date`**: `date("%Y-%m-%d")` at export. There is no "last saved" field (answers-2 Q6
  chose option 1, not 3).
- **`name`** defaults to the zone key at creation; **`description`** and **`notes`** default
  empty.
- **Caps (Proposal):** name and description 64 characters (the existing `Preset.MAX_NAME`),
  notes 500 characters per preset and 200 per area, enforced by `SetMaxLetters` on the edit
  boxes and by `Preset.validate`. These exist so the total stays under the string cap; they
  are not measured values and can be changed.

### 1.4 The store (`DynamicAmbianceCharDB.store`)

**User decision (answers-2 Q5):** everything per character. `DynamicAmbianceCharDB` holds the
store and the persistence marker; `DynamicAmbianceDB` (account) keeps only the marker, the
persistence judgement and the capture / import / export / clipboard / mapcheck records
(1.5). Nothing a player authors goes to the account file.

```lua
DynamicAmbianceCharDB.store = {
    schema   = 1,                                  -- bumped when the shape below changes
    seed     = { when = "...", checksum = "a1c4", from = "Zones.lua" },   -- nil until seeded
    zones    = {                                   -- clean copies, one per zone key
        ["Elwynn Forest"] = {
            contrast = 35, brightness = 78, gamma = nil, map = 1429,
            meta = { ... },                        -- exactly 1.1's fields
            indoors = nil,
            areas = { { ... }, ... },              -- exactly 1.1's fields, no `__` keys
            origin = "seed",                       -- "seed" | "editor" | "import"
            export = { pending = false, manual = false, once = true },   -- 1.3
        },
    },
    revert   = {                                   -- 6.10: the last exported string per zone
        ["Elwynn Forest"] = { string = "DA2~...", when = "2026-09-25 14:24" },
    },
    settings = { instances = { ... }, sharing = { accept = true, preview = true,
                 ignorePlayers = { ... } } },      -- delivery 2 (10.1); the ignore list from delivery 1
    theme    = nil,                                -- delivery 3
}
```

(Field names are the designer's, **Proposal**; the shape is the decision.)

- **Clean copies, not the live tables.** `Config.zones[name]` carries engine caches
  (`__layers`, `__areas`, `__W`, `__H`) and `__layers` holds the area tables a second time,
  which the client would serialise twice; so the store is written *from* the live table by a
  copier that knows 1.1's field lists (`Serialize.lua` already owns them) and skips every
  `__` key, and read *into* the live table by a deep copy at `ADDON_LOADED`. Round trip
  (live → store → live) reproduces every field (9.1).
- **`origin`** replaces revision 1's `__origin` and is saved: `"seed"` (from `Zones.lua`),
  `"editor"`, `"import"`. `__dirty` is gone on the normal branch (6.8).
- **`revert[name]`** is written whenever a zone's DA2 string is generated (export panel,
  `/amb export`) and, **Proposal**, when a preset is accepted through Share.lua (the accepted
  string is the last string the zone matched; an imported zone would otherwise have no
  revert point until first re-exported). Deleted with the zone.
- **Order of loading, at `ADDON_LOADED` for this addon** (`Store.lua`, section 4): read the
  marker; bind `DynamicAmbianceCharDB` / `DynamicAmbianceDB` (`X = X or {}`, then only
  mutate); if `store.seed` is nil, seed from `Config.zones` (1.2); otherwise deep-copy
  `store.zones` into `Config.zones`, replacing by key (a file zone the store does not have is
  removed from `Config.zones`, since the store is the authority on the normal branch);
  overlay `store.settings` into `Config.settings` key by key (3.6); stamp the marker. All of
  this precedes `PLAYER_LOGIN`, where the engine first resolves a zone. At
  `PLAYER_ENTERING_WORLD`: judge the state (0.1) and apply the regressed-branch checksum rule
  (1.2).
- **Schema.** `store.schema` is 1. A store with a lower or missing schema is upgraded in
  place by `Store.lua` (there is none yet; the field exists so that the first change does
  not need a guess about what it is reading).

### 1.5 The record lists in `DynamicAmbianceDB`, and their caps

`captures` (`/amb here`), `imported`, `exports` (and `probeInstances`, until the probes were
removed) were append-only and, on 69977, reset every session by the client. On 70009 they come back and grow without
bound. **Decision (designer, at the orchestrator's request to name a number):**

- `captures`, `imported`, `exports`: **the most recent 20 entries each**, oldest dropped on
  append. Reasoning: an `imported` or `exports` entry holds one DA2 string of up to 4000
  bytes (2.2), so 20 is at most 80 KB per list, under the size of the addon's own largest
  source file (`Editor.lua`, 128 KB) and parsed once per login; and twenty is more strings
  than a player scrolls back through in the chat log the lists were built to replace. Not a
  measurement; a `Config.limits.recordEntries = 20` in `Config.lua` with this reasoning in
  its comment, so it is one number in one place.
- `mapcheck` is a single table replaced per run, not a list; the editor's `mapcheck` writes
  to the account DB only.
- `probe`, `probeUI`, `probeGamma`, `probeInstances` and `selftest` belonged to the removed
  instruments (User decision, 2026-09-25: remove the probes completely; User decision,
  2026-09-25: remove selftest and ambiancecost). `Store.lua` drops them from both DBs at
  `ADDON_LOADED`, so an old record is not carried forward. `AmbianceCostDB` belongs to the
  removed addon; nothing loads it any more, and the client stops writing it.

---

## 2. The DA2 format

**Authority carried over from DA1:** plain text, `~` between segments, `:` between fields,
`%` `~` `:` `|` percent-escaped inside fields, numbers at fixed precision with trailing
zeros stripped only after a decimal point, Fletcher-16 as the last segment, and every parse
failure names the field.

### 2.1 Grammar

```
preset   := "DA2" "~" header ( "~" meta )? ( "~" area )* "~" checksum
header   := zone "~" contrast "~" brightness "~" gamma "~" map
meta     := "m" ":" name ":" description ":" notes ":" version ":" author ":" date
area     := named | circle | polygon | rule
named    := "s" ":" subzone ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" name ":" notes
circle   := "c" ":" name ":" x ":" y ":" innerYards ":" falloffYards ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" notes
polygon  := "g" ":" name ":" falloffYards ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" notes ":" corners
rule     := "z" ":" name ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" notes
corners  := number "," number ( "," number "," number )+        -- flat x,y list, >= 3 pairs
indoors  := "" | "0" | "1"
checksum := 4 hex digits, Fletcher-16 of everything before the final "~"
```

Every numeric field may be empty, meaning `nil` (inherit). Precision: coordinates 4 places,
yards 1 place, contrast/brightness 4 places as today, gamma 3 places, priority and version
and map integers. `,` is not a structural character outside `corners` and is not escaped;
`corners` is always the last field of a polygon so a stray comma elsewhere cannot be mistaken
for one.

**Example**

```
DA2~Elwynn Forest~35~78~~1429~m:Northshire test:exaggerated on purpose::3:<character>-<realm>:2026-09-24~s:Northshire Valley:10:55:45:::~c:chapel forecourt:0.492:0.4143:11.3:56.7:20:85:25::0:~g:pocket:25:10:78:18:::walked 09-24:0.4102,0.521,0.418,0.5205,0.4191,0.5302~a1c4
```

### 2.2 Parsing rules

- `Preset.parse` accepts `DA1` and `DA2`. Any other marker is refused by name, as today.
- **DA1 → in-memory conversion:** `p` areas become circles; their normalized `inner` /
  `falloff` are converted to yards by the rule in 3.4 *if* the zone's map world size can be
  read, and the result is tagged so the confirmation can say "radii converted from an older
  format". If the size cannot be read, the area keeps `inner`/`falloff` and the engine treats
  it as legacy (3.4). DA1 has no gamma and no metadata; both come in as nil/empty.
- Export writes **DA2 only**. *Assumption, flagged in interview-1.md:* no installed base
  other than the author speaks DA1.
- `Preset.MAX_AREAS` stays 64. **`Preset.MAX_LENGTH` becomes 4000**, the size measured to
  paste in and copy out intact (M5); the constant's comment cites the measurement and says it
  is a floor, not a ceiling. Export refuses a longer string with the byte count, as today. If
  a real preset is ever refused, the cap is raised by measuring a larger paste (8.3), not by
  editing the number.
- `Preset.validate` gains: gamma within `Config.limits.gamma` (section 3.1) at zone and area
  level - **refused, not clamped** (Proposal, consistent with how contrast 4000 is refused
  today): because the CVar stores any value silently, an imported Gamma 50 would be kept and
  do nothing on screen, which is exactly the "accepted and ignored" failure this repo refuses
  to ship; the message reads `area 3 gamma 50 is outside 0.3-3 - the screen ignores values
  outside that range`. Polygon has >= 3 and <= 32 corner pairs, every coordinate 0-1, `falloffYards >= 0`;
  circle `innerYards >= 0`, `falloffYards >= innerYards` (the inside-out ramp check, now in
  yards); metadata caps from 1.3; version a non-negative integer.
- `Preset.describe` prints gamma when set, the metadata line, and polygons as
  `name (N corners, falloff F yd)`.
- `Preset.conflicts`: positional overlap is computed in yards when both sides share `map` and
  the world size is readable: two circles overlap if centre distance < sum of falloffs; a
  polygon takes part through its bounding box expanded by its falloff (**Proposal**, cheap
  and conservative). If the size is unreadable, positional overlap is reported as "not
  checked - map scale unavailable" rather than skipped silently.

---

## 3. Engine changes

### 3.1 Gamma, the third axis

- `Config.baseline.gamma` - **Authority:** the client's measured default is 1.0, so the
  shipped baseline is `gamma = 1.0`, with the same comment as contrast/brightness: declare it,
  never capture it. The login banner prints the client's current Gamma beside the other two.
- `Config.limits = { contrast = { 0, 100 }, brightness = { 0, 100 }, gamma = { 0.3, 3.0 } }`
  in `Config.lua`, each with a comment citing its measurement. Gamma's comment states the
  measured facts in full: the CVar stores anything, the screen applies 0.3-3.0, and the true
  edges lie somewhere in 0.2-0.3 and 3.0-3.5 (the ladder's rungs), so a later finer ladder may
  move them. Sliders, the numeric boxes and the validator read this table and nothing else.
  Hint marks on the Gamma slider at the operator's eye range (0.7 and 3.0, verbatim from
  answers-1.md) are labels, not bounds.
- **Out-of-range gamma is never written by the addon.** The editor's numeric box clamps to
  the limits; the validator refuses a preset outside them (2.2); a `Config.lua` / `Zones.lua`
  value outside them is reported by `/amb config` as "outside the range the screen applies"
  and clamped at `resolveZone` time with a warning, rather than stored and silently ignored.
- `state` gains `curG, tgtG, heldG, writtenG`. `evaluate` returns `c, b, g`; each layer's
  `gamma or inherited` follows exactly the contrast rule, so a layer that sets only gamma
  paints gamma alone. `refreshTarget`, `onUpdate` (third ease), `maybeWrite`, `writeNow`,
  `restoreBaseline`, `settled`, `/amb try c b [g]`, `/amb status`, `/amb debug` all carry it.
- **Write epsilon for gamma - Proposal, derived rather than invented:**
  `gammaEpsilon = writeEpsilon * (limits.gamma[2] - limits.gamma[1]) / 100`, i.e. the same
  fraction of the axis's range as 0.5 is of 0-100. Re-measure by eye if steps show.
- **Cost:** a `SetCVar` allocates ~822 bytes (Authority). Gamma is written only when its
  eased value moves by more than its epsilon, so a player whose zones never set gamma pays
  one write at login and one at logout. (The self test and `/acost` were to gain the third
  CVar; both were removed before that was recorded - User decision, 2026-09-25: remove
  selftest and ambiancecost.)

### 3.2 Yard space

`resolveZone` (on zone change) reads `C_Map.GetMapWorldSize(zone.map)` through `pcall` and
`plain`, caching `zone.__W, zone.__H` (yards per normalized unit in x and y). If the call is
absent, fails, or returns non-numbers, `__W` stays nil and **positional layers are skipped
with one warning**, the same policy as the existing map-ID mismatch: "map scale unavailable
for map N - placed areas skipped". The editor shows the same message on its canvas.

`weightOf` for a circle:

```lua
local dx, dy = (px - a.x) * W, (py - a.y) * H
local d = sqrt(dx * dx + dy * dy)          -- yards
if d <= a.innerYards then return 1 end
if d >= a.falloffYards then return 0 end
return smoothstep(a.falloffYards, a.innerYards, d)
```

`polygonWeight(poly, falloffYards, px, py, W, H)`: parity is scale-invariant and stays in
normalized units; the edge-distance arithmetic multiplies `ex, wx` by `W` and `ey, wy` by
`H` before squaring, so `best` is in square yards and the band compares to `falloffYards`.
Two multiplies per edge; no allocation; the M8 figures are the expected order of magnitude
(the `/acost areas` re-run of section 9.3 was dropped with the addon).

`weightOf` dispatches: `a.subzone` → named; `a.x` → circle; `a.corners` → polygon; else rule.
`zoneNeedsPosition` returns true if any area has `x` or `corners`.

### 3.3 Cache invalidation

`layersFor` caches on `zone.__areas == zone.areas` identity. **The editor never mutates
`zone.areas` in place**: every edit that changes membership, priority, kind or gate replaces
`zone.areas` with a fresh table (copying the area records, which are small) and calls
`ns.refreshTarget(true)`. Value edits (contrast, brightness, gamma, a corner drag, a radius)
mutate the area record in place and call `ns.refreshTarget(true)` only - the sort is
unaffected. `ns.invalidateLayers(zone)` is exposed for the rare case that needs it (a
`Config.indoors` change in delivery 2).

### 3.4 Legacy radii

An area with `inner` / `falloff` and no `innerYards` / `falloffYards` is legacy. At
`resolveZone`, when `__W` and `__H` are known, it is converted **in place** to
`innerYards = inner * sqrt(W * H)`, `falloffYards = falloff * sqrt(W * H)` (the geometric mean
of the two axis scales; an exact conversion does not exist because the old radius was an
ellipse), the old fields are removed, and `__converted = true` is set so the editor can show
"radii converted from normalized units - check them". Example: the chapel forecourt's
0.0040 / 0.0200 become 11.3 / 56.7 yd on Elwynn. Config.lua already records those radii as
"A GUESS", so nothing precise is lost. When `__W` is unknown the legacy area is skipped along
with the rest of the positional layers.

### 3.5 Everything else unchanged

Priority order, the stable sort, the indoors rule, the ease, the write cap, the poll rate,
the combat flag, restore-on-logout, the instance suspensions, `/amb here` (which now prints
yards and, when the subzone is empty and a polygon is being drawn, offers "drop a corner
here" - section 6.6; its closing line no longer says "/reload or log out to write the file"
- the capture is saved, and on a regressed branch the line says so instead).

### 3.6 Binding, and the settings overlay

- **No `## LoadSavedVariablesFirst`.** Both DBs are bound inside the `ADDON_LOADED` handler
  in `Store.lua` (`X = X or {}`), never assigned at file scope, never aliased at file scope;
  the plugin's linter (`sv-file-scope-init`, `sv-file-scope-alias`) stays part of the gate.
  This is safe under either load order (§P.31), which is what protects the addon if
  Blizzard changes the default.
- **Settings are overlaid, never replaced.** `Settings.lua` and `Share.lua` take
  `local settings = Config.settings` at file scope and `defineKey` captures
  `settings.instances` / `settings.sharing` by reference. So `store.settings` is copied key
  by key into those existing tables (the `fillDefaults` shape, in the other direction), and
  `/amb set`, `/amb ignore` and the popup's "Never from this player" write both the live
  table and the store. `Config.settings` in `Config.lua` is now the **defaults**: a
  hand-edit there is read only for a key the store does not hold, and `/amb settings reset`
  (**Proposal**) copies the file's values back over the store. The listing's closing line
  becomes "saved for this character; Config.settings holds the defaults" on the normal
  branch, and the regressed text on the others.
- **The ignore list** (`sharing.ignorePlayers`) is in the store from delivery 1, since it is
  written by delivery 1's popup; `/amb ignore all` becomes the saved `sharing.accept = false`
  and says so, which closes DESIGN-settings-and-sharing.md's "cannot be built as asked" note.

---

## 4. Files and load order

```
Config.lua          baseline, limits, tuning, settings DEFAULTS, indoors rule; Config.zones = {}
Zones.lua           generated: Config.zones[...] = { ... } - the seed (1.2)
DynamicAmbiance.lua engine (3.1-3.4)
Settings.lua        overlay-aware (3.6)
Preset.lua          DA1 + DA2 parse, DA2 serialize, validate, describe, conflicts
Share.lua           writes revert[] on accept (1.4), ignore list to the store
Serialize.lua       the clean copier (store <-> live, 1.4); the Zones.lua generator (7.3,
                    regressed branch only); export bookkeeping
Store.lua           bind at ADDON_LOADED, seed / load / flush, settings overlay, revert,
                    the persistence marker and judgement (0.1), record caps (1.5)   (new)
UI/Theme.lua        the two theme tables and the accessor (7 keys used by delivery 1; the
                    picker and strings are delivery 3)
UI/Raster.lua       pure-Lua geometry: cursor mapping, scanline strips, band offsets
UI/Canvas.lua       map tiles, area drawing, handles, player dot
UI/MapOverlays.lua  generated overlay data (commit 7810e9b)
UI/Editor.lua       window, tabs, properties panel, tools, undo, export panel, and the
                    hidden Save-to-file panel for the regressed branch (7.2)
```

`SelfTest.lua`, `Probe.lua` and `ProbeUI.lua` are removed (User decision, 2026-09-25: remove
the probes completely; User decision, 2026-09-25: remove selftest and ambiancecost). The
marker and the persistence report live in `Store.lua` (`/amb status`, `/amb persistence
force`).

`UI/Raster.lua`, `Serialize.lua` and `Store.lua` contain no frame calls, so the headless
suite covers them directly (`Store.lua`'s event frame is the stub's). `UI/Canvas.lua` and
`UI/Editor.lua` are exercised by the stub's `CreateFrame` for structure (they must load,
register nothing that raises, and expose their command) and by the in-game checklist for
behaviour.

---

## 5. Editor window - structure

Opened by `/amb ui` (and `/amb ui zones`); also registered with
`Settings.RegisterAddOnCategory` as a canvas category holding one button "Open the editor"
(M7: present). Closed by the window's close button, Escape (`UISpecialFrames`, guarded with
`pcall` since it is FrameXML behaviour and unmeasured; if it fails the close button still
works), or `/amb ui` again.

**Frame:** `ButtonFrameTemplate` (M4: creates), title "Dynamic Ambiance", movable, clamped to
screen, strata `HIGH`. **Proposal** size: 1360 x 780 at UI scale; the canvas is drawn at the
art's native 1002 x 668 so at fit one canvas pixel is one art pixel (~3.5 yd on Elwynn). The
canvas zooms from fit (1x) to 4x and pans (section 6.2, added by feedback round 1).

**Tab strip** along the top: `Zones`, `Settings`, `Themes`, `Share`. Delivery 1 builds
`Zones`; the other three tabs are present but disabled with the tooltip "next delivery" so
the layout does not shift later. The `Zones` tab contains:

```
+--------------------------------------------------------------------------------------+
| Dynamic Ambiance                                                     [Zones] ... [x]  |
| Zone: [Elwynn Forest v]  [Go to my zone]   Tools: [Select][Polygon][Circle][Named][Corner here][Delete][Undo][Redo]  |
| +---------------------------------------------+ +----------------------------------+ |
| |                                             | | AREAS (this zone)                | |
| |          map canvas 1002 x 668              | |  p60  Hall of Arms     (by name)  | |
| |          fills, outlines, bands,            | |  p50  All interiors (global rule)| |
| |          handles, player dot                | |  p20  chapel forecourt (circle)  | |
| |                                             | |  p10  Northshire Valley (by name)| |
| |                                             | |  p10  pocket           (polygon) | |
| |                                             | | [+ named area]                   | |
| |                                             | |----------------------------------| |
| |                                             | | SELECTED AREA / ZONE / PRESET    | |
| |                                             | |  properties (section 6.3)        | |
| +---------------------------------------------+ +----------------------------------+ |
| under cursor: 0.4921, 0.4140  |  wins here: chapel forecourt (p20) w=0.63; pocket p10   |
| Saved - written to disk at /reload or logout.   previewing live in Elwynn  [Export][Import] |
+--------------------------------------------------------------------------------------+
```

**Export and Import at the bottom right (User decision, feedback-2 item 2).** The footer's
two buttons sit in the window's bottom right corner, under the right column: `Import`
against the right edge and, to its left, `Export` (normal branch) or `Save to file`
(regressed branch). Both are there on every branch. The right column ends above their row
(its message line included), the persistence line starts at the left edge, and the preview
note is one line between the two, so nothing overlaps; the window is fixed-size and scales
as a whole on a small screen, so the same holds at every size.

**The footer's first line is decided by the persistence state** (0.1), verbatim:

| State | Footer |
|---|---|
| `restart` | `Saved - written to disk at /reload or logout.` |
| `reload` | `Saved - written to disk at /reload or logout. Not yet verified across a restart on this build.` |
| `unverified` | `Saving not yet verified on this build - if this line is still here after a /reload, this build is not keeping saved settings. N unsaved zone(s): Save to file to keep them.` |

and the first of the two buttons reads `Export` on `restart` and `reload` and `Save to file`
on `unverified` (7); the second reads `Import` on every state (8.2). The `reload` row is the normal footer plus the one-line caveat of User
decision FQ2. "N unsaved zones" is the regressed-branch counter of 6.8.

The area list is a `UIPanelScrollFrameTemplate` of row buttons sorted by priority
descending (the order the engine applies them, top wins), each showing priority, name,
kind, and an indoors glyph (`in` / `out` / blank). The global indoors rule appears as a
read-only row so the stack is complete; it is edited in delivery 2.

**Theme hooks in delivery 1:** every colour and font the window uses comes from
`UI/Theme.lua`'s active table (`panelBg`, `panelBorder`, `text`, `textMuted`, `accent`,
`font`, `fontSize`, `priorityColors`). Delivery 1 ships only the Classic table, built from
the measured art (`Interface\DialogFrame\UI-DialogBox-Background`, `...-Border`,
`GameFontNormal:GetFont()` = `Fonts\FRIZQT__.TTF` 12). The picker and Modern come in
delivery 3 with no change to the callers.

---

## 6. Editor window - behaviour

### 6.1 Zone selection

- The dropdown (`UIDropDownMenuTemplate`) lists, in this order: the zone the player is in
  (from `GetZoneText`), every zone in `Config.zones`, then every zone on the current continent
  from `C_Map.GetMapChildrenInfo(C_Map.GetMapInfo(currentMapID).parentMapID)` (M2: 26 zones on
  1415, including Riverglades). Each entry carries its `uiMapID` and `name`.
- Selecting a zone loads its art (`MapHasArt` → `GetMapArtLayers` → `GetMapArtLayerTextures`
  for layer 1) into a pooled grid of textures sized from `layerWidth / layerHeight /
  tileWidth / tileHeight`, exactly as the M2 measurement did. A zone with no art, or a
  failed tile, shows a flat panel with the text "no map art for this zone - named areas
  still work" and disables the drawing tools.
- A zone not yet in `Config.zones` gets an entry created **only when the first area or value
  is added**, with `map` set to the selected `uiMapID`, `meta.name` = zone name, and
  `meta.author` stamped, `origin = "editor"`, and flushed to the store at once (6.10).
  Browsing creates nothing.
- The zone key used is the **`GetMapInfo(uiMapID).name`** for browsed zones; for the current
  zone it is `GetZoneText()`. If the two differ for the zone the player is standing in, the
  editor uses `GetZoneText()` and shows the map name as a note, because the engine matches on
  `GetZoneText()` (Authority). This mismatch is not expected but is not assumed away.

### 6.2 Coordinate mapping

`UI/Raster.lua`:

```
cursorToMap(canvas):   cx, cy = GetCursorPosition(); s = canvas:GetEffectiveScale()
                       nx = (cx / s - canvas:GetLeft()) / canvas:GetWidth()
                       ny = (canvas:GetTop() - cy / s) / canvas:GetHeight()
mapToCanvas(nx, ny):   px = nx * width, py = ny * height   (offset from TOPLEFT, y downwards)
yardsToPixels(yd):     yd * width / zone.__W           (== yd * height / zone.__H, section 0)
```

Coordinates are clamped to 0-1 when a click lands outside the art. Every corner is stored at
4 decimal places (the format's precision) at the moment it is placed, so what is drawn is
what is exported.

**Zoom and pan (feedback round 1, item 1; `design/ui/feedback-1.md`).** A view `{ zoom, ox,
oy }` sits between the two spaces: the art is drawn `zoom` times larger and shifted so the
zoomed art pixel `(ox, oy)` is at the canvas's top-left.

```
mapToView(nx, ny):   px = nx * width * zoom - ox,  py = ny * height * zoom - oy
viewToMap(px, py):   nx = (px + ox) / (width * zoom), ny = (py + oy) / (height * zoom)
yardsToPixels(yd):   yd * width * zoom / zone.__W
```

- **Zoom** runs from fit (1) to 4. The mouse wheel zooms about the cursor (the map point under
  it stays under it); visible `+`, `-` and `Reset` buttons over the canvas's top-right corner
  zoom about the centre and back to fit, with the zoom in per cent beside them. One step is
  x1.25. The art's measured `maxScale` is 2.14 (M2): past it the art may soften - accepted,
  not a cap.
- **Pan**: a left press on the map that is not on a handle or a shape is decided at release.
  If it moved less than 4 canvas pixels it is a click and goes to the active tool; if it moved
  further while zoomed it pans the map and places nothing. At fit there is nothing to pan,
  so every press there is a click. The circle tool's press-and-drag draws the circle, never
  pans (zoom out and in to move while it is active).
- **Clamp**: the offset is kept inside `[0, width * (zoom - 1)] x [0, height * (zoom - 1)]`,
  so the art always covers the canvas and a pan stops at the map's edge. A new zone starts
  at fit.
- **Everything drawn and every hit test goes through the view**: tiles, fills, outlines,
  bands, handles, the rubber band, the player dot. Reaches (handles, closing a shape, the
  click slop) are canvas pixels on screen, the same at every zoom.
- **Clipping**: every tile, strip and line is cut to the canvas rectangle arithmetically
  (`Raster.clipRect`, `Raster.clipSegment`; a tile's texture coordinates are cut to match
  through `SetTexCoord`), with the frame's `SetClipsChildren` kept as a second line. A tile
  wholly outside is hidden.

The view functions are pure (`UI/Raster.lua`) and tested headlessly at several zoom levels.

### 6.3 Properties panel

Three stacked sections; the one for the current selection is expanded.

**Preset (zone-level)** - `name` (`InputBoxTemplate`, 64), `description` (64), `notes`
(a multi-line text area about six lines tall that scrolls past that, 500), `version`
(integer box, auto-bumped per 1.3, editable), `author` and `date` (labels). Zone defaults:
three sliders (`OptionsSliderTemplate`) - Contrast 0-100, Brightness 0-100, Gamma
`Config.limits.gamma` - each with an **Inherit default** checkbox (`UICheckButtonTemplate`;
the label was "Inherit" until feedback round 1, item 5) that sets the value to nil and greys
the slider; a numeric box beside each slider for exact entry. `map` shown as a label.

**Area** - `name` (single line, 64), `notes` (a text area like the preset's, 200; feedback
item 7), kind (label), `priority` (the typed integer box, unchanged, and under it seven step
buttons `-10 -5 -1 0 +1 +5 +10`: each adds its value, `0` sets the priority to 0, kept
within the box's -999 to 9999; feedback item 6 - the old band buttons "feature 10",
"indoors 50", "room 60" are gone, the band colours on the map stay), **Applies** dropdown:
`anywhere / indoors only / outdoors only`, the same three sliders with Inherit default
boxes, and per kind: circle → **Inner (yd)** and **Fade (yd)** boxes (1 decimal, yards);
polygon → a corner count label and a **Fade (yd)** box; named → the subzone string
(editable, with the "seen this session" list as a dropdown - 6.6); rule → nothing further.

**Fade, not falloff (feedback items 10 and 11).** The UI never asks for `falloffYards`. It
asks for a **Fade**: how many yards past the shape its values take to fade out, measured
outward from the inner radius for a circle and from the edges for a polygon (which is
already how the engine measures a polygon's falloff). The stored format is unchanged:

```
polygon   falloffYards = fade                  fade = falloffYards
circle    falloffYards = innerYards + fade     fade = falloffYards - innerYards (0 if negative)
```

Changing a circle's inner radius (box or handle) keeps its fade, so the outer edge moves with
it; the "falloff has to reach the inner radius" error can no longer arise. The Fade box
names what it is measured from ("past the inner radius" / "past the edges").

**Refusals next to the field (feedback item 11).** A value a box refuses - a negative or
non-numeric Fade or Inner, a non-numeric priority, a version that is not a whole number, an
empty subzone - is shown in red beside (or under) the box that caused it, in a popup with an
`OK`, and under the panel as before. It clears on the next good value or a new selection.

**Slider bounds** come from `Config.limits` only. The Gamma slider carries tick labels at
`min`, `1.0`, `max` and two small hint marks at 0.7 and 3.0 labelled "usable by eye"; the
implementer reads the pair from `Config.limits.gamma` and must not hardcode it.

Edits apply immediately (3.3). A slider drag issues one `refreshTarget(true)` per value
change; the ease does the rest.

### 6.4 Drawing on the canvas

Each area gets, from pools: an **outline** (`CreateLine` per edge, thickness 2, the area's
priority colour), a **fill** (horizontal `SetColorTexture` strips, alpha 0.25 - the measured
0.4 was clearly visible, so a little lighter for stacking), a **falloff band** (thin lines at
alpha 0.5, offset outward), and, when selected, **handles**.

**Fill without a polygon primitive (Proposal).** `Raster.strips(shapePx, pitch)` rasterises
the shape into horizontal strips: for each scanline `y` at `pitch` spacing from the shape's
top to bottom, compute the x-crossings with every edge (even-odd), sort them (insertion sort
on a reused table - at most 32 crossings), and emit `[x_i, x_{i+1}]` runs as one texture each
of height `pitch`. A circle is rasterised the same way from its analytic half-width
`sqrt(r^2 - dy^2)`. `pitch` is `max(2, ceil(heightPx / 120))` so no shape ever uses more than
~120 strips; at 2 px pitch small shapes are visually solid, and a zone-sized polygon is
banded at ~5 px, which is acceptable for a translucent overlay. Strips are rebuilt only when
the shape changes; the fill can be toggled off by a checkbox above the canvas for busy zones.
Circle fill uses the inner radius; the falloff radius is drawn as a band line.

**Falloff band.** Because a yard is isotropic in canvas pixels (section 0), the band is a
uniform offset of `yardsToPixels(falloffYards)`. For a polygon: the signed area gives the
winding; each edge is shifted along its outward normal by the offset and drawn as a line
between the shifted endpoints; adjacent shifted edges are joined by a straight segment
between their nearest endpoints (a bevel, not a true arc - visibly fine at these sizes). For
a circle: a 32-segment line ring at the falloff radius. If the map scale is unknown
(`__W` nil), no band or fill is drawn and the canvas footer says why.

**Midpoint handles (feedback item 4).** A selected polygon also shows a small grey handle
at the middle of each edge that is at least three handle widths long on screen (a shorter
edge's midpoint would sit on its corners).

**Hint strip (feedback items 3 and 4).** Along the canvas's bottom edge, on a dark strip that
never takes the mouse: what the mouse does in the current state, and on a second line the
last refusal while drawing or reshaping (shown for 5 seconds, and also under the panel).

| State | Hint, verbatim |
|---|---|
| Polygon tool | Left click: place a corner. Right click: remove the last corner. Click any corner to finish. |
| Circle tool | Left click and drag: place the centre and pull out the inner radius. Then set Fade (yd) and press Finish. |
| A polygon selected | Drag a corner to move it. Click or drag an edge's middle handle to add a corner. Right click a corner to remove it. |
| Zoomed in, nothing else | Mouse wheel or + / - to zoom. Drag the map to move around. |

**Priority colours.** `priorityColors` in the theme maps the band ranges to colours
(**Proposal**: 0-19 blue, 20-49 green, 50-59 amber, 60+ red, chosen so the shipped bands
read distinctly; a theme may change them). The selected area's outline is drawn white on top.

**Under cursor readout.** On mouse move over the canvas, the footer shows the normalized
position and, computed by calling `ns.weightOf` for every *placed* area at that point
(indoors treated as unknown - both gated states listed), the areas with weight > 0 in
priority order, highest first labelled "wins here". Named subzones and the indoors rule are
listed as "cannot be located on the map". This is the priority-stack rendering IDEAS.md
idea 3 asks for.

**Player dot.** A small texture at the player's position, updated from the engine's
`state.px, state.py` when the editor shows the player's current map (no extra reads), or
from one `C_Map.GetPlayerMapPosition(editorMapID, "player")` per poll when it does not (it
returns nil off-map, in which case the dot hides). Reads happen only while the window is
shown.

### 6.5 Tools

| Tool | Interaction |
|---|---|
| **Select** | Click an area's fill or outline to select it (hit test arithmetic, through the view). Drag the body to move the whole shape (all corners or the centre shift by the cursor delta, clamped to 0-1). Drag a corner handle to move that corner; drag a circle's inner handle to change `innerYards` (the fade rides along, so `falloffYards` moves with it), its band handle to change `falloffYards`. **Edit polygon (feedback item 4):** on a selected polygon, click or drag an edge's midpoint handle to insert a corner there (dragging moves the new corner); right-click a corner to delete it. Deleting is refused at 3 corners and inserting at the 32-corner cap, each with the reason on the canvas. Each insert or delete is one undo step (an insert and its drag together). Right-click anywhere else deselects; a press on empty map pans when zoomed and deselects when it is a click. |
| **Polygon** | Click places a corner; a rubber-band line follows the cursor to the next click. **Clicking any corner already placed** closes the shape exactly as Finish does, once it has >= 3 corners (feedback item 2; this also covers a double-click); with fewer, the click is refused on the canvas instead of stacking a corner. Enter or **Finish** closes too. Right-click removes the last corner; Escape cancels the drawing. A new polygon gets Fade = `Config.editor.defaultFadeYards` (5 yd, below), priority 10, values inherited, name "area N". Corners are placed at the mouse's release, so a drag can pan instead (6.2). |
| **Circle** | Click the centre, drag to set `innerYards`; Fade starts at the same default, on top of the inner radius (`falloffYards = innerYards + 5`). |
| **Named** | Adds a named area with the current `GetSubZoneText()` prefilled (or empty, editable) - 6.6. |
| **Corner here** | While a polygon is being drawn or selected, appends a corner at the player's current normalized position on this map (from `state.px, state.py`; disabled if the player is not on the editor's map or the read is nil). The "walk and drop" path from interview-1. |
| **Delete** | Deletes the selected area, after the confirmation popup (three-button `StaticPopup` is measured; this one needs two). |
| **Undo / Redo** | A session stack of area-list snapshots (the area records are small; a snapshot is a shallow copy of `zone.areas` plus copies of the records touched). Unbounded within the session (**Proposal**; memory is negligible at these sizes). |

**Default fade for a new shape: 5 yards. Closed** (was TBD). **User decision** at the
delivery 1 acceptance run, 2026-09-24, operator verbatim: "default fade yard should be 5"
(`design/ui/feedback-1.md`). It is `Config.editor.defaultFadeYards` in `Config.lua`, with that
provenance in its comment. The Fade box of every new shape is pre-filled with it, so there
is no required field; only a box the player empties or fills with something that is not a
number of 0 or more stops Finish, with the reason beside the box and in a popup.

### 6.6 Named areas and subzones seen

The engine records every distinct `GetSubZoneText()` value per zone into
`ns.seenSubzones[zoneName]` (a set; allocation only on a new name). The Named tool's
dropdown lists them, so a player who has walked Darkshire once can add "Darkshire" without
typing it. `/amb here` keeps printing the paste-ready entry as well - it is the same data.

### 6.7 Live preview

Editing mutates the live tables, so the engine previews by construction (the Share.lua
mechanism generalised). The window's footer says `previewing live in <zone>` when the
player is in the edited zone, and `you are in <X>; edits to <Y> will not show until you are
there` otherwise. A half-drawn polygon (< 3 corners) weighs 0, so drawing never flickers the
screen. There is no "apply" step and no separate working copy.

### 6.8 Origins, and the counter that exists only on a regressed build

Each zone carries `origin` (saved, 1.4): `"seed"`, `"editor"`, `"import"` (Share.lua sets
it on accept). Areas carry the same field, for the properties panel's "from" label.

**On the normal branch there is no dirty state.** Every edit is saved as it is made (6.10),
so there is no unsaved counter, no `*` in the title bar, no popup on close, and no recovery
draft. Closing the window closes it.

**On a regressed branch** (`unverified`; `reload` is normal, User decision FQ2) revision 1's
machinery returns unchanged
(User decision, answers-2 Q7 and FQ1): `__dirty = true` on any change, the footer's counter,
the `*`, the close popup "You have N unsaved zones. <state line> Open Save to file?" with
`Save to file` / `Close anyway`, and the **recovery copy**: on every dirty change the editor
writes the current generated Zones.lua text (7.3) into `DynamicAmbianceDB.editor.draftLines`,
one string per line, with a timestamp and a `where` note, so a forgotten save can be copied
out of `WTF\Account\<account>\SavedVariables\DynamicAmbiance.lua` by hand (the Account
folder, **not** `WTF\SavedVariables\` - feedback-1 item 9, unchanged: long-bracket strings so
no line holds a `"` for the client to escape). `<state line>` is "Saving is not yet verified
on this build - they may be lost at /reload." (**Decision, designer:** the 69977 text "They
are lost at /reload" claims more than `unverified` knows). The `reload` state never raises
this popup (User decision FQ2).

**Merging seed zones and edits.** There is no merge step, by construction: the store is
loaded into `Config.zones` at `ADDON_LOADED`, the editor edits that table, and every edit is
flushed back. The only conflict possible is an import (Share.lua) landing on a zone with
edits, which is already handled by the existing confirmation's "this REPLACES your Duskwood"
warning; delivery 4's "add alongside" gives the other answer.

### 6.9 Combat hides the window (feedback round 1, item 12)

On `PLAYER_REGEN_DISABLED` (registered through `ns.register` on the editor's existing event
frame, which already drops the keyboard there) the window hides if it is open, and one chat
line says why: "the editor is hidden while you are in combat - it comes back when combat
ends." This hide is not a close: the shape being drawn, the selection, the tool, the panel
and the zoom and pan are all kept, the unsaved-zones popup is not raised, and only a gesture
in flight (whose mouse-up will never arrive) is dropped. On `PLAYER_REGEN_ENABLED` the window
comes back as it was, with the drawing keyboard if a polygon is still being drawn. Opening
the editor during combat (`/amb ui`, the options button) says it opens when combat ends,
and does. A window the player closed stays closed. The editor frame is not protected, so
hiding it in combat is allowed; this is the operator's choice, not a client restriction.
The 7e8f92a keyboard rules are unchanged underneath it.

### 6.10 Saving and reverting (User decision, answers-2 Q2 option 3)

- **Automatic.** Every edit that `afterEdit` sees - an area added, deleted or reordered, a
  value changed, a corner dragged, a slider released, metadata typed, undo, redo, an accepted
  import - calls `Store.flushZone(name)`, which writes the clean copy of that zone into
  `store.zones[name]` (1.4). A zone deleted from `Config.zones` (undo of its creation, or
  **Delete zone**, below) is removed from the store. The flush is the retargeted `flushDraft`:
  same trigger points, a table instead of lines. A slider drag flushes once per value
  change; the copier touches only the zone being edited (a few hundred bytes), so no rate
  limit is needed (**Proposal**; if a drag ever shows a hitch, coalesce to the drag's release).
- **Written to disk by the client at `/reload` or logout** (Authority, 0). The footer says
  so (5). There is no call to flush earlier, so a crash loses the session's edits on every
  branch; the design does not pretend otherwise.
- **Revert to last export.** A button in the Preset section of the properties panel, labelled
  exactly `Revert to last export`, with the tooltip `Last export: v3, 2026-09-25 14:24` (User
  decision, feedback-2 item 3: the version and time moved from the label, which ran too
  long, into the tooltip, in the same values and format). Enabled only when
  `store.revert[name]` exists; disabled with the tooltip "never exported" otherwise. Pressing
  it asks (two-button
  `StaticPopup`: "Put <zone> back to the string exported on <when>? Every change since is
  lost.") and then runs the stored DA2 string through `Preset.parse` → `Preset.validate` →
  replaces `Config.zones[name]` (a fresh table, so the layer cache re-sorts, 3.3) → flush →
  `refreshTarget(true)` → one undo step, so even a revert can be undone within the session.
  The version is left as the string carries it. On a regressed branch the button works the
  same and the zone becomes dirty.
- **Delete zone** (**Proposal**, new): a button in the Preset section, after the delete-area
  confirmation's pattern ("Delete <zone> and its N areas?"), removing the zone from
  `Config.zones`, the store and `store.revert`, as one undo step. Without it a seeded zone
  the player does not want could only be emptied, and Q1 option 3 made deletion final.
- **Undo and redo** are unchanged: a session stack of snapshots, each restore followed by a
  flush.

---

## 7. Export, and Save to file on a regressed build

**User decisions (answers-2 Q3, Q4, Q7, FQ1).** On the normal branch the editor has an
**Export** panel that produces preset strings, one zone at a time, and nothing else: the
Zones.lua export is gone from what a player can reach. The whole 69977 copy-paste flow - the
Save to file panel, its steps, its two popups and the line-by-line recovery draft - stays in
the code, unreachable on the normal branch and shown on a regressed one exactly as delivery 1
built it (7.2). The generator behind it (7.3) is kept for that, and for the shipped
`Zones.lua`'s own regeneration in the repo.

### 7.1 Export panel (normal branch)

Reached by the `Export` button (footer), by `/amb ui export`, and by `/amb ui save` (kept as
an alias, because it is in the README and in muscle memory; on a regressed branch the same
command opens 7.2). It replaces the properties panel's column with: one line of text - "A
preset string carries one zone: its values, its areas and its notes. Anyone with the addon
can paste it into their import box." - a zone dropdown defaulting to the zone being edited,
a `UIPanelScrollFrameTemplate` holding a multi-line edit box with `SetMaxLetters(0)`
containing that zone's DA2 string, one line under the box (below), `Select all`
(`SetFocus`, `HighlightText`) and `Back`. No popup: there is nothing the player must do.
The import box is not here: Import is its own panel (User decision, feedback-2 item 4; 8.2).

**Copy to clipboard (User decision, feedback-2 item 5).** Pressing the footer's `Export`
also tries to put the string on the clipboard. `CopyToClipboard` exists on this client but
is flagged `HasRestrictions` (`SecretArguments = AllowedWhenUntainted`), and whether an addon
may call it from a click is unmeasured (11), so it is a guarded attempt:

- It is called only from the `Export` button's click (a hardware event), never from
  `/amb ui export`, `/amb ui save`, the dropdown or `Select all`, and always inside `pcall`.
- While it runs, and for one second after, `ADDON_ACTION_BLOCKED` and
  `ADDON_ACTION_FORBIDDEN` naming this addon (or naming `CopyToClipboard`) are watched, the
  way the since-removed self test watched its CVar writes.
- It counts as copied only when it did not raise, no such event arrived, and it returned a
  positive length. A refusal that arrives within the second after the call turns a
  "copied" into "blocked".
- The outcome is kept per build in `DynamicAmbianceDB.clipboard[<build>]` (`outcome` =
  `copied` / `raised` / `blocked` / `zero` / `absent`, `detail`, `length`, `when`). On a
  build whose outcome is anything but `copied` it is not tried again, so a refusal costs one
  "interface action failed" and not one per export.
- The line under the box reads `Copied to clipboard` while the box holds the string that
  was copied, and `Select all -> Ctrl+C` otherwise: whenever the copy failed, was not
  tried, or the box has since changed.
- `/amb status` reports the recorded outcome for the build (its `clipboard:` line; this was
  `/amb probe`'s section 6 until User decision, 2026-09-25: remove the probes completely). It
  never calls `CopyToClipboard`, because a script call is not a click.

The string is rebuilt when the panel opens, when the dropdown changes and when `Select all`
is pressed, so the box is never stale; each rebuild is an export (1.3: the version bumps if
the zone changed since its last export; `store.revert[name]` is written, 6.10). The file
path box, the `Preset string` dropdown and the Zones.lua text of revision 1 are not here.

### 7.2 Save to file (regressed branch only)

On the `unverified` state (0.1; `reload` is normal and never shows this panel, User decision
FQ2) the footer button reads `Save to file` (with `Import` beside it, as on every branch:
User decision, feedback-2 item 2), `/amb ui save` opens this panel instead of 7.1, and the panel is revision 1's, unchanged in
layout: the explanation text (7.2.1), the multi-line box containing the generated
`Zones.lua` (7.3), `Select all`, the file path box, a `Preset string` dropdown that switches
the box to one zone's DA2 string, and `Back`; only its note line moved, from under `Back` to
beside it, so a long one stays clear of the footer's buttons (feedback-2 item 2). Select all
clears the dirty counter (6.8), as
before. The panel is built lazily and only when the state calls for it, so a normal build
never creates its frames.

**The popup (feedback round 1, item 8; kept on this branch by answers-2 Q7).** Opening Save
to file by its button, by `/amb ui save`, or by the unsaved-zones popup's `Save to file`
also raises a one-button popup over the window, verbatim: "Your changes are not saved yet.
Read the steps on the right of the editor to save them to file." with `OK`. The steps panel
is already open behind it. On a client without `StaticPopup` the same words appear on the
canvas's notice line instead.

#### 7.2.1 Exact wording

Title: **Save to file**

Body: the 69977 text (User decision, answers-1 Q2) verbatim from "So today" onward; only
the first paragraph is replaced, because its claims about the bug tracker are no longer
what is true (**Decision, designer:** FQ1 said "exactly as delivery 1 built them", and a
paragraph that states a false reason is not that). The first paragraph, for `unverified`
(the only state that shows the panel, User decision FQ2):

> **Why you have to do this step yourself, on this build.**
> This addon has not yet seen World of Warcraft: Forever read its saved
> settings back on this build. Saving worked on build 70009; a later build may have
> stopped, or this may be your first login - a /reload tells: if the footer still says "not
> yet verified" afterwards, this build is not keeping saved settings, and everything you draw
> here needs the steps below.
>
> **So today, saving is a copy and paste:**
> 1. Click **Select all**, then press **Ctrl+C**.
> 2. Open this file in a text editor:
>    `<install folder>\Interface\AddOns\DynamicAmbiance\Zones.lua`
> 3. Replace **everything** in that file with what you copied, and save it.
> 4. Type **/reload** in the game.
>
> **This is automatic on a build that reads saved settings back.** The addon saves your
> work on every change and checks at every login whether the game loads it again; when it
> does, this panel goes away and nothing you pasted here needs to be redone.
>
> Small print: if you forgot to save before a /reload, the last draft is in
> `WTF\Account\<your account>\SavedVariables\DynamicAmbiance.lua` under `editor.draftLines`,
> one line of Zones.lua per entry - copy the lines from there. That is the Account folder
> inside WTF, not `WTF\SavedVariables\`, which does not have it.

(The small print was changed by feedback round 1, item 9: it used to say `<WTF path>` and
`editor.draft`, and the operator looked in the wrong folder.)

`<install folder>` is not known to the addon (no file API); the panel prints the literal
`Interface\AddOns\DynamicAmbiance\Zones.lua` and the line "in your World of Warcraft: Forever
folder". The account name is not known either, so it prints as `<your account>`.

### 7.3 The generator (`Serialize.lua`) - regressed branch, and the repo's own seed file

`Serialize.zonesFile(zones, when, addonVersion)` returns the complete `Zones.lua` text. On
the normal branch nothing calls it from the UI; it serves 7.2 and the recovery draft (6.8)
on a regressed branch, and it is how the shipped seed file is regenerated.

- Header comment as in 1.2, with the generation time and addon version (from
  `C_AddOns.GetAddOnMetadata` if present, else the `.toc` value hardcoded in one place), now
  reading: "Dynamic Ambiance - zones. GENERATED by the in-game editor, <when>, addon <v>.
  Read once, on a character's first login, to seed its saved zones; after that the
  character's saved settings are the zones and this file is not read - except on a build
  that does not read saved settings back, where it is read at every load. Config.lua holds
  everything that is not a zone."
- The store's `origin` and `export` fields (1.4) are never written: they are not in the
  field lists.
- `local _, ns = ...` / `local Config = ns.Config` / `Config.zones = Config.zones or {}`.
- One `Config.zones[%q] = { ... }` block per zone, zones sorted by name, areas in their
  current order (the file order is the tiebreak for equal priorities - Authority - so it is
  preserved exactly).
- Field order fixed: `contrast, brightness, gamma, map, meta = {...}, indoors, areas = {...}`;
  area fields in the order of 1.1. `nil` fields are omitted. Strings via `%q`. Numbers via
  Preset.lua's `num()` with the same precisions as DA2. `corners` on one line per 4 pairs.
- Keys starting `__` skipped. `meta.notes` and area `notes` emitted as strings (`%q` keeps
  newlines escaped, which is fine; the editor's box shows them unescaped).
- A trailing comment: `-- end of generated zones`.

The result must load under the headless stub and reproduce `Config.zones` field-for-field
(9.1). `Serialize.presetString(zoneName)` is `Preset.serialize` (DA2).

---

## 8. Import, export and sharing in delivery 1

### 8.1 Export

The export panel (7.1) and `/amb export [zone]` both emit DA2, and both are exports in 1.3's
sense: the version bumps if the zone changed, `store.revert[name]` is written (6.10), and the
string is logged to `DynamicAmbianceDB.exports` (capped, 1.5). `/amb export` keeps printing
to chat; the panel is the way to copy it. `/amb export`'s closing line "Also written to
SavedVariables - /reload or log out to get it out of the file" goes; on every branch the
string is in the box.

### 8.2 Import

`/amb import <string>` keeps working. It is limited by the chat edit box's own maximum
(unmeasured here; retail's is 255 characters, which a DA2 string exceeds easily).
The footer's `Import` and `/amb ui import` open the **Import panel**, its own panel in the
right column on every branch, apart from Export (User decision, feedback-2 items 2 and 4),
focused on its box: the line "Paste a preset string below and press Import. The
confirmation that follows previews it live on your screen; Decline puts everything back.
Importing replaces the zone it names, areas and all." (no format is named: User decision,
feedback-2 item 6 - DA1 still parses, 2.2, but nobody has a string in it, so neither this
line, the parse refusal nor the chat's conversion notice names it), a multi-line paste
box, an `Import` button that runs `Preset.parse` → `ns.offerPreset` (the existing
confirmation with live preview, three buttons, replace-only; **Q6's Replace / Add alongside
arrives in delivery 4**), and the parse error printed beside the box on failure. An accepted
import is flushed to the store (6.10) and its string becomes the zone's revert point (1.4);
Share.lua's line "this lasts until you /reload ... this client is not known to read
SavedVariables back" becomes "saved for this character" on the normal branch and the
state's own line on a regressed one. On a regressed branch it is the same Import panel.

### 8.3 The paste cap

`Preset.MAX_LENGTH` = 4000, measured (M5: 4000 pasted and copied intact both ways; not a
ceiling). The import box's `SetMaxLetters(0)` accepts more, and a longer paste is refused by
`Preset.parse` with "N bytes is over the 4000 cap - the most this build has been measured to
paste intact". Raising it is a measurement, taken only if a real preset is refused: paste
8000 and 16000 characters from Notepad into the multi-line box, read `#GetText()`, record in
`measurements/`, and move the constant with the provenance in its comment. The same run
records `ChatFrame1EditBox:GetMaxLetters()` (through `pcall`) to document why `/amb import`
is limited.

### 8.4 The wire

Not in delivery 1. Section 10.3.

---

## 9. Test plan

### 9.1 Headless (`luajit tests/run.lua`, also 5.4)

Format:
- DA2 round trip for a zone with all four area kinds, metadata with every escapable
  character in every string field, empty numeric fields, and a 32-corner polygon; equality
  field-for-field after parse.
- DA1 string parses; `p` areas convert to yards with the stub's 3470.83 x 2314.62 size
  (geometric mean) and carry the converted tag; with the size call stubbed out they stay
  legacy.
- Refusals name the field: unknown kind, polygon with 2 pairs, 33 pairs, a coordinate of 1.2,
  falloff < inner (yards), gamma 50 and gamma 0.1 (outside `Config.limits.gamma`, refused
  not clamped, message names the screen range), version "-1", notes over cap, a 4001-byte
  string (cap), a truncated string (checksum), a `DA3` marker.
- Gamma at exactly 0.3 and 3.0 validates; a `Zones.lua` value of 3.5 is clamped at
  `resolveZone` with one warning and never written.
- `Preset.describe` and `Preset.conflicts` cover polygons (bounding-box overlap) and report
  "not checked" when the scale is unavailable.

Engine:
- `evaluate` returns three values; gamma inherits baseline → zone → area; an area that sets
  gamma only leaves contrast and brightness untouched.
- Circle weight in yards on the non-square stub: a point 20 yd east and a point 20 yd south
  of a centre get the same weight (which the old normalized maths would not give).
- Polygon weight with `W ~= H`: inside 1, on an edge 1, at `falloffYards / 2` outside a
  vertical edge and a horizontal edge the same weight, beyond falloff 0; concave notch
  outside; ray through a vertex counted once (existing tests, extended with the scale).
- Legacy conversion at `resolveZone`: `inner/falloff` replaced by yards, `__converted` set,
  and the area skipped with one warning when `GetMapWorldSize` is absent.
- `layersFor` re-sorts after the editor replaces `zone.areas`; does not re-sort on a value
  edit (identity check).
- Ease and write for three CVars: the gamma epsilon is derived from `Config.limits.gamma`;
  no Gamma write occurs in a session whose zones never set gamma beyond the login write;
  restore on logout writes all three baselines; `/amb off` eases all three; `/amb try 60 40
  0.9` holds three.
- `evaluate` still allocates nothing with polygons present (the existing allocation assertion
  extended to a fixture with polygons and circles).
- `ns.seenSubzones` records each distinct subzone once per zone.

Serialize:
- `Serialize.zonesFile` output loads via `loadstring` with a stub `...` and reproduces the
  input table field-for-field (including area order, `nil` omission, `__` and `origin` /
  `export` skipping, notes with newlines and quotes); round trip is idempotent (generate →
  load → generate is identical text).
- Version bump: a zone with `export.pending` bumps once per generation, a clean zone does
  not, a manual version edit is respected, and the bookkeeping survives a store round trip
  (edit, flush, reload the store into a fresh `Config.zones`, export: bumps once).
- The clean copier: live → store → live reproduces every 1.1 field, drops every `__` key,
  never writes the same area table twice, and leaves the live table's caches untouched.

Store (`Store.lua`, under the stub's `ADDON_LOADED` / `PLAYER_ENTERING_WORLD`):
- **Seed.** Empty store + `Config.zones` from the seed file: after `ADDON_LOADED` the store
  holds every zone field-for-field with `origin = "seed"`, `store.seed.checksum` equals
  Fletcher-16 over the sorted DA2 strings, and `Config.zones` is unchanged. The operator's
  installed `Zones.lua` (Elwynn v2, forecourt moved, "area 4", "area 5") is a fixture and
  must come through intact.
- **Load.** Seeded store whose zones differ from the file's: after `ADDON_LOADED`
  `Config.zones` equals the store's zones, a file-only zone is gone, a store-only zone is
  present, and the layer cache is rebuilt for each (identity changed).
- **Never replace the tables.** `Config.settings`, `.instances` and `.sharing` keep their
  identity across the overlay; `Settings.lua`'s `KEYS` entries still point at live tables;
  `/amb set dungeon off` writes the store; the ignore popup's third button writes
  `store.settings.sharing.ignorePlayers`.
- **Flush.** Each `afterEdit` path (add, delete, value, corner, metadata, undo, redo, accept
  an import, revert) leaves the store equal to the clean copy of the zone; deleting a zone
  removes it and its revert entry.
- **Revert.** Export, edit, revert: the zone equals the exported state, the change is one
  undo step, and `refreshTarget` was called; a zone with no revert entry refuses with the
  reason; an accepted import creates a revert entry.
- **Persistence judgement**, one case per rule of 0.1's table and one per sequence below,
  with the stub supplying the marker, the build string and the `PLAYER_ENTERING_WORLD`
  arguments: nil → `unverified`; restored on `login` → `restart`; restored from another
  build, kind unknown → `restart`; restored on `reload` with `best = unverified` → `reload`;
  **restored on `reload` with `best = restart`, same build → `restart`** (the working-build
  reload case); restored with unknown kind and unknown build, `best = restart` → `restart`;
  restored with unknown kind and unknown build, no `best` (a marker written by revision-1
  code) → `reload`. Sequences, each load's marker fed to the next: working build from a
  fresh install (`nil, reload, reload, login, reload` → `unverified, reload, reload,
  restart, restart`); a patch on a working build (`login` with the previous build's marker
  → `restart` on the first load); a reload-only build (`nil, reload, nil, reload` →
  `unverified, reload, unverified, reload`, never `restart`); a `none` build (`nil` every
  load → `unverified` every load). The marker written after each load carries `arrivedNil`,
  `loadKind`, `build` and `best`, and `best` never decreases on one build.
- **Regressed re-seed.** State `unverified` with the store arrived nil: seeded from the file
  at `ADDON_LOADED`, checksums equal, nothing replaced. State `unverified` over a restored
  store (a character file that came back without a marker) whose seed checksum differs from
  the file's: the store's zones are replaced by the file's, the seed record updated,
  `refreshTarget` called. States `restart` and `reload` (User decision FQ2), file different:
  ignored, the store kept.
- **Caps.** Appending a 21st capture / import / export keeps the newest 20.
- **Retired keys.** `probe`, `probeUI`, `probeGamma`, `probeInstances` and `selftest` on
  either DB are gone after `ADDON_LOADED`; the markers, the store, `clipboard`, `mapcheck`
  and the record lists are kept. `/amb probe` and `/amb selftest` answer "unknown".
- **Report and hook.** `/amb status` prints the state, this load's number and build, whether
  each marker came back, and the clipboard line; `/amb persistence force <state>` sets,
  reports and clears the override, refusing an unknown state.
- **Schema.** A store with `schema = nil` is read (no upgrade exists yet) and written back
  with `schema = 1`.

Branch-dependent UI, under the stub with the state forced to each value:
- `restart` and `reload` (User decision FQ2): the footer text of section 5 (on `reload`
  with its caveat line); the button reads `Export`; `/amb ui save` opens the export panel;
  no Save-to-file frames exist; closing with edits raises no popup; no `editor.draftLines`
  is written; no login line.
- `unverified`: the footer text of section 5 with the counter; the button
  reads `Save to file`; `/amb ui save` opens 7.2 and the "not saved yet" popup; closing with
  dirty zones raises the unsaved popup with the state's line; `draftLines` is written on
  each change and loads as a `Zones.lua` equal in content to the panel's.
- Every state (User decision, feedback-2 items 2 and 4): the footer holds `Import` and the
  first button, anchored bottom right, the first left of `Import`; the properties column and
  its message line end above their row; `Import` and `/amb ui import` open the Import panel
  with its box focused and the Export panel hidden; the Export panel has no import box; the
  first button opens Export (normal) or Save to file (regressed), and `/amb ui export` opens
  Export on the regressed branch too. A `DA3` refusal and the import text name no DA1
  (item 6), nor does the chat when a DA1 string is imported.

Revert label (User decision, feedback-2 item 3): the label is exactly `Revert to last
export` before and after an export; the tooltip is "never exported" (button disabled)
before, and `Last export: v<version>, <when>` from the revert entry after.

Clipboard (User decision, feedback-2 item 5), `CopyToClipboard` stubbed:
- Returns the length: the footer's `Export` click copies the box's DA2 string with
  `removeMarkup = false`, the note reads `Copied to clipboard`, the build's record is
  `copied` with the length, a second click copies again; `/amb ui export` does not call it;
  a changed box shows the instruction; `/amb status` prints the outcome.
- Raises: recorded `raised` with the error, the instruction shown, not called again on the
  build, called again on another build.
- Fires `ADDON_ACTION_BLOCKED` naming this addon during the call and returns: recorded
  `blocked`, the instruction shown, not called again.
- A refusal naming another addon and another function does not count; one naming this addon
  just after the call turns `copied` into `blocked`; after the watch window it is ignored;
  no function is `absent`; a return of 0 is `zero`.

Raster (pure functions):
- `cursorToMap` / `mapToCanvas` invert each other; clamping at the edges.
- `strips` of a square: every strip lies inside; strip count = height / pitch; a point inside
  the square is covered by exactly one strip and a point outside by none; a concave polygon's
  notch produces two runs on its scanlines; a circle's strips are symmetric.
- Band offset points lie outside the polygon (weight 0 at slightly more than the offset,
  inside at slightly less) for both windings.
- Pitch rule: a 668-px-tall shape yields <= 120 strips.

UI structure under the stub:
- `UI/*.lua` load with the stub's `CreateFrame` and templates (add the eight measured
  templates to the stub's template set; an unknown one must raise, as measured); `/amb ui`,
  `/amb ui export`, `/amb ui save`, `/amb ui import` dispatch; the window is not shown at
  load; the editor never mutates `zone.areas` in place (assert identity changes on
  add/delete/priority edit and not on a value edit).

Shipped config structural test: `Zones.lua` loads after `Config.lua`, defines the Northshire
set with radii in yards or as legacy (either is legal), every area validates, and the file's
header names it as the seed.

Load-order gate: the plugin linter reports no `sv-file-scope-init` / `sv-file-scope-alias`
over `addons/DynamicAmbiance`, and the `.toc` carries no `LoadSavedVariablesFirst`.

### 9.2 Self test additions - removed

**User decision, 2026-09-25: remove selftest and ambiancecost.** `/amb selftest` no longer
exists, so its Gamma lines are not run.

### 9.3 Cost - removed

**User decision, 2026-09-25: remove selftest and ambiancecost.** `/acost` no longer exists;
the yard-scaled polygon re-run, the editor phase and the third `SetCVar` in the write bench
are dropped with it. M8 stays the cost record.

### 9.4 In-game acceptance checklist (delivery 1)

Northshire, level-1 safe, with the shipped test set. Each step names the eye check.

1. `/reload`; banner prints three client values including Gamma. (The `/amb selftest` half
   of this step is gone: User decision, 2026-09-25: remove selftest and ambiancecost.)
2. `/amb ui` opens on Elwynn Forest; the map is visible; the four shipped areas appear in the
   list in priority order; the chapel forecourt shows as a circle with a band and "radii
   converted" in its properties (if shipped as legacy).
3. Hover the canvas: the footer's readout changes; over the forecourt it names the forecourt
   as the winner among placed areas.
4. Polygon tool: draw four corners around the chapel forecourt, close it, enter a falloff.
   Fill, outline and band are visible. Walk into it: the screen eases to its values; walk out
   through the band: gradual. `/amb debug` shows the target change.
5. Select the polygon, drag a corner; the fill re-rasterises; walk to the moved edge and the
   boundary has moved with it.
6. Set the polygon's Gamma to a value inside the eye range while standing in it: the screen
   changes; Inherit puts it back.
7. Corner here: stand in the unnamed pocket (Config.lua's purple), draw a polygon by walking
   its edge and pressing `Corner here` four times, close it. Walk out and in.
8. Priority: set the new polygon to 60 and the forecourt to 10; the list reorders; the
   readout's winner changes; standing in the overlap the screen follows the new winner.
9. **Migration** (first login on the new build with the operator's installed `Zones.lua`):
   the footer reads `Saved - written to disk at /reload or logout.` (the marker from the
   previous load came back on a login load); `/amb ui` shows Elwynn at version 2 with the
   moved forecourt, "area 4" and "area 5"; `/amb status` prints `persistence: restart,
   judged on build 70009`. The WTF character file holds `store.zones["Elwynn Forest"]` after
   the first `/reload`.
10. **Save in place:** draw a polygon, `/reload`; it is still there **and the footer still
    reads the `restart` line, the button still reads `Export`, and no popup appeared** (the
    marker carried `best = restart`). `/quit`, relaunch, log in: still there. Versions did
    not change. The chat line at login says nothing about persistence.
11. **Revert:** `Export` on Elwynn, copy nothing, `Back`; the button reads exactly `Revert
    to last export` and its tooltip `Last export: v<n>, <date> <time>` (feedback-2 item 3);
    move a corner; `Revert to last export`; the corner is back; Undo brings the move back. A
    zone never exported shows the button disabled with "never exported" in its tooltip.
12. **Delete zone:** create a zone in a browsed map, add one area, `Delete zone`, confirm;
    `/reload`; it is gone; Undo before the reload brings it back.
13. **Fresh alt:** log a second character in: its editor shows the repo's `Zones.lua`
    zones (the seed), not the first character's polygon; export the polygon's zone on the
    first, import on the second, accept: now it has it, and `/reload` keeps it.
14. **Settings:** `/amb set dungeon off`, `/reload`; `/amb settings` still shows it off and
    says "saved for this character". `/amb ignore Somebody`, `/reload`, `/amb ignore list`
    still lists them.
15. **Export and import:** `Export` and `Import` sit at the window's bottom right, clear of
    the properties column and the footer text (feedback-2 item 2). Export the zone as a DA2
    string from the Export panel, which has no import box; the footer's `Import` (or `/amb ui
    import`) opens a separate Import panel with the cursor in its box and no mention of DA1
    (items 4, 6); paste the string; the confirmation appears with live preview; Decline
    restores; Import replaces and the version comparison line is right.
16. **Regressed branch, simulated:** with `/amb persistence force unverified`
    (**Proposal:** a test-only override, session-scoped, printed loudly in the banner) the
    footer changes to the `unverified` text, the button reads `Save to file` with `Import`
    still beside it and opening the Import panel (feedback-2 item 2), the panel shows
    the steps and the "not saved yet" popup, closing with a change raises the unsaved popup,
    and `editor.draftLines` appears in the WTF file after `/reload`. `force reload` shows the
    normal branch with the footer's `reload` caveat line: button `Export`, no Save to file
    panel, no popups (User decision FQ2). `force off` returns to the judged state.
17. **Regression check, real:** on every new client build, the first login after the update
    must show the footer's `restart` line **on that first load** (0.1 rule 3, or rule 2): a
    marker from the previous build came back across the relaunch. If it shows `unverified`
    instead, that build does not read saved settings back; its result goes to
    `measurements/` and the plugin repo, and the panel of 7.2 is the way to keep work until
    a build restores again.
18. Record the falloff the operator found reasonable in step 4 (section 6.5's TBD). **Done**
    at the 2026-09-24 run: 5 yd, now `Config.editor.defaultFadeYards`.
19. **Clipboard (User decision, feedback-2 item 5; a measurement, 11):** on the normal
    branch, click the footer's `Export` once. Note whether a red "interface action failed"
    or a Lua error appeared, and what the line under the box says. Paste into a text editor
    outside the game (Ctrl+V) and note whether the DA2 string arrives. Run `/amb status` and
    copy its `clipboard:` line verbatim. The four together are the result: `Copied to
    clipboard` + pasted string + `clipboard: Export copied the preset string` means an addon
    may call it from a click on this build; anything else, and the line reads `Select all ->
    Ctrl+C` from then on.

Any refusal, taint line, or Lua error is the interesting result and is copied verbatim.

---

## 10. Deliveries 2-4 (outline)

### 10.1 Delivery 2 - Settings tab

Every `Config.settings` entry (five instance toggles with the `epicBattleground` caveat text
exactly as `/amb settings` prints it; sharing accept / preview; ignore list with add/remove),
the **baseline** for all three axes with "what the client has now" beside each (the one
setting every player must change), the **global indoors rule** edited as a special area
(values, priority, gate), and an **Advanced** disclosure holding `easeRate`, `pollHz`,
`writeHz`, `writeEpsilon`, `freezeInCombat`, each with its measured default, the reason from
Config.lua's comment, and a reset. `epicBattlegroundMinPlayers` read-only with the hint
that `/amb settings` inside a battleground shows its `maxPlayers` (the probe's coverage
report is gone: User decision, 2026-09-25: remove the probes completely). Every setting
saves in place into `store.settings` for this character
(answers-2 Q2, Q5) and the tab says "saved for this character"; `Config.lua` holds the
defaults and a `Reset to defaults` button copies them back (3.6). On a regressed branch the
tab carries the state's line and, **Proposal**, the 7.2 panel grows the revision-1 second box
that emits the `Config.settings` / `Config.baseline` / `Config.tuning` / `Config.indoors`
blocks for pasting into `Config.lua`. Settings panel registration via
`Settings.RegisterAddOnCategory`.

### 10.2 Delivery 3 - Themes

`UI/Theme.lua` gains the **Modern** table (**Proposal, for review by eye:** flat panels
`WHITE8X8` at a dark colour, 1-px `WHITE8X8` borders, one accent, `Fonts\ARIALN.TTF` - all
measured present), a picker in the Themes tab, and theme strings `DT1~name~key=value~...~cksum`
with the same escaping and checksum; import/export boxes like presets. Colour keys: the
eight from section 5 plus the four priority band colours. Fonts restricted to the measured
four (a missing font raises). No Customize panel (User decision, Q4). The theme choice
saves in place as `store.theme`, per character (answers-2 Q5); an imported theme string is
stored whole under `store.themes[name]` (**Proposal**).

### 10.3 Delivery 4 - Share tab and the wire

The import box moves into a Share tab with Q6's choices: the confirmation becomes the
addon's own frame with **Import (replace mine)**, **Add alongside mine** (their areas appended
with `origin = "import"`, name clashes suffixed with the sender's name, zone defaults kept),
**Decline**, **Never from them**; version shown as newer / older / same; nothing auto-replaces.
The wire follows DESIGN-settings-and-sharing.md section 3 now that messaging is measured:
`/amb share party|raid` and a Share button, `INSTANCE_CHAT` in battlegrounds, prefix `DynAmb`,
payload chunked at **200 bytes** (**Proposal**: under the 207 measured intact; the real ceiling
is measured with two clients before shipping), reassembled by a sequence header, the existing
throttle-free single-offer rule. Gate: a two-player round trip on PARTY and a hyperlink
delivered to another player, both untested solo (Authority). Shift-click a preset in the list
to drop the `dynamicambiance:` link into chat (`ChatEdit_InsertLink`, documented).

---

## 11. Still needing an in-game measurement

| What | Why | How |
|---|---|---|
| Chat edit box max letters | documents why `/amb import` is limited | `ChatFrame1EditBox:GetMaxLetters()` via `pcall`, any session |
| Paste cap above 4000 | only if a real preset is ever refused | section 8.3 |
| Gamma's exact edges | only if a preset needs a value in 0.2-0.3 or 3.0-3.5 | a finer ladder around each edge; the Gamma probe that ran the first one was removed (User decision, 2026-09-25: remove the probes completely), so this needs a new instrument |
| Polygon cost with yard scaling; editor-open OnUpdate cost; third CVar write | records, not assumptions | section 9.3 |
| ~~A reasonable default falloff for a new shape~~ | closed 2026-09-24: 5 yd, operator's call (6.5) | - |
| `UISpecialFrames` Escape-to-close | FrameXML behaviour, unmeasured | acceptance step 11 (guarded with `pcall`; a failure costs nothing) |
| Two-client addon message round trip and hyperlink delivery | delivery 4 gate | when a second client is available |
| `PLAYER_ENTERING_WORLD`'s `isInitialLogin` / `isReloadingUi` as this addon reads them | decides whether the `reload` state is distinguishable from `restart` (0.1); §P.30's companions read both, this addon has not | print both through `pcall` and `plain` at one login and one `/reload`; record in `measurements/` |
| `GetBuildInfo` on this client | the "judged on build" stamp (0.1) | one `pcall`, any session |
| A registered CVar coming back across a restart | would separate `none` from a fresh install (0.1, optional) | `C_CVar.RegisterCVar` a counter, `/reload`, restart, read it |
| Which events write SavedVariables besides `/reload` and logout | the footer's "written to disk at /reload or logout" | a disconnect and a crash, observed on the file's timestamp |
| Persistence on every new build | the whole of 0.1 has an expiry | step 17 of 9.4, every build |
| `CopyToClipboard` from an addon button's click | Export's copy (7.1, User decision feedback-2 item 5); restricted, never measured | step 19 of 9.4; the outcome is recorded per build and `/amb status` prints it |

## 12. New user questions

None. Every user-facing choice is covered by answers-1.md, feedback-1.md and answers-2.md,
or is a designer proposal marked for review: window size, priority colours, fill pitch,
corner cap, metadata caps, the store's field names (1.4), the record cap of 20 and its
reasoning (1.5), the checksum rule for re-seeding on a regressed branch (1.2), the revert
entry written on import (1.4), the `Delete zone` button (6.10), the replaced first
paragraph of the regressed panel and the per-state popup lines (6.8, 7.2.1), `/amb ui
export` with `/amb ui save` as an alias (7.1), the `force` override for the acceptance run
(9.4 step 16), the example set published as a DA2 string (1.2), and the Modern theme's look
in delivery 3.
