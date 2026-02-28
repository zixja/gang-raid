-- =============================================
-- GANG HIDEOUT RAID | client.lua  v3.0
-- Guards are spawned SERVER-SIDE (synced).
-- This client only:
--   1. Resolves netId → local entity handle
--   2. Sets relationship groups + combat tasks
--   3. Manages blip, loot crates, and UI
-- Compatible: QBCore/QBox | qb-target/ox_target
-- =============================================

local QBCore       = nil
local lootedCrates = {}
local activeBlip   = nil
local raidActive   = false
local targetExport = nil

-- =============================================
-- FRAMEWORK INIT
-- =============================================
CreateThread(function()
    Wait(200)
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and obj then QBCore = obj end

    -- Detect target system
    local oxOk = pcall(function() return exports['ox_target'] end)
    if Config.TargetExport == 'ox_target' or (Config.TargetExport == 'auto' and oxOk) then
        targetExport = 'ox_target'
    else
        targetExport = 'qb-target'
    end
end)

-- =============================================
-- HELPERS
-- =============================================
local function Notify(msg, ntype)
    ntype = ntype or 'primary'
    if QBCore then
        QBCore.Functions.Notify(msg, ntype)
    else
        local ok = pcall(function() lib.notify({ title = msg, type = ntype }) end)
        if not ok then
            SetNotificationTextEntry('STRING')
            AddTextComponentString(msg)
            DrawNotification(false, false)
        end
    end
end

local function AddTargetEntity(entity, options, distance)
    if targetExport == 'ox_target' then
        exports['ox_target']:addLocalEntity(entity, options)
    else
        exports['qb-target']:AddTargetEntity(entity, { options = options, distance = distance or 2.0 })
    end
end

local function RemoveTargetEntity(entity)
    if targetExport == 'ox_target' then
        exports['ox_target']:removeLocalEntity(entity)
    else
        exports['qb-target']:RemoveTargetEntity(entity)
    end
end

