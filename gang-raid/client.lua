-- =============================================
-- GANG HIDEOUT RAID | client.lua  v5.0
-- Supports: qb-target / ox_target (auto-detect)
--           QBCore / QBox / ox_lib notify
-- =============================================

local QBCore             = nil
local lootedCrates       = {}
local spawnedGuards      = {}   -- { ped = handle, looted = bool }
local lootedGuards       = {}   -- [ped handle] = true
local activeLocation     = nil
local activeBlip         = nil
local lootMonitorRunning = false

-- Init QBCore if available
local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
if ok and obj then QBCore = obj end

-- =============================================
-- NOTIFY HELPER
-- =============================================
local function Notify(msg, ntype)
    ntype = ntype or 'primary'
    if QBCore then
        QBCore.Functions.Notify(msg, ntype)
    elseif GetResourceState('ox_lib') == 'started' then
        exports['ox_lib']:notify({ description = msg, type = ntype })
    end
end

-- =============================================
-- TARGET COMPATIBILITY LAYER
-- =============================================
local TargetLib = nil

local function GetTargetLib()
    if TargetLib and TargetLib ~= 'none' then return TargetLib end
    local cfg = Config.TargetExport
    if cfg == 'ox_target' or (cfg == 'auto' and GetResourceState('ox_target') == 'started') then
        TargetLib = 'ox_target'
    elseif cfg == 'qb-target' or (cfg == 'auto' and GetResourceState('qb-target') == 'started') then
        TargetLib = 'qb-target'
    else
        TargetLib = 'none'
    end
    if Config.Debug then print('[gang-raid] Target lib: ' .. TargetLib) end
    return TargetLib
end

local function WaitForTargetLib()
    local attempts = 0
    while GetTargetLib() == 'none' and attempts < 40 do
        Wait(500)
        attempts = attempts + 1
    end
    if TargetLib == 'none' then
        print('^1[gang-raid] ERROR: No target resource found. Ensure qb-target or ox_target starts before gang-raid.^7')
    end
end

local function AddEntityTarget(entity, label, icon, distance, action)
    local lib = GetTargetLib()
    if lib == 'ox_target' then
        exports['ox_target']:addLocalEntity(entity, {
            {
                name     = 'gr_' .. tostring(entity),
                label    = label,
                icon     = icon,
                distance = distance,
                onSelect = action,
            }
        })
    elseif lib == 'qb-target' then
        exports['qb-target']:AddTargetEntity(entity, {
            options  = { { label = label, icon = icon, action = action } },
            distance = distance,
        })
    end
end

local function RemoveEntityTarget(entity)
    local lib = GetTargetLib()
    if lib == 'ox_target' then
        exports['ox_target']:removeLocalEntity(entity)
    elseif lib == 'qb-target' then
        exports['qb-target']:RemoveTargetEntity(entity)
    end
end

-- =============================================
-- GUARD RELATIONSHIPS
-- GTA relationship groups are client-local, so
-- this must run on every player's machine.
-- =============================================
local function SetupGuardRelationships()
    local groupName   = "HIDEOUT_GUARDS"
    local groupHash   = GetHashKey(groupName)
    local playerGroup = GetHashKey("PLAYER")

    AddRelationshipGroup(groupName)
    SetRelationshipBetweenGroups(5, groupHash, playerGroup)
    SetRelationshipBetweenGroups(5, playerGroup, groupHash)
    SetRelationshipBetweenGroups(5, groupHash, GetHashKey("CIVMALE"))
    SetRelationshipBetweenGroups(5, groupHash, GetHashKey("CIVFEMALE"))

    return groupHash
end

-- =============================================
-- APPLY COMBAT SETTINGS
-- Combat attribute 14 = attack player on sight
-- Combat attribute 52 = attack when spotted
-- SetPedAlertness(3)  = fully combat-alerted
-- These three together make guards shoot first.
-- =============================================
local function ApplyCombatSettings(ped, groupHash)
    SetPedRelationshipGroupHash(ped, groupHash)
    SetPedAsEnemy(ped, true)
    SetPedAlertness(ped, 3)

    SetPedCombatAttributes(ped, 0,  true)
    SetPedCombatAttributes(ped, 2,  true)
    SetPedCombatAttributes(ped, 5,  true)
    SetPedCombatAttributes(ped, 14, true)  -- attack player on sight (KEY)
    SetPedCombatAttributes(ped, 17, true)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAttributes(ped, 52, true)  -- attack when spotted (KEY)

    SetPedCombatRange(ped, 2)
    SetPedCombatAbility(ped, 2)
    SetPedCombatMovement(ped, 2)

    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedDiesWhenInjured(ped, false)

    TaskCombatHatedTargetsAroundPed(ped, 60.0, 0)
