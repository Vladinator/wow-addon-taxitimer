local addonName = ... ---@type string

local lib = LibStub("TaxiTimerLib-1.0") ---@type TaxiTimerLib-1.0

---@class SV
local SV do

	---@class TaxiTimerDBOptions
	---@field public debug boolean
	---@field public record boolean
	---@field public mode VisualizationMode
	---@field public bar VisualizationBarPoint

	---@alias TaxiTimerDBFlights FlightRecord[]

	---@class TaxiTimerDB
	---@field public options TaxiTimerDBOptions
	---@field public flights TaxiTimerDBFlights

	SV = {}

	---@type TaxiTimerDB
	local defaults = {
		options = {
			debug = false,
			record = false,
			mode = "stopwatch",
			bar = { "TOP", "TOP", 0, -140 },
		},
		flights = {},
	}

	---@generic T extends table
	---@param tbl T
	---@param shallow? boolean Default is `false` so tables are deeply copied.
	---@return T
	local function CopyTable(tbl, shallow)
		local copy = {} ---@type T[]
		for k, v in pairs(tbl) do
			if type(v) == "table" and not shallow then
				copy[k] = CopyTable(v)
			else
				copy[k] = v
			end
		end
		return copy
	end

	---@generic T extends table
	---@param tbl T
	---@param value T[keyof T]
	local function TableContains(tbl, value)
		for k, v in pairs(tbl) do
			if v == value then
				return true
			end
		end
		return false
	end

	-- The assumption is that we call this when the addon loads, and that the user can't realistically interact with anything in-game before this happens anyway so we are in no danger of using the SV before the addon load event occurs.
	function SV:Init()
		if type(TaxiTimerDB) ~= "table" then
			TaxiTimerDB = CopyTable(defaults)
		end
		setmetatable(TaxiTimerDB, { __index = defaults })
		for k, v in pairs(defaults) do
			if type(TaxiTimerDB[k]) ~= "table" then
				TaxiTimerDB[k] = CopyTable(v)
			end
			setmetatable(TaxiTimerDB[k], { __index = v })
		end
	end

	function SV:GetDB()
		return TaxiTimerDB ---@type TaxiTimerDB
	end

	---@generic T extends keyof TaxiTimerDB
	---@param key T
	---@return TaxiTimerDB[T]
	function SV:Get(key)
		return self:GetDB()[key]
	end

	---@generic T extends keyof TaxiTimerDB
	---@param key T
	---@param value TaxiTimerDB[T]
	function SV:Set(key, value)
		local db = self:GetDB()
		db[key] = value
	end

	---@param flight FlightRecord
	function SV:AddFlight(flight)
		local flights = self:Get("flights")
		if TableContains(flights, flight) then
			return false
		end
		flights[#flights + 1] = flight
		return true
	end

	---@param maxFlights number
	function SV:TrimFlights(maxFlights)
		local flights = self:Get("flights")
		while #flights > maxFlights do
			table.remove(flights, 1)
		end
	end

	---@generic T extends keyof TaxiTimerDBOptions
	---@param key T
	---@return TaxiTimerDBOptions[T]
	function SV:GetOption(key)
		return self:Get("options")[key]
	end

	---@generic T extends keyof TaxiTimerDBOptions
	---@param key T
	---@param value TaxiTimerDBOptions[T]
	function SV:SetOption(key, value)
		local options = self:Get("options")
		options[key] = value
	end

end

---@class Visualization
local Visualization do

	---@alias VisualizationMode "off"|"stopwatch"|"bar"|"details"

	---@alias VisualizationBarPoint { [1]: FramePoint, [2]: FramePoint, [3]: number, [4]: number }

	---@class VisualizationNotch : Frame
	---@field public checkpoint TaxiTimerLib-1.0_FlightCheckpoint The taxi node the notch is at.
	---@field public number number The place of the taxi node in the route.
	---@field public passed boolean If the flight has passed the taxi node, so the flash plays once.
	---@field public line Texture
	---@field public highlight? Texture
	---@field public flare? Texture
	---@field public flareAnim? AnimationGroup

	local BAR_WIDTH = 280
	local BAR_HEIGHT = 13
	local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
	local WHITE_TEXTURE = "Interface\\Buttons\\WHITE8X8"

	-- the colors of the bar, as red, green, blue and alpha
	local FILL_COLOR = { 1, 0.78, 0.1, 1 } -- what is flown (the color when there are no atlases, the yellow of the casting bar)
	local DONE_COLOR = { 0.35, 0.85, 0.4, 1 } -- what is flown of the route up to the last taxi node we passed (the color when there are no atlases, and of the text)
	local DONE_TINT = { 0.55, 1, 0.65 } -- the same, as the tint of the texture of a finished cast

	-- The look of the casting bar of the game, by the atlas it uses for each part (see `CastingBarFrame.xml` of `Blizzard_UIPanels_Game`).
	-- Where the game does not have them all (the older clients) the plain textures and colors above are used.
	local ATLAS = {
		background = "ui-castingbar-background",
		border = "ui-castingbar-frame",
		fill = "ui-castingbar-filling-standard",
		done = "ui-castingbar-full-standard", -- the bar of a finished cast, used for the stretches of the route that are flown
		spark = "ui-castingbar-pip", -- the edge of the fill
		sparkGlow = "cast_standard_pipglow", -- trails behind the spark
		barMask = "cast_standard_barmask", -- the shape of the bar, what trails behind the spark is cut to it
		pip = "UI-HUD-ExperienceBar-Frame-Pip", -- the notch of the experience bar where the rested experience ends, used for the taxi nodes and for where the clock says we are
		pipHighlight = "UI-HUD-ExperienceBar-Frame-Pip-Mouseover", -- the same when hovered
		pipFlare = "cast-empowered-pipflare", -- flashes as a stage is reached, used as a taxi node is passed
		flash = "ui-castingbar-full-glow-standard", -- flashes as the cast finishes, used as we land
	}

	local useAtlas = false -- if the game has all the atlases above, it is looked up when the bar is made
	local FLASH_SECONDS = 0.4 -- how long the bar stays after landing, for the flash

	---@return boolean
	local function HasAtlases()
		local info = C_Texture and C_Texture.GetAtlasInfo
		if not info then
			return false
		end
		local missing = {} ---@type string[]
		for _, name in pairs(ATLAS) do
			if not info(name) then
				missing[#missing + 1] = name
			end
		end
		if #missing > 0 then
			if SV:GetOption("debug") then
				print(format("|cffFFFF00%s: using legacy bar because of missing atlas: %s.|r", addonName, table.concat(missing, ", ")))
			end
			return false
		end
		return true
	end

	---@type table<VisualizationMode, boolean>
	local MODES = {
		off = true, -- nothing
		stopwatch = true, -- default UI stopwatch
		bar = true, -- bar with time left
		details = true, -- bar with time left and visualization of the checkpoints along the way and progress
	}

	local frame ---@type VisualizationFrame?
	local fill ---@type StatusBar
	local label ---@type FontString
	local delta ---@type FontString How far the flight is from the simulation when debugging, beside the bar so it does not move the time.
	local isOff = false -- if the delta is shown, which it stays at until the flight is close to the simulation again so it does not come and go
	local clockNotch ---@type VisualizationNotch The notch of the clock, when debugging.
	local spark ---@type Texture The edge of the fill.
	local sparkGlow ---@type Texture
	local flash ---@type Texture
	local flashAnim ---@type AnimationGroup
	local flashToken = 0 -- tells the hiding that waits for the flash if it is still the one that should happen
	local done ---@type Texture What is flown of the route up to the last taxi node we passed.
	local notches = {} ---@type VisualizationNotch[]

	local flight ---@type TaxiTimerLib-1.0_FlightInfo?
	local checkpoints ---@type TaxiTimerLib-1.0_FlightCheckpoint[]?
	local endTime ---@type number? `GetTime()` when the time left runs out.
	local startTime ---@type number? `GetTime()` when the flight was first seen going.
	local elapsed = 0 -- seconds of the flight that were flown according to the simulation
	local elapsedAt = 0 -- `GetTime()` when `elapsed` was set
	local hovered ---@type VisualizationNotch? The notch the tooltip is shown for.
	local hoveredAt = 0 -- `GetTime()` when the tooltip was made
	local shown = 0 -- seconds of the flight the bar is filled up to, which runs on between the times we get to know where we are

	local activeMode ---@type VisualizationMode? The mode the flight that is going on (or the last one) began with.

	---@return VisualizationMode
	local function GetSanitizedMode()
		local mode = SV:GetOption("mode")
		return mode and MODES[mode] and mode or "stopwatch"
	end

	Visualization = {}

	---@param node TaxiTimerLib-1.0_FlightCheckpoint
	local function CheckpointName(node)
		return node.name or format("#%d", node.nodeID)
	end

	---@param self VisualizationNotch
	local function NotchOnEnter(self)
		if not flight or not checkpoints then
			return
		end
		local checkpoint = self.checkpoint
		hovered, hoveredAt = self, GetTime()
		if self.highlight and self.line:IsShown() then
			self.highlight:Show()
		end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if self.number == 1 then
			GameTooltip:AddLine(format("Departed from %s", CheckpointName(checkpoint)), 1, 1, 1)
		else
			GameTooltip:AddLine(CheckpointName(checkpoint), 1, 1, 1)
			if elapsed >= checkpoint.time then
				GameTooltip:AddLine("Reached", unpack(DONE_TINT))
			else
				GameTooltip:AddLine(format("%s until it is reached", lib.GameAPI.FormatDuration(ceil(checkpoint.time - elapsed), true)), 0.8, 0.8, 0.8)
				-- asking to land early ends the flight at the next taxi node
				if self.number < #checkpoints and (self.number == 2 or checkpoints[self.number - 1].time <= elapsed) then
					GameTooltip:AddLine("Request Stop: land at this Flight Master.", 1, 0.82, 0)
				end
			end
		end
		GameTooltip:Show()
	end

	-- the tooltip of the notch of the clock, which tells how far the flight is from the simulation
	---@param self VisualizationNotch
	local function ClockOnEnter(self)
		hovered, hoveredAt = self, GetTime()
		if not startTime then
			return
		end
		local flown = GetTime() - startTime
		local behind = flown - elapsed
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Clock", 1, 0.25, 0.25)
		GameTooltip:AddLine(format("%s flown, the simulation says %s", lib.GameAPI.FormatDuration(floor(flown), true), lib.GameAPI.FormatDuration(floor(elapsed), true)), 0.8, 0.8, 0.8)
		GameTooltip:AddLine(format("%.1f sec %s the simulation", abs(behind), behind >= 0 and "behind" or "ahead of"), 1, 1, 1)
		GameTooltip:Show()
	end

	local function NotchOnLeave(self)
		if self.highlight then
			self.highlight:Hide()
		end
		hovered = nil
		GameTooltip:Hide()
	end

	local SNAP_CENTER = 15 -- how close to the middle of the screen (in pixels, horizontally or vertically) the bar is pulled to it
	local SNAP_STEP = 10 -- the pixels the bar moves in anywhere else

	local drag ---@type { cursorX: number, cursorY: number, x: number, y: number }? Where the cursor and the bar were as the dragging began, the bar is `x` and `y` from the middle of the screen.

	---@param value number How far from the middle of the screen the bar is on one axis.
	---@return number
	local function Snap(value)
		if abs(value) < SNAP_CENTER then
			return 0
		end
		return floor(value / SNAP_STEP + 0.5) * SNAP_STEP
	end

	-- The cursor position accounting for UI scale.
	local function GetCursor()
		local x, y = GetCursorPosition()
		local scale = UIParent:GetEffectiveScale()
		return x / scale, y / scale
	end

	-- The bar follows the cursor while dragging with snapping support.
	local function DragUpdate()
		if not drag or not frame then
			return
		end
		local cursorX, cursorY = GetCursor()
		local x = Snap(drag.x + cursorX - drag.cursorX)
		local y = Snap(drag.y + cursorY - drag.cursorY)
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
	end

	-- Drag start writes the origin of the frame with additional data.
	local function DragStart()
		if not frame or not IsShiftKeyDown() then
			return
		end
		local centerX, centerY = frame:GetCenter()
		local parentX, parentY = UIParent:GetCenter()
		local cursorX, cursorY = GetCursor()
		drag = { cursorX = cursorX, cursorY = cursorY, x = centerX - parentX, y = centerY - parentY }
	end

	-- Drag end stores the final position in the user options.
	local function DragStop()
		if not drag or not frame then
			return
		end
		DragUpdate()
		drag = nil
		local point, _, relativePoint, x, y = frame:GetPoint()
		SV:SetOption("bar", { point, relativePoint, x, y })
	end

	local function CreateFrames()
		local f = CreateFrame("Frame", nil, UIParent) ---@class VisualizationFrame : Frame
		f:SetSize(BAR_WIDTH, BAR_HEIGHT)
		f:SetFrameStrata("HIGH")
		f:SetClampedToScreen(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", DragStart)
		f:SetScript("OnDragStop", DragStop)

		useAtlas = HasAtlases()

		local background = f:CreateTexture(nil, "BACKGROUND")
		if useAtlas then
			background:SetAtlas(ATLAS.background)
			background:SetPoint("TOPLEFT", -1, 1)
			background:SetPoint("BOTTOMRIGHT", 1, -1)
		else
			background:SetAllPoints()
			background:SetTexture(WHITE_TEXTURE)
			background:SetVertexColor(0, 0, 0, 0.6)
		end

		fill = CreateFrame("StatusBar", nil, f)
		fill:SetAllPoints()
		fill:SetMinMaxValues(0, 1)
		fill:SetValue(0)
		if useAtlas then
			fill:SetStatusBarTexture(ATLAS.fill)
		else
			fill:SetStatusBarTexture(BAR_TEXTURE)
			fill:SetStatusBarColor(unpack(FILL_COLOR))
		end

		-- what is drawn over the fill
		local overlay = CreateFrame("Frame", nil, f)
		overlay:SetAllPoints()
		overlay:SetFrameLevel(fill:GetFrameLevel() + 2)

		if useAtlas then
			local border = overlay:CreateTexture(nil, "ARTWORK")
			border:SetAtlas(ATLAS.border)
			border:SetPoint("TOPLEFT", -2, 2)
			border:SetPoint("BOTTOMRIGHT", 2, -2)

			-- the glow behind the spark does not reach out of the bar at its ends, so they are in a frame that clips what is in it
			local clip = CreateFrame("Frame", nil, f)
			clip:SetAllPoints()
			clip:SetClipsChildren(true)
			clip:SetFrameLevel(fill:GetFrameLevel() + 1)
			local sparkFrame = CreateFrame("Frame", nil, clip)
			sparkFrame:SetAllPoints()

			sparkGlow = sparkFrame:CreateTexture(nil, "OVERLAY", nil, 1)
			sparkGlow:SetAtlas(ATLAS.sparkGlow)
			sparkGlow:SetBlendMode("ADD")
			sparkGlow:SetSize(37, 12)

			-- the glow is cut to the shape of the bar, as the casting bar does with its `BorderMask` (the spark itself is taller than the bar on purpose)
			local maskInfo = C_Texture.GetAtlasInfo(ATLAS.barMask)
			if maskInfo and maskInfo.file then
				local mask = sparkFrame:CreateMaskTexture()
				mask:SetTexture(maskInfo.file, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
				mask:SetTexCoord(maskInfo.leftTexCoord, maskInfo.rightTexCoord, maskInfo.topTexCoord, maskInfo.bottomTexCoord)
				mask:SetPoint("TOPLEFT", fill, "TOPLEFT")
				mask:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
				sparkGlow:AddMaskTexture(mask)
			end

			spark = sparkFrame:CreateTexture(nil, "OVERLAY", nil, 2)
			spark:SetAtlas(ATLAS.spark)
			spark:SetSize(8, 20)

			sparkGlow:SetPoint("RIGHT", spark, "LEFT", 2, 0)

			-- flashes as we land
			flash = overlay:CreateTexture(nil, "OVERLAY")
			flash:SetAtlas(ATLAS.flash)
			flash:SetBlendMode("ADD")
			flash:SetPoint("TOPLEFT", -1, 1)
			flash:SetPoint("BOTTOMRIGHT", 1, -1)
			flash:SetAlpha(0)
			flashAnim = flash:CreateAnimationGroup()
			flashAnim:SetToFinalAlpha(true)
			local fadeIn = flashAnim:CreateAnimation("Alpha")
			fadeIn:SetFromAlpha(0)
			fadeIn:SetToAlpha(1)
			fadeIn:SetDuration(0.15)
			fadeIn:SetOrder(1)
			local fadeOut = flashAnim:CreateAnimation("Alpha")
			fadeOut:SetFromAlpha(1)
			fadeOut:SetToAlpha(0)
			fadeOut:SetDuration(FLASH_SECONDS - 0.15)
			fadeOut:SetOrder(2)
		end

		-- the time is in a frame above everything else on the bar, so a taxi node or the notch of the clock passing it does not cover it
		local text = CreateFrame("Frame", nil, f)
		text:SetAllPoints()
		text:SetFrameLevel(f:GetFrameLevel() + 20)
		label = text:CreateFontString(nil, "OVERLAY", "SystemFont_Shadow_Med2")
		label:SetPoint("CENTER")
		label:SetTextColor(1, 1, 1)

		delta = f:CreateFontString(nil, "OVERLAY", "SystemFont_Shadow_Med2")
		delta:SetPoint("LEFT", f, "RIGHT", 6, 0)
		delta:SetTextColor(1, 0.25, 0.25)

		-- where the simulation says we are when the flight is going by the clock alone, to compare with where we are going by our position
		clockNotch = CreateFrame("Frame", nil, f) ---@class VisualizationNotch
		clockNotch:SetSize(10, BAR_HEIGHT + 1)
		clockNotch:SetFrameLevel(overlay:GetFrameLevel() + 6)
		clockNotch:EnableMouse(true)
		clockNotch:SetScript("OnEnter", ClockOnEnter)
		clockNotch:SetScript("OnLeave", NotchOnLeave)
		clockNotch:Hide()
		local clockNotchLine = clockNotch:CreateTexture(nil, "OVERLAY")
		if useAtlas then
			clockNotchLine:SetAtlas(ATLAS.pip, true)
		else
			clockNotchLine:SetTexture(WHITE_TEXTURE)
			clockNotchLine:SetSize(2, BAR_HEIGHT)
		end
		clockNotchLine:SetVertexColor(1, 0.2, 0.2, 1)
		clockNotchLine:SetPoint("CENTER")

		-- what is flown of the route up to the last taxi node we passed, cut off where that is the way the experience bar cuts off what it predicts
		done = fill:CreateTexture(nil, "ARTWORK", nil, 1)
		if useAtlas then
			done:SetAtlas(ATLAS.done)
			done:SetDesaturated(true)
			done:SetVertexColor(unpack(DONE_TINT))
		else
			done:SetTexture(BAR_TEXTURE)
			done:SetVertexColor(unpack(DONE_COLOR))
		end
		done:SetPoint("TOPLEFT", fill, "TOPLEFT")
		done:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT")
		done:Hide()

		f:SetScript("OnUpdate", function()
			DragUpdate()
			Visualization:Refresh()
		end)

		local saved = SV:GetOption("bar")
		f:ClearAllPoints()
		f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])

		return f
	end

	---@param newMode VisualizationMode?
	---@return boolean ok
	function Visualization:SetMode(newMode)
		if type(newMode) ~= "string" or not MODES[newMode] then
			return false
		end
		SV:SetOption("mode", newMode) -- a flight that is going on keeps the mode it began with, the next one uses this
		return true
	end

	-- The mode of the flight that is going on, or of the last one, as it is looked up when a flight starts so changing it does not change a flight on its way.
	---@return VisualizationMode
	function Visualization:GetMode()
		activeMode = activeMode or GetSanitizedMode()
		return activeMode
	end

	-- If the stopwatch is used in place of the bar.
	function Visualization:IsStopwatchEnabled()
		local mode = self:GetMode()
		return mode == "stopwatch"
	end

	-- If the bar is shown in place of the stopwatch.
	---@return boolean
	function Visualization:IsBarEnabled()
		local mode = self:GetMode()
		return mode == "bar" or mode == "details"
	end

	-- Lays out the bar for the flight we have.
	function Visualization:Build()
		local info = flight

		if not info or not self:IsBarEnabled() then
			if frame then
				frame:Hide()
			end
			return
		end

		frame = frame or CreateFrames()
		checkpoints = checkpoints or lib.GetFlightCheckpoints(info)

		local mode = self:GetMode()

		local width = frame:GetWidth()
		local numCheckpoints = #checkpoints
		flashToken = flashToken + 1
		if flashAnim then
			flashAnim:Stop()
			flash:SetAlpha(0)
		end
		if spark then
			spark:Show()
			sparkGlow:Show()
		end

		done:Hide()

		for i = 1, #notches do
			notches[i]:Hide()
		end

		if mode == "details" then
			-- a notch at each taxi node of the route, the first is where we start and the last is where we land
			for i = 1, numCheckpoints do
				local notch = notches[i]
				if not notch then
					notch = CreateFrame("Frame", nil, frame) --[[@as VisualizationNotch]]
					notch:SetSize(10, BAR_HEIGHT + 1)
					notch:SetScript("OnEnter", NotchOnEnter)
					notch:SetScript("OnLeave", NotchOnLeave)
					notch:RegisterForDrag("LeftButton")
					notch:SetScript("OnDragStart", DragStart)
					notch:SetScript("OnDragStop", DragStop)
					local line = notch:CreateTexture(nil, "OVERLAY")
					notch.line = line
					if useAtlas then
						line:SetAtlas(ATLAS.pip, true)
						notch.highlight = notch:CreateTexture(nil, "OVERLAY", nil, 1)
						notch.highlight:SetAtlas(ATLAS.pipHighlight, true)
						notch.highlight:SetBlendMode("ADD")
						notch.highlight:SetPoint("CENTER")
						notch.highlight:Hide()
						notch.flare = notch:CreateTexture(nil, "OVERLAY", nil, 2)
						notch.flare:SetAtlas(ATLAS.pipFlare, true)
						notch.flare:SetScale(0.5)
						notch.flare:SetBlendMode("ADD")
						notch.flare:SetPoint("CENTER")
						notch.flare:SetAlpha(0)
						notch.flareAnim = notch.flare:CreateAnimationGroup()
						notch.flareAnim:SetToFinalAlpha(true)
						local up = notch.flareAnim:CreateAnimation("Alpha")
						up:SetFromAlpha(0.1)
						up:SetToAlpha(1)
						up:SetDuration(0.1)
						up:SetOrder(1)
						local down = notch.flareAnim:CreateAnimation("Alpha")
						down:SetFromAlpha(1)
						down:SetToAlpha(0)
						down:SetDuration(0.25)
						down:SetOrder(2)
					else
						line:SetTexture(WHITE_TEXTURE)
						line:SetVertexColor(1, 1, 1, 0.9)
						line:SetSize(2, BAR_HEIGHT)
					end
					line:SetPoint("CENTER")
					notches[i] = notch
				end
				notch.checkpoint, notch.number = checkpoints[i], i
				notch.line:SetShown(i > 1 and i < numCheckpoints) -- the ends of the bar are where the flight starts and lands, so they only have the tooltip
				notch.passed = elapsed >= checkpoints[i].time -- the flash is for the ones we pass from here on
				notch:EnableMouse(true)
				notch:ClearAllPoints()
				notch:SetPoint("CENTER", fill, "LEFT", checkpoints[i].time / info.duration * width, 0)
				notch:SetFrameLevel(frame:GetFrameLevel() + 5)
				notch:Show()
			end
		end

		frame:Show()
		self:Refresh()
	end

	---@param info TaxiTimerLib-1.0_FlightInfo
	function Visualization:Start(info)
		activeMode = GetSanitizedMode()
		flight, checkpoints = info, nil
		endTime, startTime, elapsed, elapsedAt, shown = nil, nil, 0, 0, 0
		if frame then
			fill:SetValue(0)
		end
		self:Build()
	end

	-- `finished` if the flight ended by us landing, then the bar flashes before it goes.
	---@param finished? boolean
	function Visualization:Stop(finished)
		local wasFlying = flight ~= nil
		flight, checkpoints, endTime, startTime = nil, nil, nil, nil
		if hovered then
			hovered = nil
			GameTooltip:Hide()
		end
		if not frame then
			return
		end
		flashToken = flashToken + 1
		if finished and wasFlying and frame:IsShown() then
			fill:SetValue(1)
			if spark then
				spark:Hide() -- the casting bar does not show it when the cast is done
				sparkGlow:Hide()
			end
			if flashAnim then
				flashAnim:Stop()
				flashAnim:Play()
			end
			local token = flashToken
			C_Timer.After(FLASH_SECONDS, function()
				if token == flashToken and frame then
					frame:Hide()
				end
			end)
		else
			frame:Hide()
		end
	end

	---@param seconds number
	function Visualization:SetTimeLeft(seconds)
		-- the time left that is shown is kept up to date by `SetProgress`, so the stopwatch corrections only give it a start and do not override it
		if not endTime then
			endTime = GetTime() + seconds
		end
	end

	---@return number seconds
	function Visualization:GetTimeLeft()
		return endTime and max(endTime - GetTime(), 0) or 0
	end

	-- Tells where we are in the flight according to the simulation, as the seconds left of it.
	---@param seconds number
	function Visualization:SetProgress(seconds)
		local info = flight
		if not info then
			return
		end
		startTime = startTime or GetTime()
		elapsed = min(max(info.duration - seconds, 0), info.duration)
		elapsedAt = GetTime()
		if not self:IsStopwatchEnabled() then
			endTime = GetTime() + seconds
		end
	end

	function Visualization:Refresh()
		local info = flight
		if not frame or not info then
			return
		end
		-- where we are is only known every half second, so the bar goes on at the speed of the simulation until then, and never back unless the position says we were well ahead
		local target = min(elapsed + min(GetTime() - elapsedAt, 0.75), info.duration)
		shown = (target >= shown or shown - target > 1) and target or shown
		fill:SetValue(shown / info.duration)
		if spark then
			-- the spark stays inside the bar, the glow behind it is as long as it is and what is outside the bar is cut off by the frame it is in, with the border over the cut
			local width = frame:GetWidth()
			local x = min(max(shown / info.duration * width, 4), width - 4)
			spark:ClearAllPoints()
			spark:SetPoint("CENTER", fill, "LEFT", x, 0)
		end
		local seconds = endTime and max(endTime - GetTime(), 0)
		-- rounded up so it does not show 0:00 for the last second of the flight
		local text = seconds and lib.GameAPI.FormatDuration(ceil(seconds), true) or ""
		label:SetText(text)
		-- when debugging, how many seconds the flight is behind (+) or ahead (-) of the simulation, which is how far the red notch is from the end of the fill
		if startTime and SV:GetOption("debug") then
			local behind = GetTime() - startTime - elapsed
			isOff = abs(behind) >= (isOff and 0.5 or 1)
			delta:SetText(isOff and format("%+d", floor(behind + 0.5)) or "")
		else
			isOff = false
			delta:SetText("")
		end
		if hovered and GetTime() - hoveredAt > 0.2 then
			if hovered == clockNotch then
				ClockOnEnter(clockNotch)
			else
				NotchOnEnter(hovered)
			end
		end
		if checkpoints and self:GetMode() == "details" then
			-- up to the last taxi node we passed
			local passed = 0
			for i = 2, #checkpoints do
				if elapsed >= checkpoints[i].time then
					passed = checkpoints[i].time
				end
			end
			local width = frame:GetWidth()
			local x = min(passed / info.duration, 1) * width
			if x > 0 then
				done:SetWidth(x)
				done:SetTexCoord(0, x / width, 0, 1)
				done:Show()
			else
				done:Hide()
			end
			for i = 1, #notches do
				local notch = notches[i]
				if notch.checkpoint and not notch.passed and notch:IsShown() and elapsed >= notch.checkpoint.time then
					notch.passed = true
					if notch.flareAnim then
						notch.flareAnim:Stop()
						notch.flareAnim:Play()
					end
				end
			end
		end
		if startTime and SV:GetOption("debug") then
			clockNotch:ClearAllPoints()
			clockNotch:SetPoint("CENTER", fill, "LEFT", min((GetTime() - startTime) / info.duration, 1) * frame:GetWidth(), 0)
			clockNotch:Show()
		else
			clockNotch:Hide()
		end
	end

end

---@class Timer
local Timer do

	Timer = {}

	---@param seconds number
	---@param override? boolean
	function Timer:Start(seconds, override)
		if not Visualization:IsStopwatchEnabled() then
			Visualization:SetTimeLeft(seconds)
			return
		end
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

	---@param finished? boolean If the flight ended by us landing.
	function Timer:Stop(finished)
		Visualization:Stop(finished)
		if not Visualization:IsStopwatchEnabled() then
			return
		end
		Stopwatch_Clear()
		StopwatchFrame:Hide()
	end

	function Timer:Get()
		if not Visualization:IsStopwatchEnabled() then
			return Visualization:GetTimeLeft()
		end
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
	---@field public flavor? TaxiTimerLib-1.0_GameFlavor The game the flight was recorded on, named like its db file.
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
	---@field public info TaxiTimerLib-1.0_FlightInfo
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

	---@param points TaxiTimerLib-1.0_TaxiPathNode[]
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
	---@param info TaxiTimerLib-1.0_FlightInfo
	function Recorder:Start(state, info)
		current = nil
		if not SV:GetOption("record") then
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
				flavor = lib.Sim.FLAVOR,
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
	if TaxiRequestEarlyLanding then
		hooksecurefunc("TaxiRequestEarlyLanding", function()
			if not SV:GetOption("record") then
				return
			end
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
		SV:AddFlight(record)
		SV:TrimFlights(RECORD_MAX_FLIGHTS)
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

	-- Returns the speed we fly at, but never less than the taxi map is flown at as it is lower while taking off and landing.
	---@param areaID? number
	---@param speedModifier? number
	---@return number
	local function GetLiveSpeed(areaID, speedModifier)
		local speed = lib.Speed(areaID) * (speedModifier or 1)

		if not areaID then
			return speed
		end

		return max(GetUnitSpeed("player"), speed)
	end

	-- Checks if we left the taxi because the flight is changing to the map of its destination, and not because the flight ended.
	---@param info TaxiTimerLib-1.0_FlightInfo
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
	---@param info TaxiTimerLib-1.0_FlightInfo
	function GPS:Start(state, info)
		-- any previous flight is stopped before the stopwatch is started for this flight
		if Ticker then
			Timer:Stop()
			Ticker:Cancel()
		end
		Visualization:Start(info)
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
							GPSInfo.timeLeft = lib.GetFlightTimeLeft(info, GPSInfo.distance)
							local simulatedTimeLeft = GPSInfo.timeLeft
							if not info.dynamicSpeed then
								GPSInfo.timeLeft = GPSInfo.timeLeft * areaSpeed / GPSInfo.speed
							end
							Visualization:SetProgress(simulatedTimeLeft)
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
				Timer:Stop(true)
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

---@class State : TaxiTimerLib-1.0_TaxiMap
local State do

	---@class State
	---@field public to? TaxiNodeInfo The taxi node the player points at or clicks on.
	---@field public gps? FunctionContainer

	---@class TaxiButton : Button
	---@field public taxiNodeData TaxiNodeInfo

	-- we utilize the library to keep track of the taxi map state (we just have to hook it up and call the API that updates the state)
	State = setmetatable({}, { __index = function(_, key) return lib.GameAPI.TaxiMap[key] end }) ---@type State

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
			if self.from ~= self.to and SV:GetOption("debug") then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(format("No taxi data for map: %s (%d nodes)", tostring(self.areaID), #self.nodes), 0.8, 0.8, 0.8, true)
				GameTooltip:AddLine(format("From: %s", self.from and self.from.name or "N/A"), 0.8, 0.8, 0.8, true)
				GameTooltip:AddLine(format("To: %s", self.to and self.to.name or "N/A"), 0.8, 0.8, 0.8, true)
				GameTooltip:Show()
			end
			return
		end
		if SV:GetOption("debug") then
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
			GameTooltip:AddLine(format("Recording: %s", SV:GetOption("record") and "Yes" or "No"), 0.8, 0.8, 0.8, false)
			GameTooltip:AddLine(" ")
		end
		GameTooltip:AddLine(format("~ %s flight time", lib.GameAPI.FormatDuration(info.duration, true)), 1, 1, 1, false)
		GameTooltip:Show()
	end

	function State:PlotCourse()
		local info = self:GetFlightInfo()
		if not info then
			return
		end
		GPS:Start(self, info)
	end

	---@return TaxiTimerLib-1.0_FlightInfo?
	function State:GetFlightInfo()
		return lib.GameAPI.GetFlightInfoToNode(self.to)
	end

	---@param forceUpdate? boolean
	function State:Update(forceUpdate)
		if lib.GameAPI.UpdateTaxiMap(forceUpdate) then
			self.to = nil
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
	---@param ... any
	local function OnEvent(self, event, ...)

		if event == "ADDON_LOADED" and ... == addonName then
			SV:Init()
		end

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

	_G[format("SLASH_%s1", addonName)] = "/taxitimer"

	---@param message string?
	SlashCmdList[addonName] = function(message)
		---@type "debug"|"record"|"mode"?, string
		local command, arg1 = strmatch(strlower(message or ""), "^%s*(%S+)%s*(%S*)")
		if command then
			if command == "debug" or command == "record" then
				local newValue = not SV:GetOption(command)
				SV:SetOption(command, newValue)
				print(format("|cffFFFF00%s %s %s.|r", addonName, command, newValue and "enabled" or "disabled"))
				return
			elseif command == "mode" then
				if Visualization:SetMode(arg1) then
					print(format("|cffFFFF00%s shows flights as: %s.|r", addonName, arg1))
				else
					print(format("|cffFFFF00%s modes: off, stopwatch, bar, details.|r", addonName))
				end
				return
			end
		end
		print(format("|cffFFFF00%s commands:|r", addonName))
		print(format("    |cffFFFF00mode|r    (%s) Flight timer style.", tostring(SV:GetOption("mode"))))
		print(format("    |cffFFFF00debug|r   (%s) Enable destination tooltip information.", tostring(SV:GetOption("debug"))))
		print(format("    |cffFFFF00record|r  (%s) Records flights for later analysis.", tostring(SV:GetOption("record"))))
	end

end

-- TaxiTimerAPI
-- This is a global legacy variable that you may continue to use.
-- You may also use the `LibStub("TaxiTimerLib-1.0")` approach instead.
---@class TaxiTimerAPI
_G.TaxiTimerAPI = {
	GetNodeFromSlotIndex = function(...) return lib.GameAPI.GetNodeFromSlotIndex(...) end,
	GetFlightInfo = function(...) return lib.GameAPI.GetFlightInfo(...) end,
	GetFlightTime = function(...) return lib.GameAPI.GetFlightTime(...) end,
}
