# Scripts

Tools for building the taxi database and for keeping the flight simulation in line with the game.

They need Lua 5.1 or later.

| File | Purpose |
| --- | --- |
| `analyze.lua` | Compares recorded flights to the simulation and says what to change in the `libs/TaxiTimerLib/sim_<game>.lua` files, or writes the changes itself. |
| `launcher.lua` | Generates the `libs/TaxiTimerLib/db_<game>.lua` files (and svg maps) from the csv files in the `csv_<game>` folders. |
| `recordings.lua` | Every flight that was ever recorded. Written by `analyze.lua`, not by hand. |
| `taxiparser.lua` | The csv reader and db/svg writer that `launcher.lua` uses. |
| `shim.lua` | Loads `libs/TaxiTimerLib` (with its LibStub and the db and sim of a game) and the saved variables in plain Lua, in any version from 5.1. Used by the other scripts. |
| `meta.lua` | Type declarations for the language server. Nothing runs it. |
| `analysis/` | The parts of `analyze.lua`. |

## analyze.lua

```
lua scripts/analyze.lua [SavedVariables/TaxiTimer.lua] [options]
```

Record flights by setting `RECORD_FLIGHTS = true` at the top of `core.lua`, fly, then log out or reload.

With the SavedVariables file, the flights that are not in `recordings.lua` yet are added to it. All the flights in `recordings.lua` are then analyzed. Without the file, `recordings.lua` is analyzed as it is. A flight is never added twice.

The output lists each flight with how far off the simulation is now, the flights still off by 5 sec or more with the cause, and the lines to add, change or remove in the sim file.

| Option | What it does |
| --- | --- |
| `--apply` | Write the suggested changes to the sim file and analyze again until nothing is left. Unsure suggestions are shown, not written. |
| `--coverage` | Show how much of each map has been flown, and the maps without flights. |
| `--joins` | List every taxi node that was flown past, with the points flown there, and a table of the nodes where the game could cut a loop with how much the cut saves (to see if one rule fits them all). |
| `--speeds` | Show the speed each path was flown at from each of its points. |
| `--flight=N` / `--all` | Show the details of flight N (can be repeated), or of every flight. |
| `--worst=SECONDS` | How far off a flight must be to be listed with its cause (default 5). |
| `--sim=FILE` | Use this sim file instead of the one of the addon, to try things on a copy. |
| `--client=NAME` | Use the data of this game (`mainline`, `forever`, `classic`, `vanilla`) instead of the one the flight was recorded on. |
| `--archive=FILE` | Keep the flights in this file instead of `recordings.lua`. |
| `--no-archive` | Only look at the SavedVariables file, and keep nothing. |
| `--keep-old` | Also use the flights from before a game build changed how their route or map is flown. |
| `--no-suggest` | Do not show the suggested changes. |
| `--near=YARDS` / `--far=YARDS` | How close a point must be passed to count as flown (25), and how far away to count as not flown (60). |

Commonly used:

```
lua scripts/analyze.lua "<WoW>/_retail_/WTF/Account/<account>/SavedVariables/TaxiTimer.lua" --apply
```

```
lua scripts/analyze.lua --coverage
```

## launcher.lua

```
lua scripts/launcher.lua [options] [game ...]
```

The games are `mainline`, `forever`, `classic` and `vanilla`. Without any, all four are generated.

| Option | What it does |
| --- | --- |
| `--no-svg` | Only generate the db files. |
| `--out=FOLDER` | Write the files to this folder instead of `libs/TaxiTimerLib` (db files) and the scripts folder (svg maps). |

Commonly used:

```
lua scripts/launcher.lua --no-svg
```

## Clearing the flight records in the game

Recorded flights stay in the SavedVariables file until they are removed with `/run wipe(TaxiTimerDB.flights)`. They add loading time and memory, so turn recording off and wipe them once `analyze.lua` has added them to `recordings.lua`.
