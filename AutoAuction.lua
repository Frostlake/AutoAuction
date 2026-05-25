-- AutoAuction.lua 0.07
local AA = CreateFrame("Frame", "AutoAuctionFrame")

AA.scanQueue = {}
AA.currentItem = nil
AA.currentPage = 0
AA.lowestBuyout = nil
AA.isScanning = false
AA.waitingForEvent = false

-- cfg
AA.queryDelay = 1.0
AA.pageDelay = 0.45
AA.timeout = 22.0
AA.maxRetries = 6
AA.itemSwitchDelay = 1.5

-- values
AA.timeSinceLastQuery = 0
AA.timeSinceLastEvent = 0
AA.pendingQuery = false
AA.retryCount = 0
AA.switchingItem = false
AA.switchTime = 0

AutoAuctionDB = AutoAuctionDB or {}

local function msg(t)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[AutoAuction]|r "..t)
end

local function FormatMoney(c)
    local g = floor(c / 10000)
    local s = floor(mod(c,10000)/100)
    local cc = mod(c,100)
    return g.."g "..s.."s "..cc.."c"
end

local function GetName(link)
    if not link then return nil end
    local _,_,n = string.find(link, "%[(.+)%]")
    return n
end

function AA.BuildItemList(self)
    self.scanQueue = {}
    local seen = {}
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name = GetName(link)
                if name and not seen[name] then
                    seen[name] = true
                    table.insert(self.scanQueue, name)
                end
            end
        end
    end
    msg("Items found: "..table.getn(self.scanQueue))
end

function AA.RequestQuery(self)
    self.pendingQuery = true
    self.timeSinceLastQuery = 0
end

function AA.DoQuery(self)
    if not CanSendAuctionQuery() then
        self:RequestQuery()
        return
    end
    if BrowseName then
        BrowseName:SetText(self.currentItem)
        BrowseName:ClearFocus()
    end
    QueryAuctionItems(self.currentItem, nil, nil, self.currentPage, nil, nil, nil, true)
    self.waitingForEvent = true
    self.timeSinceLastEvent = 0
end

function AA.ScanNextItem(self)
    if table.getn(self.scanQueue) == 0 then
        msg("|cFFFFAA00=== SCAN COMPLETE ===|r")
        PlaySound("AuctionWindowClose")
        PlaySound("TellMessage")
        self.isScanning = false
        return
    end
    self.currentItem = table.remove(self.scanQueue, 1)
    self.currentPage = 0
    self.lowestBuyout = nil
    self.retryCount = 0
    msg("Scanning: "..self.currentItem)
    self.switchingItem = true
    self.switchTime = 0
end

function AA.OnAuctionUpdate(self)
    if not self.waitingForEvent then return end
    self.waitingForEvent = false
    self.retryCount = 0

    local numBatch, total = GetNumAuctionItems("list")
    local lowest = nil
    local foundCount = 0
    local buyoutCount = 0

    for i = 1, numBatch do
        local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", i)
        
        if name == self.currentItem then
            foundCount = foundCount + 1
            if buyoutPrice and buyoutPrice > 0 and count and count > 0 then
                buyoutCount = buyoutCount + 1
                local perUnit = buyoutPrice / count
                if not lowest or perUnit < lowest then
                    lowest = perUnit
                end
            end
        end
    end

    msg(self.currentItem.." - Page "..(self.currentPage+1).." | Total: "..foundCount.." | Buyout: "..buyoutCount)

    local scanned = (self.currentPage + 1) * 50
    if scanned < total or numBatch == 50 then
        self.currentPage = self.currentPage + 1
        self.timeSinceLastQuery = -self.pageDelay
        self:RequestQuery()
    else
        if lowest then
            local startPrice = floor(lowest * 0.82)
            AutoAuctionDB[self.currentItem] = { 
                buyout = floor(lowest), 
                start = startPrice 
            }
            msg("✅ Saved: "..self.currentItem.." | Buyout: "..FormatMoney(lowest))
        else
            AutoAuctionDB[self.currentItem] = nil
            msg("❌ No buyout found for: "..self.currentItem)
        end
        self:ScanNextItem()
    end
end

AA:SetScript("OnUpdate", function()
    local elapsed = arg1
    local self = AA

    if not self.isScanning then return end

    self.timeSinceLastQuery = (self.timeSinceLastQuery or 0) + elapsed
    self.timeSinceLastEvent = (self.timeSinceLastEvent or 0) + elapsed

    if self.switchingItem then
        self.switchTime = (self.switchTime or 0) + elapsed
        if self.switchTime >= self.itemSwitchDelay then
            self.switchingItem = false
            self:RequestQuery()
        end
        return
    end

    if self.pendingQuery and not self.waitingForEvent and CanSendAuctionQuery() then
        if self.timeSinceLastQuery >= self.queryDelay then
            self.pendingQuery = false
            self:DoQuery()
        end
    end

    if self.waitingForEvent and self.timeSinceLastEvent > self.timeout then
        if self.retryCount < self.maxRetries then
            self.retryCount = self.retryCount + 1
            msg("Retry "..self.retryCount.." - "..self.currentItem)
            self:DoQuery()
        else
            msg("Skip (timeout): "..self.currentItem)
            self.waitingForEvent = false
            self:ScanNextItem()
        end
    end
end)

