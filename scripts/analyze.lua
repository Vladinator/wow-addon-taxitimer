--[[

Compares the flights recorded by the addon against the taxi data, to show where the estimates are off and why, and what to change in the sim file of the game to make them better.

The estimates are made by the simulation of the addon itself (the library `libs/TaxiTimerLib` with the db and sim files of the game), so what is compared to is what the addon does.

To record flights set `RECORD_FLIGHTS = true` at the top of `core.lua`, fly, then log out or reload so the saved variables are written.

After the summary of the flights it lists the lines to add, change or remove in the sim file of the game (`sim_mainline.lua`, `sim_forever.lua`, `sim_vanilla.lua` or `sim_classic.lua`) for its speeds to match what was flown.
The speeds of a taxi map come first (its speed, how it takes off and lands, and if it flies slower where the points are close to each other), then the taxi nodes whose mount flies at another speed (the whole flight is flown on the mount of the node it starts at), and a path only gets its own speeds if it is still off by a few seconds with those.
With `--apply` the changes are written to the sim file and the flights are analyzed again until nothing is left, so recording flights and running this is all it takes to keep the sim files up to date.
Before that it lists the flights the simulation is still off by with the sim file as it is now, and what makes each of them differ (the distance and how the taxi nodes were flown past, the speed of a path, loading).
Then how the game flies past taxi nodes where the simulation does it another way (`NODE_JOINS` and `RETRACE_EXCEPTIONS`), going by where the flights went.
Some paths change the flight speed as they pass their points. These speeds are not part of the client files, so recorded flights are the only source for them.

Runs in Lua 5.1 and later (use `lua`, `lua5.1`, `luajit` or the Lua of the Lua language server):

	lua scripts/analyze.lua [WTF/Account/.../SavedVariables/TaxiTimer.lua] [options]

Every flight is kept in `scripts/recordings.lua`: the flights of the saved variables that are not in it yet are added to it, and it is all of its flights that are analyzed, from old to new.
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
	--archive=FILE  the file every flight is kept in (default is `recordings.lua` next to this script)
	--no-archive    only look at the flights of the saved variables, and do not keep them
	--keep-old      also use the flights from before the game changed how their route or taxi map is flown
	--no-suggest    do not show the suggested changes to the sim file
	--client=NAME   use the data of this game (mainline, forever, classic or vanilla) instead of what the flight was recorded on
	--near=YARDS    how close we have to pass a point for it to count as flown (default 25)
	--far=YARDS     how far from a point we have to stay for it to count as not flown (default 60)

--]]

local scriptPath = arg and arg[0] or "scripts/analyze.lua"
local scriptDir = scriptPath:match("^(.*)[/\\][^/\\]*$") or "."
local shim = dofile(scriptDir .. "/shim.lua") ---@type Shim

---@type AnalysisContext
local ctx = {
	shim = shim,
	dir = scriptDir,
	root = scriptDir:match("^(.*)[/\\][^/\\]*$") or (scriptDir == "." and ".." or "."),
	util = dofile(scriptDir .. "/analysis/util.lua"),
}
local loadData = dofile(scriptDir .. "/analysis/data.lua")(ctx) ---@type TaxiDataLoader
local Flight = dofile(scriptDir .. "/analysis/flight.lua")(ctx)
local suggestAll = dofile(scriptDir .. "/analysis/suggest.lua")(ctx)
local applyChanges = dofile(scriptDir .. "/analysis/apply.lua")(ctx) ---@type ApplyChanges
local archive = dofile(scriptDir .. "/analysis/archive.lua")(ctx) ---@type FlightArchive

local util = ctx.util
local printf, warn = util.printf, util.warn
local format = string.format

--
-- MARK: The options
--

local file ---@type string? The saved variables file.
local wowDir ---@type string? The World of Warcraft folder, to look for the saved variables of every game in.
local wanted = {} ---@type table<number, boolean> The flights to show the details of.
local all, speeds, suggest, joins = false, false, true, false
local client ---@type TaxiTimerLib-1.0_GameFlavor? The game to use instead of the one the flights were recorded on.
local simFile ---@type string?
local coverage = false
local keepSuperseded = false
local archivePath = ctx.dir .. "/recordings.lua" ---@type string? The file every flight is kept in.
local apply = false
local worstSeconds = 5 ---@type number
local near = 25 ---@type number
local far = 60 ---@type number

