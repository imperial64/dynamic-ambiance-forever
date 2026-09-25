-- A small stand-in for the parts of the client Dynamic Ambiance touches.
--
-- It exists so the blending, the ease, the write cap, the combat freeze and the
-- restore-on-exit path can be exercised without launching the game. It is not a
-- WoW emulator and does not try to be: it models the calls the addon makes and
-- the failure modes the client is known to have - a nilable position, an event
-- name that raises on registration, a value that comes back secret.
--
-- Load order matches the .toc.

local M = {}

-- Regions: textures, lines and font strings, as far as the editor touches them.
-- A path containing "NoSuch" is refused the way a missing file is assumed to be,
-- so a bogus path has something to be told apart from.
local function newRegion(kind)
    local r = { kind = kind, shown = true, points = {} }
    function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function r:SetAllPoints() end
    function r:ClearAllPoints() self.points = {} end
    function r:SetSize(w, h) self.w, self.h = w, h end
    function r:SetWidth(w) self.w = w end
    function r:SetHeight(h) self.h = h end
    function r:GetWidth() return self.w or 0 end
    function r:GetHeight() return self.h or 0 end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:IsShown() return self.shown end
    function r:SetShown(b) self.shown = b and true or false end
    function r:SetAlpha(a) self.alpha = a end
    function r:SetVertexColor(...) self.vertex = { ... } end
    function r:SetDrawLayer() end
    return r
end

local function refused(path)
    return type(path) == "string" and path:find("NoSuch", 1, true) ~= nil
end

local function newTexture()
    local t = newRegion("Texture")
    function t:SetTexture(file)
        if refused(file) then return false end
        self.file = file
        return true
    end
    function t:GetTexture() return self.file end
    function t:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
    -- The 10.0 shape: two ColorMixin tables. The six-number form raises, which
    -- is an assumption about this client, not a measurement.
    function t:SetGradient(orientation, from, to)
        if type(from) ~= "table" or type(to) ~= "table" then
            error("Usage: SetGradient(orientation, minColor, maxColor)", 2)
        end
        self.gradient = orientation
    end
    function t:SetTexCoord(...) self.texCoord = { ... } end
    function t:SetDrawLayer() end
    return t
end

local function newLine()
    local l = newRegion("Line")
    function l:SetThickness(n) self.thickness = n end
    function l:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
    function l:SetStartPoint(...) self.startPoint = { ... } end
    function l:SetEndPoint(...) self.endPoint = { ... } end
    return l
end

local function newFontString()
    local fs = newRegion("FontString")
    function fs:SetFont(path, size, flags)
        if refused(path) then return false end
        self.font = { path, size, flags }
        return true
    end
    function fs:GetFont()
        if not self.font then return nil end
        return self.font[1], self.font[2], self.font[3]
    end
    function fs:SetFontObject(o) self.fontObject = o end
    function fs:SetText(s) self.text = s end
    function fs:GetText() return self.text end
    function fs:SetJustifyH() end
    function fs:SetJustifyV() end
    function fs:SetTextColor(...) self.textColor = { ... } end
    function fs:SetWordWrap() end
    function fs:SetNonSpaceWrap() end
    function fs:SetSpacing() end
    function fs:GetStringWidth() return #(self.text or "") * 6 end
    function fs:GetStringHeight() return 12 end
    return fs
end

