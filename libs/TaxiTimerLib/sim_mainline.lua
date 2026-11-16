local MAJOR, MINOR = "TaxiTimerLib-1.0", 1
local lib = LibStub(MAJOR, true)
if not lib then return end

local sim = {} ---@class TaxiTimerLib-1.0_Sim

-- What the flights of this game were measured to do, on top of what the taxi data says. Each game has a file like this of its own, as the flights of one do not have to fly like those of another.
-- The speeds are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
-- Record flights and run `scripts/analyze.lua` to see what to add, change or remove here. It reads these tables, so they need to keep their names and layout.

-- The game the `sim_` file that was loaded is for.
sim.FLAVOR = "mainline"

-- If the stretch where the path arriving at a taxi node and the path leaving it run alongside each other is skipped when flying past the node (like Ironforge between Kharanos and Menethil Harbor).
sim.SKIP_RETRACED = true

-- The speed of each taxi map. The taxi maps not listed fly at 30.
sim.AREA_SPEEDS = {
	[993] = 50, -- Broken Isles
	[1011] = 40, -- Zandalar
	[1014] = 40, -- Kul Tiras
	[1504] = 50, -- Nazjatar
	[1647] = 40, -- Shadowlands
	[1922] = 50, -- Draenor
	[2046] = 50, -- Zereth Mortis
	[2057] = 50, -- Dragon Isles
	[2175] = 40, -- Zaralek Cavern
	[2241] = 50, -- Emerald Dream
	[2276] = 50, -- Khaz Algar
	[2374] = 50, -- Undermine
	[2401] = 50, -- Founder's Point
	[2402] = 50, -- Razorwind Shores
}

-- Taxi nodes where the game flies into the node and back out when passing through it, whole paths, however much the paths in and out run alongside each other (see `SKIP_RETRACED`).
sim.RETRACE_EXCEPTIONS = {
	[303] = true, -- Valiance Landing Camp, Wintergrasp
	[984] = true, -- Pang's Stead, Valley of the Four Winds
}

-- How the game flies past a taxi node where it was seen to do it another way than the rules of the simulation give.
-- `[node] = { [from] = { [to] = { last, first } } }` when flying from the taxi node `from` past `node` to the taxi node `to`:
-- `last` is the last point that is flown of the path arriving at `node`, and `first` the first point that is flown of the path leaving it.
sim.NODE_JOINS = {
	[1382] = { -- Twilight Glade, Shadowmoon Valley
		[1509] = { [1467] = { 8, 1 } }, -- Talon Watch, Spires of Arak > The Draakorium, Shadowmoon Valley
	},
	[1506] = { -- Telaari Station, Nagrand
		[1503] = { [1573] = { 7, 7 } }, -- Throne of the Elements, Nagrand > Nivek's Overlook, Nagrand
	},
	[2904] = { -- Eye of Ysera, The Emerald Dream
		[2903] = { [2905] = { 11, 7 } }, -- Verdant Landing, The Emerald Dream > Wellspring Overlook, The Emerald Dream
	},
	[3076] = { -- Small Aerie, Founder's Point
		[3074] = { [3078] = { 6, 5 } }, -- Mear's Farm, Founder's Point > Brumewood Hollow, Founder's Point
		[3075] = { [3073] = { 6, 4 } }, -- The Outer Banks, Founder's Point > Town Center, Founder's Point
	},
	[3133] = { -- Fairbreeze Village, Eversong Woods
		[3134] = { [3131] = { 7, 6 } }, -- Tranquillien, Eversong Woods > Sanctum of Light, Silvermoon City
	},
	[3168] = { -- Tokka's Landing, The Coiled Isle
		[3131] = { [3288] = { 24, 5 } }, -- Sanctum of Light, Silvermoon City > Amani Foothold, Vaults of Atal'Utek
	},
}

-- Spells that make the flight path mount fly faster or slower, the speeds of the flight are multiplied by `multiplier` for a player that knows the spell (so it is not part of the speeds below).
-- The addon checks if the spell is known as the flight is estimated, and the flight records the multiplier it used.
sim.SPEED_MODIFIERS = {
}

-- Taxi nodes whose mount flies at another speed than the others of the taxi map. The whole flight is flown at that speed when it starts at the node, also the hops after the first.
-- Paths in `PATH_SPEEDS` and the speeds of `AREA_RAMPS` and `AREA_SPACING` still have their own speeds.
sim.NODE_SPEEDS = {
	[252] = 45, -- Wyrmrest Temple, Dragonblight
}

-- If a speed that was set by a path carries on into the next path (the flight does not go back to the speed of the taxi map as a path begins).
sim.CARRY_SPEED = false

-- Taxi maps where the stopwatch keeps the estimate and is not adjusted while we fly.
sim.AREA_FIXED_TIME = {
	[2276] = true, -- Khaz Algar
}

