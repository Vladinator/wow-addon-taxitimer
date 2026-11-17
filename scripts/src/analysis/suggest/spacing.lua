-- If flying slower where the points are close to each other brings the estimates closer to how long the flights took, as `AREA_SPACING`.

---The speeds by the length of a stretch as `{ yards, speed }` in rising order.
---@alias SuggestSpacing number[][]

local SPACING_YARDS = { 30, 45, 60, 80, 100, 130, 170, 220, 300 } -- the lengths a stretch between two points is sorted by when looking for the speed it is flown at
local SPACING_MIN_FLIGHTS = 5 -- flights needed on a taxi map before speeds by the length of the stretches are suggested for it
local SPACING_MIN_SECONDS = 1 -- seconds the flights must get closer to their estimates on average before other speeds by length are suggested

---@param _ AnalysisContext
---@param common table
---@return table
return function(_, common)
	local format, concat = string.format, table.concat
	local max, min = math.max, math.min
	local override, modelError = common.override, common.modelError

	local spacing = {}

	---@param speeds number[] The speed for each of `SPACING_YARDS`.
	---@param cruise number
	---@return SuggestSpacing
	local function spacingFromSpeeds(speeds, cruise)
		local result = {}
		for i, yards in ipairs(SPACING_YARDS) do
			if speeds[i] < cruise and (not speeds[i + 1] or speeds[i + 1] ~= speeds[i]) then
				result[#result + 1] = { yards, speeds[i] }
			end
		end
		return result
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

	---@param list SuggestSpacing
	---@return string
	local function spacingList(list)
		local parts = {}
		for _, step in ipairs(list) do
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

	---@param m SuggestMap
	function spacing.suggest(m)
		local lib, map, out = m.lib, m.map, m.out
		local average, worst = modelError(lib, map, m.tried)
		m.average, m.worst = average, worst
		if #m.tried < SPACING_MIN_FLIGHTS then
			return
		end
		local fitted = fitSpacing(lib, map, m.tried, max(m.cruise, 10))
		local restore = override(lib.Sim, "AREA_SPACING", map, fitted)
		local fittedAverage, fittedWorst = modelError(lib, map, m.tried)
		restore()
		if not sameSpacing(fitted, m.sim.spacing[map] or {}) and fittedAverage <= average - SPACING_MIN_SECONDS then
			out[#out + 1] = format("  speeds by how close the points are: the %d flights are off by %.1f sec on average (%.1f at worst) with the sim file, and by %.1f sec (%.1f at worst) with these", #m.tried, average, worst, fittedAverage, fittedWorst)
			if #fitted > 0 then
				out[#out + 1] = format("    %s AREA_SPACING:    [%d] = { %s },", m.sim.spacing[map] and "change in" or "add to", map, spacingList(fitted))
			else
				out[#out + 1] = format("    remove from AREA_SPACING:    [%d] = ...", map)
			end
			m.restores[#m.restores + 1] = override(lib.Sim, "AREA_SPACING", map, #fitted > 0 and fitted or nil)
			m.average, m.worst = fittedAverage, fittedWorst
		end
	end

	return spacing
end
