package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/player/background/simulation/?.lua"

local CommandType = include ("commandtype")
local SimulationUtility = include ("simulationutility")
local CaptainUtility = include ("captainutility")
local TradingUtility = include ("tradingutility")
local GatesMap = include ("gatesmap")
local StockFactoryUtility = include ("stockfactoryutility")
include ("utility")
include ("stringutility")
include ("goods")


local StockFactoryCommand = {}
StockFactoryCommand.__index = StockFactoryCommand
StockFactoryCommand.type = CommandType.StockFactory

-- anchor-sector operating radius over the gate network
local MaxGateJumps = 5

-- suppliers are reached purely through the gate network; cycle time is modelled
-- per gate jump between the target and the supplier, plus a fixed docking overhead
local SecondsPerGateJump = 45
local DockingSeconds = 120

-- safety cap so the gate-jump flood fill can never run away
local MaxReachableSectors = 400

-- how often (seconds) the command re-scans reachable suppliers and the gate route
local RemapInterval = 5 * 60
local CommandLeaseKey = "stock_factory_command_lease"

-- how long to wait for an asynchronous sector transfer before replaying the leg,
-- and how many replays to allow before giving up and recalling
local TransactionTimeout = 300
local MaxTransactionTimeouts = 2

-- loaded sectors are fully simulated, so they are only held for as long as a queued
-- runSectorCode job needs to reach its next update tick
local SectorKeepSeconds = 30

-- window in which every command that remaps in the same simulation tick shares one
-- empire-wide station scan
local StationTradeCacheSeconds = 10

-- a committing transfer only blocks recall for this long, so a lost sector reply can
-- never strand the ship (Simulation.forceRecall silently aborts on a recall error)
local RecallBlockSeconds = 30


---------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------

-- a good may only be ferried if it exists and isn't stolen or illegal
local function isGoodEligible(name)
    local good = goods[name]
    if not good then return false end
    if good.stolen or good.illegal then return false end
    return true
end

local function isGoodIgnored(config, name)
    return config and type(config.ignoredGoods) == "table" and config.ignoredGoods[name] == true
end

local function skey(x, y)
    return x .. ":" .. y
end

-- all eligible goods present across any station in the list (union of buys and sells)
local function allStationGoods(stations)
    local result = {}
    for _, st in pairs(stations or {}) do
        for good, _ in pairs(st.buys or {}) do
            if not result[good] and isGoodEligible(good) then result[good] = true end
        end
        for good, _ in pairs(st.sells or {}) do
            if not result[good] and isGoodEligible(good) then result[good] = true end
        end
    end
    return result
end

-- One pass over the stations yields, per good, the stations that can receive it and the
-- stations that can supply it. A target has to buy the good and a source must not, so the
-- two lists are always disjoint.
local function buildRouteIndex(stations, config)
    local index = {}

    local function entryFor(good)
        local entry = index[good]
        if not entry then
            entry = {targets = {}, sources = {}}
            index[good] = entry
        end
        return entry
    end

    for _, st in pairs(stations or {}) do
        if st.stockHaulerDeliveryEnabled ~= false then
            for good, _ in pairs(st.buys or {}) do
                if isGoodEligible(good) and not isGoodIgnored(config, good) then
                    table.insert(entryFor(good).targets, st)
                end
            end
        end

        if st.stockHaulerPickupEnabled ~= false then
            for good, _ in pairs(st.sells or {}) do
                if isGoodEligible(good) and not isGoodIgnored(config, good)
                    and not (st.buys and st.buys[good]) then
                    table.insert(entryFor(good).sources, st)
                end
            end
        end
    end

    return index
end

local function goodDisplayName(name, amount)
    local good = goods[name]
    if good then
        local ok, result = pcall(function() return good:good():displayName(amount or 2) end)
        if ok and result and result ~= "" then return result end
    end
    return name
end

local function areaAnchor(area)
    if area and area.lower then
        return area.lower.x, area.lower.y
    end
end

local function clearCommandLease(ownerIndex, shipName, commandToken)
    local entry = ShipDatabaseEntry(ownerIndex, shipName)
    if valid(entry) and entry:getScriptValue(CommandLeaseKey) == commandToken then
        entry:setScriptValue(CommandLeaseKey, nil)
    end
end


---------------------------------------------------------------------
-- construction
---------------------------------------------------------------------

-- all commands need this kind of "new" to function within the bg simulation framework
-- it must be possible to call the command without any parameters to access some functionality
local function new(ship, area, config)
    config = config or {}
    if type(config.ignoredGoods) ~= "table" then config.ignoredGoods = {} end

    local command = setmetatable({
        type = CommandType.StockFactory,
        shipName = ship,
        area = area,
        config = config,
        data = {},
        simulation = nil,
    }, StockFactoryCommand)

    command.finishOnNextUpdate = false

    return command
end

-- all commands have the following functions, even if not listed here (added by Simulation script on command creation):
-- function StockFactoryCommand:addYield(message, money, resources, items) end
-- function StockFactoryCommand:finish() end
-- function StockFactoryCommand:registerForAttack(coords, faction, timeOfAttack, message, arguments) end
-- NOTE: this command deliberately never calls registerForAttack(). That keeps it
-- from self-recalling on a simulated ambush: if the ship is attacked it emits the
-- normal warning (handled by the game) but keeps ferrying.


---------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------

function StockFactoryCommand:initialize()
    local ax = areaAnchor(self.area)
    if not ax then
        return "We need an anchor sector."%_T
    end
end

function StockFactoryCommand:onStart()
    -- cache the station list + reachable region + gate route that were computed
    -- during the area analysis, so the ferry logic has them available (all saved
    -- to the database)
    local analysis = self.area and self.area.analysis or {}
    local ax, ay = areaAnchor(self.area)
    if (not ax) and analysis.anchor then
        ax, ay = analysis.anchor.x, analysis.anchor.y
    end
    self.data.anchor = {x = ax, y = ay}

    self.data.stations = analysis.stations or {}
    self.data.reachable = analysis.reachable or {}
    self.data.gateCameFrom = analysis.gateCameFrom or {}
    self.data.gateDepth = analysis.gateDepth or {}
    self.data.callingPlayer = analysis.callingPlayer
    self.config = self.config or {}
    self.config.ignoredGoods = self.config.ignoredGoods or {}

    self.data.phase = "idle"
    self.data.timer = 0
    self.data.rescanCooldown = 0
    self.data.remapCooldown = RemapInterval
    self.data.nextTransactionId = 0
    self.data.transaction = nil
    self.data.transactionProtocolVersion = 2
    self.data.commandToken = tostring(random():createSeed()) .. ":" .. tostring(random():createSeed())

    local owner = getParentFaction()
    local entry = ShipDatabaseEntry(owner.index, self.shipName)
    entry:setScriptValue(CommandLeaseKey, self.data.commandToken)
    entry:setStatusMessage("Stocking a sector"%_T)
end

