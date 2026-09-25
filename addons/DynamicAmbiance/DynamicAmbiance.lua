-- Dynamic Ambiance ---------------------------------------------------------------
--
-- Drives the `Brightness`, `Contrast` and `Gamma` CVars from where the player is
-- standing, easing between hand-authored values per zone and per area within a
-- zone.
--
-- The idea is Fabqt's: <https://x.com/fabqt/status/2100967616080740707>.
--
-- Defaults live in Config.lua; a character's zones and settings live in its saved
-- store (Store.lua), seeded once from Zones.lua. This file is the engine and has
-- no values in it.
--
-- What is measured, and where it came from (docs/DEVELOPMENT.md has the numbers):
--
--   * `Brightness` and `Contrast` exist on this client on a 0-100 scale, are
--     writable, carry no lock flags, and read back exactly. Retail's names -
--     gxBrightness and friends - are absent, so nothing here uses them.
--   * A write costs 0.81 microseconds and does not spike a frame, but allocates
--     ~822 bytes. Three CVars are driven, so the write rate is capped rather than
--     left to run free, and Gamma is written only when its own value moves - a
--     player whose zones never set it pays one write at login and one at logout.
--   * `Gamma` is writable and stores anything, but the screen only applies
--     0.3-3.0 (build 69977). Config.limits holds that range and nothing outside
--     it is ever written.
--   * Reading the player's position allocates 1864 bytes a call, so it runs on a
--     10 Hz accumulator while the ease runs every frame.
--   * `evaluate` below allocates nothing, which is why it can run on every poll
--     over every area without a budget.
--
-- Client constraints this file is written around, from the plugin repo's
-- research/findings.md:
--
--   * An unknown event name raises and aborts the rest of the file, so every
--     RegisterEvent goes through pcall and a refusal is reported rather than
--     silently losing the rest of the addon.
--   * SavedVariables are read back on build 70009 (findings.md P.30), restored at
--     ADDON_LOADED, after this file has run (P.31). Nothing here reads a saved
--     value; Store.lua loads the zones into Config.zones before PLAYER_LOGIN, and
--     detects at every login whether this build still reads them back. The
--     baseline is still declared in config, not captured: the CVars hold whatever
--     this addon last wrote.
--   * ReloadUI is forbidden to addons, so config changes ask a human to /reload.
--   * Secret values survive tostring(), so anything read out of the game goes
--     through plain() before it is compared, printed or stored.
--   * The CVars written here are the ones the client persists to Config.wtf, so
--     the baseline is always restored on the way out.

local ADDON, ns = ...
local Config = ns and ns.Config

-- Config.lua is listed first in the .toc and hands the settings over through the
-- per-addon namespace. If it is not here the .toc is wrong, and saying so beats
-- loading an engine with no values in it.
if not Config then
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff88ddaaAmbiance|r |cffff4444Config.lua did not load - check the .toc.|r")
    end
    return
end

local BRIGHTNESS = "Brightness"
local CONTRAST   = "Contrast"
local GAMMA      = "Gamma"

-- Below this, the ease is treated as arrived and snapped, so a settle write can
-- land the exact target rather than leaving it up to writeEpsilon short. On the
-- 0-100 scale; Gamma's is the same fraction of its own range (gammaScale below).
local SETTLE_EPSILON = 0.02

local floor, sqrt, exp, abs = math.floor, math.sqrt, math.exp, math.abs
local format = string.format

-- Output -------------------------------------------------------------------------

-- A secret value survives tostring() and detonates wherever it is next used, so
-- the coercion is what has to be guarded, not the printing.
local function plain(v)
    if v == nil then return nil end
    if type(v) == "number" then return tostring(v) end
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, v)
        if ok and secret then return nil end
    end
    local ok, s = pcall(format, "%s", v)
    if ok and type(s) == "string" then return s end
    return nil
end

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ddaaAmbiance|r " .. (plain(msg) or "<opaque>"))
    end
end

local function warn(msg) out("|cffffaa00" .. (plain(msg) or "<opaque>") .. "|r") end

-- Numbers ------------------------------------------------------------------------
--
-- The one finite-number guard. The client's tonumber is strtod underneath, so
-- "nan", "inf" and "1e999" all come back as numbers; NaN then passes every range
-- check (every comparison with it is false) and reaches a CVar as the text "nan".
-- The editor's boxes, the preset validator and the CVar writes all ask this.
local HUGE = math.huge
local function finite(v)
    return type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE
end

ns.finite = finite

-- A Config.lua from before Gamma was an axis has no baseline.gamma, and the ease
-- would do arithmetic on nil. 1.0 is the client's measured default (Config.lua).
if type(Config.baseline) == "table" and not finite(Config.baseline.gamma) then
    Config.baseline.gamma = 1.0
    warn("Config.baseline.gamma is missing - using 1.0, the client's default.")
end

-- CVars --------------------------------------------------------------------------

local function getCVar(name)
    local getter = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not getter then return nil end
    local ok, v = pcall(getter, name)
    if not ok then return nil end
    return tonumber(plain(v))
end

local function setCVar(name, value)
    local setter = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not setter then return false end
    return (pcall(setter, name, format("%.2f", value)))
end

-- Limits and the derived Gamma thresholds ------------------------------------------
--
-- Config.limits is the one place an axis's range lives (Config.lua has the
-- measurements behind each pair).

local function limits(axis)
    local l = Config.limits and Config.limits[axis]
    if not l then return nil end
    return l[1], l[2]
end

-- Gamma's range as a fraction of the 0-100 scale the other two use, so its write
-- epsilon and settle threshold are the same fraction of its axis rather than an
-- invented number. With the shipped 0.3-3.0 this is 0.027.
local function gammaScale()
    local lo, hi = limits("gamma")
    if not lo then return 0.01 end
    return (hi - lo) / 100
end

local function gammaEpsilon()
    return (Config.tuning.writeEpsilon or 0.5) * gammaScale()
end

local function clampGamma(g)
    local lo, hi = limits("gamma")
    if g == nil or not lo then return g end
    if g < lo then return lo end
    if g > hi then return hi end
    return g
end

