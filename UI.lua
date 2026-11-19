local addonName, Coffer = ...

local PANEL_WIDTH = 280
local PADDING = 14
local ROW_HEIGHT = 18
local MAX_VISIBLE_ITEMS = 8
local MAX_VISIBLE_RUNS = 8

local GOLD = { 1, 0.82, 0 }
local WHITE = { 0.92, 0.92, 0.92 }
local MUTED = { 0.6, 0.6, 0.6 }
local GREEN = { 0.25, 0.82, 0.42 }
local RED = { 1, 0.37, 0.37 }

local frame
local gphValue, goldValue
local durationValue, earnedValue, spentValue, netValue
local itemsSection, runsSection
local itemRows = {}
local runRows = {}
local ticker

local function CreateBackdropFrame(parent, name)
    local f = CreateFrame("Frame", name, parent, "BackdropTemplate")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.04, 0.04, 0.05, 0.93)
    f:SetBackdropBorderColor(0.5, 0.39, 0.14, 0.9)
    return f
end

local function SetFont(fs, size, color, flags)
    fs:SetFont("Fonts\\FRIZQT__.TTF", size, flags or "")
    if color then
        fs:SetTextColor(color[1], color[2], color[3])
    end
end

local function CreateLabelRow(parent, labelText, labelColor, valueSize)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetWidth(PANEL_WIDTH - PADDING * 2)

    local label = row:CreateFontString(nil, "OVERLAY")
    SetFont(label, 11, labelColor or MUTED)
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetText(labelText)

    local value = row:CreateFontString(nil, "OVERLAY")
    SetFont(value, valueSize or 12, WHITE)
    value:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    return row, value
end

-- A collapsible section header. Returns the section table; .body should be anchored
-- by the caller and shown/hidden based on section.collapsed.
local function CreateSection(parent, title)
    local header = CreateFrame("Button", nil, parent)
    header:SetHeight(ROW_HEIGHT)
    header:SetWidth(PANEL_WIDTH - PADDING * 2)

    local chevron = header:CreateFontString(nil, "OVERLAY")
    SetFont(chevron, 10, GOLD)
    chevron:SetPoint("LEFT", header, "LEFT", 0, 0)
    chevron:SetText("v")

    local label = header:CreateFontString(nil, "OVERLAY")
    SetFont(label, 11, GOLD, "")
    label:SetPoint("LEFT", chevron, "RIGHT", 5, 0)
    label:SetText(title:upper())

    local section = { header = header, chevron = chevron, collapsed = false }
    header:SetScript("OnClick", function()
        section.collapsed = not section.collapsed
        section.chevron:SetText(section.collapsed and ">" or "v")
        Coffer:RefreshUI()
    end)
    return section
end

local function AcquireRow(pool, parent)
    for _, row in ipairs(pool) do
        if not row.used then
            row.used = true
            row:Show()
            return row
        end
    end
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetWidth(PANEL_WIDTH - PADDING * 2)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(14, 14)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

    row.name = row:CreateFontString(nil, "OVERLAY")
    SetFont(row.name, 11, WHITE)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
    row.name:SetJustifyH("LEFT")

    row.value = row:CreateFontString(nil, "OVERLAY")
    SetFont(row.value, 11, GOLD)
    row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    row.used = true
    table.insert(pool, row)
    return row
end

local function ReleaseUnused(pool)
    for _, row in ipairs(pool) do
        if not row.used then
            row:Hide()
        end
        row.used = false
    end
end

