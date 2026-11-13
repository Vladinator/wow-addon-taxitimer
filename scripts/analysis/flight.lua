-- The analysis of a single recorded flight: how it was flown, how that compares to what was estimated and why it is off.

---A sample of where the flight was, from what the addon recorded.
---@class TrackSample
---@field t number Seconds since the flight was picked.
---@field x number Matches the x of the taxi data.
---@field y number Matches the y of the taxi data.
---@field map number The map the game said we were on.
---@field speed number The speed the game said we flew at.
---@field timer number The seconds the stopwatch had left.
---@field remaining number The yards the addon thought were left.
---@field point number The index in the points of the record of the point nearest to us.

---What happened between a sample and the one before it.
---@class TrackStep
---@field dt number Seconds.
---@field yards number Yards seen from above, 0 if we jumped.
---@field speed number
---@field kind "move"|"still"|"jump"

---A stretch between two points of the flight, in the order they are flown.
---@class FlownStretch
---@field path number The path the stretch is on.
---@field point number The index in the path of the point it starts at.
---@field yards number
---@field speed? number The speed flown for most of it to the nearest 5, if we saw it.

---What was seen of a path being flown.
---@class PathObservation
---@field speeds table<number, number> The speed flown from each point where the speed changed, by the index of the point in the path.
---@field first number The index in the path of the first point flown.
---@field last number The index in the path of the last point flown.
---@field unsure number[] The points we are not sure the speed changed at.
---@field time number The seconds seen flown on the path.
---@field distance number The yards seen flown on the path.

---A recorded flight and what is known about how it went.
---@class FlightAnalysis
---@field index number The number of the flight among the recorded ones.
---@field record FlightRecord
---@field data TaxiData
---@field ns taxi_ns_db
---@field near number
---@field far number
---@field warnings string[]
---@field incomplete? string Why the flight does not compare to its estimate, if it doesn't.
---@field track TrackSample[]
---@field steps table<number, TrackStep> `steps[i]` is between sample `i - 1` and sample `i`.
---@field hasOverride boolean
---@field moveTime number
---@field stillTime number
---@field jumpTime number
---@field jumps number
---@field travelled2D number
---@field travelled number Yards flown going by the speed the game reported.
---@field routeMaps table<number, boolean> The maps the points of the flight are on.
---@field start number Seconds since clicked we took off.
---@field end_ number Seconds since clicked we landed.
---@field uncertainty number Seconds the actual time can be off by.
---@field actual number Seconds the flight took.
---@field estimate number Seconds the flight was estimated to take.
---@field _geometry? FlightGeometry|false
---@field _observed? { paths: table<number, PathObservation>, intervals: FlownStretch[] }

