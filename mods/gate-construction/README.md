# gate-construction

Gate commissioning mission mod for Avorion.

## What it adds

- New interaction at Research Stations: commission a gate connection between two sectors.
- Gate construction progression is unlocked through Adventurer mail tied to the Wormhole Guardian storyline.
- Distance-scaled downpayment in credits and one material tier.
- Mission flow:
  - Wait for the research station to finish construction.
  - Interact with the inactive gate to start activation.
  - Defend against a strong Xsotan invasion wave.
  - Activate the gate link when the battle is won.
- Abandon behavior:
  - Material downpayment is refunded.
  - Credit fee is not refunded.
  - Spawned mission entities are cleaned up.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script extensions and mission scripts.

## Current implementation scope

This version implements the full mission backbone and persistence.
Real inactive gates are spawned and later activated into fully functional links
after the defense objective is completed.
