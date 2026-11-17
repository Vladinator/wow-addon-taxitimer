--[[

Reads the csv files the taxi data comes from. `taxiparser.lua` makes the db files from them, and `analyze.lua` takes the names of the taxi nodes from them.

Runs in Lua 5.1 and later.

--]]

---A csv file.
---@class CsvTable
---@field headers string[] The names of the columns.
---@field rows string[][] The fields of each row, without the headers.
---@field columns table<string, number> The index of each column by its name.

---@class Csv
local csv = {}

-- the names each csv file can have, as the dumps of the games are not all named the same
local FILE_NAMES = {
	taxinodes = { "taxinodes.csv", "TaxiNodes.csv" },
	taxipath = { "taxipath.csv", "TaxiPath.csv" },
	taxipathnode = { "taxipathnode.csv", "TaxiPathNode.csv" },
}

local concat = table.concat

---A number from a field, 0 if it is not one, and whole.
---@param value string?
---@return number
function csv.toInt(value)
	local number = tonumber(value) or 0
	return number >= 0 and math.floor(number) or math.ceil(number)
end

---Splits a line of a csv file into its fields, fields can be in quotes with quotes in them doubled.
---@param line string
---@return string[]
function csv.splitLine(line)
	local fields, count = {}, 0
	if not line:find('"', 1, true) then
		for field in (line .. ","):gmatch("([^,]*),") do
			count = count + 1
			fields[count] = field
		end
		return fields
	end
	local field, inQuotes, i = {}, false, 1
	while i <= #line do
		local c = line:sub(i, i)
		if inQuotes then
			if c == '"' then
				if line:sub(i + 1, i + 1) == '"' then
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
			count = count + 1
			fields[count] = concat(field)
			field = {}
		else
			field[#field + 1] = c
		end
		i = i + 1
	end
	fields[count + 1] = concat(field)
	return fields
end

---Reads the rows of a csv file. Empty lines are left out, and a field in quotes can go over more lines.
---@param text string
---@return string[][]
function csv.parse(text)
	local rows = {} ---@type string[][]
	local pending ---@type string? The lines of a field in quotes that has not ended yet.
	for rawLine in (text .. "\n"):gmatch("([^\n]*)\n") do
		local line = rawLine:gsub("\r$", "")
		if pending then
			line = pending .. "\n" .. line
		end
		local _, quotes = line:gsub('"', "")
		if quotes % 2 == 1 then
			pending = line
		else
			pending = nil
			if line ~= "" then
				rows[#rows + 1] = csv.splitLine(line)
			end
		end
	end
	return rows
end

---Reads the csv file of a table of the taxi data, the first of the names it can have that exists in the folder.
---@param dir string
---@param name "taxinodes"|"taxipath"|"taxipathnode"
---@return CsvTable?
function csv.read(dir, name)
	for _, fileName in ipairs(FILE_NAMES[name]) do
		local file = io.open(dir .. "/" .. fileName, "rb")
		if file then
			local text = file:read("*a")
			file:close()
			local rows = csv.parse(text)
			local headers = table.remove(rows, 1)
			if headers then
				local columns = {} ---@type table<string, number>
				for i, header in ipairs(headers) do
					columns[header] = i
				end
				return { headers = headers, rows = rows, columns = columns }
			end
		end
	end
end

---Checks if the folder has the csv file of a table of the taxi data.
---@param dir string
---@param name "taxinodes"|"taxipath"|"taxipathnode"
---@return boolean
function csv.exists(dir, name)
	for _, fileName in ipairs(FILE_NAMES[name]) do
		local file = io.open(dir .. "/" .. fileName, "rb")
		if file then
			file:close()
			return true
		end
	end
	return false
end

return csv
