-- What the simulation of the addon says about a flight, going by the points it flies now, and the speeds the flight was seen to fly each path at.

---@param ctx AnalysisContext
---@param class FlightAnalysis
return function(ctx, class)
	---@class FlightAnalysis
	local Flight = class

	local abs, floor, max, min = math.abs, math.floor, math.max, math.min
	local hypot = ctx.util.hypot

	-- The points the flight goes through and how far it is between them, from the simulation of the addon.
	---@return TaxiTimerLib-1.0_FlightGeometry?
	function Flight:geometry()
		if self._geometry == nil then
			local nodes = {} ---@type TaxiTimerLib-1.0_TaxiRouteNode[]
			for i, id in ipairs(self.record.route or {}) do
				nodes[i] = { nodeID = id }
			end
			local geometry = self.lib.GetFlightGeometry(nodes, nil, nil, self.record.trips)
			self._geometry = #geometry.points > 0 and geometry or false
		end
		return self._geometry or nil
	end

	-- how far along the curve each of its points is
	---@param curve TaxiTimerLib-1.0_Point[]
	---@return number[] along
	local function lengthAlong(curve)
		local along = { 0 }
		for k = 2, #curve do
			local a, b = curve[k - 1], curve[k]
			along[k] = along[k - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
		end
		return along
	end

	-- the points that are not at the same position as the point before them
	---@param points TaxiTimerLib-1.0_TaxiPathNode[]
	---@param starts number[]
	---@return number[] kept
	local function keptPoints(points, starts)
		local kept = {}
		for i = 1, #points do
			if i == 1 or starts[i] > starts[i - 1] then
				kept[#kept + 1] = i
			end
		end
		return kept
	end

	---One time we looked at where the flight was along a curve.
	---@class FlightLook
	---@field t number
	---@field along number How far along the curve we were.
	---@field speed number

	-- how far along the curve we were each time we looked
	---@param self FlightAnalysis
	---@param points TaxiTimerLib-1.0_TaxiPathNode[]
	---@param curve TaxiTimerLib-1.0_Point[]
	---@param along number[]
	---@return FlightLook[]
	local function lookAlong(self, points, curve, along)
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
		return seen
	end

	-- the speed each stretch between two points was flown at for most of it
	---@param self FlightAnalysis
	---@param points TaxiTimerLib-1.0_TaxiPathNode[]
	---@param starts number[]
	---@param along number[]
	---@param seen FlightLook[]
	---@param intervals FlownStretch[]
	---@param numBefore number
	local function setStretchSpeeds(self, points, starts, along, seen, intervals, numBefore)
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
	end

	-- the speed when first seen is what the first point set, each change after it is what the point we passed between two looks set
	---@param self FlightAnalysis
	---@param kept number[]
	---@param starts number[]
	---@param along number[]
	---@param seen FlightLook[]
	---@return { [1]: number, [2]: number, [3]: boolean }[] changes `{ position among the kept points, speed, unsure }`
	local function speedChanges(self, kept, starts, along, seen)
		local changes = { { 1, self:roundSpeed(seen[1].speed), false } }
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
		return changes
	end

	-- what was seen of each path the points are on: the speeds it was flown at, which of its points were flown, and the seconds and yards flown on it
	---@param points TaxiTimerLib-1.0_TaxiPathNode[]
	---@param kept number[]
	---@param starts number[]
	---@param along number[]
	---@param seen FlightLook[]
	---@param changes { [1]: number, [2]: number, [3]: boolean }[]
	---@param paths table<number, PathObservation>
	local function recordPaths(points, kept, starts, along, seen, changes, paths)
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

	---@param self FlightAnalysis
	---@param points TaxiTimerLib-1.0_TaxiPathNode[]
	---@param curve TaxiTimerLib-1.0_Point[]
	---@param starts number[]
	---@param intervals FlownStretch[]
	---@param numBefore number
	---@param paths table<number, PathObservation>
	local function observeSegment(self, points, curve, starts, intervals, numBefore, paths)
		local along = lengthAlong(curve)
		local kept = keptPoints(points, starts)
		local seen = lookAlong(self, points, curve, along)
		setStretchSpeeds(self, points, starts, along, seen, intervals, numBefore)
		if #seen == 0 then
			return
		end
		local changes = speedChanges(self, kept, starts, along, seen)
		recordPaths(points, kept, starts, along, seen, changes, paths)
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
		local lib = self.lib
		local paths, intervals = {}, {}
		self._observed = { paths = paths, intervals = intervals }
		if self.noPosition then
			return paths, intervals
		end
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
			local curve, starts = lib.CatmullPath(points)
			if #curve >= 2 and #points >= 2 then
				observeSegment(self, points, curve, starts, intervals, numBefore, paths)
			end
			-- the stretches of the next segment come after the stretches between the points of this one
			numBefore = numBefore + max(0, #points - 1)
		end
		return paths, intervals
	end
end
