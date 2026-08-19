local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/tests/[^/]+$") or "."

debug.setmetatable("", {
    __index = string,
    __mod = function(value) return value end,
})

local function makeGood(name)
    local tradingGood = {
        name = name,
        displayName = function() return name end,
    }
    return {
        name = name,
        size = 1,
        good = function() return tradingGood end,
    }
end

goods = {
    Iron = makeGood("Iron"),
    Steel = makeGood("Steel"),
}

local stubs = {
    commandtype = {StockFactory = "stock-factory"},
    simulationutility = {
        AttackChanceLabelCaption = "Attack Chance",
        AttackChanceLabelTooltip = "",
    },
    captainutility = {},
    tradingutility = {},
    gatesmap = {},
    stockfactoryutility = dofile(root .. "/data/scripts/lib/stockfactoryutility.lua"),
    utility = {},
    stringutility = {},
    goods = goods,
}

function include(name) return stubs[name] end
function tablelength(values)
    local count = 0
    for _ in pairs(values or {}) do count = count + 1 end
    return count
end
function valid(value) return value ~= nil end
function eprint() end

local randomPicksHigh = false
local randomTestResult = false
function random()
    return {
        getInt = function(_, low, high) return randomPicksHigh and high or low end,
        test = function() return randomTestResult end,
    }
end

ChatMessageType = {Error = 1, Normal = 2, Economy = 3, Information = 4}

-- captures every sector job the command dispatches, so the tests can assert which sector
-- was addressed, and with what, without running any of the embedded code
local sectorCalls = {}
function runSectorCode(x, y, keep, code, entry, ...)
    table.insert(sectorCalls, {x = x, y = y, code = code, args = {...}})
end

function Galaxy()
    return {
        keepOrGetSector = function() return true end,
        sectorLoaded = function() return true end,
    }
end

local shipScriptValues = {}
function ShipDatabaseEntry()
    return {
        getFreeCargoSpace = function() return 100 end,
        getScriptValue = function(_, key) return shipScriptValues[key] end,
        setScriptValue = function(_, key, value) shipScriptValues[key] = value end,
        addScriptOnce = function() end,
    }
end
function getParentFaction() return {index = 10, sendChatMessage = function() end} end

local Factory = dofile(root .. "/data/scripts/player/background/simulation/stockfactorycommand.lua")

local failures = 0
local function check(label, condition)
    if condition then
        print("  PASS  " .. label)
    else
        failures = failures + 1
        print("  FAIL  " .. label)
    end
end

local area = {
    lower = {x = 0, y = 0},
    upper = {x = 0, y = 0},
    analysis = {},
}
local command = Factory("Hauler", area, {ignoredGoods = {}})
command.data.commandToken = "current-command"
command.data.stations = {
    {name = "Iron Mine", factionIndex = 10, x = 0, y = 0, sells = {Iron = "seller.lua"}, buys = {}},
    {name = "Steel Mill", factionIndex = 10, x = 0, y = 0, sells = {Steel = "factory.lua"}, buys = {Iron = "factory.lua"}},
}
area.analysis.stations = command.data.stations

