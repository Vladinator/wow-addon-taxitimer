local ns = select(2, ...) ---@class taxi_ns_db

ns = ns or {}

---@class Point
---@field x number
---@field y number
---@field z number

local function pow(base, exponent)
	return base ^ exponent
end

local C_AMOUNT_OF_POINTS = 10
local C_ALPHA = 0.5

---@param t number
---@param p0 Point
---@param p1 Point
local function GetT(t, p0, p1)
	local a = pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2) + pow(p1.z - p0.z, 2)
	local b = pow(a, 0.5)
	local c = pow(b, C_ALPHA)
	return t + c
end

---@param p0 Point
---@param p1 Point
local function IsSamePoint(p0, p1)
	return p0.x == p1.x and p0.y == p1.y and p0.z == p1.z
end

-- Returns the point mirrored across `p1` from `p2`, used as the missing neighbor at either end of a path.
---@param p1 Point
---@param p2 Point
---@return Point
local function GetMirroredPoint(p1, p2)
	return { x = 2 * p1.x - p2.x, y = 2 * p1.y - p2.y, z = 2 * p1.z - p2.z }
end

-- Returns the points on the curve from `p1` up to (not including) `p2`. The points `p0` and `p3` are the neighbors that shape the curve.
---@param p0 Point
---@param p1 Point
---@param p2 Point
---@param p3 Point
---@return Point[]? points, number count
local function GetCatmulPoints(p0, p1, p2, p3)
	local t0 = 0
	local t1 = GetT(t0, p0, p1)
	local t2 = GetT(t1, p1, p2)
	local t3 = GetT(t2, p2, p3)

	-- two neighbors sharing the same position would divide by zero below
	if t1 == t0 or t2 == t1 or t3 == t2 then
		return nil, 0
	end

	local numNewPoints = 0
	local newPoints = {} ---@type Point[]

	local t1mt0 = t1 - t0
	local t2mt1 = t2 - t1
	local t3mt2 = t3 - t2
	local t2mt0 = t2 - t0
	local t3mt1 = t3 - t1

	-- the last point (p2) is left out as it is the first point of the next curve
	for i = 0, C_AMOUNT_OF_POINTS - 2 do
		local t = t1 + t2mt1 * i / (C_AMOUNT_OF_POINTS - 1)
		local t1mt = t1 - t
		local tmt0 = t - t0
		local t2mt = t2 - t
		local tmt1 = t - t1
		local t3mt = t3 - t
		local tmt2 = t - t2

		local a1l, a1r = t1mt/t1mt0, tmt0/t1mt0
		local a2l, a2r = t2mt/t2mt1, tmt1/t2mt1
		local a3l, a3r = t3mt/t3mt2, tmt2/t3mt2
		local b1l, b1r = t2mt/t2mt0, tmt0/t2mt0
		local b2l, b2r = t3mt/t3mt1, tmt1/t3mt1
		local cl, cr = a2l, a2r

		local A1x, A1y, A1z = a1l * p0.x + a1r * p1.x, a1l * p0.y + a1r * p1.y, a1l * p0.z + a1r * p1.z
		local A2x, A2y, A2z = a2l * p1.x + a2r * p2.x, a2l * p1.y + a2r * p2.y, a2l * p1.z + a2r * p2.z
		local A3x, A3y, A3z = a3l * p2.x + a3r * p3.x, a3l * p2.y + a3r * p3.y, a3l * p2.z + a3r * p3.z

		local B1x, B1y, B1z = b1l * A1x + b1r * A2x, b1l * A1y + b1r * A2y, b1l * A1z + b1r * A2z
		local B2x, B2y, B2z = b2l * A2x + b2r * A3x, b2l * A2y + b2r * A3y, b2l * A2z + b2r * A3z

		numNewPoints = numNewPoints + 1
		newPoints[numNewPoints] = { x = cl * B1x + cr * B2x, y = cl * B1y + cr * B2y, z = cl * B1z + cr * B2z }
	end

	return newPoints, numNewPoints
end

