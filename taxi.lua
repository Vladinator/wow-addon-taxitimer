---@alias TaxiFlavor "mainline"|"forever"|"vanilla"|"classic"

---@class TaxiAreaRamp
---@field public takeoff number[] The speeds flown from the first points of the flight, one per point.
---@field public landing number[] The speeds flown from the last points before the destination, one per point, the last being the point before the destination.

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

---@class TaxiRouteNode A taxi node of a route, the nodes the game gives us have more than this.
---@field public nodeID number
---@field public name? string

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

local CatmulDistance = ns.CatmulDistance
local TAXIPATH = ns.TAXIPATH
local TAXIPATHNODE = ns.TAXIPATHNODE
local TaxiPath = ns.taxipath
local TaxiPathNode = ns.taxipathnode

--
-- Taxi
--

-- The speeds that come with the `sim_` file of the game are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
local TAXI_SPEED_SCALE = (40 + 1/3) / 40

-- The speed of the taxi maps the `sim_` file of the game does not have another speed for.
local TAXI_SPEED_FALLBACK = 30+1/3

--- Returns the speed the taxi map is flown at.
---@param areaID? number
---@return number
local function Speed(areaID)
	local areaSpeeds = ns.AREA_SPEEDS
	local speed = areaID and areaSpeeds and areaSpeeds[areaID]

	if speed then
		return speed * TAXI_SPEED_SCALE
	end

	return TAXI_SPEED_FALLBACK
end

local TAXI_PATH_NODE_FLAG_TELEPORT = 0x1 -- the flight continues at the next point without flying the distance between
local TAXI_PATH_NODE_FLAG_STOP = 0x2 -- the flight waits at this point for the amount of seconds in the delay field

--- Checks if the single bit `flag` is set in `flags`, without bit operations that not all versions of Lua have.
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

---@class TaxiPathSegment
---@field public points TaxiPathNode[]
---@field public distance? number The yards flown.
---@field public distance2D? number The yards flown as seen from above.
---@field public speed? number The average speed in yards per second.
---@field public intervals? number[] The yards flown between each point of the segment and the next.

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

local MAX_BRIDGE_HOPS = 4 -- paths a trip between two taxi nodes can be made of when the game does not tell us the taxi nodes in between
local bridges = {} ---@type table<number, table<number, number[]|false>> `[from][to] = taxi nodes` of the trip from one taxi node to the other, including both
local neighbours = {} ---@type table<number, number[]> The taxi nodes there is a path to from a taxi node, in rising order.

