package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("callable")
include("stringutility")
include("utility")
include("randomext")
include("relations")
include("faction")
include("galaxy")
local Dialog = include("dialogutility")
local GatesMap = include("gatesmap")
local GateConstructionLinks = include("gateconstructionlinks")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace GateCommissionHub
GateCommissionHub = {}
GateCommissionHub.interactionThreshold = -30000

-- Server-side construction queue state, persisted through secure()/restore().
GateCommissionHub.data = {}

local ui = {}

local FIXED_CREDITS_FEE = 5000000
local FIXED_OGONITE_AMOUNT = 200000
local FIXED_AVORION_AMOUNT = 100000

local BUILD_TIME = 5 * 60
local BUILD_TIME_MINUTES = math.max(1, math.ceil(BUILD_TIME / 60))

-- The harnessing beam is timed to stop exactly when the gates come online.
local BEAM_DURATION = 3

local function makeResourceVector()
    -- Material order: iron, titanium, naonite, trinium, xanion, ogonite, avorion.
    local result = {0, 0, 0, 0, 0, 0, 0}
    result[6] = FIXED_OGONITE_AMOUNT
    result[7] = FIXED_AVORION_AMOUNT
    return result
end

local function distance2d(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function computeQuote(ax, ay, bx, by)
    local jumpDistance = distance2d(ax, ay, bx, by)

    return {
        jumpDistance = jumpDistance,
        credits = FIXED_CREDITS_FEE,
        ogoniteAmount = FIXED_OGONITE_AMOUNT,
        avorionAmount = FIXED_AVORION_AMOUNT,
    }
end

local function hasKnownSectorFor(player, buyer, x, y)
    if buyer and buyer.getKnownSector then
        local known = buyer:getKnownSector(x, y)
        if known then return true end
    end

    if player and player.getKnownSector then
        local known = player:getKnownSector(x, y)
        if known then return true end
    end

    if player and player.alliance and player.alliance.getKnownSector then
        local known = player.alliance:getKnownSector(x, y)
        if known then return true end
    end

    return false
end

local function isAtWarWithBuilder(x, y, builderFaction)
    if not builderFaction then return false end

    local controller = Galaxy():getControllingFaction(x, y)
    if not controller then return false end
    if controller.index == builderFaction.index then return false end

    local status = controller:getRelationStatus(builderFaction.index)
    return status == RelationStatus.War
end

local function sectorsAlreadyGateConnected(ax, ay, bx, by)
    if GateConstructionLinks.exists(ax, ay, bx, by) then return true end

    local map = GatesMap(Server().seed)

    -- Cheap rejection first: without natural gates on both ends there is no vanilla link.
    if not map:hasGates(ax, ay) or not map:hasGates(bx, by) then return false end

    for _, connected in pairs(map:getConnectedSectors({x = ax, y = ay})) do
        if connected.x == bx and connected.y == by then return true end
    end

    return false
end

local function validateProject(ax, ay, bx, by, player, buyer)
    if not ax or not ay or not bx or not by then
        return false, "Select two endpoints first."%_T
    end

    if ax == bx and ay == by then
        return false, "A gate cannot connect a sector to itself."%_T
    end

    local map = GatesMap(Server().seed)
    local maxGateDistance = map.range or 45
    local d = distance2d(ax, ay, bx, by)

    if d > maxGateDistance then
        return false, "This route is too long. Maximum connection distance is ${max}."%_T % {max = maxGateDistance}
    end

    if not hasKnownSectorFor(player, buyer, ax, ay) then
        return false, "Sector (${x}:${y}) has not been discovered yet."%_T % {x = ax, y = ay}
    end

    if not hasKnownSectorFor(player, buyer, bx, by) then
        return false, "Sector (${x}:${y}) has not been discovered yet."%_T % {x = bx, y = by}
    end

    if sectorsAlreadyGateConnected(ax, ay, bx, by) then
        return false, "These sectors are already connected by a gate."%_T
    end

    return true
end

local function isCoreResearchStation(station, buyer)
    if not station or not buyer then return false end
    if station.factionIndex ~= buyer.index then return false end

    local x, y = Sector():getCoordinates()
    return x == 0 and y == 0
end

local function hasLegendaryWormholePowerDiverter(station)
    if not station then return false end

    local systems = ShipSystem(station)
    if not systems or not systems.getUpgrades then return false end

    for upgrade, permanent in pairs(systems:getUpgrades()) do
        if upgrade
                and permanent == true
                and upgrade.rarity
                and upgrade.rarity.value == RarityType.Legendary
                and upgrade.script
                and (upgrade.script == "data/scripts/systems/wormholeopener.lua" or upgrade.script == "systems/wormholeopener.lua") then
            return true
        end
    end

    return false
end

local spawnActiveGateCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("galaxy")
local PlanGenerator = include("plangenerator")
local StyleGenerator = include("internal/stylegenerator.lua")

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

    -- Without this marker, sector/background/gatecompatibility.lua wipes every gate in
    -- the sector on the next load and regenerates only the ones in the vanilla gates map.
    Sector():setValue("gates2.0", true)

    local gate = Sector():createEntity(desc)
    if valid(gate) then
        gate:setValue("gate_construction_active_gate", true)
    end
end
]]

