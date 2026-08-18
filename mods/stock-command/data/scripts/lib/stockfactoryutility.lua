local StockFactoryUtility = {}

function StockFactoryUtility.hasCommandLease(shipEntry, commandToken)
    return shipEntry ~= nil
        and commandToken ~= nil
        and shipEntry:getScriptValue("stock_factory_command_lease") == commandToken
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