---@return never
local function usage()
	warn("usage: lua %s [SavedVariables/TaxiTimer.lua] [--wow=FOLDER] [--flight=N] [--all] [--speeds] [--joins] [--coverage] [--apply] [--archive=FILE] [--no-archive] [--keep-old] [--worst=5] [--sim=FILE] [--no-suggest] [--client=mainline|forever|classic|vanilla] [--near=25] [--far=60]", scriptPath)
	os.exit(1)
end

for _, option in ipairs(arg or {}) do
	if option:match("^--flight=%d+$") then
		wanted[tonumber(option:match("=(%d+)")) or 0] = true
	elseif option == "--all" then
		all = true
	elseif option == "--speeds" then
		speeds = true
	elseif option == "--keep-old" then
		keepSuperseded = true
	elseif option == "--no-archive" then
		archivePath = nil
	elseif option:match("^--archive=.+$") then
		archivePath = option:match("=(.+)$")
	elseif option == "--apply" then
		apply = true
	elseif option == "--coverage" then
		coverage = true
	elseif option:match("^--worst=[%d.]+$") then
		worstSeconds = tonumber(option:match("=([%d.]+)")) or worstSeconds
	elseif option == "--joins" then
		joins = true
	elseif option == "--no-suggest" then
		suggest = false
	elseif option:match("^--wow=.+$") then
		wowDir = option:match("^--wow=(.+)$")
	elseif option:match("^--sim=.+$") then
		simFile = option:match("^--sim=(.+)$")
	elseif option:match("^--client=%w+$") then
		client = option:match("=(%w+)") --[[@as TaxiTimerLib-1.0_GameFlavor]]
	elseif option:match("^--near=[%d.]+$") then
		near = tonumber(option:match("=([%d.]+)")) or near
	elseif option:match("^--far=[%d.]+$") then
		far = tonumber(option:match("=([%d.]+)")) or far
	elseif not file and option:sub(1, 2) ~= "--" then
		file = option
	else
		warn("unknown option %s", option)
		os.exit(1)
	end
end

if file and not shim.readfile(file) then
	usage()
end
if not file and not wowDir and not (archivePath and shim.readfile(archivePath)) then
	usage() -- without saved variables the flights that were kept are analyzed, if there are any
end

--
-- MARK: The flights
--

