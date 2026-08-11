-- Creates the two gate variants used by the gate-construction mod.
-- Both are built from the same seed, plan and position, so activating a gate replaces the
-- inactive one without moving it or changing how it looks.
-- Every function here runs inside the sector the gate belongs to.

package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("galaxy")
include("utility")
include("stringutility")

local PlanGenerator = include("plangenerator")
local StyleGenerator = include("internal/stylegenerator.lua")

local GateConstructionGates = {}

GateConstructionGates.InactiveScript = "data/scripts/entity/gateconstructioninactivegate.lua"
GateConstructionGates.GateScript = "data/scripts/entity/gate.lua"

-- Bumped whenever an inactive gate has to be rebuilt to pick up descriptor changes.
GateConstructionGates.InactiveVersion = 2

local function resolveFaction(factionIndex, x, y)
    return Faction(factionIndex) or Galaxy():getNearestFaction(x, y)
end

local function makeDescriptor(faction, tx, ty, x, y, ...)
    local desc = EntityDescriptor()
    desc:addComponents(
       ComponentType.Plan,
       ComponentType.BspTree,
       ComponentType.Intersection,
       ComponentType.Asleep,
       ComponentType.DamageContributors,
       ComponentType.BoundingSphere,
       ComponentType.PlanMaxDurability,
       ComponentType.Durability,
       ComponentType.BoundingBox,
       ComponentType.Velocity,
       ComponentType.Physics,
       ComponentType.Scripts,
       ComponentType.ScriptCallback,
       ComponentType.Title,
       ComponentType.Owner,
       ComponentType.FactionNotifier,
       ...
    )

    local styleGenerator = StyleGenerator(faction.index)
    local c1 = styleGenerator.factionDetails.baseColor
    local c2 = ColorRGB(0.25, 0.25, 0.25)
    local c3 = styleGenerator.factionDetails.paintColor
    c1 = ColorRGB(c1.r, c1.g, c1.b)
    c3 = ColorRGB(c3.r, c3.g, c3.b)

    local plan = PlanGenerator.makeGatePlan(Seed(faction.index) + Server().seed, c1, c2, c3)

    local dir = vec3(tx - x, 0, ty - y)
    if dir.x == 0 and dir.z == 0 then
        dir = vec3(1, 0, 0)
    else
        normalize_ip(dir)
    end

    local position = MatrixLookUp(dir, vec3(0, 1, 0))
    position.pos = dir * 3000

    desc:setMovePlan(plan)
    desc.position = position
    desc.factionIndex = faction.index
    desc.invincible = true

    return desc
end

-- A dead gate hull: it carries no WormHole, so nothing can travel through it until a
-- player activates it and it is replaced by the real thing.
function GateConstructionGates.createInactive(factionIndex, tx, ty, commissioningPlayerIndex)
    local x, y = Sector():getCoordinates()

    local faction = resolveFaction(factionIndex, x, y)
    if not faction then return nil end

    local desc = makeDescriptor(faction, tx, ty, x, y, ComponentType.InteractionText)

    -- A vanilla gate is typed EntityType.WormHole through the WormHole component this one
    -- deliberately lacks. Left untyped the client gives it no icon and strategy mode, which
    -- draws entities from those icons, skips it entirely.
    desc.type = EntityType.Unknown
    desc.title = "Inactive Gate"%_T

    local gate = Sector():createEntity(desc)
    if not valid(gate) then return nil end

    -- Set before the script is attached so its initialize() already sees them.
    gate:setValue("gate_construction_inactive_gate", true)
    gate:setValue("gate_construction_gate_version", GateConstructionGates.InactiveVersion)
    gate:setValue("gate_construction_target_x", tx)
    gate:setValue("gate_construction_target_y", ty)
    gate:setValue("gate_construction_builder_faction", faction.index)
    if commissioningPlayerIndex then
        gate:setValue("gate_construction_commissioner", commissioningPlayerIndex)
    end

    gate.dockable = false
    gate:addScript(GateConstructionGates.InactiveScript)

    return gate
end

function GateConstructionGates.createActive(factionIndex, tx, ty)
    local x, y = Sector():getCoordinates()

    local faction = resolveFaction(factionIndex, x, y)
    if not faction then return nil end

    local desc = makeDescriptor(faction, tx, ty, x, y,
       ComponentType.WormHole,
       ComponentType.EnergySystem,
       ComponentType.EntityTransferrer)

    desc:addScript(GateConstructionGates.GateScript)

    local wormhole = desc:getComponent(ComponentType.WormHole)
    wormhole:setTargetCoordinates(tx, ty)
    wormhole.visible = false
    wormhole.visualSize = 50
    wormhole.passageSize = 50
    wormhole.oneWay = true

    -- Without this marker, sector/background/gatecompatibility.lua wipes every gate in
    -- the sector on the next load and regenerates only the ones in the vanilla gates map.
    Sector():setValue("gates2.0", true)

    local gate = Sector():createEntity(desc)
    if not valid(gate) then return nil end

    gate:setValue("gate_construction_active_gate", true)

    return gate
end

return GateConstructionGates
