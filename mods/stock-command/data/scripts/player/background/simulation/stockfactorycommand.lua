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

-- How long the ferry spends flying a load out to the consumer. The goods have already
-- changed hands by the time it sets off; the leg is what stops one hauler from working a
-- whole region in a single tick. Whole minutes only: the background simulation ticks once a
-- minute, so anything else just rounds up to one.
local MinTravelMinutes = 3
local MaxTravelMinutes = 5

-- Tail of the leg during which the ferry appearance is placed at the consumer, so a watching
-- player sees it fly in and dock.
local ApproachSeconds = 120

-- Upper bound on how long the ferry patrols a transit sector before moving on. It has to
-- vacate the single appearance slot in time for the delivery approach.
local MaxTransitLinger = 60

-- safety cap so the gate-jump flood fill can never run away
local MaxReachableSectors = 400

-- how often (seconds) the command re-scans reachable suppliers and the gate route
local RemapInterval = 5 * 60
local CommandLeaseKey = "stock_factory_command_lease"

-- How long to wait for an asynchronous sector job before giving up on the run. Goods only
-- ever live in a station's cargo bay, so an abandoned transfer strands nothing.
local TransactionTimeout = 300

-- Sector loading is asynchronous and querySectors polls once per command update, i.e. once
-- per background-simulation tick (Simulation.getUpdateInterval() == 60). This MUST stay
-- above that interval: a shorter keep expires between two polls, so the sector is never
-- observed loaded and the haul retries until it is abandoned.
local SectorKeepSeconds = 90

-- Window in which every command planning in the same simulation tick shares one empire-wide
-- station scan. It is measured against real server runtime, but a tick is
-- Simulation.getUpdateInterval() real seconds -- 60/SpeedUp -- so a fixed number of seconds
-- would let the scan survive from one tick into the next on a sped-up galaxy. Expressed as a
-- fraction of the tick instead, it stays shared within one pass over the command list and
-- never across two, whatever speed the galaxy runs at.
local StationTradeCacheTickFraction = 1 / 6

-- used only if the simulation cannot be asked; matches its own SpeedUp = 1 interval
local DefaultTickSeconds = 60

-- a committing transfer only blocks recall for this long, so a lost sector reply can
-- never strand the ship (Simulation.forceRecall silently aborts on a recall error)
local RecallBlockSeconds = 30

-- A haul is sized from station data that can be a few seconds old, so a transfer can still
-- come up short. Nothing travelled to find that out, so the ship just picks another pair. The
-- background simulation ticks once a minute, so in practice this means "on the next tick".
local FailedHaulRetrySeconds = 15

-- How long a hauler waits before looking again once its region has nothing worth moving.
local DryRegionRetrySeconds = 120

-- How this one ship ranks the loads it could move. One setting per command, chosen by the
-- player when the ship is assigned. Numbers, so the command framework can clamp the value for
-- us (see getConfigurableValues).
--
-- Every hauler plans from the same station data, so a fleet that all share one setting will
-- all reach for the same pair. That is the player's dial, not ours: giving haulers different
-- settings is what spreads a fleet across the region, and the default asks for nothing in
-- particular so an unconfigured fleet spreads out on its own.
local HaulPriority = {
    Random        = 1,
    HighestValue  = 2,
    HighestVolume = 3,
    LowestValue   = 4,
    LowestVolume  = 5,
}

-- Dropdown labels, in the order the dropdown lists them.
local HaulPriorityNames = {
    [1] = "No preference"%_t,
    [2] = "Highest total value"%_t,
    [3] = "Highest total volume"%_t,
    [4] = "Lowest total value"%_t,
    [5] = "Lowest total volume"%_t,
}


---------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------

-- A good may only be ferried if it exists, isn't stolen or illegal, and takes up space --
-- every haul is sized by dividing cargo room by the good's size, so a zero is not a good.
local function isGoodEligible(name)
    local good = goods[name]
    if not good then return false end
    if good.stolen or good.illegal then return false end
    return (good.size or 0) > 0
end

local function skey(x, y)
    return x .. ":" .. y
end

-- One pass over the stations yields, per good, the stations that can receive it and the
-- stations that can supply it. A target has to buy the good and a source must not, so the
-- two lists are always disjoint.
local function buildRouteIndex(stations)
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
                if isGoodEligible(good) then
                    table.insert(entryFor(good).targets, st)
                end
            end
        end

        if st.stockHaulerPickupEnabled ~= false then
            for good, _ in pairs(st.sells or {}) do
                if isGoodEligible(good) and not (st.buys and st.buys[good]) then
                    table.insert(entryFor(good).sources, st)
                end
            end
        end
    end

    return index
end


---------------------------------------------------------------------
-- haul candidates
---------------------------------------------------------------------
--
-- Everything a haul needs in order to be sized already lives in the station database
-- entries, which read without loading a single sector. That is what lets a hauler cost every
-- producer/consumer pair in its region before it commits to one, instead of guessing a pair
-- and spending a travel leg discovering the producer was empty.

-- units of `good` in the station's bay. Cargo is keyed by exact trading good, so the stolen
-- and illegal variants of a good are deliberately not counted towards the clean one.
local function stationStock(station, good)
    return (station.stock or {})[good] or 0
end

