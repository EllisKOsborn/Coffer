-- A mock of the World of Warcraft: Forever client environment, strict enough to catch
-- the kinds of bugs that actually reached the game before:
--   * classic globals that don't exist on Forever (GetItemInfo, GetItemIcon,
--     GetCoinTextureString) are absent - only the C_* versions exist
--   * "secret" values (Midnight-era clients) are real, and reading one is an error
--   * COMBAT_LOG_EVENT_UNFILTERED can't be registered by addons
--   * a widget method that doesn't exist raises an error instead of silently working
--   * frame geometry (GetTop/GetBottom/...) is unreadable, as observed in-game
--   * any error Coffer reports through its own error handling fails the run
-- Then it plays through a full farming session and asserts on the numbers.

local addonDir = ...
local FILES = { "Compat.lua", "Core.lua", "ItemValue.lua", "Money.lua", "Loot.lua", "Sales.lua", "Lockouts.lua", "Runs.lua", "UI.lua" }

-- ---------------------------------------------------------------------------
-- Test plumbing
-- ---------------------------------------------------------------------------

local realPrint = print
local chatLog = {}
local passed = 0

_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, " ")
    chatLog[#chatLog + 1] = line
    if line:find("Coffer error", 1, true) then
        realPrint("FAIL: Coffer reported an error -> " .. line)
        os.exit(1)
    end
end

local function check(label, actual, expected)
    if actual ~= expected then
        realPrint(("FAIL: %s -- expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
    passed = passed + 1
    realPrint("  ok  " .. label)
end

local function section(name)
    realPrint("")
    realPrint("== " .. name)
end

-- ---------------------------------------------------------------------------
-- Secret values
-- ---------------------------------------------------------------------------

local SECRET = setmetatable({}, {
    __index = function() error("attempt to read a secret value") end,
    __tostring = function() return "<secret>" end,
})
_G.canaccessvalue = function(v) return v ~= SECRET end
_G.issecretvalue = function(v) return v == SECRET end
-- On the real client a secret string still has type "string" - only using it fails - so
-- a type() check alone must not be enough to make code pass here.
local realType = type
_G.type = function(v)
    if v == SECRET then return "string" end
    return realType(v)
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

local Widget = {}
local methods = {}
Widget.__index = function(self, key)
    local m = methods[key]
    if m then return m end
    if type(key) == "string" and key:match("^%u") then
        error("widget method doesn't exist: " .. key, 2)
    end
    return nil
end

local eventFrames = {}

local function NewWidget(kind, parent)
    local w = setmetatable({ kind = kind, shown = true, scripts = {}, children = {}, regions = {}, events = {} }, Widget)
    if parent then
        table.insert(parent.children, w)
    end
    return w
end

local function noop() end
for _, name in ipairs({
    "SetPoint", "ClearAllPoints", "SetFrameStrata", "SetMovable", "EnableMouse", "SetClampedToScreen",
    "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetTexCoord", "SetAllPoints", "SetWordWrap",
    "SetJustifyH", "RegisterForClicks", "EnableMouseWheel", "SetMultiLine", "SetFontObject",
    "SetAutoFocus", "HighlightText", "SetFocus", "SetAlpha",
}) do
    methods[name] = noop
end

function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetWidth(w) self.width = w end
function methods:SetHeight(h) self.height = h end
function methods:GetWidth() return self.width or 0 end
function methods:GetHeight() return self.height or 0 end
function methods:GetPoint() return "TOPLEFT", nil, "TOPLEFT", 240, -200 end
-- Unreadable from Lua, as the user's own /coffer debug output showed in-game.
function methods:GetTop() return nil end
function methods:GetBottom() return nil end
function methods:GetLeft() return nil end
-- Like the real client: frames start shown, and OnShow/OnHide fire only on an actual
-- change - so code that relies on OnShow after CreateFrame()+Show() is caught here.
function methods:Show()
    if self.shown then return end
    self.shown = true
    if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods:Hide()
    if not self.shown then return end
    self.shown = false
    if self.scripts.OnHide then self.scripts.OnHide(self) end
end
function methods:IsShown() return self.shown end
function methods:IsVisible() return self.shown end
function methods:SetShown(v) self.shown = v and true or false end
function methods:SetScript(name, fn) self.scripts[name] = fn end
function methods:GetScript(name) return self.scripts[name] end
function methods:CreateTexture() local t = NewWidget("Texture") table.insert(self.regions, t) return t end
function methods:CreateFontString() local t = NewWidget("FontString") table.insert(self.regions, t) return t end
function methods:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function methods:SetTexture(t) self.texture = t end
function methods:SetVertexColor(r, g, b) self.vertex = { r, g, b } end
function methods:SetFont(f, size, flags) self.font = { f, size, flags } end
function methods:SetTextColor(r, g, b) self.textColor = { r, g, b } end
function methods:SetText(t) self.text = t end
function methods:GetText() return self.text end
function methods:SetVerticalScroll(v) self.scroll = v end
function methods:GetVerticalScroll() return self.scroll or 0 end
function methods:SetScrollChild(c) self.scrollChild = c end
function methods:RegisterEvent(event)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        error("Frame:RegisterEvent(): COMBAT_LOG_EVENT_UNFILTERED is forbidden for addons")
    end
    if not self.registered then
        self.registered = true
        table.insert(eventFrames, self)
    end
    self.events[event] = true
end
-- tooltip
function methods:SetOwner(owner) self.owner = owner; self.lines = {} end
function methods:AddLine(text) table.insert(self.lines, tostring(text)) end
function methods:AddDoubleLine(l, r) table.insert(self.lines, tostring(l) .. " | " .. tostring(r)) end
function methods:SetHyperlink(link)
    if type(link) ~= "string" or not link:find("|H", 1, true) then error("bad hyperlink") end
    table.insert(self.lines, "link:" .. link)
end
function methods:SetItemByID(id) table.insert(self.lines, "item:" .. id) end

_G.CreateFrame = function(kind, name, parent)
    local w = NewWidget(kind, parent)
    if name then _G[name] = w end
    return w
end
_G.UIParent = NewWidget("Frame")
_G.GameTooltip = NewWidget("GameTooltip")
_G.GameTooltip.lines = {}

local function Fire(event, ...)
    for _, f in ipairs(eventFrames) do
        if f.events[event] and f.scripts.OnEvent then
            f.scripts.OnEvent(f, event, ...)
        end
    end
end

local function FindText(widget, text, depth)
    depth = depth or 0
    for _, r in ipairs(widget.regions) do
        if r.text == text then return widget end
    end
    for _, c in ipairs(widget.children) do
        local found = FindText(c, text, depth + 1)
        if found then return found end
    end
end

local function Click(widget, button)
    widget.scripts.OnClick(widget, button or "LeftButton")
end

-- ---------------------------------------------------------------------------
-- Game state and APIs
-- ---------------------------------------------------------------------------

local clock = 1700000000
_G.time = function() return clock end
_G.date = os.date
local function advance(seconds) clock = clock + seconds end

local money = 500000
_G.GetMoney = function() return money end

_G.GetBuildInfo = function() return "1.60.1", "70000", "Nov 1 2026", 16001 end
_G.UnitName = function() return "Kabann" end
_G.UnitGUID = function() return "Player-1-00000001" end
local dead = false
_G.UnitIsDeadOrGhost = function() return dead end

local where = { inInstance = false }
_G.IsInInstance = function()
    if where.inInstance then return true, where.type end
    return false, "none"
end
_G.GetInstanceInfo = function()
    if where.inInstance then
        return where.name, where.type, 1, "Normal", 5, 0, false, where.mapID, 5, 0
    end
    return "Burning Steppes", "none", 0, "", 5, 0, false, 46, 0, 0
end
local function enter(name, mapID) where = { inInstance = true, type = "party", name = name, mapID = mapID } end
local function leave() where = { inInstance = false } end

-- Items: everything is cached except item 9999, which loads asynchronously.
local uncached = { [9999] = true }
local pendingItemLoads = {}
_G.C_Item = {
    GetItemInfo = function(id)
        if type(id) ~= "number" then id = tonumber(tostring(id):match("item:(%d+)")) end
        if not id or uncached[id] then return nil end
        return "Item " .. id, "|cffffffff|Hitem:" .. id .. "|h[Item " .. id .. "]|h|r", id % 5,
            1, 1, "Misc", "Junk", 20, "", 134400, 12, 0, 0, 0, 0, 0, false
    end,
    GetItemIconByID = function() return 134400 end,
}
_G.Item = {
    CreateFromItemID = function(_, id)
        return { ContinueOnItemLoad = function(_, cb) table.insert(pendingItemLoads, { id = id, cb = cb }) end }
    end,
}
local function loadPendingItems()
    local list = pendingItemLoads
    pendingItemLoads = {}
    for _, p in ipairs(list) do
        uncached[p.id] = nil
        p.cb()
    end
end

_G.ITEM_QUALITY_COLORS = {}
for q = 0, 7 do ITEM_QUALITY_COLORS[q] = { r = 1, g = 1, b = 1 } end
_G.C_AddOns = { GetAddOnMetadata = function() return "0.0.0-test" end }
_G.Enum = { PlayerInteractionType = { TradePartner = 1, Merchant = 5, Banker = 8, GuildBanker = 10, MailInfo = 17, Auctioneer = 21 } }
_G.UISpecialFrames = {}
_G.StaticPopupDialogs = {}
_G.StaticPopup_Show = function(key) StaticPopupDialogs[key].OnAccept() end -- auto-confirm
_G.YES, _G.NO = "Yes", "No"
local shift = false
_G.IsShiftKeyDown = function() return shift end
local insertedLink
_G.ChatEdit_InsertLink = function(link) insertedLink = link end
local compartment
_G.AddonCompartmentFrame = { RegisterAddon = function(_, info) compartment = info end }
_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

-- Bags: one bag of 40 slots, item -> count
local bags = {}
local function bagList()
    local ids = {}
    for id in pairs(bags) do ids[#ids + 1] = id end
    table.sort(ids)
    local list = {}
    for _, id in ipairs(ids) do list[#list + 1] = { id = id, count = bags[id] } end
    return list
end
_G.NUM_BAG_SLOTS = 4
_G.C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 40 or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local e = bag == 0 and bagList()[slot]
        if e then return { itemID = e.id, stackCount = e.count } end
    end,
}
local function bagAdd(id, n) bags[id] = (bags[id] or 0) + n end
local function bagRemove(id, n)
    bags[id] = bags[id] - n
    if bags[id] <= 0 then bags[id] = nil end
end

-- Mailbox
local mails = {}
_G.GetInboxNumItems = function() return #mails, #mails end
_G.GetInboxHeaderInfo = function(i)
    local m = mails[i]
    if m then return nil, nil, m.sender, m.subject, m.money end
end
_G.GetInboxInvoiceInfo = function(i)
    local m = mails[i]
    if m and m.invoiceType then return m.invoiceType, m.itemName, "Buyer", 0, 0, 0, 0, 0, 0, m.count end
end

-- Functions addons hook. Reset on every load, as a /reload starts a fresh Lua state
-- with no hooks from before.
local function resetHookables()
    local function takeMoney(i)
        local m = mails[i]
        if m then money = money + m.money; m.money = 0 end
    end
    _G.TakeInboxMoney, _G.AutoLootMailItem = takeMoney, takeMoney
    _G.Logout, _G.Quit, _G.CancelLogout = function() end, function() end, function() end
end
_G.hooksecurefunc = function(name, hook)
    local original = _G[name]
    _G[name] = function(...)
        original(...)
        hook(...)
    end
end

-- Blizzard global strings (enUS)
_G.LOOT_ITEM_SELF = "You receive loot: %s."
_G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
_G.LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
_G.LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
_G.GOLD_AMOUNT = "%d Gold"
_G.SILVER_AMOUNT = "%d Silver"
_G.COPPER_AMOUNT = "%d Copper"
_G.INSTANCE_RESET_SUCCESS = "%s has been reset."
_G.INSTANCE_RESET_FAILED = "Cannot reset %s.  There are players still inside the instance."
_G.LOOT_ITEM_CREATED_SELF = "You create: %s."
_G.LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d."
_G.AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"

-- Forever doesn't have these as globals (C_Item / C_CurrencyInfo only).
_G.GetItemInfo = nil
_G.GetItemIcon = nil
_G.GetCoinTextureString = nil

-- Timers
local pendingAfters, tickers = {}, {}
_G.C_Timer = {
    After = function(_, fn) table.insert(pendingAfters, fn) end,
    NewTimer = function(_, fn) local t = { Cancel = noop } table.insert(pendingAfters, fn) return t end,
    NewTicker = function(_, fn)
        local t = { fn = fn }
        function t:Cancel() self.cancelled = true end
        table.insert(tickers, t)
        return t
    end,
}

-- Run deferred work, as the next rendered frame would.
local function flush()
    for _ = 1, 20 do
        if #pendingAfters == 0 then return end
        local list = pendingAfters
        pendingAfters = {}
        for _, fn in ipairs(list) do fn() end
    end
end

local function tick()
    for _, t in ipairs(tickers) do
        if not t.cancelled then t.fn() end
    end
    flush()
end

-- ---------------------------------------------------------------------------
-- Loading (and reloading) the addon
-- ---------------------------------------------------------------------------

local Coffer

-- A /reload or relog: frames and timers from the previous load are discarded,
-- SavedVariables (CofferDB / CofferAccountDB) carry over.
local function load()
    eventFrames, pendingAfters, tickers = {}, {}, {}
    resetHookables()
    _G.SlashCmdList = {}
    _G.CofferFrame, _G.CofferMenu, _G.CofferDebugFrame = nil, nil, nil
    Coffer = {}
    for _, file in ipairs(FILES) do
        local chunk, err = loadfile(addonDir .. "/" .. file)
        if not chunk then
            realPrint("FAIL: couldn't load " .. file .. ": " .. tostring(err))
            os.exit(1)
        end
        local ok, runErr = pcall(chunk, "Coffer", Coffer)
        if not ok then
            realPrint("FAIL: error running " .. file .. ": " .. tostring(runErr))
            os.exit(1)
        end
    end
    Fire("ADDON_LOADED", "Coffer")
    flush()
    Fire("PLAYER_ENTERING_WORLD", false, false)
    flush()
end

local function reload()
    Fire("PLAYER_LOGOUT")
    load()
end

local function slash(msg)
    SlashCmdList.COFFER(msg)
    flush()
end

local function setMoney(newValue)
    money = newValue
    Fire("PLAYER_MONEY")
    flush()
end

local function fire(event, ...)
    Fire(event, ...)
    flush()
end

-- Take a mail's gold: the client's hook-visible call, then the balance update the
-- server sends back afterwards.
local function collectMail(index)
    TakeInboxMoney(index)
    fire("PLAYER_MONEY")
end

local function link(id) return "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[Item " .. id .. "]|h|r" end

-- ===========================================================================
-- Scenario
-- ===========================================================================

section("Startup on a schema-1 save (migration)")
CofferDB = {
    session = { startTime = clock - 86400, loot = 999999, quest = 0, vendor = 50000, spent = 0, items = {} },
    runs = { { name = "Old Run", duration = 600, loot = 100, quest = 0, vendor = 0, spent = 0, items = {} } },
    settings = { point = nil, locked = false },
}
load()
check("Forever has no global GetItemInfo", _G.GetItemInfo, nil)
check("old session discarded", Coffer.db.session.loot, 0)
check("run history kept", Coffer.db.runs[1] and Coffer.db.runs[1].name, "Old Run")
check("schema upgraded", Coffer.db.schema, 3)
check("panel shown by default", CofferFrame and CofferFrame:IsShown(), true)
-- 40 top + 22 gph + 22 gold + 20 instances + 30 session header + 5 x 20 rows + 30 items
-- header + 16 empty note + 30 runs header + 20 one run row + 10 bottom
check("panel height computed without GetTop/GetBottom", CofferFrame:GetHeight(), 340)
check("addon compartment entry registered", compartment and compartment.text, "Coffer")
Coffer:ClearRuns()
flush()

section("Looted gold")
fire("CHAT_MSG_MONEY", "You loot 1 Gold, 23 Silver, 4 Copper.")
check("loot parsed from CHAT_MSG_MONEY", Coffer.db.session.loot, 12304)
setMoney(money + 12304)
check("matching PLAYER_MONEY not double counted", Coffer.db.session.loot, 12304)
fire("CHAT_MSG_MONEY", "Your share of the loot is 3 Silver, 13 Copper.")
check("'your share of the loot' parsed", Coffer.db.session.loot, 12617)
check("guild-bank deposit in parentheses ignored", Coffer:ParseMoney("You loot 2 Silver (1 Copper deposited to guild bank)."), 200)
fire("CHAT_MSG_MONEY", SECRET)
check("secret money message skipped without error", Coffer.db.session.loot, 12617)

section("Looted items")
fire("CHAT_MSG_LOOT", "You receive loot: " .. link(2589) .. "x3.")
check("own loot, stack", Coffer.db.session.items[2589].count, 3)
check("valued via C_Item (vendor 12c each)", Coffer.db.session.items[2589].value, 12)
fire("CHAT_MSG_LOOT", "You receive loot: " .. link(2590) .. ".")
check("own loot, single", Coffer.db.session.items[2590].count, 1)
fire("CHAT_MSG_LOOT", "You receive item: " .. link(2591) .. "x2.")
check("own loot, pushed", Coffer.db.session.items[2591].count, 2)
fire("CHAT_MSG_LOOT", "Jump High receives loot: " .. link(2592) .. "x2.")
check("party member's loot ignored", Coffer.db.session.items[2592], nil)
fire("CHAT_MSG_LOOT", "You receive loot: |cnIQ4:|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r.")
check("new-style |cnIQ link color handled", Coffer.db.session.items[19019] and Coffer.db.session.items[19019].count, 1)
fire("CHAT_MSG_LOOT", SECRET)
check("secret loot message skipped without error", Coffer.db.session.items[2593], nil)
fire("CHAT_MSG_LOOT", "You receive loot: " .. link(9999) .. ".")
check("uncached item counted immediately", Coffer.db.session.items[9999].count, 1)
check("...and valued once its data loads", Coffer.db.session.items[9999].value, nil)
loadPendingItems()
flush()
check("async item value arrived", Coffer.db.session.items[9999].value, 12)
-- 3 + 1 + 2 + 1 + 1 = 8 items at 12c
check("session items value", Coffer:GetSessionItemsValue(), 96)

section("Auction valuation (max of auction and vendor)")
_G.TSM_API = { GetCustomPriceValue = function(_, key)
    if key == "i:2589" then return 500 end
    if key == "i:2590" then return 5 end -- below vendor price
end }
slash("reprice")
check("auction price used when higher", Coffer.db.session.items[2589].value, 500)
check("source recorded", Coffer.db.session.items[2589].source, "auction")
check("never below vendor price", Coffer.db.session.items[2590].value, 12)
slash("value vendor")
check("vendor mode", Coffer.db.session.items[2589].value, 12)
slash("value auction")
check("back to auction mode", Coffer.db.session.items[2589].value, 500)
_G.TSM_API = nil
slash("reprice")

section("Quests, vendors, mail, trade")
fire("QUEST_TURNED_IN", 1234, 500, 5000)
setMoney(money + 5000)
check("quest gold from the event argument", Coffer.db.session.quest, 5000)
fire("QUEST_TURNED_IN", 1235, 500, SECRET)
check("secret quest reward skipped", Coffer.db.session.quest, 5000)
fire("MERCHANT_SHOW")
setMoney(money + 1000)
check("vendor sale counted as sold", Coffer:GetSessionSold(), 1000)
check("...separately from looted and quest gold", Coffer:GetSessionEarned(), 12617 + 5000)
setMoney(money - 300)
check("repair counted as spent", Coffer.db.session.spent, 300)
fire("MERCHANT_CLOSED")
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.MailInfo)
setMoney(money - 100000)
check("gold mailed to an alt isn't spending", Coffer.db.session.spent, 300)
fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.MailInfo)
fire("TRADE_SHOW")
setMoney(money - 5000)
check("gold traded away isn't spending", Coffer.db.session.spent, 300)
fire("TRADE_CLOSED")
setMoney(money - 200)
check("flight path counted as spent", Coffer.db.session.spent, 500)

section("Online time and gold per hour")
check("no rate in the first minute", Coffer:GetGoldPerHour(), nil)
advance(1800)
check("session time counts online time", Coffer:GetSessionDuration(), 1800)
local income = 12617 + 5000 + 1000 + 96
check("income = looted + quest + sold + items", Coffer:GetSessionIncome(), income)
check("gold per hour", math.floor(Coffer:GetGoldPerHour() + 0.5), income * 2)
check("total = income - spent", Coffer:GetSessionNet(), income - 500)
Fire("PLAYER_LOGOUT") -- log off...
advance(8 * 3600)     -- ...overnight...
load()                -- ...and back the next day
check("offline time excluded", Coffer:GetSessionDuration(), 1800)
advance(10)
tick()
check("panel refresh ticker is running (live durations)", (FindText(CofferFrame, "Gold per hour") ~= nil) and #tickers >= 2, true)
check("session totals survive a relog", Coffer.db.session.quest, 5000)

section("Purchases aren't loot")
fire("AUCTION_HOUSE_SHOW")
local spentBefore = Coffer.db.session.spent
setMoney(money - 490000)
check("auction house purchase counted as spent", Coffer.db.session.spent - spentBefore, 490000)
fire("AUCTION_HOUSE_CLOSED")
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.MailInfo)
fire("CHAT_MSG_LOOT", "You receive item: " .. link(4000) .. ".")
check("item collected from the mailbox (AH purchase) isn't loot", Coffer.db.session.items[4000], nil)
fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.MailInfo)
fire("MERCHANT_SHOW")
fire("CHAT_MSG_LOOT", "You receive item: " .. link(4001) .. "x5.")
check("item bought from a vendor isn't loot", Coffer.db.session.items[4001], nil)
fire("MERCHANT_CLOSED")
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Auctioneer)
fire("CHAT_MSG_LOOT", "You receive item: " .. link(4003) .. ".")
check("item received at the auction house isn't loot", Coffer.db.session.items[4003], nil)
fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.Auctioneer)
fire("MAIL_SHOW") -- and its close event never arrives
fire("LOOT_OPENED")
fire("CHAT_MSG_LOOT", "You receive loot: " .. link(4002) .. ".")
check("a missed close event can't block real loot", Coffer.db.session.items[4002] and Coffer.db.session.items[4002].count, 1)

