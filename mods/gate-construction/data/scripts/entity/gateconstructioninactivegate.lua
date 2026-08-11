package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("callable")
include("stringutility")
include("utility")
include("faction")
include("galaxy")

local Dialog = include("dialogutility")
local GateConstructionGates = include("gateconstructiongates")
local GateConstructionLinks = include("gateconstructionlinks")
local GateConstructionMap = include("gateconstructionmap")
local GateInfluence = include("gateinfluence")
local GateDiplomacy = include("gatediplomacy")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in.
-- namespace GateConstructionInactiveGate
GateConstructionInactiveGate = {}

local KEY_NAME = "XSTN-K I"

local ActivationKeyScripts = {
    ["data/scripts/systems/teleporterkey1.lua"] = true,
    ["systems/teleporterkey1.lua"] = true,
}

local ui = {}

local function targetCoordinates()
    local entity = Entity()

    local tx = entity:getValue("gate_construction_target_x")
    local ty = entity:getValue("gate_construction_target_y")
    if tx == nil or ty == nil then return nil end

    return tx, ty
end

local function interactingCraft(playerIndex)
    local player = Player(playerIndex)
    if not player then return nil end

    return Sector():getEntity(player.craftIndex)
end

local function hasActivationKey(craft)
    if not craft then return false end

    local systems = ShipSystem(craft)
    if not systems or not systems.getUpgrades then return false end

    for upgrade, _ in pairs(systems:getUpgrades()) do
        if upgrade and upgrade.script and ActivationKeyScripts[upgrade.script] then
            return true
        end
    end

    return false
end

function GateConstructionInactiveGate.initialize()
    if onServer() then
        Entity():setValue("ai_no_attack", true)
    end

    if onClient() then
        if EntityIcon().icon == "" then
            EntityIcon().icon = "data/textures/icons/pixel/gate.png"
        end
    end
end

function GateConstructionInactiveGate.interactionPossible(playerIndex, option)
    return true
end

function GateConstructionInactiveGate.getUpdateInterval()
    return 5
end

-- Gates built by an older version of the mod are replaced once so they pick up descriptor
-- changes. The version marker is carried by the new entity, so this can never loop.
local function rebuildOutdatedGate()
    local entity = Entity()

    local version = entity:getValue("gate_construction_gate_version") or 1
    if version >= GateConstructionGates.InactiveVersion then return false end

    local tx, ty = targetCoordinates()
    if not tx then return false end

    local rebuilt = GateConstructionGates.createInactive(
        entity:getValue("gate_construction_builder_faction") or entity.factionIndex,
        tx, ty, entity:getValue("gate_construction_commissioner"))

    if not valid(rebuilt) then return false end

    Sector():deleteEntity(entity)

    return true
end

-- The counterpart gate may have been activated while this sector was unloaded, or while
-- it was loaded but out of reach of the activating player. Both cases converge here.
function GateConstructionInactiveGate.updateServer()
    local tx, ty = targetCoordinates()
    if not tx then return end

    local x, y = Sector():getCoordinates()
    if not GateConstructionLinks.exists(x, y, tx, ty) then
        rebuildOutdatedGate()
        return
    end

    GateConstructionInactiveGate.convertToActiveGate()
end

-- The engine cannot add components to an existing entity, so the inactive hull is replaced
-- by a real gate built from the same seed, plan and position.
function GateConstructionInactiveGate.convertToActiveGate()
    local entity = Entity()

    local tx, ty = targetCoordinates()
    if not tx then return false end

    local factionIndex = entity:getValue("gate_construction_builder_faction") or entity.factionIndex

    local gate = GateConstructionGates.createActive(factionIndex, tx, ty)
    if not valid(gate) then return false end

    Sector():deleteEntity(entity)

    return true
end

-- Everything the finished link is worth: the real gate connection, map entries, network
-- influence and the faction thank-you gifts. None of it happens before activation.
function GateConstructionInactiveGate.registerActivation(activatingPlayerIndex)
    local entity = Entity()

    local tx, ty = targetCoordinates()
    if not tx then return end

    local x, y = Sector():getCoordinates()
    if GateConstructionLinks.exists(x, y, tx, ty) then return end

    GateConstructionLinks.add(x, y, tx, ty)
    GateConstructionLinks.removePending(x, y, tx, ty)

    local commissioner = entity:getValue("gate_construction_commissioner")

    GateConstructionMap.markActiveLink({activatingPlayerIndex, commissioner}, x, y, tx, ty)
    GateInfluence.onLinkCompleted(x, y, tx, ty)
    -- The gifts follow the player who paid for the project, not whoever happened to be
    -- carrying the key.
    GateDiplomacy.onLinkCompleted(commissioner or activatingPlayerIndex)
