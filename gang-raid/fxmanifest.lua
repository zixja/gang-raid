fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'Gang Hideout Raid - Wave-based, Multi-location, QBCore/QBox/OX'
author      'Zix'
version     '1.0.0'

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

-- Optional (script works without these, features degrade gracefully):
-- 'qb-target'    or 'ox_target'    — entity interactions (REQUIRED in practice)
-- 'ox_lib'                          — skillcheck, progressbar, notify
-- 'ox_inventory'                    — falls back to qb-inventory if absent
-- 'ps-dispatch'                     — police alerts on raid start
