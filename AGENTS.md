# AGENTS.md — rules for AI agents in this repository

A multi-mod workspace for Avorion. Each mod lives in `mods/<mod-name>/`.

## 1. Never write to the Steam installation

```
$HOME/Library/Application Support/Steam/steamapps/common/Avorion
```

This is read-only reference material. Read vanilla scripts freely for API,
architecture, and behavior; never create, edit, move, rename, or delete anything
there. If a task appears to need a vanilla change, extend it from a mod instead.

Likewise, keep changes inside this repository unless the user asks otherwise.

## 2. Mod mechanism

Mods mirror Avorion's `data/` tree and extend vanilla scripts by name-clashing
Lua injection before the final `return`. Keep `modinfo.lua` valid, preserve
`-- namespace ...` comments, and keep UI code inside `if onClient() then`.
Prefer additive, reversible changes.

## 3. Installing a mod locally

Avorion loads mods from `~/.avorion/mods/`. Symlink the mod folder under its
`modinfo.lua` name, then add that name to the `enabled` list in
`~/.avorion/mods/modconfig.lua`:

```bash
ln -s "$PWD/mods/stock-command" ~/.avorion/mods/stock_command
```

All four mods are already symlinked, so only `modconfig.lua` decides what loads.

## 4. Mod-specific notes

- `core-distance-label`: keep the readout at a map edge, never as a tooltip next
  to the sector or the cursor.
- `production-capacity-stats`: keep the production math in sync with vanilla
  `entity/merchants/factory.lua`. The game uses `max(MinimumCapacity, plan
  capacity)`, not addition, so anything at or below the 100 baseline requires
  `0`. Never show it for crafts that don't produce goods.

Ask before destructive operations.
