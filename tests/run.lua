-- Dynamic Ambiance - headless test suite
--
-- Run:  luajit tests/run.lua        (5.1 semantics, which is what the client is)
--       lua    tests/run.lua        (5.4; also passes)
--
-- What it can and cannot tell you. It exercises the addon's own logic against a
-- stand-in client: the blend, the ease, the write cap, the combat freeze, the
-- restore, and the guards around the three client behaviours that are known to
-- bite here - a nilable position, an event name that raises on registration, a
-- value that comes back secret. It cannot tell you that the screen changed, that
-- the CVar names are right, or that a write is permitted in combat. Those are
-- measurements, and they live in docs/DEVELOPMENT.md.

if jit then jit.off() end

local ROOT = (...) and arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]") or "."
package.path = ROOT .. "/tests/?.lua;" .. package.path

local wow = require("wow_stub")

-- Tiny harness -------------------------------------------------------------------

local passed, failed = 0, 0
local current

local function check(ok, msg)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print(("  FAIL  %s: %s"):format(current, msg))
    end
    return ok
end

local function near(a, b, tol)
    return type(a) == "number" and math.abs(a - b) <= (tol or 0.05)
end

local function test(name, fn)
    current = name
    wow.install()
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        print(("  FAIL  %s: raised: %s"):format(name, tostring(err)))
    else
        print(("  ok    %s"):format(name))
    end
end

-- Zones the behavioural tests are written against. They are a fixture, not the
-- shipped config: a test that asserts on whatever Config.lua happens to contain
-- breaks every time someone re-authors their zones, which is the one thing that
-- file is for. The shipped config gets a structural test of its own at the end.
local FIXTURE = {
    ["Duskwood"] = {
        contrast = 60, brightness = 40,
        areas = {
            { subzone = "Raven Hill", contrast = 65, brightness = 32 },
            { subzone = "Darkshire",  contrast = 55, brightness = 48 },
        },
    },
    ["Westfall"] = { contrast = 50, brightness = 55 },
}

local function copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = copy(v) end
    return c
end

local function load()
    local ns = wow.load(ROOT)
    ns.Config.zones = copy(FIXTURE)      -- tuning and baseline stay the real ones
    return ns
end

-- Simulate `seconds` of frames at `fps`, driving the addon's OnUpdate the way the
-- client would.
local function frames(ns, seconds, fps)
    fps = fps or 60
    local dt = 1 / fps
    local n = math.floor(seconds * fps)
    for _ = 1, n do ns.onUpdate(ns.frame, dt) end
end

local function login(ns)
    ns.frame:Fire("PLAYER_LOGIN")
end

-- Placed areas need their map's scale (design/ui/DESIGN-ui.md 3.2): the live loop
-- reads it on a zone change, so a zone handed straight to evaluate gets the same
-- treatment here. Legacy normalized radii are converted to yards by it, which
-- is also what a zone authored before yards gets in game.
local function placed(ns, zone)
    zone.map = zone.map or 1429
    ns.prepareZone(zone, "fixture")
    return zone
end

-- Field-for-field equality, ignoring the engine's `__` caches.
local function sameTable(a, b, path)
    path = path or "zone"
    if type(a) ~= "table" or type(b) ~= "table" then
        if a ~= b then return false, ("%s: %s vs %s"):format(path, tostring(a), tostring(b)) end
        return true
    end
    for k, v in pairs(a) do
        if not (type(k) == "string" and k:sub(1, 2) == "__") then
            local ok, why = sameTable(v, b[k], path .. "." .. tostring(k))
            if not ok then return false, why end
        end
    end
    for k in pairs(b) do
        if not (type(k) == "string" and k:sub(1, 2) == "__") and a[k] == nil then
            return false, path .. "." .. tostring(k) .. " appeared"
        end
    end
    return true
end

local NASTY = "a~b:c|d%e\nf\rg\t%7E"

local function every4Kinds()
    local poly = {}
    for k = 0, 31 do
        local ang = k / 32 * 2 * math.pi
        poly[#poly + 1] = tonumber(("%.4f"):format(0.5 + 0.05 * math.cos(ang)))
        poly[#poly + 1] = tonumber(("%.4f"):format(0.5 + 0.05 * math.sin(ang)))
    end
    return {
        contrast = 35, brightness = 78.25, gamma = 1.125, map = 1429,
        meta = { name = NASTY, description = NASTY, notes = NASTY .. "\nsecond line",
                 version = 3, author = NASTY, date = NASTY },
        areas = {
            { subzone = NASTY, name = NASTY, notes = NASTY, priority = 10,
              contrast = 55, brightness = 45, indoors = true },
            { name = NASTY, notes = NASTY, x = 0.492, y = 0.4143, innerYards = 11.3,
              falloffYards = 56.7, priority = 20, contrast = 85, brightness = 25,
              gamma = 0.8, indoors = false },
            { name = NASTY, notes = NASTY, corners = poly, falloffYards = 25, priority = 10,
              contrast = 78, brightness = 18 },
            { name = NASTY, notes = NASTY, priority = 55, gamma = 2.75, indoors = true },
            -- Empty numeric fields: inherits everything but gamma.
            { subzone = "Plain", priority = 5, gamma = 0.3 },
        },
    }
end

-- Tests ------------------------------------------------------------------------

test("loads, registers its events and its slash command", function()
    local ns = load()
    check(ns.frame ~= nil, "no frame")
    check(SlashCmdList.DYNAMICAMBIANCE ~= nil, "slash command not registered")
    check(SLASH_DYNAMICAMBIANCE2 == "/amb", "short alias missing")
    for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "ZONE_CHANGED",
                         "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA",
                         "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
                         "PLAYER_REGEN_ENABLED" }) do
        check(ns.frame.events[e], "event not registered: " .. e)
    end
    check(not ns.frame:IsShown(), "loop running before login")
    check(#wow.writes == 0, "wrote a CVar before login")
end)

test("an event name this client refuses does not take the file down", function()
    wow.eventRefusals.ZONE_CHANGED_INDOORS = true
    local ns = load()
    check(ns.frame.events.ZONE_CHANGED_INDOORS == nil, "refused event registered anyway")
    check(ns.frame.events.ZONE_CHANGED == true, "a later registration was lost")
    check(SlashCmdList.DYNAMICAMBIANCE ~= nil, "the rest of the file did not run")
    check(wow.chatMatches("not available on this client") ~= nil, "refusal not reported")
end)

test("login starts from what is on screen, not from the config baseline", function()
    wow.cvars.Brightness = "31.00"
    wow.cvars.Contrast   = "72.00"
    local ns = load()
    login(ns)
    check(near(ns.state.curB, 31), "did not adopt the on-screen brightness: " .. ns.state.curB)
    check(near(ns.state.curC, 72), "did not adopt the on-screen contrast: " .. ns.state.curC)
    check(ns.frame:IsShown(), "loop not running after login")
end)

test("an unconfigured zone eases to the baseline", function()
    wow.cvars.Brightness = "10.00"
    wow.cvars.Contrast   = "90.00"
    wow.zone = "Somewhere Nobody Configured"
    local ns = load()
    login(ns)
    frames(ns, 4)
    check(near(ns.state.tgtB, 50), "target brightness " .. ns.state.tgtB)
    check(near(wow.lastWrite("Brightness"), 50, 0.01), "wrote " .. tostring(wow.lastWrite("Brightness")))
    check(near(wow.lastWrite("Contrast"), 50, 0.01), "wrote " .. tostring(wow.lastWrite("Contrast")))
end)

test("a configured zone applies its values", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(near(ns.state.tgtC, 60), "contrast target " .. ns.state.tgtC)
    check(near(ns.state.tgtB, 40), "brightness target " .. ns.state.tgtB)
    check(near(wow.lastWrite("Contrast"), 60, 0.01), "contrast written " .. tostring(wow.lastWrite("Contrast")))
    check(near(wow.lastWrite("Brightness"), 40, 0.01), "brightness written " .. tostring(wow.lastWrite("Brightness")))
end)

test("a subzone area overrides its zone, and leaving it returns", function()
    wow.zone, wow.subzone = "Duskwood", "Darkshire"
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 4)
    check(near(ns.state.tgtC, 55), "in Darkshire, contrast " .. ns.state.tgtC)
    check(near(ns.state.tgtB, 48), "in Darkshire, brightness " .. ns.state.tgtB)

    wow.subzone = ""
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 4)
    check(near(ns.state.tgtC, 60), "back in the zone, contrast " .. ns.state.tgtC)
    check(near(ns.state.tgtB, 40), "back in the zone, brightness " .. ns.state.tgtB)
end)

test("the boundary is eased, not snapped", function()
    wow.zone, wow.subzone = "Duskwood", ""
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 4)                       -- settled on the zone default, b = 40

    wow.subzone = "Raven Hill"          -- b = 32, a hard coarse jump
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 1 / 60 * 2)              -- two frames in
    local justAfter = ns.state.curB
    check(justAfter > 39, "brightness jumped on the first frames: " .. justAfter)
    frames(ns, 0.5)
    check(ns.state.curB < justAfter, "not moving toward the new value")
    frames(ns, 4)
    check(near(ns.state.curB, 32), "never arrived: " .. ns.state.curB)
end)

-- Blending ---------------------------------------------------------------------

test("positional weight: inside, outside and the falloff band", function()
    local ns = load()
    local zone = {
        contrast = 50, brightness = 50,
        areas = { { x = 0.5, y = 0.5, inner = 0.05, falloff = 0.15,
                    contrast = 90, brightness = 10 } },
    }
    placed(ns, zone)
    local c, b = ns.evaluate(zone, nil, 0.5, 0.5)
    check(near(c, 90) and near(b, 10), "at the centre: " .. c .. "/" .. b)

    c, b = ns.evaluate(zone, nil, 0.5, 0.54)          -- still inside inner
    check(near(c, 90), "inside the inner radius: " .. c)

    c, b = ns.evaluate(zone, nil, 0.9, 0.9)           -- far outside
    check(near(c, 50) and near(b, 50), "outside the falloff: " .. c .. "/" .. b)

    -- Monotone across the band, and strictly between the two values.
    local prev = 91
    for i = 0, 20 do
        local d = 0.05 + (0.15 - 0.05) * (i / 20)
        local v = ns.evaluate(zone, nil, 0.5 + d, 0.5)
        check(v <= prev + 1e-9, "not monotone at d=" .. d .. ": " .. v .. " after " .. prev)
        check(v >= 50 - 1e-9 and v <= 90 + 1e-9, "outside the two values at d=" .. d)
        prev = v
    end
end)

test("overlapping areas do not produce a visible step anywhere", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = {
        contrast = 50, brightness = 50,
        areas = {
            { x = 0.40, y = 0.5, inner = 0.02, falloff = 0.12, contrast = 80 },
            { x = 0.60, y = 0.5, inner = 0.02, falloff = 0.12, contrast = 20 },
        },
    }
    placed(ns, zone)
    -- Priority decides who wins where they overlap, but the handover still has to
    -- be smooth - a discontinuity is a flicker on screen.
    local prev = ns.evaluate(zone, nil, 0.20, 0.5)
    local biggest = 0
    for i = 1, 800 do
        local x = 0.20 + 0.60 * (i / 800)
        local v = ns.evaluate(zone, nil, x, 0.5)
        biggest = math.max(biggest, math.abs(v - prev))
        prev = v
    end
    check(biggest < 0.5, "a step of " .. biggest .. " on a 0-100 scale is a visible jump")
end)

test("three overlapping areas stay inside the values they blend", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = {
        contrast = 50, brightness = 50,
        areas = {
            { x = 0.50, y = 0.45, inner = 0.01, falloff = 0.10, contrast = 80 },
            { x = 0.45, y = 0.53, inner = 0.01, falloff = 0.10, contrast = 65 },
            { x = 0.55, y = 0.53, inner = 0.01, falloff = 0.10, contrast = 20 },
        },
    }
    placed(ns, zone)
    for i = 0, 40 do
        for j = 0, 40 do
            local v = ns.evaluate(zone, nil, 0.40 + i * 0.005, 0.40 + j * 0.005)
            check(v >= 20 - 1e-9 and v <= 80 + 1e-9, "left the hull: " .. v)
        end
    end
end)

-- Priority ----------------------------------------------------------------------

test("the highest priority layer present wins, whatever the file order", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = {
        contrast = 10, brightness = 10,
        areas = {
            { subzone = "Town", priority = 60, contrast = 60 },
            { subzone = "Town", priority = 20, contrast = 20 },
            { subzone = "Town", priority = 40, contrast = 40 },
        },
    }
    check(near((ns.evaluate(zone, "Town", nil, nil, false)), 60),
        "should be the priority-60 layer")
end)

test("equal priorities keep file order, later wins", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = {
        contrast = 10, brightness = 10,
        areas = {
            { subzone = "Town", priority = 20, contrast = 20 },
            { subzone = "Town", priority = 20, contrast = 33 },
        },
    }
    check(near((ns.evaluate(zone, "Town", nil, nil, false)), 33), "later entry should win")
end)

test("a lower-priority layer still shows through where the higher one is absent", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = {
        contrast = 10, brightness = 10,
        areas = {
            { subzone = "Town",    priority = 20, contrast = 20 },
            { subzone = "The Inn", priority = 60, contrast = 60 },
        },
    }
    check(near((ns.evaluate(zone, "Town", nil, nil, false)), 20), "in Town")
    check(near((ns.evaluate(zone, "The Inn", nil, nil, false)), 60), "in the Inn")
    check(near((ns.evaluate(zone, "Elsewhere", nil, nil, false)), 10), "neither")
end)

test("a partial-weight layer fades over what is underneath, not over the baseline", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = {
        contrast = 0, brightness = 0,
        areas = {
            -- Covers the whole zone at low priority.
            { priority = 10, contrast = 40 },
            -- Fades in on top of it.
            { x = 0.5, y = 0.5, inner = 0.0, falloff = 0.10, priority = 20, contrast = 100 },
        },
    }
    placed(ns, zone)
    local far = ns.evaluate(zone, nil, 0.9, 0.9, false)
    check(near(far, 40), "outside the circle it should be the layer below: " .. far)
    local at = ns.evaluate(zone, nil, 0.5, 0.5, false)
    check(near(at, 100), "at the centre: " .. at)
    -- Half way through the falloff it must sit between 40 and 100, never between
    -- 0 and 100 - that would mean it faded over the baseline instead.
    local mid = ns.evaluate(zone, nil, 0.55, 0.5, false)
    check(mid > 40 and mid < 100, "mid-falloff should be between 40 and 100, got " .. mid)
end)

test("the chapel stairway bug: indoors outranks the subzone it overlaps", function()
    -- Measured 2026-09-20: on the chapel steps the client reports the subzone
    -- Northshire Valley while IsIndoors() is already true. Indoors has to win.
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90, priority = 50 }
    local zone = {
        contrast = 35, brightness = 78,
        areas = {
            { subzone = "Northshire Valley", priority = 10, contrast = 55, brightness = 45 },
            { subzone = "Hall of Arms", indoors = true, priority = 60,
              contrast = 70, brightness = 58 },
        },
    }
    local c, b = ns.evaluate(zone, "Northshire Valley", nil, nil, false)
    check(near(c, 55) and near(b, 45), "outdoors in the valley: " .. c .. "/" .. b)

    c, b = ns.evaluate(zone, "Northshire Valley", nil, nil, true)
    check(near(c, 42) and near(b, 90),
        "on the stairway, indoors, still reported as the valley: " .. c .. "/" .. b)

    c, b = ns.evaluate(zone, "Main Hall", nil, nil, true)
    check(near(c, 42) and near(b, 90), "in the chapel: " .. c .. "/" .. b)

    c, b = ns.evaluate(zone, "Hall of Arms", nil, nil, true)
    check(near(c, 70) and near(b, 58), "in the named room: " .. c .. "/" .. b)
end)

-- Indoors -----------------------------------------------------------------------
--
-- Measured 2026-09-20: inside the Northshire chapel the position read returns an
-- ordinary point on the parent map, the same space as the grass outside. So the
-- interior case is not a radius problem, and these are the tests that pin the
-- distinction a coordinate cannot make.

test("the indoor rule replaces the base layer, and only indoors", function()
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90 }
    local zone = { contrast = 60, brightness = 40 }

    local c, b = ns.evaluate(zone, nil, nil, nil, false)
    check(near(c, 60) and near(b, 40), "outdoors should be the zone value: " .. c .. "/" .. b)

    c, b = ns.evaluate(zone, nil, nil, nil, true)
    check(near(c, 42) and near(b, 90), "indoors should be the rule: " .. c .. "/" .. b)
end)

test("the same coordinate gives a different answer inside and out", function()
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90 }
    -- The real one, from the chapel capture: an ordinary Elwynn point.
    local zone = { contrast = 35, brightness = 78, map = 1429 }
    local outside = select(2, ns.evaluate(zone, nil, 0.4905, 0.4096, false))
    local inside  = select(2, ns.evaluate(zone, nil, 0.4905, 0.4096, true))
    check(near(outside, 78), "outside the chapel: " .. outside)
    check(near(inside, 90), "inside the chapel at the same x,y: " .. inside)
    check(outside ~= inside, "no radius could have told these apart - that is the point")
end)

test("a zone can override the indoor rule, or opt out of it", function()
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90 }

    local own = { contrast = 60, brightness = 40, indoors = { brightness = 66 } }
    local c, b = ns.evaluate(own, nil, nil, nil, true)
    check(near(b, 66), "zone's own indoor brightness: " .. b)
    check(near(c, 60), "contrast should fall through to the zone: " .. c)

    local optOut = { contrast = 60, brightness = 40, indoors = false }
    c, b = ns.evaluate(optOut, nil, nil, nil, true)
    check(near(b, 40), "indoors = false should ignore the global rule, got " .. b)
end)

test("an area gated to indoors cannot fire outside, and the reverse", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = {
        contrast = 50, brightness = 50,
        areas = {
            { subzone = "Hall of Arms", indoors = true,  contrast = 70 },
            { subzone = "Hall of Arms", indoors = false, contrast = 20 },
        },
    }
    check(near((ns.evaluate(zone, "Hall of Arms", nil, nil, true)), 70), "indoors gate")
    check(near((ns.evaluate(zone, "Hall of Arms", nil, nil, false)), 20), "outdoors gate")
    check(near((ns.evaluate(zone, "Somewhere Else", nil, nil, true)), 50), "neither")
end)

test("a room outranks the indoor rule only if its priority says so", function()
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90, priority = 50 }
    local zone = {
        contrast = 35, brightness = 78,
        areas = { { subzone = "Hall of Arms", indoors = true, contrast = 70 } },
    }

    -- No priority means priority 0, below the indoor rule. The rule wins, and
    -- that is the right answer: a room that has not asked to outrank the general
    -- interior setting should not silently do so.
    local c, b = ns.evaluate(zone, "Hall of Arms", nil, nil, true)
    check(near(c, 42) and near(b, 90), "unprioritised room beat the rule: " .. c .. "/" .. b)

    -- Give it one and it takes over, inheriting brightness from the layer below
    -- because it states only a contrast.
    zone.areas[1].priority = 60
    zone.__layers = nil                      -- config changed; drop the cache
    c, b = ns.evaluate(zone, "Hall of Arms", nil, nil, true)
    check(near(c, 70), "the room's own contrast should win: " .. c)
    check(near(b, 90), "brightness should come from the indoor rule, not the zone: " .. b)
end)

test("the indoor rule still allocates nothing", function()
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90 }
    local zone = { contrast = 50, brightness = 50,
        areas = { { subzone = "Hall of Arms", indoors = true, contrast = 70 } } }
    ns.evaluate(zone, "Hall of Arms", nil, nil, true)
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 2000 do ns.evaluate(zone, "Hall of Arms", nil, nil, true) end
    local delta = (collectgarbage("count") - before) * 1024
    collectgarbage("restart")
    check(delta < 64, ("%0.1f bytes over 2000 calls"):format(delta))
end)

test("walking indoors changes the target through the live loop", function()
    wow.zone, wow.subzone = "Duskwood", ""
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90 }
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(near(ns.state.curB, 40), "outdoors: " .. ns.state.curB)

    wow.isIndoors = true
    ns.frame:Fire("ZONE_CHANGED_INDOORS")
    frames(ns, 4)
    check(near(ns.state.curB, 90), "indoors: " .. ns.state.curB)
    check(ns.state.indoors == true, "did not record the indoor state")

    wow.isIndoors = false
    ns.frame:Fire("ZONE_CHANGED_INDOORS")
    frames(ns, 4)
    check(near(ns.state.curB, 40), "back outdoors: " .. ns.state.curB)
end)

test("an area inherits whatever it does not state", function()
    local ns = load()
    local zone = {
        contrast = 61, brightness = 39,
        areas = { { x = 0.5, y = 0.5, inner = 0.1, falloff = 0.2, brightness = 12 } },
    }
    placed(ns, zone)
    local c, b = ns.evaluate(zone, nil, 0.5, 0.5)
    check(near(c, 61), "contrast should fall through to the zone, got " .. c)
    check(near(b, 12), "brightness should be the area's, got " .. b)
end)

test("evaluate allocates nothing", function()
    local ns = load()
    local zone = { contrast = 50, brightness = 50, areas = {} }
    for i = 1, 12 do
        zone.areas[i] = { x = i / 13, y = 0.5, inner = 0.02, falloff = 0.2,
                          contrast = 40 + i, brightness = 60 - i }
    end
    placed(ns, zone)
    check(ns.evaluate(zone, nil, 0.5, 0.5) ~= 50, "the circles are not being evaluated at all")
    ns.evaluate(zone, nil, 0.5, 0.5)
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 2000 do ns.evaluate(zone, nil, 0.5, 0.5) end
    local delta = (collectgarbage("count") - before) * 1024
    collectgarbage("restart")
    check(delta < 64, ("%0.1f bytes allocated over 2000 calls"):format(delta))
end)

-- Position reads ---------------------------------------------------------------

test("a position the client will not give falls back to the subzone", function()
    local ns = load()
    ns.Config.zones["Testland"] = {
        contrast = 70, brightness = 30, map = 99,
        areas = { { x = 0.5, y = 0.5, inner = 0.05, falloff = 0.1, contrast = 10 } },
    }
    wow.zone, wow.mapID, wow.position = "Testland", 99, nil
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(near(ns.state.tgtC, 70), "should be the zone default, got " .. ns.state.tgtC)
end)

test("a Vector2DMixin-shaped position is read the same as two numbers", function()
    local ns = load()
    ns.Config.zones["Testland"] = {
        contrast = 70, brightness = 30, map = 99,
        areas = { { x = 0.5, y = 0.5, inner = 0.05, falloff = 0.1, contrast = 10 } },
    }
    wow.zone, wow.mapID = "Testland", 99
    wow.position, wow.positionShape = { 0.5, 0.5 }, "vector"
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(near(ns.state.tgtC, 10), "should be the area value, got " .. ns.state.tgtC)
end)

test("coordinates recorded against another map are skipped, not misapplied", function()
    local ns = load()
    ns.Config.zones["Testland"] = {
        contrast = 70, brightness = 30, map = 99,
        areas = { { x = 0.5, y = 0.5, inner = 0.05, falloff = 0.1, contrast = 10 } },
    }
    wow.zone, wow.mapID, wow.position = "Testland", 1234, { 0.5, 0.5 }
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(near(ns.state.tgtC, 70), "applied coordinates from the wrong map: " .. ns.state.tgtC)
    check(wow.chatMatches("positional areas skipped") ~= nil, "did not say why")
end)

test("a zone with no positional areas never reads a position", function()
    local ns = load()
    local reads = 0
    local real = C_Map.GetPlayerMapPosition
    C_Map.GetPlayerMapPosition = function(...) reads = reads + 1; return real(...) end
    wow.zone = "Duskwood"                      -- subzone areas only
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 3)
    check(reads == 0, reads .. " position reads for a zone that does not need one")
end)

-- The loop ---------------------------------------------------------------------

test("the write rate is capped", function()
    wow.cvars.Brightness, wow.cvars.Contrast = "0.00", "0.00"
    wow.zone = "Duskwood"
    local ns = load()                       -- login adopts 0/0, so the ease is long
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    local before = wow.writesTo("Brightness")
    frames(ns, 5, 240)                      -- five seconds at 240 fps
    local written = wow.writesTo("Brightness") - before
    local cap = ns.Config.tuning.writeHz * 5 + 2
    check(written > 10, "only " .. written .. " writes - the ease is not writing")
    check(written <= cap, written .. " writes in 5s, cap is " .. cap)
end)

test("a stationary player at the target generates no writes", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 5)
    local settledAt = #wow.writes
    frames(ns, 10)
    check(#wow.writes == settledAt, (#wow.writes - settledAt) .. " writes while standing still")
    check(near(wow.lastWrite("Brightness"), 40, 0.01),
        "and it did not land on the target: " .. tostring(wow.lastWrite("Brightness")))
end)

test("the ease keeps running in combat, because writes are permitted here", function()
    wow.cvars.Brightness, wow.cvars.Contrast = "50.00", "50.00"
    wow.zone = "Duskwood"
    local ns = load()
    check(ns.Config.tuning.freezeInCombat == false,
        "the shipped default should be off - measured 2026-09-20, writes work in combat")
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    ns.frame:Fire("PLAYER_REGEN_DISABLED")
    frames(ns, 4)
    check(near(ns.state.curB, 40), "the ease stopped in combat: " .. ns.state.curB)
end)

test("freezeInCombat = true still freezes, for a build that starts refusing", function()
    wow.cvars.Brightness, wow.cvars.Contrast = "50.00", "50.00"
    wow.zone = "Duskwood"
    local ns = load()
    ns.Config.tuning.freezeInCombat = true
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 0.2)
    local mid = ns.state.curB
    check(mid < 50 and mid > 40, "should be mid-ease, is " .. mid)

    ns.frame:Fire("PLAYER_REGEN_DISABLED")
    local writes = #wow.writes
    frames(ns, 5)
    check(ns.state.curB == mid, "kept easing in combat: " .. ns.state.curB)
    check(#wow.writes == writes, (#wow.writes - writes) .. " writes in combat")

    ns.frame:Fire("PLAYER_REGEN_ENABLED")
    frames(ns, 4)
    check(near(ns.state.curB, 40), "did not resume: " .. ns.state.curB)
end)

test("logging out restores the declared baseline exactly", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(near(wow.lastWrite("Brightness"), 40, 0.01), "not in Duskwood values before logout")
    ns.frame:Fire("PLAYER_LOGOUT")
    check(near(wow.lastWrite("Brightness"), 50, 0.001),
        "left the screen at " .. tostring(wow.lastWrite("Brightness")))
    check(near(wow.lastWrite("Contrast"), 50, 0.001),
        "left the screen at " .. tostring(wow.lastWrite("Contrast")))
end)

-- Gamma, the third axis ------------------------------------------------------------
--
-- design/ui/DESIGN-ui.md 3.1: Gamma follows exactly the contrast rule, is written
-- only when its own value moves, and is restored with the other two.

local function gammaWriteCount()
    return wow.writesTo("Gamma")
end

test("evaluate returns three values and gamma inherits baseline, zone, area", function()
    local ns = load()
    ns.Config.indoors = nil
    local base = ns.Config.baseline.gamma
    check(base == 1.0, "the shipped baseline gamma should be the measured client default 1.0")

    local c, b, g = ns.evaluate(nil, nil, nil, nil, false)
    check(g == base, "no zone: gamma should be the baseline, got " .. tostring(g))

    local zone = { contrast = 60, brightness = 40, gamma = 1.4,
        areas = { { subzone = "Town", priority = 10, gamma = 0.8 },
                  { subzone = "Inn", priority = 20, contrast = 70 } } }
    c, b, g = ns.evaluate(zone, "Elsewhere", nil, nil, false)
    check(g == 1.4, "zone gamma not applied: " .. tostring(g))

    -- An area that sets gamma only paints gamma alone.
    c, b, g = ns.evaluate(zone, "Town", nil, nil, false)
    check(g == 0.8, "area gamma not applied: " .. tostring(g))
    check(c == 60 and b == 40, "an area setting only gamma moved the other two: " .. c .. "/" .. b)

    -- And one that sets no gamma leaves it at whatever is underneath.
    c, b, g = ns.evaluate(zone, "Inn", nil, nil, false)
    check(g == 1.4 and c == 70, "gamma did not inherit through a contrast-only area")

    -- The indoor rule carries gamma too.
    ns.Config.indoors = { gamma = 2.0, priority = 50 }
    c, b, g = ns.evaluate(zone, "Town", nil, nil, true)
    check(g == 2.0 and c == 60, "the indoor rule's gamma: " .. tostring(g))
end)

test("the gamma epsilon is derived from Config.limits.gamma", function()
    local ns = load()
    local lo, hi = ns.limits("gamma")
    check(lo == 0.3 and hi == 3.0, "shipped gamma limits should be the measured 0.3-3.0")
    local want = ns.Config.tuning.writeEpsilon * (hi - lo) / 100
    check(near(ns.gammaEpsilon(), want, 1e-12), "epsilon " .. ns.gammaEpsilon() .. " vs " .. want)
    ns.Config.limits.gamma = { 0.5, 1.5 }
    check(near(ns.gammaEpsilon(), ns.Config.tuning.writeEpsilon * 1 / 100, 1e-12),
        "the epsilon did not follow a changed limit")
end)

test("a zone that never sets gamma costs no Gamma write before logout", function()
    wow.zone = "Duskwood"
    wow.cvars.Brightness, wow.cvars.Contrast = "0.00", "0.00"
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 6)
    check(wow.writesTo("Brightness") > 10, "the other two did not ease")
    check(gammaWriteCount() <= 1, gammaWriteCount() .. " Gamma writes for a zone with no gamma")
    ns.frame:Fire("PLAYER_LOGOUT")
    check(near(wow.lastWrite("Gamma"), 1.0, 0.001), "logout did not restore Gamma")
end)

test("a zone that sets gamma eases it and writes it through the capped path", function()
    wow.zone = "Duskwood"
    local ns = load()
    ns.Config.zones.Duskwood.gamma = 1.8
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 1 / 60 * 2)
    check(ns.state.curG > 1.0 and ns.state.curG < 1.5, "gamma snapped instead of easing: "
        .. ns.state.curG)
    frames(ns, 5, 240)
    check(near(ns.state.curG, 1.8, 1e-9), "gamma never arrived: " .. ns.state.curG)
    check(near(wow.lastWrite("Gamma"), 1.8, 0.001), "gamma not landed exactly: "
        .. tostring(wow.lastWrite("Gamma")))
    local cap = ns.Config.tuning.writeHz * 5 + 4
    check(gammaWriteCount() <= cap, gammaWriteCount() .. " gamma writes, cap " .. cap)
    local settled = #wow.writes
    frames(ns, 5)
    check(#wow.writes == settled, "kept writing once gamma settled")
end)

test("logging out restores all three baselines", function()
    wow.zone = "Duskwood"
    local ns = load()
    ns.Config.zones.Duskwood.gamma = 2.2
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(near(wow.lastWrite("Gamma"), 2.2, 0.001), "not on the zone's gamma first")
    ns.frame:Fire("PLAYER_LOGOUT")
    check(near(wow.lastWrite("Gamma"), 1.0, 0.001), "Gamma left at " .. tostring(wow.lastWrite("Gamma")))
    check(near(wow.lastWrite("Contrast"), 50, 0.001), "Contrast not restored")
    check(near(wow.lastWrite("Brightness"), 50, 0.001), "Brightness not restored")
end)

test("/amb off eases all three back to the baseline", function()
    wow.zone = "Duskwood"
    local ns = load()
    ns.Config.zones.Duskwood.gamma = 2.0
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    ns.dispatch("off")
    check(ns.frame:IsShown(), "stopped before it eased back")
    frames(ns, 6)
    check(near(wow.lastWrite("Gamma"), 1.0, 0.001), "gamma not eased back: "
        .. tostring(wow.lastWrite("Gamma")))
    check(near(wow.lastWrite("Contrast"), 50, 0.01), "contrast not eased back")
    check(not ns.frame:IsShown(), "still running once all three arrived")
end)

test("/amb try 60 40 0.9 holds three, and clamps a gamma the screen ignores", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    ns.dispatch("try 60 40 0.9")
    frames(ns, 5)
    check(near(ns.state.curC, 60) and near(ns.state.curB, 40), "contrast/brightness not held")
    check(near(ns.state.curG, 0.9, 1e-6), "gamma not held: " .. ns.state.curG)
    check(near(wow.lastWrite("Gamma"), 0.9, 0.001), "gamma not written")

    ns.dispatch("try 60 40 50")
    frames(ns, 5)
    check(near(ns.state.curG, 3.0, 1e-6), "gamma 50 was not held at the 3.0 edge: " .. ns.state.curG)
    check(wow.chatMatches("outside the range the screen applies") ~= nil, "clamp not said")
    for i = 1, #wow.writes do
        local w = wow.writes[i]
        if w.name == "Gamma" then
            check(tonumber(w.value) <= 3.0 + 1e-9 and tonumber(w.value) >= 0.3 - 1e-9,
                "wrote a Gamma outside 0.3-3.0: " .. w.value)
        end
    end

    ns.dispatch("try 55 45")
    frames(ns, 2)
    check(near(ns.state.tgtG, 3.0, 1e-6), "a two-value try moved gamma: " .. ns.state.tgtG)
end)