section("Selling and crafting move value out of Items, never count it twice")
fire("CHAT_MSG_LOOT", "You receive loot: " .. link(5000) .. "x10.")
bagAdd(5000, 10)
fire("BAG_UPDATE_DELAYED")
check("10 looted, valued at 12c each", Coffer.db.session.items[5000].count * Coffer.db.session.items[5000].value, 120)
local itemsBefore, soldBefore = Coffer:GetSessionItemsValue(), Coffer:GetSessionSold()

fire("MERCHANT_SHOW")
bagRemove(5000, 4)
fire("BAG_UPDATE_DELAYED")
setMoney(money + 48)
check("vendor sale: sold items leave the tally", Coffer.db.session.items[5000].count, 6)
check("...and their sale gold counts", Coffer:GetSessionSold() - soldBefore, 48)
check("...so income moved, it didn't double", Coffer:GetSessionItemsValue(), itemsBefore - 48)
fire("MERCHANT_CLOSED")
bagRemove(5000, 1)
fire("BAG_UPDATE_DELAYED")
check("a sale landing just after the vendor closes still counts", Coffer.db.session.items[5000].count, 5)

advance(10)
fire("BANKFRAME_OPENED")
bagRemove(5000, 2)
fire("BAG_UPDATE_DELAYED")
fire("BANKFRAME_CLOSED")
check("banking an item doesn't remove it (you still have it)", Coffer.db.session.items[5000].count, 5)

