local MAJOR, MINOR = "TaxiTimerLib-1.0", 1

---@class TaxiTimerLib-1.0
local lib, oldMinor = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Upgrade the library.
if oldMinor then
	lib.DB = nil
	lib.Sim = nil
	lib.GameAPI = nil
end

---@alias TaxiTimerLib-1.0_GameFlavor "mainline"|"forever"|"vanilla"|"classic"

---@class TaxiTimerLib-1.0_TaxiNodesStruct

---@class TaxiTimerLib-1.0_TaxiPathStruct
---@field public ID 1
---@field public FROMTAXINODE 2
---@field public TOTAXINODE 3

---@class TaxiTimerLib-1.0_TaxiPathNodeStruct
---@field public LOC_0 1
---@field public LOC_1 2
---@field public LOC_2 3
---@field public ID 4
---@field public PATHID 5
---@field public CONTINENTID 6
---@field public FLAGS 7
---@field public DELAY 8

-- A row of `lib.DB.taxipath` where the columns are indexed using `lib.DB.TAXIPATH`.
---@alias TaxiTimerLib-1.0_TaxiPathRow { [1]: number, [2]: number, [3]: number }

-- The rows of `lib.DB.taxipath` split up into chunks.
---@alias TaxiTimerLib-1.0_TaxiPathRowChunks table<number, TaxiTimerLib-1.0_TaxiPathRow[]>

-- A row of `lib.DB.taxipathnode` where the columns are indexed using `lib.DB.TAXIPATHNODE`.
---@alias TaxiTimerLib-1.0_TaxiPathNodeRow { [1]: number, [2]: number, [3]: number, [4]: number, [5]: number, [6]: number, [7]: number, [8]: number }

-- The rows of `lib.DB.taxipathnode` split up into chunks, sorted by path and in flight order within each path.
---@alias TaxiTimerLib-1.0_TaxiPathNodeRowChunks table<number, TaxiTimerLib-1.0_TaxiPathNodeRow[]>

---@class TaxiTimerLib-1.0_DB
---@field public TAXINODES TaxiTimerLib-1.0_TaxiNodesStruct
---@field public TAXIPATH TaxiTimerLib-1.0_TaxiPathStruct
---@field public TAXIPATHNODE TaxiTimerLib-1.0_TaxiPathNodeStruct
---@field public taxipath TaxiTimerLib-1.0_TaxiPathRowChunks
---@field public taxipathnode TaxiTimerLib-1.0_TaxiPathNodeRowChunks

---@class TaxiTimerLib-1.0_Sim

---@class TaxiTimerLib-1.0_TaxiAreaRamp
---@field public takeoff number[] The speeds flown from the first points of the flight, one per point.
---@field public landing number[] The speeds flown from the last points before the destination, one per point, the last being the point before the destination.

---@class TaxiTimerLib-1.0_Point
---@field x number
---@field y number
---@field z number

-- A point of a taxi path, made from a row of `lib.DB.taxipathnode`.
---@class TaxiTimerLib-1.0_TaxiPathNode : TaxiTimerLib-1.0_Point
---@field public pathId number The path id.
---@field public index number The node index in the path.
---@field public id number The node id.
---@field public map number The map the point is on.
---@field public flags number
---@field public delay number The seconds the flight waits at the point if it is flagged as a stop.

-- A taxi node of a route, which is all the library needs to know of it (the taxi node ids of the route).
-- It is often `TaxiNodeInfo` type if you inspect the table (since it also contains what we need), but we can't guarantee that, especially when running the lib outside of the game.
---@alias TaxiTimerLib-1.0_TaxiRouteNode { nodeID: number, name?: string }

--
-- MARK: Internals
--

-- The currently loaded database.
lib.DB = lib.DB or nil ---@type TaxiTimerLib-1.0_DB

-- The currently loaded simulation.
lib.Sim = lib.Sim or nil ---@type TaxiTimerLib-1.0_Sim

-- The currently loaded Game API.
lib.GameAPI = lib.GameAPI or nil ---@type TaxiTimerLib-1.0_GameAPI

