local addonName, Coffer = ...

-- Matches your own loot by using Blizzard's own localized chat templates for it
-- (LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF, and the "x4" plural
-- variant), turned into Lua patterns by swapping their %s/%d placeholders for actual
-- captures - the same technique proven production addons (e.g. KiwiFarm) use. Because
-- these templates are specifically the "you" phrasing ("You receive loot: %s."), while
-- other party/raid members' loot uses an entirely different template ("%s receives
-- loot: %s."), this only ever matches the player's own loot - no comparison against
-- UnitName()/UnitGUID() is needed at all, which sidesteps Forever's two-part name
-- system (Main Name + Secondary Name) entirely rather than having to work around it.
local SELF_LOOT_PATTERNS = {}
for _, template in ipairs({
    _G.LOOT_ITEM_SELF_MULTIPLE,
    _G.LOOT_ITEM_PUSHED_SELF_MULTIPLE,
    _G.LOOT_ITEM_SELF,
    _G.LOOT_ITEM_PUSHED_SELF,
}) do
    if template then
        table.insert(SELF_LOOT_PATTERNS, (template:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")))
    end
end

-- Item hyperlinks are never localized, so once the surrounding (now locale-safe)
-- sentence confirms this is our own loot, the item link itself is pulled out directly
-- rather than relying on the template's capture matching the link text exactly.
local LINK_PATTERN = "(|c%x%x%x%x%x%x%x%x|Hitem:.-|h%[.-%]|h|r)"

local function GetOwnLootFromMessage(message)
    for _, pattern in ipairs(SELF_LOOT_PATTERNS) do
        local captured, quantity = message:match(pattern)
        if captured then
            local link = captured:match(LINK_PATTERN) or message:match(LINK_PATTERN)
            if link then
                return link, tonumber(quantity) or 1
            end
        end
    end
end

function Coffer:RecordItemLoot(itemID, count, link)
    local session = self.db.session
    local entry = session.items[itemID]
    if not entry then
        entry = { count = 0, link = link }
        session.items[itemID] = entry
    end
    entry.count = entry.count + count
    entry.link = link

    self:TrackRunItem(itemID, count)
    self:NotifyItemsChanged()

    self:GetItemValue(itemID, function(value, source)
        entry.value = value
        entry.source = source
        self:NotifyItemsChanged()
    end)
end

Coffer:On("CHAT_MSG_LOOT", function(self, _, message)
    local link, count = GetOwnLootFromMessage(message)
    if not link then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end
    self:RecordItemLoot(itemID, count, link)
end)
