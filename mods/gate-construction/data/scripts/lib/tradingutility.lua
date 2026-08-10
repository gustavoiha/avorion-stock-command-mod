-- Lets gate-connected factions send real trading ships, not just passing traffic.
-- Vanilla picks the trader's faction with a single Galaxy():getNearestFaction call at the
-- top of spawnTrader. Rather than duplicating that ~90-line function (it carries the actual
-- buyGoods/sellGoods calls), we swap the Galaxy global for one synchronous call.
-- This injection is appended to the SAME chunk as spawnTrader, so it shares that chunk's
-- _ENV: assigning Galaxy here is exactly the binding spawnTrader reads. Avorion is Lua
-- 5.2.1, where setfenv/getfenv do not exist, so this is the portable way to do it.
-- Wrapping also keeps vanilla's eradicated_factions and "at war -> don't trade" checks.

if onServer() then

local GateInfluence = include("gateinfluence")

local vanillaSpawnTrader = TradingUtility.spawnTrader
local realGalaxy = Galaxy

local pendingFaction = nil

-- Globals must be writable for the swap to work at all; prove it before relying on it.
local canSwap = false
do
    local sentinel = function() end
    local saved = Galaxy

    local ok = pcall(function() Galaxy = sentinel end)
    canSwap = ok and Galaxy == sentinel

    Galaxy = saved
end

-- Only getNearestFaction is ever reached by spawnTrader; the rest is a passthrough safety net.
local function galaxyProxy()
    local real = realGalaxy()

    return setmetatable({}, {
        __index = function(_, key)
            if key == "getNearestFaction" then
                return function() return pendingFaction end
            end

            local value = real[key]
            if type(value) ~= "function" then return value end

            return function(_, ...) return value(real, ...) end
        end,
    })
end

local function shadowedGalaxy()
    if not pendingFaction then return realGalaxy() end
    return galaxyProxy()
end

local function pickFaction()
    local x, y = Sector():getCoordinates()

    local influence = GateInfluence.getSectorInfluence(x, y)
    if #influence == 0 then return end

    local localFaction = realGalaxy():getNearestFaction(x, y)
    local chosen = GateInfluence.rollForeignFaction(influence, localFaction and localFaction.index)
    if not chosen then return end

    return Faction(chosen.factionIndex)
end

function TradingUtility.spawnTrader(trade, namespace, immediateTransaction)
    if not canSwap then
        return vanillaSpawnTrader(trade, namespace, immediateTransaction)
    end

    local faction = pickFaction()
    if not faction then
        return vanillaSpawnTrader(trade, namespace, immediateTransaction)
    end

    pendingFaction = faction
    Galaxy = shadowedGalaxy

    local ok, err = pcall(vanillaSpawnTrader, trade, namespace, immediateTransaction)

    Galaxy = realGalaxy
    pendingFaction = nil

    if not ok then error(err, 0) end
end

end
