local SHOW_EXTRA_DEBUG_INFO = false -- enable displaying additional node information on taxi node tooltips
local RECORD_FLIGHTS = false -- enable recording of paths to SV for later analysis

local addonName = ... ---@type string

---@class TaxiNodesStruct

---@class TaxiPathStruct
---@field public ID 1
---@field public FROMTAXINODE 2
---@field public TOTAXINODE 3

---@class TaxiPathNodeStruct
---@field public LOC_0 1
---@field public LOC_1 2
---@field public LOC_2 3
---@field public ID 4
---@field public PATHID 5
---@field public CONTINENTID 6
---@field public FLAGS 7
---@field public DELAY 8

---@class TaxiPath
---@field public id number
---@field public from number
---@field public to number

---@class TaxiPathNode : Point
---@field public pathId number The path id.
---@field public index number The node index in the path.
---@field public id number The node id.
---@field public map number The map the point is on.
---@field public flags number
---@field public delay number The seconds the flight waits at the point if it is flagged as a stop.

-- A row of `ns.taxipath` where the columns are indexed using `ns.TAXIPATH`.
---@alias TaxiPathRow { [1]: number, [2]: number, [3]: number }

-- The rows of `ns.taxipath` split up into chunks.
---@alias TaxiPathStructDB table<number, TaxiPathRow[]>

-- A row of `ns.taxipathnode` where the columns are indexed using `ns.TAXIPATHNODE`.
---@alias TaxiPathNodeRow { [1]: number, [2]: number, [3]: number, [4]: number, [5]: number, [6]: number, [7]: number, [8]: number }

-- The rows of `ns.taxipathnode` split up into chunks, sorted by path and in flight order within each path.
---@alias TaxiPathNodeStructDB table<number, TaxiPathNodeRow[]>

---@class taxi_ns_db
---@field public TAXINODES TaxiNodesStruct
---@field public TAXIPATH TaxiPathStruct
---@field public TAXIPATHNODE TaxiPathNodeStruct
---@field public taxipath TaxiPathStructDB
---@field public taxipathnode TaxiPathNodeStructDB

local ns = select(2, ...) ---@class taxi_ns_db

ns = ns or {}

-- catmul.lua
do

	---@class Point
	---@field x number
	---@field y number
	---@field z number

	local CatmulDistance do
		local pow = math.pow

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
		function CatmulDistance(path, ignoreHeight)
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

	end

	ns.CatmulDistance = CatmulDistance

end

