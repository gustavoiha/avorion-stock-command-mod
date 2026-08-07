package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";data/scripts/?.lua"

include("utility")
include("stringutility")

local function canUseForBoundFaction(player, boundFaction)
    if not player or not boundFaction then return false end
    if player.index == boundFaction then return true end
    if player.alliance and player.alliance.index == boundFaction then return true end
    return false
end

function create(item, rarity, factionIndex)
    item.stackable = false
    item.depleteOnUse = true
    item.name = "Archived Gate Theory Notes"%_t
    item.price = 1000
    item.icon = "data/textures/icons/energy-arrow.png"
    item.rarity = rarity
    item.boundFaction = factionIndex
    item.droppable = false
    item.tradeable = false
    item:setValue("subtype", "GateConstructionKnowledge")
    item:setValue("unsellable", true)

    local tooltip = Tooltip()
    tooltip.icon = item.icon
    tooltip.rarity = rarity

    local title = TooltipLine(25, 15)
    title.ctext = item.name
    title.ccolor = rarity.tooltipFontColor
    tooltip:addLine(title)

    tooltip:addLine(TooltipLine(14, 14))

    local bound = TooltipLine(20, 14)
    bound.ltext = "Bound Faction"%_t
    bound.rtext = "${faction:" .. tostring(factionIndex) .. "}"
    bound.icon = "data/textures/icons/fleet-command.png"
    bound.iconColor = ColorRGB(0.8, 0.8, 0.8)
    tooltip:addLine(bound)

    tooltip:addLine(TooltipLine(14, 14))

    local l1 = TooltipLine(20, 14)
    l1.ltext = "Legacy item kept for save compatibility."%_t
    tooltip:addLine(l1)

    local l2 = TooltipLine(20, 14)
    l2.ltext = "No longer unlocks gate commissioning."%_t
    tooltip:addLine(l2)

    tooltip:addLine(TooltipLine(14, 14))

    local useLine = TooltipLine(20, 15)
    useLine.ltext = "Deprecated"%_t
    useLine.lcolor = ColorRGB(1.0, 1.0, 0.3)
    tooltip:addLine(useLine)

    tooltip:addLine(TooltipLine(10, 10))

    local actLine = TooltipLine(20, 14)
    actLine.ltext = "Can be activated by the player"%_t
    tooltip:addLine(actLine)

    item:setTooltip(tooltip)

    return item
end

function activate(item)
    local player = Player()
    if not player then return false end

    local boundFaction = item.boundFaction
    if not canUseForBoundFaction(player, boundFaction) then
        player:sendChatMessage(""%_T, ChatMessageType.Error, "These notes are bound to another faction."%_T)
        return false
    end

    local faction = Faction(boundFaction)
    if not faction then
        player:sendChatMessage(""%_T, ChatMessageType.Error, "The bound faction no longer exists."%_T)
        return false
    end

    player:sendChatMessage(""%_T, ChatMessageType.Information,
        "This item is deprecated. Gate commissioning now depends on your own Research Station in sector 0:0 with a permanently installed legendary Wormhole Power Diverter."%_T)

    return true
end
