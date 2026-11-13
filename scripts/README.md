# Scripts
These scripts are for database creation from the db client files and analysis.

## Database
Running `lua scripts/launcher.lua` will read the files in the csv-folders and generate a db lua file in the addon folder.

It also creates svg-folders with each map for visualization purposes. See the top of the script for the options (`--no-svg` leaves those out).

## Analysis
The addon can record flights when `RECORD_FLIGHTS = true` in the `core.lua` file.

The SavedVariable file for the addon contains a `TaxiTimerDB.flights` table over recorded flight data.

This data can be analyzed using `analyze.lua` by passing it the SavedVariable file path, see the top of the script for the options.

The scripts need a Lua of any version from 5.1 and up. The Lua of the Lua language server works too. The analysis runs the simulation of the addon itself.

### Clearing the flight records
Recorded flights remain in the SavedVariable file until manually deleted using `/run wipe(TaxiTimerDB.flights)`.

Flight records add loading time and static memory usage, so unless you need the data, turn off recording, then wipe the table to free up space.

