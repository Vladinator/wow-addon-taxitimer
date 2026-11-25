-- The paths that are off by more than a few seconds with the speeds of their taxi map, which need speeds of their own as `PATH_SPEEDS`.
-- What a flight flew of a path where it took off or landed is the speeds of taking off and landing of the path (`PATH_RAMPS`), the game does not slow down like that at a taxi node it passes, so they are not speeds of the path itself.

local PATH_MIN_NET_SECONDS = 1 -- seconds all of the flights on a taxi map must get closer to how long they took for a speed of a path to be suggested
local PATH_MIN_SEEN = 0.6 -- how much of a path must have been seen in flight for it to be given speeds of its own
local PATH_CONFIRMED_SECONDS = 2 -- the same, for a path that two or more flights agree on (all of them flew it at the same speeds, and each is this far off the same way)
local AGREE_RAMP_POINTS = 3 -- points at each end of a path where two flights are allowed to have flown a speed that is a step apart (taking off and landing)
local AGREE_RAMP_SPEED = 10 -- the most they can be apart, in speed, at those points
local RAMP_MIN_SECONDS = 2 -- the same for the speeds of taking off and landing of a path, which are the same every time
local RAMP_CONFIRMED_SECONDS = 1.5 -- and when two or more flights flew the path
local TRANSIT_SKIP_POINTS = 3 -- points next to a taxi node that flights only pass through that a flight does not fly, as it is past the node before it has the points of the path
local PATH_CHECKPOINTS_WORSE = 2 -- seconds the taxi nodes along the way can get further from where the flights were, in all, for the speeds of a path to be suggested
local SINGLE_HOP_WORSE = 0.5 -- seconds a flight of only that path can get worse for the speeds of the path to be suggested, as such a flight is the clearest there is of how the path is flown
local RAMP_MAX_POINTS = 6 -- points at one end of a path that can be taking off or landing, a longer stretch that is flown slower is a slow part of the path

---What the suggestions for paths came to, over all of the taxi maps of a game.
---@class SuggestPaths
---@field lines table<number, string> The line each path was suggested.
---@field notes table<number, string> What there is to say about a path that is not suggested.
---@field order number[] The paths in the order they were suggested.
---@field new table<number, table<number, number>|false> What each suggested line sets for the path (`false` to remove it), to see what it does to all of the flights on the path.
---@field support table<number, number> How many flights of the taxi map that is looked at flew each path, as much of it as it takes to tell anything.
---@field rampLines table<number, string> The line each path was suggested speeds of taking off and landing.
---@field newRamps table<number, TaxiTimerLib-1.0_PathRamp|false> What each suggested line of ramps sets for the path (`false` to remove it).
---@field small number How many paths were a little off, and are left alone.

---The stretches of a path that one flight flew, with the seconds the speeds of the taxi map give them.
---@alias SuggestStretches { interval: FlownStretch, step: table? }[]