-- Mirrors TradingManager:getMaxStock. A station's quota for one good is its whole bay split
-- across its trade slots, so it says nothing about the space actually left in that bay.
local function stationQuota(station, size)
    local space = station.baySize or 0
    local slots = station.tradeSlots or 0
    if slots > 0 then space = space / slots end

    if space / size > 100 then
        return math.min(50000, math.floor(space / size / 100 + 0.5) * 100)
    end

    return math.floor(space / size)
end

-- how many units the consumer can still take: capped by its quota for the good and by the
-- room physically left in its bay, which the quota says nothing about
local function stationRoom(station, good, size)
    local room = stationQuota(station, size) - stationStock(station, good)

    local free = station.freeSpace or -1
    if free >= 0 then room = math.min(room, math.floor(free / size)) end

    return math.max(0, room)
end

-- Every producer/consumer pair that would move something right now, sized the way the
-- transfer will size it. A pair that would move nothing is simply absent, which is why the
-- command needs no memory of what came up empty last time.
local function collectCandidates(stations, shipSpace)
    local candidates = {}

    for good, entry in pairs(buildRouteIndex(stations)) do
        local size = goods[good].size
        local shipUnits = math.floor(shipSpace / size)

        for _, source in pairs(entry.sources) do
            local available = math.min(stationStock(source, good), shipUnits)

            for _, target in pairs(entry.targets) do
                local amount = math.min(available, stationRoom(target, good, size))
                if amount > 0 then
                    table.insert(candidates, {good = good, source = source, target = target, amount = amount})
                end
            end
        end
    end

    return candidates
end

-- What this ship was told to reach for first. Cheapest and smallest are the same rankings
-- negated, so one score covers all four ordered modes; Random scores nothing and is drawn
-- flat instead, which is the only way every pair gets the same chance.
local function haulScore(candidate, priority)
    local good = goods[candidate.good]

    if priority == HaulPriority.HighestValue  then return  candidate.amount * good.price end
    if priority == HaulPriority.LowestValue   then return -candidate.amount * good.price end
    if priority == HaulPriority.HighestVolume then return  candidate.amount * good.size end
    if priority == HaulPriority.LowestVolume  then return -candidate.amount * good.size end

    return 0
end

