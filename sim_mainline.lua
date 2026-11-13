local ns = select(2, ...) ---@class taxi_ns_db

ns = ns or {}

-- What the flights of this game were measured to do, on top of what the taxi data says. Each game has a file like this of its own, as the flights of one do not have to fly like those of another.
-- The speeds are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
-- Record flights and run `scripts/analyze.php` to see what to add, change or remove here. It reads these tables, so they need to keep their names and layout.

ns.FLAVOR = "mainline"

-- If the stretch where the path arriving at a taxi node and the path leaving it run alongside each other is skipped when flying past the node (like Ironforge between Kharanos and Menethil Harbor).
ns.SKIP_RETRACED = true

-- The speed of each taxi map. The taxi maps not listed fly at 30.
ns.AREA_SPEEDS = {
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
}

-- Taxi maps where flights speed up after taking off and slow down before landing.
-- The takeoff speeds are flown from the first points of the flight, one per point. The landing speeds are flown from the last points before the destination, one per point, the last being the point before the destination.
-- Paths in `PATH_SPEEDS` have their own speeds and do not use these.
ns.AREA_RAMPS = {
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
ns.AREA_SPACING = {
	[993] = { { 60, 15 }, { 100, 30 }, { 130, 40 } }, -- Broken Isles
	[1922] = { { 80, 20 } }, -- Draenor
}

-- Paths that change the flight speed as they pass their points, as `[pathId] = { [point index] = speed }`. The speed is flown from that point until a later point of the path changes it.
-- These speeds are not part of the client data, so they come from recorded flights. The first point of a path must have a speed.
ns.PATH_SPEEDS = {
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
	[9751] = { [1] = 20, [2] = 40, [3] = 50, [16] = 45, [17] = 40, [18] = 50, [19] = 40, [24] = 25 }, -- Gundargaz, The Ringing Deeps > Dornogal, Isle of Dorn
	[9761] = { [1] = 45, [4] = 40, [5] = 30, [6] = 65, [7] = 100, [9] = 65, [10] = 45, [15] = 55, [16] = 35, [21] = 30 }, -- Dornogal, Isle of Dorn > Gundargaz, The Ringing Deeps
}