-- The Xsotan wave is generated asynchronously, so it has to run in this script's own
-- (persistent) state: a chunk passed to runSectorCode is discarded as soon as it returns
-- and the generator's callback would never fire. The station sits in 0:0 anyway.
function GateCommissionHub.spawnXsotanInvasion()
    local AsyncXsotanGenerator = include("asyncxsotangenerator")
    local SpawnUtility = include("spawnutility")

    local volumes = {1, 1, 2, 3, 3, 5, 3, 3, 2, 1, 1}

    -- Match the regular large invasion shape and spawn it twice.
    local wave = {}
    for i = 1, 2 do
        for _, size in pairs(volumes) do
            table.insert(wave, size)
        end
    end

    -- Held on the namespace so the generator outlives this call and its async callback fires.
    local generator = AsyncXsotanGenerator(GateCommissionHub, function(generated)
        SpawnUtility.addEnemyBuffs(generated)

        local builderFactionIndex = Entity().factionIndex

        for _, xsotan in pairs(generated) do
            local shipAI = ShipAI(xsotan.id)

            shipAI:registerEnemyFaction(builderFactionIndex)
            for _, player in pairs({Sector():getPlayers()}) do
                shipAI:registerEnemyFaction(player.index)
            end

            shipAI:setAggressive()
        end

        GateCommissionHub.xsotanGenerator = nil
    end)
    GateCommissionHub.xsotanGenerator = generator

    local dir = normalize(vec3(getFloat(-1, 1), getFloat(-1, 1), getFloat(-1, 1)))
    local up = vec3(0, 1, 0)
    local right = normalize(cross(dir, up))
    local pos = dir * 1500

    generator:startBatch()
    for _, size in pairs(wave) do
        generator:createShip(MatrixLookUpPosition(-dir, up, pos), size)
        pos = pos + right * 95
    end
    generator:endBatch()
end

-- Fires a guardian-style channel beam from the Research Station into the galactic
-- core, replicating the wormhole-harnessing effect used by the Wormhole Guardian.
-- createLaser() is client-only, so the server just broadcasts.
function GateCommissionHub.fireHarnessingBeam()
    if onServer() then
        broadcastInvokeClientFunction("fireHarnessingBeam")
        return
    end

    local station = Entity()
    if not valid(station) then return end

    -- Planet(0) in sector 0:0 is the central black hole. It is a backdrop object, so its
    -- position is a direction rather than a world point: the beam has to be shot far
    -- along that direction, exactly like WormholeGuardian.createChannelBeam does.
    local dir = vec3(1, 0, 0)
    local planet = Planet(0)
    if valid(planet) then
        dir = normalize(planet.position.translation)
    end

    local from = station.translationf

    local laser = Sector():createLaser(from, from + dir * 500000, ColorRGB(0.9, 0.6, 0.2), 25.0)
    laser.maxAliveTime = BEAM_DURATION
    laser.animationSpeed = -500
    laser.collision = false
end

local function getProject()
    return GateCommissionHub.data.project
end

function GateCommissionHub.interactionPossible(playerIndex, option)
    if not CheckFactionInteraction(playerIndex, GateCommissionHub.interactionThreshold) then
        return false
    end

    local player = Player(playerIndex)
    local station = Entity()
    if not player or not station then return false end

    local ownerOk = station.factionIndex == player.index
    if not ownerOk and player.alliance then
        ownerOk = station.factionIndex == player.alliance.index
    end
    if not ownerOk then return false end

    local x, y = Sector():getCoordinates()
    if x ~= 0 or y ~= 0 then return false end

    return true
end

