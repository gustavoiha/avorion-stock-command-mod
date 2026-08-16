-- Stock-command mod — inject into entity/merchants/factory.lua
-- Factories buy and sell, so both tabs get a toggle:
--   buy tab  → may stock haulers pick goods up from here
--   sell tab → may stock haulers deliver goods here
-- Neither tab has a vanilla icon button, so both sit in the top-right corner.
local StockHaulerToggle = include("stockhaulertoggle")

StockHaulerToggle.install(Factory, {pickupOffset = 30, deliveryOffset = 30})
