-- =============================================
-- GANG HIDEOUT RAID | client.lua  v6.0
-- Supports: qb-target / ox_target (auto-detect)
--           QBCore / QBox / ox_lib notify
-- =============================================

local QBCore             = nil
local lootedCrates       = {}
local spawnedCrates      = {}   -- object handles so we can delete on cleanup
local spawnedGuards      = {}   -- { ped = handle, looted = bool }
local lootedGuards       = {}   -- [ped handle] = true
local activeLocation     = nil
local activeBlip         = nil
local lootMonitorRunning = false
local aiLoopRunning      = false

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
-- EMOTE HELPER
-- =============================================
local function PlayEmote(scenario)
    local playerPed = PlayerPedId()
    if scenario then
        TaskStartScenarioInPlace(playerPed, scenario, 0, true)
    else
        -- ClearPedTasksImmediately forcefully exits any active scenario
        -- ClearPedTasks alone queues the stop but the scenario can persist
        ClearPedTasksImmediately(PlayerPedId())
    end
end

-- =============================================
-- OX_LIB SKILLCHECK + PROGRESSBAR LOOT SEQUENCE
--
-- Flow:
--   1. Skillcheck pops (must pass to continue)
--   2. Emote starts
--   3. Progress bar runs — player can press E/Backspace to cancel
--   4. Emote always cleared on exit regardless of outcome
--
-- NOTE: We do NOT pass anim.scenario to the progressBar.
-- Letting ox_lib manage the animation internally conflicts
-- with our manual scenario task and prevents clean cancellation.
-- The scenario is started before the bar and cleared after.
-- =============================================
local function DoLootSequence(params)
    local hasOxLib = GetResourceState('ox_lib') == 'started'

    if not hasOxLib then
        params.onSuccess()
        return
    end

    -- 1. Skillcheck first (no emote yet — looks weird to animate before passing)
    local passed = exports['ox_lib']:skillCheck({ 'easy', 'medium' }, { 'e' })

    if not passed then
        Notify('You failed the check.', 'error')
        if params.onFail then params.onFail() end
        return
    end

    -- 2. Start emote AFTER passing skillcheck
    PlayEmote(params.emote)

    -- 3. Progress bar — NO anim block so ox_lib doesn't fight our scenario
    local completed = exports['ox_lib']:progressBar({
        duration     = params.duration or 4000,
        label        = params.progressLabel or 'Searching...',
        useWhileDead = false,
        canCancel    = true,
        disable = {
            move   = true,
            car    = true,
            combat = true,
            sprint = true,
        },
    })

    -- 4. Always clear emote immediately when bar finishes or is cancelled
    ClearPedTasksImmediately(PlayerPedId())

    if completed then
        params.onSuccess()
    else
        Notify('Interrupted.', 'error')
        if params.onFail then params.onFail() end
    end
end

-- =============================================
-- GUARD RELATIONSHIPS
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
-- =============================================
local function ApplyCombatSettings(ped, groupHash)
    SetPedRelationshipGroupHash(ped, groupHash)
    SetPedAsEnemy(ped, true)
    SetPedAlertness(ped, 3)

    SetPedCombatAttributes(ped, 0,  true)
    SetPedCombatAttributes(ped, 2,  true)
    SetPedCombatAttributes(ped, 5,  true)
    SetPedCombatAttributes(ped, 14, true)
    SetPedCombatAttributes(ped, 17, true)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAttributes(ped, 52, true)

    SetPedCombatRange(ped, 2)
    SetPedCombatAbility(ped, 2)
    SetPedCombatMovement(ped, 2)

    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedTargetLossResponse(ped, 2)
end

-- =============================================
-- GUARD AI LOOP
-- =============================================
local function RequestPedControl(ped)
    if NetworkHasControlOfEntity(ped) then return true end
    NetworkRequestControlOfEntity(ped)
    local t = 0
    while not NetworkHasControlOfEntity(ped) and t < 1000 do
        Wait(50)
        t = t + 50
        NetworkRequestControlOfEntity(ped)
    end
    return NetworkHasControlOfEntity(ped)
