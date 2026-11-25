-- How the game flies past a taxi node where the simulation does it another way: `NODE_JOINS` and `RETRACE_EXCEPTIONS`, and where the bar shows a taxi node that is flown past: `NODE_STOPS`.

local DIVERGE_SLACK_SECONDS = 1 -- seconds after the last sample on the track of the flight that landed that the last point of the path arriving can be passed, as the routes divide somewhere before the next sample
local JOIN_MIN_YARDS = 50 -- yards the distance the simulation flies must get closer to what a flight flew before another way of flying past a taxi node is suggested
local JOIN_MIN_SECONDS = 3 -- seconds a flight must get closer to its estimate before another way of flying past a taxi node is suggested
local CHECKPOINT_MIN_YARDS = 40 -- yards the flight is from where the simulation reaches the taxi node, for the way the flights flew it to be suggested for that even where the seconds are not far off
local OFFSET_MIN_SECONDS = 3 -- seconds a stop that was asked for later than the bar shows it still landed, for the bar to show it later
local STOP_MIN_SECONDS = 3 -- seconds a taxi node is moved on the timeline by for it to be suggested
local CHECKPOINT_MAX_SECONDS = 0.5 -- seconds each flight can get further from its estimate for that

---Where a flight left the track of a flight that landed at a taxi node.
---@class SuggestLeft
---@field x number
---@field y number
---@field map number