-- Blending -----------------------------------------------------------------------

local function smoothstep(edge0, edge1, x)
    local t = (x - edge0) / (edge1 - edge0)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return t * t * (3 - 2 * t)
end

-- Layers, highest priority last.
--
-- Start at the client default, drop the zone on top of it, then apply every layer
-- that claims the spot in ascending priority order. Each one paints over what is
-- underneath by its own weight, so the highest-priority layer present wins
-- outright where its weight is 1, and fades over the result of everything below it
-- where its weight is partial. That is the whole model:
--
--   nothing claims the spot          the client default
--   approaching a positional layer   the nearer you are, the more of it applies
--   inside it                        its values, flat
--   a higher-priority layer on top   that one instead - regions may overlap
--   ...tagged indoors                only while the client says you are inside
--
-- Priority is what fixed the stairway. The chapel steps report the subzone
-- `Northshire Valley` while `IsIndoors()` is already true, so when indoors was the
-- base layer the named subzone painted over it and the values snapped back
-- outdoors mid-building. Indoors sits ABOVE the named subzone now, so it holds
-- until something with a higher priority still - a named room - takes over.
--
-- Note what this gives up: two overlapping layers at the same priority no longer
-- average symmetrically. The later one paints over the earlier one. Order and
-- priority decide, which is the point of asking for priority.
--
-- Allocates nothing once the layer list for a zone has been built.

-- Yard space ---------------------------------------------------------------------
--
-- Radii and falloffs are in YARDS, never in normalized map units. Measured on
-- build 69977 (M6): Elwynn is 3470.83 x 2314.58 yards, so one normalized unit is
-- ~3471 yd across and ~2315 yd down - a radius in normalized units is an
-- ellipse in the world. `W` and `H` are yards per normalized unit on the zone's
-- map, read once per zone change by prepareZone below and cached on the zone as
-- `__W` / `__H`. Without them no positional layer is applied at all.

-- Polygon weight -----------------------------------------------------------------
--
-- design/ui/interview-1.md: inside the polygon, 1; outside, smoothstep over a
-- single falloff distance measured to the nearest edge; beyond it, 0.
--
-- `poly` is flat: { x1, y1, x2, y2, ... } in the same 0-1 map coordinates as a
-- circle's x/y. Flat rather than a list of pairs, because a pair per corner is a
-- table per corner to build and one more index per read.
--
-- One pass over the edges does both jobs: ray-casting parity for inside, and the
-- nearest-edge distance for the band. Parity does not care about scale, so it
-- stays in normalized units; the distance is taken in yards by scaling each
-- edge's x by W and y by H before squaring - two multiplies per edge - so the
-- band is compared against `falloffYards`. W and H default to 1 (normalized
-- units), which is what the M8 cost figures were taken with. No table, closure
-- or string is made, so it allocates nothing. A point exactly on an edge is
-- inside (distance 0), whatever the parity says there. Fewer than three corners,
-- or no position, is 0.

local HUGE = math.huge

local function polygonWeight(poly, falloff, px, py, W, H)
    if not (poly and px and py) then return 0 end
    local n = #poly
    n = n - n % 2
    if n < 6 then return 0 end
    W, H = W or 1, H or 1

    local inside, best = false, HUGE
    local jx, jy = poly[n - 1], poly[n]
    for i = 1, n, 2 do
        local ix, iy = poly[i], poly[i + 1]

        -- A ray from the point towards +x crosses this edge?
        if (iy > py) ~= (jy > py) then
            if px < ix + (py - iy) * (jx - ix) / (jy - iy) then inside = not inside end
        end

        -- Squared distance from the point to the segment j -> i, in yards.
        local ex, ey = (ix - jx) * W, (iy - jy) * H
        local wx, wy = (px - jx) * W, (py - jy) * H
        local len2 = ex * ex + ey * ey
        local t = 0
        if len2 > 0 then
            t = (wx * ex + wy * ey) / len2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local dx, dy = wx - t * ex, wy - t * ey
        local d2 = dx * dx + dy * dy
        if d2 < best then best = d2 end

        jx, jy = ix, iy
    end

    if inside or best == 0 then return 1 end
    if not falloff or falloff <= 0 then return 0 end
    local d = sqrt(best)
    if d >= falloff then return 0 end
    return smoothstep(falloff, 0, d)
end

ns.polygonWeight = polygonWeight

-- An area's kind is implied by its fields: `subzone` is named, `x` is a circle,
-- `corners` is a polygon, and none of them claims the whole zone.
local function weightOf(a, subzone, px, py, isIndoors, W, H)
    -- Gated to one side of the door.
    if a.indoors ~= nil and a.indoors ~= (isIndoors and true or false) then return 0 end

    if a.subzone then
        return (subzone and a.subzone == subzone) and 1 or 0
    end

    if a.x then
        -- No scale, or radii still in normalized units (a legacy area whose
        -- map scale could not be read): skipped, not guessed at.
        if not (px and W and a.innerYards and a.falloffYards) then return 0 end
        local dx, dy = (px - a.x) * W, (py - a.y) * H
        local d = sqrt(dx * dx + dy * dy)
        if d <= a.innerYards then return 1 end
        if d >= a.falloffYards then return 0 end
        return smoothstep(a.falloffYards, a.innerYards, d)
    end

    if a.corners then
        if not (px and W) then return 0 end
        return polygonWeight(a.corners, a.falloffYards, px, py, W, H)
    end

    -- Neither a name nor a place: claims the whole zone. Only useful with a gate
    -- or a priority, which is exactly what the indoors rule is.
    return 1
end

ns.weightOf = weightOf

-- The layer list is the zone's own areas plus whichever indoors rule applies,
-- sorted once and cached on the zone table. Sorting allocates, so it happens on a
-- zone change rather than on a poll; `evaluate` then only walks it.
local NO_ZONE = {}

