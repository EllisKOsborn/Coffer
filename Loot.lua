local addonName, Coffer = ...

-- Your own loot is recognised by Blizzard's own localized "you" templates
-- (LOOT_ITEM_SELF etc.), the technique KiwiFarm uses. Other party members' loot uses a
-- different template ("%s receives loot: %s."), so it can never match - no name or GUID
-- comparison is involved, which also makes Forever's two-part character names
-- irrelevant. Patterns are anchored, and the "x%d" variants are tried first so a stack
-- count is never swallowed into the item text.
local SELF_LOOT_PATTERNS = {}
for _, template in ipairs({
    LOOT_ITEM_SELF_MULTIPLE,
    LOOT_ITEM_PUSHED_SELF_MULTIPLE,
    LOOT_ITEM_SELF,
    LOOT_ITEM_PUSHED_SELF,
}) do
    local pattern = Coffer:PatternFromTemplate(template, true)
    if pattern then
        SELF_LOOT_PATTERNS[#SELF_LOOT_PATTERNS + 1] = pattern
    end
end

-- Returns the item link and quantity if message is the player's own loot. The captured
-- text is the whole link as the client formatted it, so this doesn't depend on any
-- particular link color syntax (newer clients use "|cnIQ4:" rather than 8 hex digits).
function Coffer:ParseOwnLoot(message)
    for _, pattern in ipairs(SELF_LOOT_PATTERNS) do
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

function Coffer:RecordItemLoot(itemID, count, link)
    local items = self.db.session.items
    local entry = items[itemID]
    if not entry then
        entry = { count = 0 }
        items[itemID] = entry
    end
    entry.count = entry.count + count
    entry.link = link
    self:TrackRunItem(itemID, count)
    self:Changed()

    self:GetItemValue(itemID, function(value, source)
        entry.value, entry.source = value, source
        self:Changed()
    end)
end

Coffer:On("CHAT_MSG_LOOT", function(self, _, message)
    if not self.db or not self:Readable(message) or type(message) ~= "string" then return end
    if self:IsAcquiringNotLooting() then return end -- bought, mailed, traded: not loot
    local itemID, count, link = self:ParseOwnLoot(message)
    if itemID then
        self:RecordItemLoot(itemID, count, link)
    end
end)

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
