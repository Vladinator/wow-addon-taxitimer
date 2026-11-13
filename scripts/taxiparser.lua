--[[

Reads the taxi data of a game from its csv files, and writes the db file the addon loads for the game and svg files that show the taxi nodes and paths of each map.

It is used by `launcher.lua`, and runs in Lua 5.1 and later.

--]]

---A csv file.
---@class CsvTable
---@field headers string[] The names of the columns.
---@field rows string[][] The fields of each row.
---@field columns table<string, number> The index of each column by its name.

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
local FILE_NAMES = { taxinodes = { "taxinodes.csv", "TaxiNodes.csv" }, taxipath = { "taxipath.csv", "TaxiPath.csv" }, taxipathnode = { "taxipathnode.csv", "TaxiPathNode.csv" } }

-- the columns that are written to the db file, the addon relies on these (and on the order they have in the csv files)
local FIELDS = {
	taxinodes = {},
	taxipath = { ID = true, FromTaxiNode = true, ToTaxiNode = true },
	taxipathnode = { Loc_0 = true, Loc_1 = true, Loc_2 = true, ID = true, PathID = true, ContinentID = true, Flags = true, Delay = true },
}

-- what the types of the rows of each file are called in the db file
local TYPES = { TAXINODES = "TaxiNodesStruct", TAXIPATH = "TaxiPathStruct", TAXIPATHNODE = "TaxiPathNodeStruct" }

local ROWS_PER_CHUNK = 8192 -- a function has a limit to how many constants it can have

local floor, ceil = math.floor, math.ceil
local format, concat = string.format, table.concat

-- csv --------------------------------------------------------------------------------------------------------------------------