function StockFactoryCommand:update(timeStep)
    if self.finishOnNextUpdate then
        self:finish()
        return
    end

    -- periodically re-scan the reachable suppliers + gate route so the command
    -- follows the galaxy (gates turning hostile, suppliers built or destroyed).
    -- Recalls the ship if it can no longer do the job.
    self.data.remapCooldown = (self.data.remapCooldown or RemapInterval) - timeStep
    if self.data.remapCooldown <= 0 then
        self.data.remapCooldown = RemapInterval
        self:remapRoute()
        if self.finishOnNextUpdate then
            self:finish()
            return
        end
    end

    self.data.timer = (self.data.timer or 0) + timeStep

    local phase = self.data.phase or "idle"

    if phase == "idle" then
        if (self.data.rescanCooldown or 0) > 0 then
            self.data.rescanCooldown = self.data.rescanCooldown - timeStep
            return
        end
        self:planNextHaul()

    elseif phase == "haulingToSource" then
        local haul = self.data.currentHaul
        if not haul then
            self.data.phase = "idle"
            return
        end

        if self.data.timer >= (haul.pickupTravelTime or haul.travelTime or 60) then
            self:beginPickupTransaction()
        end

    elseif phase == "haulingToTarget" then
        local haul = self.data.currentHaul
        if not haul then
            self.data.phase = "idle"
            return
        end

        if self.data.timer >= (haul.deliveryTravelTime or haul.travelTime or 60) then
            self:beginDeliveryTransaction()
        end

    elseif phase == "transactingPickup" or phase == "transactingDelivery" then
        -- waiting for the asynchronous sector probes / transfers to report back.
        -- The ship's real cargo is the source of truth and every transfer clamps to it,
        -- so replaying the leg can't duplicate goods. Only give up after repeated timeouts.
        if self.data.timer >= TransactionTimeout then
            self.data.transactionTimeouts = (self.data.transactionTimeouts or 0) + 1

            if self.data.transactionTimeouts > MaxTransactionTimeouts then
                self:setRuntimeError("Commander, the stock transfer keeps timing out. I'm aborting with any collected cargo still in the hold."%_T)
                return
            end

            self:rewindPendingTransaction()
        end
    end
end

-- Drops an in-flight transaction and rewinds to the travel leg that issued it. Used when a
-- queued runSectorCode job can no longer answer -- it timed out, or the server restarted and
-- took the queue with it. Nothing is lost: the cargo already moved is on the ship, and the
-- replayed transfer clamps to the ship's real cargo and free space.
function StockFactoryCommand:rewindPendingTransaction()
    if not self.data.transaction then return end

    self.data.transaction = nil
    self.data.probeRetries = 0
    self.data.timer = 0

    local phase = self.data.phase
    if phase == "transactingPickup" then
        self.data.phase = self.data.currentHaul and "haulingToSource" or "idle"
    elseif phase == "transactingDelivery" then
        self.data.phase = self.data.currentHaul and "haulingToTarget" or "idle"
    end
end

function StockFactoryCommand:onRecall()
    self.data.transaction = nil
    local owner = getParentFaction()
    clearCommandLease(owner.index, self.shipName, self.data.commandToken)
end

function StockFactoryCommand:onFinish()
    self.data.transaction = nil
    local owner = getParentFaction()
    clearCommandLease(owner.index, self.shipName, self.data.commandToken)
end

function StockFactoryCommand:onSecure()
end

function StockFactoryCommand:onRestore()
    self.config = self.config or {}
    if type(self.config.ignoredGoods) ~= "table" then self.config.ignoredGoods = {} end
    self.data.nextTransactionId = self.data.nextTransactionId or 0

    if self.data.transactionProtocolVersion == 2 and self.data.commandToken then
        local owner = getParentFaction()
        local entry = ShipDatabaseEntry(owner.index, self.shipName)
        if valid(entry) then entry:setScriptValue(CommandLeaseKey, self.data.commandToken) end

        -- queued sector jobs don't survive a restart, so an in-flight transfer would
        -- otherwise sit until it times out and recall a perfectly healthy command
        self.data.transactionTimeouts = 0
        self:rewindPendingTransaction()
        return
    end

    local haul = self.data.currentHaul
    local amount = haul and (haul.carriedAmount or 0) or 0
    self.data.transaction = nil
    self.data.transactionProtocolVersion = 2

    if amount > 0 and not haul.cargoOnShip then
        local owner = getParentFaction()
        local entry = ShipDatabaseEntry(owner.index, self.shipName)
        if valid(entry) then
            entry:setScriptValue("stock_factory_pending_cargo_good", haul.good)
            entry:setScriptValue("stock_factory_pending_cargo_amount", amount)
            entry:addScriptOnce("data/scripts/entity/utility/stockfactorycargorecovery.lua")
        end
    end

    self:setRuntimeError("Commander, this Stock Factory command used an older transfer protocol. I'm recalling so its cargo state can be verified safely."%_T)
end

function StockFactoryCommand:onAttacked(attackerFaction, x, y)
    -- intentionally empty: the ship keeps its command when attacked
end


---------------------------------------------------------------------
-- ferry planning
---------------------------------------------------------------------

-- stations in the anchor region that consume the good and allow stock-hauler delivery
function StockFactoryCommand:eligibleTargets(good)
    local result = {}

    if isGoodIgnored(self.config, good) then return result end

    for _, st in pairs(self.data.stations or {}) do
        if st.buys and st.buys[good]
            and st.stockHaulerDeliveryEnabled ~= false then
            table.insert(result, st)
        end
    end

    return result
end

-- stations in the anchor region that can supply the good for a target:
--  - different station than the consumer
--  - sell the good
--  - do not also buy the same good (prevents internal starvation/loops)
--  - not opted out of stock-hauler pickup
function StockFactoryCommand:eligibleSources(good, target)
    local result = {}

    if isGoodIgnored(self.config, good) then return result end

    for _, st in pairs(self.data.stations or {}) do
        if not (st.name == target.name and st.factionIndex == target.factionIndex)
            and st.sells and st.sells[good]
            and not (st.buys and st.buys[good])
            and st.stockHaulerPickupEnabled ~= false then
            table.insert(result, st)
        end
    end

    return result
end

-- travel time for one leg of the haul, modelled from the number of gate jumps
-- between the target and the supplier (recorded during the reachable-region BFS)
-- plus a fixed docking overhead. Distance through empty space is irrelevant here.
function StockFactoryCommand:estimateTravelTime(source, target)
    local depthMap = self.data.gateDepth or {}
    local sourceJumps = depthMap[skey(source.x, source.y)] or MaxGateJumps
    local targetJumps = depthMap[skey(target.x, target.y)] or MaxGateJumps
    local jumps = math.max(1, sourceJumps + targetJumps)
    return jumps * SecondsPerGateJump + DockingSeconds
end

function StockFactoryCommand:planNextHaul()
    -- Choose one (good, source, target) triple uniformly at random so the route order is
    -- not predictable, without building every triple: sources and targets are disjoint per
    -- good, so a good contributes exactly #targets * #sources pairs.
    local index = buildRouteIndex(self.data.stations, self.config)

    local total = 0
    for _, entry in pairs(index) do
        total = total + #entry.targets * #entry.sources
    end

    if total > 0 then
        local pick = random():getInt(1, total)
        local good, source, target

        for name, entry in pairs(index) do
            local pairsForGood = #entry.targets * #entry.sources
            if pick <= pairsForGood then
                good = name
                target = entry.targets[math.floor((pick - 1) / #entry.sources) + 1]
                source = entry.sources[(pick - 1) % #entry.sources + 1]
                break
            end
            pick = pick - pairsForGood
        end

        local travelTime = self:estimateTravelTime(source, target)

        self.data.currentHaul = {
            good = good,
            source = {
                name = source.name,
                factionIndex = source.factionIndex,
                x = source.x,
                y = source.y,
                script = source.sells[good],
            },
            target = {
                name = target.name,
                factionIndex = target.factionIndex,
                x = target.x,
                y = target.y,
                script = target.buys[good],
            },
            travelTime = travelTime,
            pickupTravelTime = travelTime,
            deliveryTravelTime = travelTime,
            carriedAmount = 0,
        }

        self.data.phase = "haulingToSource"
        self.data.timer = 0
        return
    end

    -- nothing to fetch right now: stay assigned, idle near the station, re-scan later
    self.data.phase = "idle"
    self.data.rescanCooldown = 120
end


---------------------------------------------------------------------
-- transactions (asynchronous, executed inside the loaded sectors)
---------------------------------------------------------------------

-- Each sector job runs in a throwaway Lua state, so nothing it includes is ever reused.
-- goods.lua would build a TradingGood for all ~150 goods and sort several derived arrays
-- on every transfer; a job only ever touches one good, so it converts that one itself.
local goodsHelperCode = [[
include("goodsindex")
goods["Silicium"] = goods["Silicium"] or goods["Silicon"]
goods["Aluminium"] = goods["Aluminium"] or goods["Aluminum"]

local function tradingGood(descriptor)
    local price = descriptor.price
    if price == 0 then price = 500 end

    local good = TradingGood(descriptor.name, descriptor.plural, descriptor.description, descriptor.icon, price, descriptor.size)
    good.mesh = descriptor.mesh or ""
    good.illegal = descriptor.illegal or false
    good.suspicious = descriptor.suspicious or false
    good.stolen = descriptor.stolen or false
    good.dangerous = descriptor.dangerous or false
    good.tags = descriptor.tags or {}
    return good
end
]]

local probeCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("stringutility")
local StockFactoryUtility = include("stockfactoryutility")

function run(faction, shipName, stationFaction, stationName, script, goodName, callback, commandToken, transactionId, callingPlayer)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end -- command will be cancelled anyway
    if not StockFactoryUtility.hasCommandLease(ship, commandToken) then return end

    local owner = Galaxy():findFaction(faction)
    if not StockFactoryUtility.canUseStation(owner, stationFaction, callingPlayer) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, I no longer have permission to manage station '%s'."%_T, stationName)
        return
    end

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
    if not valid(station) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, station '%s' has disappeared!"%_T, stationName)
        return
    end

    local callError, stock, maxStock = station:invokeFunction(script, "getStock", goodName)
    if callError ~= 0 then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, callback, commandToken, transactionId, goodName, 0, 0)
        return
    end

    invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, callback, commandToken, transactionId, goodName, stock, maxStock)
end
]]

local removeCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("stringutility")
local StockFactoryUtility = include("stockfactoryutility")
]] .. goodsHelperCode .. [[

function run(faction, shipName, stationFaction, stationName, goodName, amount, commandToken, transactionId, callingPlayer)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end
    if not StockFactoryUtility.hasCommandLease(ship, commandToken) then return end

    local owner = Galaxy():findFaction(faction)
    if not StockFactoryUtility.canUseStation(owner, stationFaction, callingPlayer) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, I no longer have permission to manage station '%s'."%_T, stationName)
        return
    end

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
    if not valid(station) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, station '%s' has disappeared!"%_T, stationName)
        return
    end

    local good = goods[goodName]
    if not good then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, the cargo type for '%s' is no longer available."%_T, goodName)
        return
    end

    amount = math.min(amount, math.floor(ship:getFreeCargoSpace() / math.max(good.size or 1, 0.0001)))
    local removed = StockFactoryUtility.transferToShip(CargoBay(station), ship, tradingGood(good), amount)

    invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "onGoodsRemoved", commandToken, transactionId, goodName, removed)
end
]]

local addCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("stringutility")
local StockFactoryUtility = include("stockfactoryutility")
]] .. goodsHelperCode .. [[

function run(faction, shipName, stationFaction, stationName, goodName, amount, commandToken, transactionId, callingPlayer)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end
    if not StockFactoryUtility.hasCommandLease(ship, commandToken) then return end

    local owner = Galaxy():findFaction(faction)
    if not StockFactoryUtility.canUseStation(owner, stationFaction, callingPlayer) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, I no longer have permission to manage station '%s'."%_T, stationName)
        return
    end

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
    if not valid(station) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, station '%s' has disappeared!"%_T, stationName)
        return
    end

    local good = goods[goodName]
    if not good then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", commandToken, transactionId, "Commander, the cargo type for '%s' is no longer available."%_T, goodName)
        return
    end

    local added, notAdded = StockFactoryUtility.transferToStation(CargoBay(station), ship, tradingGood(good), amount)

    invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "onGoodsDelivered", commandToken, transactionId, goodName, added, notAdded)
end
]]

function StockFactoryCommand:querySectors(needSource, needTarget)
    local haul = self.data.currentHaul
    local t = haul and haul.target
    local s = haul and haul.source
    if not t or not s then return false end

    if needTarget then
        Galaxy():keepOrGetSector(t.x, t.y, SectorKeepSeconds)
    end
    if needSource then
        Galaxy():keepOrGetSector(s.x, s.y, SectorKeepSeconds)
    end

    if needTarget and not Galaxy():sectorLoaded(t.x, t.y) then
        return false
    end
    if needSource and not Galaxy():sectorLoaded(s.x, s.y) then
        return false
    end

    return true
end

function StockFactoryCommand:beginPickupTransaction()
    local haul = self.data.currentHaul
    local owner = getParentFaction()
    local t = haul.target
    local s = haul.source

    if not StockFactoryUtility.canUseStation(owner, t.factionIndex, self.data.callingPlayer)
        or not StockFactoryUtility.canUseStation(owner, s.factionIndex, self.data.callingPlayer) then
        self:setRuntimeError("Commander, I no longer have permission to manage one of the stations on this route."%_T)
        return
    end

    if not t.script or not s.script then
        -- we don't know which scripts trade the good; skip this haul
        self.data.currentHaul = nil
        self.data.phase = "idle"
        self.data.rescanCooldown = 30
        return
    end

    if not self:querySectors(true, true) then
        -- sectors not loaded yet: keep trying for a while, then give up this haul
        self.data.probeRetries = (self.data.probeRetries or 0) + 1
        if self.data.probeRetries > 15 then
            self.data.probeRetries = 0
            self.data.currentHaul = nil
            self.data.phase = "idle"
            self.data.rescanCooldown = 60
        end
        return
    end
    self.data.probeRetries = 0

    self.data.nextTransactionId = (self.data.nextTransactionId or 0) + 1
    local transactionId = self.data.nextTransactionId
    self.data.transaction = {
        id = transactionId,
        stage = "probing",
        good = haul.good,
        targetReceived = false,
        sourceReceived = false,
        targetRoom = 0,
        sourceStock = 0,
    }

    runSectorCode(t.x, t.y, true, probeCode, "run", owner.index, self.shipName, t.factionIndex or owner.index, t.name, t.script, haul.good, "reportTargetStock", self.data.commandToken, transactionId, self.data.callingPlayer)
    runSectorCode(s.x, s.y, true, probeCode, "run", owner.index, self.shipName, s.factionIndex or owner.index, s.name, s.script, haul.good, "reportSourceStock", self.data.commandToken, transactionId, self.data.callingPlayer)

    self.data.phase = "transactingPickup"
    self.data.timer = 0
end

function StockFactoryCommand:beginDeliveryTransaction()
    local haul = self.data.currentHaul
    local owner = getParentFaction()
    if not haul or not owner then return end

    local amount = haul.carriedAmount or 0
    if amount <= 0 then
        self.data.currentHaul = nil
        self.data.phase = "idle"
        self.data.rescanCooldown = 0
        return
    end

    if not StockFactoryUtility.canUseStation(owner, haul.target.factionIndex, self.data.callingPlayer) then
        self:setRuntimeError("Commander, I no longer have permission to manage the destination station. I'm aborting with the collected cargo still in the hold."%_T)
        return
    end

    if not self:querySectors(false, true) then
        self.data.probeRetries = (self.data.probeRetries or 0) + 1
        if self.data.probeRetries > 15 then
            self.data.probeRetries = 0
            self:setRuntimeError("Commander, I couldn't load the destination sector. I'm aborting with the collected cargo still in the hold."%_T)
        end
        return
    end
    self.data.probeRetries = 0

    local t = haul.target
    self.data.nextTransactionId = (self.data.nextTransactionId or 0) + 1
    local transactionId = self.data.nextTransactionId
    self.data.transaction = {id = transactionId, stage = "delivering", good = haul.good, amount = amount}
    runSectorCode(t.x, t.y, true, addCode, "run", owner.index, self.shipName, t.factionIndex or owner.index, t.name, haul.good, amount, self.data.commandToken, transactionId, self.data.callingPlayer)

    self.data.phase = "transactingDelivery"
    self.data.timer = 0
