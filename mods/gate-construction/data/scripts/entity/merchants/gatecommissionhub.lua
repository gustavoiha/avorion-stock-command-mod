package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("callable")
include("stringutility")
include("relations")
include("faction")
include("galaxy")
local Dialog = include("dialogutility")
local GatesMap = include("gatesmap")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace GateCommissionHub
GateCommissionHub = {}
GateCommissionHub.interactionThreshold = -30000

local ui = {}

local FIXED_CREDITS_FEE = 5000000
local FIXED_IRON_AMOUNT = 50000
local FIXED_TRINIUM_AMOUNT = 20000
local FIXED_XANION_AMOUNT = 20000
local FIXED_AVORION_AMOUNT = 10000

local function makeResourceVector()
    local result = {0, 0, 0, 0, 0, 0, 0}
    result[1] = FIXED_IRON_AMOUNT
    result[4] = FIXED_TRINIUM_AMOUNT
    result[5] = FIXED_XANION_AMOUNT
    result[7] = FIXED_AVORION_AMOUNT
    return result
end

local function distance2d(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function computeQuote(ax, ay, bx, by)
    local jumpDistance = distance2d(ax, ay, bx, by)

    return {
        jumpDistance = jumpDistance,
        credits = FIXED_CREDITS_FEE,
        ironAmount = FIXED_IRON_AMOUNT,
        triniumAmount = FIXED_TRINIUM_AMOUNT,
        xanionAmount = FIXED_XANION_AMOUNT,
        avorionAmount = FIXED_AVORION_AMOUNT,
    }
end

local function hasKnownSectorFor(player, buyer, x, y)
    if buyer and buyer.getKnownSector then
        local known = buyer:getKnownSector(x, y)
        if known then return true end
    end

    if player and player.getKnownSector then
        local known = player:getKnownSector(x, y)
        if known then return true end
    end

    if player and player.alliance and player.alliance.getKnownSector then
        local known = player.alliance:getKnownSector(x, y)
        if known then return true end
    end

    return false
end

local function isAtWarWithBuilder(x, y, builderFaction)
    if not builderFaction then return false end

    local controller = Galaxy():getControllingFaction(x, y)
    if not controller then return false end
    if controller.index == builderFaction.index then return false end

    local status = controller:getRelationStatus(builderFaction.index)
    return status == RelationStatus.War
end

local function validateEndpoints(ax, ay, bx, by)
    if not ax or not ay or not bx or not by then
        return false, "Select two endpoints first."%_T
    end

    if ax == bx and ay == by then
        return false, "A gate cannot connect a sector to itself."%_T
    end

    local map = GatesMap(Server().seed)
    local maxGateDistance = map.range or 45
    local d = distance2d(ax, ay, bx, by)

    if d > maxGateDistance then
        return false, "This route is too long. Maximum connection distance is ${max}."%_T % {max = maxGateDistance}
    end

    return true
end

local function isCoreResearchStation(station, buyer)
    if not station or not buyer then return false end
    if station.factionIndex ~= buyer.index then return false end

    local x, y = station:getCoordinates()
    return x == 0 and y == 0
end

local function hasLegendaryWormholePowerDiverter(station)
    if not station then return false end

    local systems = ShipSystem(station)
    if not systems or not systems.getUpgrades then return false end

    for upgrade, permanent in pairs(systems:getUpgrades()) do
        if upgrade
                and permanent == true
                and upgrade.rarity
                and upgrade.rarity.value == RarityType.Legendary
                and upgrade.script
                and (upgrade.script == "data/scripts/systems/wormholeopener.lua" or upgrade.script == "systems/wormholeopener.lua") then
            return true
        end
    end

    return false
end

function GateCommissionHub.interactionPossible(playerIndex, option)
    if not CheckFactionInteraction(playerIndex, GateCommissionHub.interactionThreshold) then
        return false
    end

    local player = Player(playerIndex)
    local station = Entity()
    if not player or not station then return false end

    local ownerOk = station.factionIndex == player.index
    if not ownerOk and player.alliance then
        ownerOk = station.factionIndex == player.alliance.index
    end
    if not ownerOk then return false end

    local x, y = station:getCoordinates()
    if x ~= 0 or y ~= 0 then return false end

    return hasLegendaryWormholePowerDiverter(station)
end

function GateCommissionHub.initUI()
    local res = getResolution()
    local size = vec2(560, 540)

    local menu = ScriptUI()
    local window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    menu:registerWindow(window, "Gate Commission"%_T, 10)

    window.caption = "Gate Construction Research"%_T
    window.showCloseButton = 1
    window.moveable = 1

    local lister = UIVerticalLister(Rect(vec2(10, 10), size - vec2(10, 10)), 10, 0)

    local introRect = lister:nextRect(82)
    ui.intro = window:createTextField(introRect,
        "Commissioning a gate is expensive and dangerous. Activating a new link attracts a large Xsotan wave. Prepare your fleet before the final activation."%_t)
    ui.intro.fontSize = 13
    ui.intro.fontColor = ColorRGB(0.7, 0.7, 0.7)

    local rowA = lister:nextRect(32)
    local rowALister = UIHorizontalLister(rowA, 10, 0)
    ui.labelA = window:createLabel(rowALister:nextRect(230), "Endpoint A: not selected"%_T, 12)
    ui.labelA:setLeftAligned()
    ui.pickA = window:createButton(rowALister.inner, "Use Galaxy Selection"%_T, "onPickA")

    local rowB = lister:nextRect(32)
    local rowBLister = UIHorizontalLister(rowB, 10, 0)
    ui.labelB = window:createLabel(rowBLister:nextRect(230), "Endpoint B: not selected"%_T, 12)
    ui.labelB:setLeftAligned()
    ui.pickB = window:createButton(rowBLister.inner, "Use Galaxy Selection"%_T, "onPickB")

    local rowMap = lister:nextRect(32)
    local rowMapLister = UIHorizontalLister(rowMap, 10, 0)
    ui.useCurrentA = window:createButton(rowMapLister:nextRect(170), "A = Current Sector"%_T, "onCurrentA")
    ui.useCurrentB = window:createButton(rowMapLister:nextRect(170), "B = Current Sector"%_T, "onCurrentB")
    ui.openMap = window:createButton(rowMapLister.inner, "Open Galaxy Map"%_T, "onOpenMap")

    local quoteFrame = lister:nextRect(250)
    window:createFrame(quoteFrame)
    local quoteLister = UIVerticalLister(quoteFrame, 8, 6)

    ui.quoteTitle = window:createLabel(quoteLister:nextRect(18), "Project Estimate"%_T, 13)
    ui.quoteTitle:setCenterAligned()

    ui.distanceLabel = window:createLabel(quoteLister:nextRect(18), "Route Distance: -"%_T, 12)
    ui.creditsLabel = window:createLabel(quoteLister:nextRect(18), "Credits Fee: -"%_T, 12)
    ui.resourcesLabel = window:createLabel(quoteLister:nextRect(18), "Material Downpayment: -"%_T, 12)
    ui.unlockLabel = window:createLabel(quoteLister:nextRect(18), "Wormhole Power Diverter: -"%_T, 12)
    ui.ruleLabel = window:createTextField(quoteLister:nextRect(66), "Rules: the station must be your own Research Station in sector 0:0, the station must have a permanently installed legendary Wormhole Power Diverter, and both endpoint sectors must be known."%_T)
    ui.ruleLabel.fontSize = 12
    ui.ruleLabel.fontColor = ColorRGB(0.75, 0.75, 0.75)
    ui.warningLabel = window:createLabel(quoteLister:nextRect(54), "Warning: canceling the mission refunds material downpayment only. Credits are never refunded."%_T, 12)
    ui.warningLabel.color = ColorRGB(0.95, 0.7, 0.35)

    local buttonRow = lister:nextRect(34)
    local btnLister = UIHorizontalLister(buttonRow, 10, 0)
    ui.refresh = window:createButton(btnLister:nextRect(200), "Refresh Quote"%_T, "onRefreshQuote")
    ui.start = window:createButton(btnLister.inner, "Commission Gate Project"%_T, "onStartProject")

    ui.selectedA = nil
    ui.selectedB = nil
end

function GateCommissionHub.onOpenMap()
    local x, y = Sector():getCoordinates()
    GalaxyMap():show(x, y)
end

local function selectedMapCoordinates()
    local map = GalaxyMap()
    if not map then return nil end

    local x, y = map:getSelectedCoordinates()
    if x == nil or y == nil then return nil end

    return x, y
end

local function updateEndpointLabels()
    if ui.selectedA then
        ui.labelA.caption = "Endpoint A: (${x}:${y})"%_T % ui.selectedA
    else
        ui.labelA.caption = "Endpoint A: not selected"%_T
    end

    if ui.selectedB then
        ui.labelB.caption = "Endpoint B: (${x}:${y})"%_T % ui.selectedB
    else
        ui.labelB.caption = "Endpoint B: not selected"%_T
    end
end

function GateCommissionHub.onPickA()
    local x, y = selectedMapCoordinates()
    if not x or not y then return end

    ui.selectedA = {x = x, y = y}
    updateEndpointLabels()
end

function GateCommissionHub.onPickB()
    local x, y = selectedMapCoordinates()
    if not x or not y then return end

    ui.selectedB = {x = x, y = y}
    updateEndpointLabels()
end

function GateCommissionHub.onCurrentA()
    local x, y = Sector():getCoordinates()
    ui.selectedA = {x = x, y = y}
    updateEndpointLabels()
end

function GateCommissionHub.onCurrentB()
    local x, y = Sector():getCoordinates()
    ui.selectedB = {x = x, y = y}
    updateEndpointLabels()
end

function GateCommissionHub.onRefreshQuote()
    if not ui.selectedA or not ui.selectedB then return end
    invokeServerFunction("requestQuote", ui.selectedA.x, ui.selectedA.y, ui.selectedB.x, ui.selectedB.y)
end

function GateCommissionHub.receiveQuote(ok, quote, err)
    if not ok then
        if err and err ~= "" then
            displayChatMessage(err, "Research Station"%_T, ChatMessageType.Error)
        end
        return
    end

    ui.distanceLabel.caption = "Route Distance: ${d}"%_T % {d = string.format("%.1f", quote.jumpDistance or 0)}
    ui.creditsLabel.caption = "Credits Fee: ¢${c}"%_T % {c = createMonetaryString(quote.credits or 0)}
    ui.resourcesLabel.caption = "Material Downpayment: ${iron} Iron + ${trinium} Trinium + ${xanion} Xanion + ${avorion} Avorion"%_T % {
        iron = quote.ironAmount or 0,
        trinium = quote.triniumAmount or 0,
        xanion = quote.xanionAmount or 0,
        avorion = quote.avorionAmount or 0,
    }
    if quote.hasWormholePowerDiverter == true then
        ui.unlockLabel.caption = "Wormhole Power Diverter: ✓ installed"%_T
    else
        ui.unlockLabel.caption = "Wormhole Power Diverter: ✗ missing"%_T
    end
end

function GateCommissionHub.onStartProject()
    if not ui.selectedA or not ui.selectedB then
        local d = Dialog.empty()
        d.text = "Select both endpoints first."%_T
        ScriptUI():showDialog(d)
        return
    end

    invokeServerFunction("startCommission", ui.selectedA.x, ui.selectedA.y, ui.selectedB.x, ui.selectedB.y)
end

function GateCommissionHub.commissionResult(ok, message)
    local d = Dialog.empty()
    d.text = message or ""

    if ok then
        ScriptUI():showDialog(d)
    else
        d.talker = "Research Station"%_T
        ScriptUI():showDialog(d)
    end
end

function GateCommissionHub.requestQuote(ax, ay, bx, by)
    local ok, err = validateEndpoints(ax, ay, bx, by)
    if not ok then
        invokeClientFunction(Player(callingPlayer), "receiveQuote", false, nil, err)
        return
    end

    local quote = computeQuote(ax, ay, bx, by)
    local station = Entity()
    quote.hasWormholePowerDiverter = hasLegendaryWormholePowerDiverter(station)
    invokeClientFunction(Player(callingPlayer), "receiveQuote", true, quote, "")
end
callable(GateCommissionHub, "requestQuote")

function GateCommissionHub.startCommission(ax, ay, bx, by)
    local player = Player(callingPlayer)
    if not player then return end

    if not CheckFactionInteraction(callingPlayer, GateCommissionHub.interactionThreshold) then
        invokeClientFunction(player, "commissionResult", false, "You don't have permission to commission this project."%_T)
        return
    end

    local station = Entity()

    local ok, err = validateEndpoints(ax, ay, bx, by)
    if not ok then
        invokeClientFunction(player, "commissionResult", false, err)
        return
    end

    local buyer, ship, interactingPlayer = getInteractingFaction(callingPlayer, AlliancePrivilege.SpendResources)
    if not buyer then
        invokeClientFunction(player, "commissionResult", false, "You are missing the privileges required to spend resources."%_T)
        return
    end

    local builderFaction = Faction(station.factionIndex)

    if not isCoreResearchStation(station, buyer) then
        invokeClientFunction(player, "commissionResult", false,
            "This gate project can only be commissioned from your own Research Station in sector 0:0."%_T)
        return
    end

    if not hasLegendaryWormholePowerDiverter(station) then
        invokeClientFunction(player, "commissionResult", false,
            "This Research Station needs a permanently installed legendary Wormhole Power Diverter before it can commission gate construction."%_T)
        return
    end

    if station:getValue("gate_construction_busy") then
        invokeClientFunction(player, "commissionResult", false, "This research station already has an active gate project in progress."%_T)
        return
    end

    if isAtWarWithBuilder(ax, ay, builderFaction) or isAtWarWithBuilder(bx, by, builderFaction) then
        invokeClientFunction(player, "commissionResult", false, "A controlling faction on one endpoint is at war with this research station's faction."%_T)
        return
    end

    if not hasKnownSectorFor(interactingPlayer or player, buyer, ax, ay) or not hasKnownSectorFor(interactingPlayer or player, buyer, bx, by) then
        invokeClientFunction(player, "commissionResult", false, "Both endpoint sectors must be scouted first."%_T)
        return
    end

    local quote = computeQuote(ax, ay, bx, by)
    local resources = makeResourceVector()

    local canPay, msg, args = buyer:canPay(quote.credits, unpack(resources))
    if not canPay then
        invokeClientFunction(player, "commissionResult", false, (msg or "Insufficient funds."%_T), unpack(args or {}))
        return
    end

    buyer:pay("Paid gate construction downpayment."%_T, quote.credits, unpack(resources))

    local scriptIndex = player:addScript("data/scripts/player/missions/gateconstruction.lua",
        station.index.string,
        station.factionIndex,
        buyer.index,
        ax, ay,
        bx, by,
        quote.credits,
        quote.ironAmount,
        quote.triniumAmount,
        quote.xanionAmount,
        quote.avorionAmount)

    if not scriptIndex then
        buyer:receive("Refunded gate construction downpayment."%_T, quote.credits, unpack(resources))
        invokeClientFunction(player, "commissionResult", false, "Could not start the gate construction mission."%_T)
        return
    end

    station:setValue("gate_construction_busy", true)

    invokeClientFunction(player, "commissionResult", true,
        "Contract signed. The gate will be active in 5 minutes. Expect a Xsotan assault near sector 0:0 upon completion. Track your mission objectives for next steps."%_T)
end
callable(GateCommissionHub, "startCommission")