-- The best-scoring load, with exact ties broken at random rather than by table order.
--
-- Ties are common and they matter: the hauler's own hold is usually the binding cap, so every
-- route carrying the same good scores identically. Every hauler in a fleet plans from the
-- same snapshot in the same tick, so settling ties by iteration order would hand all of them
-- the same route. Drawing from the tied set instead spreads them over routes the player's own
-- criterion calls equally good -- a lower-scoring load is still never chosen.
local function pickHaul(candidates, priority)
    if #candidates == 0 then return nil end

    if priority == HaulPriority.Random then
        return candidates[random():getInt(1, #candidates)]
    end

    local best, bestScore, tied = candidates[1], haulScore(candidates[1], priority), 1

    for i = 2, #candidates do
        local score = haulScore(candidates[i], priority)

        if score > bestScore then
            best, bestScore, tied = candidates[i], score, 1
        elseif score == bestScore then
            -- reservoir sample, so each of the tied routes is equally likely
            tied = tied + 1
            if random():getInt(1, tied) == 1 then best = candidates[i] end
        end
    end

    return best
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
    config.priority = tonumber(config.priority) or HaulPriority.Random

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
    self.data.callingPlayer = analysis.callingPlayer
    self.config = self.config or {}
    self.config.priority = tonumber(self.config.priority) or HaulPriority.Random

    self.data.phase = "idle"
    self.data.timer = 0
    self.data.rescanCooldown = 0
    self.data.remapCooldown = RemapInterval
    self.data.nextTransactionId = 0
    self.data.transaction = nil
    self.data.transferProtocolVersion = 3
    self.data.commandToken = tostring(random():createSeed()) .. ":" .. tostring(random():createSeed())

    local owner = getParentFaction()
    local entry = ShipDatabaseEntry(owner.index, self.shipName)
    entry:setScriptValue(CommandLeaseKey, self.data.commandToken)
    entry:setStatusMessage("Stocking a sector"%_T)
end

-- The lease is what the asynchronous sector jobs check before they touch any cargo. Writing
-- it in onStart is not enough: the ship is still a live entity in its sector then, and the
-- entity's own values overwrite the database entry when it drops into background simulation
-- (see the ShipDatabaseEntry docs). update() only ever runs once the ship is in the
-- background, so the lease is re-asserted from there and verified by reading it back.
function StockFactoryCommand:ensureCommandLease()
    local owner = getParentFaction()
    if not owner or not self.data.commandToken then return false end

    local entry = ShipDatabaseEntry(owner.index, self.shipName)
    if not valid(entry) then return false end

    if entry:getScriptValue(CommandLeaseKey) ~= self.data.commandToken then
        entry:setScriptValue(CommandLeaseKey, self.data.commandToken)

        if entry:getScriptValue(CommandLeaseKey) ~= self.data.commandToken then
            if not self.data.reportedLeaseFailure then
                self.data.reportedLeaseFailure = true
                print(string.format("StockFactory: '%s' cannot hold a command lease - transfers will never run",
                    tostring(self.shipName)))
            end
            return false
        end
    end

    self.data.reportedLeaseFailure = nil
    return true
end

function StockFactoryCommand:update(timeStep)
    if self.finishOnNextUpdate then
        self:finish()
        return
    end

    self:ensureCommandLease()

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

    if self.data.phase == "travelling" then
        local haul = self.data.currentHaul
        if haul and self.data.timer < (haul.travelTime or 0) then return end

        -- the load changed hands before the leg even started, so arriving just frees the ship
        self.data.currentHaul = nil
        self.data.phase = "idle"
        self.data.timer = 0
    end

    if self.data.phase == "idle" then
        -- decremented before it is tested, so a cooldown shorter than one tick costs exactly
        -- one tick rather than two
        self.data.rescanCooldown = (self.data.rescanCooldown or 0) - timeStep
        if self.data.rescanCooldown > 0 then return end

        self:planNextHaul()

    elseif self.data.phase == "transferring" then
        -- waiting on the asynchronous sector jobs. One timeout covers both stalls there are:
        -- a sector that never loads, and a job whose reply never arrives.
        if self.data.timer >= TransactionTimeout then
            local tr = self.data.transaction or {}
            print(string.format("StockFactory: '%s' transfer timeout - transaction #%s stage '%s', good '%s'",
                tostring(self.shipName), tostring(tr.id), tostring(tr.stage), tostring(tr.good)))

            self:abandonTransfer(FailedHaulRetrySeconds)
        elseif not self.data.transaction then
            -- both sectors have to be in memory before anything can move; keep asking
            self:beginTransfer()
        end
    end
end

-- Drops an in-flight transfer and goes looking for another run. Used when a queued
-- runSectorCode job can no longer answer -- it timed out, or the server restarted and took
-- the queue with it.
function StockFactoryCommand:abandonTransfer(cooldown)
    self.data.transaction = nil
    self.data.currentHaul = nil
    self.data.phase = "idle"
    self.data.timer = 0
    self.data.rescanCooldown = cooldown or 0
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
    self.config.priority = tonumber(self.config.priority) or HaulPriority.Random
    self.data.nextTransactionId = self.data.nextTransactionId or 0

    if self.data.transferProtocolVersion == 3 and self.data.commandToken then
        local owner = getParentFaction()
        local entry = ShipDatabaseEntry(owner.index, self.shipName)
        if valid(entry) then entry:setScriptValue(CommandLeaseKey, self.data.commandToken) end

        -- queued sector jobs don't survive a restart, so an in-flight transfer would
        -- otherwise sit until it times out
        if self.data.transaction then self:abandonTransfer(0) end
        return
    end

    -- Older protocols parked goods on the ship between two stations. Those can't be
    -- reconciled here, so the cargo is handed to the recovery script and the ship recalled.
    local haul = self.data.currentHaul
    local amount = haul and (haul.carriedAmount or 0) or 0
    self.data.transaction = nil
    self.data.transferProtocolVersion = 3

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

-- travel time for one leg of a run
function StockFactoryCommand:estimateTravelTime()
    return random():getInt(MinTravelMinutes, MaxTravelMinutes) * 60
end

-- Costs every pair the region can offer and commits to one of the best. The transfer starts
-- straight away: a pair that turns out to be worth nothing costs seconds, not a travel leg,
-- which is why nothing about it needs remembering.
function StockFactoryCommand:planNextHaul()
    local owner = getParentFaction()
    if not owner then return end

    -- station stock is what a plan is made of, so it is re-read here rather than left to the
    -- much slower route re-map. The scan is shared by every command running in the same tick.
    self:refreshStations()

    local ship = ShipDatabaseEntry(owner.index, self.shipName)
    local shipSpace = valid(ship) and ship:getFreeCargoSpace() or 0

    local haul = pickHaul(collectCandidates(self.data.stations, shipSpace), self.config.priority)

    if not haul then
        -- nothing worth moving right now: stay assigned, idle near the anchor, look again later
        self.data.phase = "idle"
        self.data.rescanCooldown = DryRegionRetrySeconds
        self:reportNoRoutes()
        return
    end

    self.data.currentHaul = {
        good = haul.good,
        amount = haul.amount,
        source = {
            name = haul.source.name,
            factionIndex = haul.source.factionIndex,
            x = haul.source.x,
            y = haul.source.y,
            script = haul.source.sells[haul.good],
        },
        target = {
            name = haul.target.name,
            factionIndex = haul.target.factionIndex,
            x = haul.target.x,
            y = haul.target.y,
            script = haul.target.buys[haul.good],
        },
    }

    self.data.reportedNoRoutes = nil
    self.data.phase = "transferring"
    self.data.timer = 0
    self:beginTransfer()
end

-- Explains once (per dry spell) why the hauler is sitting still, so "nothing happens" is
-- never silent. Reset as soon as a haul is planned.
function StockFactoryCommand:reportNoRoutes()
    if self.data.reportedNoRoutes then return end
    self.data.reportedNoRoutes = true

    local numStations = 0
    for _ in pairs(self.data.stations or {}) do numStations = numStations + 1 end

    local numConsumers, numPaired = 0, 0
    for _, entry in pairs(buildRouteIndex(self.data.stations)) do
        if #entry.targets > 0 then
            numConsumers = numConsumers + 1
            -- sources and targets are disjoint per good, so any of each is already a pair
            if #entry.sources > 0 then numPaired = numPaired + 1 end
        end
    end

    print(string.format("StockFactory: '%s' idle - %i reachable owned trading stations, %i goods with a consumer, %i of those with a producer",
        tostring(self.shipName), numStations, numConsumers, numPaired))

    local owner = getParentFaction()
    if not owner then return end

    if numStations == 0 then
        owner:sendChatMessage(self.shipName, ChatMessageType.Information, "Commander, I can't reach any of our trading stations from the anchor sector. Waiting here."%_T)
    elseif numConsumers == 0 then
        owner:sendChatMessage(self.shipName, ChatMessageType.Information, "Commander, none of the %1% stations I can reach buys anything I'm allowed to haul. Waiting here."%_T, numStations)
    elseif numPaired == 0 then
        owner:sendChatMessage(self.shipName, ChatMessageType.Information, "Commander, I can reach %1% stations but found no producer for what they need. Waiting here."%_T, numStations)
    else
        owner:sendChatMessage(self.shipName, ChatMessageType.Information, "Commander, our %1% stations in range have nothing to spare for each other right now. Waiting here."%_T, numStations)
    end
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

-- Goods never sit on the ship: they are taken out of the source station's bay and pushed
-- into the target station's bay within the same few frames, while both sectors are held in
-- memory. This mirrors vanilla's SupplyCommand.
local removeCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("stringutility")
local StockFactoryUtility = include("stockfactoryutility")
]] .. goodsHelperCode .. [[

function run(faction, shipName, stationFaction, stationName, goodName, amount, commandToken, transactionId, callingPlayer)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then
        print(string.format("StockFactory: pickup for '%s' aborted - no ship database entry", tostring(shipName)))
        return
    end
    if not StockFactoryUtility.hasCommandLease(ship, commandToken) then
        print(string.format("StockFactory: pickup for '%s' aborted - lease mismatch (entry '%s', command '%s')",
            tostring(shipName), tostring(ship:getScriptValue("stock_factory_command_lease")), tostring(commandToken)))
        return
    end

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

    local cargoBay = CargoBay(station)
    local exact = tradingGood(good)
    local before = cargoBay:getNumCargos(exact)
    cargoBay:removeCargo(exact, amount)
    local removed = before - cargoBay:getNumCargos(exact)

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
    if not valid(ship) then
        print(string.format("StockFactory: delivery for '%s' aborted - no ship database entry", tostring(shipName)))
        return
    end
    if not StockFactoryUtility.hasCommandLease(ship, commandToken) then
        print(string.format("StockFactory: delivery for '%s' aborted - lease mismatch (entry '%s', command '%s')",
            tostring(shipName), tostring(ship:getScriptValue("stock_factory_command_lease")), tostring(commandToken)))
        return
    end

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

    -- the bay can fill up between the plan and this frame, so only what it really took
    -- counts as delivered
    local cargoBay = CargoBay(station)
    local exact = tradingGood(good)
    local before = cargoBay:getNumCargos(exact)
    cargoBay:addCargo(exact, amount)
    local added = cargoBay:getNumCargos(exact) - before

    invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "onGoodsDelivered", commandToken, transactionId, goodName, added, amount - added)
end
]]

