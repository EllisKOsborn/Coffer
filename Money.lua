local addonName, Coffer = ...

-- ---------------------------------------------------------------------------
-- Session time: online seconds only
-- ---------------------------------------------------------------------------

-- session.duration holds online time banked at the last logout/reload; onlineSince is
-- when this login started. Time spent logged off never counts, so gold per hour isn't
-- diluted by sleeping between farming sessions (KiwiFarm times sessions the same way).
local onlineSince

local function BankOnlineTime()
    if onlineSince and Coffer.db then
        local session = Coffer.db.session
        session.duration = (session.duration or 0) + math.max(0, time() - onlineSince)
        onlineSince = time()
    end
end

function Coffer:GetSessionDuration()
    if not self.db then return 0 end
    return (self.db.session.duration or 0) + (onlineSince and math.max(0, time() - onlineSince) or 0)
end

-- ---------------------------------------------------------------------------
-- Totals
-- ---------------------------------------------------------------------------
-- Same convention as both reference addons (checked against the Fojicore panel's own
-- numbers: (331 earned + 233 items) / 51h15m = 11.0 gold/hour, and 331 + 233 - 374 =
-- its 190-191 total):
--   earned   = looted gold + quest gold
--   items    = value of items looted
--   income   = earned + items                 -> gold per hour
--   total    = income - spent
-- Gold from selling looted items to a vendor is NOT income - its value was already
-- counted as an item when it was looted. It's recorded separately (session.vendor) for
-- information only.

function Coffer:GetSessionEarned()
    local session = self.db.session
    return session.loot + session.quest
end

function Coffer:GetSessionIncome()
    return self:GetSessionEarned() + self:GetSessionItemsValue()
end

function Coffer:GetSessionNet()
    return self:GetSessionIncome() - self.db.session.spent
end

-- nil for the first minute, when a rate would be meaningless (one early drop would
-- read as thousands of gold per hour).
function Coffer:GetGoldPerHour()
    local seconds = self:GetSessionDuration()
    if seconds < 60 then return nil end
    return self:GetSessionIncome() / (seconds / 3600)
end

function Coffer:ResetSession()
    local session = self.db.session
    session.loot, session.quest, session.vendor, session.spent, session.kills = 0, 0, 0, 0, 0
    session.duration = 0
    wipe(session.items)
    onlineSince = time()
    self:Changed()
end

-- ---------------------------------------------------------------------------
-- Income
-- ---------------------------------------------------------------------------

-- Looted gold, parsed from CHAT_MSG_MONEY using Blizzard's own localized
-- "%d Gold"/"%d Silver"/"%d Copper" templates (KiwiFarm's technique). This event fires
-- only for your own money - "You loot ..." and "Your share of the loot is ..." alike.
local GOLD = Coffer:PatternFromTemplate(GOLD_AMOUNT)
local SILVER = Coffer:PatternFromTemplate(SILVER_AMOUNT)
local COPPER = Coffer:PatternFromTemplate(COPPER_AMOUNT)

function Coffer:ParseMoney(message)
    -- Drop parentheticals like "(5 Silver deposited to guild bank)" so a guild tax
    -- amount can't be read as part of what you looted.
    message = message:gsub("%b()", "")
    local gold = GOLD and tonumber(message:match(GOLD)) or 0
    local silver = SILVER and tonumber(message:match(SILVER)) or 0
    local copper = COPPER and tonumber(message:match(COPPER)) or 0
    return gold * 10000 + silver * 100 + copper
end

Coffer:On("CHAT_MSG_MONEY", function(self, _, message)
    if not self.db or not self:Readable(message) or type(message) ~= "string" then return end
    local amount = self:ParseMoney(message)
    if amount <= 0 then return end
    self.db.session.loot = self.db.session.loot + amount
    self:TrackRunIncome("loot", amount)
    self:Changed()
end)

-- The reward comes straight from the event, no inference needed.
Coffer:On("QUEST_TURNED_IN", function(self, _, _, _, moneyReward)
    if not self.db or not self:Readable(moneyReward) or type(moneyReward) ~= "number" or moneyReward <= 0 then return end
    self.db.session.quest = self.db.session.quest + moneyReward
    self:TrackRunIncome("quest", moneyReward)
    self:Changed()
end)

-- ---------------------------------------------------------------------------
-- Vendor sales and spending (PLAYER_MONEY)
-- ---------------------------------------------------------------------------

-- Which money-moving windows are open. Classic events and the modern interaction
-- manager both report these; Forever may send either, so both are listened to.
local open = {}

local function Track(showEvent, hideEvent, kind)
    Coffer:On(showEvent, function() open[kind] = true end)
    Coffer:On(hideEvent, function() open[kind] = nil end)
end
Track("MERCHANT_SHOW", "MERCHANT_CLOSED", "merchant")
Track("MAIL_SHOW", "MAIL_CLOSED", "mail")
Track("TRADE_SHOW", "TRADE_CLOSED", "trade")
Track("AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "auction")
Track("BANKFRAME_OPENED", "BANKFRAME_CLOSED", "bank")
Track("GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "guildbank")

local interactionKinds = {}
local PIT = Enum and Enum.PlayerInteractionType
if PIT then
    for enumName, kind in pairs({
        Merchant = "merchant", MailInfo = "mail", TradePartner = "trade",
        Auctioneer = "auction", Banker = "bank", GuildBanker = "guildbank",
    }) do
        if PIT[enumName] then interactionKinds[PIT[enumName]] = kind end
    end
end

-- Items that turn up while one of these windows is open were bought, collected from the
-- mailbox (which is where auction house purchases arrive) or traded - not looted, even
-- though the game announces them with the same "You receive item: ..." line it uses for
-- quest rewards.
function Coffer:IsAcquiringNotLooting()
    return next(open) ~= nil
end

-- A missed close event must not leave items uncounted indefinitely: opening a loot window
-- or zoning means those windows aren't open any more.
local function ClearOpenWindows()
    wipe(open)
end
Coffer:On("LOOT_OPENED", ClearOpenWindows)
Coffer:On("PLAYER_ENTERING_WORLD", ClearOpenWindows)
Coffer:On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, _, kind)
    if interactionKinds[kind] then open[interactionKinds[kind]] = true end
end)
Coffer:On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, _, kind)
    if interactionKinds[kind] then open[interactionKinds[kind]] = nil end
end)

-- PLAYER_MONEY fires for every balance change, including the loot and quest gold
-- already counted above. Left for it to classify:
--   increase at a merchant   -> vendor sale (informational, not income - see Totals)
--   other increases          -> already counted, or not farming income (mail, trade)
--   decrease at mail/trade   -> moving gold to an alt or another player, not spending
--   any other decrease       -> spent (repairs, purchases, training, AH, flights, ...)
local lastMoney

Coffer:On("PLAYER_MONEY", function(self)
    local current = GetMoney()
    if lastMoney == nil or not self.db then
        lastMoney = current
        return
    end
    local delta = current - lastMoney
    lastMoney = current
    if delta > 0 then
        if open.merchant then
            self.db.session.vendor = self.db.session.vendor + delta
            self:Changed()
        end
    elseif delta < 0 and not open.mail and not open.trade then
        self.db.session.spent = self.db.session.spent - delta
        self:TrackRunIncome("spent", -delta)
        self:Changed()
    end
end)

Coffer:OnReady(function()
    onlineSince = time()
    lastMoney = GetMoney()
end)

Coffer:On("PLAYER_LOGOUT", function()
    BankOnlineTime()
end)
