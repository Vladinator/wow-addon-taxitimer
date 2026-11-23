-- The gossip flights: what the db says about the flight, and what the hooks do with a chosen option.
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

-- the db: a flight between two taxi nodes by their ids alone
do
  local shim = dofile(ROOT .. "scripts/src/shared/shim.lua")
  local lib = assert(shim.library(ROOT, "mainline"))
  local nodes = { { nodeID = 63, name = "Nighthaven, Moonglade" }, { nodeID = 22, name = "Thunder Bluff, Mulgore" } }
  local info = lib.GetFlightInfoFromNodes(nodes, 1209, 1, nil, "Alliance")
  check(info ~= nil and info.duration > 30 and info.distance > 1000, "the db has a flight from Nighthaven to Thunder Bluff")
  check(info and info.nodes[1].name == "Nighthaven, Moonglade" and info.nodes[2].nodeID == 22, "with the names that were given")
  check(lib.IsFlightPathValid(63, 22) == true, "and a path between them")
  check(lib.IsFlightPathValid(22, 99999) == false, "and none between taxi nodes that have no path")
  print(string.format("Nighthaven > Thunder Bluff: %.1f s, %.0f yd", info.duration, info.distance))
end

-- every flight in the table of gossip options has a path in the db of the game it is for
do
  local shim = dofile(ROOT .. "scripts/src/shared/shim.lua")
  local lib = assert(shim.library(ROOT, "mainline"))
  local text = read(ROOT .. "core.lua")
  local from = text:find("local GossipToFlightDB = {", 1, true)
  local to = text:find("\n\t}\n", from, true)
  local source = text:sub(from, to + 3):gsub("^local GossipToFlightDB =", "return")
  local db = assert(load(source, "table", "t", { TTL = lib }))()
  local count = 0
  for flavor, entries in pairs(db) do
    local flavorLib = assert(shim.library(ROOT, flavor))
    for id, flight in pairs(entries) do
      count = count + 1
      check(flavorLib.IsFlightPathValid(flight[2], flight[4]), string.format("%s gossip option %d has a path from taxi node %d to %d", flavor, id, flight[2], flight[4]))
    end
  end
  check(count >= 1, "there are gossip flights to check")
end

-- the names come from the taxi map of the game, which can be listed without being at it
do
  local text = read(ROOT .. "libs/TaxiTimerLib/TaxiTimerLib-GameAPI.lua")
  local from = text:find("function api.GetTaxiMapNodeByID", 1, true)
  local to = text:find("-- Returns what the flight to a slot of the taxi map", from, true)
  local seen = {}
  local listed = 0
  local api = { GetSpeedModifier = function() return 1.25 end }
  local env = {
    ipairs = ipairs, api = api,
    C_TaxiMap = { GetTaxiNodesForMap = function(areaID) listed = listed + 1 seen.area = areaID
      return { { nodeID = 62, name = "Nighthaven, Moonglade (other)" }, { nodeID = 63, name = "Nighthaven, Moonglade" }, { nodeID = 22, name = "Thunder Bluff, Mulgore" } } end },
    UnitFactionGroup = function() return "Horde" end,
    lib = { GetFlightInfoFromNodes = function(nodes, areaID, modifier, shown, faction)
      seen.nodes, seen.areaID, seen.modifier, seen.shown, seen.faction = nodes, areaID, modifier, shown, faction
      return { duration = 1 } end },
  }
  assert(load(text:sub(from, to - 1), "nodeids", "t", env))()
  local info = api.GetFlightInfoFromNodeIDs({ 63, 22 }, 1209)
  check(info ~= nil and seen.area == 1209, "the taxi map of the flight is looked in")
  local found = api.GetTaxiMapNodeByID(1209, 63)
  check(found and found.name == "Nighthaven, Moonglade" and api.GetTaxiMapNodeByID(1209, 99999) == nil, "a taxi node of a taxi map is found by its id")
  check(seen.nodes[1].nodeID == 63 and seen.nodes[1].name == "Nighthaven, Moonglade" and seen.nodes[2].nodeID == 22 and seen.nodes[2].name == "Thunder Bluff, Mulgore", "and the taxi nodes get their names from it")
  check(seen.areaID == 1209 and seen.modifier == 1.25 and seen.shown == nil and seen.faction == "Horde", "the flight is for the taxi map, the speed modifier and the faction of the player")
  api.GetFlightInfoFromNodeIDs({ 63, 99999 }, 1209)
  check(seen.nodes[1].name == "Nighthaven, Moonglade" and seen.nodes[2].nodeID == 99999 and seen.nodes[2].name == nil, "a taxi node that is not on it has no name")
  -- the last taxi node can be on another taxi map
  local maps = { [1209] = { { nodeID = 63, name = "Nighthaven, Moonglade" } }, [1550] = { { nodeID = 22, name = "Somewhere else" } } }
  env.C_TaxiMap.GetTaxiNodesForMap = function(areaID) return maps[areaID] end
  api.GetFlightInfoFromNodeIDs({ 63, 22 }, 1209, 1550)
  check(seen.nodes[1].name == "Nighthaven, Moonglade" and seen.nodes[2].name == "Somewhere else" and seen.areaID == 1209, "the last taxi node is named from the taxi map it ends on, and the speed is the one of where it starts")
  listed = 0
  env.C_TaxiMap.GetTaxiNodesForMap = function() listed = listed + 1 return {} end
  api.GetFlightInfoFromNodeIDs({ 63, 22 })
  check(listed == 0 and seen.nodes[1].name == nil and seen.areaID == nil, "without a taxi map nothing is listed and there are no names")
