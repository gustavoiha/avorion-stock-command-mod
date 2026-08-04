package.path = package.path .. ";data/scripts/lib/?.lua"

include("stringutility")
local MissionUT = include("missionutility")

-- namespace GateConstructionLoreMail
GateConstructionLoreMail = {}

local data = {
    guardianHintSent = false,
    guardianTheorySent = false,
}

local guardianMailId = "Story_Kill_Guardian_Mission"
local guardianHintMailId = "gate_construction_guardian_hint_mail"
local guardianTheoryMailId = "gate_construction_guardian_theory_mail"

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
        local text = Format("Hello!\n\nI have been thinking about the Xsotan and the black hole in the center of the galaxy. I suspect that the wormhole there has something to do with constructing gates, but I need to learn more before I can say for certain.\n\nIf you haven't already, keep pushing toward the core and watch for any sign of the Wormhole Guardian.\n\nGreetings,\n%1%"%_T, MissionUT.getAdventurerName())
        if sendMail(player, guardianHintMailId, "Gate Theory? /* Mail Subject */"%_T, text) then
            data.guardianHintSent = true
            player:setValue("gate_construction_guardian_hint_mail_sent", true)
            if player.alliance then
                player.alliance:setValue("gate_construction_guardian_hint_mail_sent", true)
            end
        end
    end

    if not data.guardianTheorySent and storyCompleted then
        local text = Format("Hello!\n\nNow I know I was right. The wormhole in the center of the galaxy can be harnessed by a research station in the core sector. If the station is built there, it should be able to draw energy from the wormhole and use it to activate gates.\n\nThe Xsotan Guardian is gone, so the way is finally clear. If your faction has a core-sector research station, it can now commission gate construction.\n\nGood luck out there.\n\n%1%"%_T, MissionUT.getAdventurerName())
        if sendMail(player, guardianTheoryMailId, "Gate Theory Confirmed /* Mail Subject */"%_T, text) then
            data.guardianTheorySent = true
            player:setValue("gate_construction_gate_theory_mail_sent", true)
            if player.alliance then
                player.alliance:setValue("gate_construction_gate_theory_mail_sent", true)
            end
        end
    end
end

function GateConstructionLoreMail.initialize()
    local player = Player()
    data.guardianHintSent = player:getValue("gate_construction_guardian_hint_mail_sent") == true
    data.guardianTheorySent = player:getValue("gate_construction_gate_theory_mail_sent") == true

    maybeSendMailUpdates(player)
end

function GateConstructionLoreMail.updateServer(timeStep)
    if not Player() then return end
    maybeSendMailUpdates(Player())
end

function GateConstructionLoreMail.secure()
    return data
end

function GateConstructionLoreMail.restore(restored)
    data = restored or data
end
