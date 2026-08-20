-- Legacy runtime coordinator. New independent systems belong in dedicated
-- Core, Features, Interface, or Utils modules and are loaded through the TOC.
local ADDON_NAME = "AscensionRaidRolls"

local rollsMS = {}
local rollsOS = {}
local raidMembers = {}
local firstRollByPlayer = {}
local sequence = 0
local mainFrame
local quickRollFrame
local optionsFrame
local minimapButton
local minimapDragging = false
local MINIMAP_BUTTON_RADIUS = 80
local PI = 3.141592653589793
local msPanel
local osPanel
local selectedRoll
local UpdateUI
local SetButtonEnabled
local rollPattern
local rollCaptureOrder
local currentItemLink
local currentItemID
local currentTopRolls = 1
local pendingTradeItemLink
local pendingTradeItemID
local pendingTradePlayer
local awardedPlayersForRoll = {}
local currentRollAwardOrder = {}
local syncedLootHistory = { MS = {}, OS = {} }
local syncedPlusOneEnabled = false
local syncedLootHistoryRevision = 0
local pendingSyncedLootHistory = nil
local autoMasterLootProcessing = false
local autoMasterLootTarget
local autoMasterLootAccumulator = 0
local autoMasterLootWaiting = false
local autoMasterLootWaitingLink
local autoMasterLootWaitingSince = 0
local autoMasterLootBindConfirmSlot
local autoMasterLootAssignedCount = 0
local rollTimerActive = false
local rollSessionStarted = false
local rollSessionOpen = true
local rollStartTime = 0
local rollEndTime = 0
local activeDuration = 15
local timerAlerted = {}
local timerAccumulator = 0

-- Tie-break state. A tie-break never replaces the original valid roll. Instead,
-- each participating player's tiePath stores successive reroll values. Sorting
-- compares this path lexicographically, so repeated ties can be resolved safely
-- without breaking the original "first roll counts" rule.
local tieBreakActive = false
local tieBreakType = nil
local tieBreakPlayers = {}
local tieBreakRoundRolls = {}
local tieBreakRound = 0
local FinishTieBreak

local MAX_HISTORY = 200
local DEFAULT_ROLL_DURATION = 15
local MIN_ROLL_DURATION = 5
local MAX_ROLL_DURATION = 300