-- the saved variables files to take the flights from: the one that was given, and the one of every game in the World of Warcraft folder
local files = {} ---@type string[]
local labels = {} ---@type table<string, string> What to call a file when the flights of it are counted.
if file then
	files[#files + 1] = file
	labels[file] = file
end
if wowDir then
	local folder = wowDir:gsub("[/\\]+$", "")
	local numFound = 0
	for _, game in ipairs(shim.listdir(folder)) do
		if game:match("^_.+_$") then -- like `_retail_` and `_classic_`
			local accounts = folder .. "/" .. game .. "/WTF/Account"
			for _, account in ipairs(shim.listdir(accounts)) do
				local path = accounts .. "/" .. account .. "/SavedVariables/TaxiTimer.lua"
				if shim.readfile(path) then
					numFound = numFound + 1
					files[#files + 1] = path
					labels[path] = game .. " " .. account
				end
			end
		end
	end
	if numFound == 0 then
		warn("no TaxiTimer.lua was found in the SavedVariables of the games in %s (looked for _game_/WTF/Account/<account>/SavedVariables/TaxiTimer.lua)", folder)
	end
end

local records = {} ---@type FlightRecord[]
local numAdded, numLoose = 0, 0
for _, path in ipairs(files) do
	local globals, err = shim.savedvariables(path)
	if not globals then
		warn("unable to read %s: %s", path, tostring(err))
		if path == file then
			os.exit(1)
		end
	else
		local db = globals.TaxiTimerDB ---@type { flights?: FlightRecord[] }?
		local flights = type(db) == "table" and type(db.flights) == "table" and db.flights or {}
		if archivePath then
			-- the flights are kept in a file of the repo, so they are still there when the saved variables are emptied
			local added, loose
			records, added, loose = archive.merge(archivePath, flights)
			numAdded, numLoose = numAdded + added, numLoose + loose
			printf("%s: %d flight%s, %d new\n", labels[path], #flights, #flights == 1 and "" or "s", added)
		else
			for _, flight in ipairs(flights) do
				records[#records + 1] = flight
			end
			printf("%s: %d flight%s\n", labels[path], #flights, #flights == 1 and "" or "s")
		end
	end
end
local source = #files == 1 and files[1] or (#files > 1 and format("%d saved variables files", #files)) or archivePath or "?"
if archivePath then
	if #files == 0 then
		records = archive.merge(archivePath, {})
	else
		printf("%d new flight%s added to %s, which has %d now%s\n", numAdded, numAdded == 1 and "" or "s", archivePath, #records - numLoose, numLoose > 0 and format(" (%d flights do not say when they were flown and are not kept)", numLoose) or "")
		source = source .. " and " .. archivePath
	end
end
if #records == 0 then
	warn("no flights in %s, set RECORD_FLIGHTS = true in core.lua and fly somewhere", source)
	os.exit(1)
end

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
			local data, dataErr = loadData(client or getClient(record), simFile)
			if not data then
				if not quiet then
					warn("flight %s skipped: %s", tostring(index), tostring(dataErr))
				end
			else
				list[#list + 1] = Flight.new(index, record, data, near, far)
			end
		end
	end
	return list
end

-- When the game changes how a route or a taxi map is flown, the flights from before the change no longer say how it is flown now.
-- The flights of the builds of the game are compared, and the older ones are left out where the newest ones differ, so the sim file follows the game as it is now.
local SUPERSEDED_SECONDS = 3 -- seconds the flights of a route must differ between two builds of the game for the older ones to be left out
local SUPERSEDED_MAP_FLIGHTS = 2 -- flights on the newest build a taxi map needs before its speed is compared to the older builds

---@param list FlightAnalysis[]
---@return string[] notes What was left out and why.
local function leaveOutSuperseded(list)
	local notes = {} ---@type string[]

	---@param values number[]
	---@return number
	local function median(values)
		table.sort(values)
		return values[math.floor((#values + 1) / 2)]
	end

	-- the flights by what is compared (`group`) and the build of the game they were flown on
	---@param group fun(a: FlightAnalysis): string?
	---@return table<string, table<number, FlightAnalysis[]>> groups
	---@return string[] order
	local function byBuild(group)
		local groups, order = {}, {} ---@type table<string, table<number, FlightAnalysis[]>>, string[]
		for _, a in ipairs(list) do
			local build = tonumber(a.record.build)
			local key = not a.incomplete and build and group(a) or nil
			if key and build then
				if not groups[key] then
					groups[key] = {}
					order[#order + 1] = key
				end
				groups[key][build] = groups[key][build] or {}
				table.insert(groups[key][build], a)
			end
		end
		return groups, order
	end

	---@param flights FlightAnalysis[]
	---@param why string
	local function leaveOut(flights, why)
		for _, a in ipairs(flights) do
			a.incomplete = why
		end
	end

	-- a taxi map that is mostly flown at another speed than before
	---@param flights FlightAnalysis[]
	---@return number? speed
	local function cruise(flights)
		local time = {} ---@type table<number, number>
		for _, a in ipairs(flights) do
			for j = 2, #a.track do
				local step = a.steps[j]
				if step.kind == "move" then
					local speed = a:roundSpeed(step.speed)
					time[speed] = (time[speed] or 0) + step.dt
				end
			end
		end
		local best, bestTime ---@type number?, number
		bestTime = 0
		for _, speed in ipairs(util.keys(time)) do
			if time[speed] > bestTime then
				best, bestTime = speed, time[speed]
			end
		end
		return best
	end
	local maps, mapOrder = byBuild(function(a)
		return a.record.area and (a.data.client .. " taxi map " .. tostring(a.record.area)) or nil
	end)
	for _, key in ipairs(mapOrder) do
		local builds = util.keys(maps[key])
		local newest = builds[#builds]
		local now = #maps[key][newest] >= SUPERSEDED_MAP_FLIGHTS and cruise(maps[key][newest]) or nil
		for i = 1, #builds - 1 do
			local before = cruise(maps[key][builds[i]])
			if now and before and before ~= now then
				local why = format("flown on build %d, the taxi map is flown at another speed since build %d", builds[i], newest)
				leaveOut(maps[key][builds[i]], why)
				notes[#notes + 1] = format("%s was mostly flown at %d on build %d and is flown at %d on build %d: the %d flight%s of build %d are left out", key, before, builds[i], now, newest, #maps[key][builds[i]], #maps[key][builds[i]] == 1 and "" or "s", builds[i])
			end
		end
	end

	-- a route that takes longer or shorter than before
	---@param flights FlightAnalysis[]
	---@return number seconds
	local function seconds(flights)
		local values = {} ---@type number[]
		for i, a in ipairs(flights) do
			values[i] = a.actual - a.jumpTime
		end
		return median(values)
	end
	local routes, routeOrder = byBuild(function(a)
		local route = {} ---@type string[]
		for i, node in ipairs(a.record.route or {}) do
			route[i] = tostring(node)
		end
		return #route >= 2 and (a.data.client .. " " .. table.concat(route, ">")) or nil
	end)
	for _, key in ipairs(routeOrder) do
		local builds = util.keys(routes[key])
		local newest = builds[#builds]
		local now = seconds(routes[key][newest])
		for i = 1, #builds - 1 do
			local flights = routes[key][builds[i]]
			local before = seconds(flights)
			if math.abs(before - now) >= SUPERSEDED_SECONDS then
				leaveOut(flights, format("flown on build %d, the route is flown another way since build %d", builds[i], newest))
				notes[#notes + 1] = format("%s took %.1f sec on build %d and takes %.1f sec on build %d: the %d flight%s of build %d %s left out (flight %d)", flights[1]:routeName(), before, builds[i], now, newest, #flights, #flights == 1 and "" or "s", builds[i], #flights == 1 and "is" or "are", flights[1].index)
			end
		end
	end
	return notes
end

local analyses = analyzeFlights()
local superseded = keepSuperseded and {} or leaveOutSuperseded(analyses)

printf("%d flights in %s\n\n", #analyses, source)
printf("%4s  %-8s %6s  %8s %8s %8s %7s  %8s %8s  %8s %8s  %6s %6s  %s\n", "#", "client", "map", "estimate", "actual", "error", "error%", "now", "off now", "est yd", "flown yd", "speed", "flown", "route")

---What the flights on a taxi map came to.
---@class AnalysisArea
---@field count number
---@field error number The seconds the estimates were off by, added up.
---@field now number The seconds the simulation is off by with the sim file as it is now, added up.
---@field replayed number The flights the simulation has an estimate for now.
---@field used number The speed the estimates used.
---@field speeds table<number, number> The seconds flown at each speed.
---@field distance number[] How far off the estimated distance was for each flight, in percent.

local worst = {} ---@type { analysis: FlightAnalysis, error: number, estimate: number }[] The flights the simulation is off by the most with the sim file as it is now.
local areas = {} ---@type table<string, AnalysisArea>
local areaOrder = {} ---@type string[]
for _, a in ipairs(analyses) do
	local r = a.record
	local typical = a:typicalSpeed()
	local error = a:error()
	local replay = a:replay()
	local errorNow = a:errorNow()
	printf("%4d  %-8s %6s  %8.1f %8.1f %+8.1f %+6.1f%%  %8s %8s  %8.0f %8.0f  %6.2f %6s  %s%s\n", a.index, a.data.client, tostring(r.area or "?"), a.estimate, a.actual, error, a.estimate > 0 and error / a.estimate * 100 or 0, replay and format("%.1f", replay.duration) or "?", errorNow and format("%+.1f", errorNow) or "?", r.distance, a.travelled, r.areaSpeed or 0, typical == nil and "?" or format("%.2f", typical), a:routeName(), (a.hasOverride and " [override]" or "") .. (a.incomplete and (" [incomplete: " .. a.incomplete .. "]") or ""))
	if not a.incomplete then
		local key = a.data.client .. " taxi map " .. tostring(r.area or "?")
		local area = areas[key]
		if not area then
			area = { count = 0, error = 0, now = 0, replayed = 0, used = r.areaSpeed or 0, speeds = {}, distance = {} }
			areas[key] = area
			areaOrder[#areaOrder + 1] = key
		end
		area.count = area.count + 1
		area.error = area.error + math.abs(error)
		if errorNow then
			area.now = area.now + math.abs(errorNow)
			area.replayed = area.replayed + 1
			if math.abs(errorNow) >= worstSeconds then
				worst[#worst + 1] = { analysis = a, error = errorNow, estimate = replay and replay.duration or 0 }
			end
		end
		for j = 2, #a.track do
			local step = a.steps[j]
			if step.kind == "move" then
				local speed = util.round(step.speed, 2)
				area.speeds[speed] = (area.speeds[speed] or 0) + step.dt
			end
		end
		if not a.hasOverride and r.distance > 0 then
			area.distance[#area.distance + 1] = (a.travelled - r.distance) / r.distance * 100
		end
	end
end

print("\nerror is the seconds the flight took longer (+) or shorter (-) than estimated when it was flown")
print("now is what the simulation estimates with the sim file as it is now, and off now the seconds the flight took longer (+) or shorter (-) than that (without the time spent loading another map)")
print("speed is what the estimate used for the taxi map, flown is the speed most of the flight was flown at")
print("incomplete flights did not reach the destination and are left out of the summaries below\n")
if #superseded > 0 then
	print("The game changed how these are flown, so the flights from before the change are left out as well (use --keep-old to keep them)")
	for _, note in ipairs(superseded) do
		print("  " .. note)
	end
	print()
end

for _, key in ipairs(areaOrder) do
	local area = areas[key]
	local speed = util.weightedMedian(area.speeds)
	table.sort(area.distance)
	printf("%s: %d flights, off by %.1f sec on average when flown and %s now, the estimates used %.2f yd/sec and the flights were mostly flown at %s yd/sec", key, area.count, area.error / area.count, area.replayed > 0 and format("%.1f", area.now / area.replayed) or "?", area.used, speed == nil and "?" or format("%.2f", speed))
	if #area.distance > 0 then
		printf(", the flown distance was typically %+.1f%% off the estimate", area.distance[math.floor(#area.distance / 2) + 1])
	end
	print()
end

-- the flights the simulation is still off by, and what makes them differ
table.sort(worst, function(a, b)
	return math.abs(a.error) > math.abs(b.error)
end)
if #worst == 0 then
	printf("\nno flight is off by %s sec or more with the sim file as it is now\n", tostring(worstSeconds))
else
	printf("\n%d flight%s off by %s sec or more with the sim file as it is now, the worst first%s\n", #worst, #worst == 1 and " is" or "s are", tostring(worstSeconds), #worst > 20 and " (20 are shown)" or "")
	for i = 1, math.min(20, #worst) do
		local a = worst[i].analysis
		printf("  flight %d took %.1f sec %s than the %.1f sec the simulation gives: %s\n", a.index, math.abs(worst[i].error), worst[i].error > 0 and "longer" or "shorter", worst[i].estimate, a:routeName())
		for _, line in ipairs(a:whyOff(2)) do
			print("    " .. line)
		end
	end
end

if suggest and #analyses > 0 then
	local suggested = suggestAll(analyses, simFile, joins)
	-- the changes are written and the flights analyzed again, as a change can make room for another (the speed of a taxi map changes what its paths need)
	for pass = 1, apply and 5 or 0 do
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
		if not keepSuperseded then
			leaveOutSuperseded(analyses)
		end
		printf("\nAgain with the changes (pass %d)\n", pass + 1)
		suggested = suggestAll(analyses, simFile, false)
	end
	if apply then
		local off, total = 0, 0
		for _, a in ipairs(analyses) do
			local errorNow = not a.incomplete and a:errorNow() or nil
			if errorNow then
				total = total + 1
				off = off + (math.abs(errorNow) >= worstSeconds and 1 or 0)
			end
		end
		printf("\nwith the sim file as it is now %d of %d flights are off by %s sec or more\n", off, total, tostring(worstSeconds))
	end
end

local shown = 0
for _, a in ipairs(analyses) do
	if all or wanted[a.index] then
		print("\n" .. string.rep("-", 100) .. "\n" .. a:report())
		shown = shown + 1
	end
end

if speeds then
	print("\nthe speed each path was flown at from each of its points (only the points where the speed changed), as lines for the PATH_SPEEDS table of the sim file")
	print("paths flown at one speed are left out, and a path flown on several flights is shown for each of them so they can be compared\n")
	local lines, same = {}, 0
	for _, a in ipairs(analyses) do
		if #a.track >= 2 then
			local paths = a:observe()
			for _, path in ipairs(util.keys(paths)) do
				local info = paths[path]
				local distinct, count = {}, 0
				for _, speed in pairs(info.speeds) do
					if not distinct[speed] then
						distinct[speed] = true
						count = count + 1
					end
				end
				if count < 2 then
					same = same + 1
				else
					local parts = {}
					for _, point in ipairs(util.keys(info.speeds)) do
						parts[#parts + 1] = format("[%d] = %d", point, info.speeds[point])
					end
					local total = #a.data.pathPoints[path]
					local notes = { format("flight %d", a.index) }
					if info.first > 1 or info.last < total then
						notes[#notes + 1] = format("only points %d to %d of %d were flown", info.first, info.last, total)
					end
					if #info.unsure > 0 then
						local unsure = {}
						for i, point in ipairs(info.unsure) do
							unsure[i] = tostring(point)
						end
						notes[#notes + 1] = "not sure about point " .. table.concat(unsure, ", ")
					end
					if a.incomplete then
						notes[#notes + 1] = "incomplete"
					end
					lines[#lines + 1] = { path = path, index = a.index, text = format("\t[%d] = { %s }, -- %s (%s)", path, table.concat(parts, ", "), a.data.pathName(path) or "?", table.concat(notes, ", ")) }
				end
			end
		end
	end
	table.sort(lines, function(a, b)
		if a.path ~= b.path then
			return a.path < b.path
		end
		return a.index < b.index
	end)
	for _, line in ipairs(lines) do
		print(line.text)
	end
	printf("\n%d paths were flown at one speed\n", same)
	shown = shown + 1
end

--
-- MARK: Where there are flights and where there are none
--

if coverage then
	---@class AnalysisCoverage
	---@field data TaxiData
	---@field flights table<number, number> The flights by the map their taxi nodes are on.
	---@field started table<number, boolean> The taxi nodes flights started at.
	---@field passed table<number, boolean> The taxi nodes flights flew past.
	---@field paths table<number, boolean> The paths that were flown.
	---@field single table<number, boolean> The paths that were flown on a flight of just two taxi nodes, which tells how long the path takes on its own.

	local MIN_FLIGHT_YARDS = 100 -- paths between taxi nodes closer than this are too short to be worth a flight
	-- taxi nodes that are not for players: hidden hubs, teleport networks, quest paths and test nodes
	---@param name string
	---@return boolean
	local function isHidden(name)
		return name:find("^%[?[Hh][Ii][Dd][Dd][Ee][Nn]") ~= nil or name:find("Teleport") ~= nil or name:find("^Quest") ~= nil or name:find("^TEMP") ~= nil or name:find("^[Tt][Ee][Ss][Tt]") ~= nil
	end

	local clients, clientOrder = {}, {} ---@type table<string, AnalysisCoverage>, string[]
	for _, a in ipairs(analyses) do
		local route = a.record.route or {}
		if not a.incomplete and #route >= 2 then
			local name = a.data.client
			local seen = clients[name]
			if not seen then
				seen = { data = a.data, flights = {}, started = {}, passed = {}, paths = {}, single = {} }
				clients[name] = seen
				clientOrder[#clientOrder + 1] = name
			end
			local first = a.data.nodes[route[1]]
			if first then
				seen.flights[first.map] = (seen.flights[first.map] or 0) + 1
			end
			seen.started[route[1]] = true
			for k = 2, #route do
				local path = a.data.paths[route[k - 1]] and a.data.paths[route[k - 1]][route[k]]
				if path then
					seen.paths[path] = true
					if #route == 2 then
						seen.single[path] = true
					end
				end
				if k < #route then
					seen.passed[route[k]] = true
				end
			end
		end
	end

	for _, name in ipairs(clientOrder) do
		local seen = clients[name]
		local data = seen.data
		-- the taxi nodes and the paths of each map
		local maps = {} ---@type table<number, { nodes: number[], paths: number, flown: number, open: { from: number, to: number, never: boolean, yards: number }[] }>
		for id, node in pairs(data.nodes) do
			if data.paths[id] and next(data.paths[id]) then -- taxi nodes without paths can not be flown from
				local map = maps[node.map]
				if not map then
					map = { nodes = {}, paths = 0, flown = 0, open = {} }
					maps[node.map] = map
				end
				map.nodes[#map.nodes + 1] = id
				for to, path in pairs(data.paths[id]) do
					map.paths = map.paths + 1
					map.flown = map.flown + (seen.paths[path] and 1 or 0)
					-- what a flight of only that path would tell: a path never flown, or only flown as part of a longer flight
					local target = data.nodes[to]
					if not seen.single[path] and target and not isHidden(node.name) and not isHidden(target.name) then
						local dx, dy, dz = target.x - node.x, target.y - node.y, target.z - node.z
						local yards = math.sqrt(dx * dx + dy * dy + dz * dz)
						if yards >= MIN_FLIGHT_YARDS then
							map.open[#map.open + 1] = { from = id, to = to, never = not seen.paths[path], yards = yards }
						end
					end
				end
			end
		end
		---@param ids number[]
		---@param limit number
		---@return string
		local function names(ids, limit)
			table.sort(ids)
			local list = {}
			for i = 1, math.min(limit, #ids) do
				list[i] = data.nodeName(ids[i])
			end
			return table.concat(list, "; ") .. (#ids > limit and format(" (and %d more)", #ids - limit) or "")
		end

		printf("\nWhere the %s flights are (the maps are the ones the taxi nodes are on, the taxi nodes of both factions are counted)\n", name)
		local with, without = {}, {} ---@type number[], number[]
		for id in pairs(maps) do
			if seen.flights[id] then
				with[#with + 1] = id
			else
				without[#without + 1] = id
			end
		end
		table.sort(with, function(a, b)
			return maps[a].flown / maps[a].paths < maps[b].flown / maps[b].paths
		end)
		for _, id in ipairs(with) do
			local map = maps[id]
			local started, notStarted, passed = 0, {}, 0
			for _, node in ipairs(map.nodes) do
				if seen.started[node] then
					started = started + 1
				else
					notStarted[#notStarted + 1] = node
				end
				passed = passed + (seen.passed[node] and 1 or 0)
			end
			printf("  map %d: %d flights, %d of %d paths flown, started at %d of %d taxi nodes, flew past %d\n", id, seen.flights[id], map.flown, map.paths, started, #map.nodes, passed)
			if #notStarted > 0 then
				printf("    no flight starts at: %s\n", names(notStarted, 6))
			end
			-- the paths to fly next, a small map shows all of them and a big one the shortest
			table.sort(map.open, function(a, b)
				if a.never ~= b.never then
					return a.never
				end
				return a.yards < b.yards
			end)
			local limit = map.paths <= 30 and #map.open or 5
			for i = 1, math.min(limit, #map.open) do
				local open = map.open[i]
				printf("    %s: %s > %s (%.0f yd)\n", open.never and "not flown" or "only flown as part of longer flights", data.nodeName(open.from), data.nodeName(open.to), open.yards)
			end
			if #map.open > limit then
				printf("    and %d more paths without a flight of their own\n", #map.open - limit)
			end
		end
		table.sort(without, function(a, b)
			if #maps[a].nodes ~= #maps[b].nodes then
				return #maps[a].nodes > #maps[b].nodes
			end
			return a < b
		end)
		if #without > 0 then
			print("  maps without flights, the ones with the most taxi nodes first")
			for i = 1, math.min(15, #without) do
				local id = without[i]
				printf("    map %d: %d taxi nodes, %d paths, like %s\n", id, #maps[id].nodes, maps[id].paths, names(maps[id].nodes, 3))
			end
			if #without > 15 then
				printf("    and %d more maps with fewer taxi nodes\n", #without - 15)
			end
		end
	end
	shown = shown + 1
end

if shown == 0 then
	print("\nuse --flight=N or --all to see the details of flights, --speeds for the speed of each path, --joins for how the taxi nodes were flown past, --coverage for where to fly next")
end
