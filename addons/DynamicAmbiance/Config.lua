-- Dynamic Ambiance - configuration ----------------------------------------------
--
-- This file is every setting that is not a zone, and the DEFAULTS for the ones a
-- player can change in game. Build 70009 reads SavedVariables back
-- (design/ui/measurements-2026-09-25.md), so a character's zones and its
-- `/amb set` toggles live in its saved store (Store.lua): the zones are seeded
-- once from Zones.lua on the character's first login, and a toggle saved there
-- wins over the value below. See docs/DEVELOPMENT.md, "Constraints inherited from the
-- client".
--
-- Editing this file means editing it and typing `/reload`. The addon cannot
-- reload itself - ReloadUI is forbidden to addons here.

local ADDON, ns = ...

local Config = {}
ns.Config = Config

-- Baseline ----------------------------------------------------------------------
--
-- Where the screen sits when no zone entry applies, and what is written back on
-- logout and on `/amb off`.
--
-- This MUST be declared, not captured at login. The value the client persisted is
-- whatever this addon last wrote, so capturing it would make the addon ratchet the
-- player's brightness somewhere they never chose. 50/50 are the client defaults.
-- If your own neutral is different, put it here; `/amb status` prints what the
-- client currently has, so a first run tells you what to copy in.

--
-- Gamma is the third axis, and follows the same rule: declared here, never
-- captured. 1.0 is the client's measured default for `Gamma` (build 69977,
-- design/ui/measurements-2026-09-24.md).

Config.baseline = {
    contrast   = 50,
    brightness = 50,
    gamma      = 1.0,
}

-- Limits --------------------------------------------------------------------------
--
-- The range each axis may take. The editor's sliders, its numeric boxes and the
-- preset validator read this table and nothing else, so a later measurement that
-- moves an edge is a one-line change here.
--
--   contrast, brightness  0-100 is the client's own scale for `Contrast` and
--                         `Brightness`, measured 2026-09-18 (docs/DEVELOPMENT.md, "Measured").
--
--   gamma                 0.3-3.0 is the range the SCREEN applies, measured by eye
--                         on build 69977 with the Gamma edge probe (since removed)
--                         (measurements/gamma-edges-2026-09-24/). The CVar itself
--                         stores anything: -0.5 through 100 all read back exactly
--                         and nothing raised. The operator, verbatim: "the screen
--                         didnt change below 0.3 and above 3.0". Those were the
--                         ladder's rungs, so the true edges lie somewhere in
--                         0.2-0.3 and 3.0-3.5; a finer ladder may move them.
--                         A value outside this range is never written: the CVar
--                         would keep it and the screen would ignore it.
--
-- The user's decision (design/ui/answers-1.md, Q5 follow-up): the slider spans
-- what the game allows, never a narrower range chosen for taste.

Config.limits = {
    contrast   = { 0, 100 },
    brightness = { 0, 100 },
    gamma      = { 0.3, 3.0 },

    -- How many entries each saved record list keeps - `/amb here` captures,
    -- accepted imports, exports, and distinct instance snapshots - the oldest
    -- dropped first (DESIGN-ui.md 1.5). Build 70009 reads the lists back, so
    -- they would otherwise grow at every load. Not a measurement: an import or
    -- export entry holds one DA2 string of up to 4000 bytes, so 20 is at most
    -- 80 KB a list, under the addon's own largest source file and parsed once
    -- per login, and more strings than anyone scrolls back through in the chat
    -- log these lists were built to replace. One number, changed here.
    recordEntries = 20,
}

-- Hints -----------------------------------------------------------------------
--
-- Labels, not bounds. The operator's usable-by-eye Gamma range, verbatim from
-- answers-1.md: "0.7 minimum, 3.0 maximum". Drawn as two small marks on the Gamma
-- slider; nothing is clamped to them.

Config.hints = {
    gammaEye = { 0.7, 3.0 },
}

-- Tunables ----------------------------------------------------------------------
--
-- Defaults come from the cost measurements in docs/DEVELOPMENT.md, "Measuring the cost".

