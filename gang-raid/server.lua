-- =============================================
-- GANG HIDEOUT RAID | server.lua  v5.0
-- =============================================

local QBCore             = nil
local raidActive         = false
local raidCooldownEnd    = 0
local currentWave        = 0
local activeLocation     = nil
local waveMonitorRunning = false
local raidStarterSrc     = nil
local waveNetIds         = {}

-- =============================================
-- FRAMEWORK INIT
-- =============================================
CreateThread(function()
    Wait(500)
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and obj then
        QBCore = obj
        if Config.Debug then print('[gang-raid] QBCore/QBox loaded.') end
    else
        if Config.Debug then print('[gang-raid] QBCore not found — ox_inventory only mode.') end
    end
end)

-- =============================================
-- HELPERS
-- =============================================
local function GetPlayer(src)
    if QBCore then return QBCore.Functions.GetPlayer(src) end
    return nil
end

local function NotifyClient(src, msg, ntype)
    ntype = ntype or 'primary'
    if QBCore then
        TriggerClientEvent('QBCore:Notify', src, msg, ntype)
    else
        TriggerClientEvent('ox_lib:notify', src, { title = msg, type = ntype })
    end
end

local function NotifyAll(msg, ntype)
    ntype = ntype or 'primary'
    if QBCore then
        TriggerClientEvent('QBCore:Notify', -1, msg, ntype)
    else
        TriggerClientEvent('ox_lib:notify', -1, { title = msg, type = ntype })
    end
end

local function AddItem(src, itemName, amount)
    if Config.InventoryExport == 'ox_inventory'
    or (Config.InventoryExport == 'auto' and GetResourceState('ox_inventory') == 'started') then
        local ok = pcall(function() exports['ox_inventory']:AddItem(src, itemName, amount) end)
        if ok then return true end
    end
    local Player = GetPlayer(src)
    if Player then
        Player.Functions.AddItem(itemName, amount)
        return true
    end
    return false
end

local function SendItemNotify(src, itemName, amount, action)
    if QBCore then
        local item = QBCore.Shared.Items and QBCore.Shared.Items[itemName]
        if item then
            TriggerClientEvent('inventory:client:ItemBox', src, item, action or 'add', amount)
        end
    end
end

local function SendDispatch(src, coords)
    if not Config.DispatchEnabled then return end
    if GetResourceState('ps-dispatch') ~= 'started' then return end
    local ok = pcall(function()
        exports['ps-dispatch']:CustomAlert({
            coords       = coords,
            message      = Config.Dispatch.message,
            dispatchCode = Config.Dispatch.code,
            description  = Config.Dispatch.title,
            radius       = 0,
            sprite       = Config.Dispatch.blip.sprite,
            color        = Config.Dispatch.blip.color,
            scale        = 1.0,
            length       = 3,
            jobs         = Config.Dispatch.jobs,
        })
    end)
    if not ok then
        pcall(function()
            TriggerEvent('dispatch:server:notify', {
                dispatchCode = Config.Dispatch.code,
                description  = Config.Dispatch.title,
                message      = Config.Dispatch.message,
                jobs         = Config.Dispatch.jobs,
                coords       = coords,
                sprite       = Config.Dispatch.blip.sprite,
                colour       = Config.Dispatch.blip.color,
            })
        end)
    end
end

