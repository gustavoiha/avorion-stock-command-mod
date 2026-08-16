-- Stock-command mod — inject into entity/merchants/consumer.lua
-- Consumers only buy, so they only get a delivery toggle in the sell tab. The vanilla
-- NPC-trader button already occupies the rightmost 30px there, so ours sits left of it.
local StockHaulerToggle = include("stockhaulertoggle")

StockHaulerToggle.install(Consumer, {deliveryOffset = 62})
