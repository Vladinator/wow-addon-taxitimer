-- The command line of `analyze.lua`.

---What was asked for on the command line.
---@class AnalysisOptions
---@field file? string The saved variables file.
---@field wowDir? string The World of Warcraft folder, to look for the saved variables of every game in.
---@field wanted table<number, boolean> The flights to show the details of.
---@field all boolean
---@field speeds boolean
---@field suggest boolean
---@field joins boolean
---@field client? TaxiTimerLib-1.0_GameFlavor The game to use instead of the one the flights were recorded on.
---@field simFile? string
---@field coverage boolean
---@field keepSuperseded boolean
---@field archivePath? string The file every flight is kept in.
---@field apply boolean
---@field worstSeconds number
---@field near number
---@field far number

---@param ctx AnalysisContext
---@return fun(args: string[], scriptPath: string): AnalysisOptions
return function(ctx)
	local shim = ctx.shim
	local warn = ctx.util.warn

	---@param scriptPath string
	---@return never
	local function usage(scriptPath)
		warn("usage: lua %s [SavedVariables/TaxiTimer.lua] [--wow=FOLDER] [--flight=N] [--all] [--speeds] [--joins] [--coverage] [--apply] [--archive=FILE] [--no-archive] [--keep-old] [--worst=5] [--sim=FILE] [--no-suggest] [--client=mainline|forever|classic|vanilla] [--near=25] [--far=60]", scriptPath)
		os.exit(1)
	end

	return function(args, scriptPath)
		---@type AnalysisOptions
		local opts = {
			wanted = {},
			all = false,
			speeds = false,
			suggest = true,
			joins = false,
			coverage = false,
			keepSuperseded = false,
			archivePath = ctx.dataDir .. "/recordings.lua",
			apply = false,
			worstSeconds = 5,
			near = 25,
			far = 60,
		}

		for _, option in ipairs(args) do
			if option:match("^--flight=%d+$") then
				opts.wanted[tonumber(option:match("=(%d+)")) or 0] = true
			elseif option == "--all" then
				opts.all = true
			elseif option == "--speeds" then
				opts.speeds = true
			elseif option == "--keep-old" then
				opts.keepSuperseded = true
			elseif option == "--no-archive" then
				opts.archivePath = nil
			elseif option:match("^--archive=.+$") then
				opts.archivePath = option:match("=(.+)$")
			elseif option == "--apply" then
				opts.apply = true
			elseif option == "--coverage" then
				opts.coverage = true
			elseif option:match("^--worst=[%d.]+$") then
				opts.worstSeconds = tonumber(option:match("=([%d.]+)")) or opts.worstSeconds
			elseif option == "--joins" then
				opts.joins = true
			elseif option == "--no-suggest" then
				opts.suggest = false
			elseif option:match("^--wow=.+$") then
				opts.wowDir = option:match("^--wow=(.+)$")
			elseif option:match("^--sim=.+$") then
				opts.simFile = option:match("^--sim=(.+)$")
			elseif option:match("^--client=%w+$") then
				opts.client = option:match("=(%w+)") --[[@as TaxiTimerLib-1.0_GameFlavor]]
			elseif option:match("^--near=[%d.]+$") then
				opts.near = tonumber(option:match("=([%d.]+)")) or opts.near
			elseif option:match("^--far=[%d.]+$") then
				opts.far = tonumber(option:match("=([%d.]+)")) or opts.far
			elseif not opts.file and option:sub(1, 2) ~= "--" then
				opts.file = option
			else
				warn("unknown option %s", option)
				os.exit(1)
			end
		end

		if opts.file and not shim.readfile(opts.file) then
			usage(scriptPath)
		end
		if not opts.file and not opts.wowDir and not (opts.archivePath and shim.readfile(opts.archivePath)) then
			usage(scriptPath) -- without saved variables the flights that were kept are analyzed, if there are any
		end

		return opts
	end
end
