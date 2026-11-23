-- Runs the tests of the addon, each of them runs code of the addon with a stand-in for the game and says what failed:
--
--	lua scripts/tests/run.lua
--
-- The exit code is 1 if any of them failed. They need to be run from the Lua of the Lua language server (or any Lua 5.1 or later with `os.exit`).

local scriptPath = arg and arg[0] or "scripts/tests/run.lua"
local dir = scriptPath:match("^(.*)[/\\]") or "."
-- the folder of the addon is two folders up from here
local root = dir:gsub("[/\\]?tests$", ""):gsub("[/\\]?scripts$", "")
if dir == "." then
	root = "../.."
elseif dir == "tests" then
	root = ".."
elseif root == "" then
	root = "."
end
TAXITIMER_ROOT = root

local tests = { "gps_test.lua", "gossip_test.lua", "settings_test.lua" }
local total = 0
for _, name in ipairs(tests) do
	print("\n" .. name)
	local failures = dofile(dir .. "/" .. name)
	total = total + (tonumber(failures) or 1)
end
print(total == 0 and "\nall tests passed" or "\n" .. total .. " checks failed")
os.exit(total == 0 and 0 or 1)
