-- Dynamic Ambiance - the map canvas ---------------------------------------------------
--
-- design/ui/DESIGN-ui.md 6.1-6.4. The zone's own map art in a frame of our own,
-- with every placed area drawn over it: a translucent fill, an outline in its
-- priority colour, its falloff band, handles when selected, and the player.
--
-- What it stands on, all measured on build 69977:
--
--   M2  C_Map.MapHasArt / GetMapArtLayers / GetMapArtLayerTextures give the art
--       as a grid of fileIDs that textures in our own frame accept (Elwynn:
--       1002 x 668, 4 x 3 tiles of 256)
--   M3  CreateLine and SetColorTexture draw and are visible; there is no polygon
--       fill, which is why Raster.lua rasterises one into strips
--   M4  a bogus texture is detected by GetTexture() returning nil, not by
--       SetTexture's return value
--
-- This file draws and reports mouse input in map coordinates. Deciding what a
-- click means is Editor.lua's job.
--
-- Also here, because both UI files need them: the guarded helpers every frame
-- call in the editor goes through. Nothing from FrameXML is assumed - a global,
-- a template, a mixin or a child key is looked up and called under pcall, and
-- CreateFrame with a template always goes through pcall, since an unknown
-- template raises on this client (M3).

local ADDON, ns = ...
if not (ns and ns.Raster and ns.Theme) then return end

local R, T = ns.Raster, ns.Theme
local format, floor, ceil, sqrt, max, min = string.format, math.floor, math.ceil, math.sqrt,
    math.max, math.min

-- Guarded helpers -----------------------------------------------------------------------

local UI = {}
ns.UI = UI

-- One named function rather than a closure per lookup: these run per frame
-- while the window is open and per line when it is drawn.
local function index(obj, key) return obj[key] end

function UI.G(name)
    local ok, v = pcall(index, _G, name)
    if ok then return v end
    return nil
end

-- obj[key] without trusting obj.
function UI.get(obj, key)
    local t = type(obj)
    if t ~= "table" and t ~= "userdata" then return nil end
    local ok, v = pcall(index, obj, key)
    if ok then return v end
    return nil
end

-- A method call that cannot raise: false if the method is absent or raised,
-- otherwise true followed by its returns.
function UI.call(obj, method, ...)
    local f = UI.get(obj, method)
    if type(f) ~= "function" then return false end
    return pcall(f, obj, ...)
end

-- A global function call that cannot raise.
function UI.callG(name, ...)
    local f = UI.G(name)
    if type(f) ~= "function" then return false end
    return pcall(f, ...)
end

-- CreateFrame, always under pcall. Returns the frame, or nil and why not.
--
-- A templated frame always gets a name. M4 created every template it measured
-- WITH a name, because UIDropDownMenuTemplate and its kin build child names
-- from $parent and raise without one; a template is only known to work here
-- the way it was measured.
local autoName = 0

function UI.create(ftype, name, parent, template)
    local cf = UI.G("CreateFrame")
    if type(cf) ~= "function" then return nil, "CreateFrame absent" end
    if template ~= nil and name == nil then
        autoName = autoName + 1
        name = "DynamicAmbianceUI" .. autoName
    end
    local ok, f = pcall(cf, ftype, name, parent, template)
    if not ok then return nil, (ns.plain and ns.plain(f)) or "raised" end
    if f == nil then return nil, "returned nil" end
    return f
end

-- A template, and if that template is refused, the same frame without it.
function UI.createOr(ftype, name, parent, template)
    local f = UI.create(ftype, name, parent, template)
    if f then return f, true end
    return UI.create(ftype, name, parent), false
end

-- The theme's font on a font string or edit box. A missing font raises in
-- SetFont (M4), so it is pcall'd and falls back to the game's own font object.
function UI.font(obj, size, flags)
    local path = T.get("font")
    local ok = UI.call(obj, "SetFont", path, size or T.get("fontSize") or 12, flags or "")
    if not ok then
        local fo = UI.G("GameFontHighlightSmall") or UI.G("GameFontHighlight")
        if fo then UI.call(obj, "SetFontObject", fo) end
    end
end

function UI.color(obj, key, alpha)
    local r, g, b = T.rgb(key)
    UI.call(obj, "SetTextColor", r, g, b, alpha or 1)
end

