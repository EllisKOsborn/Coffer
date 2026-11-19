local addonName, Coffer = ...

local MAX_RUNS = 100
local MIN_RUN_SECONDS = 30
-- A run paused by a death (you released and are outside the instance) ends if you
-- don't come back in within this long.
local PAUSE_TIMEOUT = 15 * 60

-- The run in progress lives in CofferDB (not just memory), so a /reload or disconnect
-- mid-dungeon resumes the same run instead of losing it.
local function Active()
    return Coffer.db and Coffer.db.activeRun
end

function Coffer:GetActiveRun()
    return Active()
end

local function InTrackedInstance()
    local inInstance, instanceType = IsInInstance()
    return inInstance and (instanceType == "party" or instanceType == "raid")
end

function Coffer:GetRunDuration(run)
    local finish = run.endTime or time()
    return math.max(0, finish - run.startTime - (run.offline or 0))
end

-- Same convention as the session: looted gold + quest gold + item value - spent.
function Coffer:GetRunNet(run)
    local items = run.itemsValue or self:GetRunItemsValue(run)
    return (run.loot or 0) + (run.quest or 0) + items - (run.spent or 0)
end

function Coffer:TrackRunIncome(bucket, amount)
    local run = Active()
    if run and amount and amount ~= 0 then
        run[bucket] = (run[bucket] or 0) + amount
    end
end

function Coffer:TrackRunItem(itemID, count)
    local run = Active()
    if not run then return end
    local entry = run.items[itemID]
    if not entry then
        entry = { count = 0 }
        run.items[itemID] = entry
    end
    entry.count = entry.count + count
end

local function StartRun(name, mapID)
    Coffer.db.activeRun = {
        name = name,
        mapID = mapID,
        startTime = time(),
        offline = 0,
        loot = 0, quest = 0, spent = 0, kills = 0,
        items = {},
    }
    Coffer:Changed()
end

local function EndRun(endTime)
    local run = Active()
    if not run then return end
    Coffer.db.activeRun = nil

    run.endTime = endTime or time()
    run.duration = Coffer:GetRunDuration(run)
    run.itemsValue = Coffer:GetRunItemsValue(run) -- frozen: later price changes don't rewrite history
    run.pausedAt, run.loggedOutAt = nil, nil

    -- Runs with no gold are kept (the reference panel shows them as "-"), but an
    -- accidental walk through a portal isn't a run.
    local hadActivity = run.loot + run.quest > 0 or run.kills > 0 or next(run.items) ~= nil
    if run.duration >= MIN_RUN_SECONDS or hadActivity then
        local runs = Coffer.db.runs
        table.insert(runs, 1, run)
        while #runs > MAX_RUNS do
            table.remove(runs)
        end
    end
    Coffer:Changed()
end

function Coffer:ClearRuns()
    wipe(self.db.runs)
    self:Changed()
end

-- A reset of the instance a paused run belongs to means you won't be coming back to it.
function Coffer:EndRunForReset(zone)
    local run = Active()
    if run and run.name == zone and not InTrackedInstance() then
        EndRun(run.pausedAt or time())
    end
end

local function CheckInstance()
    if not Coffer.db then return end
    local run = Active()
    local now = time()

    if InTrackedInstance() then
        local name, _, _, _, _, _, _, mapID = GetInstanceInfo()
        if run and run.mapID == mapID then
            -- Same dungeon: back from a corpse run, a /reload, or a reconnect. Time spent
            -- logged out isn't run time.
            if run.loggedOutAt then
                local gap = now - run.loggedOutAt
                if gap > 60 then
                    run.offline = (run.offline or 0) + gap
                end
                run.loggedOutAt = nil
            end
            run.pausedAt = nil
            Coffer:Changed()
            return
        end
        if run then
            EndRun(run.pausedAt or run.loggedOutAt or now)
        end
        StartRun(name, mapID)
        return
    end

    if not run then return end
    if run.pausedAt then
        if now - run.pausedAt > PAUSE_TIMEOUT then
            EndRun(run.pausedAt)
        end
    elseif run.loggedOutAt then
        EndRun(run.loggedOutAt) -- logged out inside, came back somewhere else
    elseif UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        run.pausedAt = now -- released spirit: same run once you're back inside
        Coffer:Changed()
    else
        EndRun(now)
    end
end

Coffer:On("PLAYER_ENTERING_WORLD", CheckInstance)
Coffer:On("ZONE_CHANGED_NEW_AREA", CheckInstance)

Coffer:On("PLAYER_LOGOUT", function()
    local run = Active()
    if run then
        run.loggedOutAt = time()
    end
end)

Coffer:OnReady(function()
    C_Timer.NewTicker(30, CheckInstance) -- expires death-paused runs you never returned to
end)

-- ---------------------------------------------------------------------------
-- Kills
-- ---------------------------------------------------------------------------

-- Only counted inside dungeons/raids: in the open world there's no telling your kills
-- from other players'. The first kill in an instance is also what uses a lockout slot.
local function RecordKill()
    if not Coffer.db or not InTrackedInstance() then return end
    Coffer.db.session.kills = Coffer.db.session.kills + 1
    local run = Active()
    if run then
        run.kills = run.kills + 1
    end
    Coffer:MarkInstanceUsed((GetInstanceInfo()))
    Coffer:Changed()
end

-- Midnight-era clients (Forever included) give addons UNIT_DIED, with an enemy's GUID
-- as a secret value; the combat log isn't available to addons there. Older clients use
-- the combat log instead. Same split as KiwiFarm.
local hasUnitDied = Coffer:On("UNIT_DIED", function(self, _, guid)
    if guid ~= nil and self.IsSecret(guid) then
        RecordKill()
    end
end)

if not hasUnitDied then
    local NPC = COMBATLOG_OBJECT_TYPE_NPC or 0x800
    local band = bit and bit.band
    Coffer:On("COMBAT_LOG_EVENT_UNFILTERED", function()
        if not CombatLogGetCurrentEventInfo or not band then return end
        local _, subEvent, _, _, _, _, _, _, _, destFlags = CombatLogGetCurrentEventInfo()
        if subEvent == "UNIT_DIED" and band(destFlags or 0, NPC) > 0 then
            RecordKill()
        end
    end)
end
