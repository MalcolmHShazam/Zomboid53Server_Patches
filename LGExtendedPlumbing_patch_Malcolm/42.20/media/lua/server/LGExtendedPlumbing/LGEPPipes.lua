--
-- Extended Plumbing - pipes, on the authority.
--
-- The store, the acts that lay and lift a piece, the item ledger, the derivation of
-- networks from the pieces, which networks are supplied, the broadcast to clients, and the
-- answer the window asks for.  Everything that decides happens here; a client holds a copy
-- of the pieces and draws.  See plans/lgep-pipe-network.md.
--
-- WHAT IS SAVED IS THE PIECES AND NOTHING ELSE.  A network is re-derived from them, the
-- way LGEE's circuits are from its relays, which is what makes lifting the middle pipe of
-- a run split it on the next derivation with nobody telling anything.
--

require "LGExtendedPlumbing/LGEPPipe"

-- The folder is not a boundary - media/lua/server/ runs on a client too - so, like
-- LGEPPlumbing, this returns before defining anything there.  Singleplayer is
-- isClient() == false and runs all of it.
if isClient() then return end

local EP = LGEP

--------------------------------------------------------------------------------
-- the store
--------------------------------------------------------------------------------

--- The rows, bound to the ModData store so a dedicated server saves them with no event.
---
--- A server never raises OnSave (memory/dedicated-server-never-raises-onsave.md), but
--- ServerMap's own save writes GlobalModData, so a table hanging off the store is in the
--- save in every mode.  `floors` and `store.floors` are the same table afterwards, and so
--- are EP.floorPipes: every gate reads the saved rows themselves.
local floors, walls = {}, {}
EP.floorPipes, EP.wallPipes = floors, walls

--- Bumped on every lay and lift.  It is also EP.pipeGeneration, which the window watches.
local pipeVersion = 0

--- A row, rebuilt field by field because it has been through a file.  A field left out of
--- this list is a field that does not survive a restart; `net` is left out on purpose,
--- because it is derived and a stale one read before the first derivation would put a
--- piece on a network it is not on.
local function keepFloor(row)
	if type(row) ~= "table" then return nil end
	local x, y, z = tonumber(row.x), tonumber(row.y), tonumber(row.z)
	if not x or not y or not z or z < -32 or z > EP.MAX_LEVEL then return nil end
	-- WHOLE TILES ONLY.  Nothing checked, and `EP.pipeKey(12.5, 3, 0)` is a perfectly good
	-- key: `getGridSquare` coerces to int so every gate passes, the row is stored, saved,
	-- broadcast and given a node in every derivation - and NO LIFT CAN EVER REACH IT,
	-- because the window only ever produces whole tile coordinates. It also holds
	-- `EP.anyPipes()` true for the life of the world, which is what every idle gate in the
	-- mod stands on.
	if x ~= math.floor(x) or y ~= math.floor(y) or z ~= math.floor(z) then return nil end

	-- AND THE COST IS BOUNDED BY WHAT A PIECE CAN COST.  `lift` runs
	-- `for _ = 1, row.cost do ... end` with an `AddItem` per iteration, on the main loop,
	-- and this floored the value and clamped it at zero without ever capping it.
	-- `EP.PIPE_STORE` is the bare string "LGExtendedPlumbing" - a generic global-ModData key
	-- another mod or a hand-edited save can write - so a `cost` of 1e9 was an unbounded
	-- loop away.
	local cost = tonumber(row.cost)
	if cost == nil then cost = EP.PIPE_COST end
	if cost < 0 then cost = 0 end
	if cost > EP.PIPE_COST then cost = EP.PIPE_COST end
	return { x = x, y = y, z = z, cost = math.floor(cost), cond = tonumber(row.cond) }
end

local function keepWall(row)
	local out = keepFloor(row)
	if not out then return nil end
	out.north = row.north == true
	return out
end

--- Bind the live tables to the store.  Returns how many pieces it holds.
function EP.adoptPipeStore(store)
	local f, w = {}, {}
	if store and type(store.floors) == "table" then
		for _, row in pairs(store.floors) do
			local kept = keepFloor(row)
			if kept then f[EP.pipeKey(kept.x, kept.y, kept.z)] = kept end
		end
	end
	if store and type(store.walls) == "table" then
		for _, row in pairs(store.walls) do
			local kept = keepWall(row)
			if kept then w[EP.wallPipeKey(kept.x, kept.y, kept.z, kept.north)] = kept end
		end
	end
	floors, walls = f, w
	EP.floorPipes, EP.wallPipes = f, w
	if store then store.floors, store.walls = f, w end
	pipeVersion = pipeVersion + 1
	EP.pipeGeneration = pipeVersion
	EP.markPipesDirty()
	return EP.count(f) + EP.count(w)
end

Events.OnInitGlobalModData.Add(function()
	local ok, err = pcall(function()
		if not ModData or not ModData.getOrCreate then return end
		local n = EP.adoptPipeStore(ModData.getOrCreate(EP.PIPE_STORE))
		EP.log(("pipes: %d piece(s) in the store"):format(n))
	end)
	if not ok then EP.logFault("pipe-store", "ERROR reading the pipe store: " .. tostring(err)) end
end)

--------------------------------------------------------------------------------
-- what the derivation knows, and when it is stale
--------------------------------------------------------------------------------

--- The last derivation.  `nets[i]` carries its pieces, its map buildings (`defs`), the
--- tiles it touched a player structure from (`structs`), a box, and supplied/serve.
local state = { nets = {}, defNet = {}, anyStructs = false }

local topologyDirty = true
local supplyDirty = true

--- Re-derive on a clock while a player structure is touched.  Construction raises nothing
--- a dedicated server hears, so a structure growing to meet a pipe is otherwise never seen.
--- Map buildings need no clock: their plans do not change.
local PIPE_REDERIVE_SECONDS = 60
local derivedAt = nil

--- The supply is recomputed at most this often by the background driver.  A gate that
--- needs it fresh asks EP.pipeSupplyNow() instead.
local SUPPLY_MIN_SECONDS = 1
local suppliedAt = nil

--- Anything that could move a network's shape.
function EP.markPipesDirty()
	topologyDirty = true
	supplyDirty = true
	if EP.reg then EP.reg.invalidate() end -- [Malcolm_Perf] pipe pieces feed the hot set
end

--- Anything that could move a network's supply: a barrel plumbed in or out, filed or
--- forgotten, a pump moving.  LGEPPlumbing's supplyChanged() calls this.
function EP.markPipeSupplyDirty()
	supplyDirty = true
end

Events.OnLoadedMapZones.Add(function() EP.markPipesDirty() end)

local function nowMs()
	if getTimestampMs then return getTimestampMs() end
	return 0
end

--------------------------------------------------------------------------------
-- deriving the networks
--------------------------------------------------------------------------------

