
meta =
{
    id = "production_capacity_stats",
    name = "production_capacity_stats",
    title = "Optimal Production Capacity Stats",
    type = "mod",

    description = "In build mode on a factory or mine, shows an overlay with the "
        .. "station's current production capacity vs. how much it needs for the fastest "
        .. "cycle, plus the resulting cycle time. Non-production stations are unaffected.",

    authors = {"Gugs_Iha"},
    version = "1.0",

    dependencies = {
    },

    -- The readout is client side, the optimum is computed on the server.
    serverSideOnly = false,
    clientSideOnly = false,

    -- Attaches a player script, which is persisted with the player.
    saveGameAltering = true,

    contact = "",
}
