-- Dynamic Ambiance - canvas geometry --------------------------------------------------
--
-- design/ui/DESIGN-ui.md 6.2 and 6.4. Pure Lua: no frame calls, so the headless
-- suite covers every function here directly. Canvas.lua reads the cursor and the
-- frame's rectangle and hands the numbers in.
--
-- Canvas space is pixels from the art's TOPLEFT, y downwards, at the art's native
-- size (Elwynn: 1002 x 668). Map space is the normalized 0-1 of C_Map, y
-- downwards too, so the two differ only by the canvas size.
--
-- One fact the drawing relies on (DESIGN-ui.md section 0, M6): the map art's
-- pixel aspect matches the world's, so on the canvas a yard is the same length in
-- x and in y, and a falloff can be drawn as a uniform offset.

local ADDON, ns = ...
if not ns then return end

local floor, ceil, sqrt, huge = math.floor, math.ceil, math.sqrt, math.huge

local Raster = {}
ns.Raster = Raster

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

Raster.clamp01 = clamp01

-- Four places, the format's precision, applied the moment a corner is placed so
-- what is drawn is what is exported.
function Raster.round4(v)
    return floor(v * 10000 + 0.5) / 10000
end

-- Coordinate mapping ------------------------------------------------------------------

-- The view: zoom and pan -------------------------------------------------------------
--
-- design/ui/feedback-1.md item 1. The canvas frame keeps its size; the art is
-- drawn `zoom` times larger and shifted so that the art pixel (ox, oy) - in
-- zoomed pixels from the art's TOPLEFT - sits at the canvas's TOPLEFT. At zoom 1
-- the offset is always 0, 0 and every mapping below reduces to the plain one.
--
-- The view is clamped so the art always covers the whole canvas: nothing past
-- the map's edge is ever shown, and a pan stops at the edge.
--
-- Zoom runs from fit (1) to 4. The art's measured maxScale is 2.14 (M2), so it
-- may soften past that; that is accepted, not a cap.

Raster.MIN_ZOOM, Raster.MAX_ZOOM = 1, 4

function Raster.newView()
    return { zoom = 1, ox = 0, oy = 0 }
end

-- Keeps the offset inside what the zoomed art can show. Returns the view.
function Raster.clampView(v, width, height)
    local maxX, maxY = width * v.zoom - width, height * v.zoom - height
    if v.ox > maxX then v.ox = maxX end
    if v.oy > maxY then v.oy = maxY end
    if v.ox < 0 then v.ox = 0 end
    if v.oy < 0 then v.oy = 0 end
    return v
end

-- Map (normalized) to canvas pixels through the view, and back. Neither clamps.
function Raster.mapToView(v, nx, ny, width, height)
    return nx * width * v.zoom - v.ox, ny * height * v.zoom - v.oy
end

function Raster.viewToMap(v, px, py, width, height)
    return (px + v.ox) / (width * v.zoom), (py + v.oy) / (height * v.zoom)
end

-- Zoom to `zoom` (clamped to the range) keeping the map point under the canvas
-- pixel (px, py) where it is, unless that would show past the map's edge.
function Raster.zoomAt(v, zoom, px, py, width, height)
    if zoom < Raster.MIN_ZOOM then zoom = Raster.MIN_ZOOM end
    if zoom > Raster.MAX_ZOOM then zoom = Raster.MAX_ZOOM end
    local nx, ny = Raster.viewToMap(v, px, py, width, height)
    v.zoom = zoom
    v.ox, v.oy = nx * width * zoom - px, ny * height * zoom - py
    return Raster.clampView(v, width, height)
end

-- Moves the art by (dx, dy) canvas pixels: dragging right shows what is left.
function Raster.panView(v, dx, dy, width, height)
    v.ox, v.oy = v.ox - dx, v.oy - dy
    return Raster.clampView(v, width, height)
end

-- Coordinate mapping ------------------------------------------------------------------

