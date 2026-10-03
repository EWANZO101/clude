local carry = {
	InProgress = false,
	requestPending = false,
	targetSrc = -1,
	type = "",
	personCarrying = {
		animDict = "missfinale_c2mcs_1",
		anim = "fin_c2_mcs_1_camman",
		flag = 49,
	},
	personCarried = {
		animDict = "nm",
		anim = "firemans_carry",
		attachX = 0.27,
		attachY = 0.15,
		attachZ = 0.63,
		flag = 33,
	}
}

local function GetClosestPlayer(radius)
    local players = GetActivePlayers()
    local closestDistance = -1
    local closestPlayer = -1
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)

    for _,playerId in ipairs(players) do
        local targetPed = GetPlayerPed(playerId)
        if targetPed ~= playerPed then
            local targetCoords = GetEntityCoords(targetPed)
            local distance = #(targetCoords-playerCoords)
            if closestDistance == -1 or closestDistance > distance then
                closestPlayer = playerId
                closestDistance = distance
            end
        end
    end
	if closestDistance ~= -1 and closestDistance <= radius then
		return closestPlayer
	else
		return nil
	end
end

local function ensureAnimDict(animDict)
    if not HasAnimDictLoaded(animDict) then
        RequestAnimDict(animDict)
        while not HasAnimDictLoaded(animDict) do
            Wait(0)
        end        
    end
    return animDict
end

-- shared start/stop so both the keybind/command AND the target option use the same logic
-- actually starting the carry now waits on the target accepting a permission prompt
-- (see CarryPeople:askPermission / CarryPeople:cl_start below), so this only sends the request.
local function RequestCarry(targetSrc)
	if carry.InProgress or carry.requestPending then return end
	if not targetSrc or targetSrc == -1 then
		exports.rps_lib:Notify("No one nearby to carry!", 'error')
		return
	end

	carry.requestPending = true
	TriggerServerEvent("CarryPeople:request", targetSrc)
	if Config.RequirePermission then
		exports.rps_lib:Notify("Waiting for them to accept...", 'inform')
	end
end

local function StopCarry()
	if not carry.InProgress then return end
	carry.InProgress = false
	ClearPedSecondaryTask(PlayerPedId())
	DetachEntity(PlayerPedId(), true, false)
	TriggerServerEvent("CarryPeople:stop", carry.targetSrc)
	carry.targetSrc = 0
end

-- toggle command: proximity-based (closest player within 3m)
RegisterCommand("carry", function(source, args)
	if carry.InProgress then
		StopCarry()
	elseif not carry.requestPending then
		local closestPlayer = GetClosestPlayer(3)
		local targetSrc = closestPlayer and GetPlayerServerId(closestPlayer) or nil
		RequestCarry(targetSrc)
	end
end, false)

-- keybind: middle mouse button by default, rebindable in FiveM's
-- Settings > Key Bindings > FiveM menu under "Carry Player"
RegisterKeyMapping('carry', 'Carry Player', 'mouse_button', 'MOUSE_MIDDLE')

-- rps_lib target support: adds a "Carry" option to every player ped via
-- rps_lib's AddModelTarget (bridges to ox_target/qb-target, whichever is
-- installed; falls back to a harmless lib.print reminder if neither is).
exports.rps_lib:AddModelTarget({ `mp_m_freemode_01`, `mp_f_freemode_01` }, {
	{
		name = 'rps_carry',
		icon = 'fas fa-people-carry',
		label = 'Carry',
		distance = 2.5, -- read by the ox_target backend (per-option field)
		canInteract = function(entity, distance, coords, name)
			return not carry.InProgress and not carry.requestPending and IsPedAPlayer(entity)
		end,
		onSelect = function(data)
			if carry.InProgress or carry.requestPending then return end
			local playerIndex = NetworkGetPlayerIndexFromPed(data.entity)
			local targetSrc = playerIndex and GetPlayerServerId(playerIndex) or nil
			RequestCarry(targetSrc)
		end,
	},
}, 2.5) -- read by the qb-target backend (top-level distance)

