-- Checks that the simulation still estimates the recorded flights as well as it did.
-- The error of the simulation for every recorded flight is kept in `data/baseline.lua`, and a change to the simulation or the library that makes a flight worse than that is flagged.
-- The baseline is what was accepted as good, so a flight that is further off than it used to be is something to look into before it is accepted, and `--update-baseline` makes what there is now the baseline.
-- It also keeps where each flight was at the taxi nodes it passed without landing against when the simulation says it reaches them (what the bar of the addon shows), as the time of the whole flight can be right while the taxi nodes along the way are not.

local NEW_SECONDS = 5 -- seconds a flight that is not in the baseline can be off by before it is pointed out
local MAX_LISTED = 15 -- how many of the flights that got worse are listed
local CHECKPOINT_SECONDS = 2 -- seconds a taxi node along the way can get further from when the flight was there before it is pointed out (the samples of a flight are a second apart)

---@param ctx AnalysisContext
---@return fun(analyses: FlightAnalysis[], opts: AnalysisOptions): boolean
return function(ctx)
	local util, shim = ctx.util, ctx.shim
	local archive = dofile(ctx.dir .. "/src/analysis/archive.lua")(ctx) ---@type FlightArchive
	local printf, warn = util.printf, util.warn
	local format = string.format
	local abs = math.abs

	---A flight and how far off the simulation is for it.
	---@class CheckedFlight
	---@field key string
	---@field analysis FlightAnalysis
	---@field error number
	---@field checkpoints number[] For each taxi node passed without landing, the seconds the flight was there after the simulation gives and how many yards it was from the point of the simulation, one after the other.

	-- the flights that can be checked, with the seconds the simulation is off by for each
	---@param analyses FlightAnalysis[]
	---@return CheckedFlight[] flights
	local function currentErrors(analyses)
		local flights = {} ---@type CheckedFlight[]
		for _, a in ipairs(analyses) do
			local key = archive.flightKey(a.record)
			local seconds = key and not a.incomplete and a:errorNow() or nil
			if key and seconds then
				local checkpoints = {} ---@type number[]
				for _, fit in ipairs(a:checkpointFits()) do
					checkpoints[#checkpoints + 1] = tonumber(format("%.1f", fit.seconds)) or fit.seconds
					checkpoints[#checkpoints + 1] = tonumber(format("%.0f", fit.yards)) or fit.yards
				end
				flights[#flights + 1] = { key = key, analysis = a, error = tonumber(format("%.1f", seconds)) or seconds, checkpoints = checkpoints }
			end
		end
		return flights
	end

	---@param path string
	---@return table<string, number>? errors
	---@return table<string, number[]>? checkpoints `nil` if the baseline was made before they were kept.
	local function read(path)
		if not shim.readfile(path) then
			return nil
		end
		local globals, err = shim.savedvariables(path)
		local baseline = globals and globals.TaxiTimerBaseline ---@type table<string, number>?
		if type(baseline) ~= "table" then
			warn("unable to read the baseline %s%s", path, err and (": " .. tostring(err)) or "")
			return nil
		end
		local checkpoints = globals and globals.TaxiTimerBaselineCheckpoints ---@type table<string, number[]>?
		return baseline, type(checkpoints) == "table" and checkpoints or nil
	end

	---@param path string
	---@param flights CheckedFlight[]
	---@return boolean written
	local function write(path, flights)
		table.sort(flights, function(a, b)
			return a.key < b.key
		end)
		local out = { "-- The seconds the simulation was off by for each recorded flight when it was accepted as good (a flight that took longer than the simulation gives is positive).\n-- Written by scripts/analyze.lua --update-baseline, and what scripts/analyze.lua --check compares the simulation to.\n\nTaxiTimerBaseline = {\n" }
		for _, flight in ipairs(flights) do
			out[#out + 1] = format("\t[%q] = %.1f,\n", flight.key, flight.error)
		end
		out[#out + 1] = "}\n\n-- Where each flight was at the taxi nodes it passed without landing: the seconds after the simulation gives that it was closest to the point the simulation reaches the taxi node at, and the yards it was from that point, for each taxi node in the order of the route.\nTaxiTimerBaselineCheckpoints = {\n"
		for _, flight in ipairs(flights) do
			if #flight.checkpoints > 0 then
				local values = {} ---@type string[]
				for i, value in ipairs(flight.checkpoints) do
					values[i] = i % 2 == 1 and format("%.1f", value) or format("%.0f", value)
				end
				out[#out + 1] = format("\t[%q] = { %s },\n", flight.key, table.concat(values, ", "))
			end
		end
		out[#out + 1] = "}\n"
		local file = io.open(path, "wb")
		if not file then
			return false
		end
		file:write(table.concat(out))
		file:close()
		return true
	end

	---@param flight CheckedFlight
	---@return string
	local function describe(flight)
		local a = flight.analysis
		return format("flight %d, %s", a.index, a:routeName())
	end

	-- Compares the simulation to the baseline, or makes the baseline what the simulation does now.
	---@param analyses FlightAnalysis[]
	---@param opts AnalysisOptions
	---@return boolean ok
	return function(analyses, opts)
		local flights = currentErrors(analyses)
		if opts.updateBaseline then
			if not write(opts.baselinePath, flights) then
				warn("unable to write %s", opts.baselinePath)
				return false
			end
			printf("%d flights are the baseline of the simulation now, in %s\n", #flights, opts.baselinePath)
			return true
		end

		local baseline, baselineCheckpoints = read(opts.baselinePath)
		if not baseline then
			warn("there is no baseline to check against, make one with --update-baseline (%s)", opts.baselinePath)
			return false
		end

		local worse, new = {}, {} ---@type CheckedFlight[], CheckedFlight[]
		local compared, better, same, offBefore, offNow = 0, 0, 0, 0, 0
		local seen = {} ---@type table<string, boolean>
		for _, flight in ipairs(flights) do
			local was = baseline[flight.key]
			seen[flight.key] = true
			if not was then
				if abs(flight.error) >= NEW_SECONDS then
					new[#new + 1] = flight
				end
			else
				compared = compared + 1
				local change = abs(flight.error) - abs(was)
				offBefore = offBefore + (abs(was) >= opts.worstSeconds and 1 or 0)
				offNow = offNow + (abs(flight.error) >= opts.worstSeconds and 1 or 0)
				if change > opts.tolerance then
					worse[#worse + 1] = flight
				elseif change < -0.05 then
					better = better + 1
				else
					same = same + 1
				end
			end
		end
		local gone = 0
		for key in pairs(baseline) do
			if not seen[key] then
				gone = gone + 1
			end
		end

		table.sort(worse, function(a, b)
			return abs(a.error) - abs(baseline[a.key]) > abs(b.error) - abs(baseline[b.key])
		end)
		printf("%d flights compared to the baseline: %d better, %d the same, %d worse by more than %s sec\n", compared, better, same, #worse, tostring(opts.tolerance))
		printf("flights %s sec or more off: %d in the baseline, %d now\n", tostring(opts.worstSeconds), offBefore, offNow)
		if gone > 0 then
			printf("%d flights of the baseline are not checked now (they are left out as the game flies them another way, or they are not there)\n", gone)
		end
		for i = 1, math.min(MAX_LISTED, #worse) do
			local flight = worse[i]
			printf("  worse: %s: %+.1f sec now, was %+.1f\n", describe(flight), flight.error, baseline[flight.key])
		end
		if #worse > MAX_LISTED then
			printf("  and %d more\n", #worse - MAX_LISTED)
		end
		for _, flight in ipairs(new) do
			printf("  new flight that is off: %s: %+.1f sec\n", describe(flight), flight.error)
		end

		-- the taxi nodes along the way
		local worseNodes = {} ---@type string[]
		local nodesCompared, nodesBetter = 0, 0
		if baselineCheckpoints then
			for _, flight in ipairs(flights) do
				local was = baselineCheckpoints[flight.key]
				local now = flight.checkpoints
				if was and #was == #now then
					local near = flight.analysis.far
					for i = 1, #was, 2 do
						nodesCompared = nodesCompared + 1
						-- the flight was near the point of the simulation and is not now, or it was and is further from when the simulation says
						local lost = was[i + 1] <= near and now[i + 1] > near
						local later = was[i + 1] <= near and now[i + 1] <= near and abs(now[i]) - abs(was[i]) > CHECKPOINT_SECONDS
						if lost or later then
							worseNodes[#worseNodes + 1] = format("flight %d, %s, taxi node %d of the route: %s", flight.analysis.index, flight.analysis:routeName(), (i + 1) / 2 + 1, lost and format("%.0f yd from where the simulation puts it now, was %.0f", now[i + 1], was[i + 1]) or format("%+.1f sec from it now, was %+.1f", now[i], was[i]))
						elseif abs(now[i]) - abs(was[i]) < -0.05 or now[i + 1] < was[i + 1] - 1 then
							nodesBetter = nodesBetter + 1
						end
					end
				end
			end
			printf("%d taxi nodes along the way compared to the baseline: %d better, %d worse by more than %s sec\n", nodesCompared, nodesBetter, #worseNodes, tostring(CHECKPOINT_SECONDS))
			for i = 1, math.min(MAX_LISTED, #worseNodes) do
				printf("  worse: %s\n", worseNodes[i])
			end
			if #worseNodes > MAX_LISTED then
				printf("  and %d more\n", #worseNodes - MAX_LISTED)
			end
		else
			print("the baseline has no taxi nodes along the way yet, --update-baseline keeps them")
		end

		local ok = #worse == 0 and offNow <= offBefore and #worseNodes == 0
		print(ok and "\nthe simulation is as good as the baseline" or "\nthe simulation is worse than the baseline, look into why before accepting it (--update-baseline makes it the baseline)")
		return ok
	end
end
