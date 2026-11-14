--[[

Lets the library of the addon (`libs/TaxiTimerLib`) and the scripts that use it run outside of the game in any version of Lua from 5.1 and up.

The library only deals with the taxi data and calls nothing in the game, so it only needs `LibStub` and the files of one game: the db and the sim.
The file for what runs in the game (`TaxiTimerLib-GameAPI.lua`) and the addon itself (`core.lua`) are not loaded.
Each time the library is loaded it gets a `LibStub` of its own, so loading a game does not change what was loaded for another.

Usage:

	local shim = dofile("scripts/shim.lua")
	local lib = shim.library("path/to/the/addon", "mainline") -- the TaxiTimerLib-1.0 with the db and sim of the game

--]]

---A chunk of lua that has been loaded and is ready to run.
---@alias LuaChunk fun(...: any): any

---@class Shim
local shim = {}

--
-- MARK: Files
--

---Loads the lua in `text` as a chunk that runs with `env` as its globals (or the globals we have if there is none).
---Lua 5.1 loads with `loadstring` and `setfenv`, the later versions with `load`.
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

--
-- MARK: The library
--

---@class ShimLibraryOptions
---@field sim? string The path of a sim file to use instead of the one of the game.

---Loads the library the way the game does for a game, and returns it (TaxiTimerLib-1.0) with the db and sim of the game.
---The files are the ones of the toc and xml file in the order they are loaded in, `LibStub`, the library, the db and the sim.
---@param root string The folder of the addon.
---@param flavor TaxiTimerLib-1.0_GameFlavor
---@param options? ShimLibraryOptions
---@return TaxiTimerLib-1.0? lib
---@return string? error
function shim.library(root, flavor, options)
	options = options or {}

	-- the lib is registered in `LibStub`, which is in `_G`, so `_G` is this table and each load has its own
	local env = setmetatable({}, { __index = _G }) ---@type table<string, any>
	env._G = env
	env.strmatch = string.match -- used by LibStub.lua, the game has it

	local files = {
		"libs/LibStub/LibStub.lua",
		"libs/TaxiTimerLib/TaxiTimerLib.lua",
		"libs/TaxiTimerLib/db_" .. flavor .. ".lua",
		options.sim or ("libs/TaxiTimerLib/sim_" .. flavor .. ".lua"),
	}

	for i, name in ipairs(files) do
		local path = (options.sim and i == #files) and name or (root .. "/" .. name)
		local chunk, err = shim.loadfile(path, env)
		if not chunk then
			return nil, err
		end
		local ok, runErr = pcall(chunk, "TaxiTimer", {})
		if not ok then
			return nil, tostring(runErr)
		end
	end

	local LibStub = env.LibStub ---@type { [string]: any, __call: function }?
	local lib = LibStub and LibStub("TaxiTimerLib-1.0", true)
	if not lib then
		return nil, "the files of the library did not make TaxiTimerLib-1.0"
	end
	return lib
end

return shim