-- `cx, cy` from GetCursorPosition (screen pixels, y upwards), `scale` the canvas's
-- effective scale, and its left, top, width and height in its own units, and
-- the view (nil for fit). Returns the normalized point clamped to 0-1, whether
-- the cursor was on the canvas at all, and the unclamped canvas pixel.
function Raster.cursorToMap(cx, cy, scale, left, top, width, height, view)
    local px, py = cx / scale - left, top - cy / scale
    local x, y
    if view then
        x, y = Raster.viewToMap(view, px, py, width, height)
    else
        x, y = px / width, py / height
    end
    local inside = px >= 0 and px <= width and py >= 0 and py <= height
    return clamp01(x), clamp01(y), inside, px, py
end

function Raster.mapToCanvas(nx, ny, width, height)
    return nx * width, ny * height
end

function Raster.canvasToMap(px, py, width, height)
    return px / width, py / height
end

-- Yards to canvas pixels. `W` is the zone's yards per normalized unit in x
-- (zone.__W); by the aspect fact above, height / H gives the same answer. With a
-- view, `width` is the zoomed width (canvas width times zoom).
function Raster.yardsToPixels(yd, width, W)
    return yd * width / W
end

-- Clipping to the canvas ------------------------------------------------------------------
--
-- Zoomed, most of the art and of every shape lies outside the canvas. Rather than
-- trust frame clipping alone, everything drawn is cut to the canvas rectangle
-- (0, 0)-(w, h) here first.

-- A rectangle cut to the canvas: x, y, w, h, or nil when none of it is inside.
function Raster.clipRect(x, y, w, h, cw, ch)
    local x2, y2 = x + w, y + h
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if x2 > cw then x2 = cw end
    if y2 > ch then y2 = ch end
    if x2 <= x or y2 <= y then return nil end
    return x, y, x2 - x, y2 - y
end

-- One Liang-Barsky edge test: the narrowed t0, t1, or nil when the segment
-- misses. A plain function rather than a closure, since it runs per line drawn.
local function lbEdge(p, q, t0, t1)
    if p == 0 then
        if q < 0 then return nil end
        return t0, t1
    end
    local r = q / p
    if p < 0 then
        if r > t1 then return nil end
        if r > t0 then t0 = r end
    else
        if r < t0 then return nil end
        if r < t1 then t1 = r end
    end
    return t0, t1
end

-- A segment cut to the canvas (Liang-Barsky): x1, y1, x2, y2, or nil.
function Raster.clipSegment(x1, y1, x2, y2, cw, ch)
    local dx, dy = x2 - x1, y2 - y1
    local t0, t1 = lbEdge(-dx, x1, 0, 1)
    if t0 then t0, t1 = lbEdge(dx, cw - x1, t0, t1) end
    if t0 then t0, t1 = lbEdge(-dy, y1, t0, t1) end
    if t0 then t0, t1 = lbEdge(dy, ch - y1, t0, t1) end
    if not t0 then return nil end
    return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
end

-- Map art through the view ------------------------------------------------------------
--
-- A rectangle of the map art, in art pixels, with the texture showing from 0 to
-- `u` across and 0 to `v` down, placed through the view and cut to the canvas.
-- `sx, sy` are canvas pixels per art pixel at this zoom (canvas size / art size
-- * zoom). Returns the canvas rectangle x, y, w, h and the texture coordinates
-- left, right, top, bottom that show exactly the part left after the cut, or
-- nil when none of it is on the canvas. The base tiles use it with u = v = 1.
function Raster.placeArt(ax, ay, aw, ah, u, v, sx, sy, view, cw, ch)
    local x, y, w, h = ax * sx - view.ox, ay * sy - view.oy, aw * sx, ah * sy
    if w <= 0 or h <= 0 then return nil end
    local px, py, pw, ph = Raster.clipRect(x, y, w, h, cw, ch)
    if not px then return nil end
    return px, py, pw, ph,
        (px - x) / w * u, (px + pw - x) / w * u,
        (py - y) / h * v, (py + ph - y) / h * v
end

