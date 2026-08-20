local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/tests/[^/]+$") or "."

debug.setmetatable("", {
    __index = string,
    __mod = function(value) return value end,
})

local function makeGood(name, price, size)
    local tradingGood = {
        name = name,
        displayName = function() return name end,
    }
    return {
        name = name,
        size = size or 1,
        price = price or 100,
        good = function() return tradingGood end,
    }
end

goods = {
    Iron = makeGood("Iron", 100, 1),
    Steel = makeGood("Steel", 500, 2),
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
function random()
    return {
        getInt = function(_, low, high) return randomPicksHigh and high or low end,
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

-- the ship's own hold; a station is never looked up through this stub, the planner reads
-- station stock straight off the records in command.data.stations
local shipScriptValues = {}
local shipCargo = {}
local shipFreeCargoSpace = 100
function ShipDatabaseEntry()
    return {
        getFreeCargoSpace = function() return shipFreeCargoSpace end,
        getCargo = function() return shipCargo, 1000 end,
        setCargo = function(_, cargo) shipCargo = cargo end,
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

-- A station record is exactly what gatherOwnedTradingStations builds: what it trades, plus
-- what its bay holds. Everything a haul needs is here, which is why planning never has to
-- load a sector.
local function station(fields)
    fields.factionIndex = fields.factionIndex or 10
    fields.buys = fields.buys or {}
    fields.sells = fields.sells or {}
    fields.stock = fields.stock or {}
    fields.baySize = fields.baySize or 1000
    fields.freeSpace = fields.freeSpace or 1000
    fields.tradeSlots = fields.tradeSlots or 1
    return fields
end

-- producer and consumer sit in different sectors so the appearance/route tests can tell the
-- two ends of a run apart
local function pairedStations()
    return {
        station{name = "Iron Mine", x = 0, y = 0, sells = {Iron = "seller.lua"}, stock = {Iron = 900}},
        station{name = "Steel Mill", x = 1, y = 0, tradeSlots = 2,
            sells = {Steel = "factory.lua"}, buys = {Iron = "factory.lua"}},
    }
end

-- refreshStations is the one thing a planner does that needs the whole galaxy stubbed, and
-- every test here supplies its stations directly instead
local function freshPlanner(stations)
    local instance = Factory("Hauler", area, {})
    instance.data.stations = stations or pairedStations()
    instance.data.commandToken = "current-command"
    instance.refreshStations = function() end
    return instance
end

local command = freshPlanner()
area.analysis.stations = command.data.stations

print("\n[routes]")
check("reports an available source-target pair", command:hasAnyReachableSource())
check("counts the pair in the prediction",
    command:calculatePrediction(10, "Hauler", area, command.config).numGoodsWithSource == 1)

command.data.stations[1].stockHaulerPickupEnabled = false
check("pickup opt-out removes the route", not command:hasAnyReachableSource())
check("pickup opt-out affects prediction",
    command:calculatePrediction(10, "Hauler", area, command.config).numGoodsWithSource == 0)
command.data.stations[1].stockHaulerPickupEnabled = nil

print("\n[haul planning]")

local planner = freshPlanner()
planner:planNextHaul()
check("planning picks the producer/consumer pair",
    planner.data.currentHaul.good == "Iron"
        and planner.data.currentHaul.source.name == "Iron Mine"
        and planner.data.currentHaul.target.name == "Steel Mill")
check("planning resolves the trade script for both ends",
    planner.data.currentHaul.source.script == "seller.lua"
        and planner.data.currentHaul.target.script == "factory.lua")
check("planning transfers straight away instead of travelling first",
    planner.data.phase == "transferring" and planner.data.transaction ~= nil)
check("a run never parks cargo on the ship", planner.data.currentHaul.carriedAmount == nil)

-- sizing: the plan is capped by the same four limits the transfer is
local function planWith(mutate)
    local stations = pairedStations()
    mutate(stations[1], stations[2])
    local instance = freshPlanner(stations)
    instance:planNextHaul()
    return instance.data.currentHaul
end

check("the haul is capped by the ship's hold",
    planWith(function() end).amount == 100)
check("the haul is capped by the producer's stock",
    planWith(function(source) source.stock.Iron = 10 end).amount == 10)
check("the haul is capped by the consumer's quota for the good",
    planWith(function(_, target) target.baySize = 100 end).amount == 50)
check("the haul is capped by the room physically left in the consumer's bay",
    planWith(function(_, target) target.freeSpace = 40 end).amount == 40)

goods.Iron.size = 2
check("cargo space is converted to whole units of the good",
    planWith(function() end).amount == 50)
goods.Iron.size = 1

local noRoom = freshPlanner()
noRoom.data.stations[2].freeSpace = 0
noRoom:planNextHaul()
check("a consumer with no room is never planned for",
    noRoom.data.currentHaul == nil and noRoom.data.phase == "idle")
check("a dry region is retried later rather than given up on",
    noRoom.data.rescanCooldown == 120 and not noRoom.finishOnNextUpdate)

local producerOnly = freshPlanner({pairedStations()[1]})
producerOnly:planNextHaul()
check("planning without a consumer idles instead of failing",
    producerOnly.data.phase == "idle" and producerOnly.data.currentHaul == nil)
check("an idle hauler reports that it is waiting",
    producerOnly:getStatusMessage() == "Waiting for goods to haul /* ship AI status */")
check("a hauling ship reports that it is stocking",
    planner:getStatusMessage() == "Stocking a sector /* ship AI status */")

print("\n[priority]")

-- Iron: 90 units of a cheap, compact good. Steel: 40 units of an expensive, bulky one.
-- Value ranks them Steel > Iron (20000 > 9000), volume ranks them Iron > Steel (90 > 80).
local function rankedStations()
    return {
        station{name = "Iron Mine", x = 0, y = 0, sells = {Iron = "seller.lua"}, stock = {Iron = 90}},
        station{name = "Steel Mill", x = 1, y = 0, tradeSlots = 2,
            sells = {Steel = "factory.lua"}, buys = {Iron = "factory.lua"}, stock = {Steel = 40}},
        station{name = "Shipyard", x = 2, y = 0, buys = {Steel = "factory.lua"}},
    }
end

local function plannedUnder(priority)
    local instance = freshPlanner(rankedStations())
    instance.config.priority = priority
    instance:planNextHaul()
    return instance.data.currentHaul
end

check("highest total value takes the pricier load", plannedUnder(2).good == "Steel")
check("highest total volume takes the bulkier load", plannedUnder(3).good == "Iron")
check("lowest total value takes the cheaper load", plannedUnder(4).good == "Iron")
check("lowest total volume takes the smaller load", plannedUnder(5).good == "Steel")
check("no preference still finds a load", plannedUnder(1) ~= nil)

-- one setting per ship, and an unconfigured fleet spreads out instead of converging
check("the default priority is no preference",
    Factory("Hauler", area, {}).config.priority == 1)
check("a priority set on one command does not leak into another",
    (function()
        local picky = freshPlanner()
        picky.config.priority = 4
        return Factory("Other", area, {}).config.priority == 1 and picky.config.priority == 4
    end)())

-- an ordered priority means exactly what the dropdown says: the best-scoring load, every time
local repeatable = freshPlanner(rankedStations())
repeatable.config.priority = 2
repeatable:planNextHaul()
local firstPick = repeatable.data.currentHaul.good
local second = freshPlanner(rankedStations())
second.config.priority = 2
second:planNextHaul()
check("an ordered priority always takes the best-scoring load",
    firstPick == "Steel" and second.data.currentHaul.good == "Steel")

-- Two identical routes for the same good score identically. Settling that by table order
-- would send a whole fleet down the same one, so the tie is drawn instead -- but a
-- lower-scoring load must still never win.
local function tiedStations()
    return {
        station{name = "Mine A", x = 0, y = 0, sells = {Iron = "seller.lua"}, stock = {Iron = 900}},
        station{name = "Mine B", x = 1, y = 0, sells = {Iron = "seller.lua"}, stock = {Iron = 900}},
        station{name = "Mill", x = 2, y = 0, tradeSlots = 2, buys = {Iron = "factory.lua"}},
        station{name = "Scrap Heap", x = 3, y = 0, sells = {Steel = "seller.lua"}, stock = {Steel = 1}},
        station{name = "Yard", x = 4, y = 0, buys = {Steel = "factory.lua"}},
    }
end

local tiePicks = {}
for _ = 1, 8 do
    local instance = freshPlanner(tiedStations())
    instance.config.priority = 2
    instance:planNextHaul()
    local haul = instance.data.currentHaul
    tiePicks[haul.source.name] = (tiePicks[haul.source.name] or 0) + 1
end
check("a tie is settled among the tied routes only",
    (tiePicks["Mine A"] or 0) + (tiePicks["Mine B"] or 0) == 8)
check("a lower-scoring load never wins a tie-break", tiePicks["Scrap Heap"] == nil)

print("\n[transfer]")

local function transferring(mutate)
    local instance = freshPlanner()
    sectorCalls = {}
    instance:planNextHaul()
    if mutate then mutate(instance) end
    return instance
end

local started = transferring()
check("the pickup is dispatched to the producer's sector",
    #sectorCalls == 1 and sectorCalls[1].x == 0 and sectorCalls[1].y == 0
        and sectorCalls[1].code == Factory.sectorCode.remove)
check("the pickup asks for exactly what was planned",
    sectorCalls[1].args[6] == started.data.currentHaul.amount)

local emptyProducer = transferring()
emptyProducer:onGoodsRemoved("current-command", 1, "Iron", 0)
check("a producer that hands over nothing ends the run without a travel leg",
    emptyProducer.data.phase == "idle" and emptyProducer.data.currentHaul == nil)
check("a run that moved nothing is retried after 15 seconds",
    emptyProducer.data.rescanCooldown == 15)

local moving = transferring()
sectorCalls = {}
moving:onGoodsRemoved("current-command", 1, "Iron", 40)
check("a completed pickup immediately dispatches the delivery",
    moving.data.transaction.stage == "delivering" and moving.data.transaction.amount == 40)
check("the delivery is dispatched to the consumer's sector",
    #sectorCalls == 1 and sectorCalls[1].x == 1 and sectorCalls[1].y == 0
        and sectorCalls[1].code == Factory.sectorCode.add)

local delivered = transferring()
delivered:onGoodsRemoved("current-command", 1, "Iron", 40)
sectorCalls = {}
delivered:onGoodsDelivered("current-command", 1, "Iron", 40, 0)
check("a full delivery needs no return trip", #sectorCalls == 0)
check("a delivered load earns its travel leg",
    delivered.data.phase == "travelling" and delivered.data.transaction == nil)
check("a travel leg is at least 3 minutes", delivered.data.currentHaul.travelTime == 3 * 60)

randomPicksHigh = true
local slowLeg = transferring()
slowLeg:onGoodsRemoved("current-command", 1, "Iron", 40)
slowLeg:onGoodsDelivered("current-command", 1, "Iron", 40, 0)
check("a travel leg is at most 5 minutes", slowLeg.data.currentHaul.travelTime == 5 * 60)
randomPicksHigh = false

local short = transferring()
short:onGoodsRemoved("current-command", 1, "Iron", 40)
sectorCalls = {}
short:onGoodsDelivered("current-command", 1, "Iron", 25, 15)
check("goods the consumer could not take go back to the producer",
    #sectorCalls == 1 and sectorCalls[1].x == 0 and sectorCalls[1].y == 0
        and sectorCalls[1].code == Factory.sectorCode.returnGoods)
check("the return job is handed exactly what the consumer refused",
    sectorCalls[1].args[4] == "Iron Mine"
        and sectorCalls[1].args[5] == "Iron"
        and sectorCalls[1].args[6] == 15)
check("the run waits for the rollback before it counts as done",
    short.data.transaction.stage == "returning" and short.data.phase == "transferring")

short:onGoodsReturned("current-command", 1, "Iron", 15, 0)
check("a partial delivery that rolled back cleanly still earns its travel leg",
    short.data.phase == "travelling")

local rejected = transferring()
rejected:onGoodsRemoved("current-command", 1, "Iron", 40)
rejected:onGoodsDelivered("current-command", 1, "Iron", 0, 40)
rejected:onGoodsReturned("current-command", 1, "Iron", 40, 0)
check("a run the consumer refused outright is retried after 15 seconds",
    rejected.data.phase == "idle" and rejected.data.rescanCooldown == 15)

shipCargo = {}
local stranded = transferring()
stranded:onGoodsRemoved("current-command", 1, "Iron", 40)
stranded:onGoodsDelivered("current-command", 1, "Iron", 0, 40)
stranded:onGoodsReturned("current-command", 1, "Iron", 25, 15)
local strandedAmount = 0
for good, amount in pairs(shipCargo) do
    if good.name == "Iron" then strandedAmount = amount end
end
check("cargo neither station will hold ends up in the ship's own hold", strandedAmount == 15)
check("a hauler carrying cargo it cannot put down comes home",
    stranded.finishOnNextUpdate == true)

shipCargo = {}
local stacking = transferring()
shipCargo[goods.Iron:good()] = 5
stacking:onGoodsRemoved("current-command", 1, "Iron", 40)
stacking:onGoodsDelivered("current-command", 1, "Iron", 0, 40)
stacking:onGoodsReturned("current-command", 1, "Iron", 30, 10)
check("stranded cargo stacks onto what the hold already carries",
    shipCargo[goods.Iron:good()] == 15)
shipCargo = {}

print("\n[returning undelivered goods]")

-- The return runs in its own sector state, so it is loaded and executed here with only the
-- engine calls it touches stubbed out. What the producer's bay refuses is reported back to
-- the command, which is the only way it can be stowed instead of destroyed.
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

local returnReply
function invokeFactionFunction(faction, _, _, _, shipName, callback, token, transactionId, good, returned, lost)
    returnReply = {callback = callback, good = good, returned = returned, lost = lost}
end

local function stationWithBay(name, capacity)
    local entity = {
        name = name,
        bay = {
            stored = 0,
            getNumCargos = function(self) return self.stored end,
            addCargo = function(self, _, amount) self.stored = math.min(capacity, self.stored + amount) end,
        },
    }
    returnStations[name] = entity
    return entity
end

assert(loadstring(Factory.sectorCode.returnGoods, "returnCode"))()

local logLines
local function capturingLog(work)
    logLines = {}
    returnReply = nil
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
capturingLog(function() run(10, "Hauler", 10, "Roomy Mine", "Iron", 15, "current-command", 1) end)
check("a producer with room takes the whole remainder back", roomy.bay.stored == 15)
check("a complete return says nothing", #logLines == 0)
check("a complete return reports nothing stranded",
    returnReply.callback == "onGoodsReturned" and returnReply.returned == 15 and returnReply.lost == 0)

local cramped = stationWithBay("Cramped Mine", 5)
capturingLog(function() run(10, "Hauler", 10, "Cramped Mine", "Iron", 15, "current-command", 1) end)
check("a producer only takes back what fits", cramped.bay.stored == 5)
check("cargo the producer refuses is reported back to the command",
    returnReply.returned == 5 and returnReply.lost == 10)
check("a refused rollback is diagnosed in the log",
    #logLines == 1
        and loggedMatch("'Hauler' could not give 10 units of Iron back to 'Cramped Mine'")
        and loggedMatch("it took only 5 of 15"))

capturingLog(function() run(10, "Hauler", 10, "Vanished Mine", "Iron", 15, "current-command", 1) end)
check("a return to a station that disappeared strands the whole load",
    returnReply.returned == 0 and returnReply.lost == 15
        and loggedMatch("station gone or unknown cargo type"))

capturingLog(function() run(10, "Hauler", 10, "Roomy Mine", "Unobtainium", 15, "current-command", 1) end)
check("a return of an unknown good strands the whole load", returnReply.lost == 15)

print("\n[ferry visuals]")

local function travellingCommand(timer)
    local instance = freshPlanner()
    instance.data.anchor = {x = 5, y = 5}
    instance.data.currentHaul = {
        good = "Iron",
        amount = 100,
        source = {name = "Iron Mine", factionIndex = 10, x = 0, y = 0, script = "seller.lua"},
        target = {name = "Steel Mill", factionIndex = 10, x = 1, y = 0, script = "factory.lua"},
        travelTime = 240,
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

local loading = travellingCommand(0)
loading.data.phase = "transferring"
local loadX, loadY = loading:getAppearanceSector()
check("the ferry loads at the producer while the transfer resolves",
    loadX == 0 and loadY == 0)
check("the loading stop docks the producer",
    loading:getFerryDockTarget().name == "Iron Mine")

local leaving = travellingCommand(0)
local leaveX, leaveY = leaving:getAppearanceSector()
check("the leg starts out from the producer's sector", leaveX == 0 and leaveY == 0)
check("the ferry may patrol while the leg still has slack",
    leaving:ferryTransitLinger() == 60)

local approaching = travellingCommand(200)
local approachX, approachY = approaching:getAppearanceSector()
check("the approach window moves the ferry to the consumer", approachX == 1 and approachY == 0)
check("the approach window docks the consumer",
    approaching:getFerryDockTarget().name == "Steel Mill")
check("there is no patrol time left during the approach", approaching:ferryTransitLinger() == 0)

print("\n[run timing]")

local arriving = travellingCommand(240)
arriving:update(60)
check("arriving frees the ship up for the next run",
    arriving.data.phase == "transferring" and arriving.data.currentHaul.good == "Iron")

local enRoute = travellingCommand(60)
enRoute:update(60)
check("a leg still in progress keeps its haul",
    enRoute.data.phase == "travelling" and enRoute.data.currentHaul ~= nil)

local unloaded = travellingCommand(0)
unloaded.data.phase = "transferring"
unloaded.data.transaction = nil
sectorCalls = {}
unloaded:update(60)
check("a transfer waiting on its sectors keeps trying", #sectorCalls == 1)

-- the sim ticks once a minute, so a 15-second retry has to come back on the very next one
local retrying = travellingCommand(0)
retrying.data.phase = "idle"
retrying.data.currentHaul = nil
retrying.data.rescanCooldown = 15
sectorCalls = {}
retrying:update(60)
check("a 15-second retry looks for a new pair on the next tick",
    retrying.data.phase == "transferring")

local waiting = travellingCommand(0)
waiting.data.phase = "idle"
waiting.data.currentHaul = nil
waiting.data.rescanCooldown = 120
waiting:update(60)
check("a dry-region wait still sits out its full two ticks",
    waiting.data.phase == "idle" and waiting.data.currentHaul == nil)

local stalled = travellingCommand(0)
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
local empty = Factory("Hauler", {lower = {x = 0, y = 0}, upper = {x = 0, y = 0}, analysis = {}}, {})
check("a hauler can be assigned with no stations in range",
    empty:getErrors(10, "Hauler", empty.area, empty.config) == nil)
check("a hauler can be assigned when nothing pairs up",
    producerOnly:getErrors(10, "Hauler", area, producerOnly.config) == nil)

print("\n[callback correlation]")
local correlating = freshPlanner()
correlating.data.phase = "transferring"
correlating.data.currentHaul = {good = "Iron", source = correlating.data.stations[1], target = correlating.data.stations[2]}
correlating.data.transaction = {id = 42, stage = "removing", good = "Iron", delivered = 0}
correlating:onGoodsRemoved("current-command", 41, "Iron", 10)
check("stale reply is ignored", correlating.data.transaction.stage == "removing")
correlating:onGoodsRemoved("current-command", 42, "Steel", 10)
check("wrong-good reply is ignored", correlating.data.transaction.stage == "removing")
correlating:onGoodsRemoved("previous-command", 42, "Iron", 10)
check("previous command reply is ignored", correlating.data.transaction.stage == "removing")
correlating:onGoodsDelivered("current-command", 42, "Iron", 10, 0)
check("wrong-stage reply is ignored", correlating.data.transaction.stage == "removing")

print("\n[restore]")

-- a restored command must not sit waiting for a sector reply that died with the server
local restored = Factory("Hauler", area, {})
restored.data.transferProtocolVersion = 3
restored.data.commandToken = "restored-command"
restored.data.phase = "transferring"
restored.data.currentHaul = {good = "Iron", source = command.data.stations[1], target = command.data.stations[2]}
restored.data.transaction = {id = 70, stage = "delivering", good = "Iron"}
restored:onRestore(restored.data)
check("restore drops the orphaned transaction", restored.data.transaction == nil)
check("restore looks for a new run instead of replaying", restored.data.phase == "idle")
check("restore does not recall a healthy command", not restored.finishOnNextUpdate)
check("restore fills in a missing priority", restored.config.priority == 1)

-- goods used to sit on the ship between two stations; such a command can't be reconciled
local legacy = Factory("Hauler", area, {})
legacy.data.commandToken = "legacy-command"
legacy.data.currentHaul = {good = "Iron", source = command.data.stations[1], target = command.data.stations[2], carriedAmount = 20}
legacy:onRestore(legacy.data)
check("a command from before instant transfers is recalled for cargo verification",
    legacy.finishOnNextUpdate == true)

if failures > 0 then
    error(string.format("%d stock factory command test(s) failed", failures))
end

print("\nAll stock factory command tests passed.")
