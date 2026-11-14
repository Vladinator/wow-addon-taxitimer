--[[

Lets the files of the addon, and the scripts that use them, run outside of the game in any version of Lua from 5.1 and up.

It does two things:

1. It smooths over the differences between the versions of Lua (loading with an environment, `unpack` and so on).
2. It provides the parts of the game that the files of the addon call, so they can be loaded and tested without the game.

The files that only deal with the taxi data (`catmul.lua` and `taxi.lua`) call nothing in the game, and do not need the second part.

Usage:

	local shim = dofile("scripts/shim.lua")
	local ns = shim.addon("path/to/the/addon", "mainline", { exclude = { "core.lua" } })

--]]

---A chunk of lua that has been loaded and is ready to run.
---@alias LuaChunk fun(...: any): any

---@class Shim
local shim = {}

-- Lua versions ---------------------------------------------------------------------------------------------------------

---Returns the values of a list, `unpack` is the one of Lua 5.1 and `table.unpack` the one of the later versions.
---@type fun(list: table, i?: integer, j?: integer): any ...
---@diagnostic disable-next-line: undefined-field
shim.unpack = unpack or table.unpack

---Loads the lua in `text` as a chunk that runs with `env` as its globals (or the globals we have if there is none).
---@param text string
---@param name string The name that is shown in errors.
---@param env? table
---@return LuaChunk? chunk
---@return string? error
function shim.load(text, name, env)
	if setfenv then
		-- Lua 5.1
		local chunk, err = loadstring(text, name)
		if chunk and env then
			setfenv(chunk, env)
		end
		return chunk, err
	end
	if env then
		return load(text, name, "t", env)
	end
	return load(text, name, "t")
end

---@param path string
---@return string? text
---@return string? error
function shim.readfile(path)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, err
	end
	local text = file:read("*a")
	file:close()
	return text
end

---@param path string
---@param env? table
---@return LuaChunk? chunk
---@return string? error
function shim.loadfile(path, env)
	local text, err = shim.readfile(path)
	if not text then
		return nil, err
	end
	return shim.load(text, "@" .. path, env)
end

---Returns the folder a path is in, without the slash at the end.
---@param path string
---@return string
function shim.dirname(path)
	local dir = path:match("^(.*)[/\\][^/\\]*$")
	return dir and dir ~= "" and dir or "."
end

---Returns what the saved variables file has in its global variables.
---@param path string
---@return table<string, any>? globals
---@return string? error
function shim.savedvariables(path)
	local globals = { inf = 1 / 0, nan = 0 / 0 } ---@type table<string, any>
	local chunk, err = shim.loadfile(path, globals)
	if not chunk then
		return nil, err
	end
	local ok, runErr = pcall(chunk)
	if not ok then
		return nil, tostring(runErr)
	end
	globals.inf, globals.nan = nil, nil
	return globals
end

-- The addon ------------------------------------------------------------------------------------------------------------

-- The game types of the toc file, by the name the db and sim files of a game have.
local GAME_TYPES = { mainline = "standard", vanilla = "vanilla", classic = "classic", forever = "camelot" } ---@type table<TaxiTimerLib-1.0_TaxiFlavor, string>

