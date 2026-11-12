<?php
/*

Compares the flights recorded by the addon against the taxi data, to show where the estimates are off and why.

To record flights set `RECORD_FLIGHTS = true` at the top of `core.lua`, fly, then log out or reload so the saved variables are written.

Usage:

	php scripts/analyze.php <WTF/Account/.../SavedVariables/TaxiTimer.lua> [options]

Options:

	--flight=N      show the details of flight N (as numbered in the summary), can be repeated
	--all           show the details of every flight
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
$client = null;
$near = 25;
$far = 60;

foreach (array_slice($argv, 1) as $arg) {
	if (preg_match('/^--flight=(\d+)$/', $arg, $m)) $flights[intval($m[1])] = true;
	elseif ($arg === "--all") $all = true;
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
	fprintf(STDERR, "usage: php %s <SavedVariables/TaxiTimer.lua> [--flight=N] [--all] [--client=mainline|classic|vanilla] [--near=25] [--far=60]\n", $argv[0]);
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

$shown = 0;
foreach ($analyses as $index => $a) {
	if (!$all && !isset($flights[$index])) continue;
	print("\n" . str_repeat("-", 100) . "\n" . $a->Report() . "\n");
	$shown++;
}

if (!$shown)
	print("\nuse --flight=N or --all to see the details of flights\n");
