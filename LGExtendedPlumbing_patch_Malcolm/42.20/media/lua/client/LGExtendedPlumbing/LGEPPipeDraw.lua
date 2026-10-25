--
-- Extended Plumbing - what a laid pipe LOOKS like.
--
-- The window used to paint a piped tile as a blue or white square and tint a piped wall.
-- LG asked for pipes instead:
--
--     "instead of a square tile, its a line, but it wont simply be straight ... there are 4
--      sides and 4 corners to a tile, and any combination of adjacent tiles whether to the
--      side or diagonally will connect like it looks like a pipe system ... dont just have
--      pipe all divert from the center of the tile, actually make it seem like itll bend from
--      corner to side to side to corner ... as well as a end cap of some sorts showing theyre
--      connected to the building pipe area ... also have something that clearly shows a piped
--      tile is then also feeding a fixture"
--
-- This file is the geometry, and nothing but: which way each pipe tile runs, and the quads
-- that draw it, in WORLD coordinates.  LGEPAreaUI owns when it is built and projects it onto
-- the screen every frame.  No world access except the one callback it is handed, so a suite
-- can ask it what it would draw with no game.
--
-- THE TILE HAS EIGHT DOORS.  A run leaves a tile through the middle of one of its four edges
-- (to a side neighbour) or through one of its four corners (to a diagonal one).  A tile with
-- two doors is ONE smooth curve from one to the other - straight when they face each other,
-- a quarter circle round a corner, a long S when an edge hands over to a corner - and the
-- curve leaves each door pointing straight through it.  So the tile on the far side, whose
-- own curve enters through the same door pointing the same way, carries on without a kink:
-- a run of tiles reads as one bent pipe, not as spokes from the middle of each tile.
--
-- WHAT IS NOT A DOOR.  Two pipes diagonal to each other are joined (eight-way, as LG chose),
-- but when a pipe also stands on one of the two tiles between them the run already turns that
-- corner through it, and a second, diagonal length across the same corner would draw a
-- triangle.  So a diagonal is drawn only where nothing shorter already joins the pair.  It
-- changes nothing about what is CONNECTED - that is LGEPPipe.lua's, untouched - only what is
-- drawn to show it.
--
-- THE PIECES OF THE DRAWING, each one texture from media/ui/LGEP (tools/pz_lgep_pipe_textures.py):
--
--   body     a length of pipe, drawn as a strip of short quads along the curve
--   band     a coupling, where a run crosses from one tile into the next: one per pipe, so a
--            player can still count what they could lift back up
--   flange   where a run meets a building's plumbing area
--   cap      the closed end of a run
--   hub      a fitting: three or more ways, a run's end inside a building, a riser's elbow,
--            and the tee a fixture draws off
--   drop     over every plumbed fixture in the system: one on a pipe (on a tee off it), and
--            one in a building's plumbing area (on its own - there is no pipe drawn there)
--
--     "it should show for any fixture within the system, so fixtures that are in the
--      building regions should also get the hovering water droplet on them to show that
--      the fixture should be supplied"
--

require "LGExtendedPlumbing/LGEPPipe"

local EP = LGEP

--------------------------------------------------------------------------------
-- the eight doors
--------------------------------------------------------------------------------

--- Clockwise from north.  Odd are edges, even are corners.  x runs east, y runs south.
local N, NE, E, SE, S, SW, W, NW = 1, 2, 3, 4, 5, 6, 7, 8
local DX = { 0, 1, 1, 1, 0, -1, -1, -1 }
local DY = { -1, -1, 0, 1, 1, 1, 0, -1 }

--- Where each door is on the tile, 0..1, and the unit direction straight out through it.
local AX, AY, OX, OY = {}, {}, {}, {}
for d = 1, 8 do
	AX[d] = 0.5 + DX[d] * 0.5
	AY[d] = 0.5 + DY[d] * 0.5
	local len = math.sqrt(DX[d] * DX[d] + DY[d] * DY[d])
	OX[d], OY[d] = DX[d] / len, DY[d] / len
end

local function isEdge(d) return d % 2 == 1 end

--- How far apart two doors are, in eighths of a turn: 4 faces straight across.
local function turnSteps(a, b)
	local k = math.abs(a - b)
	if k > 4 then k = 8 - k end
	return k
end

EP.PIPE_DOOR = { N = N, NE = NE, E = E, SE = SE, S = S, SW = SW, W = W, NW = NW }
EP.PIPE_DOOR_DX, EP.PIPE_DOOR_DY = DX, DY

--------------------------------------------------------------------------------
-- sizes, in tiles, and the textures
--------------------------------------------------------------------------------

--- Half the pipe's width.  A little over a fifth of a tile across: wide enough to read zoomed
--- out, narrow enough that two runs on neighbouring tiles are plainly two.  The first try was
--- a sixth, and in the preview its couplings and flanges were a pixel or two - there, but
--- nobody would ever have seen them.
EP.PIPE_ART_HW = 0.11

