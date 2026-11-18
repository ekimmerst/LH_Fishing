local ADDON = ...
local Fishing = {}
LH_Fishing = Fishing

local LURES = {
    {6533, 100, 100}, {6532, 75, 100}, {7307, 75, 100},
    {6811, 50, 50}, {6530, 50, 50}, {6529, 25, 0},
}
local LURE_NAMES = {
    [6533] = "Aquadynamic Fish Attractor", [6532] = "Bright Baubles",
    [7307] = "Flesh Eating Worm", [6811] = "Aquadynamic Fish Lens",
    [6530] = "Nightcrawlers", [6529] = "Shiny Bauble",
}
local LURE_ENCHANT_BONUS = {[263] = 25, [264] = 50, [265] = 75, [266] = 100}
local LURE_ITEM_BONUS = {
    [6533] = 100, [6532] = 75, [7307] = 75,
    [6811] = 50, [6530] = 50, [6529] = 25,
}
local frame, locationText, totalText, vendorTotalText, rateText, lureReminder
local scrollChild, timerText, headings, headerLabels, sumRow, measureText
local rows, active, cast, bindingOwner = {}, false
local tabs, activeTab, currentSession = {}, "session"
local channeling, lastLoot = false, 0
local channelStoppedAt = 0
local bagCounts, pendingFishLootUntil, pendingDirect, pendingBag = {}, 0, {}, {}
local castAt, retryCast = 0, false
local EARLY_RECAST_SECONDS = 2
local elapsed, currentLocation, pendingBindings = 0
local refreshElapsed, lureCheckElapsed, bagScanElapsed = 0, 0, 0
local knownLureID, knownEnchantID, knownPoleID, pendingLureID, pendingLureAt, lureStatusKey

local function SessionPlace(session, key)
    local place = session.places[key]
    if not place then
        place = {items = {}, total = 0, seconds = 0}
        session.places[key] = place
    end
    return place
end

local function SessionTime()
    if not currentSession or not currentSession.firstCastAt then return "00:00:00" end
    local seconds = math.max(0, (currentSession.endedAt or time()) - currentSession.firstCastAt)
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function Combat() return InCombatLockdown and InCombatLockdown() end
local function ItemCount(id)
    local f = C_Item and C_Item.GetItemCount or GetItemCount
    return f and (f(id) or 0) or 0
end
local function CountBags()
    local slots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
    local itemID = C_Container and C_Container.GetContainerItemID or GetContainerItemID
    local itemInfo = C_Container and C_Container.GetContainerItemInfo or GetContainerItemInfo
    local counts = {}
    local missingInfo = {}
    if not slots or not itemInfo then return counts end
    for bag = 0, 4 do
        for slot = 1, slots(bag) or 0 do
            local id = itemID and itemID(bag, slot)
            local info, count = itemInfo(bag, slot)
            if type(info) == "table" then
                id = id or info.itemID
                count = info.stackCount
            end
            if id and type(count) == "number" then
                counts[id] = (counts[id] or 0) + count
            elseif id then
                missingInfo[id] = true
            end
        end
    end
    for id in pairs(missingInfo) do counts[id] = ItemCount(id) end
    return counts
end
local function FishingSkill()
    if not GetProfessions or not GetProfessionInfo then return 0, nil end
    for i = 1, 6 do
        local index = select(i, GetProfessions())
        if index then
            local name, _, skill, _, _, _, line = GetProfessionInfo(index)
            if line == 356 then return skill or 0, name end
        end
    end
    return 0, nil
end
local function FishingName()
    local _, name = FishingSkill()
    return name or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(7620)) or "Fishing"
end
local function PoleEquipped()
    local id = GetInventoryItemID and GetInventoryItemID("player", 16)
    local instant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    if not id or not instant then return false end
    local _, _, _, _, _, classID, subclassID = instant(id)
    return classID == 2 and subclassID == 20
end
local function BestLure()
    local skill = FishingSkill()
    for _, entry in ipairs(LURES) do
        if skill >= entry[3] and ItemCount(entry[1]) > 0 then return entry end
    end