-- Raid synchronization -----------------------------------------------------------
-- The active Master Looter is the authoritative host for timed roll sessions.
-- Other raid members receive the item, timer state, and accepted rolls through
-- addon messages and operate the main window in viewer mode.
local SYNC_PREFIX = "ARRSYNC"
local SYNC_PROTOCOL = 2
local ADDON_VERSION = (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")) or "1.8.0"
local latestSeenVersion = ADDON_VERSION
local notifiedNewerVersions = {}
local syncSessionID = nil
local syncOwner = nil
local syncStateRequested = false
local syncReceivingState = false
local GetActualMasterLooterName
local CanControlRolls
local UpdateControlState
local BroadcastRollSync
local BroadcastSessionEnd
local SendFullSyncState
local IsRemoteSyncedSession
local BroadcastLootHistory
local BroadcastLootCount
local UpdateOptionsControlState
local IsInRaid

local function Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ARR|r: " .. tostring(message))
    end
end

local function Trim(text)
    if not text then
        return nil
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function NormalizeName(name)
    name = Trim(name)
    if not name or name == "" then
        return nil
    end

    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")

    if YOU and name == YOU then
        name = UnitName("player") or name
    end

    local shortName = name:match("^([^%-]+)") or name
    return string.lower(shortName)
end

local function IsSamePlayerName(a, b)
    local aKey = NormalizeName(a)
    local bKey = NormalizeName(b)
    return aKey ~= nil and bKey ~= nil and aKey == bKey
end

local function ShouldUseSyncedLootHistory()
    return IsInRaid()
        and syncOwner ~= nil
        and not IsSamePlayerName(syncOwner, UnitName("player"))
end

local function IsMSOSPlusOneEnabled()
    if ShouldUseSyncedLootHistory() then
        return syncedPlusOneEnabled == true
    end
    return AscensionRaidRollsDB and AscensionRaidRollsDB.msosPlusOneEnabled == true
end

local function GetActiveLootHistory()
    if ShouldUseSyncedLootHistory() then
        return syncedLootHistory
    end
    return AscensionRaidRollsDB and AscensionRaidRollsDB.lootHistory or nil
end

local function GetLootWinCount(name, rollType)
    if not IsMSOSPlusOneEnabled() then
        return 0
    end

    local playerKey = NormalizeName(name)
    local history = GetActiveLootHistory()
    rollType = rollType == "OS" and "OS" or "MS"
    local typedHistory = type(history) == "table" and history[rollType] or nil
    return playerKey and type(typedHistory) == "table" and tonumber(typedHistory[playerKey]) or 0
end

local function GetRollDisplayName(name, rollType)
    local count = GetLootWinCount(name, rollType)
    if count > 0 then
        return tostring(name) .. " |cff73e68a+" .. tostring(count) .. "|r"
    end
    return tostring(name)
end

local function AdjustLootWinCount(name, rollType, delta, broadcast)
    if not AscensionRaidRollsDB or AscensionRaidRollsDB.msosPlusOneEnabled ~= true then
        return false
    end

    local playerKey = NormalizeName(name)
    if not playerKey then
        return false
    end

    rollType = rollType == "OS" and "OS" or "MS"
    AscensionRaidRollsDB.lootHistory = AscensionRaidRollsDB.lootHistory or { MS = {}, OS = {} }
    AscensionRaidRollsDB.lootHistory.MS = AscensionRaidRollsDB.lootHistory.MS or {}
    AscensionRaidRollsDB.lootHistory.OS = AscensionRaidRollsDB.lootHistory.OS or {}
    local typedHistory = AscensionRaidRollsDB.lootHistory[rollType]
    local nextCount = math.max(0, (tonumber(typedHistory[playerKey]) or 0) + (tonumber(delta) or 0))
    if nextCount > 0 then
        typedHistory[playerKey] = nextCount
    else
        typedHistory[playerKey] = nil
    end
    if broadcast and BroadcastLootCount then
        BroadcastLootCount(playerKey, rollType, nextCount)
    end
    return true
end

local function RecordLootWin(name, rollType)
    if not AscensionRaidRollsDB or AscensionRaidRollsDB.msosPlusOneEnabled ~= true then
        return false
    end

    local playerKey = NormalizeName(name)
    if not playerKey or awardedPlayersForRoll[playerKey] then
        return false
    end
    rollType = rollType == "OS" and "OS" or "MS"

    local maximumWinners = math.max(1, tonumber(currentTopRolls) or 1)
    if #currentRollAwardOrder >= maximumWinners then
        local replacedAward = table.remove(currentRollAwardOrder)
        if replacedAward then
            awardedPlayersForRoll[replacedAward.playerKey] = nil
            AdjustLootWinCount(replacedAward.playerKey, replacedAward.rollType, -1, true)
        end
    end

    currentRollAwardOrder[#currentRollAwardOrder + 1] = { playerKey = playerKey, rollType = rollType }
    awardedPlayersForRoll[playerKey] = true
    AdjustLootWinCount(playerKey, rollType, 1, true)
    return true
end

local function ClearLootHistory()
    if IsInRaid() and (not CanControlRolls or not CanControlRolls()) then
        Print("only the current Master Looter can clear the shared MS/OS+1 history.")
        return false
    end
    AscensionRaidRollsDB.lootHistory = { MS = {}, OS = {} }
    awardedPlayersForRoll = {}
    currentRollAwardOrder = {}
    if BroadcastLootHistory then
        BroadcastLootHistory()
    end
    if UpdateUI then
        UpdateUI()
    end
    Print("MS/OS+1 loot history cleared.")
    return true
end

IsInRaid = function()
    return (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
end

-- Base64 and JSON codecs are loaded from Features/SoftRes/Codec.lua.

function AscensionRaidRollsSoftRes.IsPriorityEnabled()
    if ShouldUseSyncedLootHistory() then
        return AscensionRaidRollsSoftRes.syncedPriorityEnabled == true
    end
    return AscensionRaidRollsDB and AscensionRaidRollsDB.reservePriorityEnabled == true
end

function AscensionRaidRollsSoftRes.GetData()
    return AscensionRaidRollsDB and AscensionRaidRollsDB.reserveData or nil
end

function AscensionRaidRollsSoftRes.IsPlayerSoftReserved(name, itemID)
    return AscensionRaidRollsSoftRes.GetPlayerReserveCount(name, itemID) > 0
end

function AscensionRaidRollsSoftRes.GetPlayerReserveCount(name, itemID)
    if not AscensionRaidRollsSoftRes.IsPriorityEnabled() then
        return 0
    end
    local playerKey = NormalizeName(name)
    local itemKey = tostring(tonumber(itemID) or 0)
    if not playerKey or itemKey == "0" then
        return 0
    end
    if ShouldUseSyncedLootHistory() then
        return math.max(0, math.floor(tonumber(AscensionRaidRollsSoftRes.syncedPlayers[playerKey]) or 0))
    end
    local data = AscensionRaidRollsSoftRes.GetData()
    return data and data.byItem and data.byItem[itemKey] and math.max(0, math.floor(tonumber(data.byItem[itemKey][playerKey]) or 0)) or 0
end

function AscensionRaidRollsSoftRes.GetTooltipReservations(itemID)
    if not AscensionRaidRollsSoftRes.IsPriorityEnabled() then
        return nil
    end

    local itemKey = tostring(tonumber(itemID) or 0)
    if itemKey == "0" then
        return nil
    end

    local reservations
    local roster
    if ShouldUseSyncedLootHistory() then
        if not currentItemID or tonumber(currentItemID) ~= tonumber(itemID) then
            return nil
        end
        reservations = AscensionRaidRollsSoftRes.syncedPlayers
    else
        local data = AscensionRaidRollsSoftRes.GetData()
        reservations = data and data.byItem and data.byItem[itemKey] or nil
        roster = data and data.roster or nil
    end
    if type(reservations) ~= "table" then
        return nil
    end

    local result = {}
    local playerKey, count
    for playerKey, count in pairs(reservations) do
        count = math.max(0, math.floor(tonumber(count) or 0))
        if count > 0 then
            local rosterEntry = roster and roster[playerKey] or nil
            local raidEntry = raidMembers and raidMembers[playerKey] or nil
            result[#result + 1] = {
                name = rosterEntry and rosterEntry.name or raidEntry and raidEntry.name or playerKey,
                count = count,
            }
        end
    end
    table.sort(result, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return result
end

function AscensionRaidRollsSoftRes.GetCurrentHardReserve()
    if not AscensionRaidRollsSoftRes.IsPriorityEnabled() then
        return nil
    end
    if ShouldUseSyncedLootHistory() then
        return AscensionRaidRollsSoftRes.syncedHardReserve and true or nil
    end
    local data = AscensionRaidRollsSoftRes.GetData()
    return data and data.hardItems and data.hardItems[tostring(tonumber(currentItemID) or 0)] or nil
end

function AscensionRaidRollsSoftRes.SetImportStatus(message, isError)
    if optionsFrame and optionsFrame.reserveStatus then
        optionsFrame.reserveStatus:SetText(tostring(message or ""))
        if isError then
            optionsFrame.reserveStatus:SetTextColor(1.0, 0.35, 0.35)
        else
            optionsFrame.reserveStatus:SetTextColor(0.45, 0.95, 0.55)
        end
    end
    if AscensionRaidRollsSoftRes.importFrame and AscensionRaidRollsSoftRes.importFrame.status then
        AscensionRaidRollsSoftRes.importFrame.status:SetText(tostring(message or ""))
        if isError then
            AscensionRaidRollsSoftRes.importFrame.status:SetTextColor(1.0, 0.35, 0.35)
        else
            AscensionRaidRollsSoftRes.importFrame.status:SetTextColor(0.45, 0.95, 0.55)
        end
    end
end

function AscensionRaidRollsSoftRes.ImportExport(encoded)
    if IsInRaid() and (not CanControlRolls or not CanControlRolls()) then
        AscensionRaidRollsSoftRes.SetImportStatus("Only the Master Looter can import reserves in a raid.", true)
        return false
    end

    local decoded, decodeError = AscensionRaidRollsSoftRes.DecodeBase64(encoded)
    if not decoded then
        AscensionRaidRollsSoftRes.SetImportStatus("Import failed: " .. tostring(decodeError), true)
        return false
    end
    local root, jsonError = AscensionRaidRollsSoftRes.DecodeJSON(decoded)
    if type(root) ~= "table" then
        AscensionRaidRollsSoftRes.SetImportStatus("Import failed: " .. tostring(jsonError or "invalid JSON"), true)
        return false
    end
    if type(root.softreserves) ~= "table" or type(root.hardreserves) ~= "table" then
        AscensionRaidRollsSoftRes.SetImportStatus("Import failed: missing softreserves/hardreserves lists.", true)
        return false
    end

    local reserveData = {
        metadata = root.metadata or {},
        roster = {},
        byItem = {},
        hardItems = {},
    }
    local playerCount = 0
    local reserveCount = 0
    local _, playerData
    for _, playerData in ipairs(root.softreserves) do
        if type(playerData) == "table" and type(playerData.name) == "string" then
            local playerKey = NormalizeName(playerData.name)
            if playerKey then
                local rosterEntry = { name = playerData.name, itemCount = 0 }
                reserveData.roster[playerKey] = rosterEntry
                playerCount = playerCount + 1
                if type(playerData.items) == "table" then
                    local _, itemData
                    for _, itemData in ipairs(playerData.items) do
                        local itemID = type(itemData) == "table" and tonumber(itemData.id) or tonumber(itemData)
                        if itemID then
                            local itemKey = tostring(math.floor(itemID))
                            reserveData.byItem[itemKey] = reserveData.byItem[itemKey] or {}
                            reserveData.byItem[itemKey][playerKey] = (tonumber(reserveData.byItem[itemKey][playerKey]) or 0) + 1
                            rosterEntry.itemCount = rosterEntry.itemCount + 1
                            reserveCount = reserveCount + 1
                        end
                    end
                end
            end
        end
    end

    local hardCount = 0
    local function AddHardReserve(itemID, owner)
        itemID = tonumber(itemID)
        if itemID then
            reserveData.hardItems[tostring(math.floor(itemID))] = owner or true
            hardCount = hardCount + 1
        end
    end
    local _, hardData
    for _, hardData in pairs(root.hardreserves) do
        if type(hardData) == "number" then
            AddHardReserve(hardData)
        elseif type(hardData) == "table" then
            AddHardReserve(hardData.id or hardData.itemId, hardData.name or hardData.player)
            if type(hardData.items) == "table" then
                local _, itemData
                for _, itemData in ipairs(hardData.items) do
                    AddHardReserve(type(itemData) == "table" and (itemData.id or itemData.itemId) or itemData, hardData.name or hardData.player)
                end
            end
        end
    end

    AscensionRaidRollsDB.reserveData = reserveData
    AscensionRaidRollsDB.reserveImportText = Trim(encoded)
    AscensionRaidRollsSoftRes.SetImportStatus(tostring(playerCount) .. " players, " .. tostring(reserveCount) .. " SR, " .. tostring(hardCount) .. " HR imported.", false)
    Print("SoftRes import complete: " .. tostring(playerCount) .. " players, " .. tostring(reserveCount) .. " reservations, " .. tostring(hardCount) .. " hard reserves.")
    if AscensionRaidRollsSoftRes.BroadcastCurrentState then
        AscensionRaidRollsSoftRes.BroadcastCurrentState()
    end
    if UpdateUI then UpdateUI() end
    return true
end

-- A remote synchronized session exists only while the player is actually in
-- a raid. Outside a raid ARR switches to Standalone Mode and deliberately
-- ignores any stale ML/viewer state left over from a previous raid.
IsRemoteSyncedSession = function()
    if not IsInRaid() then
        return false
    end

    return syncSessionID ~= nil
        and syncOwner ~= nil
        and not IsSamePlayerName(syncOwner, UnitName("player"))
end

local function SendSyncRaw(message, channel, target)
    if not SendAddonMessage then
        return false
    end

    channel = channel or "RAID"
    if channel == "RAID" and not IsInRaid() then
        return false
    end
    if channel == "WHISPER" then
        if not target or target == "" then
            return false
        end
        SendAddonMessage(SYNC_PREFIX, message, channel, target)
    else
        SendAddonMessage(SYNC_PREFIX, message, channel)
    end
    return true
end

BroadcastLootHistory = function(channel, target)
    if not AscensionRaidRollsDB or not CanControlRolls or not CanControlRolls() then
        return false
    end

    channel = channel or "RAID"
    AscensionRaidRollsDB.lootHistoryRevision = (tonumber(AscensionRaidRollsDB.lootHistoryRevision) or 0) + 1
    local revision = AscensionRaidRollsDB.lootHistoryRevision
    local enabled = AscensionRaidRollsDB.msosPlusOneEnabled == true and "1" or "0"
    SendSyncRaw("PLUSBEGIN\t" .. tostring(revision) .. "\t" .. enabled, channel, target)

    local _, rollType
    for _, rollType in ipairs({ "MS", "OS" }) do
        local playerKey, count
        for playerKey, count in pairs((AscensionRaidRollsDB.lootHistory and AscensionRaidRollsDB.lootHistory[rollType]) or {}) do
            count = math.max(0, math.floor(tonumber(count) or 0))
            if count > 0 then
                SendSyncRaw("PLUSENTRY\t" .. tostring(revision) .. "\t" .. tostring(rollType) .. "\t" .. tostring(playerKey) .. "\t" .. tostring(count), channel, target)
            end
        end
    end

    SendSyncRaw("PLUSEND\t" .. tostring(revision), channel, target)
    return true
end

AscensionRaidRollsSoftRes.BroadcastCurrentState = function(channel, target)
    if not AscensionRaidRollsDB or not CanControlRolls or not CanControlRolls() then
        return false
    end

    channel = channel or "RAID"
    local sessionID = tostring(syncSessionID or "0")
    local enabled = AscensionRaidRollsDB.reservePriorityEnabled == true and "1" or "0"
    local hardReserved = AscensionRaidRollsSoftRes.GetCurrentHardReserve() and "1" or "0"
    SendSyncRaw("SRSTATE\t" .. sessionID .. "\t" .. enabled .. "\t" .. hardReserved, channel, target)

    if enabled == "1" and currentItemID then
        local data = AscensionRaidRollsSoftRes.GetData()
        local reservations = data and data.byItem and data.byItem[tostring(tonumber(currentItemID) or 0)] or nil
        local playerKey
        local playerKey, reserveCount
        for playerKey, reserveCount in pairs(reservations or {}) do
            SendSyncRaw("SRPLAYER\t" .. sessionID .. "\t" .. tostring(playerKey) .. "\t" .. tostring(math.max(1, tonumber(reserveCount) or 1)), channel, target)
        end
    end
    return true
end

BroadcastLootCount = function(playerKey, rollType, count)
    if not IsInRaid() or not CanControlRolls or not CanControlRolls() then
        return false
    end

    AscensionRaidRollsDB.lootHistoryRevision = (tonumber(AscensionRaidRollsDB.lootHistoryRevision) or 0) + 1
    local revision = AscensionRaidRollsDB.lootHistoryRevision
    rollType = rollType == "OS" and "OS" or "MS"
    return SendSyncRaw("PLUSSET\t" .. tostring(revision) .. "\t" .. tostring(rollType) .. "\t" .. tostring(playerKey) .. "\t" .. tostring(math.max(0, tonumber(count) or 0)), "RAID")
end

local function NotifyNewerVersion(version, sender)
    if not AscensionRaidRolls.Version.IsNewer(version, ADDON_VERSION) then
        return
    end

    if AscensionRaidRolls.Version.IsNewer(version, latestSeenVersion) then
        latestSeenVersion = version
    end

    if notifiedNewerVersions[version] then
        return
    end
    notifiedNewerVersions[version] = true

    local who = sender and (" (seen on " .. tostring(sender) .. ")") or ""
    Print("UPDATE AVAILABLE: v" .. tostring(version) .. who .. ". You are using v" .. tostring(ADDON_VERSION) .. ". Check the AscensionRaidRolls GitHub release page.")
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage("AscensionRaidRolls update available: v" .. tostring(version), 1.0, 0.25, 0.25, 1.0)
    end
end

local function BroadcastVersion()
    local payload = "VER\t" .. tostring(SYNC_PROTOCOL) .. "\t" .. tostring(ADDON_VERSION)
    if IsInRaid() then
        SendSyncRaw(payload, "RAID")
    end
    if IsInGuild and IsInGuild() then
        SendSyncRaw(payload, "GUILD")
    elseif GetGuildInfo and GetGuildInfo("player") then
        SendSyncRaw(payload, "GUILD")
    end
end

local function GenerateSessionID()
    local name = UnitName("player") or "player"
    local stamp = math.floor(((GetTime and GetTime()) or 0) * 1000)
    return tostring(name) .. ":" .. tostring(stamp)
end

local function IsSenderCurrentMasterLooter(sender)
    if not GetActualMasterLooterName then
        return false
    end

    local actualMaster, method = GetActualMasterLooterName()
    if method ~= "master" or not actualMaster then
        return false
    end

    return IsSamePlayerName(sender, actualMaster)
end

local function RequestSyncState()
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidCount <= 0 or not SendAddonMessage then
        return false
    end

    syncStateRequested = true
    return SendSyncRaw("REQ\t" .. tostring(SYNC_PROTOCOL), "RAID")
end

local function EscapePatternChar(char)
    if char:find("[%^%$%(%)%%%.%[%]%*%+%-%?]") then
        return "%" .. char
    end
    return char
end

local function BuildRollPattern()
    local formatString = RANDOM_ROLL_RESULT
    if type(formatString) ~= "string" or formatString == "" then
        return nil, nil
    end

    local pattern = "^"
    local captureOrder = {}
    local nextArgument = 1
    local i = 1

    while i <= #formatString do
        local char = formatString:sub(i, i)

        if char == "%" then
            local rest = formatString:sub(i)
            local position, specifier = rest:match("^%%(%d+)%$([sd])")

            if position and specifier then
                position = tonumber(position)
                captureOrder[#captureOrder + 1] = position
                if specifier == "d" then
                    pattern = pattern .. "(%d+)"
                else
                    pattern = pattern .. "(.+)"
                end
                i = i + 3 + #tostring(position)
            else
                specifier = formatString:sub(i + 1, i + 1)

                if specifier == "s" or specifier == "d" then
                    captureOrder[#captureOrder + 1] = nextArgument
                    nextArgument = nextArgument + 1
                    if specifier == "d" then
                        pattern = pattern .. "(%d+)"
                    else
                        pattern = pattern .. "(.+)"
                    end
                    i = i + 2
                elseif specifier == "%" then
                    pattern = pattern .. "%%"
                    i = i + 2
                else
                    pattern = pattern .. "%%"
                    i = i + 1
                end
            end
        else
            pattern = pattern .. EscapePatternChar(char)
            i = i + 1
        end
    end

    pattern = pattern .. "$"
    return pattern, captureOrder
end

local function ParseRollMessage(message)
    if not rollPattern then
        rollPattern, rollCaptureOrder = BuildRollPattern()
    end

    if rollPattern and rollCaptureOrder then
        local captures = { string.match(message, rollPattern) }
        if #captures > 0 then
            local args = {}
            for index, argumentPosition in ipairs(rollCaptureOrder) do
                args[argumentPosition] = captures[index]
            end

            local playerName = args[1]
            local roll = tonumber(args[2])
            local minimum = tonumber(args[3])
            local maximum = tonumber(args[4])

            if playerName and roll and minimum and maximum then
                return Trim(playerName), roll, minimum, maximum
            end
        end
    end

    local minimum, maximum = message:match("%((%d+)%s*%-%s*(%d+)%)%s*$")
    minimum = tonumber(minimum)
    maximum = tonumber(maximum)

    if not minimum or not maximum then
        return nil
    end

    local prefix = message:gsub("%s*%(%d+%s*%-%s*%d+%)%s*$", "")
    local numbers = {}
    for number in prefix:gmatch("%d+") do
        numbers[#numbers + 1] = tonumber(number)
    end

    if #numbers == 0 then
        return nil
    end

    local roll = numbers[#numbers]
    local rollText = tostring(roll)
    local playerName = prefix:match("^(.-)%s+[^%s]*" .. rollText .. "%s*$")

    if not playerName or playerName == "" then
        return nil
    end

    playerName = playerName:match("^([^%s]+)") or playerName
    return Trim(playerName), roll, minimum, maximum
end

local function RefreshRaidMembers()
    raidMembers = {}

    local count = GetNumRaidMembers and GetNumRaidMembers() or 0
    for i = 1, count do
        local name, rank, subgroup, level, class, classFile = GetRaidRosterInfo(i)
        local key = NormalizeName(name)
        if key then
            raidMembers[key] = {
                name = name,
                classFile = classFile,
                rank = rank or 0,
                index = i,
            }
        end
    end
end

local function IsRaidMember(name)
    if not name then
        return false
    end

    local count = GetNumRaidMembers and GetNumRaidMembers() or 0
    if count <= 0 then
        return false
    end

    local key = NormalizeName(name)
    if key and raidMembers[key] then
        return true
    end

    RefreshRaidMembers()
    return key and raidMembers[key] ~= nil
end

-- Outside a raid, rolls are tracked locally so the addon can be fully tested
-- solo or in a normal party. Accept the player and visible party members.
local function IsLocalGroupMember(name)
    local key = NormalizeName(name)
    if not key then
        return false
    end

    if IsSamePlayerName(name, UnitName("player")) then
        return true
    end

    local i
    for i = 1, 4 do
        local partyName = UnitName and UnitName("party" .. i) or nil
        if partyName and IsSamePlayerName(name, partyName) then
            return true
        end
    end

    return false
end

local function GetClassColorCode(name)
    local key = NormalizeName(name)
    local member = key and raidMembers[key]
    local classFile = member and member.classFile

    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local color = RAID_CLASS_COLORS[classFile]
        return string.format("|cff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
    end

    return "|cffffffff"
end

local function CompareTiePaths(a, b)
    local pathA = a.tiePath or {}
    local pathB = b.tiePath or {}
    local maxLen = math.max(#pathA, #pathB)
    local i

    for i = 1, maxLen do
        local valueA = pathA[i]
        local valueB = pathB[i]

        if valueA ~= nil and valueB ~= nil and valueA ~= valueB then
            return valueA > valueB
        end

        -- A different path length should normally only happen after the players
        -- were already separated by an earlier tie-break value. If it does occur,
        -- keep the shorter path stable instead of inventing a result.
        if valueA == nil or valueB == nil then
            break
        end
    end

    return nil
end

local function GetTieSignature(entry)
    if not entry then
        return nil
    end

    local parts = { tostring(entry.roll or 0) }
    local path = entry.tiePath or {}
    local i
    for i = 1, #path do
        parts[#parts + 1] = tostring(path[i])
    end
    return table.concat(parts, ":")
end

local function SortRolls(list)
    table.sort(list, function(a, b)
        if a.isSoftReserved ~= b.isSoftReserved then
            return a.isSoftReserved == true
        end
        if a.roll ~= b.roll then
            return a.roll > b.roll
        end

        local tieCompare = CompareTiePaths(a, b)
        if tieCompare ~= nil then
            return tieCompare
        end

        return a.sequence < b.sequence
    end)
end

local function GetAllRolls()
    local all = {}
    local i

    for i = 1, #rollsMS do
        all[#all + 1] = rollsMS[i]
    end

    for i = 1, #rollsOS do
        all[#all + 1] = rollsOS[i]
    end

    return all
end

local function RefreshDuplicateFlags()
    local counts = {}
    local tieCounts = {}
    local all = GetAllRolls()
    local i

    for i = 1, #all do
        local entry = all[i]
        counts[entry.playerKey] = (counts[entry.playerKey] or 0) + 1
    end

    for i = 1, #all do
        local entry = all[i]
        if entry.isFirst == nil then
            entry.isFirst = firstRollByPlayer[entry.playerKey] == entry.sequence
        end
        entry.isReroll = not entry.isFirst
        entry.hasDuplicate = (counts[entry.playerKey] or 0) > 1
        entry.isTied = false

        if entry.isFirst then
            local tieKey = tostring(entry.type or "") .. "|" .. tostring(GetTieSignature(entry) or "")
            tieCounts[tieKey] = (tieCounts[tieKey] or 0) + 1
        end
    end

    for i = 1, #all do
        local entry = all[i]
        if entry.isFirst then
            local tieKey = tostring(entry.type or "") .. "|" .. tostring(GetTieSignature(entry) or "")
            entry.isTied = (tieCounts[tieKey] or 0) > 1
        end
    end
end

local function FindValidEntry(playerKey, rollType)
    local list = rollType == "OS" and rollsOS or rollsMS
    local i
    for i = 1, #list do
        local entry = list[i]
        if entry.playerKey == playerKey and entry.isFirst then
            return entry
        end
    end
    return nil
end

local function GetTieGroupForEntry(entry)
    local group = {}
    if not entry or not entry.isFirst or not entry.isTied then
        return group
    end

    local list = entry.type == "OS" and rollsOS or rollsMS
    local signature = GetTieSignature(entry)
    local i
    for i = 1, #list do
        local candidate = list[i]
        if candidate.isFirst and GetTieSignature(candidate) == signature then
            group[#group + 1] = candidate
        end
    end

    table.sort(group, function(a, b)
        return (a.sequence or 0) < (b.sequence or 0)
    end)
    return group
end

local function GetValidCount(list)
    local count = 0
    local i
    for i = 1, #list do
        if list[i].isFirst then
            count = count + 1
        end
    end
    return count
end

local function GetWinner()
    local bestMS
    local bestOS
    local i

    for i = 1, #rollsMS do
        local entry = rollsMS[i]
        if entry.isFirst then
            if not bestMS
                or (entry.isSoftReserved and not bestMS.isSoftReserved)
                or (entry.isSoftReserved == bestMS.isSoftReserved and (entry.roll > bestMS.roll or (entry.roll == bestMS.roll and entry.sequence < bestMS.sequence))) then
                bestMS = entry
            end
        end
    end

    if bestMS then
        return bestMS
    end

    for i = 1, #rollsOS do
        local entry = rollsOS[i]
        if entry.isFirst then
            if not bestOS or entry.roll > bestOS.roll or (entry.roll == bestOS.roll and entry.sequence < bestOS.sequence) then
                bestOS = entry
            end
        end
    end

    return bestOS
end

local function UpdatePanel(panel, list)
    if not panel then
        return
    end

    SortRolls(list)

    local rowHeight = 22
    local minimumHeight = panel.scroll:GetHeight()
    local contentHeight = math.max(minimumHeight, #list * rowHeight)
    panel.content:SetHeight(contentHeight)

    local validRank = 0
    local i
    for i = 1, #list do
        local row = panel.rows[i]
        if not row then
            row = CreateFrame("Button", nil, panel.content)
            row:SetHeight(rowHeight)
            row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -((i - 1) * rowHeight))
            row:SetPoint("RIGHT", panel.content, "RIGHT", 0, 0)
            row:RegisterForClicks("LeftButtonUp")

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints(row)

            row.selection = row:CreateTexture(nil, "BORDER")
            row.selection:SetAllPoints(row)
            row.selection:SetTexture(0.18, 0.52, 0.95, 0.32)
            row.selection:Hide()

            row.hover = row:CreateTexture(nil, "HIGHLIGHT")
            row.hover:SetAllPoints(row)
            row.hover:SetTexture(1, 1, 1, 0.08)

            row:SetScript("OnClick", function(self)
                if not self.entry then
                    return
                end

                if CanControlRolls and not CanControlRolls() then
                    return
                end

                selectedRoll = self.entry
                if UpdateUI then
                    UpdateUI()
                end
            end)

            row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.rank:SetPoint("LEFT", row, "LEFT", 3, 0)
            row.rank:SetWidth(22)
            row.rank:SetJustifyH("RIGHT")

            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", row.rank, "RIGHT", 5, 0)
            row.name:SetWidth(100)
            row.name:SetJustifyH("LEFT")

            row.minusButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.minusButton:SetWidth(14)
            row.minusButton:SetHeight(14)
            row.minusButton:SetText("-")
            row.minusButton:SetScript("OnClick", function(self)
                local entry = self:GetParent().entry
                if entry and CanControlRolls and CanControlRolls() then
                    AdjustLootWinCount(entry.name, entry.type, -1, true)
                    UpdateUI()
                end
            end)

            row.plusButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.plusButton:SetWidth(14)
            row.plusButton:SetHeight(14)
            row.plusButton:SetPoint("RIGHT", row, "RIGHT", -3, 0)
            row.plusButton:SetText("+")
            row.plusButton:SetScript("OnClick", function(self)
                local entry = self:GetParent().entry
                if entry and CanControlRolls and CanControlRolls() then
                    AdjustLootWinCount(entry.name, entry.type, 1, true)
                    UpdateUI()
                end
            end)

            row.minusButton:SetPoint("RIGHT", row.plusButton, "LEFT", -1, 0)

            row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.status:SetPoint("LEFT", row.name, "RIGHT", 2, 0)
            row.status:SetWidth(36)
            row.status:SetJustifyH("CENTER")

            row.value = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.value:SetPoint("RIGHT", row.minusButton, "LEFT", -2, 0)
            row.value:SetWidth(34)
            row.value:SetJustifyH("RIGHT")

            panel.rows[i] = row
        end

        local entry = list[i]
        row.entry = entry

        local showAdjustmentButtons = entry.isFirst and IsMSOSPlusOneEnabled()
        if showAdjustmentButtons then
            local canAdjust = CanControlRolls and CanControlRolls() or false
            row.minusButton:Show()
            row.plusButton:Show()
            SetButtonEnabled(row.minusButton, canAdjust)
            SetButtonEnabled(row.plusButton, canAdjust)
        else
            row.minusButton:Hide()
            row.plusButton:Hide()
        end

        if entry.isFirst then
            validRank = validRank + 1
            row.rank:SetText(validRank .. ".")
            row.name:SetText(GetClassColorCode(entry.name) .. GetRollDisplayName(entry.name, entry.type) .. "|r")
            row.value:SetText(entry.roll)
            row.rank:SetTextColor(1, 1, 1)
            row.value:SetTextColor(1, 0.82, 0.20)

            local latestTieRoll = entry.tiePath and entry.tiePath[#entry.tiePath] or nil
            local isCurrentTiePlayer = tieBreakActive and tieBreakPlayers[entry.playerKey] and entry.type == tieBreakType

            if isCurrentTiePlayer and tieBreakRoundRolls[entry.playerKey] then
                row.status:SetText("TB " .. tostring(tieBreakRoundRolls[entry.playerKey]))
                row.status:SetTextColor(0.35, 1.0, 0.35)
                row.bg:SetTexture(0.55, 0.35, 0.05, 0.24)
            elseif isCurrentTiePlayer then
                row.status:SetText("TIE")
                row.status:SetTextColor(1.0, 0.65, 0.15)
                row.bg:SetTexture(0.65, 0.35, 0.02, 0.24)
            elseif entry.isTied then
                row.status:SetText("TIE")
                row.status:SetTextColor(1.0, 0.65, 0.15)
                row.bg:SetTexture(0.65, 0.35, 0.02, 0.24)
            elseif latestTieRoll then
                row.status:SetText("TB " .. tostring(latestTieRoll))
                row.status:SetTextColor(0.45, 0.95, 0.55)
                row.bg:SetTexture(0.08, 0.45, 0.18, 0.16)
            elseif entry.isSoftReserved then
                row.status:SetText(tostring(entry.softReserveIndex or 1) .. "xSR")
                row.status:SetTextColor(0.75, 0.45, 1.0)
                row.bg:SetTexture(0.38, 0.12, 0.60, 0.22)
            elseif entry.hasDuplicate then
                row.status:SetText("FIRST")
                row.status:SetTextColor(0.35, 1.0, 0.35)
                row.bg:SetTexture(0.10, 0.55, 0.10, 0.20)
            else
                row.status:SetText("")
                if (i % 2) == 0 then
                    row.bg:SetTexture(1, 1, 1, 0.035)
                else
                    row.bg:SetTexture(0, 0, 0, 0)
                end
            end
        else
            row.rank:SetText("x")
            row.rank:SetTextColor(1.0, 0.35, 0.35)
            row.name:SetText("|cff888888" .. GetRollDisplayName(entry.name, entry.type) .. "|r")
            row.status:SetText("REROLL")
            row.status:SetTextColor(1.0, 0.35, 0.35)
            row.value:SetText(entry.roll)
            row.value:SetTextColor(0.65, 0.65, 0.65)
            row.bg:SetTexture(0.60, 0.08, 0.08, 0.18)
        end

        if selectedRoll == entry then
            row.selection:Show()
        else
            row.selection:Hide()
        end

        row:Show()
    end

    for i = #list + 1, #panel.rows do
        panel.rows[i].entry = nil
        panel.rows[i].selection:Hide()
        panel.rows[i]:Hide()
    end
end

SetButtonEnabled = function(button, enabled)
    if not button then
        return
    end

    if enabled then
        button:Enable()
        if button.SetAlpha then
            button:SetAlpha(1.0)
        end
    else
        button:Disable()
        if button.SetAlpha then
            button:SetAlpha(0.45)
        end
    end
end

local function UpdateWinnerDisplay()
    if not mainFrame then
        return
    end

    local canControl = CanControlRolls and CanControlRolls() or false

    if selectedRoll and canControl then
        local status = ""
        if selectedRoll.isReroll then
            status = "  |cffff6666[REROLL]|r"
        elseif selectedRoll.isTied then
            status = "  |cffffa62b[TIE]|r"
        elseif selectedRoll.tiePath and #selectedRoll.tiePath > 0 then
            status = "  |cff73e68a[TB " .. tostring(selectedRoll.tiePath[#selectedRoll.tiePath]) .. "]|r"
        end
        mainFrame.winnerText:SetText(
            "Selected: " .. GetClassColorCode(selectedRoll.name) .. selectedRoll.name .. "|r  -  |cffffd24a" .. selectedRoll.roll .. "|r  (" .. selectedRoll.type .. ")" .. status
        )
        SetButtonEnabled(mainFrame.tradeButton, true)
    elseif canControl then
        mainFrame.winnerText:SetText("Selected: |cff888888click a roll to choose a winner|r")
        SetButtonEnabled(mainFrame.tradeButton, false)
    else
        mainFrame.winnerText:SetText("|cffaaaaaaViewer mode - the Master Looter selects and trades winners|r")
        SetButtonEnabled(mainFrame.tradeButton, false)
    end
end

UpdateUI = function()
    if not mainFrame then
        return
    end

    RefreshDuplicateFlags()
    UpdatePanel(msPanel, rollsMS)
    UpdatePanel(osPanel, rollsOS)

    mainFrame.msCount:SetText("MS  (1-100)   |cffaaaaaa" .. GetValidCount(rollsMS) .. " valid|r")
    mainFrame.osCount:SetText("OS  (1-99)   |cffaaaaaa" .. GetValidCount(rollsOS) .. " valid|r")
    UpdateWinnerDisplay()
    if UpdateControlState then
        UpdateControlState()
    end
end

local function AddTieBreakRoll(name, roll, minimum, maximum, bypassRaidCheck)
    if not tieBreakActive or minimum ~= 1 then
        return false
    end

    local expectedMaximum = tieBreakType == "OS" and 99 or 100
    if maximum ~= expectedMaximum then
        return false
    end

    local playerKey = NormalizeName(name)
    if not playerKey or not tieBreakPlayers[playerKey] then
        return false
    end

    if tieBreakRoundRolls[playerKey] ~= nil then
        return false
    end

    if not bypassRaidCheck then
        if IsInRaid() then
            if not IsRaidMember(name) then
                return false
            end
        elseif not IsLocalGroupMember(name) then
            return false
        end
    end

    local entry = FindValidEntry(playerKey, tieBreakType)
    if not entry then
        return false
    end

    entry.tiePath = entry.tiePath or {}
    entry.tiePath[#entry.tiePath + 1] = roll
    tieBreakRoundRolls[playerKey] = roll
    UpdateUI()

    if not bypassRaidCheck and IsInRaid() and syncSessionID and CanControlRolls and CanControlRolls() then
        local message = table.concat({
            "TIEROLL",
            tostring(syncSessionID),
            tostring(tieBreakRound),
            tostring(name or ""),
            tostring(roll or 0),
            tostring(maximum or expectedMaximum),
        }, "\t")
        SendSyncRaw(message, "RAID")
    end

    return true
end

local function AddRoll(name, roll, minimum, maximum, bypassRaidCheck, validOverride, softReserveIndexOverride)
    if minimum ~= 1 then
        return false
    end

    if tieBreakActive then
        return AddTieBreakRoll(name, roll, minimum, maximum, bypassRaidCheck)
    end

    if not bypassRaidCheck and rollSessionStarted and not rollSessionOpen then
        return false
    end

    if not bypassRaidCheck then
        if IsInRaid() then
            if not IsRaidMember(name) then
                return false
            end
        elseif not IsLocalGroupMember(name) then
            return false
        end
    end

    local rollType
    local targetList

    if maximum == 100 then
        rollType = "MS"
        targetList = rollsMS
    elseif maximum == 99 then
        rollType = "OS"
        targetList = rollsOS
    else
        return false
    end

    local playerKey = NormalizeName(name)
    if not playerKey then
        return false
    end

    local allRolls = GetAllRolls()
    local hasValidRoll = false
    local validMSRolls = 0
    local i
    for i = 1, #allRolls do
        local previous = allRolls[i]
        if previous.playerKey == playerKey and previous.isFirst then
            hasValidRoll = true
            if previous.type == "MS" then validMSRolls = validMSRolls + 1 end
        end
    end

    local reserveCount = rollType == "MS" and AscensionRaidRollsSoftRes.GetPlayerReserveCount(name, currentItemID) or 0
    local isValid
    if rollType == "MS" and reserveCount > 0 then
        isValid = validMSRolls < reserveCount
    else
        isValid = not hasValidRoll
    end
    local softReserveIndex = isValid and reserveCount > 0 and (validMSRolls + 1) or nil
    if validOverride ~= nil then isValid = validOverride == true end
    if tonumber(softReserveIndexOverride) and tonumber(softReserveIndexOverride) > 0 then
        softReserveIndex = math.floor(tonumber(softReserveIndexOverride))
    elseif validOverride == false then
        softReserveIndex = nil
    end

    sequence = sequence + 1

    if isValid and not firstRollByPlayer[playerKey] then firstRollByPlayer[playerKey] = sequence end

    local entry = {
        name = name,
        playerKey = playerKey,
        roll = roll,
        minimum = minimum,
        maximum = maximum,
        type = rollType,
        sequence = sequence,
        isFirst = isValid,
        isSoftReserved = softReserveIndex ~= nil,
        softReserveIndex = softReserveIndex,
    }
    targetList[#targetList + 1] = entry

    if #targetList > MAX_HISTORY then
        table.remove(targetList, 1)
    end

    UpdateUI()

    -- Only the authoritative Master Looter republishes rolls. Remote viewers
    -- receive these messages instead of trusting their own CHAT_MSG_SYSTEM
    -- timing, so the host decides exactly which rolls arrived before 0.
    if not bypassRaidCheck and rollSessionStarted and rollSessionOpen and BroadcastRollSync and CanControlRolls and CanControlRolls() then
        BroadcastRollSync(entry)
    end

    return true
end

local function ClearRolls()
    rollsMS = {}
    rollsOS = {}
    firstRollByPlayer = {}
    selectedRoll = nil
    sequence = 0
    tieBreakActive = false
    tieBreakType = nil
    tieBreakPlayers = {}
    tieBreakRoundRolls = {}
    tieBreakRound = 0
    UpdateUI()
end

BroadcastRollSync = function(entry, channel, target)
    if not entry or not syncSessionID then
        return false
    end

    local message = table.concat({
        "ROLL",
        tostring(syncSessionID),
        tostring(entry.name or ""),
        tostring(entry.roll or 0),
        tostring(entry.minimum or 1),
        tostring(entry.maximum or 0),
        entry.isFirst and "1" or "0",
        tostring(entry.softReserveIndex or 0),
    }, "\t")

    return SendSyncRaw(message, channel or "RAID", target)
end

SendFullSyncState = function(target)
    if not CanControlRolls or not CanControlRolls() or not target then
        return false
    end

    if not rollSessionStarted or not syncSessionID then
        SendSyncRaw("IDLE\t" .. tostring(SYNC_PROTOCOL), "WHISPER", target)
        BroadcastLootHistory("WHISPER", target)
        return true
    end

    local now = GetTime and GetTime() or 0
    local remaining = 0
    if rollSessionOpen and rollTimerActive then
        remaining = math.max(0, rollEndTime - now)
    end

    local stateMessage = table.concat({
        "STATE",
        tostring(syncSessionID),
        rollSessionOpen and "1" or "0",
        string.format("%.2f", remaining),
        tostring(activeDuration or DEFAULT_ROLL_DURATION),
        tostring(currentItemID or 0),
        tostring(currentItemLink or ""),
    }, "\t")

    SendSyncRaw(stateMessage, "WHISPER", target)
    SendSyncRaw("TOP\t" .. tostring(syncSessionID) .. "\t" .. tostring(currentTopRolls or 1), "WHISPER", target)
    AscensionRaidRollsSoftRes.BroadcastCurrentState("WHISPER", target)
    BroadcastLootHistory("WHISPER", target)

    local all = GetAllRolls()
    table.sort(all, function(a, b)
        return (a.sequence or 0) < (b.sequence or 0)
    end)

    local i
    for i = 1, #all do
        BroadcastRollSync(all[i], "WHISPER", target)
    end

    -- Rebuild completed tie-break history for players that reload mid-session.
    -- While a tie-break is still active, omit the current round's last value
    -- here; it is replayed as TIEROLL after TIESTATE so the viewer also knows
    -- that player has already used their one allowed reroll for this round.
    for i = 1, #all do
        local entry = all[i]
        if entry.isFirst and entry.tiePath and #entry.tiePath > 0 then
            local pathParts = {}
            local pathLimit = #entry.tiePath
            if tieBreakActive and tieBreakPlayers[entry.playerKey] and tieBreakRoundRolls[entry.playerKey] ~= nil then
                pathLimit = math.max(0, pathLimit - 1)
            end
            local pathIndex
            for pathIndex = 1, pathLimit do
                pathParts[#pathParts + 1] = tostring(entry.tiePath[pathIndex])
            end
            if #pathParts > 0 then
                SendSyncRaw(table.concat({
                    "TBPATH",
                    tostring(syncSessionID),
                    tostring(entry.name or ""),
                    tostring(entry.type or "MS"),
                    table.concat(pathParts, ","),
                }, "\t"), "WHISPER", target)
            end
        end
    end

    if tieBreakActive then
        local names = {}
        for playerKey in pairs(tieBreakPlayers) do
            local entry = FindValidEntry(playerKey, tieBreakType)
            if entry then
                names[#names + 1] = entry.name
            end
        end
        table.sort(names)

        SendSyncRaw(table.concat({
            "TIESTATE",
            tostring(syncSessionID),
            tostring(tieBreakRound),
            tostring(tieBreakType or "MS"),
            string.format("%.2f", remaining),
            tostring(activeDuration or DEFAULT_ROLL_DURATION),
            table.concat(names, ","),
        }, "\t"), "WHISPER", target)

        for playerKey, tieRoll in pairs(tieBreakRoundRolls) do
            local entry = FindValidEntry(playerKey, tieBreakType)
            if entry then
                SendSyncRaw(table.concat({
                    "TIEROLL",
                    tostring(syncSessionID),
                    tostring(tieBreakRound),
                    tostring(entry.name or ""),
                    tostring(tieRoll or 0),
                    tostring(tieBreakType == "OS" and 99 or 100),
                }, "\t"), "WHISPER", target)
            end
        end
    end

    SendSyncRaw("STATEDONE\t" .. tostring(syncSessionID), "WHISPER", target)
    return true
end

local function GetPlayerRaidRank()
    local playerKey = NormalizeName(UnitName("player"))
    if not playerKey then
        return 0
    end

    if not raidMembers[playerKey] then
        RefreshRaidMembers()
    end

    local member = raidMembers[playerKey]
    return member and member.rank or 0
end

local function SendRaidAnnouncement(message, allowRaidFallback)
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0

    -- Standalone Mode: outside a raid there is no /rw channel to use. In a
    -- normal party, mirror the announcement to /party; when solo, print it
    -- locally so Start Roll / winner / timer flows can still be fully tested.
    if raidCount <= 0 then
        local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
        if partyCount > 0 and SendChatMessage then
            SendChatMessage(message, "PARTY")
        else
            Print("[Standalone] " .. tostring(message))
        end
        return true
    end

    if not SendChatMessage then
        Print("SendChatMessage is unavailable on this client.")
        return false
    end

    if GetPlayerRaidRank() >= 1 then
        SendChatMessage(message, "RAID_WARNING")
        return true
    end

    if allowRaidFallback then
        SendChatMessage(message, "RAID")
        Print("you are not raid leader/assistant, so the message was sent in /raid instead of /rw.")
        return true
    end

    Print("you must be raid leader or assistant to send this message in /rw.")
    return false
end

local function CheckMissingReservations()
    if not IsInRaid() then
        Print("join a raid before checking the SoftRes roster.")
        return false
    end
    if not CanControlRolls or not CanControlRolls() then
        Print("only the Master Looter can check missing reservations in a raid.")
        return false
    end
    local data = AscensionRaidRollsSoftRes.GetData()
    if not data or type(data.roster) ~= "table" then
        Print("import a SoftRes list first.")
        return false
    end

    local limit = math.max(1, math.floor(tonumber(AscensionRaidRollsDB.softResLimit) or 2))
    local missing = {}
    local incomplete = {}
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    local i
    for i = 1, raidCount do
        local raidName = GetRaidRosterInfo(i)
        local playerKey = NormalizeName(raidName)
        if playerKey then
            local entry = data.roster[playerKey]
            if not entry then
                missing[#missing + 1] = tostring(raidName)
            else
                local count = math.max(0, math.floor(tonumber(entry.itemCount) or 0))
                if count < limit then
                    incomplete[#incomplete + 1] = tostring(raidName) .. " (" .. tostring(count) .. "/" .. tostring(limit) .. ")"
                end
            end
        end
    end
    table.sort(missing)
    table.sort(incomplete)

    local function AnnounceList(prefix, list)
        local line = prefix
        local index
        for index = 1, #list do
            local addition = (line == prefix and "" or ", ") .. list[index]
            if #line + #addition > 220 then
                SendRaidAnnouncement(line, true)
                line = prefix .. list[index]
            else
                line = line .. addition
            end
        end
        if line ~= prefix then SendRaidAnnouncement(line, true) end
    end

    if #missing > 0 then
        AnnounceList("Missing from SoftRes export: ", missing)
    end
    if #incomplete > 0 then
        AnnounceList("Incomplete SoftRes (max " .. tostring(limit) .. "): ", incomplete)
    end
    if #missing > 0 or #incomplete > 0 then
        local reservationURL = Trim(AscensionRaidRollsDB.softResURL or "") or ""
        local invitation = "Please complete your SoftRes reservations"
        if reservationURL ~= "" then
            invitation = invitation .. ": " .. reservationURL
        else
            invitation = invitation .. " on the BisBeard reservation page."
        end
        SendRaidAnnouncement(invitation, false)
    end
    if #missing == 0 and #incomplete == 0 then
        SendRaidAnnouncement("SoftRes check: every raid member is in the export and has used " .. tostring(limit) .. "/" .. tostring(limit) .. " reservations.", true)
    end
    Print("SoftRes roster check: " .. tostring(#missing) .. " missing from export, " .. tostring(#incomplete) .. " below the " .. tostring(limit) .. " SR limit.")
    return true
end

local function ShowLocalTimerAlert(text)
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
        RaidNotice_AddMessage(RaidWarningFrame, tostring(text), ChatTypeInfo["RAID_WARNING"])
    elseif UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(tostring(text), 1.0, 0.2, 0.2, 1.0)
    end

    if PlaySound then
        pcall(PlaySound, "RaidWarning")
    end
end

local function GetConfiguredDuration()
    local duration

    if mainFrame and mainFrame.durationEdit then
        duration = tonumber(mainFrame.durationEdit:GetText())
    end

    if not duration and AscensionRaidRollsDB then
        duration = tonumber(AscensionRaidRollsDB.rollDuration)
    end

    duration = math.floor((duration or DEFAULT_ROLL_DURATION) + 0.5)

    if duration < MIN_ROLL_DURATION then
        duration = MIN_ROLL_DURATION
    elseif duration > MAX_ROLL_DURATION then
        duration = MAX_ROLL_DURATION
    end

    if AscensionRaidRollsDB then
        AscensionRaidRollsDB.rollDuration = duration
    end

    if mainFrame and mainFrame.durationEdit then
        mainFrame.durationEdit:SetText(tostring(duration))
    end

    return duration
end

-- Count how many matching copies of the selected item can actually be traded.
-- A copy is eligible for Top X Rolls when either:
--   1) its tooltip contains Ascension's temporary raid-loot trade text, or
--   2) it is still an unbound BoE item ("Binds when equipped").
-- Soulbound copies without the temporary trade permission are excluded.
local tradeScanTooltip

local function GetBagItemCount(bag, slot)
    if not GetContainerItemInfo then
        return 1
    end

    local _, count = GetContainerItemInfo(bag, slot)
    count = tonumber(count) or 1
    if count < 1 then
        count = 1
    end
    return count
end

local function ReadTradeScanTooltipText()
    if not tradeScanTooltip then
        return nil
    end

    -- Concatenate both tooltip columns. Ascension can wrap binding/trade text
    -- across multiple lines, so normalize the complete tooltip before matching.
    local parts = {}
    local numLines = tradeScanTooltip:NumLines() or 0
    local i
    for i = 1, numLines do
        local left = _G["AscensionRaidRollsTradeScanTooltipTextLeft" .. i]
        local right = _G["AscensionRaidRollsTradeScanTooltipTextRight" .. i]
        local leftText = left and left:GetText() or nil
        local rightText = right and right:GetText() or nil
        if leftText and leftText ~= "" then
            parts[#parts + 1] = string.lower(leftText)
        end
        if rightText and rightText ~= "" then
            parts[#parts + 1] = string.lower(rightText)
        end
    end

    local tooltipText = table.concat(parts, " ")
    tooltipText = string.gsub(tooltipText, "%s+", " ")
    return tooltipText
end

local function EnsureTradeScanTooltip()
    if not CreateFrame or not UIParent then
        return false
    end

    if not tradeScanTooltip then
        tradeScanTooltip = CreateFrame("GameTooltip", "AscensionRaidRollsTradeScanTooltip", UIParent, "GameTooltipTemplate")
    end

    tradeScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    return true
end

local function GetBagItemTooltipText(bag, slot)
    if not EnsureTradeScanTooltip() then
        return nil
    end

    tradeScanTooltip:ClearLines()
    local ok = pcall(function()
        tradeScanTooltip:SetBagItem(bag, slot)
    end)
    if not ok then
        tradeScanTooltip:Hide()
        return nil
    end

    local tooltipText = ReadTradeScanTooltipText()
    tradeScanTooltip:Hide()
    return tooltipText
end

local function GetItemLinkTooltipText(itemLink)
    if not itemLink or not EnsureTradeScanTooltip() then
        return nil
    end

    tradeScanTooltip:ClearLines()
    local ok = pcall(function()
        tradeScanTooltip:SetHyperlink(itemLink)
    end)
    if not ok then
        tradeScanTooltip:Hide()
        return nil
    end

    local tooltipText = ReadTradeScanTooltipText()
    tradeScanTooltip:Hide()
    return tooltipText
end

local function TooltipContains(text, needle)
    return text and needle and needle ~= "" and string.find(text, needle, 1, true) ~= nil
end

local function GetBindingScanStrings()
    local temporaryTradePrefix = "you may trade this item with players also eligible to loot this item for the next"
    local boeText = string.lower(tostring(_G.ITEM_BIND_ON_EQUIP or "Binds when equipped"))
    local soulboundText = string.lower(tostring(_G.ITEM_SOULBOUND or "Soulbound"))
    return temporaryTradePrefix, boeText, soulboundText
end

local function IsItemLinkBoE(itemLink)
    local tooltipText = GetItemLinkTooltipText(itemLink)
    local _, boeText = GetBindingScanStrings()
    return TooltipContains(tooltipText, boeText)
end

local function IsBagItemTradeableForRoll(bag, slot, baseItemIsBoE)
    local tooltipText = GetBagItemTooltipText(bag, slot)
    local temporaryTradePrefix, boeText, soulboundText = GetBindingScanStrings()

    -- Temporary raid-loot permission always makes this specific copy eligible.
    if TooltipContains(tooltipText, temporaryTradePrefix) then
        return true, "temporary-trade"
    end

    -- A copy explicitly marked Soulbound must never increase Top X unless the
    -- temporary-trade permission above was present.
    if TooltipContains(tooltipText, soulboundText) then
        return false, "soulbound"
    end

    -- Prefer the per-slot tooltip when it exposes the BoE line.
    if TooltipContains(tooltipText, boeText) then
        return true, "boe-slot"
    end

    -- Ascension occasionally returns an incomplete hidden bag tooltip for one
    -- of two identical items. The binding rule is an item property, so if the
    -- selected item itself is confirmed BoE and this matching copy is not
    -- explicitly Soulbound, treat it as an unbound BoE copy.
    if baseItemIsBoE then
        return true, "boe-item-fallback"
    end

    return false, tooltipText and "not-tradeable" or "tooltip-unavailable"
end

local function CountTradeableCopies(itemLink, itemID, debugOutput)
    if not GetContainerNumSlots or not GetContainerItemLink then
        return 1
    end

    local wantedID = tonumber(itemID)
    if not wantedID and type(itemLink) == "string" then
        wantedID = tonumber(itemLink:match("item:(%d+)"))
    end

    -- Determine the static binding rule once from the selected item's hyperlink.
    -- This is more reliable than requiring every hidden bag tooltip to repeat
    -- "Binds when equipped" correctly.
    local baseItemIsBoE = IsItemLinkBoE(itemLink)

    local total = 0
    local bag
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot
        for slot = 1, slots do
            local bagLink = GetContainerItemLink(bag, slot)
            if bagLink then
                local bagID = tonumber(bagLink:match("item:(%d+)"))
                local matches = false

                if wantedID and bagID then
                    matches = wantedID == bagID
                elseif itemLink then
                    matches = bagLink == itemLink
                end

                if matches then
                    local eligible, reason = IsBagItemTradeableForRoll(bag, slot, baseItemIsBoE)
                    local count = GetBagItemCount(bag, slot)
                    if eligible then
                        total = total + count
                    end
                    if debugOutput then
                        Print("Top X scan: bag " .. tostring(bag) .. ", slot " .. tostring(slot) .. ", x" .. tostring(count) .. " -> " .. tostring(reason) .. (eligible and " [COUNTED]" or " [IGNORED]"))
                    end
                end
            end
        end
    end

    if debugOutput then
        Print("Top X scan: selected item BoE = " .. tostring(baseItemIsBoE) .. ", total = " .. tostring(total))
    end

    -- Keep the normal single-item wording when fewer than two tradeable copies
    -- can be verified. Temporary-trade loot and unbound BoE copies both count.
    if total < 1 then
        total = 1
    end
    return total
end

local function GetTopRollsLabel()
    local count = math.max(1, tonumber(currentTopRolls) or 1)
    if count == 1 then
        return "Top 1 roll"
    end
    return "Top " .. tostring(count) .. " rolls"
end

local function UpdateItemDisplay()
    if not mainFrame then
        return
    end

    local canControl = CanControlRolls and CanControlRolls() or false

    if currentItemLink then
        local itemName, resolvedLink, _, _, _, _, _, _, _, texture = GetItemInfo(currentItemLink)
        if resolvedLink then
            currentItemLink = resolvedLink
        end

        mainFrame.itemText:SetText(currentItemLink or itemName or "Selected item")
        mainFrame.itemIcon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
        if canControl then
            mainFrame.itemHint:SetText(GetTopRollsLabel() .. "  •  Shift+RClick to change")
        else
            mainFrame.itemHint:SetText(GetTopRollsLabel() .. "  •  Master Looter item")
        end
        SetButtonEnabled(mainFrame.startRollButton, canControl)
    else
        mainFrame.itemText:SetText("|cffaaaaaaNo active roll item|r")
        mainFrame.itemIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        if canControl then
            mainFrame.itemHint:SetText("Drag here or Shift + Right-click an item in your bags")
        else
            mainFrame.itemHint:SetText("Waiting for the Master Looter to start a roll")
        end
        SetButtonEnabled(mainFrame.startRollButton, false)
    end
end

local function SetCurrentItem(itemLink, itemID)
    local link = itemLink

    if (not link or link == "") and itemID and GetItemInfo then
        local _, resolvedLink = GetItemInfo(itemID)
        link = resolvedLink
    end

    if not link or link == "" then
        Print("could not read that item from the cursor.")
        return false
    end

    currentItemLink = link
    currentItemID = itemID
    if not CanControlRolls or CanControlRolls() then
        currentTopRolls = CountTradeableCopies(currentItemLink, currentItemID)
    elseif not currentTopRolls or currentTopRolls < 1 then
        currentTopRolls = 1
    end
    UpdateItemDisplay()
    return true
end

AscensionRaidRolls.SetRollItem = function(itemLink, itemID)
    if CanControlRolls and not CanControlRolls() then
        Print("only the current Master Looter can choose the roll item.")
        return false
    end
    if SetCurrentItem(itemLink, itemID) then
        if mainFrame then mainFrame:Show() end
        Print("selected " .. tostring(itemLink or itemID) .. " for the next roll.")
        return true
    end
    return false
end

local function ClearCurrentItem()
    currentItemLink = nil
    currentItemID = nil
    currentTopRolls = 1
    UpdateItemDisplay()
end

local function CaptureCursorItem()
    if CanControlRolls and not CanControlRolls() then
        Print("only the current Master Looter can choose the roll item.")
        return false
    end

    if not GetCursorInfo then
        Print("GetCursorInfo is unavailable on this client.")
        return false
    end

    local cursorType, data1, data2 = GetCursorInfo()
    if cursorType ~= "item" then
        return false
    end

    local itemLink = nil
    if type(data2) == "string" and data2 ~= "" then
        itemLink = data2
    elseif data1 and GetItemInfo then
        local _, resolvedLink = GetItemInfo(data1)
        itemLink = resolvedLink
    end

    if SetCurrentItem(itemLink, data1) then
        if ClearCursor then
            ClearCursor()
        end
        return true
    end

    return false
end

-- Shift + Right-click shortcut for bag items.
-- IMPORTANT: never replace Blizzard/Ascension ContainerFrame global handlers here.
-- Replacing secure/shared click handlers can taint the UI and later cause unrelated
-- "blocked from calling a protected function" errors in other addons.
-- We therefore use hooksecurefunc only. This observes the click after the stock
-- handler without modifying the secure execution path.
local bagItemShortcutInstalled = false
local lastBagShortcutKey = nil
local lastBagShortcutTime = 0

local function GetBagItemFromButton(buttonFrame)
    if not buttonFrame or not buttonFrame.GetID then
        return nil, nil, nil, nil
    end

    local parent = buttonFrame.GetParent and buttonFrame:GetParent() or nil
    local bag = parent and parent.GetID and parent:GetID() or nil
    local slot = buttonFrame:GetID()
    if bag == nil or slot == nil then
        return nil, nil, nil, nil
    end

    local itemLink = nil
    if GetContainerItemLink then
        itemLink = GetContainerItemLink(bag, slot)
    end

    -- Some 3.3.5-derived clients also return the item link as the seventh
    -- value of GetContainerItemInfo. Use it only as a compatibility fallback.
    if (not itemLink or itemLink == "") and GetContainerItemInfo then
        local _, _, _, _, _, _, infoLink = GetContainerItemInfo(bag, slot)
        itemLink = infoLink
    end

    local itemID = nil
    if type(itemLink) == "string" then
        itemID = tonumber(itemLink:match("item:(%d+)"))
    end

    return itemLink, itemID, bag, slot
end

local function HandleBagItemShortcut(buttonFrame, mouseButton)
    if mouseButton ~= "RightButton" then
        return false
    end

    if not IsShiftKeyDown or not IsShiftKeyDown() then
        return false
    end

    -- Viewer clients cannot choose the item for a hosted roll session.
    if CanControlRolls and not CanControlRolls() then
        return false
    end

    local itemLink, itemID, bag, slot = GetBagItemFromButton(buttonFrame)
    if not itemLink or itemLink == "" then
        return false
    end

    -- Ascension/custom bag XML can route a modified click through more than one
    -- handler. Avoid selecting/printing the same item twice for a single click.
    local now = (GetTime and GetTime()) or 0
    local shortcutKey = tostring(bag) .. ":" .. tostring(slot)
    if lastBagShortcutKey == shortcutKey and (now - lastBagShortcutTime) < 0.10 then
        return true
    end
    lastBagShortcutKey = shortcutKey
    lastBagShortcutTime = now

    if SetCurrentItem(itemLink, itemID) then
        Print("roll item selected: " .. tostring(itemLink))
        return true
    end

    return false
end

local function InstallBagItemShortcut()
    if bagItemShortcutInstalled then
        return true
    end

    -- hooksecurefunc is intentionally mandatory here. Falling back to replacing
    -- ContainerFrameItemButton_OnClick would reintroduce UI taint.
    if type(hooksecurefunc) ~= "function" then
        Print("Shift + Right-click bag shortcut disabled: secure hook API unavailable.")
        return false
    end

    local installedAny = false

    if type(ContainerFrameItemButton_OnModifiedClick) == "function" then
        hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self, button, ...)
            HandleBagItemShortcut(self, button)
        end)
        installedAny = true
    end

    -- Ascension/custom-UI compatibility fallback. This is still a secure post-hook;
    -- the original global function is never replaced.
    if type(ContainerFrameItemButton_OnClick) == "function" then
        hooksecurefunc("ContainerFrameItemButton_OnClick", function(self, button, ...)
            HandleBagItemShortcut(self, button)
        end)
        installedAny = true
    end

    if not installedAny then
        Print("Shift + Right-click bag shortcut is unavailable on this client.")
        return false
    end

    bagItemShortcutInstalled = true
    return true
end

local function SetTimerVisual(remainingFloat)
    if not mainFrame or not mainFrame.timerBar then
        return
    end

    local remaining = math.max(0, remainingFloat or 0)
    mainFrame.timerBar:SetMinMaxValues(0, math.max(1, activeDuration))
    mainFrame.timerBar:SetValue(remaining)

    if remaining <= 5 then
        mainFrame.timerBar:SetStatusBarColor(0.85, 0.12, 0.12)
    elseif remaining <= 10 then
        mainFrame.timerBar:SetStatusBarColor(0.95, 0.65, 0.10)
    else
        mainFrame.timerBar:SetStatusBarColor(0.20, 0.75, 0.25)
    end
end

BroadcastSessionEnd = function()
    if not syncSessionID then
        return false
    end
    return SendSyncRaw("END\t" .. tostring(syncSessionID), "RAID")
end

local function BroadcastSessionReset()
    if not syncSessionID then
        return false
    end
    return SendSyncRaw("RESET\t" .. tostring(syncSessionID), "RAID")
end

local function CancelRollSession()
    rollTimerActive = false
    rollSessionStarted = false
    rollSessionOpen = true
    rollStartTime = 0
    rollEndTime = 0
    timerAlerted = {}
    timerAccumulator = 0
    tieBreakActive = false
    tieBreakType = nil
    tieBreakPlayers = {}
    tieBreakRoundRolls = {}
    tieBreakRound = 0

    if mainFrame then
        mainFrame.timerText:SetText("Timer ready")
        mainFrame.timerBar:SetMinMaxValues(0, 1)
        mainFrame.timerBar:SetValue(0)
        mainFrame.timerBar:SetStatusBarColor(0.20, 0.75, 0.25)
        mainFrame.startRollButton:SetText("Start Roll")
    end
end

local function GetTieBreakPlayerNames()
    local names = {}
    local playerKey
    for playerKey in pairs(tieBreakPlayers) do
        local entry = FindValidEntry(playerKey, tieBreakType)
        if entry then
            names[#names + 1] = entry.name
        end
    end
    table.sort(names)
    return names
end

local function ApplyTieBreakStart(sessionID, round, rollType, remaining, duration, playerList)
    if syncSessionID and tostring(sessionID) ~= tostring(syncSessionID) then
        return false
    end

    tieBreakActive = true
    tieBreakType = rollType == "OS" and "OS" or "MS"
    tieBreakRound = tonumber(round) or (tieBreakRound + 1)
    tieBreakPlayers = {}
    tieBreakRoundRolls = {}

    local name
    for name in string.gmatch(tostring(playerList or ""), "[^,]+") do
        local key = NormalizeName(name)
        if key then
            tieBreakPlayers[key] = true
        end
    end

    activeDuration = tonumber(duration) or DEFAULT_ROLL_DURATION
    local remainingValue = tonumber(remaining) or activeDuration
    local now = GetTime and GetTime() or 0

    rollSessionStarted = true
    rollSessionOpen = remainingValue > 0
    rollTimerActive = remainingValue > 0
    rollStartTime = now
    rollEndTime = now + math.max(0, remainingValue)
    timerAlerted = {}
    timerAccumulator = 0

    if mainFrame then
        if rollTimerActive then
            mainFrame.timerText:SetText("Tie-break closes in: " .. math.ceil(remainingValue) .. "s")
        else
            mainFrame.timerText:SetText("TIE-BREAK CLOSED")
        end
        mainFrame:Show()
    end
    SetTimerVisual(remainingValue)
    UpdateUI()
    return true
end

local function StartTieBreak()
    if not CanControlRolls or not CanControlRolls() then
        Print("only the current Master Looter can start a tie-break.")
        return false
    end

    if rollTimerActive then
        Print("wait for the current timer to finish before starting a tie-break.")
        return false
    end

    RefreshDuplicateFlags()
    if not selectedRoll or not selectedRoll.isFirst or not selectedRoll.isTied then
        Print("select a valid roll marked TIE first.")
        return false
    end

    local group = GetTieGroupForEntry(selectedRoll)
    if #group < 2 then
        Print("that roll is no longer tied.")
        UpdateUI()
        return false
    end

    tieBreakActive = true
    tieBreakType = selectedRoll.type
    tieBreakRound = tieBreakRound + 1
    tieBreakPlayers = {}
    tieBreakRoundRolls = {}

    local names = {}
    local i
    for i = 1, #group do
        tieBreakPlayers[group[i].playerKey] = true
        names[#names + 1] = group[i].name
    end

    activeDuration = GetConfiguredDuration()
    rollSessionStarted = true
    rollSessionOpen = true
    rollTimerActive = true
    timerAlerted = {}
    timerAccumulator = 0
    rollStartTime = GetTime and GetTime() or 0
    rollEndTime = rollStartTime + activeDuration

    local maximum = tieBreakType == "OS" and 99 or 100
    local message = "TIE - " .. table.concat(names, " / ") .. " - " .. tieBreakType .. ": /roll " .. tostring(maximum) .. " - " .. tostring(activeDuration) .. " sec"
    SendRaidAnnouncement(message, true)
    ShowLocalTimerAlert("TIE-BREAK - " .. tostring(activeDuration) .. "s")

    if mainFrame then
        mainFrame.timerText:SetText("Tie-break closes in: " .. activeDuration .. "s")
        mainFrame:Show()
    end
    SetTimerVisual(activeDuration)

    if IsInRaid() and syncSessionID then
        SendSyncRaw(table.concat({
            "TIESTART",
            tostring(syncSessionID),
            tostring(tieBreakRound),
            tostring(tieBreakType),
            tostring(activeDuration),
            table.concat(names, ","),
        }, "\t"), "RAID")
    end

    UpdateUI()
    return true
end

FinishTieBreak = function()
    if not tieBreakActive then
        return false
    end

    local isController = CanControlRolls and CanControlRolls() or false
    local finishedRound = tieBreakRound

    rollTimerActive = false
    rollSessionOpen = false
    rollStartTime = 0
    rollEndTime = 0
    tieBreakActive = false
    SetTimerVisual(0)

    if mainFrame then
        mainFrame.timerText:SetText("TIE-BREAK CLOSED")
    end

    ShowLocalTimerAlert("TIE-BREAK CLOSED")

    if isController then
        SendRaidAnnouncement("Tie-break closed", true)
        if IsInRaid() and syncSessionID then
            SendSyncRaw("TIEEND\t" .. tostring(syncSessionID) .. "\t" .. tostring(finishedRound), "RAID")
        end
    end

    tieBreakPlayers = {}
    tieBreakRoundRolls = {}
    UpdateUI()
    return true
end

local function FinishTimedRoll()
    if not rollTimerActive then
        return
    end

    if tieBreakActive then
        FinishTieBreak()
        return
    end

    local isController = CanControlRolls and CanControlRolls() or false

    rollTimerActive = false
    rollSessionOpen = false
    SetTimerVisual(0)

    if mainFrame then
        mainFrame.timerText:SetText("ROLL CLOSED")
        mainFrame.startRollButton:SetText("Start Roll")
    end

    ShowLocalTimerAlert("ROLL CLOSED")

    -- Only the Master Looter is allowed to publish raid announcements.
    -- Viewer clients still run the local visual countdown, but never speak.
    if isController then
        if currentItemLink then
            SendRaidAnnouncement("Rolls closed - " .. currentItemLink, true)
        else
            SendRaidAnnouncement("Rolls closed", true)
        end
        if BroadcastSessionEnd then
            BroadcastSessionEnd()
        end
    end

    if UpdateControlState then
        UpdateControlState()
    end
end

local function HandleTimerAlert(seconds)
    if timerAlerted[seconds] then
        return
    end

    timerAlerted[seconds] = true

    if seconds <= 5 then
        ShowLocalTimerAlert(tostring(seconds))
    elseif seconds == 10 then
        ShowLocalTimerAlert("10 seconds remaining")
    end

    -- The authoritative host publishes a clean raid-warning countdown for
    -- every one of the final five seconds. Do not repeat the item link here;
    -- everyone already knows which item the active session is for.
    if seconds <= 5 and CanControlRolls and CanControlRolls() then
        SendRaidAnnouncement(tostring(seconds), true)
    end
end

local function UpdateRollTimer()
    if not rollTimerActive then
        return
    end

    local now = GetTime and GetTime() or 0
    local remainingFloat = rollEndTime - now

    if remainingFloat <= 0 then
        FinishTimedRoll()
        return
    end

    local remaining = math.ceil(remainingFloat)

    if mainFrame then
        mainFrame.timerText:SetText((tieBreakActive and "Tie-break closes in: " or "Roll closes in: ") .. remaining .. "s")
    end
    SetTimerVisual(remainingFloat)

    local thresholds = { 10, 5, 4, 3, 2, 1 }
    local i
    for i = 1, #thresholds do
        local threshold = thresholds[i]
        if threshold <= activeDuration and remaining <= threshold then
            HandleTimerAlert(threshold)
        end
    end
end

local function StartTimedRoll()
    if not CanControlRolls or not CanControlRolls() then
        local actualMaster = GetActualMasterLooterName and GetActualMasterLooterName() or nil
        if actualMaster then
            Print("only the current Master Looter (" .. tostring(actualMaster) .. ") can start a roll.")
        else
            Print("only the current Master Looter can start a roll.")
        end
        return
    end

    if not currentItemLink then
        Print("drop an item into the item slot first.")
        return
    end

    local hardReserve = AscensionRaidRollsSoftRes.GetCurrentHardReserve()
    if hardReserve then
        local ownerText = type(hardReserve) == "string" and hardReserve ~= "" and (" for " .. hardReserve) or ""
        Print("this item is Hard Reserved" .. ownerText .. "; no roll was started.")
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage("HARD RESERVED" .. ownerText, 1.0, 0.25, 0.25, 1.0)
        end
        return
    end

    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    local inRaid = raidCount > 0

    activeDuration = GetConfiguredDuration()
    currentTopRolls = CountTradeableCopies(currentItemLink, currentItemID)
    UpdateItemDisplay()

    local startMessage
    local priorityLabel = AscensionRaidRollsSoftRes.IsPriorityEnabled() and "SR > MS > OS - " or ""
    if (tonumber(currentTopRolls) or 1) > 1 then
        startMessage = "Top " .. tostring(currentTopRolls) .. " Rolls " .. currentItemLink .. " - " .. priorityLabel .. "MS: /roll 100 - OS: /roll 99 - " .. activeDuration .. " sec"
    else
        startMessage = "Roll " .. currentItemLink .. " - " .. priorityLabel .. "MS: /roll 100 - OS: /roll 99 - " .. activeDuration .. " sec"
    end
    if not SendRaidAnnouncement(startMessage, true) then
        return
    end

    ClearRolls()
    awardedPlayersForRoll = {}
    currentRollAwardOrder = {}
    rollSessionStarted = true
    rollSessionOpen = true
    rollTimerActive = true
    timerAlerted = {}
    timerAccumulator = 0
    rollStartTime = GetTime and GetTime() or 0
    rollEndTime = rollStartTime + activeDuration
    if inRaid then
        syncSessionID = GenerateSessionID()
    else
        syncSessionID = nil
    end
    syncOwner = UnitName("player")

    if mainFrame then
        mainFrame.startRollButton:SetText("Restart Roll")
        mainFrame.timerText:SetText("Roll closes in: " .. activeDuration .. "s")
        mainFrame:Show()
    end
    SetTimerVisual(activeDuration)
    ShowLocalTimerAlert("ROLL STARTED - " .. activeDuration .. "s")

    if inRaid then
        local syncMessage = table.concat({
            "START",
            tostring(syncSessionID),
            tostring(activeDuration),
            tostring(currentItemID or 0),
            tostring(currentItemLink or ""),
        }, "\t")

        if not SendSyncRaw(syncMessage, "RAID") then
            Print("raid synchronization is unavailable on this client; other addon users will not receive the shared timer.")
        else
            SendSyncRaw("TOP\t" .. tostring(syncSessionID) .. "\t" .. tostring(currentTopRolls or 1), "RAID")
            AscensionRaidRollsSoftRes.BroadcastCurrentState("RAID")
            BroadcastLootHistory("RAID")
        end
    end

    if UpdateControlState then
        UpdateControlState()
    end
end

local function AnnounceWinner()
    if not CanControlRolls or not CanControlRolls() then
        Print("only the current Master Looter can announce a winner.")
        return
    end

    if not selectedRoll then
        Print("click a roll first to select the winner.")
        return
    end

    if not currentItemLink then
        Print("no item is currently selected.")
        return
    end

    local message = selectedRoll.name .. " has won " .. currentItemLink
    SendRaidAnnouncement(message, true)
end

local function FindRaidUnit(name)
    local key = NormalizeName(name)
    if not key then
        return nil
    end

    local playerName = UnitName("player")
    if NormalizeName(playerName) == key then
        return "player"
    end

    local count = GetNumRaidMembers and GetNumRaidMembers() or 0
    local i
    for i = 1, count do
        local rosterName = GetRaidRosterInfo(i)
        if NormalizeName(rosterName) == key then
            return "raid" .. i
        end
    end

    -- Outside raids, allow Trade testing/use with normal party members too.
    for i = 1, 4 do
        local partyName = UnitName and UnitName("party" .. i) or nil
        if NormalizeName(partyName) == key then
            return "party" .. i
        end
    end

    return nil
end

local function ExtractItemID(itemLink)
    if type(itemLink) ~= "string" then
        return nil
    end

    return tonumber(itemLink:match("item:(%d+)"))
end

local function FindItemInBags(itemLink, itemID)
    if not GetContainerNumSlots or not GetContainerItemLink then
        return nil, nil
    end

    local wantedID = tonumber(itemID) or ExtractItemID(itemLink)
    local bag
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot
        for slot = 1, slots do
            local bagLink = GetContainerItemLink(bag, slot)
            if bagLink then
                local matches = false
                if itemLink and bagLink == itemLink then
                    matches = true
                elseif wantedID and ExtractItemID(bagLink) == wantedID then
                    matches = true
                end

                if matches then
                    local locked = false
                    if GetContainerItemInfo then
                        local _, _, isLocked = GetContainerItemInfo(bag, slot)
                        locked = isLocked and true or false
                    end

                    if not locked then
                        return bag, slot
                    end
                end
            end
        end
    end

    return nil, nil
end

local function FindFreeTradeSlot()
    local slot
    for slot = 1, 6 do
        if not GetTradePlayerItemLink or not GetTradePlayerItemLink(slot) then
            return slot
        end
    end
    return nil
end

local function ClearPendingTradeItem()
    pendingTradeItemLink = nil
    pendingTradeItemID = nil
    pendingTradePlayer = nil
end

local function PlacePendingTradeItem()
    if not pendingTradeItemLink then
        return
    end

    if not PickupContainerItem or not ClickTradeButton then
        Print("the client does not expose the bag/trade functions needed to auto-place the item.")
        ClearPendingTradeItem()
        return
    end

    local bag, slot = FindItemInBags(pendingTradeItemLink, pendingTradeItemID)
    if bag == nil or slot == nil then
        Print("could not find the selected item in your bags. Trade opened without auto-placing it.")
        ClearPendingTradeItem()
        return
    end

    local tradeSlot = FindFreeTradeSlot()
    if not tradeSlot then
        Print("no free item slot is available in the trade window.")
        ClearPendingTradeItem()
        return
    end

    if ClearCursor then
        ClearCursor()
    end

    PickupContainerItem(bag, slot)
    ClickTradeButton(tradeSlot)

    if CursorHasItem and CursorHasItem() then
        if ClearCursor then
            ClearCursor()
        end
        Print("the item could not be placed automatically. You can still add it manually.")
    else
        Print("placed the selected item into the trade window for " .. tostring(pendingTradePlayer or "the selected player") .. ".")
    end

    ClearPendingTradeItem()
end

local function TradeWinner()
    if not CanControlRolls or not CanControlRolls() then
        Print("only the current Master Looter can announce and trade the winner.")
        return
    end

    if not selectedRoll then
        Print("click a roll first to select the player to trade with.")
        return
    end

    if not currentItemLink then
        Print("no item is currently selected. Drop the item into the addon before using Trade.")
        return
    end

    local unit = FindRaidUnit(selectedRoll.name)
    if not unit then
        RefreshRaidMembers()
        unit = FindRaidUnit(selectedRoll.name)
    end

    if not unit then
        Print("could not find " .. selectedRoll.name .. " in your current raid/party.")
        return
    end

    -- The winner announcement is optional. Muting it never changes winner
    -- tracking or the trade flow; it only suppresses the chat/RW message.
    if not AscensionRaidRollsDB.muteWinnerAnnouncement then
        SendRaidAnnouncement(selectedRoll.name .. " has won " .. currentItemLink, true)
    end

    if RecordLootWin(selectedRoll.name, selectedRoll.type) then
        Print(selectedRoll.name .. " is now " .. tostring(selectedRoll.type) .. " +" .. tostring(GetLootWinCount(selectedRoll.name, selectedRoll.type)) .. " for this loot history.")
        UpdateUI()
    end

    if unit == "player" then
        Print("winner announced. The selected player is you, so no trade was opened.")
        return
    end

    if not InitiateTrade then
        Print("winner announced, but InitiateTrade is unavailable on this client.")
        return
    end

    -- TRADE_SHOW fires only once the trade window really exists.  Store the
    -- item now and deposit it when that event arrives, otherwise the client
    -- can receive ClickTradeButton before there is a valid trade slot.
    pendingTradeItemLink = currentItemLink
    pendingTradeItemID = currentItemID or ExtractItemID(currentItemLink)
    pendingTradePlayer = selectedRoll.name

    InitiateTrade(unit)
end

-- Automatic Master Loot -----------------------------------------------------------
-- Opt-in: when enabled, each master-loot eligible item in the open loot window
-- is assigned to the configured recipient (@ME or a player name).
local function NormalizeMasterLooterSetting(value)
    value = Trim(value or "") or ""
    if value == "" or string.upper(value) == "@ME" then
        return "@ME"
    end

    -- Also accept the visual notation [PlayerName].
    value = value:gsub("^%[", ""):gsub("%]$", "")
    value = Trim(value) or ""
    if value == "" then
        return "@ME"
    end
    return value
end

local function SaveMasterLooterSetting()
    local value = (AscensionRaidRollsDB and AscensionRaidRollsDB.masterLooter) or "@ME"
    if mainFrame and mainFrame.masterLooterEdit then
        value = mainFrame.masterLooterEdit:GetText()
    end

    value = NormalizeMasterLooterSetting(value)
    AscensionRaidRollsDB.masterLooter = value
    if mainFrame and mainFrame.masterLooterEdit then
        mainFrame.masterLooterEdit:SetText(value)
    end
    return value
end

local function ResolveMasterLooterTarget()
    local setting = SaveMasterLooterSetting()
    if string.upper(setting) == "@ME" then
        return UnitName("player") or "player"
    end
    return setting
end

local function SetAutoMasterLootEnabled(enabled, quiet)
    AscensionRaidRollsDB.autoMasterLoot = enabled and true or false
    if mainFrame and mainFrame.autoLootCheck then
        mainFrame.autoLootCheck:SetChecked(AscensionRaidRollsDB.autoMasterLoot)
    end

    if not AscensionRaidRollsDB.autoMasterLoot then
        autoMasterLootProcessing = false
        autoMasterLootWaiting = false
        autoMasterLootTarget = nil
    end

    if not quiet then
        if AscensionRaidRollsDB.autoMasterLoot then
            Print("automatic Master Loot enabled -> " .. tostring(ResolveMasterLooterTarget()) .. ".")
        else
            Print("automatic Master Loot disabled.")
        end
    end
end

GetActualMasterLooterName = function()
    if not GetLootMethod then
        return nil, nil
    end

    local method, partyIndex, raidIndex = GetLootMethod()
    if method ~= "master" then
        return nil, method
    end

    if raidIndex and raidIndex > 0 and GetRaidRosterInfo then
        return GetRaidRosterInfo(raidIndex), method
    end

    if partyIndex ~= nil then
        if partyIndex == 0 then
            return UnitName("player"), method
        elseif partyIndex > 0 then
            return UnitName("party" .. partyIndex), method
        end
    end

    if raidIndex == 0 then
        return UnitName("player"), method
    end

    return nil, method
end

CanControlRolls = function()
    -- ML / Viewer permissions only apply in raids. Outside a raid ARR runs in
    -- Standalone Mode with full controls, which is useful for setup and tests.
    if not IsInRaid() then
        return true
    end

    if not GetActualMasterLooterName then
        return false
    end

    local actualMaster, method = GetActualMasterLooterName()
    if method ~= "master" or not actualMaster then
        return false
    end

    return IsSamePlayerName(actualMaster, UnitName("player"))
end

UpdateControlState = function()
    if not mainFrame then
        return
    end

    local actualMaster, method = GetActualMasterLooterName()
    local canControl = CanControlRolls()
    local inRaid = IsInRaid()

    local remoteSyncedSession = IsRemoteSyncedSession and IsRemoteSyncedSession() or false
    local controlledTimedSession = rollSessionStarted and ((inRaid and syncSessionID ~= nil) or (not inRaid))

    if not inRaid then
        mainFrame.subtitle:SetText("Standalone mode  •  Full controls  •  First roll counts")
    elseif canControl then
        mainFrame.subtitle:SetText("Master Looter mode  •  First roll counts")
    elseif remoteSyncedSession then
        mainFrame.subtitle:SetText("Viewer mode  •  Master Looter: " .. tostring(actualMaster or syncOwner) .. "  •  First roll counts")
    elseif method == "master" and actualMaster then
        mainFrame.subtitle:SetText("Local roll mode  •  Master Looter: " .. tostring(actualMaster) .. "  •  First roll counts")
    else
        mainFrame.subtitle:SetText("Local roll mode  •  First roll counts")
    end

    SetButtonEnabled(mainFrame.startRollButton, canControl and currentItemLink ~= nil and not tieBreakActive)
    if mainFrame.tieButton then
        local canTieBreak = canControl and not rollTimerActive and selectedRoll ~= nil and selectedRoll.isFirst and selectedRoll.isTied
        SetButtonEnabled(mainFrame.tieButton, canTieBreak)
    end

    -- The Master Looter can reset the shared session. A viewer can also reset
    -- their own local log when no addon-hosted shared session currently exists.
    SetButtonEnabled(mainFrame.clearButton, canControl or not remoteSyncedSession)
    SetButtonEnabled(mainFrame.tradeButton, canControl and selectedRoll ~= nil and not tieBreakActive)

    -- In fallback/local mode the MS/OS buttons stay usable even when the real
    -- Master Looter does not run ARR. Once an addon-hosted timed session exists,
    -- both host and viewers are bound by its open/closed state, so at 0 the
    -- buttons are disabled and late rolls remain rejected.
    local canPlayerRoll = true
    if controlledTimedSession then
        canPlayerRoll = rollSessionOpen
    end
    if tieBreakActive then
        local playerKey = NormalizeName(UnitName("player"))
        local eligible = playerKey and tieBreakPlayers[playerKey] and tieBreakRoundRolls[playerKey] == nil
        SetButtonEnabled(mainFrame.msRollButton, canPlayerRoll and eligible and tieBreakType == "MS")
        SetButtonEnabled(mainFrame.osRollButton, canPlayerRoll and eligible and tieBreakType == "OS")
    else
        SetButtonEnabled(mainFrame.msRollButton, canPlayerRoll)
        SetButtonEnabled(mainFrame.osRollButton, canPlayerRoll)
    end

    if mainFrame.durationEdit then
        if mainFrame.durationEdit.Enable and mainFrame.durationEdit.Disable then
            if canControl then
                mainFrame.durationEdit:Enable()
            else
                mainFrame.durationEdit:Disable()
            end
        end
        mainFrame.durationEdit:SetAlpha(canControl and 1.0 or 0.45)
    end

    if mainFrame.masterLooterEdit then
        if mainFrame.masterLooterEdit.Enable and mainFrame.masterLooterEdit.Disable then
            if canControl then
                mainFrame.masterLooterEdit:Enable()
            else
                mainFrame.masterLooterEdit:Disable()
            end
        end
        mainFrame.masterLooterEdit:SetAlpha(canControl and 1.0 or 0.45)
    end

    if mainFrame.autoLootCheck then
        if canControl and mainFrame.autoLootCheck.Enable then
            mainFrame.autoLootCheck:Enable()
        elseif (not canControl) and mainFrame.autoLootCheck.Disable then
            mainFrame.autoLootCheck:Disable()
        end
        mainFrame.autoLootCheck:SetAlpha(canControl and 1.0 or 0.45)
    end

    if mainFrame.masterLooterLabel then
        mainFrame.masterLooterLabel:SetAlpha(canControl and 1.0 or 0.55)
    end
    if UpdateOptionsControlState then
        UpdateOptionsControlState()
    end
end

local function ApplySyncedSession(sender, sessionID, isOpen, remaining, duration, itemID, itemLink, fromSnapshot)
    if not IsSenderCurrentMasterLooter(sender) then
        return false
    end

    syncStateRequested = false
    syncOwner = sender
    syncSessionID = sessionID
    syncReceivingState = fromSnapshot and true or false
    selectedRoll = nil

    ClearRolls()
    currentTopRolls = 1

    local parsedItemID = tonumber(itemID)
    if parsedItemID == 0 then
        parsedItemID = nil
    end

    if itemLink and itemLink ~= "" then
        SetCurrentItem(itemLink, parsedItemID)
    else
        currentItemLink = nil
        currentItemID = nil
        currentTopRolls = 1
        UpdateItemDisplay()
    end

    activeDuration = tonumber(duration) or DEFAULT_ROLL_DURATION
    if activeDuration < MIN_ROLL_DURATION then
        activeDuration = MIN_ROLL_DURATION
    elseif activeDuration > MAX_ROLL_DURATION then
        activeDuration = MAX_ROLL_DURATION
    end

    rollSessionStarted = true
    rollSessionOpen = isOpen and true or false
    timerAlerted = {}
    timerAccumulator = 0

    local now = GetTime and GetTime() or 0
    local remainingValue = tonumber(remaining) or 0

    if rollSessionOpen and remainingValue > 0 then
        rollTimerActive = true
        rollStartTime = now
        rollEndTime = now + remainingValue
        if mainFrame then
            mainFrame.timerText:SetText("Roll closes in: " .. math.ceil(remainingValue) .. "s")
            mainFrame.startRollButton:SetText("Start Roll")
        end
        SetTimerVisual(remainingValue)
    else
        rollTimerActive = false
        rollSessionOpen = false
        rollStartTime = 0
        rollEndTime = 0
        SetTimerVisual(0)
        if mainFrame then
            mainFrame.timerText:SetText("ROLL CLOSED")
            mainFrame.startRollButton:SetText("Start Roll")
        end
    end

    if mainFrame then
        mainFrame:Show()
    end

    UpdateUI()
    return true
end

local function CloseSyncedSession(sessionID)
    if not syncSessionID or tostring(sessionID) ~= tostring(syncSessionID) then
        return false
    end

    local wasActive = rollTimerActive
    rollTimerActive = false
    rollSessionStarted = true
    rollSessionOpen = false
    rollStartTime = 0
    rollEndTime = 0
    syncReceivingState = false
    SetTimerVisual(0)

    if mainFrame then
        mainFrame.timerText:SetText("ROLL CLOSED")
        mainFrame.startRollButton:SetText("Start Roll")
    end

    if wasActive then
        ShowLocalTimerAlert("ROLL CLOSED")
    end

    UpdateUI()
    return true
end

local function ResetSyncedSession(sessionID)
    if syncSessionID and sessionID and tostring(sessionID) ~= tostring(syncSessionID) then
        return false
    end

    ClearRolls()
    CancelRollSession()
    syncSessionID = nil
    syncReceivingState = false
    selectedRoll = nil
    UpdateUI()
    return true
end

-- If the player leaves a raid while viewing another player's synchronized
-- session, discard that remote authority immediately. Standalone Mode should
-- never inherit a closed timer or viewer lock from the raid that was just left.
local function ClearRemoteRaidStateOutsideRaid()
    if IsInRaid() then
        return false
    end

    if syncOwner and not IsSamePlayerName(syncOwner, UnitName("player")) then
        ClearRolls()
        awardedPlayersForRoll = {}
        currentRollAwardOrder = {}
        CancelRollSession()
        syncSessionID = nil
        syncOwner = nil
        syncStateRequested = false
        syncReceivingState = false
        selectedRoll = nil
        syncedLootHistory = { MS = {}, OS = {} }
        syncedPlusOneEnabled = false
        AscensionRaidRollsSoftRes.syncedPriorityEnabled = false
        AscensionRaidRollsSoftRes.syncedPlayers = {}
        AscensionRaidRollsSoftRes.syncedHardReserve = false
        syncedLootHistoryRevision = 0
        pendingSyncedLootHistory = nil
        currentItemLink = nil
        currentItemID = nil
        currentTopRolls = 1
        UpdateItemDisplay()
        UpdateUI()
        return true
    end

    return false
end

local function HandleAddonSync(prefix, message, channel, sender)
    if prefix ~= SYNC_PREFIX or type(message) ~= "string" or not sender then
        return
    end

    -- Ignore our own broadcast echo; the authoritative client has already
    -- applied the local state before publishing it.
    if IsSamePlayerName(sender, UnitName("player")) then
        return
    end

    local command = message:match("^([^\t]+)")
    if not command then
        return
    end

    if command == "VER" then
        local protocol, version = message:match("^VER\t([^\t]+)\t([^\t]+)$")
        if version then
            NotifyNewerVersion(version, sender)
            if AscensionRaidRolls.Version.IsNewer(ADDON_VERSION, version) then
                SendSyncRaw("VER\t" .. tostring(SYNC_PROTOCOL) .. "\t" .. tostring(ADDON_VERSION), "WHISPER", sender)
            end
        end
        return
    end

    if command == "REQ" then
        if CanControlRolls and CanControlRolls() and SendFullSyncState then
            SendFullSyncState(sender)
        end
        return
    end

    -- All state-changing synchronization must come from the actual current
    -- Master Looter. This prevents assistants or ordinary raid members from
    -- creating fake roll sessions for other addon users.
    if not IsSenderCurrentMasterLooter(sender) then
        return
    end

    if command == "SRSTATE" then
        local sessionID, enabled, hardReserved = message:match("^SRSTATE\t([^\t]+)\t([01])\t([01])$")
        if sessionID and (sessionID == "0" or not syncSessionID or tostring(sessionID) == tostring(syncSessionID)) then
            AscensionRaidRollsSoftRes.syncedPriorityEnabled = enabled == "1"
            AscensionRaidRollsSoftRes.syncedHardReserve = hardReserved == "1"
            AscensionRaidRollsSoftRes.syncedPlayers = {}
            UpdateItemDisplay()
            UpdateUI()
        end
        return
    end

    if command == "SRPLAYER" then
        local sessionID, playerKey, reserveCount = message:match("^SRPLAYER\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
        if not sessionID then
            sessionID, playerKey = message:match("^SRPLAYER\t([^\t]+)\t([^\t]+)$")
            reserveCount = 1
        end
        if sessionID and playerKey and (sessionID == "0" or not syncSessionID or tostring(sessionID) == tostring(syncSessionID)) then
            playerKey = NormalizeName(playerKey)
            if playerKey then AscensionRaidRollsSoftRes.syncedPlayers[playerKey] = math.max(1, math.floor(tonumber(reserveCount) or 1)) end
            UpdateUI()
        end
        return
    end

    if command == "PLUSBEGIN" then
        local revision, enabled = message:match("^PLUSBEGIN\t([^\t]+)\t([01])$")
        revision = tonumber(revision)
        if revision and revision >= syncedLootHistoryRevision then
            pendingSyncedLootHistory = {
                revision = revision,
                enabled = enabled == "1",
                history = { MS = {}, OS = {} },
            }
        end
        return
    end

    if command == "PLUSENTRY" then
        local revision, rollType, playerKey, count = message:match("^PLUSENTRY\t([^\t]+)\t([A-Z]+)\t([^\t]+)\t([^\t]+)$")
        if rollType ~= "MS" and rollType ~= "OS" then revision = nil end
        if not revision then
            revision, playerKey, count = message:match("^PLUSENTRY\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            rollType = "MS"
        end
        revision = tonumber(revision)
        count = math.max(0, math.floor(tonumber(count) or 0))
        if pendingSyncedLootHistory and revision == pendingSyncedLootHistory.revision and count > 0 then
            pendingSyncedLootHistory.history[rollType][NormalizeName(playerKey) or playerKey] = count
        end
        return
    end

    if command == "PLUSEND" then
        local revision = tonumber(message:match("^PLUSEND\t([^\t]+)$"))
        if pendingSyncedLootHistory and revision == pendingSyncedLootHistory.revision then
            syncedLootHistoryRevision = revision
            syncedPlusOneEnabled = pendingSyncedLootHistory.enabled
            syncedLootHistory = pendingSyncedLootHistory.history
            pendingSyncedLootHistory = nil
            UpdateUI()
        end
        return
    end

    if command == "PLUSSET" then
        local revision, rollType, playerKey, count = message:match("^PLUSSET\t([^\t]+)\t([A-Z]+)\t([^\t]+)\t([^\t]+)$")
        if rollType ~= "MS" and rollType ~= "OS" then revision = nil end
        if not revision then
            revision, playerKey, count = message:match("^PLUSSET\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            rollType = "MS"
        end
        revision = tonumber(revision)
        count = math.max(0, math.floor(tonumber(count) or 0))
        playerKey = NormalizeName(playerKey)
        if revision and playerKey and revision >= syncedLootHistoryRevision then
            syncedLootHistoryRevision = revision
            if count > 0 then
                syncedLootHistory[rollType] = syncedLootHistory[rollType] or {}
                syncedLootHistory[rollType][playerKey] = count
            else
                syncedLootHistory[rollType] = syncedLootHistory[rollType] or {}
                syncedLootHistory[rollType][playerKey] = nil
            end
            UpdateUI()
        end
        return
    end

    if command == "START" then
        local sessionID, duration, itemID, itemLink = message:match("^START\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
        if sessionID then
            ApplySyncedSession(sender, sessionID, true, duration, duration, itemID, itemLink, false)
            ShowLocalTimerAlert("ROLL STARTED - " .. tostring(math.ceil(tonumber(duration) or DEFAULT_ROLL_DURATION)) .. "s")
        end
        return
    end

    if command == "STATE" then
        local sessionID, openFlag, remaining, duration, itemID, itemLink = message:match("^STATE\t([^\t]+)\t([01])\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
        if sessionID then
            ApplySyncedSession(sender, sessionID, openFlag == "1", remaining, duration, itemID, itemLink, true)
        end
        return
    end

    if command == "TOP" then
        local sessionID, topRolls = message:match("^TOP\t([^\t]+)\t([^\t]+)$")
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) then
            currentTopRolls = math.max(1, math.floor((tonumber(topRolls) or 1) + 0.5))
            UpdateItemDisplay()
        end
        return
    end

    if command == "ROLL" then
        local sessionID, playerName, roll, minimum, maximum, validFlag, softReserveIndex = message:match("^ROLL\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([01])\t([^\t]+)$")
        if not sessionID then
            local reserved
            sessionID, playerName, roll, minimum, maximum, reserved = message:match("^ROLL\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([01])$")
            if sessionID then
                softReserveIndex = reserved == "1" and "1" or "0"
            else
                sessionID, playerName, roll, minimum, maximum = message:match("^ROLL\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            end
        end
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) then
            if rollSessionOpen or syncReceivingState then
                local validOverride
                if validFlag == "1" then
                    validOverride = true
                elseif validFlag == "0" then
                    validOverride = false
                end
                AddRoll(playerName, tonumber(roll), tonumber(minimum), tonumber(maximum), true, validOverride, tonumber(softReserveIndex))
            end
        end
        return
    end

    if command == "TBPATH" then
        local sessionID, playerName, rollType, pathText = message:match("^TBPATH\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) then
            local entry = FindValidEntry(NormalizeName(playerName), rollType)
            if entry then
                entry.tiePath = {}
                local value
                for value in string.gmatch(tostring(pathText or ""), "[^,]+") do
                    local numberValue = tonumber(value)
                    if numberValue then
                        entry.tiePath[#entry.tiePath + 1] = numberValue
                    end
                end
                UpdateUI()
            end
        end
        return
    end

    if command == "TIESTART" then
        local sessionID, round, rollType, duration, playerList = message:match("^TIESTART\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) then
            ApplyTieBreakStart(sessionID, round, rollType, duration, duration, playerList)
            ShowLocalTimerAlert("TIE-BREAK - " .. tostring(math.ceil(tonumber(duration) or DEFAULT_ROLL_DURATION)) .. "s")
        end
        return
    end

    if command == "TIESTATE" then
        local sessionID, round, rollType, remaining, duration, playerList = message:match("^TIESTATE\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) then
            ApplyTieBreakStart(sessionID, round, rollType, remaining, duration, playerList)
        end
        return
    end

    if command == "TIEROLL" then
        local sessionID, round, playerName, roll, maximum = message:match("^TIEROLL\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) and tonumber(round) == tonumber(tieBreakRound) then
            AddTieBreakRoll(playerName, tonumber(roll), 1, tonumber(maximum), true)
        end
        return
    end

    if command == "TIEEND" then
        local sessionID, round = message:match("^TIEEND\t([^\t]+)\t([^\t]+)$")
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) and tonumber(round) == tonumber(tieBreakRound) then
            local wasActive = tieBreakActive
            rollTimerActive = false
            rollSessionOpen = false
            rollStartTime = 0
            rollEndTime = 0
            tieBreakActive = false
            tieBreakPlayers = {}
            tieBreakRoundRolls = {}
            SetTimerVisual(0)
            if mainFrame then
                mainFrame.timerText:SetText("TIE-BREAK CLOSED")
            end
            if wasActive then
                ShowLocalTimerAlert("TIE-BREAK CLOSED")
            end
            UpdateUI()
        end
        return
    end

    if command == "STATEDONE" then
        local sessionID = message:match("^STATEDONE\t([^\t]+)$")
        if sessionID and syncSessionID and tostring(sessionID) == tostring(syncSessionID) then
            syncReceivingState = false
            syncStateRequested = false
            UpdateUI()
        end
        return
    end

    if command == "END" then
        local sessionID = message:match("^END\t([^\t]+)$")
        if sessionID then
            CloseSyncedSession(sessionID)
        end
        return
    end

    if command == "RESET" then
        local sessionID = message:match("^RESET\t([^\t]+)$")
        if sessionID then
            ResetSyncedSession(sessionID)
        end
        return
    end

    if command == "IDLE" then
        syncStateRequested = false
        syncOwner = sender
        syncSessionID = nil
        syncReceivingState = false
        ClearRolls()
        CancelRollSession()
        currentItemLink = nil
        currentItemID = nil
        currentTopRolls = 1
        UpdateItemDisplay()
        UpdateUI()
        return
    end
end

local function ResetRollSessionByController()
    local canControl = CanControlRolls and CanControlRolls() or false

    if canControl then
        if IsInRaid() and syncSessionID then
            BroadcastSessionReset()
        end

        ClearRolls()
        awardedPlayersForRoll = {}
        currentRollAwardOrder = {}
        CancelRollSession()
        syncSessionID = nil
        syncOwner = UnitName("player")
        syncReceivingState = false
        UpdateUI()
        return true, "shared"
    end

    -- Viewer fallback: when no addon-enabled Master Looter is currently hosting
    -- a synchronized session, Reset is purely local and only clears this user's
    -- roll history. It never sends RESET to the raid or affects another client.
    if IsRemoteSyncedSession and IsRemoteSyncedSession() then
        Print("the shared roll session is controlled by the Master Looter; Reset is locked until that session is cleared.")
        return false
    end

    ClearRolls()
    awardedPlayersForRoll = {}
    currentRollAwardOrder = {}
    selectedRoll = nil
    UpdateUI()
    return true, "local"
end

local function PlayerCanAssignMasterLoot()
    local actualMaster, method = GetActualMasterLooterName()
    if method ~= "master" then
        return false, "the current loot method is not Master Loot"
    end

    if actualMaster and NormalizeName(actualMaster) ~= NormalizeName(UnitName("player")) then
        return false, tostring(actualMaster) .. " is the current Master Looter"
    end

    -- Ascension may expose the indices differently from stock 3.3.5. If the
    -- method is Master Loot but the owner index is missing, let GiveMasterLoot
    -- perform the final permission check instead of disabling the feature.
    return true
end

local function LootSlotContainsItem(slot)
    if LootSlotIsItem then
        return LootSlotIsItem(slot) and true or false
    end
    if GetLootSlotLink then
        return GetLootSlotLink(slot) ~= nil
    end
    if GetLootSlotInfo then
        local texture, itemName = GetLootSlotInfo(slot)
        return texture ~= nil and itemName ~= nil
    end
    return false
end

local function GetLootSlotDisplay(slot)
    local link = GetLootSlotLink and GetLootSlotLink(slot) or nil
    if link then
        return link
    end
    if GetLootSlotInfo then
        local _, itemName = GetLootSlotInfo(slot)
        if itemName then
            return itemName
        end
    end
    return "loot slot " .. tostring(slot)
end

local function IsLootSlotLockedCompat(slot)
    if not GetLootSlotInfo then
        return false
    end
    local _, _, _, _, locked = GetLootSlotInfo(slot)
    return locked and true or false
end

local function FindMasterLootCandidateIndex(targetName)
    if not GetMasterLootCandidate then
        return nil
    end

    local targetKey = NormalizeName(targetName)
    if not targetKey then
        return nil
    end

    -- Project Ascension's 3.3.5a API differs from stock WoW here:
    -- GetMasterLootCandidate accepts ONLY the candidate index.
    -- Passing the loot slot as the first argument makes the client repeatedly
    -- query the wrong candidate (usually candidate #1), which prevented @ME
    -- from being found whenever the player was candidate #2 or later.
    local i
    for i = 1, 40 do
        local candidateName = GetMasterLootCandidate(i)
        if candidateName and candidateName ~= "" and NormalizeName(candidateName) == targetKey then
            return i
        end
    end
    return nil
end

local function StopAutoMasterLoot(message)
    autoMasterLootProcessing = false
    autoMasterLootWaiting = false
    autoMasterLootWaitingLink = nil
    autoMasterLootBindConfirmSlot = nil
    autoMasterLootTarget = nil
    autoMasterLootAccumulator = 0
    if message then
        Print(message)
    end
end

local function ProcessAutoMasterLootStep()
    if not autoMasterLootProcessing or autoMasterLootWaiting then
        return
    end

    if not AscensionRaidRollsDB or AscensionRaidRollsDB.autoMasterLoot ~= true then
        StopAutoMasterLoot()
        return
    end

    if not GetNumLootItems or not GiveMasterLoot or not GetMasterLootCandidate then
        StopAutoMasterLoot("automatic Master Loot is unavailable: required loot functions are missing on this client.")
        return
    end

    local numLoot = GetNumLootItems() or 0
    if numLoot <= 0 then
        local assigned = autoMasterLootAssignedCount
        StopAutoMasterLoot()
        if assigned > 0 then
            Print("automatic Master Loot complete: " .. tostring(assigned) .. " item(s) assigned.")
        end
        return
    end

    local sawItem = false
    local sawUnlockedItem = false
    local slot
    for slot = 1, numLoot do
        if LootSlotContainsItem(slot) then
            sawItem = true
            if not IsLootSlotLockedCompat(slot) then
                sawUnlockedItem = true
                local candidateIndex = FindMasterLootCandidateIndex(autoMasterLootTarget)
                if candidateIndex then
                    autoMasterLootWaiting = true
                    autoMasterLootWaitingLink = GetLootSlotDisplay(slot)
                    autoMasterLootWaitingSince = GetTime and GetTime() or 0
                    GiveMasterLoot(slot, candidateIndex)
                    return
                end
            end
        end
    end

    if not sawItem then
        StopAutoMasterLoot()
        return
    end

    -- A slot can remain locked for a short moment after another assignment.
    -- Wait for the next update instead of treating that temporary state as a
    -- permanent eligibility failure.
    if not sawUnlockedItem then
        return
    end

    StopAutoMasterLoot("no remaining item can be assigned to " .. tostring(autoMasterLootTarget or "the configured player") .. " (not eligible/in range or below the Master Loot threshold).")
end

local function StartAutoMasterLoot()
    if not AscensionRaidRollsDB or AscensionRaidRollsDB.autoMasterLoot ~= true then
        return
    end

    local canAssign, reason = PlayerCanAssignMasterLoot()
    if not canAssign then
        -- Opening normal Personal/Group Loot while Auto Loot to ML is enabled is
        -- expected outside Master Loot raids. Ignore that case silently instead
        -- of flooding chat every time the player loots an item or opens a cache.
        if reason ~= "the current loot method is not Master Loot" then
            Print("automatic Master Loot skipped: " .. tostring(reason) .. ".")
        end
        return
    end

    if not GetNumLootItems or not GiveMasterLoot or not GetMasterLootCandidate then
        Print("automatic Master Loot is unavailable: required loot functions are missing on this client.")
        return
    end

    autoMasterLootProcessing = true
    autoMasterLootTarget = ResolveMasterLooterTarget()
    autoMasterLootAccumulator = 0
    autoMasterLootWaiting = false
    autoMasterLootWaitingLink = nil
    autoMasterLootBindConfirmSlot = nil
    autoMasterLootAssignedCount = 0

    ProcessAutoMasterLootStep()
end

local function HandleAutoMasterLootSlotCleared()
    if not autoMasterLootProcessing then
        return
    end
    autoMasterLootAssignedCount = autoMasterLootAssignedCount + 1
    autoMasterLootWaiting = false
    autoMasterLootWaitingLink = nil
    autoMasterLootAccumulator = 0
end

local function HandleAutoMasterLootBindConfirm(slot)
    if not autoMasterLootProcessing or not AscensionRaidRollsDB or AscensionRaidRollsDB.autoMasterLoot ~= true then
        return
    end

    -- Defer to the next OnUpdate so the stock UI has time to create its
    -- LOOT_BIND popup first; then confirm and hide it.
    if slot then
        autoMasterLootBindConfirmSlot = slot
    end
end

local function UpdateAutoMasterLoot(elapsed)
    if not autoMasterLootProcessing then
        return
    end

    autoMasterLootAccumulator = autoMasterLootAccumulator + (elapsed or 0)
    if autoMasterLootAccumulator < 0.20 then
        return
    end
    autoMasterLootAccumulator = 0

    if autoMasterLootBindConfirmSlot then
        local slot = autoMasterLootBindConfirmSlot
        autoMasterLootBindConfirmSlot = nil
        if ConfirmLootSlot then
            ConfirmLootSlot(slot)
        end
        if StaticPopup_Hide then
            StaticPopup_Hide("LOOT_BIND")
        end
    end

    if autoMasterLootWaiting then
        local now = GetTime and GetTime() or 0
        if now - (autoMasterLootWaitingSince or now) >= 2.0 then
            local pending = autoMasterLootWaitingLink or "an item"
            StopAutoMasterLoot("automatic Master Loot paused on " .. tostring(pending) .. ". The loot slot did not clear.")
        end
        return
    end

    ProcessAutoMasterLootStep()
end

local function ExecutePlayerRoll(maximum)
    maximum = tonumber(maximum)
    if maximum ~= 100 and maximum ~= 99 then
        return
    end

    if rollSessionStarted and not rollSessionOpen then
        Print("this roll is closed; your /roll was not sent.")
        return
    end

    if RandomRoll then
        RandomRoll(1, maximum)
        return
    end

    if RunMacroText then
        RunMacroText("/roll " .. tostring(maximum))
        return
    end

    Print("unable to start /roll " .. tostring(maximum) .. " on this client.")
end

local function SaveQuickRollFramePosition()
    if not quickRollFrame or not AscensionRaidRollsDB then
        return
    end

    local point, _, relativePoint, x, y = quickRollFrame:GetPoint(1)
    AscensionRaidRollsDB.quickRollPoint = point
    AscensionRaidRollsDB.quickRollRelativePoint = relativePoint
    AscensionRaidRollsDB.quickRollX = x
    AscensionRaidRollsDB.quickRollY = y
end

local function ToggleQuickRollFrame()
    if not quickRollFrame then
        return
    end

    if quickRollFrame:IsShown() then
        quickRollFrame:Hide()
    else
        quickRollFrame:Show()
    end
end

local function ToggleMainFrame()
    if not mainFrame then
        return
    end

    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
    end
end

local function Atan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end

    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + PI
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - PI
    elseif x == 0 and y > 0 then
        return PI / 2
    elseif x == 0 and y < 0 then
        return -PI / 2
    end

    return 0
end

local function PositionMinimapButton(angle)
    if not minimapButton or not Minimap then
        return
    end

    angle = tonumber(angle) or 225
    local radians = angle * PI / 180
    local x = math.cos(radians) * MINIMAP_BUTTON_RADIUS
    local y = math.sin(radians) * MINIMAP_BUTTON_RADIUS

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function UpdateMinimapButtonFromCursor()
    if not minimapButton or not Minimap or not GetCursorPosition then
        return
    end

    local cursorX, cursorY = GetCursorPosition()
    local minimapX, minimapY = Minimap:GetCenter()
    if not cursorX or not cursorY or not minimapX or not minimapY then
        return
    end

    local scale = 1
    if UIParent and UIParent.GetEffectiveScale then
        scale = UIParent:GetEffectiveScale() or 1
    elseif UIParent and UIParent.GetScale then
        scale = UIParent:GetScale() or 1
    end

    if scale == 0 then
        scale = 1
    end

    cursorX = cursorX / scale
    cursorY = cursorY / scale

    local angle = Atan2(cursorY - minimapY, cursorX - minimapX) * 180 / PI
    if angle < 0 then
        angle = angle + 360
    end

    AscensionRaidRollsDB.minimapAngle = angle
    PositionMinimapButton(angle)
end

local function CreateMinimapButton()
    if minimapButton or not Minimap then
        return
    end

    minimapButton = CreateFrame("Button", "AscensionRaidRollsMinimapButton", Minimap)
    minimapButton:SetWidth(32)
    minimapButton:SetHeight(32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:EnableMouse(true)

    minimapButton.icon = minimapButton:CreateTexture(nil, "ARTWORK")
    minimapButton.icon:SetWidth(20)
    minimapButton.icon:SetHeight(20)
    minimapButton.icon:SetPoint("CENTER", minimapButton, "CENTER", 0, 0)
    minimapButton.icon:SetTexture("Interface\\Icons\\INV_Misc_Dice_02")
    minimapButton.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    minimapButton.border = minimapButton:CreateTexture(nil, "OVERLAY")
    minimapButton.border:SetWidth(54)
    minimapButton.border:SetHeight(54)
    minimapButton.border:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)
    minimapButton.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    minimapButton.highlight = minimapButton:CreateTexture(nil, "HIGHLIGHT")
    minimapButton.highlight:SetWidth(32)
    minimapButton.highlight:SetHeight(32)
    minimapButton.highlight:SetPoint("CENTER", minimapButton, "CENTER", 0, 0)
    minimapButton.highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapButton.highlight:SetBlendMode("ADD")

    minimapButton:SetScript("OnClick", function(self, button)
        if minimapDragging then
            return
        end

        if button == "LeftButton" or button == "RightButton" then
            ToggleMainFrame()
        end
    end)

    minimapButton:SetScript("OnDragStart", function(self)
        minimapDragging = true
        self:SetScript("OnUpdate", function()
            UpdateMinimapButtonFromCursor()
        end)
    end)

    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        UpdateMinimapButtonFromCursor()
        minimapDragging = false
    end)

    minimapButton:SetScript("OnEnter", function(self)
        if not GameTooltip then
            return
        end

        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Ascension Raid Rolls")
        GameTooltip:AddLine("Click: open / close raid rolls", 1, 1, 1)
        GameTooltip:AddLine("Roll MS / Roll OS are built into the main window", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Drag: move minimap icon", 0.75, 0.75, 0.75)
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    PositionMinimapButton(AscensionRaidRollsDB.minimapAngle or 225)
end

local function SaveFramePosition()
    if not mainFrame or not AscensionRaidRollsDB then
        return
    end

    local point, _, relativePoint, x, y = mainFrame:GetPoint(1)
    AscensionRaidRollsDB.point = point
    AscensionRaidRollsDB.relativePoint = relativePoint
    AscensionRaidRollsDB.x = x
    AscensionRaidRollsDB.y = y
end

local function CreateQuickRollFrame()
    quickRollFrame = CreateFrame("Frame", "AscensionRaidRollsQuickRollFrame", UIParent)
    quickRollFrame:SetWidth(270)
    quickRollFrame:SetHeight(128)
    quickRollFrame:SetFrameStrata("DIALOG")
    quickRollFrame:SetClampedToScreen(true)
    quickRollFrame:EnableMouse(true)
    quickRollFrame:SetMovable(true)
    quickRollFrame:RegisterForDrag("LeftButton")
    quickRollFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    quickRollFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveQuickRollFramePosition()
    end)

    quickRollFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    quickRollFrame.title = quickRollFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    quickRollFrame.title:SetPoint("TOP", quickRollFrame, "TOP", 0, -17)
    quickRollFrame.title:SetText("Quick Roll")

    quickRollFrame.subtitle = quickRollFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    quickRollFrame.subtitle:SetPoint("TOP", quickRollFrame.title, "BOTTOM", 0, -5)
    quickRollFrame.subtitle:SetText("MS = /roll 100   •   OS = /roll 99")

    quickRollFrame.msButton = CreateFrame("Button", nil, quickRollFrame, "UIPanelButtonTemplate")
    quickRollFrame.msButton:SetWidth(108)
    quickRollFrame.msButton:SetHeight(36)
    quickRollFrame.msButton:SetPoint("BOTTOMLEFT", quickRollFrame, "BOTTOMLEFT", 22, 20)
    quickRollFrame.msButton:SetText("Roll MS")
    quickRollFrame.msButton:SetScript("OnClick", function()
        ExecutePlayerRoll(100)
    end)

    quickRollFrame.osButton = CreateFrame("Button", nil, quickRollFrame, "UIPanelButtonTemplate")
    quickRollFrame.osButton:SetWidth(108)
    quickRollFrame.osButton:SetHeight(36)
    quickRollFrame.osButton:SetPoint("BOTTOMRIGHT", quickRollFrame, "BOTTOMRIGHT", -22, 20)
    quickRollFrame.osButton:SetText("Roll OS")
    quickRollFrame.osButton:SetScript("OnClick", function()
        ExecutePlayerRoll(99)
    end)

    quickRollFrame.closeButton = CreateFrame("Button", nil, quickRollFrame, "UIPanelCloseButton")
    quickRollFrame.closeButton:SetPoint("TOPRIGHT", quickRollFrame, "TOPRIGHT", -4, -4)

    local point = AscensionRaidRollsDB.quickRollPoint or "CENTER"
    local relativePoint = AscensionRaidRollsDB.quickRollRelativePoint or "CENTER"
    local x = AscensionRaidRollsDB.quickRollX or 290
    local y = AscensionRaidRollsDB.quickRollY or 0
    quickRollFrame:SetPoint(point, UIParent, relativePoint, x, y)

    quickRollFrame:SetScript("OnShow", function()
        AscensionRaidRollsDB.quickRollShown = true
    end)
    quickRollFrame:SetScript("OnHide", function()
        AscensionRaidRollsDB.quickRollShown = false
    end)

    if AscensionRaidRollsDB.quickRollShown == true then
        quickRollFrame:Show()
    else
        quickRollFrame:Hide()
    end
end

local function CreateRollPanel(parent, anchorPoint, xOffset)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint(anchorPoint, parent, anchorPoint, xOffset, -181)
    panel:SetWidth(275)
    panel:SetHeight(304)

    panel.bg = panel:CreateTexture(nil, "BACKGROUND")
    panel.bg:SetAllPoints(panel)
    panel.bg:SetTexture(0, 0, 0, 0.22)

    panel.scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    panel.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -7)
    panel.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -27, 7)
    panel.scroll:EnableMouseWheel(true)
    panel.scroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local range = self:GetVerticalScrollRange()
        local nextScroll = current - (delta * 44)
        if nextScroll < 0 then
            nextScroll = 0
        elseif nextScroll > range then
            nextScroll = range
        end
        self:SetVerticalScroll(nextScroll)
    end)

    panel.content = CreateFrame("Frame", nil, panel.scroll)
    panel.content:SetWidth(236)
    panel.content:SetHeight(1)
    panel.scroll:SetScrollChild(panel.content)
    panel.rows = {}

    return panel
end

UpdateOptionsControlState = function()
    if not optionsFrame then
        return
    end

    local canManageHistory = not IsInRaid() or (CanControlRolls and CanControlRolls())
    optionsFrame.plusOneCheck:SetChecked(IsMSOSPlusOneEnabled())
    SetButtonEnabled(optionsFrame.plusOneCheck, canManageHistory)
    SetButtonEnabled(optionsFrame.clearHistoryButton, canManageHistory)
    if optionsFrame.muteWinnerCheck then
        SetButtonEnabled(optionsFrame.muteWinnerCheck, canManageHistory)
    end
    if optionsFrame.reserveModeCheck then
        optionsFrame.reserveModeCheck:SetChecked(AscensionRaidRollsSoftRes.IsPriorityEnabled())
        SetButtonEnabled(optionsFrame.reserveModeCheck, canManageHistory)
        SetButtonEnabled(optionsFrame.reserveImportButton, canManageHistory)
        SetButtonEnabled(optionsFrame.reserveCheckButton, canManageHistory)
        if optionsFrame.reserveLimitEdit then
            optionsFrame.reserveLimitEdit:EnableMouse(canManageHistory)
            optionsFrame.reserveLimitEdit:SetTextColor(canManageHistory and 1 or 0.5, canManageHistory and 1 or 0.5, canManageHistory and 1 or 0.5)
        end
        if optionsFrame.reserveURLEdit then
            optionsFrame.reserveURLEdit:EnableMouse(canManageHistory)
            optionsFrame.reserveURLEdit:SetTextColor(canManageHistory and 1 or 0.5, canManageHistory and 1 or 0.5, canManageHistory and 1 or 0.5)
        end
    end

    if optionsFrame.historyText then
        local players = 0
        local items = 0
        local seenPlayers = {}
        local history = GetActiveLootHistory() or {}
        local _, rollType
        for _, rollType in ipairs({ "MS", "OS" }) do
            local playerKey, count
            for playerKey, count in pairs(history[rollType] or {}) do
                if not seenPlayers[playerKey] then
                    seenPlayers[playerKey] = true
                    players = players + 1
                end
                items = items + (tonumber(count) or 0)
            end
        end
        optionsFrame.historyText:SetText("History: " .. tostring(items) .. " MS+OS items / " .. tostring(players) .. " players")
    end
    if optionsFrame.reserveStatus and not ShouldUseSyncedLootHistory() then
        local data = AscensionRaidRollsSoftRes.GetData()
        if data and type(data.roster) == "table" then
            local players, reserves, hard = 0, 0, 0
            local _, entry
            for _, entry in pairs(data.roster) do players = players + 1; reserves = reserves + (tonumber(entry.itemCount) or 0) end
            for _ in pairs(data.hardItems or {}) do hard = hard + 1 end
            optionsFrame.reserveStatus:SetText(tostring(players) .. " players, " .. tostring(reserves) .. " SR, " .. tostring(hard) .. " HR imported.")
        end
    end
end

function AscensionRaidRollsSoftRes.CreateImportFrame()
    if AscensionRaidRollsSoftRes.importFrame then
        return AscensionRaidRollsSoftRes.importFrame
    end

    local frame = CreateFrame("Frame", "AscensionRaidRollsReserveImportFrame", UIParent)
    frame:SetWidth(800)
    frame:SetHeight(560)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -19)
    frame.title:SetText("Import SoftRes / HardRes")

    frame.help = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.help:SetPoint("TOPLEFT", frame, "TOPLEFT", 38, -60)
    frame.help:SetWidth(720)
    frame.help:SetJustifyH("LEFT")
    frame.help:SetText("Paste the complete BisBeard Base64 export below.")
    frame.help:SetTextColor(0.75, 0.75, 0.75)

    frame.editBackground = CreateFrame("Frame", nil, frame)
    frame.editBackground:SetPoint("TOPLEFT", frame, "TOPLEFT", 38, -85)
    frame.editBackground:SetWidth(724)
    frame.editBackground:SetHeight(370)
    frame.editBackground:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 8,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame.editBackground:SetBackdropColor(0.01, 0.01, 0.01, 0.98)
    frame.editBackground:SetBackdropBorderColor(0.55, 0.55, 0.55, 1.0)

    frame.scroll = CreateFrame("ScrollFrame", nil, frame.editBackground, "UIPanelScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", frame.editBackground, "TOPLEFT", 8, -8)
    frame.scroll:SetPoint("BOTTOMRIGHT", frame.editBackground, "BOTTOMRIGHT", -28, 8)
    frame.scroll:EnableMouseWheel(true)
    frame.scroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local range = self:GetVerticalScrollRange()
        local nextScroll = current - (delta * 45)
        if nextScroll < 0 then nextScroll = 0 end
        if nextScroll > range then nextScroll = range end
        self:SetVerticalScroll(nextScroll)
    end)

    frame.edit = CreateFrame("EditBox", nil, frame.scroll)
    frame.edit:SetWidth(675)
    frame.edit:SetHeight(350)
    frame.edit:SetMultiLine(true)
    frame.edit:SetAutoFocus(false)
    frame.edit:SetMaxLetters(100000)
    frame.edit:SetFontObject(GameFontHighlightSmall)
    frame.edit:SetTextColor(1.0, 1.0, 1.0)
    frame.edit:SetTextInsets(4, 4, 4, 4)
    frame.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); frame:Hide() end)
    frame.scroll:SetScrollChild(frame.edit)

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetPoint("TOPLEFT", frame, "TOPLEFT", 40, -468)
    frame.status:SetWidth(720)
    frame.status:SetJustifyH("LEFT")
    frame.status:SetText("")

    frame.importButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.importButton:SetWidth(210)
    frame.importButton:SetHeight(26)
    frame.importButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 140, 28)
    frame.importButton:SetText("Import")
    frame.importButton:SetScript("OnClick", function()
        if AscensionRaidRollsSoftRes.ImportExport(frame.edit:GetText()) then
            frame.edit:ClearFocus()
            frame:Hide()
            UpdateOptionsControlState()
        end
    end)

    frame.cancelButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.cancelButton:SetWidth(210)
    frame.cancelButton:SetHeight(26)
    frame.cancelButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -140, 28)
    frame.cancelButton:SetText("Cancel")
    frame.cancelButton:SetScript("OnClick", function() frame.edit:ClearFocus(); frame:Hide() end)

    frame.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    frame:SetScript("OnShow", function()
        frame.edit:SetText(AscensionRaidRollsDB.reserveImportText or "")
        frame.status:SetText("")
        frame.edit:SetFocus()
        frame.edit:SetCursorPosition(0)
        frame.scroll:SetVerticalScroll(0)
    end)
    frame:Hide()
    AscensionRaidRollsSoftRes.importFrame = frame
    return frame
end

local function CreateOptionsFrame()
    if optionsFrame then
        return
    end

    optionsFrame = CreateFrame("Frame", "AscensionRaidRollsOptionsFrame", UIParent)
    optionsFrame:SetWidth(390)
    optionsFrame:SetHeight(525)
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:SetMovable(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    optionsFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    optionsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)

    optionsFrame.title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    optionsFrame.title:SetPoint("TOP", optionsFrame, "TOP", 0, -18)
    optionsFrame.title:SetText("AscensionRaidRolls Options")

    optionsFrame.closeButton = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    optionsFrame.closeButton:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -4, -4)

    optionsFrame.plusOneCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    optionsFrame.plusOneCheck:SetWidth(24)
    optionsFrame.plusOneCheck:SetHeight(24)
    optionsFrame.plusOneCheck:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -55)
    optionsFrame.plusOneCheck:SetScript("OnClick", function(self)
        if IsInRaid() and (not CanControlRolls or not CanControlRolls()) then
            self:SetChecked(IsMSOSPlusOneEnabled())
            return
        end
        AscensionRaidRollsDB.msosPlusOneEnabled = self:GetChecked() and true or false
        BroadcastLootHistory()
        UpdateUI()
        Print("MS/OS+1 " .. (AscensionRaidRollsDB.msosPlusOneEnabled and "enabled." or "disabled."))
    end)

    optionsFrame.plusOneLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    optionsFrame.plusOneLabel:SetPoint("LEFT", optionsFrame.plusOneCheck, "RIGHT", 3, 0)
    optionsFrame.plusOneLabel:SetText("Enable MS/OS+1 loot history")

    optionsFrame.plusOneHelp = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.plusOneHelp:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 30, -82)
    optionsFrame.plusOneHelp:SetWidth(330)
    optionsFrame.plusOneHelp:SetJustifyH("LEFT")
    optionsFrame.plusOneHelp:SetText("Shows separate +X counters in MS and OS. Trade credits the selected roll type; both histories persist until cleared.")
    optionsFrame.plusOneHelp:SetTextColor(0.70, 0.70, 0.70)

    optionsFrame.historyText = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.historyText:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 30, -121)
    optionsFrame.historyText:SetTextColor(0.85, 0.85, 0.85)

    optionsFrame.clearHistoryButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    optionsFrame.clearHistoryButton:SetWidth(145)
    optionsFrame.clearHistoryButton:SetHeight(22)
    optionsFrame.clearHistoryButton:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -25, -113)
    optionsFrame.clearHistoryButton:SetText("Clear Loot History")
    optionsFrame.clearHistoryButton:SetScript("OnClick", function()
        ClearLootHistory()
        if optionsFrame and optionsFrame.historyText then
            optionsFrame.historyText:SetText("History: 0 items / 0 players")
        end
    end)

    optionsFrame.separator = optionsFrame:CreateTexture(nil, "ARTWORK")
    optionsFrame.separator:SetTexture(1, 1, 1, 0.12)
    optionsFrame.separator:SetHeight(1)
    optionsFrame.separator:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -153)
    optionsFrame.separator:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -24, -153)

    optionsFrame.reserveTitle = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optionsFrame.reserveTitle:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 25, -169)
    optionsFrame.reserveTitle:SetText("SoftRes / HardRes")

    optionsFrame.reserveModeCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    optionsFrame.reserveModeCheck:SetWidth(24)
    optionsFrame.reserveModeCheck:SetHeight(24)
    optionsFrame.reserveModeCheck:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -190)
    optionsFrame.reserveModeCheck:SetScript("OnClick", function(self)
        if IsInRaid() and (not CanControlRolls or not CanControlRolls()) then
            self:SetChecked(AscensionRaidRollsSoftRes.IsPriorityEnabled())
            return
        end
        AscensionRaidRollsDB.reservePriorityEnabled = self:GetChecked() and true or false
        AscensionRaidRollsSoftRes.BroadcastCurrentState()
        UpdateItemDisplay()
        UpdateUI()
        Print("SR > MS > OS priority " .. (AscensionRaidRollsDB.reservePriorityEnabled and "enabled." or "disabled."))
    end)

    optionsFrame.reserveModeLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.reserveModeLabel:SetPoint("LEFT", optionsFrame.reserveModeCheck, "RIGHT", 3, 0)
    optionsFrame.reserveModeLabel:SetText("Use SR > MS > OS priority")

    optionsFrame.reserveLimitLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.reserveLimitLabel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 245, -196)
    optionsFrame.reserveLimitLabel:SetText("SR allowed")

    optionsFrame.reserveLimitEdit = CreateFrame("EditBox", nil, optionsFrame, "InputBoxTemplate")
    optionsFrame.reserveLimitEdit:SetWidth(35)
    optionsFrame.reserveLimitEdit:SetHeight(22)
    optionsFrame.reserveLimitEdit:SetPoint("LEFT", optionsFrame.reserveLimitLabel, "RIGHT", 6, 0)
    optionsFrame.reserveLimitEdit:SetAutoFocus(false)
    optionsFrame.reserveLimitEdit:SetMaxLetters(2)
    if optionsFrame.reserveLimitEdit.SetNumeric then optionsFrame.reserveLimitEdit:SetNumeric(true) end
    local function SaveSoftResLimit()
        local value = math.floor(tonumber(optionsFrame.reserveLimitEdit:GetText()) or tonumber(AscensionRaidRollsDB.softResLimit) or 2)
        value = math.max(1, math.min(10, value))
        AscensionRaidRollsDB.softResLimit = value
        optionsFrame.reserveLimitEdit:SetText(tostring(value))
    end
    optionsFrame.reserveLimitEdit:SetScript("OnEnterPressed", function(self) SaveSoftResLimit(); self:ClearFocus() end)
    optionsFrame.reserveLimitEdit:SetScript("OnEditFocusLost", SaveSoftResLimit)

    optionsFrame.reserveURLLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.reserveURLLabel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 30, -224)
    optionsFrame.reserveURLLabel:SetText("BisBeard URL")

    optionsFrame.reserveURLEdit = CreateFrame("EditBox", nil, optionsFrame)
    optionsFrame.reserveURLEdit:SetWidth(240)
    optionsFrame.reserveURLEdit:SetHeight(22)
    optionsFrame.reserveURLEdit:SetPoint("LEFT", optionsFrame.reserveURLLabel, "RIGHT", 8, 0)
    optionsFrame.reserveURLEdit:SetAutoFocus(false)
    optionsFrame.reserveURLEdit:SetMaxLetters(200)
    if optionsFrame.reserveURLEdit.SetFontObject and GameFontHighlightSmall then
        optionsFrame.reserveURLEdit:SetFontObject(GameFontHighlightSmall)
    end
    if optionsFrame.reserveURLEdit.SetTextInsets then
        optionsFrame.reserveURLEdit:SetTextInsets(6, 6, 0, 0)
    end
    optionsFrame.reserveURLEdit:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    optionsFrame.reserveURLEdit:SetBackdropColor(0.03, 0.03, 0.03, 0.92)
    optionsFrame.reserveURLEdit:SetBackdropBorderColor(0.45, 0.45, 0.45, 1.0)
    local function SaveSoftResURL()
        AscensionRaidRollsDB.softResURL = Trim(optionsFrame.reserveURLEdit:GetText() or "") or ""
        optionsFrame.reserveURLEdit:SetText(AscensionRaidRollsDB.softResURL)
    end
    optionsFrame.reserveURLEdit:SetScript("OnEnterPressed", function(self) SaveSoftResURL(); self:ClearFocus() end)
    optionsFrame.reserveURLEdit:SetScript("OnEditFocusLost", SaveSoftResURL)

    optionsFrame.reserveImportButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    optionsFrame.reserveImportButton:SetWidth(145)
    optionsFrame.reserveImportButton:SetHeight(22)
    optionsFrame.reserveImportButton:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 30, -258)
    optionsFrame.reserveImportButton:SetText("Import Reservations")
    optionsFrame.reserveImportButton:SetScript("OnClick", function()
        AscensionRaidRollsSoftRes.CreateImportFrame():Show()
    end)

    optionsFrame.reserveCheckButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    optionsFrame.reserveCheckButton:SetWidth(160)
    optionsFrame.reserveCheckButton:SetHeight(22)
    optionsFrame.reserveCheckButton:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -30, -258)
    optionsFrame.reserveCheckButton:SetText("Check Raid SoftRes")
    optionsFrame.reserveCheckButton:SetScript("OnClick", CheckMissingReservations)

    optionsFrame.reserveStatus = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.reserveStatus:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 30, -289)
    optionsFrame.reserveStatus:SetWidth(330)
    optionsFrame.reserveStatus:SetJustifyH("LEFT")
    optionsFrame.reserveStatus:SetText("No reservation list imported.")

    optionsFrame.reserveSeparator = optionsFrame:CreateTexture(nil, "ARTWORK")
    optionsFrame.reserveSeparator:SetTexture(1, 1, 1, 0.12)
    optionsFrame.reserveSeparator:SetHeight(1)
    optionsFrame.reserveSeparator:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -324)
    optionsFrame.reserveSeparator:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -24, -324)

    optionsFrame.lootTitle = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optionsFrame.lootTitle:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 25, -340)
    optionsFrame.lootTitle:SetText("Automatic Master Loot")

    optionsFrame.masterLooterLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.masterLooterLabel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 30, -373)
    optionsFrame.masterLooterLabel:SetText("Recipient")

    optionsFrame.masterLooterEdit = CreateFrame("EditBox", nil, optionsFrame)
    optionsFrame.masterLooterEdit:SetWidth(125)
    optionsFrame.masterLooterEdit:SetHeight(22)
    optionsFrame.masterLooterEdit:SetPoint("LEFT", optionsFrame.masterLooterLabel, "RIGHT", 10, 0)
    optionsFrame.masterLooterEdit:SetAutoFocus(false)
    optionsFrame.masterLooterEdit:SetMaxLetters(24)
    if optionsFrame.masterLooterEdit.SetFontObject and GameFontHighlightSmall then
        optionsFrame.masterLooterEdit:SetFontObject(GameFontHighlightSmall)
    end
    if optionsFrame.masterLooterEdit.SetTextInsets then
        optionsFrame.masterLooterEdit:SetTextInsets(6, 6, 0, 0)
    end
    if optionsFrame.masterLooterEdit.SetBackdrop then
        optionsFrame.masterLooterEdit:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        optionsFrame.masterLooterEdit:SetBackdropColor(0.03, 0.03, 0.03, 0.90)
        optionsFrame.masterLooterEdit:SetBackdropBorderColor(0.45, 0.45, 0.45, 1.0)
    end
    optionsFrame.masterLooterEdit:SetScript("OnEnterPressed", function(self)
        SaveMasterLooterSetting()
        self:ClearFocus()
    end)
    optionsFrame.masterLooterEdit:SetScript("OnEditFocusLost", function()
        SaveMasterLooterSetting()
    end)

    optionsFrame.autoLootCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    optionsFrame.autoLootCheck:SetWidth(24)
    optionsFrame.autoLootCheck:SetHeight(24)
    optionsFrame.autoLootCheck:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -409)
    optionsFrame.autoLootCheck:SetScript("OnClick", function(self)
        SetAutoMasterLootEnabled(self:GetChecked() and true or false)
    end)

    optionsFrame.autoLootLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.autoLootLabel:SetPoint("LEFT", optionsFrame.autoLootCheck, "RIGHT", 3, 0)
    optionsFrame.autoLootLabel:SetText("Auto Loot to ML")

    optionsFrame.muteWinnerCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    optionsFrame.muteWinnerCheck:SetWidth(24)
    optionsFrame.muteWinnerCheck:SetHeight(24)
    optionsFrame.muteWinnerCheck:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -441)
    optionsFrame.muteWinnerCheck:SetScript("OnClick", function(self)
        if IsInRaid() and (not CanControlRolls or not CanControlRolls()) then
            self:SetChecked(AscensionRaidRollsDB.muteWinnerAnnouncement == true)
            return
        end
        AscensionRaidRollsDB.muteWinnerAnnouncement = self:GetChecked() and true or false
        Print("winner announcement " .. (AscensionRaidRollsDB.muteWinnerAnnouncement and "muted." or "enabled."))
    end)

    optionsFrame.muteWinnerLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optionsFrame.muteWinnerLabel:SetPoint("LEFT", optionsFrame.muteWinnerCheck, "RIGHT", 3, 0)
    optionsFrame.muteWinnerLabel:SetText("Mute winner /rw announcement")

    -- Keep compatibility with the existing settings/control helpers while the
    -- actual widgets now live in the dedicated Options frame.
    mainFrame.masterLooterEdit = optionsFrame.masterLooterEdit
    mainFrame.masterLooterLabel = optionsFrame.masterLooterLabel
    mainFrame.autoLootCheck = optionsFrame.autoLootCheck
    mainFrame.autoLootLabel = optionsFrame.autoLootLabel

    optionsFrame:SetScript("OnShow", function()
        UpdateOptionsControlState()
        optionsFrame.masterLooterEdit:SetText(NormalizeMasterLooterSetting(AscensionRaidRollsDB.masterLooter or "@ME"))
        optionsFrame.autoLootCheck:SetChecked(AscensionRaidRollsDB.autoMasterLoot == true)
        optionsFrame.muteWinnerCheck:SetChecked(AscensionRaidRollsDB.muteWinnerAnnouncement == true)
        optionsFrame.reserveModeCheck:SetChecked(AscensionRaidRollsSoftRes.IsPriorityEnabled())
        optionsFrame.reserveLimitEdit:SetText(tostring(AscensionRaidRollsDB.softResLimit or 2))
        optionsFrame.reserveURLEdit:SetText(AscensionRaidRollsDB.softResURL or "")
    end)
    optionsFrame:Hide()
end

local function CreateUI()
    mainFrame = CreateFrame("Frame", "AscensionRaidRollsFrame", UIParent)
    mainFrame:SetWidth(600)
    mainFrame:SetHeight(565)
    mainFrame:SetFrameStrata("DIALOG")
    mainFrame:SetClampedToScreen(true)
    mainFrame:EnableMouse(true)
    mainFrame:SetMovable(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveFramePosition()
    end)

    mainFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    mainFrame.title:SetPoint("TOP", mainFrame, "TOP", 0, -17)
    mainFrame.title:SetText("Raid Rolls")

    mainFrame.subtitle = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainFrame.subtitle:SetPoint("TOP", mainFrame.title, "BOTTOM", 0, -5)
    mainFrame.subtitle:SetText("First roll counts  •  Click any roll to select the winner")

    mainFrame.itemSlot = CreateFrame("Button", nil, mainFrame)
    mainFrame.itemSlot:SetWidth(42)
    mainFrame.itemSlot:SetHeight(42)
    mainFrame.itemSlot:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 24, -57)
    mainFrame.itemSlot:EnableMouse(true)
    mainFrame.itemSlot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mainFrame.itemSlot:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    mainFrame.itemSlot:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
    mainFrame.itemSlot:SetBackdropBorderColor(0.5, 0.5, 0.5, 1.0)

    mainFrame.itemIcon = mainFrame.itemSlot:CreateTexture(nil, "ARTWORK")
    mainFrame.itemIcon:SetPoint("TOPLEFT", mainFrame.itemSlot, "TOPLEFT", 4, -4)
    mainFrame.itemIcon:SetPoint("BOTTOMRIGHT", mainFrame.itemSlot, "BOTTOMRIGHT", -4, 4)
    mainFrame.itemIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    mainFrame.itemText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mainFrame.itemText:SetPoint("TOPLEFT", mainFrame.itemSlot, "TOPRIGHT", 8, -2)
    mainFrame.itemText:SetWidth(245)
    mainFrame.itemText:SetJustifyH("LEFT")
    mainFrame.itemText:SetText("|cffaaaaaaDrop an item here|r")

    mainFrame.itemHint = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainFrame.itemHint:SetPoint("TOPLEFT", mainFrame.itemText, "BOTTOMLEFT", 0, -5)
    mainFrame.itemHint:SetWidth(245)
    mainFrame.itemHint:SetJustifyH("LEFT")
    mainFrame.itemHint:SetText("Drag here or Shift + Right-click an item in your bags")
    mainFrame.itemHint:SetTextColor(0.65, 0.65, 0.65)

    mainFrame.itemSlot:SetScript("OnReceiveDrag", function()
        CaptureCursorItem()
    end)
    mainFrame.itemSlot:SetScript("OnClick", function(self, button)
        if not CanControlRolls or not CanControlRolls() then
            Print("only the current Master Looter can change the roll item.")
            return
        end

        if button == "RightButton" then
            ClearCurrentItem()
        else
            CaptureCursorItem()
        end
    end)
    mainFrame.itemSlot:SetScript("OnEnter", function(self)
        if not GameTooltip then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if currentItemLink then
            GameTooltip:SetHyperlink(currentItemLink)
        else
            GameTooltip:SetText("Drop an item here")
            GameTooltip:AddLine("Drag an item here, or Shift + Right-click it in your bags.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    mainFrame.itemSlot:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    mainFrame.durationLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainFrame.durationLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 327, -57)
    mainFrame.durationLabel:SetText("Duration")

    mainFrame.durationEdit = CreateFrame("EditBox", nil, mainFrame, "InputBoxTemplate")
    mainFrame.durationEdit:SetWidth(42)
    mainFrame.durationEdit:SetHeight(24)
    mainFrame.durationEdit:SetPoint("LEFT", mainFrame.durationLabel, "RIGHT", 7, 0)
    mainFrame.durationEdit:SetAutoFocus(false)
    if mainFrame.durationEdit.SetNumeric then
        mainFrame.durationEdit:SetNumeric(true)
    end
    mainFrame.durationEdit:SetMaxLetters(3)
    mainFrame.durationEdit:SetText(tostring(AscensionRaidRollsDB.rollDuration or DEFAULT_ROLL_DURATION))
    mainFrame.durationEdit:SetScript("OnEnterPressed", function(self)
        GetConfiguredDuration()
        self:ClearFocus()
    end)
    mainFrame.durationEdit:SetScript("OnEditFocusLost", function()
        GetConfiguredDuration()
    end)

    mainFrame.durationSec = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainFrame.durationSec:SetPoint("LEFT", mainFrame.durationEdit, "RIGHT", 4, 0)
    mainFrame.durationSec:SetText("sec")

    mainFrame.startRollButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.startRollButton:SetWidth(92)
    mainFrame.startRollButton:SetHeight(24)
    mainFrame.startRollButton:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -20, -86)
    mainFrame.startRollButton:SetText("Start Roll")
    mainFrame.startRollButton:SetScript("OnClick", function()
        StartTimedRoll()
    end)


    mainFrame.timerBar = CreateFrame("StatusBar", nil, mainFrame)
    mainFrame.timerBar:SetWidth(365)
    mainFrame.timerBar:SetHeight(18)
    mainFrame.timerBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 24, -106)
    mainFrame.timerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    mainFrame.timerBar:SetMinMaxValues(0, 1)
    mainFrame.timerBar:SetValue(0)
    mainFrame.timerBar:SetStatusBarColor(0.20, 0.75, 0.25)

    mainFrame.timerBarBg = mainFrame.timerBar:CreateTexture(nil, "BACKGROUND")
    mainFrame.timerBarBg:SetAllPoints(mainFrame.timerBar)
    mainFrame.timerBarBg:SetTexture(0.08, 0.08, 0.08, 0.85)

    mainFrame.timerText = mainFrame.timerBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainFrame.timerText:SetPoint("CENTER", mainFrame.timerBar, "CENTER", 0, 0)
    mainFrame.timerText:SetText("Timer ready")

    -- Keep Tie Break close to the roll controls instead of in the footer.
    -- It becomes available only when the selected row belongs to a valid tie.
    mainFrame.tieButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.tieButton:SetWidth(92)
    mainFrame.tieButton:SetHeight(20)
    mainFrame.tieButton:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -20, -113)
    mainFrame.tieButton:SetText("Tie Break")
    mainFrame.tieButton:SetScript("OnClick", function()
        StartTieBreak()
    end)
    SetButtonEnabled(mainFrame.tieButton, false)

    mainFrame.optionsButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.optionsButton:SetWidth(92)
    mainFrame.optionsButton:SetHeight(22)
    mainFrame.optionsButton:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 24, -132)
    mainFrame.optionsButton:SetText("Options")
    mainFrame.optionsButton:SetScript("OnClick", function()
        if optionsFrame:IsShown() then
            optionsFrame:Hide()
        else
            optionsFrame:Show()
        end
    end)

    mainFrame.timersButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.timersButton:SetWidth(92)
    mainFrame.timersButton:SetHeight(22)
    mainFrame.timersButton:SetPoint("LEFT", mainFrame.optionsButton, "RIGHT", 6, 0)
    mainFrame.timersButton:SetText("Timers")
    mainFrame.timersButton:SetScript("OnClick", function()
        if AscensionRaidRolls.TradeTimers and AscensionRaidRolls.TradeTimers.Toggle then
            AscensionRaidRolls.TradeTimers.Toggle()
        end
    end)

    CreateOptionsFrame()

    mainFrame.msCount = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mainFrame.msCount:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 24, -163)
    mainFrame.msCount:SetTextColor(1.0, 0.78, 0.20)
    mainFrame.msCount:SetText("MS  (1-100)")

    mainFrame.osCount = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mainFrame.osCount:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 316, -163)
    mainFrame.osCount:SetTextColor(0.35, 0.72, 1.0)
    mainFrame.osCount:SetText("OS  (1-99)")

    msPanel = CreateRollPanel(mainFrame, "TOPLEFT", 18)
    osPanel = CreateRollPanel(mainFrame, "TOPLEFT", 310)

    mainFrame.separator = mainFrame:CreateTexture(nil, "ARTWORK")
    mainFrame.separator:SetTexture(1, 1, 1, 0.08)
    mainFrame.separator:SetWidth(1)
    mainFrame.separator:SetPoint("TOP", mainFrame, "TOP", 0, -181)
    mainFrame.separator:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 76)

    mainFrame.winnerText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mainFrame.winnerText:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 55)
    mainFrame.winnerText:SetWidth(470)
    mainFrame.winnerText:SetJustifyH("CENTER")
    mainFrame.winnerText:SetText("Selected: |cff888888click a roll to choose a winner|r")

    -- Keep the four footer action buttons uniform and use the full width.
    -- Tie Break now lives directly under Start Roll.
    local footerButtonWidth = 135
    local footerButtonHeight = 24
    local footerButtonGap = 6

    mainFrame.clearButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.clearButton:SetWidth(footerButtonWidth)
    mainFrame.clearButton:SetHeight(footerButtonHeight)
    mainFrame.clearButton:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 18, 18)
    mainFrame.clearButton:SetText("Reset")
    mainFrame.clearButton:SetScript("OnClick", function()
        ResetRollSessionByController()
    end)

    mainFrame.msRollButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.msRollButton:SetWidth(footerButtonWidth)
    mainFrame.msRollButton:SetHeight(footerButtonHeight)
    mainFrame.msRollButton:SetPoint("LEFT", mainFrame.clearButton, "RIGHT", footerButtonGap, 0)
    mainFrame.msRollButton:SetText("Roll MS")
    mainFrame.msRollButton:SetScript("OnClick", function()
        ExecutePlayerRoll(100)
    end)

    mainFrame.osRollButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.osRollButton:SetWidth(footerButtonWidth)
    mainFrame.osRollButton:SetHeight(footerButtonHeight)
    mainFrame.osRollButton:SetPoint("LEFT", mainFrame.msRollButton, "RIGHT", footerButtonGap, 0)
    mainFrame.osRollButton:SetText("Roll OS")
    mainFrame.osRollButton:SetScript("OnClick", function()
        ExecutePlayerRoll(99)
    end)

    mainFrame.tradeButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    mainFrame.tradeButton:SetWidth(footerButtonWidth)
    mainFrame.tradeButton:SetHeight(footerButtonHeight)
    mainFrame.tradeButton:SetPoint("LEFT", mainFrame.osRollButton, "RIGHT", footerButtonGap, 0)
    mainFrame.tradeButton:SetText("Trade")
    mainFrame.tradeButton:SetScript("OnClick", function()
        TradeWinner()
    end)

    mainFrame.closeButton = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    mainFrame.closeButton:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -4, -4)

    local point = AscensionRaidRollsDB.point or "CENTER"
    local relativePoint = AscensionRaidRollsDB.relativePoint or "CENTER"
    local x = AscensionRaidRollsDB.x or 0
    local y = AscensionRaidRollsDB.y or 0
    mainFrame:SetPoint(point, UIParent, relativePoint, x, y)

    mainFrame:SetScript("OnShow", function()
        AscensionRaidRollsDB.shown = true
    end)
    mainFrame:SetScript("OnHide", function()
        AscensionRaidRollsDB.shown = false
    end)

    if AscensionRaidRollsDB.shown == false then
        mainFrame:Hide()
    else
        mainFrame:Show()
    end

    UpdateItemDisplay()
    CancelRollSession()
    GetConfiguredDuration()
    UpdateUI()