---@deprecated For internal use only. This loads and updates lib references to the currently loaded database.
---@param db TaxiTimerLib-1.0_DB
---@param incomingMinor number The `MINOR` of the files the database is from, the database is left out if it is not the version of this library.
function lib.SetDatabase(db, incomingMinor)
	assert(type(db) == "table" and type(db.TAXINODES) == "table" and type(db.TAXIPATH) == "table" and type(db.TAXIPATHNODE) == "table" and type(db.taxipath) == "table" and type(db.taxipathnode) == "table", 'TaxiTimerLib-1.0 "SetDatabase" expected a database table.')
	assert(type(incomingMinor) == "number", 'TaxiTimerLib-1.0 "SetDatabase" expected the "MINOR" of the files as the second argument.')
	if incomingMinor ~= MINOR then return end
	lib.DB = db
end

---@deprecated For internal use only. This loads and updates lib references to the currently loaded simulation.
---@param sim TaxiTimerLib-1.0_Sim
---@param incomingMinor number The `MINOR` of the files the simulation is from, the simulation is left out if it is not the version of this library.
function lib.SetSimulation(sim, incomingMinor)
	assert(type(sim) == "table" and type(sim.FLAVOR) == "string", 'TaxiTimerLib-1.0 "SetSimulation" expected a simulation table.')
	assert(type(incomingMinor) == "number", 'TaxiTimerLib-1.0 "SetSimulation" expected the "MINOR" of the files as the second argument.')
	if incomingMinor ~= MINOR then return end
	lib.Sim = sim
end

---@deprecated For internal use only. This loads and updates lib references to the currently loaded Game API.
---@param gameAPI TaxiTimerLib-1.0_GameAPI
---@param incomingMinor number The `MINOR` of the files the Game API is from, the Game API is left out if it is not the version of this library.
function lib.SetGameAPI(gameAPI, incomingMinor)
	assert(type(gameAPI) == "table", 'TaxiTimerLib-1.0 "SetGameAPI" expected a table with the game functions.')
	assert(type(incomingMinor) == "number", 'TaxiTimerLib-1.0 "SetGameAPI" expected the "MINOR" of the files as the second argument.')
	if incomingMinor ~= MINOR then return end
	lib.GameAPI = gameAPI
end

--
-- MARK: Catmull–Rom
--

---@param base number
---@param exponent number
local function pow(base, exponent)
	return base ^ exponent
end

local C_AMOUNT_OF_POINTS = 10
local C_ALPHA = 0.5

---@param t number
---@param p0 TaxiTimerLib-1.0_Point
---@param p1 TaxiTimerLib-1.0_Point
local function GetT(t, p0, p1)
	local a = pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2) + pow(p1.z - p0.z, 2)
	local b = pow(a, 0.5)
	local c = pow(b, C_ALPHA)
	return t + c
end

---@param p0 TaxiTimerLib-1.0_Point
---@param p1 TaxiTimerLib-1.0_Point
local function IsSamePoint(p0, p1)
	return p0.x == p1.x and p0.y == p1.y and p0.z == p1.z
end

-- Returns the point mirrored across `p1` from `p2`, used as the missing neighbor at either end of a path.
---@param p1 TaxiTimerLib-1.0_Point
---@param p2 TaxiTimerLib-1.0_Point
---@return TaxiTimerLib-1.0_Point
local function GetMirroredPoint(p1, p2)
	return { x = 2 * p1.x - p2.x, y = 2 * p1.y - p2.y, z = 2 * p1.z - p2.z }
end

-- Returns the points on the curve from `p1` up to (not including) `p2`. The points `p0` and `p3` are the neighbors that shape the curve.
---@param p0 TaxiTimerLib-1.0_Point
---@param p1 TaxiTimerLib-1.0_Point
---@param p2 TaxiTimerLib-1.0_Point
---@param p3 TaxiTimerLib-1.0_Point
---@return TaxiTimerLib-1.0_Point[]? points, number count
local function GetCatmullPoints(p0, p1, p2, p3)
	local t0 = 0
	local t1 = GetT(t0, p0, p1)
	local t2 = GetT(t1, p1, p2)
	local t3 = GetT(t2, p2, p3)

	-- two neighbors sharing the same position would divide by zero below
	if t1 == t0 or t2 == t1 or t3 == t2 then
		return nil, 0
	end

	local numNewPoints = 0
	local newPoints = {} ---@type TaxiTimerLib-1.0_Point[]

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

---@param p0 TaxiTimerLib-1.0_Point
---@param p1 TaxiTimerLib-1.0_Point
---@return number yards
local function GetDistance(p0, p1)
	return pow(pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2) + pow(p1.z - p0.z, 2), 0.5)
end

