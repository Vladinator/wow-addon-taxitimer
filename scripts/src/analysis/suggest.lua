-- Compares what was flown to what the sim file of a game has, and says what to change in it.
-- The estimates are made by the simulation of the addon itself, with the tables of the sim file changed for a moment to see what they would be with other speeds.
-- The parts of the suggestions are in the `suggest` folder: what a taxi map is flown at is here, and its ramps, the speeds by how close the points are, the speeds of the taxi nodes and of the paths, and the way taxi nodes are flown past are there.

---What was suggested for the sim file of a game.
---@class SuggestedChanges
---@field simFile string
---@field data TaxiData
---@field lines string[] The lines that say what to add, change or remove, as they were shown.

local DISTANCE_SCALE_MIN_FLIGHTS = 3 -- flights on a taxi map without positions (an instance) before its distance is scaled
local DISTANCE_SCALE_MIN_SHARE = 0.02 -- how much longer or shorter than the simulation the flights take, as a share, before it is scaled

---@param ctx AnalysisContext
---@return fun(analyses: FlightAnalysis[], simFile?: string, listJoins?: boolean, prunePaths?: boolean, pruneMap?: number): SuggestedChanges[]
return function(ctx)
	local util = ctx.util
	local format, concat = string.format, table.concat
	local abs = math.abs
	local printf = util.printf

	local folder = ctx.dir .. "/src/analysis/suggest/"
	local common = dofile(folder .. "common.lua")(ctx)
	local ramps = dofile(folder .. "ramps.lua")(ctx, common)
	local spacing = dofile(folder .. "spacing.lua")(ctx, common)
	local suggestNodeSpeeds = dofile(folder .. "nodes.lua")(ctx, common) ---@type fun(m: SuggestMap)
	local paths = dofile(folder .. "paths.lua")(ctx, common)
	local joins = dofile(folder .. "joins.lua")(ctx, common)
	local prune = dofile(folder .. "prune.lua")(ctx, common)
	local findTransit = dofile(ctx.dir .. "/src/analysis/transit.lua")
	local override = common.override

	-- the flights by taxi map, and what speeds they were flown at
	---@param analyses FlightAnalysis[]
	---@return table<number, { flights: FlightAnalysis[], time: table<number, number> }> maps
	---@return number[] mapOrder
	local function groupByMap(analyses)
		local maps, mapOrder = {}, {}
		for _, a in ipairs(analyses) do
			if not a.incomplete and #a.track >= 2 and a.record.area then
				local map = a.record.area
				if not maps[map] then
					maps[map] = { flights = {}, time = {} }
					mapOrder[#mapOrder + 1] = map
				end
				local info = maps[map]
				info.flights[#info.flights + 1] = a
				for j = 2, #a.track do
					local step = a.steps[j]
					if step.kind == "move" then
						local speed = a:roundSpeed(step.speed)
						info.time[speed] = (info.time[speed] or 0) + step.dt
					end
				end
			end
		end
		table.sort(mapOrder)
		return maps, mapOrder
	end

	-- the speed most of the time was flown at is the speed of the taxi map
	---@param time table<number, number> The seconds flown at each speed.
	---@param default number
	---@return number
	local function findCruise(time, default)
		local cruise, cruiseTime = default, -1
		for _, speed in ipairs(util.keys(time)) do
			if time[speed] > cruiseTime then
				cruise, cruiseTime = speed, time[speed]
			end
		end
		return cruise
	end

	-- if the speed of the taxi map is what the flights were flown at
	---@param m SuggestMap
	---@param default number The speed of a taxi map that has no entry.
	local function suggestSpeed(m, default)
		local lib, map, out = m.lib, m.map, m.out
		local now = m.sim.speeds[map] or default
		if m.cruise == now then
			return
		end
		out[#out + 1] = format("  speed: flown at %d, the sim file uses %d (%s)", m.cruise, now, m.sim.speeds[map] and "its entry in AREA_SPEEDS is wrong" or "it has no entry in AREA_SPEEDS")
		if m.cruise == default then
			out[#out + 1] = format("    remove from AREA_SPEEDS:    [%d] = ...", map)
			m.restores[#m.restores + 1] = override(lib.Sim, "AREA_SPEEDS", map, nil)
		else
			out[#out + 1] = format("    %s AREA_SPEEDS:    [%d] = %d,%s", m.sim.speeds[map] and "change in" or "add to", map, m.cruise, #m.flights < 2 and (" -- (" .. common.THIN .. ")") or "")
			m.restores[#m.restores + 1] = override(lib.Sim, "AREA_SPEEDS", map, m.cruise)
		end
	end

	-- an instance gives no positions to tell how far its flights are, so all there is is how long they took: its distance is scaled for the simulation to take as long
	---@param m SuggestMap
	local function suggestDistanceScale(m)
		local lib, map, out = m.lib, m.map, m.out
		local blind = #m.flights >= DISTANCE_SCALE_MIN_FLIGHTS
		for _, a in ipairs(m.flights) do
			blind = blind and a.noPosition
		end
		if not blind then
			return
		end
		local actual, estimated = 0, 0
		for _, a in ipairs(m.flights) do
			local replay = a:replay()
			if replay then
				actual = actual + a.actual - a.jumpTime
				estimated = estimated + replay.duration
			end
		end
		local ratio = estimated > 0 and actual / estimated or 1
		if abs(ratio - 1) >= DISTANCE_SCALE_MIN_SHARE then
			local current = lib.Sim.AREA_DISTANCE_SCALE[map]
			local scaled = util.round((current or 1) * ratio, 3)
			out[#out + 1] = format("  distance: the %d flights took %.1f%% %s than the simulation gives, as there are no positions the distance of the taxi map is scaled", #m.flights, abs(ratio - 1) * 100, ratio > 1 and "longer" or "shorter")
			out[#out + 1] = format("    %s AREA_DISTANCE_SCALE:    [%d] = %s,", current and "change in" or "add to", map, format("%.3f", scaled))
			m.restores[#m.restores + 1] = override(lib.Sim, "AREA_DISTANCE_SCALE", map, scaled)
		end
	end

	-- what to change for one taxi map. The changes are in the tables of the simulation while the next ones are looked at, as one can make room for another.
	---@param m SuggestMap
	---@param default number
	---@param pathState SuggestPaths
	local function suggestMap(m, default, pathState)
		suggestSpeed(m, default)
		suggestDistanceScale(m)
		local tried, takeoffs, landings = ramps.observe(m)
		m.tried = tried
		ramps.suggest(m, takeoffs, landings)
		spacing.suggest(m)
		suggestNodeSpeeds(m)
		paths.suggest(m, pathState)
		for i = #m.restores, 1, -1 do
			m.restores[i]()
		end
		-- with the sim file as it is, to see if the data of the taxi map looks odd
		local odd = 0
		for _, seconds in ipairs(common.flightErrors(m.lib, m.map, m.tried)) do
			odd = odd + (seconds >= common.ODD_SECONDS and 1 or 0)
		end
		m.odd = odd
	end

	-- the entries for single paths that the flights do not need, in place of the other suggestions
	---@param analyses FlightAnalysis[]
	---@param simFile string
	---@param pruneMap? number Only the flights of this taxi map are looked at, the entries of the other taxi maps are not.
	---@return string[] suggestions
	local function pruneClient(analyses, simFile, pruneMap)
		local suggestions = {} ---@type string[]
		printf("\nEntries to take out of %s\n", simFile)
		local lib = analyses[1].lib
		local maps, mapOrder = groupByMap(analyses)
		local transit = findTransit(analyses)
		local state = prune.new()
		local default = util.round(lib.TAXI_SPEED_FALLBACK / lib.TAXI_SPEED_SCALE / 5) * 5
		---@type SuggestSim
		local sim = {
			speeds = lib.Sim.AREA_SPEEDS,
			ramps = lib.Sim.AREA_RAMPS,
			spacing = lib.Sim.AREA_SPACING,
			nodes = lib.Sim.NODE_SPEEDS,
			paths = lib.Sim.PATH_SPEEDS,
			pathRamps = lib.Sim.PATH_RAMPS,
		}
		for _, map in ipairs(mapOrder) do
			if not pruneMap or pruneMap == map then
				local info = maps[map]
				---@type SuggestMap
				local m = { lib = lib, sim = sim, scale = lib.TAXI_SPEED_SCALE, transit = transit, map = map, flights = info.flights, cruise = findCruise(info.time, default), tried = {}, out = {}, restores = {}, odd = 0, average = 0, worst = 0 }
				m.tried = ramps.observe(m)
				prune.map(m, state)
			end
		end
		local unsupported = prune.finish(state, lib)
		if pruneMap then
			unsupported = {} -- the flights of the other taxi maps were not looked at, so what they fly is not known
		end
		if #state.health == 0 then
			print("\n  no flights on that taxi map")
		else
			prune.print(state, suggestions, unsupported)
		end
		return suggestions
	end

	-- Prints what to change in the sim file for the flights of a game to be estimated better.
	---@param analyses FlightAnalysis[] The analyses of the flights, in the order they were recorded.
	---@param simFile string The sim file, for what to say.
	---@param listJoins boolean If every taxi node that was flown past is listed with how it was flown.
	---@return string[] suggestions The lines that say what to add, change or remove, as they were shown.
	local function suggestClient(analyses, simFile, listJoins)
		local suggestions = {} ---@type string[]
		printf("\nSuggested changes to %s\n", simFile)
		local lib = analyses[1].lib
		local scale = lib.TAXI_SPEED_SCALE
		local default = util.round(lib.TAXI_SPEED_FALLBACK / scale / 5) * 5
		local maps, mapOrder = groupByMap(analyses)
		local transit = findTransit(analyses)
		local changes = 0
		local odd = {} ---@type string[]
		local pathState = paths.new()
		---@type SuggestSim
		local sim = {
			speeds = lib.Sim.AREA_SPEEDS,
			ramps = lib.Sim.AREA_RAMPS,
			spacing = lib.Sim.AREA_SPACING,
			nodes = lib.Sim.NODE_SPEEDS,
			paths = lib.Sim.PATH_SPEEDS,
			pathRamps = lib.Sim.PATH_RAMPS,
		}

		for _, map in ipairs(mapOrder) do
			local info = maps[map]
			---@type SuggestMap
			local m = { lib = lib, sim = sim, scale = scale, transit = transit, map = map, flights = info.flights, cruise = findCruise(info.time, default), tried = {}, out = {}, restores = {}, odd = 0, average = 0, worst = 0 }
			suggestMap(m, default, pathState)
			if m.odd > 0 then
				odd[#odd + 1] = format("taxi map %d has %d flight%s %d sec or more off", map, m.odd, m.odd == 1 and "" or "s", common.ODD_SECONDS)
			end
			if #m.out > 0 then
				changes = changes + 1
				printf("\n  taxi map %d (%d flights, mostly flown at %d)\n", map, #m.flights, m.cruise)
				print("  " .. concat(m.out, "\n  "))
				for _, line in ipairs(m.out) do
					suggestions[#suggestions + 1] = line
				end
			else
				printf("\n  taxi map %d (%d flights, mostly flown at %d, off by %.1f sec on average and %.1f at worst): nothing to change\n", map, #m.flights, m.cruise, m.average, m.worst)
			end
		end

		if listJoins then
			joins.printRetraceCandidates(lib, analyses)
		end

		-- where the flights went past a taxi node another way than the simulation flies it
		local joinLines = joins.suggest(lib, analyses, listJoins)
		if #joinLines > 0 then
			changes = changes + 1
			print("\n  flying past taxi nodes")
			for _, line in ipairs(joinLines) do
				print(line)
				suggestions[#suggestions + 1] = line
			end
		end

		if paths.print(pathState, suggestions) then
			changes = changes + 1
		end
		if changes == 0 then
			print("\n  the sim file already matches what was flown")
		end
		print("\n  the speeds are compared rounded to the nearest 5, and the time spent loading another map is left out of how long a flight took")
		if #odd > 0 then
			printf("\n  odd data: %s. Run with --prune (or --prune=MAP for one taxi map) to see which entries for single paths it goes by and which of them are not needed\n", concat(odd, "; "))
		end
		return suggestions
	end

	-- Prints the suggested changes for each of the games the flights are from.
	---@param analyses FlightAnalysis[]
	---@param simFile? string The sim file to compare to instead of the ones of the games.
	---@param listJoins? boolean If every taxi node that was flown past is listed with how it was flown.
	---@return SuggestedChanges[] suggested What was suggested for the sim file of each game.
	return function(analyses, simFile, listJoins, prunePaths, pruneMap)
		local suggested = {} ---@type SuggestedChanges[]
		local clients = {} ---@type table<string, FlightAnalysis[]>
		local order = {} ---@type string[]
		for _, a in ipairs(analyses) do
			local client = a.data.client
			if not clients[client] then
				clients[client] = {}
				order[#order + 1] = client
			end
			clients[client][#clients[client] + 1] = a
		end
		for _, client in ipairs(order) do
			local file = simFile or (ctx.root .. "/libs/TaxiTimerLib/sim_" .. client .. ".lua")
			local lines = prunePaths and pruneClient(clients[client], file, pruneMap) or suggestClient(clients[client], file, listJoins or false)
			suggested[#suggested + 1] = { simFile = file, data = clients[client][1].data, lines = lines }
		end
		return suggested
	end
end
