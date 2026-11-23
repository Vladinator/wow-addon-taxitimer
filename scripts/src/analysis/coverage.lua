-- How much of each map has been flown, and where to fly next, for `--coverage`.

---What the flights of a game flew.
---@class AnalysisCoverage
---@field data TaxiData
---@field flights table<number, number> The flights by the map their taxi nodes are on.
---@field started table<number, boolean> The taxi nodes flights started at.
---@field passed table<number, boolean> The taxi nodes flights flew past.
---@field paths table<number, boolean> The paths that were flown.
---@field single table<number, boolean> The paths that were flown on a flight of just two taxi nodes, which tells how long the path takes on its own.
---@field transit table<number, number> The taxi nodes that flights only passed through, which are not places to fly from or to.

---The taxi nodes and the paths of a map.
---@class AnalysisCoverageMap
---@field nodes number[]
---@field paths number How many paths there are.
---@field flown number How many of them were flown.
---@field open { from: number, to: number, never: boolean, yards: number }[] The paths a flight of their own would tell something about.

local MIN_FLIGHT_YARDS = 100 -- paths between taxi nodes closer than this are too short to be worth a flight

---@param ctx AnalysisContext
---@return fun(analyses: FlightAnalysis[])
return function(ctx)
	local util = ctx.util
	local printf = util.printf
	local format = string.format
	local findTransit = dofile(ctx.dir .. "/src/analysis/transit.lua")

	-- taxi nodes that are not for players: hidden hubs, teleport networks, quest paths and test nodes
	---@param name string
	---@return boolean
	local function isHidden(name)
		return name:find("^%[?[Hh][Ii][Dd][Dd][Ee][Nn]") ~= nil or name:find("Teleport") ~= nil or name:find("^Quest") ~= nil or name:find("^TEMP") ~= nil or name:find("^[Tt][Ee][Ss][Tt]") ~= nil
	end

	-- what the flights of each game flew
	---@param analyses FlightAnalysis[]
	---@return table<string, AnalysisCoverage> clients
	---@return string[] clientOrder
	local function collect(analyses)
		local clients, clientOrder = {}, {} ---@type table<string, AnalysisCoverage>, string[]
		for _, a in ipairs(analyses) do
			local route = a.record.route or {}
			if not a.incomplete and #route >= 2 then
				local name = a.data.client
				local seen = clients[name]
				if not seen then
					seen = { data = a.data, flights = {}, started = {}, passed = {}, paths = {}, single = {}, transit = {} }
					clients[name] = seen
					clientOrder[#clientOrder + 1] = name
				end
				local first = a.data.nodes[route[1]]
				if first then
					seen.flights[first.map] = (seen.flights[first.map] or 0) + 1
				end
				seen.started[route[1]] = true
				for k = 2, #route do
					local path = a.data.paths[route[k - 1]] and a.data.paths[route[k - 1]][route[k]]
					if path then
						seen.paths[path] = true
						if #route == 2 then
							seen.single[path] = true
						end
					end
					if k < #route then
						seen.passed[route[k]] = true
					end
				end
			end
		end
		return clients, clientOrder
	end

	-- the taxi nodes and the paths of each map
	---@param seen AnalysisCoverage
	---@return table<number, AnalysisCoverageMap>
	local function mapsOf(seen)
		local data = seen.data
		local maps = {} ---@type table<number, AnalysisCoverageMap>
		for id, node in pairs(data.nodes) do
			if data.paths[id] and next(data.paths[id]) then -- taxi nodes without paths can not be flown from
				local map = maps[node.map]
				if not map then
					map = { nodes = {}, paths = 0, flown = 0, open = {} }
					maps[node.map] = map
				end
				map.nodes[#map.nodes + 1] = id
				for to, path in pairs(data.paths[id]) do
					map.paths = map.paths + 1
					map.flown = map.flown + (seen.paths[path] and 1 or 0)
					-- what a flight of only that path would tell: a path never flown, or only flown as part of a longer flight
					local target = data.nodes[to]
					if not seen.single[path] and target and not isHidden(node.name) and not isHidden(target.name) and not seen.transit[id] and not seen.transit[to] then
						local dx, dy, dz = target.x - node.x, target.y - node.y, target.z - node.z
						local yards = math.sqrt(dx * dx + dy * dy + dz * dz)
						if yards >= MIN_FLIGHT_YARDS then
							map.open[#map.open + 1] = { from = id, to = to, never = not seen.paths[path], yards = yards }
						end
					end
				end
			end
		end
		return maps
	end

	-- the names of the first of the taxi nodes
	---@param data TaxiData
	---@param ids number[]
	---@param limit number
	---@return string
	local function names(data, ids, limit)
		table.sort(ids)
		local list = {}
		for i = 1, math.min(limit, #ids) do
			list[i] = data.nodeName(ids[i])
		end
		return table.concat(list, "; ") .. (#ids > limit and format(" (and %d more)", #ids - limit) or "")
	end

	-- a map that has flights: how much of it is flown, and the paths to fly next
	---@param seen AnalysisCoverage
	---@param id number
	---@param map AnalysisCoverageMap
	local function printMap(seen, id, map)
		local data = seen.data
		local started, notStarted, passed = 0, {}, 0
		for _, node in ipairs(map.nodes) do
			if seen.started[node] then
				started = started + 1
			else
				notStarted[#notStarted + 1] = node
			end
			passed = passed + (seen.passed[node] and 1 or 0)
		end
		printf("  map %d: %d flights, %d of %d paths flown, started at %d of %d taxi nodes, flew past %d\n", id, seen.flights[id], map.flown, map.paths, started, #map.nodes, passed)
		if #notStarted > 0 then
			printf("    no flight starts at: %s\n", names(data, notStarted, 6))
		end
		-- the paths to fly next, a small map shows all of them and a big one the shortest
		table.sort(map.open, function(a, b)
			if a.never ~= b.never then
				return a.never
			end
			return a.yards < b.yards
		end)
		local limit = map.paths <= 30 and #map.open or 5
		for i = 1, math.min(limit, #map.open) do
			local open = map.open[i]
			printf("    %s: %s > %s (%.0f yd)\n", open.never and "not flown" or "only flown as part of longer flights", data.nodeName(open.from), data.nodeName(open.to), open.yards)
		end
		if #map.open > limit then
			printf("    and %d more paths without a flight of their own\n", #map.open - limit)
		end
	end

	-- the maps without flights, the ones with the most taxi nodes first
	---@param data TaxiData
	---@param maps table<number, AnalysisCoverageMap>
	---@param without number[]
	local function printWithout(data, maps, without)
		table.sort(without, function(a, b)
			if #maps[a].nodes ~= #maps[b].nodes then
				return #maps[a].nodes > #maps[b].nodes
			end
			return a < b
		end)
		if #without > 0 then
			print("  maps without flights, the ones with the most taxi nodes first")
			for i = 1, math.min(15, #without) do
				local id = without[i]
				printf("    map %d: %d taxi nodes, %d paths, like %s\n", id, #maps[id].nodes, maps[id].paths, names(data, maps[id].nodes, 3))
			end
			if #without > 15 then
				printf("    and %d more maps with fewer taxi nodes\n", #without - 15)
			end
		end
	end

	return function(analyses)
		local clients, clientOrder = collect(analyses)
		local byClient = {} ---@type table<string, FlightAnalysis[]>
		for _, a in ipairs(analyses) do
			byClient[a.data.client] = byClient[a.data.client] or {}
			table.insert(byClient[a.data.client], a)
		end
		for _, name in ipairs(clientOrder) do
			local seen = clients[name]
			seen.transit = findTransit(byClient[name] or {})
			local maps = mapsOf(seen)
			printf("\nWhere the %s flights are (the maps are the ones the taxi nodes are on, the taxi nodes of both factions are counted)\n", name)
			local with, without = {}, {} ---@type number[], number[]
			for id in pairs(maps) do
				if seen.flights[id] then
					with[#with + 1] = id
				else
					without[#without + 1] = id
				end
			end
			table.sort(with, function(a, b)
				return maps[a].flown / maps[a].paths < maps[b].flown / maps[b].paths
			end)
			for _, id in ipairs(with) do
				printMap(seen, id, maps[id])
			end
			local transitNodes = {} ---@type number[]
			for node in pairs(seen.transit) do
				transitNodes[#transitNodes + 1] = node
			end
			if #transitNodes > 0 then
				printf("  taxi nodes that flights only pass through, which are not places to fly from or to, so they are left out of the paths to fly: %s\n", names(seen.data, transitNodes, 8))
			end
			printWithout(seen.data, maps, without)
		end
	end
end
