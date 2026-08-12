# stock-command

Stock Factory captain command mod for Avorion.

## Behavior

- Anchors the Stock Factory command to a selected sector.
- Operates on player/alliance-owned stations in the anchor sector and sectors
    connected by gates up to 3 jumps away.
- Lets you choose which goods to haul from all goods your stations in that
    region either consume or produce.
- Moves goods only between your own stations, never hauling from a source
    station that also buys the same good.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script overrides/extensions for command registration,
  simulation, map UI integration, and ferry appearance behavior.
