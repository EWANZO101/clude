RegisterCommand(Config.Command, function(source, args)
    if IsAdmin(source) then
        local formattedJobs = {}
        for k, v in pairs(exports.rps_lib:GetJobs() or {}) do
            local grades = {}
            if v.grades then
                for gradeLevel, gradeData in pairs(v.grades) do
                    -- QBCore grades use `.name`, ESX grades use `.label` for the same field.
                    grades[tostring(gradeLevel)] = { name = gradeData.name or gradeData.label }
                end
            end
            formattedJobs[k] = {
                label = v.label or k,
                grades = grades
            }
        end

        -- rps_lib has no gang abstraction (QBCore-only concept), so gang
        -- access is only populated via the op-crime integration below.
        local formattedGangs = {}
        if GetResourceState('op-crime') == 'started' then
            local opGangs = exports['op-crime']:getOrganisationsList()
            if opGangs then
                for _, org in pairs(opGangs) do
                    formattedGangs[tostring(org.identifier)] = {
                        label = (org.label or tostring(org.identifier)) .. " (Op-Crime)",
                        grades = {
                            ["0"] = { name = "Member" }
                        }
                    }
                end
            end
        end

        TriggerClientEvent('rps_doorlock:client:OpenUI', source, formattedJobs, formattedGangs)
    else
        exports.rps_lib:Notify(source, "You do not have permission to use this.", "error")
    end
end, false)