end

function StockFactoryCommand:reportTargetStock(commandToken, transactionId, good, stock, maxStock)
    local transaction = self.data.transaction
    if self.data.commandToken ~= commandToken or not transaction or transaction.id ~= transactionId or transaction.good ~= good or transaction.stage ~= "probing" then return end
    transaction.targetRoom = math.max(0, (maxStock or 0) - (stock or 0))
    transaction.targetReceived = true

    self:tryExecuteHaul()
end

function StockFactoryCommand:reportSourceStock(commandToken, transactionId, good, stock, maxStock)
    local transaction = self.data.transaction
    if self.data.commandToken ~= commandToken or not transaction or transaction.id ~= transactionId or transaction.good ~= good or transaction.stage ~= "probing" then return end
    transaction.sourceStock = stock or 0
    transaction.sourceReceived = true

    self:tryExecuteHaul()
end

function StockFactoryCommand:tryExecuteHaul()
    local tr = self.data.transaction
    if not tr or not tr.targetReceived or not tr.sourceReceived then return end

    local owner = getParentFaction()
    local haul = self.data.currentHaul
    if not haul then
        self.data.transaction = nil
        return
    end

    local good = tr.good
    local size = goods[good] and goods[good].size or 1

    local ship = ShipDatabaseEntry(owner.index, self.shipName)
    local cargoUnits = 0
    if valid(ship) then
        cargoUnits = math.floor(ship:getFreeCargoSpace() / size)
    end

    -- never haul more than the station actually needs (its free room), never more
    -- than the source has, and never more than the ship can carry
    local amount = math.min(tr.targetRoom, tr.sourceStock, cargoUnits)

    if not amount or amount <= 0 then
        -- source has no stock yet, or consumer is already full
        -- try a new random pair soon instead of cycling deterministically
        self.data.currentHaul = nil
        self.data.transaction = nil
        self.data.phase = "idle"
        self.data.rescanCooldown = 5
        return
    end

    tr.stage = "removing"
    tr.amount = amount
    runSectorCode(haul.source.x, haul.source.y, true, removeCode, "run", owner.index, self.shipName, haul.source.factionIndex or owner.index, haul.source.name, good, amount, self.data.commandToken, tr.id, self.data.callingPlayer)
end

function StockFactoryCommand:onGoodsRemoved(commandToken, transactionId, good, removed)
    local owner = getParentFaction()
    local haul = self.data.currentHaul
    local transaction = self.data.transaction
    if self.data.commandToken ~= commandToken or not haul or not transaction or transaction.id ~= transactionId or transaction.good ~= good or transaction.stage ~= "removing" then return end

    self.data.transaction = nil
    self.data.transactionTimeouts = 0

    if (removed or 0) <= 0 then
        -- source was empty at pickup time (produced nothing yet)
        -- retry with a different random pair soon
        self.data.currentHaul = nil
        self.data.phase = "idle"
        self.data.rescanCooldown = 5
        return
    end

    -- log the pickup to economy chat
    local goodName = goodDisplayName(good, removed)
    local sourceStationName = haul.source.name
    owner:sendChatMessage("", ChatMessageType.Economy, "(%1%:%2%) %3% picked up %4% units of %5% from %6%."%_T,
        haul.source.x, haul.source.y, self.shipName, removed, goodName, sourceStationName)

    haul.carriedAmount = removed
    haul.cargoOnShip = true
    self.data.phase = "haulingToTarget"
    self.data.timer = 0
end

function StockFactoryCommand:onGoodsDelivered(commandToken, transactionId, good, added, notAdded)
    local owner = getParentFaction()
    local haul = self.data.currentHaul
    local transaction = self.data.transaction
    if self.data.commandToken ~= commandToken or not haul or not transaction or transaction.id ~= transactionId or transaction.good ~= good or transaction.stage ~= "delivering" then return end

    self.data.transaction = nil
    self.data.transactionTimeouts = 0

    local amountToDeliver = (added or 0) + (notAdded or 0)
    haul.carriedAmount = notAdded or 0

    -- if nothing was delivered at all, the station rejected the cargo (destroyed, full, etc.)
    -- abort and return to player control with the full cargo load
    if (added or 0) <= 0 then
        self:setRuntimeError("Commander, the delivery to %1% failed. I'm aborting with the full cargo load. Please handle this manually."%_T, haul.target.name)
        return
    end

    -- if only part of the cargo fit (overflow due to other ships or station issue),
    -- abort and return to player control with remaining cargo
    if (notAdded or 0) > 0 then
        self:setRuntimeError("Commander, I could only deliver %1% of the %2% units to %3%. The station was full. I'm aborting with %4% units of cargo left in the hold."%_T, added, amountToDeliver, haul.target.name, notAdded)
        return
    end

    -- full delivery succeeded: log it and continue
    local goodName = goodDisplayName(good, added)
    local targetStationName = haul.target.name
    owner:sendChatMessage("", ChatMessageType.Economy, "(%1%:%2%) %3% delivered %4% units of %5% to %6%."%_T,
        haul.target.x, haul.target.y, self.shipName, added, goodName, targetStationName)

    local returnLeg = (haul and haul.travelTime) or 60

    haul.carriedAmount = 0
    self.data.currentHaul = nil
    self.data.phase = "idle"
    self.data.rescanCooldown = returnLeg -- simulate the trip back before the next haul
end

function StockFactoryCommand:transactionError(commandToken, transactionId, msg, ...)
    local transaction = self.data.transaction
    if self.data.commandToken ~= commandToken or not transaction or transaction.id ~= transactionId then return end
    self.data.transaction = nil
    self:setRuntimeError(msg, ...)
end

function StockFactoryCommand:setRuntimeError(msg, ...)
    local owner = getParentFaction()
    eprint(msg, ...)
    owner:sendChatMessage("", ChatMessageType.Error, msg, ...)
    clearCommandLease(owner.index, self.shipName, self.data.commandToken)
    self.finishOnNextUpdate = true
end


---------------------------------------------------------------------
-- area analysis (gathers owned stations + the reachable region)
---------------------------------------------------------------------

function StockFactoryCommand:getAreaAnalysisSectors(results, meta)
end

function StockFactoryCommand:onAreaAnalysisStart(results, meta)
end

function StockFactoryCommand:onAreaAnalysisSector(results, meta, x, y)
end

-- Gate topology is derived from the server seed and never changes, so both the map and its
-- connection lookups are memoised for the whole session. GatesMap:getConnectedSectors scans
-- a 181x181 sector window per call, which is far too expensive to repeat on every remap.
local cachedGatesMap
local gateNeighbourCache = {}

local function getGatesMap()
    if not cachedGatesMap then
        local ok, map = pcall(function() return GatesMap(Server().seed) end)
        if ok then cachedGatesMap = map end
    end

    return cachedGatesMap
end

-- Player-built gates are invisible to GatesMap, which only knows the seeded network. The
-- gate-construction mod publishes its active links as a server value ("ax:ay>bx:by" joined
-- by ";"); reading it directly keeps this mod usable on its own. Unlike the seeded network
-- these links appear at runtime, so they are re-read whenever the raw value changes.
local BuiltGateLinksKey = "gate_construction_links"
local builtGateLinks = {}
local builtGateLinksRaw

