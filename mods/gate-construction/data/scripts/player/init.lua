-- Gate Construction mod extension for player init bootstrap.
-- Injected into vanilla player/init.lua.

if onServer() then
	local player = Player()
	player:addScriptOnce("background/gateconstructionloremail.lua")
end
