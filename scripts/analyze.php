<?php
/*

Compares the flights recorded by the addon against the taxi data, to show where the estimates are off and why.

To record flights set `RECORD_FLIGHTS = true` at the top of `core.lua`, fly, then log out or reload so the saved variables are written.

After the summary of the flights it lists the lines to add, change or remove in `core.lua` for its speeds to match what was flown.
For this it reads the `TAXI_SPEED_` constants, the speed table of the taxi maps, `AREA_RAMPS`, `AREA_SPACING` and `PATH_SPEEDS` out of `core.lua`, so these need to keep their names and layout.
The speeds of a taxi map come first (its speed, how it takes off and lands, and if it flies slower where the points are close to each other), a path only gets its own speeds if it is still off by a few seconds with those.
Some paths change the flight speed as they pass their points. These speeds are not part of the client files, so recorded flights are the only source for them.

Usage:

	php scripts/analyze.php <WTF/Account/.../SavedVariables/TaxiTimer.lua> [options]

Options:

	--flight=N      show the details of flight N (as numbered in the summary), can be repeated
	--all           show the details of every flight
	--speeds        show the speed each path was flown at from each of its points, as lines for the PATH_SPEEDS table in core.lua
	--core=FILE     the core.lua to suggest changes to (default is the one of this addon)
	--no-suggest    do not show the suggested changes to core.lua
	--client=NAME   use the csv files of this client (mainline, classic or vanilla) instead of what the flight was recorded on
	--near=YARDS    how close we have to pass a point for it to count as flown (default 25)
	--far=YARDS     how far from a point we have to stay for it to count as not flown (default 60)

*/

ini_set('memory_limit', '-1');

// reads the tables of a saved variables file
class LuaReader {

	private $src;
	private $pos = 0;
	private $len;

	public function __construct($src) {
		$this->src = $src;
		$this->len = strlen($src);
	}

	// returns the global variables assigned in the file
	public function ReadGlobals() {
		$globals = array();
		while (true) {
			$this->SkipSpace();
			if ($this->pos >= $this->len)
				break;
			if (!preg_match('/\G([A-Za-z_][A-Za-z0-9_]*)\s*=/A', $this->src, $m, 0, $this->pos))
				$this->Fail("expected a variable");
			$this->pos += strlen($m[0]);
			$globals[$m[1]] = $this->ReadValue();
		}
		return $globals;
	}

	private function Fail($message) {
		$line = substr_count($this->src, "\n", 0, $this->pos) + 1;
		throw new Exception(sprintf("%s on line %d", $message, $line));
	}

	private function SkipSpace() {
		while ($this->pos < $this->len) {
			$c = $this->src[$this->pos];
			if ($c === " " || $c === "\t" || $c === "\r" || $c === "\n") {
				$this->pos++;
			} elseif ($c === "-" && substr($this->src, $this->pos, 2) === "--") {
				$end = strpos($this->src, "\n", $this->pos);
				$this->pos = $end === false ? $this->len : $end;
			} else {
				break;
			}
		}
	}

	private function ReadValue() {
		$this->SkipSpace();
		if ($this->pos >= $this->len)
			$this->Fail("unexpected end of file");
		$c = $this->src[$this->pos];
		if ($c === "{")
			return $this->ReadTable();
		if ($c === "\"" || $c === "'")
			return $this->ReadString($c);
		if (preg_match('/\G-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?)/A', $this->src, $m, 0, $this->pos)) {
			$this->pos += strlen($m[0]);
			return stripos($m[0], "x") !== false ? hexdec($m[0]) : $m[0] + 0;
		}
		if (preg_match('/\G-?[A-Za-z_][A-Za-z0-9_()]*/A', $this->src, $m, 0, $this->pos)) {
			$this->pos += strlen($m[0]);
			$word = strtolower($m[0]);
			if ($word === "true") return true;
			if ($word === "false") return false;
			if ($word === "nil") return null;
			if ($word === "inf" || $word === "math.huge") return INF;
			if ($word === "-inf") return -INF;
			if (strpos($word, "nan") !== false) return NAN;
		}
		$this->Fail("unexpected value");
	}

	private function ReadString($quote) {
		$this->pos++;
		$out = "";
		while ($this->pos < $this->len) {
			$c = $this->src[$this->pos++];
			if ($c === $quote)
				return $out;
			if ($c === "\\" && $this->pos < $this->len) {
				$e = $this->src[$this->pos++];
				if ($e === "n") $out .= "\n";
				elseif ($e === "r") $out .= "\r";
				elseif ($e === "t") $out .= "\t";
				elseif (ctype_digit($e)) {
					$digits = $e;
					while (strlen($digits) < 3 && $this->pos < $this->len && ctype_digit($this->src[$this->pos]))
						$digits .= $this->src[$this->pos++];
					$out .= chr(intval($digits));
				} else $out .= $e;
			} else {
				$out .= $c;
			}
		}
		$this->Fail("unfinished string");
	}

	private function ReadTable() {
		$this->pos++;
		$table = array();
		$index = 0;
		while (true) {
			$this->SkipSpace();
			if ($this->pos >= $this->len)
				$this->Fail("unfinished table");
			$c = $this->src[$this->pos];
			if ($c === "}") {
				$this->pos++;
				return $table;
			}
			if ($c === "," || $c === ";") {
				$this->pos++;
				continue;
			}
			if ($c === "[") {
				$this->pos++;
				$key = $this->ReadValue();
				$this->SkipSpace();
				if ($this->src[$this->pos] !== "]") $this->Fail("expected ]");
				$this->pos++;
				$this->SkipSpace();
				if ($this->src[$this->pos] !== "=") $this->Fail("expected =");
				$this->pos++;
				$table[is_float($key) && $key == floor($key) ? intval($key) : $key] = $this->ReadValue();
			} elseif (preg_match('/\G([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)/A', $this->src, $m, 0, $this->pos)) {
				$this->pos += strlen($m[0]);
				$table[$m[1]] = $this->ReadValue();
			} else {
				$table[++$index] = $this->ReadValue();
			}
		}
	}

}

// the taxi data of a client
class TaxiData {

	public $client;
	public $nodes = array(); // [id] = array(name, x, y, z, map)
	public $paths = array(); // [from][to] = path id (the first path between two nodes, like the addon)
	public $points = array(); // [id] = array(x, y, z, map, flags, delay, path, index)
	public $pathPoints = array(); // [path id] = point ids in flight order

	private static $cache = array();

	public static function Get($client) {
		if (!isset(self::$cache[$client]))
			self::$cache[$client] = new TaxiData($client);
		return self::$cache[$client];
	}

	private function __construct($client) {
		$this->client = $client;
		$dir = __DIR__ . "/csv_" . $client;
		if (!is_dir($dir))
			throw new Exception(sprintf("no csv files for the %s client in %s", $client, $dir));
		foreach ($this->ReadCsv($dir, "taxinodes") as $r)
			$this->nodes[intval($r["ID"])] = array($r["Name_lang"], floatval($r["Pos_0"]), floatval($r["Pos_1"]), floatval($r["Pos_2"]), intval($r["ContinentID"]));
		foreach ($this->ReadCsv($dir, "taxipath") as $r) {
			$from = intval($r["FromTaxiNode"]);
			$to = intval($r["ToTaxiNode"]);
			if (!isset($this->paths[$from][$to]))
				$this->paths[$from][$to] = intval($r["ID"]);
		}
		foreach ($this->ReadCsv($dir, "taxipathnode") as $r) {
			$id = intval($r["ID"]);
			$path = intval($r["PathID"]);
			$this->points[$id] = array(floatval($r["Loc_0"]), floatval($r["Loc_1"]), floatval($r["Loc_2"]), intval($r["ContinentID"]), intval($r["Flags"]), intval($r["Delay"]), $path, intval($r["NodeIndex"]));
			$this->pathPoints[$path][] = $id;
		}
		foreach ($this->pathPoints as $path => &$ids) {
			usort($ids, function($a, $b) { return $this->points[$a][7] <=> $this->points[$b][7] ?: $a <=> $b; });
		}
	}

	private function ReadCsv($dir, $name) {
		$rows = array();
		foreach (glob($dir . "/*.csv") as $file) {
			if (mb_strtolower(pathinfo($file, PATHINFO_FILENAME)) !== $name)
				continue;
			$fh = fopen($file, "r");
			$headers = fgetcsv($fh, null, ",", "\"", "");
			while (($row = fgetcsv($fh, null, ",", "\"", "")) !== false)
				if (count($row) === count($headers))
					$rows[] = array_combine($headers, $row);
			fclose($fh);
		}
		if (!count($rows))
			throw new Exception(sprintf("no %s.csv rows found in %s", $name, $dir));
		return $rows;
	}

