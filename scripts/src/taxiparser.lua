--[[

Reads the taxi data of a game from its csv files, and writes the db file the addon loads for the game and svg files that show the taxi nodes and paths of each map.

It is used by `launcher.lua`, and runs in Lua 5.1 and later.

--]]

local scriptDir = (arg and arg[0] or "scripts/launcher.lua"):match("^(.*)[/\\][^/\\]*$") or "." -- this is loaded by `launcher.lua` which is in the same folder
local csv = dofile(scriptDir .. "/src/shared/csv.lua") ---@type Csv
local util = dofile(scriptDir .. "/src/shared/util.lua") ---@type ScriptsUtil

---A taxi node that is drawn.
---@class TaxiParserNode
---@field label string
---@field x number
---@field y number
---@field z number
---@field id number
---@field map number
---@field flags number
---@field color string

---A path between two taxi nodes.
---@class TaxiParserPath
---@field id number
---@field from number
---@field to number
---@field color string

---A point of a path that is drawn.
---@class TaxiParserPoint
---@field id number
---@field pathid number
---@field x number
---@field y number
---@field z number
---@field map number
---@field color string

---The taxi nodes a taxi node has a path to.
---@class TaxiParserDirect
---@field destinations table<number, TaxiParserNode> By the id of the taxi node.
---@field order number[] The ids in the order they were found.

---What is drawn in the svg files.
---@class TaxiParserDrawing
---@field taxipath TaxiParserPath[]
---@field taxinodes TaxiParserNode[]
---@field taxipathnode table<number, TaxiParserPoint[]> The points of each path.
---@field taxipathnodeOrder number[] The paths in the order they are drawn.
---@field direct table<number, TaxiParserDirect> By the id of the taxi node.
---@field directOrder number[]

---Reads the csv files of a game and writes what the addon and the svg files need.
---@class TaxiParser
---@field client string
---@field dir string
---@field db table<string, CsvTable> What was read, by the name of the file.
---@field pdb? TaxiParserDrawing
---@field unknownMaps? table<number, boolean>

---@class TaxiParserModule
local taxiparser = {}

-- the files that are read, in the order they are written to the db file
local FILES = { "taxinodes", "taxipath", "taxipathnode" }

-- the columns that are written to the db file, the addon relies on these (and on the order they have in the csv files)
local FIELDS = {
	taxinodes = { ID = true, Flags = true }, -- the flags are not the ones of the csv file but what the library needs to know of the taxi node, see `NODE_FLAGS`
	taxipath = { ID = true, FromTaxiNode = true, ToTaxiNode = true },
	taxipathnode = { Loc_0 = true, Loc_1 = true, Loc_2 = true, ID = true, PathID = true, ContinentID = true, Flags = true, Delay = true },
}

-- what the types of the rows of each file are called in the db file
local LIB_NAME = "TaxiTimerLib-1.0" -- the library the db file is for, which has the types the db file is made of

local TYPES = { TAXINODES = "TaxiNodesStruct", TAXIPATH = "TaxiPathStruct", TAXIPATHNODE = "TaxiPathNodeStruct" }

local ROWS_PER_CHUNK = 8192 -- a function has a limit to how many constants it can have

local format, concat = string.format, table.concat

local toInt = csv.toInt

-- What the library needs to know about a taxi node, as the bits of the flags of the taxi nodes in the db file (and as `TAXINODEFLAGS` in it, so the library does not have the numbers).
-- The faction of a taxi node is in the first two: Alliance, Horde, neutral (both bits) or undefined (neither, there is nothing that says).
local NODE_FLAGS = {
	{ "ALLIANCE", 0x1 }, -- an Alliance player can use it
	{ "HORDE", 0x2 }, -- a Horde player can use it
	{ "HIDDEN", 0x4 }, -- the map shows it for neither faction, it is only passed on the way (or not in the game any more)
	{ "PASS", 0x8 }, -- a flight can pass it without landing, which it can not if it is only a start or an end, or if it is only part of the game for the players that pass its condition
}

-- The flags of the taxi nodes in the csv files (`TaxiNodes.Flags`).
local TAXI_NODE_ALLIANCE, TAXI_NODE_HORDE, TAXI_NODE_CONDITION, TAXI_NODE_END_POINT_ONLY = 0x1, 0x2, 0x8, 0x20

---How the flags of a taxi node of a game are made into `NODE_FLAGS`. The games can have their own, as the csv files of each differ.
---@alias TaxiParserNodeRule fun(flags: number, mountHorde: number, mountAlliance: number): table<string, boolean>
---@type table<string, TaxiParserNodeRule>
local NODE_RULES = {}

