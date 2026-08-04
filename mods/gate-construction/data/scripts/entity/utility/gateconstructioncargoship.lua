package.path = package.path .. ";data/scripts/lib/?.lua"

include("callable")
include("goods")
include("stringutility")

-- namespace GateConstructionCargoShip
GateConstructionCargoShip = {}
GateConstructionCargoShip.interactionThreshold = -100000

local ui = {}

function GateConstructionCargoShip.interactionPossible(playerIndex, option)
    return true
end

function GateConstructionCargoShip.initialize()
    if onServer() then
        local ship = Entity()
        ship:setValue("ai_no_attack", true)
    end

    if onClient() and EntityIcon().icon == "" then
        EntityIcon().icon = "data/textures/icons/pixel/freighter.png"
    end
end

function GateConstructionCargoShip.initUI()
    local res = getResolution()
    local size = vec2(460, 250)

    local menu = ScriptUI()
    local window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    menu:registerWindow(window, "Construction Ship"%_T, 6)

    window.caption = "Gate Construction Cargo"%_T
    window.showCloseButton = 1
    window.moveable = 1

    local lister = UIVerticalLister(Rect(vec2(10, 10), size - vec2(10, 10)), 10, 0)

    ui.info = window:createLabel(lister:nextRect(80), "Fetching requirement..."%_T, 12)
    ui.info:setLeftAligned()

    ui.refresh = window:createButton(lister:nextRect(30), "Refresh Requirement"%_T, "onRefresh")
    ui.deliver = window:createButton(lister:nextRect(30), "Deliver Components"%_T, "onDeliver")

    invokeServerFunction("requestStatus")
end

function GateConstructionCargoShip.onRefresh()
    invokeServerFunction("requestStatus")
end

function GateConstructionCargoShip.onDeliver()
    invokeServerFunction("deliver")
end

function GateConstructionCargoShip.receiveStatus(ok, msg)
    if not ui.info then return end

    if ok then
        ui.info.caption = msg or ""
    else
        ui.info.caption = msg or "Unavailable."%_T
    end
end

function GateConstructionCargoShip.requestStatus()
    local ship = Entity()
    local goodName = ship:getValue("gate_construction_goods_name")
    local required = ship:getValue("gate_construction_goods_required") or 0
    local delivered = ship:getValue("gate_construction_goods_delivered") or 0

    if not goodName then
        invokeClientFunction(Player(callingPlayer), "receiveStatus", false, "No active gate order on this ship."%_T)
        return
    end

    local left = math.max(0, required - delivered)
    local msg = "Required: ${required} ${good}. Delivered: ${delivered}. Remaining: ${left}."%_T % {
        required = required,
        good = goodName,
        delivered = delivered,
        left = left,
    }

    invokeClientFunction(Player(callingPlayer), "receiveStatus", true, msg)
end
callable(GateConstructionCargoShip, "requestStatus")

function GateConstructionCargoShip.deliver()
    local player = Player(callingPlayer)
    local craft = player and player.craft
    local ship = Entity()

    if not player or not craft then
        invokeClientFunction(player, "receiveStatus", false, "No active craft available for delivery."%_T)
        return
    end

    local goodName = ship:getValue("gate_construction_goods_name")
    local required = ship:getValue("gate_construction_goods_required") or 0
    local delivered = ship:getValue("gate_construction_goods_delivered") or 0

    if not goodName then
        invokeClientFunction(player, "receiveStatus", false, "No active gate order on this ship."%_T)
        return
    end

    local good = goods[goodName]
    if not good then
        invokeClientFunction(player, "receiveStatus", false, "Configured good doesn't exist."%_T)
        return
    end

    local remaining = math.max(0, required - delivered)
    if remaining <= 0 then
        invokeClientFunction(player, "receiveStatus", true, "All components are already delivered."%_T)
        return
    end

    if not ship:isInDockingArea(craft) then
        invokeClientFunction(player, "receiveStatus", false, "Dock to the cargo ship to deliver components."%_T)
        return
    end

    local onboard = craft:getCargoAmount(good:good())
    if onboard <= 0 then
        invokeClientFunction(player, "receiveStatus", false, "You do not carry the required components."%_T)
        return
    end

    local amount = math.min(remaining, onboard)
    craft:removeCargo(good:good(), amount)

    delivered = delivered + amount
    ship:setValue("gate_construction_goods_delivered", delivered)

    local left = math.max(0, required - delivered)
    local msg = "Delivered ${amount} ${good}. Remaining: ${left}."%_T % {
        amount = amount,
        good = goodName,
        left = left,
    }

    invokeClientFunction(player, "receiveStatus", true, msg)
end
callable(GateConstructionCargoShip, "deliver")
