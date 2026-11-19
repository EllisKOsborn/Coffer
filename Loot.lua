local addonName, Coffer = ...

-- Item hyperlinks are never localized, so we pull the link straight out of the chat
-- message instead of pattern-matching the surrounding (locale-specific) sentence.
local LINK_PATTERN = "(|c%x%x%x%x%x%x%x%x|Hitem:.-|h%[.-%]|h|r)"

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

-- In a party/raid, CHAT_MSG_LOOT also fires for OTHER members' loot (e.g. "Jump High
-- receives loot: [Mote of Unstable Magic]."), not just your own ("You receive loot:
-- ..."). The event's sender argument identifies who actually looted it; if it's
-- populated and isn't you, this is someone else's drop and must not be counted.
Coffer:On("CHAT_MSG_LOOT", function(self, _, message, sender)
    local playerName = UnitName("player")
    if sender and sender ~= "" and sender ~= playerName and not sender:find("^" .. playerName .. "%-") then
        return
    end

    local link = message:match(LINK_PATTERN)
    if not link then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end
    local count = tonumber(message:match("|h|r%s-[Xx](%d+)")) or 1
    self:RecordItemLoot(itemID, count, link)
end)
