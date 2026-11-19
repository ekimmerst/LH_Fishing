local ADDON = ...
local GOAL_TEXTURE = "Interface\\AddOns\\LH_Fishing\\Media\\Smooth.tga"
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
local frame, titleText, locationText, totalText, rateText, lureReminder, modeButton
local goalText, goalBarFrame, goalBar, goalBarLabel, goalButton, goalEditor
local goalItemInput, goalCountInput, goalHoursInput, goalMinutesInput, goalSkillInput, goalSkillCurrent
local goalToast
local scrollChild, timerText, headings, headerLabels, headerButtons, sumRow, measureText
local rows, active, cast, bindingOwner = {}, false
local catchFlashUntil = {}
local tabs, activeTab, currentSession = {}, "session"
local sortColumn, sortAscending = 2, false
local channeling, lastLoot = false, 0
local channelStoppedAt = 0
local bagCounts, pendingFishLootUntil, catchSources = {}, 0, {}
local castAt, retryCast = 0, false
local EARLY_RECAST_SECONDS = 2
local HISTORY_RESET_EPOCH = 1
local elapsed, currentLocation, pendingBindings = 0
local bindingMode, bindingMacro, jumpBound
local refreshElapsed, lureCheckElapsed, bagScanElapsed = 0, 0, 0
local knownLureID, knownEnchantID, knownPoleID, pendingLureID, pendingLureAt, lureStatusKey
local characterHistory

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
        if LH_FishingDB.compact then
            key, message = "inactive", "No lure active."
            lureReminder:SetTextColor(0.7, 0.7, 0.7, 1)
        end
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
    return key, sub ~= "" and sub ~= zone and (zone .. " - " .. sub) or zone,
        zone, sub ~= "" and sub ~= zone and sub or nil
end
local function Water()
    local key, name, zone, subzone = Place()
    currentLocation = key
    local water = LH_FishingDB.waters[key]
    if not water then
        water = {name = name, items = {}, total = 0}
        LH_FishingDB.waters[key] = water
    end
    water.name = name
    water.zone = zone
    water.subzone = subzone
    return water
end
local function CopyCounts(source)
    local counts = {}
    if type(source) == "table" then
        for id, count in pairs(source) do
            if type(id) == "number" and type(count) == "number" and count > 0 then
                counts[id] = count
            end
        end
    end
    return counts
end
local function ResetOldHistory()
    if (tonumber(LH_FishingHistory.resetEpoch) or 0) < HISTORY_RESET_EPOCH then
        LH_FishingHistory.characters = {}
        LH_FishingHistory.itemNames = {}
        LH_FishingHistory.resetEpoch = HISTORY_RESET_EPOCH
        characterHistory = nil
    end
    -- Per-character saved variables load only for the character logging in.
    -- Clear each old copy before PrepareHistory can import it again.
    if (tonumber(LH_FishingDB.historyResetEpoch) or 0) < HISTORY_RESET_EPOCH then
        LH_FishingDB.items = {}
        LH_FishingDB.itemNames = {}
        LH_FishingDB.waters = {}
        LH_FishingDB.sessions = {}
        LH_FishingDB.fishingSeconds = nil
        LH_FishingDB.historyResetEpoch = HISTORY_RESET_EPOCH
    end
end
local function PrepareHistory()
    if characterHistory then return characterHistory end
    local name, realm
    if UnitFullName then name, realm = UnitFullName("player") end
    if not name and UnitName then name = UnitName("player") end
    if (not realm or realm == "") and GetRealmName then realm = GetRealmName() end
    if not name or not realm or realm == "" then return nil end
    LH_FishingHistory = type(LH_FishingHistory) == "table" and LH_FishingHistory or {}
    LH_FishingHistory.characters = type(LH_FishingHistory.characters) == "table" and LH_FishingHistory.characters or {}
    local key = realm .. ":" .. name
    characterHistory = LH_FishingHistory.characters[key]
    if characterHistory then return characterHistory end
    characterHistory = {items = {}, waters = {}, seconds = 0}
    LH_FishingHistory.characters[key] = characterHistory
    for id, itemName in pairs(LH_FishingDB.itemNames) do
        if type(id) == "number" and type(itemName) == "string" then
            LH_FishingHistory.itemNames[id] = itemName
        end
    end
    characterHistory.items = CopyCounts(LH_FishingDB.items)
    characterHistory.seconds = type(LH_FishingDB.fishingSeconds) == "number" and LH_FishingDB.fishingSeconds or 0
    for placeKey, old in pairs(LH_FishingDB.waters) do
        if type(old) == "table" then
            local items = CopyCounts(old.items)
            local total = 0
            for _, count in pairs(items) do total = total + count end
            characterHistory.waters[placeKey] = {
                name = old.name, zone = old.zone, subzone = old.subzone, last = old.last,
                items = items, total = total, seconds = 0,
            }
        end
    end
    for _, session in ipairs(LH_FishingDB.sessions) do
        characterHistory.seconds = characterHistory.seconds + (tonumber(session.seconds) or 0)
        if type(session.places) == "table" then
            for placeKey, place in pairs(session.places) do
                local water = characterHistory.waters[placeKey]
                if not water then
                    water = {items = {}, total = 0, seconds = 0}
                    characterHistory.waters[placeKey] = water
                end
                water.seconds = water.seconds + (tonumber(place.seconds) or 0)
            end
        end
    end
    return characterHistory
end
local function SharedWater(key, localWater)
    local history = PrepareHistory()
    if not history then return nil end
    local water = history.waters[key]
    if not water then
        water = {items = {}, total = 0, seconds = 0}
        history.waters[key] = water
    end
    if localWater then
        water.name, water.zone, water.subzone = localWater.name, localWater.zone, localWater.subzone
    end
    return water
end
local function HistoryTotals(key)
    PrepareHistory()
    local hereItems, overallItems, areaCounts = {}, {}, {}
    local hereTotal, hereSeconds, overallSeconds, last = 0, 0, 0, nil
    for _, history in pairs(LH_FishingHistory.characters) do
        overallSeconds = overallSeconds + (history.seconds or 0)
        for id, count in pairs(history.items) do
            overallItems[id] = (overallItems[id] or 0) + count
        end
        for placeKey, water in pairs(history.waters) do
            if placeKey == key then
                hereSeconds = hereSeconds + (water.seconds or 0)
                if water.last and (not last or water.last > last) then last = water.last end
                for id, count in pairs(water.items) do
                    hereItems[id] = (hereItems[id] or 0) + count
                    hereTotal = hereTotal + count
                end
            end
            local zone, subzone = water.zone, water.subzone
            if type(water.name) == "string" then
                local nameZone, nameSubzone = water.name:match("^(.-) %- (.+)$")
                zone = zone or nameZone or water.name
                if nameZone == zone then subzone = subzone or nameSubzone end
            end
            local area = type(zone) == "string" and zone ~= "" and
                (type(subzone) == "string" and subzone ~= "" and (zone .. " (" .. subzone .. ")") or zone)
            if area then
                for id, count in pairs(water.items) do
                    local counts = areaCounts[id]
                    if not counts then counts = {}; areaCounts[id] = counts end
                    counts[area] = (counts[area] or 0) + count
                end
            end
        end
    end
    return hereItems, hereTotal, hereSeconds, overallItems, overallSeconds, areaCounts, last
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
local function GoalTime(seconds)
    seconds = math.floor(math.max(0, seconds or 0))
    local hours, minutes = math.floor(seconds / 3600), math.floor(seconds / 60) % 60
    if hours > 0 then return string.format("%d:%02d:%02d", hours, minutes, seconds % 60) end
    return string.format("%02d:%02d", minutes, seconds % 60)
