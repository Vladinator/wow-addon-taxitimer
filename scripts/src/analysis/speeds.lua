-- The speed each path was flown at from each of its points, for `--speeds`.

---@param ctx AnalysisContext
---@return fun(analyses: FlightAnalysis[])
return function(ctx)
	local util = ctx.util
	local printf = util.printf
	local format = string.format

	-- how many different speeds a path was flown at
	---@param info table The speeds by point.
	---@return number
	local function countSpeeds(info)
		local distinct, count = {}, 0
		for _, speed in pairs(info.speeds) do
			if not distinct[speed] then
				distinct[speed] = true
				count = count + 1
			end
		end
		return count
	end

	-- a line for the `PATH_SPEEDS` table of the sim file with where the speed changed and how sure it is
	---@param a FlightAnalysis
	---@param path number
	---@param info table
	---@return string
	local function pathLine(a, path, info)
		local parts = {}
		for _, point in ipairs(util.keys(info.speeds)) do
			parts[#parts + 1] = format("[%d] = %d", point, info.speeds[point])
		end
		local total = #a.data.pathPoints[path]
		local notes = { format("flight %d", a.index) }
		if info.first > 1 or info.last < total then
			notes[#notes + 1] = format("only points %d to %d of %d were flown", info.first, info.last, total)
		end
		if #info.unsure > 0 then
			local unsure = {}
			for i, point in ipairs(info.unsure) do
				unsure[i] = tostring(point)
			end
			notes[#notes + 1] = "not sure about point " .. table.concat(unsure, ", ")
		end
		if a.incomplete then
			notes[#notes + 1] = "incomplete"
		end
		return format("\t[%d] = { %s }, -- %s (%s)", path, table.concat(parts, ", "), a.data.pathName(path) or "?", table.concat(notes, ", "))
	end

	return function(analyses)
		print("\nthe speed each path was flown at from each of its points (only the points where the speed changed), as lines for the PATH_SPEEDS table of the sim file")
		print("paths flown at one speed are left out, and a path flown on several flights is shown for each of them so they can be compared\n")
		local lines, same = {}, 0
		for _, a in ipairs(analyses) do
			if #a.track >= 2 then
				local paths = a:observe()
				for _, path in ipairs(util.keys(paths)) do
					local info = paths[path]
					if countSpeeds(info) < 2 then
						same = same + 1
					else
						lines[#lines + 1] = { path = path, index = a.index, text = pathLine(a, path, info) }
					end
				end
			end
		end
		table.sort(lines, function(a, b)
			if a.path ~= b.path then
				return a.path < b.path
			end
			return a.index < b.index
		end)
		for _, line in ipairs(lines) do
			print(line.text)
		end
		printf("\n%d paths were flown at one speed\n", same)
	end
end
