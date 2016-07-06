local addonName, ns = ...

local Catmull
do
	local SPLINE_TIGHTNESS = .5

	local ABSCISSAS, WEIGHTS = {}, {}
	do
		ABSCISSAS[ 1 ], WEIGHTS[ 1 ] = 0, 128 / 225
		ABSCISSAS[ 2 ], WEIGHTS[ 2 ] = 1 / 21 * ( 245 - 14 * ( 70 ) ^ .5 ) ^ .5, 1 / 900 * ( 322 + 13 * ( 70 ) ^ .5 )
		ABSCISSAS[ 3 ], WEIGHTS[ 3 ] = -ABSCISSAS[ 2 ], WEIGHTS[ 2 ]
		ABSCISSAS[ 4 ], WEIGHTS[ 4 ] = 1 / 21 * ( 245 + 14 * ( 70 ) ^ .5 ) ^ .5, 1 / 900 * ( 322 - 13 * ( 70 ) ^ .5 )
		ABSCISSAS[ 5 ], WEIGHTS[ 5 ] = -ABSCISSAS[ 4 ], WEIGHTS[ 4 ]

		for i = 1, #ABSCISSAS do
			ABSCISSAS[ i ], WEIGHTS[ i ] = ABSCISSAS[ i ] / 2 + 1 / 2, WEIGHTS[ i ] / 2
		end
	end

	local function GetLength(points)
		local P0, P1, P2, P3
		local Tan1x, Tan1y, Tan1z, Tan2x, Tan2y, Tan2z
		local C1x, C1y, C1z, C2x, C2y, C2z, C3x, C3y, C3z
		local dX, dY, dZ, t, t2
		local length = 0

		for i = 2, #points - 2 do
			P0, P1, P2, P3 = points[ i - 1 ], points[ i ], points[ i + 1 ], points[ i + 2 ]

			Tan1x, Tan1y, Tan1z = SPLINE_TIGHTNESS * ( P2[ 1 ] - P0[ 1 ] ), SPLINE_TIGHTNESS * ( P2[ 2 ] - P0[ 2 ] ), SPLINE_TIGHTNESS * ( P2[ 3 ] - P0[ 3 ] )
			Tan2x, Tan2y, Tan2z = SPLINE_TIGHTNESS * ( P3[ 1 ] - P1[ 1 ] ), SPLINE_TIGHTNESS * ( P3[ 2 ] - P1[ 2 ] ), SPLINE_TIGHTNESS * ( P3[ 3 ] - P1[ 3 ] )

			C3x = 3 * ( 2 * P1[ 1 ] - 2 * P2[ 1 ] + Tan1x + Tan2x )
			C3y = 3 * ( 2 * P1[ 2 ] - 2 * P2[ 2 ] + Tan1y + Tan2y )
			C3z = 3 * ( 2 * P1[ 3 ] - 2 * P2[ 3 ] + Tan1z + Tan2z )
			C2x = 2 * ( -3 * P1[ 1 ] + 3 * P2[ 1 ] - 2 * Tan1x - Tan2x )
			C2y = 2 * ( -3 * P1[ 2 ] + 3 * P2[ 2 ] - 2 * Tan1y - Tan2y )
			C2z = 2 * ( -3 * P1[ 3 ] + 3 * P2[ 3 ] - 2 * Tan1z - Tan2z )
			C1x, C1y, C1z = Tan1x, Tan1y, Tan1z

			for j = 1, #ABSCISSAS do
				local t = ABSCISSAS[ j ]
				t2 = t ^ 2
				dX = C3x * t2 + C2x * t + C1x
				dY = C3y * t2 + C2y * t + C1y
				dZ = C3z * t2 + C2z * t + C1z

				length = length + ( dX * dX + dY * dY + dZ * dZ ) ^ .5 * WEIGHTS[ j ]
			end
		end

		return length
	end

	function Catmull(points)
		return GetLength(points)
	end
end

