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
local curRunDurationValue, curRunEarnedValue
local itemsSection, runsSection
local itemRows = {}
local runRows = {}
local ticker

-- Deliberately avoids the "BackdropTemplate" XML template: Forever's interface version
-- (1.60.x) follows Classic's numbering, not modern retail's, and that template's
-- availability can't be assumed. Built from plain textures instead, which every WoW
-- client version supports with zero dependency on named templates.
local function CreateBackdropFrame(parent, name)
    local f = CreateFrame("Frame", name, parent)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.05, 0.93)

    local function Edge(p1, p2, width, height)
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.5, 0.39, 0.14, 0.9)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if width then t:SetWidth(width) end
        if height then t:SetHeight(height) end
        return t
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)

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

    local section = { header = header, chevron = chevron, label = label, collapsed = false }
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

    -- Built manually (no "UIPanelCloseButton" template) for the same reason as
    -- CreateBackdropFrame above: don't assume a named template exists on this client.
    local closeButton = CreateFrame("Button", nil, frame)
    closeButton:SetSize(18, 18)
    closeButton:SetPoint("TOPRIGHT", -4, -4)
    local closeLabel = closeButton:CreateFontString(nil, "OVERLAY")
    SetFont(closeLabel, 13, MUTED)
    closeLabel:SetPoint("CENTER")
    closeLabel:SetText("x")
    closeButton:SetScript("OnEnter", function() SetFont(closeLabel, 13, GOLD) end)
    closeButton:SetScript("OnLeave", function() SetFont(closeLabel, 13, MUTED) end)
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
    frame.goldRow = goldRow

    -- current run section: only visible while inside a tracked (5-player) instance.
    -- Shows live duration and net gold earned since zoning in, separate from the
    -- all-time "This Session" total below it.
    local currentRun = CreateSection(frame, "Current Run")
    currentRun.header:SetPoint("TOPLEFT", goldRow, "BOTTOMLEFT", 0, -14) -- re-anchored every refresh

    local curDurRow, curDurVal = CreateLabelRow(frame, "Duration", MUTED)
    curDurRow:SetPoint("TOPLEFT", currentRun.header, "BOTTOMLEFT", 0, -2)
    curRunDurationValue = curDurVal

    local curEarnedRow, curEarnedVal = CreateLabelRow(frame, "Earned here", MUTED)
    curEarnedRow:SetPoint("TOPLEFT", curDurRow, "BOTTOMLEFT", 0, -2)
    curRunEarnedValue = curEarnedVal

    currentRun.body = { curDurRow, curEarnedRow }
    currentRun.bottom = curEarnedRow
    frame.currentRunSection = currentRun

    -- session section
    local session = CreateSection(frame, "This Session")
    session.header:SetPoint("TOPLEFT", currentRun.header, "BOTTOMLEFT", 0, -14) -- re-anchored every refresh

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

    -- Always anchor from TOPLEFT (restored position, or a fixed default) rather than
    -- CENTER, so later SetHeight calls - as content grows or shrinks - only move the
    -- bottom edge, never the top. Previously this computed a TOPLEFT equivalent from a
    -- CENTER anchor via GetLeft()/GetTop(); anchoring TOPLEFT directly is simpler and
    -- removes a dependency on those returning usable values at build time.
    frame:ClearAllPoints()
    if Coffer.db.settings.point then
        local point, relPoint, x, y = unpack(Coffer.db.settings.point)
        frame:SetPoint(point, UIParent, relPoint, x, y)
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 240, -200)
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

local function LayoutCurrentRun(anchor)
    local section = frame.currentRunSection
    local run = Coffer:GetActiveRun()

    if not run then
        section.header:Hide()
        for _, row in ipairs(section.body) do
            row:Hide()
        end
        return anchor
    end

    section.header:ClearAllPoints()
    section.header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
    section.header:Show()
    section.label:SetText(("CURRENT RUN \226\128\148 %s"):format((run.name or "Unknown"):upper()))

    local visible = not section.collapsed
    for _, row in ipairs(section.body) do
        row:SetShown(visible)
    end
    if not visible then
        return section.header
    end

    curRunDurationValue:SetText(Coffer:FormatDuration(time() - run.startTime))
    local net = run.loot + run.quest + run.vendor - run.spent
    local color = net >= 0 and GREEN or RED
    curRunEarnedValue:SetText(Coffer:FormatSigned(net))
    curRunEarnedValue:SetTextColor(color[1], color[2], color[3])

    return section.bottom
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

