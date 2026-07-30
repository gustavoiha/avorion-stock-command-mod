# AGENTS.md — Rules for AI agents working in this repository

This repository contains an **Avorion** mod ("Stock Factory" captain command).
Read and obey these rules before taking any action.

## 1. NEVER modify the local game installation

The Avorion game is installed at:

```
$HOME/Library/Application Support/Steam/steamapps/common/Avorion
```

Under **no circumstance** may an agent create, edit, move, rename, delete, or
otherwise alter **any** file or directory inside that path (or anywhere else in
the Steam installation). This includes — but is not limited to — files under
`data/scripts/`, `data/`, `Documentation/`, and any `.db`, `.lua`, `.ini`, or
asset files.

- ✅ **Allowed:** reading those files for reference (API, architecture, examples).
- ❌ **Forbidden:** any write, delete, chmod, or in-place edit of game files.
- ❌ **Forbidden:** running commands that could mutate the install (e.g. `rm`,
  `mv`, `>`, `sed -i`, `cp` *into* the install, patching, symlinking *over* game
  files).

If a task appears to require changing a vanilla game file, **stop** and instead
achieve it through Avorion's mod extension mechanism (see below), which never
touches the original files.

## 2. All mod code lives in THIS repository

All of your work must stay inside this repository — the folder that contains
this `AGENTS.md` file. Do not create or modify files anywhere else.

The mod mirrors Avorion's `data/` folder structure. Avorion loads mods by
**injecting** name-clashing Lua files *before* the vanilla file's final `return`,
so we extend vanilla scripts (e.g. the command registry) without editing them.

## 3. Installing / running the mod

Avorion loads mods from the user data folder, which is **separate** from the
read-only Steam install:

```
~/.avorion/mods/<ModName>/
```

To test, the mod is placed there via a **copy or symlink of this repo** (a link
that points the mods folder at this repo). This never modifies the game install.
Do not edit anything inside the Steam `Avorion/` folder to enable the mod.

## 4. If in doubt

Prefer reversible, local actions inside this repository. Ask the user before any
action that is destructive, affects shared/global state, or touches paths outside
this repository.
