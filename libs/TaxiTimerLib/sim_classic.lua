local MAJOR, MINOR = "TaxiTimerLib-1.0", 1
local lib = LibStub(MAJOR, true)
if not lib then return end

local sim = {} ---@class TaxiTimerLib-1.0_Sim

-- What the flights of this game were measured to do, on top of what the taxi data says. Each game has a file like this of its own, as the flights of one do not have to fly like those of another.
-- The speeds are the round numbers the game appears to use, what is flown is slightly faster (40 is flown at 40.33).
-- Record flights and run `scripts/analyze.lua` to see what to add, change or remove here. It reads these tables, so they need to keep their names and layout.

-- The game the `sim_` file that was loaded is for.
sim.FLAVOR = lib.FLAVOR.classic

-- If the stretch where the path arriving at a taxi node and the path leaving it run alongside each other is skipped when flying past the node (like Ironforge between Kharanos and Menethil Harbor).
sim.SKIP_RETRACED = false

-- The speed of each taxi map. The taxi maps not listed fly at 30.
sim.AREA_SPEEDS = {
}

-- How much longer (or shorter) than the points say the flights of a taxi map are, for the maps where the game gives no positions (instances) to tell that from.
-- The yards of the flight are multiplied by it, so the flights take as long as the recorded ones. The taxi maps not listed are flown as far as the points say.
sim.AREA_DISTANCE_SCALE = {
}

-- Taxi nodes where the game flies into the node and back out when passing through it, whole paths, however much the paths in and out run alongside each other (see `SKIP_RETRACED`).
sim.RETRACE_EXCEPTIONS = {
}

-- How the game flies past a taxi node where it was seen to do it another way than the rules of the simulation give.
-- `[node] = { [from] = { [to] = { last, first } } }` when flying from the taxi node `from` past `node` to the taxi node `to`:
-- `last` is the last point that is flown of the path arriving at `node`, and `first` the first point that is flown of the path leaving it.
sim.NODE_JOINS = {
}

-- Spells that make the flight path mount fly faster or slower, the speeds of the flight are multiplied by `multiplier` for a player that knows the spell (so it is not part of the speeds below).
-- The addon checks if the spell is known as the flight is estimated, and the flight records the multiplier it used.
sim.SPEED_MODIFIERS = {
}

-- Taxi nodes whose mount flies at another speed than the others of the taxi map. The whole flight is flown at that speed when it starts at the node, also the hops after the first.
-- Paths in `PATH_SPEEDS` and the speeds of `AREA_RAMPS` and `AREA_SPACING` still have their own speeds.
sim.NODE_SPEEDS = {
}

-- If a speed that was set by a path carries on into the next path (the flight does not go back to the speed of the taxi map as a path begins).
sim.CARRY_SPEED = false

-- Taxi maps where the stopwatch keeps the estimate and is not adjusted while we fly.
sim.AREA_FIXED_TIME = {
}

-- Taxi maps where flights speed up after taking off and slow down before landing.
-- The takeoff speeds are flown from the first points of the flight, one per point. The landing speeds are flown from the last points before the destination, one per point, the last being the point before the destination.
-- Paths in `PATH_SPEEDS` have their own speeds and do not use these.
---@type table<number, TaxiTimerLib-1.0_TaxiAreaRamp>
sim.AREA_RAMPS = {
}

-- Taxi maps where the flight is slower the closer the points are to each other, as `{ yards, speed }` in rising order: a stretch between two points shorter than the yards is flown at the speed.
-- This is what fits the recorded flights best, the game does not tell us why it flies slower there.
-- Stretches with a speed from `PATH_SPEEDS` or `AREA_RAMPS` do not use these.
sim.AREA_SPACING = {
}

-- Paths that change the flight speed as they pass their points, as `[pathId] = { [point index] = speed }`. The speed is flown from that point until a later point of the path changes it.
-- These speeds are not part of the client data, so they come from recorded flights. The first point of a path must have a speed.
sim.PATH_SPEEDS = {
}

---@diagnostic expect-next-line: deprecated
lib.SetSimulation(sim, MINOR)
