-- Dynamic Ambiance - the preset format --------------------------------------------
--
-- A preset is ONE zone: its defaults, its metadata and all of its areas. "Here is
-- my Duskwood." See DESIGN-settings-and-sharing.md for why that unit and not a
-- whole profile; design/ui/DESIGN-ui.md section 2 for DA2.
--
-- This file is the format and nothing else - serialize, parse, validate, and build
-- the chat link. It touches no CVar, shows no UI and sends nothing. That is
-- deliberate: it makes the part with all the edge cases testable without a client,
-- and it means the same code serves both transports. Share.lua does the UI and the
-- deciding.
--
-- THE FORMAT, and why it is not base64.
--
--     DA2~Duskwood~60~40~~1429~m:My Duskwood:::3:<character>-<realm>:2026-09-24~s:Raven Hill:10:65:32::::~...~9f3a
--
-- Readable, greppable, diffable, and pasteable into a forum post as-is. The
-- alternative - serialize to Lua, compress, base64 - is what WeakAuras does, and
-- it is the right answer when the payload is kilobytes of arbitrary structure.
-- This payload is a zone name and about ten numbers per area. Compressing it
-- would cost a deflate implementation in Lua 5.1 with no `string.buffer`
-- (IDEAS.md idea 1 raises exactly this) to save bytes that were never the problem,
-- and it would turn something a human can sanity-check into something only the
-- addon can read. A preset a person can read before they import it is worth more
-- here than a shorter one.
--
-- Grammar (DA2):
--
--   preset   := "DA2" "~" header ( "~" meta )? ( "~" area )* "~" checksum
--   header   := zone "~" contrast "~" brightness "~" gamma "~" map
--   meta     := "m" ":" name ":" description ":" notes ":" version ":" author ":" date
--   named    := "s" ":" subzone ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" name ":" notes
--   circle   := "c" ":" name ":" x ":" y ":" innerYards ":" falloffYards ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" notes
--   polygon  := "g" ":" name ":" falloffYards ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" notes ":" corners
--   rule     := "z" ":" name ":" priority ":" contrast ":" brightness ":" gamma ":" indoors ":" notes
--   corners  := number "," number ( "," number "," number )+
--   indoors  := "" | "0" | "1"
--
-- Every numeric field may be empty, meaning nil (inherit). `corners` is always
-- the last field of a polygon, so a stray comma elsewhere cannot be mistaken for
-- one. DA1 (the format before metadata, gamma and yards) still parses; export
-- writes DA2 only.
--
-- Escaping. `~`, `:`, `|` and `%` are the structure, so they are percent-escaped
-- inside any field - and so is every control character, newlines included, so a
-- preset is always one line whatever its notes say. Zone and subzone names come
-- from the client and are not the author's to choose, so they genuinely can
-- contain almost anything.
--
-- The checksum is not security. It catches a paste that lost its tail to a chat
-- line limit or a forum's line wrapping, which is the actual failure mode. Nothing
-- here defends against a hostile sender - that is what the confirmation in
-- Share.lua is for, and the blast radius is three display sliders.

local ADDON, ns = ...
if not (ns and ns.Config) then return end

local Config = ns.Config
local format, floor, sqrt = string.format, math.floor, math.sqrt

local Preset = {}
ns.Preset = Preset