end

local function AddTestRolls()
    ClearRolls()
    AddRoll("Arthas", 97, 1, 100, true)
    AddRoll("Jaina", 84, 1, 100, true)
    AddRoll("Anduin", 84, 1, 100, true)
    AddRoll("Thrall", 42, 1, 100, true)
    AddRoll("Valeera", 99, 1, 99, true)
    AddRoll("Uther", 73, 1, 99, true)
    AddRoll("Malfurion", 18, 1, 99, true)
    AddRoll("Arthas", 100, 1, 100, true)
    AddRoll("Jaina", 98, 1, 99, true)
end

local function HandleSlashCommand(message)
    message = Trim(message or "") or ""
    local lower = string.lower(message)

    if lower == "" or lower == "toggle" then
        ToggleMainFrame()
    elseif lower == "show" then
        mainFrame:Show()
    elseif lower == "hide" then
        mainFrame:Hide()
    elseif lower == "roll" or lower == "rollui" or lower == "panel" then
        mainFrame:Show()
    elseif lower == "ms" then
        ExecutePlayerRoll(100)
    elseif lower == "os" then
        ExecutePlayerRoll(99)
    elseif lower == "clear" or lower == "reset" then
        local resetOK, resetMode = ResetRollSessionByController()
        if resetOK then
            if resetMode == "local" then
                Print("local roll log cleared.")
            else
                Print("shared roll list and active timer cleared.")
            end
        end
    elseif lower == "test" then
        AddTestRolls()
        mainFrame:Show()
        Print("test data loaded. Jaina and Anduin are tied at 84 MS; select either row to test Tie Break.")
    elseif lower == "announce" then
        AnnounceWinner()
    elseif lower == "tie" or lower == "tiebreak" then
        StartTieBreak()
    elseif lower == "trade" then
        TradeWinner()
    elseif lower:match("^ml%s+.+$") then
        local value = Trim(message:match("^%S+%s+(.+)$") or "")
        value = NormalizeMasterLooterSetting(value)
        AscensionRaidRollsDB.masterLooter = value
        if mainFrame and mainFrame.masterLooterEdit then
            mainFrame.masterLooterEdit:SetText(value)
        end
        Print("Master Looter recipient set to " .. tostring(ResolveMasterLooterTarget()) .. ".")
    elseif lower == "autoloot on" then
        SetAutoMasterLootEnabled(true)
    elseif lower == "autoloot off" then
        SetAutoMasterLootEnabled(false)
    elseif lower == "start" then
        StartTimedRoll()
    elseif lower:match("^duration%s+%d+$") then
        if not CanControlRolls or not CanControlRolls() then
            Print("only the current Master Looter can change the shared roll duration.")
            return
        end
        local value = tonumber(lower:match("^duration%s+(%d+)$"))
        if value then
            AscensionRaidRollsDB.rollDuration = value
            GetConfiguredDuration()
            Print("roll duration set to " .. tostring(AscensionRaidRollsDB.rollDuration) .. " seconds.")
        end
    elseif lower == "version" or lower == "ver" then
        Print("version " .. tostring(ADDON_VERSION) .. ". Latest version seen from other ARR users this session: " .. tostring(latestSeenVersion) .. ".")
        BroadcastVersion()
    elseif lower == "options" then
        if optionsFrame:IsShown() then
            optionsFrame:Hide()
        else
            optionsFrame:Show()
        end
    elseif lower == "lootreset" then
        ClearLootHistory()
    elseif lower == "debug" then
        Print("RANDOM_ROLL_RESULT = " .. tostring(RANDOM_ROLL_RESULT))
        Print("pattern = " .. tostring(rollPattern))
        Print("raid members = " .. tostring(GetNumRaidMembers and GetNumRaidMembers() or 0))
        Print("item = " .. tostring(currentItemLink))
        Print("timer active = " .. tostring(rollTimerActive) .. ", session open = " .. tostring(rollSessionOpen))
        Print("sync session = " .. tostring(syncSessionID) .. ", owner = " .. tostring(syncOwner) .. ", controller = " .. tostring(CanControlRolls and CanControlRolls() or false))
        local actualMaster, lootMethod = nil, nil
        if GetActualMasterLooterName then
            actualMaster, lootMethod = GetActualMasterLooterName()
        end
        Print("active Master Looter = " .. tostring(actualMaster) .. ", loot method = " .. tostring(lootMethod))
        Print("Master Loot recipient = " .. tostring(AscensionRaidRollsDB.masterLooter or "@ME") .. ", auto = " .. tostring(AscensionRaidRollsDB.autoMasterLoot == true))
        local winner = GetWinner()
        if winner then
            Print("top valid roll = " .. winner.name .. " / " .. winner.roll .. " / " .. winner.type)
        else
            Print("top valid roll = none")
        end
        Print("top winner slots = " .. tostring(currentTopRolls or 1))
        if currentItemLink then
            local scannedTop = CountTradeableCopies(currentItemLink, currentItemID, true)
            Print("Top X rescan result = " .. tostring(scannedTop))
        end
        Print("tie-break active = " .. tostring(tieBreakActive) .. ", type = " .. tostring(tieBreakType) .. ", round = " .. tostring(tieBreakRound))
        if selectedRoll then
            Print("selected = " .. selectedRoll.name .. " / " .. selectedRoll.roll .. " / " .. selectedRoll.type)
        else
            Print("selected = none")
        end
    else
        Print("commands: /rr, /rr show, /rr hide, /rr options, /rr ms, /rr os, /rr clear, /rr lootreset, /rr test, /rr start, /rr duration <sec>, /rr announce, /rr tie, /rr trade, /rr ml <@ME|player>, /rr autoloot <on|off>, /rr version, /rr debug")
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("TRADE_CLOSED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_SLOT_CLEARED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("LOOT_BIND_CONFIRM")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= ADDON_NAME then
            return
        end

        AscensionRaidRollsDB = AscensionRaidRollsDB or {}
        if AscensionRaidRollsDB.masterLooter == nil then
            AscensionRaidRollsDB.masterLooter = "@ME"
        end
        if AscensionRaidRollsDB.autoMasterLoot == nil then
            AscensionRaidRollsDB.autoMasterLoot = false
        end
        if AscensionRaidRollsDB.muteWinnerAnnouncement == nil then
            AscensionRaidRollsDB.muteWinnerAnnouncement = false
        end
        if AscensionRaidRollsDB.msosPlusOneEnabled == nil then
            AscensionRaidRollsDB.msosPlusOneEnabled = false
        end
        if AscensionRaidRollsDB.reservePriorityEnabled == nil then
            AscensionRaidRollsDB.reservePriorityEnabled = false
        end
        if AscensionRaidRollsDB.softResLimit == nil then
            AscensionRaidRollsDB.softResLimit = 2
        end
        if AscensionRaidRollsDB.softResURL == nil then
            AscensionRaidRollsDB.softResURL = ""
        end
        if type(AscensionRaidRollsDB.reserveData) ~= "table" then
            AscensionRaidRollsDB.reserveData = { metadata = {}, roster = {}, byItem = {}, hardItems = {} }
        end
        if type(AscensionRaidRollsDB.lootHistory) ~= "table" then
            AscensionRaidRollsDB.lootHistory = { MS = {}, OS = {} }
        elseif type(AscensionRaidRollsDB.lootHistory.MS) ~= "table" or type(AscensionRaidRollsDB.lootHistory.OS) ~= "table" then
            local legacyHistory = AscensionRaidRollsDB.lootHistory
            local migratedHistory = { MS = {}, OS = {} }
            local playerKey, count
            for playerKey, count in pairs(legacyHistory) do
                if type(count) == "number" and count > 0 then
                    migratedHistory.MS[playerKey] = count
                end
            end
            AscensionRaidRollsDB.lootHistory = migratedHistory
        end

        -- Some 3.3.5-derived clients expose prefix registration while others
        -- deliver CHAT_MSG_ADDON without it. Use it when available only.
        if RegisterAddonMessagePrefix then
            pcall(RegisterAddonMessagePrefix, SYNC_PREFIX)
        end

        rollPattern, rollCaptureOrder = BuildRollPattern()
        RefreshRaidMembers()
        CreateUI()
        CreateMinimapButton()
        InstallBagItemShortcut()
        AscensionRaidRollsSoftRes.InstallTooltipHooks()
        UpdateControlState()

        SLASH_ASCENSIONRAIDROLLS1 = "/rr"
        SLASH_ASCENSIONRAIDROLLS2 = "/raidrolls"
        SlashCmdList["ASCENSIONRAIDROLLS"] = HandleSlashCommand

        Print("loaded. Shared raid-roll sync is enabled, with local fallback roll tracking when the Master Looter does not use ARR.")

        BroadcastVersion()

        if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 and not (CanControlRolls and CanControlRolls()) then
            RequestSyncState()
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        HandleAddonSync(prefix, message, channel, sender)

    elseif event == "RAID_ROSTER_UPDATE" then
        RefreshRaidMembers()
        ClearRemoteRaidStateOutsideRaid()
        UpdateUI()
        BroadcastVersion()
        if not rollSessionStarted and not syncStateRequested and not (CanControlRolls and CanControlRolls()) then
            RequestSyncState()
        end

    elseif event == "GUILD_ROSTER_UPDATE" then
        BroadcastVersion()

    elseif event == "PARTY_LOOT_METHOD_CHANGED" then
        RefreshRaidMembers()
        UpdateUI()
        if not (CanControlRolls and CanControlRolls()) and not syncStateRequested then
            RequestSyncState()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        RefreshRaidMembers()
        ClearRemoteRaidStateOutsideRaid()
        UpdateUI()
        BroadcastVersion()
        if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 and not rollSessionStarted and not syncStateRequested and not (CanControlRolls and CanControlRolls()) then
            RequestSyncState()
        end

    elseif event == "TRADE_SHOW" then
        PlacePendingTradeItem()
    elseif event == "TRADE_CLOSED" then
        ClearPendingTradeItem()
    elseif event == "LOOT_OPENED" then
        StartAutoMasterLoot()
    elseif event == "LOOT_SLOT_CLEARED" then
        HandleAutoMasterLootSlotCleared()
    elseif event == "LOOT_BIND_CONFIRM" then
        local slot = ...
        HandleAutoMasterLootBindConfirm(slot)
    elseif event == "LOOT_CLOSED" then
        StopAutoMasterLoot()
    elseif event == "CHAT_MSG_SYSTEM" then
        if not mainFrame then
            return
        end

        local message = ...
        if type(message) ~= "string" then
            return
        end

        -- During any remote synchronized session, the Master Looter is
        -- authoritative. Viewers ignore their local CHAT_MSG_SYSTEM copy and
        -- only display ROLL messages accepted by the host. This remains true
        -- after the timer closes, preventing late local rolls from appearing.
        -- With no remote session (for example when the ML does not use ARR),
        -- the viewer falls back to local roll tracking instead.
        if IsRemoteSyncedSession and IsRemoteSyncedSession() then
            return
        end

        local playerName, roll, minimum, maximum = ParseRollMessage(message)
        if playerName and roll and minimum and maximum then
            AddRoll(playerName, roll, minimum, maximum, false)
        end
    end
end)


eventFrame:SetScript("OnUpdate", function(self, elapsed)
    if rollTimerActive then
        timerAccumulator = timerAccumulator + (elapsed or 0)
        if timerAccumulator >= 0.05 then
            timerAccumulator = 0
            UpdateRollTimer()
        end
    end

    if autoMasterLootProcessing then
        UpdateAutoMasterLoot(elapsed)
    end
end)
    rollType = rollType == "OS" and "OS" or "MS"
