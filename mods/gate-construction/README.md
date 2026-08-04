# gate-construction

Gate commissioning mission mod for Avorion.

## What it adds

- New interaction at Travel Hubs: commission a gate connection between two sectors.
- Distance-scaled downpayment in credits and one material tier.
- Mission flow:
  - Wait for faction cargo ship arrival.
  - Deliver construction goods to the cargo ship.
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

This first version implements the full mission backbone and persistence.
The "inactive gate" state is represented by clearly marked gate-construction
beacons until final activation, where active gate entities are spawned.
