local ns = require "catmul"
local db = require "db"

local CatmulDistance = ns.CatmulDistance
local TAXINODES = db.TAXINODES
local TAXIPATH = db.TAXIPATH
local TAXIPATHNODE = db.TAXIPATHNODE
local TaxiNodes = db.TaxiNodes
local TaxiPath = db.TaxiPath
local TaxiPathNode = db.TaxiPathNode

local function TestFlight(pathID, fromID, toID)
    if pathID < 1 or fromID < 1 or toID < 1 then
        return
    end

    local nodes = {}
    local count = 0

    for _, bucket in ipairs(TaxiPathNode) do
        for _, node in ipairs(bucket) do
            if node[TAXIPATHNODE.PATHID] == pathID then
                count = count + 1
                nodes[count] = { x = node[TAXIPATHNODE.LOC_0], y = node[TAXIPATHNODE.LOC_1], z = node[TAXIPATHNODE.LOC_2] }
            end
        end
    end

    local distance = CatmulDistance(nodes)
    if distance > 0 then
        print(("[%d] \"%s\" to \"%s\" %d yd over cirka %d seconds"):format(pathID, fromID, toID, distance, distance / 30))
    end
end

local function TestAllPaths()
    print "Testing all flight paths ..."

    for _, bucket in ipairs(TaxiPath) do
        for _, path in ipairs(bucket) do
            TestFlight(path[TAXIPATH.ID], path[TAXIPATH.FROMTAXINODE], path[TAXIPATH.TOTAXINODE])
        end
    end

    print "... done!"
end

TestAllPaths()