local HW = EP.PIPE_ART_HW
local CAP_R = HW * 1.25
local HUB_R = HW * 1.75
local BAND_L, BAND_T = HW * 1.45, HW * 0.55
local FLANGE_L, FLANGE_T = HW * 2.40, HW * 0.85

--- How high a fixture's supply stands above the pipe, and where its drop hangs, in levels.
EP.PIPE_FEED_RISE = 0.24
EP.PIPE_FEED_DROP = 0.46

--- Texture numbers, which is what a quad carries: the window turns them into Textures once.
EP.PIPE_TEX_BODY, EP.PIPE_TEX_CAP, EP.PIPE_TEX_HUB = 1, 2, 3
EP.PIPE_TEX_BAND, EP.PIPE_TEX_FLANGE, EP.PIPE_TEX_DROP = 4, 5, 6
EP.PIPE_TEX_FILES = {
	"media/ui/LGEP/pipe_body.png", "media/ui/LGEP/pipe_cap.png", "media/ui/LGEP/pipe_hub.png",
	"media/ui/LGEP/pipe_band.png", "media/ui/LGEP/pipe_flange.png", "media/ui/LGEP/pipe_drop.png",
}
local T_BODY, T_CAP, T_HUB = EP.PIPE_TEX_BODY, EP.PIPE_TEX_CAP, EP.PIPE_TEX_HUB
local T_BAND, T_FLANGE = EP.PIPE_TEX_BAND, EP.PIPE_TEX_FLANGE

--------------------------------------------------------------------------------
-- which way each tile runs
--------------------------------------------------------------------------------

local function tkey(x, y) return x .. "," .. y end

--- How deep (x, y) is in an area's rectangle: 0 on its outermost ring, 1 a tile in, and -1
--- on the ring of tiles just outside it, corners included - the tiles that TOUCH it.
local function depthIn(a, x, y)
	local d = x - a.x1
	local v = a.x2 - x;  if v < d then d = v end
	v = y - a.y1;        if v < d then d = v end
	v = a.y2 - y;        if v < d then d = v end
	return d
end

