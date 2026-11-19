-- Minimal mock of the WoW client Lua environment, just enough surface area to load
-- and exercise Coffer's addon files end-to-end outside the game, to catch runtime
-- errors (not just syntax errors) before shipping.

local Widget = {}
Widget.__index = Widget

-- Real WoW does not resolve a frame's actual on-screen geometry synchronously the
-- instant SetPoint() is called: Get{Top,Bottom,Left,Right}() can return nil until a
-- layout pass has run, which happens on the next rendered frame, not mid-script. This
-- bit Coffer for real (a panel that built and showed successfully but got stuck at
-- height 0 because a geometry read right after anchoring it silently returned nil) and
-- wasn't caught by this harness because the mock always returned a plausible number.
-- Modeling that: SetPoint/ClearAllPoints mark a widget "dirty" (geometry unresolved)
-- until __FlushLayout() runs, which simulates "a frame has now rendered."
local allWidgets = {}

local function NewWidget(kind)
    local w = setmetatable({ kind = kind, shown = true, scripts = {}, points = {}, dirty = true }, Widget)
    table.insert(allWidgets, w)
    return w
end

function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:SetWidth(w) self.width = w end
function Widget:SetHeight(h) self.height = h end
function Widget:GetWidth() return self.width or 100 end
function Widget:GetHeight() return self.height or 20 end
function Widget:SetPoint(...) table.insert(self.points, { ... }); self.dirty = true end
function Widget:ClearAllPoints() self.points = {}; self.dirty = true end
function Widget:GetPoint()
    local p = self.points[#self.points]
    if not p then return "CENTER", nil, "CENTER", 0, 0 end
    return p[1], p[2], p[3] or p[2], p[4] or 0, p[5] or 0
end
function Widget:GetLeft() if self.dirty then return nil end return 100 end
function Widget:GetRight() if self.dirty then return nil end return 380 end
function Widget:GetTop() if self.dirty then return nil end return 500 end
function Widget:GetBottom() if self.dirty then return nil end return self:GetTop() - (self.height or 20) end
function Widget:SetMovable() end
function Widget:EnableMouse() end
function Widget:EnableMouseWheel() end
function Widget:RegisterForDrag() end
function Widget:SetClampedToScreen() end
function Widget:SetFrameStrata(s) self.strata = s end
function Widget:GetFrameStrata() return self.strata or "MEDIUM" end
function Widget:SetAlpha(a) self.alpha = a end
function Widget:GetAlpha() return self.alpha or 1 end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:IsShown() return self.shown end
function Widget:IsVisible() return self.shown end
function Widget:SetShown(v) self.shown = v end
function Widget:SetScript(name, fn) self.scripts[name] = fn end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:Fire(name, ...)
    if self.scripts[name] then return self.scripts[name](self, ...) end
end
function Widget:StartMoving() end
function Widget:StopMovingOrSizing() end
function Widget:SetMultiLine() end
function Widget:SetAutoFocus() end
function Widget:SetFocus() end
function Widget:HighlightText() end
function Widget:SetFontObject() end
function Widget:SetScrollChild(c) self.scrollChild = c end
function Widget:GetVerticalScroll() return self.vscroll or 0 end
function Widget:SetVerticalScroll(v) self.vscroll = v end
function Widget:SetJustifyH() end
function Widget:SetAllPoints() end
function Widget:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function Widget:SetTexture(t) self.texture = t end
function Widget:SetFont(f, size, flags) self.font = { f, size, flags } end
function Widget:SetTextColor(r, g, b) self.textColor = { r, g, b } end
function Widget:SetText(t) self.text = t end
function Widget:GetText() return self.text end
function Widget:CreateTexture(name, layer) return NewWidget("Texture") end
function Widget:CreateFontString(name, layer) return NewWidget("FontString") end
function Widget:RegisterEvent(e) self.events = self.events or {}; self.events[e] = true end

_G.CreateFrame = function(kind, name, parent, template)
    local w = NewWidget(kind)
    if name then _G[name] = w end
    return w
end

_G.UIParent = NewWidget("Frame")
_G.UIParent.dirty = false -- the root frame is always already on screen
_G.ITEM_QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62 },
    [1] = { r = 1, g = 1, b = 1 },
    [2] = { r = 0.12, g = 1, b = 0 },
    [3] = { r = 0, g = 0.44, b = 0.87 },
    [4] = { r = 0.64, g = 0.21, b = 0.93 },
    [5] = { r = 1, g = 0.5, b = 0 },
}
_G.GameFontNormal = {}
_G.ChatFontNormal = {}
_G.StaticPopupDialogs = {}
_G.SlashCmdList = {}

