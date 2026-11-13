---@meta

-- What the scripts in this folder use of Lua that the settings of the addon do not have.
-- The addon runs in the game, which has less of Lua than the scripts do (no files, no operating system, no way to load more lua), so the language server is told to leave those out for the addon.
--
-- The scripts run in any version of Lua from 5.1 and up, so what only some versions have is declared too, and `shim.lua` smooths over the differences.
-- This file is only for the language server, nothing runs it.

---The arguments the script was started with, the script itself is `arg[0]`.
---@type string[]
arg = {}

---Runs the lua in a file.
---@param filename? string
---@return any ...
function dofile(filename) end

---Loads a chunk, the environment (`env`) and the mode are not in Lua 5.1.
---@param chunk string|fun(): string?
---@param chunkname? string
---@param mode? string `"t"` for text.
---@param env? table The globals of the chunk.
---@return (fun(...: any): any ...)? chunk
---@return string? errorMessage
function load(chunk, chunkname, mode, env) end

---Loads a chunk from a string, only in Lua 5.1 (and LuaJIT).
---@param chunk string
---@param chunkname? string
---@return (fun(...: any): any ...)? chunk
---@return string? errorMessage
function loadstring(chunk, chunkname) end

---Sets the globals of a function, only in Lua 5.1 (and LuaJIT).
---@param f function|integer
---@param env table
---@return function
function setfenv(f, env) end

---Returns the values of a list, only in Lua 5.1 (and LuaJIT), later versions have `table.unpack`.
---@param list table
---@param i? integer
---@param j? integer
---@return any ...
function unpack(list, i, j) end

---@class iolib
io = {}

io.stderr = {}

---@param ... string
function io.write(...) end

---@param ... string
function io.stderr:write(...) end

---@class iofile
---@field public close fun(self: iofile)
---@field public read fun(self: iofile, data: string)
---@field public write fun(self: iofile, ...: string)
---@field public lines fun(self: iofile): fun(): string

---@param name string
---@param mode string
---@return iofile
function io.open(name, mode) end

---@class oslib
os = {}

---@param code? integer|boolean
---@param close? boolean
function os.exit(code, close) end

---@param format? string
---@param time? integer
---@return string|table
function os.date(format, time) end

---@param date? table
---@return integer
function os.time(date) end

---@return number
function os.clock() end

---@param filename string
---@return boolean? ok
---@return string? errorMessage
function os.remove(filename) end

---@param command? string
---@return boolean? ok
---@return string? how
---@return integer? code
function os.execute(command) end

---@class packagelib
---@field config string The separators that are used for paths, the first one is the one between folders (`\` in Windows).
package = {}
