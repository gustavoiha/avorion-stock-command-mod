package.path = package.path .. ";data/scripts/lib/?.lua"

include("callable")
include("stringutility")
include("faction")
include("rarity")
include("relations")

-- namespace GateConstructionHermitContact
GateConstructionHermitContact = {}
GateConstructionHermitContact.interactionThreshold = -30000

local AVORION_CONTRIBUTION = 500

local function avorionVector(amount)
    return 0, 0, 0, 0, 0, 0, amount
end

local function hasUnlockedForFaction(faction)
    if not faction then return false end
    return faction:getValue("gate_construction_hermit_gate_access") == true
end

local function grantKnowledgeItem(faction)
    if not faction then return false end

    local item = UsableInventoryItem("data/scripts/items/gateconstructionknowledge.lua", Rarity(RarityType.Exotic), faction.index)
    if not item then return false end

    local inv = faction:getInventory()
    if not inv then return false end

    inv:addOrDrop(item)
    return true
end

local function hasUnlockedForPlayer(player)
    if not player then return false end
    if hasUnlockedForFaction(player) then return true end
    if player.alliance and hasUnlockedForFaction(player.alliance) then return true end
    return false
end

function GateConstructionHermitContact.interactionPossible(playerIndex, option)
    return CheckFactionInteraction(playerIndex, GateConstructionHermitContact.interactionThreshold)
end

function GateConstructionHermitContact.initUI()
    ScriptUI():registerInteraction("Discuss Gate Research"%_t, "onStartDiscussion")
end

function GateConstructionHermitContact.onStartDiscussion()
    local player = Player()

    if not player then return end
    if player:getValue("story_completed") ~= true then
        local preStory = {
            text = "You are still chasing bigger questions. Return to me after you cross the Barrier and defeat the Wormhole Guardian."%_t
        }
        ScriptUI():interactShowDialog(preStory, false)
        return
    end

    if hasUnlockedForPlayer(player) then
        local unlocked = {
            text = "I have already shared my gate research notes with your faction. Use them well, and reconnect the factions with new stable routes."%_t
        }
        ScriptUI():interactShowDialog(unlocked, false)
        return
    end

    local intro = {}
    local d1 = {}
    local d2 = {}
    intro.text = "So, you crossed the Barrier and destroyed the Wormhole Guardian? Hah. That is better news than I expected."%_t
    intro.answers = {
        {answer = "I did. The Adventurer asked me to find you."%_t, followUp = d1},
        {answer = "I need your help with the wormhole."%_t, followUp = d1}
    }

    d1.text = "Then listen closely. The wormhole can be stabilized and shaped into controlled spacetime passages. But this is not work for amateurs."%_t
    d1.answers = {{answer = "What do you need from me?"%_t, followUp = d2}}

    d2.text = "First, share a little Avorion with me. Just ${amount}. Everyone else hoards it. You are the first willing to cooperate."%_t % {amount = AVORION_CONTRIBUTION}
    d2.answers = {
        {answer = "I'll share ${amount} Avorion."%_t % {amount = AVORION_CONTRIBUTION}, onSelect = "onPayAvorion"},
        {answer = "Not right now."%_t}
    }

    ScriptUI():interactShowDialog(intro, false)
end

function GateConstructionHermitContact.onPayAvorion()
    if onClient() then
        invokeServerFunction("onPayAvorion")
        return
    end

    local player = Player(callingPlayer)
    if not player then return end
    if not CheckFactionInteraction(callingPlayer, GateConstructionHermitContact.interactionThreshold) then
        invokeClientFunction(player, "showPaymentResult", false, "You don't have permission to discuss this with the Hermit."%_T)
        return
    end
    if player:getValue("story_completed") ~= true then return end

    local payer = getInteractingFaction(callingPlayer, AlliancePrivilege.SpendResources)
    if not payer then
        invokeClientFunction(player, "showPaymentResult", false, "You are missing the privileges required to share resources."%_T)
        return
    end

    if hasUnlockedForFaction(payer) then
        invokeClientFunction(player, "showPaymentResult", true, "The Hermit already has what he needs from your faction."%_T)
        return
    end

    local canPay, msg, args = payer:canPay(0, avorionVector(AVORION_CONTRIBUTION))
    if not canPay then
        invokeClientFunction(player, "showPaymentResult", false, (msg or "You don't have enough Avorion."%_T), unpack(args or {}))
        return
    end

    payer:pay("Shared Avorion with the Hermit for gate research."%_T, 0, avorionVector(AVORION_CONTRIBUTION))

    if not grantKnowledgeItem(payer) then
        payer:receive("Returned Avorion: could not deliver Hermit's gate knowledge item."%_T, 0, avorionVector(AVORION_CONTRIBUTION))
        invokeClientFunction(player, "showPaymentResult", false, "I cannot hand over the research notes right now. Try again in a moment."%_T)
        return
    end

    invokeClientFunction(player, "showPaymentResult", true, "The Hermit accepted your Avorion and gave your faction a gate-knowledge item. Use it to unlock gate commissioning at your core Research Stations."%_T)
end
callable(GateConstructionHermitContact, "onPayAvorion")

function GateConstructionHermitContact.showPaymentResult(ok, message)
    local dialog = {}
    dialog.text = message or ""

    if ok then
        local d1 = {}
        local d2 = {}
        local d3 = {}

        d1.text = "Good. That is enough to start. The factions inside and outside the Barrier keep choosing greed over progress. You did not."%_t
        d1.answers = {{answer = "What comes next?"%_t, followUp = d2}}

        d2.text = "I compiled everything we can apply now into those notes. Use them, then let your core Research Stations handle the engineering work."%_t
        d2.answers = {{answer = "And that lets us build gates?"%_t, followUp = d3}}

        d3.text = "Yes. Once your faction uses that knowledge item, any of your own core Research Stations can commission new gates. I was once a scientist studying Avorion and rift behavior before I turned away from faction greed and war. I hope you use this technology to reconnect the factions."%_t
        d3.answers = {{answer = "Understood. I'll begin."%_t}}

        dialog.followUp = d1
    end

    ScriptUI():interactShowDialog(dialog, false)
end
