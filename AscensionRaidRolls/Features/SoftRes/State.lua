-- SoftRes synchronization state shared with the main runtime.
AscensionRaidRollsSoftRes.BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
AscensionRaidRollsSoftRes.syncedPriorityEnabled = false
AscensionRaidRollsSoftRes.syncedPlayers = {}
AscensionRaidRollsSoftRes.syncedHardReserve = false

local function AddReservationsToTooltip(tooltip)
    if not tooltip or not tooltip.GetItem or not AscensionRaidRollsSoftRes.GetTooltipReservations then
        return
    end

    local _, itemLink = tooltip:GetItem()
    local itemID = itemLink and tonumber(itemLink:match("item:(%d+)")) or nil
    if not itemID then
        return
    end

    local reservations = AscensionRaidRollsSoftRes.GetTooltipReservations(itemID)
    if not reservations or #reservations == 0 then
        return
    end

    tooltip:AddLine(" ")
    tooltip:AddLine("SoftRes", 1.0, 0.82, 0.0)
    local i
    for i = 1, #reservations do
        local entry = reservations[i]
        tooltip:AddLine(tostring(entry.name) .. " - " .. tostring(entry.count) .. "xSR", 0.75, 0.45, 1.0)
    end
end

function AscensionRaidRollsSoftRes.InstallTooltipHooks()
    if AscensionRaidRollsSoftRes.tooltipHooksInstalled then
        return
    end
    AscensionRaidRollsSoftRes.tooltipHooksInstalled = true

    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", AddReservationsToTooltip)
    end
    if ItemRefTooltip and ItemRefTooltip.HookScript then
        ItemRefTooltip:HookScript("OnTooltipSetItem", AddReservationsToTooltip)
    end
end
