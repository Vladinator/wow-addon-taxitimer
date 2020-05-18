<?php

class TaxiParser {

	// the default and last known format needed to parse taxi paths and output data to db.lua
	private $allfields = false;
	private $fields = array(
		"taxinodes" => array(
			// "Name_lang",
			// "Pos[0]",
			// "Pos[1]",
			// "Pos[2]",
			// "MapOffset[0]",
			// "MapOffset[1]",
			// "FlightMapOffset[0]",
			// "FlightMapOffset[1]",
			// "ID",
			// "ContinentID",
			// "ConditionID",
			// "CharacterBitNumber",
			// "Flags",
			// "UiTextureKitID",
			// "MinimapAtlasMemberID",
			// "Facing",
			// "SpecialIconConditionID",
			// "VisibilityConditionID",
			// "MountCreatureID[0]",
			// "MountCreatureID[1]",
		),
		"taxipath" => array(
			"ID",
			"FromTaxiNode",
			"ToTaxiNode",
			// "Cost",
		),
		"taxipathnode" => array(
			"Loc[0]",
			"Loc[1]",
			"Loc[2]",
			"ID",
			"PathID",
			// "NodeIndex",
			// "ContinentID",
			// "Flags",
			// "Delay",
			// "ArrivalEventID",
			// "DepartureEventID",
		),
	);

	// visual related structures
	private $flagvisuals = array(
		0x3 => array( "color" => "#ffff00" ),
		0x2 => array( "color" => "#ff0000" ),
		0x1 => array( "color" => "#0000ff" ),
		0x0 => array( "color" => "#ccc" ),
	);
	private $pathvisuals = array();
	private $unknownmaps = array();

	// session storage for files and db entries
	private $files = array();
	private $db = array();
	private $pdb;

	// scans the csv folder for relevant files
	public function __construct($scandir = __DIR__ . "/csv/*.csv") {
		$this->files = glob($scandir);
		// create the path visual colors
		for ($r = 64; $r < 255; $r += 32)
			for ($g = 64; $g < 255; $g += 32)
				for ($b = 64; $b < 255; $b += 32)
					$this->pathvisuals[] = array( "color" => sprintf("#%02x%02x%02x", $r, $g, $b) );
	}

	// you can provide a set of fields to output or the boolean true to include all fields
	// if not called will fallback to the default last known format defined above
	public function IncludeFields($fields = true) {
		if ($fields === true) {
			$this->allfields = true;
		} elseif (is_array($fields)) {
			$this->allfields = false;
			$this->fields = $fields;
		}
	}

	// reads the files and populates the db array
	public function Read() {
		foreach ($this->files as $file) {
			$filename = pathinfo($file, PATHINFO_FILENAME);
			$filename = mb_strtolower($filename);
			$headers = array();
			$items = array();

			if (($fh = fopen($file, "r")) !== false) {
				while (($item = fgetcsv($fh, 1024, ",")) !== false) {
					if (empty($headers)) {
						$headers = $item;
					} else {
						$item = $this->ParseItem($filename, $headers, $item);
						if ($item && count($item))
							$items[] = $item;
					}
				}
				fclose($fh);
			}

			$this->db[$filename] = array($headers, $items);
		}
	}

	// rotate coordinates appropriately for the map
	private function RotateCoords($x, $y, $map = -1) {
		$rx = -90;
		$ry = 0;
		$fx = -1;
		$fy = 1;
		switch ($map) {
			case -1:
			case 0:
			case 1:
			case 30:
			case 451:
			case 530:
			case 560:
			case 571:
			case 603:
			case 606:
			case 609:
			case 622:
			case 631:
			case 646:
			case 870:
			case 967:
			case 1014:
			case 1116:
			case 1159:
			case 1190:
			case 1191:
			case 1220:
			case 1464:
			case 1473:
			case 1481:
			case 1519:
			case 1529:
			case 1560:
			case 1623:
			case 1642:
			case 1643:
			case 1666:
			case 1669:
			case 1693:
			case 1718: // OK Nazjatar
			case 1795:
			case 1817:
			case 2175:
			case 2222:
			case 2224:
			case 2228:
			case 2305:
				// we default using the values above the switch block
				break;
			default:
				if (!isset($this->unknownmaps[$map])) {
					$this->unknownmaps[$map] = true;
					printf("[%s] new map can't rotate and flip coordinate system\r\n", $map);
				}
		}
		$sin = deg2rad($rx);
		$cos = deg2rad($ry);
		$nx = $x * $cos - $y * $sin;
		$ny = $x * $sin + $y * $cos;
		return array($nx * $fx, $ny * $fy);
	}