---@param p0 Point
---@param p1 Point
---@return number yards
local function GetDistance(p0, p1)
	return pow(pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2) + pow(p1.z - p0.z, 2), 0.5)
end

---@param path Point[]
---@param ignoreHeight? boolean `true` to measure the distance as seen from above (the height of the points is ignored)
---@return number yards, number[] intervals The yards flown between each point and the next, `intervals[i]` is from `path[i]` to `path[i + 1]`.
local function CatmulDistance(path, ignoreHeight)
	local intervals = {} ---@type number[]
	local numPoints = 0
	local points = {} ---@type Point[]
	local origins = {} ---@type number[] the index in `path` of each of the `points`

	-- a point sharing the position of the point before it adds no distance and would break the curve math
	for i = 1, #path do
		local point = path[i]

		if ignoreHeight then
			point = { x = point.x, y = point.y, z = 0 }
		end

		if i > 1 then
			intervals[i - 1] = 0
		end

		if numPoints == 0 or not IsSamePoint(points[numPoints], point) then
			numPoints = numPoints + 1
			points[numPoints] = point
			origins[numPoints] = i
		end
	end

	local distance = 0

	for i = 1, numPoints - 1 do
		local p1 = points[i]
		local p2 = points[i + 1]
		local p0 = points[i - 1] or GetMirroredPoint(p1, p2)
		local p3 = points[i + 2] or GetMirroredPoint(p2, p1)
		local newPoints, numNewPoints = GetCatmulPoints(p0, p1, p2, p3)
		local interval = 0
		local previous = p1

		-- without a curve the straight line to the next point is used
		if newPoints then
			for j = 1, numNewPoints do
				interval = interval + GetDistance(previous, newPoints[j])
				previous = newPoints[j]
			end
		end

		interval = interval + GetDistance(previous, p2)
		intervals[origins[i + 1] - 1] = interval
		distance = distance + interval
	end

	return distance, intervals
end

--- Returns the points of the curve through `path`, and where each point of the path is among them.
--- A point sharing the position of the point before it is where that point is.
---@param path Point[]
---@param ignoreHeight? boolean `true` to leave out the height of the points
---@return Point[] curve, number[] starts `starts[i]` is the index in `curve` of `path[i]`. What is flown from `path[i]` to `path[i + 1]` are the points from `starts[i]` up to `starts[i + 1]`.
local function CatmulPath(path, ignoreHeight)
	local curve = {} ---@type Point[]
	local starts = {} ---@type number[]
	local numCurve = 0
	local numPoints = 0
	local points = {} ---@type Point[]
	local origins = {} ---@type number[]

	for i = 1, #path do
		local point = path[i]

		if ignoreHeight then
			point = { x = point.x, y = point.y, z = 0 }
		end

		if numPoints == 0 or not IsSamePoint(points[numPoints], point) then
			numPoints = numPoints + 1
			points[numPoints] = point
			origins[numPoints] = i
		end
	end

	for i = 1, numPoints - 1 do
		local p1 = points[i]
		local p2 = points[i + 1]
		local p0 = points[i - 1] or GetMirroredPoint(p1, p2)
		local p3 = points[i + 2] or GetMirroredPoint(p2, p1)
		local newPoints, numNewPoints = GetCatmulPoints(p0, p1, p2, p3)

		starts[origins[i]] = numCurve + 1

		if newPoints then
			for j = 1, numNewPoints do
				numCurve = numCurve + 1
				curve[numCurve] = newPoints[j]
			end
		else
			-- without a curve the straight line to the next point is used
			numCurve = numCurve + 1
			curve[numCurve] = p1
		end
	end

	if numPoints > 0 then
		numCurve = numCurve + 1
		curve[numCurve] = points[numPoints]
		starts[origins[numPoints]] = numCurve
	end

	for i = 1, #path do
		if not starts[i] then
			starts[i] = starts[i - 1] or 1
		end
	end

	return curve, starts
end

--
-- Exports
--

ns.CatmulDistance = CatmulDistance
ns.CatmulPath = CatmulPath