	public function NodeName($id) {
		return isset($this->nodes[$id]) ? $this->nodes[$id][0] : "node " . $id;
	}

}

// the analysis of a single recorded flight
class FlightAnalysis {

	const TELEPORT = 0x1;
	const STOP = 0x2;

	public $index;
	public $record;
	public $data;
	public $near;
	public $far;
	public $warnings = array();
	public $incomplete = null; // why the flight does not compare to its estimate, if it doesn't

	public $track = array(); // array(t, x, y, map, speed, timer, remaining, point) per sample, x and y matching the taxi data
	public $steps = array(); // array(dt, yards 2D, speed, kind) between each sample and the one before it, kind is "move", "still" or "jump"

	public $start; // seconds since clicked we took off
	public $end; // seconds since clicked we landed
	public $uncertainty; // seconds the actual time can be off by
	public $actual;
	public $estimate;
	public $hasOverride = false;

	private $pathSpeeds = null;
	private $intervals = array();

	public $moveTime = 0;
	public $stillTime = 0;
	public $jumpTime = 0;
	public $jumps = 0;
	public $travelled2D = 0;
	public $travelled = 0; // yards flown going by the speed the game reported

	public function __construct($index, $record, $data, $near, $far) {
		$this->index = $index;
		$this->record = $record;
		$this->data = $data;
		$this->near = $near;
		$this->far = $far;
		$this->BuildTrack();
		$this->BuildTimes();
		$this->CheckComplete();
	}

	private function BuildTrack() {
		$r = $this->record;
		$swap = !empty($r["swapAxis"]);
		foreach ($r["samples"] ?? array() as $s) {
			$x = $swap ? $s[3] : $s[2];
			$y = $swap ? $s[2] : $s[3];
			$this->track[] = array($s[1], $x, $y, $s[5], $s[6], $s[7], $s[8], $s[9]);
		}
		$scale = !empty($r["distance2D"]) ? $r["distance"] / $r["distance2D"] : 1;
		for ($i = 1; $i < count($this->track); $i++) {
			$a = $this->track[$i - 1];
			$b = $this->track[$i];
			$dt = $b[0] - $a[0];
			$d = $a[3] === $b[3] ? hypot($b[1] - $a[1], $b[2] - $a[2]) : INF;
			$speed = $b[4];
			$expected = max($speed, $a[4], 30) * $dt;
			if ($d > max(60, $expected * 3)) {
				$kind = "jump"; // changed map or moved further than we could have flown
				$d = 0;
				$this->jumps++;
				$this->jumpTime += $dt;
			} elseif ($d < 1 && $speed < 1) {
				$kind = "still";
				$this->stillTime += $dt;
			} else {
				$kind = "move";
				if ($speed < 1 && $dt > 0)
					$speed = $d * $scale / $dt; // the game didn't tell us the speed so we go by how far we moved
				$this->moveTime += $dt;
				$this->travelled2D += $d;
				$this->travelled += $speed * $dt;
			}
			$this->steps[$i] = array($dt, $d, $speed, $kind);
		}
		foreach ($r["segments"] ?? array() as $segment)
			if (!empty($segment["override"]))
				$this->hasOverride = true;
		// make sure our position and the taxi data agree on what is x and what is y
		if (count($this->track)) {
			$direct = 0;
			$swapped = 0;
			foreach (array(0, intdiv(count($this->track), 2), count($this->track) - 1) as $i) {
				$s = $this->track[$i];
				$direct += $this->NearestRoutePoint($s[1], $s[2], $s[3]);
				$swapped += $this->NearestRoutePoint($s[2], $s[1], $s[3]);
			}
			if ($swapped < $direct)
				$this->warnings[] = "the positions fit the points better with x and y swapped, the addon got the axis order wrong for this flight";
		}
	}

	private function NearestRoutePoint($x, $y, $map) {
		$best = INF;
		foreach ($this->record["points"] ?? array() as $id) {
			if (!isset($this->data->points[$id])) continue;
			$p = $this->data->points[$id];
			if ($p[3] !== $map) continue;
			$best = min($best, hypot($p[0] - $x, $p[1] - $y));
		}
		return $best === INF ? 100000 : $best;
	}

	private function BuildTimes() {
		$r = $this->record;
		$first = $r["firstTaxi"] ?? 0;
		$last = $r["lastTaxi"] ?? $first;
		$ground = $r["lastGround"] ?? $first;
		$landed = $r["landed"] ?? $last;
		$this->start = ($ground + $first) / 2;
		$this->end = ($last + $landed) / 2;
		$this->uncertainty = (($first - $ground) + ($landed - $last)) / 2;
		$this->actual = $this->end - $this->start;
		$this->estimate = $r["estimate"] ?? 0;
	}

	// flights that did not go all the way to the destination must not be compared to the estimate
	private function CheckComplete() {
		$r = $this->record;
		$points = $r["points"] ?? array();
		$count = count($this->track);
		// asking to land early ends the flight at the next taxi node, which on the last hop is the destination, so we go by where the flight ended
		$early = isset($r["early"]) ? sprintf("asked to land early %.0f sec into the flight", $r["early"] - $this->start) : null;
		if ($count < 2) {
			$this->incomplete = "not enough samples";
		} elseif (isset($this->data->points[$points[count($points)] ?? 0])) {
			$p = $this->data->points[$points[count($points)]];
			$last = $this->track[$count - 1];
			$distance = $p[3] === $last[3] ? hypot($p[0] - $last[1], $p[1] - $last[2]) : INF;
			if ($distance > max($this->far, 100))
				$this->incomplete = ($early ? $early . " and " : "") . ($distance === INF ? "ended on another map than the destination" : sprintf("ended %.0f yd from the destination", $distance));
			elseif ($early)
				$this->warnings[] = $early . " but it was on the last hop so the flight still went to the destination";
		} elseif ($early) {
			$this->incomplete = $early;
		}
		// the game not responding for a while (loading, lag) leaves a hole in what we saw
		$gap = 0;
		for ($i = 1; $i < $count; $i++)
			$gap = max($gap, $this->track[$i][0] - $this->track[$i - 1][0]);
		if ($gap > 2)
			$this->warnings[] = sprintf("nothing was recorded for %.1f sec at one point during the flight (loading screen or the game not responding), the speed and distance around it are less reliable", $gap);
	}

	// seconds the flight took longer (positive) or shorter (negative) than estimated
	public function Error() {
		return $this->actual - $this->estimate;
	}

	// splits the error up by what caused it, each in seconds the flight took longer (positive) or shorter (negative) than estimated
	public function ErrorSplit() {
		$r = $this->record;
		$delay = !empty($r["delayIncluded"]) ? ($r["delay"] ?? 0) : 0;
		$speed = $r["speed"] ?? 0;
		if ($speed <= 0)
			return null;
		$split = array(
			"distance" => ($this->travelled - $r["distance"]) / $speed, // we flew further or shorter than estimated
			"speed" => $this->moveTime - $this->travelled / $speed, // we flew slower or faster than estimated
			"standing still" => $this->stillTime - $delay,
			"teleports" => $this->jumpTime,
		);
		$split["take off and landing"] = $this->Error() - array_sum($split);
		return $split;
	}

	public function RouteName() {
		return implode(" > ", array_map(function($id) { return $this->data->NodeName($id); }, $this->record["route"] ?? array()));
	}

	// the speed we flew at for most of the flight, outside of the segments that have their own speed
	public function TypicalSpeed() {
		$weights = array();
		$segments = $this->record["segments"] ?? array();
		foreach ($this->steps as $i => $step) {
			if ($step[3] !== "move") continue;
			$point = $this->track[$i][7];
			foreach ($segments as $segment)
				if (!empty($segment["override"]) && $point >= $segment["first"] && $point <= $segment["last"])
					continue 2;
			$key = strval(round($step[2], 2));
			$weights[$key] = ($weights[$key] ?? 0) + $step[0];
		}
		return self::WeightedMedian($weights);
	}

	public static function WeightedMedian($weights) {
		if (!count($weights))
			return null;
		ksort($weights, SORT_NUMERIC);
		$half = array_sum($weights) / 2;
		$sum = 0;
		foreach ($weights as $value => $weight) {
			$sum += $weight;
			if ($sum >= $half)
				return floatval($value);
		}
		return null;
	}

