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

-- Like FormatSigned, but at full silver/copper precision instead of rounding down to
-- whole gold. Used anywhere a single dungeon run's worth of money is shown: a run that
-- only dropped a few silver would otherwise always display as a misleading "+0".
function Coffer:FormatSignedMoney(copper)
    copper = copper or 0
    local sign = copper < 0 and "-" or "+"
    return sign .. self:FormatMoney(copper)
end

-- A small embedded gold-coin icon (the same texture GetCoinTextureString uses),
-- appended after a whole-gold amount. Used for the bigger aggregate numbers (gold/hour,
-- session totals, item values) where showing a coin icon per amount - as in the
-- reference design - matters more than silver/copper precision.
local GOLD_COIN_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"

function Coffer:FormatGoldIcon(copper)
    return self:FormatGold(copper) .. " " .. GOLD_COIN_ICON
end

function Coffer:FormatSignedGoldIcon(copper)
    copper = copper or 0
    local sign = copper < 0 and "-" or "+"
    return sign .. self:FormatGold(copper) .. " " .. GOLD_COIN_ICON
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

-- Everything is collected into `lines` (not just print()'d) and the whole body is
-- wrapped in pcall, then Coffer:ShowDebugText opens a dedicated copyable window with
-- whatever was collected - plus the crash message, if any - so this command always
-- produces a complete, capturable report no matter what goes wrong while gathering it.
-- Chat scrollback alone isn't trustworthy for this: heavy trade/party chat can bury or
-- obscure later lines with no way to tell whether you've seen the end of the output.
local function PrintDebug()
    local lines = {}
    local function out(s)
        print(s)
        table.insert(lines, s)
    end

    local ok, err = pcall(function()
        local build, buildNum, buildDate, tocVersion = GetBuildInfo()
        out("Coffer debug")
        out("  Addon version: " .. tostring(Coffer.VERSION))
        out("  Client build: " .. tostring(build) .. "  (interface " .. tostring(tocVersion) .. ")")
        out("  Coffer.toc declares interface: 16001 - if that doesn't match the line above, update Coffer.toc")
        out("  SavedVariables loaded: " .. tostring(Coffer.db ~= nil))
        if Coffer.db then
            out("  Session started: " .. tostring(Coffer.db.session.startTime ~= nil))
            out("  Items tracked this session: " .. CountKeys(Coffer.db.session.items))
            out("  Runs recorded: " .. #Coffer.db.runs)
        end
        local built = Coffer:ForceShowPanel()
        out("  Panel build+show attempt succeeded: " .. tostring(built))
        local geo = Coffer:GetPanelGeometry()
        if geo then
            out(("  Panel geometry: %.0fx%.0f, strata=%s, alpha=%s"):format(
                geo.width or -1, geo.height or -1, tostring(geo.strata), tostring(geo.alpha)))
            out("  Panel shown: " .. tostring(geo.shown) .. "   Panel actually visible on screen: " .. tostring(geo.visible))
            out("  (on-screen position left=" .. tostring(geo.left) .. " top=" .. tostring(geo.top) ..
                " - 'nil' here is a separate, harmless WoW quirk about reading geometry back into")
            out("  Lua, not an indication the panel isn't actually drawn at the right place on screen)")
            if geo.shown and not geo.visible then
                out("  NOTE: shown is true but visible is false - an ancestor frame is hidden; shouldn't happen for a UIParent-attached frame.")
            elseif geo.width and geo.width > 0 and (not geo.height or geo.height <= 1) then
                out("  NOTE: height looks collapsed (<=1px) - the panel exists but has no visible content area. This is the bug that was just fixed by computing height arithmetically instead of measuring it - if you still see this, something is still wrong.")
            end
        else
            out("  Panel frame could not be built at all.")
        end
        out("")
        out("END OF DEBUG OUTPUT (if you see this line, nothing crashed while gathering it)")
    end)

    if not ok then
        out("")
        out("CRASHED while gathering debug info: " .. tostring(err))
    end

    local fullText = table.concat(lines, "\n")
    if Coffer.ShowDebugText then
        Coffer:ShowDebugText(fullText)

        -- Height is now computed arithmetically and set synchronously (see UI.lua), so
        -- it should already be correct above, immediately. This re-check is just a
        -- belt-and-suspenders confirmation a moment later. left/top are deliberately
        -- NOT part of the "healthy" check: they reflect a separate, harmless WoW quirk
        -- about reading resolved screen position back into Lua, not whether the panel
        -- is actually drawn in the right place (the engine renders it regardless).
        C_Timer.After(0.3, function()
            local geo = Coffer:GetPanelGeometry()
            local extra = "\n\n(re-checked 0.3s later)\n"
            if geo then
                extra = extra .. ("  Panel geometry: %.0fx%.0f\n"):format(geo.width or -1, geo.height or -1)
                extra = extra .. "  Panel shown: " .. tostring(geo.shown) .. "   visible: " .. tostring(geo.visible)
                if geo.height and geo.height > 1 then
                    extra = extra .. "\n  Height looks healthy. If you still don't see the panel on screen, it may be"
                    extra = extra .. "\n  positioned off your visible screen area, or behind another window."
                else
                    extra = extra .. "\n  Height STILL looks collapsed - this needs more investigation, please report it."
                end
            else
                extra = extra .. "  Panel frame no longer exists."
            end
            Coffer:ShowDebugText(fullText .. extra)
        end)
    else
        print("|cffff0000Coffer:|r couldn't open the debug window (UI not loaded) - see the printed lines above instead.")
    end
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
