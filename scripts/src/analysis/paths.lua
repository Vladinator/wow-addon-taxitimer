-- The paths that leave the taxi nodes whose name has some text in it, for `--paths=TEXT`, to pick the flights to fly or to look up the id of a node or a path without opening the data files.

---@return fun(analyses: FlightAnalysis[], patterns: string[])
return function()
	local format = string.format

	-- how many flights flew a path, as one of the hops of their route
	---@param analyses FlightAnalysis[]
	---@param client string
	---@return table<number, number> flown By path id.
	local function countFlown(analyses, client)
		local flown = {} ---@type table<number, number>
		for _, a in ipairs(analyses) do
			if a.data.client == client and not a.incomplete then
				local route = a.record.route or {}
				for k = 2, #route do
					local id = a.data.paths[route[k - 1]] and a.data.paths[route[k - 1]][route[k]]
					if id then
						flown[id] = (flown[id] or 0) + 1
					end
				end
			end
		end
		return flown
	end

	---@param analyses FlightAnalysis[]
	---@param patterns string[] Text a name has to include, case matters.
	return function(analyses, patterns)
		local seen = {} ---@type table<string, boolean>
		for _, a in ipairs(analyses) do
			local data = a.data
			if not seen[data.client] then
				seen[data.client] = true
				local flown = countFlown(analyses, data.client)
				local ids = {} ---@type number[]
				for id, node in pairs(data.nodes) do
					for _, pattern in ipairs(patterns) do
						if node.name:find(pattern, 1, true) then
							ids[#ids + 1] = id
							break
						end
					end
				end
				table.sort(ids)
				if #ids > 0 then
					print(format("\nPaths from the taxi nodes of %s whose name has %s in it (path id, yards in a straight line, flights that flew it)", data.client, table.concat(patterns, " or ")))
				end
				for _, id in ipairs(ids) do
					local node = data.nodes[id]
					local outs = {} ---@type string[]
					for to, path in pairs(data.paths[id] or {}) do
						local target = data.nodes[to]
						if target then
							local dx, dy, dz = target.x - node.x, target.y - node.y, target.z - node.z
							outs[#outs + 1] = format("%s [%d] %.0f yd, %d", target.name, path, math.sqrt(dx * dx + dy * dy + dz * dz), flown[path] or 0)
						end
					end
					table.sort(outs)
					print(format("%s (taxi node %d, map %d): %s", node.name, id, node.map, #outs > 0 and table.concat(outs, " | ") or "no paths"))
				end
			end
		end
	end
end
