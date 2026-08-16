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
function random()
    return {getInt = function(_, low) return low end}
end

ChatMessageType = {Error = 1, Normal = 2}

local shipScriptValues = {}
function ShipDatabaseEntry()
    return {
        getFreeCargoSpace = function() return 100 end,
        getScriptValue = function(_, key) return shipScriptValues[key] end,
        setScriptValue = function(_, key, value) shipScriptValues[key] = value end,
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

local function pairedStations()
    return {
        {name = "Iron Mine", factionIndex = 10, x = 0, y = 0, sells = {Iron = "seller.lua"}, buys = {}},
        {name = "Steel Mill", factionIndex = 10, x = 0, y = 0, sells = {Steel = "factory.lua"}, buys = {Iron = "factory.lua"}},
    }
end

local planner = Factory("Hauler", area, {ignoredGoods = {}})
planner.data.stations = pairedStations()
planner:planNextHaul()
check("planning picks the producer/consumer pair",
    planner.data.phase == "haulingToSource"
        and planner.data.currentHaul.good == "Iron"
        and planner.data.currentHaul.source.name == "Iron Mine"
        and planner.data.currentHaul.target.name == "Steel Mill")
check("planning resolves the trade script for both ends",
    planner.data.currentHaul.source.script == "seller.lua"
        and planner.data.currentHaul.target.script == "factory.lua")

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

print("\n[assignment]")
local empty = Factory("Hauler", {lower = {x = 0, y = 0}, upper = {x = 0, y = 0}, analysis = {}}, {ignoredGoods = {}})
check("a hauler can be assigned with no stations in range",
    empty:getErrors(10, "Hauler", empty.area, empty.config) == nil)
check("a hauler can be assigned when nothing pairs up",
    producerOnly:getErrors(10, "Hauler", area, producerOnly.config) == nil)

print("\n[callback correlation]")
command.data.phase = "transactingPickup"
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

print("\n[stalled transactions]")

local haul = {good = "Iron", source = command.data.stations[1], target = command.data.stations[2]}

command.data.phase = "transactingPickup"
command.data.currentHaul = haul
command.data.transaction = {id = 43, stage = "removing", good = "Iron"}
command.data.timer = 250
command:rewindPendingTransaction()
check("rewinding a pickup returns to the source leg", command.data.phase == "haulingToSource")
check("rewinding clears the pending transaction", command.data.transaction == nil)
check("rewinding restarts the phase timer", command.data.timer == 0)

command.data.phase = "transactingDelivery"
command.data.transaction = {id = 44, stage = "delivering", good = "Iron"}
command:rewindPendingTransaction()
check("rewinding a delivery returns to the target leg", command.data.phase == "haulingToTarget")

command.data.phase = "transactingPickup"
command.data.currentHaul = nil
command.data.transaction = {id = 45, stage = "removing", good = "Iron"}
command:rewindPendingTransaction()
check("rewinding without a haul falls back to idle", command.data.phase == "idle")

command.data.transaction = nil
command.data.phase = "haulingToSource"
command:rewindPendingTransaction()
check("rewinding without a transaction changes nothing", command.data.phase == "haulingToSource")

-- a stalled sector reply must retry the leg a few times before it is allowed to recall
command.finishOnNextUpdate = nil
command.data.currentHaul = haul
command.data.transactionTimeouts = 0
for attempt = 1, 2 do
    command.data.phase = "transactingPickup"
    command.data.transaction = {id = 50 + attempt, stage = "removing", good = "Iron"}
    command.data.timer = 0
    command:update(400)
    check("timeout " .. attempt .. " retries instead of recalling",
        command.data.phase == "haulingToSource" and not command.finishOnNextUpdate)
end

command.data.phase = "transactingPickup"
command.data.transaction = {id = 60, stage = "removing", good = "Iron"}
command.data.timer = 0
command:update(400)
check("the retry budget eventually gives up and recalls", command.finishOnNextUpdate == true)

-- a completed transfer clears the budget so unrelated later stalls get their full retries
command.data.transaction = {id = 61, stage = "delivering", good = "Iron"}
command.data.currentHaul = haul
haul.carriedAmount = 10
command:onGoodsDelivered("current-command", 61, "Iron", 10, 0)
check("a successful delivery resets the timeout budget", command.data.transactionTimeouts == 0)

print("\n[restore]")

-- a restored v2 command must not sit waiting for a sector reply that died with the server
local restored = Factory("Hauler", area, {ignoredGoods = {}})
restored.data.transactionProtocolVersion = 2
restored.data.commandToken = "restored-command"
restored.data.phase = "transactingDelivery"
restored.data.currentHaul = haul
restored.data.transaction = {id = 70, stage = "delivering", good = "Iron"}
restored:onRestore(restored.data)
check("restore drops the orphaned transaction", restored.data.transaction == nil)
check("restore replays the interrupted leg", restored.data.phase == "haulingToTarget")

if failures > 0 then
    error(string.format("%d stock factory command test(s) failed", failures))
end

print("\nAll stock factory command tests passed.")