-- A font string, themed.
function UI.text(parent, text, size, colorKey, layer)
    local ok, fs = UI.call(parent, "CreateFontString", nil, layer or "OVERLAY")
    if not ok or fs == nil then return nil end
    UI.font(fs, size)
    UI.color(fs, colorKey or "text")
    UI.call(fs, "SetJustifyH", "LEFT")
    if text then fs:SetText(text) end
    return fs
end

function UI.texture(parent, layer, sublevel)
    local ok, t = UI.call(parent, "CreateTexture", nil, layer or "ARTWORK", nil, sublevel)
    if not ok or t == nil then return nil end
    return t
end

-- The Canvas ----------------------------------------------------------------------------

local Canvas = {}
Canvas.__index = Canvas
ns.Canvas = Canvas

Canvas.NO_ART    = "no map art for this zone - named areas still work"
Canvas.HANDLE    = 7          -- pixels: a handle's size, and how near a click must be
Canvas.MID       = 5          -- pixels: an edge's midpoint handle (feedback-1.md item 4)
Canvas.MID_MIN   = 3 * Canvas.HANDLE   -- an edge shorter than this on screen has no midpoint handle
Canvas.FILL_A    = 0.25       -- M3 measured 0.4 clearly visible; lighter for stacking
Canvas.BAND_A    = 0.5
Canvas.OUTLINE   = 2
Canvas.ZOOM_STEP = 1.25       -- one wheel notch or one press of + / -

function Canvas.new(parent, width, height)
    local self = setmetatable({}, Canvas)
    self.width, self.height = width, height
    self.tiles = {}
    -- The discovered-area overlays: art-pixel pieces and a pool of textures,
    -- reused from map to map.
    self.pieces, self.overlayTex, self.pieceCount = {}, {}, 0
    self.source, self.sourceText = nil, ""
    self.pools = { strip = { n = 0 }, line = { n = 0 }, handle = { n = 0 } }
    self.hasArt = false
    self.view = R.newView()

    local f, err = UI.create("Frame", nil, parent)
    if not f then return nil, err end
    self.frame = f
    f:SetSize(width, height)
    -- Belt and braces: everything drawn is also cut to the canvas arithmetically
    -- (Raster.clipRect / clipSegment), so nothing depends on this taking.
    UI.call(f, "SetClipsChildren", true)
    UI.call(f, "EnableMouse", true)
    UI.call(f, "EnableMouseWheel", true)

    local bg = UI.texture(f, "BACKGROUND", -8)
    if bg then
        bg:SetAllPoints(f)
        bg:SetColorTexture(0.06, 0.06, 0.08, 1)
    end

    self.msg = UI.text(f, "", 14, "textMuted", "OVERLAY")
    if self.msg then
        self.msg:SetPoint("CENTER", f, "CENTER", 0, 0)
        UI.call(self.msg, "SetJustifyH", "CENTER")
        self.msg:Hide()
    end

    self.dot = UI.texture(f, "OVERLAY", 7)
    if self.dot then
        self.dot:SetSize(9, 9)
        self.dot:SetColorTexture(1, 1, 0.2, 1)
        self.dot:Hide()
    end

    local ok, rubber = UI.call(f, "CreateLine", nil, "OVERLAY")
    if ok and rubber then
        self.rubber = rubber
        UI.call(rubber, "SetThickness", 1)
        UI.call(rubber, "SetColorTexture", 1, 1, 1, 0.8)
        rubber:Hide()
    end

    -- The hint and the notice (feedback-1.md items 3 and 4): a child frame, so it
    -- sits over every line and fill, and one that never takes the mouse, so a
    -- click on it still lands on the map.
    local hint = UI.create("Frame", nil, f)
    if hint then
        self.hintFrame = hint
        hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
        hint:SetSize(width, 40)
        local hb = UI.texture(hint, "BACKGROUND")
        if hb then
            hb:SetAllPoints(hint)
            hb:SetColorTexture(0, 0, 0, 0.6)
        end
        self.hintText = UI.text(hint, "", 12, "text", "OVERLAY")
        if self.hintText then self.hintText:SetPoint("TOPLEFT", hint, "TOPLEFT", 8, -5) end
        self.noticeText = UI.text(hint, "", 12, "accent", "OVERLAY")
        if self.noticeText then self.noticeText:SetPoint("TOPLEFT", hint, "TOPLEFT", 8, -22) end
        hint:Hide()
    end

    f:SetScript("OnMouseDown", function(_, button) self:_mouse("down", button) end)
    f:SetScript("OnMouseUp", function(_, button) self:_mouse("up", button) end)
    f:SetScript("OnMouseWheel", function(_, delta) self:_wheel(delta) end)
    f:SetScript("OnEnter", function() self.over = true end)
    f:SetScript("OnLeave", function()
        self.over = false
        if self.onLeave then pcall(self.onLeave) end
    end)
    return self
