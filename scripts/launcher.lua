--[[

Generates the db file of each game from the csv files in the `csv_<game>` folders, and svg files of each of its maps for visualization.

	lua scripts/launcher.lua [options] [game ...]

The games are mainline, forever, classic and vanilla, and are all of them if none are given.

Options:

	--no-svg        only generate the db files
	--out=FOLDER    write the files in this folder instead of the library folder (the db files) and the scripts folder (the svg folders)

Runs in Lua 5.1 and later.

--]]

local scriptPath = arg and arg[0] or "scripts/launcher.lua"
local scriptDir = scriptPath:match("^(.*)[/\\][^/\\]*$") or "."
local addonDir = scriptDir:match("^(.*)[/\\][^/\\]*$") or (scriptDir == "." and ".." or ".")
local libDir = addonDir .. "/libs/TaxiTimerLib" -- the library has the db files

-- the version of the library the db files are for, so they are only used with it
local libMinor ---@type number?
do
	local file = io.open(libDir .. "/TaxiTimerLib.lua", "rb")
	local text = file and file:read("*a") or ""
	if file then
		file:close()
	end
	libMinor = tonumber(text:match('local MAJOR, MINOR = "[^"]+", (%d+)'))
	if not libMinor then
		io.stderr:write("could not read the MINOR of the library in ", libDir, "/TaxiTimerLib.lua, the db files are written for 1\n")
	end
end

local taxiparser = dofile(scriptDir .. "/taxiparser.lua") ---@type TaxiParserModule

local clients = {} ---@type string[] The games to generate the files for.
local svg = true
local outDir ---@type string?
for _, option in ipairs(arg or {}) do
	if option == "--no-svg" then
		svg = false
	elseif option:match("^--out=.+$") then
		outDir = option:match("^--out=(.+)$")
	elseif option:sub(1, 2) ~= "--" then
		clients[#clients + 1] = option
	else
		io.stderr:write("unknown option ", option, "\n")
		os.exit(1)
	end
end
if #clients == 0 then
	clients = { "mainline", "forever", "classic", "vanilla" }
end

---Makes sure a folder exists, lua can't make one so the system is asked.
---@param path string
local function ensureDir(path)
	local probe = path .. "/.probe"
	local file = io.open(probe, "wb")
	if file then
		file:close()
		os.remove(probe)
		return
	end
	if package.config:sub(1, 1) == "\\" then
		os.execute('mkdir "' .. (path:gsub("/", "\\")) .. '" >nul 2>nul')
	else
		os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
	end
end

for _, client in ipairs(clients) do
	local csvPath = scriptDir .. "/csv_" .. client
	local svgPath = (outDir or scriptDir) .. "/svg_" .. client
	local dbPath = (outDir or libDir) .. "/db_" .. client .. ".lua"

	-- skip if the csv files of the game don't exist
	if taxiparser.exists(csvPath) then
		if outDir then
			ensureDir(outDir)
		end
		local parser = taxiparser.new(client, csvPath)
		parser:read()
		parser:write(dbPath, libMinor)

		if svg then
			ensureDir(svgPath)
			for _, map in ipairs(parser:getMaps()) do
				parser:writeSvg(svgPath .. "/db_" .. map .. ".svg", map)
			end
		end
	end
end
