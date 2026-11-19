local addonName, Coffer = ...
_G.Coffer = Coffer

Coffer.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(addonName, "Version") or "dev"

-- session: the running totals since the player last reset tracking (persists across logout/relog)
-- runs: finished dungeon runs, most recent first
-- settings: UI state
local DEFAULTS = {
    session = { startTime = nil, loot = 0, quest = 0, vendor = 0, spent = 0, items = {} },
    runs = {},
    settings = { point = nil, locked = false },
}

local function ApplyDefaults(defaults, target)
    target = target or {}
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = ApplyDefaults(value, target[key])
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

local eventFrame = CreateFrame("Frame")
Coffer.handlers = {}

function Coffer:On(event, fn)
    self.handlers[event] = self.handlers[event] or {}
    table.insert(self.handlers[event], fn)
    eventFrame:RegisterEvent(event)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = Coffer.handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        fn(Coffer, event, ...)
    end
end)

Coffer.callbacks = {}

function Coffer:RegisterCallback(name, fn)
    self.callbacks[name] = self.callbacks[name] or {}
    table.insert(self.callbacks[name], fn)
end

local function Fire(name, ...)
    local list = Coffer.callbacks[name]
    if not list then return end
    for _, fn in ipairs(list) do
        fn(...)
    end
end

function Coffer:NotifyMoneyChanged() Fire("MoneyChanged") end
function Coffer:NotifyItemsChanged() Fire("ItemsChanged") end
function Coffer:NotifyRunsChanged() Fire("RunsChanged") end
function Coffer:NotifyActiveRunChanged() Fire("ActiveRunChanged") end
function Coffer:NotifySessionReset() Fire("SessionReset") end

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
    CofferDB = ApplyDefaults(DEFAULTS, CofferDB)
    self.db = CofferDB
    if not self.db.session.startTime then
        self.db.session.startTime = time()
    end
    for _, fn in ipairs(self.readyCallbacks) do
        fn(self)
    end
    self.readyCallbacks = {}
end)

-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------

function Coffer:FormatMoney(copper)
    copper = math.floor(math.abs(copper or 0))
    if GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local bronze = copper % 100
    return string.format("%dg %ds %dc", gold, silver, bronze)
end

function Coffer:FormatGold(copper)
    return math.floor(math.abs(copper or 0) / 10000)
end

function Coffer:FormatSigned(copper)
    copper = copper or 0
    local sign = copper < 0 and "-" or "+"
    return sign .. self:FormatGold(copper)
end

function Coffer:FormatDuration(seconds)
    seconds = math.floor(seconds or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %02dm", hours, minutes)
    end
    local secs = seconds % 60
    return string.format("%dm %02ds", minutes, secs)
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

SLASH_COFFER1 = "/coffer"
SlashCmdList["COFFER"] = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "reset" then
        Coffer:ResetSession()
        print("|cffffd200Coffer:|r Session reset.")
    elseif msg == "lock" then
        Coffer.db.settings.locked = true
        print("|cffffd200Coffer:|r Frame locked.")
    elseif msg == "unlock" then
        Coffer.db.settings.locked = false
        print("|cffffd200Coffer:|r Frame unlocked.")
    else
        Coffer:ToggleFrame()
    end
end
