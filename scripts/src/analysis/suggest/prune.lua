-- The entries of the sim file for single paths (`PATH_SPEEDS` and `PATH_RAMPS`) that the flights do not need.
-- The speeds of a path are the last thing the simulation falls back on, so as flights come in and the speeds and ramps of the taxi maps are fitted better, an entry that was made from the first flight on a path can end up doing nothing.
-- Each entry is taken out for a moment to see how much worse the flights on its path get without it, and the ones that cost next to nothing are suggested to be removed, one at a time as taking one out can change what another costs.
-- It also says how well the taxi map does without any of the entries (only the speed and the ramps and spacing of the taxi map), which is what a path nobody has flown is estimated with.

local PRUNE_MAX_SECONDS = 1 -- seconds the flights on a path may be off by in all more without its entry for it to be removed
local PRUNE_MAX_FLIGHT = 1 -- and the most any one of them may be off more
local THIN_FLIGHTS = 1 -- entries that this many flights or fewer are all there is to go by are listed, as one flight can be anything

---One entry of the sim file that was looked at.
---@class SuggestPruneEntry
---@field table "PATH_SPEEDS"|"PATH_RAMPS"
---@field path number
---@field name string
---@field flights number How many of the recorded flights fly the path.
---@field cost number How many seconds the flights on the path are off by in all more without the entry.
---@field worst number And how many the one that is worst off is.

---How well the flights of a taxi map are estimated.
---@class SuggestPruneHealth
---@field map number
---@field flights number
---@field now SuggestPruneErrors With the sim file as it is.
---@field zone SuggestPruneErrors With only what the taxi map has, none of the entries for single paths.

---@class SuggestPruneErrors
---@field average number
---@field median number
---@field p90 number The seconds 90% of the flights are within.
---@field over number How many flights are `ODD_SECONDS` or more off.

---What the looking at the entries came to, over all of the taxi maps of a game.
---@class SuggestPrune
---@field removed SuggestPruneEntry[] The entries that are not needed.
---@field kept SuggestPruneEntry[] The entries that are.
---@field health SuggestPruneHealth[]
---@field seen table<string, boolean> The entries that were looked at.
---@field restores (fun())[] What puts back the entries that were taken out.

