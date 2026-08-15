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
local MaxGoodCheckboxes = 20

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

local function areaAnchor(area)
    if area and area.lower then
        return area.lower.x, area.lower.y
    end
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
    if not self.config.goods or #self.config.goods == 0 then
        return "We need at least one good to stock."%_T
    end

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

    self.data.phase = "idle"
    self.data.timer = 0
    self.data.rescanCooldown = 0
    self.data.cursor = 0
    self.data.sourceCursor = 0
    self.data.remapCooldown = RemapInterval

    local owner = getParentFaction()
    local entry = ShipDatabaseEntry(owner.index, self.shipName)
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

-- stations in the anchor region that consume the good
function StockFactoryCommand:eligibleTargets(good)
    local result = {}

    for _, st in pairs(self.data.stations or {}) do
        if st.buys and st.buys[good] then
            table.insert(result, st)
        end
    end

    return result
end

-- stations in the anchor region that can supply the good for a target:
--  - different station than the consumer
--  - sell the good
--  - do not also buy the same good (prevents internal starvation/loops)
function StockFactoryCommand:eligibleSources(good, target)
    local result = {}

    for _, st in pairs(self.data.stations or {}) do
        if not (st.name == target.name and st.factionIndex == target.factionIndex)
            and st.sells and st.sells[good]
            and not (st.buys and st.buys[good]) then
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
            local targets = self:eligibleTargets(good)

            if #targets > 0 then
                local tStart = self.data.targetCursor or 0

                for tAttempt = 0, #targets - 1 do
                    local ti = ((tStart + tAttempt) % #targets) + 1
                    local target = targets[ti]
                    local sources = self:eligibleSources(good, target)

                    if #sources > 0 then
                        -- rotate through the possible sources too
                        local sIdx = ((self.data.sourceCursor or 0) % #sources) + 1
                        local source = sources[sIdx]

                        self.data.cursor = cursor + attempt + 1
                        self.data.targetCursor = tStart + tAttempt + 1
                        self.data.sourceCursor = (self.data.sourceCursor or 0) + 1

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
                            travelTime = self:estimateTravelTime(source, target),
                        }

                        self.data.phase = "hauling"
                        self.data.timer = 0
                        return
                    end
                end
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

function run(faction, shipName, stationFaction, stationName, script, goodName, callback)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end -- command will be cancelled anyway

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
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

function run(faction, shipName, stationFaction, stationName, goodName, amount)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
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

function run(faction, shipName, stationFaction, stationName, goodName, amount)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
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

function run(faction, shipName, stationFaction, stationName, goodName, amount)
    local ship = ShipDatabaseEntry(faction, shipName)
    if not valid(ship) then return end

    local station = Sector():getEntityByFactionAndName(stationFaction, stationName)
    if not valid(station) then return end

    local good = goods[goodName]
    if not good then return end

    CargoBay(station):addCargo(good:good(), amount)
end
]]

function StockFactoryCommand:querySectors()
    local haul = self.data.currentHaul
    local t = haul and haul.target
    local s = haul and haul.source
    if not t or not s then return false end

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
    local t = haul.target
    local s = haul.source

    if not t.script or not s.script then
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

    runSectorCode(t.x, t.y, true, probeCode, "run", owner.index, self.shipName, t.factionIndex or owner.index, t.name, t.script, haul.good, "reportTargetStock")
    runSectorCode(s.x, s.y, true, probeCode, "run", owner.index, self.shipName, s.factionIndex or owner.index, s.name, s.script, haul.good, "reportSourceStock")

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

    runSectorCode(haul.source.x, haul.source.y, true, removeCode, "run", owner.index, self.shipName, haul.source.factionIndex or owner.index, haul.source.name, good, amount)
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

    -- log the pickup to economy chat
    local goodName = goodDisplayName(good, removed)
    local sourceStationName = haul.source.name
    owner:sendChatMessage("", ChatMessageType.Economy, "Picked up %1% units of %2% from %3%"%_T, removed, goodName, sourceStationName)

    local t = haul.target
    runSectorCode(t.x, t.y, true, addCode, "run", owner.index, self.shipName, t.factionIndex or owner.index, t.name, good, removed)
end

function StockFactoryCommand:onGoodsDelivered(good, added, notAdded)
    local owner = getParentFaction()
    local haul = self.data.currentHaul

    -- log the delivery to economy chat
    if haul and (added or 0) > 0 then
        local goodName = goodDisplayName(good, added)
        local targetStationName = haul.target.name
        owner:sendChatMessage("", ChatMessageType.Economy, "Delivered %1% units of %2% to %3%"%_T, added, goodName, targetStationName)
    end

    -- if the target had less room than expected (e.g. another ship delivered in
    -- the meantime), return the leftover goods to the source instead of losing them
    if haul and (notAdded or 0) > 0 then
        owner:sendChatMessage("", ChatMessageType.Economy, "Returned %1% units of %2% to %3% (target station was full)"%_T, notAdded, goodDisplayName(good, notAdded), haul.source.name)
        runSectorCode(haul.source.x, haul.source.y, true, retourCode, "run", owner.index, self.shipName, haul.source.factionIndex or owner.index, haul.source.name, good, notAdded)
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