-- Whatever the consumer could not take is pushed straight back into the producer's bay, so
-- a short delivery normally moves nothing anywhere. The producer's bay is not guaranteed to
-- still have the room it had when the goods left it, though -- it keeps producing, and other
-- haulers keep dropping off -- so what it really takes back is measured the same way the
-- pickup and the delivery measure theirs. Anything it refuses is reported back so the
-- command can stow it on the ship rather than let the engine destroy it.
local returnCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("stringutility")
local StockFactoryUtility = include("stockfactoryutility")
]] .. goodsHelperCode .. [[

function run(faction, shipName, stationFaction, stationName, goodName, amount, commandToken, transactionId)
    local function reply(returned)
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "onGoodsReturned", commandToken, transactionId, goodName, returned, amount - returned)
    end

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
    local good = goods[goodName]
    if not valid(station) or not good then
        print(string.format("StockFactory: '%s' could not give %i units of %s back to '%s' - station gone or unknown cargo type",
            tostring(shipName), amount, tostring(goodName), tostring(stationName)))
        reply(0)
        return
    end

    local cargoBay = CargoBay(station)
    local exact = tradingGood(good)
    local before = cargoBay:getNumCargos(exact)
    cargoBay:addCargo(exact, amount)
    local returned = cargoBay:getNumCargos(exact) - before

    if returned < amount then
        print(string.format("StockFactory: '%s' could not give %i units of %s back to '%s' - it took only %i of %i, its bay is full",
            tostring(shipName), amount - returned, tostring(goodName), tostring(stationName), returned, amount))
    end

    reply(returned)
end
]]

-- true once both ends of the run are in memory. Loading is asynchronous, so this is asked
-- again every tick until it answers yes or the run times out.
function StockFactoryCommand:querySectors()
    local haul = self.data.currentHaul
    local t = haul and haul.target
    local s = haul and haul.source
    if not t or not s then return false end

    Galaxy():keepOrGetSector(t.x, t.y, SectorKeepSeconds)
    Galaxy():keepOrGetSector(s.x, s.y, SectorKeepSeconds)

    return Galaxy():sectorLoaded(t.x, t.y) and Galaxy():sectorLoaded(s.x, s.y)
