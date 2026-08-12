# AGENTS.md - Rules for the production-capacity-stats mod

This file applies to `mods/production-capacity-stats/`.

## 1. Scope

Only modify files in this mod folder unless the user explicitly asks otherwise.

## 2. Mod mechanism

`data/scripts/player/init.lua` is a name-clashing injection into the vanilla
bootstrap; `data/scripts/player/ui/productioncapacitystats.lua` is a new file.

The vanilla build-mode statistics panel is C++ and cannot be extended from Lua,
so the readout is a separate small HUD window shown only in
`PlayerStateType.BuildCraft`.

Do not edit vanilla game files.

## 3. Constraints

- Keep the production-time math in sync with
  `entity/merchants/factory.lua` (`Factory.refreshProductionTime`,
  `Factory.MinimumTimeToProduce`, `Factory.MinimumCapacity`).
- The game uses `max(MinimumCapacity, plan capacity)`, not an addition. Anything
  at or below the 100 baseline must report `0` required capacity.
- Never show the readout for crafts that don't produce goods.
- Keep the `-- namespace ...` comment.
