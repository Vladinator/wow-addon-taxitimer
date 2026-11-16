local MAJOR, MINOR = "TaxiTimerLib-1.0", 1
local lib = LibStub(MAJOR, true)
if not lib then return end

local api = {} ---@class TaxiTimerLib-1.0_GameAPI

--
-- MARK: Taxi map
--

---@class TaxiTimerLib-1.0_TaxiMap
---@field public areaID? number The taxi map.
---@field public from? TaxiNodeInfo The taxi node the player is at.
---@field public nodes table<number, TaxiNodeInfo> The taxi nodes of the taxi map by slot, which is what the routes of the game are made of.
---@field public otherNodes table<number, TaxiNodeInfo> The taxi nodes by slot of the other taxi map that is shown, for the slots `nodes` does not have.
---@field public otherMaps table<number, boolean> The taxi maps `otherNodes` was filled from.
---@field public shown table<number, boolean> The ids of the taxi nodes of `nodes` and `otherNodes`, which are the ones the taxi map shows.
---@field public otherConflict? boolean If the slots of another taxi map are not the same as the ones of the taxi map we are on, so they can not be used.

-- The taxi map as it was last looked at.
api.TaxiMap = { nodes = {}, otherNodes = {}, otherMaps = {}, shown = {} } ---@type TaxiTimerLib-1.0_TaxiMap
local TaxiMap = api.TaxiMap

-- Makes `TaxiMap.shown` match the taxi nodes that are known now, which is the same table every time so a route does not have to make one.
local function UpdateShown()
	local shown = TaxiMap.shown
	table.wipe(shown)
	for _, node in pairs(TaxiMap.nodes) do
		shown[node.nodeID] = true
	end
	for _, node in pairs(TaxiMap.otherNodes) do
		shown[node.nodeID] = true
	end
end

-- Checks if the taxi map is known, and the taxi node the player is at.
---@return boolean
function api.IsTaxiMapValid()
	return not not (TaxiMap.areaID and TaxiMap.areaID > 0 and TaxiMap.from and next(TaxiMap.nodes))
end

-- Looks at the taxi map the game has open, if it has not been looked at (or it is another taxi map now).
---@param forceUpdate? boolean Look at it again even if it was looked at, like when the taxi map is opened.
---@return boolean updated If it was looked at again.
function api.UpdateTaxiMap(forceUpdate)
	local areaID = GetTaxiMapID()

	if not forceUpdate and api.IsTaxiMapValid() and areaID == TaxiMap.areaID then
		return false
	end

	-- where we are is kept when the taxi map changes, as the other map does not have the taxi node we are at
	local from = not forceUpdate and TaxiMap.from or nil

	TaxiMap.areaID, TaxiMap.from = areaID, from
	table.wipe(TaxiMap.nodes)
	table.wipe(TaxiMap.otherNodes)
	table.wipe(TaxiMap.otherMaps)
	TaxiMap.otherConflict = nil

	if not areaID then
		UpdateShown()
		return true
	end

	local nodes = C_TaxiMap.GetAllTaxiNodes(areaID)
	for i = 1, #nodes do
		local node = nodes[i]
		if node.state == Enum.FlightPathState.Current then
			TaxiMap.from = node
		end
		TaxiMap.nodes[node.slotIndex] = node
	end

	UpdateShown()
	return true
end

-- A flight between two taxi maps (like Dragon Isles and Zaralek Cavern) has taxi nodes on both, and the game only lists the ones of the taxi map we are on.
-- The route has the slot of the ones that are missing, so the list of the taxi map that is shown is used for them, if its slots are the same as the ones of the taxi map we are on.
local function AddShownTaxiMap()
	local frame = _G["FlightMapFrame"] ---@type { GetMapID?: fun(self: table): number? }?
	local mapID = frame and frame.GetMapID and frame:GetMapID()

	if type(mapID) ~= "number" or mapID == TaxiMap.areaID or TaxiMap.otherMaps[mapID] then
		return
	end

	TaxiMap.otherMaps[mapID] = true

	local nodes = C_TaxiMap.GetAllTaxiNodes(mapID)
	for i = 1, #nodes do
		local node = nodes[i]
		local known = TaxiMap.nodes[node.slotIndex]

		if known and known.nodeID ~= node.nodeID then
			-- the slots mean something else on the other taxi map, so none of them can be used
			table.wipe(TaxiMap.otherNodes)
			TaxiMap.otherConflict = true
			UpdateShown()
			return
		end

		if not known and not TaxiMap.otherConflict then
			TaxiMap.otherNodes[node.slotIndex] = node
		end
	end

	UpdateShown()
end

-- Returns the taxi node of a slot of the taxi map.
---@param slotIndex number
---@return TaxiNodeInfo?
function api.GetNodeFromSlotIndex(slotIndex)
	if type(slotIndex) ~= "number" then
		return
	end
	return TaxiMap.nodes[slotIndex]
end

--
-- MARK: Taxi speed
--

