package.path = package.path .. ";data/scripts/lib/?.lua"

local GateInfluence = include("gateinfluence")

local MaxListed = 12

local function reply(player, lines)
    for _, line in ipairs(lines) do
        print(line)

        if player then
            player:sendChatMessage("Gate Debug", ChatMessageType.Information, line)
        end
    end
end

local function factionName(index)
    local faction = Faction(index)
    if not faction then return "faction " .. tostring(index) end

    return (faction.name or "faction " .. tostring(index))
end

local function statsLines()
    local stats = GateInfluence.getStats()
    local hop = GateInfluence.HopWeight

    return {
        string.format("graph: %i nodes, %i edges (%i mod links, %i vanilla edges cached)",
            stats.nodes, stats.edges, stats.modLinks, stats.vanillaEdges),
        string.format("expansion: %i nodes expanded, %i queued", stats.expanded, stats.queued),
        string.format("constants: MaxHops=%i HopWeight=%.2f/%.2f/%.2f SpillRadius=%i LocalWeight=%.2f",
            GateInfluence.MaxHops, hop[1], hop[2], hop[3],
            GateInfluence.SpillRadius, GateInfluence.LocalWeight),
    }
end

local function dumpSector(x, y)
    local lines = {
        string.format("=== gate influence at (%i, %i) ===", x, y),
        string.format("inside barrier: %s | graph node: %s",
            tostring(GateInfluence.isInsideBarrier(x, y)),
            tostring(GateInfluence.isNode(x, y))),
    }

    for _, line in ipairs(statsLines()) do
        table.insert(lines, line)
    end

    -- Odds come from getTraderCandidates so this readout cannot drift from the real draw.
    local localFaction = Galaxy():getNearestFaction(x, y)
    local candidates = GateInfluence.getTraderCandidates(x, y, localFaction and localFaction.index)

    table.insert(lines, string.format("trader factions: %s %.0f%% (local)",
        factionName(localFaction and localFaction.index), candidates.localProbability * 100))

    if #candidates.foreign == 0 then
        table.insert(lines, "no gate-borne factions here - spawns are pure vanilla")
        return lines
    end

    for i, entry in ipairs(candidates.foreign) do
        if i > MaxListed then
            table.insert(lines, string.format("  ... and %i more", #candidates.foreign - MaxListed))
            break
        end

        table.insert(lines, string.format(
            "  via gate: %s %.0f%% (%i hop%s, spill %.1f, weight %.2f, gate at (%i,%i)->(%i,%i))",
            factionName(entry.factionIndex), entry.probability * 100,
            entry.hops, entry.hops == 1 and "" or "s",
            entry.spill, entry.weight,
            entry.via.x, entry.via.y, entry.viaTarget.x, entry.viaTarget.y))
    end

    return lines
end

local function dumpGraph()
    local lines = statsLines()
    local adjacency = GateInfluence.buildAdjacency()

    local keys = {}
    for key in pairs(adjacency) do table.insert(keys, key) end
    table.sort(keys)

    table.insert(lines, "nodes (sector -> linked sectors):")

    for i, key in ipairs(keys) do
        if i > MaxListed then
            table.insert(lines, string.format("  ... and %i more nodes", #keys - MaxListed))
            break
        end

        local targets = {}
        for neighbour in pairs(adjacency[key]) do table.insert(targets, neighbour) end
        table.sort(targets)

        table.insert(lines, "  " .. key .. " -> " .. table.concat(targets, ", "))
    end

    if #keys == 0 then
        table.insert(lines, "  (graph is empty - commission a gate first)")
    end

    return lines
end

-- The queue normally only drains while the hub sector is loaded; this forces it anywhere.
local function forceExpand(count)
    local before = GateInfluence.getStats()

    local remaining = true
    for _ = 1, count do
        if not remaining then break end
        remaining = GateInfluence.processExpansion(1)
    end

    local after = GateInfluence.getStats()

    return {
        string.format("expanded %i -> %i nodes, queue %i -> %i, vanilla edges %i -> %i",
            before.expanded, after.expanded, before.queued, after.queued,
            before.vanillaEdges, after.vanillaEdges),
        remaining and "queue still has work - run again" or "queue drained",
    }
end

function execute(sender, commandName, ...)
    local args = {...}
    local player = Player()

    local sub = string.lower(args[1] or "")

    if sub == "help" then
        reply(player, {
            "/gateinfluence            - influence at your current sector",
            "/gateinfluence <x> <y>    - influence at a specific sector",
            "/gateinfluence graph      - dump the gate graph and expansion state",
            "/gateinfluence expand [n] - force-drain n expansion nodes (default 5)",
        })
        return 0, "", ""
    end

    if sub == "graph" then
        reply(player, dumpGraph())
        return 0, "", ""
    end

    if sub == "expand" then
        reply(player, forceExpand(tonumber(args[2]) or 5))
        return 0, "", ""
    end

    local x, y = tonumber(args[1]), tonumber(args[2])

    if not x or not y then
        if not player then
            return 1, "", "No player context - specify coordinates: /gateinfluence <x> <y>"
        end

        x, y = player:getSectorCoordinates()
    end

    reply(player, dumpSector(x, y))
    return 0, "", ""
end

function getDescription()
    return "Inspects the gate-construction faction influence graph."
end

function getHelp()
    return "Usage: /gateinfluence [<x> <y> | graph | expand [n] | help]"
end
