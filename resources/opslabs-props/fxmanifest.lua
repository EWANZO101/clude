fx_version 'cerulean'
game 'gta5'

name 'opslabs-props'
description 'Custom props for OpsLabs (UniFi-style network gear for opslabs-towers)'
author 'OpsLabs'
version '1.4.0'

-- stream/ is streamed automatically; the ytyp registers the archetypes
files {
    'stream/opslabs_wifi_props.ytyp',
    'stream/opslabs_network_props.ytyp',
    'stream/opslabs_cabling_props.ytyp',
    'stream/opslabs_telecom_props.ytyp',
    'stream/opslabs_tplink_props.ytyp',
    'stream/opslabs_ladder_props.ytyp',
}
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_wifi_props.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_network_props.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_cabling_props.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_telecom_props.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_tplink_props.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/opslabs_ladder_props.ytyp'
