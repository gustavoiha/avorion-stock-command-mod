-- Gate Construction mod extension for Research Station.
-- This name-clashes with vanilla researchstation.lua and is injected before return.

if onServer() then
    local originalInitialize = ResearchStation.initialize

    function ResearchStation.initialize(...)
        if type(originalInitialize) == "function" then
            originalInitialize(...)
        end

        local station = Entity()
        if valid(station) then
            station:addScriptOnce("data/scripts/entity/merchants/gatecommissionhub.lua")
        end
    end
end
