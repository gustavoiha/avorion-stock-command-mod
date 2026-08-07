package.path = package.path .. ";data/scripts/lib/?.lua"

include("callable")
include("stringutility")
include("relations")

-- namespace GateConstructionHermitContact
GateConstructionHermitContact = {}
GateConstructionHermitContact.interactionThreshold = -30000

local function hasGuardianProgress(player)
    if not player then return false end
    return player:getValue("story_completed") == true or player:getValue("wormhole_guardian_destroyed") == true
end

function GateConstructionHermitContact.interactionPossible(playerIndex, option)
    return CheckFactionInteraction(playerIndex, GateConstructionHermitContact.interactionThreshold)
end

function GateConstructionHermitContact.initUI()
    ScriptUI():registerInteraction("I crossed the galactic Barrier and came back."%_t, "onStartDiscussion")
end

function GateConstructionHermitContact.onStartDiscussion()
    local player = Player()

    if not player then return end
    if not hasGuardianProgress(player) then
        local preStory = {
            text = "You are still chasing bigger questions. Return to me after you cross the Barrier and defeat the Wormhole Guardian."%_t
        }
        ScriptUI():interactShowDialog(preStory, false)
        return
    end

    local intro = {}
    local d1 = {}
    local d2 = {}
    local d3 = {}
    local d4 = {}
    local d6 = {}

    intro.text = "You... returned. I did not expect to see you again."%_t
    intro.answers = {{answer = "I equipped my ship with Avorion and came back to ask for your help."%_t, followUp = d1}}

    d1.text = "Then speak. What did you find?"%_t
    d1.answers = {{answer = "Tell the Hermit about the wormhole guardian..."%_t, followUp = d2}}

    d2.text = "This is a shocking revelation. Centuries ago, the United Alliance also harnessed the energy of the wormhole to build gates connecting all of the galaxy."%_t
    d2.answers = {{answer = "Could we do the same?"%_t, followUp = d3}}

    d3.text = "With that piece of Xsotan technology you have, yes. You will need a research station in the core of the galaxy equipped with the device."%_t
    d3.answers = {{answer = "I see."%_t, followUp = d4}}

    d4.text = "Then you will be able to direct the energy of the wormhole into stabilizing new gates."%_t
    d4.answers = {
        {answer = "I promise to reconnect the inner and outer factions once again."%_t, followUp = d6},
        {answer = "I will use this to become rich!"%_t, followUp = d6}
    }

    d6.text = "To be honest, I don't even care. Do whatever you want. I doubt the factions will change."%_t
    d6.answers = {{answer = "I am ready to begin."%_t, onSelect = "onBeginResearch"}}

    ScriptUI():interactShowDialog(intro, false)
end

function GateConstructionHermitContact.onBeginResearch()
    if onClient() then
        invokeServerFunction("onBeginResearch")
        return
    end

    local player = Player(callingPlayer)
    if not player then return end
    if not CheckFactionInteraction(callingPlayer, GateConstructionHermitContact.interactionThreshold) then
        invokeClientFunction(player, "showBeginResult", false, "You don't have permission to discuss this with the Hermit."%_T)
        return
    end
    if not hasGuardianProgress(player) then return end

    invokeClientFunction(player, "showBeginResult", true, "Then begin at your own Research Station in sector 0:0 with a permanently installed legendary Wormhole Power Diverter."%_T)
end
callable(GateConstructionHermitContact, "onBeginResearch")

function GateConstructionHermitContact.showBeginResult(ok, message)
    local dialog = {}
    dialog.text = message or ""

    ScriptUI():interactShowDialog(dialog, false)
end
