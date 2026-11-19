-- What the gossip options that put the player on a flight can be: the flights between the taxi nodes close to where the flight started and ended that take as long as it did.

local START_YARDS = 200 -- how far from a taxi node the player can be when the flight starts (it is seen up to a moment after taking off)
local END_YARDS = 300 -- how far from a taxi node the player can be when the flight is over (the player is seen some seconds after landing)
local MAX_SHOWN = 4 -- the candidates shown for each
local CLOSE_SECONDS = 3 -- a candidate that is this close in time is a good one
local APART_SECONDS = 3 -- and the next one has to be this much further off for the first one to be the likely one

---A taxi node close to a place.
---@class GossipNode
---@field id number
---@field yards? number How far it is, not known for the ones that are only reachable.

---A taxi node that is known to be a distance from a place.
---@class GossipNearNode : GossipNode
---@field yards number

---@class GossipCandidate
---@field from number The taxi node the flight starts at.
---@field to number The taxi node it ends at.
---@field estimate number The seconds the simulation gives it.
---@field error number The estimate minus the seconds the flight took.
---@field startYards number How far the start was from the taxi node.
---@field endYards? number How far the end was from the taxi node.

---@param ctx AnalysisContext
---@return fun(entries: GossipFlightRecord[], loadData: TaxiDataLoader, getClient: fun(record: { flavor?: TaxiTimerLib-1.0_GameFlavor, project?: number }): TaxiTimerLib-1.0_GameFlavor)
return function(ctx)
	local util = ctx.util
	local printf, warn = util.printf, util.warn
	local format, abs, sqrt = string.format, math.abs, math.sqrt

	-- the taxi nodes of the map that are close to a place, nearest first
	---@param data TaxiData
	---@param x number
	---@param y number
	---@param map number
	---@param yards number
	---@return GossipNearNode[]
	local function nodesNear(data, x, y, map, yards)
		local found = {} ---@type GossipNearNode[]
		for id, node in pairs(data.nodes) do
			if node.map == map then
				local dx, dy = node.x - x, node.y - y
				local distance = sqrt(dx * dx + dy * dy)
				if distance <= yards and data.paths[id] then
					found[#found + 1] = { id = id, yards = distance }
				end
			end
		end
		table.sort(found, function(a, b)
			return a.yards < b.yards
		end)
		return found
	end

	-- `UnitPosition` gives y before x, and the places in the entries are what it gave. Which one matches the taxi nodes is found by trying both.
	---@param x number
	---@param y number
	---@param map number
	---@param data TaxiData
	---@return GossipNearNode[] starts
	---@return boolean swap
	local function findStarts(x, y, map, data)
		local best, bestSwap = {}, false
		for _, swap in ipairs({ false, true }) do
			local found = nodesNear(data, swap and y or x, swap and x or y, map, START_YARDS)
			if #found > 0 and (#best == 0 or found[1].yards < best[1].yards) then
				best, bestSwap = found, swap
			end
		end
		return best, bestSwap
	end

	---@param entry GossipFlightRecord
	---@param data TaxiData
	---@return GossipCandidate[]? candidates Nothing if the place of the flight is not known.
	---@return string? why
	local function findCandidates(entry, data)
		local place = entry.start
		local x, y, map = place.x, place.y, place.map
		if not x or not y or not map then
			return nil, "no position was seen at the start (the game gives none in instances)"
		end
		local starts, swap = findStarts(x, y, map, data)
		if #starts == 0 then
			return nil, format("no taxi node with a path within %d yards of where it started", START_YARDS)
		end
		local landing = entry.landing
		local ends = {} ---@type GossipNearNode[]
		if landing and landing.x and landing.y and landing.map then
			ends = nodesNear(data, swap and landing.y or landing.x, swap and landing.x or landing.y, landing.map, END_YARDS)
		end
		local seconds = entry.duration
		local candidates = {} ---@type GossipCandidate[]
		local lib = data.lib
		for _, from in ipairs(starts) do
			local destinations = ends ---@type GossipNode[]
			if #destinations == 0 then
				destinations = {}
				for to in pairs(data.paths[from.id]) do
					destinations[#destinations + 1] = { id = to }
				end
			end
			for _, to in ipairs(destinations) do
				if to.id ~= from.id and data.paths[from.id][to.id] then
					local ok, info = pcall(lib.GetFlightInfoFromNodes, { { nodeID = from.id }, { nodeID = to.id } }, nil, 1, nil, entry.faction)
					if ok and info then
						candidates[#candidates + 1] = {
							from = from.id,
							to = to.id,
							estimate = info.duration,
							error = seconds and info.duration - seconds or 0,
							startYards = from.yards,
							endYards = to.yards,
						}
					end
				end
			end
		end
		table.sort(candidates, function(a, b)
			if seconds and abs(a.error) ~= abs(b.error) then
				return abs(a.error) < abs(b.error)
			end
			return a.startYards + (a.endYards or 0) < b.startYards + (b.endYards or 0)
		end)
		return candidates
	end

	-- the option that was most likely the one: the last choice before the flight
	---@param entry GossipFlightRecord
	---@return GossipChoiceRecord?
	local function lastChoice(entry)
		return type(entry.choices) == "table" and entry.choices[#entry.choices] or nil
	end

	---@param entry GossipFlightRecord
	---@return string
	local function describeOptions(entry)
		local names = {} ---@type string[]
		for _, option in ipairs(entry.options or {}) do
			names[#names + 1] = format("%s [%s]", option.name or "?", tostring(option.id or "secret"))
		end
		return #names > 0 and table.concat(names, "; ") or "none seen"
	end

	return function(entries, loadData, getClient)
		if #entries == 0 then
			return
		end
		printf("\n%d gossip flight%s (a gossip option put the player on a flight we have nothing for)\n", #entries, #entries == 1 and "" or "s")
		for index, entry in ipairs(entries) do
			local data, err = loadData(getClient(entry))
			printf("\n%d. %s%s, %s%s\n", index, os.date("!%Y-%m-%d %H:%M", entry.time) or "?", entry.faction and (" " .. entry.faction) or "",
				entry.npcName or "unknown npc", entry.npcID and format(" (%s %d)", tostring(entry.npcType), entry.npcID) or "")
			printf("   options in the window: %s\n", describeOptions(entry))
			local choice = lastChoice(entry)
			if choice then
				printf("   last choice %s sec before: %s [%s], index %s\n", tostring(choice.ago), choice.name or "?", tostring(choice.id or "secret"), tostring(choice.index))
			end
			if entry.duration then
				printf("   flew for %.1f sec\n", entry.duration)
			else
				print("   no landing was seen (logged out, or it is still the flight in progress)")
			end
			if not data then
				warn("   no taxi data: %s", tostring(err))
			else
				local candidates, why = findCandidates(entry, data)
				if not candidates then
					printf("   cannot tell: %s\n", tostring(why))
				elseif #candidates == 0 then
					print("   no path between the taxi nodes close to where it started and ended")
				else
					local first, second = candidates[1], candidates[2]
					local likely = entry.duration and abs(first.error) <= CLOSE_SECONDS and (not second or abs(second.error) - abs(first.error) >= APART_SECONDS)
					for i = 1, math.min(MAX_SHOWN, #candidates) do
						local c = candidates[i]
						printf("   %s %s (%d) > %s (%d): %.1f sec%s, %.0f yd from the start%s\n", i == 1 and likely and "likely" or "      ", data.nodeName(c.from), c.from, data.nodeName(c.to), c.to,
							c.estimate, entry.duration and format(" (%+.1f)", c.error) or "", c.startYards, c.endYards and format(", %.0f yd from the end", c.endYards) or "")
					end
					if #candidates > MAX_SHOWN then
						printf("   and %d more\n", #candidates - MAX_SHOWN)
					end
					if likely and choice and choice.id then
						printf("   to add to GossipToFlight: [%d] = { <taxi map>, %d, <taxi map>, %d }, -- %s > %s\n", choice.id, first.from, first.to, data.nodeName(first.from), data.nodeName(first.to))
					end
				end
			end
		end
	end
end