local function BuildFrame()
    frame = CreateBackdropFrame(UIParent, "CofferFrame")
    frame:SetWidth(PANEL_WIDTH)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not Coffer.db.settings.locked then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Coffer.db.settings.point = { point, relPoint, x, y }
    end)
    frame:SetClampedToScreen(true)

    -- header
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("TOPLEFT", PADDING, -12)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")

    local title = frame:CreateFontString(nil, "OVERLAY")
    SetFont(title, 14, GOLD, "OUTLINE")
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    title:SetText("Coffer")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetSize(20, 20)
    closeButton:SetPoint("TOPRIGHT", -4, -4)
    closeButton:SetScript("OnClick", function() frame:Hide() end)

    local cursor = frame:CreateTexture(nil, "ARTWORK") -- anchor placeholder
    cursor:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -10)
    cursor:SetSize(1, 1)
    frame.cursor = cursor

    -- gold per hour
    local gphRow, gphVal = CreateLabelRow(frame, "Gold per hour", MUTED, 16)
    SetFont(gphVal, 16, GOLD, "")
    gphRow:SetPoint("TOPLEFT", cursor, "BOTTOMLEFT", 0, 0)
    gphValue = gphVal

    local goldRow, goldVal = CreateLabelRow(frame, "Your gold", MUTED)
    goldRow:SetPoint("TOPLEFT", gphRow, "BOTTOMLEFT", 0, -6)
    goldValue = goldVal

    -- session section
    local session = CreateSection(frame, "This Session")
    session.header:SetPoint("TOPLEFT", goldRow, "BOTTOMLEFT", 0, -14)

    local resetButton = CreateFrame("Button", nil, frame)
    resetButton:SetSize(40, 14)
    resetButton:SetPoint("RIGHT", session.header, "RIGHT", 0, 0)
    local resetText = resetButton:CreateFontString(nil, "OVERLAY")
    SetFont(resetText, 10, MUTED)
    resetText:SetPoint("CENTER")
    resetText:SetText("reset")
    resetButton:SetScript("OnEnter", function() SetFont(resetText, 10, GOLD) end)
    resetButton:SetScript("OnLeave", function() SetFont(resetText, 10, MUTED) end)
    resetButton:SetScript("OnClick", function()
        StaticPopup_Show and StaticPopup_Show("COFFER_CONFIRM_RESET")
        if not StaticPopup_Show then Coffer:ResetSession() end
    end)

    local durRow, durVal = CreateLabelRow(frame, "Duration", MUTED)
    durRow:SetPoint("TOPLEFT", session.header, "BOTTOMLEFT", 0, -2)
    durationValue = durVal

    local earnedRow, earnedVal = CreateLabelRow(frame, "Earned", MUTED)
    earnedRow:SetPoint("TOPLEFT", durRow, "BOTTOMLEFT", 0, -2)
    earnedValue = earnedVal

    local spentRow, spentVal = CreateLabelRow(frame, "Spent", MUTED)
    spentRow:SetPoint("TOPLEFT", earnedRow, "BOTTOMLEFT", 0, -2)
    spentValue = spentVal

    local netRow, netVal = CreateLabelRow(frame, "Total", MUTED)
    netRow:SetPoint("TOPLEFT", spentRow, "BOTTOMLEFT", 0, -2)
    netValue = netVal
    session.body = { durRow, earnedRow, spentRow, netRow }
    session.bottom = netRow

    -- items section
    itemsSection = CreateSection(frame, "Items")
    itemsSection.header:SetPoint("TOPLEFT", session.bottom, "BOTTOMLEFT", 0, -14)
    itemsSection.more = frame:CreateFontString(nil, "OVERLAY")
    SetFont(itemsSection.more, 10, MUTED)
    itemsSection.more:SetPoint("LEFT", 0, 0)

    -- runs section
    runsSection = CreateSection(frame, "Recent Runs")
    runsSection.more = frame:CreateFontString(nil, "OVERLAY")
    SetFont(runsSection.more, 10, MUTED)
    runsSection.more:SetPoint("LEFT", 0, 0)

    frame.sessionSection = session
    if Coffer.db.settings.point then
        local point, relPoint, x, y = unpack(Coffer.db.settings.point)
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relPoint, x, y)
    end

    -- Normalize to a TOPLEFT anchor so later SetHeight calls (as content grows or
    -- shrinks) only move the bottom edge, never the top, regardless of which corner
    -- the frame happened to be anchored from above.
    frame:SetHeight(1)
    local left, top = frame:GetLeft(), frame:GetTop()
    if left and top then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end

    frame:SetScript("OnShow", function()
        if not ticker then
            ticker = C_Timer.NewTicker(2, function() Coffer:RefreshUI() end)
        end
    end)
    frame:SetScript("OnHide", function()
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
    end)
end

