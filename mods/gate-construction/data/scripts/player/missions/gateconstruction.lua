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

local spawnInactiveGateCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("galaxy")

function run(key, factionIndex, tx, ty, missionId)
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
       ComponentType.EntityTransferrer,
       ComponentType.InteractionText
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
    desc:addScriptOnce("data/scripts/entity/utility/gateconstructioninactivegate.lua")
    desc:setValue("ai_no_attack", true)

    local wormhole = desc:getComponent(ComponentType.WormHole)
    wormhole:setTargetCoordinates(tx, ty)
    wormhole.enabled = false
    wormhole.visible = false
    wormhole.visualSize = 50
    wormhole.passageSize = 50
    wormhole.oneWay = true

    desc.title = "Inactive Gate"%_T

    local gate = Sector():createEntity(desc)
    if valid(gate) then
        gate:setValue(key, true)
        gate:setValue("gate_construction_inactive_gate", true)
        gate:setValue("gate_construction_mission_id", missionId)
        gate:setValue("gate_construction_mission_script", "data/scripts/player/missions/gateconstruction.lua")
    end
end
]]

local gateActivationVfxCode = [[
function run(key)
    local entities = {Sector():getEntitiesByScriptValue(key)}
    for _, entity in pairs(entities) do
        if valid(entity) and entity:getValue("gate_construction_inactive_gate") then
            local p = entity.translationf

            for i = 1, 14 do
                local from = p + random():getDirection() * random():getFloat(120, 340)
                local to = p + random():getDirection() * random():getFloat(15, 80)
                local laser = Sector():createLaser(from, to, ColorRGB(0.2, 0.9, 0.95), random():getFloat(1.3, 2.2))
                laser.maxAliveTime = 2.0
                laser.animationSpeed = -2.8
                laser.collision = false
            end

            Sector():createExplosion(p, 85, false)
            Sector():createHyperspaceJumpAnimation(p, ColorRGB(0.2, 0.95, 0.95), 1.0)
        end
    end
end
]]

local deleteMissionEntitiesCode = [[
function run(key)
    local entities = {Sector():getEntitiesByScriptValue(key)}
    for _, entity in pairs(entities) do
        if valid(entity) then
            Sector():deleteEntity(entity)
        end
    end
end
]]

local countXsotanCode = [[
function run(playerIndex, missionId)
    local count = Sector():getNumEntitiesByScriptValue("is_xsotan")

    local player = Player(playerIndex)
    if player then
        player:setValue("gate_construction_xsotan_" .. tostring(missionId), count)
    end
end
]]

function requestActivation(gateIndex)
    if onClient() then
        invokeServerFunction("requestActivation", gateIndex)
        return
    end

    local c = missionData.custom
    if not c or c.phase ~= 2 then return end

    local gate = Entity(gateIndex)
    if not valid(gate) then return end
    if not gate:getValue("gate_construction_inactive_gate") then return end
    if gate:getValue("gate_construction_mission_id") ~= c.missionId then return end

    c.activationRequested = true
    c.activationGateIndex = gateIndex

    Player(callingPlayer):sendChatMessage("Research Station"%_T, ChatMessageType.Information,
        "The research station has begun the gate activation sequence."%_T)
    sync()
end
callable(nil, "requestActivation")

local spawnInvasionCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"

include("randomext")
local AsyncXsotanGenerator = include("asyncxsotangenerator")
local SpawnUtility = include("spawnutility")

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

local spawnActiveGateCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("galaxy")

function run(key, ownerFactionIndex, tx, ty)
    local x, y = Sector():getCoordinates()
    local ownerFaction = Faction(ownerFactionIndex)
    if not ownerFaction then
        ownerFaction = Galaxy():getNearestFaction(x, y)
    end
    if not ownerFaction then return end

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

    local styleGenerator = StyleGenerator(ownerFaction.index)
    local c1 = styleGenerator.factionDetails.baseColor
    local c2 = ColorRGB(0.25, 0.25, 0.25)
    local c3 = styleGenerator.factionDetails.paintColor
    c1 = ColorRGB(c1.r, c1.g, c1.b)
    c3 = ColorRGB(c3.r, c3.g, c3.b)

    local plan = PlanGenerator.makeGatePlan(Seed(ownerFaction.index) + Server().seed, c1, c2, c3)

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
    desc.factionIndex = ownerFaction.index
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