	// parses the db into usable data
	public function ParseDB($mapFilter = false, $drawEdges = true, $drawDirectEdges = true) {
		if (isset($this->pdb))
			return $this->pdb;
		$pdb = array();

		list ($pathheaders, $pathitems) = $this->db['taxipath'];
		$pdb['taxipath'] = array();
		$hasconnections = array();

		foreach ($pathitems as $path) {
			list ($id, $from, $to, $cost) = $path;
			$id = intval($id);
			$from = intval($from);
			$to = intval($to);
			$cost = intval($cost);

			if (!$from || !$to || $from === $to)
				continue;

			$hasconnections[$from] = true;
			$hasconnections[$to] = true;

			$visual = next($this->pathvisuals);
			if (!$visual) $visual = reset($this->pathvisuals);

			$pdb['taxipath'][] = array(
				"id" => $id,
				"from" => $from,
				"to" => $to,
				"cost" => $cost,
				// extra
				"visual" => $visual,
			);
		}

		list ($nodesheaders, $nodesitems) = $this->db['taxinodes'];
		$pdb['taxinodes'] = array();

		foreach ($nodesitems as $node) {
			list ($label, $x, $y, $z, $mapOffsetX, $mapOffsetY, $_, $_, $id, $map, $_, $_, $flags, $texture, $atlas, $_, $_, $_, $hmount, $amount) = $node;
			$label = preg_replace("/[\"]/", "", $label);
			$x = floatval($x);
			$y = floatval($y);
			$z = floatval($z);
			$id = intval($id);
			$map = intval($map);
			$flags = intval($flags);
			$texture = intval($texture);
			$atlas = intval($atlas);
			$hmount = intval($hmount);
			$amount = intval($amount);

			if ($mapFilter !== false && $mapFilter !== $map)
				continue;

			if (!isset($hasconnections[$id]))
				continue;

			list ($x, $y) = $this->RotateCoords($x, $y, $map);

			$visual = $this->flagvisuals[0x0];
			foreach ($this->flagvisuals as $mask => $visuals) {
				if (($flags & $mask) === $mask) {
					$visual = $visuals;
					break;
				}
			}

			$pdb['taxinodes'][] = array(
				"label" => $label,
				"x" => $x,
				"y" => $y,
				"z" => $z,
				"id" => $id,
				"map" => $map,
				"flags" => $flags,
				"texture" => $texture,
				"atlas" => $atlas,
				"hmount" => $hmount,
				"amount" => $amount,
				// extra
				"visual" => $visual,
			);
		}

		list ($pathnodeheaders, $pathnodeitems) = $this->db['taxipathnode'];
		$pdb['taxipathnode'] = array();
		$pdb['taxipathnodedirect'] = array();

		if ($drawEdges)
			foreach ($pdb['taxipath'] as $nodepath) {
				$found = false;

				foreach ($pathnodeitems as $pathnode) {
					list ($x, $y, $z, $id, $pathid, $index, $map, $flags, $delay) = $pathnode;
					$map = intval($map);
					$pathid = intval($pathid);

					if ($mapFilter !== false && $mapFilter !== $map)
						continue;

					if ($found && $nodepath['id'] !== $pathid)
						break;

					if ($nodepath['id'] === $pathid)
						$found = true;

					if (!$found)
						continue;

					$x = floatval($x);
					$y = floatval($y);
					$z = floatval($z);
					$id = intval($id);
					$index = intval($index);
					$flags = intval($flags);
					$delay = intval($delay);

					list ($x, $y) = $this->RotateCoords($x, $y, $map);

					$pdb['taxipathnode'][$pathid][] = array(
						"id" => $id,
						"pathid" => $pathid,
						"x" => $x,
						"y" => $y,
						"z" => $z,
						"map" => $map,
						// extra
						"visual" => $nodepath['visual'],
					);
				}
			}

		if ($drawDirectEdges)
			foreach ($pdb['taxinodes'] as $node) {
				if ($mapFilter !== false && $mapFilter !== $node['map'])
					continue;

				if (!isset($hasconnections[$node['id']]))
					continue;

				$nodeid = $node['id'];
				$destinations = array();

				foreach ($pdb['taxipath'] as $nodepath) {
					if ($nodeid !== $nodepath['from'] || $nodeid === $nodepath['to'] || $nodepath['from'] === 0 || $nodepath['to'] === 0)
						continue;

					$toid = $nodepath['to'];
					$tonode = null;

					foreach ($pdb['taxinodes'] as $subnode) {
						if ($toid === $subnode['id']) {
							$tonode = $subnode;
							break;
						}
					}

					if (empty($tonode))
						continue;

					$destinations[$toid] = $tonode;
				}

				$pdb['taxipathnodedirect'][$nodeid] = $destinations;
			}

		$this->pdb = $pdb;
		return $pdb;
	}

