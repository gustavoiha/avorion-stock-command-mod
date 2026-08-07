package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("mission")
include("callable")
include("stringutility")
include("utility")
include("galaxy")
include("relations")
include("randomext")

local missionKeyPrefix = "gate_construction_mission_"

local function distance2d(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function makeResourceVector(ironAmount, triniumAmount, xanionAmount, avorionAmount, legacyIndex, legacyAmount)
    local result = {0, 0, 0, 0, 0, 0, 0}
    if ironAmount and ironAmount > 0 then
        result[1] = ironAmount
    end
    if triniumAmount and triniumAmount > 0 then
        result[4] = triniumAmount
    end
    if xanionAmount and xanionAmount > 0 then
        result[5] = xanionAmount
    end
    if avorionAmount and avorionAmount > 0 then
        result[7] = avorionAmount
    end

    if result[1] == 0 and result[4] == 0 and result[5] == 0 and result[7] == 0 and legacyIndex and legacyAmount and legacyIndex >= 1 and legacyIndex <= 7 then
        result[legacyIndex] = legacyAmount
    end
    return result
end

local function missionKey(missionId)
    return missionKeyPrefix .. tostring(missionId)
end

local BUILD_TIME = 5 * 60

local clearStationBusyCode = [[
function run(stationIndex)
    local entity = Entity(stationIndex)
    if valid(entity) then
        entity:setValue("gate_construction_busy", false)
    end
end
]]

local spawnActiveGateCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("galaxy")

function run(factionIndex, tx, ty)
    local x, y = Sector():getCoordinates()

    local faction = Faction(factionIndex) or Galaxy():getNearestFaction(x, y)
    if not faction then return end

    local desc = EntityDescriptor()
    desc:addComponents(
       ComponentType.Plan,
       ComponentType.BspTree,
       ComponentType.Intersection,
       ComponentType.Asleep,
       ComponentType.DamageContributors,
       ComponentType.BoundingSphere,
       ComponentType.PlanMaxDurability,
       ComponentType.Durability,
       ComponentType.BoundingBox,
       ComponentType.Velocity,
       ComponentType.Physics,
       ComponentType.Scripts,
       ComponentType.ScriptCallback,
       ComponentType.Title,
       ComponentType.Owner,
       ComponentType.FactionNotifier,
       ComponentType.WormHole,
       ComponentType.EnergySystem,
       ComponentType.EntityTransferrer
    )

    local styleGenerator = StyleGenerator(faction.index)
    local c1 = styleGenerator.factionDetails.baseColor
    local c2 = ColorRGB(0.25, 0.25, 0.25)
    local c3 = styleGenerator.factionDetails.paintColor
    c1 = ColorRGB(c1.r, c1.g, c1.b)
    c3 = ColorRGB(c3.r, c3.g, c3.b)

    local plan = PlanGenerator.makeGatePlan(Seed(faction.index) + Server().seed, c1, c2, c3)

    local dir = vec3(tx - x, 0, ty - y)
    if dir.x == 0 and dir.z == 0 then
        dir = vec3(1, 0, 0)
    else
        normalize_ip(dir)
    end

    local position = MatrixLookUp(dir, vec3(0, 1, 0))
    position.pos = dir * 3000

    desc:setMovePlan(plan)
    desc.position = position
    desc.factionIndex = faction.index
    desc.invincible = true
    desc:addScript("data/scripts/entity/gate.lua")

    local wormhole = desc:getComponent(ComponentType.WormHole)
    wormhole:setTargetCoordinates(tx, ty)
    wormhole.visible = false
    wormhole.visualSize = 50
    wormhole.passageSize = 50
    wormhole.oneWay = true

    local gate = Sector():createEntity(desc)
    if valid(gate) then
        gate:setValue("gate_construction_active_gate", true)
    end
end
]]

local spawnInvasionCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"

include("randomext")
local AsyncXsotanGenerator = include("asyncxsotangenerator")
local SpawnUtility = include("spawnutility")
-- Invasion spawns in whichever sector this code is run in (always 0:0).

