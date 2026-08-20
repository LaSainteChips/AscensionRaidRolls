-- AscensionRaidRolls - BisBeard Base64 and JSON codecs
-- Pure Lua 5.1 module with no UI dependency.
-- WoW 3.3.5a has no native Base64 or JSON library, so the importer keeps small
-- self-contained decoders and validates the resulting reserve structure.
function AscensionRaidRollsSoftRes.DecodeBase64(input)
    if type(input) ~= "string" then
        return nil, "the export is not text"
    end

    input = input:gsub("%s+", ""):gsub("-", "+"):gsub("_", "/")
    if input == "" then
        return nil, "paste a Base64 export first"
    end
    if #input > 100000 then
        return nil, "the export is too large"
    end
    if (#input % 4) ~= 0 then
        return nil, "invalid Base64 length"
    end

    local output = {}
    local i
    for i = 1, #input, 4 do
        local c1 = input:sub(i, i)
        local c2 = input:sub(i + 1, i + 1)
        local c3 = input:sub(i + 2, i + 2)
        local c4 = input:sub(i + 3, i + 3)
        local p1 = AscensionRaidRollsSoftRes.BASE64_ALPHABET:find(c1, 1, true)
        local p2 = AscensionRaidRollsSoftRes.BASE64_ALPHABET:find(c2, 1, true)
        local p3 = c3 == "=" and 1 or AscensionRaidRollsSoftRes.BASE64_ALPHABET:find(c3, 1, true)
        local p4 = c4 == "=" and 1 or AscensionRaidRollsSoftRes.BASE64_ALPHABET:find(c4, 1, true)
        if not p1 or not p2 or not p3 or not p4 then
            return nil, "invalid Base64 character"
        end

        local n1 = p1 - 1
        local n2 = p2 - 1
        local n3 = p3 - 1
        local n4 = p4 - 1
        output[#output + 1] = string.char((n1 * 4) + math.floor(n2 / 16))
        if c3 ~= "=" then
            output[#output + 1] = string.char(((n2 % 16) * 16) + math.floor(n3 / 4))
        end
        if c4 ~= "=" then
            output[#output + 1] = string.char(((n3 % 4) * 64) + n4)
        end
    end

    return table.concat(output)
end

function AscensionRaidRollsSoftRes.DecodeJSON(text)
    if type(text) ~= "string" or #text > 75000 then
        return nil, "decoded JSON is missing or too large"
    end

    local position = 1
    local length = #text
    local parseValue

    local function SkipWhitespace()
        while position <= length and text:sub(position, position):match("%s") do
            position = position + 1
        end
    end

    local function ParseString()
        if text:sub(position, position) ~= '"' then
            error("expected JSON string")
        end
        position = position + 1
        local parts = {}
        while position <= length do
            local char = text:sub(position, position)
            if char == '"' then
                position = position + 1
                return table.concat(parts)
            elseif char == "\\" then
                position = position + 1
                local escaped = text:sub(position, position)
                local replacements = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if escaped == "u" then
                    local hex = text:sub(position + 1, position + 4)
                    local code = tonumber(hex, 16)
                    if not code then error("invalid JSON unicode escape") end
                    parts[#parts + 1] = code >= 32 and code <= 126 and string.char(code) or "?"
                    position = position + 4
                elseif replacements[escaped] then
                    parts[#parts + 1] = replacements[escaped]
                else
                    error("invalid JSON escape")
                end
                position = position + 1
            else
                parts[#parts + 1] = char
                position = position + 1
            end
        end
        error("unterminated JSON string")
    end

    local function ParseNumber()
        local startPosition = position
        while position <= length and text:sub(position, position):match("[%d%+%-%.eE]") do
            position = position + 1
        end
        local value = tonumber(text:sub(startPosition, position - 1))
        if value == nil then error("invalid JSON number") end
        return value
    end

    local function ParseArray()
        local result = {}
        position = position + 1
        SkipWhitespace()
        if text:sub(position, position) == "]" then
            position = position + 1
            return result
        end
        while position <= length do
            result[#result + 1] = parseValue()
            SkipWhitespace()
            local char = text:sub(position, position)
            if char == "]" then
                position = position + 1
                return result
            elseif char ~= "," then
                error("expected ',' or ']' in JSON array")
            end
            position = position + 1
            SkipWhitespace()
        end
        error("unterminated JSON array")
    end

    local function ParseObject()
        local result = {}
        position = position + 1
        SkipWhitespace()
        if text:sub(position, position) == "}" then
            position = position + 1
            return result
        end
        while position <= length do
            local key = ParseString()
            SkipWhitespace()
            if text:sub(position, position) ~= ":" then error("expected ':' in JSON object") end
            position = position + 1
            SkipWhitespace()
            result[key] = parseValue()
            SkipWhitespace()
            local char = text:sub(position, position)
            if char == "}" then
                position = position + 1
                return result
            elseif char ~= "," then
                error("expected ',' or '}' in JSON object")
            end
            position = position + 1
            SkipWhitespace()
        end
        error("unterminated JSON object")
    end

    parseValue = function()
        SkipWhitespace()
        local char = text:sub(position, position)
        if char == '"' then return ParseString() end
        if char == "{" then return ParseObject() end
        if char == "[" then return ParseArray() end
        if char == "-" or char:match("%d") then return ParseNumber() end
        if text:sub(position, position + 3) == "true" then position = position + 4 return true end
        if text:sub(position, position + 4) == "false" then position = position + 5 return false end
        if text:sub(position, position + 3) == "null" then position = position + 4 return false end
        error("unsupported JSON value")
    end

    local ok, result = pcall(parseValue)
    if not ok then
        return nil, tostring(result):gsub("^.-:%d+:%s*", "")
    end
    SkipWhitespace()
    if position <= length then
        return nil, "unexpected text after JSON data"
    end
    return result
end
