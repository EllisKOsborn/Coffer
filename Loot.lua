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
-- ..."). World of Warcraft: Forever gives every character a two-part name (e.g.
-- "Kabann Aethermere"), and it isn't confirmed that UnitName("player") and the chat
-- event's sender string always format that the same way - comparing them as plain
-- strings silently dropped the player's own loot entirely in testing. GUID is the one
-- identifier that can't be ambiguous regardless of any naming system, so that's tried
-- first; a fuzzy (substring, either direction) name match is kept only as a fallback
-- for whenever a GUID isn't available on the event.
local function IsOwnLoot(sender, guid)
    local playerGUID = UnitGUID("player")
    if guid and guid ~= "" then
        return playerGUID ~= nil and guid == playerGUID
    end
    if not sender or sender == "" then
        return true -- no sender info at all - this is "You receive loot: ..." (yourself)
    end
    local playerName = UnitName("player")
    if sender == playerName then
        return true
    end
    if playerName and (sender:find(playerName, 1, true) or playerName:find(sender, 1, true)) then
        return true
    end
    return false
end

Coffer:On("CHAT_MSG_LOOT", function(self, _, ...)
    local message, sender = ...
    local guid = select(12, ...)
    if not IsOwnLoot(sender, guid) then return end

    local link = message:match(LINK_PATTERN)
    if not link then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end
    local count = tonumber(message:match("|h|r%s-[Xx](%d+)")) or 1
    self:RecordItemLoot(itemID, count, link)
end)
