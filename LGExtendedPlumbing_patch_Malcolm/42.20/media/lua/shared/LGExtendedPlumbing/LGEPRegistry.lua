--
-- Extended Plumbing - registry of plumbed spots  [LOCAL PERFORMANCE PATCH, Malcolm_Perf]
--
-- Not part of LittleGroove's original mod. Added by the LGExtendedPlumbing_patch_Malcolm
-- variant so the per-square LoadGridsquare handler can return at once for squares that have
-- nothing to do with plumbing.
--
-- What it keeps, in global ModData on the authority (server / singleplayer) only:
--   spots   : square key -> bit set of what plumbing lives there
--             (1 = plumbed-in collector, 2 = hidden water store, 4 = topped-up fixture)
--   scanned : chunk key -> true once that chunk has had its one-time migration look
--
-- From those (plus the pipe store) it derives, in memory only, the set of HOT chunks: every
-- chunk a registered spot stands in, and every chunk under the building / reach box of a
-- plumbed collector or a pipe, which is where the original mod needs its full per-square
-- look.  Squares in hot chunks get exactly the original treatment.  Squares in a cold chunk
-- that was never scanned get a cheap look for anything that could be plumbing (migration of
-- existing saves); squares in a cold scanned chunk are skipped.
--
-- Nothing here is ever sent over the network.
--
require "LGExtendedPlumbing/LGEPCore"

local EP = LGEP
local R = EP.reg or {}
EP.reg = R

R.BIT_SRC, R.BIT_GHOST, R.BIT_FED = 1, 2, 4
R.STORE = "LGEPPerfRegistry"
R.CHUNK = 8
R.SCAN_SETTLE_MS = 3000      -- a chunk counts as scanned this long after its first square
R.REBUILD_MIN_GAP_MS = 1000  -- hot set rebuilt at most this often
R.RESCAN_PER_TICK = 1        -- newly hot, already loaded chunks given their full look per tick

local floor = math.floor

local spots, scanned = nil, nil
local hot = {}
local hotBuilt = false
local wantRebuild = true
local lastRebuild = nil
local unresolvedChunks = {}
local pendingScan = {}
local pendingAny = false
local rescanQueue, rescanSet = {}, {}
local unloadMarked = {}
local noticed = {}
local stats = { added = 0, removed = 0, rebuilds = 0, rescans = 0, skipped = 0, cheap = 0, full = 0 }
R.stats = stats

local function nowMs()
	if getTimestampMs then return getTimestampMs() end
	return 0
end
R.nowMs = nowMs

-- keys ------------------------------------------------------------------------------------

function R.spotKey(x, y, z)
	return (floor(x) * 32768 + floor(y)) * 64 + (floor(z) + 32)
end

function R.unpackSpot(k)
	local zz = k % 64
	local rest = (k - zz) / 64
	local y = rest % 32768
	local x = (rest - y) / 32768
	return x, y, zz - 32
end

function R.chunkKey(x, y)
	return floor(x / R.CHUNK) * 8192 + floor(y / R.CHUNK)
end

function R.unpackChunk(ck)
	local cy = ck % 8192
	return (ck - cy) / 8192, cy
end

local function hasBit(bits, b) return bits ~= nil and floor(bits / b) % 2 == 1 end
R.hasBit = hasBit

-- storage ---------------------------------------------------------------------------------

function R.ready() return spots ~= nil end

--- Attach to a store table (the ModData one in game, any table in tests).
function R.attach(store)
	if type(store.spots) ~= "table" then store.spots = {} end
	if type(store.scanned) ~= "table" then store.scanned = {} end
	-- Tolerate keys that came back from disk as strings.
	local s, c = {}, {}
	for k, v in pairs(store.spots) do
		local n = tonumber(k)
		if n and type(v) == "number" and v > 0 then s[n] = v end
	end
	for k, v in pairs(store.scanned) do
		local n = tonumber(k)
		if n and v then c[n] = true end
	end
	store.spots, store.scanned = s, c
	store.version = 1
	spots, scanned = s, c
	hot, hotBuilt, wantRebuild, lastRebuild = {}, false, true, nil
	unresolvedChunks, pendingScan, pendingAny = {}, {}, false
	rescanQueue, rescanSet, unloadMarked, noticed = {}, {}, {}, {}
	return store