local function layersFor(zone)
    local holder = zone or NO_ZONE
    local rule = Config.indoors
    if zone and zone.indoors ~= nil then rule = zone.indoors end

    local areas = zone and zone.areas
    if holder.__layers and holder.__rule == rule and holder.__areas == areas then
        return holder.__layers
    end

    local list, n = {}, 0
    if areas then
        for i = 1, #areas do
            n = n + 1
            list[n] = areas[i]
        end
    end
    if rule then
        n = n + 1
        list[n] = {
            indoors    = true,
            contrast   = rule.contrast,
            brightness = rule.brightness,
            gamma      = rule.gamma,
            priority   = rule.priority or 50,
        }
    end

    -- Stable: equal priorities keep their order in the file, so the later entry
    -- paints over the earlier one rather than the sort deciding arbitrarily.
    local index = {}
    for i = 1, n do index[list[i]] = i end
    table.sort(list, function(x, y)
        local px, py = x.priority or 0, y.priority or 0
        if px == py then return index[x] < index[y] end
        return px < py
    end)

    holder.__layers, holder.__rule, holder.__areas = list, rule, areas
    return list
end

ns.layersFor = layersFor

-- The cache above keys on the identity of `zone.areas`, which is why the editor
-- never mutates that table in place: membership, priority, kind and gate edits
-- replace it. This is for the rare change the identity check cannot see.
local function invalidateLayers(zone)
    if zone then zone.__layers = nil end
end

ns.invalidateLayers = invalidateLayers

-- Three axes, one rule: each layer's value is its own or whatever is underneath,
-- so a layer that states only gamma paints gamma alone and leaves the other two
-- exactly as the layers below left them.
local function evaluate(zone, subzone, px, py, isIndoors)
    local c = Config.baseline.contrast
    local b = Config.baseline.brightness
    local g = Config.baseline.gamma
    if zone then
        c = zone.contrast or c
        b = zone.brightness or b
        g = zone.gamma or g
    end

    local W, H
    if zone then W, H = zone.__W, zone.__H end

    local layers = layersFor(zone)
    for i = 1, #layers do
        local a = layers[i]
        local w = weightOf(a, subzone, px, py, isIndoors, W, H)
        if w > 0 then
            local lc = a.contrast or c
            local lb = a.brightness or b
            local lg = a.gamma or g
            if w >= 1 then
                c, b, g = lc, lb, lg
            else
                c = c + (lc - c) * w
                b = b + (lb - b) * w
                g = g + (lg - g) * w
            end
        end
    end
    return c, b, g
end

ns.evaluate = evaluate

-- Where am I ---------------------------------------------------------------------

-- Two signals, coarse and fine. The coarse one is always available and is the
-- fallback; the fine one is only read when a zone actually has positional areas,
-- because it is the expensive call in the loop.

local function zoneNames()
    local zoneName, subzone
    if GetZoneText then
        local ok, v = pcall(GetZoneText)
        if ok then zoneName = plain(v) end
    end
    if GetSubZoneText then
        local ok, v = pcall(GetSubZoneText)
        if ok then subzone = plain(v) end
    end
    if zoneName == "" then zoneName = nil end
    if subzone == "" then subzone = nil end
    return zoneName, subzone
end

local function currentMap()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local ok, id = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok then return nil end
    return tonumber(plain(id))
end

local function getXY(v) return v:GetXY() end

-- GetPlayerMapPosition is nilable and is known to return nothing in instances, so
-- every read is guarded and a failure falls back to the subzone name by simply
-- returning nil - evaluate() then ignores the positional areas.
local function readPosition(mapID)
    if not (C_Map and C_Map.GetPlayerMapPosition and mapID) then return nil end
    local ok, a, b = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or a == nil then return nil end
    -- Measured on build 69913: this client hands back an object with GetXY, which
    -- is where its 1864 bytes a call come from. Two plain numbers are still
    -- accepted, because that is what the fallback path would look like and the
    -- shape has only been measured on one build.
    if type(a) == "number" then return a, tonumber(b) end
    local ok2, x, y = pcall(getXY, a)
    if ok2 and type(x) == "number" then return x, y end
    if type(a) == "table" and type(a.x) == "number" then return a.x, a.y end
    return nil
end

-- The third signal, and the only one that can tell inside from outside: a building
-- sits at the same x and y as the ground it stands on, so no radius separates
-- them. Measured present on build 69913.
local function indoors()
    local inside, outside
    if IsIndoors then
        local ok, v = pcall(IsIndoors)
        if ok then inside = v and true or false end
    end
    if IsOutdoors then
        local ok, v = pcall(IsOutdoors)
        if ok then outside = v and true or false end
    end
    return inside, outside
end

ns.indoors = indoors

-- Does this zone entry need a position read at all?
local function zoneNeedsPosition(zone)
    if not (zone and zone.areas) then return false end
    for i = 1, #zone.areas do
        if zone.areas[i].x or zone.areas[i].corners then return true end
    end
    return false
end

ns.zoneNeedsPosition = zoneNeedsPosition

-- Yards per normalized unit on a map, or nil. Measured present on build 69977
-- and returning two numbers (M6); still guarded, because an absent or failing
-- call has to skip placed areas rather than take the loop down.
local function mapWorldSize(mapID)
    if not (mapID and C_Map and C_Map.GetMapWorldSize) then return nil end
    local ok, w, h = pcall(C_Map.GetMapWorldSize, mapID)
    if not ok then return nil end
    w, h = tonumber(plain(w)), tonumber(plain(h))
    if not (w and h and w > 0 and h > 0) then return nil end
    return w, h
end

ns.mapWorldSize = mapWorldSize

-- The one conversion from an old normalized radius to yards. An exact one does
-- not exist - the old radius was an ellipse - so it uses the geometric mean of
-- the two axis scales. Elwynn's chapel forecourt, 0.0040 / 0.0200, becomes
-- 11.3 / 56.7 yd.
local function legacyToYards(r, W, H)
    return r * sqrt(W * H)
end

ns.legacyToYards = legacyToYards

