-- Shared registry of gate links commissioned by the gate-construction mod.
-- Stored as a server value so it survives restarts and works for unloaded sectors.
--
-- Two sets are kept: pending links, whose inactive gates are built but not switched on
-- yet, and active links, which have real working gates at both endpoints.

local GateConstructionLinks = {}

local VALUE_KEY = "gate_construction_links"
local PENDING_KEY = "gate_construction_pending_links"
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

local function load(setKey)
    migrate()

    local raw = Server():getValue(setKey) or ""

    local links = {}
    for entry in string.gmatch(raw, "[^;]+") do
        links[entry] = true
    end

    return links
end

local function store(setKey, links)
    local entries = {}
    for entry, _ in pairs(links) do
        table.insert(entries, entry)
    end

    table.sort(entries)
    Server():setValue(setKey, table.concat(entries, ";"))
end

local function exists(setKey, ax, ay, bx, by)
    return load(setKey)[GateConstructionLinks.key(ax, ay, bx, by)] == true
end

local function add(setKey, ax, ay, bx, by)
    local links = load(setKey)
    local key = GateConstructionLinks.key(ax, ay, bx, by)
    if links[key] then return end

    links[key] = true
    store(setKey, links)
end

local function remove(setKey, ax, ay, bx, by)
    local links = load(setKey)
    local key = GateConstructionLinks.key(ax, ay, bx, by)
    if not links[key] then return end

    links[key] = nil
    store(setKey, links)
end

function GateConstructionLinks.getAll()
    return load(VALUE_KEY)
end

function GateConstructionLinks.exists(ax, ay, bx, by)
    return exists(VALUE_KEY, ax, ay, bx, by)
end

function GateConstructionLinks.add(ax, ay, bx, by)
    add(VALUE_KEY, ax, ay, bx, by)
end

function GateConstructionLinks.remove(ax, ay, bx, by)
    remove(VALUE_KEY, ax, ay, bx, by)
end

function GateConstructionLinks.getAllPending()
    return load(PENDING_KEY)
end

function GateConstructionLinks.existsPending(ax, ay, bx, by)
    return exists(PENDING_KEY, ax, ay, bx, by)
end

function GateConstructionLinks.addPending(ax, ay, bx, by)
    add(PENDING_KEY, ax, ay, bx, by)
end

function GateConstructionLinks.removePending(ax, ay, bx, by)
    remove(PENDING_KEY, ax, ay, bx, by)
end

return GateConstructionLinks
