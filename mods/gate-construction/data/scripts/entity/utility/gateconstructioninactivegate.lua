package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("stringutility")
include("callable")

-- namespace GateConstructionInactiveGate
GateConstructionInactiveGate = {}

if onClient() then

function GateConstructionInactiveGate.initUI()
    ScriptUI():registerInteraction("Initialize Activation"%_t, "onInitializeActivation")
end

function GateConstructionInactiveGate.onInitializeActivation()
    invokeServerFunction("onInitializeActivation")
end

end

if onServer() then

function GateConstructionInactiveGate.onInitializeActivation()
    local entity = Entity()
    if not valid(entity) or not entity:getValue("gate_construction_inactive_gate") then return end

    local missionScript = entity:getValue("gate_construction_mission_script")
    local missionId = entity:getValue("gate_construction_mission_id")
    if not missionScript or not missionId then return end

    Player(callingPlayer):invokeFunction(missionScript, "requestActivation", entity.index)
end

callable(GateConstructionInactiveGate, "onInitializeActivation")

end