---@meta

---The chat window that messages go to.
---@type MessageFrame
DEFAULT_CHAT_FRAME = nil

---The slash commands, by the name an addon gives its command.
---@type table<string, fun(message: string?)>
SlashCmdList = {}

---The stopwatch of the game.
---@type Frame
StopwatchFrame = nil

---What counts the stopwatch, `timer` is the seconds it shows.
---@type Frame|{ timer: number? }
StopwatchTicker = nil

function Stopwatch_Toggle() end
function Stopwatch_Clear() end
function Stopwatch_Play() end
---@return boolean
function Stopwatch_IsPlaying() end
---@param hours number
---@param minutes number
---@param seconds number
function Stopwatch_StartCountdown(hours, minutes, seconds) end

---The pins of the flight paths on the flight map of the game.
---@class FlightMapFlightPointPinMixin
---@field OnMouseEnter fun(self: FlightMapFlightPointPinMixin)
FlightMap_FlightPointPinMixin = {}

--
-- MARK: Blizzard_Settings
--

---@class SettingsCategory

---@class SettingsSetting
---@field SetValueChangedCallback fun(self: SettingsSetting, callback: fun(setting: SettingsSetting, value: any))

---@class SettingsInitializer
---When the control is only available while its parent is. The parent is a control, and the predicate says if this one is available.
---@field SetParentInitializer fun(self: SettingsInitializer, parent: SettingsInitializer, modifyPredicate?: fun(): boolean)

---What can be chosen in a dropdown, as the game wants it.
---@class SettingsControlTextContainer
---@field Add fun(self: SettingsControlTextContainer, value: any, label: string, tooltip?: string)
---@field GetData fun(self: SettingsControlTextContainer): table[]

---@class SettingsVarType
---@field Boolean "boolean"
---@field String "string"
---@field Number "number"

---@class SettingsPolyfill
---@field VarType SettingsVarType
---Makes a category in the addon settings with the controls in a list.
---@field RegisterVerticalLayoutCategory fun(name: string): SettingsCategory, table
---Makes a setting that is kept in `variableTbl[variableKey]`, which gets its default if it has no value.
---@field RegisterAddOnSetting fun(category: SettingsCategory, variable: string, variableKey: string, variableTbl: table, variableType: string, name: string, defaultValue: any): SettingsSetting
---@field CreateDropdown fun(category: SettingsCategory, setting: SettingsSetting, options: (fun(): table[])|table[], tooltip?: string): SettingsInitializer
---@field CreateCheckbox fun(category: SettingsCategory, setting: SettingsSetting, tooltip?: string): SettingsInitializer
---@field CreateControlTextContainer fun(): SettingsControlTextContainer
---Shows the category in the addon settings, once all of it is made.
---@field RegisterAddOnCategory fun(category: SettingsCategory)
Settings = {}

--
-- MARK: LibEditMode
--

-- The position a frame has when it is moved, the layout is the one of the Edit Mode that is active.
---@alias LibEditModePositionCallback fun(frame: Frame, layoutName: string, point: FramePoint, x: number, y: number)

-- Where a frame is until it is moved.
---@class LibEditModeDefaultPosition
---@field point FramePoint
---@field x number
---@field y number

-- The events of the Edit Mode and what they tell.
---@alias LibEditModeEvent "enter"|"exit"|"layout"|"create"|"rename"|"delete"

-- A setting that is shown in the dialog of a frame. The getter is given the layout and gives the value, the setter is given the layout, the new value and if it was a reset.
---@class LibEditModeSetting
---@field kind number One of `SettingType`.
---@field name string The label.
---@field desc? string Shown in a tooltip.
---@field default any
---@field get fun(layoutName: string): any
---@field set fun(layoutName: string, value: any, fromReset: boolean)
---@field disabled? boolean|fun(): boolean
---@field hidden? boolean|fun(): boolean

-- A show/hide toggle.
---@class LibEditModeCheckbox : LibEditModeSetting
---@field default boolean
---@field get fun(layoutName: string): boolean
---@field set fun(layoutName: string, value: boolean, fromReset: boolean)

