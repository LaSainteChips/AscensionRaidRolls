-- Version comparison is independent from the raid-roll runtime.
AscensionRaidRolls.Version = AscensionRaidRolls.Version or {}

function AscensionRaidRolls.Version.Parse(version)
    if type(version) ~= "string" then
        return 0, 0, 0
    end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)")
    return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

function AscensionRaidRolls.Version.IsNewer(candidate, current)
    local c1, c2, c3 = AscensionRaidRolls.Version.Parse(candidate)
    local a1, a2, a3 = AscensionRaidRolls.Version.Parse(current)
    if c1 ~= a1 then return c1 > a1 end
    if c2 ~= a2 then return c2 > a2 end
    return c3 > a3
end
