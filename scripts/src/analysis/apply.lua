-- Writes the changes the analysis suggests into the sim file of a game.
-- The suggestions are the lines that are shown (`add to NAME:    [key] = value, -- comment`), so what is written is what was shown.

---A suggestion as it is written to the sim file.
---@class AppliedChange
---@field action "add"|"change"|"remove"
---@field name string The table of the sim file.
---@field key number
---@field entry? string The line for the table, without the comment.
---@field comment? string
---@field text string The suggestion as it was shown.

---Writes the suggestions into a sim file, and returns how many were written and the ones that were not.
---@alias ApplyChanges fun(simFile: string, suggestions: string[], data: TaxiData, includeThin?: boolean): number, string[]

---@param ctx AnalysisContext
---@return ApplyChanges
return function(ctx)
	local shim, util = ctx.shim, ctx.util
	local format = string.format

	-- the suggestions that need more flights before they are written, by what the line after them or their comment says
	local UNSURE = { "not sure about point", "not sure about this one" }

	-- the ones that go by one flight, which are only written when asked for
	local THIN = { "based on one flight", "only one flight starts at this taxi node" }

	-- how a suggestion begins: the action and the word that comes after it
	local ACTIONS = { { "add", "to" }, { "change", "in" }, { "remove", "from" } }

	-- if a line is the beginning of a suggestion
	---@param line string
	---@return boolean
	local function startsSuggestion(line)
		for _, words in ipairs(ACTIONS) do
			if line:match("^%s*" .. words[1] .. " " .. words[2] .. " ") then
				return true
			end
		end
		return false
	end

	---@param text string
	---@return string
	local function trim(text)
		return (text:gsub("^%s+", ""):gsub("%s+$", ""))
	end

	-- splits the line of a suggestion into the entry and its comment, what the comment says about the flights (in brackets at its end) is left out
	---@param line string
	---@return string entry
	---@return string? comment
	local function splitComment(line)
		local entry, comment = line:match("^(.-)%s*%-%-%s*(.*)$")
		if not entry then
			return trim(line), nil
		end
		comment = trim(comment:gsub("%s*%b()$", ""))
		return trim(entry), comment ~= "" and comment or nil
	end

	---@param suggestions string[]
	---@param includeThin boolean
	---@return AppliedChange[] changes
	---@return string[] held The suggestions that are not written.
	local function parse(suggestions, includeThin)
		local changes, held = {}, {} ---@type AppliedChange[], string[]
		for i, line in ipairs(suggestions) do
			local text = trim(line)
			local action, name, rest
			for _, words in ipairs(ACTIONS) do
				action, name, rest = text:match("^(" .. words[1] .. ") " .. words[2] .. " ([A-Z_]+):%s+(%[.+)$")
				if action then
					break
				end
			end
			if action then
				local unsure = false
				-- the line after it can say it is not sure, unless it is the next suggestion (what that one says is about that one)
				local after = suggestions[i + 1] or ""
				if startsSuggestion(after) then
					after = ""
				end
				for _, words in ipairs(UNSURE) do
					if text:find(words, 1, true) or after:find(words, 1, true) then
						unsure = true
					end
				end
				for _, words in ipairs(THIN) do
					if not includeThin and (text:find(words, 1, true) or after:find(words, 1, true)) then
						unsure = true
					end
				end
				local entry, comment = splitComment(rest)
				local key = tonumber(entry:match("^%[(%d+)%]"))
				if unsure or not key then
					held[#held + 1] = text
				else
					changes[#changes + 1] = { action = action, name = name, key = key, entry = action ~= "remove" and entry or nil, comment = comment, text = text }
				end
			end
		end
		return changes, held
	end

	-- the lines of the table `sim.NAME = { ... }` in the sim file, as the index of its first and its last line
	---@param lines string[]
	---@param name string
	---@return number? first
	---@return number? last
	local function findTable(lines, name)
		for i, line in ipairs(lines) do
			if line:match("^sim%." .. name .. " = {%s*$") then
				for j = i + 1, #lines do
					if lines[j]:match("^}") then
						return i, j
					end
				end
			elseif line:match("^sim%." .. name .. " = {}%s*$") then
				-- an empty table on one line is opened up
				lines[i] = "sim." .. name .. " = {"
				table.insert(lines, i + 1, "}")
				return i, i + 1
			end
		end
	end

	-- a table with one line for each key
	---@param lines string[]
	---@param change AppliedChange
	---@return boolean applied
	local function applyLine(lines, change)
		local first, last = findTable(lines, change.name)
		if not first or not last then
			return false
		end
		local at, before ---@type number?, number?
		for i = first + 1, last - 1 do
			local key = tonumber(lines[i]:match("^\t%[(%d+)%] = "))
			if key == change.key then
				at = i
			elseif key and key > change.key and not before then
				before = i
			end
		end
		if change.action == "remove" then
			if at then
				table.remove(lines, at)
			end
			return at ~= nil
		end
		local entry = (change.entry or ""):gsub("{%s+}", "{}")
		if not entry:match(",$") then
			entry = entry .. ","
		end
		local comment = change.comment
		if at and not comment then
			comment = lines[at]:match("%-%-%s*(.*)$") -- what the line it replaces said
		end
		local line = "\t" .. entry .. (comment and (" -- " .. comment) or "")
		if at then
			lines[at] = line
		else
			table.insert(lines, before or last, line)
		end
		return true
	end

	-- `NODE_JOINS` has a table in a table for each taxi node, so all of it is written again with the changes
	---@param lines string[]
	---@param changes AppliedChange[]
	---@param data TaxiData
	---@return number applied
	local function applyJoins(lines, changes, data)
		local first, last = findTable(lines, "NODE_JOINS")
		if not first or not last then
			return 0
		end
		local joins = {} ---@type table<number, table<number, table<number, number[]>>>
		for node, fromNodes in pairs(data.lib.Sim.NODE_JOINS) do
			joins[node] = {}
			for from, toNodes in pairs(fromNodes) do
				joins[node][from] = {}
				for to, join in pairs(toNodes) do
					joins[node][from][to] = join
				end
			end
		end
		local applied = 0
		for _, change in ipairs(changes) do
			local node, from, to = change.text:match("%[(%d+)%] = { %[(%d+)%] = { %[(%d+)%] = ")
			local flownLast, flownFirst = change.text:match("= { (%d+), (%d+) } } }")
			node, from, to = tonumber(node), tonumber(from), tonumber(to)
			if node and from and to and (change.action == "remove" or flownLast) then
				joins[node] = joins[node] or {}
				joins[node][from] = joins[node][from] or {}
				joins[node][from][to] = change.action ~= "remove" and { tonumber(flownLast), tonumber(flownFirst) } or nil
				applied = applied + 1
			end
		end
		local block = {} ---@type string[]
		for _, node in ipairs(util.keys(joins)) do
			local entries = {} ---@type string[]
			for _, from in ipairs(util.keys(joins[node])) do
				-- all of the joins from a taxi node are in one entry, a key that is written twice would only keep the last
				local targets, names = {}, {} ---@type string[], string[]
				for _, to in ipairs(util.keys(joins[node][from])) do
					local join = joins[node][from][to]
					targets[#targets + 1] = format("[%d] = { %d, %d }", to, join[1], join[2])
					names[#names + 1] = data.nodeName(to)
				end
				entries[#entries + 1] = format("\t\t[%d] = { %s }, -- %s > %s", from, table.concat(targets, ", "), data.nodeName(from), table.concat(names, "; "))
			end
			if #entries > 0 then
				block[#block + 1] = format("\t[%d] = { -- %s", node, data.nodeName(node))
				for _, entry in ipairs(entries) do
					block[#block + 1] = entry
				end
				block[#block + 1] = "\t},"
			end
		end
		for _ = first + 1, last - 1 do
			table.remove(lines, first + 1)
		end
		for i, line in ipairs(block) do
			table.insert(lines, first + i, line)
		end
		return applied
	end

	-- Writes the suggestions into the sim file.
	---@param simFile string
	---@param suggestions string[] The suggestions as they were shown.
	---@param data TaxiData The taxi data of the game the sim file is for.
	---@param includeThin? boolean Also write the suggestions that go by one flight.
	---@return number applied How many changes were written.
	---@return string[] held The suggestions that were not written, as they need more flights or a look.
	return function(simFile, suggestions, data, includeThin)
		local changes, held = parse(suggestions, includeThin or false)
		if #changes == 0 then
			return 0, held
		end
		local text = shim.readfile(simFile)
		if not text then
			util.warn("unable to read %s", simFile)
			return 0, held
		end
		local newline = text:find("\r\n", 1, true) and "\r\n" or "\n"
		local lines = {} ---@type string[]
		for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1] = line
		end
		if lines[#lines] == "" then
			lines[#lines] = nil
		end

		local applied = 0
		local joins = {} ---@type AppliedChange[]
		for _, change in ipairs(changes) do
			if change.name == "NODE_JOINS" then
				joins[#joins + 1] = change
			elseif applyLine(lines, change) then
				applied = applied + 1
			else
				held[#held + 1] = change.text
			end
		end
		if #joins > 0 then
			local count = applyJoins(lines, joins, data)
			applied = applied + count
			if count < #joins then
				held[#held + 1] = format("%d of the changes to NODE_JOINS", #joins - count)
			end
		end
		if applied > 0 then
			local file = io.open(simFile, "wb")
			if not file then
				util.warn("unable to write %s", simFile)
				return 0, held
			end
			file:write(table.concat(lines, newline), newline)
			file:close()
		end
		return applied, held
	end
end
