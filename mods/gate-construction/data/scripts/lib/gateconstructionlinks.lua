-- Shared registry of gate links commissioned by the gate-construction mod.
-- Stored as a server value so it survives restarts and works for unloaded sectors.

local GateConstructionLinks = {}

local VALUE_KEY = "gate_construction_links"
local VERSION_KEY = "gate_construction_links_version"
local VERSION = 2

-- Links used to be reserved when a project was commissioned. Construction could then
-- silently fail (remote endpoints were never loaded into memory), leaving a reservation
-- that blocked the pair forever. Drop those stale entries once.
local function migrate()
    if (Server():getValue(VERSION_KEY) or 0) >= VERSION then return end

    Server():setValue(VALUE_KEY, "")
    Server():setValue(VERSION_KEY, VERSION)
end

function GateConstructionLinks.key(ax, ay, bx, by)
    if ax > bx or (ax == bx and ay > by) then
        ax, ay, bx, by = bx, by, ax, ay
    end

    return string.format("%i:%i>%i:%i", ax, ay, bx, by)
end

function GateConstructionLinks.getAll()
    migrate()

    local raw = Server():getValue(VALUE_KEY) or ""

    local links = {}
    for entry in string.gmatch(raw, "[^;]+") do
        links[entry] = true
    end

    return links
end

local function store(links)
    local entries = {}
    for entry, _ in pairs(links) do
        table.insert(entries, entry)
    end

    table.sort(entries)
    Server():setValue(VALUE_KEY, table.concat(entries, ";"))
end

function GateConstructionLinks.exists(ax, ay, bx, by)
    return GateConstructionLinks.getAll()[GateConstructionLinks.key(ax, ay, bx, by)] == true
end

function GateConstructionLinks.add(ax, ay, bx, by)
    local links = GateConstructionLinks.getAll()
    local key = GateConstructionLinks.key(ax, ay, bx, by)
    if links[key] then return end

    links[key] = true
    store(links)
end

function GateConstructionLinks.remove(ax, ay, bx, by)
    local links = GateConstructionLinks.getAll()
    local key = GateConstructionLinks.key(ax, ay, bx, by)
    if not links[key] then return end

    links[key] = nil
    store(links)
end

return GateConstructionLinks
