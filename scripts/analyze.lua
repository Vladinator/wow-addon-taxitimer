--[[

Compares the flights recorded by the addon against the taxi data, to show where the estimates are off and why, and what to change in the sim file of the game to make them better.

The estimates are made by the simulation of the addon itself (the library `libs/TaxiTimerLib` with the db and sim files of the game), so what is compared to is what the addon does.

To record flights turn recording on with `/taxitimer record` in the game, fly, then log out or reload so the saved variables are written.

After the summary of the flights it lists the lines to add, change or remove in the sim file of the game (`sim_mainline.lua`, `sim_forever.lua`, `sim_vanilla.lua` or `sim_classic.lua`) for its speeds to match what was flown.
The speeds of a taxi map come first (its speed, how it takes off and lands, and if it flies slower where the points are close to each other), then the taxi nodes whose mount flies at another speed (the whole flight is flown on the mount of the node it starts at), and a path only gets its own speeds if it is still off by a few seconds with those.
With `--apply` the changes are written to the sim file and the flights are analyzed again until nothing is left, so recording flights and running this is all it takes to keep the sim files up to date.
Before that it lists the flights the simulation is still off by with the sim file as it is now, and what makes each of them differ (the distance and how the taxi nodes were flown past, the speed of a path, loading).
Then how the game flies past taxi nodes where the simulation does it another way (`NODE_JOINS` and `RETRACE_EXCEPTIONS`), going by where the flights went.
Some paths change the flight speed as they pass their points. These speeds are not part of the client files, so recorded flights are the only source for them.

Runs in Lua 5.1 and later (use `lua`, `lua5.1`, `luajit` or the Lua of the Lua language server):

	lua scripts/analyze.lua [WTF/Account/.../SavedVariables/TaxiTimer.lua] [options]

Every flight is kept in `scripts/data/recordings.lua`: the flights of the saved variables that are not in it yet are added to it, and it is all of its flights that are analyzed, from old to new.
So the saved variables can be emptied (or be those of another account) without losing what the sim files were made from. Without the saved variables file the flights that were kept are analyzed.
The game can change how a route or a taxi map is flown. Every flight says which build of the game it was flown on, so where the flights of the newest build differ from those of an older build (a route takes 3 sec longer or shorter, or a taxi map is mostly flown at another speed) the older flights are left out, and the sim file follows the game as it is now. They stay in the file.
A flight is the same flight when it was picked at the same second, flew the same route in the same game and landed after the same time.

Options:

	--wow=FOLDER    take the flights from the saved variables of every game in the World of Warcraft folder (`_retail_`, `_classic_` and so on, in `WTF/Account/<account>/SavedVariables/TaxiTimer.lua`)
	--flight=N      show the details of flight N (as numbered in the summary), can be repeated
	--all           show the details of every flight
	--speeds        show the speed each path was flown at from each of its points, as lines for the PATH_SPEEDS table of the sim file
	--sim=FILE      the sim file to suggest changes to (default is the one of this addon for the game the flights were recorded on)
	--worst=SECONDS the seconds a flight must be off by with the sim file as it is now to be listed with what causes it (default 5)
	--coverage      show how much of each map has been flown, the paths that have no flight of their own yet (all on a small map, the shortest on a big one), and the maps without flights, to see where to fly next
	--joins         list every taxi node that was flown past with the points that were flown there, to see where the simulation flies past a node another way than the game
	--apply         write the suggested changes to the sim file, and analyze again until there is nothing left to change (the suggestions that need more flights are shown and left out)
	--archive=FILE  the file every flight is kept in (default is `data/recordings.lua` next to this script)
	--no-archive    only look at the flights of the saved variables, and do not keep them
	--keep-old      also use the flights from before the game changed how their route or taxi map is flown
	--no-suggest    do not show the suggested changes to the sim file
	--client=NAME   use the data of this game (mainline, forever, classic or vanilla) instead of what the flight was recorded on
	--near=YARDS    how close we have to pass a point for it to count as flown (default 25)
	--far=YARDS     how far from a point we have to stay for it to count as not flown (default 60)

--]]

local scriptPath = arg and arg[0] or "scripts/analyze.lua"
local scriptDir = scriptPath:match("^(.*)[/\\][^/\\]*$") or "."
local shim = dofile(scriptDir .. "/src/shared/shim.lua") ---@type Shim

