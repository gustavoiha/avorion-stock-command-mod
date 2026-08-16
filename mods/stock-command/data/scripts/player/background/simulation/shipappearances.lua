-- Stock Factory mod — makes the ferry visible in loaded sectors (rule: the ship
-- must not disappear from view; it should be seen flying to a station, docking
-- and leaving again).
--
-- This file name-clashes with the vanilla
--   data/scripts/player/background/simulation/shipappearances.lua
-- so Avorion appends this code to that file. The file-local tables below
-- (VisualizableCommands / AppearanceChances / AppearanceLengths), the local
-- `CommandType` (with our extension applied), the `data` table and the
-- `ShipAppearances` namespace are all in scope here.
--
-- Vanilla places an appearance at a *random* reachable sector and then just lets
-- it patrol, so a stocking ferry was rarely seen where the player actually was
-- and never docked. We fix both below:
--   * findLocation is biased so the ferry shows up in the sector the watching
--     player is currently in (when that sector is on the ferry's route), or
--     otherwise at one of the route's stations — not somewhere random.
--   * the docking behaviour itself lives in the backgroundshipappearance.lua and
--     ai/stockfactoryferry.lua extensions.
VisualizableCommands[CommandType.StockFactory] = true
AppearanceChances[CommandType.StockFactory] = 0.5
-- generous cap (minutes); the ferry AI normally jumps back out much sooner via
-- ShipAppearances.returnFerryToBackground once it has finished a station visit
AppearanceLengths[CommandType.StockFactory] = 6

if onServer() then

-- The ferry AI only ever docks the station of the leg it is currently flying
-- (ai/stockfactoryferry.lua treats every other sector as a transit hop and leaves again
-- immediately), so the appearance has to be placed in exactly that sector. An idle command
-- has no leg and therefore no place to be seen.
local function stockFactoryDockSector(shipName)
    if not Simulation then return end

    for _, command in pairs(Simulation.commands) do
        if command.shipName == shipName and command.data then
            local haul = command.data.currentHaul
            if not haul then return end

            local phase = command.data.phase
            local stop

            if phase == "haulingToSource" or phase == "transactingPickup" then
                stop = haul.source
            elseif phase == "haulingToTarget" or phase == "transactingDelivery" then
                stop = haul.target
            end

            if stop and stop.x and stop.y then return stop.x, stop.y end
            return
        end
    end
end

-- Put the ferry where it can actually be watched flying in and docking, instead of at a
-- random reachable sector. Anything that isn't a Stock Factory ferry keeps vanilla
-- behaviour; returning nil makes vanilla skip the appearance entirely this tick.
local stockFactoryOriginalFindLocation = ShipAppearances.findLocation
function ShipAppearances.findLocation(shipName, commandType)
    if commandType == CommandType.StockFactory then
        return stockFactoryDockSector(shipName)
    end

    return stockFactoryOriginalFindLocation(shipName, commandType)
end

-- Called by the ferry AI (ai/stockfactoryferry.lua) once it has finished visiting
-- a station, so the appearance jumps back out immediately instead of lingering in
-- the sector until the appearance timer expires.
function ShipAppearances.returnFerryToBackground(shipName)
    local owner = getParentFaction()
    if not owner then return end

    if data.visibleShips[shipName] then
        ShipAppearances.removeFromVisible(owner, shipName)
        ShipAppearances.sync()
    end
end

end -- onServer()
