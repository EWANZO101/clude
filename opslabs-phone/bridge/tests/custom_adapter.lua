-- what a server owner would drop into bridge/custom/server/
Bridge.RegisterFramework('mycity', {
    label = 'My City Framework',
    detect = function() return true end,
    GetPlayer = function(src) return { identifier = 'mycity:' .. src, name = 'Citizen ' .. src } end,
})
