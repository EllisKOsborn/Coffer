local addonName, Coffer = ...

-- Per-unit value (copper) of every item resolved this login, so runs can still be valued
-- after a session reset has wiped the session's own item table.
local priceMemo = {}

local function VendorPrice(itemID)
    local sellPrice = select(11, Coffer.GetItemInfo(itemID))
    return tonumber(sellPrice) or 0
end

-- TradeSkillMaster's market value, then Auctionator's last scan. Both optional.
local function AuctionPrice(itemID)
    if TSM_API and TSM_API.GetCustomPriceValue then
        local ok, value = pcall(TSM_API.GetCustomPriceValue, "dbmarket", "i:" .. itemID)
        if ok and tonumber(value) and value > 0 then return value end
    end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local ok, value = pcall(api.GetAuctionPriceByItemID, addonName, itemID)
        if ok and tonumber(value) and value > 0 then return value end
    end
end

-- "auction" (default): auction price, but never below vendor price, since a vendor
-- will always buy it - the same max-over-sources rule KiwiFarm uses. Soulbound items
-- have no auction price and fall back to vendor automatically.
-- "vendor": vendor price only, which is how Fojicore's panel values items.
local function Resolve(itemID)
    local vendor = VendorPrice(itemID)
    if Coffer.db.settings.valuation == "auction" then
        local auction = AuctionPrice(itemID)
        if auction and auction > vendor then
            return auction, "auction"
        end
    end
    return vendor, "vendor"
end

-- callback(valuePerUnit, source) runs once the client has the item's data, which for an
-- item never seen this login means asynchronously.
function Coffer:GetItemValue(itemID, callback)
    -- Runs outside Coffer's event dispatcher when the item loads asynchronously, so it
    -- isolates its own errors.
    local function deliver()
        local ok, err = pcall(function()
            local value, source = Resolve(itemID)
            priceMemo[itemID] = value
            callback(value, source)
        end)
        if not ok then
            self:ReportError("item value", err)
        end
    end
    if self.GetItemInfo(itemID) then
        deliver()
    elseif Item and Item.CreateFromItemID then
        Item:CreateFromItemID(itemID):ContinueOnItemLoad(deliver)
    end
end

function Coffer:ValueOf(itemID)
    local entry = self.db and self.db.session.items[itemID]
    return priceMemo[itemID] or (entry and entry.value) or 0
end

function Coffer:GetSessionItemsValue()
    if not self.db then return 0 end
    local total = 0
    for _, entry in pairs(self.db.session.items) do
        total = total + (entry.value or 0) * entry.count
    end
    return total
end

function Coffer:GetRunItemsValue(run)
    local total = 0
    for itemID, entry in pairs(run.items or {}) do
        total = total + self:ValueOf(itemID) * entry.count
    end
    return total
end

-- Re-values every item this session (and the run in progress) under the current
-- settings - after an auction-house scan, or a change of valuation mode. Finished runs
-- keep the value they were recorded with.
function Coffer:RepriceItems()
    if not self.db then return end
    for itemID, entry in pairs(self.db.session.items) do
        self:GetItemValue(itemID, function(value, source)
            entry.value, entry.source = value, source
            self:Changed()
        end)
    end
    local run = self.db.activeRun
    if run then
        for itemID in pairs(run.items) do
            self:GetItemValue(itemID, function() self:Changed() end)
        end
    end
end

function Coffer:SetValuation(mode)
    self.db.settings.valuation = mode
    self:RepriceItems()
end

-- Price addons (TSM, Auctionator) finish loading after Coffer, so values recorded
-- before they were ready get refreshed a few seconds into the session.
Coffer:OnReady(function(self)
    C_Timer.After(5, function() self:RepriceItems() end)
end)
