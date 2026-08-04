-- Gate Construction mod extension for Travel Hub.
-- This name-clashes with vanilla travelhub.lua and is injected before return.

if onServer() then
    local originalInitialize = TravelHub.initialize

    function TravelHub.initialize(...)
        if type(originalInitialize) == "function" then
            originalInitialize(...)
        end

        local station = Entity()
        if valid(station) then
            station:addScriptOnce("data/scripts/entity/merchants/gatecommissionhub.lua")
        end
    end
end