end
local function LureInBags()
    for _, entry in ipairs(LURES) do
        if ItemCount(entry[1]) > 0 then return true end
    end
    return false
end
local function HasLure()
    if not GetWeaponEnchantInfo then return false end
    local has = GetWeaponEnchantInfo()
    return has and true or false
end
local function UpdateLureStatus()
    local has, milliseconds, _, enchantID
    if GetWeaponEnchantInfo then
        has, milliseconds, _, enchantID = GetWeaponEnchantInfo()
    end
    local poleID = GetInventoryItemID and GetInventoryItemID("player", 16)
    if knownPoleID ~= poleID then knownLureID, knownEnchantID, knownPoleID = nil, nil, poleID end
    if pendingLureID and GetTime() - (pendingLureAt or 0) > 5 then pendingLureID = nil end
    local key, message
    if has then
        if knownEnchantID and enchantID and knownEnchantID ~= enchantID then
            knownLureID, knownEnchantID = nil, nil
        end
        if pendingLureID then
            local expected = ({[6529] = 263, [6530] = 264, [6811] = 264,
                [6532] = 265, [7307] = 265, [6533] = 266})[pendingLureID]
            if not enchantID or enchantID == expected then
                knownLureID, knownEnchantID = pendingLureID, enchantID
            end
            pendingLureID = nil
        end
        local name = knownLureID and LURE_NAMES[knownLureID]
            or (enchantID == 263 and "Shiny Bauble")
            or (enchantID == 266 and "Aquadynamic Fish Attractor")
            or "Fishing lure"
        local bonus = LURE_ENCHANT_BONUS[enchantID] or LURE_ITEM_BONUS[knownLureID]
        local description = bonus and string.format("%s (+%d Fishing)", name, bonus) or name
        key = "active:" .. description
        if type(milliseconds) == "number" and milliseconds > 0 then
            local seconds = math.ceil(milliseconds / 1000)
            message = string.format("%s  %d:%02d remaining", description,
                math.floor(seconds / 60), seconds % 60)
        else
            message = description
        end
        lureReminder:SetTextColor(0.55, 0.82, 1, 1)
    elseif LH_FishingDB.autoLure and not LureInBags() then
        knownLureID, knownEnchantID = nil, nil
        key, message = "missing", "No fishing lure in your bags."
        lureReminder:SetTextColor(1, 0.75, 0.15, 1)
    else
        knownLureID, knownEnchantID = nil, nil
    end
    lureReminder:SetShown(message ~= nil)
    if message then lureReminder:SetText(message) end
    local changed = key ~= lureStatusKey
    lureStatusKey = key
    return changed, message ~= nil
end
local function Place()
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local zone = GetRealZoneText and GetRealZoneText() or "Unknown waters"
    local sub = GetMinimapZoneText and GetMinimapZoneText() or ""
    local key = tostring(map or zone) .. ":" .. sub
    return key, sub ~= "" and sub ~= zone and (zone .. " - " .. sub) or zone
end
local function Water()
    local key, name = Place()
    currentLocation = key
    local water = LH_FishingDB.waters[key]
    if not water then
        water = {name = name, items = {}, total = 0}
        LH_FishingDB.waters[key] = water
    end
    water.name = name
    return water
end
local function Money(copper)
    if type(copper) ~= "number" then return "-" end
    copper = math.floor(math.max(0, copper))
    local gold, silver, bronze = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = ("|cffffbf26%dg|r"):format(gold) end
    if silver > 0 then parts[#parts + 1] = ("|cffc0c0c0%ds|r"):format(silver) end
    if bronze > 0 or #parts == 0 then parts[#parts + 1] = ("|cffcd7f32%dc|r"):format(bronze) end
    return table.concat(parts, " ")
end
local function Price(id)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not api or not api.GetAuctionPriceByItemID then return nil end
    local ok, value = pcall(api.GetAuctionPriceByItemID, ADDON, id)
    return ok and type(value) == "number" and value or nil
end
local function Text(parent, size, anchor, x, y, width)
    local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size)
    line:SetPoint(anchor, parent, anchor, x, y)
    line:SetWidth(width)
    line:SetJustifyH("LEFT")
    return line
