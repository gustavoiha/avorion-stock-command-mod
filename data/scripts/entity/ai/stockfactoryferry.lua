package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/entity/?.lua"

include ("utility")
include ("stringutility")
local DockAI = include ("ai/dock")

-- Stock Factory mod -- "real" flight behaviour for a stocking ferry.
--
-- This entity script is attached to a Stock Factory ship *appearance* (see the
-- backgroundshipappearance.lua extension) whenever a player is in one of the
-- sectors the ferry operates in. It makes the ferry behave like an NPC trader:
-- fly to one of the owner's stations in the sector, dock, wait a short moment,
-- then leave the sector again.
--
-- It is purely visual: the goods themselves are still moved by the background
-- command (stockfactorycommand.lua). When no player is watching the sector, this
-- script is never attached and the command stays a pure background behaviour.
--
-- Modeled on the vanilla data/scripts/entity/ai/trade.lua NPC-trader behaviour
-- and data/scripts/entity/ai/docktostation.lua.

local factionIndex
local stationId
local stage
local waitCount = 0

-- how long the ferry stays docked, matching vanilla ai/trade.lua's trader wait
local WaitTime = 40

function getUpdateInterval()
    return 1
end

function initialize(faction)
    factionIndex = faction
end

function secure()
    return {stage = stage, waitCount = waitCount}
end

function restore(values)
    values = values or {}
    stage = values.stage
    waitCount = values.waitCount or 0
end

-- nearest station in the sector that belongs to the ferry's owner and can be
-- docked at
local function findOwnedStation()
    local ship = Entity()
    local best, bestDist

    for _, station in pairs({Sector():getEntitiesByType(EntityType.Station)}) do
        if station.factionIndex == factionIndex then
            local docks = DockingPositions(station)
            if valid(docks) and docks.numDockingPositions > 0 and docks.docksEnabled then
                local delta = station.translationf - ship.translationf
                local dist = delta:length()
                if not bestDist or dist < bestDist then
                    best = station
                    bestDist = dist
                end
            end
        end
    end

    return best
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

    stage = stage or 0

    -- keep a handle on the station we're visiting
    local station
    if stationId then station = sector:getEntity(stationId) end

    if not valid(station) then
        station = findOwnedStation()
        if not valid(station) then
            -- nothing of ours to dock at here: just drift like other eye candy
            ship:addScriptOnce("ai/patrolpeacefully.lua")
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
        -- undock
        if DockAI.flyAwayFromDock(ship, station) then
            stage = 3
        end

    elseif stage == 3 then
        -- done visiting: ask the appearance system to jump the ferry back out,
        -- so it "carries on" instead of lingering until the appearance expires
        DockAI.reset()
        ShipAI():setPassive()

        pcall(function()
            invokeFactionFunction(factionIndex, true,
                "background/simulation/shipappearances.lua",
                "returnFerryToBackground", ship.name)
        end)

        stage = 4
    end
end
