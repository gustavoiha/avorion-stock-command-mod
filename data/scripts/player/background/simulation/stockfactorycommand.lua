package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/player/background/simulation/?.lua"

local CommandType = include ("commandtype")
local SimulationUtility = include ("simulationutility")
local CaptainUtility = include ("captainutility")
local TradingUtility = include ("tradingutility")
local GatesMap = include ("gatesmap")
include ("utility")
include ("stringutility")
include ("goods")


local StockFactoryCommand = {}
StockFactoryCommand.__index = StockFactoryCommand
StockFactoryCommand.type = CommandType.StockFactory

-- how many goods can be shown in the config checklist
local MaxGoodCheckboxes = 12

-- how many sectors to scan around the target (Euclidean radius) for the "2.5
-- sectors away" rule, and how many consecutive gate jumps for the alternative rule
local SectorRadius = 2.5
local MaxGateJumps = 3

-- safety cap so the gate-jump flood fill can never run away
local MaxReachableSectors = 400


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

local function skey(x, y)
    return x .. ":" .. y
end

local function goodDisplayName(name, amount)
    local good = goods[name]
    if good then
        local ok, result = pcall(function() return good:good():displayName(amount or 2) end)
        if ok and result and result ~= "" then return result end
    end
    return name
end


---------------------------------------------------------------------
-- construction
---------------------------------------------------------------------

-- all commands need this kind of "new" to function within the bg simulation framework
-- it must be possible to call the command without any parameters to access some functionality
local function new(ship, area, config)
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
    if not self.config or not self.config.target then
        return "We need a station to stock."%_T
    end

    if not self.config.goods or #self.config.goods == 0 then
        return "We need at least one good to stock."%_T
    end
end

