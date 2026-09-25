-- Dynamic Ambiance - settings and instance auto-toggles ---------------------------
--
-- `/amb settings`              what every toggle is set to, and why
-- `/amb set <key> on|off`      flip one, saved for this character
-- `/amb settings reset`        every toggle back to Config.lua's values
--
-- Config.settings is the DEFAULTS (DESIGN-ui.md 3.6). A character's own values
-- are saved in its store (Store.lua) and copied into these same tables at
-- ADDON_LOADED, key by key - the tables themselves are never replaced, because
-- `settings` below and every defineKey hold them by reference.
--
-- Two things live here, because they are the same thing seen from two ends: the
-- table of toggles, and the one consumer of it that has to watch the world -
-- instance detection.
--
-- WHAT A SUSPENSION IS. Not `/amb off`, which stops the loop, and not a mode the
-- user chose. `state.suspendedBy` is set to the name of whichever rule claimed the
-- player, `refreshTarget` reads it and aims at the baseline while it is set, and
-- the ordinary ease carries the screen there and back. The loop keeps running
-- throughout, which is what makes both edges smooth and what makes leaving an
-- instance need no reload.
--
-- Precedence, decided rather than fallen into: `off` beats everything, then an
-- explicit `hold` from `/amb try`, then a suspension, then following the map. A
-- hold outranks a suspension because holding is something a person typed on
-- purpose; suspending is something the addon decided on their behalf, and the
-- addon does not get to overrule them.
--
-- WHAT IS NOT MEASURED HERE, and is not pretended to be: which `instanceType`
-- strings this client actually returns, and whether an epic battleground is
-- distinguishable from an ordinary one. `/amb settings` shows both for wherever
-- the player stands, and an unrecognised type is reported. Everything below degrades to "treat it as an ordinary instance" rather
-- than to a guess, and `/amb settings` says out loud which branches are still
-- unconfirmed.

local ADDON, ns = ...
if not (ns and ns.COMMANDS and ns.Config) then return end

local Config = ns.Config
local out, warn, plain, register = ns.out, ns.warn, ns.plain, ns.register
local state = ns.state
local format = string.format

-- Config.settings is new. An addon updated over a config the user wrote before it
-- existed should not explode, and should not silently behave as though every
-- toggle were off either - so the defaults are restated here and merged under
-- whatever the file provides.
local DEFAULTS = {
    instances = {
        all = false, dungeon = true, raid = true,
        battleground = true, epicBattleground = true,
    },
    sharing = { accept = true, preview = true, ignorePlayers = {} },
}

local function fillDefaults(into, from)
    for k, v in pairs(from) do
        if type(v) == "table" then
            if type(into[k]) ~= "table" then into[k] = {} end
            fillDefaults(into[k], v)
        elseif into[k] == nil then
            into[k] = v
        end
    end
end

Config.settings = Config.settings or {}
fillDefaults(Config.settings, DEFAULTS)

local settings = Config.settings

-- Keys ---------------------------------------------------------------------------
--
-- A flat namespace for `/amb set`, because "instances.epicBattleground" is a thing
-- to mistype and "epicbg" is a thing to remember. Each entry knows where it really
-- lives, what it means, and what to do after it changes - a toggle that needs a
-- /reload to take effect is not a toggle.

local KEYS = {}
local ORDER = {}

