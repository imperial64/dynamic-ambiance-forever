-- Dynamic Ambiance - sharing a preset ---------------------------------------------
--
-- `/amb export [zone]`      the string for a zone you have, ready to paste
-- `/amb import <string>`    offer one to yourself, with the same confirmation
-- `/amb ignore <name>`      never raise a confirmation from that player again
-- `/amb ignore all`         no confirmations at all (the saved `sharing.accept`)
-- `/amb ignore list`        who is ignored
-- `/amb unignore <name>`    undo one (`/amb unignore all` turns sharing back on)
--
-- Every one of these is saved for the character (Store.lua, DESIGN-ui.md 3.6),
-- and an accepted preset is saved into the store with its string as the zone's
-- revert point (1.4).
--
-- This is the RECEIVING side and the confirmation, which is the half that has to
-- be right. Preset.lua is the format. The wire - sending to party and raid over
-- addon messaging - is deliberately not here yet: whether this client has that API
-- at all is unmeasured, and has to be measured before the wire is built. Everything below
-- works on a preset that arrived by any route, so the transport plugs in without
-- reopening any of it.
--
-- THE RULE THIS FILE EXISTS TO ENFORCE: nothing a stranger sends is applied
-- without a human saying yes. A click that accepts a preset writes CVars on the
-- receiver's machine, and while the blast radius here is genuinely small - three
-- display sliders, nothing secure, nothing destructive - "small" is not "none",
-- and the receiver is the one who gets to decide.
--
-- LIVE PREVIEW. The sender's values go on the screen while the dialog is open and
-- come back off on decline, on timeout, on escape and at logout. This is the one
-- design choice here worth defending: a contrast number read off a dialog tells
-- you nothing, and trying someone's Duskwood on the spot is most of what the
-- feature is for. It is only safe because of what these CVars are - the same
-- reasoning would be indefensible for a preset that changed anything else.
--
-- It is also honest about when it cannot work: previewing a Duskwood preset while
-- standing in Elwynn shows nothing, because the zone it describes is not the zone
-- the player is in. That says so rather than leaving them staring at an unchanged
-- screen wondering whether the addon is broken.

local ADDON, ns = ...
if not (ns and ns.COMMANDS and ns.Config and ns.Preset) then return end

local Config, Preset = ns.Config, ns.Preset
local out, warn, plain = ns.out, ns.warn, ns.plain
local format = string.format

local settings = Config.settings
local POPUP = "DYNAMICAMBIANCE_IMPORT"

-- Session state: only the offer being confirmed. Everything a player chooses -
-- the ignore list, "ignore all" - is a saved setting instead (Store.lua).
local session = {
    offer     = nil,      -- the one preset currently being confirmed
}

-- Saves what the ignore commands changed; says what happened to it.
local function saveSharing(field)
    local Store = ns.Store
    if not Store then return end
    if field then Store.saveSetting("sharing", field, settings.sharing[field]) end
    Store.saveIgnoreList()
end

local function keptLine()
    return ns.Store and ns.Store.savedLine() or "saved for this character."
end

ns.shareSession = session

-- Ignoring ---------------------------------------------------------------------------

local function isIgnored(sender)
    if not settings.sharing.accept then
        return true, "sharing is off (/amb unignore all, or /amb set accept on)"
    end
    if sender and settings.sharing.ignorePlayers[sender] then
        return true, format("%s is ignored", sender)
    end
    return false
end

ns.isIgnored = isIgnored

-- Preview ------------------------------------------------------------------------------

