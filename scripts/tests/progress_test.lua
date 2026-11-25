-- Runs the progress of the flight of core.lua (where we are in the flight and what a stop that was asked for does to the bar) without the game, as it makes no game calls.
local ROOT = (TAXITIMER_ROOT or ".") .. "/"

local failures = 0
local function check(ok, what)
  if not ok then failures = failures + 1 print("FAILED: " .. what) end
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local t = f:read("a"):gsub("\r\n", "\n")
  f:close()
  return t
end

local text = read(ROOT .. "core.lua")
local a = text:find("local TAKEOFF_LAG", 1, true)
local b = text:find("-- MARK: Widgets", a, true)
local env = { min = math.min, max = math.max, setmetatable = setmetatable }
local newProgress = assert(load(text:sub(a, b - 1) .. "\nreturn progress", "progress", "t", env))

-- a flight of three taxi nodes passed and a destination, where the third is flown past so landing at it is later than the notch
local function flight()
  local progress = newProgress()
  progress:Start({ duration = 300 })
  progress.checkpoints = {
    { time = 0, landTime = 0 },
    { time = 50, landTime = 60 },
    { time = 120, landTime = 120 },
    { time = 200, landTime = 230 },
    { time = 300, landTime = 300 },
  }
  progress.startTime, progress.positioned, progress.elapsed, progress.elapsedAt = 0, true, 10, 0
  return progress
end

-- a stop lands at the taxi node when the flight lands there, not where the notch is
do
  local progress = flight()
  progress:SetStop(2)
  check(progress.stopAt == 60 and progress.stopIndex == 2, "a stop is for when the flight lands at the taxi node")
end

-- a stop that is still on its way is kept
do
  local progress = flight()
  progress:SetStop(2)
  progress.elapsed = 62
  local _, missed = progress:Advance(0)
  check(not missed and progress.stopIndex == 2, "a stop that is a few seconds late is kept")
end

-- a stop that was too late for the taxi node lands at the next one
do
  local progress = flight()
  progress:SetStop(2)
  progress.elapsed = 70
  local _, missed = progress:Advance(0)
  check(missed, "a stop that came too late is missed")
  check(progress.stopIndex == 3 and progress.stopAt == 120, "and it is for the next taxi node")
  progress.elapsed = 130
  progress:Advance(0)
  check(progress.stopIndex == 4 and progress.stopAt == 230, "and the one after that, if that is missed too")
end

-- one that was too late for the last taxi node before the destination goes on to the destination
do
  local progress = flight()
  progress:SetStop(4)
  progress.elapsed = 240
  local _, missed = progress:Advance(0)
  check(missed and progress.stopAt == nil and progress.stopIndex == nil, "the flight goes on as it was when it lands at the destination anyway")
end

print(failures == 0 and "all good" or (failures .. " checks failed"))
return failures
