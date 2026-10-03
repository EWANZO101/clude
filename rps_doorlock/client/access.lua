function CanAccessDoor(door, opCrimeId)
    local PlayerData = exports.rps_lib:GetPlayerData()
    local identifier = PlayerData.identifier
    local jobName = PlayerData.job and PlayerData.job.name or ''
    local jobGrade = PlayerData.job and PlayerData.job.grade and PlayerData.job.grade.level or 0

    -- rps_lib has no gang abstraction (QBCore-only concept), so gang data is
    -- only pulled directly from qb-core when it's actually the active framework.
    local gangName, gangGrade = '', 0
    if exports.rps_lib:GetFrameworkName() == 'qb' then
        local qbPlayerData = exports['qb-core']:GetCoreObject().Functions.GetPlayerData()
        gangName = qbPlayerData.gang and qbPlayerData.gang.name or ''
        gangGrade = qbPlayerData.gang and qbPlayerData.gang.grade and qbPlayerData.gang.grade.level or 0
    end

    local hasChars = door.chars and type(door.chars) == 'table' and #door.chars > 0
    local hasJobs = door.jobs and type(door.jobs) == 'table' and #door.jobs > 0
    local hasGangs = door.gangs and type(door.gangs) == 'table' and #door.gangs > 0

    if not hasChars and not hasJobs and not hasGangs then
        return true
    end

    if hasChars then
        for _, char in ipairs(door.chars) do
            if char.id == identifier then
                return true
            end
        end
    end

    if hasJobs then
        for _, job in ipairs(door.jobs) do
            if job.job == jobName and jobGrade >= tonumber(job.grade or 0) then
                return true
            end
        end
    end

    if hasGangs then
        for _, gang in ipairs(door.gangs) do
            if GetResourceState('op-crime') == 'started' then
                if opCrimeId and gang.gang == opCrimeId then
                    return true
                end
            else
                if gang.gang == gangName and gangGrade >= tonumber(gang.grade or 0) then
                    return true
                end
            end
        end
    end

    return false
end