local function refreshBuiltGateLinks()
    local ok, raw = pcall(function() return Server():getValue(BuiltGateLinksKey) end)
    raw = (ok and type(raw) == "string") and raw or ""

    if raw == builtGateLinksRaw then return end
    builtGateLinksRaw = raw
    builtGateLinks = {}

    local function link(fromKey, x, y)
        local neighbours = builtGateLinks[fromKey]
        if not neighbours then
            neighbours = {}
            builtGateLinks[fromKey] = neighbours
        end
        table.insert(neighbours, {x = x, y = y})
    end

    for entry in string.gmatch(raw, "[^;]+") do
        local ax, ay, bx, by = string.match(entry, "^(%-?%d+):(%-?%d+)>(%-?%d+):(%-?%d+)$")
        if ax then
            ax, ay, bx, by = tonumber(ax), tonumber(ay), tonumber(bx), tonumber(by)
            link(skey(ax, ay), bx, by)
            link(skey(bx, by), ax, ay)
        end
    end
end

local function gateNeighbours(x, y)
    local gatesMap = getGatesMap()
    if not gatesMap then return builtGateLinks[skey(x, y)] or {} end

    local key = skey(x, y)
    local cached = gateNeighbourCache[key]

    if not cached then
        cached = {}
        local ok, connected = pcall(gatesMap.getConnectedSectors, gatesMap, {x = x, y = y})
        if ok and connected then
            for _, coord in pairs(connected) do
                table.insert(cached, {x = coord.x, y = coord.y})
            end
        end

        gateNeighbourCache[key] = cached
    end

    local built = builtGateLinks[key]
    if not built then return cached end

    -- the BFS already de-duplicates, so a link that mirrors a seeded gate is harmless
    local merged = {}
    for _, coord in pairs(cached) do table.insert(merged, coord) end
    for _, coord in pairs(built) do table.insert(merged, coord) end

    return merged
end

-- BFS over the gate network from the anchor sector, bounded to MaxGateJumps.
-- Returns the reachable set, a gate-predecessor map (cameFrom[key] points one hop
-- closer to the anchor), and gate depths.
local function computeReachableRegion(owner, originX, originY)
    local reachable = {}
    local cameFrom = {}
    local gateDepth = {}
    local count = 0

    refreshBuiltGateLinks()

    local function blockedByWar(x, y)
        local faction = Galaxy():getControllingFaction(x, y)
        return StockFactoryUtility.isFactionBlockedByWar(owner, faction)
    end

    local function add(x, y)
        local key = skey(x, y)
        if not reachable[key] then
            reachable[key] = true
            count = count + 1
        end
    end

    -- the anchor sector itself is part of the operating region
    add(originX, originY)

    -- bounded gate flood fill up to MaxGateJumps.
    do
        local originKey = skey(originX, originY)
        local gateVisited = {[originKey] = true}
        gateDepth[originKey] = 0
        local frontier = {{x = originX, y = originY}}
        local depth = 0

        while #frontier > 0 and depth < MaxGateJumps do
            depth = depth + 1
            local nextFrontier = {}

            for _, sector in pairs(frontier) do
                for _, coord in pairs(gateNeighbours(sector.x, sector.y)) do
                    local key = skey(coord.x, coord.y)
                    if not gateVisited[key] and not blockedByWar(coord.x, coord.y) then
                        gateVisited[key] = true
                        cameFrom[key] = {x = sector.x, y = sector.y}
                        gateDepth[key] = depth
                        add(coord.x, coord.y)
                        table.insert(nextFrontier, coord)
                        if count >= MaxReachableSectors then
                            return reachable, cameFrom, gateDepth
                        end
                    end
                end
            end

            frontier = nextFrontier
        end
    end

    return reachable, cameFrom, gateDepth
end

-- Reading a station's secured script values deserialises its whole trading state, so the
-- parsed offer is cached briefly and dropped wholesale once it ages out. Every running
-- command remaps in the same simulation tick and would otherwise repeat the same scan.
local stationTradeCache = {}
local stationTradeCacheTime

local function beginStationScan()
    local ok, runtime = pcall(function() return Server().unpausedRuntime end)

    if not ok or not stationTradeCacheTime or runtime - stationTradeCacheTime >= StationTradeCacheSeconds then
        stationTradeCache = {}
        stationTradeCacheTime = ok and runtime or nil
    end
end

local function readStationTrade(entry, cacheKey, tradeScripts)
    local cached = stationTradeCache[cacheKey]
    if cached ~= nil then return cached or nil end

    local scripts = entry:getScripts()
    local secured = entry:getSecuredScriptValues()

    local buys = {}
    local sells = {}
    local hasTrade = false
    local pickupEnabled  = true
    local deliveryEnabled = true

    for i, script in pairs(scripts) do
        local isTrade = false
        for _, tradeScript in pairs(tradeScripts) do
            if string.ends(script, tradeScript) then
                isTrade = true
                break
            end
        end

        if isTrade then
            local values = secured[i] or {}

            -- read stock-hauler opt-out flags (default enabled when absent)
            local pf = values.stockHaulerPickupEnabled
            if pf ~= nil then pickupEnabled  = pickupEnabled  and pf end
            local df = values.stockHaulerDeliveryEnabled
            if df ~= nil then deliveryEnabled = deliveryEnabled and df end

            local soldGoods = values.soldGoods
            if not soldGoods and values.tradingData then soldGoods = values.tradingData.soldGoods end

            local boughtGoods = values.boughtGoods
            if not boughtGoods and values.tradingData then boughtGoods = values.tradingData.boughtGoods end

            for _, good in pairs(soldGoods or {}) do
                sells[good.name] = script
                hasTrade = true
            end

            for _, good in pairs(boughtGoods or {}) do
                buys[good.name] = script
                hasTrade = true
            end

            -- factory.lua stores the production recipe even before first output;
            -- use it so an empty-but-configured factory still appears as a source
            if values.production then
                for _, result in pairs(values.production.results or {}) do
                    if result.name and not sells[result.name] then
                        sells[result.name] = script
                        hasTrade = true
                    end
                end
                for _, garbage in pairs(values.production.garbages or {}) do
                    if garbage.name and not sells[garbage.name] then
                        sells[garbage.name] = script
                        hasTrade = true
                    end
                end
                for _, ingredient in pairs(values.production.ingredients or {}) do
                    if ingredient.name and not buys[ingredient.name] then
                        buys[ingredient.name] = script
                        hasTrade = true
                    end
                end
            end
        end
    end

    local trade = hasTrade and {
        buys = buys,
        sells = sells,
        stockHaulerPickupEnabled   = pickupEnabled,
        stockHaulerDeliveryEnabled = deliveryEnabled,
    } or false

    stationTradeCache[cacheKey] = trade
    return trade or nil
end

-- gathers the owner's stations that trade goods, with their buy/sell trade scripts
local function gatherOwnedTradingStations(owner, reachable, callingPlayer)
    local tradeScripts = TradingUtility.getTradeableScripts()
    local stations = {}
    local seenStations = {}

    beginStationScan()

    local factions = {}
    local factionSeen = {}

    local function addFaction(faction)
        if not faction or factionSeen[faction.index] then return end
        if not StockFactoryUtility.canUseStation(owner, faction.index, callingPlayer) then return end
        factionSeen[faction.index] = true
        table.insert(factions, faction)
    end

    addFaction(owner)

    if owner and owner.isPlayer then
        local player = Player(owner.index)
        if player and player.allianceIndex and player.allianceIndex ~= 0 then
            addFaction(Alliance(player.allianceIndex))
        end
    elseif owner and owner.isAlliance and callingPlayer then
        local player = Player(callingPlayer)
        if player then addFaction(player) end
    end

    for _, faction in pairs(factions) do
        for _, name in pairs({faction:getShipNames()}) do
            local stationKey = faction.index .. ":" .. name
            if seenStations[stationKey] then goto continue end

            local entry = ShipDatabaseEntry(faction.index, name)

            if valid(entry)
                and entry:getAvailability() == ShipAvailability.Available
                and entry:getEntityType() == EntityType.Station then
                local x, y = entry:getCoordinates()
                if reachable and not reachable[skey(x, y)] then
                    goto continue
                end

                local trade = readStationTrade(entry, stationKey, tradeScripts)

                if trade then
                    seenStations[stationKey] = true
                    table.insert(stations, {
                        name = name, factionIndex = faction.index, x = x, y = y,
                        buys = trade.buys, sells = trade.sells,
                        stockHaulerPickupEnabled   = trade.stockHaulerPickupEnabled,
                        stockHaulerDeliveryEnabled = trade.stockHaulerDeliveryEnabled,
                    })
                end
            end

            ::continue::
        end
    end

    return stations
