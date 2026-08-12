package.path = package.path .. ";data/scripts/lib/?.lua"

include("callable")
include("goods")
include("stringutility")
include("utility")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace ProductionCapacityStats
ProductionCapacityStats = {}

local FactoryScript = "data/scripts/entity/merchants/factory.lua"

-- Mirrors data/scripts/entity/merchants/factory.lua:
-- a production cycle can never get shorter than MinimumTimeToProduce, and the
-- effective capacity is max(MinimumCapacity, capacity of the assembly blocks).
local MinimumTimeToProduce = 15.0
local MinimumCapacity = 100

-- Same math as Factory.refreshProductionTime(), solved for the capacity at which
-- the cycle time hits MinimumTimeToProduce.
function ProductionCapacityStats.getOptimalCapacity(production)
    if not production then return nil end

    local value = 0
    local levelSum = 0
    local samples = 0

    for _, part in pairs({production.results, production.garbages}) do
        for _, entry in pairs(part) do
            local good = goods[entry.name]
            if good then
                value = value + good.price * entry.amount
                levelSum = levelSum + (good.level or 0)
                samples = samples + 1
            end
        end
    end

    if samples == 0 or value <= 0 then return nil end

    local levelSpeedup = 1 + (levelSum / samples) / 100
    return value / MinimumTimeToProduce / levelSpeedup
end

-- Capacity the player still has to build. Below the free baseline nothing is needed.
function ProductionCapacityStats.getRequiredCapacity(optimal)
    if not optimal or optimal <= MinimumCapacity then return 0 end
    return math.ceil(optimal)
end


if onServer() then

function ProductionCapacityStats.requestOptimalCapacity(entityId)
    local player = Player(callingPlayer)
    if not player then return end

    local entity = Entity(entityId)
    if not valid(entity) then return end

    -- only report on crafts the requesting player actually owns
    if entity.factionIndex ~= player.index and entity.factionIndex ~= player.allianceIndex then
        return
    end

    local optimal
    if entity:hasScript(FactoryScript) then
        local ok, production = entity:invokeFunction(FactoryScript, "getProduction")
        if ok == 0 then
            optimal = ProductionCapacityStats.getOptimalCapacity(production)
        end
    end

    invokeClientFunction(player, "receiveOptimalCapacity", entityId, optimal)
end
callable(ProductionCapacityStats, "requestOptimalCapacity")

end


if onClient() then

local window
local label
local requestedCraft
local answeredCraft
local optimalCapacity

function ProductionCapacityStats.getUpdateInterval()
    return 0.5
end

function ProductionCapacityStats.initialize()
    Player():registerCallback("onStateChanged", "onStateChanged")

    local res = getResolution()
    local size = vec2(300, 60)
    local position = vec2(20, res.y - size.y - 20)

    window = Hud():createWindow(Rect(position, position + size))
    window.caption = "Production Capacity"%_t
    window.moveable = true

    label = window:createLabel(Rect(vec2(10, 5), size - vec2(10, 10)), "", 15)
    label:setCenterAligned()

    window:hide()
end

function ProductionCapacityStats.onStateChanged(newState, oldState)
    -- re-query on every build session, the production may have been set up meanwhile
    requestedCraft = nil
    answeredCraft = nil
    optimalCapacity = nil

    if newState ~= PlayerStateType.BuildCraft then
        window:hide()
    end
end

function ProductionCapacityStats.receiveOptimalCapacity(entityId, optimal)
    answeredCraft = entityId.string
    optimalCapacity = optimal
end

function ProductionCapacityStats.updateClient()
    local player = Player()

    if player.state ~= PlayerStateType.BuildCraft then
        window:hide()
        return
    end

    local craft = player.craft
    if not valid(craft) then
        window:hide()
        return
    end

    local craftId = craft.id.string
    if requestedCraft ~= craftId then
        requestedCraft = craftId
        answeredCraft = nil
        optimalCapacity = nil
        invokeServerFunction("requestOptimalCapacity", craft.id)
    end

    -- no answer yet, or the craft doesn't produce goods: leave the vanilla stats alone
    if answeredCraft ~= craftId or not optimalCapacity then
        window:hide()
        return
    end

    local current = math.floor(Plan(craft):getStats().productionCapacity)
    local required = ProductionCapacityStats.getRequiredCapacity(optimalCapacity)

    label.caption = string.format("%i/%i", current, required)
    if current >= required then
        label.color = ColorRGB(0.6, 1.0, 0.6)
    else
        label.color = ColorRGB(1.0, 0.5, 0.5)
    end

    window:show()
end

end