-- Yard space and polygons ------------------------------------------------------------
--
-- design/ui/DESIGN-ui.md 3.2-3.4. The stub's map is 3470.83 x 2314.62 yards, so
-- the two axes are not square - the reason radii are in yards at all.

local SW, SH = 3470.83, 2314.62

test("a circle in yards weighs the same 20 yd east and 20 yd south", function()
    local ns = load()
    ns.Config.indoors = nil
    local zone = placed(ns, { contrast = 50, brightness = 50,
        areas = { { x = 0.5, y = 0.5, innerYards = 10, falloffYards = 30, contrast = 90 } } })
    check(zone.__W == SW and zone.__H == SH, "scale not cached: " .. tostring(zone.__W))
    local east  = ns.evaluate(zone, nil, 0.5 + 20 / SW, 0.5, false)
    local south = ns.evaluate(zone, nil, 0.5, 0.5 + 20 / SH, false)
    check(east > 50 and east < 90, "20 yd east should be in the band: " .. east)
    check(near(east, south, 1e-9), "east " .. east .. " vs south " .. south)
    -- The old normalized maths gave these different weights, which is the bug.
    check(ns.evaluate(zone, nil, 0.5 + 9 / SW, 0.5, false) == 90, "inside innerYards")
    check(ns.evaluate(zone, nil, 0.5, 0.5 + 31 / SH, false) == 50, "beyond falloffYards")
end)

test("polygon weight in yards: the band is the same width on both axes", function()
    local w = load().polygonWeight
    -- 0.1 normalized on a side: 347 yd wide, 231 yd tall.
    local sq = { 0.4, 0.4, 0.5, 0.4, 0.5, 0.5, 0.4, 0.5 }
    local F = 40
    check(w(sq, F, 0.45, 0.45, SW, SH) == 1, "inside is not 1")
    check(w(sq, F, 0.5, 0.45, SW, SH) == 1, "on an edge is not 1")
    local east  = w(sq, F, 0.5 + (F / 2) / SW, 0.45, SW, SH)     -- off a vertical edge
    local south = w(sq, F, 0.45, 0.5 + (F / 2) / SH, SW, SH)     -- off a horizontal edge
    check(near(east, 0.5, 1e-9), "half the band off the vertical edge: " .. east)
    check(near(east, south, 1e-9), "vertical " .. east .. " vs horizontal " .. south)
    check(w(sq, F, 0.5 + (F + 1) / SW, 0.45, SW, SH) == 0, "beyond the falloff is not 0")

    local U = { 0.2, 0.2, 0.8, 0.2, 0.8, 0.8, 0.6, 0.8, 0.6, 0.5, 0.4, 0.5, 0.4, 0.8, 0.2, 0.8 }
    check(w(U, 10, 0.5, 0.7, SW, SH) == 0, "the notch is not outside")
    check(w(U, 10, 0.3, 0.7, SW, SH) == 1, "the arm is not inside")
    local diamond = { 0.5, 0.3, 0.7, 0.5, 0.5, 0.7, 0.3, 0.5 }
    check(w(diamond, 10, 0.4, 0.5, SW, SH) == 1, "a ray through two vertices, inside")
    check(w(diamond, 10, 0.2, 0.5, SW, SH) == 0, "a ray through two vertices, outside")
end)

test("a polygon area is live in evaluate and through the loop", function()
    local ns = load()
    ns.Config.indoors = nil
    ns.Config.zones.Testland = { contrast = 50, brightness = 50, map = 1429,
        areas = { { name = "pocket", corners = { 0.4, 0.4, 0.5, 0.4, 0.5, 0.5, 0.4, 0.5 },
                    falloffYards = 25, priority = 10, contrast = 78, brightness = 18 } } }
    wow.zone, wow.mapID, wow.position = "Testland", 1429, { 0.45, 0.45 }
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    check(ns.state.needsPos == true, "a polygon zone does not ask for a position")
    frames(ns, 4)
    check(near(ns.state.tgtC, 78) and near(ns.state.tgtB, 18), "inside the polygon: "
        .. ns.state.tgtC .. "/" .. ns.state.tgtB)
    wow.position = { 0.9, 0.9 }
    frames(ns, 4)
    check(near(ns.state.tgtC, 50), "outside the polygon: " .. ns.state.tgtC)

    -- Fewer than three corners weighs nothing, so a half-drawn shape is inert.
    local half = placed(ns, { contrast = 50, brightness = 50,
        areas = { { corners = { 0.4, 0.4, 0.5, 0.4 }, falloffYards = 25, contrast = 90 } } })
    check(ns.evaluate(half, nil, 0.45, 0.4, false) == 50, "a two-corner polygon weighed something")
end)

test("legacy radii convert to yards on a zone change, or skip with one warning", function()
    local ns = load()
    ns.Config.indoors = nil
    ns.Config.zones.Testland = { contrast = 50, brightness = 50, map = 1429,
        areas = { { name = "forecourt", x = 0.4920, y = 0.4143, inner = 0.0040, falloff = 0.0200,
                    contrast = 85 } } }
    wow.zone, wow.mapID, wow.position = "Testland", 1429, { 0.4920, 0.4143 }
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    local a = ns.Config.zones.Testland.areas[1]
    local g = math.sqrt(SW * SH)
    check(a.inner == nil and a.falloff == nil, "the normalized radii were left in place")
    check(near(a.innerYards, 0.004 * g, 0.05) and near(a.falloffYards, 0.02 * g, 0.05),
        "converted to " .. tostring(a.innerYards) .. "/" .. tostring(a.falloffYards))
    check(near(a.innerYards, 11.3, 0.05) and near(a.falloffYards, 56.7, 0.05),
        "the design's worked example is 11.3 / 56.7")
    check(a.__converted == true, "not tagged as converted")
    frames(ns, 3)
    check(near(ns.state.tgtC, 85), "the converted area is not applied: " .. ns.state.tgtC)

    -- No scale: skipped, one warning, the rest of the zone still works.
    wow.install()
    local ns2 = load()
    ns2.Config.indoors = nil
    C_Map.GetMapWorldSize = nil
    ns2.Config.zones.Testland = { contrast = 60, brightness = 50, map = 1429,
        areas = { { name = "forecourt", x = 0.5, y = 0.5, inner = 0.004, falloff = 0.02,
                    contrast = 85 },
                  { subzone = "Town", contrast = 20 } } }
    wow.zone, wow.subzone, wow.mapID, wow.position = "Testland", "", 1429, { 0.5, 0.5 }
    login(ns2)
    ns2.frame:Fire("ZONE_CHANGED_NEW_AREA")
    ns2.frame:Fire("ZONE_CHANGED")
    frames(ns2, 3)
    local n = 0
    for i = 1, #wow.chat do
        if wow.chat[i]:find("map scale unavailable", 1, true) then n = n + 1 end
    end
    check(n == 1, n .. " scale warnings, expected exactly one")
    check(near(ns2.state.tgtC, 60), "a placed area applied without a scale: " .. ns2.state.tgtC)
    local b = ns2.Config.zones.Testland.areas[1]
    check(b.inner == 0.004 and b.innerYards == nil, "converted without a scale")
    wow.subzone = "Town"
    ns2.frame:Fire("ZONE_CHANGED")
    frames(ns2, 3)
    check(near(ns2.state.tgtC, 20), "named areas stopped working with no scale")
end)

test("a gamma outside the screen's range in config is clamped once and never written", function()
    local ns = load()
    ns.Config.zones.Duskwood.gamma = 3.5
    ns.Config.zones.Duskwood.areas[1].gamma = 0.1
    wow.zone, wow.subzone = "Duskwood", ""
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 4)
    local zone = ns.Config.zones.Duskwood
    check(zone.gamma == 3.0 and zone.__gammaWas == 3.5, "zone gamma not clamped: " .. tostring(zone.gamma))
    check(zone.areas[1].gamma == 0.3, "area gamma not clamped: " .. tostring(zone.areas[1].gamma))
    local n = 0
    for i = 1, #wow.chat do
        if wow.chat[i]:find("outside the range the screen applies", 1, true) then n = n + 1 end
    end
    check(n == 2, n .. " clamp warnings, expected one per value")
    for i = 1, #wow.writes do
        local w = wow.writes[i]
        if w.name == "Gamma" then
            check(tonumber(w.value) <= 3.0 + 1e-9, "wrote Gamma " .. w.value)
        end
    end
    wow.chat = {}
    ns.dispatch("config")
    check(wow.chatMatches("outside the range the screen applies") ~= nil,
        "/amb config does not report the clamped value")
end)

test("layersFor re-sorts when areas is replaced, and not on a value edit", function()
    local ns = load()
    ns.Config.indoors = nil
    local a1 = { subzone = "Town", priority = 10, contrast = 10 }
    local a2 = { subzone = "Town", priority = 20, contrast = 20 }
    local zone = { contrast = 50, brightness = 50, areas = { a1, a2 } }
    local list = ns.layersFor(zone)
    check(list[2] == a2, "a2 should be on top")
    check(ns.layersFor(zone) == list, "rebuilt with nothing changed")

    a1.contrast = 11                               -- a value edit, in place
    check(ns.layersFor(zone) == list, "a value edit rebuilt the layer list")
    check(near((ns.evaluate(zone, "Town", nil, nil, false)), 20), "value edit not live")

    a1.priority = 30                               -- a priority edit, the editor way
    zone.areas = { a1, a2 }
    local list2 = ns.layersFor(zone)
    check(list2 ~= list and list2[2] == a1, "replacing areas did not re-sort")
    check(near((ns.evaluate(zone, "Town", nil, nil, false)), 11), "the new winner is not live")

    ns.invalidateLayers(zone)
    check(ns.layersFor(zone) ~= list2, "invalidateLayers did not drop the cache")
end)

test("evaluate allocates nothing with polygons and circles present", function()
    local ns = load()
    local zone = { contrast = 50, brightness = 50, areas = {} }
    for i = 1, 6 do
        zone.areas[#zone.areas + 1] = { x = i / 13, y = 0.5, innerYards = 10, falloffYards = 200,
            contrast = 40 + i, brightness = 60 - i, gamma = 1 + i / 10 }
        local p = {}
        for k = 0, 15 do
            local ang = k / 16 * 2 * math.pi
            p[#p + 1] = 0.5 + 0.05 * math.cos(ang) + i / 100
            p[#p + 1] = 0.5 + 0.05 * math.sin(ang)
        end
        zone.areas[#zone.areas + 1] = { corners = p, falloffYards = 40, priority = i,
            contrast = 30 + i }
    end
    placed(ns, zone)
    ns.evaluate(zone, nil, 0.52, 0.5)
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 2000 do
        ns.evaluate(zone, nil, 0.52, 0.5)
        ns.evaluate(zone, nil, 0.9, 0.9, true)
    end
    local delta = (collectgarbage("count") - before) * 1024
    collectgarbage("restart")
    check(delta < 64, ("%0.1f bytes allocated over 4000 calls"):format(delta))
end)

test("every distinct subzone is recorded once per zone", function()
    local ns = load()
    wow.zone, wow.subzone = "Duskwood", "Darkshire"
    login(ns)
    frames(ns, 1)
    wow.subzone = "Raven Hill"
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 1)
    wow.subzone = "Darkshire"
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 1)
    wow.subzone = ""
    ns.frame:Fire("ZONE_CHANGED")
    local set = ns.seenSubzones.Duskwood
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    check(n == 2 and set.Darkshire and set["Raven Hill"], "seen: " .. n)
    check(ns.seenSubzones.Westfall == nil, "another zone got entries")
end)

test("/amb here prints radii in yards when the map scale can be read", function()
    local ns = load()
    wow.zone, wow.subzone, wow.mapID, wow.position = "Testland", "", 99, { 0.1234, 0.5678 }
    login(ns)
    ns.dispatch("here")
    check(wow.chatMatches("innerYards = 42.5, falloffYards = 113.4") ~= nil,
        "the circle entry is not in yards")
end)

-- Secrets ----------------------------------------------------------------------

test("a zone name that comes back secret is refused, not used", function()
    wow.secrets.zone = true
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    check(ns.state.zoneName == nil, "a secret was adopted as a zone name")
    check(near(ns.state.tgtB, 50), "should have fallen back to the baseline, got " .. ns.state.tgtB)
end)

-- Commands ---------------------------------------------------------------------

test("/amb off eases back to the baseline and then stops", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 4)
    SlashCmdList.DYNAMICAMBIANCE("off")
    check(ns.frame:IsShown(), "stopped before it had eased back")
    frames(ns, 5)
    check(near(wow.lastWrite("Brightness"), 50, 0.01),
        "did not reach the baseline: " .. tostring(wow.lastWrite("Brightness")))
    check(not ns.frame:IsShown(), "still running after it arrived")

    local writes = #wow.writes
    frames(ns, 5)
    check(#wow.writes == writes, "still writing after /amb off")

    SlashCmdList.DYNAMICAMBIANCE("on")
    frames(ns, 4)
    check(near(wow.lastWrite("Brightness"), 40, 0.01), "/amb on did not resume")
end)

test("/amb try holds a value until released", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("try 33 77")
    frames(ns, 4)
    check(near(ns.state.curC, 33), "contrast " .. ns.state.curC)
    check(near(ns.state.curB, 77), "brightness " .. ns.state.curB)

    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")      -- a zone change must not break the hold
    frames(ns, 2)
    check(near(ns.state.curC, 33), "the hold was broken by a zone change")

    SlashCmdList.DYNAMICAMBIANCE("auto")
    frames(ns, 4)
    check(near(ns.state.curC, 60), "did not go back to following the map: " .. ns.state.curC)
end)

test("/amb try rejects nonsense without breaking", function()
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("try banana")
    check(ns.state.mode == "auto", "a bad argument changed the mode")
    check(wow.chatMatches("usage:") ~= nil, "no usage line")
end)

