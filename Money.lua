local addonName, Coffer = ...

local lastMoney
local questFlag = false
local questFlagTimer
local merchantOpen = false

-- Classifies every currency change into loot / quest / vendor / spent. We can't get a
-- direct "why did money change" event from the API, so we infer it from short-lived
-- flags set by QUEST_TURNED_IN and MERCHANT_SHOW/CLOSED, which both fire just before
-- the matching PLAYER_MONEY event.
local function ClassifyAndRecord(delta)
    local session = Coffer.db.session
    if delta > 0 then
        local bucket
        if questFlag then
            bucket = "quest"
            questFlag = false
        elseif merchantOpen then
            bucket = "vendor"
        else
            bucket = "loot"
        end
        session[bucket] = session[bucket] + delta
        Coffer:TrackRunIncome(bucket, delta)
    else
        session.spent = session.spent - delta
        Coffer:TrackRunIncome("spent", -delta)
    end
    Coffer:NotifyMoneyChanged()
end

Coffer:On("PLAYER_MONEY", function(self)
    local current = GetMoney()
    if lastMoney == nil then
        lastMoney = current
        return
    end
    local delta = current - lastMoney
    lastMoney = current
    if delta ~= 0 and self.db then
        ClassifyAndRecord(delta)
    end
end)

Coffer:On("QUEST_TURNED_IN", function()
    questFlag = true
    if questFlagTimer then
        questFlagTimer:Cancel()
    end
    questFlagTimer = C_Timer.NewTimer(1, function() questFlag = false end)
end)

Coffer:On("MERCHANT_SHOW", function() merchantOpen = true end)
Coffer:On("MERCHANT_CLOSED", function() merchantOpen = false end)

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

function Coffer:ResetSession()
    local session = self.db.session
    session.startTime = time()
    session.loot, session.quest, session.vendor, session.spent = 0, 0, 0, 0
    wipe(session.items)
    self:NotifySessionReset()
end
