--
-- Extended Plumbing - pipes, the part both sides ask.
--
-- A pipe does one thing: it decides what is CONNECTED.  A floor pipe is one tile at one
-- level; a wall pipe is one wall edge, joining the floor it is on to the floor above.
-- Pieces join when their footprints touch, eight ways, and a piece touching a building's
-- plumbing area joins that building.  A building never joins a building on its own - a
-- terrace would share one supply - so buildings are joined only by pipes somebody laid.
--
-- What a pipe does NOT do is lift water.  Gravity and the pump are EP.serves, exactly as
-- inside a house, and nothing here touches them.  See plans/lgep-pipe-network.md.
--
-- This file is the arithmetic and the vocabulary: names, keys, the wall-edge rule, the
-- footprint and touch rule, the union-find that turns pieces into networks, the rectangle
-- merge the window draws with, and the copy of the pieces a client holds.  No world access
-- except through the callback derivation is handed, so a suite can run it with no world.
--

require "LGExtendedPlumbing/LGEPCore"

local EP = LGEP

--------------------------------------------------------------------------------
-- names
--------------------------------------------------------------------------------

--- ONE IRON PIPE A PIECE.  Base.MetalPipe is the item whose English name is "Iron Pipe";
--- the short type is what getItemCountRecurse and getAllTypeRecurse take everywhere in
--- vanilla, the full one is what AddItems takes.
EP.PIPE_TYPE = "MetalPipe"
EP.PIPE_ITEM = "Base.MetalPipe"
EP.PIPE_COST = 1

--- The four things the window can ask the authority to do.  Strings, because they cross
--- the wire as a timed action's parameter.
EP.PIPE_ACT_LAY       = "lay"
EP.PIPE_ACT_LIFT      = "lift"
EP.PIPE_ACT_LAY_WALL  = "laywall"
EP.PIPE_ACT_LIFT_WALL = "liftwall"

--- Why a lay or a lift was refused.  HERE and not in the server file, because the window
--- compares against them - LGEE learned that one the hard way: defined server-side, every
--- one of them was nil on the reading side and every refusal read as the first.
EP.PIPE_NO_PIPE     = "nopipe"      -- no iron pipe in the bag
EP.PIPE_NO_WRENCH   = "nowrench"    -- no working pipe wrench
EP.PIPE_NO_SQUARE   = "nosquare"    -- nothing there to lay it on
EP.PIPE_OCCUPIED    = "occupied"    -- a pipe of ours is there already
EP.PIPE_NOT_OURS    = "notours"     -- nothing of ours to lift
EP.PIPE_NO_WALL     = "nowall"      -- a wall pipe needs a wall
EP.PIPE_NO_WALK     = "nowalk"      -- no way to get there
EP.PIPE_DISABLED    = "disabled"    -- the mod is switched off

--- The wire.  Client to authority: HELLO asks for the set, AREA asks what is round the
--- player.  Authority to client: PIPES is the set, to everybody; AREA_RESULT and PIPE_DONE
--- are addressed to the one player who asked.
EP.COMMAND_PIPE_HELLO  = "pipehello"
EP.COMMAND_PIPE_AREA   = "pipearea"
EP.COMMAND_PIPES       = "pipes"
EP.COMMAND_PIPE_AREA_RESULT = "pipearearesult"
EP.COMMAND_PIPE_DONE   = "pipedone"

--- The global ModData table the pieces are saved in.  LGEP's first world-level save.
EP.PIPE_STORE = "LGExtendedPlumbing"

--------------------------------------------------------------------------------
-- keys
--------------------------------------------------------------------------------

--- A floor pipe is keyed exactly like everything else in this mod.
function EP.pipeKey(x, y, z)
	return EP.key(x, y, z)
end

--- A WALL PIPE IS KEYED ON THE SQUARE THAT OWNS THE WALL.
---
--- The engine stores a wall only as the north or west edge of a square (there is no
--- WallS and no WallE), so a building's south and east walls belong to the square outside
--- them.  Keying the pipe on that owner means both sides of a wall find the same row -
--- "pipe the wall once, lift it from either side" - with nothing to keep in step.
function EP.wallPipeKey(x, y, z, north)
	return x .. "," .. y .. "," .. z .. (north and ",N" or ",W")
end

--- Which square owns the wall on `side` of the tile (x, y), and which way it faces.
---
--- `side` is "N", "S", "E" or "W" as seen from the tile the player is pointing at.  The
--- south edge of a tile is the north wall of the tile below it; the east edge is the
--- west wall of the tile to its right.  Everything after this speaks only N and W.
function EP.wallOwner(x, y, side)
	if side == "N" then return x, y, true end
	if side == "W" then return x, y, false end
	if side == "S" then return x, y + 1, true end
	if side == "E" then return x + 1, y, false end
	return nil
end

--- The two tiles a wall stands between: its owner, and the one across it.
function EP.wallSides(x, y, north)
	if north then return x, y, x, y - 1 end
	return x, y, x - 1, y
end