	// distance from a position to where we flew
	private function DistanceToTrack($x, $y, $map) {
		$best = INF;
		$count = count($this->track);
		for ($i = 0; $i < $count; $i++) {
			$b = $this->track[$i];
			if ($b[3] !== $map) continue;
			$best = min($best, hypot($b[1] - $x, $b[2] - $y));
			if ($i === 0 || $this->steps[$i][3] === "jump") continue;
			$a = $this->track[$i - 1];
			$dx = $b[1] - $a[1];
			$dy = $b[2] - $a[2];
			$len = $dx * $dx + $dy * $dy;
			if ($len <= 0) continue;
			$t = max(0, min(1, (($x - $a[1]) * $dx + ($y - $a[2]) * $dy) / $len));
			$best = min($best, hypot($a[1] + $dx * $t - $x, $a[2] + $dy * $t - $y));
		}
		return $best;
	}

	private function DescribePoint($id) {
		if (!isset($this->data->points[$id]))
			return sprintf("point %d (not in the csv files)", $id);
		$p = $this->data->points[$id];
		$count = count($this->data->pathPoints[$p[6]]);
		$text = sprintf("path %d point %d of %d", $p[6], $p[7] + 1, $count);
		if ($p[4]) $text .= sprintf(", flags %d", $p[4]);
		if ($p[5]) $text .= sprintf(", delay %d", $p[5]);
		return $text;
	}

	private static function Clock($seconds) {
		$sign = $seconds < 0 ? "-" : "";
		$seconds = abs($seconds);
		return sprintf("%s%d:%04.1f", $sign, floor($seconds / 60), fmod($seconds, 60));
	}

	private static function Signed($seconds) {
		return sprintf("%+.1f", $seconds);
	}

	// the points of a curve through the given positions, the same curve the addon measures the distance of
	// returns the points as array(x, y, z) and the index among them of each of the given positions
	private static function Curve($positions) {
		$curve = array();
		$starts = array();
		$count = count($positions);
		$knot = function($t, $a, $b) { return $t + pow(sqrt(pow($b[0] - $a[0], 2) + pow($b[1] - $a[1], 2) + pow($b[2] - $a[2], 2)), 0.5); };
		$mirror = function($a, $b) { return array(2 * $a[0] - $b[0], 2 * $a[1] - $b[1], 2 * $a[2] - $b[2]); };
		$mix = function($a, $b, $wa, $wb) { return array($wa * $a[0] + $wb * $b[0], $wa * $a[1] + $wb * $b[1], $wa * $a[2] + $wb * $b[2]); };
		for ($i = 0; $i < $count - 1; $i++) {
			$p1 = $positions[$i];
			$p2 = $positions[$i + 1];
			$p0 = $i > 0 ? $positions[$i - 1] : $mirror($p1, $p2);
			$p3 = $i + 2 < $count ? $positions[$i + 2] : $mirror($p2, $p1);
			$starts[$i] = count($curve);
			$t0 = 0;
			$t1 = $knot($t0, $p0, $p1);
			$t2 = $knot($t1, $p1, $p2);
			$t3 = $knot($t2, $p2, $p3);
			if ($t1 == $t0 || $t2 == $t1 || $t3 == $t2) {
				$curve[] = $p1;
				continue;
			}
			for ($j = 0; $j < 9; $j++) {
				$t = $t1 + ($t2 - $t1) * $j / 9;
				$a1 = $mix($p0, $p1, ($t1 - $t) / ($t1 - $t0), ($t - $t0) / ($t1 - $t0));
				$a2 = $mix($p1, $p2, ($t2 - $t) / ($t2 - $t1), ($t - $t1) / ($t2 - $t1));
				$a3 = $mix($p2, $p3, ($t3 - $t) / ($t3 - $t2), ($t - $t2) / ($t3 - $t2));
				$b1 = $mix($a1, $a2, ($t2 - $t) / ($t2 - $t0), ($t - $t0) / ($t2 - $t0));
				$b2 = $mix($a2, $a3, ($t3 - $t) / ($t3 - $t1), ($t - $t1) / ($t3 - $t1));
				$curve[] = $mix($b1, $b2, ($t2 - $t) / ($t2 - $t1), ($t - $t1) / ($t2 - $t1));
			}
		}
		if ($count) {
			$starts[$count - 1] = count($curve);
			$curve[] = $positions[$count - 1];
		}
		return array($curve, $starts);
	}

	// the speed the game reported rounded to the speed it appears to be set to (40 is flown at 40.33)
	public static function RoundSpeed($speed) {
		return intval(round($speed / ((40 + 1 / 3) / 40) / 5) * 5);
	}

	// the speed flown from each point where the speed changed, as array([path id] = array("speeds" => array([point index] = speed), "first" => point index, "last" => point index, "unsure" => array(point index, ...), "time" => seconds flown, "distance" => yards flown))
	// the game changes the speed as it passes a point, so where we were when the speed changed tells us which point it was
	// the points split up where the flight does not fly from one point to the next (teleports and map changes), as array("first" => index in the points, "last" => index in the points)
	// older records also split the points up where a path had a made up distance and speed, so this does not go by the segments of the record
	private function FlownSegments() {
		$points = $this->record["points"] ?? array();
		$segments = array();
		$previous = null;
		foreach ($points as $i => $id) {
			$p = $this->data->points[$id] ?? null;
			if (!$p)
				return $this->record["segments"] ?? array();
			if ($previous === null || $previous[3] !== $p[3] || ($previous[4] & self::TELEPORT))
				$segments[] = array("first" => $i, "last" => $i);
			else
				$segments[count($segments) - 1]["last"] = $i;
			$previous = $p;
		}
		return $segments;
	}

	// the stretches between the points in the order they were flown, as array(path id, point index, yards, speed flown or null if we did not see it, position in the flight starting at 0, stretches in the flight)
	public function Intervals() {
		$this->PathSpeeds();
		$intervals = $this->intervals;
		foreach ($intervals as $position => $interval) {
			$intervals[$position][4] = $position;
			$intervals[$position][5] = count($intervals);
		}
		return $intervals;
	}