end

function GateConstructionInactiveGate.requestStatus()
    local player = Player(callingPlayer)
    if not player then return end

    local tx, ty = targetCoordinates()

    invokeClientFunction(player, "receiveStatus", tx, ty,
        hasActivationKey(interactingCraft(callingPlayer)))
end
callable(GateConstructionInactiveGate, "requestStatus")

function GateConstructionInactiveGate.activate()
    local player = Player(callingPlayer)
    if not player then return end

    local tx, ty = targetCoordinates()
    if not tx then
        invokeClientFunction(player, "activationResult", false,
            "This gate is not linked to any sector."%_T)
        return
    end

    if not hasActivationKey(interactingCraft(callingPlayer)) then
        invokeClientFunction(player, "activationResult", false,
            "Your ship needs an installed ${key} to activate this gate."%_T % {key = KEY_NAME})
        return
    end

    local x, y = Sector():getCoordinates()

    GateConstructionInactiveGate.registerActivation(callingPlayer)

    -- Answer before the conversion: this entity and its script are gone right after.
    invokeClientFunction(player, "activationResult", true,
        "The gate is online. It now connects (${ax}:${ay}) and (${bx}:${by})."%_T
            % {ax = x, ay = y, bx = tx, by = ty})

    GateConstructionInactiveGate.convertToActiveGate()
end
callable(GateConstructionInactiveGate, "activate")

function GateConstructionInactiveGate.initUI()
    local res = getResolution()
    local size = vec2(500, 320)

    local menu = ScriptUI()
    local window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    menu:registerWindow(window, "Inactive Gate"%_t, 10)

    window.caption = "Inactive Gate"%_t
    window.showCloseButton = 1
    window.moveable = 1

    local lister = UIVerticalLister(Rect(vec2(10, 10), size - vec2(10, 10)), 10, 0)

    ui.info = window:createTextField(lister:nextRect(150), "")
    ui.info.fontSize = 13
    ui.info.fontColor = ColorRGB(0.7, 0.7, 0.7)

    ui.keyLabel = window:createLabel(lister:nextRect(20), "", 13)
    ui.keyLabel:setLeftAligned()

    ui.errorLabel = window:createTextField(lister:nextRect(40), "")
    ui.errorLabel.fontSize = 13
    ui.errorLabel.fontColor = ColorRGB(0.95, 0.25, 0.25)

    ui.activate = window:createButton(lister:nextRect(34), "Activate Gate"%_t, "onActivate")
    ui.activate.active = false
end

function GateConstructionInactiveGate.onShowWindow()
    invokeServerFunction("requestStatus")
end

function GateConstructionInactiveGate.receiveStatus(tx, ty, hasKey)
    if tx and ty then
        ui.info.text = "This gate is built but inert. Its counterpart stands in sector (${x}:${y}).\n\nActivating it requires a ship with an installed ${key}. Both gates come online at once."%_t
            % {x = tx, y = ty, key = KEY_NAME}
    else
        ui.info.text = "This gate is built but inert, and no longer knows where it was meant to lead."%_t
    end

    if hasKey == true then
        ui.keyLabel.caption = "${key}: ✓ installed"%_t % {key = KEY_NAME}
        ui.keyLabel.color = ColorRGB(0.55, 0.85, 1.0)
    else
        ui.keyLabel.caption = "${key}: ✗ missing"%_t % {key = KEY_NAME}
        ui.keyLabel.color = ColorRGB(0.95, 0.7, 0.35)
    end

    ui.errorLabel.text = ""
    ui.activate.active = hasKey == true and tx ~= nil
end

function GateConstructionInactiveGate.onActivate()
    ui.activate.active = false
    ui.errorLabel.text = ""
    invokeServerFunction("activate")
end

function GateConstructionInactiveGate.activationResult(ok, message)
    if ok then
        local dialog = Dialog.empty()
        dialog.text = message or ""
        dialog.talker = "Gate Control"%_t
        ScriptUI():showDialog(dialog)
        return
    end

    ui.errorLabel.text = message or ""
    ui.activate.active = true
end
