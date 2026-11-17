-- The summary of the flights: each flight with how far off the simulation is, what the flights on each taxi map came to, and the flights that are still off.

---What the flights on a taxi map came to.
---@class AnalysisArea
---@field count number
---@field error number The seconds the estimates were off by, added up.
---@field now number The seconds the simulation is off by with the sim file as it is now, added up.
---@field replayed number The flights the simulation has an estimate for now.
---@field used number The speed the estimates used.
---@field speeds table<number, number> The seconds flown at each speed.
---@field distance number[] How far off the estimated distance was for each flight, in percent.

---@class AnalysisWorst
---@field analysis FlightAnalysis
---@field error number
---@field estimate number

---@param ctx AnalysisContext
---@return fun(analyses: FlightAnalysis[], superseded: string[], source: string, worstSeconds: number)
return function(ctx)
	local util = ctx.util
	local printf = util.printf
	local format = string.format

	-- Lists every flight, and adds up what the flights of each taxi map came to and which flights are off by `worstSeconds` or more.
	---@param analyses FlightAnalysis[]
	---@param worstSeconds number
	---@return table<string, AnalysisArea> areas
	---@return string[] areaOrder
	---@return AnalysisWorst[] worst The flights the simulation is off by the most with the sim file as it is now.
	local function listFlights(analyses, worstSeconds)
		local worst = {} ---@type AnalysisWorst[]
		local areas = {} ---@type table<string, AnalysisArea>
		local areaOrder = {} ---@type string[]
		for _, a in ipairs(analyses) do
			local r = a.record
			local typical = a:typicalSpeed()
			local error = a:error()
			local replay = a:replay()
			local errorNow = a:errorNow()
			printf("%4d  %-8s %6s  %8.1f %8.1f %+8.1f %+6.1f%%  %8s %8s  %8.0f %8.0f  %6.2f %6s  %s%s\n", a.index, a.data.client, tostring(r.area or "?"), a.estimate, a.actual, error, a.estimate > 0 and error / a.estimate * 100 or 0, replay and format("%.1f", replay.duration) or "?", errorNow and format("%+.1f", errorNow) or "?", r.distance, a.travelled, r.areaSpeed or 0, typical == nil and "?" or format("%.2f", typical), a:routeName(), (a.hasOverride and " [override]" or "") .. (a.incomplete and (" [incomplete: " .. a.incomplete .. "]") or ""))
			if not a.incomplete then
				local key = a.data.client .. " taxi map " .. tostring(r.area or "?")
				local area = areas[key]
				if not area then
					area = { count = 0, error = 0, now = 0, replayed = 0, used = r.areaSpeed or 0, speeds = {}, distance = {} }
					areas[key] = area
					areaOrder[#areaOrder + 1] = key
				end
				area.count = area.count + 1
				area.error = area.error + math.abs(error)
				if errorNow then
					area.now = area.now + math.abs(errorNow)
					area.replayed = area.replayed + 1
					if math.abs(errorNow) >= worstSeconds then
						worst[#worst + 1] = { analysis = a, error = errorNow, estimate = replay and replay.duration or 0 }
					end
				end
				for j = 2, #a.track do
					local step = a.steps[j]
					if step.kind == "move" then
						local speed = util.round(step.speed, 2)
						area.speeds[speed] = (area.speeds[speed] or 0) + step.dt
					end
				end
				if not a.hasOverride and r.distance > 0 then
					area.distance[#area.distance + 1] = (a.travelled - r.distance) / r.distance * 100
				end
			end
		end
		return areas, areaOrder, worst
	end

	local function printLegend()
		print("\nerror is the seconds the flight took longer (+) or shorter (-) than estimated when it was flown")
		print("now is what the simulation estimates with the sim file as it is now, and off now the seconds the flight took longer (+) or shorter (-) than that (without the time spent loading another map)")
		print("speed is what the estimate used for the taxi map, flown is the speed most of the flight was flown at")
		print("incomplete flights did not reach the destination and are left out of the summaries below\n")
	end

	---@param superseded string[]
	local function printSuperseded(superseded)
		if #superseded > 0 then
			print("The game changed how these are flown, so the flights from before the change are left out as well (use --keep-old to keep them)")
			for _, note in ipairs(superseded) do
				print("  " .. note)
			end
			print()
		end
	end

	---@param areas table<string, AnalysisArea>
	---@param areaOrder string[]
	local function printAreas(areas, areaOrder)
		for _, key in ipairs(areaOrder) do
			local area = areas[key]
			local speed = util.weightedMedian(area.speeds)
			table.sort(area.distance)
			printf("%s: %d flights, off by %.1f sec on average when flown and %s now, the estimates used %.2f yd/sec and the flights were mostly flown at %s yd/sec", key, area.count, area.error / area.count, area.replayed > 0 and format("%.1f", area.now / area.replayed) or "?", area.used, speed == nil and "?" or format("%.2f", speed))
			if #area.distance > 0 then
				printf(", the flown distance was typically %+.1f%% off the estimate", area.distance[math.floor(#area.distance / 2) + 1])
			end
			print()
		end
	end

	-- the flights the simulation is still off by, and what makes them differ
	---@param worst AnalysisWorst[]
	---@param worstSeconds number
	local function printWorst(worst, worstSeconds)
		table.sort(worst, function(a, b)
			return math.abs(a.error) > math.abs(b.error)
		end)
		if #worst == 0 then
			printf("\nno flight is off by %s sec or more with the sim file as it is now\n", tostring(worstSeconds))
			return
		end
		printf("\n%d flight%s off by %s sec or more with the sim file as it is now, the worst first%s\n", #worst, #worst == 1 and " is" or "s are", tostring(worstSeconds), #worst > 20 and " (20 are shown)" or "")
		for i = 1, math.min(20, #worst) do
			local a = worst[i].analysis
			printf("  flight %d took %.1f sec %s than the %.1f sec the simulation gives: %s\n", a.index, math.abs(worst[i].error), worst[i].error > 0 and "longer" or "shorter", worst[i].estimate, a:routeName())
			for _, line in ipairs(a:whyOff(2)) do
				print("    " .. line)
			end
		end
	end

	return function(analyses, superseded, source, worstSeconds)
		printf("%d flights in %s\n\n", #analyses, source)
		printf("%4s  %-8s %6s  %8s %8s %8s %7s  %8s %8s  %8s %8s  %6s %6s  %s\n", "#", "client", "map", "estimate", "actual", "error", "error%", "now", "off now", "est yd", "flown yd", "speed", "flown", "route")
		local areas, areaOrder, worst = listFlights(analyses, worstSeconds)
		printLegend()
		printSuperseded(superseded)
		printAreas(areas, areaOrder)
		printWorst(worst, worstSeconds)
	end
end