end

local function TaskGuardCombat(ped)
    local pedCoords     = GetEntityCoords(ped)
    local closestPlayer = nil
    local closestDist   = 80.0

    for _, playerId in ipairs(GetActivePlayers()) do
        local playerPed = GetPlayerPed(playerId)
        if DoesEntityExist(playerPed) and not IsEntityDead(playerPed) then
            local dist = #(pedCoords - GetEntityCoords(playerPed))
            if dist < closestDist then
                closestDist   = dist
                closestPlayer = playerPed
            end
        end
    end

    if closestPlayer then
        TaskCombatPed(ped, closestPlayer, 0, 16)
    else
        TaskCombatHatedTargetsAroundPed(ped, 80.0, 0)
    end
end

local function StartGuardAILoop()
    if aiLoopRunning then return end
    aiLoopRunning = true

    CreateThread(function()
        while aiLoopRunning do
            Wait(1500)

            for _, entry in ipairs(spawnedGuards) do
                local ped = entry.ped
                if not DoesEntityExist(ped) or IsEntityDead(ped) then goto continue end
                if RequestPedControl(ped) then
                    TaskGuardCombat(ped)
                end
                ::continue::
            end
        end
    end)
end

-- =============================================
-- LOOT MONITOR — watches for dead guards
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

                            DoLootSequence({
                                emote         = 'CODE_HUMAN_MEDIC_KNEEL',  -- kneeling over body
                                progressLabel = 'Searching body...',
                                duration      = 5000,
                                onSuccess     = function()
                                    TriggerServerEvent("gang_hideout:lootGuard")
                                end,
                                onFail = function()
                                    -- Re-add target so player can try again
                                    if DoesEntityExist(p) then
                                        lootedGuards[p]  = nil
                                        entry.looted     = false
                                    end
                                end,
                            })
                        end)
                    end)
                end
            end
        end
    end)
end

-- =============================================
-- BLIP HELPER — safe remove + create
-- Uses both the stored handle AND a full blip
-- sweep by sprite so stale handles never leave
-- a ghost blip on the map.
-- =============================================
local RAID_BLIP_SPRITE = 161  -- matches all locations in config

local function ClearRaidBlip()
    -- Remove by stored handle first
    if activeBlip and DoesBlipExist(activeBlip) then
        RemoveBlip(activeBlip)
    end
    activeBlip = nil

    -- Safety sweep: remove every blip with the raid sprite
    -- This catches any orphaned blips from previous raids
    -- or blips whose handle was lost between events.
    local blip = GetFirstBlipInfoId(RAID_BLIP_SPRITE)
    while DoesBlipExist(blip) do
        RemoveBlip(blip)
        blip = GetNextBlipInfoId(RAID_BLIP_SPRITE)
    end
end

