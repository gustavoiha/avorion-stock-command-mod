-- Offline harness for lib/gateinfluence.lua.
--
-- Stubs the Avorion engine globals and runs the REAL library file, so the weight math,
-- the BFS and the weighted faction draw can be verified without launching the game.
-- This folder is outside data/, so the game never loads it.
--
-- Run from anywhere:  luajit mods/gate-construction/tests/gateinfluence_test.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)/tests/[^/]+$") or "."
local LIB = root .. "/data/scripts/lib/gateinfluence.lua"

-- ---- engine stubs --------------------------------------------------------
local store = {}
local owners = {}

function Server()
    return {
        seed = 1,
        getValue = function(_, k) return store[k] end,
        setValue = function(_, k, v) store[k] = v end,
    }
end

function Galaxy()
    return {
        getControllingFaction = function(_, x, y)
            local idx = owners[x .. ":" .. y]
            if not idx then return nil end
            return {index = idx, name = "Faction" .. idx, isAIFaction = true}
        end,
        getLocalFaction = function() return nil end,
    }
end

function vec2(x, y) return {x = x, y = y} end

function distance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

function Balancing_InsideRing(x, y) return math.sqrt(x * x + y * y) < 150 end

-- Deterministic when `forcedRoll` is set (a 0..1 fraction of the range), else uniform.
local forcedRoll = nil
function random()
    return {
        getFloat = function(_, lo, hi)
            local t = forcedRoll or math.random()
            return lo + t * (hi - lo)
        end,
    }
end

local modLinks = {}

local function normalizeKey(ax, ay, bx, by)
    if ax > bx or (ax == bx and ay > by) then ax, ay, bx, by = bx, by, ax, ay end
    return string.format("%i:%i>%i:%i", ax, ay, bx, by)
end

local stubs = {
    gateconstructionlinks = {
        key = normalizeKey,
        getAll = function() return modLinks end,
    },
    gatesmap = setmetatable({}, {__call = function()
        return {
            hasGates = function() return false end,
            getConnectedSectors = function() return {} end,
        }
    end}),
}

function include(name) return stubs[name] end

local GateInfluence = dofile(LIB)

-- ---- helpers -------------------------------------------------------------
local function reset()
    store, owners, modLinks, forcedRoll = {}, {}, {}, nil
end

local function link(ax, ay, bx, by) modLinks[normalizeKey(ax, ay, bx, by)] = true end
local function own(x, y, idx) owners[x .. ":" .. y] = idx end

local function find(list, idx)
    for _, e in ipairs(list) do if e.factionIndex == idx then return e end end
end

local failures = 0
local function check(label, cond, detail)
    if cond then
        print("  PASS  " .. label)
    else
        failures = failures + 1
        print("  FAIL  " .. label .. (detail and ("  -> " .. detail) or ""))
    end
end

local function approx(a, b, tolerance) return math.abs(a - b) < (tolerance or 0.0001) end

-- ==========================================================================
-- getSectorInfluence
-- ==========================================================================

print("\n[3] regression: gate LENGTH must never affect weight")
reset()
link(0, 0, 5, 0);  own(5, 0, 101)
link(0, 0, 45, 0); own(45, 0, 202)
local inf = GateInfluence.getSectorInfluence(0, 0)
local short, long = find(inf, 101), find(inf, 202)
check("5-sector gate reaches its faction", short ~= nil)
check("45-sector gate reaches its faction", long ~= nil)
if short and long then
    check("both are exactly 1 hop", short.hops == 1 and long.hops == 1,
        "short=" .. short.hops .. " long=" .. long.hops)
    check("IDENTICAL weights regardless of length", approx(short.weight, long.weight),
        string.format("short=%.4f long=%.4f", short.weight, long.weight))
    check("weight is HopWeight[1] = 0.70", approx(short.weight, 0.70),
        string.format("%.4f", short.weight))
end

print("\n[2] 2-link chain with an empty middle relay sector")
reset()
own(0, 0, 1); own(90, 0, 2)                  -- (45,0) is a pure relay, unowned
link(0, 0, 45, 0); link(45, 0, 90, 0)
local mid = GateInfluence.getSectorInfluence(45, 0)
local m1, m2 = find(mid, 1), find(mid, 2)
check("middle sees both end factions", m1 ~= nil and m2 ~= nil)
if m1 and m2 then
    check("both at hop 1, weight 0.70",
        m1.hops == 1 and m2.hops == 1 and approx(m1.weight, 0.70) and approx(m2.weight, 0.70),
        string.format("f1=%i/%.2f f2=%i/%.2f", m1.hops, m1.weight, m2.hops, m2.weight))