end
local function SetCell(cell, parent, x, width)
    cell:ClearAllPoints()
    cell:SetPoint("LEFT", parent, "LEFT", x, 0)
    cell:SetWidth(width)
end
local function MeasuredWidth(value)
    measureText:SetText(value)
    return math.ceil(measureText:GetStringWidth() or 0) + 4
end
local function Refresh()
    if not frame then return end
    local water = Water()
    timerText:SetText(SessionTime())
    local showReminder = lureReminder:IsShown()
    local key = currentLocation
    local historyItems, historyTotal, historySeconds = {}, water.total or 0, 0
    local overallSeconds = LH_FishingDB.fishingSeconds or 0
    local currentPlace = currentSession and currentSession.places[key]
    for id, count in pairs(water.items) do
        local previous = count - (currentPlace and (currentPlace.items[id] or 0) or 0)
        if previous > 0 then historyItems[id] = previous end
    end
    historyTotal = math.max(0, historyTotal - (currentPlace and currentPlace.total or 0))
    for _, session in ipairs(LH_FishingDB.sessions) do
        overallSeconds = overallSeconds + (session.seconds or 0)
        local place = session.places and session.places[key]
        if session ~= currentSession and place then
            historySeconds = historySeconds + (place.seconds or 0)
        end
    end
    tabs.session.text:SetText("Session")
    tabs.history.text:SetText("History here")
    tabs.overall.text:SetText("History overall")
    for tabKey, tab in pairs(tabs) do
        local selected = tabKey == activeTab
        tab.text:SetTextColor(selected and 1 or 0.7, selected and 0.82 or 0.7, selected and 0.38 or 0.7)
        tab.underline:SetShown(selected)
    end
    local visited = water.last and date("%Y-%m-%d %H:%M", water.last) or "Never"
    locationText:SetText(water.name .. "  |  Last fished: " .. visited)
    local visibleItems
    if activeTab == "session" then
        visibleItems = currentSession and currentSession.items or {}
    elseif activeTab == "history" then
        visibleItems = historyItems
    else
        visibleItems = LH_FishingDB.items
    end
    local chanceItems = visibleItems
    local chanceTotal = activeTab == "history" and historyTotal or 0
    headerLabels[3]:SetText(activeTab == "session" and "Session %"
        or activeTab == "history" and "Here %" or "Overall %")
    local entries = {}
    for id, count in pairs(visibleItems) do
        if count > 0 then
            entries[#entries + 1] = {id = id, count = count}
            if activeTab ~= "history" then chanceTotal = chanceTotal + count end
        end
    end
    table.sort(entries, function(a, b) return a.count == b.count and a.id < b.id or a.count > b.count end)
    local auctionTotal, vendorTotal, auctionUnitTotal, vendorUnitTotal = 0, 0, 0, 0
    local auctionKnown, vendorKnown, quantityTotal = false, false, 0
    local widths = {190, 30, 70, 62, 62, 78, 78}
    for column, label in ipairs(headerLabels) do
        widths[column] = math.max(widths[column], MeasuredWidth(label:GetText()))
    end
    for index, entry in ipairs(entries) do
        local row = rows[index]
        if not row then
            row = CreateFrame("Frame", nil, scrollChild)
            row:SetSize(600, 21)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * 21)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(17, 17)
            row.icon:SetPoint("LEFT", 0, 0)
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if not self.itemID or not GameTooltip then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if GameTooltip.SetItemByID then
                    GameTooltip:SetItemByID(self.itemID)
                else
                    GameTooltip:SetHyperlink("item:" .. self.itemID)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function(self)
                if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
            end)
            row.cells = {}
            for column = 1, 7 do row.cells[column] = Text(row, 11, "LEFT", 0, 0, 10) end
            rows[index] = row
        end
        local name, _, _, _, _, _, _, _, _, icon, sellPrice = GetItemInfo(entry.id)
        row.itemID = entry.id
        row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local localCount = chanceItems[entry.id] or 0
        local auctionPrice = Price(entry.id)
        if type(sellPrice) ~= "number" and C_Item and C_Item.GetItemInfo then
            sellPrice = select(11, C_Item.GetItemInfo(entry.id))
        end
        local values = {
            name or ("Item %d"):format(entry.id), tostring(entry.count),
            chanceTotal > 0 and string.format("%.1f%%", 100 * localCount / chanceTotal) or "-",
            Money(auctionPrice), Money(auctionPrice and auctionPrice * entry.count),
            Money(sellPrice), Money(type(sellPrice) == "number" and sellPrice * entry.count or nil),
        }
        for column, value in ipairs(values) do
            row.cells[column]:SetText(value)
            if column == 1 then
                widths[column] = math.max(widths[column], math.min(205, MeasuredWidth(value)))
            else
                widths[column] = math.max(widths[column], MeasuredWidth(value))
            end
        end
        quantityTotal = quantityTotal + entry.count
        if auctionPrice then
            auctionTotal = auctionTotal + auctionPrice * entry.count
            auctionUnitTotal = auctionUnitTotal + auctionPrice
            auctionKnown = true
        end
        if type(sellPrice) == "number" then
            vendorTotal = vendorTotal + sellPrice * entry.count
            vendorUnitTotal = vendorUnitTotal + sellPrice
            vendorKnown = true
        end
        row:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    local sumValues = {
        "Total", tostring(quantityTotal), "",
        Money(auctionKnown and auctionUnitTotal or nil), Money(auctionKnown and auctionTotal or nil),
        Money(vendorKnown and vendorUnitTotal or nil), Money(vendorKnown and vendorTotal or nil),
    }
    for column, value in ipairs(sumValues) do
        sumRow.cells[column]:SetText(value)
        if column > 1 then widths[column] = math.max(widths[column], MeasuredWidth(value)) end
    end
    local offsets = {21}
    for column = 2, 7 do offsets[column] = offsets[column - 1] + widths[column - 1] + 6 end
    local tableWidth = offsets[7] + widths[7] + 4
    totalText:SetText("AH total (priced): " .. Money(auctionKnown and auctionTotal or nil))
    vendorTotalText:SetText("Vendor total: " .. Money(vendorKnown and vendorTotal or nil))
    local duration
    if activeTab == "session" then
        duration = currentSession and currentSession.firstCastAt
            and math.max(0, time() - currentSession.firstCastAt) or 0
    elseif activeTab == "history" then
        duration = historySeconds
    else
        duration = overallSeconds
    end
    rateText:SetText("Estimated AH per hour: " .. Money(auctionKnown and duration >= 60 and auctionTotal * 3600 / duration or nil))
    local footerWidths = {
        MeasuredWidth(totalText:GetText()), MeasuredWidth(vendorTotalText:GetText()), MeasuredWidth(rateText:GetText()),
    }
    local reminderWidth = showReminder and MeasuredWidth(lureReminder:GetText()) or 0
    local frameWidth = math.max(690, tableWidth + 42,
        footerWidths[1] + footerWidths[2] + footerWidths[3] + 48 + (showReminder and reminderWidth + 12 or 0))
    if not Combat() then
        frame:SetWidth(frameWidth)
        frame:SetHeight(117 + (#entries + 1) * 21 + 35)
    end
    lureReminder:SetWidth(math.max(1, reminderWidth))
    headings:SetWidth(tableWidth)
    scrollChild:SetWidth(tableWidth)
    locationText:SetWidth(frame:GetWidth() - 24)
    for column, label in ipairs(headerLabels) do SetCell(label, headings, offsets[column], widths[column]) end
    for _, row in ipairs(rows) do
        row:SetWidth(tableWidth)
        for column, cell in ipairs(row.cells) do SetCell(cell, row, offsets[column], widths[column]) end
    end
    sumRow:SetWidth(tableWidth)
    sumRow:ClearAllPoints()
    sumRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -#entries * 21)
    for column, cell in ipairs(sumRow.cells) do SetCell(cell, sumRow, offsets[column], widths[column]) end
    scrollChild:SetHeight((#entries + 1) * 21)
    local footers = {totalText, vendorTotalText, rateText}
    local x = 12
    for index, footer in ipairs(footers) do
        footer:ClearAllPoints()
        footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 12)
        footer:SetWidth(footerWidths[index])
        footer:SetJustifyH("LEFT")
        x = x + footerWidths[index] + 12
    end
end

local function SelectTab(key)
    if activeTab == key then return end
    activeTab = key
    Refresh()
end

local function RestorePosition()
    frame:ClearAllPoints()
    local p = LH_FishingDB.position
    if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end
local function SavePosition()
    local x, y = frame:GetCenter()
    if not x then return end
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    LH_FishingDB.position = {x = x * scale, y = y * scale}
    RestorePosition()
end
local function BobberReady()
    if not UnitGUID then return false end
    local ok, guid = pcall(UnitGUID, "softinteract")
    return ok and type(guid) == "string" and guid:match("^GameObject%-%d+%-%d+%-%d+%-%d+%-35591%-") ~= nil
end
local function KeyHeld()
    local ok, held = pcall(IsKeyDown, "SPACE")
    return ok and held
end
local function ApplyBinding()
    if Combat() or not frame then pendingBindings = true; return end
    if KeyHeld() then pendingBindings = true; return end
    pendingBindings = false
    ClearOverrideBindings(bindingOwner)
    if not active then return end
    -- The bobber can be interacted with only when it is the player's soft target.
    -- A misplaced bobber uses the retry macro on the same Space press.
    if channeling and not retryCast and GetTime() - castAt >= EARLY_RECAST_SECONDS and BobberReady() then
        SetOverrideBinding(bindingOwner, true, "SPACE", "INTERACTTARGET")
    else
        local macro = (channeling and "/stopcasting\n/cast " or "/cast ") .. FishingName()
        if not channeling and LH_FishingDB.autoLure and not HasLure() then
            local lureInfo = BestLure()
            if lureInfo then macro = ("/use item:%d\n/use 16"):format(lureInfo[1]) end
        end
        cast:SetAttribute("macrotext", macro)
        SetOverrideBindingClick(bindingOwner, true, "SPACE", "LH_FishingCastButton", "LeftButton")
    end
    SetOverrideBinding(bindingOwner, true, "SHIFT-SPACE", "JUMP")
end
local function StartSession()
    local previous = LH_FishingDB.sessions[#LH_FishingDB.sessions]
    if previous and not previous.endedAt then previous.endedAt = time() end
    local session = {startedAt = time(), items = {}, places = {}, casts = 0, seconds = 0}
    LH_FishingDB.sessions[#LH_FishingDB.sessions + 1] = session
    currentSession = session
    activeTab = "session"
end
local function UpdateActive()
    local wanted = PoleEquipped()
    if wanted == active then return end
    active = wanted
    if active then
        bagCounts = CountBags()
        pendingLureID = nil
        pendingFishLootUntil, pendingDirect, pendingBag = 0, {}, {}
        castAt, channelStoppedAt = 0, 0
        StartSession()
    elseif currentSession then
        currentSession.endedAt = time()
        currentSession = nil
        pendingFishLootUntil, pendingDirect, pendingBag = 0, {}, {}
        castAt, channelStoppedAt = 0, 0
        pendingLureID = nil
    end
    if frame then frame:SetShown(active) end
    if not active then channeling, retryCast = false, false end
    ApplyBinding()
    if active then Refresh() end
end
local function CreateUI()
    LH_FishingDB = type(LH_FishingDB) == "table" and LH_FishingDB or {}
    LH_FishingDB.items = type(LH_FishingDB.items) == "table" and LH_FishingDB.items or {}
    LH_FishingDB.waters = type(LH_FishingDB.waters) == "table" and LH_FishingDB.waters or {}
    LH_FishingDB.sessions = type(LH_FishingDB.sessions) == "table" and LH_FishingDB.sessions or {}
    LH_FishingDB.locked = LH_FishingDB.locked == true
    LH_FishingDB.autoLure = LH_FishingDB.autoLure ~= false
    LH_LayoutProfiles:Register(ADDON, LH_FishingDB, LH_FishingDB, {"position", "locked", "autoLure"})
    bindingOwner = CreateFrame("Frame")
    cast = CreateFrame("Button", "LH_FishingCastButton", UIParent, "SecureActionButtonTemplate")
    cast:SetSize(1, 1)
    cast:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT")
    cast:SetAlpha(0)
    cast:EnableMouse(false)
    cast:RegisterForClicks("AnyUp", "AnyDown")
    cast:SetAttribute("useOnKeyDown", false)
    cast:SetAttribute("type", "macro")
    cast:SetAttribute("macrotext", "/cast " .. FishingName())
    frame = CreateFrame("Frame", "LH_FishingFrame", UIParent, "BackdropTemplate")
    frame:SetSize(690, 173)
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2}})
    frame:SetBackdropColor(0, 0, 0, 0.5)
    frame:SetBackdropBorderColor(0.65, 0.59, 0.45, 1)
    frame:SetScript("OnDragStart", function(self) if not LH_FishingDB.locked then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    local title = Text(frame, 14, "TOPLEFT", 12, -12, 220)
    title:SetText("LH Fishing")
    title:SetTextColor(1, 0.75, 0.15, 1)
    timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    timerText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
    timerText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -9)
    timerText:SetWidth(200)
    timerText:SetJustifyH("RIGHT")
    timerText:SetTextColor(1, 0.75, 0.15, 1)
    timerText:SetText("00:00:00")
    locationText = Text(frame, 11, "TOPLEFT", 12, -40, 666)
    measureText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    measureText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 11)
    for _, option in ipairs({{"session", 12}, {"history", 165}, {"overall", 318}}) do
        local tab = CreateFrame("Button", nil, frame)
        tab:SetSize(147, 26)
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", option[2], -62)
        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.text:SetPoint("LEFT", 4, 0)
        tab.text:SetPoint("RIGHT", -4, 0)
        tab.text:SetWordWrap(false)
        tab.underline = tab:CreateTexture(nil, "ARTWORK")
        tab.underline:SetColorTexture(0.75, 0.56, 0.16, 1)
        tab.underline:SetPoint("BOTTOMLEFT", 2, 0)
        tab.underline:SetPoint("BOTTOMRIGHT", -2, 0)
        tab.underline:SetHeight(2)
        local key = option[1]
        tab:SetScript("OnClick", function() SelectTab(key) end)
        tabs[key] = tab
    end
    headings = CreateFrame("Frame", nil, frame)
    headings:SetSize(648, 16)
    headings:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -97)
    headerLabels = {}
    for _, column in ipairs({
        {"Item", 21, 190}, {"Qty", 217, 30}, {"Here", 253, 40},
        {"AH Each", 299, 62}, {"AH Sum", 367, 62},
        {"Vendor Each", 435, 78}, {"Vendor Sum", 519, 78},
    }) do
        local label = Text(headings, 10, "LEFT", column[2], 0, column[3])
        label:SetWordWrap(false)
        label:SetText(column[1])
        headerLabels[#headerLabels + 1] = label
    end
    scrollChild = CreateFrame("Frame", nil, frame)
    scrollChild:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -117)
    scrollChild:SetWidth(648)
    scrollChild:SetHeight(21)
    sumRow = CreateFrame("Frame", nil, scrollChild)
    sumRow:SetSize(648, 21)
    sumRow.cells = {}
    for column = 1, 7 do
        local cell = Text(sumRow, 11, "LEFT", 0, 0, 10)
        cell:SetTextColor(1, 0.75, 0.15, 1)
        sumRow.cells[column] = cell
    end
    local separator = sumRow:CreateTexture(nil, "ARTWORK")
    separator:SetColorTexture(0.65, 0.59, 0.45, 0.7)
    separator:SetPoint("TOPLEFT", sumRow, "TOPLEFT", 0, 0)
    separator:SetPoint("TOPRIGHT", sumRow, "TOPRIGHT", 0, 0)
    separator:SetHeight(1)
    totalText = Text(frame, 11, "BOTTOMLEFT", 12, 12, 200)
    vendorTotalText = Text(frame, 11, "BOTTOMLEFT", 220, 12, 160)
    rateText = Text(frame, 11, "BOTTOMLEFT", 392, 12, 250)
    lureReminder = Text(frame, 11, "BOTTOMRIGHT", -12, 12, 200)
    lureReminder:SetJustifyH("RIGHT")
    lureReminder:SetTextColor(1, 0.75, 0.15, 1)
    lureReminder:SetText("No fishing lure in your bags.")
    lureReminder:Hide()
    RestorePosition()
    frame:Hide()
    UpdateActive()
