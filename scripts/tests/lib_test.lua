-- Runs the library of the addon with the taxi data of a game, to see where the flights reach the taxi nodes and where they land at them.
local ROOT = (TAXITIMER_ROOT or ".") .. "/"

local failures = 0
local function check(ok, what)
  if not ok then failures = failures + 1 print("FAILED: " .. what) end
end

local shim = dofile(ROOT .. "scripts/src/shared/shim.lua")
local lib = assert(shim.library(ROOT, "forever"))

local function checkpointsOf(route)
  local nodes = {}
  for i, id in ipairs(route) do nodes[i] = { nodeID = id } end
  local info = lib.GetFlightInfoFromGeometry(lib.GetFlightGeometry(nodes), 1463)
  return assert(info), lib.GetFlightCheckpoints(info)
end

-- Stormwind to Thelsamar past Ironforge: the flight cuts the corner, so landing at Ironforge is later than where the bar shows it
do
  local info, checkpoints = checkpointsOf({ 2, 6, 8 })
  check(#checkpoints == 3, "there is a checkpoint for each taxi node")
  check(checkpoints[2].landTime > checkpoints[2].time + 5, "landing at a taxi node the flight cuts the corner at is later than where the bar shows it")
  check(checkpoints[2].landDistance > checkpoints[2].distance, "and further")
  check(checkpoints[1].landTime == 0 and checkpoints[3].landTime == checkpoints[3].time, "the first and the last are where they are")
  check(math.abs(checkpoints[3].time - info.duration) < 0.01, "the last is at the end of the flight")
end

-- a flight that does not cut the corner lands where the bar shows it
do
  local _, checkpoints = checkpointsOf({ 2, 12, 11 })
  check(#checkpoints == 3 and checkpoints[2].landTime >= checkpoints[2].time, "landing is never before the taxi node on the bar")
end

-- a stop that was seen to still land after the point the bar shows the taxi node at moves the taxi node later, never past landing there, and the flight takes as long
do
  local sim = lib.Sim
  local before = checkpointsOf({ 74, 6, 7 })
  local keep = sim.NODE_STOP_OFFSETS
  sim.NODE_STOP_OFFSETS = { [6] = { [74] = { [7] = 9 } } }
  local info, checkpoints = checkpointsOf({ 74, 6, 7 })
  local _, plain = (function()
    sim.NODE_STOP_OFFSETS = {}
    return checkpointsOf({ 74, 6, 7 })
  end)()
  check(math.abs(checkpoints[2].time - (plain[2].time + 9)) < 0.01 and checkpoints[2].offset == 9, "the taxi node is shown the seconds later")
  check(math.abs(checkpoints[2].landTime - plain[2].landTime) < 0.01, "landing there is when it was")
  check(math.abs(info.duration - before.duration) < 0.01, "the flight takes as long")
  sim.NODE_STOP_OFFSETS = { [6] = { [74] = { [7] = 1000 } } }
  local _, capped = checkpointsOf({ 74, 6, 7 })
  check(capped[2].time <= capped[2].landTime + 0.01, "it is never shown after landing there")
  sim.NODE_STOP_OFFSETS = keep
end

print(failures == 0 and "all good" or (failures .. " checks failed"))
return failures
