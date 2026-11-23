-- The flights the GPS follows: one that is asked for warms up until the player is on the taxi, goes on while the player is, and ends when the player is off it. The GPS runs from the core.lua of the addon with a stand-in for the game.
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

local function rig()
  local r = { now = 1000, onTaxi = false, tickers = {}, entries = {}, log = {}, record = true, debug = false, pos = { 1, 2, 3, 4 } }
  local env = {
    max = math.max, min = math.min, abs = math.abs, floor = math.floor, sqrt = math.sqrt, format = string.format,
    setmetatable = setmetatable, getmetatable = getmetatable, table = table, ipairs = ipairs, pairs = pairs, select = select, tostring = tostring, tonumber = tonumber, unpack = table.unpack,
    Round = function(v, d) local m = 10 ^ d return math.floor(v * m + 0.5) / m end,
    addonName = "TaxiTimer", WOW_PROJECT_ID = 1,
    issecretvalue = function(value) return type(value) == "table" and value.secret == true end,
    print = function(...) r.log[#r.log + 1] = table.concat({ ... }, " ") end,
    GetTime = function() return r.now end,
    GetServerTime = function() return 5000 + r.now end,
    GetBuildInfo = function() return "1.0", "12345" end,
    C_AddOns = { GetAddOnMetadata = function() return "1.2.3" end },
    C_Map = { GetBestMapForUnit = function() return 77 end },
    UnitFactionGroup = function() return "Horde" end,
    UnitPosition = function() return table.unpack(r.pos) end,
    UnitOnTaxi = function() return r.onTaxi end,
    GetUnitSpeed = function() return 0 end,
    PlaySound = function() end, FlashClientIcon = function() end,
    hooksecurefunc = function() end,
    C_Timer = { NewTicker = function(_, fn)
      local t = { fn = fn }
      function t:Cancel() self.cancelled = true end
      r.tickers[#r.tickers + 1] = t
      return t
    end },
    SV = {
      GetOption = function(_, key) if key == "record" then return r.record end return r.debug end,
      AddGossipFlight = function(_, entry, max) r.entries[#r.entries + 1] = entry r.max = max end,
    },
    TTL = { Speed = function() return 30 end, GetFlightTimeLeft = function(_, d) return d / 30 end },
    Visualization = { Start = function(_, info) r.log[#r.log + 1] = "V.Start " .. tostring(info and info.id) end, Takeoff = function() end, SetProgress = function() end, RequestStop = function() end },
    Recorder = { Start = function(_, _, info) r.log[#r.log + 1] = "R.Start " .. tostring(info and info.id) end, Tick = function() end, Idle = function() end, Stop = function() r.log[#r.log + 1] = "R.Stop" end, RequestStop = function() end },
    Timer = { Start = function() end, Stop = function() end, Get = function() return 0 end },
  }
  local text = read(ROOT .. "core.lua")
  local from = text:find("---@class GossipDiscovery", 1, true)
  local to = text:find("---@class State", from, true)
  local chunk = assert(load(text:sub(from, to - 1) .. "\nreturn GPS", "gps", "t", env))
  r.GPS = chunk()
  -- the clock goes on in steps of half a second, and the tickers that are alive run
  function r.advance(seconds)
    for _ = 1, seconds * 2 do
      r.now = r.now + 0.5
      for _, t in ipairs(r.tickers) do if not t.cancelled then t.fn() end end
    end
  end
  function r.alive()
    local n = 0
    for _, t in ipairs(r.tickers) do if not t.cancelled then n = n + 1 end end
    return n
  end
  return r
end


local function count(log, prefix)
  local n = 0
  for _, line in ipairs(log) do
    if line:sub(1, #prefix) == prefix then n = n + 1 end
  end
  return n
end

local function flight(id)
  return { id = id, distance = 1000, distance2D = 1000, duration = 40, areaSpeed = 30, maps = { [1] = true }, points = { { x = 0, y = 0, map = 1 } } }
end

-- a flight that never begins leaves nothing behind
do
  local r = rig()
  r.GPS:Request(1209, flight(1))
  r.advance(25)
  check(r.alive() == 1, "it waits for the taxi while it warms up")
  r.advance(7)
  check(r.alive() == 0, "and is let go when the warm-up is over")
  check(count(r.log, "V.") == 0, "nothing is shown for a flight that did not begin")
  check(count(r.log, "R.Stop") == 1, "the recording is let go once")
end

-- it can begin when the warm-up is not over
do
  local r = rig()
  r.GPS:Request(1209, flight(1))
  r.advance(20)
  r.pos = { 10, 0, 0, 1 }
  r.onTaxi = true
  r.advance(1)
  check(count(r.log, "V.Start") == 1 and r.alive() == 1, "it begins when the player gets on the taxi, and goes on")
end

-- asking again lets go of the one that is warming up
do
  local r = rig()
  r.GPS:Request(1209, flight(1))
  r.advance(2)
  r.GPS:Request(1209, flight(2))
  r.pos = { 10, 0, 0, 1 }
  r.onTaxi = true
  r.advance(1)
  check(count(r.log, "R.Start") == 2 and count(r.log, "R.Stop") == 1 and r.alive() == 1, "the first is let go")
  check(count(r.log, "V.Start 2") == 1 and count(r.log, "V.Start 1") == 0, "only the second is shown")
end

-- asking while flying does nothing, the game refuses it
do
  local r = rig()
  r.GPS:Request(1209, flight(1))
  r.pos = { 10, 0, 0, 1 }
  r.onTaxi = true
  r.advance(2)
  local before = #r.log
  r.GPS:Request(1209, flight(2))
  check(#r.log == before, "a request while flying changes nothing")
  r.advance(1)
  check(count(r.log, "R.Start") == 1 and count(r.log, "R.Stop") == 0 and r.alive() == 1, "and the flight carries on")
end

-- asking right after landing, before the tick noticed: the old flight lands first
do
  local r = rig()
  r.GPS:Request(1209, flight(1))
  r.pos = { 10, 0, 0, 1 }
  r.onTaxi = true
  r.advance(2)
  r.onTaxi = false
  r.GPS:Request(1209, flight(2))
  check(count(r.log, "R.Stop") == 1, "the old flight lands")
  check(count(r.log, "R.Start 2") == 1 and r.alive() == 1, "and the new one warms up")
end

print(failures == 0 and "all good" or (failures .. " checks failed"))
return failures
