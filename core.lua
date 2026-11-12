local SHOW_EXTRA_DEBUG_INFO = true -- enable displaying additional node information on taxi node tooltips
local RECORD_FLIGHTS = true -- enable recording of paths to SV for later analysis

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
---@field public pathId number
---@field public id number
---@field public map number The map the point is on (`ContinentID`).
---@field public flags number
---@field public delay number The seconds the flight waits at the point if it is flagged as a stop.

---A row of `ns.taxipath` where the columns are indexed using `ns.TAXIPATH`.
---@alias TaxiPathRow { [1]: number, [2]: number, [3]: number }

---The rows of `ns.taxipath` split up into chunks.
---@alias TaxiPathStructDB table<number, TaxiPathRow[]>

---A row of `ns.taxipathnode` where the columns are indexed using `ns.TAXIPATHNODE`.
---@alias TaxiPathNodeRow { [1]: number, [2]: number, [3]: number, [4]: number, [5]: number, [6]: number, [7]: number, [8]: number }

---The rows of `ns.taxipathnode` split up into chunks, sorted by path and in flight order within each path.
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

		---Returns the point mirrored across `p1` from `p2`, used as the missing neighbor at either end of a path.
		---@param p1 Point
		---@param p2 Point
		---@return Point
		local function GetMirroredPoint(p1, p2)
			return { x = 2 * p1.x - p2.x, y = 2 * p1.y - p2.y, z = 2 * p1.z - p2.z }
		end

		---Returns the points on the curve from `p1` up to (not including) `p2`. The points `p0` and `p3` are the neighbors that shape the curve.
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

		---@param path Point[]
		---@param ignoreHeight? boolean
		---@return Point[]? path, number count
		local function GetCatmulPath(path, ignoreHeight)
			local numPoints = 0
			local points = {} ---@type Point[]

			-- a point sharing the position of the point before it adds no distance and would break the curve math
			for i = 1, #path do
				local point = path[i]

				if ignoreHeight then
					point = { x = point.x, y = point.y, z = 0 }
				end

				if numPoints == 0 or not IsSamePoint(points[numPoints], point) then
					numPoints = numPoints + 1
					points[numPoints] = point
				end
			end

			if numPoints < 2 then
				return nil, 0
			end

			local numNewPath = 0
			local newPath = {} ---@type Point[]

			for i = 1, numPoints - 1 do
				local p1 = points[i]
				local p2 = points[i + 1]
				local p0 = points[i - 1] or GetMirroredPoint(p1, p2)
				local p3 = points[i + 2] or GetMirroredPoint(p2, p1)
				local newPoints, numNewPoints = GetCatmulPoints(p0, p1, p2, p3)

				if newPoints then
					for j = 1, numNewPoints do
						numNewPath = numNewPath + 1
						newPath[numNewPath] = newPoints[j]
					end
				else
					-- without a curve the straight line to the next point is used
					numNewPath = numNewPath + 1
					newPath[numNewPath] = p1
				end
			end

			numNewPath = numNewPath + 1
			newPath[numNewPath] = points[numPoints]

			return newPath, numNewPath
		end

		---@param p0 Point
		---@param p1 Point
		---@return number yards
		local function GetDistance(p0, p1)
			return pow(pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2) + pow(p1.z - p0.z, 2), 0.5)
		end

		---@param path Point[]
		---@param ignoreHeight? boolean `true` to measure the distance as seen from above (the height of the points is ignored)
		---@return number yards
		function CatmulDistance(path, ignoreHeight)
			local distance = 0
			local newPath = GetCatmulPath(path, ignoreHeight)

			if newPath then
				for i = 2, #newPath do
					distance = distance + GetDistance(newPath[i - 1], newPath[i])
				end
			end

			return distance
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
		local TAXI_SPEED_50 = 50+7/9
		local TAXI_SPEED_55 = 55

		local fallback = setmetatable({
			[1116] = TAXI_SPEED_40, -- Draenor
			[1220] = TAXI_SPEED_40, -- Broken Isles
			[1647] = TAXI_SPEED_40, -- Shadowlands
			[2444] = TAXI_SPEED_50, -- Dragon Isles
			[2276] = TAXI_SPEED_55, -- Khaz Algar
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

	local GetPointsFromNodes do

		local TAXI_PATH_NODE_FLAG_TELEPORT = 0x1 -- the flight continues at the next point without flying the distance between
		local TAXI_PATH_NODE_FLAG_STOP = 0x2 -- the flight waits at this point for the amount of seconds in the delay field

		local SKIP_POINT_DISTANCE = 40 -- yards (seen from above) around the edges of a path where its points are skipped as we fly past a taxi node without landing
		local SKIP_POINT_DISTANCE_SQ = SKIP_POINT_DISTANCE * SKIP_POINT_DISTANCE

		local SHADOWLANDS_SPEED = Speed(1647)
		local SHADOWLANDS_WARP_SPEED = 200 -- estimation
		local SHADOWLANDS_ORIBOS_LIGHTSPEED_PADDING_DISTANCE = SHADOWLANDS_WARP_SPEED*40 -- estimation
		local SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE = SHADOWLANDS_SPEED*80 -- ?
		local SHADOWLANDS_ORIBOS_BASTION_DISTANCE = SHADOWLANDS_SPEED*75
		local SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE = SHADOWLANDS_SPEED*80 -- ?
		local SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE = SHADOWLANDS_SPEED*80 -- ?

		---@class TaxiPathOverride
		---@field public distance number The distance used for the path instead of the distance between its points.
		---@field public speed number The speed used for the path instead of the speed of the area.

		---@param distance number
		---@return TaxiPathOverride
		local function ShadowlandsOverride(distance)
			return {
				distance = distance + SHADOWLANDS_ORIBOS_LIGHTSPEED_PADDING_DISTANCE,
				speed = (SHADOWLANDS_SPEED + SHADOWLANDS_WARP_SPEED)/2,
			}
		end

		-- paths where the points do not reflect the flight at all, these are timed on their own and do not blend into the paths before and after
		---@type table<number, TaxiPathOverride>
		local PATH_OVERRIDE = {
			[7916] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE), -- Oribos > Revendreth, Pridefall Hamlet
			[7917] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE), -- Revendreth, Pridefall Hamlet > Oribos
			[8013] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_BASTION_DISTANCE), -- Oribos > Bastion, Aspirant's Rest
			[8012] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_BASTION_DISTANCE), -- Bastion, Aspirant's Rest > Oribos
			[8318] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE), -- Oribos > Maldraxxus, Theater of Pain
			[8319] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE), -- Maldraxxus, Theater of Pain > Oribos
			[8431] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE), -- Oribos > Ardenweald, Tirna Vaal
			[8432] = ShadowlandsOverride(SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE), -- Ardenweald, Tirna Vaal > Oribos
		}

		---@class TaxiPathSegment
		---@field public points TaxiPathNode[]
		---@field public override? TaxiPathOverride
		---@field public distance? number The yards flown.
		---@field public distance2D? number The yards flown as seen from above.
		---@field public speed? number The speed in yards per second.

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

		---Checks if `node` is far enough away from `edge` to be flown when the taxi node at `edge` is passed without landing.
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

		---Joins the paths of a route into the points that are flown.
		---
		---When flying past a taxi node the game doesn't land, it skips the points near where the path arriving at the node ends and where the path leaving the node begins.
		---This is the same logic as `FlightPathMovementGenerator::LoadPath` in TrinityCore.
		---@param paths TaxiPathNode[][]
		---@return TaxiPathNode[] points
		local function JoinTaxiPaths(paths)
			local points = {} ---@type TaxiPathNode[]
			local numPoints = 0
			local numPaths = #paths

			for pathIndex = 1, numPaths do
				local nodes = paths[pathIndex]
				local numNodes = #nodes
				local isFirst = pathIndex == 1
				local isLast = pathIndex == numPaths
				local first = nodes[1]
				local last = nodes[numNodes]
				local hasLeftPreviousPath = false

				for i = 1, numNodes do
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

			-- the points are split up where the flight doesn't fly from one point to the next (teleports and map changes) and where a path is timed on its own
			for i = 1, #points do
				local point = points[i]
				local previous = points[i - 1]
				local override = PATH_OVERRIDE[point.pathId]

				if not segment
					or segment.override ~= override
					or (override and previous.pathId ~= point.pathId)
					or (not override and (previous.map ~= point.map or IsTeleport(previous)))
				then
					segment = { points = {}, override = override }
					segments[#segments + 1] = segment
				end

				segment.points[#segment.points + 1] = point

				if IsStop(point) then
					delay = delay + point.delay
				end
			end

			return points, segments, delay
		end

	end

	local GetFlightInfo do

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
			local areaSpeed = Speed(areaID)
			local distance = 0
			local distance2D = 0
			local duration = 0
			-- each segment is timed on its own as they do not all share the same speed
			for i = 1, #segments do
				local segment = segments[i]
				local override = segment.override
				local segmentDistance, segmentDistance2D, segmentSpeed
				if override then
					segmentDistance, segmentDistance2D, segmentSpeed = override.distance, override.distance, override.speed
				else
					segmentDistance, segmentDistance2D, segmentSpeed = CatmulDistance(segment.points), CatmulDistance(segment.points, true), areaSpeed
				end
				segment.distance, segment.distance2D, segment.speed = segmentDistance, segmentDistance2D, segmentSpeed
				distance = distance + segmentDistance
				distance2D = distance2D + segmentDistance2D
				duration = duration + segmentDistance / segmentSpeed
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
				}
				if INCLUDE_STOP_DELAYS then
					info.duration = info.duration + delay
				end
				info.donotadjustarrivaltime = not not (areaID and DO_NOT_ADJUST_FOR_MAPS[areaID])
				return info
			end
		end

	end

	ns.Speed = Speed
	ns.GetPointsFromNodes = GetPointsFromNodes
	ns.GetFlightInfo = GetFlightInfo

end

-- core.lua
do

	local Speed = ns.Speed
	local GetFlightInfo = ns.GetFlightInfo

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
		---@field public speed number Speed the segment was estimated to be flown at.
		---@field public override boolean If the distance and speed are from a path override and not from the points.

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

		---Returns the index of the point nearest to us among the points ahead of where we were last.
		---@param flight RecorderFlight
		---@param x number
		---@param y number
		---@param mapID? number
		---@return number? index
		local function GetCurrentPoint(flight, x, y, mapID)
			local points = flight.info.points
			local numPoints = #points
			local record = flight.record
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
			local index, distance = GetNearestPoint(points, first, math.min(numPoints, first + RECORD_SEARCH_AHEAD), x, y, mapID)
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
					override = segment.override ~= nil,
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

		local TAXI_MAX_SLEEP = 30 -- seconds before we give up waiting on the taxi to start (can happen if lag, or other conditions not being met as we click to fly somewhere)

		local TAXI_TIME_CORRECT = true -- if we wish to change the stopwatch time based on our movement and dynamic speed (if false, uses the original calculation and keeps the timer as-is during the flight)
		local TAXI_TIME_CORRECT_INTERVAL = 2 -- adjusts the timer X amount of times during flight to better calculate actual arrival time (some taxi paths slow down at start, or speed up eventually, this causes some seconds differences, this aims to counter that a bit)
		local TAXI_TIME_CORRECT_IGNORE = 5 -- amount of seconds we need to be wrong, before adjusting the timer

		local TAXI_TIME_CORRECT_MUTE_UPDATES = false -- mute the mid-flight updates
		local TAXI_TIME_CORRECT_MUTE_SUMMARY = false -- mute the end-of-flight summary

		local GPSInfo ---@type GPSInfo?
		local Ticker ---@type FunctionContainer?

		GPS = {}

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
					GPSInfo.speed = Speed(state.areaID, true)
					GPSInfo.x, GPSInfo.y, GPSInfo.z, GPSInfo.mapID = UnitPosition("player")
					if GPSInfo.lastSpeed then
						if GPSInfo.mapID and GPSInfo.lastMapID and GPSInfo.mapID ~= GPSInfo.lastMapID then
							GPSInfo.lastX = nil
						end
						if GPSInfo.lastX then
							GPSInfo.distance = GPSInfo.distance - math.sqrt((GPSInfo.lastX - GPSInfo.x)^2 + (GPSInfo.lastY - GPSInfo.y)^2) * travelScale
							GPSInfo.distancePercent = GPSInfo.distance / info.distance
							if GPSInfo.distance > 0 and GPSInfo.speed > 0 then
								local timeCorrection = TAXI_TIME_CORRECT
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
										gpsInfoTimeCorrection.difference = math.floor(Timer:Get() - (GPSInfo.distance / GPSInfo.speed))
										-- check if time difference is within acceptable boundaries
										if TAXI_TIME_CORRECT_IGNORE > 0 and abs(gpsInfoTimeCorrection.difference) < TAXI_TIME_CORRECT_IGNORE then
											timeCorrection = false
										elseif GPSInfo.stopwatchSet then
											gpsInfoTimeCorrection.adjustments = gpsInfoTimeCorrection.adjustments + gpsInfoTimeCorrection.difference
											-- announce the stopwatch time adjustments if significant enough to be noteworthy, and if we have more than just one interval (we then just summarize at the end)
											if not info.donotadjustarrivaltime and not TAXI_TIME_CORRECT_MUTE_UPDATES and TAXI_TIME_CORRECT_INTERVAL > 1 then
												DEFAULT_CHAT_FRAME:AddMessage("Expected arrival time adjusted by |cffFFFFFF" .. math.abs(gpsInfoTimeCorrection.difference) .. " seconds|r.", 1, 1, 0)
											end
										end
									end
								end
								-- set or override the stopwatch based on time correction mode
								if not info.donotadjustarrivaltime then
									Timer:Start(GPSInfo.distance / GPSInfo.speed, timeCorrection)
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
				elseif GPSInfo.wasOnTaxi then
					Recorder:Stop()
					-- announce the time adjustments, if any
					if not TAXI_TIME_CORRECT_MUTE_SUMMARY and GPSInfo.timeCorrection then
						local absAdjustments = math.abs(GPSInfo.timeCorrection.adjustments)
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
				local pathIds = {}
				GameTooltip:AddLine(" ")
				for i = 1, #info.nodes do
					local node = info.nodes[i]
					local pathId = pathIds[i]
					GameTooltip:AddLine(i .. ". " .. node.name .. (pathId and " (" .. pathId .. ")" or ""), .8, .8, .8, false)
				end
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("Number of nodes: " .. #info.nodes, .8, .8, .8, false)
				GameTooltip:AddLine("Number of points: " .. #info.points, .8, .8, .8, false)
				GameTooltip:AddLine("Approx. speed: " .. info.speed, .8, .8, .8, false)
				GameTooltip:AddLine("Distance: ~ " .. info.distance .. " yards", .8, .8, .8, false)
				if info.delay > 0 then
					GameTooltip:AddLine("Stops: " .. info.delay .. " seconds" .. (info.delayIncluded and "" or " (not included)"), .8, .8, .8, false)
				end
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("~ " .. GetTimeStringFromSeconds(info.duration, false, true) .. " flight time", 1, 1, 1, false)
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
			for _, node in ipairs(State.nodes) do
				if node.slotIndex == slotIndex then
					return node
				end
			end
		end

		---@param toSlotIndex number
		---@param fromSlotIndex? number
		---@param areaID? number
		---@param forceUpdateState? boolean
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
			return GetFlightInfo(State.nodes, from, to, areaID)
		end

		---@param info FlightInfo
		---@param dropZeroHours? boolean
		---@return string
		function TaxiTimerAPI.GetFlightTime(info, dropZeroHours)
			if dropZeroHours == nil then
				dropZeroHours = true
			end
			return GetTimeStringFromSeconds(info.duration or info.distance / info.speed, false, dropZeroHours)
		end

	end

end