end

function StockFactoryCommand:onAreaAnalysisFinished(results, meta)
    local owner = Galaxy():findFaction(meta.factionIndex)
    local ax, ay = areaAnchor(meta.area)
    if not ax then
        ax, ay = meta.faction:getShipPosition(meta.shipName)
    end

    local reachable, gateCameFrom, gateDepth = computeReachableRegion(owner, ax, ay)
    results.reachable = reachable
    results.gateCameFrom = gateCameFrom
    results.gateDepth = gateDepth
    results.anchor = {x = ax, y = ay}
    results.callingPlayer = meta.callingPlayer

    results.stations = gatherOwnedTradingStations(owner, reachable, meta.callingPlayer)

    -- let the appearance system show the ferry anywhere in its operating region.
    -- each entry is flagged `hidden = true` so the vanilla map highlighter
    -- (MapCommands.highlightReachableSectors) skips it and doesn't clutter the
    -- galaxy map with green squares — while ShipAppearances.findLocation, which
    -- ignores that flag, can still pick these sectors to show the moving ferry.
    -- This mirrors how vanilla's travelcommand.lua hides its route.
    results.reachableCoordinates = results.reachableCoordinates or {}
    local existing = {}
    for _, coord in pairs(results.reachableCoordinates) do
        existing[skey(coord.x, coord.y)] = true
    end
    for key, _ in pairs(reachable) do
        if not existing[key] then
            local sep = string.find(key, ":")
            local kx = tonumber(string.sub(key, 1, sep - 1))
            local ky = tonumber(string.sub(key, sep + 1))
            table.insert(results.reachableCoordinates, {x = kx, y = ky, faction = 0, hidden = true})
        end
    end
end


---------------------------------------------------------------------
-- periodic re-mapping + failure handling
---------------------------------------------------------------------

-- true if at least one good can still be sourced from a reachable owned supplier
function StockFactoryCommand:hasAnyReachableSource(index)
    index = index or buildRouteIndex(self.data.stations, self.config)

    for _, entry in pairs(index) do
        if #entry.targets > 0 and #entry.sources > 0 then
            return true
        end
    end

    return false
end

-- returns true when at least one consumer exists for any eligible good
function StockFactoryCommand:hasAnyConsumer(index)
    index = index or buildRouteIndex(self.data.stations, self.config)

    for _, entry in pairs(index) do
        if #entry.targets > 0 then
            return true
        end
    end

    return false
end

-- re-scan owned stations and recompute the reachable region + gate route from the
-- target, so the command follows the galaxy over time (gates turning hostile,
-- suppliers built or destroyed). Finding nothing is not a failure: the ship stays
-- assigned and idles until a route appears.
function StockFactoryCommand:remapRoute()
    local owner = getParentFaction()
    local anchor = self.data.anchor
    if not owner or not anchor then return end

    if not anchor.x then
        local ship = ShipDatabaseEntry(owner.index, self.shipName)
        if valid(ship) then
            local sx, sy = ship:getCoordinates()
            anchor.x, anchor.y = sx, sy
        else
            return
        end
    end

    local reachable, gateCameFrom, gateDepth = computeReachableRegion(owner, anchor.x, anchor.y)
    self.data.reachable = reachable
    self.data.gateCameFrom = gateCameFrom
    self.data.gateDepth = gateDepth
    self.data.stations = gatherOwnedTradingStations(owner, reachable, self.data.callingPlayer)
end


---------------------------------------------------------------------
-- ferry route queries (which gate the visible ferry should fly through)
---------------------------------------------------------------------

-- runs inside the loaded sector: hands the computed next hop to the ferry appearance
local ferryReplyCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")

function run(faction, shipName, nextX, nextY, useGate, dockFaction, dockName, dockX, dockY, hasDockTarget)
    for _, entity in pairs({Sector():getEntitiesByScriptValue("displayed_faction")}) do
        if entity:getValue("displayed_faction") == faction and entity.name == shipName then
            entity:invokeFunction("ai/stockfactoryferry.lua", "setNextHop", nextX, nextY, useGate, dockFaction, dockName, dockX, dockY, hasDockTarget)
        end
    end
end
]]

-- next gate hop from one sector to another using the saved anchor-rooted BFS tree.
local function nextHopOnTree(cameFrom, anchorX, anchorY, fromX, fromY, toX, toY)
    if fromX == toX and fromY == toY then return nil, nil, false end

    local fromKey = skey(fromX, fromY)
    local ancestors = {}
    local cx, cy = fromX, fromY

    for _ = 1, MaxReachableSectors do
        local key = skey(cx, cy)
        ancestors[key] = true
        if cx == anchorX and cy == anchorY then break end
        local pred = cameFrom[key]
        if not pred then break end
        cx, cy = pred.x, pred.y
    end

    local tx, ty = toX, toY
    local child
    for _ = 1, MaxReachableSectors do
        local key = skey(tx, ty)
        if ancestors[key] then
            if key == fromKey and child then
                return child.x, child.y, true
            end

            local up = cameFrom[fromKey]
            if up then return up.x, up.y, true end
            return nil, nil, false
        end

        local pred = cameFrom[key]
        if not pred then break end
        child = {x = tx, y = ty}
        tx, ty = pred.x, pred.y
    end

    local up = cameFrom[fromKey]
    if up then return up.x, up.y, true end
    return nil, nil, false
end

-- given the sector a ferry is in, return the next sector it should head towards
-- (one gate hop) and whether that hop uses a gate. Hub-and-spoke loop:
-- target -> supplier -> target -> ...
function StockFactoryCommand:computeFerryNextHop(sx, sy)
    local haul = self.data.currentHaul
    if not haul or not haul.source or not haul.target then return nil, nil, false end

    local cameFrom = self.data.gateCameFrom or {}
    local anchor = self.data.anchor or {}
    local destX, destY

    local phase = self.data.phase
    if phase == "haulingToSource" or phase == "transactingPickup" then
        destX, destY = haul.source.x, haul.source.y
    elseif phase == "haulingToTarget" or phase == "transactingDelivery" then
        destX, destY = haul.target.x, haul.target.y
    else
        return nil, nil, false
    end

    return nextHopOnTree(cameFrom, anchor.x, anchor.y, sx, sy, destX, destY)
end

function StockFactoryCommand:getFerryDockTarget()
    local haul = self.data.currentHaul
    if not haul then return nil end

    local phase = self.data.phase
    if phase == "haulingToSource" or phase == "transactingPickup" then
        return haul.source
    elseif phase == "haulingToTarget" or phase == "transactingDelivery" then
        return haul.target
    end

    return nil
end

-- invoked by the ferry appearance to learn which gate to use; replies straight
-- back into the ferry's sector via runSectorCode
function StockFactoryCommand:onFerryRouteRequest(sx, sy)
    local owner = getParentFaction()
    if not owner then return end

    local nextX, nextY, useGate = self:computeFerryNextHop(sx, sy)
    local dockTarget = self:getFerryDockTarget()

    runSectorCode(sx, sy, true, ferryReplyCode, "run", owner.index, self.shipName,
        nextX or 0, nextY or 0, useGate and true or false,
        dockTarget and (dockTarget.factionIndex or 0) or 0,
        dockTarget and dockTarget.name or "",
        dockTarget and dockTarget.x or 0,
        dockTarget and dockTarget.y or 0,
        dockTarget and true or false)