_G.C_AddOns = { GetAddOnMetadata = function(name, field) return "0.0.0-mock" end }
_G.GetAddOnMetadata = _G.C_AddOns.GetAddOnMetadata

local fakeMoney = 500000
_G.GetMoney = function() return fakeMoney end
_G.GetCoinTextureString = function(c) return tostring(c) .. "c" end

_G.GetBuildInfo = function() return "1.60.1", "99999", "Jan 1 2026", 16001 end

_G.UnitName = function(unit) return "TestPlayer" end

_G.GetItemInfo = function(itemID)
    return "Test Item " .. tostring(itemID), "itemlink", 2, 1, 1, "Misc", "Junk", 1, "", 134400, 12, 0, 0, 1, 0, 0, false
end
_G.GetItemIcon = function(itemID) return 134400 end

_G.Item = {
    CreateFromItemID = function(self, itemID)
        local obj = { itemID = itemID }
        function obj:ContinueOnItemLoad(cb) cb() end
        return obj
    end,
}

_G.IsInInstance = function() return false, "none" end
_G.GetInstanceInfo = function() return "Mock Instance", "party", 1, "Normal", 5, 0, false, 12345, 5, 0 end

-- Genuinely deferred (not invoked here), matching real WoW: a 0-second C_Timer.After
-- still waits for the next frame, it doesn't run synchronously. __FlushLayout() below
-- runs these, simulating that next frame actually happening.
local pendingAfters = {}
local timers = {}
_G.C_Timer = {
    After = function(delay, fn) table.insert(pendingAfters, fn) end,
    NewTimer = function(delay, fn)
        local t = { Cancel = function() end }
        table.insert(timers, fn)
        return t
    end,
    NewTicker = function(interval, fn)
        return { Cancel = function() end }
    end,
}

-- Test-only helper (not part of the real WoW API): simulates "a frame has now been
-- rendered" by clearing every widget's dirty flag, then runs whatever C_Timer.After
-- callbacks were queued (in registration order) - matching a 0-second deferred call
-- actually firing on the next frame, after layout has settled.
function _G.__FlushLayout()
    for _, w in ipairs(allWidgets) do
        w.dirty = false
    end
    local toRun = pendingAfters
    pendingAfters = {}
    for _, fn in ipairs(toRun) do
        fn()
    end
end

_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local fakeClock = os.time()
_G.time = function() return fakeClock end
_G.date = os.date
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

-- ---------------------------------------------------------------------------
-- Load the addon's files in TOC order, each receiving (addonName, Coffer) via `...`
-- exactly like the real client passes it.
-- ---------------------------------------------------------------------------

local files = {
    "Core.lua", "ItemValue.lua", "Money.lua", "Loot.lua", "Runs.lua", "UI.lua",
}

local addonDir = ...
local Coffer = {}

for _, f in ipairs(files) do
    local path = addonDir .. "/" .. f
    local chunk, err = loadfile(path)
    if not chunk then
        print("LOAD ERROR in " .. f .. ": " .. tostring(err))
        os.exit(1)
    end
    local ok, runErr = pcall(chunk, "Coffer", Coffer)
    if not ok then
        print("RUNTIME ERROR while loading " .. f .. ": " .. tostring(runErr))
        os.exit(1)
    end
    print("Loaded " .. f .. " OK")
end

-- Fire ADDON_LOADED for "Coffer"
local function FireEvent(event, ...)
    local list = Coffer.handlers and Coffer.handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, Coffer, event, ...)
        if not ok then
            print("EVENT ERROR (" .. event .. "): " .. tostring(err))
            os.exit(1)
        end
    end
end

FireEvent("ADDON_LOADED", "Coffer")
print("ADDON_LOADED fired OK")

local function assertEqual(label, actual, expected)
    if actual ~= expected then
        print("ASSERTION FAILED: " .. label .. " -- expected " .. tostring(expected) .. ", got " .. tostring(actual))
        os.exit(1)
    end
    print("ASSERT OK: " .. label .. " == " .. tostring(actual))
end

-- Simulate plain /coffer (should build + show the panel)
local ok, err = pcall(function() SlashCmdList["COFFER"]("") end)
if not ok then
    print("SLASH /coffer ERROR: " .. tostring(err))
    os.exit(1)
