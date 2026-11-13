--[[

Compares the flights recorded by the addon against the taxi data, to show where the estimates are off and why, and what to change in the sim file of the game to make them better.

The estimates are made by the simulation of the addon itself (`catmul.lua` and `taxi.lua` with the db and sim files of the game), so what is compared to is what the addon does.

To record flights set `RECORD_FLIGHTS = true` at the top of `core.lua`, fly, then log out or reload so the saved variables are written.

After the summary of the flights it lists the lines to add, change or remove in the sim file of the game (`sim_mainline.lua`, `sim_forever.lua`, `sim_vanilla.lua` or `sim_classic.lua`) for its speeds to match what was flown.
The speeds of a taxi map come first (its speed, how it takes off and lands, and if it flies slower where the points are close to each other), then the taxi nodes whose mount flies at another speed (the whole flight is flown on the mount of the node it starts at), and a path only gets its own speeds if it is still off by a few seconds with those.
Some paths change the flight speed as they pass their points. These speeds are not part of the client files, so recorded flights are the only source for them.

Runs in Lua 5.1 and later (use `lua`, `lua5.1`, `luajit` or the Lua of the Lua language server):

	lua scripts/analyze.lua <WTF/Account/.../SavedVariables/TaxiTimer.lua> [options]

Options:

	--flight=N      show the details of flight N (as numbered in the summary), can be repeated
	--all           show the details of every flight
	--speeds        show the speed each path was flown at from each of its points, as lines for the PATH_SPEEDS table of the sim file
	--sim=FILE      the sim file to suggest changes to (default is the one of this addon for the game the flights were recorded on)
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

local util = ctx.util
local printf, warn = util.printf, util.warn
local format = string.format

-- the options --------------------------------------------------------------------------------------------------------------

local file ---@type string? The saved variables file.
local wanted = {} ---@type table<number, boolean> The flights to show the details of.
local all, speeds, suggest = false, false, true
local client ---@type TaxiFlavor? The game to use instead of the one the flights were recorded on.
local simFile ---@type string?
local near = 25 ---@type number
local far = 60 ---@type number

---@return never
local function usage()
	warn("usage: lua %s <SavedVariables/TaxiTimer.lua> [--flight=N] [--all] [--speeds] [--sim=FILE] [--no-suggest] [--client=mainline|forever|classic|vanilla] [--near=25] [--far=60]", scriptPath)
	os.exit(1)
end

for _, option in ipairs(arg or {}) do
	if option:match("^--flight=%d+$") then
		wanted[tonumber(option:match("=(%d+)")) or 0] = true
	elseif option == "--all" then
		all = true
	elseif option == "--speeds" then
		speeds = true
	elseif option == "--no-suggest" then
		suggest = false
	elseif option:match("^--sim=.+$") then
		simFile = option:match("^--sim=(.+)$")
	elseif option:match("^--client=%w+$") then
		client = option:match("=(%w+)") --[[@as TaxiFlavor]]
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

if not file or not shim.readfile(file) then
	usage()
end

-- the flights ------------------------------------------------------------------------------------------------------------------

local globals, err = shim.savedvariables(file)
if not globals then
	warn("unable to read %s: %s", file, tostring(err))
	os.exit(1)
end

local db = globals.TaxiTimerDB ---@type { flights?: FlightRecord[] }?
local records = type(db) == "table" and db.flights or nil
if type(records) ~= "table" or #records == 0 then
	warn("no flights in %s, set RECORD_FLIGHTS = true in core.lua and fly somewhere", file)
	os.exit(1)
end

-- the game to compare a flight to, newer records say which game they are from, named like its db file
---@param record FlightRecord
---@return TaxiFlavor
local function getClient(record)
	if type(record.flavor) == "string" then
		return record.flavor
	end
	local project = record.project or 1
	if project == 1 then return "mainline" end
	if project == 2 then return "vanilla" end
	return "classic"
end

local analyses = {} ---@type FlightAnalysis[]
for index, record in ipairs(records) do
	if type(record) ~= "table" or record.version ~= 1 then
		warn("flight %s skipped as it is not in a format this script knows", tostring(index))
	else
		local data, dataErr = loadData(client or getClient(record), simFile)
		if not data then
			warn("flight %s skipped: %s", tostring(index), tostring(dataErr))
		else
			analyses[#analyses + 1] = Flight.new(index, record, data, near, far)
		end
	end
end

printf("%d flights in %s\n\n", #analyses, file)
printf("%4s  %-8s %6s  %8s %8s %8s %7s  %8s %8s  %6s %6s  %s\n", "#", "client", "map", "estimate", "actual", "error", "error%", "est yd", "flown yd", "speed", "flown", "route")

---What the flights on a taxi map came to.
---@class AnalysisArea
---@field count number
---@field error number The seconds the estimates were off by, added up.
---@field used number The speed the estimates used.
---@field speeds table<number, number> The seconds flown at each speed.
---@field distance number[] How far off the estimated distance was for each flight, in percent.

local areas = {} ---@type table<string, AnalysisArea>
local areaOrder = {} ---@type string[]
for _, a in ipairs(analyses) do
	local r = a.record
	local typical = a:typicalSpeed()
	local error = a:error()
	printf("%4d  %-8s %6s  %8.1f %8.1f %+8.1f %+6.1f%%  %8.0f %8.0f  %6.2f %6s  %s%s\n", a.index, a.data.client, tostring(r.area or "?"), a.estimate, a.actual, error, a.estimate > 0 and error / a.estimate * 100 or 0, r.distance, a.travelled, r.areaSpeed or 0, typical == nil and "?" or format("%.2f", typical), a:routeName(), (a.hasOverride and " [override]" or "") .. (a.incomplete and (" [incomplete: " .. a.incomplete .. "]") or ""))
	if not a.incomplete then
		local key = a.data.client .. " taxi map " .. tostring(r.area or "?")
		local area = areas[key]
		if not area then
			area = { count = 0, error = 0, used = r.areaSpeed or 0, speeds = {}, distance = {} }
			areas[key] = area
			areaOrder[#areaOrder + 1] = key
		end
		area.count = area.count + 1
		area.error = area.error + math.abs(error)
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

print("\nerror is the seconds the flight took longer (+) or shorter (-) than estimated")
print("speed is what the estimate used for the taxi map, flown is the speed most of the flight was flown at")
print("incomplete flights did not reach the destination and are left out of the summaries below\n")

for _, key in ipairs(areaOrder) do
	local area = areas[key]
	local speed = util.weightedMedian(area.speeds)
	table.sort(area.distance)
	printf("%s: %d flights, off by %.1f sec on average, the estimates used %.2f yd/sec and the flights were mostly flown at %s yd/sec", key, area.count, area.error / area.count, area.used, speed == nil and "?" or format("%.2f", speed))
	if #area.distance > 0 then
		printf(", the flown distance was typically %+.1f%% off the estimate", area.distance[math.floor(#area.distance / 2) + 1])
	end
	print()
end

if suggest and #analyses > 0 then
	suggestAll(analyses, simFile)
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

if shown == 0 then
	print("\nuse --flight=N or --all to see the details of flights, --speeds for the speed of each path")
end
