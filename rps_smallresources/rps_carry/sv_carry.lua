local carrying = {}
--carrying[source] = targetSource, source is carrying targetSource
local carried = {}
--carried[targetSource] = source, targetSource is being carried by source
local pendingRequest = {}
--pendingRequest[targetSrc] = requesterSrc, targetSrc has a pending carry request from requesterSrc

local function InRange(a, b)
	local aPed, bPed = GetPlayerPed(a), GetPlayerPed(b)
	if aPed == 0 or bPed == 0 then return false end
	return #(GetEntityCoords(aPed) - GetEntityCoords(bPed)) <= 3.0
end

local function StartCarrySession(requesterSrc, targetSrc)
	carrying[requesterSrc] = targetSrc
	carried[targetSrc] = requesterSrc
	TriggerClientEvent("CarryPeople:cl_start", requesterSrc, targetSrc)
	TriggerClientEvent("CarryPeople:syncTarget", targetSrc, requesterSrc)
end

-- Asks the target player for permission before anyone starts carrying
-- (skipped entirely when Config.RequirePermission is false).
RegisterServerEvent("CarryPeople:request", function(targetSrc)
	local source = source

	if carrying[source] or carried[source] then return end
	if carrying[targetSrc] or carried[targetSrc] or pendingRequest[targetSrc] then
		TriggerClientEvent("CarryPeople:cl_declined", source, "They're busy right now.")
		return
	end

	if not InRange(source, targetSrc) then
		TriggerClientEvent("CarryPeople:cl_declined", source, "Too far away!")
		return
	end

	if not Config.RequirePermission then
		StartCarrySession(source, targetSrc)
		return
	end

	pendingRequest[targetSrc] = source
	TriggerClientEvent("CarryPeople:askPermission", targetSrc, source, GetPlayerName(source))

	SetTimeout(Config.RequestTimeout, function()
		if pendingRequest[targetSrc] == source then
			pendingRequest[targetSrc] = nil
			TriggerClientEvent("CarryPeople:cl_declined", source, "They didn't respond in time.")
		end
	end)
end)

-- The target's response to a pending carry request.
RegisterServerEvent("CarryPeople:respond", function(requesterSrc, accepted)
	local source = source

	if pendingRequest[requesterSrc] ~= source then return end
	pendingRequest[requesterSrc] = nil

	if not accepted then
		TriggerClientEvent("CarryPeople:cl_declined", requesterSrc, "They declined.")
		return
	end

	if carrying[requesterSrc] or carried[requesterSrc] or not InRange(requesterSrc, source) then
		TriggerClientEvent("CarryPeople:cl_declined", requesterSrc, "They moved too far away.")
		return
	end

	StartCarrySession(requesterSrc, source)
end)

RegisterServerEvent("CarryPeople:stop", function(targetSrc)
	local source = source

	if carrying[source] then
		TriggerClientEvent("CarryPeople:cl_stop", targetSrc)
		carrying[source] = nil
		carried[targetSrc] = nil
	elseif carried[source] then
		TriggerClientEvent("CarryPeople:cl_stop", carried[source])			
		carrying[carried[source]] = nil
		carried[source] = nil
	end
end)

AddEventHandler('playerDropped', function(reason)
	local source = source

	if carrying[source] then
		TriggerClientEvent("CarryPeople:cl_stop", carrying[source])
		carried[carrying[source]] = nil
		carrying[source] = nil
	end

	if carried[source] then
		TriggerClientEvent("CarryPeople:cl_stop", carried[source])
		carrying[carried[source]] = nil
		carried[source] = nil
	end

	pendingRequest[source] = nil
	for targetSrc, requesterSrc in pairs(pendingRequest) do
		if requesterSrc == source then
			pendingRequest[targetSrc] = nil
		end
	end
end)
