local SHOW_EXTRA_DEBUG_INFO = true

---@class TaxiPathNodeStruct
---@field public LOC_0 1
---@field public LOC_1 2
---@field public LOC_2 3
---@field public ID 4
---@field public PATHID 5

---@class TaxiPathStruct
---@field public ID 1
---@field public FROMTAXINODE 2
---@field public TOTAXINODE 3

---@class taxi_ns
---@field public CatmulDistance fun(path: any[]): number
---@field public TAXIPATHNODE TaxiPathNodeStruct
---@field public TAXIPATH TaxiPathStruct
---@field public taxipathnode table<number, any[]>
---@field public taxipath table<number, any[]>

---@class TaxiPathNode
---@field public x number
---@field public y number
---@field public z number
---@field public pathId number
---@field public id number

---@class TaxiPath
---@field public NYI any

local ns = select(2, ...) ---@type taxi_ns

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
	function Speed(areaID, useLive, noSafety)
		return fallback(areaID, useLive == true, noSafety == true)
	end

end

---@type DB
local DB do

	---@class DB

	DB = {}

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
	function DB:GetPointsFromNodes(nodes)
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

---@type Timer
local Timer do

	---@class Timer
	---@field public Start fun(self: Timer, seconds: number, override?: boolean): nil
	---@field public Stop fun(self: Timer, ): nil
	---@field public Get fun(self: Timer, ): number

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
		return StopwatchTicker.timer
	end

end

---@type GPS
local GPS do

	---@class GPS
	---@field public Start fun(self: GPS, state: State, info: FlightInfo): nil

	---@class GPSInfo
	---@field public wasOnTaxi boolean
	---@field public waitingOnTaxi number

	local TAXI_MAX_SLEEP = 30 -- seconds before we give up waiting on the taxi to start (can happen if lag, or other conditions not being met as we click to fly somewhere)

	local TAXI_TIME_CORRECT = true -- if we wish to change the stopwatch time based on our movement and dynamic speed (if false, uses the original calculation and keeps the timer as-is during the flight)
	local TAXI_TIME_CORRECT_INTERVAL = 2 -- adjusts the timer X amount of times during flight to better calculate actual arrival time (some taxi paths slow down at start, or speed up eventually, this causes some seconds differences, this aims to counter that a bit)
	local TAXI_TIME_CORRECT_IGNORE = 5 -- amount of seconds we need to be wrong, before adjusting the timer

	local TAXI_TIME_CORRECT_MUTE_UPDATES = false -- mute the mid-flight updates
	local TAXI_TIME_CORRECT_MUTE_SUMMARY = false -- mute the end-of-flight summary

	local GPSInfo ---@type GPSInfo|nil
	local Ticker ---@type Ticker|nil

	GPS = {}

	---@param state State
	---@param info FlightInfo
	function GPS:Start(state, info)
		GPSInfo = {
			wasOnTaxi = false,
			waitingOnTaxi = GetTime(),
		}
		if Ticker then
			Timer:Stop()
			Ticker:Cancel()
		end
		Ticker = C_Timer.NewTicker(0.5, function()
			if not GPSInfo.distance then
				GPSInfo.distance = info.distance
				if TAXI_TIME_CORRECT and TAXI_TIME_CORRECT_INTERVAL and not info.donotadjustarrivaltime then
					GPSInfo.timeCorrection = { progress = info.distance, chunk = GPSInfo.distance * (1 / (TAXI_TIME_CORRECT_INTERVAL + 1)), adjustments = 0 }
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
						GPSInfo.distance = GPSInfo.distance - math.sqrt((GPSInfo.lastX - GPSInfo.x)^2 + (GPSInfo.lastY - GPSInfo.y)^2)
						GPSInfo.distancePercent = GPSInfo.distance / info.distance
						if GPSInfo.distance > 0 and GPSInfo.speed > 0 then
							local timeCorrection = TAXI_TIME_CORRECT
							-- DEBUG: current progress
							-- DEFAULT_CHAT_FRAME:AddMessage(format("Flight progress |cffFFFFFF%d|r yd (%.1f%%)", GPSInfo.distance, GPSInfo.distancePercent * 100), 1, 1, 0)
							-- if time correction is enabled to correct in intervals we will do the logic here
							if GPSInfo.timeCorrection then
								timeCorrection = false
								-- make sure we are at a checkpoint before calculating the new time
								if GPSInfo.timeCorrection.progress > GPSInfo.distance then
									timeCorrection = true
									-- set next checkpoint, and calculate time difference
									GPSInfo.timeCorrection.progress = GPSInfo.timeCorrection.progress - GPSInfo.timeCorrection.chunk
									GPSInfo.timeCorrection.difference = math.floor(Timer:Get() - (GPSInfo.distance / GPSInfo.speed))
									-- check if time difference is within acceptable boundaries
									if TAXI_TIME_CORRECT_IGNORE > 0 and math.abs(GPSInfo.timeCorrection.difference) < TAXI_TIME_CORRECT_IGNORE then
										timeCorrection = false
									elseif GPSInfo.stopwatchSet then
										GPSInfo.timeCorrection.adjustments = GPSInfo.timeCorrection.adjustments + GPSInfo.timeCorrection.difference
										-- announce the stopwatch time adjustments if significant enough to be noteworthy, and if we have more than just one interval (we then just summarize at the end)
										if not TAXI_TIME_CORRECT_MUTE_UPDATES and TAXI_TIME_CORRECT_INTERVAL > 1 then
											DEFAULT_CHAT_FRAME:AddMessage("Expected arrival time adjusted by |cffFFFFFF" .. math.abs(GPSInfo.timeCorrection.difference) .. " seconds|r.", 1, 1, 0)
										end
									end
								end
							end
							-- set or override the stopwatch based on time correction mode
							Timer:Start(GPSInfo.distance / GPSInfo.speed, timeCorrection)
							-- stopwatch was set at least once
							GPSInfo.stopwatchSet = true
						end
					end
				end
				GPSInfo.lastSpeed = GPSInfo.speed
				GPSInfo.lastX, GPSInfo.lastY, GPSInfo.lastMapID = GPSInfo.x, GPSInfo.y, GPSInfo.mapID
			elseif not GPSInfo.wasOnTaxi then
				GPSInfo.wasOnTaxi = GetTime() - GPSInfo.waitingOnTaxi > TAXI_MAX_SLEEP
			elseif GPSInfo.wasOnTaxi then
				-- announce the time adjustments, if any
				if not TAXI_TIME_CORRECT_MUTE_SUMMARY and GPSInfo.timeCorrection then
					local absAdjustments = math.abs(GPSInfo.timeCorrection.adjustments)
					if absAdjustments > TAXI_TIME_CORRECT_IGNORE then
						DEFAULT_CHAT_FRAME:AddMessage("Your trip was |cffFFFFFF" .. absAdjustments .. " seconds|r " .. (GPSInfo.timeCorrection.adjustments < 0 and "longer" or "shorter") .. " than indicated.", 1, 1, 0)
					end
				end
				Timer:Stop()
				Ticker:Cancel() ---@diagnostic disable-line: need-check-nil
				Ticker = nil
				table.wipe(GPSInfo)
				GPSInfo = nil
				PlaySound(34089, "Master", true)
				FlashClientIcon()
			end
		end)
	end

