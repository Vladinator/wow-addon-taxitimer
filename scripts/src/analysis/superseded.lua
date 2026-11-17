-- When the game changes how a route or a taxi map is flown, the flights from before the change no longer say how it is flown now.
-- The flights of the builds of the game are compared, and the older ones are left out where the newest ones differ, so the sim file follows the game as it is now.

local SECONDS = 3 -- seconds the flights of a route must differ between two builds of the game for the older ones to be left out
local MAP_FLIGHTS = 2 -- flights on the newest build a taxi map needs before its speed is compared to the older builds

---@param ctx AnalysisContext
---@return fun(list: FlightAnalysis[]): string[]
return function(ctx)
	local util = ctx.util
	local format = string.format

	-- the flights by what is compared (`group`) and the build of the game they were flown on
	---@param list FlightAnalysis[]
	---@param group fun(a: FlightAnalysis): string?
	---@return table<string, table<number, FlightAnalysis[]>> groups
	---@return string[] order
	local function byBuild(list, group)
		local groups, order = {}, {} ---@type table<string, table<number, FlightAnalysis[]>>, string[]
		for _, a in ipairs(list) do
			local build = tonumber(a.record.build)
			local key = not a.incomplete and build and group(a) or nil
			if key and build then
				if not groups[key] then
					groups[key] = {}
					order[#order + 1] = key
				end
				groups[key][build] = groups[key][build] or {}
				table.insert(groups[key][build], a)
			end
		end
		return groups, order
	end

	---@param flights FlightAnalysis[]
	---@param why string
	local function leaveOut(flights, why)
		for _, a in ipairs(flights) do
			a.incomplete = why
		end
	end

	-- the speed a taxi map is mostly flown at
	---@param flights FlightAnalysis[]
	---@return number? speed
	local function cruise(flights)
		local time = {} ---@type table<number, number>
		for _, a in ipairs(flights) do
			for j = 2, #a.track do
				local step = a.steps[j]
				if step.kind == "move" then
					local speed = a:roundSpeed(step.speed)
					time[speed] = (time[speed] or 0) + step.dt
				end
			end
		end
		local best, bestTime ---@type number?, number
		bestTime = 0
		for _, speed in ipairs(util.keys(time)) do
			if time[speed] > bestTime then
				best, bestTime = speed, time[speed]
			end
		end
		return best
	end

	-- how long a route takes
	---@param flights FlightAnalysis[]
	---@return number seconds
	local function seconds(flights)
		local values = {} ---@type number[]
		for i, a in ipairs(flights) do
			values[i] = a.actual - a.jumpTime
		end
		return util.median(values)
	end

	-- a taxi map that is mostly flown at another speed than before
	---@param list FlightAnalysis[]
	---@param notes string[]
	local function leaveOutMaps(list, notes)
		local maps, order = byBuild(list, function(a)
			return a.record.area and (a.data.client .. " taxi map " .. tostring(a.record.area)) or nil
		end)
		for _, key in ipairs(order) do
			local builds = util.keys(maps[key])
			local newest = builds[#builds]
			local now = #maps[key][newest] >= MAP_FLIGHTS and cruise(maps[key][newest]) or nil
			for i = 1, #builds - 1 do
				local before = cruise(maps[key][builds[i]])
				if now and before and before ~= now then
					local why = format("flown on build %d, the taxi map is flown at another speed since build %d", builds[i], newest)
					leaveOut(maps[key][builds[i]], why)
					notes[#notes + 1] = format("%s was mostly flown at %d on build %d and is flown at %d on build %d: the %d flight%s of build %d are left out", key, before, builds[i], now, newest, #maps[key][builds[i]], #maps[key][builds[i]] == 1 and "" or "s", builds[i])
				end
			end
		end
	end

	-- a route that takes longer or shorter than before
	---@param list FlightAnalysis[]
	---@param notes string[]
	local function leaveOutRoutes(list, notes)
		local routes, order = byBuild(list, function(a)
			local route = {} ---@type string[]
			for i, node in ipairs(a.record.route or {}) do
				route[i] = tostring(node)
			end
			return #route >= 2 and (a.data.client .. " " .. table.concat(route, ">")) or nil
		end)
		for _, key in ipairs(order) do
			local builds = util.keys(routes[key])
			local newest = builds[#builds]
			local now = seconds(routes[key][newest])
			for i = 1, #builds - 1 do
				local flights = routes[key][builds[i]]
				local before = seconds(flights)
				if math.abs(before - now) >= SECONDS then
					leaveOut(flights, format("flown on build %d, the route is flown another way since build %d", builds[i], newest))
					notes[#notes + 1] = format("%s took %.1f sec on build %d and takes %.1f sec on build %d: the %d flight%s of build %d %s left out (flight %d)", flights[1]:routeName(), before, builds[i], now, newest, #flights, #flights == 1 and "" or "s", builds[i], #flights == 1 and "is" or "are", flights[1].index)
				end
			end
		end
	end

	---@param list FlightAnalysis[]
	---@return string[] notes What was left out and why.
	return function(list)
		local notes = {} ---@type string[]
		leaveOutMaps(list, notes)
		leaveOutRoutes(list, notes)
		return notes
	end
end
