-- Dynamic Ambiance - the editor window -------------------------------------------------
--
-- `/amb ui`            open or close the editor on the Zones tab
-- `/amb ui zones`      open it
-- `/amb ui export`     open it on Export: a zone's preset string
-- `/amb ui save`       the same, kept as an alias; on a build where saving has
--                      regressed it opens Save to file instead (DESIGN-ui.md 7.2)
-- `/amb ui import`     open it on Import, its own panel - for strings too long for chat
-- `/amb ui corner`     drop a polygon corner where you stand (the "walk and drop" path)
-- `/amb ui named <s>`  add a named area for subzone <s>, from anywhere
-- `/amb ui mapcheck`   compare the explored overlays the client reports for the
--                      current map with MapOverlays.lua, into the account DB
--
-- design/ui/DESIGN-ui.md sections 5-8, delivery 1. One window: a tab strip (only
-- Zones is live; Settings, Themes and Share are there, disabled, so the layout
-- does not move later), the zone's own map with every placed area on it, the
-- area list in priority order, a properties panel, the tools, and Export and
-- Import at the bottom right (design/ui/feedback-2.md item 2).
--
-- There is no working copy and no apply step. The editor edits Config.zones -
-- the live table - so the engine previews every change by construction, the way
-- Share.lua's preview does. What that asks of this file (DESIGN-ui.md 3.3): an
-- edit that changes membership, priority or gate REPLACES zone.areas with a
-- fresh table, because the engine's sorted layer cache keys on that table's
-- identity; a value edit changes the record in place and only re-targets.
--
-- Persistence (DESIGN-ui.md 0.1, 6.8, 6.10). Build 70009 reads saved settings
-- back, so every edit is saved in place: each change flushes a clean copy of the
-- zone into the character's store (Store.flushZone), and the client writes it to
-- disk at /reload or logout. There is no dirty state, no unsaved counter and no
-- popup on close. The branch is judged at every login, and on the regressed one
-- (`unverified`) delivery 1's machinery comes back unchanged: the unsaved
-- counter, the `*`, the close popup, the Save to file panel with its copy-paste
-- steps, and the recovery draft of the generated Zones.lua written line by line
-- to DynamicAmbianceDB.editor on every change.
--
-- Built lazily, on first open, so loading the addon creates one small settings
-- panel and nothing else. Every FrameXML global, template, mixin and child key
-- is guarded (ns.UI in Canvas.lua); a build that fails says so in chat and leaves
-- the rest of the addon running.
--
-- design/ui/feedback-1.md (the delivery 1 acceptance run) changed: the map
-- zooms and pans, a polygon closes on any of its corners, a selected polygon
-- takes and loses corners, the priority buttons step, notes are text areas, a
-- shape's Fade is measured outward from it with a default of 5 yards, Save to
-- file says in a popup that there is a step left, the recovery draft is stored
-- line by line, and combat hides the window until it ends.

local ADDON, ns = ...
if not (ns and ns.COMMANDS and ns.Config and ns.Preset and ns.Serialize and ns.Raster
    and ns.Theme and ns.Canvas and ns.UI) then return end

local Config, Preset, Serialize = ns.Config, ns.Preset, ns.Serialize
local R, T, UI, Canvas = ns.Raster, ns.Theme, ns.UI, ns.Canvas
local out, warn, plain = ns.out, ns.warn, ns.plain
local format, floor, sqrt, abs, max, min = string.format, math.floor, math.sqrt, math.abs,
    math.max, math.min

local E = {
    built       = false,
    zoneName    = nil,       -- the zone key being edited
    mapID       = nil,       -- the uiMapID its coordinates belong to
    mapNote     = nil,       -- set when GetZoneText and the map's name differ
    selected    = nil,       -- an area record, or nil for the zone itself
    tool        = "select",
    draft       = nil,       -- a shape being drawn, not yet an area
    drag        = nil,
    fill        = true,
    panel       = "props",   -- props | export | save | import
    exportZone  = nil,       -- the zone the Export panel shows
    storePending = {},       -- zone names edited since the last flush to the store
    saveMode    = "file",    -- "file", or a zone name for its preset string
    undoStack   = {},
    redoStack   = {},
    lastKey     = nil,
    draftPending = false,
    press       = nil,       -- a left press not yet known to be a click or a pan
    combatHidden = false,    -- hidden by combat, to come back when it ends
}
ns.Editor = E

-- Layout. A proposal (DESIGN-ui.md 5): the canvas at the art's native 1002 x 668,
-- so one canvas pixel is one art pixel. A screen too small for 1360 x 780 gets
-- the whole window scaled down rather than a cramped layout.
local WIN_W, WIN_H     = 1360, 780
local CANVAS_W, CANVAS_H = 1002, 668
local PAD              = 12
local CANVAS_TOP       = -62
local COL_X            = PAD + CANVAS_W + 10
local COL_W            = WIN_W - COL_X - PAD
local COL_TOP          = -32
-- The footer's two buttons sit under the right column, in the window's bottom
-- right corner (feedback-2.md item 2), so the column stops above their row: the
-- row is FOOT_Y..FOOT_Y + 22 up from the window's bottom edge, and the column's
-- message line, two lines at most, ends at COL_BOTTOM - 8.
local FOOT_Y           = 8
local FOOT_GAP         = 6
local COL_BOTTOM       = -(WIN_H - FOOT_Y - 22 - 8)
local FRAME_NAME       = "DynamicAmbianceEditor"

local POPUP_UNSAVED = "DYNAMICAMBIANCE_UNSAVED"
local POPUP_DELETE  = "DYNAMICAMBIANCE_DELETE_AREA"
local POPUP_SAVE    = "DYNAMICAMBIANCE_SAVE_STEPS"
local POPUP_FIELD   = "DYNAMICAMBIANCE_FIELD_ERROR"
local POPUP_REVERT  = "DYNAMICAMBIANCE_REVERT_ZONE"
local POPUP_DELZONE = "DYNAMICAMBIANCE_DELETE_ZONE"

E.POPUP_UNSAVED, E.POPUP_DELETE = POPUP_UNSAVED, POPUP_DELETE
E.POPUP_SAVE, E.POPUP_FIELD = POPUP_SAVE, POPUP_FIELD
E.POPUP_REVERT, E.POPUP_DELZONE = POPUP_REVERT, POPUP_DELZONE

-- The branch (Store.lua). Without a store the editor behaves as on a normal build.
local function regressed()
    return ns.Store ~= nil and ns.Store.regressed() or false
end

E.regressed = regressed

-- The footer's first line, per state (DESIGN-ui.md 5), verbatim. `reload` is the
-- normal footer plus one line of caveat (User decision FQ2).
E.FOOTER_RESTART = "Saved - written to disk at /reload or logout."
E.FOOTER_RELOAD = E.FOOTER_RESTART .. " Not yet verified across a restart on this build."
E.FOOTER_UNVERIFIED = "Saving not yet verified on this build - if this line is still here "
    .. "after a /reload, this build is not keeping saved settings."
-- The regressed-branch close popup's line for the state (DESIGN-ui.md 6.8).
E.UNSAVED_STATE_LINE = "Saving is not yet verified on this build - they may be lost at /reload."

-- The Export panel's one line (DESIGN-ui.md 7.1).
E.EXPORT_TEXT = "A preset string carries one zone: its values, its areas and its notes. "
    .. "Anyone with the addon can paste it into their import box."

-- feedback-1.md item 8, the popup's wording as resolved there.
E.SAVE_POPUP_TEXT = "Your changes are not saved yet. Read the steps on the right of the editor "
    .. "to save them to file."

-- feedback-1.md item 3: what the mouse does, on the canvas while drawing.
E.HINT_POLYGON = "Left click: place a corner. Right click: remove the last corner. "
    .. "Click any corner to finish."
E.HINT_CIRCLE = "Left click and drag: place the centre and pull out the inner radius. "
    .. "Then set Fade (yd) and press Finish."
E.HINT_EDIT = "Drag a corner to move it. Click or drag an edge's middle handle to add a "
    .. "corner. Right click a corner to remove it."
E.HINT_PAN = "Mouse wheel or + / - to zoom. Drag the map to move around."

-- feedback-1.md item 5: "Inherit" alone did not say what it inherits.
E.INHERIT_LABEL = "Inherit default"

-- A press that moves less than this, in canvas pixels, is a click (item 1).
E.CLICK_SLOP = 4
-- How near a click must be to a corner of the shape being drawn to close it.
E.CLOSE_REACH = 8
-- The priority box takes four characters, so the step buttons stay inside that.
E.PRIORITY_MIN, E.PRIORITY_MAX = -999, 9999
-- How long a refusal stays on the canvas.
E.NOTICE_SECONDS = 5

-- The Save to file wording, shown on the regressed branch only. User decision,
-- Q2 (design/ui/answers-1.md), verbatim from DESIGN-ui.md 7.2.1: the 69977 text
-- from "So today" onward, with the first paragraph replaced for `unverified`
-- and the "automatic" paragraph saying what is now true. Bold is shown in the
-- accent colour, since a font string has no bold. The addon cannot know the
-- install folder or the account name (there is no file API), so those two print
-- as the design says they do.
local ACC, END = "|cffffd100", "|r"
E.SAVE_TITLE = "Save to file"
E.SAVE_TEXT = table.concat({
    ACC .. "Why you have to do this step yourself, on this build." .. END,
    "This addon has not yet seen World of Warcraft: Forever read its saved settings back on "
        .. "this build. Saving worked on build 70009; a later build may have stopped, or this "
        .. "may be your first login - a /reload tells: if the footer still says \"not yet "
        .. "verified\" afterwards, this build is not keeping saved settings, and everything you "
        .. "draw here needs the steps below.",
    "",
    ACC .. "So today, saving is a copy and paste:" .. END,
    "1. Click " .. ACC .. "Select all" .. END .. ", then press " .. ACC .. "Ctrl+C" .. END .. ".",
    "2. Open this file in a text editor:",
    "    " .. Serialize.FILE_PATH,
    "    in your World of Warcraft: Forever folder",
    "3. Replace " .. ACC .. "everything" .. END .. " in that file with what you copied, and "
        .. "save it.",
    "4. Type " .. ACC .. "/reload" .. END .. " in the game.",
    "",
    ACC .. "This is automatic on a build that reads saved settings back." .. END .. " The addon "
        .. "saves your work on every change and checks at every login whether the game loads it "
        .. "again; when it does, this panel goes away and nothing you pasted here needs to be "
        .. "redone.",
    "",
    "|cff9d9d9dSmall print: if you forgot to save before a /reload, the last draft is in "
        .. Serialize.DRAFT_PATH .. "DynamicAmbiance.lua under editor.draftLines, one line "
        .. "of Zones.lua per entry - copy the lines from there. That is the Account folder "
        .. "inside WTF, not WTF\\SavedVariables\\, which does not have it." .. END,
}, "\n")

-- feedback-2.md item 6: no format names - nobody has a string in the old one.
E.IMPORT_TEXT = "Paste a preset string below and press Import. The confirmation that "
    .. "follows previews it live on your screen; Decline puts everything back. Importing "
    .. "replaces the zone it names, areas and all."

-- feedback-2.md item 3: the label is short, and the when is in the tooltip.
E.REVERT_LABEL = "Revert to last export"

-- feedback-2.md item 5: under the Export panel's box, whether Export put the
-- string on the clipboard or the player has to copy it.
E.CLIP_COPIED = "Copied to clipboard"
E.CLIP_HINT = "Select all -> Ctrl+C"

-- Helpers ---------------------------------------------------------------------------------

local function now()
    local ok, t = UI.callG("GetTime")
    if ok and type(t) == "number" then return t end
    return 0
end

local function round(v, places)
    local m = 10 ^ (places or 0)
    return floor(v * m + 0.5) / m
end

local function limits(axis)
    local l = Config.limits and Config.limits[axis]
    if l then return l[1], l[2] end
    return 0, 100
end

