-- Framework bridge tests: every adapter against a fake of its framework (shapes taken from each framework's source).
-- Run from the resource folder:   lua5.4 bridge/tests/run.lua        (exit code 1 when a test fails)
-- These prove the adapters map the framework APIs correctly; "verified" in the console still means tested on a
-- live server too.

local root = arg and arg[0]:match('^(.*)/bridge/tests/run%.lua$') or '.'
package.path = root .. '/bridge/tests/?.lua;' .. package.path
local H = require('fivem')

local SERVER = { 'bridge/shared.lua' }
local function serverFiles(extra)
    local list = { 'bridge/shared.lua' }
    local v = io.popen('ls "' .. root .. '/bridge/voice"')
    for f in v:lines() do if f:match('%.lua$') then list[#list + 1] = 'bridge/voice/' .. f end end
    v:close()
    for _, f in ipairs({ 'esx', 'qbx', 'qb', 'ox', 'nd', 'vrp', 'standalone' }) do
        local path = 'bridge/server/frameworks/' .. f .. '.lua'
        if io.open(root .. '/' .. path) then list[#list + 1] = path end
    end
    for _, f in ipairs({ 'ox_inventory', 'qb-inventory', 'ps-inventory', 'lj-inventory', 'qs-inventory', 'codem-inventory', 'tgiann-inventory' }) do
        local path = 'bridge/server/inventories/' .. f .. '.lua'
        if io.open(root .. '/' .. path) then list[#list + 1] = path end
    end
    local p = io.popen('ls "' .. root .. '/bridge/server/integrations"')
    for f in p:lines() do if f:match('%.lua$') then list[#list + 1] = 'bridge/server/integrations/' .. f end end
    p:close()
    for _, f in ipairs(extra or {}) do list[#list + 1] = f end
    list[#list + 1] = 'bridge/server/core.lua'
    return list
end
_G.TEST_SERVER_FILES = serverFiles

local passed, failed, current = 0, 0, ''
local function fail(msg) error({ test = true, msg = msg }, 2) end
function _G.eq(a, b, what)
    if a ~= b then fail(('%s: expected %s, got %s'):format(what or 'value', tostring(b), tostring(a))) end
end
function _G.ok(v, what) if not v then fail((what or 'expected true') .. ' (got ' .. tostring(v) .. ')') end end

local tests = {}
function _G.test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

--- boots the server bridge with the given fakes; returns H
--- (extraFiles load before core.lua, like bridge/custom; afterFiles after it, like the phone's own server files)
function _G.boot(setup, extraFiles, afterFiles)
    H.reset()
    if setup then setup(H) end
    H.load(root, serverFiles(extraFiles))
    if afterFiles then H.load(root, afterFiles) end
    H.run()
    return H
end
_G.H = H
_G.H_ROOT = root

-- the test files, one per framework
local dir = root .. '/bridge/tests/'
for _, f in ipairs({ 'core_test.lua', 'esx_test.lua', 'qb_test.lua', 'ox_test.lua', 'nd_test.lua', 'vrp_test.lua', 'inventory_test.lua', 'integrations_test.lua', 'integrations2_test.lua', 'client_test.lua' }) do
    local chunk = loadfile(dir .. f)
    if chunk then chunk() end
end

for _, t in ipairs(tests) do
    current = t.name
    local okRun, err = pcall(t.fn)
    if okRun then
        passed = passed + 1
        io.write('  \27[32mok\27[0m   ', t.name, '\n')
    else
        failed = failed + 1
        io.write('  \27[31mFAIL\27[0m ', t.name, '\n       ', type(err) == 'table' and err.msg or tostring(err), '\n')
        if os.getenv('VERBOSE') then for _, l in ipairs(H.logs or {}) do io.write('       | ', l, '\n') end end
    end
end
io.write(('\n%d passed, %d failed\n'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