end

---@type State
local State do

	---@class State
	---@field public areaID? number
	---@field public from? TaxiNodeInfo
	---@field public to? TaxiNodeInfo
	---@field public nodes TaxiNodeInfo[]
	---@field public gps? Ticker

	---@class TaxiButton : Button
	---@field public taxiNodeData TaxiNodeInfo

	---@class FlightInfo
	---@field public distance number
	---@field public speed number
	---@field public nodes TaxiNodeInfo[]
	---@field public points TaxiPathNode[]
	---@field public paddingDistance? number
	---@field public paddingSpeed? number
	---@field public donotadjustarrivaltime? boolean

	---@param timeAmount number
	---@param asMs? boolean
	---@param dropZeroHours? boolean
	local function GetTimeStringFromSeconds(timeAmount, asMs, dropZeroHours)
		local seconds = asMs and floor(timeAmount / 1000) or timeAmount
		local displayZeroHours = not (dropZeroHours and seconds < 3600)
		return SecondsToClock(seconds, displayZeroHours)
	end

	State = { nodes = {} }

	---@param button TaxiButton
	function State:UpdateButton(button)
		if not self:IsValidState() then
			self:Update()
		end
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
		local info = self:GetFlightInfo() ---@type FlightInfo|nil
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
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("~ " .. GetTimeStringFromSeconds(info.distance / info.speed, false, true) .. " flight time", 1, 1, 1, false)
		GameTooltip:Show()
	end

	function State:PlotCourse()
		local info = self:GetFlightInfo() ---@type FlightInfo|nil
		if not info then
			return
		end
		GPS:Start(self, info)
	end

	function State:GetFlightInfo()
		if not self.from or not self.to or self.from == self.to then
			return
		end
		local nodes = {} ---@type table<TaxiNodeInfo|number, boolean|TaxiNodeInfo>
		local slotIndex = self.to.slotIndex
		local numRoutes = GetNumRoutes(slotIndex)
		for routeIndex = 1, numRoutes do
			local sourceSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, true) ---@diagnostic disable-line: redundant-parameter
			local destinationSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, false) ---@diagnostic disable-line: redundant-parameter
			local sourceNode = self.nodes[sourceSlotIndex]
			local destinationNode = self.nodes[destinationSlotIndex]
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
		local points, paddingDistance, paddingSpeed = DB:GetPointsFromNodes(nodes)
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
				info.speed = Speed(self.areaID)
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

	function State:IsValidState()
		return not not (self.areaID and self.areaID > 0 and self.from and next(self.nodes))
	end

	function State:Update()
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

---@type table<AddOnName, AddOnManifest>
local Frames do

	---@class AddOnName : string

	---@class AddOnManifest
	---@field public loaded boolean
	---@field public OnLoad fun(manifest: AddOnManifest, frame: Frame): nil
	---@field public OnShow? fun(manifest: AddOnManifest): nil

	Frames = {}

	---@type AddOnManifest
	Frames.FlightMapFrame = {
		---@param manifest AddOnManifest
		---@param frame Frame
		OnLoad = function(manifest, frame)
			frame:HookScript("OnShow", function(...) State:Update(...) end)
			hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", function(...) State:OnEnter(...) end)
			hooksecurefunc(FlightMap_FlightPointPinMixin, "OnClick", function(...) State:OnClick(...) end)
		end,
	}

	---@type AddOnManifest
	Frames.TaxiFrame = {
		---@param manifest AddOnManifest
		---@param frame Frame
		OnLoad = function(manifest, frame)
			frame:HookScript("OnShow", function(...) State:Update(...) manifest:OnShow() end)
		end,
		---@param manifest AddOnManifest
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
	---@param event string
	---@param ... any
	local function OnEvent(self, event, ...)

		local numLoaded, numTotal = 0, 0

		for name, manifest in pairs(Frames) do
			local frame = _G[name] ---@type Frame|nil

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

	AddOn = CreateFrame("Frame") ---@diagnostic disable-line: cast-local-type
	AddOn:SetScript("OnEvent", OnEvent)
	AddOn:RegisterEvent("ADDON_LOADED")

end
