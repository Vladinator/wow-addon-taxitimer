-- What the parts of the suggestions have in common: changing the tables of the simulation for a moment, and how far off the estimates are.

---A flight the speeds of a taxi map are tried on.
---@class SuggestFlight
---@field index number The number of the flight among the recorded ones.
---@field analysis FlightAnalysis
---@field geometry TaxiTimerLib-1.0_FlightGeometry
---@field intervals FlownStretch[]
---@field seconds number How long the flight took, without the time spent loading.

---The tables of the simulation that are changed for a moment.
---@alias SuggestTable "AREA_SPEEDS"|"AREA_DISTANCE_SCALE"|"AREA_RAMPS"|"AREA_SPACING"|"NODE_SPEEDS"|"NODE_JOINS"|"NODE_STOPS"|"NODE_STOP_OFFSETS"|"RETRACE_EXCEPTIONS"|"PATH_SPEEDS"|"PATH_RAMPS"

---The tables of the simulation as they were when the suggestions began, the changes that are tried are in the entries of these.
---@class SuggestSim
---@field speeds table<number, number>
---@field ramps table<number, TaxiTimerLib-1.0_TaxiAreaRamp>
---@field spacing table<number, number[][]>
---@field nodes table<number, number>
---@field paths table<number, table<number, number>>
---@field pathRamps table<number, TaxiTimerLib-1.0_PathRamp>

---What is looked at for one taxi map. Each part of the suggestions adds what it suggests to `out`, and what puts back what it changed to `restores`.
---@class SuggestMap
---@field lib TaxiTimerLib-1.0
---@field sim SuggestSim
---@field scale number
---@field transit table<number, number> The taxi nodes that flights only pass through, which are not places to fly from or to.
---@field map number The taxi map.
---@field flights FlightAnalysis[] The flights on it.
---@field cruise number The speed most of the time was flown at.
---@field tried SuggestFlight[] The flights the speeds are tried on, filled in when they are observed.
---@field out string[]
---@field restores (fun())[]
---@field odd number How many of the flights are `ODD_SECONDS` or more off with the tables the simulation has (filled in when the suggestions for the taxi map are done).
---@field average number How far off the estimates of the flights are, as the seconds on average.
---@field worst number And at worst.

---@param ctx AnalysisContext
---@return table
return function(ctx)
	local util = ctx.util
	local abs, max = math.abs, math.max

	local common = {}

	common.PATH_MIN_SECONDS = 5 -- seconds a path must differ from the speeds of its taxi map before it is suggested to have its own speeds
	common.ODD_SECONDS = 10 -- seconds a flight can be off by before the data of its taxi map looks odd
	common.THIN = "based on one flight" -- what a suggestion says when one flight is all there is to go by, it is not written unless asked for

	-- how a suggestion says it goes by one flight, to put at the end of what is in brackets after it
	---@param flights number How many flights it goes by.
	---@return string
	function common.thinNote(flights)
		return flights < 2 and (", " .. common.THIN) or ""
	end

	-- sets `sim[name][key]` and returns what puts it back
	---@param lib TaxiTimerLib-1.0_Sim
	---@param name SuggestTable
	---@param key number
	---@param value any
	---@return fun() restore Puts back what it was.
	function common.override(lib, name, key, value)
		local tbl = lib[name]
		local old = tbl[key]
		tbl[key] = value
		return function()
			tbl[key] = old
		end
	end

	-- how far off the estimates of the flights are with the tables the simulation has now, as the seconds on average and at worst
	---@param lib TaxiTimerLib-1.0
	---@param area number The taxi map.
	---@param flights SuggestFlight[]
	---@return number average
	---@return number worst
	function common.modelError(lib, area, flights)
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

	-- how many seconds the estimate of each of the flights is off by, in the order of the flights, with the tables the simulation has now
	---@param lib TaxiTimerLib-1.0
	---@param area number
	---@param flights SuggestFlight[]
	---@return number[] errors
	function common.flightErrors(lib, area, flights)
		local errors = {} ---@type number[]
		for i, flight in ipairs(flights) do
			local result = lib.GetFlightInfoFromGeometry(flight.geometry, area, flight.analysis.record.speedModifier)
			errors[i] = result and abs(flight.seconds - result.duration) or 0
		end
		return errors
	end

	-- how far the taxi nodes along the way are from when the flights were there, with the tables the simulation has now: the seconds in all for the ones the flights were near the point of the simulation at, and how many of them that is
	---@param lib TaxiTimerLib-1.0
	---@param area number
	---@param flights SuggestFlight[]
	---@return number seconds
	---@return number reached
	function common.checkpointsOff(lib, area, flights)
		local seconds, reached = 0, 0
		for _, flight in ipairs(flights) do
			local info = lib.GetFlightInfoFromGeometry(flight.geometry, area, flight.analysis.record.speedModifier)
			if info then
				for _, fit in ipairs(flight.analysis:checkpointFits(info)) do
					if fit.yards <= flight.analysis.far then
						seconds = seconds + abs(fit.seconds)
						reached = reached + 1
					end
				end
			end
		end
		return seconds, reached
	end

	-- how many seconds the estimates of the flights are off by in all, with the tables the simulation has now
	---@param lib TaxiTimerLib-1.0
	---@param area number
	---@param flights SuggestFlight[]
	---@return number
	function common.secondsOff(lib, area, flights)
		local sum = 0
		for _, flight in ipairs(flights) do
			local result = lib.GetFlightInfoFromGeometry(flight.geometry, area, flight.analysis.record.speedModifier)
			sum = sum + (result and abs(flight.seconds - result.duration) or 0)
		end
		return sum
	end

	-- the speed flown from each of the points first to last, given the speeds set at some of them
	---@param speeds table<number, number> The speeds by the point they are set at.
	---@param first number
	---@param last number
	---@param initial? number The speed flown before the first point sets one.
	---@return table<number, number> spread The speed flown from each point.
	function common.spreadSpeeds(speeds, first, last, initial)
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
	function common.sameSpread(a, b)
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

	return common
end
