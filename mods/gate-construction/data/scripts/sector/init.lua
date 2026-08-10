-- Attaches passing traffic to gate relay sectors.
-- SectorGenerator:addAmbientEvents() only runs for generated faction sectors, so an empty
-- sector that exists purely as a gate junction would otherwise never see any traffic.

-- Vanilla sector/init.lua sets no package.path, and injection shares its chunk, so
-- include() cannot find anything under lib/ until we add it ourselves.
package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

if onServer() then

local GateInfluence = include("gateinfluence")

local sector = Sector()
local x, y = sector:getCoordinates()

if GateInfluence.isNode(x, y) then
    sector:addScriptOnce("sector/passingships.lua")
end

end
