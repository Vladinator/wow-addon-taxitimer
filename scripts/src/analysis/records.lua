-- The recorded flights to analyze: the ones of the saved variables, kept in the archive, and what the archive already has.

---@param ctx AnalysisContext
---@return fun(opts: AnalysisOptions): FlightRecord[], string
return function(ctx)
	local shim = ctx.shim
	local util = ctx.util
	local archive = dofile(ctx.dir .. "/src/analysis/archive.lua")(ctx) ---@type FlightArchive
	local printf, warn = util.printf, util.warn
	local format = string.format

	-- the saved variables files to take the flights from: the one that was given, and the one of every game in the World of Warcraft folder
	---@param opts AnalysisOptions
	---@return string[] files
	---@return table<string, string> labels What to call a file when the flights of it are counted.
	local function findFiles(opts)
		local files = {} ---@type string[]
		local labels = {} ---@type table<string, string>
		if opts.file then
			files[#files + 1] = opts.file
			labels[opts.file] = opts.file
		end
		if opts.wowDir then
			local folder = opts.wowDir:gsub("[/\\]+$", "")
			local numFound = 0
			for _, game in ipairs(shim.listdir(folder)) do
				if game:match("^_.+_$") then -- like `_retail_` and `_classic_`
					local accounts = folder .. "/" .. game .. "/WTF/Account"
					for _, account in ipairs(shim.listdir(accounts)) do
						local path = accounts .. "/" .. account .. "/SavedVariables/TaxiTimer.lua"
						if shim.readfile(path) then
							numFound = numFound + 1
							files[#files + 1] = path
							labels[path] = game .. " " .. account
						end
					end
				end
			end
			if numFound == 0 then
				warn("no TaxiTimer.lua was found in the SavedVariables of the games in %s (looked for _game_/WTF/Account/<account>/SavedVariables/TaxiTimer.lua)", folder)
			end
		end
		return files, labels
	end

	return function(opts)
		local files, labels = findFiles(opts)
		local archivePath = opts.archivePath
		local records = {} ---@type FlightRecord[]
		local numAdded, numLoose = 0, 0
		for _, path in ipairs(files) do
			local globals, err = shim.savedvariables(path)
			if not globals then
				warn("unable to read %s: %s", path, tostring(err))
				if path == opts.file then
					os.exit(1)
				end
			else
				local db = globals.TaxiTimerDB ---@type { flights?: FlightRecord[] }?
				local flights = type(db) == "table" and type(db.flights) == "table" and db.flights or {}
				if archivePath then
					-- the flights are kept in a file of the repo, so they are still there when the saved variables are emptied
					local added, loose
					records, added, loose = archive.merge(archivePath, flights)
					numAdded, numLoose = numAdded + added, numLoose + loose
					printf("%s: %d flight%s, %d new\n", labels[path], #flights, #flights == 1 and "" or "s", added)
				else
					for _, flight in ipairs(flights) do
						records[#records + 1] = flight
					end
					printf("%s: %d flight%s\n", labels[path], #flights, #flights == 1 and "" or "s")
				end
			end
		end
		local source = #files == 1 and files[1] or (#files > 1 and format("%d saved variables files", #files)) or archivePath or "?"
		if archivePath then
			if #files == 0 then
				records = archive.merge(archivePath, {})
			else
				printf("%d new flight%s added to %s, which has %d now%s\n", numAdded, numAdded == 1 and "" or "s", archivePath, #records - numLoose, numLoose > 0 and format(" (%d flights do not say when they were flown and are not kept)", numLoose) or "")
				source = source .. " and " .. archivePath
			end
		end
		if #records == 0 then
			warn("no flights in %s, turn recording on with /taxitimer record in the game and fly somewhere", source)
			os.exit(1)
		end
		return records, source
	end
end
