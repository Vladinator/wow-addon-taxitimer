-- Runs the code that writes what was written to the sim file of a game into the sim files of the other games, with taxi data of two small games, to see that it is only done where the paths have the same points.
local ROOT = (TAXITIMER_ROOT or ".") .. "/"

local failures = 0
local function check(ok, what)
  if not ok then failures = failures + 1 print("FAILED: " .. what) end
end

local shim = { readfile = function() return "stand-in" end }
local util = dofile(ROOT .. "scripts/src/shared/util.lua")
local ctx = { shim = shim, util = util }

-- taxi data with paths from taxi node 1 to 2 and from 2 to 3, `leaving` is where the path from 2 to 3 goes to
local function game(client, leaving, sim)
  return {
    client = client,
    paths = { [1] = { [2] = 10 }, [2] = { [3] = 11 } },
    pathPoints = { [10] = { 1, 2 }, [11] = { 3, 4 } },
    points = {
      [1] = { x = 0, y = 0, z = 0, map = 1 },
      [2] = { x = 10, y = 0, z = 0, map = 1 },
      [3] = { x = 10, y = 0, z = 0, map = 1 },
      [4] = { x = leaving, y = 5, z = 0, map = 1 },
    },
    lib = { Sim = sim or { NODE_JOINS = {}, NODE_STOPS = {} } },
    nodeName = function(id) return "node" .. id end,
  }
end

local function run(source, others, flights)
  local data = { forever = source }
  for name, other in pairs(others) do data[name] = other end
  local loaded = function(client) return data[client] end
  local written = {} ---@type table<string, string[]>
  local apply = function(file, lines)
    written[file] = lines
    return #lines
  end
  local mirror = dofile(ROOT .. "scripts/src/analysis/mirror.lua")(ctx, loaded, apply)
  local lines = { "add to NODE_JOINS:    [2] = { [1] = { [3] = { 1, 2 } } }, -- node2" }
  local count = mirror("forever", "libs/sim_forever.lua", lines, flights or {})
  return count, written
end

-- the same paths in the other game: it is written there
do
  local count, written = run(game("forever", 20), { vanilla = game("vanilla", 20) })
  check(count == 1 and written["libs/sim_vanilla.lua"] and #written["libs/sim_vanilla.lua"] == 1, "a join for paths that are the same is written to the other game")
end

-- a path with other points: it is not
do
  local count = run(game("forever", 20), { vanilla = game("vanilla", 99) })
  check(count == 0, "a join for paths with other points is not written")
end

-- the other game has the same already: nothing to write
do
  local sim = { NODE_JOINS = { [2] = { [1] = { [3] = { 1, 2 } } } }, NODE_STOPS = {} }
  local count = run(game("forever", 20), { vanilla = game("vanilla", 20, sim) })
  check(count == 0, "what the other game has the same is not written again")
end

-- the other game has another one that no flight of it flew: it is made the same
do
  local sim = { NODE_JOINS = { [2] = { [1] = { [3] = { 5, 5 } } } }, NODE_STOPS = {} }
  local count = run(game("forever", 20), { vanilla = game("vanilla", 20, sim) })
  check(count == 1, "a change is carried on to a game that no flights fly there")
end

-- flights of the other game flew there
do
  local flight = { data = { client = "vanilla" }, incomplete = nil, record = { route = { 1, 2, 3 } } }
  local count = run(game("forever", 20), { vanilla = game("vanilla", 20) }, { flight })
  check(count == 0, "a corner that flights of the other game flew is left to them")
end

print(failures == 0 and "all good" or (failures .. " checks failed"))
return failures
