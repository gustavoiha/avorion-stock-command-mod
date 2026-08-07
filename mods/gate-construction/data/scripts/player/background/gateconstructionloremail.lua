package.path = package.path .. ";data/scripts/lib/?.lua"

include("stringutility")
local MissionUT = include("missionutility")
local Hermit = include("data/scripts/entity/story/hermit")

-- namespace GateConstructionLoreMail
GateConstructionLoreMail = {}

local data = {
    guardianHintSent = false,
    guardianHermitFollowupSent = false,
}

local guardianMailId = "Story_Kill_Guardian_Mission"
local guardianHintMailId = "gate_construction_guardian_hint_mail"
local guardianHermitFollowupMailId = "gate_construction_guardian_hermit_followup_mail_v2"

local resolvedHermitXKey = "gate_construction_resolved_hermit_x_v2"
local resolvedHermitYKey = "gate_construction_resolved_hermit_y_v2"

local function hasGuardianProgress(player)
    if not player then return false end

    if player:getValue("story_completed") == true then
        return true
    end

    if player:getValue("wormhole_guardian_destroyed") == true then
        return true
    end

    local storyAdvance = tonumber(player:getValue("story_advance") or 0) or 0
    if storyAdvance >= 6 and onServer() then
        local server = Server()
        if server and server:getValue("guardian_respawn_time") ~= nil then
            return true
        end
    end

    return false
end

local function getHermitLocationForPlayer(player)
    if not player then return nil, nil end

    local ok, hx, hy = player:invokeFunction("storyquestutility.lua", "getHermitLocation")
    if ok and hx and hy then
        return hx, hy
    end

    return nil, nil
end

local function storeResolvedHermitLocation(player, x, y)
    if not player or x == nil or y == nil then return end

    player:setValue(resolvedHermitXKey, x)
    player:setValue(resolvedHermitYKey, y)

    if player.alliance then
        player.alliance:setValue(resolvedHermitXKey, x)
        player.alliance:setValue(resolvedHermitYKey, y)
    end
end

local function getStoredResolvedHermitLocation(player)
    if not player then return nil, nil end

    local x = player:getValue(resolvedHermitXKey)
    local y = player:getValue(resolvedHermitYKey)
    if x ~= nil and y ~= nil then
        return x, y
    end

    if player.alliance then
        x = player.alliance:getValue(resolvedHermitXKey)
        y = player.alliance:getValue(resolvedHermitYKey)
        if x ~= nil and y ~= nil then
            return x, y
        end
    end

    return nil, nil
end

local function getHermitLocationFromCurrentSector(player)
    if not player then return nil, nil end

    local hermit = Sector():getEntitiesByScript("data/scripts/entity/story/hermit.lua")
    if valid(hermit) then
        return player:getSectorCoordinates()
    end

    return nil, nil
end

local function getHermitLocationFromKnownFactionHome()
    local faction = Galaxy():findFaction("The Hermit"%_T)
    if not faction then return nil, nil end
    if faction.homeSectorUnknown then return nil, nil end

    local x, y = faction:getHomeSectorCoordinates()
    if x ~= nil and y ~= nil then
        return x, y
    end

    return nil, nil
end

local function getHermitLocationFromKnownSectors(player)
    if not player then return nil, nil end

    local hermitFaction = Galaxy():findFaction("The Hermit"%_T)
    if not hermitFaction then return nil, nil end

    local px, py = player:getSectorCoordinates()
    local bestX, bestY
    local bestDist2

    local function considerView(view)
        if not view then return end

        local vx, vy = view:getCoordinates()
        local seen = false

        if view.factionIndex == hermitFaction.index then
            seen = true
        end

        if not seen then
            local shipsByFaction = view:getShipsByFaction()
            if shipsByFaction and (shipsByFaction[hermitFaction.index] or 0) > 0 then
                seen = true
            end
        end

        if not seen then
            local craftsByFaction = view:getCraftsByFaction()
            if craftsByFaction and (craftsByFaction[hermitFaction.index] or 0) > 0 then
                seen = true
            end
        end

        if not seen then return end

        if px ~= nil and py ~= nil then
            local dx = vx - px
            local dy = vy - py
            local d2 = dx * dx + dy * dy
            if bestDist2 == nil or d2 < bestDist2 then
                bestDist2 = d2
                bestX, bestY = vx, vy
            end
        else
            bestX, bestY = vx, vy
        end
    end

    for _, view in pairs({player:getKnownSectors()}) do
        considerView(view)
    end

    if player.alliance then
        for _, view in pairs({player.alliance:getKnownSectors()}) do
            considerView(view)
        end
    end

    return bestX, bestY
end

local function getHermitLocationFromDeterministicFallback(player)
    if not player then return nil, nil end

    local x, y = player:getHomeSectorCoordinates()
    if x ~= nil and y ~= nil then
        local hx, hy = Hermit.getLocation(x, y)
        if hx ~= nil and hy ~= nil then
            return hx, hy
        end
    end

    x, y = player:getSectorCoordinates()
    if x ~= nil and y ~= nil then
        return Hermit.getLocation(x, y)
    end

    return nil, nil
end

