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

function ProductionCapacityStats.getCycleTimeSeconds(optimal, capacity)
    if not optimal then return nil end

    local effectiveCapacity = math.max(MinimumCapacity, capacity or 0)
    local cycleTime = math.max(MinimumTimeToProduce, MinimumTimeToProduce * optimal / effectiveCapacity)
    return math.floor(cycleTime)
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

local titleLabel
local capacityTitleLabel
local capacityValueLabel
local cycleTimeTitleLabel
local cycleTimeValueLabel
local container
local requestedCraft
local answeredCraft
local optimalCapacity

local function hideUi()
    if titleLabel then
        titleLabel:hide()
        capacityTitleLabel:hide()
        capacityValueLabel:hide()
        cycleTimeTitleLabel:hide()
        cycleTimeValueLabel:hide()
    end
end

function ProductionCapacityStats.getUpdateInterval()
    return 0.5
end

function ProductionCapacityStats.initialize()
    Player():registerCallback("onStateChanged", "onStateChanged")

    local res = getResolution()
    local hud = Hud()
    container = hud:createContainer(Rect(vec2(0, 0), res))

    local right = res.x - 22
    local left = res.x - 200
    local top = res.y - 112

    titleLabel = container:createLabel(Rect(vec2(left, top), vec2(right, top + 13)), "Production Capacity", 12)
    titleLabel:setLeftAligned()
    titleLabel.color = ColorRGB(0.82, 0.82, 0.82)
    titleLabel.outline = true
    titleLabel:hide()

    capacityTitleLabel = container:createLabel(Rect(vec2(left, top + 18), vec2(right - 48, top + 31)), "Capacity", 12)
    capacityTitleLabel:setLeftAligned()
    capacityTitleLabel.color = ColorRGB(0.72, 0.72, 0.72)
    capacityTitleLabel.outline = true
    capacityTitleLabel:hide()

    capacityValueLabel = container:createLabel(Rect(vec2(right - 100, top + 18), vec2(right, top + 31)), "", 12)
    capacityValueLabel:setRightAligned()
    capacityValueLabel.outline = true
    capacityValueLabel:hide()

    cycleTimeTitleLabel = container:createLabel(Rect(vec2(left, top + 32), vec2(right - 48, top + 45)), "Cycle Time", 12)
    cycleTimeTitleLabel:setLeftAligned()
    cycleTimeTitleLabel.color = ColorRGB(0.72, 0.72, 0.72)
    cycleTimeTitleLabel.outline = true
    cycleTimeTitleLabel:hide()

    cycleTimeValueLabel = container:createLabel(Rect(vec2(right - 100, top + 32), vec2(right, top + 45)), "", 12)
    cycleTimeValueLabel:setRightAligned()
    cycleTimeValueLabel.outline = true
    cycleTimeValueLabel:hide()

    hideUi()
end

function ProductionCapacityStats.onStateChanged(newState, oldState)
    -- re-query on every build session, the production may have been set up meanwhile
    requestedCraft = nil
    answeredCraft = nil
    optimalCapacity = nil

    if newState ~= PlayerStateType.BuildCraft then
        hideUi()
    end
end

function ProductionCapacityStats.receiveOptimalCapacity(entityId, optimal)
    answeredCraft = entityId.string
    optimalCapacity = optimal
end

function ProductionCapacityStats.updateClient()
    local player = Player()

    if player.state ~= PlayerStateType.BuildCraft then
        hideUi()
        return
    end

    local craft = player.craft
    if not valid(craft) then
        hideUi()
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
        hideUi()
        return
    end

    local current = math.floor(Plan(craft):getStats().productionCapacity)
    local required = ProductionCapacityStats.getRequiredCapacity(optimalCapacity)
    local cycleTime = ProductionCapacityStats.getCycleTimeSeconds(optimalCapacity, current)

    titleLabel.caption = "Production Capacity"%_t
    titleLabel:show()
    capacityTitleLabel.caption = "Capacity"%_t
    capacityTitleLabel:show()
    capacityValueLabel.caption = string.format("%i/%i", current, required)
    capacityValueLabel:show()
    if current >= required then
        capacityValueLabel.color = ColorRGB(0.6, 1.0, 0.6)
    else
        capacityValueLabel.color = ColorRGB(1.0, 0.5, 0.5)
    end

    cycleTimeTitleLabel.caption = "Cycle Time"%_t
    cycleTimeTitleLabel:show()
    cycleTimeValueLabel.caption = string.format("%is", cycleTime)
    cycleTimeValueLabel.color = ColorRGB(0.8, 0.8, 0.8)
    cycleTimeValueLabel:show()
end

end
