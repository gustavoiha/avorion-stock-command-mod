-- Shared "transfer cargo with stock haulers" opt-out toggle for the vanilla trading
-- station scripts (factory, consumer, seller, trading post).
--
-- Each of those scripts is extended by a name-clashing injection that calls
-- StockHaulerToggle.install(<Namespace>, options). The toggles are stored in the
-- station's secure()/restore() data as stockHaulerPickupEnabled /
-- stockHaulerDeliveryEnabled, which is what the Stock Factory command reads back out
-- of ShipDatabaseEntry:getSecuredScriptValues() when it picks routes.

local StockHaulerToggle = {}

local IconEnabled = "data/textures/icons/sell-enabled.png"
local IconDisabled = "data/textures/icons/sell-disabled.png"

-- vanilla icon buttons in these tabs occupy the rightmost 30px; an offset of 62 parks
-- ours immediately to the left of one
local function buttonRect(tab, offset)
    return Rect(tab.size.x - offset, -5, tab.size.x - (offset - 30), 25)
end

function StockHaulerToggle.install(namespace, options)
    options = options or {}

    local state = {pickup = true, delivery = true}
    local pickupButton, deliveryButton

    local function refreshPickup()
        if not pickupButton then return end
        pickupButton.icon = state.pickup and IconEnabled or IconDisabled
        pickupButton.tooltip = state.pickup
            and "Transfer cargo with stock haulers: ENABLED\nStock haulers may pick up goods from this station."%_t
            or "Transfer cargo with stock haulers: DISABLED\nStock haulers will not pick up goods from this station."%_t
    end

    local function refreshDelivery()
        if not deliveryButton then return end
        deliveryButton.icon = state.delivery and IconEnabled or IconDisabled
        deliveryButton.tooltip = state.delivery
            and "Transfer cargo with stock haulers: ENABLED\nStock haulers may deliver goods to this station."%_t
            or "Transfer cargo with stock haulers: DISABLED\nStock haulers will not deliver goods to this station."%_t
    end

    local function sendState()
        if not onServer() or not callingPlayer then return end
        invokeClientFunction(Player(callingPlayer), "shReceiveState", state.pickup, state.delivery)
    end

    namespace.shRequestState = function()
        if onClient() then
            invokeServerFunction("shRequestState")
        else
            sendState()
        end
    end
    callable(namespace, "shRequestState")

    namespace.shReceiveState = function(pickup, delivery)
        if onServer() then return end
        state.pickup = pickup ~= false
        state.delivery = delivery ~= false
        refreshPickup()
        refreshDelivery()
    end

    -- the server is authoritative: a rejected toggle is answered with the real state,
    -- which corrects the client's optimistic flip
    local function installSetter(field, name)
        namespace[name] = function(value)
            if onClient() then
                invokeServerFunction(name, value)
                return
            end

            if not checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageStations) then
                sendState()
                return
            end

            state[field] = (value ~= false)
            sendState()
        end
        callable(namespace, name)
    end

    if options.pickupOffset then
        installSetter("pickup", "shSetPickup")

        namespace.shOnPickupToggle = function()
            state.pickup = not state.pickup
            refreshPickup()
            invokeServerFunction("shSetPickup", state.pickup)
        end

        local originalBuyGui = namespace.buildBuyGui
        namespace.buildBuyGui = function(tab)
            originalBuyGui(tab)
            if not onClient() then return end

            pickupButton = tab:createButton(buttonRect(tab, options.pickupOffset), "", "shOnPickupToggle")
            refreshPickup()
            pickupButton:hide()
        end
    end

    if options.deliveryOffset then
        installSetter("delivery", "shSetDelivery")

        namespace.shOnDeliveryToggle = function()
            state.delivery = not state.delivery
            refreshDelivery()
            invokeServerFunction("shSetDelivery", state.delivery)
        end

        local originalSellGui = namespace.buildSellGui
        namespace.buildSellGui = function(tab)
            originalSellGui(tab)
            if not onClient() then return end

            deliveryButton = tab:createButton(buttonRect(tab, options.deliveryOffset), "", "shOnDeliveryToggle")
            refreshDelivery()
            deliveryButton:hide()
        end
    end

    local originalOnShowWindow = namespace.onShowWindow
    namespace.onShowWindow = function()
        originalOnShowWindow()

        local faction = Faction()
        local player = Player()
        if not faction or not player then return end

        local manages = player.index == faction.index
        if player.allianceIndex == faction.index and player.alliance then
            manages = player.alliance:hasPrivilege(player.index, AlliancePrivilege.ManageStations)
        end

        if pickupButton then
            if manages then pickupButton:show() else pickupButton:hide() end
        end
        if deliveryButton then
            if manages then deliveryButton:show() else deliveryButton:hide() end
        end

        -- secure()/restore() is server-side persistence, so the client starts on the
        -- defaults and needs the authoritative state pushed to it
        if manages then invokeServerFunction("shRequestState") end
    end

    -- both flags are always secured, even the one this station type can't toggle, so the
    -- command sees a uniform shape in getSecuredScriptValues()
    local originalSecure = namespace.secure
    namespace.secure = function()
        local data = originalSecure() or {}
        data.stockHaulerPickupEnabled = state.pickup
        data.stockHaulerDeliveryEnabled = state.delivery
        return data
    end

    local originalRestore = namespace.restore
    namespace.restore = function(data)
        originalRestore(data)
        if type(data) ~= "table" then return end

        if data.stockHaulerPickupEnabled ~= nil then state.pickup = data.stockHaulerPickupEnabled end
        if data.stockHaulerDeliveryEnabled ~= nil then state.delivery = data.stockHaulerDeliveryEnabled end
    end

    return state
end

return StockHaulerToggle
