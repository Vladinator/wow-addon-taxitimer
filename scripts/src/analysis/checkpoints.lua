-- When the flights reached the taxi nodes along their way, for `--checkpoints`.
-- The bar of the addon shows a taxi node of the route where the simulation says it is reached, and the stop that can be asked for there. The time of the whole flight can be right while that is not, for example where the simulation flies into a city that the game flies past, so this looks at each taxi node a flight passed: the seconds the simulation gives for it against the seconds the flight really took to be at the same point.

local MIN_SECONDS = 3 -- how many seconds a taxi node is off by to be listed
local MAX_LISTED = 40
local MIN_DIVERGE_YARDS = 50 -- yards the simulation puts a taxi node from where the flight left the track of the one that landed to be listed

---A taxi node that a flight flew past, with when the simulation and the flight reached it.
---@class AnalysisCheckpoint
---@field flight FlightAnalysis
---@field node number
---@field name string
---@field simulated number Seconds after take off the simulation gives.
---@field flown? number Seconds after take off the flight was at the point of the simulation, `nil` if it never was near it.
---@field offBy? number `flown - simulated`.
---@field away? number Yards the flight was from the point of the simulation at its closest, when it never was near it.
---@field wholeOff number How many seconds the whole flight is off by with the simulation.

---@param ctx AnalysisContext
---@return fun(analyses: FlightAnalysis[])
return function(ctx)
	local format = string.format

	---@param text string
	---@param ... any
	local function say(text, ...)
		print(format(text, ...))
	end

	---The taxi nodes of the flights that were passed without landing.
	---@param analyses FlightAnalysis[]
	---@return AnalysisCheckpoint[]
	local function collect(analyses)
		local found = {} ---@type AnalysisCheckpoint[]
		for _, a in ipairs(analyses) do
			-- the time between the samples is not known across a loading screen, and where the game has no positions there is nothing to tell where the flight was
			if not a.incomplete and not a.noPosition and a.jumpTime == 0 then
				local info = a:replay()
				local whole = a:errorNow()
				if info and whole then
					local checkpoints = a.lib.GetFlightCheckpoints(info)
					for k = 2, #checkpoints - 1 do
						local checkpoint = checkpoints[k]
						local point = info.points[checkpoint.pointIndex]
						local at = point and a:passedAt(point, -math.huge)
						local flown = at and (at - a.start) or nil
						local node = a.data.nodes[checkpoint.nodeID]
						found[#found + 1] = {
							flight = a,
							node = checkpoint.nodeID,
							name = node and node.name or tostring(checkpoint.nodeID),
							simulated = checkpoint.time,
							flown = flown,
							away = point and not flown and a:distanceToTrack(point.x, point.y, point.map) or nil,
							offBy = flown and (flown - checkpoint.time) or nil,
							wholeOff = whole,
						}
					end
				end
			end
		end
		return found
	end

	---Where a flight that passed a taxi node left the track of a flight that landed there, which is where the route divides.
	---@class AnalysisDivergence
	---@field flight FlightAnalysis The flight that passed the taxi node.
	---@field lander FlightAnalysis The flight that landed at it, arriving from the same taxi node.
	---@field node number
	---@field from number
	---@field name string
	---@field leftAt number Seconds after take off the flight left the track of the one that landed.
	---@field simulated number Seconds after take off the simulation gives for the taxi node.
	---@field yards number How far the place it left the track is from the point of the simulation.
	---@field wholeOff number
	---@field confirmed boolean If the flight was at the point of the simulation when the simulation says it is, so the taxi node is reached where and when the simulation says whatever the track of the flight that landed does.

	---The flights that passed a taxi node with the flights that landed at it coming from the same taxi node, and where the first left the track of the second.
	---@param analyses FlightAnalysis[]
	---@return AnalysisDivergence[]
	local function divergences(analyses)
		local find = dofile(ctx.dir .. "/src/analysis/diverge.lua")(analyses)
		local passers = {} ---@type FlightAnalysis[]
		for _, a in ipairs(analyses) do
			if not a.incomplete and #(a.record.route or {}) >= 3 then
				passers[#passers + 1] = a
			end
		end
		local found = {} ---@type AnalysisDivergence[]
		for _, a in ipairs(passers) do
			local info = a:replay()
			local whole = a:errorNow()
			local checkpoints = info and a.lib.GetFlightCheckpoints(info) or {}
			for k = 2, #checkpoints - 1 do
				local from, node = checkpoints[k - 1].nodeID, checkpoints[k].nodeID
				local split = find(a, from, node)
				local point = info and info.points[checkpoints[k].pointIndex]
				local flownAt, flownYards = nil, nil
				if point then
					flownAt, flownYards = a:closestTo(point)
				end
				if split and point and whole then
					local sample = a.track[split.sample]
					local nodeInfo = a.data.nodes[node]
					found[#found + 1] = {
						flight = a,
						lander = split.lander,
						node = node,
						from = from,
						name = nodeInfo and nodeInfo.name or tostring(node),
						leftAt = sample.t - a.start,
						simulated = checkpoints[k].time - checkpoints[k].offset,
						yards = a:sameMap(sample.map, point.map) and math.sqrt((sample.x - point.x) ^ 2 + (sample.y - point.y) ^ 2) or math.huge,
						wholeOff = whole,
						confirmed = flownAt ~= nil and (flownYards or math.huge) <= a.far and math.abs(flownAt - a.start - (checkpoints[k].time - checkpoints[k].offset)) < MIN_SECONDS,
					}
				end
			end
		end
		return found
	end

	---@param analyses FlightAnalysis[]
	return function(analyses)
		local found = collect(analyses)
		local missed, off, measured = {}, {}, 0
		for _, c in ipairs(found) do
			if not c.offBy then
				missed[#missed + 1] = c
			else
				measured = measured + 1
				if math.abs(c.offBy) >= MIN_SECONDS then
					off[#off + 1] = c
				end
			end
		end
		table.sort(off, function(a, b)
			return math.abs(a.offBy) > math.abs(b.offBy)
		end)
		table.sort(missed, function(a, b)
			return (a.away or 0) > (b.away or 0)
		end)

		say("\nChecking when the taxi nodes along the way are reached: %d passed by %d flights, %d the simulation is %d sec or more from, %d the flight was never near the point the simulation reaches it at", #found, #analyses, #off, MIN_SECONDS, #missed)
		if #found == 0 then
			return
		end
		say("seconds are after take off; 'node off' is when the flight was at the point of the simulation less when the simulation gives, 'flight off' is the same for the whole flight")
		say("\n  %5s  %-9s  %8s  %8s  %9s  %10s  %s", "#", "client", "sim", "flown", "node off", "flight off", "taxi node passed")
		for i = 1, math.min(#off, MAX_LISTED) do
			local c = off[i]
			say("  %5d  %-9s  %8.1f  %8.1f  %+9.1f  %+10.1f  %s", c.flight.index, c.flight.data.client, c.simulated, c.flown, c.offBy, c.wholeOff, c.name)
		end
		if #off > MAX_LISTED then
			say("  and %d more", #off - MAX_LISTED)
		end
		if #missed > 0 then
			say("\nthe flight was never near the point the simulation reaches the taxi node at, the farthest first:")
			say("  %5s  %-9s  %8s  %8s  %s", "#", "client", "sim", "away yd", "taxi node passed")
			for i = 1, math.min(#missed, MAX_LISTED) do
				local c = missed[i]
				say("  %5d  %-9s  %8.1f  %8.0f  %s", c.flight.index, c.flight.data.client, c.simulated, c.away or 0, c.name)
			end
			if #missed > MAX_LISTED then
				say("  and %d more", #missed - MAX_LISTED)
			end
		end
		say("\n%d of %d measured taxi nodes are within %d sec", measured - #off, measured, MIN_SECONDS)

		local split = divergences(analyses)
		table.sort(split, function(a, b)
			return math.abs(a.leftAt - a.simulated) > math.abs(b.leftAt - b.simulated)
		end)
		local differ = 0
		for _, d in ipairs(split) do
			differ = differ + ((not d.confirmed and (math.abs(d.leftAt - d.simulated) >= MIN_SECONDS or d.yards >= MIN_DIVERGE_YARDS)) and 1 or 0)
		end
		say("\nWhere the route divides, going by flights that passed a taxi node and flights that landed at it coming from the same one: %d taxi nodes passed, %d where the simulation puts it %d sec or %d yd from where the flight left the track of the one that landed and the flight was not at that point of the simulation when it says (the taxi nodes where it was are left out, as the flight itself shows them right)", #split, differ, MIN_SECONDS, MIN_DIVERGE_YARDS)
		if #split == 0 then
			return
		end
		say("\n  %5s  %5s  %-9s  %8s  %8s  %8s  %8s  %s", "#", "lands", "client", "left at", "sim", "diff", "yards", "taxi node passed")
		local listed = 0
		for _, d in ipairs(split) do
			if listed < MAX_LISTED and not d.confirmed and (math.abs(d.leftAt - d.simulated) >= MIN_SECONDS or d.yards >= MIN_DIVERGE_YARDS) then
				listed = listed + 1
				say("  %5d  %5d  %-9s  %8.1f  %8.1f  %+8.1f  %8.0f  %s", d.flight.index, d.lander.index, d.flight.data.client, d.leftAt, d.simulated, d.leftAt - d.simulated, d.yards, d.name)
			end
		end
	end
end
