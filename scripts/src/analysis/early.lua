-- The flights that asked to land early, for `--early`.
-- Asking to land at the next taxi node ends the flight there, so what the game does is in the flights: when it was asked, where the flight landed, how long it went on for, and the path it took to get there (the samples after it was asked). Those are the flights to fly to see where the point of no return is at a taxi node that is flown past, as only the game tells it.

local MAX_LISTED = 60

---@return fun(analyses: FlightAnalysis[])
return function()
	local format = string.format

	---@param text string
	---@param ... any
	local function say(text, ...)
		print(format(text, ...))
	end

	-- the taxi node of the route the flight ended nearest to, going by the points the simulation reaches them at
	---@param a FlightAnalysis
	---@param info TaxiTimerLib-1.0_FlightInfo
	---@return number? index The place of the taxi node in the route.
	---@return number yards
	local function landedAt(a, info)
		local last = a.track[#a.track]
		local checkpoints = a.lib.GetFlightCheckpoints(info)
		local best, bestYards = nil, math.huge
		for k = 2, #checkpoints do
			local point = a:landingPoint(info, k)
			if point and a:sameMap(last.map, point.map) then
				local yards = math.sqrt((last.x - point.x) ^ 2 + (last.y - point.y) ^ 2)
				if yards < bestYards then
					best, bestYards = k, yards
				end
			end
		end
		return best, bestYards
	end

	-- how far the player was from the rest of the path arriving at the taxi node (what was left out to cut the corner, the way back onto the path a stop turns the flight by) when the stop was asked for
	---@param a FlightAnalysis
	---@param info TaxiTimerLib-1.0_FlightInfo
	---@param k number The place of the taxi node in the route.
	---@param checkpoint TaxiTimerLib-1.0_FlightCheckpoint
	---@param sample { x: number, y: number }
	---@return number? yards
	local function distanceToRamp(a, info, k, checkpoint, sample)
		local point = info.points[checkpoint.pointIndex]
		local arrival = info.arrivals[k - 1]
		local ids = arrival and a.data.pathPoints[arrival]
		if not point or not ids or point.pathId ~= arrival then
			return nil
		end
		local best = math.huge
		for i = point.index, #ids - 1 do
			local p, q = a.data.points[ids[i]], a.data.points[ids[i + 1]]
			if p and q then
				local dx, dy = q.x - p.x, q.y - p.y
				local lengthSquared = dx * dx + dy * dy
				local along = lengthSquared > 0 and math.max(0, math.min(1, ((sample.x - p.x) * dx + (sample.y - p.y) * dy) / lengthSquared)) or 0
				best = math.min(best, math.sqrt((p.x + dx * along - sample.x) ^ 2 + (p.y + dy * along - sample.y) ^ 2))
			end
		end
		return best < math.huge and best or nil
	end

	---@param analyses FlightAnalysis[]
	return function(analyses)
		local rows = {} ---@type string[]
		for _, a in ipairs(analyses) do
			local r = a.record
			if r.early and not a.noPosition and #a.track >= 2 then
				local info = a:replay()
				local landed, yards = nil, 0
				if info then
					landed, yards = landedAt(a, info)
				end
				local checkpoints = info and a.lib.GetFlightCheckpoints(info) or {}
				local asked = r.early - a.start
				local ended = a.end_ - a.start
				local at = landed and checkpoints[landed]
				local name = at and (at.name or a.data.nodeName(at.nodeID)) or "?"
				-- the checkpoints the simulation had passed when it was asked, and the one it is for
				local passed = 0
				for k = 2, #checkpoints do
					if checkpoints[k].time <= asked then
						passed = k
					end
				end
				-- the way back onto the path arriving, at the taxi node the stop was meant for
				local ramp = "-"
				for k = 2, #checkpoints - 1 do
					if info and checkpoints[k].landTime > asked then
						for i = 1, #a.track do
							if a.track[i].t >= r.early then
								local yardsToRamp = checkpoints[k].landDistance > checkpoints[k].distance + 1 and distanceToRamp(a, info, k, checkpoints[k], a.track[i])
								ramp = yardsToRamp and format("%.0f", yardsToRamp) or "-"
								break
							end
						end
						break
					end
				end
				rows[#rows + 1] = format("  %5d  %-9s  %8.1f  %8.1f  %8.1f  %-34s  %8.1f  %+8.1f  %6.0f  %6s  %s", a.index, a.data.client, asked, ended, ended - asked, name:sub(1, 34), at and at.landTime or 0, at and (ended - at.landTime) or 0, yards, ramp, passed > 0 and format("after taxi node %d of the route", passed) or "before the first taxi node")
			end
		end
		say("\nThe flights that asked to land early: %d (seconds are after take off; 'after' is how long the flight went on after it was asked, 'sim' is when the simulation lands at the taxi node it landed at, 'diff' when it landed less that, 'yd' how far from that point it ended, 'ramp yd' how far the flight was from the rest of the path arriving at the taxi node when it was asked, where the flight cuts the corner)", #rows)
		if #rows == 0 then
			return
		end
		say("\n  %5s  %-9s  %8s  %8s  %8s  %-34s  %8s  %8s  %6s  %6s  %s", "#", "client", "asked at", "landed", "after", "landed at", "sim", "diff", "yd", "ramp yd", "asked")
		for i = 1, math.min(#rows, MAX_LISTED) do
			print(rows[i])
		end
		if #rows > MAX_LISTED then
			say("  and %d more", #rows - MAX_LISTED)
		end
	end
end
