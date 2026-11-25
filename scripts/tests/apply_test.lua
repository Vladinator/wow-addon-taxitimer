-- Runs the code that writes the changes the analysis suggests into a sim file, on a copy of a small sim file, to see what is written and that the sim file still loads.
local ROOT = (TAXITIMER_ROOT or ".") .. "/"

local failures = 0
local function check(ok, what)
  if not ok then failures = failures + 1 print("FAILED: " .. what) end
end

local shim = dofile(ROOT .. "scripts/src/shared/shim.lua")
local util = dofile(ROOT .. "scripts/src/shared/util.lua")
local ctx = { shim = shim, util = util, dir = ROOT .. "scripts", dataDir = ROOT .. "scripts/data", root = ROOT }
local apply = dofile(ROOT .. "scripts/src/analysis/apply.lua")(ctx)

local function names(id)
  return "node" .. id
end

-- a sim file with the tables the changes go into
local function write(path, stops)
  local f = assert(io.open(path, "wb"))
  f:write("local sim = {}\n\nsim.NODE_JOINS = {\n}\n\nsim.NODE_STOPS = {\n" .. (stops or "") .. "}\n\nreturn sim\n")
  f:close()
end

local function data(joins, stops)
  return { lib = { Sim = { NODE_JOINS = joins or {}, NODE_STOPS = stops or {} } }, nodeName = names }
end

local path = os.tmpname()

-- a stop for one way of going on from a taxi node
do
  write(path)
  local count = apply(path, { "add to NODE_STOPS:    [2084] = { [2060] = { [2102] = 10 } }, -- Norwington (2 flights)" }, data())
  check(count == 1, "one stop is written")
  local sim = dofile(path)
  check(sim.NODE_STOPS[2084] and sim.NODE_STOPS[2084][2060] and sim.NODE_STOPS[2084][2060][2102] == 10, "it is for the way it was suggested for")
end

-- a stop for every taxi node it goes on to, which keeps the ones that were there for other taxi nodes
do
  write(path, "\t[2084] = { [5] = { [6] = 3 } },\n")
  local current = { [2084] = { [5] = { [6] = 3 } } }
  local count = apply(path, { "add to NODE_STOPS:    [2084] = { [2060] = 10 }, -- Norwington, flying from Hatherford to any taxi node (2 of the ways of going on agree)" }, data(nil, current))
  check(count == 1, "a stop for every taxi node is written")
  local sim = dofile(path)
  check(sim.NODE_STOPS[2084][2060] == 10, "it is a number for the taxi node it arrives from")
  check(type(sim.NODE_STOPS[2084][5]) == "table" and sim.NODE_STOPS[2084][5][6] == 3, "the stop that was there stays")
end

-- the same again does not change what is written
do
  local before = io.open(path, "rb"):read("a")
  apply(path, { "add to NODE_STOPS:    [2084] = { [2060] = 10 }, -- again" }, data(nil, { [2084] = { [5] = { [6] = 3 }, [2060] = 10 } }))
  local after = io.open(path, "rb"):read("a")
  check(before == after, "writing the same stop again leaves the file as it was")
end

os.remove(path)
print(failures == 0 and "all good" or (failures .. " checks failed"))
return failures