-- The one finite-number guard (Preset.finite, which is the engine's). The
-- client's tonumber reads "nan", "inf" and "1e999" as numbers, and a NaN passes
-- every comparison below, so every numeric box reads through `number`.
local finite = Preset.finite

local function number(text)
    local t = type(text)
    if t ~= "string" and t ~= "number" then return nil end
    local v = tonumber(text)
    if finite(v) then return v end
    return nil
end

E.number = number

-- Fade and falloff (feedback-1.md items 10 and 11) ------------------------------------
--
-- The operator should not have to do sums. The UI asks for a Fade: how many
-- yards past the shape its values take to fade out. The stored format is
-- unchanged - falloffYards - so the two convert here and nowhere else:
--
--   polygon   falloffYards = fade            (the engine already measures a
--                                             polygon's falloff from its edges)
--   circle    falloffYards = innerYards + fade
--
-- and back, for showing a selected shape. A circle whose stored falloff is inside
-- its inner radius (only a hand-edited file could have one) shows a fade of 0.

function E.defaultFade()
    local d = Config.editor and Config.editor.defaultFadeYards
    if finite(d) and d >= 0 then return d end
    return 5
end

function E.fadeToFalloff(kind, innerYards, fade)
    if not finite(fade) then return nil end
    if kind == "circle" then return (innerYards or 0) + fade end
    return fade
end

function E.falloffToFade(kind, innerYards, falloffYards)
    if not finite(falloffYards) then return nil end
    if kind == "circle" then return max(0, falloffYards - (innerYards or 0)) end
    return falloffYards
end

-- The priority step buttons (feedback-1.md item 6): each adds its value, and 0
-- sets the priority to 0. Kept inside what the priority box can show.
function E.stepPriority(current, step)
    if step == 0 then return 0 end
    local v = (finite(current) and current or 0) + step
    if v < E.PRIORITY_MIN then v = E.PRIORITY_MIN end
    if v > E.PRIORITY_MAX then v = E.PRIORITY_MAX end
    return v
end

local function clampAxis(axis, v)
    if not finite(v) then return nil end
    local lo, hi = limits(axis)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function copyArea(a)
    local c = {}
    for k, v in pairs(a) do c[k] = v end
    if type(a.corners) == "table" then
        c.corners = {}
        for i = 1, #a.corners do c.corners[i] = a.corners[i] end
    end
    return c
end

-- The engine's layer cache holds references into the zone; a snapshot must not.
local SKIP = { __layers = true, __rule = true, __areas = true }

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do
        if not SKIP[k] then c[k] = deepCopy(v) end
    end
    return c
end

local function kindOf(a)
    if a.subzone then return "named" end
    if a.x then return "circle" end
    if a.corners then return "polygon" end
    return "rule"
end

E.kindOf = kindOf

local KIND_LABEL = { named = "by name", circle = "circle", polygon = "polygon", rule = "zone rule" }

local function areaName(a, index)
    if a.name and a.name ~= "" then return a.name end
    if a.subzone and a.subzone ~= "" then return a.subzone end
    return "area " .. tostring(index or "?")
end

local function isPlaced(a) return a.x ~= nil or a.corners ~= nil end

local function tellError(where, err)
    warn(format("editor: %s failed - %s", where, plain(err) or "?"))
end

-- An import preview swaps the zone it names into Config.zones (Share.lua), so
-- while one is open the "live zone" is the sender's. Editing it, saving it,
-- snapshotting it for undo or clearing its unsaved flag would all act on a table
-- that Decline throws away - so while an offer is open the editor is locked, and
-- says why.
E.LOCK_NOTE = "import preview open - accept or decline first"

function E.locked()
    local s = ns.shareSession
    return (s and s.offer ~= nil) and true or false
end

local function refuseLocked()
    if not E.locked() then return false end
    E.say(E.LOCK_NOTE)
    E.needsProps, E.needsRender, E.needsFooter = true, true, true
    return true
end

-- A value that is not a finite number never reaches a zone, whatever sent it.
local function refuseNonFinite(value)
    if type(value) == "number" and not finite(value) then
        E.say("that is not a number the game can use.")
        E.needsProps = true
        return true
    end
    return false
end

-- The model ---------------------------------------------------------------------------------

function E.zone()
    return E.zoneName and Config.zones[E.zoneName] or nil
end

-- Yards per normalized unit for the zone being edited: the engine's cache when
-- the zone exists, otherwise read once for the map being browsed.
function E.scale()
    local z = E.zone()
    if z and z.__W then return z.__W, z.__H end
    return E.W, E.H
end

-- Zones unsaved to file. Only a regressed build has a Save to file to count for;
-- on a normal one every edit is already saved (DESIGN-ui.md 6.8).
function E.dirtyCount()
    if not regressed() then return 0 end
    local n = 0
    for _, z in pairs(Config.zones) do
        if type(z) == "table" and z.__dirty then n = n + 1 end
    end
    return n
end

-- A zone not yet in Config.zones gets an entry only when the first area or value
-- is added (DESIGN-ui.md 6.1). Browsing creates nothing.
function E.ensureZone()
    local z = E.zone()
    if z then return z end
    if not E.zoneName then return nil end
    z = { map = E.mapID, areas = {}, origin = "editor" }
    Config.zones[E.zoneName] = z
    Serialize.ensureMeta(E.zoneName, z)
    ns.prepareZone(z, E.zoneName)
    E.storePending[E.zoneName] = true
    return z
end

-- Every zone edited since the last flush goes to the store (DESIGN-ui.md 6.10):
-- its clean copy, or its removal when it is gone from Config.zones.
function E.flushStore()
    if not ns.Store or E.locked() then return end
    for name in pairs(E.storePending) do
        local ok, err = pcall(ns.Store.flushZone, name)
        if not ok then tellError("saving " .. tostring(name), err) end
    end
    E.storePending = {}
end

-- Undo / redo: a session stack of whole-zone snapshots. A zone is small - at most
-- 64 areas of a dozen fields - so a copy of it is cheap, and a snapshot restores
-- a zone that did not exist yet by removing it again. Unbounded within the
-- session (a proposal). Consecutive edits to the same field - a slider drag -
-- share one snapshot.
local function snapshot(name)
    local z = Config.zones[name]
    -- The zone's revert point too, so undoing a Delete zone brings it back.
    local rev = ns.Store and ns.Store.getRevert(name) or nil
    return { name = name, existed = z ~= nil, data = z and deepCopy(z) or nil,
             selected = E.selectedIndex(), revert = rev and deepCopy(rev) or nil }
end

function E.pushUndo(key)
    if not E.zoneName or E.locked() then return end
    if key and key == E.lastKey then return end
    E.lastKey = key
    E.undoStack[#E.undoStack + 1] = snapshot(E.zoneName)
    E.redoStack = {}
end

local function restore(snap)
    E.storePending[snap.name] = true
    if not snap.existed then
        Config.zones[snap.name] = nil
    else
        local z = Config.zones[snap.name]
        local data = deepCopy(snap.data)
        if z then
            -- Where the zone came from, and whether it was ever exported, are
            -- facts about the zone rather than about the edit being undone.
            local origin = z.origin
            local once = type(z.export) == "table" and z.export.once or nil
            for k in pairs(z) do z[k] = nil end
            for k, v in pairs(data) do z[k] = v end
            z.origin = origin
            if once then Serialize.exportState(z).once = true end
        else
            z = data
            Config.zones[snap.name] = z
        end
        -- A new areas table, so the engine re-sorts.
        z.areas = z.areas or {}
        Serialize.markChanged(z)
    end
    if ns.Store and snap.existed and snap.revert then
        ns.Store.putRevert(snap.name, deepCopy(snap.revert))
    end
    if E.zoneName ~= snap.name then E.selectZone(snap.name) end
    local z = E.zone()
    E.selected = z and snap.selected and z.areas and z.areas[snap.selected] or nil
end

local function afterRestore()
    E.lastKey = nil
    E.draftPending = true
    if ns.refreshTarget then pcall(ns.refreshTarget, true) end
    E.flushDraft()
    E.refresh()
end

function E.undo()
    if refuseLocked() then return false, "locked" end
    local snap = table.remove(E.undoStack)
    if not snap then return false end
    E.redoStack[#E.redoStack + 1] = snapshot(snap.name)
    restore(snap)
    afterRestore()
    return true
end

function E.redo()
    if refuseLocked() then return false, "locked" end
    local snap = table.remove(E.redoStack)
    if not snap then return false end
    E.undoStack[#E.undoStack + 1] = snapshot(snap.name)
    restore(snap)
    afterRestore()
    return true
end

function E.selectedIndex()
    local z = E.zone()
    if not (z and z.areas and E.selected) then return nil end
    for i = 1, #z.areas do
        if z.areas[i] == E.selected then return i end
    end
    return nil
end

-- After any edit: mark it, save it (and on a regressed build write the draft),
-- re-target the engine (the live preview), redraw. A light edit - a slider or a
-- drag, many a second - leaves the save and the full refresh to the next tick.
local function afterEdit(zone, light)
    Serialize.markChanged(zone)
    if E.zoneName then E.storePending[E.zoneName] = true end
    E.draftPending = true
    if ns.refreshTarget then pcall(ns.refreshTarget, true) end
    if light then
        E.needsRender = true
        E.needsFooter = true
        return
    end
    E.flushDraft()
    E.refresh()
end

E.afterEdit = afterEdit

-- Replaces zone.areas with a fresh table of copied records, lets `fn` change the
-- copy, and keeps the selection pointing at the same area.
function E.replaceAreas(zone, fn)
    local fresh, map = {}, {}
    local old = zone.areas or {}
    for i = 1, #old do
        local c = copyArea(old[i])
        fresh[i] = c
        map[old[i]] = c
    end
    fn(fresh, map)
    zone.areas = fresh
    if E.selected then
        local s = map[E.selected] or E.selected
        E.selected = nil
        for i = 1, #fresh do
            if fresh[i] == s then E.selected = s end
        end
    end
end

-- Edits that change membership, the sort, or the gate.
local STRUCTURAL = { priority = true, indoors = true }

function E.addArea(a)
    if refuseLocked() then return nil end
    local zone = E.ensureZone()
    if not zone then return nil end
    if #(zone.areas or {}) >= Preset.MAX_AREAS then
        warn(format("%d areas is the cap for one zone.", Preset.MAX_AREAS))
        return nil
    end
    E.pushUndo(nil)
    a.origin = "editor"
    E.replaceAreas(zone, function(list) list[#list + 1] = a end)
    E.selected = a
    afterEdit(zone)
    return a
end

function E.deleteArea(a)
    if refuseLocked() then return false end
    local zone = E.zone()
    if not (zone and a) then return false end
    E.pushUndo(nil)
    E.replaceAreas(zone, function(list, map)
        local target = map[a] or a
        for i = #list, 1, -1 do
            if list[i] == target then table.remove(list, i) end
        end
    end)
    E.selected = nil
    afterEdit(zone)
    return true
end

-- One field of one area. `light` for a continuous gesture.
function E.setArea(a, key, value, light)
    if refuseLocked() or refuseNonFinite(value) then return end
    local zone = E.zone()
    if not (zone and a) then return end
    if STRUCTURAL[key] then
        E.pushUndo(nil)
        E.replaceAreas(zone, function(_, map) (map[a] or a)[key] = value end)
        afterEdit(zone)
    else
        E.pushUndo("area:" .. tostring(E.selectedIndex()) .. ":" .. key)
        a[key] = value
        afterEdit(zone, light)
    end
end

-- The zone's own contrast, brightness or gamma. nil inherits the baseline.
function E.setZoneValue(key, value, light)
    if refuseLocked() or refuseNonFinite(value) then return end
    local zone = E.ensureZone()
    if not zone then return end
    E.pushUndo("zone:" .. key)
    zone[key] = value
    afterEdit(zone, light)
end

-- Preset metadata. A typed version stands at the next export (DESIGN-ui.md 1.3).
function E.setMeta(key, value)
    if refuseLocked() or refuseNonFinite(value) then return end
    local zone = E.ensureZone()
    if not zone then return end
    local meta = Serialize.ensureMeta(E.zoneName, zone)
    E.pushUndo("meta:" .. key)
    meta[key] = value
    if key == "version" then Serialize.markManualVersion(zone) end
    afterEdit(zone)
end

-- Shapes being drawn ----------------------------------------------------------------------
--
-- A new shape is a draft until it is closed, not a live area: nothing half-drawn
-- ever reaches the engine, so drawing never flickers the screen.
--
-- Its fade starts at Config.editor.defaultFadeYards - 5, the operator's call at
-- the acceptance run (feedback-1.md item 10) - so closing it never stops to ask.
-- `falloffYards` on a draft is derived from the fade for drawing its band.

E.MAX_CORNERS = Preset.MAX_CORNERS

local function syncDraft(d)
    d.falloffYards = E.fadeToFalloff(d.kind, d.innerYards, d.fadeYards)
end

function E.startPolygon()
    E.draft = { kind = "polygon", corners = {}, fadeYards = E.defaultFade() }
    syncDraft(E.draft)
    E.tool = "polygon"
    E.selected = nil
    E.refresh()
end

function E.startCircle(nx, ny)
    E.draft = { kind = "circle", x = R.round4(nx), y = R.round4(ny), innerYards = 0,
                fadeYards = E.defaultFade() }
    syncDraft(E.draft)
    E.refresh()
end

function E.addDraftCorner(nx, ny)
    local d = E.draft
    if not (d and d.kind == "polygon") then return false end
    if #d.corners / 2 >= E.MAX_CORNERS then
        E.notice(format("a polygon has at most %d corners.", E.MAX_CORNERS))
        return false
    end
    d.corners[#d.corners + 1] = R.round4(R.clamp01(nx))
    d.corners[#d.corners + 1] = R.round4(R.clamp01(ny))
    E.needsRender, E.needsProps = true, true
    return true
end

function E.removeDraftCorner()
    local d = E.draft
    if not (d and d.kind == "polygon" and #d.corners >= 2) then return false end
    d.corners[#d.corners] = nil
    d.corners[#d.corners] = nil
    E.needsRender, E.needsProps = true, true
    return true
end

function E.cancelDraft(quiet)
    if not E.draft then return end
    E.draft = nil
    E.setKeyboard(false)
    if E.canvas then E.canvas:setRubber(nil) end
    if not quiet then E.refresh() end
end

-- Closes the draft into a real area. Returns the area, or nil and why not.
function E.finishDraft()
    local d = E.draft
    if not d then return nil, "nothing is being drawn" end
    if refuseLocked() then return nil, "locked" end
    if d.kind == "polygon" and #d.corners < 6 then
        E.notice("a polygon needs at least 3 corners.")
        return nil, "corners"
    end
    -- Only an emptied or unreadable Fade box can stop it now; there is no sum
    -- left for the player to get wrong.
    if not finite(d.fadeYards) or d.fadeYards < 0 then
        E.fieldError(E.draftFade, "Fade (yd) has to be a number of yards, 0 or more.")
        E.focusDraftFade()
        return nil, "fade"
    end
    local zone = E.ensureZone()
    local n = #((zone and zone.areas) or {}) + 1
    local fade = round(d.fadeYards, 1)
    local a
    if d.kind == "polygon" then
        local corners = {}
        for i = 1, #d.corners do corners[i] = d.corners[i] end
        a = { name = "area " .. n, corners = corners, falloffYards = E.fadeToFalloff("polygon", nil, fade),
              priority = 10 }
    else
        local inner = round(d.innerYards or 0, 1)
        a = { name = "area " .. n, x = d.x, y = d.y, innerYards = inner,
              falloffYards = round(E.fadeToFalloff("circle", inner, fade), 1), priority = 10 }
    end
    E.clearFieldError()
    E.draft = nil
    E.setKeyboard(false)
    if E.canvas then E.canvas:setRubber(nil) end
    E.tool = "select"
    E.say(nil)
    return E.addArea(a)
end

-- The draft's Fade. Anything that is not a finite number of 0 or more is refused
-- next to the box and in a popup, and the fade stays what it was.
function E.setDraftFade(v)
    local d = E.draft
    if not d then return false end
    if not finite(v) or v < 0 then
        E.fieldError(E.draftFade, "Fade (yd) has to be a number of yards, 0 or more.")
        E.needsProps = true
        return false
    end
    d.fadeYards = v
    syncDraft(d)
    E.clearFieldError()
    E.needsRender = true
    return true
end

-- Named areas: the name given, or the current subzone when the player is in this
-- zone (DESIGN-ui.md 6.6). Never empty: a named area with no subzone matches
-- nothing, and its preset string would be refused on import ("no subzone
-- name"), so without a name there is no area - `/amb ui named <subzone>` gives
-- one from anywhere, and the list of subzones seen this session renames it after.
function E.addNamed(name)
    if refuseLocked() then return nil, "locked" end
    local sub = type(name) == "string" and (name:gsub("^%s+", ""):gsub("%s+$", "")) or ""
    if sub == "" then
        local zoneName, subzone = ns.zoneNames()
        if zoneName == E.zoneName and subzone then sub = subzone end
    end
    if sub == "" then
        E.say(format("a named area needs a subzone name - stand in one of %s's subzones, or "
            .. "type /amb ui named <subzone>.", tostring(E.zoneName or "this zone")))
        return nil, "no name"
    end
    return E.addArea({ subzone = sub, priority = 10 })
end

-- Where the player is on the editor's map: the engine's own last read when it is
-- on this map, otherwise one read of our own. nil when off this map.
function E.playerPosition()
    local st = ns.state
    local z = E.zone()
    if st and E.zoneName and st.zoneName == E.zoneName and st.px
        and (not (z and z.map) or z.map == st.mapID) then
        return st.px, st.py
    end
    if E.mapID and ns.readPosition then return ns.readPosition(E.mapID) end
    return nil
end

-- "Corner here": append a corner at the player's position to the polygon being
-- drawn, or to the selected one.
function E.cornerHere()
    if refuseLocked() then return false end
    local nx, ny = E.playerPosition()
    if not nx then
        E.say("you are not on this zone's map, or the client gave no position here.")
        return false
    end
    if E.draft and E.draft.kind == "polygon" then
        local ok = E.addDraftCorner(nx, ny)
        if ok then
            E.say(format("corner %d at %.4f, %.4f.", #E.draft.corners / 2, nx, ny))
            E.refresh()
        end
        return ok
    end
    local a = E.selected
    if a and a.corners then
        if #a.corners / 2 >= E.MAX_CORNERS then
            E.notice(format("a polygon has at most %d corners.", E.MAX_CORNERS))
            return false
        end
        E.pushUndo(nil)
        a.corners[#a.corners + 1] = R.round4(nx)
        a.corners[#a.corners + 1] = R.round4(ny)
        afterEdit(E.zone())
        return true
    end
    E.say("pick the Polygon tool, or select a polygon, first.")
    return false
end

-- Editing a placed polygon's corners (feedback-1.md item 4). Both change the
-- area record in place - geometry, like a corner drag (DESIGN-ui.md 3.3) - and
-- both take an undo snapshot first. The shape never drops below 3 corners or
-- rises above the cap, so the engine never sees a polygon it cannot weigh.

-- A new corner after corner `after`, at (nx, ny). Returns its index, or nil.
function E.insertCorner(a, after, nx, ny)
    if refuseLocked() then return nil end
    if not (a and a.corners) then return nil end
    if #a.corners / 2 >= E.MAX_CORNERS then
        E.notice(format("a polygon has at most %d corners - this one has %d.", E.MAX_CORNERS,
            #a.corners / 2))
        return nil
    end
    E.pushUndo(nil)
    local index = R.insertCorner(a.corners, after, R.round4(R.clamp01(nx)), R.round4(R.clamp01(ny)))
    afterEdit(E.zone())
    return index
end

function E.deleteCorner(a, index)
    if refuseLocked() then return false end
    if not (a and a.corners and index) then return false end
    local n = #a.corners / 2
    if n <= 3 then
        E.notice(format("a polygon needs at least 3 corners - this one has %d, so none can go.", n))
        return false
    end
    E.pushUndo(nil)
    R.removeCorner(a.corners, index)
    afterEdit(E.zone())
    return true
end

ns.editorDrawing = function() return E.draft ~= nil and E.draft.kind == "polygon" end

-- Canvas input --------------------------------------------------------------------------
--
-- In map coordinates from Canvas.lua, plus the canvas pixel under the cursor
-- (px, py, unclamped). A caller that leaves the pixel out gets it from the view.
-- Every reach - handles, closing a shape, the click slop - is in canvas pixels
-- on screen, so it feels the same at every zoom.
--
-- A left press on the map that is not on a handle or a shape is not acted on at
-- once (feedback-1.md item 1): if it moves under E.CLICK_SLOP pixels before the
-- release it is a click and goes to the tool; if it moves further while the map
-- is zoomed, it pans the map and places nothing. At fit there is nothing to pan,
-- so every press there is a click.

local polyPx = {}

E.fitView = R.newView()

local function view()
    return (E.canvas and E.canvas.view) or E.fitView
end

E.view = view

local function toPx(nx, ny) return R.mapToView(view(), nx, ny, CANVAS_W, CANVAS_H) end

-- Canvas pixels per normalized unit in x, at the current zoom.
local function zoomedW() return CANVAS_W * view().zoom end

local function cornersToPx(corners, out)
    local n = #corners - #corners % 2
    for k = 1, n, 2 do out[k], out[k + 1] = toPx(corners[k], corners[k + 1]) end
    for k = #out, n + 1, -1 do out[k] = nil end
    return out
end

-- The topmost placed area under a point: highest priority first, and among equal
-- priorities the later one, the same order the engine paints them.
function E.hitArea(nx, ny)
    local z = E.zone()
    if not (z and z.areas) then return nil end
    local W = E.scale()
    local px, py = toPx(nx, ny)
    local layers = ns.layersFor(z)
    for i = #layers, 1, -1 do
        local a = layers[i]
        if a.corners and #a.corners >= 6 then
            cornersToPx(a.corners, polyPx)
            if R.pointInPolygon(polyPx, px, py) or R.distToOutline(polyPx, px, py) <= 5 then
                return a
            end
        elseif a.x and a.y then
            local cx, cy = toPx(a.x, a.y)
            local d = sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
            local rin = W and a.innerYards and R.yardsToPixels(a.innerYards, zoomedW(), W) or 0
            if d <= max(rin, 6) + 4 then return a end
        end
    end
    return nil
end

-- Which handle of the selected area is under a point: "corner" and its index,
-- "mid" and the edge whose midpoint handle it is, or a circle's "inner",
-- "falloff" or "body". Corners come before midpoints.
function E.hitHandle(a, nx, ny)
    if not a then return nil end
    local px, py = toPx(nx, ny)
    local reach = Canvas.HANDLE
    if a.corners then
        for k = 1, #a.corners - 1, 2 do
            local hx, hy = toPx(a.corners[k], a.corners[k + 1])
            if abs(hx - px) <= reach and abs(hy - py) <= reach then
                return "corner", (k + 1) / 2
            end
        end
        cornersToPx(a.corners, polyPx)
        local edge = R.nearestMidpoint(polyPx, px, py, reach, Canvas.MID_MIN)
        if edge then return "mid", edge end
    elseif a.x then
        local W = E.scale()
        local cx, cy = toPx(a.x, a.y)
        if W then
            local rin = a.innerYards and R.yardsToPixels(a.innerYards, zoomedW(), W)
            local rout = a.falloffYards and R.yardsToPixels(a.falloffYards, zoomedW(), W)
            if rout and abs(cx + rout - px) <= reach and abs(cy - py) <= reach then return "falloff" end
            if rin and abs(cx + rin - px) <= reach and abs(cy - py) <= reach then return "inner" end
        end
        if abs(cx - px) <= reach and abs(cy - py) <= reach then return "body" end
    end
    return nil
end

local function yardsBetween(ax, ay, bx, by)
    local W, H = E.scale()
    if not W then return nil end
    local dx, dy = (bx - ax) * W, (by - ay) * H
    return sqrt(dx * dx + dy * dy)
end

local function setDragging(on)
    if E.canvas then E.canvas.dragging = on and true or false end
end

function E.onCanvasDown(button, nx, ny, inside, px, py)
    if not (E.canvas and E.canvas.hasArt) then return end
    if refuseLocked() then return end
    if not px then px, py = toPx(nx, ny) end
    E.press = nil

    if button == "RightButton" then
        if E.tool == "polygon" then
            if not E.draft then E.startPolygon() end
            E.removeDraftCorner()
            E.refresh()
        elseif E.tool == "select" then
            -- On a corner of the selected polygon it removes that corner;
            -- anywhere else it lets go of the selection.
            local handle, index = E.hitHandle(E.selected, nx, ny)
            if handle == "corner" then
                E.deleteCorner(E.selected, index)
            else
                E.selected = nil
            end
            E.refresh()
        end
        return
    end
    if button ~= "LeftButton" then return end

    if E.tool == "circle" then
        E.startCircle(nx, ny)
        E.drag = { kind = "newCircle" }
        setDragging(true)
        return
    end

    if E.tool == "select" then
        local a = E.selected
        local handle, index = E.hitHandle(a, nx, ny)
        if not handle then
            local hit = E.hitArea(nx, ny)
            if hit then a, handle = hit, "body" end
        end
        if a and handle then
            E.selected = a
            if handle == "mid" then
                -- A new corner at the edge's middle, then dragged like any other.
                -- The insert took the undo snapshot, so the drag does not take one.
                local mx, my = R.edgeMidpoint(a.corners, index)
                local at = E.insertCorner(a, index, mx, my)
                if at then
                    E.drag = { kind = "corner", index = at, area = a, moved = true }
                    setDragging(true)
                end
            else
                -- The undo snapshot is taken on the first move, so a click that
                -- only selects leaves nothing to undo.
                local orig = a.corners and copyArea(a).corners or { a.x, a.y }
                E.drag = { kind = handle, index = index, area = a, sx = nx, sy = ny, orig = orig }
                setDragging(true)
            end
            E.refresh()
            return
        end
    end

    -- The Polygon tool, or Select on empty map: a click or a pan, decided at release.
    E.press = { px = px, py = py, lastPx = px, lastPy = py, nx = nx, ny = ny }
    setDragging(true)
end

function E.onCanvasMove(nx, ny, inside, px, py)
    if not px then px, py = toPx(nx, ny) end
    if E.locked() and (E.drag or E.press) then
        E.drag, E.press = nil, nil
        setDragging(false)
    end

    local p = E.press
    if p then
        if not p.panning and view().zoom > 1
            and sqrt((px - p.px) ^ 2 + (py - p.py) ^ 2) >= E.CLICK_SLOP then
            p.panning = true
        end
        if p.panning and E.canvas then
            E.canvas:panBy(px - p.lastPx, py - p.lastPy)
            p.lastPx, p.lastPy = px, py
        end
    end

    local d = E.drag
    if d then
        local zone = E.zone()
        if d.kind == "newCircle" and E.draft then
            local r = yardsBetween(E.draft.x, E.draft.y, nx, ny)
            if r then
                E.draft.innerYards = round(r, 1)
                syncDraft(E.draft)
            end
            E.needsRender, E.needsProps = true, true
        elseif zone and d.area then
            local a = d.area
            if not d.moved then E.pushUndo(nil) end
            if d.kind == "corner" then
                a.corners[d.index * 2 - 1] = R.round4(nx)
                a.corners[d.index * 2] = R.round4(ny)
            elseif d.kind == "body" then
                local dx, dy = nx - d.sx, ny - d.sy
                local o = d.orig
                -- Clamped so every point stays on the map.
                local minX, maxX, minY, maxY = 1, 0, 1, 0
                for k = 1, #o - 1, 2 do
                    minX, maxX = min(minX, o[k]), max(maxX, o[k])
                    minY, maxY = min(minY, o[k + 1]), max(maxY, o[k + 1])
                end
                dx = max(-minX, min(1 - maxX, dx))
                dy = max(-minY, min(1 - maxY, dy))
                if a.corners then
                    for k = 1, #o - 1, 2 do
                        a.corners[k] = R.round4(o[k] + dx)
                        a.corners[k + 1] = R.round4(o[k + 1] + dy)
                    end
                else
                    a.x, a.y = R.round4(o[1] + dx), R.round4(o[2] + dy)
                end
            elseif d.kind == "inner" then
                -- The fade rides on top of the inner radius (item 11), so moving
                -- the inner edge carries the outer one with it.
                local r = yardsBetween(a.x, a.y, nx, ny)
                if r then
                    local fade = E.falloffToFade("circle", a.innerYards, a.falloffYards) or 0
                    a.innerYards = round(r, 1)
                    a.falloffYards = round(a.innerYards + fade, 1)
                end
            elseif d.kind == "falloff" then
                local r = yardsBetween(a.x, a.y, nx, ny)
                if r then a.falloffYards = round(max(r, a.innerYards or 0), 1) end
            end
            d.moved = true
            afterEdit(zone, true)
        end
    end

    -- The rubber band, and the readout.
    if E.canvas and E.draft and E.draft.kind == "polygon" and #E.draft.corners >= 2 then
        local c = E.draft.corners
        E.canvas:setRubber(c[#c - 1], c[#c], nx, ny)
    elseif E.canvas then
        E.canvas:setRubber(nil)
    end
    E.hover = { nx, ny, inside }
    E.updateReadout()
end

function E.onCanvasUp(button, nx, ny, inside, px, py)
    local p = E.press
    if p and button == "LeftButton" then
        E.press = nil
        setDragging(false)
        if p.panning or E.locked() then return end
        E.click(p.nx, p.ny, p.px, p.py)
        return
    end
    local d = E.drag
    E.drag = nil
    setDragging(false)
    if not d then return end
    if d.kind == "newCircle" then
        E.say("the fade starts at " .. Preset.num(E.defaultFade(), 1)
            .. " yd - change Fade (yd) if you like, then press Finish.")
        E.refresh()
        return
    end
    if d.moved then
        E.flushDraft()
        E.refresh()
    end
end

-- A click on the map, once it is known not to be a pan.
function E.click(nx, ny, px, py)
    if not px then px, py = toPx(nx, ny) end
    if E.tool == "polygon" then return E.polygonClick(nx, ny, px, py) end
    if E.tool == "select" then
        E.selected = nil
        E.refresh()
    end
end

-- The Polygon tool's click (feedback-1.md item 2). On any corner already placed,
-- once there are 3, it closes the shape exactly as Finish does - which also
-- covers a double-click, whose second click lands on the corner the first one
-- placed. With fewer than 3, a click on a placed corner is refused rather than
-- stacking a second corner on it.
function E.polygonClick(nx, ny, px, py)
    if not E.draft then E.startPolygon() end
    local d = E.draft
    local n = #d.corners / 2
    local hit = n >= 1 and R.nearestCorner(cornersToPx(d.corners, polyPx), px, py, E.CLOSE_REACH)
    if hit then
        if n >= 3 then
            E.finishDraft()
        else
            E.notice("a polygon needs at least 3 corners - place another one before closing it.")
        end
        E.refresh()
        return
    end
    E.addDraftCorner(nx, ny)
    E.setKeyboard(true)
    E.refresh()
end

-- The readout: what the engine would apply at the point under the cursor, among
-- the areas that can be located on the map, highest first. The indoor state is
-- not known for a point on a map, so gated areas are listed with their gate
-- rather than dropped (DESIGN-ui.md 6.4; IDEAS.md idea 3).
function E.readoutText(nx, ny)
    local z = E.zone()
    local parts = { format("under cursor: %.4f, %.4f", nx, ny) }
    if not z then return parts[1] end
    local W, H = E.scale()
    local layers = ns.layersFor(z)
    local hits, unplaced = {}, {}
    for i = #layers, 1, -1 do
        local a = layers[i]
        if isPlaced(a) then
            local w = ns.weightOf(a, nil, nx, ny, a.indoors == true, W, H)
            if w > 0 then hits[#hits + 1] = { a = a, w = w } end
        else
            local label = a.subzone and (a.subzone .. " (by name)") or (a.name or "indoor rule")
            unplaced[#unplaced + 1] = label
        end
    end
    if not W then
        parts[#parts + 1] = "map scale unavailable - placed areas cannot be weighed"
    elseif #hits == 0 then
        parts[#parts + 1] = "no placed area here"
    else
        local list = {}
        for i = 1, #hits do
            local h = hits[i]
            local gate = h.a.indoors == true and " [indoors]" or (h.a.indoors == false and " [outdoors]" or "")
            list[#list + 1] = format("%s%s (p%d)%s w=%.2f", i == 1 and "wins here: " or "",
                areaName(h.a), h.a.priority or 0, gate, h.w)
        end
        parts[#parts + 1] = table.concat(list, "; ")
    end
    if #unplaced > 0 then
        parts[#parts + 1] = "cannot be located on the map: " .. table.concat(unplaced, ", ")
    end
    return table.concat(parts, "  |  ")
end

function E.updateReadout()
    if not (E.built and E.readout) then return end
    local h = E.hover
    if h and h[3] then
        E.readout:SetText(E.readoutText(h[1], h[2]))
    else
        E.readout:SetText("")
    end
end

-- Keyboard while a polygon is drawn: Enter closes it, Escape cancels it, and
-- every other key goes on to the game so the player can still walk. Only switched
-- on if passing keys on is known to work - a keyboard that swallowed movement
-- would be far worse than having to press Finish.
--
-- Never in combat. Retail refuses SetPropagateKeyboardInput in combat without
-- raising, so a capture started or continued there could swallow every key,
-- movement included. In combat the shape is drawn and closed by mouse (the first
-- corner again, a double-click, Finish); Enter and Escape are simply not
-- shortcuts until it ends. Where the client can say, the setting is read back,
-- and a propagate that did not take turns the keyboard off.
local function inCombat()
    local ok, v = UI.callG("InCombatLockdown")
    return ok and v and true or false
end

E.inCombat = inCombat

function E.setKeyboard(on)
    local f = E.canvas and E.canvas.frame
    if not f then return false end
    if on and not inCombat() then
        local ok = UI.call(f, "SetPropagateKeyboardInput", true)
        if ok and type(UI.get(f, "GetPropagateKeyboardInput")) == "function" then
            local okGet, took = UI.call(f, "GetPropagateKeyboardInput")
            ok = okGet and took == true
        end
        if ok then
            UI.call(f, "EnableKeyboard", true)
            return true
        end
    end
    UI.call(f, "EnableKeyboard", false)
    return false
end

-- Zone selection --------------------------------------------------------------------------

local function mapInfo(id)
    local C = UI.G("C_Map")
    local f = UI.get(C, "GetMapInfo")
    if type(f) ~= "function" or not id then return nil end
    local ok, info = pcall(f, id)
    if ok and type(info) == "table" then return info end
    return nil
end

-- The zone-level map for a map ID: a dungeon or micro map (UIMapType 4 or 5)
-- walks up to the zone that holds it.
local function zoneMapOf(id)
    local seen = 0
    while id and seen < 5 do
        local info = mapInfo(id)
        if not info then return id end
        local t = tonumber(info.mapType)
        if not t or t <= 3 then return id end
        id = tonumber(info.parentMapID)
        seen = seen + 1
    end
    return id
end

-- The dropdown's entries, in order: where the player is, every configured zone,
-- then every zone on the current continent (DESIGN-ui.md 6.1).
function E.zoneItems()
    local items, seen = {}, {}
    local function add(name, mapID, note)
        if type(name) ~= "string" or name == "" or seen[name] then return end
        seen[name] = true
        items[#items + 1] = { text = name, value = name, mapID = mapID, note = note }
    end

    local here = ns.zoneNames()
    local hereMap = zoneMapOf(ns.currentMap and ns.currentMap())
    if here then
        local z = Config.zones[here]
        local map = (z and z.map) or hereMap
        local info = mapInfo(map)
        local note
        if info and plain(info.name) and plain(info.name) ~= here then
            note = format("the map calls this zone %q; the game reports %q, which is the key "
                .. "used", plain(info.name), here)
        end
        add(here, map, note)
    end

    local names = {}
    for name in pairs(Config.zones) do
        if type(name) == "string" then names[#names + 1] = name end
    end
    table.sort(names)
    for i = 1, #names do add(names[i], Config.zones[names[i]].map) end

    local info = mapInfo(hereMap)
    local parent = info and tonumber(info.parentMapID)
    if parent then
        local C = UI.G("C_Map")
        local f = UI.get(C, "GetMapChildrenInfo")
        if type(f) == "function" then
            local ok, children = pcall(f, parent)
            if ok and type(children) == "table" then
                local list = {}
                for i = 1, #children do
                    local c = children[i]
                    if type(c) == "table" and plain(c.name) then
                        list[#list + 1] = { name = plain(c.name), mapID = tonumber(c.mapID) }
                    end
                end
                table.sort(list, function(a, b) return a.name < b.name end)
                for i = 1, #list do add(list[i].name, list[i].mapID) end
            end
        end
    end
    return items
end

function E.selectZone(name, mapID, note)
    if not name then return end
    E.cancelDraft(true)
    E.drag, E.selected, E.press = nil, nil, nil
    E.zoneName, E.mapNote = name, note
    local z = Config.zones[name]
    E.mapID = (z and z.map) or mapID
    if not E.mapID then
        for _, it in ipairs(E.zoneItems()) do
            if it.value == name then E.mapID = it.mapID end
        end
    end
    if z then ns.prepareZone(z, name) end
    E.W, E.H = nil, nil
    if not (z and z.__W) and ns.mapWorldSize then E.W, E.H = ns.mapWorldSize(E.mapID) end
    if E.built then
        E.canvas:setMap(E.mapID)
        if E.zoneDrop then E.zoneDrop.setText(name) end
    end
    E.refresh()
end

function E.goToMyZone()
    local items = E.zoneItems()
    local here = ns.zoneNames()
    for i = 1, #items do
        if items[i].value == here then return E.selectZone(here, items[i].mapID, items[i].note) end
    end
    if items[1] then E.selectZone(items[1].value, items[1].mapID, items[1].note) end
end

-- Saving, and the recovery draft --------------------------------------------------------------
--
-- Every edit is saved to the store here (the retargeted flush of DESIGN-ui.md
-- 6.10: the same trigger points, a table instead of lines). On a regressed build
-- only, the recovery draft of the generated Zones.lua is written as well.

function E.flushDraft()
    if not E.draftPending then return end
    -- Not the sender's zone: the save waits for Accept or Decline.
    if E.locked() then return end
    E.draftPending = false
    E.flushStore()
    E.lastFlush = now()
    if not regressed() then return end
    -- One string per line of Zones.lua (feedback-1.md item 9): the client escapes
    -- every newline in a saved string, so a single string reached the file as one
    -- unreadable line. The lines use long-bracket strings, so none holds a `"`
    -- for the client to escape either.
    local ok, lines = pcall(Serialize.draftLines, Config.zones)
    if not ok then return tellError("writing the recovery draft", lines) end
    if type(DynamicAmbianceDB) ~= "table" then DynamicAmbianceDB = {} end
    DynamicAmbianceDB.editor = {
        where = "copy every line of draftLines, in order, into Zones.lua",
        when  = Serialize.now(),
        unsavedZones = E.dirtyCount(),
        draftLines = lines,
    }
    E.lastFlush = now()
end

-- An import accepted through Share.lua is a change to the zones too.
ns.onZoneChanged = function(name)
    if type(name) == "string" then E.storePending[name] = true end
    E.draftPending = true
    E.flushDraft()
    E.refresh()
end

-- An import preview opening and closing (Share.lua). Opening locks the editor
-- (E.locked) and remembers what it had selected; any gesture in flight is
-- dropped. Closing puts the editor back: on Decline the player's own zone is
-- back under the same table, so the old selection is restored; on Import the
-- zone was replaced, so nothing is selected. Either way the recovery draft,
-- held while locked, is written from the player's own zones.
ns.onOfferOpened = function(zoneName)
    E.preOffer = { selected = E.selected, zoneName = zoneName }
    E.selected = nil
    E.drag = nil
    if E.canvas then E.canvas.dragging = false end
    E.lastKey = nil
    E.say(E.LOCK_NOTE)
    E.refresh()
end

ns.onOfferClosed = function(keep)
    local saved = E.preOffer
    E.preOffer = nil
    E.drag, E.lastKey = nil, nil
    if E.canvas then E.canvas.dragging = false end
    local sel = saved and saved.selected
    E.selected = nil
    local z = E.zone()
    if not keep and sel and z and z.areas then
        for i = 1, #z.areas do
            if z.areas[i] == sel then E.selected = sel end
        end
    end
    if E.message == E.LOCK_NOTE then E.say(nil) end
    E.draftPending = true
    E.flushDraft()
    E.refresh()
end

-- Save to file and import ------------------------------------------------------------------

-- The text for the big box: the whole Zones.lua, or one zone's DA2 string. Both
-- are exports, so versions are bumped here for changed zones.
function E.saveText()
    -- Nothing is generated from a previewed zone: it is not the player's yet,
    -- and generating would also stamp its version as exported.
    if E.locked() then return "-- " .. E.LOCK_NOTE end
    if E.saveMode == "file" then
        return Serialize.exportFile(Config.zones)
    end
    local s, err = Serialize.presetString(E.saveMode)
    if not s then return "-- could not export " .. tostring(E.saveMode) .. ": " .. tostring(err) end
    return s
end

function E.refreshSaveBox()
    local ok, text = pcall(E.saveText)
    if not ok then
        tellError("generating the text", text)
        text = ""
    end
    E.saveBoxText = text
    if E.built and E.saveBox then E.saveBox:SetText(text) end
    if E.built and E.saveNote then E.saveNote:SetText(E.saveNoteText()) end
    return text
end

-- Select all: rebuilt first so the box is never stale. Selecting the whole file
-- for copying is the last thing the addon can see of a save, so that is where
-- the unsaved counter clears.
function E.selectAll()
    local text = E.refreshSaveBox()
    if E.built and E.saveBox then
        UI.call(E.saveBox, "SetFocus")
        UI.call(E.saveBox, "HighlightText")
    end
    if E.locked() then
        E.say(E.LOCK_NOTE)
        return text
    end
    if E.saveMode == "file" then
        for _, z in pairs(Config.zones) do
            if type(z) == "table" then z.__dirty = nil end
        end
        E.refresh()
    end
    return text
end

-- Export (DESIGN-ui.md 7.1) ------------------------------------------------------------------
--
-- One zone's DA2 string. Rebuilt when the panel opens, when the dropdown changes
-- and on Select all, so the box is never stale; each rebuild is an export
-- (Store.exportZone: the version bumps if the zone changed, the string becomes
-- its revert point, and it is logged).

function E.exportText()
    if E.locked() then return "-- " .. E.LOCK_NOTE end
    local name = E.exportZone
    if not (name and Config.zones[name]) then
        name = (E.zoneName and Config.zones[E.zoneName]) and E.zoneName or nil
        if not name then
            local names = {}
            for n in pairs(Config.zones) do names[#names + 1] = n end
            table.sort(names)
            name = names[1]
        end
        E.exportZone = name
    end
    if not name then return "-- no zones yet: draw an area first." end
    local s, err
    if ns.Store then
        s, err = ns.Store.exportZone(name)
    else
        s, err = Serialize.presetString(name)
    end
    if not s then return "-- could not export " .. tostring(name) .. ": " .. tostring(err) end
    return s
end

function E.refreshExportBox()
    local ok, text = pcall(E.exportText)
    if not ok then
        tellError("generating the preset string", text)
        text = ""
    end
    E.exportBoxText = text
    if E.built and E.exportBox then E.exportBox:SetText(text) end
    if E.built and E.exportDrop and E.exportZone then E.exportDrop.setText(E.exportZone) end
    E.refreshExportNote()
    E.needsProps = true
    return text
end

function E.exportSelectAll()
    local text = E.refreshExportBox()
    if E.built and E.exportBox then
        UI.call(E.exportBox, "SetFocus")
        UI.call(E.exportBox, "HighlightText")
    end
    return text
end

-- Copy to clipboard (feedback-2.md item 5) -----------------------------------------------------
--
-- CopyToClipboard is on this client and flagged HasRestrictions, with
-- SecretArguments = AllowedWhenUntainted (Blizzard's documentation for 70009),
-- and nobody has measured whether an addon may call it from a click. So it is an
-- attempt, made only from the footer's Export click (a hardware event), inside
-- pcall, with ADDON_ACTION_BLOCKED and ADDON_ACTION_FORBIDDEN watched while it
-- runs: a refusal on this client often fires one of those and returns normally,
-- so a pcall alone would report a false success. It counts as
-- copied only when it did not raise, no refusal naming this addon arrived, and
-- it returned a positive length. The outcome is kept per build in
-- DynamicAmbianceDB.clipboard, and anything but "copied" is not tried again on
-- that build: an "interface action failed" on every export would be worse than
-- the instruction under the box. `/amb status` reports it.

-- How long the watch stays up after the call, for a refusal delivered late.
E.CLIP_WATCH_SECONDS = 1

local clipWatch = { frame = nil, armed = false, refused = nil, recorded = false, token = 0 }

local function clipBuild()
    local b = ns.Store and ns.Store.buildString and ns.Store.buildString()
    return b or "unknown"
end

-- This build's recorded outcome, or nil when Export has not tried yet.
function E.clipboardRecord()
    local t = type(DynamicAmbianceDB) == "table" and DynamicAmbianceDB.clipboard
    local r = type(t) == "table" and t[clipBuild()] or nil
    return type(r) == "table" and r or nil
end

local function recordClip(outcome, detail, length)
    if type(DynamicAmbianceDB) ~= "table" then DynamicAmbianceDB = {} end
    local t = DynamicAmbianceDB.clipboard
    if type(t) ~= "table" then t = {}; DynamicAmbianceDB.clipboard = t end
    local r = { outcome = outcome, detail = detail, length = length, when = Serialize.now() }
    t[clipBuild()] = r
    return r
end

-- Built on the first attempt, so a player who never presses Export never has it.
local function clipWatcher()
    if clipWatch.frame then return clipWatch.frame end
    local w = UI.create("Frame", "DynamicAmbianceClipboardWatcher")
    if not w then return nil end
    w:SetScript("OnEvent", function(_, event, a, b)
        if not clipWatch.armed then return end
        local who, what = plain(a), plain(b)
        if who ~= ADDON and not (what and what:find("CopyToClipboard", 1, true)) then return end
        local detail = tostring(event) .. " (" .. (what or "?") .. ")"
        clipWatch.refused = detail
        -- Arriving after the call returned: a "copied" already recorded was not.
        local r = clipWatch.recorded and E.clipboardRecord()
        if r and r.outcome == "copied" then
            recordClip("blocked", detail)
            E.clipCopiedText = nil
            E.refreshExportNote()
        end
    end)
    if ns.register then
        ns.register(w, "ADDON_ACTION_BLOCKED")
        ns.register(w, "ADDON_ACTION_FORBIDDEN")
    end
    clipWatch.frame = w
    return w
end

-- What a returned value looks like in the record, without trusting it.
local function shown(v)
    local t = type(v)
    if t == "number" or t == "string" then return plain(v) or "an unreadable value" end
    return t
end

-- The attempt, for one DA2 string. Returns true when it is on the clipboard.
function E.copyExport(text)
    local head = Preset.VERSION .. "~"
    if type(text) ~= "string" or text:sub(1, #head) ~= head then return false end
    local r = E.clipboardRecord()
    if r and r.outcome ~= "copied" then return false end
    local fn = UI.G("CopyToClipboard")
    if type(fn) ~= "function" then
        recordClip("absent", "no CopyToClipboard on this client")
        E.refreshExportNote()
        return false
    end
    clipWatcher()
    clipWatch.token = clipWatch.token + 1
    clipWatch.armed, clipWatch.refused, clipWatch.recorded = true, nil, false
    local ok, n = pcall(fn, text, false)
    local length
    if ok then
        local okN, positive = pcall(function() return type(n) == "number" and n > 0 end)
        if okN and positive then length = n end
    end
    local outcome, detail
    if not ok then
        outcome, detail = "raised", shown(n)
    elseif clipWatch.refused then
        outcome, detail = "blocked", clipWatch.refused
    elseif not length then
        outcome, detail = "zero", "returned " .. shown(n)
    else
        outcome = "copied"
    end
    recordClip(outcome, detail, length)
    clipWatch.recorded = true
    local token = clipWatch.token
    local function disarm()
        if clipWatch.token == token then clipWatch.armed = false end
    end
    local after = UI.get(UI.G("C_Timer"), "After")
    if type(after) ~= "function" or not pcall(after, E.CLIP_WATCH_SECONDS, disarm) then disarm() end
    E.clipCopiedText = outcome == "copied" and text or nil
    E.refreshExportNote()
    return outcome == "copied"
end

-- The line under the Export panel's box: "Copied" only while the box holds the
-- string that was copied; the instruction whenever the copy is not known to
-- have worked for what is in the box.
function E.exportNoteText()
    if E.clipCopiedText and E.clipCopiedText == E.exportBoxText then return E.CLIP_COPIED end
    return E.CLIP_HINT
end

function E.refreshExportNote()
    if E.built and E.exportNote then E.exportNote:SetText(E.exportNoteText()) end
end

-- For `/amb status`: whether Export has tried on this build, whether it worked,
-- and the line that says so.
function E.clipboardReport()
    local build = clipBuild()
    local r = E.clipboardRecord()
    if not r then
        return false, false, format("not tried yet on build %s - press Export at the editor's "
            .. "bottom right (/amb ui), then run /amb status again.", build)
    end
    local when = tostring(r.when or "?")
    if r.outcome == "copied" then
        return true, true, format("Export copied the preset string (%s characters) on build %s, "
            .. "%s - paste it somewhere to confirm.", tostring(r.length or "?"), build, when)
    end
    local what = ({
        raised  = "CopyToClipboard raised",
        blocked = "the client refused CopyToClipboard",
        zero    = "CopyToClipboard copied nothing",
        absent  = "there is no CopyToClipboard",
    })[r.outcome] or ("unknown outcome " .. tostring(r.outcome))
    return true, false, format("%s on build %s, %s: %s. Export shows \"%s\" instead and does not "
        .. "try again on this build.", what, build, when, tostring(r.detail or "-"), E.CLIP_HINT)
end

-- The footer's first button: Export on a normal build, with the copy attempt;
-- Save to file on a regressed one.
function E.footerClicked()
    if regressed() then return E.openSave() end
    if not E.open("export") then return false end
    if not E.locked() then E.copyExport(E.exportBoxText) end
    return true
end

-- Revert to last export (DESIGN-ui.md 6.10) ----------------------------------------------------

-- The button's tooltip, or nil and the reason it is disabled. The label is
-- always E.REVERT_LABEL; the version and the when moved here (feedback-2.md
-- item 3), in the format the label used to carry them.
function E.revertTooltip(name)
    local e = ns.Store and name and ns.Store.getRevert(name)
    if not e then return nil, "never exported" end
    return format("Last export: v%s, %s", tostring(e.version or "?"), tostring(e.when or "?"))
end

function E.requestRevert()
    if refuseLocked() then return false end
    local name = E.zoneName
    local e = ns.Store and name and ns.Store.getRevert(name)
    if not e then
        E.say("never exported - there is nothing to revert to.")
        return false
    end
    E.pendingRevert = name
    local dialogs = UI.G("StaticPopupDialogs")
    local shown = false
    if type(dialogs) == "table" and dialogs[POPUP_REVERT] then
        shown = UI.callG("StaticPopup_Show", POPUP_REVERT, name, tostring(e.when or "?"))
    end
    if not shown then return E.confirmRevert() end
    return true
end

-- The stored string, back through parse and validate, replaces the zone: a
-- fresh table, so the layer cache re-sorts. One undo step.
function E.confirmRevert()
    local name = E.pendingRevert or E.zoneName
    E.pendingRevert = nil
    if refuseLocked() then return false end
    local e = ns.Store and name and ns.Store.getRevert(name)
    if not e then return false end
    local parsedName, zone = Preset.parse(e.string)
    if not parsedName then
        E.say("the stored string does not parse: " .. tostring(zone))
        return false
    end
    local ok, problems = Preset.validate(parsedName, zone)
    if not ok then
        E.say("the stored string is refused: " .. table.concat(problems, "; "))
        return false
    end
    if E.zoneName ~= name then E.selectZone(name) end
    E.pushUndo(nil)
    local old = Config.zones[name]
    zone.origin = old and old.origin or "editor"
    zone.export = { pending = false, manual = false, once = true }
    for i = 1, #(zone.areas or {}) do zone.areas[i].origin = zone.origin end
    if regressed() then zone.__dirty = true end
    Config.zones[name] = zone
    ns.prepareZone(zone, name)
    E.selected = nil
    E.lastKey = nil
    E.storePending[name] = true
    E.draftPending = true
    if ns.refreshTarget then pcall(ns.refreshTarget, true) end
    E.flushDraft()
    E.refresh()
    out(format("%s is back to the string exported on %s.", name, tostring(e.when or "?")))
    return true
end

-- Delete zone (DESIGN-ui.md 6.10) ---------------------------------------------------------------

function E.requestDeleteZone()
    if refuseLocked() then return false end
    local z = E.zone()
    if not z then return false end
    E.pendingDeleteZone = E.zoneName
    local dialogs = UI.G("StaticPopupDialogs")
    local shown = false
    if type(dialogs) == "table" and dialogs[POPUP_DELZONE] then
        local n = #(z.areas or {})
        shown = UI.callG("StaticPopup_Show", POPUP_DELZONE,
            format("%s and its %d area%s", E.zoneName, n, n == 1 and "" or "s"))
    end
    if not shown then return E.confirmDeleteZone() end
    return true
end

-- Removed from Config.zones, the store and its revert point, as one undo step.
function E.confirmDeleteZone()
    local name = E.pendingDeleteZone or E.zoneName
    E.pendingDeleteZone = nil
    if refuseLocked() or not (name and Config.zones[name]) then return false end
    if E.zoneName ~= name then E.selectZone(name) end
    E.pushUndo(nil)
    Config.zones[name] = nil
    E.selected = nil
    E.lastKey = nil
    E.storePending[name] = true
    E.draftPending = true
    if ns.refreshTarget then pcall(ns.refreshTarget, true) end
    E.flushDraft()
    E.refresh()
    out(format("deleted %s. Undo brings it back.", name))
    return true
end

-- Import: the same parse and the same confirmation /amb import uses - live
-- preview, Import / Decline / Never from them, replace only. Returns true when a
-- confirmation opened.
function E.importText(text)
    local body = ns.presetBody(text or "")
    if body == "" then
        E.setImportError("paste a preset string first.")
        return false
    end
    local name, zone = Preset.parse(body)
    if not name then
        E.setImportError("not a preset: " .. tostring(zone))
        return false
    end
    local ok, problems = Preset.validate(name, zone)
    if not ok then
        E.setImportError("refused: " .. table.concat(problems, "; "))
        return false
    end
    local opened, why = ns.offerPreset(name, zone, nil, body)
    if not opened then
        E.setImportError("not opened: " .. tostring(why))
        return false
    end
    E.setImportError(nil)
    return true
end

function E.setImportError(msg)
    E.importError = msg
    local text = msg and ("|cffff6060" .. msg .. "|r") or ""
    if E.built and E.importErr then E.importErr:SetText(text) end
end

-- Messages under the properties panel.
function E.say(msg)
    E.message = msg
    if E.built and E.msgText then E.msgText:SetText(msg or "") end
end

-- A refusal made while drawing or editing a shape: said under the properties
-- panel as ever, and also on the canvas itself, where the player is looking,
-- for E.NOTICE_SECONDS (feedback-1.md item 4).
function E.notice(msg)
    E.say(msg)
    E.noticeText = msg
    E.noticeUntil = now() + E.NOTICE_SECONDS
    if E.built and E.canvas then E.canvas:setNotice(msg) end
end

function E.clearNotice()
    E.noticeText, E.noticeUntil = nil, nil
    if E.built and E.canvas then E.canvas:setNotice(nil) end
end

-- A value a box refused (feedback-1.md item 11): the reason goes next to the box
-- that caused it and into a popup with an OK, as well as under the panel, so it
-- is never only in the footer. It clears on the next good value or selection.
function E.fieldError(box, msg)
    E.say(msg)
    E.fieldErr = { box = box, msg = msg }
    local label = E.built and E.errLabel
    if label then
        label:ClearAllPoints()
        local okW, w = UI.call(box, "GetWidth")
        if box and okW and type(w) == "number" and w < 100 then
            label:SetPoint("LEFT", box, "RIGHT", 8, 0)
        elseif box then
            label:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -2)
        else
            label:SetPoint("TOPLEFT", E.frame, "TOPLEFT", COL_X, COL_BOTTOM + 36)
        end
        label:SetText("|cffff6060" .. msg .. "|r")
        label:Show()
    end
    local dialogs = UI.G("StaticPopupDialogs")
    if type(dialogs) == "table" and dialogs[POPUP_FIELD] then
        UI.callG("StaticPopup_Show", POPUP_FIELD, msg)
    end
end

function E.clearFieldError()
    if not E.fieldErr then return end
    E.fieldErr = nil
    if E.built and E.errLabel then
        E.errLabel:SetText("")
        E.errLabel:Hide()
    end
end

-- Widgets ------------------------------------------------------------------------------------

local function guarded(where, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then tellError(where, err) end
    end
end

local function setLabel(b, text)
    if b.label then b.label:SetText(text) else b:SetText(text) end
end

local function button(parent, text, w, h, onClick)
    local b, templ = UI.createOr("Button", nil, parent, "UIPanelButtonTemplate")
    if not b then return nil end
    b:SetSize(w, h or 22)
    if templ then
        b:SetText(text)
    else
        local bg = UI.texture(b, "BACKGROUND")
        if bg then bg:SetAllPoints(b); bg:SetColorTexture(0.22, 0.22, 0.28, 1) end
        b.label = UI.text(b, text, 11, "accent")
        if b.label then b.label:SetPoint("CENTER", b, "CENTER", 0, 0) end
        UI.call(b, "EnableMouse", true)
    end
    UI.call(b, "RegisterForClicks", "LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", guarded(text, function(self, btn) onClick(self, btn) end))
    return b
end

local function tooltip(frame, text)
    frame:SetScript("OnEnter", function(self)
        local tt = UI.G("GameTooltip")
        if tt then
            UI.call(tt, "SetOwner", self, "ANCHOR_TOP")
            UI.call(tt, "SetText", text)
            UI.call(tt, "Show")
        end
    end)
    frame:SetScript("OnLeave", function()
        local tt = UI.G("GameTooltip")
        if tt then UI.call(tt, "Hide") end
    end)
end

-- A single-line box that commits on Enter or on losing focus, and reverts on
-- Escape.
local function editBox(parent, w, maxLetters, onCommit)
    local eb, templ = UI.createOr("EditBox", nil, parent, "InputBoxTemplate")
    if not eb then return nil end
    eb:SetSize(w, 20)
    UI.call(eb, "SetAutoFocus", false)
    if maxLetters then UI.call(eb, "SetMaxLetters", maxLetters) end
    UI.font(eb, 11)
    if not templ then
        local bg = UI.texture(eb, "BACKGROUND")
        if bg then bg:SetAllPoints(eb); bg:SetColorTexture(0, 0, 0, 0.6) end
        UI.call(eb, "SetTextInsets", 4, 4, 0, 0)
    end
    eb.commit = function(text) if onCommit then onCommit(text) end end
    eb:SetScript("OnEnterPressed", function(self) UI.call(self, "ClearFocus") end)
    eb:SetScript("OnEscapePressed", function(self)
        self.reverting = true
        UI.call(self, "ClearFocus")
    end)
    eb:SetScript("OnEditFocusLost", guarded("a text box", function(self)
        if self.reverting then
            self.reverting = nil
            self:SetText(self.shown_ or "")
            return
        end
        if (self:GetText() or "") ~= (self.shown_ or "") then eb.commit(self:GetText()) end
    end))
    eb.set = function(text)
        eb.shown_ = text or ""
        eb:SetText(eb.shown_)
    end
    return eb
end

-- A multi-line box in a scroll frame.
local function multiBox(parent, w, h, maxLetters)
    local sf, templ = UI.createOr("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    if not sf then return nil end
    sf:SetSize(w, h)
    local bg = UI.texture(sf, "BACKGROUND")
    if bg then
        bg:SetPoint("TOPLEFT", sf, "TOPLEFT", -4, 4)
        bg:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", templ and 24 or 4, -4)
        bg:SetColorTexture(0, 0, 0, 0.65)
    end
    local eb = UI.create("EditBox", nil, sf)
    if not eb then return nil end
    UI.call(eb, "SetMultiLine", true)
    UI.call(eb, "SetAutoFocus", false)
    UI.call(eb, "SetMaxLetters", maxLetters or 0)
    -- Width only, as in the box M5 measured holding and copying 4000 characters:
    -- a multi-line box sizes its own height to its text inside the scroll frame.
    eb:SetWidth(w - (templ and 4 or 0))
    UI.font(eb, 11)
    eb:SetScript("OnEscapePressed", function(self) UI.call(self, "ClearFocus") end)
    UI.call(sf, "SetScrollChild", eb)
    -- A click anywhere in the box, not only on its text, puts the cursor in it.
    UI.call(sf, "EnableMouse", true)
    sf:SetScript("OnMouseDown", function() UI.call(eb, "SetFocus") end)
    return sf, eb
end

-- A slider with an exact-entry box and an Inherit checkbox. `onValue(v, light)`
-- gets nil for inherit.
local sliderCount = 0
local function axisRow(parent, axis, label, width, onValue)
    local row = { axis = axis }
    local lo, hi = limits(axis)
    local step = axis == "gamma" and 0.01 or 1
    row.title = UI.text(parent, label, 12, "accent")

    sliderCount = sliderCount + 1
    local name = "DynamicAmbianceEditorSlider" .. sliderCount
    local s, templ = UI.createOr("Slider", name, parent, "OptionsSliderTemplate")
    row.slider = s
    if s then
        s:SetSize(width, 16)
        UI.call(s, "SetOrientation", "HORIZONTAL")
        UI.call(s, "SetMinMaxValues", lo, hi)
        UI.call(s, "SetValueStep", step)
        UI.call(s, "SetObeyStepOnDrag", true)
        UI.call(s, "EnableMouse", true)
        if not templ then
            local track = UI.texture(s, "BACKGROUND")
            if track then track:SetAllPoints(s); track:SetColorTexture(0.15, 0.15, 0.18, 1) end
            local thumb = UI.texture(s, "OVERLAY")
            if thumb then
                thumb:SetSize(8, 16)
                thumb:SetColorTexture(1, 0.82, 0, 1)
                UI.call(s, "SetThumbTexture", thumb)
            end
        end
        -- The template's own Low / High / Text labels, whatever they are called
        -- on this client, are blanked; this row draws its own.
        for _, key in ipairs({ "Low", "High", "Text" }) do
            local r = UI.get(s, key) or UI.G(name .. key)
            if r then UI.call(r, "SetText", "") end
        end
        s:SetScript("OnValueChanged", guarded(label, function(self, v)
            if row.quiet then return end
            v = round(v, axis == "gamma" and 2 or 0)
            row.inherit:SetChecked(false)
            UI.call(self, "SetAlpha", 1)
            if row.box then row.box.set(axis == "gamma" and format("%.2f", v) or tostring(v)) end
            onValue(v, true)
        end))
        s:SetScript("OnMouseUp", function() E.lastKey = nil; E.flushDraft(); E.refresh() end)
    end

    row.box = editBox(parent, 48, 8, function(text)
        -- The numeric box clamps to Config.limits (DESIGN-ui.md 3.1). Anything
        -- that is not a finite number - "nan", "inf", "1e999" - puts back what
        -- was shown.
        local v = clampAxis(axis, number(text))
        if v == nil then row.box.set(row.box.shown_) return end
        onValue(v, false)
    end)

    local cb, ctempl = UI.createOr("CheckButton", nil, parent, "UICheckButtonTemplate")
    row.inherit = cb
    if cb then
        cb:SetSize(22, 22)
        local t = UI.get(cb, "text") or UI.get(cb, "Text")
        if t and UI.call(t, "SetText", E.INHERIT_LABEL) then
            row.inheritLabel = t
        else
            row.inheritLabel = UI.text(parent, E.INHERIT_LABEL, 11, "textMuted")
        end
        cb:SetScript("OnClick", guarded("Inherit", function(self)
            if self:GetChecked() then
                onValue(nil, false)
            else
                onValue(round(s and s:GetValue() or lo, axis == "gamma" and 2 or 0), false)
            end
        end))
    end

    -- Gamma carries tick labels at min, 1.0 and max, and two small marks at the
    -- operator's usable-by-eye range - labels, never bounds. All read from
    -- Config.limits and Config.hints.
    if axis == "gamma" and s then
        row.ticks = {}
        local function at(v) return (v - lo) / (hi - lo) * (width - 8) + 4 end
        for _, v in ipairs({ lo, 1.0, hi }) do
            local fs = UI.text(parent, Preset.num(v, 2), 9, "textMuted")
            if fs then row.ticks[#row.ticks + 1] = { fs = fs, x = at(v) } end
        end
        local hint = Config.hints and Config.hints.gammaEye
        if hint then
            for _, v in ipairs(hint) do
                local mark = UI.texture(parent, "OVERLAY")
                if mark then
                    mark:SetSize(2, 6)
                    mark:SetColorTexture(1, 0.82, 0, 0.9)
                    row.ticks[#row.ticks + 1] = { tex = mark, x = at(v) }
                end
            end
            local fs = UI.text(parent, format("usable by eye %s-%s", Preset.num(hint[1], 2),
                Preset.num(hint[2], 2)), 9, "accent")
            if fs then row.ticks[#row.ticks + 1] = { fs = fs, x = at(hint[1]) - 10, dy = -10 } end
        end
    end

    function row.place(x, y)
        if row.title then row.title:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y) end
        if s then s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 18) end
        if row.box then row.box:SetPoint("TOPLEFT", parent, "TOPLEFT", x + width + 12, y - 16) end
        if cb then cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x + width + 64, y - 15) end
        if row.inheritLabel and not UI.get(cb, "text") and not UI.get(cb, "Text") then
            row.inheritLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", x + width + 86, y - 20)
        end
        for _, t in ipairs(row.ticks or {}) do
            if t.fs then t.fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x + t.x - 8, y - 36 + (t.dy or 0)) end
            if t.tex then t.tex:SetPoint("TOPLEFT", parent, "TOPLEFT", x + t.x, y - 34) end
        end
        return (axis == "gamma") and 58 or 42
    end

    -- Shows a value, or the inherited one greyed with Inherit ticked.
    function row.show(value, inherited)
        row.quiet = true
        local v = value
        if v == nil then v = inherited end
        if s and v then s:SetValue(v) end
        if s then UI.call(s, "SetAlpha", value == nil and 0.4 or 1) end
        if cb then cb:SetChecked(value == nil) end
        if row.box then
            row.box.set(v and (axis == "gamma" and format("%.2f", v) or tostring(round(v, 1))) or "")
        end
        row.quiet = false
    end

    return row
end

-- A dropdown. UIDropDownMenuTemplate when it and its functions are present (M4:
-- the template creates; the functions are FrameXML and unmeasured, so looked up
-- here), otherwise a button that opens a plain list of our own.
local dropCount = 0
local function dropdown(parent, width, getItems, onPick)
    local dd = {}
    dropCount = dropCount + 1
    local name = "DynamicAmbianceEditorDrop" .. dropCount
    local api = UI.G("UIDropDownMenu_Initialize") and UI.G("UIDropDownMenu_AddButton")
        and UI.G("UIDropDownMenu_CreateInfo")
    local f = api and UI.create("Frame", name, parent, "UIDropDownMenuTemplate") or nil

    function dd.pick(value, item)
        dd.value = value
        dd.setText(item and item.text or tostring(value))
        onPick(value, item)
    end

    if f then
        dd.frame = f
        UI.callG("UIDropDownMenu_SetWidth", f, width)
        local function init(frame, level)
            local items = getItems() or {}
            for i = 1, #items do
                local it = items[i]
                local ok, info = UI.callG("UIDropDownMenu_CreateInfo")
                info = (ok and type(info) == "table") and info or {}
                info.text, info.value = it.text, it.value
                info.checked = it.value == dd.value
                info.func = guarded("a menu", function()
                    UI.callG("CloseDropDownMenus")
                    dd.pick(it.value, it)
                end)
                UI.callG("UIDropDownMenu_AddButton", info, level)
            end
        end
        UI.callG("UIDropDownMenu_Initialize", f, init)
        function dd.setText(t) UI.callG("UIDropDownMenu_SetText", f, t) end
        function dd.place(point, rel, relPoint, x, y) f:SetPoint(point, rel, relPoint, x - 16, y + 2) end
        return dd
    end

    -- Our own list.
    local b = button(parent, "", width, 22, function() dd.toggle() end)
    dd.frame = b
    local list = UI.create("Frame", nil, parent)
    dd.list = list
    if list then
        list:SetFrameStrata("DIALOG")
        list:SetSize(width, 20)
        local bg = UI.texture(list, "BACKGROUND")
        if bg then bg:SetAllPoints(list); bg:SetColorTexture(0.05, 0.05, 0.07, 0.97) end
        list:Hide()
        list.rows = {}
    end
    function dd.toggle()
        if not list then return end
        if list:IsShown() then list:Hide() return end
        local items = getItems() or {}
        local n = min(#items, 40)
        for i = 1, n do
            local r = list.rows[i]
            if not r then
                r = UI.create("Button", nil, list)
                if r then
                    r:SetSize(width - 4, 16)
                    r:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -2 - (i - 1) * 16)
                    r.label = UI.text(r, "", 11, "text")
                    if r.label then r.label:SetPoint("LEFT", r, "LEFT", 4, 0) end
                    UI.call(r, "EnableMouse", true)
                end
                list.rows[i] = r
            end
            if r then
                local it = items[i]
                r.label:SetText(it.text)
                r:SetScript("OnClick", guarded("a menu", function()
                    list:Hide()
                    dd.pick(it.value, it)
                end))
                r:Show()
            end
        end
        for i = n + 1, #list.rows do list.rows[i]:Hide() end
        list:SetHeight(n * 16 + 4)
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
        list:Show()
    end
    function dd.setText(t) setLabel(b, t or "") end
    function dd.place(point, rel, relPoint, x, y) b:SetPoint(point, rel, relPoint, x, y) end
    return dd
end

-- Building the window -------------------------------------------------------------------------

local function applyBackdrop(f)
    if UI.get(f, "SetBackdrop") then
        UI.call(f, "SetBackdrop", {
            bgFile = T.get("panelBg"), edgeFile = T.get("panelBorder"),
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    else
        local bg = UI.texture(f, "BACKGROUND", -8)
        if bg then bg:SetAllPoints(f); bg:SetColorTexture(0.05, 0.05, 0.07, 0.95) end
    end
end

local function setTitle(text)
    if not E.frame then return end
    local done = false
    local tt = UI.get(E.frame, "TitleText")
    if not tt then tt = UI.get(UI.get(E.frame, "TitleContainer"), "TitleText") end
    if tt then done = UI.call(tt, "SetText", text) end
    if not done then done = UI.call(E.frame, "SetTitle", text) end
    if not done then
        if not E.titleText then
            E.titleText = UI.text(E.frame, "", 14, "accent")
            if E.titleText then E.titleText:SetPoint("TOP", E.frame, "TOP", 0, -8) end
        end
        if E.titleText then E.titleText:SetText(text) end
    end
end

local function fitScale(f)
    local up = UI.G("UIParent")
    local ok, w = UI.call(up, "GetWidth")
    local ok2, h = UI.call(up, "GetHeight")
    if ok and ok2 and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
        local s = min(1, (w - 20) / WIN_W, (h - 20) / WIN_H)
        UI.call(f, "SetScale", s)
    end
end

local TOOLS = {
    { key = "select",  label = "Select",      w = 56 },
    { key = "polygon", label = "Polygon",     w = 64 },
    { key = "circle",  label = "Circle",      w = 56 },
    { key = "named",   label = "Named",       w = 58 },
    { key = "corner",  label = "Corner here", w = 86 },
    { key = "delete",  label = "Delete",      w = 58 },
    { key = "undo",    label = "Undo",        w = 50 },
    { key = "redo",    label = "Redo",        w = 50 },
}

function E.useTool(key)
    if key == "select" then
        E.cancelDraft(true)
        E.tool = "select"
    elseif key == "polygon" then
        if not (E.canvas and E.canvas.hasArt) then return E.say(Canvas.NO_ART) end
        E.startPolygon()
        E.say("click to place corners; any corner again, Enter or Finish closes it.")
    elseif key == "circle" then
        if not (E.canvas and E.canvas.hasArt) then return E.say(Canvas.NO_ART) end
        E.cancelDraft(true)
        E.tool = "circle"
        E.say("click the centre and drag out the inner radius.")
    elseif key == "named" then
        E.addNamed()
        return
    elseif key == "corner" then
        E.cornerHere()
        return
    elseif key == "delete" then
        E.requestDelete()
        return
    elseif key == "undo" then
        if not E.undo() and not E.locked() then E.say("nothing to undo.") end
        return
    elseif key == "redo" then
        if not E.redo() and not E.locked() then E.say("nothing to redo.") end
        return
    end
    E.refresh()
end

function E.requestDelete(a)
    a = a or E.selected
    if not a then return E.say("select an area to delete.") end
    E.pendingDelete = a
    local shown = false
    local dialogs = UI.G("StaticPopupDialogs")
    if type(dialogs) == "table" and dialogs[POPUP_DELETE] then
        shown = UI.callG("StaticPopup_Show", POPUP_DELETE, areaName(a, E.selectedIndex()))
    end
    if not shown then
        -- No dialog on this client: say how to confirm instead of deleting blind.
        E.say("press Delete again to confirm.")
        if E.deleteArmed == a then
            E.deleteArmed = nil
            E.confirmDelete()
        else
            E.deleteArmed = a
        end
    end
end

function E.confirmDelete()
    local a = E.pendingDelete
    E.pendingDelete = nil
    if a then E.deleteArea(a) end
end

local function buildToolbar(f)
    local x = PAD
    local zl = UI.text(f, "Zone:", 12, "accent")
    if zl then zl:SetPoint("TOPLEFT", f, "TOPLEFT", x, -38) end
    x = x + 40
    E.zoneDrop = dropdown(f, 170, E.zoneItems, function(value, item)
        E.selectZone(value, item and item.mapID, item and item.note)
    end)
    E.zoneDrop.place("TOPLEFT", f, "TOPLEFT", x, -32)
    x = x + 200
    local go = button(f, "Go to my zone", 100, 22, function() E.goToMyZone() end)
    if go then go:SetPoint("TOPLEFT", f, "TOPLEFT", x, -32) end
    x = x + 112

    E.toolButtons = {}
    for _, t in ipairs(TOOLS) do
        local b = button(f, t.label, t.w, 22, function() E.useTool(t.key) end)
        if b then
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -32)
            E.toolButtons[t.key] = b
        end
        x = x + t.w + 4
    end

    local cb = UI.createOr("CheckButton", nil, f, "UICheckButtonTemplate")
    if cb then
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", f, "TOPLEFT", x + 6, -32)
        cb:SetChecked(E.fill)
        local l = UI.text(f, "Fill", 11, "text")
        if l then l:SetPoint("TOPLEFT", f, "TOPLEFT", x + 30, -37) end
        cb:SetScript("OnClick", function(self)
            E.fill = self:GetChecked() and true or false
            E.needsRender = true
        end)
        E.fillCheck = cb
    end
end

local function buildTabs(f)
    E.tabs = {}
    local names = { "Zones", "Settings", "Themes", "Share" }
    local x = WIN_W - 40 - #names * 72
    for i, n in ipairs(names) do
        local b = button(f, n, 70, 20, function() end)
        if b then
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x + (i - 1) * 72, -4)
            if n == "Zones" then
                UI.call(b, "LockHighlight")
            else
                -- Present but disabled, so the layout does not move when they
                -- arrive (DESIGN-ui.md 5).
                UI.call(b, "Disable")
                tooltip(b, "next delivery")
            end
            E.tabs[n] = b
        end
    end
end

local function buildList(f)
    local header = UI.text(f, "AREAS (this zone) - top wins", 12, "accent")
    if header then header:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_TOP) end
    E.listHeader = header

    local sf, templ = UI.createOr("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    E.listScroll = sf
    if sf then
        sf:SetSize(COL_W - 24, 186)
        sf:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_TOP - 18)
        local bg = UI.texture(sf, "BACKGROUND")
        if bg then
            bg:SetPoint("TOPLEFT", sf, "TOPLEFT", -2, 2)
            bg:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 22, -2)
            bg:SetColorTexture(0, 0, 0, 0.45)
        end
        local child = UI.create("Frame", nil, sf)
        if child then
            child:SetSize(COL_W - 24, 186)
            UI.call(sf, "SetScrollChild", child)
            E.listChild = child
        end
    end
    E.listRows = {}

    local add = button(f, "+ named area", 110, 20, function() E.addNamed() end)
    if add then add:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_TOP - 210) end
    E.addNamedButton = add
end

E.INERT_LABEL = "- does nothing yet"

-- Every area that sets no values, as "Zone: area", zones in name order - for
-- the Save panel. `only` limits it to one zone.
function E.inertAreas(only)
    local names = {}
    for name, z in pairs(Config.zones) do
        if type(name) == "string" and type(z) == "table" and (not only or name == only) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local list = {}
    for _, name in ipairs(names) do
        local areas = Config.zones[name].areas or {}
        for i = 1, #areas do
            if Preset.inert(areas[i]) then
                list[#list + 1] = format("%s: %s", name, areaName(areas[i], i))
            end
        end
    end
    return list
end

-- The line under the Save box: the lock, or the areas that do nothing yet.
function E.saveNoteText()
    if E.locked() then return E.LOCK_NOTE end
    local list = E.inertAreas(E.saveMode ~= "file" and E.saveMode or nil)
    if #list == 0 then return "" end
    local one = #list == 1
    return format("%d %s no contrast, brightness or gamma and %s nothing yet - saved as "
        .. "drawn: %s", #list, one and "area sets" or "areas set", one and "does" or "do",
        table.concat(list, ", "))
end

-- One row per layer, top wins: priority, name, kind, and in / out for a gate.
function E.listItems()
    local z = E.zone()
    local layers = ns.layersFor(z)
    local own = {}
    for i = 1, #((z and z.areas) or {}) do own[z.areas[i]] = i end
    local items = {}
    for i = #layers, 1, -1 do
        local a = layers[i]
        local gate = a.indoors == true and "in" or (a.indoors == false and "out" or "")
        if own[a] then
            -- A shape with no values yet is legal and saved as drawn, but paints
            -- nothing; the list says so, so nobody walks in expecting a change.
            items[#items + 1] = { area = a, index = own[a], inert = Preset.inert(a),
                text = format("p%-3d %s  (%s)  %s%s", a.priority or 0, areaName(a, own[a]),
                    KIND_LABEL[kindOf(a)], gate, Preset.inert(a) and "  " .. E.INERT_LABEL or "") }
        else
            -- The indoor rule: shown so the stack is complete, edited in delivery 2.
            local global = not (z and type(z.indoors) == "table")
            items[#items + 1] = { readOnly = true, text = format("p%-3d %s  (%s)  %s",
                a.priority or 0, global and "All interiors" or "Interiors in this zone",
                global and "global rule" or "zone rule", gate) }
        end
    end
    return items
end

function E.refreshList()
    if not (E.built and E.listChild) then return end
    local items = E.listItems()
    for i = 1, #items do
        local r = E.listRows[i]
        if not r then
            r = UI.create("Button", nil, E.listChild)
            if not r then break end
            r:SetSize(COL_W - 28, 16)
            r:SetPoint("TOPLEFT", E.listChild, "TOPLEFT", 2, -2 - (i - 1) * 16)
            r.hl = UI.texture(r, "BACKGROUND")
            if r.hl then r.hl:SetAllPoints(r); r.hl:SetColorTexture(1, 1, 1, 0.12) end
            r.label = UI.text(r, "", 11, "text")
            if r.label then r.label:SetPoint("LEFT", r, "LEFT", 4, 0) end
            UI.call(r, "EnableMouse", true)
            UI.call(r, "RegisterForClicks", "LeftButtonUp")
            E.listRows[i] = r
        end
        local it = items[i]
        r.item = it
        r.label:SetText(it.text)
        if it.readOnly then
            UI.color(r.label, "textMuted")
        else
            local cr, cg, cb = T.priorityColor(it.area.priority)
            UI.call(r.label, "SetTextColor", cr, cg, cb, 1)
        end
        if r.hl then
            if it.area and it.area == E.selected then r.hl:Show() else r.hl:Hide() end
        end
        r:SetScript("OnClick", guarded("the area list", function()
            if it.readOnly then
                E.say("the indoor rule is edited in the Settings tab, next delivery.")
                return
            end
            E.cancelDraft(true)
            E.tool = "select"
            E.selected = it.area
            E.refresh()
        end))
        r:Show()
    end
    for i = #items + 1, #E.listRows do E.listRows[i]:Hide() end
    if E.listChild then E.listChild:SetHeight(max(186, #items * 16 + 4)) end
end

-- Properties -----------------------------------------------------------------------------------

local function sectionFrame(parent, h)
    local s = UI.create("Frame", nil, parent)
    if s then
        s:SetSize(COL_W - 30, h)
        s:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        s:Hide()
    end
    return s
end

local function row(parent, label, y)
    local fs = UI.text(parent, label, 11, "textMuted")
    if fs then fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, y) end
    return fs
end

local SLIDER_W = 130      -- leaves room for "Inherit default" beside the box
local NOTES_H  = 84       -- the notes areas: about six lines at size 11

local function buildPresetSection(p)
    local s = sectionFrame(p, 600)
    E.presetSection = s
    if not s then return end
    local y = -4
    local head = UI.text(s, "PRESET", 12, "accent")
    if head then head:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y) end
    y = y - 20
    local W_BOX = COL_W - 110

    row(s, "Name", y - 3)
    E.metaName = editBox(s, W_BOX, Preset.MAX_NAME, function(t) E.setMeta("name", t) end)
    if E.metaName then E.metaName:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y) end
    y = y - 24
    row(s, "Description", y - 3)
    E.metaDesc = editBox(s, W_BOX, Preset.MAX_DESCRIPTION, function(t) E.setMeta("description", t) end)
    if E.metaDesc then E.metaDesc:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y) end
    y = y - 24
    -- A text area several lines tall, scrolling past that (feedback-1.md item 7).
    row(s, "Notes", y - 3)
    local sf, eb = multiBox(s, W_BOX - 20, NOTES_H, Preset.MAX_NOTES)
    E.metaNotes = eb
    E.metaNotesScroll = sf
    if sf then sf:SetPoint("TOPLEFT", s, "TOPLEFT", 88, y - 2) end
    if eb then
        eb:SetScript("OnEditFocusLost", guarded("notes", function(self)
            local t = self:GetText() or ""
            local z = E.zone()
            local cur = z and z.meta and z.meta.notes or ""
            if t ~= cur then E.setMeta("notes", t) end
        end))
    end
    y = y - NOTES_H - 12
    row(s, "Version", y - 3)
    E.metaVersion = editBox(s, 50, 6, function(t)
        local v = number(t)
        if v and v >= 0 and v == floor(v) then
            E.clearFieldError()
            E.setMeta("version", v)
        else
            E.fieldError(E.metaVersion, "the version is a whole number of 0 or more.")
            E.refreshProps()
        end
    end)
    if E.metaVersion then E.metaVersion:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y) end
    E.metaAuthor = UI.text(s, "", 10, "textMuted")
    if E.metaAuthor then E.metaAuthor:SetPoint("TOPLEFT", s, "TOPLEFT", 144, y - 4) end
    y = y - 22
    E.metaMap = UI.text(s, "", 10, "textMuted")
    if E.metaMap then E.metaMap:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y) end
    y = y - 16
    E.metaMapNote = UI.text(s, "", 10, "accent")
    if E.metaMapNote then
        E.metaMapNote:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y)
        E.metaMapNote:SetWidth(COL_W - 40)
    end
    y = y - 22

    -- DESIGN-ui.md 6.10: back to the last exported string, and deleting a zone.
    -- The label is short and fixed; the tooltip says which export (feedback-2.md
    -- item 3), or why the button is disabled.
    E.revertButton = button(s, E.REVERT_LABEL, 170, 22, function() E.requestRevert() end)
    if E.revertButton then
        E.revertButton:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y)
        E.revertButton:SetScript("OnEnter", function(self)
            local tt = UI.G("GameTooltip")
            if tt then
                UI.call(tt, "SetOwner", self, "ANCHOR_TOP")
                UI.call(tt, "SetText", E.revertTip or "never exported")
                UI.call(tt, "Show")
            end
        end)
        E.revertButton:SetScript("OnLeave", function()
            local tt = UI.G("GameTooltip")
            if tt then UI.call(tt, "Hide") end
        end)
    end
    -- Under Revert, not beside it: beside it ran off the panel's right edge
    -- (in-game check, 2026-09-25).
    y = y - 26
    E.deleteZoneButton = button(s, "Delete zone", 100, 22, function() E.requestDeleteZone() end)
    if E.deleteZoneButton then
        E.deleteZoneButton:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y)
        tooltip(E.deleteZoneButton, "delete this zone and all its areas - Undo brings it back")
    end
    y = y - 30

    local zh = UI.text(s, "ZONE DEFAULTS", 12, "accent")
    if zh then zh:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y) end
    y = y - 18
    E.zoneRows = {}
    for _, ax in ipairs({ { "contrast", "Contrast" }, { "brightness", "Brightness" },
                          { "gamma", "Gamma" } }) do
        local r = axisRow(s, ax[1], ax[2], SLIDER_W, function(v, light)
            E.setZoneValue(ax[1], v, light)
        end)
        E.zoneRows[ax[1]] = r
        y = y - r.place(4, y)
    end
end

local APPLIES = {
    { text = "anywhere",      value = "any" },
    { text = "indoors only",  value = "in" },
    { text = "outdoors only", value = "out" },
}

-- The priority step buttons (feedback-1.md item 6), in the order the operator
-- gave them.
E.PRIORITY_STEPS = { -10, -5, -1, 0, 1, 5, 10 }

local function stepLabel(v)
    if v > 0 then return "+" .. v end
    return tostring(v)
end

-- A circle's two radii at once, keeping the stored format (falloffYards is
-- innerYards + fade) in one undo step.
function E.setCircleRadii(a, inner, fade)
    if refuseLocked() or refuseNonFinite(inner) or refuseNonFinite(fade) then return end
    local zone = E.zone()
    if not (zone and a and a.x) then return end
    E.pushUndo(nil)
    a.innerYards = round(inner, 1)
    a.falloffYards = round(a.innerYards + fade, 1)
    afterEdit(zone)
end

local YARDS_ERR = "%s has to be a number of yards, 0 or more."

local function buildAreaSection(p)
    local s = sectionFrame(p, 780)
    E.areaSection = s
    if not s then return end
    local y = -4
    E.areaHead = UI.text(s, "AREA", 12, "accent")
    if E.areaHead then E.areaHead:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y) end
    y = y - 20
    local W_BOX = COL_W - 110

    row(s, "Name", y - 3)
    E.areaName = editBox(s, W_BOX, Preset.MAX_NAME, function(t)
        if E.selected then E.setArea(E.selected, "name", t ~= "" and t or nil) end
    end)
    if E.areaName then E.areaName:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y) end
    y = y - 24
    -- A text area, like the preset's (feedback-1.md item 7). It commits when it
    -- loses focus, to the area it was opened on.
    row(s, "Notes", y - 3)
    local sf, eb = multiBox(s, W_BOX - 20, NOTES_H, Preset.MAX_AREA_NOTES)
    E.areaNotes, E.areaNotesScroll = eb, sf
    if sf then sf:SetPoint("TOPLEFT", s, "TOPLEFT", 88, y - 2) end
    if eb then
        eb:SetScript("OnEditFocusGained", function(self) self.forArea = E.selected end)
        eb:SetScript("OnEditFocusLost", guarded("notes", function(self)
            local a = self.forArea or E.selected
            self.forArea = nil
            -- A structural edit while typing (a priority step, say) replaced the
            -- records with copies; the selection followed the copy, so use it.
            local z, found = E.zone(), false
            for i = 1, #((z and z.areas) or {}) do found = found or z.areas[i] == a end
            if not found then a = E.selected end
            if not a then return end
            local t = self:GetText() or ""
            if t ~= (a.notes or "") then E.setArea(a, "notes", t ~= "" and t or nil) end
        end))
    end
    y = y - NOTES_H - 12
    E.areaKind = UI.text(s, "", 11, "text")
    if E.areaKind then E.areaKind:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y) end
    y = y - 18
    E.areaConverted = UI.text(s, "", 10, "accent")
    if E.areaConverted then E.areaConverted:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y) end
    y = y - 16

    -- Priority: the typed box as it was, and a row of step buttons under it.
    row(s, "Priority", y - 3)
    E.areaPriority = editBox(s, 40, 4, function(t)
        local v = number(t)
        if v and E.selected then
            E.clearFieldError()
            E.setArea(E.selected, "priority", floor(v))
        else
            E.fieldError(E.areaPriority, "the priority is a whole number.")
            E.refreshProps()
        end
    end)
    if E.areaPriority then E.areaPriority:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y) end
    y = y - 24
    E.priorityButtons = {}
    local bx = 4
    for _, step in ipairs(E.PRIORITY_STEPS) do
        local b = button(s, stepLabel(step), 38, 20, function()
            local a = E.selected
            if a then E.setArea(a, "priority", E.stepPriority(a.priority, step)) end
        end)
        if b then
            b:SetPoint("TOPLEFT", s, "TOPLEFT", bx, y)
            tooltip(b, step == 0 and "set the priority to 0"
                or format("add %d to the priority", step))
            E.priorityButtons[#E.priorityButtons + 1] = b
        end
        bx = bx + 41
    end
    y = y - 28

    row(s, "Applies", y - 5)
    E.areaApplies = dropdown(s, 120, function() return APPLIES end, function(v)
        if not E.selected then return end
        local gate = nil
        if v == "in" then gate = true elseif v == "out" then gate = false end
        E.setArea(E.selected, "indoors", gate)
    end)
    E.areaApplies.place("TOPLEFT", s, "TOPLEFT", 84, y)
    y = y - 30

    E.areaRows = {}
    for _, ax in ipairs({ { "contrast", "Contrast" }, { "brightness", "Brightness" },
                          { "gamma", "Gamma" } }) do
        local r = axisRow(s, ax[1], ax[2], SLIDER_W, function(v, light)
            if E.selected then E.setArea(E.selected, ax[1], v, light) end
        end)
        E.areaRows[ax[1]] = r
        y = y - r.place(4, y)
    end

    -- Per kind. A circle: Inner (yd), then Fade (yd) on top of it. A polygon: its
    -- corner count, then Fade (yd) from its edges (feedback-1.md item 11).
    E.kindY = y
    E.innerLabel = row(s, "Inner (yd)", y - 3)
    E.innerBox = editBox(s, 60, 8, function(t)
        local v = number(t)
        local a = E.selected
        if not a then return end
        if not (v and v >= 0) then
            E.fieldError(E.innerBox, format(YARDS_ERR, "Inner (yd)"))
            return E.refreshProps()
        end
        E.clearFieldError()
        E.setCircleRadii(a, v, E.falloffToFade("circle", a.innerYards, a.falloffYards) or 0)
    end)
    if E.innerBox then E.innerBox:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y) end
    E.cornerCount = UI.text(s, "", 11, "textMuted")
    if E.cornerCount then E.cornerCount:SetPoint("TOPLEFT", s, "TOPLEFT", 4, y - 4) end
    E.fadeLabel = row(s, "Fade (yd)", y - 27)
    E.fadeBox = editBox(s, 60, 8, function(t)
        local v = number(t)
        local a = E.selected
        if not a then return end
        if not (v and v >= 0) then
            E.fieldError(E.fadeBox, format(YARDS_ERR, "Fade (yd)"))
            return E.refreshProps()
        end
        E.clearFieldError()
        if a.x then
            E.setCircleRadii(a, a.innerYards or 0, v)
        else
            E.setArea(a, "falloffYards", round(E.fadeToFalloff("polygon", nil, v), 1))
        end
    end)
    if E.fadeBox then E.fadeBox:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y - 24) end
    E.fadeNote = UI.text(s, "", 10, "textMuted")
    if E.fadeNote then E.fadeNote:SetPoint("TOPLEFT", s, "TOPLEFT", 150, y - 28) end

    E.subzoneLabel = row(s, "Subzone", y - 3)
    E.subzoneBox = editBox(s, W_BOX - 40, Preset.MAX_NAME, function(t)
        t = (t or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if t == "" then
            -- An empty subzone matches nothing and exports a string that is refused.
            E.fieldError(E.subzoneBox, "a named area needs a subzone name.")
            return E.refreshProps()
        end
        E.clearFieldError()
        if E.selected then E.setArea(E.selected, "subzone", t) end
    end)
    if E.subzoneBox then E.subzoneBox:SetPoint("TOPLEFT", s, "TOPLEFT", 84, y) end
    E.seenDrop = dropdown(s, 150, function()
        local set = ns.seenSubzones[E.zoneName or ""] or {}
        local names = {}
        for n in pairs(set) do names[#names + 1] = n end
        table.sort(names)
        local items = {}
        for i = 1, #names do items[i] = { text = names[i], value = names[i] } end
        if #items == 0 then items[1] = { text = "(none seen yet this session)", value = false } end
        return items
    end, function(v)
        if v and E.selected then E.setArea(E.selected, "subzone", v) end
    end)
    E.seenDrop.setText("seen this session")
    E.seenDrop.place("TOPLEFT", s, "TOPLEFT", 84, y - 26)
end

E.FADE_NOTE_CIRCLE  = "past the inner radius"
E.FADE_NOTE_POLYGON = "past the edges"

local function buildDraftSection(p)
    local s = sectionFrame(p, 200)
    E.draftSection = s
    if not s then return end
    E.draftHead = UI.text(s, "", 12, "accent")
    if E.draftHead then E.draftHead:SetPoint("TOPLEFT", s, "TOPLEFT", 4, -4) end
    E.draftInfo = UI.text(s, "", 11, "text")
    if E.draftInfo then E.draftInfo:SetPoint("TOPLEFT", s, "TOPLEFT", 4, -24) end
    row(s, "Fade (yd)", -51)
    -- Pre-filled with Config.editor.defaultFadeYards (feedback-1.md item 10).
    E.draftFade = editBox(s, 60, 8, function(t) E.setDraftFade(number(t)) end)
    if E.draftFade then E.draftFade:SetPoint("TOPLEFT", s, "TOPLEFT", 84, -48) end
    E.draftFadeNote = UI.text(s, "", 10, "textMuted")
    if E.draftFadeNote then E.draftFadeNote:SetPoint("TOPLEFT", s, "TOPLEFT", 150, -52) end
    local fin = button(s, "Finish", 70, 22, function()
        -- A value typed but not yet committed counts; a bad one stops here, with
        -- its reason beside the box.
        local box = E.draftFade
        if box and (box:GetText() or "") ~= (box.shown_ or "") then
            if not E.setDraftFade(number(box:GetText())) then return end
        end
        E.finishDraft()
    end)
    if fin then fin:SetPoint("TOPLEFT", s, "TOPLEFT", 4, -80) end
    local cancel = button(s, "Cancel", 70, 22, function() E.cancelDraft() end)
    if cancel then cancel:SetPoint("TOPLEFT", s, "TOPLEFT", 80, -80) end
    local undoCorner = button(s, "Remove last corner", 130, 22, function()
        E.removeDraftCorner()
        E.refresh()
    end)
    if undoCorner then undoCorner:SetPoint("TOPLEFT", s, "TOPLEFT", 156, -80) end
    E.draftRemove = undoCorner
end

function E.focusDraftFade()
    if E.built and E.draftFade then UI.call(E.draftFade, "SetFocus") end
end

function E.focusSubzone()
    if E.built and E.subzoneBox then UI.call(E.subzoneBox, "SetFocus") end
end

local function buildProps(f)
    local header = UI.text(f, "PROPERTIES", 12, "accent")
    if header then header:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_TOP - 236) end
    E.propsHeader = header

    local sf = UI.createOr("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    E.propsScroll = sf
    if not sf then return end
    local top = COL_TOP - 254
    sf:SetSize(COL_W - 24, (top - COL_BOTTOM) - 22)
    sf:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, top)
    local child = UI.create("Frame", nil, sf)
    if not child then return end
    child:SetSize(COL_W - 24, 860)
    UI.call(sf, "SetScrollChild", child)
    E.propsChild = child
    buildPresetSection(child)
    buildAreaSection(child)
    buildDraftSection(child)

    E.msgText = UI.text(f, "", 11, "accent")
    if E.msgText then
        E.msgText:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_BOTTOM + 18)
        E.msgText:SetWidth(COL_W)
    end
end

local function gateValue(g)
    if g == true then return "in", "indoors only" end
    if g == false then return "out", "outdoors only" end
    return "any", "anywhere"
end

local function focusedBox(box)
    local ok, focused = UI.call(box, "HasFocus")
    return ok and focused and true or false
end

function E.refreshProps()
    if not E.built then return end
    -- A field's error belongs to what it was about: a new selection or a new
    -- shape clears it.
    local showing = E.draft or E.selected or E.zoneName or false
    if showing ~= E.propsShowing then
        E.propsShowing = showing
        E.clearFieldError()
    end
    E.populating = true
    local ok, err = pcall(function()
        local z = E.zone()
        local d, a = E.draft, E.selected
        if E.presetSection then E.presetSection:Hide() end
        if E.areaSection then E.areaSection:Hide() end
        if E.draftSection then E.draftSection:Hide() end

        if d and E.draftSection then
            E.draftSection:Show()
            if d.kind == "polygon" then
                E.draftHead:SetText("NEW POLYGON")
                E.draftInfo:SetText(format("%d corner%s - at least 3, at most %d.",
                    #d.corners / 2, #d.corners == 2 and "" or "s", E.MAX_CORNERS))
                if E.draftRemove then E.draftRemove:Show() end
            else
                E.draftHead:SetText("NEW CIRCLE")
                E.draftInfo:SetText(format("inner radius %.1f yd.", d.innerYards or 0))
                if E.draftRemove then E.draftRemove:Hide() end
            end
            if E.draftFade then
                -- Not while the player is typing into it.
                local okF, focused = UI.call(E.draftFade, "HasFocus")
                if not (okF and focused) then
                    E.draftFade.set(d.fadeYards and Preset.num(d.fadeYards, 1) or "")
                end
            end
            if E.draftFadeNote then
                E.draftFadeNote:SetText(d.kind == "circle" and E.FADE_NOTE_CIRCLE or E.FADE_NOTE_POLYGON)
            end
            return
        end

        local base = Config.baseline
        if a and E.areaSection then
            E.areaSection:Show()
            local idx = E.selectedIndex()
            local kind = kindOf(a)
            E.areaHead:SetText(format("AREA %s", idx and ("#" .. idx) or ""))
            E.areaName.set(a.name or "")
            if E.areaNotes and not focusedBox(E.areaNotes) then E.areaNotes:SetText(a.notes or "") end
            E.areaKind:SetText("Kind: " .. KIND_LABEL[kind])
            E.areaConverted:SetText(a.__converted
                and "radii converted from normalized units - check them" or "")
            E.areaPriority.set(tostring(a.priority or 0))
            local _, text = gateValue(a.indoors)
            E.areaApplies.value = gateValue(a.indoors)
            E.areaApplies.setText(text)
            for axis, r in pairs(E.areaRows) do
                local inherited = (z and z[axis]) or base[axis]
                r.show(a[axis], inherited)
            end
            local circle, poly, named = kind == "circle", kind == "polygon", kind == "named"
            local function vis(obj, on) if obj then if on then obj:Show() else obj:Hide() end end end
            vis(E.innerLabel, circle); vis(E.innerBox, circle)
            vis(E.fadeLabel, circle or poly); vis(E.fadeBox, circle or poly)
            vis(E.fadeNote, circle or poly)
            vis(E.cornerCount, poly)
            vis(E.subzoneLabel, named); vis(E.subzoneBox, named)
            vis(E.seenDrop and E.seenDrop.frame, named)
            if circle then E.innerBox.set(a.innerYards and tostring(a.innerYards) or "") end
            if circle or poly then
                -- The fade back out of the stored falloff (item 11).
                local fade = E.falloffToFade(kind, a.innerYards, a.falloffYards)
                E.fadeBox.set(fade and Preset.num(round(fade, 1), 1) or "")
                E.fadeNote:SetText(circle and E.FADE_NOTE_CIRCLE or E.FADE_NOTE_POLYGON)
            end
            if poly then E.cornerCount:SetText(format("%d corners", floor(#a.corners / 2))) end
            if named then E.subzoneBox.set(a.subzone or "") end
            return
        end

        if E.presetSection then
            E.presetSection:Show()
            local m = z and z.meta or {}
            E.metaName.set(m.name or E.zoneName or "")
            E.metaDesc.set(m.description or "")
            if E.metaNotes and not focusedBox(E.metaNotes) then E.metaNotes:SetText(m.notes or "") end
            E.metaVersion.set(tostring(m.version or 1))
            E.metaAuthor:SetText(format("by %s%s", tostring(m.author or "-"),
                m.date and (", " .. m.date) or ""))
            E.metaMap:SetText(format("map %s%s", tostring((z and z.map) or E.mapID or "-"),
                z and "" or "   (not configured yet - nothing is created until you add something)"))
            E.metaMapNote:SetText(E.mapNote or "")
            if E.revertButton then
                local tip, why = E.revertTooltip(z and E.zoneName)
                setLabel(E.revertButton, E.REVERT_LABEL)
                E.revertTip = tip or why
                UI.call(E.revertButton, (tip and not E.locked()) and "Enable" or "Disable")
            end
            if E.deleteZoneButton then
                UI.call(E.deleteZoneButton, (z and not E.locked()) and "Enable" or "Disable")
            end
            for axis, r in pairs(E.zoneRows) do r.show(z and z[axis], base[axis]) end
        end
    end)
    E.populating = false
    if not ok then tellError("the properties panel", err) end
end

-- Save and import panels ------------------------------------------------------------------------

local function buildSavePanel(f)
    local p = UI.create("Frame", nil, f)
    E.savePanel = p
    if not p then return end
    p:SetSize(COL_W, COL_TOP - COL_BOTTOM)
    p:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_TOP)
    p:Hide()
    local title = UI.text(p, E.SAVE_TITLE, 14, "accent")
    if title then title:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0) end
    E.saveTitle = title
    local body = UI.text(p, E.SAVE_TEXT, 11, "text")
    if body then
        body:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -20)
        body:SetWidth(COL_W)
        UI.call(body, "SetWordWrap", true)
        UI.call(body, "SetJustifyV", "TOP")
    end
    E.saveBody = body
    local boxTop = -420
    local sf, eb = multiBox(p, COL_W - 28, 150, 0)
    if sf then sf:SetPoint("TOPLEFT", p, "TOPLEFT", 4, boxTop) end
    E.saveBox = eb

    local sel = button(p, "Select all", 90, 22, function() E.selectAll() end)
    if sel then sel:SetPoint("TOPLEFT", p, "TOPLEFT", 0, boxTop - 160) end
    E.modeDrop = dropdown(p, 170, function()
        local items = { { text = "Zones.lua (whole file)", value = "file" } }
        local names = {}
        for name in pairs(Config.zones) do names[#names + 1] = name end
        table.sort(names)
        for i = 1, #names do
            items[#items + 1] = { text = "Preset string: " .. names[i], value = names[i] }
        end
        return items
    end, function(v)
        E.saveMode = v
        E.refreshSaveBox()
    end)
    E.modeDrop.setText("Zones.lua (whole file)")
    E.modeDrop.place("TOPLEFT", p, "TOPLEFT", 100, boxTop - 160)

    local pl = UI.text(p, "The file, to paste into your file manager's search or address bar:", 10,
        "textMuted")
    if pl then
        pl:SetPoint("TOPLEFT", p, "TOPLEFT", 0, boxTop - 190)
        pl:SetWidth(COL_W)
    end
    local path = editBox(p, COL_W - 10, 0, nil)
    if path then
        path:SetPoint("TOPLEFT", p, "TOPLEFT", 4, boxTop - 216)
        path.set(Serialize.FILE_PATH)
        path:SetScript("OnEditFocusGained", function(self) UI.call(self, "HighlightText") end)
        path:SetScript("OnEditFocusLost", function(self) self:SetText(Serialize.FILE_PATH) end)
    end
    E.pathBox = path
    local back = button(p, "Back", 70, 22, function() E.showPanel("props") end)
    if back then back:SetPoint("TOPLEFT", p, "TOPLEFT", 0, boxTop - 244) end
    -- Beside Back rather than under it: under it, a note of two lines or more
    -- reached the footer's buttons, which sit under this column since
    -- feedback-2.md item 2.
    E.saveNote = UI.text(p, "", 11, "accent")
    if E.saveNote then
        E.saveNote:SetPoint("TOPLEFT", p, "TOPLEFT", 80, boxTop - 244)
        E.saveNote:SetWidth(COL_W - 80)
        UI.call(E.saveNote, "SetWordWrap", true)
    end
end

-- The Export panel (DESIGN-ui.md 7.1): one zone's preset string. Import is its
-- own panel (feedback-2.md item 4). No popup: there is nothing the player must do.
local function buildExportPanel(f)
    local p = UI.create("Frame", nil, f)
    E.exportPanel = p
    if not p then return end
    p:SetSize(COL_W, COL_TOP - COL_BOTTOM)
    p:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_TOP)
    p:Hide()
    local title = UI.text(p, "Export", 14, "accent")
    if title then title:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0) end
    local body = UI.text(p, E.EXPORT_TEXT, 11, "text")
    if body then
        body:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -20)
        body:SetWidth(COL_W)
        UI.call(body, "SetWordWrap", true)
    end
    E.exportDrop = dropdown(p, 220, function()
        local items, names = {}, {}
        for name in pairs(Config.zones) do names[#names + 1] = name end
        table.sort(names)
        for i = 1, #names do items[#items + 1] = { text = names[i], value = names[i] } end
        return items
    end, function(v)
        E.exportZone = v
        E.refreshExportBox()
    end)
    E.exportDrop.place("TOPLEFT", p, "TOPLEFT", -14, -60)
    local sf, eb = multiBox(p, COL_W - 28, 150, 0)
    if sf then sf:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -96) end
    E.exportBox = eb
    -- Under the box: "Copied to clipboard" when Export put this string there,
    -- the instruction otherwise (feedback-2.md item 5).
    E.exportNote = UI.text(p, E.CLIP_HINT, 11, "accent")
    if E.exportNote then
        E.exportNote:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -252)
        E.exportNote:SetWidth(COL_W)
    end
    local sel = button(p, "Select all", 90, 22, function() E.exportSelectAll() end)
    if sel then sel:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -272) end
    local back = button(p, "Back", 70, 22, function() E.showPanel("props") end)
    if back then back:SetPoint("TOPLEFT", p, "TOPLEFT", 96, -272) end
end

-- The Import panel (DESIGN-ui.md 8.2), on every branch: the footer's Import and
-- `/amb ui import` open it (feedback-2.md items 2 and 4).
local function buildImportPanel(f)
    local p = UI.create("Frame", nil, f)
    E.importPanel = p
    if not p then return end
    p:SetSize(COL_W, COL_TOP - COL_BOTTOM)
    p:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X, COL_TOP)
    p:Hide()
    local title = UI.text(p, "Import a preset", 14, "accent")
    if title then title:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0) end
    local body = UI.text(p, E.IMPORT_TEXT, 11, "text")
    if body then
        body:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -20)
        body:SetWidth(COL_W)
        UI.call(body, "SetWordWrap", true)
    end
    -- SetMaxLetters(0): the box takes any length, and Preset.parse refuses one
    -- over the measured 4000 with a reason (DESIGN-ui.md 8.3).
    local sf, eb = multiBox(p, COL_W - 28, 260, 0)
    if sf then sf:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -110) end
    E.importBox = eb
    local imp = button(p, "Import", 80, 22, function()
        E.importText(E.importBox and E.importBox:GetText() or "")
    end)
    if imp then imp:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -380) end
    local clear = button(p, "Clear", 70, 22, function()
        if E.importBox then E.importBox:SetText("") end
        E.setImportError(nil)
    end)
    if clear then clear:SetPoint("TOPLEFT", p, "TOPLEFT", 86, -380) end
    local back = button(p, "Back", 70, 22, function() E.showPanel("props") end)
    if back then back:SetPoint("TOPLEFT", p, "TOPLEFT", 162, -380) end
    E.importErr = UI.text(p, "", 11, "text")
    if E.importErr then
        E.importErr:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -410)
        E.importErr:SetWidth(COL_W)
        UI.call(E.importErr, "SetWordWrap", true)
    end
end

-- Which panels a branch offers (DESIGN-ui.md 7): Save to file only on a
-- regressed build, and built only then, so a normal build never creates its
-- frames. Import is its own panel on every branch (feedback-2.md item 4), built
-- on first need.
function E.panelFor(which)
    if which == "save" and not regressed() then return "export" end
    return which
end

function E.showPanel(which)
    which = E.panelFor(which)
    E.panel = which
    if not E.built then return end
    if which == "save" and not E.savePanel then
        local ok, err = pcall(buildSavePanel, E.frame)
        if not ok then tellError("building Save to file", err) end
    end
    if which == "import" and not E.importPanel then
        local ok, err = pcall(buildImportPanel, E.frame)
        if not ok then tellError("building the import panel", err) end
    end
    local props = which == "props"
    local function vis(obj, on) if obj then if on then obj:Show() else obj:Hide() end end end
    vis(E.listScroll, props); vis(E.addNamedButton, props); vis(E.propsScroll, props)
    vis(E.propsHeader, props); vis(E.listHeader, props)
    for _, r in ipairs(E.listRows or {}) do vis(r, props and r.item ~= nil) end
    vis(E.savePanel, which == "save")
    vis(E.importPanel, which == "import")
    vis(E.exportPanel, which == "export")
    if which == "save" then E.refreshSaveBox() end
    if which == "export" then E.refreshExportBox() end
    if props then E.refresh() end
end

-- Zoom controls (feedback-1.md item 1): visible buttons over the canvas's top
-- right corner, children of the canvas so they sit above the map, and the zoom
-- in per cent beside them. + and - zoom about the canvas's centre; Reset goes
-- back to fit.
local function buildZoomButtons(c)
    local parent = c.frame
    local x = -8
    local function add(label, w, tip, fn)
        local b = button(parent, label, w, 20, fn)
        if b then
            b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x, -8)
            tooltip(b, tip)
        end
        x = x - w - 4
        return b
    end
    E.zoomButtons = {
        reset = add("Reset", 50, "zoom back out to the whole map", function() c:resetView() end),
        zoomIn = add("+", 24, "zoom in (or the mouse wheel over the map)",
            function() c:zoomBy(Canvas.ZOOM_STEP) end),
        zoomOut = add("-", 24, "zoom out (or the mouse wheel over the map)",
            function() c:zoomBy(1 / Canvas.ZOOM_STEP) end),
    }
    E.zoomLabel = UI.text(parent, "100%", 11, "accent", "OVERLAY")
    if E.zoomLabel then E.zoomLabel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x - 2, -12) end
end

-- Footer ---------------------------------------------------------------------------------------

local function buildFooter(f)
    E.readout = UI.text(f, "", 11, "text")
    if E.readout then
        E.readout:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, CANVAS_TOP - CANVAS_H - 4)
        E.readout:SetWidth(CANVAS_W - 200)
    end
    -- Where the discovered areas come from (Canvas.lua, "The discovered areas"),
    -- on the same line, at the map's right edge.
    E.mapSource = UI.text(f, "", 11, "textMuted")
    if E.mapSource then
        E.mapSource:SetPoint("TOPRIGHT", f, "TOPLEFT", PAD + CANVAS_W, CANVAS_TOP - CANVAS_H - 4)
        E.mapSource:SetWidth(190)
        UI.call(E.mapSource, "SetJustifyH", "RIGHT")
    end
    -- Over the canvas's top-left corner, where a missing scale matters.
    E.scaleNote = UI.text(E.canvas.frame, "", 11, "accent", "OVERLAY")
    if E.scaleNote then E.scaleNote:SetPoint("TOPLEFT", E.canvas.frame, "TOPLEFT", 8, -8) end
    -- The window's bottom right corner (feedback-2.md item 2), under the right
    -- column, which stops above this row (COL_BOTTOM): `Import`, and to its left
    -- `Export` on a normal build or `Save to file` on a regressed one
    -- (DESIGN-ui.md 5). Both on every branch.
    local imp = button(f, "Import", 80, 22, function() E.open("import") end)
    if imp then
        imp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOT_Y)
        tooltip(imp, "paste a preset string someone gave you")
    end
    E.importButton = imp
    local save = button(f, "Save to file", 110, 22, function() E.footerClicked() end)
    if save then save:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + 80 + FOOT_GAP), FOOT_Y) end
    E.footerButton = save
    -- The persistence line can run to three lines on a regressed build, so it
    -- wraps inside its own column, bottom-aligned, clear of the preview note.
    E.status = UI.text(f, "", 11, "text")
    if E.status then
        E.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 6)
        E.status:SetWidth(560)
        UI.call(E.status, "SetWordWrap", true)
        UI.call(E.status, "SetJustifyH", "LEFT")
    end
    -- From the status column to the buttons' left edge, less a gap; one line, so
    -- it never climbs into the readout line above it.
    E.previewText = UI.text(f, "", 11, "textMuted")
    if E.previewText then
        E.previewText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD + 576, 15)
        E.previewText:SetWidth(WIN_W - PAD - 80 - FOOT_GAP - 110 - 12 - (PAD + 576))
        UI.call(E.previewText, "SetWordWrap", false)
        UI.call(E.previewText, "SetJustifyH", "LEFT")
    end
