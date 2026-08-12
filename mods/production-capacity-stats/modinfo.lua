
meta =
{
    id = "production_capacity_stats",
    name = "production_capacity_stats",
    title = "Optimal Production Capacity Stats",
    type = "mod",

    description = "While building a factory or mine, shows the station's current "
        .. "production capacity next to the amount it actually needs, in the same "
        .. "\"have/need\" form the game uses for crew quarters. Factories run on a "
        .. "free baseline of 100 production capacity, so anything a station needs "
        .. "below that baseline is reported as 0. Stations that don't produce goods "
        .. "are not affected.",

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
