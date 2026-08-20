-- AscensionRaidRolls - temporary loot trade expiration tracker
-- Project Ascension / WoW 3.3.5a compatible; no Retail container APIs.
local Addon = AscensionRaidRolls
Addon.TradeTimers = Addon.TradeTimers or {}
local Timers = Addon.TradeTimers

local ALERT_AT = 20 * 60
local DEFAULT_WINDOW = 2 * 60 * 60
local SCAN_INTERVAL = 2
local MAX_ROWS = 10
local HEADER_HEIGHT = 21
local ROW_HEIGHT = 19

Timers.entries = Timers.entries or {}
Timers.alerted = Timers.alerted or {}
Timers.scanElapsed = 0
Timers.frame = nil
Timers.tooltip = nil

local function NormalizeName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:match("^%s*(.-)%s*$")
    name = name and (name:match("^([^%-]+)") or name) or nil
    return name and string.lower(name) or nil
end

local function IsSamePlayer(a, b)
    local left, right = NormalizeName(a), NormalizeName(b)
    return left and right and left == right
end

local function IsCurrentMasterLooter()
    if not GetLootMethod then return false end
    local method, partyIndex, raidIndex = GetLootMethod()
    if method ~= "master" then return false end
    if raidIndex ~= nil then
        if raidIndex == 0 then return true end
        local name = GetRaidRosterInfo and GetRaidRosterInfo(raidIndex) or nil
        return IsSamePlayer(name, UnitName("player"))
    end
    if partyIndex ~= nil then
        if partyIndex == 0 then return true end
        return IsSamePlayer(UnitName("party" .. tostring(partyIndex)), UnitName("player"))
    end
    return false
end

