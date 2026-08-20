# stock-command

Stock Factory captain command mod for Avorion.

## Behavior

- Anchors the Stock Factory command to a selected sector.
- Operates on player/alliance-owned stations in the anchor sector and sectors
    connected by gates up to 5 jumps away.
- Hauls every eligible good. Each ship gets one **Prioritize** setting, chosen
    in the command window when it is assigned, deciding which of the loads it
    could move it reaches for first: no preference (the default — it picks at
    random), highest/lowest total value (units moved × the good's base price),
    or highest/lowest total volume (units moved × the good's cargo volume).
- Moves goods only between your own stations, never hauling from a source
    station that also buys the same good.
- Requires the initiating player to have the alliance `Manage Stations`
    privilege before alliance station cargo or stock-hauler settings can be
    changed.
- Logs every completed transfer to the Economy chat channel, e.g.
    `(2:2) Hauler transferred 100 units of Aluminium from Aluminium Mine to Steel Factory.`
- Goods are never parked on the ship. Each run takes them out of the producer's
    cargo bay and puts them into the consumer's while both sectors are held in
    memory, the way vanilla's Supply command works.

## Choosing a load

Every station database entry carries what the station trades *and* what is
sitting in its bay, and it reads without loading the station's sector. So before
the ship commits to anything, the command sizes every producer/consumer pair it
can reach — capped by the producer's stock, the consumer's quota for the good,
the room physically left in the consumer's bay, and the hauler's own hold — and
ranks the ones that would actually move something.

A pair that would move nothing is simply absent from the list, which is why the
command keeps no memory of what came up empty last time.

An ordered priority is exactly that — the ship takes the best-scoring pair,
every time, and never a lower-scoring one. Exact ties are drawn at random rather
than settled by list order, which matters more than it sounds: the hauler's hold
is usually the binding cap, so every route carrying the same good scores
identically, and list order would send a whole fleet down one of them.

Beyond ties, a fleet sharing one setting will reach for the same cargo, because
every hauler plans from the same station data in the same simulation tick.
Spreading a fleet out is the player's dial: give haulers different settings and
they stop competing. The default asks for nothing in particular and picks at
random, so an unconfigured fleet spreads out on its own.

## Transfers

The transfer happens first and the flight afterwards. The command moves the
goods out of the producer and into the consumer within the same few frames, then
the ship spends 3–5 minutes flying the load out to the consumer before it looks
for its next one.

That ordering is what makes a wrong guess cheap. Station data can be a few
seconds stale, so a transfer can still come up short:

- The producer hands over nothing — nothing left its bay, so there is nothing to
    undo. The ship waits 15 seconds and picks another pair.
- The consumer takes less than the haul was sized for — the remainder goes
    straight back into the producer's bay. If anything was delivered the run
    still earns its travel leg; if nothing was, the ship waits 15 seconds and
    picks another pair.
- The producer cannot take the remainder back either — the goods go into the
    ship's own hold and the command ends, bringing the ship home with them. A
    hauler flying around with cargo it cannot put down is not something it can
    resolve on its own.

The command also aborts and recalls the ship when a source or destination
disappears, or a station-management permission is revoked while the route is
active.

A stalled sector job is abandoned rather than retried, and the ship looks for
another route. A transfer interrupted by a server restart is dropped on load for
the same reason. Commands saved before this transfer model are recalled once on
load so any cargo still in the hold can be verified by hand.

## Ferry visuals

When a player is in one of the ferry's sectors, the background ship appears and
flies for real. It has three states:

- **Waiting** — with no run in progress it patrols its anchor sector.
- **Loading** — it is docked at the producer while the transfer resolves.
- **Travelling** — it patrols and passes through the sectors on its gate route,
    entering and leaving through the actual gates, then parks in the consumer's
    sector for the tail of the leg so a watching player sees it fly in and dock.

## Folder contents

- `modinfo.lua`: mod metadata loaded by Avorion.
- `data/`: injected script overrides/extensions for command registration,
  simulation, map UI integration, and ferry appearance behavior.