end

function E.footerButtonText()
    return regressed() and "Save to file" or "Export"
end

-- The footer's first line, decided by the persistence state (DESIGN-ui.md 5).
function E.footerText()
    local state = ns.Store and ns.Store.state() or "restart"
    local status
    if state == "unverified" then
        local n = E.dirtyCount()
        status = E.FOOTER_UNVERIFIED .. (n == 0 and "" or format(
            " %d unsaved zone%s: Save to file to keep them.", n, n == 1 and "" or "s"))
    elseif state == "reload" then
        status = E.FOOTER_RELOAD
    else
        status = E.FOOTER_RESTART
    end
    local here = ns.state and ns.state.zoneName
    local preview
    if E.locked() then
        preview = "|cffffd100" .. E.LOCK_NOTE .. "|r"
    elseif not E.zoneName then
        preview = ""
    elseif here == E.zoneName then
        preview = "previewing live in " .. E.zoneName
    else
        preview = format("you are in %s; edits to %s will not show until you are there",
            tostring(here or "no zone"), E.zoneName)
    end
    return status, preview
end

function E.refreshFooter()
    if not E.built then return end
    local status, preview = E.footerText()
    if E.status then E.status:SetText(status) end
    if E.previewText then E.previewText:SetText(preview) end
    if E.footerButton then setLabel(E.footerButton, E.footerButtonText()) end
    setTitle("Dynamic Ambiance" .. (E.dirtyCount() > 0 and " *" or ""))
    if E.mapSource then
        E.mapSource:SetText((E.canvas and E.canvas.hasArt and E.canvas.sourceText) or "")
    end
    if E.scaleNote then
        local W = E.scale()
        E.scaleNote:SetText((E.canvas and E.canvas.hasArt and not W)
            and format("map scale unavailable for map %s - fills and bands are not drawn",
                tostring(E.mapID))
            or "")
    end
