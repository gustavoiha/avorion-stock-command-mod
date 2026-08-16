-- Stock-command mod — inject into entity/merchants/seller.lua
-- Sellers only sell, so they only get a pickup toggle in the buy tab. That tab has no
-- vanilla icon button, so ours sits in the top-right corner.
local StockHaulerToggle = include("stockhaulertoggle")

StockHaulerToggle.install(Seller, {pickupOffset = 30})