end

local function frameRect(f)
    return f:GetEffectiveScale(), f:GetLeft(), f:GetTop(), f:GetWidth(), f:GetHeight()
end

-- Where the cursor is, as a map point through the view: nx, ny (clamped 0-1),
-- whether it is on the canvas at all, and the canvas pixel (unclamped). nil when
-- the cursor or the frame cannot be read.
function Canvas:cursor()
    local ok, cx, cy = UI.callG("GetCursorPosition")
    if not ok or type(cx) ~= "number" or type(cy) ~= "number" then return nil end
    local ok2, s, l, t, w, h = pcall(frameRect, self.frame)
    if not ok2 or not (s and l and t and w and h) or w <= 0 or h <= 0 or s <= 0 then
        return nil
    end
    return R.cursorToMap(cx, cy, s, l, t, w, h, self.view)
end

function Canvas:_mouse(what, button)
    local nx, ny, inside, px, py = self:cursor()
    if not nx then return end
    local fn = what == "down" and self.onDown or self.onUp
    if fn then
        local ok, err = pcall(fn, button, nx, ny, inside, px, py)
        if not ok and ns.warn then ns.warn("editor: " .. (ns.plain(err) or "?")) end
    end
end

-- Called from the editor's OnUpdate while shown. Reports a move only when the
-- cursor actually moved (or the view did, which moves the map under it), so
-- standing still costs one read and nothing else.
function Canvas:poll()
    local over = self.over
    if not over then
        local ok, v = UI.call(self.frame, "IsMouseOver")
        over = ok and v
    end
    if not over and not self.dragging then return end
    local nx, ny, inside, px, py = self:cursor()
    if not nx then return end
    if px == self.lastX and py == self.lastY then return end
    self.lastX, self.lastY = px, py
    if self.onMove then
        local ok, err = pcall(self.onMove, nx, ny, inside, px, py)
        if not ok and ns.warn then ns.warn("editor: " .. (ns.plain(err) or "?")) end
    end
end

function Canvas:message(text)
    if not self.msg then return end
    if text and text ~= "" then
        self.msg:SetText(text)
        self.msg:Show()
    else
        self.msg:Hide()
    end
end

-- The hint line (what the tool does) and the notice line (why something was
-- refused). The strip shows while either has text.
function Canvas:_hintVisibility()
    if not self.hintFrame then return end
    if (self.hintShown or "") ~= "" or (self.noticeShown or "") ~= "" then
        self.hintFrame:Show()
    else
        self.hintFrame:Hide()
    end
end

function Canvas:setHint(text)
    text = text or ""
    if text == self.hintShown then return end
    self.hintShown = text
    if self.hintText then self.hintText:SetText(text) end
    self:_hintVisibility()
end

function Canvas:setNotice(text)
    text = text or ""
    if text == self.noticeShown then return end
    self.noticeShown = text
    if self.noticeText then self.noticeText:SetText(text) end
    self:_hintVisibility()
end

-- The view ----------------------------------------------------------------------------

-- After any change of view: re-lay the art, report the cursor again (the map
-- under it moved), and let the editor redraw.
function Canvas:_viewChanged()
    self:layoutTiles()
    self.lastX, self.lastY = nil, nil
    if self.onView then
        local ok, err = pcall(self.onView)
        if not ok and ns.warn then ns.warn("editor: " .. (ns.plain(err) or "?")) end
    end
end

-- Zoom to `z` about the canvas pixel (px, py); the centre when none is given.
function Canvas:zoomTo(z, px, py)
    R.zoomAt(self.view, z, px or self.width / 2, py or self.height / 2, self.width, self.height)
    self:_viewChanged()
end

function Canvas:zoomBy(factor, px, py)
    self:zoomTo(self.view.zoom * factor, px, py)
end

function Canvas:resetView()
    self.view.zoom, self.view.ox, self.view.oy = 1, 0, 0
    self:_viewChanged()