local function LoadModel(model)
    local hash = type(model) == 'number' and model or GetHashKey(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local timeout = 0
    while not HasModelLoaded(hash) do
        Wait(100)
        timeout = timeout + 100
        if timeout > 10000 then
            if Config.Debug then print('[GHR CLIENT] Model timeout: ' .. tostring(model)) end
            return nil
        end
    end
    return hash
end

-- =============================================
-- BLIP
-- =============================================
local function CreateRaidBlip(blipData)
    if activeBlip then RemoveBlip(activeBlip) end
    activeBlip = AddBlipForCoord(blipData.coords.x, blipData.coords.y, blipData.coords.z)
    SetBlipSprite(activeBlip, blipData.sprite)
    SetBlipScale(activeBlip, blipData.scale)
    SetBlipColour(activeBlip, blipData.color)
    SetBlipDisplay(activeBlip, 4)
    SetBlipAsShortRange(activeBlip, false)
    SetBlipFlashes(activeBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(blipData.label)
    EndTextCommandSetBlipName(activeBlip)
end

-- =============================================
-- LOOT CRATES  (client-local props are fine —
-- only the server loot event is authoritative)
-- =============================================
local function SpawnLootCrates(crateCoords)
    lootedCrates = {}

    for i, coords in ipairs(crateCoords) do
        local crateId = 'crate_' .. i
        local hash    = `prop_box_wood01a`
        RequestModel(hash)
        local t = 0
        while not HasModelLoaded(hash) do
            Wait(100); t = t + 100
            if t > 5000 then break end
        end

        local obj = CreateObject(hash, coords.x, coords.y, coords.z, true, true, true)
        SetEntityAsMissionEntity(obj, true, true)
        FreezeEntityPosition(obj, true)
        PlaceObjectOnGroundProperly(obj)
        SetModelAsNoLongerNeeded(hash)

        local capturedObj     = obj
        local capturedCrateId = crateId

        local function OnSearch(entity)
            if lootedCrates[capturedCrateId] then
                Notify('This crate is already empty.', 'error')
                return
            end
            lootedCrates[capturedCrateId] = true
            TriggerServerEvent('gang_hideout:giveLoot')
            RemoveTargetEntity(entity or capturedObj)
            if DoesEntityExist(capturedObj) then DeleteEntity(capturedObj) end
        end

        local options = {
            {
                name     = 'ghr_search_' .. crateId,
                label    = 'Search Crate',
                icon     = 'fas fa-box-open',
                distance = 2.0,
                onSelect = function(data)  -- ox_target
                    OnSearch(data and data.entity)
                end,
                action   = function(entity) -- qb-target
                    OnSearch(entity)
                end,
            }
        }

        AddTargetEntity(obj, options, 2.0)
    end
end

-- =============================================
-- START NPC  (spawned locally — cosmetic only)
-- =============================================
CreateThread(function()
    Wait(1500)
    local npc  = Config.StartRaidNPC
    local hash = LoadModel(npc.model)
    if not hash then return end

    local ped = CreatePed(4, hash,
        npc.coords.x, npc.coords.y, npc.coords.z - 1.0, npc.coords.w,
        false, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetModelAsNoLongerNeeded(hash)

    local options = {
        {
            name     = 'ghr_start_raid',
            label    = npc.targetLabel,
            icon     = 'fas fa-skull-crossbones',
            distance = 2.5,
            onSelect = function()   -- ox_target
                if raidActive then Notify('A raid is already in progress!', 'error'); return end
                TriggerServerEvent('gang_hideout:startRaid')
            end,
            action = function()     -- qb-target
                if raidActive then Notify('A raid is already in progress!', 'error'); return end
                TriggerServerEvent('gang_hideout:startRaid')
            end,
        }
    }

    AddTargetEntity(ped, options, 2.5)
end)

-- =============================================
-- NET EVENT: RAID STARTED
-- Server picks the location — clients show blip
-- and spawn crate props locally.
-- =============================================
RegisterNetEvent('gang_hideout:raidStarted', function(locationIndex)
    if raidActive then return end
    raidActive = true

    local location = Config.Locations[locationIndex]
    if not location then return end

    Notify('🚨 Gang Hideout Raid started at ' .. location.name .. '!', 'error')
    CreateRaidBlip(location.blip)
    SpawnLootCrates(location.lootCrates)
end)

-- =============================================
-- NET EVENT: CONFIGURE PEDS
-- Server sends us the netIds of freshly spawned
-- peds. We resolve them to local handles and
-- apply relationship groups + combat tasks,
-- which MUST run client-side.
-- =============================================
RegisterNetEvent('gang_hideout:configurePeds', function(netIdList)
    -- Give the engine a moment to replicate the entities before we look them up
    Wait(1000)

    -- Set up hostile relationship group once
    local groupHash  = GetHashKey('HIDEOUT_GUARDS')
    local playerHash = GetHashKey('PLAYER')
    if not HasRelationshipGroupWithHash(groupHash) then
        AddRelationshipGroup('HIDEOUT_GUARDS')
    end
    SetRelationshipBetweenGroups(5, groupHash, playerHash)  -- hate
    SetRelationshipBetweenGroups(5, playerHash, groupHash)

    for _, entry in ipairs(netIdList) do
        -- Wait until this net entity exists locally (up to 5 seconds)
        local ped     = nil
        local timeout = 0
        repeat
            Wait(200)
            timeout = timeout + 200
            if NetworkDoesNetworkIdExist(entry.netId) then
                ped = NetworkGetEntityFromNetworkId(entry.netId)
            end
        until (ped and DoesEntityExist(ped)) or timeout > 5000

        if ped and DoesEntityExist(ped) then
            SetPedRelationshipGroupHash(ped, groupHash)
            SetPedAsEnemy(ped, true)
            SetPedAccuracy(ped, entry.accuracy or 70)
            SetPedCombatAttributes(ped, 46, true)   -- canFightArmedPedsWhenNotArmed
            SetPedCombatAttributes(ped, 5,  true)   -- canUseCover
            SetPedCombatRange(ped, 2)               -- far
            SetPedCombatAbility(ped, 2)             -- professional
            SetPedCombatMovement(ped, 2)            -- advance
            TaskCombatHatedTargetsAroundPed(ped, 80.0, 0)

            if Config.Debug then
                print('[GHR CLIENT] Configured ped netId=' .. entry.netId)
            end
        else
            if Config.Debug then
                print('[GHR CLIENT] Could not resolve netId=' .. tostring(entry.netId))
            end
        end
    end
end)

-- =============================================
-- NET EVENT: DRIVE ESCAPE VEHICLE
-- Server creates the vehicle and driver, sends
-- us the driver's netId. We apply the drive
-- task since TaskVehicleDriveToCoord is client.
-- =============================================
RegisterNetEvent('gang_hideout:driveEscapeVehicle', function(driverNetId, destX, destY, destZ)
    Wait(1000)

    local driver  = nil
    local timeout = 0
    repeat
        Wait(200)
        timeout = timeout + 200
        if NetworkDoesNetworkIdExist(driverNetId) then
            driver = NetworkGetEntityFromNetworkId(driverNetId)
        end
    until (driver and DoesEntityExist(driver)) or timeout > 5000

    if not (driver and DoesEntityExist(driver)) then return end

    local veh = GetVehiclePedIsIn(driver, false)
    if not DoesEntityExist(veh) then return end

    -- Set up hostility
    local groupHash  = GetHashKey('HIDEOUT_GUARDS')
    local playerHash = GetHashKey('PLAYER')
    if not HasRelationshipGroupWithHash(groupHash) then AddRelationshipGroup('HIDEOUT_GUARDS') end
    SetRelationshipBetweenGroups(5, groupHash, playerHash)
    SetRelationshipBetweenGroups(5, playerHash, groupHash)
    SetPedRelationshipGroupHash(driver, groupHash)
    SetPedAsEnemy(driver, true)

    TaskVehicleDriveToCoordLongrange(driver, veh, destX, destY, destZ, 22.0, 262144, 5.0)
end)

-- =============================================
-- NET EVENT: RAID FINISHED
-- =============================================
RegisterNetEvent('gang_hideout:raidFinished', function()
    raidActive = false
    if activeBlip then RemoveBlip(activeBlip); activeBlip = nil end
    Notify('🏆 Raid complete! All enemies eliminated.', 'success')
    -- Claim server bonus (each player can claim individually)
    TriggerServerEvent('gang_hideout:claimBonus')
end)