end

-- Rendering ------------------------------------------------------------------------------------

function E.renderCanvas()
    if not (E.built and E.canvas) then return end
    local z = E.zone()
    local items = {}
    if z and z.areas then
        local layers = ns.layersFor(z)
        for i = 1, #layers do
            local a = layers[i]
            if isPlaced(a) then items[#items + 1] = { area = a, selected = a == E.selected } end
        end
        -- The selected one last, so its white outline and handles sit on top.
        table.sort(items, function(x, y)
            if x.selected ~= y.selected then return y.selected end
            return false
        end)
    end
    E.canvas:render({ areas = items, W = E.scale(), fill = E.fill, draft = E.draft })
end

function E.refreshTools()
    if not (E.built and E.toolButtons) then return end
    for key, b in pairs(E.toolButtons) do
        if key == E.tool then UI.call(b, "LockHighlight") else UI.call(b, "UnlockHighlight") end
    end
    local art = E.canvas and E.canvas.hasArt
    for _, key in ipairs({ "polygon", "circle" }) do
        local b = E.toolButtons[key]
        if b then UI.call(b, art and "Enable" or "Disable") end
    end
    local corner = E.toolButtons.corner
    if corner then
        local can = art and (E.draft and E.draft.kind == "polygon" or (E.selected and E.selected.corners))
        UI.call(corner, can and "Enable" or "Disable")
    end
    local del = E.toolButtons.delete
    if del then UI.call(del, E.selected and "Enable" or "Disable") end
end

-- What the mouse does, on the canvas (feedback-1.md item 3): the drawing tools
-- say it while they are in use, a selected polygon says how to reshape it, and
-- a zoomed map says how to move around.
function E.hintText()
    if E.tool == "polygon" or (E.draft and E.draft.kind == "polygon") then return E.HINT_POLYGON end
    if E.tool == "circle" then return E.HINT_CIRCLE end
    if E.selected and E.selected.corners then return E.HINT_EDIT end
    if view().zoom > 1 then return E.HINT_PAN end
    return ""
end

function E.refreshHint()
    if not (E.built and E.canvas) then return end
    E.canvas:setHint(E.canvas.hasArt and E.hintText() or "")
    if E.zoomLabel then E.zoomLabel:SetText(format("%d%%", floor(view().zoom * 100 + 0.5))) end
end

function E.refresh()
    E.needsRender, E.needsProps, E.needsFooter = false, false, false
    if not E.built then return end
    E.refreshList()
    E.refreshProps()
    E.renderCanvas()
    E.refreshFooter()
    E.refreshTools()
    E.refreshHint()
    if E.zoneDrop and E.zoneName then E.zoneDrop.setText(E.zoneName) end
end

-- The window's tick, only while it is shown: the player dot at the poll rate,
-- the canvas's hover and drag, deferred redraws, and the debounced draft.
local tickAccum = 0
local function onTick(_, elapsed)
    if E.canvas then E.canvas:poll() end
    if E.needsProps then E.needsProps = false; E.refreshProps() end
    if E.needsRender then E.needsRender = false; E.renderCanvas() end
    if E.needsFooter then E.needsFooter = false; E.refreshFooter() end
    tickAccum = tickAccum + (elapsed or 0)
    local hz = (Config.tuning and Config.tuning.pollHz) or 10
    if tickAccum >= 1 / hz then
        tickAccum = 0
        if E.canvas then
            local x, y = E.playerPosition()
            E.canvas:setPlayer(x, y)
        end
        E.refreshFooter()
        if E.draftPending and (now() - (E.lastFlush or 0)) >= 0.5 then E.flushDraft() end
        if E.noticeUntil and now() >= E.noticeUntil then E.clearNotice() end
    end
end

E.onTick = onTick

-- Build ------------------------------------------------------------------------------------------

function E.build()
    if E.built then return true end
    if E.buildFailed then return false end
    local ok, err = pcall(function()
        local up = UI.G("UIParent")
        local f, templ = UI.createOr("Frame", FRAME_NAME, up, "ButtonFrameTemplate")
        if not f then error("could not create the window") end
        -- Hidden before any script is attached: a new frame is shown, and its
        -- first hide must not be taken for the player closing the window.
        f:Hide()
        E.frame = f
        if not templ then applyBackdrop(f) end
        UI.callG("ButtonFrameTemplate_HidePortrait", f)
        local inset = UI.get(f, "Inset")
        if inset then UI.call(inset, "Hide") end
        f:SetSize(WIN_W, WIN_H)
        f:SetPoint("CENTER", up, "CENTER", 0, 0)
        UI.call(f, "SetFrameStrata", "HIGH")
        UI.call(f, "SetToplevel", true)
        UI.call(f, "SetMovable", true)
        UI.call(f, "SetClampedToScreen", true)
        UI.call(f, "EnableMouse", true)
        UI.call(f, "RegisterForDrag", "LeftButton")
        f:SetScript("OnDragStart", function(self) UI.call(self, "StartMoving") end)
        f:SetScript("OnDragStop", function(self) UI.call(self, "StopMovingOrSizing") end)
        fitScale(f)
        setTitle("Dynamic Ambiance")

        local c, cerr = Canvas.new(f, CANVAS_W, CANVAS_H)
        if not c then error("could not create the canvas: " .. tostring(cerr)) end
        E.canvas = c
        c.frame:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, CANVAS_TOP)
        c.onDown = E.onCanvasDown
        c.onUp = E.onCanvasUp
        c.onMove = E.onCanvasMove
        c.onLeave = function() E.hover = nil; E.updateReadout() end
        -- A new zoom or pan redraws every shape on the next tick; the art has
        -- already been re-laid by the canvas.
        c.onView = function()
            E.needsRender = true
            E.refreshHint()
        end
        buildZoomButtons(c)
        c.frame:SetScript("OnKeyDown", function(self, key)
            -- A capture that outlived the combat event: let go at once rather
            -- than keep a keyboard whose keys cannot be passed on.
            if inCombat() then
                UI.call(self, "EnableKeyboard", false)
                return
            end
            if key == "ENTER" or key == "ESCAPE" then
                UI.call(self, "SetPropagateKeyboardInput", false)
                if key == "ENTER" then pcall(E.finishDraft) else pcall(E.cancelDraft) end
            else
                UI.call(self, "SetPropagateKeyboardInput", true)
            end
        end)

        buildTabs(f)
        buildToolbar(f)
        buildList(f)
        buildProps(f)
        -- Save to file (a regressed build only) and Import are built on first
        -- need (E.showPanel).
        buildExportPanel(f)
        buildFooter(f)

        -- The one label a refused value is shown in, beside its box (item 11).
        E.errLabel = UI.text(f, "", 11, "text", "OVERLAY")
        if E.errLabel then
            E.errLabel:SetWidth(170)
            UI.call(E.errLabel, "SetWordWrap", true)
            E.errLabel:Hide()
        end

        f:SetScript("OnUpdate", onTick)
        f:SetScript("OnHide", function() pcall(E.onHidden) end)

        -- Escape closes it, if this client's FrameXML has UISpecialFrames. Not
        -- measured; the close button works either way.
        local specials = UI.G("UISpecialFrames")
        if type(specials) == "table" then pcall(table.insert, specials, FRAME_NAME) end
    end)
    if not ok then
        E.buildFailed = true
        tellError("building the window", err)
        if E.frame then pcall(E.frame.Hide, E.frame) end
        return false
    end
    E.built = true
    return true