	public function PathSpeeds() {
		if ($this->pathSpeeds !== null)
			return $this->pathSpeeds;
		$d = $this->data;
		$points = $this->record["points"] ?? array();
		$paths = array();
		$this->intervals = array();
		foreach ($this->FlownSegments() as $segment) {
			$ids = array();
			$positions = array();
			for ($i = $segment["first"]; $i <= $segment["last"]; $i++) {
				$p = $d->points[$points[$i] ?? 0] ?? null;
				if (!$p)
					continue 2;
				if (count($positions) && $positions[count($positions) - 1] === array($p[0], $p[1], $p[2]))
					continue;
				$ids[] = $points[$i];
				$positions[] = array($p[0], $p[1], $p[2]);
			}
			if (count($positions) < 2)
				continue;
			list($curve, $starts) = self::Curve($positions);
			$along = array(0);
			for ($i = 1; $i < count($curve); $i++)
				$along[$i] = $along[$i - 1] + sqrt(pow($curve[$i][0] - $curve[$i - 1][0], 2) + pow($curve[$i][1] - $curve[$i - 1][1], 2) + pow($curve[$i][2] - $curve[$i - 1][2], 2));
			// how far along the curve we were each time we looked
			$seen = array();
			$at = 0;
			foreach ($this->track as $s) {
				if ($s[7] < $segment["first"] || $s[7] > $segment["last"] || $s[3] !== $d->points[$ids[0]][3])
					continue;
				$best = null;
				for ($k = $at; $k < min(count($curve) - 1, $at + 40); $k++) {
					$dx = $curve[$k + 1][0] - $curve[$k][0];
					$dy = $curve[$k + 1][1] - $curve[$k][1];
					$len = $dx * $dx + $dy * $dy;
					$t = $len > 0 ? max(0, min(1, (($s[1] - $curve[$k][0]) * $dx + ($s[2] - $curve[$k][1]) * $dy) / $len)) : 0;
					$distance = hypot($curve[$k][0] + $dx * $t - $s[1], $curve[$k][1] + $dy * $t - $s[2]);
					if ($best === null || $distance < $best[0] - 0.000001)
						$best = array($distance, $k, $t);
				}
				if ($best === null)
					continue;
				$at = $best[1];
				if ($s[4] >= 1)
					$seen[] = array($s[0], $along[$at] + ($along[$at + 1] - $along[$at]) * $best[2], $s[4]);
			}
			// the speed each stretch between two points was flown at for most of it
			foreach ($ids as $index => $id) {
				if (!isset($ids[$index + 1]))
					break;
				$from = $along[$starts[$index]];
				$to = $along[$starts[$index + 1]];
				$flown = array();
				foreach ($seen as $look)
					if ($look[1] >= $from && $look[1] < $to)
						$flown[] = $look[2];
				sort($flown);
				$this->intervals[] = array($d->points[$id][6], $d->points[$id][7] + 1, $to - $from, count($flown) ? self::RoundSpeed($flown[intdiv(count($flown), 2)]) : null);
			}
			if (!count($seen))
				continue;
			// the speed when first seen is what the first point set, each change after it is what the point we passed between two looks set
			$changes = array(array(0, self::RoundSpeed($seen[0][2]), false));
			$speed = $seen[0][2];
			for ($i = 1; $i < count($seen); $i++) {
				$a = $seen[$i - 1];
				$b = $seen[$i];
				if (abs($b[2] - $speed) <= 1.5)
					continue;
				$dt = $b[0] - $a[0];
				$where = $a[1] + $a[2] * max(0, min($dt, $a[2] != $b[2] ? (($b[1] - $a[1]) - $b[2] * $dt) / ($a[2] - $b[2]) : $dt / 2));
				$between = array();
				$nearest = null;
				foreach ($starts as $index => $k) {
					if ($along[$k] >= $a[1] - 12 && $along[$k] <= $b[1] + 12)
						$between[] = $index;
					if ($nearest === null || abs($along[$k] - $where) < abs($along[$starts[$nearest]] - $where))
						$nearest = $index;
				}
				$changes[] = array(count($between) === 1 ? $between[0] : $nearest, self::RoundSpeed($b[2]), count($between) !== 1);
				$speed = $b[2];
			}
			foreach ($ids as $index => $id) {
				$p = $d->points[$id];
				if (!isset($paths[$p[6]])) {
					$paths[$p[6]] = array("speeds" => array(), "first" => $p[7] + 1, "last" => $p[7] + 1, "unsure" => array(), "time" => 0, "distance" => 0);
					// the first point of a path we fly is flown at the speed set before we got to it
					foreach ($changes as $change)
						if ($change[0] <= $index)
							$paths[$p[6]]["speeds"][$p[7] + 1] = $change[1];
				}
				$paths[$p[6]]["last"] = $p[7] + 1;
			}
			// the seconds and yards flown on each path
			for ($i = 1; $i < count($seen); $i++) {
				$index = 0;
				foreach ($starts as $point => $k)
					if ($along[$k] <= $seen[$i - 1][1])
						$index = $point;
				$path = $d->points[$ids[$index]][6];
				$paths[$path]["time"] += $seen[$i][0] - $seen[$i - 1][0];
				$paths[$path]["distance"] += $seen[$i][1] - $seen[$i - 1][1];
			}
			foreach ($changes as $change) {
				$p = $d->points[$ids[$change[0]]];
				$paths[$p[6]]["speeds"][$p[7] + 1] = $change[1];
				if ($change[2])
					$paths[$p[6]]["unsure"][] = $p[7] + 1;
			}
		}
		$this->pathSpeeds = $paths;
		return $paths;
	}

