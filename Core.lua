local addonName, Coffer = ...
_G.Coffer = Coffer

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
Coffer.VERSION = (GetAddOnMetadata and GetAddOnMetadata(addonName, "Version")) or "dev"

-- ---------------------------------------------------------------------------
-- Saved data
-- ---------------------------------------------------------------------------

local SCHEMA = 2

-- CofferDB is per character: session totals, run history, panel settings.
-- session.duration is *online* seconds only (banked on logout/reload), so time spent
-- logged off never dilutes gold per hour.
local DEFAULTS = {
    schema = SCHEMA,
    session = { duration = 0, loot = 0, quest = 0, vendor = 0, spent = 0, kills = 0, items = {} },
    runs = {},
    settings = { locked = false, hidden = false, valuation = "auction", collapsed = {} },
}

-- CofferAccountDB is account-wide: instance lockouts are per account under Classic
-- rules, so alts must share the same counter.
local ACCOUNT_DEFAULTS = { lockouts = {} }

local function ApplyDefaults(defaults, target)
    if type(target) ~= "table" then target = {} end
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = ApplyDefaults(value, target[key])
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

-- Schema 1 timed sessions from a wall-clock start (offline time included) and counted
-- vendor sales as income; neither carries over meaningfully, so that session is
-- restarted. Run history is kept.
local function Migrate(db)
    if type(db) == "table" and (db.schema or 1) < SCHEMA then
        db.session = nil
        db.schema = SCHEMA
        Coffer.migratedSession = true
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
Coffer.handlers = {}
Coffer.unsupportedEvents = {}

-- Registers fn for event. Returns false if this client doesn't know the event (e.g.
-- COMBAT_LOG_EVENT_UNFILTERED, which addons may not register on Midnight-era clients)
-- instead of letting RegisterEvent's error abort the whole file.
function Coffer:On(event, fn)
    local list = self.handlers[event]
    if not list then
        list = {}
        self.handlers[event] = list
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
            self.unsupportedEvents[event] = true
        end
    end
    list[#list + 1] = fn
    return not self.unsupportedEvents[event]
end

local reportedErrors = {}

-- Prints each distinct error once, so a broken handler can't fail silently or spam.
function Coffer:ReportError(context, err)
    local key = tostring(context) .. ":" .. tostring(err)
    if reportedErrors[key] then return end
    reportedErrors[key] = true
    print(("|cffff5555Coffer error (%s):|r %s"):format(tostring(context), tostring(err)))
end

-- Each handler runs isolated: one failing handler can't stop the others for the same
-- event (an item-pricing error must never stop gold being counted).
eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = Coffer.handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], Coffer, event, ...)
        if not ok then
            Coffer:ReportError(event, err)
        end
    end
end)

-- Data changed: refresh the panel once on the next frame, however many changes landed
-- in this one (a loot burst can fire a dozen events back to back).
local refreshQueued = false
function Coffer:Changed()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        if Coffer.RefreshUI then
            Coffer:RefreshUI()
        end
    end)
end

Coffer.readyCallbacks = {}

function Coffer:OnReady(fn)
    if self.db then
        fn(self)
    else
        table.insert(self.readyCallbacks, fn)
    end
end

Coffer:On("ADDON_LOADED", function(self, _, loadedName)
    if loadedName ~= addonName then return end
    Migrate(CofferDB)
    CofferDB = ApplyDefaults(DEFAULTS, CofferDB)
    CofferAccountDB = ApplyDefaults(ACCOUNT_DEFAULTS, CofferAccountDB)
    self.db = CofferDB
    self.account = CofferAccountDB

    for _, fn in ipairs(self.readyCallbacks) do
        local ok, err = pcall(fn, self)
        if not ok then self:ReportError("startup", err) end
    end
    self.readyCallbacks = {}

    print(("|cffffd200Coffer|r v%s loaded. |cffaaaaaa/coffer to toggle, /coffer help for options.|r"):format(self.VERSION))
    if self.migratedSession then
        print("|cffffd200Coffer:|r session restarted for the new online-time tracking (run history kept).")
    end
end)

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local COIN = {
    gold = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t",
    silver = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t",
    copper = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t",
}

local function Round(n)
    return math.floor(math.abs(n or 0) + 0.5)
end

function Coffer:FormatNumber(n)
    local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (s:gsub("^,", ""))
end

