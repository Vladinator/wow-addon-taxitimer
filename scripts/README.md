# Scripts

Tools for building the taxi database and for keeping the flight simulation in line with the game.

They need Lua 5.1 or later.

| File | Purpose |
| --- | --- |
| `analyze.lua` | Compares recorded flights to the simulation and says what to change in the `libs/TaxiTimerLib/sim_<game>.lua` files, or writes the changes itself. |
| `launcher.lua` | Generates the `libs/TaxiTimerLib/db_<game>.lua` files (and svg maps) from the csv files in the `data/csv_<game>` folders. |
| `src/` | What the two scripts above are made of, nothing in it is run directly. |
| `data/` | What they read and write, see below. |

The `data` folder:

| File | Purpose |
| --- | --- |
| `csv_<game>/` | The taxi data of each game, as the game dumps it. Read by `launcher.lua` and `analyze.lua`. |
| `svg_<game>/` | The svg maps `launcher.lua` makes of them, not kept in git. |
| `recordings.lua` | Every flight that was ever recorded. Written by `analyze.lua`, not by hand. |

The `src` folder:

| File | Purpose |
| --- | --- |
| `analysis/` | The parts of `analyze.lua`: reading the options and the flights, the summary, the suggestions to the sim file (with their parts in `analysis/suggest/`) and writing them, and the analysis of a single flight (with its parts in `analysis/flight/`). |
| `taxiparser.lua` | Reads the csv files and writes the db files for `launcher.lua`. The svg maps are drawn by `taxiparser/svg.lua`. |
| `shared/csv.lua` | Reads the csv files of the taxi data, for `taxiparser.lua` and `analyze.lua`. |
| `shared/util.lua` | Small helpers the scripts share. |
| `shared/shim.lua` | Loads `libs/TaxiTimerLib` (with its LibStub and the db and sim of a game) and the saved variables in plain Lua, in any version from 5.1. |
| `shared/meta.lua` | Type declarations for the language server. Nothing runs it. |

## analyze.lua

```
lua scripts/analyze.lua [SavedVariables/TaxiTimer.lua] [options]
```

Record flights with `/taxitimer record` in the game, fly, then log out or reload.

With the SavedVariables file, the flights that are not in `recordings.lua` yet are added to it. All the flights in `recordings.lua` are then analyzed. Without the file, `recordings.lua` is analyzed as it is. A flight is never added twice.

The output lists each flight with how far off the simulation is now, the flights still off by 5 sec or more with the cause, and the lines to add, change or remove in the sim file.

