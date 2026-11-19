local addonName, Coffer = ...
_G.Coffer = Coffer

-- Never let this throw: if neither API exists, Coffer.VERSION just stays "dev" instead
-- of a hard Lua error on load that would silently kill every file after this one,
-- including the slash command registration at the bottom of this file.
Coffer.VERSION = "dev"
if C_AddOns and C_AddOns.GetAddOnMetadata then
    Coffer.VERSION = C_AddOns.GetAddOnMetadata(addonName, "Version") or Coffer.VERSION
elseif GetAddOnMetadata then
    Coffer.VERSION = GetAddOnMetadata(addonName, "Version") or Coffer.VERSION
end

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

    -- A visible sign the addon actually loaded at all. If you don't see this line in
    -- chat after logging in, Coffer never loaded (wrong AddOns folder, addon unchecked
    -- at character select, or it's flagged out-of-date) — that's a different problem
    -- than anything inside the addon itself. Run /coffer debug for more detail.
    print(("|cffffd200Coffer|r v%s loaded. Type /coffer to open it, or /coffer debug if something looks wrong."):format(self.VERSION))
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

local function CountKeys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function PrintDebug()
    local build, buildNum, buildDate, tocVersion = GetBuildInfo()
    print("|cffffd200Coffer debug|r")
    print("  Addon version: " .. tostring(Coffer.VERSION))
    print("  Client build: " .. tostring(build) .. "  (interface " .. tostring(tocVersion) .. ")")
    print("  Coffer.toc declares interface: 16001 - if that doesn't match the line above, update Coffer.toc")
    print("  SavedVariables loaded: " .. tostring(Coffer.db ~= nil))
    if Coffer.db then
        print("  Session started: " .. tostring(Coffer.db.session.startTime ~= nil))
        print("  Items tracked this session: " .. CountKeys(Coffer.db.session.items))
        print("  Runs recorded: " .. #Coffer.db.runs)
    end
    local f = _G.CofferFrame
    print("  Panel frame built: " .. tostring(f ~= nil))
    if f then
        print("  Panel shown: " .. tostring(f:IsShown()))
    end
    print("  If you see this message at all, Coffer IS loaded and running - /coffer not")
    print("  opening the panel would then be a display bug, not a load failure. If you")
    print("  never see this after typing /coffer debug, Coffer never loaded: check the")
    print("  AddOns list at character select (is it checked? flagged out-of-date?) and")
    print("  that the folder is World of Warcraft\\_forever_\\Interface\\AddOns\\Coffer.")
end

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
    elseif msg == "debug" then
        PrintDebug()
    else
        Coffer:ToggleFrame()
    end
end
