local ns = select(2, ...) ---@type taxi_ns

if type(ns) ~= "table" then
    ns = {}
end

local CatmulDistance do
    local pow = math.pow

    local C_AMOUNT_OF_POINTS = 10
    local C_ALPHA = 0.5

    local function GetT(t, p0, p1)
        local a = pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2) + pow(p1.z - p0.z, 2)
        local b = pow(a, 0.5)
        local c = pow(b, C_ALPHA)

        return t + c
    end

    local function GetCatmulPoints(points)
        if not points or not points[2] then
            return
        end

        local numNewPoints = 0
        local newPoints = {}

        local ph = { x = 0, y = 0, z = 0 }
        local p0 = points[1] or ph
        local p1 = points[2] or ph
        local p2 = points[3] or ph
        local p3 = points[4] or ph

        local t0 = 0
        local t1 = GetT(t0, p0, p1)
        local t2 = GetT(t1, p1, p2)
        local t3 = GetT(t2, p2, p3)

        local step = (t2 - t1) / (C_AMOUNT_OF_POINTS - 1)

        for t = t1, t2, step do
            local t1mt = t1 - t
            local t1mt0 = t1 - t0
            local tmt0 = t - t0
            local t2mt = t2 - t
            local t2mt1 = t2 - t1
            local tmt1 = t - t1
            local t3mt = t3 - t
            local t3mt2 = t3 - t2
            local tmt2 = t - t2
            local t2mt0 = t2 - t0
            local t3mt1 = t3 - t1

            local a1l, a1r = t1mt/t1mt0, tmt0/t1mt0
            local a2l, a2r = t2mt/t2mt1, tmt1/t2mt1
            local a3l, a3r = t3mt/t3mt2, tmt2/t3mt2
            local b1l, b1r = t2mt/t2mt0, tmt0/t2mt0
            local b2l, b2r = t3mt/t3mt1, tmt1/t3mt1
            local cl, cr = a2l, a2r

            local A1Lx, A1Ly, A1Lz, A1Rx, A1Ry, A1Rz = a1l * p0.x, a1l * p0.y, a1l * p0.z, a1r * p1.x, a1r * p1.y, a1r * p1.z
            local A2Lx, A2Ly, A2Lz, A2Rx, A2Ry, A2Rz = a2l * p1.x, a2l * p1.y, a2l * p1.z, a2r * p2.x, a2r * p2.y, a2r * p2.z
            local A3Lx, A3Ly, A3Lz, A3Rx, A3Ry, A3Rz = a3l * p2.x, a3l * p2.y, a3l * p2.z, a3r * p3.x, a3r * p3.y, a3r * p3.z
            local A1x, A1y, A1z = A1Lx + A1Rx, A1Ly + A1Ry, A1Lz + A1Rz
            local A2x, A2y, A2z = A2Lx + A2Rx, A2Ly + A2Ry, A2Lz + A2Rz
            local A3x, A3y, A3z = A3Lx + A3Rx, A3Ly + A3Ry, A3Lz + A3Rz

            local B1Lx, B1Ly, B1Lz, B1Rx, B1Ry, B1Rz = b1l * A1x, b1l * A1y, b1l * A1z, b1r * A2x, b1r * A2y, b1r * A2z
            local B2Lx, B2Ly, B2Lz, B2Rx, B2Ry, B2Rz = b2l * A2x, b2l * A2y, b2l * A2z, b2r * A3x, b2r * A3y, b2r * A3z
            local B1x, B1y, B1z = B1Lx + B1Rx, B1Ly + B1Ry, B1Lz + B1Rz
            local B2x, B2y, B2z = B2Lx + B2Rx, B2Ly + B2Ry, B2Lz + B2Rz

            local CLx, CLy, CLz, CRx, CRy, CRz = cl * B1x, cl * B1y, cl * B1z, cr * B2x, cr * B2y, cr * B2z
            local Cx, Cy, Cz = CLx + CRx, CLy + CRy, CLz + CRz

            numNewPoints = numNewPoints + 1
            newPoints[numNewPoints] = { x = Cx, y = Cy, z = Cz }
        end

        return newPoints, numNewPoints
    end

    local function GetCatmulPath(path)
        local numNewPath = 0
        local newPath = {}

        for i = 1, #path - 1 do
            local points = { path[i - 1], path[i], path[i + 1], path[i + 2] }
            local newPoints, numNewPoints = GetCatmulPoints(points)

            if newPoints then
                for j = 1, numNewPoints do
                    numNewPath = numNewPath + 1
                    newPath[numNewPath] = newPoints[j]
                end
            end
        end

        if numNewPath > 0 then
            numNewPath = numNewPath + 1
            newPath[numNewPath] = path[#path]

            return newPath, numNewPath
        end
    end

    local function GetDistance(p0, p1)
        return pow(pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2) + pow(p1.z - p0.z, 2), 0.5)
    end

	function CatmulDistance(path)
		local distance = 0
		local newPath = GetCatmulPath(path)

        if newPath then
            for i = 2, #newPath do
                distance = distance + GetDistance(newPath[i - 1], newPath[i])
            end
        end

		return distance
	end

end

ns.CatmulDistance = CatmulDistance

return ns