---@param path TaxiTimerLib-1.0_Point[]
---@param ignoreHeight? boolean `true` to measure the distance as seen from above (the height of the points is ignored)
---@return number yards, number[] intervals The yards flown between each point and the next, `intervals[i]` is from `path[i]` to `path[i + 1]`.
function lib.CatmullDistance(path, ignoreHeight)
	local intervals = {} ---@type number[]
	local numPoints = 0
	local points = {} ---@type TaxiTimerLib-1.0_Point[]
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
		local newPoints, numNewPoints = GetCatmullPoints(p0, p1, p2, p3)
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

-- Returns the points of the curve through `path`, and where each point of the path is among them.
-- A point sharing the position of the point before it is where that point is.
---@param path TaxiTimerLib-1.0_Point[]
---@param ignoreHeight? boolean `true` to leave out the height of the points
---@return TaxiTimerLib-1.0_Point[] curve
---@return number[] starts `starts[i]` is the index in `curve` of `path[i]`. What is flown from `path[i]` to `path[i + 1]` are the points from `starts[i]` up to `starts[i + 1]`.
function lib.CatmullPath(path, ignoreHeight)
	local curve = {} ---@type TaxiTimerLib-1.0_Point[]
	local starts = {} ---@type number[]
	local numCurve = 0
	local numPoints = 0
	local points = {} ---@type TaxiTimerLib-1.0_Point[]
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
		local newPoints, numNewPoints = GetCatmullPoints(p0, p1, p2, p3)

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
-- MARK: Flight pathing
--

-- The speeds that come with the `sim_` file of the game are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
local TAXI_SPEED_SCALE = (40 + 1/3) / 40

-- The speeds that come with the `sim_` file of the game are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
lib.TAXI_SPEED_SCALE = TAXI_SPEED_SCALE

-- The speed of the taxi maps the `sim_` file of the game does not have another speed for.
local TAXI_SPEED_FALLBACK = 30+1/3

-- The speed of the taxi maps the `sim_` file of the game does not have another speed for.
lib.TAXI_SPEED_FALLBACK = TAXI_SPEED_FALLBACK

-- Returns the speed the taxi map is flown at.
---@param areaID? number
---@return number speed
function lib.Speed(areaID)
	local speed = areaID and lib.Sim.AREA_SPEEDS[areaID]

	if speed then
		return speed * TAXI_SPEED_SCALE
	end

	return TAXI_SPEED_FALLBACK
end

local TAXI_PATH_NODE_FLAG_TELEPORT = 0x1 -- the flight continues at the next point without flying the distance between
local TAXI_PATH_NODE_FLAG_STOP = 0x2 -- the flight waits at this point for the amount of seconds in the delay field

-- Checks if the single bit `flag` is set in `flags`, without bit operations that not all versions of Lua have.
---@param flags number
---@param flag number
local function HasFlag(flags, flag)
	return flags % (flag * 2) >= flag
end

local SKIP_POINT_DISTANCE = 40 -- yards (seen from above) around the edges of a path where its points are skipped as we fly past a taxi node without landing
local SKIP_POINT_DISTANCE_SQ = SKIP_POINT_DISTANCE * SKIP_POINT_DISTANCE

local RETRACE_DISTANCE = 100 -- yards (height included) between the points of the path arriving at a taxi node and the path leaving it for the two to run alongside each other
local RETRACE_DISTANCE_SQ = RETRACE_DISTANCE * RETRACE_DISTANCE
local RETRACE_REACH = 250 -- yards (seen from above) the stretch must reach away from the taxi node, on the path arriving and the path leaving together
local RETRACE_POINTS = 4 -- points of each of the two paths that must run alongside the other before that stretch is skipped, fewer are left to the skip distance above

local hasLookup = false
local pathLookup = {} ---@type table<number, table<number, number>> `[from][to] = pathId`
local pathRows = {} ---@type table<number, TaxiTimerLib-1.0_TaxiPathNodeRow[]> `[pathId] = rows` in flight order
local pathNodes = {} ---@type table<number, TaxiTimerLib-1.0_TaxiPathNode[]|false>