end


---------------------------------------------------------------------
-- descriptors
---------------------------------------------------------------------

function StockFactoryCommand:getDescriptionText()
    local anchor = self.data and self.data.anchor
    if anchor then
        return "The ship is stocking your stations in the anchor region around (${x}:${y}), moving all eligible goods between your own producers and consumers (except any you have added to the ignore list)."%_T, {x = anchor.x, y = anchor.y}
    end

    return "The ship is stocking your stations in the anchor region, moving all eligible goods between your own producers and consumers."%_T
end

function StockFactoryCommand:getStatusMessage()
    if self.data and self.data.phase == "idle" and not self.data.currentHaul then
        return "Waiting for goods to haul /* ship AI status */"%_T
    end

    return "Stocking a sector /* ship AI status */"%_T
end

function StockFactoryCommand:getIcon()
    return "data/textures/icons/crate.png"
end

function StockFactoryCommand:getAreaBounds()
    return {lower = self.area.lower, upper = self.area.upper}
end

function StockFactoryCommand:getRecallError()
    if self.data and self.data.transaction and (self.data.timer or 0) < RecallBlockSeconds then
        return "A station cargo transfer is currently being committed. Try recalling again in a moment."%_T
    end
end

-- A hauler can always be assigned: stations get built, destroyed and reconfigured while the
-- command runs, so an empty route right now says nothing about the next re-scan. The ship
-- idles in the anchor region until a producer/consumer pair shows up.
function StockFactoryCommand:getErrors(ownerIndex, shipName, area, config)
    return
end

function StockFactoryCommand:getAreaSize(ownerIndex, shipName)
    return {x = 1, y = 1} -- one selected anchor sector
end

function StockFactoryCommand:isShipRequiredInArea(ownerIndex, shipName)
    return true
end

function StockFactoryCommand:isAreaFixed(ownerIndex, shipName)
    return false
end

function StockFactoryCommand:getAreaSelectionTooltip(ownerIndex, shipName, area, valid)
    return "Left-Click to select the anchor sector"%_t
end

function StockFactoryCommand:getConfigurableValues(ownerIndex, shipName)
    return {ignoredGoods = {default = {}}}
end

function StockFactoryCommand:getPredictableValues()
    local values = {}
    values.attackChance = {displayName = SimulationUtility.AttackChanceLabelCaption}
    values.producers = {displayName = "Producers in Range"%_t}
    values.consumers = {displayName = "Consumers in Range"%_t}
    return values
end

function StockFactoryCommand:calculatePrediction(ownerIndex, shipName, area, config)
    local prediction = self:getPredictableValues()
    prediction.attackChance = 0

    local ship = ShipDatabaseEntry(ownerIndex, shipName)
    prediction.freeCargoSpace = valid(ship) and ship:getFreeCargoSpace() or 0

    local analysis = area.analysis or {}
    local stations = analysis.stations or {}

    local index = buildRouteIndex(stations, config)

    local producerStations = {}
    local consumerStations = {}
    local numGoodsWithSource = 0
    local numGoodsWithConsumer = 0

    for _, entry in pairs(index) do
        for _, source in pairs(entry.sources) do
            producerStations[(source.factionIndex or 0) .. ":" .. source.name] = true
        end

        if #entry.targets > 0 then
            numGoodsWithConsumer = numGoodsWithConsumer + 1

            for _, target in pairs(entry.targets) do
                consumerStations[(target.factionIndex or 0) .. ":" .. target.name] = true
            end

            -- sources and targets are disjoint, so any of each is already a valid pair
            if #entry.sources > 0 then
                numGoodsWithSource = numGoodsWithSource + 1
            end
        end
    end

    prediction.producers.value = tablelength(producerStations)
    prediction.consumers.value = tablelength(consumerStations)
    prediction.producerCount = prediction.producers.value
    prediction.consumerCount = prediction.consumers.value
    prediction.numGoodsWithSource = numGoodsWithSource
    prediction.numGoodsWithConsumer = numGoodsWithConsumer

    return prediction
end

function StockFactoryCommand:generateAssessmentFromPrediction(prediction, captain, ownerIndex, shipName, area, config)
    local intro = {}
    if prediction.numGoodsWithConsumer > 0 then
        table.insert(intro, "We can stock your anchor region, Commander. I know where to move those goods."%_t)
        table.insert(intro, "Leave the logistics to me. I'll keep those sector stations supplied."%_t)
    else
        table.insert(intro, "I don't see anything to haul in the anchor region yet, Commander. I'll hold position and keep looking."%_t)
        table.insert(intro, "No routes there for now. Assign me anyway and I'll start hauling as soon as your stations line up."%_t)
    end

    local autonomy = {}
    table.insert(autonomy, "While I run this route I have full command of the ship and won't be reachable."%_t)
    table.insert(autonomy, "You won't be able to give me other orders until you call me back."%_t)

    local persistence = {}
    table.insert(persistence, "I'll keep hauling until you recall me or something goes wrong."%_t)
    table.insert(persistence, "If we get attacked I'll warn you, but I won't abandon the route."%_t)

    local rnd = Random(Seed(captain.name))
    return {
        randomEntry(rnd, intro),
        randomEntry(rnd, autonomy),
        randomEntry(rnd, persistence),
    }
end


---------------------------------------------------------------------
-- client UI
---------------------------------------------------------------------

