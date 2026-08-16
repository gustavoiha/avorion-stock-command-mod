local StockFactoryUtility = {}

local function flag(value)
    return value and true or false
end

function StockFactoryUtility.sameGood(left, right)
    return left ~= nil
        and right ~= nil
        and left.name == right.name
        and flag(left.stolen) == flag(right.stolen)
        and flag(left.illegal) == flag(right.illegal)
        and flag(left.dangerous) == flag(right.dangerous)
        and flag(left.suspicious) == flag(right.suspicious)
end

function StockFactoryUtility.cargoAmount(cargo, tradingGood)
    for cargoGood, amount in pairs(cargo or {}) do
        if StockFactoryUtility.sameGood(cargoGood, tradingGood) then return amount, cargoGood end
    end
    return 0
end

function StockFactoryUtility.addCargo(cargo, tradingGood, amount)
    local before, cargoKey = StockFactoryUtility.cargoAmount(cargo, tradingGood)
    cargo[cargoKey or tradingGood] = before + amount
    return before
end

function StockFactoryUtility.removeCargo(cargo, tradingGood, amount)
    local before, cargoKey = StockFactoryUtility.cargoAmount(cargo, tradingGood)
    local removed = math.min(before, amount)
    local remaining = before - removed

    if cargoKey then
        if remaining > 0 then
            cargo[cargoKey] = remaining
        else
            cargo[cargoKey] = nil
        end
    end

    return removed
end

function StockFactoryUtility.hasCommandLease(shipEntry, commandToken)
    return shipEntry ~= nil
        and commandToken ~= nil
        and shipEntry:getScriptValue("stock_factory_command_lease") == commandToken
end

-- Moves goods out of a station's cargo bay into the background ship's database cargo.
-- setCargo() rewrites the whole cargo table, so the result is verified by re-reading it
-- and anything the ship did not actually take is put back into the bay.
-- Returns the number of units that ended up on the ship.
function StockFactoryUtility.transferToShip(cargoBay, shipEntry, tradingGood, amount)
    if amount <= 0 then return 0 end

    local bayBefore = cargoBay:getNumCargos(tradingGood)
    cargoBay:removeCargo(tradingGood, amount)
    local removed = bayBefore - cargoBay:getNumCargos(tradingGood)
    if removed <= 0 then return 0 end

    local cargo = shipEntry:getCargo()
    local shipBefore = StockFactoryUtility.addCargo(cargo, tradingGood, removed)

    local ok = pcall(shipEntry.setCargo, shipEntry, cargo)
    local shipAfter = StockFactoryUtility.cargoAmount(shipEntry:getCargo(), tradingGood)
    local moved = ok and math.max(0, shipAfter - shipBefore) or 0

    if moved < removed then
        cargoBay:addCargo(tradingGood, removed - moved)
    end

    return moved
end

-- Inverse of transferToShip: moves goods from the ship's database cargo into the station's
-- cargo bay, clamped to what the ship really carries, and takes back out of the bay whatever
-- the ship failed to release. Returns accepted (in the bay) and rejected (still aboard).
function StockFactoryUtility.transferToStation(cargoBay, shipEntry, tradingGood, amount)
    local cargo = shipEntry:getCargo()
    local shipBefore = StockFactoryUtility.cargoAmount(cargo, tradingGood)
    amount = math.min(amount, shipBefore)
    if amount <= 0 then return 0, 0 end

    local bayBefore = cargoBay:getNumCargos(tradingGood)
    cargoBay:addCargo(tradingGood, amount)
    local added = cargoBay:getNumCargos(tradingGood) - bayBefore
    if added <= 0 then return 0, amount end

    StockFactoryUtility.removeCargo(cargo, tradingGood, added)

    local ok = pcall(shipEntry.setCargo, shipEntry, cargo)
    local shipAfter = StockFactoryUtility.cargoAmount(shipEntry:getCargo(), tradingGood)
    local released = ok and math.max(0, shipBefore - shipAfter) or 0

    if released < added then
        cargoBay:removeCargo(tradingGood, added - released)
    end

    return released, amount - released
end

function StockFactoryUtility.isFactionBlockedByWar(owner, faction)
    return owner ~= nil
        and faction ~= nil
        and faction.index ~= owner.index
        and owner:getRelationStatus(faction.index) == RelationStatus.War
end

function StockFactoryUtility.canUseStation(commandOwner, stationFactionIndex, callingPlayerIndex)
    if not commandOwner or not stationFactionIndex then return false end

    local player = callingPlayerIndex and Player(callingPlayerIndex) or nil

    if commandOwner.isAlliance then
        if not player
            or player.allianceIndex ~= commandOwner.index
            or not commandOwner:hasPrivilege(player.index, AlliancePrivilege.ManageStations) then
            return false
        end

        return stationFactionIndex == commandOwner.index or stationFactionIndex == player.index
    end

    if stationFactionIndex == commandOwner.index then return true end
    if not player then return false end
    if stationFactionIndex == player.index then return true end

    if player.allianceIndex and player.allianceIndex ~= 0
        and stationFactionIndex == player.allianceIndex then
        local alliance = Alliance(player.allianceIndex)
        return alliance ~= nil
            and alliance:hasPrivilege(player.index, AlliancePrivilege.ManageStations)
    end

    return false
end

return StockFactoryUtility