local function FormatTime(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

local function ParseRemainingTime(text)
    text = string.lower(tostring(text or ""))
    if text:find("less than a minute", 1, true) then return 30 end
    local h, m, s = text:match("(%d+)%s*:%s*(%d+)%s*:%s*(%d+)")
    if h then return (tonumber(h) * 3600) + (tonumber(m) * 60) + tonumber(s) end

    local total = 0
    local value = text:match("(%d+)%s*day")
    if value then total = total + tonumber(value) * 86400 end
    value = text:match("(%d+)%s*h[ou]*r")
    if value then total = total + tonumber(value) * 3600 end
    value = text:match("(%d+)%s*min")
    if value then total = total + tonumber(value) * 60 end
    value = text:match("(%d+)%s*sec")
    if value then total = total + tonumber(value) end
    return total > 0 and total or nil
end

local function EnsureTooltip()
    if Timers.tooltip then return Timers.tooltip end
    local tooltip = CreateFrame("GameTooltip", "AscensionRaidRollsTradeTimerTooltip", UIParent, "GameTooltipTemplate")
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    Timers.tooltip = tooltip
    return tooltip
end

local function ReadTradeTime(bag, slot)
    local tooltip = EnsureTooltip()
    tooltip:ClearLines()
    local ok = pcall(tooltip.SetBagItem, tooltip, bag, slot)
    if not ok then return nil end

    local i
    for i = 1, 30 do
        local region = _G["AscensionRaidRollsTradeTimerTooltipTextLeft" .. tostring(i)]
        local text = region and region:GetText() or nil
        if text then
            local lower = string.lower(text)
            if lower:find("you may trade this item with", 1, true)
                and lower:find("eligible to loot this item", 1, true) then
                return ParseRemainingTime(lower), text
            end
        end
    end
    return nil
end

local function ShowAlert(itemLink, remaining, owner)
    local ownerText = owner and not IsSamePlayer(owner, UnitName("player")) and (" held by " .. tostring(owner)) or ""
    local message = "TRADE TIMER: " .. tostring(itemLink or "item") .. ownerText .. " has " .. FormatTime(remaining) .. " remaining"
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
        RaidNotice_AddMessage(RaidWarningFrame, message, ChatTypeInfo["RAID_WARNING"])
    elseif UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(message, 1.0, 0.2, 0.2, 1.0)
    end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ARR|r: " .. message)
    end
    if PlaySound then pcall(PlaySound, "RaidWarning") end
end

local function AlertLocalMasterLooter(entry)
    if not IsCurrentMasterLooter() then return false end
    ShowAlert(entry.link, entry.remaining)
    return true
end

local function CreateFrameUI()
    if Timers.frame then return Timers.frame end
    local frame = CreateFrame("Frame", "AscensionRaidRollsTradeTimersFrame", UIParent)
    frame:SetWidth(250)
    frame:SetHeight(42)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 8, edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    frame:SetBackdropColor(0, 0, 0, 0.78)
    frame:SetBackdropBorderColor(0.18, 0.18, 0.18, 0.95)
    frame:SetPoint("CENTER", UIParent, "CENTER", -320, 100)

    frame.header = frame:CreateTexture(nil, "BACKGROUND")
    frame.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    frame.header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    frame.header:SetHeight(HEADER_HEIGHT - 2)
    frame.header:SetTexture(0.02, 0.02, 0.02, 0.92)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, -5)
    frame.title:SetText("Trade expiration timers")
    frame.title:SetTextColor(1, 1, 1)

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetWidth(20)
    frame.close:SetHeight(20)
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 1, 1)
    frame.close:SetScript("OnClick", function() Timers.manualHidden = true; Timers.forceShown = false; frame:Hide() end)

    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.empty:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, -25)
    frame.empty:SetText("No temporarily tradeable items")
    frame.empty:SetTextColor(0.60, 0.60, 0.60)
    frame.empty:Hide()
    frame.rows = {}

    local i
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, frame)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -(HEADER_HEIGHT + ((i - 1) * ROW_HEIGHT)))
        row:SetPoint("RIGHT", frame, "RIGHT", -1, 0)
        row:EnableMouse(true)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(ROW_HEIGHT)
        row.icon:SetHeight(ROW_HEIGHT)
        row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

        row.bar = CreateFrame("StatusBar", nil, row)
        row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", ROW_HEIGHT, 0)
        row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        row.bar:EnableMouse(true)
        row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        row.bar:SetMinMaxValues(0, DEFAULT_WINDOW)
        row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
        row.bar.bg:SetAllPoints(row.bar)
        row.bar.bg:SetTexture(0.02, 0.02, 0.02, 0.76)

        row.name = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.bar, "LEFT", 4, 0)
        row.name:SetJustifyH("LEFT")

        row.time = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.time:SetPoint("RIGHT", row.bar, "RIGHT", -4, 0)
        row.time:SetWidth(52)
        row.time:SetJustifyH("RIGHT")
        row.time:SetTextColor(1, 1, 1)
        row.name:SetPoint("RIGHT", row.time, "LEFT", -2, 0)
        if GameFontHighlightSmall and GameFontHighlightSmall.GetFont then
            local fontPath, fontSize = GameFontHighlightSmall:GetFont()
            if fontPath and fontSize then
                row.name:SetFont(fontPath, fontSize, "OUTLINE")
                row.time:SetFont(fontPath, fontSize, "OUTLINE")
            end
        end

        local function ShowTooltip(self)
            if self.entry and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.entry.link)
                GameTooltip:Show()
            end
        end
        local function HideTooltip() if GameTooltip then GameTooltip:Hide() end end
        row:SetScript("OnEnter", ShowTooltip)
        row:SetScript("OnLeave", HideTooltip)
        row.bar:SetScript("OnEnter", function() row.bar.entry = row.entry; ShowTooltip(row.bar) end)
        row.bar:SetScript("OnLeave", HideTooltip)
        local function SelectItemForRoll(self, button)
            if button ~= "RightButton" or not IsShiftKeyDown or not IsShiftKeyDown() then return end
            if row.entry and Addon.SetRollItem then
                Addon.SetRollItem(row.entry.link, row.entry.itemID)
            end
        end
        row:SetScript("OnMouseUp", SelectItemForRoll)
        row.bar:SetScript("OnMouseUp", SelectItemForRoll)
        row:Hide()
        frame.rows[i] = row
    end
    frame:Hide()
    Timers.frame = frame
    return frame