function StockFactoryCommand:buildUI(startPressedCallback, changeAreaPressedCallback, recallPressedCallback, configChangedCallback)
    local ui = {}
    ui.orderName = "Stock Factory"%_t
    ui.icon = StockFactoryCommand:getIcon()

    local size = vec2(700, 780)

    ui.window = GalaxyMap():createWindow(Rect(size))
    ui.window.caption = "Stock Factory"%_t

    local settings = {areaHeight = 110, configHeight = 180, hideEscortUI = true}
    ui.commonUI = SimulationUtility.buildCommandUI(ui.window, startPressedCallback, changeAreaPressedCallback, recallPressedCallback, configChangedCallback, settings)

    -- brief "how it works" description, shown in the top-right panel (the space
    -- normally used by the escort UI, which this command hides)
    local descRect = ui.commonUI.escortRect
    ui.window:createFrame(descRect)
    local descOrganizer = UIOrganizer(descRect)
    descOrganizer.margin = 6
    ui.descriptionField = ui.window:createTextField(descOrganizer.inner, "")
    ui.descriptionField.font = FontType.Normal
    ui.descriptionField.fontSize = 12
    ui.descriptionField.fontColor = ColorRGB(0.7, 0.7, 0.7)
    ui.descriptionField.padding = 4
    ui.descriptionField.text =
        "Anchors to one sector and operates in that sector plus sectors up to 5 gate jumps away."%_t .. "\n\n" ..
        "The ship automatically hauls all eligible goods it can find source-target pairs for."%_t .. "\n\n" ..
        "It never hauls more than a consumer station needs, and never takes a good from a station that also buys it.\n\nUse the toggle buttons on station buy/sell tabs to exclude individual stations."%_t

    -- config: anchor sector and goods denylist
    local configRect = ui.commonUI.configRect
    local vlist = UIVerticalLister(configRect, 8, 0)

    local headerRect = vlist:nextRect(20)
    local headerSplit = UIVerticalSplitter(headerRect, 8, 0, 0.35)
    ui.window:createLabel(headerSplit.left, "Anchor Sector:"%_t, 13)
    ui.anchorSectorLabel = ui.window:createLabel(headerSplit.right, ""%_t, 13)
    ui.anchorSectorLabel:setCenterAligned()

    ui.window:createLabel(vlist:nextRect(18), "Ignored Goods:"%_t, 13)

    local editorRect = vlist:nextRect(28)
    local editorSplit = UIVerticalSplitter(editorRect, 6, 0, 0.82)
    ui.goodCombo = ui.window:createValueComboBox(editorSplit.left, "")
    ui.goodCombo.height = 26

    local buttonSplit = UIVerticalSplitter(editorSplit.right, 4, 0, 0.5)
    ui.addIgnoredGoodButton = ui.window:createButton(buttonSplit.left, "", "stockFactoryAddIgnoredGood")
    ui.addIgnoredGoodButton.icon = "data/textures/icons/plus.png"
    ui.addIgnoredGoodButton.tooltip = "Ignore the selected good."%_t
    ui.removeIgnoredGoodButton = ui.window:createButton(buttonSplit.right, "", "stockFactoryRemoveIgnoredGood")
    ui.removeIgnoredGoodButton.icon = "data/textures/icons/minus.png"
    ui.removeIgnoredGoodButton.tooltip = "Haul the selected ignored good again."%_t

    ui.ignoredGoodsList = ui.window:createListBox(vlist:nextRect(82))
    ui.ignoredGoodsList.rowHeight = 20
    ui.ignoredGoods = {}

    ui.refreshGoods = function(self, area, config)
        self.ignoredGoods = {}
        local configuredGoods = config and config.ignoredGoods
        if type(configuredGoods) ~= "table" then configuredGoods = {} end
        for name, ignored in pairs(configuredGoods) do
            if ignored then self.ignoredGoods[name] = true end
        end

        local available = {}
        local stations = area and area.analysis and area.analysis.stations or {}
        for name, _ in pairs(allStationGoods(stations)) do
            if not self.ignoredGoods[name] then table.insert(available, name) end
        end
        table.sort(available, function(a, b) return goodDisplayName(a, 1) < goodDisplayName(b, 1) end)

        self.goodCombo:clear()
        self.goodCombo:addEntry("", "")
        for _, name in pairs(available) do
            self.goodCombo:addEntry(name, goodDisplayName(name, 1))
        end
        self.goodCombo:setSelectedValueNoCallback("")

        local ignored = {}
        for name, _ in pairs(self.ignoredGoods) do table.insert(ignored, name) end
        table.sort(ignored, function(a, b) return goodDisplayName(a, 1) < goodDisplayName(b, 1) end)

        self.ignoredGoodsList:clear()
        for _, name in pairs(ignored) do
            self.ignoredGoodsList:addEntry(goodDisplayName(name, 1), name)
        end
    end

    self.mapCommands.stockFactoryAddIgnoredGood = function()
        local name = ui.goodCombo.selectedValue
        if not name or name == "" then return end

        ui.ignoredGoods[name] = true
        ui:refreshGoods(ui.currentArea, {ignoredGoods = ui.ignoredGoods})
        self.mapCommands[configChangedCallback]()
    end

    self.mapCommands.stockFactoryRemoveIgnoredGood = function()
        local name = ui.ignoredGoodsList.selectedValue
        if not name or name == "" then return end

        ui.ignoredGoods[name] = nil
        ui:refreshGoods(ui.currentArea, {ignoredGoods = ui.ignoredGoods})
        self.mapCommands[configChangedCallback]()
    end

    -- prediction panel
    local predictable = self:getPredictableValues()
    local plist = UIVerticalLister(ui.commonUI.predictionRect, 5, 0)
    plist:nextRect(20)

    local row = UIVerticalSplitter(plist:nextRect(15), 5, 0, 0.65)
    local label = ui.window:createLabel(row.left, predictable.attackChance.displayName .. ":", 12)
    label.tooltip = SimulationUtility.AttackChanceLabelTooltip
    ui.commonUI.attackChanceLabel = ui.window:createLabel(row.right, "", 12)
    ui.commonUI.attackChanceLabel:setCenterAligned()

    local row = UIVerticalSplitter(plist:nextRect(15), 5, 0, 0.65)
    ui.window:createLabel(row.left, "Free Cargo Space:"%_t, 12)
    ui.cargoSpaceLabel = ui.window:createLabel(row.right, "", 12)
    ui.cargoSpaceLabel:setCenterAligned()

    local row = UIVerticalSplitter(plist:nextRect(15), 5, 0, 0.65)
    ui.window:createLabel(row.left, predictable.producers.displayName .. ":", 12)
    ui.producersLabel = ui.window:createLabel(row.right, "", 12)
    ui.producersLabel:setCenterAligned()

    local row = UIVerticalSplitter(plist:nextRect(15), 5, 0, 0.65)
    ui.window:createLabel(row.left, predictable.consumers.displayName .. ":", 12)
    ui.consumersLabel = ui.window:createLabel(row.right, "", 12)
    ui.consumersLabel:setCenterAligned()

    local row = UIVerticalSplitter(plist:nextRect(15), 5, 0, 0.65)
    ui.window:createLabel(row.left, "Runtime:"%_t, 12)
    local runtimeLabel = ui.window:createLabel(row.right, "Indefinite"%_t, 12)
    runtimeLabel:setCenterAligned()

    ---------------------------------------------------------------
    -- ui methods
    ---------------------------------------------------------------

    ui.clear = function(self, shipName)
        self.commonUI:clear(shipName)
        self.anchorSectorLabel.caption = ""
        self.goodCombo:clear()
        self.ignoredGoodsList:clear()
        self.ignoredGoods = {}
        self.currentArea = nil
    end

    ui.refreshInputs = function(self, ownerIndex, shipName, area, config)
        self.currentArea = area
        local ax, ay = areaAnchor(area)
        if ax then
            -- \s(x:y) is chat/description markup; a Label renders it literally
            self.anchorSectorLabel.caption = "(" .. ax .. ":" .. ay .. ")"
        else
            self.anchorSectorLabel.caption = ""
        end

        self:refreshGoods(area, config or {ignoredGoods = self.ignoredGoods})
    end

    ui.refresh = function(self, ownerIndex, shipName, area, config)
        self.commonUI:refresh(ownerIndex, shipName, area, config)

        if not config then
            self:refreshInputs(ownerIndex, shipName, area, {ignoredGoods = {}})
            config = self:buildConfig()
        else
            self:refreshInputs(ownerIndex, shipName, area, config)
        end

        self:refreshPredictions(ownerIndex, shipName, area, config)
    end

    ui.refreshPredictions = function(self, ownerIndex, shipName, area, config)
        self:refreshInputs(ownerIndex, shipName, area, config)

        local prediction = StockFactoryCommand:calculatePrediction(ownerIndex, shipName, area, config)
        self:displayPrediction(prediction, config, ownerIndex)

        self.commonUI:refreshPredictions(ownerIndex, shipName, area, config, StockFactoryCommand, prediction)
        -- no minimum config required; command can start with an empty ignore list
    end

    ui.displayPrediction = function(self, prediction, config, ownerIndex)
        self.cargoSpaceLabel.caption = math.floor(prediction.freeCargoSpace or 0)
        self.producersLabel.caption = tostring(prediction.producerCount or 0)
        self.consumersLabel.caption = tostring(prediction.consumerCount or 0)
        self.commonUI:setAttackChance(prediction.attackChance or 0)
    end

    ui.buildConfig = function(self)
        local config = {}
        config.escorts = self.commonUI.escortUI:buildConfig()
        config.ignoredGoods = {}
        for name, ignored in pairs(self.ignoredGoods or {}) do
            if ignored then config.ignoredGoods[name] = true end
        end
        return config
    end

    ui.displayConfig = function(self, config, ownerIndex)
        self:refreshGoods(self.currentArea, config)
    end

    ui.setActive = function(self, active, description)
        self.commonUI:setActive(active, description)
        self.goodCombo.active = active
        self.addIgnoredGoodButton.active = active
        self.removeIgnoredGoodButton.active = active
    end

    ui.onWindowClosed = function(self)
    end

    return ui
end


return setmetatable({new = new}, {__call = function(_, ...) return new(...) end})
