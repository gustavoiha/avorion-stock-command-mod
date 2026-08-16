package.path = package.path .. ";data/scripts/lib/?.lua"

include("goods")
include("utility")

-- namespace StockFactoryCargoRecovery
StockFactoryCargoRecovery = {}

local GoodKey = "stock_factory_pending_cargo_good"
local AmountKey = "stock_factory_pending_cargo_amount"
local LeaseKey = "stock_factory_command_lease"

function StockFactoryCargoRecovery.getUpdateInterval()
    return 1
end

function StockFactoryCargoRecovery.updateServer()
    local ship = Entity()

    -- Only a v1 command that was migrated on load leaves pending cargo behind. If a live
    -- command holds the lease it owns the ship's cargo, so stay out of its way rather than
    -- racing its in-flight transfers.
    if ship:getValue(LeaseKey) then return end

    local goodName = ship:getValue(GoodKey)
    local amount = ship:getValue(AmountKey) or 0
    local good = goodName and goods[goodName] or nil

    if not good or amount <= 0 then
        ship:setValue(GoodKey, nil)
        ship:setValue(AmountKey, nil)
        terminate()
        return
    end

    local tradingGood = good:good()
    local before = ship:getCargoAmount(tradingGood)
    ship:addCargo(tradingGood, amount)
    local added = math.max(0, ship:getCargoAmount(tradingGood) - before)
    local remaining = amount - added

    if remaining > 0 then
        ship:setValue(AmountKey, remaining)
        return
    end

    ship:setValue(GoodKey, nil)
    ship:setValue(AmountKey, nil)
    terminate()
end