Config.tuning = {
    -- How fast the exponential approach settles. Higher is snappier; 4.0 is
    -- roughly one second to arrive.
    easeRate = 4.0,

    -- Position polls per second. C_Map.GetPlayerMapPosition allocates 1864 bytes
    -- a call, so this is deliberately not per-frame; the ease still runs every
    -- frame, which is what makes it look smooth.
    pollHz = 10,

    -- Cap on CVar writes per second. A write allocates ~822 bytes and steps
    -- faster than this are not visible, so this is the single largest reduction
    -- in the addon's garbage rate.
    writeHz = 25,

    -- Skip a write smaller than this, on the 0-100 scale. 0.5 is imperceptible
    -- and roughly halves the write count on its own.
    --
    -- Gamma is not on a 0-100 scale, so its epsilon is derived rather than set:
    -- the same fraction of its range, writeEpsilon * (3.0 - 0.3) / 100, read from
    -- Config.limits.gamma at run time. Re-measure by eye if its steps ever show.
    writeEpsilon = 0.5,

    -- Freeze the ease in combat.
    --
    -- Off, because it was measured rather than assumed. `/amb selftest` was run
    -- mid-fight on 2026-09-20, build 69913: 1742 SetCVar calls in combat, both
    -- CVars read back exactly, no lock flags, and no ADDON_ACTION_BLOCKED or
    -- FORBIDDEN. Writes are permitted in combat here.
    -- Record: measurements/selftest-combat-2026-09-20.lua
    --
    -- Turn it back on if a future build starts refusing. (`/amb selftest`, which
    -- measured this, was removed on 2026-09-25 by the user's decision.)
    freezeInCombat = false,
}

-- Settings ------------------------------------------------------------------------
--
-- Toggles, as opposed to values. `/amb settings` lists them and `/amb set <key>
-- on|off` flips one and saves it for the character. This table is the DEFAULTS:
-- a key the character has saved wins over the value here, and `/amb settings
-- reset` puts the character back on these. See DESIGN-settings-and-sharing.md.

Config.settings = {
    -- Instances -------------------------------------------------------------------
    --
    -- On means SUSPEND: the addon stops driving the screen and eases back to
    -- `Config.baseline` for as long as you are in there, then picks up again on
    -- the way out. It does not stop the loop, so there is no snap at either end
    -- and no reload needed - this is `/amb off` applied automatically and
    -- temporarily.
    --
    -- Off means the addon keeps doing its job inside, the same as anywhere else.
    --
    -- Why on by default: this was asked for, which says the current behaviour -
    -- driving the screen inside group content - is the unwanted one. Group content
    -- is also where an unexpected brightness ramp costs the most, and where the
    -- values everyone else is looking at matter more than your own.

    instances = {
        -- The master. On suspends in EVERY instance, including a kind this addon
        -- does not recognise. Off lets the four below decide for themselves, and
        -- an unrecognised instance keeps running.
        --
        -- Off by default: it exists for "disable for all instances", which is a
        -- blunt instrument that should be reached for deliberately.
        all = false,

        dungeon          = true,
        raid             = true,
        battleground     = true,

        -- NOTE: this one currently cannot fire. Separating an epic battleground
        -- from an ordinary one needs `epicBattlegroundMinPlayers` below, and that
        -- number has not been measured on this client - see the comment there.
        -- Until it is, every battleground counts as `battleground`.
        --
        -- With both defaulting to on, that costs nothing: the behaviour is
        -- identical either way. It only starts to matter if you set them
        -- differently, and `/amb settings` says so when you do.
        epicBattleground = true,
    },

    -- The threshold, in players, at or above which a battleground counts as epic.
    --
    -- DELIBERATELY NIL. "Epic battleground" is a retail bracket name, and whether
    -- this client has that bracket at all is unknown. The plausible rule here is
    -- Alterac Valley at 40 against Warsong Gulch at 10 and Arathi Basin at 15, so
    -- 40 is the obvious guess - and guessing is the one thing this repo does not
    -- do, because assuming retail's behaviour has already been wrong twice on this
    -- client (docs/DEVELOPMENT.md, "Measured 2026-09-18").
    --
    -- `/amb settings`, run inside a battleground, shows its maxPlayers. Once two
    -- different sizes have shown up, put the threshold between them here.
    epicBattlegroundMinPlayers = nil,

    -- Sharing ---------------------------------------------------------------------
    --
    -- The receiving side. Nothing is ever applied without a confirmation, so these
    -- decide whether the confirmation appears at all.

    sharing = {
        -- Off means no incoming preset ever raises a popup. This is the "ignore
        -- all requests" setting: `/amb ignore all` turns it off and saves that.
        accept = true,

        -- Apply the sender's values live while the confirmation is open, and put
        -- them back on decline, on timeout, on escape and on logout. Two display
        -- sliders is the whole blast radius, and a contrast number read off a
        -- dialog tells you nothing - presets are judged by eye.
        preview = true,

        -- Names that never raise a popup. The popup's own third button and
        -- `/amb ignore <name>` add to the character's saved list, and `/amb
        -- unignore <name>` removes. Names here are the default list, used until
        -- the character's own list has been saved once.
        ignorePlayers = {
            -- ["Somebody"] = true,
        },
    },
}

-- Zones -------------------------------------------------------------------------
--
-- A character's zones live in its saved store and are edited in `/amb ui`. The
-- file Zones.lua, loaded right after this one, is the SEED: read on each
-- character's first login, then not read again - except on a build that does not
-- read saved settings back, where it is the zones at every load and the editor's
-- Save to file generates it (DESIGN-ui.md 1.2, 7.2). What follows is the shape of
-- an entry, in the file and in the store alike.
--
-- Keyed by the name GetZoneText() returns. Each entry carries the zone default,
-- its metadata (`meta`: name, description, notes, version, author, date), and
-- optionally areas that override it within the zone.
--
-- An area's kind is implied by its fields - exactly one of `subzone`, `x` or
-- `corners`, or none:
--
--   subzone   matched by name against GetSubZoneText(). Weight is 1 inside and 0
--             outside; the ease is what stops the boundary snapping. Needs no
--             coordinates and no map ID, so it is the one to reach for first.
--
--   circle    `x`, `y` in the map's normalized 0-1 space, and `innerYards`,
--             `falloffYards` in YARDS. Weight is 1 inside `innerYards`,
--             smoothsteps down to 0 at `falloffYards`, and overlapping falloffs
--             blend. Radii are yards because a normalized radius is an ellipse
--             in the world: Elwynn is 3471 yd across and 2315 yd down.
--
--   polygon   `corners = { x1, y1, x2, y2, ... }`, normalized, 3 to 32 corners,
--             plus `falloffYards`. Weight is 1 inside, smoothsteps to 0 over
--             `falloffYards` measured to the nearest edge.
--
--   rule      none of the three: claims the whole zone, usually with a gate.
--
-- Circles and polygons require `map` on the zone - `/amb here` prints it - and
-- are skipped, with one warning, when the map's scale cannot be read. An older
-- circle with `inner` / `falloff` in normalized units still works: it is
-- converted to yards when the zone is entered.
--
-- `gamma` goes everywhere `contrast` and `brightness` do. Anything an area leaves
-- out falls through to the zone, and anything the zone leaves out falls through
-- to the baseline.

-- Priority -----------------------------------------------------------------------
--
-- Every layer carries a `priority`. They are applied lowest first, so the highest
-- priority present wins, and regions are free to overlap:
--
--     nothing claims the spot          the baseline above
--     approaching a positional layer   the nearer you are, the more it applies
--     inside it                        its values, flat
--     a higher-priority layer on top   that one instead
--     ...and tagged `indoors = true`   only while the client says you are inside
--
-- The numbers below are spread out on purpose so things can be slotted between
-- them later without renumbering.

local P_ZONE_FEATURE = 10   -- a named subzone, or a place on the map
local P_INDOORS      = 50   -- any interior, anywhere
local P_ROOM         = 60   -- a named room that differs from the general rule

-- Indoors --------------------------------------------------------------------
--
-- One rule for every building in the game, rather than an entry hand-placed on
-- each one.
--
-- Why this is not just another area. Measured 2026-09-20, standing in the
-- Northshire chapel: the position read works indoors and returns an ordinary
-- point on the parent map - 0.4905, 0.4096 on map 1429 - which is the same
-- coordinate space as the grass outside the door. Inside and outside are the
-- same x and y, so no radius can separate them. A map coordinate is two
-- dimensional and "indoors" is not a fact it can carry. `IsIndoors()` is, and it
-- is present on this client.
--
-- Why its priority is ABOVE the named subzones. Measured the same day, on the
-- chapel stairway: the client reports the subzone `Northshire Valley` while
-- `IsIndoors()` is already true. When indoors was the bottom layer, that subzone
-- painted over it and the screen snapped back to outdoor values while still
-- inside the building. At priority 50 it holds until a named room outranks it.
--
-- Lifted, because that is the actual complaint that started this project:
-- settings that make the outdoors look right turn interiors into caves.
--
-- Set to nil to switch it off. A zone can override it with its own
-- `indoors = { ... }`, or opt out entirely with `indoors = false`.

Config.indoors = {
    contrast = 42, brightness = 90,
    priority = P_INDOORS,
}

-- Editor -----------------------------------------------------------------------
--
-- defaultFadeYards   the Fade (yd) every new circle or polygon starts with: how
--                    far past the shape's edge its values take to fade out. For a
--                    circle it is measured outward from the inner radius, so the
--                    stored falloffYards is innerYards + fade; for a polygon it is
--                    measured from the edges and stored as falloffYards as is.
--                    5 yards is the operator's call at the delivery 1 acceptance
--                    run, 2026-09-24 (design/ui/feedback-1.md): "default fade yard
--                    should be 5". It closes DESIGN-ui.md 6.5's TBD. Not a
--                    measurement of what looks right everywhere - change it here.

Config.editor = {
    defaultFadeYards = 5,
}

-- The table Zones.lua fills, and Store.lua then loads the character's store into.
-- A zone still defined here is seeded like the file's, on a character's first
-- login; Zones.lua assigns by key after this file and wins on a collision.
Config.zones = {}