local Speed
do
	local TAXI_SPEED_FALLBACK = 30+1/3

	local fallback = setmetatable({
		-- [13] = TAXI_SPEED_FALLBACK, -- Kalimdor
		-- [14] = TAXI_SPEED_FALLBACK, -- Eastern Kingdoms
		-- [466] = TAXI_SPEED_FALLBACK, -- Outland
		-- [485] = TAXI_SPEED_FALLBACK, -- Northrend
		-- [862] = TAXI_SPEED_FALLBACK, -- Pandaria
		[962] = 40+1/3, -- Draenor
		[1007] = 50+1/3, -- Broken Isles
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

	function Speed(areaID, useLive, noSafety)
		return fallback(areaID, useLive == true, noSafety == true)
	end
end

local Stopwatch
do
	Stopwatch = {
		Start = function(self, seconds, override)
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
		end,
		Stop = function(self)
			Stopwatch_Clear()
			StopwatchFrame:Hide()
		end,
	}
end

local State, Frames
do
	local NODE_EDGE_TRIM = 2 -- amount of points to be trimmed for more accurate blizzard like transitions between several taxi nodes
	local TAXI_MAX_SLEEP = 60 -- seconds before we give up waiting on the taxi to start (can happen if lag, or other conditions not being met as we click to fly somewhere)
	local TAXI_TIME_CORRECT = false -- if we wish to change the stopwatch time based on our movement and dynamic speed (if false, uses the original calculation and keeps the timer as-is during the flight)

	local function GetTaxiPathNodes(pathId, trimEdges, whatEdge)
		local nodes = {}
		local exists = false

		for i = 1, #ns.TaxiPathNode do
			local taxiPathNode = ns.TaxiPathNode[i]

			if taxiPathNode[4] == pathId then
				exists = true

				table.insert(nodes, {taxiPathNode[1], taxiPathNode[2], taxiPathNode[3], taxiPathNode[5]})
			end
		end

		if trimEdges and #nodes > trimEdges * 3 then
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

		return exists, nodes[1] and nodes or nil
	end

	local function GetTaxiPath(from, to, trimEdges, whatEdge)
		local pathId

		for i = 1, #ns.TaxiPath do
			local taxiPath = ns.TaxiPath[i]
			local fromId, toId = taxiPath[1], taxiPath[2]

			if fromId == from and toId == to then
				pathId = taxiPath[3]

				break
			end
		end

		if pathId then
			return GetTaxiPathNodes(pathId, trimEdges, whatEdge)
		end
	end

	local function GetPointsFromNodes(nodes)
		local points = {}
		local numNodes = #nodes

		for i = 2, numNodes do
			local from, to = nodes[i - 1], nodes[i]
			local trimEdges, whatEdge = NODE_EDGE_TRIM

			if numNodes < 3 then
				trimEdges = nil -- pointless if there are no jumps between additional nodes
			end

			if i == 2 then
				whatEdge = 2 -- at the beginning we trim the right side points
			elseif i == numNodes then
				whatEdge = 1 -- at the end we trim the left side points
			end

			local exists, temp = GetTaxiPath(from.nodeID, to.nodeID, trimEdges, whatEdge)
			if exists then
				for j = 1, #temp do
					table.insert(points, temp[j])
				end
			end
		end

		return points
	end

	State = {
		areaID = 0,
		from = nil,
		to = nil,
		nodes = {},

		Update = function(self)
			self.areaID, self.from, self.to = GetTaxiMapID(), nil
			table.wipe(self.nodes)

			local taxiNodes = GetAllTaxiNodes()
			for i = 1, #taxiNodes do
				local taxiNode = taxiNodes[i]

				if taxiNode.type == LE_FLIGHT_PATH_TYPE_CURRENT then
					self.from = taxiNode
				end

				self.nodes[taxiNode.slotIndex] = taxiNode
			end
		end,

		UpdateButton = function(self, button)
			if button.taxiNodeData then
				self.to = self.nodes[button.taxiNodeData.slotIndex]
			else
				self.to = self.nodes[button:GetID()]
			end

			if self.to and self.to.type == LE_FLIGHT_PATH_TYPE_UNREACHABLE then
				self.to = nil
			end
		end,

		GetFlightInfo = function(self)
			if not self.from or not self.to or self.from == self.to then
				return
			end

			local nodes = {}

			local slotIndex = self.to.slotIndex
			local numRoutes = GetNumRoutes(slotIndex)

			for routeIndex = 1, numRoutes do
				local sourceSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, true)
				local destinationSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, false)

				local sourceNode = self.nodes[sourceSlotIndex]
				local destinationNode = self.nodes[destinationSlotIndex]

				if not nodes[sourceNode] then
					nodes[sourceNode] = true

					table.insert(nodes, sourceNode)
				end

				if not nodes[destinationNode] then
					nodes[destinationNode] = true

					table.insert(nodes, destinationNode)
				end
			end

			local points = GetPointsFromNodes(nodes)
			if points and points[1] then
				local distance = Catmull(points)

				if distance and distance > 0 then
					local speed = Speed(self.areaID)

					return {
						distance = distance,
						speed = speed,
						nodes = nodes,
						points = points,
					}
				end
			end
		end,

		ButtonTooltip = function(self, button)
			local info = self:GetFlightInfo()

			if info then
				GameTooltip:AddLine(" ")

				for i = 1, #info.nodes do
					local node = info.nodes[i]

					GameTooltip:AddLine(i .. ". " .. node.name, .8, .8, .8, false)
				end

				-- GameTooltip:AddLine(" ")
				-- GameTooltip:AddLine("Number of nodes: " .. #info.nodes, .8, .8, .8, false)
				-- GameTooltip:AddLine("Number of points: " .. #info.points, .8, .8, .8, false)
				-- GameTooltip:AddLine("Approx. speed: " .. info.speed, .8, .8, .8, false)
				-- GameTooltip:AddLine("Distance: ~ " .. info.distance .. " yards", .8, .8, .8, false)

				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("~ " .. GetTimeStringFromSeconds(info.distance / info.speed, false, true) .. " flight time", 1, 1, 1, false)

				GameTooltip:Show()
			end
		end,

		PlotCourse = function(self)
			local info = self:GetFlightInfo()

			if info then
				local gps, _ = {
					wasOnTaxi = false,
					waitingOnTaxi = GetTime(),
				}

				if self.gps then
					Stopwatch:Stop()
					self.gps:Cancel()
				end

				self.gps = C_Timer.NewTicker(.5, function()
					if not gps.distance then
						gps.distance = info.distance
					end

					if UnitOnTaxi("player") then
						gps.wasOnTaxi = true
						gps.speed = Speed(self.areaID, true)
						gps.x, gps.y, _, gps.areaID = UnitPosition("player")

						if gps.lastSpeed then
							if gps.areaID and gps.lastAreaID and gps.areaID ~= gps.lastAreaID then
								gps.lastX = nil
							end

							if gps.lastX then
								gps.distance = gps.distance - math.sqrt((gps.lastX - gps.x)^2 + (gps.lastY - gps.y)^2)
							end

							if gps.distance > 0 and gps.speed > 0 then
								Stopwatch:Start(gps.distance / gps.speed, TAXI_TIME_CORRECT)
							end
						end

						gps.lastSpeed = gps.speed
						gps.lastX, gps.lastY, gps.lastAreaID = gps.x, gps.y, gps.areaID

					elseif not gps.wasOnTaxi then
						gps.wasOnTaxi = GetTime() - gps.waitingOnTaxi > TAXI_MAX_SLEEP

					elseif gps.wasOnTaxi then
						Stopwatch:Stop()
						self.gps:Cancel()
						table.wipe(gps)
						self:Arrived()
					end
				end)
			end
		end,

		OnEnter = function(button)
			State:UpdateButton(button)
			State:ButtonTooltip(button)
		end,

		OnClick = function(button)
			State:UpdateButton(button)
			State:PlotCourse()
		end,

		Arrived = function(self)
			PlaySoundKitID(34089, "Master")
			FlashClientIcon()
		end,
	}

	Frames = {
		FlightMapFrame = {
			OnLoad = function(manifest, frame)
				frame:HookScript("OnShow", function() State:Update() end)
				hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", State.OnEnter)
				hooksecurefunc(FlightMap_FlightPointPinMixin, "OnClick", State.OnClick)
			end,
		},
		TaxiFrame = {
			OnLoad = function(manifest, frame)
				frame:HookScript("OnShow", function() State:Update() manifest:OnShow() end)
			end,
			OnShow = function(manifest)
				for i = 1, NumTaxiNodes(), 1 do
					local button = _G["TaxiButton" .. i]

					if button and not manifest[button] then
						manifest[button] = true

						button:HookScript("OnEnter", State.OnEnter)
						button:HookScript("OnClick", State.OnClick)
					end
				end
			end,
		},
	}
end

local addon = CreateFrame("Frame")
addon:SetScript("OnEvent", function(self, event, ...) self[event](self, event, ...) end)

function addon:ADDON_LOADED(event)
	local numLoaded, numTotal = 0, 0

	for name, manifest in pairs(Frames) do
		local frame = _G[name]

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
		addon:UnregisterEvent(event)
	end
end

addon:RegisterEvent("ADDON_LOADED")
