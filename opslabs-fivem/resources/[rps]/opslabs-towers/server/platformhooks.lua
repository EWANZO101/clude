-- Job verification for the OPS platform (opslabs-phone server/platform.lua): did the engineer really do the work?
-- Everything counts only if it was built AFTER the job was accepted (ids above the snapshot taken then).
--   OpsVerifySnapshot()                 -> { fixture, run, tower, at }
--   OpsVerify(spec, x, y, z, snap, who) -> { ok, have, need, label, detail }

local function d2(a, x, y) return math.sqrt((a.x - x) ^ 2 + (a.y - y) ^ 2) end
local function setOf(list) local s = {} for _, v in ipairs(list or {}) do s[v] = true end return s end

local function maxKey(t) local m = 0 for k in pairs(t or {}) do if tonumber(k) and k > m then m = k end end return m end

exports('OpsVerifySnapshot', function()
    return { fixture = maxKey(Cabling.fixtures), run = maxKey(Cabling.runs), tower = maxKey(Towers), at = os.time() }
end)

local function runLength(r)
    local L, p = 0.0, r.points or {}
    for i = 2, #p do L = L + math.sqrt((p[i].x - p[i - 1].x) ^ 2 + (p[i].y - p[i - 1].y) ^ 2 + (p[i].z - p[i - 1].z) ^ 2) end
    return L
end

