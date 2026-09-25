-- Dynamic Ambiance - editor theme ---------------------------------------------------
--
-- design/ui/DESIGN-ui.md section 5. Every colour and font the editor window uses
-- comes from the active table here, so delivery 3's picker and its Modern table
-- change the look without touching a caller.
--
-- Delivery 1 ships only Classic, built from what M4 measured present on build
-- 69977: the dialog background and border art, and GameFontNormal's font. The
-- colours are proposals, to be judged by eye at the acceptance run.

local ADDON, ns = ...
if not ns then return end

local Theme = { tables = {}, activeName = "Classic" }
ns.Theme = Theme

Theme.tables.Classic = {
    -- M4: both load (fileIDs 131071, 131072).
    panelBg     = "Interface\\DialogFrame\\UI-DialogBox-Background",
    panelBorder = "Interface\\DialogFrame\\UI-DialogBox-Border",

    text      = { 1.00, 1.00, 1.00 },
    textMuted = { 0.62, 0.62, 0.62 },
    accent    = { 1.00, 0.82, 0.00 },         -- GameFontNormal's gold

    -- M4: GameFontNormal:GetFont() = Fonts\FRIZQT__.TTF, 12. A missing font
    -- raises in SetFont, so only the four measured fonts may ever go here.
    font     = "Fonts\\FRIZQT__.TTF",
    fontSize = 12,

    -- Proposal: one colour per priority band in Config.lua, chosen so the
    -- shipped bands read distinctly. The selected area is drawn white on top.
    priorityColors = {
        { min = -math.huge, max = 19, color = { 0.35, 0.60, 1.00 } },   -- blue
        { min = 20, max = 49,         color = { 0.35, 0.90, 0.35 } },   -- green
        { min = 50, max = 59,         color = { 1.00, 0.72, 0.20 } },   -- amber
        { min = 60, max = math.huge,  color = { 1.00, 0.30, 0.30 } },   -- red
    },
}

function Theme.active()
    return Theme.tables[Theme.activeName] or Theme.tables.Classic
end

function Theme.get(key)
    return Theme.active()[key]
end

-- r, g, b for a priority, from the active table's bands.
function Theme.priorityColor(p)
    p = p or 0
    local bands = Theme.get("priorityColors") or {}
    for i = 1, #bands do
        local b = bands[i]
        if p >= b.min and p <= b.max then
            return b.color[1], b.color[2], b.color[3]
        end
    end
    return 1, 1, 1
end

function Theme.rgb(key)
    local c = Theme.get(key)
    if type(c) ~= "table" then return 1, 1, 1 end
    return c[1], c[2], c[3]
end
