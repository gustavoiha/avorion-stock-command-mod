local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/tests/[^/]+$") or "."

AlliancePrivilege = {ManageStations = 1}
RelationStatus = {War = 1, Neutral = 2}

local players = {}
local alliances = {}

function Player(index) return players[index] end
function Alliance(index) return alliances[index] end

local Utility = dofile(root .. "/data/scripts/lib/stockfactoryutility.lua")

local failures = 0
local function check(label, condition)
    if condition then
        print("  PASS  " .. label)
    else
        failures = failures + 1
        print("  FAIL  " .. label)
    end
end

print("\n[command lease]")
local leaseEntry = {
    getScriptValue = function(_, key)
        if key == "stock_factory_command_lease" then return "current-token" end
    end,
}
check("accepts the current command lease", Utility.hasCommandLease(leaseEntry, "current-token"))
check("rejects a stale command lease", not Utility.hasCommandLease(leaseEntry, "old-token"))

local routeOwner = {
    index = 10,
    getRelationStatus = function(_, factionIndex)
        return factionIndex == 99 and RelationStatus.War or RelationStatus.Neutral
    end,
}
check("blocks sectors controlled by a faction at war", Utility.isFactionBlockedByWar(routeOwner, {index = 99}))
check("allows neutral controlled sectors", not Utility.isFactionBlockedByWar(routeOwner, {index = 98}))
check("allows the owner's controlled sectors", not Utility.isFactionBlockedByWar(routeOwner, {index = 10}))
check("allows uncontrolled sectors", not Utility.isFactionBlockedByWar(routeOwner, nil))

print("\n[permissions]")
local personalOwner = {index = 10, isPlayer = true}
local allianceOwner = {
    index = 20,
    isAlliance = true,
    hasPrivilege = function(_, playerIndex)
        return playerIndex == 10
    end,
}
local deniedAlliance = {
    index = 30,
    isAlliance = true,
    hasPrivilege = function() return false end,
}

players[10] = {index = 10, allianceIndex = 20}
players[11] = {index = 11, allianceIndex = 30}
alliances[20] = allianceOwner
alliances[30] = deniedAlliance

check("personal commands can use personal stations", Utility.canUseStation(personalOwner, 10, 10))
check("authorized members can use alliance stations", Utility.canUseStation(personalOwner, 20, 10))
check("unauthorized members cannot use alliance stations", not Utility.canUseStation({index = 11, isPlayer = true}, 30, 11))
check("alliance commands require ManageStations for alliance cargo", Utility.canUseStation(allianceOwner, 20, 10))
check("alliance commands reject members without ManageStations", not Utility.canUseStation(deniedAlliance, 30, 11))
check("alliance commands may use the initiating player's stations", Utility.canUseStation(allianceOwner, 10, 10))
check("unrelated faction stations are rejected", not Utility.canUseStation(personalOwner, 99, 10))

players[10].allianceIndex = 0
check("former members cannot use alliance cargo", not Utility.canUseStation(allianceOwner, 20, 10))
check("former members cannot use personal cargo for an alliance command", not Utility.canUseStation(allianceOwner, 10, 10))

if failures > 0 then
    error(string.format("%d stock factory utility test(s) failed", failures))
end

print("\nAll stock factory utility tests passed.")