end

local function UpdateFrame()
    local frame = CreateFrameUI()
    local list = {}
    local _, entry
    for _, entry in pairs(Timers.entries) do list[#list + 1] = entry end
    table.sort(list, function(a, b) return (a.remaining or 0) < (b.remaining or 0) end)

    local i
    for i = 1, MAX_ROWS do
        local row = frame.rows[i]
        entry = list[i]
        if entry then
            row.entry = entry
            row.icon:SetTexture(entry.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText(entry.link or "Unknown item")
            row.time:SetText(FormatTime(entry.remaining))
            local maximum = math.max(DEFAULT_WINDOW, tonumber(entry.initialRemaining) or 0)
            row.bar:SetMinMaxValues(0, maximum)
            row.bar:SetValue(math.max(0, entry.remaining or 0))
            if entry.remaining <= ALERT_AT then
                row.bar:SetStatusBarColor(1.0, 0.0, 0.0, 0.38)
            elseif entry.remaining <= 60 * 60 then
                row.bar:SetStatusBarColor(1.0, 1.0, 0.0, 0.34)
            else
                row.bar:SetStatusBarColor(0.0, 1.0, 0.0, 0.30)
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
    if #list > 0 and not Timers.manualHidden then
        frame.empty:Hide()
        frame:SetHeight(HEADER_HEIGHT + (math.min(#list, MAX_ROWS) * ROW_HEIGHT) + 2)
        frame:Show()
    elseif #list == 0 and Timers.forceShown and not Timers.manualHidden then
        frame.empty:Show()
        frame:SetHeight(42)
        frame:Show()
    else
        frame.empty:Hide()
        frame:Hide()
    end
end

local function ScanBags()
    local found = {}
    local discoveredNewItem = false
    local bag, slot
    for bag = 0, 4 do
        local slots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink and GetContainerItemLink(bag, slot) or nil
            if link then
                local remaining = ReadTradeTime(bag, slot)
                if remaining then
                    local key = tostring(bag) .. ":" .. tostring(slot)
                    local previous = Timers.entries[key]
                    local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(link)
                    local itemID = tonumber(link:match("item:(%d+)"))
                    local entry = {
                        key = key,
                        bag = bag,
                        slot = slot,
                        link = link,
                        itemID = itemID,
                        texture = texture,
                        remaining = remaining,
                        initialRemaining = math.max(remaining, previous and previous.initialRemaining or 0),
                    }
                    found[key] = entry
                    if not previous then discoveredNewItem = true end
                    local alertKey = key .. "|" .. tostring(itemID or link)
                    if remaining <= ALERT_AT and not Timers.alerted[alertKey] then
                        if AlertLocalMasterLooter(entry) then
                            Timers.alerted[alertKey] = true
                        end
                    end
                end
            end
        end
    end
    Timers.entries = found
    if discoveredNewItem then Timers.manualHidden = false end
    UpdateFrame()
end

function Timers.Toggle()
    local frame = CreateFrameUI()
    if frame:IsShown() then
        Timers.manualHidden = true
        Timers.forceShown = false
        frame:Hide()
        return
    end
    Timers.manualHidden = false
    Timers.forceShown = true
    UpdateFrame()
end

SLASH_ASCENSIONRAIDROLLSTIMERS1 = "/rrtimers"
SlashCmdList["ASCENSIONRAIDROLLSTIMERS"] = Timers.Toggle

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= "AscensionRaidRolls" then return end
        CreateFrameUI()
        ScanBags()
    else
        Timers.scanElapsed = SCAN_INTERVAL
    end
end)

eventFrame:SetScript("OnUpdate", function(self, elapsed)
    Timers.scanElapsed = Timers.scanElapsed + (elapsed or 0)
    if Timers.scanElapsed >= SCAN_INTERVAL then
        Timers.scanElapsed = 0
        ScanBags()
    end
end)