-- Readies a zone for evaluate, on a zone change rather than on a poll:
--
--   * a gamma outside Config.limits.gamma is clamped, with one warning - the
--     CVar would store it and the screen would ignore it
--   * the map's scale is read and cached as __W, __H
--   * a legacy area (`inner` / `falloff`, normalized) is converted to yards in
--     place and tagged `__converted`, so the editor can say so
--
-- Returns true when placed areas can be applied. With no scale they are skipped
-- with one warning per zone table, the same policy as a map-ID mismatch.
local function prepareZone(zone, zoneName)
    if type(zone) ~= "table" then return false end
    local label = tostring(zoneName or (zone.meta and zone.meta.name) or "zone")

    local lo, hi = limits("gamma")
    local function clampField(t, where)
        local g = t.gamma
        if type(g) == "number" and lo and (g < lo or g > hi) then
            t.__gammaWas = g
            t.gamma = clampGamma(g)
            warn(format("%s: %s gamma %s is outside the range the screen applies (%s-%s) - "
                .. "clamped to %s.", label, where, tostring(g), tostring(lo), tostring(hi),
                tostring(t.gamma)))
        end
    end
    clampField(zone, "zone")
    if type(zone.indoors) == "table" then clampField(zone.indoors, "indoor rule") end
    local areas = zone.areas or {}
    for i = 1, #areas do
        clampField(areas[i], format("area %d", i))
    end

    if not zoneNeedsPosition(zone) then return true end

    if not zone.__W then
        zone.__W, zone.__H = mapWorldSize(zone.map)
    end
    local W, H = zone.__W, zone.__H
    if not W then
        if not zone.__scaleWarned then
            zone.__scaleWarned = true
            warn(format("%s: map scale unavailable for map %s - placed areas skipped.",
                label, tostring(zone.map)))
        end
        return false
    end

    for i = 1, #areas do
        local a = areas[i]
        if a.x and a.innerYards == nil and a.falloffYards == nil
            and type(a.inner) == "number" and type(a.falloff) == "number" then
            a.innerYards   = floor(legacyToYards(a.inner, W, H) * 10 + 0.5) / 10
            a.falloffYards = floor(legacyToYards(a.falloff, W, H) * 10 + 0.5) / 10
            a.inner, a.falloff = nil, nil
            a.__converted = true
        end
    end
    return true
end

ns.prepareZone = prepareZone

-- Every distinct subzone name seen in each zone this session, for the editor's
-- Named tool. A set per zone; the only allocation is on a name not seen before.
local seenSubzones = {}
ns.seenSubzones = seenSubzones

local function noteSubzone(zoneName, subzone)
    if not (zoneName and subzone) then return end
    local set = seenSubzones[zoneName]
    if not set then
        set = {}
        seenSubzones[zoneName] = set
    end
    if not set[subzone] then set[subzone] = true end
end

ns.noteSubzone = noteSubzone

-- State --------------------------------------------------------------------------

local state = {
    mode        = "auto",   -- auto | off | hold
    frozen      = false,    -- combat
    curC        = Config.baseline.contrast,
    curB        = Config.baseline.brightness,
    curG        = Config.baseline.gamma,
    tgtC        = Config.baseline.contrast,
    tgtB        = Config.baseline.brightness,
    tgtG        = Config.baseline.gamma,
    heldC       = nil,
    heldB       = nil,
    heldG       = nil,
    writtenC    = nil,
    writtenB    = nil,
    writtenG    = nil,
    pollAccum   = 0,
    writeAccum  = 0,
    zoneName    = nil,
    subzone     = nil,
    zone        = nil,
    needsPos    = false,
    mapID       = nil,
    mapWarned   = false,
    px          = nil,
    py          = nil,
    writes      = 0,
    debug       = false,
    loaded      = false,
}

ns.state = state

local frame

local function pollInterval()
    local hz = Config.tuning.pollHz or 10
    if hz <= 0 then return 0 end
    return 1 / hz
end

local function writeInterval()
    local hz = Config.tuning.writeHz or 0
    if hz <= 0 then return 0 end
    return 1 / hz
end

-- Target -------------------------------------------------------------------------

local function resolveZone(zoneName)
    state.zone = zoneName and Config.zones[zoneName] or nil
    if state.zone then prepareZone(state.zone, zoneName) end
    state.needsPos = zoneNeedsPosition(state.zone)
    layersFor(state.zone)    -- sort now, on a zone change, not on the next poll
end

local function refreshTarget(force)
    if state.mode == "off" then
        state.tgtC = Config.baseline.contrast
        state.tgtB = Config.baseline.brightness
        state.tgtG = Config.baseline.gamma
        return
    end
    if state.mode == "hold" then
        state.tgtC = state.heldC
        state.tgtB = state.heldB
        state.tgtG = state.heldG or state.tgtG
        return
    end

    -- Suspended by an instance rule. Set by Settings.lua, which owns deciding it;
    -- this only has to aim at the baseline while it is set. The ease does the
    -- rest, so both edges are smooth and leaving needs no reload.
    --
    -- Below `hold` on purpose: holding is something a person typed, suspending is
    -- something the addon decided for them, and the addon does not overrule them.
    if state.suspendedBy then
        state.tgtC = Config.baseline.contrast
        state.tgtB = Config.baseline.brightness
        state.tgtG = Config.baseline.gamma
        return
    end

    local zoneName, subzone = zoneNames()
    if force or zoneName ~= state.zoneName then
        -- The map-mismatch warning is once per zone entry. A forced refresh - the
        -- editor sends one on every step of a drag - is not an entry.
        if zoneName ~= state.zoneName then state.mapWarned = false end
        state.zoneName = zoneName
        resolveZone(zoneName)
        state.mapID = nil
    end
    state.subzone = subzone
    noteSubzone(zoneName, subzone)

    state.px, state.py = nil, nil
    if state.needsPos then
        state.mapID = state.mapID or currentMap()
        local zoneMap = state.zone and state.zone.map
        if zoneMap and state.mapID and zoneMap ~= state.mapID then
            -- The coordinates in config belong to a different map than the one
            -- the client is handing back, so applying them would put areas in
            -- the wrong place. Drop to the subzone path instead.
            if not state.mapWarned then
                state.mapWarned = true
                warn(format("%s: config coordinates are for map %d, client reports %d - "
                    .. "positional areas skipped. Re-capture with /amb here.",
                    tostring(state.zoneName), zoneMap, state.mapID))
            end
        else
            state.px, state.py = readPosition(state.mapID)
        end
    end

    state.indoors = indoors()
    state.tgtC, state.tgtB, state.tgtG = evaluate(state.zone, state.subzone,
        state.px, state.py, state.indoors)
    state.tgtG = clampGamma(state.tgtG)

    -- Only on a change. This runs at the poll rate, so logging unconditionally is
    -- ten lines a second and unreadable - which matters because walking a route
    -- with this on is how you find out what the subzones are really called.
    if state.debug then
        local moved = state.zoneName ~= state.dbgZone or state.subzone ~= state.dbgSub
            or state.indoors ~= state.dbgIn
        local shifted = state.dbgC == nil
            or abs(state.tgtC - state.dbgC) >= 1 or abs(state.tgtB - state.dbgB) >= 1
            or abs(state.tgtG - state.dbgG) >= gammaScale()
        if moved or shifted then
            state.dbgZone, state.dbgSub, state.dbgIn =
                state.zoneName, state.subzone, state.indoors
            state.dbgC, state.dbgB, state.dbgG = state.tgtC, state.tgtB, state.tgtG
            out(format("%s / %s%s%s  ->  c=%.1f b=%.1f g=%.3f%s",
                tostring(state.zoneName), tostring(state.subzone),
                state.indoors and " |cffffff00[indoors]|r" or "",
                state.suspendedBy and " |cffffaa00[suspended]|r" or "",
                state.tgtC, state.tgtB, state.tgtG,
                state.px and format("   @ %.4f, %.4f", state.px, state.py) or ""))
        end
    end