---Splits a line of a csv file into its fields, fields can be in quotes with quotes in them doubled.
---@param line string
---@return string[]
local function splitLine(line)
	local fields, count = {}, 0
	if not line:find('"', 1, true) then
		for field in (line .. ","):gmatch("([^,]*),") do
			count = count + 1
			fields[count] = field
		end
		return fields
	end
	local field, inQuotes, i = {}, false, 1
	while i <= #line do
		local c = line:sub(i, i)
		if inQuotes then
			if c == '"' then
				if line:sub(i + 1, i + 1) == '"' then
					field[#field + 1] = '"'
					i = i + 1
				else
					inQuotes = false
				end
			else
				field[#field + 1] = c
			end
		elseif c == '"' then
			inQuotes = true
		elseif c == "," then
			count = count + 1
			fields[count] = concat(field)
			field = {}
		else
			field[#field + 1] = c
		end
		i = i + 1
	end
	fields[count + 1] = concat(field)
	return fields
end

---Reads a csv file.
---@param dir string
---@param names string[] The names the file can have.
---@return CsvTable?
local function readCsv(dir, names)
	for _, name in ipairs(names) do
		local file = io.open(dir .. "/" .. name, "rb")
		if file then
			local headers = nil ---@type string[]?
			local rows = {} ---@type string[][]
			for rawLine in file:lines() do
				local line = rawLine:gsub("\r$", "")
				if line ~= "" then
					local fields = splitLine(line)
					if not headers then
						headers = fields
					else
						rows[#rows + 1] = fields
					end
				end
			end
			file:close()
			if headers then
				local columns = {} ---@type table<string, number>
				for i, header in ipairs(headers) do
					columns[header] = i
				end
				return { headers = headers, rows = rows, columns = columns }
			end
		end
	end
end

---A number from a field, 0 if it is not one.
---@param value string?
---@return number
local function toInt(value)
	local number = tonumber(value) or 0
	return number >= 0 and floor(number) or ceil(number)
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

-- the parser -----------------------------------------------------------------------------------------------------------------

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
	local file = io.open(dir .. "/" .. FILE_NAMES.taxipath[1], "rb") or io.open(dir .. "/" .. FILE_NAMES.taxipath[2], "rb")
	if file then
		file:close()
		return true
	end
	return false
end

---Reads the csv files. The points of the paths are sorted by their node index as the dumps are not in flight order, and the addon relies on that.
function Parser:read()
	local db = {} ---@type table<string, CsvTable>
	for _, name in ipairs(FILES) do
		local csv = readCsv(self.dir, FILE_NAMES[name])
		if csv then
			local columns, rows = csv.columns, csv.rows
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
			db[name] = csv
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

-- the db file ------------------------------------------------------------------------------------------------------------------

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
		return "---@type " .. type .. "DB\r\n"
	end
	return "---@class " .. type .. "\r\n"
end

---Writes the db file the addon loads for the game.
---@param outfile string
function Parser:write(outfile)
	local lua = {}
	lua[#lua + 1] = "local ns = select(2, ...) ---@class taxi_ns_db\r\nlocal F\r\n"
	lua[#lua + 1] = "ns = ns or {}"
	io.write(format("Writing lua file for %s...\n", self.client))

	local items = {} ---@type table<string, string[]>
	for _, name in ipairs(FILES) do
		local data = self.db[name]
		if data then
			local selected = FIELDS[name]
			local fields, index = {}, 0
			for _, header in ipairs(data.headers) do
				if selected[header] then
					index = index + 1
					local field = header:upper():gsub("%[", "_"):gsub("%]", "")
					fields[#fields + 1] = field .. " = " .. index
				end
			end
			local list = concat(fields, ",\r\n\t")
			local upper = name:upper()
			lua[#lua + 1] = "\r\n" .. annotation(upper, false) .. "ns." .. upper .. " = {\r\n\t" .. list .. (list ~= "" and "," or "-- TODO") .. "\r\n}"

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
			items[name] = rows
		end
	end

	for _, name in ipairs(FILES) do
		local rows = items[name]
		if rows and #rows > 0 then
			lua[#lua + 1] = "\r\n" .. annotation(name:upper(), true) .. "ns." .. name .. " = {}"
			local chunk = 0
			for first = 1, #rows, ROWS_PER_CHUNK do
				chunk = chunk + 1
				local last = math.min(first + ROWS_PER_CHUNK - 1, #rows)
				lua[#lua + 1] = "F = function() ns." .. name .. "[" .. chunk .. "] = {" .. concat(rows, ",", first, last) .. "} end F() F = nil"
			end
		end
	end

	local file = assert(io.open(outfile, "wb"))
	file:write(concat(lua, "\r\n"), "\r\n\r\nreturn ns\r\n")
	file:close()
end

-- the svg files ----------------------------------------------------------------------------------------------------------------

-- the maps the coordinates are rotated and flipped for, others are reported
local KNOWN_MAPS = {} ---@type table<number, boolean>
for _, map in ipairs({ 3, 12, 9770568, 654135852, -1, 0, 1, 30, 451, 530, 560, 571, 603, 606, 609, 622, 631, 646, 870, 967, 1014, 1116, 1159, 1190, 1191, 1220, 1464, 1473, 1481, 1519, 1529, 1560, 1623, 1642, 1643, 1666, 1669, 1693, 1718, 1795, 1817, 2175, 2222, 2224, 2228, 2305, 1550, 1549, 2481, 2374, 2444, 2454, 2516, 2548, 2552, 2601, 2657, 2706, 2736, 2738, 2735, 2771, 2965, 2694, 3043, 3047, 3075, 2916 }) do
	KNOWN_MAPS[map] = true
end

-- the colors of the paths
local PATH_COLORS = {} ---@type string[]
for r = 64, 254, 32 do
	for g = 64, 254, 32 do
		for b = 64, 254, 32 do
			PATH_COLORS[#PATH_COLORS + 1] = format("#%02x%02x%02x", r, g, b)
		end
	end
end

---@param flags number
---@return string
local function nodeColor(flags)
	if flags % 4 == 3 then
		return "#ffff00"
	elseif flags % 4 >= 2 then
		return "#ff0000"
	elseif flags % 2 == 1 then
		return "#0000ff"
	end
	return "#ccc"
end

---@param degrees number
---@return number
local function deg2rad(degrees)
	return (degrees / 180) * math.pi
end

---Rotates and flips the coordinates for the map.
---@param x number
---@param y number
---@param map number
---@return number x
---@return number y
function Parser:rotate(x, y, map)
	if not KNOWN_MAPS[map] then
		self.unknownMaps = self.unknownMaps or {}
		if not self.unknownMaps[map] then
			self.unknownMaps[map] = true
			io.write(format("[%s] new map can't rotate and flip coordinate system\n", tostring(map)))
		end
	end
	local sin = deg2rad(-90)
	local cos = deg2rad(0)
	local nx = x * cos - y * sin
	local ny = x * sin + y * cos
	return nx * -1, ny * 1
end

---Parses the csv files into what is drawn.
---@return TaxiParserDrawing
function Parser:parse()
	if self.pdb then
		return self.pdb
	end
	local pdb = { taxipath = {}, taxinodes = {}, taxipathnode = {}, taxipathnodeOrder = {}, direct = {}, directOrder = {} } ---@type TaxiParserDrawing
	if not self:canProcess() then
		return pdb
	end

	local hasConnections = {} ---@type table<number, boolean>
	local paths = self.db.taxipath
	local pointer = 0
	for _, row in ipairs(paths.rows) do
		local id, from, to = toInt(row[paths.columns.ID]), toInt(row[paths.columns.FromTaxiNode]), toInt(row[paths.columns.ToTaxiNode])
		if from ~= 0 and to ~= 0 and from ~= to then
			hasConnections[from] = true
			hasConnections[to] = true
			pointer = pointer + 1
			if pointer >= #PATH_COLORS then
				pointer = 0
			end
			pdb.taxipath[#pdb.taxipath + 1] = { id = id, from = from, to = to, color = PATH_COLORS[pointer + 1] }
		end
	end

	local nodes = self.db.taxinodes
	local c = nodes.columns
	for _, row in ipairs(nodes.rows) do
		local id = toInt(row[c.ID])
		if hasConnections[id] then
			local map = toInt(row[c.ContinentID])
			local flags = toInt(row[c.Flags])
			local x, y = self:rotate(tonumber(row[c.Pos_0]) or 0, tonumber(row[c.Pos_1]) or 0, map)
			pdb.taxinodes[#pdb.taxinodes + 1] = { label = (row[c.Name_lang] or ""):gsub('"', ""), x = x, y = y, z = tonumber(row[c.Pos_2]) or 0, id = id, map = map, flags = flags, color = nodeColor(flags) }
		end
	end

	-- the points of each path, in flight order
	local points = self.db.taxipathnode
	local pc = points.columns
	local pointsByPath = {} ---@type table<number, string[][]>
	for _, row in ipairs(points.rows) do
		local pathId = toInt(row[pc.PathID])
		local list = pointsByPath[pathId]
		if not list then
			list = {}
			pointsByPath[pathId] = list
		end
		list[#list + 1] = row
	end
	for _, path in ipairs(pdb.taxipath) do
		local list = pointsByPath[path.id]
		if list then
			local edges = pdb.taxipathnode[path.id]
			if not edges then
				edges = {}
				pdb.taxipathnode[path.id] = edges
				pdb.taxipathnodeOrder[#pdb.taxipathnodeOrder + 1] = path.id
			end
			for _, row in ipairs(list) do
				local map = toInt(row[pc.ContinentID])
				local x, y = self:rotate(tonumber(row[pc.Loc_0]) or 0, tonumber(row[pc.Loc_1]) or 0, map)
				edges[#edges + 1] = { id = toInt(row[pc.ID]), pathid = path.id, x = x, y = y, z = tonumber(row[pc.Loc_2]) or 0, map = map, color = path.color }
			end
		end
	end

	-- the taxi nodes each node has a path to
	local nodeById = {} ---@type table<number, TaxiParserNode>
	for _, node in ipairs(pdb.taxinodes) do
		nodeById[node.id] = nodeById[node.id] or node
	end
	for _, node in ipairs(pdb.taxinodes) do
		local destinations, order = {}, {} ---@type table<number, TaxiParserNode>, number[]
		for _, path in ipairs(pdb.taxipath) do
			if path.from == node.id and node.id ~= path.to then
				local destination = nodeById[path.to]
				if destination then
					if not destinations[path.to] then
						order[#order + 1] = path.to
					end
					destinations[path.to] = destination
				end
			end
		end
		if not pdb.direct[node.id] then
			pdb.directOrder[#pdb.directOrder + 1] = node.id
		end
		pdb.direct[node.id] = { destinations = destinations, order = order }
	end

	self.pdb = pdb
	return pdb
end

---Returns the maps that have taxi nodes, in rising order.
---@return number[]
function Parser:getMaps()
	local maps, seen = {}, {} ---@type number[], table<number, boolean>
	local nodes = self.db.taxinodes
	if not self:canProcess() then
		return maps
	end
	for _, row in ipairs(nodes.rows) do
		local map = toInt(row[nodes.columns.ContinentID])
		if not seen[map] then
			seen[map] = true
			maps[#maps + 1] = map
		end
	end
	table.sort(maps)
	return maps
end

---What is written in the svg file for text.
---@param text string
---@return string
local function escape(text)
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#039;"))
end

---A number for a `%d`, the way a number is made a whole number when it is converted.
---@param number number
---@return number
local function whole(number)
	if number ~= number or number == math.huge or number == -math.huge then
		return 0
	end
	return number >= 0 and floor(number) or ceil(number)
end

---Writes an svg file with the taxi nodes and paths of a map.
---@param outfile string
---@param map number
function Parser:writeSvg(outfile, map)
	local pdb = self:parse()
	local svg = {} ---@type string[]

	local minx, maxx, miny, maxy = 0xffffff, -0xffffff, 0xffffff, -0xffffff
	for _, node in ipairs(pdb.taxinodes) do
		if node.map == map then
			minx, maxx = math.min(minx, node.x), math.max(maxx, node.x)
			miny, maxy = math.min(miny, node.y), math.max(maxy, node.y)
		end
	end
	local offsetx, offsety = math.abs(minx), math.abs(miny)
	local width, height = maxx + offsetx, maxy + offsety

	local padding = 500
	local scale = 0.25
	local nodescale = 0.75
	local nodesizex, nodesizey = 40, 20
	local nodefont, nodefontmin = 14, 6
	local edgesize, edgesizemin = 5, 1

	for _, node in ipairs(pdb.taxinodes) do
		if node.map == map then
			local nx = node.x + offsetx + padding
			local ny = node.y + offsety + padding
			local label = escape(node.label)
			svg[#svg + 1] = format('<g id="node_%d" class="node"><title>%s</title><ellipse fill="%s" stroke="#000" cx="%d" cy="%d" rx="%d" ry="%d" /><text text-anchor="middle" x="%.2f" y="%.2f" font-family="Times New Roman,serif" font-size="%.2f">%s</text></g>', node.id, label, node.color, whole(nx * scale), whole(ny * scale), whole(nodesizex * nodescale), whole(nodesizey * nodescale), nx * scale, ny * scale, math.max(nodefontmin, nodefont * nodescale), label)
		end
	end

	for _, pathId in ipairs(pdb.taxipathnodeOrder) do
		for i, point in ipairs(pdb.taxipathnode[pathId]) do
			if point.map == map then
				local nx = point.x + offsetx + padding
				local ny = point.y + offsety + padding
				local r = math.max(edgesizemin, edgesize * nodescale)
				svg[#svg + 1] = format('<g id="path_%d_%d" class="edge"><ellipse fill="%s" stroke="#ccc" cx="%d" cy="%d" rx="%d" ry="%d" /></g>', pathId, i, point.color, whole(nx * scale), whole(ny * scale), whole(r), whole(r))
			end
		end
	end

	local nodeById = {} ---@type table<number, TaxiParserNode>
	for _, node in ipairs(pdb.taxinodes) do
		nodeById[node.id] = nodeById[node.id] or node
	end
	for _, nodeId in ipairs(pdb.directOrder) do
		local from = nodeById[nodeId]
		if from then
			local direct = pdb.direct[nodeId]
			for _, toId in ipairs(direct.order) do
				local to = direct.destinations[toId]
				if to.map == map then
					local nx1 = to.x + offsetx + padding
					local ny1 = to.y + offsety + padding
					local nx2 = from.x + offsetx + padding
					local ny2 = from.y + offsety + padding
					svg[#svg + 1] = format('<line id="line_%d_%d" class="edge" stroke="%s" x1="%d" y1="%d" x2="%d" y2="%d" />', nodeId, toId + 1, to.color, whole(nx1 * scale), whole(ny1 * scale), whole(nx2 * scale), whole(ny2 * scale))
				end
			end
		end
	end

	-- the last things drawn are at the back
	local reversed = {} ---@type string[]
	for i = #svg, 1, -1 do
		reversed[#reversed + 1] = svg[i]
	end

	io.write(format("Writing svg file for %s...\n", tostring(map)))
	local text = '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\r\n'
		.. '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"\r\n\t"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\r\n'
		.. format('<svg width="%d" height="%d" transform="scale(1 1) rotate(0) translate(0 0)" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\r\n', whole((width + padding * 2) * scale), whole((height + padding * 2) * scale))
		.. concat(reversed, "\r\n")
		.. "\r\n</svg>\r\n"
	local file = assert(io.open(outfile, "wb"))
	file:write(text)
	file:close()
end

return taxiparser
