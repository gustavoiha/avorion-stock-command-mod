-- Stock Factory mod -- extends the vanilla background-ship appearance behaviour.
--
-- This file name-clashes with the vanilla
--   data/scripts/entity/utility/backgroundshipappearance.lua
-- so Avorion appends this code to that file. The file-local `data` table and the
-- file-local `CommandType` (with our command-type extension applied) are both in
-- scope here, and `BackgroundShipAppearance` is the script's namespace.
--
-- Vanilla only gives Mine / Salvage / Escort appearances a special behaviour;
-- every other command just runs ai/patrolpeacefully.lua. We hook the behaviour
-- update so a Stock Factory ferry instead flies to one of the owner's stations,
-- docks, waits and leaves -- like an NPC trader -- whenever a player is watching.
if onServer() then

local stockFactoryOriginalUpdateCommandBehavior = BackgroundShipAppearance.updateCommandBehavior

function BackgroundShipAppearance.updateCommandBehavior(owner, ship)
    if data.command == CommandType.StockFactory then
        -- data.faction is the ship's real owner (the appearance itself belongs to
        -- a neutral display faction); the ferry AI needs it to find the station
        ship:addScriptOnce("ai/stockfactoryferry.lua", data.faction)
        return
    end

    return stockFactoryOriginalUpdateCommandBehavior(owner, ship)
end

end -- onServer()
