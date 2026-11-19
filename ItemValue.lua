local addonName, Coffer = ...

-- itemID -> { value = copper (per unit), source = "auction" | "vendor" }
Coffer.itemValueCache = {}

local function VendorPrice(itemID)
    local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    return sellPrice
end

-- Tries TradeSkillMaster's market-value db, then Auctionator's saved scan data.
-- Both are optional; neither being installed just means we fall back to vendor price.
local function AuctionValue(itemID)
    if TSM_API and TSM_API.GetCustomPriceValue then
        local ok, value = pcall(TSM_API.GetCustomPriceValue, "dbmarket", "i:" .. itemID)
        if ok and value and value > 0 then
            return value
        end
    end
    if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID then
        local ok, value = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, addonName, itemID)
        if ok and value and value > 0 then
            return value
        end
    end
    return nil
end

local function ResolveValue(itemID)
    local value = AuctionValue(itemID)
    if value then
        return value, "auction"
    end
    return VendorPrice(itemID) or 0, "vendor"
end

-- callback(valueCopper, source) is invoked once item data is available. Item data
-- that isn't cached client-side yet is requested and the callback fires asynchronously.
function Coffer:GetItemValue(itemID, callback)
    local cached = self.itemValueCache[itemID]
    if cached then
        callback(cached.value, cached.source)
        return
    end

    if GetItemInfo(itemID) then
        local value, source = ResolveValue(itemID)
        self.itemValueCache[itemID] = { value = value, source = source }
        callback(value, source)
        return
    end

    if Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(itemID)
        item:ContinueOnItemLoad(function()
            local value, source = ResolveValue(itemID)
            self.itemValueCache[itemID] = { value = value, source = source }
            callback(value, source)
        end)
    else
        C_Timer.After(1, function()
            self:GetItemValue(itemID, callback)
        end)
    end
end
