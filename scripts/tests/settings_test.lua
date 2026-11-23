-- Runs settings.lua with a stand-in for the game and the libraries, and the saved options code of core.lua, to see what they do.
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

--
-- the saved options: defaults and the mode that was called details
--
local function loadSV(saved)
  local text = read(ROOT .. "core.lua")
  local a = text:find("---@class SV\nlocal SV do", 1, true)
  local b = text:find("---@class Visualization", a, true)
  local env = { type = type, pairs = pairs, setmetatable = setmetatable, rawget = rawget, table = table, TaxiTimerDB = saved }
  setmetatable(env, { __newindex = function(t, k, v) rawset(t, k, v) end })
  local SV = assert(load(text:sub(a, b - 1) .. "\nreturn SV", "sv", "t", env))()
  SV:Init()
  return SV, env
end

do
  local SV = loadSV(nil)
  check(SV:GetOption("mode") == "bar" and SV:GetOption("timer") == true and SV:GetOption("destination") == true and SV:GetOption("checkpoints") == true, "defaults")
  check(SV:GetDefaultOption("timer") == true, "the default of an option")
end
do
  local SV = loadSV({ options = { mode = "details" }, flights = {} })
  check(SV:GetOption("mode") == "bar" and SV:GetOption("checkpoints") == true, "details becomes the bar with the checkpoints")
end
do
  local SV = loadSV({ options = { mode = "stopwatch", checkpoints = false }, flights = {} })
  check(SV:GetOption("mode") == "stopwatch" and SV:GetOption("checkpoints") == false, "other modes stay")
end