-- A taxi node the map shows is for the faction it is shown for (both is neutral). A taxi node the map does not show (the ones the game flies through that are phased out or never shown) is for the faction that has a mount for it (the first mount is the Horde, the second the Alliance), for both if it has both, and undefined if it has none.
-- One that is only for the players that pass its condition, or only a start or an end, is not passed.
function NODE_RULES.default(flags, mountHorde, mountAlliance)
	local alliance, horde = util.hasFlag(flags, TAXI_NODE_ALLIANCE), util.hasFlag(flags, TAXI_NODE_HORDE)
	local hidden = not alliance and not horde
	if hidden then
		alliance, horde = mountAlliance ~= 0, mountHorde ~= 0
	end
	return {
		ALLIANCE = alliance,
		HORDE = horde,
		HIDDEN = hidden,
		PASS = not util.hasFlag(flags, TAXI_NODE_CONDITION) and not util.hasFlag(flags, TAXI_NODE_END_POINT_ONLY),
	}
end

---The taxi nodes as they are written to the db file: the id and the `NODE_FLAGS` of each.
---@param nodes CsvTable
---@param client string
---@return CsvTable
local function deriveNodes(nodes, client)
	local rule = NODE_RULES[client] or NODE_RULES.default
	local c = nodes.columns
	local rows = {} ---@type string[][]
	for _, row in ipairs(nodes.rows) do
		local node = rule(toInt(row[c.Flags]), toInt(row[c.MountCreatureID_0]), toInt(row[c.MountCreatureID_1]))
		local derived = 0
		for _, flag in ipairs(NODE_FLAGS) do
			if node[flag[1]] then
				derived = derived + flag[2]
			end
		end
		rows[#rows + 1] = { tostring(toInt(row[c.ID])), tostring(derived) }
	end
	return { headers = { "ID", "Flags" }, rows = rows, columns = { ID = 1, Flags = 2 } }
end

---The value of a field as it is written in lua, numbers as they are and the rest in quotes.
---@param value string
---@return string?
local function luaValue(value)
	if value == "" then
		return nil
	end
	if value:match("^%-?[%d%.,]+$") then
		return (value:gsub(",", "."))
	end
	return '"' .. value:gsub('"', '\\"') .. '"'
end

--
-- MARK: The parser
--

---@class TaxiParser
local Parser = {}
Parser.__index = Parser

---Creates a parser for the csv files of a game.
---@param client string The name of the game, like its db file.
---@param dir string The folder with the csv files.
---@return TaxiParser
function taxiparser.new(client, dir)
	return setmetatable({ client = client, dir = dir, db = {} }, Parser)
end

---Checks if there are csv files for the game.
---@param dir string
---@return boolean
function taxiparser.exists(dir)
	return csv.exists(dir, "taxipath")
end

---Reads the csv files. The points of the paths are sorted by their node index as the dumps are not in flight order, and the addon relies on that.
function Parser:read()
	local db = {} ---@type table<string, CsvTable>
	for _, name in ipairs(FILES) do
		local file = csv.read(self.dir, name)
		if file then
			local columns, rows = file.columns, file.rows
			if name == "taxipathnode" then
				if columns.PathID and columns.NodeIndex and columns.ID then
					local keyed = {} ---@type { [1]: string[], [2]: number, [3]: number, [4]: number }[]
					for i, row in ipairs(rows) do
						keyed[i] = { row, toInt(row[columns.PathID]), toInt(row[columns.NodeIndex]), toInt(row[columns.ID]) }
					end
					table.sort(keyed, function(a, b)
						if a[2] ~= b[2] then return a[2] < b[2] end
						if a[3] ~= b[3] then return a[3] < b[3] end
						return a[4] < b[4]
					end)
					for i, entry in ipairs(keyed) do
						rows[i] = entry[1]
					end
				else
					io.stderr:write(format("[%s] unable to sort the path nodes as the PathID, NodeIndex or ID column is missing\n", self.client))
				end
			end
			db[name] = file
		end
	end
	self.db = db
	self.pdb = nil
end

---Checks if the csv files that are needed have been read.
---@return boolean
function Parser:canProcess()
	return self.db.taxinodes ~= nil and self.db.taxipath ~= nil and self.db.taxipathnode ~= nil
end

--
-- MARK: The db file
--

---What the type of the rows of a file is called in the db file.
---@param name string The name of the file in upper case.
---@param items boolean If it is for the list of rows and not for the table of columns.
---@return string
local function annotation(name, items)
	local type = TYPES[name]
	if not type then
		return ""
	end
	if items then
		return "---@type " .. LIB_NAME .. "_" .. (type:gsub("Struct$", "RowChunks")) .. "\r\n"
	end
	return "---@class " .. LIB_NAME .. "_" .. type .. "\r\n"
end

---The columns of a file that are written to the db file, as the lines that give each its index.
---@param headers string[]
---@param selected table<string, boolean>
---@return string
local function fieldList(headers, selected)
	local fields, index = {}, 0
	for _, header in ipairs(headers) do
		if selected[header] then
			index = index + 1
			local field = header:upper():gsub("%[", "_"):gsub("%]", "")
			fields[#fields + 1] = field .. " = " .. index
		end
	end
	return concat(fields, ",\r\n\t")
end

---The rows of a file as they are written to the db file, with the columns that are written.
---@param data CsvTable
---@param selected table<string, boolean>
---@return string[]
local function rowList(data, selected)
	local rows = {}
	for _, row in ipairs(data.rows) do
		local item = {}
		for k, value in ipairs(row) do
			if selected[data.headers[k]] then
				local lv = luaValue(value)
				if lv then
					item[#item + 1] = lv
				end
			end
		end
		if #item > 0 then
			rows[#rows + 1] = "{" .. concat(item, ",") .. "}"
		end
	end
	return rows
end

---Writes the db file the library loads for the game, which hands its tables to the library.
---@param outfile string
---@param libMinor? number The version of the library the db file is for, the `MINOR` in `TaxiTimerLib.lua`.
function Parser:write(outfile, libMinor)
	local lua = {}
	lua[#lua + 1] = 'local MAJOR, MINOR = "' .. LIB_NAME .. '", ' .. (libMinor or 1) .. '\r\nlocal lib = LibStub(MAJOR, true)\r\nif not lib then return end\r\n\r\nlocal db = {} ---@class ' .. LIB_NAME .. '_DB\r\nlocal F'
	io.write(format("Writing lua file for %s...\n", self.client))

	local items = {} ---@type table<string, string[]>
	for _, name in ipairs(FILES) do
		local data = self.db[name]
		if data and name == "taxinodes" then
			data = deriveNodes(data, self.client)
		end
		if data then
			local selected = FIELDS[name]
			local list = fieldList(data.headers, selected)
			local upper = name:upper()
			lua[#lua + 1] = "\r\n" .. annotation(upper, false) .. "db." .. upper .. " = {\r\n\t" .. list .. (list ~= "" and "," or "-- TODO") .. "\r\n}"
			if name == "taxinodes" then
				local flags = {}
				for _, flag in ipairs(NODE_FLAGS) do
					flags[#flags + 1] = flag[1] .. " = " .. flag[2] .. ","
				end
				lua[#lua + 1] = "\r\n---@class " .. LIB_NAME .. "_TaxiNodeFlagsStruct\r\ndb.TAXINODEFLAGS = {\r\n\t" .. concat(flags, "\r\n\t") .. "\r\n}"
			end
			items[name] = rowList(data, selected)
		end
	end

	for _, name in ipairs(FILES) do
		local rows = items[name]
		if rows and #rows > 0 then
			lua[#lua + 1] = "\r\n" .. annotation(name:upper(), true) .. "db." .. name .. " = {}"
			local chunk = 0
			for first = 1, #rows, ROWS_PER_CHUNK do
				chunk = chunk + 1
				local last = math.min(first + ROWS_PER_CHUNK - 1, #rows)
				lua[#lua + 1] = "F = function() db." .. name .. "[" .. chunk .. "] = {" .. concat(rows, ",", first, last) .. "} end F() F = nil"
			end
		end
	end

	local file = assert(io.open(outfile, "wb"))
	file:write(concat(lua, "\r\n"), "\r\n\r\n---@diagnostic expect-next-line: deprecated\r\nlib.SetDatabase(db, MINOR)\r\n")
	file:close()
end

--
-- MARK: The svg files
--

-- what is drawn (the parsing of the csv files into taxi nodes and paths, and the svg files) is in its own file
dofile(scriptDir .. "/src/taxiparser/svg.lua")(Parser, { csv = csv, util = util, alliance = TAXI_NODE_ALLIANCE, horde = TAXI_NODE_HORDE })

return taxiparser
