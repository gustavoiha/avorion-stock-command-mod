package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/entity/?.lua"

include ("utility")
include ("stringutility")
local DockAI = include ("ai/dock")
local Placer = include ("placer")

-- Stock Factory mod -- "real" flight behaviour for a stocking ferry.
--
-- This entity script is attached to a Stock Factory ship *appearance* (see the
-- backgroundshipappearance.lua extension) whenever a player is in one of the
-- sectors the ferry operates in. It makes the ferry behave like an NPC trader:
--
--   * arrive through a gate (if the sector has one) instead of just popping in,
--   * fly to one of the owner's stations and dock,
--   * wait a short moment,
--   * fly back out through a gate (if available) and leave.
--
-- If the sector has no gate the ferry falls back to jumping in / out on the spot.
-- It is purely visual: the goods themselves are still moved by the background
-- command (stockfactorycommand.lua). When no player is watching the sector, this
-- script is never attached and the command stays a pure background behaviour.
--
-- Modeled on the vanilla data/scripts/entity/ai/trade.lua (dock behaviour) and
-- data/scripts/entity/ai/passgate.lua (gate approach).

local GateScript = "data/scripts/entity/gate.lua"

-- how long the ferry stays docked, matching vanilla ai/trade.lua's trader wait
local WaitTime = 40

-- extra distance (on top of the gate radius) that counts as "reached the gate"
local GateReachedDistance = 250

-- the route reply travels through two queued round trips (invokeFactionFunction, then
-- runSectorCode), so the ferry holds position rather than assuming it has nowhere to dock
local RouteReplyTimeout = 20
local RouteRequestInterval = 5

local factionIndex
local stationId
local exitGateId
local stage
local waitCount = 0

-- route info supplied by the command (StockFactoryCommand:onFerryRouteRequest),
-- filled in asynchronously by setNextHop()
local nextHop
local nextHopReady = false
local nextHopUseGate = false
local dockTarget

-- arrival bookkeeping: we hold at the spawn point until the command answers with our
-- route, so a slow reply is never mistaken for "nothing to dock at here"
local arrived = false
local routeWait = 0
local sinceRouteRequest = 0

function getUpdateInterval()
    return 1
end

---------------------------------------------------------------------
-- gates
---------------------------------------------------------------------

local function findGates()
    return {Sector():getEntitiesByScript(GateScript)}
end

local function nearestGate(toPosition)
    local best, bestDist

    for _, gate in pairs(findGates()) do
        if valid(gate) then
            local dist = distance(gate.translationf, toPosition)
            if not bestDist or dist < bestDist then
                best = gate
                bestDist = dist
            end
        end
    end

    return best
end

-- a point a little in front of a gate, on the side the ship is currently on, so
-- the ferry lines up with the gate like a real ship would (mirrors ai/passgate)
local function gateEntryPosition(ship, gate)
    local entryDistance = ship:getBoundingSphere().radius * 2 + gate:getBoundingSphere().radius

    if dot(gate.look, ship.translationf - gate.translationf) > 0 then
        return gate.translationf + gate.look * entryDistance
    else
        return gate.translationf - gate.look * entryDistance
    end
end

-- the in-sector gate whose far end is the given sector, if any
local function gateLeadingTo(destX, destY)
    for _, gate in pairs(findGates()) do
        if valid(gate) then
            local wormhole = WormHole(gate)
            if wormhole then
                local gx, gy = wormhole:getTargetCoordinates()
                if gx == destX and gy == destY then
                    return gate
                end
            end
        end
    end
end

-- reposition the ferry so it looks like it just arrived through the given gate
local function repositionToGate(ship, gate)
    local pos = gateEntryPosition(ship, gate)

    -- face roughly into the sector (towards the origin); DockAI turns the ship
    -- towards the station straight afterwards anyway
    local look = -pos
    if distance(pos, vec3(0, 0, 0)) < 1 then
        look = vec3(0, 0, 1)
    end
    look = normalize(look)

    local up = vec3(0, 1, 0)
    if math.abs(look.y) > 0.99 then up = vec3(1, 0, 0) end

    ship.position = MatrixLookUpPosition(look, up, pos)

    -- the vanilla appearance spawn resolved intersections back at the sector
    -- origin; now that we've moved the ferry in front of the gate, nudge it clear
    -- of the gate and anything else nearby
    Placer.resolveIntersections({ship})
end

---------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------

-- ask the background command which sector we should head to next, and whether the
-- route uses a gate there; the answer comes back through setNextHop()
local function requestNextHop()
    local x, y = Sector():getCoordinates()

    pcall(function()
        invokeFactionFunction(factionIndex, true,
            "background/simulation/simulation.lua",
            "invokeCommandFunction", Entity().name, "onFerryRouteRequest", x, y)
    end)
end

function initialize(faction)
    factionIndex = faction
    requestNextHop()
end

-- called by the command (through the sector) with the next hop of our route
function setNextHop(nextX, nextY, useGate, dockFaction, dockName, dockX, dockY, hasDockTarget)
    nextHop = {x = nextX, y = nextY}
    nextHopUseGate = useGate and true or false

    if hasDockTarget and dockName and dockName ~= "" then
        dockTarget = {
            factionIndex = dockFaction,
            name = dockName,
            x = dockX,
            y = dockY,
        }
    else
        dockTarget = nil
    end

    nextHopReady = true