end

function Fishing:IsLocked() return LH_FishingDB and LH_FishingDB.locked end
function Fishing:SetLocked(value)
    if not LH_FishingDB then return end
    LH_FishingDB.locked = value == true
    if self.RefreshSettings then self:RefreshSettings() end
end
function Fishing:IsAutoLureEnabled()
    return LH_FishingDB and LH_FishingDB.autoLure ~= false
end
function Fishing:SetAutoLureEnabled(value)
    if not LH_FishingDB then return end
    LH_FishingDB.autoLure = value == true
    ApplyBinding()
    if frame then Refresh() end
    if self.RefreshSettings then self:RefreshSettings() end
end
function Fishing:ResetPosition()
    if not frame then return end
    LH_FishingDB.position = nil
    RestorePosition()
end
function Fishing:ResetHistory()
    if not LH_FishingDB then return end
    LH_FishingDB.items = {}
    LH_FishingDB.waters = {}
    LH_FishingDB.sessions = {}
    LH_FishingDB.fishingSeconds = nil
    currentSession = nil
    lastLoot = 0
    bagCounts = CountBags()
    pendingFishLootUntil, pendingDirect, pendingBag = 0, {}, {}
    if not channeling then castAt = 0 end
    channelStoppedAt = 0
    if active then
        StartSession()
        if channeling then
            currentSession.firstCastAt = time()
            local key = Place()
            SessionPlace(currentSession, key)
        end
    else
        activeTab = "session"
    end
    if frame then Refresh() end