fire("AUCTION_HOUSE_SHOW")
bagRemove(5000, 3)
fire("BAG_UPDATE_DELAYED")
fire("AUCTION_HOUSE_CLOSED")
check("posting on the AH doesn't remove it (not sold yet)", Coffer.db.session.items[5000].count, 5)
mails = { { sender = "Auction House", subject = "Auction successful: Item 5000", money = 2000,
            invoiceType = "seller", itemName = "Item 5000", count = 3 } }
fire("MAIL_SHOW")
collectMail(1)
check("auction sale gold collected from the mailbox counts", Coffer.db.session.ahSales, 2000)
check("...and those items leave the tally", Coffer.db.session.items[5000].count, 2)
collectMail(1)
check("collecting the same mail twice can't count twice", Coffer.db.session.ahSales, 2000)
fire("MAIL_CLOSED")

mails = { { sender = "Kabannalt", subject = "farm gold", money = 100000 } }
fire("MAIL_SHOW")
collectMail(1)
check("gold mailed by an alt isn't a sale", Coffer.db.session.ahSales, 2000)
fire("MAIL_CLOSED")

fire("AUCTION_HOUSE_SHOW")
local spentBeforeBid = Coffer.db.session.spent
setMoney(money - 1000)
fire("AUCTION_HOUSE_CLOSED")
check("a bid counts as spent", Coffer.db.session.spent - spentBeforeBid, 1000)
mails = { { sender = "Auction House", subject = "Outbid on Item 6000", money = 1000 } }
fire("MAIL_SHOW")
collectMail(1)
fire("MAIL_CLOSED")
check("...and an outbid refund gives it back", Coffer.db.session.spent, spentBeforeBid)

