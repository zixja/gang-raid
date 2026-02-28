fx_version 'cerulean'
game 'gta5'

description 'Gang Hideout Raid - Wave-based, Multi-location, QBCore/QBox/ox compatible'
author 'Zix'
version '1.0.0'

shared_script 'config.lua'

client_scripts {
    'client.lua'
}

server_scripts {
    'server.lua'
}

-- Hard dependency: one of these must be running
dependencies {
    '/onesync',
    'qb-core',
}

-- Optional dependencies (script works without them but features degrade):
-- qb-target  OR  ox_target   → entity interactions
-- ox_inventory               → inventory fallback
-- ps-dispatch                → police alerts
-- ox_lib                     → notify fallback
