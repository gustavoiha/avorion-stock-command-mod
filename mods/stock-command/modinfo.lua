
meta =
{
    -- ID of the mod. Must be unique. Matches the game-generated skeleton so the
    -- workspace can be linked straight into ~/.avorion/mods/stock_command/.
    id = "stock_command",

    -- Internal name (helps identify the mod in the Mods() list).
    name = "stock_command",

    -- Title shown to players.
    title = "Stock Factory Command",

    -- "mod" or "factionpack".
    type = "mod",

    -- Description shown to players.
    description = "Adds a new captain command, \"Stock Factory\". Assign a ship "
        .. "(with a captain and a cargo hold) to stock your stations across a gate "
        .. "network. The ship costs every producer/consumer pair it can reach and "
        .. "delivers one in a single transfer between authorized player and alliance "
        .. "stations. Each hauler gets its own pick order - by value, by volume, or at "
        .. "random - so a fleet can be spread across a region instead of competing.",

    -- Authors.
    authors = {"Gugs_Iha"},

    -- Version (major.minor[.patch]).
    version = "1.6",

    -- Dependencies. Left empty on purpose so the mod isn't tied to a specific
    -- Avorion patch version.
    dependencies = {

    },

    -- Runs on both client (command UI) and server (background simulation).
    serverSideOnly = false,
    clientSideOnly = false,

    -- The command is persisted into the savegame database while a ship runs it,
    -- so disabling the mod mid-game would leave orphaned command data.
    saveGameAltering = true,

    contact = "",
}
