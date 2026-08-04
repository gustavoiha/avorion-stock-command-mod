-- Stock Factory mod — registers the StockFactory command class in the factory.
--
-- This file name-clashes with the vanilla
--   data/scripts/player/background/simulation/commandfactory.lua
-- so Avorion injects this code *before* that file's final `return CommandFactory`.
-- The file-local `registry` table and `CommandType` (included at the top of the
-- vanilla file, with our extension applied) are therefore both in scope here.
--
-- include() (not require()) is used so mod extensions are respected. The package
-- path for this folder was already added by the vanilla file above.
local StockFactoryCommand = include ("stockfactorycommand")
registry[CommandType.StockFactory] = StockFactoryCommand
