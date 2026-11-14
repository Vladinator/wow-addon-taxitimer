local SHOW_EXTRA_DEBUG_INFO = false -- enable displaying additional node information on taxi node tooltips
local RECORD_FLIGHTS = false -- enable recording of paths to SV for later analysis

local addonName = ... ---@type string

local ns = select(2, ...) ---@class taxi_ns_db

ns = ns or {}

local Speed = ns.Speed
local GetFlightInfoFromNodes = ns.GetFlightInfoFromNodes
local GetFlightTimeLeft = ns.GetFlightTimeLeft

--- Returns what the flight path mount speed modifier (currently only relevant for Forever "Frequent Flier" legacy talent)
---@return number
local function GetSpeedModifier()
	local modifiers = ns.SPEED_MODIFIERS
	local modifier = 1

	if modifiers then
		---@diagnostic expect-next-line: deprecated
		local IsSpellKnown = IsSpellKnown or C_SpellBook.IsSpellKnown ---@type fun(spell: number, ...: any): boolean

		for i = 1, #modifiers do
			local entry = modifiers[i]

			if IsSpellKnown(entry.spellId) then
				modifier = modifier * entry.multiplier
			end
		end
	end

	return modifier
end

--- Returns the speed we fly at, but never less than the taxi map is flown at as it is lower while taking off and landing.
---@param areaID? number
---@param speedModifier? number
---@return number
local function GetLiveSpeed(areaID, speedModifier)
	local speed = Speed(areaID) * (speedModifier or 1)

	if not areaID then
		return speed
	end

	return max(GetUnitSpeed("player"), speed)
end

--- Asks the game for the route to the destination and returns what the flight is estimated to be like.
---@param taxiNodes TaxiNodeInfo[]
---@param from? TaxiNodeInfo
---@param to? TaxiNodeInfo
---@param areaID? number
---@param otherNodes? TaxiNodeInfo[] The taxi nodes of the other taxi map that is shown, for the slots the taxi map we are on does not have.
---@return FlightInfo?
local function GetFlightInfo(taxiNodes, from, to, areaID, otherNodes)
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
	local numMissing = 0
	for routeIndex = 1, numRoutes do
		---@type number
		local sourceSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, true) ---@diagnostic expect-line: assign-type-mismatch, redundant-parameter
		---@type number
		local destinationSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, false) ---@diagnostic expect-line: assign-type-mismatch, redundant-parameter
		local sourceNode = taxiNodes[sourceSlotIndex] or (otherNodes and otherNodes[sourceSlotIndex])
		local destinationNode = taxiNodes[destinationSlotIndex] or (otherNodes and otherNodes[destinationSlotIndex])
		-- taxi nodes that are never shown on the taxi map (like the tunnels into Zaralek Cavern) are not in the list, so only the ones we have are used and the simulation finds the way between them
		if sourceNode and not nodes[sourceNode] then
			nodes[sourceNode] = true
			table.insert(nodes, sourceNode)
		end
		if destinationNode and not nodes[destinationNode] then
			nodes[destinationNode] = true
			table.insert(nodes, destinationNode)
		end
		numMissing = numMissing + (sourceNode and 0 or 1) + (destinationNode and 0 or 1)
	end
	-- the start and the destination are known even if the taxi map has no slot for them (the destination can be on another taxi map than the one we are on)
	local function HasNode(node)
		for i = 1, #nodes do
			if nodes[i].nodeID == node.nodeID then
				return true
			end
		end
		return false
	end
	if not HasNode(from) then
		table.insert(nodes, 1, from)
	end
	if not HasNode(to) then
		nodes[#nodes + 1] = to
	end
	return GetFlightInfoFromNodes(nodes, areaID, GetSpeedModifier())
end

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
	---@field public flavor? TaxiFlavor The game the flight was recorded on, named like its db file.
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
	---@field public speedModifier? number What every speed was multiplied by for spells that make the flight path mount faster or slower.
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
				flavor = ns.FLAVOR,
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
				areaSpeed = Round(info.areaSpeed, 2),
				speedModifier = Round(info.speedModifier, 3),
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
		local areaSpeed = info.areaSpeed
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
				GPSInfo.speed = GetLiveSpeed(state.areaID, info.speedModifier)
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
	---@field public nodes TaxiNodeInfo[] The taxi nodes by slot of the current taxi map.
	---@field public otherNodes table<number, TaxiNodeInfo> The taxi nodes by slot of the other taxi map that is shown, for the slots `nodes` does not have.
	---@field public otherMaps table<number, boolean> The taxi maps `otherNodes` was filled from.
	---@field public otherConflict? boolean If the slots of another taxi map are not the same as the ones of the taxi map we are on, so they can not be used.
	---@field public gps? FunctionContainer

	---@class TaxiButton : Button
	---@field public taxiNodeData TaxiNodeInfo

	State = { nodes = {}, otherNodes = {}, otherMaps = {} }

	---@param button TaxiButton
	function State:UpdateButton(button)
		self:Update()
		if button.taxiNodeData then
			self.to = self.nodes[button.taxiNodeData.slotIndex] or button.taxiNodeData
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
			if SHOW_EXTRA_DEBUG_INFO and self.from ~= self.to then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(format("No taxi data for map: %s (%d nodes)", tostring(self.areaID), #self.nodes), 0.8, 0.8, 0.8, true)
				GameTooltip:AddLine(format("From: %s", self.from and self.from.name or "N/A"), 0.8, 0.8, 0.8, true)
				GameTooltip:AddLine(format("To: %s", self.to and self.to.name or "N/A"), 0.8, 0.8, 0.8, true)
				GameTooltip:Show()
			end
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
			GameTooltip:AddLine(" ")
		end
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

	function State:AddShownMap()
		local frame = _G["FlightMapFrame"] ---@type { GetMapID?: fun(self: table): number? }?
		local mapID = frame and frame.GetMapID and frame:GetMapID()
		if type(mapID) ~= "number" or mapID == self.areaID or self.otherMaps[mapID] then
			return
		end
		self.otherMaps[mapID] = true
		local nodes = C_TaxiMap.GetAllTaxiNodes(mapID)
		for i = 1, #nodes do
			local node = nodes[i]
			local known = self.nodes[node.slotIndex]
			if known and known.nodeID ~= node.nodeID then
				-- the slots mean something else on the other taxi map, so none of them can be used
				table.wipe(self.otherNodes)
				self.otherConflict = true
				return
			end
			if not known and not self.otherConflict then
				self.otherNodes[node.slotIndex] = node
			end
		end
	end

	---@return FlightInfo?
	function State:GetFlightInfo()
		self:AddShownMap()
		return GetFlightInfo(self.nodes, self.from, self.to, self.areaID, self.otherNodes)
	end

	function State:IsValidState()
		return not not (self.areaID and self.areaID > 0 and self.from and next(self.nodes))
	end

	---@param forceUpdate? boolean
	function State:Update(forceUpdate)
		local areaID = GetTaxiMapID()
		if not forceUpdate and self:IsValidState() and areaID == self.areaID then
			return
		end
		local from = not forceUpdate and self.from or nil
		self.areaID, self.from, self.to = areaID, from, nil
		table.wipe(self.nodes)
		table.wipe(self.otherNodes)
		table.wipe(self.otherMaps)
		self.otherConflict = nil
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
