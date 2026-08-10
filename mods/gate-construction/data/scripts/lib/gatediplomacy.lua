-- Thank-you gifts from factions that gain a route across the barrier.
-- A faction is thanked the first time it can reach the opposite side within MaxHops,
-- no matter which of the player's gates finally made that true.

package.path = package.path .. ";data/scripts/lib/?.lua"

include("stringutility")
include("relations")

local GateInfluence = include("gateinfluence")

local GateDiplomacy = {}

GateDiplomacy.RelationsGift = 50000
GateDiplomacy.CreditsGiftMin = 20000000
GateDiplomacy.CreditsGiftMax = 40000000

-- Gates are permanent, so a faction that has crossed the barrier never uncrosses it.
-- Both values are append-only and safe to replay.
local THANKED_KEY = "gate_diplomacy_thanked"
local PENDING_KEY = "gate_diplomacy_pending_player"

local function parseThanked()
    local set = {}
    for entry in string.gmatch(Server():getValue(THANKED_KEY) or "", "[^;]+") do
        local index = tonumber(entry)
        if index then set[index] = true end
    end

    return set
end

local function storeThanked(set)
    local entries = {}
    for index, _ in pairs(set) do
        table.insert(entries, index)
    end

    table.sort(entries)
    Server():setValue(THANKED_KEY, table.concat(entries, ";"))
end

local function sendThankYouMail(player, faction)
    local mail = Mail()

    mail.id = "gate_construction_barrier_thanks_" .. faction.index
    mail.header = "A road through the barrier"%_T
    mail.sender = faction.name
    mail.money = random():getInt(GateDiplomacy.CreditsGiftMin, GateDiplomacy.CreditsGiftMax)
    mail.text = Format("For generations the barrier was the edge of everything we could reach. \z
Your gates changed that. Ships that were never coming back are on our docks again.\n\n\z
Attached is a payment from our treasury. It does not cover what you have opened up for us, \z
but our books insist we try.\n\n\z
- %1%"%_T, faction.name)

    player:addMail(mail)
end

-- RelationChangeType.Default is deliberate: it is the only positive type with no entry in
-- RelationChangeMaxCap, so the full gift lands instead of being silently clamped the way a
-- trade-flavoured type would be. Its multiplier table exists but is empty, so faction
-- traits do not scale it either.
local function thank(player, factionIndex)
    local faction = Faction(factionIndex)
    if not faction or not faction.isAIFaction then return false end

    changeRelations(player, faction, GateDiplomacy.RelationsGift, RelationChangeType.Default)
    sendThankYouMail(player, faction)

    return true
end

local function grantTo(playerIndex)
    local player = Player(playerIndex)
    if not player then return end

    local thanked = parseThanked()
    local changed = false

    for factionIndex, _ in pairs(GateInfluence.getCrossBarrierFactions()) do
        if not thanked[factionIndex] and thank(player, factionIndex) then
            thanked[factionIndex] = true
            changed = true
        end
    end

    if changed then storeThanked(thanked) end
end

-- A finished link only queues the vanilla gate edges around it, so the graph is still
-- incomplete right now. Remember who paid for it and keep re-checking as it fills in.
function GateDiplomacy.onLinkCompleted(playerIndex)
    if not playerIndex then return end

    Server():setValue(PENDING_KEY, playerIndex)
    grantTo(playerIndex)
end

-- Called while the expansion queue drains. Once it is empty the graph is final for this
-- link, so the pending recipient can be dropped.
function GateDiplomacy.processPending(moreWork)
    local playerIndex = Server():getValue(PENDING_KEY)
    if not playerIndex then return end

    grantTo(playerIndex)

    if not moreWork then Server():setValue(PENDING_KEY, nil) end
end

return GateDiplomacy