	public function Report() {
		$r = $this->record;
		$d = $this->data;
		$out = array();
		$out[] = sprintf("Flight %d: %s", $this->index, $this->RouteName());
		$out[] = sprintf("  recorded %s on %s build %s with addon %s, taxi map %s, %d samples", isset($r["time"]) ? gmdate("Y-m-d H:i", $r["time"]) . " UTC" : "?", $d->client, $r["build"] ?? "?", $r["addon"] ?? "?", $r["area"] ?? "?", count($this->track));
		if ($this->incomplete)
			$out[] = sprintf("  INCOMPLETE: %s, so the estimate does not apply and the flight is left out of the summary of its taxi map", $this->incomplete);
		foreach ($this->warnings as $warning)
			$out[] = "  WARNING: " . $warning;
		if (count($this->track) < 2) {
			$out[] = "  not enough samples to analyze";
			return implode("\n", $out);
		}

		// time
		$error = $this->Error();
		$out[] = "";
		$out[] = "  Time";
		$out[] = sprintf("    estimated %s, took %s (give or take %.1f sec), the flight was %.1f sec %s than estimated (%+.1f%%)", self::Clock($this->estimate), self::Clock($this->actual), $this->uncertainty, abs($error), $error < 0 ? "shorter" : "longer", $this->estimate > 0 ? $error / $this->estimate * 100 : 0);
		$split = $this->ErrorSplit();
		if ($split) {
			$parts = array();
			foreach ($split as $name => $seconds)
				$parts[] = sprintf("%s %s", $name, self::Signed($seconds));
			$out[] = "    seconds longer (+) or shorter (-) by cause: " . implode(", ", $parts);
			if ($this->hasOverride)
				$out[] = "    the route has a path with its own made up distance and speed, so distance and speed above can't be told apart for it";
		}
		if (!empty($r["delay"]))
			$out[] = sprintf("    the paths have %d sec of stops which were %s the estimate", $r["delay"], !empty($r["delayIncluded"]) ? "part of" : "not part of");

		// distance
		$out[] = "";
		$out[] = "  Distance";
		$out[] = sprintf("    estimated %.0f yd (%.0f yd seen from above), flew %.0f yd going by speed and %.0f yd seen from above going by position", $r["distance"], $r["distance2D"], $this->travelled, $this->travelled2D);
		foreach ($r["segments"] ?? array() as $i => $segment) {
			$flown = 0;
			$time = 0;
			foreach ($this->steps as $j => $step) {
				$point = $this->track[$j][7];
				if ($point < $segment["first"] || $point > $segment["last"]) continue;
				$flown += $step[1];
				$time += $step[0];
			}
			$text = sprintf("    segment %d (points %d to %d): estimated %.0f yd seen from above at %.1f yd/sec taking %.1f sec, flew %.0f yd seen from above in %.1f sec", $i, $segment["first"], $segment["last"], $segment["distance2D"], $segment["speed"], $segment["speed"] > 0 ? $segment["distance"] / $segment["speed"] : 0, $flown, $time);
			if (!empty($segment["override"]))
				$text .= " (made up distance and speed, only the time compares)";
			elseif ($segment["distance2D"] > 0)
				$text .= sprintf(" (%+.1f%%)", ($flown - $segment["distance2D"]) / $segment["distance2D"] * 100);
			$out[] = $text;
		}
		$first = $this->track[0];
		$last = $this->track[count($this->track) - 1];
		$route = $r["route"] ?? array();
		$from = $d->nodes[$route[1] ?? 0] ?? null;
		$to = $d->nodes[$route[count($route)] ?? 0] ?? null;
		$points = $r["points"] ?? array();
		$firstPoint = $d->points[$points[1] ?? 0] ?? null;
		$lastPoint = $d->points[$points[count($points)] ?? 0] ?? null;
		$text = array();
		if ($firstPoint) $text[] = sprintf("first seen %.0f yd from the first point", hypot($firstPoint[0] - $first[1], $firstPoint[1] - $first[2]));
		if ($from) $text[] = sprintf("%.0f yd from where the first taxi node is", hypot($from[1] - $first[1], $from[2] - $first[2]));
		if ($lastPoint) $text[] = sprintf("last seen %.0f yd from the last point", hypot($lastPoint[0] - $last[1], $lastPoint[1] - $last[2]));
		if ($to) $text[] = sprintf("%.0f yd from where the last taxi node is", hypot($to[1] - $last[1], $to[2] - $last[2]));
		if (count($text))
			$out[] = "    " . implode(", ", $text);
		if ($this->jumps)
			$out[] = sprintf("    jumped %d times (changed map or moved further than could be flown), taking %.1f sec", $this->jumps, $this->jumpTime);

		// points
		$out[] = "";
		$out[] = "  Points";
		$used = array();
		$missed = array();
		foreach ($points as $i => $id) {
			$used[$id] = true;
			if (!isset($d->points[$id])) {
				$missed[] = sprintf("      %s", $this->DescribePoint($id));
				continue;
			}
			$p = $d->points[$id];
			$distance = $this->DistanceToTrack($p[0], $p[1], $p[3]);
			if ($distance > $this->far)
				$missed[] = sprintf("      %d. %s: %s", $i, $this->DescribePoint($id), $distance === INF ? "never on its map" : sprintf("%.0f yd away", $distance));
		}
		$out[] = sprintf("    %d of the %d points the estimate was made from were not flown (further than %d yd away)%s", count($missed), count($points), $this->far, count($missed) ? ":" : "");
		$out = array_merge($out, $missed);
		$flown = array();
		$skipped = 0;
		for ($i = 1; $i < count($route); $i++) {
			$path = $d->paths[$route[$i] ?? 0][$route[$i + 1] ?? 0] ?? null;
			if ($path === null) {
				$out[] = sprintf("    no path from %s to %s in the csv files", $d->NodeName($route[$i]), $d->NodeName($route[$i + 1] ?? 0));
				continue;
			}
			foreach ($d->pathPoints[$path] ?? array() as $id) {
				if (isset($used[$id])) continue;
				$skipped++;
				$p = $d->points[$id];
				$distance = $this->DistanceToTrack($p[0], $p[1], $p[3]);
				if ($distance <= $this->near)
					$flown[] = sprintf("      %s: %.0f yd away", $this->DescribePoint($id), $distance);
			}
		}
		$out[] = sprintf("    %d of the %d points the estimate skipped were flown (within %d yd)%s", count($flown), $skipped, $this->near, count($flown) ? ":" : "");
		$out = array_merge($out, $flown);

		// speed
		$out[] = "";
		$out[] = "  Speed";
		$typical = $this->TypicalSpeed();
		$out[] = sprintf("    the estimate used %.2f yd/sec for the taxi map, the flight was mostly flown at %s yd/sec", $r["areaSpeed"] ?? 0, $typical === null ? "?" : sprintf("%.2f", $typical));
		$perPath = array();
		foreach ($this->steps as $i => $step) {
			if ($step[3] !== "move") continue;
			$id = $points[$this->track[$i][7]] ?? 0;
			$path = isset($d->points[$id]) ? $d->points[$id][6] : 0;
			if (!isset($perPath[$path]))
				$perPath[$path] = array(0, 0, INF, -INF, 0);
			$perPath[$path][0] += $step[0];
			$perPath[$path][1] += $step[2] * $step[0];
			$perPath[$path][2] = min($perPath[$path][2], $step[2]);
			$perPath[$path][3] = max($perPath[$path][3], $step[2]);
			$perPath[$path][4] += $step[1];
		}
		foreach ($perPath as $path => $p)
			$out[] = sprintf("    path %s: %.1f sec, %.0f yd seen from above, %.2f yd/sec on average (%.2f to %.2f)", $path ?: "?", $p[0], $p[4], $p[0] > 0 ? $p[1] / $p[0] : 0, $p[2], $p[3]);
		// the stretches flown at the same speed
		$stretches = array();
		$current = null;
		foreach ($this->steps as $i => $step) {
			$speed = $step[3] === "move" ? $step[2] : ($step[3] === "still" ? 0 : -1);
			if ($current !== null && abs($stretches[$current][2] - $speed) <= 1.5) {
				$stretches[$current][1] += $step[0];
				$stretches[$current][4] = $this->track[$i][7];
				$stretches[$current][5] += $step[2] * $step[0];
			} else {
				$stretches[] = array($this->track[$i - 1][0] - $this->start, $step[0], $speed, $this->track[$i][7], $this->track[$i][7], $step[2] * $step[0]);
				$current = count($stretches) - 1;
			}
		}
		$long = array_filter($stretches, function($s) { return $s[1] >= 1.5; });
		if (count($long) > 1 || count($stretches) > 3) {
			$out[] = sprintf("    the speed changed %d times, the stretches of 1.5 sec or longer:", count($stretches) - 1);
			$shown = 0;
			foreach ($long as $s) {
				if (++$shown > 40) {
					$out[] = sprintf("      and %d more", count($long) - 40);
					break;
				}
				$what = $s[2] < 0 ? "jumping" : ($s[2] == 0 ? "standing still" : sprintf("%.1f yd/sec", $s[1] > 0 ? $s[5] / $s[1] : $s[2]));
				$out[] = sprintf("      %s for %.1f sec: %s, from %s to %s", self::Clock($s[0]), $s[1], $what, $this->DescribePoint($points[$s[3]] ?? 0), $this->DescribePoint($points[$s[4]] ?? 0));
			}
		} else {
			$out[] = "    the speed stayed the same during the flight";
		}

		// stops
		$out[] = "";
		$out[] = "  Stops";
		$stills = array_values(array_filter($stretches, function($s) { return $s[2] == 0 && $s[1] >= 1; }));
		// the points that are stops, and how long we stood still at each (going by the stop nearest to where we stood still)
		$stops = array();
		foreach ($points as $i => $id) {
			$p = $d->points[$id] ?? null;
			if ($p && ($p[4] & self::STOP) && $p[5])
				$stops[$i] = 0;
		}
		foreach ($stills as $s) {
			$nearest = null;
			foreach ($stops as $i => $waited)
				if (abs($s[3] - $i) <= 2 && ($nearest === null || abs($s[3] - $i) < abs($s[3] - $nearest)))
					$nearest = $i;
			if ($nearest !== null)
				$stops[$nearest] += $s[1];
		}
		foreach ($stops as $i => $waited)
			$out[] = sprintf("    %d. %s: stood still for %.1f sec near it", $i, $this->DescribePoint($points[$i]), $waited);
		if (!count($stops))
			$out[] = "    none of the points the estimate was made from are stops";
		$out[] = sprintf("    stood still for %.1f sec in total%s", $this->stillTime, count($stills) ? ":" : "");
		foreach ($stills as $s)
			$out[] = sprintf("      %s for %.1f sec near %s", self::Clock($s[0]), $s[1], $this->DescribePoint($points[$s[3]] ?? 0));

		// stopwatch
		$out[] = "";
		$out[] = "  Stopwatch";
		$worst = 0;
		$resets = 0;
		$previous = null;
		foreach ($this->track as $i => $s) {
			if ($s[5] <= 0) continue;
			$left = $this->end - $s[0];
			$worst = max($worst, abs($s[5] - $left));
			if ($previous !== null && abs(($previous[5] - $s[5]) - ($s[0] - $previous[0])) > 1.5)
				$resets++;
			$previous = $s;
		}
		$out[] = sprintf("    the time shown was off by up to %.1f sec and was changed %d times during the flight", $worst, $resets);

		return implode("\n", $out);
	}

}

// ---------------------------------------------------------------------------------------------------------------------

$file = null;
$flights = array();
$all = false;
$speeds = false;
$suggest = true;
$coreFile = dirname(__DIR__) . DIRECTORY_SEPARATOR . "core.lua";
$client = null;
$near = 25;
$far = 60;

foreach (array_slice($argv, 1) as $arg) {
	if (preg_match('/^--flight=(\d+)$/', $arg, $m)) $flights[intval($m[1])] = true;
	elseif ($arg === "--all") $all = true;
	elseif ($arg === "--speeds") $speeds = true;
	elseif ($arg === "--no-suggest") $suggest = false;
	elseif (preg_match('/^--core=(.+)$/', $arg, $m)) $coreFile = $m[1];
	elseif (preg_match('/^--client=(\w+)$/', $arg, $m)) $client = $m[1];
	elseif (preg_match('/^--near=([\d.]+)$/', $arg, $m)) $near = floatval($m[1]);
	elseif (preg_match('/^--far=([\d.]+)$/', $arg, $m)) $far = floatval($m[1]);
	elseif ($file === null && substr($arg, 0, 2) !== "--") $file = $arg;
	else {
		fprintf(STDERR, "unknown option %s\n", $arg);
		exit(1);
	}
}

if ($file === null || !is_file($file)) {
	fprintf(STDERR, "usage: php %s <SavedVariables/TaxiTimer.lua> [--flight=N] [--all] [--speeds] [--core=FILE] [--no-suggest] [--client=mainline|classic|vanilla] [--near=25] [--far=60]\n", $argv[0]);
	exit(1);
}

try {
	$reader = new LuaReader(file_get_contents($file));
	$globals = $reader->ReadGlobals();
} catch (Exception $e) {
	fprintf(STDERR, "unable to read %s: %s\n", $file, $e->getMessage());
	exit(1);
}

$records = $globals["TaxiTimerDB"]["flights"] ?? array();

if (!is_array($records) || !count($records)) {
	fprintf(STDERR, "no flights in %s, set RECORD_FLIGHTS = true in core.lua and fly somewhere\n", $file);
	exit(1);
}

// the csv files to compare a flight against, going by the client it was recorded on (WOW_PROJECT_ID)
const SUGGEST_PATH_SECONDS = 5; // seconds a path must differ from the speed of its taxi map before it is suggested to have its own speeds