-- taxi.lua
do

	local CatmulDistance = ns.CatmulDistance
	local TAXIPATH = ns.TAXIPATH
	local TAXIPATHNODE = ns.TAXIPATHNODE
	local TaxiPath = ns.taxipath
	local TaxiPathNode = ns.taxipathnode

	local Speed do

		local TAXI_SPEED_FALLBACK = 30+1/3
		local TAXI_SPEED_40 = 40+1/3
		local TAXI_SPEED_50 = 50+5/12

		local fallback = setmetatable({
			[993] = TAXI_SPEED_50, -- Broken Isles
			[1011] = TAXI_SPEED_40, -- Zandalar
			[1014] = TAXI_SPEED_40, -- Kul Tiras
			[1504] = TAXI_SPEED_50, -- Nazjatar
			[1647] = TAXI_SPEED_40, -- Shadowlands
			[1922] = TAXI_SPEED_50, -- Draenor
			[2046] = TAXI_SPEED_50, -- Zereth Mortis
			[2057] = TAXI_SPEED_50, -- Dragon Isles
			[2175] = TAXI_SPEED_40, -- Zaralek Cavern
			[2241] = TAXI_SPEED_50, -- Emerald Dream
			[2276] = TAXI_SPEED_50, -- Khaz Algar
		}, {
			__index = function()
				return TAXI_SPEED_FALLBACK
			end,
			__call = function(self, areaID, useLive, noSafety)
				if areaID then
					local value = self[areaID]
					if useLive then
						local speed = GetUnitSpeed("player")
						if not noSafety then
							speed = max(speed, value)
						end
						return speed
					end
					return value
				else
					return TAXI_SPEED_FALLBACK
				end
			end,
		})

		---@param areaID? number
		---@param useLive? boolean
		---@param noSafety? boolean
		---@return number
		function Speed(areaID, useLive, noSafety)
			return fallback(areaID, useLive == true, noSafety == true)
		end

	end

	local GetPointsFromNodes
	local GetPointSpeeds
	local GetSpacingSpeed do

		local TAXI_PATH_NODE_FLAG_TELEPORT = 0x1 -- the flight continues at the next point without flying the distance between
		local TAXI_PATH_NODE_FLAG_STOP = 0x2 -- the flight waits at this point for the amount of seconds in the delay field

		local SKIP_POINT_DISTANCE = 40 -- yards (seen from above) around the edges of a path where its points are skipped as we fly past a taxi node without landing
		local SKIP_POINT_DISTANCE_SQ = SKIP_POINT_DISTANCE * SKIP_POINT_DISTANCE

		local RETRACE_DISTANCE = 100 -- yards (height included) between the points of the path arriving at a taxi node and the path leaving it for the two to run alongside each other
		local RETRACE_DISTANCE_SQ = RETRACE_DISTANCE * RETRACE_DISTANCE
		local RETRACE_REACH = 250 -- yards (seen from above) the stretch must reach away from the taxi node, on the path arriving and the path leaving together
		local RETRACE_POINTS = 4 -- points of each of the two paths that must run alongside the other before that stretch is skipped, fewer are left to the skip distance above

		-- The game changes the flight speed as it passes the points of a path.
		-- These speeds are not part of the client data, so they come from recorded flights.
		local TAXI_SPEED_SCALE = (40 + 1/3) / 40

		-- The speed flown from a point of a path until a later point of the path changes it, as `[pathId] = { [point index] = speed }`.
		-- The first point of a path must have a speed.
		---@type table<number, table<number, number>>
		local PATH_SPEEDS = {
			[7916] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [6] = 100, [7] = 300, [13] = 100, [16] = 65, [17] = 40, [18] = 30 }, -- Oribos > Pridefall Hamlet, Revendreth
			[7917] = { [1] = 15, [2] = 25, [3] = 40, [4] = 65, [5] = 100, [6] = 300, [11] = 100, [12] = 65, [13] = 40, [14] = 25 }, -- Pridefall Hamlet, Revendreth > Oribos
			[8012] = { [1] = 15, [2] = 30, [3] = 50, [7] = 300, [13] = 100, [16] = 65, [17] = 40, [18] = 25 }, -- Aspirant's Rest, Bastion > Oribos
			[8013] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [6] = 100, [8] = 300, [14] = 100, [17] = 65, [18] = 40, [19] = 25 }, -- Oribos > Aspirant's Rest, Bastion
			[8318] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [6] = 100, [7] = 300, [14] = 100, [15] = 65, [16] = 55, [17] = 50, [20] = 45, [21] = 40, [23] = 25 }, -- Oribos > Theater of Pain, Maldraxxus
			[8319] = { [1] = 15, [2] = 25, [3] = 40, [4] = 50, [8] = 65, [10] = 300, [17] = 100, [18] = 65, [20] = 40, [21] = 25 }, -- Theater of Pain, Maldraxxus > Oribos
			[8431] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [7] = 100, [8] = 300, [10] = 250, [11] = 200, [12] = 100, [14] = 40, [22] = 25 }, -- Oribos > Tirna Vaal, Ardenweald
			[8432] = { [1] = 10, [2] = 25, [3] = 40, [11] = 65, [13] = 100, [14] = 300, [16] = 250, [17] = 200, [18] = 100, [20] = 65, [22] = 40, [23] = 25 }, -- Tirna Vaal, Ardenweald > Oribos
			[8557] = { [1] = 25, [2] = 35, [3] = 45, [4] = 70, [5] = 100, [8] = 300, [15] = 155, [16] = 60, [17] = 40, [18] = 25 }, -- Oribos > Tazavesh, the Veiled Market
			[8558] = { [1] = 25, [2] = 50, [4] = 300, [11] = 100, [13] = 65, [14] = 50, [15] = 45, [16] = 25 }, -- Tazavesh, the Veiled Market > Oribos
			[9751] = { [1] = 20, [2] = 40, [3] = 50, [16] = 45, [17] = 40, [18] = 50, [19] = 40, [24] = 25 }, -- Gundargaz, The Ringing Deeps > Dornogal, Isle of Dorn
			[9761] = { [1] = 45, [4] = 40, [5] = 30, [6] = 65, [7] = 100, [9] = 65, [10] = 45, [15] = 55, [16] = 35, [21] = 30 }, -- Dornogal, Isle of Dorn > Gundargaz, The Ringing Deeps
		}

		---@class TaxiAreaRamp
		---@field public takeoff number[] The speeds flown from the first points of the flight, one per point.
		---@field public landing number[] The speeds flown from the last points before the destination, one per point, the last being the point before the destination.

		-- Taxi maps where flights speed up after taking off and slow down before landing.
		-- Paths in `PATH_SPEEDS` have their own speeds and do not use these.
		---@type table<number, TaxiAreaRamp>
		local AREA_RAMPS = {
			[993] = { takeoff = { 15, 30, 40 }, landing = {} }, -- Broken Isles
			[1011] = { takeoff = { 25, 25 }, landing = { 25, 15 } }, -- Zandalar
			[1014] = { takeoff = { 25, 25 }, landing = { 25, 15 } }, -- Kul Tiras
			[1647] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Shadowlands
			[1922] = { takeoff = { 30, 30, 40 }, landing = { 40, 30 } }, -- Draenor
			[2046] = { takeoff = { 25, 30, 40 }, landing = { 40, 30, 25 } }, -- Zereth Mortis
			[2175] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Zaralek Cavern
		}

		-- Taxi maps where the flight is slower the closer the points are to each other, as `{ yards, speed }` in rising order:
		-- a stretch between two points shorter than the yards is flown at the speed.
		-- This is what fits the recorded flights best, the game does not tell us why it flies slower there.
		-- Stretches with a speed from `PATH_SPEEDS` or `AREA_RAMPS` do not use these.
		---@type table<number, number[][]>
		local AREA_SPACING = {
			[993] = { { 60, 15 }, { 100, 30 }, { 130, 40 } }, -- Broken Isles
			[1922] = { { 80, 20 } }, -- Draenor
		}

		---@class TaxiPathSegment
		---@field public points TaxiPathNode[]
		---@field public distance? number The yards flown.
		---@field public distance2D? number The yards flown as seen from above.
		---@field public speed? number The average speed in yards per second.

		local hasLookup = false
		local pathLookup = {} ---@type table<number, table<number, number>> `[from][to] = pathId`
		local pathRows = {} ---@type table<number, TaxiPathNodeRow[]> `[pathId] = rows` in flight order
		local pathNodes = {} ---@type table<number, TaxiPathNode[]|false>

		-- the db is only walked once, the first time we need a path
		local function BuildLookup()
			hasLookup = true

			for i = 1, #TaxiPath do
				local taxiPathChunk = TaxiPath[i]

				for j = 1, #taxiPathChunk do
					local taxiPath = taxiPathChunk[j]
					local fromId = taxiPath[TAXIPATH.FROMTAXINODE]
					local toId = taxiPath[TAXIPATH.TOTAXINODE]
					local destinations = pathLookup[fromId]

					if not destinations then
						destinations = {}
						pathLookup[fromId] = destinations
					end

					-- the first path between two nodes is the one used
					if not destinations[toId] then
						destinations[toId] = taxiPath[TAXIPATH.ID]
					end
				end
			end

			for i = 1, #TaxiPathNode do
				local taxiPathChunk = TaxiPathNode[i]

				for j = 1, #taxiPathChunk do
					local taxiPathNode = taxiPathChunk[j]
					local pathId = taxiPathNode[TAXIPATHNODE.PATHID]
					local rows = pathRows[pathId]

					if not rows then
						rows = {}
						pathRows[pathId] = rows
					end

					rows[#rows + 1] = taxiPathNode
				end
			end
		end

		---@param pathId number
		---@return TaxiPathNode[]? nodes
		local function GetTaxiPathNodes(pathId)
			local nodes = pathNodes[pathId]

			if nodes == nil then
				if not hasLookup then
					BuildLookup()
				end

				local rows = pathRows[pathId]
				nodes = false

				if rows then
					nodes = {}

					for i = 1, #rows do
						local row = rows[i]

						nodes[i] = {
							x = row[TAXIPATHNODE.LOC_0],
							y = row[TAXIPATHNODE.LOC_1],
							z = row[TAXIPATHNODE.LOC_2],
							id = row[TAXIPATHNODE.ID],
							pathId = pathId,
							index = i,
							map = row[TAXIPATHNODE.CONTINENTID],
							flags = row[TAXIPATHNODE.FLAGS],
							delay = row[TAXIPATHNODE.DELAY],
						}
					end
				end

				pathNodes[pathId] = nodes
			end

			return nodes or nil
		end

		---@param from number
		---@param to number
		---@return TaxiPathNode[]? nodes
		local function GetTaxiPath(from, to)
			if not hasLookup then
				BuildLookup()
			end

			local destinations = pathLookup[from]
			local pathId = destinations and destinations[to]

			if not pathId then
				return
			end

			return GetTaxiPathNodes(pathId)
		end

		---@param node TaxiPathNode
		local function IsTeleport(node)
			return bit.band(node.flags, TAXI_PATH_NODE_FLAG_TELEPORT) ~= 0
		end

		---@param node TaxiPathNode
		local function IsStop(node)
			return node.delay > 0 and bit.band(node.flags, TAXI_PATH_NODE_FLAG_STOP) ~= 0
		end

		-- Checks if `node` is far enough away from `edge` to be flown when the taxi node at `edge` is passed without landing.
		---@param edge TaxiPathNode
		---@param node TaxiPathNode
		local function IsFarFromEdge(edge, node)
			if edge.map ~= node.map then
				return true
			end

			local dx = edge.x - node.x
			local dy = edge.y - node.y

			if dx * dx + dy * dy > SKIP_POINT_DISTANCE_SQ then
				return true
			end

			return IsTeleport(node) or IsStop(node)
		end

		--- Checks if `node` is close to any of the points of the path `nodes`, height included.
		---@param node TaxiPathNode
		---@param nodes TaxiPathNode[]
		local function IsNearPath(node, nodes)
			if IsTeleport(node) or IsStop(node) then
				return false
			end

			for i = 1, #nodes do
				local other = nodes[i]

				if other.map == node.map then
					local dx = other.x - node.x
					local dy = other.y - node.y
					local dz = other.z - node.z

					if dx * dx + dy * dy + dz * dz <= RETRACE_DISTANCE_SQ then
						return true
					end
				end
			end

			return false
		end

		--- Returns the last point flown of the path arriving at a taxi node and the first point flown of the path leaving it, if the two paths run alongside each other at the node.
		--- Where the way out of a taxi node goes back along the way in (like Ironforge between Kharanos and Menethil Harbor) the game does not fly in and back out, it flies from where the paths come together to where they part again.
		---@param arriving TaxiPathNode[]
		---@param leaving TaxiPathNode[]
		---@return number? last, number? first
		local function GetRetrace(arriving, leaving)
			local numArriving = #arriving
			local numLeaving = #leaving
			local last = numArriving
			local first = 1

			while last > 1 and IsNearPath(arriving[last], leaving) do
				last = last - 1
			end

			while first < numLeaving and IsNearPath(leaving[first], arriving) do
				first = first + 1
			end

			if numArriving - last < RETRACE_POINTS or first - 1 < RETRACE_POINTS then
				return
			end

			-- points circling the taxi node to land or take off are all close to each other without the paths running alongside each other
			-- so the stretch has to reach away from the node, going by how far out it starts on the two paths together
			local function GetReach(node, edge)
				local dx = node.x - edge.x
				local dy = node.y - edge.y
				return math.sqrt(dx * dx + dy * dy)
			end

			if GetReach(arriving[last + 1], arriving[numArriving]) + GetReach(leaving[first - 1], leaving[1]) >= RETRACE_REACH then
				return last, first
			end
		end

		-- Joins the paths of a route into the points that are flown.
		-- When flying past a taxi node the game doesn't land, it skips the points near where the path arriving at the node ends and where the path leaving the node begins.
		---@param paths TaxiPathNode[][]
		---@return TaxiPathNode[] points
		local function JoinTaxiPaths(paths)
			local points = {} ---@type TaxiPathNode[]
			local numPoints = 0
			local numPaths = #paths
			local firstFlown = {} ---@type table<number, number> `[pathIndex] = index` of the first point of the path that is flown, if not all of it is
			local lastFlown = {} ---@type table<number, number> `[pathIndex] = index` of the last point of the path that is flown, if not all of it is

			for pathIndex = 1, numPaths - 1 do
				local last, first = GetRetrace(paths[pathIndex], paths[pathIndex + 1])

				if last and first then
					lastFlown[pathIndex] = last
					firstFlown[pathIndex + 1] = first
				end
			end

			for pathIndex = 1, numPaths do
				local nodes = paths[pathIndex]
				local numNodes = #nodes
				local isFirst = pathIndex == 1
				local isLast = pathIndex == numPaths
				local first = nodes[1]
				local last = nodes[numNodes]
				local hasLeftPreviousPath = false

				for i = firstFlown[pathIndex] or 1, lastFlown[pathIndex] or numNodes do
					local node = nodes[i]

					if hasLeftPreviousPath or isFirst or numPoints == 0 or IsFarFromEdge(points[numPoints], node) then
						if (isFirst or (i > 2 and IsFarFromEdge(first, node)))
							and (isLast or (IsFarFromEdge(last, node) and (i < numNodes or numPoints == 0)))
							and not (numPoints > 0 and IsTeleport(node) and IsTeleport(points[numPoints]))
						then
							hasLeftPreviousPath = true
							numPoints = numPoints + 1
							points[numPoints] = node
						end
					else
						-- still too close to where the previous path ended so that point is skipped as well
						points[numPoints] = nil
						numPoints = numPoints - 1
					end
				end
			end

			return points
		end

		---@param nodes TaxiNodeInfo[]
		---@return TaxiPathNode[] points, TaxiPathSegment[] segments, number delay
		function GetPointsFromNodes(nodes)
			local paths = {} ---@type TaxiPathNode[][]

			for i = 2, #nodes do
				local from, to = nodes[i - 1], nodes[i]
				local path = GetTaxiPath(from.nodeID, to.nodeID)

				if path and path[1] then
					paths[#paths + 1] = path
				end
			end

			local points = JoinTaxiPaths(paths)
			local segments = {} ---@type TaxiPathSegment[]
			local segment ---@type TaxiPathSegment?
			local delay = 0

			-- the points are split up where the flight doesn't fly from one point to the next (teleports and map changes)
			for i = 1, #points do
				local point = points[i]
				local previous = points[i - 1]

				if not segment or previous.map ~= point.map or IsTeleport(previous) then
					segment = { points = {} }
					segments[#segments + 1] = segment
				end

				segment.points[#segment.points + 1] = point

				if IsStop(point) then
					delay = delay + point.delay
				end
			end

			return points, segments, delay
		end

		-- Returns the speed a path is flown at from the given point, if the path has its own speeds.
		---@param point TaxiPathNode
		---@return number? speed
		local function GetPathSpeed(point)
			local speeds = PATH_SPEEDS[point.pathId]

			if not speeds then
				return
			end

			-- the speed last set at or before the point, as the points before it can have been skipped
			for i = point.index, 1, -1 do
				local speed = speeds[i]

				if speed then
					return speed * TAXI_SPEED_SCALE
				end
			end
		end

		-- Returns the speed flown from each of the points to the next.
		---@param points TaxiPathNode[]
		---@param areaID? number
		---@return (number|false)[] speeds, boolean isDynamic `true` if the speed changes during the flight. The speed is `false` for the points that leave it to the taxi map.
		function GetPointSpeeds(points, areaID)
			local speeds = {} ---@type (number|false)[]
			local numPoints = #points
			local ramp = areaID and AREA_RAMPS[areaID]
			local isDynamic = false

			for i = 1, numPoints do
				local speed = GetPathSpeed(points[i])

				if not speed and ramp then
					local takeoff = ramp.takeoff[i]
					local landing = ramp.landing[#ramp.landing - (numPoints - 1 - i)]

					if i < numPoints and (landing or takeoff) then
						speed = (landing or takeoff) * TAXI_SPEED_SCALE
					end
				end

				if speed then
					isDynamic = true
				end

				speeds[i] = speed or false
			end

			return speeds, isDynamic
		end

		-- Returns the speed a stretch between two points is flown at going by its length, if the taxi map flies slower where the points are close.
		---@param areaID? number
		---@param yards number
		---@return number? speed
		function GetSpacingSpeed(areaID, yards)
			local spacing = areaID and AREA_SPACING[areaID]

			if not spacing then
				return
			end

			for i = 1, #spacing do
				local step = spacing[i]

				if yards < step[1] then
					return step[2] * TAXI_SPEED_SCALE
				end
			end
		end

	end

	local GetFlightInfo, GetFlightTimeLeft do

		---@class FlightStep
		---@field public distance number The yards flown between a point and the next.
		---@field public speed number The speed in yards per second it is flown at.
		---@field public distanceLeft number The yards left of the flight after it.
		---@field public durationLeft number The seconds left of the flight after it.

		---@class FlightInfo
		---@field public distance number The yards flown.
		---@field public distance2D number The yards flown as seen from above (without climbing and descending).
		---@field public speed number The average speed in yards per second (`distance / speed` is the seconds spent flying).
		---@field public duration number The estimated seconds the flight takes.
		---@field public delay number The seconds the paths say the flight waits at stops along the way.
		---@field public delayIncluded boolean If the `delay` is part of the `duration`.
		---@field public nodes TaxiNodeInfo[]
		---@field public points TaxiPathNode[]
		---@field public segments TaxiPathSegment[]
		---@field public steps FlightStep[] The stretches between the points in the order they are flown.
		---@field public maps table<number, boolean> The maps the points are on.
		---@field public dynamicSpeed boolean If the speed changes during the flight (the speed we fly at then says nothing about the rest of the flight).
		---@field public donotadjustarrivaltime? boolean

		local DO_NOT_ADJUST_FOR_MAPS = {
			[2276] = true, -- Khaz Algar
		}

		local INCLUDE_STOP_DELAYS = false -- if the seconds waiting at stops along the paths are added to the flight time (not confirmed that flights wait at these, so it's shown in the debug tooltip until it is)

		---@param taxiNodes TaxiNodeInfo[]
		---@param from? TaxiNodeInfo
		---@param to? TaxiNodeInfo
		---@param areaID? number
		---@return FlightInfo?
		function GetFlightInfo(taxiNodes, from, to, areaID)
			if not from or not to or from == to then
				return
			end
			local nodes = {} ---@type table<TaxiNodeInfo|number, boolean|TaxiNodeInfo>
			local slotIndex = to.slotIndex
			---@type number
			local numRoutes = GetNumRoutes(slotIndex) ---@diagnostic expect-line: assign-type-mismatch
			if type(numRoutes) ~= "number" then
				return -- the taxi map is not open
			end
			for routeIndex = 1, numRoutes do
				---@type number
				local sourceSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, true) ---@diagnostic expect-line: assign-type-mismatch, redundant-parameter
				---@type number
				local destinationSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, false) ---@diagnostic expect-line: assign-type-mismatch, redundant-parameter
				local sourceNode = taxiNodes[sourceSlotIndex]
				local destinationNode = taxiNodes[destinationSlotIndex]
				if sourceNode and destinationNode then
					if not nodes[sourceNode] then
						nodes[sourceNode] = true
						table.insert(nodes, sourceNode)
					end
					if not nodes[destinationNode] then
						nodes[destinationNode] = true
						table.insert(nodes, destinationNode)
					end
				end
			end
			local points, segments, delay = GetPointsFromNodes(nodes)
			local maps = {} ---@type table<number, boolean>
			for i = 1, #points do
				maps[points[i].map] = true
			end
			local areaSpeed = Speed(areaID)
			local speeds, isDynamic = GetPointSpeeds(points, areaID)
			local steps = {} ---@type FlightStep[]
			local numSteps = 0
			local numPoints = 0
			local distance = 0
			local distance2D = 0
			local duration = 0
			-- each stretch between two points is timed on its own as they do not all share the same speed
			for i = 1, #segments do
				local segment = segments[i]
				local segmentDistance, intervals = CatmulDistance(segment.points)
				local segmentDistance2D = CatmulDistance(segment.points, true)
				local segmentDuration = 0
				for j = 1, #intervals do
					local speed = speeds[numPoints + j] or GetSpacingSpeed(areaID, intervals[j])
					if speed then
						isDynamic = true
					else
						speed = areaSpeed
					end
					numSteps = numSteps + 1
					steps[numSteps] = { distance = intervals[j], speed = speed, distanceLeft = 0, durationLeft = 0 }
					segmentDuration = segmentDuration + intervals[j] / speed
				end
				numPoints = numPoints + #segment.points
				segment.distance, segment.distance2D, segment.speed = segmentDistance, segmentDistance2D, segmentDuration > 0 and segmentDistance / segmentDuration or areaSpeed
				distance = distance + segmentDistance
				distance2D = distance2D + segmentDistance2D
				duration = duration + segmentDuration
			end
			-- what is left of the flight once each stretch has been flown
			local distanceLeft = 0
			local durationLeft = 0
			for i = numSteps, 1, -1 do
				local step = steps[i]
				step.distanceLeft, step.durationLeft = distanceLeft, durationLeft
				distanceLeft = distanceLeft + step.distance
				durationLeft = durationLeft + step.distance / step.speed
			end
			if distance > 0 and duration > 0 then
				---@type FlightInfo
				local info = {
					distance = distance,
					distance2D = distance2D,
					speed = distance / duration,
					duration = duration,
					delay = delay,
					delayIncluded = INCLUDE_STOP_DELAYS,
					nodes = nodes,
					points = points,
					segments = segments,
					steps = steps,
					maps = maps,
					dynamicSpeed = isDynamic,
				}
				if INCLUDE_STOP_DELAYS then
					info.duration = info.duration + delay
				end
				info.donotadjustarrivaltime = not not (areaID and DO_NOT_ADJUST_FOR_MAPS[areaID])
				return info
			end
		end

		-- Returns the seconds left of the flight when the given yards are left of it, going by the speed of each stretch.
		---@param info FlightInfo
		---@param distance number
		---@return number seconds
		function GetFlightTimeLeft(info, distance)
			local steps = info.steps
			for i = 1, #steps do
				local step = steps[i]
				if distance >= step.distanceLeft then
					return step.durationLeft + min(distance - step.distanceLeft, step.distance) / step.speed
				end
			end
			return 0
		end

	end

	ns.Speed = Speed
	ns.GetPointsFromNodes = GetPointsFromNodes
	ns.GetFlightInfo = GetFlightInfo
	ns.GetFlightTimeLeft = GetFlightTimeLeft

end

-- core.lua
do

	local Speed = ns.Speed
	local GetFlightInfo = ns.GetFlightInfo
	local GetFlightTimeLeft = ns.GetFlightTimeLeft

	---@param timeAmount number
	---@param asMs? boolean
	---@param dropZeroHours? boolean
	local function GetTimeStringFromSeconds(timeAmount, asMs, dropZeroHours)
		local seconds = asMs and floor(timeAmount / 1000) or timeAmount
		local displayZeroHours = not (dropZeroHours and seconds < 3600)
		return SecondsToClock(seconds, displayZeroHours)
	end

	---@class Timer
	local Timer do

		Timer = {}

		---@param seconds number
		---@param override? boolean
		function Timer:Start(seconds, override)
			if not StopwatchFrame:IsShown() then
				Stopwatch_Toggle()
			end
			if override then
				Stopwatch_Clear()
			end
			if not Stopwatch_IsPlaying() then
				Stopwatch_StartCountdown(0, 0, seconds)
				Stopwatch_Play()
			end
		end

		function Timer:Stop()
			Stopwatch_Clear()
			StopwatchFrame:Hide()
		end

		function Timer:Get()
			local timer = StopwatchTicker.timer ---@type number?
			if not timer or timer < 1 then
				return 0
			end
			return timer
		end

	end

	---@class Recorder
	local Recorder do

		---@class FlightRecordSegment
		---@field public first number Index in `points` of the first point of the segment.
		---@field public last number Index in `points` of the last point of the segment.
		---@field public distance number Yards the segment was estimated to be.
		---@field public distance2D number Yards the segment was estimated to be as seen from above.
		---@field public speed number Average speed the segment was estimated to be flown at.
		---@field public override boolean Always `false`, older versions set it for paths with a made up distance and speed.

		---@class FlightRecord
		---@field public version number Format of the record.
		---@field public addon string Version of the addon.
		---@field public project number Game client (`WOW_PROJECT_ID`).
		---@field public build number Game build number.
		---@field public time number Server time when the flight was taken.
		---@field public area? number The taxi map.
		---@field public route number[] The taxi nodes (`TaxiNodes.ID`) of the route.
		---@field public points number[] The path points (`TaxiPathNode.ID`) the estimate was made from, in the order they are flown.
		---@field public segments FlightRecordSegment[] How the points were split up and estimated.
		---@field public estimate number Seconds the flight was estimated to take.
		---@field public distance number Yards the flight was estimated to be.
		---@field public distance2D number Yards the flight was estimated to be as seen from above.
		---@field public speed number Average speed of the estimate.
		---@field public areaSpeed number Speed used for the taxi map.
		---@field public delay number Seconds of stops along the paths.
		---@field public delayIncluded boolean If the stops were part of the estimate.
		---@field public swapAxis? boolean If x and y of our position had to be swapped to match the points when looking for the nearest point.
		---@field public clicked number `GetTime()` when the flight was picked. The times below are seconds since then.
		---@field public lastGround? number When we were last seen waiting for the flight to start.
		---@field public firstTaxi? number When we were first seen on the flight.
		---@field public lastTaxi? number When we were last seen on the flight.
		---@field public landed? number When we were first seen having ended the flight.
		---@field public early? number When we asked to land early at the next taxi node. The flight then ends before the destination so it does not compare to the estimate.
		---@field public samples number[][] What was seen while on the flight as `{ seconds since clicked, x, y, z, map, speed, stopwatch, remaining, point }`. The position and map are what `UnitPosition` returned. The speed is what `GetUnitSpeed` returned. The stopwatch is the seconds the stopwatch had left. The remaining is the yards we think are left. The point is the index in `points` of the point nearest to us.

		local RECORD_VERSION = 1
		local RECORD_MAX_FLIGHTS = 200 -- the oldest flights are dropped once we have more than this
		local RECORD_SEARCH_AHEAD = 8 -- amount of points ahead of where we are that we look at to find the point nearest to us
		local RECORD_LOST_DISTANCE = 500 -- yards away from the points near us before we look at all the points ahead

		---@class RecorderFlight
		---@field public info FlightInfo
		---@field public record FlightRecord
		---@field public pointIndex? number

		local current ---@type RecorderFlight?

		Recorder = {}

		---@param value? number
		---@param decimals number
		---@return number
		local function Round(value, decimals)
			if not value then
				return 0
			end
			local mult = 10 ^ decimals
			return floor(value * mult + 0.5) / mult
		end

		---@param points TaxiPathNode[]
		---@param first number
		---@param last number
		---@param x number
		---@param y number
		---@param mapID? number
		---@return number? index, number distanceSq
		local function GetNearestPoint(points, first, last, x, y, mapID)
			local nearest ---@type number?
			local nearestDistance = math.huge
			for i = first, last do
				local point = points[i]
				if not mapID or point.map == mapID then
					local dx = point.x - x
					local dy = point.y - y
					local distance = dx * dx + dy * dy
					if distance < nearestDistance then
						nearest = i
						nearestDistance = distance
					end
				end
			end
			return nearest, nearestDistance
		end

		-- Returns the index of the point nearest to us among the points ahead of where we were last.
		---@param flight RecorderFlight
		---@param x number
		---@param y number
		---@param mapID? number
		---@return number? index
		local function GetCurrentPoint(flight, x, y, mapID)
			local points = flight.info.points
			local numPoints = #points
			local record = flight.record
			-- a map the points are not on shares its positions with the map they are on
			if mapID and not flight.info.maps[mapID] then
				mapID = nil
			end
			if record.swapAxis == nil then
				-- the first time we make sure our position and the points agree on what is x and what is y
				local _, distance = GetNearestPoint(points, 1, numPoints, x, y, mapID)
				local _, swapDistance = GetNearestPoint(points, 1, numPoints, y, x, mapID)
				record.swapAxis = swapDistance < distance
			end
			if record.swapAxis then
				x, y = y, x
			end
			local first = flight.pointIndex or 1
			local index, distance = GetNearestPoint(points, first, min(numPoints, first + RECORD_SEARCH_AHEAD), x, y, mapID)
			if not index or distance > RECORD_LOST_DISTANCE * RECORD_LOST_DISTANCE then
				index = GetNearestPoint(points, first, numPoints, x, y, mapID) or index
			end
			if index then
				flight.pointIndex = index
			end
			return index
		end

		---@param state State
		---@param info FlightInfo
		function Recorder:Start(state, info)
			current = nil
			if not RECORD_FLIGHTS then
				return
			end
			local route = {} ---@type number[]
			for i = 1, #info.nodes do
				route[i] = info.nodes[i].nodeID
			end
			local points = {} ---@type number[]
			for i = 1, #info.points do
				points[i] = info.points[i].id
			end
			local segments = {} ---@type FlightRecordSegment[]
			local numPoints = 0
			for i = 1, #info.segments do
				local segment = info.segments[i]
				segments[i] = {
					first = numPoints + 1,
					last = numPoints + #segment.points,
					distance = Round(segment.distance, 1),
					distance2D = Round(segment.distance2D, 1),
					speed = Round(segment.speed, 2),
					override = false,
				}
				numPoints = numPoints + #segment.points
			end
			---@type RecorderFlight
			current = {
				info = info,
				record = {
					version = RECORD_VERSION,
					addon = C_AddOns.GetAddOnMetadata(addonName, "Version") or "",
					project = WOW_PROJECT_ID,
					build = tonumber((select(2, GetBuildInfo()))) or 0,
					time = GetServerTime(),
					area = state.areaID,
					route = route,
					points = points,
					segments = segments,
					estimate = Round(info.duration, 1),
					distance = Round(info.distance, 1),
					distance2D = Round(info.distance2D, 1),
					speed = Round(info.speed, 2),
					areaSpeed = Round(Speed(state.areaID), 2),
					delay = info.delay,
					delayIncluded = info.delayIncluded,
					clicked = Round(GetTime(), 2),
					samples = {},
				},
			}
		end

		-- called while we wait for the flight to start
		function Recorder:Idle()
			local flight = current
			if flight and not flight.record.firstTaxi then
				flight.record.lastGround = Round(GetTime() - flight.record.clicked, 2)
			end
		end

		-- called while we are on the flight
		---@param x? number
		---@param y? number
		---@param z? number
		---@param mapID? number
		---@param remaining? number
		function Recorder:Tick(x, y, z, mapID, remaining)
			local flight = current
			if not flight then
				return
			end
			local record = flight.record
			local elapsed = Round(GetTime() - record.clicked, 2)
			if not record.firstTaxi then
				record.firstTaxi = elapsed
			end
			record.lastTaxi = elapsed
			local samples = record.samples
			samples[#samples + 1] = {
				elapsed,
				Round(x, 1),
				Round(y, 1),
				Round(z, 1),
				mapID or -1,
				Round(GetUnitSpeed("player"), 2),
				Round(Timer:Get(), 1),
				Round(remaining, 1),
				x and y and GetCurrentPoint(flight, x, y, mapID) or 0,
			}
		end

		-- asking to land early ends the flight at the next taxi node
		if RECORD_FLIGHTS and TaxiRequestEarlyLanding then
			hooksecurefunc("TaxiRequestEarlyLanding", function()
				local flight = current
				if flight and flight.record.firstTaxi and not flight.record.early then
					flight.record.early = Round(GetTime() - flight.record.clicked, 2)
				end
			end)
		end

		-- called once the flight has ended, or if we gave up waiting for it to start
		function Recorder:Stop()
			local flight = current
			current = nil
			if not flight or not flight.record.firstTaxi then
				return
			end
			local record = flight.record
			record.landed = Round(GetTime() - record.clicked, 2)
			local db = TaxiTimerDB
			if type(db) ~= "table" then
				db = {}
				TaxiTimerDB = db
			end
			local flights = db.flights
			if type(flights) ~= "table" then
				flights = {}
				db.flights = flights
			end
			flights[#flights + 1] = record
			while #flights > RECORD_MAX_FLIGHTS do
				table.remove(flights, 1)
			end
		end

	end

	---@class GPS
	local GPS do

		---@class GPSInfoTimeCorrection
		---@field public progress number
		---@field public chunk number
		---@field public adjustments number
		---@field public difference? number

		---@class GPSInfo
		---@field public wasOnTaxi boolean
		---@field public waitingOnTaxi number
		---@field public timeCorrection? GPSInfoTimeCorrection
		---@field public distance? number
		---@field public timeLeft? number
		---@field public lastOnTaxi? number `GetTime()` when we were last seen on the flight.
		---@field public lastMapID? number The map we were on when last seen on the flight.
		---@field public earlyLanding? boolean If we asked to land early at the next taxi node.

		local TAXI_MAX_MAP_CHANGE = 30 -- seconds we wait for a flight to carry on after it left the taxi on its way to another map (the game takes us off the taxi while the next map loads)
		local TAXI_MAX_MAP_CHANGE_DISTANCE = 100 -- yards we must be away from the destination for the flight to be on its way to another map and not have ended
		local TAXI_MAX_SLEEP = 30 -- seconds before we give up waiting on the taxi to start (can happen if lag, or other conditions not being met as we click to fly somewhere)

		local TAXI_TIME_CORRECT = true -- if we wish to change the stopwatch time based on our movement and dynamic speed (if false, uses the original calculation and keeps the timer as-is during the flight)
		local TAXI_TIME_CORRECT_INTERVAL = 2 -- adjusts the timer X amount of times during flight to better calculate actual arrival time (some taxi paths slow down at start, or speed up eventually, this causes some seconds differences, this aims to counter that a bit)
		local TAXI_TIME_CORRECT_IGNORE = 5 -- amount of seconds we need to be wrong, before adjusting the timer

		local TAXI_TIME_CORRECT_MUTE_UPDATES = false -- mute the mid-flight updates
		local TAXI_TIME_CORRECT_MUTE_SUMMARY = false -- mute the end-of-flight summary

		local GPSInfo ---@type GPSInfo?
		local Ticker ---@type FunctionContainer?

		GPS = {}

		-- Checks if we left the taxi because the flight is changing to the map of its destination, and not because the flight ended.
		---@param info FlightInfo
		---@return boolean
		local function IsChangingMap(info)
			local gps = GPSInfo
			if not gps or gps.earlyLanding or not gps.lastOnTaxi or not gps.lastMapID or not gps.distance then
				return false
			end
			local destination = info.points[#info.points]
			if not destination or destination.map == gps.lastMapID or GetTime() - gps.lastOnTaxi >= TAXI_MAX_MAP_CHANGE then
				return false
			end
			-- the game can be on a map of its own that shares its positions with the map of the points (like Tanaan Jungle and Draenor), so being on another map than the destination does not tell us that we are not there yet
			-- where we were last seen does, and it does not drift like the distance we think is left
			local x, y = gps.lastX, gps.lastY
			if not x or not y then
				return gps.distance > TAXI_MAX_MAP_CHANGE_DISTANCE
			end
			local dx, dy = destination.x - x, destination.y - y
			local sx, sy = destination.x - y, destination.y - x -- our position can have x and y the other way around
			return min(dx * dx + dy * dy, sx * sx + sy * sy) > TAXI_MAX_MAP_CHANGE_DISTANCE * TAXI_MAX_MAP_CHANGE_DISTANCE
		end

		-- asking to land early ends the flight at the next taxi node, which can be on a map before the one of the destination
		if TaxiRequestEarlyLanding then
			hooksecurefunc("TaxiRequestEarlyLanding", function()
				if GPSInfo then
					GPSInfo.earlyLanding = true
				end
			end)
		end

		---@param state State
		---@param info FlightInfo
		function GPS:Start(state, info)
			-- any previous flight is stopped before the stopwatch is started for this flight
			if Ticker then
				Timer:Stop()
				Ticker:Cancel()
			end
			Recorder:Start(state, info)
			if info.donotadjustarrivaltime then
				Timer:Start(info.duration, true)
			end
			---@class GPSInfo
			GPSInfo = {
				wasOnTaxi = false,
				waitingOnTaxi = GetTime(),
			}
			-- our position is tracked as seen from above, so what we travel is scaled to match the flight distance that includes climbing and descending
			local travelScale = info.distance2D > 0 and info.distance / info.distance2D or 1
			local areaSpeed = Speed(state.areaID)
			Ticker = C_Timer.NewTicker(0.5, function()
				if not GPSInfo.distance then
					GPSInfo.distance = info.distance
					if TAXI_TIME_CORRECT and TAXI_TIME_CORRECT_INTERVAL and not info.donotadjustarrivaltime then
						GPSInfo.timeCorrection = {
							progress = info.distance,
							chunk = GPSInfo.distance * (1 / (TAXI_TIME_CORRECT_INTERVAL + 1)),
							adjustments = 0,
						}
					end
				end
				if UnitOnTaxi("player") then
					GPSInfo.wasOnTaxi = true
					GPSInfo.lastOnTaxi = GetTime()
					GPSInfo.speed = Speed(state.areaID, true)
					GPSInfo.x, GPSInfo.y, GPSInfo.z, GPSInfo.mapID = UnitPosition("player")
					if GPSInfo.lastSpeed then
						-- going from one map of the points to another the positions do not compare, but a map the points are not on shares its positions with the map they are on
						if GPSInfo.mapID and GPSInfo.lastMapID and GPSInfo.mapID ~= GPSInfo.lastMapID and info.maps[GPSInfo.mapID] and info.maps[GPSInfo.lastMapID] then
							GPSInfo.lastX = nil
						end
						if GPSInfo.lastX then
							GPSInfo.distance = GPSInfo.distance - sqrt((GPSInfo.lastX - GPSInfo.x)^2 + (GPSInfo.lastY - GPSInfo.y)^2) * travelScale
							GPSInfo.distancePercent = GPSInfo.distance / info.distance
							if GPSInfo.distance > 0 and GPSInfo.speed > 0 then
								local timeCorrection = TAXI_TIME_CORRECT
								-- the time left goes by the speed of each stretch that is left, and if the whole flight is at one speed also by how much faster than expected we fly
								GPSInfo.timeLeft = GetFlightTimeLeft(info, GPSInfo.distance)
								if not info.dynamicSpeed then
									GPSInfo.timeLeft = GPSInfo.timeLeft * areaSpeed / GPSInfo.speed
								end
								-- DEBUG: current progress
								-- DEFAULT_CHAT_FRAME:AddMessage(format("Flight progress |cffFFFFFF%d|r yd (%.1f%%)", GPSInfo.distance, GPSInfo.distancePercent * 100), 1, 1, 0)
								local gpsInfoTimeCorrection = GPSInfo.timeCorrection
								-- if time correction is enabled to correct in intervals we will do the logic here
								if gpsInfoTimeCorrection then
									timeCorrection = false
									-- make sure we are at a checkpoint before calculating the new time
									if gpsInfoTimeCorrection.progress > GPSInfo.distance then
										timeCorrection = true
										-- set next checkpoint, and calculate time difference
										gpsInfoTimeCorrection.progress = gpsInfoTimeCorrection.progress - gpsInfoTimeCorrection.chunk
										gpsInfoTimeCorrection.difference = floor(Timer:Get() - GPSInfo.timeLeft)
										-- check if time difference is within acceptable boundaries
										if TAXI_TIME_CORRECT_IGNORE > 0 and abs(gpsInfoTimeCorrection.difference) < TAXI_TIME_CORRECT_IGNORE then
											timeCorrection = false
										elseif GPSInfo.stopwatchSet then
											gpsInfoTimeCorrection.adjustments = gpsInfoTimeCorrection.adjustments + gpsInfoTimeCorrection.difference
											-- announce the stopwatch time adjustments if significant enough to be noteworthy, and if we have more than just one interval (we then just summarize at the end)
											if not info.donotadjustarrivaltime and not TAXI_TIME_CORRECT_MUTE_UPDATES and TAXI_TIME_CORRECT_INTERVAL > 1 then
												DEFAULT_CHAT_FRAME:AddMessage("Expected arrival time adjusted by |cffFFFFFF" .. abs(gpsInfoTimeCorrection.difference) .. " seconds|r.", 1, 1, 0)
											end
										end
									end
								end
								-- set or override the stopwatch based on time correction mode
								-- a stopwatch that ran out before we landed is only started again if there is a good while left, or
								-- it would start over and ring again and again as we come in to land
								if not info.donotadjustarrivaltime and (timeCorrection or not GPSInfo.stopwatchSet or GPSInfo.timeLeft > TAXI_TIME_CORRECT_IGNORE) then
									Timer:Start(GPSInfo.timeLeft, timeCorrection)
								end
								-- stopwatch was set at least once
								GPSInfo.stopwatchSet = true
							end
						end
					end
					Recorder:Tick(GPSInfo.x, GPSInfo.y, GPSInfo.z, GPSInfo.mapID, GPSInfo.distance)
					GPSInfo.lastSpeed = GPSInfo.speed
					GPSInfo.lastX, GPSInfo.lastY, GPSInfo.lastMapID = GPSInfo.x, GPSInfo.y, GPSInfo.mapID
				elseif not GPSInfo.wasOnTaxi then
					Recorder:Idle()
					GPSInfo.wasOnTaxi = GetTime() - GPSInfo.waitingOnTaxi > TAXI_MAX_SLEEP
				elseif IsChangingMap(info) then
					-- the flight carries on once the next map has loaded
					GPSInfo.lastX = nil
				elseif GPSInfo.wasOnTaxi then
					Recorder:Stop()
					-- announce the time adjustments, if any
					if not TAXI_TIME_CORRECT_MUTE_SUMMARY and GPSInfo.timeCorrection then
						local absAdjustments = abs(GPSInfo.timeCorrection.adjustments)
						if absAdjustments > TAXI_TIME_CORRECT_IGNORE then
							DEFAULT_CHAT_FRAME:AddMessage("Your trip was |cffFFFFFF" .. absAdjustments .. " seconds|r " .. (GPSInfo.timeCorrection.adjustments < 0 and "longer" or "shorter") .. " than indicated.", 1, 1, 0)
						end
					end
					Timer:Stop()
					if Ticker then
						Ticker:Cancel()
						Ticker = nil
					end
					table.wipe(GPSInfo)
					GPSInfo = nil
					PlaySound(34089, "Master", true)
					FlashClientIcon()
				end
			end)
		end

	end

	---@class State
	local State do

		---@class State
		---@field public areaID? number
		---@field public from? TaxiNodeInfo
		---@field public to? TaxiNodeInfo
		---@field public nodes TaxiNodeInfo[]
		---@field public gps? FunctionContainer

		---@class TaxiButton : Button
		---@field public taxiNodeData TaxiNodeInfo

		State = { nodes = {} }

		---@param button TaxiButton
		function State:UpdateButton(button)
			self:Update()
			if button.taxiNodeData then
				self.to = self.nodes[button.taxiNodeData.slotIndex]
			else
				self.to = self.nodes[button:GetID()]
			end
			if self.to and self.to.state == Enum.FlightPathState.Unreachable then
				self.to = nil
			end
		end

		---@param button TaxiButton
		function State:ButtonTooltip(button)
			local info = self:GetFlightInfo()
			if not info then
				return
			end
			if SHOW_EXTRA_DEBUG_INFO then
				GameTooltip:AddLine(" ")
				for i = 1, #info.nodes do
					local node = info.nodes[i]
					GameTooltip:AddLine(format("%d. %s", i, node.name), 0.8, 0.8, 0.8, false)
				end
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(format("Number of nodes: %d", #info.nodes), 0.8, 0.8, 0.8, false)
				GameTooltip:AddLine(format("Number of points: %d", #info.points), 0.8, 0.8, 0.8, false)
				GameTooltip:AddLine(format("Speed: ~ %.1f", info.speed), 0.8, 0.8, 0.8, false)
				GameTooltip:AddLine(format("Distance: ~ %.1f yards", info.distance), 0.8, 0.8, 0.8, false)
				if info.delay > 0 then
					GameTooltip:AddLine(format("Stops: %d seconds %s", info.delay, info.delayIncluded and "" or "(not included)"), 0.8, 0.8, 0.8, false)
				end
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(format("~ %s flight time", GetTimeStringFromSeconds(info.duration, false, true)), 1, 1, 1, false)
			GameTooltip:Show()
		end

		function State:PlotCourse()
			local info = self:GetFlightInfo()
			if not info then
				return
			end
			GPS:Start(self, info)
		end

		---@return FlightInfo?
		function State:GetFlightInfo()
			return GetFlightInfo(self.nodes, self.from, self.to, self.areaID)
		end

		function State:IsValidState()
			return not not (self.areaID and self.areaID > 0 and self.from and next(self.nodes))
		end

		---@param forceUpdate? boolean
		function State:Update(forceUpdate)
			if not forceUpdate and self:IsValidState() then
				return
			end
			self.areaID, self.from, self.to = GetTaxiMapID(), nil, nil
			table.wipe(self.nodes)
			if not self.areaID then
				return
			end
			local nodes = C_TaxiMap.GetAllTaxiNodes(self.areaID)
			for i = 1, #nodes do
				local node = nodes[i]
				if node.state == Enum.FlightPathState.Current then
					self.from = node
				end
				self.nodes[node.slotIndex] = node
			end
		end

		---@param button TaxiButton
		function State:OnEnter(button)
			self:UpdateButton(button)
			self:ButtonTooltip(button)
		end

		---@param button TaxiButton
		function State:OnClick(button)
			self:UpdateButton(button)
			self:PlotCourse()
		end

	end

	---@type table<string, AddOnManifest>?
	local Frames do

		---@class AddOnName : string

		---@class AddOnManifest
		---@field public loaded? boolean
		---@field public OnLoad fun(manifest: AddOnManifest, frame: Frame)
		---@field public OnShow? fun(manifest: AddOnManifest)

		Frames = {}

		Frames.FlightMapFrame = {
			OnLoad = function(manifest, frame)
				frame:HookScript("OnShow", function() State:Update(true) end)
				hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", function(...) State:OnEnter(...) end)
				hooksecurefunc(FlightMap_FlightPointPinMixin, "OnClick", function(...) State:OnClick(...) end)
			end,
		}

		Frames.TaxiFrame = {
			OnLoad = function(manifest, frame)
				frame:HookScript("OnShow", function() State:Update(true) if manifest.OnShow then manifest:OnShow() end end)
			end,
			OnShow = function(manifest)
				for i = 1, NumTaxiNodes(), 1 do
					local button = _G["TaxiButton" .. i] ---@type TaxiButton
					if button and not manifest[button] then
						manifest[button] = true
						button:HookScript("OnEnter", function(...) State:OnEnter(...) end)
						button:HookScript("OnClick", function(...) State:OnClick(...) end)
					end
				end
			end,
		}

	end

	---@class AddOnFrame : Frame
	local AddOn do

		---@param self AddOnFrame
		---@param event WowEvent
		local function OnEvent(self, event)

			local numLoaded, numTotal = 0, 0

			for name, manifest in pairs(Frames) do
				local frame = _G[name] ---@type Frame?

				if frame then
					if not manifest.loaded then
						manifest.loaded = true
						manifest:OnLoad(frame)
					end

					numLoaded = numLoaded + 1
				end

				numTotal = numTotal + 1
			end

			if numLoaded == numTotal then
				self:UnregisterEvent(event)
			end

		end

		AddOn = CreateFrame("Frame") ---@class AddOnFrame
		AddOn:SetScript("OnEvent", OnEvent)
		AddOn:RegisterEvent("ADDON_LOADED")

	end

	-- TaxiTimerAPI
	do

		---@class TaxiTimerAPI
		_G.TaxiTimerAPI = {}

		---@param slotIndex number
		---@return TaxiNodeInfo?
		function TaxiTimerAPI.GetNodeFromSlotIndex(slotIndex)
			if type(slotIndex) ~= "number" then
				return
			end
			return State.nodes[slotIndex]
		end

		---@param toSlotIndex number
		---@param fromSlotIndex? number Only if you wish to check the travel time from another starting node.
		---@param areaID? number Only if you know you wish to override calculations with another areaID than the current TaxiMap provided one.
		---@param forceUpdateState? boolean Only if you know the state is stale, otherwise the addon refreshes it as the TaxiMap opens.
		---@return FlightInfo?
		function TaxiTimerAPI.GetFlightInfo(toSlotIndex, fromSlotIndex, areaID, forceUpdateState)
			State:Update(forceUpdateState)
			local from = fromSlotIndex and TaxiTimerAPI.GetNodeFromSlotIndex(fromSlotIndex) or State.from
			if not from then
				return
			end
			local to = TaxiTimerAPI.GetNodeFromSlotIndex(toSlotIndex)
			if not to then
				return
			end
			return GetFlightInfo(State.nodes, from, to, areaID or State.areaID)
		end

		---@param info? FlightInfo
		---@param dropZeroHours? boolean
		---@return string?
		function TaxiTimerAPI.GetFlightTime(info, dropZeroHours)
			if type(info) ~= "table" then
				return
			end
			local duration = info.duration
			local distance = info.distance
			local speed = info.speed
			if type(duration) ~= "number" then
				if type(distance) ~= "number" or type(speed) ~= "number" or speed <= 0 then
					return
				end
				duration = distance / speed
			end
			if duration ~= duration or duration < 0 or duration == math.huge then
				return
			end
			if dropZeroHours == nil then
				dropZeroHours = true
			end
			return GetTimeStringFromSeconds(duration, false, dropZeroHours)
		end

	end

end
