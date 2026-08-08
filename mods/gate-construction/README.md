# gate-construction

Gate commissioning mod for Avorion.

## What it adds

- New interaction at Research Stations: commission a gate connection between two sectors.
- Gate commissioning does not require speaking with the Hermit.
- Commissioning is available only at your own (player/alliance-owned) Research Station in sector `0:0`.
- That station must have a permanently installed legendary Wormhole Power Diverter (Xsotan Wormhole Generator).
- Commissioning uses fixed credits + material downpayment only (no station goods bundle).
- Endpoint sectors must be discovered, and cannot already be linked by a gate.
- Construction flow (no mission involved):
  - The station queues the project and runs a 5 minute construction timer.
  - The timer keeps running while you are away; elapsed time is applied when sector `0:0` reloads.
  - When it completes, both gates spawn and a strong Xsotan wave attacks sector `0:0`.
- The commission window shows the live remaining build time and blocks new commissions while one is queued.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script extensions and mod libraries.

## Current implementation scope

The construction queue, timer and persistence live on the Research Station itself
(`data/scripts/entity/merchants/gatecommissionhub.lua`), secured via `secure()`/`restore()`.
Commissioned links are tracked galaxy-wide in `data/scripts/lib/gateconstructionlinks.lua`.
