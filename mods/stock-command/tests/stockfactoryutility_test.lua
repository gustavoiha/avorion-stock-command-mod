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

print("\n[cargo]")
local iron = {name = "Iron"}
local steel = {name = "Steel"}
local stolenIron = {name = "Iron", stolen = true}
local suspiciousIron = {name = "Iron", suspicious = true}
local cargo = {[iron] = 12, [stolenIron] = 4, [suspiciousIron] = 3}

check("reads cargo by full good identity", Utility.cargoAmount(cargo, iron) == 12)
check("keeps stolen cargo separate", Utility.cargoAmount(cargo, stolenIron) == 4)
check("keeps suspicious cargo separate", Utility.cargoAmount(cargo, suspiciousIron) == 3)
check("adds to an existing cargo key", Utility.addCargo(cargo, {name = "Iron"}, 8) == 12 and cargo[iron] == 20)
check("adds a new cargo type", Utility.addCargo(cargo, steel, 5) == 0 and cargo[steel] == 5)
check("removes only the requested legal amount", Utility.removeCargo(cargo, {name = "Iron"}, 7) == 7 and cargo[iron] == 13)
check("legal removal leaves flagged variants unchanged", cargo[stolenIron] == 4 and cargo[suspiciousIron] == 3)
check("clamps removal to available cargo", Utility.removeCargo(cargo, steel, 50) == 5 and cargo[steel] == nil)

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

print("\n[cargo transfers]")

-- minimal stand-ins for the engine's CargoBay and ShipDatabaseEntry. setCargo can be told
-- to only partially apply (or to raise) so the reconciliation paths are exercised.
local function makeBay(stock)
    return {
        stock = stock,
        getNumCargos = function(self, good) return self.stock[good.name] or 0 end,
        addCargo = function(self, good, amount)
            self.stock[good.name] = (self.stock[good.name] or 0) + amount
        end,
        removeCargo = function(self, good, amount)
            self.stock[good.name] = math.max(0, (self.stock[good.name] or 0) - amount)
        end,
    }
end

local function makeShip(initial, behaviour)
    return {
        cargo = initial or {},
        getCargo = function(self)
            local copy = {}
            for good, amount in pairs(self.cargo) do copy[good] = amount end
            return copy
        end,
        setCargo = function(self, cargo)
            if behaviour then behaviour(self, cargo) else self.cargo = cargo end
        end,
    }
end

local bay = makeBay({Iron = 100})
local ship = makeShip()
check("moves goods from the bay onto the ship", Utility.transferToShip(bay, ship, iron, 40) == 40)
check("bay is debited by the moved amount", bay.stock.Iron == 60)
check("ship holds the moved amount", Utility.cargoAmount(ship:getCargo(), iron) == 40)

local shortBay = makeBay({Iron = 10})
check("pickup clamps to what the bay actually had", Utility.transferToShip(shortBay, makeShip(), iron, 40) == 10)
check("nothing is transferred for a non-positive amount", Utility.transferToShip(shortBay, makeShip(), iron, 0) == 0)

-- a ship that silently only accepts half of what setCargo was given
local pickyBay = makeBay({Iron = 100})
local pickyShip = makeShip(nil, function(self, cargo)
    self.cargo = {}
    for good, amount in pairs(cargo) do self.cargo[good] = math.floor(amount / 2) end
end)
check("pickup reports only what the ship really took", Utility.transferToShip(pickyBay, pickyShip, iron, 40) == 20)
check("pickup returns the untaken goods to the bay", pickyBay.stock.Iron == 80)

local raisingBay = makeBay({Iron = 100})
local raisingShip = makeShip(nil, function() error("setCargo exploded") end)
check("pickup reports nothing moved when setCargo raises", Utility.transferToShip(raisingBay, raisingShip, iron, 40) == 0)
check("pickup restores the bay when setCargo raises", raisingBay.stock.Iron == 100)

local deliveryBay = makeBay({})
local loadedShip = makeShip({[iron] = 30})
local delivered, rejected = Utility.transferToStation(deliveryBay, loadedShip, iron, 30)
check("delivers the full load to the station", delivered == 30 and rejected == 0)
check("station bay receives the delivered goods", deliveryBay.stock.Iron == 30)
check("ship no longer carries the delivered goods", Utility.cargoAmount(loadedShip:getCargo(), iron) == 0)

local clampBay = makeBay({})
local lightShip = makeShip({[iron] = 5})
local clampDelivered, clampRejected = Utility.transferToStation(clampBay, lightShip, iron, 30)
check("delivery clamps to the cargo actually carried", clampDelivered == 5 and clampRejected == 0)
check("delivery of an empty hold is a no-op", select(1, Utility.transferToStation(clampBay, makeShip(), iron, 30)) == 0)

-- a ship that refuses to give up any cargo: the bay must not be credited
local stuckBay = makeBay({})
local stuckShip = makeShip({[iron] = 30}, function() end)
local stuckDelivered, stuckRejected = Utility.transferToStation(stuckBay, stuckShip, iron, 30)
check("delivery reports nothing released when the ship keeps its cargo", stuckDelivered == 0 and stuckRejected == 30)
check("delivery does not credit the bay for cargo still aboard", (stuckBay.stock.Iron or 0) == 0)

local raisingDeliveryBay = makeBay({})
local raisingDeliveryShip = makeShip({[iron] = 30}, function() error("setCargo exploded") end)
local raisedDelivered, raisedRejected = Utility.transferToStation(raisingDeliveryBay, raisingDeliveryShip, iron, 30)
check("delivery reports nothing released when setCargo raises", raisedDelivered == 0 and raisedRejected == 30)
check("delivery leaves the bay untouched when setCargo raises", (raisingDeliveryBay.stock.Iron or 0) == 0)

local exchangeBay = makeBay({Steel = 15})
local exchangeShip = makeShip({[iron] = 10})
check("exchanges station cargo without temporary ship space", Utility.exchangeCargo(exchangeBay, exchangeShip, iron, 10, steel, 15))
check("an exchange credits the delivered cargo to the station", exchangeBay.stock.Iron == 10 and exchangeBay.stock.Steel == 0)
check("an exchange replaces the ship cargo", Utility.cargoAmount(exchangeShip:getCargo(), iron) == 0 and Utility.cargoAmount(exchangeShip:getCargo(), steel) == 15)

local rejectedExchangeBay = makeBay({Steel = 15})
local rejectedExchangeShip = makeShip({[iron] = 10}, function() end)
check("a rejected exchange reports failure", not Utility.exchangeCargo(rejectedExchangeBay, rejectedExchangeShip, iron, 10, steel, 15))
check("a rejected exchange restores station cargo", (rejectedExchangeBay.stock.Iron or 0) == 0 and rejectedExchangeBay.stock.Steel == 15)

if failures > 0 then
    error(string.format("%d stock factory utility test(s) failed", failures))
end

print("\nAll stock factory utility tests passed.")