end

function Canvas:panBy(dx, dy)
    R.panView(self.view, dx, dy, self.width, self.height)
    self:_viewChanged()
end

-- The wheel zooms about the cursor. Not while a shape or a handle is being
-- dragged: the drag is in map coordinates and would jump.
function Canvas:_wheel(delta)
    if self.dragging or type(delta) ~= "number" or delta == 0 then return end
    local _, _, inside, px, py = self:cursor()
    if not inside then px, py = nil, nil end
    self:zoomBy(delta > 0 and Canvas.ZOOM_STEP or 1 / Canvas.ZOOM_STEP, px, py)
end

-- Map point to canvas pixel, through the view.
function Canvas:toScreen(nx, ny)
    return R.mapToView(self.view, nx, ny, self.width, self.height)
end

-- Map art -----------------------------------------------------------------------------

local function mapCall(name, ...)
    local C = UI.G("C_Map")
    local f = UI.get(C, name)
    if type(f) ~= "function" then return false end
    return pcall(f, ...)
end

-- Loads the art of layer 1 for a map into a pooled grid of textures, the way
-- M2 was measured (design/ui/measurements-2026-09-24.md). Any failed tile, or no art at all, gives a flat panel and the
-- NO_ART message instead, and `hasArt` false so the drawing tools are disabled.
-- A new map starts at fit.
function Canvas:setMap(mapID)
    for i = 1, #self.tiles do self.tiles[i]:Hide() end
    self:hideOverlays()
    self.hasArt, self.mapID, self.art = false, mapID, nil
    self.view.zoom, self.view.ox, self.view.oy = 1, 0, 0
    self.lastX, self.lastY = nil, nil
    if not mapID then
        self:message(Canvas.NO_ART)
        return false
    end

    local okHas, has = mapCall("MapHasArt", mapID)
    local okL, layers = mapCall("GetMapArtLayers", mapID)
    local okT, files = mapCall("GetMapArtLayerTextures", mapID, 1)
    local layer = okL and type(layers) == "table" and layers[1]
    if (okHas and has == false) or type(layer) ~= "table" or not okT
        or type(files) ~= "table" or #files == 0 then
        self:message(Canvas.NO_ART)
        return false
    end

    local lw, lh = tonumber(layer.layerWidth), tonumber(layer.layerHeight)
    local tw, th = tonumber(layer.tileWidth), tonumber(layer.tileHeight)
    if not (lw and lh and tw and th) or lw <= 0 or lh <= 0 or tw <= 0 or th <= 0 then
        self:message(Canvas.NO_ART)
        return false
    end

    local failed = 0
    for i = 1, #files do
        local t = self.tiles[i]
        if not t then
            t = UI.texture(self.frame, "BORDER")
            self.tiles[i] = t
        end
        if t then
            UI.call(t, "SetTexture", files[i])
            local ok, got = UI.call(t, "GetTexture")
            if not ok or got == nil then failed = failed + 1 end
        else
            failed = failed + 1
        end
    end
    if failed > 0 then
        for i = 1, #self.tiles do self.tiles[i]:Hide() end
        self:message(Canvas.NO_ART)
        return false
    end
    self.art = { lw = lw, lh = lh, tw = tw, th = th, cols = ceil(lw / tw), count = #files }
    self.hasArt = true
    self:message(nil)
    self:loadOverlays(mapID)
    self:layoutTiles()
    return true
end

-- One texture placed over the art rectangle (ax, ay, aw, ah), whose texture
-- shows from 0 to u across and 0 to v down. It is cut to the canvas and its
-- texture coordinates cut to match, so no part of it is drawn outside; one that
-- is wholly outside is hidden. If SetTexCoord is refused, the whole rectangle is
-- placed uncut and the frame's own clipping has to do.
function Canvas:_place(t, ax, ay, aw, ah, u, v, sx, sy)
    local x, y, w, h, l, r, top, bottom = R.placeArt(ax, ay, aw, ah, u, v, sx, sy, self.view,
        self.width, self.height)
    t:ClearAllPoints()
    if not x then
        t:Hide()
        return
    end
    if not UI.call(t, "SetTexCoord", l, r, top, bottom) then
        x, y, w, h = ax * sx - self.view.ox, ay * sy - self.view.oy, aw * sx, ah * sy
    end
    t:SetSize(w, h)
    t:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -y)
    t:Show()
