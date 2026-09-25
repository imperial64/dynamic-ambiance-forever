-- Dynamic Ambiance - the clean copier and the Zones.lua generator -------------------
--
-- design/ui/DESIGN-ui.md 1.4 and 7.3. Two things built on one set of field lists:
--
--   * the clean copier (Serialize.cleanZone / Serialize.liveZone): what the saved
--     store holds for a zone - every field of DESIGN-ui.md 1.1 plus the saved
--     bookkeeping (`origin`, `export`), and never an engine cache (`__` keys).
--     Build 70009 reads saved settings back, so this is where "save" goes.
--   * the Zones.lua generator (Serialize.zonesFile): the complete text of the
--     file. On a normal build nothing in the UI calls it; it serves the hidden
--     Save to file panel and its recovery draft on a build where saving has
--     regressed (DESIGN-ui.md 7.2), and it is how the shipped seed file is made.
--
-- No frame calls here, so the headless suite covers it directly. The generator's
-- rules:
--
--   * the header comment, then `local _, ns = ...` / `local Config = ns.Config` /
--     `Config.zones = Config.zones or {}`
--   * one `Config.zones["..."] = { ... }` block per zone, zones sorted by name,
--     areas in their current order - the file order is the tiebreak for equal
--     priorities, so it is preserved exactly
--   * a fixed field order, nil fields omitted, `__` fields (engine and editor
--     caches) never written
--   * numbers at the DA2 precisions, through Preset.num
--   * strings quoted by `q` below rather than %q: %q writes a newline as a
--     backslash and a real line break on 5.1 and as `\n` on 5.4, and a `|` would
--     be taken for an escape code by the edit box the text is shown in. `q`
--     writes `\n`, `\r` and `\124` on every interpreter, so the output is one
--     line per field and identical everywhere.
--
-- Also here: the export bookkeeping of DESIGN-ui.md 1.3 - a preset's version
-- goes up by one each time it is exported (a DA2 string, or on a regressed build
-- a Save-to-file generation) if it changed since its last export. Saving in
-- place never touches it.

local ADDON, ns = ...
if not (ns and ns.Config and ns.Preset) then return end

local Config, Preset = ns.Config, ns.Preset
local format, floor = string.format, math.floor
local num, PL = Preset.num, Preset.PLACES

local Serialize = {}
ns.Serialize = Serialize

-- The .toc's `## Version` is the release packager's project-version keyword,
-- which it replaces with the git tag. This is the fallback for a client with no
-- metadata call and for a copy installed straight from the repo, where the
-- keyword is still there. Keep it in step with the newest CHANGELOG.md entry.
Serialize.ADDON_VERSION = "0.3.1"

-- Where the file lives, relative to the game folder. The addon cannot know the
-- install folder - there is no file API - so this is all it can print.
Serialize.FILE_PATH  = "Interface\\AddOns\\DynamicAmbiance\\Zones.lua"
Serialize.DRAFT_PATH = "WTF\\Account\\<your account>\\SavedVariables\\"

function Serialize.addonVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if type(get) == "function" then
        local ok, v = pcall(get, ADDON or "DynamicAmbiance", "Version")
        if ok and type(v) == "string" and v ~= "" and not v:find("^@") then return v end
    end
    return Serialize.ADDON_VERSION
end

-- Quoting ---------------------------------------------------------------------------

local QUOTE = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["|"] = "\\124" }

local function q(s)
    s = tostring(s):gsub('[\\"\n\r|%c]', function(c)
        return QUOTE[c] or format("\\%03d", c:byte())
    end)
    return '"' .. s .. '"'
end

Serialize.quote = q

