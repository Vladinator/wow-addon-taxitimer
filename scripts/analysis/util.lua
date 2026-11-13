-- Small helpers for the analysis. They only use what every version of Lua from 5.1 and up has.

---A list of values by a key that remembers the order the keys were added in.
---@class AnalysisGroups
---@field order string[] The keys in the order they were added.
---@field byKey table<string, any[]> The values of each key.

---@class AnalysisUtil
local util = {}

---@type number
util.INF = math.huge

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

---The distance of a step.
---@param dx number
---@param dy number
---@return number
function util.hypot(dx, dy)
	return sqrt(dx * dx + dy * dy)
end

---Rounds to the number of decimals, halves away from zero.
---@param value number
---@param decimals? number
---@return number
function util.round(value, decimals)
	local mult = 10 ^ (decimals or 0)
	if value < 0 then
		return -floor(-value * mult + 0.5) / mult
	end
	return floor(value * mult + 0.5) / mult
end

---Returns the keys of a table in rising order (or the order the comparison gives).
---@generic K
---@param t table<K, any>
---@param cmp? fun(a: K, b: K): boolean
---@return K[]
function util.keys(t, cmp)
	local keys = {}
	for key in pairs(t) do
		keys[#keys + 1] = key
	end
	table.sort(keys, cmp)
	return keys
end

---The value that has half of the total weight below it.
---@param weights table<number, number> `weights[value] = weight`
---@return number?
function util.weightedMedian(weights)
	local keys = util.keys(weights)
	if #keys == 0 then
		return nil
	end
	local total = 0
	for _, weight in pairs(weights) do
		total = total + weight
	end
	local half, sum = total / 2, 0
	for _, value in ipairs(keys) do
		sum = sum + weights[value]
		if sum >= half then
			return value
		end
	end
end

---Seconds as minutes, seconds and tenths of a second.
---@param seconds number
---@return string
function util.clock(seconds)
	local sign = seconds < 0 and "-" or ""
	seconds = abs(seconds)
	return string.format("%s%d:%04.1f", sign, floor(seconds / 60), math.fmod(seconds, 60))
end

---@param seconds number
---@return string
function util.signed(seconds)
	return string.format("%+.1f", seconds)
end

---Checks if the single bit `flag` is set in `flags`.
---@param flags number
---@param flag number
---@return boolean
function util.hasFlag(flags, flag)
	return flags % (flag * 2) >= flag
end

---@param format string
---@param ... any
function util.printf(format, ...)
	io.write(string.format(format, ...))
end

---@param format string
---@param ... any
function util.warn(format, ...)
	io.stderr:write(string.format(format, ...), "\n")
end

---@return AnalysisGroups
function util.newGroups()
	return { order = {}, byKey = {} }
end

---@param groups AnalysisGroups
---@param key string
---@param value any
function util.addToGroup(groups, key, value)
	local list = groups.byKey[key]
	if not list then
		list = {}
		groups.byKey[key] = list
		groups.order[#groups.order + 1] = key
	end
	list[#list + 1] = value
end

return util
