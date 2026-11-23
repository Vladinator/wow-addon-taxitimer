-- How the game flies past a taxi node where the simulation does it another way: `NODE_JOINS` and `RETRACE_EXCEPTIONS`.

local JOIN_MIN_YARDS = 50 -- yards the distance the simulation flies must get closer to what a flight flew before another way of flying past a taxi node is suggested
local JOIN_MIN_SECONDS = 3 -- seconds a flight must get closer to its estimate before another way of flying past a taxi node is suggested

---The flights that flew past a taxi node arriving from one and leaving to another.
---@class SuggestJoin
---@field node number
---@field from number
---@field to number
---@field flights FlightAnalysis[]
---@field seen table<string, number> How many flights flew each `last, first`.
---@field whole number How many flights flew all of the two paths.

---@param ctx AnalysisContext
---@param common table
---@return table
return function(ctx, common)
	local util = ctx.util
	local printf = util.printf
	local format, concat = string.format, table.concat
	local abs, max, min = math.abs, math.max, math.min
	local override = common.override

	local joins = {}

	-- `lib.Sim.NODE_JOINS` with the join of flying from `from` past `node` to `to` set to `join` (or without it), the tables that are changed are copies
	---@param nodeJoins table<number, table<number, table<number, number[]>>>
	---@param node number
	---@param from number
	---@param to number
	---@param join? number[]
	---@return table<number, table<number, number[]>> ofNode What to have for `node`.
	local function withJoin(nodeJoins, node, from, to, join)
		local ofNode = {}
		for fromNode, toNodes in pairs(nodeJoins[node] or {}) do
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

	-- the taxi nodes a flight went past in the order it flew them, which includes the ones the game did not give as part of the route (a taxi node that is not shown on the map but is flown past)
	---@param record FlightRecord
	---@return number[]
	local function flownNodes(record)
		local route = record.route or {}
		local nodes = { route[1] } ---@type number[]
		for i = 1, #route - 1 do
			local trip = record.trips and record.trips[i]
			if trip and #trip >= 2 then
				for k = 2, #trip do
					nodes[#nodes + 1] = trip[k]
				end
			else
				nodes[#nodes + 1] = route[i + 1]
			end
		end
		return nodes
	end

	-- the taxi nodes that were flown past, by the paths the flights arrived and left by
	---@param analyses FlightAnalysis[]
	---@return table<string, SuggestJoin> byKey
	---@return string[] order
	local function collectJoins(analyses)
		local byKey, order = {}, {} ---@type table<string, SuggestJoin>, string[]
		for _, a in ipairs(analyses) do
			local route = flownNodes(a.record)
			if not a.incomplete and #a.track >= 2 and a.record.area and a:geometry() then
				for k = 2, #route - 1 do
					local from, node, to = route[k - 1], route[k], route[k + 1]
					local arriving = a.data.paths[from] and a.data.paths[from][node]
					local leaving = a.data.paths[node] and a.data.paths[node][to]
					if arriving and leaving then
						local key = format("%d %d %d", node, from, to)
						local join = byKey[key]
						if not join then
							join = { node = node, from = from, to = to, flights = {}, seen = {}, whole = 0 }
							byKey[key] = join
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
		return byKey, order
	end

	-- how far off the flights are with the joins the simulation has now
	---@param lib TaxiTimerLib-1.0
	---@param flights FlightAnalysis[]
	---@return number seconds
	---@return number yards How far the distance the simulation flies is from what was flown.
	local function offBy(lib, flights)
		local total, yards = 0, 0
		for _, a in ipairs(flights) do
			local nodes = {} ---@type TaxiTimerLib-1.0_TaxiRouteNode[]
			for i, id in ipairs(a.record.route) do
				nodes[i] = { nodeID = id }
			end
			local geometry = lib.GetFlightGeometry(nodes, nil, nil, a.record.trips)
			local info = lib.GetFlightInfoFromGeometry(geometry, a.record.area, a.record.speedModifier)
			total = total + (info and abs(a.actual - a.jumpTime - info.duration) or 0)
			yards = yards + (a.hasOverride and 0 or abs(a.travelled - geometry.distance))
		end
		return total, yards
	end

	-- the line for one join, if what the flights flew is better than what the simulation has, or the entry it has is no longer needed
	---@param lib TaxiTimerLib-1.0
	---@param join SuggestJoin
	---@param lines string[]
	---@param kept (fun())[] What puts back the changes that are suggested, they stay while the rest is looked at so two changes for the same flight are not both suggested for what one of them does.
	---@param excepted table<number, boolean> The taxi nodes that were suggested for `RETRACE_EXCEPTIONS`.
	---@return number now How far off the flights are now, in seconds.
	---@return number? with And with what was flown.
	---@return number[]? has The join the sim file has.
	---@return string name
	local function suggestJoin(lib, join, lines, kept, excepted)
		local node, from, to = join.node, join.from, join.to
		local count = #join.flights
		local has = lib.Sim.NODE_JOINS[node] and lib.Sim.NODE_JOINS[node][from] and lib.Sim.NODE_JOINS[node][from][to]
		local name = format("%s, flying from %s to %s", join.flights[1].data.nodeName(node), join.flights[1].data.nodeName(from), join.flights[1].data.nodeName(to))
		local plural = count == 1 and "" or "s"

		-- what all of the flights flew, if they agree
		local flown ---@type string?
		for seen, flights in pairs(join.seen) do
			if flights == count and seen ~= "?" then
				flown = seen
			end
		end

		local now, nowYards = offBy(lib, join.flights)
		local with ---@type number?
		if flown and not (has and format("%d, %d", has[1], has[2]) == flown) then
			local last, first = flown:match("^(%d+), (%d+)$")
			local flownJoin = withJoin(lib.Sim.NODE_JOINS, node, from, to, { tonumber(last), tonumber(first) })
			local restore = override(lib.Sim, "NODE_JOINS", node, flownJoin)
			local withYards
			with, withYards = offBy(lib, join.flights)
			restore()
			-- the flights have to get closer both in how long they take and in how far they fly, or it makes up for something else that is off
			local closer = now - with >= JOIN_MIN_SECONDS * count and nowYards - withYards >= JOIN_MIN_YARDS * count
			-- a taxi node that is flown into and back out whole only needs to be left out of the rule that skips where the paths run alongside each other
			local excepts = false
			if join.whole == count and closer and not lib.Sim.RETRACE_EXCEPTIONS[node] then
				local restoreException = override(lib.Sim, "RETRACE_EXCEPTIONS", node, true)
				excepts = offBy(lib, join.flights) - with < count
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
				lines[#lines + 1] = format("    %s NODE_JOINS:    [%d] = { [%d] = { [%d] = { %s } } }, -- %s (%d flight%s, %.0f sec closer each with it%s)", has and "change in" or "add to", node, from, to, flown, name, count, plural, (now - with) / count, common.thinNote(count))
			end
		elseif has then
			-- the simulation may fly it right without the entry by now
			local restore = override(lib.Sim, "NODE_JOINS", node, withJoin(lib.Sim.NODE_JOINS, node, from, to, nil))
			local without = offBy(lib, join.flights)
			restore()
			if without - now < JOIN_MIN_SECONDS * count then
				kept[#kept + 1] = override(lib.Sim, "NODE_JOINS", node, withJoin(lib.Sim.NODE_JOINS, node, from, to, nil))
				lines[#lines + 1] = format("    remove from NODE_JOINS:    [%d] = { [%d] = { [%d] = ... } } -- %s (the %d flight%s past it are as close without it%s)", node, from, to, name, count, plural, common.thinNote(count))
			end
		end
		return now, with, has, name
	end

	-- the lines for `NODE_JOINS` where the flights went past a taxi node another way than the simulation flies it
	---@param lib TaxiTimerLib-1.0
	---@param analyses FlightAnalysis[]
	---@param list boolean If every taxi node that was flown past is listed.
	---@return string[] lines
	function joins.suggest(lib, analyses, list)
		local byKey, order = collectJoins(analyses)
		local lines = {}
		local kept = {} ---@type (fun())[]
		local excepted = {} ---@type table<number, boolean>
		if list then
			print("\nThe taxi nodes that were flown past (last is the last point flown of the path arriving, first is the first point flown of the path leaving, off is the seconds each flight is off by now and would be with what was flown in NODE_JOINS)")
			print("  flights  last, first  off now   with  taxi node")
		end
		for _, key in ipairs(order) do
			local join = byKey[key]
			local now, with, has, name = suggestJoin(lib, join, lines, kept, excepted)
			if list then
				local count = #join.flights
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

	---One flight that passed a taxi node where the game could cut a stretch.
	---@class SuggestRetraceCase
	---@field analysis FlightAnalysis
	---@field node number
	---@field saved number
	---@field share number
	---@field seconds number
	---@field cut boolean

	-- the flights that passed one taxi node where the rule that skips where the paths run alongside each other would cut something
	---@param lib TaxiTimerLib-1.0
	---@param analyses FlightAnalysis[]
	---@return SuggestRetraceCase[]
	local function retraceCases(lib, analyses)
		local cases = {} ---@type SuggestRetraceCase[]
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
				local cutDistance = lib.GetFlightGeometry(nodes, nil, nil, a.record.trips).distance
				lib.Sim.SKIP_RETRACED = false
				local wholeDistance = lib.GetFlightGeometry(nodes, nil, nil, a.record.trips).distance
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
		return cases
	end

	-- does one limit on what is saved tell the cuts from the flights that were not cut, for each way of measuring it
	---@param cases SuggestRetraceCase[]
	---@return string[] fits
	local function limitsThatFit(cases)
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
		return fits
	end

	-- The flights that passed one taxi node where the rule that skips where the paths run alongside each other would cut something, and what the game did: how many yards the cut saves, and if the game made it.
	-- This is to see if there is one rule for all taxi nodes (the game cuts when it saves less than some yards) or only the taxi nodes `RETRACE_EXCEPTIONS` and `NODE_JOINS` say.
	---@param lib TaxiTimerLib-1.0
	---@param analyses FlightAnalysis[]
	function joins.printRetraceCandidates(lib, analyses)
		if not lib.Sim.SKIP_RETRACED then
			return
		end
		local cases = retraceCases(lib, analyses)
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
		local numCut = 0
		for _, case in ipairs(cases) do
			numCut = numCut + (case.cut and 1 or 0)
		end
		if numCut == 0 or numCut == #cases then
			print("  all of them went the same way, so there is nothing to tell them apart by yet")
			return
		end
		local fits = limitsThatFit(cases)
		if #fits == 0 then
			printf("  none of the yards, the seconds or the share of the flight that a cut saves tells the cuts from the flights that were not cut (%d flights, %d taxi nodes), so it is something else\n", #cases, numNodes)
		else
			for _, line in ipairs(fits) do
				printf("  %s\n", line)
			end
		end
	end

	return joins
end