-- BFS over the gate network from the anchor sector, bounded to MaxGateJumps.
-- Returns the reachable set, a gate-predecessor map (cameFrom[key] points one hop
-- closer to the anchor), and gate depths.
local function computeReachableRegion(owner, originX, originY)
    local reachable = {}
    local cameFrom = {}
    local gateDepth = {}
    local count = 0

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
    local ok, gatesMap = pcall(function() return GatesMap(Server().seed) end)
    if ok and gatesMap then
        local originKey = skey(originX, originY)
        local gateVisited = {[originKey] = true}
        gateDepth[originKey] = 0
        local frontier = {{x = originX, y = originY}}
        local depth = 0

        while #frontier > 0 and depth < MaxGateJumps do
            depth = depth + 1
            local nextFrontier = {}

            for _, sector in pairs(frontier) do
                local connected = {}
                local okc, res = pcall(function() return gatesMap:getConnectedSectors(sector) end)
                if okc and res then connected = res end

                for _, coord in pairs(connected) do
                    local key = skey(coord.x, coord.y)
                    if not gateVisited[key] then
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

-- gathers the owner's stations that trade goods, with their buy/sell trade scripts
local function gatherOwnedTradingStations(owner, reachable, callingPlayer)
    local tradeScripts = TradingUtility.getTradeableScripts()
    local stations = {}
    local seenStations = {}

    local factions = {}
    local factionSeen = {}

    local function addFaction(faction)
        if not faction or factionSeen[faction.index] then return end
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

            if valid(entry) and entry:getEntityType() == EntityType.Station then
                local x, y = entry:getCoordinates()
                if reachable and not reachable[skey(x, y)] then
                    goto continue
                end

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
                    seenStations[stationKey] = true
                    table.insert(stations, {name = name, factionIndex = faction.index, x = x, y = y, buys = buys, sells = sells})
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

-- true if at least one selected good can still be sourced from a reachable owned
-- supplier (i.e. the command can still do its job at all)
function StockFactoryCommand:hasAnyReachableSource()
    for _, good in pairs(self.config.goods or {}) do
        if isGoodEligible(good) then
            for _, target in pairs(self:eligibleTargets(good)) do
                if #self:eligibleSources(good, target) > 0 then
                    return true
                end
            end
        end
    end
    return false
end

-- re-scan owned stations and recompute the reachable region + gate route from the
-- target, so the command follows the galaxy over time (gates turning hostile,
-- suppliers built or destroyed). If nothing can be reached any more the ship can't
-- keep the order, so it is stopped and recalled.
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

    if not self:hasAnyReachableSource() then
        self:setRuntimeError("Commander, there are no producer/consumer station pairs for the selected goods in the anchor region. Recalling."%_T)
    end
end


---------------------------------------------------------------------
-- ferry route queries (which gate the visible ferry should fly through)
---------------------------------------------------------------------

