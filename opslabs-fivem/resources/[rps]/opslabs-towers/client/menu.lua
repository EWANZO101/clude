-- Menu navigation for every ox_lib context menu in this resource.
-- ox_lib's Back runs the menu's onBack and then opens the menu named in `menu`; when those disagree you land
-- somewhere unexpected. Here every submenu remembers the menu it was opened from, and Back goes exactly there
-- (rebuilt fresh when it was opened from an arrow item, so counts and lists are up to date).
-- Menus opened by a command or a key (no menu in front) are roots and get no Back button.

local PARENT, OPENER = {}, {}
local ORIGIN, BACKING = nil, false
local rawRegister, rawShow = lib.registerContext, lib.showContext

local function isAncestor(of, id)
    for _ = 1, 25 do
        if not of then return false end
        if of == id then return true end
        of = PARENT[of]
    end
    return false
end

local function rebuild(p)
    local fn = OPENER[p]
    if not fn then return false end
    local was = BACKING
    BACKING = true
    local ok, err = pcall(fn)
    BACKING = was
    if not ok then print(('[opslabs-towers] menu rebuild failed: %s'):format(err)) end
    return ok
end

local function wrapOptions(id, options)
    for _, o in pairs(options or {}) do
        local fn = o.onSelect
        if type(o) == 'table' and fn and not o.__nav then
            o.__nav = true
            local arrow = o.arrow
            o.onSelect = function(args)
                local prev = ORIGIN
                ORIGIN = { id = id, arrow = arrow, fn = function() return fn(args) end }
                local ok, err = pcall(fn, args)
                ORIGIN = prev
                if not ok then error(err, 0) end
            end
        end
    end
end

lib.registerContext = function(ctx)
    if type(ctx) ~= 'table' or not ctx.id then return rawRegister(ctx) end
    local id = ctx.id
    if ctx.root then
        PARENT[id], OPENER[id] = nil, nil
    elseif ORIGIN and ORIGIN.id ~= id then
        if not isAncestor(ORIGIN.id, id) then                 -- going down (going up keeps the old parent)
            PARENT[id] = ORIGIN.id
            OPENER[id] = ORIGIN.arrow and ORIGIN.fn or nil
        end
    elseif not ORIGIN and not BACKING then                    -- opened from a command / key
        PARENT[id], OPENER[id] = nil, nil
    end
    local parent = PARENT[id]
    ctx.menu = parent
    ctx.onBack = parent and function() rebuild(parent) end or nil
    wrapOptions(id, ctx.options)
    return rawRegister(ctx)
end

--- go back from menu `id` to wherever it was opened from (after removing something, etc.)
--- returns false when there is nowhere to go back to
function MenuBack(id)
    local p = PARENT[id]
    if not p then return false end
    if not rebuild(p) then rawShow(p) end
    return true
end

--- true when `id` was opened from another menu (it has a Back button)
function MenuHasParent(id) return PARENT[id] ~= nil end