function run()
    local volumes = {
        {size = 1}, {size = 1}, {size = 2}, {size = 3}, {size = 3},
        {size = 5}, {size = 3}, {size = 3}, {size = 2}, {size = 1}, {size = 1}
    }

    -- Match the regular large invasion shape and spawn it twice.
    local wave = {}
    for i = 1, 2 do
        for _, entry in pairs(volumes) do
            table.insert(wave, {size = entry.size})
        end
    end

    local generator = AsyncXsotanGenerator(nil, function(generated)
        SpawnUtility.addEnemyBuffs(generated)
    end)

    local dir = normalize(vec3(getFloat(-1, 1), getFloat(-1, 1), getFloat(-1, 1)))
    local up = vec3(0, 1, 0)
    local right = normalize(cross(dir, up))
    local pos = dir * 1500

    generator:startBatch()
    for _, entry in pairs(wave) do
        generator:createShip(MatrixLookUpPosition(-dir, up, pos), entry.size)
        pos = pos + right * 95
    end
    generator:endBatch()
end
]]

-- Fires a guardian-style channel beam from the Research Station toward the
-- central black hole (Planet 0) at sector 0:0, replicating the wormhole-
-- harnessing effect used by the Wormhole Guardian.
local stationHarnessingCode = [[
function run(stationIndex)
    local station = Entity(stationIndex)
    if not valid(station) then return end

    local targetPos = vec3()
    local planet = Planet(0)
    if valid(planet) then
        targetPos = planet.position.translation
    end

    local laser = Sector():createLaser(station.translationf, targetPos, ColorRGB(0.9, 0.6, 0.2), 25.0)
    laser.maxAliveTime = 25.0
    laser.animationSpeed = -500
    laser.collision = false
end
]]

local function clearStationBusy()
    local c = missionData.custom
    if not c or not c.stationIndex then return end
    runSectorCode(0, 0, true, clearStationBusyCode, "run", c.stationIndex)
end

local function refundMaterialsOnly()
    local c = missionData.custom
    if c.materialRefunded then return end

    local payer = Faction(c.commissioningFactionIndex)
    if not payer then return end

    local resources = makeResourceVector(c.ironAmount, c.triniumAmount, c.xanionAmount, c.avorionAmount, c.resourceIndex, c.resourceAmount)
    payer:receive("Refunded gate-construction material downpayment after mission cancelation."%_T, 0, unpack(resources))
    c.materialRefunded = true
end

local function activateGates()
    local c = missionData.custom

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnActiveGateCode, "run", c.builderFactionIndex, c.endpointB.x, c.endpointB.y)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, spawnActiveGateCode, "run", c.builderFactionIndex, c.endpointA.x, c.endpointA.y)

    runSectorCode(0, 0, true, stationHarnessingCode, "run", c.stationIndex)
    Player():sendChatMessage(""%_T, ChatMessageType.Warning, "Subspace signatures surging near sector 0:0. Brace for a major Xsotan assault!"%_T)
    runSectorCode(0, 0, true, spawnInvasionCode, "run")
end

local function updateObjectivesFromPhase()
    local custom = missionData.custom

    missionData.description = {}
    missionData.description[1] = "You commissioned a gate between (${ax}:${ay}) and (${bx}:${by})."%_T % {
        ax = custom.endpointA.x,
        ay = custom.endpointA.y,
        bx = custom.endpointB.x,
        by = custom.endpointB.y,
    }

    if custom.phase == 1 then
        local mins = math.max(1, math.ceil((custom.buildCountdown or 0) / 60))
        missionData.description[2] = {text = "The research station is building the gate (${m} min remaining)."%_T, arguments = {m = mins}, bulletPoint = true}
        missionData.description[3] = {text = "A Xsotan invasion will strike sector 0:0 when construction completes."%_T, bulletPoint = true}
    elseif custom.phase == 2 then
        missionData.description[2] = {text = "The gate has been activated."%_T, bulletPoint = true, fulfilled = true}
    end
end

