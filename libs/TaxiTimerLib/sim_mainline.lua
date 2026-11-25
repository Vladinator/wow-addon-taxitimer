local MAJOR, MINOR = "TaxiTimerLib-1.0", 1
local lib = LibStub(MAJOR, true)
if not lib then return end

local sim = {} ---@class TaxiTimerLib-1.0_Sim

-- What the flights of this game were measured to do, on top of what the taxi data says. Each game has a file like this of its own, as the flights of one do not have to fly like those of another.
-- The speeds are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
-- Record flights and run `scripts/analyze.lua` to see what to add, change or remove here. It reads these tables, so they need to keep their names and layout.

-- The game the `sim_` file that was loaded is for.
sim.FLAVOR = lib.FLAVOR.mainline

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
	[2055] = 50, -- Sepulcher of the First Ones (a raid, there are no positions)
	[2057] = 50, -- Dragon Isles
	[2149] = 25, -- The Nokhud Offensive
	[2175] = 40, -- Zaralek Cavern
	[2241] = 50, -- Emerald Dream
	[2276] = 50, -- Khaz Algar
	[2374] = 50, -- Undermine
	[2401] = 50, -- Founder's Point
	[2402] = 50, -- Razorwind Shores
	[2479] = 50, -- Voidstorm
	[2480] = 50, -- Harandar
}