-- Taxi maps where flights speed up after taking off and slow down before landing.
-- The takeoff speeds are flown from the first points of the flight, one per point. The landing speeds are flown from the last points before the destination, one per point, the last being the point before the destination.
-- Paths in `PATH_SPEEDS` have their own speeds and do not use these.
---@type table<number, TaxiTimerLib-1.0_TaxiAreaRamp>
sim.AREA_RAMPS = {
	[993] = { takeoff = { 15, 30, 40 }, landing = {} }, -- Broken Isles
	[1011] = { takeoff = { 25, 25 }, landing = { 25, 15 } }, -- Zandalar
	[1014] = { takeoff = { 25, 25 }, landing = { 25, 15 } }, -- Kul Tiras
	[1647] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Shadowlands
	[1922] = { takeoff = { 30, 30, 40 }, landing = { 40, 30 } }, -- Draenor
	[2046] = { takeoff = { 25, 30, 40 }, landing = { 40, 30, 25 } }, -- Zereth Mortis
	[2175] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Zaralek Cavern
}

-- Taxi maps where the flight is slower the closer the points are to each other, as `{ yards, speed }` in rising order: a stretch between two points shorter than the yards is flown at the speed.
-- This is what fits the recorded flights best, the game does not tell us why it flies slower there.
-- Stretches with a speed from `PATH_SPEEDS` or `AREA_RAMPS` do not use these.
sim.AREA_SPACING = {
	[993] = { { 60, 15 }, { 100, 30 }, { 130, 40 } }, -- Broken Isles
	[1922] = { { 80, 20 } }, -- Draenor
	[2175] = { { 80, 15 }, { 100, 35 } }, -- Zaralek Cavern
}

-- Paths that change the flight speed as they pass their points, as `[pathId] = { [point index] = speed }`. The speed is flown from that point until a later point of the path changes it.
-- These speeds are not part of the client data, so they come from recorded flights. The first point of a path must have a speed.
sim.PATH_SPEEDS = {
	[7916] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [6] = 100, [7] = 300, [13] = 100, [16] = 65, [17] = 40, [18] = 30 }, -- Oribos > Pridefall Hamlet, Revendreth
	[7917] = { [1] = 15, [2] = 25, [3] = 40, [4] = 65, [5] = 100, [6] = 300, [11] = 100, [12] = 65, [13] = 40, [14] = 25 }, -- Pridefall Hamlet, Revendreth > Oribos
	[8012] = { [1] = 15, [2] = 30, [3] = 50, [7] = 300, [13] = 100, [16] = 65, [17] = 40, [18] = 25 }, -- Aspirant's Rest, Bastion > Oribos
	[8013] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [6] = 100, [8] = 300, [14] = 100, [17] = 65, [18] = 40, [19] = 25 }, -- Oribos > Aspirant's Rest, Bastion
	[8318] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [6] = 100, [7] = 300, [14] = 100, [15] = 65, [16] = 55, [17] = 50, [20] = 45, [21] = 40, [23] = 25 }, -- Oribos > Theater of Pain, Maldraxxus
	[8319] = { [1] = 15, [2] = 25, [3] = 40, [4] = 50, [8] = 65, [10] = 300, [17] = 100, [18] = 65, [20] = 40, [21] = 25 }, -- Theater of Pain, Maldraxxus > Oribos
	[8431] = { [1] = 15, [2] = 25, [4] = 40, [5] = 65, [7] = 100, [8] = 300, [10] = 250, [11] = 200, [12] = 100, [14] = 40, [22] = 25 }, -- Oribos > Tirna Vaal, Ardenweald
	[8432] = { [1] = 10, [2] = 25, [3] = 40, [11] = 65, [13] = 100, [14] = 300, [16] = 250, [17] = 200, [18] = 100, [20] = 65, [22] = 40, [23] = 25 }, -- Tirna Vaal, Ardenweald > Oribos
	[8557] = { [1] = 25, [2] = 35, [3] = 45, [4] = 70, [5] = 100, [8] = 300, [15] = 155, [16] = 60, [17] = 40, [18] = 25 }, -- Oribos > Tazavesh, the Veiled Market
	[8558] = { [1] = 25, [2] = 50, [4] = 300, [11] = 100, [13] = 65, [14] = 50, [15] = 45, [16] = 25 }, -- Tazavesh, the Veiled Market > Oribos
	[9382] = { [1] = 25 }, -- Old Loamm Road, Ohn'ahran Plains > Old Loamm Road, Zaralek Cavern
	[9751] = { [1] = 20, [2] = 40, [3] = 50, [16] = 45, [17] = 40, [18] = 50, [19] = 40, [24] = 25 }, -- Gundargaz, The Ringing Deeps > Dornogal, Isle of Dorn
	[9761] = { [1] = 45, [4] = 40, [5] = 30, [6] = 65, [7] = 100, [9] = 65, [10] = 45, [15] = 55, [16] = 35, [21] = 30 }, -- Dornogal, Isle of Dorn > Gundargaz, The Ringing Deeps
}

---@diagnostic disable-next-line: deprecated
lib.SetSimulation(sim, MINOR)