function StockFactoryCommand:onStart()
    local owner = getParentFaction()

    local target = ShipDatabaseEntry(owner.index, self.config.target)
    if not valid(target) or target:getEntityType() ~= EntityType.Station then
        return "The station we were supposed to stock doesn't exist any more."%_T
    end

    local tx, ty = target:getCoordinates()
    self.data.target = {name = self.config.target, x = tx, y = ty}

    -- cache the station list + reachable region that was computed during the area
    -- analysis, so the ferry logic has it available (and it's saved to database)
    local analysis = self.area and self.area.analysis or {}
    self.data.stations = analysis.stations or {}
    self.data.reachable = analysis.reachable or {}

    self.data.phase = "idle"
    self.data.timer = 0
    self.data.rescanCooldown = 0
    self.data.cursor = 0
    self.data.sourceCursor = 0

    local entry = ShipDatabaseEntry(owner.index, self.shipName)
    entry:setStatusMessage("Stocking a station"%_T)
end

function StockFactoryCommand:update(timeStep)
    if self.finishOnNextUpdate then
        self:finish()
        return
    end

    self.data.timer = (self.data.timer or 0) + timeStep

    local phase = self.data.phase or "idle"

    if phase == "idle" then
        if (self.data.rescanCooldown or 0) > 0 then
            self.data.rescanCooldown = self.data.rescanCooldown - timeStep
            return
        end
        self:planNextHaul()

    elseif phase == "hauling" then
        local haul = self.data.currentHaul
        if not haul then
            self.data.phase = "idle"
            return
        end

        if self.data.timer >= (haul.travelTime or 60) then
            self:beginTransaction()
        end

    elseif phase == "transacting" then
        -- waiting for the asynchronous sector probes / transfers to report back.
        -- if they never do (e.g. a sector got unloaded), recover after a while.
        if self.data.timer >= 300 then
            self.transaction = nil
            self.data.currentHaul = nil
            self.data.phase = "idle"
            self.data.rescanCooldown = 30
        end
    end
end

function StockFactoryCommand:onRecall()
end

function StockFactoryCommand:onFinish()
end

function StockFactoryCommand:onSecure()
end

function StockFactoryCommand:onRestore()
end

function StockFactoryCommand:onAttacked(attackerFaction, x, y)
    -- intentionally empty: the ship keeps its command when attacked
end


---------------------------------------------------------------------
-- ferry planning
---------------------------------------------------------------------

-- returns the trade script the target station uses to buy the given good
function StockFactoryCommand:targetScriptFor(good)
    for _, st in pairs(self.data.stations or {}) do
        if st.name == self.data.target.name then
            return st.buys and st.buys[good]
        end
    end
end

-- returns the list of owned stations that can supply the given good:
--  - in range of the target (2.5 sectors or <= 3 gate jumps)
--  - they SELL the good
--  - they do NOT also buy the good (prevents loops / stealing from other factories)
function StockFactoryCommand:eligibleSources(good)
    local target = self.data.target
    local reachable = self.data.reachable or {}
    local result = {}

    for _, st in pairs(self.data.stations or {}) do
        if st.name ~= target.name
            and reachable[skey(st.x, st.y)]
            and st.sells and st.sells[good]
            and not (st.buys and st.buys[good]) then
            table.insert(result, st)
        end
    end

    return result
end

function StockFactoryCommand:estimateTravelTime(owner, source)
    local ship = ShipDatabaseEntry(owner.index, self.shipName)

    local range = 45
    if valid(ship) then
        local reach = ship:getHyperspaceProperties()
        if reach and reach > 1 then range = reach end
    end

    local t = self.data.target
    local dist = math.sqrt((t.x - source.x) ^ 2 + (t.y - source.y) ^ 2)
    local jumps = math.max(1, math.ceil(dist / range))
    local minutes = math.ceil(jumps * 45 / 60) + 2 -- + docking time

    return minutes * 60
end

function StockFactoryCommand:planNextHaul()
    local owner = getParentFaction()
    local target = self.data.target

    -- make sure the target still exists
    local targetEntry = ShipDatabaseEntry(owner.index, target.name)
    if not valid(targetEntry) or targetEntry:getEntityType() ~= EntityType.Station then
        self:setRuntimeError("Commander, the station '%s' we were stocking is gone. Ending the command."%_T, target.name)
        return
    end

    local goodsList = self.config.goods or {}
    if #goodsList == 0 then
        self.data.phase = "idle"
        self.data.rescanCooldown = 120
        return
    end

    local n = #goodsList
    local cursor = self.data.cursor or 0

    -- rotate through the selected goods so all of them get serviced over time
    for attempt = 0, n - 1 do
        local gi = ((cursor + attempt) % n) + 1
        local good = goodsList[gi]

        if isGoodEligible(good) then
            local sources = self:eligibleSources(good)

            if #sources > 0 then
                -- rotate through the possible sources too
                local sIdx = ((self.data.sourceCursor or 0) % #sources) + 1
                local source = sources[sIdx]

                self.data.cursor = cursor + attempt + 1
                self.data.sourceCursor = (self.data.sourceCursor or 0) + 1

                self.data.currentHaul = {
                    good = good,
                    source = {
                        name = source.name,
                        x = source.x,
                        y = source.y,
                        script = source.sells[good],
                    },
                    targetScript = self:targetScriptFor(good),
                    travelTime = self:estimateTravelTime(owner, source),
                }

                self.data.phase = "hauling"
                self.data.timer = 0
                return
            end
        end
    end

    -- nothing to fetch right now: stay assigned, idle near the station, re-scan later
    self.data.phase = "idle"
    self.data.rescanCooldown = 120
end


---------------------------------------------------------------------
-- transactions (asynchronous, executed inside the loaded sectors)
---------------------------------------------------------------------

local probeCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("stringutility")

function run(faction, shipName, stationName, script, goodName, callback)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end -- command will be cancelled anyway

    local station = Sector():getEntityByFactionAndName(faction, stationName)
    if not valid(station) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", "Commander, station '%s' has disappeared!"%_T, stationName)
        return
    end

    local callError, stock, maxStock = station:invokeFunction(script, "getStock", goodName)
    if callError ~= 0 then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, callback, goodName, 0, 0)
        return
    end

    invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, callback, goodName, stock, maxStock)
end
]]

local removeCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")
include("stringutility")