end

-- Places every base tile, then every overlay tile over them, for the current view.
function Canvas:layoutTiles()
    local g = self.art
    if not (self.hasArt and g) then return end
    local v = self.view
    local sx, sy = self.width / g.lw * v.zoom, self.height / g.lh * v.zoom
    for i = 1, g.count do
        local t = self.tiles[i]
        if t then
            local col, row = (i - 1) % g.cols, floor((i - 1) / g.cols)
            self:_place(t, col * g.tw, row * g.th, g.tw, g.th, 1, 1, sx, sy)
        end
    end
    for i = 1, self.pieceCount do
        local p, t = self.pieces[i], self.overlayTex[i]
        if t then
            if p.ok then self:_place(t, p.x, p.y, p.w, p.h, p.u, p.v, sx, sy) else t:Hide() end
        end
    end
end

-- The discovered areas ------------------------------------------------------------------
--
-- On the world map a discovered area is an overlay drawn over the base art, and
-- the base art alone is the undiscovered parchment. The client hands back only
-- the overlays the player has explored, so the whole set ships in
-- MapOverlays.lua, generated from the client's WorldMapOverlay tables for one
-- build and keyed by the map's art ID. Where to draw from, in order:
--
--   data      the shipped table has this art ID: every overlay, the full map
--   explored  C_MapExplorationInfo.GetExploredMapTextures exists and answers
--             with a table: what this character has explored (unmeasured here)
--   base      neither: the base art alone
--
-- The overlays sit on the BORDER layer one sublevel above the base tiles, so
-- they are under every fill, line and handle.

Canvas.SOURCE_DATA     = "full map (data %s)"
Canvas.SOURCE_EXPLORED = "explored areas only"
Canvas.SOURCE_BASE     = "base map only"

-- One overlay tile into the reused piece list: art-pixel rectangle, crop and file.
local function addPiece(out, n, ox, oy, tw, th, row, col, file)
    local tf = type(file)
    if tf ~= "number" and tf ~= "string" then return n end
    if type(row) ~= "number" or type(col) ~= "number" then return n end
    local x, y, w, h, u, v = R.overlayTile(ox, oy, tw, th, row, col)
    if not x then return n end
    n = n + 1
    local p = out[n]
    if not p then
        p = {}
        out[n] = p
    end
    p.x, p.y, p.w, p.h, p.u, p.v, p.file, p.ok = x, y, w, h, u, v, file, false
    return n
end

local function addTriples(list, first, out, n, ox, oy, tw, th)
    for i = first, #list - 2, 3 do
        n = addPiece(out, n, ox, oy, tw, th, list[i], list[i + 1], list[i + 2])
    end
    return n
end

