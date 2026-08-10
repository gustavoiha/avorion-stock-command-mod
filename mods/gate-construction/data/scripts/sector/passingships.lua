-- Lets gate-connected factions send traffic through their links.
-- Injected before the end of the vanilla script, so file locals such as PassingShipType
-- and Placer are in scope, but locals declared inside vanilla's `if onServer()` are not.

if onServer() then

local GateInfluence = include("gateinfluence")

local TrafficBonusScale = 2
local TrafficBonusMax = 3

local vanillaAddPassingBehavior = PassingShips.addPassingBehavior

-- Set by update() for the duration of one spawn burst, so every ship of a convoy enters
-- through the same gate. Cleared at the start of every update.
local pendingGate = nil

local function findGateTo(tx, ty)
    for _, gate in pairs({Sector():getEntitiesByScript("data/scripts/entity/gate.lua")}) do
        local wormhole = WormHole(gate)
        if wormhole then
            local gx, gy = wormhole:getTargetCoordinates()
            if gx == tx and gy == ty then return gate end
        end
    end
end

local function placeAtGate(ship, gate)
    local entryDistance = ship:getBoundingSphere().radius * 2 + gate:getBoundingSphere().radius

    local side = gate.look
    if dot(gate.look, ship.translationf - gate.translationf) <= 0 then
        side = -gate.look
    end

    local position = gate.translationf + side * entryDistance
    ship.position = MatrixLookUpPosition(side, vec3(0, 1, 0), position)

    Placer.resolveIntersections({ship})
end

function PassingShips.addPassingBehavior(ship, destination_in, gateId_in)
    if not pendingGate then
        return vanillaAddPassingBehavior(ship, destination_in, gateId_in)
    end

    local gate = findGateTo(pendingGate.x, pendingGate.y)
    if not gate then
        return vanillaAddPassingBehavior(ship, destination_in, gateId_in)
    end

    placeAtGate(ship, gate)

    -- Cross the sector instead of turning straight back into the gate it came out of.
    -- Same formula as vanilla, but computed after the move and with the gate exit
    -- suppressed, so the destination is the far side relative to the gate.
    local destination = -ship.translationf + vec3(math.random(), math.random(), math.random()) * 1000
    destination = normalize(destination) * 1500

    return vanillaAddPassingBehavior(ship, destination, nil)
end

local function trafficBonus(influence, localFaction)
    local sum = 0

    for _, entry in pairs(influence) do
        if not localFaction or entry.factionIndex ~= localFaction.index then
            sum = sum + entry.weight
        end
    end

    return math.min(TrafficBonusMax, sum * TrafficBonusScale)
end

function PassingShips.update(timeStep)
    pendingGate = nil

    local sector = Sector()

    -- don't create server load when there are no players to witness it
    if sector.numPlayers == 0 then return end

    -- don't spawn helpless ships in war zones
    if sector:getValue("war_zone") then return end

    local galaxy = Galaxy()
    local x, y = sector:getCoordinates()

    local localFaction = galaxy:getNearestFaction(x + math.random(-15, 15), y + math.random(-15, 15))
    local influence = GateInfluence.getSectorInfluence(x, y)

    local stations = {sector:getEntitiesByType(EntityType.Station)}
    local maxPassThroughs = #stations * 0.5 + 1 + trafficBonus(influence, localFaction)

    local passingShips = {sector:getEntitiesByScriptValue("passing_ship", true)}
    if tablelength(passingShips) >= maxPassThroughs then return end

    local faction = localFaction
    local gateBorne = GateInfluence.rollForeignFaction(influence, localFaction and localFaction.index)

    if gateBorne then
        faction = Faction(gateBorne.factionIndex)

        -- Only emerge from a gate when the carrying gate is actually in this sector.
        if faction and gateBorne.via.x == x and gateBorne.via.y == y then
            pendingGate = gateBorne.viaTarget
        end
    end

    if not faction then return end

    -- outer regions spawn only half as many passing ships
    if not gateBorne and not galaxy:isCentralFactionArea(x, y, faction.index) then
        if random():test(0.5) then
            return
        end
    end

    -- spawn random passing ship
    local typeToSpawn = random():getInt(1, 10)
    if random():test(0.75) then typeToSpawn = PassingShipType.Trader end

    if typeToSpawn == PassingShipType.Trader then
        PassingShips.createPassingTrader(faction)
    elseif typeToSpawn == PassingShipType.CruiseShip then
        PassingShips.createPassingCruiseShip(faction)
    elseif typeToSpawn == PassingShipType.PartyShip then
        PassingShips.createPassingPartyShip(faction)
    elseif typeToSpawn == PassingShipType.PrisonTransport then
        PassingShips.createPassingPrisonTransport(faction)
    elseif typeToSpawn == PassingShipType.SnackBar then
        PassingShips.createPassingSnackBarShip(faction)
    elseif typeToSpawn == PassingShipType.TowBoat then
        PassingShips.createPassingTowBoat(faction)
    elseif typeToSpawn == PassingShipType.FamilyShip then
        PassingShips.createPassingFamilyShip()
    elseif typeToSpawn == PassingShipType.CommuneShip then
        PassingShips.createPassingCommuneShip()
    elseif typeToSpawn == PassingShipType.CavaliersShip then
        PassingShips.createPassingCavaliersShip()
    else
        PassingShips.createPassingFactoryCommuteShuttle(faction)
    end
end

end
