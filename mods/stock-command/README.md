# stock-command

Stock Factory captain command mod for Avorion.

## Behavior

- Anchors the Stock Factory command to a selected sector.
- Operates on player/alliance-owned stations in the anchor sector and sectors
    connected by gates up to 5 jumps away.
- Lets you choose which goods to haul from all goods your stations in that
    region either consume or produce.
- Moves goods only between your own stations, never hauling from a source
    station that also buys the same good.
- Logs all cargo pickups and deliveries to the Economy chat channel for visibility.
- **If cargo transfer fails (overflow, station destroyed, etc.), the command aborts and
    returns the cargo to the player's control** instead of losing it.

## Cargo Overflow Handling

If either:
- The destination station is too full to accept the cargo
- The destination station is destroyed or inaccessible
- The source station cannot provide the cargo

Then the command **aborts immediately** and the player regains control of the ship with any cargo remaining in its hold. This ensures no cargo is ever lost silently. The player can then manually decide what to do with the remaining cargo.

See `CARGO_OVERFLOW_HANDLING.md` for detailed behavior and setup recommendations.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script overrides/extensions for command registration,
  simulation, map UI integration, and ferry appearance behavior.