-- How much longer (or shorter) than the points say the flights of a taxi map are, for the maps where the game gives no positions (instances) to tell that from.
-- The yards of the flight are multiplied by it, so the flights take as long as the recorded ones. The taxi maps not listed are flown as far as the points say.
sim.AREA_DISTANCE_SCALE = {
	[2149] = 1.041, -- The Nokhud Offensive
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
	[61] = { -- Splintertree Post, Ashenvale
		[354] = { [166] = { 17, 5 } }, -- The Mor'Shan Ramparts, Ashenvale > Emerald Sanctuary, Felwood
	},
	[597] = { -- Irontree Clearing, Felwood
		[594] = { [69] = { 9, 6 } }, -- Whisperwind Grove, Felwood > Moonglade
	},
	[1382] = { -- Twilight Glade, Shadowmoon Valley
		[1509] = { [1467] = { 8, 1 } }, -- Talon Watch, Spires of Arak > The Draakorium, Shadowmoon Valley
	},
	[1447] = { -- Fort Wrynn (Alliance), Talador
		[1448] = { [1645] = { 5, 5 } }, -- Redemption Rise, Talador > The Iron Front, Tanaan Jungle
	},
	[1506] = { -- Telaari Station, Nagrand
		[1503] = { [1573] = { 7, 7 } }, -- Throne of the Elements, Nagrand > Nivek's Overlook, Nagrand
	},
	[1858] = { -- Meredil, Suramar
		[1615] = { [1879] = { 13, 6 } }, -- Challiane's Terrace, Azsuna > Crimson Thicket, Suramar
		[1879] = { [1615] = { 7, 1 } }, -- Crimson Thicket, Suramar > Challiane's Terrace, Azsuna
	},
	[1859] = { -- Felblaze Ingress, Azsuna
		[1774] = { [1615] = { 13, 5 } }, -- Dalaran > Challiane's Terrace, Azsuna
	},
	[1879] = { -- Crimson Thicket, Suramar
		[1858] = { [1863] = { 8, 4 } }, -- Meredil, Suramar > Hafr Fjall, Stormheim
		[1863] = { [1858] = { 6, 5 } }, -- Hafr Fjall, Stormheim > Meredil, Suramar
	},
	[2058] = { -- Staghelm Point, Silithus
		[386] = { [653] = { 14, 5 } }, -- Mossy Pile, Un'Goro Crater > Oasis of Vir'sar, Uldum
		[653] = { [41] = { 17, 4 }, [386] = { 17, 4 } }, -- Oasis of Vir'sar, Uldum > Feathermoon, Feralas; Mossy Pile, Un'Goro Crater
	},
	[2076] = { -- Atal'Gral, Zuldazar
		[2147] = { [2126] = { 4, 4 } }, -- Castaway Encampment, Zuldazar > Scaletrader Post, Zuldazar
	},
	[2080] = { -- Grimwatt's Crash, Nazmir
		[2145] = { [2112] = { 9, 6 } }, -- Verdant Hollow, Zuldazar > Vulture's Nest, Vol'dun
	},
	[2137] = { -- Millstone Hamlet, Stormsong Valley
		[2102] = { [2138] = { 2, 6 } }, -- Roughneck Camp, Tiragarde Sound > Fort Daelin, Stormsong Valley
	},
	[2792] = { -- Maruukai, Ohn'ahran Plains
		[2795] = { [2799] = { 10, 3 } }, -- Broadhoof Outpost, Ohn'ahran Plains > Rusza'thar Reach, Ohn'ahran Plains
	},
	[2904] = { -- Eye of Ysera, The Emerald Dream
		[2903] = { [2905] = { 11, 7 } }, -- Verdant Landing, The Emerald Dream > Wellspring Overlook, The Emerald Dream
	},
	[2979] = { -- The Common, Razorwind Shores
		[2980] = { [2972] = { 4, 5 } }, -- The Bloom, Razorwind Shores > Entrance Gate, Razorwind Shores
	},
	[2980] = { -- The Bloom, Razorwind Shores
		[2973] = { [2978] = { 5, 3 } }, -- Saltfang Shoals East, Razorwind Shores > Cragthorn Highlands, Razorwind Shores
		[2976] = { [2979] = { 4, 3 } }, -- The Bluffs, Razorwind Shores > The Common, Razorwind Shores
		[2979] = { [2976] = { 4, 3 } }, -- The Common, Razorwind Shores > The Bluffs, Razorwind Shores
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

-- Where the bar shows a taxi node that is flown past, where it was seen to be another place than the last point that is flown of the path arriving (which `NODE_JOINS` and the rules above give), as it is where the route divides to cut the corner there.
-- `[node] = { [from] = { [to] = point } }` when flying from the taxi node `from` past `node` to the taxi node `to`: `point` is the last point of the path arriving at `node` that the taxi node is shown at.
-- `[node] = { [from] = point }` is for every taxi node it goes on to, where the flights to more than one of them show the same place (the route divides in one place on the way, which all of them fly).
-- This only moves where the taxi node is on the timeline, how long the flight takes is the same.
sim.NODE_STOPS = {
	[1745] = { -- Lorna's Watch, Stormheim
		[1863] = { [1759] = 7 }, -- Hafr Fjall, Stormheim > Ironhorn Enclave, Highmountain
	},
	[2034] = { -- Hangman's Point, Drustvar
		[2035] = { [2033] = 4 }, -- Fletcher's Hollow, Drustvar > Fallhaven, Drustvar
	},
	[2060] = { -- Hatherford, Tiragarde Sound
		[2083] = { [2084] = 4 }, -- Tradewinds Market, Tiragarde Sound > Norwington Estate, Tiragarde Sound
	},
	[2084] = { -- Norwington Estate, Tiragarde Sound
		[2060] = { [2102] = 10 }, -- Hatherford, Tiragarde Sound > Roughneck Camp, Tiragarde Sound
	},
	[2112] = { -- Vulture's Nest, Vol'dun
		[2120] = { [2110] = 7 }, -- Tortaka Refuge, Vol'dun > Shatterstone Harbor, Vol'dun
	},
}

-- Where the stop of a taxi node that is flown past was seen to still be possible to ask for, later than the last point that is flown of the path arriving (which `NODE_JOINS` and `NODE_STOPS` give), as the flight cuts the corner there.
-- `[node] = { [from] = { [to] = seconds } }`, or `[node] = { [from] = seconds }` for all of the taxi nodes it goes on to, when flying from the taxi node `from` past `node` to the taxi node `to`.
-- The seconds are added to when the bar shows the taxi node, never past landing there. This only moves the taxi node on the timeline, how long the flight takes is the same.
sim.NODE_STOP_OFFSETS = {
}

-- Spells that make the flight path mount fly faster or slower, the speeds of the flight are multiplied by `multiplier` for a player that knows the spell (so it is not part of the speeds below).
-- The addon checks if the spell is known as the flight is estimated, and the flight records the multiplier it used.
sim.SPEED_MODIFIERS = {
}

-- Taxi nodes whose mount flies at another speed than the others of the taxi map. The whole flight is flown at that speed when it starts at the node, also the hops after the first.
-- Paths in `PATH_SPEEDS` and the speeds of `AREA_RAMPS` and `AREA_SPACING` still have their own speeds.
sim.NODE_SPEEDS = {
	[252] = 45, -- Wyrmrest Temple, Dragonblight
	[653] = 20, -- Oasis of Vir'sar, Uldum
	[2137] = 50, -- Millstone Hamlet, Stormsong Valley
	[2442] = 50, -- Overspark Expedition Camp, Mechagon
}

-- Taxi maps where a speed that was set by a path carries on into the next path (the flight does not go back to the speed of the taxi map as a path begins, a slow part of a path goes on past the taxi node).
sim.AREA_CARRY = {
	[2276] = true, -- Khaz Algar
}

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
	[2276] = { takeoff = { 30 }, landing = {} }, -- Khaz Algar
	[2479] = { takeoff = { 20 }, landing = {} },
	[2480] = { takeoff = { 35, 35 }, landing = { 35 } },
}

-- Taxi maps where the flight is slower the closer the points are to each other, as `{ yards, speed }` in rising order: a stretch between two points shorter than the yards is flown at the speed.
-- This is what fits the recorded flights best, the game does not tell us why it flies slower there.
-- Stretches with a speed from `PATH_SPEEDS` or `AREA_RAMPS` do not use these.
sim.AREA_SPACING = {
	[993] = { { 60, 15 }, { 100, 30 }, { 130, 40 } }, -- Broken Isles
	[1922] = { { 100, 40 } }, -- Draenor
	[2175] = { { 80, 15 }, { 100, 35 } }, -- Zaralek Cavern
}

-- Paths that change the flight speed as they pass their points, as `[pathId] = { [point index] = speed }`. The speed is flown from that point until a later point of the path changes it.
-- These speeds are not part of the client data, so they come from recorded flights. The first point of a path must have a speed.
sim.PATH_SPEEDS = {
	[4225] = { [1] = 30, [3] = 40, [6] = 45, [8] = 40 }, -- Fort Wrynn (Alliance), Talador > Zangarra, Talador
	[4542] = { [7] = 40 }, -- Apexis Excavation, Spires of Arak > Exarch's Refuge, Talador
	[5111] = { [8] = 35 }, -- Malo's Lookout, Tanaan Jungle > Aktar's Post, Tanaan Jungle
	[5982] = { [1] = 50 }, -- Meredil, Suramar > Crimson Thicket, Suramar
	[6124] = { [8] = 40, [9] = 30, [10] = 50, [11] = 20, [12] = 50 }, -- Dalaran > Deliverance Point, Broken Shore
	[6466] = { [1] = 25, [3] = 40, [6] = 30, [8] = 15, [9] = 10 }, -- Barbthorn Ridge, Drustvar > Fallhaven, Drustvar
	[6683] = { [1] = 15, [2] = 25, [3] = 40, [6] = 25 }, -- Watchman's Rise, Drustvar > Whitegrove Chapel, Drustvar
	[6688] = { [1] = 15, [2] = 25, [3] = 40, [12] = 25 }, -- Arom's Stand, Drustvar > Fletcher's Hollow, Drustvar
	[6876] = { [1] = 10, [2] = 15, [3] = 25, [4] = 35, [5] = 40, [10] = 35, [11] = 25, [12] = 15 }, -- Tortaka Refuge, Vol'dun > Vulture's Nest, Vol'dun
	[6932] = { [1] = 20, [3] = 30, [4] = 40, [19] = 25, [20] = 15 }, -- Millstone Hamlet, Stormsong Valley > Roughneck Camp, Tiragarde Sound
	[6943] = { [1] = 40, [6] = 25 }, -- Atal'Gral, Zuldazar > Castaway Encampment, Zuldazar
	[7290] = { [1] = 10, [2] = 15, [3] = 25, [4] = 35, [5] = 40, [9] = 50, [11] = 25 }, -- Tortaka Refuge, Vol'dun > Redfield's Watch, Nazmir
	[7646] = { [1] = 50 }, -- Overspark Expedition Camp, Mechagon > Millstone Hamlet, Stormsong Valley
	[7744] = { [1] = 25, [2] = 35, [3] = 50, [8] = 35 }, -- Overspark Expedition Camp, Mechagon > Whitegrove Chapel, Drustvar
	[7745] = { [1] = 15, [2] = 25, [3] = 40, [7] = 25, [8] = 15 }, -- Whitegrove Chapel, Drustvar > Overspark Expedition Camp, Mechagon
	[7746] = { [1] = 50 }, -- Seekers Vista, Stormsong Valley > Overspark Expedition Camp, Mechagon
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
	[8655] = { [1] = 30, [2] = 40, [4] = 50, [10] = 40, [11] = 35 }, -- Pilgrim's Grace, Zereth Mortis > Haven, Zereth Mortis
	[8673] = { [1] = 30, [2] = 40, [3] = 50, [4] = 40 }, -- Antecedent Isle, Zereth Mortis > Zovaal's Grasp, Zereth Mortis
	[8674] = { [1] = 30, [2] = 40, [3] = 50, [4] = 40 }, -- Zovaal's Grasp, Zereth Mortis > Antecedent Isle, Zereth Mortis
	[8684] = { [1] = 50, [3] = 40 }, -- Sepulcher Of The First Ones, Zereth Mortis > Sepulcher Overlook, Zereth Mortis
	[9376] = { [3] = 40, [7] = 25 }, -- Old Loamm Road, Zaralek Cavern > Dragonscale Camp, Zaralek Cavern
	[9382] = { [1] = 25 }, -- Old Loamm Road, Ohn'ahran Plains > Old Loamm Road, Zaralek Cavern
	[9591] = { [10] = 30, [11] = 20 }, -- Faerin's Advance, Azj-Kahet > Weaver's Lair, Azj-Kahet
	[9751] = { [16] = 45, [17] = 40, [18] = 50 }, -- Gundargaz, The Ringing Deeps > Dornogal, Isle of Dorn
	[9761] = { [1] = 45, [4] = 40, [5] = 30, [6] = 65, [7] = 100, [9] = 65, [10] = 45, [15] = 55, [16] = 35, [21] = 30 }, -- Dornogal, Isle of Dorn > Gundargaz, The Ringing Deeps
	[11186] = { [1] = 30, [3] = 45, [4] = 50, [8] = 45, [9] = 30 }, -- The Den, Harandar > Har'athir, Harandar
}

-- The speeds a path is flown at when the flight takes off on it or lands on it, as `[pathId] = { takeoff = { speed of each point }, landing = { speed of each point } }`. They are the speeds of `AREA_RAMPS` for the path: the ramps of the taxi map are not used at the end of the flight where the path has its own.
-- A flight that passes through a taxi node does not take off or land there, it keeps its speed, so these are only used where the flight begins or ends. `PATH_SPEEDS` are used wherever the path is flown.
-- These speeds are not part of the client data, so they come from recorded flights.
---@type table<number, TaxiTimerLib-1.0_PathRamp>
sim.PATH_RAMPS = {
	[4542] = { takeoff = { 30, 30, 40, 40 } }, -- Apexis Excavation, Spires of Arak > Exarch's Refuge, Talador
	[4543] = { takeoff = { 15, 30, 40 } }, -- Stormshield (Alliance), Ashran > Wildwood Wash, Gorgrond
	[4787] = { takeoff = { 15, 25, 40, 40, 40 } }, -- Stormshield (Alliance), Ashran > Shattrath City, Talador
	[5052] = { takeoff = { 15, 30, 40 }, landing = { 40, 30, 25 } }, -- The Iron Front, Tanaan Jungle > Aktar's Post, Tanaan Jungle
	[5054] = { takeoff = { 15, 30, 40 }, landing = { 40, 30, 25 } }, -- Aktar's Post, Tanaan Jungle > Vault of the Earth, Tanaan Jungle
	[5062] = { takeoff = { 15, 25, 30, 40 }, landing = { 40, 30 } }, -- The Iron Front, Tanaan Jungle > Lion's Watch, Tanaan Jungle
	[5063] = { takeoff = { 15, 25, 30, 40 }, landing = { 40, 30 } }, -- Vault of the Earth, Tanaan Jungle > The Iron Front, Tanaan Jungle
	[5064] = { takeoff = { 15, 25, 30, 40 }, landing = { 40, 30 } }, -- Aktar's Post, Tanaan Jungle > The Iron Front, Tanaan Jungle
	[5065] = { takeoff = { 15, 25, 30, 40 }, landing = { 40, 30 } }, -- Vault of the Earth, Tanaan Jungle > Lion's Watch, Tanaan Jungle
	[5079] = { takeoff = { 15, 30, 40 }, landing = { 40, 30 } }, -- Bastion Rise, Gorgrond > The Iron Front, Tanaan Jungle
	[5111] = { takeoff = { 15, 35, 40 } }, -- Malo's Lookout, Tanaan Jungle > Aktar's Post, Tanaan Jungle
	[5119] = { takeoff = { 15, 30, 40 }, landing = { 45, 40, 30 } }, -- Vault of the Earth, Tanaan Jungle > Malo's Lookout, Tanaan Jungle
	[5400] = { takeoff = { 15, 30, 40 }, landing = { 40, 20 } }, -- Ironhorn Enclave, Highmountain > Obsidian Overlook, Highmountain
	[5843] = { takeoff = { 15, 30, 40 }, landing = { 30, 20 } }, -- Dalaran > Hafr Fjall, Stormheim
	[5857] = { takeoff = { 10, 15, 20, 30, 40 }, landing = { 40, 40, 40, 40, 40, 30 } }, -- Meredil, Suramar > Dalaran
	[6124] = { takeoff = { 15, 30, 40 } }, -- Dalaran > Deliverance Point, Broken Shore
	[6126] = { takeoff = { 30, 30, 40 }, landing = { 40, 30 } }, -- Deliverance Point, Broken Shore > Aalgen Point, Broken Shore
	[6675] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Arom's Stand, Drustvar > Watchman's Rise, Drustvar
	[6677] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Watchman's Rise, Drustvar > Arom's Stand, Drustvar
	[6690] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Falconhurst, Drustvar > Arom's Stand, Drustvar
	[6763] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Whitegrove Chapel, Drustvar > Anyport, Drustvar
	[6767] = { takeoff = { 15, 25 }, landing = { 25 } }, -- Scaletrader Post, Zuldazar > Nesingwary's Gameland, Zuldazar
	[6836] = { takeoff = { 20, 20, 30 }, landing = { 25, 15 } }, -- Brennadam, Stormsong Valley > The Amber Waves, Stormsong Valley
	[6840] = { takeoff = { 15, 15, 25 }, landing = { 25, 15 } }, -- Tidecross, Stormsong Valley > Mildenhall Meadery, Stormsong Valley
	[6842] = { takeoff = { 15, 15, 20, 30 }, landing = { 25, 15 } }, -- Tidecross, Stormsong Valley > Brennadam, Stormsong Valley
	[6843] = { takeoff = { 15, 15, 25, 30 }, landing = { 25, 15 } }, -- Brennadam, Stormsong Valley > Tidecross, Stormsong Valley
	[6860] = { takeoff = { 20, 20, 30 }, landing = { 25, 15 } }, -- Fort Daelin, Stormsong Valley > Seekers Vista, Stormsong Valley
	[6861] = { takeoff = { 15, 15, 20, 30 }, landing = { 25, 15 } }, -- Tidecross, Stormsong Valley > Seekers Vista, Stormsong Valley
	[6880] = { takeoff = { 15, 15, 25, 35 }, landing = { 35, 25, 15 } }, -- Vulture's Nest, Vol'dun > Shatterstone Harbor, Vol'dun
	[6883] = { takeoff = { 15, 15, 25, 35 }, landing = { 35, 25, 15 } }, -- Shatterstone Harbor, Vol'dun > Sanctuary of the Devoted, Vol'dun
	[6942] = { takeoff = { 25, 25 }, landing = { 25 } }, -- Castaway Encampment, Zuldazar > Atal'Gral, Zuldazar
	[6945] = { takeoff = { 25, 25 }, landing = { 25 } }, -- Seeker's Outpost, Zuldazar > Castaway Encampment, Zuldazar
	[7073] = { takeoff = { 25, 25 }, landing = { 25 } }, -- Fletcher's Hollow, Drustvar > Vigil Hill, Tiragarde Sound
	[9353] = { takeoff = { 25, 25 }, landing = { 25 } }, -- Dragonscale Camp, Zaralek Cavern > Loamm, Zaralek Cavern
	[9590] = { takeoff = { 20, 25, 40 }, landing = { 30 } }, -- Weaver's Lair, Azj-Kahet > Faerin's Advance, Azj-Kahet
	[9591] = { takeoff = { 30, 30, 40 } }, -- Faerin's Advance, Azj-Kahet > Weaver's Lair, Azj-Kahet
	[9673] = { takeoff = { 20, 35 } }, -- Dunelle's Kindness, Hallowfall > Hillhelm Family Farm, Hallowfall
	[9751] = { takeoff = { 20, 40 }, landing = { 40, 40, 40, 40, 40, 25 } }, -- Gundargaz, The Ringing Deeps > Dornogal, Isle of Dorn
	[11198] = { takeoff = { 30, 30, 40 }, landing = { 40, 30 } }, -- The Den, Harandar > Har'mara, Harandar
	[11199] = { takeoff = { 30, 30, 30, 40 }, landing = { 40, 30 } }, -- Har'mara, Harandar > Har'kuai, Harandar
	[11200] = { takeoff = { 30, 30, 40 }, landing = { 40, 30 } }, -- Har'kuai, Harandar > Har'mara, Harandar
}

---@diagnostic expect-next-line: deprecated
lib.SetSimulation(sim, MINOR)
