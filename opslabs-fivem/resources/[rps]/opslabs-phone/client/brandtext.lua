-- Branding for ox_lib menus, notifications and dialogs: swaps the built-in names (OPS Work, OPS Network …) for this
-- server's (GlobalState['ops:brand'], published by opslabs-phone server/brand.lua). Same rules as the phone UI's
-- html/js/brand.js. The same file lives in opslabs-towers/client/brandtext.lua — keep them in step.
local pairsList, bare = {}, nil

local function build(p)
    pairsList, bare = {}, nil
    if not p or not p.brand then return end
    local function add(from, to) if from and to and from ~= to then pairsList[#pairsList + 1] = { from, to } end end
    for k, v in pairs(p.stock or {}) do add(v, p.brand[k]) end
    for k, v in pairs(p.sites or {}) do add(v, (p.brand.Sites or {})[k]) end
    for _, r in ipairs(p.renames or {}) do add(r.from, r.to) end
    table.sort(pairsList, function(a, b) return #a[1] > #b[1] end)
    if p.brand.Name and p.brand.Name ~= 'OPS' then bare = p.brand.Name end
end

local function isWord(c) return c ~= nil and c ~= '' and (c:match('[%w_%-]') ~= nil) end

--- built-in names → this server's names
function BrandText(s)
    if type(s) ~= 'string' or s == '' or (#pairsList == 0 and not bare) then return s end
    for _, pr in ipairs(pairsList) do
        local from, to, out, i = pr[1], pr[2], {}, 1
        while true do
            local a, b = s:find(from, i, true)
            if not a then break end
            if not isWord(s:sub(a - 1, a - 1)) and not isWord(s:sub(b + 1, b + 1)) then
                out[#out + 1] = s:sub(i, a - 1) .. to
            else out[#out + 1] = s:sub(i, b) end
            i = b + 1
        end
        if #out > 0 then s = table.concat(out) .. s:sub(i) end
    end
    if bare then
        s = s:gsub('()OPS()', function(a, b)
            local before, after = s:sub(a - 1, a - 1), s:sub(b, b + 1)
            if isWord(before) or isWord(after:sub(1, 1)) or after:match('^%s%u') then return 'OPS' end
            return bare
        end)
    end
    return s
end

local function deep(t, seen)
    if type(t) == 'string' then return BrandText(t) end
    if type(t) ~= 'table' or (seen and seen[t]) then return t end
    seen = seen or {}
    seen[t] = true
    for k, v in pairs(t) do
        if type(v) == 'string' and (k == 'title' or k == 'description' or k == 'label' or k == 'content' or k == 'text' or k == 'header' or k == 'placeholder' or k == 'metadata') then t[k] = BrandText(v)
        elseif type(v) == 'table' then deep(v, seen) end
    end
    return t
end

build(GlobalState['ops:brand'])
AddStateBagChangeHandler('ops:brand', 'global', function(_, _, value) build(value) end)

-- wrap ox_lib's UI once lib is ready
CreateThread(function()
    while not lib do Wait(100) end
    local function wrap(name, how)
        local f = lib[name]
        if type(f) ~= 'function' then return end
        lib[name] = function(a, ...) return f(how(a), ...) end
    end
    wrap('registerContext', function(a) return deep(a) end)
    wrap('registerMenu', function(a) return deep(a) end)
    wrap('notify', function(a) return deep(a) end)
    wrap('alertDialog', function(a) return deep(a) end)
    wrap('progressBar', function(a) return deep(a) end)
    wrap('progressCircle', function(a) return deep(a) end)
    wrap('showTextUI', function(a) return BrandText(a) end)
    local input = lib.inputDialog
    if type(input) == 'function' then lib.inputDialog = function(h, rows, ...) return input(BrandText(h), deep(rows), ...) end end
end)