local function updateObjectivesFromPhase()
    local custom = missionData.custom
    local a = custom.endpointA

    missionData.description = {}
    missionData.description[1] = "You commissioned a faction-built gate between (${ax}:${ay}) and (${bx}:${by})."%_T % {
        ax = custom.endpointA.x,
        ay = custom.endpointA.y,
        bx = custom.endpointB.x,
        by = custom.endpointB.y,
    }

    if custom.phase == 1 then
        local mins = math.max(1, math.floor((custom.arrivalCountdown or 0) / 60))
        missionData.description[2] = {text = "Secure sector (${x}:${y}) if hostiles are present. The research station will construct the inactive gate once the area is clear."%_T, arguments = {x = a.x, y = a.y}, bulletPoint = true}
        missionData.description[3] = {text = "Once secure: wait for the inactive gate to appear (${m} min est.)"%_T, arguments = {m = mins}, bulletPoint = true}
    elseif custom.phase == 2 then
        missionData.description[2] = {text = "Interact with the inactive gate in (${x}:${y}) to begin activation."%_T, arguments = {x = a.x, y = a.y}, bulletPoint = true}
        missionData.description[3] = {text = "The station still requires the full material payment before activation."%_T, bulletPoint = true}
    elseif custom.phase == 3 then
        missionData.description[2] = {text = "Defend the construction site in (${x}:${y}) and destroy all Xsotan."%_T, arguments = {x = a.x, y = a.y}, bulletPoint = true}
    elseif custom.phase == 4 then
        missionData.description[2] = {text = "The gate has been activated."%_T, bulletPoint = true, fulfilled = true}
    end
end

local function cleanupMissionEntities()
    local c = missionData.custom
    local key = missionKey(c.missionId)

    runSectorCode(c.endpointA.x, c.endpointA.y, true, deleteMissionEntitiesCode, "run", key)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, deleteMissionEntitiesCode, "run", key)

    if c.dispatchSector then
        runSectorCode(c.dispatchSector.x, c.dispatchSector.y, true, deleteMissionEntitiesCode, "run", key)
    end
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

local function spawnInactiveAnchors()
    local c = missionData.custom
    local key = missionKey(c.missionId)

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnInactiveGateCode, "run", key, c.builderFactionIndex, c.endpointB.x, c.endpointB.y, c.missionId)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, spawnInactiveGateCode, "run", key, c.builderFactionIndex, c.endpointA.x, c.endpointA.y, c.missionId)
end

local function spawnInvasion()
    local c = missionData.custom

    Player():sendChatMessage(""%_T, ChatMessageType.Information, "Your sensors picked up short bursts of subspace signals near the construction zone."%_T)
    Player():sendChatMessage(""%_T, ChatMessageType.Warning, "Subspace signatures are surging. Brace for a major Xsotan assault!"%_T)

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnInvasionCode, "run")
    c.invasionStarted = true
end

local function canOwnGateAt(x, y)
    local c = missionData.custom
    local builderFaction = Faction(c.builderFactionIndex)
    if not builderFaction then return false, "Building faction no longer exists."%_T end

    local controller = Galaxy():getControllingFaction(x, y)
    if not controller then return true end

    local status = controller:getRelationStatus(builderFaction.index)
    if status == RelationStatus.War then
        return false, "A sector controller is now at war with the builder faction. Activation halted."%_T
    end

    return true
end

