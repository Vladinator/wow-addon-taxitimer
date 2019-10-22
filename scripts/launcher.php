<?php

// import and create a taxi parser instance
include_once __DIR__ . "/taxiparser.php";
$tp = new TaxiParser();

// generate the db.lua file
$tp->Read();
$tp->Write(__DIR__ . "/../db.lua");

// generate the db.svg file
$tp->IncludeFields(true);
$tp->Read();
#$tp->WriteSvg(__DIR__ . "/svg/db_1718.svg", 1718);die; // DEBUG
foreach ($tp->GetMaps() as $map)
    $tp->WriteSvg(__DIR__ . "/svg/db_" . $map . ".svg", $map);