local function SortedItems()
    local list = {}
    for itemID, entry in pairs(Coffer.db.session.items) do
        list[#list + 1] = { itemID = itemID, entry = entry }
    end
    table.sort(list, function(a, b)
        return (a.entry.value or 0) * a.entry.count > (b.entry.value or 0) * b.entry.count
    end)
    return list
end

local function LayoutItems(anchor)
    itemsSection.header:ClearAllPoints()
    itemsSection.header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
    local cursor = itemsSection.header

    if not itemsSection.collapsed then
        local list = SortedItems()
        for i = 1, math.min(#list, MAX_VISIBLE_ITEMS) do
            local data = list[i]
            local row = AcquireRow(itemRows, frame)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", cursor, "BOTTOMLEFT", 0, -2)
            row.icon:SetTexture(GetItemIcon and GetItemIcon(data.itemID) or 134400)
            local name, _, quality = GetItemInfo(data.itemID)
            local r, g, b = Coffer:GetQualityColor(quality)
            row.name:SetTextColor(r, g, b)
            row.name:SetText((name or ("item:" .. data.itemID)) .. (data.entry.count > 1 and ("  x" .. data.entry.count) or ""))
            row.name:SetWidth(PANEL_WIDTH - PADDING * 2 - 60)
            if data.entry.value then
                row.value:SetText(Coffer:FormatGold(data.entry.value * data.entry.count) .. "g")
            else
                row.value:SetText("...")
            end
            cursor = row
        end
        ReleaseUnused(itemRows)

        if #list > MAX_VISIBLE_ITEMS then
            itemsSection.more:ClearAllPoints()
            itemsSection.more:SetPoint("TOPLEFT", cursor, "BOTTOMLEFT", 19, -2)
            itemsSection.more:SetText("and " .. (#list - MAX_VISIBLE_ITEMS) .. " more")
            itemsSection.more:Show()
            cursor = itemsSection.more
        else
            itemsSection.more:Hide()
        end
    else
        ReleaseUnused(itemRows)
        itemsSection.more:Hide()
    end

    return cursor
end

local function LayoutRuns(anchor)
    runsSection.header:ClearAllPoints()
    runsSection.header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
    local cursor = runsSection.header

    if not runsSection.collapsed then
        local runs = Coffer.db.runs
        for i = 1, math.min(#runs, MAX_VISIBLE_RUNS) do
            local run = runs[i]
            local row = AcquireRow(runRows, frame)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", cursor, "BOTTOMLEFT", 0, -2)
            row.icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
            row.name:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
            row.name:SetText(Coffer:FormatDuration(run.duration) .. "  " .. (run.name or "Unknown"))
            row.name:SetWidth(PANEL_WIDTH - PADDING * 2 - 60)
            local net = run.loot + run.quest + run.vendor - run.spent
            local color = net >= 0 and GREEN or RED
            row.value:SetText(Coffer:FormatSigned(net) .. "g")
            row.value:SetTextColor(color[1], color[2], color[3])
            cursor = row
        end
        ReleaseUnused(runRows)

        if #runs > MAX_VISIBLE_RUNS then
            runsSection.more:ClearAllPoints()
            runsSection.more:SetPoint("TOPLEFT", cursor, "BOTTOMLEFT", 19, -2)
            runsSection.more:SetText(#runs .. " runs")
            runsSection.more:Show()
            cursor = runsSection.more
        else
            runsSection.more:Hide()
        end
    else
        ReleaseUnused(runRows)
        runsSection.more:Hide()
    end

    return cursor
end

function Coffer:RefreshUI()
    if not frame or not frame:IsShown() or not self.db then return end

    gphValue:SetText(self:FormatGold(self:GetGoldPerHour()) .. "g/hr")
    goldValue:SetText(self:FormatMoney(GetMoney()))

    durationValue:SetText(self:FormatDuration(self:GetSessionDuration()))
    earnedValue:SetText("+" .. self:FormatGold(self:GetSessionEarned()))
    earnedValue:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
    spentValue:SetText("-" .. self:FormatGold(self.db.session.spent))
    spentValue:SetTextColor(RED[1], RED[2], RED[3])
    local net = self:GetSessionNet()
    netValue:SetText(self:FormatSigned(net))
    local netColor = net >= 0 and GREEN or RED
    netValue:SetTextColor(netColor[1], netColor[2], netColor[3])

    for _, row in ipairs(frame.sessionSection.body) do
        row:SetShown(not frame.sessionSection.collapsed)
    end

    local afterSession = frame.sessionSection.collapsed and frame.sessionSection.header or frame.sessionSection.bottom
    local afterItems = LayoutItems(afterSession)
    local afterRuns = LayoutRuns(afterItems)

    -- Height from top of frame down to the bottom-most visible element, plus padding.
    local top = frame:GetTop()
    local bottom = afterRuns:GetBottom()
    if top and bottom then
        frame:SetHeight((top - bottom) + PADDING)
    end
end

function Coffer:ToggleFrame()
    if not frame then
        BuildFrame()
    end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:RefreshUI()
    end
end

if StaticPopupDialogs then
    StaticPopupDialogs["COFFER_CONFIRM_RESET"] = {
        text = "Reset Coffer's current session? Recent run history is kept.",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Coffer:ResetSession() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
end

Coffer:RegisterCallback("MoneyChanged", function() Coffer:RefreshUI() end)
Coffer:RegisterCallback("ItemsChanged", function() Coffer:RefreshUI() end)
Coffer:RegisterCallback("RunsChanged", function() Coffer:RefreshUI() end)
Coffer:RegisterCallback("ActiveRunChanged", function() Coffer:RefreshUI() end)
Coffer:RegisterCallback("SessionReset", function() Coffer:RefreshUI() end)

Coffer:OnReady(function()
    Coffer:ToggleFrame()
end)