-- The recovery draft's quoting (feedback-1.md item 9). The client writes every
-- SavedVariables string in double quotes and escapes the `"` inside, so a
-- Zones.lua line holding `name = "pocket"` would reach the WTF file as
-- `name = \"pocket\"` and could not be copied out as it stands. A Lua long
-- bracket needs no quote marks at all: `name = [[pocket]]` loads the same and
-- survives the trip as it is. A string with a control character (a newline in a
-- note, say) cannot go in a long bracket on one line, so it keeps `q`.
local function longq(s)
    s = tostring(s)
    if s:find("%c") then return q(s) end
    local eq = ""
    while (s .. "]"):find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
    return "[" .. eq .. "[" .. s .. "]" .. eq .. "]"
end

Serialize.longQuote = longq

-- Field order ----------------------------------------------------------------------
--
-- DESIGN-ui.md 1.1. One list covers every kind: a circle comes out as x, y,
-- innerYards, falloffYards and a polygon as corners, falloffYards, because the
-- fields a kind does not have are simply absent.

local ZONE_FIELDS = {
    { "contrast", "value" }, { "brightness", "value" }, { "gamma", "gamma" }, { "map", "int" },
}
local META_FIELDS = {
    { "name", "str" }, { "description", "str" }, { "notes", "str" },
    { "version", "int" }, { "author", "str" }, { "date", "str" },
}
local RULE_FIELDS = {
    { "contrast", "value" }, { "brightness", "value" }, { "gamma", "gamma" },
    { "priority", "int" },
}
local AREA_FIELDS = {
    { "subzone", "str" }, { "name", "str" }, { "notes", "str" },
    { "x", "coord" }, { "y", "coord" },
    { "inner", "coord" }, { "falloff", "coord" },            -- legacy, normalized
    { "innerYards", "yards" }, { "corners", "corners" }, { "falloffYards", "yards" },
    { "priority", "int" },
    { "contrast", "value" }, { "brightness", "value" }, { "gamma", "gamma" },
    { "indoors", "bool" },
}

local PLACES_FOR = {
    value = PL.value, gamma = PL.gamma, int = PL.int, coord = PL.coord, yards = PL.yards,
}

local finite = Preset.finite

local function value(v, kind, qf)
    if kind == "str" then return (qf or q)(v) end
    if kind == "bool" then return v and "true" or "false" end
    if type(v) ~= "number" then return nil end
    return num(v, PLACES_FOR[kind])
end

-- `priority = inf` is a global read in the generated file, so the field would
-- load as nil; `nan` likewise. Neither is ever written: the field is left out
-- with a comment saying so, which the next load reads as "not set".
local function dropped(lines, indent, key, v)
    lines[#lines + 1] = format("%s-- %s left out: %s is not a finite number", indent, key,
        tostring(v))
end

local function known(list)
    local set = {}
    for i = 1, #list do set[list[i][1]] = true end
    return set
end

local KNOWN_AREA, KNOWN_META, KNOWN_RULE = known(AREA_FIELDS), known(META_FIELDS), known(RULE_FIELDS)

-- The store's own bookkeeping on an area (DESIGN-ui.md 1.4): saved with the
-- store, never written into Zones.lua.
local STORE_ONLY = { origin = true }

-- A field this generator does not know, but that holds a plain value, is kept
-- rather than dropped - after the known ones, sorted by name - so an edit nobody
-- here anticipated does not vanish on the next save.
local function extras(t, knownSet, skip)
    local keys = {}
    for k, v in pairs(t) do
        local tv = type(v)
        if type(k) == "string" and k:sub(1, 2) ~= "__" and not knownSet[k]
            and not (skip and skip[k])
            and (tv == "string" or tv == "number" or tv == "boolean")
            and k:match("^[%a_][%w_]*$") then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

