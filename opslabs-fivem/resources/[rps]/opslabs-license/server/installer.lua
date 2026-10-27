-- In-FXServer installer: for hosts where no companion process can run at all (txAdmin panel + FTP/
-- SFTP only, no shell/RDP) - ops-update-companion.py needs somewhere to run; this needs nothing but
-- FXServer itself, so "restart the server" really is the whole update step. For anyone with real OS
-- access, the companion script is still the fuller-featured path (full .zip, backup/rollback
-- generations) - this is the lighter "restart and it's already there" tier.
--
-- FXServer's Lua has no .zip parser, so instead of teaching it the real ZIP format (where the bugs
-- would be), the server derives a much simpler artifact from the same uploaded zip at publish time
-- (see opsphone-store's ops_license_updates.py build_pack()): one length-framed entry after another,
-- the whole thing zlib-compressed once. Two vendored, unmodified libraries do the real work:
--   libs/LibDeflate.lua - zlib-licensed, decodes the standard zlib/DEFLATE stream (RFC1950/1951)
--   libs/sha2.lua       - MIT-licensed "pure_lua_SHA", sha.sha256(str) for the integrity check
-- Both return a module table via `return X` at EOF, which plain shared/server_script loading
-- discards - loaded here with load()+LoadResourceFile instead, so the vendored files stay untouched
-- and diffable against upstream.
--
-- Trust model: this never makes its own decision about what's allowed to run - it only ever asks
-- about codes already in Cert.resources that main.lua's State.modules/State.enabled already say are
-- licensed AND switched on (the exact same signed certificate everything else here trusts). The
-- manifest for the actual file bytes is the same sign()/verifyCertificate() pair used for the
-- license certificate itself - no new crypto, no new trust root. A tampered or truncated download
-- fails the hash check before a single file is written; a crafted path (`..`, a leading `/`, a drive
-- letter) is rejected before a single file is written. Nothing (e.g. undoing) happens for a pack that
-- fails to fully parse - either every entry is written, or none are.

local RES = GetCurrentResourceName()

local function loadLib(name)
    local src = LoadResourceFile(RES, ('libs/%s.lua'):format(name))
    if not src then return nil end
    local chunk, err = load(src, name)
    if not chunk then
        print(('^1[OPSHUB] failed to load %s: %s^7'):format(name, tostring(err)))
        return nil
    end
    local ok, result = pcall(chunk)
    if not ok then
        print(('^1[OPSHUB] failed to run %s: %s^7'):format(name, tostring(result)))
        return nil
    end
    return result
end

local LibDeflate = loadLib('LibDeflate')
local sha = loadLib('sha2')

--- same underlying crypto as the license certificate (exports[RES]:verifyCertificate, Config.PublicKey -
--- both globals/exports, no need for main.lua to hand anything over) but NOT main.lua's own verify():
--- that one also asserts c.iss == 'OPSHUB' and c.uid == this instance, which only make sense for the
--- license certificate shape - an update manifest has neither field. Binding this manifest to the
--- module it claims to be for (so a signed manifest for one module can't be replayed as another) is
--- done at the call site instead, by checking manifest.module == code.
local function verifyManifest(certB64, sigB64)
    local ok, text = pcall(function() return exports[RES]:verifyCertificate(certB64, sigB64, Config.PublicKey) end)
    if not ok or not text then return nil, 'signature' end
    local okJ, manifest = pcall(json.decode, text)
    if not okJ or type(manifest) ~= 'table' then return nil, 'format' end
    return manifest
end

--- is this a path we're willing to write via SaveResourceFile? No traversal, no absolute path, no
--- drive letter - must stay inside the resource's own folder.
local function safePath(path)
    if type(path) ~= 'string' or path == '' then return false end
    if path:find('%.%.') then return false end
    if path:sub(1, 1) == '/' or path:sub(1, 1) == '\\' then return false end
    if path:match('^%a:') then return false end
    return true
end

--- parse the length-framed, already-decompressed buffer into { {path, content}, ... }, or nil + why.
--- Parses (and validates) every entry before the caller writes anything - a short/corrupt buffer
--- fails here, before touching disk.
local function parsePack(data)
    local entries, pos, sawManifest = {}, 1, false
    local len = #data
    while pos <= len do
        if pos + 4 > len + 1 then return nil, 'truncated (path length)' end
        local okP, pathLen = pcall(string.unpack, '<I4', data, pos)
        if not okP then return nil, 'bad path length' end
        pos = pos + 4
        if pos + pathLen - 1 > len then return nil, 'truncated (path)' end
        local path = data:sub(pos, pos + pathLen - 1)
        pos = pos + pathLen
        if pos + 4 > len + 1 then return nil, 'truncated (content length)' end
        local okC, contentLen = pcall(string.unpack, '<I4', data, pos)
        if not okC then return nil, 'bad content length' end
        pos = pos + 4
        if pos + contentLen - 1 > len then return nil, 'truncated (content)' end
        local content = data:sub(pos, pos + contentLen - 1)
        pos = pos + contentLen
        if not safePath(path) then return nil, ('unsafe path %q'):format(path) end
        if path == 'fxmanifest.lua' then sawManifest = true end
        entries[#entries + 1] = { path = path, content = content }
    end
    if pos ~= len + 1 then return nil, 'trailing garbage after last entry' end
    if not sawManifest then return nil, 'no fxmanifest.lua at the pack root - not a resource package' end
    return entries
end

--- a raw GET, unlike main.lua's own call() (always POST, always JSON-decodes the response) - the
--- pack is binary, not JSON, so it needs its own request rather than reusing that one.
local function httpGetRaw(url)
    local p = promise.new()
    PerformHttpRequest(url, function(status, text)
        p:resolve({ status = status or 0, body = text or '' })
    end, 'GET', '', {})
    return Citizen.Await(p)
end

--- download, verify, parse and install `code` (module) -> `res` (resource) at `version`. Writes the
--- same `.opshub-update-pending` marker main.lua's checkPendingUpdates() already watches for, so the
--- actual StopResource/StartResource happens through that one shared path regardless of whether the
--- update came from this installer or ops-update-companion.py.
local function installPack(key, code, res, manifest)
    if not LibDeflate or not sha then
        print('^1[OPSHUB] installer unavailable - libs/LibDeflate.lua or libs/sha2.lua failed to load^7')
        return
    end
    local url = ('%s/updates/%s/pack?key=%s'):format(Config.Api, code, key)
    local r = httpGetRaw(url)
    if r.status ~= 200 or r.body == '' then
        print(('^1[OPSHUB] %s: pack download failed (HTTP %s)^7'):format(code, tostring(r.status)))
        return
    end
    if sha.sha256(r.body) ~= manifest.pack_sha256 then
        print(('^1[OPSHUB] %s: downloaded pack does not match the signed manifest - discarding, nothing installed^7'):format(code))
        return
    end
    local data, err = LibDeflate:DecompressZlib(r.body)
    if not data then
        print(('^1[OPSHUB] %s: pack failed to decompress: %s^7'):format(code, tostring(err)))
        return
    end
    local entries, parseErr = parsePack(data)
    if not entries then
        print(('^1[OPSHUB] %s: pack rejected - %s^7'):format(code, tostring(parseErr)))
        return
    end
    for _, e in ipairs(entries) do
        SaveResourceFile(res, e.path, e.content, #e.content)
    end
    local version = tostring(manifest.version)
    SaveResourceFile(res, '.opshub-update-pending', version, #version)
    print(('^2[OPSHUB] %s: installed %s (%d files) - waiting for the next check-in to restart it^7'):format(code, version, #entries))
end

--- one entry per entitled+enabled resource module: check, and install if OPSHUB says there's
--- something newer than what's on disk. `call` is main.lua's own HTTP helper (reused, not
--- reimplemented, POST+JSON only - fine here, /updates/check answers in JSON too) - `key` is the
--- license key main.lua already resolved for this check-in.
return function(call, key, cert, moduleOn, state)
    if not cert or type(cert.resources) ~= 'table' then return end
    for code, res in pairs(cert.resources) do
        if type(res) == 'string' and state.modules[code] == true and moduleOn(code) and GetResourceState(res) ~= 'missing' then
            local localVersion = GetResourceMetadata(res, 'version', 0) or ''
            local r = call('/updates/check', { key = key, module = code, version = localVersion })
            if r.status == 200 and r.data.update_available then
                local manifest, why = verifyManifest(r.data.cert, r.data.sig)
                if manifest and manifest.module == code then
                    installPack(key, code, res, manifest)
                elseif manifest then
                    print(('^1[OPSHUB] %s: update manifest was for a different module - ignored^7'):format(code))
                else
                    print(('^1[OPSHUB] %s: update manifest signature did not verify (%s) - ignored^7'):format(code, tostring(why)))
                end
            end
        end
    end
end
