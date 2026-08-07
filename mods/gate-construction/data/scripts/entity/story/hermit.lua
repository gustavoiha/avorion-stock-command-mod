package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

local originalSpawn = Hermit and Hermit.spawn

if type(originalSpawn) == "function" then
	function Hermit.spawn()
		local ship = originalSpawn()
		if valid(ship) then
			ship:addScriptOnce("data/scripts/entity/story/gateconstructionhermitcontact.lua")
		end
		return ship
	end

	if onServer() then
		local current = Entity()
		if valid(current) then
			current:addScriptOnce("data/scripts/entity/story/gateconstructionhermitcontact.lua")
		end
	end
else
	print("GateConstruction: hermit injection skipped because Hermit.spawn is not a function.")
end