-- The widget half of a frame. Every frame gets all of it regardless of type -
-- this is a stand-in, not a type system - unless M.frameMinimal is set, which
-- models a client whose frames have none of these methods at all.
local function addWidgetMethods(f)
    function f:SetSize(w, h) self.w, self.h = w, h end
    function f:SetWidth(w) self.w = w end
    function f:SetHeight(h) self.h = h end
    function f:SetPoint(...) self.points = self.points or {} ; self.points[#self.points + 1] = { ... } end
    function f:SetAllPoints() end
    function f:ClearAllPoints() self.points = {} end
    function f:SetFrameStrata() end
    function f:SetClampedToScreen() end
    function f:SetClipsChildren() end
    function f:EnableMouse() end
    function f:SetMovable() end
    function f:RegisterForDrag() end
    function f:RegisterForClicks() end
    function f:StartMoving() end
    function f:StopMovingOrSizing() end
    function f:CreateTexture(_, layer, _, sublevel)
        local t = newTexture()
        t.layer, t.sublevel = layer, sublevel
        M.regions[#M.regions + 1] = t
        return t
    end
    function f:CreateMaskTexture() return newTexture() end
    function f:CreateLine() local l = newLine() ; M.regions[#M.regions + 1] = l ; return l end
    function f:CreateFontString() return newFontString() end
    -- EditBox / Button / ScrollFrame
    function f:SetText(s) self.text = s end
    function f:GetText() return self.text or "" end
    function f:SetMaxLetters(n) self.maxLetters = n end
    function f:SetMultiLine(b) self.multiLine = b end
    function f:SetAutoFocus() end
    function f:SetFontObject(o) self.fontObject = o end
    function f:SetFont() return true end
    function f:SetFocus() self.focused = true end
    function f:ClearFocus() self.focused = false end
    function f:HighlightText() self.highlighted = true end
    function f:SetCursorPosition() end
    function f:SetScrollChild(c) self.scrollChild = c end
    -- What the editor window leans on. Getters answer from what was set, so a
    -- layout can be read back; the rectangle is UIParent-relative and fixed.
    function f:GetWidth() return self.w or 0 end
    function f:GetHeight() return self.h or 0 end
    function f:GetLeft() return self.left or 0 end
    function f:GetTop() return self.top or (self.h or 0) end
    function f:SetScale(s) self.scale = s end
    function f:GetScale() return self.scale or 1 end
    function f:GetEffectiveScale() return self.scale or 1 end
    function f:IsMouseOver() return self.mouseOver == true end
    function f:EnableKeyboard(b) self.keyboard = b end
    -- Retail refuses this in combat without raising (M.propagateBlockedInCombat
    -- models that); the getter reads back what actually took.
    function f:SetPropagateKeyboardInput(b)
        if M.propagateBlockedInCombat and M.inCombat then return end
        self.propagate = b
    end
    function f:GetPropagateKeyboardInput() return self.propagate == true end
    function f:SetFrameLevel(n) self.level = n end
    function f:GetFrameLevel() return self.level or 1 end
    function f:SetToplevel() end
    function f:Raise() end
    function f:SetAlpha(a) self.alpha = a end
    function f:SetParent(p) self.parent = p end
    function f:GetParent() return self.parent end
    function f:SetID(n) self.id = n end
    function f:GetID() return self.id end
    function f:HookScript(which, fn)
        local prev = self.scripts[which]
        self.scripts[which] = prev and function(...) prev(...) ; fn(...) end or fn
    end
    function f:Enable() self.enabled = true end
    function f:Disable() self.enabled = false end
    function f:SetEnabled(b) self.enabled = b and true or false end
    function f:IsEnabled() return self.enabled ~= false end
    function f:LockHighlight() self.locked = true end
    function f:UnlockHighlight() self.locked = false end
    function f:SetNormalTexture() end
    function f:SetHighlightTexture() end
    function f:SetPushedTexture() end
    function f:SetHitRectInsets() end
    function f:GetFontString() return self.fontString end
    function f:SetNormalFontObject() end
    function f:SetDisabledFontObject() end
    function f:SetHighlightFontObject() end
    -- Slider / CheckButton / EditBox
    function f:SetMinMaxValues(lo, hi) self.min, self.max = lo, hi end
    function f:GetMinMaxValues() return self.min, self.max end
    function f:SetValueStep(s) self.step = s end
    function f:SetObeyStepOnDrag() end
    function f:SetOrientation() end
    function f:SetThumbTexture() end
    function f:SetValue(v)
        self.value = v
        local fn = self.scripts.OnValueChanged
        if fn then fn(self, v, false) end
    end
    function f:GetValue() return self.value or 0 end
    function f:SetChecked(b) self.checked = b and true or false end
    function f:GetChecked() return self.checked == true end
    function f:SetNumeric() end
    function f:SetTextInsets() end
    function f:SetJustifyH() end
    function f:SetTextColor() end
    function f:HasFocus() return self.focused == true end
    function f:GetNumLetters() return #(self.text or "") end
    function f:SetVerticalScroll(v) self.vscroll = v end
end

local function newFrame(name, ftype, template)
    local f = {
        name     = name,
        ftype    = ftype,
        template = template,
        scripts  = {},
        events   = {},
        shown    = false,
    }
    function f:RegisterEvent(event)
        if M.eventRefusals[event] then
            error("unknown event: " .. event, 2)
        end
        self.events[event] = true
    end
    function f:UnregisterEvent(event) self.events[event] = nil end
    function f:SetScript(which, fn) self.scripts[which] = fn end
    function f:GetScript(which) return self.scripts[which] end
    -- OnShow / OnHide fire on a change of state, as the client fires them.
    function f:Show()
        if self.shown then return end
        self.shown = true
        if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    function f:Hide()
        if not self.shown then return end
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:IsShown() return self.shown end
    function f:SetShown(b) if b then self:Show() else self:Hide() end end
    function f:IsVisible() return self.shown end
    function f:Fire(event, ...)
        if not self.events[event] then return false end
        local fn = self.scripts.OnEvent
        if not fn then return false end
        fn(self, event, ...)
        return true
    end
    if not M.frameMinimal then addWidgetMethods(f) end
    if type(template) == "string" and template:find("BackdropTemplate", 1, true) then
        function f:SetBackdrop(b) self.backdrop = b end
    end
    return f
end

-- A value that behaves the way this client's secret values do: it survives
-- tostring() and detonates at the point of use.
local secretMT = {
    __tostring = function() return "secret" end,
    __concat   = function() error("attempt to use a secret value") end,
    __eq       = function() error("attempt to use a secret value") end,
}
local secrets = setmetatable({}, { __mode = "k" })

function M.secret()
    local v = setmetatable({}, secretMT)
    secrets[v] = true
    return v
end

function M.install()
    M.chat          = {}
    M.cvars         = { Brightness = "50.00", Contrast = "50.00", Gamma = "1.00" }
    M.cvarClamp     = {}           -- name -> { min, max }, applied on write
    M.writes        = {}
    M.zone          = ""
    M.subzone       = ""
    M.mapID         = nil
    M.position      = nil          -- {x, y}, or nil for "client gave nothing"
    M.positionShape = "numbers"    -- numbers | vector | none
    M.eventRefusals = {}
    M.frames        = {}
    M.secrets       = {}

    _G.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, msg) M.chat[#M.chat + 1] = msg end,
    }

    -- Templates. An unknown one raises, which is what retail does;
    -- M.templateRaises makes every template raise, and M.frameMinimal gives
    -- frames nothing beyond events and scripts.
    M.regions        = {}
    M.frameMinimal   = false
    M.templateRaises = false
    M.templates      = {
        BackdropTemplate = true, UIPanelButtonTemplate = true, InputBoxTemplate = true,
        OptionsSliderTemplate = true, UICheckButtonTemplate = true,
        UIDropDownMenuTemplate = true, UIPanelScrollFrameTemplate = true,
        BasicFrameTemplateWithInset = true, ButtonFrameTemplate = true,
        UIPanelCloseButton = true,
    }

    _G.CreateFrame = function(ftype, name, _, template)
        if template ~= nil then
            if M.templateRaises then
                error("CreateFrame: template refused: " .. tostring(template), 2)
            end
            for t in tostring(template):gmatch("[^,%s]+") do
                if not M.templates[t] then error("CreateFrame: Unknown template " .. t, 2) end
            end
        end
        local f = newFrame(name, ftype, template)
        M.frames[#M.frames + 1] = f
        return f
    end

    _G.SlashCmdList = {}

    -- Deliberately namespaced and with no global twin: on build 69913 there is no
    -- global GetCVarInfo, so an addon reaching for one must fail here too.
    M.cvarFlags = {}

    _G.C_CVar = {
        GetCVar = function(n) return M.cvars[n] end,
        GetCVarInfo = function(n)
            local f = M.cvarFlags[n] or {}
            return M.cvars[n], "50", false, false,
                   f.locked or false, f.secure or false, f.readOnly or false
        end,
        SetCVar = function(n, v)
            local requested = v
            local c = M.cvarClamp[n]
            if c and tonumber(v) then
                local x = tonumber(v)
                if x < c[1] then x = c[1] elseif x > c[2] then x = c[2] end
                v = string.format("%.2f", x)
            end
            M.cvars[n] = v
            M.writes[#M.writes + 1] = { name = n, value = v, requested = requested }
            return true
        end,
    }

    _G.GetZoneText    = function()
        if M.secrets.zone then return M.secret() end
        return M.zone
    end
    _G.GetSubZoneText = function() return M.subzone end

    _G.C_Map = {
        GetBestMapForUnit = function() return M.mapID end,
        GetPlayerMapPosition = function()
            if not M.position then return nil end
            if M.positionShape == "vector" then
                local p = M.position
                return { GetXY = function() return p[1], p[2] end }
            end
            return M.position[1], M.position[2]
        end,
    }

    -- The client's sanctioned way of spotting a secret before it is coerced.
    _G.issecretvalue = function(v) return secrets[v] == true end

    -- Instances. M.instance is nil for the open world, or a table shaped like
    -- what GetInstanceInfo hands back - deliberately positional, because the
    -- number of return values on this client has not been measured and a test
    -- that assumes ten of them would be asserting on retail rather than here.
    M.instance = nil

    _G.IsInInstance = function()
        if not M.instance then return false, "none" end
        return true, M.instance.instanceType
    end
    _G.GetInstanceInfo = function()
        local i = M.instance
        if not i then return "", "none", 0, "", 0, 0, false, 0, 0, nil end
        return i.name or "Instance", i.instanceType, i.difficultyID or 1,
               i.difficulty or "Normal", i.maxPlayers or 5, 0, false,
               i.instanceID or 0, i.groupSize or 0, nil
    end

    _G.IsInGroup                = function() return M.inGroup == true end
    _G.IsInRaid                 = function() return M.inRaid == true end
    _G.UnitInBattleground       = function() return nil end
    _G.IsActiveBattlefieldArena = function() return false end
    _G.GetNumGroupMembers       = function() return M.groupMembers or 0 end
    M.inGroup, M.inRaid, M.groupMembers = false, false, 0

    _G.UnitName       = function() return "Tester" end
    _G.GetNormalizedRealmName = function() return "TestRealm" end

    -- The editor's inputs: the cursor in screen pixels (y upwards) and a clock.
    M.cursor = { 0, 0 }
    M.time   = 1000
    _G.GetCursorPosition = function() return M.cursor[1], M.cursor[2] end
    _G.GetTime           = function() return M.time end
    _G.UISpecialFrames   = {}
    _G.GameTooltip = {
        SetOwner = function() end, SetText = function(_, t) M.tooltip = t end,
        AddLine = function() end, Show = function() end, Hide = function() end,
    }
    -- UIDropDownMenu, as far as the editor calls it. Items added during an
    -- initialize are kept per frame so a test can pick one.
    M.dropdowns = {}
    _G.UIDropDownMenu_Initialize = function(frame, fn)
        frame.initialize = fn
        M.dropdowns[frame] = {}
        M.dropdownOpening = frame
        fn(frame, 1)
        M.dropdownOpening = nil
    end
    _G.UIDropDownMenu_CreateInfo = function() return {} end
    _G.UIDropDownMenu_AddButton  = function(info)
        local f = M.dropdownOpening
        if f then table.insert(M.dropdowns[f], info) end
    end
    _G.UIDropDownMenu_SetWidth = function() end
    _G.UIDropDownMenu_SetText  = function(frame, t) frame.ddText = t end
    _G.CloseDropDownMenus      = function() end
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show   = function(which) M.popupShown = which ; return {} end
    _G.StaticPopup_Hide   = function(which) M.popupHidden = which end
    _G.SetItemRef     = function() end
    _G.SendChatMessage = function(msg, ch, _, target)
        M.chatSent[#M.chatSent + 1] = { msg = msg, channel = ch, target = target }
    end
    M.chatSent = {}
    _G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendAddonMessage = function(prefix, payload, channel, target)
            M.addonSent[#M.addonSent + 1] =
                { prefix = prefix, payload = payload, channel = channel, target = target }
            return true
        end,
    }
    M.addonSent = {}

    _G.GetBuildInfo     = function() return "1.60.1", "69913", "2026-09-18", 16001 end
    _G.GetFramerate     = function() return 119.9 end
    _G.InCombatLockdown = function() return M.inCombat == true end
    _G.IsIndoors        = function() return M.isIndoors == true end
    _G.IsOutdoors       = function() return M.isIndoors ~= true end
    M.isIndoors = false
    _G.C_Timer          = { After = function(_, fn) M.timers[#M.timers + 1] = fn end }
    M.timers = {}
    M.inCombat = false
    M.propagateBlockedInCombat = false
    M.afterFile = nil

    _G.date = function(fmt) return "1970-01-01 00:00:00" end

    -- What the editor reads. Shaped after retail, because that is the only
    -- documentation there is; every value here is a guess, and the tests that
    -- use them assert on the addon's handling, not on the numbers.
    _G.UIParent = newFrame("UIParent", "Frame")
    _G.UIParent.w, _G.UIParent.h, _G.UIParent.shown = 1366, 768, true
    M.worldMap = { shown = false, mapID = 1429 }
    _G.WorldMapFrame = {
        IsShown         = function() return M.worldMap.shown end,
        GetMapID        = function() return M.worldMap.mapID end,
        AddDataProvider = function() end,
        GetCanvas       = function() return {} end,
        ScrollContainer = { GetNormalizedCursorPosition = function() return 0.5, 0.5 end },
    }
    local tiles = {}
    for i = 1, 12 do tiles[i] = 750000 + i end
    _G.C_Map.MapHasArt   = function() return true end
    _G.C_Map.GetMapArtID = function() return 12 end
    _G.C_Map.GetMapArtLayers = function()
        return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256,
                   minScale = 1, maxScale = 1, additionalZoomSteps = 0 } }
    end
    _G.C_Map.GetMapArtLayerTextures = function() return tiles end
    _G.C_Map.GetMapInfo = function(id)
        return { mapID = id, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 }
    end
    _G.C_Map.GetMapChildrenInfo = function()
        return {
            { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
            { mapID = 1431, name = "Duskwood",      mapType = 3, parentMapID = 1415 },
            { mapID = 1436, name = "Westfall",      mapType = 3, parentMapID = 1415 },
        }
    end
    _G.C_Map.GetMapWorldSize = function() return 3470.83, 2314.62 end
    _G.C_Map.GetWorldPosFromMapPos = function(_, pos)
        local x, y = pos.x, pos.y
        local wx, wy = -9000 + y * 2314.62, 1000 - x * 3470.83
        return 0, { x = wx, y = wy, GetXY = function() return wx, wy end }
    end
    _G.CreateVector2D = function(x, y) return { x = x, y = y } end
    _G.UnitPosition   = function() return -8914.5, -135.2, 0, 0 end
    _G.CreateColor    = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
    _G.C_Texture      = { GetAtlasExists = function(n) return n == "128-RedButton-UP" end }
    local function font(path, size)
        return { GetFont = function() return path, size, "" end }
    end
    _G.GameFontNormal        = font("Fonts\\FRIZQT__.TTF", 12)
    _G.GameFontHighlight     = font("Fonts\\FRIZQT__.TTF", 12)
    _G.GameFontHighlightSmall = font("Fonts\\FRIZQT__.TTF", 10)
    _G.ChatFontNormal        = font("Fonts\\ARIALN.TTF", 14)
    _G.NumberFontNormal      = font("Fonts\\ARIALN.TTF", 14)
    _G.BackdropTemplateMixin = {}
    _G.ColorPickerFrame      = { SetupColorPickerAndShow = function() end }
    _G.Settings = {
        RegisterCanvasLayoutCategory = function() return {} end,
        RegisterAddOnCategory        = function() end,
    }
    _G.InterfaceOptions_AddCategory = nil

    _G.DynamicAmbianceDB     = nil
    _G.DynamicAmbianceCharDB = nil
end

-- Load the addon exactly as the .toc lists it, into a fresh namespace, then do
-- what the client does next: restore SavedVariables and fire ADDON_LOADED.
--
-- The order is the point. The client runs every file first and only then assigns
-- the saved globals, so anything read at file load sees nil whatever was saved.
-- `saved` is { account = <table>, char = <table> } - what the files on disk held -
-- and nil means a fresh install. A key the file never defined is left alone, the
-- same as the client leaves a global alone when there is no file to restore.
-- The file list is read from the .toc itself, so a file added to the addon is
-- loaded here in the same order the client loads it, and a file left out of the
-- .toc is left out here too. Subfolders are written with a backslash in the .toc,
-- the client's convention.
function M.tocFiles(root)
    local files = {}
    local fh = assert(io.open(root .. "/addons/DynamicAmbiance/DynamicAmbiance.toc", "r"))
    for line in fh:lines() do
        line = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    fh:close()
    return files
end

function M.load(root, saved)
    local ns = {}
    M.loaded = M.tocFiles(root)
    for _, file in ipairs(M.loaded) do
        local chunk, err = loadfile(root .. "/addons/DynamicAmbiance/" .. file)
        if not chunk then error(err) end
        chunk("DynamicAmbiance", ns)
        -- M.afterFile(file, ns) lets a test change what a file left behind -
        -- an older Config.lua, say - before the next file reads it.
        if M.afterFile then M.afterFile(file, ns) end
    end
    if saved and saved.account ~= nil then _G.DynamicAmbianceDB     = saved.account end
    if saved and saved.char    ~= nil then _G.DynamicAmbianceCharDB = saved.char    end
    M.fireAll("ADDON_LOADED", "DynamicAmbiance")
    return ns
end

-- Fire an event on every frame registered for it, the way the client does.
function M.fireAll(event, ...)
    local n = 0
    for i = 1, #M.frames do
        if M.frames[i]:Fire(event, ...) then n = n + 1 end
    end
    return n
end

-- Run every timer queued through C_Timer.After since the last call. The editor's
-- clipboard watch defers work this way, and a test that cannot advance them
-- can only assert on half of what happened.
function M.runTimers()
    local pending = M.timers
    M.timers = {}
    for i = 1, #pending do pending[i]() end
    return #pending
end

function M.frameNamed(name)
    for i = 1, #M.frames do
        if M.frames[i].name == name then return M.frames[i] end
    end
    return nil
end

function M.writesTo(name)
    local n = 0
    for i = 1, #M.writes do
        if M.writes[i].name == name then n = n + 1 end
    end
    return n
end

function M.lastWrite(name)
    for i = #M.writes, 1, -1 do
        if M.writes[i].name == name then return tonumber(M.writes[i].value) end
    end
    return nil
end

function M.chatMatches(pattern)
    for i = 1, #M.chat do
        if M.chat[i]:find(pattern, 1, true) then return M.chat[i] end
    end
    return nil
end

return M