end

local function RecordCatch(id, count)
    if not active or not id or count <= 0 then return end
    local water = Water()
    water.last = time()
    LH_FishingDB.items[id] = (LH_FishingDB.items[id] or 0) + count
    water.items[id] = (water.items[id] or 0) + count
    water.total = water.total + count
    if currentSession then
        local place = SessionPlace(currentSession, currentLocation)
        currentSession.items[id] = (currentSession.items[id] or 0) + count
        place.items[id] = (place.items[id] or 0) + count
        place.total = place.total + count
    end
end
local function ScanBagChanges()
    local current = CountBags()
    local found = false
    if active then
        for _, entry in ipairs(LURES) do
            local id = entry[1]
            if (current[id] or 0) < (bagCounts[id] or 0) then
                pendingLureID, pendingLureAt = id, GetTime()
                break
            end
        end
        local recentCast = castAt > 0 and GetTime() - castAt <= 45
        if recentCast or GetTime() <= pendingFishLootUntil then
            for id, count in pairs(current) do
                local gained = count - (bagCounts[id] or 0)
                if gained > 0 then
                    local alreadyCounted = math.min(gained, pendingDirect[id] or 0)
                    pendingDirect[id] = (pendingDirect[id] or 0) - alreadyCounted
                    gained = gained - alreadyCounted
                    if gained > 0 then
                        RecordCatch(id, gained)
                        pendingBag[id] = (pendingBag[id] or 0) + gained
                        found = true
                    end
                end
            end
        end
    end
    bagCounts = current
    return found