end

function StockFactoryCommand:beginTransfer()
    local haul = self.data.currentHaul
    local owner = getParentFaction()
    if not haul or not owner then
        self.data.phase = "idle"
        return
    end

    local t = haul.target
    local s = haul.source

    if not self:ensureCommandLease() then return end

    if not StockFactoryUtility.canUseStation(owner, t.factionIndex, self.data.callingPlayer)
        or not StockFactoryUtility.canUseStation(owner, s.factionIndex, self.data.callingPlayer) then
        self:setRuntimeError("Commander, I no longer have permission to manage one of the stations on this route."%_T)
        return
    end

    if not t.script or not s.script then
        -- we don't know which scripts trade the good; skip this run
        print(string.format("StockFactory: '%s' dropped %s - no trading script (source '%s' %s, target '%s' %s)",
            tostring(self.shipName), tostring(haul.good),
            tostring(s.name), tostring(s.script), tostring(t.name), tostring(t.script)))

        self:abandonTransfer(FailedHaulRetrySeconds)
        return
    end

    if not self:querySectors() then return end

    self.data.nextTransactionId = (self.data.nextTransactionId or 0) + 1
    self.data.transaction = {
        id = self.data.nextTransactionId,
        stage = "removing",
        good = haul.good,
        delivered = 0,
    }

    runSectorCode(s.x, s.y, true, removeCode, "run", owner.index, self.shipName, s.factionIndex or owner.index, s.name, haul.good, haul.amount, self.data.commandToken, self.data.transaction.id, self.data.callingPlayer)

    print(string.format("StockFactory: '%s' moving #%i - %i units of %s from '%s' (%i:%i) to '%s' (%i:%i)",
        tostring(self.shipName), self.data.transaction.id, haul.amount, tostring(haul.good),
        tostring(s.name), s.x, s.y, tostring(t.name), t.x, t.y))
end

-- Replies arrive from a queued sector job, so they can be stale. Anything that doesn't match
-- the in-flight transaction is dropped -- and logged, because a dropped reply is invisible
-- otherwise and shows up much later as a transfer timeout.
function StockFactoryCommand:acceptReply(commandToken, transactionId, good, stage)
    local transaction = self.data.transaction
    local reason

    if self.data.commandToken ~= commandToken then reason = "lease token changed"
    elseif not transaction then reason = "no transaction in flight"
    elseif not self.data.currentHaul then reason = "no haul in flight"
    elseif transaction.id ~= transactionId then reason = string.format("transaction %i, expected %i", transactionId or -1, transaction.id or -1)
    elseif transaction.good ~= good then reason = string.format("good '%s', expected '%s'", tostring(good), tostring(transaction.good))
    elseif transaction.stage ~= stage then reason = string.format("stage '%s', expected '%s'", tostring(transaction.stage), tostring(stage))
    end

    if reason then
        print(string.format("StockFactory: '%s' dropped a transfer reply - %s", tostring(self.shipName), reason))
        return nil
    end

    return transaction
end

function StockFactoryCommand:onGoodsRemoved(commandToken, transactionId, good, removed)
    local transaction = self:acceptReply(commandToken, transactionId, good, "removing")
    if not transaction then return end

    if (removed or 0) <= 0 then
        -- the producer's bay held less than the plan said; nothing left it, so nothing to undo
        print(string.format("StockFactory: '%s' picked up no %s at '%s' - looking for another pair",
            tostring(self.shipName), tostring(good), tostring(self.data.currentHaul.source.name)))

        self:abandonTransfer(FailedHaulRetrySeconds)
        return
    end

    transaction.stage = "delivering"
    transaction.amount = removed
    self.data.timer = 0

    local owner = getParentFaction()
    local t = self.data.currentHaul.target
    runSectorCode(t.x, t.y, true, addCode, "run", owner.index, self.shipName, t.factionIndex or owner.index, t.name, good, removed, self.data.commandToken, transactionId, self.data.callingPlayer)
end

function StockFactoryCommand:onGoodsDelivered(commandToken, transactionId, good, added, notAdded)
    local transaction = self:acceptReply(commandToken, transactionId, good, "delivering")
    if not transaction then return end

    local haul = self.data.currentHaul
    transaction.delivered = added or 0

    if transaction.delivered > 0 then
        getParentFaction():sendChatMessage("", ChatMessageType.Economy, "(%1%:%2%) %3% transferred %4% %5% from %6% to %7%."%_T,
            haul.target.x, haul.target.y, self.shipName, transaction.delivered, goodDisplayName(good, transaction.delivered),
            haul.source.name, haul.target.name)
    end

    if (notAdded or 0) <= 0 then
        self:finishHaul()
        return
    end

    -- the bay took less than the plan sized the haul for: usually it filled up with something
    -- else in the meantime. The remainder goes straight back where it came from.
    print(string.format("StockFactory: '%s' giving %i units of %s back to '%s' - '%s' only took %i",
        tostring(self.shipName), notAdded, tostring(good), tostring(haul.source.name),
        tostring(haul.target.name), transaction.delivered))

    transaction.stage = "returning"
    self.data.timer = 0

    local owner = getParentFaction()
    local s = haul.source
    runSectorCode(s.x, s.y, true, returnCode, "run", owner.index, self.shipName, s.factionIndex or owner.index, s.name, good, notAdded, self.data.commandToken, transactionId)