---@param nodeId number
---@return number[]
local function GetNeighbours(nodeId)
	local list = neighbours[nodeId]

	if not list then
		list = {}

		for toId in pairs(pathLookup[nodeId] or {}) do
			list[#list + 1] = toId
		end

		table.sort(list) -- the same trip in every version of Lua
		neighbours[nodeId] = list
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
			local list = GetNeighbours(current)

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

---@param node TaxiPathNode
local function IsTeleport(node)
	return HasFlag(node.flags, TAXI_PATH_NODE_FLAG_TELEPORT)
end

---@param node TaxiPathNode
local function IsStop(node)
	return node.delay > 0 and HasFlag(node.flags, TAXI_PATH_NODE_FLAG_STOP)
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
---@param nodeIds number[] The taxi node each path ends at, which is where the next path begins.
---@param fromIds number[] The taxi node each path begins at.
---@return TaxiPathNode[] points
local function JoinTaxiPaths(paths, nodeIds, fromIds)
	local points = {} ---@type TaxiPathNode[]
	local numPoints = 0
	local numPaths = #paths
	local firstFlown = {} ---@type table<number, number> `[pathIndex] = index` of the first point of the path that is flown, if not all of it is
	local lastFlown = {} ---@type table<number, number> `[pathIndex] = index` of the last point of the path that is flown, if not all of it is

	local exceptions = ns.RETRACE_EXCEPTIONS

	for pathIndex = 1, ns.SKIP_RETRACED and numPaths - 1 or 0 do
		-- the game flies into some taxi nodes and back out whole, however much the two paths run alongside each other
		local last, first
		if not (exceptions and exceptions[nodeIds[pathIndex]]) then
			last, first = GetRetrace(paths[pathIndex], paths[pathIndex + 1])
		end

		if last and first then
			lastFlown[pathIndex] = last
			firstFlown[pathIndex + 1] = first
		end
	end

	-- the joins that were seen to be flown another way than the rules above give
	local nodeJoins = ns.NODE_JOINS

	for pathIndex = 1, nodeJoins and numPaths - 1 or 0 do
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

---@param nodes TaxiRouteNode[]
---@return TaxiPathNode[] points, TaxiPathSegment[] segments, number delay
local function GetPointsFromNodes(nodes)
	local paths = {} ---@type TaxiPathNode[][]
	local nodeIds = {} ---@type number[]
	local fromIds = {} ---@type number[]

	for i = 2, #nodes do
		local from, to = nodes[i - 1], nodes[i]
		local path = GetTaxiPath(from.nodeID, to.nodeID)

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
	end

	local points = JoinTaxiPaths(paths, nodeIds, fromIds)
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
	local pathSpeeds = ns.PATH_SPEEDS
	local speeds = pathSpeeds and pathSpeeds[point.pathId]

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
local function GetPointSpeeds(points, areaID)
	local speeds = {} ---@type (number|false)[]
	local numPoints = #points
	local areaRamps = ns.AREA_RAMPS
	local ramp = areaID and areaRamps and areaRamps[areaID]
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
local function GetSpacingSpeed(areaID, yards)
	local areaSpacing = ns.AREA_SPACING
	local spacing = areaID and areaSpacing and areaSpacing[areaID]

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
-- Flight
--

---@class FlightStep
---@field public distance number The yards flown between a point and the next.
---@field public speed number The speed in yards per second it is flown at.
---@field public distanceLeft number The yards left of the flight after it.
---@field public durationLeft number The seconds left of the flight after it.

---@class FlightGeometry The points a flight goes through and how far it is between them, which does not depend on how fast it is flown.
---@field public nodes TaxiRouteNode[]
---@field public points TaxiPathNode[]
---@field public segments TaxiPathSegment[]
---@field public delay number The seconds the paths say the flight waits at stops along the way.
---@field public maps table<number, boolean> The maps the points are on.
---@field public distance number The yards flown.
---@field public distance2D number The yards flown as seen from above (without climbing and descending).

---@class FlightInfo
---@field public distance number The yards flown.
---@field public distance2D number The yards flown as seen from above (without climbing and descending).
---@field public speed number The average speed in yards per second (`distance / speed` is the seconds spent flying).
---@field public duration number The estimated seconds the flight takes.
---@field public delay number The seconds the paths say the flight waits at stops along the way.
---@field public delayIncluded boolean If the `delay` is part of the `duration`.
---@field public nodes TaxiRouteNode[]
---@field public points TaxiPathNode[]
---@field public segments TaxiPathSegment[]
---@field public steps FlightStep[] The stretches between the points in the order they are flown.
---@field public maps table<number, boolean> The maps the points are on.
---@field public dynamicSpeed boolean If the speed changes during the flight (the speed we fly at then says nothing about the rest of the flight).
---@field public areaSpeed number The speed the stretches without a speed of their own are flown at, which is the speed of the taxi map or the speed of the taxi node the flight starts at.
---@field public donotadjustarrivaltime? boolean

local INCLUDE_STOP_DELAYS = false -- if the seconds waiting at stops along the paths are added to the flight time (not confirmed that flights wait at these, so it's shown in the debug tooltip until it is)

--- Returns the points a flight goes through and how far it is between them.
---@param nodes TaxiRouteNode[] The taxi nodes of the route in the order they are flown.
---@return FlightGeometry
local function GetFlightGeometry(nodes)
	local points, segments, delay = GetPointsFromNodes(nodes)
	local maps = {} ---@type table<number, boolean>
	local distance = 0
	local distance2D = 0

	for i = 1, #points do
		maps[points[i].map] = true
	end

	for i = 1, #segments do
		local segment = segments[i]
		local segmentDistance, intervals = CatmulDistance(segment.points)
		local segmentDistance2D = CatmulDistance(segment.points, true)
		segment.distance, segment.distance2D, segment.intervals = segmentDistance, segmentDistance2D, intervals
		distance = distance + segmentDistance
		distance2D = distance2D + segmentDistance2D
	end

	return {
		nodes = nodes,
		points = points,
		segments = segments,
		delay = delay,
		maps = maps,
		distance = distance,
		distance2D = distance2D,
	}
end

--- Returns what the flight is estimated to be like at the speeds the game flies the taxi map at.
---@param geometry FlightGeometry
---@param areaID? number
---@return FlightInfo?
local function GetFlightInfoFromGeometry(geometry, areaID)
	local areaSpeed = Speed(areaID)
	local speeds, isDynamic = GetPointSpeeds(geometry.points, areaID)

	-- some taxi nodes have a mount that flies faster or slower than the others of the taxi map, the whole flight is flown on the mount of the node it starts at
	local nodeSpeeds = ns.NODE_SPEEDS
	local firstNode = geometry.nodes[1]
	local nodeSpeed = firstNode and nodeSpeeds and nodeSpeeds[firstNode.nodeID]

	if nodeSpeed then
		areaSpeed = nodeSpeed * TAXI_SPEED_SCALE
		isDynamic = true -- the speed of the taxi map says nothing about the speed we fly at
	end

	local segments = {} ---@type TaxiPathSegment[]
	local steps = {} ---@type FlightStep[]
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
			else
				speed = areaSpeed
			end

			numSteps = numSteps + 1
			steps[numSteps] = { distance = intervals[j], speed = speed, distanceLeft = 0, durationLeft = 0 }
			segmentDuration = segmentDuration + intervals[j] / speed
		end

		numPoints = numPoints + #segment.points
		segments[i] = {
			points = segment.points,
			intervals = intervals,
			distance = segment.distance,
			distance2D = segment.distance2D,
			speed = segmentDuration > 0 and (segment.distance or 0) / segmentDuration or areaSpeed,
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
		local fixedTime = ns.AREA_FIXED_TIME

		---@type FlightInfo
		local info = {
			distance = geometry.distance,
			distance2D = geometry.distance2D,
			speed = geometry.distance / duration,
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
		}

		if INCLUDE_STOP_DELAYS then
			info.duration = info.duration + geometry.delay
		end

		info.donotadjustarrivaltime = not not (areaID and fixedTime and fixedTime[areaID])

		return info
	end
end

--- Returns what the flight along the taxi nodes is estimated to be like.
---@param nodes TaxiRouteNode[] The taxi nodes of the route in the order they are flown.
---@param areaID? number
---@return FlightInfo?
local function GetFlightInfoFromNodes(nodes, areaID)
	return GetFlightInfoFromGeometry(GetFlightGeometry(nodes), areaID)
end

-- Returns the seconds left of the flight when the given yards are left of it, going by the speed of each stretch.
---@param info FlightInfo
---@param distance number
---@return number seconds
local function GetFlightTimeLeft(info, distance)
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
-- Exports
--

-- The speeds that come with the `sim_` file of the game are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
ns.TAXI_SPEED_SCALE = TAXI_SPEED_SCALE

-- The speed of the taxi maps the `sim_` file of the game does not have another speed for.
ns.TAXI_SPEED_FALLBACK = TAXI_SPEED_FALLBACK

ns.Speed = Speed
ns.GetPointsFromNodes = GetPointsFromNodes
ns.GetFlightGeometry = GetFlightGeometry
ns.GetFlightInfoFromGeometry = GetFlightInfoFromGeometry
ns.GetFlightInfoFromNodes = GetFlightInfoFromNodes
ns.GetFlightTimeLeft = GetFlightTimeLeft