---@param ctx AnalysisContext
---@param common table
---@return table
return function(ctx, common)
	local util = ctx.util
	local printf = util.printf
	local format = string.format
	local max, min, floor = math.max, math.min, math.floor
	local override, flightErrors = common.override, common.flightErrors

	local prune = {}

	---@return SuggestPrune
	function prune.new()
		return { removed = {}, kept = {}, health = {}, seen = {}, restores = {} }
	end

	-- the flights that fly each path
	---@param flights SuggestFlight[]
	---@return table<number, SuggestFlight[]>
	local function flightsByPath(flights)
		local byPath = {} ---@type table<number, SuggestFlight[]>
		for _, flight in ipairs(flights) do
			local seen = {} ---@type table<number, boolean>
			for _, point in ipairs(flight.geometry.points) do
				local path = point.pathId
				if not seen[path] then
					seen[path] = true
					byPath[path] = byPath[path] or {}
					table.insert(byPath[path], flight)
				end
			end
		end
		return byPath
	end

	---@param errors number[]
	---@return SuggestPruneErrors
	local function summarize(errors)
		local sorted = {} ---@type number[]
		for i, seconds in ipairs(errors) do
			sorted[i] = seconds
		end
		table.sort(sorted)
		local count, sum, over = #sorted, 0, 0
		for _, seconds in ipairs(sorted) do
			sum = sum + seconds
			over = over + (seconds >= common.ODD_SECONDS and 1 or 0)
		end
		if count == 0 then
			return { average = 0, median = 0, p90 = 0, over = 0 }
		end
		return { average = sum / count, median = sorted[floor((count + 1) / 2)], p90 = sorted[min(count, math.ceil(count * 0.9))], over = over }
	end

	-- how many seconds more the flights are off by with an entry taken out, in all and for the one that is off the most
	---@param lib TaxiTimerLib-1.0
	---@param map number
	---@param flights SuggestFlight[]
	---@param name "PATH_SPEEDS"|"PATH_RAMPS"
	---@param path number
	---@return number total
	---@return number worst
	local function costOf(lib, map, flights, name, path)
		local before = flightErrors(lib, map, flights)
		local restore = override(lib.Sim, name, path, nil)
		local after = flightErrors(lib, map, flights)
		restore()
		local total, worst = 0, 0
		for i = 1, #flights do
			local difference = after[i] - before[i]
			total = total + difference
			worst = max(worst, difference)
		end
		return total, worst
	end

	-- Looks at the entries for the paths the flights of a taxi map fly. What is taken out stays out until `prune.finish`, so what the next ones cost is without it.
	---@param m SuggestMap
	---@param state SuggestPrune
	function prune.map(m, state)
		local lib = m.lib
		local data = m.flights[1].data
		if #m.tried == 0 then
			return
		end
		local byPath = flightsByPath(m.tried)

		local now = flightErrors(lib, m.map, m.tried)
		local savedSpeeds, savedRamps = lib.Sim.PATH_SPEEDS, lib.Sim.PATH_RAMPS
		lib.Sim.PATH_SPEEDS, lib.Sim.PATH_RAMPS = {}, {}
		local zone = flightErrors(lib, m.map, m.tried)
		lib.Sim.PATH_SPEEDS, lib.Sim.PATH_RAMPS = savedSpeeds, savedRamps
		state.health[#state.health + 1] = { map = m.map, flights = #m.tried, now = summarize(now), zone = summarize(zone) }

		-- what each costs on its own, the cheapest are looked at first
		local list = {} ---@type SuggestPruneEntry[]
		for _, name in ipairs({ "PATH_SPEEDS", "PATH_RAMPS" }) do
			for path in pairs(lib.Sim[name]) do
				if byPath[path] and not state.seen[name .. path] then
					local total, worst = costOf(lib, m.map, byPath[path], name, path)
					list[#list + 1] = { table = name, path = path, name = data.pathName(path) or "?", flights = #byPath[path], cost = total, worst = worst }
				end
			end
		end
		table.sort(list, function(a, b)
			if a.cost ~= b.cost then
				return a.cost < b.cost
			end
			return a.path < b.path
		end)
		for _, entry in ipairs(list) do
			state.seen[entry.table .. entry.path] = true
			-- once more as what was taken out before it can change what it costs
			entry.cost, entry.worst = costOf(lib, m.map, byPath[entry.path], entry.table, entry.path)
			if entry.cost <= PRUNE_MAX_SECONDS and entry.worst <= PRUNE_MAX_FLIGHT then
				state.restores[#state.restores + 1] = override(lib.Sim, entry.table, entry.path, nil)
				state.removed[#state.removed + 1] = entry
			else
				state.kept[#state.kept + 1] = entry
			end
		end
	end

	-- Puts back what was taken out, and says which entries no recorded flight flies.
	---@param state SuggestPrune
	---@param lib TaxiTimerLib-1.0
	---@return number[] unsupported The paths that have an entry that no flight flies, so there is nothing to tell if it is needed.
	function prune.finish(state, lib)
		for i = #state.restores, 1, -1 do
			state.restores[i]()
		end
		state.restores = {}
		local unsupported = {} ---@type number[]
		for _, name in ipairs({ "PATH_SPEEDS", "PATH_RAMPS" }) do
			for path in pairs(lib.Sim[name]) do
				if not state.seen[name .. path] then
					unsupported[#unsupported + 1] = path
				end
			end
		end
		table.sort(unsupported)
		local seen = {} ---@type table<number, boolean>
		local unique = {} ---@type number[]
		for _, path in ipairs(unsupported) do
			if not seen[path] then
				seen[path] = true
				unique[#unique + 1] = path
			end
		end
		return unique
	end

	---@param errors SuggestPruneErrors
	---@return string
	local function describe(errors)
		return format("%5.1f  %5.1f  %3d", errors.average, errors.p90, errors.over)
	end

	-- Prints what was found, and adds the lines to remove entries to the suggestions.
	---@param state SuggestPrune
	---@param suggestions string[]
	---@param unsupported number[]
	---@return boolean printed
	function prune.print(state, suggestions, unsupported)
		print("\n  how each taxi map is estimated as the sim file is and without its entries for single paths (PATH_SPEEDS and PATH_RAMPS): the seconds the flights are off on average, the seconds 90% of them are within, and how many are 10 sec or more off")
		printf("\n  %-9s %7s   %-19s %-19s\n", "taxi map", "flights", "as the sim file is", "without the entries")
		for _, health in ipairs(state.health) do
			printf("  %-9d %7d   %-19s %-19s%s\n", health.map, health.flights, describe(health.now), describe(health.zone), health.zone.over > health.now.over and "  <- needs them" or "")
		end

		local lines = {} ---@type string[]
		table.sort(state.removed, function(a, b)
			if a.table ~= b.table then
				return a.table < b.table
			end
			return a.path < b.path
		end)
		for _, entry in ipairs(state.removed) do
			lines[#lines + 1] = format("    remove from %s:    [%d] = ... -- %s (%d flight%s, %+.1f sec in all without it%s)", entry.table, entry.path, entry.name, entry.flights, entry.flights == 1 and "" or "s", entry.cost, common.thinNote(entry.flights))
		end
		if #lines > 0 then
			print("\n  entries the flights do not need")
			for _, line in ipairs(lines) do
				print(line)
				suggestions[#suggestions + 1] = line
			end
		else
			printf("\n  every entry that flights fly is needed: %d kept, none can go without a flight being more than %d sec worse or the flights on its path more than %d sec worse in all\n", #state.kept, PRUNE_MAX_FLIGHT, PRUNE_MAX_SECONDS)
		end

		-- entries that one flight alone is behind are the ones to look at when there are more flights
		local thin = {} ---@type SuggestPruneEntry[]
		for _, entry in ipairs(state.kept) do
			if entry.flights <= THIN_FLIGHTS then
				thin[#thin + 1] = entry
			end
		end
		table.sort(thin, function(a, b)
			return a.cost > b.cost
		end)
		if #thin > 0 then
			printf("\n  %d of the %d entries that are kept go by %s flight, the ones that matter most first\n", #thin, #state.kept, THIN_FLIGHTS == 1 and "one" or tostring(THIN_FLIGHTS))
			for i = 1, min(10, #thin) do
				local entry = thin[i]
				printf("    %s [%d] %s: %+.1f sec in all without it\n", entry.table, entry.path, entry.name, entry.cost)
			end
		end
		if #unsupported > 0 then
			local names = {} ---@type string[]
			for i = 1, min(8, #unsupported) do
				names[i] = tostring(unsupported[i])
			end
			printf("\n  %d paths have an entry that no recorded flight flies, so there is nothing to tell if they are needed (%s%s)\n", #unsupported, table.concat(names, ", "), #unsupported > 8 and ", ..." or "")
		end
		print("\n  run the analysis again (with --apply to write the suggestions) after removing entries, as the taxi map is then fitted without them")
		return true
	end

	return prune
end