end

-- The producer normally takes the remainder straight back. When it can't, the goods have
-- nowhere left to go but the ship's own hold, and a hauler flying around with cargo it cannot
-- put down is not something it can resolve on its own -- so that ends the run for good.
function StockFactoryCommand:onGoodsReturned(commandToken, transactionId, good, returned, lost)
    local transaction = self:acceptReply(commandToken, transactionId, good, "returning")
    if not transaction then return end

    if (lost or 0) <= 0 then
        self:finishHaul()
        return
    end

    self:stowOnShip(good, lost)
    self:setRuntimeError("Commander, %1% wouldn't take %2% %3% back and I'm carrying it. Bringing it home."%_T,
        self.data.currentHaul.source.name, lost, goodDisplayName(good, lost))
end

-- A run that moved something earns its travel leg; one that moved nothing just picks another
-- pair, having cost nothing but a few seconds.
function StockFactoryCommand:finishHaul()
    if (self.data.transaction.delivered or 0) <= 0 then
        self:abandonTransfer(FailedHaulRetrySeconds)
        return
    end

    self.data.currentHaul.travelTime = self:estimateTravelTime()
    self.data.transaction = nil
    self.data.phase = "travelling"
    self.data.timer = 0
end

-- Last resort for goods neither station will hold. The haul was sized against the ship's free
-- space in the first place, so the hold has room for them unless something else filled it.
function StockFactoryCommand:stowOnShip(goodName, amount)
    local good = goods[goodName]
    local entry = ShipDatabaseEntry(getParentFaction().index, self.shipName)
    if not good or not valid(entry) then return end

    local cargo = entry:getCargo()
    local exact = good:good()

    for held, heldAmount in pairs(cargo) do
        if held.name == exact.name and not held.stolen and not held.illegal then
            exact, amount = held, heldAmount + amount
            break
        end
    end

    cargo[exact] = amount
    entry:setCargo(cargo)
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
-- Returns the reachable set and a gate-predecessor map (cameFrom[key] points one hop
-- closer to the anchor).
local function computeReachableRegion(owner, originX, originY)
    local reachable = {}
    local cameFrom = {}
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
                        add(coord.x, coord.y)
                        table.insert(nextFrontier, coord)
                        if count >= MaxReachableSectors then
                            return reachable, cameFrom
                        end
                    end
                end
            end

            frontier = nextFrontier
        end
    end

    return reachable, cameFrom
end

-- Reading a station's secured script values deserialises its whole trading state, so the
-- parsed offer is cached briefly and dropped wholesale once it ages out. Every running
-- command plans in the same simulation tick and would otherwise repeat the same scan.
local stationTradeCache = {}
local stationTradeCacheTime

-- Resolved on every call rather than at load: this module is included by commandfactory.lua,
-- which simulation.lua includes before it declares the Simulation namespace, so the function
-- does not exist yet while this file is being read.
local function stationTradeCacheSeconds()
    local ok, interval = pcall(function() return Simulation.getUpdateInterval() end)
    if not ok or type(interval) ~= "number" or interval <= 0 then interval = DefaultTickSeconds end

    return interval * StationTradeCacheTickFraction
end