---Returns the lua files the toc file loads for a game, in the order they are loaded.
---@param root string The folder of the addon.
---@param flavor TaxiTimerLib-1.0_TaxiFlavor
---@return string[]? files
---@return string? error
function shim.files(root, flavor)
	local toc, err = shim.readfile(root .. "/TaxiTimer.toc")
	if not toc then
		return nil, err
	end
	local gameType = GAME_TYPES[flavor]
	local files = {} ---@type string[]
	for line in toc:gmatch("[^\r\n]+") do
		local name, rest = line:match("^(%S+%.lua)%s*(.*)$")
		if name then
			local isLoaded = true
			for kind, list in rest:gmatch("%[(%a+)%s+([^%]]+)%]") do
				local isListed = false
				for item in list:gmatch("[^%s,]+") do
					if item == gameType then
						isListed = true
					end
				end
				if kind == "AllowLoadGameType" and not isListed then
					isLoaded = false
				elseif kind == "ExcludeLoadGameType" and isListed then
					isLoaded = false
				end
			end
			if isLoaded then
				files[#files + 1] = name
			end
		end
	end
	return files
end

---@class ShimAddonOptions
---@field sim? string The path of a sim file to use instead of the one of the game.
---@field exclude? string[] Files not to load, like `core.lua`.
---@field game? ShimGame The game the files run in (from `shim.game`), the files do not need it if they do not call the game.

---Loads the files of the addon the way the game does for a game and returns what they put in the table they share.
---@param root string The folder of the addon.
---@param flavor TaxiTimerLib-1.0_TaxiFlavor
---@param options? ShimAddonOptions
---@return TaxiTimerLib-1.0_DB? ns
---@return string? error
function shim.addon(root, flavor, options)
	options = options or {}
	local files, err = shim.files(root, flavor)
	if not files then
		return nil, err
	end
	local skip = {} ---@type table<string, boolean>
	for _, name in ipairs(options.exclude or {}) do
		skip[name] = true
	end
	local ns = {}
	---@cast ns TaxiTimerLib-1.0_DB
	for _, name in ipairs(files) do
		if not skip[name] then
			local path = root .. "/" .. name
			if options.sim and name:match("^sim_") then
				path = options.sim
			end
			local chunk, loadErr = shim.loadfile(path, options.game and options.game.env or nil)
			if not chunk then
				return nil, loadErr
			end
			chunk("TaxiTimer", ns)
		end
	end
	return ns
end

-- The game -------------------------------------------------------------------------------------------------------------

---@class ShimTicker
---@field interval number
---@field fn fun()
---@field due number When the clock is at it runs next.
---@field cancelled? boolean
local Ticker = {}
Ticker.__index = Ticker

function Ticker:Cancel()
	self.cancelled = true
end

---@class ShimFrame
---@field scripts table<string, function>
---@field events table<string, boolean>
---@field shown boolean
local Frame = {}

function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:HookScript(name, fn) self.scripts[name] = fn end
function Frame:RegisterEvent(event) self.events[event] = true end
function Frame:UnregisterEvent(event) self.events[event] = nil end
function Frame:Show() self.shown = true end
function Frame:Hide() self.shown = false end
function Frame:IsShown() return self.shown end

---@class ShimPlayer What the player is doing, as the game tells the addon.
---@field onTaxi boolean
---@field x number
---@field y number
---@field z number
---@field map number
---@field speed number

---@class ShimTaxi The taxi map that is open.
---@field areaID number
---@field nodes table[] The taxi nodes of the map, like `C_TaxiMap.GetAllTaxiNodes` gives them.
---@field routes table<number, number[][]> `routes[destination slot] = { { from slot, to slot }, ... }`

---@class ShimStopwatch
---@field timer number The seconds it has left when it counts down.
---@field playing boolean
---@field shown boolean

---@class ShimGame What the game has for the addon, and what to set up in it.
---@field clock number What `GetTime` says.
---@field player ShimPlayer
---@field taxi ShimTaxi
---@field stopwatch ShimStopwatch
---@field chat string[] What the addon has said in the chat.
---@field tooltip string[] The lines the addon has put in the tooltip.
---@field tickers ShimTicker[]
---@field hooks number The number of functions that have been hooked.
---@field version string
---@field build number
---@field env table<string, any> The globals of the game, which is what `core.lua` runs with.
---@field advance fun(seconds: number) Makes time pass.

---Provides the parts of the game the addon calls. They are in the table that is returned as `env`, which is what `core.lua` runs with.
---What it returns also has what to set up in the game: `clock`, `player`, `taxi`, `stopwatch`, `chat` and `tooltip`, and `advance(seconds)` to make time pass.
---@param flavor? TaxiTimerLib-1.0_TaxiFlavor
---@return ShimGame game
function shim.game(flavor)
	flavor = flavor or "mainline"
	local floor, format = math.floor, string.format
	local noop = function() end
	local env = setmetatable({}, { __index = _G }) ---@type table<string, any>
	local game = {
		clock = 1000,
		player = { onTaxi = false, x = 0, y = 0, z = 0, map = 0, speed = 0 },
		taxi = { areaID = 0, nodes = {}, routes = {} },
		stopwatch = { timer = 0, playing = false, shown = false },
		chat = {},
		tooltip = {},
		tickers = {},
		hooks = 0,
		version = "0.0.0",
		build = 0,
		env = env,
	} ---@type ShimGame

	-- the shortcuts the game has for the standard library
	env.abs, env.floor, env.ceil, env.max, env.min, env.format = math.abs, math.floor, math.ceil, math.max, math.min, string.format
	env.wipe = function(t)
		for k in pairs(t) do
			t[k] = nil
		end
		return t
	end
	env.table = setmetatable({ wipe = env.wipe }, { __index = table })
	env.math = setmetatable({ pow = function(base, exponent) return base ^ exponent end }, { __index = math })
	env.bit = {
		band = function(a, b)
			local result, bit = 0, 1
			while a > 0 and b > 0 do
				if a % 2 == 1 and b % 2 == 1 then
					result = result + bit
				end
				a, b, bit = floor(a / 2), floor(b / 2), bit * 2
			end
			return result
		end,
	}

	-- the games
	env.WOW_PROJECT_MAINLINE, env.WOW_PROJECT_CLASSIC, env.WOW_PROJECT_CAMELOT = 1, 2, 20
	env.WOW_PROJECT_ID = ({ mainline = 1, vanilla = 2, forever = 20 })[flavor] or 5

	-- frames, timers and hooks
	env.CreateFrame = function()
		-- what the addon calls on a frame is there, anything else does nothing
		return setmetatable({ scripts = {}, events = {}, shown = false }, { __index = function(_, key) return Frame[key] or noop end })
	end
	env.C_Timer = {
		NewTicker = function(interval, fn)
			local ticker = setmetatable({ interval = interval, fn = fn, due = game.clock + interval }, Ticker)
			game.tickers[#game.tickers + 1] = ticker
			return ticker
		end,
	}
	env.hooksecurefunc = function(a, b, c)
		local owner, name, hook = env, a, b
		if type(a) == "table" then
			owner, name, hook = a, b, c
		end
		local original = owner[name]
		owner[name] = function(...)
			local result = { original and original(...) }
			hook(...)
			return shim.unpack(result)
		end
		game.hooks = game.hooks + 1
	end

	-- time, and what the stopwatch does as it passes
	env.GetTime = function() return game.clock end
	env.GetServerTime = function() return os.time() end
	env.GetBuildInfo = function() return game.version, tostring(game.build), "", 0 end
	env.C_AddOns = { GetAddOnMetadata = function() return game.version end }

	local stopwatch = game.stopwatch
	env.StopwatchTicker = stopwatch
	env.StopwatchFrame = { IsShown = function() return stopwatch.shown end, Hide = function() stopwatch.shown = false end }
	env.Stopwatch_Toggle = function() stopwatch.shown = not stopwatch.shown end
	env.Stopwatch_Clear = function() stopwatch.timer, stopwatch.playing = 0, false end
	env.Stopwatch_IsPlaying = function() return stopwatch.playing end
	env.Stopwatch_StartCountdown = function(hours, minutes, seconds) stopwatch.timer = hours * 3600 + minutes * 60 + seconds end
	env.Stopwatch_Play = function() stopwatch.playing = true end
	env.SecondsToClock = function(seconds, displayZeroHours)
		seconds = floor(seconds)
		local hours = floor(seconds / 3600)
		if hours > 0 or displayZeroHours then
			return format("%02d:%02d:%02d", hours, floor(seconds / 60) % 60, seconds % 60)
		end
		return format("%02d:%02d", floor(seconds / 60), seconds % 60)
	end

	---Makes time pass, running the tickers that are due and counting the stopwatch down.
	---@param seconds number
	function game.advance(seconds)
		local target = game.clock + seconds
		while true do
			local nextTicker ---@type ShimTicker?
			for _, ticker in ipairs(game.tickers) do
				if not ticker.cancelled and ticker.due <= target and (not nextTicker or ticker.due < nextTicker.due) then
					nextTicker = ticker
				end
			end
			local to = nextTicker and nextTicker.due or target
			if stopwatch.playing then
				stopwatch.timer = math.max(0, stopwatch.timer - (to - game.clock))
			end
			game.clock = to
			if not nextTicker then
				break
			end
			nextTicker.due = nextTicker.due + nextTicker.interval
			nextTicker.fn()
		end
	end

	-- the player
	local player = game.player
	env.UnitOnTaxi = function() return player.onTaxi end
	env.UnitPosition = function() return player.x, player.y, player.z, player.map end
	env.GetUnitSpeed = function() return player.speed end

	-- the taxi map
	env.Enum = { FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 } }
	env.GetTaxiMapID = function() return game.taxi.areaID end
	env.NumTaxiNodes = function() return 0 end
	env.C_TaxiMap = { GetAllTaxiNodes = function() return game.taxi.nodes end }
	env.GetNumRoutes = function(slot)
		local routes = game.taxi.routes[slot]
		return routes and #routes or nil
	end
	env.TaxiGetNodeSlot = function(slot, routeIndex, isSource)
		local route = game.taxi.routes[slot] and game.taxi.routes[slot][routeIndex]
		return route and (isSource and route[1] or route[2])
	end
	env.TaxiRequestEarlyLanding = noop

	-- what is shown
	env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) game.chat[#game.chat + 1] = message end }
	env.GameTooltip = {
		AddLine = function(_, line) game.tooltip[#game.tooltip + 1] = line end,
		Show = noop,
	}
	env.PlaySound = noop
	env.FlashClientIcon = noop

	return game
end

return shim