	// writes the db into a db.lua file
	public function Write($outfile = __DIR__ . "/db.lua") {
		$lua = array();
		$lua[] = "local _, ns, F = ...\r\n";
		$lua[] = "if type(ns) ~= \"table\" then\r\n\tns = {}\r\nend\r\n";

		foreach ($this->db as $file => $data) {
			$file = mb_strtolower($file);
			list ($headers, $items) = $data;
			$temp = array();

			foreach ($headers as $k => $v) {
				if (!$this->allfields && array_search($v, $this->fields[$file]) === false)
					continue;

				$v = mb_strtoupper($v);
				$v = preg_replace("/[\[]/", "_", $v);
				$v = preg_replace("/[\[\]]/", "", $v);

				$temp[] = $v . " = " . ($k + 1);
			}

			$temp = implode(",\r\n\t", $temp);
			$lua[] = "ns." . mb_strtoupper($file) . " = {\r\n\t" . $temp . (!empty($temp) ? "," : "-- TODO") . "\r\n}\r\n";
		}

		foreach ($this->db as $file => $data) {
			list ($headers, $items) = $data;

			if (!count($items))
				continue;

			$temp = array();

			foreach ($items as $item) {
				$temp[] = "{" . implode(",", $item) . "}";
			}
	
			$lua[] = "ns." . $file . " = {}";
	
			$chunks = array_chunk($temp, 8192);
			foreach ($chunks as $cindex => $chunk) {
				$lua[] = "F = function() ns." . $file . "[" . ($cindex + 1) . "] = {" . implode(",", $chunk) . "} end F() F = nil";
			}
		}

		$lua = implode("\r\n", $lua) . "\r\n\r\nreturn ns\r\n";
		file_put_contents($outfile, $lua);
	}

	// parses the loaded item data and returns the relevant data based on what headers we are interested to load
	private function ParseItem($file, $headers, $data) {
		$item = array();
	
		foreach ($data as $k => $v) {
			if ($this->allfields || array_search($headers[$k], $this->fields[$file]) !== false) {
				$v = $this->ParseValue($v);
			} else {
				$v = null;
			}
	
			if ($v !== null)
				$item[] = $v;
		}

		return $item;
	}

	// when outputing lua this wraps the values with the appropriate syntax
	private function ParseValue($value) {
		if (strlen($value) === 0)
			return null;

		if (preg_match("/^\-?[0-9\.\,]+$/", $value))
			return preg_replace("/\,/", ".", $value);

		return "\"" . addcslashes($value, "\"") . "\"";
	}

	// returns array over relevant maps
	public function GetMaps() {
		$maps = array();

		list ($nodesheaders, $nodesitems) = $this->db['taxinodes'];

		foreach ($nodesitems as $node) {
			$map = intval($node[9]);

			$maps[$map] = true;
		}

		$maps = array_keys($maps);
		natsort($maps);

		return $maps;
	}