-- The shipped table's overlays for one art ID (MapOverlays.lua's shape) into
-- `out`. Returns the count.
function Canvas.piecesFromData(overlays, out)
    local n = 0
    for i = 1, #overlays do
        local o = overlays[i]
        local ox, oy, tw, th = o[1], o[2], o[3], o[4]
        if type(ox) == "number" and type(oy) == "number" and type(tw) == "number"
            and type(th) == "number" then
            if type(o.layers) == "table" then
                local keys = {}
                for k in pairs(o.layers) do
                    if type(k) == "number" then keys[#keys + 1] = k end
                end
                table.sort(keys)
                for j = 1, #keys do n = addTriples(o.layers[keys[j]], 1, out, n, ox, oy, tw, th) end
            else
                n = addTriples(o, 5, out, n, ox, oy, tw, th)
            end
        end
    end
    return n
end

-- GetExploredMapTextures' entries, shaped as on retail: textureWidth,
-- textureHeight, offsetX, offsetY and fileDataIDs, row by row. Returns the count.
function Canvas.piecesFromExplored(list, out)
    local n, size = 0, R.OVERLAY_TILE
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" then
            local tw, th = tonumber(e.textureWidth), tonumber(e.textureHeight)
            local ox, oy = tonumber(e.offsetX), tonumber(e.offsetY)
            local ids = e.fileDataIDs
            if tw and th and ox and oy and tw > 0 and th > 0 and type(ids) == "table" then
                local wide, tall = ceil(tw / size), ceil(th / size)
                for row = 0, tall - 1 do
                    for col = 0, wide - 1 do
                        n = addPiece(out, n, ox, oy, tw, th, row, col, ids[row * wide + col + 1])
                    end
                end
            end
        end
    end
    return n
end

-- C_MapExplorationInfo.GetExploredMapTextures(mapID), if this client has it:
-- the list, or nil and why not ("absent", "raised", "not a table").
function Canvas.exploredFor(mapID)
    local f = UI.get(UI.G("C_MapExplorationInfo"), "GetExploredMapTextures")
    if type(f) ~= "function" then return nil, "absent" end
    local ok, list = pcall(f, mapID)
    if not ok then return nil, "raised" end
    if type(list) ~= "table" then return nil, "not a table" end
    return list, "present"
end

-- The shipped overlays for a map's art, or nil; and the art ID.
function Canvas.dataFor(mapID)
    local okA, artID = mapCall("GetMapArtID", mapID)
    if not okA or artID == nil then return nil, nil end
    local data = ns.MapOverlays
    local list = UI.get(UI.get(data, "art"), artID)
    if type(list) ~= "table" or #list == 0 then return nil, artID end
    return list, artID
end

-- The overlays to draw for a map, into `out`: the count, the source ("data",
-- "explored" or "base") and the line the editor shows for it.
function Canvas.overlaysFor(mapID, out)
    local list = Canvas.dataFor(mapID)
    if list then
        local ok, n = pcall(Canvas.piecesFromData, list, out)
        if ok then
            return n, "data", format(Canvas.SOURCE_DATA, tostring(ns.MapOverlays.build))
        end
    end
    local explored = Canvas.exploredFor(mapID)
    if explored then
        local ok, n = pcall(Canvas.piecesFromExplored, explored, out)
        if ok then return n, "explored", Canvas.SOURCE_EXPLORED end
    end
    return 0, "base", Canvas.SOURCE_BASE
end

function Canvas:hideOverlays()
    for i = 1, #self.overlayTex do
        local t = self.overlayTex[i]
        if t then t:Hide() end
    end
    self.pieceCount, self.source, self.sourceText = 0, nil, ""
end

-- Sets every overlay tile's file on a pooled texture: new textures only when
-- this map has more tiles than any map before it. A file the client refuses
-- hides that one tile; the rest of the map still draws.
function Canvas:loadOverlays(mapID)
    local n, source, text = Canvas.overlaysFor(mapID, self.pieces)
    self.pieceCount, self.source, self.sourceText = n, source, text
    for i = 1, n do
        local p, t = self.pieces[i], self.overlayTex[i]
        if t == nil then
            t = UI.texture(self.frame, "BORDER", 1) or false
            self.overlayTex[i] = t
        end
        if t then
            UI.call(t, "SetTexture", p.file)
            local ok, got = UI.call(t, "GetTexture")
            p.ok = ok and got ~= nil
            if not p.ok then t:Hide() end
        end
    end
    for i = n + 1, #self.overlayTex do
        local t = self.overlayTex[i]
        if t then t:Hide() end
    end
end

-- The client's build number and the shipped data's, and whether they differ.
-- nil for either one that cannot be read.
function Canvas.builds()
    local data = ns.MapOverlays
    local dataBuild = type(data) == "table" and type(data.build) == "string"
        and data.build:match("(%d+)$") or nil
    local ok, _, client = UI.callG("GetBuildInfo")
    client = ok and ns.plain and ns.plain(client) or nil
    return dataBuild, client, (dataBuild ~= nil and client ~= nil and dataBuild ~= client)
end

-- Pools ----------------------------------------------------------------------------------

function Canvas:_acquire(kind)
    local pool = self.pools[kind]
    pool.n = pool.n + 1
    local r = pool[pool.n]
    if r then return r end
    if kind == "line" then
        local ok, l = UI.call(self.frame, "CreateLine", nil, "OVERLAY")
        r = ok and l or false
    elseif kind == "handle" then
        r = UI.texture(self.frame, "OVERLAY", 6) or false
    else
        r = UI.texture(self.frame, "ARTWORK") or false
    end
    pool[pool.n] = r
    return r
end

function Canvas:beginDraw()
    for _, pool in pairs(self.pools) do pool.n = 0 end
end

function Canvas:endDraw()
    for _, pool in pairs(self.pools) do
        for i = pool.n + 1, #pool do
            if pool[i] then pool[i]:Hide() end
        end
    end
end

-- In canvas pixels; cut to the canvas, and nothing drawn when none of it is on it.
function Canvas:line(x1, y1, x2, y2, r, g, b, a, thick)
    x1, y1, x2, y2 = R.clipSegment(x1, y1, x2, y2, self.width, self.height)
    if not x1 then return end
    local l = self:_acquire("line")
    if not l then return end
    UI.call(l, "SetStartPoint", "TOPLEFT", self.frame, x1, -y1)
    UI.call(l, "SetEndPoint", "TOPLEFT", self.frame, x2, -y2)
    UI.call(l, "SetThickness", thick or 1)
    UI.call(l, "SetColorTexture", r, g, b, a or 1)
    l:Show()
end

function Canvas:rect(kind, x, y, w, h, r, g, b, a)
    x, y, w, h = R.clipRect(x, y, w, h, self.width, self.height)
    if not x then return end
    local t = self:_acquire(kind)
    if not t then return end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -y)
    t:SetSize(max(w, 1), max(h, 1))
    t:SetColorTexture(r, g, b, a or 1)
    t:Show()
