-- Stock Factory mod — makes the ferry visible in loaded sectors (rule: the ship
-- must not disappear from view; it should be seen moving around and jumping).
--
-- This file name-clashes with the vanilla
--   data/scripts/player/background/simulation/shipappearances.lua
-- so Avorion appends this code to that file. The file-local tables below
-- (VisualizableCommands / AppearanceChances / AppearanceLengths) and the local
-- `CommandType` (with our extension applied) are all in scope here.
--
-- With this, whenever a player is in a sector where a stocking ship "is", the
-- appearance system spawns the real ship and lets it fly around / jump, exactly
-- like the vanilla Mine / Salvage / Procure ships.
VisualizableCommands[CommandType.StockFactory] = true
AppearanceChances[CommandType.StockFactory] = 0.5
AppearanceLengths[CommandType.StockFactory] = 10