---@param ctx AnalysisContext
---@param common table
---@return table
return function(ctx, common)
	local util = ctx.util
	local printf = util.printf
	local format, concat = string.format, table.concat
	local abs, max, min = math.abs, math.max, math.min
	local override, secondsOff, spreadSpeeds, sameSpread = common.override, common.secondsOff, common.spreadSpeeds, common.sameSpread
	local PATH_MIN_SECONDS = common.PATH_MIN_SECONDS

	local paths = {}

	---@return SuggestPaths
	function paths.new()
		return { lines = {}, notes = {}, order = {}, new = {}, rampLines = {}, newRamps = {}, support = {}, small = 0 }
	end

	-- If two flights flew a path at the same speeds, going by the points both of them have a speed for.
	---@param a table<number, number>
	---@param b table<number, number>
	---@param skipA? number
	---@param skipB? number
	---@return boolean
	local function agreeSpread(a, b, skipA, skipB)
		local points = {}
		for point in pairs(a) do
			-- the last point of a flight that ended before the path did only has the speed it was going at, not one the path sets
			if b[point] ~= nil and point ~= skipA and point ~= skipB then
				points[#points + 1] = point
			end
		end
		table.sort(points)
		for i, point in ipairs(points) do
			-- the speed of taking off and landing is set by the time, so the point the game was at when it changed differs a point between flights, there it can be one step off
			local atEnds = i <= AGREE_RAMP_POINTS or i > #points - AGREE_RAMP_POINTS
			if abs(a[point] - b[point]) > (atEnds and AGREE_RAMP_SPEED or 0) then
				return false
			end
		end
		return #points > 0
	end

	-- the stretches of each path in a flight, and the seconds the speeds of the taxi map give them
	---@param intervals FlownStretch[]
	---@param without TaxiTimerLib-1.0_FlightInfo
	---@return table<number, SuggestStretches>
	local function stretchesByPath(intervals, without)
		local byPath = {}
		for i, interval in ipairs(intervals) do
			local list = byPath[interval.path]
			if not list then
				list = {}
				byPath[interval.path] = list
			end
			list[#list + 1] = { interval = interval, step = without.steps[i] }
		end
		return byPath
	end

	-- the seconds the stretches of a path were flown in and the seconds the speeds of the taxi map give them, and the yards that were seen
	-- the stretches we did not see (where the flight changed map, or was too far away to be sure) are left out, what is seen is scaled up to the whole path
	---@param stretches SuggestStretches
	---@param scale number
	---@return number observed
	---@return number predicted
	---@return number seenYards
	---@return number totalYards
	local function totals(stretches, scale)
		local observed, predicted, seenYards, totalYards = 0, 0, 0, 0
		for _, stretch in ipairs(stretches) do
			totalYards = totalYards + stretch.interval.yards
			if stretch.interval.speed then
				seenYards = seenYards + stretch.interval.yards
				observed = observed + stretch.interval.yards / (stretch.interval.speed * scale)
				predicted = predicted + (stretch.step and stretch.step.distance / stretch.step.speed or 0)
			end
		end
		return observed, predicted, seenYards, totalYards
	end

	-- a few seconds off on one flight can be anything, but when two or more flights flew a path at the same speeds and each is off the same way it is the path
	---@param m SuggestMap
	---@return table<number, boolean> confirmed
	---@return table<number, boolean> onMap The paths the flights of this taxi map flew.
	---@return table<number, number> counts How many of the flights saw each path (all of it that it takes to tell how it is flown).
	local function confirmPaths(m)
		local lib = m.lib
		local confirmed = {} ---@type table<number, boolean>
		local onMap = {} ---@type table<number, boolean>
		local counts = {} ---@type table<number, number>
		local seenOn = {} ---@type table<number, { gain: number, spread: table<number, number>, skip: number? }[]>
		for _, flight in ipairs(m.tried) do
			local without = lib.GetFlightInfoFromGeometry(flight.geometry, m.map, flight.analysis.record.speedModifier)
			if without then
				local byPath = stretchesByPath(flight.intervals, without)
				for path, flown in pairs(flight.analysis:observe()) do
					local stretches = byPath[path]
					if stretches then
						onMap[path] = true
						local observed, predicted, seenYards, totalYards = totals(stretches, m.scale)
						if totalYards == 0 or seenYards >= totalYards * PATH_MIN_SEEN then
							seenOn[path] = seenOn[path] or {}
							table.insert(seenOn[path], {
								gain = (predicted - observed) * (seenYards > 0 and totalYards / seenYards or 1),
								spread = spreadSpeeds(flown.speeds, flown.first, flown.last),
								skip = flown.last < #flight.analysis.data.pathPoints[path] - 1 and flown.last or nil,
							})
						end
					end
				end
			end
		end
		for path, list in pairs(seenOn) do
			counts[path] = #list
			local agree = #list >= 2
			for i = 1, #list do
				if abs(list[i].gain) < PATH_CONFIRMED_SECONDS or (list[i].gain > 0) ~= (list[1].gain > 0) or not agreeSpread(list[1].spread, list[i].spread, list[1].skip, list[i].skip) then
					agree = false
				end
			end
			confirmed[path] = agree
		end
		return confirmed, onMap, counts
	end

	-- the order the paths were flown in with the speed each was entered and left at: a speed carries on into the next path, so a path that starts at the speed the one before it ended at does not set it
	---@param intervals FlownStretch[]
	---@return { path: number, entry: number?, exit: number? }[] runs
	---@return table<number, number> runOf The first run of each path.
	local function runsOf(intervals)
		local runs, runOf = {}, {}
		for _, interval in ipairs(intervals) do
			local run = runs[#runs]
			if not run or run.path ~= interval.path then
				run = { path = interval.path }
				runs[#runs + 1] = run
				runOf[interval.path] = runOf[interval.path] or #runs
			end
			if interval.speed then
				run.entry = run.entry or interval.speed
				run.exit = interval.speed
			end
		end
		return runs, runOf
	end

	-- the paths are in the order something was first suggested for them
	---@param state SuggestPaths
	---@param path number
	local function addToOrder(state, path)
		for _, known in ipairs(state.order) do
			if known == path then
				return
			end
		end
		state.order[#state.order + 1] = path
	end

	-- the line for a path, which replaces the one an earlier flight gave it
	---@param state SuggestPaths
	---@param path number
	---@param speeds table<number, number>|false What the line sets, `false` if it removes the speeds.
	---@param line string
	local function setLine(state, path, speeds, line)
		addToOrder(state, path)
		state.new[path] = speeds
		state.lines[path] = line
	end

	-- the line of ramps for a path, which replaces the one an earlier flight gave it
	---@param state SuggestPaths
	---@param path number
	---@param ramp TaxiTimerLib-1.0_PathRamp|false What the line sets, `false` if it removes the ramps.
	---@param line string
	local function setRampLine(state, path, ramp, line)
		addToOrder(state, path)
		state.newRamps[path] = ramp
		state.rampLines[path] = line
	end

	-- if two lists of speeds are the same
	---@param a number[]
	---@param b number[]
	---@return boolean
	local function sameList(a, b)
		if #a ~= #b then
			return false
		end
		for i = 1, #a do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end

	-- the speeds of the points as the points where the speed changed, from the speed of the taxi map
	---@param spread table<number, number>
	---@param first number
	---@param last number
	---@param cruise number
	---@return table<number, number> set
	local function collapseSpeeds(spread, first, last, cruise)
		local set, current = {}, cruise
		for point = first, last do
			local speed = spread[point]
			if speed and speed ~= current then
				set[point] = speed
				current = speed
			end
		end
		return set
	end

	---What a flight flew of a path split into taking off, landing and the path itself.
	---@class SuggestSplit
	---@field takeoff number[] The speeds of the first points, until the speed of the taxi map is reached.
	---@field landing number[] The speeds of the last points, back to where the speed of the taxi map was last flown.
	---@field takeoffDone boolean If the speed of the taxi map was reached, so the takeoff is all there is of it.
	---@field landingDone boolean If the speed of the taxi map was flown before the landing.
	---@field first number The first point that is not taking off.
	---@field last number The last point that is not landing.
	---@field set table<number, number> The speeds the path itself sets, by the point they are set at.

	-- Splits what a flight flew of a path. Taking off is the points from where the flight began until it was flown at the speed of the taxi map, and landing is the same at the end, but only where the flight took off or landed on the path.
	---@param spread table<number, number> The speed flown from each of the points.
	---@param first number The first point that was flown.
	---@param last number The last point that was flown.
	---@param count number How many points the path has.
	---@param cruise number
	---@param takesOff boolean If the flight began on the path.
	---@param lands boolean If the flight ended on the path.
	---@return SuggestSplit
	local function splitRamps(spread, first, last, count, cruise, takesOff, lands)
		local split = { takeoff = {}, landing = {}, takeoffDone = false, landingDone = false, first = first, last = last, set = {} } ---@type SuggestSplit
		if takesOff then
			for point = first, last do
				local speed = spread[point]
				if not speed then
					break
				elseif speed >= cruise then
					split.takeoffDone = true
					break
				end
				split.takeoff[#split.takeoff + 1] = speed
				split.first = point + 1
			end
		end
		if not split.takeoffDone or #split.takeoff > RAMP_MAX_POINTS then
			split.takeoff, split.first, split.takeoffDone = {}, first, false
		end
		if lands then
			-- the last point sets no speed as the flight ends there
			for point = min(last, count - 1), split.first, -1 do
				local speed = spread[point]
				if not speed then
					break
				elseif speed >= cruise then
					split.landingDone = true
					break
				end
				table.insert(split.landing, 1, speed)
				split.last = point - 1
			end
		end
		if not split.landingDone or #split.landing > RAMP_MAX_POINTS then
			split.landing, split.last, split.landingDone = {}, last, false
		end
		split.set = collapseSpeeds(spread, split.first, split.last, cruise)
		return split
	end

	-- how many different speeds there are in the speeds that were flown from each point
	---@param spread table<number, number>
	---@return table<number, boolean> distinct
	---@return number count
	local function distinctSpeeds(spread)
		local distinct, count = {}, 0
		for _, speed in pairs(spread) do
			if not distinct[speed] then
				distinct[speed] = true
				count = count + 1
			end
		end
		return distinct, count
	end

	---What one flight shows of a path.
	---@class SuggestPathFlight
	---@field a FlightAnalysis
	---@field path number
	---@field flown PathObservation
	---@field count number How many points the path has.
	---@field name string
	---@field whole boolean If the flight went all the way along the path.
	---@field inherited boolean If the speed it was entered at is the one the path before it left at.
	---@field had? table<number, number> The speeds the sim file gives the path where it was flown.
	---@field text string What it is compared to the speeds of the taxi map.
	---@field takesOff boolean If the flight began on the path.
	---@field lands boolean If the flight ended on the path.
	---@field split? SuggestSplit What the flight flew of the path as taking off, landing and the speeds of the path itself, if it took off or landed on it.
	---@field ramp? TaxiTimerLib-1.0_PathRamp The speeds of taking off and landing the sim file gives the path.

	-- the line of the speeds of taking off and landing that a flight flew on a path, with what other flights gave it
	---@param state SuggestPaths
	---@param f SuggestPathFlight
	---@param split SuggestSplit
	---@param text string
	local function suggestRamps(state, f, split, text)
		local path = f.path
		local ramp = state.newRamps[path]
		if not ramp then
			ramp = { takeoff = f.ramp and f.ramp.takeoff, landing = f.ramp and f.ramp.landing }
		end
		---@cast ramp TaxiTimerLib-1.0_PathRamp
		local merged = { takeoff = ramp.takeoff, landing = ramp.landing } ---@type TaxiTimerLib-1.0_PathRamp
		if f.takesOff and split.takeoffDone then
			merged.takeoff = #split.takeoff > 0 and split.takeoff or nil
		end
		if f.lands and split.landingDone then
			merged.landing = #split.landing > 0 and split.landing or nil
		end
		if not state.rampLines[path] and sameList(merged.takeoff or {}, f.ramp and f.ramp.takeoff or {}) and sameList(merged.landing or {}, f.ramp and f.ramp.landing or {}) then
			return -- the sim file has them
		end
		local parts = {}
		if merged.takeoff then
			parts[#parts + 1] = format("takeoff = { %s }", concat(merged.takeoff, ", "))
		end
		if merged.landing then
			parts[#parts + 1] = format("landing = { %s }", concat(merged.landing, ", "))
		end
		local thin = common.thinNote(state.support[path] or 0)
		if #parts > 0 then
			setRampLine(state, path, merged, format("    %s PATH_RAMPS:    [%d] = { %s }, -- %s (flight %d, %s%s)", f.ramp and "change in" or "add to", path, concat(parts, ", "), f.name, f.a.index, text, thin))
		elseif f.ramp then
			setRampLine(state, path, false, format("    remove from PATH_RAMPS:    [%d] = ... -- %s (flight %d, it was not flown at other speeds when taking off and landing%s)", path, f.name, f.a.index, thin))
		end
	end

	-- the line that sets the speeds a flight flew a path at
	---@param m SuggestMap
	---@param state SuggestPaths
	---@param f SuggestPathFlight
	---@param confirmed table<number, boolean>
	---@param uniform boolean
	---@param distinct table<number, boolean>
	local function suggestSpeeds(m, state, f, confirmed, uniform, distinct)
		local a, path, flown, count, text = f.a, f.path, f.flown, f.count, f.text
		local parts = {}
		local newSpeeds = {} ---@type table<number, number>
		if uniform then
			if not f.inherited then
				parts[1] = format("[1] = %d", next(distinct))
				newSpeeds[1] = next(distinct)
			end
			text = text .. format(", points %d to %d of %d were flown, all at one speed", flown.first, flown.last, count)
		else
			-- what is flown as taking off and landing is not a speed of the path, it is only flown where the flight begins and ends
			local split = f.split
			local ramps = split ~= nil and (#split.takeoff > 0 or #split.landing > 0 or f.ramp ~= nil)
			local speeds = ramps and split and split.set or flown.speeds
			for _, point in ipairs(util.keys(speeds)) do
				-- the speed it was entered at is the one the path before it left at, so it is not the path that sets it
				if point ~= count and not (f.inherited and point == flown.first) then
					parts[#parts + 1] = format("[%d] = %d", point, speeds[point])
					newSpeeds[point] = speeds[point]
				end
			end
			if ramps and split then
				suggestRamps(state, f, split, text)
			end
			if not f.whole then
				text = text .. format(", points %d to %d of %d were flown", flown.first, flown.last, count)
			end
		end
		if #parts == 0 then
			-- nothing is set by this path, a speed it was given in the sim file is carried on from the path before it, or is the speed of taking off and landing
			if f.had and m.sim.paths[path] then
				setLine(state, path, false, format("    remove from PATH_SPEEDS:    [%d] = ... -- %s (flight %d, %s%s)", path, f.name, a.index, state.rampLines[path] and "the speeds are those of taking off and landing" or "the speed is carried on from the path before it", common.thinNote(state.support[path] or 0)))
			end
			return
		end
		local unsure = {}
		-- the point a speed changed at is not sure on one flight, but when two or more flights agree on the speeds of the path it is the one they show
		if not confirmed[path] then
			for i, point in ipairs(flown.unsure) do
				unsure[i] = tostring(point)
			end
		end
		setLine(state, path, newSpeeds, format("    %s PATH_SPEEDS:    [%d] = { %s }, -- %s (flight %d, %s%s%s)", f.had and "change in" or "add to", path, concat(parts, ", "), f.name, a.index, text, #unsure > 0 and (", not sure about point " .. concat(unsure, ", ")) or "", common.thinNote(state.support[path] or 0)))
	end

	-- if the sim file already gives a path what a flight flew of it as taking off, landing and the speeds of the path itself
	---@param m SuggestMap
	---@param path number
	---@param split SuggestSplit
	---@param takesOff boolean
	---@param lands boolean
	---@param baseline number
	---@return boolean
	local function sameRamps(m, path, split, takesOff, lands, baseline)
		local ramp = m.sim.pathRamps[path]
		if takesOff and split.takeoffDone and not sameList(ramp and ramp.takeoff or {}, split.takeoff) then
			return false
		end
		if lands and split.landingDone and not sameList(ramp and ramp.landing or {}, split.landing) then
			return false
		end
		local speeds = m.sim.paths[path]
		local had = speeds and collapseSpeeds(spreadSpeeds(speeds, split.first, split.last, baseline), split.first, split.last, baseline) or {}
		return sameSpread(had, split.set)
	end

	-- what a path flown by one flight needs: speeds of its own, or to lose the ones it has
	---@param m SuggestMap
	---@param state SuggestPaths
	---@param a FlightAnalysis
	---@param path number
	---@param flown PathObservation
	---@param stretches SuggestStretches
	---@param runs { path: number, entry: number?, exit: number? }[]
	---@param runOf table<number, number>
	---@param confirmed table<number, boolean>
	---@param baseline number The speed the taxi map is flown at in the estimate of the flight.
	local function suggestPath(m, state, a, path, flown, stretches, runs, runOf, confirmed, baseline)
		local lib = m.lib
		local observed, predicted, seenYards, totalYards = totals(stretches, m.scale)
		local seen = totalYards == 0 or seenYards >= totalYards * PATH_MIN_SEEN
		if not seen then
			if abs(predicted - observed) * totalYards / max(seenYards, 1) >= PATH_MIN_SECONDS and not state.lines[path] and not state.notes[path] then
				state.notes[path] = format("    path %d (%s) looks %.0f sec %s than the speeds of the taxi map give, but only %.0f%% of it was seen in flight %d. Fly it again to see all of it", path, a.data.pathName(path) or "?", abs(predicted - observed) * totalYards / max(seenYards, 1), predicted > observed and "shorter" or "longer", seenYards / totalYards * 100, a.index)
			end
			return
		end
		local gain = (predicted - observed) * (seenYards > 0 and totalYards / seenYards or 1)
		local count = #a.data.pathPoints[path]
		-- the last point of a path sets no speed as the flight does not go on from it, so a path flown up to the point before it was flown all the way
		-- a path that starts or ends at a taxi node that flights only pass through can not be flown from or to it, so what a flight across it flew of it is all of it that there is to see
		local pathEnds = a.data.pathEnds[path]
		local startsAtTransit = pathEnds ~= nil and m.transit[pathEnds.from] ~= nil
		local endsAtTransit = pathEnds ~= nil and m.transit[pathEnds.to] ~= nil
		local whole = (flown.first == 1 or (startsAtTransit and flown.first <= TRANSIT_SKIP_POINTS + 1))
			and (flown.last >= count - 1 or (endsAtTransit and flown.last >= count - 1 - TRANSIT_SKIP_POINTS))
		local name = a.data.pathName(path) or "?"
		local runIndex = runOf[path] or 1
		local run, before = runs[runIndex] or {}, runs[runIndex - 1]
		local carries = lib.Sim.AREA_CARRY[m.map]
		local inherited = carries and before ~= nil and before.exit ~= nil and run.entry == before.exit
		-- the points we did not see at the ends of the path were skipped by the game as the flight passed a taxi node, and are not the start or the end of the flight
		local nearlyWhole = carries and not (flown.first == 1 and flown.last == count)
			and (flown.first == 1 or (runIndex > 1 and flown.first <= 4))
			and (flown.last >= count - 1 or (runIndex < #runs and flown.last >= count - 4))
		local had = m.sim.paths[path] and spreadSpeeds(m.sim.paths[path], flown.first, flown.last, inherited and run.entry or nil) or nil
		local spread = spreadSpeeds(flown.speeds, flown.first, flown.last)
		if had then
			had[count] = nil -- the last point sets no speed as the flight ends there
		end
		spread[count] = nil
		-- the speeds of taking off and landing are of where the flight began and ended, a flight that passes the path does not slow down on it
		local takesOff = runIndex == 1 and flown.first == 1
		local lands = runs[#runs] ~= nil and runs[#runs].path == path and flown.last >= count - 1
		local ramp = m.sim.pathRamps[path]
		local split ---@type SuggestSplit?
		if (takesOff or lands) and (whole or nearlyWhole) then
			split = splitRamps(spread, flown.first, flown.last, count, baseline, takesOff, lands)
		end
		local rampsMatter = split ~= nil and (#split.takeoff > 0 or #split.landing > 0 or ramp ~= nil)
		local text = format("%.0f sec %s than the speeds of the taxi map give", abs(gain), gain > 0 and "shorter" or "longer")
		-- a path that is flown at one speed all the way does not need every point of it to be seen, the points next to a taxi node we passed are skipped by the game
		local distinct, numDistinct = distinctSpeeds(spread)
		local uniform = not whole and numDistinct == 1 and (flown.last - flown.first + 1) >= count * PATH_MIN_SEEN
		-- taking off and landing is the same every time, so a few seconds of it are enough
		local ramped = split ~= nil and (#split.takeoff > 0 or #split.landing > 0)
		local least = ramped and ((state.support[path] or 0) >= 2 and RAMP_CONFIRMED_SECONDS or RAMP_MIN_SECONDS) or (confirmed[path] and PATH_CONFIRMED_SECONDS or PATH_MIN_SECONDS)
		if abs(gain) < least then
			if had and whole then
				setLine(state, path, false, format("    remove from PATH_SPEEDS:    [%d] = ... -- %s (flight %d, only %s%s)", path, name, a.index, text, common.thinNote(state.support[path] or 0)))
			elseif not had and flown.time > 0 and abs(gain) >= 1 then
				state.small = state.small + 1
			end
		elseif not (rampsMatter and split and sameRamps(m, path, split, takesOff, lands, baseline) or not rampsMatter and sameSpread(had, spread)) then
			if whole or nearlyWhole or uniform then
				---@type SuggestPathFlight
				local f = { a = a, path = path, flown = flown, count = count, name = name, whole = whole, inherited = inherited, had = had, text = text, takesOff = takesOff, lands = lands, split = rampsMatter and split or nil, ramp = ramp }
				suggestSpeeds(m, state, f, confirmed, uniform, distinct)
			elseif not state.lines[path] then
				state.notes[path] = format("    path %d (%s) is %s%s, but flight %d only flew points %d to %d of %d. %s", path, name, text, had and " and differs from the sim file" or "", a.index, flown.first, flown.last, count,
					(startsAtTransit or endsAtTransit) and "It starts or ends at a taxi node that flights only pass through, so only a flight across it can tell" or "Fly it on its own (not passing through its ends) to get all of it")
			end
		end
	end

	---@param m SuggestMap
	---@param state SuggestPaths
	---@param flight SuggestFlight
	---@param confirmed table<number, boolean>
	local function suggestFlight(m, state, flight, confirmed)
		local a = flight.analysis
		local without = m.lib.GetFlightInfoFromGeometry(flight.geometry, m.map, a.record.speedModifier)
		local flown = a:observe()
		if not without then
			return
		end
		local byPath = stretchesByPath(flight.intervals, without)
		local runs, runOf = runsOf(flight.intervals)
		local baseline = a:roundSpeed(without.areaSpeed)
		for _, path in ipairs(util.keys(flown)) do
			local stretches = byPath[path]
			if stretches then
				suggestPath(m, state, a, path, flown[path], stretches, runs, runOf, confirmed, baseline)
			end
		end
	end

	-- a path is flown by more than the flight it was seen on, so what a line sets must make all of the flights on the path closer to how long they took, or the flights disagree
	---@param m SuggestMap
	---@param state SuggestPaths
	---@param onMap table<number, boolean>
	local function keepTheOnesThatHelp(m, state, onMap)
		local lib = m.lib
		for _, path in ipairs(state.order) do
			local new, newRamp = state.new[path], state.newRamps[path]
			-- only the flights of this taxi map say if a path they flew is better with it, the lines of the paths of other taxi maps are for those to judge
			if (new ~= nil or newRamp ~= nil) and (state.lines[path] or state.rampLines[path]) and onMap[path] then
				local before = secondsOff(lib, m.map, m.tried)
				local beforeFlights = common.flightErrors(lib, m.map, m.tried)
				-- the taxi nodes along the way are shown where the speeds put them, so a change that makes the total right must not move them away from where the flights were
				local beforeCheckpoints, beforeReached = common.checkpointsOff(lib, m.map, m.tried)
				local restores = {} ---@type (fun())[]
				if new ~= nil then
					restores[#restores + 1] = override(lib.Sim, "PATH_SPEEDS", path, new or nil)
				end
				if newRamp ~= nil then
					restores[#restores + 1] = override(lib.Sim, "PATH_RAMPS", path, newRamp or nil)
				end
				local after = secondsOff(lib, m.map, m.tried)
				local afterFlights = common.flightErrors(lib, m.map, m.tried)
				local afterCheckpoints, afterReached = common.checkpointsOff(lib, m.map, m.tried)
				for i = #restores, 1, -1 do
					restores[i]()
				end
				-- a flight of just this path must not get worse for what a longer flight shows of it
				local worsened ---@type number?
				for i, flight in ipairs(m.tried) do
					local points = flight.geometry.points
					if #(flight.analysis.record.route or {}) == 2 and points[1] and points[1].pathId == path and afterFlights[i] - beforeFlights[i] > SINGLE_HOP_WORSE then
						worsened = flight.index
					end
				end
				if afterReached < beforeReached or afterCheckpoints - beforeCheckpoints > PATH_CHECKPOINTS_WORSE then
					state.notes[path] = format("    path %d (%s) would make the taxi nodes along the way further from where the flights were (%.1f sec off now, %.1f with it, %d to %d of them reached), so it is left alone", path, (m.tried[1] and m.tried[1].analysis.data.pathName(path)) or "?", beforeCheckpoints, afterCheckpoints, beforeReached, afterReached)
					state.lines[path], state.rampLines[path] = nil, nil
				elseif worsened then
					state.notes[path] = format("    path %d (%s) would make flight %d, which only flew that path, more than %s sec worse, so it is left alone", path, (m.tried[1] and m.tried[1].analysis.data.pathName(path)) or "?", worsened, tostring(SINGLE_HOP_WORSE))
					state.lines[path], state.rampLines[path] = nil, nil
				elseif before - after < PATH_MIN_NET_SECONDS then
					-- a line of speeds of taking off and landing that changes nothing for the flights is only a different way of saying what the sim file has
					if newRamp == nil or after > before + 0.05 then
						state.notes[path] = format("    path %d (%s) would not make the flights on it any closer (%.1f sec off now, %.1f sec off with it), so the flights on it disagree or it needs other speeds, and it is left alone", path, (m.tried[1] and m.tried[1].analysis.data.pathName(path)) or "?", before, after)
					end
					state.lines[path], state.rampLines[path] = nil, nil
				end
			end
		end
	end

	-- the paths of a taxi map that are off by more than a few seconds with the speeds of the taxi map
	---@param m SuggestMap
	---@param state SuggestPaths
	function paths.suggest(m, state)
		local lib = m.lib
		local savedPaths, savedRamps = lib.Sim.PATH_SPEEDS, lib.Sim.PATH_RAMPS
		lib.Sim.PATH_SPEEDS, lib.Sim.PATH_RAMPS = {}, {}
		local confirmed, onMap, counts = confirmPaths(m)
		state.support = counts
		for _, flight in ipairs(m.tried) do
			suggestFlight(m, state, flight, confirmed)
		end
		lib.Sim.PATH_SPEEDS, lib.Sim.PATH_RAMPS = savedPaths, savedRamps
		keepTheOnesThatHelp(m, state, onMap)
	end

	-- Prints the paths that were suggested, and what there is to say about the others.
	---@param state SuggestPaths
	---@param suggestions string[] The lines that were suggested are added to these.
	---@return boolean printed If there was anything to print about the paths.
	function paths.print(state, suggestions)
		local noteLines = {}
		table.sort(state.order)
		local lines = {}
		for _, path in ipairs(state.order) do
			lines[#lines + 1] = state.lines[path]
			lines[#lines + 1] = state.rampLines[path]
		end
		for _, path in ipairs(util.keys(state.notes)) do
			if not state.lines[path] and not state.rampLines[path] then
				noteLines[#noteLines + 1] = state.notes[path]
			end
		end
		local printed = #lines > 0 or #noteLines > 0
		if printed then
			print("\n  paths with their own speeds")
			for _, line in ipairs(lines) do
				print(line)
				suggestions[#suggestions + 1] = line
			end
			for _, line in ipairs(noteLines) do
				print(line)
			end
		end
		if state.small > 0 then
			printf("\n  %d paths were off by 1 to %d sec with the speeds of their taxi map and are left alone\n", state.small, PATH_MIN_SECONDS)
		end
		return printed
	end

	return paths
end
