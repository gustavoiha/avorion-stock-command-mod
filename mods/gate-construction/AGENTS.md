# AGENTS.md - Rules for the gate-construction mod

This file applies to `mods/gate-construction/`.

## 1. Scope

Only modify files in this mod folder unless the user explicitly asks otherwise.

## 2. Mod mechanism

This mod mirrors Avorion's `data/` structure and extends vanilla scripts through
name-clashing Lua injection before the final `return`.

Use extension files in this folder only. Do not edit vanilla game files.

## 3. Install/test location

Avorion loads mods from:

```
~/.avorion/mods/<ModName>/
```

Use a symlink or copy from this mod folder when testing. Do not write into the
Steam installation.

## 4. Notes

- Keep `modinfo.lua` metadata valid.
- Keep `-- namespace ...` comments where required by Avorion scripts.
- Prefer additive, reversible changes.
