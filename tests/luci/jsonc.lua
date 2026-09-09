local M = require "tests.mock_json"

function M.stringify(obj)
    local t = type(obj)
    if t == "number" or t == "boolean" then
        return tostring(obj)
    elseif t == "string" then
        return string.format("%q", obj)
    elseif t == "table" then
        local is_array = true
        local n = 0
        for k, v in pairs(obj) do
            n = n + 1
            if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
                is_array = false
                break
            end
        end
        if is_array and n > 0 and obj[1] ~= nil then
            local parts = {}
            for i = 1, #obj do
                parts[#parts + 1] = M.stringify(obj[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(obj) do
                parts[#parts + 1] = string.format("%q:%s", tostring(k), M.stringify(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return "null"
    end
end

return M