end

-- Closing with unsaved zones asks first, on a regressed build (DESIGN-ui.md 6.8;
-- on a normal one dirtyCount is 0, so closing closes). Every way of closing - the
-- close button, Escape, /amb ui - ends here, since all of them hide.
--
-- Except combat's hide (feedback-1.md item 12), which is not a close: the shape
-- being drawn, the selection, the tool and the view all stay exactly as they
-- are for when the window comes back, and nothing is asked. Only a gesture in
-- flight is dropped, since its mouse-up will never arrive.
function E.onHidden()
    E.drag, E.press = nil, nil
    if E.canvas then E.canvas.dragging = false end
    E.setKeyboard(false)
    if E.combatHiding then
        E.flushDraft()
        return
    end
    E.cancelDraft(true)
    E.flushDraft()
    local n = E.dirtyCount()
    if n > 0 and not E.quietClose then
        local dialogs = UI.G("StaticPopupDialogs")
        if type(dialogs) == "table" and dialogs[POPUP_UNSAVED] then
            UI.callG("StaticPopup_Show", POPUP_UNSAVED, format("%d unsaved zone%s", n,
                n == 1 and "" or "s"), E.UNSAVED_STATE_LINE)
        else
            warn(format("%d unsaved zone%s. %s /amb ui save to copy them out.",
                n, n == 1 and "" or "s", E.UNSAVED_STATE_LINE))
        end
    end
    E.quietClose = nil