local function isSectorClearOfHostiles(x, y)
    local clearCode = [[
    function run(playerIndex, missionId)
        local owner = Player(playerIndex)
        local clear = true

        for _, ship in pairs({Sector():getEntitiesByType(EntityType.Ship)}) do
            if valid(ship)
                    and not ship.playerOrAllianceOwned
                    and (ship:getValue("is_xsotan") ~= nil
                        or ship:getValue("is_pirate") ~= nil
                        or ship:getValue("background_attacker") ~= nil) then
                clear = false
                break
            end

            if valid(ship)
                    and not ship.playerOrAllianceOwned
                    and ship.factionIndex ~= 0
                    and owner
                    and owner:getRelationStatus(ship.factionIndex) == RelationStatus.War then
                clear = false
                break
            end
        end

        if clear then
            for _, station in pairs({Sector():getEntitiesByType(EntityType.Station)}) do
                if valid(station)
                        and station.factionIndex ~= 0
                        and owner
                        and owner:getRelationStatus(station.factionIndex) == RelationStatus.War then
                    clear = false
                    break
                end
            end
        end

        if owner then
            owner:setValue("gate_construction_sector_clear_" .. tostring(missionId), clear)
        end
    end
    ]]

    local c = missionData.custom
    runSectorCode(x, y, true, clearCode, "run", Player().index, c.missionId)
    return Player():getValue("gate_construction_sector_clear_" .. tostring(c.missionId)) == true
end

local function clearInactiveAndSpawnActiveGates()
    local c = missionData.custom
    local key = missionKey(c.missionId)

    local okA, errA = canOwnGateAt(c.endpointA.x, c.endpointA.y)
    if not okA then return false, errA end

    local okB, errB = canOwnGateAt(c.endpointB.x, c.endpointB.y)
    if not okB then return false, errB end

    runSectorCode(c.endpointA.x, c.endpointA.y, true, deleteMissionEntitiesCode, "run", key)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, deleteMissionEntitiesCode, "run", key)

    local ownerA = Galaxy():getControllingFaction(c.endpointA.x, c.endpointA.y)
    local ownerB = Galaxy():getControllingFaction(c.endpointB.x, c.endpointB.y)

    local ownerAIndex = ownerA and ownerA.index or c.commissioningFactionIndex
    local ownerBIndex = ownerB and ownerB.index or c.commissioningFactionIndex

    runSectorCode(c.endpointA.x, c.endpointA.y, true, gateActivationVfxCode, "run", key)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, gateActivationVfxCode, "run", key)

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnActiveGateCode, "run", key, ownerAIndex, c.endpointB.x, c.endpointB.y)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, spawnActiveGateCode, "run", key, ownerBIndex, c.endpointA.x, c.endpointA.y)

    return true
end

local function checkXsotanCount()
    local c = missionData.custom
    runSectorCode(c.endpointA.x, c.endpointA.y, true, countXsotanCode, "run", Player().index, c.missionId)
    return Player():getValue("gate_construction_xsotan_" .. tostring(c.missionId)) or 0
end

function initialize(stationIndex, builderFactionIndex, commissioningFactionIndex, ax, ay, bx, by, creditsPaid, ironAmount, triniumAmount, xanionAmount, avorionAmount, goodsName, goodsAmount)
    initMissionCallbacks()

    if onClient() then
        if not missionData.custom then missionData.custom = {} end
        sync()
        return
    end

    if not stationIndex then return end

    local sx, sy = Sector():getCoordinates()
    local routeDistance = distance2d(ax, ay, bx, by)
    local missionId = random():getInt(100000, 99999999)

    missionData.custom = {
        missionId = missionId,
        stationIndex = stationIndex,
        builderFactionIndex = builderFactionIndex,
        commissioningFactionIndex = commissioningFactionIndex,
        endpointA = {x = ax, y = ay},
        endpointB = {x = bx, y = by},
        dispatchSector = {x = sx, y = sy},
        routeDistance = routeDistance,
        creditsPaid = creditsPaid,
        ironAmount = ironAmount,
        triniumAmount = triniumAmount,
        xanionAmount = xanionAmount,
        avorionAmount = avorionAmount,
        goodsName = goodsName,
        goodsAmount = goodsAmount,
        phase = 1,
        xsotanPoll = 0,
        invasionStarted = false,
        completionDelay = 8,
        activationRequested = false,
    }

    missionData.custom.arrivalCountdown = math.max(60, math.floor(50 + routeDistance * 18))

    missionData.brief = "Construct Gate"%_T
    missionData.title = "Gate Construction (${ax}:${ay}) <-> (${bx}:${by})"%_T % {ax = ax, ay = ay, bx = bx, by = by}
    missionData.autoTrackMission = true

    updateObjectivesFromPhase()

    Player():sendChatMessage("Research Station"%_T, ChatMessageType.Normal,
        "Contract accepted. The research station will construct an inactive gate in sector (${x}:${y}) once the site is secure."%_T, ax, ay)

    sync()
