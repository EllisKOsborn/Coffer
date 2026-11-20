local addonName, Coffer = ...

local PANEL_WIDTH = 290
local PADDING = 14
local CONTENT_WIDTH = PANEL_WIDTH - PADDING * 2
local ROW_HEIGHT = 18
local GPH_HEIGHT = 22
local TOP_CHROME = 40 -- icon inset + icon + gap down to the first row
local BOTTOM_PAD = 10
local MAX_ITEMS = 8
local MAX_ITEMS_EXPANDED = 30
local MAX_RUNS = 8

local FONT = "Fonts\\FRIZQT__.TTF"
local COLORS = {
    gold = { 1, 0.82, 0 },
    white = { 0.93, 0.93, 0.93 },
    label = { 0.74, 0.74, 0.74 },
    muted = { 0.55, 0.55, 0.55 },
    green = { 0.32, 0.86, 0.47 },
    red = { 1, 0.4, 0.4 },
    orange = { 1, 0.62, 0.2 },
    border = { 0.55, 0.43, 0.15 },
}
local GRAY = "|cff8a8a8a"

local frame
local rows = {}      -- fixed rows, by name
local sections = {}  -- collapsible sections, by key
local itemPool, runPool = {}, {}
local ticker

-- ---------------------------------------------------------------------------
-- Widget helpers
-- ---------------------------------------------------------------------------
-- Everything is built from plain textures and font strings rather than Blizzard XML
-- templates (BackdropTemplate, UIPanelCloseButton, dropdown menus): which templates
-- exist on Forever's client can't be assumed, and a missing one breaks the whole panel.

local function SetFont(fs, size, color, flags)
    fs:SetFont(FONT, size, flags or "")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
end

local function Text(parent, size, color, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    SetFont(fs, size, color, flags)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end

local function Solid(parent, layer, color, alpha)
    local t = parent:CreateTexture(nil, layer)
    t:SetColorTexture(color[1], color[2], color[3], alpha)
    return t
end

local function Paint(fs, color)
    fs:SetTextColor(color[1], color[2], color[3])
end

local function Hex(color)
    local function byte(c) return math.floor(c * 255 + 0.5) end
    return ("|cff%02x%02x%02x"):format(byte(color[1]), byte(color[2]), byte(color[3]))
end

local function Box(parent, name, alpha)
    local f = CreateFrame("Frame", name, parent)
    Solid(f, "BACKGROUND", { 0.04, 0.04, 0.05 }, alpha or 0.93):SetAllPoints()
    local function Edge(p1, p2, w, h)
        local t = Solid(f, "BORDER", COLORS.border, 0.9)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return f
end

local function ShowTooltip(owner, build)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    local ok, err = pcall(build, GameTooltip)
    if not ok then Coffer:ReportError("tooltip", err) end
    GameTooltip:Show()
end

local function HideTooltip()
    if GameTooltip then GameTooltip:Hide() end
end

local function Line(tip, left, right, color)
    color = color or COLORS.white
    tip:AddDoubleLine(left, right, COLORS.label[1], COLORS.label[2], COLORS.label[3], color[1], color[2], color[3])
end

-- Rows take the mouse for tooltips, which would stop the panel being dragged by them;
-- forward drags to the panel.
local function ForwardDrag(region)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function() frame:GetScript("OnDragStart")(frame) end)
    region:SetScript("OnDragStop", function() frame:GetScript("OnDragStop")(frame) end)
end

local function Hoverable(region, build)
    region:EnableMouse(true)
    region:SetScript("OnEnter", function(self) ShowTooltip(self, function(tip) build(tip, self) end) end)
    region:SetScript("OnLeave", HideTooltip)
    ForwardDrag(region)
end

local function LabelRow(label)
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
    row.label = Text(row, 11, COLORS.label)
    row.label:SetPoint("LEFT")
    row.label:SetText(label)
    row.value = Text(row, 12, COLORS.white)
    row.value:SetPoint("RIGHT")
    return row
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
-- Every visible region is positioned through Place(), which also adds its height to a
-- running total. The panel's height therefore comes from the very same numbers that
-- positioned its contents - never from GetTop()/GetBottom(), whose results aren't
-- reliably readable from Lua on this client (the cause of the earlier invisible,
-- zero-height panel).