-- the db is only walked once, the first time we need a path
local function BuildLookup()
	hasLookup = true

	for i = 1, #lib.DB.taxipath do
		local taxiPathChunk = lib.DB.taxipath[i]

		for j = 1, #taxiPathChunk do
			local taxiPath = taxiPathChunk[j]
			local fromId = taxiPath[lib.DB.TAXIPATH.FROMTAXINODE]
			local toId = taxiPath[lib.DB.TAXIPATH.TOTAXINODE]
			local destinations = pathLookup[fromId]

			if not destinations then
				destinations = {}
				pathLookup[fromId] = destinations
			end

			-- the first path between two nodes is the one used
			if not destinations[toId] then
				destinations[toId] = taxiPath[lib.DB.TAXIPATH.ID]
			end
		end
	end

	for i = 1, #lib.DB.taxipathnode do
		local taxiPathChunk = lib.DB.taxipathnode[i]

		for j = 1, #taxiPathChunk do
			local taxiPathNode = taxiPathChunk[j]
			local pathId = taxiPathNode[lib.DB.TAXIPATHNODE.PATHID]
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
---@return TaxiTimerLib-1.0_TaxiPathNode[]? nodes
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
					x = row[lib.DB.TAXIPATHNODE.LOC_0],
					y = row[lib.DB.TAXIPATHNODE.LOC_1],
					z = row[lib.DB.TAXIPATHNODE.LOC_2],
					id = row[lib.DB.TAXIPATHNODE.ID],
					pathId = pathId,
					index = i,
					map = row[lib.DB.TAXIPATHNODE.CONTINENTID],
					flags = row[lib.DB.TAXIPATHNODE.FLAGS],
					delay = row[lib.DB.TAXIPATHNODE.DELAY],
				}
			end
		end

		pathNodes[pathId] = nodes
	end

	return nodes or nil
end

---@param from number
---@param to number
---@return TaxiTimerLib-1.0_TaxiPathNode[]? nodes
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

local MAX_BRIDGE_HOPS = 4 -- paths a trip between two taxi nodes can be made of when the game does not tell us the taxi nodes in between
local bridges = {} ---@type table<number, table<number, number[]|false>> `[from][to] = taxi nodes` of the trip from one taxi node to the other, including both
local neighbors = {} ---@type table<number, number[]> The taxi nodes there is a path to from a taxi node, in rising order.