local function emitFields(lines, indent, t, list, knownSet, qf)
    for i = 1, #list do
        local key, kind = list[i][1], list[i][2]
        local v = t[key]
        local bad
        if type(v) == "number" and not finite(v) then
            bad = v
        elseif kind == "corners" and type(v) == "table" then
            for k = 1, #v do
                if not finite(v[k]) then bad = v[k]; break end
            end
        end
        if bad ~= nil then
            dropped(lines, indent, key, bad)
        elseif v ~= nil then
            if kind == "corners" then
                if type(v) == "table" then
                    lines[#lines + 1] = indent .. "corners = {"
                    for k = 1, #v, 8 do
                        local row = {}
                        for j = k, math.min(k + 7, #v) do row[#row + 1] = num(v[j], PL.coord) end
                        lines[#lines + 1] = indent .. "    " .. table.concat(row, ", ") .. ","
                    end
                    lines[#lines + 1] = indent .. "},"
                end
            else
                local s = value(v, kind, qf)
                if s then lines[#lines + 1] = format("%s%s = %s,", indent, key, s) end
            end
        end
    end
    if knownSet then
        local more = extras(t, knownSet, STORE_ONLY)
        for i = 1, #more do
            local v = t[more[i]]
            if type(v) == "number" and not finite(v) then
                dropped(lines, indent, more[i], v)
            else
                local s = type(v) == "string" and (qf or q)(v) or (type(v) == "boolean" and tostring(v))
                    or num(v, PL.value)
                lines[#lines + 1] = format("%s%s = %s,", indent, more[i], s)
            end
        end
    end
end

local function emitZone(lines, name, z, qf)
    -- Spaced for a long bracket: `zones[[[x]]]` would read as a call.
    lines[#lines + 1] = format(qf and "Config.zones[ %s ] = {" or "Config.zones[%s] = {",
        (qf or q)(name))
    emitFields(lines, "    ", z, ZONE_FIELDS, nil, qf)
    if type(z.meta) == "table" then
        lines[#lines + 1] = "    meta = {"
        emitFields(lines, "        ", z.meta, META_FIELDS, KNOWN_META, qf)
        lines[#lines + 1] = "    },"
    end
    if z.indoors == false then
        lines[#lines + 1] = "    indoors = false,"
    elseif type(z.indoors) == "table" then
        lines[#lines + 1] = "    indoors = {"
        emitFields(lines, "        ", z.indoors, RULE_FIELDS, KNOWN_RULE, qf)
        lines[#lines + 1] = "    },"
    end
    if type(z.areas) == "table" then
        lines[#lines + 1] = "    areas = {"
        for i = 1, #z.areas do
            lines[#lines + 1] = "        {"
            emitFields(lines, "            ", z.areas[i], AREA_FIELDS, KNOWN_AREA, qf)
            lines[#lines + 1] = "        },"
        end
        lines[#lines + 1] = "    },"
    end
    lines[#lines + 1] = "}"
end

-- The complete text of Zones.lua. Pure: reads `zones`, changes nothing.
function Serialize.zonesFile(zones, when, addonVersion, opts)
    local lines = {
        format("-- Dynamic Ambiance - zones. GENERATED by the in-game editor, %s, addon %s.",
            tostring(when or "?"), tostring(addonVersion or Serialize.ADDON_VERSION)),
        "-- Read once, on a character's first login, to seed its saved zones; after that the",
        "-- character's saved settings are the zones and this file is not read - except on a build",
        "-- that does not read saved settings back, where it is read at every load. Config.lua holds",
        "-- everything that is not a zone.",
        "local _, ns = ...",
        "local Config = ns.Config",
        "Config.zones = Config.zones or {}",
    }

    local names = {}
    for name in pairs(zones or {}) do
        if type(name) == "string" then names[#names + 1] = name end
    end
    table.sort(names)
    for i = 1, #names do
        lines[#lines + 1] = ""
        emitZone(lines, names[i], zones[names[i]], opts and opts.longStrings and longq or nil)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- end of generated zones"
    return table.concat(lines, "\n") .. "\n"
end

-- The clean copier (DESIGN-ui.md 1.4) ---------------------------------------------------
--
-- The store holds a clean copy of each zone, not the live table: the live one
-- carries engine caches (`__layers`, `__areas`, `__W`, `__H`) and `__layers` holds
-- the area tables a second time, which the client would serialise twice. The copy
-- is made from the same field lists as the generator, keeps an unknown plain
-- field the way the generator does, keeps the store's `origin` and `export`, and
-- drops every `__` key and every number that is not finite (a `nan` in a saved
-- file is not one the client can be trusted to read back).

local function copyFields(from, list, knownSet, into)
    for i = 1, #list do
        local key = list[i][1]
        local v = from[key]
        if key == "corners" then
            if type(v) == "table" then
                local c = {}
                for k = 1, #v do
                    if not finite(v[k]) then c = nil; break end
                    c[k] = v[k]
                end
                into.corners = c
            end
        elseif type(v) == "number" then
            if finite(v) then into[key] = v end
        elseif v ~= nil and type(v) ~= "table" then
            into[key] = v
        end
    end
    if knownSet then
        local more = extras(from, knownSet)
        for i = 1, #more do
            local v = from[more[i]]
            if type(v) ~= "number" or finite(v) then into[more[i]] = v end
        end
    end
    return into
end

-- The live zone -> what the store keeps. Pure: the live table is not touched.
function Serialize.cleanZone(zone)
    if type(zone) ~= "table" then return nil end
    local c = copyFields(zone, ZONE_FIELDS, nil, {})
    if type(zone.meta) == "table" then
        c.meta = copyFields(zone.meta, META_FIELDS, KNOWN_META, {})
    end
    if zone.indoors == false then
        c.indoors = false
    elseif type(zone.indoors) == "table" then
        c.indoors = copyFields(zone.indoors, RULE_FIELDS, KNOWN_RULE, {})
    end
    if type(zone.areas) == "table" then
        c.areas = {}
        for i = 1, #zone.areas do
            local a = zone.areas[i]
            if type(a) == "table" then c.areas[#c.areas + 1] = copyFields(a, AREA_FIELDS, KNOWN_AREA, {}) end
        end
    end
    if type(zone.origin) == "string" then c.origin = zone.origin end
    if type(zone.export) == "table" then
        c.export = { pending = zone.export.pending == true, manual = zone.export.manual == true,
                     once = zone.export.once == true }
    end
    return c
end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end

-- What the store keeps -> a fresh live table. A deep copy, so editing the live
-- zone never edits the store behind the copier's back.
function Serialize.liveZone(clean)
    if type(clean) ~= "table" then return nil end
    return deepCopy(Serialize.cleanZone(clean))
end

-- Export bookkeeping ------------------------------------------------------------------
--
-- Saved with the zone (DESIGN-ui.md 1.3, 1.4), so a zone edited today and
-- exported tomorrow still bumps:
--
--   origin          "seed" (from Zones.lua), "editor" or "import"
--   export.pending  changed since its last export - the version bump
--   export.manual   the version was typed in the properties panel; it stands
--   export.once     exported at least once, so a new zone now has a version to bump
--
-- and one cache, on a regressed build only (DESIGN-ui.md 6.8):
--
--   __dirty         changed since the last Save to file - the footer's counter

local function exportState(zone)
    if type(zone.export) ~= "table" then zone.export = {} end
    return zone.export
end

Serialize.exportState = exportState

-- Is this build's saving in doubt? Only then is there a Save to file to count for.
local function regressed()
    return ns.Store ~= nil and ns.Store.regressed() or false
end

local function today()
    if type(date) ~= "function" then return nil end
    local ok, s = pcall(date, "%Y-%m-%d")
    if ok and type(s) == "string" then return s end
    return nil
end

function Serialize.now()
    if type(date) ~= "function" then return "?" end
    local ok, s = pcall(date, "%Y-%m-%d %H:%M")
    if ok and type(s) == "string" then return s end
    return "?"
end

-- `UnitName("player") .. "-" .. GetNormalizedRealmName()`, or nil.
function Serialize.author()
    local name, realm
    if type(UnitName) == "function" then
        local ok, v = pcall(UnitName, "player")
        if ok and ns.plain then name = ns.plain(v) end
    end
    if type(GetNormalizedRealmName) == "function" then
        local ok, v = pcall(GetNormalizedRealmName)
        if ok and ns.plain then realm = ns.plain(v) end
    end
    if not name or name == "" then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- A zone's metadata, created on first need. A preset never exported shows
-- version 1; the author is stamped at creation unless it arrived by import,
-- whose author belongs to the sender.
function Serialize.ensureMeta(zoneName, zone)
    if type(zone.meta) ~= "table" then
        zone.meta = { name = zoneName, description = "", notes = "", version = 1 }
        if zone.origin ~= "import" then zone.meta.author = Serialize.author() end
    end
    zone.meta.version = zone.meta.version or 1
    return zone.meta
end

-- Something about the zone changed. On a regressed build it is also unsaved to
-- file until the next Save to file.
function Serialize.markChanged(zone)
    exportState(zone).pending = true
    if regressed() then zone.__dirty = true end
end

-- The version was typed by hand: it stands at the next export.
function Serialize.markManualVersion(zone)
    exportState(zone).manual = true
end

-- A zone is being exported. Raises the version by one if it changed since its
-- last export, unless the version was typed by hand or this is the first export
-- of a zone created in the editor. Date and author are stamped with the bump.
function Serialize.stampExport(zoneName, zone)
    if type(zone) ~= "table" then return end
    local ex = exportState(zone)
    if ex.pending or ex.manual then
        local meta = Serialize.ensureMeta(zoneName, zone)
        local firstOfNew = zone.origin == "editor" and not ex.once
        if ex.pending and not ex.manual and not firstOfNew then
            meta.version = floor(meta.version or 1) + 1
        end
        meta.date = today() or meta.date
        if meta.author == nil and zone.origin ~= "import" then
            meta.author = Serialize.author()
        end
    end
    ex.pending, ex.manual, ex.once = false, false, true
end

-- The Save-to-file text: every zone stamped as exported, then generated.
function Serialize.exportFile(zones)
    zones = zones or Config.zones
    for name, zone in pairs(zones) do Serialize.stampExport(name, zone) end
    return Serialize.zonesFile(zones, Serialize.now(), Serialize.addonVersion())
end

-- One zone's DA2 string, stamped as exported. Returns the string or nil, reason.
function Serialize.presetString(zoneName)
    local zone = Config.zones[zoneName]
    if not zone then return nil, "no such zone: " .. tostring(zoneName) end
    Serialize.stampExport(zoneName, zone)
    return Preset.serialize(zoneName, zone)
end

-- The generated file for recovery, without stamping anything: a draft is not an
-- export.
function Serialize.draft(zones)
    return Serialize.zonesFile(zones or Config.zones, Serialize.now(), Serialize.addonVersion())
end

-- The same draft as it is kept in the WTF file (feedback-1.md item 9): one string
-- per line of Zones.lua, with long-bracket strings so no line holds a `"` for the
-- client to escape. The lines joined with newlines are a loadable Zones.lua.
function Serialize.draftLines(zones)
    local text = Serialize.zonesFile(zones or Config.zones, Serialize.now(),
        Serialize.addonVersion(), { longStrings = true })
    local lines = {}
    for line in (text:gsub("\n$", "") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

-- Give every zone, and each of its areas, an origin where it has none. Store.lua
-- calls it with "seed" on the zones Zones.lua defined, when it seeds a store.
function Serialize.markOrigin(zones, origin)
    for _, zone in pairs(zones or Config.zones) do
        if type(zone) == "table" then
            if zone.origin == nil then zone.origin = origin end
            for i = 1, #(zone.areas or {}) do
                local a = zone.areas[i]
                if type(a) == "table" and a.origin == nil then a.origin = origin end
            end
        end
    end
end