end

function R.detach() spots, scanned = nil, nil end

function R.invalidate() wantRebuild = true end

function R.add(x, y, z, bit)
	if not spots or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return false end
	local k = R.spotKey(x, y, z)
	local bits = spots[k] or 0
	if hasBit(bits, bit) then return false end
	spots[k] = bits + bit
	stats.added = stats.added + 1
	-- its own chunk is hot from this moment, without waiting for a rebuild; if it is already
	-- loaded, the squares that went past before this one get their full look from the queue
	local ck = R.chunkKey(x, y)
	if not hot[ck] then
		hot[ck] = true
		if not rescanSet[ck] and R.chunkIsLoaded(ck) then
			rescanSet[ck] = true
			rescanQueue[#rescanQueue + 1] = ck
		end
	end
	wantRebuild = true
	return true
end

function R.remove(x, y, z, bit)
	if not spots or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return false end
	local k = R.spotKey(x, y, z)
	local bits = spots[k]
	if not hasBit(bits, bit) then return false end
	bits = bits - bit
	if bits <= 0 then spots[k] = nil else spots[k] = bits end
	stats.removed = stats.removed + 1
	wantRebuild = true
	return true
end

function R.bitsAt(x, y, z)
	if not spots then return 0 end
	return spots[R.spotKey(x, y, z)] or 0
end

function R.count()
	local n = 0
	if spots then for _ in pairs(spots) do n = n + 1 end end
	return n
end

-- hot set ---------------------------------------------------------------------------------

-- Hooks the server side fills in (left nil, the registry still works on spots alone).
R.boxFor = nil        -- function(x, y, z) -> {minX,minY,maxX,maxY} the original's discovery box
R.eachPipe = nil      -- function(fn) calls fn(x, y, z) per pipe piece
R.eachNetBox = nil    -- function(fn) calls fn(box) per derived pipe network box (no deriving)
R.squareLoaded = nil  -- function(x, y, z) -> bool
R.noticeSquare = nil  -- function(square) the original full per-square look
R.getSquare = nil     -- function(x, y, z) -> square or nil
R.levelsOf = nil      -- function(square) -> minZ, maxZ of that square's chunk

local function markBox(set, x1, y1, x2, y2)
	local c = R.CHUNK
	for cx = floor(x1 / c), floor(x2 / c) do
		for cy = floor(y1 / c), floor(y2 / c) do
			set[cx * 8192 + cy] = true
		end
	end
end

local function markSpotBox(set, x, y, z, withBox, unresolved)
	markBox(set, x - 1, y - 1, x + 1, y + 1)
	if not withBox then return end
	if R.squareLoaded and not R.squareLoaded(x, y, z) then
		-- A player-built building is only known while loaded; look again when it is.
		unresolved[R.chunkKey(x, y)] = true
	end
	if R.boxFor then
		local ok, box = pcall(R.boxFor, x, y, z)
		if ok and box and box.minX then markBox(set, box.minX, box.minY, box.maxX, box.maxY) end
	end
end

function R.chunkIsLoaded(ck)
	if not R.squareLoaded then return false end
	local cx, cy = R.unpackChunk(ck)
	return R.squareLoaded(cx * R.CHUNK, cy * R.CHUNK, 0) == true
end

function R.rebuildHot()
	if not spots then return end
	local set, unresolved = {}, {}
	for k, bits in pairs(spots) do
		local x, y, z = R.unpackSpot(k)
		markSpotBox(set, x, y, z, hasBit(bits, R.BIT_SRC), unresolved)
	end
	if R.eachPipe then
		pcall(R.eachPipe, function(x, y, z) markSpotBox(set, x, y, z, true, unresolved) end)
	end
	if R.eachNetBox then
		pcall(R.eachNetBox, function(b)
			if b and b.minX then markBox(set, b.minX, b.minY, b.maxX, b.maxY) end
		end)
	end
	-- Chunks that just turned hot while already loaded never had the full look: queue them.
	for ck in pairs(set) do
		if (not hotBuilt or not hot[ck]) and not rescanSet[ck] and R.chunkIsLoaded(ck) then
			rescanSet[ck] = true
			rescanQueue[#rescanQueue + 1] = ck
		end
	end
	hot, unresolvedChunks = set, unresolved
	hotBuilt, wantRebuild = true, false
	lastRebuild = nowMs()
	stats.rebuilds = stats.rebuilds + 1
end

function R.isHot(ck) return hot[ck] == true end
function R.isScanned(ck) return scanned ~= nil and scanned[ck] == true end
function R.queueLength() return #rescanQueue end

-- per-square path -------------------------------------------------------------------------

--- Classify a square being loaded. Returns "full", "cheap" or "skip".
function R.classify(x, y)
	if not spots then return "full" end
	if not hotBuilt then R.rebuildHot() end
	local ck = R.chunkKey(x, y)
	unloadMarked[ck] = nil
	if unresolvedChunks[ck] then
		unresolvedChunks[ck] = nil
		wantRebuild = true
	end
	if hot[ck] then return "full" end
	if scanned[ck] then return "skip" end
	if not pendingScan[ck] then
		pendingScan[ck] = nowMs()
		pendingAny = true
	end
	return "cheap"
end

--- Something on this square was registered by the full look; its chunk must be flagged on unload.
function R.noteNoticed(x, y)
	noticed[R.chunkKey(x, y)] = true
end

--- An unloading square: true at most once per chunk, and only for chunks that matter.
function R.shouldMarkUnload(x, y)
	if not spots then return true end
	local ck = R.chunkKey(x, y)
	if unloadMarked[ck] then return false end
	if not hot[ck] and not noticed[ck] then return false end
	unloadMarked[ck] = true
	noticed[ck] = nil
	return true
end

-- cheap migration look --------------------------------------------------------------------

local pipedByName, collectorByName = {}, {}
function R.clearSpriteCaches() pipedByName, collectorByName = {}, {} end

local function propsOf(o)
	local sprite = o.getSprite and o:getSprite()
	return sprite and sprite:getProperties() or nil
end

local function namePiped(name, o)
	local v = pipedByName[name]
	if v == nil then
		local p = propsOf(o)
		v = (p ~= nil and IsoFlagType ~= nil and p:has(IsoFlagType.waterPiped)) == true
		pipedByName[name] = v
	end
	return v
end

local function nameCollector(name, o)
	local v = collectorByName[name]
	if v == nil then
		local p = propsOf(o)
		v = false
		if p then
			v = p:has("CustomItem") == true
				or (IsoFlagType ~= nil and IsoFlagType.EntityScript ~= nil and p:has(IsoFlagType.EntityScript) == true)
		end
		collectorByName[name] = v
	end
	return v
end

--- Could anything on this square matter to the mod? Errs on the side of yes.
function R.cheapRelevant(square)
	if square.hasModData and square:hasModData() then
		local d = square:getModData()
		if d and d[EP.KEY_FED] ~= nil then return true end
	end
	local objects = square:getObjects()
	if not objects then return false end
	local ghostName = EP.GHOST_SPRITE
	for i = 0, objects:size() - 1 do
		local o = objects:get(i)
		local name = o.getSpriteName and o:getSpriteName() or nil
		-- a hidden water store is nameless or ours
		if name == nil or name == ghostName then return true end
		-- anything the mod ever marked (included barrels, stamped fixtures...)
		if o:hasModData() then return true end
		-- a sink already plumbed the vanilla way: the original adopts these on first sight
		if namePiped(name, o) and o.getUsesExternalWaterSource and o:getUsesExternalWaterSource() then return true end
		-- a rain collector that lost its container: the original repairs these on first sight
		if nameCollector(name, o) and instanceof(o, "IsoThumpable")
			and o.getFluidContainer and o:getFluidContainer() == nil then return true end
	end
	return false
end

-- tick work -------------------------------------------------------------------------------

local function scanChunk(ck)
	if not R.getSquare or not R.noticeSquare then return end
	local cx, cy = R.unpackChunk(ck)
	local x0, y0 = cx * R.CHUNK, cy * R.CHUNK
	local probe = R.getSquare(x0, y0, 0)
	if not probe then return end
	local lo, hi = 0, 7
	if R.levelsOf then
		local ok, a, b = pcall(R.levelsOf, probe)
		if ok and a and b then lo, hi = a, b end
	end
	for z = lo, hi do
		for x = x0, x0 + R.CHUNK - 1 do
			for y = y0, y0 + R.CHUNK - 1 do
				local sq = R.getSquare(x, y, z)
				if sq then R.noticeSquare(sq) end
			end
		end
	end
	stats.rescans = stats.rescans + 1
end
R.scanChunk = scanChunk

--- Synchronous full look over a box of loaded squares (on-demand discovery for one building).
function R.scanBox(box)
	if not box or not box.minX or not R.getSquare or not R.noticeSquare then return 0 end
	local n = 0
	local z1, z2 = box.minZ or 0, box.maxZ or 7
	for z = z1, z2 do
		for x = box.minX, box.maxX do
			for y = box.minY, box.maxY do
				local sq = R.getSquare(x, y, z)
				if sq then R.noticeSquare(sq); n = n + 1 end
			end
		end
	end
	return n
end

local tickCount = 0
function R.tick()
	if not spots then return end
	local now = nowMs()
	if wantRebuild and (not lastRebuild or now - lastRebuild >= R.REBUILD_MIN_GAP_MS or now < lastRebuild) then
		R.rebuildHot()
	end
	local budget = R.RESCAN_PER_TICK
	while budget > 0 and #rescanQueue > 0 do
		local ck = table.remove(rescanQueue, 1)
		rescanSet[ck] = nil
		local ok, err = pcall(scanChunk, ck)
		if not ok and EP.logFault then EP.logFault("registry-rescan", "ERROR rescanning a chunk: " .. tostring(err)) end
		budget = budget - 1
	end
	tickCount = tickCount + 1
	if pendingAny and tickCount % 30 == 0 then
		local still = false
		for ck, at in pairs(pendingScan) do
			if now - at >= R.SCAN_SETTLE_MS or now < at then
				scanned[ck] = true
				pendingScan[ck] = nil
			else
				still = true
			end
		end
		pendingAny = still
	end
end

--- Seed from data the original mod already persists (its mirror index), for existing saves.
function R.seedFromMirrorIndex(mirrors)
	if type(mirrors) ~= "table" then return 0 end
	local n = 0
	for key in pairs(mirrors) do
		if type(key) == "string" then
			local a, b, c = string.match(key, "^(%-?%d+),(%-?%d+),(%-?%d+)$")
			a, b, c = tonumber(a), tonumber(b), tonumber(c)
			if a and b and c and R.add(a, b, c, R.BIT_GHOST) then n = n + 1 end
		end
	end
	return n
end

-- game wiring -----------------------------------------------------------------------------

if Events and Events.OnInitGlobalModData then
	Events.OnInitGlobalModData.Add(function()
		local ok, err = pcall(function()
			if not EP.isAuthority() then return end
			if not ModData or not ModData.getOrCreate then return end
			R.attach(ModData.getOrCreate(R.STORE))
			if EP.PIPE_STORE then
				local store = ModData.getOrCreate(EP.PIPE_STORE)
				local n = R.seedFromMirrorIndex(store and store.mirrors)
				if n > 0 and EP.log then EP.log(("registry: %d hidden store(s) taken from the mirror index"):format(n)) end
			end
			if EP.log then EP.log(("registry: %d plumbed spot(s) on record"):format(R.count())) end
		end)
		if not ok and EP.logFault then EP.logFault("registry-init", "ERROR reading the registry: " .. tostring(err)) end
	end)
end

if Events and Events.OnTick then
	Events.OnTick.Add(function()
		if not spots then return end
		local ok, err = pcall(R.tick)
		if not ok and EP.logFault then EP.logFault("registry-tick", "ERROR in the registry tick: " .. tostring(err)) end
	end)
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(function() R.clearSpriteCaches() end) end

return R