print("\n[eligibility]")
check("finds an eligible target", #command:eligibleTargets("Iron") == 1)
check("finds an eligible source", #command:eligibleSources("Iron", command.data.stations[2]) == 1)
check("reports an available source-target pair", command:hasAnyReachableSource())

command.config.ignoredGoods.Iron = true
check("ignored goods have no targets", #command:eligibleTargets("Iron") == 0)
check("ignored goods have no sources", #command:eligibleSources("Iron", command.data.stations[2]) == 0)
check("ignored goods are absent from prediction", command:calculatePrediction(10, "Hauler", area, command.config).numGoodsWithConsumer == 0)

command.config.ignoredGoods.Iron = nil
command.data.stations[1].stockHaulerPickupEnabled = false
check("pickup opt-out removes the route", not command:hasAnyReachableSource())
check("pickup opt-out affects prediction", command:calculatePrediction(10, "Hauler", area, command.config).numGoodsWithSource == 0)

print("\n[haul planning]")

-- producer and consumer sit in different sectors so the appearance/route tests can tell
-- the two ends of a run apart
local function pairedStations()
    return {
        {name = "Iron Mine", factionIndex = 10, x = 0, y = 0, sells = {Iron = "seller.lua"}, buys = {}},
        {name = "Steel Mill", factionIndex = 10, x = 1, y = 0, sells = {Steel = "factory.lua"}, buys = {Iron = "factory.lua"}},
    }
end

local function freshPlanner()
    local instance = Factory("Hauler", area, {ignoredGoods = {}})
    instance.data.stations = pairedStations()
    instance.data.commandToken = "current-command"
    return instance
end

local planner = freshPlanner()
planner:planNextHaul()
check("planning picks the producer/consumer pair",
    planner.data.phase == "travelling"
        and planner.data.currentHaul.good == "Iron"
        and planner.data.currentHaul.source.name == "Iron Mine"
        and planner.data.currentHaul.target.name == "Steel Mill")
check("planning resolves the trade script for both ends",
    planner.data.currentHaul.source.script == "seller.lua"
        and planner.data.currentHaul.target.script == "factory.lua")

check("a run is at least 4 minutes", planner.data.currentHaul.travelTime == 4 * 60)
check("a run never parks cargo on the ship", planner.data.currentHaul.carriedAmount == nil)

randomPicksHigh = true
local slowPlanner = freshPlanner()
slowPlanner:planNextHaul()
check("a run is at most 6 minutes", slowPlanner.data.currentHaul.travelTime == 6 * 60)
randomPicksHigh = false

local ignoring = Factory("Hauler", area, {ignoredGoods = {Iron = true}})
ignoring.data.stations = pairedStations()
ignoring:planNextHaul()
check("planning skips ignored goods", ignoring.data.currentHaul == nil and ignoring.data.phase == "idle")

local producerOnly = Factory("Hauler", area, {ignoredGoods = {}})
producerOnly.data.stations = {pairedStations()[1]}
producerOnly:planNextHaul()
check("planning without a consumer idles instead of failing",
    producerOnly.data.phase == "idle" and producerOnly.data.currentHaul == nil)
check("an idle hauler reports that it is waiting",
    producerOnly:getStatusMessage() == "Waiting for goods to haul /* ship AI status */")
check("a hauling ship reports that it is stocking",
    planner:getStatusMessage() == "Stocking a sector /* ship AI status */")

print("\n[recent failure memory]")

local emptySource = freshPlanner()
emptySource.data.currentHaul = {good = "Iron", source = emptySource.data.stations[1], target = emptySource.data.stations[2]}
emptySource.data.transaction = {id = 1, stage = "probing", good = "Iron", targetReceived = true, sourceReceived = true, targetRoom = 500, sourceStock = 0}
emptySource:tryExecuteHaul()
check("an empty source is remembered", tablelength(emptySource.data.recentFailures) == 1)
emptySource:planNextHaul()
check("a remembered empty source is not picked again",
    emptySource.data.phase == "idle" and emptySource.data.currentHaul == nil)

local fullTarget = freshPlanner()
fullTarget.data.currentHaul = {good = "Iron", source = fullTarget.data.stations[1], target = fullTarget.data.stations[2]}
fullTarget.data.transaction = {id = 1, stage = "probing", good = "Iron", targetReceived = true, sourceReceived = true, targetRoom = 0, sourceStock = 900}
fullTarget:tryExecuteHaul()
check("a full target is remembered", tablelength(fullTarget.data.recentFailures) == 1)
fullTarget:planNextHaul()
check("a remembered full target is not picked again",
    fullTarget.data.phase == "idle" and fullTarget.data.currentHaul == nil)
check("a blocked plan retries sooner than a dry galaxy", fullTarget.data.rescanCooldown == 60)

local pickupFailure = freshPlanner()
pickupFailure.data.currentHaul = {good = "Iron", source = pickupFailure.data.stations[1], target = pickupFailure.data.stations[2]}
pickupFailure.data.transaction = {id = 7, stage = "removing", good = "Iron"}
pickupFailure:onGoodsRemoved("current-command", 7, "Iron", 0)
check("a source that hands over nothing is remembered", tablelength(pickupFailure.data.recentFailures) == 1)

local expiring = freshPlanner()
expiring:noteHaulFailure("source", "Iron", expiring.data.stations[1])
expiring.data.clock = 10 * 60
check("a failure expires and is forgotten", expiring:pruneHaulFailures() == nil)
expiring:planNextHaul()
check("an expired failure no longer blocks the pair",
    expiring.data.phase == "travelling" and expiring.data.currentHaul.good == "Iron")

-- delivering inputs to a station can restart its production, so it stops counting as dry
local restocked = freshPlanner()
restocked:noteHaulFailure("source", "Iron", restocked.data.stations[1])
restocked:noteHaulFailure("target", "Steel", restocked.data.stations[1])
restocked.data.currentHaul = {good = "Steel", source = restocked.data.stations[2], target = restocked.data.stations[1]}
restocked.data.transaction = {id = 3, stage = "delivering", good = "Steel"}
restocked:onGoodsDelivered("current-command", 3, "Steel", 10, 0)
check("delivering to a station leaves its other blocks alone", tablelength(restocked.data.recentFailures) == 1)
restocked:planNextHaul()
check("delivering to a station clears its dry-source block",
    restocked.data.phase == "travelling"
        and restocked.data.currentHaul.good == "Iron"
        and restocked.data.currentHaul.source.name == "Iron Mine")

local overflowing = freshPlanner()
overflowing.data.recentFailures = {}
for entry = 1, 65 do
    overflowing.data.recentFailures["stale" .. entry] = 10 * 60
end
check("an oversized failure table is discarded wholesale", overflowing:pruneHaulFailures() == nil)

print("\n[target bay space]")

-- the station's quota for a good says nothing about its bay, which can be full of anything
local function haulWith(transaction)
    local instance = freshPlanner()
    instance.data.currentHaul = {good = "Iron", source = instance.data.stations[1], target = instance.data.stations[2]}
    transaction.id = 1
    transaction.stage = "probing"
    transaction.good = "Iron"
    transaction.targetReceived = true
    transaction.sourceReceived = true
    instance.data.transaction = transaction
    sectorCalls = {}
    instance:tryExecuteHaul()
    return instance
end

local reporting = freshPlanner()
reporting.data.currentHaul = {good = "Iron", source = reporting.data.stations[1], target = reporting.data.stations[2]}
reporting.data.transaction = {id = 20, stage = "probing", good = "Iron", targetReceived = false, sourceReceived = false}
reporting:reportTargetStock("current-command", 20, "Iron", 20, 100, 250)
check("a target probe records both the quota and the bay space",
    reporting.data.transaction.targetRoom == 80 and reporting.data.transaction.targetFreeSpace == 250)

local physicallyFull = haulWith({targetRoom = 500, sourceStock = 900, targetFreeSpace = 0})
check("a target with quota but no bay space hauls nothing",
    physicallyFull.data.transaction == nil and #sectorCalls == 0)
check("a physically full target is remembered", tablelength(physicallyFull.data.recentFailures) == 1)

local cramped = haulWith({targetRoom = 500, sourceStock = 900, targetFreeSpace = 40})
check("the haul is capped by the target's free bay space",
    cramped.data.transaction.stage == "removing" and cramped.data.transaction.amount == 40)

goods.Iron.size = 2
local bulky = haulWith({targetRoom = 500, sourceStock = 900, targetFreeSpace = 45})
check("bay space is converted to whole units of the good",
    bulky.data.transaction.amount == 22)
goods.Iron.size = 1

local unknownSpace = haulWith({targetRoom = 30, sourceStock = 900, targetFreeSpace = -1})
check("a station that reports no bay is not capped by space",
    unknownSpace.data.transaction.amount == 30)

local roomIsStillTheCap = haulWith({targetRoom = 15, sourceStock = 900, targetFreeSpace = 400})
check("plenty of bay space does not lift the good's own quota",
    roomIsStillTheCap.data.transaction.amount == 15)

print("\n[transfer]")

local moving = freshPlanner()
moving.data.currentHaul = {good = "Iron", source = moving.data.stations[1], target = moving.data.stations[2]}
moving.data.transaction = {id = 11, stage = "removing", good = "Iron"}
sectorCalls = {}
moving:onGoodsRemoved("current-command", 11, "Iron", 40)
check("a completed pickup immediately dispatches the delivery",
    moving.data.transaction.stage == "delivering" and moving.data.transaction.amount == 40)
check("the delivery is dispatched to the consumer's sector",
    #sectorCalls == 1 and sectorCalls[1].x == 1 and sectorCalls[1].y == 0)

local delivering = freshPlanner()
delivering.data.currentHaul = {good = "Iron", source = delivering.data.stations[1], target = delivering.data.stations[2]}
delivering.data.transaction = {id = 12, stage = "delivering", good = "Iron", amount = 40}
sectorCalls = {}
delivering:onGoodsDelivered("current-command", 12, "Iron", 40, 0)
check("a delivered run goes straight to the next job",
    delivering.data.phase == "idle"
        and delivering.data.currentHaul == nil
        and delivering.data.transaction == nil
        and delivering.data.rescanCooldown == 0)
check("a full delivery needs no return trip", #sectorCalls == 0)

local overdelivered = freshPlanner()
overdelivered.data.currentHaul = {good = "Iron", source = overdelivered.data.stations[1], target = overdelivered.data.stations[2]}
overdelivered.data.transaction = {id = 13, stage = "delivering", good = "Iron", amount = 40}
sectorCalls = {}
overdelivered:onGoodsDelivered("current-command", 13, "Iron", 25, 15)
check("goods the consumer could not take go back to the producer",
    #sectorCalls == 1 and sectorCalls[1].x == 0 and sectorCalls[1].y == 0)
check("a consumer that filled up is remembered", tablelength(overdelivered.data.recentFailures) == 1)
check("an overdelivery still finishes the run", overdelivered.data.phase == "idle")
check("the return job is handed exactly what the consumer refused",
    sectorCalls[1].code == Factory.sectorCode.returnGoods
        and sectorCalls[1].args[4] == "Iron Mine"
        and sectorCalls[1].args[5] == "Iron"
        and sectorCalls[1].args[6] == 15)

print("\n[returning undelivered goods]")

-- The return runs in its own sector state, so it is loaded and executed here with only the
-- engine calls it touches stubbed out. Cargo the producer's bay refuses is destroyed by the
-- engine and is undetectable afterwards, so the log is the only evidence there is.
local returnStations = {}

function Sector()
    return {
        getEntityByFactionAndName = function(_, factionIndex, name) return returnStations[name] end,
    }
end

function TradingGood(name)
    return {name = name}
end

function CargoBay(station)
    return station.bay
end

local function stationWithBay(name, capacity)
    local station = {
        name = name,
        bay = {
            stored = 0,
            getNumCargos = function(self) return self.stored end,
            addCargo = function(self, _, amount) self.stored = math.min(capacity, self.stored + amount) end,
        },
    }
    returnStations[name] = station
    return station
end

assert(loadstring(Factory.sectorCode.returnGoods, "returnCode"))()

local logLines
local function capturingLog(work)
    logLines = {}
    local realPrint = print
    print = function(line) table.insert(logLines, line) end
    work()
    print = realPrint
end

local function loggedMatch(pattern)
    for _, line in ipairs(logLines) do
        if line:find(pattern, 1, true) then return true end
    end
    return false
end

local roomy = stationWithBay("Roomy Mine", 1000)
capturingLog(function() run(10, "Hauler", 10, "Roomy Mine", "Iron", 15) end)
check("a producer with room takes the whole remainder back", roomy.bay.stored == 15)
check("a complete return says nothing", #logLines == 0)

local cramped = stationWithBay("Cramped Mine", 5)
capturingLog(function() run(10, "Hauler", 10, "Cramped Mine", "Iron", 15) end)
check("a producer only takes back what fits", cramped.bay.stored == 5)
check("cargo the producer refuses is reported as lost",
    #logLines == 1
        and loggedMatch("'Hauler' lost 10 units of Iron")
        and loggedMatch("'Cramped Mine' took back only 5 of 15"))

local full = stationWithBay("Full Mine", 0)
capturingLog(function() run(10, "Hauler", 10, "Full Mine", "Iron", 15) end)
check("a producer with no room at all loses everything, loudly",
    full.bay.stored == 0 and loggedMatch("'Hauler' lost 15 units of Iron"))

capturingLog(function() run(10, "Hauler", 10, "Vanished Mine", "Iron", 15) end)
check("a return to a station that disappeared is reported as lost",
    loggedMatch("'Hauler' lost 15 units of Iron") and loggedMatch("could not take them back"))

capturingLog(function() run(10, "Hauler", 10, "Roomy Mine", "Unobtainium", 15) end)
check("a return of an unknown good is reported as lost",
    loggedMatch("'Hauler' lost 15 units of Unobtainium"))

print("\n[ferry visuals]")

local function travellingCommand(timer, visitSource)
    local instance = freshPlanner()
    local stations = instance.data.stations
    instance.data.anchor = {x = 5, y = 5}
    instance.data.currentHaul = {
        good = "Iron",
        source = {name = stations[1].name, factionIndex = 10, x = 0, y = 0, script = "seller.lua"},
        target = {name = stations[2].name, factionIndex = 10, x = 1, y = 0, script = "factory.lua"},
        travelTime = 240,
        visitSource = visitSource and true or false,
    }
    instance.data.phase = "travelling"
    instance.data.timer = timer
    -- keep update() away from the route re-scan, which needs the whole galaxy stubbed
    instance.data.remapCooldown = math.huge
    return instance
end

local idleFerry = freshPlanner()
idleFerry.data.anchor = {x = 5, y = 5}
idleFerry.data.phase = "idle"
local idleX, idleY = idleFerry:getAppearanceSector()
check("an idle ferry waits at the anchor", idleX == 5 and idleY == 5)
check("an idle ferry has nothing to dock", idleFerry:getFerryDockTarget() == nil)

local earlyVisit = travellingCommand(0, true)
local visitX, visitY = earlyVisit:getAppearanceSector()
check("a run that rolled a producer visit shows the ferry there", visitX == 0 and visitY == 0)
check("the producer visit offers the producer as a decorative dock",
    earlyVisit:getFerryDockTarget().name == "Iron Mine")
check("the ferry may patrol while the run still has slack",
    earlyVisit:ferryTransitLinger() == 60)

local approaching = travellingCommand(200, true)
local approachX, approachY = approaching:getAppearanceSector()
check("the approach window moves the ferry to the consumer", approachX == 1 and approachY == 0)
check("the approach window docks the consumer",
    approaching:getFerryDockTarget().name == "Steel Mill")
check("there is no patrol time left during the approach", approaching:ferryTransitLinger() == 0)

local docking = travellingCommand(200, false)
sectorCalls = {}
docking:onFerryDocked(1, 0, "Steel Mill")
check("docking the consumer starts the transfer", docking.data.phase == "transferring")
check("docking the consumer probes both stations", #sectorCalls == 2)

local wrongDock = travellingCommand(200, false)
wrongDock:onFerryDocked(0, 0, "Iron Mine")
check("docking the producer does not start the transfer", wrongDock.data.phase == "travelling")

local earlyDock = travellingCommand(10, false)
earlyDock:onFerryDocked(1, 0, "Steel Mill")
check("docking before the approach window does not start the transfer",
    earlyDock.data.phase == "travelling")

print("\n[transfer timing]")

local unwatched = travellingCommand(240, false)
unwatched:update(60)
check("an unwatched run transfers as soon as the timer expires",
    unwatched.data.phase == "transferring")

local watched = travellingCommand(240, false)
watched.data.clock = 240
watched.data.ferrySector = {x = 1, y = 0, clock = 240}
watched:update(60)
check("a watched run waits for the ferry to dock", watched.data.phase == "travelling")

local watchedTooLong = travellingCommand(240 + 90, false)
watchedTooLong.data.clock = 330
watchedTooLong.data.ferrySector = {x = 1, y = 0, clock = 330}
watchedTooLong:update(60)
check("waiting for a dock gives up after the grace period",
    watchedTooLong.data.phase == "transferring")

local stalled = travellingCommand(0, false)
stalled.data.phase = "transferring"
stalled.data.transaction = {id = 20, stage = "removing", good = "Iron"}
stalled.data.timer = 0
stalled:update(400)
check("a stalled transfer is abandoned rather than recalled",
    stalled.data.phase == "idle"
        and stalled.data.currentHaul == nil
        and stalled.data.transaction == nil
        and not stalled.finishOnNextUpdate)

print("\n[assignment]")
local empty = Factory("Hauler", {lower = {x = 0, y = 0}, upper = {x = 0, y = 0}, analysis = {}}, {ignoredGoods = {}})
check("a hauler can be assigned with no stations in range",
    empty:getErrors(10, "Hauler", empty.area, empty.config) == nil)
check("a hauler can be assigned when nothing pairs up",
    producerOnly:getErrors(10, "Hauler", area, producerOnly.config) == nil)

print("\n[callback correlation]")
command.data.phase = "transferring"
command.data.currentHaul = {good = "Iron", source = command.data.stations[1], target = command.data.stations[2]}
command.data.transaction = {id = 42, stage = "probing", good = "Iron", targetReceived = false, sourceReceived = false}
command:reportTargetStock("current-command", 41, "Iron", 0, 100)
check("stale probe callback is ignored", command.data.transaction.targetReceived == false)
command:reportTargetStock("current-command", 42, "Steel", 0, 100)
check("wrong-good callback is ignored", command.data.transaction.targetReceived == false)
command:reportTargetStock("previous-command", 42, "Iron", 0, 100)
check("previous command callback is ignored", command.data.transaction.targetReceived == false)

command.data.transaction = {id = 42, stage = "removing", good = "Iron"}
command:reportTargetStock("current-command", 42, "Iron", 0, 100)
check("wrong-stage callback is ignored", command.data.transaction.stage == "removing")

print("\n[restore]")

-- a restored command must not sit waiting for a sector reply that died with the server
local restored = Factory("Hauler", area, {ignoredGoods = {}})
restored.data.transferProtocolVersion = 3
restored.data.commandToken = "restored-command"
restored.data.phase = "transferring"
restored.data.currentHaul = {good = "Iron", source = command.data.stations[1], target = command.data.stations[2]}
restored.data.transaction = {id = 70, stage = "delivering", good = "Iron"}
restored:onRestore(restored.data)
check("restore drops the orphaned transaction", restored.data.transaction == nil)
check("restore looks for a new run instead of replaying", restored.data.phase == "idle")
check("restore does not recall a healthy command", not restored.finishOnNextUpdate)

-- goods used to sit on the ship between two stations; such a command can't be reconciled
local legacy = Factory("Hauler", area, {ignoredGoods = {}})
legacy.data.commandToken = "legacy-command"
legacy.data.currentHaul = {good = "Iron", source = command.data.stations[1], target = command.data.stations[2], carriedAmount = 20}
legacy:onRestore(legacy.data)
check("a command from before instant transfers is recalled for cargo verification",
    legacy.finishOnNextUpdate == true)

if failures > 0 then
    error(string.format("%d stock factory command test(s) failed", failures))
end

print("\nAll stock factory command tests passed.")
