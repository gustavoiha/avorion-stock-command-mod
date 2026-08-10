-- Faction influence carried across gate links.
-- Hops are the only network currency: gate length never enters the math.

package.path = package.path .. ";data/scripts/lib/?.lua"

include("galaxy")

local GateConstructionLinks = include("gateconstructionlinks")
local GatesMap = include("gatesmap")

local GateInfluence = {}

GateInfluence.MaxHops = 3
GateInfluence.HopWeight = {0.70, 0.40, 0.15}
GateInfluence.SpillRadius = 17
GateInfluence.LocalWeight = 1.0

-- Vanilla gate topology is fixed by the galaxy seed and mod gates are permanent, so every
-- discovered edge stays valid forever. These sets are append-only and never invalidated.
local EDGES_KEY = "gate_influence_edges"
local EXPANDED_KEY = "gate_influence_expanded"
local QUEUE_KEY = "gate_influence_queue"

local function parseSet(raw)
    local set = {}
    for entry in string.gmatch(raw or "", "[^;]+") do
        set[entry] = true
    end

    return set
end

local function storeSet(key, set)
    local entries = {}
    for entry, _ in pairs(set) do
        table.insert(entries, entry)
    end

    table.sort(entries)
    Server():setValue(key, table.concat(entries, ";"))
end

local function nodeKey(x, y)
    return string.format("%i:%i", x, y)
end

local function parseNode(key)
    local x, y = string.match(key, "^(-?%d+):(-?%d+)")
    if not x then return end

    return tonumber(x), tonumber(y)
end

local function parseEdge(key)
    local ax, ay, bx, by = string.match(key, "^(-?%d+):(-?%d+)>(-?%d+):(-?%d+)$")
    if not ax then return end

    return tonumber(ax), tonumber(ay), tonumber(bx), tonumber(by)
end

local function queueKey(x, y, depth)
    return string.format("%i:%i:%i", x, y, depth)
end

local function parseQueueEntry(entry)
    local x, y, depth = string.match(entry, "^(-?%d+):(-?%d+):(%d+)$")
    if not x then return end

    return tonumber(x), tonumber(y), tonumber(depth)
end

function GateInfluence.isInsideBarrier(x, y)
    return Balancing_InsideRing(x, y)
end

-- Every edge costs exactly one hop, so a plain BFS is correct: there is no shorter path
-- to find by weighting, and gate length must never influence the result.
local function buildAdjacency()
    local adjacency = {}

    local function connect(ax, ay, bx, by)
        local a, b = nodeKey(ax, ay), nodeKey(bx, by)

        adjacency[a] = adjacency[a] or {}
        adjacency[b] = adjacency[b] or {}
        adjacency[a][b] = true
        adjacency[b][a] = true
    end

    for entry, _ in pairs(GateConstructionLinks.getAll()) do
        local ax, ay, bx, by = parseEdge(entry)
        if ax then connect(ax, ay, bx, by) end
    end

    for entry, _ in pairs(parseSet(Server():getValue(EDGES_KEY))) do
        local ax, ay, bx, by = parseEdge(entry)
        if ax then connect(ax, ay, bx, by) end
    end

    return adjacency
end

GateInfluence.buildAdjacency = buildAdjacency

function GateInfluence.isNode(x, y)
    return buildAdjacency()[nodeKey(x, y)] ~= nil
end

-- Debug support: the Server value keys are file-private, so expose the counts here.
function GateInfluence.getStats()
    local function count(set)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        return n
    end

    local nodes, halfEdges = 0, 0
    for _, neighbours in pairs(buildAdjacency()) do
        nodes = nodes + 1
        halfEdges = halfEdges + count(neighbours)
    end

    return {
        nodes = nodes,
        edges = halfEdges / 2,
        modLinks = count(GateConstructionLinks.getAll()),
        vanillaEdges = count(parseSet(Server():getValue(EDGES_KEY))),
        expanded = count(parseSet(Server():getValue(EXPANDED_KEY))),
        queued = count(parseSet(Server():getValue(QUEUE_KEY))),
    }