---@type AnalysisContext
local ctx = {
	shim = shim,
	dir = scriptDir,
	dataDir = scriptDir .. "/data",
	root = scriptDir:match("^(.*)[/\\][^/\\]*$") or (scriptDir == "." and ".." or "."),
	util = dofile(scriptDir .. "/src/shared/util.lua"),
	csv = dofile(scriptDir .. "/src/shared/csv.lua"),
}
local loadData = dofile(scriptDir .. "/src/analysis/data.lua")(ctx) ---@type TaxiDataLoader
local Flight = dofile(scriptDir .. "/src/analysis/flight.lua")(ctx)
local suggestAll = dofile(scriptDir .. "/src/analysis/suggest.lua")(ctx)
local applyChanges = dofile(scriptDir .. "/src/analysis/apply.lua")(ctx) ---@type ApplyChanges
local parseOptions = dofile(scriptDir .. "/src/analysis/options.lua")(ctx)
local loadRecords = dofile(scriptDir .. "/src/analysis/records.lua")(ctx)
local leaveOutSuperseded = dofile(scriptDir .. "/src/analysis/superseded.lua")(ctx)
local printSummary = dofile(scriptDir .. "/src/analysis/summary.lua")(ctx)
local printSpeeds = dofile(scriptDir .. "/src/analysis/speeds.lua")(ctx)
local printCoverage = dofile(scriptDir .. "/src/analysis/coverage.lua")(ctx)

local printf, warn = ctx.util.printf, ctx.util.warn

local opts = parseOptions(arg or {}, scriptPath)
local records, source = loadRecords(opts)

-- the game to compare a flight to, newer records say which game they are from, named like its db file
---@param record FlightRecord
---@return TaxiTimerLib-1.0_GameFlavor
local function getClient(record)
	if type(record.flavor) == "string" then
		return record.flavor
	end
	local project = record.project or 1
	if project == 1 then return "mainline" end
	if project == 2 then return "vanilla" end
	return "classic"
end

-- the analyses of the flights with the files of the addon as they are now
---@param quiet? boolean
---@return FlightAnalysis[]
local function analyzeFlights(quiet)
	local list = {} ---@type FlightAnalysis[]
	for index, record in ipairs(records) do
		if type(record) ~= "table" or record.version ~= 1 then
			if not quiet then
				warn("flight %s skipped as it is not in a format this script knows", tostring(index))
			end
		else
			local data, dataErr = loadData(opts.client or getClient(record), opts.simFile)
			if not data then
				if not quiet then
					warn("flight %s skipped: %s", tostring(index), tostring(dataErr))
				end
			else
				list[#list + 1] = Flight.new(index, record, data, opts.near, opts.far)
			end
		end
	end
	return list
end

-- the lines to change in the sim file, written and analyzed again with `--apply` as a change can make room for another (the speed of a taxi map changes what its paths need)
---@param analyses FlightAnalysis[]
---@return FlightAnalysis[] analyses The analyses after the changes.
local function suggestChanges(analyses)
	local suggested = suggestAll(analyses, opts.simFile, opts.joins)
	for pass = 1, opts.apply and 5 or 0 do
		local written = 0
		for _, changes in ipairs(suggested) do
			local count, held = applyChanges(changes.simFile, changes.lines, changes.data)
			written = written + count
			printf("\n%d change%s written to %s\n", count, count == 1 and "" or "s", changes.simFile)
			for _, line in ipairs(held) do
				print("  not written, it needs more flights or a look: " .. line)
			end
		end
		if written == 0 then
			break
		end
		if ctx.reload then
			ctx.reload()
		end
		analyses = analyzeFlights(true)
		if not opts.keepSuperseded then
			leaveOutSuperseded(analyses)
		end
		printf("\nAgain with the changes (pass %d)\n", pass + 1)
		suggested = suggestAll(analyses, opts.simFile, false)
	end
	if opts.apply then
		local off, total = 0, 0
		for _, a in ipairs(analyses) do
			local errorNow = not a.incomplete and a:errorNow() or nil
			if errorNow then
				total = total + 1
				off = off + (math.abs(errorNow) >= opts.worstSeconds and 1 or 0)
			end
		end
		printf("\nwith the sim file as it is now %d of %d flights are off by %s sec or more\n", off, total, tostring(opts.worstSeconds))
	end
	return analyses
end

-- the details of the flights that were asked for
---@param analyses FlightAnalysis[]
---@return number shown How many flights.
local function printDetails(analyses)
	local shown = 0
	for _, a in ipairs(analyses) do
		if opts.all or opts.wanted[a.index] then
			print("\n" .. string.rep("-", 100) .. "\n" .. a:report())
			shown = shown + 1
		end
	end
	return shown
end

local analyses = analyzeFlights()
local superseded = opts.keepSuperseded and {} or leaveOutSuperseded(analyses)
printSummary(analyses, superseded, source, opts.worstSeconds)

if opts.suggest and #analyses > 0 then
	analyses = suggestChanges(analyses)
end

local shown = printDetails(analyses)
if opts.speeds then
	printSpeeds(analyses)
	shown = shown + 1
end
if opts.coverage then
	printCoverage(analyses)
	shown = shown + 1
end

if shown == 0 then
	print("\nuse --flight=N or --all to see the details of flights, --speeds for the speed of each path, --joins for how the taxi nodes were flown past, --coverage for where to fly next")
end
