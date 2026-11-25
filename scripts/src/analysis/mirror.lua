-- Writes the joins and the stops that were written to the sim file of one game into the sim files of the other games that have the same paths.
-- The games fly the same paths where the taxi data says so (what `vanilla` has is mostly what `forever` has, as `forever` is that and more), so how a corner is cut at a taxi node there is how it is cut in the other. That is only taken for granted where the points of the paths are the same in both, a path with other points would have other points for the numbers of a join to mean.
-- A corner that flights of the game flew is left to them: they say how it is flown there, which is more accurate than what another game does. What the game has for one that no flight of it flew is made the same, so a change is carried on to it.
-- The speeds are not written: they are mostly one speed for all of a game, and the flights of the game say.

local GAMES = { "mainline", "forever", "classic", "vanilla" }

local TABLES = { NODE_JOINS = true, NODE_STOPS = true, NODE_STOP_OFFSETS = true }

---@param ctx AnalysisContext
---@param loadData TaxiDataLoader
---@param applyChanges ApplyChanges
---@return fun(client: TaxiTimerLib-1.0_GameFlavor, simFile: string, written: string[], analyses: FlightAnalysis[]): number mirror
---@return fun(client: TaxiTimerLib-1.0_GameFlavor, simFile: string, analyses: FlightAnalysis[]): number all
return function(ctx, loadData, applyChanges)
	local util, shim = ctx.util, ctx.shim
	local format = string.format

	-- if two paths have the same points in the same order
	---@param a TaxiData
	---@param pathA number
	---@param b TaxiData
	---@param pathB number
	---@return boolean
	local function samePath(a, pathA, b, pathB)
		local pointsA, pointsB = a.pathPoints[pathA], b.pathPoints[pathB]
		if not pointsA or not pointsB or #pointsA ~= #pointsB then
			return false
		end
		for i = 1, #pointsA do
			local p, q = a.points[pointsA[i]], b.points[pointsB[i]]
			if not p or not q or p.map ~= q.map or format("%.1f %.1f %.1f", p.x, p.y, p.z) ~= format("%.1f %.1f %.1f", q.x, q.y, q.z) then
				return false
			end
		end
		return true
	end

	-- if the path from one taxi node to another is the same in both games
	---@param a TaxiData
	---@param b TaxiData
	---@param from number
	---@param to number
	---@return boolean
	local function sameRoute(a, b, from, to)
		local pathA = a.paths[from] and a.paths[from][to]
		local pathB = b.paths[from] and b.paths[from][to]
		return pathA ~= nil and pathB ~= nil and samePath(a, pathA, b, pathB)
	end

	-- the taxi node the entry is for, and the taxi nodes it comes from and goes on to (`to` is `nil` for a stop for all of them)
	---@param text string
	---@return string? name
	---@return number? node
	---@return number? from
	---@return number? to
	---@return boolean? removes
	local function parse(text)
		local action, name = text:match("^%s*(%a+) %a+ ([A-Z_]+):")
		if not TABLES[name] then
			return
		end
		local node, from, to = text:match("%[(%d+)%] = { %[(%d+)%] = { %[(%d+)%] = ")
		if not node then
			node, from = text:match("%[(%d+)%] = { %[(%d+)%] = %d+ }")
		end
		return name, tonumber(node), tonumber(from), tonumber(to), action == "remove"
	end

	-- what a suggestion sets, to compare it with what the sim file of a game has
	---@param text string
	---@return string?
	local function valueOf(text)
		local last, first = text:match("= { (%d+), (%d+) } } }")
		if last then
			return last .. "," .. first
		end
		local seconds = text:match("= ([%d.]+) } }") or text:match("%[%d+%] = { %[%d+%] = ([%d.]+) }")
		return seconds and format("%.1f", tonumber(seconds) or 0) or nil
	end

	-- what the sim file of the game has for the same, in the same form as `valueOf`
	---@param data TaxiData
	---@param name string
	---@param node number
	---@param from number
	---@param to? number
	---@return string?
	local function currentOf(data, name, node, from, to)
		local ofNode = data.lib.Sim[name][node]
		local ofFrom = ofNode and ofNode[from]
		local value = type(ofFrom) == "table" and to and ofFrom[to] or (type(ofFrom) == "number" and ofFrom) or nil
		if type(value) == "table" then
			return value[1] .. "," .. value[2]
		end
		return value and format("%.1f", value) or nil
	end

	-- if flights of a game flew past a taxi node coming from another, and on to a third if there is one
	---@param analyses FlightAnalysis[]
	---@param game TaxiTimerLib-1.0_GameFlavor
	---@param node number
	---@param from number
	---@param to? number
	---@return boolean
	local function flown(analyses, game, node, from, to)
		for _, a in ipairs(analyses) do
			local route = a.data.client == game and not a.incomplete and a.record.route or {}
			for k = 2, #route - 1 do
				if route[k] == node and route[k - 1] == from and (to == nil or route[k + 1] == to) then
					return true
				end
			end
		end
		return false
	end

	-- Writes what was written to the sim file of `client` into the sim files of the games that fly the same paths.
	---@param client TaxiTimerLib-1.0_GameFlavor
	---@param simFile string The sim file that was written.
	---@param written string[] The suggestions that were written to it.
	---@param analyses FlightAnalysis[] All of the flights.
	---@return number mirrored How many were written to the others.
	local function mirror(client, simFile, written, analyses)
		local count = 0
		local data = loadData(client)
		for _, other in ipairs(GAMES) do
			local otherFile = simFile:gsub("sim_" .. client .. "%.lua$", "sim_" .. other .. ".lua")
			local otherData = other ~= client and otherFile ~= simFile and shim.readfile(otherFile) and loadData(other) or nil
			if data and otherData then
				local lines, different, existing, theirs = {}, 0, 0, 0 ---@type string[], number, number, number
				for _, text in ipairs(written) do
					local name, node, from, to, removes = parse(text)
					if name and node and from then
						-- the path it arrives by, and the path it leaves by if it is for one of them
						local same = sameRoute(data, otherData, from, node) and (to == nil or sameRoute(data, otherData, node, to))
						if not same then
							different = different + 1
						elseif removes and currentOf(otherData, name, node, from, to) == nil then
							existing = existing + 1
						elseif not removes and currentOf(otherData, name, node, from, to) == valueOf(text) then
							existing = existing + 1
						elseif flown(analyses, other, node, from, to) then
							theirs = theirs + 1
						else
							lines[#lines + 1] = text
						end
					end
				end
				if #lines > 0 then
					local applied = applyChanges(otherFile, lines, otherData, true)
					count = count + applied
					print(format("  %d of them are also written to %s, as the paths are the same in %s", applied, otherFile, other))
				end
				if different > 0 then
					print(format("  %d of them are not written to %s, as the paths have other points in %s", different, otherFile, other))
				end
				if theirs > 0 then
					print(format("  %d of them are not written to %s, as flights of %s flew there and say how it is flown", theirs, otherFile, other))
				end
				if existing > 0 then
					util.printf("  %d of them are already in %s\n", existing, otherFile)
				end
			end
		end
		return count
	end

	-- what the sim file of a game has now, as the suggestions that would write it
	---@param data TaxiData
	---@return string[]
	local function entriesOf(data)
		local lines = {} ---@type string[]
		for _, node in ipairs(util.keys(data.lib.Sim.NODE_JOINS)) do
			for _, from in ipairs(util.keys(data.lib.Sim.NODE_JOINS[node])) do
				for _, to in ipairs(util.keys(data.lib.Sim.NODE_JOINS[node][from])) do
					local join = data.lib.Sim.NODE_JOINS[node][from][to]
					lines[#lines + 1] = format("add to NODE_JOINS:    [%d] = { [%d] = { [%d] = { %d, %d } } }, -- sim file", node, from, to, join[1], join[2])
				end
			end
		end
		for _, node in ipairs(util.keys(data.lib.Sim.NODE_STOP_OFFSETS)) do
			for _, from in ipairs(util.keys(data.lib.Sim.NODE_STOP_OFFSETS[node])) do
				local ofFrom = data.lib.Sim.NODE_STOP_OFFSETS[node][from]
				if type(ofFrom) == "number" then
					lines[#lines + 1] = format("add to NODE_STOP_OFFSETS:    [%d] = { [%d] = %.1f }, -- sim file", node, from, ofFrom)
				else
					for _, to in ipairs(util.keys(ofFrom)) do
						lines[#lines + 1] = format("add to NODE_STOP_OFFSETS:    [%d] = { [%d] = { [%d] = %.1f } }, -- sim file", node, from, to, ofFrom[to])
					end
				end
			end
		end
		for _, node in ipairs(util.keys(data.lib.Sim.NODE_STOPS)) do
			for _, from in ipairs(util.keys(data.lib.Sim.NODE_STOPS[node])) do
				local ofFrom = data.lib.Sim.NODE_STOPS[node][from]
				if type(ofFrom) == "number" then
					lines[#lines + 1] = format("add to NODE_STOPS:    [%d] = { [%d] = %d }, -- sim file", node, from, ofFrom)
				else
					for _, to in ipairs(util.keys(ofFrom)) do
						lines[#lines + 1] = format("add to NODE_STOPS:    [%d] = { [%d] = { [%d] = %d } }, -- sim file", node, from, to, ofFrom[to])
					end
				end
			end
		end
		return lines
	end

	-- Writes everything the sim file of a game has into the sim files of the other games that fly the same paths, for what they do not have yet.
	---@param client TaxiTimerLib-1.0_GameFlavor
	---@param simFile string
	---@param analyses FlightAnalysis[]
	---@return number mirrored
	local function mirrorAll(client, simFile, analyses)
		local data = loadData(client)
		return data and mirror(client, simFile, entriesOf(data), analyses) or 0
	end

	return mirror, mirrorAll
end
