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

-- collect the sectors a stocking ferry actually works between: the target station
-- and every owned trading station it might pick goods up from (read straight from
-- the running command's saved data)
local function stockFactoryRouteSectors(shipName)
    local result = {}
    local seen = {}

    if not Simulation then return result end

    local function addSector(x, y)
        if not x or not y then return end
        local key = x .. ":" .. y
        if not seen[key] then
            seen[key] = true
            table.insert(result, {x = x, y = y})
        end
    end

    for _, command in pairs(Simulation.commands) do
        if command.shipName == shipName and command.data then
            local anchor = command.data.anchor
            if anchor then addSector(anchor.x, anchor.y) end

            local haul = command.data.currentHaul
            if haul then
                local phase = command.data.phase
                if phase == "haulingToSource" or phase == "transactingPickup" then
                    if haul.source then addSector(haul.source.x, haul.source.y) end
                    if haul.target then addSector(haul.target.x, haul.target.y) end
                elseif phase == "haulingToTarget" or phase == "transactingDelivery" then
                    if haul.target then addSector(haul.target.x, haul.target.y) end
                    if haul.source then addSector(haul.source.x, haul.source.y) end
                else
                    if haul.source then addSector(haul.source.x, haul.source.y) end
                    if haul.target then addSector(haul.target.x, haul.target.y) end
                end
            end

            for _, station in pairs(command.data.stations or {}) do
                addSector(station.x, station.y)
            end

            break
        end
    end

    return result
end

-- Bias the ferry so it appears where it can actually be watched docking, instead
-- of at a random reachable sector. Everything that isn't a Stock Factory ferry
-- (and the fallback when we have no route) keeps the vanilla behaviour.
local stockFactoryOriginalFindLocation = ShipAppearances.findLocation
function ShipAppearances.findLocation(shipName, commandType)
    if commandType == CommandType.StockFactory then
        local route = stockFactoryRouteSectors(shipName)

        if #route > 0 then
            -- if the watching player is sitting in one of the route's sectors,
            -- make the ferry show up right there so it's actually seen
            if isPlayerScript() then
                local ok, px, py = pcall(function()
                    return Sector():getCoordinates()
                end)

                if ok and px then
                    for _, coord in pairs(route) do
                        if coord.x == px and coord.y == py then
                            return px, py
                        end
                    end
                end
            end

            -- otherwise pick one of the route's stations at random
            local coord = route[random():getInt(1, #route)]
            return coord.x, coord.y
        end
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
