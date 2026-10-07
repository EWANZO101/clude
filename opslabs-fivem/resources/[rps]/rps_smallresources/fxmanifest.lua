fx_version 'cerulean'

game 'gta5'

lua54 'yes'

name 'rps_smallresources'

author 'Realplay Scrips'

description 'rps_smallresources - bundle of small standalone client scripts'

version '1.0.3'



shared_scripts {
    '@ox_lib/init.lua',
    '@opslabs-license/guard.lua',     -- OPSHUB: every player action is checked (opslabs-license)
    'rps_vehicleradio/vehicleradio_config.lua',   -- must load before cl_vehicleradio.lua
    'rps_carry/config.lua',                       -- must load before cl_carry.lua / sv_carry.lua
}

client_scripts {
    'rps_handsup/cl_handsup.lua',
    'rps_vehicleradio/cl_vehicleradio.lua',
    'rps_carry/cl_carry.lua',
    'rps_escmap/cl_escmap.lua',
    'rps_crosshair/cl_crosshair.lua',
    'rps_point/cl_point.lua',
    -- add more small scripts here as you create them, e.g.:
    -- 'cl_seatbelt.lua',
}

server_scripts {
    'rps_carry/sv_carry.lua',
}

dependencies {
    'ox_lib',
    'rps_lib',
}

escrow_ignore {
    'rps_vehicleradio/vehicleradio_config.lua',
    'rps_carry/config.lua',
}

dependency 'opslabs-license'   -- OPSHUB licensing: nothing runs without it