end
print("/coffer (toggle) OK -- panel exists: " .. tostring(_G.CofferFrame ~= nil) .. ", shown: " .. tostring(_G.CofferFrame and _G.CofferFrame:IsShown()))

-- This is the exact bug found from the user's real debug output: geometry read in the
-- same script execution that just built/anchored the panel must come back unresolved
-- (nil/never-set), and the deferred C_Timer.After callback that fixes it must still be
-- sitting queued, not yet run.
assertEqual("frame height NOT YET set (still queued in a deferred callback)", _G.CofferFrame.height, nil)
assertEqual("frame top NOT YET resolved (geometry unresolved before layout)", _G.CofferFrame:GetTop(), nil)

__FlushLayout() -- simulate the next rendered frame actually happening

assertEqual("frame top resolves after a simulated layout pass", _G.CofferFrame:GetTop() ~= nil, true)
assertEqual("frame height gets set once geometry resolves", _G.CofferFrame.height ~= nil, true)
if _G.CofferFrame.height <= 1 then
    print("ASSERTION FAILED: frame height is still collapsed (<=1px) after layout settled")
    os.exit(1)
end
print("ASSERT OK: frame height is a real, non-collapsed value (" .. tostring(_G.CofferFrame.height) .. "px)")

-- Simulate /coffer debug
local ok2, err2 = pcall(function() SlashCmdList["COFFER"]("debug") end)
if not ok2 then
    print("SLASH /coffer debug ERROR: " .. tostring(err2))
    os.exit(1)
end
__FlushLayout()
print("/coffer debug OK -- debug window shown: " .. tostring(_G.CofferDebugFrame and _G.CofferDebugFrame:IsShown()))

-- Simulate looting an item (CHAT_MSG_LOOT) as the player
fakeMoney = fakeMoney + 1234
FireEvent("PLAYER_MONEY")
FireEvent("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:2589::::::::1:0:0:0:0|h[Linen Cloth]|h|rx3.", "TestPlayer")
assertEqual("own loot item count tracked", Coffer.db.session.items[2589] and Coffer.db.session.items[2589].count, 3)
assertEqual("own loot money bucket (loot)", Coffer.db.session.loot, 1234)

-- Simulate someone else's loot in the same channel (must NOT be counted - this is the
-- party-loot bug found from the user's real chat log)
FireEvent("CHAT_MSG_LOOT", "SomeoneElse receives loot: |cffffffff|Hitem:2592::::::::1:0:0:0:0|h[Wool Cloth]|h|r.", "SomeoneElse")
assertEqual("other player's loot NOT tracked", Coffer.db.session.items[2592], nil)

-- Simulate a quest turn-in with money reward
FireEvent("QUEST_TURNED_IN", 1234, 500, 5000)
fakeMoney = fakeMoney + 5000
FireEvent("PLAYER_MONEY")
assertEqual("quest money bucket", Coffer.db.session.quest, 5000)

-- Simulate entering then leaving a dungeon instance, with the fake clock advanced past
-- the 15s minimum run duration so this exercises the "record a finished run" path too.
_G.IsInInstance = function() return true, "party" end
FireEvent("PLAYER_ENTERING_WORLD")
assertEqual("active run starts on instance entry", Coffer:GetActiveRun() ~= nil, true)

fakeMoney = fakeMoney + 777
FireEvent("PLAYER_MONEY")
assertEqual("active run tracks loot income", Coffer:GetActiveRun().loot, 777)

fakeClock = fakeClock + 90
_G.IsInInstance = function() return false, "none" end
FireEvent("ZONE_CHANGED_NEW_AREA")
assertEqual("active run cleared on instance exit", Coffer:GetActiveRun(), nil)
assertEqual("finished run recorded into history", #Coffer.db.runs, 1)
assertEqual("recorded run's duration", Coffer.db.runs[1].duration, 90)
assertEqual("recorded run's loot amount", Coffer.db.runs[1].loot, 777)

-- Force a few more UI refreshes/toggles to shake out anything state-dependent
Coffer:RefreshUI()
Coffer:ToggleFrame()
Coffer:ToggleFrame()
Coffer:ResetSession()
print("Final refresh/toggle/reset cycle OK")

print("")
print("ALL SIMULATED STEPS COMPLETED WITH NO ERRORS")
