fx_version 'cerulean'

game 'gta5'

lua54 'yes'

name 'rps_lib'

author 'real play scripts'

description 'Framework-agnostic utility library for ESX / QBCore / QBox / standalone'

version '3.1.2'

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

-- Loaded before our own init.lua so this resource's own lib.table / lib.string /
-- lib.math / lib.print win the collision with ox_lib's identically-named fields
-- on the shared 'lib' global (see README.md "Notes" for details).

-- Shared (both sides) — order matters: each of these depends on the ones above it.
shared_scripts {
    '@ox_lib/init.lua',
    '@opslabs-license/guard.lua',     -- OPSHUB: every player action is checked (opslabs-license)
    'init.lua',
    'config.lua',
    'shared/utils.lua',
    'framework/init.lua',
    'integrations/garages/init.lua',
    'integrations/progressbar/init.lua',
    'integrations/ambulancejob/init.lua',
    'integrations/notifications/init.lua',
    'integrations/inventory/init.lua',
    'integrations/phone/init.lua',
    'integrations/bank/init.lua'
}

-- Client-only
client_scripts {
    'framework/esx/client.lua',
    'framework/qb/client.lua',
    'framework/qbox/client.lua',
    'framework/standalone/client.lua',
    'integrations/garages/qb-garage/client.lua',
    'integrations/garages/qbox-garage/client.lua',
    'integrations/garages/esx-garage/client.lua',
    'integrations/garages/none/client.lua',
    'integrations/progressbar/ox_lib/client.lua',
    'integrations/progressbar/none/client.lua',
    'integrations/ambulancejob/esx_ambulancejob/client.lua',
    'integrations/ambulancejob/qb-ambulancejob/client.lua',
    'integrations/ambulancejob/qbx_ambulancejob/client.lua',
    'integrations/ambulancejob/none/client.lua',
    'integrations/notifications/ox_lib/client.lua',
    'integrations/notifications/codem/client.lua',
    'integrations/notifications/none/client.lua',
    'integrations/inventory/ox_inventory/client.lua',
    'integrations/inventory/tgiann-inventory/client.lua',
    'integrations/inventory/qb-inventory/client.lua',
    'integrations/inventory/ps-inventory/client.lua',
    'integrations/inventory/lj-inventory/client.lua',
    'integrations/inventory/none/client.lua',
    'integrations/target/init.lua',
    'integrations/target/ox_target/client.lua',
    'integrations/target/tgiann-target/client.lua',
    'integrations/target/qb-target/client.lua',
    'integrations/target/none/client.lua',
    'integrations/phone/lb_phone/client.lua',
    'integrations/phone/qb_phone/client.lua',
    'integrations/phone/none/client.lua',
    'integrations/bank/qb-banking/client.lua',
    'integrations/bank/renewed-banking/client.lua',
    'integrations/bank/qbox/client.lua',
    'integrations/bank/none/client.lua',
    'client/3dtext.lua',
    'client/client.lua'
}

-- Server-only
server_scripts {
    'framework/esx/server.lua',
    'framework/qb/server.lua',
    'framework/qbox/server.lua',
    'framework/standalone/server.lua',
    'integrations/garages/qb-garage/server.lua',
    'integrations/garages/qbox-garage/server.lua',
    'integrations/garages/esx-garage/server.lua',
    'integrations/garages/none/server.lua',
    'integrations/progressbar/ox_lib/server.lua',
    'integrations/progressbar/none/server.lua',
    'integrations/ambulancejob/esx_ambulancejob/server.lua',
    'integrations/ambulancejob/qb-ambulancejob/server.lua',
    'integrations/ambulancejob/qbx_ambulancejob/server.lua',
    'integrations/ambulancejob/none/server.lua',
    'integrations/notifications/ox_lib/server.lua',
    'integrations/notifications/codem/server.lua',
    'integrations/notifications/none/server.lua',
    'integrations/inventory/ox_inventory/server.lua',
    'integrations/inventory/tgiann-inventory/server.lua',
    'integrations/inventory/qb-inventory/server.lua',
    'integrations/inventory/ps-inventory/server.lua',
    'integrations/inventory/lj-inventory/server.lua',
    'integrations/inventory/none/server.lua',
    'integrations/phone/lb_phone/server.lua',
    'integrations/phone/qb_phone/server.lua',
    'integrations/phone/none/server.lua',
    'integrations/bank/qb-banking/server.lua',
    'integrations/bank/renewed-banking/server.lua',
    'integrations/bank/qbox/server.lua',
    'integrations/bank/none/server.lua',
    'server/server.lua'
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

-- Client exports
exports {
    'GetFrameworkName',
    'GetPlayerData',
    'Notify',
    'TriggerServerCallback',
    'RegisterClientCallback',
    'GetGarageName',
    'OpenGarage',
    'GetProgressBarName',
    'ProgressBar',
    'GetAmbulanceJobName',
    'IsPlayerDead',
    'RevivePlayer',
    'GetNotificationModuleName',
    'ShowNotification',
    'GetInventoryName',
    'HasItem',
    'GetItemCount',
    'GetTargetName',
    'AddBoxZone',
    'AddEntityTarget',
    'AddModelTarget',
    'RemoveZone',
    'RemoveEntityTarget',
    'DrawText3D',
    'DrawText3DSimple',
    'GetPhoneName',
    'OpenPhone',
    'PhoneNotification',
    'AddPhoneContact',
    'GetPhoneNumber',
    'GetBankName',
    'OpenBank'
}

-- Server exports
server_exports {
    'GetFrameworkName',
    'GetPlayerData',
    'GetIdentifier',
    'Notify',
    'AddMoney',
    'RemoveMoney',
    'GetMoney',
    'RegisterServerCallback',
    'TriggerClientCallback',
    'GetGarageName',
    'GetPlayerVehicles',
    'IsVehicleStored',
    'SetVehicleStored',
    'GetProgressBarName',
    'ServerProgressBar',
    'GetAmbulanceJobName',
    'IsPlayerDead',
    'RevivePlayer',
    'GetNotificationModuleName',
    'ShowNotification',
    'GetInventoryName',
    'HasItem',
    'GetItemCount',
    'AddItem',
    'RemoveItem',
    'GetInventory',
    'ClearInventory',
    'CanCarryItem',
    'GetItemDefinition',
    'GetItemCatalog',
    'GetJobs',
    'SetPlayerJob',
    'SetJob',
    'HasPermission',
    'CreateUseableItem',
    'GetOfflinePlayer',
    'GetEmployeesByJob',
    'GetAllCharacters',
    'SetOfflinePlayerJob',
    'AddOfflinePlayerMoney',
    'GetPhoneName',
    'SendPhoneMessage',
    'StartPhoneCall',
    'AddPhoneTweet',
    'SendPhoneBankingNotification',
    'GetBankName',
    'GetAccountBalance',
    'AddAccountMoney',
    'RemoveAccountMoney',
    'TransferAccountMoney'
}

dependency {
    'ox_lib'
}

escrow_ignore {
    'config.lua',
    'integrations/**/**.lua'
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--]]

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