-- Swapping the zone table under the engine is the whole mechanism: `refreshTarget`
-- re-resolves the zone by name, the layer cache hangs off the table it is given,
-- and the ordinary ease carries the screen from wherever it was to whatever the
-- preset says. Nothing here writes a CVar directly.
local function startPreview(offer)
    if offer.previewing then return end
    if not settings.sharing.preview then return end

    offer.saved = Config.zones[offer.zoneName]
    offer.savedWasSet = Config.zones[offer.zoneName] ~= nil
    Config.zones[offer.zoneName] = offer.zone
    offer.previewing = true

    if ns.refreshTarget then ns.refreshTarget(true) end

    if ns.state.zoneName ~= offer.zoneName then
        out(format("|cff888888(preview is live, but you are in %s and this preset is for "
            .. "%s - you will not see it until you are there)|r",
            tostring(ns.state.zoneName), offer.zoneName))
    end
end

local function endPreview(offer, keep)
    if not offer or not offer.previewing then return end
    offer.previewing = false
    if keep then return end                       -- accepted: the swap stays

    if offer.savedWasSet then
        Config.zones[offer.zoneName] = offer.saved
    else
        Config.zones[offer.zoneName] = nil
    end
    if ns.refreshTarget then ns.refreshTarget(true) end
end

-- The offer ------------------------------------------------------------------------------

local function closeOffer(keep)
    local offer = session.offer
    if not offer then return end
    session.offer = nil
    endPreview(offer, keep)
    if StaticPopup_Hide then pcall(StaticPopup_Hide, POPUP) end
    -- The editor locks while an offer is open and puts itself back here.
    if ns.onOfferClosed then pcall(ns.onOfferClosed, keep, offer.zoneName) end
end

ns.closeOffer = closeOffer