function GateCommissionHub.initialize()
    if onServer() then
        GateCommissionHub.data = GateCommissionHub.data or {}
        -- Keeps the build timer running while the sector is unloaded, like a shipyard job.
        Sector():registerCallback("onRestoredFromDisk", "onRestoredFromDisk")
    end
end

function GateCommissionHub.onRestoredFromDisk(timeSinceLastSimulation)
    GateCommissionHub.updateServer(timeSinceLastSimulation)
end

function GateCommissionHub.secure()
    return GateCommissionHub.data
end

function GateCommissionHub.restore(data)
    GateCommissionHub.data = data or {}
end

function GateCommissionHub.getUpdateInterval()
    -- Tick every second while building so the beam can be timed to the second.
    if onServer() and getProject() then return 1 end
    return 5
end

-- runSectorCode only works on sectors that are already in memory, so an endpoint
-- has to be loaded first. Loading is asynchronous, hence the retry loop.
local function spawnGateIn(project, x, y, tx, ty)
    local galaxy = Galaxy()

    if not galaxy:sectorLoaded(x, y) then
        galaxy:loadSector(x, y)
        return false
    end

    -- Keep it around long enough for the queued code to actually run.
    galaxy:keepSector(x, y, 30)

    local result = runSectorCode(x, y, true, spawnActiveGateCode, "run",
        project.builderFactionIndex, tx, ty)

    if result ~= nil and result ~= 0 then
        return false
    end

    return true
end

-- The galaxy map is drawn from stored sector views, so the new link stays invisible
-- until it is written into them (same approach as the Gate Map Upgrade item).
local function registerGateOnMap(faction, x, y, tx, ty)
    -- Only Player and Alliance carry sector views; a plain Faction does not.
    if not faction or not faction.getKnownSector then return end

    local view = faction:getKnownSector(x, y)
    if not view then return end

    local destinations = {view:getGateDestinations()}
    for _, destination in pairs(destinations) do
        if destination.x == tx and destination.y == ty then return end
    end

    table.insert(destinations, ivec2(tx, ty))
    view:setGateDestinations(unpack(destinations))
    faction:updateKnownSector(view)
end

local function updateGateMaps(project)
    local a = project.endpointA
    local b = project.endpointB

    local factions = {}

    local player = Player(project.commissioningPlayerIndex)
    if player then
        factions[player.index] = player
        if player.alliance then factions[player.alliance.index] = player.alliance end
    end

    for _, faction in pairs(factions) do
        registerGateOnMap(faction, a.x, a.y, b.x, b.y)
        registerGateOnMap(faction, b.x, b.y, a.x, a.y)
    end
end

function GateCommissionHub.finishProject()
    local project = getProject()
    if not project then return end

    local a = project.endpointA
    local b = project.endpointB
    local playerIndex = project.commissioningPlayerIndex

    -- Cleared up front so a failure below can never leave activation retrying forever.
    GateCommissionHub.data.project = nil

    GateConstructionLinks.add(a.x, a.y, b.x, b.y)
    updateGateMaps(project)

    local station = Entity()
    station:setValue("gate_construction_busy", false)

    local player = Player(playerIndex)
    if player then
        -- sendChatMessage substitutes %1%-style placeholders, not ${named} ones.
        player:sendChatMessage(station, ChatMessageType.Normal,
            "Gate construction complete. The gates linking (%1%:%2%) and (%3%:%4%) are now online. Brace yourself - the harnessed wormhole energy has drawn a Xsotan wave into this sector!"%_T,
            a.x, a.y, b.x, b.y)
    end

    GateCommissionHub.spawnXsotanInvasion()
end

function GateCommissionHub.updateActivation()
    local project = getProject()
    if not project then return end

    local a = project.endpointA
    local b = project.endpointB

    if not project.spawnedA then
        project.spawnedA = spawnGateIn(project, a.x, a.y, b.x, b.y)
    end

    if not project.spawnedB then
        project.spawnedB = spawnGateIn(project, b.x, b.y, a.x, a.y)
    end

    if project.spawnedA and project.spawnedB then
        GateCommissionHub.finishProject()
    end
end

function GateCommissionHub.updateServer(timeStep)
    local project = getProject()
    if not project then return end

    if project.activating then
        GateCommissionHub.updateActivation()
        return
    end

    project.remaining = (project.remaining or 0) - timeStep

    -- Start the beam BEAM_DURATION seconds out so it dies exactly as the gates appear.
    if not project.beamFired and project.remaining <= BEAM_DURATION then
        project.beamFired = true
        GateCommissionHub.fireHarnessingBeam()
    end

    if project.remaining <= 0 then
        project.remaining = 0
        project.activating = true
        GateCommissionHub.updateActivation()
    end