--- The edge of a tile nearest a point inside it, from the fractional world position the
--- cursor is at.  `fx`, `fy` are the fractions, 0..1, west-to-east and north-to-south.
---
--- Nearest rather than a quadrant test, so a tile with walls on two sides answers the side
--- the player is actually pointing at, and a click near the middle still picks one.
function EP.nearestEdge(fx, fy)
	local dn, ds, dw, de = fy, 1 - fy, fx, 1 - fx
	local best, side = dn, "N"
	if ds < best then best, side = ds, "S" end
	if dw < best then best, side = dw, "W" end
	if de < best then side = "E" end
	return side
end

--------------------------------------------------------------------------------
-- footprints, and what touching means
--------------------------------------------------------------------------------

--- The tiles a piece occupies, for the purpose of JOINING.
---
--- A floor pipe is its own tile.  A wall pipe is both sides of its wall, at its own level
--- and at the level above - it is a riser, so it is at both ends of itself.  Returned as a
--- flat list of x, y, z triples, because the derivation walks it once per piece and a
--- table per tile would be an allocation per tile for nothing.
function EP.pieceFootprint(piece)
	if not piece.wall then
		return { piece.x, piece.y, piece.z }
	end
	local ax, ay, bx, by = EP.wallSides(piece.x, piece.y, piece.north)
	local z = piece.z
	return { ax, ay, z, bx, by, z, ax, ay, z + 1, bx, by, z + 1 }
end

--- Do two tiles touch?  The same level, and no further apart than one tile in any
--- direction - corners included, as LG chose.
function EP.tilesTouch(ax, ay, az, bx, by, bz)
	if az ~= bz then return false end
	local dx, dy = ax - bx, ay - by
	return dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1
end

--------------------------------------------------------------------------------
-- pieces into networks
--------------------------------------------------------------------------------