local function RefreshUIImpl()
    if not frame or not frame:IsShown() or not Coffer.db then return end

    gphValue:SetText(Coffer:FormatGold(Coffer:GetGoldPerHour()) .. "g/hr")
    goldValue:SetText(Coffer:FormatMoney(GetMoney()))

    durationValue:SetText(Coffer:FormatDuration(Coffer:GetSessionDuration()))
    earnedValue:SetText("+" .. Coffer:FormatGold(Coffer:GetSessionEarned()))
    earnedValue:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
    spentValue:SetText("-" .. Coffer:FormatGold(Coffer.db.session.spent))
    spentValue:SetTextColor(RED[1], RED[2], RED[3])
    local net = Coffer:GetSessionNet()
    netValue:SetText(Coffer:FormatSigned(net))
    local netColor = net >= 0 and GREEN or RED
    netValue:SetTextColor(netColor[1], netColor[2], netColor[3])

    for _, row in ipairs(frame.sessionSection.body) do
        row:SetShown(not frame.sessionSection.collapsed)
    end

    local afterCurrentRun = LayoutCurrentRun(frame.goldRow)
    frame.sessionSection.header:ClearAllPoints()
    frame.sessionSection.header:SetPoint("TOPLEFT", afterCurrentRun, "BOTTOMLEFT", 0, -14)

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

-- Every refresh (the 2s ticker, every money/loot/run event, manual toggles) goes
-- through this pcall wrapper, so a bug in the layout code prints a visible error once
-- instead of either silently doing nothing or, on the ticker, spamming the same error
-- every 2 seconds forever.
local lastUIError
function Coffer:RefreshUI()
    local ok, err = pcall(RefreshUIImpl)
    if not ok and err ~= lastUIError then
        lastUIError = err
        print("|cffff0000Coffer UI error:|r " .. tostring(err))
        print("|cffff0000Coffer:|r please report this error (and your /coffer debug output) so it can be fixed.")
    end
end

local function EnsureFrame()
    if frame then return true end
    local ok, err = pcall(BuildFrame)
    if not ok then
        print("|cffff0000Coffer failed to build its panel:|r " .. tostring(err))
        print("|cffff0000Coffer:|r please report this error (and your /coffer debug output) so it can be fixed.")
        return false
    end
    return true
end

function Coffer:ToggleFrame()
    if not EnsureFrame() then return end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:RefreshUI()
    end
end

-- Builds the panel if needed and always shows it (never toggles it closed). Used by
-- /coffer debug so running that command can never itself hide an already-open panel.
function Coffer:ForceShowPanel()
    if not EnsureFrame() then return false end
    frame:Show()
    self:RefreshUI()
    return true
end

function Coffer:GetPanelGeometry()
    if not frame then return nil end
    return {
        width = frame:GetWidth(),
        height = frame:GetHeight(),
        left = frame:GetLeft(),
        top = frame:GetTop(),
        shown = frame:IsShown(),
        visible = frame:IsVisible(),
        strata = frame:GetFrameStrata(),
        alpha = frame:GetAlpha(),
    }
end

-- A dedicated, scrollable, selectable text window for /coffer debug output. Chat
-- scrollback is unreliable for this: it can be buried by other chat traffic, and
-- there's no reliable way to know whether you've seen the end of the output or not.
-- This window always shows the complete text, independent of chat entirely.
local debugWindow
local function ShowDebugText(text)
    if not debugWindow then
        local f = CreateFrame("Frame", "CofferDebugFrame", UIParent)
        f:SetSize(520, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.06, 0.98)

        local titleText = f:CreateFontString(nil, "OVERLAY")
        SetFont(titleText, 13, GOLD, "OUTLINE")
        titleText:SetPoint("TOPLEFT", 12, -10)
        titleText:SetText("Coffer Debug - select all (Ctrl+A) and copy (Ctrl+C)")

        local closeBtn = CreateFrame("Button", nil, f)
        closeBtn:SetSize(20, 20)
        closeBtn:SetPoint("TOPRIGHT", -6, -6)
        local closeLbl = closeBtn:CreateFontString(nil, "OVERLAY")
        SetFont(closeLbl, 14, MUTED)
        closeLbl:SetPoint("CENTER")
        closeLbl:SetText("x")
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        local scrollFrame = CreateFrame("ScrollFrame", nil, f)
        scrollFrame:SetPoint("TOPLEFT", 12, -32)
        scrollFrame:SetPoint("BOTTOMRIGHT", -12, 12)
        scrollFrame:EnableMouseWheel(true)
        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            self:SetVerticalScroll(math.max(0, (self:GetVerticalScroll() or 0) - delta * 20))
        end)

        local editBox = CreateFrame("EditBox", nil, scrollFrame)
        editBox:SetMultiLine(true)
        editBox:SetFontObject(ChatFontNormal or GameFontNormal)
        editBox:SetWidth(480)
        editBox:SetAutoFocus(false)
        editBox:SetScript("OnEscapePressed", function() f:Hide() end)
        scrollFrame:SetScrollChild(editBox)

        f.editBox = editBox
        debugWindow = f
    end

    debugWindow.editBox:SetText(text)
    debugWindow.editBox:HighlightText()
    debugWindow.editBox:SetFocus()
    debugWindow:Show()
end
Coffer.ShowDebugText = function(self, text) ShowDebugText(text) end

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
