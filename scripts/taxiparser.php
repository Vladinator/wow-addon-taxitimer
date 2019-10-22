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

	// session storage for files and db entries
	private $files = array();
	private $db = array();

	// scans the csv folder for relevant files
	public function __construct($scandir = __DIR__ . "/csv/*.csv") {
		$this->files = glob($scandir);
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

	// writes the db into a db.svg file
	public function WriteSvg($outfile = __DIR__ . "/db.svg", $mapFilter = false) {
		$svgdata = array();

		list ($pathheaders, $pathitems) = $this->db['taxipath'];

		$validnodes = array();
		$nodepaths = array();

		foreach ($pathitems as $path) {
			list ($id, $from, $to, $cost) = $path;
			$id = intval($id);
			$from = intval($from);
			$to = intval($to);
			$cost = intval($cost);

			if (!$from || !$to || $from === $to)
				continue;

			$validnodes[$from] = true;
			$validnodes[$to] = true;

			$nodepaths[] = array(
				"id" => $id,
				"from" => $from,
				"to" => $to,
				"cost" => $cost,
			);
		}

		list ($nodesheaders, $nodesitems) = $this->db['taxinodes'];

		$nodesvars = array(
			"minx" => 0xffffff,
			"maxx" => -0xffffff,
			"miny" => 0xffffff,
			"maxy" => -0xffffff,
			"minz" => 0xffffff,
			"maxz" => -0xffffff,
		);

		$nodes = array();

		foreach ($nodesitems as $node) {
			list ($label, $x, $y, $z, $_, $_, $_, $_, $id, $map) = $node;
			$label = preg_replace("/[\"]/", "", $label);
			$x = floatval($x);
			$y = floatval($y);
			$z = floatval($z);
			$id = intval($id);
			$map = intval($map);

			if (!isset($validnodes[$id]) || ($mapFilter !== false && $mapFilter !== $map))
				continue;

			$nodesvars['minx'] = min($nodesvars['minx'], $x);
			$nodesvars['maxx'] = max($nodesvars['maxx'], $x);
			$nodesvars['miny'] = min($nodesvars['miny'], $y);
			$nodesvars['maxy'] = max($nodesvars['maxy'], $y);
			$nodesvars['minz'] = min($nodesvars['minz'], $z);
			$nodesvars['maxz'] = max($nodesvars['maxz'], $z);

			$nodes[] = array(
				"label" => $label,
				"x" => $x,
				"y" => $y,
				"z" => $z,
				"id" => $id,
				"map" => $map,
			);
		}

		if (empty($nodes))
			return;

		list ($pathnodeheaders, $pathnodeitems) = $this->db['taxipathnode'];

		$edges = array();

		/*
		foreach ($nodepaths as $nodepath) {
			$found = false;

			foreach ($pathnodeitems as $pathnode) {
				$pathid = intval($pathnode[4]);

				if ($found && $nodepath['id'] !== $pathid)
					break;

				if ($nodepath['id'] === $pathid)
					$found = true;

				if (!$found)
					continue;

				$map = intval($pathnode[5]);

				if ($mapFilter !== false && $mapFilter !== $map)
					continue;

				$x = floatval($pathnode[0]);
				$y = floatval($pathnode[1]);
				$z = floatval($pathnode[2]);
				$id = intval($pathnode[3]);

				$edges[$pathid][] = array(
					"id" => $id,
					"pathid" => $pathid,
					"x" => $x,
					"y" => $y,
					"z" => $z,
					"map" => $map,
				);
			}
		}
		// */

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
			$nx = $node['x'] + $nodesvars['offsetx'] + $padding;
			$ny = $node['y'] + $nodesvars['offsety'] + $padding;
			$nz = $node['z'] + $nodesvars['offsetz'] + $padding;

			$label2 = htmlentities($node['label']);
			$svgdata[] = sprintf("<g id=\"node%d\" class=\"node\"><title>%s</title><ellipse fill=\"%s\" stroke=\"#000\" cx=\"%d\" cy=\"%d\" rx=\"%d\" ry=\"%d\" /><text text-anchor=\"middle\" x=\"%.2f\" y=\"%.2f\" font-family=\"Times New Roman,serif\" font-size=\"%.2f\">%s</text></g>\r\n", $node['id'], $label2, "#ccc", $nx * $scale, $ny * $scale, $nodesizex * $nodescale, $nodesizey * $nodescale, $nx * $scale, $ny * $scale, max($nodefontmin, $nodefont * $nodescale), $label2);
		}

		foreach ($edges as $pathid => $pathnodes) {
			foreach ($pathnodes as $edgeid => $pathnode) {
				$nx = $pathnode['x'] + $nodesvars['offsetx'] + $padding;
				$ny = $pathnode['y'] + $nodesvars['offsety'] + $padding;
				$nz = $pathnode['z'] + $nodesvars['offsetz'] + $padding;

				$r = max($edgesizemin, $edgesize * $nodescale);
				$svgdata[] = sprintf("<g id=\"edge%d_%d\" class=\"edge\"><ellipse fill=\"#eee\" stroke=\"#ccc\" cx=\"%d\" cy=\"%d\" rx=\"%d\" ry=\"%d\" /></g>\r\n", $pathid, $edgeid + 1, $nx * $scale, $ny * $scale, $r, $r);
			}
		}

		$svg = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\r\n";
		$svg .= "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\"\r\n\t\"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">\r\n";
		$svg .= sprintf("<svg width=\"%d\" height=\"%d\" transform=\"scale(1 1) rotate(0) translate(0 0)\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">\r\n", ($nodesvars['width'] + $padding * 2) * $scale, ($nodesvars['height'] + $padding * 2) * $scale);
		$svg .= implode("\r\n", $svgdata);
		$svg .= "</svg>\r\n";
		file_put_contents($outfile, $svg);
	}

}