| Option | What it does |
| --- | --- |
| `--wow=FOLDER` | Take the flights from the SavedVariables of every game in the World of Warcraft folder (`_retail_`, `_classic_`, `_forever_` and so on, in every account). |
| `--apply` | Write the suggested changes to the sim file and analyze again until nothing is left. Unsure suggestions are shown, not written. |
| `--coverage` | Show how much of each map has been flown, and the maps without flights. |
| (flights that landed early) | A flight that asked to land early and landed at a taxi node of its route that is not the last is left out as it is, and also counted as a flight of the route up to that taxi node (the same number in the summary, the shorter route in the end): what it did until it landed is all that is used of it, the rest of the route it was recorded for was never flown. It counts like any flight of that route (the sim is compared to how long it took, joins at the taxi nodes before the landing are looked at), but the way it turned back onto the path arriving to land after the stop was asked for is a few yards of another route than the sim's, so it is not a flight of the path leaving. |
| `--early` | List the flights that asked to land early (the stop button): when it was asked, which taxi node it landed at, how long it went on for after it was asked, and when the simulation reaches that taxi node. These are the flights that show where the point of no return is at a taxi node that is flown past. |
| `--paths=TEXT` | List the paths that leave the taxi nodes with TEXT in their name, with the path ids, their length and how many flights flew them. Can be repeated. |
| `--checkpoints` | For every taxi node a flight passed without landing, show when the simulation says it is reached against when the flight was at the same point (what the bar of the addon shows), the nodes where the flight was never near the simulated point, and where the route divides (going by a flight that landed at the node and one that passed it) when that is not where and when the simulation puts the node and the flight itself does not show the node right. |
| `--check` | Check the simulation against `data/baseline.lua`, which holds the seconds it was off by for every recorded flight when it was accepted as good. It fails (exit code 1) and lists the flights that got worse by more than the tolerance (1 sec, `--tolerance=S`) or if more flights are off by the worst seconds, and for the taxi nodes along the way (where each flight was when the simulation says it reaches them, the bar of the addon) when one gets more than 2 sec further from it or the flight is no longer near the point of the simulation. Run it after any change to the simulation, the sim files or the library. |
| `--update-baseline` | Make what the simulation does now the baseline, after a change that was looked into and is good. |
| `--apply` (other games) | The joins and the stops that are written to the sim file of one game are also written to the sim files of the other games where the paths have exactly the same points in both, unless the game already has an entry for it or flights of it flew there (they say how it is flown). The paths of `vanilla` are mostly the same as `forever`, those of `classic` (Mists of Pandaria) mostly are not. |
| `--thin` | With `--apply`, also write the suggestions that go by one flight. They say "based on one flight" and are held back otherwise, as a flight with lag or a stop can be anything. |
| `--prune[=MAP]` | Look at the entries of the sim file for single paths (`PATH_SPEEDS`, `PATH_RAMPS`) and suggest taking out the ones the flights do not need, for one taxi map or all of them, in place of the other suggestions. Shows how each taxi map is estimated with and without its entries, which entries go by one flight, and which have no flight. Run the analysis again after it (the taxi maps are then fitted without them). A normal run says when a taxi map has flights 10 sec or more off, as a reason to run this. |
| `--joins` | List every taxi node that was flown past, with the points flown there, and a table of the nodes where the game could cut a loop with how much the cut saves (to see if one rule fits them all). |
| `--speeds` | Show the speed each path was flown at from each of its points. |
| `--flight=N` / `--all` | Show the details of flight N (can be repeated), or of every flight. |
| `--worst=SECONDS` | How far off a flight must be to be listed with its cause (default 5). |
| `--sim=FILE` | Use this sim file instead of the one of the addon, to try things on a copy. |
| `--client=NAME` | Use the data of this game (`mainline`, `forever`, `classic`, `vanilla`) instead of the one the flight was recorded on. |
| `--archive=FILE` | Keep the flights in this file instead of `data/recordings.lua`. |
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
| `--out=FOLDER` | Write the files to this folder instead of `libs/TaxiTimerLib` (db files) and `data` (svg maps). |

Commonly used:

```
lua scripts/launcher.lua --no-svg
```

## Checking that a change did not make the timers worse

Two checks, both of which fail (exit code 1) and say what, so they can be run after every change to the addon or the simulation:

```
lua scripts/tests/run.lua
lua scripts/analyze.lua --check
```

The first runs the code of the addon (the flights of the GPS, the gossip flights, the settings and the saved options) against a stand-in for the game. The second replays every recorded flight through the simulation and compares what it estimates to `data/baseline.lua`, which has the seconds it was off by for each flight (and where it was at the taxi nodes along the way) when it was accepted as good, and fails when a flight got more than a second worse, a taxi node along the way got further from when the flight was there, or more flights are off by the worst seconds. The suggestions for speeds and ramps are also left out when they would move the taxi nodes along the way away from the flights, and the stops of `NODE_STOPS` that the flights no longer need are suggested to be removed. After a change that was looked into and is good, `lua scripts/analyze.lua --update-baseline` makes what the simulation does now the baseline.

## Clearing the gossip and flight records in the game

Recorded flights stay in the SavedVariables file until they are removed with `/run wipe(TaxiTimerDB.flights) wipe(TaxiTimerDB.gossipFlights)`. They add loading time and memory, so turn recording off and wipe them once `analyze.lua` has added them to `recordings.lua`.