end

-- the hooks
local SECRET = { secret = true } -- stands in for a secret value

local function world(opts)
  opts = opts or {}
  local calls = {}
  local tip = { lines = {} }
  local hooks, handlers, events = {}, {}, {}
  local gossip = {}
  local clock = { now = 100, onTaxi = false, tickers = {}, entries = {}, discovered = {} }
  local env = {
    RegisterFrameEvent = function(frame, event) frame:RegisterEvent(event) end,
    ipairs = ipairs, pairs = pairs, tonumber = tonumber, strsplit = function(sep, s) local t = {} for part in (s .. sep):gmatch("(.-)" .. sep) do t[#t + 1] = part end return table.unpack(t) end,
    TTL = {
      Sim = { FLAVOR = "mainline" }, FLAVOR = { mainline = "mainline", classic = "classic", forever = "forever", vanilla = "vanilla" },
      IsFlightPathValid = function(from, to) return (from == 63 and to == 22) or (from == 62 and to == 27 and not opts.invalid) end,
      GameAPI = { GetFlightInfoFromNodeIDs = function(ids, areaID, toAreaID)
        calls[#calls + 1] = { "info", ids[1], ids[2], areaID, toAreaID }
        return { duration = 100 }
      end },
    },
    SV = {
      GetOption = function(_, key) if key == "record" then return not opts.noRecord end return not opts.quiet end,
      AddGossipFlight = function(_, entry, max) clock.entries[#clock.entries + 1] = entry clock.max = max end,
    },
    Round = function(v, d) local m = 10 ^ d return math.floor(v * m + 0.5) / m end, tostring = tostring, table = table, select = select, WOW_PROJECT_ID = 1,
    GetTime = function() return clock.now end,
    GetServerTime = function() return 1000 + clock.now end,
    GetBuildInfo = function() return "1.0", "12345" end,
    C_AddOns = { GetAddOnMetadata = function() return "1.2.3" end },
    C_Map = { GetBestMapForUnit = function() return 77 end },
    UnitName = function() return "Keeper" end,
    UnitFactionGroup = function() return "Horde" end,
    UnitPosition = function() return 1, 2, 3, 4 end,
    UnitOnTaxi = function() return clock.onTaxi end,
    C_Timer = { NewTicker = function(interval, fn)
      local t = { fn = fn, interval = interval }
      function t:Cancel() self.cancelled = true end
      clock.tickers[#clock.tickers + 1] = t
      return t
    end },
    addonName = "TaxiTimer",
    print = function(...) calls[#calls + 1] = { "print", ... } end,
    GPS = {
      Request = function(_, areaID, info) calls[#calls + 1] = { "request", areaID, info.duration } end,
      Discover = function(_, option, npc, options) clock.discovered[#clock.discovered + 1] = { option = option, npc = npc, options = options } end,
    },
    C_GossipInfo = { GetOptions = function() return gossip.options end },
    UnitGUID = function() return opts.secretGUID and SECRET or "Creature-0-0-0-0-12345-0" end,
    issecretvalue = function(value) return type(value) == "table" and value.secret == true end,
    hooksecurefunc = function(tbl, name, fn)
      local orig = tbl[name]
      tbl[name] = function(...) if orig then orig(...) end fn(...) end
      hooks[name] = tbl[name]
    end,
    GOSSIP_BUTTON_TYPE_OPTION = 3,
    GossipTitleButtonMixin = not opts.noMixin and { OnEnter = function() end, OnLeave = function() end } or nil,
    GameTooltip = {
      GetOwner = function() return tip.owner end,
      IsShown = function() return tip.shown end,
      SetOwner = function(_, owner, anchor) tip.owner, tip.anchor, tip.shown, tip.lines = owner, anchor, false, {} end,
      AddLine = function(_, text) tip.lines[#tip.lines + 1] = text end,
      Show = function() tip.shown = true end,
      Hide = function() tip.shown, tip.owner = false, nil end,
    },
    AddFlightTooltipLines = function(info, title) tip.lines[#tip.lines + 1] = "flight " .. info.duration .. (title and " titled" or "") end,
    AddOn = { RegisterEvent = function(_, event) events[event] = true end, HookScript = function(_, script, fn) handlers[script] = fn end },
  }
  local text = read(ROOT .. "core.lua")
  local from = text:find("local GossipFlight do", 1, true)
  local to = text:find("-- TaxiTimerAPI", from, true)
  assert(load(text:sub(from, to - 1), "gossip", "t", env))()
  -- advance the clock in steps, running the tickers that are alive
  function clock.advance(seconds)
    for _ = 1, seconds * 2 do
      clock.now = clock.now + 0.5
      for _, t in ipairs(clock.tickers) do if not t.cancelled then t.fn() end end
    end
  end
  function clock.alive()
    local n = 0
    for _, t in ipairs(clock.tickers) do if not t.cancelled then n = n + 1 end end
    return n
  end
  return { clock = clock, discovered = clock.discovered, calls = calls, hooks = hooks, handlers = handlers, events = events, gossip = gossip, env = env, tip = tip }
end

do
  local w = world()
  check(w.events.GOSSIP_SHOW and w.events.GOSSIP_OPTIONS_REFRESHED, "the gossip events are listened to")
  w.gossip.options = { { gossipOptionID = 33160, orderIndex = 0 }, { gossipOptionID = 11111, orderIndex = 1 } }
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  w.hooks.SelectOption(33160)
  check(#w.calls == 2 and w.calls[1][1] == "info" and w.calls[1][2] == 63 and w.calls[1][3] == 22 and w.calls[1][4] == 1209 and w.calls[1][5] == 1209, "choosing the option asks the db for its flight, between the taxi maps it has")
  check(w.calls[2][1] == "request" and w.calls[2][2] == 1209, "and the flight is requested for the taxi map of it")

  for i = #w.calls, 1, -1 do w.calls[i] = nil end
  -- the same one by its place in the list
  w.hooks.SelectOptionByIndex(0)
  check(#w.calls == 2 and w.calls[2][1] == "request", "choosing it by its place does the same")

  -- one that asks first is chosen again when it is confirmed
  local before = #w.calls
  w.hooks.SelectOption(33160, "", true)
  check(#w.calls == before + 2, "confirmed it is requested")
  before = #w.calls
  w.hooks.SelectOption(33160, "", false)
  check(#w.calls == before, "but not when it is said not to be")

  -- options that are not flights
  before = #w.calls
  w.hooks.SelectOption(11111)
  w.hooks.SelectOptionByIndex(1)
  w.hooks.SelectOption(99999)
  check(#w.calls == before, "other options are left alone")
  check(#w.discovered == 2 and w.discovered[1].option.gossipOptionID == 11111 and w.discovered[1].npc.id == 12345 and w.discovered[1].npc.type == "creature" and #w.discovered[1].options == 2, "but they are handed to the GPS to see if they put the player on a flight, with who it was and the options of the window")
  check(w.discovered[1].npc.name == "Keeper", "and the name of who it was")

  -- the options of a window that closed are still known, for a confirmation that comes after
  w.gossip.options = nil
  before = #w.calls
  w.hooks.SelectOption(33160, "", true)
  check(#w.calls == before + 2, "what was known of the options stays until the next window")
end

do
  local w = world()
  w.hooks.SelectOption(33160)
  check(#w.calls == 0, "nothing happens before a window was shown")
end

-- the gossip frame: hovering an option that is a flight adds its time to the tooltip, and nothing is written to the buttons
do
  local w = world()
  local enter = w.env.GossipTitleButtonMixin.OnEnter
  local tip = w.tip
  local function reset() tip.owner, tip.shown, tip.anchor, tip.lines = nil, false, nil, {} end
  -- the scroll box tells a button what it shows
  local function button(data) return { data = data, GetElementData = function(self) return self.data end } end
  local function option(id) return { buttonType = 3, info = { gossipOptionID = id, orderIndex = 0 } } end

  local flight = button(option(33160))
  enter(flight)
  check(tip.owner == flight and tip.anchor == "ANCHOR_RIGHT" and tip.shown and #tip.lines == 1 and tip.lines[1] == "flight 100 titled", "hovering an option that is a flight shows its time, with the name of where it goes")
  local fields = 0
  for _ in pairs(flight) do fields = fields + 1 end
  check(fields == 2, "and nothing was added to the button")

  reset()
  enter(button(option(11111)))
  check(tip.owner == nil and not tip.shown, "an option that is not a flight gets nothing")

  reset()
  enter(button({ buttonType = 5, info = { gossipOptionID = 33160 } }))
  enter(button({ buttonType = 1, text = "hello" }))
  check(tip.owner == nil and not tip.shown, "a quest or the text of the window gets nothing, even with the id of a flight")

  reset()
  enter({ GetID = function() return 0 end })
  check(tip.owner == nil and not tip.shown, "a button the scroll box did not make gets nothing")

  -- a button is used again for another option
  reset()
  flight.data = option(11111)
  enter(flight)
  check(tip.owner == nil and not tip.shown, "a button that is used for another option stops showing it")
  flight.data = option(33157)
  enter(flight)
  check(tip.owner == flight and #tip.lines == 1, "and shows the one it is used for now")

  -- it does not matter what the window was told last, the button knows
  reset()
  w.gossip.options = nil
  enter(button(option(33160)))
  check(tip.owner ~= nil and #tip.lines == 1, "what the button shows is used, not the list of options")

  -- leaving the button hides our tooltip, and only ours
  reset()
  local left = button(option(33160))
  enter(left)
  w.env.GossipTitleButtonMixin.OnLeave(left)
  check(not tip.shown and tip.owner == nil, "leaving the button hides the tooltip")
  reset()
  local other = {}
  tip.owner, tip.shown = other, true
  w.env.GossipTitleButtonMixin.OnLeave(left)
  check(tip.shown and tip.owner == other, "but not the tooltip of something else")

  -- an option that is a spell has a tooltip of the game already, the time is added to it
  reset()
  local spell = button(option(33160))
  tip.owner, tip.shown, tip.lines = spell, true, { "spell" }
  enter(spell)
  check(#tip.lines == 3 and tip.lines[1] == "spell" and tip.lines[2] == " " and tip.lines[3] == "flight 100 titled", "it is added to the tooltip that is there, after an empty line")
end

-- secret values are left alone
do
  local w = world()
  w.gossip.options = { { gossipOptionID = 33160, orderIndex = 0 } }
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  w.hooks.SelectOption(SECRET)
  w.hooks.SelectOptionByIndex(SECRET)
  check(#w.calls == 0, "an option that is chosen by a secret value is left alone")

  w.gossip.options = SECRET
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  w.hooks.SelectOption(33160)
  check(#w.calls == 0, "so is a list of options that is secret")

  w.gossip.options = { { gossipOptionID = SECRET, orderIndex = 0 }, { gossipOptionID = 33160, orderIndex = 1 } }
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  w.hooks.SelectOptionByIndex(0)
  check(#w.calls == 0, "an option with a secret id is left alone also when it is chosen by its place")
  w.hooks.SelectOptionByIndex(1)
  check(#w.calls == 2 and w.calls[2][1] == "request", "and the next one is not")

  -- the npc is only known if it is not secret, the flight does not need it
  local g = world({ secretGUID = true })
  g.gossip.options = { { gossipOptionID = 33160, orderIndex = 0 } }
  g.handlers.OnEvent(g.env.AddOn, "GOSSIP_SHOW")
  g.hooks.SelectOption(33160)
  check(#g.calls == 2 and g.calls[2][1] == "request", "a secret npc does not stop a flight")

  -- a button of an option that has a secret id gets nothing
  local secretButton = { GetElementData = function() return { buttonType = 3, info = { gossipOptionID = SECRET } } end }
  w.env.GossipTitleButtonMixin.OnEnter(secretButton)
  check(w.tip.owner == nil, "a button of an option that has a secret id gets nothing")
end

-- a game without the buttons keeps working
do
  local w = world({ noMixin = true })
  w.gossip.options = { { gossipOptionID = 33160, orderIndex = 0 } }
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  w.hooks.SelectOption(33160)
  check(#w.calls == 2 and w.calls[2][1] == "request", "without the buttons of the gossip frame the options still start flights")
end

-- the table is checked against the db when the first window is shown
do
  local w = world()
  w.gossip.options = { { gossipOptionID = 33157, orderIndex = 0 } }
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  check(#w.calls == 0, "flights the db has a path for are kept, and nothing is said")
  w.hooks.SelectOption(33157)
  check(#w.calls == 2 and w.calls[2][1] == "request", "so they are started")

  w = world({ invalid = true })
  w.gossip.options = { { gossipOptionID = 33157, orderIndex = 0 }, { gossipOptionID = 33160, orderIndex = 1 } }
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  check(#w.calls == 1 and w.calls[1][1] == "print", "a flight the db has no path for is told when debugging")
  w.hooks.SelectOption(33157)
  check(#w.calls == 1, "and it is not started")
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  check(#w.calls == 1, "it is only told once")
  w.hooks.SelectOption(33160)
  check(#w.calls == 3 and w.calls[3][1] == "request", "the others still are")

  w = world({ invalid = true, quiet = true })
  w.gossip.options = { { gossipOptionID = 33157, orderIndex = 0 } }
  w.handlers.OnEvent(w.env.AddOn, "GOSSIP_SHOW")
  check(#w.calls == 0, "nothing is said without debugging, and it is still left out")
  w.hooks.SelectOption(33157)
  check(#w.calls == 0, "and not started")
end

-- discovery: the GPS follows a flight that an option we know nothing of started, like the ones we know
local function gps()
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
    Visualization = { Start = function() r.log[#r.log + 1] = "V.Start" end, Takeoff = function() end, SetProgress = function() end, RequestStop = function() end },
    Recorder = { Start = function() end, Tick = function() end, Idle = function() r.idle = (r.idle or 0) + 1 end, Stop = function() end, RequestStop = function() end },
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

local OPTION_A = { gossipOptionID = 11111, orderIndex = 1, name = "Fly me", flags = 0 }
local OPTION_B = { gossipOptionID = 22222, orderIndex = 2, name = "Other" }
local WINDOW = { OPTION_A, OPTION_B, { gossipOptionID = 33333, orderIndex = 3, name = "Secret!" } }
local NPC = { type = "creature", id = 12345, name = "Keeper" }
local FLIGHT = { distance = 1000, distance2D = 1000, duration = 40, areaSpeed = 30, maps = { [1] = true }, points = { { x = 0, y = 0, map = 1 } } }

do
  local r = gps()
  r.record = false
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.onTaxi = true
  r.advance(2)
  check(r.alive() == 0 and #r.entries == 0, "not recording: nothing is followed or written")

  r = gps()
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.advance(12)
  check(r.alive() == 0 and #r.entries == 0, "no taxi in time: nothing is written and the flight is let go")

  r = gps()
  r.GPS:Discover(OPTION_B, NPC, WINDOW)
  r.advance(3)
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  check(r.alive() == 1, "a choice while waiting takes the place of the last one")
  r.advance(2)
  r.onTaxi = true
  r.advance(1)
  check(#r.entries == 0 and r.alive() == 1, "on a taxi: the flight goes on and nothing is kept until it has ended")
  r.onTaxi = false
  r.advance(2)
  r.onTaxi = true
  r.advance(2)
  check(#r.entries == 0 and r.alive() == 1, "a short time off the taxi is not landing")
  r.advance(30)
  r.onTaxi = false
  r.advance(3)
  check(#r.entries == 0 and r.alive() == 1, "and neither is a few seconds")
  r.advance(4)
  local e = r.entries[1]
  check(#r.entries == 1 and r.alive() == 0, "when it has landed the record is kept and the flight is over")
  check(e and e.npcType == "creature" and e.npcID == 12345 and e.npcName == "Keeper" and e.faction == "Horde" and e.addon == "1.2.3" and e.build == 12345 and e.project == 1, "with who and what it is")
  check(e and #e.options == 3 and e.options[1].id == 11111 and e.options[1].name == "Fly me", "the options of the window")
  check(e and #e.choices == 2 and e.choices[1].id == 22222 and e.choices[2].id == 11111 and e.choices[2].ago == 2.5 and e.choices[1].ago == 5.5, "the choices made, the last one a few seconds before")
  check(e and e.takeoffDelay == 2.5 and e.start.x == 1 and e.start.map == 4 and e.start.uiMap == 77 and e.landing and e.landing.map == 4, "and when and where")
  check(e and e.duration and e.duration > 30 and e.duration < 40 and r.max == 100, "how long it took, and the log is limited")
end

do
  -- the choices are remembered for a while, and the last few
  local r = gps()
  for i = 1, 7 do
    r.GPS:Discover({ gossipOptionID = i, orderIndex = i }, NPC, WINDOW)
    r.advance(1)
  end
  r.onTaxi = true
  r.advance(1)
  r.onTaxi = false
  r.advance(7)
  local e = r.entries[1]
  check(e and #e.choices == 5 and e.choices[1].id == 3 and e.choices[5].id == 7, "the last five choices are kept")
  r = gps()
  r.GPS:Discover(OPTION_B, NPC, WINDOW)
  r.advance(70)
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.onTaxi = true
  r.advance(1)
  r.onTaxi = false
  r.advance(7)
  check(#r.entries == 1 and #r.entries[1].choices == 1, "and not the ones that are more than a minute old")
end

do
  -- the flights of the GPS are decided the same way for the ones we know and the ones we do not
  local r = gps()
  r.GPS:Request(1209, FLIGHT)
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.onTaxi = true
  r.advance(1)
  r.onTaxi = false
  r.advance(30)
  check(#r.entries == 0 and r.log[1] == "V.Start", "a flight that is waiting for the taxi is not taken the place of by an option we know nothing of")

  r = gps()
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.GPS:Request(1209, FLIGHT)
  r.onTaxi = true
  r.advance(1)
  r.onTaxi = false
  r.advance(7)
  check(#r.entries == 0, "but it is by a flight we know")

  r = gps()
  r.GPS:Request(1209, FLIGHT)
  r.onTaxi = true
  r.advance(2)
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.advance(1)
  r.onTaxi = false
  r.advance(7)
  check(#r.entries == 0, "a flight that is going on is left alone")

  r = gps()
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.onTaxi = true
  r.advance(2)
  r.GPS:Discover(OPTION_B, NPC, WINDOW)
  r.GPS:Request(1209, FLIGHT)
  r.advance(30)
  r.onTaxi = false
  r.advance(7)
  check(#r.entries == 1 and #r.entries[1].choices == 1, "a flight that is going on is not taken the place of or ended by another choice, and the record is of the one that started")
  r.GPS:Request(1209, FLIGHT)
  r.onTaxi = true
  r.advance(2)
  check(r.alive() == 1, "a flight can be asked for after it landed")
end

do
  local r = gps()
  r.debug = true
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.onTaxi = true
  r.advance(1)
  check(#r.log == 1 and r.log[1]:find("Keeper") and r.log[1]:find("12345"), "it is told when debugging")
  r.onTaxi = false
  r.advance(7)
  check(#r.log == 2 and r.log[2]:find("recorded") and r.log[2]:find("Keeper"), "and again when the flight was recorded")
  r = gps()
  r.GPS:Discover(OPTION_A, NPC, WINDOW)
  r.onTaxi = true
  r.advance(1)
  r.onTaxi = false
  r.advance(7)
  check(#r.log == 0 and #r.entries == 1, "nothing is told without debugging")
  -- values that are secret are left out of the record
  r = gps()
  r.GPS:Discover({ gossipOptionID = { secret = true }, orderIndex = 1, name = { secret = true } }, { type = "creature" }, { { gossipOptionID = { secret = true }, orderIndex = 1 } })
  r.onTaxi = true
  r.advance(1)
  r.onTaxi = false
  r.advance(7)
  local e = r.entries[1]
  check(e and e.choices[1].id == nil and e.choices[1].name == nil and e.options[1].id == nil and e.npcID == nil, "what is secret is left out")
end

print(failures == 0 and "all good" or (failures .. " checks failed"))
return failures
