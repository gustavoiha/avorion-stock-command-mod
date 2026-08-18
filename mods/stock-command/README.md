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
- Logs every completed transfer to the Economy chat channel, e.g.
    `(2:2) Hauler transferred 100 units of Aluminium from Aluminium Mine to Steel Factory.`
- Goods are never parked on the ship. Each run ends in a single transfer that takes
    them out of the producer's cargo bay and puts them into the consumer's while both
    sectors are held in memory, the way vanilla's Supply command works.

## Transfers

A run is one travel leg. When it ends, the command probes both stations, moves the
goods out of the producer, and pushes them into the consumer within the same few
frames. The amount is clamped to the consumer's free room, the producer's stock and
the hauler's cargo capacity.

Because the whole exchange resolves in one burst, a consumer can only fill up in the
few frames between the probe and the transfer, and only if another hauler is working
the same route. Whatever the consumer could not take is pushed straight back into the
producer's bay, so nothing is destroyed and the ship is never left holding cargo.

A run that finds an empty producer or a full consumer is simply abandoned; the
station is remembered for a while so the next plan skips it, and the ship picks
another route.

The command aborts and recalls the ship when:

- A source or destination disappears or becomes inaccessible.
- A station-management permission is revoked while the route is active.

A stalled station transfer is abandoned rather than retried, and the ship looks for
another route. Nothing is in transit between two stations for longer than a few
frames, so an abandoned transfer strands nothing. A transfer interrupted by a server
restart is dropped on load for the same reason.

An empty producer is not a failure: the command simply waits and tries another
eligible route. Commands saved before this transfer model are recalled once on load
so any cargo still in the hold can be verified by hand.

## Ferry visuals

When a player is in one of the ferry's sectors, the background ship appears and flies
for real. It has three states:

- **Waiting** — with no run in progress it patrols its anchor sector.
- **Travelling** — during the first part of a run it patrols and passes through the
    sectors on its gate route, entering and leaving through the actual gates. Some
    runs include a decorative stop at the producer.
- **Delivering** — for the tail of the run it is parked in the consumer's sector, so a
    watching player sees it fly in and dock. Docking is what triggers the transfer, so
    the Economy message lands exactly as the ship touches the dock. If nobody is
    watching, or it cannot reach a dock, the transfer fires on the timer instead.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script overrides/extensions for command registration,
  simulation, map UI integration, and ferry appearance behavior.