end

function GateInfluence.weight(hops, spill)
    local hopWeight = GateInfluence.HopWeight[hops]
    if not hopWeight then return 0 end

    local falloff = 1 - spill / GateInfluence.SpillRadius
    if falloff <= 0 then return 0 end

    return hopWeight * falloff
end

local function ownerOf(x, y)
    local galaxy = Galaxy()

    local faction = galaxy:getControllingFaction(x, y) or galaxy:getLocalFaction(x, y)
    if not faction then return end
    if not faction.isAIFaction then return end

    return faction
end

local function collectFrom(adjacency, originKey, spill, results)
    local visited = {[originKey] = true}
    local frontier = {}

    for neighbor, _ in pairs(adjacency[originKey] or {}) do
        visited[neighbor] = true
        table.insert(frontier, {key = neighbor, firstHop = neighbor})
    end

    for hops = 1, GateInfluence.MaxHops do
        if #frontier == 0 then break end

        local weight = GateInfluence.weight(hops, spill)
        if weight <= 0 then break end

        local nextFrontier = {}

        for _, entry in pairs(frontier) do
            local nx, ny = parseNode(entry.key)
            local faction = nx and ownerOf(nx, ny)

            local previous = faction and results[faction.index]
            if faction and (not previous or previous.weight < weight) then
                local gx, gy = parseNode(originKey)
                local tx, ty = parseNode(entry.firstHop)

                results[faction.index] = {
                    factionIndex = faction.index,
                    hops = hops,
                    spill = spill,
                    weight = weight,
                    via = {x = gx, y = gy},
                    viaTarget = {x = tx, y = ty},
                }
            end

            for neighbor, _ in pairs(adjacency[entry.key] or {}) do
                if not visited[neighbor] then
                    visited[neighbor] = true
                    table.insert(nextFrontier, {key = neighbor, firstHop = entry.firstHop})
                end
            end
        end

        frontier = nextFrontier
    end
end

-- Returns factions reachable from (x, y) through at least one gate hop, strongest first.
-- Each entry carries `via` (the sector holding the gate that carries the influence) and
-- `viaTarget` (where that gate leads), which together identify the gate entity to use.
function GateInfluence.getSectorInfluence(x, y)
    local adjacency = buildAdjacency()
    local origin = vec2(x, y)

    local results = {}

    for key, _ in pairs(adjacency) do
        local gx, gy = parseNode(key)
        if gx then
            local spill = distance(origin, vec2(gx, gy))
            if spill < GateInfluence.SpillRadius then
                collectFrom(adjacency, key, spill, results)
            end
        end
    end

    local sorted = {}
    for _, entry in pairs(results) do
        table.insert(sorted, entry)
    end

    table.sort(sorted, function(a, b)
        if a.weight == b.weight then return a.factionIndex < b.factionIndex end
        return a.weight > b.weight
    end)

    return sorted
end

-- Weighted draw between the vanilla proximity pick (LocalWeight) and each gate-borne
-- faction. Returns nil when the local faction wins, i.e. when vanilla should be left alone.
function GateInfluence.rollForeignFaction(influence, localFactionIndex)
    local candidates = {}
    local total = GateInfluence.LocalWeight

    for _, entry in pairs(influence) do
        if entry.factionIndex ~= localFactionIndex then
            table.insert(candidates, entry)
            total = total + entry.weight
        end
    end

    if #candidates == 0 then return end

    local roll = random():getFloat(0, total) - GateInfluence.LocalWeight
    if roll <= 0 then return end

    for _, entry in pairs(candidates) do
        roll = roll - entry.weight
        if roll <= 0 then return entry end
    end
end