test("/amb here captures a paste-ready entry and logs it", function()
    wow.zone, wow.subzone = "Duskwood", "Darkshire"
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")
    check(wow.chatMatches('subzone = "Darkshire"') ~= nil, "no paste-ready line")
    check(DynamicAmbianceDB and DynamicAmbianceDB.captures
        and #DynamicAmbianceDB.captures == 1, "nothing logged to SavedVariables")
    check(DynamicAmbianceDB.captures[1].zone == "Duskwood", "wrong zone logged")
end)

test("/amb here reports indoor state, which a coordinate cannot express", function()
    wow.zone, wow.subzone, wow.isIndoors = "Elwynn Forest", "Main Hall", true
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")
    check(wow.chatMatches("IsIndoors=true") ~= nil, "did not report being indoors")
    check(DynamicAmbianceDB.captures[1].indoors == true, "did not log the indoor state")
end)

test("/amb here emits an entry that actually works where it was captured", function()
    -- The captured entry has to outrank the indoors rule and be gated to indoors,
    -- or pasting it produces a layer that either never fires or fires outside too.
    wow.zone, wow.subzone, wow.isIndoors = "Duskwood", "Main Hall", true
    local ns = load()
    ns.Config.indoors = { contrast = 42, brightness = 90, priority = 50 }
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")

    local line = wow.chatMatches('{ subzone = "Main Hall"')
    check(line ~= nil, "no entry line")
    if line then
        check(line:find("indoors = true", 1, true) ~= nil, "not gated to indoors: " .. line)
        local p = tonumber(line:match("priority = (%d+)"))
        check(p ~= nil and p > 50, "priority does not outrank the indoors rule: " .. tostring(p))
    end
end)

test("/amb here adds to a zone it already knows instead of duplicating the key", function()
    wow.zone, wow.subzone = "Duskwood", "Darkshire"
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")
    check(wow.chatMatches("already configured") ~= nil, "did not notice the zone exists")
    check(wow.chatMatches('["Duskwood"] = {') == nil,
        "emitted a second Duskwood key, which would silently replace the first")
end)

test("/amb here outdoors does not gate the entry to indoors", function()
    wow.zone, wow.subzone, wow.isIndoors = "Duskwood", "Darkshire", false
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")
    local line = wow.chatMatches('{ subzone = "Darkshire"')
    check(line ~= nil and line:find("indoors", 1, true) == nil,
        "gated an outdoor capture to indoors: " .. tostring(line))
end)

test("/amb here in an unknown zone emits a positional entry carrying its map", function()
    local ns = load()
    wow.zone, wow.subzone, wow.mapID, wow.position = "Testland", "", 99, { 0.1234, 0.5678 }
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")
    check(wow.chatMatches("x = 0.1234, y = 0.5678") ~= nil, "no coordinates in the entry")
    check(wow.chatMatches("map = 99") ~= nil, "no map id in the entry")
end)

test("/amb here says to add a map id when the known zone has none", function()
    local ns = load()
    ns.Config.zones["Testland"] = { contrast = 50, brightness = 50 }   -- no map
    wow.zone, wow.subzone, wow.mapID, wow.position = "Testland", "", 99, { 0.1234, 0.5678 }
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")
    check(wow.chatMatches("add `map = 99,`") ~= nil,
        "captured coordinates into a zone with no map and said nothing")
end)

test("/amb here stays quiet about the map when the known zone already has one", function()
    local ns = load()
    ns.Config.zones["Testland"] = { contrast = 50, brightness = 50, map = 99 }
    wow.zone, wow.subzone, wow.mapID, wow.position = "Testland", "", 99, { 0.1234, 0.5678 }
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("here")
    check(wow.chatMatches("x = 0.1234, y = 0.5678") ~= nil, "no coordinates in the entry")
    check(wow.chatMatches("add `map =") == nil, "nagged about a map it already has")
end)

test("/amb and /amb config answer without raising", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("")
    check(wow.chatMatches("mode=auto") ~= nil, "no status line")
    SlashCmdList.DYNAMICAMBIANCE("config")
    check(wow.chatMatches("Duskwood") ~= nil, "config did not list the zone")
    SlashCmdList.DYNAMICAMBIANCE("nonsense")
    check(wow.chatMatches("unknown: nonsense") ~= nil, "no complaint about a bad command")
    check(wow.chatMatches("/amb here") ~= nil, "no usage after a bad command")
end)

test("/amb debug logs once per change, not once per poll", function()
    wow.zone, wow.subzone = "Duskwood", ""
    local ns = load()
    login(ns)
    SlashCmdList.DYNAMICAMBIANCE("debug")
    frames(ns, 3)                              -- ~30 polls, standing still
    local after = #wow.chat
    frames(ns, 3)                              -- ~30 more, nothing changed
    check(#wow.chat == after, (#wow.chat - after) .. " lines while standing still")

    wow.subzone = "Darkshire"
    ns.frame:Fire("ZONE_CHANGED")
    frames(ns, 3)
    check(#wow.chat > after, "said nothing when the subzone changed")
    check(wow.chatMatches("Duskwood / Darkshire") ~= nil, "did not name the new subzone")
end)

test("/amb reset snaps to the baseline without stopping", function()
    wow.zone = "Duskwood"
    local ns = load()
    login(ns)
    frames(ns, 4)
    SlashCmdList.DYNAMICAMBIANCE("reset")
    check(near(wow.lastWrite("Brightness"), 50, 0.001), "did not snap")
    check(ns.state.mode == "auto", "stopped following the map")
    frames(ns, 4)
    check(near(ns.state.curB, 40), "did not go back to the zone value: " .. ns.state.curB)
end)

-- The shipped config ------------------------------------------------------------
--
-- Not its values - those are taste and change constantly. Its shape, because a
-- hand-authored table with a typo in it fails at runtime in a way that looks like
-- the addon being broken.

test("the shipped Config.lua is structurally sound", function()
    local ns = wow.load(ROOT)                  -- the real file, no fixture
    local C = ns.Config

    local function pct(v) return type(v) == "number" and v >= 0 and v <= 100 end

    check(pct(C.baseline.contrast) and pct(C.baseline.brightness),
        "baseline is not two numbers on the 0-100 scale")
    check(type(C.tuning.easeRate) == "number" and C.tuning.easeRate > 0, "bad easeRate")
    check(type(C.tuning.pollHz) == "number", "bad pollHz")
    check(type(C.tuning.writeHz) == "number", "bad writeHz")
    check(type(C.tuning.writeEpsilon) == "number" and C.tuning.writeEpsilon >= 0,
        "bad writeEpsilon")
    check(type(C.tuning.freezeInCombat) == "boolean", "freezeInCombat is not a boolean")

    local function rule(r, where)
        if r == nil or r == false then return end
        check(type(r) == "table", where .. ": indoors must be a table, nil or false")
        if type(r) == "table" then
            check(r.contrast == nil or pct(r.contrast), where .. ": bad indoor contrast")
            check(r.brightness == nil or pct(r.brightness), where .. ": bad indoor brightness")
        end
    end
    rule(C.indoors, "Config.indoors")

    for name, z in pairs(C.zones) do
        rule(z.indoors, name .. ".indoors")
        check(type(name) == "string" and name ~= "", "a zone with no name")
        check(z.contrast == nil or pct(z.contrast), name .. ": bad contrast")
        check(z.brightness == nil or pct(z.brightness), name .. ": bad brightness")
        check(z.map == nil or type(z.map) == "number", name .. ": map is not a number")

        for i = 1, #(z.areas or {}) do
            local a = z.areas[i]
            local where = ("%s area %d"):format(name, i)
            local positional = a.x ~= nil
            local kinds = (a.subzone and 1 or 0) + (a.x and 1 or 0) + (a.corners and 1 or 0)
            check(kinds == 1 or (kinds == 0 and a.indoors ~= nil),
                where .. ": must be exactly one of subzone, circle or polygon"
                .. " (or a gated whole-zone rule)")
            check(a.indoors == nil or type(a.indoors) == "boolean",
                where .. ": indoors must be true, false or absent")
            check(a.priority == nil or type(a.priority) == "number",
                where .. ": priority must be a number or absent")
            check(a.contrast == nil or pct(a.contrast), where .. ": bad contrast")
            check(a.brightness == nil or pct(a.brightness), where .. ": bad brightness")
            if positional then
                check(type(a.x) == "number" and a.x >= 0 and a.x <= 1, where .. ": x not 0-1")
                check(type(a.y) == "number" and a.y >= 0 and a.y <= 1, where .. ": y not 0-1")
                -- Yards, or legacy normalized radii that are converted on entry:
                -- design/ui/DESIGN-ui.md 9.1 says either is legal in the shipped file.
                local yards = type(a.innerYards) == "number" and type(a.falloffYards) == "number"
                    and a.innerYards < a.falloffYards
                local legacy = type(a.inner) == "number" and type(a.falloff) == "number"
                    and a.inner < a.falloff
                check(yards or legacy, where .. ": inner must be smaller than falloff")
                check(z.map ~= nil,
                    where .. ": positional, but its zone records no map id to check against")
            end
            if a.corners then
                check(#a.corners % 2 == 0 and #a.corners >= 6 and #a.corners <= 64,
                    where .. ": a polygon needs 3 to 32 corner pairs")
                check(type(a.falloffYards) == "number" and a.falloffYards >= 0,
                    where .. ": a polygon needs falloffYards")
                check(z.map ~= nil, where .. ": a polygon with no map id")
            end
        end
    end
end)

test("the chapel forecourt ramps outdoors and yields to the interior rule inside", function()
    -- The shipped positional layer, evaluated exactly as the live loop would.
    local ns = wow.load(ROOT)
    local zone = placed(ns, ns.Config.zones["Elwynn Forest"])
    local cx, cy = 0.4920, 0.4143

    -- Outdoors at the centre: the forecourt layer wins over the valley.
    local c, b = ns.evaluate(zone, "Northshire Valley", cx, cy, false)
    check(near(c, 85) and near(b, 25), "at the centre outdoors: " .. c .. "/" .. b)

    -- Far away: back to the valley.
    c, b = ns.evaluate(zone, "Northshire Valley", 0.9, 0.9, false)
    check(near(c, 55) and near(b, 45), "far away: " .. c .. "/" .. b)

    -- Through the band it has to move monotonically, with no step big enough to
    -- see. This is the only place a falloff is exercised against shipped values.
    local prev, biggest = nil, 0
    for i = 0, 200 do
        local d = 0.0200 * (i / 200)
        local v = ns.evaluate(zone, "Northshire Valley", cx + d, cy, false)
        if prev then biggest = math.max(biggest, math.abs(v - prev)) end
        prev = v
    end
    check(biggest < 0.5, "a step of " .. biggest .. " walking out of the forecourt")

    -- Same coordinate, indoors: the forecourt is gated out and the interior rule
    -- takes it. This is the pair of assertions the whole design turns on.
    c, b = ns.evaluate(zone, "Northshire Valley", cx, cy, true)
    check(near(c, 42) and near(b, 90), "same spot, indoors: " .. c .. "/" .. b)
end)

test("the shipped config still carries the measured Northshire facts", function()
    local ns = wow.load(ROOT)
    local z = ns.Config.zones["Elwynn Forest"]
    check(z ~= nil, "Elwynn Forest is gone - the measured zone name")
    if z then
        check(z.map == 1429, "map should be the measured 1429, is " .. tostring(z.map))

        -- Main Hall is deliberately NOT named. It was walked and it exists, but
        -- the chapel capture showed inside and outside share a coordinate space,
        -- so interiors are handled by Config.indoors instead of an entry per
        -- building. Hall of Arms stays only because it differs from that rule.
        local want = { ["Northshire Valley"] = false, ["Hall of Arms"] = false }
        local named = {}
        for i = 1, #(z.areas or {}) do
            local s = z.areas[i].subzone
            if s then
                named[s] = z.areas[i]
                if want[s] ~= nil then want[s] = true end
            end
        end
        for s, found in pairs(want) do
            check(found, "the measured subzone " .. s .. " is no longer configured")
        end
        check(named["Main Hall"] == nil,
            "Main Hall is named again - that is what Config.indoors replaced")
        if named["Hall of Arms"] then
            check(named["Hall of Arms"].indoors == true,
                "Hall of Arms should be gated to indoors, or it can fire outside it")
        end
    end

    check(type(ns.Config.indoors) == "table",
        "Config.indoors is gone - interiors have nothing handling them")

    -- At least one live positional layer, or the falloff code is never exercised
    -- in the world however green this suite is.
    local positional = 0
    for _, zz in pairs(ns.Config.zones) do
        for i = 1, #(zz.areas or {}) do
            if zz.areas[i].x then positional = positional + 1 end
        end
    end
    check(positional > 0, "no positional layer is live - the falloff path is untested in game")

    -- The stairway bug in one assertion: if any named subzone outranks the indoor
    -- rule without being gated to indoors, walking a building whose steps report
    -- the outdoor subzone will snap the screen back mid-interior.
    if type(ns.Config.indoors) == "table" then
        local p = ns.Config.indoors.priority or 50
        for name, zz in pairs(ns.Config.zones) do
            for i = 1, #(zz.areas or {}) do
                local a = zz.areas[i]
                if (a.priority or 0) > p then
                    check(a.indoors == true, ("%s area %d outranks the indoor rule but is "
                        .. "not gated to indoors"):format(name, i))
                end
            end
        end
    end
end)

test("Zones.lua loads right after Config.lua and holds the Northshire set, all valid", function()
    local ns = wow.load(ROOT)
    local files = wow.loaded
    check(files[1] == "Config.lua" and files[2] == "Zones.lua",
        "load order: " .. tostring(files[1]) .. ", " .. tostring(files[2]))
    local z = ns.Config.zones["Elwynn Forest"]
    check(z ~= nil and z.map == 1429, "the Northshire set is not in Zones.lua")
    if not z then return end
    check(z.origin == "seed", "a shipped zone is not marked as the seed")
    local fh = assert(io.open(ROOT .. "/addons/DynamicAmbiance/Zones.lua", "rb"))
    local head = fh:read("*a"):sub(1, 400)
    fh:close()
    check(head:find("Read once, on a character's first login, to seed its saved zones", 1, true) ~= nil,
        "the file's header does not name it as the seed")
    check(type(z.meta) == "table" and z.meta.version == 1, "no metadata on the shipped set")
    local notes = (z.meta and z.meta.notes) or ""
    check(notes:find("VALUES ARE DELIBERATELY EXAGGERATED", 1, true) ~= nil,
        "the exaggeration warning did not survive the move")
    check(notes:find("WAS WALKED", 1, true) ~= nil, "the walked-names record did not survive")
    local ok, problems = ns.Preset.validate("Elwynn Forest", z)
    check(ok, "the shipped set does not validate: " .. table.concat(problems or {}, "; "))
    for i = 1, #z.areas do
        local a = z.areas[i]
        if a.x then
            check((a.innerYards and a.falloffYards) or (a.inner and a.falloff),
                "area " .. i .. " has no radii in yards or legacy form")
        end
    end
end)

test("the shipped Zones.lua is exactly what the generator writes", function()
    local fh = assert(io.open(ROOT .. "/addons/DynamicAmbiance/Zones.lua", "rb"))
    local text = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    local ns = wow.load(ROOT)
    local when, ver = text:match("GENERATED by the in%-game editor, ([^,]+), addon ([%d%.]+)%.\n")
    local again = ns.Serialize.zonesFile(ns.Config.zones, when, ver)
    check(again == text, "Zones.lua is not generated content - regenerating it changes it")
end)

-- Serialize ------------------------------------------------------------------------
--
-- design/ui/DESIGN-ui.md 7.3: the generated file must load and reproduce
-- Config.zones field-for-field, and generating twice gives the same text.

local function loadZonesText(text)
    local chunk, err = (_G.loadstring or _G.load)(text)
    if not chunk then return nil, err end
    local target = { Config = { zones = {} } }
    local ok, e = pcall(chunk, "DynamicAmbiance", target)
    if not ok then return nil, e end
    return target.Config.zones
end

-- The recovery draft as the WTF file holds it (feedback-1.md item 9): one string
-- per line of Zones.lua, joined back into the text.
local function draftText()
    local d = DynamicAmbianceDB and DynamicAmbianceDB.editor
    if not (d and type(d.draftLines) == "table") then return nil end
    return table.concat(d.draftLines, "\n")
end

test("the generated Zones.lua loads and reproduces the zones field-for-field", function()
    local ns = load()
    local zones = {
        ["Elwynn Forest"] = every4Kinds(),
        ["Duskwood"] = { contrast = 60, brightness = 40, indoors = false,
            areas = { { subzone = 'Raven "Hill"', notes = 'line one\nline "two"\\ |pipe|',
                        priority = 10, contrast = 65 },
                      { name = "legacy", x = 0.25, y = 0.75, inner = 0.004, falloff = 0.02,
                        contrast = 40 } } },
        ["Westfall"] = { contrast = 50, brightness = 55, indoors = { gamma = 1.5, priority = 55 } },
        ["Empty"] = {},
    }
    -- Engine and editor caches must not be written.
    zones["Elwynn Forest"].__W, zones["Elwynn Forest"].__layers = 1, {}
    zones["Elwynn Forest"].areas[1].origin = "editor"
    zones.Duskwood.areas[2].__converted = true

    local text = ns.Serialize.zonesFile(zones, "2026-09-24 19:02", "0.2.0")
    check(not text:find("__", 1, true), "a __ field was written")
    check(not text:find("|", 1, true), "a raw pipe reached the text - the edit box would eat it")
    check(text:find("-- end of generated zones", 1, true), "no trailing comment")
    check(text:find('Config.zones["Duskwood"]', 1, true)
        < text:find('Config.zones["Elwynn Forest"]', 1, true), "zones not sorted by name")
    local got, err = loadZonesText(text)
    check(got ~= nil, "the generated file does not load: " .. tostring(err))
    if not got then return end
    -- The store's own `origin` is never written into the file (DESIGN-ui.md 7.3).
    check(got["Elwynn Forest"].areas[1].origin == nil, "the store's origin reached Zones.lua")
    zones["Elwynn Forest"].areas[1].origin = nil
    for name, z in pairs(zones) do
        local ok, why = sameTable(z, got[name], name)
        check(ok, "not reproduced: " .. tostring(why))
    end
    check(got.Duskwood.areas[1].notes == 'line one\nline "two"\\ |pipe|', "notes mangled")
    check(got.Duskwood.indoors == false, "indoors = false lost")
    check(got["Elwynn Forest"].areas[3].corners[64] ~= nil, "corners lost")

    local again = ns.Serialize.zonesFile(got, "2026-09-24 19:02", "0.2.0")
    check(again == text, "generate -> load -> generate is not identical")
end)

test("a version goes up once per export of a changed zone, and a typed one stands", function()
    local ns = load()
    local S = ns.Serialize
    local zones = ns.Config.zones
    zones.Duskwood.meta = { name = "Duskwood", version = 3 }
    zones.Duskwood.origin = "seed"
    zones.Westfall.meta = { name = "Westfall", version = 7 }
    zones.Westfall.origin = "seed"

    S.markChanged(zones.Duskwood)
    S.exportFile(zones)
    check(zones.Duskwood.meta.version == 4, "a changed zone did not go up: " .. zones.Duskwood.meta.version)
    check(zones.Westfall.meta.version == 7, "an unchanged zone went up")
    check(zones.Duskwood.meta.date == "1970-01-01 00:00:00" or zones.Duskwood.meta.date ~= nil,
        "no date stamped on the bump")
    S.exportFile(zones)
    check(zones.Duskwood.meta.version == 4, "a second export without a change bumped again")

    -- A DA2 export is an export too.
    S.markChanged(zones.Duskwood)
    S.presetString("Duskwood")
    check(zones.Duskwood.meta.version == 5, "a preset string export did not bump")
    S.exportFile(zones)
    check(zones.Duskwood.meta.version == 5, "the file export after it bumped again")

    -- Typed in the properties panel: it stands, even though the zone changed.
    S.markChanged(zones.Duskwood)
    zones.Duskwood.meta.version = 12
    S.markManualVersion(zones.Duskwood)
    S.exportFile(zones)
    check(zones.Duskwood.meta.version == 12, "a manual version was overwritten: "
        .. zones.Duskwood.meta.version)

    -- A zone created in the editor exports as version 1 the first time.
    zones.Redridge = { contrast = 50, origin = "editor" }
    S.ensureMeta("Redridge", zones.Redridge)
    S.markChanged(zones.Redridge)
    S.exportFile(zones)
    check(zones.Redridge.meta.version == 1, "a new preset's first export is not 1: "
        .. zones.Redridge.meta.version)
    check(zones.Redridge.meta.author == "Tester-TestRealm", "author not stamped: "
        .. tostring(zones.Redridge.meta.author))
    S.markChanged(zones.Redridge)
    S.exportFile(zones)
    check(zones.Redridge.meta.version == 2, "its second changed export is not 2")

    -- An imported preset keeps the sender's author.
    zones.Import = { contrast = 50, origin = "import", meta = { version = 2, author = "Them" } }
    S.markChanged(zones.Import)
    S.exportFile(zones)
    check(zones.Import.meta.author == "Them" and zones.Import.meta.version == 3,
        "an import's provenance was overwritten")

    -- The recovery draft is not an export.
    S.markChanged(zones.Westfall)
    S.draft(zones)
    check(zones.Westfall.meta.version == 7 and zones.Westfall.export.pending,
        "writing the draft counted as an export")
end)

test("/amb export bumps the version of a changed zone", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    local z = ns.Config.zones.Duskwood
    z.origin = "seed"
    ns.Serialize.markChanged(z)
    ns.dispatch("export")
    check(z.meta and z.meta.version == 2, "not bumped: " .. tostring(z.meta and z.meta.version))
    ns.dispatch("export")
    check(z.meta.version == 2, "bumped without a change")
end)

-- Raster: the canvas geometry ------------------------------------------------------
--
-- design/ui/DESIGN-ui.md 6.2 and 6.4. Pure functions, tested directly.

test("cursorToMap and mapToCanvas invert each other, and clamp at the edges", function()
    local R = load().Raster
    local s, left, top, w, h = 0.8, 100, 900, 1002, 668
    for _, p in ipairs({ { 0, 0 }, { 1, 1 }, { 0.4921, 0.414 }, { 0.25, 0.75 } }) do
        local px, py = R.mapToCanvas(p[1], p[2], w, h)
        local cx, cy = (left + px) * s, (top - py) * s          -- what the cursor would read
        local nx, ny, inside = R.cursorToMap(cx, cy, s, left, top, w, h)
        check(near(nx, p[1], 1e-9) and near(ny, p[2], 1e-9) and inside,
            ("%s,%s came back as %s,%s"):format(p[1], p[2], nx, ny))
        local bx, by = R.canvasToMap(px, py, w, h)
        check(near(bx, p[1], 1e-12) and near(by, p[2], 1e-12), "canvasToMap")
    end
    local nx, ny, inside = R.cursorToMap((left - 50) * s, (top + 20) * s, s, left, top, w, h)
    check(nx == 0 and ny == 0 and inside == false, "off the top-left not clamped: " .. nx .. "," .. ny)
    nx, ny, inside = R.cursorToMap((left + w + 5) * s, (top - h - 5) * s, s, left, top, w, h)
    check(nx == 1 and ny == 1 and inside == false, "off the bottom-right not clamped")
    check(R.round4(0.123456) == 0.1235, "round4")
    check(near(R.yardsToPixels(3470.83, 1002, 3470.83), 1002, 1e-9), "yardsToPixels")
end)

local function covering(strips, x, y)
    local n = 0
    for i = 1, #strips do
        local e = strips[i]
        if x >= e.x and x < e.x + e.w and y >= e.y and y < e.y + e.h then n = n + 1 end
    end
    return n
end

test("strips of a square lie inside it and cover each point exactly once", function()
    local R = load().Raster
    local sq = { 100, 40, 300, 40, 300, 240, 100, 240 }        -- 200 x 200
    local out, n = R.strips(sq, 4)
    check(n == 50 and #out == 50, "strip count " .. n .. ", expected 200 / 4 = 50")
    for i = 1, n do
        local e = out[i]
        check(e.x >= 100 - 1e-9 and e.x + e.w <= 300 + 1e-9 and e.y >= 40 - 1e-9
            and e.y + e.h <= 240 + 1e-9, "strip " .. i .. " leaves the square")
    end
    for _, p in ipairs({ { 150, 100 }, { 101, 41 }, { 299, 239 }, { 200, 44 } }) do
        check(covering(out, p[1], p[2]) == 1, ("%d,%d covered %d times"):format(p[1], p[2],
            covering(out, p[1], p[2])))
    end
    for _, p in ipairs({ { 99, 100 }, { 301, 100 }, { 200, 39 }, { 200, 241 } }) do
        check(covering(out, p[1], p[2]) == 0, ("%d,%d outside, covered"):format(p[1], p[2]))
    end
    -- The table is reused: a smaller shape leaves no stale entries behind.
    local again, m = R.strips({ 0, 0, 10, 0, 10, 10, 0, 10 }, 2, out)
    check(again == out and m == 5 and #out == 5, "reuse left " .. #out .. " entries")
end)

test("a concave notch splits its scanlines into two runs; a circle is symmetric", function()
    local R = load().Raster
    -- A U, open at the bottom (y down): the notch is x 400-600, y 500-800.
    local U = { 200, 200, 800, 200, 800, 800, 600, 800, 600, 500, 400, 500, 400, 800, 200, 800 }
    local out = R.strips(U, 10)
    local rowsAt = {}
    for i = 1, #out do
        local e = out[i]
        rowsAt[e.y] = (rowsAt[e.y] or 0) + 1
    end
    check(rowsAt[700] == 2, "a row through the notch has " .. tostring(rowsAt[700]) .. " runs")
    check(rowsAt[300] == 1, "a row above the notch has " .. tostring(rowsAt[300]) .. " runs")
    check(covering(out, 500, 650) == 0, "the notch is filled")

    local c = R.circleStrips(500, 300, 50, 4)
    check(#c == 25, "circle rows " .. #c)
    for i = 1, #c do
        local e, m = c[i], c[#c + 1 - i]
        check(near(e.x + e.w / 2, 500, 1e-9), "row " .. i .. " is not centred")
        check(near(e.w, m.w, 1e-9), "rows " .. i .. " and " .. (#c + 1 - i) .. " differ")
    end
end)

test("band offset lines sit at the falloff distance, outside, for both windings", function()
    local ns = load()
    local R, w = ns.Raster, ns.polygonWeight
    local ccw = { 0.4, 0.4, 0.6, 0.4, 0.6, 0.6, 0.4, 0.6 }
    local cw  = { 0.4, 0.4, 0.4, 0.6, 0.6, 0.6, 0.6, 0.4 }
    check(R.signedArea(ccw) * R.signedArea(cw) < 0, "the two windings are not opposite")
    local off = 0.05
    for name, poly in pairs({ ccw = ccw, cw = cw }) do
        local segs = R.band(poly, off)
        check(#segs == 8, name .. ": 4 shifted edges and 4 joins, got " .. #segs)
        for i = 1, #segs, 2 do                     -- the shifted edges
            local s = segs[i]
            local mx, my = (s[1] + s[3]) / 2, (s[2] + s[4]) / 2
            check(not R.pointInPolygon(poly, mx, my), name .. ": band point inside")
            local cx, cy = 0.5, 0.5
            local dx, dy = mx - cx, my - cy
            local len = math.sqrt(dx * dx + dy * dy)
            local ux, uy = dx / len, dy / len
            check(w(poly, off, mx + ux * 1e-4, my + uy * 1e-4) == 0,
                name .. ": weight beyond the band line is not 0")
            check(w(poly, off, mx - ux * 1e-3, my - uy * 1e-3) > 0,
                name .. ": weight just inside the band line is 0")
        end
    end
    check(#R.band(ccw, 0) == 0 and #R.band({ 0, 0, 1, 1 }, 1) == 0, "degenerate bands drew")
    check(#R.ring(0, 0, 10, 32) == 32, "the ring is not 32 segments")
end)

test("the pitch rule keeps a map-tall shape to 120 strips or fewer", function()
    local R = load().Raster
    check(R.pitchFor(10) == 2 and R.pitchFor(240) == 2, "small shapes are not at 2 px")
    local p = R.pitchFor(668)
    local tall = { 0, 0, 1002, 0, 1002, 668, 0, 668 }
    local _, n = R.strips(tall, p)
    check(n <= 120, n .. " strips at pitch " .. p)
    local _, c = R.circleStrips(500, 334, 334, R.pitchFor(668))
    check(c <= 120, "a map-tall circle: " .. c .. " strips")
end)

test("hit-test helpers", function()
    local R = load().Raster
    local sq = { 0, 0, 10, 0, 10, 10, 0, 10 }
    check(R.pointInPolygon(sq, 5, 5) and not R.pointInPolygon(sq, 11, 5), "pointInPolygon")
    check(near(R.distToOutline(sq, 5, 12), 2, 1e-9), "distToOutline")
    check(R.nearestCorner(sq, 9, 9, 3) == 3, "nearestCorner")
    check(R.nearestCorner(sq, 5, 5, 3) == nil, "nearestCorner outside the radius")
    check(#R.outline(sq) == 4 and #R.outline({ 0, 0, 5, 5 }) == 1, "outline segments")
end)

test("the Classic theme carries the measured art and a colour for every band", function()
    local ns = load()
    local T = ns.Theme
    check(T.get("font") == "Fonts\\FRIZQT__.TTF" and T.get("fontSize") == 12, "font")
    check(T.get("panelBg"):find("UI%-DialogBox%-Background") ~= nil, "panel art")
    -- The bands in Config.lua: feature 10, indoors 50, room 60.
    for _, p in ipairs({ 10, 50, 60 }) do
        local r, g, bb = T.priorityColor(p)
        check(r and g and bb, "no colour for the priority " .. p .. " band")
    end
    local a = { T.priorityColor(10) }
    local c = { T.priorityColor(60) }
    check(a[1] ~= c[1] or a[2] ~= c[2], "feature and room bands share a colour")
end)

-- The editor window ------------------------------------------------------------------
--
-- design/ui/DESIGN-ui.md 9.1, "UI structure under the stub": the UI files load,
-- the window is not built or shown at load, the commands dispatch, closing with
-- unsaved zones goes through the popup, and the editor never mutates zone.areas
-- in place. The canvas callbacks are driven directly in map coordinates; what the
-- screen shows is the in-game checklist's job.

local function editorAt(zone, sub, pos)
    wow.zone, wow.subzone, wow.mapID = zone or "Elwynn Forest", sub or "", 1429
    wow.position = pos or { 0.49, 0.41 }
    local ns = wow.load(ROOT)
    ns.Config.indoors = nil
    login(ns)
    return ns, ns.Editor
end

-- A left click on the canvas: a press and a release at the same point, which is
-- how the Polygon tool and Select on empty map see one (feedback-1.md item 1).
local function click(E, nx, ny)
    E.onCanvasDown("LeftButton", nx, ny, true)
    E.onCanvasUp("LeftButton", nx, ny, true)
end

test("the editor loads, builds nothing at load, and /amb ui opens and closes it", function()
    wow.zone = "Elwynn Forest"
    local ns = wow.load(ROOT)
    local E = ns.Editor
    check(E ~= nil and ns.Canvas ~= nil and ns.UI ~= nil, "UI files did not load")
    check(E.built == false and wow.frameNamed("DynamicAmbianceEditor") == nil,
        "the window was built at load")
    login(ns)
    ns.dispatch("ui")
    local f = wow.frameNamed("DynamicAmbianceEditor")
    check(f ~= nil and f:IsShown(), "/amb ui did not show the window")
    check(f and f.template == "ButtonFrameTemplate", "not the measured ButtonFrameTemplate")
    check(E.zoneName == "Elwynn Forest", "did not open on the zone the player is in")
    check(E.canvas and E.canvas.hasArt, "the map art was not loaded")
    local tiles = 0
    for _, t in ipairs(E.canvas.tiles) do if t.file then tiles = tiles + 1 end end
    check(tiles == 12, "tiles set: " .. tiles)
    local found = false
    for _, n in ipairs(UISpecialFrames) do found = found or n == "DynamicAmbianceEditor" end
    check(found, "not registered for Escape")
    -- Every template was measured (M4) on a NAMED frame; the editor matches that.
    local unnamed = 0
    for _, fr in ipairs(wow.frames) do
        if fr.template ~= nil and fr.name == nil then unnamed = unnamed + 1 end
    end
    check(unnamed == 0, unnamed .. " templated frame(s) created without a name")
    check(E.tabs.Settings and E.tabs.Settings.enabled == false, "the Settings tab is not disabled")
    check(E.tabs.Zones and E.tabs.Zones.enabled ~= false, "the Zones tab is disabled")
    ns.dispatch("ui")
    check(not f:IsShown(), "/amb ui did not close it")
    ns.dispatch("ui save")
    check(f:IsShown() and E.panel == "save" and E.savePanel:IsShown(), "/amb ui save")
    ns.dispatch("ui import")
    check(E.panel == "import" and E.importPanel:IsShown() and not E.savePanel:IsShown(),
        "/amb ui import")
    ns.dispatch("ui zones")
    check(E.panel == "props" and not E.importPanel:IsShown(), "/amb ui zones")
    wow.chat = {}
    ns.dispatch("ui nonsense")
    check(wow.chatMatches("usage: /amb ui") ~= nil, "a bad subcommand was not answered")
end)

test("the editor never mutates zone.areas in place for add, delete or priority", function()
    local ns, E = editorAt()
    E.selectZone("Elwynn Forest", 1429)
    local z = ns.Config.zones["Elwynn Forest"]

    local before = z.areas
    local a = E.addArea({ name = "new", corners = { 0.1, 0.1, 0.2, 0.1, 0.2, 0.2 },
        falloffYards = 10, priority = 10, contrast = 70 })
    check(z.areas ~= before and #z.areas == #before + 1, "add mutated areas in place")
    check(before[#before + 1] == nil, "the old table was appended to")

    before = z.areas
    E.setArea(E.selected, "priority", 60)
    check(z.areas ~= before, "a priority edit mutated areas in place")
    check(E.selected.priority == 60 and E.selected ~= a, "the selection did not follow the copy")

    before = z.areas
    E.setArea(E.selected, "contrast", 71)
    check(z.areas == before, "a value edit replaced areas")
    check(E.selected.contrast == 71, "the value edit did not land")

    before = z.areas
    E.setArea(E.selected, "indoors", true)
    check(z.areas ~= before, "a gate edit mutated areas in place")

    before = z.areas
    local n = #before
    E.deleteArea(E.selected)
    check(z.areas ~= before and #z.areas == n - 1, "delete mutated areas in place")
end)

test("browsing creates nothing; the first area creates the zone with its map and metadata", function()
    local ns, E = editorAt()
    E.selectZone("Westfall", 1436)
    check(ns.Config.zones.Westfall == nil, "browsing created a zone")
    local items = E.zoneItems()
    check(items[1].value == "Elwynn Forest", "the player's zone is not first: " .. items[1].value)
    local names = {}
    for _, it in ipairs(items) do names[it.value] = true end
    check(names.Duskwood and names.Westfall, "the continent's zones are not listed")

    -- Outside the zone there is no subzone to prefill, and a named area with an
    -- empty subzone exports a string that is refused - so it needs a name.
    check(E.addNamed() == nil and ns.Config.zones.Westfall == nil,
        "a named area with no subzone name was created")
    check((E.message or ""):find("/amb ui named", 1, true) ~= nil,
        "the refusal does not say how to name one: " .. tostring(E.message))

    E.addNamed("Sentinel Hill")
    local z = ns.Config.zones.Westfall
    check(z ~= nil and z.map == 1436, "no zone, or the wrong map: " .. tostring(z and z.map))
    check(z.origin == "editor" and z.__dirty, "not marked as made in the editor")
    check(z.meta and z.meta.name == "Westfall" and z.meta.version == 1
        and z.meta.author == "Tester-TestRealm", "metadata not stamped")
    check(z.areas[1].subzone == "Sentinel Hill", "the name given was not used")
end)

test("drawing a polygon: corners, the default fade, and a live area", function()
    local ns, E = editorAt("Elwynn Forest", "", { 0.45, 0.45 })
    E.open("zones")
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    E.useTool("polygon")
    check(E.draft and E.draft.kind == "polygon", "no draft")
    for _, p in ipairs({ { 0.4, 0.4 }, { 0.5, 0.4 }, { 0.5, 0.5 }, { 0.4, 0.5 } }) do
        wow.time = wow.time + 1
        click(E, p[1], p[2])
    end
    check(#E.draft.corners == 8, "corners: " .. #E.draft.corners)
    E.onCanvasDown("RightButton", 0, 0)
    check(#E.draft.corners == 6, "right-click did not remove the last corner")
    wow.time = wow.time + 1
    click(E, 0.4, 0.5)
    -- The fade box starts at the operator's 5 yards, so nothing has to be filled in.
    check(E.draft.fadeYards == 5 and E.draftFade:GetText() == "5",
        "the fade is not pre-filled with 5: " .. tostring(E.draftFade:GetText()))
    E.setDraftFade(25)
    wow.time = wow.time + 1
    click(E, 0.4001, 0.4001)                         -- the first corner again closes it
    local z = ns.Config.zones["Elwynn Forest"]
    local last = z.areas[#z.areas]
    check(E.draft == nil and last.corners and #last.corners == 8, "the polygon was not added")
    check(last.falloffYards == 25 and last.priority == 10 and last.name:find("^area "),
        "defaults wrong")
    check(E.tool == "select" and E.selected == last, "not selected after closing")

    -- Live: standing inside, the engine follows the new area's values at once.
    E.setArea(last, "contrast", 12)
    frames(ns, 3)
    check(near(ns.state.tgtC, 12), "the new polygon is not live: " .. ns.state.tgtC)
    check(E.footerText():find("unsaved") ~= nil, "no unsaved count")
    local _, preview = E.footerText()
    check(preview == "previewing live in Elwynn Forest", "preview line: " .. preview)

    -- A 33rd corner is refused.
    E.useTool("polygon")
    for i = 1, 33 do E.addDraftCorner(0.1 + i / 100, 0.1 + (i % 2) / 100) end
    check(#E.draft.corners == 64, "the corner cap did not hold: " .. #E.draft.corners)
    E.cancelDraft()
    check(E.draft == nil, "cancel did not drop the draft")
end)

test("a double-click closes a polygon, and a circle's fade goes on top of its inner radius", function()
    local ns, E = editorAt()
    E.open("zones")
    local z = ns.Config.zones["Elwynn Forest"]
    local n = #z.areas
    E.useTool("polygon")
    E.setDraftFade(10)
    for _, p in ipairs({ { 0.2, 0.2 }, { 0.3, 0.2 }, { 0.3, 0.3 } }) do
        wow.time = wow.time + 1
        click(E, p[1], p[2])
    end
    wow.time = wow.time + 0.1
    click(E, 0.3, 0.3)                                -- the second click of a double
    check(#z.areas == n + 1 and z.areas[n + 1].corners and #z.areas[n + 1].corners == 6,
        "a double-click did not close it")
    check(z.areas[n + 1].falloffYards == 10, "a polygon's fade is not its falloff")

    E.useTool("circle")
    E.onCanvasDown("LeftButton", 0.6, 0.6)
    E.onCanvasMove(0.6 + 20 / SW, 0.6, true)
    E.onCanvasUp("LeftButton", 0.6 + 20 / SW, 0.6)
    check(E.draft and E.draft.kind == "circle" and near(E.draft.innerYards, 20, 0.05),
        "the drag did not set innerYards: " .. tostring(E.draft and E.draft.innerYards))
    check(#z.areas == n + 1, "the circle existed before Finish")
    -- The fade box shows 5 and the band is drawn at inner + 5; no sum is asked for.
    check(E.draft.fadeYards == 5 and near(E.draft.falloffYards, 25, 0.05),
        "the draft's band is not inner + fade: " .. tostring(E.draft.falloffYards))
    E.setDraftFade(40)
    local c = E.finishDraft()
    check(c and c.x == 0.6 and c.innerYards == 20 and c.falloffYards == 60,
        "circle not stored as inner + fade: " .. tostring(c and c.falloffYards))
    check(E.fadeBox:GetText() == "40", "the selected circle does not show its fade: "
        .. tostring(E.fadeBox:GetText()))
end)

test("select and drag: a corner moves in place, the body moves clamped, undo restores", function()
    local ns, E = editorAt()
    E.open("zones")
    local z = ns.Config.zones["Elwynn Forest"]
    local a = E.addArea({ name = "sq", corners = { 0.4, 0.4, 0.5, 0.4, 0.5, 0.5, 0.4, 0.5 },
        falloffYards = 20, priority = 30, contrast = 90 })
    E.selected = nil
    E.useTool("select")
    E.onCanvasDown("LeftButton", 0.45, 0.45)
    check(E.selected == a, "clicking inside did not select it")
    E.onCanvasUp("LeftButton", 0.45, 0.45)

    local areas = z.areas
    E.onCanvasDown("LeftButton", 0.5, 0.5)            -- the corner handle
    check(E.drag and E.drag.kind == "corner" and E.drag.index == 3, "not a corner drag")
    E.onCanvasMove(0.55, 0.56, true)
    E.onCanvasUp("LeftButton", 0.55, 0.56)
    check(a.corners[5] == 0.55 and a.corners[6] == 0.56, "the corner did not move")
    check(z.areas == areas, "a corner drag replaced areas")

    E.onCanvasDown("LeftButton", 0.45, 0.45)          -- the body
    E.onCanvasMove(-0.9, 0.45, true)                   -- far off the left edge
    E.onCanvasUp("LeftButton", -0.9, 0.45)
    check(a.corners[1] == 0 and a.corners[7] == 0, "the body was not clamped at the edge: "
        .. a.corners[1])
    check(near(a.corners[3], 0.1, 1e-9), "the shape did not keep its width")

    check(E.undo(), "nothing to undo")
    local now_ = ns.Config.zones["Elwynn Forest"]
    local restored = now_.areas[#now_.areas]
    check(restored.corners[1] == 0.4 and restored.corners[5] == 0.55, "undo did not restore "
        .. "the shape before the body drag")
    check(E.redo(), "nothing to redo")
    restored = now_.areas[#now_.areas]
    check(restored.corners[1] == 0, "redo did not reapply the drag")

    -- Undo all the way back removes the area, and the zone's areas table is new.
    while E.undo() do end
    for _, x in ipairs(now_.areas) do check(x.name ~= "sq", "undo left the area behind") end
end)

test("Corner here drops corners where the player stands", function()
    local ns, E = editorAt("Elwynn Forest", "", { 0.41, 0.52 })
    E.open("zones")
    E.useTool("polygon")
    for _, p in ipairs({ { 0.41, 0.52 }, { 0.418, 0.5205 }, { 0.4191, 0.5302 }, { 0.4098, 0.5311 } }) do
        wow.position = p
        frames(ns, 0.2)
        ns.dispatch("ui corner")
    end
    check(#E.draft.corners == 8 and E.draft.corners[3] == 0.418, "corners: "
        .. #E.draft.corners)
    -- /amb here offers the same while a polygon is being drawn and there is no subzone.
    wow.chat = {}
    ns.dispatch("here")
    check(wow.chatMatches("Corner here") ~= nil, "/amb here did not offer a corner")
    E.setDraftFade(15)
    local a = E.finishDraft()
    check(a and #a.corners == 8, "not closed")
    -- On another map, or with no position, it refuses rather than guessing.
    E.useTool("polygon")
    wow.position = nil
    ns.state.px = nil
    check(E.cornerHere() == false, "a corner was placed with no position")
end)

test("the readout names the winner among placed areas, highest priority first", function()
    local ns, E = editorAt()
    E.selectZone("Elwynn Forest", 1429)
    local z = ns.Config.zones["Elwynn Forest"]
    ns.prepareZone(z, "Elwynn Forest")
    local text = E.readoutText(0.4920, 0.4143)
    check(text:find("wins here: chapel forecourt (p20) [outdoors] w=1.00", 1, true) ~= nil,
        "forecourt not the winner: " .. text)
    check(text:find("cannot be located on the map", 1, true) and text:find("Northshire Valley",
        1, true), "named areas not listed as unlocatable: " .. text)
    E.addArea({ name = "top", corners = { 0.48, 0.40, 0.50, 0.40, 0.50, 0.43, 0.48, 0.43 },
        falloffYards = 5, priority = 60, indoors = true, contrast = 1 })
    text = E.readoutText(0.4920, 0.4143)
    check(text:find("wins here: top (p60) [indoors]", 1, true) ~= nil, "the new top area: " .. text)
    check(text:find("chapel forecourt (p20)", 1, true) ~= nil, "the lower one is not listed")
end)

test("closing with unsaved zones goes through the popup, and each button does what it says", function()
    local ns, E = editorAt()
    E.open("zones")
    local dialog = StaticPopupDialogs.DYNAMICAMBIANCE_UNSAVED
    check(dialog and dialog.button1 == "Save to file" and dialog.button2 == "Close anyway",
        "the popup is not defined with its two buttons")
    wow.popupShown = nil
    E.close()
    check(wow.popupShown == nil, "a popup with nothing unsaved")

    E.open("zones")
    E.setZoneValue("contrast", 40)
    E.close()
    check(wow.popupShown == "DYNAMICAMBIANCE_UNSAVED", "closing with an unsaved zone did not ask")
    dialog.OnCancel()
    check(not E.isShown(), "Close anyway reopened it")
    dialog.OnAccept()
    check(E.isShown() and E.panel == "save", "Save to file did not open the save panel")
end)

test("Save to file: the exact wording, the whole file, versions bumped once, dirty cleared", function()
    local ns, E = editorAt()
    E.open("zones")
    local z = ns.Config.zones["Elwynn Forest"]
    E.setZoneValue("brightness", 70)
    check(z.__dirty and E.dirtyCount() == 1, "not dirty")
    ns.dispatch("ui save")
    local body = E.SAVE_TEXT
    for _, phrase in ipairs({
        "Why you have to do this step yourself, on this build.",
        "This addon has not yet seen World of Warcraft: Forever read its saved settings back on this build.",
        "Saving worked on build 70009; a later build may have stopped, or this may be your first login",
        "this build is not keeping saved settings, and everything you draw here needs the steps below.",
        "So today, saving is a copy and paste:",
        "Interface\\AddOns\\DynamicAmbiance\\Zones.lua",
        "in your World of Warcraft: Forever folder",
        "This is automatic on a build that reads saved settings back.",
        "when it does, this panel goes away and nothing you pasted here needs to be redone.",
        "WTF\\Account\\<your account>\\SavedVariables\\DynamicAmbiance.lua under editor.draftLines",
    }) do
        local plainBody = body:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        check(plainBody:find(phrase, 1, true) ~= nil, "wording missing: " .. phrase)
    end
    check(E.saveTitle and E.saveTitle.text == "Save to file", "title")
    check(z.meta.version == 2, "opening the panel did not bump the changed zone: " .. z.meta.version)
    local text = E.saveBox:GetText()
    local got = loadZonesText(text)
    check(got and got["Elwynn Forest"] and got["Elwynn Forest"].brightness == 70,
        "the box does not hold the whole, current Zones.lua")
    E.selectAll()
    check(E.saveBox.focused and E.saveBox.highlighted, "Select all did not select")
    check(z.meta.version == 2, "Select all bumped again")
    check(E.dirtyCount() == 0, "Select all did not clear the unsaved count")
    check(E.pathBox and E.pathBox:GetText() == "Interface\\AddOns\\DynamicAmbiance\\Zones.lua",
        "the path box")

    -- Preset string mode: one zone's DA2.
    E.modeDrop.pick("Elwynn Forest", { text = "Preset string: Elwynn Forest" })
    check(E.saveBox:GetText():sub(1, 4) == "DA2~", "preset string mode: " .. E.saveBox:GetText():sub(1, 20))
end)

test("the recovery draft reaches DynamicAmbianceDB.editor on a change", function()
    local ns, E = editorAt()
    E.open("zones")
    E.addArea({ subzone = "Goldshire", priority = 10, contrast = 33 })
    local d = DynamicAmbianceDB and DynamicAmbianceDB.editor
    check(d and type(d.draftLines) == "table" and #d.draftLines > 10, "no draft lines written")
    local text = draftText()
    check(text and text:find("subzone = [[Goldshire]]", 1, true) ~= nil, "the draft lacks the change")
    local got = text and loadZonesText(text)
    check(got and got["Elwynn Forest"] and got["Elwynn Forest"].areas[4].subzone == "Goldshire",
        "the draft is not a loadable Zones.lua")
    -- A draft is not an export: no version moved.
    check(ns.Config.zones["Elwynn Forest"].meta.version == 1, "writing the draft bumped a version")
    -- Logout flushes a pending one.
    E.draftPending = true
    DynamicAmbianceDB.editor = nil
    wow.fireAll("PLAYER_LOGOUT")
    check(DynamicAmbianceDB.editor ~= nil, "logout did not flush the draft")
end)

test("/amb ui import: a pasted string opens the confirmation; garbage is refused beside the box", function()
    local ns, E = editorAt()
    ns.dispatch("ui import")
    local s = ns.Preset.serialize("Duskwood", { contrast = 20, brightness = 80, map = 1431,
        areas = { { subzone = "Darkshire", priority = 10, contrast = 25 } } })
    E.importBox:SetText("[12:00] Somebody: " .. s)
    E.importText(E.importBox:GetText())
    check(ns.shareSession.offer ~= nil and wow.popupShown == "DYNAMICAMBIANCE_IMPORT",
        "the confirmation did not open")
    ns.dispatch("import accept")
    check(ns.Config.zones.Duskwood and ns.Config.zones.Duskwood.contrast == 20, "not imported")
    check(ns.Config.zones.Duskwood.origin == "import", "not marked as an import")

    check(E.importText("hello") == false and E.importError:find("not a preset"),
        "garbage was not refused: " .. tostring(E.importError))
    check(E.importText(("x"):rep(4001)) == false and E.importError:find("4000"),
        "an over-long paste was not refused with the cap")
    local bad = ns.Preset.serialize("Z", { contrast = 50, gamma = 5 })
    check(E.importText(bad) == false and E.importError:find("gamma 5"),
        "an out-of-range gamma was not refused in the panel: " .. tostring(E.importError))
end)

test("the properties panel shows the selection and edits through the sliders", function()
    local ns, E = editorAt()
    E.open("zones")
    local z = ns.Config.zones["Elwynn Forest"]
    check(E.presetSection:IsShown() and not E.areaSection:IsShown(), "preset section not shown")
    check(E.metaName:GetText() == "Elwynn, Northshire test set", "preset name: " .. E.metaName:GetText())
    local g = E.zoneRows.gamma
    check(g.slider.min == 0.3 and g.slider.max == 3.0, "the gamma slider is not bounded by "
        .. "Config.limits: " .. tostring(g.slider.min) .. "-" .. tostring(g.slider.max))
    check(g.inherit:GetChecked(), "an unset gamma is not shown as inherited")
    g.slider:SetValue(1.6)
    check(z.gamma == 1.6, "the zone gamma slider did not set it: " .. tostring(z.gamma))
    g.inherit:SetChecked(true)
    g.inherit.scripts.OnClick(g.inherit)
    check(z.gamma == nil, "Inherit did not clear it")
    g.box.commit("9")
    check(z.gamma == 3.0, "the numeric box did not clamp to the limit: " .. tostring(z.gamma))

    E.selected = z.areas[1]
    E.refresh()
    check(E.areaSection:IsShown() and E.subzoneBox:IsShown(), "area section for a named area")
    local before = z.areas
    E.areaPriority.commit("55")
    check(z.areas ~= before and E.selected.priority == 55, "priority via the box")
    E.areaApplies.pick("in", { text = "indoors only" })
    check(E.selected.indoors == true, "Applies did not gate it")
    E.areaRows.contrast.slider:SetValue(33)
    check(E.selected.contrast == 33, "the area slider did not set contrast")
end)

test("a zone with no art disables drawing; no scale says so; templates refused still build", function()
    local ns, E = editorAt()
    C_Map.MapHasArt = function() return false end
    E.open("zones")
    check(E.canvas.hasArt == false and E.canvas.msg.text:find("no map art"), "no-art message")
    E.useTool("polygon")
    check(E.draft == nil, "drew on a zone with no art")
    E.addNamed("Goldshire")
    check(ns.Config.zones["Elwynn Forest"].areas[4].subzone == "Goldshire",
        "named areas stopped working")

    wow.install()
    wow.zone, wow.mapID = "Elwynn Forest", 1429
    wow.templateRaises = true
    local ns2 = wow.load(ROOT)
    login(ns2)
    ns2.dispatch("ui")
    check(ns2.Editor.built and ns2.Editor.isShown(), "the window did not build without templates")

    wow.install()
    local ns3 = wow.load(ROOT)
    login(ns3)
    _G.CreateFrame = function() error("CreateFrame refused") end
    ns3.dispatch("ui")
    check(wow.chatMatches("could not be built") ~= nil, "a failed build was not reported")
    check(ns3.frame ~= nil and SlashCmdList.DYNAMICAMBIANCE ~= nil, "the addon went down with it")
end)

test("the editor registers an options panel through the Settings API", function()
    local calls = {}
    wow.install()
    _G.Settings.RegisterCanvasLayoutCategory = function(frame, name)
        calls.canvas = name
        return { name = name }
    end
    _G.Settings.RegisterAddOnCategory = function(cat) calls.addon = cat end
    local ns = wow.load(ROOT)
    check(calls.canvas == "Dynamic Ambiance" and calls.addon and calls.addon.name == "Dynamic Ambiance",
        "not registered")
    check(ns.Editor.built == false, "registering the panel built the editor")
end)

-- Review fixes, UI delivery 1 -------------------------------------------------------
--
-- Each of these reproduces a finding from the review of delivery 1 and failed
-- before its fix.

-- The client's tonumber is strtod underneath and reads "nan" as a number. Lua 5.4's
-- does not, so the test puts the client's behaviour back for the duration.
local function withClientTonumber(fn)
    local real = tonumber
    _G.tonumber = function(v, base)
        if type(v) == "string" and v:lower() == "nan" then return 0 / 0 end
        return real(v, base)
    end
    local ok, err = pcall(fn)
    _G.tonumber = real
    if not ok then error(err, 0) end
end

local function isFinite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Every CVar write so far was a finite number, or the first one that was not.
local function allWritesFinite(ns)
    for _, w in ipairs(wow.writes) do
        if not isFinite(tonumber(w.value)) then return false, w.name .. " = " .. tostring(w.value) end
    end
    return true
end

test("review 1: nan, inf and 1e999 in any numeric box never reach a zone or a CVar", function()
    local ns, E = editorAt()
    E.open("zones")
    frames(ns, 3)
    wow.writes = {}
    local z = ns.Config.zones["Elwynn Forest"]
    local area = z.areas[3]                              -- the chapel forecourt circle
    local BAD = { "nan", "NaN", "inf", "-inf", "1e999", "-1e999" }
    withClientTonumber(function()
        check(tonumber("nan") ~= tonumber("nan"), "the stand-in tonumber does not read nan")
        E.selected = nil
        E.refresh()
        for _, text in ipairs(BAD) do
            E.zoneRows.contrast.box.commit(text)
            E.zoneRows.gamma.box.commit(text)
            E.metaVersion.commit(text)
        end
        check(z.contrast == 35, "the zone contrast box took a non-finite value: " .. tostring(z.contrast))
        check(z.gamma == nil, "the zone gamma box took a non-finite value: " .. tostring(z.gamma))
        check(z.meta.version == 1, "the version box took a non-finite value: " .. tostring(z.meta.version))

        E.selected = area
        E.refresh()
        for _, text in ipairs(BAD) do
            E.areaRows.brightness.box.commit(text)
            E.areaPriority.commit(text)
            E.innerBox.commit(text)
            E.fadeBox.commit(text)
        end
        local a = E.selected
        check(a.brightness == 25 and a.priority == 20 and a.innerYards == 11.3
            and a.falloffYards == 56.7, ("an area box took a non-finite value: b=%s p=%s in=%s out=%s")
            :format(tostring(a.brightness), tostring(a.priority), tostring(a.innerYards),
                tostring(a.falloffYards)))

        E.useTool("polygon")
        for _, text in ipairs(BAD) do
            E.draftFade.commit(text)
            check(E.draft.fadeYards == 5 and E.draft.falloffYards == 5,
                "the draft fade box took " .. text)
        end
        E.setDraftFade(0 / 0)
        check(E.draft.fadeYards == 5, "setDraftFade took a NaN")
        E.cancelDraft()
    end)

    -- The model calls, which every box and slider ends in, refuse one too.
    E.selected = z.areas[1]
    E.setArea(E.selected, "priority", math.floor(0 / 0))
    E.setZoneValue("brightness", 1 / 0)
    E.setMeta("version", -1 / 0)
    check(E.selected.priority == 10 and z.brightness == 78 and z.meta.version == 1,
        "setArea / setZoneValue / setMeta took a non-finite value")

    frames(ns, 2)
    local ok, bad = allWritesFinite(ns)
    check(ok, "a non-finite value reached a CVar: " .. tostring(bad))
end)

test("review 1: the CVar writes refuse a non-finite value from any path, and the ease recovers",
    function()
    local ns, E = editorAt()
    frames(ns, 3)
    local z = ns.Config.zones["Elwynn Forest"]
    wow.position = { 0.1, 0.9 }                           -- nowhere near an area: zone values
    frames(ns, 5)
    wow.writes = {}
    z.contrast, z.gamma = 0 / 0, 1 / 0                    -- straight into the table, no editor
    ns.refreshTarget(true)
    frames(ns, 2)
    local ok, bad = allWritesFinite(ns)
    check(ok, "a non-finite value reached a CVar: " .. tostring(bad))
    check(isFinite(ns.state.curC) and isFinite(ns.state.curG), "the ease went non-finite")
    check(tonumber(wow.cvars.Contrast) ~= nil and isFinite(tonumber(wow.cvars.Contrast)),
        "the Contrast CVar lost its last good value: " .. tostring(wow.cvars.Contrast))

    z.contrast, z.gamma = 60, nil
    ns.refreshTarget(true)
    frames(ns, 5)
    check(near(ns.state.curC, 60) and near(wow.lastWrite("Contrast"), 60, 0.5),
        "the ease did not recover: curC " .. tostring(ns.state.curC))

    -- /amb off with a NaN in play still lands the baseline (review scenario A).
    z.contrast = 0 / 0
    ns.refreshTarget(true)
    frames(ns, 1)
    ns.dispatch("off")
    frames(ns, 10)
    check(near(tonumber(wow.cvars.Contrast), 50, 0.01), "off did not restore: " .. tostring(wow.cvars.Contrast))
    ok, bad = allWritesFinite(ns)
    check(ok, "a non-finite value reached a CVar: " .. tostring(bad))

    -- The writes themselves, with nothing upstream to catch it: a baseline that
    -- is not a number keeps each CVar at its last good value.
    local lastC, lastG = wow.cvars.Contrast, wow.cvars.Gamma
    ns.Config.baseline.contrast, ns.Config.baseline.gamma = 0 / 0, -1 / 0
    wow.writes = {}
    ns.restoreBaseline()
    check(wow.cvars.Contrast == lastC and wow.cvars.Gamma == lastG,
        "restoreBaseline wrote a non-finite value: " .. tostring(wow.cvars.Contrast) .. " / "
        .. tostring(wow.cvars.Gamma))
    check(wow.writesTo("Brightness") == 1, "the finite half of the pair was not written")

    -- A "nan" an older build left in Config.wtf is replaced, not adopted.
    wow.install()
    wow.zone, wow.mapID, wow.position = "Elwynn Forest", 1429, { 0.1, 0.9 }
    wow.cvars.Contrast = "nan"
    local ns2 = wow.load(ROOT)
    login(ns2)
    frames(ns2, 3)
    check(isFinite(tonumber(wow.cvars.Contrast)), "a stored nan was kept: " .. tostring(wow.cvars.Contrast))
end)

local function signed(ns, body) return body .. "~" .. ns.Preset.checksum(body) end

local ELWYNN_OFFER = "DA2~Elwynn Forest~10~95~~1429~z:theirs:10:5:95:::"

test("review 2A: during an import preview the editor edits nothing, snapshots nothing; Decline restores",
    function()
    local ns, E = editorAt()
    E.open("zones")
    local mine = ns.Config.zones["Elwynn Forest"]
    E.selected = mine.areas[1]
    local undoDepth = #E.undoStack
    E.open("import")
    check(E.importText(signed(ns, ELWYNN_OFFER)), "the offer did not open")
    check(E.locked(), "the editor is not locked while a preview is open")
    local theirs = ns.Config.zones["Elwynn Forest"]
    check(theirs ~= mine, "the preview did not swap the zone in")

    E.selected = nil
    E.setZoneValue("contrast", 20)
    E.setMeta("name", "mine now")
    check(E.addNamed("Goldshire") == nil and E.addArea({ subzone = "X", contrast = 1 }) == nil,
        "added an area to the previewed zone")
    E.setArea(theirs.areas[1], "contrast", 1)
    check(E.deleteArea(theirs.areas[1]) == false, "deleted from the previewed zone")
    E.useTool("polygon")
    click(E, 0.2, 0.2)
    check(E.draft == nil or #E.draft.corners == 0, "drew on the previewed zone")
    E.useTool("select")
    check(theirs.contrast == 10 and theirs.meta == nil and #theirs.areas == 1
        and theirs.areas[1].contrast == 5, "the previewed zone was edited")
    check(#E.undoStack == undoDepth, "the previewed zone was snapshotted for undo")
    check(E.undo() == false, "undo ran during the preview")
    check(E.message == E.LOCK_NOTE, "the refusal was not said: " .. tostring(E.message))
    local _, preview = E.footerText()
    check(preview:find(E.LOCK_NOTE, 1, true) ~= nil, "the footer does not show the lock: " .. preview)

    ns.closeOffer(false)
    check(not E.locked(), "still locked after Decline")
    check(ns.Config.zones["Elwynn Forest"] == mine and mine.contrast == 35, "Decline did not restore")
    check(E.selected == mine.areas[1], "the editor's selection was not restored")
    check(E.undo() == false, "Undo after Decline brought something back")
    check(ns.Config.zones["Elwynn Forest"] == mine and mine.contrast == 35 and #mine.areas == 3,
        "Undo after Decline put the declined preset back")
    E.setZoneValue("contrast", 22)
    check(mine.contrast == 22, "editing did not come back after Decline")
end)

test("review 2B: Save to file during an import preview generates nothing and clears nothing",
    function()
    local ns, E = editorAt()
    E.open("zones")
    E.setZoneValue("brightness", 44)
    check(E.dirtyCount() == 1, "setup: one unsaved zone")
    local draftBefore = draftText()
    E.open("import")
    E.importText(signed(ns, ELWYNN_OFFER))
    E.open("save")
    local text = E.selectAll()
    check(not text:find('"theirs"', 1, true), "Save to file generated the previewed zone")
    check(text:find(E.LOCK_NOTE, 1, true) ~= nil, "the save box does not say why: " .. text)
    check(E.saveNote.text == E.LOCK_NOTE, "the save panel note does not show the lock")
    check(ns.Config.zones["Elwynn Forest"].meta == nil, "the previewed zone was stamped as exported")
    E.draftPending = true
    E.flushDraft()
    check(draftText() == draftBefore, "the recovery draft took the previewed zone")

    ns.closeOffer(false)
    check(E.dirtyCount() == 1, "Select all during the preview cleared the unsaved count")
    check(not draftText():find('theirs', 1, true),
        "the recovery draft holds the declined preset")
    text = E.selectAll()
    check(text:find("brightness = 44", 1, true) and not text:find('"theirs"', 1, true),
        "Save to file after Decline is not the player's own zone")
    check(E.dirtyCount() == 0, "Select all after Decline did not clear")

    -- Accepting unlocks too, with nothing selected in the replaced zone.
    E.open("import")
    E.importText(signed(ns, ELWYNN_OFFER))
    ns.dispatch("import accept")
    check(not E.locked() and E.selected == nil, "Import left the editor locked or selecting")
    E.setZoneValue("contrast", 12)
    check(ns.Config.zones["Elwynn Forest"].contrast == 12, "editing did not come back after Import")
end)

test("review 3: no keyboard capture in combat; combat drops it; a propagate that did not take disables it",
    function()
    local ns, E = editorAt()
    E.open("zones")
    wow.propagateBlockedInCombat = true
    local f = E.canvas.frame
    local exit = wow.frameNamed("DynamicAmbianceEditorExit")
    check(exit.events.PLAYER_REGEN_DISABLED and exit.events.PLAYER_REGEN_ENABLED,
        "the editor does not listen for combat")

    E.useTool("polygon")
    for _, p in ipairs({ { 0.2, 0.2 }, { 0.3, 0.2 } }) do
        wow.time = wow.time + 1
        click(E, p[1], p[2])
    end
    check(f.keyboard == true and f.propagate == true, "no capture out of combat")

    wow.inCombat = true
    wow.fireAll("PLAYER_REGEN_DISABLED")
    check(f.keyboard == false, "combat did not drop the keyboard")
    wow.time = wow.time + 1
    click(E, 0.3, 0.3)
    check(f.keyboard == false, "a corner in combat started a capture")
    check(E.setKeyboard(true) == false and f.keyboard == false, "setKeyboard captured in combat")

    -- A capture that somehow outlived the event lets go on the next key.
    f.keyboard, f.propagate = true, false
    f.scripts.OnKeyDown(f, "W")
    check(f.keyboard == false, "a key in combat was captured")

    -- The mouse still closes it in combat.
    E.setDraftFade(10)
    wow.time = wow.time + 1
    click(E, 0.2, 0.2)
    check(E.draft == nil and #ns.Config.zones["Elwynn Forest"].areas == 4,
        "the polygon could not be closed by mouse in combat")

    wow.inCombat = false
    wow.fireAll("PLAYER_REGEN_ENABLED")
    E.useTool("polygon")
    wow.time = wow.time + 1
    click(E, 0.6, 0.6)
    check(f.keyboard == true, "no capture after combat")

    -- A client that silently refuses the propagate: read back, and off.
    function f:SetPropagateKeyboardInput() end
    f.propagate = false
    check(E.setKeyboard(true) == false and f.keyboard == false,
        "kept a capture whose keys cannot be passed on")
end)

test("review 4a: a new shape with no values exports, re-imports exactly, and is labelled", function()
    local ns, E = editorAt()
    E.open("zones")
    E.useTool("polygon")
    E.setDraftFade(20)
    for _, p in ipairs({ { 0.2, 0.2 }, { 0.3, 0.2 }, { 0.3, 0.3 } }) do
        wow.time = wow.time + 1
        click(E, p[1], p[2])
    end
    E.setDraftFade(20)
    local a = E.finishDraft()
    check(a and ns.Preset.inert(a), "setup: the new shape should have no values")

    local s = ns.Serialize.presetString("Elwynn Forest")
    local name, zone = ns.Preset.parse(s)
    local ok, problems = ns.Preset.validate(name, zone)
    check(ok, "the editor's own export is refused: " .. table.concat(problems or {}, "; "))
    local back = zone and zone.areas[4]
    check(back and back.corners and #back.corners == 6 and back.falloffYards == 20
        and back.contrast == nil and back.brightness == nil and back.gamma == nil,
        "the inert area did not come back as drawn")
    check(zone and ns.Preset.serialize(name, zone) == s, "the round trip is not exact")

    local labelled = false
    for _, it in ipairs(E.listItems()) do
        if it.area == a then labelled = it.inert and it.text:find("does nothing yet", 1, true) ~= nil end
    end
    check(labelled, "the list does not say the area does nothing yet")
    E.open("save")
    check(E.saveNote.text:find("does nothing yet", 1, true)
        and E.saveNote.text:find("Elwynn Forest: area 4", 1, true),
        "the save panel does not name it: " .. tostring(E.saveNote.text))
    E.selected = a
    E.setArea(a, "contrast", 40)
    E.open("save")
    check(E.saveNote.text == "", "the note stayed after the area got a value")
end)

test("review 4b: a named area never has an empty subzone", function()
    local ns, E = editorAt()
    E.open("zones")
    check(E.addNamed() == nil, "the Named tool made an area with no subzone")
    check(#ns.Config.zones["Elwynn Forest"].areas == 3, "an area was added anyway")
    ns.dispatch("ui named Goldshire")
    local a = ns.Config.zones["Elwynn Forest"].areas[4]
    check(a and a.subzone == "Goldshire", "/amb ui named did not add it")
    E.selected = a
    E.refresh()
    E.subzoneBox.commit("   ")
    check(a.subzone == "Goldshire", "the subzone box emptied it: " .. tostring(a.subzone))
    wow.subzone = "Northshire Valley"
    E.useTool("named")
    check(ns.Config.zones["Elwynn Forest"].areas[5].subzone == "Northshire Valley",
        "the current subzone is no longer prefilled")
    local s = ns.Serialize.presetString("Elwynn Forest")
    local name, zone = ns.Preset.parse(s)
    check(name and ns.Preset.validate(name, zone), "the export does not re-import")
end)

test("review 4c: validate refuses a non-finite number anywhere; the generators never write one",
    function()
    local ns = load()
    local P = ns.Preset
    local function refused(zone)
        local ok, list = P.validate("D", zone)
        return (not ok) and table.concat(list, "; ") or nil
    end
    local nan, inf = 0 / 0, 1 / 0
    local cases = {
        { "priority", { map = 1, areas = { { subzone = "A", priority = inf, contrast = 50 } } } },
        { "priority", { map = 1, areas = { { subzone = "A", priority = nan, contrast = 50 } } } },
        { "map",      { map = inf, areas = {} } },
        { "version",  { map = 1, meta = { version = inf }, areas = {} } },
        { "x",        { map = 1, areas = { { x = nan, y = 0.5, innerYards = 1, falloffYards = 2,
                                             contrast = 50 } } } },
        { "innerYards", { map = 1, areas = { { x = 0.5, y = 0.5, innerYards = nan,
                                               falloffYards = 2, contrast = 50 } } } },
        { "falloffYards", { map = 1, areas = { { corners = { 0.1, 0.1, 0.2, 0.1, 0.2, 0.2 },
                                                 falloffYards = inf, contrast = 50 } } } },
        { "corner",   { map = 1, areas = { { corners = { 0.1, nan, 0.2, 0.1, 0.2, 0.2 },
                                             falloffYards = 1, contrast = 50 } } } },
        { "contrast", { contrast = nan, areas = {} } },
        { "gamma",    { map = 1, areas = { { subzone = "A", gamma = -inf } } } },
        { "priority", { map = 1, indoors = { priority = nan, contrast = 50 }, areas = {} } },
    }
    for _, c in ipairs(cases) do
        local why = refused(c[2])
        check(why and why:find(c[1], 1, true) and why:find("not a finite number", 1, true),
            c[1] .. " was not refused as non-finite: " .. tostring(why))
    end

    -- The review's string: priority 1e999 parses to inf and must not validate.
    local body = "DA2~Duskwood~60~40~~~z:x:1e999:50::::"
    local name, zone = P.parse(signed(ns, body))
    check(name and not P.validate(name, zone), "priority 1e999 validated")

    -- Neither generator writes one.
    local s, err = P.serialize("Duskwood", zone)
    check(s == nil and tostring(err):find("finite", 1, true), "serialize wrote a non-finite priority")
    local text = ns.Serialize.zonesFile({ Duskwood = zone, Other = { contrast = nan, map = 1,
        areas = { { corners = { 0.1, 0.1, 0.2, inf, 0.2, 0.2 }, falloffYards = 1 } } } },
        "now", "x")
    for line in text:gmatch("[^\n]+") do
        if not line:find("^%s*%-%-") then
            check(not line:find("inf") and not line:find("nan"), "the generator wrote: " .. line)
        end
    end
    local chunk = (loadstring or _G.load)(text)
    local ns2 = { Config = {} }
    check(pcall(chunk, "DynamicAmbiance", ns2), "the generated file does not load")
    check(ns2.Config.zones and ns2.Config.zones.Duskwood.areas[1].priority == nil,
        "the dropped field came back as something")
end)

test("review 4d: a preset with an empty zone name is refused with a reason, not a table", function()
    local ns = load()
    for _, body in ipairs({ "DA2~~50~50~~", "DA1~~50~50~" }) do
        local name, err = ns.Preset.parse(signed(ns, body))
        check(name == nil and type(err) == "string", body .. " gave a " .. type(err))
    end
    local ns2, E = editorAt()
    E.open("import")
    check(E.importText(signed(ns2, "DA2~~50~50~~")) == false
        and E.importError:find("no zone name", 1, true), "the import box: " .. tostring(E.importError))
end)

test("review 5: a map mismatch warns once per zone entry, not once per refresh", function()
    wow.zone, wow.subzone, wow.mapID = "Elwynn Forest", "", 1437     -- a micro map in Elwynn
    wow.position = { 0.49, 0.41 }
    local ns = wow.load(ROOT)
    login(ns)
    local E = ns.Editor
    E.open("zones")
    local function warnings()
        local n = 0
        for _, m in ipairs(wow.chat) do
            if m:find("positional areas skipped", 1, true) then n = n + 1 end
        end
        return n
    end
    frames(ns, 1)
    check(warnings() == 1, "entering the zone warned " .. warnings() .. " times")
    local z = ns.Config.zones["Elwynn Forest"]
    E.selected = z.areas[3]
    E.onCanvasDown("LeftButton", z.areas[3].x, z.areas[3].y)
    for i = 1, 30 do E.onCanvasMove(z.areas[3].x + i * 0.0005, z.areas[3].y, true) end
    E.onCanvasUp("LeftButton", 0, 0)
    frames(ns, 2)
    check(warnings() == 1, "a 30-step drag warned " .. (warnings() - 1) .. " more times")

    wow.zone = "Westfall"
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    wow.zone = "Elwynn Forest"
    ns.frame:Fire("ZONE_CHANGED_NEW_AREA")
    frames(ns, 1)
    check(warnings() == 2, "re-entering the zone did not warn again: " .. warnings())
end)

test("review 6: a Config.lua with no baseline.gamma defaults it to 1.0, says so, and runs", function()
    wow.afterFile = function(file, ns)
        if file == "Config.lua" then ns.Config.baseline.gamma = nil end
    end
    wow.zone = "Elwynn Forest"
    local ns = wow.load(ROOT)
    wow.afterFile = nil
    check(ns.Config.baseline.gamma == 1.0, "not defaulted: " .. tostring(ns.Config.baseline.gamma))
    local n = 0
    for _, m in ipairs(wow.chat) do if m:find("baseline.gamma", 1, true) then n = n + 1 end end
    check(n == 1, n .. " warnings about it")
    login(ns)
    local ok, err = pcall(frames, ns, 1)
    check(ok, "the loop raised: " .. tostring(err))
    check(isFinite(ns.state.curG) and isFinite(ns.state.tgtG), "Gamma is not a number in the ease")
end)

test("review 7: the installer leaves a game-folder Zones.lua that differs from the repo's", function()
    -- Read, not run: running it would install into the game folder. What it has
    -- to contain is the switch, the comparison and a copy that skips the file.
    local fh = assert(io.open(ROOT .. "/scripts/install-addon.ps1", "r"))
    local text = fh:read("*a")
    fh:close()
    check(text:find("[switch]$OverwriteZones", 1, true) ~= nil, "no -OverwriteZones switch")
    check(text:find("Get-FileHash", 1, true) and text:find("-ne $gameHash", 1, true),
        "the game copy is not compared with the repo's")
    check(text:find('$_.Name -ne "Zones.lua"', 1, true) ~= nil, "the skip does not leave Zones.lua out")
    check(text:find("NOT overwritten", 1, true) and text:find("-OverwriteZones", 1, true)
        and text:find("Copy it back into the repo", 1, true), "the message does not say what to do")
end)

-- Feedback round 1 (design/ui/feedback-1.md) ------------------------------------------
--
-- The operator's acceptance run of delivery 1, items 1-12 of "Resolved into
-- changes". Each test names its item.

test("feedback 1: the view maps both ways at every zoom, zooms about the cursor, pans and clamps", function()
    local R = load().Raster
    local w, h = 1002, 668
    local v = R.newView()
    check(v.zoom == 1 and v.ox == 0 and v.oy == 0, "a new view is not at fit")

    -- Round trip at several zoom levels, with the view pushed around each time.
    for _, z in ipairs({ 1, 1.25, 2, 3.2, 4 }) do
        R.zoomAt(v, z, 300, 200, w, h)
        R.panView(v, -137, 58, w, h)
        for _, p in ipairs({ { 0.1, 0.2 }, { 0.4921, 0.414 }, { 0.9, 0.95 } }) do
            local px, py = R.mapToView(v, p[1], p[2], w, h)
            local nx, ny = R.viewToMap(v, px, py, w, h)
            check(near(nx, p[1], 1e-9) and near(ny, p[2], 1e-9),
                ("zoom %s: %s,%s came back as %s,%s"):format(z, p[1], p[2], nx, ny))
            -- And through the cursor, as the canvas reads it.
            local s, left, top = 0.8, 100, 900
            local cx, cy = (left + px) * s, (top - py) * s
            local cnx, cny, inside, cpx, cpy = R.cursorToMap(cx, cy, s, left, top, w, h, v)
            local on = px >= 0 and px <= w and py >= 0 and py <= h
            check(inside == on and near(cpx, px, 1e-6) and near(cpy, py, 1e-6),
                ("zoom %s: cursor pixel %s,%s read back as %s,%s"):format(z, px, py, cpx, cpy))
            if on then
                check(near(cnx, p[1], 1e-9) and near(cny, p[2], 1e-9), "cursorToMap through the view")
            end
        end
    end

    -- Zoom about the cursor: the map point under it stays under it.
    v = R.newView()
    local bx, by = R.viewToMap(v, 700, 250, w, h)
    R.zoomAt(v, 2, 700, 250, w, h)
    local ax, ay = R.viewToMap(v, 700, 250, w, h)
    check(near(ax, bx, 1e-12) and near(ay, by, 1e-12), "the point under the cursor moved")
    R.zoomAt(v, 3, 700, 250, w, h)
    ax, ay = R.viewToMap(v, 700, 250, w, h)
    check(v.zoom == 3 and near(ax, bx, 1e-12) and near(ay, by, 1e-12), "a second zoom moved it")

    -- Clamped: 1 to 4, and never past the map's edge.
    R.zoomAt(v, 9, 0, 0, w, h)
    check(v.zoom == 4, "zoom was not capped at 4: " .. v.zoom)
    R.panView(v, 1e6, 1e6, w, h)
    check(v.ox == 0 and v.oy == 0, "a pan left the map's top-left edge")
    R.panView(v, -1e6, -1e6, w, h)
    check(v.ox == w * 3 and v.oy == h * 3, "a pan left the bottom-right edge: " .. v.ox .. "," .. v.oy)
    local fx, fy = R.viewToMap(v, w, h, w, h)
    check(near(fx, 1, 1e-12) and near(fy, 1, 1e-12), "the canvas corner is not the map corner")
    R.zoomAt(v, 0.2, 500, 300, w, h)
    check(v.zoom == 1 and v.ox == 0 and v.oy == 0, "zooming out past fit did not land on fit")
    -- Zooming about the canvas's top-left corner keeps the offset at 0.
    R.zoomAt(v, 2, 0, 0, w, h)
    check(v.ox == 0 and v.oy == 0, "zoom about the corner moved the corner")

    -- Clipping to the canvas.
    local x, y, cw, ch = R.clipRect(-10, 600, 50, 100, w, h)
    check(x == 0 and y == 600 and cw == 40 and ch == 68, "clipRect")
    check(R.clipRect(1100, 10, 5, 5, w, h) == nil, "a rectangle off the canvas was kept")
    local x1, y1, x2, y2 = R.clipSegment(-100, 334, 1102, 334, w, h)
    check(x1 == 0 and x2 == w and y1 == 334 and y2 == 334, "clipSegment across")
    check(R.clipSegment(-10, -10, -1, -5, w, h) == nil, "a segment off the canvas was kept")
    x1, y1, x2, y2 = R.clipSegment(10, 10, 20, 20, w, h)
    check(x1 == 10 and y2 == 20, "a segment inside was changed")
end)

test("feedback 1: wheel and buttons zoom the canvas, the art is cut to it, a drag pans and places nothing", function()
    local ns, E = editorAt()
    E.open("zones")
    local c = E.canvas
    check(E.zoomButtons and E.zoomButtons.zoomIn and E.zoomButtons.zoomOut and E.zoomButtons.reset,
        "the +, - and Reset buttons are missing")
    check(E.zoomButtons.zoomIn.text == "+" and E.zoomButtons.zoomOut.text == "-"
        and E.zoomButtons.reset.text == "Reset", "the zoom buttons' labels")

    -- The wheel, about the cursor at the canvas's centre.
    wow.cursor = { 501, 334 }
    c.frame.scripts.OnMouseWheel(c.frame, 1)
    check(near(c.view.zoom, 1.25, 1e-9), "the wheel did not zoom in: " .. c.view.zoom)
    c.frame.scripts.OnMouseWheel(c.frame, -1)
    check(near(c.view.zoom, 1, 1e-9), "the wheel did not zoom back out")
    E.zoomButtons.zoomIn.scripts.OnClick(E.zoomButtons.zoomIn, "LeftButton")
    E.zoomButtons.zoomIn.scripts.OnClick(E.zoomButtons.zoomIn, "LeftButton")
    E.zoomButtons.zoomIn.scripts.OnClick(E.zoomButtons.zoomIn, "LeftButton")
    E.zoomButtons.zoomIn.scripts.OnClick(E.zoomButtons.zoomIn, "LeftButton")
    check(c.view.zoom > 2 and c.view.zoom < 2.5, "+ did not step the zoom: " .. c.view.zoom)
    E.zoomButtons.reset.scripts.OnClick(E.zoomButtons.reset, "LeftButton")
    check(c.view.zoom == 1 and c.view.ox == 0 and c.view.oy == 0, "Reset did not go back to fit")
    for _ = 1, 20 do E.zoomButtons.zoomIn.scripts.OnClick(E.zoomButtons.zoomIn, "LeftButton") end
    check(c.view.zoom == 4, "zoom went past 4: " .. c.view.zoom)
    E.zoomButtons.reset.scripts.OnClick(E.zoomButtons.reset, "LeftButton")

    -- Zoomed, every tile shown lies inside the canvas.
    c:zoomTo(2, 501, 334)
    local shown = 0
    for _, t in ipairs(c.tiles) do
        if t.shown then
            shown = shown + 1
            local p = t.points[#t.points]
            local x, y = p[4], -p[5]
            check(x >= 0 and y >= 0 and x + t.w <= 1002 + 1e-6 and y + t.h <= 668 + 1e-6,
                ("a tile at %s,%s %sx%s spills off the canvas"):format(x, y, t.w, t.h))
        end
    end
    check(shown > 0 and shown < 12, "zoomed in, " .. shown .. " tiles are shown")
    E.renderCanvas()
    for _, l in ipairs(c.pools.line) do
        if l and l.shown then
            local s, e = l.startPoint, l.endPoint
            -- SetStartPoint("TOPLEFT", frame, x, -y)
            check(s[3] >= -1e-6 and s[3] <= 1002 + 1e-6 and -s[4] >= -1e-6 and -s[4] <= 668 + 1e-6
                and e[3] >= -1e-6 and e[3] <= 1002 + 1e-6 and -e[4] >= -1e-6 and -e[4] <= 668 + 1e-6,
                "a line was drawn off the canvas")
        end
    end

    -- Drawing through the view: a click at a canvas pixel lands on the map point under it.
    E.useTool("polygon")
    local nx, ny = ns.Raster.viewToMap(c.view, 400, 300, 1002, 668)
    E.onCanvasDown("LeftButton", nx, ny, true, 400, 300)
    E.onCanvasUp("LeftButton", nx, ny, true, 400, 302)             -- 2 px: still a click
    check(#E.draft.corners == 2 and E.draft.corners[1] == ns.Raster.round4(nx),
        "a click at 2x did not place its corner where it was")

    -- A drag of 40 px pans the map by 40 px and places nothing.
    local ox = c.view.ox
    wow.time = wow.time + 1
    E.onCanvasDown("LeftButton", nx, ny, true, 600, 300)
    E.onCanvasMove(nx, ny, true, 620, 300)
    E.onCanvasMove(nx, ny, true, 640, 300)
    E.onCanvasUp("LeftButton", nx, ny, true, 640, 300)
    check(near(c.view.ox, ox - 40, 1e-9), "the drag did not pan by 40 px: " .. (ox - c.view.ox))
    check(#E.draft.corners == 2, "a pan placed a corner")

    -- At fit there is nothing to pan, so a sloppy click is still a click.
    c:resetView()
    E.onCanvasDown("LeftButton", 0.3, 0.3, true, 300.6, 200.4)
    E.onCanvasMove(0.3, 0.3, true, 310, 200)
    E.onCanvasUp("LeftButton", 0.3, 0.3, true, 310, 200)
    check(#E.draft.corners == 4, "a click that moved at fit placed nothing")

    -- Select on empty map pans too, and keeps the selection; a click there drops it.
    E.useTool("select")
    local z = ns.Config.zones["Elwynn Forest"]
    E.selected = z.areas[3]
    c:zoomTo(2, 501, 334)
    ox = c.view.ox
    E.onCanvasDown("LeftButton", 0.95, 0.95, true, 900, 600)
    E.onCanvasMove(0.95, 0.95, true, 880, 600)
    E.onCanvasUp("LeftButton", 0.95, 0.95, true, 880, 600)
    check(E.selected == z.areas[3] and near(c.view.ox, ox + 20, 1e-9),
        "a pan in Select lost the selection or did not pan")
    E.onCanvasDown("LeftButton", 0.95, 0.95, true, 900, 600)
    E.onCanvasUp("LeftButton", 0.95, 0.95, true, 900, 600)
    check(E.selected == nil, "a click on empty map kept the selection")

    -- A new zone starts at fit.
    E.selectZone("Westfall", 1436)
    check(c.view.zoom == 1 and c.view.ox == 0, "the view did not reset for a new map")
end)

test("feedback 1: handles are hit at the same screen distance at any zoom", function()
    local ns, E = editorAt()
    E.open("zones")
    local a = E.addArea({ name = "sq", corners = { 0.4, 0.4, 0.5, 0.4, 0.5, 0.5, 0.4, 0.5 },
        falloffYards = 5, priority = 30, contrast = 90 })
    E.canvas:zoomTo(4, 501, 334)
    -- 6 canvas pixels from corner 3 at 4x is 1.5 art pixels: still within reach.
    local px, py = ns.Raster.mapToView(E.canvas.view, 0.5, 0.5, 1002, 668)
    local nx, ny = ns.Raster.viewToMap(E.canvas.view, px + 6, py, 1002, 668)
    check(E.hitHandle(a, nx, ny) == "corner", "a corner 6 px away at 4x was missed")
    nx, ny = ns.Raster.viewToMap(E.canvas.view, px + 12, py, 1002, 668)
    check(E.hitHandle(a, nx, ny) ~= "corner", "a corner 12 px away at 4x was hit")
end)

test("feedback 2 and 3: a click on any placed corner closes the polygon; the hints say how", function()
    local ns, E = editorAt()
    E.open("zones")
    local z = ns.Config.zones["Elwynn Forest"]
    local n = #z.areas
    E.useTool("polygon")
    check(E.canvas.hintShown == E.HINT_POLYGON and E.HINT_POLYGON ==
        "Left click: place a corner. Right click: remove the last corner. Click any corner to finish.",
        "the polygon hint: " .. tostring(E.canvas.hintShown))
    check(E.canvas.hintFrame.shown, "the hint strip is hidden")

    -- Two corners, then a click on the first: refused, nothing stacked on it.
    click(E, 0.2, 0.2)
    click(E, 0.3, 0.2)
    click(E, 0.2001, 0.2001)
    check(#E.draft.corners == 4 and E.draft ~= nil, "two corners closed, or a corner stacked")
    check(E.canvas.noticeShown:find("at least 3 corners", 1, true) ~= nil,
        "the refusal is not on the canvas: " .. tostring(E.canvas.noticeShown))

    -- Four corners, then corner 2 again: closed with the four, as Finish does.
    click(E, 0.3, 0.3)
    click(E, 0.2, 0.3)
    click(E, 0.3001, 0.2)
    check(E.draft == nil and #z.areas == n + 1, "clicking corner 2 did not close it")
    local a = z.areas[n + 1]
    check(a.corners and #a.corners == 8 and a.falloffYards == 5 and E.selected == a,
        "the closed shape is not the four corners with the default fade")

    -- Any corner at all, including the one just placed.
    for i, p in ipairs({ { 0.6, 0.6 }, { 0.7, 0.6 }, { 0.7, 0.7 } }) do
        if i == 1 then E.useTool("polygon") end
        click(E, p[1], p[2])
    end
    click(E, 0.7, 0.7)
    check(E.draft == nil and #z.areas == n + 2 and #z.areas[n + 2].corners == 6,
        "clicking the last corner did not close it")

    -- The circle's hint, the reshape hint on a selected polygon, and the pan hint.
    E.useTool("circle")
    check(E.canvas.hintShown == E.HINT_CIRCLE, "the circle hint")
    E.useTool("select")
    E.selected = z.areas[n + 2]
    E.refresh()
    check(E.canvas.hintShown == E.HINT_EDIT, "the reshape hint")
    E.selected = nil
    E.canvas:zoomTo(2)
    E.refresh()
    check(E.canvas.hintShown == E.HINT_PAN, "the pan hint")
    E.canvas:resetView()
    E.refresh()
    check(not E.canvas.hintFrame.shown or E.canvas.noticeShown ~= "", "an empty hint strip shows")
end)

test("feedback 4: midpoint handles insert corners and right-click deletes them, with the 3 and 32 limits",
    function()
    local ns, E = editorAt()
    E.open("zones")
    local z = ns.Config.zones["Elwynn Forest"]
    local a = E.addArea({ name = "sq", corners = { 0.4, 0.4, 0.5, 0.4, 0.5, 0.5, 0.4, 0.5 },
        falloffYards = 5, priority = 30, contrast = 90 })
    E.useTool("select")
    E.selected = a
    local areas = z.areas
    local undoDepth = #E.undoStack

    -- The midpoint of edge 1 (corner 1 to 2): a click inserts a corner there.
    check(E.hitHandle(a, 0.45, 0.4) == "mid", "no midpoint handle on edge 1")
    click(E, 0.45, 0.4)
    check(#a.corners == 10 and a.corners[3] == 0.45 and a.corners[4] == 0.4
        and a.corners[5] == 0.5, "the corner was not inserted after corner 1: "
        .. table.concat(a.corners, ","))
    check(z.areas == areas, "a corner insert replaced areas")
    check(#E.undoStack == undoDepth + 1, "the insert took " .. (#E.undoStack - undoDepth) .. " undo steps")

    -- Dragging a midpoint inserts and moves the new corner, in one undo step.
    local mx, my = ns.Raster.edgeMidpoint(a.corners, 5)        -- the closing edge, 5 back to 1
    E.onCanvasDown("LeftButton", mx, my, true)
    E.onCanvasMove(0.38, 0.44, true)
    E.onCanvasUp("LeftButton", 0.38, 0.44, true)
    check(#a.corners == 12 and a.corners[11] == 0.38 and a.corners[12] == 0.44,
        "a midpoint drag did not insert and move the new corner")
    check(#E.undoStack == undoDepth + 2, "the insert and its drag are not one undo step")

    -- The engine weighs the new shape at once.
    check(ns.polygonWeight(a.corners, 5, 0.39, 0.44, SW, SH) == 1, "the new corner is not live")

    -- Right-click on a corner deletes it, down to 3 and no further.
    E.onCanvasDown("RightButton", 0.38, 0.44, true)
    check(#a.corners == 10, "right-click did not delete the corner")
    check(E.selected == a, "deleting a corner lost the selection")
    E.onCanvasDown("RightButton", 0.45, 0.4, true)
    E.onCanvasDown("RightButton", 0.5, 0.5, true)
    check(#a.corners == 6, "corners after two more deletes: " .. #a.corners / 2)
    E.onCanvasDown("RightButton", 0.4, 0.4, true)
    check(#a.corners == 6, "a triangle lost a corner")
    check(E.canvas.noticeShown:find("at least 3 corners", 1, true)
        and E.message:find("at least 3 corners", 1, true), "the minimum was not said: "
        .. tostring(E.canvas.noticeShown))
    -- Right-click away from a corner still lets go of the selection.
    E.onCanvasDown("RightButton", 0.9, 0.9, true)
    check(E.selected == nil, "right-click off the corners kept the selection")

    -- Undo walks all of it back.
    for _ = 1, 3 do E.undo() end
    local now_ = ns.Config.zones["Elwynn Forest"].areas[#ns.Config.zones["Elwynn Forest"].areas]
    check(#now_.corners == 12, "undo did not bring the deleted corners back: " .. #now_.corners / 2)
    E.undo(); E.undo()
    now_ = ns.Config.zones["Elwynn Forest"].areas[#ns.Config.zones["Elwynn Forest"].areas]
    check(#now_.corners == 8 and now_.corners[3] == 0.5, "undo did not take the inserts back")

    -- At 32 corners a midpoint is refused, with the reason.
    local ring = {}
    for k = 0, 31 do
        local ang = k / 32 * 2 * math.pi
        ring[#ring + 1] = ns.Raster.round4(0.5 + 0.2 * math.cos(ang))
        ring[#ring + 1] = ns.Raster.round4(0.5 + 0.2 * math.sin(ang))
    end
    local big = E.addArea({ name = "ring", corners = ring, falloffYards = 5, priority = 5, contrast = 1 })
    E.selected = big
    mx, my = ns.Raster.edgeMidpoint(big.corners, 1)
    check(E.hitHandle(big, mx, my) == "mid", "setup: the ring's edge 1 has no midpoint handle")
    click(E, mx, my)
    check(#big.corners == 64, "a 33rd corner was inserted")
    check(E.canvas.noticeShown:find("at most 32 corners", 1, true) ~= nil,
        "the cap was not said: " .. tostring(E.canvas.noticeShown))
    check(E.insertCorner(big, 1, 0.5, 0.5) == nil and #big.corners == 64, "insertCorner passed the cap")

    -- The notice goes after a few seconds.
    wow.time = wow.time + E.NOTICE_SECONDS + 1
    E.onTick(nil, 1)
    check(E.canvas.noticeShown == "", "the notice stayed")
end)

test("feedback 5 and 6: Inherit default; priority buttons step, and 0 sets 0", function()
    local ns, E = editorAt()
    E.open("zones")
    check(E.zoneRows.gamma.inherit and E.INHERIT_LABEL == "Inherit default", "the label constant")
    local labelled = false
    for _, r in pairs(E.areaRows) do
        local t = r.inheritLabel
        labelled = t and t.text == "Inherit default" or labelled
    end
    check(labelled, "the area rows do not say Inherit default")

    -- The arithmetic.
    check(E.stepPriority(20, -10) == 10 and E.stepPriority(20, 5) == 25
        and E.stepPriority(20, 1) == 21 and E.stepPriority(20, -1) == 19, "steps")
    check(E.stepPriority(20, 0) == 0 and E.stepPriority(-7, 0) == 0, "0 does not set 0")
    check(E.stepPriority(0, -5) == -5 and E.stepPriority(nil, 10) == 10, "from 0 or nothing")
    check(E.stepPriority(9995, 10) == 9999 and E.stepPriority(-995, -10) == -999,
        "the steps leave the box's range")

    -- The buttons, in the operator's order.
    local labels = {}
    for i, b in ipairs(E.priorityButtons) do labels[i] = b.text end
    check(table.concat(labels, " ") == "-10 -5 -1 0 +1 +5 +10", "buttons: " .. table.concat(labels, " "))
    local z = ns.Config.zones["Elwynn Forest"]
    E.selected = z.areas[3]                             -- the forecourt, p20
    E.refresh()
    local before = z.areas
    E.priorityButtons[1].scripts.OnClick(E.priorityButtons[1], "LeftButton")
    check(E.selected.priority == 10 and z.areas ~= before, "-10 did not step (or mutated in place)")
    E.priorityButtons[7].scripts.OnClick(E.priorityButtons[7], "LeftButton")
    E.priorityButtons[6].scripts.OnClick(E.priorityButtons[6], "LeftButton")
    check(E.selected.priority == 25, "+10 then +5: " .. E.selected.priority)
    E.priorityButtons[4].scripts.OnClick(E.priorityButtons[4], "LeftButton")
    check(E.selected.priority == 0, "0 did not set 0: " .. E.selected.priority)
    check(E.areaPriority:GetText() == "0", "the typed box did not follow")
    E.areaPriority.commit("42")
    check(E.selected.priority == 42, "the typed box stopped working")
    check(ns.Config.priorityBands == nil, "the band buttons' table is still in Config.lua")
end)

test("feedback 7: notes are multi-line text areas several lines tall", function()
    local ns, E = editorAt()
    E.open("zones")
    check(E.metaNotes.multiLine and E.areaNotes.multiLine, "a notes box is single-line")
    check(E.metaNotesScroll.h >= 80 and E.areaNotesScroll.h >= 80, "a notes area is not several lines tall")
    check(not E.areaName.multiLine, "the name box became multi-line")
    local z = ns.Config.zones["Elwynn Forest"]
    E.selected = z.areas[3]
    E.refresh()
    local a = E.selected
    E.areaNotes.scripts.OnEditFocusGained(E.areaNotes)
    E.areaNotes:SetText("line one\nline two")
    E.areaNotes.scripts.OnEditFocusLost(E.areaNotes)
    check(a.notes == "line one\nline two", "the area note did not commit: " .. tostring(a.notes))
end)

test("feedback 8: Save to file raises a popup naming the step left to do", function()
    local ns, E = editorAt()
    E.open("zones")
    local dialog = StaticPopupDialogs[E.POPUP_SAVE]
    check(dialog and dialog.text == "Your changes are not saved yet. Read the steps on the right of "
        .. "the editor to save them to file." and dialog.button1 == "OK" and dialog.button2 == nil,
        "the popup's wording or button")
    wow.popupShown = nil
    ns.dispatch("ui save")
    check(wow.popupShown == E.POPUP_SAVE and E.panel == "save" and E.savePanel:IsShown(),
        "/amb ui save did not raise the popup over the steps panel")
    E.open("zones")
    wow.popupShown = nil
    E.openSave()
    check(wow.popupShown == E.POPUP_SAVE, "the Save to file button's path raised no popup")
    -- The unsaved-close popup's Save to file goes the same way.
    E.setZoneValue("contrast", 40)
    E.close()
    wow.popupShown = nil
    StaticPopupDialogs.DYNAMICAMBIANCE_UNSAVED.OnAccept()
    check(wow.popupShown == E.POPUP_SAVE and E.panel == "save", "the unsaved popup's path")
    -- No popup on this client: the words go on the canvas instead.
    StaticPopupDialogs[E.POPUP_SAVE] = nil
    E.openSave()
    check(E.canvas.noticeShown == E.SAVE_POPUP_TEXT, "no fallback without a popup")
end)

test("feedback 9: the small print names the Account folder; the draft is stored as lines", function()
    local ns, E = editorAt()
    local body = E.SAVE_TEXT:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check(body:find("WTF\\Account\\<your account>\\SavedVariables\\DynamicAmbiance.lua", 1, true)
        and body:find("not WTF\\SavedVariables\\", 1, true) and body:find("editor.draftLines", 1, true),
        "the small print does not name the folder exactly")

    -- Lines, with no quote marks for the client to escape, even for an apostrophe
    -- or a closing bracket in a name.
    local zones = {
        ["Elwynn Forest"] = { contrast = 35, map = 1429, meta = { name = "Lion's test", version = 1 },
            areas = { { subzone = "Lion's Pride Inn", priority = 10, contrast = 40 },
                      { name = "odd ]] name]", corners = { 0.1, 0.1, 0.2, 0.1, 0.2, 0.2 },
                        falloffYards = 5, priority = 10 } } },
    }
    local lines = ns.Serialize.draftLines(zones)
    check(#lines > 10, "not lines: " .. #lines)
    for i, line in ipairs(lines) do
        check(not line:find('"', 1, true) and not line:find("\n", 1, true),
            "line " .. i .. " would be escaped in the WTF file: " .. line)
    end
    local got = loadZonesText(table.concat(lines, "\n"))
    local ok, why = sameTable(zones["Elwynn Forest"], got and got["Elwynn Forest"])
    check(ok, "the lines do not load back field-for-field: " .. tostring(why))

    -- Every kind of area, and strings that need escapes, still round-trip.
    local all = { ["Elwynn Forest"] = every4Kinds() }
    got = loadZonesText(table.concat(ns.Serialize.draftLines(all), "\n"))
    ok, why = sameTable(all["Elwynn Forest"], got and got["Elwynn Forest"])
    check(ok, "every kind does not survive the lines: " .. tostring(why))

    -- The editor writes them, and only them.
    E.open("zones")
    E.setZoneValue("brightness", 66)
    local d = DynamicAmbianceDB.editor
    check(type(d.draftLines) == "table" and d.draft == nil, "the editor did not write draftLines alone")
    got = loadZonesText(draftText())
    check(got and got["Elwynn Forest"].brightness == 66, "the draft lines lack the change")
end)

test("feedback 10 and 11: Fade defaults to 5, maps to falloffYards both ways, and needs no sums", function()
    local ns, E = editorAt()
    check(ns.Config.editor and ns.Config.editor.defaultFadeYards == 5 and E.defaultFade() == 5,
        "Config.editor.defaultFadeYards is not 5")

    -- The mapping, both ways.
    check(E.fadeToFalloff("circle", 11.3, 5) == 16.3 and E.fadeToFalloff("polygon", nil, 5) == 5,
        "fade to falloff")
    check(near(E.falloffToFade("circle", 11.3, 56.7), 45.4, 1e-9)
        and E.falloffToFade("polygon", nil, 25) == 25, "falloff to fade")
    check(E.falloffToFade("circle", 20, 10) == 0, "an inside-out circle shows a negative fade")
    for _, c in ipairs({ { 0, 0 }, { 11.3, 45.4 }, { 20, 5 } }) do
        local f = E.fadeToFalloff("circle", c[1], c[2])
        check(near(E.falloffToFade("circle", c[1], f), c[2], 1e-9), "the circle round trip")
    end
    check(E.fadeToFalloff("circle", 1, 0 / 0) == nil and E.falloffToFade("circle", 1, 1 / 0) == nil,
        "a non-finite value got through the mapping")

    -- A selected circle shows its fade and keeps it when the inner radius moves.
    E.open("zones")
    local z = ns.Config.zones["Elwynn Forest"]
    E.selected = z.areas[3]                             -- 11.3 / 56.7
    E.refresh()
    check(E.fadeBox:GetText() == "45.4", "the forecourt's fade: " .. E.fadeBox:GetText())
    local a = E.selected
    E.innerBox.commit("20")
    check(a.innerYards == 20 and a.falloffYards == 65.4, "the fade did not ride on the inner radius: "
        .. tostring(a.falloffYards))
    E.fadeBox.commit("10")
    check(a.falloffYards == 30, "the fade box did not set inner + fade: " .. tostring(a.falloffYards))
    check(ns.Preset.validate("Elwynn Forest", z), "the circle no longer validates")

    -- The inner handle carries the fade with it too. (Radii big enough that the
    -- inner and outer handles are apart on screen at fit.)
    E.innerBox.commit("60")
    E.fadeBox.commit("40")
    local W = E.scale()
    E.onCanvasDown("LeftButton", a.x + 60 / W, a.y, true)
    check(E.drag and E.drag.kind == "inner", "setup: not the inner handle")
    E.onCanvasMove(a.x + 80 / W, a.y, true)
    E.onCanvasUp("LeftButton", a.x + 80 / W, a.y, true)
    check(near(a.innerYards, 80, 0.05) and near(a.falloffYards - a.innerYards, 40, 0.05),
        "the inner handle did not keep the fade: " .. a.innerYards .. " / " .. a.falloffYards)

    -- A polygon's fade is its falloff.
    local p = E.addArea({ name = "p", corners = { 0.1, 0.1, 0.2, 0.1, 0.2, 0.2 }, falloffYards = 25,
        priority = 10, contrast = 5 })
    E.refresh()
    check(E.fadeBox:GetText() == "25" and E.fadeNote.text == E.FADE_NOTE_POLYGON, "the polygon's fade")
    E.fadeBox.commit("7.5")
    check(p.falloffYards == 7.5, "the polygon's fade did not set its falloff")

    -- Refused values: beside the box, in a popup, and nothing changed.
    wow.popupShown = nil
    E.fadeBox.commit("-3")
    check(p.falloffYards == 7.5, "a negative fade was stored")
    check(wow.popupShown == E.POPUP_FIELD and StaticPopupDialogs[E.POPUP_FIELD].button1 == "OK",
        "no popup for the refused value")
    check(E.fieldErr and E.fieldErr.box == E.fadeBox and E.errLabel.shown
        and E.errLabel.text:find("Fade (yd)", 1, true), "the reason is not beside the box")
    E.fadeBox.commit("8")
    check(p.falloffYards == 8 and not E.errLabel.shown, "a good value did not clear the reason")
    E.metaVersion.commit("1.5")
    check(E.fieldErr and E.fieldErr.box == E.metaVersion, "the version box's refusal is not beside it")

    -- A new circle: the fade box is 5, Finish needs nothing more, and no inner-radius error exists.
    E.useTool("circle")
    E.onCanvasDown("LeftButton", 0.6, 0.6)
    E.onCanvasMove(0.6 + 30 / SW, 0.6, true)
    E.onCanvasUp("LeftButton", 0.6 + 30 / SW, 0.6)
    check(E.draftFade:GetText() == "5", "the new circle's fade box: " .. tostring(E.draftFade:GetText()))
    local c = E.finishDraft()
    check(c and c.innerYards == 30 and c.falloffYards == 35, "the circle is not inner + 5: "
        .. tostring(c and c.falloffYards))
    -- Only an emptied box can stop Finish, and it says so beside the box.
    E.useTool("polygon")
    for _, q in ipairs({ { 0.1, 0.5 }, { 0.2, 0.5 }, { 0.2, 0.6 } }) do click(E, q[1], q[2]) end
    E.draftFade.commit("")
    check(E.draft.fadeYards == 5 and E.fieldErr and E.fieldErr.box == E.draftFade,
        "an emptied fade box was taken, or not refused beside it")
    check(E.finishDraft() ~= nil, "Finish was stopped by a fade that stayed 5")
end)

test("feedback 12: combat hides the editor and brings it back with the shape, selection, tool and zoom", function()
    local ns, E = editorAt()
    E.open("zones")
    local f = wow.frameNamed("DynamicAmbianceEditor")
    E.setZoneValue("contrast", 41)                      -- an unsaved zone: no popup on this hide
    E.canvas:zoomTo(2.5, 300, 200)
    E.canvas:panBy(-50, 20)
    local view = { E.canvas.view.zoom, E.canvas.view.ox, E.canvas.view.oy }
    E.useTool("polygon")
    click(E, 0.4, 0.4)
    click(E, 0.45, 0.4)
    local draft = E.draft

    wow.chat, wow.popupShown = {}, nil
    wow.inCombat = true
    wow.fireAll("PLAYER_REGEN_DISABLED")
    check(not f:IsShown() and E.combatHidden, "combat did not hide the window")
    check(wow.chatMatches("hidden while you are in combat") ~= nil, "no chat line says why")
    check(wow.popupShown == nil, "the combat hide asked about unsaved zones")
    check(E.draft == draft and #draft.corners == 4 and E.tool == "polygon",
        "the shape being drawn was torn down")
    check(E.canvas.view.zoom == view[1] and E.canvas.view.ox == view[2] and E.canvas.view.oy == view[3],
        "the view moved")
    check(E.canvas.frame.keyboard == false, "the keyboard was kept in combat")

    -- Asking for it in combat waits for the end of combat.
    wow.chat = {}
    ns.dispatch("ui")
    check(not f:IsShown() and wow.chatMatches("opens when combat ends") ~= nil,
        "/amb ui in combat opened it, or did not say when it would")

    wow.inCombat = false
    wow.fireAll("PLAYER_REGEN_ENABLED")
    check(f:IsShown() and not E.combatHidden, "the window did not come back")
    check(E.draft == draft and #draft.corners == 4 and E.tool == "polygon",
        "the shape did not come back as it was")
    check(E.canvas.view.zoom == view[1] and E.canvas.view.ox == view[2], "the zoom did not come back")
    check(E.canvas.frame.keyboard == true, "the drawing keyboard did not come back")
    click(E, 0.45, 0.45)
    click(E, 0.4, 0.4)
    check(E.draft == nil and E.selected and #E.selected.corners == 6, "drawing did not carry on")

    -- A selection survives the round trip too; a closed window stays closed.
    local sel = E.selected
    wow.inCombat = true
    wow.fireAll("PLAYER_REGEN_DISABLED")
    wow.inCombat = false
    wow.fireAll("PLAYER_REGEN_ENABLED")
    check(f:IsShown() and E.selected == sel and E.tool == "select", "the selection was lost")
    E.quietClose = true
    E.close()
    wow.inCombat = true
    wow.fireAll("PLAYER_REGEN_DISABLED")
    wow.inCombat = false
    wow.fireAll("PLAYER_REGEN_ENABLED")
    check(not f:IsShown(), "combat opened a window that was closed")
end)

-- Settings and instance auto-toggles ----------------------------------------------
--
-- The behaviour under test is a suspension: the addon stops driving and eases to
-- the baseline while the player is inside, then picks up again. What matters is
-- that it is a SUSPENSION and not a stop - the loop keeps running, so both edges
-- are smooth and leaving needs no reload - and that it sits in the right place in
-- the precedence order.

local function enterInstance(ns, info)
    wow.instance = info
    ns.settingsWatch:Fire("PLAYER_ENTERING_WORLD")
end

local function leaveInstance(ns)
    wow.instance = nil
    ns.settingsWatch:Fire("PLAYER_ENTERING_WORLD")
end

test("settings exist, carry the documented defaults and survive a config without them",
function()
    local ns = load()
    local s = ns.Config.settings
    check(type(s) == "table", "no settings table")
    check(s.instances.all == false, "the master should default off")
    for _, k in ipairs({ "dungeon", "raid", "battleground", "epicBattleground" }) do
        check(s.instances[k] == true, k .. " should default on")
    end
    check(s.sharing.accept == true, "sharing should default to accepting")
    check(s.sharing.preview == true, "preview should default on")
    check(s.epicBattlegroundMinPlayers == nil,
        "the epic threshold must stay nil until it is measured")
end)

test("a dungeon suspends the addon and the ease carries it to the baseline", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    frames(ns, 3)
    check(near(ns.state.curC, 60), "not on Duskwood values first: " .. ns.state.curC)

    enterInstance(ns, { name = "The Stockade", instanceType = "party", maxPlayers = 5 })
    check(ns.state.suspendedBy == "dungeon", "not suspended: " .. tostring(ns.state.suspendedBy))
    check(ns.frame:IsShown(), "the loop stopped - a suspension must not stop it")

    frames(ns, 3)
    check(near(ns.state.curC, ns.Config.baseline.contrast),
        "did not ease to the baseline contrast: " .. ns.state.curC)
    check(near(ns.state.curB, ns.Config.baseline.brightness),
        "did not ease to the baseline brightness: " .. ns.state.curB)
end)

test("leaving an instance resumes, with no reload and no snap", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    enterInstance(ns, { name = "The Stockade", instanceType = "party", maxPlayers = 5 })
    frames(ns, 3)

    leaveInstance(ns)
    check(ns.state.suspendedBy == nil, "still suspended after leaving")

    -- One frame in, it must have MOVED but not ARRIVED. That is the difference
    -- between easing back and snapping back, and it is the whole reason the
    -- suspension does not stop the loop.
    local before = ns.state.curC
    frames(ns, 1 / 60, 60)
    check(ns.state.curC ~= before, "did not start moving back")
    check(math.abs(ns.state.curC - 60) > 1, "snapped straight to the zone value")

    frames(ns, 3)
    check(near(ns.state.curC, 60), "did not arrive back on Duskwood: " .. ns.state.curC)
end)

test("each instance type reads its own setting", function()
    local cases = {
        { key = "dungeon",      info = { instanceType = "party", maxPlayers = 5 } },
        { key = "raid",         info = { instanceType = "raid",  maxPlayers = 40 } },
        { key = "battleground", info = { instanceType = "pvp",   maxPlayers = 10 } },
    }
    for i = 1, #cases do
        -- A fresh character each time: the toggle below is saved, and a second
        -- load would otherwise restore it, as the client now does.
        _G.DynamicAmbianceDB, _G.DynamicAmbianceCharDB = nil, nil
        local ns = load()
        login(ns)
        -- On by default: it suspends.
        enterInstance(ns, cases[i].info)
        check(ns.state.suspendedBy == cases[i].key,
            cases[i].key .. " did not claim it: " .. tostring(ns.state.suspendedBy))

        -- Turned off: the same place no longer suspends, without a reload.
        ns.dispatch("set " .. cases[i].key .. " off")
        check(ns.state.suspendedBy == nil,
            cases[i].key .. " still suspended after being turned off")

        -- And the other three must not have been disturbed by that.
        for j = 1, #cases do
            if j ~= i then
                check(ns.Config.settings.instances[cases[j].key] == true,
                    "turning off " .. cases[i].key .. " also changed " .. cases[j].key)
            end
        end
    end
end)

test("the master overrides the four, including an instance type nothing recognises",
function()
    local ns = load()
    login(ns)
    for _, k in ipairs({ "dungeon", "raid", "battleground", "epicBattleground" }) do
        ns.Config.settings.instances[k] = false
    end

    enterInstance(ns, { instanceType = "party", maxPlayers = 5 })
    check(ns.state.suspendedBy == nil, "suspended with every specific toggle off")

    -- An instanceType none of the four cover. With the master off this behaves
    -- like the open world, which is the safe degradation; with it on it is caught.
    enterInstance(ns, { instanceType = "somethingNew", maxPlayers = 3 })
    check(ns.state.suspendedBy == nil, "an unrecognised type was claimed by a specific toggle")

    ns.dispatch("set allinstances on")
    check(ns.state.suspendedBy == "all instances",
        "the master did not catch an unrecognised instance: " .. tostring(ns.state.suspendedBy))

    enterInstance(ns, { instanceType = "party", maxPlayers = 5 })
    check(ns.state.suspendedBy == "all instances", "the master did not override dungeon=off")
end)

test("an epic battleground is NOT split out until a threshold has been measured",
function()
    local ns = load()
    login(ns)
    ns.Config.settings.instances.battleground     = true
    ns.Config.settings.instances.epicBattleground = false

    -- 40 players is retail's rule. With no measured threshold the addon must not
    -- apply it - this is the assertion that stops a guess shipping.
    enterInstance(ns, { name = "Alterac Valley", instanceType = "pvp", maxPlayers = 40 })
    check(ns.state.suspendedBy == "battleground",
        "classified as epic with no measured threshold: " .. tostring(ns.state.suspendedBy))

    -- Once measured, the same place classifies the other way.
    ns.Config.settings.epicBattlegroundMinPlayers = 40
    enterInstance(ns, { name = "Alterac Valley", instanceType = "pvp", maxPlayers = 40 })
    check(ns.state.suspendedBy == nil,
        "epicBattleground=off did not take effect once the threshold existed: "
        .. tostring(ns.state.suspendedBy))

    enterInstance(ns, { name = "Warsong Gulch", instanceType = "pvp", maxPlayers = 10 })
    check(ns.state.suspendedBy == "battleground", "a 10-player BG was treated as epic")
end)

test("an explicit hold outranks a suspension, and off outranks both", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    enterInstance(ns, { instanceType = "raid", maxPlayers = 40 })
    check(ns.state.suspendedBy == "raid", "not suspended to begin with")

    -- Typing /amb try in a raid is a deliberate act and the addon does not get to
    -- overrule it.
    ns.dispatch("try 70 20")
    frames(ns, 3)
    check(near(ns.state.curC, 70), "a suspension overrode an explicit hold: " .. ns.state.curC)

    ns.dispatch("auto")
    frames(ns, 3)
    check(near(ns.state.curC, ns.Config.baseline.contrast),
        "releasing the hold did not fall back to the suspension: " .. ns.state.curC)

    ns.dispatch("off")
    frames(ns, 3)
    check(ns.state.mode == "off", "off did not take")
    check(not ns.frame:IsShown(), "off did not stop the loop while suspended")
end)

test("a suspension is visible in /amb status", function()
    local ns = load()
    login(ns)
    enterInstance(ns, { name = "Molten Core", instanceType = "raid", maxPlayers = 40 })
    ns.dispatch("")
    check(wow.chatMatches("suspended: raid") ~= nil, "status does not mention the suspension")
end)

test("GetInstanceInfo going missing degrades to open-world behaviour, not a crash",
function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    _G.GetInstanceInfo = nil
    enterInstance(ns, { instanceType = "party", maxPlayers = 5 })
    -- IsInInstance still says yes, but nothing can say WHICH kind, so no specific
    -- toggle can claim it. The master still can.
    check(ns.state.suspendedBy == nil, "claimed an instance it could not identify")
    ns.dispatch("set allinstances on")
    check(ns.state.suspendedBy == "all instances",
        "the master should not need GetInstanceInfo")

    _G.IsInInstance = nil
    ns.settingsWatch:Fire("PLAYER_ENTERING_WORLD")
    check(ns.state.suspendedBy == nil, "still suspended with no way to detect an instance")
    frames(ns, 3)
    check(near(ns.state.curC, 60), "did not fall back to driving the zone: " .. ns.state.curC)
end)

test("/amb set reports unknown keys and accepts the documented aliases", function()
    local ns = load()
    login(ns)
    ns.dispatch("set nonsense on")
    check(wow.chatMatches("unknown setting") ~= nil, "an unknown key was accepted silently")

    for _, alias in ipairs({ "bg", "dungeons", "epicbg", "raids", "all" }) do
        wow.chat = {}
        ns.dispatch("set " .. alias .. " off")
        check(wow.chatMatches("unknown setting") == nil, "alias not accepted: " .. alias)
    end
    check(ns.Config.settings.instances.battleground == false, "bg alias did not take")
    check(ns.Config.settings.instances.dungeon == false, "dungeons alias did not take")
    check(ns.Config.settings.instances.epicBattleground == false, "epicbg alias did not take")

    -- A bare key with no value toggles, which is what people type when flipping
    -- something they just read off the listing.
    ns.dispatch("set raid")
    check(ns.Config.settings.instances.raid == true, "a bare key did not toggle back on")
end)

test("/amb settings lists every toggle and flags what cannot fire", function()
    local ns = load()
    login(ns)
    ns.dispatch("settings")
    for _, k in ipairs({ "allinstances", "dungeon", "raid", "battleground",
                         "epicbattleground", "accept", "preview" }) do
        check(wow.chatMatches(k) ~= nil, "not listed: " .. k)
    end
    -- With no measured threshold, the listing has to say the epic branch cannot
    -- fire. A toggle reading `on` while being structurally unable to do anything
    -- is worse than no toggle.
    check(wow.chatMatches("cannot fire") ~= nil, "did not flag the unmeasured epic threshold")

    -- And when the two are set differently, that warning has to get louder,
    -- because only then does it actually cost the player something.
    wow.chat = {}
    ns.Config.settings.instances.epicBattleground = false
    ns.dispatch("settings")
    check(wow.chatMatches("CANNOT FIRE") ~= nil,
        "the warning did not escalate when the two toggles disagree")
end)

test("suspending writes no CVar beyond the ease, and settles", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    frames(ns, 3)
    enterInstance(ns, { instanceType = "raid", maxPlayers = 40 })
    frames(ns, 3)
    local settled = #wow.writes
    frames(ns, 5)
    check(#wow.writes == settled, "kept writing after the suspension settled")
end)

-- The preset format ---------------------------------------------------------------
--
-- The format is the one part of sharing that has to survive leaving the machine:
-- a string goes into a forum post and comes back weeks later through someone
-- else's clipboard. So these lean on round trips rather than on asserting the
-- exact bytes, which would only pin the format in place without proving it works.

local function roundTrip(ns, name, zone)
    local s, err = ns.Preset.serialize(name, zone)
    check(s ~= nil, "did not serialize " .. name .. ": " .. tostring(err))
    if not s then return end
    local gotName, got = ns.Preset.parse(s)
    check(gotName == name, "name did not survive: " .. tostring(gotName))
    return gotName, got, s
end

test("a preset round-trips through the string, areas and gates included", function()
    local ns = load()
    local zone = {
        contrast = 60, brightness = 40, map = 1429,
        areas = {
            { subzone = "Raven Hill", priority = 10, contrast = 65, brightness = 32 },
            { subzone = "Hall of Arms", indoors = true, priority = 60,
              contrast = 70, brightness = 58 },
            { name = "forecourt", x = 0.4920, y = 0.4143,
              inner = 0.0040, falloff = 0.0200, indoors = false,
              priority = 20, contrast = 85, brightness = 25 },
        },
    }
    local _, got = roundTrip(ns, "Duskwood", zone)
    if not got then return end

    check(got.contrast == 60 and got.brightness == 40, "zone values lost")
    check(got.map == 1429, "map id lost: " .. tostring(got.map))
    check(#got.areas == 3, "area count: " .. #got.areas)

    check(got.areas[1].subzone == "Raven Hill", "subzone name lost")
    check(got.areas[1].priority == 10, "priority 10 came back as " .. tostring(got.areas[1].priority))

    -- The indoor gate is three-valued - true, false and absent - and all three
    -- mean different things. Collapsing false into absent would make an
    -- outdoors-only layer fire indoors.
    check(got.areas[2].indoors == true, "indoors=true lost")
    check(got.areas[3].indoors == false, "indoors=false became " .. tostring(got.areas[3].indoors))
    check(got.areas[1].indoors == nil, "an ungated area came back gated")

    check(near(got.areas[3].x, 0.4920, 0.0001), "x drifted: " .. tostring(got.areas[3].x))
    -- DA2 writes radii in yards: the legacy 0.0200 goes out converted on map 1429.
    check(near(got.areas[3].falloffYards, 56.7, 0.05), "falloff drifted: "
        .. tostring(got.areas[3].falloffYards))
end)

test("trailing zeros in a priority or a map id are not eaten", function()
    local ns = load()
    -- 10 -> "1" and 1420 -> "142" is what naive zero-stripping does, and neither
    -- looks wrong in the string.
    local _, got = roundTrip(ns, "Z", {
        contrast = 50, brightness = 50, map = 1420,
        areas = { { subzone = "A", priority = 100, contrast = 10, brightness = 40 } },
    })
    if not got then return end
    check(got.map == 1420, "map came back as " .. tostring(got.map))
    check(got.areas[1].priority == 100, "priority came back as " .. tostring(got.areas[1].priority))
    check(got.areas[1].contrast == 10, "contrast came back as " .. tostring(got.areas[1].contrast))
end)

test("the shipped config round-trips, whatever anyone has authored into it", function()
    local ns = wow.load(ROOT)      -- the REAL zones, not the fixture
    local n = 0
    for name, zone in pairs(ns.Config.zones) do
        n = n + 1
        local _, got = roundTrip(ns, name, zone)
        if got then
            check(#got.areas == #(zone.areas or {}),
                name .. ": area count changed through the round trip")
            local ok = ns.Preset.validate(name, got)
            check(ok, name .. ": the shipped config does not pass its own validator")
        end
    end
    check(n > 0, "no zones in the shipped config to test")
end)

test("separator characters in a name survive escaping", function()
    local ns = load()
    local nasty = "a~b:c|d%e"
    local name, got = roundTrip(ns, nasty, {
        contrast = 50, brightness = 50,
        areas = { { subzone = nasty, contrast = 1, brightness = 2 } },
    })
    check(name == nasty, "zone name mangled: " .. tostring(name))
    if got then
        check(got.areas[1].subzone == nasty, "subzone mangled: " .. tostring(got.areas[1].subzone))
    end

    -- And the escape sequence itself, written literally, must not be unescaped
    -- into something else on the way back.
    local literal = "100%7E of it"
    local n2, g2 = roundTrip(ns, literal, { contrast = 50, brightness = 50 })
    check(n2 == literal, "a literal escape sequence was decoded: " .. tostring(n2))
end)

test("a truncated or edited string is refused, not half-applied", function()
    local ns = load()
    local s = ns.Preset.serialize("Duskwood", {
        contrast = 60, brightness = 40,
        areas = { { subzone = "Darkshire", contrast = 55, brightness = 48 } },
    })

    -- Losing the tail to a chat line limit is the real failure mode.
    local cut = s:sub(1, #s - 6)
    local ok, err = ns.Preset.parse(cut)
    check(ok == nil, "accepted a truncated string")
    check(tostring(err):find("checksum") ~= nil or tostring(err):find("short") ~= nil,
        "unhelpful error for a truncated string: " .. tostring(err))

    -- A value edited by hand without recomputing the checksum.
    local edited = s:gsub("60", "99", 1)
    check(ns.Preset.parse(edited) == nil, "accepted an edited string")

    check(ns.Preset.parse("") == nil, "accepted an empty string")
    check(ns.Preset.parse("hello") == nil, "accepted arbitrary text")
    check(ns.Preset.parse(("x"):rep(9000)) == nil, "accepted a string over the length cap")
end)

test("a preset from a newer format is refused by name, not parsed hopefully", function()
    local ns = load()
    local s = ns.Preset.serialize("Duskwood", { contrast = 60, brightness = 40 })
    local future = s:gsub("^DA2", "DA3", 1)
    local ok, err = ns.Preset.parse(future)
    check(ok == nil, "parsed a format it does not speak")
    check(tostring(err):find("DA3") ~= nil, "did not name the offending version: " .. tostring(err))
end)

test("the validator catches values that parse but cannot be acted on", function()
    local ns = load()

    local ok = ns.Preset.validate("Duskwood", { contrast = 60, brightness = 40, areas = {} })
    check(ok, "rejected a clean preset")

    local function problems(name, zone)
        local good, list = ns.Preset.validate(name, zone)
        return (not good) and table.concat(list, " ; ") or nil
    end

    check(problems("D", { contrast = 400, brightness = 40 }), "accepted contrast 400")
    check(problems("D", { contrast = 60, brightness = -5 }), "accepted negative brightness")
    check(problems("", { contrast = 60 }), "accepted an empty zone name")
    check(problems(("x"):rep(200), { contrast = 60 }), "accepted an over-long zone name")

    -- An inverted radius pair is the nastiest one: smoothstep divides by
    -- (inner - falloff), so it applies the area everywhere EXCEPT where it was
    -- drawn. Nothing about the numbers looks wrong.
    local inverted = problems("D", { contrast = 60, brightness = 40, map = 1,
        areas = { { name = "a", x = 0.5, y = 0.5, inner = 0.2, falloff = 0.01,
                    contrast = 50, brightness = 50 } } })
    check(inverted and inverted:find("inside out") ~= nil,
        "did not catch an inverted falloff: " .. tostring(inverted))

    -- Coordinates with no map are inert rather than wrong, and the receiver has
    -- to be told, or they watch nothing happen and blame the addon.
    local nomap = problems("D", { contrast = 60, brightness = 40,
        areas = { { name = "a", x = 0.5, y = 0.5, inner = 0.01, falloff = 0.02,
                    contrast = 50, brightness = 50 } } })
    check(nomap and nomap:find("map id") ~= nil, "did not flag coordinates with no map")

    -- An area that sets no values at all is inert, not wrong: the editor makes
    -- them (a new shape has no values yet), so refusing one would make the
    -- editor's own exports unimportable. The editor labels them instead.
    local empty = problems("D", { contrast = 60, brightness = 40,
        areas = { { subzone = "A" } } })
    check(empty == nil, "refused an inert area: " .. tostring(empty))

    check(problems("D", { contrast = 60, brightness = 40, map = 1,
        areas = { { name = "a", x = 4, y = 0.5, inner = 0.01, falloff = 0.02,
                    contrast = 50, brightness = 50 } } }),
        "accepted a coordinate outside 0-1")
end)

-- DA2 ------------------------------------------------------------------------------
--
-- design/ui/DESIGN-ui.md section 2: gamma, metadata, polygons and yards, with DA1
-- still accepted on the way in.

local function da(ns, body) return body .. "~" .. ns.Preset.checksum(body) end

test("DA2 round-trips every kind, every escapable character and a 32-corner polygon", function()
    local ns = load()
    local zone = every4Kinds()
    local s, err = ns.Preset.serialize(NASTY, zone)
    check(s ~= nil, "did not serialize: " .. tostring(err))
    if not s then return end
    check(s:sub(1, 4) == "DA2~", "export is not DA2: " .. s:sub(1, 8))
    check(not s:find("[\n\r\t]"), "a control character reached the string unescaped")
    check(#s <= ns.Preset.MAX_LENGTH, #s .. " bytes")
    local name, got = ns.Preset.parse(s)
    check(name == NASTY, "zone name mangled: " .. tostring(name))
    if not got then return check(false, "parse failed: " .. tostring(got)) end
    local ok, why = sameTable(zone, got)
    check(ok, "not equal field-for-field: " .. tostring(why))
    check(#got.areas[3].corners == 64, "corners lost")
    check(got.areas[5].contrast == nil and got.areas[5].brightness == nil,
        "an empty numeric field did not come back as nil")
    check(ns.Preset.validate("Elwynn Forest", got), "the round-tripped preset does not validate")
    -- And the same string again: serialization is deterministic.
    check(ns.Preset.serialize(NASTY, got) == s, "a second serialization differs")
end)

test("a DA1 string parses, and its radii convert to yards with a tag", function()
    local ns = load()
    local body = "DA1~Elwynn Forest~35~78~1429~s:Northshire Valley:10:55:45:"
        .. "~p:forecourt:0.492:0.4143:0.004:0.02:20:85:25:0"
    local name, zone = ns.Preset.parse(da(ns, body))
    check(name == "Elwynn Forest", "DA1 did not parse: " .. tostring(zone))
    if not name then return end
    local a = zone.areas[2]
    local g = math.sqrt(SW * SH)
    check(a.inner == nil and near(a.innerYards, 0.004 * g, 0.05)
        and near(a.falloffYards, 0.02 * g, 0.05),
        "not converted: " .. tostring(a.innerYards) .. "/" .. tostring(a.falloffYards))
    check(a.__converted == true and zone.__convertedFrom == "DA1", "not tagged as converted")
    check(zone.gamma == nil and zone.meta == nil, "DA1 has no gamma or metadata")
    check(ns.Preset.validate(name, zone), "the converted preset does not validate")

    -- With the size call gone, the radii stay legacy and untagged.
    C_Map.GetMapWorldSize = nil
    local _, legacy = ns.Preset.parse(da(ns, body))
    check(legacy.areas[2].inner == 0.004 and legacy.areas[2].innerYards == nil,
        "converted without a scale")
    check(legacy.areas[2].__converted == nil, "tagged without a conversion")
    check(ns.Preset.validate(name, legacy), "a legacy circle should still validate")
end)

test("DA2 refusals name the field", function()
    local ns = load()
    local function refusal(zone, name)
        local ok, list = ns.Preset.validate(name or "Z", zone)
        return (not ok) and table.concat(list, " ; ") or nil
    end
    local function poly(pairs_, bad)
        local c = {}
        for k = 1, pairs_ do
            c[#c + 1] = 0.5 + 0.01 * math.cos(k)
            c[#c + 1] = 0.5 + 0.01 * math.sin(k)
        end
        if bad then c[1] = 1.2 end
        return { contrast = 50, brightness = 50, map = 1429,
            areas = { { corners = c, falloffYards = 10, contrast = 60 } } }
    end

    local _, err = ns.Preset.parse(da(ns, "DA2~Z~50~50~~1429~q:what:10~"))
    check(err and err:find("unknown kind"), "unknown kind: " .. tostring(err))
    _, err = ns.Preset.parse(da(ns, "DA2~Z~50~50~~1429~c:a:0.5:0.5:ten:20:10:60::::"))
    check(err and err:find("innerYards"), "a non-number did not name its field: " .. tostring(err))

    local r = refusal(poly(2))
    check(r and r:find("2 corners") and r:find("at least 3"), "2 pairs: " .. tostring(r))
    r = refusal(poly(33))
    check(r and r:find("33 corners") and r:find("cap is 32"), "33 pairs: " .. tostring(r))
    check(refusal(poly(32)) == nil, "32 pairs should be fine: " .. tostring(refusal(poly(32))))
    r = refusal(poly(4, true))
    check(r and r:find("1.2") and r:find("normalized 0%-1"), "coordinate 1.2: " .. tostring(r))

    r = refusal({ contrast = 50, map = 1429, areas = { { x = 0.5, y = 0.5, innerYards = 30,
        falloffYards = 10, contrast = 60 } } })
    check(r and r:find("inside out") and r:find("yd"), "falloff < inner in yards: " .. tostring(r))

    r = refusal({ contrast = 50, areas = { { subzone = "A", gamma = 50 } } })
    check(r and r:find("area 1 %(A%) gamma 50 is outside 0.3%-3 %- the screen ignores values "
        .. "outside that range"), "gamma 50: " .. tostring(r))
    r = refusal({ gamma = 0.1 })
    check(r and r:find("zone gamma 0.1 is outside 0.3%-3"), "gamma 0.1: " .. tostring(r))
    check(refusal({ gamma = 0.3, areas = { { subzone = "A", gamma = 3.0 } } }) == nil,
        "the exact edges 0.3 and 3.0 should validate")

    local s = ns.Preset.serialize("Z", { contrast = 50,
        meta = { name = "n", version = -1 } })
    local zn, z = ns.Preset.parse(s)
    r = zn and refusal(z, zn)
    check(r and r:find("version %-1"), "version -1: " .. tostring(r))

    r = refusal({ contrast = 50, meta = { notes = ("x"):rep(501) } })
    check(r and r:find("notes are 501 characters"), "preset notes over cap: " .. tostring(r))
    r = refusal({ contrast = 50, areas = { { subzone = "A", contrast = 1, notes = ("x"):rep(201) } } })
    check(r and r:find("notes are 201 characters, the cap is 200"), "area notes over cap: " .. tostring(r))
    r = refusal({ contrast = 50, meta = { name = ("x"):rep(65) } })
    check(r and r:find("preset name is 65"), "name over cap: " .. tostring(r))

    _, err = ns.Preset.parse("DA2~" .. ("x"):rep(3997))
    check(err and err:find("4001 bytes is over the 4000 cap"), "4001 bytes: " .. tostring(err))
    local full = ns.Preset.serialize("Duskwood", { contrast = 60, brightness = 40,
        areas = { { subzone = "Darkshire", contrast = 55 } } })
    _, err = ns.Preset.parse(full:sub(1, #full - 3))
    check(err and err:find("checksum"), "truncated: " .. tostring(err))
    _, err = ns.Preset.parse((full:gsub("^DA2", "DA3")))
    check(err and err:find("DA3"), "DA3: " .. tostring(err))
end)

test("describe and conflicts cover polygons, and say when overlap cannot be checked", function()
    local ns = load()
    ns.Config.zones.Elwynn = { contrast = 50, map = 1429, areas = {
        { name = "mine", x = 0.5, y = 0.5, innerYards = 5, falloffYards = 20, contrast = 60 },
        { name = "far", corners = { 0.1, 0.1, 0.12, 0.1, 0.12, 0.12 }, falloffYards = 5,
          contrast = 60 },
    } }
    local theirs = { contrast = 50, map = 1429, gamma = 1.2,
        meta = { name = "Their Elwynn", version = 4, author = "Fabqt-Realm", date = "2026-09-24" },
        areas = {
            -- Its box reaches the circle only through its falloff.
            { name = "pocket", corners = { 0.507, 0.49, 0.52, 0.49, 0.52, 0.51, 0.507, 0.51 },
              falloffYards = 12, contrast = 70 },
            { name = "elsewhere", corners = { 0.8, 0.8, 0.82, 0.8, 0.82, 0.82 },
              falloffYards = 1, contrast = 70 },
        } }
    local lines = table.concat(ns.Preset.describe("Elwynn", theirs), "\n")
    check(lines:find("pocket (4 corners, falloff 12 yd)", 1, true), "polygon not described: " .. lines)
    check(lines:find("Their Elwynn", 1, true) and lines:find("v4", 1, true)
        and lines:find("Fabqt-Realm", 1, true), "metadata line missing: " .. lines)
    check(lines:find("g=1.2", 1, true), "gamma not described")

    local report = ns.Preset.conflicts("Elwynn", theirs)
    local found = {}
    for _, o in ipairs(report.overlaps) do found[o.name .. ">" .. tostring(o.against)] = o.kind end
    check(found["pocket>mine"] == "position", "a box overlapping through its falloff was missed")
    check(found["elsewhere>mine"] == nil and found["elsewhere>far"] == nil,
        "reported an overlap that is nowhere near")

    C_Map.GetMapWorldSize = nil
    report = ns.Preset.conflicts("Elwynn", theirs)
    check(#report.overlaps == 1 and report.overlaps[1].kind == "unchecked"
        and report.overlaps[1].reason:find("not checked"), "an unreadable scale was not reported")
end)

test("importing a DA1 string says its radii were converted", function()
    local ns = load()
    wow.zone = "Westfall"
    login(ns)
    local body = "DA1~Elwynn Forest~35~78~1429~p:forecourt:0.492:0.4143:0.004:0.02:20:85:25:0"
    ns.dispatch("import " .. da(ns, body))
    check(ns.shareSession.offer ~= nil, "a DA1 string did not raise a confirmation")
    check(wow.chatMatches("radii converted from an older format") ~= nil, "no conversion notice")
    -- feedback-2.md item 6: the old format still parses, and is never named.
    check(wow.chatMatches("DA1") == nil, "a chat line names DA1: " .. tostring(wow.chatMatches("DA1")))
    ns.dispatch("import accept")
    local z = ns.Config.zones["Elwynn Forest"]
    check(z and z.origin == "import" and z.__dirty == true, "import origin not recorded")
end)

-- Offering, confirming, previewing --------------------------------------------------

local function offerDuskwood(ns, sender)
    local s = ns.Preset.serialize("Duskwood", {
        contrast = 20, brightness = 80,
        areas = { { subzone = "Darkshire", priority = 10, contrast = 25, brightness = 75 } },
    })
    local name, zone = ns.Preset.parse(s)
    return ns.offerPreset(name, zone, sender, s), s
end

test("an offered preset previews live and a decline puts the screen back", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    frames(ns, 3)
    check(near(ns.state.curC, 60), "not on the original Duskwood first: " .. ns.state.curC)

    offerDuskwood(ns, "Fabqt")
    check(wow.popupShown == "DYNAMICAMBIANCE_IMPORT", "no confirmation was raised")
    frames(ns, 3)
    check(near(ns.state.curC, 20), "preview did not reach the screen: " .. ns.state.curC)
    check(near(ns.state.curB, 80), "preview brightness did not land: " .. ns.state.curB)

    ns.dispatch("import decline")
    frames(ns, 3)
    check(near(ns.state.curC, 60), "declining did not put it back: " .. ns.state.curC)
    check(ns.Config.zones.Duskwood.contrast == 60, "the original zone table was not restored")
    check(#ns.Config.zones.Duskwood.areas == 2, "the original areas were not restored")
end)

test("accepting keeps it, saves it in place, and says what happens to it", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    offerDuskwood(ns, "Fabqt")
    ns.dispatch("import accept")
    frames(ns, 3)
    check(near(ns.state.curC, 20), "accepted values are not live: " .. ns.state.curC)
    check(ns.Config.zones.Duskwood.contrast == 20, "not installed")
    -- Before PLAYER_ENTERING_WORLD nothing is verified, so it says the regressed line.
    check(wow.chatMatches("may be lost at /reload") ~= nil,
        "did not say what happens to the import on an unverified build")
    local st = DynamicAmbianceCharDB.store
    check(st.zones.Duskwood and st.zones.Duskwood.contrast == 20, "the import was not saved in place")
    check(st.revert.Duskwood and st.revert.Duskwood.string:sub(1, 4) == "DA2~",
        "the accepted string is not the zone's revert point")
    check(DynamicAmbianceDB.imported ~= nil and #DynamicAmbianceDB.imported == 1,
        "the accepted preset was not logged for recovery from the file")
end)

test("a preset for a zone you are not standing in says so rather than looking broken",
function()
    local ns = load()
    wow.zone = "Westfall"
    login(ns)
    offerDuskwood(ns, "Fabqt")
    check(wow.chatMatches("you are in Westfall") ~= nil,
        "did not explain why the preview shows nothing")
    ns.dispatch("import decline")
end)

test("a preset for a zone you already have warns that importing replaces it", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    offerDuskwood(ns, "Fabqt")
    check(wow.chatMatches("you already have a Duskwood") ~= nil, "no conflict warning")
    check(wow.chatMatches("REPLACES") ~= nil, "did not say it replaces the whole zone")
    -- Darkshire exists on both sides, so the overlap has to be named with both
    -- sets of values - that is the thing the receiver is actually choosing between.
    check(wow.chatMatches("Darkshire") ~= nil, "did not name the overlapping subzone")
    ns.dispatch("import decline")
end)

test("ignoring works per player and globally, and is saved for the character", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)

    ns.dispatch("ignore Spammer")
    local shown = offerDuskwood(ns, "Spammer")
    check(shown == false, "an ignored player still raised a confirmation")
    check(ns.shareSession.offer == nil, "an ignored offer was still opened")

    -- Someone else still gets through.
    check(offerDuskwood(ns, "Fabqt") == true, "ignoring one player blocked everyone")
    ns.dispatch("import decline")

    ns.dispatch("ignore all")
    check(offerDuskwood(ns, "Fabqt") == false, "ignore all did not take")
    check(ns.Config.settings.sharing.accept == false, "ignore all is not the accept setting")
    check(DynamicAmbianceCharDB.store.settings.sharing.accept == false, "ignore all was not saved")
    check(DynamicAmbianceCharDB.store.settings.sharing.ignorePlayers.Spammer == true,
        "the ignored player was not saved")

    ns.dispatch("unignore all")
    check(offerDuskwood(ns, "Fabqt") == true, "unignore all did not take")
    ns.dispatch("import decline")

    -- The config-level switch is the one that survives, and it beats everything.
    ns.dispatch("set accept off")
    check(offerDuskwood(ns, "Fabqt") == false, "accept=off still let a preset through")
end)

test("the popup's third button declines and ignores in one go", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    offerDuskwood(ns, "Spammer")
    check(ns.shareSession.offer ~= nil, "nothing open to act on")

    local dialog = StaticPopupDialogs.DYNAMICAMBIANCE_IMPORT
    -- StaticPopup wires button1->OnAccept, button2->OnCancel, button3->OnAlt.
    -- Crossing the labels puts people on an ignore list they never chose, so the
    -- arrangement is pinned here rather than left to be re-derived.
    check(dialog.button1 == "Import", "button1 is not Import: " .. tostring(dialog.button1))
    check(dialog.button2 == "Decline", "button2 is not Decline: " .. tostring(dialog.button2))
    check(dialog.button3 == "Never from them",
        "button3 is not the ignore: " .. tostring(dialog.button3))

    dialog.OnAlt()
    check(ns.Config.settings.sharing.ignorePlayers.Spammer == true, "not added to the ignore list")
    check(ns.shareSession.offer == nil, "the offer stayed open")
    check(ns.Config.zones.Duskwood.contrast == 60, "the preview was not reverted")

    check(offerDuskwood(ns, "Spammer") == false, "they got through again straight away")
end)

test("only one confirmation is open at a time", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    check(offerDuskwood(ns, "First") == true, "the first offer did not open")
    check(offerDuskwood(ns, "Second") == false, "a second dialog was stacked on the first")
    check(ns.shareSession.offer.sender == "First", "the second offer replaced the first")
end)

test("an invalid preset is refused with a reason and never previewed", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    frames(ns, 3)
    local shown = ns.offerPreset("Duskwood", { contrast = 4000, brightness = 40, areas = {} },
        "Fabqt", nil)
    check(shown == false, "a preset with contrast 4000 was offered anyway")
    check(wow.chatMatches("outside 0-100") ~= nil, "did not say what was wrong")
    frames(ns, 3)
    check(near(ns.state.curC, 60), "an invalid preset still touched the screen: " .. ns.state.curC)
end)

test("logging out closes an open confirmation and reverts the preview", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    offerDuskwood(ns, "Fabqt")
    check(ns.Config.zones.Duskwood.contrast == 20, "preview not installed to begin with")

    wow.frameNamed("DynamicAmbianceShareExit"):Fire("PLAYER_LOGOUT")
    check(ns.shareSession.offer == nil, "the offer survived logout")
    check(ns.Config.zones.Duskwood.contrast == 60,
        "a stranger's values were left in place at logout")
end)

-- Export, import and links ------------------------------------------------------------

test("/amb export uses the zone you are standing in and warns about your own problems",
function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    ns.dispatch("export")
    local line = wow.chatMatches("DA2~Duskwood")
    check(line ~= nil, "did not print a preset string")
    check(DynamicAmbianceDB.exports ~= nil and #DynamicAmbianceDB.exports == 1,
        "the export was not written to SavedVariables")

    wow.chat = {}
    ns.dispatch("export Nowhere")
    check(wow.chatMatches("no config for") ~= nil, "exported a zone that does not exist")

    -- Exporting a zone with a problem in it must warn the AUTHOR, because the
    -- receiver is the one who will otherwise find out.
    wow.chat = {}
    ns.Config.zones.Broken = { contrast = 60, brightness = 40,
        areas = { { name = "a", x = 0.5, y = 0.5, innerYards = 10, falloffYards = 20,
                    contrast = 50, brightness = 50 } } }
    ns.dispatch("export Broken")
    check(wow.chatMatches("a receiver will see") ~= nil, "exported a broken zone silently")
end)

test("export then import is a working loop", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)
    ns.dispatch("export")

    -- Deliberately the WHOLE chat line, prefix and colour codes included: that is
    -- what a person copying out of their chat log actually ends up with, and the
    -- import has to cope with it.
    local pasted = wow.chatMatches("DA2~Duskwood")
    check(pasted:find("Ambiance", 1, true) ~= nil,
        "this test is meant to paste a line that still carries the addon prefix")

    ns.Config.zones.Duskwood = nil        -- as if the receiver had no Duskwood
    ns.dispatch("import " .. pasted)
    check(ns.shareSession.offer ~= nil, "the pasted string did not raise a confirmation")
    ns.dispatch("import accept")
    check(ns.Config.zones.Duskwood ~= nil, "import did not install it")
    check(ns.Config.zones.Duskwood.contrast == 60, "values did not survive the loop")
    check(#ns.Config.zones.Duskwood.areas == 2, "areas did not survive the loop")

    wow.chat = {}
    ns.dispatch("import not-a-preset")
    check(wow.chatMatches("not a preset") ~= nil, "garbage was not rejected clearly")
end)

test("a preset link carries provenance and resolves to an offer", function()
    local ns = load()
    wow.zone = "Duskwood"
    login(ns)

    local text = ns.Preset.linkText("Duskwood", "Fabqt", "2026-09-19")
    check(text:find("Duskwood", 1, true) and text:find("Fabqt", 1, true)
        and text:find("2026-09-19", 1, true),
        "the visible text lost its provenance: " .. text)

    local link = ns.Preset.link("abc123", "Duskwood", "Fabqt", "2026-09-19")
    check(ns.Preset.linkID("dynamicambiance:abc123") == "abc123", "id did not come back")
    check(ns.Preset.linkID("item:12345") == nil, "claimed a link that is not ours")
    check(ns.Preset.linkID(nil) == nil, "did not survive a nil link")

    local s = ns.Preset.serialize("Duskwood", { contrast = 20, brightness = 80 })
    local name, zone = ns.Preset.parse(s)
    ns.registerLinkPayload("abc123", name, zone, "Fabqt", s)
    ns.onPresetLinkClicked("abc123")
    check(ns.shareSession.offer ~= nil, "clicking a known link did not offer it")
    ns.dispatch("import decline")

    wow.chat = {}
    ns.onPresetLinkClicked("neverseen")
    check(wow.chatMatches("not in this session") ~= nil,
        "an unknown link id was not explained")
end)

-- The persistence marker. The first version stamped at file load, before the
-- client restores SavedVariables, so it could never see a saved marker and the
-- restore then overwrote its stamp. These pin the order the client really uses.

local function loadState(ns)
    return ns.persistenceLoad
end

test("marker: a fresh install reads as nil and stamps load #1", function()
    local ns = load()
    login(ns)
    local sv = loadState(ns)
    check(sv.captured == true, "ADDON_LOADED was not what captured the load state")
    check(sv.accountWasNil and sv.charWasNil, "a fresh install did not arrive nil")
    check(sv.accountMarker == nil and sv.charMarker == nil, "found a marker that was never saved")
    check(_G.DynamicAmbianceCharDB.persistenceMarker.loadCount == 1, "did not stamp load #1")
end)

test("marker: a marker restored by the client is seen and counted up", function()
    local ns = load()
    local account = copy(_G.DynamicAmbianceDB)     -- what the reload wrote to disk
    local char    = copy(_G.DynamicAmbianceCharDB)

    wow.install()
    ns = wow.load(ROOT, { account = account, char = char })
    login(ns)
    local sv = loadState(ns)
    check(sv.accountMarker ~= nil, "a restored account marker was not seen")
    check(sv.charMarker ~= nil, "a restored character marker was not seen")
    check(_G.DynamicAmbianceDB.persistenceMarker.loadCount == 2,
        "account load # did not go up across a reload")
    check(_G.DynamicAmbianceCharDB.persistenceMarker.loadCount == 2,
        "character load # did not go up across a reload")
end)

test("marker: only one of the two restored is reported as exactly that", function()
    local ns = load()
    local char = copy(_G.DynamicAmbianceCharDB)

    wow.install()
    ns = wow.load(ROOT, { char = char })            -- the 2026-09-21 shape
    login(ns)
    local sv = loadState(ns)
    check(sv.accountMarker == nil and sv.accountWasNil, "account read back when it was not")
    check(sv.charMarker ~= nil, "character read back was missed")
    wow.chat = {}
    ns.dispatch("status")
    check(wow.chatMatches("came back: account no, character yes") ~= nil,
        "/amb status did not report which one came back")
end)

test("marker: ADDON_LOADED for another addon is ignored", function()
    wow.install()
    local ns = wow.load(ROOT, { char = { persistenceMarker = { loadCount = 4 } } })
    wow.fireAll("ADDON_LOADED", "SomebodyElse")
    login(ns)
    check(_G.DynamicAmbianceCharDB.persistenceMarker.loadCount == 5,
        "a second ADDON_LOADED re-stamped the marker")
end)

test("/amb share says what it cannot do instead of pretending", function()
    local ns = load()
    login(ns)
    ns.dispatch("share party")
    check(wow.chatMatches("not wired up yet") ~= nil, "share claimed to work")
    check(wow.chatMatches("is unmeasured") ~= nil, "did not say the transport is unmeasured")
    check(wow.chatMatches("/amb export") ~= nil, "did not offer the transport that does work")
end)

-- M8. Polygon weight -------------------------------------------------------------
--
-- design/ui/interview-1.md: inside 1, outside a smoothstep over one falloff
-- distance to the nearest edge, beyond it 0. Standalone; evaluate does not use it
-- yet. Corners are flat: { x1, y1, x2, y2, ... }.

local SQUARE = { 0.4, 0.4, 0.6, 0.4, 0.6, 0.6, 0.4, 0.6 }

local function regularPolygon(corners, cx, cy, r)
    local p = {}
    for k = 0, corners - 1 do
        local a = k / corners * 2 * math.pi
        p[#p + 1] = cx + r * math.cos(a)
        p[#p + 1] = cy + r * math.sin(a)
    end
    return p
end

test("polygon weight: inside, on the edge, and the falloff band", function()
    local w = load().polygonWeight
    check(w(SQUARE, 0.1, 0.5, 0.5) == 1, "centre is not 1")
    check(w(SQUARE, 0.1, 0.45, 0.58) == 1, "an interior point is not 1")
    check(w(SQUARE, 0.1, 0.5, 0.4) == 1, "a point on an edge is not 1")
    check(w(SQUARE, 0.1, 0.6, 0.5) == 1, "a point on the far edge is not 1")
    check(w(SQUARE, 0.1, 0.4, 0.4) == 1, "a corner is not 1")

    check(near(w(SQUARE, 0.1, 0.65, 0.5), 0.5, 1e-9), "half the band is not 0.5")
    -- 0.7 - 0.6 is a hair under 0.1 in binary, so the end of the band is near 0,
    -- and just past it is exactly 0.
    check(near(w(SQUARE, 0.1, 0.7, 0.5), 0, 1e-9), "the end of the band is not 0")
    check(w(SQUARE, 0.1, 0.71, 0.5) == 0, "past the band is not 0")
    check(w(SQUARE, 0.1, 0.9, 0.9) == 0, "far outside is not 0")
    -- Beyond a corner the nearest edge point is the corner itself: 0.03, 0.04 -> 0.05.
    check(near(w(SQUARE, 0.1, 0.63, 0.64), 0.5, 1e-9), "distance off a corner is wrong")

    local prev = 1
    for i = 0, 20 do
        local v = w(SQUARE, 0.1, 0.6 + 0.1 * i / 20, 0.5)
        check(v <= prev + 1e-12, "not monotone at step " .. i)
        check(v >= 0 and v <= 1, "outside 0..1 at step " .. i)
        prev = v
    end

    check(w(SQUARE, 0, 0.5, 0.5) == 1 and w(SQUARE, 0, 0.61, 0.5) == 0,
        "a zero falloff should be a hard edge")
    check(w(SQUARE, nil, 0.61, 0.5) == 0, "a missing falloff should be a hard edge")
    check(w(SQUARE, 0.1, nil, nil) == 0, "no position should weigh 0")
end)

test("polygon weight: a ray through a vertex is counted once", function()
    local w = load().polygonWeight
    local diamond = { 0.5, 0.3, 0.7, 0.5, 0.5, 0.7, 0.3, 0.5 }
    check(w(diamond, 0.2, 0.4, 0.5) == 1, "inside, level with two vertices, read as outside")
    check(near(w(diamond, 0.2, 0.2, 0.5), 0.5, 1e-9),
        "outside, level with two vertices, read wrong: " .. w(diamond, 0.2, 0.2, 0.5))
    -- Level with the square's bottom edge, to its left.
    check(near(w(SQUARE, 0.2, 0.3, 0.4), 0.5, 1e-9), "level with a horizontal edge read wrong")
end)

test("polygon weight: a concave shape leaves its notch outside", function()
    local w = load().polygonWeight
    -- A U: the notch runs from y = 0.5 up to the open side at 0.8, between x 0.4 and 0.6.
    local U = { 0.2, 0.2, 0.8, 0.2, 0.8, 0.8, 0.6, 0.8, 0.6, 0.5, 0.4, 0.5, 0.4, 0.8, 0.2, 0.8 }
    check(w(U, 0.4, 0.3, 0.7) == 1, "left arm")
    check(w(U, 0.4, 0.7, 0.7) == 1, "right arm")
    check(w(U, 0.4, 0.5, 0.3) == 1, "the base")
    -- In the notch the nearest edges are its sides, 0.1 away: smoothstep(0.4, 0, 0.1).
    check(near(w(U, 0.4, 0.5, 0.7), 0.84375, 1e-9), "the notch: " .. w(U, 0.4, 0.5, 0.7))
    check(w(U, 0.05, 0.5, 0.7) == 0, "the notch with a short falloff should be 0")
end)

test("polygon weight: fewer than three corners weighs nothing", function()
    local w = load().polygonWeight
    check(w(nil, 0.1, 0.5, 0.5) == 0, "nil")
    check(w({}, 0.1, 0.5, 0.5) == 0, "empty")
    check(w({ 0.5, 0.5 }, 0.1, 0.5, 0.5) == 0, "one corner")
    check(w({ 0.4, 0.5, 0.6, 0.5 }, 0.1, 0.5, 0.5) == 0, "two corners, point on the segment")
    check(w({ 0.4, 0.4, 0.6, 0.4, 0.5 }, 0.1, 0.5, 0.41) == 0, "two and a half corners")
    check(w({ 0.1, 0.1, 0.3, 0.1, 0.2, 0.3 }, 0.1, 0.2, 0.15) == 1, "a triangle is the minimum")
end)

test("polygon weight allocates nothing at 4, 8, 16 and 32 corners", function()
    local w = load().polygonWeight
    for _, corners in ipairs({ 4, 8, 16, 32 }) do
        local poly = regularPolygon(corners, 0.5, 0.5, 0.1)
        w(poly, 0.05, 0.5, 0.5)
        collectgarbage("collect")
        collectgarbage("stop")
        local before = collectgarbage("count")
        for _ = 1, 2000 do
            w(poly, 0.05, 0.5, 0.5)       -- inside
            w(poly, 0.05, 0.62, 0.5)      -- in the band
            w(poly, 0.05, 0.9, 0.9)       -- beyond it
        end
        local delta = (collectgarbage("count") - before) * 1024
        collectgarbage("restart")
        check(delta < 64, ("%d corners: %0.1f bytes over 6000 calls"):format(corners, delta))
    end
end)

test("polygon weight cost per call (printed, not asserted)", function()
    local w = load().polygonWeight
    local pts = { 0.5, 0.5, 0.62, 0.5, 0.9, 0.9, 0.45, 0.58 }
    local ITERS = 100000
    local function bench(poly)
        local t0 = os.clock()
        for i = 1, ITERS do
            local k = (i % 4) * 2 + 1
            w(poly, 0.05, pts[k], pts[k + 1])
        end
        return (os.clock() - t0) * 1e6 / ITERS
    end
    local runtime = (jit and jit.version) or _VERSION
    for _, corners in ipairs({ 4, 8, 16, 32 }) do
        local poly = regularPolygon(corners, 0.5, 0.5, 0.1)
        local interp = bench(poly)
        local traced
        if jit then
            -- The suite runs with the JIT off, like the client's interpreter. The
            -- traced figure is the LuaJIT ceiling, for scale only.
            jit.on() ; jit.flush()
            bench(poly) ; bench(poly)
            traced = bench(poly)
            jit.off() ; jit.flush()
        end
        print(("        M8 %-22s %2d corners  %7.3f us/call interpreted%s"):format(
            runtime, corners, interp,
            traced and ("  %7.3f us/call JIT"):format(traced) or ""))
        check(interp > 0 or interp == 0, "no timing")
    end
end)

-- The discovered areas (MapOverlays.lua) -----------------------------------------------
--
-- The editor draws the whole map, not the undiscovered parchment: every overlay
-- from the generated table for the map's art, else what the client says was
-- explored, else the base art alone.

local ELWYNN_ART = 2153

-- The editor open on Elwynn with the given art ID and exploration API.
local function overlayEditor(artID, explored)
    local ns, E = editorAt()
    _G.C_Map.GetMapArtID = function() return artID end
    _G.C_MapExplorationInfo = explored
    ns.dispatch("ui")
    return ns, E
end

local function overlayTextures(c)
    local list = {}
    for i = 1, c.pieceCount do list[#list + 1] = c.overlayTex[i] end
    return list
end

test("MapOverlays.lua loads, names its source and build, and holds every art ID", function()
    local ns = wow.load(ROOT)
    local d = ns.MapOverlays
    check(type(d) == "table" and d.build == "1.60.1.69977", "no data table, or the wrong build")
    local n = 0
    for k, v in pairs(d.art) do
        n = n + 1
        if type(k) ~= "number" or type(v) ~= "table" or #v == 0 then
            check(false, "a bad art entry: " .. tostring(k))
        end
    end
    check(n == 84, "art IDs: " .. n)
    local fh = assert(io.open(ROOT .. "/addons/DynamicAmbiance/UI/MapOverlays.lua", "r"))
    local head = fh:read(1200)
    fh:close()
    check(head:lower():find("generated, do not hand-edit", 1, true) ~= nil, "no do-not-edit line")
    check(head:find("https://wago.tools/db2/WorldMapOverlay/csv?build=1.60.1.69977", 1, true)
        ~= nil, "no source URL")
    check(head:find("Generated: %d%d%d%d%-%d%d%-%d%d") ~= nil, "no generation date")
    local toc = wow.tocFiles(ROOT)
    local at, editorAt_ = nil, nil
    for i, f in ipairs(toc) do
        if f == "UI/MapOverlays.lua" then at = i end
        if f == "UI/Editor.lua" then editorAt_ = i end
    end
    check(at and editorAt_ and at < editorAt_, "not in the .toc before Editor.lua")
end)

test("Elwynn's art 2153 has its 12 overlays, 5156 on file 8061955", function()
    local ns = wow.load(ROOT)
    local list = ns.MapOverlays.art[ELWYNN_ART]
    check(list and #list == 12, "overlays: " .. tostring(list and #list))
    local o = list[1]
    check(o[1] == 577 and o[2] == 419 and o[3] == 256 and o[4] == 249, "5156's rectangle")
    check(o[5] == 0 and o[6] == 0 and o[7] == 8061955, "5156's tile")
    local tiles = 0
    for i = 1, #list do tiles = tiles + (#list[i] - 4) / 3 end
    check(tiles == 18, "tiles: " .. tiles)
end)

test("overlay tile placement and edge crop follow Blizzard's exploration provider", function()
    local ns = wow.load(ROOT)
    local R = ns.Raster
    check(R.overlayFileSize(1) == 16 and R.overlayFileSize(16) == 16
        and R.overlayFileSize(17) == 32 and R.overlayFileSize(50) == 64
        and R.overlayFileSize(249) == 256 and R.overlayFileSize(256) == 256, "file sizes")
    -- Elwynn 5164: 306 x 233 at (696, 435), two tiles across.
    local x, y, w, h, u, v = R.overlayTile(696, 435, 306, 233, 0, 0)
    check(x == 696 and y == 435 and w == 256 and h == 233, "first tile's rectangle")
    check(u == 1 and near(v, 233 / 256, 1e-9), "first tile's crop")
    x, y, w, h, u, v = R.overlayTile(696, 435, 306, 233, 0, 1)
    check(x == 952 and y == 435 and w == 50 and h == 233, "edge tile's rectangle")
    check(near(u, 50 / 64, 1e-9) and near(v, 233 / 256, 1e-9), "edge tile's crop")
    -- 5160: 256 x 341, the second row 85 tall on a 128 file.
    x, y, w, h, u, v = R.overlayTile(124, 327, 256, 341, 1, 0)
    check(x == 124 and y == 583 and w == 256 and h == 85 and near(v, 85 / 128, 1e-9), "edge row")
    check(R.overlayTile(0, 0, 256, 256, 0, 1) == nil, "a tile past the overlay was placed")

    -- Through the view: at fit on the native-size canvas one art pixel is one
    -- canvas pixel; zoomed 2x and panned, the cut narrows the crop to match.
    local view = R.newView()
    local px, py, pw, ph, l, r, t, b = R.placeArt(952, 435, 50, 233, 50 / 64, 1, 1, 1, view,
        1002, 668)
    check(px == 952 and py == 435 and pw == 50 and ph == 233, "fit placement")
    check(l == 0 and near(r, 50 / 64, 1e-9) and t == 0 and b == 1, "fit crop")
    view.zoom, view.ox, view.oy = 2, 1000, 0
    px, py, pw, ph, l, r = R.placeArt(450, 0, 100, 100, 0.5, 1, 2, 2, view, 1002, 668)
    check(px == 0 and pw == 100 and near(l, 0.25, 1e-9) and near(r, 0.5, 1e-9),
        ("cut at the left: %s %s %s %s"):format(tostring(px), tostring(pw), tostring(l), tostring(r)))
    check(R.placeArt(0, 0, 100, 100, 1, 1, 2, 2, view, 1002, 668) == nil,
        "a tile scrolled off the canvas was placed")
end)

test("the editor draws every Elwynn overlay over the base tiles, cropped and layered", function()
    local ns, E = overlayEditor(ELWYNN_ART, nil)
    local c = E.canvas
    check(c.hasArt and c.source == "data", "source: " .. tostring(c.source))
    check(c.pieceCount == 18, "overlay tiles: " .. c.pieceCount)
    check(E.mapSource and E.mapSource:GetText() == "full map (data 1.60.1.69977)",
        "source line: " .. tostring(E.mapSource and E.mapSource:GetText()))
    local shown, edge = 0, nil
    for i, t in ipairs(overlayTextures(c)) do
        if t.shown and t.file then shown = shown + 1 end
        check(t.layer == "BORDER" and t.sublevel == 1, "overlay not one sublevel over the base")
        local p = c.pieces[i]
        if p.file == 8061977 then edge = t end
    end
    check(shown == 18, "overlay tiles shown: " .. shown)
    check(c.tiles[1].layer == "BORDER" and (c.tiles[1].sublevel or 0) < 1, "base tiles moved")
    check(edge and edge.w == 50 and edge.h == 233, "edge tile size")
    local tc = edge and edge.texCoord or {}
    check(tc[1] == 0 and near(tc[2], 50 / 64, 1e-9) and tc[3] == 0 and near(tc[4], 233 / 256, 1e-9),
        "edge tile crop")
    local pt = edge and edge.points[1]
    check(pt and pt[4] == 952 and pt[5] == -435, "edge tile position")

    -- Zoomed about the top left, 5166 (0,0 512 x 512) fills the corner.
    c:zoomTo(2, 0, 0)
    for i, t in ipairs(overlayTextures(c)) do
        if c.pieces[i].file == 8061980 then
            check(t.shown and t.w == 512 and t.h == 512, "5166's first tile at 2x")
        end
        if c.pieces[i].file == 8061977 then
            check(not t.shown, "a tile off the zoomed canvas is still shown")
        end
    end
end)

test("overlays fall back from the data to the explored areas to the base art", function()
    local explored = {
        GetExploredMapTextures = function()
            return { { textureWidth = 306, textureHeight = 233, offsetX = 696, offsetY = 435,
                       fileDataIDs = { 111, 112 } },
                     "junk", { textureWidth = "x" } }
        end,
    }
    -- The data wins over the explored list when it has the art.
    local ns, E = overlayEditor(ELWYNN_ART, explored)
    check(E.canvas.source == "data", "the data did not win")

    -- No data for art 12 (the stub's): the explored list, retail-shaped.
    wow.install()
    ns, E = overlayEditor(12, explored)
    local c = E.canvas
    check(c.source == "explored" and c.pieceCount == 2, "explored: " .. tostring(c.source)
        .. " " .. c.pieceCount)
    check(E.mapSource:GetText() == "explored areas only", "explored line")
    check(c.pieces[2].file == 112 and c.pieces[2].x == 952 and c.pieces[2].w == 50,
        "explored edge tile")

    -- The API raises: the base art alone.
    wow.install()
    ns, E = overlayEditor(12, { GetExploredMapTextures = function() error("no") end })
    check(E.canvas.source == "base" and E.canvas.pieceCount == 0, "a raising API was not base")

    -- Absent entirely, and no art ID either.
    wow.install()
    ns, E = overlayEditor(nil, nil)
    check(E.canvas.source == "base" and E.mapSource:GetText() == "base map only", "base line")
    check(E.canvas.hasArt, "the base art was lost")
end)

test("a data build other than the client's is said once, on the first open", function()
    -- The stub's client is 69913.
    local ns, E = overlayEditor(ELWYNN_ART, nil)
    local msg = wow.chatMatches("map overlay data is from build")
    check(msg and msg:find("69977", 1, true) and msg:find("69913", 1, true)
        and msg:find("scripts/gen-map-overlays.py", 1, true), "mismatch line: " .. tostring(msg))
    check(E.canvas.source == "data", "not drawn on a mismatch")
    wow.chat = {}
    ns.dispatch("ui")
    ns.dispatch("ui")
    check(wow.chatMatches("map overlay data is from build") == nil, "said twice")

    wow.install()
    _G.GetBuildInfo = function() return "1.60.1", "69977", "2026-09-24", 16001 end
    overlayEditor(ELWYNN_ART, nil)
    check(wow.chatMatches("map overlay data is from build") == nil, "said on a matching build")
end)

test("/amb ui mapcheck counts explored overlays found in the data, into the account DB", function()
    local explored = {
        GetExploredMapTextures = function(mapID)
            if mapID ~= 1429 then return nil end
            return {
                { textureWidth = 256, textureHeight = 249, offsetX = 577, offsetY = 419,
                  fileDataIDs = { 8061955 } },
                { textureWidth = 306, textureHeight = 233, offsetX = 696, offsetY = 435,
                  fileDataIDs = { 8061976, 8061977 } },
                { textureWidth = 256, textureHeight = 256, offsetX = 0, offsetY = 0,
                  fileDataIDs = { 8061976, 999 } },
            }
        end,
    }
    local ns, E = overlayEditor(ELWYNN_ART, explored)
    wow.chat = {}
    ns.dispatch("ui mapcheck")
    local r = _G.DynamicAmbianceDB and _G.DynamicAmbianceDB.mapcheck
    -- The account DB only (DESIGN-ui.md 1.5): nothing that is not the player's
    -- own authoring goes to the character's file.
    check(r and _G.DynamicAmbianceCharDB and _G.DynamicAmbianceCharDB.mapcheck == nil,
        "not stored in the account DB alone")
    r = r or {}
    check(r.mapID == 1429 and r.artID == ELWYNN_ART and r.api == "present", "what was checked")
    check(r.explored == 3 and r.found == 2 and r.missing == 1, ("%s explored, %s found, %s missing")
        :format(tostring(r.explored), tostring(r.found), tostring(r.missing)))
    check(r.missingFiles and r.missingFiles[1] == 999, "the missing file was not named")
    check(r.inData == 12 and r.dataBuild == "1.60.1.69977", "data side")
    local line = wow.chatMatches("mapcheck map 1429")
    check(line and line:find("2 found", 1, true) and line:find("1 missing", 1, true),
        "report: " .. tostring(line))

    -- No API: says so, and still records it.
    wow.install()
    ns, E = overlayEditor(ELWYNN_ART, nil)
    ns.dispatch("ui mapcheck")
    r = _G.DynamicAmbianceDB and _G.DynamicAmbianceDB.mapcheck or {}
    check(r.api == "absent" and r.explored == 0 and r.inData == 12, "absent API: "
        .. tostring(r.api))
    check(wow.chatMatches("GetExploredMapTextures absent") ~= nil, "absent API not reported")
end)

test("overlay textures are pooled across redraws, views and maps", function()
    local ns, E = overlayEditor(ELWYNN_ART, nil)
    local c = E.canvas
    -- Map art textures only: the shapes' own strip pool grows with the zoom by
    -- design, and is not what is under test here.
    local function artTextures()
        local n = 0
        for _, r in ipairs(wow.regions) do if r.layer == "BORDER" then n = n + 1 end end
        return n
    end
    local before = artTextures()
    local poolSize = #c.overlayTex
    local firstTex = c.overlayTex[1]
    for _ = 1, 5 do
        c:zoomBy(1.25)
        c:panBy(-30, -20)
        E.renderCanvas()
    end
    c:resetView()
    E.selectZone("Elwynn Forest", 1429)
    E.renderCanvas()
    check(artTextures() == before, (artTextures() - before) .. " art textures created on redraw")
    check(#c.overlayTex == poolSize and poolSize == 18, "overlay pool: " .. #c.overlayTex)
    check(c.overlayTex[1] == firstTex, "the pool was replaced")

    -- A map with fewer overlays reuses the pool and hides the rest.
    _G.C_Map.GetMapArtID = function() return 12 end
    _G.C_MapExplorationInfo = { GetExploredMapTextures = function()
        return { { textureWidth = 256, textureHeight = 256, offsetX = 0, offsetY = 0,
                   fileDataIDs = { 5 } } }
    end }
    c:setMap(1429)
    check(artTextures() == before, "art textures created for a smaller map")
    local stray = 0
    for i = 2, #c.overlayTex do if c.overlayTex[i].shown then stray = stray + 1 end end
    check(c.pieceCount == 1 and stray == 0, stray .. " stale overlay tiles still shown")
end)

-- The saved store, and the persistence branch ----------------------------------------
--
-- design/ui/DESIGN-ui.md 0.1, 1.2, 1.4, 1.5, 3.6, 6.8, 6.10 and 9.1. Build 70009
-- reads SavedVariables back, so a character's zones and settings live in
-- DynamicAmbianceCharDB.store; the branch is judged at every login. The stub's
-- wow.load plays the client's order: every file first, then the saved globals,
-- then ADDON_LOADED. PLAYER_ENTERING_WORLD is fired by hand, with the client's
-- isInitialLogin / isReloadingUi.

local function pew(kind)
    wow.fireAll("PLAYER_ENTERING_WORLD", kind == "login", kind == "reload")
end

local function setBuild(build)
    if build then
        _G.GetBuildInfo = function() return "1.60.1", build, "2026-09-25", 16001 end
    end
end

-- A load after the client restored what the last one wrote (restored = true), or
-- after it restored nothing (restored = false). `kind` is how the load began.
local function nextLoad(restored, kind, build)
    local account, char = copy(_G.DynamicAmbianceDB), copy(_G.DynamicAmbianceCharDB)
    wow.install()
    setBuild(build)
    local ns = wow.load(ROOT, restored and { account = account, char = char } or nil)
    pew(kind)
    return ns
end

local function firstLoad(kind, build)
    wow.install()
    setBuild(build)
    local ns = wow.load(ROOT)
    pew(kind or "login")
    return ns
end

-- The operator's installed Zones.lua, as interview-2.md describes it: Elwynn at
-- version 2 with the author stamped, the chapel forecourt moved and resized, and
-- two polygons the repo's file does not have. The corners are this fixture's.
local function operatorElwynn()
    return {
        contrast = 35, brightness = 78, map = 1429,
        meta = { name = "Elwynn, Northshire test set", description = "", notes = "mine",
                 version = 2, author = "<character>-<realm>", date = "2026-09-24" },
        areas = {
            { subzone = "Northshire Valley", priority = 10, contrast = 55, brightness = 45 },
            { name = "chapel forecourt", x = 0.5138, y = 0.4438, innerYards = 111.4,
              falloffYards = 295.8, priority = 10, contrast = 85, brightness = 25, indoors = false },
            { name = "area 4", corners = { 0.41, 0.52, 0.418, 0.5205, 0.4191, 0.5302 },
              falloffYards = 5, priority = 10, contrast = 70 },
            { name = "area 5", corners = { 0.3, 0.3, 0.32, 0.3, 0.32, 0.33, 0.3, 0.33 },
              falloffYards = 5, priority = 20, gamma = 1.2 },
        },
    }
end

test("store: the first load seeds it from Zones.lua, field for field", function()
    wow.install()
    local ns = wow.load(ROOT)
    local st = _G.DynamicAmbianceCharDB.store
    check(type(st) == "table" and st.schema == 1, "no store, or no schema")
    local file = copy(ns.Store.fileZones)
    for name, z in pairs(ns.Config.zones) do
        check(st.zones[name] ~= nil, "not seeded: " .. name)
        local ok, why = sameTable(z, st.zones[name], name)
        check(ok, "the store differs from Config.zones: " .. tostring(why))
        check(st.zones[name].origin == "seed" and z.origin == "seed", "origin is not seed")
        check(st.zones[name] ~= z, "the store holds the live table itself")
    end
    check(st.seed and st.seed.from == "Zones.lua", "no seed record")
    check(st.seed.checksum == ns.Store.checksum(file), "the seed checksum is not the file's")
    check(#st.seed.checksum == 4, "not a Fletcher-16: " .. tostring(st.seed.checksum))
    check(_G.DynamicAmbianceDB.store == nil, "zones reached the account file")
end)

test("store: the operator's installed Zones.lua comes through the migration intact", function()
    wow.install()
    local mine = operatorElwynn()
    wow.afterFile = function(file, ns)
        if file == "Zones.lua" then ns.Config.zones["Elwynn Forest"] = copy(mine) end
    end
    local ns = wow.load(ROOT)
    wow.afterFile = nil
    pew("login")
    local st = _G.DynamicAmbianceCharDB.store.zones["Elwynn Forest"]
    local ok, why = sameTable(st, mine, "store")
    -- origin is the store's own field; everything else is the file's.
    st = copy(st); st.origin = nil
    for i = 1, #st.areas do st.areas[i].origin = nil end
    ok, why = sameTable(st, mine, "store")
    check(ok, "the operator's zone did not survive: " .. tostring(why))
    check(st.meta.version == 2 and #st.areas == 4 and st.areas[4].name == "area 5",
        "version 2, area 4 and area 5 are not all there")

    -- ...and the next load, restored, still has it, with the file ignored.
    ns = nextLoad(true, "login")
    local z = ns.Config.zones["Elwynn Forest"]
    check(z and z.meta.version == 2 and z.areas[2].x == 0.5138, "not loaded back from the store")
end)

test("store: a seeded store is the zones; the file's other zones are not", function()
    wow.install()
    local saved = { store = { schema = 1, seed = { checksum = "0000", from = "Zones.lua" },
        zones = { ["Redridge Mountains"] = { contrast = 44, brightness = 61, origin = "editor",
                                            areas = { { subzone = "Lakeshire", priority = 10 } } } },
        revert = {}, settings = {} } }
    local ns = wow.load(ROOT, { char = copy(saved) })
    check(ns.Config.zones["Elwynn Forest"] == nil, "a file-only zone survived the load")
    local z = ns.Config.zones["Redridge Mountains"]
    check(z and z.contrast == 44 and z.areas[1].subzone == "Lakeshire", "the store's zone is missing")
    check(z ~= _G.DynamicAmbianceCharDB.store.zones["Redridge Mountains"],
        "the live zone is the store's table")
    check(ns.layersFor(z)[1] ~= nil and z.__areas == z.areas, "the layer cache was not built for it")
end)

test("store: the clean copier reproduces every field and writes no cache", function()
    local ns = load()
    local z = placed(ns, every4Kinds())
    z.origin = "editor"
    z.export = { pending = true, manual = false, once = true }
    z.areas[2].origin = "import"
    ns.layersFor(z)
    z.__dirty = true
    local layers, W = z.__layers, z.__W
    local c = ns.Serialize.cleanZone(z)
    local function noCache(t, path)
        for k, v in pairs(t) do
            if type(k) == "string" and k:sub(1, 2) == "__" then return false, path .. "." .. k end
            if type(v) == "table" then
                local ok, why = noCache(v, path .. "." .. tostring(k))
                if not ok then return ok, why end
            end
        end
        return true
    end
    local ok, why = noCache(c, "clean")
    check(ok, "a cache reached the store: " .. tostring(why))
    check(c.areas ~= z.areas and c.areas[1] ~= z.areas[1] and c.areas[3].corners ~= z.areas[3].corners,
        "the store shares a table with the live zone")
    check(z.__layers == layers and z.__W == W and z.__dirty, "the live table's caches were touched")
    local back = ns.Serialize.liveZone(c)
    ok, why = sameTable(z, back, "zone")
    check(ok, "live -> store -> live lost something: " .. tostring(why))
    check(back.export.pending == true and back.export.once == true and back.areas[2].origin == "import",
        "the bookkeeping did not round-trip")
    -- A number that is not finite is not written: the client cannot be trusted to
    -- read one back.
    z.contrast = 0 / 0
    check(ns.Serialize.cleanZone(z).contrast == nil, "a NaN reached the store")
end)

test("store: the version bookkeeping survives a store round trip", function()
    local ns = firstLoad("login")
    local E = ns.Editor
    wow.zone, wow.mapID = "Elwynn Forest", 1429
    E.open("zones")
    E.selectZone("Elwynn Forest", 1429)
    E.setZoneValue("brightness", 71)
    E.flushDraft()
    check(_G.DynamicAmbianceCharDB.store.zones["Elwynn Forest"].export.pending == true,
        "the pending export was not saved")
    ns = nextLoad(true, "reload")
    local z = ns.Config.zones["Elwynn Forest"]
    check(z.brightness == 71, "the edit did not come back")
    local before = z.meta.version
    ns.dispatch("export Elwynn Forest")
    check(z.meta.version == before + 1, "an edit saved yesterday did not bump today's export: "
        .. tostring(z.meta.version))
    ns.dispatch("export Elwynn Forest")
    check(z.meta.version == before + 1, "bumped again without a change")
end)

test("store: settings are overlaid into the live tables, never swapping them", function()
    local ns = firstLoad("login")
    ns.Store.force("restart")
    local S = ns.Config.settings
    local inst, sharing, ig = S.instances, S.sharing, S.sharing.ignorePlayers
    ns.dispatch("set dungeon off")
    check(_G.DynamicAmbianceCharDB.store.settings.instances.dungeon == false, "/amb set did not save")
    check(wow.chatMatches("Saved for this character") ~= nil, "did not say it is saved")
    ns.dispatch("ignore Somebody")
    check(_G.DynamicAmbianceCharDB.store.settings.sharing.ignorePlayers.Somebody == true,
        "/amb ignore did not save")

    ns = nextLoad(true, "reload")
    S = ns.Config.settings
    check(S.instances.dungeon == false and S.instances.raid == true, "the saved toggle was not restored")
    check(S.sharing.ignorePlayers.Somebody == true, "the ignore list was not restored")
    check(ns.settingsKeys.dungeon.tbl == S.instances and ns.settingsKeys.accept.tbl == S.sharing,
        "a /amb set key no longer points at the live table")
    -- Same table identity across the overlay, within one load.
    local keep = { S, S.instances, S.sharing, S.sharing.ignorePlayers }
    ns.Store.overlaySettings()
    check(ns.Config.settings == keep[1] and S.instances == keep[2] and S.sharing == keep[3]
        and S.sharing.ignorePlayers == keep[4], "the overlay replaced a table")

    -- The popup's third button saves too.
    wow.zone = "Duskwood"
    ns.Config.zones.Duskwood = { contrast = 60, brightness = 40, areas = {} }
    login(ns)
    check(offerDuskwood(ns, "Spammer") == true, "no offer opened")
    StaticPopupDialogs.DYNAMICAMBIANCE_IMPORT.OnAlt()
    check(_G.DynamicAmbianceCharDB.store.settings.sharing.ignorePlayers.Spammer == true,
        "Never from them did not save")

    ns.dispatch("settings reset")
    check(S.instances.dungeon == true and S.sharing.ignorePlayers.Somebody == nil,
        "reset did not put Config.settings back")
    check(next(_G.DynamicAmbianceCharDB.store.settings) == nil, "reset left saved settings behind")
    check(S.instances == keep[2], "reset replaced a table")
end)

test("store: every editor edit is flushed, and a deleted zone leaves the store", function()
    local ns = firstLoad("login")
    local E = ns.Editor
    local st = function() return _G.DynamicAmbianceCharDB.store end
    local function same(name)
        local ok, why = sameTable(ns.Serialize.cleanZone(ns.Config.zones[name]), st().zones[name], name)
        return ok, why
    end
    E.open("zones")
    E.selectZone("Elwynn Forest", 1429)
    local a = E.addArea({ subzone = "Goldshire", priority = 10, contrast = 33 })
    check(same("Elwynn Forest"), "add was not flushed")
    E.setArea(a, "contrast", 44)
    check(st().zones["Elwynn Forest"].areas[#st().zones["Elwynn Forest"].areas].contrast == 44,
        "a value edit was not flushed")
    E.setZoneValue("brightness", 12, true)       -- a slider drag: flushed on the next tick
    check(st().zones["Elwynn Forest"].brightness ~= 12, "a light edit flushed at once")
    wow.time = wow.time + 1
    E.onTick(nil, 1)
    check(st().zones["Elwynn Forest"].brightness == 12, "the light edit was not flushed on the tick")
    E.setMeta("notes", "walked")
    check(st().zones["Elwynn Forest"].meta.notes == "walked", "metadata was not flushed")
    E.deleteArea(a)
    check(same("Elwynn Forest"), "delete was not flushed")
    E.undo()
    check(same("Elwynn Forest") and #st().zones["Elwynn Forest"].areas == #ns.Config.zones["Elwynn Forest"].areas,
        "undo was not flushed")
    E.redo()
    check(same("Elwynn Forest"), "redo was not flushed")

    -- A zone created by the editor, then deleted with Delete zone.
    E.selectZone("Westfall", 1436)
    E.addArea({ subzone = "Sentinel Hill", priority = 10 })
    check(st().zones.Westfall and st().zones.Westfall.origin == "editor", "the new zone was not saved")
    ns.dispatch("export Westfall")
    check(st().revert.Westfall ~= nil, "no revert point after an export")
    E.requestDeleteZone()
    check(wow.popupShown == E.POPUP_DELZONE, "Delete zone did not ask")
    StaticPopupDialogs[E.POPUP_DELZONE].OnAccept()
    check(ns.Config.zones.Westfall == nil and st().zones.Westfall == nil and st().revert.Westfall == nil,
        "Delete zone left the zone or its revert point behind")
    E.undo()
    check(ns.Config.zones.Westfall ~= nil and st().zones.Westfall ~= nil and st().revert.Westfall ~= nil,
        "undo did not bring the deleted zone back, revert point and all")
end)

test("store: Revert to last export puts the zone back, as one undo step", function()
    local ns = firstLoad("login")
    local E = ns.Editor
    E.open("zones")
    E.selectZone("Elwynn Forest", 1429)
    check(E.revertTooltip("Elwynn Forest") == nil, "a zone never exported offers a revert")
    local _, why = E.revertTooltip("Elwynn Forest")
    check(why == "never exported", "the disabled reason: " .. tostring(why))
    check(E.revertButton and E.revertButton.enabled == false, "the button is not disabled")
    check(E.requestRevert() == false, "reverting with no export did not refuse")

    E.open("export")
    E.showPanel("props")
    local exported = copy(ns.Config.zones["Elwynn Forest"])
    check(E.revertTooltip("Elwynn Forest") ~= nil, "the export panel did not write a revert point")
    E.setZoneValue("contrast", 3)
    E.addArea({ subzone = "Goldshire", priority = 10 })
    local calls = 0
    local rt = ns.refreshTarget
    ns.refreshTarget = function(...) calls = calls + 1; return rt(...) end
    E.requestRevert()
    check(wow.popupShown == E.POPUP_REVERT, "revert did not ask first")
    StaticPopupDialogs[E.POPUP_REVERT].OnAccept()
    ns.refreshTarget = rt
    local z = ns.Config.zones["Elwynn Forest"]
    check(z.contrast == exported.contrast and #z.areas == #exported.areas, "not back to the export")
    check(calls > 0, "refreshTarget was not called")
    check(_G.DynamicAmbianceCharDB.store.zones["Elwynn Forest"].contrast == exported.contrast,
        "the revert was not saved")
    E.undo()
    z = ns.Config.zones["Elwynn Forest"]
    check(z.contrast == 3 and #z.areas == #exported.areas + 1, "undo did not bring the edits back")
end)

test("persistence: each rule of the judgement", function()
    local ns = load()
    local J = ns.Store.judge
    local B = "1.60.1.70009"
    check(J(nil, "login", B) == "unverified", "nil")
    check(J({ build = B }, "login", B) == "restart", "restored on a login")
    check(J({ build = "1.60.1.69977" }, nil, B) == "restart", "restored from another build")
    check(J({ build = B, best = "unverified" }, "reload", B) == "reload", "reload, best unverified")
    check(J({ build = B, best = "restart" }, "reload", B) == "restart",
        "a /reload on a restart-verified build did not stay restart")
    check(J({ best = "restart" }, nil, nil) == "restart", "unknown kind and build, best restart")
    check(J({}, nil, nil) == "reload", "a revision-1 marker with no best")
    local _, rule = J({ build = "x" }, nil, B)
    check(rule == 3, "rule number: " .. tostring(rule))
end)

-- The client's Lua 5.1 refuses a boolean for "%s"; LuaJIT and 5.4 accept one.
-- In game that made plain(true) nil and every load's kind nil (2026-09-25).
test("persistence: the load kind survives a 5.1-strict string.format", function()
    local realFormat = string.format
    string.format = function(fmt, ...)
        local args = { ... }
        local i = 0
        for spec in tostring(fmt):gmatch("%%[%-%d%.]*(%a)") do
            i = i + 1
            if spec == "s" and type(args[i]) == "boolean" then
                error("bad argument #" .. (i + 1) .. " to 'format' (string expected, got boolean)")
            end
        end
        return realFormat(fmt, ...)
    end
    local ok, err = pcall(function()
        firstLoad("login", "70009")
        local ns = nextLoad(true, "login", "70009")
        check(ns.persistence.state == "restart",
            "a relaunch judged " .. tostring(ns.persistence.state) .. ", not restart")
        check(_G.DynamicAmbianceCharDB.persistenceMarker.loadKind == "login",
            "loadKind not recorded")
    end)
    string.format = realFormat
    if not ok then error(err, 0) end
end)

test("persistence: a working build from a fresh install, then a /reload keeps restart", function()
    local B = "70009"
    local ns = firstLoad("login", B)
    local seq = { ns.Store.state() }
    ns = nextLoad(true, "reload", B); seq[#seq + 1] = ns.Store.state()
    ns = nextLoad(true, "reload", B); seq[#seq + 1] = ns.Store.state()
    ns = nextLoad(true, "login", B);  seq[#seq + 1] = ns.Store.state()
    ns = nextLoad(true, "reload", B); seq[#seq + 1] = ns.Store.state()
    check(table.concat(seq, ",") == "unverified,reload,reload,restart,restart",
        "sequence: " .. table.concat(seq, ","))
    local m = _G.DynamicAmbianceCharDB.persistenceMarker
    check(m.best == "restart" and m.loadKind == "reload" and m.build == "1.60.1.70009"
        and m.arrivedNil == false and m.loadCount == 5, "the marker's fields")
    check(_G.DynamicAmbianceDB.persistence.state == "restart"
        and _G.DynamicAmbianceCharDB.persistence.state == "restart", "not written to both DBs")
    check(ns.Editor.footerText() == ns.Editor.FOOTER_RESTART, "the /reload footer is not restart's")
end)

test("persistence: a patch to a working build is restart on its first load", function()
    firstLoad("login", "70009")
    local ns = nextLoad(true, "reload", "70009")
    ns = nextLoad(true, nil, "70100")                -- load kind unreadable, new build
    check(ns.Store.state() == "restart", "rule 3: " .. ns.Store.state())
    ns = nextLoad(true, "login", "70200")
    check(ns.Store.state() == "restart", "rule 2 on a patch: " .. ns.Store.state())
end)

test("persistence: a reload-only build never reaches restart; a none build is unverified", function()
    local B = "69913"
    local ns = firstLoad("login", B)
    local seq = { ns.Store.state() }
    ns = nextLoad(true, "reload", B);  seq[#seq + 1] = ns.Store.state()
    ns = nextLoad(false, "login", B);  seq[#seq + 1] = ns.Store.state()
    ns = nextLoad(true, "reload", B);  seq[#seq + 1] = ns.Store.state()
    check(table.concat(seq, ",") == "unverified,reload,unverified,reload",
        "reload-only: " .. table.concat(seq, ","))
    -- Reload counts as normal (User decision FQ2): the caveat, and nothing else.
    check(not ns.Store.regressed(), "reload was treated as regressed")
    check(ns.Editor.footerText() == ns.Editor.FOOTER_RELOAD, "the reload footer: " .. ns.Editor.footerText())

    ns = firstLoad("login", "69977")
    local none = { ns.Store.state() }
    for _ = 1, 3 do ns = nextLoad(false, "reload", "69977"); none[#none + 1] = ns.Store.state() end
    check(table.concat(none, ",") == "unverified,unverified,unverified,unverified",
        "none: " .. table.concat(none, ","))
end)

test("persistence: best never decreases on one build", function()
    local B = "70009"
    firstLoad("login", B)
    local ns = nextLoad(true, "login", B)
    for _ = 1, 3 do
        ns = nextLoad(true, nil, B)
        check(_G.DynamicAmbianceCharDB.persistenceMarker.best == "restart", "best dropped")
    end
end)

test("persistence: the login line is said on unverified only", function()
    local ns = firstLoad("login", "70009")
    check(wow.chatMatches("saving is not yet verified on this build") ~= nil, "no login line on unverified")
    ns = nextLoad(true, "reload", "70009")
    check(wow.chatMatches("saving is not yet verified on this build") == nil, "a login line on reload")
    ns = nextLoad(true, "login", "70009")
    check(wow.chatMatches("saving is not yet verified on this build") == nil, "a login line on restart")
    ns.dispatch("status")
    check(wow.chatMatches("persistence: restart, judged on build 1.60.1.70009") ~= nil,
        "/amb status does not print the state")
end)

test("persistence: /amb status reports the load count, the build and the markers", function()
    firstLoad("login", "70009")
    local ns = nextLoad(true, "login", "70009")
    wow.chat = {}
    ns.dispatch("status")
    check(wow.chatMatches("persistence: restart") ~= nil, "/amb status: no state")
    check(wow.chatMatches("this load: #2 on build 1.60.1.70009") ~= nil,
        "/amb status did not report the load count and build")
    check(wow.chatMatches("came back: account yes, character yes") ~= nil,
        "/amb status did not report the read-back")
    check(wow.chatMatches("clipboard: not tried yet on build 1.60.1.70009") ~= nil,
        "/amb status did not report the clipboard")
    wow.chat = {}
    ns.dispatch("persistence")
    check(wow.chatMatches("persistence: restart") ~= nil and wow.chatMatches("this load: #2") ~= nil,
        "/amb persistence")
end)

test("persistence: /amb persistence force sets, reports and clears the override", function()
    firstLoad("login", "70009")
    local ns = nextLoad(true, "login", "70009")
    check(ns.Store.state() == "restart", "judged " .. ns.Store.state())
    wow.chat = {}
    ns.dispatch("persistence force unverified")
    check(ns.Store.state() == "unverified" and ns.Store.regressed(), "force unverified did not take")
    check(wow.chatMatches("PERSISTENCE FORCED TO UNVERIFIED") ~= nil, "no warning")
    check(wow.chatMatches("/amb persistence force off to undo") ~= nil, "the undo is not named")
    wow.chat = {}
    ns.dispatch("status")
    check(wow.chatMatches("FORCED to unverified for this session") ~= nil, "/amb status hides the override")
    ns.dispatch("persistence force RELOAD")
    check(ns.Store.state() == "reload", "an upper-case state was not accepted")
    wow.chat = {}
    ns.dispatch("persistence force sideways")
    check(ns.Store.state() == "reload", "a bad state changed the override")
    check(wow.chatMatches("usage: /amb persistence force restart") ~= nil, "a bad state not refused")
    wow.chat = {}
    ns.dispatch("persistence force")
    check(wow.chatMatches("usage: /amb persistence force") ~= nil, "a missing state not refused")
    ns.dispatch("persistence force off")
    check(ns.Store.state() == "restart" and ns.Store.forced == nil, "force off did not clear it")
end)

test("the removed instruments are gone: no .toc line, no command", function()
    local toc = wow.tocFiles(ROOT)
    for _, f in ipairs(toc) do
        check(f ~= "Probe.lua" and f ~= "ProbeUI.lua" and f ~= "SelfTest.lua", "the .toc lists " .. f)
    end
    local ns = firstLoad("login", "70009")
    for _, cmd in ipairs({ "probe", "selftest" }) do
        wow.chat = {}
        ns.dispatch(cmd)
        check(wow.chatMatches("unknown: " .. cmd) ~= nil, "/amb " .. cmd .. " still answers")
    end
    check(ns.COMMANDS.probe == nil and ns.COMMANDS.selftest == nil, "a removed command is registered")
    wow.chat = {}
    ns.dispatch("help")
    check(wow.chatMatches("/amb probe") == nil and wow.chatMatches("/amb selftest") == nil,
        "the help still lists a removed command")
end)

test("regressed re-seed: only on unverified, and only when the file changed", function()
    -- Unverified with the store arrived nil: seeded at ADDON_LOADED, nothing replaced.
    local ns = firstLoad("login")
    local calls = 0
    check(ns.Store.reseedIfChanged() == false, "a fresh seed was replaced")

    -- A character file that came back without a marker, seeded from another file.
    local char = copy(_G.DynamicAmbianceCharDB)
    char.persistenceMarker = nil
    char.store.seed.checksum = "ffff"
    char.store.zones = { Mine = { contrast = 1 } }
    wow.install()
    ns = wow.load(ROOT, { char = char })
    local rt = ns.refreshTarget
    ns.refreshTarget = function(...) calls = calls + 1; return rt(...) end
    pew("reload")
    ns.refreshTarget = rt
    check(ns.Store.state() == "unverified", "state " .. ns.Store.state())
    local st = _G.DynamicAmbianceCharDB.store
    check(st.zones.Mine == nil and st.zones["Elwynn Forest"] ~= nil, "the store was not re-seeded")
    check(ns.Config.zones.Mine == nil and ns.Config.zones["Elwynn Forest"] ~= nil,
        "Config.zones was not replaced")
    check(st.seed.checksum == ns.Store.fileChecksum, "the seed record was not updated")
    check(calls > 0, "refreshTarget was not called")

    -- Restart and reload (normal, FQ2): a different file is ignored.
    for _, kind in ipairs({ "login", "reload" }) do
        firstLoad("login", "70009")
        local c = copy(_G.DynamicAmbianceCharDB)
        c.persistenceMarker.best = "restart"
        c.store.seed.checksum = "ffff"
        c.store.zones = { Mine = { contrast = 1 } }
        wow.install()
        setBuild("70009")
        ns = wow.load(ROOT, { account = copy(_G.DynamicAmbianceDB), char = c })
        pew(kind)
        check(not ns.Store.regressed(), kind .. " judged regressed")
        check(_G.DynamicAmbianceCharDB.store.zones.Mine ~= nil and ns.Config.zones.Mine ~= nil,
            "the store was replaced on " .. kind)
    end
end)

test("caps: the record lists keep the newest 20", function()
    local ns = firstLoad("login")
    check(ns.Config.limits.recordEntries == 20, "the cap is not in Config.limits")
    wow.zone, wow.mapID, wow.position = "Duskwood", 1431, { 0.5, 0.5 }
    for i = 1, 21 do ns.dispatch("here") end
    local caps = _G.DynamicAmbianceDB.captures
    check(#caps == 20, "captures: " .. #caps)
    for i = 1, 21 do ns.Store.appendRecord("imported", { n = i }) end
    local imp = _G.DynamicAmbianceDB.imported
    check(#imp == 20 and imp[1].n == 2 and imp[20].n == 21, "imports did not keep the newest 20")
    ns.Config.zones.Duskwood = { contrast = 60, brightness = 40, areas = {} }
    for i = 1, 21 do
        ns.Config.zones.Duskwood.contrast = i
        ns.Serialize.markChanged(ns.Config.zones.Duskwood)
        ns.dispatch("export Duskwood")
    end
    check(#_G.DynamicAmbianceDB.exports == 20, "exports: " .. #_G.DynamicAmbianceDB.exports)
end)

test("retired keys: the removed instruments' records are dropped at ADDON_LOADED", function()
    firstLoad("login", "70009")
    local account, char = copy(_G.DynamicAmbianceDB), copy(_G.DynamicAmbianceCharDB)
    for _, k in ipairs({ "probe", "probeUI", "probeGamma", "probeInstances", "selftest" }) do
        account[k] = { old = true }
        char[k] = { old = true }
    end
    account.clipboard = { ["1.60.1.70009"] = { outcome = "copied" } }
    account.mapcheck = { api = "ok" }
    account.imported = { { n = 1 } }
    wow.install()
    setBuild("70009")
    local ns = wow.load(ROOT, { account = account, char = char })
    pew("login")
    for _, k in ipairs({ "probe", "probeUI", "probeGamma", "probeInstances", "selftest" }) do
        check(_G.DynamicAmbianceDB[k] == nil, "account kept " .. k)
        check(_G.DynamicAmbianceCharDB[k] == nil, "character kept " .. k)
    end
    check(_G.DynamicAmbianceDB.persistenceMarker.loadCount == 2
        and _G.DynamicAmbianceCharDB.persistenceMarker.loadCount == 2, "the markers were lost")
    check(type(_G.DynamicAmbianceCharDB.store) == "table" and _G.DynamicAmbianceCharDB.store.seed,
        "the store was lost")
    check(_G.DynamicAmbianceDB.clipboard and _G.DynamicAmbianceDB.mapcheck
        and _G.DynamicAmbianceDB.imported, "a live record was dropped")
    check(ns.Store.state() == "restart", "judged " .. ns.Store.state())
end)

test("schema: a store without one is read and written back at 1", function()
    wow.install()
    local ns = wow.load(ROOT, { char = { store = { seed = { checksum = "0000" },
        zones = { Westfall = { contrast = 5 } } } } })
    check(ns.Config.zones.Westfall and ns.Config.zones.Westfall.contrast == 5, "not read")
    check(_G.DynamicAmbianceCharDB.store.schema == 1, "not written back at 1")
end)

test("branch UI: restart and reload - Saved, Export, no Save to file, no popups", function()
    for _, state in ipairs({ "restart", "reload" }) do
        local ns = firstLoad("login")
        ns.Store.force(state)
        local E = ns.Editor
        E.open("zones")
        E.selectZone("Elwynn Forest", 1429)
        check(E.footerText() == (state == "restart" and E.FOOTER_RESTART or E.FOOTER_RELOAD),
            state .. " footer: " .. E.footerText())
        check(E.footerButtonText() == "Export", state .. " button: " .. E.footerButtonText())
        _G.DynamicAmbianceDB.editor = nil
        E.setZoneValue("contrast", 12)
        check(E.dirtyCount() == 0, state .. ": counted an unsaved zone")
        check(_G.DynamicAmbianceDB.editor == nil, state .. ": wrote the recovery draft")
        wow.popupShown = nil
        ns.dispatch("ui save")
        check(E.panel == "export" and E.savePanel == nil, state .. ": /amb ui save did not open Export")
        check(wow.popupShown == nil, state .. ": /amb ui save raised a popup")
        check(E.exportBox:GetText():sub(1, 4) == "DA2~", state .. ": no preset string in the box")
        ns.dispatch("ui import")
        check(E.panel == "import" and E.importPanel:IsShown() and E.importBox.focused
            and not E.exportPanel:IsShown(), state .. ": /amb ui import did not open Import")
        E.close()
        check(wow.popupShown == nil, state .. ": closing with edits raised a popup")
        check(E.titleText and E.titleText.text == "Dynamic Ambiance", state .. ": a * in the title")
    end
end)

test("branch UI: unverified - the counter, Save to file, both popups, the draft", function()
    local ns = firstLoad("login")
    check(ns.Store.state() == "unverified", "a fresh install is not unverified")
    local E = ns.Editor
    E.open("zones")
    E.selectZone("Elwynn Forest", 1429)
    E.setZoneValue("contrast", 12)
    check(E.dirtyCount() == 1, "no unsaved zone counted")
    check(E.footerText():find(E.FOOTER_UNVERIFIED, 1, true) == 1
        and E.footerText():find("1 unsaved zone: Save to file to keep them.", 1, true) ~= nil,
        "footer: " .. E.footerText())
    check(E.footerButtonText() == "Save to file", "button")
    local d = _G.DynamicAmbianceDB.editor
    check(d and type(d.draftLines) == "table", "no recovery draft")
    local got = loadZonesText(table.concat(d.draftLines, "\n"))
    check(got and got["Elwynn Forest"].contrast == 12, "the draft is not the current Zones.lua")
    ns.dispatch("ui save")
    check(E.panel == "save" and E.savePanel ~= nil, "/amb ui save did not open Save to file")
    check(wow.popupShown == E.POPUP_SAVE, "no 'not saved yet' popup")
    E.showPanel("props")
    E.setZoneValue("contrast", 13)
    wow.popupShown = nil
    E.close()
    check(wow.popupShown == E.POPUP_UNSAVED, "closing with a dirty zone did not ask")
    check(StaticPopupDialogs[E.POPUP_UNSAVED].text:find("%s Open Save to file?", 1, true) ~= nil,
        "the unsaved popup does not carry the state's line")
    -- force off puts back the judged state; force restart hides Save to file again.
    ns.Store.force("restart")
    check(E.footerButtonText() == "Export" and E.dirtyCount() == 0, "forcing restart did not switch")
    ns.Store.force("off")
    check(ns.Store.state() == "unverified", "force off did not return to the judged state")
end)

-- design/ui/feedback-2.md --------------------------------------------------------------

local function labelOf(b)
    return b and (b.label and b.label.text or b.text) or nil
end

local function press(b)
    check(b ~= nil and b.scripts.OnClick ~= nil, "no button to press")
    b.scripts.OnClick(b, "LeftButton")
end

test("feedback-2 item 3: Revert reads 'Revert to last export'; the tooltip says which", function()
    local ns = firstLoad("login", "70009")
    ns.Store.force("restart")
    local E = ns.Editor
    E.open("zones")
    E.selectZone("Elwynn Forest", 1429)
    E.refreshProps()
    local b = E.revertButton
    check(labelOf(b) == "Revert to last export", "label before an export: " .. tostring(labelOf(b)))
    check(b.enabled == false, "enabled with no export")
    wow.tooltip = nil
    b.scripts.OnEnter(b)
    check(wow.tooltip == "never exported", "disabled tooltip: " .. tostring(wow.tooltip))

    E.open("export")
    E.showPanel("props")
    E.refreshProps()
    local e = ns.Store.getRevert("Elwynn Forest")
    check(e ~= nil, "no revert point after the export")
    check(labelOf(b) == "Revert to last export", "label after an export: " .. tostring(labelOf(b)))
    check(b.enabled == true, "not enabled after an export")
    wow.tooltip = nil
    b.scripts.OnEnter(b)
    local want = ("Last export: v%s, %s"):format(tostring(e.version), tostring(e.when))
    check(wow.tooltip == want, "tooltip: " .. tostring(wow.tooltip) .. ", wanted " .. want)
    check(E.revertTooltip("Elwynn Forest") == want, "revertTooltip: " .. tostring(E.revertTooltip("Elwynn Forest")))
    check(want:match("^Last export: v%d+, 1970%-01%-01 00:00") ~= nil, "the format moved: " .. want)
end)

test("feedback-2 items 2 and 4: Export and Import at the bottom right, separate panels, every branch",
    function()
    for _, state in ipairs({ "restart", "reload", "unverified" }) do
        local ns = firstLoad("login", "70009")
        ns.Store.force(state)
        local E = ns.Editor
        E.open("zones")
        E.selectZone("Elwynn Forest", 1429)
        local normal = state ~= "unverified"
        local foot, imp = E.footerButton, E.importButton
        check(imp ~= nil and labelOf(imp) == "Import", state .. ": no Import in the footer")
        check(labelOf(foot) == (normal and "Export" or "Save to file"),
            state .. ": footer button reads " .. tostring(labelOf(foot)))
        local ip, fp = imp.points[1], foot.points[1]
        check(ip[1] == "BOTTOMRIGHT" and ip[3] == "BOTTOMRIGHT" and fp[1] == "BOTTOMRIGHT",
            state .. ": the buttons are not at the bottom right")
        check(fp[4] <= ip[4] - imp.w, state .. ": the first button does not sit left of Import")
        -- The right column stops above the buttons' row (the window is 780 tall).
        local rowTop = -(780 - ip[5] - imp.h)
        local sp = E.propsScroll.points[1]
        check(sp[5] - E.propsScroll.h > rowTop, state .. ": the properties run into the buttons")
        check(E.msgText.points[1][5] - 26 >= rowTop, state .. ": the message line runs into the buttons")

        press(imp)
        check(E.panel == "import" and E.importPanel:IsShown() and E.importBox.focused,
            state .. ": Import did not open its panel")
        check(not (E.exportPanel and E.exportPanel:IsShown()), state .. ": Export shown with Import")
        check(E.exportImportBox == nil, state .. ": the Export panel still has an import box")

        wow.popupShown = nil
        press(foot)
        if normal then
            check(E.panel == "export" and E.exportPanel:IsShown() and not E.importPanel:IsShown(),
                state .. ": Export did not open its own panel")
            check(wow.popupShown == nil, state .. ": Export raised a popup")
        else
            check(E.panel == "save" and E.savePanel:IsShown() and not E.importPanel:IsShown(),
                state .. ": Save to file did not open")
            ns.dispatch("ui export")
            check(E.panel == "export" and E.exportPanel:IsShown(), state .. ": /amb ui export")
        end
        ns.dispatch("ui import")
        check(E.panel == "import" and E.importPanel:IsShown() and not E.exportPanel:IsShown(),
            state .. ": /amb ui import")
        check(E.importText("DA3~x~~~~~ffff") == false and not E.importError:find("DA1", 1, true),
            state .. ": the refusal names DA1: " .. tostring(E.importError))
        check(not E.IMPORT_TEXT:find("DA1", 1, true), "the import text names DA1")
        E.close()
    end
end)

-- A fresh normal-branch editor on build 70009 with CopyToClipboard stubbed.
local function clipEditor(stub)
    local ns = firstLoad("login", "70009")
    ns.Store.force("restart")
    _G.CopyToClipboard = stub
    local E = ns.Editor
    E.open("zones")
    E.selectZone("Elwynn Forest", 1429)
    return ns, E
end

local function clipRecord()
    local t = _G.DynamicAmbianceDB and _G.DynamicAmbianceDB.clipboard
    return t and t["1.60.1.70009"]
end

test("feedback-2 item 5: Export copies when the client lets it", function()
    local calls = {}
    local ns, E = clipEditor(function(text, removeMarkup)
        calls[#calls + 1] = text
        check(removeMarkup == false, "removeMarkup not false")
        return #text
    end)
    check(E.exportNoteText() == E.CLIP_HINT, "the note before any export")
    ns.dispatch("ui export")
    check(#calls == 0, "/amb ui export (not a click) called CopyToClipboard")
    check(E.exportNote.text == E.CLIP_HINT, "the note after a slash open: " .. tostring(E.exportNote.text))
    press(E.footerButton)
    check(#calls == 1 and calls[1] == E.exportBox:GetText() and calls[1]:sub(1, 4) == "DA2~",
        "Export did not copy the box's string")
    check(E.exportNote.text == E.CLIP_COPIED, "the note: " .. tostring(E.exportNote.text))
    local r = clipRecord()
    check(r and r.outcome == "copied" and r.length == #calls[1], "not recorded as copied")
    local tried, works, line = E.clipboardReport()
    check(tried and works and line:find("on build 1.60.1.70009", 1, true), "report: " .. tostring(line))
    press(E.footerButton)
    check(#calls == 2, "a copy that works was not used again")
    -- The box changes: the clipboard no longer holds it.
    E.showPanel("props")
    E.setZoneValue("contrast", 12)
    E.showPanel("export")
    check(E.exportNote.text == E.CLIP_HINT, "Copied shown for a string that was not copied")
    -- /amb status reports it.
    wow.chat = {}
    ns.dispatch("status")
    check(wow.chatMatches("clipboard: Export copied the preset string") ~= nil,
        "/amb status does not report it")
end)

test("feedback-2 item 5: a copy that raises is recorded and not tried again on the build", function()
    local calls = 0
    local ns, E = clipEditor(function() calls = calls + 1; error("interface action blocked") end)
    press(E.footerButton)
    check(calls == 1, "not tried")
    check(E.panel == "export" and E.exportNote.text == E.CLIP_HINT, "the note: " .. tostring(E.exportNote.text))
    local r = clipRecord()
    check(r and r.outcome == "raised" and r.detail:find("interface action blocked", 1, true),
        "not recorded as raised")
    press(E.footerButton)
    check(calls == 1, "tried again on the same build")
    check(E.exportNote.text == E.CLIP_HINT, "the note on a second export")
    local tried, works, line = E.clipboardReport()
    check(tried and not works and line:find("Select all -> Ctrl+C", 1, true), "report: " .. tostring(line))
    wow.chat = {}
    ns.dispatch("status")
    check(wow.chatMatches("CopyToClipboard raised on build 1.60.1.70009") ~= nil, "/amb status")
    -- Another build tries again.
    setBuild("70010")
    press(E.footerButton)
    check(calls == 2, "a new build did not try")
end)

test("feedback-2 item 5: a refusal event during the call is a refusal, though it returned", function()
    local calls = 0
    local ns, E = clipEditor(function(text)
        calls = calls + 1
        wow.fireAll("ADDON_ACTION_BLOCKED", "DynamicAmbiance", "CopyToClipboard()")
        return #text
    end)
    press(E.footerButton)
    check(E.exportNote.text == E.CLIP_HINT, "Copied shown after a refusal")
    local r = clipRecord()
    check(r and r.outcome == "blocked" and r.detail == "ADDON_ACTION_BLOCKED (CopyToClipboard())",
        "not recorded as blocked: " .. tostring(r and r.detail))
    press(E.footerButton)
    check(calls == 1, "tried again after a refusal")
    check(wow.frameNamed("DynamicAmbianceClipboardWatcher").events.ADDON_ACTION_FORBIDDEN == true,
        "not watching ADDON_ACTION_FORBIDDEN")
end)

test("feedback-2 item 5: a late refusal overrides Copied; other addons' do not count", function()
    local ns, E = clipEditor(function(text)
        wow.fireAll("ADDON_ACTION_FORBIDDEN", "SomeOtherAddon", "UseAction()")
        return #text
    end)
    press(E.footerButton)
    check(clipRecord().outcome == "copied", "another addon's refusal counted")
    check(E.exportNote.text == E.CLIP_COPIED, "not shown as copied")
    wow.fireAll("ADDON_ACTION_FORBIDDEN", "DynamicAmbiance", "CopyToClipboard()")
    check(clipRecord().outcome == "blocked", "a refusal just after the call was missed")
    check(E.exportNote.text == E.CLIP_HINT, "Copied still shown after a late refusal")
    -- The watch ends: a refusal after it is someone else's business.
    _G.DynamicAmbianceDB.clipboard = nil
    wow.runTimers()
    wow.fireAll("ADDON_ACTION_BLOCKED", "DynamicAmbiance", "SetCVar()")
    check(clipRecord() == nil, "the watch outlived its window")
    -- A client with no such function: recorded, the instruction shown.
    _G.CopyToClipboard = nil
    press(E.footerButton)
    check(clipRecord().outcome == "absent" and E.exportNote.text == E.CLIP_HINT, "absent")
    -- Zero copied is not copied.
    _G.DynamicAmbianceDB.clipboard = nil
    _G.CopyToClipboard = function() return 0 end
    press(E.footerButton)
    check(clipRecord().outcome == "zero" and E.exportNote.text == E.CLIP_HINT, "zero")
end)

test("the README's example preset is current DA2 and decodes to its Duskwood", function()
    local fh = assert(io.open(ROOT .. "/README.md", "rb"))
    local text = fh:read("*a")
    fh:close()
    check(not text:find("\nDA1~", 1, true), "the README still shows a DA1 string")
    local s = text:match("\n(DA2~Duskwood~[^\r\n]*)")
    check(s ~= nil, "no DA2 Duskwood example in the README")
    if not s then return end
    local ns = wow.load(ROOT)
    local name, z = ns.Preset.parse(s)
    check(name == "Duskwood" and z and z.contrast == 60 and z.brightness == 40,
        "the example does not decode to Duskwood 60/40: " .. tostring(name))
    if not z then return end
    local a1, a2 = z.areas[1], z.areas[2]
    check(#z.areas == 2 and a1.subzone == "Raven Hill" and a1.contrast == 65 and a1.brightness == 32
        and a2.subzone == "Darkshire" and a2.contrast == 55 and a2.brightness == 48,
        "the example's areas are not Raven Hill 65/32 and Darkshire 55/48")
    check(ns.Preset.serialize(name, z) == s, "the example is not what the encoder writes")
end)

test("load order: no directive, and no saved global touched at file scope", function()
    for _, toc in ipairs({ "/addons/DynamicAmbiance/DynamicAmbiance.toc" }) do
        local fh = assert(io.open(ROOT .. toc, "rb"))
        local t = fh:read("*a")
        fh:close()
        check(not t:find("LoadSavedVariablesFirst", 1, true), "the directive is in " .. toc)
    end
    local files = wow.tocFiles(ROOT)
    for _, f in ipairs(files) do
        local fh = assert(io.open(ROOT .. "/addons/DynamicAmbiance/" .. f, "rb"))
        local n = 0
        for line in fh:lines() do
            n = n + 1
            if line:match("^[%w_]*DB%s*=") or line:match("^local%s+[%w_,%s]+=%s*DynamicAmbiance%w*DB") then
                check(false, ("%s:%d touches a saved global at file scope"):format(f, n))
            end
        end
        fh:close()
    end
end)

-- ------------------------------------------------------------------------------

print()
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