local function CreateRaidBlip(b)
    ClearRaidBlip()
    activeBlip = AddBlipForCoord(b.coords)
    SetBlipSprite(activeBlip, b.sprite)
    SetBlipScale(activeBlip, b.scale)
    SetBlipColour(activeBlip, b.color)
    SetBlipDisplay(activeBlip, 4)
    SetBlipAsShortRange(activeBlip, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(b.label)
    EndTextCommandSetBlipName(activeBlip)
    RAID_BLIP_SPRITE = b.sprite  -- keep in sync in case config changes it
end

-- =============================================
-- RAID STARTED — fires on ALL clients
-- =============================================
RegisterNetEvent('gang_hideout:raidStarted', function(locationIndex)
    lootedCrates       = {}
    spawnedCrates      = {}
    lootedGuards       = {}
    spawnedGuards      = {}
    lootMonitorRunning = false
    aiLoopRunning      = false
    activeLocation     = Config.Locations[locationIndex]

    CreateRaidBlip(activeLocation.blip)

    for i, coords in pairs(activeLocation.lootCrates) do
        local crateId = "crate_" .. i
        local obj     = CreateObject(GetHashKey('prop_box_wood01a'), coords.x, coords.y, coords.z, true, true, true)
        SetEntityAsMissionEntity(obj, true, true)
        FreezeEntityPosition(obj, true)
        PlaceObjectOnGroundProperly(obj)
        table.insert(spawnedCrates, obj)  -- track for cleanup on raid end

        AddEntityTarget(obj, "Search Crate", "fas fa-box-open", 2.0, function(entity)
            if lootedCrates[crateId] then
                Notify("This crate is already empty.", "error")
                return
            end

            DoLootSequence({
                emote         = 'PROP_HUMAN_BUM_BIN',   -- rummaging through a container
                progressLabel = 'Searching crate...',
                duration      = 6000,
                onSuccess     = function()
                    lootedCrates[crateId] = true
                    TriggerServerEvent("gang_hideout:giveLoot")
                    RemoveEntityTarget(entity)
                    DeleteEntity(entity)
                end,
                -- onFail: do nothing, player can try again
            })
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
        TaskGuardCombat(ped)

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
    StartGuardAILoop()
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
-- =============================================
-- FULL RAID CLEANUP
-- Deletes all client-side entities (crates, guards)
-- and removes the blip. Called on raidFinished and
-- also exported so server can trigger it directly.
-- =============================================
local function CleanupRaid()
    lootMonitorRunning = false
    aiLoopRunning      = false

    -- Delete remaining crate props
    for _, obj in ipairs(spawnedCrates) do
        if DoesEntityExist(obj) then
            RemoveEntityTarget(obj)
            SetEntityAsMissionEntity(obj, false, true)
            DeleteObject(obj)
        end
    end
    spawnedCrates = {}
    lootedCrates  = {}

    -- Delete remaining guard peds
    for _, entry in ipairs(spawnedGuards) do
        local ped = entry.ped
        if DoesEntityExist(ped) then
            RemoveEntityTarget(ped)
            SetEntityAsMissionEntity(ped, false, true)
            DeleteEntity(ped)
        end
    end
    spawnedGuards = {}
    lootedGuards  = {}

    -- Blip: remove by handle + full sprite sweep, retried 3 times
    -- to handle stale handles and late-resolving blip state
    local function WipeBlip()
        if activeBlip and DoesBlipExist(activeBlip) then
            RemoveBlip(activeBlip)
        end
        activeBlip = nil
        local b = GetFirstBlipInfoId(RAID_BLIP_SPRITE)
        while DoesBlipExist(b) do
            RemoveBlip(b)
            b = GetNextBlipInfoId(RAID_BLIP_SPRITE)
        end
    end

    WipeBlip()
    SetTimeout(500,  WipeBlip)
    SetTimeout(1500, WipeBlip)
    SetTimeout(4000, WipeBlip)

    activeLocation = nil
end

RegisterNetEvent('gang_hideout:raidFinished', function()
    CleanupRaid()
    Notify('Gang hideout cleared! Check your inventory for your bonus.', 'success')
    TriggerServerEvent('gang_hideout:claimBonus')
end)

-- =============================================
-- CLEANUP DEAD PEDS — all clients
-- Called 30s after each wave is cleared so
-- corpses don't litter the area forever.
-- =============================================
RegisterNetEvent('gang_hideout:cleanupPeds', function(netIds)
    for _, netId in ipairs(netIds) do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local ped = NetworkGetEntityFromNetworkId(netId)
            if DoesEntityExist(ped) and not IsPedAPlayer(ped) then
                RemoveEntityTarget(ped)
                SetEntityAsMissionEntity(ped, false, true)
                DeleteEntity(ped)
            end
        end
    end
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