-- =============================================
-- SHARED LOOT ROLL
-- Used by both crate looting and guard looting.
-- =============================================
local function RollLoot(src)
    local shuffled = {}
    for _, v in ipairs(Config.LootTable) do shuffled[#shuffled + 1] = v end
    for i = #shuffled, 2, -1 do
        local j = math.random(i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end

    for _, item in ipairs(shuffled) do
        if math.random(100) <= item.chance then
            local amount = math.random(item.amount.min, item.amount.max)
            if AddItem(src, item.name, amount) then
                SendItemNotify(src, item.name, amount, 'add')
                NotifyClient(src, 'Found ' .. amount .. 'x ' .. item.name, 'success')
                return true
            end
        end
    end
    return false
end

-- =============================================
-- WAVE MONITOR
-- =============================================
local function StartWaveMonitor()
    if waveMonitorRunning then return end
    waveMonitorRunning = true

    CreateThread(function()
        Wait(10000)

        while raidActive do
            Wait(5000)

            if #waveNetIds == 0 then goto continue end

            local aliveCount = 0
            local toDelete   = {}

            for _, netId in ipairs(waveNetIds) do
                if NetworkDoesEntityExistWithNetworkId(netId) then
                    local ped = NetworkGetEntityFromNetworkId(netId)
                    if DoesEntityExist(ped) then
                        if IsEntityDead(ped) then
                            table.insert(toDelete, ped)
                        else
                            aliveCount = aliveCount + 1
                        end
                    end
                end
            end

            -- Clean up corpses after a delay (gives players time to loot)
            for _, deadPed in ipairs(toDelete) do
                local p = deadPed
                SetTimeout(30000, function()
                    if DoesEntityExist(p) then DeleteEntity(p) end
                end)
            end

            if aliveCount == 0 then
                waveNetIds  = {}
                currentWave = currentWave + 1

                if currentWave > Config.MaxWaves then
                    raidActive         = false
                    waveMonitorRunning = false
                    TriggerClientEvent('gang_hideout:raidFinished', -1)
                    if Config.Debug then print('[gang-raid] Raid complete.') end
                    return
                else
                    NotifyAll('Wave ' .. currentWave .. ' incoming in ' .. Config.WaveDelay .. 's!', 'error')
                    Wait(Config.WaveDelay * 1000)

                    if raidStarterSrc then
                        TriggerClientEvent('gang_hideout:spawnWave', raidStarterSrc,
                            activeLocation.waves[currentWave], currentWave)

                        if currentWave == Config.MaxWaves then
                            TriggerClientEvent('gang_hideout:spawnEscapeVehicle', raidStarterSrc,
                                activeLocation.escapeVehicle)
                        end
                    end
                end
            end

            ::continue::
        end

        waveMonitorRunning = false
    end)
end

-- =============================================
-- NET EVENTS
-- =============================================
RegisterNetEvent('gang_hideout:startRaid', function()
    local src = source

    if raidActive then
        NotifyClient(src, 'A raid is already in progress!', 'error')
        return
    end

    local now = os.time()
    if now < raidCooldownEnd then
        NotifyClient(src, 'Raid on cooldown for ' .. (raidCooldownEnd - now) .. 's.', 'error')
        return
    end

    raidActive      = true
    raidCooldownEnd = now + Config.RaidCooldown
    currentWave     = 1
    waveNetIds      = {}
    raidStarterSrc  = src

    local locationIndex = math.random(1, #Config.Locations)
    activeLocation      = Config.Locations[locationIndex]

    if Config.Debug then
        print('[gang-raid] Raid started by ' .. src .. ' at: ' .. activeLocation.name)
    end

    TriggerClientEvent('gang_hideout:raidStarted', -1, locationIndex)

    SetTimeout(800, function()
        TriggerClientEvent('gang_hideout:spawnWave', src,
            activeLocation.waves[currentWave], currentWave)
    end)

    SetTimeout(3000, function()
        SendDispatch(src, activeLocation.blip.coords)
    end)
end)

RegisterNetEvent('gang_hideout:waveSpawned', function(netIds)
    local src = source
    if src ~= raidStarterSrc then return end
    waveNetIds = netIds
    if Config.Debug then
        print('[gang-raid] Wave ' .. currentWave .. ' has ' .. #netIds .. ' peds.')
    end
    TriggerClientEvent('gang_hideout:configurePeds', -1, netIds)
    StartWaveMonitor()
end)

RegisterNetEvent('gang_hideout:escapeVehicleSpawned', function(driverNetId)
    TriggerClientEvent('gang_hideout:driveEscapeVehicle', -1,
        driverNetId,
        activeLocation.blip.coords.x,
        activeLocation.blip.coords.y,
        activeLocation.blip.coords.z)
    NotifyAll('Enemy reinforcements are inbound!', 'error')
end)

-- Crate loot
RegisterNetEvent('gang_hideout:giveLoot', function()
    local src    = source
    local Player = GetPlayer(src)
    if not Player and Config.InventoryExport ~= 'ox_inventory' then return end

    if not RollLoot(src) then
        NotifyClient(src, 'The crate was empty.', 'error')
    end
end)

-- Guard body loot
-- Guards carry less than crates on average since they're an extra reward.
-- Rolls from the same loot table but with a reduced chance per item.
RegisterNetEvent('gang_hideout:lootGuard', function()
    local src    = source
    local Player = GetPlayer(src)
    if not Player and Config.InventoryExport ~= 'ox_inventory' then return end

    -- Guards have a 50% chance of carrying anything at all
    if math.random(100) > 50 then
        NotifyClient(src, 'Nothing of value on the body.', 'error')
        return
    end

    -- Use a reduced loot table (half the chance values)
    local shuffled = {}
    for _, v in ipairs(Config.LootTable) do
        shuffled[#shuffled + 1] = {
            name   = v.name,
            amount = { min = v.amount.min, max = math.max(v.amount.min, math.floor(v.amount.max * 0.5)) },
            chance = math.floor(v.chance * 0.5),
        }
    end
    for i = #shuffled, 2, -1 do
        local j = math.random(i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end

    local rewarded = false
    for _, item in ipairs(shuffled) do
        if math.random(100) <= item.chance then
            local amount = math.random(item.amount.min, item.amount.max)
            if AddItem(src, item.name, amount) then
                SendItemNotify(src, item.name, amount, 'add')
                NotifyClient(src, 'Found ' .. amount .. 'x ' .. item.name .. ' on the body.', 'success')
                rewarded = true
                break
            end
        end
    end

    if not rewarded then
        NotifyClient(src, 'Nothing of value on the body.', 'error')
    end
end)

-- Completion bonus
RegisterNetEvent('gang_hideout:claimBonus', function()
    local src = source
    if raidActive then return end
    local Player = GetPlayer(src)
    if not Player then return end

    local bonus = math.random(500, 1500)
    if AddItem(src, 'markedmoney', bonus) then
        SendItemNotify(src, 'markedmoney', bonus, 'add')
        NotifyClient(src, 'Raid bonus: $' .. bonus .. ' in marked bills!', 'success')
    end
end)