end

-- =============================================
-- LOOT MONITOR
-- Watches spawnedGuards every second for newly
-- dead peds, then adds a Search Body target.
-- =============================================
local function StartLootMonitor()
    if lootMonitorRunning then return end
    lootMonitorRunning = true

    CreateThread(function()
        while lootMonitorRunning do
            Wait(1000)

            for _, entry in ipairs(spawnedGuards) do
                local ped = entry.ped
                if not entry.looted
                and DoesEntityExist(ped)
                and IsEntityDead(ped)
                and not lootedGuards[ped] then

                    lootedGuards[ped] = true
                    entry.looted      = true

                    local p = ped
                    SetTimeout(1500, function()
                        if not DoesEntityExist(p) then return end
                        AddEntityTarget(p, "Search Body", "fas fa-search", 1.5, function(entity)
                            RemoveEntityTarget(entity)
                            TriggerServerEvent("gang_hideout:lootGuard")
                        end)
                    end)
                end
            end
        end
    end)
end

-- =============================================
-- RAID STARTED — fires on ALL clients
-- =============================================
RegisterNetEvent('gang_hideout:raidStarted', function(locationIndex)
    lootedCrates       = {}
    lootedGuards       = {}
    spawnedGuards      = {}
    lootMonitorRunning = false
    activeLocation     = Config.Locations[locationIndex]

    if activeBlip then RemoveBlip(activeBlip) end
    local b    = activeLocation.blip
    activeBlip = AddBlipForCoord(b.coords)
    SetBlipSprite(activeBlip, b.sprite)
    SetBlipScale(activeBlip, b.scale)
    SetBlipColour(activeBlip, b.color)
    SetBlipDisplay(activeBlip, 4)
    SetBlipAsShortRange(activeBlip, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(b.label)
    EndTextCommandSetBlipName(activeBlip)

    for i, coords in pairs(activeLocation.lootCrates) do
        local crateId = "crate_" .. i
        local obj     = CreateObject(GetHashKey('prop_box_wood01a'), coords.x, coords.y, coords.z, true, true, true)
        SetEntityAsMissionEntity(obj, true, true)
        FreezeEntityPosition(obj, true)
        PlaceObjectOnGroundProperly(obj)

        AddEntityTarget(obj, "Search Crate", "fas fa-box-open", 2.0, function(entity)
            if lootedCrates[crateId] then
                Notify("This crate is already empty.", "error")
                return
            end
            lootedCrates[crateId] = true
            TriggerServerEvent("gang_hideout:giveLoot")
            RemoveEntityTarget(entity)
            DeleteEntity(entity)
        end)
    end

    if Config.Debug then print('[gang-raid] Raid started at: ' .. activeLocation.name) end
end)

-- =============================================
-- SPAWN WAVE — raid-starter client only
-- =============================================
RegisterNetEvent('gang_hideout:spawnWave', function(guards, waveNum)
    local groupHash = SetupGuardRelationships()
    spawnedGuards   = {}
    local netIds    = {}

    for _, guard in pairs(guards) do
        local model = GetHashKey(guard.model)
        RequestModel(model)
        while not HasModelLoaded(model) do Wait(0) end

        local ped = CreatePed(4, model,
            guard.coords.x, guard.coords.y, guard.coords.z, guard.coords.w,
            true, true)

        SetEntityAsMissionEntity(ped, true, true)
        NetworkRegisterEntityAsNetworked(ped)

        GiveWeaponToPed(ped, GetHashKey(guard.weapon), 200, true, true)
        SetPedArmour(ped, guard.armor    or 100)
        SetPedAccuracy(ped, guard.accuracy or 70)

        ApplyCombatSettings(ped, groupHash)
        SetModelAsNoLongerNeeded(model)

        table.insert(spawnedGuards, { ped = ped, looted = false })

        local timeout = 0
        while (not NetworkGetNetworkIdFromEntity(ped) or NetworkGetNetworkIdFromEntity(ped) == 0) do
            Wait(50)
            timeout = timeout + 50
            if timeout > 3000 then break end
        end

        local netId = NetworkGetNetworkIdFromEntity(ped)
        if netId and netId ~= 0 then
            table.insert(netIds, netId)
        end
    end

    TriggerServerEvent('gang_hideout:waveSpawned', netIds)
    StartLootMonitor()
    Notify('Wave ' .. waveNum .. ' — enemies inbound!', 'error')

    if Config.Debug then print('[gang-raid] Wave ' .. waveNum .. ' spawned ' .. #netIds .. ' peds.') end
end)

-- =============================================
-- CONFIGURE PEDS — ALL clients
-- =============================================
RegisterNetEvent('gang_hideout:configurePeds', function(netIds)
    Wait(800)
    local groupHash = SetupGuardRelationships()

    for _, netId in ipairs(netIds) do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local ped = NetworkGetEntityFromNetworkId(netId)
            if DoesEntityExist(ped) and not IsPedAPlayer(ped) then
                ApplyCombatSettings(ped, groupHash)

                local alreadyTracked = false
                for _, entry in ipairs(spawnedGuards) do
                    if entry.ped == ped then alreadyTracked = true break end
                end
                if not alreadyTracked then
                    table.insert(spawnedGuards, { ped = ped, looted = false })
                end
            end
        end
    end

    StartLootMonitor()
end)

-- =============================================
-- SPAWN ESCAPE VEHICLE — raid-starter client only
-- =============================================
RegisterNetEvent('gang_hideout:spawnEscapeVehicle', function(vehicleData)
    if not Config.EscapeVehicleEnabled then return end

    local model = GetHashKey(vehicleData.model)
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(0) end

    local veh = CreateVehicle(model,
        vehicleData.coords.x, vehicleData.coords.y,
        vehicleData.coords.z, vehicleData.coords.w,
        true, true)
    SetEntityAsMissionEntity(veh, true, true)
    NetworkRegisterEntityAsNetworked(veh)
    SetModelAsNoLongerNeeded(model)

    local driverModelName = (activeLocation
        and activeLocation.waves
        and activeLocation.waves[1]
        and activeLocation.waves[1][1]
        and activeLocation.waves[1][1].model)
        or 'g_m_y_ballasout_01'

    local driverModel = GetHashKey(driverModelName)
    RequestModel(driverModel)
    while not HasModelLoaded(driverModel) do Wait(0) end

    local driver = CreatePedInsideVehicle(veh, 4, driverModel, -1, true, true)
    SetEntityAsMissionEntity(driver, true, true)
    NetworkRegisterEntityAsNetworked(driver)
    GiveWeaponToPed(driver, GetHashKey('WEAPON_ASSAULTRIFLE'), 200, true, true)
    SetPedArmour(driver, 200)

    local timeout = 0
    while (not NetworkGetNetworkIdFromEntity(driver) or NetworkGetNetworkIdFromEntity(driver) == 0) do
        Wait(50)
        timeout = timeout + 50
        if timeout > 3000 then break end
    end

    local driverNetId = NetworkGetNetworkIdFromEntity(driver)
    SetModelAsNoLongerNeeded(driverModel)
    TriggerServerEvent('gang_hideout:escapeVehicleSpawned', driverNetId)
end)

-- =============================================
-- DRIVE ESCAPE VEHICLE — all clients
-- =============================================
RegisterNetEvent('gang_hideout:driveEscapeVehicle', function(driverNetId, x, y, z)
    Wait(500)
    if not NetworkDoesEntityExistWithNetworkId(driverNetId) then return end
    local driver = NetworkGetEntityFromNetworkId(driverNetId)
    if not DoesEntityExist(driver) then return end
    local veh = GetVehiclePedIsIn(driver, false)
    if DoesEntityExist(veh) then
        TaskVehicleDriveToCoordLongrange(driver, veh, x, y, z, 30.0, 786603, 20.0)
    end
end)

-- =============================================
-- RAID FINISHED — all clients
-- =============================================
RegisterNetEvent('gang_hideout:raidFinished', function()
    lootMonitorRunning = false
    if activeBlip then RemoveBlip(activeBlip) activeBlip = nil end
    Notify('Gang hideout cleared! Check your inventory for your bonus.', 'success')
    TriggerServerEvent('gang_hideout:claimBonus')
    activeLocation = nil
end)

-- =============================================
-- START NPC — always present in world
-- =============================================
CreateThread(function()
    WaitForTargetLib()

    local npc   = Config.StartRaidNPC
    local model = GetHashKey(npc.model)
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(0) end

    local ped = CreatePed(0, model,
        npc.coords.x, npc.coords.y, npc.coords.z - 1, npc.coords.w,
        false, true)

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetModelAsNoLongerNeeded(model)

    AddEntityTarget(ped, npc.targetLabel, "fas fa-skull-crossbones", 2.5, function()
        TriggerServerEvent("gang_hideout:startRaid")
    end)
end)
