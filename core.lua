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

-- TODO: copy-paste from the taxi.lua file to avoid warnings
---@class FlightInfo
---@field public distance number
---@field public speed number
---@field public nodes TaxiNodeInfo[]
---@field public points TaxiPathNode[]
---@field public paddingDistance? number
---@field public paddingSpeed? number
---@field public donotadjustarrivaltime? boolean

---@class taxi_ns
---@field public CatmulDistance fun(path: any[]): number
---@field public Speed fun(areaID: number, useLive?: boolean, noSafety?: boolean): number
---@field public GetPointsFromNodes fun(nodes: TaxiNodeInfo[]): TaxiPathNode[], number?, number?
---@field public GetFlightInfo fun(taxiNodes: TaxiNodeInfo[], from: TaxiNodeInfo, to: TaxiNodeInfo, areaID?: number): FlightInfo | nil
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

local Speed = ns.Speed
local GetFlightInfo = ns.GetFlightInfo

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
		return GetFlightInfo(self.nodes, self.from, self.to, self.areaID)
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