end

function GateCommissionHub.initUI()
    local res = getResolution()
    local size = vec2(560, 550)

    local menu = ScriptUI()
    local window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    menu:registerWindow(window, "Gate Commission"%_T, 10)

    window.caption = "Gate Construction Research"%_T
    window.showCloseButton = 1
    window.moveable = 1

    local lister = UIVerticalLister(Rect(vec2(10, 10), size - vec2(10, 10)), 10, 0)

    local introRect = lister:nextRect(96)
    ui.intro = window:createTextField(introRect,
        "Commissioning a gate is expensive and dangerous. This station needs ${m} minutes to bring the new link online, and construction continues even while you are away. Activating the link attracts a large Xsotan wave, so have your fleet ready."%_t % {m = BUILD_TIME_MINUTES})
    ui.intro.fontSize = 13
    ui.intro.fontColor = ColorRGB(0.7, 0.7, 0.7)

    local rowA = lister:nextRect(32)
    local rowALister = UIHorizontalLister(rowA, 10, 0)
    ui.labelA = window:createLabel(rowALister:nextRect(230), "Endpoint A: not selected"%_T, 12)
    ui.labelA:setLeftAligned()
    ui.pickA = window:createButton(rowALister.inner, "Use Galaxy Selection"%_T, "onPickA")

    local rowB = lister:nextRect(32)
    local rowBLister = UIHorizontalLister(rowB, 10, 0)
    ui.labelB = window:createLabel(rowBLister:nextRect(230), "Endpoint B: not selected"%_T, 12)
    ui.labelB:setLeftAligned()
    ui.pickB = window:createButton(rowBLister.inner, "Use Galaxy Selection"%_T, "onPickB")

    local rowMap = lister:nextRect(32)
    ui.openMap = window:createButton(rowMap, "Open Galaxy Map"%_T, "onOpenMap")

    local quoteFrame = lister:nextRect(150)
    window:createFrame(quoteFrame)
    local quoteLister = UIVerticalLister(quoteFrame, 8, 6)

    ui.quoteTitle = window:createLabel(quoteLister:nextRect(18), "Project Estimate"%_T, 13)
    ui.quoteTitle:setCenterAligned()

    ui.distanceLabel = window:createLabel(quoteLister:nextRect(18), "Route Distance: -"%_T, 12)
    ui.creditsLabel = window:createLabel(quoteLister:nextRect(18), "Credits Fee: -"%_T, 12)
    ui.resourcesLabel = window:createLabel(quoteLister:nextRect(18), "Material Downpayment: -"%_T, 12)
    ui.unlockLabel = window:createLabel(quoteLister:nextRect(18), "Wormhole Power Diverter: -"%_T, 12)

    local statusRect = lister:nextRect(20)
    ui.statusLabel = window:createLabel(statusRect, "", 13)
    ui.statusLabel:setLeftAligned()
    ui.statusLabel.color = ColorRGB(0.55, 0.85, 1.0)

    local errorRect = lister:nextRect(40)
    ui.errorLabel = window:createTextField(errorRect, "")
    ui.errorLabel.fontSize = 13
    ui.errorLabel.fontColor = ColorRGB(0.95, 0.25, 0.25)

    local buttonRow = lister:nextRect(34)
    ui.start = window:createButton(buttonRow, "Commission Gate Project"%_T, "onStartProject")
    ui.start.active = false

    ui.selectedA = nil
    ui.selectedB = nil
    ui.busy = false
    ui.remaining = 0
end

function GateCommissionHub.onShowWindow()
    invokeServerFunction("requestStatus")
    GateCommissionHub.refreshQuote()
end

function GateCommissionHub.onOpenMap()
    local x, y = Sector():getCoordinates()
    GalaxyMap():show(x, y)
end

local function selectedMapCoordinates()
    local map = GalaxyMap()
    if not map then return nil end

    local x, y = map:getSelectedCoordinates()
    if x == nil or y == nil then return nil end

    return x, y
end

local function updateEndpointLabels()
    if ui.selectedA then
        ui.labelA.caption = "Endpoint A: (${x}:${y})"%_T % ui.selectedA
    else
        ui.labelA.caption = "Endpoint A: not selected"%_T
    end

    if ui.selectedB then
        ui.labelB.caption = "Endpoint B: (${x}:${y})"%_T % ui.selectedB
    else
        ui.labelB.caption = "Endpoint B: not selected"%_T
    end