--- TURN PIECES INTO NETWORKS.
---
--- `pieces` is a list of { key, x, y, z, wall = bool, north = bool }.  `areaAt(x, y, z)`
--- answers which BUILDINGS a single tile is part of, as a list of opaque string ids or nil;
--- it is the only world access and the caller supplies it, so this runs in a suite with a
--- table standing in for the world.
---
--- A piece joins every piece whose footprint touches its own, and every building whose
--- area contains a tile its footprint touches.  Buildings are unioned only ever WITH A
--- PIECE, never with each other - that is the whole terrace rule, and it falls out of the
--- union-find without a special case: two buildings end up in one network only if a chain
--- of pieces runs between them.
---
--- COST.  A tile index makes the piece-to-piece test nine table reads per footprint tile.
--- `areaAt` is memoised per tile for the life of the call, so a run of pipes asks each tile
--- of its neighbourhood once however many pieces border it.
---
--- Returns
---     nets        list of { index, pieces = {piece...}, buildings = { id -> {x,y,z} } ,
---                           minX, minY, maxX, maxY, minZ, maxZ }  -- over the pieces
---     pieceNet    piece key -> net index
---     buildingNet building id -> net index
function EP.pipeDerive(pieces, areaAt)
	local parent = {}

	local function find(a)
		local root = a
		while parent[root] ~= root do root = parent[root] end
		-- Path halving on the way back, so a long run does not make every later find walk it.
		while parent[a] ~= root do
			local nextA = parent[a]
			parent[a] = root
			a = nextA
		end
		return root
	end

	local function union(a, b)
		local ra, rb = find(a), find(b)
		if ra ~= rb then parent[ra] = rb end
	end

	--- A TILE KEY THAT IS A NUMBER, NOT A STRING, and it is worth the four lines.
	---
	--- This walk builds one key per footprint tile and then one per NEIGHBOUR - nine a piece -
	--- and `EP.key` is `x .. "," .. y .. "," .. z`, three concatenations and an allocation
	--- each.  At eight thousand pieces that is seventy-two thousand strings built and thrown
	--- away per derivation, and a derivation runs on every lay, every lift, a sixty-second
	--- clock and inside the group walk.  Measured at 512 ms for 8,000 pieces
	--- (`tools/luatest/lgep_probe_derivecost.lua`), and it is Lua churn rather than engine
	--- calls: caching the engine's own answers first took only a fifth of it off.
	---
	--- World z is -32..31 and x, y fit in sixteen bits of chunk-addressable map, so this is
	--- exact for every coordinate the game has - and it is INTERNAL to this function, so no
	--- store, no save and no packet sees it.  `EP.key` stays what it is everywhere else.
	--- ONE INTEGER PER TILE, and it may not wrap.
	---
	--- `(x * 65536 + y) * 64 + (z + 32)` gives z a 6-bit field, 0..63 for z in -32..31 - and a
	--- WALL PIPE'S FOOTPRINT REACHES z + 1 (`EP.pieceFootprint`). At `EP.MAX_LEVEL` (31) that
	--- is 32, so `tileKey(x, y, 32) == tileKey(x, y + 1, -32)`: a riser on the top floor shared
	--- a bucket with a floor pipe one tile north at the bottom of the world, and the two were
	--- unioned into one network. Nobody will meet it - `IsoCell` bounds z to [-32, 31] so the
	--- second tile cannot hold a pipe - but it costs one clamp, and it stops being theoretical
	--- if the world's z range ever moves.
	local function tileKey(x, y, z)
		if z > EP.MAX_LEVEL then z = EP.MAX_LEVEL elseif z < -32 then z = -32 end
		return (x * 65536 + y) * 64 + (z + 32)
	end

	--- AND A NODE ID THAT IS A NUMBER TOO, for the same reason and a bigger saving.
	---
	--- The union-find was keyed on `"P" .. i` and `"B" .. id`: one string built per piece, and
	--- then `find` and `union` walking a string-keyed table up to nine times per piece - about
	--- seventy-two thousand hashed string lookups at eight thousand pieces.  With numeric tile
	--- keys already in, this was what was left of the 512 ms.
	---
	--- A PIECE IS ITS OWN INDEX, and a building takes the next integer after the pieces,
	--- allocated the first time it is touched.  `buildingNode` keeps the id -> node map so
	--- the component walk at the bottom can find its root again.  Nothing outside this
	--- function sees either: `pieceNet` and `buildingNet` are still keyed the way callers
	--- read them.
	local buildingNode, nextNode = {}, #pieces

	local function nodeFor(id)
		local node = buildingNode[id]
		if not node then
			nextNode = nextNode + 1
			node = nextNode
			buildingNode[id] = node
			parent[node] = node
		end
		return node
	end

	-- Every footprint tile, pointing at the pieces standing on it.
	local atTile = {}
	for i = 1, #pieces do
		parent[i] = i
		local fp = EP.pieceFootprint(pieces[i])
		pieces[i].fp = fp
		for t = 1, #fp, 3 do
			local k = tileKey(fp[t], fp[t + 1], fp[t + 2])
			local list = atTile[k]
			if not list then list = {}; atTile[k] = list end
			list[#list + 1] = i
		end
	end

	local memo = {}
	local function buildingsAt(x, y, z)
		local k = tileKey(x, y, z)
		local hit = memo[k]
		if hit == nil then
			hit = (areaAt and areaAt(x, y, z)) or false
			memo[k] = hit
		end
		return hit or nil
	end

	-- Where each building was first touched from, so a caller can re-resolve a structure
	-- whose id will not survive the next wall somebody lays.
	local touchedAt = {}

	for i = 1, #pieces do
		local fp = pieces[i].fp
		for t = 1, #fp, 3 do
			local x, y, z = fp[t], fp[t + 1], fp[t + 2]
			for dy = -1, 1 do
				for dx = -1, 1 do
					local nx, ny = x + dx, y + dy
					local others = atTile[tileKey(nx, ny, z)]
					if others then
						for o = 1, #others do
							if others[o] ~= i then union(i, others[o]) end
						end
					end
					local ids = buildingsAt(nx, ny, z)
					if ids then
						for b = 1, #ids do
							local id = ids[b]
							if buildingNode[id] == nil then
								touchedAt[id] = { x = nx, y = ny, z = z }
							end
							union(i, nodeFor(id))
						end
					end
				end
			end
		end
	end

	-- Number the components in piece order, so the same pieces give the same indices on
	-- every derivation and a client's colours do not shuffle when nothing moved.
	local nets, byRoot = {}, {}
	local pieceNet, buildingNet = {}, {}

	for i = 1, #pieces do
		local piece = pieces[i]
		local root = find(i)
		local net = byRoot[root]
		if not net then
			net = { index = #nets + 1, pieces = {}, buildings = {} }
			nets[#nets + 1] = net
			byRoot[root] = net
		end
		net.pieces[#net.pieces + 1] = piece
		pieceNet[piece.key] = net.index

		local fp = piece.fp
		for t = 1, #fp, 3 do
			local x, y, z = fp[t], fp[t + 1], fp[t + 2]
			if net.minX == nil or x < net.minX then net.minX = x end
			if net.minY == nil or y < net.minY then net.minY = y end
			if net.maxX == nil or x > net.maxX then net.maxX = x end
			if net.maxY == nil or y > net.maxY then net.maxY = y end
			if net.minZ == nil or z < net.minZ then net.minZ = z end
			if net.maxZ == nil or z > net.maxZ then net.maxZ = z end
		end
		piece.fp = nil
	end

	for id, at in pairs(touchedAt) do
		local net = byRoot[find(buildingNode[id])]
		if net then
			net.buildings[id] = at
			buildingNet[id] = net.index
		end
	end

	return nets, pieceNet, buildingNet
end

--------------------------------------------------------------------------------
-- the client's copy, and the one question both sides ask of it
--------------------------------------------------------------------------------

--- The pieces, as this machine knows them.
---
--- On the authority these ARE the saved rows - LGEPPipes binds them to the ModData store -
--- so every gate below reads the truth.  On a multiplayer client they are the last set the
--- authority broadcast.  Either way `net` on a row is the network it was in at the last
--- derivation, and `EP.pipeNets[net]` is that network's summary.
EP.floorPipes = EP.floorPipes or {}
EP.wallPipes  = EP.wallPipes or {}
EP.pipeNets   = EP.pipeNets or {}

--- Map building id string -> the network it is on.  The authority writes it at every
--- derivation; a client gets it with the set.  It is what lets a client put a fixture in a
--- barrel-less house on its network for the first-click Plumb, without scanning for barrels
--- it cannot see.  Map buildings only - a player structure's id does not survive the next
--- wall, so it is never sent.
EP.pipeDefNet = EP.pipeDefNet or {}

--- Bumped whenever the set above changes, on either side.  The window watches it.
EP.pipeGeneration = EP.pipeGeneration or 0

--- The floor pipe on this tile, or nil.
function EP.pipeAt(x, y, z)
	return EP.floorPipes[EP.pipeKey(x, y, z)]
end

--- The wall pipe on this edge, or nil.  `north` is as the owning square sees it.
function EP.wallPipeAt(x, y, z, north)
	return EP.wallPipes[EP.wallPipeKey(x, y, z, north)]
end

--- Is anything laid at all?  The idle test: every integration point asks this first, so a
--- world with no pipes pays one table walk that finds nothing.
function EP.anyPipes()
	return EP.any(EP.floorPipes) or EP.any(EP.wallPipes)
end

--- Would the network numbered `net` feed a fixture at level `fz` drawing `liquid`?
---
--- The first-click question a client cannot answer from the world, because a network is by
--- design the thing that reaches past its loaded chunks.  The authority summarises each
--- network per liquid - the highest a plumbed barrel of it stands, and whether any is
--- pumped - and this is EP.canSupply asked of that summary: strictly above, or pumped.
---
--- Never the colour.  Blue says a barrel is on the network; this says one of them could
--- reach the tap, and offering Plumb on the colour alone would plumb a same-floor sink to
--- nothing - the dead end lgep_spec_unplumb exists for.
function EP.pipeNetServes(net, fz, liquid)
	local summary = EP.pipeNets[net]
	if not summary or not summary.supplied or not summary.serve then return false end
	local want = EP.canonicalFluidType and EP.canonicalFluidType(liquid) or liquid
	local entry = summary.serve[want or EP.FLUID_DEFAULT]
	if not entry then return false end
	return entry.top > fz or entry.pumped == true
end

--- The network a fixture at (x, y, z) is on, as far as THIS machine can tell: a floor pipe
--- under it, or its own room's map building.  Not a player structure - see EP.pipeDefNet.
---
--- The client's half of EP.pipeNetsAt, and deliberately the narrower half: it is asked to
--- decide whether to put up a stand-in, and a structure-joined fixture that misses out gets
--- its Plumb row on the second click, when the authority's own mirror has arrived.  Wrong in
--- that direction is a click; wrong in the other would plumb a sink to nothing.
function EP.pipeNetOfFixtureVisible(x, y, z)
	local row = EP.pipeAt(x, y, z)
	if row and row.net and row.net > 0 then return row.net end
	local square = getCell() and getCell():getGridSquare(x, y, z)
	local building = square and square:getBuilding()
	local def = building and building:getDef()
	def = def and EP.canonicalDef(def) or nil
	if def and not (def.isUserDefined and def:isUserDefined()) then
		return EP.pipeDefNet[def:getIDString()]
	end
	return nil
end

--- Would a network feed this fixture, as far as this machine can tell?  The stand-in's gate.
function EP.pipeFixtureServesVisible(x, y, z, liquid)
	if not EP.anyPipes() then return false end
	local net = EP.pipeNetOfFixtureVisible(x, y, z)
	return net ~= nil and EP.pipeNetServes(net, z, liquid)
end

--------------------------------------------------------------------------------
-- what fits in one packet
--------------------------------------------------------------------------------

--- ONE COMMAND IS AT MOST A MEGABYTE, AND PAST IT NOTHING IS SENT AT ALL.
---
--- BR-LGEE-025, 1.11.0, every big server.  `UdpConnection` has ONE
--- `ByteBuffer.allocate(1000000)` (`UdpConnection.java:40`) and `TableNetworkUtils.save`
--- writes a type byte plus an 8-byte double for the KEY and again for the VALUE, so a flat
--- numeric array costs **18 bytes a number**.  Past the end, `BufferOverflowException`
--- escapes `sendServerCommand` between `startPacket()` and `send()` -
--- `GameServer.java:3467` catches only `IOException` - so the packet is NEVER SENT, and
--- Kahlua logs the throw and hands back nil, so the mod carries on as if it had.
---
--- WHAT THAT LOOKS LIKE TO A PLAYER: every client holds no pipes at all.  No blue tiles, no
--- white ones, and `EP.pipeFixtureServesVisible` answers false for every tap, so the first
--- click on a piped fixture is refused with nothing to explain it.  It is not a degraded
--- picture; it is the whole feature gone, and only on the servers big enough to want it.
---
--- The set grows with the world - one row per iron pipe anybody has ever laid - so it has
--- to go out in parts.  LGEE's `EE.splitPacket` is the same idea on a flat stride-N array;
--- this one carries several arrays of different strides in one answer, so it is written
--- against the FIELDS rather than against a stride.
---
--- PRICED IN BYTES RATHER THAN IN ENTRIES, and that is not pedantry: `nets` carries liquid
--- names and map building id strings, and a string is `1 + 2 + #s` where a number is 9.  A
--- budget counted in entries under-prices exactly the field whose length nobody controls.
EP.PACKET_BYTES = 700000

--- What one entry of an answer's array costs in the connection's buffer: its integer key,
--- and then itself.
local function entryBytes(v)
	if type(v) == "string" then return 9 + 3 + #v end
	return 18
end

--- The two answers that grow with the world, described ONCE so both ends read one list.
---
--- `stride` is the unit a part may be cut on.  `nets` is a stream rather than a table of
--- fixed rows - a network is `supplied, n, n x (liquid, top, pumped), d, d x id` - so its
--- stride is one: `EP.unpackPipeSet` walks it with a cursor and does not care where a part
--- boundary fell, as long as the order is kept.
EP.PIPE_SET_FIELDS = {
	{ array = "floors", count = "nf", stride = 4 },
	{ array = "walls",  count = "nw", stride = 5 },
	{ array = "nets",   count = "nn", stride = 1 },
}

--- The area answer, which carries the drawn rectangles as well.
EP.PIPE_AREA_FIELDS = {
	{ array = "nets",   count = "nn", stride = 1 },
	{ array = "floors", count = "nf", stride = 4 },
	{ array = "walls",  count = "nw", stride = 5 },
	{ array = "areas",  count = "na", stride = 7 },
}

--- Which non-array keys every part has to carry.  Anything a part is read without.
EP.PIPE_SET_KEEP  = { "gen" }
EP.PIPE_AREA_KEEP = { "x", "y", "z" }

EP.packetSerial = EP.packetSerial or 0

--- Split an answer into packets that each fit the buffer.
---
--- An answer that fits comes back as ITSELF, the very same table, so the ordinary case -
--- every base in the game - gains no round trip, no part number and no reassembly buffer.
---
--- Parts are numbered and share a `set`, because a command is reliable but **not ordered**
--- (`PacketTypes` ClientCommand, reliability 2): they may arrive in any order.
function EP.splitPacket(args, fields, keep)
	if type(args) ~= "table" then return { args } end

	-- What the scalar keys and the table headers cost, before a single entry.
	local base = 256
	for i = 1, #keep do
		local v = args[keep[i]]
		if v ~= nil then base = base + 16 + #tostring(keep[i]) + entryBytes(v) end
	end

	local total = base
	for i = 1, #fields do
		local arr = args[fields[i].array]
		local n = tonumber(args[fields[i].count]) or 0
		if type(arr) == "table" then
			for j = 1, n do total = total + entryBytes(arr[j]) end
		end
	end
	if total <= EP.PACKET_BYTES then return { args } end

	EP.packetSerial = EP.packetSerial + 1
	local set = EP.packetSerial

	local list = {}
	local part, spent = nil, 0

	--- Which keys the fields own, so a scalar copy does not tread on them.
	local owned = {}
	for i = 1, #fields do
		owned[fields[i].array] = true
		owned[fields[i].count] = true
	end

	--- EVERY SCALAR SURVIVES, NOT ONLY THE ONES SOMEBODY REMEMBERED TO LIST.
	---
	--- This copied `keep` and nothing else, so a scalar the caller put in `args` and left
	--- out of the KEEP list travelled on an UNSPLIT answer and vanished from a split one.
	--- That is a bug that appears only on a big server, only above the split threshold, and
	--- nowhere in any suite small enough to run - the worst shape there is.  The KEEP lists
	--- stay, because `base` has to price the scalars before the first row is placed; they
	--- are no longer what decides whether a key is carried.
	local function openPart()
		part = {}
		for k, v in pairs(args) do
			if type(v) ~= "table" and not owned[k]
				and k ~= "part" and k ~= "parts" and k ~= "set" then
				part[k] = v
			end
		end
		for i = 1, #fields do
			part[fields[i].array] = {}
			part[fields[i].count] = 0
		end
		spent = base
		list[#list + 1] = part
	end
	openPart()

	for i = 1, #fields do
		local f = fields[i]
		local arr = args[f.array]
		local n = tonumber(args[f.count]) or 0
		if type(arr) == "table" then
			local at = 1
			while at <= n do
				-- One stride at a time, so a row is never cut in half.  A single row bigger
				-- than the whole budget is impossible here (the widest is seven numbers) and
				-- would in any case go out alone rather than be dropped.
				local take = f.stride
				if at + take - 1 > n then take = n - at + 1 end

				local cost = 0
				for j = at, at + take - 1 do cost = cost + entryBytes(arr[j]) end

				-- THE TEST IS WHETHER THIS PART HOLDS ANYTHING, NOT WHETHER IT HOLDS ANY
				-- OF THIS FIELD.  `part[f.count] > 0` is false at the start of every field,
				-- so a part already full of floors took the first wall row past the budget
				-- as well - once per field, every time.  The guard is there to stop an empty
				-- part being replaced by another empty part, and `spent > base` says that
				-- exactly.
				if spent + cost > EP.PACKET_BYTES and spent > base then openPart() end

				local into = part[f.array]
				local m = part[f.count]
				for j = 0, take - 1 do into[m + j + 1] = arr[at + j] end
				part[f.count] = m + take
				spent = spent + cost
				at = at + take
			end
		end
	end

	for i = 1, #list do
		list[i].part, list[i].parts, list[i].set = i, #list, set
	end
	return list
end

--- Parts waiting for the rest of their answer, per command and per set.
local assembling = {}
--- The newest set put back together, per command: an older one finishing late is stale.
local assembledSet = {}
local ASSEMBLING_MAX = 4

--- Take one packet in.  Returns the whole answer, or nil while parts are still missing.
---
--- A packet with no `parts` is an answer on its own and is handed straight back, whatever it
--- is - a singleplayer call that never went near a wire, a small set, or nothing at all.
--- That is what keeps the direct SP path and the suites that drive it unchanged.
function EP.assemblePacket(command, args, fields)
	if type(args) ~= "table" then return args end
	local parts = tonumber(args.parts)
	if not parts or parts <= 1 then
		-- AN UNSPLIT ANSWER SUPERSEDES A SPLIT ONE STILL IN FLIGHT, and forgetting that put
		-- the client back on an OLDER set.  The staleness gate below is `assembledSet`, and
		-- it was only ever written on the split path - so a small answer was handed back
		-- without touching it, leaving a half-arrived older set in `assembling`.  When that
		-- set's last part landed it completed normally and overwrote the newer answer, `gen`
		-- and all.
		--
		-- It is not a corner case.  A set crosses the 700 KB line at about 9,750 floor pipes
		-- and every lay or lift moves it by 72 bytes, so a server parked near that count
		-- alternates split and unsplit on consecutive broadcasts.  The window's area answer
		-- is worse: its size tracks where the player is standing.
		--
		-- What the player saw: lifted pipes still drawn, pipes just laid missing, and a tap
		-- on the new run refused with "No supply reaches this" until somebody moved a pipe.
		assembling[command] = nil
		return args
	end

	local part, set = tonumber(args.part), tonumber(args.set)
	if not part or not set or part < 1 or part > parts then return nil end

	-- An older set finishing late is stale: the newest answer is the true one.
	local last = assembledSet[command]
	if last and set <= last then return nil end

	local slots = assembling[command]
	if not slots then
		slots = {}
		assembling[command] = slots
	end

	local slot = slots[set]

	-- EVERY PART OF ONE SET MUST AGREE ABOUT HOW MANY THERE ARE.  A packet claiming a
	-- different `parts` passes the bound test above (it is checked against its OWN claim) and
	-- then counts toward a slot sized by the first packet - so `got` can reach `parts` with
	-- holes in the list, and assembly throws on a nil part.  Server-only input today; it
	-- costs one comparison to make that not matter.
	if slot and slot.parts ~= parts then return nil end

	if not slot then
		-- A set whose parts never all arrive would otherwise sit here for the session.
		local held, oldest = 0, nil
		for s in pairs(slots) do
			held = held + 1
			if not oldest or s < oldest then oldest = s end
		end
		if held >= ASSEMBLING_MAX then
			-- AND THE STALEST THING HERE MAY BE THE PACKET THAT JUST ARRIVED.  The eviction
			-- makes room by dropping the lowest serial in the table, which is the right rule
			-- when the arrival is newer than everything held - and the wrong one when it is
			-- not.  A straggler from set 5 landing while 10, 11, 12 and 13 are in flight
			-- threw away set 10 to make room for a set that nothing will ever finish, and
			-- set 10 then never completed either: one late packet cost two answers.
			--
			-- `assembledSet` does not catch it, because that only knows about sets that
			-- COMPLETED, and none of these has.
			if oldest and set < oldest then return nil end
			slots[oldest] = nil
		end
		slot = { parts = parts, got = 0, list = {} }
		slots[set] = slot
	end

	if slot.list[part] ~= nil then return nil end
	slot.list[part] = args
	slot.got = slot.got + 1
	if slot.got < slot.parts then return nil end

	local whole = {}
	for k, v in pairs(slot.list[1]) do
		if type(k) == "string" and k ~= "part" and k ~= "parts" and k ~= "set" then whole[k] = v end
	end

	for i = 1, #fields do
		local f = fields[i]
		local into, m = {}, 0
		for p = 1, slot.parts do
			local piece = slot.list[p]
			local arr = piece[f.array]
			local n = tonumber(piece[f.count]) or 0
			if type(arr) == "table" then
				-- CLAMPED TO WHAT IS REALLY THERE.  A count larger than its array punches nil
				-- holes into the middle of the answer, and an off-stride one re-aligns every
				-- row after it onto the wrong coordinates - silently, because `unpackPipeSet`
				-- simply skips a nil row.
				if n > #arr then n = #arr end
				for j = 1, n do into[m + j] = arr[j] end
				m = m + n
			end
		end
		whole[f.array] = into
		whole[f.count] = m
	end

	-- COMMITTED ONLY ONCE THE ANSWER IS BUILT.  Marking the set accepted before assembling it
	-- meant a packet that threw on the way through had already bumped the gate, so every
	-- remaining part of that set was then dropped as stale and the answer was lost twice.
	local stale = {}
	for s in pairs(slots) do
		if s <= set then stale[#stale + 1] = s end
	end
	for i = 1, #stale do slots[stale[i]] = nil end
	assembledSet[command] = set

	return whole
end

--- A NEW WORLD IS A NEW WIRE.  Both tables above are file-locals and nothing reset them; the
--- only reason a second world did not inherit the first one's serials is that
--- `IngameState.exit()` rebuilds the whole Lua environment on the way to the main menu, which
--- is exactly the accident memory/caches-must-be-session-scoped-not-process-scoped.md says
--- not to rest on.  A server that soft-resets its Lua with clients connected would otherwise
--- restart `EP.packetSerial` under live `assembledSet` values and drop every set after it.
function EP.forgetPacketAssembly()
	assembling, assembledSet = {}, {}
	-- The other half of the same gate: a serial that restarts under a live `assembledSet` is
	-- the fault this exists for, so both ends go back to zero together.
	EP.packetSerial = 0
end

--- Send an answer that grows with the world, in as many parts as it takes.
---
--- `to` is the player it is addressed to, or nil to broadcast.  Off a wire - singleplayer,
--- and the co-op child server's own half - there is nothing to split and `deliver` is
--- called with the whole answer, which is exactly what it always was.
function EP.sendSplit(to, command, args, fields, keep, deliver)
	if not isServer() then
		if deliver then deliver(args) end
		return 1
	end

	local parts = EP.splitPacket(args, fields, keep)
	for i = 1, #parts do
		if to then
			sendServerCommand(to, EP.COMMAND_MODULE, command, parts[i])
		else
			sendServerCommand(EP.COMMAND_MODULE, command, parts[i])
		end
	end
	return #parts
end

--------------------------------------------------------------------------------
-- the wire format of the set
--------------------------------------------------------------------------------

--- Flat, like LGEE's relay set: a table per piece would be an allocation per piece to carry
--- four integers.
---
---     floors  x, y, z, net, ...
---     walls   x, y, z, north (1/0), net, ...
---     nets    supplied (1/0), n, then n x (liquid, top, pumped 1/0),
---             then d, then d x map building id string, ...                 per network
function EP.packPipeSet(floors, walls, nets)
	local f, w, n = {}, {}, {}
	for _, row in pairs(floors) do
		f[#f + 1] = row.x; f[#f + 1] = row.y; f[#f + 1] = row.z; f[#f + 1] = row.net or 0
	end
	for _, row in pairs(walls) do
		w[#w + 1] = row.x; w[#w + 1] = row.y; w[#w + 1] = row.z
		w[#w + 1] = row.north and 1 or 0; w[#w + 1] = row.net or 0
	end
	for i = 1, #nets do
		local net = nets[i]
		n[#n + 1] = net.supplied and 1 or 0
		local serve, count = {}, 0
		for liquid, entry in pairs(net.serve or {}) do
			serve[#serve + 1] = liquid; serve[#serve + 1] = entry.top
			serve[#serve + 1] = entry.pumped and 1 or 0
			count = count + 1
		end
		n[#n + 1] = count
		for k = 1, #serve do n[#n + 1] = serve[k] end
		local defs = {}
		for id in pairs(net.defs or {}) do defs[#defs + 1] = id end
		n[#n + 1] = #defs
		for k = 1, #defs do n[#n + 1] = defs[k] end
	end
	-- THE LENGTHS TRAVEL WITH THEM.  `#` on a table that has been through the wire is a
	-- property of how the far side rebuilt it, and LGEE's relay set has always said how
	-- many it sent for the same reason.
	return { floors = f, walls = w, nets = n, nf = #f, nw = #w, nn = #n }
end

--- The other end: replace this machine's copy with what arrived.
function EP.unpackPipeSet(args)
	local floors, walls, nets = {}, {}, {}
	if type(args) ~= "table" then return floors, walls, nets end

	local f = args.floors
	if type(f) == "table" then
		for i = 1, (tonumber(args.nf) or 0) - 3, 4 do
			local x, y, z = tonumber(f[i]), tonumber(f[i + 1]), tonumber(f[i + 2])
			if x and y and z then
				floors[EP.pipeKey(x, y, z)] = { x = x, y = y, z = z, net = tonumber(f[i + 3]) or 0 }
			end
		end
	end

	local w = args.walls
	if type(w) == "table" then
		for i = 1, (tonumber(args.nw) or 0) - 4, 5 do
			local x, y, z = tonumber(w[i]), tonumber(w[i + 1]), tonumber(w[i + 2])
			if x and y and z then
				local north = tonumber(w[i + 3]) == 1
				walls[EP.wallPipeKey(x, y, z, north)] = { x = x, y = y, z = z, north = north,
					net = tonumber(w[i + 4]) or 0 }
			end
		end
	end

	local n = args.nets
	if type(n) == "table" then
		local at, last = 1, tonumber(args.nn) or 0
		while at <= last do
			local supplied = tonumber(n[at]) == 1
			local count = tonumber(n[at + 1]) or 0
			at = at + 2
			local serve = {}
			for _ = 1, count do
				local liquid, top, pumped = n[at], tonumber(n[at + 1]), tonumber(n[at + 2])
				if type(liquid) == "string" and top then
					serve[liquid] = { top = top, pumped = pumped == 1 }
				end
				at = at + 3
			end
			local defs = {}
			local nd = tonumber(n[at]) or 0
			at = at + 1
			for _ = 1, nd do
				if type(n[at]) == "string" then defs[n[at]] = true end
				at = at + 1
			end
			nets[#nets + 1] = { supplied = supplied, serve = serve, defs = defs }
		end
	end

	return floors, walls, nets
end

--- Take a set in, on a machine that is not the authority.
function EP.receivePipeSet(args)
	local floors, walls, nets = EP.unpackPipeSet(args)
	local defNet = {}
	for i = 1, #nets do
		for id in pairs(nets[i].defs or {}) do defNet[id] = i end
	end
	EP.floorPipes, EP.wallPipes, EP.pipeNets, EP.pipeDefNet = floors, walls, nets, defNet
	EP.pipeGeneration = (tonumber(args and args.gen) or (EP.pipeGeneration + 1))
end

--------------------------------------------------------------------------------
-- rectangles, for the window
--------------------------------------------------------------------------------

--- A window of squares.  The client passes the loaded chunk map's own bounds, so the
--- worst case is 104 x 104 whatever the network's true extent.  Indexed by position in the
--- window so negative world coordinates cost nothing.
function EP.newPipeGrid(x0, y0, x1, y1)
	return { x0 = x0, y0 = y0, x1 = x1, y1 = y1, w = x1 - x0 + 1, h = y1 - y0 + 1,
		cells = {}, mx0 = nil, my0 = nil, mx1 = nil, my1 = nil }
end

--- Mark a rectangle with `value`, keeping the larger where two overlap - so a tile two
--- buildings both claim draws once, in the stronger of their two states.
function EP.pipeGridMark(grid, x1, y1, x2, y2, value)
	if x1 < grid.x0 then x1 = grid.x0 end
	if y1 < grid.y0 then y1 = grid.y0 end
	if x2 > grid.x1 then x2 = grid.x1 end
	if y2 > grid.y1 then y2 = grid.y1 end
	if x1 > x2 or y1 > y2 then return end

	if grid.mx0 == nil or x1 < grid.mx0 then grid.mx0 = x1 end
	if grid.my0 == nil or y1 < grid.my0 then grid.my0 = y1 end
	if grid.mx1 == nil or x2 > grid.mx1 then grid.mx1 = x2 end
	if grid.my1 == nil or y2 > grid.my1 then grid.my1 = y2 end

	local cells = grid.cells
	for y = y1, y2 do
		local base = (y - grid.y0) * grid.w - grid.x0
		for x = x1, x2 do
			local was = cells[base + x]
			if was == nil or was < value then cells[base + x] = value end
		end
	end
end

--- What one square is worth, or nil.
function EP.pipeGridAt(grid, x, y)
	if x < grid.x0 or x > grid.x1 or y < grid.y0 or y > grid.y1 then return nil end
	return grid.cells[(y - grid.y0) * grid.w + (x - grid.x0)]
end

--- Every square worth exactly `want`, as few rectangles as a row merge manages.
---
--- EE.areaRects, and for the same reason: every rectangle the engine draws gets a
--- hardcoded WHITE outline (FBORenderAreaHighlights.renderOutline), so the rectangle count
--- is what the overlay looks like.  Row runs, extended downward while the run below is
--- identical; `open` holds only the previous row.
function EP.pipeGridRects(grid, want, out)
	out = out or {}
	if grid.mx0 == nil then return out end

	local cells = grid.cells
	local x0, x1 = grid.mx0, grid.mx1
	local open = {}

	for y = grid.my0, grid.my1 do
		local carried = {}
		local base = (y - grid.y0) * grid.w - grid.x0
		local x = x0
		while x <= x1 do
			if cells[base + x] == want then
				local runStart = x
				repeat x = x + 1 until x > x1 or cells[base + x] ~= want
				local id = runStart .. ":" .. (x - 1)
				local rect = open[id]
				if rect then
					rect.h = rect.h + 1
					open[id] = nil
				else
					rect = { x = runStart, y = y, w = x - runStart, h = 1 }
				end
				carried[id] = rect
			else
				x = x + 1
			end
		end
		for _, rect in pairs(open) do out[#out + 1] = rect end
		open = carried
	end

	for _, rect in pairs(open) do out[#out + 1] = rect end
	return out
end

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
if EP.checkBuild then
	EP.checkBuild("LGEPPipe.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPPipe.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
