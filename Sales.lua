local addonName, Coffer = ...

-- Selling and crafting convert items. A looted item is counted at its value while you
-- hold it; once it's sold or used in a craft it leaves that tally, so it's counted once:
--   sold to a vendor or on the auction house -> its sale gold counts instead
--   used as a crafting material              -> the crafted item's value counts instead
-- Selling or crafting with things you didn't loot this session is simply a gain.

-- Hooks run outside Coffer's event dispatcher, so they isolate their own errors.
local function Safe(context, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then Coffer:ReportError(context, err) end
    end
end

-- ---------------------------------------------------------------------------
-- Auction house sales (and outbid refunds), from the mailbox
-- ---------------------------------------------------------------------------
-- Auction proceeds arrive by mail. The mail's invoice says what sold, how many, and for
-- how much, which tells a sale apart from gold your alts mailed you (not income). The
-- inbox is snapshotted whenever it changes, so the mail a Take/AutoLoot call refers to is
-- known even once the client starts removing it.

local inbox = {}
local OUTBID = Coffer:PatternFromTemplate(AUCTION_OUTBID_MAIL_SUBJECT, true)

local function SnapshotInbox()
    wipe(inbox)
    if not GetInboxNumItems or not GetInboxHeaderInfo then return end
    for i = 1, (GetInboxNumItems()) or 0 do
        local _, _, sender, subject, money = GetInboxHeaderInfo(i)
        local invoiceType, itemName, count
        if GetInboxInvoiceInfo then
            local info = { GetInboxInvoiceInfo(i) }
            invoiceType, itemName, count = info[1], info[2], info[10]
        end
        if Coffer:Readable(sender, subject, money, invoiceType, itemName, count) then
            inbox[i] = {
                subject = subject,
                money = tonumber(money) or 0,
                invoiceType = invoiceType,
                itemName = itemName,
                count = tonumber(count) or 1,
            }
        end
    end
end
Coffer:On("MAIL_SHOW", SnapshotInbox)
Coffer:On("MAIL_INBOX_UPDATE", SnapshotInbox)

function Coffer:FindSessionItemByName(name)
    if not name then return nil end
    for itemID in pairs(self.db.session.items) do
        if self.GetItemInfo(itemID) == name then return itemID end
    end
end

local function MoneyCollected(index)
    local mail = inbox[index]
    if not mail or mail.collected or mail.money <= 0 or not Coffer.db then return end
    mail.collected = true
    if mail.invoiceType == "seller" then
        local session = Coffer.db.session
        session.ahSales = session.ahSales + mail.money
        Coffer:TrackRunIncome("sold", mail.money)
        local itemID = Coffer:FindSessionItemByName(mail.itemName)
        if itemID then
            Coffer:ItemsLeftBags(itemID, mail.count)
        end
        Coffer:Changed()
    elseif OUTBID and type(mail.subject) == "string" and mail.subject:match(OUTBID) then
        -- your bid comes back: it was counted as spent when you placed it
        local session = Coffer.db.session
        session.spent = math.max(0, session.spent - mail.money)
        Coffer:Changed()
    end
    -- any other gold in the mail (from your alts, other players) isn't farming income
end

if hooksecurefunc then
    if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", Safe("mail", MoneyCollected)) end
    if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", Safe("mail", MoneyCollected)) end
end

-- ---------------------------------------------------------------------------
-- Items leaving your bags: vendor sales and crafting materials
-- ---------------------------------------------------------------------------
-- Rather than hooking every way of selling (right-click, dragging onto the vendor, the
-- sell-junk button, auto-sell addons), bag contents are compared after each change. An
-- item that left your bags while a vendor was open was sold; one that left around a
-- craft was used as a material. Anything else (banked, mailed, posted on the auction
-- house, eaten) stays counted - you still have its value, or will once it sells.

local C = C_Container
local NumSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
local LAST_BAG = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)

local function SlotItem(bag, slot)
    if C and C.GetContainerItemInfo then
        local info = C.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount end
    elseif GetContainerItemInfo then
        local _, count, _, _, _, _, _, _, _, itemID = GetContainerItemInfo(bag, slot)
        return itemID, count
    end
end

local function ScanBags()
    local counts = {}
    if not NumSlots then return counts end
    for bag = 0, LAST_BAG do
        for slot = 1, (NumSlots(bag) or 0) do
            local itemID, count = SlotItem(bag, slot)
            if itemID then
                counts[itemID] = (counts[itemID] or 0) + (count or 1)
            end
        end
    end
    return counts
end

local SALE_GRACE = 2   -- seconds after a vendor closes that a sale can still land
local CRAFT_WINDOW = 3 -- seconds around a "You create" message that materials count

local snapshot
local merchantClosedAt
local craftUntil = 0
local recent = {} -- unexplained losses, in case a craft announces itself a moment later

Coffer:On("MERCHANT_CLOSED", function() merchantClosedAt = time() end)
local PIT = Enum and Enum.PlayerInteractionType
Coffer:On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, _, kind)
    if PIT and kind == PIT.Merchant then merchantClosedAt = time() end
end)

local function ItemLost(itemID, lost, now)
    local atVendor = Coffer:IsWindowOpen("merchant")
        or (merchantClosedAt and now - merchantClosedAt <= SALE_GRACE)
    if atVendor or now <= craftUntil then
        Coffer:ItemsLeftBags(itemID, lost)
    else
        recent[#recent + 1] = { id = itemID, count = lost, time = now }
    end
end

local function BagsChanged()
    if not Coffer.db then return end
    local now = time()
    local current = ScanBags()
    if snapshot then
        for itemID, before in pairs(snapshot) do
            local lost = before - (current[itemID] or 0)
            if lost > 0 then ItemLost(itemID, lost, now) end
        end
    end
    snapshot = current
    for i = #recent, 1, -1 do
        if now - recent[i].time > CRAFT_WINDOW then table.remove(recent, i) end
    end
end
Coffer:On("BAG_UPDATE_DELAYED", BagsChanged)
Coffer:On("PLAYER_ENTERING_WORLD", function()
    if not snapshot then snapshot = ScanBags() end
end)

-- Called by Loot.lua on "You create: ...": materials that just left your bags, or leave
-- in the next few seconds, were used up by the craft.
function Coffer:NoteCraft(productID)
    local now = time()
    craftUntil = now + CRAFT_WINDOW
    for _, loss in ipairs(recent) do
        if loss.id ~= productID and now - loss.time <= CRAFT_WINDOW then
            self:ItemsLeftBags(loss.id, loss.count)
        end
    end
    wipe(recent)
end