function run(faction, shipName, stationName, goodName, amount)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end

    local station = Sector():getEntityByFactionAndName(faction, stationName)
    if not valid(station) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", "Commander, station '%s' has disappeared!"%_T, stationName)
        return
    end

    local cargoBay = CargoBay(station)
    local before = cargoBay:getNumCargos(goodName)
    cargoBay:removeCargo(goodName, amount)
    local after = cargoBay:getNumCargos(goodName)
    local removed = before - after

    invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "onGoodsRemoved", goodName, removed)
end
]]

local addCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("goods")
include("utility")
include("stringutility")

function run(faction, shipName, stationName, goodName, amount)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end

    local station = Sector():getEntityByFactionAndName(faction, stationName)
    if not valid(station) then
        invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "transactionError", "Commander, station '%s' has disappeared!"%_T, stationName)
        return
    end

    local good = goods[goodName]
    if not good then return end

    local cargoBay = CargoBay(station)
    local before = cargoBay:getNumCargos(goodName)
    cargoBay:addCargo(good:good(), amount)
    local after = cargoBay:getNumCargos(goodName)
    local added = after - before
    local notAdded = amount - added

    invokeFactionFunction(faction, true, "background/simulation/simulation.lua", "invokeCommandFunction", shipName, "onGoodsDelivered", goodName, added, notAdded)
end
]]

local retourCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("goods")
include("utility")

function run(faction, shipName, stationName, goodName, amount)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end

    local station = Sector():getEntityByFactionAndName(faction, stationName)
    if not valid(station) then return end

    local good = goods[goodName]
    if not good then return end

    CargoBay(station):addCargo(good:good(), amount)
end
]]

function StockFactoryCommand:querySectors()
    local t = self.data.target
    local s = self.data.currentHaul.source

    Galaxy():keepOrGetSector(t.x, t.y, 90)
    Galaxy():keepOrGetSector(s.x, s.y, 90)

    if not Galaxy():sectorLoaded(t.x, t.y) or not Galaxy():sectorLoaded(s.x, s.y) then
        return false
    end

    return true
end

function StockFactoryCommand:beginTransaction()
    local haul = self.data.currentHaul
    local owner = getParentFaction()
    local t = self.data.target
    local s = haul.source

    if not haul.targetScript or not s.script then
        -- we don't know which scripts trade the good; skip this haul
        self.data.currentHaul = nil
        self.data.phase = "idle"
        self.data.rescanCooldown = 30
        return
    end

    if not self:querySectors() then
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

    -- transient (never saved to database on purpose)
    self.transaction = {
        good = haul.good,
        targetReceived = false,
        sourceReceived = false,
        targetRoom = 0,
        sourceStock = 0,
    }

    runSectorCode(t.x, t.y, true, probeCode, "run", owner.index, self.shipName, t.name, haul.targetScript, haul.good, "reportTargetStock")
    runSectorCode(s.x, s.y, true, probeCode, "run", owner.index, self.shipName, s.name, s.script, haul.good, "reportSourceStock")

    self.data.phase = "transacting"
    self.data.timer = 0
end

function StockFactoryCommand:reportTargetStock(good, stock, maxStock)
    if not self.transaction then return end
    self.transaction.targetRoom = math.max(0, (maxStock or 0) - (stock or 0))
    self.transaction.targetReceived = true
    self:tryExecuteHaul()
end

function StockFactoryCommand:reportSourceStock(good, stock, maxStock)
    if not self.transaction then return end
    self.transaction.sourceStock = stock or 0
    self.transaction.sourceReceived = true
    self:tryExecuteHaul()
end

function StockFactoryCommand:tryExecuteHaul()
    local tr = self.transaction
    if not tr or not tr.targetReceived or not tr.sourceReceived then return end

    local owner = getParentFaction()
    local haul = self.data.currentHaul
    if not haul then
        self.transaction = nil
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

    self.transaction = nil

    if not amount or amount <= 0 then
        self.data.currentHaul = nil
        self.data.phase = "idle"
        self.data.rescanCooldown = 30
        return
    end

    runSectorCode(haul.source.x, haul.source.y, true, removeCode, "run", owner.index, self.shipName, haul.source.name, good, amount)
end