end
local function ShowGoalToast(goal)
    if not goalToast then
        local toast = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        toast:SetSize(320, 104)
        toast:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
        toast:SetFrameStrata("FULLSCREEN_DIALOG")
        toast:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", edgeSize = 18,
            insets = {left = 7, right = 7, top = 7, bottom = 7}})
        toast:SetBackdropColor(0.12, 0.07, 0.025, 0.96)
        local function Atlas(texture, name)
            if texture.SetAtlas then pcall(texture.SetAtlas, texture, name) end
        end
        local background = toast:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(toast)
        Atlas(background, "ui-achievement-guild-background")
        local icon = toast:CreateTexture(nil, "ARTWORK")
        icon:SetSize(48, 48)
        icon:SetPoint("TOPLEFT", toast, "TOPLEFT", 17, -34)
        toast.icon = icon
        local iconFrame = toast:CreateTexture(nil, "OVERLAY")
        iconFrame:SetSize(70, 68)
        iconFrame:SetPoint("CENTER", icon, "CENTER", 0, 0)
        Atlas(iconFrame, "ui-achievement-guild-iconframe")
        local shield = toast:CreateTexture(nil, "ARTWORK")
        shield:SetSize(62, 62)
        shield:SetPoint("TOPRIGHT", toast, "TOPRIGHT", -10, -31)
        Atlas(shield, "ui-achievement-shield-1")
        local title = toast:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", toast, "TOP", 0, -13)
        title:SetText("LH Fishing")
        local heading = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        heading:SetPoint("TOPLEFT", toast, "TOPLEFT", 75, -36)
        heading:SetText("GOAL COMPLETED")
        heading:SetTextColor(1, 0.82, 0.35, 1)
        local name = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        name:SetSize(165, 36)
        name:SetPoint("TOPLEFT", toast, "TOPLEFT", 75, -55)
        name:SetJustifyH("CENTER")
        name:SetJustifyV("MIDDLE")
        toast.name = name
        local glow = toast:CreateTexture(nil, "OVERLAY")
        glow:SetSize(320, 104)
        glow:SetPoint("CENTER", toast, "CENTER")
        glow:SetBlendMode("ADD")
        Atlas(glow, "ui-achievement-guild-glow")
        local glowAnim = glow:CreateAnimationGroup()
        local glowIn = glowAnim:CreateAnimation("Alpha")
        glowIn:SetFromAlpha(0); glowIn:SetToAlpha(1); glowIn:SetDuration(0.2); glowIn:SetOrder(1)
        local glowOut = glowAnim:CreateAnimation("Alpha")
        glowOut:SetFromAlpha(1); glowOut:SetToAlpha(0); glowOut:SetDuration(0.6); glowOut:SetOrder(2)
        glowAnim:SetScript("OnFinished", function() glow:Hide() end)
        toast.glow, toast.glowAnim = glow, glowAnim
        local shine = toast:CreateTexture(nil, "OVERLAY")
        shine:SetSize(80, 100)
        shine:SetPoint("BOTTOMLEFT", toast, "BOTTOMLEFT", 0, 2)
        shine:SetBlendMode("ADD")
        Atlas(shine, "ui-achievement-guild-shine")
        local shineAnim = shine:CreateAnimationGroup()
        local shineIn = shineAnim:CreateAnimation("Alpha")
        shineIn:SetFromAlpha(0); shineIn:SetToAlpha(1); shineIn:SetDuration(0.2); shineIn:SetOrder(1)
        local sweep = shineAnim:CreateAnimation("Translation")
        sweep:SetOffset(240, 0); sweep:SetDuration(0.9); sweep:SetOrder(2)
        local shineOut = shineAnim:CreateAnimation("Alpha")
        shineOut:SetFromAlpha(1); shineOut:SetToAlpha(0); shineOut:SetDuration(0.5); shineOut:SetOrder(3)
        shineAnim:SetScript("OnFinished", function() shine:Hide() end)
        toast.shine, toast.shineAnim = shine, shineAnim
        local intro = toast:CreateAnimationGroup()
        local fadeIn = intro:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(0.25)
        toast.intro = intro
        local outro = toast:CreateAnimationGroup()
        local fadeOut = outro:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0); fadeOut:SetDuration(1)
        outro:SetScript("OnFinished", function() toast:Hide() end)
        toast.outro = outro
        toast:SetScript("OnUpdate", function(self, dt)
            self.remaining = (self.remaining or 0) - dt
            if self.remaining <= 0 and not self.outro:IsPlaying() then self.outro:Play() end
        end)
        toast:Hide()
        goalToast = toast
    end
    local toast = goalToast
    if goal.kind == "fish" then
        local icon = C_Item and C_Item.GetItemIconByID or GetItemIcon
        local ok, texture = icon and pcall(icon, goal.id)
        if issecretvalue and issecretvalue(texture) then texture = nil end
        toast.icon:SetTexture(ok and texture or "Interface\\Icons\\Trade_Fishing")
        toast.name:SetText(string.format("Catch %d %s", goal.target, goal.name or ("Item " .. goal.id)))
    elseif goal.kind == "skill" then
        toast.icon:SetTexture("Interface\\Icons\\Trade_Fishing")
        toast.name:SetText("Fishing skill " .. goal.target)
    else
        toast.icon:SetTexture("Interface\\Icons\\Trade_Fishing")
        toast.name:SetText("Fish for " .. GoalTime(goal.target))
    end
    toast.remaining = 4
    toast.outro:Stop()
    toast.intro:Stop()
    toast.glowAnim:Stop()
    toast.shineAnim:Stop()
    toast:SetAlpha(1)
    toast:Show()
    toast.intro:Play()
    toast.glow:Show(); toast.glowAnim:Play()
    toast.shine:Show(); toast.shineAnim:Play()
    if PlaySound then pcall(PlaySound, 12891, "Master") end
