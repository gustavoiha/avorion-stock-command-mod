# Optimal Production Capacity Stats

While you are in build mode on a station that produces goods (factories and
mines), this mod adds a small toggle button in the bottom-left corner. Open it
to see a compact overlay with both the production capacity readout and the
estimated production cycle time:

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

The overlay starts closed each time you enter build mode. Stations that don't
produce goods never show the toggle or overlay, so the default build stats are
unaffected.

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

## Install

Link or copy this folder into `~/.avorion/mods/production_capacity_stats/`.