-- Returns what the flight path mount is made to fly faster or slower by, going by the spells the player knows (the `SPEED_MODIFIERS` of the sim file of the game, like Frequent Flier in Classic Era's seasonal realms).
---@return number
function api.GetSpeedModifier()
	local modifiers = lib.Sim and lib.Sim.SPEED_MODIFIERS
	local modifier = 1

	if modifiers then
		---@diagnostic disable-next-line: deprecated
		local IsSpellKnown = _G["IsSpellKnown"] or (C_SpellBook and C_SpellBook.IsSpellKnown) ---@type (fun(spell: number, ...: any): boolean)?

		for i = 1, #modifiers do
			local entry = modifiers[i]

			if IsSpellKnown and IsSpellKnown(entry.spellId) then
				modifier = modifier * entry.multiplier
			end
		end
	end

	return modifier
end

--
-- MARK: Flight information
--

-- Asks the game for the route to the taxi node and returns the taxi nodes of it that the taxi map shows, with the start and the destination.
---@param to? TaxiNodeInfo The taxi node to fly to.
---@param from? TaxiNodeInfo The taxi node to fly from, the one the player is at if there is none.
---@return TaxiTimerLib-1.0_TaxiRouteNode[]? nodes
---@return number? numRoutes How many flights the game says the route is made of, which includes the ones to taxi nodes that are not shown.
---@return table<number, boolean>? shown The ids of the taxi nodes the taxi map shows.
function api.GetRouteNodes(to, from)
	from = from or TaxiMap.from

	if not from or not to or from == to then
		return
	end

	AddShownTaxiMap()

	local taxiNodes, otherNodes = TaxiMap.nodes, TaxiMap.otherNodes
	local nodes = {} ---@type TaxiTimerLib-1.0_TaxiRouteNode[]
	local slotIndex = to.slotIndex
	---@type number?
	local numRoutes = GetNumRoutes(slotIndex)

	if type(numRoutes) ~= "number" then
		return -- the taxi map is not open
	end

	local added = {} ---@type table<TaxiNodeInfo, boolean>

	local TaxiGetNodeSlot = TaxiGetNodeSlot ---@type fun(slotIndex: number, routeIndex: number, flag: boolean): number?

	for routeIndex = 1, numRoutes do
		local sourceSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, true)
		local destinationSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, false)
		local sourceNode = sourceSlotIndex and (taxiNodes[sourceSlotIndex] or otherNodes[sourceSlotIndex])
		local destinationNode = destinationSlotIndex and (taxiNodes[destinationSlotIndex] or otherNodes[destinationSlotIndex])

		-- taxi nodes that are never shown on the taxi map (like the tunnels into Zaralek Cavern) are not in the list, so only the ones we have are used and the simulation finds the way between them
		if sourceNode and not added[sourceNode] then
			added[sourceNode] = true
			nodes[#nodes + 1] = sourceNode
		end

		if destinationNode and not added[destinationNode] then
			added[destinationNode] = true
			nodes[#nodes + 1] = destinationNode
		end
	end

	---@param node TaxiNodeInfo
	local function HasNode(node)
		for i = 1, #nodes do
			if nodes[i].nodeID == node.nodeID then
				return true
			end
		end
		return false
	end

	-- the start and the destination are known even if the taxi map has no slot for them (the destination can be on another taxi map than the one we are on)
	if not HasNode(from) then
		table.insert(nodes, 1, from)
	end

	if not HasNode(to) then
		nodes[#nodes + 1] = to
	end

	-- the taxi nodes the taxi map shows, a taxi node in between that is not one of them is one the game does not show (like one that is phased out)
	return nodes, numRoutes, TaxiMap.shown
end

-- Asks the game for the route to the taxi node and returns what the flight is estimated to be like.
---@param to? TaxiNodeInfo The taxi node to fly to.
---@param from? TaxiNodeInfo The taxi node to fly from, the one the player is at if there is none.
---@param areaID? number The taxi map to use the speed of, the taxi map that is open if there is none.
---@return TaxiTimerLib-1.0_FlightInfo?
function api.GetFlightInfoToNode(to, from, areaID)
	local nodes, _, shown = api.GetRouteNodes(to, from)
	if not nodes then
		return
	end
	local faction = UnitFactionGroup("player")
	return lib.GetFlightInfoFromNodes(nodes, areaID or TaxiMap.areaID, api.GetSpeedModifier(), shown, faction)
end

-- Returns what the flight to a slot of the taxi map is estimated to be like.
---@param toSlotIndex number
---@param fromSlotIndex? number Only if you wish to check the travel time from another starting node.
---@param areaID? number Only if you know you wish to override calculations with another areaID than the current TaxiMap provided one.
---@param forceUpdateState? boolean Only if you know the state is stale, otherwise the taxi map is looked at when it is opened.
---@return TaxiTimerLib-1.0_FlightInfo?
function api.GetFlightInfo(toSlotIndex, fromSlotIndex, areaID, forceUpdateState)
	api.UpdateTaxiMap(forceUpdateState)

	local from = fromSlotIndex and api.GetNodeFromSlotIndex(fromSlotIndex) or TaxiMap.from

	if not from then
		return
	end

	local to = api.GetNodeFromSlotIndex(toSlotIndex)

	if not to then
		return
	end

	return api.GetFlightInfoToNode(to, from, areaID)
end

--
-- MARK: Time
--

-- Returns the seconds as a clock, like `1:15` or `1:02:03`.
---@param seconds number
---@param dropZeroHours? boolean If the hours are left out when there are none.
---@return string
function api.FormatDuration(seconds, dropZeroHours)
	local displayZeroHours = not (dropZeroHours and seconds < 3600)

	if SecondsToClock then
		return SecondsToClock(seconds, displayZeroHours)
	end

	local total = floor(seconds)
	local hours = floor(total / 3600)
	local minutes = floor(total % 3600 / 60)

	if hours > 0 or displayZeroHours then
		return ("%d:%02d:%02d"):format(hours, minutes, total % 60)
	end

	return ("%d:%02d"):format(minutes, total % 60)
end

-- Returns the duration of a flight as a clock.
---@param info? TaxiTimerLib-1.0_FlightInfo
---@param dropZeroHours? boolean If the hours are left out when there are none, which is the default.
---@return string?
function api.GetFlightTime(info, dropZeroHours)
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

	return api.FormatDuration(duration, dropZeroHours)
end

---@diagnostic disable-next-line: deprecated
lib.SetGameAPI(api, MINOR)
