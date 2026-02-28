-- =============================================
-- GANG HIDEOUT RAID | server.lua  v3.0
-- Peds are created SERVER-SIDE so they are
-- network-synced and visible to ALL players.
-- Compatible: QBCore / QBox | ox_inventory
-- =============================================

local QBCore              = nil
local raidActive          = false
local raidCooldownEnd     = 0
local spawnedPeds         = {}   -- { handle, netId } per ped
local currentWave         = 0
local activeLocation      = nil
local waveMonitorRunning  = false

-- =============================================
-- FRAMEWORK INIT
-- =============================================
CreateThread(function()
    Wait(500)
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and obj then
        QBCore = obj
        if Config.Debug then print('[GHR] QBCore/QBox loaded.') end
    else
        if Config.Debug then print('[GHR] QBCore not found — ox_inventory only mode.') end
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
-- SERVER-SIDE PED SPAWN
-- networked = true  →  synced to all clients
-- =============================================
local function SpawnPedServer(guardData)
    local c = guardData.coords

    local ped = CreatePed(
        4,                          -- ped type (gang)
        GetHashKey(guardData.model),
        c.x, c.y, c.z - 1.0, c.w,
        true,                       -- networked  ← key flag
        true                        -- mission entity
    )

    if not DoesEntityExist(ped) then
        if Config.Debug then print('[GHR] Failed to create ped: ' .. guardData.model) end
        return nil, nil
    end

    SetEntityAsMissionEntity(ped, true, true)
    SetPedArmour(ped, guardData.armor or 100)
    SetPedCanRagdoll(ped, true)
    GiveWeaponToPed(ped, GetHashKey(guardData.weapon), 500, false, true)

    local netId = NetworkGetNetworkIdFromEntity(ped)

    if Config.Debug then
        print('[GHR] Ped spawned: ' .. guardData.model .. ' netId=' .. tostring(netId))
    end

    return ped, netId
end

-- =============================================
-- SPAWN WAVE  (server-side, all peds synced)
-- After spawning, clients are told the netIds
-- so they can resolve local handles and apply
-- combat tasks (which must be client-side).
-- =============================================
local function SpawnWave(waveData)
    spawnedPeds = {}
    local netIds = {}

    for _, guard in ipairs(waveData) do
        local ped, netId = SpawnPedServer(guard)
        if ped and netId then
            table.insert(spawnedPeds, { handle = ped, netId = netId, accuracy = guard.accuracy or 70 })
            table.insert(netIds, { netId = netId, weapon = guard.weapon, accuracy = guard.accuracy or 70 })
        end
        Wait(50) -- stagger slightly to avoid engine hiccup
    end

    -- Tell every client the netIds of the new wave so they can:
    -- 1. Resolve the local entity handle
    -- 2. Set relationship groups and combat tasks
    TriggerClientEvent('gang_hideout:configurePeds', -1, netIds)
end

-- =============================================
-- SPAWN ESCAPE VEHICLE  (server-side, synced)
-- =============================================
local function SpawnEscapeVehicle(vehData)
    if not Config.EscapeVehicleEnabled then return end

    local c   = vehData.coords
    local veh = CreateVehicle(GetHashKey(vehData.model), c.x, c.y, c.z, c.w, true, false)
    if not DoesEntityExist(veh) then return end

    SetEntityAsMissionEntity(veh, true, true)

    local driver = CreatePedInsideVehicle(veh, 4, GetHashKey('g_m_y_ballasout_01'), -1, true, true)
    SetEntityAsMissionEntity(driver, true, true)
    GiveWeaponToPed(driver, GetHashKey('WEAPON_PISTOL'), 200, false, true)
    SetPedArmour(driver, 50)

    local driverNetId = NetworkGetNetworkIdFromEntity(driver)

    -- Clients apply the drive task (TaskVehicleDriveToCoord must be client-side)
    TriggerClientEvent('gang_hideout:driveEscapeVehicle', -1,
        driverNetId,
        activeLocation.blip.coords.x,
        activeLocation.blip.coords.y,
        activeLocation.blip.coords.z)

    NotifyAll('⚠ Enemy reinforcements are inbound!', 'error')
end

-- =============================================
-- WAVE MONITOR  (server-side health checks)
-- =============================================
local function StartWaveMonitor()
    if waveMonitorRunning then return end
    waveMonitorRunning = true

    CreateThread(function()
        -- Give peds a moment to fully spawn before we start checking
        Wait(8000)

        while raidActive do
            Wait(5000)

            if #spawnedPeds == 0 then
                -- Wave hasn't populated yet, keep waiting
                goto continue
            end

            local aliveCount = 0
            for _, entry in ipairs(spawnedPeds) do
                if DoesEntityExist(entry.handle) and not IsEntityDead(entry.handle) then
                    aliveCount = aliveCount + 1
                end
            end

            if aliveCount == 0 then
                -- Clean up dead bodies after a short delay
                for _, entry in ipairs(spawnedPeds) do
                    local handle = entry.handle
                    SetTimeout(12000, function()
                        if DoesEntityExist(handle) then DeleteEntity(handle) end
                    end)
                end
                spawnedPeds = {}

                currentWave = currentWave + 1

                if currentWave > Config.MaxWaves then
                    -- ===== RAID COMPLETE =====
                    raidActive         = false
                    waveMonitorRunning = false
                    TriggerClientEvent('gang_hideout:raidFinished', -1)
                    if Config.Debug then print('[GHR] Raid complete — all waves cleared.') end
                    return
                else
                    -- ===== NEXT WAVE =====
                    NotifyAll('⚡ Wave ' .. currentWave .. ' incoming in ' .. Config.WaveDelay .. 's!', 'error')

                    if Config.Debug then print('[GHR] Waiting ' .. Config.WaveDelay .. 's before wave ' .. currentWave) end
                    Wait(Config.WaveDelay * 1000)

                    local waveData = activeLocation.waves[currentWave]
                    if waveData then
                        SpawnWave(waveData)
                        if Config.Debug then print('[GHR] Wave ' .. currentWave .. ' spawned.') end
                    end

                    if currentWave == Config.MaxWaves then
                        SpawnEscapeVehicle(activeLocation.escapeVehicle)
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

-- Player presses "Start Raid" on the NPC
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
    spawnedPeds     = {}

    local locationIndex = math.random(1, #Config.Locations)
    activeLocation      = Config.Locations[locationIndex]

    if Config.Debug then
        print('[GHR] Raid started by player ' .. src .. ' at: ' .. activeLocation.name)
    end

    -- Tell ALL clients to show the blip and spawn loot crates
    -- (crates are client-local props — that's intentional and fine;
    --  only the loot trigger goes to the server, preventing duplication)
    TriggerClientEvent('gang_hideout:raidStarted', -1, locationIndex)

    -- Give the client event a tiny head-start before peds appear
    SetTimeout(600, function()
        SpawnWave(activeLocation.waves[1])
        StartWaveMonitor()
    end)

    SetTimeout(2500, function()
        SendDispatch(src, activeLocation.blip.coords)
    end)
end)

-- Player opens a loot crate
RegisterNetEvent('gang_hideout:giveLoot', function()
    local src    = source
    local Player = GetPlayer(src)
    if not Player and Config.InventoryExport ~= 'ox_inventory' then return end

    local shuffled = {}
    for _, v in ipairs(Config.LootTable) do shuffled[#shuffled + 1] = v end
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
                NotifyClient(src, 'Found ' .. amount .. 'x ' .. item.name, 'success')
                rewarded = true
                break
            end
        end
    end

    if not rewarded then
        NotifyClient(src, 'The crate was empty.', 'error')
    end
end)

-- Player claims their completion bonus after raid finishes
RegisterNetEvent('gang_hideout:claimBonus', function()
    local src = source
    if raidActive then return end  -- sanity check
    local Player = GetPlayer(src)
    if not Player then return end

    local bonus = math.random(500, 1500)
    if AddItem(src, 'markedmoney', bonus) then
        SendItemNotify(src, 'markedmoney', bonus, 'add')
        NotifyClient(src, '🏆 Raid bonus: $' .. bonus .. ' in marked bills!', 'success')
        if Config.Debug then print('[GHR] Bonus $' .. bonus .. ' paid to player ' .. src) end
    end
end)