advance(10)
fire("CHAT_MSG_LOOT", "You receive loot: " .. link(4305) .. "x10.")
bagAdd(4305, 10)
fire("BAG_UPDATE_DELAYED")
bagRemove(4305, 6) -- materials leave before the "You create" line arrives...
fire("BAG_UPDATE_DELAYED")
fire("CHAT_MSG_LOOT", "You create: " .. link(5764) .. ".")
check("a crafted item counts at its value", (Coffer.db.session.items[5764] or {}).count, 1)
check("...marked as crafted", (Coffer.db.session.items[5764] or {}).crafted, 1)
check("looted materials it used leave the tally", Coffer.db.session.items[4305].count, 4)
advance(10)
fire("CHAT_MSG_LOOT", "You create: " .. link(5764) .. ".")
bagRemove(4305, 3) -- ...or after it
fire("BAG_UPDATE_DELAYED")
check("materials used just after the line count too", Coffer.db.session.items[4305].count, 1)
check("two crafted", (Coffer.db.session.items[5764] or {}).count, 2)
bagAdd(7777, 5)
fire("BAG_UPDATE_DELAYED")
advance(10)
fire("CHAT_MSG_LOOT", "You create: " .. link(5764) .. ".")
bagRemove(7777, 5)
fire("BAG_UPDATE_DELAYED")
check("materials you already had (not looted this session) cost nothing", (Coffer.db.session.items[5764] or {}).count, 3)
advance(10)
bagRemove(4305, 1)
fire("BAG_UPDATE_DELAYED")
check("using an item outside a craft or vendor keeps it counted", Coffer.db.session.items[4305].count, 1)

