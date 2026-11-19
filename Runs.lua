local addonName, Coffer = ...

local MAX_RUNS = 50
local MIN_RUN_SECONDS = 15

local active
local lastInstanceID

local function NewRun(name)
    return {
        name = name,
        startTime = time(),
        loot = 0, quest = 0, vendor = 0, spent = 0,
        items = {},
    }
end

function Coffer:GetActiveRun()
    return active
end

function Coffer:TrackRunIncome(bucket, amount)
    if active and amount and amount ~= 0 then
        active[bucket] = (active[bucket] or 0) + amount
    end
end

function Coffer:TrackRunItem(itemID, count)
    if not active then return end
    local entry = active.items[itemID] or { count = 0 }
    entry.count = entry.count + count
    active.items[itemID] = entry
end

local function EndRun()
    if not active then return end
    active.endTime = time()
    active.duration = active.endTime - active.startTime

    local hadIncome = active.loot + active.quest + active.vendor > 0
    if active.duration >= MIN_RUN_SECONDS and (hadIncome or next(active.items)) then
        table.insert(Coffer.db.runs, 1, active)
        for i = #Coffer.db.runs, MAX_RUNS + 1, -1 do
            table.remove(Coffer.db.runs)
        end
        Coffer:NotifyRunsChanged()
    end
    active = nil
    Coffer:NotifyActiveRunChanged()
end

local function StartRun(name)
    EndRun()
    active = NewRun(name)
    Coffer:NotifyActiveRunChanged()
end

local function CheckInstance()
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "party" then
        local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
        if instanceID ~= lastInstanceID then
            lastInstanceID = instanceID
            StartRun(name)
        end
    elseif lastInstanceID then
        lastInstanceID = nil
        EndRun()
    end
end

Coffer:On("PLAYER_ENTERING_WORLD", CheckInstance)
Coffer:On("ZONE_CHANGED_NEW_AREA", CheckInstance)
