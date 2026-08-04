# AGENTS.md - Global rules for AI agents in this repository

This repository is a multi-mod workspace for Avorion mods.
Read and obey these global rules before taking any action.

## 1. Never modify the Steam game installation

The Avorion game installation is read-only reference material:

```
$HOME/Library/Application Support/Steam/steamapps/common/Avorion
```

Do not create, edit, move, rename, or delete files there.

- Allowed: read-only access for API or architecture reference.
- Forbidden: any write operation in the Steam installation.

If a task appears to require changing vanilla game files, stop and implement the
change through the mod extension mechanism inside this repository instead.

## 2. Keep all changes inside this repository

Do not create or modify files outside this repository unless the user explicitly
asks for it.

## 3. Mod layout

Each mod lives in its own folder under `mods/`.
Mod-specific conventions and constraints belong in that mod folder's own
`AGENTS.md` file.

## 4. Safety

Prefer reversible local actions. Ask before destructive operations.
