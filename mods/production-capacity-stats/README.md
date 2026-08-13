# Optimal Production Capacity Stats

While you are in build mode on a station that produces goods (factories and
mines), this mod shows a compact overlay in the bottom-right corner with both
the production capacity readout and the estimated production cycle time:

```
Production Capacity
   Capacity 420/380
      Cycle 15s
```

- **Capacity left number**: the production capacity your assembly blocks currently provide.
- **Capacity right number**: the capacity you still have to build to reach the shortest
  possible production cycle.
- **Cycle**: the estimated resulting production cycle time in whole seconds,
  truncated after applying the game's minimum 15 second floor.

Stations that don't produce goods never show the overlay, so the default build
stats are unaffected.

## How the requirement is calculated

Taken straight from `data/scripts/entity/merchants/factory.lua`:

```
time  = value / productionCapacity / levelSpeedup
value = sum(good.price * amount) over results and garbages
levelSpeedup = 1 + (average good level) / 100
```

The cycle time is clamped to `Factory.MinimumTimeToProduce` (15s), so the
capacity worth building is:

```
optimal = value / 15 / levelSpeedup
```

Factories also get a free baseline of `Factory.MinimumCapacity` (100). The game
applies it as `max(100, capacity of your assembly blocks)`, so any factory whose
optimum is at or below 100 is already running at full speed and the mod reports
`0` required capacity — there is no point adding assembly blocks at all.

## Files

- `data/scripts/player/init.lua` — injection that attaches the player script.
- `data/scripts/player/ui/productioncapacitystats.lua` — server-side optimum
  calculation plus the client-side readout.
- `tests/optimalcapacity_test.lua` — offline check of the math against the
  reference table on the Avorion wiki. Run with
  `luajit tests/optimalcapacity_test.lua`.

## Steam Workshop description (BBCode)

```bbcode
This mod shows exactly how many assembly blocks a factory needs to reach its maximum cycle speed, right in the build view.

[h2]Build mode only[/h2]

While you're in build mode on a factory or mine, a small overlay appears in
the bottom-right corner. For example, a factory that only needs 380 production capacity would be shown like this:

[code]
Production Capacity
   Capacity 420/380
      Cycle 15s
[/code]

[h2]For every type of production[/h2]

This mod is based on the information from Avorion wiki's webpage detailing the optimal production capacity for each factory: [url=https://avorion.fandom.com/wiki/Optimal_factory_production_capacity]reference[/url].

[h2]Capacity floor of 100[/h2]

Every factory has a free capacity floor of 100 by default.
If a station's optimal amount is equal to or below 100, that means there is no need for assembly blocks at all. Therefore, the mod reports [b]0[/b] required.

[h2]No clutter on other stations[/h2]

Stations that don't produce goods (shipyards, turret factories, repair docks, etc.)
never show the overlay at all.
```

## Install

Link or copy this folder into `~/.avorion/mods/production_capacity_stats/`.