end

local function clearQuoteLabels()
    ui.distanceLabel.caption = "Route Distance: -"%_T
    ui.creditsLabel.caption = "Credits Fee: -"%_T
    ui.resourcesLabel.caption = "Material Downpayment: -"%_T
    ui.unlockLabel.caption = "Wormhole Power Diverter: -"%_T
end

local function updateStatusLabel()
    if not ui.statusLabel then return end

    if ui.busy and ui.project then
        if (ui.remaining or 0) <= 0 then
            ui.statusLabel.caption = "Bringing the (${ax}:${ay}) <-> (${bx}:${by}) link online..."%_T % ui.project
        else
            ui.statusLabel.caption = "Building (${ax}:${ay}) <-> (${bx}:${by}) - ${m} min remaining"%_T % {
                ax = ui.project.ax,
                ay = ui.project.ay,
                bx = ui.project.bx,
                by = ui.project.by,
                m = math.max(1, math.ceil((ui.remaining or 0) / 60)),
            }
        end
        ui.statusLabel.color = ColorRGB(0.95, 0.7, 0.35)
    else
        ui.statusLabel.caption = "Construction bay idle."%_T
        ui.statusLabel.color = ColorRGB(0.55, 0.85, 1.0)
    end
end

function GateCommissionHub.receiveStatus(busy, ax, ay, bx, by, remaining)
    local wasBusy = ui.busy
    ui.busy = busy == true
    ui.remaining = remaining or 0

    if ui.busy then
        ui.project = {ax = ax, ay = ay, bx = bx, by = by}
        if ui.start then ui.start.active = false end
    else
        ui.project = nil
        if wasBusy then GateCommissionHub.refreshQuote() end
    end

    updateStatusLabel()
end

function GateCommissionHub.updateClient(timeStep)
    if not ui.busy then return end

    if (ui.remaining or 0) > 0 then
        ui.remaining = math.max(0, ui.remaining - timeStep)
    else
        -- Waiting on the endpoints to load and the gates to spawn; poll the station.
        ui.statusPoll = (ui.statusPoll or 0) + timeStep
        if ui.statusPoll >= 10 then
            ui.statusPoll = 0
            invokeServerFunction("requestStatus")
        end
    end

    updateStatusLabel()
end

function GateCommissionHub.refreshQuote()
    ui.errorLabel.text = ""
    ui.start.active = false

    if not ui.selectedA or not ui.selectedB then
        clearQuoteLabels()
        return
    end

    invokeServerFunction("requestQuote", ui.selectedA.x, ui.selectedA.y, ui.selectedB.x, ui.selectedB.y)
end

function GateCommissionHub.onPickA()
    local x, y = selectedMapCoordinates()
    if not x or not y then return end

    ui.selectedA = {x = x, y = y}
    updateEndpointLabels()
    GateCommissionHub.refreshQuote()
end

function GateCommissionHub.onPickB()
    local x, y = selectedMapCoordinates()
    if not x or not y then return end

    ui.selectedB = {x = x, y = y}
    updateEndpointLabels()
    GateCommissionHub.refreshQuote()
end

function GateCommissionHub.receiveQuote(ok, quote, err)
    if not ok then
        clearQuoteLabels()
        ui.start.active = false
        ui.errorLabel.text = err or ""
        return
    end

    ui.errorLabel.text = ""
    ui.start.active = not ui.busy

    ui.distanceLabel.caption = "Route Distance: ${d}"%_T % {d = string.format("%.1f", quote.jumpDistance or 0)}
    ui.creditsLabel.caption = "Credits Fee: ¢${c}"%_T % {c = createMonetaryString(quote.credits or 0)}
    ui.resourcesLabel.caption = "Material Downpayment: ${avorion} Avorion + ${ogonite} Ogonite"%_T % {
        avorion = quote.avorionAmount or 0,
        ogonite = quote.ogoniteAmount or 0,
    }
    if quote.hasWormholePowerDiverter == true then
        ui.unlockLabel.caption = "Wormhole Power Diverter: ✓ installed"%_T
    else
        ui.unlockLabel.caption = "Wormhole Power Diverter: ✗ missing"%_T
    end
end

function GateCommissionHub.onStartProject()
    if ui.busy then return end

    if not ui.selectedA or not ui.selectedB then
        local d = Dialog.empty()
        d.text = "Select both endpoints first."%_T
        ScriptUI():showDialog(d)
        return
    end

    invokeServerFunction("startCommission", ui.selectedA.x, ui.selectedA.y, ui.selectedB.x, ui.selectedB.y)
