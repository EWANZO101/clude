--[[
    lib.utils
    General-purpose helpers usable on both client and server.
    Access as: lib.table.*, lib.string.*, lib.math.*, lib.print(...)
]]

lib = lib or {}

local RESOURCE_NAME = GetCurrentResourceName()

-- ─────────────────────────────────────────────
-- Debug print (only prints when Config.Debug is true, config.lua)
-- ─────────────────────────────────────────────
function lib.print(...)
    local debugEnabled = (Config and Config.Debug) or (GetConvar('rps_lib:debug', 'false') == 'true')
    if not debugEnabled then return end
    local args = { ... }
    local parts = {}
    for i = 1, select('#', ...) do
        parts[i] = tostring(args[i])
    end
    print(('[^3%s^7] %s'):format(RESOURCE_NAME, table.concat(parts, ' ')))
end

-- ─────────────────────────────────────────────
-- Boxed startup banner, shared by framework/init.lua and
-- integrations/garages/init.lua so both print the same style.
-- ─────────────────────────────────────────────

--- Prints a boxed banner. `title` is the header line, `rows` is an array of
--- { label, value } pairs rendered as aligned "label : value" lines.
function lib.printBanner(title, rows)
    local labelWidth = 0
    for _, row in ipairs(rows) do
        labelWidth = math.max(labelWidth, #row[1])
    end

    local width = 42
    print(('^5%s^7'):format('╔' .. ('═'):rep(width) .. '╗'))
    print(('^5║^7 %-' .. width - 1 .. 's^5║^7'):format(title))
    print(('^5╠%s╣^7'):format(('═'):rep(width)))
    for _, row in ipairs(rows) do
        local text = (' %-' .. labelWidth .. 's ^7: ^3%s^7'):format(row[1], row[2])
        local visibleLen = labelWidth + #row[2] + 4
        print(('^5║^7%s%s^5║^7'):format(text, (' '):rep(math.max(0, width - visibleLen))))
    end
    print(('^5%s^7'):format('╚' .. ('═'):rep(width) .. '╝'))
end

-- ─────────────────────────────────────────────
-- Table helpers
-- ─────────────────────────────────────────────
lib.table = {}

--- Deep copies a table (handles nested tables, ignores metatables).
function lib.table.deepcopy(tbl)
    if type(tbl) ~= 'table' then return tbl end
    local result = {}
    for k, v in pairs(tbl) do
        if type(v) == 'table' then
            result[k] = lib.table.deepcopy(v)
        else
            result[k] = v
        end
    end
    return result
end

--- Returns true if `value` exists in `tbl` (array-style search).
function lib.table.contains(tbl, value)
    for _, v in pairs(tbl) do
        if v == value then return true end
    end
    return false
end

--- Returns the number of keys in a table (works for non-sequential tables too).
function lib.table.count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

--- Merges `source` into `target`, overwriting existing keys.
function lib.table.merge(target, source)
    for k, v in pairs(source) do
        target[k] = v
    end
    return target
end

--- Removes all keys from a table in place.
function lib.table.wipe(tbl)
    for k in pairs(tbl) do
        tbl[k] = nil
    end
end

-- ─────────────────────────────────────────────
-- String helpers
-- ─────────────────────────────────────────────
lib.string = {}

--- Splits a string by a separator. Returns an array of parts.
--- With no `sep`, splits on whitespace (Lua's '%s' pattern class). A given
--- `sep` is treated as a literal character (or set of characters), not a
--- Lua pattern — magic characters like '.', '%', '-' are escaped internally.
function lib.string.split(str, sep)
    local charSet = sep and (sep:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')) or '%s'
    local parts = {}
    for part in string.gmatch(str, '([^' .. charSet .. ']+)') do
        parts[#parts + 1] = part
    end
    return parts
end

--- Trims leading/trailing whitespace.
function lib.string.trim(str)
    return str:match('^%s*(.-)%s*$')
end

-- Seeded once at module load rather than per-call (reseeding on every call
-- can produce repeated/low-entropy sequences when called in a tight loop).
math.randomseed(GetGameTimer() + (GetInstanceId and GetInstanceId() or 0))

--- Generates a random alphanumeric string of a given length.
function lib.string.random(length)
    length = length or 8
    local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    local result = {}
    for i = 1, length do
        local idx = math.random(1, #chars)
        result[i] = chars:sub(idx, idx)
    end
    return table.concat(result)
end

-- ─────────────────────────────────────────────
-- Math helpers
-- ─────────────────────────────────────────────
lib.math = {}

function lib.math.round(value, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(value * mult + 0.5) / mult
end

function lib.math.clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- Distance between two vector3-like tables {x=,y=,z=} or vector3 values.
function lib.math.distance(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end
