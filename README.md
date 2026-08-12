# Avorion mods workspace

This repository is organized as a multi-mod workspace.

## Structure

- `mods/stock-command/`: "Stock Factory" captain command.
- `mods/gate-construction/`: commissioning player-built gates at research stations.
- `mods/core-distance-label/`: galaxy map readout of the selected sector's
  distance to the galactic core.
- `mods/production-capacity-stats/`: build-mode `have/need` readout for a
  factory's production capacity.
- Future mods should be added as additional folders under `mods/`.

Each mod folder should contain its own `modinfo.lua`, `data/` tree, and optional
mod-specific documentation.
