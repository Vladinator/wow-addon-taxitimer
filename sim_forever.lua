local ns = select(2, ...) ---@class taxi_ns_db

ns = ns or {}

-- What the flights of this game were measured to do, on top of what the taxi data says. Each game has a file like this of its own, as the flights of one do not have to fly like those of another.
-- The speeds are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
-- Record flights and run `scripts/analyze.lua` to see what to add, change or remove here. It reads these tables, so they need to keep their names and layout.

-- The game the `sim_` file that was loaded is for.
ns.FLAVOR = "forever"

-- If the stretch where the path arriving at a taxi node and the path leaving it run alongside each other is skipped when flying past the node (like Ironforge between Kharanos and Menethil Harbor).
ns.SKIP_RETRACED = false

-- The speed of each taxi map. The taxi maps not listed fly at 30.
ns.AREA_SPEEDS = {
}

-- Taxi maps where the stopwatch keeps the estimate and is not adjusted while we fly.
ns.AREA_FIXED_TIME = {
}

-- Taxi maps where flights speed up after taking off and slow down before landing.
-- The takeoff speeds are flown from the first points of the flight, one per point. The landing speeds are flown from the last points before the destination, one per point, the last being the point before the destination.
-- Paths in `PATH_SPEEDS` have their own speeds and do not use these.
ns.AREA_RAMPS = {
}

-- Taxi maps where the flight is slower the closer the points are to each other, as `{ yards, speed }` in rising order: a stretch between two points shorter than the yards is flown at the speed.
-- This is what fits the recorded flights best, the game does not tell us why it flies slower there.
-- Stretches with a speed from `PATH_SPEEDS` or `AREA_RAMPS` do not use these.
ns.AREA_SPACING = {
}

-- Paths that change the flight speed as they pass their points, as `[pathId] = { [point index] = speed }`. The speed is flown from that point until a later point of the path changes it.
-- These speeds are not part of the client data, so they come from recorded flights. The first point of a path must have a speed.
ns.PATH_SPEEDS = {
}
