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

local function getFactionHermitUnlock(player)
    if not player then return false end

    if player:getValue("gate_construction_hermit_gate_access") == true then
        return true
    end

    if player.alliance and player.alliance:getValue("gate_construction_hermit_gate_access") == true then
        return true
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

local function maybeSpawnHermitForCurrentSector(player)
    if not player then return end
    if not (player:getValue("story_completed") == true) then return end
    if getFactionHermitUnlock(player) then return end

    local px, py = player:getSectorCoordinates()
    if not px or not py then return end

    local hx, hy = getHermitLocationForPlayer(player)
    if not hx or not hy then return end
    if px ~= hx or py ~= hy then return end

    Hermit.spawn()
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
    local storyCompleted = player:getValue("story_completed") == true

    if not data.guardianHintSent and (guardianMail or storyCompleted) then
        local text = Format("Hello!\n\nI believe the giant wormhole in the center is the key to building new gate links. If that theory is correct, we could reopen routes that have been dead for ages.\n\nPlease keep pushing toward the core and watch for the Wormhole Guardian. If we can remove it, we might finally prove this works.\n\nGreetings,\n%1%"%_T, MissionUT.getAdventurerName())
        if sendMail(player, guardianHintMailId, "Gate Theory? /* Mail Subject */"%_T, text) then
            data.guardianHintSent = true
            player:setValue("gate_construction_guardian_hint_mail_sent", true)
            if player.alliance then
                player.alliance:setValue("gate_construction_guardian_hint_mail_sent", true)
            end
        end
    end

    if not data.guardianHermitFollowupSent and storyCompleted then
        local hx, hy = getHermitLocationForPlayer(player)
        local locationLine = "()"
        if hx and hy then
            locationLine = "(${x}:${y})"%_T % {x = hx, y = hy}
        end

        local text = Format("Hello!\n\nI am convinced that the wormhole's power can be used to open passages through spacetime.\n\nBut the technology for building stable gates has been lost since the war between the United Alliances and the Xsotan.\n\nI can only think of asking the Hermit for more information. Find and speak with him again in sector %2%. Tell him what happened beyond the Barrier, and hope he points us in the right direction.\n\nGood luck,\n%1%"%_T, MissionUT.getAdventurerName(), locationLine)
        if sendMail(player, guardianHermitFollowupMailId, "A New Lead on Gate Construction /* Mail Subject */"%_T, text) then
            data.guardianHermitFollowupSent = true
            player:setValue("gate_construction_guardian_hermit_followup_mail_sent", true)
            if player.alliance then
                player.alliance:setValue("gate_construction_guardian_hermit_followup_mail_sent", true)
            end
        end
    end

    maybeSpawnHermitForCurrentSector(player)
end

function GateConstructionLoreMail.initialize()
    local player = Player()
    data.guardianHintSent = player:getValue("gate_construction_guardian_hint_mail_sent") == true
    data.guardianHermitFollowupSent = player:getValue("gate_construction_guardian_hermit_followup_mail_sent") == true

    maybeSendMailUpdates(player)
end

function GateConstructionLoreMail.updateServer(timeStep)
    if not Player() then return end
    maybeSendMailUpdates(Player())
end

function GateConstructionLoreMail.onSectorEntered(x, y)
    if not Player() then return end
    maybeSpawnHermitForCurrentSector(Player())
end

function GateConstructionLoreMail.secure()
    return data
end

function GateConstructionLoreMail.restore(restored)
    data = restored or data
end
