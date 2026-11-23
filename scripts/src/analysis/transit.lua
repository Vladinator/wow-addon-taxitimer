-- The taxi nodes that were only ever passed through.
-- Some taxi nodes are on the way between two taxi maps and are not places to fly from or to (Old Loamm Road between Zaralek Cavern and Ohn'ahran Plains is one): every flight that has one of them in its route flies past it, and none starts or ends there.
-- A path that starts or ends at one can not be flown on its own, so what is asked of the flights for those paths is different, and they are not suggested to be flown.
-- Flights alone do not tell them from taxi nodes that are places to fly from but that nobody started a flight at yet, so a taxi node also has to have a path to or from a taxi node with the same name on another taxi map, which is how the game joins two taxi maps.

local MIN_PASSES = 2 -- how many flights must have flown past a taxi node, and none started or ended there, for it to count

---The name of a taxi node without the name of where it is.
---@param name string
---@return string
local function baseName(name)
	return (name:match("^([^,]+)")) or name
end

---The taxi nodes that flights only passed through, with how many flights passed them. The flights are all of one game.
---@param analyses FlightAnalysis[]
---@return table<number, number> transit
return function(analyses)
	local passed = {} ---@type table<number, number>
	local ended = {} ---@type table<number, boolean>
	for _, a in ipairs(analyses) do
		local route = a.record.route
		-- a flight that was asked to land early ended at a taxi node that is not the last of its route
		if type(route) == "table" and #route >= 2 and not a.record.early then
			ended[route[1]] = true
			ended[route[#route]] = true
			for k = 2, #route - 1 do
				passed[route[k]] = (passed[route[k]] or 0) + 1
			end
		end
	end
	local transit = {} ---@type table<number, number>
	if not analyses[1] then
		return transit
	end
	local data = analyses[1].data
	for from, destinations in pairs(data.paths) do
		for to in pairs(destinations) do
			local a, b = data.nodes[from], data.nodes[to]
			-- the two ends of a path between taxi maps are taxi nodes with the same name on both
			if a and b and a.map ~= b.map and baseName(a.name) == baseName(b.name) then
				for _, node in ipairs({ from, to }) do
					local count = passed[node]
					if count and count >= MIN_PASSES and not ended[node] then
						transit[node] = count
					end
				end
			end
		end
	end
	return transit
end