--- Which buildings a single tile is part of, as ids the derivation can union on.
---
--- The same two questions EP.canPlumbHere asks, so the set a pipe joins is the set a
--- barrel is offered Plumb on - one set, two readers.
---
---   "B<id string>"  a MAP building, by EP.mapBuildingAt (room, then the plan grown by one - never the linear walk).
---                   Stable for the life of the world.
---   "R<region id>"  a player STRUCTURE, by EP.regionsAt.  Valid only inside this one
---                   derivation: a region is rebuilt with a fresh id when a wall goes up.
---
--- A user-defined def is skipped: it is the same structure the region answer names, and
--- its id is rebuilt just as often.  poolOf refuses them for the same reason.
local function areaAt(x, y, z)
	local out = nil
	local def = EP.mapBuildingAt(x, y, z)
	if def and not (def.isUserDefined and def:isUserDefined()) then
		out = { "B" .. def:getIDString() }
	end
	-- EVEN UNLOADED (BR-LGEP-083): a derivation runs on a clock whether anybody is near the
	-- house or not, and one that could not see it cut the run off from it for good.
	local regions = EP.regionsAt(x, y, z, true)
	if regions then
		for id in pairs(regions) do
			out = out or {}
			out[#out + 1] = "R" .. tostring(id)
		end
	end
	return out
end

--- THE SAME TILE, ASKED ONCE, NOT ONCE PER DERIVATION.
---
--- MEASURED on the real engine with `nanos()` (`tools/luatest/lgep_probe_derivecost.lua`):
---
---       100 pieces     13.1 ms
---       500 pieces     55.1 ms
---     2,000 pieces    123.7 ms
---     8,000 pieces    511.9 ms      -- half a second, in one frame
---
--- about 0.064 ms a piece, and effectively all of it is `areaAt`: nine neighbours a piece,
--- each one a `EP.mapBuildingAt` plus an `EP.regionsAt`, and `EP.regionsAt` is a column of up
--- to eight grid lookups plus a ring of eight.  `EP.pipeDerive` memoises per tile WITHIN one
--- derivation and threw the answers away at the end of it - and a derivation runs on every
--- lay, on every lift, on a sixty-second clock, and inside `EP.pipeNetsAt`, which is on the
--- group walk and therefore inside a right-click.
---
--- WHY A CACHE IS SOUND HERE, AND IT IS NOT AN OPTIMISATION ARGUMENT.  The answer this
--- caches is already allowed to be stale by exactly this much: `PIPE_REDERIVE_SECONDS` exists
--- because a player-built structure changes with nothing to announce it, and
--- `plans/lgep-pipe-network.md` section 12 states the consequence as accepted - "a structure
--- that grows to meet a pipe is seen within PIPE_REDERIVE_SECONDS, not at once".  A memo
--- whose life is that same window cannot be staler than the answer it feeds.
---
--- AND A PLAYER'S OWN ACT IS NEVER ANSWERED FROM IT.  Laying a pipe against a wall you have
--- just built has to join NOW, not in a minute, so `piecesChanged` evicts the tiles round the
--- piece that moved.  Everything else keeps its answer, which is what makes the derivation
--- after a lay cost the union-find and not the world.
local areaMemo, areaMemoAt = {}, nil

local function areaAtCached(x, y, z)
	local now = nowMs()
	if not areaMemoAt or now - areaMemoAt >= PIPE_REDERIVE_SECONDS * 1000 then
		areaMemo, areaMemoAt = {}, now
	end

	local key = EP.key(x, y, z)
	local hit = areaMemo[key]
	if hit ~= nil then
		if hit == false then return nil end
		return hit
	end

	local out = areaAt(x, y, z)

	-- A REGION ID IS A POOL SLOT, NOT AN IDENTITY, SO IT IS NEVER REMEMBERED.
	--
	-- `IsoRegionManager.allocIsoWorldRegion` takes its id from `regionIdStack` when that is
	-- not empty and `releaseIsoWorldRegion` pushes the freed id straight back
	-- (`IsoRegionManager.java:24-42`) - and `allocIsoChunkRegion` draws from the SAME stack,
	-- so the numbers are churned by every chunk streaming in or out, not only by somebody
	-- building a wall. `LGEPCore.lua`'s own note says the answer is safe only because "both
	-- ends are resolved in the same call and a rebuild between them is not a case that
	-- exists". A memo with a sixty-second life is exactly the case that makes it exist.
	--
	-- What that would have done: a tile in one base remembered as "R17", that region
	-- released when its chunk unloaded, id 17 handed to a structure four hundred tiles away,
	-- and the next derivation unions two runs that have no pipe between them. The far base's
	-- white run turns blue, its tap offers a barrel it cannot reach, and the real base's
	-- barrel drains - then it stops for no visible reason when the memo flushes.
	--
	-- A MAP building's id is stable for the life of the world, which is the justification
	-- the header above actually rests on, so those are still remembered. A tile whose answer
	-- names a region is asked fresh every time: in a map building that is no tiles at all,
	-- and in a player-built base it is the pre-cache cost, which is the honest price.
	local memoable = true
	if out then
		for i = 1, #out do
			if out[i]:sub(1, 1) == "R" then memoable = false; break end
		end
	end
	-- NOR IS AN ANSWER ABOUT A SQUARE THAT IS NOT THERE (BR-LGEP-083). "Nothing here" about an
	-- unloaded square is "not known", and remembered for a minute it outlived the chunk
	-- coming back: the derivation the arrival woke read the old nil and cut the run again.
	if memoable and not getCell():getGridSquare(x, y, z) then memoable = false end
	if memoable then areaMemo[key] = out or false end
	return out
end

--- Forget what was believed about the tiles round a piece that has just moved.
---
--- Five by five and a level either side, which is more than `EP.pipeDerive` asks for (a
--- footprint tile's own 3x3, and a wall pipe's two tiles at z and z+1) - generous on purpose,
--- because being one tile short here is a join that does not happen and nothing saying why.
local function forgetAreaNear(x, y, z)
	for dz = -1, 2 do
		for dy = -2, 2 do
			for dx = -2, 2 do
				areaMemo[EP.key(x + dx, y + dy, z + dz)] = nil
			end
		end
	end
end

--- A new world is a new map: nothing believed about the old one survives it.
Events.OnLoadedMapZones.Add(function() areaMemo, areaMemoAt = {}, nil end)

--- A CHUNK WITH A PIPE IN IT ARRIVED, SO LOOK AGAIN (BR-LGEP-083).
---
--- Yeetgor, dedicated server: "when we leave the tile and then re-enter, the pipes are white
--- and disconnected. I then need to remove one and place it again." A derivation run while
--- the house was away could not see it, and the only things that re-derive were a lay, a
--- lift, and a clock that the same derivation had just switched off. `IsoChunk.doLoadGridsquare`
--- ends with `triggerEvent("LoadChunk", this)` on a dedicated server as well
--- (`ServerMap.java:949` -> `IsoChunk.java:3963`), after every square is in.
---
--- Asked per arriving chunk, so it is one table lookup unless the chunk has a pipe in it or
--- beside it, and the derivation it asks for waits ARRIVAL_SETTLE_MS - long enough for a
--- walk into a base to be one derivation and not one per chunk, and for the region worker to
--- have processed what arrived - and never comes sooner than ARRIVAL_MIN_GAP_MS after the
--- last one, because a derivation of a big store is hundreds of milliseconds (BR-LGEP-040).
---
--- AND NEVER MORE THAN ABOUT 2% OF THE TIME. Somebody walking the length of a long run brings
--- a pipe chunk in every few seconds; at 8,000 pieces a derivation was measured at ~400 ms, and
--- one every ten seconds would be a worse stall than the sixty-second clock it exists beside.
--- So the gap also grows with what the last derivation actually cost, timed on the same clock.
local ARRIVAL_SETTLE_MS = 2000
local ARRIVAL_MIN_GAP_MS = 10000
local ARRIVAL_DUTY = 50
local arrivalWakeAt = nil
local lastDeriveMs = 0
local pipeChunks, pipeChunksGen = nil, nil
local CHUNK = 8

local function chunkKey(cx, cy) return cx * 65536 + cy end

--- Every chunk a piece stands in, and the ones either side of it, because a piece joins a
--- structure through its own ring of eight and that ring crosses a chunk edge.
local function chunksWithPipes()
	if pipeChunks and pipeChunksGen == pipeVersion then return pipeChunks end
	local set = {}
	local function mark(x, y)
		for dx = -1, 1 do
			for dy = -1, 1 do
				set[chunkKey(math.floor((x + dx) / CHUNK), math.floor((y + dy) / CHUNK))] = true
			end
		end
	end
	for _, row in pairs(floors) do mark(row.x, row.y) end
	for _, row in pairs(walls) do mark(row.x, row.y) end
	pipeChunks, pipeChunksGen = set, pipeVersion
	return set
end

--- Where an arriving chunk is, from the first square it holds. Methods only: Kahlua exposes
--- no fields, so `chunk.wx` is nil (memory/kahlua-exposes-methods-not-fields.md).
local function chunkOrigin(chunk)
	if not chunk or not chunk.getGridSquare then return nil end
	local lo, hi = 0, 0
	if chunk.getMinLevel and chunk.getMaxLevel then lo, hi = chunk:getMinLevel(), chunk:getMaxLevel() end
	for z = math.max(lo, 0), math.max(hi, 0) do
		for lx = 0, CHUNK - 1 do
			for ly = 0, CHUNK - 1 do
				local square = chunk:getGridSquare(lx, ly, z)
				if square then
					return math.floor(square:getX() / CHUNK), math.floor(square:getY() / CHUNK)
				end
			end
		end
	end
	return nil
end

Events.LoadChunk.Add(function(chunk)
	if not EP.anyPipes() then return end
	local ok, err = pcall(function()
		local cx, cy = chunkOrigin(chunk)
		if not cx then return end
		if chunksWithPipes()[chunkKey(cx, cy)] and not arrivalWakeAt then
			arrivalWakeAt = nowMs() + ARRIVAL_SETTLE_MS
		end
	end)
	if not ok then EP.logFault("pipe-arrival", "ERROR noting a chunk with pipes: " .. tostring(err)) end
end)

--- Grow a box to cover another.
local function widen(box, minX, minY, maxX, maxY)
	if box.minX == nil or minX < box.minX then box.minX = minX end
	if box.minY == nil or minY < box.minY then box.minY = minY end
	if box.maxX == nil or maxX > box.maxX then box.maxX = maxX end
	if box.maxY == nil or maxY > box.maxY then box.maxY = maxY end
end

--- The pieces as the derivation takes them: fresh tables, never the saved rows, because
--- the derivation writes working fields onto what it is handed.
local function pieceList()
	local pieces = {}
	for key, row in pairs(floors) do
		pieces[#pieces + 1] = { key = key, x = row.x, y = row.y, z = row.z }
	end
	for key, row in pairs(walls) do
		pieces[#pieces + 1] = { key = key, x = row.x, y = row.y, z = row.z, wall = true, north = row.north }
	end
	-- IN A FIXED ORDER, so the same pieces give the same network numbers on every
	-- derivation and a client's colours do not shuffle when nothing moved.  pairs() has no
	-- order to offer.
	table.sort(pieces, function(a, b) return a.key < b.key end)
	return pieces
end

--- Structure tiles this session has resolved, by EP.key, and how many derivations running
--- have since failed to.  See the end of deriveNow.  Session state: `LuaManager.init()` on
--- leaving a world takes it with every other file-local.
local structSeen = {}
local deriveRound = 0
local STRUCT_PATIENCE = 5

local function deriveNow()
	deriveRound = deriveRound + 1
	local startedAt = nowMs()
	-- A derivation for any reason after the arrivals settled answers them too.
	if arrivalWakeAt and startedAt >= arrivalWakeAt then arrivalWakeAt = nil end
	local pieces = pieceList()
	local nets, pieceNet = EP.pipeDerive(pieces, areaAtCached)

	local defNet, anyStructs = {}, false
	for _, net in ipairs(nets) do
		net.defs, net.structs = {}, {}
		local box = {}
		widen(box, net.minX - 1, net.minY - 1, net.maxX + 1, net.maxY + 1)
		for id, at in pairs(net.buildings) do
			local kind, rest = string.sub(id, 1, 1), string.sub(id, 2)
			if kind == "B" then
				net.defs[rest] = true
				defNet[rest] = net.index
				local def = EP.mapBuildingAt(at.x, at.y, at.z)
				local b = def and EP.buildingBounds(def) or nil
				if b then widen(box, b.minX - 2, b.minY - 2, b.maxX + 2, b.maxY + 2) end
			else
				net.structs[#net.structs + 1] = at
				anyStructs = true
				structSeen[EP.key(at.x, at.y, at.z)] = { misses = 0, round = deriveRound }
				local rb = EP.regionBounds(EP.regionsAt(at.x, at.y, at.z, true))
				if rb then widen(box, rb.minX - 2, rb.minY - 2, rb.maxX + 2, rb.maxY + 2) end
			end
		end
		net.box = box
		net.supplied, net.serve = false, {}
	end

	-- A STRUCTURE THIS SESSION HAS SEEN AND THIS DERIVATION DID NOT (BR-LGEP-083).
	--
	-- `anyStructs` is what keeps the sixty-second clock running, and it is recomputed from
	-- what THIS derivation could resolve - so one derivation that could not see the house
	-- (its regions not yet worked out after the chunk arrived; a build where the region
	-- graph cannot be asked directly) turned the clock off, and nothing turned it on again
	-- short of a lay or a lift. Remembered tiles keep it armed for a few more rounds, and a
	-- tile that goes on answering nothing is a structure that was knocked down.
	for k, seen in pairs(structSeen) do
		if seen.round ~= deriveRound then
			seen.misses = seen.misses + 1
			if seen.misses > STRUCT_PATIENCE then structSeen[k] = nil else anyStructs = true end
		end
	end

	for key, row in pairs(floors) do row.net = pieceNet[key] end
	for key, row in pairs(walls) do row.net = pieceNet[key] end

	state = { nets = nets, defNet = defNet, anyStructs = anyStructs, structAt = nil, structSets = nil }
	EP.pipeDefNet = defNet
	-- AND THE OLD SUPPLY SUMMARIES GO WITH THE OLD NUMBERING.
	--
	-- Network numbers are handed out by walking the pieces in sorted key order, so MERGING
	-- two networks renumbers every network after them. `EP.pipeNets` is indexed by that
	-- number and is only ever rebuilt in `recomputeSupply`, which runs on the driver's next
	-- tick - and `ensureDerived` is reachable from outside the driver, through
	-- `EP.pipeNetsAt` and `EP.pipeNetsUnionBox`, so any right-click or cursor lap landing in
	-- between asked the NEW numbering of the OLD summaries.
	--
	-- One tick, and it is the tick that matters: `lay` calls `EP.serviceAround` immediately
	-- so the far tap works NOW, and the case that gets wrong is exactly the merge - the
	-- connecting pipe between a barrelled house and a dry one.
	EP.pipeNets = {}
	topologyDirty = false
	supplyDirty = true
	derivedAt = nowMs()
	lastDeriveMs = derivedAt - startedAt
end

--- The derivation, brought up to date if anything moved.  Correctness before cost: a walk
--- asking "which network is this barrel on" gets an answer about the pieces as they are.
local function ensureDerived()
	if topologyDirty then deriveNow() end
	return state
end

--- Each structure-touching network's region set, resolved LIVE from the tiles it touched,
--- and memoised for a second: a region's id changes only when somebody builds, and a walk
--- asks this once per candidate.
--- BR-LGEP-053's MECHANISM WITH A ONE-SECOND WINDOW INSTEAD OF SIXTY.
---
--- A region id is a pool slot, not an identity: `IsoRegionManager.allocIsoWorldRegion` takes
--- its id from `regionIdStack` when that is not empty, `releaseIsoWorldRegion` pushes the
--- freed id straight back, and `allocIsoChunkRegion` draws from the SAME stack
--- (`IsoRegionManager.java:24-42`) - so the numbers churn on every chunk streaming in or out.
--- `EP.pipeNetsAt` compares a tile's live regions against this set BY ID, so a set held over a
--- chunk boundary can match a structure that never touched the network.
---
--- One second is short enough that it needs a player to move between chunks in the same
--- second, and long enough that a server with players streaming is doing that constantly. The
--- set is rebuilt each ask now; it is a walk of the networks that touch a structure at all,
--- which is nil work in a world of map buildings.
local function structSets()
	local st = state
	local sets = {}
	for _, net in ipairs(st.nets) do
		if #net.structs > 0 then
			local set = {}
			for i = 1, #net.structs do
				local at = net.structs[i]
				local regions = EP.regionsAt(at.x, at.y, at.z, true)
				if regions then
					for id, region in pairs(regions) do set[id] = region end
				end
			end
			sets[net.index] = set
		end
	end
	return sets
end

--------------------------------------------------------------------------------
-- which network a thing is on
--------------------------------------------------------------------------------

--- The networks a barrel or fixture at (x, y, z) belongs to, as a set, or nil.
---
--- Three ways in, and a thing can be on at most one network by each - a building is in at
--- most one network, because two runs touching it are one network through it:
---
---   a floor pipe under it;
---   its map building - EP.mapBuildingAt for a barrel, the square's OWN ROOM for a fixture,
---   the narrowing walkBegin already makes so a shack pitched against a house is not
---   adopted into the house by the plan test;
---   a player structure its EP.regionsAt meets.
function EP.pipeNetsAt(x, y, z, isFixture)
	if not EP.anyPipes() then return nil end
	local st = ensureDerived()
	local out = nil

	local row = floors[EP.pipeKey(x, y, z)]
	if row and row.net then out = { [row.net] = true } end

	local def
	if isFixture then
		local square = getCell():getGridSquare(x, y, z)
		local building = square and square:getBuilding()
		def = building and EP.canonicalDef(building:getDef()) or nil
	else
		def = EP.mapBuildingAt(x, y, z)
	end
	if def and not (def.isUserDefined and def:isUserDefined()) then
		local n = st.defNet[def:getIDString()]
		if n then out = out or {}; out[n] = true end
	end

	if st.anyStructs then
		local regions = EP.regionsAt(x, y, z)
		if regions then
			for n, set in pairs(structSets()) do
				if EP.regionsIntersect(regions, set) then out = out or {}; out[n] = true end
			end
		end
	end

	return out
end

--- Does a thing at (x, y, z) belong to any network in `nets`?
function EP.pipeNetsMeet(x, y, z, nets, isFixture)
	if not nets then return false end
	local mine = EP.pipeNetsAt(x, y, z, isFixture)
	if not mine then return false end
	for n in pairs(mine) do
		if nets[n] then return true end
	end
	return false
end

--- The box every member of these networks stands in: pieces, map buildings and structures,
--- with the margins the locality bounds elsewhere use.  Loose on purpose: it decides what
--- is CONSIDERED, never what is ACCEPTED.
function EP.pipeNetsBox(nets)
	if not nets then return nil end
	local st = ensureDerived()
	local box = nil
	for n in pairs(nets) do
		local net = st.nets[n]
		if net and net.box and net.box.minX then
			box = box or {}
			widen(box, net.box.minX, net.box.minY, net.box.maxX, net.box.maxY)
		end
	end
	return box
end

--- Every network, for the fixtures a barrel's plumbing-in has to reach.
function EP.pipeNetList()
	return ensureDerived().nets
end

--- One box round every network, or nil when nothing is laid.
---
--- The cheap test in front of the expensive one, for the callers that walk a registry
--- holding every sink a player has ever streamed past: a fixture outside this box is on no
--- network, and it costs four comparisons to find that out instead of a square lookup, a
--- building resolution and a key.
function EP.pipeNetsUnionBox()
	if not EP.anyPipes() then return nil end
	local st = ensureDerived()
	if st.unionBox ~= nil then return st.unionBox or nil end
	local box = {}
	for _, net in ipairs(st.nets) do
		if net.box and net.box.minX then widen(box, net.box.minX, net.box.minY, net.box.maxX, net.box.maxY) end
	end
	st.unionBox = box.minX and box or false
	return st.unionBox or nil
end

--- Is a fixture at (x, y, z) on a network that is supplied?  The cursor's question.
function EP.pipeFixtureSupplied(x, y, z)
	local box = EP.pipeNetsUnionBox()
	if not box or x < box.minX or x > box.maxX or y < box.minY or y > box.maxY then return false end
	local nets = EP.pipeNetsAt(x, y, z, true)
	if not nets then return false end
	for n in pairs(nets) do
		if EP.pipeNetSupplied(n) then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- supplied
--------------------------------------------------------------------------------

--- Which networks have a plumbed-in barrel, and what each could serve.
---
--- `supplied` is the colour: any plumbed-in barrel on it, loaded or not - a barrel whose
--- chunk has closed is still plumbed in and its water comes back with it.  The collector
--- registry keeps the last-seen `included` on each entry for exactly that.
---
--- `serve` is the first-click answer, and it counts only barrels the authority can SEE
--- right now.  A group is built from objects, so a barrel in a closed chunk feeds nothing
--- until it opens; a summary that promised otherwise would have a client offer Plumb onto
--- a group the authority cannot build.
local function recomputeSupply()
	local st = ensureDerived()
	local changed = false

	local was = {}
	for _, net in ipairs(st.nets) do
		was[net.index] = { supplied = net.supplied, serve = net.serve }
		net.supplied, net.serve = false, {}
	end

	if #st.nets > 0 and EP.eachCollector then
		-- One box round everything, so a barrel in the next town costs four comparisons.
		local all = {}
		for _, net in ipairs(st.nets) do
			if net.box and net.box.minX then widen(all, net.box.minX, net.box.minY, net.box.maxX, net.box.maxY) end
		end

		EP.eachCollector(function(entry)
			if not all.minX or entry.x < all.minX or entry.x > all.maxX
				or entry.y < all.minY or entry.y > all.maxY then return end

			local nets = EP.pipeNetsAt(entry.x, entry.y, entry.z, false)
			if not nets then return end

			local object = EP.sourceAt(entry.x, entry.y, entry.z)
			local included
			if object then
				included = EP.isIncluded(object)
				entry.included = included
			else
				included = entry.included == true
			end
			if not included then return end

			local liquid, pumped = nil, false
			if object then
				liquid = EP.canonicalFluidType(EP.barrelFluidType(object)) or EP.FLUID_DEFAULT
				pumped = EP.hasPump(object) == true
			end

			for n in pairs(nets) do
				local net = st.nets[n]
				if net then
					net.supplied = true
					if liquid then
						local s = net.serve[liquid]
						if not s then
							net.serve[liquid] = { top = entry.z, pumped = pumped }
						else
							if entry.z > s.top then s.top = entry.z end
							if pumped then s.pumped = true end
						end
					end
				end
			end
		end)
	end

	local summaries = {}
	for _, net in ipairs(st.nets) do
		summaries[net.index] = { supplied = net.supplied, serve = net.serve, defs = net.defs }
		local before = was[net.index]
		if not before or before.supplied ~= net.supplied then changed = true
		else
			for liquid, s in pairs(net.serve) do
				local b = before.serve and before.serve[liquid]
				if not b or b.top ~= s.top or b.pumped ~= s.pumped then changed = true end
			end
			for liquid in pairs(before.serve or {}) do
				if not net.serve[liquid] then changed = true end
			end
		end
	end
	EP.pipeNets = summaries

	supplyDirty = false
	suppliedAt = nowMs()
	return changed
end

--- Is network `n` supplied, as of the last recompute?  The cursor's gate asks this; a second
--- of staleness costs a fixture one lap.
function EP.pipeNetSupplied(n)
	local s = EP.pipeNets[n]
	return s ~= nil and s.supplied == true
end

--- Bring the supply up to date now, for a caller that cannot wait for the driver.
function EP.pipeSupplyNow()
	ensureDerived()
	if supplyDirty then return recomputeSupply() end
	return false
end

--------------------------------------------------------------------------------
-- telling the clients
--------------------------------------------------------------------------------

local broadcastWanted = true

--- THE SET, BUILT ONCE PER GENERATION AND NOT ONCE PER ASK.
---
--- `EP.packPipeSet` is 120,000 table appends for a 30,000-piece store, and `sendTo` called it
--- fresh for every HELLO.  One 38-byte HELLO produced 2,160,766 bytes of answer - an
--- amplifier of 56,862 - with no rate limit anywhere, so a client at the 300-command/sec cap
--- turns 12 KB/s of asks into hundreds of MB/s of outbound and tens of millions of table
--- appends a second on the main loop.  Even honestly, thirty players rejoining after a
--- restart is thirty of those in a burst.
---
--- Cached against `pipeVersion`, which is bumped by every lay, lift, adopt and derivation -
--- so a second ask in the same generation re-sends the table the first one built.
local packedCache, packedGen = nil, nil

local function packed()
	if packedCache and packedGen == pipeVersion then return packedCache end
	local args = EP.packPipeSet(floors, walls, EP.pipeNets)
	args.gen = pipeVersion
	packedCache, packedGen = args, pipeVersion
	return args
end

--- To everybody.  A multiplayer client's gates read the pieces and the summaries, so every
--- change goes out whole - it is a handful of numbers per piece.  Nothing to do in
--- singleplayer, where EP.floorPipes IS the store.
--- IN PARTS WHEN IT IS BIG (BR-LGEE-025).  The set is one row per iron pipe anybody has
--- ever laid, so it grows with the world and a big server's goes past the connection's
--- one-megabyte buffer - past which the engine sends NOTHING and says nothing about it.
--- See EP.splitPacket.
-- [Malcolm_Perf] Everything a client or LGEPPlumbing can see of the derived networks, as one
-- string, so an identical re-derive can be told from a real change.
local lastSignature = nil
local function networkSignature()
	local parts = {}
	local function sortedKeys(t)
		local out = {}
		for k in pairs(t or {}) do out[#out + 1] = tostring(k) end
		table.sort(out)
		return out
	end
	for _, k in ipairs(sortedKeys(floors)) do parts[#parts + 1] = "f" .. k .. "=" .. tostring(floors[k].net) end
	for _, k in ipairs(sortedKeys(walls)) do parts[#parts + 1] = "w" .. k .. "=" .. tostring(walls[k].net) end
	for _, net in ipairs(state.nets or {}) do
		parts[#parts + 1] = "n" .. tostring(net.index) .. ":" .. tostring(net.supplied)
		for _, liquid in ipairs(sortedKeys(net.serve)) do
			local sv = net.serve[liquid]
			parts[#parts + 1] = "s" .. liquid .. ":" .. tostring(sv.top) .. ":" .. tostring(sv.pumped)
		end
		for _, d in ipairs(sortedKeys(net.defs)) do parts[#parts + 1] = "d" .. d end
		local structs = {}
		for i = 1, #(net.structs or {}) do
			local at = net.structs[i]
			structs[#structs + 1] = tostring(at.x) .. "," .. tostring(at.y) .. "," .. tostring(at.z)
		end
		table.sort(structs)
		for i = 1, #structs do parts[#parts + 1] = "t" .. structs[i] end
		local b = net.box or {}
		parts[#parts + 1] = "b" .. tostring(b.minX) .. "," .. tostring(b.minY) .. "," .. tostring(b.maxX) .. "," .. tostring(b.maxY)
	end
	return table.concat(parts, ";")
end

-- [Malcolm_Perf] For the registry's hot set: pipe pieces, and network boxes as already derived
-- (never derives on its own).
if EP.reg then
	EP.reg.eachPipe = function(fn)
		for _, row in pairs(floors) do fn(row.x, row.y, row.z) end
		for _, row in pairs(walls) do fn(row.x, row.y, row.z) end
	end
	EP.reg.eachNetBox = function(fn)
		for _, net in ipairs(state.nets or {}) do
			if net.box and net.box.minX then fn(net.box) end
		end
	end
end

local function broadcast()
	broadcastWanted = false
	if not isServer() then return end
	EP.sendSplit(nil, EP.COMMAND_PIPES, packed(), EP.PIPE_SET_FIELDS, EP.PIPE_SET_KEEP)
end

--- The suite's way in: `broadcast` is a local and the claim being defended is about what
--- reaches the wire, which nothing else here can drive.
EP.broadcastPipesForTest = broadcast

--- To one player, who asked.
local function sendTo(player)
	if not isServer() or not player then return end
	EP.sendSplit(player, EP.COMMAND_PIPES, packed(), EP.PIPE_SET_FIELDS, EP.PIPE_SET_KEEP)
end

--- The driver: derivation, supply and broadcast, on the authority's own tick, and one
--- comparison when nothing has moved.
Events.OnTick.Add(function()
	if not EP.getOption("Enabled") then return end
	local now = nowMs()

	if not topologyDirty and state.anyStructs and derivedAt
		and now - derivedAt >= PIPE_REDERIVE_SECONDS * 1000 then
		topologyDirty = true
	end
	if arrivalWakeAt and now >= arrivalWakeAt
		and (not derivedAt or now - derivedAt >= math.max(ARRIVAL_MIN_GAP_MS, lastDeriveMs * ARRIVAL_DUTY)) then
		arrivalWakeAt = nil
		topologyDirty = true
	end

	if not topologyDirty and not supplyDirty and not broadcastWanted then return end
	if supplyDirty and suppliedAt and now - suppliedAt < SUPPLY_MIN_SECONDS * 1000
		and not topologyDirty and not broadcastWanted then return end

	local ok, err = pcall(function()
		local reshaped = topologyDirty
		ensureDerived()
		local moved = supplyDirty and recomputeSupply() or false
		-- [Malcolm_Perf] A re-derive that comes out exactly as the last one (the 60 s timer, or
		-- a chunk with pipes arriving) is not a change: no new generation, no scope-changed
		-- cascade into LGEPPlumbing, no resend to every client.  Anything that differs - a net,
		-- a building or player structure joining or leaving one, a supply going blue or white,
		-- a liquid, a top floor, a pump - changes the signature and goes through as before.
		if (reshaped or moved) and not broadcastWanted then
			local sig = networkSignature()
			if sig == lastSignature then
				reshaped, moved = false, false
			else
				lastSignature = sig
				if EP.reg then EP.reg.invalidate() end
			end
		elseif reshaped or moved then
			lastSignature = networkSignature()
			if EP.reg then EP.reg.invalidate() end
		end
		if reshaped or moved or broadcastWanted then
			pipeVersion = pipeVersion + ((reshaped or moved) and 1 or 0)
			EP.pipeGeneration = pipeVersion
			-- A network going blue or white changes which fixtures can be served, and the
			-- refusal memory in LGEPPlumbing is keyed on its supply version.  A re-derive
			-- always lands here as `moved`: deriveNow hands recomputeSupply fresh networks
			-- reading unsupplied, so a house rejoining its run (BR-LGEP-083) is announced
			-- with no test of its own - measured, lgep_spec_chunkreturn section 5.
			if moved and EP.onPipeScopeChanged then EP.onPipeScopeChanged("a network's supply moved") end
			broadcast()
		end
	end)
	if not ok then
		-- NOT CLEARED, AND THIS USED TO CLEAR THEM.
		--
		-- `recomputeSupply` zeroes every network's `supplied` and `serve` first and fills
		-- them in afterwards, so a throw part way through leaves every network reading
		-- UNSUPPLIED. Clearing the dirty flags on the way out of that threw away the only
		-- thing that would have recomputed it - and `EP.pipeSupplyNow()` gates on the same
		-- flag, so the escape hatch went with it. Every pipe run turns white at once, every
		-- tap fed only through pipes answers "No supply reaches this", and nothing short of
		-- a lay, a lift or a world reload brings it back.
		--
		-- Left set, so the next tick tries again. A fault that repeats is a fault that
		-- repeats in the log, which is the right outcome: `EP.logFault` latches the message
		-- after the first, so it costs one line and not a flood.
		EP.logFault("pipe-driver", "ERROR bringing the pipe networks up to date: " .. tostring(err))
	end
end)

--- A heartbeat, because a set pushed only on change is wrong for ever after one lost packet
--- (memory/ongamestart-cannot-send-client-commands.md).
--- [Malcolm_Perf] Kept, but every six game hours instead of every ten game minutes (which at
--- the default day length was a full resend to every client about every 25 real seconds).
--- New players still get the set on join through COMMAND_PIPE_HELLO, and every real change is
--- still broadcast at once.
local heartbeatHours = 0
Events.EveryHours.Add(function()
	heartbeatHours = heartbeatHours + 1
	if heartbeatHours < 6 then return end
	heartbeatHours = 0
	if isServer() and EP.anyPipes() then broadcastWanted = true end
end)

--------------------------------------------------------------------------------
-- the ledger
--------------------------------------------------------------------------------

--- A working pipe wrench, found the way vanilla's own Plumb finds one.
local function wrenchOf(player)
	if not player or not player.getInventory then return nil end
	local ok, inventory = pcall(player.getInventory, player)
	if not ok or not inventory then return nil end
	local notBroken = function(item) return not item:isBroken() end
	local wrench = inventory.getFirstTypeEvalRecurse
		and inventory:getFirstTypeEvalRecurse("PipeWrench", notBroken) or nil
	if not wrench and inventory.getFirstTagEvalRecurse and ItemTag and ItemTag.PIPE_WRENCH then
		wrench = inventory:getFirstTagEvalRecurse(ItemTag.PIPE_WRENCH, notBroken)
	end
	return wrench
end

--- Take one iron pipe off this player.  Returns its condition, or nil when none could go.
---
--- LGEE's wireSpend, shape for shape: the container is read BEFORE the removal, because
--- ItemContainer.Remove nils it; the removal is the charge and the announce is a message,
--- so they are two pcalls and a lost message is never a second charge; and the hands are
--- a packet of their own that the engine will not send for us.
local function pipeSpend(player)
	if not player or not player.getInventory then return nil end
	local ok, inventory = pcall(player.getInventory, player)
	if not ok or not inventory or not inventory.getFirstTypeEvalRecurse then return nil end

	local notBroken = function(item) return not item:isBroken() end
	local found, item = pcall(inventory.getFirstTypeEvalRecurse, inventory, EP.PIPE_TYPE, notBroken)
	if not found or not item then return nil end

	local held = false
	if player.isPrimaryHandItem then
		local okp, p = pcall(player.isPrimaryHandItem, player, item)
		local oks, s = pcall(player.isSecondaryHandItem, player, item)
		held = (okp and p == true) or (oks and s == true)
	end

	local container = item:getContainer() or inventory
	local cond = item.getCondition and item:getCondition() or nil

	local moved = pcall(function()
		if player.removeFromHands then player:removeFromHands(item) end
		container:Remove(item)
	end)
	if not moved then return nil end

	if sendRemoveItemFromContainer then pcall(sendRemoveItemFromContainer, container, item) end
	if held and sendEquip then pcall(sendEquip, player) end

	return cond or -1
end

--- Give one iron pipe back, in the condition it was laid in.  Returns 1 or 0.
local function pipeRefund(player, cond)
	if not player or not player.getInventory then return 0 end
	local ok, inventory = pcall(player.getInventory, player)
	if not ok or not inventory or not inventory.AddItem then return 0 end

	local made, item = pcall(inventory.AddItem, inventory, EP.PIPE_ITEM)
	if not made or not item then return 0 end

	-- Before the announce, so the packet carries the condition rather than a fresh pipe
	-- the client is then told about separately.
	if type(cond) == "number" and cond >= 0 and item.setCondition then
		pcall(item.setCondition, item, cond)
	end

	if sendAddItemToContainer then pcall(sendAddItemToContainer, inventory, item) end
	return 1
end

--------------------------------------------------------------------------------
-- the acts
--------------------------------------------------------------------------------

--- Tell the player who did the work what happened.  Always sent, refusal included: the
--- window is waiting on an answer, and silence is the one response it cannot draw.
local function deliver(player, ok, reason, x, y, z, gave)
	local args = { x = x, y = y, z = z, ok = ok == true, reason = reason, gave = gave or 0 }
	if isServer() then
		if player then sendServerCommand(player, EP.COMMAND_MODULE, EP.COMMAND_PIPE_DONE, args) end
	elseif EP.onPipeDone then
		EP.onPipeDone(args)
	end
end

--- Every lay and lift.  The two existing counters every scope change moves are moved here
--- too - a walk in flight is thrown away and a remembered refusal is asked again - and the
--- set goes out to every client.
local function piecesChanged(why, x, y, z)
	-- THE PLAYER'S OWN ACT IS ANSWERED FRESH.  See areaAtCached: everything else keeps its
	-- tile answers, and the tiles round the piece that moved lose theirs.
	if x then forgetAreaNear(x, y, z) end
	pipeVersion = pipeVersion + 1
	EP.pipeGeneration = pipeVersion
	EP.markPipesDirty()
	broadcastWanted = true
	if EP.onPipeScopeChanged then EP.onPipeScopeChanged(why) end
	EP.log("pipes: " .. why)
end

local function floorBlocked(x, y, z)
	if floors[EP.pipeKey(x, y, z)] then return EP.PIPE_OCCUPIED end
	local square = getCell():getGridSquare(x, y, z)
	if not square then return EP.PIPE_NO_SQUARE end
	-- A pipe lies on a floor.  Open air over a yard is a square once something has been put
	-- there, and a pipe in it would join a roof run to nothing anybody can stand on.
	-- `TreatAsSolidFloor`, NOT `isSolidFloor`, AND THEY ARE NOT THE SAME QUESTION.
	--
	-- `isSolidFloor()` is a bare field read (`IsoGridSquare.java:9904-9906`). The only thing in
	-- the engine that ever COMPUTES that field is `TreatAsSolidFloor()` (`:8179-8192`), which
	-- caches it under `solidFloorCached`; `setSolidFloor()` has no caller anywhere in the jar.
	-- And `solidFloorCached` is cleared WITHOUT recomputing by `ReCalculateAll`,
	-- `ReCalculateMineOnly` and friends (`:5407`, `:5424`, `:5454`, `:5477`, `:5522`) - which
	-- is chunk load, and every object added or removed nearby.
	--
	-- So `isSolidFloor()` answers false for any square whose `TreatAsSolidFloor()` has not run
	-- since the last recalc, which is most of the world and specifically open ground - what
	-- floor pipes are for. Which tiles worked was arbitrary (the ones somebody had walked
	-- over), and a tile that worked stopped working the moment anything was built beside it.
	-- Worse on a dedicated server, where the authority's squares are warmed only by
	-- pathfinding, so it refused acts the client's own cursor had shown green.
	--
	-- Vanilla asks the computing form in all thirteen of its Lua call sites, including this
	-- very question for a rain barrel (`RainCollectorBarrel.lua:69`). The stub answered
	-- permissively, so no suite could see it.
	if square.TreatAsSolidFloor and not square:TreatAsSolidFloor() then
		return EP.PIPE_NO_SQUARE
	end
	return nil
end

local function wallBlocked(x, y, z, north)
	if walls[EP.wallPipeKey(x, y, z, north)] then return EP.PIPE_OCCUPIED end
	local square = getCell():getGridSquare(x, y, z)
	if not square then return EP.PIPE_NO_SQUARE end
	-- Vanilla's own "anything on this edge": walls, corners, window and door frames, tall
	-- fences.  Asked of the OWNING square, which the window resolved before sending.
	if not square.getWall or not square:getWall(north == true) then return EP.PIPE_NO_WALL end
	return nil
end

--- Is this a place a piece could go?  Exposed so the window's fast no and the authority's
--- real one are the same function.
EP.pipeFloorBlocked = floorBlocked
EP.pipeWallBlocked = wallBlocked

--- LAY A PIECE.  `north` is nil for a floor pipe; for a wall pipe (x, y) is the square that
--- OWNS the wall.  The price is taken before the row exists, whole or not at all.
--- IS THE SENDER ANYWHERE NEAR THE PIECE THEY ARE MOVING?
---
--- NOTHING ASKED, until 2026-09-17.  The plumb commands go through `OnClientCommand` and are
--- gated by `commandAllowed` - same building, or within Reach - but a pipe act is not a
--- command: it is a timed action, and the engine rebuilds it on the server through
--- `NetTimedAction`, whose `isValid()` is a bare `return false`.  So `LGEPPipeAction:isValid`
--- never runs on this side and `complete()` was the entire gate: Enabled, the square, a
--- wrench, an iron pipe.  Not one line read the character's position.
---
--- Measured: with the player standing at 30,15, `complete()` laid a pipe at 88,28 - fifty-
--- eight tiles away, with Reach at 12 - and a character object with no `getX` at all laid one
--- too.  Lifting a far piece worked and refunded the iron pipe.
---
--- WHAT THAT IS WORTH TO A GRIEFER: every client is broadcast the whole pipe set, coordinates
--- included, so a modified client can read every run on the server and lift the lot from its
--- own base, collecting the iron pipe as it goes.  The owner watches a run disappear with
--- nothing to point at.  The same hole lays pipe INTO somebody else's building, which changes
--- what their fixtures are connected to.
---
--- The same rule as `commandAllowed`, deliberately: a player may touch their own building, or
--- anything within Reach of where they are standing.  A caller with no position - singleplayer
--- calling in, and every suite - is allowed, which is what `commandAllowed` does too.
local function senderMayReach(player, x, y, z)
	if not player or not player.getX or not player.getY or not player.getZ then return true end

	local ok, px, py, pz = pcall(function()
		return player:getX(), player:getY(), player:getZ()
	end)
	if not ok or type(px) ~= "number" or type(py) ~= "number" or type(pz) ~= "number" then
		return true
	end
	px, py, pz = math.floor(px), math.floor(py), math.floor(pz)

	local mine = EP.buildingAt(px, py, pz)
	local theirs = EP.buildingAt(x, y, z)
	if mine and theirs and EP.sameDef(mine, theirs) then return true end

	-- WITH A FLOOR UNDER IT.  Reach has min = 1 in sandbox-options, and the honest player is
	-- at exactly 1: `LGEPAreaUI:act` calls `luautils.walkAdj` (or `walkAdjWall` for a wall)
	-- before it queues the action, so they are standing on a neighbouring tile.  A gate of
	-- `<= 1` therefore has no slack at all for the server's copy of where they are, which on a
	-- dedicated server trails the client's by whatever the last movement packet said.  Two
	-- tiles costs the griefer nothing - the hole this closes is a lift from forty tiles away.
	local reach = EP.getOption("Reach")
	if reach < 2 then reach = 2 end
	return math.max(math.abs(px - x), math.abs(py - y)) <= reach
end

local function lay(x, y, z, north, player)
	if not EP.isAuthority() then return end
	local isWall = north ~= nil
	if not EP.getOption("Enabled") then deliver(player, false, EP.PIPE_DISABLED, x, y, z); return end

	-- WRITTEN OUT, NOT `isWall and wallBlocked(...) or floorBlocked(...)`.
	--
	-- That reads correctly and is wrong exactly when the wall check PASSES: `true and nil` is
	-- nil, so Lua falls through to the `or` and a wall pipe was asked whether there was a
	-- FLOOR pipe on its tile - which there very often is, because a riser is laid where a run
	-- reaches a wall.  Reported by LG on the first read: "a vertical pipe should be able to be
	-- placed in the same tile as a ground pipe already being installed, and vice versa".  The
	-- other order worked, which is what kept it out of the suite.
	local blocked
	if isWall then
		blocked = wallBlocked(x, y, z, north)
	else
		blocked = floorBlocked(x, y, z)
	end
	if blocked then deliver(player, false, blocked, x, y, z); return end

	if not wrenchOf(player) then deliver(player, false, EP.PIPE_NO_WRENCH, x, y, z); return end

	-- AFTER the square and the wrench, deliberately.  Both of those are more specific and are
	-- what the player most likely got wrong; being out of reach is the rarer answer and the
	-- one only a modified client ever sees.  Putting it first turned "there is nothing to lay
	-- it on" into "you cannot get there", which is a worse message for the honest case.
	if not senderMayReach(player, x, y, z) then
		EP.log(("refused a lay at %d,%d,%d: not the sender's building, and out of reach")
			:format(x, y, z))
		deliver(player, false, EP.PIPE_NO_WALK, x, y, z)
		return
	end

	local cond = pipeSpend(player)
	if cond == nil then deliver(player, false, EP.PIPE_NO_PIPE, x, y, z); return end

	local row = { x = x, y = y, z = z, cost = EP.PIPE_COST, cond = cond >= 0 and cond or nil }
	if isWall then
		row.north = north == true
		walls[EP.wallPipeKey(x, y, z, row.north)] = row
	else
		floors[EP.pipeKey(x, y, z)] = row
	end

	piecesChanged(("a %s was laid at %d,%d,%d"):format(isWall and "wall pipe" or "pipe", x, y, z), x, y, z)

	-- NOW, NOT WITHIN A LAP.  Somebody has just stood there with a wrench for a hundred
	-- ticks; a tap at the other end that took a lap to notice would read as the pipe not
	-- working.  A wide service from the piece reaches every fixture on its network (see
	-- serviceAround).  A LIFT does not need this: the counters it moves make every mirror
	-- re-settle, and one that has lost its supply is what the settle is for.
	if EP.serviceAround then
		local ok, err = pcall(EP.serviceAround, x, y, z, true)
		if not ok then EP.logFault("pipe-service", "ERROR servicing a new pipe's network: " .. tostring(err)) end
	end

	deliver(player, true, nil, x, y, z, 0)
end

--- LIFT A PIECE.  Anybody may lift anybody's pipe; the refund, at the condition stamped on
--- the row, goes to whoever does the work.  A wrench is needed to take one apart, as LG
--- chose, and the refusal comes before anything moves.
local function lift(x, y, z, north, player)
	if not EP.isAuthority() then return end
	local isWall = north ~= nil
	-- Safe as written - a key is a string and a store is a table, so neither middle value can
	-- be nil - but see the note in `lay` before turning any of these into a test that can be.
	local key = isWall and EP.wallPipeKey(x, y, z, north == true) or EP.pipeKey(x, y, z)
	local store = isWall and walls or floors
	local row = store[key]
	if not row then deliver(player, false, EP.PIPE_NOT_OURS, x, y, z); return end

	-- The same gate as `lay`, and it matters more here: lifting hands the iron pipe back, so
	-- an ungated lift is somebody else's run turned into your inventory.
	if not senderMayReach(player, x, y, z) then
		EP.log(("refused a lift at %d,%d,%d: not the sender's building, and out of reach")
			:format(x, y, z))
		deliver(player, false, EP.PIPE_NO_WALK, x, y, z)
		return
	end

	if not wrenchOf(player) then deliver(player, false, EP.PIPE_NO_WRENCH, x, y, z); return end

	store[key] = nil
	piecesChanged(("a %s was lifted at %d,%d,%d"):format(isWall and "wall pipe" or "pipe", x, y, z), x, y, z)

	local given = 0
	for _ = 1, (row.cost or 0) do given = given + pipeRefund(player, row.cond) end
	if (row.cost or 0) > given and player then
		EP.logFault("pipe-refund", ("handed back only %d of %d iron pipe for the piece at %d,%d,%d")
			:format(given, row.cost or 0, x, y, z))
	end
	deliver(player, true, nil, x, y, z, given)
end

function EP.layPipe(x, y, z, player) lay(x, y, z, nil, player) end
function EP.liftPipe(x, y, z, player) lift(x, y, z, nil, player) end
function EP.layWallPipe(x, y, z, north, player) lay(x, y, z, north == true, player) end
function EP.liftWallPipe(x, y, z, north, player) lift(x, y, z, north == true, player) end

--- For a suite that needs the live tables after a simulated restart.
function EP.pipeStoreForTest() return floors, walls end

--------------------------------------------------------------------------------
-- the window's question
--------------------------------------------------------------------------------

--- How far round the asker the answer reaches.  Bigger than the client's own drawing
--- window (the loaded chunk map, about 52 tiles either side) by more than the window's
--- re-centring threshold, so a walking player does not out-run their own answer.
--- A client may ask for the whole set at most this often.  See `packed`.
local HELLO_MIN_MS = 1000
local helloLastAt = {}

local AREA_WINDOW = 150
local AREA_MIN_MS = 900
local areaLastAt = {}

--- What the window draws, round (x, y), as one flat answer.
---
---     nets     supplied (1/0) per network index
---     floors   x, y, z, net ...                        pieces inside the window
---     walls    x, y, z, north (1/0), net ...
---     areas    x1, y1, x2, y2, z1, z2, net ...          building areas, per building
---
--- A building's area is its plan grown by one (the relax plan EP.buildingAt uses) over
--- its levels and the roof above them, for a map building; a structure's is the chunk
--- box of its regions over its level and the one above.  `net` 0 is a building held by
--- a plumbed barrel with no pipe touching it - a network of one, supplied by definition.
local function areaAnswer(cx, cy, cz)
	local st = ensureDerived()
	if supplyDirty then recomputeSupply() end

	local minX, minY = cx - AREA_WINDOW, cy - AREA_WINDOW
	local maxX, maxY = cx + AREA_WINDOW, cy + AREA_WINDOW
	local function inside(x, y) return x >= minX and x <= maxX and y >= minY and y <= maxY end

	local args = { x = cx, y = cy, z = cz }
	local n, f, w, a = {}, {}, {}, {}

	for i = 1, #st.nets do n[#n + 1] = st.nets[i].supplied and 1 or 0 end

	for _, row in pairs(floors) do
		if inside(row.x, row.y) then
			f[#f + 1] = row.x; f[#f + 1] = row.y; f[#f + 1] = row.z; f[#f + 1] = row.net or 0
		end
	end
	for _, row in pairs(walls) do
		if inside(row.x, row.y) then
			w[#w + 1] = row.x; w[#w + 1] = row.y; w[#w + 1] = row.z
			w[#w + 1] = row.north and 1 or 0; w[#w + 1] = row.net or 0
		end
	end

	local drawn = {}
	local function addDef(def, net)
		if not def then return end
		local id = def:getIDString()
		if drawn[id] then return end
		drawn[id] = true
		local b = EP.buildingBounds(def)
		if not b then return end
		if b.maxX + 1 < minX or b.minX - 1 > maxX or b.maxY + 1 < minY or b.minY - 1 > maxY then return end
		a[#a + 1] = b.minX - 1; a[#a + 1] = b.minY - 1; a[#a + 1] = b.maxX + 1; a[#a + 1] = b.maxY + 1
		a[#a + 1] = b.minZ; a[#a + 1] = b.maxZ + 1; a[#a + 1] = net
	end
	local function addStruct(at, net)
		local regions = EP.regionsAt(at.x, at.y, at.z)
		local rb = regions and EP.regionBounds(regions) or nil
		if not rb then return end
		local key = rb.minX .. ":" .. rb.minY .. ":" .. rb.maxX .. ":" .. rb.maxY .. ":" .. at.z
		if drawn[key] then return end
		drawn[key] = true
		a[#a + 1] = rb.minX; a[#a + 1] = rb.minY; a[#a + 1] = rb.maxX; a[#a + 1] = rb.maxY
		a[#a + 1] = at.z - 1; a[#a + 1] = at.z + 1; a[#a + 1] = net
	end

	for _, net in ipairs(st.nets) do
		for i = 1, #net.structs do
			if inside(net.structs[i].x, net.structs[i].y) then addStruct(net.structs[i], net.index) end
		end
	end
	for id, idx in pairs(st.defNet) do
		local net = st.nets[idx]
		local at = net and net.buildings["B" .. id]
		if at and inside(at.x, at.y) then addDef(EP.mapBuildingAt(at.x, at.y, at.z), idx) end
	end

	-- AND EVERY BUILDING HELD BY A PLUMBED BARREL, pipes or not: "no need to show a house's
	-- plumbing till there is at least one barrel plumbed in or an adjacent piped tile".
	if EP.eachCollector then
		EP.eachCollector(function(entry)
			if not inside(entry.x, entry.y) then return end
			local object = EP.sourceAt(entry.x, entry.y, entry.z)
			local included
			if object then included = EP.isIncluded(object) else included = entry.included == true end
			if not included then return end
			local def = EP.mapBuildingAt(entry.x, entry.y, entry.z)
			if def and not (def.isUserDefined and def:isUserDefined()) then
				addDef(def, st.defNet[def:getIDString()] or 0)
			else
				local regions = EP.regionsAt(entry.x, entry.y, entry.z)
				if regions then addStruct({ x = entry.x, y = entry.y, z = entry.z }, 0) end
			end
		end)
	end

	args.nets, args.floors, args.walls, args.areas = n, f, w, a
	args.nn, args.nf, args.nw, args.na = #n, #f, #w, #a
	return args
end

EP.pipeAreaAnswer = areaAnswer

--- A player has the window open and is standing at (x, y, z).
---
--- Answered in the frame it is asked - there is no job to queue, because the pieces are
--- few and every building lookup is a bucket read - but rate-limited per player, silently,
--- because the window re-asks on its own clock and a dropped ask is answered by the next.
function EP.requestPipeArea(x, y, z, player)
	if not EP.isAuthority() then return end
	local who = (player and player.getUsername and player:getUsername()) or "*"
	local now = nowMs()
	local last = areaLastAt[who]
	if last and now - last < AREA_MIN_MS then return end
	areaLastAt[who] = now

	local args = areaAnswer(x, y, z)
	-- The window is ONE player's, and it is capped at a 301x301 box - but a base inside
	-- that box can hold thousands of pieces, so this grows with the world too.  Split for
	-- the same reason the set is.
	if isServer() then
		if player then
			EP.sendSplit(player, EP.COMMAND_PIPE_AREA_RESULT, args,
				EP.PIPE_AREA_FIELDS, EP.PIPE_AREA_KEEP)
		end
	elseif EP.onPipeAreaResult then
		EP.onPipeAreaResult(args)
	end
end

--------------------------------------------------------------------------------
-- the wire
--------------------------------------------------------------------------------

Events.OnClientCommand.Add(function(module, command, player, args)
	if module ~= EP.COMMAND_MODULE then return end
	if command ~= EP.COMMAND_PIPE_HELLO and command ~= EP.COMMAND_PIPE_AREA then return end

	-- SWITCHED OFF MEANS SWITCHED OFF ON THIS WIRE TOO.  Every other entry point gates on it -
	-- the plumb handler, the driver, `lay`, `lift` - and this one did not, so a server with the
	-- mod disabled still answered up to forty HELLOs per connecting client with a full
	-- `ensureDerived` and a broadcast of the whole set. That is BR-LGEP-044's amplifier path,
	-- rate-limited but alive, for a feature nobody can reach.
	if not EP.getOption("Enabled") then return end

	local ok, err
	if command == EP.COMMAND_PIPE_HELLO then
		-- The same per-player floor `requestPipeArea` has.  A client asks at most twice a
		-- second by its own timer, so an honest one never meets this.
		local who = (player and player.getUsername and player:getUsername()) or "*"
		local now = nowMs()
		if helloLastAt[who] and now - helloLastAt[who] < HELLO_MIN_MS then return end
		helloLastAt[who] = now

		ok, err = pcall(function()
			ensureDerived()
			if supplyDirty then recomputeSupply() end
			sendTo(player)
		end)
	else
		if type(args) ~= "table" then return end
		local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
		if not x or not y or not z or z < -32 or z > EP.MAX_LEVEL then return end
		-- YOU MAY ONLY ASK ABOUT WHERE YOU ARE.  The centre is the asker's own position, so a
		-- sender more than a window away from what they named is not a window.
		--
		-- AND IT FAILS CLOSED.  This was `if player and player.getX then`, which skipped the
		-- whole test for a sender the gate could not read - and `math.floor(nan)` is nan, so
		-- every comparison below came back false and a nan position passed it too.  A gate
		-- that lets through exactly the callers it cannot understand is not a gate.
		--
		-- Nothing legitimate is refused: this handler only ever runs on a server, where the
		-- engine hands `OnClientCommand` a real IsoPlayer.  Singleplayer and the suites call
		-- `EP.requestPipeArea` directly and never reach this line.
		local px, py
		local pok = player ~= nil and player.getX ~= nil and player.getY ~= nil
		if pok then
			pok = pcall(function() px, py = player:getX(), player:getY() end)
		end
		if not pok or type(px) ~= "number" or type(py) ~= "number"
			or px ~= px or py ~= py then
			EP.log("refused an area ask: the sender has no position this side can read")
			return
		end
		px, py = math.floor(px), math.floor(py)
		if math.abs(px - x) > AREA_WINDOW or math.abs(py - y) > AREA_WINDOW then return end
		ok, err = pcall(EP.requestPipeArea, x, y, z, player)
	end
	if not ok then EP.logFault("pipe-command", "ERROR answering a pipe command: " .. tostring(err)) end
end)

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
if EP.checkBuild then
	EP.checkBuild("LGEPPipes.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPPipes.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
