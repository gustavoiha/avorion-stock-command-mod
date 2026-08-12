-- Offline test for the optimal production capacity math.
-- Run with: luajit tests/optimalcapacity_test.lua
--
-- Stubs the few engine globals the script touches at load time, then dofile()s
-- the real production script so the test can never drift from the shipped code.

local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/tests/[^/]+$") or "."
local scriptPath = root .. "/data/scripts/player/ui/productioncapacitystats.lua"

package = package or {}
package.path = package.path or ""

function include() end
function onServer() return false end
function onClient() return false end

-- name -> {price, level}, taken from the Avorion wiki's factory table
goods = {
    ["Aluminum"] = {price = 200, level = 0},
    ["Coal"] = {price = 200, level = 0},
    ["Corn"] = {price = 28, level = 1},
    ["Oxygen"] = {price = 80, level = 0},
    ["Book"] = {price = 319, level = 3},
    ["Chemicals"] = {price = 402, level = 3},
    ["Adhesive"] = {price = 402, level = 3},
    ["Coolant"] = {price = 402, level = 3},
    ["Solvent"] = {price = 402, level = 3},
    ["Acid"] = {price = 402, level = 3},
    ["Helium"] = {price = 50, level = 0},
    ["Hydrogen"] = {price = 150, level = 0},
    ["Neon"] = {price = 200, level = 0},
    ["Chlorine"] = {price = 150, level = 0},
}

dofile(scriptPath)

local failures = 0

local function check(name, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAIL %s: expected %s, got %s", name, tostring(expected), tostring(actual)))
    else
        print(string.format("ok   %s = %s", name, tostring(actual)))
    end
end

local function required(name, results)
    local optimal = ProductionCapacityStats.getOptimalCapacity({results = results})
    return ProductionCapacityStats.getRequiredCapacity(optimal)
end

-- expected values are the "Production Capacity cap v2.0" column of
-- https://avorion.fandom.com/wiki/Optimal_factory_production_capacity
check("Aluminum Mine", required("Aluminum Mine", {
    {name = "Aluminum", amount = 10},
}), 134)

check("Coal Mine (below the 100 baseline)", required("Coal Mine", {
    {name = "Coal", amount = 4},
}), 0)

check("Book Factory (below the 100 baseline)", required("Book Factory", {
    {name = "Book", amount = 4},
}), 0)

check("Corn Farm", required("Corn Farm", {
    {name = "Corn", amount = 60},
    {name = "Oxygen", amount = 4},
}), 133)

check("Chemical Factory", required("Chemical Factory", {
    {name = "Chemicals", amount = 2},
    {name = "Adhesive", amount = 1},
    {name = "Coolant", amount = 2},
    {name = "Solvent", amount = 2},
    {name = "Acid", amount = 2},
}), 235)

check("Gas Collector", required("Gas Collector", {
    {name = "Helium", amount = 3},
    {name = "Hydrogen", amount = 3},
    {name = "Neon", amount = 3},
    {name = "Chlorine", amount = 3},
}), 110)

-- garbage counts towards both the value and the average level
local withGarbage = ProductionCapacityStats.getOptimalCapacity({
    results = {{name = "Aluminum", amount = 10}},
    garbages = {{name = "Coal", amount = 4}},
})
check("garbage is included", ProductionCapacityStats.getRequiredCapacity(withGarbage), 187)

-- non-producing craft
check("no production", ProductionCapacityStats.getOptimalCapacity(nil), nil)
check("empty production", ProductionCapacityStats.getOptimalCapacity({results = {}}), nil)

-- the baseline is a floor, not an addend
check("exactly at the baseline", ProductionCapacityStats.getRequiredCapacity(100), 0)
check("just above the baseline", ProductionCapacityStats.getRequiredCapacity(100.5), 101)

check("cycle time uses the free baseline", ProductionCapacityStats.getCycleTimeSeconds(134, 40), 20)
check("cycle time is capped at the minimum", ProductionCapacityStats.getCycleTimeSeconds(134, 200), 15)
check("cycle time truncates instead of rounding", ProductionCapacityStats.getCycleTimeSeconds(110, 101), 16)

if failures > 0 then
    print(string.format("\n%d test(s) failed", failures))
    os.exit(1)
end

print("\nall tests passed")
