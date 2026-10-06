--- Discord Webhook System
--- URLs + queued, throttled Discord logging for the tax system. Messages are
--- pushed onto a queue and sent one at a time by a single worker thread, so a
--- tax cycle never blocks on HTTP requests.
--- @module webhooks

-- ════════════════════════════════════════════════════════════════════════════════════
-- DISCORD WEBHOOK URLS (server-only)
-- ════════════════════════════════════════════════════════════════════════════════════
-- This file is loaded as a server_script only, so these URLs are never sent to
-- players (unlike config.lua, which is shared with clients).
--
-- `default` is used for every log. Set a URL on a specific event to send that
-- event to a different channel instead; leave it '' to use `default`.
-- All other webhook settings (enable, events, colors, throttle) are in config.lua.

Webhooks = {
    default = 'https://discord.com/api/webhooks/1555221101729288223/zfJ3N86xrVBsv32fvzmI5T7xgXxJMxH_RbIXBn7r-0ZuEhZ2PWiUzRaBq9e2reYMPZuS',

    taxCollected      = 'https://discord.com/api/webhooks/1555221101729288223/zfJ3N86xrVBsv32fvzmI5T7xgXxJMxH_RbIXBn7r-0ZuEhZ2PWiUzRaBq9e2reYMPZuS',
    taxFailed         = '',
    taxExempt         = 'https://discord.com/api/webhooks/1555221101729288223/zfJ3N86xrVBsv32fvzmI5T7xgXxJMxH_RbIXBn7r-0ZuEhZ2PWiUzRaBq9e2reYMPZuS',
    collectionSummary = 'https://discord.com/api/webhooks/1555221101729288223/zfJ3N86xrVBsv32fvzmI5T7xgXxJMxH_RbIXBn7r-0ZuEhZ2PWiUzRaBq9e2reYMPZuS',
    manualTrigger     = 'https://discord.com/api/webhooks/1555221101729288223/zfJ3N86xrVBsv32fvzmI5T7xgXxJMxH_RbIXBn7r-0ZuEhZ2PWiUzRaBq9e2reYMPZuS',
    systemStart       = 'https://discord.com/api/webhooks/1555221101729288223/zfJ3N86xrVBsv32fvzmI5T7xgXxJMxH_RbIXBn7r-0ZuEhZ2PWiUzRaBq9e2reYMPZuS',
    systemError       = '',
    test              = ''
}

-- ════════════════════════════════════════════════════════════════════════════════════
-- LOCAL STATE
-- ════════════════════════════════════════════════════════════════════════════════════

local queue = {}
local workerRunning = false
local cycleCount = 0
local cycleCapped = false

-- ════════════════════════════════════════════════════════════════════════════════════
-- INTERNAL
-- ════════════════════════════════════════════════════════════════════════════════════

--- Resolve the URL for an event (event URL, else default)
--- @param event string Event key
--- @return string|nil URL, or nil if webhooks are disabled / no URL is set
local function GetWebhookUrl(event)
    if not Config.Webhook.enabled then return nil end

    local url = Webhooks[event]
    if IsStringEmpty(url) then
        url = Webhooks.default
    end

    return not IsStringEmpty(url) and url or nil
end

