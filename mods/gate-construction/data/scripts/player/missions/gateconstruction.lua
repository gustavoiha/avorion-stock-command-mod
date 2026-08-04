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

local function makeResourceVector(index, amount)
    local result = {0, 0, 0, 0, 0, 0, 0}
    if index and amount and index >= 1 and index <= 7 then
        result[index] = amount
    end
    return result
end

local function missionKey(missionId)
    return missionKeyPrefix .. tostring(missionId)
end

local spawnCargoCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("galaxy")
include("randomext")
local ShipGenerator = include("shipgenerator")

function run(playerIndex, key, factionIndex, goodsName, goodsAmount)
    local x, y = Sector():getCoordinates()
    local faction = Faction(factionIndex) or Galaxy():getNearestFaction(x, y)
    if not faction then return end

    local volume = Balancing_GetSectorShipVolume(x, y)
    local ship = ShipGenerator.createFreighterShip(faction, Matrix(), volume)

    ship.title = "Gate Construction Cargo"%_T
    ship:setValue(key, true)
    ship:setValue("gate_construction_cargo_ship", true)
    ship:setValue("gate_construction_goods_name", goodsName)
    ship:setValue("gate_construction_goods_required", goodsAmount)
    ship:setValue("gate_construction_goods_delivered", 0)
    ship:addScriptOnce("data/scripts/entity/utility/gateconstructioncargoship.lua")
end
]]

local spawnInactiveMarkerCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

local SectorGenerator = include("SectorGenerator")

function run(key, factionIndex, tx, ty)
    local x, y = Sector():getCoordinates()

    local faction = Faction(factionIndex)
    local generator = SectorGenerator(x, y)
    local anchor = generator:createBeacon(nil, faction, "Inactive gate anchor to (${x}:${y})"%_T, {x = tx, y = ty})
    anchor.title = "Inactive Gate Anchor"%_T
    anchor:setValue(key, true)
    anchor:setValue("gate_construction_inactive_anchor", true)
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

local updateDeliveredCode = [[
function run(playerIndex, key, missionId)
    local delivered = 0
    local entities = {Sector():getEntitiesByScriptValue(key)}

    for _, entity in pairs(entities) do
        if valid(entity) and entity:getValue("gate_construction_cargo_ship") then
            delivered = math.max(delivered, entity:getValue("gate_construction_goods_delivered") or 0)
        end
    end

    local player = Player(playerIndex)
    if player then
        player:setValue("gate_construction_delivery_" .. tostring(missionId), delivered)
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

local spawnInvasionCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"

include("randomext")
local AsyncXsotanGenerator = include("asyncxsotangenerator")
local SpawnUtility = include("spawnutility")

function run(scale)
    local volumes = {
        {size = 1}, {size = 1}, {size = 2}, {size = 3}, {size = 3},
        {size = 5}, {size = 3}, {size = 2}, {size = 1}, {size = 1}
    }

    -- double the regular event strength by duplicating the standard shape.
    local wave = {}
    for i = 1, 2 do
        for _, entry in pairs(volumes) do
            table.insert(wave, {size = entry.size * (scale or 1)})
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
        missionData.description[2] = {text = "Wait for the cargo ship to reach sector (${x}:${y}) (${m} min est.)"%_T, arguments = {x = a.x, y = a.y, m = mins}, bulletPoint = true}
    elseif custom.phase == 2 then
        missionData.description[2] = {text = "Deliver ${amount} ${good} to the construction cargo ship in (${x}:${y})"%_T, arguments = {amount = custom.goodsAmount, good = custom.goodsName, x = a.x, y = a.y}, bulletPoint = true}
        missionData.description[3] = {text = "Progress: ${delivered}/${amount}"%_T, arguments = {delivered = custom.goodsDelivered or 0, amount = custom.goodsAmount}, bulletPoint = true}
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

    local resources = makeResourceVector(c.resourceIndex, c.resourceAmount)
    payer:receive("Refunded gate-construction material downpayment after mission cancelation."%_T, 0, unpack(resources))
    c.materialRefunded = true
end

local function spawnInactiveAnchors()
    local c = missionData.custom
    local key = missionKey(c.missionId)

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnInactiveMarkerCode, "run", key, c.builderFactionIndex, c.endpointB.x, c.endpointB.y)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, spawnInactiveMarkerCode, "run", key, c.builderFactionIndex, c.endpointA.x, c.endpointA.y)
end

local function spawnCargoAtDestination()
    local c = missionData.custom
    local key = missionKey(c.missionId)

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnCargoCode, "run", Player().index, key, c.builderFactionIndex, c.goodsName, c.goodsAmount)
end