end

-- Writing ------------------------------------------------------------------------

-- Contrast and brightness go out as a pair, as they always have. Gamma goes out
-- on its own, only when its own value moved, so driving the other two never
-- costs a Gamma write. Both halves are the same path: setCVar, one per CVar.
--
-- A value that is not a finite number is never written, from any path: the CVar
-- keeps its last good value. Config.wtf persists these, so a "nan" written once
-- would outlive the session.
local function writePair(c, b)
    local okC, okB = finite(c), finite(b)
    if okC then
        setCVar(CONTRAST, c)
        state.writtenC = c
    end
    if okB then
        setCVar(BRIGHTNESS, b)
        state.writtenB = b
    end
    if okC or okB then state.writes = state.writes + 1 end
end

local function writeGamma(g)
    if not finite(g) then return end
    -- Never outside the range the screen applies: the CVar would store it and
    -- the screen would ignore it, which is the accepted-and-ignored failure.
    g = clampGamma(g)
    setCVar(GAMMA, g)
    state.writtenG = g
    state.writes = state.writes + 1
end

local function writeNow(c, b, g)
    writePair(c, b)
    if g ~= nil then writeGamma(g) end
end

local function maybeWrite()
    local wrote = false
    local eps = Config.tuning.writeEpsilon or 0.5
    local dc = state.writtenC and abs(state.curC - state.writtenC) or math.huge
    local db = state.writtenB and abs(state.curB - state.writtenB) or math.huge
    if dc > eps or db > eps then
        writePair(state.curC, state.curB)
        wrote = true
    -- Settled: the ease has arrived but the last write may still be up to eps
    -- short of it. Land the exact value once, then stop.
    elseif state.curC == state.tgtC and state.curB == state.tgtB
        and (dc > SETTLE_EPSILON or db > SETTLE_EPSILON) then
        writePair(state.curC, state.curB)
        wrote = true
    end

    -- Measured against what would actually be written, so an ease that starts
    -- outside the screen's range (the client's own value, at login) does not
    -- rewrite the same clamped edge on every tick until it comes inside.
    local dg = state.writtenG and abs(clampGamma(state.curG) - state.writtenG) or math.huge
    if dg > gammaEpsilon() then
        writeGamma(state.curG)
        wrote = true
    elseif state.curG == state.tgtG and dg > SETTLE_EPSILON * gammaScale() then
        writeGamma(state.curG)
        wrote = true
    end
    return wrote
end

-- The loop -----------------------------------------------------------------------

local function settled()
    return state.curC == state.tgtC and state.curB == state.tgtB
       and state.writtenC == state.curC and state.writtenB == state.curB
       and state.curG == state.tgtG and state.writtenG == clampGamma(state.curG)
end

local function onUpdate(_, elapsed)
    if state.frozen then return end

    state.pollAccum = state.pollAccum + elapsed
    if state.pollAccum >= pollInterval() then
        state.pollAccum = 0
        refreshTarget(false)
    end

    -- A NaN anywhere in the ease would stay NaN forever (NaN plus anything is
    -- NaN), so one bad value would freeze the screen until /reload. A bad current
    -- value restarts from what was last written, a bad target holds still.
    if not (finite(state.curC) and finite(state.curB) and finite(state.curG)) then
        local base = Config.baseline
        if not finite(state.curC) then
            state.curC = finite(state.writtenC) and state.writtenC or base.contrast
        end
        if not finite(state.curB) then
            state.curB = finite(state.writtenB) and state.writtenB or base.brightness
        end
        if not finite(state.curG) then
            state.curG = finite(state.writtenG) and state.writtenG or base.gamma
        end
    end
    if not finite(state.tgtC) then state.tgtC = state.curC end
    if not finite(state.tgtB) then state.tgtB = state.curB end
    if not finite(state.tgtG) then state.tgtG = state.curG end

    local k = 1 - exp(-(Config.tuning.easeRate or 4.0) * elapsed)
    state.curC = state.curC + (state.tgtC - state.curC) * k
    state.curB = state.curB + (state.tgtB - state.curB) * k
    state.curG = state.curG + (state.tgtG - state.curG) * k
    if abs(state.tgtC - state.curC) < SETTLE_EPSILON then state.curC = state.tgtC end
    if abs(state.tgtB - state.curB) < SETTLE_EPSILON then state.curB = state.tgtB end
    if abs(state.tgtG - state.curG) < SETTLE_EPSILON * gammaScale() then
        state.curG = state.tgtG
    end

    state.writeAccum = state.writeAccum + elapsed
    if state.writeAccum >= writeInterval() then
        state.writeAccum = 0
        maybeWrite()
    end

    -- `/amb off` eases back to the baseline before it stops, rather than leaving
    -- the screen wherever the last frame put it.
    if state.mode == "off" and settled() then
        frame:Hide()
        out("off - baseline restored.")
    end