local check
check = function(v, x, y, z, snap, who)
    local r = v.radius or 40
    local kind = v.kind
    if kind == 'all' then
        local parts, ok = {}, true
        for _, s in ipairs(v.steps or {}) do
            local res = check(s, x, y, z, snap, who)
            parts[#parts + 1] = ('%s %s: %s/%s'):format(res.ok and '✓' or '✗', s.label or res.label, res.have, res.need)
            ok = ok and res.ok
        end
        return { ok = ok, have = ok and 1 or 0, need = 1, label = 'All parts', detail = table.concat(parts, ' · ') }
    elseif kind == 'fixtures' then
        local models, n = setOf(v.models), 0
        for id, f in pairs(Cabling.fixtures) do
            if id > (snap.fixture or 0) and models[f.model] and d2(f, x, y) <= r then n = n + 1 end
        end
        local res = { ok = n >= (v.count or 1), have = n, need = v.count or 1, label = 'New equipment fitted' }
        if res.ok and v['and'] then
            for _, s in ipairs(v['and']) do
                local sub = check(s, x, y, z, snap, who)
                if not sub.ok then res.ok = false res.detail = 'Also needs: ' .. (sub.label or '') .. (' %s/%s'):format(sub.have, sub.need) end
            end
        end
        return res
    elseif kind == 'towers' then
        local models, n = setOf(v.models), 0
        for id, t in pairs(Towers or {}) do
            if id > (snap.tower or 0) and t.model and models[t.model] and d2(t, x, y) <= r then
                local pw = TowerPowered and TowerPowered(id) or true
                if (not v.powered or pw) and (not v.poe or pw == 'poe') then n = n + 1 end
            end
        end
        return { ok = n >= (v.count or 1), have = n, need = v.count or 1,
            label = v.poe and 'Devices powered over PoE' or v.powered and 'Devices installed and powered' or 'Devices installed' }
    elseif kind == 'runs' then
        local L = 0.0
        for id, run in pairs(Cabling.runs) do
            if id > (snap.run or 0) and run.kind == (v.run or 'cable') then
                for _, p in ipairs(run.points or {}) do
                    if d2(p, x, y) <= r then L = L + runLength(run) break end
                end
            end
        end
        return { ok = L >= (v.metres or 10), have = math.floor(L), need = v.metres or 10, label = (v.run == 'fibre' and 'Metres of fibre' or v.run == 'copper' and 'Metres of copper' or 'Metres of CAT6') .. ' laid' }
    elseif kind == 'ont_online' then
        local status = IspPayload and IspPayload() or {}
        local n = 0
        for id, f in pairs(Cabling.fixtures) do
            if f.model == (Config.Isp or {}).Ont and d2(f, x, y) <= r and id > (snap.fixture or 0) then
                local s = status[id]
                if s and s.internet == 'on' then n = n + 1 end
            end
        end
        return { ok = n >= 1, have = n, need = 1, label = 'New ONT online with live service' }
    elseif kind == 'dialtone' then
        local n = 0
        for id, f in pairs(Cabling.fixtures) do
            if id > (snap.fixture or 0) and f.model == 'opslabs_nte5c' and d2(f, x, y) <= r and PhoneLineTrace then
                local tr = PhoneLineTrace(id)
                if tr and tr.dialtone then n = n + 1 end
            end
        end
        return { ok = n >= 1, have = n, need = 1, label = 'New master socket with dial tone' }
    elseif kind == 'mains_live' then
        local models, n = setOf(v.models), 0
        for id, f in pairs(Cabling.fixtures) do
            if id > (snap.fixture or 0) and models[f.model] and d2(f, x, y) <= r then
                local s = MainsState and MainsState(id)
                if s and s.on then n = n + 1 end
            end
        end
        return { ok = n >= (v.count or 1), have = n, need = v.count or 1, label = 'Fitted and live' }
    elseif kind:sub(1, 5) == 'cctv_' then
        local st = CctvCamStates and CctvCamStates() or { cams = {}, recs = {} }
        local CV = Config.Cctv or {}
        local models = v.models and setOf(v.models) or nil
        if kind == 'cctv_online' then
            local n = 0
            for id, c in pairs(st.cams) do
                local f = Cabling.fixtures[id]
                if f and c.online and d2(f, x, y) <= r and (v.new == false or id > (snap.fixture or 0)) and (not models or models[f.model])
                    and (not v.poe or c.via == 'nvr_poe' or c.via == 'switch') then n = n + 1 end
            end
            return { ok = n >= (v.count or 1), have = n, need = v.count or 1, label = v.poe and 'Cameras live over PoE' or 'Cameras live on a recorder' }
        elseif kind == 'cctv_recorder' then
            local n = 0
            for id, rec in pairs(st.recs) do
                local f = Cabling.fixtures[id]
                if f and rec.powered and #(rec.cams or {}) >= 1 and d2(f, x, y) <= r and (v.new == false or id > (snap.fixture or 0)) and (not models or models[f.model]) then n = n + 1 end
            end
            return { ok = n >= 1, have = n, need = 1, label = 'Recorder powered and recording a camera' }
        elseif kind == 'cctv_remote' or kind == 'cctv_recording' then
            local n = 0
            for id, rec in pairs(st.recs) do
                local f = Cabling.fixtures[id]
                local sys = Cctv and Cctv.systems[id]
                if f and sys and d2(f, x, y) <= r and rec.powered then
                    if kind == 'cctv_remote' and sys.remote == 1 and rec.internet then n = n + 1 end
                    if kind == 'cctv_recording' and sys.configured == 1 and rec.recording and #(rec.cams or {}) >= 1 then n = n + 1 end
                end
            end
            return { ok = n >= 1, have = n, need = 1, label = kind == 'cctv_remote' and 'Remote viewing on, recorder online' or 'System set up and recording' }
        elseif kind == 'cctv_healthy' then
            local total, bad = 0, 0
            for id, c in pairs(st.cams) do
                local f = Cabling.fixtures[id]
                if f and d2(f, x, y) <= r then total = total + 1 if not c.online or tostring(c.status):find('^fault') then bad = bad + 1 end end
            end
            return { ok = total > 0 and bad == 0, have = total - bad, need = math.max(1, total), label = 'Cameras on site working' }
        elseif kind == 'cctv_none' then
            local n = 0
            for _, f in pairs(Cabling.fixtures) do if (CV.Cameras or {})[f.model] and d2(f, x, y) <= r then n = n + 1 end end
            return { ok = n == 0, have = n == 0 and 1 or 0, need = 1, label = n == 0 and 'All cameras removed' or (n .. ' camera(s) still fitted') }
        end
    elseif kind and kind:find('^dc_') then
        if not DcVerify then return { ok = false, have = 0, need = 1, label = 'Data centre systems are off' } end
        return DcVerify(v, x, y, z, snap, who)
    elseif kind == 'speedtest' then
        local best = 0
        for _, t in ipairs(OpsIspSpeedtestsSince and OpsIspSpeedtestsSince(x, y, r, snap.at or 0) or {}) do
            local pct = math.floor(tonumber(t.down_mbps) / math.max(1, tonumber(t.plan_down)) * 100)
            if pct > best then best = pct end
        end
        return { ok = best >= (v.pct or 70), have = best, need = v.pct or 70, label = 'Best speed test (% of the package)' }
    elseif kind == 'isp_config' then
        local cfg, at, svc, ips = nil, 0, nil, nil
        if OpsIspConfigNear then cfg, at, svc, ips = OpsIspConfigNear(x, y, r) end
        if not cfg then return { ok = false, have = 0, need = 1, label = 'No OPS Network line at this address' } end
        local changed = (at or 0) >= (snap.at or 0)
        local f, have = v.field, false
        if f == 'firewall' then have = #((cfg.firewall or {}).rules or {}) > 0
        elseif f == 'forwards' then have = #(cfg.forwards or {}) > 0
        elseif f == 'vlans' then have = #(cfg.vlans or {}) >= 2
        elseif f == 'vpn' then have = #(cfg.vpn or {}) > 0
        elseif f == 'dns' then have = cfg.dns ~= nil
        elseif f == 'dhcp' then have = cfg.dhcp ~= nil and #((cfg.dhcp or {}).reservations or {}) > 0
        elseif f == 'wifi' then have = cfg.wifi ~= nil and cfg.wifi.password ~= nil and cfg.wifi.password ~= ''
        elseif f == 'ip' then have = #(ips or {}) > 0 end
        local ok = have and (changed or f == 'ip')
        return { ok = ok, have = ok and 1 or 0, need = 1, label = ('Router settings: %s %s'):format(f, have and (changed and 'set' or 'set before this job — change them on OPS Hub') or 'not set yet'),
            detail = 'OPS Hub → OPS Network → the customer’s line → Router settings' }
    elseif kind == 'tracker' then
        local n = 0
        for _, t in ipairs((TrackState and TrackState().trackers) or {}) do
            if (t.installed_at or 0) >= (snap.at or 0) and (not who or t.installed_by == who) then n = n + 1 end
        end
        return { ok = n >= 1, have = n, need = 1, label = 'Tracker fitted (by you)' }
    end
    return { ok = false, have = 0, need = 1, label = 'Unknown check ' .. tostring(kind) }
end

exports('OpsVerify', function(spec, x, y, z, snap, who)
    local ok, res = pcall(check, spec or {}, tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0, snap or {}, who)
    if not ok then return { ok = false, have = 0, need = 1, label = 'Check failed', detail = tostring(res) } end
    return res
end)