-- The discovered areas: overlay tiles ----------------------------------------------
--
-- An overlay is textureWidth x textureHeight art pixels at (offsetX, offsetY),
-- cut into tiles of 256. Tile (row, col) sits at offsetX + col * 256,
-- offsetY + row * 256; the last column and row are only partly filled. Their
-- file is the smallest power of two, at least 16, that holds what is filled, and
-- the texture is cropped to the filled part - both exactly as Blizzard's
-- WorldMapExploration provider (MapExplorationPinMixin:RefreshOverlays) does.

Raster.OVERLAY_TILE = 256

function Raster.overlayFileSize(px)
    local f = 16
    while f < px do f = f * 2 end
    return f
end

-- One tile in art pixels: x, y, w, h, and the right and bottom texture
-- coordinates that crop its file to the filled part. nil for a tile that lies
-- wholly past the overlay's size.
function Raster.overlayTile(offX, offY, texW, texH, row, col, size)
    size = size or Raster.OVERLAY_TILE
    local w, h = texW - col * size, texH - row * size
    if w > size then w = size end
    if h > size then h = size end
    if w <= 0 or h <= 0 then return nil end
    return offX + col * size, offY + row * size, w, h,
        w / Raster.overlayFileSize(w), h / Raster.overlayFileSize(h)
end

-- Fill: horizontal strips ---------------------------------------------------------------
--
-- There is no polygon fill primitive (M3), so a shape is rasterised into
-- horizontal strips, one colour texture each: for every scanline at `pitch`
-- spacing from the shape's top to its bottom, the x crossings with every edge
-- (even-odd), sorted, emitted as runs. Rebuilt only when the shape changes.

-- No shape ever uses more than ~120 strips; small shapes are solid at 2 px.
function Raster.pitchFor(heightPx)
    local p = ceil(heightPx / 120)
    if p < 2 then p = 2 end
    return p
end

-- `out` is reused: its entries are tables { x, y, w, h } in canvas pixels, and
-- entries past the new count are dropped. Returns out, count.
local function emit(out, count, x, y, w, h)
    count = count + 1
    local e = out[count]
    if not e then
        e = {}
        out[count] = e
    end
    e.x, e.y, e.w, e.h = x, y, w, h
    return count
end

local function trim(out, count)
    for i = #out, count + 1, -1 do out[i] = nil end
    return out, count
end

local xs = {}      -- crossings on one scanline, reused

-- `poly` is flat pixel coordinates { x1, y1, x2, y2, ... }.
function Raster.strips(poly, pitch, out)
    out = out or {}
    local count = 0
    local n = #poly - #poly % 2
    if n < 6 then return trim(out, 0) end

    local minY, maxY = huge, -huge
    for i = 2, n, 2 do
        if poly[i] < minY then minY = poly[i] end
        if poly[i] > maxY then maxY = poly[i] end
    end
    if maxY <= minY then return trim(out, 0) end

    local rows = ceil((maxY - minY) / pitch - 1e-9)
    for r = 0, rows - 1 do
        local y0 = minY + r * pitch
        local h = pitch
        if y0 + h > maxY then h = maxY - y0 end
        local ym = y0 + h / 2

        local k = 0
        local jx, jy = poly[n - 1], poly[n]
        for i = 1, n, 2 do
            local ix, iy = poly[i], poly[i + 1]
            if (iy > ym) ~= (jy > ym) then
                local x = ix + (ym - iy) * (jx - ix) / (jy - iy)
                -- Insertion sort as it goes: at most 32 crossings.
                k = k + 1
                local p = k
                while p > 1 and xs[p - 1] > x do
                    xs[p] = xs[p - 1]
                    p = p - 1
                end
                xs[p] = x
            end
            jx, jy = ix, iy
        end
        for c = 1, k - 1, 2 do
            if xs[c + 1] > xs[c] then
                count = emit(out, count, xs[c], y0, xs[c + 1] - xs[c], h)
            end
        end
    end
    return trim(out, count)
end