---@class LibEditModeSlider : LibEditModeSetting
---@field default number
---@field get fun(layoutName: string): number
---@field set fun(layoutName: string, value: number, fromReset: boolean)
---@field minValue? number Default 0.
---@field maxValue? number Default 1.
---@field valueStep? number Default 1.
---@field formatter? fun(value: number): number

---@class LibEditModeDropdownOption
---@field text string
---@field value? any The text if it is not set.

---@class LibEditModeDropdown : LibEditModeSetting
---@field values? LibEditModeDropdownOption[]|fun(): LibEditModeDropdownOption[]
---@field multiple? boolean
---@field generator? fun(dropdown: Frame, rootDescription: table, setting: LibEditModeDropdown)
---@field height? number

---@class LibEditModeColorPicker : LibEditModeSetting
---@field default ColorMixin
---@field get fun(layoutName: string): ColorMixin
---@field set fun(layoutName: string, value: ColorMixin, fromReset: boolean)
---@field hasOpacity? boolean

---@class LibEditModeDivider : LibEditModeSetting
---@field hideLabel? boolean

---@class LibEditModeExpander : LibEditModeSetting
---@field hideArrow? boolean
---@field expandedLabel? string Both labels are needed for them to be used.
---@field collapsedLabel? string

---@alias LibEditModeSettingObject LibEditModeCheckbox|LibEditModeSlider|LibEditModeDropdown|LibEditModeColorPicker|LibEditModeDivider|LibEditModeExpander

-- A button in the dialog of a frame.
---@class LibEditModeButton
---@field text string
---@field click fun()

---@class LibEditModeSettingType
---@field Dropdown number
---@field Checkbox number
---@field Slider number
---@field ColorPicker number
---@field Divider number
---@field Expander number

-- The methods of `LibEditMode` that are used, called with `:`.
-- On the games that have no Edit Mode what stands in for it does nothing, and `IsInEditMode` is false.
---@class LibEditModePolyfill
---@field SettingType LibEditModeSettingType
---Makes a frame something that can be moved in the Edit Mode. `callback` is told every time it is moved, `default` is where it is until then, and `name` is what the Edit Mode calls it (the name of the frame if there is none).
---@field AddFrame fun(self: LibEditModePolyfill, frame: Frame, callback: LibEditModePositionCallback, default: LibEditModeDefaultPosition, name?: string)
---The settings shown in the dialog of a frame that was added.
---@field AddFrameSettings fun(self: LibEditModePolyfill, frame: Frame, settings: LibEditModeSettingObject[])
---The buttons shown in the dialog of a frame that was added.
---@field AddFrameSettingsButtons fun(self: LibEditModePolyfill, frame: Frame, buttons: LibEditModeButton[])
---Enables or disables a setting by its name, it stays shown.
---@field EnableFrameSetting fun(self: LibEditModePolyfill, frame: Frame, settingName: string)
---@field DisableFrameSetting fun(self: LibEditModePolyfill, frame: Frame, settingName: string)
---Draws the dialog again, for when what a setting says changed from somewhere else.
---@field RefreshFrameSettings fun(self: LibEditModePolyfill, frame: Frame)
---Tells when the Edit Mode is entered (`enter`) or left (`exit`), and when the layout changes (`layout`, also at login, with the name and index of the layout). The others are `create`, `rename` and `delete` of a layout.
---@field RegisterCallback fun(self: LibEditModePolyfill, event: LibEditModeEvent, callback: fun(...))
---If the Edit Mode is open.
---@field IsInEditMode fun(self: LibEditModePolyfill): boolean
---The layout that is active, nothing until the server has given it (use the `layout` callback).
---@field GetActiveLayout fun(self: LibEditModePolyfill): number?
---@field GetActiveLayoutName fun(self: LibEditModePolyfill): string?
---What was given to `AddFrame` as the default position.
---@field GetFrameDefaultPosition fun(self: LibEditModePolyfill, frame: Frame): LibEditModeDefaultPosition?
