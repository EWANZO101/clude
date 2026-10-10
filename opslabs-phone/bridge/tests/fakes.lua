-- Fakes of each framework's server API, shaped like their source (see the comments for the files they follow).
local F = {}

--- ESX Legacy 1.15 (es_extended/server/classes/player.lua, server/functions.lua, shared/main.lua)
function F.esx(H, opts)
    opts = opts or {}
    H.resources.es_extended = 'started'
    local players, usable = {}, {}
    local function xPlayer(src, d)
        local accounts = { bank = d.bank or 0, money = d.cash or 0 }
        local inv = d.items or {}
        local self = { source = src, identifier = d.identifier, job = d.job, group = d.group or 'user' }
        function self.getName() return d.first .. ' ' .. d.last end
        function self.get(k) return ({ firstName = d.first, lastName = d.last })[k] end
        function self.getGroup() return self.group end
        function self.getAccount(n) return accounts[n] and { name = n, money = accounts[n] } or nil end
        function self.addAccountMoney(n, m) accounts[n] = accounts[n] + m end
        function self.removeAccountMoney(n, m) accounts[n] = accounts[n] - m end
        function self.getInventoryItem(n) return { name = n, count = inv[n] or 0 } end
        function self.addInventoryItem(n, c) inv[n] = (inv[n] or 0) + c end
        function self.removeInventoryItem(n, c) inv[n] = (inv[n] or 0) - c end
        function self.showNotification(msg) H.notified = msg end
        self._accounts, self._inv = accounts, inv
        return self
    end
    local ESX = {}
    function ESX.GetPlayerFromId(src) return players[tonumber(src)] end
    function ESX.GetPlayerFromIdentifier(id) for _, p in pairs(players) do if p.identifier == id then return p end end end
    function ESX.RegisterUsableItem(item, cb) usable[item] = cb end
    H.exportsOf.es_extended = opts.noExport and {} or { getSharedObject = function() return ESX end }
    return {
        ESX = ESX, usable = usable,
        add = function(src, d)
            players[src] = xPlayer(src, d)
            H.players[src] = { name = 'steamname' .. src }
            return players[src]
        end,
    }
end

-- QBCore player object (qb-core/server/player.lua): PlayerData + Functions; bank may go negative (MinusLimit)
local function qbPlayer(src, d)
    local money = { cash = d.cash or 0, bank = d.bank or 0 }
    local P = {
        PlayerData = { source = src, citizenid = d.citizenid, charinfo = { firstname = d.first, lastname = d.last },
            job = d.job, money = money },
        Functions = {},
    }
    function P.Functions.GetMoney(t) return money[t] end
    function P.Functions.AddMoney(t, n) money[t] = money[t] + n return true end
    function P.Functions.RemoveMoney(t, n)
        if t == 'cash' and money[t] < n then return false end
        money[t] = money[t] - n          -- bank: allowed down to -5000
        return true
    end
    return P
end

--- qb-core 1.3 (shared/main.lua GetCoreObject, server/functions.lua)
function F.qb(H)
    H.resources['qb-core'] = 'started'
    local players, usable = {}, {}
    local QBCore = { Functions = {} }
    function QBCore.Functions.GetPlayer(src) return players[tonumber(src)] end
    function QBCore.Functions.GetPlayerByCitizenId(cid) for _, p in pairs(players) do if p.PlayerData.citizenid == cid then return p end end end
    function QBCore.Functions.HasPermission(src, perm) return IsPlayerAceAllowed(src, perm) end
    function QBCore.Functions.CreateUseableItem(item, cb) usable[item] = cb end
    H.exportsOf['qb-core'] = { GetCoreObject = function() return QBCore end }
    return { usable = usable, add = function(src, d) players[src] = qbPlayer(src, d) H.players[src] = { name = 'p' .. src } return players[src] end }
end

--- qbx_core 1.24 (server/functions.lua, server/player.lua): exports; money exports take a source or a citizenid
function F.qbx(H)
    H.resources.qbx_core = 'started'
    H.resources['qb-core'] = 'started'          -- provide 'qb-core'
    local players, offline, usable = {}, {}, {}
    local function find(id)
        if type(id) == 'number' then return players[id] end
        for _, p in pairs(players) do if p.PlayerData.citizenid == id then return p end end
        return offline[id]
    end
    H.exportsOf.qbx_core = {
        GetPlayer = function(_, src) return players[tonumber(src)] end,
        GetPlayerByCitizenId = function(_, cid) for _, p in pairs(players) do if p.PlayerData.citizenid == cid then return p end end end,
        GetMoney = function(_, id, t) local p = find(id) return p and p.Functions.GetMoney(t) end,
        AddMoney = function(_, id, t, n) local p = find(id) return p ~= nil and p.Functions.AddMoney(t, n) end,
        RemoveMoney = function(_, id, t, n) local p = find(id) return p ~= nil and p.Functions.RemoveMoney(t, n) end,
        CreateUseableItem = function(_, item, cb) usable[item] = cb end,
        Notify = function(_, src, msg) H.notified = msg end,
    }
    return {
        usable = usable,
        add = function(src, d) players[src] = qbPlayer(src, d) H.players[src] = { name = 'p' .. src } return players[src] end,
        addOffline = function(cid, d) d.citizenid = cid offline[cid] = qbPlayer(nil, d) return offline[cid] end,
    }