end

function secure()
    return {
        factionIndex = factionIndex,
        stage = stage,
        waitCount = waitCount,
        nextHop = nextHop,
        nextHopReady = nextHopReady,
        nextHopUseGate = nextHopUseGate,
        dockTarget = dockTarget,
    }
end

function restore(values)
    values = values or {}
    factionIndex = values.factionIndex or factionIndex
    stage = values.stage
    waitCount = values.waitCount or 0
    nextHop = values.nextHop
    nextHopReady = values.nextHopReady and true or false
    nextHopUseGate = values.nextHopUseGate and true or false
    dockTarget = values.dockTarget
end

-- exact station for the current pickup/delivery leg, supplied by the command
local function findDockTargetStation()
    if not dockTarget then return end

    local sx, sy = Sector():getCoordinates()
    if sx ~= dockTarget.x or sy ~= dockTarget.y then return end

    local station = Sector():getEntityByFactionAndName(dockTarget.factionIndex or factionIndex, dockTarget.name)
    if not valid(station) then return end

    local docks = DockingPositions(station)
    if not valid(docks) or docks.numDockingPositions <= 0 or not docks.docksEnabled then return end

    return station
end

-- ask the appearance system to jump the ferry back out of the sector
local function requestReturn(ship)
    DockAI.reset()
    ShipAI():setPassive()

    pcall(function()
        invokeFactionFunction(factionIndex, true,
            "background/simulation/shipappearances.lua",
            "returnFerryToBackground", ship.name)
    end)
end

-- fly to the chosen exit gate and, once we reach it, jump out there; if there is
-- no gate, just jump out on the spot
local function leaveThroughGate(ship)
    local gate = exitGateId and Sector():getEntity(exitGateId) or nil

    if not valid(gate) then
        requestReturn(ship)
        stage = 4
        return
    end

    ShipAI():setFly(gateEntryPosition(ship, gate), 0)

    if distance(ship.translationf, gate.translationf) < gate:getBoundingSphere().radius + GateReachedDistance then
        requestReturn(ship)
        stage = 4
    end
end

-- decide which gate to arrive through / leave through: the gate the command routed
-- us to if it's here, otherwise the nearest gate. Returns (gate, isJump); a pure
-- jump leg (no gate on this hop) returns (nil, true).
local function chosenGate(ship)
    if nextHopReady then
        if not nextHopUseGate then
            return nil, true
        end

        local gate = gateLeadingTo(nextHop.x, nextHop.y)
        if valid(gate) then return gate, false end
    end

    return nearestGate(ship.translationf), false
end

-- position the ferry at its entry gate on arrival (or leave it at the spawn point
-- for a pure jump-in)
local function doArrival(ship)
    local gate, isJump = chosenGate(ship)
    if gate and not isJump then
        repositionToGate(ship, gate)
    end
    arrived = true
end

function updateServer(timeStep)
    local ship = Entity()

    -- if the appearance got signed over to the player (e.g. it was attacked),
    -- stop interfering and let the normal ship behaviour take over
    if ship.playerOwned or ship.allianceOwned then
        DockAI.reset()
        terminate()
        return
    end

    local sector = Sector()
    if sector.numPlayers == 0 then
        -- no one is watching; the appearance system will clean the ferry up
        return
    end

    -- arrival: hold at the spawn point until the command tells us our route, retrying the
    -- request, then enter from the correct gate (nearest gate if the reply never lands)
    if not nextHopReady and not arrived then
        routeWait = routeWait + timeStep
        sinceRouteRequest = sinceRouteRequest + timeStep

        if sinceRouteRequest >= RouteRequestInterval then
            sinceRouteRequest = 0
            requestNextHop()
        end

        if routeWait < RouteReplyTimeout then return end
    end

    if not arrived then
        doArrival(ship)
    end

    stage = stage or 0

    -- leaving / done stages don't need the station any more
    if stage == 3 then
        leaveThroughGate(ship)
        return
    elseif stage == 4 then
        return
    end

    -- keep a handle on the station we're visiting
    local station
    if stationId then station = sector:getEntity(stationId) end

    if not valid(station) then
        station = findDockTargetStation()
        if not valid(station) then
            -- this sector is just a transit hop for the current leg
            local gate, isJump = chosenGate(ship)
            exitGateId = (gate and not isJump) and gate.id or nil
            DockAI.reset()
            stage = 3
            return
        end
        stationId = station.id
        DockAI.reset()
        stage = 0
    end

    if stage == 0 then
        -- fly in and dock
        if DockAI.flyToDock(ship, station) then
            stage = 1
            waitCount = 0
        end

    elseif stage == 1 then
        -- stay docked for a short while, like an npc trader
        waitCount = waitCount + timeStep
        if waitCount >= WaitTime then
            stage = 2
        end

    elseif stage == 2 then
        -- undock, then head for the gate that leads towards our next stop
        if DockAI.flyAwayFromDock(ship, station) then
            local gate, isJump = chosenGate(ship)
            exitGateId = (gate and not isJump) and gate.id or nil
            DockAI.reset()
            stage = 3
        end
    end
end
