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

Coffer:On("CHAT_MSG_LOOT", function(self, _, message)
    local link = message:match(LINK_PATTERN)
    if not link then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end
    local count = tonumber(message:match("|h|r%s-[Xx](%d+)")) or 1
    self:RecordItemLoot(itemID, count, link)
end)