--- Every pipe tile on `level`, and the doors it uses.
---
---     floors   list of { x, y, z, net }                        every floor pipe the window knows
---     walls    list of { x, y, z, north, net }                 every wall pipe
---     areas    list of { x1, y1, x2, y2, z1, z2, net }         building areas, one per building
---
--- Returns `tiles` (key "x,y" -> tile) and `order`, the same tiles north to south, west to east,
--- so every choice below is made in the same order on every machine and every rebuild.  A tile:
---
---     x, y, net
---     door[d]   true when the tile's pipe runs out through door d
---     pipe[d]   ... to a pipe on the neighbouring tile
---     riser[d]  ... to a wall pipe on that edge
---     flange[d] ... into a building's area: the index of the area
---     n         how many doors
---     tapped    true when the tile stands inside a building of its own network
function EP.pipeArtLinks(level, floors, walls, areas)
	local tiles, order = {}, {}
	for i = 1, #floors do
		local f = floors[i]
		if f.z == level then
			local t = { x = f.x, y = f.y, net = f.net or 0, door = {}, pipe = {}, riser = {}, flange = {}, n = 0 }
			tiles[tkey(f.x, f.y)] = t
			order[#order + 1] = t
		end
	end
	table.sort(order, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)

	local function open(t, d)
		if not t.door[d] then
			t.door[d] = true
			t.n = t.n + 1
		end
	end

	-- WALL PIPES WITH AN END AT THIS LEVEL: a riser's foot on its own floor, its top on the one
	-- above.  Keyed by the edge as its owner square sees it, like everything else.
	local edge = {}
	for i = 1, #walls do
		local w = walls[i]
		if w.z == level or w.z + 1 == level then
			edge[w.x .. "," .. w.y .. (w.north and ",N" or ",W")] = true
		end
	end

	for i = 1, #order do
		local t = order[i]
		local x, y = t.x, t.y
		for d = 1, 8 do
			if tiles[tkey(x + DX[d], y + DY[d])] then
				local draw = true
				if not isEdge(d) then
					-- A diagonal is drawn only where no pipe on either tile between the pair
					-- already turns that corner.  See the file note.
					local a, b = d - 1, d % 8 + 1
					if tiles[tkey(x + DX[a], y + DY[a])] or tiles[tkey(x + DX[b], y + DY[b])] then
						draw = false
					end
				end
				if draw then
					t.pipe[d] = true
					open(t, d)
				end
			end
		end
		-- The four edges, as the wall that owns each: a tile's south edge is the north wall of
		-- the tile below it, its east edge the west wall of the tile beside it.
		if edge[x .. "," .. y .. ",N"] then t.riser[N] = true; open(t, N) end
		if edge[x .. "," .. (y + 1) .. ",N"] then t.riser[S] = true; open(t, S) end
		if edge[x .. "," .. y .. ",W"] then t.riser[W] = true; open(t, W) end
		if edge[(x + 1) .. "," .. y .. ",W"] then t.riser[E] = true; open(t, E) end
	end

	-- BUILDINGS.  Only areas drawn at this level, and only a tile's own network's: a pipe
	-- beside a house it is not joined to is exactly what the colours are there to show, and a
	-- flange would say the opposite.
	local level_areas = {}
	for i = 1, #areas do
		local a = areas[i]
		if (a.net or 0) > 0 and level >= a.z1 and level <= a.z2 then
			level_areas[#level_areas + 1] = { x1 = a.x1, y1 = a.y1, x2 = a.x2, y2 = a.y2, net = a.net, id = i }
		end
	end

	-- Each tile's relation to each area it is near: INSIDE when it stands a tile or more in (a
	-- run inside a house is in the house's plumbing, and needs no flange to say so), TOUCHING
	-- when it is on the area's edge or just outside it.  An area's rectangle is its building's
	-- plan grown by one, so the edge ring is the yard a barrel is already accepted in.
	for i = 1, #order do
		local t = order[i]
		t.touch, t.inside = {}, {}
		for k = 1, #level_areas do
			local a = level_areas[k]
			if a.net == t.net then
				local depth = depthIn(a, t.x, t.y)
				if depth >= 1 then
					t.inside[#t.inside + 1] = { area = a, depth = depth }
				elseif depth >= -1 then
					t.touch[#t.touch + 1] = { area = a, depth = depth }
				end
			end
		end
	end

	-- The door a flange to `a` goes through: one that leads deeper into the area, as far round
	-- from the doors the tile already uses as there is (a run arriving from the east meets a
	-- house on its west in a straight line), an edge before a corner when it is a tie.
	local function flangeDoor(t, touch)
		local best, bestScore = nil, -1
		for d = 1, 8 do
			if not t.door[d] and depthIn(touch.area, t.x + DX[d], t.y + DY[d]) > touch.depth then
				local far = 4
				for e = 1, 8 do
					if t.door[e] then
						local s = turnSteps(d, e)
						if s < far then far = s end
					end
				end
				local score = far * 2 + (isEdge(d) and 1 or 0)
				if score > bestScore then best, bestScore = d, score end
			end
		end
		return best
	end

	local joined = {}      -- tile -> area id -> true, for the second pass
	local function flangeTo(t, touch)
		local d = flangeDoor(t, touch)
		if not d then return false end
		t.flange[d] = touch.area.id
		open(t, d)
		joined[t] = joined[t] or {}
		joined[t][touch.area.id] = true
		return true
	end

	-- FIRST, THE ENDS OF RUNS.  A run that stops beside a building goes into it.  Taken before
	-- any flange is added, so both sides of a one-tile pipe are ends.
	--
	-- AND A TILE BETWEEN TWO BUILDINGS FLANGES INTO BOTH, even one it stands inside.  LG's case:
	-- two houses with no gap between them are joined by one pipe, and with no gap that pipe is
	-- on one house's own ground.  Drawn as in one house and flanged into the other it reads as
	-- a stub; drawn as a flange into each, it reads as what it is.
	local ends = {}
	for i = 1, #order do
		if order[i].n <= 1 then ends[#ends + 1] = order[i] end
	end
	for i = 1, #ends do
		local t = ends[i]
		for k = 1, #t.touch do flangeTo(t, t.touch[k]) end
		if #t.touch + #t.inside >= 2 then
			for k = 1, #t.inside do flangeTo(t, t.inside[k]) end
		end
	end
	for i = 1, #order do
		local t = order[i]
		for k = 1, #t.inside do
			if not (joined[t] and joined[t][t.inside[k].area.id]) then t.tapped = true end
		end
	end

	-- THEN, AT LEAST ONE PER RUN.  A run that only brushes a building part-way along - a loop,
	-- or a run past a house's corner - is joined to it all the same, so it gets one flange, on
	-- the tile with the fewest doors, nearest the building.  Runs are what the doors join.
	local parent = {}
	local function find(t)
		while parent[t] ~= t do
			parent[t] = parent[parent[t]]
			t = parent[t]
		end
		return t
	end
	for i = 1, #order do parent[order[i]] = order[i] end
	for i = 1, #order do
		local t = order[i]
		for d = 1, 8 do
			if t.pipe[d] then
				local o = tiles[tkey(t.x + DX[d], t.y + DY[d])]
				local ra, rb = find(t), find(o)
				if ra ~= rb then parent[ra] = rb end
			end
		end
	end

	local runs, runOrder = {}, {}
	for i = 1, #order do
		local t = order[i]
		local r = find(t)
		local run = runs[r]
		if not run then
			run = { tiles = {}, tapped = {}, joined = {} }
			runs[r] = run
			runOrder[#runOrder + 1] = run
		end
		run.tiles[#run.tiles + 1] = t
		for id in pairs(joined[t] or {}) do run.joined[id] = true end
	end

	for i = 1, #runOrder do
		local run = runOrder[i]
		-- A run with a tile inside the building is in it already.
		for j = 1, #run.tiles do
			local t = run.tiles[j]
			for k = 1, #level_areas do
				if t.net == level_areas[k].net and depthIn(level_areas[k], t.x, t.y) >= 1 then
					run.tapped[level_areas[k].id] = true
				end
			end
		end
		for k = 1, #level_areas do
			local id = level_areas[k].id
			if not run.joined[id] and not run.tapped[id] then
				local best, bestTouch = nil, nil
				for j = 1, #run.tiles do
					local t = run.tiles[j]
					for m = 1, #t.touch do
						local touch = t.touch[m]
						if touch.area.id == id and flangeDoor(t, touch) then
							if not best or t.n < best.n or (t.n == best.n and touch.depth > bestTouch.depth) then
								best, bestTouch = t, touch
							end
						end
					end
				end
				if best then
					flangeTo(best, bestTouch)
					run.joined[id] = true
				end
			end
		end
	end

	return tiles, order
end

--------------------------------------------------------------------------------
-- quads
--------------------------------------------------------------------------------

--- A quad is thirteen numbers in a flat list: a texture number, then four corners x, y, z,
--- in the order SpriteRenderer maps a texture's top-left, top-right, bottom-right and
--- bottom-left to.  World coordinates, relative to the drawing's own origin, so a world
--- position in the tens of thousands never has to survive a float in the arithmetic.
local function quad(list, tex, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4)
	local n = #list
	list[n + 1] = tex
	list[n + 2] = x1;  list[n + 3] = y1;  list[n + 4] = z1
	list[n + 5] = x2;  list[n + 6] = y2;  list[n + 7] = z2
	list[n + 8] = x3;  list[n + 9] = y3;  list[n + 10] = z3
	list[n + 11] = x4; list[n + 12] = y4; list[n + 13] = z4
end

--- A texture laid flat on the floor, square, centred on a point.
local function flat(list, tex, cx, cy, z, r)
	quad(list, tex, cx - r, cy - r, z, cx + r, cy - r, z, cx + r, cy + r, z, cx - r, cy + r, z)
end

--- A band or a flange across a pipe, at a point, for a pipe running along (dx, dy).  u runs
--- across the pipe, v along it.
local function across(list, tex, cx, cy, z, dx, dy, halfLen, halfThick)
	local nx, ny = -dy, dx
	quad(list, tex,
		cx + nx * halfLen - dx * halfThick, cy + ny * halfLen - dy * halfThick, z,
		cx - nx * halfLen - dx * halfThick, cy - ny * halfLen - dy * halfThick, z,
		cx - nx * halfLen + dx * halfThick, cy - ny * halfLen + dy * halfThick, z,
		cx + nx * halfLen + dx * halfThick, cy + ny * halfLen + dy * halfThick, z)
end

--- A strip of pipe through points (px, py) with unit tangents (tx, ty).  Each end of each
--- quad is square to the curve AT THAT POINT, so neighbouring quads share their corners
--- exactly - and so does the next tile's strip, whose curve leaves the shared door along the
--- same line.  The normal can come out reversed between two strips that walk the door in
--- opposite directions; that swaps two corners, which the body texture, the same on both
--- sides of its centre line, cannot show.
local function strip(list, px, py, tx, ty, z)
	for i = 1, #px - 1 do
		local ax, ay = -ty[i] * HW, tx[i] * HW
		local bx, by = -ty[i + 1] * HW, tx[i + 1] * HW
		quad(list, T_BODY,
			px[i] + ax, py[i] + ay, z,
			px[i] - ax, py[i] - ay, z,
			px[i + 1] - bx, py[i + 1] - by, z,
			px[i + 1] + bx, py[i + 1] + by, z)
	end
end

--- The curve from door a to door b of the tile at (ox, oy), as points and tangents, and the
--- point on it nearest the middle of the tile - where a fixture's supply is drawn off.
---
--- A cubic Bezier leaving a straight in through its door and leaving b straight out through
--- its own.  The handles are the length that makes a symmetric bend a circular arc,
--- (4/3) tan(phi/4) of the radius, which puts a quarter turn between two edges on the
--- quarter circle a plumber's elbow is; the other bends take the same rule and come out as
--- the smooth S of an edge handing over to a corner.
function EP.pipeArtCurve(a, b, ox, oy)
	local x0, y0 = ox + AX[a], oy + AY[a]
	local x3, y3 = ox + AX[b], oy + AY[b]
	local sx, sy = -OX[a], -OY[a]           -- in through a
	local ex, ey = OX[b], OY[b]             -- out through b
	local chord = math.sqrt((x3 - x0) ^ 2 + (y3 - y0) ^ 2)

	if turnSteps(a, b) == 4 then
		-- Straight across: one quad.
		return { x0, x3 }, { y0, y3 }, { sx, sx }, { sy, sy }, (x0 + x3) / 2, (y0 + y3) / 2
	end

	local cosPhi = sx * ex + sy * ey
	if cosPhi > 1 then cosPhi = 1 elseif cosPhi < -1 then cosPhi = -1 end
	local phi = math.acos(cosPhi)
	local h
	if phi < 1e-4 then
		h = chord / 3
	else
		h = chord * (2 / 3) * math.tan(phi / 4) / math.sin(phi / 2)
	end
	local x1, y1 = x0 + sx * h, y0 + sy * h
	local x2, y2 = x3 - ex * h, y3 - ey * h

	-- A segment per 22.5 degrees of turn, and never fewer than three: smooth at the zoom it is
	-- played at, and every one of them is a draw call.
	local segs = math.max(3, math.ceil(phi / (math.pi / 8)))
	local px, py, tx, ty = {}, {}, {}, {}
	for i = 0, segs do
		local t = i / segs
		local u = 1 - t
		local b0, b1, b2, b3 = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
		px[i + 1] = b0 * x0 + b1 * x1 + b2 * x2 + b3 * x3
		py[i + 1] = b0 * y0 + b1 * y1 + b2 * y2 + b3 * y3
		local dx = 3 * u * u * (x1 - x0) + 6 * u * t * (x2 - x1) + 3 * t * t * (x3 - x2)
		local dy = 3 * u * u * (y1 - y0) + 6 * u * t * (y2 - y1) + 3 * t * t * (y3 - y2)
		local len = math.sqrt(dx * dx + dy * dy)
		if len < 1e-9 then dx, dy, len = sx, sy, 1 end
		tx[i + 1], ty[i + 1] = dx / len, dy / len
	end
	local mid = math.floor(segs / 2) + 1
	local cx, cy = px[mid], py[mid]
	if segs % 2 == 1 then
		-- Odd: the middle is between two samples; the curve is near enough straight there.
		cx, cy = (px[mid] + px[mid + 1]) / 2, (py[mid] + py[mid + 1]) / 2
	end
	return px, py, tx, ty, cx, cy
end

--- From door d to the middle of the tile.
local function stub(list, d, ox, oy, z)
	local x0, y0 = ox + AX[d], oy + AY[d]
	local sx, sy = -OX[d], -OY[d]
	strip(list, { x0, ox + 0.5 }, { y0, oy + 0.5 }, { sx, sx }, { sy, sy }, z)
end

--------------------------------------------------------------------------------
-- the drawing
--------------------------------------------------------------------------------

--- Everything to draw at `level`, as groups a frame can cull whole.
---
---     supplied(net) -> bool        blue or white
---     bx, by                       the origin every coordinate is relative to
---
--- Returns { tiles = { group... }, risers = { group... }, drops = {}, dropAt = {} }.  `drops`
--- starts empty: the fixtures standing in a building's area are found by the window a few
--- squares a frame (EP.pipeArtAddDrop), because finding them is world access and this is not.
--- A group:
---
---     cx, cy, cz       its middle, for culling
---     blue             its network is supplied
---     body, fit        quads: lengths of pipe, then the fittings drawn over them
---     x, y             (tiles) the tile, in world coordinates
---     tapX, tapY       (tiles) where a fixture's supply comes off the pipe
---     feed             (tiles) the supply's quads, drawn only while `fed` is true
function EP.pipeArtBuild(level, floors, walls, areas, supplied, bx, by)
	local tiles, order = EP.pipeArtLinks(level, floors, walls, areas)
	local art = { tiles = {}, risers = {}, drops = {}, dropAt = {}, level = level, bx = bx, by = by,
		links = tiles }
	local z = level

	for i = 1, #order do
		local t = order[i]
		local ox, oy = t.x - bx, t.y - by
		local g = { x = t.x, y = t.y, cx = ox + 0.5, cy = oy + 0.5, cz = z, body = {}, fit = {},
			blue = supplied(t.net), net = t.net, tile = t }
		local body, fit = g.body, g.fit

		local doors = {}
		for d = 1, 8 do if t.door[d] then doors[#doors + 1] = d end end

		g.tapX, g.tapY = ox + 0.5, oy + 0.5
		if #doors == 0 then
			-- A pipe on its own: a short length lying across the tile, closed at both ends.
			strip(body, { ox + 0.22, ox + 0.78 }, { oy + 0.5, oy + 0.5 }, { 1, 1 }, { 0, 0 }, z)
			flat(fit, T_CAP, ox + 0.22, oy + 0.5, z, CAP_R)
			flat(fit, T_CAP, ox + 0.78, oy + 0.5, z, CAP_R)
			if t.tapped then flat(fit, T_HUB, ox + 0.5, oy + 0.5, z, HUB_R) end
		elseif #doors == 1 then
			stub(body, doors[1], ox, oy, z)
			flat(fit, t.tapped and T_HUB or T_CAP, ox + 0.5, oy + 0.5, z, t.tapped and HUB_R or CAP_R)
		elseif #doors == 2 then
			local px, py, tx, ty, cx, cy = EP.pipeArtCurve(doors[1], doors[2], ox, oy)
			strip(body, px, py, tx, ty, z)
			g.tapX, g.tapY = cx, cy
		else
			-- A JUNCTION.  The straightest pair runs through as one pipe when there is a pair
			-- facing each other, and every other door comes in to a fitting in the middle.
			local through = nil
			for p = 1, #doors do
				for q = p + 1, #doors do
					if turnSteps(doors[p], doors[q]) == 4 then
						if not through or (isEdge(doors[p]) and not isEdge(through[1])) then
							through = { doors[p], doors[q] }
						end
					end
				end
			end
			for p = 1, #doors do
				local d = doors[p]
				if not through or (d ~= through[1] and d ~= through[2]) then stub(body, d, ox, oy, z) end
			end
			if through then
				local px, py, tx, ty = EP.pipeArtCurve(through[1], through[2], ox, oy)
				strip(body, px, py, tx, ty, z)
			end
			flat(fit, T_HUB, ox + 0.5, oy + 0.5, z, HUB_R)
		end

		-- Fittings at the doors.  A coupling between two pipes is drawn by ONE of the pair -
		-- the one it leaves to the east and south of - so a joint is never drawn twice.
		for p = 1, #doors do
			local d = doors[p]
			local ax, ay = ox + AX[d], oy + AY[d]
			if t.flange[d] then
				across(fit, T_FLANGE, ax, ay, z, OX[d], OY[d], FLANGE_L, FLANGE_T)
			elseif t.pipe[d] and d >= NE and d <= S then
				across(fit, T_BAND, ax, ay, z, OX[d], OY[d], BAND_L, BAND_T)
			end
		end

		-- A FIXTURE'S SUPPLY, built now and drawn only while one is fed: a tee on the pipe and a
		-- short upright off it.  Upright along the world's (1, -1), which is the one direction
		-- the projection draws exactly across the screen, so it stands like a round pipe does.
		local feed = {}
		local ux, uy = 0.7071 * HW * 0.8, -0.7071 * HW * 0.8
		flat(feed, T_HUB, g.tapX, g.tapY, z, HUB_R)
		quad(feed, T_BODY,
			g.tapX - ux, g.tapY - uy, z,
			g.tapX + ux, g.tapY + uy, z,
			g.tapX + ux, g.tapY + uy, z + EP.PIPE_FEED_RISE,
			g.tapX - ux, g.tapY - uy, z + EP.PIPE_FEED_RISE)
		flat(feed, T_CAP, g.tapX, g.tapY, z + EP.PIPE_FEED_RISE, CAP_R)
		g.feed = feed

		art.tiles[#art.tiles + 1] = g
	end

	-- RISERS.  A wall pipe at level wz climbs from wz to wz + 1, so it is drawn from the floor
	-- it stands on and from the floor it reaches.  Up the middle of its wall, its width along
	-- the wall, which puts its foot exactly where a floor pipe's curve leaves through that edge.
	local floorAt, wallAt = {}, {}
	for i = 1, #floors do
		local f = floors[i]
		floorAt[f.x .. "," .. f.y .. "," .. f.z] = true
	end
	for i = 1, #walls do
		local w = walls[i]
		wallAt[w.x .. "," .. w.y .. "," .. w.z .. (w.north and ",N" or ",W")] = true
	end

	for i = 1, #walls do
		local w = walls[i]
		if w.z == level or w.z + 1 == level then
			local ax, ay = w.x - bx + (w.north and 0.5 or 0), w.y - by + (w.north and 0 or 0.5)
			local wx, wy = (w.north and HW or 0), (w.north and 0 or HW)
			local g = { cx = ax, cy = ay, cz = w.z + 0.5, body = {}, fit = {}, blue = supplied(w.net or 0),
				net = w.net, wall = w }
			quad(g.body, T_BODY,
				ax - wx, ay - wy, w.z,
				ax + wx, ay + wy, w.z,
				ax + wx, ay + wy, w.z + 1,
				ax - wx, ay - wy, w.z + 1)

			-- Each end: nothing where another riser carries on, an elbow where a floor pipe on
			-- either side meets it, and a collar through the floor where nothing does.
			local sx, sy
			if w.north then sx, sy = w.x, w.y - 1 else sx, sy = w.x - 1, w.y end
			local side = w.north and ",N" or ",W"
			for _, endZ in ipairs({ w.z, w.z + 1 }) do
				local continues = wallAt[w.x .. "," .. w.y .. "," .. (endZ == w.z and w.z - 1 or w.z + 1) .. side]
				if not continues then
					if floorAt[w.x .. "," .. w.y .. "," .. endZ] or floorAt[sx .. "," .. sy .. "," .. endZ] then
						flat(g.fit, T_HUB, ax, ay, endZ, HUB_R)
					else
						-- Across the riser's foot, as a flange across a floor pipe would be:
						-- its length along the wall.
						across(g.fit, T_FLANGE, ax, ay, endZ, (w.north and 0 or 1), (w.north and 1 or 0),
							FLANGE_L, FLANGE_T)
					end
				end
			end
			art.risers[#art.risers + 1] = g
		end
	end

	return art
end

--- A fixture standing in a building's area, at (x, y) on the drawing's level, to hang a drop
--- over while it is fed.  Kept in a list for the frame's walk and a map for the window's sweep;
--- adding one twice is a no-op.  Returns the entry.
function EP.pipeArtAddDrop(art, x, y, blue)
	local key = x .. "," .. y
	local d = art.dropAt[key]
	if d then
		d.blue = blue
		return d
	end
	d = { key = key, x = x, y = y, cx = x - art.bx + 0.5, cy = y - art.by + 0.5, cz = art.level,
		blue = blue, fed = false }
	art.drops[#art.drops + 1] = d
	art.dropAt[key] = d
	return d
end

--- And gone again - the fixture was picked up.  The last entry takes its place, so the list
--- stays dense for the round-robin that walks it.
function EP.pipeArtRemoveDrop(art, x, y)
	local key = x .. "," .. y
	local d = art.dropAt[key]
	if not d then return end
	art.dropAt[key] = nil
	local list = art.drops
	for i = 1, #list do
		if list[i] == d then
			list[i] = list[#list]
			list[#list] = nil
			return
		end
	end
end

--- The screen, as a linear map from the drawing's coordinates.  The projection is affine -
--- IsoUtils.XToScreen and YToScreen are sums of x, y and z each times a constant, divided by
--- the zoom - so four points of it are the whole of it, and the rest is arithmetic in Lua
--- rather than two Java calls per corner.  The spans are long so the engine's float rounding
--- at a world position in the thousands is spread over many tiles rather than one.
function EP.pipeArtBasis(playerNum, bx, by, z)
	local SPAN, ZSPAN = 64, 4
	local ox, oy = isoToScreenX(playerNum, bx, by, z), isoToScreenY(playerNum, bx, by, z)
	local xx = (isoToScreenX(playerNum, bx + SPAN, by, z) - ox) / SPAN
	local xy = (isoToScreenY(playerNum, bx + SPAN, by, z) - oy) / SPAN
	local yx = (isoToScreenX(playerNum, bx, by + SPAN, z) - ox) / SPAN
	local yy = (isoToScreenY(playerNum, bx, by + SPAN, z) - oy) / SPAN
	local zx = (isoToScreenX(playerNum, bx, by, z + ZSPAN) - ox) / ZSPAN
	local zy = (isoToScreenY(playerNum, bx, by, z + ZSPAN) - oy) / ZSPAN
	return { ox = ox, oy = oy, z0 = z, xx = xx, xy = xy, yx = yx, yy = yy, zx = zx, zy = zy }
end

--- Hand every quad of `list` to `emit(tex, tlx, tly, trx, try, brx, bry, blx, bly)`.
local function emitList(list, B, emit)
	local ox, oy, z0 = B.ox, B.oy, B.z0
	local xx, xy, yx, yy, zx, zy = B.xx, B.xy, B.yx, B.yy, B.zx, B.zy
	for i = 1, #list, 13 do
		local x1, y1, z1 = list[i + 1], list[i + 2], list[i + 3] - z0
		local x2, y2, z2 = list[i + 4], list[i + 5], list[i + 6] - z0
		local x3, y3, z3 = list[i + 7], list[i + 8], list[i + 9] - z0
		local x4, y4, z4 = list[i + 10], list[i + 11], list[i + 12] - z0
		emit(list[i],
			ox + x1 * xx + y1 * yx + z1 * zx, oy + x1 * xy + y1 * yy + z1 * zy,
			ox + x2 * xx + y2 * yx + z2 * zx, oy + x2 * xy + y2 * yy + z2 * zy,
			ox + x3 * xx + y3 * yx + z3 * zx, oy + x3 * xy + y3 * yy + z3 * zy,
			ox + x4 * xx + y4 * yx + z4 * zx, oy + x4 * xy + y4 * yy + z4 * zy)
	end
end

--- Draw it.  `emit(tex, tlx, tly, trx, try, brx, bry, blx, bly, blue)` puts one quad on the
--- screen; `screenW`/`screenH`, when known, cull every group whose middle is further off the
--- screen than a group can reach; `now` bobs the drops.
---
--- IN FOUR PASSES, so what stands up is drawn over what lies down whatever order the groups
--- are in: every length on the floor, the floor's fittings, the risers, then the supplies and
--- the drops.  A group culled in the first pass is skipped in the rest.
---
--- Returns how many quads it drew, which is what a suite bounds.
function EP.pipeArtDraw(art, B, emit, screenW, screenH, now)
	local count = 0
	local blue = false
	local function out(tex, a, b, c, d, e, f, g, h)
		count = count + 1
		emit(tex, a, b, c, d, e, f, g, h, blue)
	end

	-- A group reaches at most a tile and a half across and a level up from its middle.
	local reachX = (math.abs(B.xx) + math.abs(B.yx)) * 1.5 + math.abs(B.zx)
	local reachY = (math.abs(B.xy) + math.abs(B.yy)) * 1.5 + math.abs(B.zy)
	local function visible(g)
		if not screenW then return true end
		local dz = g.cz - B.z0
		local sx = B.ox + g.cx * B.xx + g.cy * B.yx + dz * B.zx
		local sy = B.oy + g.cx * B.xy + g.cy * B.yy + dz * B.zy
		return sx > -reachX and sx < screenW + reachX and sy > -reachY and sy < screenH + reachY
	end

	local tiles, risers = art.tiles, art.risers
	local shown = {}
	for i = 1, #tiles do
		local g = tiles[i]
		if visible(g) then
			shown[#shown + 1] = g
			blue = g.blue
			emitList(g.body, B, out)
		end
	end
	for i = 1, #shown do
		blue = shown[i].blue
		emitList(shown[i].fit, B, out)
	end
	for i = 1, #risers do
		local g = risers[i]
		if visible(g) then
			blue = g.blue
			emitList(g.body, B, out)
			emitList(g.fit, B, out)
		end
	end

	-- The drop, facing the screen: it is a sign, not a thing on the floor.  Sized off the
	-- projection so it scales with the zoom, and bobbing a little, slowly, so the eye finds it.
	local unit = math.sqrt((B.xx - B.yx) ^ 2 + (B.xy - B.yy) ^ 2) * 0.7071
	local dw = unit * 0.30
	local dh = dw * 1.5
	local bob = now and math.sin((now % 2000) / 2000 * 2 * math.pi) * 0.025 or 0
	local function drop(px, py, cz)
		local dz = cz - B.z0 + EP.PIPE_FEED_DROP + bob
		local sx = B.ox + px * B.xx + py * B.yx + dz * B.zx
		local sy = B.oy + px * B.xy + py * B.yy + dz * B.zy
		out(EP.PIPE_TEX_DROP, sx - dw / 2, sy - dh, sx + dw / 2, sy - dh, sx + dw / 2, sy, sx - dw / 2, sy)
	end
	for i = 1, #shown do
		local g = shown[i]
		if g.fed then
			blue = g.blue
			emitList(g.feed, B, out)
			drop(g.tapX, g.tapY, g.cz)
		end
	end

	-- AND EVERY FIXTURE IN A BUILDING'S AREA.  The same drop at the same height over the
	-- middle of its tile, with nothing under it: the building's own plumbing is not drawn as
	-- pipe, so a tee would be a fitting on nothing.
	local drops = art.drops or {}
	for i = 1, #drops do
		local d = drops[i]
		if d.fed and visible(d) then
			blue = d.blue
			drop(d.cx, d.cy, d.cz)
		end
	end
	return count
end

--- Could a plumbable fixture be standing on this square?  ONE question of the square, not a
--- walk of its objects: IsoGridSquare.RecalcProperties rebuilds the square's properties as
--- every object's sprite flags OR'd together (PropertyContainer.AddProperties), so a square
--- with no waterPiped object on it says so in one call.  It is what makes sweeping a
--- building's whole area for its fixtures affordable.  Blueprints are left out of that OR by
--- the engine, which is right here too: a sink not yet built is not a fixture.
function EP.pipeArtMayHoldFixture(square)
	if not square then return false end
	local props = square.getProperties and square:getProperties()
	if not props then return true end
	return props:has(IsoFlagType.waterPiped) == true
end

--- Is the fixture on (x, y, z) plumbed in?  A plumbable fixture stands there and is plumbed:
--- the engine's flag, or the authority's key where the engine drops the flag on the way to a
--- client (a washing machine; see EP.KEY_PIPED).  Asked of a pipe tile and of a fixture in a
--- building's area alike.
function EP.pipeArtFed(x, y, z)
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	if not square or not EP.pipeArtMayHoldFixture(square) then return false end
	local fixture = EP.fixtureOnSquare(square)
	if not fixture then return false end
	if fixture.getUsesExternalWaterSource and fixture:getUsesExternalWaterSource() then return true end
	if fixture.hasModData and fixture:hasModData() and fixture:getModData()[EP.KEY_PIPED] then return true end
	return false
end

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
if EP.checkBuild then
	EP.checkBuild("LGEPPipeDraw.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPPipeDraw.lua is from build 3.3.1 and LGEPCore.lua is from a build"
		.. " too old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