end

function Canvas:handle(x, y, r, g, b, size)
    local s = size or Canvas.HANDLE
    self:rect("handle", x - s / 2, y - s / 2, s, s, r or 1, g or 1, b or 1, 1)
end

local segs, strips = {}, {}

function Canvas:segments(list, count, r, g, b, a, thick)
    for i = 1, count do
        local s = list[i]
        self:line(s[1], s[2], s[3], s[4], r, g, b, a, thick)
    end
end

-- Drawing -------------------------------------------------------------------------------

-- Normalized corners to canvas pixels through the view, into a reused table.
function Canvas:toPixels(corners, out)
    out = out or {}
    local n = #corners - #corners % 2
    for i = 1, n, 2 do
        out[i], out[i + 1] = self:toScreen(corners[i], corners[i + 1])
    end
    for i = #out, n + 1, -1 do out[i] = nil end
    return out
end

-- Yards to canvas pixels at the current zoom.
function Canvas:yards(yd, W)
    if not (yd and W) then return nil end
    return R.yardsToPixels(yd, self.width * self.view.zoom, W)
end

local polyPx = {}

-- The midpoint handles of a selected polygon's edges: small, grey, and only on
-- an edge long enough on screen to keep them off its corners.
function Canvas:midpoints(px)
    local n = #px - #px % 2
    if n < 6 then return end
    for k = 1, n / 2 do
        local mx, my, len = R.edgeMidpoint(px, k)
        if len >= Canvas.MID_MIN then self:handle(mx, my, 0.8, 0.8, 0.8, Canvas.MID) end
    end
end

-- One placed area. `W` is yards per normalized unit, or nil when the map's scale
-- is unknown: then the outline is drawn but no fill and no band, and a circle is
-- only its centre.
function Canvas:drawArea(a, selected, W, fill)
    local r, g, b = T.priorityColor(a.priority)
    local or_, og, ob = r, g, b
    if selected then or_, og, ob = 1, 1, 1 end

    if a.corners then
        local px = self:toPixels(a.corners, polyPx)
        if fill and W and #px >= 6 then
            local _, n = R.strips(px, R.pitchFor(self:_extent(px)), strips)
            for i = 1, n do
                local e = strips[i]
                self:rect("strip", e.x, e.y, e.w, e.h, r, g, b, Canvas.FILL_A)
            end
        end
        if W and a.falloffYards and a.falloffYards > 0 and #px >= 6 then
            local _, n = R.band(px, self:yards(a.falloffYards, W), segs)
            self:segments(segs, n, r, g, b, Canvas.BAND_A, 1)
        end
        local _, n = R.outline(px, segs)
        self:segments(segs, n, or_, og, ob, 1, Canvas.OUTLINE)
        if selected then
            self:midpoints(px)
            for i = 1, #px - 1, 2 do self:handle(px[i], px[i + 1]) end
        end
    elseif a.x and a.y then
        local cx, cy = self:toScreen(a.x, a.y)
        local rin = W and self:yards(a.innerYards, W)
        local rout = W and self:yards(a.falloffYards, W)
        if fill and rin and rin > 0 then
            local _, n = R.circleStrips(cx, cy, rin, R.pitchFor(2 * rin), strips)
            for i = 1, n do
                local e = strips[i]
                self:rect("strip", e.x, e.y, e.w, e.h, r, g, b, Canvas.FILL_A)
            end
        end
        if rout and rout > 0 then
            local _, n = R.ring(cx, cy, rout, 32, segs)
            self:segments(segs, n, r, g, b, Canvas.BAND_A, 1)
        end
        if rin and rin > 0 then
            local _, n = R.ring(cx, cy, rin, 32, segs)
            self:segments(segs, n, or_, og, ob, 1, Canvas.OUTLINE)
        else
            self:line(cx - 5, cy, cx + 5, cy, or_, og, ob, 1, Canvas.OUTLINE)
            self:line(cx, cy - 5, cx, cy + 5, or_, og, ob, 1, Canvas.OUTLINE)
        end
        if selected then
            self:handle(cx, cy)
            if rin then self:handle(cx + rin, cy, 1, 1, 1) end
            if rout then self:handle(cx + rout, cy, r, g, b) end
        end
    end
