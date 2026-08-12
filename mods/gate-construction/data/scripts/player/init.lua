-- Gate Construction mod extension for player init bootstrap.
-- Injected into vanilla player/init.lua.

if onServer() then
	local player = Player()
	player:addScriptOnce("background/gateconstructionloremail.lua")
	player:addScriptOnce("map/gateconstructiongatemap.lua")

	if not player:getValue("gate_construction_map_entries_repaired_v3") then
		package.path = package.path .. ";data/scripts/lib/?.lua"

		local GateConstructionMap = include("gateconstructionmap")

		GateConstructionMap.repairLegacyMarkers({player.index})
		player:setValue("gate_construction_map_entries_repaired_v3", true)
	end
end
