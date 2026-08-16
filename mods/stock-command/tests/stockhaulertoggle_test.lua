local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/tests/[^/]+$") or "."

debug.setmetatable("", {
    __index = string,
    __mod = function(value) return value end,
})

AlliancePrivilege = {ManageStations = 1}

-- engine stand-ins. `side` decides whether onServer()/onClient() report server or client,
-- so the same namespace can be driven from both ends of the RPC boundary.
local side = "server"
function onServer() return side == "server" end
function onClient() return side == "client" end

callingPlayer = nil

local permissionGranted = true
function checkEntityInteractionPermissions() return permissionGranted end
function Entity() return {index = 1} end
function Rect(...) return {...} end

local players = {}
function Player(index) return players[index or 1] end

local currentFaction = {index = 1}
function Faction() return currentFaction end

local serverCalls = {}
function invokeServerFunction(name, ...) serverCalls[#serverCalls + 1] = {name = name, args = {...}} end

local clientCalls = {}
function invokeClientFunction(_, name, ...) clientCalls[#clientCalls + 1] = {name = name, args = {...}} end

local callables = {}
function callable(namespace, name)
    namespace.Callable = namespace.Callable or {}
    namespace.Callable[name] = namespace[name]
    callables[name] = true
end

local function makeButton()
    local button = {visible = false}
    button.show = function(self) self.visible = true end
    button.hide = function(self) self.visible = false end
    return button
end

local function makeTab()
    local tab = {size = {x = 400}, buttons = {}}
    tab.createButton = function(self, rect, caption, callbackName)
        local button = makeButton()
        button.callback = callbackName
        button.rect = rect
        self.buttons[#self.buttons + 1] = button
        return button
    end
    return tab
end

-- a minimal stand-in for a vanilla trading namespace, tracking that the wrapped
-- vanilla implementations are still invoked
local function makeNamespace()
    local calls = {}
    return {
        buildBuyGui = function() calls.buildBuyGui = (calls.buildBuyGui or 0) + 1 end,
        buildSellGui = function() calls.buildSellGui = (calls.buildSellGui or 0) + 1 end,
        onShowWindow = function() calls.onShowWindow = (calls.onShowWindow or 0) + 1 end,
        secure = function() return {vanilla = true} end,
        restore = function() calls.restore = (calls.restore or 0) + 1 end,
    }, calls
end

local Toggle = dofile(root .. "/data/scripts/lib/stockhaulertoggle.lua")

local failures = 0
local function check(label, condition)
    if condition then
        print("  PASS  " .. label)
    else
        failures = failures + 1
        print("  FAIL  " .. label)
    end
end

print("\n[installation]")

local factory, factoryCalls = makeNamespace()
local factoryState = Toggle.install(factory, {pickupOffset = 30, deliveryOffset = 30})
check("both toggles default to enabled", factoryState.pickup == true and factoryState.delivery == true)
check("both setters are exposed to the server", callables.shSetPickup and callables.shSetDelivery)
check("state requests are exposed to the server", callables.shRequestState)

callables = {}
local seller = makeNamespace()
Toggle.install(seller, {pickupOffset = 30})
check("sell-only stations expose a pickup setter", seller.shSetPickup ~= nil)
check("sell-only stations do not expose a dead delivery setter", seller.shSetDelivery == nil)
check("sell-only stations have no delivery button callback", seller.shOnDeliveryToggle == nil)

callables = {}
local consumer = makeNamespace()
Toggle.install(consumer, {deliveryOffset = 62})
check("buy-only stations expose a delivery setter", consumer.shSetDelivery ~= nil)
check("buy-only stations do not expose a dead pickup setter", consumer.shSetPickup == nil)

print("\n[gui]")

side = "client"
local buyTab = makeTab()
factory.buildBuyGui(buyTab)
check("the vanilla buy gui is still built", factoryCalls.buildBuyGui == 1)
check("a pickup button is added to the buy tab", #buyTab.buttons == 1)
check("the pickup button is hidden until ownership is known", buyTab.buttons[1].visible == false)
check("the pickup button targets the namespace callback", buyTab.buttons[1].callback == "shOnPickupToggle")

local sellTab = makeTab()
factory.buildSellGui(sellTab)
check("the vanilla sell gui is still built", factoryCalls.buildSellGui == 1)
check("a delivery button is added to the sell tab", #sellTab.buttons == 1)

local consumerTab = makeTab()
consumer.buildSellGui(consumerTab)
check("the consumer button is offset left of the vanilla trader button",
    consumerTab.buttons[1].rect[1] == 400 - 62 and consumerTab.buttons[1].rect[3] == 400 - 32)

serverCalls = {}
currentFaction = {index = 1}
players[1] = {index = 1, allianceIndex = 0}
factory.onShowWindow()
check("the vanilla show handler still runs", factoryCalls.onShowWindow == 1)
check("owners see the toggles", buyTab.buttons[1].visible and sellTab.buttons[1].visible)
check("owners pull the authoritative state from the server",
    #serverCalls == 1 and serverCalls[1].name == "shRequestState")

serverCalls = {}
currentFaction = {index = 2}
factory.onShowWindow()
check("non-owners do not see the toggles", not buyTab.buttons[1].visible and not sellTab.buttons[1].visible)
check("non-owners do not query the server", #serverCalls == 0)

serverCalls = {}
currentFaction = {index = 3}
players[1] = {
    index = 1,
    allianceIndex = 3,
    alliance = {hasPrivilege = function() return false end},
}
factory.onShowWindow()
check("alliance members without ManageStations do not see the toggles", not buyTab.buttons[1].visible)

players[1].alliance.hasPrivilege = function() return true end
factory.onShowWindow()
check("alliance members with ManageStations see the toggles", buyTab.buttons[1].visible)

print("\n[toggling]")

serverCalls = {}
factory.shOnPickupToggle()
check("clicking flips the client state immediately", factoryState.pickup == false)
check("clicking forwards the new state to the server",
    #serverCalls == 1 and serverCalls[1].name == "shSetPickup" and serverCalls[1].args[1] == false)
check("the button icon reflects the disabled state",
    buyTab.buttons[1].icon == "data/textures/icons/sell-disabled.png")

factory.shOnPickupToggle()
check("clicking again re-enables pickup", factoryState.pickup == true)

print("\n[server authority]")

side = "server"
callingPlayer = 1
clientCalls = {}
permissionGranted = true
factory.shSetPickup(false)
check("a permitted toggle is applied", factoryState.pickup == false)
check("a permitted toggle is echoed back to the client",
    #clientCalls == 1 and clientCalls[1].name == "shReceiveState" and clientCalls[1].args[1] == false)

clientCalls = {}
permissionGranted = false
factory.shSetPickup(true)
check("an unauthorized toggle is rejected", factoryState.pickup == false)
check("an unauthorized toggle re-syncs the real state to the client",
    #clientCalls == 1 and clientCalls[1].args[1] == false)

clientCalls = {}
callingPlayer = nil
factory.shRequestState()
check("a state request without a calling player is ignored", #clientCalls == 0)

print("\n[persistence]")

permissionGranted = true
callingPlayer = 1
factoryState.pickup = false
factoryState.delivery = true

local secured = factory.secure()
check("the vanilla secured data is preserved", secured.vanilla == true)
check("both flags are always secured",
    secured.stockHaulerPickupEnabled == false and secured.stockHaulerDeliveryEnabled == true)

factoryState.pickup = true
factoryState.delivery = false
factory.restore(secured)
check("the vanilla restore still runs", factoryCalls.restore == 1)
check("restore round-trips both flags", factoryState.pickup == false and factoryState.delivery == true)

factory.restore({})
check("absent flags keep the current state", factoryState.pickup == false and factoryState.delivery == true)

factory.restore(nil)
check("a nil restore payload is survivable", factoryState.pickup == false)

if failures > 0 then
    error(string.format("%d stock hauler toggle test(s) failed", failures))
end

print("\nAll stock hauler toggle tests passed.")
