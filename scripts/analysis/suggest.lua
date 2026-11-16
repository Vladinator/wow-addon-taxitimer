-- Compares what was flown to what the sim file of a game has, and says what to change in it.
-- The estimates are made by the simulation of the addon itself, with the tables of the sim file changed for a moment to see what they would be with other speeds.

---A flight the speeds of a taxi map are tried on.
---@class SuggestFlight
---@field index number The number of the flight among the recorded ones.
---@field analysis FlightAnalysis
---@field geometry TaxiTimerLib-1.0_FlightGeometry
---@field intervals FlownStretch[]
---@field seconds number How long the flight took, without the time spent loading.

---The speeds by the length of a stretch as `{ yards, speed }` in rising order.
---@alias SuggestSpacing number[][]

---What was suggested for the sim file of a game.
---@class SuggestedChanges
---@field simFile string
---@field data TaxiData
---@field lines string[] The lines that say what to add, change or remove, as they were shown.

---The tables of the simulation that are changed for a moment.
---@alias SuggestTable "AREA_SPEEDS"|"AREA_RAMPS"|"AREA_SPACING"|"NODE_SPEEDS"|"NODE_JOINS"|"RETRACE_EXCEPTIONS"|"PATH_SPEEDS"

---@param ctx AnalysisContext
---@return fun(analyses: FlightAnalysis[], simFile?: string, listJoins?: boolean): SuggestedChanges[]
return function(ctx)
	local util = ctx.util
	local format, concat = string.format, table.concat
	local abs, max, min = math.abs, math.max, math.min
	local printf = util.printf

	local SPACING_YARDS = { 30, 45, 60, 80, 100, 130, 170, 220, 300 } -- the lengths a stretch between two points is sorted by when looking for the speed it is flown at
	local SPACING_MIN_FLIGHTS = 5 -- flights needed on a taxi map before speeds by the length of the stretches are suggested for it
	local SPACING_MIN_SECONDS = 1 -- seconds the flights must get closer to their estimates on average before other speeds by length are suggested
	local PATH_MIN_NET_SECONDS = 1 -- seconds all of the flights on a taxi map must get closer to how long they took for a speed of a path to be suggested
	local PATH_MIN_SEEN = 0.6 -- how much of a path must have been seen in flight for it to be given speeds of its own
	local PATH_MIN_SECONDS = 5 -- seconds a path must differ from the speeds of its taxi map before it is suggested to have its own speeds
	local PATH_CONFIRMED_SECONDS = 2 -- the same, for a path that two or more flights agree on (all of them flew it at the same speeds, and each is this far off the same way)
	local JOIN_MIN_YARDS = 50 -- yards the distance the simulation flies must get closer to what a flight flew before another way of flying past a taxi node is suggested
	local JOIN_MIN_SECONDS = 3 -- seconds a flight must get closer to its estimate before another way of flying past a taxi node is suggested
	local RAMP_MIN_SECONDS = 0.25 -- seconds the flights must get closer to their estimates on average before other speeds for taking off and landing are suggested

	--
	-- MARK: Changing the tables of the simulation for a moment
	--

	-- sets `sim[name][key]` and returns what puts it back
	---@param lib TaxiTimerLib-1.0_Sim
	---@param name SuggestTable
	---@param key number
	---@param value any
	---@return fun() restore Puts back what it was.
	local function override(lib, name, key, value)
		local created = false
		local tbl = lib[name]
		if not tbl then
			tbl = {}
			lib[name] = tbl
			created = true
		end
		local old = tbl[key]
		tbl[key] = value
		return function()
			tbl[key] = old
			if created then
				lib[name] = nil
			end
		end
	end

	--
	-- MARK: Models
	--

	-- how far off the estimates of the flights are with the tables the simulation has now, as the seconds on average and at worst
	---@param lib TaxiTimerLib-1.0
	---@param area number The taxi map.
	---@param flights SuggestFlight[]
	---@return number average
	---@return number worst
	local function modelError(lib, area, flights)
		local sum, worst, count = 0, 0, 0
		for _, flight in ipairs(flights) do
			local info = lib.GetFlightInfoFromGeometry(flight.geometry, area, flight.analysis.record.speedModifier)
			if info then
				local err = abs(flight.seconds - info.duration)
				sum = sum + err
				worst = max(worst, err)
				count = count + 1
			end
		end
		if count == 0 then
			return 0, 0
		end
		return sum / count, worst
	end

	---@param speeds number[] The speed for each of `SPACING_YARDS`.
	---@param cruise number
	---@return SuggestSpacing
	local function spacingFromSpeeds(speeds, cruise)
		local spacing = {}
		for i, yards in ipairs(SPACING_YARDS) do
			if speeds[i] < cruise and (not speeds[i + 1] or speeds[i + 1] ~= speeds[i]) then
				spacing[#spacing + 1] = { yards, speeds[i] }
			end
		end
		return spacing
	end

	-- the speeds by the length of the stretches that bring the estimates of the flights closest to how long they took
	---@param lib TaxiTimerLib-1.0
	---@param area number
	---@param flights SuggestFlight[]
	---@param cruise number
	---@return SuggestSpacing
	local function fitSpacing(lib, area, flights, cruise)
		local speeds = {}
		for i = 1, #SPACING_YARDS do
			speeds[i] = cruise
		end
		local function cost(candidate)
			local restore = override(lib.Sim, "AREA_SPACING", area, spacingFromSpeeds(candidate, cruise))
			local average, worst = modelError(lib, area, flights)
			restore()
			return average + 0.15 * worst
		end
		local best = cost(speeds)
		repeat
			local improved = false
			for i = 1, #SPACING_YARDS do
				for speed = 10, cruise, 5 do
					-- shorter stretches are never flown faster than longer ones
					local try = {}
					for j, value in ipairs(speeds) do
						try[j] = j <= i and min(value, speed) or max(value, speed)
					end
					try[i] = speed
					local value = cost(try)
					if value < best - 0.000001 then
						best = value
						speeds = try
						improved = true
					end
				end
			end
		until not improved
		return spacingFromSpeeds(speeds, cruise)
	end

	---@param spacing SuggestSpacing
	---@return string
	local function spacingList(spacing)
		local parts = {}
		for _, step in ipairs(spacing) do
			parts[#parts + 1] = format("{ %d, %d }", step[1], step[2])
		end
		return concat(parts, ", ")
	end

	---@param a SuggestSpacing
	---@param b SuggestSpacing
	---@return boolean
	local function sameSpacing(a, b)
		if #a ~= #b then
			return false
		end
		for i = 1, #a do
			if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then
				return false
			end
		end
		return true
	end

	-- the speed flown from each of the points first to last, given the speeds set at some of them
	---@param speeds table<number, number> The speeds by the point they are set at.
	---@param first number
	---@param last number
	---@return table<number, number> spread The speed flown from each point.
	local function spreadSpeeds(speeds, first, last, initial)
		local points = util.keys(speeds)
		local speed = initial or 0
		for _, point in ipairs(points) do
			if point <= first then
				speed = speeds[point]
			end
		end
		local spread = {}
		for point = first, last do
			if speeds[point] then
				speed = speeds[point]
			end
			spread[point] = speed
		end
		return spread
	end

	---@param a table<number, number>?
	---@param b table<number, number>?
	---@return boolean
	local function sameSpread(a, b)
		if not a or not b then
			return false
		end
		for point, speed in pairs(a) do
			if b[point] ~= speed then
				return false
			end
		end
		for point in pairs(b) do
			if a[point] == nil then
				return false
			end
		end
		return true
	end

	-- If two flights flew a path at the same speeds, going by the points both of them have a speed for.
	---@param a table<number, number>
	---@param b table<number, number>
	---@return boolean
	local function agreeSpread(a, b)
		local common = 0
		for point, speed in pairs(a) do
			if b[point] ~= nil then
				if b[point] ~= speed then
					return false
				end
				common = common + 1
			end
		end
		return common > 0
	end

	---@param speeds number[]
	---@return string
	local function speedList(speeds)
		if #speeds == 0 then
			return "none"
		end
		local parts = {}
		for i, speed in ipairs(speeds) do
			parts[i] = tostring(speed)
		end
		return concat(parts, ", ")
	end

	-- the most seen of the lists of speeds, on a tie the one the addon has now wins and then the longest
	---@param groups AnalysisGroups
	---@param now string What the sim file has.
	---@return string?
	local function mostSeen(groups, now)
		local best
		for _, key in ipairs(groups.order) do
			local count, bestCount = #groups.byKey[key], best and #groups.byKey[best]
			if not best or count > bestCount or (count == bestCount and best ~= now and (key == now or #key > #best)) then
				best = key
			end
		end
		return best
	end

	---@param text string
	---@return number[]
	local function parseSpeeds(text)
		local speeds = {}
		for speed in text:gmatch("%d+") do
			speeds[#speeds + 1] = tonumber(speed)
		end
		return speeds
	end

	---@param groups AnalysisGroups
	---@param best string
	---@return string
	local function describeSeen(groups, best)
		local others, total = {}, 0
		for _, key in ipairs(groups.order) do
			local flights = groups.byKey[key]
			total = total + #flights
			if key ~= best then
				local list = {}
				for i, index in ipairs(flights) do
					list[i] = tostring(index)
				end
				others[#others + 1] = format("%s on flight %s", key == "" and "none" or key, concat(list, ", "))
			end
		end
		return format("%s on %d of %d flights%s", best == "" and "none" or best, #groups.byKey[best], total, #others > 0 and (" (" .. concat(others, "; ") .. ")") or "")
	end

	--
	-- MARK: Flying past taxi nodes
	--

	-- `lib.Sim.NODE_JOINS` with the join of flying from `from` past `node` to `to` set to `join` (or without it), the tables that are changed are copies
	---@param joins? table<number, table<number, table<number, number[]>>>
	---@param node number
	---@param from number
	---@param to number
	---@param join? number[]
	---@return table<number, table<number, number[]>> ofNode What to have for `node`.
	local function withJoin(joins, node, from, to, join)
		local ofNode = {}
		for fromNode, toNodes in pairs(joins and joins[node] or {}) do
			local copy = {}
			for toNode, value in pairs(toNodes) do
				copy[toNode] = value
			end
			ofNode[fromNode] = copy
		end
		ofNode[from] = ofNode[from] or {}
		ofNode[from][to] = join
		return ofNode
	end

	-- the lines for `NODE_JOINS` where the flights went past a taxi node another way than the simulation flies it
	---@param lib TaxiTimerLib-1.0
	---@param analyses FlightAnalysis[]
	---@param list boolean If every taxi node that was flown past is listed.
	---@return string[] lines
	local function suggestJoins(lib, analyses, list)
		---@class SuggestJoin
		---@field node number
		---@field from number
		---@field to number
		---@field flights FlightAnalysis[]
		---@field seen table<string, number> How many flights flew each `last, first`.
		---@field whole number How many flights flew all of the two paths.

		local joins, order = {}, {} ---@type table<string, SuggestJoin>, string[]
		for _, a in ipairs(analyses) do
			local route = a.record.route or {}
			if not a.incomplete and #a.track >= 2 and a.record.area and a:geometry() then
				for k = 2, #route - 1 do
					local from, node, to = route[k - 1], route[k], route[k + 1]
					local arriving = a.data.paths[from] and a.data.paths[from][node]
					local leaving = a.data.paths[node] and a.data.paths[node][to]
					if arriving and leaving then
						local key = format("%d %d %d", node, from, to)
						local join = joins[key]
						if not join then
							join = { node = node, from = from, to = to, flights = {}, seen = {}, whole = 0 }
							joins[key] = join
							order[#order + 1] = key
						end
						-- a flight is only counted once for a join, also if it flies past it more than once
						if join.flights[#join.flights] ~= a then
							join.flights[#join.flights + 1] = a
							local last, first, whole = a:flownJoin(arriving, leaving)
							local flown = last and format("%d, %d", last, first) or "?"
							join.seen[flown] = (join.seen[flown] or 0) + 1
							join.whole = join.whole + (whole and 1 or 0)
						end
					end
				end
			end
		end
		table.sort(order)

		-- how far off the flights are with the joins the simulation has now
		---@param flights FlightAnalysis[]
		---@return number seconds
		---@return number yards How far the distance the simulation flies is from what was flown.
		local function offBy(flights)
			local total, yards = 0, 0
			for _, a in ipairs(flights) do
				local nodes = {} ---@type TaxiTimerLib-1.0_TaxiRouteNode[]
				for i, id in ipairs(a.record.route) do
					nodes[i] = { nodeID = id }
				end
				local geometry = lib.GetFlightGeometry(nodes)
				local info = lib.GetFlightInfoFromGeometry(geometry, a.record.area, a.record.speedModifier)
				total = total + (info and abs(a.actual - a.jumpTime - info.duration) or 0)
				yards = yards + (a.hasOverride and 0 or abs(a.travelled - geometry.distance))
			end
			return total, yards
		end

		local lines = {}
		local kept = {} ---@type (fun())[] What puts back the changes that are suggested, they stay while the rest is looked at so two changes for the same flight are not both suggested for what one of them does.
		local excepted = {} ---@type table<number, boolean> The taxi nodes that were suggested for `RETRACE_EXCEPTIONS`.
		if list then
			print("\nThe taxi nodes that were flown past (last is the last point flown of the path arriving, first is the first point flown of the path leaving, off is the seconds each flight is off by now and would be with what was flown in NODE_JOINS)")
			print("  flights  last, first  off now   with  taxi node")
		end
		for _, key in ipairs(order) do
			local join = joins[key]
			local node, from, to = join.node, join.from, join.to
			local count = #join.flights
			local has = lib.Sim.NODE_JOINS and lib.Sim.NODE_JOINS[node] and lib.Sim.NODE_JOINS[node][from] and lib.Sim.NODE_JOINS[node][from][to]
			local name = format("%s, flying from %s to %s", join.flights[1].data.nodeName(node), join.flights[1].data.nodeName(from), join.flights[1].data.nodeName(to))
			local plural = count == 1 and "" or "s"

			-- what all of the flights flew, if they agree
			local flown ---@type string?
			for seen, flights in pairs(join.seen) do
				if flights == count and seen ~= "?" then
					flown = seen
				end
			end

			local now, nowYards = offBy(join.flights)
			local with ---@type number?
			if flown and not (has and format("%d, %d", has[1], has[2]) == flown) then
				local last, first = flown:match("^(%d+), (%d+)$")
				local flownJoin = withJoin(lib.Sim.NODE_JOINS, node, from, to, { tonumber(last), tonumber(first) })
				local restore = override(lib.Sim, "NODE_JOINS", node, flownJoin)
				local withYards
				with, withYards = offBy(join.flights)
				restore()
				-- the flights have to get closer both in how long they take and in how far they fly, or it makes up for something else that is off
				local closer = now - with >= JOIN_MIN_SECONDS * count and nowYards - withYards >= JOIN_MIN_YARDS * count
				-- a taxi node that is flown into and back out whole only needs to be left out of the rule that skips where the paths run alongside each other
				local excepts = false
				if join.whole == count and closer and not (lib.Sim.RETRACE_EXCEPTIONS and lib.Sim.RETRACE_EXCEPTIONS[node]) then
					local restoreException = override(lib.Sim, "RETRACE_EXCEPTIONS", node, true)
					excepts = offBy(join.flights) - with < count
					restoreException()
				end
				if excepts then
					kept[#kept + 1] = override(lib.Sim, "RETRACE_EXCEPTIONS", node, true)
					if not excepted[node] then
						excepted[node] = true
						lines[#lines + 1] = format("    add to RETRACE_EXCEPTIONS:    [%d] = true, -- %s (flown into and back out whole)", node, join.flights[1].data.nodeName(node))
					end
					lines[#lines + 1] = format("      %d flight%s from %s to %s, %.0f sec closer each with it", count, plural, join.flights[1].data.nodeName(from), join.flights[1].data.nodeName(to), (now - with) / count)
				elseif closer then
					kept[#kept + 1] = override(lib.Sim, "NODE_JOINS", node, flownJoin)
					lines[#lines + 1] = format("    %s NODE_JOINS:    [%d] = { [%d] = { [%d] = { %s } } }, -- %s (%d flight%s, %.0f sec closer each with it)", has and "change in" or "add to", node, from, to, flown, name, count, plural, (now - with) / count)
				end
			elseif has then
				-- the simulation may fly it right without the entry by now
				local restore = override(lib.Sim, "NODE_JOINS", node, withJoin(lib.Sim.NODE_JOINS, node, from, to, nil))
				local without = offBy(join.flights)
				restore()
				if without - now < JOIN_MIN_SECONDS * count then
					kept[#kept + 1] = override(lib.Sim, "NODE_JOINS", node, withJoin(lib.Sim.NODE_JOINS, node, from, to, nil))
					lines[#lines + 1] = format("    remove from NODE_JOINS:    [%d] = { [%d] = { [%d] = ... } } -- %s (the %d flight%s past it are as close without it)", node, from, to, name, count, plural)
				end
			end
			if list then
				local seen = {}
				for _, what in ipairs(util.keys(join.seen)) do
					seen[#seen + 1] = join.seen[what] == count and what or format("%s (%d)", what, join.seen[what])
				end
				printf("  %7d  %-11s  %7.1f  %5s  %s%s\n", count, concat(seen, " / "), now / count, with and format("%.1f", with / count) or "", name, has and " [in NODE_JOINS]" or "")
			end
		end
		for i = #kept, 1, -1 do
			kept[i]()
		end
		return lines
	end

	-- The flights that passed one taxi node where the rule that skips where the paths run alongside each other would cut something, and what the game did: how many yards the cut saves, and if the game made it.
	-- This is to see if there is one rule for all taxi nodes (the game cuts when it saves less than some yards) or only the taxi nodes `RETRACE_EXCEPTIONS` and `NODE_JOINS` say.
	---@param lib TaxiTimerLib-1.0
	---@param analyses FlightAnalysis[]
	local function printRetraceCandidates(lib, analyses)
		if not lib.Sim.SKIP_RETRACED then
			return
		end
		---@type { analysis: FlightAnalysis, node: number, saved: number, share: number, seconds: number, cut: boolean }[]
		local cases = {}
		local keepExceptions, keepJoins = lib.Sim.RETRACE_EXCEPTIONS, lib.Sim.NODE_JOINS
		lib.Sim.RETRACE_EXCEPTIONS, lib.Sim.NODE_JOINS = {}, {}
		for _, a in ipairs(analyses) do
			local route = a.record.route or {}
			if not a.incomplete and not a.hasOverride and #route == 3 and #a.track >= 2 then
				local nodes = {} ---@type TaxiTimerLib-1.0_TaxiRouteNode[]
				for i, id in ipairs(route) do
					nodes[i] = { nodeID = id }
				end
				lib.Sim.SKIP_RETRACED = true
				local cutDistance = lib.GetFlightGeometry(nodes).distance
				lib.Sim.SKIP_RETRACED = false
				local wholeDistance = lib.GetFlightGeometry(nodes).distance
				lib.Sim.SKIP_RETRACED = true
				if wholeDistance - cutDistance > 1 then
					local saved = wholeDistance - cutDistance
					cases[#cases + 1] = {
						analysis = a,
						node = route[2],
						saved = saved,
						share = saved / wholeDistance * 100,
						seconds = saved / max(a.record.areaSpeed or lib.TAXI_SPEED_FALLBACK, 1),
						cut = abs(a.travelled - cutDistance) < abs(a.travelled - wholeDistance),
					}
				end
			end
		end
		lib.Sim.RETRACE_EXCEPTIONS, lib.Sim.NODE_JOINS = keepExceptions, keepJoins
		if #cases == 0 then
			return
		end
		table.sort(cases, function(x, y)
			return x.saved < y.saved
		end)
		print("\nThe taxi nodes where the game could cut a stretch where the paths run alongside each other (saved is the yards the cut saves)")
		print("  saved yd  seconds  % of flight  game      flight  taxi node")
		local nodes = {}
		for _, case in ipairs(cases) do
			printf("  %8.0f  %7.1f  %10.1f%%  %-8s  %6d  %s\n", case.saved, case.seconds, case.share, case.cut and "cut" or "flew all", case.analysis.index, case.analysis.data.nodeName(case.node))
			nodes[case.node] = true
		end
		local numNodes = 0
		for _ in pairs(nodes) do
			numNodes = numNodes + 1
		end
		-- does one limit on what is saved tell the cuts from the flights that were not cut, for each way of measuring it
		local numCut = 0
		for _, case in ipairs(cases) do
			numCut = numCut + (case.cut and 1 or 0)
		end
		if numCut == 0 or numCut == #cases then
			print("  all of them went the same way, so there is nothing to tell them apart by yet")
			return
		end
		local fits = {}
		for _, measure in ipairs({ { "yards", "saved" }, { "seconds", "seconds" }, { "share of the flight", "share" } }) do
			local maxCut, minWhole, maxWhole, minCut = -util.INF, util.INF, -util.INF, util.INF
			for _, case in ipairs(cases) do
				local value = case[measure[2]]
				if case.cut then
					maxCut, minCut = max(maxCut, value), min(minCut, value)
				else
					minWhole, maxWhole = min(minWhole, value), max(maxWhole, value)
				end
			end
			if maxCut < minWhole then
				fits[#fits + 1] = format("a cut saves less than the flights that were not cut (limit in %s between %.1f and %.1f)", measure[1], maxCut, minWhole)
			elseif maxWhole < minCut then
				fits[#fits + 1] = format("a cut saves more than the flights that were not cut (limit in %s between %.1f and %.1f)", measure[1], maxWhole, minCut)
			end
		end
		if #fits == 0 then
			printf("  none of the yards, the seconds or the share of the flight that a cut saves tells the cuts from the flights that were not cut (%d flights, %d taxi nodes), so it is something else\n", #cases, numNodes)
		else
			for _, line in ipairs(fits) do
				printf("  %s\n", line)
			end
		end
	end

	--
	-- MARK: Suggestions
	--

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

		-- the flights by taxi map, and what speeds they were flown at
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

		local changes = 0
		local pathLines, pathNotes, pathOrder, small = {}, {}, {}, 0
		local pathNew = {} ---@type table<number, table<number, number>|false> What each suggested line sets for the path (`false` to remove it), to see what it does to all of the flights on the path.
		local sim = {
			speeds = lib.Sim.AREA_SPEEDS or {},
			ramps = lib.Sim.AREA_RAMPS or {},
			spacing = lib.Sim.AREA_SPACING or {},
			nodes = lib.Sim.NODE_SPEEDS or {},
			paths = lib.Sim.PATH_SPEEDS or {},
		}

		for _, map in ipairs(mapOrder) do
			local info = maps[map]
			local out = {}
			local restores = {}

			-- the speed most of the time was flown at is the speed of the taxi map
			local cruise, cruiseTime = default, -1
			for _, speed in ipairs(util.keys(info.time)) do
				if info.time[speed] > cruiseTime then
					cruise, cruiseTime = speed, info.time[speed]
				end
			end
			local now = sim.speeds[map] or default
			if cruise ~= now then
				out[#out + 1] = format("  speed: flown at %d, the sim file uses %d (%s)", cruise, now, sim.speeds[map] and "its entry in AREA_SPEEDS is wrong" or "it has no entry in AREA_SPEEDS")
				if cruise == default then
					out[#out + 1] = format("    remove from AREA_SPEEDS:    [%d] = ...", map)
					restores[#restores + 1] = override(lib.Sim, "AREA_SPEEDS", map, nil)
				else
					out[#out + 1] = format("    %s AREA_SPEEDS:    [%d] = %d,", sim.speeds[map] and "change in" or "add to", map, cruise)
					restores[#restores + 1] = override(lib.Sim, "AREA_SPEEDS", map, cruise)
				end
			end

			-- how the flights sped up after taking off and slowed down before landing
			local takeoffs, landings = util.newGroups(), util.newGroups()
			local flights = {}
			for _, a in ipairs(info.flights) do
				local route = a.record.route or {}
				local paths, intervals = a:observe()
				local geometry = a:geometry()
				if geometry and #intervals > 0 then
					flights[#flights + 1] = { index = a.index, analysis = a, geometry = geometry, intervals = intervals, seconds = a.actual - a.jumpTime }
				end
				local from, to = a.data.paths[route[1]], a.data.paths[route[#route - 1]]
				local firstPath = from and from[route[2]]
				local lastPath = to and to[route[#route]]
				for _, path in ipairs(util.keys(paths)) do
					local flown = paths[path]
					local count = #a.data.pathPoints[path]
					local spread = spreadSpeeds(flown.speeds, flown.first, flown.last)
					local fastest, reachesCruise = 0, false
					for _, speed in pairs(spread) do
						fastest = max(fastest, speed)
						if speed == cruise then
							reachesCruise = true
						end
					end
					-- a path with its own speeds is left to those, and if we never got up to speed we can't tell where taking off ends and landing begins
					if not (sim.paths[path] or fastest > cruise) and reachesCruise then
						if path == firstPath and flown.first == 1 then
							local list = {}
							local point = 1
							while point <= flown.last and spread[point] < cruise do
								list[#list + 1] = spread[point]
								point = point + 1
							end
							util.addToGroup(takeoffs, concat(list, ", "), a.index)
						end
						if path == lastPath and flown.last == count then
							local list = {}
							local point = count - 1
							while point >= flown.first and spread[point] < cruise do
								table.insert(list, 1, spread[point])
								point = point - 1
							end
							util.addToGroup(landings, concat(list, ", "), a.index)
						end
					end
				end
			end

			local ramp = sim.ramps[map] or { takeoff = {}, landing = {} }
			-- taxi maps with speeds by the length of the stretches leave what is flown slower to those, their ramp is only what is the same on every flight
			if not sim.spacing[map] or #sim.spacing[map] == 0 then
				local takeoff = mostSeen(takeoffs, concat(ramp.takeoff, ", "))
				local landing = mostSeen(landings, concat(ramp.landing, ", "))
				if takeoff and landing and (takeoff ~= concat(ramp.takeoff, ", ") or landing ~= concat(ramp.landing, ", ")) then
					-- what most flights did is not always what brings the estimates closest, so a taxi map that already has speeds for taking off and landing only gets others if they do
					local better = true
					local candidate = { takeoff = parseSpeeds(takeoff), landing = parseSpeeds(landing) }
					if sim.ramps[map] then
						local currentError = modelError(lib, map, flights)
						local restore = override(lib.Sim, "AREA_RAMPS", map, candidate)
						local candidateError = modelError(lib, map, flights)
						restore()
						better = candidateError < currentError - RAMP_MIN_SECONDS
					end
					if better then
						out[#out + 1] = format("  speeds after taking off: %s, the sim file has %s", describeSeen(takeoffs, takeoff), speedList(ramp.takeoff))
						out[#out + 1] = format("  speeds before landing: %s, the sim file has %s", describeSeen(landings, landing), speedList(ramp.landing))
						if takeoff == "" and landing == "" then
							out[#out + 1] = format("    remove from AREA_RAMPS:    [%d] = ...", map)
						else
							out[#out + 1] = format("    %s AREA_RAMPS:    [%d] = { takeoff = { %s }, landing = { %s } },", sim.ramps[map] and "change in" or "add to", map, takeoff, landing)
						end
						local takeoffCount, landingCount = #takeoffs.byKey[takeoff], #landings.byKey[landing]
						local takeoffTotal, landingTotal = 0, 0
						for _, list in pairs(takeoffs.byKey) do takeoffTotal = takeoffTotal + #list end
						for _, list in pairs(landings.byKey) do landingTotal = landingTotal + #list end
						if takeoffCount < 2 or landingCount < 2 or takeoffCount * 2 <= takeoffTotal or landingCount * 2 <= landingTotal then
							out[#out + 1] = "    not sure about this one as too few flights agree, fly a few more single path flights on this taxi map"
						end
						if takeoff == "" and landing == "" then
							candidate = nil
						end
						restores[#restores + 1] = override(lib.Sim, "AREA_RAMPS", map, candidate)
					end
				end
			end

			-- if flying slower where the points are close to each other brings the estimates closer to how long the flights took
			local average, worst = modelError(lib, map, flights)
			if #flights >= SPACING_MIN_FLIGHTS then
				local fitted = fitSpacing(lib, map, flights, max(cruise, 10))
				local restore = override(lib.Sim, "AREA_SPACING", map, fitted)
				local fittedAverage, fittedWorst = modelError(lib, map, flights)
				restore()
				if not sameSpacing(fitted, sim.spacing[map] or {}) and fittedAverage <= average - SPACING_MIN_SECONDS then
					out[#out + 1] = format("  speeds by how close the points are: the %d flights are off by %.1f sec on average (%.1f at worst) with the sim file, and by %.1f sec (%.1f at worst) with these", #flights, average, worst, fittedAverage, fittedWorst)
					if #fitted > 0 then
						out[#out + 1] = format("    %s AREA_SPACING:    [%d] = { %s },", sim.spacing[map] and "change in" or "add to", map, spacingList(fitted))
					else
						out[#out + 1] = format("    remove from AREA_SPACING:    [%d] = ...", map)
					end
					restores[#restores + 1] = override(lib.Sim, "AREA_SPACING", map, #fitted > 0 and fitted or nil)
					average, worst = fittedAverage, fittedWorst
				end
			end

			-- the taxi nodes whose mount flies at another speed than the others of the taxi map, as the whole flight is flown on the mount of the node it starts at
			local byNode, nodeOrder = {}, {} ---@type table<number, SuggestFlight[]>, number[]
			for _, flight in ipairs(flights) do
				local first = (flight.analysis.record.route or {})[1]
				if first then
					if not byNode[first] then
						byNode[first] = {}
						nodeOrder[#nodeOrder + 1] = first
					end
					table.insert(byNode[first], flight)
				end
			end
			table.sort(nodeOrder)
			for _, node in ipairs(nodeOrder) do
				local nodeFlights = byNode[node]
				-- the speed the flights from the node were flown at for most of the time
				local time = {} ---@type table<number, number>
				for _, flight in ipairs(nodeFlights) do
					for _, stretch in ipairs(flight.intervals) do
						if stretch.speed and stretch.yards > 0 then
							time[stretch.speed] = (time[stretch.speed] or 0) + stretch.yards / (stretch.speed * scale)
						end
					end
				end
				local dominant, dominantTime = nil, 0
				for _, speed in ipairs(util.keys(time)) do
					if time[speed] > dominantTime then
						dominant, dominantTime = speed, time[speed]
					end
				end
				local had = sim.nodes[node]
				local wanted = dominant ~= cruise and dominant or nil -- a node that flies like the rest of the taxi map needs none
				if dominant and wanted ~= had then
					-- how much closer the flights from the node get to how long they took
					local function offBy()
						local total = 0
						for _, flight in ipairs(nodeFlights) do
							local flightInfo = lib.GetFlightInfoFromGeometry(flight.geometry, map, flight.analysis.record.speedModifier)
							total = total + (flightInfo and abs(flight.seconds - flightInfo.duration) or 0)
						end
						return total
					end
					local before = offBy()
					local restore = override(lib.Sim, "NODE_SPEEDS", node, wanted)
					local after = offBy()
					restore()
					if before - after >= PATH_MIN_SECONDS then
						local name = nodeFlights[1].analysis.data.nodeName(node)
						local count = #nodeFlights
						if wanted then
							out[#out + 1] = format("    %s NODE_SPEEDS:    [%d] = %d, -- %s (%d flight%s from it end up %.0f sec closer with it)", had and "change in" or "add to", node, wanted, name, count, count == 1 and "" or "s", before - after)
							if count < 2 then
								out[#out + 1] = "    only one flight starts at this taxi node, fly another one from it on a different path to see that it is the node and not the path"
							end
						else
							out[#out + 1] = format("    remove from NODE_SPEEDS:    [%d] = ... -- %s (the %d flight%s from it fly like the rest of the taxi map)", node, name, count, count == 1 and "" or "s")
						end
						-- a speed seen on one flight is not written, so the paths of that flight are looked at without it (otherwise it would hide what its paths need)
						if count >= 2 or not wanted then
							restores[#restores + 1] = override(lib.Sim, "NODE_SPEEDS", node, wanted)
						end
					end
				end
			end

			-- the paths that are off by more than a few seconds with the speeds of the taxi map need their own speeds
			local savedPaths = lib.Sim.PATH_SPEEDS
			lib.Sim.PATH_SPEEDS = {}

			-- a few seconds off on one flight can be anything, but when two or more flights flew a path at the same speeds and each is off the same way it is the path
			local confirmed = {} ---@type table<number, boolean>
			local onMap = {} ---@type table<number, boolean> The paths the flights of this taxi map flew.
			do
				local seenOn = {} ---@type table<number, { gain: number, spread: table<number, number> }[]>
				for _, flight in ipairs(flights) do
					local without = lib.GetFlightInfoFromGeometry(flight.geometry, map, flight.analysis.record.speedModifier)
					if without then
						local byPath = {} ---@type table<number, { interval: table, step: table }[]>
						for i, interval in ipairs(flight.intervals) do
							byPath[interval.path] = byPath[interval.path] or {}
							table.insert(byPath[interval.path], { interval = interval, step = without.steps[i] })
						end
						for path, flown in pairs(flight.analysis:observe()) do
							local stretches = byPath[path]
							if stretches then
								onMap[path] = true
								local observed, predicted, seenYards, totalYards = 0, 0, 0, 0
								for _, stretch in ipairs(stretches) do
									totalYards = totalYards + stretch.interval.yards
									if stretch.interval.speed then
										seenYards = seenYards + stretch.interval.yards
										observed = observed + stretch.interval.yards / (stretch.interval.speed * scale)
										predicted = predicted + (stretch.step and stretch.step.distance / stretch.step.speed or 0)
									end
								end
								if totalYards == 0 or seenYards >= totalYards * PATH_MIN_SEEN then
									seenOn[path] = seenOn[path] or {}
									table.insert(seenOn[path], {
										gain = (predicted - observed) * (seenYards > 0 and totalYards / seenYards or 1),
										spread = spreadSpeeds(flown.speeds, flown.first, flown.last),
									})
								end
							end
						end
					end
				end
				for path, list in pairs(seenOn) do
					local agree = #list >= 2
					for i = 1, #list do
						if abs(list[i].gain) < PATH_CONFIRMED_SECONDS or (list[i].gain > 0) ~= (list[1].gain > 0) or not agreeSpread(list[1].spread, list[i].spread) then
							agree = false
						end
					end
					confirmed[path] = agree
				end
			end

			for _, flight in ipairs(flights) do
				local a = flight.analysis
				local without = lib.GetFlightInfoFromGeometry(flight.geometry, map, flight.analysis.record.speedModifier)
				local paths = a:observe()
				if without then
					-- the stretches of each path in this flight, and the seconds the speeds of the taxi map give them
					local byPath = {}
					for i, interval in ipairs(flight.intervals) do
						local list = byPath[interval.path]
						if not list then
							list = {}
							byPath[interval.path] = list
						end
						list[#list + 1] = { interval = interval, step = without.steps[i] }
					end
					-- the order the paths were flown in with the speed each was entered and left at: a speed carries on into the next path, so a path that starts at the speed the one before it ended at does not set it
					local runs, runOf = {}, {}
					for _, interval in ipairs(flight.intervals) do
						local run = runs[#runs]
						if not run or run.path ~= interval.path then
							run = { path = interval.path }
							runs[#runs + 1] = run
							runOf[interval.path] = runOf[interval.path] or #runs
						end
						if interval.speed then
							run.entry = run.entry or interval.speed
							run.exit = interval.speed
						end
					end
					for _, path in ipairs(util.keys(paths)) do
						local flown = paths[path]
						local stretches = byPath[path]
						if stretches then
							-- the stretches we did not see (where the flight changed map, or was too far away to be sure) are left out, what is seen is scaled up to the whole path
							local observed, predicted, seenYards, totalYards = 0, 0, 0, 0
							for _, stretch in ipairs(stretches) do
								totalYards = totalYards + stretch.interval.yards
								if stretch.interval.speed then
									seenYards = seenYards + stretch.interval.yards
									observed = observed + stretch.interval.yards / (stretch.interval.speed * scale)
									predicted = predicted + (stretch.step and stretch.step.distance / stretch.step.speed or 0)
								end
							end
							local seen = totalYards == 0 or seenYards >= totalYards * PATH_MIN_SEEN
							if not seen and abs(predicted - observed) * totalYards / max(seenYards, 1) >= PATH_MIN_SECONDS and not pathLines[path] and not pathNotes[path] then
								pathNotes[path] = format("    path %d (%s) looks %.0f sec %s than the speeds of the taxi map give, but only %.0f%% of it was seen in flight %d. Fly it again to see all of it", path, a.data.pathName(path) or "?", abs(predicted - observed) * totalYards / max(seenYards, 1), predicted > observed and "shorter" or "longer", seenYards / totalYards * 100, a.index)
							end
							if seen then
								local gain = (predicted - observed) * (seenYards > 0 and totalYards / seenYards or 1)
								local count = #a.data.pathPoints[path]
								-- the last point of a path sets no speed as the flight does not go on from it, so a path flown up to the point before it was flown all the way
								local whole = flown.first == 1 and flown.last >= count - 1
								local name = a.data.pathName(path) or "?"
								local runIndex = runOf[path] or 1
								local run, before = runs[runIndex] or {}, runs[runIndex - 1]
								local inherited = lib.Sim.CARRY_SPEED and before ~= nil and before.exit ~= nil and run.entry == before.exit
								-- the points we did not see at the ends of the path were skipped by the game as the flight passed a taxi node, and are not the start or the end of the flight
								local nearlyWhole = lib.Sim.CARRY_SPEED and not (flown.first == 1 and flown.last == count)
									and (flown.first == 1 or (runIndex > 1 and flown.first <= 4))
									and (flown.last >= count - 1 or (runIndex < #runs and flown.last >= count - 4))
								local had = sim.paths[path] and spreadSpeeds(sim.paths[path], flown.first, flown.last, inherited and run.entry or nil) or nil
								local spread = spreadSpeeds(flown.speeds, flown.first, flown.last)
								if had then
									had[count] = nil -- the last point sets no speed as the flight ends there
								end
								spread[count] = nil
								local text = format("%.0f sec %s than the speeds of the taxi map give", abs(gain), gain > 0 and "shorter" or "longer")
								-- a path that is flown at one speed all the way does not need every point of it to be seen, the points next to a taxi node we passed are skipped by the game
								local distinct, numDistinct = {}, 0
								for _, speed in pairs(spread) do
									if not distinct[speed] then
										distinct[speed] = true
										numDistinct = numDistinct + 1
									end
								end
								local uniform = not whole and numDistinct == 1 and (flown.last - flown.first + 1) >= count * PATH_MIN_SEEN
								if abs(gain) < (confirmed[path] and PATH_CONFIRMED_SECONDS or PATH_MIN_SECONDS) then
									if had and whole then
										if not pathLines[path] then
											pathOrder[#pathOrder + 1] = path
										end
										pathNew[path] = false
										pathLines[path] = format("    remove from PATH_SPEEDS:    [%d] = ... -- %s (flight %d, only %s)", path, name, a.index, text)
									elseif not had and flown.time > 0 and abs(gain) >= 1 then
										small = small + 1
									end
								elseif not sameSpread(had, spread) then
									if whole or nearlyWhole or uniform then
										local parts = {}
										local newSpeeds = {} ---@type table<number, number>
										if uniform then
											if not inherited then
												parts[1] = format("[1] = %d", next(distinct))
												newSpeeds[1] = next(distinct)
											end
											text = text .. format(", points %d to %d of %d were flown, all at one speed", flown.first, flown.last, count)
										else
											for _, point in ipairs(util.keys(flown.speeds)) do
												-- the speed it was entered at is the one the path before it left at, so it is not the path that sets it
												if point ~= count and not (inherited and point == flown.first) then
													parts[#parts + 1] = format("[%d] = %d", point, flown.speeds[point])
													newSpeeds[point] = flown.speeds[point]
												end
											end
											if not whole then
												text = text .. format(", points %d to %d of %d were flown", flown.first, flown.last, count)
											end
										end
										if #parts == 0 then
											-- nothing is set by this path, a speed it was given in the sim file is carried on from the path before it
											if had and sim.paths[path] then
												if not pathLines[path] then
													pathOrder[#pathOrder + 1] = path
												end
												pathNew[path] = false
												pathLines[path] = format("    remove from PATH_SPEEDS:    [%d] = ... -- %s (flight %d, the speed is carried on from the path before it)", path, name, a.index)
											end
										else
										local unsure = {}
										for i, point in ipairs(flown.unsure) do
											unsure[i] = tostring(point)
										end
										if not pathLines[path] then
											pathOrder[#pathOrder + 1] = path
										end
										pathNew[path] = newSpeeds
										pathLines[path] = format("    %s PATH_SPEEDS:    [%d] = { %s }, -- %s (flight %d, %s%s)", had and "change in" or "add to", path, concat(parts, ", "), name, a.index, text, #unsure > 0 and (", not sure about point " .. concat(unsure, ", ")) or "")
										end
									elseif not pathLines[path] then
										pathNotes[path] = format("    path %d (%s) is %s%s, but flight %d only flew points %d to %d of %d. Fly it on its own (not passing through its ends) to get all of it", path, name, text, had and " and differs from the sim file" or "", a.index, flown.first, flown.last, count)
									end
								end
							end
						end
					end
				end
			end
			lib.Sim.PATH_SPEEDS = savedPaths

			-- a path is flown by more than the flight it was seen on, so what a line sets must make all of the flights on the path closer to how long they took, or the flights disagree
			local function secondsOff()
				local sum = 0
				for _, flight in ipairs(flights) do
					local result = lib.GetFlightInfoFromGeometry(flight.geometry, map, flight.analysis.record.speedModifier)
					sum = sum + (result and abs(flight.seconds - result.duration) or 0)
				end
				return sum
			end
			for _, path in ipairs(pathOrder) do
				local new = pathNew[path]
				-- only the flights of this taxi map say if a path they flew is better with it, the lines of the paths of other taxi maps are for those to judge
				if new ~= nil and pathLines[path] and onMap[path] then
					local before = secondsOff()
					local restore = override(lib.Sim, "PATH_SPEEDS", path, new or nil)
					local after = secondsOff()
					restore()
					if before - after < PATH_MIN_NET_SECONDS then
						pathNotes[path] = format("    path %d (%s) would not make the flights on it any closer (%.1f sec off now, %.1f sec off with it), so the flights on it disagree or it needs other speeds, and it is left alone", path, (flights[1] and flights[1].analysis.data.pathName(path)) or "?", before, after)
						pathLines[path] = nil
					end
				end
			end

			for i = #restores, 1, -1 do
				restores[i]()
			end

			if #out > 0 then
				changes = changes + 1
				printf("\n  taxi map %d (%d flights, mostly flown at %d)\n", map, #info.flights, cruise)
				print("  " .. concat(out, "\n  "))
				for _, line in ipairs(out) do
					suggestions[#suggestions + 1] = line
				end
			else
				printf("\n  taxi map %d (%d flights, mostly flown at %d, off by %.1f sec on average and %.1f at worst): nothing to change\n", map, #info.flights, cruise, average, worst)
			end
		end

		if listJoins then
			printRetraceCandidates(lib, analyses)
		end

		-- where the flights went past a taxi node another way than the simulation flies it
		local joinLines = suggestJoins(lib, analyses, listJoins)
		if #joinLines > 0 then
			changes = changes + 1
			print("\n  flying past taxi nodes")
			for _, line in ipairs(joinLines) do
				print(line)
				suggestions[#suggestions + 1] = line
			end
		end

		local noteLines = {}
		table.sort(pathOrder)
		local lines = {}
		for _, path in ipairs(pathOrder) do
			lines[#lines + 1] = pathLines[path]
		end
		for _, path in ipairs(util.keys(pathNotes)) do
			if not pathLines[path] then
				noteLines[#noteLines + 1] = pathNotes[path]
			end
		end
		if #lines > 0 or #noteLines > 0 then
			changes = changes + 1
			print("\n  paths with their own speeds")
			for _, line in ipairs(lines) do
				print(line)
				suggestions[#suggestions + 1] = line
			end
			for _, line in ipairs(noteLines) do
				print(line)
			end
		end
		if small > 0 then
			printf("\n  %d paths were off by 1 to %d sec with the speeds of their taxi map and are left alone\n", small, PATH_MIN_SECONDS)
		end
		if changes == 0 then
			print("\n  the sim file already matches what was flown")
		end
		print("\n  the speeds are compared rounded to the nearest 5, and the time spent loading another map is left out of how long a flight took")
		return suggestions
	end

	-- Prints the suggested changes for each of the games the flights are from.
	---@param analyses FlightAnalysis[]
	---@param simFile? string The sim file to compare to instead of the ones of the games.
	---@param listJoins? boolean If every taxi node that was flown past is listed with how it was flown.
	---@return SuggestedChanges[] suggested What was suggested for the sim file of each game.
	return function(analyses, simFile, listJoins)
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
			suggested[#suggested + 1] = { simFile = file, data = clients[client][1].data, lines = suggestClient(clients[client], file, listJoins or false) }
		end
		return suggested
	end
end