end

function getUpdateInterval()
    return 2
end

function update(timeStep)
    if not missionData.custom then return end

    local c = missionData.custom

    if c.phase == 1 then
        c.arrivalCountdown = c.arrivalCountdown - timeStep

        local clear = isSectorClearOfHostiles(c.endpointA.x, c.endpointA.y)
        if not clear then
            c.arrivalCountdown = math.max(c.arrivalCountdown, 35)
            c.waitingForClearSector = true
            sync()
            return
        end

        if c.waitingForClearSector then
            Player():sendChatMessage("Research Station"%_T, ChatMessageType.Information,
                "Construction zone is now clear. The station is preparing the inactive gate in (${x}:${y})."%_T,
                c.endpointA.x, c.endpointA.y)
            c.waitingForClearSector = false
        end

        if c.arrivalCountdown <= 0 then
            spawnInactiveAnchors()

            c.phase = 2

            Player():sendChatMessage("Research Station"%_T, ChatMessageType.Normal,
                "The inactive gate has appeared in (${x}:${y}). Interact with it to begin activation."%_T,
                c.endpointA.x, c.endpointA.y)

            updateObjectivesFromPhase()
            sync()
        end

    elseif c.phase == 2 then
        if c.activationRequested then
            c.phase = 3
            c.xsotanPoll = 0
            spawnInvasion()

            Player():sendChatMessage("Research Station"%_T, ChatMessageType.Warning,
                "Activation sequence started. Defend the construction sector until all Xsotan are destroyed!"%_T)

            updateObjectivesFromPhase()
            sync()
        end

    elseif c.phase == 3 then
        c.xsotanPoll = c.xsotanPoll + timeStep

        if c.xsotanPoll >= 6 then
            c.xsotanPoll = 0
            local xsotanCount = checkXsotanCount()

            if c.invasionStarted and xsotanCount <= 0 then
                local ok, err = clearInactiveAndSpawnActiveGates()
                if not ok then
                    missionData.failMessage = err
                    showMissionFailed()
                    cleanupMissionEntities()
                    terminate()
                    return
                end

                c.phase = 4
                updateObjectivesFromPhase()
                sync()

                Player():sendChatMessage("Research Station"%_T, ChatMessageType.Normal,
                    "The new gate route is online. The construction team is withdrawing from the sector."%_T)

                showMissionAccomplished()
            end
        end

    elseif c.phase == 4 then
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

    if (not c.ironAmount or not c.triniumAmount or not c.xanionAmount or not c.avorionAmount) and c.resourceAmount and c.resourceIndex then
        matText = "${amount} unit(s) of tier ${tier}"%_T % {
            amount = c.resourceAmount,
            tier = c.resourceIndex,
        }
    end

    local base = "Two endpoints were contracted: (${ax}:${ay}) and (${bx}:${by}).\nCredits fee paid: ¢${credits}. Material downpayment: ${mat}."%_T % {
        ax = c.endpointA.x,
        ay = c.endpointA.y,
        bx = c.endpointB.x,
        by = c.endpointB.y,
        credits = createMonetaryString(c.creditsPaid or 0),
        mat = matText,
    }

    if c.phase == 1 then
        return base .. "\n\nCurrent Objective: Wait for the inactive gate to be constructed in the destination sector."%_T
    elseif c.phase == 2 then
        return base .. "\n\nCurrent Objective: Interact with the inactive gate in (${x}:${y}) to begin activation."%_T % {
            x = c.endpointA.x,
            y = c.endpointA.y,
        }
    elseif c.phase == 3 then
        return base .. "\n\nCurrent Objective: Destroy all Xsotan attackers in (${x}:${y})."%_T % {
            x = c.endpointA.x,
            y = c.endpointA.y,
        }
    end

    return base .. "\n\nGate successfully activated."%_T
end

function abandon()
    if onClient() then
        invokeServerFunction("abandon")
        return
    end

    refundMaterialsOnly()
    cleanupMissionEntities()

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