end

function GateCommissionHub.commissionResult(ok, message)
    local d = Dialog.empty()
    d.text = message or ""
    d.talker = "Research Station"%_T
    ScriptUI():showDialog(d)
end

function GateCommissionHub.requestQuote(ax, ay, bx, by)
    local player = Player(callingPlayer)
    local buyer = getInteractingFaction(callingPlayer)

    local ok, err = validateProject(ax, ay, bx, by, player, buyer)
    if not ok then
        invokeClientFunction(player, "receiveQuote", false, nil, err)
        return
    end

    local quote = computeQuote(ax, ay, bx, by)
    local station = Entity()
    quote.hasWormholePowerDiverter = hasLegendaryWormholePowerDiverter(station)
    invokeClientFunction(player, "receiveQuote", true, quote, "")
end
callable(GateCommissionHub, "requestQuote")

function GateCommissionHub.requestStatus()
    local player = Player(callingPlayer)
    if not player then return end

    local project = getProject()
    if not project then
        invokeClientFunction(player, "receiveStatus", false, 0, 0, 0, 0, 0)
        return
    end

    invokeClientFunction(player, "receiveStatus", true,
        project.endpointA.x, project.endpointA.y,
        project.endpointB.x, project.endpointB.y,
        math.max(0, project.remaining or 0))
end
callable(GateCommissionHub, "requestStatus")

function GateCommissionHub.startCommission(ax, ay, bx, by)
    local player = Player(callingPlayer)
    if not player then return end

    if not CheckFactionInteraction(callingPlayer, GateCommissionHub.interactionThreshold) then
        invokeClientFunction(player, "commissionResult", false, "You don't have permission to commission this project."%_T)
        return
    end

    local station = Entity()

    local buyer, ship, interactingPlayer = getInteractingFaction(callingPlayer, AlliancePrivilege.SpendResources)
    if not buyer then
        invokeClientFunction(player, "commissionResult", false, "You are missing the privileges required to spend resources."%_T)
        return
    end

    local ok, err = validateProject(ax, ay, bx, by, interactingPlayer or player, buyer)
    if not ok then
        invokeClientFunction(player, "commissionResult", false, err)
        return
    end

    local builderFaction = Faction(station.factionIndex)

    if not isCoreResearchStation(station, buyer) then
        invokeClientFunction(player, "commissionResult", false,
            "This gate project can only be commissioned from your own Research Station in sector 0:0."%_T)
        return
    end

    if not hasLegendaryWormholePowerDiverter(station) then
        invokeClientFunction(player, "commissionResult", false,
            "This Research Station needs a permanently installed legendary Wormhole Power Diverter before it can commission gate construction."%_T)
        return
    end

    if getProject() or station:getValue("gate_construction_busy") then
        invokeClientFunction(player, "commissionResult", false, "This research station already has an active gate project in progress."%_T)
        return
    end

    if isAtWarWithBuilder(ax, ay, builderFaction) or isAtWarWithBuilder(bx, by, builderFaction) then
        invokeClientFunction(player, "commissionResult", false, "A controlling faction on one endpoint is at war with this research station's faction."%_T)
        return
    end

    local quote = computeQuote(ax, ay, bx, by)
    local resources = makeResourceVector()

    local canPay, msg, args = buyer:canPay(quote.credits, unpack(resources))
    if not canPay then
        invokeClientFunction(player, "commissionResult", false, (msg or "Insufficient funds."%_T), unpack(args or {}))
        return
    end

    buyer:pay("Paid gate construction downpayment."%_T, quote.credits, unpack(resources))

    GateCommissionHub.data.project = {
        endpointA = {x = ax, y = ay},
        endpointB = {x = bx, y = by},
        builderFactionIndex = station.factionIndex,
        commissioningFactionIndex = buyer.index,
        commissioningPlayerIndex = callingPlayer,
        remaining = BUILD_TIME,
    }

    station:setValue("gate_construction_busy", true)

    invokeClientFunction(player, "receiveStatus", true, ax, ay, bx, by, BUILD_TIME)
    player:sendChatMessage(station, ChatMessageType.Normal,
        "Thank you for your purchase. The gates will be constructed in about %1% minutes. Expect a Xsotan assault near sector 0:0 once the link goes online."%_T,
        BUILD_TIME_MINUTES)
end
callable(GateCommissionHub, "startCommission")
