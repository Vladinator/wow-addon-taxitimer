-- The taxi data of a game, as the addon has it, with the names and positions of the taxi nodes from the csv files.

---What the analysis modules share.
---@class AnalysisContext
---@field shim Shim
---@field util ScriptsUtil
---@field csv Csv
---@field dir string The folder of the scripts.
---@field dataDir string The folder with the csv files and the recorded flights.
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
---@field client TaxiTimerLib-1.0_GameFlavor
---@field lib TaxiTimerLib-1.0 The lib for taxi data and simulation.
---@field nodes table<number, TaxiDataNode> By taxi node id.
---@field paths table<number, table<number, number>> `paths[from][to]` is the id of the first path between two taxi nodes, like the addon has it.
---@field points table<number, TaxiDataPoint> By point id.
---@field pathPoints table<number, number[]> The point ids of each path in flight order.
---@field pathEnds table<number, { from: number, to: number }> The taxi nodes each path goes between, by path id (all of the paths, also the ones `paths` does not have as there is another between the same taxi nodes).
---@field pathNames? table<number, string>
---@field nodeName fun(id: number): string
---@field pathName fun(path: number): string?

---Loads the taxi data of a game, the first time it is asked for.
---@alias TaxiDataLoader fun(client: TaxiTimerLib-1.0_GameFlavor, simFile?: string): TaxiData?, string?

---@param ctx AnalysisContext
---@return TaxiDataLoader
return function(ctx)
	local shim = ctx.shim
	local util = ctx.util

	local cache = {} ---@type table<string, TaxiData>

	---The names and positions of the taxi nodes, the db the addon has does not have them.
	---@param client TaxiTimerLib-1.0_GameFlavor
	---@return table<number, TaxiDataNode>
	local function readNodes(client)
		local nodes = {} ---@type table<number, TaxiDataNode>
		local dir = ctx.dataDir .. "/csv_" .. client
		local file = ctx.csv.read(dir, "taxinodes")
		if not file then
			util.warn("no taxinodes.csv in %s/ so the taxi nodes have no names or positions", dir)
			return nodes
		end
		local columns, rows = file.columns, file.rows
		for _, row in ipairs(rows) do
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

		-- the library of the addon with the db and sim of the game, so the simulation is the one of the addon
		local lib, err = shim.library(ctx.root, client, { sim = simFile })
		if not lib then
			return nil, string.format("unable to load the %s files of the addon: %s", client, tostring(err))
		end

		local data ---@type TaxiData
		data = {
			client = client,
			lib = lib,
			nodes = readNodes(client),
			paths = {},
			pathEnds = {},
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

		local PATH = lib.DB.TAXIPATH
		for _, chunk in ipairs(lib.DB.taxipath or {}) do
			for _, row in ipairs(chunk) do
				local from, to = row[PATH.FROMTAXINODE], row[PATH.TOTAXINODE]
				data.pathEnds[row[PATH.ID]] = { from = from, to = to }
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

		local NODE = lib.DB.TAXIPATHNODE
		for _, chunk in ipairs(lib.DB.taxipathnode or {}) do
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