-- Full precision with coin icons ("1,245g 32s 10c"); built by hand rather than with
-- GetCoinTextureString, which doesn't exist as a global on Forever.
function Coffer:FormatMoney(copper)
    copper = Round(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor(copper % 10000 / 100)
    local bronze = copper % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = self:FormatNumber(gold) .. COIN.gold end
    if silver > 0 then parts[#parts + 1] = silver .. COIN.silver end
    if bronze > 0 or #parts == 0 then parts[#parts + 1] = bronze .. COIN.copper end
    return table.concat(parts, " ")
end

-- Just the largest unit ("331g", "9s", "40c"), the way the reference panel shows row
-- values. Below 1 gold it switches unit instead of rounding to a misleading "0g".
function Coffer:FormatShort(copper)
    copper = Round(copper)
    if copper == 0 then return "-" end
    if copper >= 10000 then
        return self:FormatNumber(math.floor(copper / 10000)) .. COIN.gold
    elseif copper >= 100 then
        return math.floor(copper / 100) .. COIN.silver
    end
    return copper .. COIN.copper
end

function Coffer:FormatSignedShort(copper)
    if Round(copper) == 0 then return "-" end
    return ((copper or 0) < 0 and "-" or "+") .. self:FormatShort(copper)
end

function Coffer:FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if hours > 0 then
        return ("%dh %02dm"):format(hours, minutes)
    end
    return ("%dm %02ds"):format(minutes, seconds % 60)
end

function Coffer:GetQualityColor(quality)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
    if color then
        return color.r, color.g, color.b
    end
    return 1, 1, 1
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function CountKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Collected into a dedicated copyable window (not just chat, which heavy trade/party
-- traffic can bury) and pcall-wrapped, so it always produces a complete report.
local function PrintDebug()
    local lines = {}
    local function out(s) lines[#lines + 1] = s end

    local ok, err = pcall(function()
        local build, _, _, tocVersion = GetBuildInfo()
        out("Coffer " .. tostring(Coffer.VERSION))
        out("Client " .. tostring(build) .. " (interface " .. tostring(tocVersion) .. ")")
        out("")
        out("API: GetItemInfo via " .. ((C_Item and C_Item.GetItemInfo) and "C_Item" or (GetItemInfo and "global" or "MISSING")))
        out("API: secret values " .. (canaccessvalue and "present (guarded)" or "not used by this client"))
        local missing = {}
        for event in pairs(Coffer.unsupportedEvents) do missing[#missing + 1] = event end
        table.sort(missing)
        out("Events this client doesn't support: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
        out("")
        if Coffer.db then
            local s = Coffer.db.session
            out("Session online time: " .. Coffer:FormatDuration(Coffer:GetSessionDuration()))
            out(("Loot %d  Quest %d  Items %d  Spent %d  Vendor %d  (copper)"):format(
                s.loot, s.quest, Coffer:GetSessionItemsValue(), s.spent, s.vendor))
            out("Distinct items: " .. CountKeys(s.items) .. "   Kills: " .. s.kills)
            out("Item valuation: " .. Coffer.db.settings.valuation)
            out("Runs recorded: " .. #Coffer.db.runs .. "   Active run: " .. tostring(Coffer.db.activeRun and Coffer.db.activeRun.name))
        end
        if Coffer.GetLockoutStatus then
            local st = Coffer:GetLockoutStatus()
            out(("Instances: %d/%d this hour, %d/%d today"):format(st.hour, st.hourLimit, st.day, st.dayLimit))
        end
        out("")
        local built = Coffer:ForceShowPanel()
        local geo = Coffer:GetPanelGeometry()
        out("Panel built: " .. tostring(built) .. (geo and ("   size %.0fx%.0f   shown %s"):format(geo.width or -1, geo.height or -1, tostring(geo.shown)) or ""))
        out("")
        out("END OF DEBUG OUTPUT")
    end)
    if not ok then
        out("")
        out("CRASHED while gathering debug info: " .. tostring(err))
    end

    local text = table.concat(lines, "\n")
    if Coffer.ShowDebugText then
        Coffer:ShowDebugText(text)
    else
        print(text)
    end
end

local function Say(msg)
    print("|cffffd200Coffer:|r " .. msg)
end

local function PrintHelp()
    Say("commands")
    print("  /coffer - show or hide the panel")
    print("  /coffer reset - start a new session (run history is kept)")
    print("  /coffer lock | unlock - stop or allow dragging the panel")
    print("  /coffer value auction | vendor - how looted items are valued")
    print("  /coffer reprice - re-value this session's items (e.g. after an AH scan)")
    print("  /coffer clearruns - delete the recent runs history")
    print("  /coffer debug - diagnostics window")
end

SLASH_COFFER1 = "/coffer"
SlashCmdList["COFFER"] = function(msg)
    msg = strtrim((msg or ""):lower())
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "toggle" then
        Coffer:ToggleFrame()
    elseif cmd == "show" then
        Coffer:SetPanelShown(true)
    elseif cmd == "hide" then
        Coffer:SetPanelShown(false)
    elseif cmd == "reset" then
        Coffer:ResetSession()
        Say("session reset.")
    elseif cmd == "lock" or cmd == "unlock" then
        Coffer.db.settings.locked = (cmd == "lock")
        Say("panel " .. cmd .. "ed.")
    elseif cmd == "value" and (arg == "auction" or arg == "vendor") then
        Coffer:SetValuation(arg)
        Say("items now valued at " .. (arg == "auction" and "auction price (vendor price as the floor)." or "vendor price."))
    elseif cmd == "reprice" then
        Coffer:RepriceItems()
        Say("items re-valued.")
    elseif cmd == "clearruns" then
        Coffer:ClearRuns()
        Say("run history cleared.")
    elseif cmd == "debug" then
        PrintDebug()
    else
        PrintHelp()
    end
end
