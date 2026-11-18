local addonName = ... ---@type string

local TTL = LibStub("TaxiTimerLib-1.0") ---@type TaxiTimerLib-1.0

---@param text string
local function print(text, ...)
	DEFAULT_CHAT_FRAME:AddMessage(format(text, ...), 1, 1, 0)
end

-- Get the name of a taxi node.
---@param node TaxiTimerLib-1.0_FlightCheckpoint|TaxiTimerLib-1.0_TaxiRouteNode|TaxiNodeInfo
---@return string
local function NodeName(node)
	return node.name or format("#%d", node.nodeID)
end

---@class SV
local SV do

	---@class TaxiTimerDBOptions
	---@field public debug boolean Enable debug which may display additional elements.
	---@field public record boolean Enable dumping of flight records for later anaysis.
	---@field public mode VisualizationMode How the flight is shown.
	---@field public bar VisualizationBarPoint
	---@field public timer boolean If the bar shows the time left.
	---@field public timerPosition FramePoint The position of the time left.
	---@field public timerOutline boolean If the time left has an outline.
	---@field public destination boolean If the bar shows where the flight goes.
	---@field public destinationPosition FramePoint
	---@field public destinationOutline boolean If the destination has an outline.
	---@field public checkpoints boolean If the bar shows the taxi nodes along the way.

	---@alias TaxiTimerDBFlights FlightRecord[]

	---@class TaxiTimerDB
	---@field public options TaxiTimerDBOptions
	---@field public flights TaxiTimerDBFlights

	SV = {}

	---@type TaxiTimerDB
	local TaxiTimerDBDefaults = {
		options = {
			debug = false,
			record = false,
			mode = "bar",
			bar = { "TOP", "TOP", 0, -110 },
			timer = true,
			timerPosition = "CENTER",
			timerOutline = false,
			destination = false,
			destinationPosition = "TOP",
			destinationOutline = false,
			checkpoints = false,
		},
		flights = {},
	}

	---@generic T extends table
	---@param tbl T
	---@return T
	local function CopyTable(tbl)
		local copy = {} ---@type T[]
		for k, v in pairs(tbl) do
			if type(v) == "table" then
				copy[k] = CopyTable(v)
			else
				copy[k] = v
			end
		end
		return copy
	end

	-- The assumption is that we call this when the addon loads, and that the user can't realistically interact with anything in-game before this happens anyway so we are in no danger of using the SV before the addon load event occurs.
	function SV:Init()
		if type(TaxiTimerDB) ~= "table" then
			TaxiTimerDB = CopyTable(TaxiTimerDBDefaults)
		end
		for k, v in pairs(TaxiTimerDBDefaults) do
			if type(TaxiTimerDB[k]) ~= "table" then
				TaxiTimerDB[k] = CopyTable(v)
			end
		end
		local options = TaxiTimerDB.options
		setmetatable(options, { __index = TaxiTimerDBDefaults.options })
		-- upgrade "details" into "bar" mode and adjust key settings to match the old details behavior
		if rawget(options, "mode") == "details" then
			options.mode = "bar"
			options.checkpoints = true
		end
	end

	---@generic T extends keyof TaxiTimerDB
	---@param key T
	---@return TaxiTimerDB[T]
	function SV:Get(key)
		return TaxiTimerDB[key]
	end

	---@return TaxiTimerDBOptions
	function SV:GetOptions()
		return self:Get("options")
	end

	---@generic T extends keyof TaxiTimerDBOptions
	---@param key T
	---@return TaxiTimerDBOptions[T]
	function SV:GetDefaultOption(key)
		return TaxiTimerDBDefaults.options[key]
	end

	---@param flight FlightRecord
	function SV:AddFlight(flight)
		local flights = self:Get("flights")
		flights[#flights + 1] = flight
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

	---@alias VisualizationMode "off"|"stopwatch"|"bar"

	---@alias VisualizationBarPoint { [1]: FramePoint, [2]: FramePoint, [3]: number, [4]: number }

	local BAR_FULL_SOUND = 12889 -- when you fill the flight bar

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
				print("%s is using legacy bar because of missing atlas: |cffFFFFFF%s|r.", addonName, table.concat(missing, "|r, |cffFFFFFF"))
			end
			return false
		end
		return true
	end

	-- How the bar looks. The parts of it that differ between the casting bar of the game (with its atlases) and the plain textures and colors for the games that do not have them are all here, so the rest of the code does not have to know which one is used.
	-- `skin` is the one in use, chosen when the bar is made.
	---@class VisualizationSkin
	---@field Background fun(frame: Frame) The background of the bar.
	---@field Fill fun(fill: StatusBar) The texture and color of what is flown.
	---@field Overlay fun(frame: Frame, fill: StatusBar, overlay: Frame): Texture?, Texture?, Texture?, AnimationGroup? What is drawn over the fill: its border, and the spark, the glow behind it, the flash as we land and its animation (the last four are nil where the skin has none).
	---@field Done fun(fill: StatusBar): Texture What is flown of the route up to the last taxi node we passed.
	---@field Pip fun(texture: Texture) The mark of a taxi node, the clock or the stop.
	---@field NotchExtras fun(notch: VisualizationNotch) What a notch has besides its mark: the highlight as it is hovered and the flare as it is passed.

	---@type VisualizationSkin
	local AtlasSkin = {
		Background = function(frame)
			local background = frame:CreateTexture(nil, "BACKGROUND")
			background:SetAtlas(ATLAS.background)
			background:SetPoint("TOPLEFT", -1, 1)
			background:SetPoint("BOTTOMRIGHT", 1, -1)
		end,
		Fill = function(fill)
			fill:SetStatusBarTexture(ATLAS.fill)
		end,
		Overlay = function(frame, fill, overlay)
			local border = overlay:CreateTexture(nil, "ARTWORK")
			border:SetAtlas(ATLAS.border)
			border:SetPoint("TOPLEFT", -2, 2)
			border:SetPoint("BOTTOMRIGHT", 2, -2)

			-- the glow behind the spark does not reach out of the bar at its ends, so they are in a frame that clips what is in it
			local clip = CreateFrame("Frame", nil, frame)
			clip:SetAllPoints()
			clip:SetClipsChildren(true)
			clip:SetFrameLevel(fill:GetFrameLevel() + 1)
			local sparkFrame = CreateFrame("Frame", nil, clip)
			sparkFrame:SetAllPoints()

			local sparkGlow = sparkFrame:CreateTexture(nil, "OVERLAY", nil, 1)
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

			local spark = sparkFrame:CreateTexture(nil, "OVERLAY", nil, 2)
			spark:SetAtlas(ATLAS.spark)
			spark:SetSize(8, 20)

			sparkGlow:SetPoint("RIGHT", spark, "LEFT", 2, 0)

			-- flashes as we land
			local flash = overlay:CreateTexture(nil, "OVERLAY")
			flash:SetAtlas(ATLAS.flash)
			flash:SetBlendMode("ADD")
			flash:SetPoint("TOPLEFT", -1, 1)
			flash:SetPoint("BOTTOMRIGHT", 1, -1)
			flash:SetAlpha(0)
			local flashAnim = flash:CreateAnimationGroup()
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

			return spark, sparkGlow, flash, flashAnim
		end,
		Done = function(fill)
			local done = fill:CreateTexture(nil, "ARTWORK", nil, 1)
			done:SetAtlas(ATLAS.done)
			done:SetDesaturated(true)
			done:SetVertexColor(DONE_TINT[1], DONE_TINT[2], DONE_TINT[3])
			return done
		end,
		Pip = function(texture)
			texture:SetAtlas(ATLAS.pip, true)
		end,
		NotchExtras = function(notch)
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
		end,
	}

	---@type VisualizationSkin
	local PlainSkin = {
		Background = function(frame)
			local background = frame:CreateTexture(nil, "BACKGROUND")
			background:SetAllPoints()
			background:SetTexture(WHITE_TEXTURE)
			background:SetVertexColor(0, 0, 0, 0.6)
		end,
		Fill = function(fill)
			fill:SetStatusBarTexture(BAR_TEXTURE)
			fill:SetStatusBarColor(FILL_COLOR[1], FILL_COLOR[2], FILL_COLOR[3], FILL_COLOR[4])
		end,
		Overlay = function()
			return nil, nil, nil, nil -- no border, spark or flash
		end,
		Done = function(fill)
			local done = fill:CreateTexture(nil, "ARTWORK", nil, 1)
			done:SetTexture(BAR_TEXTURE)
			done:SetVertexColor(DONE_COLOR[1], DONE_COLOR[2], DONE_COLOR[3], DONE_COLOR[4])
			return done
		end,
		Pip = function(texture)
			texture:SetTexture(WHITE_TEXTURE)
			texture:SetSize(2, BAR_HEIGHT)
		end,
		NotchExtras = function(notch)
			notch.line:SetVertexColor(1, 1, 1, 0.9)
		end,
	}

	local skin = PlainSkin ---@type VisualizationSkin

	---@type table<VisualizationMode, boolean>
	local MODES = {
		off = true, -- nothing
		stopwatch = true, -- default UI stopwatch
		bar = true,
	}

	--
	-- MARK: Flight progress
	--

	local TAKEOFF_LAG = 0.25 -- seconds, we find out we are on the taxi on a tick of the GPS, which is half a tick (0.5 s) late on average
	local RUN_ON = 0.75 -- seconds the bar goes on at the speed of the simulation between the times we get to know where we are
	local RUN_ON_FIRST = 1.5 -- the same until the first position is known, which takes two ticks of the GPS (the distance is the step from the one before)
	local STOP_GRACE = 3 -- seconds past the stop we can be, the simulation being off by a bit, before we know it was missed

	-- Where we are in the flight that is going on, and what that says about the time. It has no widgets and makes no game calls (the time is given), so it can be tried without the game.
	---@class VisualizationProgress
	---@field public flight? TaxiTimerLib-1.0_FlightInfo
	---@field public checkpoints? TaxiTimerLib-1.0_FlightCheckpoint[]
	---@field public startTime? number When the flight began, which is when the clock notch starts too.
	---@field public positioned boolean If we know where we are in the flight yet, which is only after the first two ticks of the GPS.
	---@field public elapsed number Seconds of the flight that were flown according to the simulation.
	---@field public elapsedAt number When `elapsed` was set.
	---@field public shown number Seconds of the flight the bar is filled up to, which runs on between the times we get to know where we are.
	---@field public endTime? number When the time left runs out.
	---@field public stopAt? number The seconds of the flight at which we land after asking to stop.
	---@field public stopIndex? number The checkpoint we land at after asking to stop.
	local Progress = {}
	Progress.__index = Progress

	---@type VisualizationProgress
	local progress = setmetatable({ positioned = false, elapsed = 0, elapsedAt = 0, shown = 0 }, Progress)

	-- A flight is chosen. Nothing runs until we take off, which is some time after.
	---@param info TaxiTimerLib-1.0_FlightInfo
	function Progress:Start(info)
		self.flight, self.checkpoints = info, nil
		self.stopAt, self.stopIndex = nil, nil
		self.endTime, self.startTime = nil, nil
		self.elapsed, self.elapsedAt, self.shown, self.positioned = 0, 0, 0, false
	end

	-- The flight is over.
	function Progress:End()
		self.flight, self.checkpoints, self.endTime, self.startTime = nil, nil, nil, nil
	end

	-- We are flying: the clock begins to run, and until the first position is known (it takes two ticks) the bar runs on at the speed of the simulation.
	---@param now number
	function Progress:Takeoff(now)
		if not self.flight or self.startTime then
			return
		end
		now = now - TAKEOFF_LAG
		self.startTime, self.elapsedAt = now, now
	end

	-- Where we are in the flight according to the simulation, as the seconds left of it.
	---@param seconds number
	---@param now number
	---@param trackEnd boolean If the time left is kept up to date by this too, which it is not when the stopwatch has the time.
	function Progress:SetPosition(seconds, now, trackEnd)
		local info = self.flight
		if not info then
			return
		end
		self.positioned = true
		self.elapsed = min(max(info.duration - seconds, 0), info.duration)
		self.elapsedAt = now
		if trackEnd then
			self.endTime = now + seconds
		end
	end

	-- The time left of the flight from the stopwatch, it is only the first one that is used as `SetPosition` keeps it up to date.
	---@param seconds number
	---@param now number
	function Progress:SetEndTime(seconds, now)
		if not self.endTime then
			self.endTime = now + seconds
		end
	end

	---@param now number
	---@return number seconds
	function Progress:TimeLeftOfEnd(now)
		return self.endTime and max(self.endTime - now, 0) or 0
	end

	-- The taxi nodes of the route and when the flight is at them.
	---@return TaxiTimerLib-1.0_FlightCheckpoint[]
	function Progress:GetCheckpoints()
		if not self.checkpoints and self.flight then
			self.checkpoints = TTL.GetFlightCheckpoints(self.flight)
		end
		return self.checkpoints or {}
	end

	-- The seconds of the flight flown by the simulation as of now. Where we are is only known every half second, so it runs on from there.
	---@param now number
	---@return number
	function Progress:Elapsed(now)
		if not self.flight or not self.startTime then
			return self.elapsed
		end
		return min(self.elapsed + min(now - self.elapsedAt, self.positioned and RUN_ON or RUN_ON_FIRST), self.flight.duration)
	end

	-- The seconds the flight has gone on by the clock, if it has begun.
	---@param now number
	---@return number?
	function Progress:Clock(now)
		if self.startTime then
			return now - self.startTime
		end
	end

	-- Moves what is shown up to where we are, never back unless the position says we were well ahead.
	-- If we asked to stop and are still flying well past it, the stop came too late for that node and the flight goes on as it was (`missed`).
	---@param now number
	---@return number shown
	---@return boolean missed
	function Progress:Advance(now)
		local target = self.startTime and self:Elapsed(now) or 0
		local missed = false
		if self.stopAt then
			if self.positioned and self.elapsed + (now - self.elapsedAt) > self.stopAt + STOP_GRACE then
				self.stopAt, self.stopIndex = nil, nil
				missed = true
			else
				target = min(target, self.stopAt) -- the flight ends there
			end
		end
		if target >= self.shown or self.shown - target > 1 then
			self.shown = target -- a little ahead of where we are it waits for it
		end
		return self.shown, missed
	end

	-- The time left as the bar shows it. Before the first position is known it is the one of the simulation, from where the bar has run to.
	---@param now number
	---@return number seconds
	function Progress:SecondsLeft(now)
		if self.stopAt then
			return max(self.stopAt - self.shown, 0)
		end
		if self.endTime then
			return max(self.endTime - now, 0)
		end
		return max((self.flight and self.flight.duration or 0) - self.shown, 0)
	end

	-- The checkpoint a stop would land at, the next taxi node, if it is not the last (which we land at anyway).
	---@return number? index
	function Progress:NextStop()
		local checkpoints = self.checkpoints
		if not self.flight or not checkpoints or self.stopAt then
			return
		end
		for i = 2, #checkpoints - 1 do
			if checkpoints[i].time > self.shown then
				return i
			end
		end
	end

	---@param index number
	function Progress:SetStop(index)
		local checkpoint = self.checkpoints and self.checkpoints[index]
		if checkpoint then
			self.stopAt, self.stopIndex = checkpoint.time, index
		end
	end

	function Progress:ClearStop()
		self.stopAt, self.stopIndex = nil, nil
	end

	-- The part of the bar that was flown when we land, all of it unless we asked to stop.
	---@return number
	function Progress:Landed()
		return self.stopAt and self.flight and self.stopAt / self.flight.duration or 1
	end

	---@param checkpoint TaxiTimerLib-1.0_FlightCheckpoint
	---@return boolean
	function Progress:HasPassed(checkpoint)
		return self.elapsed >= checkpoint.time
	end

	-- When the flight was at the last taxi node it has passed (not counting the start).
	---@return number seconds
	function Progress:Passed()
		local passed = 0
		local checkpoints = self.checkpoints or {}
		for i = 2, #checkpoints do
			if self.elapsed >= checkpoints[i].time then
				passed = checkpoints[i].time
			end
		end
		return passed
	end

	--
	-- MARK: Widgets
	--

	local STOP_COLOR = { 1, 0.82, 0 } -- the yellow of the stop text in the tooltip of the notches
	local INTERPOLATION = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut -- the smoothing of the status bar, nothing on a client without it

	local activeMode ---@type VisualizationMode? The mode the flight that is going on (or the last one) began with.
	local example ---@type number? When the example was shown, nothing if it is not.
	local exampleLeft = 0 -- the seconds left of the example last time, to tell when it begins again
	local editing = false -- if the Edit Mode is open, which is when the example is shown whenever there is no real flight

	Visualization = {}

	function Visualization:GetSavedMode()
		local mode = SV:GetOption("mode")
		return mode and MODES[mode] and mode or "stopwatch"
	end

	-- The bar and what is on it. `bar:Create` makes all of it together, so while `bar.frame` exists so does the rest and the code that runs with a frame does not nil-check them.
	-- The ones that can be missing (the atlas textures of the spark and the flash) are nilable, and are checked where they are used.
	---@class VisualizationBar
	---@field public frame? VisualizationFrame
	---@field public fill StatusBar
	---@field public label FontString
	---@field public delta FontString How far the flight is from the simulation when debugging, beside the bar so it does not move the time.
	---@field public destination FontString Where the flight goes, above the bar.
	---@field public isOff boolean If the delta is shown, which it stays at until the flight is close to the simulation again so it does not come and go.
	---@field public clockNotch VisualizationNotch The notch of the clock, when debugging.
	---@field public spark? Texture The edge of the fill, not there without the atlases.
	---@field public sparkGlow? Texture The glow behind it.
	---@field public flash? Texture The flash as we land, not there without the atlases.
	---@field public flashAnim? AnimationGroup
	---@field public flashToken number Tells the hiding that waits for the flash if it is still the one that should happen.
	---@field public done Texture What is flown of the route up to the last taxi node we passed.
	---@field public cut Texture What is left of the bar after the taxi node we land at when we ask to stop, it is not flown.
	---@field public stopMarker Texture Where that is.
	---@field public notches VisualizationNotch[]
	---@field public hovered? VisualizationNotch The notch the tooltip is shown for.
	---@field public hoveredAt number `GetTime()` when the tooltip was made.
	local bar = { isOff = false, flashToken = 0, notches = {}, hoveredAt = 0 }

	-- The time left as the bar and its tooltips show it, rounded up so it does not say 00:00 for the last second of the flight.
	---@param seconds number
	---@return string
	local function TimeLeftText(seconds)
		return TTL.GameAPI.FormatDuration(ceil(seconds), true)
	end

	-- The seconds the flight has gone on by the clock, for the clock notch and the delta beside the bar, which are only there when debugging once the flight is going (nothing otherwise).
	---@return number?
	local function ClockSeconds()
		if SV:GetOption("debug") then
			return progress:Clock(GetTime())
		end
	end

	--
	-- MARK: Moving the bar
	--

	local SNAP_CENTER = 15 -- how close to the middle of the screen (in pixels, horizontally or vertically) the bar is pulled to it
	local SNAP_STEP = 10 -- the pixels the bar moves in anywhere else

	-- Lets the bar be dragged with shift held, and snaps it to the middle of the screen or to steps. What is part of the bar (its frame and its notches) is attached, so it can be dragged from any of them.
	-- Without shift they take no clicks, only the hovering for the tooltips, so what is behind them gets the clicks.
	---@class VisualizationMover
	---@field public target? Frame What moves.
	---@field public regions Frame[] What it can be dragged from.
	---@field public clickable boolean If they take clicks, which is only while shift is held so it can be dragged.
	---@field public drag? { cursorX: number, cursorY: number, x: number, y: number } Where the cursor and the bar were as the dragging began, the bar is `x` and `y` from the middle of the screen.
	local mover = { regions = {}, clickable = false }

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

	-- Keeps the tooltips working, but disables intercepting the clicks.
	---@param region Frame
	function mover:Apply(region)
		region:SetMouseMotionEnabled(true)
		region:SetMouseClickEnabled(self.clickable)
	end

	-- Takes mouse input on the region, which is then part of what the bar can be dragged from.
	---@param region Frame
	function mover:Enable(region)
		region:EnableMouse(true)
		self:Apply(region)
	end

	-- What it can be dragged from.
	---@param region Frame
	function mover:Attach(region)
		self.regions[#self.regions + 1] = region
		region:RegisterForDrag("LeftButton")
		region:SetScript("OnDragStart", function() self:Start() end)
		region:SetScript("OnDragStop", function() self:Stop() end)
		self:Enable(region) -- last, as setting the drag up can turn the clicks back on
	end

	-- Drag start writes the origin of the frame with additional data.
	function mover:Start()
		local target = self.target
		if not target or not IsShiftKeyDown() then
			return
		end
		local centerX, centerY = target:GetCenter()
		local parentX, parentY = UIParent:GetCenter()
		local cursorX, cursorY = GetCursor()
		self.drag = { cursorX = cursorX, cursorY = cursorY, x = centerX - parentX, y = centerY - parentY }
	end

	-- The bar follows the cursor while dragging with snapping support.
	function mover:Follow()
		local drag, target = self.drag, self.target
		if not drag or not target then
			return
		end
		local cursorX, cursorY = GetCursor()
		local x = Snap(drag.x + cursorX - drag.cursorX)
		local y = Snap(drag.y + cursorY - drag.cursorY)
		target:ClearAllPoints()
		target:SetPoint("CENTER", UIParent, "CENTER", x, y)
	end

	-- Drag end stores the final position in the user options.
	function mover:Stop()
		local target = self.target
		if not self.drag or not target then
			return
		end
		self:Follow()
		self.drag = nil
		local point, _, relativePoint, x, y = target:GetPoint()
		SV:SetOption("bar", { point, relativePoint, x, y })
	end

	-- The click-state follows shift, unless the user is already dragging the frame.
	function mover:Update()
		local shift = IsShiftKeyDown() or self.drag ~= nil
		if shift ~= self.clickable then
			self.clickable = shift
			for _, region in ipairs(self.regions) do
				self:Apply(region)
			end
		end
		self:Follow()
	end

	--
	-- MARK: Notches
	--

	-- A notch of the bar: a mark at a place on it. The taxi nodes of the route and the clock are the same, with a mark that lights up as it is hovered, and the flare for when we pass it.
	---@class VisualizationNotch : Frame
	---@field public track StatusBar What it is placed along.
	---@field public tooltip fun(self: VisualizationNotch) What its tooltip is made of.
	---@field public checkpoint TaxiTimerLib-1.0_FlightCheckpoint The taxi node the notch is at.
	---@field public number number The place of the taxi node in the route.
	---@field public passed boolean If the flight has passed the taxi node, so the flash plays once.
	---@field public line Texture
	---@field public highlight? Texture
	---@field public flare? Texture
	---@field public flareAnim? AnimationGroup
	local Notch = {}

	-- Puts it on the bar, `x` pixels from its start.
	---@param x number
	function Notch:Place(x)
		self:ClearAllPoints()
		self:SetPoint("CENTER", self.track, "LEFT", x, 0)
	end

	-- Makes the mark dim (for the taxi nodes we will not reach) or as it was.
	---@param dimmed boolean
	function Notch:Dim(dimmed)
		self.line:SetAlpha(dimmed and 0.3 or 1)
	end

	function Notch:Flare()
		if self.flareAnim then
			self.flareAnim:Stop()
			self.flareAnim:Play()
		end
	end

	-- It is the taxi node of the route at `number`, which the flight `passed` or not.
	---@param checkpoint TaxiTimerLib-1.0_FlightCheckpoint
	---@param number number
	---@param numCheckpoints number
	---@param passed boolean The flash is for the ones we pass from here on.
	function Notch:SetCheckpoint(checkpoint, number, numCheckpoints, passed)
		self.checkpoint, self.number, self.passed = checkpoint, number, passed
		self.line:SetShown(number > 1 and number < numCheckpoints) -- the ends of the bar are where the flight starts and lands, so they only have the tooltip
	end

	-- Flashes once as the flight passes it.
	---@param elapsed number The seconds of the flight flown.
	function Notch:Pass(elapsed)
		if self.checkpoint and not self.passed and self:IsShown() and elapsed >= self.checkpoint.time then
			self.passed = true
			self:Flare()
		end
	end

	function Notch:Enter()
		bar.hovered, bar.hoveredAt = self, GetTime()
		if self.highlight and self.line:IsShown() then
			self.highlight:Show()
		end
		self.tooltip(self)
	end

	function Notch:Leave()
		if self.highlight then
			self.highlight:Hide()
		end
		bar.hovered = nil
		GameTooltip:Hide()
	end

	---@param self VisualizationNotch
	local function NotchTooltip(self)
		local checkpoints = progress.checkpoints
		if not progress.flight or not checkpoints then
			return
		end
		local checkpoint = self.checkpoint
		local flown = progress:Elapsed(GetTime())
		local stopIndex = progress.stopIndex
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(NodeName(checkpoint), 1, 1, 1)
		if self.number ~= 1 then
			if stopIndex and self.number > stopIndex then
				GameTooltip:AddLine("Landing before reaching this location.", 0.8, 0.8, 0.8)
			elseif flown < checkpoint.time then
				GameTooltip:AddLine(format("%s until it is reached", TimeLeftText(checkpoint.time - flown)), 0.8, 0.8, 0.8)
				if stopIndex then
					if self.number == stopIndex then
						GameTooltip:AddLine("Stop requested: landing at this Flight Master.", STOP_COLOR[1], STOP_COLOR[2], STOP_COLOR[3])
					end
				elseif TaxiRequestEarlyLanding and self.number < #checkpoints and (self.number == 2 or checkpoints[self.number - 1].time <= flown) then
					GameTooltip:AddLine("Request Stop: land at this Flight Master.", STOP_COLOR[1], STOP_COLOR[2], STOP_COLOR[3])
				end
			end
		end
		GameTooltip:Show()
	end

	-- the tooltip of the notch of the clock, which tells how far the flight is from the simulation
	---@param self VisualizationNotch
	local function ClockTooltip(self)
		local flown = progress:Clock(GetTime())
		if not flown then
			return
		end
		local behind = flown - progress.elapsed
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Clock", 1, 0.25, 0.25)
		GameTooltip:AddLine(format("%s flown, the simulation says %s", TTL.GameAPI.FormatDuration(floor(flown), true), TTL.GameAPI.FormatDuration(floor(progress.elapsed), true)), 0.8, 0.8, 0.8)
		GameTooltip:AddLine(format("%.1f sec %s the simulation", abs(behind), behind >= 0 and "behind" or "ahead of"), 1, 1, 1)
		GameTooltip:Show()
	end

	--
	-- MARK: The bar
	--

	local TEXT_FONT = "SystemFont_Shadow_Med2"
	local TEXT_FONT_OUTLINE = "SystemFont_Outline_Med2"

	-- Makes a notch along the fill of the bar, `parent` being the bar which is not `bar.frame` yet as the first notch is made while the bar is being created.
	---@param parent Frame
	---@param tooltip fun(self: VisualizationNotch) What the tooltip of the notch is made of.
	---@param level number
	---@return VisualizationNotch
	function bar:CreateNotch(parent, tooltip, level)
		local notch = CreateFrame("Frame", nil, parent)
		---@cast notch VisualizationNotch
		for name, method in pairs(Notch) do
			notch[name] = method
		end
		notch.track, notch.tooltip = self.fill, tooltip
		notch:SetSize(10, BAR_HEIGHT + 1)
		notch:SetFrameLevel(level)

		local line = notch:CreateTexture(nil, "OVERLAY")
		notch.line = line
		skin.Pip(line)
		line:SetPoint("CENTER")
		skin.NotchExtras(notch)

		notch:SetScript("OnEnter", notch.Enter)
		notch:SetScript("OnLeave", notch.Leave)
		mover:Attach(notch)
		notch:Hide()
		return notch
	end

	-- Makes the bar and everything on it, once.
	---@return VisualizationFrame
	function bar:Create()
		if self.frame then
			return self.frame
		end
		local f = CreateFrame("Frame", format("%sFrame", addonName), UIParent) ---@class VisualizationFrame : Frame
		f:SetSize(BAR_WIDTH, BAR_HEIGHT)
		f:SetFrameStrata("MEDIUM")
		f:SetClampedToScreen(true)
		mover.target = f
		mover:Attach(f)

		skin = HasAtlases() and AtlasSkin or PlainSkin

		skin.Background(f)

		self.fill = CreateFrame("StatusBar", nil, f)
		self.fill:SetAllPoints()
		self.fill:SetMinMaxValues(0, 1)
		self.fill:SetValue(0)
		skin.Fill(self.fill)

		-- what is drawn over the fill
		local overlay = CreateFrame("Frame", nil, f)
		overlay:SetAllPoints()
		overlay:SetFrameLevel(self.fill:GetFrameLevel() + 2)

		self.spark, self.sparkGlow, self.flash, self.flashAnim = skin.Overlay(f, self.fill, overlay)

		-- the time is in a frame above everything else on the bar, so a taxi node or the notch of the clock passing it does not cover it
		local text = CreateFrame("Frame", nil, f)
		text:SetAllPoints()
		text:SetFrameLevel(f:GetFrameLevel() + 20)
		self.label = text:CreateFontString(nil, "OVERLAY", TEXT_FONT)
		self.label:SetTextColor(1, 1, 1)

		self.delta = f:CreateFontString(nil, "OVERLAY", TEXT_FONT)
		self.delta:SetPoint("LEFT", f, "RIGHT", 6, 0)
		self.delta:SetTextColor(1, 0.25, 0.25)

		self.destination = text:CreateFontString(nil, "OVERLAY", TEXT_FONT)
		self.destination:SetTextColor(1, 1, 1)

		-- where the simulation says we are when the flight is going by the clock alone, to compare with where we are going by our position
		self.clockNotch = self:CreateNotch(f, ClockTooltip, overlay:GetFrameLevel() + 6)

		-- asking to stop lands us at the next taxi node, so the rest of the bar is dimmed and a marker is where we land
		self.cut = overlay:CreateTexture(nil, "ARTWORK", nil, -1)
		self.cut:SetTexture(WHITE_TEXTURE)
		self.cut:SetVertexColor(0, 0, 0, 0.6)
		self.cut:Hide()
		self.stopMarker = overlay:CreateTexture(nil, "OVERLAY", nil, 3)
		skin.Pip(self.stopMarker)
		self.stopMarker:SetVertexColor(STOP_COLOR[1], STOP_COLOR[2], STOP_COLOR[3], 1)
		self.stopMarker:Hide()

		-- what is flown of the route up to the last taxi node we passed, cut off where that is the way the experience bar cuts off what it predicts
		self.done = skin.Done(self.fill)
		self.done:SetPoint("TOPLEFT", self.fill, "TOPLEFT")
		self.done:SetPoint("BOTTOMLEFT", self.fill, "BOTTOMLEFT")
		self.done:Hide()

		f:SetScript("OnUpdate", function()
			mover:Update()
			Visualization:Refresh()
		end)

		local saved = SV:GetOption("bar")
		f:ClearAllPoints()
		f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
		self:PlaceTexts(f)
		f:Hide()

		self.frame = f
		return f
	end

	-- How far along the bar the given seconds of the flight are, in pixels.
	---@param seconds number
	---@return number
	function bar:X(seconds)
		local info = progress.flight
		if not info then
			return 0
		end
		return min(max(seconds / info.duration, 0), 1) * self.fill:GetWidth()
	end

	-- Empties the bar at once, without the easing of the status bar (it would slide down from where the last flight ended).
	function bar:Empty()
		self.fill:SetValue(0)
		if self.fill.SetToTargetValue then
			self.fill:SetToTargetValue()
		end
	end

	-- Hides the bar, empty so it is empty again when it is shown for the next flight.
	function bar:Hide()
		if not self.frame then
			return
		end
		self.frame:Hide()
		self:Empty()
	end

	-- Lays the bar out for a flight: what the last one left is taken away and, with `notches`, a notch is put at each taxi node of the route.
	---@param frame VisualizationFrame
	---@param checkpoints TaxiTimerLib-1.0_FlightCheckpoint[]
	---@param notches boolean
	function bar:Layout(frame, checkpoints, notches)
		self.flashToken = self.flashToken + 1
		if self.flash and self.flashAnim then
			self.flashAnim:Stop()
			self.flash:SetAlpha(0)
		end
		if self.spark and self.sparkGlow then
			self.spark:Show()
			self.sparkGlow:Show()
		end

		self.done:Hide()
		self:ClearStopMarks()

		for _, notch in ipairs(self.notches) do
			notch:Hide()
		end

		if notches then
			-- a notch at each taxi node of the route, the first is where we start and the last is where we land
			local numCheckpoints = #checkpoints
			for i = 1, numCheckpoints do
				local notch = self.notches[i]
				if not notch then
					notch = self:CreateNotch(frame, NotchTooltip, frame:GetFrameLevel() + 5)
					self.notches[i] = notch
				end
				notch:SetCheckpoint(checkpoints[i], i, numCheckpoints, progress:HasPassed(checkpoints[i]))
				mover:Enable(notch)
				notch:Place(self:X(checkpoints[i].time))
				notch:SetFrameLevel(frame:GetFrameLevel() + 5)
				notch:Show()
			end
		end
	end

	-- What the bar shows of a stop that was asked for: the end of the bar is dimmed, a marker shows where we land, and the notches after it are dimmed.
	---@param seconds number When in the flight we land.
	---@param index number The checkpoint we land at.
	function bar:MarkStop(seconds, index)
		local x = self:X(seconds)
		self.cut:ClearAllPoints()
		self.cut:SetPoint("TOPLEFT", self.fill, "TOPLEFT", x, 0)
		self.cut:SetPoint("BOTTOMRIGHT", self.fill, "BOTTOMRIGHT")
		self.cut:Show()
		self.stopMarker:ClearAllPoints()
		self.stopMarker:SetPoint("CENTER", self.fill, "LEFT", x, 0)
		self.stopMarker:Show()
		for i = index + 1, #self.notches do
			self.notches[i]:Dim(true)
		end
	end

	-- Takes back the dimmed end of the bar and the marker of the stop.
	function bar:ClearStopMarks()
		if self.cut then
			self.cut:Hide()
			self.stopMarker:Hide()
		end
		for _, notch in ipairs(self.notches) do
			notch:Dim(false)
		end
	end

	-- What is filled, as the part of the flight. Before the flight has begun it stays empty and does not ease.
	---@param fraction number
	---@param started boolean
	function bar:SetFill(fraction, started)
		if started then
			-- the status bar eases to the value by itself, a jump in position is a quick slide
			self.fill:SetValue(fraction, INTERPOLATION)
		else
			self:Empty()
		end
	end

	-- The spark is at the edge of what is drawn of the fill, which is not always the value it was given as it eases to it.
	---@param fraction number
	---@param started boolean
	function bar:SetSpark(fraction, started)
		local spark, fill = self.spark, self.fill
		if not spark then
			return
		end
		-- the spark stays inside the bar, the glow behind it is as long as it is and what is outside the bar is cut off by the frame it is in, with the border over the cut
		local width = fill:GetWidth()
		local drawn = started and fill.GetInterpolatedValue and fill:GetInterpolatedValue() or fraction -- where the fill is, not where it is going
		local x = min(max(drawn * width, 4), width - 4)
		spark:ClearAllPoints()
		spark:SetPoint("CENTER", fill, "LEFT", x, 0)
	end

	-- The clock notch and the delta beside the bar, when debugging: how many seconds the flight is behind (+) or ahead (-) of the simulation, which is how far the red notch is from the end of the fill.
	-- The notch is only red when the flight is off from the simulation, as the number beside the bar is.
	---@param clock? number The seconds the flight has gone on by the clock, nothing when they are not shown.
	---@param behind? number
	function bar:SetClock(clock, behind)
		local notch = self.clockNotch
		if clock and behind then
			self.isOff = abs(behind) >= (self.isOff and 0.5 or 1)
			self.delta:SetText(self.isOff and format("%+d", floor(behind + 0.5)) or "")
			if self.isOff then
				notch.line:SetVertexColor(1, 0, 0, 1)
			else
				notch.line:SetVertexColor(1, 1, 1, 1)
			end
			notch:Place(self:X(clock))
			notch:Show()
		else
			self.isOff = false
			self.delta:SetText("")
			notch:Hide()
		end
	end

	-- Where the flight goes.
	---@param text string
	function bar:SetDestination(text)
		self.destination:SetText(text)
	end

	local TEXT_GAP = 4 -- pixels between the bar and a text above or below it, and between the texts
	local TEXT_INSET = 6 -- pixels from the end of the bar to a text on it
	local TEXT_BELOW_TRIM = 3 -- pixels removed below the bar (to keep roughly the same distance as when placed above)

	-- A text can be in any of nine places: above the bar (`TOPLEFT`, `TOP`, `TOPRIGHT`), on it (`LEFT`, `CENTER`, `RIGHT`) or below it (`BOTTOMLEFT`, `BOTTOM`, `BOTTOMRIGHT`).
	---@param point FramePoint
	---@return "above"|"inside"|"below" row
	---@return "LEFT"|"RIGHT"|"" side
	local function SplitPoint(point)
		local row = point:find("^TOP") and "above" or point:find("^BOTTOM") and "below" or "inside"
		local side = point:find("LEFT$") and "LEFT" or point:find("RIGHT$") and "RIGHT" or ""
		return row, side
	end

	-- Puts a text in a place, `offset` pixels further out from the bar if it is above or below it.
	---@param frame Frame The bar.
	---@param text FontString
	---@param point FramePoint
	---@param offset number
	local function PlaceText(frame, text, point, offset)
		local row, side = SplitPoint(point)
		text:ClearAllPoints()
		text:SetJustifyH(side == "" and "CENTER" or side)
		if row == "above" then
			text:SetPoint("BOTTOM" .. side --[[@as FramePoint]], frame, "TOP" .. side --[[@as FramePoint]], 0, TEXT_GAP + offset)
		elseif row == "below" then
			text:SetPoint("TOP" .. side --[[@as FramePoint]], frame, "BOTTOM" .. side --[[@as FramePoint]], 0, TEXT_BELOW_TRIM - TEXT_GAP - offset)
		else
			local anchor = (side == "" and "CENTER" or side) --[[@as FramePoint]]
			text:SetPoint(anchor, frame, anchor, side == "LEFT" and TEXT_INSET or side == "RIGHT" and -TEXT_INSET or 0, 0)
		end
	end

	-- Puts the time and the destination where the player wishes. If they are in the same place they share it: above or below the bar one is over the other with the time next to the bar, and on the bar they are side by side with the destination first.
	---@param frame Frame The bar.
	function bar:PlaceTexts(frame)
		local timer, destination = self.label, self.destination
		timer:SetFontObject(SV:GetOption("timerOutline") and TEXT_FONT_OUTLINE or TEXT_FONT)
		destination:SetFontObject(SV:GetOption("destinationOutline") and TEXT_FONT_OUTLINE or TEXT_FONT)
		timer:SetTextColor(1, 1, 1) -- a font brings its own color
		destination:SetTextColor(1, 1, 1)
		local timerPoint, destinationPoint = SV:GetOption("timerPosition"), SV:GetOption("destinationPosition")
		PlaceText(frame, timer, timerPoint, 0)
		if not (SV:GetOption("timer") and SV:GetOption("destination") and timerPoint == destinationPoint) then
			PlaceText(frame, destination, destinationPoint, 0)
			return
		end
		local row, side = SplitPoint(timerPoint)
		if row ~= "inside" then
			PlaceText(frame, destination, destinationPoint, select(2, timer:GetFont()) + 2)
			return
		end
		destination:ClearAllPoints()
		if side == "LEFT" then
			destination:SetPoint("LEFT", frame, "LEFT", TEXT_INSET, 0)
			timer:ClearAllPoints()
			timer:SetPoint("LEFT", destination, "RIGHT", TEXT_GAP * 2, 0)
		elseif side == "RIGHT" then
			destination:SetPoint("RIGHT", timer, "LEFT", -TEXT_GAP * 2, 0)
		else
			destination:SetPoint("RIGHT", frame, "CENTER", -TEXT_GAP, 0)
			destination:SetJustifyH("RIGHT")
			timer:ClearAllPoints()
			timer:SetPoint("LEFT", frame, "CENTER", TEXT_GAP, 0)
			timer:SetJustifyH("LEFT")
		end
	end

	-- What is flown of the route up to the last taxi node we passed.
	---@param seconds number
	function bar:SetDone(seconds)
		local x = self:X(seconds)
		if x > 0 then
			self.done:SetWidth(x)
			self.done:SetTexCoord(0, x / self.fill:GetWidth(), 0, 1)
			self.done:Show()
		else
			self.done:Hide()
		end
	end

	-- The tooltip of the notch the cursor is on is made again now and then, as what it says changes as we fly.
	---@param now number
	function bar:RefreshTooltip(now)
		local notch = self.hovered
		if notch and now - self.hoveredAt > 0.2 then
			notch:Enter()
		end
	end

	-- The flight ended: the bar fills as far as we flew if we landed, flashes and goes, otherwise it goes at once.
	---@param landedAt number The part of the bar we flew.
	---@param landed boolean
	function bar:Finish(landedAt, landed)
		self.flashToken = self.flashToken + 1
		if landed and self.frame and self.frame:IsShown() then
			self.fill:SetValue(landedAt)
			if self.spark and self.sparkGlow then
				self.spark:Hide() -- the casting bar does not show it when the cast is done
				self.sparkGlow:Hide()
			end
			if self.flashAnim then
				self.flashAnim:Stop()
				self.flashAnim:Play()
			end
			local token = self.flashToken
			C_Timer.After(FLASH_SECONDS, function()
				if token == self.flashToken then
					self:Hide()
				end
			end)
		else
			self:Hide()
		end
	end

	--
	-- MARK: Exported
	--

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
		activeMode = activeMode or self:GetSavedMode()
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
		return self:GetMode() == "bar"
	end

	-- The stop is not asked for any more.
	local function ClearStop()
		progress:ClearStop()
		bar:ClearStopMarks()
	end

	-- Lays the bar out for the flight we have, with what the player wishes to see on it.
	---@param frame VisualizationFrame
	local function LayOut(frame)
		local flight = progress.flight
		ClearStop()
		bar:Layout(frame, progress:GetCheckpoints(), SV:GetOption("checkpoints"))
		bar:SetDestination(flight and flight.nodes[#flight.nodes] and NodeName(flight.nodes[#flight.nodes]) or "")
		bar:PlaceTexts(frame)
		bar:Empty()
		frame:Show()
	end

	-- Lays out the bar for the flight we have.
	function Visualization:Build()
		if not progress.flight or not self:IsBarEnabled() then
			bar:Hide()
			return
		end
		LayOut(bar:Create())
		self:Refresh()
	end

	-- What is shown of the options changed, for the flight that is going on or for the example.
	function Visualization:Apply()
		if not bar.frame or not progress.flight then
			return
		end
		if example then
			LayOut(bar.frame)
			self:Refresh()
			return
		end
		local stopAt, stopIndex = progress.stopAt, progress.stopIndex
		self:Build()
		-- laying the bar out takes a stop that was asked for away, and it is still asked for
		if stopAt and stopIndex and bar.frame:IsShown() then
			progress:SetStop(stopIndex)
			bar:MarkStop(stopAt, stopIndex)
		end
	end

	function Visualization:GetFrame()
		return bar:Create()
	end

	---@param info TaxiTimerLib-1.0_FlightInfo
	function Visualization:Start(info)
		self:HideExample()
		activeMode = self:GetSavedMode()
		progress:Start(info)
		bar:ClearStopMarks()
		if bar.frame then
			bar:Empty()
		end
		self:Build()
	end

	-- We are flying: the bar and the clock begin to run, both from here.
	function Visualization:Takeoff()
		progress:Takeoff(GetTime())
	end

	-- `finished` if the flight ended by us landing, then the bar flashes before it goes.
	---@param finished? boolean
	function Visualization:Stop(finished)
		local wasFlying = progress.flight ~= nil
		-- stopwatch plays a sound when it reaches zero, but if we use the bar simply play the same sound as we land
		if finished and wasFlying and self:IsBarEnabled() then
			PlaySound(BAR_FULL_SOUND, "Master", true)
		end
		local landedAt = progress:Landed()
		progress:End()
		if bar.hovered then
			bar.hovered = nil
			GameTooltip:Hide()
		end
		if bar.frame then
			bar:Finish(landedAt, finished and wasFlying or false)
		end
		if editing then
			-- the example comes back when the bar has gone
			C_Timer.After(FLASH_SECONDS, function()
				if editing and not progress.flight then
					self:ShowExample()
				end
			end)
		end
	end

	-- We asked to stop: the flight ends at the next taxi node, so the rest of the bar is dimmed and a marker shows where we land.
	function Visualization:RequestStop()
		if not bar.frame or not bar.frame:IsShown() then
			return
		end
		local at = progress:NextStop()
		if not at then
			return -- the next taxi node is where we land anyway
		end
		progress:SetStop(at)
		bar:MarkStop(progress.stopAt or 0, at)
	end

	---@param seconds number
	function Visualization:SetTimeLeft(seconds)
		-- the time left that is shown is kept up to date by `SetProgress`, so the stopwatch corrections only give it a start and do not override it
		progress:SetEndTime(seconds, GetTime())
	end

	---@return number seconds
	function Visualization:GetTimeLeft()
		return progress:TimeLeftOfEnd(GetTime())
	end

	-- Tells where we are in the flight according to the simulation, as the seconds left of it.
	---@param seconds number
	function Visualization:SetProgress(seconds)
		progress:SetPosition(seconds, GetTime(), not self:IsStopwatchEnabled())
	end

	--
	-- MARK: Example for Edit Mode
	--

	---@type TaxiTimerLib-1.0_FlightCheckpoint[]
	local EXAMPLE_CHECKPOINTS = {
		{ nodeID = 1, name = "Departure", lands = true, pointIndex = 1, distance = 0, time = 0 },
		{ nodeID = 2, name = "First stop", lands = false, pointIndex = 1, distance = 0, time = 34 },
		{ nodeID = 3, name = "Second stop", lands = false, pointIndex = 1, distance = 0, time = 61 },
		{ nodeID = 4, name = "Destination", lands = true, pointIndex = 1, distance = 0, time = 90 },
	}

	---@type Partial<TaxiTimerLib-1.0_FlightInfo>
	local EXAMPLE_FLIGHT = {
		duration = 90,
		nodes = EXAMPLE_CHECKPOINTS,
	}

	local EXAMPLE_DIMMED = 0.35

	function Visualization:ShowExample()
		if progress.flight and not example then
			return
		end
		local frame = bar:Create()
		example, exampleLeft = GetTime(), EXAMPLE_FLIGHT.duration
		progress:Start(EXAMPLE_FLIGHT)
		progress.checkpoints = EXAMPLE_CHECKPOINTS
		progress:Takeoff(example)
		LayOut(frame)
		self:Refresh()
	end

	function Visualization:HideExample()
		if not example then
			return
		end
		example = nil
		progress:End()
		local frame = bar.frame
		if frame then
			frame:SetAlpha(1)
		end
		bar:Hide()
	end

	-- The Edit Mode was opened or closed. While it is open the example is shown, but a real flight comes first, and the example is back when it has landed.
	---@param on boolean
	function Visualization:SetEditing(on)
		editing = on
		if on then
			self:ShowExample()
		else
			self:HideExample()
		end
	end

	function Visualization:Refresh()
		local info = progress.flight
		if not bar.frame or not info then
			return
		end
		local now = GetTime()
		if example then
			-- the example flies by the clock, over and over
			local left = info.duration - (now - example) % info.duration
			if left > exampleLeft then
				LayOut(bar.frame)
			end
			exampleLeft = left
			progress:SetPosition(left, now, true)
			bar.frame:SetAlpha(self:GetSavedMode() == "bar" and 1 or EXAMPLE_DIMMED)
		end
		-- where we are is only known every half second, so the bar goes on at the speed of the simulation until then
		local shown, missed = progress:Advance(now)
		if missed then
			bar:ClearStopMarks() -- the stop came too late for that node and the flight goes on as it was
		end
		local started = progress.startTime ~= nil
		bar:SetFill(shown / info.duration, started)
		bar:SetSpark(shown / info.duration, started)
		bar.label:SetText(TimeLeftText(progress:SecondsLeft(now)))
		bar.label:SetShown(SV:GetOption("timer"))
		bar.destination:SetShown(SV:GetOption("destination"))
		local clock = ClockSeconds()
		bar:SetClock(clock, clock and clock - progress.elapsed)
		bar:RefreshTooltip(now)
		if progress.checkpoints and SV:GetOption("checkpoints") then
			bar:SetDone(progress:Passed()) -- up to the last taxi node we passed
			for _, notch in ipairs(bar.notches) do
				notch:Pass(progress.elapsed)
			end
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
	---@field public override? boolean Only on old recordings, which set it for paths with a made up distance and speed. The analyzer leaves such flights out of its distance and speed checks.

	---@class FlightRecord
	---@field public version number Format of the record.
	---@field public addon string Version of the addon.
	---@field public project number Game client (`WOW_PROJECT_ID`).
	---@field public flavor? TaxiTimerLib-1.0_GameFlavor The game the flight was recorded on, named like its db file.
	---@field public build number Game build number.
	---@field public time number Server time when the flight was taken.
	---@field public area? number The taxi map.
	---@field public route number[] The taxi nodes (`TaxiNodes.ID`) of the route.
	---@field public trips? table<number, number[]> `trips[i]` is the taxi nodes flown from `route[i]` to `route[i + 1]`, both included, where the game does not show the ones between them.
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

	---@param areaID? number The taxi map.
	---@param info TaxiTimerLib-1.0_FlightInfo
	function Recorder:Start(areaID, info)
		current = nil
		if not SV:GetOption("record") then
			return
		end
		local route = {} ---@type number[]
		for i = 1, #info.nodes do
			route[i] = info.nodes[i].nodeID
		end
		-- the taxi nodes the game does not show that the route passes (the ones it flew through that are phased out or never shown), so the flight can be worked out again the same way
		local trips ---@type table<number, number[]>?
		for index, trip in pairs(info.trips) do
			trips = trips or {}
			trips[index] = { unpack(trip) }
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
				flavor = TTL.Sim.FLAVOR,
				build = tonumber((select(2, GetBuildInfo()))) or 0,
				time = GetServerTime(),
				area = areaID,
				route = route,
				trips = trips,
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

	-- we asked to land early, which ends the flight at the next taxi node
	-- on the last leg that is the destination, so the flight is no different and it is not marked
	function Recorder:RequestStop()
		local flight = current
		if not flight or not flight.record.firstTaxi or flight.record.early then
			return
		end
		local checkpoints = TTL.GetFlightCheckpoints(flight.info)
		local flown = GetTime() - flight.record.clicked - flight.record.firstTaxi
		if flown < checkpoints[#checkpoints - 1].time then
			flight.record.early = Round(GetTime() - flight.record.clicked, 2)
		end
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

	local LANDING_SOUND = 34089 -- when you dismount the taxi

	local TAXI_MAX_MAP_CHANGE = 30 -- seconds we wait for a flight to carry on after it left the taxi on its way to another map (the game takes us off the taxi while the next map loads)
	local TAXI_MAX_MAP_CHANGE_DISTANCE = 100 -- yards we must be away from the destination for the flight to be on its way to another map and not have ended
	local TAXI_WARMUP = 30 -- seconds a flight that was asked for can wait for us to get on the taxi before we let it go (the game refuses it if we are in combat, too far away or already flying, or lagging, or other conditions which don't say so)

	local TAXI_TIME_CORRECT = true -- if we wish to change the stopwatch time based on our movement and dynamic speed (if false, uses the original calculation and keeps the timer as-is during the flight)
	local TAXI_TIME_CORRECT_INTERVAL = 2 -- adjusts the timer X amount of times during flight to better calculate actual arrival time (some taxi paths slow down at start, or speed up eventually, this causes some seconds differences, this aims to counter that a bit)
	local TAXI_TIME_CORRECT_IGNORE = 5 -- amount of seconds we need to be wrong, before adjusting the timer

	local TAXI_TIME_CORRECT_MUTE_UPDATES = false -- mute the mid-flight updates
	local TAXI_TIME_CORRECT_MUTE_SUMMARY = false -- mute the end-of-flight summary

	-- How far into the flight the next correction of the timer is made, and how much the corrections have changed it.
	---@class GPSTimeCorrection
	---@field public progress number The distance left at which the next correction is made.
	---@field public chunk number The distance between the corrections.
	---@field public adjustments number The seconds the timer was changed by in all.

	-- The flight that was asked for, followed on every tick of the GPS. It is warming up until we are on the taxi, then it is going on.
	---@class GPSFlight
	---@field public areaID? number The taxi map.
	---@field public info TaxiTimerLib-1.0_FlightInfo
	---@field public ticker FunctionContainer
	---@field public travelScale number What we travel is seen from above, so it is scaled to match the flight distance that includes climbing and descending.
	---@field public wasOnTaxi boolean If we got on the taxi, which is when the flight is going on and it shows.
	---@field public waitingOnTaxi number `GetTime()` when the flight was asked for.
	---@field public distance number The yards left of the flight.
	---@field public timeCorrection? GPSTimeCorrection
	---@field public stopwatchSet boolean If the timer was started at least once.
	---@field public lastOnTaxi? number `GetTime()` when we were last seen on the flight.
	---@field public lastTick? number `GetTime()` of the last tick we were on the flight.
	---@field public lastX? number Where we were on the last tick, nothing if it does not compare to where we are (going from one map to another).
	---@field public lastY? number
	---@field public lastMapID? number The map we were on when last seen on the flight.
	---@field public earlyLanding? boolean If we asked to land early at the next taxi node.
	local Flight = {}
	Flight.__index = Flight

	local flight ---@type GPSFlight? The flight that is going on.

	GPS = {}

	-- Returns the speed we fly at, but never less than the taxi map is flown at as it is lower while taking off and landing.
	---@param areaID? number
	---@param speedModifier? number
	---@return number
	local function GetLiveSpeed(areaID, speedModifier)
		local speed = TTL.Speed(areaID) * (speedModifier or 1)

		if not areaID then
			return speed
		end

		return max(GetUnitSpeed("player"), speed)
	end

	---@param areaID? number
	---@param info TaxiTimerLib-1.0_FlightInfo
	---@return GPSFlight
	function Flight.New(areaID, info)
		local self = setmetatable({
			areaID = areaID,
			info = info,
			travelScale = info.distance2D > 0 and info.distance / info.distance2D or 1,
			wasOnTaxi = false,
			waitingOnTaxi = GetTime(),
			distance = info.distance,
			stopwatchSet = false,
		}, Flight)
		---@cast self GPSFlight
		if TAXI_TIME_CORRECT and not info.donotadjustarrivaltime then
			self.timeCorrection = {
				progress = info.distance,
				chunk = info.distance * (1 / (TAXI_TIME_CORRECT_INTERVAL + 1)),
				adjustments = 0,
			}
		end
		self.ticker = C_Timer.NewTicker(0.5, function()
			self:Tick()
		end)
		return self
	end

	-- Checks if we left the taxi because the flight is changing to the map of its destination, and not because the flight ended.
	---@return boolean
	function Flight:IsChangingMap()
		if self.earlyLanding or not self.lastOnTaxi or not self.lastMapID then
			return false
		end
		local destination = self.info.points[#self.info.points]
		if not destination or destination.map == self.lastMapID or GetTime() - self.lastOnTaxi >= TAXI_MAX_MAP_CHANGE then
			return false
		end
		-- the game can be on a map of its own that shares its positions with the map of the points (like Tanaan Jungle and Draenor), so being on another map than the destination does not tell us that we are not there yet
		-- where we were last seen does, and it does not drift like the distance we think is left
		local x, y = self.lastX, self.lastY
		if not x or not y then
			return self.distance > TAXI_MAX_MAP_CHANGE_DISTANCE
		end
		local dx, dy = destination.x - x, destination.y - y
		local sx, sy = destination.x - y, destination.y - x -- our position can have x and y the other way around
		return min(dx * dx + dy * dy, sx * sx + sy * sy) > TAXI_MAX_MAP_CHANGE_DISTANCE * TAXI_MAX_MAP_CHANGE_DISTANCE
	end

	-- The yards flown since the last tick, from where we were and are, or by speed and time in instances where there is no position.
	---@param x? number
	---@param y? number
	---@param mapID? number
	---@return number?
	function Flight:Step(x, y, mapID)
		local lastMapID = self.lastMapID
		-- going from one map of the points to another the positions do not compare, but a map the points are not on shares its positions with the map they are on
		if mapID and lastMapID and mapID ~= lastMapID and self.info.maps[mapID] and self.info.maps[lastMapID] then
			self.lastX = nil
		end
		local lastX, lastY = self.lastX, self.lastY
		if lastX and lastY and x and y then
			return sqrt((lastX - x)^2 + (lastY - y)^2) * self.travelScale
		elseif not x and self.lastTick then
			return GetUnitSpeed("player") * (GetTime() - self.lastTick)
		end
	end

	-- Checks if the timer is to be corrected now, which is at each of the distances the flight is divided in (and then only if it is off by enough to be worth it).
	---@param timeLeft number The time left the simulation gives.
	---@return boolean
	function Flight:CorrectTime(timeLeft)
		local correction = self.timeCorrection
		if not correction or correction.progress <= self.distance then
			return false
		end
		correction.progress = correction.progress - correction.chunk
		local difference = floor(Timer:Get() - timeLeft)
		if abs(difference) < TAXI_TIME_CORRECT_IGNORE then
			return false
		end
		if self.stopwatchSet then
			correction.adjustments = correction.adjustments + difference
			-- announce the stopwatch time adjustments if significant enough to be noteworthy, and if we have more than just one interval (we then just summarize at the end)
			if not TAXI_TIME_CORRECT_MUTE_UPDATES and TAXI_TIME_CORRECT_INTERVAL > 1 then
				print("Expected arrival time adjusted by |cffFFFFFF%d seconds|r.", abs(difference))
			end
		end
		return true
	end

	-- Takes the yards flown from what is left of the flight and tells the bar and the timer how long it is to go.
	---@param step number
	---@param speed number The speed we fly at.
	function Flight:Advance(step, speed)
		local info = self.info
		self.distance = self.distance - step
		if self.distance <= 0 or speed <= 0 then
			return
		end
		-- the time left goes by the speed of each stretch that is left, and if the whole flight is at one speed also by how much faster than expected we fly
		local timeLeft = TTL.GetFlightTimeLeft(info, self.distance)
		Visualization:SetProgress(timeLeft)
		if not info.dynamicSpeed then
			timeLeft = timeLeft * info.areaSpeed / speed
		end
		local correct = self:CorrectTime(timeLeft)
		-- set or override the stopwatch based on time correction mode
		-- a stopwatch that ran out before we landed is only started again if there is a good while left, or
		-- it would start over and ring again and again as we come in to land
		if not info.donotadjustarrivaltime and (correct or not self.stopwatchSet or timeLeft > TAXI_TIME_CORRECT_IGNORE) then
			Timer:Start(timeLeft, correct)
		end
		self.stopwatchSet = true
	end

	-- We got on the taxi, so the flight is real: the bar and the timer begin.
	function Flight:Board()
		self.wasOnTaxi = true
		Visualization:Start(self.info)
		if self.info.donotadjustarrivaltime then
			Timer:Start(self.info.duration, true)
		end
	end

	-- We are on the taxi: the bar runs, and where we are tells how far we got since the last tick.
	function Flight:Fly()
		if not self.wasOnTaxi then
			self:Board()
		end
		Visualization:Takeoff()
		local now = GetTime()
		self.lastOnTaxi = now
		local speed = GetLiveSpeed(self.areaID, self.info.speedModifier)
		local x, y, z, mapID = UnitPosition("player")
		if self.lastTick then
			local step = self:Step(x, y, mapID)
			if step then
				self:Advance(step, speed)
			end
		end
		Recorder:Tick(x, y, z, mapID, self.distance)
		self.lastTick = now
		self.lastX, self.lastY, self.lastMapID = x, y, mapID
	end

	-- The flight has ended: the recording is saved, the time we were off is told, and the timer stops.
	function Flight:Land()
		Recorder:Stop()
		-- announce the time adjustments, if any
		local correction = self.timeCorrection
		if not TAXI_TIME_CORRECT_MUTE_SUMMARY and correction then
			local adjusted = abs(correction.adjustments)
			if adjusted > TAXI_TIME_CORRECT_IGNORE then
				print("Your trip was |cffFFFFFF%d seconds|r %s than indicated.", adjusted, correction.adjustments < 0 and "longer" or "shorter")
			end
		end
		Timer:Stop(true)
		self.ticker:Cancel()
		flight = nil
		PlaySound(LANDING_SOUND, "Master", true)
		FlashClientIcon(true)
	end

	-- The flight did not begin.
	function Flight:Discard()
		Recorder:Stop()
		self.ticker:Cancel()
		flight = nil
	end

	-- Ticks are called from a timer to regularly update our state.
	function Flight:Tick()
		if UnitOnTaxi("player") then
			self:Fly()
		elseif not self.wasOnTaxi then
			Recorder:Idle()
			if GetTime() - self.waitingOnTaxi > TAXI_WARMUP then
				self:Discard()
			end
		elseif self:IsChangingMap() then
			self.lastX = nil -- the flight carries on once the next map has loaded
		else
			self:Land()
		end
	end

	-- asking to land early ends the flight at the next taxi node, which can be on a map before the one of the destination
	if TaxiRequestEarlyLanding then
		hooksecurefunc("TaxiRequestEarlyLanding", function()
			if flight and flight.wasOnTaxi then
				flight.earlyLanding = true
				Recorder:RequestStop()
				Visualization:RequestStop()
			end
		end)
	end

	-- A flight was requested and we're waiting to get on the taxi.
	---@param areaID? number The taxi map.
	---@param info TaxiTimerLib-1.0_FlightInfo
	function GPS:Request(areaID, info)
		if flight then
			if flight.wasOnTaxi then
				if UnitOnTaxi("player") then
					return
				end
				flight:Land()
			else
				flight:Discard()
			end
		end
		Recorder:Start(areaID, info)
		flight = Flight.New(areaID, info)
	end

end

---@class State : TaxiTimerLib-1.0_TaxiMap
local State do

	---@class State
	---@field public to? TaxiNodeInfo The taxi node the player points at or clicks on.

	---@class TaxiButton : Button
	---@field public taxiNodeData TaxiNodeInfo

	-- we utilize the library to keep track of the taxi map state (we just have to hook it up and call the API that updates the state)
	State = setmetatable({}, { __index = function(_, key) return TTL.GameAPI.TaxiMap[key] end }) ---@type State

	-- The taxi node the player points at or takes, nothing if the flight path is not reachable.
	---@param node? TaxiNodeInfo
	function State:Select(node)
		self.to = node
		if node and node.state == Enum.FlightPathState.Unreachable then
			self.to = nil
		end
	end

	---@param button TaxiButton
	function State:UpdateButton(button)
		self:Update()
		if button.taxiNodeData then
			self:Select(self.nodes[button.taxiNodeData.slotIndex] or button.taxiNodeData)
		else
			self:Select(self.nodes[button:GetID()])
		end
	end

	-- Where two taxi nodes of the route have no path between them: the ways there that the data has, and which of the taxi nodes in between the game shows.
	---@param route TaxiTimerLib-1.0_TaxiRouteNode[]
	---@param shown table<number, boolean>
	---@return string[] lines
	local function GapLines(route, shown)
		local lines = {} ---@type string[]
		for i = 2, #route do
			local from, to = route[i - 1].nodeID, route[i].nodeID
			local trips = TTL.GetBridgeCandidates(from, to)
			if not trips[1] then
				lines[#lines + 1] = format("No path %d > %d, and no trip between them", from, to)
			elseif #trips[1] > 2 then
				for _, trip in ipairs(trips) do
					local parts = {}
					for j = 2, #trip - 1 do
						parts[#parts + 1] = format("#%d%s", trip[j], shown[trip[j]] and " (shown)" or " (not shown)")
					end
					lines[#lines + 1] = format("No path %d > %d, trip via %s", from, to, table.concat(parts, ", "))
				end
			end
		end
		return lines
	end

	function State:ButtonTooltip()
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
		GameTooltip:AddLine(format("~ %s flight time", TTL.GameAPI.FormatDuration(info.duration, true)), 1, 1, 1, false)
		GameTooltip:Show()
	end

	---@return TaxiTimerLib-1.0_FlightInfo?
	function State:GetFlightInfo()
		return TTL.GameAPI.GetFlightInfoToNode(self.to)
	end

	-- Test all destinations if we properly detect a path, if not we'll report it in the chat.
	function State:TestMap()
		local from = self.from
		if not from then
			return
		end
		local total = 0
		local problems = {} ---@type { name: string, lines: string[] }[]
		for _, node in pairs(self.nodes) do
			if node.state == Enum.FlightPathState.Reachable then
				total = total + 1
				local route, _, shown = TTL.GameAPI.GetRouteNodes(node, from)
				local info = TTL.GameAPI.GetFlightInfoToNode(node, from)
				local lines ---@type string[]?
				if route and shown then
					if not info then
						lines = GapLines(route, shown)
						table.insert(lines, 1, "no flight information")
					else
						local missing = {} ---@type string[]
						for i = 1, #info.arrivals do
							if not info.arrivals[i] then
								missing[#missing + 1] = format("%s > %s", NodeName(info.nodes[i]), NodeName(info.nodes[i + 1]))
							end
						end
						if #missing > 0 then
							lines = { format("leg left out of the estimate: %s", table.concat(missing, "; ")) }
						end
					end
				end
				if lines then
					problems[#problems + 1] = { name = NodeName(node), lines = lines }
				end
			end
		end
		local numProblems = #problems
		if numProblems == 0 then
			return
		end
		table.sort(problems, function(a, b) return a.name < b.name end)
		print("%s: tried the %d flights from %s: %d without all of their flight information.", addonName, total, from.name or "here", numProblems)
		for i = 1, math.min(numProblems, 12) do
			print("  to %s: %s", problems[i].name, table.concat(problems[i].lines, "; "))
		end
		if numProblems > 12 then
			print("  and %d more.", numProblems - 12)
		end
	end

	---@param forceUpdate? boolean
	function State:Update(forceUpdate)
		if TTL.GameAPI.UpdateTaxiMap(forceUpdate) then
			self.to = nil
		end
		if forceUpdate and SV:GetOption("debug") then
			self:TestMap()
		end
	end

	---@param button TaxiButton
	function State:OnEnter(button)
		self:UpdateButton(button)
		self:ButtonTooltip()
	end

	-- The player took a taxi node.
	---@param slotIndex number
	function State:OnTakeTaxiNode(slotIndex)
		self:Update()
		self:Select(self.nodes[slotIndex])
		local info = self:GetFlightInfo()
		if info then
			GPS:Request(self.areaID, info)
		end
	end

	-- We track flight requests through the API.
	hooksecurefunc("TakeTaxiNode", function(slotIndex)
		State:OnTakeTaxiNode(slotIndex)
	end)

end

---@type table<string, AddOnManifest>?
local Frames do

	---@class AddOnManifest
	---@field public loaded? boolean
	---@field public OnLoad fun(manifest: AddOnManifest, frame: Frame)
	---@field public OnShow? fun(manifest: AddOnManifest)

	Frames = {}

	Frames.FlightMapFrame = {
		OnLoad = function(_, frame)
			frame:HookScript("OnShow", function() State:Update(true) end)
			hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", function(...) State:OnEnter(...) end)
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
				end
			end
		end,
	}

end

---@class SettingsUI
local SettingsUI do

	---@class SettingsUIOption
	---@field key keyof TaxiTimerDBOptions
	---@field kind "dropdown"|"checkbox"
	---@field name string
	---@field tooltip string
	---@field options? { value: string, text: string }[] What can be chosen, for a dropdown.
	---@field barOnly? boolean If it is for the bar, so it is only there while the bar is what flights are shown as.
	---@field under? string The option that has to be on for this one to be there.

	---@type { value: FramePoint, text: string }[]
	local Positions = {
		{ value = "TOPLEFT", text = "Above, left" },
		{ value = "TOP", text = "Above, center" },
		{ value = "TOPRIGHT", text = "Above, right" },
		{ value = "LEFT", text = "On the bar, left" },
		{ value = "CENTER", text = "On the bar, center" },
		{ value = "RIGHT", text = "On the bar, right" },
		{ value = "BOTTOMLEFT", text = "Below, left" },
		{ value = "BOTTOM", text = "Below, center" },
		{ value = "BOTTOMRIGHT", text = "Below, right" },
	}

	---@type SettingsUIOption[]
	local SettingsOptions = {
		{
			key = "mode",
			kind = "dropdown",
			name = "Show flights as",
			tooltip = "How the time of a flight is shown: the bar, the stopwatch of the game, or not at all.",
			options = {
				{ value = "off", text = "Off" },
				{ value = "bar", text = "Bar" },
				{ value = "stopwatch", text = "Stopwatch" },
			},
		},
		{
			key = "timer",
			kind = "checkbox",
			name = "Show timer",
			tooltip = "The time left of the flight on the bar.",
			barOnly = true,
		},
		{
			key = "timerPosition",
			kind = "dropdown",
			name = "Timer position",
			tooltip = "Where the time left is: above the bar, on it or below it. If the destination is in the same place they share it.",
			options = Positions,
			barOnly = true,
			under = "timer",
		},
		{
			key = "timerOutline",
			kind = "checkbox",
			name = "Timer outline",
			tooltip = "Draws an outline around the time left, to read it better against what is behind it.",
			barOnly = true,
			under = "timer",
		},
		{
			key = "destination",
			kind = "checkbox",
			name = "Show destination",
			tooltip = "Where the flight goes.",
			barOnly = true,
		},
		{
			key = "destinationPosition",
			kind = "dropdown",
			name = "Destination position",
			tooltip = "Where the destination is: above the bar, on it or below it. If the timer is in the same place they share it.",
			options = Positions,
			barOnly = true,
			under = "destination",
		},
		{
			key = "destinationOutline",
			kind = "checkbox",
			name = "Destination outline",
			tooltip = "Draws an outline around the destination, to read it better against what is behind it.",
			barOnly = true,
			under = "destination",
		},
		{
			key = "checkpoints",
			kind = "checkbox",
			name = "Show checkpoints",
			tooltip = "The taxi nodes of the route along the bar, that light up as they are passed.",
			barOnly = true,
		},
	}

	local function IsBar()
		return SV:GetOption("mode") == "bar"
	end

	-- If an option is there: the ones for the bar only while the bar is shown, and the ones under another option only while that is on.
	---@param option SettingsUIOption
	---@return boolean
	local function IsShown(option)
		return (not option.barOnly or IsBar()) and (not option.under or SV:GetOption(option.under) == true)
	end

	-- If other options come and go with this one, so the dialog has to be drawn again when it changes.
	---@param key string
	---@return boolean
	local function HasOptionsUnder(key)
		if key == "mode" then
			return true
		end
		for _, option in ipairs(SettingsOptions) do
			if option.under == key then
				return true
			end
		end
		return false
	end

	local function OnChange()
		Visualization:Apply()
	end

	--
	-- MARK: Edit Mode
	--

	local function InitEditMode()
		local LEM = LibStub("LibEditMode", true) ---@type LibEditModePolyfill?
		if not LEM then
			return
		end

		local frame = Visualization:GetFrame()
		local default = SV:GetDefaultOption("bar")

		LEM:AddFrame(
			frame,
			function(_, _, point, x, y)
				SV:SetOption("bar", { point, point, x, y })
			end,
			{
				point = default[1],
				x = default[3],
				y = default[4],
			},
			addonName
		)

		local settings = {} ---@type LibEditModeSettingObject[]

		for _, item in ipairs(SettingsOptions) do
			---@type LibEditModeSettingObject
			local setting = {
				kind = item.kind == "dropdown" and LEM.SettingType.Dropdown or LEM.SettingType.Checkbox,
				name = item.name,
				desc = item.tooltip,
				default = SV:GetDefaultOption(item.key),
				get = function()
					return SV:GetOption(item.key)
				end,
				set = function(_, value)
					SV:SetOption(item.key, value)
					OnChange()
					if HasOptionsUnder(item.key) then
						LEM:RefreshFrameSettings(frame)
					end
				end,
				hidden = (item.barOnly or item.under) and function() return not IsShown(item) end or nil,
			}
			if item.kind == "dropdown" then
				setting.values = item.options
			end
			settings[#settings + 1] = setting
		end

		LEM:AddFrameSettings(frame, settings)

		LEM:RegisterCallback("enter", function()
			Visualization:SetEditing(true)
		end)

		LEM:RegisterCallback("exit", function()
			Visualization:SetEditing(false)
		end)

		if LEM:IsInEditMode() then
			Visualization:SetEditing(true)
		end
	end

	--
	-- MARK: Settings Panel
	--

	local function InitSettingsPanel()
		if not Settings or not Settings.RegisterVerticalLayoutCategory then
			return
		end

		local category = Settings.RegisterVerticalLayoutCategory(addonName)
		local initializers = {} ---@type table<string, table>

		for _, item in ipairs(SettingsOptions) do
			local setting = Settings.RegisterAddOnSetting(
				category,
				"TAXITIMER_" .. item.key:upper(),
				item.key,
				SV:GetOptions(),
				item.kind == "dropdown" and Settings.VarType.String or Settings.VarType.Boolean,
				item.name,
				SV:GetDefaultOption(item.key)
			)
			setting:SetValueChangedCallback(OnChange)
			local initializer
			if item.kind == "dropdown" then
				initializer = Settings.CreateDropdown(category, setting, function()
					local container = Settings.CreateControlTextContainer()
					for _, option in ipairs(item.options or {}) do
						container:Add(option.value, option.text)
					end
					return container:GetData()
				end, item.tooltip)
			else
				initializer = Settings.CreateCheckbox(category, setting, item.tooltip)
			end
			initializers[item.key] = initializer
			local parent = initializers[item.under or "mode"]
			if parent and (item.barOnly or item.under) then
				initializer:SetParentInitializer(parent, function() return IsShown(item) end)
			end
		end

		Settings.RegisterAddOnCategory(category)
	end

	SettingsUI = {}

	function SettingsUI:Init()
		InitEditMode()
		InitSettingsPanel()
	end

end

---@class AddOnFrame : Frame
local AddOn do

	---@param self AddOnFrame
	---@param event WowEvent
	---@param ... any
	local function OnEvent(self, event, ...)

		if event == "ADDON_LOADED" and ... == addonName then
			SV:Init()
			SettingsUI:Init()
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
		---@type "debug"|"record"?, string
		local command = strmatch(strlower(message or ""), "^%s*(%S+)")
		if command then
			if command == "debug" or command == "record" then
				local newValue = not SV:GetOption(command)
				SV:SetOption(command, newValue)
				print("%s %s %s.", addonName, command, newValue and "enabled" or "disabled")
				return
			end
		end
		print("%s commands:", addonName)
		print("    |cffFFFFFFdebug|r   (|cffFFFFFF%s|r) Enable destination tooltip information.", tostring(SV:GetOption("debug")))
		print("    |cffFFFFFFrecord|r  (|cffFFFFFF%s|r) Records flights for later analysis.", tostring(SV:GetOption("record")))
	end

end

-- TaxiTimerAPI
-- This is a global legacy variable that you may continue to use.
-- You may also use the `LibStub("TaxiTimerLib-1.0")` approach instead.
---@class TaxiTimerAPI
_G.TaxiTimerAPI = {
	GetNodeFromSlotIndex = function(...) return TTL.GameAPI.GetNodeFromSlotIndex(...) end,
	GetFlightInfo = function(...) return TTL.GameAPI.GetFlightInfo(...) end,
	GetFlightTime = function(...) return TTL.GameAPI.GetFlightTime(...) end,
}