--
-- settings.lua
--
local function world(opts)
  local calls = { visualization = {}, lem = {}, settings = {} }
  local SV = loadSV(nil)
  local Visualization = {
    GetFrame = function() calls.visualization[#calls.visualization + 1] = "GetFrame" return "frame" end,
    Apply = function() calls.visualization[#calls.visualization + 1] = "Apply" end,
    SetEditing = function(_, on) calls.visualization[#calls.visualization + 1] = on and "Editing" or "NotEditing" end,
  }
  local ns = { SV = SV, Visualization = Visualization, onLoad = {} }
  local callbacks = {}
  local lem
  if opts.lem then
    lem = {
      SettingType = { Dropdown = 0, Checkbox = 1, Slider = 2 },
      AddFrame = function(_, frame, callback, default, name) calls.lem.addFrame = { frame = frame, callback = callback, default = default, name = name } end,
      AddFrameSettings = function(_, frame, settings) calls.lem.settings = settings end,
      RefreshFrameSettings = function(_, frame) calls.lem.refresh = (calls.lem.refresh or 0) + 1 end,
      RegisterCallback = function(_, event, fn) callbacks[event] = fn end,
      IsInEditMode = function() return opts.inEditMode or false end,
    }
  end
  local settingsCalls = { settings = {}, dropdowns = {}, checkboxes = {}, parents = {} }
  local initializers = 0
  local function initializer(kind, setting)
    initializers = initializers + 1
    local init = { id = initializers, kind = kind, setting = setting }
    function init:SetParentInitializer(parent, predicate) settingsCalls.parents[#settingsCalls.parents + 1] = { child = self, parent = parent, predicate = predicate } end
    return init
  end
  local Settings
  if opts.settings then
    Settings = {
      VarType = { String = "string", Boolean = "boolean" },
      RegisterVerticalLayoutCategory = function(name) settingsCalls.category = name return { name = name } end,
      RegisterAddOnSetting = function(category, variable, key, tbl, varType, name, default)
        local s = { variable = variable, key = key, tbl = tbl, varType = varType, name = name, default = default }
        function s:SetValueChangedCallback(fn) self.changed = fn end
        settingsCalls.settings[#settingsCalls.settings + 1] = s
        return s
      end,
      CreateDropdown = function(category, setting, getOptions, tooltip)
        local init = initializer("dropdown", setting)
        init.options = getOptions()
        init.tooltip = tooltip
        settingsCalls.dropdowns[#settingsCalls.dropdowns + 1] = init
        return init
      end,
      CreateCheckbox = function(category, setting, tooltip)
        local init = initializer("checkbox", setting)
        init.tooltip = tooltip
        settingsCalls.checkboxes[#settingsCalls.checkboxes + 1] = init
        return init
      end,
      CreateControlTextContainer = function()
        local c = { data = {} }
        function c:Add(value, label) self.data[#self.data + 1] = { value = value, label = label } end
        function c:GetData() return self.data end
        return c
      end,
      RegisterAddOnCategory = function(category) settingsCalls.registered = category end,
    }
  end
  local env = {
    ipairs = ipairs, pairs = pairs, type = type,
    LibStub = function(name, silent) if name == "LibEditMode" then return lem end end,
    Settings = Settings,
    WOW_PROJECT_ID = opts.project or 1, WOW_PROJECT_MAINLINE = 1,
  }
  local text = read(ROOT .. "core.lua")
  local from = text:find("local SettingsUI do", 1, true)
  local to = text:find("---@class AddOnFrame", from, true)
  env.SV, env.Visualization, env.addonName = SV, Visualization, "TaxiTimer"
  local SettingsUI = assert(load(text:sub(from, to - 1) .. "\nreturn SettingsUI", "settings", "t", env))()
  SettingsUI:Init()
  return { ns = ns, SV = SV, calls = calls, lem = lem, callbacks = callbacks, settings = settingsCalls }
end

-- the Edit Mode and the settings of the game, both there
do
  local w = world({ lem = true, settings = true })
  local lemCalls = w.calls.lem
  check(lemCalls.addFrame and lemCalls.addFrame.frame == "frame" and lemCalls.addFrame.name == "TaxiTimer", "the bar is added to the Edit Mode")
  check(lemCalls.addFrame.default.point == "TOP" and lemCalls.addFrame.default.y == -110, "with the default position of the bar")
  lemCalls.addFrame.callback("frame", "Modern", "CENTER", 12, -34)
  local bar = w.SV:GetOption("bar")
  check(bar[1] == "CENTER" and bar[2] == "CENTER" and bar[3] == 12 and bar[4] == -34, "moving the bar saves where it is")

  local settings = lemCalls.settings
  -- 1 mode, 2 timer, 3 its place, 4 its outline, 5 destination, 6 its place, 7 its outline, 8 checkpoints
  check(#settings == 8, "eight settings in the Edit Mode")
  check(settings[1].kind == 0 and #settings[1].values == 3 and settings[1].values[1].value == "off", "the mode is a dropdown of off, bar and stopwatch")
  check(settings[2].kind == 1 and settings[5].kind == 1 and settings[8].kind == 1, "the timer, the destination and the checkpoints are toggles")
  check(settings[4].kind == 1 and settings[7].kind == 1, "so are the outlines")
  check(settings[3].kind == 0 and #settings[3].values == 9 and settings[6].kind == 0 and #settings[6].values == 9, "the places are dropdowns of nine places")
  check(settings[3].values[1].value == "TOPLEFT" and settings[3].values[5].value == "CENTER" and settings[3].values[9].value == "BOTTOMRIGHT", "above the bar, on it and below it")
  local allCanHide = true
  for i = 2, 8 do allCanHide = allCanHide and settings[i].hidden ~= nil end
  check(settings[1].hidden == nil and allCanHide, "all but the mode can be hidden")
  check(settings[2].hidden() == false and settings[3].hidden() == false and settings[4].hidden() == false and settings[8].hidden() == false, "they show while the mode is the bar")
  check(settings[5].hidden() == false and settings[6].hidden() == false and settings[7].hidden() == false, "and what is under the destination is there while the destination is")
  check(settings[1].default == "bar" and settings[3].default == "BOTTOMRIGHT" and settings[6].default == "BOTTOMLEFT" and settings[2].default == true and settings[5].default == true, "the defaults are the ones of the options")
  check(settings[4].default == true and settings[7].default == true, "the outlines are on")
  settings[5].set("Modern", true, false)
  check(settings[6].hidden() == false and settings[7].hidden() == false and lemCalls.refresh == 1, "they show with it, and the dialog is drawn again")
  settings[2].set("Modern", false, false)
  check(settings[3].hidden() == true and settings[4].hidden() == true and lemCalls.refresh == 2, "what is under the timer goes with it")
  settings[3].set("Modern", "BOTTOM", false)
  check(w.SV:GetOption("timerPosition") == "BOTTOM" and settings[3].get() == "BOTTOM" and lemCalls.refresh == 2, "a place is saved, and the dialog is not drawn again for it")
  settings[7].set("Modern", true, false)
  check(w.SV:GetOption("destinationOutline") == true and settings[7].get() == true and lemCalls.refresh == 2, "an outline is saved, and the dialog is not drawn again for it")
  settings[1].set("Modern", "stopwatch", false)
  check(w.SV:GetOption("mode") == "stopwatch" and settings[1].get() == "stopwatch", "choosing the stopwatch is saved")
  check(settings[2].hidden() == true and settings[5].hidden() == true and settings[6].hidden() == true and settings[7].hidden() == true and settings[8].hidden() == true, "and the ones for the bar are hidden")
  check(lemCalls.refresh == 3, "the dialog is drawn again when the mode changes")
  settings[8].set("Modern", true, false)
  check(w.SV:GetOption("checkpoints") == true and settings[8].get() == true and lemCalls.refresh == 3, "a toggle with nothing under it is saved without drawing the dialog again")
  local applied = 0
  for _, name in ipairs(w.calls.visualization) do if name == "Apply" then applied = applied + 1 end end
  check(applied == 6, "what is shown follows each choice")

  w.callbacks.enter()
  w.callbacks.exit()
  local show, hide = 0, 0
  for _, name in ipairs(w.calls.visualization) do
    if name == "Editing" then show = show + 1 elseif name == "NotEditing" then hide = hide + 1 end
  end
  check(show == 1 and hide == 1, "the example is shown in the Edit Mode and goes when it is left")

  -- the settings of the game
  local s = w.settings
  w.SV:SetOption("mode", "bar")
  w.SV:SetOption("timer", true)
  w.SV:SetOption("destination", false)
  check(s.category == "TaxiTimer" and s.registered and s.registered.name == "TaxiTimer", "the category is registered")
  check(#s.settings == 8 and #s.dropdowns == 3 and #s.checkboxes == 5, "the same list is there")
  check(s.settings[1].variable == "TAXITIMER_MODE" and s.settings[1].key == "mode" and s.settings[1].tbl == w.SV:GetOptions() and s.settings[1].varType == "string" and s.settings[1].default == "bar", "the mode is kept in the options")
  check(s.settings[3].variable == "TAXITIMER_TIMERPOSITION" and s.settings[3].varType == "string" and s.settings[3].default == "BOTTOMRIGHT", "so is the place of the timer")
  check(s.settings[4].variable == "TAXITIMER_TIMEROUTLINE" and s.settings[4].varType == "boolean" and s.settings[4].default == true, "and its outline")
  check(s.settings[2].varType == "boolean" and s.settings[8].key == "checkpoints", "toggles are booleans")
  check(#s.dropdowns[1].options == 3 and s.dropdowns[1].options[2].value == "bar" and s.dropdowns[1].options[2].label == "Bar", "the dropdown has what can be chosen")
  check(#s.dropdowns[2].options == 9 and s.dropdowns[2].options[1].value == "TOPLEFT" and s.dropdowns[2].options[1].label == "Above, left", "and so has the one for the places")
  -- checkboxes: 1 timer, 2 timer outline, 3 destination, 4 destination outline, 5 checkpoints
  check(#s.parents == 7, "seven of them are under another")
  check(s.parents[1].parent == s.dropdowns[1] and s.parents[1].child == s.checkboxes[1], "the timer is under the mode")
  check(s.parents[2].parent == s.checkboxes[1] and s.parents[2].child == s.dropdowns[2], "its place is under the timer")
  check(s.parents[3].parent == s.checkboxes[1] and s.parents[3].child == s.checkboxes[2], "and so is its outline")
  check(s.parents[4].parent == s.dropdowns[1] and s.parents[5].parent == s.checkboxes[3] and s.parents[5].child == s.dropdowns[3] and s.parents[6].parent == s.checkboxes[3] and s.parents[6].child == s.checkboxes[4], "the place and the outline of the destination are under the destination")
  check(s.parents[1].predicate() == true and s.parents[2].predicate() == true and s.parents[5].predicate() == false and s.parents[6].predicate() == false, "they are available when the bar is shown, and what is under the destination when it is on")
  w.SV:SetOption("destination", true)
  check(s.parents[5].predicate() == true and s.parents[6].predicate() == true, "and it is when the destination is")
  w.SV:SetOption("mode", "off")
  check(s.parents[1].predicate() == false and s.parents[2].predicate() == false and s.parents[7].predicate() == false, "none are available unless it is the bar")
  w.SV:SetOption("mode", "bar")
  local before = 0
  for _, name in ipairs(w.calls.visualization) do if name == "Apply" then before = before + 1 end end
  s.settings[2].changed()
  local after = 0
  for _, name in ipairs(w.calls.visualization) do if name == "Apply" then after = after + 1 end end
  check(after == before + 1, "a change in the settings of the game is applied")
end

-- where the texts are put
do
  local text = read(ROOT .. "core.lua")
  local from = text:find("local TEXT_FONT =", 1, true)
  local to = text:find("-- What is flown of the route up to the last taxi node we passed", from, true)
  local options = {}
  local SV = { GetOption = function(_, key) return options[key] end }
  local bar = {}
  local chunk = assert(load(text:sub(from, to - 1) .. "\nreturn bar", "texts", "t", { SV = SV, bar = bar, select = select, ipairs = ipairs }))
  chunk()
  local function fontString()
    local fs = { points = {}, justify = nil }
    function fs:ClearAllPoints() self.points = {} end
    function fs:SetPoint(point, relative, relativePoint, x, y) self.points[#self.points + 1] = { point, relative, relativePoint, x or 0, y or 0 } end
    function fs:SetJustifyH(value) self.justify = value end
    function fs:GetFont() return "font", 14 end
    function fs:SetFontObject(name) self.fontObject = name; self.color = nil end
    function fs:SetTextColor(r, g, b) self.color = { r, g, b } end
    return fs
  end
  local function place(timerPosition, destinationPosition, timer, destination, timerOutline, destinationOutline)
    options = { timerPosition = timerPosition, destinationPosition = destinationPosition, timer = timer ~= false, destination = destination ~= false, timerOutline = timerOutline, destinationOutline = destinationOutline }
    local frame = "frame"
    bar.label, bar.destination = fontString(), fontString()
    bar:PlaceTexts(frame)
    return bar.label, bar.destination, frame
  end
  local function at(fs, point, relative, relativePoint, x, y)
    local p = fs.points[1]
    return #fs.points == 1 and p[1] == point and p[2] == relative and p[3] == relativePoint and p[4] == x and p[5] == y
  end

  local timer, destination, frame = place("CENTER", "TOP")
  check(at(timer, "CENTER", frame, "CENTER", 0, 0) and timer.justify == "CENTER", "the timer on the bar, in the middle")
  check(at(destination, "BOTTOM", frame, "TOP", 0, 4) and destination.justify == "CENTER", "the destination above it")
  timer, destination, frame = place("BOTTOM", "TOP")
  check(at(timer, "TOP", frame, "BOTTOM", 0, -1) and at(destination, "BOTTOM", frame, "TOP", 0, 4), "one above and one below do not share")
  timer, destination, frame = place("TOPLEFT", "BOTTOMRIGHT")
  check(at(timer, "BOTTOMLEFT", frame, "TOPLEFT", 0, 4) and timer.justify == "LEFT", "above, at the left end")
  check(at(destination, "TOPRIGHT", frame, "BOTTOMRIGHT", 0, -1) and destination.justify == "RIGHT", "below, at the right end")
  timer, destination, frame = place("LEFT", "RIGHT")
  check(at(timer, "LEFT", frame, "LEFT", 6, 0) and at(destination, "RIGHT", frame, "RIGHT", -6, 0), "on the bar, at the ends")

  timer, destination, frame = place("TOP", "TOP")
  check(at(timer, "BOTTOM", frame, "TOP", 0, 4) and at(destination, "BOTTOM", frame, "TOP", 0, 4 + 16), "both above: the timer next to the bar and the destination over it")
  timer, destination, frame = place("BOTTOMRIGHT", "BOTTOMRIGHT")
  check(at(timer, "TOPRIGHT", frame, "BOTTOMRIGHT", 0, -1) and at(destination, "TOPRIGHT", frame, "BOTTOMRIGHT", 0, -1 - 16) and destination.justify == "RIGHT", "both below: the timer next to the bar and the destination under it")
  timer, destination, frame = place("TOPLEFT", "TOPLEFT")
  check(at(destination, "BOTTOMLEFT", frame, "TOPLEFT", 0, 20) and destination.justify == "LEFT", "the same in the corners")
  timer, destination, frame = place("LEFT", "LEFT")
  check(at(destination, "LEFT", frame, "LEFT", 6, 0) and at(timer, "LEFT", destination, "RIGHT", 8, 0), "both at the left of the bar: side by side, the destination first")
  timer, destination, frame = place("RIGHT", "RIGHT")
  check(at(timer, "RIGHT", frame, "RIGHT", -6, 0) and at(destination, "RIGHT", timer, "LEFT", -8, 0), "both at the right of the bar: the timer last")
  timer, destination, frame = place("CENTER", "CENTER")
  check(at(destination, "RIGHT", frame, "CENTER", -4, 0) and destination.justify == "RIGHT" and at(timer, "LEFT", frame, "CENTER", 4, 0) and timer.justify == "LEFT", "both in the middle: the destination ends where the timer begins")

  timer, destination, frame = place("TOP", "TOP", true, false)
  check(at(destination, "BOTTOM", frame, "TOP", 0, 4), "with the destination off the timer has the place to itself")
  timer, destination, frame = place("TOP", "TOP", false, true)
  check(at(timer, "BOTTOM", frame, "TOP", 0, 4) and at(destination, "BOTTOM", frame, "TOP", 0, 4), "and the other way")

  -- the outline is another font of the same family, so the fonts of the language are kept
  timer, destination = place("CENTER", "TOP", true, true, false, false)
  check(timer.fontObject == "SystemFont_Shadow_Med2" and destination.fontObject == "SystemFont_Shadow_Med2", "without the outline the fonts are the ones with a shadow")
  timer, destination = place("CENTER", "TOP", true, true, true, false)
  check(timer.fontObject == "SystemFont_Outline_Med2" and destination.fontObject == "SystemFont_Shadow_Med2", "the outline is for each one of them")
  timer, destination = place("CENTER", "TOP", true, true, false, true)
  check(timer.fontObject == "SystemFont_Shadow_Med2" and destination.fontObject == "SystemFont_Outline_Med2", "also the other way")
  check(timer.color[1] == 1 and timer.color[2] == 1 and timer.color[3] == 1 and destination.color[1] == 1, "the color is put back, a font has its own")
end

-- a game with no Edit Mode has the settings of the game
do
  local w = world({ lem = false, settings = true, project = 2 })
  check(w.calls.lem.addFrame == nil and #w.calls.visualization == 0 and w.settings.category == "TaxiTimer" and #w.settings.settings == 8, "a game with no Edit Mode has the settings of the game and nothing else")
end

-- the main game without the library: only the settings of the game
do
  local w = world({ lem = false, settings = true })
  check(w.calls.lem.addFrame == nil and #w.settings.settings == 8, "without the Edit Mode there are still the settings of the game")
end

print(failures == 0 and "all good" or (failures .. " checks failed"))
return failures