local function beginStationScan()
    local ok, runtime = pcall(function() return Server().unpausedRuntime end)

    if not ok or not stationTradeCacheTime or runtime - stationTradeCacheTime >= stationTradeCacheSeconds() then
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
    -- vanilla splits a station's bay evenly across its trade slots, so the offer sizes count
    local tradeSlots = 0

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
                tradeSlots = tradeSlots + 1
                hasTrade = true
            end

            for _, good in pairs(boughtGoods or {}) do
                buys[good.name] = script
                tradeSlots = tradeSlots + 1
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

    -- What is actually in the bay, read straight off the database entry: no sector has to be
    -- loaded for this, which is what lets a haul be sized before the ship commits to it.
    -- Cargo is keyed by exact trading good, so stolen and illegal variants stay uncounted.
    local stock = {}
    local cargo, baySize = entry:getCargo()
    for good, amount in pairs(cargo or {}) do
        if not good.stolen and not good.illegal then
            stock[good.name] = (stock[good.name] or 0) + amount
        end
    end

    local trade = hasTrade and {
        buys = buys,
        sells = sells,
        stock = stock,
        baySize = baySize or 0,
        freeSpace = entry:getFreeCargoSpace() or -1,
        tradeSlots = tradeSlots,
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
                        stock = trade.stock, baySize = trade.baySize,
                        freeSpace = trade.freeSpace, tradeSlots = trade.tradeSlots,
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

    local reachable, gateCameFrom = computeReachableRegion(owner, ax, ay)
    results.reachable = reachable
    results.gateCameFrom = gateCameFrom
    results.anchor = {x = ax, y = ay}
    results.callingPlayer = meta.callingPlayer

    results.stations = gatherOwnedTradingStations(owner, reachable, meta.callingPlayer)

    local numReachable = 0
    for _ in pairs(reachable) do numReachable = numReachable + 1 end
    print(string.format("StockFactory: analysis for '%s' anchored at %i:%i - %i reachable sectors, %i owned trading stations",
        tostring(meta.shipName), ax, ay, numReachable, #results.stations))

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
-- periodic re-mapping
---------------------------------------------------------------------

-- true if at least one good can still be sourced from a reachable owned supplier
function StockFactoryCommand:hasAnyReachableSource()
    for _, entry in pairs(buildRouteIndex(self.data.stations)) do
        if #entry.targets > 0 and #entry.sources > 0 then
            return true
        end
    end

    return false
end

-- Re-reads what the owned stations in range offer and hold. Cheap enough to run before every
-- plan, and shared with every other command that plans in the same tick.
function StockFactoryCommand:refreshStations()
    local owner = getParentFaction()
    if not owner then return end

    self.data.stations = gatherOwnedTradingStations(owner, self.data.reachable, self.data.callingPlayer)
end

-- Recompute the reachable region + gate route from the anchor, so the command follows the
-- galaxy over time (gates turning hostile, suppliers built or destroyed). Finding nothing is
-- not a failure: the ship stays assigned and idles until a route appears.
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

    local reachable, gateCameFrom = computeReachableRegion(owner, anchor.x, anchor.y)
    self.data.reachable = reachable
    self.data.gateCameFrom = gateCameFrom
    self:refreshStations()
end


---------------------------------------------------------------------
-- ferry route queries (which gate the visible ferry should fly through)
---------------------------------------------------------------------

-- runs inside the loaded sector: hands the computed next hop to the ferry appearance
local ferryReplyCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")

function run(faction, shipName, nextX, nextY, useGate, dockFaction, dockName, dockX, dockY, hasDockTarget, loiter, transitLinger)
    for _, entity in pairs({Sector():getEntitiesByScriptValue("displayed_faction")}) do
        if entity:getValue("displayed_faction") == faction and entity.name == shipName then
            entity:invokeFunction("ai/stockfactoryferry.lua", "setNextHop", nextX, nextY, useGate, dockFaction, dockName, dockX, dockY, hasDockTarget, loiter, transitLinger)
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

-- the sectors a ferry passes through going from one sector to another, starting at `from`
local function routePath(cameFrom, anchorX, anchorY, fromX, fromY, toX, toY)
    local path = {{x = fromX, y = fromY}}
    local cx, cy = fromX, fromY

    for _ = 1, MaxGateJumps * 2 + 2 do
        if cx == toX and cy == toY then break end
        local nx, ny = nextHopOnTree(cameFrom, anchorX, anchorY, cx, cy, toX, toY)
        if not nx then break end
        cx, cy = nx, ny
        table.insert(path, {x = cx, y = cy})
    end

    return path
end


---------------------------------------------------------------------
-- ferry visuals
---------------------------------------------------------------------
--
-- The cargo changes hands in the producer's sector, and the ferry flies the load out from
-- there: it is docked at the producer while the transfer resolves, patrols the transit
-- sectors on its gate route, then parks at the consumer for the tail of the leg so a watching
-- player sees it fly in and dock.

-- start of the delivery approach, as an offset into the leg
function StockFactoryCommand:approachStart()
    local haul = self.data.currentHaul
    if not haul then return 0 end

    local legTime = haul.travelTime or 60
    return math.max(legTime * 0.5, legTime - ApproachSeconds)
end

function StockFactoryCommand:isApproaching()
    if self.data.phase ~= "travelling" then return false end
    return (self.data.timer or 0) >= self:approachStart()
end

-- Where the appearance system should place the ferry. Returning nil means "nowhere", which
-- vanilla treats as no appearance this tick.
function StockFactoryCommand:getAppearanceSector()
    local anchor = self.data.anchor or {}
    local haul = self.data.currentHaul

    if not haul or self.data.phase == "idle" then
        if anchor.x then return anchor.x, anchor.y end
        return nil
    end

    if self.data.phase == "transferring" then
        return haul.source.x, haul.source.y
    end

    if self:isApproaching() then
        return haul.target.x, haul.target.y
    end

    -- somewhere along the gate route, advancing with the leg so the trip reads as a trip
    local path = routePath(self.data.gateCameFrom or {}, anchor.x, anchor.y,
        haul.source.x, haul.source.y, haul.target.x, haul.target.y)

    local approach = self:approachStart()
    local progress = approach > 0 and math.min(1, (self.data.timer or 0) / approach) or 0
    local step = math.floor(progress * (#path - 1)) + 1

    local sector = path[math.max(1, math.min(#path, step))]
    return sector.x, sector.y
end

-- given the sector a ferry is in, return the next sector it should head towards
-- (one gate hop) and whether that hop uses a gate
function StockFactoryCommand:computeFerryNextHop(sx, sy)
    local haul = self.data.currentHaul
    if not haul or not haul.source or not haul.target then return nil, nil, false end

    local phase = self.data.phase
    if phase ~= "travelling" and phase ~= "transferring" then return nil, nil, false end

    local cameFrom = self.data.gateCameFrom or {}
    local anchor = self.data.anchor or {}

    local destX, destY = haul.target.x, haul.target.y
    if phase == "transferring" then destX, destY = haul.source.x, haul.source.y end

    return nextHopOnTree(cameFrom, anchor.x, anchor.y, sx, sy, destX, destY)
end

-- The ferry is loading at the producer while the transfer resolves, and unloading at the
-- consumer once it has flown the leg. In between there is nothing to dock with.
function StockFactoryCommand:getFerryDockTarget()
    local haul = self.data.currentHaul
    if not haul then return nil end

    if self.data.phase == "transferring" then return haul.source end
    if self:isApproaching() then return haul.target end

    return nil
end

-- How long the ferry may patrol a transit sector before moving on. It occupies the only
-- appearance slot the ship has, so it must be free again in time for the delivery approach.
function StockFactoryCommand:ferryTransitLinger()
    if self.data.phase ~= "travelling" then return 0 end

    local slack = self:approachStart() - (self.data.timer or 0)
    return math.max(0, math.min(MaxTransitLinger, slack))
end

-- invoked by the ferry appearance to learn which gate to use; replies straight
-- back into the ferry's sector via runSectorCode
function StockFactoryCommand:onFerryRouteRequest(sx, sy)
    local owner = getParentFaction()
    if not owner then return end

    local nextX, nextY, useGate = self:computeFerryNextHop(sx, sy)
    local dockTarget = self:getFerryDockTarget()

    -- with no haul the ship is waiting out its shift at the anchor, not passing through
    local anchor = self.data.anchor or {}
    local loiter = not self.data.currentHaul and sx == anchor.x and sy == anchor.y

    runSectorCode(sx, sy, true, ferryReplyCode, "run", owner.index, self.shipName,
        nextX or 0, nextY or 0, useGate and true or false,
        dockTarget and (dockTarget.factionIndex or 0) or 0,
        dockTarget and dockTarget.name or "",
        dockTarget and dockTarget.x or 0,
        dockTarget and dockTarget.y or 0,
        dockTarget and true or false,
        loiter,
        self:ferryTransitLinger())
end


---------------------------------------------------------------------
-- descriptors
---------------------------------------------------------------------

function StockFactoryCommand:getDescriptionText()
    local anchor = self.data and self.data.anchor
    if anchor then
        return "The ship is stocking your stations in the anchor region around (${x}:${y}), moving goods between your own producers and consumers in the order you asked for."%_T, {x = anchor.x, y = anchor.y}
    end

    return "The ship is stocking your stations in the anchor region, moving goods between your own producers and consumers in the order you asked for."%_T
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
    return {priority = {displayName = "Prioritize"%_t, from = 1, to = 5, default = HaulPriority.Random}}
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

    local index = buildRouteIndex(stations)

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

    local settings = {areaHeight = 110, configHeight = 90, hideEscortUI = true}
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
        "The ship reads what every station in range holds, then moves whichever load its own setting favours. It never hauls more than a consumer needs, and never takes a good from a station that also buys it."%_t .. "\n\n" ..
        "Use the toggle buttons on station buy/sell tabs to exclude individual stations."%_t

    -- config: anchor sector and haul priority
    local configRect = ui.commonUI.configRect
    local vlist = UIVerticalLister(configRect, 8, 0)

    local headerSplit = UIVerticalSplitter(vlist:nextRect(20), 8, 0, 0.35)
    ui.window:createLabel(headerSplit.left, "Anchor Sector:"%_t, 13)
    ui.anchorSectorLabel = ui.window:createLabel(headerSplit.right, ""%_t, 13)
    ui.anchorSectorLabel:setCenterAligned()

    local prioritySplit = UIVerticalSplitter(vlist:nextRect(26), 8, 0, 0.35)
    ui.window:createLabel(prioritySplit.left, "Prioritize:"%_t, 13)
    ui.priorityCombo = ui.window:createValueComboBox(prioritySplit.right, configChangedCallback)
    ui.priorityCombo.tooltip = "Which of the loads it could move this ship should reach for first. Total value is the units moved times the good's base price; total volume is the units moved times the good's cargo volume.\n\nWith no preference it picks at random. Give haulers working the same region different settings and they will stop competing for the same cargo."%_t
    for value = 1, #HaulPriorityNames do
        ui.priorityCombo:addEntry(value, HaulPriorityNames[value])
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
        self.priorityCombo:setSelectedValueNoCallback(HaulPriority.Random)
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

        self.priorityCombo:setSelectedValueNoCallback(tonumber(config and config.priority) or HaulPriority.Random)
    end

    ui.refresh = function(self, ownerIndex, shipName, area, config)
        self.commonUI:refresh(ownerIndex, shipName, area, config)

        self:refreshInputs(ownerIndex, shipName, area, config)
        config = config or self:buildConfig()

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
        return {
            escorts = self.commonUI.escortUI:buildConfig(),
            priority = tonumber(self.priorityCombo.selectedValue) or HaulPriority.Random,
        }
    end

    ui.displayConfig = function(self, config, ownerIndex)
        self.priorityCombo:setSelectedValueNoCallback(tonumber(config and config.priority) or HaulPriority.Random)
    end

    ui.setActive = function(self, active, description)
        self.commonUI:setActive(active, description)
        self.priorityCombo.active = active
    end

    ui.onWindowClosed = function(self)
    end

    return ui
end


-- The sector jobs run in throwaway Lua states and are never called directly, so they are
-- exposed here purely so the tests can load and exercise them.
local sectorCode = {remove = removeCode, add = addCode, returnGoods = returnCode}

return setmetatable({new = new, sectorCode = sectorCode}, {__call = function(_, ...) return new(...) end})