function StockFactoryCommand:onGoodsRemoved(good, removed)
    local owner = getParentFaction()
    local haul = self.data.currentHaul
    if not haul then return end

    if (removed or 0) <= 0 then
        self.data.currentHaul = nil
        self.data.phase = "idle"
        self.data.rescanCooldown = 30
        return
    end

    local t = self.data.target
    runSectorCode(t.x, t.y, true, addCode, "run", owner.index, self.shipName, t.name, good, removed)
end

function StockFactoryCommand:onGoodsDelivered(good, added, notAdded)
    local owner = getParentFaction()
    local haul = self.data.currentHaul

    if (added or 0) > 0 then
        owner:sendChatMessage("", ChatMessageType.Economy, "'%1%' delivered %2% %3% to '%4%'."%_T, self.shipName, added, goodDisplayName(good, added), self.data.target.name)
    end

    -- if the target had less room than expected (e.g. another ship delivered in
    -- the meantime), return the leftover goods to the source instead of losing them
    if haul and (notAdded or 0) > 0 then
        runSectorCode(haul.source.x, haul.source.y, true, retourCode, "run", owner.index, self.shipName, haul.source.name, good, notAdded)
    end

    local returnLeg = (haul and haul.travelTime) or 60

    self.data.currentHaul = nil
    self.data.phase = "idle"
    self.data.rescanCooldown = returnLeg -- simulate the trip back before the next haul
end

function StockFactoryCommand:transactionError(msg, ...)
    self:setRuntimeError(msg, ...)
end

function StockFactoryCommand:setRuntimeError(msg, ...)
    eprint(msg, ...)
    getParentFaction():sendChatMessage("", ChatMessageType.Error, msg, ...)
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

-- BFS over the gate network from the origin sector, up to MaxGateJumps hops,
-- plus every sector within SectorRadius (Euclidean) of the origin.
local function computeReachableRegion(originX, originY)
    local reachable = {}
    local count = 0

    local function add(x, y)
        local key = skey(x, y)
        if not reachable[key] then
            reachable[key] = true
            count = count + 1
        end
    end

    -- "2.5 sectors away" disk
    local r = math.ceil(SectorRadius)
    for dx = -r, r do
        for dy = -r, r do
            if dx * dx + dy * dy <= SectorRadius * SectorRadius then
                add(originX + dx, originY + dy)
            end
        end
    end

    -- "3 consecutive gate jumps" flood fill
    local ok, gatesMap = pcall(function() return GatesMap(Server().seed) end)
    if ok and gatesMap then
        local frontier = {{x = originX, y = originY}}

        for jump = 1, MaxGateJumps do
            local nextFrontier = {}

            for _, sector in pairs(frontier) do
                local connected = {}
                local okc, res = pcall(function() return gatesMap:getConnectedSectors(sector) end)
                if okc and res then connected = res end

                for _, coord in pairs(connected) do
                    local key = skey(coord.x, coord.y)
                    if not reachable[key] then
                        add(coord.x, coord.y)
                        table.insert(nextFrontier, coord)
                        if count >= MaxReachableSectors then return reachable end
                    end
                end
            end

            frontier = nextFrontier
        end
    end

    return reachable
end

function StockFactoryCommand:onAreaAnalysisFinished(results, meta)
    local owner = Galaxy():findFaction(meta.factionIndex)
    local tradeScripts = TradingUtility.getTradeableScripts()

    local stations = {}

    for _, name in pairs({owner:getShipNames()}) do
        local entry = ShipDatabaseEntry(owner.index, name)

        if valid(entry) and entry:getEntityType() == EntityType.Station then
            local scripts = entry:getScripts()
            local secured = entry:getSecuredScriptValues()

            local buys = {}
            local sells = {}
            local hasTrade = false

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
                end
            end

            if hasTrade then
                local x, y = entry:getCoordinates()
                table.insert(stations, {name = name, x = x, y = y, buys = buys, sells = sells})
            end
        end
    end

    results.stations = stations

    -- reachable region around the ship's sector (which is also the target's sector,
    -- since only stations in the ship's sector can be selected as target)
    local sx, sy = meta.faction:getShipPosition(meta.shipName)
    local reachable = computeReachableRegion(sx, sy)
    results.reachable = reachable

    -- let the appearance system show the ferry anywhere in its operating region
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
            table.insert(results.reachableCoordinates, {x = kx, y = ky, faction = 0})
        end
    end
