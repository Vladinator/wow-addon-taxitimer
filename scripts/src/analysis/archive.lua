-- Keeps every flight that was ever recorded in a file of the repo, so the saved variables of the game can be emptied without losing what the sim files were made from.
-- The file has the same shape as the saved variables (`TaxiTimerDB = { flights = { ... } }`), written with a flight sample on each line so it stays small and changes show up well in git.

---@class FlightArchive
---@field merge fun(path: string, records: FlightRecord[]): FlightRecord[], number, number Adds the flights that are new to the file at `path` and returns all of its flights from old to new, how many were added and how many could not be kept.

---@param ctx AnalysisContext
---@return FlightArchive
return function(ctx)
	local shim, util = ctx.shim, ctx.util
	local format, concat = string.format, table.concat

	-- what tells a flight from every other: when it was picked, where it went and how long it took
	---@param record FlightRecord
	---@return string? key Nothing for a record that can not be told apart (it does not say when it was flown).
	local function flightKey(record)
		if type(record) ~= "table" or type(record.time) ~= "number" or type(record.route) ~= "table" then
			return nil
		end
		local route = {} ---@type string[]
		for i, node in ipairs(record.route) do
			route[i] = tostring(node)
		end
		return format("%d %s %s %.2f", record.time, tostring(record.flavor or record.project or ""), concat(route, ">"), tonumber(record.landed) or 0)
	end

	--
	-- MARK: Writing
	--

	---@param value number
	---@return string
	local function number(value)
		if value ~= value then
			return "nan"
		elseif value == util.INF then
			return "inf"
		elseif value == -util.INF then
			return "-inf"
		end
		return format("%.14g", value) -- the same text in every version of Lua
	end

	---@param value any
	---@return boolean
	local function isList(value)
		if type(value) ~= "table" then
			return false
		end
		local count = 0
		for _ in pairs(value) do
			count = count + 1
		end
		return count == #value
	end

	-- a list of numbers, strings and booleans fits on one line
	---@param list any[]
	---@return boolean
	local function isPlain(list)
		for _, item in ipairs(list) do
			if type(item) == "table" then
				return false
			end
		end
		return true
	end

	---@param out string[]
	---@param value any
	---@param indent string
	local function write(out, value, indent)
		local kind = type(value)
		if kind == "number" then
			out[#out + 1] = number(value)
		elseif kind == "string" then
			out[#out + 1] = format("%q", value)
		elseif kind == "boolean" then
			out[#out + 1] = tostring(value)
		elseif kind ~= "table" then
			out[#out + 1] = "nil"
		elseif isList(value) and isPlain(value) then
			local items = {} ---@type string[]
			for i, item in ipairs(value) do
				local text = {} ---@type string[]
				write(text, item, "")
				items[i] = text[1]
			end
			out[#out + 1] = "{" .. concat(items, ",") .. "}"
		elseif isList(value) then
			out[#out + 1] = "{\n"
			for _, item in ipairs(value) do
				out[#out + 1] = indent .. "\t"
				write(out, item, indent .. "\t")
				out[#out + 1] = ",\n"
			end
			out[#out + 1] = indent .. "}"
		else
			-- the keys in the same order every time
			local keys = {} ---@type any[]
			for key in pairs(value) do
				keys[#keys + 1] = key
			end
			table.sort(keys, function(a, b)
				if type(a) == type(b) then
					return a < b
				end
				return type(a) < type(b)
			end)
			out[#out + 1] = "{\n"
			for _, key in ipairs(keys) do
				out[#out + 1] = indent .. "\t[" .. (type(key) == "number" and number(key) or format("%q", tostring(key))) .. "] = "
				write(out, value[key], indent .. "\t")
				out[#out + 1] = ",\n"
			end
			out[#out + 1] = indent .. "}"
		end
	end

	---@param path string
	---@param records FlightRecord[]
	---@return boolean written
	local function save(path, records)
		local out = { "-- Every flight that was recorded, from old to new. Written by scripts/analyze.lua, which adds the flights of the saved variables it is given that are not in here yet.\n\nTaxiTimerDB = {\n\t[\"flights\"] = " }
		write(out, records, "\t")
		out[#out + 1] = ",\n}\n"
		local file = io.open(path, "wb")
		if not file then
			return false
		end
		file:write(concat(out))
		file:close()
		return true
	end

	--
	-- MARK: Merging
	--

	---@param path string
	---@param records FlightRecord[] The flights of the saved variables.
	---@return FlightRecord[] all The flights of the file with the new ones, from old to new, and after them the ones that could not be kept.
	---@return number added
	---@return number loose The flights that are not kept as they do not say when they were flown.
	local function merge(path, records)
		local all, seen = {}, {} ---@type FlightRecord[], table<string, boolean>
		if shim.readfile(path) then
			local globals, err = shim.savedvariables(path)
			local db = globals and globals.TaxiTimerDB ---@type { flights?: FlightRecord[] }?
			if type(db) ~= "table" or type(db.flights) ~= "table" then
				util.warn("unable to read the flights of %s%s, it is left as it is", path, err and (": " .. tostring(err)) or "")
				return records, 0, 0
			end
			for _, record in ipairs(db.flights) do
				local key = flightKey(record)
				if key and not seen[key] then
					seen[key] = true
					all[#all + 1] = record
				end
			end
		end

		local added, loose = 0, {} ---@type number, FlightRecord[]
		for _, record in ipairs(records) do
			local key = flightKey(record)
			if not key then
				loose[#loose + 1] = record
			elseif not seen[key] then
				seen[key] = true
				all[#all + 1] = record
				added = added + 1
			end
		end

		-- from old to new, the flights of the same second stay in the order they were in
		local order = {} ---@type table<FlightRecord, number>
		for i, record in ipairs(all) do
			order[record] = i
		end
		table.sort(all, function(a, b)
			if a.time ~= b.time then
				return a.time < b.time
			end
			return order[a] < order[b]
		end)

		if added > 0 and not save(path, all) then
			util.warn("unable to write %s", path)
		end
		for _, record in ipairs(loose) do
			all[#all + 1] = record
		end
		return all, added, #loose
	end

	return { merge = merge }
end