local function resolveHermitLocationForPlayer(player)
    if not player then return nil, nil end

    local hx, hy = getHermitLocationForPlayer(player)
    if hx ~= nil and hy ~= nil then
        storeResolvedHermitLocation(player, hx, hy)
        return hx, hy
    end

    hx, hy = getStoredResolvedHermitLocation(player)
    if hx ~= nil and hy ~= nil then
        return hx, hy
    end

    hx, hy = getHermitLocationFromCurrentSector(player)
    if hx ~= nil and hy ~= nil then
        storeResolvedHermitLocation(player, hx, hy)
        return hx, hy
    end

    hx, hy = getHermitLocationFromKnownFactionHome()
    if hx ~= nil and hy ~= nil then
        storeResolvedHermitLocation(player, hx, hy)
        return hx, hy
    end

    hx, hy = getHermitLocationFromKnownSectors(player)
    if hx ~= nil and hy ~= nil then
        storeResolvedHermitLocation(player, hx, hy)
        return hx, hy
    end

    hx, hy = getHermitLocationFromDeterministicFallback(player)
    if hx ~= nil and hy ~= nil then
        storeResolvedHermitLocation(player, hx, hy)
        return hx, hy
    end

    return nil, nil
end

local function hasMail(player, mailId)
    local mails = {player:getMailsById(mailId)}
    return mails[1] ~= nil
end

local function sendMail(player, mailId, header, text)
    if hasMail(player, mailId) then return false end

    local mail = Mail()
    mail.header = header
    mail.sender = Format("%1%, the Adventurer"%_T, MissionUT.getAdventurerName())
    mail.id = mailId
    mail.text = text

    player:addMail(mail)
    player:sendChatMessage(""%_T, ChatMessageType.Information, "You received a message from the Adventurer."%_T)
    return true
end

local function maybeSendMailUpdates(player)
    if not player then return end

    local guardianMail = hasMail(player, guardianMailId)
    local guardianProgress = hasGuardianProgress(player)

    if data.guardianHintSent and not hasMail(player, guardianHintMailId) then
        data.guardianHintSent = false
        player:setValue("gate_construction_guardian_hint_mail_sent", false)
        if player.alliance then
            player.alliance:setValue("gate_construction_guardian_hint_mail_sent", false)
        end
    end

    if guardianProgress and data.guardianHermitFollowupSent and not hasMail(player, guardianHermitFollowupMailId) then
        data.guardianHermitFollowupSent = false
        player:setValue("gate_construction_guardian_hermit_followup_mail_sent", false)
        if player.alliance then
            player.alliance:setValue("gate_construction_guardian_hermit_followup_mail_sent", false)
        end
    end

    if not data.guardianHintSent and (guardianMail or guardianProgress) then
        local text = Format("Hello!\n\nI believe the giant wormhole in the center is the key to building new gate links. If that theory is correct, we could reopen routes that have been dead for ages.\n\nPlease keep pushing toward the core and watch for the Wormhole Guardian. If we can remove it, we might finally prove this works.\n\nGreetings,\n%1%"%_T, MissionUT.getAdventurerName())
        if sendMail(player, guardianHintMailId, "Gate Theory? /* Mail Subject */"%_T, text) then
            data.guardianHintSent = true
            player:setValue("gate_construction_guardian_hint_mail_sent", true)
            if player.alliance then
                player.alliance:setValue("gate_construction_guardian_hint_mail_sent", true)
            end
        end
    end

    local hx, hy = resolveHermitLocationForPlayer(player)

    if not data.guardianHermitFollowupSent and guardianProgress then
        local text
        if hx ~= nil and hy ~= nil then
            local locationLine = "(${x}:${y})"%_T % {x = hx, y = hy}
            text = Format("Hello!\n\nI am convinced that the wormhole's power can be used to open passages through spacetime.\n\nBut the technology for building stable gates has been lost since the war between the United Alliances and the Xsotan.\n\nI can only think of asking the Hermit for more information. Find and speak with him again in sector %2%. Tell him what happened beyond the Barrier, and hope he points us in the right direction.\n\nGood luck,\n%1%"%_T, MissionUT.getAdventurerName(), locationLine)
        else
            text = Format("Hello!\n\nI am convinced that the wormhole's power can be used to open passages through spacetime.\n\nBut the technology for building stable gates has been lost since the war between the United Alliances and the Xsotan.\n\nI can only think of asking the Hermit for more information. I no longer have his exact sector in my current notes, so please check my earlier message about the Hermit and speak with him again. Tell him what happened beyond the Barrier, and hope he points us in the right direction.\n\nGood luck,\n%1%"%_T, MissionUT.getAdventurerName())
        end

        if sendMail(player, guardianHermitFollowupMailId, "A New Lead on Gate Construction /* Mail Subject */"%_T, text) then
            data.guardianHermitFollowupSent = true
            player:setValue("gate_construction_guardian_hermit_followup_mail_sent", true)
            if player.alliance then
                player.alliance:setValue("gate_construction_guardian_hermit_followup_mail_sent", true)
            end
        end
    end

end

function GateConstructionLoreMail.initialize()
    local player = Player()
    data.guardianHintSent = player:getValue("gate_construction_guardian_hint_mail_sent") == true
    data.guardianHermitFollowupSent = player:getValue("gate_construction_guardian_hermit_followup_mail_sent") == true

    maybeSendMailUpdates(player)
end

function GateConstructionLoreMail.getUpdateInterval()
    return 30
end

function GateConstructionLoreMail.updateServer(timeStep)
    if not Player() then return end
    maybeSendMailUpdates(Player())
end

function GateConstructionLoreMail.onSectorEntered(x, y)
    if not Player() then return end
    maybeSendMailUpdates(Player())
end

function GateConstructionLoreMail.secure()
    return data
end

function GateConstructionLoreMail.restore(restored)
    data = restored or data
end
