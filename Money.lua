local addonName, Coffer = ...

local lastMoney
local merchantOpen = false

-- Loot gold is parsed directly from CHAT_MSG_MONEY using Blizzard's own localized
-- "%d Gold"/"%d Silver"/"%d Copper" templates (GOLD_AMOUNT etc.), the same technique
-- proven production addons (e.g. KiwiFarm) use - this event fires specifically for
-- money looted, so there's no need to infer "was this loot?" from timing/context at
-- all, unlike a PLAYER_MONEY delta.
local GOLD_PATTERN = _G.GOLD_AMOUNT and (_G.GOLD_AMOUNT:gsub("%%d", "(%%d+)"))
local SILVER_PATTERN = _G.SILVER_AMOUNT and (_G.SILVER_AMOUNT:gsub("%%d", "(%%d+)"))
local COPPER_PATTERN = _G.COPPER_AMOUNT and (_G.COPPER_AMOUNT:gsub("%%d", "(%%d+)"))

local function ParseLootedMoney(message)
    local gold = GOLD_PATTERN and tonumber(message:match(GOLD_PATTERN)) or 0
    local silver = SILVER_PATTERN and tonumber(message:match(SILVER_PATTERN)) or 0
    local copper = COPPER_PATTERN and tonumber(message:match(COPPER_PATTERN)) or 0
    return gold * 10000 + silver * 100 + copper
end

Coffer:On("CHAT_MSG_MONEY", function(self, _, message)
    local amount = ParseLootedMoney(message)
    if amount <= 0 or not self.db then return end
    local session = self.db.session
    session.loot = session.loot + amount
    self:TrackRunIncome("loot", amount)
    self:NotifyMoneyChanged()
end)

-- moneyReward is given directly by the event - no need to infer it from a money delta.
Coffer:On("QUEST_TURNED_IN", function(self, _, questID, xpReward, moneyReward)
    if not moneyReward or moneyReward <= 0 or not self.db then return end
    local session = self.db.session
    session.quest = session.quest + moneyReward
    self:TrackRunIncome("quest", moneyReward)
    self:NotifyMoneyChanged()
end)

Coffer:On("MERCHANT_SHOW", function() merchantOpen = true end)
Coffer:On("MERCHANT_CLOSED", function() merchantOpen = false end)

-- PLAYER_MONEY fires for every currency change, including the loot/quest gold already
-- captured precisely above - counting those again here would double them. What's left
-- for this handler: vendor sales (a positive delta while the merchant window is open)
-- and spending (any decrease - repairs, purchases, training, AH deposits, ...), neither
-- of which has its own dedicated, cleanly-parseable chat event.
Coffer:On("PLAYER_MONEY", function(self)
    local current = GetMoney()
    if lastMoney == nil then
        lastMoney = current
        return
    end
    local delta = current - lastMoney
    lastMoney = current
    if delta == 0 or not self.db then return end

    local session = self.db.session
    if delta > 0 then
        if merchantOpen then
            session.vendor = session.vendor + delta
            self:TrackRunIncome("vendor", delta)
            self:NotifyMoneyChanged()
        end
        -- else: already accounted for via CHAT_MSG_MONEY/QUEST_TURNED_IN above.
    else
        session.spent = session.spent - delta
        self:TrackRunIncome("spent", -delta)
        self:NotifyMoneyChanged()
    end
end)

Coffer:OnReady(function()
    lastMoney = GetMoney()
end)

function Coffer:GetSessionDuration()
    if not self.db or not self.db.session.startTime then return 0 end
    return time() - self.db.session.startTime
end

function Coffer:GetGoldPerHour()
    local elapsed = self:GetSessionDuration()
    if elapsed <= 0 then return 0 end
    local session = self.db.session
    local net = session.loot + session.quest + session.vendor - session.spent
    return net / (elapsed / 3600)
end

function Coffer:GetSessionEarned()
    local session = self.db.session
    return session.loot + session.quest + session.vendor
end

function Coffer:GetSessionNet()
    local session = self.db.session
    return self:GetSessionEarned() - session.spent
end

-- Total estimated value of items looted this session (whatever their value source
-- resolved to - auction or vendor). Shown alongside the realized-gold figures above as
-- separate, informational "potential value still sitting in your bags" - not summed
-- into Earned/Total, since actually selling an item is already captured as vendor gold
-- when it happens, and these two would otherwise double-count.
function Coffer:GetSessionItemsValue()
    if not self.db then return 0 end
    local total = 0
    for _, entry in pairs(self.db.session.items) do
        total = total + (entry.value or 0) * entry.count
    end
    return total
end

function Coffer:ResetSession()
    local session = self.db.session
    session.startTime = time()
    session.loot, session.quest, session.vendor, session.spent = 0, 0, 0, 0
    wipe(session.items)
    self:NotifySessionReset()
end