// reads the speeds the addon uses out of core.lua, so what was flown can be compared to them
function ReadCore($file) {
	$core = array("constants" => array(), "speeds" => array(), "ramps" => array(), "spacing" => array(), "paths" => array(), "default" => 30);
	$src = @file_get_contents($file);
	if ($src === false)
		return null;
	$block = function($start, $end) use ($src) {
		$a = strpos($src, $start);
		if ($a === false)
			return "";
		$b = strpos($src, $end, $a);
		return $b === false ? "" : substr($src, $a, $b - $a);
	};
	// local TAXI_SPEED_40 = 40+1/3
	preg_match_all('/local (TAXI_SPEED_\w+) = (\d+)(?:\s*\+\s*(\d+)\s*\/\s*(\d+))?\s*$/m', $src, $matches, PREG_SET_ORDER);
	foreach ($matches as $m)
		$core["constants"][$m[1]] = FlightAnalysis::RoundSpeed($m[2] + (isset($m[3]) ? $m[3] / $m[4] : 0));
	if (isset($core["constants"]["TAXI_SPEED_FALLBACK"]))
		$core["default"] = $core["constants"]["TAXI_SPEED_FALLBACK"];
	// [2057] = TAXI_SPEED_50, -- Dragon Isles
	preg_match_all('/\[(\d+)\]\s*=\s*(TAXI_SPEED_\w+)/', $block("local fallback = setmetatable({", "}, {"), $matches, PREG_SET_ORDER);
	foreach ($matches as $m)
		if (isset($core["constants"][$m[2]]))
			$core["speeds"][intval($m[1])] = $core["constants"][$m[2]];
	// [1647] = { takeoff = { 15, 25 }, landing = { 25 } },
	preg_match_all('/\[(\d+)\]\s*=\s*\{\s*takeoff\s*=\s*\{([^}]*)\}\s*,\s*landing\s*=\s*\{([^}]*)\}/', $block("local AREA_RAMPS = {", "\n\t\t}"), $matches, PREG_SET_ORDER);
	foreach ($matches as $m)
		$core["ramps"][intval($m[1])] = array(
			"takeoff" => array_map("intval", array_filter(array_map("trim", explode(",", $m[2])), "strlen")),
			"landing" => array_map("intval", array_filter(array_map("trim", explode(",", $m[3])), "strlen")),
		);
	// [993] = { { 60, 15 }, { 100, 30 } },
	preg_match_all('/^\s*\[(\d+)\]\s*=\s*\{((?:\s*\{\s*\d+\s*,\s*\d+\s*\}\s*,?)+)\s*\}/m', $block("local AREA_SPACING = {", "\n\t\t}"), $matches, PREG_SET_ORDER);
	foreach ($matches as $m) {
		preg_match_all('/\{\s*(\d+)\s*,\s*(\d+)\s*\}/', $m[2], $steps, PREG_SET_ORDER);
		foreach ($steps as $step)
			$core["spacing"][intval($m[1])][] = array(intval($step[1]), intval($step[2]));
	}
	// [7917] = { [1] = 15, [2] = 25 },
	preg_match_all('/^\s*\[(\d+)\]\s*=\s*\{((?:\s*\[\d+\]\s*=\s*\d+\s*,?)+)\s*\}/m', $block("local PATH_SPEEDS = {", "\n\t\t}"), $matches, PREG_SET_ORDER);
	foreach ($matches as $m) {
		preg_match_all('/\[(\d+)\]\s*=\s*(\d+)/', $m[2], $points, PREG_SET_ORDER);
		foreach ($points as $p)
			$core["paths"][intval($m[1])][intval($p[1])] = intval($p[2]);
	}
	return $core;
}

// the speed flown from each of the points first to last, given the speeds set at some of them
function SpreadSpeeds($speeds, $first, $last) {
	ksort($speeds);
	$spread = array();
	$speed = null;
	foreach ($speeds as $point => $value)
		if ($point <= $first)
			$speed = $value;
	for ($point = $first; $point <= $last; $point++) {
		if (isset($speeds[$point]))
			$speed = $speeds[$point];
		$spread[$point] = $speed;
	}
	return $spread;
}

function SpeedList($speeds) {
	return count($speeds) ? implode(", ", $speeds) : "none";
}

// the most seen of the lists of speeds, on a tie the one the addon has now wins and then the longest
function MostSeen($seen, $now) {
	$best = null;
	foreach ($seen as $key => $flights) {
		$key = strval($key); // a list of one speed became a number as an array key
		if ($best === null || count($flights) > count($seen[$best]) || (count($flights) === count($seen[$best]) && $best !== $now && ($key === $now || strlen($key) > strlen($best))))
			$best = $key;
	}
	return $best;
}

const SPACING_YARDS = array(30, 45, 60, 80, 100, 130, 170, 220, 300); // the lengths a stretch between two points is sorted by when looking for the speed it is flown at
const SPACING_MIN_FLIGHTS = 5; // flights needed on a taxi map before speeds by the length of the stretches are suggested for it
const SPACING_MIN_SECONDS = 1; // seconds the flights must get closer to their estimates on average before other speeds by length are suggested

// the seconds the addon would estimate for stretches of a flight
// $intervals are array(path, point, yards, speed flown, position in the flight, stretches in the flight), $model is array("cruise", "takeoff", "landing", "spacing" => array(array(yards, speed), ...), "paths" => array([path] = array([point] = speed)))
function ModelSeconds($intervals, $model) {
	$seconds = 0;
	foreach ($intervals as $interval) {
		list($path, $point, $yards, , $position, $total) = $interval;
		$speed = null;
		if (isset($model["paths"][$path])) {
			ksort($model["paths"][$path]);
			foreach ($model["paths"][$path] as $at => $value)
				if ($at <= $point || $speed === null)
					$speed = $value;
		} else {
			$landing = count($model["landing"]) - ($total - $position);
			if (isset($model["landing"][$landing]))
				$speed = $model["landing"][$landing];
			elseif (isset($model["takeoff"][$position]))
				$speed = $model["takeoff"][$position];
			else
				foreach ($model["spacing"] as $step)
					if ($speed === null && $yards < $step[0])
						$speed = $step[1];
		}
		$seconds += $yards / (($speed ?? $model["cruise"]) * (40 + 1 / 3) / 40);
	}
	return $seconds;
}

// how far off the estimates of the flights are, as array(seconds on average, seconds at worst)
function ModelError($flights, $model) {
	$sum = 0;
	$worst = 0;
	foreach ($flights as $flight) {
		$error = abs($flight["seconds"] - ModelSeconds($flight["intervals"], $model));
		$sum += $error;
		$worst = max($worst, $error);
	}
	return count($flights) ? array($sum / count($flights), $worst) : array(0, 0);
}

// the speeds by the length of the stretches that bring the estimates of the flights closest to how long they took
function FitSpacing($flights, $model) {
	$speeds = array_fill(0, count(SPACING_YARDS), $model["cruise"]);
	$build = function($speeds) use ($model) {
		$spacing = array();
		foreach (SPACING_YARDS as $i => $yards)
			if ($speeds[$i] < $model["cruise"] && (!isset($speeds[$i + 1]) || $speeds[$i + 1] !== $speeds[$i]))
				$spacing[] = array($yards, $speeds[$i]);
		return $spacing;
	};
	$cost = function($speeds) use ($flights, $model, $build) {
		$model["spacing"] = $build($speeds);
		list($average, $worst) = ModelError($flights, $model);
		return $average + 0.15 * $worst;
	};
	$best = $cost($speeds);
	do {
		$improved = false;
		foreach (SPACING_YARDS as $i => $yards) {
			for ($speed = 10; $speed <= $model["cruise"]; $speed += 5) {
				// shorter stretches are never flown faster than longer ones
				$try = $speeds;
				foreach ($try as $j => $value)
					$try[$j] = $j <= $i ? min($value, $speed) : max($value, $speed);
				$try[$i] = $speed;
				$value = $cost($try);
				if ($value < $best - 0.000001) {
					$best = $value;
					$speeds = $try;
					$improved = true;
				}
			}
		}
	} while ($improved);
	return $build($speeds);
}

function SpacingList($spacing) {
	return implode(", ", array_map(function($step) { return sprintf("{ %d, %d }", $step[0], $step[1]); }, $spacing));
}

