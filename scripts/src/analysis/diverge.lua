-- Where the route divides at a taxi node that a flight passed without landing, going by a flight that landed there coming from the same taxi node: the two flew the same stretch of the path and the one that passed leaves the track of the one that landed where the route divides.
-- The routes leave each other at a shallow angle, so the distance that tells a flight went by a point (`--near`) would let it seem to stay on the track for hundreds of yards. A short distance is used instead, as the two fly the same path.

local format = string.format

local DIVERGE_NEAR = 8 -- yards from the track of the flight that landed that a flight is still on it

---What was found for a flight that passed a taxi node.
---@class AnalysisDivergenceFound
---@field lander FlightAnalysis The flight that landed at the taxi node.
---@field sample number The index of the last sample of the flight that is on the track of the one that landed.
---@field seconds number Seconds after the click that sample was taken, as the flights are numbered in `track`.

---@alias AnalysisDivergenceFinder fun(passer: FlightAnalysis, from: number, node: number): AnalysisDivergenceFound?

---When a stop was asked for at a taxi node that is flown past, from the flights that asked: the latest it was asked and the flight still landed there, and the earliest it was asked and the flight went on past it. The point of no return is between the two.
---@alias AnalysisStopWindow fun(from: number, node: number, to: number): number?, number?

---Walks the samples of a flight that passed a taxi node and finds the longest stretch that was on the track of one that landed at it, whose end is where the two routes divide.
---@param passer FlightAnalysis
---@param lander FlightAnalysis
---@return number? sample
local function divergenceSample(passer, lander)
	local track = passer.track
	local best, runStart ---@type number?, number?
	local bestLength = 0
	for i = 1, #track do
		local on = not (i > 1 and passer.steps[i].kind == "jump") and lander:distanceToTrack(track[i].x, track[i].y, track[i].map) <= DIVERGE_NEAR
		if on and not runStart then
			runStart = i
		end
		if runStart and (not on or i == #track) then
			local last = on and i or i - 1
			if last - runStart + 1 > bestLength then
				best, bestLength = last, last - runStart + 1
			end
			runStart = nil
		end
	end
	return best
end

---The taxi node of the route the flight ended nearest to, going by the points the simulation reaches them at.
---@param a FlightAnalysis
---@param checkpoints TaxiTimerLib-1.0_FlightCheckpoint[]
---@param info TaxiTimerLib-1.0_FlightInfo
---@return number? index The place of the taxi node in the route.
local function landedAt(a, checkpoints, info)
	local last = a.track[#a.track]
	local best, bestYards = nil, math.max(a.far, 100)
	for k = 2, #checkpoints do
		local point = a:landingPoint(info, k)
		if point and a:sameMap(last.map, point.map) then
			local yards = math.sqrt((last.x - point.x) ^ 2 + (last.y - point.y) ^ 2)
			if yards < bestYards then
				best, bestYards = k, yards
			end
		end
	end
	return best
end

---@param analyses FlightAnalysis[]
---@return AnalysisDivergenceFinder
---@return AnalysisStopWindow
return function(analyses)
	-- the flights that landed at a taxi node, by the taxi node they came from and the one they landed at
	local landers = {} ---@type table<string, FlightAnalysis[]>
	for _, a in ipairs(analyses) do
		local route = a.record.route
		-- the time between samples is not known across a loading screen, and where the game gives no positions there is no track
		if not a.incomplete and not a.noPosition and a.jumpTime == 0 and type(route) == "table" and #route >= 2 and #a.track >= 2 then
			local key = route[#route - 1] .. " " .. route[#route]
			landers[key] = landers[key] or {}
			table.insert(landers[key], a)
		end
	end

	-- the stops that were asked for, by the way of flying past the taxi node they were meant for
	local landed, went = {}, {} ---@type table<string, number>, table<string, number>
	for _, a in ipairs(analyses) do
		if a.record.early and not a.noPosition and a.jumpTime == 0 and #a.track >= 2 then
			local info = a:replay()
			local checkpoints = info and a.lib.GetFlightCheckpoints(info) or {}
			local ended = info and landedAt(a, checkpoints, info)
			if info and ended then
				local asked = a.record.early - a.start
				-- the taxi node it was meant for is the next one when it was asked, going by when the flight lands at them
				for k = 2, #checkpoints - 1 do
					if checkpoints[k].landTime > asked then
						local key = format("%d %d %d", checkpoints[k].nodeID, checkpoints[k - 1].nodeID, checkpoints[k + 1].nodeID)
						if ended == k then
							landed[key] = math.max(landed[key] or -math.huge, asked)
						elseif ended > k then
							went[key] = math.min(went[key] or math.huge, asked)
						end
						break
					end
				end
			end
		end
	end

	local function window(from, node, to)
		local key = format("%d %d %d", node, from, to)
		return landed[key], went[key]
	end

	local function find(passer, from, node)
		if passer.noPosition or passer.jumpTime ~= 0 or #passer.track < 2 then
			return nil
		end
		local best ---@type AnalysisDivergenceFound?
		for _, lander in ipairs(landers[from .. " " .. node] or {}) do
			if lander ~= passer then
				local sample = divergenceSample(passer, lander)
				-- the one that was followed the longest tells the most
				if sample and (not best or sample > best.sample) then
					best = { lander = lander, sample = sample, seconds = passer.track[sample].t }
				end
			end
		end
		return best
	end

	return find, window
end