end

function E.isShown()
    return E.built and E.frame and E.frame:IsShown() or false
end

E.COMBAT_HIDDEN = "the editor is hidden while you are in combat - it comes back when combat ends."
E.COMBAT_LATER  = "in combat - the editor opens when combat ends."

-- Combat hides the window (feedback-1.md item 12). The editor frame is not a
-- protected frame, so hiding and showing it is allowed in combat; this is the
-- operator's choice, not a restriction.
function E.hideForCombat()
    if not E.isShown() then return false end
    E.combatHidden = true
    E.combatHiding = true
    local ok, err = pcall(E.frame.Hide, E.frame)
    E.combatHiding = false
    if not ok then tellError("hiding the editor for combat", err) end
    out(E.COMBAT_HIDDEN)
    return true
end

-- Combat is over: back as it was, on the panel it was on. The Export or Save
-- panel's box is not regenerated here - that would count as an export - so it
-- shows what it showed until Select all.
function E.restoreAfterCombat()
    if not E.combatHidden then return false end
    E.combatHidden = false
    local pending = E.pendingPanel
    E.pendingPanel = nil
    if pending or not E.built then
        if not E.open(pending or "props") then return false end
    else
        E.frame:Show()
        E.refresh()
    end
    if E.draft and E.draft.kind == "polygon" then E.setKeyboard(true) end
    return true
