-- Security & fencing fixtures (opslabs_fence_*) for the website maps: one tracker per physical LINE of
-- fence, not one per panel. There's no stored "line id" - fixture:saveMany saves every panel placed by the
-- line tool (client/roadworks.lua FenceLine) as its own independent row (server/cabling.lua:830-845) - so a
-- line is reconstructed here by grouping fixtures within reach of each other, same as the line tool spaces
-- them (LINE_GAP, client/roadworks.lua). This also means it works for fencing placed before that tool
-- existed or before its ground-height fix (server/fencefix.lua), with nothing to migrate.

local GROUP_GAP = 4.0   -- a bit over the 2.5 m line-tool spacing so panels butted together always chain

local function fenceFixtures()
    local out = {}
    for id, f in pairs(Cabling.fixtures) do
        if f.model:find('^opslabs_fence_') then out[#out + 1] = f end
    end
    return out
end

--- union-find: group fixtures within GROUP_GAP of another fixture in the same group
local function clusters(list)
    local parent = {}
    for i in ipairs(list) do parent[i] = i end
    local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]] i = parent[i] end return i end
    local function union(a, b) local ra, rb = find(a), find(b) if ra ~= rb then parent[ra] = rb end end
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i], list[j]
            if math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) <= GROUP_GAP then union(i, j) end
        end
    end
    local groups = {}
    for i in ipairs(list) do
        local r = find(i)
        groups[r] = groups[r] or {}
        groups[r][#groups[r] + 1] = list[i]
    end
    local out = {}
    for _, g in pairs(groups) do out[#out + 1] = g end
    return out
end

--- order a cluster along its own line: find the two mutually-farthest fixtures as the ends, then sort
--- every other fixture by where it falls between them
local function ordered(group)
    if #group == 1 then return group end
    local bi, bj, bd = 1, 2, -1
    for i = 1, #group do
        for j = i + 1, #group do
            local d = (group[i].x - group[j].x) ^ 2 + (group[i].y - group[j].y) ^ 2
            if d > bd then bi, bj, bd = i, j, d end
        end
    end
    local ax, ay = group[bi].x, group[bi].y
    local dx, dy = group[bj].x - ax, group[bj].y - ay
    local len2 = dx * dx + dy * dy
    local withT = {}
    for _, f in ipairs(group) do
        local t = len2 > 0 and ((f.x - ax) * dx + (f.y - ay) * dy) / len2 or 0
        withT[#withT + 1] = { f = f, t = t }
    end
    table.sort(withT, function(a, b) return a.t < b.t end)
    local out = {}
    for i, w in ipairs(withT) do out[i] = w.f end
    return out
end

--- one marker per line of fencing, for the grid map and the poles map - pts shaped like every other
--- drawable line on these maps (server/grid.lua ptsOf(), server/isp.lua IspPoles() links): an array of
--- [x, y] pairs, not {x=, y=} objects
function FenceState()
    local out = {}
    for _, group in ipairs(clusters(fenceFixtures())) do
        local line = ordered(group)
        local n = #line
        local sx, sy, sz, pts = 0, 0, 0, {}
        for _, f in ipairs(line) do
            sx, sy, sz = sx + f.x, sy + f.y, sz + f.z
            pts[#pts + 1] = { math.floor(f.x * 10) / 10, math.floor(f.y * 10) / 10 }
        end
        local first, last = line[1], line[n]
        local ids = {}
        for _, f in ipairs(line) do ids[#ids + 1] = f.id end
        out[#out + 1] = {
            id = first.id, count = n, model = first.model,
            x = sx / n, y = sy / n, z = sz / n,     -- tracker position: the line's midpoint
            pts = pts,
            length = math.floor(math.sqrt((last.x - first.x) ^ 2 + (last.y - first.y) ^ 2) + 0.5),
            ids = ids,   -- every fixture in the line, in order - unused by the map, read by the in-game removal tool (client/fencefix.lua)
        }
    end
    return out
end

--- in-game "Remove fencing" tool (client/fencefix.lua): same lines FenceState() shows on the maps, but
--- gated like any other fixture change rather than admin-only, since deleting is no more sensitive than placing
lib.callback.register('opslabs-towers:fence:lines', function(src)
    if not CanCable(src) then return {} end
    return FenceState()
end)
