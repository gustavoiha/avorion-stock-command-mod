
meta =
{
    id = "core_distance_label",
    name = "core_distance_label",
    title = "Galactic Core Distance Label",
    type = "mod",

    description = "Always know how close you are to the core without doing the math yourself. "
        .. "The galaxy map gets a small label in the lower-left corner showing the euclidean "
        .. "straight-line distance from the selected sector to 0:0. ",

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