end

-- The map overlays in MapOverlays.lua are generated for one build. On another
-- they are still drawn - art IDs and file IDs rarely move - but the first open
-- of the session says so once, with the way to regenerate them.
function E.dataBuildText()
    local data, client, differ = Canvas.builds()
    if not differ then return nil end
    return format("the map overlay data is from build %s and the client is %s - rerun "
        .. "scripts/gen-map-overlays.py with this client's build.", data, client)
end

function E.noteDataBuild()
    if E.dataBuildNoted then return end
    E.dataBuildNoted = true
    local msg = E.dataBuildText()
    if msg then out(msg) end
end

-- `/amb ui mapcheck`: does the shipped overlay data belong to this client? The
-- overlays the client says the player has explored on the current map (the
-- editor's map while it is open, else the player's) are looked up by file ID in
-- the data for that map's art. An explored overlay is found when every one of
-- its files is there. The result goes to the account SavedVariables as
-- `mapcheck` (DESIGN-ui.md 1.5: the character's file holds only what the player
-- authors, and the marker).
local function mirror(key, t)
    if type(DynamicAmbianceDB) ~= "table" then DynamicAmbianceDB = {} end
    DynamicAmbianceDB[key] = t
    return t
end

function E.mapCheckMap()
    if E.isShown() and E.mapID then return E.mapID end
    local okB, id = pcall(function()
        return UI.get(UI.G("C_Map"), "GetBestMapForUnit")("player")
    end)
    id = okB and tonumber(plain(id)) or nil
    return id or E.mapID