-- The engine's finite-number guard (DynamicAmbiance.lua), shared by the editor.
local finite = ns.finite or function(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
Preset.finite = finite

-- An area that sets none of the three values is inert: it paints nothing. A new
-- shape starts that way in the editor, so it is legal - saved, exported and
-- imported exactly as drawn - and the editor labels it rather than refusing it.
function Preset.inert(a)
    return type(a) == "table" and a.contrast == nil and a.brightness == nil and a.gamma == nil
end

Preset.VERSION  = "DA2"
Preset.LEGACY   = "DA1"
Preset.LINKTYPE = "dynamicambiance"

-- Caps. A preset arriving over the wire is untrusted input in the ordinary sense -
-- not malicious, but possibly from a much later version, or truncated, or written
-- by hand. Every one of these exists so a malformed preset is rejected with a
-- reason rather than half-applied.
Preset.MAX_AREAS = 64

-- 4000 is the size MEASURED to paste into and copy out of an edit box intact on
-- build 69977, both single- and multi-line (design/ui/measurements-2026-09-24.md,
-- M5). It is a floor, not a ceiling: 4000 was the size tested, not a limit found.
-- If a real preset is ever refused, raise this by measuring a larger paste
-- (DESIGN-ui.md 8.3), not by editing the number.
Preset.MAX_LENGTH = 4000

-- Proposals, not measurements (DESIGN-ui.md 1.3): they keep the total under the
-- length cap and can be changed.
Preset.MAX_NAME        = 64
Preset.MAX_DESCRIPTION = 64
Preset.MAX_NOTES       = 500
Preset.MAX_AREA_NOTES  = 200

-- Proposal from M8: twelve 32-corner areas cost ~725 us a second at the 10 Hz poll.
Preset.MAX_CORNERS = 32

-- Places after the decimal point, per field kind (DESIGN-ui.md 2.1).
Preset.PLACES = { coord = 4, yards = 1, value = 4, gamma = 3, int = 0 }
local PL = Preset.PLACES

-- Escaping -------------------------------------------------------------------------

local ESCAPE = { ["%"] = "%25", ["~"] = "%7E", [":"] = "%3A", ["|"] = "%7C" }

local function escChar(c)
    return ESCAPE[c] or format("%%%02X", c:byte())
end

local function esc(s)
    if s == nil then return "" end
    return (tostring(s):gsub("[%%~:|%c]", escChar))
end

local function unesc(s)
    if s == nil or s == "" then return nil end
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

Preset.esc, Preset.unesc = esc, unesc

-- Numbers go out at a fixed precision rather than through tostring, which on 5.1
-- renders 0.492 as "0.492" and 1/3 as "0.33333333333333" - a difference that would
-- make two identical presets serialize differently and break the checksum for no
-- reason.
local function num(v, places)
    if v == nil then return "" end
    local s = format("%." .. (places or PL.value) .. "f", v)
    -- Trailing zeros are only noise AFTER a decimal point. Stripping them
    -- unconditionally turns priority 10 into 1 and map 1420 into 142, which
    -- reorders layers and mislabels a map without anything looking wrong.
    -- (A plain find for "." - DA1's find for "%." with plain=true looked for the
    -- two characters "%." and so never stripped anything.)
    if s:find(".", 1, true) then
        s = s:gsub("0+$", ""):gsub("%.$", "")
    end
    if s == "-0" then s = "0" end
    return s
end

Preset.num = num

local function maybe(v) return v ~= nil and tonumber(v) or nil end

-- Checksum -------------------------------------------------------------------------
--
-- Fletcher-16. Four hex digits, order-sensitive, and about ten lines - which is
-- the right size for something whose only job is to notice a truncated paste.

local function checksum(s)
    local a, b = 0, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 255
        b = (b + a) % 255
    end
    return format("%02x%02x", b, a)
end

Preset.checksum = checksum

-- Yards ------------------------------------------------------------------------------

local function worldSize(mapID)
    if ns.mapWorldSize then return ns.mapWorldSize(mapID) end
    return nil
end

local function round1(v) return floor(v * 10 + 0.5) / 10 end

-- An older circle's normalized radius in yards, by the engine's rule (the
-- geometric mean of the two axis scales). nil when there is no scale.
local function legacyYards(r, W, H)
    if not (r and W and H) then return nil end
    if ns.legacyToYards then return round1(ns.legacyToYards(r, W, H)) end
    return round1(r * sqrt(W * H))
end

-- The circle's radii in yards, whichever form it is stored in.
local function circleYards(a, W, H)
    if a.innerYards ~= nil or a.falloffYards ~= nil then return a.innerYards, a.falloffYards end
    return legacyYards(a.inner, W, H), legacyYards(a.falloff, W, H)
end

-- Serialize ------------------------------------------------------------------------

local function gate(v)
    if v == true then return "1" end
    if v == false then return "0" end
    return ""
end

local function serializeArea(a, index, W, H)
    if a.subzone then
        return table.concat({
            "s", esc(a.subzone), num(a.priority, PL.int),
            num(a.contrast), num(a.brightness), num(a.gamma, PL.gamma),
            gate(a.indoors), esc(a.name), esc(a.notes),
        }, ":")
    end
    if a.x then
        local inner, falloff = circleYards(a, W, H)
        if inner == nil and falloff == nil and (a.inner or a.falloff) then
            return nil, format("area %d has radii in normalized units and the map scale is "
                .. "unavailable, so they cannot be written in yards", index)
        end
        return table.concat({
            "c", esc(a.name), num(a.x, PL.coord), num(a.y, PL.coord),
            num(inner, PL.yards), num(falloff, PL.yards), num(a.priority, PL.int),
            num(a.contrast), num(a.brightness), num(a.gamma, PL.gamma),
            gate(a.indoors), esc(a.notes),
        }, ":")
    end
    if a.corners then
        local c = {}
        for i = 1, #a.corners do c[i] = num(a.corners[i], PL.coord) end
        return table.concat({
            "g", esc(a.name), num(a.falloffYards, PL.yards), num(a.priority, PL.int),
            num(a.contrast), num(a.brightness), num(a.gamma, PL.gamma),
            gate(a.indoors), esc(a.notes), table.concat(c, ","),
        }, ":")
    end
    -- Neither a name nor a place: claims the whole zone. Rare in a shared preset,
    -- but it is a legal layer and dropping it silently would change what the
    -- sender meant.
    return table.concat({
        "z", esc(a.name), num(a.priority, PL.int),
        num(a.contrast), num(a.brightness), num(a.gamma, PL.gamma),
        gate(a.indoors), esc(a.notes),
    }, ":")
end

-- Every number a preset carries, by where it sits. `fn(where, field, value)` is
-- called for each one that is set but is not a finite number - which the parser
-- lets through, since tonumber reads "nan", "inf" and "1e999".
local ZONE_NUMBERS = { "contrast", "brightness", "gamma", "map" }
local RULE_NUMBERS = { "contrast", "brightness", "gamma", "priority" }
local AREA_NUMBERS = { "priority", "contrast", "brightness", "gamma", "x", "y",
                       "inner", "falloff", "innerYards", "falloffYards" }

local function eachNonFinite(zone, fn)
    local function scan(t, where, keys)
        for i = 1, #keys do
            local v = t[keys[i]]
            if v ~= nil and not finite(v) then fn(where, keys[i], v) end
        end
    end
    scan(zone, "zone", ZONE_NUMBERS)
    if type(zone.indoors) == "table" then scan(zone.indoors, "zone indoor rule", RULE_NUMBERS) end
    if type(zone.meta) == "table" then scan(zone.meta, "metadata", { "version" }) end
    local areas = type(zone.areas) == "table" and zone.areas or {}
    for i = 1, #areas do
        local a = areas[i]
        if type(a) == "table" then
            local where = format("area %d", i)
            scan(a, where, AREA_NUMBERS)
            if type(a.corners) == "table" then
                for k = 1, #a.corners do
                    if not finite(a.corners[k]) then
                        fn(where, format("corner value %d", k), a.corners[k])
                        break
                    end
                end
            end
        end
    end
end

Preset.eachNonFinite = eachNonFinite

local function serializeMeta(m)
    return table.concat({
        "m", esc(m.name), esc(m.description), esc(m.notes),
        num(m.version, PL.int), esc(m.author), esc(m.date),
    }, ":")
end

-- Takes a zone NAME and the zone table. Returns the string, or nil plus a reason.
function Preset.serialize(zoneName, zone)
    if type(zoneName) ~= "string" or zoneName == "" then
        return nil, "a preset needs a zone name"
    end
    if type(zone) ~= "table" then
        return nil, "no such zone: " .. tostring(zoneName)
    end

    local areas = zone.areas or {}
    if #areas > Preset.MAX_AREAS then
        return nil, format("%d areas is over the %d cap", #areas, Preset.MAX_AREAS)
    end

    -- A string with "inf" or "nan" in it would be refused by the receiver's
    -- validate, so it is never written.
    local broken
    eachNonFinite(zone, function(where, field, v)
        broken = broken or format("%s %s is %s, not a finite number", where, field, tostring(v))
    end)
    if broken then return nil, broken end

    local W, H = zone.__W, zone.__H
    if not W then W, H = worldSize(zone.map) end

    local parts = {
        Preset.VERSION,
        esc(zoneName),
        num(zone.contrast),
        num(zone.brightness),
        num(zone.gamma, PL.gamma),
        num(zone.map, PL.int),
    }
    if type(zone.meta) == "table" then parts[#parts + 1] = serializeMeta(zone.meta) end
    for i = 1, #areas do
        local chunk, err = serializeArea(areas[i], i, W, H)
        if not chunk then return nil, err end
        parts[#parts + 1] = chunk
    end

    local body = table.concat(parts, "~")
    local s = body .. "~" .. checksum(body)
    if #s > Preset.MAX_LENGTH then
        return nil, format("%d bytes is over the %d cap - the most this build has been "
            .. "measured to paste intact", #s, Preset.MAX_LENGTH)
    end
    return s
end

-- Parse ----------------------------------------------------------------------------

local function split(s, sep)
    local out, pattern = {}, "([^" .. sep .. "]*)" .. sep
    for piece in (s .. sep):gmatch(pattern) do out[#out + 1] = piece end
    return out
end

local function parseIndoors(field)
    if field == "1" then return true end
    if field == "0" then return false end
    return nil
end

-- DA1 ------------------------------------------------------------------------------
--
-- The format before gamma, metadata and yards. Kept so a string someone saved
-- still imports; `p` areas become circles with their radii converted to yards
-- when the map's scale can be read.

local function parseAreaDA1(chunk, index)
    local f = split(chunk, ":")
    local kind = f[1]

    if kind == "s" then
        local a = {
            subzone    = unesc(f[2]),
            priority   = maybe(f[3]) or 10,
            contrast   = maybe(f[4]),
            brightness = maybe(f[5]),
            indoors    = parseIndoors(f[6]),
        }
        if not a.subzone then return nil, format("area %d has no subzone name", index) end
        return a
    end

    if kind == "p" then
        local a = {
            name       = unesc(f[2]) or ("area " .. index),
            x          = maybe(f[3]), y = maybe(f[4]),
            inner      = maybe(f[5]), falloff = maybe(f[6]),
            priority   = maybe(f[7]) or 10,
            contrast   = maybe(f[8]),
            brightness = maybe(f[9]),
            indoors    = parseIndoors(f[10]),
        }
        if not (a.x and a.y and a.inner and a.falloff) then
            return nil, format("area %d is positional but missing a coordinate or radius", index)
        end
        return a
    end

    if kind == "z" then
        return {
            name       = unesc(f[2]),
            priority   = maybe(f[3]) or 10,
            contrast   = maybe(f[4]),
            brightness = maybe(f[5]),
            indoors    = parseIndoors(f[6]),
        }
    end

    return nil, format("area %d has an unknown kind %q", index, tostring(kind))
end

local function parseDA1(fields)
    if #fields < 6 then return nil, "too short to be a preset" end
    local zoneName = unesc(fields[2])
    local zone = {
        contrast   = maybe(fields[3]),
        brightness = maybe(fields[4]),
        map        = maybe(fields[5]),
        areas      = {},
    }
    for i = 6, #fields - 1 do
        local a, err = parseAreaDA1(fields[i], i - 5)
        if not a then return nil, err end
        zone.areas[#zone.areas + 1] = a
    end

    -- Radii to yards. Without a scale they stay as they are and the engine
    -- treats them as legacy: converted on entry if the scale turns up, skipped
    -- with a warning if it does not.
    local W, H = worldSize(zone.map)
    if W then
        for i = 1, #zone.areas do
            local a = zone.areas[i]
            if a.x and a.inner then
                a.innerYards, a.falloffYards = legacyYards(a.inner, W, H), legacyYards(a.falloff, W, H)
                a.inner, a.falloff = nil, nil
                a.__converted = true
                zone.__convertedFrom = Preset.LEGACY
            end
        end
    end
    return zoneName, zone
end

-- DA2 ------------------------------------------------------------------------------

-- Field layouts, in order after the kind letter. Every failure below names the
-- area and the field: an import that says "malformed" and stops is
-- indistinguishable from a bug in this file, and the person holding the string
-- is usually the only one who can see what is wrong with it.
local LAYOUT = {
    s = { kind = "named area",
          "subzone", "priority", "contrast", "brightness", "gamma", "indoors", "name", "notes" },
    c = { kind = "circle",
          "name", "x", "y", "innerYards", "falloffYards", "priority", "contrast", "brightness",
          "gamma", "indoors", "notes" },
    g = { kind = "polygon",
          "name", "falloffYards", "priority", "contrast", "brightness", "gamma", "indoors",
          "notes", "corners" },
    z = { kind = "whole-zone rule",
          "name", "priority", "contrast", "brightness", "gamma", "indoors", "notes" },
    m = { kind = "metadata",
          "name", "description", "notes", "version", "author", "date" },
}

local STRING_FIELDS = {
    subzone = true, name = true, notes = true, description = true, author = true, date = true,
}

local function parseFields(chunk, where, layout)
    local f = split(chunk, ":")
    local want = #layout + 1
    if #f ~= want then
        return nil, format("%s is a %s with %d fields, expected %d", where, layout.kind,
            #f - 1, want - 1)
    end
    local t = {}
    for i = 1, #layout do
        local key, raw = layout[i], f[i + 1]
        if STRING_FIELDS[key] then
            t[key] = unesc(raw)
        elseif key == "indoors" then
            if raw ~= "" and raw ~= "0" and raw ~= "1" then
                return nil, format("%s indoors %q is not 0, 1 or empty", where, raw)
            end
            t.indoors = parseIndoors(raw)
        elseif key == "corners" then
            local list = {}
            for piece in (raw .. ","):gmatch("([^,]*),") do
                local v = tonumber(piece)
                if v == nil then
                    return nil, format("%s corner value %q is not a number", where, piece)
                end
                list[#list + 1] = v
            end
            if #list % 2 ~= 0 then
                return nil, format("%s corners has %d values - they come in x,y pairs", where, #list)
            end
            t.corners = list
        elseif raw ~= "" then
            local v = tonumber(raw)
            if v == nil then
                return nil, format("%s %s %q is not a number", where, key, raw)
            end
            t[key] = v
        end
    end
    return t
end

local function parseDA2(fields)
    if #fields < 7 then return nil, "too short to be a preset" end
    local zoneName = unesc(fields[2])
    local zone = { areas = {} }
    local header = { "contrast", "brightness", "gamma", "map" }
    for i = 1, #header do
        local raw = fields[i + 2]
        if raw ~= "" then
            local v = tonumber(raw)
            if v == nil then
                return nil, format("zone %s %q is not a number", header[i], raw)
            end
            zone[header[i]] = v
        end
    end

    local first = 7
    if first < #fields and fields[first]:sub(1, 2) == "m:" then
        local meta, err = parseFields(fields[first], "metadata", LAYOUT.m)
        if not meta then return nil, err end
        zone.meta = meta
        first = first + 1
    end

    for i = first, #fields - 1 do
        local index = i - first + 1
        local chunk = fields[i]
        local kind = chunk:match("^([^:]*)")
        local layout = kind ~= "m" and LAYOUT[kind] or nil
        if not layout then
            return nil, format("area %d has an unknown kind %q", index, tostring(kind))
        end
        local a, err = parseFields(chunk, format("area %d", index), layout)
        if not a then return nil, err end
        if kind == "s" and not a.subzone then
            return nil, format("area %d has no subzone name", index)
        end
        if kind == "c" and not (a.x and a.y) then
            return nil, format("area %d is a circle with no centre", index)
        end
        if kind == "g" and not a.corners then
            return nil, format("area %d is a polygon with no corners", index)
        end
        zone.areas[#zone.areas + 1] = a
    end
    return zoneName, zone
end

-- Returns zoneName, zoneTable, or nil plus a reason.
function Preset.parse(s)
    if type(s) ~= "string" then return nil, "not a string" end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil, "empty" end
    if #s > Preset.MAX_LENGTH then
        return nil, format("%d bytes is over the %d cap - the most this build has been "
            .. "measured to paste intact", #s, Preset.MAX_LENGTH)
    end

    local fields = split(s, "~")
    if #fields < 6 then return nil, "too short to be a preset" end

    local marker = fields[1]
    if marker ~= Preset.VERSION and marker ~= Preset.LEGACY then
        -- Versioning, as IDEAS.md idea 1 asks for. A newer preset is refused by
        -- name rather than parsed hopefully and applied wrongly. The legacy
        -- format still parses but is not named to the player: nobody has a
        -- string in it (design/ui/feedback-2.md item 6).
        return nil, format("this is format %q and this addon speaks %q",
            tostring(marker), Preset.VERSION)
    end

    local given = fields[#fields]
    local body  = s:sub(1, #s - #given - 1)
    local want  = checksum(body)
    if given ~= want then
        return nil, format("checksum %s, expected %s - the string is truncated or edited",
            tostring(given), want)
    end

    local zoneName, zone
    if marker == Preset.LEGACY then
        zoneName, zone = parseDA1(fields)
    else
        zoneName, zone = parseDA2(fields)
    end
    if not zoneName then
        -- A well-formed string with an empty zone field comes back as nil plus
        -- the zone TABLE; the caller prints the reason, so it has to be one.
        if type(zone) == "string" then return nil, zone end
        return nil, "the preset has no zone name"
    end
    if #zoneName > Preset.MAX_NAME then
        return nil, format("zone name is %d characters, cap is %d", #zoneName, Preset.MAX_NAME)
    end
    if #zone.areas > Preset.MAX_AREAS then
        return nil, format("%d areas is over the %d cap", #zone.areas, Preset.MAX_AREAS)
    end

    return zoneName, zone
end

-- Validate ---------------------------------------------------------------------------
--
-- Parsing says the string is well-formed. This says the numbers in it are ones the
-- addon can act on. They are separate because a preset can be perfectly structured
-- and still ask for brightness 4000, and because the same validator has to serve
-- an imported string, a pasted one, and eventually a file in a public library
-- (IDEAS.md idea 7), where it runs in CI against strangers' submissions.
--
-- Ranges come from Config.limits and nothing else. An out-of-range value is
-- REFUSED, not clamped: Gamma in particular stores any value silently, so an
-- imported Gamma 50 would be kept and do nothing on screen - exactly the
-- "accepted and ignored" failure this repo refuses to ship.

local function limits(axis)
    local l = Config.limits and Config.limits[axis]
    if l then return l[1], l[2] end
    return nil
end

-- A number that is not finite is reported once, by the finite check in validate,
-- rather than again here as out of range.
local function inRange(v, lo, hi)
    if v == nil or lo == nil then return true end
    if type(v) == "number" and not finite(v) then return true end
    return type(v) == "number" and v >= lo and v <= hi
end

local function rangeText(lo, hi) return num(lo, 3) .. "-" .. num(hi, 3) end

local function checkValues(t, where, bad)
    for _, axis in ipairs({ "contrast", "brightness" }) do
        local lo, hi = limits(axis)
        if not inRange(t[axis], lo, hi) then
            bad("%s %s %s is outside %s", where, axis, tostring(t[axis]), rangeText(lo, hi))
        end
    end
    local lo, hi = limits("gamma")
    if not inRange(t.gamma, lo, hi) then
        bad("%s gamma %s is outside %s - the screen ignores values outside that range",
            where, tostring(t.gamma), rangeText(lo, hi))
    end
end

local function tooLong(s, cap) return type(s) == "string" and #s > cap end

function Preset.validate(zoneName, zone)
    local problems = {}

    local function bad(fmt, ...) problems[#problems + 1] = format(fmt, ...) end

    if type(zoneName) ~= "string" or zoneName == "" then
        bad("no zone name")
    elseif #zoneName > Preset.MAX_NAME then
        bad("zone name is longer than %d characters", Preset.MAX_NAME)
    elseif zoneName:find("[%c]") then
        -- The name ends up inside a chat link's display text and, later, inside a
        -- web page (IDEAS.md idea 7). Control characters in either are a problem.
        bad("zone name contains control characters")
    end

    -- Every number, whatever it is for: NaN passes every range check, since every
    -- comparison with it is false, and inf passes "a whole number of 0 or more".
    eachNonFinite(zone, function(where, field, v)
        bad("%s %s is %s, not a finite number", where, field, tostring(v))
    end)

    checkValues(zone, "zone", bad)
    if type(zone.indoors) == "table" then checkValues(zone.indoors, "zone indoor rule", bad) end

    local m = zone.meta
    if m ~= nil then
        if type(m) ~= "table" then
            bad("metadata is not a table")
        else
            if tooLong(m.name, Preset.MAX_NAME) then
                bad("preset name is %d characters, the cap is %d", #m.name, Preset.MAX_NAME)
            end
            if tooLong(m.description, Preset.MAX_DESCRIPTION) then
                bad("description is %d characters, the cap is %d", #m.description,
                    Preset.MAX_DESCRIPTION)
            end
            if tooLong(m.notes, Preset.MAX_NOTES) then
                bad("preset notes are %d characters, the cap is %d", #m.notes, Preset.MAX_NOTES)
            end
            local v = m.version
            if v ~= nil and finite(v) and not (v >= 0 and v == floor(v)) then
                bad("version %s is not a whole number of 0 or more", tostring(v))
            elseif v ~= nil and type(v) ~= "number" then
                bad("version %s is not a whole number of 0 or more", tostring(v))
            end
        end
    end

    local placed = 0
    for i = 1, #(zone.areas or {}) do
        local a = zone.areas[i]
        local where = a.subzone and format("area %d (%s)", i, a.subzone) or format("area %d", i)

        local kinds = (a.subzone and 1 or 0) + (a.x and 1 or 0) + (a.corners and 1 or 0)
        if kinds > 1 then
            bad("%s is more than one kind - exactly one of a subzone, a centre or corners",
                where)
        end

        -- An area with no values is inert, not wrong (Preset.inert): refusing it
        -- would make the editor's own new shapes unimportable, and dropping it
        -- would break the round trip.
        checkValues(a, where, bad)

        if a.x then
            placed = placed + 1
            if not (inRange(a.x, 0, 1) and inRange(a.y, 0, 1)) or a.y == nil then
                bad("%s is at %s,%s - map coordinates are normalized 0-1",
                    where, tostring(a.x), tostring(a.y))
            end
            local inner, falloff, unit = a.innerYards, a.falloffYards, " yd"
            if inner == nil and falloff == nil then
                inner, falloff, unit = a.inner, a.falloff, ""
            end
            if type(inner) ~= "number" or type(falloff) ~= "number" or inner < 0 or falloff < 0 then
                bad("%s has a negative or missing radius", where)
            elseif falloff < inner then
                -- Not cosmetic: smoothstep(falloff, inner, d) divides by
                -- (inner - falloff), so an inverted pair inverts the ramp and the
                -- area applies everywhere EXCEPT where it was drawn.
                bad("%s has falloff %s%s smaller than inner %s%s - the ramp would be inside out",
                    where, tostring(falloff), unit, tostring(inner), unit)
            end
        end

        if a.corners then
            placed = placed + 1
            local c = type(a.corners) == "table" and a.corners or {}
            local pairs_ = floor(#c / 2)
            if type(a.corners) ~= "table" or #c % 2 ~= 0 then
                bad("%s has an odd number of corner values", where)
            elseif pairs_ < 3 then
                bad("%s has %d corners - a polygon needs at least 3", where, pairs_)
            elseif pairs_ > Preset.MAX_CORNERS then
                bad("%s has %d corners - the cap is %d", where, pairs_, Preset.MAX_CORNERS)
            end
            for k = 1, #c - 1, 2 do
                if not (type(c[k]) == "number" and type(c[k + 1]) == "number"
                    and inRange(c[k], 0, 1) and inRange(c[k + 1], 0, 1)) then
                    bad("%s corner %d is at %s,%s - map coordinates are normalized 0-1",
                        where, (k + 1) / 2, tostring(c[k]), tostring(c[k + 1]))
                    break
                end
            end
            if type(a.falloffYards) ~= "number" then
                bad("%s is a polygon with no falloffYards", where)
            elseif a.falloffYards < 0 then
                bad("%s has a negative falloffYards %s", where, tostring(a.falloffYards))
            end
        end

        if a.subzone and #a.subzone > Preset.MAX_NAME then
            bad("%s has a subzone name longer than %d characters", where, Preset.MAX_NAME)
        end
        if tooLong(a.name, Preset.MAX_NAME) then
            bad("%s name is %d characters, the cap is %d", where, #a.name, Preset.MAX_NAME)
        end
        if tooLong(a.notes, Preset.MAX_AREA_NOTES) then
            bad("%s notes are %d characters, the cap is %d", where, #a.notes,
                Preset.MAX_AREA_NOTES)
        end
    end

    -- Coordinates are meaningless without the map they were captured on, and the
    -- engine already refuses to apply them to a map they did not come from. A
    -- preset that ships them with no map is not wrong, it is just inert - and
    -- saying so on import beats the receiver wondering why nothing happened.
    if placed > 0 and not zone.map then
        bad("%d positional area(s) but no map id - they cannot be checked against the "
            .. "map they came from, so they will be skipped", placed)
    end

    if #problems == 0 then return true end
    return false, problems
end

-- A description the receiver can read before deciding. The values, not just a
-- name: a preset is judged by what it will do to the screen.

local function valuesText(t)
    return format("c=%s b=%s%s", tostring(t.contrast or "-"), tostring(t.brightness or "-"),
        t.gamma ~= nil and (" g=" .. tostring(t.gamma)) or "")
end

function Preset.describe(zoneName, zone)
    local lines = {}
    lines[#lines + 1] = format("|cffffff00%s|r  zone default %s%s", zoneName, valuesText(zone),
        zone.map and format("  map=%d", zone.map) or "")
    local m = zone.meta
    if type(m) == "table" then
        lines[#lines + 1] = format("    \"%s\"%s  v%s%s%s", tostring(m.name or zoneName),
            (m.description and m.description ~= "") and (" - " .. m.description) or "",
            tostring(m.version or 1),
            m.author and (" by " .. m.author) or "",
            m.date and (", " .. m.date) or "")
    end
    for i = 1, #(zone.areas or {}) do
        local a = zone.areas[i]
        local where
        if a.subzone then
            where = format('subzone "%s"', a.subzone)
        elseif a.x then
            local inner, falloff = a.innerYards, a.falloffYards
            if inner ~= nil or falloff ~= nil then
                where = format("%s @ %.4f,%.4f r=%s/%s yd", a.name or "area", a.x, a.y or 0,
                    tostring(inner), tostring(falloff))
            else
                where = format("%s @ %.4f,%.4f r=%s/%s (normalized)", a.name or "area", a.x,
                    a.y or 0, tostring(a.inner), tostring(a.falloff))
            end
        elseif a.corners then
            where = format("%s (%d corners, falloff %s yd)", a.name or "area",
                floor(#a.corners / 2), tostring(a.falloffYards))
        else
            where = a.name or "the whole zone"
        end
        lines[#lines + 1] = format("    p%-3d %s%s  %s",
            a.priority or 0, where,
            a.indoors == true and " [indoors only]"
                or (a.indoors == false and " [outdoors only]" or ""),
            valuesText(a))
    end
    return lines
end

-- The chat link ----------------------------------------------------------------------
--
-- The payload does NOT ride in the link. A chat line has a hard length limit and
-- the link's display text is what a receiver reads before deciding, so the link
-- carries an identifier and the bytes move separately - which is how Mythic
-- Dungeon Tools and WeakAuras both do it, and why both need the addon on each end.
--
-- Author and date are in the VISIBLE text on purpose. They are the only provenance
-- a receiver gets before clicking, and they make a linked preset attributable in a
-- way a pasted string never is.

function Preset.linkText(zoneName, author, when)
    return format("[%s%s%s]", zoneName,
        author and (" - " .. author) or "",
        when and (" - " .. when) or "")
end

function Preset.link(id, zoneName, author, when)
    return format("|cff88ddaa|H%s:%s|h%s|h|r",
        Preset.LINKTYPE, tostring(id),
        Preset.linkText(zoneName, author, when))
end

-- Pull the id back out of whatever SetItemRef was handed. Returns nil for any link
-- that is not ours, which is the common case - this runs on every link click in
-- the game.
function Preset.linkID(link)
    if type(link) ~= "string" then return nil end
    return link:match("^" .. Preset.LINKTYPE .. ":(.+)$")
end

-- Merge ------------------------------------------------------------------------------
--
-- What an import would collide with. IDEAS.md idea 1 is right that this is the
-- interesting part and the transport is not: the answers are keep mine, take
-- theirs, keep both, or rename theirs, and "keep both" is a legitimate answer here
-- in a way it would not be in most merge UIs, because overlapping layers already
-- coexist by design.
--
-- This reports; it does not decide. Deciding is the receiver's, in the dialog.

-- A placed area's extent in normalized units, expanded by its falloff in yards.
-- A circle is its centre and radius; a polygon is its bounding box (DESIGN-ui.md
-- 2.2: cheap and conservative - it can report an overlap that is not there, never
-- miss one that is).
local function extent(a, W, H)
    if a.x then
        local _, falloff = circleYards(a, W, H)
        if not falloff or not a.y then return nil end
        return a.x - falloff / W, a.y - falloff / H, a.x + falloff / W, a.y + falloff / H,
            falloff
    end
    if a.corners and #a.corners >= 2 then
        local c = a.corners
        local x0, y0, x1, y1 = c[1], c[2], c[1], c[2]
        for k = 1, #c - 1, 2 do
            if c[k] < x0 then x0 = c[k] end
            if c[k] > x1 then x1 = c[k] end
            if c[k + 1] < y0 then y0 = c[k + 1] end
            if c[k + 1] > y1 then y1 = c[k + 1] end
        end
        local f = a.falloffYards or 0
        return x0 - f / W, y0 - f / H, x1 + f / W, y1 + f / H
    end
    return nil
end

local function positionalOverlap(a, b, W, H)
    if a.x and b.x then
        local _, fa = circleYards(a, W, H)
        local _, fb = circleYards(b, W, H)
        if not (fa and fb) then return nil end
        local dx, dy = (a.x - b.x) * W, (a.y - b.y) * H
        local d = sqrt(dx * dx + dy * dy)
        if d < fa + fb then return d end
        return nil
    end
    local ax0, ay0, ax1, ay1 = extent(a, W, H)
    local bx0, by0, bx1, by1 = extent(b, W, H)
    if not (ax0 and bx0) then return nil end
    if ax0 <= bx1 and bx0 <= ax1 and ay0 <= by1 and by0 <= ay1 then return 0 end
    return nil
end

function Preset.conflicts(zoneName, zone)
    local existing = Config.zones[zoneName]
    if not existing then return nil end

    local report = { zone = zoneName, existing = existing, overlaps = {} }

    local mine = {}
    for i = 1, #(existing.areas or {}) do
        local a = existing.areas[i]
        if a.subzone then mine[a.subzone] = a end
    end

    for i = 1, #(zone.areas or {}) do
        local a = zone.areas[i]
        if a.subzone and mine[a.subzone] then
            report.overlaps[#report.overlaps + 1] = {
                kind = "subzone", name = a.subzone,
                mineC = mine[a.subzone].contrast, mineB = mine[a.subzone].brightness,
                mineG = mine[a.subzone].gamma,
                theirsC = a.contrast, theirsB = a.brightness, theirsG = a.gamma,
            }
        end
    end

    -- Positional overlap, in yards. Only meaningful when both sides agree on the
    -- map, which is the same condition the engine puts on applying them at all -
    -- and only checkable when that map's scale can be read. When it cannot, the
    -- report says so rather than skipping silently.
    local function isPlaced(a) return a.x ~= nil or a.corners ~= nil end
    if zone.map and existing.map and zone.map == existing.map then
        local theirs, ours = {}, {}
        for i = 1, #(zone.areas or {}) do
            if isPlaced(zone.areas[i]) then theirs[#theirs + 1] = zone.areas[i] end
        end
        for i = 1, #(existing.areas or {}) do
            if isPlaced(existing.areas[i]) then ours[#ours + 1] = existing.areas[i] end
        end
        if #theirs > 0 and #ours > 0 then
            local W, H = worldSize(zone.map)
            if not W then
                report.overlaps[#report.overlaps + 1] = {
                    kind = "unchecked",
                    reason = "positional overlap not checked - map scale unavailable",
                }
            else
                for i = 1, #theirs do
                    for j = 1, #ours do
                        local d = positionalOverlap(theirs[i], ours[j], W, H)
                        if d then
                            report.overlaps[#report.overlaps + 1] = {
                                kind = "position",
                                name = theirs[i].name or "area",
                                against = ours[j].name or "area",
                                distance = d,
                            }
                        end
                    end
                end
            end
        end
    end

    return report
end
