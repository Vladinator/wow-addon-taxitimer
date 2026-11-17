-- What the taxi parser draws: the taxi nodes and paths of each map as svg files, from the csv files.

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
			PATH_COLORS[#PATH_COLORS + 1] = string.format("#%02x%02x%02x", r, g, b)
		end
	end
end

-- how the svg is laid out
local PADDING = 500
local SCALE = 0.25
local NODE_SCALE = 0.75
local NODE_SIZE_X, NODE_SIZE_Y = 40, 20
local NODE_FONT, NODE_FONT_MIN = 14, 6
local EDGE_SIZE, EDGE_SIZE_MIN = 5, 1

---What the svg drawing needs of the taxi parser.
---@class TaxiParserTools
---@field csv Csv
---@field util ScriptsUtil
---@field alliance number The flag of the taxi nodes of the csv files that the Alliance can use.
---@field horde number And the Horde.

---@param class TaxiParser
---@param tools TaxiParserTools
return function(class, tools)
	---@class TaxiParser
	local Parser = class
	local toInt, hasFlag = tools.csv.toInt, tools.util.hasFlag
	local format, concat = string.format, table.concat
	local floor, ceil = math.floor, math.ceil

	---@param flags number
	---@return string
	local function nodeColor(flags)
		local alliance, horde = hasFlag(flags, tools.alliance), hasFlag(flags, tools.horde)
		if alliance and horde then
			return "#ffff00"
		elseif horde then
			return "#ff0000"
		elseif alliance then
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

	-- the paths between two different taxi nodes
	---@param self TaxiParser
	---@param pdb TaxiParserDrawing
	---@return table<number, boolean> hasConnections The taxi nodes that have a path.
	local function parsePaths(self, pdb)
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
		return hasConnections
	end

	-- the taxi nodes that have a path
	---@param self TaxiParser
	---@param pdb TaxiParserDrawing
	---@param hasConnections table<number, boolean>
	local function parseNodes(self, pdb, hasConnections)
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
	end

	-- the points of each path, in flight order
	---@param self TaxiParser
	---@param pdb TaxiParserDrawing
	local function parsePoints(self, pdb)
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
	end

	-- the taxi nodes by their id, the first of each
	---@param pdb TaxiParserDrawing
	---@return table<number, TaxiParserNode>
	local function nodesById(pdb)
		local nodeById = {} ---@type table<number, TaxiParserNode>
		for _, node in ipairs(pdb.taxinodes) do
			nodeById[node.id] = nodeById[node.id] or node
		end
		return nodeById
	end

	-- the taxi nodes each node has a path to
	---@param pdb TaxiParserDrawing
	local function parseDirect(pdb)
		local nodeById = nodesById(pdb)
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
		local hasConnections = parsePaths(self, pdb)
		parseNodes(self, pdb, hasConnections)
		parsePoints(self, pdb)
		parseDirect(pdb)
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

	---Where a map is drawn: how far the coordinates are moved to be positive.
	---@class TaxiParserFrame
	---@field offsetx number
	---@field offsety number
	---@field width number
	---@field height number

	---@param pdb TaxiParserDrawing
	---@param map number
	---@return TaxiParserFrame
	local function frameOf(pdb, map)
		local minx, maxx, miny, maxy = 0xffffff, -0xffffff, 0xffffff, -0xffffff
		for _, node in ipairs(pdb.taxinodes) do
			if node.map == map then
				minx, maxx = math.min(minx, node.x), math.max(maxx, node.x)
				miny, maxy = math.min(miny, node.y), math.max(maxy, node.y)
			end
		end
		local offsetx, offsety = math.abs(minx), math.abs(miny)
		return { offsetx = offsetx, offsety = offsety, width = maxx + offsetx, height = maxy + offsety }
	end

	---@param svg string[]
	---@param pdb TaxiParserDrawing
	---@param map number
	---@param frame TaxiParserFrame
	local function drawNodes(svg, pdb, map, frame)
		for _, node in ipairs(pdb.taxinodes) do
			if node.map == map then
				local nx = node.x + frame.offsetx + PADDING
				local ny = node.y + frame.offsety + PADDING
				local label = escape(node.label)
				svg[#svg + 1] = format('<g id="node_%d" class="node"><title>%s</title><ellipse fill="%s" stroke="#000" cx="%d" cy="%d" rx="%d" ry="%d" /><text text-anchor="middle" x="%.2f" y="%.2f" font-family="Times New Roman,serif" font-size="%.2f">%s</text></g>', node.id, label, node.color, whole(nx * SCALE), whole(ny * SCALE), whole(NODE_SIZE_X * NODE_SCALE), whole(NODE_SIZE_Y * NODE_SCALE), nx * SCALE, ny * SCALE, math.max(NODE_FONT_MIN, NODE_FONT * NODE_SCALE), label)
			end
		end
	end

	---@param svg string[]
	---@param pdb TaxiParserDrawing
	---@param map number
	---@param frame TaxiParserFrame
	local function drawPoints(svg, pdb, map, frame)
		for _, pathId in ipairs(pdb.taxipathnodeOrder) do
			for i, point in ipairs(pdb.taxipathnode[pathId]) do
				if point.map == map then
					local nx = point.x + frame.offsetx + PADDING
					local ny = point.y + frame.offsety + PADDING
					local r = math.max(EDGE_SIZE_MIN, EDGE_SIZE * NODE_SCALE)
					svg[#svg + 1] = format('<g id="path_%d_%d" class="edge"><ellipse fill="%s" stroke="#ccc" cx="%d" cy="%d" rx="%d" ry="%d" /></g>', pathId, i, point.color, whole(nx * SCALE), whole(ny * SCALE), whole(r), whole(r))
				end
			end
		end
	end

	---@param svg string[]
	---@param pdb TaxiParserDrawing
	---@param map number
	---@param frame TaxiParserFrame
	local function drawLines(svg, pdb, map, frame)
		local nodeById = nodesById(pdb)
		for _, nodeId in ipairs(pdb.directOrder) do
			local from = nodeById[nodeId]
			if from then
				local direct = pdb.direct[nodeId]
				for _, toId in ipairs(direct.order) do
					local to = direct.destinations[toId]
					if to.map == map then
						local nx1 = to.x + frame.offsetx + PADDING
						local ny1 = to.y + frame.offsety + PADDING
						local nx2 = from.x + frame.offsetx + PADDING
						local ny2 = from.y + frame.offsety + PADDING
						svg[#svg + 1] = format('<line id="line_%d_%d" class="edge" stroke="%s" x1="%d" y1="%d" x2="%d" y2="%d" />', nodeId, toId + 1, to.color, whole(nx1 * SCALE), whole(ny1 * SCALE), whole(nx2 * SCALE), whole(ny2 * SCALE))
					end
				end
			end
		end
	end

	---Writes an svg file with the taxi nodes and paths of a map.
	---@param outfile string
	---@param map number
	function Parser:writeSvg(outfile, map)
		local pdb = self:parse()
		local frame = frameOf(pdb, map)
		local svg = {} ---@type string[]
		drawNodes(svg, pdb, map, frame)
		drawPoints(svg, pdb, map, frame)
		drawLines(svg, pdb, map, frame)

		-- the last things drawn are at the back
		local reversed = {} ---@type string[]
		for i = #svg, 1, -1 do
			reversed[#reversed + 1] = svg[i]
		end

		io.write(format("Writing svg file for %s...\n", tostring(map)))
		local text = '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\r\n'
			.. '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"\r\n\t"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\r\n'
			.. format('<svg width="%d" height="%d" transform="scale(1 1) rotate(0) translate(0 0)" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\r\n', whole((frame.width + PADDING * 2) * SCALE), whole((frame.height + PADDING * 2) * SCALE))
			.. concat(reversed, "\r\n")
			.. "\r\n</svg>\r\n"
		local file = assert(io.open(outfile, "wb"))
		file:write(text)
		file:close()
	end
end
