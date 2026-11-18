local addonName = ...
local Addon = LH_Fishing
local variables = {"LH_Fishing_locked", "LH_Fishing_autoLure"}

function Addon:RefreshSettings()
    if not Settings or not Settings.NotifyUpdate then return end
    for _, name in ipairs(variables) do Settings.NotifyUpdate(name) end
end

local function Build(category, layout)
    LH_LayoutProfiles:AddSetting(category, layout, addonName)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Fishing window"))
    local locked = Settings.RegisterProxySetting(category, variables[1], "boolean", "Lock fishing window", false,
        function() return Addon:IsLocked() end,
        function(value) Addon:SetLocked(value) end)
    Settings.CreateCheckbox(category, locked, "Unlock to drag the fishing window while a pole is equipped. Saved per character.")
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Fishing"))
    local autoLure = Settings.RegisterProxySetting(category, variables[2], "boolean",
        "Apply best lure automatically", true,
        function() return Addon:IsAutoLureEnabled() end,
        function(value) Addon:SetAutoLureEnabled(value) end)
    Settings.CreateCheckbox(category, autoLure,
        "When casting with an unbaited pole, the first Space press applies the best available lure. Press Space again to cast. Saved per character.")
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("History"))
    layout:AddInitializer(CreateSettingsButtonInitializer("Delete all saved catches, sessions, and water history", "Reset history",
        function()
            StaticPopupDialogs.LH_FISHING_RESET_HISTORY = {
                text = "Delete all LH Fishing catch and location history for this character? This cannot be undone.",
                button1 = "Delete", button2 = "Cancel",
                OnAccept = function() Addon:ResetHistory() end,
                timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
            }
            StaticPopup_Show("LH_FISHING_RESET_HISTORY")
        end,
        "Permanently clear the saved fishing history for this character. Layout and fishing settings are kept.", true))
    layout:AddInitializer(CreateSettingsButtonInitializer("Restore the default window position", "Reset position",
        function() Addon:ResetPosition() end, "Center the fishing window on screen.", true))
    EventRegistry:RegisterCallback("Settings.CategoryDefaulted", function(_, selected)
        if selected == category then
            Addon:SetLocked(false)
            Addon:SetAutoLureEnabled(true)
            Addon:SetCompactMode(false)
            Addon:ResetPosition()
        end
    end, Addon)
end

LH_Tweaks:RegisterModule(addonName, "LH Fishing", Build)