local function accept()
    local offer = session.offer
    if not offer then return end

    -- The preview already installed it. Accepting is therefore mostly a matter of
    -- NOT putting it back - which is also why accepting with preview off has to do
    -- the install itself.
    if not offer.previewing then
        Config.zones[offer.zoneName] = offer.zone
        if ns.refreshTarget then ns.refreshTarget(true) end
    end
    closeOffer(true)

    -- Where it came from (DESIGN-ui.md 6.8). Not changed since the sender
    -- exported it, so its version is theirs until it is edited here; on a
    -- regressed build it is also unsaved to file.
    local zone = offer.zone
    zone.origin = "import"
    zone.export = { pending = false, manual = false, once = false }
    if ns.Store and ns.Store.regressed() then zone.__dirty = true end
    for i = 1, #(zone.areas or {}) do zone.areas[i].origin = "import" end

    -- Saved in place, and the accepted string is the zone's revert point: the last
    -- string it matched (DESIGN-ui.md 1.4).
    if ns.Store then
        ns.Store.flushZone(offer.zoneName)
        if offer.raw then
            ns.Store.setRevert(offer.zoneName, offer.raw, zone.meta and zone.meta.version)
        end
    end
    if ns.onZoneChanged then pcall(ns.onZoneChanged, offer.zoneName, "import") end

    out(format("imported |cffffff00%s|r%s - %s", offer.zoneName,
        offer.sender and (" from " .. offer.sender) or "", keptLine()))
    if ns.Store and ns.Store.regressed() then
        warn("Use Save to file (|cffffff00/amb ui save|r) to keep it.")
    end

    -- Logged so accepted presets can be lifted out of the file rather than
    -- retyped out of the chat log, the same way `/amb here` captures are. The
    -- most recent Config.limits.recordEntries are kept (DESIGN-ui.md 1.5).
    local entry = {
        zone   = offer.zoneName,
        sender = offer.sender,
        string = offer.raw,
        when   = (date and date("%Y-%m-%d %H:%M:%S")) or nil,
    }
    if ns.Store then
        ns.Store.appendRecord("imported", entry)
    else
        if type(DynamicAmbianceDB) ~= "table" then DynamicAmbianceDB = {} end
        DynamicAmbianceDB.imported = DynamicAmbianceDB.imported or {}
        DynamicAmbianceDB.imported[#DynamicAmbianceDB.imported + 1] = entry
    end
end

local function decline()
    local offer = session.offer
    closeOffer(false)
    if offer then out("declined - screen put back.") end
end

local function ignoreSender()
    local offer = session.offer
    local sender = offer and offer.sender
    closeOffer(false)
    if sender then
        settings.sharing.ignorePlayers[sender] = true
        saveSharing(nil)
        out(format("declined, and %s will not raise one of these again - %s", sender,
            keptLine()))
    else
        out("declined.")
    end
end

if type(StaticPopupDialogs) == "table" then
    StaticPopupDialogs[POPUP] = {
        text         = "%s",
        -- Button order is NOT cosmetic. StaticPopup wires button1 to OnAccept,
        -- button2 to OnCancel and button3 to OnAlt, so labelling button2 as the
        -- ignore would fire `decline` when someone clicked it and `ignoreSender`
        -- when they clicked Decline - a mix-up that silently adds people to an
        -- ignore list they never asked to add them to.
        --
        -- Decline is also the middle button on purpose: it is the answer someone
        -- gives most often and the one nobody should have to aim for.
        button1      = "Import",
        button2      = "Decline",
        button3      = "Never from them",
        OnAccept     = function() pcall(accept) end,
        OnCancel     = function() pcall(decline) end,
        OnAlt        = function() pcall(ignoreSender) end,
        OnHide       = function() pcall(closeOffer, false) end,
        timeout      = 60,
        whileDead    = true,
        hideOnEscape = true,
        showAlert    = true,
    }
end

-- Offer a preset to the player. `sender` is nil when they imported it themselves,
-- which still confirms - seeing what a string will do before it does it is the
-- point - but is never subject to the ignore rules.
function ns.offerPreset(zoneName, zone, sender, raw)
    if sender then
        local ignored, why = isIgnored(sender)
        if ignored then
            out(format("|cff888888ignored a preset from %s: %s|r", sender, why))
            return false, why
        end
    end

    if session.offer then
        -- One at a time. A queue would let anyone in a forty-player raid stack up
        -- dialogs on someone who has not answered the first.
        out(format("|cff888888%s sent a preset, but %s's is still open - answer that "
            .. "first.|r", tostring(sender or "you"), tostring(session.offer.sender or "yours")))
        return false, "one already open"
    end

    local ok, problems = Preset.validate(zoneName, zone)
    if not ok then
        warn(format("refused a preset%s:", sender and (" from " .. sender) or ""))
        for i = 1, #problems do out("  " .. problems[i]) end
        return false, "invalid"
    end

    local offer = { zoneName = zoneName, zone = zone, sender = sender, raw = raw }
    session.offer = offer
    if ns.onOfferOpened then pcall(ns.onOfferOpened, zoneName) end

    -- What it will do, in the chat log, always - the dialog is small and the
    -- values are the thing worth reading.
    out(format("|cffffff00preset offered%s|r", sender and (" by " .. sender) or ""))
    local lines = Preset.describe(zoneName, zone)
    for i = 1, #lines do out("  " .. lines[i]) end
    -- The format is not named (design/ui/feedback-2.md item 6).
    if zone.__convertedFrom then
        out("  |cffffaa00radii converted from an older format - check them.|r")
    end

    local conflict = Preset.conflicts(zoneName, zone)
    if conflict then
        local counted = 0
        for i = 1, #conflict.overlaps do
            if conflict.overlaps[i].kind ~= "unchecked" then counted = counted + 1 end
        end
        warn(format("you already have a %s.%s", zoneName,
            counted > 0 and format(" %d of its areas overlap yours:", counted) or ""))
        for i = 1, #conflict.overlaps do
            local o = conflict.overlaps[i]
            if o.kind == "subzone" then
                out(format("    subzone \"%s\": yours c=%s b=%s g=%s, theirs c=%s b=%s g=%s",
                    o.name, tostring(o.mineC), tostring(o.mineB), tostring(o.mineG),
                    tostring(o.theirsC), tostring(o.theirsB), tostring(o.theirsG)))
            elseif o.kind == "unchecked" then
                out("    " .. o.reason)
            else
                out(format("    %s overlaps your %s", o.name, o.against))
            end
        end
        warn("importing REPLACES your whole " .. zoneName .. ", areas and all.")
    end

    startPreview(offer)

    local text = format("%s%s\n\nzone default c=%s b=%s g=%s, %d area(s).%s%s%s",
        sender and (sender .. " sent you a preset:\n") or "Import this preset?\n",
        zoneName,
        tostring(zone.contrast or "-"), tostring(zone.brightness or "-"),
        tostring(zone.gamma or "-"),
        #(zone.areas or {}),
        zone.__convertedFrom and "\n|cffffaa00Radii converted from an older format.|r" or "",
        conflict and "\n\n|cffffaa00This REPLACES the " .. zoneName
            .. " you already have.|r" or "",
        offer.previewing and "\n\n|cff888888Previewing now - declining puts it back.|r" or "")

    if StaticPopup_Show and type(StaticPopupDialogs) == "table" then
        local shown = pcall(StaticPopup_Show, POPUP, text)
        if not shown then
            warn("could not raise the confirmation dialog - "
                .. "use /amb import accept or /amb import decline.")
        end
    else
        warn("no dialog on this client - /amb import accept or /amb import decline.")
    end

    return true
end

-- A dialog left open at logout would otherwise leave a stranger's values on the
-- screen permanently: the CVars this addon writes are the ones the client
-- persists. The engine already restores the baseline on the way out; this makes
-- sure the zone table it restores from is the player's own.
local exitWatch = CreateFrame("Frame", "DynamicAmbianceShareExit")
exitWatch:SetScript("OnEvent", function() pcall(closeOffer, false) end)
if ns.register then ns.register(exitWatch, "PLAYER_LOGOUT") end

-- The chat link ----------------------------------------------------------------------
--
-- Clicking a preset link offers it. The payload does not ride in the link, so
-- until the wire exists this resolves only against presets this session has
-- already seen - which is exactly what a link is for once the wire lands, and is
-- honest about it until then.

local offered = {}
ns.offeredPresets = offered

function ns.registerLinkPayload(id, zoneName, zone, sender, raw)
    offered[id] = { zoneName = zoneName, zone = zone, sender = sender, raw = raw }
    return id
end

local function onLinkClicked(id)
    local p = offered[id]
    if not p then
        warn("that preset is not in this session - ask them to send it again.")
        return
    end
    ns.offerPreset(p.zoneName, p.zone, p.sender, p.raw)
end

ns.onPresetLinkClicked = onLinkClicked

do
    local orig = _G.SetItemRef
    if orig then
        pcall(function()
            _G.SetItemRef = function(link, text, button, chatFrame)
                local id = Preset.linkID(plain(link) or "")
                if id then
                    return onLinkClicked(id)
                end
                return orig(link, text, button, chatFrame)
            end
        end)
    end
end

-- Commands ---------------------------------------------------------------------------

-- The preset in whatever was pasted: from the first DA<n>~ marker to the end.
function ns.presetBody(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return text:match("(DA%d+~.*)$") or text
end

ns.COMMANDS.export = function(rest)
    local zoneName = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if zoneName == "" then zoneName = ns.state.zoneName end
    if not zoneName then
        warn("usage: /amb export <zone>   (or stand in one)")
        return
    end

    local zone = Config.zones[zoneName]
    if not zone then
        warn(format("no config for %q - /amb config lists what you have.", zoneName))
        return
    end

    -- An export (DESIGN-ui.md 1.3, 8.1): the version goes up by one if the zone
    -- changed since its last export, the string becomes its revert point, and it
    -- is logged to DynamicAmbianceDB.exports.
    local s, err
    if ns.Store then
        s, err = ns.Store.exportZone(zoneName)
    else
        if ns.Serialize then ns.Serialize.stampExport(zoneName, zone) end
        s, err = Preset.serialize(zoneName, zone)
    end
    if not s then
        warn("could not export: " .. tostring(err))
        return
    end

    local ok, problems = Preset.validate(zoneName, zone)
    if not ok then
        warn("exporting anyway, but your own config has problems a receiver will see:")
        for i = 1, #problems do out("  " .. problems[i]) end
    end

    out(format("|cffffff00%s|r - %d bytes, copy the line below:", zoneName, #s))
    out(s)
    out("|cff888888Too long for the chat box to copy? |cffffff00/amb ui export|r has it in a box.|r")
end

ns.COMMANDS.import = function(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")

    -- The escape hatch for a client with no StaticPopup, and the way a test drives
    -- the flow without a dialog.
    if rest:lower() == "accept" then
        if not session.offer then warn("nothing to accept.") ; return end
        return accept()
    end
    if rest:lower() == "decline" then
        if not session.offer then warn("nothing to decline.") ; return end
        return decline()
    end

    if rest == "" then
        warn("usage: /amb import <string>   - paste what /amb export printed")
        return
    end

    -- What actually gets pasted is rarely just the string. Chat lines carry the
    -- addon's own prefix, forum posts carry quote markers, and Discord adds
    -- backticks. The format marker is unambiguous, so anything before it is
    -- dropped rather than failing the paste. `Preset.parse` stays strict - the
    -- leniency belongs to the command, and the checksum still has to hold. Any
    -- DA<n> marker is kept, so a newer format is still refused by name.
    local body = ns.presetBody(rest)

    local zoneName, zone = Preset.parse(body)
    if not zoneName then
        warn("not a preset: " .. tostring(zone))
        return
    end
    return ns.offerPreset(zoneName, zone, nil, body)
end

ns.COMMANDS.ignore = function(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = rest:lower()

    if lower == "list" then
        local names = {}
        for n in pairs(settings.sharing.ignorePlayers) do names[#names + 1] = n end
        table.sort(names)
        if not settings.sharing.accept then
            out("|cffffaa00ignoring ALL requests (sharing is off)|r - /amb unignore all")
        end
        if #names == 0 then
            out("no players ignored.")
        else
            out(format("%d ignored: %s", #names, table.concat(names, ", ")))
        end
        out("|cff888888" .. (ns.settingsSavedLine and ns.settingsSavedLine()
            or keptLine()) .. "|r")
        return
    end

    if lower == "all" then
        -- "Ignore all requests" is the saved setting sharing.accept = false
        -- (DESIGN-ui.md 3.6), not a flag for the session.
        settings.sharing.accept = false
        saveSharing("accept")
        out("ignoring all preset requests - " .. keptLine() .. " /amb unignore all undoes it.")
        return
    end

    if rest == "" then
        warn("usage: /amb ignore <name> | all | list")
        return
    end

    settings.sharing.ignorePlayers[rest] = true
    saveSharing(nil)
    out(format("%s will not raise a confirmation - %s", rest, keptLine()))
end

ns.COMMANDS.unignore = function(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if rest:lower() == "all" then
        settings.sharing.accept = true
        saveSharing("accept")
        out("no longer ignoring everything - " .. keptLine())
        return
    end
    if rest == "" then
        warn("usage: /amb unignore <name> | all")
        return
    end
    if not settings.sharing.ignorePlayers[rest] then
        warn(rest .. " was not ignored.")
        return
    end
    settings.sharing.ignorePlayers[rest] = nil
    saveSharing(nil)
    out(rest .. " is no longer ignored - " .. keptLine())
end

-- Not yet -----------------------------------------------------------------------------
--
-- The command exists so that asking for it gets an answer rather than "unknown".
-- It does not pretend to a capability that has not been measured.

ns.COMMANDS.share = function()
    warn("sharing over party/raid is not wired up yet.")
    out("Whether this client has addon-to-addon messaging at all is unmeasured, and the "
        .. "transport is built against a measurement rather than against a guess.")
    out("Until then: |cffffff00/amb export|r gives you a string to paste anywhere, and the "
        .. "receiver runs |cffffff00/amb import|r - which raises the same confirmation the "
        .. "wire will.")
end