--- Send a single payload to Discord (async)
--- @param url string Webhook URL
--- @param payload table Discord webhook payload
--- @return nil
local function Send(url, payload)
    PerformHttpRequest(url, function(status, body)
        if status == 429 then
            WarnPrint('Discord webhook rate limited (429) - consider raising Config.Webhook.throttle.delayMs')
        elseif status < 200 or status >= 300 then
            DebugPrint(string.format('Discord webhook returned %s: %s', tostring(status), tostring(body)))
        end
    end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
end

--- Worker that drains the queue with the configured delay between sends
--- @return nil
local function StartWorker()
    if workerRunning then return end
    workerRunning = true

    CreateThread(function()
        local throttle = Config.Webhook.throttle
        while #queue > 0 do
            local entry = table.remove(queue, 1)
            Send(entry.url, entry.payload)
            if throttle and throttle.enabled then
                Wait(throttle.delayMs or 250)
            else
                Wait(0)
            end
        end
        workerRunning = false
    end)
end

--- Build a Discord embed payload
--- @param title string Embed title
--- @param description string|nil Embed description
--- @param color string Color key from Config.Webhook.colors
--- @param fields table|nil Array of { name, value, inline }
--- @return table Payload
local function BuildPayload(title, description, color, fields)
    local embed = {
        title = title,
        description = description,
        color = Config.Webhook.colors[color] or Config.Webhook.colors.info,
        fields = fields or {},
        footer = { text = Config.Webhook.footer }
    }

    if Config.Webhook.timestamp then
        embed.timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
    end

    return {
        username = Config.Webhook.botName,
        avatar_url = Config.Webhook.avatarUrl,
        embeds = { embed }
    }
end

--- Queue an embed, respecting the per-cycle cap
--- @param event string Event key (selects the URL)
--- @param payload table Discord payload
--- @param bypassCap boolean|nil Always send (summaries, system events)
--- @return boolean True if queued
local function Enqueue(event, payload, bypassCap)
    local url = GetWebhookUrl(event)
    if not url then return false end

    if not bypassCap then
        local throttle = Config.Webhook.throttle
        if throttle and throttle.enabled and throttle.maxPerCycle > 0 then
            if cycleCount >= throttle.maxPerCycle then
                if not cycleCapped then
                    cycleCapped = true
                    DebugPrint('Webhook per-cycle cap reached, suppressing per-player logs')
                end
                return false
            end
            cycleCount = cycleCount + 1
        end
    end

    queue[#queue + 1] = { url = url, payload = payload }
    StartWorker()
    return true
end

--- Build the player fields shared by per-player logs
--- @param playerData table { source, name, citizenid, job }
--- @return table Fields
local function PlayerFields(playerData)
    local fields = {
        { name = 'Player', value = string.format('%s (ID: %s)', playerData.name or 'Unknown', tostring(playerData.source)), inline = true },
        { name = 'Identifier', value = tostring(playerData.citizenid or 'N/A'), inline = true },
        { name = 'Job', value = tostring(playerData.job or 'N/A'), inline = true }
    }

    if Config.Webhook.includeIdentifiers and playerData.source and IsPlayerOnline(playerData.source) then
        local ids = GetPlayerIdentifierTable(playerData.source)
        local lines = {}
        if ids.license ~= '' then lines[#lines + 1] = ids.license end
        if ids.discord ~= '' then lines[#lines + 1] = string.format('<@%s>', (ids.discord:gsub('discord:', ''))) end
        if ids.steam ~= '' then lines[#lines + 1] = ids.steam end
        if #lines > 0 then
            fields[#fields + 1] = { name = 'Identifiers', value = table.concat(lines, '\n'), inline = false }
        end
    end

    return fields
end

-- ════════════════════════════════════════════════════════════════════════════════════
-- CYCLE CONTROL
-- ════════════════════════════════════════════════════════════════════════════════════

--- Reset the per-cycle webhook counter. Call at the start of every tax cycle.
--- @return nil
function BeginWebhookCycle()
    cycleCount = 0
    cycleCapped = false
end

-- ════════════════════════════════════════════════════════════════════════════════════
-- PUBLIC LOG FUNCTIONS
-- ════════════════════════════════════════════════════════════════════════════════════

--- Log a successful tax collection for a player
--- @param playerData table Player data
--- @param bankTax number Bank tax amount
--- @param vehicleTax number Vehicle tax amount
--- @param totalTax number Total collected
--- @return nil
function LogTaxCollected(playerData, bankTax, vehicleTax, totalTax)
    if not Config.Webhook.events.taxCollected then return end
    if cycleCapped and Config.Webhook.throttle.summaryOnlyOnCap then return end

    local fields = PlayerFields(playerData)
    fields[#fields + 1] = { name = 'Bank Tax', value = FormatCurrency(bankTax), inline = true }
    fields[#fields + 1] = { name = 'Vehicle Tax', value = FormatCurrency(vehicleTax), inline = true }
    fields[#fields + 1] = { name = 'Total', value = FormatCurrency(totalTax), inline = true }

    Enqueue('taxCollected', BuildPayload('💰 Tax Collected', nil, 'success', fields))
end

--- Log a failed tax collection for a player
--- @param playerData table Player data
--- @param amount number Amount due
--- @param reason string Failure reason
--- @return nil
function LogTaxFailed(playerData, amount, reason)
    if not Config.Webhook.events.taxFailed then return end
    if cycleCapped and Config.Webhook.throttle.summaryOnlyOnCap then return end

    local fields = PlayerFields(playerData)
    fields[#fields + 1] = { name = 'Amount Due', value = FormatCurrency(amount or 0), inline = true }
    fields[#fields + 1] = { name = 'Reason', value = tostring(reason or 'Unknown'), inline = true }

    Enqueue('taxFailed', BuildPayload('❌ Tax Collection Failed', nil, 'error', fields))
end

--- Log a tax-exempt player
--- @param playerData table Player data
--- @param reason string Exemption reason
--- @return nil
function LogTaxExempt(playerData, reason)
    if not Config.Webhook.events.taxExempt then return end
    if cycleCapped and Config.Webhook.throttle.summaryOnlyOnCap then return end

    local fields = PlayerFields(playerData)
    fields[#fields + 1] = { name = 'Reason', value = tostring(reason or 'Exempt'), inline = false }

    Enqueue('taxExempt', BuildPayload('🛡️ Tax Exempt', nil, 'info', fields))
end

--- Log the end-of-cycle summary (always sent, ignores the per-cycle cap)
--- @param totalPlayers number Players processed
--- @param totalCollected number Total amount collected
--- @param failed number Failed collections
--- @param exempt number Exempt players
--- @param deposits table|nil Array of { account, amount, success } from Bridge.DistributeRevenue
--- @return nil
function LogCollectionSummary(totalPlayers, totalCollected, failed, exempt, deposits)
    if Config.Webhook.events.collectionSummary == false then return end

    local fields = {
        { name = 'Players Processed', value = tostring(totalPlayers), inline = true },
        { name = 'Total Collected', value = FormatCurrency(totalCollected), inline = true },
        { name = 'Failed', value = tostring(failed), inline = true },
        { name = 'Exempt', value = tostring(exempt), inline = true },
        { name = 'Next Collection', value = Config.TaxInterval .. ' minutes', inline = true }
    }

    if Config.Banking.enabled and deposits and #deposits > 0 then
        local lines = {}
        for _, d in ipairs(deposits) do
            lines[#lines + 1] = string.format('%s **%s** → %s', d.success and '✅' or '❌', d.account, FormatCurrency(d.amount))
        end
        fields[#fields + 1] = { name = 'Deposits', value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
    end

    if cycleCapped then
        fields[#fields + 1] = { name = 'Note', value = 'Per-player logs were capped this cycle', inline = false }
    end

    Enqueue('collectionSummary', BuildPayload('📊 Tax Collection Summary', nil, failed > 0 and 'warning' or 'success', fields), true)
end

--- Log tax system start
--- @param interval number Collection interval in minutes
--- @return nil
function LogSystemStart(interval)
    if not Config.Webhook.events.systemStart then return end

    local fields = {
        { name = 'Bank Tax', value = Config.BankTax.enabled and ((Config.BankTax.percentage * 100) .. '%') or 'Disabled', inline = true },
        { name = 'Vehicle Tax', value = Config.VehicleTax.enabled and (FormatCurrency(Config.VehicleTax.perVehicle) .. ' / vehicle') or 'Disabled', inline = true },
        { name = 'Interval', value = interval .. ' minutes', inline = true }
    }

    Enqueue('systemStart', BuildPayload('✅ Tax System Started', string.format(Config.Messages.systemStart, interval), 'info', fields), true)
end

--- Log a system error
--- @param title string Error context
--- @param message string Error details
--- @return nil
function LogSystemError(title, message)
    if not Config.Webhook.events.systemError then return end

    Enqueue('systemError', BuildPayload('⚠️ Tax System Error', string.format(Config.Messages.systemError, tostring(title)), 'error', {
        { name = 'Details', value = tostring(message or 'N/A'):sub(1, 1000), inline = false }
    }), true)
end

--- Log a manual tax collection trigger
--- @param triggeredBy string Name of whoever triggered it
--- @return nil
function LogManualCollection(triggeredBy)
    if not Config.Webhook.events.manualTrigger then return end

    Enqueue('manualTrigger', BuildPayload('🔧 Manual Tax Collection', string.format('Triggered by **%s**', triggeredBy), 'warning'), true)
end

--- Send a test message to verify the webhook
--- @return boolean True if queued
function SendTestWebhook()
    return Enqueue('test', BuildPayload('🧪 Webhook Test', 'The tax system webhook is working.', 'info'), true)
end