end

--- ox_core (server/classInterface.ts exports: GetPlayer / CallPlayer / GetCharacterAccount / CallAccount …)
function F.ox(H)
    H.resources.ox_core = 'started'
    local players, accounts, groupAccounts = {}, {}, {}
    local function call(src, method, a)
        local p = players[tonumber(src)]
        if not p then return nil end
        if method == 'get' then return p.data[a] end
        if method == 'getGroup' then return p.groups[a] end
    end
    local function acc(id) return accounts[id] end
    H.exportsOf.ox_core = {
        GetPlayer = function(_, src) local p = players[tonumber(src)] return p and { source = src, charId = p.charId, userId = 1 } end,
        GetPlayerFromCharId = function(_, id) for src, p in pairs(players) do if p.charId == id then return { source = src, charId = id } end end end,
        CallPlayer = function(_, src, method, a) return call(src, method, a) end,
        GetCharacterAccount = function(_, charId) return accounts['c' .. tostring(charId)] and { accountId = 'c' .. tostring(charId) } or nil end,
        GetGroupAccount = function(_, name) return accounts['g' .. name] and { accountId = 'g' .. name } or nil end,
        CallAccount = function(_, id, method, a)
            local A = acc(id)
            if method == 'get' then return A.balance end
            if method == 'addBalance' then A.balance = A.balance + a.amount return { success = true } end
            if method == 'removeBalance' then
                if not a.overdraw and A.balance < a.amount then return { success = false, message = 'insufficient_balance' } end
                A.balance = A.balance - a.amount return { success = true }
            end
        end,
    }
    return {
        add = function(src, d)
            players[src] = { charId = d.charId, data = { firstName = d.first, lastName = d.last, activeGroup = d.group }, groups = d.groups or {} }
            accounts['c' .. d.charId] = { balance = d.bank or 0 }
            H.players[src] = { name = 'p' .. src }
        end,
        account = function(id, balance) accounts[id] = { balance = balance } end,
        balance = function(id) return accounts[id].balance end,
    }
end

--- ND Core 2.3 (server/player.lua createCharacterTable, server/functions.lua): deductMoney doesn't check the balance
function F.nd(H)
    H.resources.ND_Core = 'started'
    local players = {}
    H.exportsOf.ND_Core = {
        getPlayer = function(_, src) return players[tonumber(src)] end,
        getPlayers = function(_, key, value) local out = {} for _, p in pairs(players) do if p[key] == value then out[#out + 1] = p end end return out end,
    }
    return {
        add = function(src, d)
            local self = { id = d.charid, source = src, firstname = d.first, lastname = d.last, cash = d.cash or 0, bank = d.bank or 0,
                job = d.job, jobInfo = d.jobInfo, groups = d.groups or {} }
            function self.addMoney(a, n) self[a] = self[a] + n return true end
            function self.deductMoney(a, n) self[a] = self[a] - n return true end
            function self.notify(data) H.notified = data.description end
            players[src] = self
            H.players[src] = { name = 'p' .. src }
            return self
        end,
    }
end

--- vRP 1 (vrp/lib/Proxy.lua addInterface + modules/money.lua, identity.lua, group.lua)
function F.vrp(H)
    H.resources.vrp = 'started'
    H.files.vrp = { ['base.lua'] = 'function vRP.getUserId(source) end' }
    local users, wallet, bank, identity, groups = {}, {}, {}, {}, {}
    local vRP = {}
    function vRP.getUserId(src) return users[tonumber(src)] end
    function vRP.getUserSource(uid) for s, u in pairs(users) do if u == uid then return s end end end
    function vRP.getUserIdentity(uid) return identity[uid] end
    function vRP.getUserGroupByType(uid, t) return (groups[uid] or {})._job or '' end
    function vRP.getGroupTitle(g) return g:upper() end
    function vRP.hasGroup(uid, g) return (groups[uid] or {})[g] == true end
    function vRP.hasPermission() return false end
    function vRP.getMoney(uid) return wallet[uid] end
    function vRP.giveMoney(uid, n) wallet[uid] = wallet[uid] + n end
    function vRP.tryPayment(uid, n) if wallet[uid] >= n then wallet[uid] = wallet[uid] - n return true end return false end
    function vRP.getBankMoney(uid) return bank[uid] end
    function vRP.setBankMoney(uid, v) bank[uid] = v end
    function vRP.giveBankMoney(uid, n) bank[uid] = bank[uid] + n end
    -- Proxy.addInterface('vRP', vRP)
    AddEventHandler('vRP:proxy', function(member, args, identifier, rid)
        local f = vRP[member]
        local rets = f and { f(table.unpack(args)) } or {}
        if rid >= 0 then TriggerEvent('vRP:' .. identifier .. ':proxy_res', rid, rets) end
    end)
    return {
        add = function(src, uid, d)
            users[src], wallet[uid], bank[uid] = uid, d.cash or 0, d.bank or 0
            identity[uid] = { firstname = d.first, name = d.last }
            groups[uid] = d.groups or {}
            H.players[src] = { name = 'p' .. src }
        end,
        bank = function(uid) return bank[uid] end,
    }
end

return F
