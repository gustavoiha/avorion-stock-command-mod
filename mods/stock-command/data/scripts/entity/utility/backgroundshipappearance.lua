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

-- Vanilla mixes command-specific lines with GeneralLines, which includes "So, I guess you
-- enjoy monitoring my work, Commander?" -- odd coming from a freighter that is only passing
-- through. Stock Factory ferries get their own haulage-themed set instead.
local StockFactoryLines = {
    "Manifest's clear, Commander. Hold's where it needs to be."%_T,
    "Another run, another station topped up."%_T,
    "Cargo's secured. Moving on to the next pickup."%_T,
    "Somebody has to keep these production lines fed."%_T,
    "The route's steady. Your stations won't run dry on my watch."%_T,
    "Loading, hauling, unloading. Honest work, Commander."%_T,
    "I'll have this delivered before the foreman starts complaining."%_T,
}

local stockFactoryChatterTimer = random():getFloat(0, 40)
local stockFactoryOriginalUpdateChatter = BackgroundShipAppearance.updateChatter

function BackgroundShipAppearance.updateChatter(owner, timeStep)
    if data.command ~= CommandType.StockFactory then
        return stockFactoryOriginalUpdateChatter(owner, timeStep)
    end

    stockFactoryChatterTimer = stockFactoryChatterTimer + timeStep
    if stockFactoryChatterTimer < 90 then return end
    stockFactoryChatterTimer = 0

    if not random():test(0.5) then return end

    local captain = CrewComponent():getCaptain()
    if not captain then return end

    owner:sendChatMessage(Entity(), ChatMessageType.Chatter, "Captain %1%: %2%"%_T,
        captain.name, randomEntry(StockFactoryLines))
end

end -- onServer()
