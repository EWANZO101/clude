fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'opslabs-towers'
description 'Cell towers and Wi-Fi access points for opslabs-phone (OPS Mobile coverage)'
author 'OpsLabs'
version '1.0.0'

dependencies { 'oxmysql', 'ox_lib', 'rps_lib' }   -- framework (ESX / QBCore / QBox) through rps_lib

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/opsconnect.lua',            -- multi-server: OPS tables → hosted OPS Hub database when connected (opslabs-connect)
    'server/settings.lua',
    'server/framework.lua',
    'server/main.lua',
    'server/api.lua',
    'server/cabling.lua',
    'server/isp.lua',
    'server/ladders.lua',
    'server/doors.lua',
    'server/tools.lua',
    'server/uniform.lua',
    'server/faults.lua',
    'server/guys.lua',
    'server/van.lua',
    'server/phoneline.lua',
    'server/laptop.lua',
    'server/mains.lua',
    'server/netpower.lua',
    'server/ontrepair.lua',
    'server/gunshots.lua',
    'server/grid.lua',
    'server/powerdiag.lua',
    'server/powerline.lua',
    'server/danger.lua',
    'server/citybuild.lua',
    'server/fuel.lua',
    'server/track.lua',
    'server/showcase.lua',
    'server/platformhooks.lua',
    'server/cctv.lua',
    'server/cctvlive.lua',
    'server/opsisp.lua',
    'server/datacentre.lua',
}

client_scripts {
    'client/settings.lua',
    'client/brandtext.lua',
    'client/menu.lua',
    'client/console.lua',
    'client/main.lua',
    'client/worldpoles.lua',
    'client/cabling.lua',
    'client/poles.lua',
    'client/ladders.lua',
    'client/ont.lua',
    'client/roadworks.lua',
    'client/lighting.lua',
    'client/faults.lua',
    'client/harness.lua',
    'client/guys.lua',
    'client/coach.lua',
    'client/doors.lua',
    'client/van.lua',
    'client/vanspot.lua',
    'client/underground.lua',
    'client/tools.lua',
    'client/worldcleanup.lua',
    'client/anticlimb.lua',
    'client/uniform.lua',
    'client/laptop.lua',
    'client/mains.lua',
    'client/gunshots.lua',
    'client/grid.lua',
    'client/powerline.lua',
    'client/danger.lua',
    'client/target.lua',
    'client/citybuild.lua',
    'client/fuel.lua',
    'client/track.lua',
    'client/showcase.lua',
    'client/cctv.lua',
    'client/cctvlive.lua',
    'client/datacentre.lua',
}

ui_page 'html/index.html'
files { 'html/index.html', 'html/sign.html', 'html/brand.html', 'html/fencesign.html', 'html/console.css', 'html/console.js', 'html/cctvcap.js',
    'html/vendor/fontawesome/css/*.css', 'html/vendor/fontawesome/webfonts/*.woff2', 'html/vendor/inter/*' }