---The flights that flew past a taxi node arriving from one and leaving to another.
---@class SuggestJoin
---@field node number
---@field from number
---@field to number
---@field flights FlightAnalysis[]
---@field seen table<string, number> How many flights flew each `last, first`.
---@field whole number How many flights flew all of the two paths.
---@field divided table<number, number> How many flights left the track of a flight that landed at the taxi node after each last point flown of the path arriving, for the flights it is known for.
---@field landed? number The latest a stop was asked for and the flight still landed at the taxi node, in seconds after take off.
---@field went? number The earliest a stop was asked for and the flight went on past the taxi node.
---@field leaves table<FlightAnalysis, SuggestLeft> Where each flight left the track of a flight that landed at the taxi node, which is where the route divides, for the flights it is known for.

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
	---@param nodeJoins table<number, table<number, table<number, number[]|number>|number>>
	---@param node number
	---@param from number
	---@param to number
	---@param join? number[]|number
	---@return table<number, table<number, number[]|number>|number> ofNode What to have for `node`.
	local function withJoin(nodeJoins, node, from, to, join)
		local ofNode = {}
		for fromNode, toNodes in pairs(nodeJoins[node] or {}) do
			if type(toNodes) == "table" then
				local copy = {}
				for toNode, value in pairs(toNodes) do
					copy[toNode] = value
				end
				ofNode[fromNode] = copy
			else
				ofNode[fromNode] = toNodes
			end
		end
		if type(ofNode[from]) ~= "table" then
			ofNode[from] = {}
		end
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
		local findDivergence, findWindow = dofile(ctx.dir .. "/src/analysis/diverge.lua")(analyses)
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
							join = { node = node, from = from, to = to, flights = {}, seen = {}, whole = 0, leaves = {}, divided = {} }
							join.landed, join.went = findWindow(from, node, to)
							byKey[key] = join
							order[#order + 1] = key
						end
						-- a flight is only counted once for a join, also if it flies past it more than once
						if join.flights[#join.flights] ~= a then
							join.flights[#join.flights + 1] = a
							-- where the route divides is where the last point of the path arriving is, if a flight that landed at the taxi node shows it
							local split = findDivergence(a, from, node)
							-- stops that were asked for tell where it is too late: a stop that still landed was before it (the routes can be seen leaving each other a little before the game stops allowing it), and one that did not was after
							local limit = split and split.seconds + DIVERGE_SLACK_SECONDS or nil
							local landed, went = findWindow(from, node, to)
							if landed then
								limit = math.max(limit or -math.huge, landed + a.start)
							end
							if limit and went then
								limit = math.min(limit, went + a.start)
							end
							if split then
								local sample = a.track[split.sample]
								join.leaves[a] = { x = sample.x, y = sample.y, map = sample.map }
								local divided = a:flownJoin(arriving, leaving, limit)
								if divided then
									join.divided[divided] = (join.divided[divided] or 0) + 1
								end
							end
							-- how the flight flew the corner is what the join is, where the stop can be asked for only goes into the stops and their offsets
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

	-- how far the flights were from where the simulation reaches a taxi node, which is the checkpoint of the bar, as the sum of the yards at the closest the flight came to it
	---@param lib TaxiTimerLib-1.0
	---@param flights FlightAnalysis[]
	---@param node number
	---@param leaves table<FlightAnalysis, SuggestLeft> Where the flights left the track of a flight that landed at the taxi node, for the ones it is known for (the others are measured from the track they flew).
	---@return number yards
	local function checkpointAway(lib, flights, node, leaves)
		local total = 0
		for _, a in ipairs(flights) do
			if not a.noPosition then
				local nodes = {} ---@type TaxiTimerLib-1.0_TaxiRouteNode[]
				for i, id in ipairs(a.record.route) do
					nodes[i] = { nodeID = id }
				end
				local info = lib.GetFlightInfoFromGeometry(lib.GetFlightGeometry(nodes, nil, nil, a.record.trips), a.record.area, a.record.speedModifier)
				local checkpoints = info and lib.GetFlightCheckpoints(info) or {}
				for k = 2, #checkpoints - 1 do
					local point = checkpoints[k].nodeID == node and info and info.points[checkpoints[k].pointIndex]
					if point then
						local leaves_ = leaves[a]
						if leaves_ and a:sameMap(leaves_.map, point.map) then
							total = total + math.sqrt((leaves_.x - point.x) ^ 2 + (leaves_.y - point.y) ^ 2)
						else
							total = total + a:distanceToTrack(point.x, point.y, point.map)
						end
					end
				end
			end
		end
		return total
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
		local nowAway = checkpointAway(lib, join.flights, node, join.leaves)
		local with ---@type number?
		if flown and not (has and format("%d, %d", has[1], has[2]) == flown) then
			local last, first = flown:match("^(%d+), (%d+)$")
			local flownJoin = withJoin(lib.Sim.NODE_JOINS, node, from, to, { tonumber(last), tonumber(first) })
			local restore = override(lib.Sim, "NODE_JOINS", node, flownJoin)
			local withYards
			with, withYards = offBy(lib, join.flights)
			local withAway = checkpointAway(lib, join.flights, node, join.leaves)
			restore()
			-- the flights have to get closer both in how long they take and in how far they fly, or it makes up for something else that is off
			local closer = now - with >= JOIN_MIN_SECONDS * count and nowYards - withYards >= JOIN_MIN_YARDS * count
			-- or the taxi node is reached where the flights were not and now is where they were, with the time not worse
			local reached = not closer and nowAway >= CHECKPOINT_MIN_YARDS * count and withAway < CHECKPOINT_MIN_YARDS * count and withAway <= nowAway / 2 and with - now <= CHECKPOINT_MAX_SECONDS * count
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
			elseif closer or reached then
				kept[#kept + 1] = override(lib.Sim, "NODE_JOINS", node, flownJoin)
				local because = closer and format("%.0f sec closer each with it", (now - with) / count) or format("the taxi node is reached %.0f yd from the flights without it and %.0f yd with it", nowAway / count, withAway / count)
				lines[#lines + 1] = format("    %s NODE_JOINS:    [%d] = { [%d] = { [%d] = { %s } } }, -- %s (%d flight%s, %s%s)", has and "change in" or "add to", node, from, to, flown, name, count, plural, because, common.thinNote(count))
			end
		elseif has then
			-- the simulation may fly it right without the entry by now
			local restore = override(lib.Sim, "NODE_JOINS", node, withJoin(lib.Sim.NODE_JOINS, node, from, to, nil))
			local without = offBy(lib, join.flights)
			local withoutAway = checkpointAway(lib, join.flights, node, join.leaves)
			restore()
			-- it is also needed where the taxi node would be reached somewhere the flights were not
			if without - now < JOIN_MIN_SECONDS * count and withoutAway - nowAway < CHECKPOINT_MIN_YARDS * count then
				kept[#kept + 1] = override(lib.Sim, "NODE_JOINS", node, withJoin(lib.Sim.NODE_JOINS, node, from, to, nil))
				lines[#lines + 1] = format("    remove from NODE_JOINS:    [%d] = { [%d] = { [%d] = ... } } -- %s (the %d flight%s past it are as close without it%s)", node, from, to, name, count, plural, common.thinNote(count))
			end
		end
		return now, with, has, name
	end

	-- where the flights were at the point the bar shows a taxi node at, as the seconds after take off the simulation gives and the flights were closest, and how far from it
	---@param lib TaxiTimerLib-1.0
	---@param a FlightAnalysis
	---@param node number
	---@return number? simulated
	---@return number? flown
	---@return number? yards
	local function checkpointTimes(lib, a, node)
		local nodes = {} ---@type TaxiTimerLib-1.0_TaxiRouteNode[]
		for i, id in ipairs(a.record.route) do
			nodes[i] = { nodeID = id }
		end
		local info = lib.GetFlightInfoFromGeometry(lib.GetFlightGeometry(nodes, nil, nil, a.record.trips), a.record.area, a.record.speedModifier)
		local checkpoints = info and lib.GetFlightCheckpoints(info) or {}
		for k = 2, #checkpoints - 1 do
			local point = checkpoints[k].nodeID == node and info and info.points[checkpoints[k].pointIndex]
			if point then
				local at, yards = a:closestTo(point)
				return checkpoints[k].time - checkpoints[k].offset, at and (at - a.start), yards
			end
		end
	end

	---A taxi node that is flown past where the bar should show it somewhere else than it does.
	---@class SuggestStop
	---@field node number
	---@field from number
	---@field to number
	---@field point number The last point of the path arriving that it is shown at.
	---@field has boolean If the sim file has another one for it.
	---@field nodeName string
	---@field fromName string
	---@field toName string
	---@field text string What the flights say about it, for the line.

	---The stop the sim file has for flying from a taxi node past another to a third one.
	---@param lib TaxiTimerLib-1.0
	---@param node number
	---@param from number
	---@param to number
	---@return number? point
	local function stopOf(lib, node, from, to)
		local ofFrom = lib.Sim.NODE_STOPS[node] and lib.Sim.NODE_STOPS[node][from]
		if type(ofFrom) == "number" then
			return ofFrom
		end
		return ofFrom and ofFrom[to] or nil
	end

	-- the stop for `NODE_STOPS` if the flights that left the track of a flight that landed at a taxi node show it is reached before where the bar shows it, and the flights were not at that point of the bar when it says
	---@param lib TaxiTimerLib-1.0
	---@param join SuggestJoin
	---@return SuggestStop?
	local function suggestStop(lib, join)
		local node, from, to = join.node, join.from, join.to
		local has = lib.Sim.NODE_JOINS[node] and lib.Sim.NODE_JOINS[node][from] and lib.Sim.NODE_JOINS[node][from][to]
		local count = 0
		for _ in pairs(join.leaves) do
			count = count + 1
		end
		-- the flights that left the track agree on where, and the flights that landed show it
		local point, agree = nil, 0 ---@type number?, number
		for divided, flights in pairs(join.divided) do
			if flights > agree then
				point, agree = divided, flights
			end
		end
		if has or count == 0 or not point or agree < count then
			return
		end
		local stops = stopOf(lib, node, from, to)
		if stops == point then
			return
		end
		local flights = {} ---@type FlightAnalysis[]
		for _, a in ipairs(join.flights) do
			if join.leaves[a] then
				flights[#flights + 1] = a
			end
		end
		local moved, closerNow, closerWith = 0, 0, 0 -- seconds the bar moves it by (earlier is negative), and the seconds the flights were from it
		local before = {} ---@type number[]
		for i, a in ipairs(flights) do
			local simulated, flown, yards = checkpointTimes(lib, a, node)
			before[i] = simulated or 0
			-- a flight that was at the point of the bar when it says shows it is right
			if simulated and flown and yards and yards <= a.far and math.abs(flown - simulated) < STOP_MIN_SECONDS then
				return
			end
			closerNow = closerNow + (simulated and flown and math.abs(flown - simulated) or 0)
		end
		local restore = override(lib.Sim, "NODE_STOPS", node, withJoin(lib.Sim.NODE_STOPS, node, from, to, point))
		for i, a in ipairs(flights) do
			local simulated, flown = checkpointTimes(lib, a, node)
			moved = moved + (simulated and simulated - before[i] or 0)
			closerWith = closerWith + (simulated and flown and math.abs(flown - simulated) or 0)
		end
		restore()
		if math.abs(moved / count) >= STOP_MIN_SECONDS and closerWith < closerNow then
			local a = flights[1]
			return {
				node = node,
				from = from,
				to = to,
				point = point,
				has = stops ~= nil,
				nodeName = a.data.nodeName(node),
				fromName = a.data.nodeName(from),
				toName = a.data.nodeName(to),
				text = format("%d flight%s that went past it, with one that landed there: the bar shows it %.0f sec %s with it, and the flights were %.0f sec from it before and %.0f sec with it", count, count == 1 and "" or "s", math.abs(moved / count), moved < 0 and "earlier" or "later", closerNow / count, closerWith / count),
			}
		end
	end

	-- a stop of the sim file for one way of flying past a taxi node that the flights do not need any more, as they are as close to the bar without it (a join or other speeds have since put the taxi node there)
	---@param lib TaxiTimerLib-1.0
	---@param join SuggestJoin
	---@param lines string[]
	---@param kept (fun())[]
	local function staleStop(lib, join, lines, kept)
		local node, from, to = join.node, join.from, join.to
		local ofFrom = lib.Sim.NODE_STOPS[node] and lib.Sim.NODE_STOPS[node][from]
		-- only the stops for one way of going on are looked at, the ones for all of them are for more flights than these
		if type(ofFrom) ~= "table" or ofFrom[to] == nil then
			return
		end
		local flights = {} ---@type FlightAnalysis[]
		for _, a in ipairs(join.flights) do
			if join.leaves[a] then
				flights[#flights + 1] = a
			end
		end
		if #flights == 0 then
			return
		end
		local function off()
			local seconds, reached = 0, 0
			for _, a in ipairs(flights) do
				local simulated, flown, yards = checkpointTimes(lib, a, node)
				if simulated and flown and yards and yards <= a.far then
					seconds, reached = seconds + math.abs(flown - simulated), reached + 1
				end
			end
			return seconds, reached
		end
		local withSeconds, withReached = off()
		local restore = override(lib.Sim, "NODE_STOPS", node, withJoin(lib.Sim.NODE_STOPS, node, from, to, nil))
		local withoutSeconds, withoutReached = off()
		restore()
		if withoutReached >= withReached and withoutSeconds - withSeconds < STOP_MIN_SECONDS * #flights then
			kept[#kept + 1] = override(lib.Sim, "NODE_STOPS", node, withJoin(lib.Sim.NODE_STOPS, node, from, to, nil))
			local a = flights[1]
			lines[#lines + 1] = format("    remove from NODE_STOPS:    [%d] = { [%d] = { [%d] = ... } } -- %s, flying from %s to %s (the %d flight%s past it are as close to it without it)", node, from, to, a.data.nodeName(node), a.data.nodeName(from), a.data.nodeName(to), #flights, #flights == 1 and "" or "s")
		end
	end

	-- the line for `NODE_STOP_OFFSETS` if a stop that was asked for after the point the bar shows the taxi node at still landed there, and the flights passed it at that point
	---@param lib TaxiTimerLib-1.0
	---@param join SuggestJoin
	---@param lines string[]
	---@param kept (fun())[]
	local function suggestOffset(lib, join, lines, kept)
		local node, from, to = join.node, join.from, join.to
		if not join.landed then
			return
		end
		-- when the flights that passed it were at the point of the bar, going by the time the flights took
		local sum, count = 0, 0
		for _, a in ipairs(join.flights) do
			local _, flown, yards = checkpointTimes(lib, a, node)
			if flown and yards and yards <= a.far then
				sum, count = sum + flown, count + 1
			end
		end
		if count == 0 then
			return
		end
		local wanted = join.landed - sum / count
		-- not after where it was seen not to land
		if join.went then
			wanted = math.min(wanted, join.went - sum / count)
		end
		wanted = tonumber(format("%.1f", wanted)) or wanted
		local ofFrom = lib.Sim.NODE_STOP_OFFSETS[node] and lib.Sim.NODE_STOP_OFFSETS[node][from]
		local has = type(ofFrom) == "number" and ofFrom or (ofFrom and ofFrom[to]) or 0
		if wanted < OFFSET_MIN_SECONDS then
			-- an offset that is not needed any more (the bar shows the taxi node where the stop can still be asked for already)
			if has ~= 0 then
				kept[#kept + 1] = override(lib.Sim, "NODE_STOP_OFFSETS", node, withJoin(lib.Sim.NODE_STOP_OFFSETS, node, from, to, nil))
				local a = join.flights[1]
				lines[#lines + 1] = format("    remove from NODE_STOP_OFFSETS:    [%d] = { [%d] = { [%d] = ... } } -- %s, flying from %s to %s (the bar shows the taxi node where a stop asked for %.1f sec after take off still landed already)", node, from, to, a.data.nodeName(node), a.data.nodeName(from), a.data.nodeName(to), join.landed)
			end
			return
		end
		if math.abs(wanted - has) < 1 then
			return
		end
		kept[#kept + 1] = override(lib.Sim, "NODE_STOP_OFFSETS", node, withJoin(lib.Sim.NODE_STOP_OFFSETS, node, from, to, wanted))
		local a = join.flights[1]
		lines[#lines + 1] = format("    %s NODE_STOP_OFFSETS:    [%d] = { [%d] = { [%d] = %.1f } }, -- %s, flying from %s to %s (a stop asked for %.1f sec after take off still landed there%s, and the flights were at the point of the bar %.1f sec after take off)", has ~= 0 and "change in" or "add to", node, from, to, wanted, a.data.nodeName(node), a.data.nodeName(from), a.data.nodeName(to), join.landed, join.went and format(", one asked for %.1f sec did not", join.went) or "", sum / count)
	end

	-- the lines for `NODE_STOPS`: one for each way of flying past a taxi node, or one for every taxi node it goes on to when more than one of them agree on where the route divides
	---@param lib TaxiTimerLib-1.0
	---@param stops SuggestStop[]
	---@param lines string[]
	---@param kept (fun())[]
	local function stopLines(lib, stops, lines, kept)
		local byFrom, order = {}, {} ---@type table<string, SuggestStop[]>, string[]
		for _, stop in ipairs(stops) do
			local key = stop.node .. " " .. stop.from
			if not byFrom[key] then
				byFrom[key] = {}
				order[#order + 1] = key
			end
			table.insert(byFrom[key], stop)
		end
		for _, key in ipairs(order) do
			local group = byFrom[key]
			local first = group[1]
			local same = #group >= 2
			for _, stop in ipairs(group) do
				same = same and stop.point == first.point
			end
			if same then
				-- the flights to more than one taxi node show the same place, which is where the path arriving is flown by all of them
				local ofNode = withJoin(lib.Sim.NODE_STOPS, first.node, first.from, first.to, first.point)
				ofNode[first.from] = first.point
				kept[#kept + 1] = override(lib.Sim, "NODE_STOPS", first.node, ofNode)
				lines[#lines + 1] = format("    add to NODE_STOPS:    [%d] = { [%d] = %d }, -- %s, flying from %s to any taxi node (%d of the ways of going on agree: %s)", first.node, first.from, first.point, first.nodeName, first.fromName, #group, first.text)
			else
				for _, stop in ipairs(group) do
					kept[#kept + 1] = override(lib.Sim, "NODE_STOPS", stop.node, withJoin(lib.Sim.NODE_STOPS, stop.node, stop.from, stop.to, stop.point))
					lines[#lines + 1] = format("    %s NODE_STOPS:    [%d] = { [%d] = { [%d] = %d } }, -- %s, flying from %s to %s (%s)", stop.has and "change in" or "add to", stop.node, stop.from, stop.to, stop.point, stop.nodeName, stop.fromName, stop.toName, stop.text)
				end
			end
		end
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
		local stops = {} ---@type SuggestStop[]
		for _, key in ipairs(order) do
			local stop = suggestStop(lib, byKey[key])
			if stop then
				stops[#stops + 1] = stop
			else
				staleStop(lib, byKey[key], lines, kept)
			end
		end
		stopLines(lib, stops, lines, kept)
		for _, key in ipairs(order) do
			suggestOffset(lib, byKey[key], lines, kept)
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
