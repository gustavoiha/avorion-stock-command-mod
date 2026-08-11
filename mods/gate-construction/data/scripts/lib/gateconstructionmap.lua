-- Galaxy map bookkeeping for commissioned gates.
-- The map is drawn from stored sector views, not from live sector contents, so both the
-- "Inactive gate" marker and the finished gate link have to be written into them
-- (same approach as the vanilla Gate Map Upgrade item).

package.path = package.path .. ";data/scripts/lib/?.lua"

include("stringutility")

local GateConstructionMap = {}

local CUSTOM_ENTRY_KEY = "gate_construction_inactive_gate"

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

local function markSectorInactive(faction, x, y)
    editView(faction, x, y, function(view)
        view:setCustomEntry(CUSTOM_ENTRY_KEY, "Inactive gate"%_T)
    end)
end

local function markSectorActive(faction, x, y, tx, ty)
    editView(faction, x, y, function(view)
        view:setCustomEntry(CUSTOM_ENTRY_KEY, "")

        local destinations = {view:getGateDestinations()}
        for _, destination in pairs(destinations) do
            if destination.x == tx and destination.y == ty then return end
        end

        table.insert(destinations, ivec2(tx, ty))
        view:setGateDestinations(unpack(destinations))
    end)
end

function GateConstructionMap.markInactiveLink(playerIndices, ax, ay, bx, by)
    for _, faction in pairs(collectFactions(playerIndices)) do
        markSectorInactive(faction, ax, ay)
        markSectorInactive(faction, bx, by)
    end
end

function GateConstructionMap.markActiveLink(playerIndices, ax, ay, bx, by)
    for _, faction in pairs(collectFactions(playerIndices)) do
        markSectorActive(faction, ax, ay, bx, by)
        markSectorActive(faction, bx, by, ax, ay)
    end
end

return GateConstructionMap