local layout

local function Begin()
    layout = { anchor = nil, x = 0, height = TOP_CHROME }
end

local function Place(region, gap, height, x)
    x = x or 0
    region:ClearAllPoints()
    if layout.anchor then
        -- relative to the previous region, compensating its own indent
        region:SetPoint("TOPLEFT", layout.anchor, "BOTTOMLEFT", x - layout.x, -gap)
    else
        region:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING + x, -(layout.height + gap))
    end
    layout.anchor, layout.x = region, x
    layout.height = layout.height + gap + height
    region:Show()
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

local function SetChevron(section)
    section.chevron:SetText(section.collapsed and ">" or "v")
end

-- A collapsible section: a full-width highlighted header bar with a title on the left
-- and a summary (duration, total, count) on the right that stays visible when collapsed.
-- Left-click collapses (remembered between sessions); right-click runs onRightClick.
local function Section(key, title)
    local s = { key = key }
    local header = CreateFrame("Button", nil, frame)
    header:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
    header:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local bar = Solid(header, "BACKGROUND", COLORS.border, 0.14)
    bar:SetPoint("TOPLEFT", header, "TOPLEFT", -PADDING, 2)
    bar:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", PADDING, -1)
    local rule = Solid(header, "BORDER", COLORS.border, 0.35)
    rule:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
    rule:SetHeight(1)

    s.chevron = Text(header, 9, COLORS.gold)
    s.chevron:SetPoint("LEFT")
    s.label = Text(header, 11, COLORS.gold)
    s.label:SetPoint("LEFT", s.chevron, "RIGHT", 5, 0)
    s.label:SetText(title)
    s.summary = Text(header, 11, COLORS.muted)
    s.summary:SetPoint("RIGHT")

    s.collapsed = Coffer.db.settings.collapsed[key] and true or false
    SetChevron(s)

    header:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if s.onRightClick then s.onRightClick() end
            return
        end
        s.collapsed = not s.collapsed
        Coffer.db.settings.collapsed[key] = s.collapsed or nil
        SetChevron(s)
        Coffer:RefreshUI()
    end)
    header:SetScript("OnEnter", function(self)
        if s.tooltip then ShowTooltip(self, s.tooltip) end
    end)
    header:SetScript("OnLeave", HideTooltip)
    ForwardDrag(header)

    s.header = header
    sections[key] = s
    return s
end

-- A "and N more" / empty-state line inside a section.
local function NoteLine(onClick)
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(CONTENT_WIDTH - 20, 14)
    b.text = Text(b, 10, COLORS.muted)
    b.text:SetPoint("LEFT")
    if onClick then
        b:SetScript("OnClick", onClick)
        b:SetScript("OnEnter", function() Paint(b.text, COLORS.gold) end)
        b:SetScript("OnLeave", function() Paint(b.text, COLORS.muted) end)
    end
    ForwardDrag(b)
    return b
end

-- ---------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------

local function ItemName(itemID, entry)
    local name, _, quality = Coffer.GetItemInfo(itemID)
    return name or (entry and entry.link) or ("item:" .. itemID), quality
end

