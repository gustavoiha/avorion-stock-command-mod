
meta =
{
    id = "core_distance_label",
    name = "core_distance_label",
    title = "Galactic Core Distance Label",
    type = "mod",

    description = "Shows the euclidean distance between the sector selected on the "
        .. "galaxy map and the galactic core (0:0). The readout sits in the lower "
        .. "left edge of the map so it never covers the map itself or any tooltip.",

    authors = {"Gugs_Iha"},
    version = "1.0",

    dependencies = {
    },

    -- The label is client side, but the player script is attached from the server.
    serverSideOnly = false,
    clientSideOnly = false,

    -- Attaches a player script, which is persisted with the player.
    saveGameAltering = true,

    contact = "",
}
