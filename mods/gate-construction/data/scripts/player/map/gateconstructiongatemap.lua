-- Draws commissioned but not yet activated gate links onto the galaxy map.
--
-- Purely a client overlay rebuilt from server data every time the map is opened, so it
-- leaves nothing behind in the save. Sector views are deliberately not used: a custom
-- sector entry cannot be removed once written, and this marker has to disappear the
-- moment the link goes live.

package.path = package.path .. ";data/scripts/lib/?.lua"

include("callable")
include("stringutility")

local GateConstructionMap = include("gateconstructionmap")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace GateConstructionGateMap
GateConstructionGateMap = {}

local ICON = "data/textures/icons/pixel/gate.png"

if onClient() then

local container
local pendingLinks = {}

local function refresh()
    if not container then return end

    container:clear()

    for _, link in pairs(pendingLinks) do
        local line = container:createMapArrowLine()
        line.layer = -10
        line.from = ivec2(link.ax, link.ay)
        line.to = ivec2(link.bx, link.by)
        line.color = ColorARGB(0.5, 0.45, 0.7, 1.0)
        line.width = 8

        for _, endpoint in pairs({{link.ax, link.ay}, {link.bx, link.by}}) do
            local icon = container:createMapIcon(ICON, ivec2(endpoint[1], endpoint[2]))
            icon.color = ColorARGB(0.9, 0.45, 0.7, 1.0)
            icon.tooltip = "Inactive Gate"%_t
        end
    end
end

function GateConstructionGateMap.initialize()
    Player():registerCallback("onShowGalaxyMap", "onShowGalaxyMap")

    container = GalaxyMap():createContainer()
end

function GateConstructionGateMap.onShowGalaxyMap()
    invokeServerFunction("requestPendingLinks")
end

function GateConstructionGateMap.receivePendingLinks(links)
    pendingLinks = links or {}
    refresh()
end

end

if onServer() then

function GateConstructionGateMap.requestPendingLinks()
    local player = Player()
    if not player then return end

    invokeClientFunction(player, "receivePendingLinks",
        GateConstructionMap.getPendingLinks(player.index))
end
callable(GateConstructionGateMap, "requestPendingLinks")

end
