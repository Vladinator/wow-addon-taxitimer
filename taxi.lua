local ns = select(2, ...) ---@class taxi_ns

if type(ns) ~= "table" then
    ns = {}
end

local CatmulDistance = ns.CatmulDistance
local TAXIPATHNODE = ns.TAXIPATHNODE
local TAXIPATH = ns.TAXIPATH
local TaxiPathNode = ns.taxipathnode
local TaxiPath = ns.taxipath

local Speed do

	local TAXI_SPEED_FALLBACK = 30+1/3
	local TAXI_SPEED_FASTER = 40+1/3

	local fallback = setmetatable({
		[1116] = TAXI_SPEED_FASTER, -- Draenor
		[1220] = TAXI_SPEED_FASTER, -- Broken Isles
		[1647] = TAXI_SPEED_FASTER, -- Shadowlands
	}, {
		__index = function()
			return TAXI_SPEED_FALLBACK
		end,
		__call = function(self, areaID, useLive, noSafety)
			if useLive then
				local speed = GetUnitSpeed("player")
				if not noSafety then
					speed = math.max(speed, self[areaID])
				end
				return speed
			elseif areaID then
				return self[areaID]
			else
				return TAXI_SPEED_FALLBACK
			end
		end,
	})

	---@param areaID number
	---@param useLive? boolean
	---@param noSafety? boolean
	---@return number
	function Speed(areaID, useLive, noSafety)
		return fallback(areaID, useLive == true, noSafety == true)
	end

end

