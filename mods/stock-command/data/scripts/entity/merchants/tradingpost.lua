-- Stock-command mod — inject into entity/merchants/tradingpost.lua
-- Trading posts buy AND sell, so both tabs get a toggle:
--   buy tab  → may stock haulers pick goods up from here (station is a source)
--   sell tab → may stock haulers deliver goods here (station is a target)
-- The sell tab already has the vanilla NPC-trader button, so ours sits left of it.
local StockHaulerToggle = include("stockhaulertoggle")

StockHaulerToggle.install(TradingPost, {pickupOffset = 30, deliveryOffset = 62})