---@param ctx AnalysisContext
---@return { new: fun(index: number, record: FlightRecord, data: TaxiData, near: number, far: number): FlightAnalysis }
return function(ctx)
	local util = ctx.util
	local format, concat = string.format, table.concat
	local abs, floor, max, min = math.abs, math.floor, math.max, math.min
	local INF = util.INF
	local hypot, hasFlag, clock = util.hypot, util.hasFlag, util.clock

	local STOP = 0x2

	---@class FlightAnalysis
	local Flight = {}
	Flight.__index = Flight

	-- Construction ---------------------------------------------------------------------------------------------------------

	--- Creates the analysis of a recorded flight.
	---@param index number The number of the flight among the recorded ones.
	---@param record FlightRecord
	---@param data TaxiData The taxi data of the game the flight was recorded on.
	---@param near number Yards from a point to count it as flown.
	---@param far number Yards from a point to count it as not flown.
	---@return FlightAnalysis
	function Flight.new(index, record, data, near, far)
		local self = setmetatable({
			index = index,
			record = record,
			data = data,
			ns = data.ns,
			near = near,
			far = far,
			warnings = {},
			incomplete = nil, -- why the flight does not compare to its estimate, if it doesn't
			track = {}, -- { t, x, y, map, speed, timer, remaining, point } per sample, x and y matching the taxi data
			steps = {}, -- [i] = { dt, yards (2D), speed, kind } between sample i - 1 and sample i, kind is "move", "still" or "jump"
			hasOverride = false,
			moveTime = 0,
			stillTime = 0,
			jumpTime = 0,
			jumps = 0,
			travelled2D = 0,
			travelled = 0, -- yards flown going by the speed the game reported
			routeMaps = {}, -- [map] = true for the maps the points of the flight are on
			start = 0,
			end_ = 0,
			uncertainty = 0,
			actual = 0,
			estimate = 0,
		}, Flight)
		for _, id in ipairs(record.points or {}) do
			local point = data.points[id]
			if point then
				self.routeMaps[point.map] = true
			end
		end
		self:buildTrack()
		self:buildTimes()
		self:checkComplete()
		return self
	end

	-- if a position the game gave us on one map can be compared to a point on another
	-- the game can be on a map of its own that shares its positions with the map the points are on (like Tanaan Jungle and Draenor), which it can not be if the flight has points on that map as well
	---@param seen number
	---@param map number
	---@return boolean
	function Flight:sameMap(seen, map)
		return seen == map or not self.routeMaps[seen]
	end

	function Flight:buildTrack()
		local r = self.record
		local swap = r.swapAxis
		for _, s in ipairs(r.samples or {}) do
			local x = swap and s[3] or s[2]
			local y = swap and s[2] or s[3]
			self.track[#self.track + 1] = { t = s[1], x = x, y = y, map = s[5], speed = s[6], timer = s[7], remaining = s[8], point = s[9] }
		end
		local track = self.track
		local scale = (r.distance2D and r.distance2D ~= 0) and r.distance / r.distance2D or 1
		for j = 2, #track do
			local a, b = track[j - 1], track[j]
			local dt = b.t - a.t
			local d = (self:sameMap(a.map, b.map) or self:sameMap(b.map, a.map)) and hypot(b.x - a.x, b.y - a.y) or INF
			local speed = b.speed
			local expected = max(speed, a.speed, 30) * dt
			local kind
			if d > max(60, expected * 3) then
				kind = "jump" -- changed map or moved further than we could have flown
				d = 0
				self.jumps = self.jumps + 1
				self.jumpTime = self.jumpTime + dt
			elseif d < 1 and speed < 1 then
				kind = "still"
				self.stillTime = self.stillTime + dt
			else
				kind = "move"
				if speed < 1 and dt > 0 then
					speed = d * scale / dt -- the game didn't tell us the speed so we go by how far we moved
				end
				self.moveTime = self.moveTime + dt
				self.travelled2D = self.travelled2D + d
				self.travelled = self.travelled + speed * dt
			end
			self.steps[j] = { dt = dt, yards = d, speed = speed, kind = kind }
		end
		for _, segment in ipairs(r.segments or {}) do
			if segment.override then
				self.hasOverride = true
			end
		end
		-- make sure our position and the taxi data agree on what is x and what is y
		if #track > 0 then
			local direct, swapped = 0, 0
			for _, i in ipairs({ 1, floor(#track / 2) + 1, #track }) do
				local s = track[i]
				direct = direct + self:nearestRoutePoint(s.x, s.y, s.map)
				swapped = swapped + self:nearestRoutePoint(s.y, s.x, s.map)
			end
			if swapped < direct then
				self.warnings[#self.warnings + 1] = "the positions fit the points better with x and y swapped, the addon got the axis order wrong for this flight"
			end
		end
	end

	---@param x number
	---@param y number
	---@param map number
	---@return number
	function Flight:nearestRoutePoint(x, y, map)
		local best = INF
		for _, id in ipairs(self.record.points or {}) do
			local p = self.data.points[id]
			if p and self:sameMap(map, p.map) then
				best = min(best, hypot(p.x - x, p.y - y))
			end
		end
		return best == INF and 100000 or best
	end

	function Flight:buildTimes()
		local r = self.record
		local first = r.firstTaxi or 0
		local last = r.lastTaxi or first
		local ground = r.lastGround or first
		local landed = r.landed or last
		self.start = (ground + first) / 2 -- seconds since clicked we took off
		self.end_ = (last + landed) / 2 -- seconds since clicked we landed
		self.uncertainty = ((first - ground) + (landed - last)) / 2 -- seconds the actual time can be off by
		self.actual = self.end_ - self.start
		self.estimate = r.estimate or 0
	end

	-- flights that did not go all the way to the destination must not be compared to the estimate
	function Flight:checkComplete()
		local r = self.record
		local points = r.points or {}
		local track = self.track
		local count = #track
		-- asking to land early ends the flight at the next taxi node, which on the last hop is the destination, so we go by where the flight ended
		local early = r.early and format("asked to land early %.0f sec into the flight", r.early - self.start) or nil
		local destination = self.data.points[points[#points] or 0]
		if count < 2 then
			self.incomplete = "not enough samples"
		elseif destination then
			local last = track[count]
			local distance = self:sameMap(last.map, destination.map) and hypot(destination.x - last.x, destination.y - last.y) or INF
			if distance > max(self.far, 100) then
				self.incomplete = (early and (early .. " and ") or "") .. (distance == INF and "ended on another map than the destination" or format("ended %.0f yd from the destination", distance))
			elseif early then
				self.warnings[#self.warnings + 1] = early .. " but it was on the last hop so the flight still went to the destination"
			end
		elseif early then
			self.incomplete = early
		end
		-- the game not responding for a while (loading, lag) leaves a hole in what we saw
		local gap = 0
		for i = 2, count do
			gap = max(gap, track[i].t - track[i - 1].t)
		end
		if gap > 2 then
			self.warnings[#self.warnings + 1] = format("nothing was recorded for %.1f sec at one point during the flight (loading screen or the game not responding), the speed and distance around it are less reliable", gap)
		end
	end

	-- Times and speeds -----------------------------------------------------------------------------------------------------

	-- seconds the flight took longer (positive) or shorter (negative) than estimated
	---@return number
	function Flight:error()
		return self.actual - self.estimate
	end

	-- splits the error up by what caused it, each in seconds the flight took longer (positive) or shorter (negative) than estimated, as a list of { name, seconds }
	---@return { [1]: string, [2]: number }[]? parts The cause and the seconds it adds.
	function Flight:errorSplit()
		local r = self.record
		local delay = r.delayIncluded and (r.delay or 0) or 0
		local speed = r.speed or 0
		if speed <= 0 then
			return nil
		end
		local split = {
			{ "distance", (self.travelled - r.distance) / speed }, -- we flew further or shorter than estimated
			{ "speed", self.moveTime - self.travelled / speed }, -- we flew slower or faster than estimated
			{ "standing still", self.stillTime - delay },
			{ "teleports", self.jumpTime },
		}
		local sum = 0
		for _, part in ipairs(split) do
			sum = sum + part[2]
		end
		split[#split + 1] = { "take off and landing", self:error() - sum }
		return split
	end

	---@return string
	function Flight:routeName()
		local names = {}
		for _, id in ipairs(self.record.route or {}) do
			names[#names + 1] = self.data.nodeName(id)
		end
		return concat(names, " > ")
	end

	-- the speed we flew at for most of the flight, outside of the segments that have their own speed
	---@return number?
	function Flight:typicalSpeed()
		local weights = {}
		local segments = self.record.segments or {}
		for j = 2, #self.track do
			local step = self.steps[j]
			if step.kind == "move" then
				local point = self.track[j].point
				local own = false
				for _, segment in ipairs(segments) do
					if segment.override and point >= segment.first and point <= segment.last then
						own = true
					end
				end
				if not own then
					local key = util.round(step.speed, 2)
					weights[key] = (weights[key] or 0) + step.dt
				end
			end
		end
		return util.weightedMedian(weights)
	end

	-- the speed to the nearest 5 the game appears to have set (40 is flown at 40.33)
	---@param speed number
	---@return number
	function Flight:roundSpeed(speed)
		return floor(speed / self.ns.TAXI_SPEED_SCALE / 5 + 0.5) * 5
	end

	-- Where the flight was ---------------------------------------------------------------------------------------------------

	-- distance from a position to where we flew
	---@param x number
	---@param y number
	---@param map number
	---@return number
	function Flight:distanceToTrack(x, y, map)
		local best = INF
		local track = self.track
		for i = 1, #track do
			local b = track[i]
			if self:sameMap(b.map, map) then
				best = min(best, hypot(b.x - x, b.y - y))
				if i > 1 and self.steps[i].kind ~= "jump" then
					local a = track[i - 1]
					local dx, dy = b.x - a.x, b.y - a.y
					local len = dx * dx + dy * dy
					if len > 0 then
						local t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / len))
						best = min(best, hypot(a.x + dx * t - x, a.y + dy * t - y))
					end
				end
			end
		end
		return best
	end

	---@param id number
	---@return string
	function Flight:describePoint(id)
		local p = self.data.points[id]
		if not p then
			return format("point %s (not in the taxi data)", tostring(id))
		end
		local text = format("path %d point %d of %d", p.path, p.index, #self.data.pathPoints[p.path])
		if p.flags ~= 0 then
			text = text .. format(", flags %d", p.flags)
		end
		if p.delay ~= 0 then
			text = text .. format(", delay %d", p.delay)
		end
		return text
	end

	-- What the simulation of the addon says about the flight, going by the points it flies now ---------------------------------

	--- The points the flight goes through and how far it is between them, from the simulation of the addon.
	---@return FlightGeometry?
	function Flight:geometry()
		if self._geometry == nil then
			local nodes = {} ---@type TaxiRouteNode[]
			for i, id in ipairs(self.record.route or {}) do
				nodes[i] = { nodeID = id }
			end
			local geometry = self.ns.GetFlightGeometry(nodes)
			self._geometry = #geometry.points > 0 and geometry or false
		end
		return self._geometry or nil
	end

	-- the speed flown from each point where the speed changed, as `{ [path id] = { speeds = { [point index] = speed }, first, last, unsure, time, distance } }`, and a list of the stretches between the points of the flight in the order they are flown
	-- the stretches are `{ path, point, yards, speed }` where the speed is the speed flown for most of it to the nearest 5, or nil if we did not see it
	-- the game changes the speed as it passes a point, so where we were when the speed changed tells us which point it was
	---@return table<number, PathObservation> paths
	---@return FlownStretch[] intervals
	function Flight:observe()
		if self._observed then
			return self._observed.paths, self._observed.intervals
		end
		local ns = self.ns
		local paths, intervals = {}, {}
		self._observed = { paths = paths, intervals = intervals }
		local geometry = self:geometry()
		if not geometry then
			return paths, intervals
		end
		local numBefore = 0
		for _, segment in ipairs(geometry.segments) do
			local points = segment.points
			local lengths = segment.intervals or {}
			for i = 1, #points - 1 do
				intervals[numBefore + i] = { path = points[i].pathId, point = points[i].index, yards = lengths[i] or 0 }
			end
			local curve, starts = ns.CatmulPath(points)
			if #curve >= 2 and #points >= 2 then
				self:observeSegment(points, curve, starts, intervals, numBefore, paths)
			end
			-- the stretches of the next segment come after the stretches between the points of this one
			numBefore = numBefore + max(0, #points - 1)
		end
		return paths, intervals
	end

	---@param points TaxiPathNode[]
	---@param curve Point[]
	---@param starts number[]
	---@param intervals FlownStretch[]
	---@param numBefore number
	---@param paths table<number, PathObservation>
	function Flight:observeSegment(points, curve, starts, intervals, numBefore, paths)
		local along = { 0 }
		for k = 2, #curve do
			local a, b = curve[k - 1], curve[k]
			along[k] = along[k - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
		end
		-- the points that are not at the same position as the point before them
		local kept = {}
		for i = 1, #points do
			if i == 1 or starts[i] > starts[i - 1] then
				kept[#kept + 1] = i
			end
		end
		-- how far along the curve we were each time we looked
		local seen = {}
		local at = 1
		local map = points[1].map
		for _, s in ipairs(self.track) do
			if self:sameMap(s.map, map) then
				local best
				for k = at, min(#curve - 1, at + 39) do
					local a, b = curve[k], curve[k + 1]
					local dx, dy = b.x - a.x, b.y - a.y
					local len = dx * dx + dy * dy
					local t = len > 0 and max(0, min(1, ((s.x - a.x) * dx + (s.y - a.y) * dy) / len)) or 0
					local distance = hypot(a.x + dx * t - s.x, a.y + dy * t - s.y)
					if not best or distance < best.distance - 0.000001 then
						best = { distance = distance, k = k, t = t }
					end
				end
				if best and best.distance <= 150 then
					at = best.k
					if s.speed >= 1 then
						seen[#seen + 1] = { t = s.t, along = along[at] + (along[at + 1] - along[at]) * best.t, speed = s.speed }
					end
				end
			end
		end
		-- the speed each stretch between two points was flown at for most of it
		for i = 1, #points - 1 do
			local from, to = along[starts[i]], along[starts[i + 1]]
			local flown = {}
			for _, look in ipairs(seen) do
				if look.along >= from and look.along < to then
					flown[#flown + 1] = look.speed
				end
			end
			table.sort(flown)
			if #flown > 0 then
				intervals[numBefore + i].speed = self:roundSpeed(flown[floor(#flown / 2) + 1])
			end
		end
		if #seen == 0 then
			return
		end
		-- the speed when first seen is what the first point set, each change after it is what the point we passed between two looks set
		local changes = { { 1, self:roundSpeed(seen[1].speed), false } } -- { position among the kept points, speed, unsure }
		local speed = seen[1].speed
		for i = 2, #seen do
			local a, b = seen[i - 1], seen[i]
			if abs(b.speed - speed) > 1.5 then
				local dt = b.t - a.t
				local tau = a.speed ~= b.speed and ((b.along - a.along) - b.speed * dt) / (a.speed - b.speed) or dt / 2
				local where = a.along + a.speed * max(0, min(dt, tau))
				local between, nearest = {}, nil
				for position, point in ipairs(kept) do
					local start = along[starts[point]]
					if start >= a.along - 12 and start <= b.along + 12 then
						between[#between + 1] = position
					end
					if not nearest or abs(start - where) < abs(along[starts[kept[nearest]]] - where) then
						nearest = position
					end
				end
				changes[#changes + 1] = { #between == 1 and between[1] or nearest, self:roundSpeed(b.speed), #between ~= 1 }
				speed = b.speed
			end
		end
		for position, point in ipairs(kept) do
			local p = points[point]
			local info = paths[p.pathId]
			if not info then
				info = { speeds = {}, first = p.index, last = p.index, unsure = {}, time = 0, distance = 0 }
				paths[p.pathId] = info
				-- the first point of a path we fly is flown at the speed set before we got to it
				for _, change in ipairs(changes) do
					if change[1] <= position then
						info.speeds[p.index] = change[2]
					end
				end
			end
			info.last = p.index
		end
		-- the seconds and yards flown on each path
		for i = 2, #seen do
			local position = 1
			for pos, point in ipairs(kept) do
				if along[starts[point]] <= seen[i - 1].along then
					position = pos
				end
			end
			local info = paths[points[kept[position]].pathId]
			info.time = info.time + seen[i].t - seen[i - 1].t
			info.distance = info.distance + seen[i].along - seen[i - 1].along
		end
		for _, change in ipairs(changes) do
			local p = points[kept[change[1]]]
			local info = paths[p.pathId]
			info.speeds[p.index] = change[2]
			if change[3] then
				info.unsure[#info.unsure + 1] = p.index
			end
		end
	end

	-- The report -------------------------------------------------------------------------------------------------------------

	---@return string
	function Flight:report()
		local r, d = self.record, self.data
		local out = {}
		local function add(text)
			out[#out + 1] = text
		end
		add(format("Flight %d: %s", self.index, self:routeName()))
		add(format("  recorded %s on %s build %s with addon %s, taxi map %s, %d samples", r.time and (os.date("!%Y-%m-%d %H:%M", r.time) .. " UTC") or "?", d.client, tostring(r.build or "?"), tostring(r.addon or "?"), tostring(r.area or "?"), #self.track))
		if self.incomplete then
			add(format("  INCOMPLETE: %s, so the estimate does not apply and the flight is left out of the summary of its taxi map", self.incomplete))
		end
		for _, warning in ipairs(self.warnings) do
			add("  WARNING: " .. warning)
		end
		if #self.track < 2 then
			add("  not enough samples to analyze")
			return concat(out, "\n")
		end

		-- time
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

		-- distance
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
		if #text > 0 then
			add("    " .. concat(text, ", "))
		end
		if self.jumps > 0 then
			add(format("    jumped %d times (changed map or moved further than could be flown), taking %.1f sec", self.jumps, self.jumpTime))
		end

		-- points
		add("")
		add("  Points")
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

		-- speed
		add("")
		add("  Speed")
		local typical = self:typicalSpeed()
		add(format("    the estimate used %.2f yd/sec for the taxi map, the flight was mostly flown at %s yd/sec", r.areaSpeed or 0, typical == nil and "?" or format("%.2f", typical)))
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
		-- the stretches flown at the same speed
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

		-- stops
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

		-- stopwatch
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

		return concat(out, "\n")
	end

	return Flight
end