-- The same for a circle, from its analytic half-width at each scanline.
function Raster.circleStrips(cx, cy, r, pitch, out)
    out = out or {}
    local count = 0
    if not (r and r > 0) then return trim(out, 0) end
    local top, bottom = cy - r, cy + r
    local rows = ceil((bottom - top) / pitch - 1e-9)
    for i = 0, rows - 1 do
        local y0 = top + i * pitch
        local h = pitch
        if y0 + h > bottom then h = bottom - y0 end
        local dy = y0 + h / 2 - cy
        local d2 = r * r - dy * dy
        if d2 > 0 then
            local hw = sqrt(d2)
            count = emit(out, count, cx - hw, y0, 2 * hw, h)
        end
    end
    return trim(out, count)
end

-- Outlines and bands ----------------------------------------------------------------------

-- Twice the signed area; its sign is the winding. Frame-independent: y-down
-- mirrors both the shape and the normals below, so outward stays outward.
function Raster.signedArea(poly)
    local n = #poly - #poly % 2
    local a = 0
    local jx, jy = poly[n - 1], poly[n]
    for i = 1, n, 2 do
        local ix, iy = poly[i], poly[i + 1]
        a = a + (jx * iy - ix * jy)
        jx, jy = ix, iy
    end
    return a
end

local function seg(out, count, x1, y1, x2, y2)
    count = count + 1
    local e = out[count]
    if not e then
        e = {}
        out[count] = e
    end
    e[1], e[2], e[3], e[4] = x1, y1, x2, y2
    return count
end

-- The polygon's edges as segments { x1, y1, x2, y2 }.
function Raster.outline(poly, out)
    out = out or {}
    local count = 0
    local n = #poly - #poly % 2
    if n < 4 then return trim(out, 0) end
    local last = n >= 6 and n or n - 2         -- two corners: one segment, not a loop
    for i = 1, last, 2 do
        local j = i + 2
        if j > n then j = 1 end
        count = seg(out, count, poly[i], poly[i + 1], poly[j], poly[j + 1])
    end
    return trim(out, count)
end

-- The falloff band: each edge shifted along its outward normal by `offset`, and
-- adjacent shifted edges joined by a straight segment between their nearest
-- endpoints - a bevel rather than a true arc, which is visibly fine at these
-- sizes. The winding comes from the signed area, so either winding works.
function Raster.band(poly, offset, out)
    out = out or {}
    local count = 0
    local n = #poly - #poly % 2
    if n < 6 or not offset or offset <= 0 then return trim(out, 0) end
    local sgn = Raster.signedArea(poly) >= 0 and 1 or -1

    local firstX, firstY, prevX, prevY
    for i = 1, n, 2 do
        local j = i + 2
        if j > n then j = 1 end
        local x1, y1, x2, y2 = poly[i], poly[i + 1], poly[j], poly[j + 1]
        local ex, ey = x2 - x1, y2 - y1
        local len = sqrt(ex * ex + ey * ey)
        if len > 0 then
            local nx, ny = sgn * ey / len * offset, -sgn * ex / len * offset
            local ax, ay, bx, by = x1 + nx, y1 + ny, x2 + nx, y2 + ny
            if prevX then count = seg(out, count, prevX, prevY, ax, ay) end
            count = seg(out, count, ax, ay, bx, by)
            if not firstX then firstX, firstY = ax, ay end
            prevX, prevY = bx, by
        end
    end
    if prevX and firstX then count = seg(out, count, prevX, prevY, firstX, firstY) end
    return trim(out, count)
end

-- A circle as an `n`-segment ring.
function Raster.ring(cx, cy, r, n, out)
    out = out or {}
    local count = 0
    n = n or 32
    if not (r and r > 0) then return trim(out, 0) end
    local px, py = cx + r, cy
    for i = 1, n do
        local a = i / n * 2 * math.pi
        local x, y = cx + r * math.cos(a), cy + r * math.sin(a)
        count = seg(out, count, px, py, x, y)
        px, py = x, y
    end
    return trim(out, count)
end

