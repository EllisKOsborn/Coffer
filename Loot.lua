local addonName, Coffer = ...

-- Your own loot is recognised by Blizzard's own localized "you" templates
-- (LOOT_ITEM_SELF etc.), the technique KiwiFarm uses. Other party members' loot uses a
-- different template ("%s receives loot: %s."), so it can never match - no name or GUID
-- comparison is involved, which also makes Forever's two-part character names
-- irrelevant. Patterns are anchored, and the "x%d" variants are tried first so a stack
-- count is never swallowed into the item text.
local function Patterns(templates)
    local list = {}
    for _, template in ipairs(templates) do
        local pattern = Coffer:PatternFromTemplate(template, true)
        if pattern then list[#list + 1] = pattern end
    end
    return list
end

local LOOT_PATTERNS = Patterns({
    LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_SELF, LOOT_ITEM_PUSHED_SELF,
})
-- "You create: %s." - things you craft.
local CRAFT_PATTERNS = Patterns({ LOOT_ITEM_CREATED_SELF_MULTIPLE, LOOT_ITEM_CREATED_SELF })

-- Returns itemID, quantity and the item link if message matches one of patterns. The
-- captured text is the whole link as the client formatted it, so this doesn't depend on
-- any particular link color syntax (newer clients use "|cnIQ4:" rather than 8 hex digits).
local function Parse(message, patterns)
    for _, pattern in ipairs(patterns) do
        local first, second = message:match(pattern)
        if first then
            local text, quantity = first, second
            if second and first:match("^%d+$") then -- positional templates can swap order
                text, quantity = second, first
            end
            local itemID = tonumber(text:match("item:(%d+)"))
            if itemID then
                return itemID, tonumber(quantity) or 1, text
            end
        end
    end
end

function Coffer:ParseOwnLoot(message)
    return Parse(message, LOOT_PATTERNS)
end

-- crafted: true for things you made, which aren't part of a dungeon run's loot.
function Coffer:RecordItemLoot(itemID, count, link, crafted)
    local items = self.db.session.items
    local entry = items[itemID]
    if not entry then
        entry = { count = 0 }
        items[itemID] = entry
    end
    entry.count = entry.count + count
    entry.link = link
    if crafted then
        entry.crafted = (entry.crafted or 0) + count
    else
        self:TrackRunItem(itemID, count)
    end
    self:Changed()

    self:GetItemValue(itemID, function(value, source)
        entry.value, entry.source = value, source
        self:Changed()
    end)
end

Coffer:On("CHAT_MSG_LOOT", function(self, _, message)
    if not self.db or not self:Readable(message) or type(message) ~= "string" then return end

    local itemID, count, link = Parse(message, CRAFT_PATTERNS)
    if itemID then
        self:RecordItemLoot(itemID, count, link, true)
        self:NoteCraft(itemID) -- the materials it used stop counting (Sales.lua)
        return
    end

    if self:IsAcquiringNotLooting() then return end -- bought, mailed, traded: not loot
    itemID, count, link = Parse(message, LOOT_PATTERNS)
    if itemID then
        self:RecordItemLoot(itemID, count, link)
    end
end)

-- Items counted at their value leave the tally when they're sold or used in a craft:
-- the sale gold or the crafted item counts instead, so nothing is counted twice. Items
-- that weren't in the tally (not looted this session) are unaffected.
function Coffer:ItemsLeftBags(itemID, count)
    local function Take(items)
        local entry = items and items[itemID]
        if not entry then return end
        entry.count = entry.count - math.min(count, entry.count)
        if entry.count <= 0 then
            items[itemID] = nil
        elseif entry.crafted then
            entry.crafted = math.min(entry.crafted, entry.count)
        end
    end
    Take(self.db.session.items)
    local run = self:GetActiveRun()
    if run then Take(run.items) end
    self:Changed()
end

-- Stop counting an item this session (and in the run in progress): the manual fix for
-- anything that slipped through as loot when it wasn't.
function Coffer:ForgetItem(itemID)
    self.db.session.items[itemID] = nil
    local run = self:GetActiveRun()
    if run then
        run.items[itemID] = nil
    end
    self:Changed()
end
