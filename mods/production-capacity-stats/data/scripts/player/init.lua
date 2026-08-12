-- Optimal Production Capacity Stats mod extension for the player init bootstrap.
-- Injected into vanilla player/init.lua.

if onServer() then
	Player():addScriptOnce("ui/productioncapacitystats.lua")
end