-- runs inside the loaded sector: hands the computed next hop to the ferry appearance
local ferryReplyCode = [[
package.path = package.path .. ";data/scripts/lib/?.lua"
include("utility")

function run(faction, shipName, nextX, nextY, useGate)
    for _, entity in pairs({Sector():getEntitiesByScriptValue("displayed_faction")}) do
        if entity:getValue("displayed_faction") == faction and entity.name == shipName then
            entity:invokeFunction("ai/stockfactoryferry.lua", "setNextHop", nextX, nextY, useGate)
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

    if sx == haul.target.x and sy == haul.target.y then
        destX, destY = haul.source.x, haul.source.y
    else
        destX, destY = haul.target.x, haul.target.y
    end

    return nextHopOnTree(cameFrom, anchor.x, anchor.y, sx, sy, destX, destY)
end

-- invoked by the ferry appearance to learn which gate to use; replies straight
-- back into the ferry's sector via runSectorCode
function StockFactoryCommand:onFerryRouteRequest(sx, sy)
    local owner = getParentFaction()
    if not owner then return end

    local nextX, nextY, useGate = self:computeFerryNextHop(sx, sy)

    runSectorCode(sx, sy, true, ferryReplyCode, "run", owner.index, self.shipName,
        nextX or 0, nextY or 0, useGate and true or false)
end


---------------------------------------------------------------------
-- descriptors
---------------------------------------------------------------------

function StockFactoryCommand:getDescriptionText()
    local anchor = self.data and self.data.anchor
    if anchor then
        return "The ship is stocking your stations in the anchor region around \\s(${x}:${y}), moving selected goods between your own producers and consumers."%_T, {x = anchor.x, y = anchor.y}
    end

    return "The ship is stocking your stations in the anchor region, moving selected goods between your own producers and consumers."%_T
end

function StockFactoryCommand:getStatusMessage()
    return "Stocking a sector /* ship AI status */"%_T
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
    if not config.goods or #config.goods == 0 then
        return "You haven't selected any goods for me to stock. Tick at least one good from your anchor region before I can start."%_t
    end

    local prediction = self:calculatePrediction(ownerIndex, shipName, area, config)

    if prediction.numGoodsWithSource == 0 then
        return "No producer/consumer station pairs for the selected goods were found in the anchor region (up to 5 gate jumps)."%_t
    end

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

    local supplierCount = 0
    local goodsWithSource = {}

    if config.goods then
        for _, good in pairs(config.goods) do
            if isGoodEligible(good) then
                local hasPair = false
                for _, target in pairs(stations) do
                    if target.buys and target.buys[good] then
                        for _, source in pairs(stations) do
                            if not (source.name == target.name and source.factionIndex == target.factionIndex)
                                and source.sells and source.sells[good]
                                and not (source.buys and source.buys[good]) then
                                supplierCount = supplierCount + 1
                                hasPair = true
                            end
                        end
                    end
                end
                if hasPair then goodsWithSource[good] = true end
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
        table.insert(intro, "We can stock your anchor region, Commander. I know where to move those goods."%_t)
        table.insert(intro, "Leave the logistics to me. I'll keep those sector stations supplied."%_t)
    else
        table.insert(intro, "I can't find producer and consumer stations for those goods in the anchor region."%_t)
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

-- collects the goods traded by the anchor-region stations (consumed or produced),
-- filtered to eligible goods and sorted.
local function anchorRegionGoods(stations)
    local list = {}
    local seen = {}

    for _, station in pairs(stations or {}) do
        for good, _ in pairs(station.buys or {}) do
            if not seen[good] and isGoodEligible(good) then
                seen[good] = true
                table.insert(list, good)
            end
        end

        for good, _ in pairs(station.sells or {}) do
            if not seen[good] and isGoodEligible(good) then
                seen[good] = true
                table.insert(list, good)
            end
        end
    end

    table.sort(list)
    return list
end

function StockFactoryCommand:buildUI(startPressedCallback, changeAreaPressedCallback, recallPressedCallback, configChangedCallback)
    local ui = {}
    ui.orderName = "Stock Factory"%_t
    ui.icon = StockFactoryCommand:getIcon()

    local size = vec2(700, 720)

    ui.window = GalaxyMap():createWindow(Rect(size))
    ui.window.caption = "Stock Factory"%_t

    local settings = {areaHeight = 110, configHeight = 290, hideEscortUI = true}
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
        "The ship ferries only the goods you select, moving them between your own producer and consumer stations in that anchor region."%_t .. "\n\n" ..
        "It never hauls more than a consumer station needs, and never takes a good from a station that also buys it."%_t

    -- config: anchor sector + goods checklist
    local configRect = ui.commonUI.configRect
    local vlist = UIVerticalLister(configRect, 8, 0)

    local headerRect = vlist:nextRect(20)
    local headerSplit = UIVerticalSplitter(headerRect, 8, 0, 0.35)
    ui.window:createLabel(headerSplit.left, "Anchor Sector:"%_t, 13)
    ui.anchorSectorLabel = ui.window:createLabel(headerSplit.right, ""%_t, 13)
    ui.anchorSectorLabel:setCenterAligned()

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
        self.anchorSectorLabel.caption = ""%_t
        for _, box in pairs(self.goodBoxes) do
            box.goodName = nil
            box.checkbox:setCheckedNoCallback(false)
            box.checkbox:hide()
            box.label:hide()
        end
    end

    -- fills the goods checklist from all owned stations in the selected
    -- anchor region (anchor + up to 3 gate jumps)
    ui.refreshInputs = function(self, ownerIndex, shipName, area)
        local stations = (area.analysis or {}).stations or {}
        local ax, ay = areaAnchor(area)
        if ax then
            self.anchorSectorLabel.caption = "\\s(" .. ax .. ":" .. ay .. ")"
        else
            self.anchorSectorLabel.caption = ""%_t
        end

        -- remember checked goods
        local checked = {}
        for _, box in pairs(self.goodBoxes) do
            if box.goodName and box.checkbox.visible and box.checkbox.checked then
                checked[box.goodName] = true
            end
        end

        -- rebuild goods checklist for the whole anchor region
        local inputGoods = anchorRegionGoods(stations)

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

        if not config.goods or #config.goods == 0 then
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
        for _, box in pairs(self.goodBoxes) do
            box.checkbox.active = active
        end
    end

    ui.onWindowClosed = function(self)
    end

    return ui
end


return setmetatable({new = new}, {__call = function(_, ...) return new(...) end})