-- The same pool rollForeignFaction draws from, with the odds resolved. Used for debug
-- readouts, so it must mirror the roll exactly - including excluding the local faction
-- when it also appears in the influence list.
function GateInfluence.getTraderCandidates(x, y, localFactionIndex)
    local total = GateInfluence.LocalWeight
    local foreign = {}

    for _, entry in ipairs(GateInfluence.getSectorInfluence(x, y)) do
        if entry.factionIndex ~= localFactionIndex then
            table.insert(foreign, entry)
            total = total + entry.weight
        end
    end

    for _, entry in ipairs(foreign) do
        entry.probability = entry.weight / total
    end

    return {
        localFactionIndex = localFactionIndex,
        localProbability = GateInfluence.LocalWeight / total,
        foreign = foreign,
    }
end

function GateInfluence.onLinkCompleted(ax, ay, bx, by)
    local queue = parseSet(Server():getValue(QUEUE_KEY))
    local expanded = parseSet(Server():getValue(EXPANDED_KEY))

    if not expanded[nodeKey(ax, ay)] then queue[queueKey(ax, ay, 0)] = true end
    if not expanded[nodeKey(bx, by)] then queue[queueKey(bx, by, 0)] = true end

    storeSet(QUEUE_KEY, queue)
end

-- Splices vanilla gate edges into the graph. getConnectedSectors scans a 180x180 window,
-- so this drains a few nodes per call rather than expanding everything at once.
function GateInfluence.processExpansion(maxNodes)
    local queue = parseSet(Server():getValue(QUEUE_KEY))

    local pending = {}
    for entry, _ in pairs(queue) do
        table.insert(pending, entry)
    end

    if #pending == 0 then return false end

    table.sort(pending)

    local expanded = parseSet(Server():getValue(EXPANDED_KEY))
    local edges = parseSet(Server():getValue(EDGES_KEY))
    local map = GatesMap(Server().seed)

    local budget = maxNodes or 1
    local processed = 0

    for _, entry in ipairs(pending) do
        if processed >= budget then break end

        queue[entry] = nil

        local x, y, depth = parseQueueEntry(entry)
        if x and not expanded[nodeKey(x, y)] then
            expanded[nodeKey(x, y)] = true
            processed = processed + 1

            if map:hasGates(x, y) then
                for _, connected in pairs(map:getConnectedSectors({x = x, y = y})) do
                    edges[GateConstructionLinks.key(x, y, connected.x, connected.y)] = true

                    if depth + 1 < GateInfluence.MaxHops
                            and not expanded[nodeKey(connected.x, connected.y)] then
                        queue[queueKey(connected.x, connected.y, depth + 1)] = true
                    end
                end
            end
        end
    end

    storeSet(QUEUE_KEY, queue)
    storeSet(EXPANDED_KEY, expanded)
    storeSet(EDGES_KEY, edges)

    return next(queue) ~= nil
end

-- Factions that can currently reach a faction on the opposite side of the barrier within
-- MaxHops. A faction's side is decided by the graph node it owns, never by its home
-- sector: what matters is which end of the gate network it actually sits on.
-- Returned as a set of faction indices so callers can diff it against what they know.
function GateInfluence.getCrossBarrierFactions()
    local adjacency = buildAdjacency()

    local owners = {}
    for key, _ in pairs(adjacency) do
        local x, y = parseNode(key)
        if x then
            local faction = ownerOf(x, y)
            if faction then
                owners[key] = {index = faction.index, inside = GateInfluence.isInsideBarrier(x, y)}
            end
        end
    end

    local connected = {}

    for originKey, origin in pairs(owners) do
        local visited = {[originKey] = true}
        local frontier = {originKey}

        for _ = 1, GateInfluence.MaxHops do
            local nextFrontier = {}

            for _, current in ipairs(frontier) do
                for neighbor, _ in pairs(adjacency[current] or {}) do
                    if not visited[neighbor] then
                        visited[neighbor] = true
                        table.insert(nextFrontier, neighbor)

                        -- Both ends gain the crossing, so credit them together.
                        local other = owners[neighbor]
                        if other and other.inside ~= origin.inside and other.index ~= origin.index then
                            connected[origin.index] = true
                            connected[other.index] = true
                        end
                    end
                end
            end

            frontier = nextFrontier
        end
    end

    return connected
end

return GateInfluence