	// get catmull-rom splines for given path
	private function GetCatmullRomSplineForPath($pathnodes) {
		$visual = $pathnodes[0]['visual'];
		$temp = array_map(function($pathnode){ return array($pathnode['x'], $pathnode['y']); }, $pathnodes);
		$pathnodes = array(); foreach ($temp as $a) foreach ($a as $b) $pathnodes[] = $b;
		$k = 1;
		$size = count($pathnodes);
		$last = $size - 4;
		$path = array();
		$path[] = array($pathnodes[0], $pathnodes[1]);
		for ($i = 0; $i < $size - 2; $i +=2) {
			$x0 = $i ? $pathnodes[$i - 2] : $pathnodes[0];
			$y0 = $i ? $pathnodes[$i - 1] : $pathnodes[1];
			$x1 = $pathnodes[$i + 0];
			$y1 = $pathnodes[$i + 1];
			$x2 = $pathnodes[$i + 2];
			$y2 = $pathnodes[$i + 3];
			$x3 = $i !== $last ? $pathnodes[$i + 4] : $x2;
			$y3 = $i !== $last ? $pathnodes[$i + 5] : $y2;
			$cp1x = $x1 + ($x2 - $x0) / 6 * $k;
			$cp1y = $y1 + ($y2 - $y0) / 6 * $k;
			$cp2x = $x2 - ($x3 - $x1) / 6 * $k;
			$cp2y = $y2 - ($y3 - $y1) / 6 * $k;
			$path[] = array($cp1x, $cp1y); // array($cp1x, $cp1y, $cp2x, $cp2y, $x2, $y2);
		}
		return array("visual" => $visual, "path" => $path);
	}