end
local function GoalProgress(goal)
    if not currentSession then return 0 end
    if goal.kind == "fish" then return currentSession.items[goal.id] or 0 end
    if goal.kind == "skill" then
        local skill = FishingSkill()
        if skill <= 0 then return 0 end
        if not goal.startSkill then
            goal.startSkill = skill
            if skill >= goal.target then goal.reached = true end
        end
        if goal.startSkill >= goal.target then return 1 end
        return math.max(0, skill - goal.startSkill)
    end
    return currentSession.seconds or 0
end
local function UpdateGoalDisplay()
    local goal = LH_FishingDB.goal
    if not goal then
        goalText:SetText("Goal: none")
        goalText:SetTextColor(1, 0.75, 0.3, 1)
        goalBarFrame:Hide()
        return
    end
    local progress = GoalProgress(goal)
    local maximum = goal.kind == "skill" and math.max(1, goal.target - (goal.startSkill or 0)) or goal.target
    if not goal.reached and progress >= maximum then
        goal.reached = true
        ShowGoalToast(goal)
    end
    if goal.kind == "fish" then
        goalText:SetText("Goal: " .. (goal.name or ("Item " .. goal.id)))
        goalBarLabel:SetText(string.format("%d / %d", progress, goal.target))
    elseif goal.kind == "skill" then
        goalText:SetText("Goal: Fishing skill")
        goalBarLabel:SetText(string.format("+%d / +%d  (%d / %d)", progress, maximum,
            (goal.startSkill or 0) + progress, goal.target))
    else
        goalText:SetText("Goal: Fishing time")
        goalBarLabel:SetText(GoalTime(progress) .. " / " .. GoalTime(goal.target))
    end
    goalText:SetTextColor(goal.reached and 0.35 or 1, goal.reached and 1 or 0.75, 0.3, 1)
    goalBar:SetMinMaxValues(0, maximum)
    goalBar:SetValue(math.min(progress, maximum))
    goalBar:SetStatusBarColor(goal.reached and 0.35 or 1, goal.reached and 0.9 or 0.75, 0.15, 1)
    goalBarFrame:ClearAllPoints()
    if LH_FishingDB.compact then
        goalBarFrame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6, 5)
        goalBarFrame:SetSize(frame:GetWidth() - 12, 13)
        goalBarLabel:SetText(string.format("%d%%", math.min(100, math.floor(progress * 100 / maximum + 0.5))))
    else
        local labelWidth = math.min(300, MeasuredWidth(goalText:GetText()))
        goalText:SetWidth(labelWidth)
        local x = 12 + labelWidth + 8
        goalBarFrame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 10)
        goalBarFrame:SetSize(math.max(80, frame:GetWidth() - x - 12), 20)
    end
    goalBarFrame:Show()
end
local function ShowGoalEditor(id, name)
    local goal = LH_FishingDB.goal
    if not id and goal then
        if goal.kind == "fish" then
            id, name = goal.id, goal.name
            goalCountInput:SetText(tostring(goal.target))
        elseif goal.kind == "time" then
            goalItemInput:SetText("")
            goalItemInput.itemID, goalItemInput.itemName = nil, nil
            goalHoursInput:SetText(tostring(math.floor(goal.target / 3600)))
            goalMinutesInput:SetText(tostring(math.floor(goal.target / 60) % 60))
        else
            goalSkillInput:SetText(tostring(goal.target))
        end
    end
    local skill = FishingSkill()
    goalSkillCurrent:SetText("Current Fishing skill: " .. (skill > 0 and skill or "unknown"))
    if id then
        goalItemInput:SetText(name or tostring(id))
        goalItemInput.itemID = id
        goalItemInput.itemName = name
    end
    goalEditor:Show()
    if id then goalCountInput:SetFocus() end
end
local function ResolveGoalItem(value)
    local id = tonumber(value:match("item:(%d+)") or value:match("^%s*(%d+)%s*$"))
    local itemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local name
    if id then
        if itemInfo then
            local ok, foundName = pcall(itemInfo, id)
            if ok and type(foundName) == "string" and not (issecretvalue and issecretvalue(foundName)) then
                name = foundName
            end
        end
        return id, name or value:match("%[(.-)%]")
    end
    local wanted = value:match("^%s*(.-)%s*$"):lower()
    if wanted == "" then return nil end
    local _, _, _, allItems = HistoryTotals(currentLocation)
    for caughtID, count in pairs(allItems) do
        if type(count) == "number" and count > 0 then
            local caughtName = LH_FishingHistory.itemNames[caughtID] or LH_FishingDB.itemNames[caughtID]
            if not caughtName and itemInfo then
                local ok, caughtName = pcall(itemInfo, caughtID)
                if ok and type(caughtName) == "string" and not (issecretvalue and issecretvalue(caughtName)) then
                    LH_FishingHistory.itemNames[caughtID] = caughtName
                end
            end
            caughtName = LH_FishingHistory.itemNames[caughtID] or LH_FishingDB.itemNames[caughtID]
            if type(caughtName) == "string" and caughtName:lower() == wanted then return caughtID, caughtName end
        end
    end
    if itemInfo then
        local ok, foundName, link = pcall(itemInfo, value)
        if ok and type(link) == "string" and not (issecretvalue and issecretvalue(link)) then
            id = tonumber(link:match("item:(%d+)"))
            if id then
                name = type(foundName) == "string" and not (issecretvalue and issecretvalue(foundName))
                    and foundName or value
                return id, name
            end
        end
    end
    local instant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    if instant then
        local ok, foundID = pcall(instant, value)
        if ok and type(foundID) == "number" and not (issecretvalue and issecretvalue(foundID))
            and foundID > 0 then return foundID, value end
    end
end
local function UpdateCatchFlashes()
    local now = GetTime()
    for id, expires in pairs(catchFlashUntil) do
        if now >= expires then catchFlashUntil[id] = nil end
    end
    for _, row in ipairs(rows) do
        local expires = activeTab ~= "history" and row:IsShown() and catchFlashUntil[row.itemID]
        if expires then
            local seconds = 1 - (expires - now)
            local pulse = math.sin(seconds * math.pi)
            row.qtyFlash:SetColorTexture(1, 0.65, 0.1, 0.55 * pulse)
            row.qtyFlash:Show()
            row.cells[2]:SetTextColor(1, 1, 1 - 0.55 * pulse, 1)
        else
            row.qtyFlash:Hide()
            row.cells[2]:SetTextColor(1, 1, 1, 1)
        end
    end