end


---------------------------------------------------------------------
-- descriptors
---------------------------------------------------------------------

function StockFactoryCommand:getDescriptionText()
    return "The ship keeps a station stocked with the goods it needs, fetching them from your own nearby stations."%_t
end

function StockFactoryCommand:getStatusMessage()
    return "Stocking a station /* ship AI status */"%_T
end

function StockFactoryCommand:getIcon()
    return "data/textures/icons/crate.png"
end

function StockFactoryCommand:getAreaBounds()
    return {lower = self.area.lower, upper = self.area.upper}
end

function StockFactoryCommand:getRecallError()
end

function StockFactoryCommand:getErrors(ownerIndex, shipName, area, config)
    if not config or not config.target then
        return "Select one of your stations to stock."%_t
    end

    if not config.goods or #config.goods == 0 then
        return "Select at least one good to stock."%_t
    end

    local prediction = self:calculatePrediction(ownerIndex, shipName, area, config)

    if not prediction.hasTarget then
        return "The selected station couldn't be found."%_t
    end

    if prediction.numGoodsWithSource == 0 then
        return "None of your stations in range supply the selected goods without also buying them."%_t
    end

    return
end

function StockFactoryCommand:getAreaSize(ownerIndex, shipName)
    return {x = 1, y = 1} -- the target is in the ship's own sector
end

function StockFactoryCommand:isShipRequiredInArea(ownerIndex, shipName)
    return true
end

function StockFactoryCommand:isAreaFixed(ownerIndex, shipName)
    return true
end

function StockFactoryCommand:getAreaSelectionTooltip(ownerIndex, shipName, area, valid)
    return ""
end

function StockFactoryCommand:getConfigurableValues(ownerIndex, shipName)
    return {}
end

function StockFactoryCommand:getPredictableValues()
    local values = {}
    values.attackChance = {displayName = SimulationUtility.AttackChanceLabelCaption}
    values.suppliers = {displayName = "Suppliers in Range"%_t}
    return values
end

function StockFactoryCommand:calculatePrediction(ownerIndex, shipName, area, config)
    local prediction = self:getPredictableValues()
    prediction.attackChance = 0

    local ship = ShipDatabaseEntry(ownerIndex, shipName)
    prediction.freeCargoSpace = valid(ship) and ship:getFreeCargoSpace() or 0

    local analysis = area.analysis or {}
    local stations = analysis.stations or {}
    local reachable = analysis.reachable or {}

    local target
    for _, st in pairs(stations) do
        if st.name == config.target then
            target = st
            break
        end
    end

    prediction.hasTarget = target ~= nil

    local supplierCount = 0
    local goodsWithSource = {}

    if target and config.goods then
        for _, good in pairs(config.goods) do
            if isGoodEligible(good) then
                for _, st in pairs(stations) do
                    if st.name ~= target.name
                        and reachable[skey(st.x, st.y)]
                        and st.sells and st.sells[good]
                        and not (st.buys and st.buys[good]) then
                        supplierCount = supplierCount + 1
                        goodsWithSource[good] = true
                    end
                end
            end
        end
    end

    prediction.suppliers.value = supplierCount
    prediction.supplierCount = supplierCount
    prediction.numGoodsWithSource = tablelength(goodsWithSource)

    return prediction
end

function StockFactoryCommand:generateAssessmentFromPrediction(prediction, captain, ownerIndex, shipName, area, config)
    local intro = {}
    if prediction.numGoodsWithSource > 0 then
        table.insert(intro, "We can keep that station stocked, Commander. I know where to get the goods."%_t)
        table.insert(intro, "Leave the logistics to me. I'll make sure the station never runs dry."%_t)
    else
        table.insert(intro, "I can't find any of our stations nearby that supply what this one needs."%_t)
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

-- collects the goods a station buys that are eligible to be ferried (sorted)
local function targetInputGoods(station)
    local list = {}
    if station and station.buys then
        for good, _ in pairs(station.buys) do
            if isGoodEligible(good) then
                table.insert(list, good)
            end
        end
    end
    table.sort(list)
    return list