end

function Canvas:_extent(px)
    local lo, hi = math.huge, -math.huge
    for i = 2, #px, 2 do
        if px[i] < lo then lo = px[i] end
        if px[i] > hi then hi = px[i] end
    end
    return hi - lo
end

-- A shape still being drawn: its corners, the edges between them, handles.
function Canvas:drawDraft(d, W)
    if not d then return end
    if d.kind == "polygon" then
        local px = self:toPixels(d.corners, polyPx)
        for i = 1, #px - 3, 2 do
            self:line(px[i], px[i + 1], px[i + 2], px[i + 3], 1, 1, 1, 1, Canvas.OUTLINE)
        end
        for i = 1, #px - 1, 2 do self:handle(px[i], px[i + 1], 1, 0.9, 0.3) end
        if W and d.falloffYards and d.falloffYards > 0 and #px >= 6 then
            local _, n = R.band(px, self:yards(d.falloffYards, W), segs)
            self:segments(segs, n, 1, 1, 1, Canvas.BAND_A, 1)
        end
    elseif d.kind == "circle" and d.x then
        local cx, cy = self:toScreen(d.x, d.y)
        self:handle(cx, cy, 1, 0.9, 0.3)
        local rin = W and self:yards(d.innerYards, W)
        if rin and rin > 0 then
            local _, n = R.ring(cx, cy, rin, 32, segs)
            self:segments(segs, n, 1, 1, 1, 1, Canvas.OUTLINE)
        end
        local rout = W and self:yards(d.falloffYards, W)
        if rout and rout > 0 then
            local _, n = R.ring(cx, cy, rout, 32, segs)
            self:segments(segs, n, 1, 1, 1, Canvas.BAND_A, 1)
        end
    end
end

-- The whole picture. `model` = { areas = { {area, selected}... } lowest priority
-- first, W, fill, draft }.
function Canvas:render(model)
    self:beginDraw()
    if self.hasArt or model.drawWithoutArt then
        for i = 1, #model.areas do
            local item = model.areas[i]
            self:drawArea(item.area, item.selected, model.W, model.fill)
        end
        self:drawDraft(model.draft, model.W)
    end
    self:endDraw()
end

-- The rubber band from the draft's last corner to the cursor, in map points.
function Canvas:setRubber(x1, y1, x2, y2)
    if not self.rubber then return end
    if x1 then
        local ax, ay = self:toScreen(x1, y1)
        local bx, by = self:toScreen(x2, y2)
        ax, ay, bx, by = R.clipSegment(ax, ay, bx, by, self.width, self.height)
        if ax then
            UI.call(self.rubber, "SetStartPoint", "TOPLEFT", self.frame, ax, -ay)
            UI.call(self.rubber, "SetEndPoint", "TOPLEFT", self.frame, bx, -by)
            self.rubber:Show()
            return
        end
    end
    self.rubber:Hide()
end

-- The player's dot, hidden when off this map or scrolled out of the canvas.
function Canvas:setPlayer(nx, ny)
    if not self.dot then return end
    local px, py
    if nx then px, py = self:toScreen(nx, ny) end
    if not px or px < 0 or py < 0 or px > self.width or py > self.height then
        self.dot:Hide()
        return
    end
    self.dot:ClearAllPoints()
    self.dot:SetPoint("CENTER", self.frame, "TOPLEFT", px, -py)
    self.dot:Show()
end