end
local function Refresh()
    if not frame then return end
    local water = Water()
    timerText:SetText(SessionTime())
    if LH_FishingDB.compact then
        local compactWidth = math.max(230, MeasuredWidth(lureReminder:GetText()) + 24)
        if not Combat() then frame:SetSize(compactWidth, LH_FishingDB.goal and 82 or 72) end
        lureReminder:SetWidth(frame:GetWidth() - 24)
        UpdateGoalDisplay()
        return
    end
    local showReminder = lureReminder:IsShown()
    local key = currentLocation
    local historyItems, historyTotal, historySeconds, overallItems, overallSeconds,
        areaCounts, lastFished = HistoryTotals(key)
    tabs.session.text:SetText("Session")
    tabs.history.text:SetText("History here")
    tabs.overall.text:SetText("History overall")
    for tabKey, tab in pairs(tabs) do
        local selected = tabKey == activeTab
        tab.text:SetTextColor(selected and 1 or 0.7, selected and 0.82 or 0.7, selected and 0.38 or 0.7)
        tab.underline:SetShown(selected)
    end
    local visited = lastFished and date("%Y-%m-%d %H:%M", lastFished) or "Never"
    locationText:SetText(water.name .. "  |  Last fished: " .. visited)
    local visibleItems
    if activeTab == "session" then
        visibleItems = currentSession and currentSession.items or {}
    elseif activeTab == "history" then
        visibleItems = historyItems
    else
        visibleItems = overallItems
    end
    local chanceItems = visibleItems
    local chanceTotal = activeTab == "history" and historyTotal or 0
    local headerTitles = {"Item", "Qty", activeTab == "session" and "Session %"
        or activeTab == "history" and "Here %" or "Overall %",
        "AH Each", "AH Sum", "Common in Area"}
    for column, label in ipairs(headerLabels) do
        label:SetText(headerTitles[column])
        local arrow = headerButtons[column].arrow
        arrow:SetShown(sortColumn == column)
        if sortColumn == column then
            arrow:SetTexCoord(0, 0.5625, sortAscending and 1 or 0, sortAscending and 0 or 1)
        end
    end
    local entries = {}
    for id, count in pairs(visibleItems) do
        if count > 0 then
            entries[#entries + 1] = {id = id, count = count}
            if activeTab ~= "history" then chanceTotal = chanceTotal + count end
        end
    end
    local commonAreas = {}
    for id, counts in pairs(areaCounts) do
        local bestArea, bestCount
        for area, count in pairs(counts) do
            if not bestCount or count > bestCount or (count == bestCount and area < bestArea) then
                bestArea, bestCount = area, count
            end
        end
        commonAreas[id] = bestArea
    end
    local itemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    for _, entry in ipairs(entries) do
        local name, icon
        if itemInfo then
            local ok, itemName, _, _, _, _, _, _, _, _, itemIcon = pcall(itemInfo, entry.id)
            if ok then name, icon = itemName, itemIcon end
        end
        if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) then name = nil end
        if issecretvalue and issecretvalue(icon) then icon = nil end
        if name then LH_FishingDB.itemNames[entry.id] = name; LH_FishingHistory.itemNames[entry.id] = name end
        entry.name = name or LH_FishingHistory.itemNames[entry.id] or LH_FishingDB.itemNames[entry.id]
            or ("Item %d"):format(entry.id)
        entry.icon = icon
        entry.auctionPrice = Price(entry.id)
        entry.area = commonAreas[entry.id]
    end
    local function SortValue(entry)
        if sortColumn == 1 then return entry.name:lower() end
        if sortColumn == 2 or sortColumn == 3 then return entry.count end
        if sortColumn == 4 then return entry.auctionPrice end
        if sortColumn == 5 then return entry.auctionPrice and entry.auctionPrice * entry.count end
        return entry.area and entry.area:lower()
    end
    table.sort(entries, function(a, b)
        local first, second = SortValue(a), SortValue(b)
        if first == second then return a.id < b.id end
        if first == nil then return false end
        if second == nil then return true end
        return sortAscending and first < second or first > second
    end)
    local auctionTotal, auctionUnitTotal = 0, 0
    local auctionKnown, quantityTotal = false, 0
    local widths = {210, 30, 70, 62, 62, 130}
    for column, label in ipairs(headerLabels) do
        widths[column] = math.max(widths[column], MeasuredWidth(label:GetText()) + (sortColumn == column and 18 or 0))
    end
    for index, entry in ipairs(entries) do
        local row = rows[index]
        if not row then
            row = CreateFrame("Frame", nil, scrollChild)
            row:SetSize(610, 21)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * 21)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(17, 17)
            row.icon:SetPoint("LEFT", 0, 0)
            row.qtyFlash = row:CreateTexture(nil, "BACKGROUND")
            row.qtyFlash:SetSize(30, 19)
            row.qtyFlash:Hide()
            row.goalButton = CreateFrame("Button", nil, row)
            row.goalButton:SetSize(16, 16)
            local crosshair = {{4, 1, -5, 0}, {4, 1, 5, 0}, {1, 4, 0, 5},
                {1, 4, 0, -5}, {2, 2, 0, 0}}
            for _, part in ipairs(crosshair) do
                local mark = row.goalButton:CreateTexture(nil, "ARTWORK")
                mark:SetSize(part[1], part[2])
                mark:SetPoint("CENTER", row.goalButton, "CENTER", part[3], part[4])
                mark:SetColorTexture(1, 0.75, 0.15, 1)
            end
            local hover = row.goalButton:CreateTexture(nil, "HIGHLIGHT")
            hover:SetAllPoints(row.goalButton)
            hover:SetColorTexture(1, 0.75, 0.15, 0.2)
            row.goalButton:SetScript("OnClick", function(self)
                ShowGoalEditor(self.itemID, self.itemName)
            end)
            row.goalButton:SetScript("OnEnter", function(self)
                if not GameTooltip then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Set fish goal: " .. (self.itemName or "Item"))
                GameTooltip:Show()
            end)
            row.goalButton:SetScript("OnLeave", function(self)
                if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
            end)
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if not self.itemID or not GameTooltip then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if GameTooltip.SetItemByID then
                    GameTooltip:SetItemByID(self.itemID)
                else
                    GameTooltip:SetHyperlink("item:" .. self.itemID)
                end
                GameTooltip:AddLine("Right-click to set a fish goal", 1, 0.75, 0.15)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function(self)
                if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
            end)
            row:SetScript("OnMouseUp", function(self, button)
                if button == "RightButton" then ShowGoalEditor(self.itemID, self.itemName) end
            end)
            row.cells = {}
            for column = 1, 6 do row.cells[column] = Text(row, 11, "LEFT", 0, 0, 10) end
            rows[index] = row
        end
        row.itemID = entry.id
        row.itemName = entry.name
        row.goalButton.itemID = entry.id
        row.goalButton.itemName = entry.name
        row.icon:SetTexture(entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local localCount = chanceItems[entry.id] or 0
        local auctionPrice = entry.auctionPrice
        local values = {
            entry.name, tostring(entry.count),
            chanceTotal > 0 and string.format("%.1f%%", 100 * localCount / chanceTotal) or "-",
            Money(auctionPrice), Money(auctionPrice and auctionPrice * entry.count),
            entry.area or "-",
        }
        for column, value in ipairs(values) do
            row.cells[column]:SetText(value)
            if column == 1 then
                widths[column] = math.max(widths[column], math.min(225, MeasuredWidth(value) + 20))
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
        row:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    local sumValues = {
        "Total", tostring(quantityTotal), "",
        Money(auctionKnown and auctionUnitTotal or nil), Money(auctionKnown and auctionTotal or nil), "",
    }
    for column, value in ipairs(sumValues) do
        sumRow.cells[column]:SetText(value)
        if column > 1 then widths[column] = math.max(widths[column], MeasuredWidth(value)) end
    end
    local offsets = {21}
    for column = 2, 6 do offsets[column] = offsets[column - 1] + widths[column - 1] + 6 end
    local tableWidth = offsets[6] + widths[6] + 4
    totalText:SetText("AH total (priced): " .. Money(auctionKnown and auctionTotal or nil))
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
        MeasuredWidth(totalText:GetText()), MeasuredWidth(rateText:GetText()),
    }
    local reminderWidth = showReminder and MeasuredWidth(lureReminder:GetText()) or 0
    local frameWidth = math.max(650, tableWidth + 42,
        footerWidths[1] + footerWidths[2] + 36 + (showReminder and reminderWidth + 12 or 0))
    if not Combat() then
        frame:SetWidth(frameWidth)
        frame:SetHeight(117 + (#entries + 1) * 21 + 65)
    end
    lureReminder:SetWidth(math.max(1, reminderWidth))
    headings:SetWidth(tableWidth)
    scrollChild:SetWidth(tableWidth)
    locationText:SetWidth(frame:GetWidth() - 24)
    for column, label in ipairs(headerLabels) do
        SetCell(label, headings, offsets[column], widths[column])
        SetCell(headerButtons[column], headings, offsets[column], widths[column])
        local arrow = headerButtons[column].arrow
        arrow:ClearAllPoints()
        arrow:SetPoint("LEFT", label, "LEFT", label:GetStringWidth() + 4, 0)
    end
    for _, row in ipairs(rows) do
        row:SetWidth(tableWidth)
        for column, cell in ipairs(row.cells) do
            SetCell(cell, row, offsets[column], widths[column] - (column == 1 and 20 or 0))
        end
        local nameWidth = math.min(widths[1] - 20, MeasuredWidth(row.cells[1]:GetText()) - 4)
        row.goalButton:ClearAllPoints()
        row.goalButton:SetPoint("LEFT", row, "LEFT", offsets[1] + nameWidth + 4, 0)
        SetCell(row.qtyFlash, row, offsets[2], widths[2])
    end
    sumRow:SetWidth(tableWidth)
    sumRow:ClearAllPoints()
    sumRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -#entries * 21)
    for column, cell in ipairs(sumRow.cells) do SetCell(cell, sumRow, offsets[column], widths[column]) end
    scrollChild:SetHeight((#entries + 1) * 21)
    local footers = {totalText, rateText}
    local x = 12
    for index, footer in ipairs(footers) do
        footer:ClearAllPoints()
        footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 42)
        footer:SetWidth(footerWidths[index])
        footer:SetJustifyH("LEFT")
        x = x + footerWidths[index] + 12
    end
    UpdateGoalDisplay()
    UpdateCatchFlashes()
end

local function SetCompactMode(compact)
    local left, top = frame:GetLeft(), frame:GetTop()
    if left and top then
        local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
        left, top = left * scale, top * scale
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        LH_FishingDB.position = {anchor = "TOPLEFT", x = left, y = top}
    end
    LH_FishingDB.compact = compact == true
    local standard = not LH_FishingDB.compact
    titleText:SetShown(standard)
    locationText:SetShown(standard)
    goalText:SetShown(standard)
    goalButton:SetShown(standard)
    if not standard then goalEditor:Hide() end
    headings:SetShown(standard)
    scrollChild:SetShown(standard)
    totalText:SetShown(standard)
    rateText:SetShown(standard)
    for _, tab in pairs(tabs) do tab:SetShown(standard) end
    timerText:ClearAllPoints()
    if standard then
        timerText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -48, -11)
        timerText:SetWidth(200)
        timerText:SetJustifyH("RIGHT")
    else
        timerText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -11)
        timerText:SetWidth(175)
        timerText:SetJustifyH("LEFT")
    end
    lureReminder:ClearAllPoints()
    if standard then
        lureReminder:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 42)
        lureReminder:SetJustifyH("RIGHT")
    else
        lureReminder:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -48)
        lureReminder:SetJustifyH("LEFT")
    end
    modeButton.arrow:SetTexture(standard and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up"
        or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    if active then
        UpdateLureStatus()
        Refresh()
    end
end

local function SelectTab(key)
    if activeTab == key then return end
    activeTab = key
    sortColumn, sortAscending = 2, false
    Refresh()
end

local function RestorePosition()
    frame:ClearAllPoints()
    local p = LH_FishingDB.position
    if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
        if p.anchor == "TOPLEFT" then
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
        else
            frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", p.x, p.y)
        end
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end
local function SavePosition()
    local x, y = frame:GetLeft(), frame:GetTop()
    if not x then return end
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    LH_FishingDB.position = {anchor = "TOPLEFT", x = x * scale, y = y * scale}
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
local function BindingIs(key, action)
    if not GetBindingAction then return true end
    local ok, current = pcall(GetBindingAction, key, true)
    return not ok or current == action
end
local function ApplyBinding()
    if Combat() or not frame then pendingBindings = true; return end
    if KeyHeld() then pendingBindings = true; return end
    pendingBindings = false
    if not active then
        if bindingMode then
            ClearOverrideBindings(bindingOwner)
            bindingMode, bindingMacro, jumpBound = nil, nil, nil
        end
        return
    end
    -- Replace the active action in place; clearing it on every update can let Space fall back to Jump.
    -- The bobber can be interacted with only when it is the player's soft target.
    -- A misplaced bobber uses the retry macro on the same Space press.
    if channeling and not retryCast and GetTime() - castAt >= EARLY_RECAST_SECONDS and BobberReady() then
        if bindingMode ~= "interact" or not BindingIs("SPACE", "INTERACTTARGET") then
            SetOverrideBinding(bindingOwner, true, "SPACE", "INTERACTTARGET")
            bindingMode = "interact"
        end
    else
        local macro = (channeling and "/stopcasting\n/cast " or "/cast ") .. FishingName()
        if not channeling and LH_FishingDB.autoLure and not HasLure() then
            local lureInfo = BestLure()
            if lureInfo then macro = ("/use item:%d\n/use 16"):format(lureInfo[1]) end
        end
        if bindingMacro ~= macro then
            cast:SetAttribute("macrotext", macro)
            bindingMacro = macro
        end
        if bindingMode ~= "cast" or not BindingIs("SPACE", "CLICK LH_FishingCastButton:LeftButton") then
            SetOverrideBindingClick(bindingOwner, true, "SPACE", "LH_FishingCastButton", "LeftButton")
            bindingMode = "cast"
        end
    end
    if not jumpBound or not BindingIs("SHIFT-SPACE", "JUMP") then
        SetOverrideBinding(bindingOwner, true, "SHIFT-SPACE", "JUMP")
        jumpBound = true
    end
end
local function StartSession()
    local previous = LH_FishingDB.sessions[#LH_FishingDB.sessions]
    if previous and not previous.endedAt then previous.endedAt = time() end
    local session = {startedAt = time(), items = {}, places = {}, casts = 0, seconds = 0}
    LH_FishingDB.sessions[#LH_FishingDB.sessions + 1] = session
    currentSession = session
    catchFlashUntil = {}
    if LH_FishingDB.goal then
        LH_FishingDB.goal.reached = false
        if LH_FishingDB.goal.kind == "skill" then
            local skill = FishingSkill()
            LH_FishingDB.goal.startSkill = skill > 0 and skill or nil
            if skill >= LH_FishingDB.goal.target then LH_FishingDB.goal.reached = true end
        end
    end
    activeTab = "session"
    sortColumn, sortAscending = 2, false
end
local function UpdateActive()
    local wanted = PoleEquipped()
    if wanted == active then return end
    active = wanted
    if active then
        bagCounts = CountBags()
        pendingLureID = nil
        pendingFishLootUntil, catchSources = 0, {}
        castAt, channelStoppedAt = 0, 0
        StartSession()
    elseif currentSession then
        currentSession.endedAt = time()
        currentSession = nil
        pendingFishLootUntil, catchSources = 0, {}
        castAt, channelStoppedAt = 0, 0
        pendingLureID = nil
    end
    if frame then frame:SetShown(active) end
    if not active and goalEditor then goalEditor:Hide() end
    if not active then channeling, retryCast = false, false end
    ApplyBinding()
    if active then
        UpdateLureStatus()
        Refresh()
    end
end
local function CreateUI()
    LH_FishingDB = type(LH_FishingDB) == "table" and LH_FishingDB or {}
    LH_FishingHistory = type(LH_FishingHistory) == "table" and LH_FishingHistory or {}
    LH_FishingHistory.characters = type(LH_FishingHistory.characters) == "table" and LH_FishingHistory.characters or {}
    LH_FishingHistory.itemNames = type(LH_FishingHistory.itemNames) == "table" and LH_FishingHistory.itemNames or {}
    LH_FishingDB.items = type(LH_FishingDB.items) == "table" and LH_FishingDB.items or {}
    LH_FishingDB.itemNames = type(LH_FishingDB.itemNames) == "table" and LH_FishingDB.itemNames or {}
    LH_FishingDB.waters = type(LH_FishingDB.waters) == "table" and LH_FishingDB.waters or {}
    LH_FishingDB.sessions = type(LH_FishingDB.sessions) == "table" and LH_FishingDB.sessions or {}
    ResetOldHistory()
    LH_FishingDB.locked = LH_FishingDB.locked == true
    LH_FishingDB.autoLure = LH_FishingDB.autoLure ~= false
    LH_FishingDB.compact = LH_FishingDB.compact == true
    local goal = LH_FishingDB.goal
    if type(goal) ~= "table" or (goal.kind ~= "fish" and goal.kind ~= "time" and goal.kind ~= "skill")
        or type(goal.target) ~= "number" or goal.target <= 0
        or (goal.kind == "fish" and type(goal.id) ~= "number")
        or (goal.kind == "skill" and goal.startSkill ~= nil and type(goal.startSkill) ~= "number") then
        LH_FishingDB.goal = nil
    else
        goal.progress = nil
    end
    LH_LayoutProfiles:Register(ADDON, LH_FishingDB, LH_FishingDB, {"position", "locked", "autoLure", "compact"})
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
    frame:SetSize(650, 173)
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
    titleText = Text(frame, 14, "TOPLEFT", 12, -12, 220)
    titleText:SetText("LH Fishing")
    titleText:SetTextColor(1, 0.75, 0.15, 1)
    timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    timerText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
    timerText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -48, -11)
    timerText:SetWidth(200)
    timerText:SetJustifyH("RIGHT")
    timerText:SetTextColor(1, 0.75, 0.15, 1)
    timerText:SetText("00:00:00")
    modeButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
    modeButton:SetSize(27, 25)
    modeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -12)
    modeButton:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8, insets = {left = 2, right = 2, top = 2, bottom = 2}})
    modeButton:SetBackdropColor(0.16, 0.12, 0.07, 0.9)
    modeButton:SetBackdropBorderColor(0.65, 0.59, 0.45, 1)
    local highlight = modeButton:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 3, -3)
    highlight:SetPoint("BOTTOMRIGHT", -3, 3)
    highlight:SetColorTexture(0.8, 0.65, 0.3, 0.2)
    modeButton.arrow = modeButton:CreateTexture(nil, "ARTWORK")
    modeButton.arrow:SetSize(17, 17)
    modeButton.arrow:SetPoint("CENTER")
    modeButton:SetScript("OnClick", function() SetCompactMode(not LH_FishingDB.compact) end)
    locationText = Text(frame, 11, "TOPLEFT", 12, -40, 666)
    goalText = Text(frame, 11, "BOTTOMLEFT", 12, 15, 300)
    goalText:SetWordWrap(false)
    goalBarFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    goalBarFrame:SetSize(200, 20)
    goalBarFrame:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8, insets = {left = 2, right = 2, top = 2, bottom = 2}})
    goalBarFrame:SetBackdropColor(0, 0, 0, 0.8)
    goalBarFrame:SetBackdropBorderColor(0.65, 0.59, 0.45, 1)
    goalBarFrame:EnableMouse(true)
    goalBarFrame:SetScript("OnEnter", function(self)
        if not GameTooltip or not LH_FishingDB.goal then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(goalText:GetText())
        local goal = LH_FishingDB.goal
        local progress = GoalProgress(goal)
        local detail
        if goal.kind == "fish" then
            detail = string.format("%d / %d", progress, goal.target)
        elseif goal.kind == "skill" then
            detail = string.format("+%d / +%d  (%d / %d)", progress,
                math.max(1, goal.target - (goal.startSkill or 0)), (goal.startSkill or 0) + progress, goal.target)
        else
            detail = GoalTime(progress) .. " / " .. GoalTime(goal.target)
        end
        GameTooltip:AddLine(detail, 1, 1, 1)
        GameTooltip:Show()
    end)
    goalBarFrame:SetScript("OnLeave", function(self)
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    goalBar = CreateFrame("StatusBar", nil, goalBarFrame)
    goalBar:SetPoint("TOPLEFT", goalBarFrame, "TOPLEFT", 3, -3)
    goalBar:SetPoint("BOTTOMRIGHT", goalBarFrame, "BOTTOMRIGHT", -3, 3)
    goalBar:SetStatusBarTexture(GOAL_TEXTURE)
    goalBar:SetStatusBarColor(1, 0.75, 0.15, 1)
    goalBar:SetMinMaxValues(0, 1)
    goalBar:SetValue(0)
    goalBar:EnableMouse(false)
    goalBarLabel = goalBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    goalBarLabel:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    goalBarLabel:SetAllPoints(goalBarFrame)
    goalBarLabel:SetJustifyH("CENTER")
    goalBarFrame:Hide()
    goalButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    goalButton:SetSize(88, 22)
    goalButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -64)
    goalButton:SetText("Goal...")
    goalButton:SetScript("OnClick", function() ShowGoalEditor() end)
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
    headings:SetSize(610, 16)
    headings:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -97)
    headerLabels, headerButtons = {}, {}
    for _, column in ipairs({
        {"Item", 21, 190}, {"Qty", 217, 30}, {"Here", 253, 40},
        {"AH Each", 299, 62}, {"AH Sum", 367, 62},
        {"Common in Area", 435, 130},
    }) do
        local label = Text(headings, 10, "LEFT", column[2], 0, column[3])
        label:SetWordWrap(false)
        label:SetText(column[1])
        headerLabels[#headerLabels + 1] = label
        local button = CreateFrame("Button", nil, headings)
        button:SetSize(column[3], 16)
        button:SetPoint("LEFT", headings, "LEFT", column[2], 0)
        button.arrow = button:CreateTexture(nil, "OVERLAY")
        button.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        button.arrow:SetSize(12, 12)
        button.arrow:SetVertexColor(1, 0.82, 0.38, 1)
        button.arrow:Hide()
        local sortIndex = #headerLabels
        button:SetScript("OnClick", function()
            if sortColumn == sortIndex then
                sortAscending = not sortAscending
            else
                sortColumn, sortAscending = sortIndex, true
            end
            Refresh()
        end)
        headerButtons[sortIndex] = button
    end
    scrollChild = CreateFrame("Frame", nil, frame)
    scrollChild:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -117)
    scrollChild:SetWidth(610)
    scrollChild:SetHeight(21)
    sumRow = CreateFrame("Frame", nil, scrollChild)
    sumRow:SetSize(610, 21)
    sumRow.cells = {}
    for column = 1, 6 do
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
    rateText = Text(frame, 11, "BOTTOMLEFT", 220, 12, 250)
    lureReminder = Text(frame, 11, "BOTTOMRIGHT", -12, 42, 200)
    lureReminder:SetJustifyH("RIGHT")
    lureReminder:SetTextColor(1, 0.75, 0.15, 1)
    lureReminder:SetText("No fishing lure in your bags.")
    lureReminder:Hide()
    goalEditor = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    goalEditor:SetSize(440, 280)
    goalEditor:SetPoint("CENTER", frame, "CENTER")
    goalEditor:SetFrameStrata("DIALOG")
    goalEditor:SetClampedToScreen(true)
    goalEditor:EnableMouse(true)
    goalEditor:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8, insets = {left = 2, right = 2, top = 2, bottom = 2}})
    goalEditor:SetBackdropColor(0, 0, 0, 0.9)
    goalEditor:SetBackdropBorderColor(0.65, 0.59, 0.45, 1)
    local editorTitle = Text(goalEditor, 14, "TOPLEFT", 12, -12, 300)
    editorTitle:SetText("Set fishing goal")
    editorTitle:SetTextColor(1, 0.75, 0.15, 1)
    local fishLabel = Text(goalEditor, 11, "TOPLEFT", 12, -42, 250)
    fishLabel:SetText("Fish name, item ID or link")
    local countLabel = Text(goalEditor, 11, "TOPLEFT", 285, -42, 80)
    countLabel:SetText("Quantity")
    local function EditBox(x, y, width, numeric)
        local edit = CreateFrame("EditBox", nil, goalEditor, "InputBoxTemplate")
        edit:SetSize(width, 20)
        edit:SetPoint("TOPLEFT", goalEditor, "TOPLEFT", x, y)
        edit:SetAutoFocus(false)
        if numeric then edit:SetNumeric(true) end
        edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        return edit
    end
    local function ActionButton(label, x, y, width, onClick)
        local button = CreateFrame("Button", nil, goalEditor, "UIPanelButtonTemplate")
        button:SetSize(width, 22)
        button:SetPoint("TOPLEFT", goalEditor, "TOPLEFT", x, y)
        button:SetText(label)
        button:SetScript("OnClick", onClick)
        return button
    end
    goalItemInput = EditBox(18, -61, 245)
    goalItemInput:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self.itemID, self.itemName = nil, nil end
    end)
    goalCountInput = EditBox(290, -61, 55, true)
    goalCountInput:SetText("10")
    ActionButton("Set fish", 355, -60, 75, function()
        local value = goalItemInput:GetText()
        local id, name = goalItemInput.itemID, goalItemInput.itemName
        if not id then id, name = ResolveGoalItem(value) end
        local target = tonumber(goalCountInput:GetText())
        if not id or id < 1 or not target or target < 1 then
            if UIErrorsFrame then UIErrorsFrame:AddMessage("Enter a known fish name, item ID or link, and a quantity.", 1, 0.3, 0.3) end
            return
        end
        LH_FishingDB.goal = {kind = "fish", id = id, name = name, target = target, reached = false}
        goalEditor:Hide()
        Refresh()
    end)
    local timeLabel = Text(goalEditor, 11, "TOPLEFT", 12, -99, 250)
    timeLabel:SetText("Fishing time")
    local hoursLabel = Text(goalEditor, 11, "TOPLEFT", 12, -120, 60)
    hoursLabel:SetText("Hours")
    local minutesLabel = Text(goalEditor, 11, "TOPLEFT", 102, -120, 65)
    minutesLabel:SetText("Minutes")
    goalHoursInput = EditBox(18, -140, 55, true)
    goalMinutesInput = EditBox(108, -140, 55, true)
    goalHoursInput:SetText("0")
    goalMinutesInput:SetText("10")
    ActionButton("Set time", 180, -139, 95, function()
        local hours = tonumber(goalHoursInput:GetText()) or 0
        local minutes = tonumber(goalMinutesInput:GetText()) or 0
        local target = hours * 3600 + minutes * 60
        if target < 60 then
            if UIErrorsFrame then UIErrorsFrame:AddMessage("Enter at least one minute.", 1, 0.3, 0.3) end
            return
        end
        LH_FishingDB.goal = {kind = "time", target = target, reached = false}
        goalEditor:Hide()
        Refresh()
    end)
    goalSkillCurrent = Text(goalEditor, 11, "TOPLEFT", 12, -180, 250)
    local skillLabel = Text(goalEditor, 11, "TOPLEFT", 12, -200, 100)
    skillLabel:SetText("Target skill")
    goalSkillInput = EditBox(18, -220, 55, true)
    local initialSkill = FishingSkill()
    if initialSkill > 0 then goalSkillInput:SetText(tostring(initialSkill + 10)) end
    ActionButton("Set skill", 95, -219, 95, function()
        local skill = FishingSkill()
        local target = tonumber(goalSkillInput:GetText())
        if skill <= 0 or not target or target <= skill then
            if UIErrorsFrame then UIErrorsFrame:AddMessage("Enter a Fishing skill above your current skill.", 1, 0.3, 0.3) end
            return
        end
        LH_FishingDB.goal = {kind = "skill", target = target, startSkill = skill, reached = false}
        goalEditor:Hide()
        Refresh()
    end)
    ActionButton("Clear goal", 12, -249, 100, function()
        LH_FishingDB.goal = nil
        goalItemInput:SetText("")
        goalItemInput.itemID, goalItemInput.itemName = nil, nil
        goalCountInput:SetText("10")
        goalHoursInput:SetText("0")
        goalMinutesInput:SetText("10")
        local skill = FishingSkill()
        goalSkillInput:SetText(skill > 0 and tostring(skill + 10) or "")
        goalEditor:Hide()
        Refresh()
    end)
    ActionButton("Close", 345, -249, 80, function() goalEditor:Hide() end)
    goalEditor:Hide()
    RestorePosition()
    frame:Hide()
    SetCompactMode(LH_FishingDB.compact)
    UpdateActive()