end

function E.mapCheck()
    local mapID = E.mapCheckMap()
    local dataBuild, clientBuild = Canvas.builds()
    local r = {
        when = Serialize.now(), mapID = mapID, dataBuild = ns.MapOverlays and ns.MapOverlays.build,
        clientBuild = clientBuild, explored = 0, found = 0, missing = 0, missingFiles = {},
    }
    if not mapID then
        r.api = "no map"
        mirror("mapcheck", r)
        return warn("mapcheck: no current map to check.")
    end
    local list, artID = Canvas.dataFor(mapID)
    r.artID = tonumber(plain(artID))
    r.inData = list and #list or 0
    local files = {}
    if list then
        for i = 1, #list do
            local o = list[i]
            if type(o.layers) == "table" then
                for _, l in pairs(o.layers) do
                    for j = 3, #l, 3 do files[l[j]] = true end
                end
            else
                for j = 7, #o, 3 do files[o[j]] = true end
            end
        end
    end
    local explored, api = Canvas.exploredFor(mapID)
    r.api = api
    if explored then
        local ok, err = pcall(function()
            for i = 1, #explored do
                local e = explored[i]
                local ids = type(e) == "table" and e.fileDataIDs
                if type(ids) == "table" then
                    r.explored = r.explored + 1
                    local all = #ids > 0
                    for j = 1, #ids do
                        if not files[ids[j]] then
                            all = false
                            if #r.missingFiles < 20 then
                                r.missingFiles[#r.missingFiles + 1] = tonumber(plain(ids[j]))
                            end
                        end
                    end
                    if all then r.found = r.found + 1 else r.missing = r.missing + 1 end
                end
            end
        end)
        if not ok then r.api, r.error = "raised reading", plain(err) end
    end
    mirror("mapcheck", r)
    local where = format("map %s (art %s)", tostring(mapID), tostring(r.artID or "?"))
    if not explored or r.api ~= "present" then
        return out(format("mapcheck %s: GetExploredMapTextures %s - nothing to compare; the data "
            .. "has %d overlay%s for this art. Saved as mapcheck.", where, r.api, r.inData,
            r.inData == 1 and "" or "s"))
    end
    out(format("mapcheck %s: %d explored overlay%s, %d found in the data (build %s), %d missing. "
        .. "Saved as mapcheck.", where, r.explored, r.explored == 1 and "" or "s", r.found,
        tostring(r.dataBuild or "none"), r.missing))
    return r
end

function E.open(panel)
    -- Asked for in combat: it opens when combat ends instead.
    if inCombat() then
        E.combatHidden = true
        E.pendingPanel = panel or E.pendingPanel or "props"
        out(E.COMBAT_LATER)
        return false
    end
    if not E.build() then
        warn("the editor could not be built on this client - /amb export and /amb import "
            .. "still work.")
        return false
    end
    if not E.zoneName then E.goToMyZone() end
    E.noteDataBuild()
    E.frame:Show()
    E.showPanel(panel == "zones" and "props" or (panel or "props"))
    if panel == "save" or panel == "export" then E.say(nil) end
    -- Import is for pasting: put the cursor in its box.
    if E.panel == "import" and E.importBox then UI.call(E.importBox, "SetFocus") end
    E.refresh()
    return true
end

function E.close()
    -- A close asked for while combat has it hidden: it stays closed.
    E.combatHidden, E.pendingPanel = false, nil
    if E.isShown() then E.frame:Hide() end
end

-- `/amb ui save`, and the footer button on a regressed build (E.footerClicked).
-- On a normal build that is Export, with no popup: there is nothing the player
-- must do (DESIGN-ui.md 7.1), and no clipboard attempt, which is the Export
-- click's alone (feedback-2.md item 5). On a
-- regressed build it is Save to file, and a popup in the player's face saying
-- there is a step left for them (feedback-1.md item 8, kept there by answers-2
-- Q7). The steps panel opens behind it. With no popup on this client the same
-- words go on the canvas instead.
function E.openSave()
    if not regressed() then return E.open("export") end
    if not E.open("save") then return false end
    local shown = false
    local dialogs = UI.G("StaticPopupDialogs")
    if type(dialogs) == "table" and dialogs[POPUP_SAVE] then
        shown = UI.callG("StaticPopup_Show", POPUP_SAVE)
    end
    if not shown then E.notice(E.SAVE_POPUP_TEXT) end
    return true
end

function E.toggle()
    if E.isShown() then E.close() else E.open("props") end
end

-- Popups ------------------------------------------------------------------------------------------

do
    local dialogs = UI.G("StaticPopupDialogs")
    if type(dialogs) == "table" then
        dialogs[POPUP_REVERT] = {
            text = "Put %s back to the string exported on %s? Every change since is lost.",
            button1 = "Revert",
            button2 = "Cancel",
            OnAccept = function() pcall(E.confirmRevert) end,
            OnCancel = function() E.pendingRevert = nil end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        dialogs[POPUP_DELZONE] = {
            text = "Delete %s?",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function() pcall(E.confirmDeleteZone) end,
            OnCancel = function() E.pendingDeleteZone = nil end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        -- Regressed build only (DESIGN-ui.md 6.8): the state's own line in place of
        -- 69977's "They are lost at /reload".
        dialogs[POPUP_UNSAVED] = {
            text = "You have %s. %s Open Save to file?",
            button1 = "Save to file",
            button2 = "Close anyway",
            OnAccept = function() pcall(E.openSave) end,
            OnCancel = function() end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        dialogs[POPUP_SAVE] = {
            text = E.SAVE_POPUP_TEXT,
            button1 = "OK",
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        -- A refused value, verbatim (the text is an argument, never a format).
        dialogs[POPUP_FIELD] = {
            text = "%s",
            button1 = "OK",
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        dialogs[POPUP_DELETE] = {
            text = "Delete %s?",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function() pcall(E.confirmDelete) end,
            OnCancel = function() E.pendingDelete = nil end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
    end
end

-- The draft reaches the file even if the window is never closed: PLAYER_LOGOUT
-- fires before the client writes SavedVariables on a /reload or a logout.
--
-- The same frame drops the keyboard the moment combat starts (see setKeyboard)
-- and hides the window until combat ends (feedback-1.md item 12); afterwards
-- the window comes back as it was, and the keyboard with it if a polygon is
-- still being drawn.
do
    local exit = UI.create("Frame", "DynamicAmbianceEditorExit")
    if exit then
        exit:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then
                pcall(E.setKeyboard, false)
                pcall(E.hideForCombat)
            elseif event == "PLAYER_REGEN_ENABLED" then
                local ok, back = pcall(E.restoreAfterCombat)
                if not (ok and back) and E.isShown() and E.draft and E.draft.kind == "polygon" then
                    pcall(E.setKeyboard, true)
                end
            else
                pcall(E.flushDraft)
            end
        end)
        if ns.register then
            ns.register(exit, "PLAYER_LOGOUT")
            ns.register(exit, "PLAYER_REGEN_DISABLED")
            ns.register(exit, "PLAYER_REGEN_ENABLED")
        end
    end
end

-- The options panel: one button (M7: Settings.RegisterAddOnCategory is present,
-- InterfaceOptions_AddCategory is not). Registered at load, guarded; if any part
-- is missing, /amb ui is the way in.
do
    local S = UI.G("Settings")
    local reg = UI.get(S, "RegisterCanvasLayoutCategory")
    local add = UI.get(S, "RegisterAddOnCategory")
    if type(reg) == "function" and type(add) == "function" then
        local panel = UI.create("Frame", "DynamicAmbianceSettingsPanel")
        if panel then
            panel:Hide()
            local b = button(panel, "Open the editor", 140, 24, function()
                -- The options window would sit over the editor; close it if it
                -- offers a way to (FrameXML, unmeasured, so guarded).
                local sp = UI.G("SettingsPanel")
                if sp and not UI.call(sp, "Close") then UI.call(sp, "Hide") end
                E.open("props")
            end)
            if b then b:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16) end
            local note = UI.text(panel, "Everything else is in the editor for now - /amb ui.", 12,
                "text")
            if note then note:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -50) end
            local ok, category = pcall(reg, panel, "Dynamic Ambiance")
            if ok and category then pcall(add, category) end
            E.settingsCategory = ok and category or nil
        end
    end
end

-- Command -------------------------------------------------------------------------------------------

ns.COMMANDS.ui = function(rest)
    local raw = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local verb, arg = raw:match("^(%S+)%s*(.*)$")
    if verb and verb:lower() == "named" then
        -- The subzone's own spelling, so not lowercased.
        if not E.isShown() then return warn("open the editor first: /amb ui") end
        return E.addNamed(arg)
    end
    local sub = raw:lower()
    if sub == "" then return E.toggle() end
    if sub == "zones" then return E.open("props") end
    if sub == "export" then return E.open("export") end
    if sub == "save" then return E.openSave() end
    if sub == "import" then return E.open("import") end
    if sub == "mapcheck" then return E.mapCheck() end
    if sub == "corner" then
        if not E.isShown() then return warn("open the editor first: /amb ui") end
        return E.cornerHere()
    end
    warn("usage: /amb ui [zones | export | save | import | corner | named <subzone> | mapcheck]")
end

-- The branch changed (judged at login, or forced for the acceptance run): the
-- footer, the button and the panels follow it.
ns.onPersistenceChanged = function()
    if not E.built then return end
    -- Save to file exists on a regressed build only.
    if E.panelFor(E.panel) ~= E.panel then E.showPanel(E.panel) end
    E.refresh()
end