end

local events = CreateFrame("Frame")
for _, event in ipairs({"ADDON_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "UNIT_INVENTORY_CHANGED",
    "BAG_UPDATE_DELAYED", "SKILL_LINES_CHANGED", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UI_INFO_MESSAGE", "UI_ERROR_MESSAGE",
    "LOOT_READY", "LOOT_OPENED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT"}) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, a, b, c)
    if event == "ADDON_LOADED" then if a == ADDON then CreateUI() end; return end
    if not frame then return end
    if event == "UNIT_SPELLCAST_CHANNEL_START" and a == "player" then
        local name = FishingName()
        if c == 7620 or c == 131474 or (type(c) == "number" and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(c) == name) then
            channeling, castAt, retryCast = true, GetTime(), false
            pendingFishLootUntil, pendingDirect, pendingBag = 0, {}, {}
            ApplyBinding()
            local water = Water()
            water.last = time()
            if currentSession then
                currentSession.firstCastAt = currentSession.firstCastAt or time()
                currentSession.casts = currentSession.casts + 1
                SessionPlace(currentSession, currentLocation)
            end
            Refresh()
        end
    elseif event == "PLAYER_LOGOUT" then
        if currentSession then currentSession.endedAt = time() end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" and a == "player" and channeling then
        channeling = false
        channelStoppedAt = GetTime()
        pendingFishLootUntil = channelStoppedAt + 10
        ApplyBinding()
    elseif (event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE") and active then
        local message = type(b) == "string" and b or a
        if type(message) == "string" and message == ERR_FISH_NOT_HOOKED then
            retryCast = true
            castAt = 0
            pendingFishLootUntil = 0
            ApplyBinding()
        end
    elseif (event == "LOOT_READY" or event == "LOOT_OPENED") and active then
        local ok, isFishing = pcall(IsFishingLoot or function() return false end)
        local recentCast = castAt > 0 and (channeling or (channelStoppedAt > 0 and GetTime() - channelStoppedAt <= 3))
        if (ok and isFishing) or recentCast then
            if GetTime() > pendingFishLootUntil then pendingDirect = {} end
            pendingFishLootUntil = GetTime() + 3
            if GetTime() - lastLoot > 2 then
                local found, sawLoot = false, false
                for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
                    local linked, link = pcall(GetLootSlotLink, slot)
                    if not linked or (issecretvalue and issecretvalue(link)) then link = nil end
                    local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
                    if id then
                        sawLoot = true
                        local _, _, count = GetLootSlotInfo(slot)
                        count = math.max(1, tonumber(count) or 1)
                        local alreadyCounted = math.min(count, pendingBag[id] or 0)
                        pendingBag[id] = (pendingBag[id] or 0) - alreadyCounted
                        count = count - alreadyCounted
                        if count > 0 then
                            RecordCatch(id, count)
                            pendingDirect[id] = (pendingDirect[id] or 0) + count
                            found = true
                        end
                    end
                end
                if sawLoot then lastLoot = GetTime() end
                if found then Refresh() end
            end
            if LootSlot and GetNumLootItems then
                for slot = 1, GetNumLootItems() do LootSlot(slot) end
            end
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        local found = ScanBagChanges()
        if active then
            ApplyBinding()
            local lureChanged = UpdateLureStatus()
            if found or lureChanged then Refresh() end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        ApplyBinding()
        Refresh()
    else
        UpdateActive()
        if active then
            if event == "BAG_UPDATE_DELAYED" or event == "UNIT_INVENTORY_CHANGED"
                or event == "SKILL_LINES_CHANGED" then ApplyBinding() end
            Refresh()
        end
    end
end)
events:SetScript("OnUpdate", function(_, dt)
    if not frame then return end
    if active and currentSession and currentSession.firstCastAt then
        currentSession.seconds = (currentSession.seconds or 0) + dt
        local key = Place()
        local place = currentSession.places[key]
        if place then place.seconds = (place.seconds or 0) + dt end
    end
    elapsed = elapsed + dt
    refreshElapsed = refreshElapsed + dt
    lureCheckElapsed = lureCheckElapsed + dt
    bagScanElapsed = bagScanElapsed + dt
    if elapsed < 0.2 then return end
    elapsed = 0
    if pendingBindings or (active and channeling) or (active and lureCheckElapsed >= 0.5) then
        lureCheckElapsed = 0
        ApplyBinding()
    end
    if active then
        if bagScanElapsed >= 0.5 and castAt > 0 and GetTime() - castAt <= 45 then
            bagScanElapsed = 0
            if ScanBagChanges() then Refresh() end
        end
        timerText:SetText(SessionTime())
        local key = Place()
        local lureChanged = UpdateLureStatus()
        if key ~= currentLocation or refreshElapsed >= 10 or lureChanged then
            refreshElapsed = 0
            Refresh()
        end
    end
end)