end

ns.onUpdate = onUpdate

-- Events -------------------------------------------------------------------------

-- An unknown event name raises and aborts the rest of the file on this client, so
-- registration is wrapped and a refusal is reported instead of taking the addon
-- down with it.
local function register(f, event)
    local ok = pcall(f.RegisterEvent, f, event)
    if not ok then warn("event not available on this client: " .. event) end
    return ok
end

-- All three, always: the CVars written here are the ones the client persists, so
-- an axis left out of the restore is an axis left wherever the addon put it.
local function restoreBaseline()
    writeNow(Config.baseline.contrast, Config.baseline.brightness, Config.baseline.gamma)
    state.curC = Config.baseline.contrast
    state.curB = Config.baseline.brightness
    state.curG = clampGamma(Config.baseline.gamma)
end

ns.restoreBaseline = restoreBaseline

local function onLogin()
    if state.loaded then return end
    state.loaded = true

    -- Start the ease from whatever is actually on screen so login does not snap,
    -- but never treat it as the baseline: that value is whatever this addon last
    -- wrote, and adopting it is how an addon ratchets someone's brightness
    -- somewhere they never chose. The baseline comes from config, always.
    local c, b, g = getCVar(CONTRAST), getCVar(BRIGHTNESS), getCVar(GAMMA)
    -- A "nan" left in Config.wtf by an older build reads back as a number that
    -- is not one; it is treated as unread, so the first write replaces it.
    if not finite(c) then c = nil end
    if not finite(b) then b = nil end
    if not finite(g) then g = nil end
    if c then state.curC = c end
    if b then state.curB = b end
    if g then state.curG = g end
    state.writtenC, state.writtenB, state.writtenG = c, b, g

    refreshTarget(true)
    frame:Show()

    local n = 0
    for _ in pairs(Config.zones) do n = n + 1 end
    out(format("loaded. %d zone%s configured, baseline c=%d b=%d g=%s. "
        .. "Client is at c=%s b=%s g=%s.",
        n, n == 1 and "" or "s",
        Config.baseline.contrast, Config.baseline.brightness,
        tostring(Config.baseline.gamma),
        c and format("%.0f", c) or "?", b and format("%.0f", b) or "?",
        g and format("%.2f", g) or "?"))
    if n == 0 then
        out("No zones configured yet - stand somewhere and type |cffffff00/amb here|r.")
    end
end

local handlers = {
    PLAYER_LOGIN           = onLogin,
    PLAYER_ENTERING_WORLD  = function() onLogin(); refreshTarget(true) end,
    ZONE_CHANGED           = function() refreshTarget(true) end,
    ZONE_CHANGED_INDOORS   = function() refreshTarget(true) end,
    ZONE_CHANGED_NEW_AREA  = function() refreshTarget(true) end,
    PLAYER_LOGOUT          = restoreBaseline,
    PLAYER_REGEN_DISABLED  = function()
        if Config.tuning.freezeInCombat then
            state.frozen = true
            if state.debug then out("combat - ease frozen") end
        end
    end,
    PLAYER_REGEN_ENABLED   = function()
        if state.frozen then
            state.frozen = false
            if state.debug then out("combat over - ease resumed") end
        end
    end,
}

-- Commands -----------------------------------------------------------------------