end

function Fishing:IsLocked() return LH_FishingDB and LH_FishingDB.locked end
function Fishing:SetCompactMode(value)
    if not frame then return end
    SetCompactMode(value)
end
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
    local history = PrepareHistory()
    if history then
        history.items, history.waters, history.seconds = {}, {}, 0
    end
    LH_FishingDB.items = {}
    LH_FishingDB.itemNames = {}
    LH_FishingDB.waters = {}
    LH_FishingDB.sessions = {}
    LH_FishingDB.fishingSeconds = nil
    currentSession = nil
    catchFlashUntil = {}
    lastLoot = 0
    bagCounts = CountBags()
    pendingFishLootUntil, catchSources = 0, {}
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
    catchFlashUntil[id] = GetTime() + 1
    local water = Water()
    water.last = time()
    LH_FishingDB.items[id] = (LH_FishingDB.items[id] or 0) + count
    water.items[id] = (water.items[id] or 0) + count
    water.total = water.total + count
    local history = PrepareHistory()
    local sharedWater = SharedWater(currentLocation, water)
    if history and sharedWater then
        history.items[id] = (history.items[id] or 0) + count
        sharedWater.items[id] = (sharedWater.items[id] or 0) + count
        sharedWater.total = sharedWater.total + count
        sharedWater.last = water.last
    end
    if currentSession then
        local place = SessionPlace(currentSession, currentLocation)
        currentSession.items[id] = (currentSession.items[id] or 0) + count
        place.items[id] = (place.items[id] or 0) + count
        place.total = place.total + count
    end
