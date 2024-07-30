<?php
ini_set('memory_limit', '-1');

// import and create a taxi parser instance
include_once __DIR__ . "/taxiparser.php";

// loop over the various clients
foreach (array("mainline", "cata", "classic") as $client) {

    // define the various paths for this client
    $csv_path = __DIR__ . "/csv_" . $client;
    $svg_path = __DIR__ . "/svg_" . $client;
    $db_lua_path = __DIR__ . "/../db_" . $client . ".lua";

    // skip if the client csv files don't exist
    if (!is_dir($csv_path)) {
        continue;
    }

    // ensure the svg folder exists
    if (!is_dir($svg_path)) {
        mkdir($svg_path);
    }

    // construct a parser instance for this client
    $tp = new TaxiParser($client, $csv_path);

    // generate the db.lua file
    $tp->Read();
    $tp->Write($db_lua_path);
    // die; // DEBUG

    // generate the db.svg file
    $tp->IncludeFields(true);
    $tp->Read();
    // $tp->WriteSvg($svg_path . "/db_2444.svg", 2444); die; // DEBUG
    foreach ($tp->GetMaps() as $map) {
        $tp->WriteSvg($svg_path . "/db_" . $map . ".svg", $map);
    }

}
