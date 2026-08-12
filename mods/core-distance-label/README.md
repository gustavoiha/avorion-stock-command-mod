# Galactic Core Distance Label

Adds a small readout to the galaxy map showing how far the currently selected
sector is from the galactic core, measured as a plain euclidean distance
`sqrt(x² + y²)` in sectors.

The label is drawn in the lower left edge of the map, not next to the sector or
the mouse cursor, so it never competes with sector tooltips or the fleet list.

## Files

- `data/scripts/player/init.lua` — injection that attaches the client script.
- `data/scripts/player/map/coredistancelabel.lua` — the client-side label.

## Install

Link or copy this folder into `~/.avorion/mods/core_distance_label/`.