-- Direct Posting (Stack Total)
local function PostAuctionDirectly(name)
    local d = AutoAuctionDB[name]
    if not d then
        msg("No price data for: "..name)
        return
    end

    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link and GetName(link) == name then
                local _, stackCount = GetContainerItemInfo(bag, slot)
                
                ClearCursor()
                PickupContainerItem(bag, slot)
                ClickAuctionSellItemButton()
                ClearCursor()

                local totalBuyout = d.buyout * (stackCount or 1)
                local totalStart = d.start * (stackCount or 1)

                if StartPrice and StartPrice.SetText then StartPrice:SetText(totalStart) end
                if BuyoutPrice and BuyoutPrice.SetText then BuyoutPrice:SetText(totalBuyout) end

                if AuctionsLongAuctionButton then
                    AuctionsShortAuctionButton:SetChecked(0)
                    AuctionsMediumAuctionButton:SetChecked(0)
                    AuctionsLongAuctionButton:SetChecked(1)
                end

                StartAuction(totalStart, totalBuyout, 1440)

                msg("✅ Posted: "..name.." x"..(stackCount or 1))
                return
            end
        end
    end
end

local origClick = ContainerFrameItemButton_OnClick
ContainerFrameItemButton_OnClick = function(button, ignoreShift)
    if arg1 == "RightButton" and AuctionFrame and AuctionFrame:IsVisible() then
        local bag = this:GetParent():GetID()
        local slot = this:GetID()
        local link = GetContainerItemLink(bag, slot)
        local name = GetName(link)

        if name then
            UseContainerItem(bag, slot)
            PostAuctionDirectly(name)
            return
        end
    end
    origClick(button, ignoreShift)
end

-- Tooltip
local function HookTooltip()
    local orig = GameTooltip.SetBagItem
    GameTooltip.SetBagItem = function(tooltip, bag, slot)
        orig(tooltip, bag, slot)
        local link = GetContainerItemLink(bag, slot)
        local name = GetName(link)
        local _, stackCount = GetContainerItemInfo(bag, slot)

        tooltip:AddLine(" ")
        if name and AutoAuctionDB[name] then
            local d = AutoAuctionDB[name]
            tooltip:AddLine("|cFF00FF00[AutoAuction]|r")
            tooltip:AddLine("Buyout (1ea): "..FormatMoney(d.buyout))
            if stackCount and stackCount > 1 then
                tooltip:AddLine("Buyout (Total): |cFFFFFFFF"..FormatMoney(d.buyout * stackCount).."|r")
            end
        else
            tooltip:AddLine("|cFFFF0000No price data|r")
        end
        tooltip:Show()
    end
end

AA:RegisterEvent("AUCTION_HOUSE_SHOW")
AA:RegisterEvent("AUCTION_HOUSE_CLOSED")
AA:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

AA:SetScript("OnEvent", function()
    if event == "AUCTION_HOUSE_SHOW" then
        msg("AutoAuction Loaded.")
        msg("Use |cFFFFFF00/aascan|r")
        msg("Right-click item to auto post")
        HookTooltip()
        for bag=0,4 do OpenBag(bag) end

    elseif event == "AUCTION_HOUSE_CLOSED" then
        if AA.isScanning then
            AA.isScanning = false
            AA.scanQueue = {}
            msg("Scan stopped (AH closed).")
        end

    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        AA:OnAuctionUpdate()
    end
end)

function AA.StartScan(self)
    if not AuctionFrame or not AuctionFrame:IsVisible() then
        msg("Open the Auction House first.")
        return
    end
    if self.isScanning then
        msg("Already scanning.")
        return
    end
    self:BuildItemList()
    if table.getn(self.scanQueue) == 0 then
        msg("No items found.")
        return
    end
    self.isScanning = true
    self:ScanNextItem()
end

SLASH_AUTOAUCTION1 = "/aascan"
SlashCmdList["AUTOAUCTION"] = function() AA:StartScan() end

SLASH_AUTOSTOP1 = "/aastop"
SlashCmdList["AUTOSTOP"] = function()
    if AA.isScanning then
        AA.isScanning = false
        AA.scanQueue = {}
        msg("Scan stopped.")
    end
end
