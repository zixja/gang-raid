fx_version 'cerulean'
game 'gta5'

description 'Gang Hideout Raid - Wave-based, Multi-location, QBCore/QBox/ox compatible'
author 'Decripterr'
version '2.0.0'

shared_script 'config.lua'

client_scripts {
    'client.lua'
}

server_scripts {
    'server.lua'
}

dependencies {
    'qb-core',
}

-- Optional dependencies (resource will still load without them)
-- 'qb-target' or 'ox_target'  — for interactions
-- 'ox_inventory'               — for inventory compatibility
-- 'ps-dispatch'                — for police alerts