// compares what was flown to what core.lua has and prints what to change in it
function SuggestChanges($analyses, $coreFile) {
	$core = ReadCore($coreFile);
	printf("\nSuggested changes to %s\n", $coreFile);
	if (!$core || !count($core["constants"])) {
		print("  unable to read the speeds out of it, so there is nothing to compare the flights to\n");
		return;
	}
	$names = array_flip(array_reverse($core["constants"], true)); // [speed] = constant
	$maps = array();
	foreach ($analyses as $index => $a) {
		if ($a->incomplete || count($a->track) < 2 || !isset($a->record["area"]))
			continue;
		$key = $a->record["area"];
		if (!isset($maps[$key]))
			$maps[$key] = array("flights" => array(), "time" => array());
		$maps[$key]["flights"][$index] = $a;
		foreach ($a->steps as $step) {
			if ($step[3] !== "move") continue;
			$speed = FlightAnalysis::RoundSpeed($step[2]);
			$maps[$key]["time"][$speed] = ($maps[$key]["time"][$speed] ?? 0) + $step[0];
		}
	}
	ksort($maps);
	$changes = 0;
	$pathLines = array();
	$pathNotes = array();
	$small = 0;
	foreach ($maps as $map => $info) {
		$out = array();
		// the speed most of the time was flown at is the speed of the taxi map
		arsort($info["time"]);
		$cruise = intval(array_key_first($info["time"]));
		$now = $core["speeds"][$map] ?? $core["default"];
		if ($cruise !== $now) {
			$name = $names[$cruise] ?? null;
			$out[] = sprintf("  speed: flown at %d, core.lua uses %d (%s)", $cruise, $now, isset($core["speeds"][$map]) ? "its entry in the speed table is wrong" : "it has no entry in the speed table");
			if ($cruise === $core["default"])
				$out[] = sprintf("    remove from the speed table:    [%d] = ...", $map);
			elseif ($name)
				$out[] = sprintf("    %s the speed table:    [%d] = %s,", isset($core["speeds"][$map]) ? "change in" : "add to", $map, $name);
			else
				$out[] = sprintf("    there is no TAXI_SPEED constant for %d, add one (local TAXI_SPEED_%d = %d * (1 + 1/120)) and then to the speed table:    [%d] = TAXI_SPEED_%d,", $cruise, $cruise, $cruise, $map, $cruise);
		}
		// how the flights sped up after taking off and slowed down before landing
		$takeoffs = array();
		$landings = array();
		$flights = array();
		foreach ($info["flights"] as $index => $a) {
			$route = $a->record["route"] ?? array();
			$speeds = $a->PathSpeeds();
			$intervals = $a->Intervals();
			if (count($intervals))
				$flights[$index] = array("intervals" => $intervals, "seconds" => $a->actual - $a->jumpTime);
			$firstPath = $a->data->paths[$route[1] ?? 0][$route[2] ?? 0] ?? null;
			$lastPath = $a->data->paths[$route[count($route) - 1] ?? 0][$route[count($route)] ?? 0] ?? null;
			foreach ($speeds as $path => $flown) {
				$count = count($a->data->pathPoints[$path] ?? array());
				$spread = SpreadSpeeds($flown["speeds"], $flown["first"], $flown["last"]);
				if (isset($core["paths"][$path]) || (count($spread) && max($spread) > $cruise))
					continue; // has its own speeds
				if (!in_array($cruise, $spread, true))
					continue; // never got up to speed, so we can't tell where taking off ends and landing begins
				if ($path === $firstPath && $flown["first"] === 1) {
					$list = array();
					for ($point = 1; $point <= $flown["last"] && $spread[$point] < $cruise; $point++)
						$list[] = $spread[$point];
					$takeoffs[implode(", ", $list)][] = $index;
				}
				if ($path === $lastPath && $flown["last"] === $count) {
					$list = array();
					for ($point = $count - 1; $point >= $flown["first"] && $spread[$point] < $cruise; $point--)
						array_unshift($list, $spread[$point]);
					$landings[implode(", ", $list)][] = $index;
				}
			}
		}
		$model = array("cruise" => $cruise, "takeoff" => $core["ramps"][$map]["takeoff"] ?? array(), "landing" => $core["ramps"][$map]["landing"] ?? array(), "spacing" => $core["spacing"][$map] ?? array(), "paths" => $core["paths"]);
		// taxi maps with speeds by the length of the stretches leave what is flown slower to those, their ramp is only what is the same on every flight
		if (!count($model["spacing"])) {
			$takeoff = MostSeen($takeoffs, implode(", ", $model["takeoff"]));
			$landing = MostSeen($landings, implode(", ", $model["landing"]));
			if ($takeoff !== null && $landing !== null && ($takeoff !== implode(", ", $model["takeoff"]) || $landing !== implode(", ", $model["landing"]))) {
				$describe = function($seen, $best) {
					$others = array();
					foreach ($seen as $key => $list)
						if (strval($key) !== $best)
							$others[] = sprintf("%s on flight %s", strval($key) === "" ? "none" : $key, implode(", ", $list));
					return sprintf("%s on %d of %d flights%s", $best === "" ? "none" : $best, count($seen[$best]), array_sum(array_map("count", $seen)), count($others) ? " (" . implode("; ", $others) . ")" : "");
				};
				$out[] = sprintf("  speeds after taking off: %s, core.lua has %s", $describe($takeoffs, $takeoff), SpeedList($model["takeoff"]));
				$out[] = sprintf("  speeds before landing: %s, core.lua has %s", $describe($landings, $landing), SpeedList($model["landing"]));
				if ($takeoff === "" && $landing === "")
					$out[] = sprintf("    remove from AREA_RAMPS:    [%d] = ...", $map);
				else
					$out[] = sprintf("    %s AREA_RAMPS:    [%d] = { takeoff = { %s }, landing = { %s } },", isset($core["ramps"][$map]) ? "change in" : "add to", $map, $takeoff, $landing);
				if (count($takeoffs[$takeoff]) < 2 || count($landings[$landing]) < 2 || count($takeoffs[$takeoff]) * 2 <= array_sum(array_map("count", $takeoffs)) || count($landings[$landing]) * 2 <= array_sum(array_map("count", $landings)))
					$out[] = "    not sure about this one as too few flights agree, fly a few more single path flights on this taxi map";
				$model["takeoff"] = array_map("intval", array_filter(explode(", ", $takeoff), "strlen"));
				$model["landing"] = array_map("intval", array_filter(explode(", ", $landing), "strlen"));
			}
		}
		// if flying slower where the points are close to each other brings the estimates closer to how long the flights took
		list($average, $worst) = ModelError($flights, $model);
		if (count($flights) >= SPACING_MIN_FLIGHTS) {
			$fitted = $model;
			$fitted["spacing"] = FitSpacing($flights, $model);
			list($fittedAverage, $fittedWorst) = ModelError($flights, $fitted);
			if ($fitted["spacing"] !== $model["spacing"] && $fittedAverage <= $average - SPACING_MIN_SECONDS) {
				$out[] = sprintf("  speeds by how close the points are: the %d flights are off by %.1f sec on average (%.1f at worst) with core.lua, and by %.1f sec (%.1f at worst) with these", count($flights), $average, $worst, $fittedAverage, $fittedWorst);
				if (count($fitted["spacing"]))
					$out[] = sprintf("    %s AREA_SPACING:    [%d] = { %s },", isset($core["spacing"][$map]) ? "change in" : "add to", $map, SpacingList($fitted["spacing"]));
				else
					$out[] = sprintf("    remove from AREA_SPACING:    [%d] = ...", $map);
				$model = $fitted;
				list($average, $worst) = array($fittedAverage, $fittedWorst);
			}
		}
		// the paths that are off by more than a few seconds with the speeds of the taxi map need their own speeds
		$without = $model;
		$without["paths"] = array();
		foreach ($info["flights"] as $index => $a) {
			if (!isset($flights[$index]))
				continue;
			$byPath = array();
			foreach ($flights[$index]["intervals"] as $interval)
				$byPath[$interval[0]][] = $interval;
			foreach ($a->PathSpeeds() as $path => $flown) {
				if (!isset($byPath[$path]))
					continue;
				$seconds = 0;
				foreach ($byPath[$path] as $interval) {
					if (!$interval[3])
						continue 2; // we did not see how fast all of it was flown
					$seconds += $interval[2] / ($interval[3] * (40 + 1 / 3) / 40);
				}
				$gain = ModelSeconds($byPath[$path], $without) - $seconds;
				$count = count($a->data->pathPoints[$path] ?? array());
				$whole = $flown["first"] === 1 && $flown["last"] === $count;
				$name = "?";
				foreach ($a->data->paths as $from => $destinations)
					foreach ($destinations as $to => $id)
						if ($id === $path)
							$name = $a->data->NodeName($from) . " > " . $a->data->NodeName($to);
				$had = isset($core["paths"][$path]) ? SpreadSpeeds($core["paths"][$path], $flown["first"], $flown["last"]) : null;
				$spread = SpreadSpeeds($flown["speeds"], $flown["first"], $flown["last"]);
				unset($had[$count], $spread[$count]); // the last point sets no speed as the flight ends there
				$text = sprintf("%.0f sec %s than the speeds of the taxi map give", abs($gain), $gain > 0 ? "shorter" : "longer");
				if (abs($gain) < SUGGEST_PATH_SECONDS) {
					if ($had !== null && $whole)
						$pathLines[$path] = sprintf("    remove from PATH_SPEEDS:    [%d] = ... -- %s (flight %d, only %s)", $path, $name, $index, $text);
					elseif ($had === null && $flown["time"] > 0 && abs($gain) >= 1)
						$small++;
					continue;
				}
				if ($had === $spread)
					continue;
				if ($whole) {
					ksort($flown["speeds"]);
					unset($flown["speeds"][$count]);
					$parts = array();
					foreach ($flown["speeds"] as $point => $speed)
						$parts[] = sprintf("[%d] = %d", $point, $speed);
					$pathLines[$path] = sprintf("    %s PATH_SPEEDS:    [%d] = { %s }, -- %s (flight %d, %s%s)", $had === null ? "add to" : "change in", $path, implode(", ", $parts), $name, $index, $text, count($flown["unsure"]) ? ", not sure about point " . implode(", ", $flown["unsure"]) : "");
				} elseif (!isset($pathLines[$path])) {
					$pathNotes[$path] = sprintf("    path %d (%s) is %s%s, but flight %d only flew points %d to %d of %d. Fly it on its own (not passing through its ends) to get all of it", $path, $name, $text, $had === null ? "" : " and differs from core.lua", $index, $flown["first"], $flown["last"], $count);
				}
			}
		}
		if (count($out)) {
			$changes++;
			printf("\n  taxi map %d (%d flights, mostly flown at %d)\n", $map, count($info["flights"]), $cruise);
			print("  " . implode("\n  ", $out) . "\n");
		} else {
			printf("\n  taxi map %d (%d flights, mostly flown at %d, off by %.1f sec on average and %.1f at worst): nothing to change\n", $map, count($info["flights"]), $cruise, $average, $worst);
		}
	}
	foreach ($pathLines as $path => $line)
		unset($pathNotes[$path]);
	if (count($pathLines) || count($pathNotes)) {
		$changes++;
		ksort($pathLines);
		ksort($pathNotes);
		print("\n  paths with their own speeds\n" . implode("\n", array_merge($pathLines, $pathNotes)) . "\n");
	}
	if ($small)
		printf("\n  %d paths were off by 1 to %d sec with the speeds of their taxi map and are left alone\n", $small, SUGGEST_PATH_SECONDS);
	if (!$changes)
		print("\n  core.lua already matches what was flown\n");
	print("\n  the speeds are compared rounded to the nearest 5, and the time spent loading another map is left out of how long a flight took\n");
}