local function RunTooltip(tip, run)
    tip:AddLine(run.name, COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    local started = date and date("%a %H:%M", run.startTime) or ""
    tip:AddLine(started .. "  " .. GRAY .. Coffer:FormatDuration(Coffer:GetRunDuration(run)) .. "|r", 0.7, 0.7, 0.7)
    tip:AddLine(" ")
    local itemsValue = run.itemsValue or Coffer:GetRunItemsValue(run)
    Line(tip, "Looted gold", Coffer:FormatSignedShort(run.loot or 0), COLORS.green)
    Line(tip, "Quest gold", Coffer:FormatSignedShort(run.quest or 0), COLORS.green)
    Line(tip, "Items", Coffer:FormatSignedShort(itemsValue), COLORS.green)
    Line(tip, "Spent", Coffer:FormatSignedShort(-(run.spent or 0)), COLORS.red)
    local net = Coffer:GetRunNet(run)
    Line(tip, "Net", Coffer:FormatSignedShort(net), net >= 0 and COLORS.green or COLORS.red)
    Line(tip, "Kills", tostring(run.kills or 0))

    local list = {}
    for itemID, entry in pairs(run.items or {}) do
        list[#list + 1] = { id = itemID, count = entry.count, value = Coffer:ValueOf(itemID) * entry.count }
    end
    table.sort(list, function(a, b) return a.value > b.value end)
    if #list > 0 then
        tip:AddLine(" ")
        for i = 1, math.min(#list, 6) do
            local name, quality = ItemName(list[i].id)
            local r, g, b = Coffer:GetQualityColor(quality)
            tip:AddDoubleLine(name .. (list[i].count > 1 and (GRAY .. " x" .. list[i].count .. "|r") or ""),
                Coffer:FormatShort(list[i].value), r, g, b, 1, 1, 1)
        end
        if #list > 6 then
            tip:AddLine(("and %d more"):format(#list - 6), 0.55, 0.55, 0.55)
        end
    end
end

local function SessionTooltip(tip)
    local s = Coffer.db.session
    tip:AddLine("This session", COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    tip:AddLine("Online time only - time logged off doesn't count.", 0.7, 0.7, 0.7, true)
    tip:AddLine(" ")
    Line(tip, "Looted gold", Coffer:FormatSignedShort(s.loot), COLORS.green)
    Line(tip, "Quest gold", Coffer:FormatSignedShort(s.quest), COLORS.green)
    Line(tip, "Items looted", Coffer:FormatSignedShort(Coffer:GetSessionItemsValue()), COLORS.green)
    Line(tip, "Spent", Coffer:FormatSignedShort(-s.spent), COLORS.red)
    Line(tip, "Kills", tostring(s.kills))
    Line(tip, "Sold to vendors", Coffer:FormatShort(s.vendor), COLORS.muted)
    tip:AddLine(" ")
    tip:AddLine("Vendor sales aren't counted as income: those items were already counted at their value when looted.", 0.55, 0.55, 0.55, true)
    tip:AddLine("Right-click to start a new session.", 0.55, 0.55, 0.55)
end

local function GphTooltip(tip)
    tip:AddLine("Gold per hour", COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    tip:AddLine("(looted gold + quest gold + item value) / online time", 0.75, 0.75, 0.75, true)
    tip:AddLine(" ")
    local valuation = Coffer.db.settings.valuation
    tip:AddLine(valuation == "auction"
        and "Items are valued at auction price (TSM or Auctionator), never below vendor price."
        or "Items are valued at vendor price.", 0.55, 0.55, 0.55, true)
end

local function LockoutTooltip(tip)
    local st = Coffer:GetLockoutStatus()
    tip:AddLine("Instance lockouts", COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    tip:AddLine(("Classic rules: %d instances per hour, %d per day, shared by your whole account. An instance counts once you've killed something in it."):format(st.hourLimit, st.dayLimit), 0.75, 0.75, 0.75, true)
    if st.freeIn then
        tip:AddLine(" ")
        tip:AddLine("Next instance available in " .. Coffer:FormatDuration(st.freeIn), COLORS.red[1], COLORS.red[2], COLORS.red[3])
    end
    if #st.entries > 0 then
        tip:AddLine(" ")
        local now = time()
        for i = #st.entries, math.max(1, #st.entries - 9), -1 do
            local e = st.entries[i]
            local ago = Coffer:FormatDuration(now - e.time) .. " ago"
            local recent = now - e.time < 3600
            tip:AddDoubleLine(e.zone .. (e.reset and (GRAY .. " (reset)|r") or ""), ago,
                recent and 1 or 0.6, recent and 1 or 0.6, recent and 1 or 0.6, 0.6, 0.6, 0.6)
        end
    end
end

-- ---------------------------------------------------------------------------
-- List rows (items, runs)
-- ---------------------------------------------------------------------------

local function Confirm(key, text, onAccept)
    if StaticPopupDialogs and StaticPopup_Show then
        StaticPopupDialogs[key] = {
            text = text, button1 = YES or "Yes", button2 = NO or "No",
            OnAccept = onAccept, timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show(key)
    else
        onAccept()
    end
end

local function ListRow(pool, index, withIcon)
    local row = pool[index]
    if row then return row end
    row = CreateFrame("Button", nil, frame)
    row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
    local highlight = Solid(row, "HIGHLIGHT", { 1, 1, 1 }, 0.06)
    highlight:SetPoint("TOPLEFT", -4, 0)
    highlight:SetPoint("BOTTOMRIGHT", 4, 0)
    row.value = Text(row, 11, COLORS.white)
    row.value:SetPoint("RIGHT")
    row.name = Text(row, 11, COLORS.white)
    row.name:SetJustifyH("LEFT")
    if withIcon then
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT")
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    else
        row.name:SetPoint("LEFT")
    end
    row.name:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
    row:SetScript("OnEnter", function(self)
        if self.tooltip then ShowTooltip(self, self.tooltip) end
    end)
    row:SetScript("OnLeave", HideTooltip)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if not self.itemID then return end
        if button == "RightButton" then
            local itemID = self.itemID
            local name = Coffer.GetItemInfo(itemID) or "this item"
            Confirm("COFFER_FORGET_ITEM", ("Stop counting %s this session?"):format(name), function()
                Coffer:ForgetItem(itemID)
            end)
        elseif self.link and IsShiftKeyDown and IsShiftKeyDown() and ChatEdit_InsertLink then
            -- shift-click links the item in chat, like anywhere else in the UI
            ChatEdit_InsertLink(self.link)
        end
    end)
    ForwardDrag(row)
    pool[index] = row
    return row
end

local function HideFrom(pool, first)
    for i = first, #pool do
        pool[i]:Hide()
    end
end

local function SortedItems()
    local list = {}
    for itemID, entry in pairs(Coffer.db.session.items) do
        list[#list + 1] = { id = itemID, entry = entry, total = (entry.value or 0) * entry.count }
    end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.id < b.id
    end)
    return list
end

local function SignedColor(amount)
    if math.floor(math.abs(amount) + 0.5) == 0 then return COLORS.muted end
    return amount > 0 and COLORS.green or COLORS.red
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

local function LayoutTop()
    local gph = Coffer:GetGoldPerHour()
    Place(rows.gph, 0, GPH_HEIGHT)
    rows.gph.value:SetText(gph and (Coffer:FormatShort(gph) .. GRAY .. " /hr|r") or (GRAY .. "-|r"))

    Place(rows.gold, 4, ROW_HEIGHT)
    rows.gold.value:SetText(Coffer:FormatMoney(GetMoney()))

    Place(rows.instances, 2, ROW_HEIGHT)
    local st = Coffer:GetLockoutStatus()
    local hourColor = st.hour >= st.hourLimit and COLORS.red
        or (st.hour >= st.hourLimit - 1 and COLORS.orange or COLORS.white)
    local dayColor = st.day >= st.dayLimit and COLORS.red
        or (st.day >= st.dayLimit - 5 and COLORS.orange or COLORS.white)
    local text = ("%s%d/%d|r%s hr|r  %s%d/%d|r%s day|r"):format(
        Hex(hourColor), st.hour, st.hourLimit, GRAY, Hex(dayColor), st.day, st.dayLimit, GRAY)
    if st.freeIn then
        text = Hex(COLORS.red) .. "free in " .. Coffer:FormatDuration(st.freeIn) .. "|r  " .. text
    end
    rows.instances.value:SetText(text)
end

local function LayoutCurrentRun()
    local s = sections.current
    local run = Coffer:GetActiveRun()
    if not run then
        s.header:Hide()
        rows.current:Hide()
        return
    end
    Place(s.header, 12, ROW_HEIGHT)
    s.summary:SetText(Coffer:FormatDuration(Coffer:GetRunDuration(run))
        .. (run.pausedAt and (Hex(COLORS.red) .. "  dead|r") or ""))
    if s.collapsed then
        rows.current:Hide()
        return
    end
    Place(rows.current, 2, ROW_HEIGHT)
    rows.current.label:SetText(run.name)
    local net = Coffer:GetRunNet(run)
    rows.current.value:SetText(Coffer:FormatSignedShort(net))
    Paint(rows.current.value, SignedColor(net))
end

local function LayoutSession()
    local s = sections.session
    Place(s.header, 12, ROW_HEIGHT)
    s.summary:SetText(Coffer:FormatDuration(Coffer:GetSessionDuration()))
    local sessionRows = { rows.earned, rows.items, rows.spent, rows.total }
    if s.collapsed then
        for _, row in ipairs(sessionRows) do row:Hide() end
        return
    end
    local values = {
        Coffer:GetSessionEarned(),
        Coffer:GetSessionItemsValue(),
        -Coffer.db.session.spent,
        Coffer:GetSessionNet(),
    }
    for i, row in ipairs(sessionRows) do
        Place(row, 2, ROW_HEIGHT)
        row.value:SetText(Coffer:FormatSignedShort(values[i]))
        Paint(row.value, SignedColor(values[i]))
    end
end

local showAllItems = false

local function LayoutItems()
    local s = sections.items
    Place(s.header, 12, ROW_HEIGHT)
    s.summary:SetText(Coffer:FormatShort(Coffer:GetSessionItemsValue()))
    if s.collapsed then
        HideFrom(itemPool, 1)
        rows.itemsNote:Hide()
        return
    end

    local list = SortedItems()
    local limit = showAllItems and MAX_ITEMS_EXPANDED or MAX_ITEMS
    local shown = math.min(#list, limit)
    for i = 1, shown do
        local data = list[i]
        local row = ListRow(itemPool, i, true)
        local name, quality = ItemName(data.id, data.entry)
        local r, g, b = Coffer:GetQualityColor(quality)
        row.icon:SetTexture((Coffer.GetItemIcon and Coffer.GetItemIcon(data.id)) or 134400)
        row.name:SetText(name .. (data.entry.count > 1 and (GRAY .. "  x" .. data.entry.count .. "|r") or ""))
        row.name:SetTextColor(r, g, b)
        row.value:SetText(data.entry.value and Coffer:FormatShort(data.total) or (GRAY .. "...|r"))
        row.link, row.itemID = data.entry.link, data.id
        row.tooltip = function(tip)
            if row.link then
                tip:SetHyperlink(row.link)
            elseif tip.SetItemByID then
                tip:SetItemByID(row.itemID)
            end
            tip:AddLine(" ")
            local each = data.entry.value or 0
            tip:AddDoubleLine("Looted this session", tostring(data.entry.count), 0.75, 0.75, 0.75, 1, 1, 1)
            tip:AddDoubleLine("Value each (" .. (data.entry.source or "?") .. ")", Coffer:FormatMoney(each), 0.75, 0.75, 0.75, 1, 1, 1)
            tip:AddLine("Shift-click to link in chat", 0.55, 0.55, 0.55)
            tip:AddLine("Right-click to stop counting it (e.g. it wasn't loot)", 0.55, 0.55, 0.55)
        end
        Place(row, 2, ROW_HEIGHT)
    end
    HideFrom(itemPool, shown + 1)

    local note = rows.itemsNote
    if #list == 0 then
        note.text:SetText("Nothing looted yet this session")
        Place(note, 2, 14, 20)
    elseif #list > MAX_ITEMS then
        note.text:SetText(showAllItems and "show fewer" or ("and %d more"):format(#list - shown))
        Place(note, 2, 14, 20)
    else
        note:Hide()
    end
end

local function LayoutRuns()
    local s = sections.runs
    local runs = Coffer.db.runs
    Place(s.header, 12, ROW_HEIGHT)
    s.summary:SetText(#runs == 1 and "1 run" or (#runs .. " runs"))
    if s.collapsed then
        HideFrom(runPool, 1)
        rows.runsNote:Hide()
        return
    end

    local shown = math.min(#runs, MAX_RUNS)
    for i = 1, shown do
        local run = runs[i]
        local row = ListRow(runPool, i, false)
        row.name:SetText(GRAY .. Coffer:FormatDuration(run.duration or Coffer:GetRunDuration(run)) .. "|r  " .. (run.name or "?"))
        local net = Coffer:GetRunNet(run)
        row.value:SetText(Coffer:FormatSignedShort(net))
        Paint(row.value, SignedColor(net))
        row.link = nil
        row.tooltip = function(tip) RunTooltip(tip, run) end
        Place(row, 2, ROW_HEIGHT)
    end
    HideFrom(runPool, shown + 1)

    if #runs == 0 then
        rows.runsNote.text:SetText("Finished dungeon runs show up here")
        Place(rows.runsNote, 2, 14, 20)
    else
        rows.runsNote:Hide()
    end
end

local function RefreshUIImpl()
    if not frame or not frame:IsShown() or not Coffer.db then return end
    Begin()
    LayoutTop()
    LayoutCurrentRun()
    LayoutSession()
    LayoutItems()
    LayoutRuns()
    frame:SetHeight(layout.height + BOTTOM_PAD)
end

local lastUIError
function Coffer:RefreshUI()
    local ok, err = pcall(RefreshUIImpl)
    if not ok and err ~= lastUIError then
        lastUIError = err
        self:ReportError("panel", err)
    end
end

-- ---------------------------------------------------------------------------
-- Settings menu (built by hand: dropdown menu templates differ between clients)
-- ---------------------------------------------------------------------------

local menu

local function MenuEntries()
    local settings = Coffer.db.settings
    local function mark(on) return on and "|cffffd200>|r " or "   " end
    return {
        { text = settings.locked and "Unlock panel" or "Lock panel", func = function()
            settings.locked = not settings.locked
        end },
        { text = mark(settings.valuation == "auction") .. "Value items at auction price", func = function()
            Coffer:SetValuation("auction")
        end },
        { text = mark(settings.valuation == "vendor") .. "Value items at vendor price", func = function()
            Coffer:SetValuation("vendor")
        end },
        { text = "Re-price items now", func = function() Coffer:RepriceItems() end },
        { text = "Start a new session...", func = function()
            Confirm("COFFER_RESET_SESSION", "Start a new Coffer session? Run history is kept.", function() Coffer:ResetSession() end)
        end },
        { text = "Clear run history...", func = function()
            Confirm("COFFER_CLEAR_RUNS", "Delete Coffer's recent runs history?", function() Coffer:ClearRuns() end)
        end },
    }
end

local function ToggleMenu(anchor)
    if menu and menu:IsShown() then
        menu:Hide()
        return
    end
    if not menu then
        menu = Box(UIParent, "CofferMenu", 0.97)
        menu:SetFrameStrata("DIALOG")
        menu:SetClampedToScreen(true)
        menu:EnableMouse(true)
        menu.buttons = {}
        if UISpecialFrames then table.insert(UISpecialFrames, "CofferMenu") end -- Escape closes it
    end
    local entries = MenuEntries()
    for i, entry in ipairs(entries) do
        local b = menu.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetSize(210, 18)
            b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
            Solid(b, "HIGHLIGHT", COLORS.gold, 0.12):SetAllPoints()
            b.text = Text(b, 11, COLORS.white)
            b.text:SetPoint("LEFT", 4, 0)
            menu.buttons[i] = b
        end
        b.text:SetText(entry.text)
        b:SetScript("OnClick", function()
            menu:Hide()
            entry.func()
            Coffer:RefreshUI()
        end)
        b:Show()
    end
    menu:SetSize(222, #entries * 18 + 12)
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
    menu:Show()
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

-- Refreshes once a second while visible, so durations and gold per hour stay live.
local function StartTicker()
    if not ticker then
        ticker = C_Timer.NewTicker(1, function() Coffer:RefreshUI() end)
    end
end

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function BuildFrame()
    frame = Box(UIParent, "CofferFrame")
    frame:SetWidth(PANEL_WIDTH)
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not Coffer.db.settings.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Coffer.db.settings.point = { point, relPoint, x, y }
    end)

    -- header
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("TOPLEFT", PADDING, -12)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local title = Text(frame, 14, COLORS.gold, "OUTLINE")
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    title:SetText("Coffer")

    local divider = Solid(frame, "BORDER", COLORS.border, 0.3)
    divider:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -36)
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -36)
    divider:SetHeight(1)

    local close = CreateFrame("Button", nil, frame)
    close:SetSize(16, 16)
    close:SetPoint("TOPRIGHT", -6, -12)
    close.text = Text(close, 13, COLORS.muted)
    close.text:SetPoint("CENTER")
    close.text:SetText("x")
    close:SetScript("OnEnter", function() Paint(close.text, COLORS.gold) end)
    close:SetScript("OnLeave", function() Paint(close.text, COLORS.muted) end)
    close:SetScript("OnClick", function() Coffer:SetPanelShown(false) end)

    -- settings: a real icon texture rather than a gear glyph, since font coverage for
    -- symbol characters can't be assumed
    local gear = CreateFrame("Button", nil, frame)
    gear:SetSize(14, 14)
    gear:SetPoint("RIGHT", close, "LEFT", -6, 0)
    local gearIcon = gear:CreateTexture(nil, "ARTWORK")
    gearIcon:SetAllPoints()
    gearIcon:SetTexture("Interface\\Icons\\Trade_Engineering")
    gearIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    gearIcon:SetVertexColor(0.65, 0.65, 0.65)
    gear:SetScript("OnEnter", function() gearIcon:SetVertexColor(1, 0.82, 0) end)
    gear:SetScript("OnLeave", function() gearIcon:SetVertexColor(0.65, 0.65, 0.65) end)
    gear:SetScript("OnClick", function(self) ToggleMenu(self) end)

    -- gold per hour, on a highlighted bar with an accent stripe as in the reference
    local gph = CreateFrame("Frame", nil, frame)
    gph:SetSize(CONTENT_WIDTH, GPH_HEIGHT)
    local gphBar = Solid(gph, "BACKGROUND", COLORS.gold, 0.08)
    gphBar:SetPoint("TOPLEFT", -PADDING + 1, 0)
    gphBar:SetPoint("BOTTOMRIGHT", PADDING - 1, 0)
    local accent = Solid(gph, "BORDER", COLORS.gold, 0.9)
    accent:SetPoint("TOPLEFT", gphBar, "TOPLEFT")
    accent:SetPoint("BOTTOMLEFT", gphBar, "BOTTOMLEFT")
    accent:SetWidth(2)
    gph.label = Text(gph, 12, COLORS.gold)
    gph.label:SetPoint("LEFT")
    gph.label:SetText("Gold per hour")
    gph.value = Text(gph, 15, COLORS.gold)
    gph.value:SetPoint("RIGHT")
    Hoverable(gph, GphTooltip)
    rows.gph = gph

    rows.gold = LabelRow("Your gold")
    rows.instances = LabelRow("Instances")
    Hoverable(rows.instances, LockoutTooltip)

    local current = Section("current", "CURRENT RUN")
    current.tooltip = function(tip)
        local run = Coffer:GetActiveRun()
        if run then RunTooltip(tip, run) end
    end
    rows.current = LabelRow("")
    Paint(rows.current.label, COLORS.white)
    Hoverable(rows.current, current.tooltip)

    local session = Section("session", "THIS SESSION")
    session.tooltip = SessionTooltip
    session.onRightClick = function()
        Confirm("COFFER_RESET_SESSION", "Start a new Coffer session? Run history is kept.", function() Coffer:ResetSession() end)
    end
    rows.earned = LabelRow("Earned")
    rows.items = LabelRow("Items")
    rows.spent = LabelRow("Spent")
    rows.total = LabelRow("Total")
    for _, key in ipairs({ "earned", "items", "spent", "total" }) do
        Hoverable(rows[key], SessionTooltip)
    end

    Section("items", "ITEMS")
    rows.itemsNote = NoteLine(function()
        showAllItems = not showAllItems
        Coffer:RefreshUI()
    end)

    Section("runs", "RECENT RUNS")
    rows.runsNote = NoteLine()

    -- position: restored, else a fixed default; always a TOPLEFT-style anchor so height
    -- changes grow the panel downward
    frame:ClearAllPoints()
    local point = Coffer.db.settings.point
    if point then
        frame:SetPoint(point[1], UIParent, point[2], point[3], point[4])
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 240, -200)
    end

    -- OnShow/OnHide also cover the whole UI being hidden (Alt+Z); the panel's own first
    -- Show() doesn't fire OnShow (frames are created already shown), so SetPanelShown
    -- starts the ticker explicitly too.
    frame:SetScript("OnShow", StartTicker)
    frame:SetScript("OnHide", function()
        StopTicker()
        if menu then menu:Hide() end
    end)
end

local function EnsureFrame()
    if frame then return true end
    local ok, err = pcall(BuildFrame)
    if not ok then
        Coffer:ReportError("building the panel", err)
        return false
    end
    return true
end

-- Visibility is remembered between sessions.
function Coffer:SetPanelShown(shown)
    self.db.settings.hidden = not shown
    if shown then
        if not EnsureFrame() then return end
        frame:Show()
        StartTicker()
        self:RefreshUI()
    elseif frame then
        frame:Hide()
        if not self.hintedReopen then
            self.hintedReopen = true
            print("|cffffd200Coffer:|r hidden. Type /coffer to show it again.")
        end
    end
end

function Coffer:ToggleFrame()
    self:SetPanelShown(not (frame and frame:IsShown()))
end

function Coffer:ForceShowPanel()
    self:SetPanelShown(true)
    return frame ~= nil
end

function Coffer:GetPanelGeometry()
    if not frame then return nil end
    return { width = frame:GetWidth(), height = frame:GetHeight(), shown = frame:IsShown() }
end

Coffer:OnReady(function(self)
    if not self.db.settings.hidden then
        self:SetPanelShown(true)
    end
    -- the addon dropdown next to the minimap on modern clients
    if AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
        pcall(AddonCompartmentFrame.RegisterAddon, AddonCompartmentFrame, {
            text = "Coffer",
            icon = "Interface\\Icons\\INV_Misc_Coin_01",
            notCheckable = true,
            func = function() Coffer:ToggleFrame() end,
        })
    end
end)

-- ---------------------------------------------------------------------------
-- Debug window (/coffer debug)
-- ---------------------------------------------------------------------------
-- A scrollable, selectable window rather than chat, which heavy chat traffic can bury.

local debugWindow
function Coffer:ShowDebugText(text)
    if not debugWindow then
        local f = Box(UIParent, "CofferDebugFrame", 0.98)
        f:SetSize(520, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        local title = Text(f, 13, COLORS.gold, "OUTLINE")
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText("Coffer debug - Ctrl+A, Ctrl+C to copy")

        local close = CreateFrame("Button", nil, f)
        close:SetSize(20, 20)
        close:SetPoint("TOPRIGHT", -6, -6)
        close.text = Text(close, 14, COLORS.muted)
        close.text:SetPoint("CENTER")
        close.text:SetText("x")
        close:SetScript("OnClick", function() f:Hide() end)

        local scroll = CreateFrame("ScrollFrame", nil, f)
        scroll:SetPoint("TOPLEFT", 12, -32)
        scroll:SetPoint("BOTTOMRIGHT", -12, 12)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            self:SetVerticalScroll(math.max(0, (self:GetVerticalScroll() or 0) - delta * 20))
        end)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal or GameFontNormal)
        edit:SetWidth(480)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)

        f.edit = edit
        debugWindow = f
    end
    debugWindow.edit:SetText(text)
    debugWindow.edit:HighlightText()
    debugWindow.edit:SetFocus()
    debugWindow:Show()
end
