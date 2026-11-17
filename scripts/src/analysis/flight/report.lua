-- The details of a single flight, for `--flight=N` and `--all`.

local STOP = 0x2 -- the flag of a point that is a stop

---A stretch of a flight that was flown at the same speed.
---@class FlightStretch
---@field start number Seconds since we took off.
---@field duration number
---@field speed number -1 if we jumped, 0 if we stood still.
---@field first number The first point of the record it was flown from.
---@field last number
---@field weighted number The yards per second flown, added up over the seconds.

---@param ctx AnalysisContext
---@param class FlightAnalysis
return function(ctx, class)
	---@class FlightAnalysis
	local Flight = class

	local util = ctx.util
	local format, concat = string.format, table.concat
	local abs, max, min = math.abs, math.max, math.min
	local INF = util.INF
	local hypot, hasFlag, clock = util.hypot, util.hasFlag, util.clock

	---@alias FlightReportAdd fun(text: string)

	---@param self FlightAnalysis
	---@param add FlightReportAdd
	local function reportHeader(self, add)
		local r, d = self.record, self.data
		add(format("Flight %d: %s", self.index, self:routeName()))
		add(format("  recorded %s on %s build %s with addon %s, taxi map %s, %d samples", r.time and (os.date("!%Y-%m-%d %H:%M", r.time) .. " UTC") or "?", d.client, tostring(r.build or "?"), tostring(r.addon or "?"), tostring(r.area or "?"), #self.track))
		if self.incomplete then
			add(format("  INCOMPLETE: %s, so the estimate does not apply and the flight is left out of the summary of its taxi map", self.incomplete))
		end
		for _, warning in ipairs(self.warnings) do
			add("  WARNING: " .. warning)
		end
	end

	---@param self FlightAnalysis
	---@param add FlightReportAdd
	local function reportTime(self, add)
		local r = self.record
		local err = self:error()
		add("")
		add("  Time")
		add(format("    estimated %s, took %s (give or take %.1f sec), the flight was %.1f sec %s than estimated (%+.1f%%)", clock(self.estimate), clock(self.actual), self.uncertainty, abs(err), err < 0 and "shorter" or "longer", self.estimate > 0 and err / self.estimate * 100 or 0))
		local split = self:errorSplit()
		if split then
			local parts = {}
			for _, part in ipairs(split) do
				parts[#parts + 1] = format("%s %s", part[1], util.signed(part[2]))
			end
			add("    seconds longer (+) or shorter (-) by cause: " .. concat(parts, ", "))
			if self.hasOverride then
				add("    the route has a path with its own made up distance and speed, so distance and speed above can't be told apart for it")
			end
		end
		if r.delay and r.delay ~= 0 then
			add(format("    the paths have %d sec of stops which were %s the estimate", r.delay, r.delayIncluded and "part of" or "not part of"))
		end
	end

	-- how far from the points and the taxi nodes of the route the flight started and ended
	---@param self FlightAnalysis
	---@return string[] text
	local function endsOfTheRoute(self)
		local r, d = self.record, self.data
		local first = self.track[1]
		local last = self.track[#self.track]
		local route = r.route or {}
		local from = d.nodes[route[1] or 0]
		local to = d.nodes[route[#route] or 0]
		local points = r.points or {}
		local firstPoint = d.points[points[1] or 0]
		local lastPoint = d.points[points[#points] or 0]
		local text = {}
		if firstPoint then text[#text + 1] = format("first seen %.0f yd from the first point", hypot(firstPoint.x - first.x, firstPoint.y - first.y)) end
		if from then text[#text + 1] = format("%.0f yd from where the first taxi node is", hypot(from.x - first.x, from.y - first.y)) end
		if lastPoint then text[#text + 1] = format("last seen %.0f yd from the last point", hypot(lastPoint.x - last.x, lastPoint.y - last.y)) end
		if to then text[#text + 1] = format("%.0f yd from where the last taxi node is", hypot(to.x - last.x, to.y - last.y)) end
		return text
	end

	---@param self FlightAnalysis
	---@param add FlightReportAdd
	local function reportDistance(self, add)
		local r = self.record
		add("")
		add("  Distance")
		add(format("    estimated %.0f yd (%.0f yd seen from above), flew %.0f yd going by speed and %.0f yd seen from above going by position", r.distance, r.distance2D, self.travelled, self.travelled2D))
		for i, segment in ipairs(r.segments or {}) do
			local flown, time = 0, 0
			for j = 2, #self.track do
				local point = self.track[j].point
				if point >= segment.first and point <= segment.last then
					flown = flown + self.steps[j].yards
					time = time + self.steps[j].dt
				end
			end
			local text = format("    segment %d (points %d to %d): estimated %.0f yd seen from above at %.1f yd/sec taking %.1f sec, flew %.0f yd seen from above in %.1f sec", i, segment.first, segment.last, segment.distance2D, segment.speed, segment.speed > 0 and segment.distance / segment.speed or 0, flown, time)
			if segment.override then
				text = text .. " (made up distance and speed, only the time compares)"
			elseif segment.distance2D > 0 then
				text = text .. format(" (%+.1f%%)", (flown - segment.distance2D) / segment.distance2D * 100)
			end
			add(text)
		end
		local text = endsOfTheRoute(self)
		if self.noPosition then
			add("    no positions were given (an instance), so the distance flown is the speed times the time")
		elseif #text > 0 then
			add("    " .. concat(text, ", "))
		end
		if self.jumps > 0 then
			add(format("    jumped %d times (changed map or moved further than could be flown), taking %.1f sec", self.jumps, self.jumpTime))
		end
	end

	-- the points the estimate was made from that were not flown
	---@param self FlightAnalysis
	---@param add FlightReportAdd
	---@return table<number, boolean> used The points the estimate was made from.
	local function reportPointsNotFlown(self, add)
		local d = self.data
		local points = self.record.points or {}
		local used, missed = {}, {}
		for i, id in ipairs(points) do
			used[id] = true
			local p = d.points[id]
			if not p then
				missed[#missed + 1] = "      " .. self:describePoint(id)
			else
				local distance = self:distanceToTrack(p.x, p.y, p.map)
				if distance > self.far then
					missed[#missed + 1] = format("      %d. %s: %s", i, self:describePoint(id), distance == INF and "never on its map" or format("%.0f yd away", distance))
				end
			end
		end
		add(format("    %d of the %d points the estimate was made from were not flown (further than %d yd away)%s", #missed, #points, self.far, #missed > 0 and ":" or ""))
		for _, line in ipairs(missed) do
			add(line)
		end
		return used
	end

	-- the points of the paths of the route that the estimate skipped, and were flown
	---@param self FlightAnalysis
	---@param add FlightReportAdd
	---@param used table<number, boolean>
	local function reportPointsSkipped(self, add, used)
		local d = self.data
		local route = self.record.route or {}
		local flown, skipped = {}, 0
		for i = 1, #route - 1 do
			local destinations = d.paths[route[i]]
			local path = destinations and destinations[route[i + 1]]
			if not path then
				add(format("    no path from %s to %s in the taxi data", d.nodeName(route[i]), d.nodeName(route[i + 1])))
			else
				for _, id in ipairs(d.pathPoints[path] or {}) do
					if not used[id] then
						skipped = skipped + 1
						local p = d.points[id]
						local distance = self:distanceToTrack(p.x, p.y, p.map)
						if distance <= self.near then
							flown[#flown + 1] = format("      %s: %.0f yd away", self:describePoint(id), distance)
						end
					end
				end
			end
		end
		add(format("    %d of the %d points the estimate skipped were flown (within %d yd)%s", #flown, skipped, self.near, #flown > 0 and ":" or ""))
		for _, line in ipairs(flown) do
			add(line)
		end
	end

	-- the stretches of the flight that were flown at the same speed
	---@param self FlightAnalysis
	---@return FlightStretch[]
	local function stretchesOf(self)
		local stretches, current = {}, nil
		for j = 2, #self.track do
			local step = self.steps[j]
			local speed = step.kind == "move" and step.speed or (step.kind == "still" and 0 or -1)
			local stretch = current and stretches[current]
			if stretch and abs(stretch.speed - speed) <= 1.5 then
				stretch.duration = stretch.duration + step.dt
				stretch.last = self.track[j].point
				stretch.weighted = stretch.weighted + step.speed * step.dt
			else
				stretches[#stretches + 1] = { start = self.track[j - 1].t - self.start, duration = step.dt, speed = speed, first = self.track[j].point, last = self.track[j].point, weighted = step.speed * step.dt }
				current = #stretches
			end
		end
		return stretches
	end

	---@param self FlightAnalysis
	---@param add FlightReportAdd
	local function reportSpeedPerPath(self, add)
		local d = self.data
		local points = self.record.points or {}
		local perPath, pathOrder = {}, {}
		for j = 2, #self.track do
			local step = self.steps[j]
			if step.kind == "move" then
				local p = d.points[points[self.track[j].point] or 0]
				local path = p and p.path or 0
				local info = perPath[path]
				if not info then
					info = { time = 0, weighted = 0, min = INF, max = -INF, yards = 0 }
					perPath[path] = info
					pathOrder[#pathOrder + 1] = path
				end
				info.time = info.time + step.dt
				info.weighted = info.weighted + step.speed * step.dt
				info.min = min(info.min, step.speed)
				info.max = max(info.max, step.speed)
				info.yards = info.yards + step.yards
			end
		end
		for _, path in ipairs(pathOrder) do
			local info = perPath[path]
			add(format("    path %s: %.1f sec, %.0f yd seen from above, %.2f yd/sec on average (%.2f to %.2f)", path ~= 0 and tostring(path) or "?", info.time, info.yards, info.time > 0 and info.weighted / info.time or 0, info.min, info.max))
		end
	end

	---@param self FlightAnalysis
	---@param add FlightReportAdd
	---@param stretches FlightStretch[]
	local function reportSpeedChanges(self, add, stretches)
		local points = self.record.points or {}
		local long = {}
		for _, stretch in ipairs(stretches) do
			if stretch.duration >= 1.5 then
				long[#long + 1] = stretch
			end
		end
		if #long > 1 or #stretches > 3 then
			add(format("    the speed changed %d times, the stretches of 1.5 sec or longer:", #stretches - 1))
			for shown, stretch in ipairs(long) do
				if shown > 40 then
					add(format("      and %d more", #long - 40))
					break
				end
				local what = stretch.speed < 0 and "jumping" or (stretch.speed == 0 and "standing still" or format("%.1f yd/sec", stretch.duration > 0 and stretch.weighted / stretch.duration or stretch.speed))
				add(format("      %s for %.1f sec: %s, from %s to %s", clock(stretch.start), stretch.duration, what, self:describePoint(points[stretch.first] or 0), self:describePoint(points[stretch.last] or 0)))
			end
		else
			add("    the speed stayed the same during the flight")
		end
	end

	---@param self FlightAnalysis
	---@param add FlightReportAdd
	---@param stretches FlightStretch[]
	local function reportStops(self, add, stretches)
		local d = self.data
		local points = self.record.points or {}
		add("")
		add("  Stops")
		local stills = {}
		for _, stretch in ipairs(stretches) do
			if stretch.speed == 0 and stretch.duration >= 1 then
				stills[#stills + 1] = stretch
			end
		end
		-- the points that are stops, and how long we stood still at each (going by the stop nearest to where we stood still)
		local stops, stopOrder = {}, {}
		for i, id in ipairs(points) do
			local p = d.points[id]
			if p and hasFlag(p.flags, STOP) and p.delay ~= 0 then
				stops[i] = 0
				stopOrder[#stopOrder + 1] = i
			end
		end
		for _, still in ipairs(stills) do
			local nearest
			for _, i in ipairs(stopOrder) do
				if abs(still.first - i) <= 2 and (nearest == nil or abs(still.first - i) < abs(still.first - nearest)) then
					nearest = i
				end
			end
			if nearest then
				stops[nearest] = stops[nearest] + still.duration
			end
		end
		for _, i in ipairs(stopOrder) do
			add(format("    %d. %s: stood still for %.1f sec near it", i, self:describePoint(points[i]), stops[i]))
		end
		if #stopOrder == 0 then
			add("    none of the points the estimate was made from are stops")
		end
		add(format("    stood still for %.1f sec in total%s", self.stillTime, #stills > 0 and ":" or ""))
		for _, still in ipairs(stills) do
			add(format("      %s for %.1f sec near %s", clock(still.start), still.duration, self:describePoint(points[still.first] or 0)))
		end
	end

	---@param self FlightAnalysis
	---@param add FlightReportAdd
	local function reportStopwatch(self, add)
		add("")
		add("  Stopwatch")
		local worst, resets, previous = 0, 0, nil
		for _, s in ipairs(self.track) do
			if s.timer > 0 then
				local left = self.end_ - s.t
				worst = max(worst, abs(s.timer - left))
				if previous and abs((previous.timer - s.timer) - (s.t - previous.t)) > 1.5 then
					resets = resets + 1
				end
				previous = s
			end
		end
		add(format("    the time shown was off by up to %.1f sec and was changed %d times during the flight", worst, resets))
	end

	---@return string
	function Flight:report()
		local out = {}
		---@type FlightReportAdd
		local function add(text)
			out[#out + 1] = text
		end
		reportHeader(self, add)
		if #self.track < 2 then
			add("  not enough samples to analyze")
			return concat(out, "\n")
		end
		reportTime(self, add)
		reportDistance(self, add)
		if not self.noPosition then
			add("")
			add("  Points")
			local used = reportPointsNotFlown(self, add)
			reportPointsSkipped(self, add, used)
		end
		add("")
		add("  Speed")
		local typical = self:typicalSpeed()
		add(format("    the estimate used %.2f yd/sec for the taxi map, the flight was mostly flown at %s yd/sec", self.record.areaSpeed or 0, typical == nil and "?" or format("%.2f", typical)))
		reportSpeedPerPath(self, add)
		local stretches = stretchesOf(self)
		reportSpeedChanges(self, add, stretches)
		reportStops(self, add, stretches)
		reportStopwatch(self, add)
		return concat(out, "\n")
	end
end