function GetClient($record) {
	$project = $record["project"] ?? 1;
	if ($project === 1) return "mainline";
	if ($project === 2) return "vanilla";
	return "classic";
}

$analyses = array();
$areas = array();

foreach ($records as $index => $record) {
	if (!is_array($record) || ($record["version"] ?? 0) !== 1) {
		fprintf(STDERR, "flight %s skipped as it is not in a format this script knows\n", $index);
		continue;
	}
	try {
		$analyses[$index] = new FlightAnalysis($index, $record, TaxiData::Get($client ?? GetClient($record)), $near, $far);
	} catch (Exception $e) {
		fprintf(STDERR, "flight %s skipped: %s\n", $index, $e->getMessage());
	}
}

printf("%d flights in %s\n\n", count($analyses), $file);
printf("%4s  %-8s %6s  %8s %8s %8s %7s  %8s %8s  %6s %6s  %s\n", "#", "client", "map", "estimate", "actual", "error", "error%", "est yd", "flown yd", "speed", "flown", "route");

foreach ($analyses as $index => $a) {
	$r = $a->record;
	$typical = $a->TypicalSpeed();
	$error = $a->Error();
	printf("%4d  %-8s %6s  %8.1f %8.1f %+8.1f %+6.1f%%  %8.0f %8.0f  %6.2f %6s  %s%s\n", $index, $a->data->client, $r["area"] ?? "?", $a->estimate, $a->actual, $error, $a->estimate > 0 ? $error / $a->estimate * 100 : 0, $r["distance"], $a->travelled, $r["areaSpeed"] ?? 0, $typical === null ? "?" : sprintf("%.2f", $typical), $a->RouteName(), ($a->hasOverride ? " [override]" : "") . ($a->incomplete ? " [incomplete: " . $a->incomplete . "]" : ""));
	if ($a->incomplete)
		continue;
	$key = $a->data->client . " taxi map " . ($r["area"] ?? "?");
	if (!isset($areas[$key]))
		$areas[$key] = array("count" => 0, "error" => 0, "used" => $r["areaSpeed"] ?? 0, "speeds" => array(), "distance" => array());
	$areas[$key]["count"]++;
	$areas[$key]["error"] += abs($error);
	foreach ($a->steps as $i => $step) {
		if ($step[3] !== "move") continue;
		$speed = strval(round($step[2], 2));
		$areas[$key]["speeds"][$speed] = ($areas[$key]["speeds"][$speed] ?? 0) + $step[0];
	}
	if (!$a->hasOverride && $r["distance"] > 0)
		$areas[$key]["distance"][] = ($a->travelled - $r["distance"]) / $r["distance"] * 100;
}

print("\nerror is the seconds the flight took longer (+) or shorter (-) than estimated\n");
print("speed is what the estimate used for the taxi map, flown is the speed most of the flight was flown at\n");
print("incomplete flights did not reach the destination and are left out of the summaries below\n\n");

foreach ($areas as $key => $area) {
	$speed = FlightAnalysis::WeightedMedian($area["speeds"]);
	$distance = $area["distance"];
	sort($distance);
	printf("%s: %d flights, off by %.1f sec on average, the estimates used %.2f yd/sec and the flights were mostly flown at %s yd/sec", $key, $area["count"], $area["error"] / $area["count"], $area["used"], $speed === null ? "?" : sprintf("%.2f", $speed));
	if (count($distance))
		printf(", the flown distance was typically %+.1f%% off the estimate", $distance[intdiv(count($distance), 2)]);
	print("\n");
}

if ($suggest)
	SuggestChanges($analyses, $coreFile);

$shown = 0;
foreach ($analyses as $index => $a) {
	if (!$all && !isset($flights[$index])) continue;
	print("\n" . str_repeat("-", 100) . "\n" . $a->Report() . "\n");
	$shown++;
}

if ($speeds) {
	$names = array();
	foreach ($analyses as $a) {
		if (isset($names[$a->data->client]))
			continue;
		$names[$a->data->client] = array();
		foreach ($a->data->paths as $from => $destinations)
			foreach ($destinations as $to => $path)
				$names[$a->data->client][$path] = $a->data->NodeName($from) . " > " . $a->data->NodeName($to);
	}
	print("\nthe speed each path was flown at from each of its points (only the points where the speed changed), as lines for the PATH_SPEEDS table in core.lua\n");
	print("paths flown at one speed are left out, and a path flown on several flights is shown for each of them so they can be compared\n\n");
	$lines = array();
	$same = 0;
	foreach ($analyses as $index => $a) {
		if (count($a->track) < 2)
			continue;
		foreach ($a->PathSpeeds() as $path => $info) {
			if (count(array_unique($info["speeds"])) < 2) {
				$same++;
				continue;
			}
			ksort($info["speeds"]);
			$parts = array();
			foreach ($info["speeds"] as $point => $speed)
				$parts[] = sprintf("[%d] = %d", $point, $speed);
			$count = count($a->data->pathPoints[$path] ?? array());
			$notes = array(sprintf("flight %d", $index));
			if ($info["first"] > 1 || $info["last"] < $count)
				$notes[] = sprintf("only points %d to %d of %d were flown", $info["first"], $info["last"], $count);
			if (count($info["unsure"]))
				$notes[] = "not sure about point " . implode(", ", $info["unsure"]);
			if ($a->incomplete)
				$notes[] = "incomplete";
			$lines[] = array($path, $index, sprintf("\t\t\t[%d] = { %s }, -- %s (%s)", $path, implode(", ", $parts), $names[$a->data->client][$path] ?? "?", implode(", ", $notes)));
		}
	}
	usort($lines, function($a, $b) { return $a[0] <=> $b[0] ?: $a[1] <=> $b[1]; });
	foreach ($lines as $line)
		print($line[2] . "\n");
	printf("\n%d paths were flown at one speed\n", $same);
	$shown++;
}

if (!$shown)
	print("\nuse --flight=N or --all to see the details of flights, --speeds for the speed of each path\n");