section("A dungeon run, with a death and a /reload")
fire("UNIT_DIED", SECRET)
check("open-world deaths aren't counted (can't tell whose kill)", Coffer.db.session.kills, 0)
check("...and don't use an instance slot", Coffer:GetLockoutStatus().day, 0)
enter("Blackrock Depths", 230)
fire("PLAYER_ENTERING_WORLD", false, false)
local run = Coffer:GetActiveRun()
check("run starts on entering", run and run.name, "Blackrock Depths")
local runStart = run.startTime
fire("UNIT_DIED", SECRET)
check("enemy death (secret GUID) counted", run.kills, 1)
check("session kill count", Coffer.db.session.kills, 1)
check("first kill uses an instance slot", Coffer:GetLockoutStatus().hour, 1)
fire("UNIT_DIED", "Player-1-00000002")
check("party member death (readable GUID) not counted", run.kills, 1)
fire("UNIT_DIED", SECRET)
check("same instance doesn't use another slot", Coffer:GetLockoutStatus().hour, 1)
fire("CHAT_MSG_MONEY", "You loot 3 Gold.")
fire("CHAT_MSG_LOOT", "You receive loot: " .. link(3000) .. "x5.")
advance(600)

dead = true
leave()
fire("ZONE_CHANGED_NEW_AREA")
check("releasing spirit pauses the run instead of ending it", Coffer:GetActiveRun() ~= nil, true)
check("no run recorded yet", #Coffer.db.runs, 0)
advance(120)
dead = false
enter("Blackrock Depths", 230)
fire("ZONE_CHANGED_NEW_AREA")
check("running back in resumes the same run", Coffer:GetActiveRun().startTime, runStart)
check("...and it's no longer paused", Coffer:GetActiveRun().pausedAt, nil)

reload()
check("/reload inside keeps the same run", Coffer:GetActiveRun() and Coffer:GetActiveRun().startTime, runStart)
fire("UNIT_DIED", SECRET)
check("kills keep counting after /reload", Coffer:GetActiveRun().kills, 3)
advance(300)

leave()
fire("ZONE_CHANGED_NEW_AREA")
check("leaving alive ends the run", Coffer:GetActiveRun(), nil)
check("one run recorded, not split by the death", #Coffer.db.runs, 1)
run = Coffer.db.runs[1]
check("run duration", run.duration, 1020)
check("run looted gold", run.loot, 30000)
check("run items value frozen at the end", run.itemsValue, 60)
check("run net = gold + items - spent", Coffer:GetRunNet(run), 30060)
check("run kills", run.kills, 3)

section("Instance lockouts")
fire("CHAT_MSG_SYSTEM", SECRET)
check("secret system message skipped without error", Coffer:GetLockoutStatus().entries[1].reset, nil)
fire("CHAT_MSG_SYSTEM", "Blackrock Depths has been reset.")
check("reset recorded", Coffer:GetLockoutStatus().entries[1].reset ~= nil, true)
enter("Blackrock Depths", 230)
fire("PLAYER_ENTERING_WORLD", false, false)
fire("UNIT_DIED", SECRET)
check("a reset instance uses a new slot", Coffer:GetLockoutStatus().hour, 2)
leave()
fire("ZONE_CHANGED_NEW_AREA")
for i, name in ipairs({ "Stratholme", "Scholomance", "Dire Maul" }) do
    enter(name, 300 + i)
    fire("PLAYER_ENTERING_WORLD", false, false)
    fire("UNIT_DIED", SECRET)
    leave()
    fire("ZONE_CHANGED_NEW_AREA")
end
local status = Coffer:GetLockoutStatus()
check("five instances this hour", status.hour, 5)
check("capped: shows when the next slot frees up", status.freeIn ~= nil and status.freeIn > 0, true)
check("lockouts are account-wide", CofferAccountDB.lockouts == Coffer.account.lockouts, true)
advance(3601)
check("slots free up after an hour", Coffer:GetLockoutStatus().hour, 0)
check("...but still count toward the day", Coffer:GetLockoutStatus().day, 5)
enter("Zul'Farrak", 209)
fire("PLAYER_ENTERING_WORLD", false, false)
fire("UNIT_DIED", SECRET)
leave()
fire("ZONE_CHANGED_NEW_AREA")
Logout()
Fire("PLAYER_LOGOUT")
local allReset = true
for _, entry in ipairs(CofferAccountDB.lockouts) do
    if not entry.reset then allReset = false end
end
check("logging out resets every used instance", allReset, true)
load()

section("A death you don't come back from")
enter("Uldaman", 70)
fire("PLAYER_ENTERING_WORLD", false, false)
fire("UNIT_DIED", SECRET)
advance(200)
dead = true
leave()
fire("ZONE_CHANGED_NEW_AREA")
local pausedAt = Coffer:GetActiveRun().pausedAt
dead = false
advance(16 * 60)
tick()
check("paused run ends after 15 minutes", Coffer:GetActiveRun(), nil)
check("...recorded up to when you left", Coffer.db.runs[1].endTime, pausedAt)

section("Panel interactions")
local itemRow = nil
local function findItemRow(widget)
    for _, child in ipairs(widget.children) do
        if child.link and child.link:find("item:2589", 1, true) then return child end
        local found = findItemRow(child)
        if found then return found end
    end
end
itemRow = findItemRow(CofferFrame)
check("item row exists", itemRow ~= nil, true)
itemRow.scripts.OnEnter(itemRow)
check("item tooltip shows the item", GameTooltip.lines[1] and GameTooltip.lines[1]:find("item:2589", 1, true) ~= nil, true)
shift = true
Click(itemRow)
shift = false
check("shift-click links the item in chat", insertedLink and insertedLink:find("item:2589", 1, true) ~= nil, true)

local function findRow(widget, itemID)
    for _, child in ipairs(widget.children) do
        if child.itemID == itemID and child:IsShown() then return child end
        local found = findRow(child, itemID)
        if found then return found end
    end
end
local robeRow = findRow(CofferFrame, 4002)
check("row for the item to forget", robeRow ~= nil, true)
Click(robeRow, "RightButton")
flush()
check("right-click stops counting an item", Coffer.db.session.items[4002], nil)

local runsHeader = FindText(CofferFrame, "RECENT RUNS")
check("runs header found", runsHeader ~= nil, true)
local function findRunRow(widget)
    for _, child in ipairs(widget.children) do
        if child.tooltip and not child.link and child.kind == "Button" and child.name then return child end
        local found = findRunRow(child)
        if found then return found end
    end
end
local runRow = findRunRow(CofferFrame)
check("run row exists", runRow ~= nil, true)
runRow.scripts.OnEnter(runRow)
check("run tooltip shows the breakdown", #GameTooltip.lines > 5, true)

local instancesRow = FindText(CofferFrame, "Instances")
instancesRow.scripts.OnEnter(instancesRow)
check("lockout tooltip", GameTooltip.lines[1], "Instance lockouts")

local itemsHeader = FindText(CofferFrame, "ITEMS")
Click(itemsHeader)
flush()
check("collapsing a section is saved", Coffer.db.settings.collapsed.items, true)
reload()
check("...and remembered after /reload", Coffer.db.settings.collapsed.items, true)

local gear
for _, child in ipairs(CofferFrame.children) do
    for _, region in ipairs(child.regions) do
        if region.texture == "Interface\\Icons\\Trade_Engineering" then gear = child end
    end
end
Click(gear)
check("settings menu opens", CofferMenu and CofferMenu:IsShown(), true)
Click(FindText(CofferMenu, "   Value items at vendor price"))
check("menu switches valuation", Coffer.db.settings.valuation, "vendor")
check("menu closes after a choice", CofferMenu:IsShown(), false)

local close = FindText(CofferFrame, "x")
Click(close)
check("closing hides the panel", CofferFrame:IsShown(), false)
reload()
check("...and it stays hidden after /reload", CofferFrame == nil or not CofferFrame:IsShown(), true)
compartment.func()
flush()
check("compartment entry reopens it", CofferFrame and CofferFrame:IsShown(), true)

section("Slash commands")
CofferDB.schema = 2
CofferDB.session.vendor = 777
reload()
check("schema 2 vendor sales (never matched to items) dropped, not double-counted", Coffer.db.session.vendor, 0)
check("...the rest of the session kept", Coffer.db.session.quest, 5000)
slash("help")
slash("debug")
check("debug window opens", CofferDebugFrame and CofferDebugFrame:IsShown(), true)
slash("clearruns")
check("clearruns", #Coffer.db.runs, 0)
slash("reset")
check("reset clears the session", Coffer.db.session.loot, 0)
check("reset restarts session time", Coffer:GetSessionDuration(), 0)
tick()

realPrint("")
realPrint(("ALL %d CHECKS PASSED"):format(passed))
