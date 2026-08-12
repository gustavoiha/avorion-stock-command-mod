package.path = package.path .. ";data/scripts/lib/?.lua"

include("stringutility")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace CoreDistanceLabel
CoreDistanceLabel = {}

if onClient() then

local label

function CoreDistanceLabel.initialize()
    local player = Player()
    player:registerCallback("onShowGalaxyMap", "onShowGalaxyMap")
    player:registerCallback("onSelectMapCoordinates", "onSelectMapCoordinates")

    local res = getResolution()
    local container = GalaxyMap():createContainer(Rect(0, 0, res.x, res.y))

    label = container:createLabel(Rect(vec2(25, res.y - 62), vec2(525, res.y - 38)), "", 14)
    label:setLeftAligned()
    label.color = ColorRGB(0.65, 0.65, 0.65)
    label:hide()
end

function CoreDistanceLabel.onShowGalaxyMap()
    CoreDistanceLabel.refresh()
end

function CoreDistanceLabel.onSelectMapCoordinates(x, y)
    CoreDistanceLabel.refresh(x, y)
end

function CoreDistanceLabel.refresh(x, y)
    if not label then return end

    if x == nil or y == nil then
        x, y = GalaxyMap():getSelectedCoordinates()
    end

    if x == nil or y == nil then
        label:hide()
        return
    end

    local text = "Distance to center of galaxy: %.1f"%_t
    label.caption = string.format(text, math.sqrt(x * x + y * y))
    label:show()
end

end
