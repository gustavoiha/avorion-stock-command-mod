
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
        .. "network. The ship ferries selected goods between authorized player and "
        .. "alliance stations, moving each load in one transfer so nothing is ever "
        .. "left stranded in its hold.",

    -- Authors.
    authors = {"Gugs_Iha"},

    -- Version (major.minor[.patch]).
    version = "1.5",

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