end

local function findStation(stations, name)
    for _, st in pairs(stations or {}) do
        if st.name == name then return st end
    end
end

function StockFactoryCommand:buildUI(startPressedCallback, changeAreaPressedCallback, recallPressedCallback, configChangedCallback)
    local ui = {}
    ui.orderName = "Stock Factory"%_t
    ui.icon = StockFactoryCommand:getIcon()

    local size = vec2(700, 640)

    ui.window = GalaxyMap():createWindow(Rect(size))
    ui.window.caption = "Stock Factory"%_t

    local settings = {areaHeight = 110, configHeight = 250, hideEscortUI = true}
    ui.commonUI = SimulationUtility.buildCommandUI(ui.window, startPressedCallback, changeAreaPressedCallback, recallPressedCallback, configChangedCallback, settings)

    -- config: target station + goods checklist
    local configRect = ui.commonUI.configRect
    local vlist = UIVerticalLister(configRect, 8, 0)

    local headerRect = vlist:nextRect(20)
    local headerSplit = UIVerticalSplitter(headerRect, 8, 0, 0.35)
    ui.window:createLabel(headerSplit.left, "Station:"%_t, 13)
    ui.targetCombo = ui.window:createValueComboBox(headerSplit.right, configChangedCallback)

    vlist:nextRect(4)
    ui.window:createLabel(vlist:nextRect(15), "Goods to keep stocked:"%_t, 12)

    -- checklist of goods, laid out in two columns
    local gridRect = vlist.inner
    local columns = UIVerticalMultiSplitter(gridRect, 12, 0, 1)
    local columnRects = {columns.left, columns.right}

    ui.goodBoxes = {}
    local perColumn = math.ceil(MaxGoodCheckboxes / 2)
    for c = 1, 2 do
        local clist = UIVerticalLister(columnRects[c], 4, 0)
        for _ = 1, perColumn do
            local rowRect = clist:nextRect(18)
            local rowSplit = UIVerticalSplitter(rowRect, 5, 0, 0.12)
            rowSplit:setLeftQuadratic()

            local checkbox = ui.window:createCheckBox(rowSplit.left, "", configChangedCallback)
            local label = ui.window:createLabel(rowSplit.right, "", 12)

            checkbox:hide()
            label:hide()

            table.insert(ui.goodBoxes, {checkbox = checkbox, label = label, goodName = nil})
        end
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
    ui.window:createLabel(row.left, predictable.suppliers.displayName .. ":", 12)
    ui.suppliersLabel = ui.window:createLabel(row.right, "", 12)
    ui.suppliersLabel:setCenterAligned()

    local row = UIVerticalSplitter(plist:nextRect(15), 5, 0, 0.65)
    ui.window:createLabel(row.left, "Runtime:"%_t, 12)
    local runtimeLabel = ui.window:createLabel(row.right, "Indefinite"%_t, 12)
    runtimeLabel:setCenterAligned()

    ---------------------------------------------------------------
    -- ui methods
    ---------------------------------------------------------------

    ui.clear = function(self, shipName)
        self.commonUI:clear(shipName)
        self.targetCombo:clear()
        for _, box in pairs(self.goodBoxes) do
            box.goodName = nil
            box.checkbox:setCheckedNoCallback(false)
            box.checkbox:hide()
            box.label:hide()
        end
    end

    -- fills the target combo with owned stations in the ship's sector, and the
    -- goods checklist with the selected station's input goods
    ui.refreshInputs = function(self, ownerIndex, shipName, area)
        local stations = (area.analysis or {}).stations or {}

        local ship = ShipDatabaseEntry(ownerIndex, shipName)
        if not valid(ship) then return end
        local sx, sy = ship:getCoordinates()

        -- remember current selection & checked goods
        local previousTarget = self.targetCombo.selectedValue
        local checked = {}
        for _, box in pairs(self.goodBoxes) do
            if box.goodName and box.checkbox.visible and box.checkbox.checked then
                checked[box.goodName] = true
            end
        end

        -- rebuild target combo
        self.targetCombo:clear()
        local candidates = {}
        for _, st in pairs(stations) do
            if st.x == sx and st.y == sy and #targetInputGoods(st) > 0 then
                local entry = ShipDatabaseEntry(ownerIndex, st.name)
                local title = valid(entry) and entry:getTitle():translated() or ""
                local text = st.name
                if title ~= "" then text = title .. " - " .. st.name end
                table.insert(candidates, {name = st.name, text = text})
            end
        end
        table.sort(candidates, function(a, b) return a.text < b.text end)
        for _, c in pairs(candidates) do
            self.targetCombo:addEntry(c.name, c.text)
        end
        if previousTarget then
            self.targetCombo:setSelectedValueNoCallback(previousTarget)
        end

        -- rebuild goods checklist for the selected target
        local target = findStation(stations, self.targetCombo.selectedValue)
        local inputGoods = targetInputGoods(target)

        for i, box in ipairs(self.goodBoxes) do
            local good = inputGoods[i]
            if good then
                box.goodName = good
                box.label.caption = goodDisplayName(good, 2)
                box.checkbox:setCheckedNoCallback(checked[good] == true)
                box.checkbox:show()
                box.label:show()
            else
                box.goodName = nil
                box.checkbox:setCheckedNoCallback(false)
                box.checkbox:hide()
                box.label:hide()
            end
        end
    end

    ui.refresh = function(self, ownerIndex, shipName, area, config)
        self.commonUI:refresh(ownerIndex, shipName, area, config)

        if not config then
            self:refreshInputs(ownerIndex, shipName, area)
            config = self:buildConfig()
        end

        self:refreshPredictions(ownerIndex, shipName, area, config)
    end

    ui.refreshPredictions = function(self, ownerIndex, shipName, area, config)
        self:refreshInputs(ownerIndex, shipName, area)

        local prediction = StockFactoryCommand:calculatePrediction(ownerIndex, shipName, area, config)
        self:displayPrediction(prediction, config, ownerIndex)

        self.commonUI:refreshPredictions(ownerIndex, shipName, area, config, StockFactoryCommand, prediction)

        if not config.target or not config.goods or #config.goods == 0 then
            self.commonUI.startButton.active = false
        end
    end

    ui.displayPrediction = function(self, prediction, config, ownerIndex)
        self.cargoSpaceLabel.caption = math.floor(prediction.freeCargoSpace or 0)
        self.suppliersLabel.caption = tostring(prediction.supplierCount or 0)
        self.commonUI:setAttackChance(prediction.attackChance or 0)
    end

    ui.buildConfig = function(self)
        local config = {}
        config.escorts = self.commonUI.escortUI:buildConfig()
        config.target = self.targetCombo.selectedValue
        config.goods = {}

        for _, box in pairs(self.goodBoxes) do
            if box.goodName and box.checkbox.visible and box.checkbox.checked then
                table.insert(config.goods, box.goodName)
            end
        end

        return config
    end

    ui.displayConfig = function(self, config, ownerIndex)
        -- read-only display of a running command
        self.targetCombo:clear()
        if config.target then
            local entry = ShipDatabaseEntry(ownerIndex, config.target)
            local title = valid(entry) and entry:getTitle():translated() or ""
            local text = config.target
            if title ~= "" then text = title .. " - " .. config.target end
            self.targetCombo:addEntry(config.target, text)
            self.targetCombo:setSelectedValueNoCallback(config.target)
        end

        local goodsList = config.goods or {}
        for i, box in ipairs(self.goodBoxes) do
            local good = goodsList[i]
            if good then
                box.goodName = good
                box.label.caption = goodDisplayName(good, 2)
                box.checkbox:setCheckedNoCallback(true)
                box.checkbox:show()
                box.label:show()
            else
                box.goodName = nil
                box.checkbox:setCheckedNoCallback(false)
                box.checkbox:hide()
                box.label:hide()
            end
        end
    end

    ui.setActive = function(self, active, description)
        self.commonUI:setActive(active, description)
        self.targetCombo.active = active
        for _, box in pairs(self.goodBoxes) do
            box.checkbox.active = active
        end
    end

    ui.onWindowClosed = function(self)
    end

    return ui
end


return setmetatable({new = new}, {__call = function(_, ...) return new(...) end})