end
local far = find(GateInfluence.getSectorInfluence(0, 0), 2)
check("far endpoint seen at hop 2, weight 0.40",
    far ~= nil and far.hops == 2 and approx(far.weight, 0.40),
    far and string.format("hops=%i w=%.2f", far.hops, far.weight) or "absent")

print("\n[4/5] three 45-sector hops reach 135 sectors; 4 hops must not")
reset()
link(0, 0, 45, 0); link(45, 0, 90, 0); link(90, 0, 135, 0); link(135, 0, 180, 0)
own(135, 0, 3); own(180, 0, 4)
local chain = GateInfluence.getSectorInfluence(0, 0)
local h3, h4 = find(chain, 3), find(chain, 4)
check("faction 135 sectors away arrives at hop 3, weight 0.15",
    h3 ~= nil and h3.hops == 3 and approx(h3.weight, 0.15),
    h3 and string.format("hops=%i w=%.2f", h3.hops, h3.weight) or "absent")
check("faction at 4 hops is ABSENT (MaxHops holds)", h4 == nil,
    h4 and ("leaked in at hop " .. h4.hops) or nil)

print("\n[5b] spill falloff away from the arrival gate")
reset()
link(0, 0, 45, 0); own(45, 0, 7)
local at0 = find(GateInfluence.getSectorInfluence(0, 0), 7)
local at8 = find(GateInfluence.getSectorInfluence(8, 0), 7)
local at17 = find(GateInfluence.getSectorInfluence(17, 0), 7)
local at18 = find(GateInfluence.getSectorInfluence(18, 0), 7)
check("at the gate: 0.70", at0 and approx(at0.weight, 0.70),
    at0 and string.format("%.4f", at0.weight) or "absent")
check("8 sectors away: 0.70*(1-8/17) = 0.3706",
    at8 and approx(at8.weight, 0.70 * (1 - 8 / 17)),
    at8 and string.format("%.4f", at8.weight) or "absent")
check("exactly 17 sectors away: zero (absent)", at17 == nil,
    at17 and string.format("%.4f", at17.weight) or nil)
check("18 sectors away: zero (absent)", at18 == nil,
    at18 and string.format("%.4f", at18.weight) or nil)

