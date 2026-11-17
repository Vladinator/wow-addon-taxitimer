-- How the flights of a taxi map sped up after taking off and slowed down before landing, and the `AREA_RAMPS` for it.

local RAMP_MIN_SECONDS = 0.25 -- seconds the flights must get closer to their estimates on average before other speeds for taking off and landing are suggested

---@param ctx AnalysisContext
---@param common table
---@return table
return function(ctx, common)
	local util = ctx.util
	local format, concat = string.format, table.concat
	local max = math.max
	local override, modelError, spreadSpeeds = common.override, common.modelError, common.spreadSpeeds

	local ramps = {}

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

	-- the speeds one flight flew a path of from the points first to last, taking off at the start of the flight or landing at the end of it
	---@param m SuggestMap
	---@param a FlightAnalysis
	---@param paths table<number, PathObservation>
	---@param takeoffs AnalysisGroups
	---@param landings AnalysisGroups
	local function observeRamps(m, a, paths, takeoffs, landings)
		local cruise = m.cruise
		local route = a.record.route or {}
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
			if not (m.sim.paths[path] or fastest > cruise) and reachesCruise then
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

	-- the flights the speeds are tried on, and how the flights took off and landed
	---@param m SuggestMap
	---@return SuggestFlight[] tried
	---@return AnalysisGroups takeoffs
	---@return AnalysisGroups landings
	function ramps.observe(m)
		local takeoffs, landings = util.newGroups(), util.newGroups()
		local tried = {}
		for _, a in ipairs(m.flights) do
			local paths, intervals = a:observe()
			local geometry = a:geometry()
			if geometry and #intervals > 0 then
				tried[#tried + 1] = { index = a.index, analysis = a, geometry = geometry, intervals = intervals, seconds = a.actual - a.jumpTime }
			end
			observeRamps(m, a, paths, takeoffs, landings)
		end
		return tried, takeoffs, landings
	end

	---@param m SuggestMap
	---@param takeoffs AnalysisGroups
	---@param landings AnalysisGroups
	function ramps.suggest(m, takeoffs, landings)
		local lib, map, sim, out = m.lib, m.map, m.sim, m.out
		local ramp = sim.ramps[map] or { takeoff = {}, landing = {} }
		-- taxi maps with speeds by the length of the stretches leave what is flown slower to those, their ramp is only what is the same on every flight
		if sim.spacing[map] and #sim.spacing[map] > 0 then
			return
		end
		local takeoff = mostSeen(takeoffs, concat(ramp.takeoff, ", "))
		local landing = mostSeen(landings, concat(ramp.landing, ", "))
		if not (takeoff and landing and (takeoff ~= concat(ramp.takeoff, ", ") or landing ~= concat(ramp.landing, ", "))) then
			return
		end
		-- what most flights did is not always what brings the estimates closest, so a taxi map that already has speeds for taking off and landing only gets others if they do
		local better = true
		local candidate = { takeoff = parseSpeeds(takeoff), landing = parseSpeeds(landing) }
		if sim.ramps[map] then
			local currentError = modelError(lib, map, m.tried)
			local restore = override(lib.Sim, "AREA_RAMPS", map, candidate)
			local candidateError = modelError(lib, map, m.tried)
			restore()
			better = candidateError < currentError - RAMP_MIN_SECONDS
		end
		if not better then
			return
		end
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
		m.restores[#m.restores + 1] = override(lib.Sim, "AREA_RAMPS", map, candidate)
	end

	return ramps
end
