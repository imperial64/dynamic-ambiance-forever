-- Dynamic Ambiance - the saved store, and which persistence branch is live -----------
--
-- design/ui/DESIGN-ui.md 0.1, 1.2, 1.4, 1.5 and 3.6. Build 1.60.1.70009 reads
-- SavedVariables back, account-wide and per character, across /reload and across
-- a full restart (design/ui/measurements-2026-09-25.md; the plugin repo's
-- research/findings.md P.30). So a character's zones and settings live here, in
-- DynamicAmbianceCharDB.store, and every edit is saved in place. The client writes
-- the file at /reload and at logout and nowhere else; nothing here can make it
-- write sooner.
--
-- That has an expiry. Blizzard has not announced the fix, and the two builds
-- before 70009 behaved differently from each other, so the branch is measured at
-- every login rather than assumed (0.1): `restart` and `reload` are the normal
-- branch (reload counts as normal by the user's decision FQ2, with a one-line
-- caveat in the editor's footer), and `unverified` - which is also what a build
-- that never reads saved settings back looks like - is the regressed one.
--
-- LOAD ORDER (P.31). No `## LoadSavedVariablesFirst`: every saved global is nil
-- while the addon's files run, and at ADDON_LOADED the client replaces it with
-- the restored table. So nothing here touches a saved global at file scope, no
-- file-scope local points at one, and every function reads the global when it
-- runs. Saved values are copied INTO the tables other files already hold
-- (Config.settings and its sub-tables are captured by reference in Settings.lua
-- and Share.lua), never swapped for new ones.
--
-- Order of loading, at ADDON_LOADED for this addon: read the markers that came
-- back; bind both DBs; seed the store from Zones.lua if it has never been seeded,
-- otherwise load the store into Config.zones; overlay the saved settings; stamp
-- the markers. All of this precedes PLAYER_LOGIN, where the engine first resolves
-- a zone. At the first PLAYER_ENTERING_WORLD: judge the branch, and on a regressed
-- one let a changed Zones.lua replace the store (FQ1).

local ADDON, ns = ...
if not (ns and ns.Config and ns.Preset and ns.Serialize) then return end

local Config, Preset, Serialize = ns.Config, ns.Preset, ns.Serialize
local out, warn, plain = ns.out, ns.warn, ns.plain
local format, floor = string.format, math.floor

local Store = {}
ns.Store = Store

-- Bumped when the shape of DynamicAmbianceCharDB.store changes (DESIGN-ui.md 1.4).
Store.SCHEMA = 1

-- The judged branch. Nothing is proven before the first PLAYER_ENTERING_WORLD, so
-- until then the state is `unverified`.
ns.persistence = { state = "unverified" }

-- What came back at ADDON_LOADED, for `/amb status` (the load count it reports).
local load = { captured = false }
ns.persistenceLoad = load

local RANK = { unverified = 0, reload = 1, restart = 2 }
Store.RANK = RANK

-- Access -------------------------------------------------------------------------------
--
-- The globals are read every time: a table taken once would be the orphan P.31
-- describes if anything ever swapped the global.

local function accountDB()
    if type(DynamicAmbianceDB) ~= "table" then DynamicAmbianceDB = {} end
    return DynamicAmbianceDB
end

local function charDB()
    if type(DynamicAmbianceCharDB) ~= "table" then DynamicAmbianceCharDB = {} end
    return DynamicAmbianceCharDB
end

Store.accountDB, Store.charDB = accountDB, charDB

-- The character's store, with every part it must have. A store with a lower or
-- missing schema is read as it is (no upgrade exists yet) and written back at
-- the current one.
function Store.data()
    local char = charDB()
    local s = char.store
    if type(s) ~= "table" then s = {}; char.store = s end
    if type(s.zones) ~= "table" then s.zones = {} end
    if type(s.revert) ~= "table" then s.revert = {} end
    if type(s.settings) ~= "table" then s.settings = {} end
    s.schema = Store.SCHEMA
    return s
end

local function stamp()
    if type(date) ~= "function" then return nil end
    local ok, s = pcall(date, "%Y-%m-%d %H:%M:%S")
    if ok and type(s) == "string" then return s end
    return nil
end

-- The client build, as "1.60.1.70009", or nil when it cannot be read.
function Store.buildString()
    if type(GetBuildInfo) ~= "function" then return nil end
    local ok, version, build = pcall(GetBuildInfo)
    if not ok then return nil end
    version, build = plain(version), plain(build)
    if not build or build == "" then return nil end
    if version and version ~= "" then return version .. "." .. build end
    return build
end

-- The branch ---------------------------------------------------------------------------

-- `/amb persistence force <state>`: a session-only override for the acceptance
-- run (DESIGN-ui.md 9.4 step 16). Never saved, never judged on.
Store.forced = nil

function Store.state()
    return Store.forced or ns.persistence.state or "unverified"
end

-- Only `unverified` is regressed (User decision FQ2).
function Store.regressed()
    return Store.state() == "unverified"
end

-- DESIGN-ui.md 0.1's table, first match wins. `marker` is what came back at
-- ADDON_LOADED (nil when nothing did), `loadKind` is "login", "reload" or nil,
-- `build` this client's build or nil. Returns the state and the rule's number.
function Store.judge(marker, loadKind, build)
    if type(marker) ~= "table" then return "unverified", 1 end
    if loadKind == "login" then return "restart", 2 end
    local mb = marker.build
    if type(mb) == "number" then mb = tostring(mb) end
    if type(mb) == "string" and type(build) == "string" and mb ~= build then
        return "restart", 3
    end
    -- Across /reload, or a load of unknown kind: the best state already proven on
    -- this build is kept, so on a restart-verified build every /reload stays
    -- `restart`. A marker from before `best` existed counts as unverified.
    if marker.best == "restart" then return "restart", 4 end
    return "reload", 4
end

-- The one chat line for a change that is kept, on the branch this is.
function Store.savedLine()
    if Store.regressed() then
        return "saving is not yet verified on this build - this may be lost at /reload (/amb status)."
    end
    return "saved for this character."
end

-- The login line, on the regressed branch only (DESIGN-ui.md 0.1).
Store.LOGIN_LINE = "saving is not yet verified on this build - if the editor's footer still says so "
    .. "after a /reload, this build is not keeping saved settings. |cffffff00/amb ui save|r keeps "
    .. "your zones by copy and paste."

-- Zones ----------------------------------------------------------------------------------

-- Fletcher-16 over the DA2 strings of `zones`, sorted by name (DESIGN-ui.md 1.2).
-- A zone too big for a DA2 string is counted by its generated Zones.lua text, so
-- it still moves the sum when it changes.
function Store.checksum(zones)
    local names = {}
    for name, z in pairs(zones or {}) do
        if type(name) == "string" and type(z) == "table" then names[#names + 1] = name end
    end
    table.sort(names)
    local parts = {}
    for i = 1, #names do
        local name, z = names[i], zones[names[i]]
        local ok, s = pcall(Preset.serialize, name, z)
        if not (ok and type(s) == "string") then
            local okF, text = pcall(Serialize.zonesFile, { [name] = z }, "-", "-")
            s = okF and text or ("?" .. name)
        end
        parts[#parts + 1] = s
    end
    return Preset.checksum(table.concat(parts, "\n"))
end

local function seedRecord()
    return { when = stamp(), checksum = Store.fileChecksum, from = "Zones.lua" }
end

-- Replace every entry of the live Config.zones with `zones` (clean copies), in
-- place: other code holds the Config.zones table itself.
local function replaceLive(zones)
    local live = Config.zones
    for name in pairs(live) do live[name] = nil end
    for name, c in pairs(zones) do live[name] = Serialize.liveZone(c) end
end

-- First login for this character: every zone the file defined goes into the
-- store, clean, with origin "seed". Config.zones is left as it was, apart from
-- the origin it now carries.
function Store.seed()
    local s = Store.data()
    Serialize.markOrigin(Config.zones, "seed")
    s.zones = {}
    for name, z in pairs(Config.zones) do
        if type(name) == "string" and type(z) == "table" then s.zones[name] = Serialize.cleanZone(z) end
    end
    s.seed = seedRecord()
    return s
end

-- Every later login: the store is the zones. A file zone the store does not have
-- is gone (the store is the authority on the normal branch); every other entry
-- is a fresh copy of the store's, so the engine's layer caches start again.
function Store.load()
    local s = Store.data()
    replaceLive(s.zones)
    return s
end

-- A regressed branch (FQ1): Zones.lua is the authority again, at every load. A
-- store that did not come back was seeded from the file already, so only a file
-- that differs from the one the store was seeded from replaces it.
function Store.reseedIfChanged()
    local s = Store.data()
    if type(s.seed) == "table" and s.seed.checksum == Store.fileChecksum then return false end
    s.zones = {}
    for name, c in pairs(Store.fileZones or {}) do
        local z = Serialize.liveZone(c)
        z.origin = nil
        Serialize.markOrigin({ z }, "seed")
        s.zones[name] = Serialize.cleanZone(z)
    end
    replaceLive(s.zones)
    s.seed = seedRecord()
    if ns.refreshTarget then pcall(ns.refreshTarget, true) end
    return true
end

-- One zone, live -> store: its clean copy, or its removal (with its revert point)
-- when it is no longer in Config.zones.
function Store.flushZone(name)
    if type(name) ~= "string" then return end
    local s = Store.data()
    local z = Config.zones[name]
    if type(z) == "table" then
        s.zones[name] = Serialize.cleanZone(z)
    else
        s.zones[name] = nil
        s.revert[name] = nil
    end
end

-- The last exported string of a zone (DESIGN-ui.md 6.10).
function Store.setRevert(name, str, version)
    if type(name) ~= "string" or type(str) ~= "string" then return end
    Store.data().revert[name] = { string = str, when = Serialize.now(), version = version }
end

function Store.getRevert(name)
    local e = Store.data().revert[name]
    return type(e) == "table" and type(e.string) == "string" and e or nil
end

-- Put a revert entry back as it was (undo of a zone's deletion), or remove it.
function Store.putRevert(name, entry)
    if type(name) ~= "string" then return end
    Store.data().revert[name] = type(entry) == "table" and entry or nil
end

-- An export (DESIGN-ui.md 1.3, 8.1): the version bumps if the zone changed since
-- its last export, the string becomes the zone's revert point, it is logged to
-- DynamicAmbianceDB.exports, and the zone's new bookkeeping is saved. Returns the
-- string, or nil and the reason.
function Store.exportZone(name)
    local zone = Config.zones[name]
    if type(zone) ~= "table" then return nil, "no such zone: " .. tostring(name) end
    Serialize.stampExport(name, zone)
    local s, err = Preset.serialize(name, zone)
    if not s then return nil, err end
    Store.setRevert(name, s, zone.meta and zone.meta.version)
    Store.appendRecord("exports", { zone = name, string = s, when = stamp() })
    Store.flushZone(name)
    return s
end

-- Settings (DESIGN-ui.md 3.6) ----------------------------------------------------------------
--
-- Config.settings is the defaults. The saved values are copied into its existing
-- tables key by key, so every reference Settings.lua and Share.lua took at file
-- scope stays the live one. A key the store does not hold keeps the file's value.

Store.SETTINGS = {
    instances = { "all", "dungeon", "raid", "battleground", "epicBattleground" },
    sharing   = { "accept", "preview" },
}

local function copySet(t)
    local c = {}
    for k, v in pairs(t or {}) do if v then c[k] = true end end
    return c
end

local function applySettings(from)
    local live = Config.settings
    if type(live) ~= "table" then return end
    for section, fields in pairs(Store.SETTINGS) do
        local src, dst = from[section], live[section]
        if type(src) == "table" and type(dst) == "table" then
            for i = 1, #fields do
                if type(src[fields[i]]) == "boolean" then dst[fields[i]] = src[fields[i]] end
            end
        end
    end
    local ig = type(from.sharing) == "table" and from.sharing.ignorePlayers
    local liveIg = type(live.sharing) == "table" and live.sharing.ignorePlayers
    if type(ig) == "table" and type(liveIg) == "table" then
        for k in pairs(liveIg) do liveIg[k] = nil end
        for k, v in pairs(ig) do if v then liveIg[k] = true end end
    end
end

-- What Config.lua holds, taken once before the first overlay, for a reset.
local function takeDefaults()
    if Store.defaults then return end
    local live, d = Config.settings or {}, {}
    for section, fields in pairs(Store.SETTINGS) do
        d[section] = {}
        for i = 1, #fields do
            if type(live[section]) == "table" then d[section][fields[i]] = live[section][fields[i]] end
        end
    end
    d.sharing.ignorePlayers = copySet(live.sharing and live.sharing.ignorePlayers)
    Store.defaults = d
end

function Store.overlaySettings()
    takeDefaults()
    applySettings(Store.data().settings)
end

-- One toggle, written to the store (the live table is written by the caller).
function Store.saveSetting(section, field, value)
    local s = Store.data().settings
    if type(s[section]) ~= "table" then s[section] = {} end
    s[section][field] = value
end

-- The ignore list, as it is now, written whole.
function Store.saveIgnoreList()
    local s = Store.data().settings
    if type(s.sharing) ~= "table" then s.sharing = {} end
    local live = Config.settings.sharing
    s.sharing.ignorePlayers = copySet(live and live.ignorePlayers)
end

-- `/amb settings reset`: the store forgets every setting, and the live tables
-- go back to Config.lua's values.
function Store.resetSettings()
    takeDefaults()
    Store.data().settings = {}
    applySettings(Store.defaults)
end

-- Record lists (DESIGN-ui.md 1.5) ------------------------------------------------------

function Store.recordCap()
    local n = Config.limits and Config.limits.recordEntries
    if type(n) == "number" and n >= 1 and n < math.huge then return floor(n) end
    return 20
end

-- Append to DynamicAmbianceDB[key], keeping the most recent entries only.
function Store.appendRecord(key, entry)
    local db = accountDB()
    local list = db[key]
    if type(list) ~= "table" then list = {}; db[key] = list end
    list[#list + 1] = entry
    Store.trim(list)
    return list
end

function Store.trim(list)
    local cap = Store.recordCap()
    local extra = #list - cap
    if extra > 0 then
        for i = 1, #list do list[i] = list[i + extra] end
    end
    return list
end

-- The marker, and the judgement ----------------------------------------------------------

local function readMarker(db)
    if type(db) ~= "table" then return nil end
    local m = db.persistenceMarker
    if type(m) ~= "table" then return nil end
    return m
end

-- Re-stamped on every load, so the NEXT load is the one that answers: a counter
-- that goes up across a restart can only come from a read-back.
local function stampMarker(db, prior, arrivedNil, build)
    db.persistenceMarker = {
        writtenAt  = stamp(),
        loadCount  = ((prior and tonumber(prior.loadCount)) or 0) + 1,
        arrivedNil = arrivedNil,
        build      = build,
    }
    return db.persistenceMarker
end

-- Keys only the removed instruments wrote (User decisions, 2026-09-25: remove
-- the probes completely; remove selftest and ambiancecost). Dropped from both
-- DBs at every load so an old record is not carried forward by the next write.
Store.RETIRED = { "probe", "probeUI", "probeGamma", "probeInstances", "selftest" }

function Store.dropRetired(db)
    if type(db) ~= "table" then return end
    for i = 1, #Store.RETIRED do db[Store.RETIRED[i]] = nil end
end

function Store.onAddonLoaded()
    load.captured      = true
    load.accountWasNil = (DynamicAmbianceDB == nil)
    load.charWasNil    = (DynamicAmbianceCharDB == nil)
    load.accountType   = type(DynamicAmbianceDB)
    load.charType      = type(DynamicAmbianceCharDB)
    load.accountMarker = readMarker(DynamicAmbianceDB)
    load.charMarker    = readMarker(DynamicAmbianceCharDB)
    load.build         = Store.buildString()

    local account, char = accountDB(), charDB()
    Store.dropRetired(account)
    Store.dropRetired(char)

    -- The file's zones as the file left them: the seed, and on a regressed branch
    -- the authority (1.2).
    Store.fileZones = {}
    for name, z in pairs(Config.zones) do
        if type(name) == "string" and type(z) == "table" then Store.fileZones[name] = Serialize.cleanZone(z) end
    end
    Store.fileChecksum = Store.checksum(Config.zones)

    local s = type(char.store) == "table" and char.store or nil
    if s == nil or s.seed == nil then
        Store.seed()
        load.seeded = true
    else
        Store.load()
        load.seeded = false
    end
    Store.overlaySettings()

    load.accountStamped = stampMarker(account, load.accountMarker, load.accountWasNil, load.build)
    load.charStamped    = stampMarker(char, load.charMarker, load.charWasNil, load.build)
end

-- The first PLAYER_ENTERING_WORLD after ADDON_LOADED. The state is judged on the
-- per-character marker, because the store lives in that file: it is the one
-- whose coming back matters.
function Store.onEnteringWorld(isInitialLogin, isReloadingUi)
    if Store.judged or not load.captured then return end
    Store.judged = true
    -- Compared as booleans, not through plain(): plain formats with "%s", and the
    -- client's Lua 5.1 refuses a boolean there, so plain(true) is nil in game and
    -- every load came out of kind nil (in-game check, 2026-09-25: the marker had
    -- no loadKind and best = "reload" after a relaunch). LuaJIT and 5.4, which run
    -- the tests, accept it, which is why the tests did not see it.
    local kind = (isInitialLogin == true and "login") or (isReloadingUi == true and "reload") or nil
    load.loadKind = kind

    local state, rule = Store.judge(load.charMarker, kind, load.build)
    local p = ns.persistence
    p.state, p.build, p.when, p.rule, p.loadKind = state, load.build, stamp(), rule, kind

    for _, m in ipairs({ load.accountStamped, load.charStamped }) do
        if type(m) == "table" then m.loadKind, m.best = kind, state end
    end
    local record = { state = state, build = load.build, when = p.when }
    accountDB().persistence = record
    charDB().persistence = { state = state, build = load.build, when = p.when }

    if state == "unverified" then
        Store.reseedIfChanged()
        out(Store.LOGIN_LINE)
    end
    if ns.onPersistenceChanged then pcall(ns.onPersistenceChanged) end
end

-- `/amb status`'s line.
function Store.statusLine()
    local p = ns.persistence
    local line = format("persistence: %s, judged on build %s", tostring(p.state),
        tostring(p.build or "unknown"))
    if not Store.judged then line = "persistence: not judged yet (no PLAYER_ENTERING_WORLD)" end
    if Store.forced then
        line = line .. format(" |cffff4444- FORCED to %s for this session|r", Store.forced)
    end
    return line
end

-- The acceptance run's override. `state` is restart, reload, unverified or off.
function Store.force(state)
    if state == "off" or state == nil then
        Store.forced = nil
        out("persistence: back to the judged state, " .. tostring(ns.persistence.state) .. ".")
    elseif RANK[state] then
        Store.forced = state
        warn(format("PERSISTENCE FORCED TO %s FOR THIS SESSION - a test override, not a "
            .. "measurement. /amb persistence force off to undo.", state:upper()))
    else
        return warn("usage: /amb persistence force restart | reload | unverified | off")
    end
    if ns.onPersistenceChanged then pcall(ns.onPersistenceChanged) end
end

-- `/amb status`'s persistence report: the judged state, this load's number,
-- whether the previous load's markers came back, and what the editor's Export
-- click recorded about the clipboard on this build.
function Store.report(emit)
    emit = emit or out
    emit("  " .. Store.statusLine())
    if not load.captured then
        emit("  saved settings: ADDON_LOADED never arrived for " .. tostring(ADDON)
            .. " - nothing to judge read-back by.")
    else
        local m = load.charStamped or load.accountStamped
        emit(format("  this load: #%s on build %s; the previous load's marker came back: "
            .. "account %s, character %s.", tostring(m and m.loadCount or "?"),
            tostring(load.build or "unknown"),
            load.accountMarker and "yes" or "no", load.charMarker and "yes" or "no"))
    end
    local E = ns.Editor
    if E and E.clipboardReport then
        local ok, _, _, line = pcall(E.clipboardReport)
        if ok and line then emit("  clipboard: " .. line) end
    end
end

-- `/amb persistence` prints the report; `/amb persistence force <state>` is the
-- test hook above.
if ns.COMMANDS then
    ns.COMMANDS.persistence = function(rest)
        local want = (plain(rest) or ""):lower():match("^%s*force%s*(%S*)")
        if want then return Store.force(want ~= "" and want or "?") end
        Store.report()
    end
end

-- Wiring -----------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "DynamicAmbianceStore")
frame:SetScript("OnEvent", function(self, event, a, b)
    if event == "ADDON_LOADED" then
        if a ~= ADDON then return end
        self:UnregisterEvent("ADDON_LOADED")
        local ok, err = pcall(Store.onAddonLoaded)
        if not ok then warn("loading the saved zones failed: " .. (plain(err) or "?")) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local ok, err = pcall(Store.onEnteringWorld, a, b)
        if not ok then warn("judging persistence failed: " .. (plain(err) or "?")) end
    end
end)
if ns.register then
    ns.register(frame, "ADDON_LOADED")
    ns.register(frame, "PLAYER_ENTERING_WORLD")
end
Store.frame = frame
