local addonName, Coffer = ...

-- Instance lockout tracking, modelled on KiwiFarm (which applies Classic rules to
-- Forever): at most 5 instances per hour and 30 per day, per account. An instance only
-- uses a slot once you've killed something in it, re-entering the same instance before
-- it's reset doesn't use another, and logging out resets every instance you've used.
-- Stored in CofferAccountDB so every character on the account shares the count.

local HOUR, DAY = 3600, 86400
local HOUR_LIMIT, DAY_LIMIT = 5, 30

local function Entries()
    return Coffer.account.lockouts
end

local function Prune()
    local list = Entries()
    local cutoff = time() - DAY
    while list[1] and list[1].time <= cutoff do
        table.remove(list, 1)
    end
end

-- The instance you're in used a slot (called on the first kill inside it).
function Coffer:MarkInstanceUsed(zone)
    if not zone or zone == "" or not self.account then return end
    local list = Entries()
    for i = #list, 1, -1 do
        if list[i].zone == zone and not list[i].reset then
            return -- still the same, un-reset instance
        end
    end
    list[#list + 1] = { zone = zone, time = time() }
    self:Changed()
end

function Coffer:MarkInstanceReset(zone)
    local list = Entries()
    for i = #list, 1, -1 do
        if list[i].zone == zone and not list[i].reset then
            list[i].reset = time()
            self:Changed()
            return
        end
    end
end

function Coffer:GetLockoutStatus()
    Prune()
    local now, list = time(), Entries()
    local hour, oldestInHour = 0, nil
    for _, entry in ipairs(list) do
        if entry.time > now - HOUR then
            hour = hour + 1
            oldestInHour = oldestInHour or entry.time
        end
    end
    return {
        hour = hour,
        hourLimit = HOUR_LIMIT,
        day = #list,
        dayLimit = DAY_LIMIT,
        -- seconds until a slot frees up, when you're at the hourly cap
        freeIn = (hour >= HOUR_LIMIT and oldestInHour) and (oldestInHour + HOUR - now) or nil,
        entries = list,
    }
end

-- "<zone> has been reset." Classic clients sometimes report a reset as failed even
-- though it succeeded, so (like KiwiFarm) the failure message counts too.
local RESET_OK = Coffer:PatternFromTemplate(INSTANCE_RESET_SUCCESS, true)
local RESET_FAILED = Coffer:PatternFromTemplate(INSTANCE_RESET_FAILED, true)

function Coffer:ParseResetMessage(message)
    return (RESET_OK and message:match(RESET_OK)) or (RESET_FAILED and message:match(RESET_FAILED))
end

Coffer:On("CHAT_MSG_SYSTEM", function(self, _, message)
    if not self.db or not self:Readable(message) or type(message) ~= "string" then return end
    local zone = self:ParseResetMessage(message)
    if zone then
        self:MarkInstanceReset(zone)
        self:EndRunForReset(zone)
    end
end)

-- The game resets every instance you've used when you log out (not on /reload), except
-- the one you're standing in.
local loggingOut = false
if hooksecurefunc then
    if Logout then hooksecurefunc("Logout", function() loggingOut = true end) end
    if Quit then hooksecurefunc("Quit", function() loggingOut = true end) end
    if CancelLogout then hooksecurefunc("CancelLogout", function() loggingOut = false end) end
end

Coffer:On("PLAYER_LOGOUT", function(self)
    if not loggingOut or not self.account then return end
    local inInstance = IsInInstance()
    local current = inInstance and GetInstanceInfo() or nil
    for _, entry in ipairs(Entries()) do
        if not entry.reset and entry.zone ~= current then
            entry.reset = time()
        end
    end
end)
