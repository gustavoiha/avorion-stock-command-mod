-- Galactic Core Distance Label mod extension for the player init bootstrap.
-- Injected into vanilla player/init.lua.

if onServer() then
	Player():addScriptOnce("map/coredistancelabel.lua")
end
