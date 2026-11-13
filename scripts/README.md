# Scripts
These scripts are for database creation from the db client files and analysis.

## Database
Running `launcher.php` will read the files in the csv-folders and generate a db lua file in the addon folder.

It also creates svg-folders with each map for visualization purposes.

## Analysis
The addon can record flights when `RECORD_FLIGHTS = true` in the `core.lua` file.

The SavedVariable file for the addon contains a `TaxiTimerDB.flights` table over recorded flight data.

This data can be analyzed using `analyze.php` by passing it the SavedVariable file path and the game flavor.

### Clearing the flight records
Recorded flights remain in the SavedVariable file until manually deleted using `/run wipe(TaxiTimerDB.flights)`.

Flight records add loading time and static memory usage, so unless you need the data, turn off recording, then wipe the table to free up space.