	// writes the db into a db.svg file
	public function WriteSvg($outfile = __DIR__ . "/db.svg", $mapFilter = false, $drawEdges = true, $drawDirectEdges = true) {
		$svgdata = array();

		$pdb = $this->ParseDB(false, $drawEdges, $drawDirectEdges);
		$nodes = $pdb['taxinodes'];
		$edges = $pdb['taxipathnode'];
		$edgesdirect = $pdb['taxipathnodedirect'];

		$nodesvars = array(
			"minx" => 0xffffff,
			"maxx" => -0xffffff,
			"miny" => 0xffffff,
			"maxy" => -0xffffff,
			"minz" => 0xffffff,
			"maxz" => -0xffffff,
		);

		foreach ($nodes as $node) {
			if ($mapFilter !== false && $mapFilter !== $node['map'])
				continue;

			$nodesvars['minx'] = min($nodesvars['minx'], $node['x']);
			$nodesvars['maxx'] = max($nodesvars['maxx'], $node['x']);
			$nodesvars['miny'] = min($nodesvars['miny'], $node['y']);
			$nodesvars['maxy'] = max($nodesvars['maxy'], $node['y']);
			$nodesvars['minz'] = min($nodesvars['minz'], $node['z']);
			$nodesvars['maxz'] = max($nodesvars['maxz'], $node['z']);
		}

		$nodesvars['offsetx'] = abs($nodesvars['minx']);
		$nodesvars['offsety'] = abs($nodesvars['miny']);
		$nodesvars['offsetz'] = abs($nodesvars['minz']);

		$nodesvars['width'] = $nodesvars['maxx'] + $nodesvars['offsetx'];
		$nodesvars['height'] = $nodesvars['maxy'] + $nodesvars['offsety'];
		$nodesvars['depth'] = $nodesvars['maxz'] + $nodesvars['offsetz'];

		$padding = 500;
		$scale = 0.25;
		$nodescale = 0.75;
		$nodesizex = 40;
		$nodesizey = 20;
		$nodefont = 14;
		$nodefontmin = 6;
		$edgesize = 5;
		$edgesizemin = 1;

		foreach ($nodes as $node) {
			if ($mapFilter !== false && $mapFilter !== $node['map'])
				continue;

			$nx = $node['x'] + $nodesvars['offsetx'] + $padding;
			$ny = $node['y'] + $nodesvars['offsety'] + $padding;
			$nz = $node['z'] + $nodesvars['offsetz'] + $padding;

			$label2 = htmlentities($node['label']);
			$svgdata[] = sprintf("<g id=\"node_%d\" class=\"node\"><title>%s</title><ellipse fill=\"%s\" stroke=\"#000\" cx=\"%d\" cy=\"%d\" rx=\"%d\" ry=\"%d\" /><text text-anchor=\"middle\" x=\"%.2f\" y=\"%.2f\" font-family=\"Times New Roman,serif\" font-size=\"%.2f\">%s</text></g>", $node['id'], $label2, $node['visual']['color'], $nx * $scale, $ny * $scale, $nodesizex * $nodescale, $nodesizey * $nodescale, $nx * $scale, $ny * $scale, max($nodefontmin, $nodefont * $nodescale), $label2);
		}

		if ($drawEdges)
			foreach ($edges as $pathid => $pathnodes) {
				foreach ($pathnodes as $edgeid => $pathnode) {
					if ($mapFilter !== false && $mapFilter !== $pathnode['map'])
						continue;

					$nx = $pathnode['x'] + $nodesvars['offsetx'] + $padding;
					$ny = $pathnode['y'] + $nodesvars['offsety'] + $padding;
					$nz = $pathnode['z'] + $nodesvars['offsetz'] + $padding;

					$r = max($edgesizemin, $edgesize * $nodescale);
					$svgdata[] = sprintf("<g id=\"path_%d_%d\" class=\"edge\"><ellipse fill=\"%s\" stroke=\"#ccc\" cx=\"%d\" cy=\"%d\" rx=\"%d\" ry=\"%d\" /></g>", $pathid, $edgeid + 1, $pathnode['visual']['color'], $nx * $scale, $ny * $scale, $r, $r);
				}

				/*
				$catmull = array_filter($pathnodes, function($pathnode){ return $mapFilter !== false && $mapFilter !== $pathnode['map']; });
				$catmull = $this->GetCatmullRomSplineForPath($catmull);
				foreach ($catmull['path'] as $edgeid => $pathnode) {
					$nx = $pathnode[0] + $nodesvars['offsetx'] + $padding;
					$ny = $pathnode[1] + $nodesvars['offsety'] + $padding;
					// $nz = $pathnode[2] + $nodesvars['offsetz'] + $padding;

					$r = max($edgesizemin, $edgesize * $nodescale);
					$svgdata[] = sprintf("<g id=\"cpath_%d_%d\" class=\"edge\"><ellipse fill=\"%s\" stroke=\"#ccc\" cx=\"%d\" cy=\"%d\" rx=\"%d\" ry=\"%d\" /></g>", $pathid, $edgeid + 1, $pathnode['visual']['color'], $nx * $scale, $ny * $scale, $r, $r);
				}
				// */
			}

		if ($drawDirectEdges)
			foreach ($edgesdirect as $pathid => $pathnodes) {
				$fromnode = null;

				foreach ($nodes as $node) {
					if ($pathid === $node['id']) {
						$fromnode = $node;
						break;
					}
				}

				if (empty($fromnode))
					continue;

				foreach ($pathnodes as $edgeid => $pathnode) {
					if ($mapFilter !== false && $mapFilter !== $pathnode['map'])
						continue;

					$nx1 = $pathnode['x'] + $nodesvars['offsetx'] + $padding;
					$ny1 = $pathnode['y'] + $nodesvars['offsety'] + $padding;
					$nz1 = $pathnode['z'] + $nodesvars['offsetz'] + $padding;

					$nx2 = $fromnode['x'] + $nodesvars['offsetx'] + $padding;
					$ny2 = $fromnode['y'] + $nodesvars['offsety'] + $padding;
					$nz2 = $fromnode['z'] + $nodesvars['offsetz'] + $padding;

					$svgdata[] = sprintf("<line id=\"line_%d_%d\" class=\"edge\" stroke=\"%s\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" />", $pathid, $edgeid + 1, $pathnode['visual']['color'], $nx1 * $scale, $ny1 * $scale, $nx2 * $scale, $ny2 * $scale);
				}
			}

		$svgdata = array_reverse($svgdata);

		printf("Writing svg file for %s...\r\n", $mapFilter);
		$svg = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\r\n";
		$svg .= "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\"\r\n\t\"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">\r\n";
		$svg .= sprintf("<svg width=\"%d\" height=\"%d\" transform=\"scale(1 1) rotate(0) translate(0 0)\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">\r\n", ($nodesvars['width'] + $padding * 2) * $scale, ($nodesvars['height'] + $padding * 2) * $scale);
		$svg .= implode("\r\n", $svgdata);
		$svg .= "\r\n</svg>\r\n";
		file_put_contents($outfile, $svg);
	}

	/*
	public function Debug($mapFilter, $pathnodes) {
		$catmull = array_filter($pathnodes, function($pathnode){ return $mapFilter !== false && $mapFilter !== $pathnode['map']; });
		$catmull = $this->GetCatmullRomSplineForPath($catmull);
		var_dump($catmull);
	}
	// */

}
