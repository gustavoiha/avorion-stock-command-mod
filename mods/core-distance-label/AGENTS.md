# AGENTS.md - Rules for the core-distance-label mod

This file applies to `mods/core-distance-label/`.

## 1. Scope

Only modify files in this mod folder unless the user explicitly asks otherwise.

## 2. Mod mechanism

`data/scripts/player/init.lua` is a name-clashing injection into the vanilla
bootstrap; `data/scripts/player/map/coredistancelabel.lua` is a new file.

Do not edit vanilla game files.

## 3. Constraints

- The distance readout must stay in a low-priority screen area (map edges).
  Never render it as a tooltip next to the sector or the mouse.
- Keep the client/server split: UI code lives inside `if onClient() then`.
- Keep the `-- namespace ...` comment.
