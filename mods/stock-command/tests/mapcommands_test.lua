local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/tests/[^/]+$") or "."
local SCRIPT = root .. "/data/scripts/player/map/mapcommands.lua"

CommandType = {StockFactory = "stock-factory"}

local failures = 0
local function check(label, condition)
    if condition then
        print("  PASS  " .. label)
    else
        failures = failures + 1
        print("  FAIL  " .. label)
    end
end

print("\n[map command sorting]")
local sortedCommands
MapCommands = {}
MapCommands.initUI = function()
    local order = {known = 1}
    local commands = {CommandType.StockFactory, "known"}
    table.sort(commands, function(left, right) return order[left] < order[right] end)
    sortedCommands = commands
end
dofile(SCRIPT)

local ok = pcall(MapCommands.initUI)
check("unknown stock command receives fallback ordering",
    ok and sortedCommands and sortedCommands[1] == "known" and sortedCommands[2] == CommandType.StockFactory)

MapCommands = {}
MapCommands.initUI = function()
    local unrelated = {"broken", "known"}
    table.sort(unrelated, function(left, right)
        local order = {known = 1}
        return order[left] < order[right]
    end)
end
dofile(SCRIPT)

check("unrelated comparator failures still surface", not pcall(MapCommands.initUI))

if failures > 0 then
    error(string.format("%d map command test(s) failed", failures))
end

print("\nAll map command tests passed.")