end
local function ObserveCatch(id, count, source)
    if not active or not id or count <= 0 then return false end
    local seen = catchSources[id]
    if not seen then
        seen = {bag = 0, loot = 0, chat = 0, recorded = 0}
        catchSources[id] = seen
    end
    seen[source] = seen[source] + count
    local total = math.max(seen.bag, seen.loot, seen.chat)
    if total <= seen.recorded then return false end
    RecordCatch(id, total - seen.recorded)
    seen.recorded = total
    return true
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
                    if ObserveCatch(id, gained, "bag") then found = true end
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
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UI_INFO_MESSAGE", "UI_ERROR_MESSAGE", "CHAT_MSG_LOOT",
    "LOOT_READY", "LOOT_OPENED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT"}) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, a, b, c)
    if event == "ADDON_LOADED" then if a == ADDON then CreateUI() end; return end
    if not frame then return end
    if event == "PLAYER_ENTERING_WORLD" then PrepareHistory() end
    if event == "UNIT_SPELLCAST_CHANNEL_START" and a == "player" then
        local name = FishingName()
        if c == 7620 or c == 131474 or (type(c) == "number" and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(c) == name) then
            if castAt > 0 and ScanBagChanges() then Refresh() end
            channeling, castAt, retryCast = true, GetTime(), false
            pendingFishLootUntil, catchSources = 0, {}
            ApplyBinding()
            local water = Water()
            water.last = time()
            local sharedWater = SharedWater(currentLocation, water)
            if sharedWater then sharedWater.last = water.last end
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
    elseif event == "CHAT_MSG_LOOT" and active and castAt > 0 and GetTime() - castAt <= 45 then
        if type(a) == "string" and not (issecretvalue and issecretvalue(a)) then
            local id = tonumber(a:match("|Hitem:(%d+)"))
            if id then
                local count = tonumber(a:match("[xX](%d+)[^%d]*$")) or 1
                if ObserveCatch(id, count, "chat") then Refresh() end
            end
        end
    elseif (event == "LOOT_READY" or event == "LOOT_OPENED") and active then
        local ok, isFishing = pcall(IsFishingLoot or function() return false end)
        local recentCast = castAt > 0 and (channeling or (channelStoppedAt > 0 and GetTime() - channelStoppedAt <= 3))
        if (ok and isFishing) or recentCast then
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
                        if ObserveCatch(id, count, "loot") then found = true end
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
        local place = SessionPlace(currentSession, key)
        place.seconds = (place.seconds or 0) + dt
        local history = PrepareHistory()
        local sharedWater = SharedWater(key)
        if history and sharedWater then
            history.seconds = history.seconds + dt
            sharedWater.seconds = sharedWater.seconds + dt
        end
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
        if next(catchFlashUntil) then UpdateCatchFlashes() end
        if LH_FishingDB.goal and (LH_FishingDB.goal.kind == "time" or LH_FishingDB.goal.kind == "skill") then
            UpdateGoalDisplay()
        end
    end
end)