-- Hit testing -----------------------------------------------------------------------------
--
-- Done arithmetically on a click rather than by making each strip clickable: a
-- texture is not a mouse target, and a frame per strip would be hundreds of
-- frames for one busy zone.

function Raster.pointInPolygon(poly, x, y)
    local n = #poly - #poly % 2
    if n < 6 then return false end
    local inside = false
    local jx, jy = poly[n - 1], poly[n]
    for i = 1, n, 2 do
        local ix, iy = poly[i], poly[i + 1]
        if (iy > y) ~= (jy > y) then
            if x < ix + (y - iy) * (jx - ix) / (jy - iy) then inside = not inside end
        end
        jx, jy = ix, iy
    end
    return inside
end

function Raster.distToSegment(px, py, ax, ay, bx, by)
    local ex, ey = bx - ax, by - ay
    local wx, wy = px - ax, py - ay
    local len2 = ex * ex + ey * ey
    local t = 0
    if len2 > 0 then
        t = (wx * ex + wy * ey) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local dx, dy = wx - t * ex, wy - t * ey
    return sqrt(dx * dx + dy * dy)
end

-- Distance from a point to the nearest edge of a polygon (closed when it has
-- three corners or more).
function Raster.distToOutline(poly, x, y)
    local n = #poly - #poly % 2
    if n < 4 then
        if n == 2 then return sqrt((x - poly[1]) ^ 2 + (y - poly[2]) ^ 2) end
        return huge
    end
    local best = huge
    local last = n >= 6 and n or n - 2
    for i = 1, last, 2 do
        local j = i + 2
        if j > n then j = 1 end
        local d = Raster.distToSegment(x, y, poly[i], poly[i + 1], poly[j], poly[j + 1])
        if d < best then best = d end
    end
    return best
end

-- The index (1-based, per corner) of the corner within `radius` of the point,
-- nearest first, or nil.
function Raster.nearestCorner(poly, x, y, radius)
    local best, bestD = nil, radius or huge
    for i = 1, #poly - 1, 2 do
        local dx, dy = poly[i] - x, poly[i + 1] - y
        local d = sqrt(dx * dx + dy * dy)
        if d <= bestD then best, bestD = (i + 1) / 2, d end
    end
    return best, bestD
end

-- Editing a polygon's corners (feedback-1.md item 4) ------------------------------------
--
-- Edge k runs from corner k to corner k + 1, and the last one back to corner 1.
-- An edge shorter than `minLen` has no midpoint handle: it would sit on top of
-- its own corners, and a corner is the more useful thing to grab there.

function Raster.edgeMidpoint(poly, k)
    local n = #poly - #poly % 2
    local i = 2 * k - 1
    local j = i + 2
    if j > n then j = 1 end
    local ax, ay, bx, by = poly[i], poly[i + 1], poly[j], poly[j + 1]
    local dx, dy = bx - ax, by - ay
    return (ax + bx) / 2, (ay + by) / 2, sqrt(dx * dx + dy * dy)
end

-- The edge whose midpoint handle is within `radius` of the point, or nil. Only
-- closed shapes (three corners or more) have them.
function Raster.nearestMidpoint(poly, x, y, radius, minLen)
    local n = #poly - #poly % 2
    if n < 6 then return nil end
    local best, bestD = nil, radius or huge
    for k = 1, n / 2 do
        local mx, my, len = Raster.edgeMidpoint(poly, k)
        if len >= (minLen or 0) then
            local dx, dy = mx - x, my - y
            local d = sqrt(dx * dx + dy * dy)
            if d <= bestD then best, bestD = k, d end
        end
    end
    return best, bestD
end

-- A new corner (x, y) after corner `after`, in place. Returns its index.
function Raster.insertCorner(corners, after, x, y)
    local at = 2 * after + 1
    table.insert(corners, at, x)
    table.insert(corners, at + 1, y)
    return after + 1
end

-- Removes corner `index`, in place.
function Raster.removeCorner(corners, index)
    table.remove(corners, 2 * index)
    table.remove(corners, 2 * index - 1)
end