local function spawnInvasion()
    local c = missionData.custom

    Player():sendChatMessage(""%_T, ChatMessageType.Information, "Your sensors picked up short bursts of subspace signals near the construction zone."%_T)
    Player():sendChatMessage(""%_T, ChatMessageType.Warning, "Subspace signatures are surging. Brace for a major Xsotan assault!"%_T)

    local distance = distance2d(c.endpointA.x, c.endpointA.y, 0, 0)
    local scale = 1
    if distance > 250 then scale = 1.2 end
    if distance > 380 then scale = 1.35 end

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnInvasionCode, "run", scale)
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

    runSectorCode(c.endpointA.x, c.endpointA.y, true, spawnActiveGateCode, "run", key, ownerAIndex, c.endpointB.x, c.endpointB.y)
    runSectorCode(c.endpointB.x, c.endpointB.y, true, spawnActiveGateCode, "run", key, ownerBIndex, c.endpointA.x, c.endpointA.y)

    return true
end

local function checkDeliveryProgress()
    local c = missionData.custom
    runSectorCode(c.endpointA.x, c.endpointA.y, true, updateDeliveredCode, "run", Player().index, missionKey(c.missionId), c.missionId)
    c.goodsDelivered = Player():getValue("gate_construction_delivery_" .. tostring(c.missionId)) or c.goodsDelivered or 0
end

local function checkXsotanCount()
    local c = missionData.custom
    runSectorCode(c.endpointA.x, c.endpointA.y, true, countXsotanCode, "run", Player().index, c.missionId)
    return Player():getValue("gate_construction_xsotan_" .. tostring(c.missionId)) or 0
end

function initialize(stationIndex, builderFactionIndex, commissioningFactionIndex, ax, ay, bx, by, creditsPaid, resourceIndex, resourceAmount, goodsName, goodsAmount)
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
        resourceIndex = resourceIndex,
        resourceAmount = resourceAmount,
        goodsName = goodsName,
        goodsAmount = goodsAmount,
        goodsDelivered = 0,
        phase = 1,
        deliveryPoll = 0,
        xsotanPoll = 0,
        invasionStarted = false,
        completionDelay = 8,
    }

    missionData.custom.arrivalCountdown = math.max(90, math.floor(60 + routeDistance * 22))

    missionData.brief = "Construct Gate"%_T
    missionData.title = "Gate Construction (${ax}:${ay}) <-> (${bx}:${by})"%_T % {ax = ax, ay = ay, bx = bx, by = by}
    missionData.autoTrackMission = true

    updateObjectivesFromPhase()

    Player():sendChatMessage("Travel Hub"%_T, ChatMessageType.Normal,
        "Contract accepted. We have dispatched a cargo ship to sector (${x}:${y})."%_T, ax, ay)

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

        if c.arrivalCountdown <= 0 then
            spawnCargoAtDestination()
            spawnInactiveAnchors()

            c.phase = 2
            c.deliveryPoll = 0

            Player():sendChatMessage("Travel Hub"%_T, ChatMessageType.Normal,
                "Cargo ship arrived in (${x}:${y}). Deliver the required components to begin activation."%_T,
                c.endpointA.x, c.endpointA.y)

            updateObjectivesFromPhase()
            sync()
        end

    elseif c.phase == 2 then
        c.deliveryPoll = c.deliveryPoll + timeStep
        if c.deliveryPoll >= 4 then
            c.deliveryPoll = 0
            checkDeliveryProgress()

            if c.goodsDelivered >= c.goodsAmount then
                c.phase = 3
                c.xsotanPoll = 0
                spawnInvasion()

                Player():sendChatMessage("Travel Hub"%_T, ChatMessageType.Warning,
                    "Activation sequence started. Defend the construction sector until all Xsotan are destroyed!"%_T)

                updateObjectivesFromPhase()
                sync()
            else
                updateObjectivesFromPhase()
                sync()
            end
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

                Player():sendChatMessage("Travel Hub"%_T, ChatMessageType.Normal,
                    "The new gate route is online. Construction cargo ship is leaving the sector."%_T)

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

    local base = "Two endpoints were contracted: (${ax}:${ay}) and (${bx}:${by}).\nCredits fee paid: ¢${credits}. Material downpayment: ${mat}."%_T % {
        ax = c.endpointA.x,
        ay = c.endpointA.y,
        bx = c.endpointB.x,
        by = c.endpointB.y,
        credits = createMonetaryString(c.creditsPaid or 0),
        mat = c.resourceAmount,
    }

    if c.phase == 1 then
        return base .. "\n\nCurrent Objective: Wait for the cargo ship to reach the destination sector."%_T
    elseif c.phase == 2 then
        return base .. "\n\nCurrent Objective: Deliver ${amount} ${good} to the construction cargo ship in (${x}:${y})."%_T % {
            amount = c.goodsAmount,
            good = c.goodsName,
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
