-- The taxi nodes whose mount flies at another speed than the others of the taxi map, as `NODE_SPEEDS`. The whole flight is flown on the mount of the node it starts at.

---@param ctx AnalysisContext
---@param common table
---@return fun(m: SuggestMap)
return function(ctx, common)
	local util = ctx.util
	local format = string.format
	local override, secondsOff, PATH_MIN_SECONDS = common.override, common.secondsOff, common.PATH_MIN_SECONDS

	-- the flights by the taxi node they start at
	---@param flights SuggestFlight[]
	---@return table<number, SuggestFlight[]> byNode
	---@return number[] nodeOrder
	local function byStartNode(flights)
		local byNode, nodeOrder = {}, {} ---@type table<number, SuggestFlight[]>, number[]
		for _, flight in ipairs(flights) do
			local first = (flight.analysis.record.route or {})[1]
			if first then
				if not byNode[first] then
					byNode[first] = {}
					nodeOrder[#nodeOrder + 1] = first
				end
				table.insert(byNode[first], flight)
			end
		end
		table.sort(nodeOrder)
		return byNode, nodeOrder
	end

	-- the speed the flights were flown at for most of the time
	---@param flights SuggestFlight[]
	---@param scale number
	---@return number? speed
	local function dominantSpeed(flights, scale)
		local time = {} ---@type table<number, number>
		for _, flight in ipairs(flights) do
			for _, stretch in ipairs(flight.intervals) do
				if stretch.speed and stretch.yards > 0 then
					time[stretch.speed] = (time[stretch.speed] or 0) + stretch.yards / (stretch.speed * scale)
				end
			end
		end
		local dominant, dominantTime = nil, 0
		for _, speed in ipairs(util.keys(time)) do
			if time[speed] > dominantTime then
				dominant, dominantTime = speed, time[speed]
			end
		end
		return dominant
	end

	---@param m SuggestMap
	return function(m)
		local lib, map, out = m.lib, m.map, m.out
		local byNode, nodeOrder = byStartNode(m.tried)
		for _, node in ipairs(nodeOrder) do
			local nodeFlights = byNode[node]
			local dominant = dominantSpeed(nodeFlights, m.scale)
			local had = m.sim.nodes[node]
			local wanted = dominant ~= m.cruise and dominant or nil -- a node that flies like the rest of the taxi map needs none
			if dominant and wanted ~= had then
				-- how much closer the flights from the node get to how long they took
				local before = secondsOff(lib, map, nodeFlights)
				local restore = override(lib.Sim, "NODE_SPEEDS", node, wanted)
				local after = secondsOff(lib, map, nodeFlights)
				restore()
				if before - after >= PATH_MIN_SECONDS then
					local name = nodeFlights[1].analysis.data.nodeName(node)
					local count = #nodeFlights
					if wanted then
						out[#out + 1] = format("    %s NODE_SPEEDS:    [%d] = %d, -- %s (%d flight%s from it end up %.0f sec closer with it)", had and "change in" or "add to", node, wanted, name, count, count == 1 and "" or "s", before - after)
						if count < 2 then
							out[#out + 1] = "    only one flight starts at this taxi node, fly another one from it on a different path to see that it is the node and not the path"
						end
					else
						out[#out + 1] = format("    remove from NODE_SPEEDS:    [%d] = ... -- %s (the %d flight%s from it fly like the rest of the taxi map)", node, name, count, count == 1 and "" or "s")
					end
					-- a speed seen on one flight is not written, so the paths of that flight are looked at without it (otherwise it would hide what its paths need)
					if count >= 2 or not wanted then
						m.restores[#m.restores + 1] = override(lib.Sim, "NODE_SPEEDS", node, wanted)
					end
				end
			end
		end
	end
end
