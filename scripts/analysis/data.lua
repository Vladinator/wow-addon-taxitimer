-- The taxi data of a game, as the addon has it, with the names and positions of the taxi nodes from the csv files.

---What the analysis modules share.
---@class AnalysisContext
---@field shim Shim
---@field util AnalysisUtil
---@field dir string The folder of the scripts.
---@field root string The folder of the addon.
---@field reload? fun() Forgets the taxi data that was loaded, so the files of the addon are read again (after the sim file was changed).

---A taxi node from the csv files.
---@class TaxiDataNode
---@field name string
---@field x number
---@field y number
---@field z number
---@field map number

---A point of a path, as the addon has it in its db.
---@class TaxiDataPoint
---@field x number
---@field y number
---@field z number
---@field map number
---@field flags number
---@field delay number
---@field path number The path the point is on.
---@field index number The position in the path, starting at 1.

---The taxi data of a game, and the simulation of the addon for it.
---@class TaxiData
---@field client TaxiFlavor
---@field ns taxi_ns_db The files of the addon for the game, without `core.lua`.
---@field nodes table<number, TaxiDataNode> By taxi node id.
---@field paths table<number, table<number, number>> `paths[from][to]` is the id of the first path between two taxi nodes, like the addon has it.
---@field points table<number, TaxiDataPoint> By point id.
---@field pathPoints table<number, number[]> The point ids of each path in flight order.
---@field pathNames? table<number, string>
---@field nodeName fun(id: number): string
---@field pathName fun(path: number): string?

---Loads the taxi data of a game, the first time it is asked for.
---@alias TaxiDataLoader fun(client: TaxiFlavor, simFile?: string): TaxiData?, string?

---@param ctx AnalysisContext
---@return TaxiDataLoader
return function(ctx)
	local shim = ctx.shim
	local util = ctx.util

	local cache = {} ---@type table<string, TaxiData>

	---Reads a csv file into a list of rows that are lists of fields. Fields can be in quotes, with quotes in them doubled.
	---@param text string
	---@return string[][]
	local function readCsv(text)
		local rows, row, field = {}, {}, {}
		local inQuotes = false
		local i, length = 1, #text
		while i <= length do
			local c = text:sub(i, i)
			if inQuotes then
				if c == '"' then
					if text:sub(i + 1, i + 1) == '"' then
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
				row[#row + 1] = table.concat(field)
				field = {}
			elseif c == "\n" then
				row[#row + 1] = table.concat(field)
				field = {}
				rows[#rows + 1] = row
				row = {}
			elseif c ~= "\r" then
				field[#field + 1] = c
			end
			i = i + 1
		end
		if #field > 0 or #row > 0 then
			row[#row + 1] = table.concat(field)
			rows[#rows + 1] = row
		end
		return rows
	end

	---The names and positions of the taxi nodes, the db the addon has does not have them.
	---@param client TaxiFlavor
	---@return table<number, TaxiDataNode>
	local function readNodes(client)
		local nodes = {} ---@type table<number, TaxiDataNode>
		local dir = ctx.dir .. "/csv_" .. client .. "/"
		local text
		for _, name in ipairs({ "taxinodes.csv", "TaxiNodes.csv" }) do
			text = shim.readfile(dir .. name)
			if text then
				break
			end
		end
		if not text then
			util.warn("no taxinodes.csv in %s so the taxi nodes have no names or positions", dir)
			return nodes
		end
		local rows = readCsv(text)
		local columns = {} ---@type table<string, number>
		for i, name in ipairs(rows[1] or {}) do
			columns[name] = i
		end
		for r = 2, #rows do
			local row = rows[r]
			local id = tonumber(row[columns.ID or 0])
			if id then
				nodes[id] = {
					name = row[columns.Name_lang or 0] or ("node " .. id),
					x = tonumber(row[columns.Pos_0 or 0]) or 0,
					y = tonumber(row[columns.Pos_1 or 0]) or 0,
					z = tonumber(row[columns.Pos_2 or 0]) or 0,
					map = tonumber(row[columns.ContinentID or 0]) or 0,
				}
			end
		end
		return nodes
	end

	ctx.reload = function()
		cache = {}
	end

	return function(client, simFile)
		if cache[client] then
			return cache[client]
		end

		-- the files of the addon that the game loads, so the simulation is the one of the addon
		local ns, err = shim.addon(ctx.root, client, { exclude = { "core.lua" }, sim = simFile })
		if not ns then
			return nil, string.format("unable to load the %s files of the addon: %s", client, tostring(err))
		end

		local data ---@type TaxiData
		data = {
			client = client,
			ns = ns,
			nodes = readNodes(client),
			paths = {},
			points = {},
			pathPoints = {},
			nodeName = function(id)
				local node = data.nodes[id]
				return node and node.name or ("node " .. tostring(id))
			end,
			-- the name of each path, going by the taxi nodes it connects
			pathName = function(path)
				if not data.pathNames then
					data.pathNames = {}
					for from, destinations in pairs(data.paths) do
						for to, id in pairs(destinations) do
							data.pathNames[id] = data.nodeName(from) .. " > " .. data.nodeName(to)
						end
					end
				end
				return data.pathNames[path]
			end,
		}

		local PATH = ns.TAXIPATH
		for _, chunk in ipairs(ns.taxipath or {}) do
			for _, row in ipairs(chunk) do
				local from, to = row[PATH.FROMTAXINODE], row[PATH.TOTAXINODE]
				local destinations = data.paths[from]
				if not destinations then
					destinations = {}
					data.paths[from] = destinations
				end
				if not destinations[to] then
					destinations[to] = row[PATH.ID]
				end
			end
		end

		local NODE = ns.TAXIPATHNODE
		for _, chunk in ipairs(ns.taxipathnode or {}) do
			for _, row in ipairs(chunk) do
				local path = row[NODE.PATHID]
				local list = data.pathPoints[path]
				if not list then
					list = {}
					data.pathPoints[path] = list
				end
				list[#list + 1] = row[NODE.ID]
				data.points[row[NODE.ID]] = {
					x = row[NODE.LOC_0],
					y = row[NODE.LOC_1],
					z = row[NODE.LOC_2],
					map = row[NODE.CONTINENTID],
					flags = row[NODE.FLAGS],
					delay = row[NODE.DELAY],
					path = path,
					index = #list,
				}
			end
		end

		cache[client] = data
		return data
	end
end
