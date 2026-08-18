# stock-command

Stock Factory captain command mod for Avorion.

## Behavior

- Anchors the Stock Factory command to a selected sector.
- Operates on player/alliance-owned stations in the anchor sector and sectors
    connected by gates up to 5 jumps away.
- Hauls every eligible good by default. The command window provides an ignore
    list for goods that should not be moved.
- Moves goods only between your own stations, never hauling from a source
    station that also buys the same good.
- Requires the initiating player to have the alliance `Manage Stations`
    privilege before alliance station cargo or stock-hauler settings can be
    changed.
- Logs all cargo pickups and deliveries to the Economy chat channel for visibility.
- Stores picked-up goods in the background ship's real cargo hold. If a delivery
    becomes full, the command makes one recovery attempt before returning the
    ship with any remaining cargo.

## Cargo Overflow Handling

Pickup and delivery are separate, correlated transactions. A pickup is only
acknowledged after the goods have been written to the ship's database cargo.
Delivery removes only the amount actually accepted by the destination. When cargo
remains aboard because a destination filled up, the command makes one recovery
attempt:

- It first looks for a good sold by the full station that another reachable station
    can accept in full. The replacement load must free enough station cargo space
    for every remaining unit, and must fit entirely in the ship.
- If an exchange is not viable, it tries one other reachable consumer for the
    remaining original cargo.
- A failed continuation delivery aborts the command. Successful exchanges are
    logged as an Economy delivery followed by an Economy pickup.

The command aborts and recalls the ship when:

- A destination cannot accept all cargo and its one recovery attempt fails.
- A source or destination disappears or becomes inaccessible.
- A station-management permission is revoked while the route is active.
- An asynchronous station transfer times out repeatedly.
- A five-minute route remap finds no consumer or eligible supplier.

Any undelivered goods remain in the ship's cargo hold for the player to handle.

An empty producer is not a failure: the command simply waits and tries another
eligible route. A producer that is *destroyed*, sold, or opted out is different —
it disappears from the route map, so if it was the last one the next five-minute
remap recalls the ship rather than leaving it idle forever.

A stalled station transfer is retried rather than aborted. Because the ship's real
cargo is the source of truth and every transfer clamps to it, replaying a leg cannot
duplicate goods; only repeated timeouts recall the ship. For the same reason, a
transfer interrupted by a server restart is replayed on load instead of stranding
the command.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script overrides/extensions for command registration,
  simulation, map UI integration, and ferry appearance behavior.