-- Shown to the target of a carry request as rps_lib target options on the
-- requester's own ped (same AddEntityTarget/RemoveEntityTarget API already
-- used elsewhere in this codebase, e.g. rps_parking's PoliceOptions), rather
-- than a keybind or dialog.
local pendingCarryId = 0

RegisterNetEvent("CarryPeople:askPermission", function(requesterSrc, requesterName)
	local requesterPed = GetPlayerPed(GetPlayerFromServerId(requesterSrc))
	if not requesterPed or requesterPed == 0 then
		TriggerServerEvent("CarryPeople:respond", requesterSrc, false)
		return
	end

	pendingCarryId = pendingCarryId + 1
	local thisRequestId = pendingCarryId
	local resolved = false

	local carryRequestOptions = {
		{
			name = 'rps_carry_accept',
			icon = 'fas fa-check',
			label = 'Accept Carry Request',
			onSelect = function()
				if resolved then return end
				resolved = true
				exports.rps_lib:RemoveEntityTarget(requesterPed, carryRequestOptions)
				TriggerServerEvent("CarryPeople:respond", requesterSrc, true)
			end,
		},
		{
			name = 'rps_carry_decline',
			icon = 'fas fa-xmark',
			label = 'Decline Carry Request',
			onSelect = function()
				if resolved then return end
				resolved = true
				exports.rps_lib:RemoveEntityTarget(requesterPed, carryRequestOptions)
				TriggerServerEvent("CarryPeople:respond", requesterSrc, false)
			end,
		},
	}

	exports.rps_lib:AddEntityTarget(requesterPed, carryRequestOptions, 2.5)
	exports.rps_lib:Notify(('%s wants to carry you. Target them to accept or decline.'):format(requesterName), 'inform')

	SetTimeout(Config.RequestTimeout, function()
		if pendingCarryId == thisRequestId and not resolved then
			resolved = true
			exports.rps_lib:RemoveEntityTarget(requesterPed, carryRequestOptions)
			TriggerServerEvent("CarryPeople:respond", requesterSrc, false)
		end
	end)
end)

-- Sent to the requester once the target accepts; this is what actually starts the carry.
RegisterNetEvent("CarryPeople:cl_start", function(targetSrc)
	carry.requestPending = false
	carry.InProgress = true
	carry.targetSrc = targetSrc
	ensureAnimDict(carry.personCarrying.animDict)
	carry.type = "carrying"
end)

RegisterNetEvent("CarryPeople:cl_declined", function(reason)
	carry.requestPending = false
	exports.rps_lib:Notify(reason or "Carry request declined.", 'error')
end)

RegisterNetEvent("CarryPeople:syncTarget", function(targetSrc)
	local targetPed = GetPlayerPed(GetPlayerFromServerId(targetSrc))
	carry.InProgress = true
	ensureAnimDict(carry.personCarried.animDict)
	AttachEntityToEntity(PlayerPedId(), targetPed, 0, carry.personCarried.attachX, carry.personCarried.attachY, carry.personCarried.attachZ, 0.5, 0.5, 180, false, false, false, false, 2, false)
	carry.type = "beingcarried"
end)

RegisterNetEvent("CarryPeople:cl_stop", function()
	carry.InProgress = false
	ClearPedSecondaryTask(PlayerPedId())
	DetachEntity(PlayerPedId(), true, false)
end)

CreateThread(function()
	while true do
		if carry.InProgress then
			if carry.type == "beingcarried" then
				if not IsEntityPlayingAnim(PlayerPedId(), carry.personCarried.animDict, carry.personCarried.anim, 3) then
					TaskPlayAnim(PlayerPedId(), carry.personCarried.animDict, carry.personCarried.anim, 8.0, -8.0, 100000, carry.personCarried.flag, 0, false, false, false)
				end
			elseif carry.type == "carrying" then
				if not IsEntityPlayingAnim(PlayerPedId(), carry.personCarrying.animDict, carry.personCarrying.anim, 3) then
					TaskPlayAnim(PlayerPedId(), carry.personCarrying.animDict, carry.personCarrying.anim, 8.0, -8.0, 100000, carry.personCarrying.flag, 0, false, false, false)
				end
			end
		end
		Wait(0)
	end
end)
