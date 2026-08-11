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
  - When it completes, an **inactive gate** spawns at each endpoint, in the same place and with
    the same look as the finished gate. Nothing can travel through it.
  - Endpoint sectors are marked `Inactive gate` on the galaxy map.
- Activation:
  - Fly to either inactive gate and interact with it.
  - The ship you are flying must have an installed `XSTN-K I`.
  - Activating replaces both inactive gates with real, working gates.
  - Only then are the gate link, the galaxy map connection, the gate-network influence
    expansion and the faction thank-you gifts applied.
- The commission window shows the live remaining build time and blocks new commissions while one is queued.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script extensions and mod libraries.

## Current implementation scope

The construction queue, timer and persistence live on the Research Station itself
(`data/scripts/entity/merchants/gatecommissionhub.lua`), secured via `secure()`/`restore()`.
Commissioned links are tracked galaxy-wide in `data/scripts/lib/gateconstructionlinks.lua`,
which keeps built-but-inactive pairs separate from activated ones.
Both gate variants are built by `data/scripts/lib/gateconstructiongates.lua` from the same
seed, plan and position. The inactive gate carries
`data/scripts/entity/gateconstructioninactivegate.lua`, which owns the activation UI and
replaces itself with a real gate; the counterpart gate converts itself the next time its
sector is loaded.