---@param nodeId number
---@return number[] nodeIds
local function GetNeighbors(nodeId)
	local list = neighbors[nodeId]

	if not list then
		list = {}

		for toId in pairs(pathLookup[nodeId] or {}) do
			list[#list + 1] = toId
		end

		table.sort(list) -- the same trip in every version of Lua
		neighbors[nodeId] = list
	end

	return list
end

-- Some taxi nodes are never shown on the taxi map, they are only passed on the way (like the tunnels into Zaralek Cavern), so a trip can have taxi nodes in between that the game does not give us.
-- When there is no path between two taxi nodes, this finds the trip with the fewest paths that does it, and only if there is one such trip. Every path of it is one of the paths of the game files.
---@param from number
---@param to number
---@return number[]? nodeIds The taxi nodes of the trip in the order they are flown, `from` and `to` included.
local function GetTaxiBridge(from, to)
	if not hasLookup then
		BuildLookup()
	end

	local cached = bridges[from]

	if cached and cached[to] ~= nil then
		return cached[to] or nil
	end

	local previous = { [from] = false } ---@type table<number, number|false>
	local queue = { from }
	local depth = { [from] = 0 }
	local trips = { [from] = 1 } ---@type table<number, number> How many trips with the fewest paths lead to each taxi node.
	local head = 1

	-- breadth first, so the trip found has the fewest paths
	while head <= #queue do
		local current = queue[head]
		head = head + 1

		if depth[current] < MAX_BRIDGE_HOPS and current ~= to then
			local list = GetNeighbors(current)

			for i = 1, #list do
				local nextId = list[i]

				if depth[nextId] == nil then
					previous[nextId] = current
					depth[nextId] = depth[current] + 1
					trips[nextId] = 0
					queue[#queue + 1] = nextId
				end

				if depth[nextId] == depth[current] + 1 then
					trips[nextId] = trips[nextId] + trips[current]
				end
			end
		end
	end

	local trip = false ---@type number[]|false

	-- the trip is only used when it is the only way (with the fewest paths) between the two, otherwise we would be guessing which way the game flew
	if trips[to] == 1 then
		trip = {}

		local at = to ---@type number|false

		while at do
			table.insert(trip, 1, at)
			at = previous[at]
		end
	end

	if not cached then
		cached = {}
		bridges[from] = cached
	end

	cached[to] = trip
	return trip or nil
end

---@param node TaxiTimerLib-1.0_TaxiPathNode
local function IsTeleport(node)
	return HasFlag(node.flags, TAXI_PATH_NODE_FLAG_TELEPORT)
end

---@param node TaxiTimerLib-1.0_TaxiPathNode
local function IsStop(node)
	return node.delay > 0 and HasFlag(node.flags, TAXI_PATH_NODE_FLAG_STOP)
end

-- Checks if `node` is far enough away from `edge` to be flown when the taxi node at `edge` is passed without landing.
---@param edge TaxiTimerLib-1.0_TaxiPathNode
---@param node TaxiTimerLib-1.0_TaxiPathNode
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

-- Checks if `node` is close to any of the points of the path `nodes`, height included.
---@param node TaxiTimerLib-1.0_TaxiPathNode
---@param nodes TaxiTimerLib-1.0_TaxiPathNode[]
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

-- Returns the last point flown of the path arriving at a taxi node and the first point flown of the path leaving it, if the two paths run alongside each other at the node.
-- Where the way out of a taxi node goes back along the way in (like Ironforge between Kharanos and Menethil Harbor) the game does not fly in and back out, it flies from where the paths come together to where they part again.
---@param arriving TaxiTimerLib-1.0_TaxiPathNode[]
---@param leaving TaxiTimerLib-1.0_TaxiPathNode[]
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
---@param paths TaxiTimerLib-1.0_TaxiPathNode[][]
---@param nodeIds number[] The taxi node each path ends at, which is where the next path begins.
---@param fromIds number[] The taxi node each path begins at.
---@return TaxiTimerLib-1.0_TaxiPathNode[] points
local function JoinTaxiPaths(paths, nodeIds, fromIds)
	local points = {} ---@type TaxiTimerLib-1.0_TaxiPathNode[]
	local numPoints = 0
	local numPaths = #paths
	local firstFlown = {} ---@type table<number, number> `[pathIndex] = index` of the first point of the path that is flown, if not all of it is
	local lastFlown = {} ---@type table<number, number> `[pathIndex] = index` of the last point of the path that is flown, if not all of it is

	local exceptions = lib.Sim.RETRACE_EXCEPTIONS

	for pathIndex = 1, lib.Sim.SKIP_RETRACED and numPaths - 1 or 0 do
		-- the game flies into some taxi nodes and back out whole, however much the two paths run alongside each other
		local last, first
		if not exceptions[nodeIds[pathIndex]] then
			last, first = GetRetrace(paths[pathIndex], paths[pathIndex + 1])
		end

		if last and first then
			lastFlown[pathIndex] = last
			firstFlown[pathIndex + 1] = first
		end
	end

	-- the joins that were seen to be flown another way than the rules above give
	local nodeJoins = lib.Sim.NODE_JOINS

	for pathIndex = 1, numPaths - 1 do
		local joins = nodeJoins[nodeIds[pathIndex]]
		local join = joins and joins[fromIds[pathIndex]]
		join = join and join[nodeIds[pathIndex + 1]]

		if join then
			lastFlown[pathIndex] = join[1]
			firstFlown[pathIndex + 1] = join[2]
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

---@param nodes TaxiTimerLib-1.0_TaxiRouteNode[]
---@return TaxiTimerLib-1.0_TaxiPathNode[] points
---@return TaxiTimerLib-1.0_FlightSegment[] segments
---@return number delay
---@return (number|false)[] arrivals `arrivals[i]` is the id of the last path flown to get to `nodes[i + 1]` (`false` if no path is known to it).
function lib.GetPointsFromNodes(nodes)
	local paths = {} ---@type TaxiTimerLib-1.0_TaxiPathNode[][]
	local nodeIds = {} ---@type number[]
	local fromIds = {} ---@type number[]
	local arrivals = {} ---@type (number|false)[]

	for i = 2, #nodes do
		local from, to = nodes[i - 1], nodes[i]
		local path = GetTaxiPath(from.nodeID, to.nodeID)
		local numBefore = #paths

		if path and path[1] then
			paths[#paths + 1] = path
			nodeIds[#paths] = to.nodeID
			fromIds[#paths] = from.nodeID
		elseif from.nodeID ~= to.nodeID then
			-- no path between the two, so the game flew through taxi nodes it does not show
			local trip = GetTaxiBridge(from.nodeID, to.nodeID) or {}

			for j = 2, #trip do
				local hop = GetTaxiPath(trip[j - 1], trip[j])

				if hop and hop[1] then
					paths[#paths + 1] = hop
					nodeIds[#paths] = trip[j]
					fromIds[#paths] = trip[j - 1]
				end
			end
		end

		local arrival = paths[#paths]
		arrivals[i - 1] = #paths > numBefore and arrival[1].pathId or false
	end

	local points = JoinTaxiPaths(paths, nodeIds, fromIds)
	local segments = {} ---@type TaxiTimerLib-1.0_FlightSegment[]
	local segment ---@type TaxiTimerLib-1.0_FlightSegment?
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

	return points, segments, delay, arrivals
end

-- Returns the speed a path is flown at from the given point, if the path has its own speeds.
---@param point TaxiTimerLib-1.0_TaxiPathNode
---@return number? speed
local function GetPathSpeed(point)
	local speeds = lib.Sim.PATH_SPEEDS[point.pathId]

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
---@param points TaxiTimerLib-1.0_TaxiPathNode[]
---@param areaID? number
---@return (number|false)[] speeds, boolean isDynamic `true` if the speed changes during the flight. The speed is `false` for the points that leave it to the taxi map.
local function GetPointSpeeds(points, areaID)
	local speeds = {} ---@type (number|false)[]
	local numPoints = #points
	local ramp = areaID and lib.Sim.AREA_RAMPS[areaID]
	local isDynamic = false

	for i = 1, numPoints do
		local speed = GetPathSpeed(points[i])

		-- a speed that was set carries on into the next path, the game does not change it as a path begins
		local previous = points[i - 1]

		if not speed and lib.Sim.CARRY_SPEED and previous and previous.pathId ~= points[i].pathId then
			speed = speeds[i - 1] or nil
		end

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
local function GetSpacingSpeed(areaID, yards)
	local spacing = areaID and lib.Sim.AREA_SPACING[areaID]

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

--
-- MARK: Flight information
--

-- A stretch of a flight that is flown from point to point, the flight starts a new one where it jumps (teleports and map changes).
---@class TaxiTimerLib-1.0_FlightSegment
---@field public points TaxiTimerLib-1.0_TaxiPathNode[]
---@field public distance? number The yards flown.
---@field public distance2D? number The yards flown as seen from above.
---@field public speed? number The average speed in yards per second.
---@field public intervals? number[] The yards flown between each point of the segment and the next.

---@class TaxiTimerLib-1.0_FlightStep
---@field public distance number The yards flown between a point and the next.
---@field public speed number The speed in yards per second it is flown at.
---@field public distanceLeft number The yards left of the flight after it.
---@field public durationLeft number The seconds left of the flight after it.

---@class TaxiTimerLib-1.0_FlightGeometry The points a flight goes through and how far it is between them, which does not depend on how fast it is flown.
---@field public nodes TaxiTimerLib-1.0_TaxiRouteNode[]
---@field public points TaxiTimerLib-1.0_TaxiPathNode[]
---@field public segments TaxiTimerLib-1.0_FlightSegment[]
---@field public delay number The seconds the paths say the flight waits at stops along the way.
---@field public arrivals (number|false)[] `arrivals[i]` is the id of the last path flown to get to `nodes[i + 1]`.
---@field public maps table<number, boolean> The maps the points are on.
---@field public distance number The yards flown.
---@field public distance2D number The yards flown as seen from above (without climbing and descending).

---@class TaxiTimerLib-1.0_FlightInfo
---@field public distance number The yards flown.
---@field public distance2D number The yards flown as seen from above (without climbing and descending).
---@field public speed number The average speed in yards per second (`distance / speed` is the seconds spent flying).
---@field public duration number The estimated seconds the flight takes.
---@field public delay number The seconds the paths say the flight waits at stops along the way.
---@field public delayIncluded boolean If the `delay` is part of the `duration`.
---@field public nodes TaxiTimerLib-1.0_TaxiRouteNode[]
---@field public points TaxiTimerLib-1.0_TaxiPathNode[]
---@field public segments TaxiTimerLib-1.0_FlightSegment[]
---@field public steps TaxiTimerLib-1.0_FlightStep[] The stretches between the points in the order they are flown.
---@field public maps table<number, boolean> The maps the points are on.
---@field public dynamicSpeed boolean If the speed changes during the flight (the speed we fly at then says nothing about the rest of the flight).
---@field public areaSpeed number The speed the stretches without a speed of their own are flown at, which is the speed of the taxi map or the speed of the taxi node the flight starts at (with the `speedModifier`).
---@field public speedModifier number What every speed of the flight was multiplied by (1 if nothing makes the flight path mount fly faster or slower).
---@field public arrivals (number|false)[] See `TaxiTimerLib-1.0_FlightGeometry`.
---@field public donotadjustarrivaltime? boolean

local INCLUDE_STOP_DELAYS = false -- if the seconds waiting at stops along the paths are added to the flight time (not confirmed that flights wait at these, so it's shown in the debug tooltip until it is)

-- Returns the points a flight goes through and how far it is between them.
---@param nodes TaxiTimerLib-1.0_TaxiRouteNode[] The taxi nodes of the route in the order they are flown.
---@return TaxiTimerLib-1.0_FlightGeometry flightGeometry
function lib.GetFlightGeometry(nodes)
	local points, segments, delay, arrivals = lib.GetPointsFromNodes(nodes)
	local maps = {} ---@type table<number, boolean>
	local distance = 0
	local distance2D = 0

	for i = 1, #points do
		maps[points[i].map] = true
	end

	for i = 1, #segments do
		local segment = segments[i]
		local segmentDistance, intervals = lib.CatmullDistance(segment.points)
		local segmentDistance2D = lib.CatmullDistance(segment.points, true)
		segment.distance, segment.distance2D, segment.intervals = segmentDistance, segmentDistance2D, intervals
		distance = distance + segmentDistance
		distance2D = distance2D + segmentDistance2D
	end

	return {
		nodes = nodes,
		points = points,
		segments = segments,
		delay = delay,
		arrivals = arrivals,
		maps = maps,
		distance = distance,
		distance2D = distance2D,
	}
end

-- Returns what the flight is estimated to be like at the speeds the game flies the taxi map at.
---@param geometry TaxiTimerLib-1.0_FlightGeometry
---@param areaID? number
---@param speedModifier? number What the speeds are multiplied by for something that makes the flight path mount fly faster or slower (1.2 for 20% faster), the game side knows what that is.
---@return TaxiTimerLib-1.0_FlightInfo? flightInfo
function lib.GetFlightInfoFromGeometry(geometry, areaID, speedModifier)
	local modifier = speedModifier and speedModifier > 0 and speedModifier or 1
	local areaSpeed = lib.Speed(areaID)
	local speeds, isDynamic = GetPointSpeeds(geometry.points, areaID)

	-- some taxi nodes have a mount that flies faster or slower than the others of the taxi map, the whole flight is flown on the mount of the node it starts at
	local firstNode = geometry.nodes[1]
	local nodeSpeed = firstNode and lib.Sim.NODE_SPEEDS[firstNode.nodeID]

	if nodeSpeed then
		areaSpeed = nodeSpeed * TAXI_SPEED_SCALE
		isDynamic = true -- the speed of the taxi map says nothing about the speed we fly at
	end

	areaSpeed = areaSpeed * modifier

	-- the taxi maps where what is flown is longer or shorter than the points say (instances, which give no positions to find that out from)
	local scale = areaID and lib.Sim.AREA_DISTANCE_SCALE[areaID] or 1

	local segments = {} ---@type TaxiTimerLib-1.0_FlightSegment[]
	local steps = {} ---@type TaxiTimerLib-1.0_FlightStep[]
	local numSteps = 0
	local numPoints = 0
	local duration = 0

	-- each stretch between two points is timed on its own as they do not all share the same speed
	for i = 1, #geometry.segments do
		local segment = geometry.segments[i]
		local intervals = segment.intervals or {}
		local segmentDuration = 0

		for j = 1, #intervals do
			local speed = speeds[numPoints + j] or GetSpacingSpeed(areaID, intervals[j])

			if speed then
				isDynamic = true
				speed = speed * modifier
			else
				speed = areaSpeed
			end

			numSteps = numSteps + 1
			steps[numSteps] = { distance = intervals[j] * scale, speed = speed, distanceLeft = 0, durationLeft = 0 }
			segmentDuration = segmentDuration + intervals[j] * scale / speed
		end

		numPoints = numPoints + #segment.points
		segments[i] = {
			points = segment.points,
			intervals = intervals,
			distance = segment.distance and segment.distance * scale,
			distance2D = segment.distance2D,
			speed = segmentDuration > 0 and (segment.distance or 0) * scale / segmentDuration or areaSpeed,
		}
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

	if geometry.distance > 0 and duration > 0 then
		---@type TaxiTimerLib-1.0_FlightInfo
		local info = {
			distance = geometry.distance * scale,
			distance2D = geometry.distance2D,
			speed = geometry.distance * scale / duration,
			duration = duration,
			delay = geometry.delay,
			delayIncluded = INCLUDE_STOP_DELAYS,
			nodes = geometry.nodes,
			points = geometry.points,
			segments = segments,
			steps = steps,
			maps = geometry.maps,
			dynamicSpeed = isDynamic,
			areaSpeed = areaSpeed,
			speedModifier = modifier,
			arrivals = geometry.arrivals,
		}

		if INCLUDE_STOP_DELAYS then
			info.duration = info.duration + geometry.delay
		end

		info.donotadjustarrivaltime = not not (areaID and lib.Sim.AREA_FIXED_TIME[areaID])

		return info
	end
end

-- Returns what the flight along the taxi nodes is estimated to be like.
---@param nodes TaxiTimerLib-1.0_TaxiRouteNode[] The taxi nodes of the route in the order they are flown.
---@param areaID? number
---@param speedModifier? number See `GetFlightInfoFromGeometry`.
---@return TaxiTimerLib-1.0_FlightInfo? flightInfo
function lib.GetFlightInfoFromNodes(nodes, areaID, speedModifier)
	return lib.GetFlightInfoFromGeometry(lib.GetFlightGeometry(nodes), areaID, speedModifier)
end

-- Returns the seconds left of the flight when the given yards are left of it, going by the speed of each stretch.
---@param info TaxiTimerLib-1.0_FlightInfo
---@param distance number
---@return number seconds
function lib.GetFlightTimeLeft(info, distance)
	local steps = info.steps

	for i = 1, #steps do
		local step = steps[i]

		if distance >= step.distanceLeft then
			return step.durationLeft + math.min(distance - step.distanceLeft, step.distance) / step.speed
		end
	end

	return 0
end

--
-- MARK: Flight checkpoints
--

-- Where a flight reaches a taxi node of its route.
---@class TaxiTimerLib-1.0_FlightCheckpoint
---@field public nodeID number
---@field public name? string
---@field public lands boolean If the flight lands at the taxi node (the first and last of the route), `false` where it passes the taxi node without landing.
---@field public pointIndex number The index in `info.points` of the point flown at the taxi node.
---@field public distance number The yards flown when it is reached.
---@field public time number The seconds flown when it is reached, going by the speeds of the flight.

-- Returns where the flight reaches each taxi node of its route, to show the progress of the flight.
-- The first is at 0 yards and 0 seconds, the last at `info.distance` and `info.duration`.
-- A taxi node of the route that the flight does not fly through (the game skips the points near it) is where the flight is closest to it, which is the point before it.
---@param info TaxiTimerLib-1.0_FlightInfo
---@return TaxiTimerLib-1.0_FlightCheckpoint[] checkpoints
function lib.GetFlightCheckpoints(info)
	local points, segments, steps, nodes = info.points, info.segments, info.steps, info.nodes
	local numPoints = #points

	-- the yards and seconds flown when each point is reached, there is no step between where a segment ends and the next begins
	local distances, times = {}, {} ---@type number[], number[]
	local distance, time = 0, 0
	local numPoint, numStep = 0, 0

	for i = 1, #segments do
		for j = 1, #segments[i].points do
			numPoint = numPoint + 1
			distances[numPoint], times[numPoint] = distance, time

			if j < #segments[i].points then
				numStep = numStep + 1
				local step = steps[numStep]
				distance = distance + step.distance
				time = time + step.distance / step.speed
			end
		end
	end

	-- the last point of the path that goes to each node, looking on from where the node before was
	local checkpoints = {} ---@type TaxiTimerLib-1.0_FlightCheckpoint[]
	local from = 1

	for i = 1, #nodes do
		local index = from

		if i == 1 then
			index = 1
		elseif i == #nodes then
			index = numPoints
		else
			local pathId = info.arrivals[i - 1]

			local found = false

			for j = from, numPoints do
				if points[j].pathId == pathId then
					index, found = j, true
				elseif found then
					break
				end
			end
		end

		from = index
		checkpoints[i] = {
			nodeID = nodes[i].nodeID,
			name = nodes[i].name,
			lands = i == 1 or i == #nodes,
			pointIndex = index,
			distance = distances[index] or 0,
			time = times[index] or 0,
		}
	end

	return checkpoints
end