local function capture()
    local zoneName, subzone = zoneNames()
    local mapID = currentMap()
    local px, py = readPosition(mapID)
    local inside, outside = indoors()

    out(format("zone=%s  subzone=%s  map=%s  pos=%s",
        tostring(zoneName), tostring(subzone), tostring(mapID),
        px and format("%.4f, %.4f", px, py) or "unavailable"))
    out(format("  IsIndoors=%s  IsOutdoors=%s",
        tostring(inside), tostring(outside)))

    if not zoneName then
        warn("no zone name - nothing to key an entry on here.")
        return
    end

    local c, b = floor(state.curC + 0.5), floor(state.curB + 0.5)

    -- The entry has to come out ready to work, not merely ready to paste. Two
    -- things decide that and both are easy to forget by hand:
    --
    --   * a layer captured indoors must be gated `indoors = true`, or it fires
    --     outdoors too - a building and the grass in front of it share a
    --     coordinate, and the client reports subzone names on both sides
    --   * it must outrank the indoors rule, or it never shows at all, because
    --     that rule sits above the ordinary zone features
    local gate, priority = "", 10
    if inside then
        gate = "indoors = true, "
        local rule = Config.indoors
        if Config.zones[zoneName] and Config.zones[zoneName].indoors ~= nil then
            rule = Config.zones[zoneName].indoors
        end
        priority = ((rule and rule.priority) or 50) + 10
    end

    local known = Config.zones[zoneName] ~= nil
    if known then
        out("|cffffff00" .. zoneName .. " is already configured - add this to its areas:|r")
        -- Coordinates are meaningless without the map they were taken on, and a
        -- zone that has never held a positional layer will not have recorded one.
        if px and not subzone and not Config.zones[zoneName].map then
            out(format("  |cffffaa00...and add `map = %d,` to the zone itself, or these "
                .. "coordinates cannot be checked against the map they came from.|r", mapID))
        end
    else
        if ns.Store and not ns.Store.regressed() then
            -- Zones.lua is only a seed once a character's store exists
            -- (DESIGN-ui.md 1.2), so a paste there would not be read.
            out("|cffffff00add it in /amb ui, which saves it - the entry, for reference:|r")
        else
            out("|cffffff00paste at the end of Zones.lua (or add it in /amb ui), then /reload:|r")
        end
        out(format('  Config.zones["%s"] = { contrast = %d, brightness = %d,%s areas = {',
            zoneName, Config.baseline.contrast, Config.baseline.brightness,
            (not subzone and px) and format(" map = %d,", mapID) or ""))
    end

    -- Gamma only when it is not the baseline, so an entry captured by someone who
    -- never touched Gamma does not start setting it.
    local g = ""
    if abs(state.curG - Config.baseline.gamma) > gammaEpsilon() then
        g = format(", gamma = %.2f", clampGamma(state.curG))
    end

    local indent = known and "    " or "    "
    if subzone then
        out(format('%s{ subzone = "%s", %spriority = %d, contrast = %d, brightness = %d%s },',
            indent, subzone, gate, priority, c, b, g))
    elseif px then
        -- Radii in yards. The starting pair is the one this command has always
        -- printed (0.0150 / 0.0400 normalized), converted by the same rule as a
        -- legacy area; like before, it is a starting point to walk and adjust.
        local W, H = mapWorldSize(mapID)
        if W then
            out(format('%s{ name = "here", x = %.4f, y = %.4f, innerYards = %.1f, '
                .. 'falloffYards = %.1f,', indent, px, py,
                legacyToYards(0.0150, W, H), legacyToYards(0.0400, W, H)))
        else
            out(format('%s{ name = "here", x = %.4f, y = %.4f, inner = 0.0150, falloff = 0.0400,',
                indent, px, py))
            out(format("%s  |cffffaa00(map scale unavailable - radii left in normalized "
                .. "units; they are converted when the scale can be read)|r", indent))
        end
        out(format('%s  %spriority = %d, contrast = %d, brightness = %d%s },',
            indent, gate, priority, c, b, g))
        if not subzone and ns.editorDrawing and ns.editorDrawing() then
            out("  |cffffff00a polygon is being drawn in the editor|r - press "
                .. "|cffffff00Corner here|r there, or type |cffffff00/amb ui corner|r, to drop "
                .. "a corner on this spot.")
        end
    else
        out(format('%s-- no subzone and no position here; this can only be the zone default',
            indent))
        out(format('%s-- contrast = %d, brightness = %d', indent, c, b))
    end

    if not known then out("  } }") end
    if subzone and px then
        out(format("  |cff888888(also at %.4f, %.4f on map %d, if you would rather place it "
            .. "than name it)|r", px, py, mapID))
    end

    -- Also logged to DynamicAmbianceDB.captures, the raw record it always was, so
    -- captures can be lifted out of the file instead of retyped out of the chat
    -- log. The most recent Config.limits.recordEntries are kept (DESIGN-ui.md 1.5).
    local entry = {
        zone = zoneName, subzone = subzone, map = mapID, x = px, y = py,
        indoors = inside, outdoors = outside,
        contrast = state.curC, brightness = state.curB,
        when = (date and date("%Y-%m-%d %H:%M:%S")) or nil,
    }
    local list
    if ns.Store then
        list = ns.Store.appendRecord("captures", entry)
    else
        if type(DynamicAmbianceDB) ~= "table" then DynamicAmbianceDB = {} end
        DynamicAmbianceDB.captures = DynamicAmbianceDB.captures or {}
        list = DynamicAmbianceDB.captures
        list[#list + 1] = entry
    end
    if ns.Store and ns.Store.regressed() then
        out(format("captured (%d kept). Saving is not yet verified on this build - /reload "
            .. "or log out to write the file, and copy it out before the next session.", #list))
    else
        out(format("captured and saved (%d kept, in DynamicAmbianceDB.captures).", #list))
    end
end

local function status()
    out(format("mode=%s%s%s  zone=%s  subzone=%s%s",
        state.mode, state.frozen and " |cffffaa00(frozen: combat)|r" or "",
        state.suspendedBy
            and format(" |cffffaa00(suspended: %s)|r", state.suspendedBy) or "",
        tostring(state.zoneName), tostring(state.subzone),
        state.indoors and "  |cffffff00[indoors]|r" or ""))
    out(format("  current c=%.1f b=%.1f g=%.3f  ->  target c=%.1f b=%.1f g=%.3f  "
        .. "(%d writes this session)",
        state.curC, state.curB, state.curG, state.tgtC, state.tgtB, state.tgtG, state.writes))
    out(format("  client reports c=%s b=%s g=%s  baseline c=%d b=%d g=%s",
        tostring(getCVar(CONTRAST)), tostring(getCVar(BRIGHTNESS)), tostring(getCVar(GAMMA)),
        Config.baseline.contrast, Config.baseline.brightness, tostring(Config.baseline.gamma)))
    if state.needsPos then
        out(format("  map=%s  pos=%s",
            tostring(state.mapID),
            state.px and format("%.4f, %.4f", state.px, state.py) or "unavailable"))
    end
    if ns.Store then ns.Store.report(out) end
end

local function listConfig()
    local names = {}
    for name in pairs(Config.zones) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        out("no zones configured.")
        return
    end
    local lo, hi = limits("gamma")
    local function gammaNote(t)
        local g = t.__gammaWas or t.gamma
        if type(g) == "number" and lo and (g < lo or g > hi) then
            return format(" |cffffaa00(gamma %s is outside the range the screen applies, "
                .. "%s-%s%s)|r", tostring(g), tostring(lo), tostring(hi),
                t.__gammaWas and format(" - clamped to %s", tostring(t.gamma)) or "")
        end
        return ""
    end

    for i = 1, #names do
        local z = Config.zones[names[i]]
        out(format("|cffffff00%s|r  c=%s b=%s g=%s%s%s", names[i],
            tostring(z.contrast), tostring(z.brightness), tostring(z.gamma),
            z.map and (" map=" .. z.map) or "", gammaNote(z)))
        -- In the order they are applied, lowest priority first, so the listing
        -- reads the same way the blend does.
        local layers = layersFor(z)
        for j = 1, #layers do
            local a = layers[j]
            local where
            if a.subzone then
                where = 'subzone "' .. a.subzone .. '"'
            elseif a.x then
                if a.innerYards then
                    where = format("%s @ %.4f,%.4f  r=%.1f/%.1f yd",
                        a.name or "area", a.x, a.y, a.innerYards, a.falloffYards or 0)
                else
                    where = format("%s @ %.4f,%.4f  r=%s/%s (normalized, not yet converted)",
                        a.name or "area", a.x, a.y, tostring(a.inner), tostring(a.falloff))
                end
            elseif a.corners then
                where = format("%s (%d corners, falloff %s yd)", a.name or "area",
                    floor(#a.corners / 2), tostring(a.falloffYards))
            else
                where = a.name or "the whole zone"
            end
            out(format("    p%-3d %s%s  c=%s b=%s g=%s%s",
                a.priority or 0, where,
                a.indoors == true and " |cffffff00[indoors only]|r"
                    or (a.indoors == false and " [outdoors only]" or ""),
                tostring(a.contrast), tostring(a.brightness), tostring(a.gamma),
                gammaNote(a)))
        end
    end
    if ns.Store and ns.Store.regressed() then
        out("Edit in |cffffff00/amb ui|r and Save to file, or edit Zones.lua, then /reload - "
            .. "saving is not yet verified on this build.")
    else
        out("Edit in |cffffff00/amb ui|r - every edit is saved for this character. Zones.lua "
            .. "only seeded this character's first login.")
    end
end

local function setMode(mode)
    state.mode = mode
    state.pollAccum, state.writeAccum = math.huge, math.huge
    refreshTarget(true)
    frame:Show()
end

local COMMANDS = {}

COMMANDS.on = function()
    setMode("auto")
    out("on.")
end

COMMANDS.off = function()
    setMode("off")
    out("easing back to baseline...")
end

COMMANDS.here = capture

COMMANDS.status = status

COMMANDS.config = listConfig

COMMANDS.auto = function()
    setMode("auto")
    out("released - following the map again.")
end

COMMANDS.reset = function()
    setMode("auto")
    restoreBaseline()
    out("snapped to baseline; still following the map.")
end

COMMANDS.debug = function()
    state.debug = not state.debug
    state.dbgZone, state.dbgSub, state.dbgC, state.dbgB = nil, nil, nil, nil
    out("debug " .. (state.debug and "on - one line per change. Walk the route to learn "
        .. "what the subzones are called." or "off"))
end

COMMANDS.try = function(rest)
    local c, b, g = rest:match("^(%-?[%d%.]+)%s+(%-?[%d%.]+)%s*(%-?[%d%.]*)")
    c, b, g = tonumber(c), tonumber(b), tonumber(g)
    if not (c and b) then
        local lo, hi = limits("gamma")
        warn(format("usage: /amb try <contrast> <brightness> [gamma]   (0-100, 0-100, %s-%s)",
            tostring(lo), tostring(hi)))
        return
    end
    if g then
        local clamped = clampGamma(g)
        if clamped ~= g then
            warn(format("gamma %s is outside the range the screen applies - holding %s.",
                tostring(g), tostring(clamped)))
        end
        g = clamped
    end
    state.heldC, state.heldB, state.heldG = c, b, g
    setMode("hold")
    out(format("holding c=%.0f b=%.0f%s. |cffffff00/amb here|r to capture it, "
        .. "|cffffff00/amb auto|r to release.", c, b, g and format(" g=%.2f", g) or ""))
end

local function usage()
    out("|cffffff00/amb|r                 what it is doing right now")
    out("|cffffff00/amb ui|r              the editor: draw areas on the map, saved as you go")
    out("|cffffff00/amb ui export|r       a zone's preset string to copy")
    out("|cffffff00/amb ui import|r       paste a preset too long for the chat box")
    out("|cffffff00/amb here|r            a paste-ready config entry for where you stand")
    out("|cffffff00/amb try c b [g]|r     hold these values so you can look at them")
    out("|cffffff00/amb auto|r            release a hold, follow the map again")
    out("|cffffff00/amb on|r / |cffffff00off|r        enable, or ease back to baseline and stop")
    out("|cffffff00/amb reset|r           snap to baseline without stopping")
    out("|cffffff00/amb config|r          the zones and areas currently loaded")
    out("|cffffff00/amb settings|r        the toggles, including the instance auto-toggles")
    out("|cffffff00/amb set <key> on|r    flip one - saved for this character")
    out("|cffffff00/amb settings reset|r  every toggle back to Config.lua's defaults")
    out("|cffffff00/amb export [zone]|r   a preset string for a zone, ready to paste")
    out("|cffffff00/amb import <str>|r    offer one to yourself, with the confirmation")
    out("|cffffff00/amb ignore <name>|r   or |cffffff00all|r, or |cffffff00list|r")
    out("|cffffff00/amb debug|r           log every target change")
    out("|cffffff00/amb status|r          the same; its last lines say whether this build keeps saved settings")
end

COMMANDS.help = usage

local function dispatch(msg)
    msg = (plain(msg) or ""):gsub("^%s+", "")
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "" then return status() end
    local fn = COMMANDS[cmd]
    if not fn then
        warn("unknown: " .. cmd)
        return usage()
    end
    return fn(rest or "")
end

ns.dispatch = dispatch

-- Wiring -------------------------------------------------------------------------

frame = CreateFrame("Frame", "DynamicAmbianceFrame")
frame:Hide()
frame:SetScript("OnUpdate", onUpdate)
frame:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if not h then return end
    local ok, err = pcall(h, ...)
    if not ok then warn("error in " .. event .. ": " .. (plain(err) or "?")) end
end)

for event in pairs(handlers) do
    register(frame, event)
end

SLASH_DYNAMICAMBIANCE1 = "/ambiance"
SLASH_DYNAMICAMBIANCE2 = "/amb"
SlashCmdList["DYNAMICAMBIANCE"] = dispatch

ns.frame = frame

-- Handed to the files loaded after this one, which add their own entries to
-- COMMANDS. dispatch() looks the table up at call time, so a later addition is
-- live without this file knowing about it.
ns.COMMANDS      = COMMANDS
ns.out           = out
ns.warn          = warn
ns.plain         = plain
ns.getCVar       = getCVar
ns.setCVar       = setCVar
ns.zoneNames     = zoneNames
ns.currentMap    = currentMap
ns.readPosition  = readPosition
ns.refreshTarget = refreshTarget
ns.register      = register
ns.BRIGHTNESS    = BRIGHTNESS
ns.CONTRAST      = CONTRAST
ns.GAMMA         = GAMMA
ns.limits        = limits
ns.clampGamma    = clampGamma
ns.gammaEpsilon  = gammaEpsilon
