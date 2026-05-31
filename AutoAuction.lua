local AA = CreateFrame("Frame", "AutoAuctionFrame")

AA.scanQueue = {}
AA.currentItem = nil
AA.currentPage = 0
AA.lowestBuyout = nil
AA.isScanning = false
AA.waitingForEvent = false


AA.queryDelay = 1.0
AA.itemSwitchDelay = 1.5

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

-- 상태 완전 초기화 함수 (경매장 닫힘/스캔 정지 시 안전하게 상태 복구)
local function ResetScanState()
    AA.isScanning = false
    AA.scanQueue = {}
    AA.currentItem = nil
    AA.currentPage = 0
    AA.lowestBuyout = nil
    AA.waitingForEvent = false
    AA.pendingQuery = false
    AA.switchingItem = false
    AA.switchTime = 0
    AA.retryCount = 0
end

-- =========================
-- Build List
-- =========================
function AA.BuildItemList(self, specificItem)
    self.scanQueue = {}
    local seen = {}
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name = GetName(link)
                if name and not seen[name] then
                    seen[name] = true
                    if not specificItem or name == specificItem then
                        table.insert(self.scanQueue, name)
                    end
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
        BrowseName:SetText(self.currentItem or "")
        BrowseName:ClearFocus()
    end

    pcall(function()
        QueryAuctionItems(self.currentItem, nil, nil, 0, nil, nil, nil, true)
    end)

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

    local numBatch = GetNumAuctionItems("list") or 0
    local lowest = nil
    local buyoutCount = 0

    for i = 1, numBatch do
        local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", i)
        
        if name == self.currentItem then
            if buyoutPrice and buyoutPrice > 0 and count and count > 0 then
                buyoutCount = buyoutCount + 1
                local perUnit = buyoutPrice / count
                if not lowest or perUnit < lowest then
                    lowest = perUnit
                end
            end
        end
    end

    msg(self.currentItem.." | Total: "..numBatch.." | Buyout: "..buyoutCount)

    if lowest then
        local startPrice = floor(lowest * 0.82)
        AutoAuctionDB[self.currentItem] = { 
            buyout = floor(lowest), 
            start = startPrice,
            lastScan = time()
        }
        msg("✅ Saved: "..self.currentItem.." | Buyout: "..FormatMoney(lowest))
    else
        msg("❌ No buyout found: "..self.currentItem.." (Keeping old data)")
    end

    self:ScanNextItem()
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

    if self.waitingForEvent and self.timeSinceLastEvent > 12 then
        self.waitingForEvent = false
        self:ScanNextItem()
    end
end)

-- Direct Posting
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

-- Container Click Override

local origClick = ContainerFrameItemButton_OnClick
ContainerFrameItemButton_OnClick = function(button, ignoreShift)
    if button == "RightButton" and AuctionFrame and AuctionFrame:IsVisible() then
        local bag = this:GetParent():GetID()
        local slot = this:GetID()
        local link = GetContainerItemLink(bag, slot)
        local name = GetName(link)

        if name then
            PostAuctionDirectly(name)
            return
        end
    end
    origClick(button, ignoreShift)
end

-- Tooltip 
local tooltipHooked = false
local function HookTooltip()
    if tooltipHooked then return end
    tooltipHooked = true

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
            tooltip:AddLine("Current Buyout (1ea): "..FormatMoney(d.buyout))
            if stackCount and stackCount > 1 then
                tooltip:AddLine("Current Buyout (Total): |cFFFFFFFF"..FormatMoney(d.buyout * stackCount).."|r")
            end
        else
            tooltip:AddLine("|cFFFF0000No current price data|r")
        end
        tooltip:Show()
    end
end

AA:RegisterEvent("AUCTION_HOUSE_SHOW")
AA:RegisterEvent("AUCTION_HOUSE_CLOSED")
AA:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

AA:SetScript("OnEvent", function()
    if event == "AUCTION_HOUSE_SHOW" then
        msg("|cFF00FF00AutoAuction Loaded!|r")
        msg(" ")
        msg("|cFFFFFF00=== How to Use ===|r")
        msg("1. Full Scan: |cFFFFFF00/aascan|r")
        msg("2. Specific Item: |cFFFFFF00/aascan [Item Link]|r")
        msg("   (Drag item link into chat after /aascan)")
        msg(" ")
        msg("3. Post Item: Open AH → Right-click item in bags")
        msg(" ")
        msg("Note: Equippable items will NOT be equipped.")
        

        HookTooltip()
        for bag=0,4 do OpenBag(bag) end

    elseif event == "AUCTION_HOUSE_CLOSED" then
        if AA.isScanning then
            ResetScanState()
            msg("Scan stopped (AH closed).")
        else
            ResetScanState()
        end

    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        AA:OnAuctionUpdate()
    end
end)

function AA.StartScan(self, arg)
    if not AuctionFrame or not AuctionFrame:IsVisible() then
        msg("Open the Auction House first.")
        return
    end
    if self.isScanning then
        msg("Already scanning. Use |cFFFFFF00/aastop|r first.")
        return
    end

    local specific = nil
    if arg and arg ~= "" then
        specific = GetName(arg) or arg
        msg("Scanning specific item: |cFFFFFF00"..specific.."|r")
    else
        msg("Starting full scan...")
    end

    self:BuildItemList(specific)
    if table.getn(self.scanQueue) == 0 then
        msg("No items found.")
        return
    end
    self.isScanning = true
    self:ScanNextItem()
end

SLASH_AUTOAUCTION1 = "/aascan"
SlashCmdList["AUTOAUCTION"] = function(msg) AA:StartScan(msg) end

SLASH_AUTOSTOP1 = "/aastop"
SlashCmdList["AUTOSTOP"] = function()
    if AA.isScanning then
        ResetScanState()
        msg("Scan stopped.")
    else
        msg("No scan in progress.")
    end
end