print("\n[sanity] graph-free galaxy behaves exactly like vanilla")
reset()
check("no gates -> empty influence list", #GateInfluence.getSectorInfluence(0, 0) == 0)

print("\n[sanity] results sorted strongest first")
reset()
link(0, 0, 45, 0); own(45, 0, 1)
link(45, 0, 90, 0); own(90, 0, 2)
local sorted = GateInfluence.getSectorInfluence(0, 0)
check("descending weight order",
    #sorted >= 2 and sorted[1].weight >= sorted[2].weight,
    #sorted >= 2 and string.format("%.2f then %.2f", sorted[1].weight, sorted[2].weight) or "too few")

-- ==========================================================================
-- rollForeignFaction  (decides the faction of every trader / passing ship)
-- ==========================================================================

print("\n[roll] weighted draw against the local faction")

check("empty influence -> nil (vanilla untouched)",
    GateInfluence.rollForeignFaction({}, 5) == nil)

check("influence containing ONLY the local faction -> nil",
    GateInfluence.rollForeignFaction({{factionIndex = 5, weight = 0.70}}, 5) == nil)

local single = {{factionIndex = 9, weight = 0.70}}   -- total = LocalWeight 1.0 + 0.70 = 1.70

forcedRoll = 0.50                                     -- 0.85 - 1.0 < 0 -> local wins
check("low roll keeps the local faction", GateInfluence.rollForeignFaction(single, 5) == nil)

forcedRoll = 0.90                                     -- 1.53 - 1.0 > 0 -> foreign wins
local picked = GateInfluence.rollForeignFaction(single, 5)
check("high roll returns the gate-borne faction",
    picked ~= nil and picked.factionIndex == 9,
    picked and tostring(picked.factionIndex) or "nil")

forcedRoll = 1.0                                      -- extreme edge must still resolve
check("maximum roll still resolves to a faction (no nil fallthrough)",
    GateInfluence.rollForeignFaction(single, 5) ~= nil)

forcedRoll = nil
math.randomseed(20240607)

local samples = 40000
local hits = 0
for _ = 1, samples do
    if GateInfluence.rollForeignFaction(single, 5) then hits = hits + 1 end
end
local rate = hits / samples
check(string.format("one 0.70 faction wins ~41.2%% of draws (got %.1f%%)", rate * 100),
    approx(rate, 0.70 / 1.70, 0.015))

local pair = {{factionIndex = 9, weight = 0.70}, {factionIndex = 11, weight = 0.40}}
local counts = {[9] = 0, [11] = 0, local_ = 0}
for _ = 1, samples do
    local e = GateInfluence.rollForeignFaction(pair, 5)
    if e then counts[e.factionIndex] = counts[e.factionIndex] + 1 else counts.local_ = counts.local_ + 1 end
end
check(string.format("stronger faction ~33.3%% (got %.1f%%)", counts[9] / samples * 100),
    approx(counts[9] / samples, 0.70 / 2.10, 0.015))
check(string.format("weaker faction ~19.0%% (got %.1f%%)", counts[11] / samples * 100),
    approx(counts[11] / samples, 0.40 / 2.10, 0.015))
check(string.format("local still wins ~47.6%% (got %.1f%%)", counts.local_ / samples * 100),
    approx(counts.local_ / samples, 1.00 / 2.10, 0.015))

-- ==========================================================================
-- getTraderCandidates  (what the in-game debug readout shows on sector entry)
-- ==========================================================================

print("\n[candidates] displayed odds must match the actual roll")

reset()
local none = GateInfluence.getTraderCandidates(0, 0, 5)
check("no gates -> local faction is certain",
    #none.foreign == 0 and approx(none.localProbability, 1.0),
    string.format("%i foreign, local=%.3f", #none.foreign, none.localProbability))

reset()
link(0, 0, 45, 0); own(45, 0, 9)
local one = GateInfluence.getTraderCandidates(0, 0, 5)
check("one 0.70 faction -> local 58.8%, foreign 41.2%",
    #one.foreign == 1
        and approx(one.localProbability, 1.00 / 1.70)
        and approx(one.foreign[1].probability, 0.70 / 1.70),
    string.format("local=%.3f foreign=%.3f", one.localProbability,
        #one.foreign > 0 and one.foreign[1].probability or -1))
check("displayed foreign odds equal the measured roll rate (41.4%)",
    #one.foreign > 0 and approx(one.foreign[1].probability, rate, 0.015))

local sum = one.localProbability
for _, e in ipairs(one.foreign) do sum = sum + e.probability end
check("probabilities sum to 1", approx(sum, 1.0), string.format("%.4f", sum))

reset()
link(0, 0, 45, 0); own(45, 0, 7)
local selfOwned = GateInfluence.getTraderCandidates(0, 0, 7)
check("gate faction that IS the local faction is excluded (matches the roll)",
    #selfOwned.foreign == 0 and approx(selfOwned.localProbability, 1.0),
    string.format("%i foreign", #selfOwned.foreign))

-- ==========================================================================
-- getCrossBarrierFactions  (decides who sends the thank-you gift)
-- ==========================================================================

print("\n[barrier] thank-you trigger: reaching the far side within 3 hops")

local function crossing()
    local set = GateInfluence.getCrossBarrierFactions()
    local list = {}
    for index, _ in pairs(set) do table.insert(list, index) end
    table.sort(list)
    return set, table.concat(list, ",")
end

reset()
link(140, 0, 160, 0); own(140, 0, 1); own(160, 0, 2)
local crossed, crossedLabel = crossing()
check("a 1-hop crossing credits BOTH sides", crossed[1] and crossed[2], crossedLabel)

reset()
link(0, 0, 45, 0); own(0, 0, 1); own(45, 0, 2)
local _, sameSide = crossing()
check("two factions on the SAME side never trigger", sameSide == "", sameSide)

reset()
link(0, 0, 40, 0); link(40, 0, 80, 0); link(80, 0, 120, 0); link(120, 0, 160, 0)
own(0, 0, 1); own(160, 0, 2)
local _, tooFar = crossing()
check("a crossing that needs 4 hops does NOT trigger", tooFar == "", tooFar)

link(0, 0, 80, 0)   -- shortcut: the very same pair now sits 3 hops apart
local shortened, shortenedLabel = crossing()
check("a later gate shortening 4 hops to 3 DOES trigger",
    shortened[1] and shortened[2], shortenedLabel)

print("")
if failures == 0 then
    print("ALL INFLUENCE TESTS PASSED")
else
    print(failures .. " TEST(S) FAILED")
    os.exit(1)
end
