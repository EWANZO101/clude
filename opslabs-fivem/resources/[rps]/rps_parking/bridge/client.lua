-- ============================================
--  rps_lib Bridge (client)
--  Notifications go through rps_lib (ox_lib / codem / framework fallback).
-- ============================================
Bridge = {}

--- type: 'success' | 'error' | 'inform'/'info'
function Bridge.Notify(msg, type, title)
    if type == 'inform' or not type then type = 'info' end
    exports.rps_lib:ShowNotification({ title = title or 'Parking', description = msg, type = type })
end
