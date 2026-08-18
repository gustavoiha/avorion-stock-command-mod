-- Stock Factory mod — makes the ferry visible in loaded sectors.
--
-- This file name-clashes with the vanilla
--   data/scripts/player/background/simulation/shipappearances.lua
-- so Avorion appends this code to that file. The file-local tables below
-- (VisualizableCommands / AppearanceChances / AppearanceLengths), the local
-- `CommandType` (with our extension applied), the `data` table and the
-- `ShipAppearances` namespace are all in scope here.
--
-- Vanilla places an appearance at a *random* reachable sector and then just lets it patrol,
-- so a stocking ferry was rarely seen where the player actually was and never docked. The
-- command decides where its ferry belongs on the current run (see
-- StockFactoryCommand:getAppearanceSector); the docking behaviour itself lives in the
-- backgroundshipappearance.lua and ai/stockfactoryferry.lua extensions.
VisualizableCommands[CommandType.StockFactory] = true
-- the command already returns nil for every tick the ferry should not be placed, so an
-- extra dice roll would only randomly skip delivery approaches
AppearanceChances[CommandType.StockFactory] = 1.0
-- generous cap (minutes); the ferry AI normally jumps back out much sooner via
-- ShipAppearances.returnFerryToBackground once it has finished a station visit
AppearanceLengths[CommandType.StockFactory] = 6

if onServer() then

local function stockFactoryAppearanceSector(shipName)
    if not Simulation then return end

    for _, command in pairs(Simulation.commands) do
        if command.shipName == shipName and command.getAppearanceSector then
            return command:getAppearanceSector()
        end
    end
end

-- Put the ferry where it can actually be watched flying in and docking, instead of at a
-- random reachable sector. Anything that isn't a Stock Factory ferry keeps vanilla
-- behaviour; returning nil makes vanilla skip the appearance entirely this tick.
local stockFactoryOriginalFindLocation = ShipAppearances.findLocation
function ShipAppearances.findLocation(shipName, commandType)
    if commandType == CommandType.StockFactory then
        return stockFactoryAppearanceSector(shipName)
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