local function defineKey(name, tbl, field, aliases, describe, onChange)
    local entry = {
        name = name, tbl = tbl, field = field,
        describe = describe, onChange = onChange,
        -- Which part of the store it is saved under.
        section = (tbl == settings.instances and "instances")
            or (tbl == settings.sharing and "sharing") or nil,
    }
    KEYS[name] = entry
    ORDER[#ORDER + 1] = entry
    for i = 1, #(aliases or {}) do KEYS[aliases[i]] = entry end
    return entry
end

-- Instances ------------------------------------------------------------------------

-- What the client calls each kind, mapped to what the settings call it.
--
-- These strings are retail's and TBC's, and are NOT confirmed on this client. An
-- instanceType that matches none of them is recorded and treated as unrecognised,
-- which the master toggle covers and the four specific ones do not. That is the
-- degradation: an unknown instance behaves like the open world unless the player
-- has asked for every instance to be suspended.
local TYPE_TO_KEY = {
    party = "dungeon",
    raid  = "raid",
    pvp   = "battleground",
}

local unknownTypes = {}

-- Returns the settings key for where the player is, plus the raw client facts, or
-- nil if they are not in an instance at all.
local function classify()
    if not IsInInstance then return nil end
    local ok, inside = pcall(IsInInstance)
    if not ok or not inside then return nil end

    local info = { instanceType = nil, maxPlayers = nil, name = nil }
    if GetInstanceInfo then
        local ok2, a, b, _, _, e = pcall(GetInstanceInfo)
        if ok2 then
            info.name         = plain(a)
            info.instanceType = plain(b)
            info.maxPlayers   = tonumber(plain(e))
        end
    end

    local key = info.instanceType and TYPE_TO_KEY[info.instanceType] or nil

    -- The epic split. Only attempted when a threshold has been supplied, and the
    -- threshold is nil until somebody measures two battleground sizes on this
    -- client. Without it every battleground is an ordinary battleground, which is
    -- the safe direction to be wrong in: the setting that fires is the one the
    -- player is more likely to have thought about.
    if key == "battleground" then
        local threshold = tonumber(settings.epicBattlegroundMinPlayers)
        if threshold and info.maxPlayers and info.maxPlayers >= threshold then
            key = "epicBattleground"
        end
    end

    if not key and info.instanceType then unknownTypes[info.instanceType] = true end
    info.key = key
    return key, info
end

ns.classifyInstance = classify

-- Does the current place call for a suspension, and under which rule. Returns the
-- label to show the player, or nil.
local function suspensionFor()
    local key, info = classify()
    if not info then return nil end          -- not in an instance

    if settings.instances.all then
        return "all instances", info
    end
    if key and settings.instances[key] then
        return key, info
    end
    return nil, info
end

local function applySuspension(quiet)
    local label, info = suspensionFor()
    local was = state.suspendedBy
    state.suspendedBy = label
    state.instanceInfo = info

    if was == label then return end

    if label then
        if not quiet then
            out(format("suspended in %s - easing back to baseline (c=%d b=%d). "
                .. "|cffffff00/amb set %s off|r to keep running in here.",
                info and info.name or "this instance",
                Config.baseline.contrast, Config.baseline.brightness,
                (label == "all instances") and "allinstances" or label))
        end
    elseif was then
        if not quiet then out("no longer suspended - following the map again.") end
    end

    if ns.refreshTarget then ns.refreshTarget(true) end
end

ns.applySuspension = applySuspension

-- The world moves under this in two ways: the player zones, or the player changes
-- a setting while standing still. Both re-run the same check.
local watch = CreateFrame("Frame", "DynamicAmbianceSettingsWatch")
watch:SetScript("OnEvent", function()
    local ok, err = pcall(applySuspension, false)
    if not ok then warn("instance check failed: " .. (plain(err) or "?")) end
end)
register(watch, "PLAYER_ENTERING_WORLD")
register(watch, "ZONE_CHANGED_NEW_AREA")

ns.settingsWatch = watch

-- Key table ------------------------------------------------------------------------

local function reapply() applySuspension(false) end

defineKey("allinstances", settings.instances, "all", { "all", "instances" },
    "suspend in every instance, recognised or not", reapply)
defineKey("dungeon", settings.instances, "dungeon", { "dungeons", "party" },
    "suspend in dungeons", reapply)
defineKey("raid", settings.instances, "raid", { "raids" },
    "suspend in raids", reapply)
defineKey("battleground", settings.instances, "battleground", { "bg", "battlegrounds" },
    "suspend in battlegrounds", reapply)
defineKey("epicbattleground", settings.instances, "epicBattleground",
    { "epicbg", "epic", "epicbgs" },
    "suspend in epic battlegrounds", reapply)
defineKey("accept", settings.sharing, "accept", { "sharing", "requests" },
    "let an incoming preset raise a confirmation at all")
defineKey("preview", settings.sharing, "preview", { "livepreview" },
    "apply a sender's values live while the confirmation is open")

-- Listing --------------------------------------------------------------------------

-- The one thing this listing must do that a plain dump would not: say which
-- branches cannot currently fire, and why. A toggle that reads `on` while being
-- structurally unable to do anything is worse than no toggle at all.
local function caveatFor(entry)
    if entry.field == "epicBattleground" then
        if not tonumber(settings.epicBattlegroundMinPlayers) then
            if settings.instances.battleground == settings.instances.epicBattleground then
                return "|cff888888(cannot fire yet - no measured size threshold; harmless, "
                    .. "it matches `battleground`)|r"
            end
            return "|cffffaa00(CANNOT FIRE - no measured size threshold, so every "
                .. "battleground uses `battleground` instead. /amb settings in a battleground "
                .. "shows its maxPlayers)|r"
        end
        return format("|cff888888(>= %d players)|r",
            tonumber(settings.epicBattlegroundMinPlayers))
    end
    if entry.field == "all" and settings.instances.all then
        return "|cffffaa00(overriding the four below)|r"
    end
    return nil
end

local function listSettings()
    out("|cffffff00settings|r  - |cffffff00/amb set <key> on|off|r")
    for i = 1, #ORDER do
        local e = ORDER[i]
        local v = e.tbl[e.field]
        local caveat = caveatFor(e)
        out(format("  %-17s %s  |cff888888%s|r%s",
            e.name,
            v and "|cff44ff44on |r" or "|cffff4444off|r",
            e.describe,
            caveat and ("  " .. caveat) or ""))
    end

    local label, info = suspensionFor()
    if info then
        out(format("  |cff888888here: %s, instanceType=%s, maxPlayers=%s -> %s|r",
            tostring(info.name), tostring(info.instanceType), tostring(info.maxPlayers),
            label and ("|cffffaa00suspended by " .. label .. "|r") or "not suspended"))
    else
        out("  |cff888888here: not in an instance|r")
    end

    local unknown = {}
    for t in pairs(unknownTypes) do unknown[#unknown + 1] = t end
    if #unknown > 0 then
        table.sort(unknown)
        warn("instanceType(s) seen that none of these cover: " .. table.concat(unknown, ", ")
            .. " - only `allinstances` catches those. Worth recording.")
    end

    local n = 0
    for _ in pairs(settings.sharing.ignorePlayers) do n = n + 1 end
    if n > 0 then out(format("  |cff888888%d player(s) ignored - /amb ignore list|r", n)) end

    out("|cff888888" .. ns.settingsSavedLine() .. "|r")
end

-- The closing line: what happens to a change, on the branch this build is on.
function ns.settingsSavedLine()
    local Store = ns.Store
    if Store and Store.regressed() then
        return "Saving is not yet verified on this build - a change may last only until "
            .. "/reload. Config.settings holds the defaults."
    end
    return "Saved for this character; Config.settings holds the defaults "
        .. "(/amb settings reset)."
end

-- Commands -------------------------------------------------------------------------

local function parseBool(word)
    word = (word or ""):lower()
    if word == "on" or word == "true" or word == "yes" or word == "1" then return true end
    if word == "off" or word == "false" or word == "no" or word == "0" then return false end
    return nil
end

ns.COMMANDS.settings = function(rest)
    if (rest or ""):lower():match("^%s*reset") then
        if not ns.Store then return warn("the store did not load - nothing to reset.") end
        ns.Store.resetSettings()
        pcall(applySuspension, true)
        out("every setting is back to Config.settings, for this character.")
        return listSettings()
    end
    return listSettings()
end

ns.COMMANDS.set = function(rest)
    local key, value = (rest or ""):match("^(%S+)%s*(%S*)")
    if not key then
        warn("usage: /amb set <key> on|off")
        return listSettings()
    end

    local entry = KEYS[key:lower()]
    if not entry then
        warn("unknown setting: " .. key)
        return listSettings()
    end

    local want = parseBool(value)
    if want == nil then
        -- No value given is a toggle, which is what people type when they are
        -- flipping something they just read off the listing.
        want = not entry.tbl[entry.field]
    end

    entry.tbl[entry.field] = want
    -- Written to the store as well as the live table (DESIGN-ui.md 3.6).
    if ns.Store and entry.section then ns.Store.saveSetting(entry.section, entry.field, want) end
    out(format("%s is now %s.", entry.name,
        want and "|cff44ff44on|r" or "|cffff4444off|r"))

    local caveat = caveatFor(entry)
    if caveat then out("  " .. caveat) end

    if entry.onChange then
        local ok, err = pcall(entry.onChange)
        if not ok then warn("applying it failed: " .. (plain(err) or "?")) end
    end

    out("|cff888888" .. ns.settingsSavedLine() .. "|r")
end

ns.settingsKeys = KEYS
ns.listSettings = listSettings