local GetPointsFromNodes do

	local NODE_EDGE_TRIM = 10 -- amount of points to be trimmed for more accurate blizzard like transitions between several taxi nodes

	local SHADOWLANDS_SPEED = Speed(1647)
	local SHADOWLANDS_WARP_SPEED = 200 -- estimation
	local SHADOWLANDS_ORIBOS_LIGHTSPEED_PADDING_DISTANCE = SHADOWLANDS_WARP_SPEED*40 -- estimation
	local SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE = SHADOWLANDS_SPEED*80 -- ?
	local SHADOWLANDS_ORIBOS_BASTION_DISTANCE = SHADOWLANDS_SPEED*75
	local SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE = SHADOWLANDS_SPEED*80 -- ?
	local SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE = SHADOWLANDS_SPEED*80 -- ?

	local SHADOWLANDS_DISTANCE = {
		[7916] = SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE, -- Oribos > Revendreth, Pridefall Hamlet
		[7917] = SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE, -- Revendreth, Pridefall Hamlet > Oribos
		[8013] = SHADOWLANDS_ORIBOS_BASTION_DISTANCE, -- Oribos > Bastion, Aspirant's Rest
		[8012] = SHADOWLANDS_ORIBOS_BASTION_DISTANCE, -- Bastion, Aspirant's Rest > Oribos
		[8318] = SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE, -- Oribos > Maldraxxus, Theater of Pain
		[8319] = SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE, -- Maldraxxus, Theater of Pain > Oribos
		[8431] = SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE, -- Oribos > Ardenweald, Tirna Vaal
		[8432] = SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE, -- Ardenweald, Tirna Vaal > Oribos
	}

	---@return number paddingDistance, number paddingSpeed
	local DISTANCE_ADJUSTMENT = function(pathId, nodes)
		for i = #nodes, 3, -1 do
			nodes[i] = nil
		end
		local d = SHADOWLANDS_DISTANCE[pathId] or 0
		nodes[1].x, nodes[1].y, nodes[1].z = 1, 1, 1
		nodes[2].x, nodes[2].y, nodes[2].z = d + 1, 1, 1
		return SHADOWLANDS_ORIBOS_LIGHTSPEED_PADDING_DISTANCE, SHADOWLANDS_WARP_SPEED
	end

	local PATH_ADJUSTMENT = {
		[7916] = DISTANCE_ADJUSTMENT,
		[8013] = DISTANCE_ADJUSTMENT,
		[8318] = DISTANCE_ADJUSTMENT,
		[8431] = DISTANCE_ADJUSTMENT,
		[7917] = DISTANCE_ADJUSTMENT,
		[8012] = DISTANCE_ADJUSTMENT,
		[8319] = DISTANCE_ADJUSTMENT,
		[8432] = DISTANCE_ADJUSTMENT,
	}

	---@param pathId number
	---@param trimEdges number|nil
	---@param whatEdge number|nil
	---@return boolean exists, TaxiPathNode[]|nil nodes, number|nil paddingDistance, number|nil paddingSpeed
	local function GetTaxiPathNodes(pathId, trimEdges, whatEdge)
		local nodes = {} ---@type TaxiPathNode[]
		local exists = false

		for i = 1, #TaxiPathNode do
			local taxiPathChunk = TaxiPathNode[i]

			for j = 1, #taxiPathChunk do
				local taxiPathNode = taxiPathChunk[j]

				if taxiPathNode[TAXIPATHNODE.PATHID] == pathId then
					exists = true

					table.insert(nodes, {taxiPathNode[TAXIPATHNODE.ID], x = taxiPathNode[TAXIPATHNODE.LOC_0], y = taxiPathNode[TAXIPATHNODE.LOC_1], z = taxiPathNode[TAXIPATHNODE.LOC_2], pathId = pathId, id = taxiPathNode[TAXIPATHNODE.ID]})
				end
			end
		end

		if trimEdges and #nodes > trimEdges then
			if whatEdge == nil or whatEdge == 1 then
				for i = 1, trimEdges do
					table.remove(nodes, 1)
				end
			end

			if whatEdge == nil or whatEdge == 2 then
				for i = 1, trimEdges do
					table.remove(nodes, #nodes)
				end
			end
		end

		local paddingDistance, paddingSpeed
		if nodes[2] then
			local pathAdjustment = PATH_ADJUSTMENT[pathId]
			if pathAdjustment then
				paddingDistance, paddingSpeed = pathAdjustment(pathId, nodes)
			end
		end

		return exists, nodes[1] and nodes or nil, paddingDistance, paddingSpeed
	end

	---@param from number
	---@param to number
	---@param trimEdges number|nil
	---@param whatEdge number|nil
	local function GetTaxiPath(from, to, trimEdges, whatEdge)
		local pathId

		for i = 1, #TaxiPath do
			local taxiPathChunk = TaxiPath[i]

			for j = 1, #taxiPathChunk do
				local taxiPath = taxiPathChunk[j]
				local fromId, toId = taxiPath[TAXIPATH.FROMTAXINODE], taxiPath[TAXIPATH.TOTAXINODE]

				if fromId == from and toId == to then
					pathId = taxiPath[TAXIPATH.ID]
					break
				end
			end

			if pathId then
				break
			end
		end

		if not pathId then
			return
		end

		local exists, nodes, paddingDistance, paddingSpeed = GetTaxiPathNodes(pathId, trimEdges, whatEdge)
		return exists, nodes, paddingDistance, paddingSpeed
	end

	---@param nodes TaxiNodeInfo[]
	---@return TaxiPathNode[] points, number|nil paddingDistance, number|nil paddingSpeed
	function GetPointsFromNodes(nodes)
		local points = {} ---@type TaxiPathNode[]
		local numNodes = #nodes
		local paddingDistance, paddingSpeed

		for i = 2, numNodes do
			local from, to = nodes[i - 1], nodes[i]
			local trimEdges, whatEdge

			if numNodes > 2 then
				trimEdges = NODE_EDGE_TRIM
			end

			if i == 2 then
				whatEdge = 2 -- at the beginning we trim the right side points
			elseif i == numNodes then
				whatEdge = 1 -- at the end we trim the left side points
			end

			local exists, temp, padding, pspeed = GetTaxiPath(from.nodeID, to.nodeID, trimEdges, whatEdge)
			if exists and temp then
				for j = 1, #temp do
					table.insert(points, temp[j])
				end
				paddingDistance = padding
				paddingSpeed = pspeed
			end
		end

		return points, paddingDistance, paddingSpeed
	end

end

local GetFlightInfo do

	---@class FlightInfo
	---@field public distance number
	---@field public speed number
	---@field public nodes TaxiNodeInfo[]
	---@field public points TaxiPathNode[]
	---@field public paddingDistance? number
	---@field public paddingSpeed? number
	---@field public donotadjustarrivaltime? boolean

	---@param taxiNodes TaxiNodeInfo[]
	---@param from TaxiNodeInfo
	---@param to TaxiNodeInfo
	---@param areaID? number
	---@return FlightInfo | nil
	function GetFlightInfo(taxiNodes, from, to, areaID)
		if not from or not to or from == to then
			return
		end
		local nodes = {} ---@type table<TaxiNodeInfo|number, boolean|TaxiNodeInfo>
		local slotIndex = to.slotIndex
		local numRoutes = GetNumRoutes(slotIndex)
		for routeIndex = 1, numRoutes do
			local sourceSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, true) ---@diagnostic disable-line: redundant-parameter
			local destinationSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, false) ---@diagnostic disable-line: redundant-parameter
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
		local points, paddingDistance, paddingSpeed = GetPointsFromNodes(nodes)
		if points and points[1] then
			local distance = CatmulDistance(points)
			if distance and distance > 0 then
				---@type FlightInfo
				local info = {
					distance = distance,
					nodes = nodes,
					points = points,
					paddingDistance = paddingDistance,
					paddingSpeed = paddingSpeed,
				}
				info.speed = Speed(areaID) ---@diagnostic disable-line: param-type-mismatch
				if paddingDistance then
					info.distance = info.distance + paddingDistance
				end
				if paddingSpeed then
					info.speed = (info.speed + paddingSpeed)/2
				end
				-- info.donotadjustarrivaltime = paddingDistance or paddingSpeed
				return info
			end
		end
	end

end

ns.Speed = Speed
ns.GetPointsFromNodes = GetPointsFromNodes
ns.GetFlightInfo = GetFlightInfo

return ns