function initialize(stationIndex, builderFactionIndex, commissioningFactionIndex, ax, ay, bx, by, creditsPaid, ironAmount, triniumAmount, xanionAmount, avorionAmount)
    initMissionCallbacks()

    if onClient() then
        if not missionData.custom then missionData.custom = {} end
        sync()
        return
    end

    if not stationIndex then return end

    local missionId = random():getInt(100000, 99999999)

    missionData.custom = {
        missionId = missionId,
        stationIndex = stationIndex,
        builderFactionIndex = builderFactionIndex,
        commissioningFactionIndex = commissioningFactionIndex,
        endpointA = {x = ax, y = ay},
        endpointB = {x = bx, y = by},
        creditsPaid = creditsPaid,
        ironAmount = ironAmount,
        triniumAmount = triniumAmount,
        xanionAmount = xanionAmount,
        avorionAmount = avorionAmount,
        phase = 1,
        buildCountdown = BUILD_TIME,
        completionDelay = 8,
        objectiveRefresh = 0,
    }

    missionData.brief = "Construct Gate"%_T
    missionData.title = "Gate Construction (${ax}:${ay}) <-> (${bx}:${by})"%_T % {ax = ax, ay = ay, bx = bx, by = by}
    missionData.autoTrackMission = true

    updateObjectivesFromPhase()

    Player():sendChatMessage("Research Station"%_T, ChatMessageType.Normal,
        "Contract accepted. The gate will be built in ${m} minutes. Expect a Xsotan response near sector 0:0 when construction completes."%_T,
        math.floor(BUILD_TIME / 60))

    sync()
end

function getUpdateInterval()
    return 2
end

function update(timeStep)
    if not missionData.custom then return end

    local c = missionData.custom

    if c.phase == 1 then
        c.buildCountdown = c.buildCountdown - timeStep

        -- Periodically refresh the countdown shown in objectives.
        c.objectiveRefresh = (c.objectiveRefresh or 0) + timeStep
        if c.objectiveRefresh >= 30 then
            c.objectiveRefresh = 0
            updateObjectivesFromPhase()
            sync()
        end

        if c.buildCountdown <= 0 then
            activateGates()
            clearStationBusy()

            c.phase = 2
            updateObjectivesFromPhase()

            Player():sendChatMessage("Research Station"%_T, ChatMessageType.Normal,
                "The gate link between (${ax}:${ay}) and (${bx}:${by}) is now active. A Xsotan wave has been detected near sector 0:0!"%_T,
                c.endpointA.x, c.endpointA.y, c.endpointB.x, c.endpointB.y)

            showMissionAccomplished()
            sync()
        end

    elseif c.phase == 2 then
        c.completionDelay = c.completionDelay - timeStep
        if c.completionDelay <= 0 then
            terminate()
        end
    end
end

function getMissionBrief()
    return missionData.brief or "Construct Gate"%_T
end

function getMissionLocation()
    if not missionData.custom then return 0, 0 end
    local c = missionData.custom
    return c.endpointA.x, c.endpointA.y
end

function getMissionDescription()
    if not missionData.custom then return "" end

    local c = missionData.custom

    local matText = "${iron} Iron + ${trinium} Trinium + ${xanion} Xanion + ${avorion} Avorion"%_T % {
        iron = c.ironAmount or 0,
        trinium = c.triniumAmount or 0,
        xanion = c.xanionAmount or 0,
        avorion = c.avorionAmount or 0,
    }

    local base = "Two endpoints contracted: (${ax}:${ay}) and (${bx}:${by}).\nCredits fee paid: ¢${credits}. Material downpayment: ${mat}."%_T % {
        ax = c.endpointA.x,
        ay = c.endpointA.y,
        bx = c.endpointB.x,
        by = c.endpointB.y,
        credits = createMonetaryString(c.creditsPaid or 0),
        mat = matText,
    }

    if c.phase == 1 then
        local mins = math.max(1, math.ceil((c.buildCountdown or 0) / 60))
        return base .. "\n\nBuilding: ${m} minute(s) remaining. Xsotan will strike sector 0:0 upon completion."%_T % {m = mins}
    end

    return base .. "\n\nGate successfully activated."%_T
end

function abandon()
    if onClient() then
        invokeServerFunction("abandon")
        return
    end

    clearStationBusy()
    refundMaterialsOnly()

    missionData.failMessage = "Gate construction was canceled. Material downpayment was refunded, but credit fees were retained by the contractor."%_T
    showMissionFailed()
    terminate()
end
callable(nil, "abandon")

function onRestore()
    if not missionData.custom then
        terminate()
        return
    end
end

function secure()
    return missionData
end

function restore(data)
    if not data then
        terminate()
        return
    end

    missionData = data
end
