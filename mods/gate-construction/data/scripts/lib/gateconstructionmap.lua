-- Galaxy map bookkeeping for commissioned gates.
--
-- Finished links are written into the stored sector views, because that is where the map
-- draws gate connections from (same approach as the vanilla Gate Map Upgrade item).
--
-- Pending links are kept as faction values instead and drawn as an overlay by
-- player/map/gateconstructiongatemap.lua. A custom sector entry can never be removed once
-- written -- the engine stringifies whatever is passed, so even nil ends up as the text
-- "nil" -- which makes sector views unusable for anything temporary.

package.path = package.path .. ";data/scripts/lib/?.lua"

include("stringutility")

local GateConstructionLinks = include("gateconstructionlinks")

local GateConstructionMap = {}

local PENDING_KEY = "gate_construction_pending_map_links"
local CUSTOM_ENTRY_KEY = "gate_construction_inactive_gate"
local LEGACY_ENTRY = "Constructed gate"%_T

local function collectFactions(playerIndices)
    local factions = {}

    for _, playerIndex in pairs(playerIndices or {}) do
        local player = Player(playerIndex)
        if player then
            factions[player.index] = player
            if player.alliance then factions[player.alliance.index] = player.alliance end
        end
    end

    return factions
end

-- Only Player and Alliance carry sector views; a plain Faction does not.
local function editView(faction, x, y, edit)
    if not faction or not faction.getKnownSector then return end

    local view = faction:getKnownSector(x, y)
    if not view then return end

    edit(view)
    faction:updateKnownSector(view)
end

local function loadPending(faction)
    local links = {}

    for entry in string.gmatch(faction:getValue(PENDING_KEY) or "", "[^;]+") do
        links[entry] = true
    end

    return links
end

local function storePending(faction, links)
    local entries = {}
    for entry, _ in pairs(links) do
        table.insert(entries, entry)
    end

    table.sort(entries)
    faction:setValue(PENDING_KEY, table.concat(entries, ";"))
end

local function setPending(faction, key, wanted)
    local links = loadPending(faction)
    if (links[key] == true) == wanted then return end

    links[key] = wanted or nil
    storePending(faction, links)
end

-- Saves made before the overlay existed carry a permanent custom entry. It cannot be
-- deleted, only corrected -- and it must never be created for a sector that lacks one.
local function relabelLegacyEntry(view)
    local entries = view:getCustomEntries() or {}
    if not entries[CUSTOM_ENTRY_KEY] then return end

    view:setCustomEntry(CUSTOM_ENTRY_KEY, LEGACY_ENTRY)
end

local function markSectorActive(faction, x, y, tx, ty)
    editView(faction, x, y, function(view)
        relabelLegacyEntry(view)

        local destinations = {view:getGateDestinations()}
        for _, destination in pairs(destinations) do
            if destination.x == tx and destination.y == ty then return end
        end

        table.insert(destinations, ivec2(tx, ty))
        view:setGateDestinations(unpack(destinations))
    end)
end

function GateConstructionMap.markInactiveLink(playerIndices, ax, ay, bx, by)
    local key = GateConstructionLinks.key(ax, ay, bx, by)

    for _, faction in pairs(collectFactions(playerIndices)) do
        setPending(faction, key, true)
    end
end

function GateConstructionMap.markActiveLink(playerIndices, ax, ay, bx, by)
    local key = GateConstructionLinks.key(ax, ay, bx, by)

    for _, faction in pairs(collectFactions(playerIndices)) do
        setPending(faction, key, false)

        markSectorActive(faction, ax, ay, bx, by)
        markSectorActive(faction, bx, by, ax, ay)
    end
end

-- Every pending link a player should see, merged with its alliance's and deduplicated.
function GateConstructionMap.getPendingLinks(playerIndex)
    local keys = {}
    for _, faction in pairs(collectFactions({playerIndex})) do
        for key, _ in pairs(loadPending(faction)) do
            keys[key] = true
        end
    end

    local links = {}
    for key, _ in pairs(keys) do
        local ax, ay, bx, by = GateConstructionLinks.parse(key)
        if ax then
            table.insert(links, {ax = ax, ay = ay, bx = bx, by = by})
        end
    end

    return links
end

-- One-time fixup on login for galaxies built by an earlier version: correct the custom
-- entries it left behind and seed the overlay with links that are still pending.
function GateConstructionMap.repairLegacyMarkers(playerIndices)
    local factions = collectFactions(playerIndices)

    for _, sector in pairs(GateConstructionLinks.getAllSectors()) do
        for _, faction in pairs(factions) do
            editView(faction, sector.x, sector.y, relabelLegacyEntry)
        end
    end

    for key, _ in pairs(GateConstructionLinks.getAllPending()) do
        for _, faction in pairs(factions) do
            setPending(faction, key, true)
        end
    end
end

return GateConstructionMap
