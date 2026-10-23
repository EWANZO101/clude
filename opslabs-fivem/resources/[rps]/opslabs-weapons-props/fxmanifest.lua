fx_version 'cerulean'
game 'gta5'

name 'opslabs-weapons-props'
description 'Crafted weapon display props (.50 cal pistol, Uzi, sawed-off, AK-47) for the OpsLabs weapon-crafting system'
author 'OpsLabs'
version '1.0.0'

-- stream/ is streamed automatically; the ytyps register the archetypes.
-- These are static display props (crafting-table / inventory world models), not functional
-- FiveM weapons -- they carry no weapons.meta entry, no animations, no WEAPON_ hash.
files {
    'stream/opslabs_wp_pistol50.ytyp',
    'stream/opslabs_wp_uzi.ytyp',
    'stream/opslabs_wp_sawedoff.ytyp',
    'stream/opslabs_wp_ak47.ytyp',
}

data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_wp_pistol50.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_wp_uzi.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_wp_sawedoff.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_wp_ak47.ytyp'
