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
---@field lib TaxiTimerLib-1.0
---@field near number
---@field far number
---@field warnings string[]
---@field incomplete? string Why the flight does not compare to its estimate, if it doesn't.
---@field track TrackSample[]
---@field steps table<number, TrackStep> `steps[i]` is between sample `i - 1` and sample `i`.
---@field hasOverride boolean
---@field noPosition boolean If the game gave no positions (in instances), so only the time and the speed of the samples are of use.
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
---@field stalled? number Seconds the flight stood still at the end, which are left out of `actual`.
---@field actual number Seconds the flight took.
---@field estimate number Seconds the flight was estimated to take.
---@field _geometry? TaxiTimerLib-1.0_FlightGeometry|false
---@field _observed? { paths: table<number, PathObservation>, intervals: FlownStretch[] }

---@param ctx AnalysisContext
---@return { new: fun(index: number, record: FlightRecord, data: TaxiData, near: number, far: number): FlightAnalysis }
return function(ctx)
	local util = ctx.util
	local format, concat = string.format, table.concat
	local abs, floor, max, min = math.abs, math.floor, math.max, math.min
	local INF = util.INF
	local hypot = util.hypot

	local STALL_SECONDS = 3 -- seconds a flight can stand still at the end before it is a wait for the server and not the landing
	local MAX_STILL_SECONDS = 20 -- seconds a flight can stand still in one go before the game is seen as having lost it (stops along the way are a few seconds)
	local MAX_HANG_SECONDS = 4 -- seconds the game can go without a sample on one map before the time of the flight is not trusted (a loading screen is between two maps)

	---@class FlightAnalysis
	local Flight = {}
	Flight.__index = Flight

	--
	-- MARK: Construction
	--

	-- Creates the analysis of a recorded flight.
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
			lib = data.lib,
			near = near,
			far = far,
			warnings = {},
			incomplete = nil, -- why the flight does not compare to its estimate, if it doesn't
			track = {}, -- { t, x, y, map, speed, timer, remaining, point } per sample, x and y matching the taxi data
			steps = {}, -- [i] = { dt, yards (2D), speed, kind } between sample i - 1 and sample i, kind is "move", "still" or "jump"
			hasOverride = false,
			noPosition = false,
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
		-- the game gives no position in instances (`UnitPosition` is nil), so the samples have zeros and the map -1, and there are only the time and the speed
		self.noPosition = #track >= 2
		for _, s in ipairs(track) do
			if s.x ~= 0 or s.y ~= 0 then
				self.noPosition = false
				break
			end
		end
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
		if #track > 0 and not self.noPosition then
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

		-- a flight that stands still at the end (the game waiting for the server to hand us over) does not end when we arrive, so it is cut where it stopped moving, the waiting is not part of the flight
		local track, steps = self.track, self.steps
		local lastMove = #track
		while lastMove > 1 and steps[lastMove] and steps[lastMove].kind == "still" do
			lastMove = lastMove - 1
		end
		local stalled = #track > 0 and track[#track].t - track[lastMove].t or 0
		if stalled > STALL_SECONDS then
			self.stalled = stalled
			self.stillTime = self.stillTime - stalled
			self.end_ = track[lastMove].t + (landed - last) / 2 -- the same time after it stopped as the other flights have
			self.uncertainty = (first - ground) / 2 + 0.25
			self.actual = self.end_ - self.start
			self.warnings[#self.warnings + 1] = format("the flight stood still for %.1f sec at the end (waiting for the game to hand us over), that time is left out of how long it took", stalled)
		end
	end

	-- If the flight took as long as it takes to fly all of the route and not to a taxi node on the way, which is all there is to tell where it landed when the game gives no positions.
	---@return boolean
	function Flight:tookTheWholeRoute()
		local info = self:replay()
		if not info then
			return false
		end
		local checkpoints = self.lib.GetFlightCheckpoints(info)
		local actual = self.actual - self.jumpTime
		local nearest, nearestDifference
		for i, checkpoint in ipairs(checkpoints) do
			local difference = abs(checkpoint.time - actual)
			if not nearestDifference or difference < nearestDifference then
				nearest, nearestDifference = i, difference
			end
		end
		return nearest == #checkpoints
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
		elseif destination and not self.noPosition then
			local last = track[count]
			local distance = self:sameMap(last.map, destination.map) and hypot(destination.x - last.x, destination.y - last.y) or INF
			if distance > max(self.far, 100) then
				self.incomplete = (early and (early .. " and ") or "") .. (distance == INF and "ended on another map than the destination" or format("ended %.0f yd from the destination", distance))
			elseif early then
				self.warnings[#self.warnings + 1] = early .. " but it was on the last hop so the flight still went to the destination"
			end
		elseif early then
			-- without positions the time it took says if we landed at the destination or at a taxi node before it
			if self.noPosition and self:tookTheWholeRoute() then
				self.warnings[#self.warnings + 1] = early .. " but the flight took as long as all of the route, so it still went to the destination"
			else
				self.incomplete = early
			end
		end
		if self.noPosition and not self.incomplete then
			self.warnings[#self.warnings + 1] = "the game gave no positions (an instance), so only the time and the speed are used, and that the flight went all the way to the destination can not be checked"
		end
		-- a flight the game lost (a failed teleport or map load leaves us stuck while the taxi still goes on) does not tell how long the route takes
		-- standing still at the very end is the wait for the server that `buildTimes` leaves out, so only what was followed by moving on counts
		if not self.incomplete and count >= 2 then
			local still, longest = 0, 0
			for j = 2, count do
				local step = self.steps[j]
				if step and step.kind == "still" then
					still = still + step.dt
				else
					longest = max(longest, still)
					still = 0
				end
			end
			if longest > MAX_STILL_SECONDS then
				self.incomplete = format("stood still for %.0f sec in one go during the flight, the game lost it", longest)
			end
		end
		-- the game not responding for a while (loading, lag) leaves a hole in what we saw
		local gap, hang = 0, 0
		for i = 2, count do
			local seconds = track[i].t - track[i - 1].t
			gap = max(gap, seconds)
			-- a loading screen is between two maps, so a hole on the same map is the game not responding, which makes the time the flight took not tell how long the route takes
			if track[i].map == track[i - 1].map and not self.noPosition then
				hang = max(hang, seconds)
			end
		end
		if hang >= MAX_HANG_SECONDS and not self.incomplete then
			self.incomplete = format("the game did not respond for %.1f sec on one map during the flight, so how long it took is not reliable", hang)
		end
		if gap > 2 then
			self.warnings[#self.warnings + 1] = format("nothing was recorded for %.1f sec at one point during the flight (loading screen or the game not responding), the speed and distance around it are less reliable", gap)
		end
	end

	--
	-- MARK: Times and speeds
	--

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

	-- What the simulation estimates for the flight with the sim file as it is now (the estimate of the record is what the addon gave when it was flown).
	---@return TaxiTimerLib-1.0_FlightInfo?
	function Flight:replay()
		local geometry = self:geometry()
		if not geometry or not self.record.area then
			return nil
		end
		return self.lib.GetFlightInfoFromGeometry(geometry, self.record.area, self.record.speedModifier)
	end

	-- seconds the flight took longer (positive) or shorter (negative) than the simulation gives now, the time spent loading another map is left out
	---@return number?
	function Flight:errorNow()
		local info = self:replay()
		if not info then
			return nil
		end
		return self.actual - self.jumpTime - info.duration
	end

	-- when we first passed a point after `after` seconds, going by the samples of the flight
	---@param point TaxiDataPoint
	---@param after number
	---@return number? seconds
	function Flight:passedAt(point, after)
		if self.noPosition then
			return nil
		end
		local track = self.track
		local nearSq = self.near * self.near
		for j = 2, #track do
			local from, to = track[j - 1], track[j]
			if to.t > after and from.map == point.map and to.map == point.map and self.steps[j].kind == "move" then
				-- the place between the two samples that is closest to the point
				local dx, dy = to.x - from.x, to.y - from.y
				local lengthSq = dx * dx + dy * dy
				local along = lengthSq > 0 and ((point.x - from.x) * dx + (point.y - from.y) * dy) / lengthSq or 0
				along = max(0, min(1, along))
				local px, py = from.x + dx * along - point.x, from.y + dy * along - point.y
				local t = from.t + (to.t - from.t) * along
				if px * px + py * py <= nearSq and t > after then
					return t
				end
			end
		end
	end

	-- the last point we flew of the path arriving at a taxi node and the first point we flew of the path leaving it, going by the samples of the flight
	---@param arriving number The id of the path.
	---@param leaving number The id of the path.
	---@return number? last
	---@return number? first
	---@return boolean? whole If all of the two paths was flown at the taxi node.
	function Flight:flownJoin(arriving, leaving)
		local data = self.data
		local arrivingPoints, leavingPoints = data.pathPoints[arriving], data.pathPoints[leaving]
		if not arrivingPoints or not leavingPoints then
			return
		end
		-- the points of the path arriving are passed one after the other until the first one we did not pass
		local last, t = nil, -INF
		for i = 1, #arrivingPoints do
			local passed = self:passedAt(data.points[arrivingPoints[i]], t)
			if passed then
				last, t = i, passed
			elseif last then
				break
			end
		end
		if not last then
			return
		end
		-- the first point of the path leaving that we passed after that, and went on to the next from
		local count = #leavingPoints
		for i = 1, count do
			local passed = self:passedAt(data.points[leavingPoints[i]], t)
			if passed and (i == count or self:passedAt(data.points[leavingPoints[i + 1]], passed)) then
				return last, i, last == #arrivingPoints and i == 1
			end
		end
	end

	-- flying further or shorter than the simulation is about how the taxi nodes are flown past
	---@param self FlightAnalysis
	---@param lines string[]
	---@param info TaxiTimerLib-1.0_FlightInfo
	---@param geometry TaxiTimerLib-1.0_FlightGeometry
	---@param seconds number
	local function distanceCause(self, lines, info, geometry, seconds)
		local data = self.data
		local yards = self.travelled - geometry.distance
		if self.hasOverride or info.areaSpeed <= 0 or abs(yards) / info.areaSpeed < seconds then
			return
		end
		lines[#lines + 1] = format("distance: flew %.0f yd %s than the simulation flies (%.0f against %.0f), %.1f sec at %.0f yd/sec", abs(yards), yards < 0 and "less" or "more", self.travelled, geometry.distance, abs(yards) / info.areaSpeed, info.areaSpeed)
		local route = self.record.route or {}
		for k = 2, #route - 1 do
			local from, node, to = route[k - 1], route[k], route[k + 1]
			local arriving = data.paths[from] and data.paths[from][node]
			local leaving = data.paths[node] and data.paths[node][to]
			if arriving and leaving then
				local last, first, whole = self:flownJoin(arriving, leaving)
				if last then
					lines[#lines + 1] = format("  past %s: flew the path in up to point %d of %d and the path out from point %d%s", data.nodeName(node), last, #data.pathPoints[arriving], first, whole and " (all of both)" or "")
				else
					lines[#lines + 1] = format("  past %s: the samples do not show how it was flown", data.nodeName(node))
				end
			end
		end
	end

	-- the paths that were flown faster or slower than the simulation flies them
	---@param self FlightAnalysis
	---@param lines string[]
	---@param info TaxiTimerLib-1.0_FlightInfo
	---@param seconds number
	local function speedCause(self, lines, info, seconds)
		local data = self.data
		local scale = self.lib.TAXI_SPEED_SCALE
		local _, intervals = self:observe()
		local byPath, order = {}, {} ---@type table<number, { observed: number, predicted: number, flown: table<number, boolean>, used: table<number, boolean> }>, number[]
		for i, interval in ipairs(intervals) do
			local step = info.steps[i]
			if interval.speed and step and step.speed > 0 then
				local path = byPath[interval.path]
				if not path then
					path = { observed = 0, predicted = 0, flown = {}, used = {} }
					byPath[interval.path] = path
					order[#order + 1] = interval.path
				end
				path.observed = path.observed + interval.yards / (interval.speed * scale)
				path.predicted = path.predicted + step.distance / step.speed
				path.flown[interval.speed] = true
				path.used[util.round(step.speed / scale / 5) * 5] = true
			end
		end
		for _, id in ipairs(order) do
			local path = byPath[id]
			local diff = path.observed - path.predicted
			if abs(diff) >= seconds then
				local flown, used = {}, {}
				for _, speed in ipairs(util.keys(path.flown)) do
					flown[#flown + 1] = tostring(speed)
				end
				for _, speed in ipairs(util.keys(path.used)) do
					used[#used + 1] = tostring(speed)
				end
				lines[#lines + 1] = format("speed: path %d (%s) was flown at %s where the simulation uses %s, %+.1f sec", id, data.pathName(id) or "?", concat(flown, "/"), concat(used, "/"), diff)
			end
		end
	end

	-- What makes the flight differ from what the simulation gives now, as lines to show: the distance, how the taxi nodes were flown past, the speed of the paths and the time spent loading.
	---@param seconds number The seconds a cause must add or take away to be shown.
	---@return string[]
	function Flight:whyOff(seconds)
		local lines = {} ---@type string[]
		local info, geometry = self:replay(), self:geometry()
		if not info or not geometry then
			return lines
		end
		distanceCause(self, lines, info, geometry, seconds)
		speedCause(self, lines, info, seconds)
		if self.stillTime >= seconds then
			lines[#lines + 1] = format("standing still: %.1f sec", self.stillTime)
		end
		if self.jumpTime > 0 then
			lines[#lines + 1] = format("loading: %.1f sec spent loading another map is left out", self.jumpTime)
		end
		if #lines == 0 then
			lines[#lines + 1] = "nothing stands out: the distance and the speed of each path are close, so it is spread over the flight (how it takes off and lands, or the speeds by the length of the stretches)"
		end
		return lines
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
		-- what makes the flight path mount fly faster (like Frequent Flier) is not part of the speeds of the sim file
		return floor(speed / self.lib.TAXI_SPEED_SCALE / (self.record.speedModifier or 1) / 5 + 0.5) * 5
	end

	--
	-- MARK: Where the flight was
	--

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

	-- the geometry the simulation gives the flight and what was seen of the paths, and the details of the flight to show
	local folder = ctx.dir .. "/src/analysis/flight/"
	dofile(folder .. "observe.lua")(ctx, Flight)
	dofile(folder .. "report.lua")(ctx, Flight)

	return Flight
end
