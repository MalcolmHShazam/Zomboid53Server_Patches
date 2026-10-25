--
-- Extended Plumbing - the authority.
--
-- Everything that decides or moves anything happens here; a client only hides
-- ghosts it is told about and keeps them out of its own context menu.
--
-- THE FOLDER IS NOT A BOUNDARY.  This file used to open by claiming it was
-- "loaded on a dedicated server and in singleplayer, never on a multiplayer
-- client", and that is simply not what the engine does:
--
--     // GameLoadingState.enter()
--     LuaManager.LoadDirBase("server");        // no mode test of any kind
--
-- runs on every client as it loads into the world, so media/lua/server/ is
-- executed there too.  Only client/ is one-sided, and in the other direction -
-- GameServer.doMinimumInit calls LoadDirBase("client", true), where the second
-- argument is onlyChecksum, so a server hashes those files and never runs them.
--
-- Which is why vanilla's own server files open with this line - 35 of them do -
-- and why this one does now.  Nothing below is reachable on a client, so nothing
-- below has to think about one.
--
-- The measured cost of NOT having it, over nine two-storey houses (13,122 squares
-- streaming in), was one extra square:getObjects() per square - 13,122 of them,
-- doubling this mod's share of chunk loading on a client - plus 45 building
-- resolutions, to build a registry that every reader returns early on.  Small in
-- absolute terms.  The reason it is here is that the file can now say what it
-- means.
--
-- The two halves still keep themselves apart by EP.isAuthority() as well, and those
-- guards stay: singleplayer is `isClient() == false`, so it runs this whole file,
-- and the shared/ files run everywhere regardless.
--
-- One side deciding is not a tidiness preference, it is the only arrangement
-- that works.  IsoRegions.update() calls clientProcessBuildings() inside
-- `if (!GameServer.server)`, so the BuildingDef a player-built base gets is
-- synthesised on a client and never exists on a dedicated server - two sides
-- working out "the same building" from their own view would not agree, and a
-- ghost is a real object in the world, not a local decoration.  So the server
-- makes them, the server owns the water, and nothing is derived twice.
--
-- Which is also why reach is measured rather than looked up: a plain distance in
-- tiles is an answer a dedicated server can give about a player-built shack, and
-- getBuilding() is not.
--

require "LGExtendedPlumbing/LGEPGhost"

-- Before anything is defined, so that on a client the names below simply do not
-- exist.  Every cross-folder caller already asks - `if EP.serviceAround then`,
-- `if not EP.supplyGroupFor then return nil end`, `if moved and EP.afterGroupCharged`,
-- `if not EP.reviewPumps then return end` - so nil is the answer they were written
-- for, and it is now the answer they get.
--
-- Singleplayer is `isClient() == false`, so this does not touch it.
if isClient() then return end

local EP = LGEP

--------------------------------------------------------------------------------
-- what is loaded
--------------------------------------------------------------------------------

--- Three sets of addresses, held in memory only.  Nothing here is saved: it is
--- rebuilt from LoadGridsquare as chunks arrive, and an entry that turns out to
--- be stale costs one failed lookup and is dropped.  The ghosts themselves are
--- saved, being ordinary objects on a square, so a restart finds them again on
--- the way in.
--- Which pool a square belongs to.
---
--- A building is a pool: everything in it can potentially plumb to everything else
--- in it and to nothing outside, which is exactly the grouping the decisions want.
--- The id comes from the same plan test used to decide scope, so a collector stood
--- against the outside of a wall lands in the pool of the house it is leaning on.
---
--- Anything with no building at all returns nil rather than a made-up key, and
--- that is deliberate.  A player structure on open ground has no boundary to pool
--- by, and inventing one from a coordinate grid would put a barrel and the sink it
--- feeds in different pools whenever they straddled a cell edge - a connection that
--- silently never happens.  Those stay in the unpooled list and are filtered by
--- distance as before: correct first, fast second.
---
--- EP.buildingAt and not the square's own def, because a B42 basement is a
--- BuildingDef of its own that the engine will not merge with the house over it -
--- see the note in LGEPCore.  Asking the square directly put a basement sink in a
--- pool with no collectors in it, which is a pool that never elects a main supply,
--- never gets topped up, and whose fixtures are in no list that a barrel being
--- placed ever walks.
--- A player-built structure is deliberately NOT pooled, and that is a correction.
---
--- A pool id is worked out once, at first sighting, and then kept for the rest of
--- the session - which is only safe for something whose id is stable.  A map
--- building's is.  A player structure's is not: IsoRegions.update hands changed
--- cells to WorldRegionToMetaGrid.clientProcessBuildings, which REMOVES every
--- user-defined BuildingDef in that cell and its eight neighbours and builds fresh
--- ones from the regions, so every wall, floor or door laid or destroyed rebuilds
--- the def and BuildingID.makeID hands out a new number with it.
---
--- Left pooled, the fixtures filed before that change sat in a pool nothing was in
--- any more.  The sweep's cheap gate below reads srcPool[pool], finds it empty, and
--- passes over the fixture without asking anything further - so a washing machine
--- in a base somebody was still building would stop and never start again.
--- Right-clicking the machine healed it, because serviceAround services the fixture
--- it was handed whatever the registry thinks, which is exactly the shape of fault
--- that gets reported as "it works when I look at it".
---
--- Returning nil puts them in the unpooled list instead, where scope is decided by
--- Reach inside supplyGroup and the sweep asks only whether there is any collector
--- at all.  Which is what a dedicated server has always done with them anyway -
--- IsoRegions.update() calls clientProcessBuildings() inside `if (!GameServer.server)`,
--- so a player base HAS no def there - so this also stops singleplayer and a
--- dedicated server pooling the same base two different ways.
local function poolOf(x, y, z)
	local def = EP.buildingAt(x, y, z)
	if not def then return nil end
	if def:isUserDefined() then return nil end
	return def:getIDString()
end

--- How many entries `sources` holds, maintained rather than counted.
---
--- discover() asks "did that sweep turn anything up" by taking EP.count(sources) before
--- and after - two O(n) walks of the whole collector registry, to answer a boolean, on a
--- path that already walks a building's bounding box.  Kept in step at the two places
--- that can change it, which is notice() and forgetSource().
local sourceCount = 0

local sources  = {}   -- square key -> {x,y,z,pool} of a collector
local pumped   = {}   -- square key -> was that collector powered last time we looked
local qualified = {}  -- square key -> did that address QUALIFY as a supply last time we
                      -- looked.  See the edge detector in the collector stage: a barrel
                      -- can stop being one, and start again, with no event either way.
local fixtures = {}   -- square key -> {x,y,z,pool} of something plumbable
local byPool   = {}   -- pool id -> { square key -> the same fixture entry }
local srcPool  = {}   -- pool id -> { square key -> the same collector entry }

--------------------------------------------------------------------------------
-- WHERE the collectors are, coarsely
--------------------------------------------------------------------------------

--- One bucket per 16x16 tiles, holding how many collectors stand in it.
---
--- THE QUESTION THIS EXISTS TO ANSWER is "could anything supply a fixture HERE", and it
--- used to be answered with `EP.any(sources)` -- is there a collector ANYWHERE in the
--- loaded world.  That is O(1) and it is the wrong question, and it was the single most
--- expensive line in this mod:
---
---   * a fixture with no pool took that branch, and a player-built structure has no pool
---     at all on a dedicated server (player-built defs are synthesised inside
---     `if (!GameServer.server)`) and none in ANY mode when it is built within a tile of a
---     map building - which is the ordinary way people build;
---   * so one barrel anywhere made every such fixture "supplied", and each then ran
---     serviceFixtureAt -> groupOrDiscover -> discover(), whose sweepBox for a fixture with
---     no building is Reach either way and +/-4 levels: 25 x 25 x 9 = 5,625 squares, each
---     getting a full notice();
---   * and serviceFixtureEntry returning true spends the rest of the purse, so that is ONE
---     fixture per tick, for ever.
---
--- Measured, 2,000 unserved pool-less fixtures: 16 ms/s with no collector in the world,
--- 260 ms/s with ONE, and 525 ms/s in a nine-level world where the sweep box is not
--- clipped -- 52% of every second, with 250 ticks in 4,000 over a whole frame.  Forty
--- collectors cost the same as one, because it was never about how many there were.
--- plans/lgep-stutter-fix-programme.md has the full chain; the raw is
--- plans/raw/lgep-base-ms-2026-09-07.txt.
---
--- WHY A BUCKET AND NOT A BETTER STRUCTURE.  The replacement has to stay O(1) in the
--- number of collectors, because the thing it replaces was; at Reach 12 and a 16-tile
--- bucket this reads at most nine of them.
---
--- DELIBERATELY NOT z-AWARE, and deliberately generous in x and y.  It is a conservative
--- over-approximation: it can say "maybe" where the truth is "no", and it can never say
--- "no" where the truth is "yes".  A gate that can only ever be too generous cannot take a
--- fixture's water away, which is the only failure that would matter.
--- THE BUCKET KEY IS A NUMBER, NOT A STRING, and that is not a micro-optimisation.
---
--- `sourceNear` reads up to nine buckets per call and is called once per queued fixture per
--- lap.  A `cx .. "," .. cy` key would allocate nine strings every time it is asked -- which
--- is the same kind of cost this whole change set exists to remove, reintroduced by the
--- thing removing it.  A number key allocates nothing.
---
--- The offset is what makes it work for negative coordinates, and 8192 buckets a side at 16
--- tiles each is 131,072 tiles either way, against a Knox County about 20,000 wide.  Two
--- distinct buckets cannot collide inside that.
local SRC_CELL = 16
local SRC_SPAN = 8192
local srcCells = {}   -- bucket number -> how many collectors stand in that bucket

local function srcBucketAt(cx, cy)
	return (cx + SRC_SPAN) * (SRC_SPAN * 2) + (cy + SRC_SPAN)
end

local function srcBucket(x, y)
	return srcBucketAt(math.floor(x / SRC_CELL), math.floor(y / SRC_CELL))
end

--- Kept in step at the two places that own `sources`, which are the same two that maintain
--- `sourceCount` - notice() and forgetSource() - so there is no third thing to remember.
local function srcIndexAdd(x, y)
	local b = srcBucket(x, y)
	srcCells[b] = (srcCells[b] or 0) + 1
end

local function srcIndexRemove(x, y)
	local b = srcBucket(x, y)
	local n = (srcCells[b] or 0) - 1
	srcCells[b] = n > 0 and n or nil
end

--- Is there a collector within `reach` of here?
---
--- `reach` is the caller's, not the option's: a fixture inside a player-built structure passes
--- a radius widened to cover it, because the supply walk admits any collector in the same
--- structure with no distance limit. See `regionSpread`.
local function sourceNear(x, y, reach)
	for cx = math.floor((x - reach) / SRC_CELL), math.floor((x + reach) / SRC_CELL) do
		for cy = math.floor((y - reach) / SRC_CELL), math.floor((y + reach) / SRC_CELL) do
			if srcCells[srcBucketAt(cx, cy)] then return true end
		end
	end
	return false
end

--- Square key -> {x,y,z} of something on the FedFixtures list: a water dispenser, or
--- whatever else an operator has said the building's supply should fill.
---
--- A FOURTH REGISTRY RATHER THAN A FLAG ON ONE OF THE OTHER THREE, and the reason is that
--- a listed object is in none of them.  It is not a collector - EP.isWaterSource refuses it
--- outright, or it would be filled out of itself - and it is not a plumbable fixture,
--- because it carries no waterPiped and vanilla will never route a read through it.  It is
--- a third kind of thing and the cursor walks it as a stage of its own.
---
--- NOT POOLED, unlike sources and fixtures.  A pool id is an optimisation for the sweep's
--- cheap gate - "does this building hold any collector at all" - and the top-up has no such
--- gate to serve: it asks supplyGroup, which decides scope from the world every time.  A
--- fourth pool index would be a second thing to keep in step with poolOf for no answer.
local fed = {}

--- Re-entrancy guard for reviewPumps.  Declared up here with the rest of the
--- module state because the sweep's error handler resets it, and that handler is
--- written above the function it belongs to - a `local` beside reviewPumps would
--- have left the reset writing a global instead.
local reviewing = false

--- Has anything happened that a mirror's books could be wrong about?
---
--- PRECIPITATION IS NOT THE WHOLE GATE, and getting that wrong would have shipped a mod
--- that loses water.  The settle pass does four jobs and only the first is weather:
---
---   1. rain or snow into a barrel, and petrol evaporating out of one  - the weather
---   2. rebuilding a mirror's FluidContainer after a restart, because
---      GameEntityManager.Save writes meta entities only and a ghost comes back
---      without its component
---   3. following a group that CHANGED SIZE - a barrel's chunk streaming in or out, a
---      pump gaining or losing power.  A mirror is the sum of its group, so a group
---      with a member missing must not go on reading full
---   4. paying a debt that could not be charged while a member was away
---
--- Three and four are chunk traffic rather than weather, and they have events:
--- LoadGridsquare on the way in and ReuseGridsquare on the way out.  So this is an
--- ordinary dirty flag fed by everything that can move the answer, and the weather is one
--- of its inputs rather than the whole of it.
---
--- Declared up here with the rest of the module state because notice() sets it and
--- notice() is written far above the sweep that reads it - a `local` beside the sweep
--- would have left notice() writing a global that nothing reads, which is the same
--- mistake the comment on `generatorEpoch` in LGEEGrid records.
---
--- Starts true, so the first pass of a session settles everything it can reach.
local settleWanted = true

--- THE WALK EPOCH, which is what makes a group safe to build over several ticks.
---
--- The maintenance cursor assembles a big mirror's group a few candidates at a time, so a
--- group finished on tick 40 was begun on tick 1 - and a group half-read from one world and
--- half from another describes a world that never existed.  In this mod that is not an odd
--- reading, it is duplicated or vanished water.
---
--- So every walk records the epoch it began in and is thrown away if the number has moved
--- by the time it finishes.  Restarting costs a lap; getting it wrong costs a save.
---
--- WHAT MUST BUMP IT, and the reasoning for each, because a missed one is silent:
---
---   * anything that changes who is IN a group - a collector filed, forgotten, included,
---     excluded, re-pointed at another liquid, or its pump moving.  These are exactly the
---     places that already raise settleWanted, which is why the two are raised together by
---     one helper rather than left to be remembered separately.
---   * any DELIBERATE movement of water - a drink, a bottle emptied, a transfer.  Those
---     arrive as OnWaterAmountChange and are the dangerous direction: a walk that read a
---     barrel before it was drained would credit the mirror with water that has gone.
---
--- WHAT DELIBERATELY DOES NOT BUMP IT: rain.  It is silent, so it could not bump anything
--- even if it should, and it does not need to - rain only ever ADDS to a barrel, so a walk
--- that read an amount before the rain landed under-reports.  A mirror reading low is the
--- safe direction and is already what the whole lap period means; the water is still in the
--- barrels and the next lap finds it.
local walkEpoch = 0

--- Raise the settle flag and invalidate any walk in progress, together.
---
--- One helper rather than two statements at nine call sites: the two facts are the same
--- fact - the world under a mirror moved - and a site that remembered one and forgot the
--- other would produce a group assembled across a change, which is the fault the epoch
--- exists to prevent.
--- WHAT COULD CHANGE A FIXTURE'S ANSWER, counted.
---
--- A fixture near a barrel can still be unservable -- wrong floor, no pump reaching it, not
--- the same structure -- and asking again produces the same "no" at the same price. In a
--- deep world that price is a whole supplyGroup walk over the Reach box, measured at 22 ms
--- and up in one tick, and the cursor was repeating it every lap for the life of the save.
--- That is the same shape as the bug this change set began with, one level in: work that
--- cannot succeed, repeated for ever.
---
--- So a refusal is REMEMBERED against this counter, and only a change that could plausibly
--- turn a "no" into a "yes" clears it: a collector filed, a collector gone, or a pump
--- moving. Deliberately NOT bumped by `worldChanged()`, which fires for every departing
--- square of every chunk and would leave the memory useless exactly while a player moves.
---
--- A MIRROR APPEARING OR VANISHING COUNTS TOO, and leaving it out was a real regression
--- caught by the suites rather than by reasoning: `serviceFixtureEntry` stands down for a
--- fixture that already has one, so a mirror being retired is exactly the moment its fixture
--- becomes worth asking about again.  Two suites failed on it -- a mirror retired from a
--- neighbour square never being replaced on the centre one, and switching the mod off and
--- back on never rebuilding what the teardown removed.
---
--- A VERSION AND NOT A FLAG, because a flag is consumed by whoever reads it first -- see
--- memory/a-shared-dirty-flag-is-consumed-by-its-first-reader.md. Every fixture compares
--- against the same number and they do not race.
---
--- WHAT THIS GIVES UP: a player who builds a wall or a floor that newly connects a shack to
--- a barrel is not noticed by the background loop, because construction bumps nothing here.
--- Right-clicking the tap re-derives everything through EP.serviceAround, which is both the
--- thing a player does to use it and a path this counter does not gate.
local supplyVersion = 0

local function supplyChanged()
	supplyVersion = supplyVersion + 1
	-- A barrel filed, forgotten, plumbed or pumped can turn a pipe network blue or white.
	-- A flag and nothing else: this runs once per barrel a streaming chunk files, and
	-- LGEPPipes recomputes on its own clock.  See plans/lgep-pipe-network.md section 5.3.
	if EP.markPipeSupplyDirty then EP.markPipeSupplyDirty() end
end

--- And the other half of the same idea: has the fixture REGISTRY itself moved.
---
--- Bumped when a fixture is filed or forgotten.  Between the two counters, "is there any
--- point rebuilding the fixture queue" is two number compares.
---
--- WITHOUT THIS THE REFUSAL MEMORY MAKES THINGS WORSE, and it did -- measured.  Once every
--- fixture has been tried the queue comes back empty, so a lap finishes in a handful of
--- ticks instead of thousands, so `enterStage` re-walks the whole registry every few ticks
--- rather than once a lap: 5.5 ms/s became 29 ms/s and 36 ticks in 4,000 crossed half a
--- frame.  Making the work per lap smaller made the laps shorter, which is a trap worth
--- naming: a per-lap cost is only bounded if the lap length is.
local fixturesEpoch = 0

local function fixturesChanged()
	fixturesEpoch = fixturesEpoch + 1
end

--- What the fixture queue was last built against.  Different from either counter means the
--- answer could have changed; equal to both means it cannot have.
local fixtureQueueSupply, fixtureQueueEpoch = -1, -1

local function worldChanged()
	settleWanted = true
	walkEpoch = walkEpoch + 1
end

--- A PIPE CHANGES SCOPE, and scope is what both counters above are about.
---
--- Laying or lifting a piece, or a network turning blue, can put a barrel into a fixture's
--- group or take it out: a walk begun before it describes a world that no longer exists
--- (worldChanged), and a fixture refused for having nothing to draw on may now have
--- something (supplyChanged).  Called by LGEPPipes, which is loaded on its own and reaches
--- this through the EP table.
function EP.onPipeScopeChanged(why)
	supplyChanged()
	worldChanged()
end

--- Every collector the registry holds, handed to `fn(entry)` - {x, y, z, pool, and the
--- last-seen `included` LGEPPipes keeps on it}.  For the pipe supply, which is the only
--- reader outside this file.  `fn` must not add to or remove from the registry: this is a
--- pairs() walk, and a key appearing mid-walk is undefined in Kahlua as in Lua.
function EP.eachCollector(fn)
	for _, entry in pairs(sources) do fn(entry) end
end

--- Forward declaration.  The sweep relinks a fixture the moment its collector is
--- confirmed gone, and that is written above the helper that does it; without this
--- the name would compile as a global and be nil at the only moment it is needed.
local serviceFixtureAt

--- Forward declared for the same reason, and from the same shape of problem: the washer
--- patch is written at the very foot of this file because it is about a fault in the
--- engine's own sync rather than about plumbing, and serviceFixture - which is the one
--- place every fixture this mod knows about passes through - is a long way above it.
--- Declared here rather than at the definition, because a `local function` called from
--- above it is a nil call the engine's pcalls swallow.
local reconcilePipedFlag

local ghosts   = {}   -- square key -> {x,y,z} of a square with a ghost on it

--- EVERY SQUARE THIS SAVE HAS A MIRROR ON, LOADED OR NOT - kept for the way out and nothing else.
---
--- `ghosts` holds only what is loaded, and it has to: it is what the sweep walks. But the
--- Uninstall (EP.uninstallNow, CLAUDE.md section 6) must say what it could NOT reach and
--- where, and a mirror in a chunk nobody is standing near is exactly the one that dries a tap
--- after the mod is deleted (plans/lgep-uninstall-leaves-mirrors.md). So an address is written
--- here when a mirror is filed - which is also how a save from before this existed fills in, a
--- chunk at a time as players walk it - and struck off only when the mirror is really taken
--- off its square, never when its chunk streams out.
---
--- In the global store beside the pipes, so a dedicated server saves it with the world
--- (memory/dedicated-server-never-raises-onsave.md). One `true` per mirror. It can hold an
--- address whose mirror went some way this mod did not see; the report says "up to" for that.
local savedMirrors = nil

local function markMirrorSaved(key)
	if savedMirrors and not savedMirrors[key] then savedMirrors[key] = true end
end

Events.OnInitGlobalModData.Add(function()
	local ok, err = pcall(function()
		if not ModData or not ModData.getOrCreate then return end
		local store = ModData.getOrCreate(EP.PIPE_STORE)
		if type(store.mirrors) ~= "table" then store.mirrors = {} end
		savedMirrors = store.mirrors
	end)
	if not ok then EP.logFault("mirror-index", "ERROR reading the mirror index: " .. tostring(err)) end
end)

--- Which mirror squares have had their repair pass this session.
---
--- THE REPAIRS ARE A ONCE-PER-MIRROR JOB, NOT A CLOCK, and that is what decides when they
--- run.  Every one of them fixes something read off the disk or left by an older build:
--- a mirror on a neighbour square from before the centre-square rule, a sprite that came
--- back anonymous because IsoObject.save writes it by numeric id, two mirrors on one
--- square, a mirror whose fixture has been taken away.  None is a state this build can
--- produce at runtime.
---
--- So a mirror is inspected the first time this session sees it - which is when it arrives
--- from a chunk, which is the moment the disk hands it over - and after that it is only
--- re-checked on the slow rotation, as a net.  That is both cheaper than the old
--- every-mirror-every-minute pass and STRICTER than a rotation alone: the upgrade path
--- promises the repairs happen on the first sweep after an update, and a sixth of them
--- per pass would have spread that over a game hour.
local repaired = {}

--- Which mirror squares have been standing over a building with NO PLUMBING AT ALL, and
--- since when.
---
--- The latch behind retireIfUnsupplied, held in memory only like every other registry
--- here.  A restart simply starts the clock again, which is the safe direction: the worst
--- it costs is that a mirror already due to be taken away waits one more spell for it.
local unsupplied = {}

--- Drop a collector's address, and its place in its pool's list with it.
---
--- Both together or neither: a key left in srcPool after sources has forgotten it
--- is a pool that goes on offering a barrel nobody can resolve, and the main-supply
--- election would keep electing it.
local function forgetSource(key)
	local entry = sources[key]
	if entry and entry.pool and srcPool[entry.pool] then
		srcPool[entry.pool][key] = nil
	end
	if entry then
		sourceCount = sourceCount - 1
		srcIndexRemove(entry.x, entry.y)
		supplyChanged()
	end
	sources[key] = nil
	pumped[key] = nil
	qualified[key] = nil

	-- A barrel leaving the pool shrinks every group it was in, so every mirror over it
	-- is now reading a total that includes something that is not there.
	worldChanged()
end

--- Look at a square and file whatever is standing on it.
---
--- Note the order.  A ghost is an IsoThumpable with a fluid container, so it
--- would pass the collector test if it were asked - isWaterSource excludes them
--- explicitly, and this checks for one first regardless, because a ghost filed as
--- a collector would be a barrel that fills itself from itself.
local function notice(square)
	if not square then return end

	local x, y, z = square:getX(), square:getY(), square:getZ()
	local objects = square:getObjects()

	-- BUILT ON FIRST USE, NOT UP FRONT.
	--
	-- `EP.key` is a string concatenation and it was the most expensive single thing on the
	-- per-square path -- 1.88 us of a 21.3 us square, nine per cent, built for every square
	-- of every chunk that opens whether or not anything is ever filed under it.  The
	-- overwhelming majority of squares in the world file nothing.
	--
	-- `key = key or EP.key(x, y, z)` at each use rather than a memoising closure: a closure
	-- would be an allocation per square, which is the thing being removed.
	local key = nil

	-- A SQUARE SOMEBODY PLUMBED A FIXTURE ON IS FILED WHATEVER IS STANDING ON IT NOW.
	--
	-- The object walk below cannot do this, because in the bottle-less state there is no
	-- listed fixture to find: taking a bottle leaves a WaterDispenserNoBottle, which has no
	-- FluidContainer and is therefore not one.  A player who takes a bottle out, saves and
	-- comes back would have had a square that was plumbed and an address nothing would ever
	-- file again - so putting the bottle back would have done nothing until the chunk
	-- happened to reload.
	--
	-- One square-level modData read per square as a chunk arrives, against the per-OBJECT
	-- work the loop below already does, and only on squares that have one at all: hasModData
	-- is `table != null && !table.isEmpty()`, so every ordinary square in the world answers
	-- false on a null check.
	if EP.isFedPlumbed(square) then
		key = key or EP.key(x, y, z)
		if not fed[key] then
			fed[key] = { x = x, y = y, z = z }
		end
		if EP.reg then EP.reg.add(x, y, z, EP.reg.BIT_FED) end -- [Malcolm_Perf]
	end

	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if EP.isGhost(object) then
			key = key or EP.key(x, y, z)
			if not ghosts[key] then
				-- A mirror we have not seen this session.  It arrived off the disk, so
				-- it has no FluidContainer and its ledger is last session's - both of
				-- which are the settle pass's job.
				worldChanged()
			end
			ghosts[key] = { x = x, y = y, z = z }
			markMirrorSaved(key)
			if EP.reg then EP.reg.add(x, y, z, EP.reg.BIT_GHOST) end -- [Malcolm_Perf]
			supplyChanged()
		else
		-- BEFORE the collector test, because a barrel the engine has gutted FAILS it.
		--
		-- A chunk unload can leave a rain barrel with no components at all - no
		-- FluidContainer and no MetaTag pointing at where they went - so
		-- getFluidCapacity() is 0 and EP.isWaterSource refuses it.  Left alone it falls
		-- straight through this walk, out of the supply, and out of the right-click menu,
		-- for good.  See EP.repairOrphanedCollector for the whole account; the short
		-- version is that it is vanilla's `%ld` in GameEntityManager.checkEntityIDChange.
		--
		-- Guarded, because this runs inside LoadGridsquare: a throw here is one throw per
		-- square for the rest of the session, and it would bury the log somebody needs.
		-- ASKED ONCE, FOR BOTH.
		--
		-- `EP.repairOrphanedCollector` and `EP.isWaterSource` each open with
		-- `instanceof(object, "IsoThumpable")` and each returns false immediately when it is
		-- not one -- but only after paying for their own EP.isGhost as well.  An ordinary
		-- world object is a floor, a wall or a bit of furniture and is not an IsoThumpable,
		-- so both calls were pure cost on almost every object in the world: 1.36 us and
		-- 1.41 us against the 0.28 us of asking once here.  That is 2.77 us of a 6.34 us
		-- object, on the path that runs for every object of every square of every chunk.
		--
		-- The elseif chain below is UNCHANGED in meaning: isWaterSource answers false for
		-- anything that is not an IsoThumpable, so `thumpable and ...` is the same test
		-- written earlier.  A player-built sink CAN be an IsoThumpable, which is why the
		-- fixture branches below are not moved inside this and must go on being asked about
		-- everything.
		local thumpable = instanceof(object, "IsoThumpable")

		if thumpable then
			local ok, err = pcall(EP.repairOrphanedCollector, object)
			if not ok then
				EP.logFault("repair-orphaned-collector",
					"ERROR giving a collector its container back: " .. tostring(err))
			elseif err == true then
				-- It is a collector again, and every mirror that could see it is now short.
				worldChanged()
			end
		end

		if thumpable and EP.isWaterSource(object) then
			key = key or EP.key(x, y, z)
			-- Created once and then left alone, like a fixture, because working out
			-- the pool means asking the metagrid and a roof barrel's own square has
			-- no building on it - which is the linear plan scan, and not something to
			-- repeat every time a chunk brings the same barrel back.
			local entry = sources[key]
			if not entry then
				-- A barrel joining the pool grows every group it belongs to, so every
				-- mirror that can see it is now reading a total that is short.
				worldChanged()
				entry = { x = x, y = y, z = z, pool = poolOf(x, y, z) }
				sources[key] = entry
				sourceCount = sourceCount + 1
				srcIndexAdd(x, y)
				supplyChanged()
				if entry.pool then
					srcPool[entry.pool] = srcPool[entry.pool] or {}
					srcPool[entry.pool][key] = entry
				end

				-- SEED THE PUMP STATE HERE, where the barrel is in hand, and the whole of
				-- reviewPumps' edge detector becomes honest.
				--
				-- It compares pumped[key] against EP.isPumped and treats a difference as a
				-- transition.  Left unseeded, pumped[key] is NIL on a barrel nobody has
				-- reviewed yet, EP.isPumped returns a real boolean, and `nil ~= false` is
				-- TRUE - so EVERY collector in the loaded world reported a transition it
				-- had never had, and each fired a WIDE serviceAround over its whole
				-- building.  Measured at 457,011 operations for nine houses, 7,747,610 for
				-- one base with 200 barrels, and 201,841,744 for sixty-four buildings, in a
				-- single frame, against 576 for the same call afterwards.  In practice it
				-- was a player's first right-click after logging in.
				--
				-- Recording the truth at first sighting is what fixes it, rather than
				-- teaching reviewPumps to ignore an unknown state: ignoring it would also
				-- swallow the FIRST REAL transition of a barrel that had never been
				-- reviewed - a pump switching on for a collector on the tap's own floor,
				-- which is the one case where gravity gives nothing and the pump is the
				-- entire supply.  lgep_sim_tiers asserts exactly that, and it is right to.
				pumped[key] = EP.isPumped(object)
			end
			-- [Malcolm_Perf] a plumbed-in collector is a registered spot
			if EP.reg and EP.isIncluded(object) then EP.reg.add(x, y, z, EP.reg.BIT_SRC) end
		elseif EP.isFedFixture(object) then
			key = key or EP.key(x, y, z)
			-- REACHED ONLY BECAUSE isWaterSource ALREADY SAID NO, which is what keeps the
			-- two answers from ever both being yes: the list is consulted at the foot of
			-- isWaterSource, so a listed object falls through to here by construction
			-- rather than by these two branches being written to agree.
			--
			-- No pool and no worldChanged().  Nothing above a listed object is reading it -
			-- it supplies nobody - so filing one cannot make any mirror's total wrong, and
			-- raising the settle flag for it would be a lap of work for every dispenser in
			-- an office block as the chunks arrive.
			if not fed[key] then
				fed[key] = { x = x, y = y, z = z }
			end
		elseif EP.isPlumbableFixture(object) then
			key = key or EP.key(x, y, z)
			local entry = fixtures[key]
			if not entry then
				entry = { x = x, y = y, z = z, pool = poolOf(x, y, z) }
				fixtures[key] = entry
				fixturesChanged()
				if entry.pool then
					byPool[entry.pool] = byPool[entry.pool] or {}
					byPool[entry.pool][key] = entry
				end
			end
		end
		end
	end
	if key and EP.reg then EP.reg.noteNoticed(x, y) end -- [Malcolm_Perf]
end

--- Guarded because of how often it runs and what it runs inside: LoadGridsquare
--- is raised for every square of every chunk as it arrives, so an error here is an
--- error in the middle of loading the world, thousands of times over.  Filing one
--- square wrongly costs a fixture one sweep; throwing costs the chunk.
--- [Malcolm_Perf] GATED BY THE REGISTRY OF PLUMBED SPOTS (shared/LGEPRegistry.lua).
---
--- A square in a hot chunk (one a plumbed spot, a plumbed collector's building or reach box,
--- or a pipe network covers) gets the original look in full.  A square in a cold chunk that
--- has never been scanned gets a cheap look for anything that could be plumbing (the one-time
--- migration of existing saves) and the full look only if that finds something.  A square in
--- a cold, scanned chunk is skipped.  Without a registry (a multiplayer client, or before the
--- world's ModData is read) this is the original full look.
local function noticeLoaded(square)
	if not square then return end
	local reg = EP.reg
	if not reg or not reg.ready() then return notice(square) end
	local class = reg.classify(square:getX(), square:getY())
	if class == "full" then
		reg.stats.full = reg.stats.full + 1
		return notice(square)
	elseif class == "cheap" then
		reg.stats.cheap = reg.stats.cheap + 1
		if reg.cheapRelevant(square) then return notice(square) end
		return
	end
	reg.stats.skipped = reg.stats.skipped + 1
end

Events.LoadGridsquare.Add(function(square)
	local ok, err = pcall(noticeLoaded, square)
	if not ok then
		EP.logFault("plumb-read-square", "ERROR reading a square: " .. tostring(err))
	end
end)

--- A square being recycled: the unload side of the chunk traffic.
---
--- IsoChunk raises this at :3356 as it hands a square back for reuse, which is the one
--- moment a barrel LEAVES the loaded world without anybody removing it.  A mirror is the
--- sum of its group, so a group whose member has just streamed out is reading a total
--- that includes water nobody can reach - and unlike a dismantled barrel there is no
--- OnObjectAboutToBeRemoved to say so.
---
--- Deliberately just a flag and no work at all.  This fires for every square of every
--- departing chunk, so anything more than a boolean here would be a cost per square of
--- streaming; the sweep resolves what actually went, at its own pace, in one place.
--- [Malcolm_Perf] Once per chunk, and only for a chunk the registry says holds something:
--- the same two flags the original raised for every departing square.  With no square or
--- no registry it falls back to the original behaviour.
local function unloadShouldMark(square)
	local reg = EP.reg
	if not square or not reg or not reg.ready() then return true end
	local ok, mark = pcall(reg.shouldMarkUnload, square:getX(), square:getY())
	if not ok then return true end
	return mark
end

Events.ReuseGridsquare.Add(function(square)
	if not unloadShouldMark(square) then return end
	worldChanged()

	-- AND MARK THE FIXTURE REGISTRY DIRTY, which is what lets the next lap prune it.
	--
	-- Still just two increments and no allocation, which is what the note above insists on:
	-- this fires for every square of every departing chunk, so anything that touched the
	-- registry here would be a per-square cost on the streaming path.  The WALK stays on the
	-- lap, where it happens anyway (see flattenLoaded); all this does is say it is worth
	-- doing once more.
	--
	-- Without it the pruning is unreachable in the one state that matters.  The queue is
	-- only rebuilt when one of the two counters moves, and a chunk closing moves neither --
	-- so a player who walked away and stopped would keep every address for ever, which is
	-- precisely the case the pruning exists for.
	fixturesChanged()
end)

--- Discovery has three sources, and the OnObjectAdded handler at the bottom of this file
--- is one of them.
---
--- This block used to say the opposite - "there is deliberately no OnObjectAdded handler
--- here", on the grounds that AddItemToMapPacket declares only processClient - and it went
--- on saying it long after the handler was added, in the same file, forty lines from the
--- claim.  It was true of the Java and blind to vanilla's own Lua, which raises the event
--- itself in seven places including the rain collector's build code and the moveables
--- path, both of which load on every side.  See the handler's own note.
---
--- So: LoadGridsquare files what was standing when a chunk opened, OnObjectAdded files
--- what is built afterwards, and discover() is the repair for the residue neither
--- describes - an admin spawn, worldgen, another mod placing something silently.

--- Everything within reach of a player, re-read.
---
--- The z band reaches further up than down because that is where collectors go: a
--- player standing at a sink should notice a barrel on the roof two floors above
--- them, and a player standing on the roof should notice they are over their own
--- house.
--- Notice the ground a trigger actually touched.
---
--- This replaced a volume scan, and the volume scan was wrong twice over.
---
--- It was enormous: at the default Reach, 25 x 25 x 7 is about four thousand
--- square lookups, and it ran on every right-click.  And its z band was a guess -
--- seven levels, when B42 builds up to z 31 and digs to -32, so a tall tower or a
--- deep basement fell outside it anyway.  Widening the band would have made a slow
--- thing slower without making it correct.
---
--- Neither problem needed solving, because there was never anything to search for.
--- Every trigger already carries the coordinates of the thing that changed: a
--- placement passes the square the collector or fixture was put on, a right-click
--- passes the fixture that was clicked, a generator passes its own square.  So the
--- only squares worth reading are that one and the nine above it where a mirror
--- would live.  Ten lookups, no z band to get wrong, and no building size to care
--- about.
---
--- Everything already standing when a chunk opened was filed by LoadGridsquare, so
--- between the two nothing goes unseen.
local function noticeAt(x, y, z)
	local cell = getCell()
	notice(cell:getGridSquare(x, y, z))
	for dy = -1, 1 do
		for dx = -1, 1 do
			notice(cell:getGridSquare(x + dx, y + dy, z + 1))
		end
	end
end

--------------------------------------------------------------------------------
-- discovery for the collector nothing announces
--------------------------------------------------------------------------------

--- The box this mod has already swept during the current trigger.
---
--- A wide pass services every fixture in a building and they all resolve to the
--- same box, so without this a house with six sinks and no collector would sweep
--- the same squares six times over.  Cleared by each public entry point rather
--- than held across them: the whole point of sweeping is to find something that
--- was not there a moment ago, and a memo that outlived its trigger would
--- suppress exactly the scan that was wanted.
local swept

--- Where to look for a collector that could serve the fixture at x,y,z.
---
--- Deliberately the same region EP.visibleSupplyGroup walks on a multiplayer
--- client - the fixture's building where it has one, a square of Reach where it
--- does not - so the two sides go on finding the same collectors and the stand-in
--- a client puts up still matches the mirror this makes.
---
--- Measured off EP.buildingBounds, which is the whole building including its
--- basements.  Built from the fixture's own def it was wrong at both ends for a
--- basement sink: the plan was the basement's, so a barrel against the house's
--- outside wall was not in it, and maxZ came out of a def whose getMaxLevel() is
--- -1, so the sweep stopped two floors below the roof the barrels stand on.  A
--- collector built after its chunk had opened was then undiscoverable from below
--- ground for the rest of the session.
--- HOW FAR A FIXTURE'S OWN STRUCTURE REACHES, or nil when it is in none.
---
--- `walkBegin` scopes a fixture by Reach UNION its BuildingDef UNION its regions, and
--- `walkStep` accepts a collector on `EP.regionsMeet` with **no distance limit at all** - only
--- a four-level z band. The region half was added later, and the gates that decide whether the
--- walk is ever STARTED were never widened with it:
---
---   `sweepBox`                 - what `discover` looks at
---   `affectedBox`              - which fixtures a trigger re-services
---   `serviceFixtureEntry`      - `sourceNear(x, y, Reach)`
---   the fixture-queue filter   - the same, for every fixture
---
--- `poolOf` returns nil for a user-defined def and for open ground, so EVERY player-built base
--- takes the Reach branch - and on a dedicated server the engine synthesises no def at all.
---
--- What that cost: a compound with a sink at one end and its plumbed barrel forty tiles away
--- in the SAME structure. `walkBegin` and `walkStep` would put that barrel in the group, but
--- the fixture never enters the queue, `discover` never sweeps that far, and plumbing the
--- barrel in services a Reach box round the BARREL. The tap says it has no water until
--- somebody right-clicks that one tap, and then it is fine for ever. "It works when I look at
--- it" - and raising Reach is the only setting that helps, which is precisely the advice given
--- to all thirteen of BR-LGEP-003's reporters and precisely why it appears to work.
---
--- Unioned, never substituted, so every one of these boxes can only ever grow. What is
--- eligible is still decided per collector by `EP.serves`.
local function regionSpread(fx, fy, fz)
	if not EP.regionsAt or not EP.regionBounds then return nil end
	local regions = EP.regionsAt(fx, fy, fz)
	return regions and EP.regionBounds(regions) or nil
end

--- The same widening as a RADIUS, for the two `sourceNear` gates, which take one.
--- `math.max` of the four sides from the fixture, floored at the Reach option.
local function reachForStructure(fx, fy, fz)
	local reach = EP.getOption("Reach")
	local rb = regionSpread(fx, fy, fz)
	if not rb then return reach end
	local far = math.max(fx - rb.minX, rb.maxX - fx, fy - rb.minY, rb.maxY - fy)
	return (far + 2 > reach) and (far + 2) or reach
end

--- Widen a box in place to cover the fixture's structure.
local function widenToStructure(box, fx, fy, fz, withZ)
	local rb = regionSpread(fx, fy, fz)
	if not rb then return box end
	if rb.minX - 2 < box.minX then box.minX = rb.minX - 2 end
	if rb.minY - 2 < box.minY then box.minY = rb.minY - 2 end
	if rb.maxX + 2 > box.maxX then box.maxX = rb.maxX + 2 end
	if rb.maxY + 2 > box.maxY then box.maxY = rb.maxY + 2 end
	if withZ then
		if fz - 4 < box.minZ then box.minZ = math.max(-32, fz - 4) end
		if fz + 4 > box.maxZ then box.maxZ = math.min(EP.MAX_LEVEL, fz + 4) end
	end
	return box
end

local function sweepBox(fx, fy, fz)
	local bounds = EP.buildingBounds(EP.buildingAt(fx, fy, fz))

	local box
	if bounds then
		box = { minX = bounds.minX - 2, minY = bounds.minY - 2,
		        maxX = bounds.maxX + 2, maxY = bounds.maxY + 2,
		        minZ = math.max(-32, math.min(bounds.minZ, fz) - 2),
		        maxZ = math.min(EP.MAX_LEVEL, math.max(bounds.maxZ, fz) + 2) }
	else
		local reach = EP.getOption("Reach")
		box = { minX = fx - reach, minY = fy - reach,
		        maxX = fx + reach, maxY = fy + reach,
		        minZ = math.max(-32, fz - 4),
		        maxZ = math.min(EP.MAX_LEVEL, fz + 4) }
	end

	-- The sweep is purse-bounded (`DISCOVER_PER_PASS`) and walks nearest-first, so a wider box
	-- costs more LOOKS rather than a bigger frame - which is the shape this can afford.
	return widenToStructure(box, fx, fy, fz, true)
end

-- [Malcolm_Perf] what the registry needs from this file, all of it read-only access to
-- things above: the original full look, square access, and the original discovery box.
EP.sweepBoxFor = sweepBox
if EP.reg then
	local reg = EP.reg
	reg.noticeSquare = notice
	reg.boxFor = sweepBox
	reg.getSquare = function(x, y, z)
		local cell = getCell()
		return cell and cell:getGridSquare(x, y, z) or nil
	end
	reg.squareLoaded = function(x, y, z)
		local cell = getCell()
		return cell ~= nil and cell:getGridSquare(x, y, z) ~= nil
	end
	reg.levelsOf = function(square)
		local chunk = square.getChunk and square:getChunk()
		if chunk and chunk.getMinLevel and chunk.getMaxLevel then
			return math.max(chunk:getMinLevel(), -32), math.min(chunk:getMaxLevel(), EP.MAX_LEVEL)
		end
		return 0, 7
	end
end

local function boxCovers(outer, inner)
	return outer.minX <= inner.minX and outer.maxX >= inner.maxX
		and outer.minY <= inner.minY and outer.maxY >= inner.maxY
		and outer.minZ <= inner.minZ and outer.maxZ >= inner.maxZ
end

--- Go and look, because nothing is going to say.
---
--- LoadGridsquare files everything that was standing when a chunk opened, and
--- noticeAt files the ten squares a trigger actually touched.  Between them they
--- see nothing that was built after its chunk was already open, and the obvious
--- hook for that is OnObjectAdded, which is not one: LuaEventManager declares it
--- (LuaEventManager.java:734) and AddItemToMapPacket.processClient raises it
--- (AddItemToMapPacket.java:94) and nothing else does, ever.  That makes it an
--- event about *receiving* somebody else's placement.  Singleplayer receives no
--- packets at all, and even in multiplayer the player who placed the object is
--- the one player who does not get it.
---
--- So in singleplayer a rain collector built on the roof was invisible to this
--- mod for the rest of the session.  Right-clicking the sink below it did not
--- help - the narrow trigger reads ten squares, none of them the roof - and
--- neither did the sweep, which deliberately does not walk the fixture list.  The
--- only things that ever fixed it were reloading the world, so LoadGridsquare saw
--- the barrel, or toggling the barrel's own Include option, which happens to
--- service the barrel's square on the way past.
---
--- There is no other event to hook.  A collector can arrive from a build recipe,
--- from the moveables system, from an admin spawn or from another mod entirely,
--- and looking covers all of them and heals a stale registry besides, which no
--- event does.
---
--- Paid for only when it is needed, which is what keeps this from being the volume
--- scan noticeAt replaced.  That one ran on every right-click, was measured from
--- the player rather than from anything, and guessed its z band.  This is reached
--- from groupOrDiscover and only when the registry could offer the fixture nothing at
--- all, so:
---
---   right-clicking anything that is not a fixture      no lookups
---   right-clicking a fixture that has a supply         no lookups
---   right-clicking a fixture that has none             its building, once
---   a wide pass over a building with no collector      its building, once, not
---                                                     once per fixture
---
--- Measured at 2787 square lookups for a two-storey 10x10 house, which is the box
--- and not the map: a town being loaded does not make it larger.  A fixture with
--- nothing to draw on is also the one case where being slightly slower is free,
--- because there is no water to serve at the end of it either way.
--- HOW MUCH SWEEPING ONE PLAYER ACTION MAY PAY FOR.
---
--- MEASURED, real engine, `nanos()`, `tools/luatest/lgep_probe_scopecost.lua`: one sweep of
--- a tap that is in a room and has no supply cost
---
---     Reach  4        729 squares      7.0 ms
---     Reach 12 (default)  5,625       45.0 ms
---     Reach 24       21,609          144.7 ms
---     Reach 64 (the most a player can set)  149,769   211.1 ms
---
--- at about twelve microseconds a square, because this walks `notice()` and not a bare
--- lookup.  And it is paid per FIXTURE, not per action: `EP.serviceAround(x, y, z, true)` -
--- which is what putting a barrel down runs - services every fixture near it, and in a
--- player-built base each one resolves to its own Reach box, so six taps is six sweeps.
---
--- WHO PAYS IT.  A tap in a room with no supply, which is BR-LGEP-003's commonest scene: a
--- barrel standing next to a sink that nobody has taken a wrench to.  The thirteen people
--- on that report are the ones being charged for it, and the advice they are given is to
--- raise Reach.
---
--- So the sweep gets a purse, spent across the whole player action rather than per fixture.
--- `EP.serviceAround` fills it; a sweep that runs out stops where it is and the next action
--- carries on from there (`sweeping`), so nothing is skipped - only spread.
local DISCOVER_PER_PASS = 1024

--- HOW MANY SQUARES THE SWEEP HAS EVER LOOKED AT, and the only reason it is public.
---
--- The purse's claim is a COUNT, not a duration: one player action may not sweep more than
--- the purse plus the overshoot of the last column, however many fixtures it services and
--- whatever Reach is set to.  `lgep_probe_scopecost` used to assert that as milliseconds and
--- flapped five-to-one on an unchanged build - a GC pause, the JIT, another core - so the
--- gate now reads this, which is exact and says the thing that is actually true.  Time is
--- still measured there, per square, to catch a square becoming dearer.
EP.DISCOVER_PER_PASS = DISCOVER_PER_PASS
EP.sweptSquares = 0

--- What is left of that purse.  Refilled by each public entry point, beside `swept`.
local sweepPurse = 0

--- The sweep in progress, or nil: which box, and how far out from its fixture it has got.
local sweeping = nil

--- SWEPT FROM THE FIXTURE OUTWARDS, NEAREST FIRST, and that is what makes a purse safe.
---
--- A budget on a row-major walk would spend itself on the top edge of the box - two hundred
--- tiles due north of the sink - and a barrel built one square away would not be reached for
--- several more actions.  A barrel that is about to serve a tap is NEXT TO IT: the first
--- ring is the tap's own column, and 1,024 squares is everything within five tiles at all
--- nine levels.  The far corners of a Reach 64 box are where nothing useful has ever been.
---
--- `r` is a Chebyshev ring and `i` an index round its perimeter - 8r squares, or one at the
--- centre - so a half-spent sweep resumes from two integers.
local function ringSquare(cx, cy, r, i)
	if r == 0 then return cx, cy end
	local side = 2 * r
	local n = i % (4 * side)
	if n < side then return cx - r + n, cy - r end
	n = n - side
	if n < side then return cx + r, cy - r + n end
	n = n - side
	if n < side then return cx + r - n, cy + r end
	n = n - side
	return cx - r, cy + r - n
end

local function sameBox(a, b)
	return a and b and a.minX == b.minX and a.minY == b.minY and a.minZ == b.minZ
		and a.maxX == b.maxX and a.maxY == b.maxY and a.maxZ == b.maxZ
end

--- HOW FAR OUT IS ALWAYS LOOKED AT, WHATEVER THE SWEEP IN PROGRESS HAS REACHED.
---
--- A purse and a resume point on their own have a hole in them, and it is the hole that
--- matters most: once a sweep has worked its way out to ring thirty, every later look spends
--- its whole purse out there, and a barrel put down NEXT TO THE SINK is not re-read until
--- the entire box has been walked.  The near squares are exactly the ones that change.
---
--- So every look walks the near rings first and unconditionally, and only what is left of
--- the purse carries the outward sweep on.  Three tiles is a barrel beside a sink, a barrel
--- on the roof directly over it, and the 3x3 `noticeAt` already covers, at every level in
--- the band - 441 squares.
---
--- WHAT THE SLOW HALF IS ACTUALLY FOR, now that it is slow.  A barrel only joins a supply
--- when somebody takes a wrench to it (memory/plumbing-is-an-act-not-a-position.md), and
--- `EP.setIncluded` runs `EP.serviceAround` on the BARREL'S own square, which notices it
--- outright.  So every barrel a player means to use is filed by the act of using it; the
--- outward sweep is left as the backstop for what nothing announced and nobody clicked - an
--- admin spawn, worldgen, another mod - and being found within a few looks is the right
--- service level for that.
local NEAR_RINGS = 3

local function discover(fx, fy, fz)
	local box = sweepBox(fx, fy, fz)
	if swept and boxCovers(swept, box) then return false end

	-- THE NEAR RINGS ARE NOT FREE EITHER, AND A WIDE PASS IS MANY FIXTURES.
	--
	-- `EP.serviceAround(x, y, z, true)` services every fixture near the trigger, and each
	-- one that is unsupplied reaches here with its OWN centre - so the near rings are a
	-- different 441 squares every time and `swept` cannot cover them.  Twenty taps in a
	-- player base would be twenty near zones, which is the per-fixture cost this purse was
	-- introduced to end, wearing the fix.
	--
	-- So the purse is checked before the near rings and not only after them.  The whole pass
	-- is then bounded at the purse plus one fixture's near zone - a fixture that arrives with
	-- nothing left is simply looked at by the next action, which is what `sweeping` is for.
	if sweepPurse <= 0 then return false end

	-- A sweep of a different box starts over; the same box carries on.  `swept` is set only
	-- when the box is finished, so an unfinished one is tried again by the next action.
	if not sameBox(sweeping and sweeping.box, box) then
		sweeping = { box = box, r = NEAR_RINGS + 1, i = 0 }
	end

	-- How far out the ring walk has to go before every square of the box has been offered.
	local maxR = math.max(fx - box.minX, box.maxX - fx, fy - box.minY, box.maxY - fy)
	if maxR < 0 then maxR = 0 end

	local cell = getCell()
	local before = sourceCount
	local levels = box.maxZ - box.minZ + 1
	local s = sweeping

	--- One column, every level of the band.  `notice()` rather than a collector test written
	--- out again: a square swept here may just as well be holding a fixture built this
	--- session or a mirror off an older save, and filing all three is what the registry
	--- wanted in the first place.
	local function sweepColumn(x, y)
		if x < box.minX or x > box.maxX or y < box.minY or y > box.maxY then return end
		for z = box.minZ, box.maxZ do
			notice(cell:getGridSquare(x, y, z))
		end
		sweepPurse = sweepPurse - levels
		EP.sweptSquares = EP.sweptSquares + levels
	end

	-- THE NEAR RINGS, EVERY TIME, and not out of the purse's near end: they are what makes
	-- "I just put a barrel down and right-clicked the sink" work, and a look that skipped
	-- them because a far sweep was mid-flight would be the old bug wearing a budget.
	for r = 0, math.min(NEAR_RINGS, maxR) do
		local n = (r == 0) and 1 or (8 * r)
		for i = 0, n - 1 do
			local x, y = ringSquare(fx, fy, r, i)
			sweepColumn(x, y)
		end
	end

	-- AND THEN OUTWARDS, from wherever the last look stopped, for as long as the purse lasts.
	local done = false
	while sweepPurse > 0 do
		if s.r > maxR then done = true; break end
		local x, y = ringSquare(fx, fy, s.r, s.i)
		sweepColumn(x, y)
		s.i = s.i + 1
		if s.i >= (s.r == 0 and 1 or 8 * s.r) then
			s.r = s.r + 1
			s.i = 0
		end
	end

	if done then
		swept = box
		sweeping = nil
	end

	local found = sourceCount ~= before
	-- Guarded, like `refuse` and the draw line in `settleGhost`.  `EP.log` checks the option
	-- itself, but Lua builds the argument first - and this one is an eight-argument format
	-- with a nested `:format` inside it, on the path the sweep purse exists to bound.
	if EP.debugging() then
		EP.log(("swept %d,%d..%d,%d z%d..%d for a collector: %s%s"):format(
			box.minX, box.minY, box.maxX, box.maxY, box.minZ, box.maxZ,
			found and "found one nobody had mentioned" or "nothing new",
			done and "" or (" (out to %d tiles so far; the rest on the next look)"):format(s and s.r or 0)))
	end
	return found
end

--------------------------------------------------------------------------------
-- the collective supply
--------------------------------------------------------------------------------

--- Every resolvable collector in a pool, as objects.
---
--- A pool is a building, so this is the barrels of one house however much of the
--- map is loaded.  Addresses that no longer resolve are pruned on the way past
--- rather than skipped, because this is walked several times a minute once a base
--- has plumbing in it.
local function poolSources(pool)
	if not pool then return {} end
	local list = srcPool[pool]
	if not list then return {} end

	local out, stale = {}, nil
	for key, pos in pairs(list) do
		local source = EP.sourceAt(pos.x, pos.y, pos.z)
		if source then
			out[#out + 1] = { key = key, object = source, x = pos.x, y = pos.y, z = pos.z }
		elseif EP.somethingStandsAt(pos.x, pos.y, pos.z) then
			-- There, but not answering as a supply just now - a barrel somebody has
			-- run a fuel line to.  Not a supply this pass, and NOT forgotten: see
			-- EP.somethingStandsAt.  Nothing would ever file it again.
		else
			-- Unloaded or gone.  Collected rather than dropped on the spot: pruning
			-- inside the traversal is what crashed reviewPumps once already.
			stale = stale or {}
			stale[#stale + 1] = key
		end
	end
	if stale then
		for i = 1, #stale do forgetSource(stale[i]) end
	end
	return out
end

--------------------------------------------------------------------------------
-- how far a building reaches
--------------------------------------------------------------------------------

--- Two BuildingDefs being the same one, basements resolved to the house they are
--- under first.  Both halves live in LGEPCore so the client answers them the same
--- way; see the note there.
local function sameBuilding(a, b)
	return EP.sameDef(EP.canonicalDef(a), EP.canonicalDef(b))
end

--- How many floors down to look for a building beneath a collector that is not
--- standing in one.  A roof is one level above the top floor; four covers a
--- tiered roof or a raised section, and the plan test below catches the rest.
local ROOF_DEPTH = 4

--- The building whose *plan* a column falls in, at any level.
---
--- IsoMetaGrid.getBuildingAtRelax is the engine's own footprint test, already
--- grown by a tile, and it takes no z at all - which is exactly right, because a
--- BuildingDef has no bottom.  CalculateBounds tracks x and y only; getMaxLevel
--- is derived from the rooms and there is no getMinLevel anywhere.  A building is
--- a plan plus a top, so a basement is inside it by construction.
---
--- It is a linear scan over every building on the map, so it is asked last and
--- the fixture's own answer is worked out once per right-click rather than once
--- per collector.
---
--- MEMOISED, because that linear scan was the single most expensive thing this mod did.
---
--- getBuildingAtRelax walks IsoMetaGrid.buildings in order until a footprint grown by one
--- contains the point.  That list is filled at world load from every lot header of every
--- map file, so it is a whole-map constant in the thousands from the first frame - and a
--- MISS is its worst case, because a miss walks all of it.  EP.buildingAt got a bucket
--- index for exactly this reason; this function was the one caller left going straight to
--- the engine.  Measured over a town of 64 houses, one settle pass: 1,580,800 building
--- entries walked, against 14,560 with this table in front of it.  On a real Knox County
--- world, where the list is in the tens of thousands rather than 64, it is worth
--- proportionally more.
---
--- Safe to hold for the session because it is a pure function of the map's plan, and that
--- plan is immutable: IsoMetaGrid.buildings is cleared only on a full world reset.  A
--- PLAYER-built structure is the one thing that appears at runtime, and it cannot corrupt
--- this: clientProcessBuildings synthesises those defs, EP.canonicalDef and
--- EP.buildingBounds both refuse to remember anything isUserDefined, and every caller here
--- passes the answer through canonicalDef before comparing.  The worst a stale entry can
--- do is name a map building that is still exactly where it was.
---
--- `false` and not nil for the negative answer, so a miss is remembered rather than
--- re-walked.  nil would read as "not asked yet" and the misses - the expensive half -
--- would pay the full scan every time.
local columnMemo = {}

--- Cleared alongside the rest of the building memos.  Reached from EP.forgetBuildings in
--- LGEPCore, which OnLoadedMapZones raises after the metagrid is assembled and before
--- anybody is playing through it.
function EP.forgetColumns()
	columnMemo = {}
end

local function columnBuilding(x, y)
	local key = x .. ":" .. y
	local hit = columnMemo[key]
	if hit ~= nil then
		if hit == false then return nil end
		return hit
	end

	local def = getWorld():getMetaGrid():getBuildingAtRelax(x, y)
	columnMemo[key] = def or false
	return def
end

--- Does this collector belong to this fixture's building?
---
--- Three questions in order, because neither end of the interesting cases is
--- actually *in* a room.  A collector on a roof stands on an outside square, so
--- getBuilding() there is nil - the building is not under its feet, it is under
--- the floor below.
---
---   1. the collector's own square, for one standing indoors
---   2. straight down the column, for one on a roof or a balcony
---   3. the same plan, for everything else - the overhang answer, and the reason
---      a barrel out on a corner still counts
---
--- Step 2 stops at the first building it finds rather than carrying on down. A
--- collector standing over next door's roof is over next door, and letting it
--- fall through to the plan test would hand a terrace one shared water supply.
---
--- A basement is no longer a fourth case here.  sameBuilding resolves one to the
--- house standing over it before comparing, so a barrel indoors on the ground floor
--- and a sink in the cellar match at step 1 - where they always should have - rather
--- than by both happening to land on the same footprint at step 3.  That coincidence
--- is what the plan test used to be carrying, and it only held while the basement
--- and the house shared a plan; the moment the basement was smaller than the house,
--- which is what BasementPlacement actually produces, a barrel outside the
--- basement's outline resolved to a different building and the cellar went dry.
local function servesBuilding(scope, sx, sy, sz)
	local cell = getCell()

	-- A match at either of the first two steps settles it.  A *mismatch* does not:
	-- it falls through to the plan test rather than rejecting, so an annexe, an
	-- overhang or an outbuilding sharing a footprint still connects.
	--
	-- Falling through is safe.  The plan test is what keeps a terrace apart, and it
	-- keeps it apart just as well from here: next door's column resolves to next
	-- door's footprint whichever step sent us.
	local square = cell:getGridSquare(sx, sy, sz)
	local own = square and square:getBuilding()
	if own then
		if sameBuilding(own:getDef(), scope.def) then return true end
	else
		for cz = sz - 1, math.max(-32, sz - ROOF_DEPTH), -1 do
			local below = cell:getGridSquare(sx, sy, cz)
			local under = below and below:getBuilding()
			if under then
				if sameBuilding(under:getDef(), scope.def) then return true end
				-- Standing over somebody.  Stop walking; the plan decides.
				break
			end
		end
	end

	if not scope.askedColumn then
		scope.column = EP.canonicalDef(columnBuilding(scope.x, scope.y))
		scope.askedColumn = true
	end
	if not scope.column then return false end

	return sameBuilding(scope.column, columnBuilding(sx, sy))
end

--- Every collector a fixture at fx,fy,fz may draw on, as a group.
---
--- Same building where there is one, plain distance where there is not.
---
--- The building is the real rule and the one worth having: it is what lets a
--- collector on the roof of a house supply the whole house and nothing supply the
--- house next door, whatever the tape measure says.
---
--- The distance is the fallback, and it exists for exactly one case - a structure
--- with no BuildingDef.  On a dedicated server that is every player-built base,
--- because IsoRegions.update() calls clientProcessBuildings() inside
--- `if (!GameServer.server)`, so the BuildingDef synthesised for an enclosed
--- player structure exists on a client and in singleplayer and never on a server.
--- Map buildings resolve everywhere - getRoomByID has no such guard - so the
--- fallback never takes over from a rule that was available.
---
--- Reach is Chebyshev, a square rather than a circle, because a building is a box
--- and a corner of one should not be out of reach of its own middle.
---
--- This asks servesBuilding per candidate rather than reading srcPool[pool] and stopping
--- there, and the difference is not laziness.  poolOf files a barrel under ONE building,
--- decided once at first sighting; servesBuilding is looser on purpose, so an annexe, an
--- overhang or a barrel shoved against a shared wall still connects to the house it is
--- leaning on.  A pool-only walk would silently drop those, and under a collective that
--- shows up as a total that is quietly short rather than as anything anybody could report.
---
--- It no longer walks all of `sources` to do it.  A bounding box decides what is even
--- considered, and that is a different kind of filter from the pool: the pool is TIGHTER
--- than servesBuilding and the box is LOOSER, so the box cannot drop anything the pool
--- would have dropped.  See the note on the bound itself, below.
---
--- It is the same traversal that used to pick a single winner; only the last step
--- changed, from "rank these and keep the best" to "keep all of them".  The scope
--- rules, the scope memo and the prune-after-the-traversal discipline are the ones
--- that were already shipping.
--- `wantType` is the liquid the fixture draws, and it defaults to water so a caller
--- that has not been taught about liquids asks what this mod has always asked.  It
--- is the only new question in the loop below: EP.serves is EP.eligible with the
--- barrel's own liquid tested as well, in one call so the two cannot drift apart.
--- BEGIN a walk over the candidates.  See EP.beginGroupWalk below for why this is split.
---
--- `generator` is true when the consumer is a generator plumbed into the building rather
--- than a fixture.  See EP.generatorGroupFor; the one difference it makes is the building,
--- just below, and nothing in walkStep knows it was asked.
local function walkBegin(fx, fy, fz, wantType, generator)
	local reach = EP.getOption("Reach")

	local def
	if generator then
		-- A GENERATOR IS SCOPED BY THE SAME CALL THAT OFFERED IT THE PLUMB ROW.
		--
		-- EP.canPlumbHere offers Plumb generator indoors, on the roof and against an
		-- outside wall, all through EP.buildingAt.  The fixture rule below takes the
		-- square's own room only, and a generator almost never has one: it stands in the
		-- yard.  So the walk scoped it to a 12-tile Reach square round the machine while
		-- the menu had promised the whole building - BR-LGEE-005, a triple garage whose
		-- far-end generator never saw the barrels at the other end.  Asking EP.buildingAt
		-- here makes the row and the supply one answer.
		--
		-- The shack-against-a-house worry below does not apply.  A generator is plumbed
		-- into a building on purpose, and the building it was offered is the one it
		-- should drink from.
		def = EP.buildingAt(fx, fy, fz)
	else
		local fixtureSquare = getCell():getGridSquare(fx, fy, fz)
		local building = fixtureSquare and fixtureSquare:getBuilding()
		def = building and EP.canonicalDef(building:getDef()) or nil
	end

	-- Deliberately the square's own room and not EP.buildingAt, which would fall
	-- back to the plan: a fixture in a player-built shack pitched against a map
	-- building must keep the Reach rule rather than be adopted into the house next
	-- to it.  Resolved through canonicalDef all the same, so a fixture in a cellar
	-- is scoped to the house it is under.
	--
	-- Worked out once per fixture and carried through the loop, because step 3 of
	-- servesBuilding walks every building on the map.
	local scope = def and { def = def, x = fx, y = fy, askedColumn = false } or nil

	-- THE REGION GRAPH IS ASKED ALONGSIDE THE DEF, NOT INSTEAD OF IT.
	--
	-- It used to be `(not def) and ...`, on the reasoning that a def is the better answer
	-- and the region is what a dedicated server has to fall back on.  That reasoning was
	-- wrong in one direction and it is the direction players build in.
	--
	-- A structure a player raises within about a tile of a map building gets NO def, in
	-- EVERY mode: clientProcessBuildings discards any def it synthesises that is adjacent to
	-- or overlapping a predefined one (WorldRegionToMetaGrid.java:100-104 and :512-530, and
	-- RoomDef.isAdjacent grows the other rectangle by a tile first).  An extension bolted
	-- onto a house is the ordinary way to build a base, and its squares are in none of the
	-- house's RoomDefs, so the def path cannot see it and never could - not on a server, and
	-- not in singleplayer either.
	--
	-- The region graph can.  A DataChunk floods squares into a region across every edge with
	-- no wall on it, so a house and the extension a player opened a doorway into are
	-- literally ONE IsoWorldRegion (floodFillExpandWorldRegion, DataChunk.java:630-651).
	-- The engine already knows the extension is part of the house; it has nowhere to write it
	-- down.  That is the whole of the renovation case, and it needs no rule of its own.
	--
	-- So neither test is a superset - a map basement is below ground, where
	-- getIsoWorldRegion() returns null outright, and a player extension has no def - and
	-- membership is the union.  See plans/player-built-structures.md.
	--
	-- Reach remains underneath both, unchanged, for a fixture in neither - an unroofed pen,
	-- a lean-to, a barrel on open ground.
	local regions = EP.regionsAt(fx, fy, fz)

	-- THE LOCALITY BOUND.  A collector outside this box cannot pass servesBuilding, so it
	-- is never asked.
	--
	-- This is not the srcPool shortcut the note above refuses, and the difference is the
	-- whole reason it is safe.  A POOL filter is TIGHTER than servesBuilding - poolOf files
	-- a barrel under one building, so the annexe and the overhang get dropped.  A BOUNDING
	-- BOX is LOOSER than it: every branch of servesBuilding resolves the collector to a
	-- BuildingDef and compares it with sameBuilding, and every one of those resolutions -
	-- the collector's own room, the column below it, the plan under it - places the
	-- collector inside that def's footprint.  So the annexe, the overhang and the barrel
	-- against a shared wall are all still inside the box and still asked.  The box narrows
	-- what is CONSIDERED; it cannot narrow what is ACCEPTED.
	--
	-- What it removes is the rest of the town.  supplyGroup walked every collector on the
	-- map and paid a square lookup, an object scan and a plan test to reject each one.
	-- Measured over 64 houses, 256 mirrors and 192 collectors: a settle pass of 1,991,168
	-- operations became 55,529, and one drink went from 1,988,366 to 1,701.
	--
	-- Grown by 2, matching affectedBox, which covers getBuildingAtRelax's own +/-1 slop.
	-- The Reach square is the floor rather than the alternative: with no building this is
	-- exactly the `else` branch's own test, and with one it costs nothing to keep.
	local bMinX, bMinY, bMaxX, bMaxY = fx - reach, fy - reach, fx + reach, fy + reach
	local function widen(d)
		local b = d and EP.buildingBounds(d) or nil
		if not b then return end
		if b.minX - 2 < bMinX then bMinX = b.minX - 2 end
		if b.minY - 2 < bMinY then bMinY = b.minY - 2 end
		if b.maxX + 2 > bMaxX then bMaxX = b.maxX + 2 end
		if b.maxY + 2 > bMaxY then bMaxY = b.maxY + 2 end
	end
	if def then
		widen(def)

		-- BOTH IDENTITIES, because servesBuilding can match on either.
		--
		-- Steps 1 and 2 compare against scope.def; step 3 compares against scope.column.
		-- Those are the same building only while canonicalDef resolves a basement to its
		-- parent.  When findParent fails, scope.def is the cellar and scope.column is the
		-- house standing over it - and a box built from the cellar alone would drop a
		-- barrel indoors on the ground floor outside the cellar's outline.  That is the
		-- exact fault the note above servesBuilding records as having gone dry once
		-- already, and it is not being re-introduced through the back door.
		--
		-- ASKED ONLY WHEN THE TWO CAN DIFFER, which is why the isBasementDef gate is here
		-- and not left to the memo.  Asked unconditionally this is a getBuildingAtRelax
		-- MISS for every ordinary house - the worst case of a linear scan, because a miss
		-- walks the whole list - and it put 105,007 building entries back into a single
		-- sweep on a map carrying 15,000 of them.  A superset that is expensive to compute
		-- is not a free superset.
		if EP.isBasementDef(def) then
			widen(EP.canonicalDef(columnBuilding(fx, fy)))
		end
	end

	-- AND BY THE STRUCTURE, for the same reason the def widens it: a barrel at the far end of
	-- a long extension is inside the structure and outside a 12-tile square, and a box that
	-- dropped it would narrow what is ACCEPTED rather than what is CONSIDERED - which is the
	-- one thing the note above forbids.
	--
	-- Chunk granularity, straight off getChunkRegions(), so this costs a pass over the pieces
	-- of the structure and not over its squares.  Loose in the safe direction: a box that is
	-- 8 tiles too big considers a few more candidates and accepts none of them.
	if regions then
		local b = EP.regionBounds(regions)
		if b then
			if b.minX - 2 < bMinX then bMinX = b.minX - 2 end
			if b.minY - 2 < bMinY then bMinY = b.minY - 2 end
			if b.maxX + 2 > bMaxX then bMaxX = b.maxX + 2 end
			if b.maxY + 2 > bMaxY then bMaxY = b.maxY + 2 end
		end
	end

	-- AND THE PIPE NETWORKS IT IS ON, the fourth way to be in scope.
	--
	-- Asked the way a fixture is asked everywhere else - its own room, not the plan - unless
	-- the consumer is a generator, which is scoped like a barrel for the reason above.  The
	-- box grows by every member of those networks, for the same reason it grows by the
	-- building: a barrel in the house at the other end of a pipe is outside both of the
	-- boxes above, and a box that dropped it would narrow what is ACCEPTED.
	--
	-- One table walk when nothing is laid.  See plans/lgep-pipe-network.md section 7.
	local nets = nil
	if EP.anyPipes and EP.anyPipes() then
		nets = EP.pipeNetsAt(fx, fy, fz, not generator)
		local nb = nets and EP.pipeNetsBox(nets) or nil
		if nb then
			if nb.minX < bMinX then bMinX = nb.minX end
			if nb.minY < bMinY then bMinY = nb.minY end
			if nb.maxX > bMaxX then bMaxX = nb.maxX end
			if nb.maxY > bMaxY then bMaxY = nb.maxY end
		end
	end

	-- HOW MUCH THIS CALL ACTUALLY COST, for the maintenance cursor to pace itself by.
	--
	-- The cursor cannot know in advance what a mirror is worth: after the locality bound a
	-- tap in a terraced house considers three collectors and a tap in a hoarder's base
	-- considers two hundred, and the registry size no longer predicts either - it counts
	-- the whole world, and the box is what decides how much of it is looked at.  Guessing
	-- from sourceCount over-estimated an ordinary base by sixty times.
	--
	-- So it is measured rather than guessed, in the step below, where it is free: one
	-- integer counting exactly the candidates that got past the box.  That is the inner
	-- loop, and everything expensive about a settle is proportional to it.

	-- FLATTENED, because the walk has to survive the end of a tick.
	--
	-- Kahlua has no `next`, so a pairs() traversal cannot be suspended and resumed - the
	-- candidates are taken as an array and walked by index instead.  Cheap: table writes
	-- and no Java crossings, which is the opposite of what the walk itself costs.
	local list = {}
	for key, pos in pairs(sources) do
		list[#list + 1] = { key = key, x = pos.x, y = pos.y, z = pos.z }
	end

	return {
		fx = fx, fy = fy, fz = fz, wantType = wantType, reach = reach, scope = scope,
		regions = regions, nets = nets,
		bMinX = bMinX, bMinY = bMinY, bMaxX = bMaxX, bMaxY = bMaxY,
		list = list, at = 1, group = {}, considered = 0, stale = nil,
		-- How many collectors in scope are PLUMBED IN, whatever else is true of them.  See
		-- the note where it is counted; a zero is what says a building's plumbing is gone
		-- rather than merely idle.
		supply = 0,
		-- And how many of those are SPOKEN FOR: holding something, or empty and kept for a
		-- liquid.  The difference between the two decides whether a mirror with nothing in it
		-- keeps standing in front of vanilla's own answer; see EP.sleepGhost.
		spoken = 0,
		-- And how many are plumbed in, in scope, and refused ONLY because they are not above
		-- the tap and have no pump.  Counted for the log and nothing else; see walkStep.
		needPump = 0,
		-- And how many candidates this walk could NOT SEE, because their square is not in
		-- memory.  Zero is what makes `supply == 0` mean "this building has no plumbing"
		-- rather than "I could not tell"; see retireIfUnsupplied.
		unresolved = 0,
		epoch = walkEpoch,
		summary = EP.newSummary(),
	}
end

--- Advance a walk by at most `budget` candidates.  Returns true when it is finished.
---
--- The body is the one that used to sit inline in supplyGroup and is unchanged; what moved
--- is only where it stops.
--- THE BUDGET COUNTS WHAT THE BOX ADMITS, NOT WHAT IT LOOKS AT.
---
--- Charging every candidate the same was the first attempt and it made the cursor far
--- slower without making any frame cheaper: a candidate outside the box costs four integer
--- comparisons, and one inside costs a grid lookup, an object walk and a building test.
--- Budgeting the cheap ones meant spreading a scan that was already free - in a town of
--- thirty-six houses a single mirror took twenty-four ticks to walk a hundred and forty
--- collectors it rejected instantly, and the cursor stopped completing laps at all.
---
--- So `spent` counts admitted candidates and `scanned` is only a stop on the raw scan, so
--- that a registry of thousands still cannot be walked end to end in one frame.  It is
--- deliberately loose - eight times the budget - because that scan is the part the locality
--- bound already made nearly free.
local function walkStep(w, budget)
	local group, scope, fx, fy, fz = w.group, w.scope, w.fx, w.fy, w.fz
	local spent, scanned = 0, 0
	local scanCap = budget * 8

	while w.at <= #w.list and spent < budget and scanned < scanCap do
		local entry = w.list[w.at]
		w.at = w.at + 1
		scanned = scanned + 1
		local key, pos = entry.key, entry
		-- Four integer comparisons, before anything is resolved.  What they save is the
		-- EP.sourceAt below - a grid lookup and a walk of the square's objects - and the
		-- servesBuilding call after it.
		local inBox = pos.x >= w.bMinX and pos.x <= w.bMaxX
			and pos.y >= w.bMinY and pos.y <= w.bMaxY

		if inBox then
			w.considered = w.considered + 1
			spent = spent + 1
		end

		local source = inBox and EP.sourceAt(pos.x, pos.y, pos.z) or nil
		if not inBox then
			-- Out of scope for THIS fixture, and nothing whatever is concluded about it.
			--
			-- The staleness check below must not run here.  It asks whether a collector
			-- has gone, and answers "yes" for anything it cannot resolve - so letting a
			-- barrel in the next street reach it would prune a perfectly good collector
			-- from the registry on the strength of a question that never applied to it.
			-- Being outside one fixture's box says nothing about whether a barrel exists.
		elseif not source then
			-- Unloaded or gone.  Either way it is not a supply right now, and
			-- LoadGridsquare files it again if it comes back.  Collected rather
			-- than dropped on the spot: this table is walked by reviewPumps too,
			-- and pruning inside a traversal is what crashed that one.
			--
			-- Unless it is still standing there and merely not qualifying - a barrel
			-- with a fuel line on it.  "LoadGridsquare files it again" is the whole
			-- justification for forgetting, and it is not true of that one: its chunk
			-- is already open and will not be loaded a second time.  See
			-- EP.somethingStandsAt.
			--
			-- THE THIRD ANSWER IS COUNTED AND NOT DISCARDED, and that is what stops a
			-- correctly plumbed base losing its taps for thirty seconds every time its
			-- barrels stream out.  `unresolved` is candidates this walk could not SEE, as
			-- against candidates it looked at and found gone; retirement may only conclude
			-- "there is no plumbing here" from a walk that saw the whole scope.
			local presence = EP.collectorPresence(pos.x, pos.y, pos.z)
			if presence == EP.AT_UNLOADED then
				w.unresolved = (w.unresolved or 0) + 1
			elseif presence == EP.AT_EMPTY then
				w.stale = w.stale or {}
				w.stale[#w.stale + 1] = key
			end
		else
			local dx, dy = pos.x - fx, pos.y - fy

			-- THREE TESTS, IN COST ORDER, AND ANY ONE OF THEM IS A YES.
			--
			-- Ordered so the expensive one is asked least: the def test is a walk this mod
			-- has always paid for and is answered from a bucket index; the region test is up
			-- to COLUMN_DEPTH grid lookups and is asked only for a candidate the def test
			-- rejected - which, after the locality box, is a handful; the tape measure is
			-- four comparisons and only decides anything when neither structure answered.
			--
			-- WHAT GATES THEM IS INCLUSION ALONE NOW, where it used to be the whole of
			-- EP.serves, and that is a deliberate trade rather than a loosening.
			--
			-- The scope answer is worth more than group membership: it is also the answer to
			-- "has this building got ANY plumbing left", which is what decides whether a
			-- mirror over a dry fixture is asleep or finished - see retireIfUnsupplied.  A
			-- barrel that is plumbed in but cannot serve THIS tap, because the generator is
			-- off or because it holds whiskey, is still the building's supply and still the
			-- reason a mirror stays standing.  Gravity and the liquid cannot answer that
			-- question, so they may not gate it.
			--
			-- What it costs is one scope test per PLUMBED IN candidate that the old order
			-- would have rejected on gravity or on liquid.  That is bounded by the number of
			-- barrels a player has plumbed into the box, which is exactly the size the group
			-- itself would be with the generator running - so the worst case here is no worse
			-- than the same base working normally, and the ordinary case (barrels above the
			-- tap, holding water) is unchanged.
			--
			-- MEASURED, not argued: 200 plumbed barrels on the tap's own floor with no
			-- generator went from 210 square lookups to 410, and 410 is exactly what the same
			-- 200 barrels cost with the power on.  See
			-- plans/raw/lgep-retire-unsupplied-2026-08-15.md, which also records the reading
			-- in the other direction - a town's settle got CHEAPER, because EP.serves ends in
			-- a container read and is no longer asked of candidates that are out of scope.
			--
			-- Inclusion still comes first, and that is what keeps a field of unplumbed
			-- barrels, or a barrel of petrol nobody joined up, from costing a region walk.
			local within = false
			if EP.isIncluded(source) then
				if scope and servesBuilding(scope, pos.x, pos.y, pos.z) then
					within = true
				elseif w.regions and EP.regionsMeet(pos.x, pos.y, pos.z, w.regions) then
					-- The height band is kept.  A region is a volume the engine derived from
					-- connectivity, and a barrel four floors above a sink up the same
					-- stairwell is not gravity.
					within = math.abs(pos.z - fz) <= 4
				elseif not scope and not w.regions and not w.nets then
					-- NOT FOR A FIXTURE ON A PIPE.  Reach is the answer for something in
					-- neither a building nor a structure, and a fixture on a pipe is in
					-- neither - but it IS on a network, and a network is an answer: "either
					-- covered by the piping system or not".  Letting Reach in as well would
					-- hand an outdoor tap every plumbed barrel within twelve tiles, piped to it
					-- or not, which is the over-application plumbing-as-an-act exists to end.
					within = math.max(math.abs(dx), math.abs(dy)) <= w.reach
						and math.abs(pos.z - fz) <= 4
				end

				-- THE PIPE NETWORK, asked last because it is asked least: only a candidate
				-- the building and the structure both refused, in a world with pipes laid.
				-- No height band - a network is topology somebody built, and gravity is
				-- EP.serves's business below, exactly as it is inside a house.
				if not within and w.nets and EP.pipeNetsMeet(pos.x, pos.y, pos.z, w.nets, false) then
					within = true
				end
			end

			-- THE BUILDING'S PLUMBING, COUNTED, whatever this particular tap can do with it.
			--
			-- Everything above is scope and inclusion; nothing below is.  So this is the
			-- count of barrels somebody has plumbed into this fixture's building - the whole
			-- supply, not the part of it this tap can reach today - and a zero here means
			-- there is no plumbing left to be a mirror OF.
			--
			-- The group is a subset of it by construction, so `supply == 0` implies an empty
			-- group and never the other way round.  That is the invariant retireIfUnsupplied
			-- rests on and lgep_spec_teardown asserts.
			if within then
				w.supply = w.supply + 1
			end

			-- AND NOW WHAT THIS TAP CAN ACTUALLY DRAW ON, out of what is in scope.
			--
			-- A collector only ever feeds what is BELOW it, and never its own floor.  Water
			-- runs downhill, and vanilla says the same thing: FindExternalWaterSource looks
			-- at z+1 and its neighbours, one storey up, so a barrel standing on the same
			-- floor as a sink is not a supply in vanilla either and must not become one here.
			--
			-- How far below is not limited, and that is the basement answer: a BuildingDef is
			-- a plan plus a top with no bottom at all (CalculateBounds tracks x and y only,
			-- and there is no getMinLevel), so once "same building" has answered, depth is
			-- already accounted for.  The fallback has no containment to lean on, so it keeps
			-- a band: four storeys covers a player base with a basement and a roof without
			-- reaching one built on a cliff below.
			--
			-- Gravity, unless it is pumped, in the network at all, and holding the
			-- right liquid.  EP.serves is every one of those in one call, and it is
			-- the only place any of them is asked - the settle path used to re-check
			-- height and forget inclusion, so an excluded barrel went on filling
			-- mirrors above it.  `own` comes back as the barrel's own liquid, or nil
			-- for one nobody has filled yet.
			--
			-- It re-asks EP.isIncluded, which the branch above has already answered.  One
			-- modData read, deliberately paid: membership is decided by ONE predicate, and
			-- taking the inclusion clause out of it here to save that read would leave two
			-- half-copies of the rule to drift apart.
			--
			-- A GENERATOR IS HELD TO THE SAME RULE.  A barrel above it feeds it by gravity; one
			-- on its floor or below feeds it only while that barrel's square has power.  Only
			-- the building is resolved differently for a generator, in walkBegin.
			local serves, own = false, nil
			if within then serves, own = EP.serves(source, pos.z, fz, w.wantType) end

			-- IS THERE ANYTHING HERE WORTH DEFENDING, which is a different question from
			-- whether this tap can draw on it, and a different one again from whether the
			-- plumbing exists at all.
			--
			-- A barrel is spoken for when it holds something, or when it is empty and kept for
			-- a liquid - which is exactly `own ~= nil`, because EP.barrelFluidType derives from
			-- the contents first and falls back to the remembered key.  A plumbed-in barrel
			-- that is empty and has never held anything is not spoken for: there is nothing in
			-- it, no liquid it belongs to, and nothing a mirror over it could be defending.
			--
			-- FREE ON EVERY CANDIDATE THAT CAN SERVE, which is the whole group and therefore
			-- the ordinary case: EP.serves has already read the contents and handed back `own`.
			-- The extra read below is reached only by a barrel that is plumbed in and in scope
			-- and REFUSED - by gravity or by a stopped generator - because EP.serves returns
			-- nil for those without looking in them.  In a base that is working that is no
			-- candidates at all.
			-- WHY A BARREL THAT IS PLUMBED IN AND IN SCOPE STILL GAVE NOTHING, for the log.
			--
			-- The commonest support question there is, and until this line there was no way to
			-- answer it from a save: a barrel standing at or below the tap feeds nothing unless
			-- a generator reaches ITS square, and IsoGridSquare.haveElectricity opens with
			--
			--     !allowExteriorGenerator && has(exterior) ? false : ...   (:10076-10080)
			--
			-- so on a server with AllowExteriorGenerator turned off, a barrel outdoors - against
			-- a wall, or up on a roof - can NEVER be a pump however close the generator is.  The
			-- barrel is in scope, the Plumb row is offered because it is, and it quietly supplies
			-- nothing at all.  Nothing on screen says why and nothing could.
			--
			-- Behind EP.debugging() because EP.isPumped ends in a Java call and this is the
			-- inner loop; with the option off it is one boolean per candidate.
			if within and not serves and pos.z <= fz and EP.debugging()
				and not EP.isPumped(source) then
				w.needPump = w.needPump + 1
			end

			if within then
				if own ~= nil then
					w.spoken = w.spoken + 1
				elseif not serves and EP.barrelFluidType(source) ~= nil then
					w.spoken = w.spoken + 1
				end
			end

			if serves then
				group[#group + 1] = {
					object = source, x = pos.x, y = pos.y, z = pos.z,
					reserve = EP.isReserve(source),
					assigned = own ~= nil,
				}

				-- SUMMARISED ON THE WAY PAST, so the settle at the end does not have to
				-- walk the members again.
				--
				-- Without this the walk bounded only half the job: the candidate scan was
				-- spread over ticks and then the apply read every member in one frame
				-- anyway, so the peak stayed linear in barrels-per-building - 2,477
				-- operations at eight hundred barrels, which is the number this removes.
				-- The container is in hand here already; the totals are free.
				--
				-- THROUGH EP.addToSummary, and it used to be a hand copy of that function's
				-- body sitting here.  Two transcriptions of one rule is the drift the core
				-- file complains about at every other seam, and this one had teeth: a
				-- summary is what the mirror is REBUILT from, so the cursor's copy going
				-- stale would not be a slow answer, it would be a different one from the
				-- answer a right-click gives for the same barrels.
				EP.addToSummary(w.summary, source:getFluidContainer())
			end
		end
	end

	if w.at <= #w.list then return false end

	-- Applied at last.  These keys were collected on every pass and then dropped on
	-- the floor, so a collector whose chunk had unloaded was re-resolved and
	-- re-failed on every right-click for the rest of the session.
	--
	-- This calls worldChanged and so bumps the epoch, which would invalidate the walk that
	-- has just finished if the check were made after it.  It cannot actually invalidate
	-- anything: every key here is a collector EP.sourceAt could not resolve, so none of them
	-- was ever admitted to the group.  The caller checks the epoch BEFORE this runs.
	if w.stale then
		for i = 1, #w.stale do forgetSource(w.stale[i]) end
		w.stale = nil
	end

	return true
end

--- The whole walk at once, which is what every caller outside the maintenance cursor wants.
---
--- A right-click, a placement, a drink: all of them need an answer in the frame they were
--- asked in, so all of them run the walk to completion here.  Only the cursor - which
--- nobody is waiting on - spreads it.
EP.beginGroupWalk = function(fx, fy, fz, wantType) return walkBegin(fx, fy, fz, wantType) end
EP.stepGroupWalk  = function(w, budget) return walkStep(w, budget) end
EP.walkEpochNow   = function() return walkEpoch end

--- THE SUMMARY IS RETURNED BESIDE THE GROUP.  Q13, closed 2026-08-16.
---
--- walkStep accumulates `w.summary` on the way past because the container is in hand
--- anyway - see the note where it does it.  Returning only `w.group` meant every caller
--- outside the maintenance cursor handed EP.settleGhost no summary, so it built a second
--- one from scratch: a full extra pass over the group, a getAmount and a getCapacity and a
--- contents read per member.  The cursor never paid it, because stepSettleWalk passes its
--- own through - so the cost fell entirely on the paths a PLAYER triggers, every
--- right-click, placement and draw, which is the wrong half to be paying it.
---
--- A SECOND RETURN VALUE AND NOT A CHANGED ONE, which is what makes this safe to do to a
--- function with a dozen callers: `local group = supplyGroup(...)` goes on meaning exactly
--- what it meant, and only a caller that asks for the second value gets it.  Nothing has
--- to be audited for having silently started receiving a table it did not want.
---
--- The staleness guard is already in settleGhost and is not weakened here: it discards the
--- summary outright when anything moved (`if moved then summary = nil end`) and rebuilds,
--- so a summary handed in can only ever be used for a settle that changed nothing. That is
--- precisely the case it saves - the common one, where a group is re-read and is the same.
local function supplyGroup(fx, fy, fz, wantType)
	local w = walkBegin(fx, fy, fz, wantType)
	walkStep(w, math.huge)
	EP.lastConsidered = w.considered
	return w.group, w.summary, w.spoken, w.needPump
end

--- The registry's answer, and a look around when it has not got one.
---
--- Two steps and not two rules: every question about scope, gravity and inclusion
--- stays in supplyGroup above, and discover() only puts things into the registry
--- for it to consider.  A collector that was swept up and then rejected is
--- rejected for the same reasons as one that arrived through LoadGridsquare,
--- rather than through a second copy of the scope test that could drift out of
--- step with the first.
---
--- Which also means the sweep is not a second chance at a "no": a fixture out of
--- scope of every collector in its building sweeps once, learns nothing new, and
--- gets the same answer.
local function groupOrDiscover(fx, fy, fz, wantType)
	-- Both values forwarded, per Q13.  The summary belongs to whichever walk produced the
	-- group being returned, and the two are never crossed: the second walk overwrites both
	-- or neither.
	local group, summary, spoken, needPump = supplyGroup(fx, fy, fz, wantType)
	if #group > 0 then return group, summary, spoken, needPump end

	if not discover(fx, fy, fz) then return group, summary, spoken, needPump end
	return supplyGroup(fx, fy, fz, wantType)
end

--- The hook the delivery layer asks through.  See EP.supplyGroupFor in LGEPCore.
---
--- Deliberately the plain lookup and NOT groupOrDiscover: this is reached from
--- every settle, including the once-a-minute sweep over every mirror in the world,
--- and discover() walks a whole building.  Discovery belongs on the path that is
--- deciding whether a fixture should have a mirror at all, which is serviceFixture,
--- and it is paid for once per trigger there.
EP.supplyGroupFor = supplyGroup

--- Every barrel of `wantType` a GENERATOR plumbed in at gx,gy,gz may draw on.
---
--- A petrol barrel plumbed into a building feeds every generator plumbed into that
--- building, wherever in it each one stands, under the same gravity rule as a tap: above
--- feeds by gravity, its own floor or below only while the barrel's square has power.  So
--- it is supplyGroup with the building taken from EP.buildingAt, the call that offered the
--- Plumb generator row - see walkBegin.  Everything else is shared, so a barrel is in a
--- generator's building by exactly the test that puts it in a sink's.
---
--- Plain lookup, no discover(), for supplyGroupFor's reason: LG Extended Electricity asks
--- this once per plumbed generator per game hour, and a barrel is filed when it is plumbed
--- in and when its chunk loads.
local function generatorGroup(gx, gy, gz, wantType)
	local w = walkBegin(gx, gy, gz, wantType, true)
	walkStep(w, math.huge)
	EP.lastConsidered = w.considered
	return w.group, w.summary
end

EP.generatorGroupFor = generatorGroup

--- There is deliberately no election here any more, and nothing to choose between.
---
--- One collector per building used to be its main supply; every fixture drank from
--- the main and every other barrel was drained into it, so the whole question was
--- "which barrel", asked over and over as barrels filled and emptied.  It answered
--- badly in three directions at once: a tap could only ever show one barrel's
--- worth however much the building held, a barrel below the main was dead weight
--- without a generator, and a fixture ABOVE the main fell back to a single barrel
--- that the top-up pass then drained out from under it.
---
--- The answer is the group, and the group needs no deciding - it is every barrel
--- the fixture can physically reach, which is a question about heights and pumps
--- that supplyGroup answers from the world every time it is asked.

--- There is deliberately no test here for "vanilla can already reach water".
---
--- There used to be, and it was the mode switch this design exists to remove.  The
--- mod stood down whenever a real collector in the nine squares happened to hold a
--- drop, and stood back up when it did not - so the top-up pass, by draining that
--- very barrel into the main, flipped the mod on; rain flipping the barrel back
--- flipped it off; and each cycle destroyed and rebuilt a transmitted world object
--- per fixture.  Worse, the flip could not settle: once the main reached capacity
--- the top-up stopped taking, the barrel over the sink kept its rain for good, and
--- the fixture was left on whichever side of the switch it happened to be.
---
--- A ghost seated at index 0 of the centre square is reached before anything else
--- on that square and before any neighbour is considered, so there is nothing left
--- to arbitrate.  Every fixture is fed the same way, from the same place, whatever
--- is standing over it - a barrel in its own group, or one the player excluded.
---
--- The ghost belonging to this fixture, from the one square it can be on.
---
--- One lookup rather than the nine this used to walk.  A ghost is always on
--- (fx, fy, fz+1) now, so a ghost found anywhere else belongs to an older layout
--- and is cleared by the sweep rather than adopted here.
---
--- The object list is read straight rather than through ghostsOnSquare: one pass,
--- no table allocated, and no state kept between calls.  An earlier version reused
--- a module-level scratch table and a later edit deleted its declaration, which
--- turned it into a nil global and crashed the whole settle pass on `#scratch`.
local function ghostFor(fx, fy, fz)
	local square = getCell():getGridSquare(fx, fy, fz + 1)
	if not square then return nil end

	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if EP.isGhost(object) then
			local data = object:getModData()
			if data[EP.KEY_FIX_X] == fx and data[EP.KEY_FIX_Y] == fy
				and data[EP.KEY_FIX_Z] == fz then
				return object
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- keeping one fixture right
--------------------------------------------------------------------------------

local function forgetFixture(key)
	local entry = fixtures[key]
	if entry and entry.pool and byPool[entry.pool] then
		byPool[entry.pool][key] = nil
	end
	if entry then fixturesChanged() end
	fixtures[key] = nil
end

--- File a mirror's square in the registry the sweep walks.
---
--- Needed after a RESEAT as much as after a spawn, and that is not obvious.
--- Re-seating is a remove followed by an add, and the remove raises
--- OnObjectAboutToBeRemoved - in every mode, not just one: IsoGridSquare
--- RemoveTileObject raises it for singleplayer and clients, and
--- RemoveItemFromSquarePacket.removeItemFromMap raises it for the dedicated
--- server's own path through GameServer.RemoveItemFromMap.  This mod's handler for
--- it drops the square from `ghosts`, which is correct for a mirror being taken
--- away and quietly wrong for one being put back a moment later.
---
--- Left unfiled, a mirror is still settled by OnWaterAmountChange when somebody
--- draws through it, so it does not leak water - but it falls out of the sweep,
--- which is what carries rain to it and what checks its seat.  It would have gone
--- stale slowly and only under the one repair path, which is the worst way for
--- anything to be wrong.
local function rememberGhost(ghost)
	local square = ghost and ghost:getSquare()
	if not square then return end
	local x, y, z = square:getX(), square:getY(), square:getZ()
	local key = EP.key(x, y, z)
	ghosts[key] = { x = x, y = y, z = z }
	markMirrorSaved(key)
end

--- Re-seat and keep the registry honest.  Always this, never EP.reseatGhost bare.
local function reseat(ghost)
	if EP.reseatGhost(ghost) then rememberGhost(ghost) end
end

local function forgetGhost(ghost)
	local square = ghost:getSquare()
	if square then
		local key = EP.key(square:getX(), square:getY(), square:getZ())
		ghosts[key] = nil
		supplyChanged()
		-- The repair record goes with the address: a different mirror appearing on this
		-- square later is a mirror this session has never inspected.
		repaired[key] = nil
		unsupplied[key] = nil
		if savedMirrors then savedMirrors[key] = nil end
	end
	EP.removeGhost(ghost)
end

--------------------------------------------------------------------------------
-- when the plumbing is gone, so is the mirror
--------------------------------------------------------------------------------

--- HOW LONG A BUILDING MUST HAVE HAD NO PLUMBING BEFORE ITS MIRRORS ARE TAKEN AWAY.
---
--- Both, not either.  Laps alone are wrong because a lap is not a duration - a cottage
--- laps in milliseconds and a town takes tens of seconds - and seconds alone are wrong
--- because a suite has no clock at all (getTimeInMillis is withheld everywhere except
--- lgep_spec_rate) and would then never retire anything.  Two laps says "this was seen
--- again and again"; thirty seconds says "and it was not a moment".
---
--- GENEROUS ON PURPOSE, because nothing is waiting on it.  A mirror is invisible,
--- unclickable and out of the context menu, so a mirror that outlives its supply by a
--- minute costs a player precisely nothing - it is save clutter, not a fault.  What being
--- hasty WOULD cost is real: the registry holds only what is loaded, so a base whose
--- barrels are in a chunk that has streamed out reads as a base with no plumbing, and a
--- mirror torn down for that is one rebuilt and re-transmitted when the chunk comes back,
--- with its debt forgiven on the way past.  The wait is what tells the two apart.
local RETIRE_LAPS = 2

--- TEN MINUTES, NOT THIRTY SECONDS, and the old number was chosen against the wrong cost.
---
--- Retirement is save-hygiene: what it buys is a saved object with no purpose going away.
--- Nothing is waiting on it and nothing reads worse for it being late.  What it COST at
--- thirty seconds was a fixture, because while the mirror is gone the tap above it is dry,
--- out of the right-click menu and unplumbable - and thirty seconds of a base's barrels
--- being unloaded is not a rare event on a dedicated server delivering 64x64 cells.
---
--- The resolved-scope test below is the real fix and this is the belt to its braces.
local RETIRE_SECONDS = 600

--- Take a mirror away when there is no longer any plumbing for it to be a mirror OF.
---
--- THE DISTINCTION THIS DRAWS, and it is the whole function.  EP.sleepGhost exists for a
--- supply that is IDLE - the generator stopped, the barrels hold the wrong liquid, the
--- chunk they stand in has gone - and every one of those reverses on its own, which is why
--- sleeping rather than destroying is right for them.  A building whose barrels have all
--- been carried away, or all been disconnected with a wrench, is not idle: there is nothing
--- left to come back, and a mirror standing over it is a saved object with no purpose,
--- exactly as if the mod had never touched the place.
---
--- `supply` is what tells them apart, and it is counted by the walk that has just finished:
--- collectors in this fixture's scope that somebody has PLUMBED IN, whatever their height,
--- their power or their liquid.  Anything above zero means the plumbing is there and idle,
--- so the mirror sleeps as it always did.
---
--- A MIRROR THAT HAS NOT BEEN THROUGH ADOPTION IS NEVER RETIRED.  EP.adoptLegacyPlumbing
--- uses the mirror itself as the evidence that a building's barrels were supplying a
--- fixture before plumbing became an act - and on the first load after that update every
--- barrel reads as unplumbed, which is precisely `supply == 0`.  Retiring on the strength of
--- it would destroy the evidence before the pass that reads it, and the building would be
--- dry for good with nothing to say why.  The stamp is written by the pass on the same
--- visit, immediately above the settle that reaches here, and by EP.spawnGhost at birth - so
--- this only ever waits for a mirror that genuinely has not been looked at yet.
---
--- `supply` IS NOT ON ITS OWN AN ANSWER, and reading it as one is the second half of what
--- took players' water away.  A walk resolves each candidate through EP.sourceAt, and a
--- candidate whose chunk has streamed out resolves to nil - so a base whose barrels are
--- temporarily unloaded counted identically to a base whose barrels had all been
--- disconnected.  `unresolved` is what tells them apart and it is now required to be zero.
--- See plans/lgep-why-players-lost-their-water.md §3.
---
--- Anything the mirror still owes dies with it, and that is stated rather than hidden.  A
--- debt is a promise to charge a barrel that was away when the water was drawn; with no
--- barrels left there is nobody to charge and no future in which there is.  The latch above
--- is what gives an unloaded chunk its chance to come back and pay first.
---
--- Returns true when the mirror was taken away, in which case the caller must not go on to
--- settle or sleep it: the object is off its square.
local function retireIfUnsupplied(ghost, supply, unresolved)
	local square = ghost:getSquare()
	if not square then return false end

	if supply > 0 then
		-- The ordinary case, and it builds no key at all.  A base with plumbing in it
		-- reaches this line once per mirror per lap for ever, and EP.any stops at the
		-- first entry rather than counting.
		if EP.any(unsupplied) then
			unsupplied[EP.key(square:getX(), square:getY(), square:getZ())] = nil
		end
		return false
	end

	-- A WALK THAT COULD NOT SEE THE WHOLE SCOPE KNOWS NOTHING, and must not be allowed to
	-- advance the latch on the strength of it.
	--
	-- `supply == 0` from a partial walk is the signature of a base whose barrels are simply
	-- in a chunk that has streamed out - which on a dedicated server happens to any base
	-- straddling a 64x64 cell boundary, and to every outbuilding, several times a session.
	-- Retiring there takes the mirror away, and while it is away the tap above it reads dry,
	-- drops out of the right-click menu and cannot be re-plumbed, because vanilla's own
	-- Plumb row is gated on the very flag that stranded it.
	--
	-- CLEARED rather than merely not advanced.  A latch that is held across an unresolved
	-- lap would retire on the first fully-resolved lap that happened to follow two blind
	-- ones, which is the same bug with extra steps.  The count has to start again from a
	-- walk that actually saw the building.
	if (unresolved or 0) > 0 then
		if EP.any(unsupplied) then
			unsupplied[EP.key(square:getX(), square:getY(), square:getZ())] = nil
		end
		return false
	end

	-- Adoption must have had a real look at this building first; see the note above.  The
	-- key is KEY_ADOPT_SEEN and not KEY_ADOPTED, because adoption now declines to stamp
	-- KEY_ADOPTED at all until the building has some plumbing - so gating on that one would
	-- mean a building that genuinely has none could never retire a mirror.  SEEN says
	-- "adoption resolved this scope and drew its conclusion", which is the thing this
	-- actually needs to wait for.  EP.spawnGhost stamps both at birth.
	local gdata = ghost:getModData()
	if gdata[EP.KEY_ADOPT_SEEN] ~= true and gdata[EP.KEY_ADOPTED] ~= true then return false end

	local key = EP.key(square:getX(), square:getY(), square:getZ())
	local since = unsupplied[key]
	if not since then
		unsupplied[key] = {
			lap = EP.maintenanceLaps,
			-- nil on a machine with no clock, which is every suite but one.  The seconds
			-- test then simply does not apply and the laps decide alone.
			ms = getTimeInMillis and getTimeInMillis() or nil,
		}
		return false
	end

	if EP.maintenanceLaps - since.lap < RETIRE_LAPS then return false end
	if since.ms and getTimeInMillis
		and (getTimeInMillis() - since.ms) < RETIRE_SECONDS * 1000 then return false end

	-- EP.ghostDebt, not a raw read: a mirror owing two liquids at once writes a TABLE, and
	-- `type(debt) == "number"` reported that as nothing owed - so the one line that says
	-- water was destroyed said nothing at all in the case where the most was destroyed.
	local debt = EP.ghostDebt(ghost)
	EP.log(("nothing is plumbed in above %d,%d,%d any more; removing the mirror%s"):format(
		square:getX(), square:getY(), square:getZ(),
		debt > EP.EPS
			and (" (%.2f owed, and nothing left to charge it to)"):format(debt) or ""))

	forgetGhost(ghost)
	return true
end

--- Decide whether this fixture should have a ghost, and make that true.
---
--- Nothing is done to the fixture itself, here or anywhere in this mod.  No
--- component, no flag, no modData.  Plumbing it remains vanilla's Plumb action
--- setting vanilla's usesExternalWaterSource, and all this does is make sure
--- there is something for vanilla to find when it looks - which is also why
--- uninstalling is clean: the ghosts go, and every fixture is left in a state the
--- game already has a meaning for, namely one whose barrel was taken away.
--- Say why a fixture was passed over.  Only assembled when Debug is on, because
--- the point of it is a log line naming the exact gate rather than a shrug.
local function refuse(fx, fy, fz, reason)
	-- GATED HERE TOO, because the comment above was only half true.  The `reason` is
	-- assembled behind EP.debugging() at the call site, but this `:format` ran whatever the
	-- option said -- EP.log checks it *after* Lua has already built the argument.  One
	-- string per unserved fixture per attempt, thrown away, on a path that used to run once
	-- per fixture per lap for ever.  plans/tick-path-audit.md Finding D is the family.
	if not EP.debugging() then return end
	EP.log(("no ghost for the fixture at %d,%d,%d: %s"):format(fx, fy, fz, reason))
end

--- `mayDiscover` says whether this call is allowed to go and LOOK for a collector nobody
--- has mentioned, which is `discover()` and a sweep of up to 5,625 squares.
---
--- TRUE on every path where a player did something and is waiting for the answer: a
--- right-click, a placement, a plumb, a generator being pulled.  FALSE from the maintenance
--- cursor, which is the background loop, and where it was running the sweep once per
--- unserved fixture per lap, for ever.
---
--- What that gives up, exactly: a collector that ONLY the sweep could have found is picked
--- up on the next right-click, the next placement or the next chunk reload rather than
--- within a lap.  The set of such collectors is small and named -- vanilla's own Lua raises
--- OnObjectAdded for rain collectors and moveables in all three modes (seven sites; see
--- `RainCollectorBarrel.lua:27-29`, which says why it does it), so what is left is admin and
--- debug spawns, worldgen, and other mods that place an object without announcing it.
---
--- Defaulted to true, so a caller that has not thought about it gets the old behaviour and
--- only the cursor is quiet.
local function serviceFixture(fixture, mayDiscover)
	local square = fixture:getSquare()
	if not square then return end

	-- Before every gate below, because none of them is about this.  A fixture that is
	-- refused a mirror for want of a room still has a plumb flag, and if this side and the
	-- player's side disagree about it the disagreement should not depend on whether the
	-- fixture happened to qualify for water this lap.  See the foot of this file.
	reconcilePipedFlag(fixture)

	local fx, fy, fz = square:getX(), square:getY(), square:getZ()
	local ghost = ghostFor(fx, fy, fz)

	-- isInARoom() is vanilla's own gate on offering Plumb at all, and a fixture
	-- outside one cannot use a ghost even if it had it.  Worth naming separately
	-- from the rest: below ground it is always false and always will be, because
	-- getIsoWorldRegion() returns null on its first line when z < 0, so a
	-- player-dug basement can never be plumbed by vanilla or by this.
	-- A ROOM, OR AN ENCLOSED ROOFED REGION, WHICH IS WHAT A SERVER HAS INSTEAD.
	--
	-- isInARoom() alone is a singleplayer answer.  The rooms of a player-built structure are
	-- synthesised by clientProcessBuildings, which IsoRegions.update calls inside
	-- `if (!GameServer.server)` - so on a dedicated server, and on the child process a co-op
	-- host spawns, a player base is never in a room and this refused for ever.  The same
	-- base plumbed perfectly in singleplayer, which is precisely the mode difference this
	-- was reported as: "works for me, not on the server".
	--
	-- EP.buildingRegionAt asks the region graph, which the server does have, using vanilla's
	-- own enclosed-and-roofed test.  See the long note there.
	--
	-- AND IT NO LONGER DESTROYS ANYTHING ON THE WAY PAST.  forgetGhost stood in the refusal
	-- branch, so on a dedicated server every service of a player-base fixture actively
	-- removed the mirror it was being asked to update - which is why right-clicking it again
	-- never helped, and could not have.  A mirror is only taken away when the fixture is
	-- genuinely gone or genuinely unservable, and "this side cannot see rooms" is neither.
	--
	-- ASKED THROUGH EP.canServeHere, which is the same call the client's three menu
	-- gates make.  It used to be written out here and written out SHORT on the client -
	-- a bare isInARoom() - so a fixture in a player-built structure got a mirror from
	-- this side and no Plumb row, no liquid row and no stand-in from the other.  One
	-- predicate, or it happens again.
	if not EP.canServeHere(fx, fy, fz) then
		refuse(fx, fy, fz, fz < 0
			and "not in a room or an enclosed region, and z < 0 - below ground needs a map RoomDef"
			or "not in a room or an enclosed roofed region")
		return
	end

	-- The seat is checked on every pass, before anything is decided about water.
	-- It should never have been lost, and if it has been then this fixture is being
	-- served by whatever is standing behind the mirror - which is the one failure
	-- this design cannot detect from its own books.
	if ghost then reseat(ghost) end

	-- The one path that pays for discover(), and the only one: this is where it is
	-- being decided whether a fixture should have a mirror at all, so a building
	-- that has just gained its first barrel has to be looked at rather than
	-- remembered.  Every other caller settles an existing mirror and takes the
	-- registry's word for it.
	--
	-- Asked for the fixture's OWN liquid, which is water unless a player has chosen
	-- otherwise.  A fixture set to a liquid the building has none of gets an empty
	-- group and a sleeping mirror, which is the situation stated accurately: the tap
	-- reads dry, Plumb is still offered, and it wakes by itself the day somebody
	-- fills a barrel with the right thing.
	-- The summary comes out of the same walk, per Q13.  This is one of the two paths that
	-- question names by hand: it is reached from every right-click and every placement, and
	-- it was building the group's totals twice.
	local group, groupSummary, spoken, needPump
	if mayDiscover == false then
		group, groupSummary, spoken, needPump =
			supplyGroup(fx, fy, fz, EP.fixtureFluidType(fixture))
	else
		group, groupSummary, spoken, needPump =
			groupOrDiscover(fx, fy, fz, EP.fixtureFluidType(fixture))
	end

	if #group == 0 then
		-- Guarded, because EP.count walks the whole collector registry and this is
		-- reached once per unsupplied fixture per sweep.  refuse() calls EP.log,
		-- which checks the option - but Lua builds the argument first, so the count
		-- was being paid for on every pass and thrown away.
		-- SAY WHICH SCOPE ACTUALLY ANSWERED, because the old line did not and a player
		-- pasted it into a bug report that then took a REDATA dig to interpret.  It printed
		-- "no building, using reach" off square:getBuilding(), which is one of the three
		-- inputs and not the decision - so a fixture scoped perfectly well by its structure
		-- reported that it was using a tape measure.  These are the same two answers
		-- walkBegin works from, read the same way.
		if EP.debugging() then
			local by = {}
			if square:getBuilding() then by[#by + 1] = "its building" end
			if EP.regionsAt(fx, fy, fz) then by[#by + 1] = "its structure" end
			-- AND NAME THE PUMP WHERE IT IS THE ANSWER, because it usually is and nothing
			-- on screen can say so.  A barrel at or below the tap needs a generator reaching
			-- ITS square, and haveElectricity refuses an OUTDOOR square outright when the
			-- server has AllowExteriorGenerator turned off - so a barrel against a wall or on
			-- a roof can never be a pump there, however close the generator is.
			refuse(fx, fy, fz, ("no collector in scope (%d known, scoped by %s)%s"):format(
				EP.count(sources),
				#by > 0 and table.concat(by, " and ") or "reach alone - no building, no structure",
				(needPump or 0) > 0
					and ((" - %d plumbed in and in scope but neither above the tap nor pumped"
						.. " (a generator must reach the BARREL's own square; an outdoor square"
						.. " never counts with AllowExteriorGenerator off)"):format(needPump))
					or ""))
		end
		-- Nothing in reach right now.  Put the mirror to sleep rather than destroy
		-- it: the usual reason to be here is a generator that stopped, and that is a
		-- state that reverses in a second - tearing the object down would mean
		-- rebuilding and re-transmitting one per fixture every time somebody cycled
		-- a generator.  A sleeping mirror wakes by itself the moment a group turns
		-- up again, because being awake is not a flag, it is having something to be
		-- a copy of.
		if ghost then
			EP.sleepGhost(ghost, spoken > 0)
		elseif (spoken or 0) > 0 then
			-- NO MIRROR, AND THE TAP NEXT DOOR HAS ONE.
			--
			-- The building is plumbed - `spoken` says so - and this fixture is simply set to a
			-- liquid it has none of.  Leaving its square empty is not neutral: vanilla's search
			-- falls through to the eight neighbours and hands the fixture ANOTHER FIXTURE'S
			-- mirror, because nothing in that search knows which fixture a source belongs to.
			-- BR-LGEP-021, and the direction that matters is a dry WATER tap beside a petrol
			-- one.  The account is on EP.defendSeat.
			--
			-- THE ENGINE IS ASKED, not guessed at, and only when the building has plumbing: one
			-- FindExternalWaterSource for a fixture that has just been refused a group, which is
			-- nine grid lookups against the several hundred squares the refusal itself cost.
			--
			-- ONLY AGAINST ONE OF OUR OWN.  A real rain barrel standing in the nine squares
			-- above a sink is vanilla's own plumbing and not ours to veto - the same rule
			-- EP.sleepGhost's step-aside keeps, from the other side.
			if EP.poachedBy(fixture, nil) then
				rememberGhost(EP.spawnSeatGhost(fx, fy, fz))
			end
		end

		return
	end


	if not ghost then
		rememberGhost(EP.spawnGhost(fx, fy, fz, group))
		return
	end

	-- Settled here and now, completely, so anything the cursor had half-assembled for this
	-- mirror is out of date the moment this returns.  See EP.abandonWalkFor: left alone it
	-- would land a few ticks later and write an older total over this one, which reads to a
	-- player as a tap that updated and then went back.
	--
	-- Reached through the EP table because the cursor is written far below this.
	if EP.abandonWalkFor then EP.abandonWalkFor(ghost) end

	EP.settleGhost(ghost, group, groupSummary)
end

--------------------------------------------------------------------------------
-- the sweep
--------------------------------------------------------------------------------

--- Once a minute, because that is the coarsest thing that spends water:
--- ClothingWasherLogic.update() calls useFluid(1 * elapsedMinutes).  Drinking and
--- filling settle themselves the instant they happen, through
--- OnWaterAmountChange; this pass is for the two things that raise nothing.
---
--- The first is rain.  FluidContainerUpdateSystem.updateEntity puts it into the
--- barrel by calling addFluid on the *component*, not on the IsoObject, so no
--- event is raised anywhere and the only way to see it is to look.
---
--- The second is the world changing shape - a barrel built, a sink installed, a
--- collector dismantled, a chunk loaded with somebody else's ghosts on it.
--- Switched off mid-save.
---
--- Ghosts are real objects sitting in the world, so turning the option off cannot
--- simply mean "stop running" - that would leave every plumbed fixture drawing on
--- a mirror nothing is keeping honest any more.  Each one is settled and taken
--- away, which puts its fixture back into a state vanilla already has a meaning
--- for: plumbed, with nothing above it, exactly like one whose barrel was
--- dismantled.
---
--- Only what is loaded can be reached, so this keeps working through the option
--- being off: LoadGridsquare goes on filing ghosts as chunks arrive, and each
--- pass clears whatever has turned up since.
--- Take every mirror out of the world.
---
--- THIS IS "PREPARE FOR REMOVAL", and it is the only moment the mod can make itself
--- safe to delete. A mirror is a real object saved with the chunk, and IsoObject.save
--- writes its sprite by NUMERIC ID (IsoObject.java:1317) - an id belonging to a sprite
--- this mod registers from Lua. A load without the mod misses `intMap` and gets null
--- back (IsoSprite.java:185); IsoObject.load only falls back to the blank sprite when
--- the id was -1, and this one is not. So the object returns with a NULL SPRITE, still
--- carrying a FluidContainer, still directly above the tap - which is exactly where
--- vanilla's FindExternalWaterSource looks. The tap is then plumbed to a barrel nothing
--- will ever fill: a dry sink, for ever, with no error. That is what deleting the mod
--- did to two players' bases (reported 2026-08-16), and nothing can be done about it
--- from a save the mod is no longer part of. IsoObject has no dontSave, so the switch
--- is the only chance there is.
---
--- A SQUARE THIS CANNOT REACH IS NOT A PROBLEM, which is worth writing down because it
--- looks like one. `cell:getGridSquare` answers nil for a chunk that has streamed out,
--- and this drops the address and walks on - so a base whose far end is unloaded is
--- only half cleared by the pass that runs when the switch moves. It heals itself: a
--- chunk arriving raises LoadGridsquare, `notice` files any mirror on it with no Enabled
--- gate of its own, and the caller's `EP.any(ghosts)` test then wakes this again. Proved
--- by lgep_spec_switchoff, and proved the other way too - an attempt to "fix" it by
--- keeping unreachable addresses changed nothing except to put a registry walk on every
--- tick of a disabled mod.
---
--- Returns what it did, `removed, unplumbed`, for the Uninstall's report; the tick handler that
--- calls it on the switch ignores both.
local function teardown()
	local cell = getCell()
	local removed, unplumbed = 0, 0
	for key, pos in pairs(ghosts) do
		local square = cell:getGridSquare(pos.x, pos.y, pos.z)
		if not square then
			ghosts[key] = nil
			supplyChanged()
			repaired[key] = nil
			unsupplied[key] = nil
		else
			for _, ghost in ipairs(EP.ghostsOnSquare(square)) do
				EP.log("extended plumbing is off; removing a ghost")

				-- Read before it leaves the square, and acted on after: see EP.unplumbStranded.
				-- A fixture plumbed to a mirror reports the mirror's water and NOTHING ELSE it
				-- might have had - not the mains, not a toilet's reserve - so one left plumbed to
				-- a mirror that has gone is drier than an unplumbed one beside it.
				--
				-- ONLY HERE, and that is a deliberate line rather than an oversight.  A mirror
				-- taken away by retirement can come back: the engine re-finds a source on every
				-- read (checkExternalFluidSource, IsoObject.java:2626-2636), so a tap whose barrels
				-- were disconnected for a minute picks the new mirror up by itself and needs no
				-- wrench.  Unplumbing it there would cost the player that for nothing.  This is the
				-- switch, which is the one moment the mod is being packed up on purpose and there
				-- is nothing to come back to.
				local d = ghost:getModData()
				local fx, fy, fz = d[EP.KEY_FIX_X], d[EP.KEY_FIX_Y], d[EP.KEY_FIX_Z]

				forgetGhost(ghost)
				removed = removed + 1
				if EP.unplumbStranded(fx, fy, fz) then unplumbed = unplumbed + 1 end
			end
			ghosts[key] = nil
			supplyChanged()
			repaired[key] = nil
			unsupplied[key] = nil
		end
	end
	return removed, unplumbed
end

--------------------------------------------------------------------------------
-- the way out (CLAUDE.md section 6)
--------------------------------------------------------------------------------

--- THE SWITCH, PRESSED FROM THE DEBUG MENU, and made to happen now.
---
--- Everything the way out needs already existed and was measured: turning Enabled off runs
--- `teardown`, which takes every loaded mirror away and puts its tap back to unplumbed
--- (lgep_spec_switchoff, lgep_spec_teardown). What stood between a player and it was the
--- sandbox screen - which singleplayer cannot reach for an existing save without -debug, and
--- whose Apply does not refresh Lua even then (memory/sp-sandbox-options-need-debug) - and a
--- procedure that lived on the Workshop page. LGEE wrote its procedure on the page and in the
--- FAQ, in full, and four people still lost or rolled back a server (BR-LGEE-043).
---
--- WRITING THIS MOD'S OWN OPTION IS NOT THE RULE BEING BROKEN. "A mod never writes its own
--- sandbox option" bans the mod DECIDING. This is an admin pressing a button that says what it
--- will do (CLAUDE.md section 6).
---
--- Returns true when the option really moved, and the teardown's counts when it went off.
function EP.setModEnabled(on)
	if not EP.isAuthority() then return false end
	on = on and true or false

	local wrote = pcall(function()
		local option = getSandboxOptions():getOptionByName(EP.MOD_ID .. ".Enabled")
		if not option then error("no sandbox option " .. EP.MOD_ID .. ".Enabled") end
		if option.setValue then option:setValue(on) else option:asConfigOption():setValue(on) end
	end)
	if not wrote then
		print("[LGExtendedPlumbing] could not write the Enabled option; nothing was changed")
		return false
	end
	-- MAKE IT STICK. The SandboxVars snapshot is what a reload reads; a dedicated server
	-- rewrites its SandboxVars file at boot, so the value has to be in it; singleplayer writes
	-- map_sand.bin at its next save. The same two calls as LGEE's persistSandbox.
	pcall(function() getSandboxOptions():toLua() end)
	if isServer() and getServerName then
		pcall(function() getSandboxOptions():saveServerLuaFile(getServerName()) end)
	end

	local removed, unplumbed = 0, 0
	if on then
		supplyChanged()
		worldChanged()
	else
		-- The pack-up, now, rather than on whichever tick notices next.
		local ok, a, b = pcall(teardown)
		if ok then removed, unplumbed = a or 0, b or 0
		else EP.logFault("plumb-teardown", "ERROR tearing down: " .. tostring(a)) end
	end

	print(("[LGExtendedPlumbing] switched %s from the debug menu"):format(on and "ON" or "OFF"))
	return true, removed, unplumbed
end

--- Put everything back that can be put back from here, and say what is left and where.
---
--- Returns `{ removed, unplumbed, away, ax, ay, az }`. Never throws: an uninstall that fails
--- half way is worse than one that says what it managed.
---
--- WHAT CANNOT BE DONE FROM HERE, and is therefore REPORTED rather than implied done: a mirror
--- in a chunk nobody is standing near cannot be reached by anybody. `savedMirrors` knows where
--- they are. They go on their own as their chunks load while the mod is still installed and
--- switched off - `notice` files them with no Enabled gate and the disabled branch of the sweep
--- takes them (plans/lgep-uninstall-leaves-mirrors.md, measured) - so the report says where the
--- first one is, and that deleting the mod before then leaves those taps dry.
---
--- WHAT IS NOT TOUCHED, on purpose. Laid pipes stay in the save: they are rows in the global
--- store that vanilla never reads, they cost nothing with the mod gone, and they come back if
--- the mod is switched on again. A barrel's plumbed flag is the same. Neither harms a save that
--- no longer has the mod.
function EP.uninstallNow()
	if not EP.isAuthority() then return nil end
	local report = { removed = 0, unplumbed = 0, away = 0 }

	local ok, err = pcall(function()
		local _, removed, unplumbed = EP.setModEnabled(false)
		report.removed, report.unplumbed = removed or 0, unplumbed or 0

		local cell = getCell()
		for key in pairs(savedMirrors or {}) do
			local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			if not x then
				savedMirrors[key] = nil
			elseif cell:getGridSquare(x, y, z) then
				-- Loaded and not taken by the teardown, so there is no mirror there: an entry
				-- for one that went some way this mod did not see.
				savedMirrors[key] = nil
			else
				report.away = report.away + 1
				if not report.ax then report.ax, report.ay, report.az = x, y, z end
			end
		end
	end)
	if not ok then
		EP.logFault("plumb-uninstall", "ERROR putting everything back: " .. tostring(err))
		return nil
	end

	print(("[LGExtendedPlumbing] uninstall: %d mirror(s) taken away, %d tap(s) put back to"
		.. " unplumbed, up to %d mirror(s) in chunks that are not loaded"):format(
		report.removed, report.unplumbed, report.away))
	if report.ax then
		print(("[LGExtendedPlumbing] uninstall: visit %d,%d,%d with the mod still installed and"
			.. " the rest go on their own; deleting it before then leaves those taps dry"):format(
			report.ax, report.ay, report.az))
	end
	return report
end

--- Where the admin's two buttons arrive.
---
--- The client hides them behind isDebugEnabled(), and that hides the MENU. It does not protect
--- the world: a command is a packet. So the authority asks for itself. Singleplayer is the
--- player's own machine, and its player carries the default `user` role (Roles.java:477-478),
--- so a role test there would refuse the only person who can ask; on a server, admins only.
--- A refusal is printed, because a mod silently ignoring a command is the shape of a bug
--- report nobody can answer.
Events.OnClientCommand.Add(function(module, command, player, args)
	if module ~= EP.COMMAND_MODULE then return end
	if command ~= EP.CMD_ADMIN_ENABLE and command ~= EP.CMD_ADMIN_UNINSTALL then return end

	if isServer() then
		local level = player and player.getAccessLevel and tostring(player:getAccessLevel() or "") or ""
		if level:lower() ~= "admin" then
			local who = (player and player.getUsername and player:getUsername()) or "?"
			print(("[LGExtendedPlumbing] refused %s from %s: not an admin"):format(
				tostring(command), tostring(who)))
			return
		end
	end

	local result = { ok = true, action = command }
	if command == EP.CMD_ADMIN_ENABLE then
		local want = type(args) == "table" and args.on == true
		local moved, removed, unplumbed = EP.setModEnabled(want)
		result.ok, result.on = moved == true, want
		result.removed, result.unplumbed = removed or 0, unplumbed or 0
	else
		local report = EP.uninstallNow()
		if report then
			result.removed, result.unplumbed, result.away = report.removed, report.unplumbed, report.away
			result.ax, result.ay, result.az = report.ax, report.ay, report.az
		else
			result.ok = false
		end
	end

	if isServer() and player then
		sendServerCommand(player, EP.COMMAND_MODULE, EP.CMD_ADMIN_RESULT, result)
	elseif EP.onAdminResult then
		EP.onAdminResult(result)
	end
end)

--- CAN A BARREL'S CONTENTS HAVE MOVED WITHOUT ANYTHING SAYING SO?
---
--- The whole reason this mod had a once-a-minute pass is that one path moves water with
--- no event.  It is `FluidContainerUpdateSystem`, it is the only one, and it is gated:
---
---     if (ClimateManager.getInstance().getPrecipitationIntensity() > 0.0F
---         && fluidContainer.getGameEntity().isOutside()
---         && !fluidContainer.isMultiTileMoveable()
---         && fluidContainer.canPlayerEmpty()
---         && fluidContainer.getRainCatcher() > 0.0F)
---            fluidContainer.addFluid(waterType, rainAmount);   // on the COMPONENT
---
--- addFluid on the component raises nothing - every one of OnWaterAmountChange's twelve
--- call sites is on IsoObject or IsoWorldInventoryObject, never on a FluidContainer - so
--- rain really is invisible.  But when the intensity is zero, NO barrel anywhere gains a
--- drop, and there is nothing for a settle pass to find.
---
--- getPrecipitationIntensity() is `precipitationIntensity.finalValue`, a bare field read,
--- and ClimateManager.update() is called on a dedicated server too
--- (GameServer.java:2868), so this costs the same nothing in all three modes.
---
--- TWO EXACTNESS NOTES, both of which cost water if they are got wrong:
---
---   * SNOW FILLS BARRELS AS WELL AS RAIN.  The same block applies a snowModifier of
---     0.5 and goes on adding.  So isRaining() is the WRONG question - it would miss
---     every snowfall and let the ledger drift all winter - and the intensity is the
---     right one, because it is what the engine itself tests.
---   * A PETROL BARREL DRAINS SILENTLY WHATEVER THE WEATHER.  The first half of
---     updateEntity evaporates `1e-4 * rainCatcher / (dayLength * 24 / 60)` per tick
---     from any container whose primary fluid is Petrol.  So a building with fuel in a
---     barrel is always drifting and always has to be settled.
--- The cheap half of the question above, on its own.
---
--- A bare field read on a manager the dedicated server updates too, so it is affordable
--- EVERY TICK - which the full question is not, because its second half walks the collector
--- registry.  That split is what lets the tick handler notice rain starting without waiting
--- for a lap boundary: at backstop rate a lap is tens of seconds away, and a shower that
--- began in between would have gone unnoticed for all of it.
---
--- The petrol half deliberately does NOT get the same treatment.  It is the expensive half,
--- and a barrel of petrol seeping away is exactly the kind of slow, unattended change the
--- backstop rate is adequate for.  Rain is the one that arrives suddenly.
--- ASKED THROUGH getClimateManager(), WHICH IS THE ONLY ACCESSOR LUA ACTUALLY HAS.
---
--- This read `ClimateManager.getInstance()`, transcribed straight out of the Java in
--- FluidContainerUpdateSystem, and that is a Java call path rather than a Lua one.  The
--- singleton is exposed to Lua as a global function - LuaManager.java:11533 - and no
--- vanilla Lua file calls getInstance() anywhere; every one of them uses
--- getClimateManager().  The class itself IS visible (the debug UIs read constants off
--- it), which is exactly why this failed quietly instead of loudly.
---
--- And it failed in the worst possible way: the guard around it returned false whenever it
--- could not resolve the manager, so "I cannot tell" was reported as "it is not raining".
--- Rain then never raised the settle flag, and a barrel filling in a downpour was invisible
--- at the tap until somebody drank from it and forced a settle by another route.
---
--- THE STUB IS WHY NO SUITE CAUGHT IT.  lgep_stub.lua defines a ClimateManager global with
--- a getInstance on it, because it was written from the same Java.  A harness that models
--- an API the game does not expose will confirm anything.  It now provides
--- getClimateManager() as the game does, and keeps the old global so a mistake in the
--- other direction would be caught too.
---
--- Both spellings are tried regardless.  The cost is one nil check on a path that is
--- already only reached once a tick, and the failure this is repairing was caused by
--- being certain about an accessor.
local function precipitating()
	local climate = getClimateManager and getClimateManager() or nil
	if not climate and ClimateManager and ClimateManager.getInstance then
		climate = ClimateManager.getInstance()
	end
	if not climate or not climate.getPrecipitationIntensity then return false end
	local intensity = climate:getPrecipitationIntensity()
	return type(intensity) == "number" and intensity > 0
end

local function silentDriftPossible()
	if precipitating() then return true, "precipitation" end

	-- Only asked when nothing is falling, and only a modData read per known collector -
	-- a base has a dozen.  KEY_HOLDS is written by EP.rememberBarrelFluid for any liquid
	-- that is not water, so a petrol barrel is already labelled.
	for _, pos in pairs(sources) do
		local source = EP.sourceAt(pos.x, pos.y, pos.z)
		if source and source:hasModData() and source:getModData()[EP.KEY_HOLDS] == "Petrol" then
			return true, "a petrol barrel"
		end
	end

	return false
end

--- THERE IS NO HOUSEKEEPING SLICE ANY MORE, because the whole pass is a slice now.
---
--- What stood here was HOUSEKEEPING_PASSES = 6: the repairs below are for states a healthy
--- save never reaches, so a sixth of the mirrors were inspected per ten-minute pass and
--- the rest were only settled.  That was a rotation bolted onto a batch, to stop the batch
--- being enormous.
---
--- The batch is gone (see the maintenance cursor at the foot of this file) and the
--- rotation went with it: the cursor visits a handful of mirrors per tick and goes round
--- for ever, so EVERY visit can afford to be a full inspection.  That is simpler and it is
--- also stricter - a fault is now found on the cursor's next lap, about a second, rather
--- than within a game hour.
---
--- One mirror square, inspected and settled.
---
--- Lifted out of sweep() unchanged so that the cursor and a whole-pass sweep drive the
--- IDENTICAL code.  Two copies of this, one incremental and one batch, is exactly the
--- drift that would put a repair in one path and not the other, and it would show up as a
--- fault that heals when you happen to trigger the other one.
---
--- `repairing` is kept as a parameter rather than deleted even though the cursor always
--- passes true, because sweep() still passes false for a mirror it has already inspected
--- this session - see `repaired`.
local function settleMirrorSquare(entry, repairing, drift, cell, defer)
	local key, pos = entry.key, entry
	repaired[key] = true

	local square = cell:getGridSquare(pos.x, pos.y, pos.z)
	if not square then
		-- Chunk unloaded.  The ghost is still saved on it; forget the address
		-- and pick it up again from LoadGridsquare.
		--
		-- The retirement latch goes with it, deliberately.  A mirror whose own chunk has
		-- streamed out has not been observed at all, so what it was seen to be standing
		-- over is no longer something this session can claim - and starting the count
		-- again on the way back in is what stops a base at the edge of the loaded world
		-- from accumulating a verdict across the gaps.
		ghosts[key] = nil
		supplyChanged()
		repaired[key] = nil
		unsupplied[key] = nil
		return
	end

	local found = EP.ghostsOnSquare(square)
	if #found == 0 then
		ghosts[key] = nil
		supplyChanged()
		repaired[key] = nil
		unsupplied[key] = nil
	end

	for i, ghost in ipairs(found) do
		local data = ghost:getModData()
		local fx, fy, fz = data[EP.KEY_FIX_X], data[EP.KEY_FIX_Y], data[EP.KEY_FIX_Z]
		-- A ghost with no fixture address is one this version did not
		-- write.  It cannot be matched to anything, so it is cleared and
		-- the fixture below gets a fresh one on the pass through the
		-- fixture list a moment later.
		local owner = (repairing and fx and fy and fz)
			and cell:getGridSquare(fx, fy, fz) or nil

		-- A MIRROR THAT OWES SOMETHING IS A MIRROR WHOSE BOOKS ARE NOT SQUARE,
		-- so it settles whatever the weather is doing.
		--
		-- A debt is what is left when a draw could not be charged - a member's
		-- chunk was away - and it is a promise to keep trying rather than a loss.
		-- Gating it behind the world-changed flag would mean a debt sitting unpaid
		-- until something unrelated happened, which is exactly the kind of "it
		-- fixes itself when you look at it" fault this mod has been bitten by
		-- before.  One table read per mirror is worth not having that.
		local owes = EP.ghostDebt(ghost) > EP.EPS
		-- SETTLED EVERY TIME THE CURSOR REACHES IT, asking nobody's permission.
		--
		-- This was `drift or owes`: settle only when the weather or a flag said water could
		-- have moved unannounced.  That gate earned its place when a pass was a ten-minute
		-- batch over every mirror in the world and skipping it was the entire saving.  It
		-- does not earn it now.  The cursor visits one mirror at a bounded cost, so what the
		-- gate buys is no longer speed - it is a class of bug where the answer was stale and
		-- nothing went to look.
		--
		-- It produced exactly that bug: precipitating() reached the climate through an
		-- accessor Lua does not have, its guard reported "cannot tell" as "not raining", and
		-- a barrel filling in a downpour stayed invisible at the tap until somebody drank
		-- from it and forced a settle by another route.  The accessor is fixed; the gate
		-- that turned a wrong answer into a silent one is gone as well, because the next
		-- wrong answer will not announce itself either.
		--
		-- Adding work to the QUEUE is not what costs - adding work to a TICK is.  Settling
		-- unconditionally makes the queue longer, not the frame heavier, and a longer queue
		-- is precisely what this design absorbs.
		local settling = true

		-- `drift` and `owes` are still computed above and still mean what they meant; they
		-- are no longer permission to look.  drift decides how FAST the cursor laps, which
		-- is a pacing question rather than a correctness one.
		local _ = drift or owes

		if not repairing then
			-- Nothing is inspected and nothing is repaired.  The settle still runs
			-- when something can have moved water with no event, which is the half
			-- that has to be prompt.
			if settling then
				if defer then defer(ghost) else EP.settleOrSleep(ghost) end
			end
		elseif not (fx and fy and fz) then
			EP.log("ghost with no fixture address; removing it")
			forgetGhost(ghost)
		elseif pos.x ~= fx or pos.y ~= fy or pos.z ~= fz + 1 then
			-- Standing somewhere a mirror is no longer allowed to stand.
			--
			-- Older versions hunted the nine squares for a free one, so a save
			-- from before the centre-square rule has mirrors on neighbours.
			-- They cannot simply be left: a neighbour mirror still answers
			-- vanilla's search for every OTHER fixture whose nine squares reach
			-- it, so it would go on serving water nobody is keeping honest once
			-- its own fixture has a proper one.
			--
			-- Settled and taken away.  The fixture stage gives the fixture a new one
			-- on its centre square when the cursor reaches it.
			EP.log("mirror off its centre square; removing it")
			forgetGhost(ghost)
		elseif i > 1 then
			-- Two ghosts on one square is a state nothing should produce.
			-- Settle the spare's account and take it out rather than leave
			-- an unowned copy of a barrel standing in the world.
			EP.log("two ghosts on one square; removing the spare")
			forgetGhost(ghost)
		elseif owner and not EP.fixtureOnSquare(owner) then
			EP.log("fixture gone; removing its ghost")
			forgetGhost(ghost)
		else
			-- The sprite.
			--
			-- A mirror loses ours to an anonymous one every time it goes through
			-- IsoObject.load - see EP.fitGhostSprite for why - and on a dedicated
			-- server nothing else ever puts it back: EP.dressGhost is reached from
			-- LoadGridsquare and OnObjectAdded in the CLIENT file, which a
			-- dedicated server does not load.  One pointer comparison per mirror,
			-- and a no-op for every mirror this session made.
			EP.fitGhostSprite(ghost)

			-- The seat.  serviceFixture checks it too, but a settled base never
			-- reaches serviceFixture: the fixture stage skips anything that already
			-- has a mirror, so without this a mirror that lost its place would keep
			-- it for the rest of the save, and the fixture would be quietly served
			-- by whatever is standing behind it.
			reseat(ghost)

			-- THE BARRELS THAT WERE ALREADY SUPPLYING THIS FIXTURE KEEP SUPPLYING IT.
			--
			-- Here, and on THIS branch only, which is the branch meaning "a healthy
			-- mirror, on its own centre square, whose fixture is still standing".  Every
			-- other branch above removes the mirror for one reason or another, and a
			-- mirror about to be removed is not evidence of anything.
			--
			-- Before the settle below rather than after, so the mirror is filled from
			-- the group it has just re-acquired instead of being put to sleep and
			-- waking a lap later - which would be a tap that reads dry for a second on
			-- the first load after the update, the exact thing this exists to avoid.
			--
			-- A no-op on all but the first sight of a mirror written by an older build:
			-- it returns on its own marker, and EP.spawnGhost stamps that at birth.
			EP.adoptLegacyPlumbing(ghost)

			-- Settle it against whatever its fixture can reach, or put it
			-- to sleep if that is nothing.
			--
			-- There is no "and then re-decide" branch here any more, and
			-- there were two.  One re-serviced a fixture whose collector had
			-- been dismantled; a dismantled barrel just drops out of the sum
			-- now, so there is nothing to react to.  The other re-serviced a
			-- mirror that had run dry, in case some other barrel in the
			-- building still had water - which is exactly what the group
			-- already is.  Both were the old design asking "which barrel"
			-- over and over, and the question is gone.
			--
			-- Only when something can have moved water without saying so, or
			-- when this mirror still owes for a draw it could not charge.  With
			-- nothing falling, no petrol about and nothing owed, this mirror was
			-- settled the instant its last draw happened and re-settling it would
			-- rebuild a container to the number it already holds.
			if settling then
				if defer then defer(ghost) else EP.settleOrSleep(ghost) end
			end
		end
	end
end

--- One fixture, given a mirror if it has none and there is anything to fill it from.
---
--- Lifted out of sweep() for the same reason as the mirror body above.  The three gates
--- that keep this from being a volume scan are unchanged and are what make it cheap enough
--- to run continuously:
---
---   * a fixture that already has its mirror is one lookup and then skipped - which is
---     every fixture, every lap, once a base has settled
---   * a fixture whose pool holds no collector at all is skipped without asking anything
---     further, so a town of plumbed houses and no rain barrels costs one table read apiece
---   * only what is loaded is in the registry in the first place
---
--- The second gate is what keeps discover() off this path.  groupOrDiscover falls through
--- to it when a fixture has no supply, and discover sweeps a whole building - measured at
--- 2787 square lookups for a two-storey house.  Reaching it once per unsupplied fixture per
--- lap across a loaded town is exactly the cost that pass was deleted for.
--- RETURNS WHETHER IT DID THE EXPENSIVE THING, which the cursor needs and a batch did not.
---
--- The three gates below mean this entry is nearly always one table read and a skip - and
--- then, for the one fixture in a base that has just lost its mirror, it is a whole
--- supplyGroup and a mirror spawned.  A cursor that charged every fixture the same price
--- would let a tick take eight of the expensive ones: measured on a base of 200 barrels, a
--- peak tick of 16,187 operations with five mirrors spawned in it, against a mean of 105.
---
--- A static weight cannot price this, because which branch is taken is a property of the
--- world and not of the stage.  So the caller is told, and charges the full purse after the
--- fact.  That is the general shape for anything whose cost is data-dependent: bound it by
--- charging for what happened, not by guessing beforehand.
local function serviceFixtureEntry(entry, cell)
	-- THE REGISTRY IS ASKED FIRST, AND IT ANSWERS FOR ALMOST EVERY FIXTURE.
	--
	-- This stage exists to find a fixture that has not got a mirror.  In a settled base that
	-- is none of them, every lap, for ever - and it was paying THREE Java walks apiece to
	-- establish it: a grid lookup for the fixture's own square, an object walk to confirm
	-- the fixture is still there, then ghostFor, which is another grid lookup at z+1 and
	-- another object walk.  Across a sixty-four house town that is a thousand square walks a
	-- lap to answer "still fine" a thousand times.
	--
	-- `ghosts` already knows.  It is keyed by mirror square, a mirror lives at the fixture's
	-- own centre square plus one, and the ghost stage removes any mirror standing anywhere
	-- else.  So one table read settles it for the overwhelming majority.
	--
	-- Safe against a stale registry in both directions, and self-correcting within a lap:
	-- a key that says yes when the square is empty is deleted by the ghost stage the moment
	-- it walks it (`if #found == 0`), and a fixture that has been taken away has its mirror
	-- removed there too - which clears the key and lets this stage look properly again.
	-- Nothing here needs to be right immediately; it needs to stop being wrong on its own.
	if ghosts[EP.key(entry.x, entry.y, entry.z + 1)] then return false end

	local square = cell:getGridSquare(entry.x, entry.y, entry.z)
	if square == nil then
		-- The chunk is closed. The address stays: LoadGridsquare files it again
		-- on the way back in, and forgetting it here would only mean re-deriving
		-- its pool later, which is the expensive half.
		return false
	end

	if not EP.fixtureOnSquare(square) then
		forgetFixture(entry.key)
		return false
	end

	if ghostFor(entry.x, entry.y, entry.z) then return false end

	local supplied
	if entry.pool then
		local pool = srcPool[entry.pool]
		supplied = pool ~= nil and EP.any(pool)
	else
		-- No building to pool by - a player structure on open ground, which on a dedicated
		-- server is every player base.
		--
		-- THIS USED TO BE `EP.any(sources)`, AND IT WAS THE MOD'S WORST LINE.  It asked
		-- whether there was a collector ANYWHERE in the loaded world, so a sink in a shack
		-- in Louisville was "supplied" because somebody had a barrel in Rosewood - and each
		-- one then ran serviceFixtureAt -> groupOrDiscover -> discover(), a 5,625-square
		-- sweep, and spent the whole purse doing it.  One fixture per tick, for ever.
		-- Measured at 525 ms/s with 2,000 unserved fixtures and ONE barrel; forty barrels
		-- cost the same as one, because the count was never what it turned on.
		--
		-- BEHAVIOUR-IDENTICAL, and this is why: supplyGroup's own locality bound is a box
		-- of Reach around the fixture - see the note at walkBegin, "a collector outside this
		-- box cannot pass servesBuilding, so it is never asked".  A collector outside that
		-- box can never join the group, so declining to start when there is none inside it
		-- removes no outcome that was ever reachable.
		--
		-- sourceNear over-approximates in x and y and ignores z entirely, so it errs only
		-- towards doing the work.  See its note.
		supplied = sourceNear(entry.x, entry.y,
			reachForStructure(entry.x, entry.y, entry.z))
	end

	-- OR A SUPPLIED PIPE NETWORK, and without this a piped house with no barrels of its own
	-- is never serviced by this loop at all: its pool is empty and no collector stands
	-- within Reach, so both answers above are no - for ever.  Only a right-click would heal
	-- it, which is the "it works when I look at it" shape of fault.  Asked only when both
	-- answers above were no, and only in a world with pipes laid.
	if not supplied and EP.pipeFixtureSupplied then
		supplied = EP.pipeFixtureSupplied(entry.x, entry.y, entry.z)
	end
	if not supplied then return false end

	-- FALSE: this is the background cursor, and it must not run discover()'s sweep once per
	-- unserved fixture per lap.  See the note on serviceFixture.
	serviceFixtureAt(entry.x, entry.y, entry.z, false)

	-- REMEMBER WHAT THAT COST BOUGHT.  `entry` is the flattened copy, so the answer is
	-- written back onto the registry's own table -- one lookup on a key that is already in
	-- hand.  If a mirror is standing afterwards the attempt worked and nothing is
	-- remembered; the ghost test in enterStage keeps it out of the queue from now on, and
	-- clearing the mark means that if the mirror is ever removed this fixture is considered
	-- again immediately.
	local registered = fixtures[entry.key]
	if registered then
		if ghosts[EP.key(entry.x, entry.y, entry.z + 1)] then
			registered.triedAt = nil
		else
			registered.triedAt = supplyVersion
		end
	end
	return true
end

--- Drop a listed fixture's address.
---
--- No pool to unfile it from and no worldChanged(), for the reasons on the `fed` registry
--- above: nothing reads a listed object, so nothing is left describing it.
local function forgetFed(key)
	fed[key] = nil
end

--- FILL ONE LISTED FIXTURE OUT OF ITS BUILDING'S BARRELS.
---
--- The whole of the feature, and it is deliberately not a ghost.  A mirror works by being
--- the thing FindExternalWaterSource returns, which only happens for an object the engine
--- routes through checkExternalFluidSource - and it only routes an object whose
--- usesExternalWaterSource is set.  A water dispenser's water is its OWN container: that is
--- what the Take Bottle menu reads, what a bottle fills from, and what a player sees.
--- Pointing it at a mirror would replace a fifteen litre cooler with a readout of the whole
--- building, and would mean setting a saved engine flag on somebody's furniture.  So the
--- water is really moved, and the object is left exactly the kind of object it was.
---
--- CLEAN WATER GOES IN, WHATEVER CAME OUT, and that is the same substitution the engine
--- makes rather than a new rule.  IsoObject.createSampleAndPurifyWater - the whole of a
--- plumbed tap's fluid path - rewrites TaintedWater to Water per instance on the way
--- through, so a tap fed tainted barrels pours clean water today.  A dispenser fed the same
--- barrels does the same thing.  The barrels are charged in whatever they are actually
--- holding, because EP.drawFromGroup goes through IsoObject.useFluid, which takes a
--- proportional bite out of each member's real blend.  See the long note on
--- EP.canonicalFluidType: this mod has one substitution and this is it.
---
--- WATER AND ONLY WATER, so the group is asked for EP.FLUID_DEFAULT.  A dispenser is not
--- offered a Plumbed liquid menu and has no KEY_FLUID, so there is nothing to read: what it
--- gets is what it would get from a tap nobody had touched.  A whiskey barrel in the same
--- building is in a different group and is not asked.
---
--- THE ORDER IS ADD, THEN CHARGE, THEN CLAW BACK, and it is the only order in which every
--- way this can go wrong is recoverable.
---
--- Charging first reads better and loses water: EP.drawFromGroup returns what it MANAGED to
--- take, which is less than asked whenever a member's chunk went out mid-draw, and those
--- litres are then in nothing at all - they left the barrels and the container has not had
--- them yet.  The mirror path can carry that as a debt because a mirror has modData and a
--- settle that comes round again; a dispenser is somebody's furniture and this mod may not
--- start writing bookkeeping keys onto it.
---
--- Adding first puts the water somewhere it can be taken back OUT of.  So the container is
--- filled, the group is charged for exactly what went in, and anything the group could not
--- pay for is removed again.  The failure mode is a dispenser that ends up slightly less
--- full than it looked for the width of one call, which nobody can observe, instead of
--- water that no longer exists anywhere.
---
--- THE INPUT LOCK HAS TO COME OFF, and forgetting it would have been a silent no-op rather
--- than an error.  The dispenser's entity script sets `InputLocked = true` (it is a sealed
--- bottle, not something you pour into), and FluidContainer.canAddFluid opens with
--- `!this.inputLocked && this.canPlayerEmpty` (:900) - so addFluid would simply do nothing
--- and return.  Saved and restored either side, exactly as EP.fillFromGroup does it for a
--- mirror, so the object is handed back in the state its script asked for.
---
--- Returns true when it did enough work to be worth charging the cursor a full step for -
--- which is any call that reached the group walk, the same rule serviceFixtureEntry uses.
local function topUpFedEntry(entry, cell)
	local square = cell:getGridSquare(entry.x, entry.y, entry.z)
	-- The chunk is closed.  The address stays: LoadGridsquare files it again on the way
	-- back in, and a dispenser in an unloaded chunk is not one anybody is drinking from.
	if square == nil then return false end

	-- PLUMBING IS AN ACT HERE TOO, AND THE LIST IS NOT THE ACT.
	--
	-- The sandbox list says what KIND of thing may be plumbed into the supply.  It does not
	-- say that any particular one has been - and the difference is the same one the note on
	-- DEFAULTS in LGEPCore spends a page on for barrels, arriving from the other side.
	--
	-- An office block holds a dozen dispensers.  Filled on sight, all twelve would quietly
	-- drink a hundred and eighty litres out of a base's barrels the first time somebody
	-- walked through, with nothing to click and no state to inspect - which is exactly the
	-- over-application "a barrel joins the supply by standing in the right place" was.
	--
	-- So a listed fixture is inert until somebody takes a wrench to it, through the same
	-- action, the same command and the same EP.canPlumbHere gate a collector uses.
	--
	-- ASKED OF THE SQUARE, and the long note on EP.KEY_FED says why at length: the engine
	-- DESTROYS the dispenser and builds another every time a bottle comes off or goes on
	-- (ISAddTakeDispenserBottle:complete), so a flag on the object would be thrown away by
	-- an ordinary act of play and a player would have to re-plumb after every bottle change.
	if not EP.isFedPlumbed(square) then
		-- Nothing plumbed here, and nothing listed standing here either, so this address
		-- describes nothing at all.  Both halves are needed: a PLUMBED square keeps its
		-- address through the bottle-less state below, and an unplumbed one is only worth
		-- keeping while something that could be plumbed is still standing on it.
		local here = EP.fedOnSquare(square)
		if not here then
			forgetFed(entry.key)
		else
			-- A stamp saying plumbed on a square that is not.  The only way to reach it is a
			-- disconnect a client never heard, so clearing it is what puts that client's menu
			-- back in step.  Costs two table reads when there is nothing to correct.
			EP.stampFed(here, square)
		end
		return false
	end

	local object = EP.fedOnSquare(square)

	-- THE OBJECT'S COPY, PUT BACK IN STEP, AND THIS IS WHERE A BOTTLE CHANGE IS REPAIRED.
	--
	-- A square's modData never reaches a client after the chunk that carried it, so what a
	-- client actually reads is a copy stamped on the object and transmitted.  That copy is
	-- destroyed every time the object is - which a bottle change does twice - and no event
	-- announces the replacement, so nothing but a pass coming round can put it back.
	--
	-- Before the room gate on purpose: a full dispenser still has to be correctly labelled,
	-- and this is the one line that makes a rebuilt one show Disconnect instead of Plumb.
	-- EP.stampFed transmits only on a change, so the settled case is two table reads.
	if object then EP.stampFed(object, square) end

	if not object then
		-- THE BOTTLE IS OUT, OR THE DISPENSER HAS GONE, AND THIS IS WHERE THE TWO ARE TOLD
		-- APART.  Nothing else can tell them apart, because OnObjectAboutToBeRemoved is
		-- raised for the dispenser in both cases and is raised BEFORE the removal.
		--
		-- Bottle out: ISAddTakeDispenserBottle has already stood a WaterDispenserNoBottle in
		-- the same spot, in the same frame.  Its script has no FluidContainer component at
		-- all, so it is not a listed fixture and EP.fedOnSquare rightly does not find it -
		-- but it IS a scripted entity.  Hold the address and the flag, and the next lap after
		-- the bottle goes back simply finds a listed fixture standing there again.  That is
		-- what makes a bottle change cost nothing: no re-plumbing, no re-choosing a liquid,
		-- and no event to hear either, because addWorkstationEntity adds the replacement
		-- from Java and raises nothing.
		--
		-- Taken away: bare floor, so the pipe went with it.  The square is put back exactly
		-- as this mod found it - no flag, no liquid, no address - so a dispenser somebody
		-- stands there afterwards is unplumbed like everything else, rather than silently
		-- inheriting a stranger's plumbing.
		if not EP.hasScriptedEntity(square) then
			EP.setFedPlumbed(square, false)
			forgetFed(entry.key)
			EP.log(("the topped-up fixture at %d,%d,%d has gone; its square is clear"):format(
				entry.x, entry.y, entry.z))
		end
		return false
	end

	local fc = object:getFluidContainer()
	if not fc then return false end

	-- The cheap gate, and it is the one nearly every call takes.  A dispenser that is full
	-- is the settled state, so this stage costs one grid lookup, one object walk and two
	-- container reads for the whole of a settled office block.
	local room = fc:getCapacity() - fc:getAmount()
	if room <= EP.EPS then return false end

	-- Whatever the player pointed this square at, defaulting to water.  Kept on the SQUARE
	-- for the same reason the plumbed flag is: a bottle change must not reset it either.
	local liquid = EP.fedFluidType(square)

	-- The summary the walk built on the way past, TAKEN rather than thrown away and rebuilt.
	-- The note below says "SUMMARISED ONCE" and this line used to take only the first return,
	-- so `EP.summariseGroup` then made a whole extra pass over the members - a
	-- getFluidContainer, a getAmount, a getCapacity and a contents read each. Every other
	-- Q13 call site takes the second value.
	local group, walked = supplyGroup(entry.x, entry.y, entry.z, liquid)
	if #group == 0 then return true end

	-- SUMMARISED ONCE, and the summary is both the clamp and the blend.
	--
	-- EP.groupTotals stood here and walked the members for the total alone.  This walk gets
	-- the per-fluid breakdown out of the same container reads, which is what lets a dispenser
	-- on a bleach-and-water supply receive the blend those barrels genuinely add up to
	-- instead of whichever component there happened to be most of.
	--
	-- Clamped to the group's total BEFORE anything is added, so the claw-back below is the
	-- exceptional path rather than the ordinary one.  EP.drawFromGroup clamps again on its
	-- own; this only keeps a nearly-dry building from filling a dispenser and then
	-- immediately emptying most of it again.
	local summary = walked or EP.summariseGroup(group)
	local want = math.min(room, summary.total)
	if want <= EP.EPS then return true end

	local wasLocked, couldEmpty = fc:isInputLocked(), fc:canPlayerEmpty()
	fc:setInputLocked(false)
	fc:setCanPlayerEmpty(true)
	local added = EP.addBlendFrom(fc, summary, want)
	fc:setInputLocked(wasLocked)
	fc:setCanPlayerEmpty(couldEmpty)

	-- Refused.  The only way to reach this is a container holding something the supply's own
	-- liquid will not blend with, which is a state a player has to have made deliberately.
	-- Nothing has been charged, so there is nothing to undo.
	if added <= EP.EPS then return true end

	-- Saved and restored rather than set and cleared, for the reason EP.settleGhost gives:
	-- the draw touches every barrel in the group and each one raises OnWaterAmountChange, so
	-- a plain `= false` in here would drop the guard mid-charge and let the next barrel's
	-- event settle this building's mirrors against a half-debited group.
	local wasSettling = EP.settling
	EP.settling = true

	local taken = EP.drawFromGroup(group, added)

	local unpaid = added - taken
	if unpaid > EP.EPS then
		-- A member went out from under the draw.  Take back exactly what nobody paid for.
		-- On the container rather than through IsoObject.useFluid on purpose: useFluid would
		-- raise OnWaterAmountChange for the dispenser, and the whole point of this branch is
		-- that nothing happened.
		fc:removeFluid(unpaid)
	end

	EP.settling = wasSettling

	if EP.debugging() then
		EP.log(("%.2f of %s topped up into the %s at %d,%d,%d from %d collector(s)%s"):format(
			taken, tostring(liquid), tostring(object:getEntityFullTypeDebug()),
			entry.x, entry.y, entry.z, #group,
			unpaid > EP.EPS and (", %.2f unpaid and taken back"):format(unpaid) or ""))
	end

	-- The container was written to directly, so nothing has told the clients.  This is the
	-- same channel EP.settleGhost uses and for the same reason: the component is not what
	-- the network watches, and syncIsoObjectSend is what carries it.  Only for an object the
	-- square actually holds - syncIsoObject refuses and logs when getObjectIndex() is -1.
	if taken > EP.EPS and object:getObjectIndex() >= 0 then object:sync() end

	-- Every mirror over any of the barrels just charged is now reading a total that includes
	-- water this took out, and their own OnWaterAmountChange was raised inside the guard
	-- above and deliberately ignored.  Left alone that is duplicated water, exactly as it is
	-- on the mirror path - two taps over one barrel, one of them still believing it is full.
	-- No `except`: nothing here is a mirror.
	if taken > EP.EPS and EP.afterGroupCharged then
		EP.afterGroupCharged(group)
	end

	return true
end

--- THERE IS NO BATCH SWEEP FUNCTION ANY MORE, and that is deliberate rather than tidy.
---
--- sweep(full) used to live here: build a list of every mirror and every fixture, walk all
--- of it, and be finished.  The maintenance cursor at the foot of this file does the same
--- work through the same two per-item functions, a few entries at a time, for ever.
---
--- Keeping both would have been the obvious safe move and it is the one thing that must
--- not be done.  Two mechanisms doing the same job drift: a repair gets added to the batch
--- and not to the cursor, and the symptom is a fault that heals whenever something happens
--- to run the other one.  There is one path, so there is nothing to keep in step.
---
--- What the callers do instead:
---
---   EveryHours    reviewPumps, then raise settleWanted and let the cursor act on it
---   OnRainStop    raise settleWanted
---   Enabled=off   teardown, from the tick handler
---
--- and the debug dump the old function ended with is now its own EveryTenMinutes handler,
--- because it was always a log and never maintenance.

--- Service one fixture on demand, and whatever else stands in the same building.
---
--- This is the trigger the client pulls when somebody right-clicks a fixture or
--- puts a collector down.  It notices the ground around the request first, so a
--- barrel built ten seconds ago is in the registry by the time the choice is made.
--- The box a change at x,y,z could possibly matter inside.
---
--- Without this, servicing walked every registered fixture in the loaded world -
--- every sink, bath, toilet and washing machine in every open chunk - on every
--- right-click and every placement, at roughly eighteen square lookups plus a scan
--- of every collector apiece.  In a town that is thousands of lookups to answer a
--- question about one building.
---
--- A collector can only supply a fixture in its own building, or within Reach of
--- it where there is no building, so anything outside that box is answering a
--- question nobody asked.  The box is computed once per trigger and each fixture
--- is then rejected by four integer comparisons.
local function affectedBox(x, y, z)
	-- EP.buildingAt falls back to the plan, which matters here: a collector shoved
	-- against the outside of a wall stands on a square with no room, and measuring
	-- Reach from outside a large house would miss most of the fixtures in it.  The
	-- plan test is the same one servesBuilding uses to decide that barrel belongs to
	-- that house, so the walk it triggers agrees with it.
	--
	-- Deliberately no z bounds: the box is a plan, and every floor and basement
	-- inside it is in scope.  Height is settled per collector by canSupply.  The
	-- bounds are the building's *and its basements'*, so a cellar that reaches out
	-- past the house above it is still walked.
	local bounds = EP.buildingBounds(EP.buildingAt(x, y, z))
	local box
	if bounds then
		box = { minX = bounds.minX - 2, minY = bounds.minY - 2,
		        maxX = bounds.maxX + 2, maxY = bounds.maxY + 2 }
	else
		local reach = EP.getOption("Reach")
		box = { minX = x - reach, minY = y - reach, maxX = x + reach, maxY = y + reach }
	end
	-- AND THE STRUCTURE.  See `regionSpread`: plumbing a barrel in a player-built compound
	-- re-serviced a Reach square round the BARREL, so a tap at the far end of the same
	-- structure was never told. No z bounds here, by the note above.
	return widenToStructure(box, x, y, z, false)
end

--- Service the fixture at an address, if there is still one there.
function serviceFixtureAt(fx, fy, fz, mayDiscover)
	if not fx or not fy or not fz then return end
	local square = getCell():getGridSquare(fx, fy, fz)
	local f = square and EP.fixtureOnSquare(square)
	if f then serviceFixture(f, mayDiscover) end
end

--- `wide` says whether anything other than this one fixture could have changed.
---
--- A right-click is about one fixture and nothing else, so it services that
--- fixture and stops.  A collector being placed or a generator starting changes the
--- answer for every fixture that can see it, so those pass wide and pay for the
--- pass over the registry.  Splitting the two is what keeps the common trigger -
--- opening a context menu - down to a handful of lookups.
local function serviceAroundBody(x, y, z, wide)
	noticeAt(x, y, z)

	local square = getCell():getGridSquare(x, y, z)
	local fixture = square and EP.fixtureOnSquare(square)
	if fixture then
		serviceFixture(fixture)

		-- FORCED OUT TO THE CLIENT, because somebody is looking at it right now.
		--
		-- serviceFixture settles the mirror, and settleGhost syncs it - but only when the
		-- amount it holds actually MOVED.  That gate is right for the hundreds of settles
		-- the cursor does, where re-sending an unchanged number would be a packet per
		-- mirror per lap for nothing.  It is wrong here, and in one case exactly: a client
		-- whose copy has drifted.  The server's number did not change, so nothing was sent,
		-- so the client goes on showing a stale figure - and no amount of right-clicking
		-- fixes it, because each click confirms the server was right all along.
		--
		-- A right-click is the one moment worth spending a packet on unconditionally: it is
		-- rare, it is deliberate, and it is the moment a player is asking what a tap holds.
		-- This is what makes the answer instant rather than "within a lap", which is the
		-- whole complaint - and it is a repair for drift as well as a promptness win.
		local ghost = ghostFor(x, y, z)
		if ghost and ghost:getObjectIndex() >= 0 then ghost:sync() end
	end

	-- Walk the other way too.  A right-click is about one fixture, but the answer
	-- for that fixture depends on its collector, and the collector's pump can have
	-- changed with nothing to announce it - a generator out of fuel raises no event
	-- at all.  Reviewing the pumps here is what makes looking at a tap enough to
	-- notice that its barrel stopped, instead of waiting for the sweep.
	-- AND ONLY ON A WIDE PASS.  `EP.reviewPumps` snapshots the WHOLE `sources` registry and
	-- pays an `EP.sourceAt` - a grid lookup plus a walk of the square's object list - per
	-- collector in the world, not per collector in scope. Running it before the `wide`
	-- early-out charged that to every plain right-click on a single tap, which is the third
	-- whole-registry walk on that path: BR-LGEP-037 removed two and neither report touched
	-- this one.
	--
	-- A wide pass is what a placement, a plumb-in and a pipe lay run, and those are the
	-- triggers a pump transition can actually hide behind. A right-click on one tap still
	-- re-points that tap through `serviceFixture` above.
	if wide then EP.reviewPumps() end

	if not wide then return end

	-- Nothing to connect to and nothing already connected: the common case in a
	-- game where nobody has built a rain collector yet, and not worth walking the
	-- fixture list for.
	if not EP.any(sources) and not EP.any(ghosts) then return end

	-- Anything else in scope, because the trigger is just as often "a collector
	-- appeared" as "this fixture was clicked", and a new barrel changes the answer
	-- for every fixture that can see it, not only the one under the cursor.
	--
	-- Inside a building this reads that building's own list and nothing else, so a
	-- barrel going up in one house costs the fixtures of one house however much of
	-- the map is loaded.  With no building there is no list to read and it falls
	-- back to filtering the whole registry by distance.
	local pool = poolOf(x, y, z)
	local list = pool and byPool[pool] or fixtures
	local box = pool and nil or affectedBox(x, y, z)
	local cell = getCell()

	-- Snapshot before walking, because servicing a fixture can add to the very list
	-- being walked: serviceFixture reaches groupOrDiscover, which can reach discover(),
	-- which files every fixture it sweeps up - and a sink built this session is
	-- exactly the sort of thing it finds.  Both `fixtures` and its per-pool view
	-- would gain a key mid-pairs(), which is undefined in Lua and in Kahlua.
	--
	-- The new arrivals are not missed by skipping them here.  They are in the
	-- registry from now on, and the fixture that triggered this pass is serviced
	-- above regardless of whether anything had ever heard of it.
	local snapshot = {}
	local taken = {}
	for key, pos in pairs(list) do
		snapshot[#snapshot + 1] = { key = key, x = pos.x, y = pos.y, z = pos.z }
		taken[key] = true
	end

	-- AND EVERY FIXTURE ON THE SAME PIPE NETWORKS, which are outside this building's list and
	-- outside the Reach box by definition - that is what a pipe is for.  Filtered by the
	-- networks' box, so a pipe across town costs the fixtures near that pipe and not the
	-- registry.  The group each one then builds decides whether it is actually fed; this
	-- only decides who is asked now rather than on the next lap.
	if EP.anyPipes and EP.anyPipes() then
		local nets = EP.pipeNetsAt(x, y, z, fixture ~= nil)
		local nb = nets and EP.pipeNetsBox(nets) or nil
		if nb then
			for key, pos in pairs(fixtures) do
				if not taken[key] and pos.x >= nb.minX and pos.x <= nb.maxX
					and pos.y >= nb.minY and pos.y <= nb.maxY then
					snapshot[#snapshot + 1] = { key = key, x = pos.x, y = pos.y, z = pos.z, piped = true }
				end
			end
		end
	end

	for _, entry in ipairs(snapshot) do
		local key, pos = entry.key, entry
		if entry.piped or not box or (pos.x >= box.minX and pos.x <= box.maxX
			and pos.y >= box.minY and pos.y <= box.maxY) then
			local other = cell:getGridSquare(pos.x, pos.y, pos.z)
			if not other then
				forgetFixture(key)
			else
				local f = EP.fixtureOnSquare(other)
				if not f then
					forgetFixture(key)
				elseif f ~= fixture then
					serviceFixture(f)
				end
			end
		end
	end

end

--- SERVICE A SQUARE, AND THE PURSE IS PER PLAYER ACTION - INCLUDING THE NESTED CALLS.
---
--- The body above used to open with `swept = nil; sweepPurse = DISCOVER_PER_PASS`, which is
--- the right thing for a fresh trigger and the wrong thing for a call this one made itself.
--- `EP.reviewPumps` ends each transition with `EP.serviceAround(..., true)`, and so does
--- `EP.reviewPumpEntry`, so a generator running out of fuel in a base with two hundred
--- plumbed barrels gave two hundred nested calls, each REFILLING the purse the outer call
--- had just bounded: up to 200 x 1,024 squares of `discover()` in one frame, at about twelve
--- microseconds a square. The header on `DISCOVER_PER_PASS` states the bound as "one player
--- action"; set-and-clear made it "one nested call", which is no bound at all.
---
--- Clearing `swept` in a nested call was the same mistake from the other side: it let the
--- outer walk re-sweep a box it had already covered.
---
--- Depth-counted and balanced through a pcall, because every caller already pcalls this and
--- a leaked depth would silently disable the refill for the rest of the session. The perf
--- marks move out here with it: `marks` is one slot per name, so a nested call used to
--- overwrite the outer's start and the outer's `markEnd` then recorded nothing - the log
--- showed the short inner rows and lost the long outer one, on the mod's own hottest path.
--- memory/an-instrument-that-changes-what-it-measures.md
local servicingDepth = 0

--- RUN THIS AS ONE PLAYER ACTION: one sweep purse, one `swept` memo, one perf mark.
---
--- The purse's header states the bound as "one player action", and getting that right means
--- knowing where an action BEGINS. The first version of this counted depth inside
--- `EP.serviceAround` only, which closes the nesting that happens below a service and leaves
--- the nesting that happens ABOVE one wide open:
---
---     ISActivateGenerator:complete  ->  powerChanged  ->  EP.reviewPumps
---                                                          -> serviceAround   (depth 0!)
---                                                          -> serviceAround   (depth 0!)
---                                                          -> ... once per transition
---
--- `EP.reviewPumps` is reached from the generator wrappers with no service above it, so every
--- one of its per-transition calls tested as outermost and re-armed the purse and cleared
--- `swept` - which is BR-LGEP-052's sentence word for word, surviving on the deliberate act
--- after it was closed on the autonomous one. Pulling the cord on a generator in a base with
--- two hundred plumbed barrels is N x 1,024 columns of `discover()` in one frame, at about
--- twelve microseconds a square, and it is the one moment a player is standing there waiting
--- for the lights.
---
--- `EP.reviewPumpEntry` is the same shape one level down: the cursor's pump stage also ran at
--- depth 0, so it handed itself a fresh purse on every step that found a transition while
--- charging itself a whole frame's budget as if it had bounded the work.
---
--- `mark` is the perf-table name, or nil for work that is not a player action at all. The
--- cursor passes nil: bracketing its background pump stage as "right-click" put maintenance
--- time in the right-click row, which is
--- memory/an-instrument-that-changes-what-it-measures.md arriving from the other side.
local function asOneAction(mark, fn, ...)
	local outermost = servicingDepth == 0
	if outermost then
		-- A fresh trigger gets a fresh look; see `swept`.
		swept = nil
		sweepPurse = DISCOVER_PER_PASS
		if mark then EP.markStart(mark) end
	end

	servicingDepth = servicingDepth + 1
	local ok, err = pcall(fn, ...)
	servicingDepth = servicingDepth - 1

	if outermost and mark then EP.markEnd(mark) end
	if not ok then error(err, 0) end
end

function EP.serviceAround(x, y, z, wide)
	if not EP.isAuthority() then return end
	if not EP.getOption("Enabled") then return end

	-- The other Class B frame, and the one a player meets most often.  The menu is built
	-- synchronously and must return populated in this frame, so like the drink there is no
	-- deferring it - only making it smaller.
	asOneAction("right-click", serviceAroundBody, x, y, z, wide)
end

--- The client asking for a fixture to be serviced: a right-click, or something
--- plumbable being put down.  There is no server-side event for either - see the
--- note above - so the side that can see them says so.
--- A player opting a collector in or out of the building-wide pool.
---
--- Authoritative here, like every other decision: the flag lives in the
--- collector's modData, which is saved with the chunk and travels to clients on
--- its own, so nothing has to be sent back.  Re-servicing straight afterwards is
--- what makes the change visible immediately rather than at some later trigger --
--- excluding the barrel a fixture was using has to re-point that fixture now.
function EP.setIncluded(x, y, z, included)
	if not EP.isAuthority() then return end

	-- A COLLECTOR OR A LISTED FIXTURE, AND THE SAME DECISION EITHER WAY.
	--
	-- Both ends of a pipe are plumbed in by the same act, so they are plumbed in through the
	-- same function, the same flag and the same command rather than through a second path
	-- that would have to be kept in step with this one.  EP.sourceAt and EP.fedOnSquare are
	-- mutually exclusive by construction - the list is consulted at the foot of
	-- EP.isWaterSource - so exactly one of them can answer for any object.
	local square = getCell():getGridSquare(x, y, z)
	local source = EP.sourceAt(x, y, z)
	local fedFixture = nil
	if not source then
		fedFixture = EP.fedOnSquare(square)
		source = fedFixture
	end
	if not source then return end

	-- PLUMBING IN IS CHECKED HERE TOO, not only in the menu that offered it.
	--
	-- The menu is a client's opinion.  It is the right place to DECIDE what to show -
	-- vanilla settles the Plumb option on the client as well, see the note in
	-- ensureLocalStandIn - but it is not a place a rule can be enforced, because the
	-- command that arrives here is whatever somebody's machine chose to send.  A client
	-- that is a moment out of date, a base that changed shape while a menu was open, and
	-- an outright forged packet all arrive looking the same.
	--
	-- Same predicate as the menu's, so this refuses exactly what the menu declines to
	-- offer rather than being a second, drifting copy of the rule.
	--
	-- DISCONNECTING IS NEVER REFUSED.  Getting out of the supply must always work,
	-- whatever has happened to the building - the asymmetry the menu draws for the same
	-- reason, and refusing here would be the one way to strand a barrel permanently.
	if included and not EP.canPlumbHere(x, y, z) then
		EP.log(("refused to plumb the collector at %d,%d,%d: nothing there for it to join")
			:format(x, y, z))
		return
	end

	local data = source:getModData()

	-- The reserve flag is deliberately NOT cleared on the way out, which is a
	-- change from what the main-supply flag did here.
	--
	-- Being the main was a post: the building appointed somebody else the moment a
	-- barrel left the network, and that appointment had to outlast the barrel coming
	-- back, or changing your mind would silently move the whole building's plumbing
	-- twice.  Being held in reserve is nothing of the sort - it is a property of
	-- this barrel, chosen by the player, and there is no post for anybody else to
	-- take.  Forgetting it because somebody toggled a different switch would be a
	-- setting that quietly resets itself.
	--
	-- EP.isReserve answers false for an excluded barrel anyway, so an excluded
	-- reserve is out of the network exactly like any other excluded barrel; the flag
	-- simply waits for it to come back.

	if fedFixture then
		-- ON THE SQUARE, NOT ON THE OBJECT.  The engine destroys and rebuilds a dispenser
		-- every time its bottle comes off or goes on, so the object is not a place a decision
		-- can be kept; see the long note on EP.KEY_FED.  KEY_INCLUDE is left completely
		-- alone, so an object that had been plumbed in as a COLLECTOR before its id went on
		-- the list still carries that flag and gets it back if the id comes off again.
		--
		-- The liquid is deliberately not passed, so plumbing something in never overwrites a
		-- choice already made for that square - a bottle change that somehow got this far
		-- would otherwise silently reset it to water.
		--
		-- THE `included == false` BRANCH IS KEPT THOUGH NO MENU CAN REACH IT ANY MORE.
		--
		-- addFedOptions offers no Disconnect row: a listed fixture is not a water collector
		-- by canPickUpMoveableInternal's test, so it can be picked up full, and picking it up
		-- already clears the square completely.  A row duplicating that is clutter.
		--
		-- The COMMAND is not narrowed to match, and that is the asymmetry to keep: a client a
		-- version behind still has the row, and a request the authority quietly ignored would
		-- be a timed action that plays out in full, with the wrench sound and the progress
		-- bar, and does nothing - which is the exact shape of the fault this whole file's
		-- notes are arranged against.  Honouring it costs one branch.
		EP.setFedPlumbed(square, included)

		-- AND TELL THE CLIENTS, because the square alone cannot.  IsoGridSquare has no
		-- transmit for its modData at all - it reaches a client with the chunk and never
		-- again - so without this the dispenser filled correctly and the player watched the
		-- Plumb row sit there as though nothing had happened.  Invisible in singleplayer,
		-- where the deciding VM is the drawing VM; total on a server.
		EP.stampFed(fedFixture, square)

		EP.log(("topped-up fixture at %d,%d,%d %s the extended pool"):format(
			x, y, z, included and "joined" or "left"))

		-- FILLED NOW, NOT WITHIN A LAP.  Somebody has just stood there with a wrench for a
		-- hundred ticks; a dispenser that then took another few seconds to show any water
		-- would read as the job having failed, which is the whole complaint the instant
		-- paths in this mod exist to answer.
		--
		-- Filed first, because a dispenser somebody built this session may never have been
		-- through LoadGridsquare - and this is also what puts it in the registry that the
		-- maintenance stage walks, so a plumb-in is what starts it being kept full.
		noticeAt(x, y, z)
		if included then topUpFedEntry({ key = EP.key(x, y, z), x = x, y = y, z = z }, getCell()) end

		-- Deliberately NOT the wide serviceAround a collector gets.  That re-points every
		-- fixture in the building because a barrel joining or leaving changes what all of
		-- them can reach; a dispenser supplies nobody, so it changes the answer for nothing.
		-- What it DID change - the barrels it just drank from - was handed to
		-- EP.afterGroupCharged inside the top-up.
		return
	end

	data[EP.KEY_INCLUDE] = included and true or false
	source:transmitModData()
	EP.log(("collector at %d,%d,%d %s the extended pool"):format(
		x, y, z, included and "joined" or "left"))

	-- A barrel plumbed in or out is exactly what turns a pipe network blue or white, and
	-- nothing else here moves the pipe supply: the barrel is already filed, so notice()
	-- files nothing and supplyChanged() is not reached.  A flag; LGEPPipes decides.
	if EP.markPipeSupplyDirty then EP.markPipeSupplyDirty() end

	-- AND EVERY WALK THAT ALREADY COUNTED THIS BARREL IS NOW WRONG.
	--
	-- `walkEpoch`'s header names "a collector filed, forgotten, included, excluded" as exactly
	-- what must invalidate a walk in flight, and this path never did it: `walkStep` asks
	-- `EP.isIncluded` per candidate as it goes, so a walk that had already passed this barrel
	-- keeps it in the group. On a base where a walk spans tens of ticks the Disconnect lands
	-- during somebody's hundred-tick wrench action, which is the whole window.
	--
	-- The one walk in flight is dropped rather than the epoch bumped: bumping it also clears
	-- the refusal memory for the whole world, and there is at most one walk open at a time, so
	-- the cost is one restarted walk per wrench job. `ghostsFed` would be the precise set but
	-- it is declared below this - a local called from above is a nil call
	-- (memory/local-function-called-from-above-is-a-nil-call.md).
	if EP.abandonWalkNow then EP.abandonWalkNow() end

	-- [Malcolm_Perf] The registry decides which chunks get the full look as they load, so a
	-- barrel plumbed in where nothing was plumbed before has its building's fixtures looked at
	-- now, once, before the wide service below goes looking for them.
	if EP.reg and EP.reg.ready() then
		if included then
			if EP.reg.add(x, y, z, EP.reg.BIT_SRC) then
				local ok, err = pcall(function() EP.reg.scanBox(sweepBox(x, y, z)) end)
				if not ok then EP.logFault("registry-discover", "ERROR looking over a building: " .. tostring(err)) end
			end
		else
			EP.reg.remove(x, y, z, EP.reg.BIT_SRC)
		end
	end

	EP.serviceAround(x, y, z, true)
end

--- A player holding a collector back as a reserve, or putting it into service.
---
--- No election, no stand-down, no pool: a building may have any number of
--- reserves or none, and the flag says nothing about any other barrel.  That is
--- the whole difference from the main supply this replaced, which was one per
--- building by construction and had to take the job off whoever held it.
---
--- Re-servicing afterwards is what makes it visible at once.  Nothing has to move
--- and no mirror has to be re-aimed - the group is the same group, the draw order
--- inside it changed - but every mirror wants re-settling so the debug dump and any
--- watching client agree with the new arrangement.
function EP.setReserve(x, y, z, reserve)
	if not EP.isAuthority() then return end

	local source = EP.sourceAt(x, y, z)
	if not source then return end

	source:getModData()[EP.KEY_RESERVE] = reserve and true or nil
	source:transmitModData()
	EP.log(("collector at %d,%d,%d is %s"):format(
		x, y, z, reserve and "held in reserve" or "back in normal service"))

	EP.serviceAround(x, y, z, true)
end

--- Point a fixture at a different liquid.
---
--- THE ORDER BELOW IS THE WHOLE FUNCTION.  Every step is a primitive that already
--- exists and is already right; what is new is only that they happen in this order,
--- and each one of them prevents a specific way of losing or inventing water.
---
---   1. SETTLE AGAINST THE OLD GROUP.  Anything drawn through the tap since the
---      last settle is charged to the barrels it actually came out of.  Do this
---      after the key is written and the last minute's drinking is billed to the
---      new liquid's barrels instead.  This is why the write is step 3.
---
---   2. SLEEP THE MIRROR.  Empties the copy - the real water is still in the
---      barrels - and, critically, sets the ledger to 0.  Without that the next
---      settle reads `held(new) - ledger(old)` and credits or charges the new
---      liquid's barrels for the old liquid's water.  sleepGhost also banks any
---      residual as debt rather than forgiving it, tagged with the liquid it was
---      incurred in, so a switch performed while a member's chunk is unloaded still
---      owes what it owes - and owes it in whiskey, not in water.
---
---   3. WRITE THE CHOICE.  nil for water, so a fixture only ever gains modData when
---      a player deliberately chooses something else and every existing save is
---      untouched.
---
---   4. REBUILD.  serviceFixture resolves the new group, re-seats, re-sprites and
---      settles, or sleeps the mirror when the building has none of the new liquid.
---      It reaches EP.fillFromGroup, which is the one path safe to change a
---      container's capacity through: Empty, then setCapacity, then refill.
---
--- This is the one place in the mod that writes to a fixture, and it is a
--- deliberate exception to "nothing is ever written to a fixture" rather than an
--- oversight.  The alternative was to keep the choice on the mirror, and that fails
--- on a path that matters: teardown() destroys every mirror when the Enabled option
--- is switched off, so an operator flicking that option would silently revert every
--- whiskey tap to water and set it drinking the house's drinking water.  One string
--- that vanilla ignores, on an object vanilla already lets players re-plumb, is the
--- cheaper of the two.
function EP.setFixtureFluid(x, y, z, newType)
	if not EP.isAuthority() then return end

	local square = getCell():getGridSquare(x, y, z)
	if not square then return end

	-- A TOPPED-UP FIXTURE CHOOSES ITS LIQUID THROUGH THE SAME COMMAND, AND THE SAME ROW.
	--
	-- It is the identical question asked of a different vessel, so it goes down the identical
	-- channel rather than growing a second command that would have to be kept in step.  What
	-- follows the write is where the two part company: a tap has a mirror to settle, sleep
	-- and rebuild, and a dispenser has fifteen real litres somebody can drink.
	if not EP.fixtureOnSquare(square) then
		local fedFixture = EP.fedOnSquare(square)
		if not fedFixture then return end

		newType = EP.canonicalFluidType(newType) or EP.FLUID_DEFAULT
		if EP.fedFluidType(square) == newType then return end

		-- REFUSED WHILE THERE IS ANYTHING IN IT, and checked here and not only in the menu
		-- that offered it.  The menu is a client's opinion - a stale one, a base that changed
		-- while a submenu was open, and an outright forged packet all arrive looking the
		-- same - and this is the one rule here with a consequence that cannot be undone:
		-- switching a half-full dispenser from water to whiskey would have the next top-up
		-- pour whiskey into water, and the player has no way to unmix it.
		--
		-- Same predicate as the menu's, so this refuses exactly what the menu declines to
		-- offer rather than being a second, drifting copy of the rule.
		local fc = fedFixture:getFluidContainer()
		if fc and fc:getAmount() > EP.EPS then
			EP.log(("refused to re-point the topped-up fixture at %d,%d,%d: it is not empty")
				:format(x, y, z))
			return
		end

		-- Plumbed in is what the row is offered on, and the same reasoning applies: a choice
		-- recorded for a square nobody has plumbed anything on would be state with nothing
		-- reading it.
		if not EP.isFedPlumbed(square) then return end

		EP.setFedPlumbed(square, true, newType)
		EP.stampFed(fedFixture, square)
		EP.log(("the topped-up fixture at %d,%d,%d now draws %s"):format(x, y, z, newType))

		-- FILLED NOW.  Nothing has to be settled or slept - there is no mirror - and the
		-- container is empty by the test above, so the next top-up is the whole of the
		-- change.  Doing it here rather than leaving it to the cursor means the player sees
		-- the answer to what they just chose.
		topUpFedEntry({ key = EP.key(x, y, z), x = x, y = y, z = z }, getCell())
		return
	end

	local fixture = EP.fixtureOnSquare(square)

	-- THE WALK IN FLIGHT FOR THIS FIXTURE'S MIRROR DESCRIBES THE OLD LIQUID'S GROUP.
	--
	-- Re-pointing a fixture changes which barrels its mirror may draw on - the same change to
	-- group membership that `walkEpoch`'s own header lists as something that must invalidate
	-- a walk, written for a COLLECTOR being re-pointed and never applied to the fixture.
	--
	-- Left alone: `serviceFixtureAt` below abandons the walk only on the branch where the new
	-- liquid resolves to a group. When it does not - a sink pointed at whiskey in a building
	-- with no whiskey - the walk survives and lands carrying the WATER barrels. The mirror is
	-- filled from them while `EP.ghostFluidType` already answers whiskey, so the tap pours
	-- water it calls whiskey; and the next drink charges nothing, because the whiskey group is
	-- empty, so the shortfall is banked as a whiskey debt that no water barrel may ever pay.
	local repointed = fixture and ghostFor(square:getX(), square:getY(), square:getZ()) or nil
	if repointed and EP.abandonWalkFor then EP.abandonWalkFor(repointed) end

	newType = EP.canonicalFluidType(newType) or EP.FLUID_DEFAULT
	local old = EP.fixtureFluidType(fixture)
	if old == newType then return end

	local ghost = ghostFor(x, y, z)
	if ghost then
		-- The other path Q13 names by hand.  The final settle against the OLD group before
		-- the fixture's choice is rewritten, so the last draw is charged to the barrels it
		-- actually came out of - and the totals for it are the ones the walk just built.
		local oldGroup, oldSummary = supplyGroup(x, y, z, old)
		if #oldGroup > 0 then EP.settleGhost(ghost, oldGroup, oldSummary) end
		EP.sleepGhost(ghost)
	end

	fixture:getModData()[EP.KEY_FLUID] = (newType ~= EP.FLUID_DEFAULT) and newType or nil
	fixture:transmitModData()

	EP.log(("the fixture at %d,%d,%d now draws %s instead of %s"):format(
		x, y, z, newType, old))

	serviceFixtureAt(x, y, z)
end

--- Is this command about somewhere the player who sent it actually is?
---
--- Not a distance.  A distance was the first attempt and it was the wrong question:
--- the whole point of this mod is that a fixture is served by its BUILDING, so the
--- legitimate span of one command is however big that building happens to be - a
--- mall, a warehouse, a tower with a cellar - and any radius wide enough for the
--- largest of those is wide enough to reach three streets of somebody else's.
---
--- So it asks the mod's own scope question instead, in the mod's own vocabulary:
--- the same building, or within Reach.  Which is exactly the pair of rules
--- supplyGroup uses to decide what a fixture may draw on, so a command is accepted
--- precisely when it is about somewhere the sender could already have plumbed by
--- walking up to it, and refused when it is about a building they are not in.
---
--- Nothing here is a capability the player has not got - they can right-click the
--- barrel in front of them - so this is not about privilege.  It is about a packet
--- naming somebody else's base:
---
---   * include/reserve write to a collector's modData and transmit it, so without
---     this any client could re-plumb any building on the map from anywhere, and its
---     owner would watch their barrels change state with nothing to point at.
---   * service is the expensive one.  It runs noticeAt and then serviceAround, which
---     can reach discover() - a sweep of a whole building, measured at 2787 square
---     lookups for a small house and a great deal more for a warehouse - on the
---     server's own thread.  Aimed at a chosen coordinate and repeated at packet
---     rate, that is the server doing the work and the sender choosing how much.
---
--- Fails OPEN when neither end resolves to anything, which is not a hole: that is
--- the case supplyGroup itself falls back to Reach for, and it is filtered by Reach
--- here too.  It also fails open when the sender cannot be resolved at all -
--- deliberately.  GameServer passes the IsoPlayer that sent the packet and
--- SinglePlayerServer passes one too, so this resolves on every shipping path, but a
--- guard that silently stopped the mod working because a future build changed the
--- argument shape would be a worse bug than the one it is here for.
--- How often one player may ask the authority to service a fixture.  See the handler.
local SERVICE_MIN_MS = 250
local serviceLastAt = {}

--- WHAT A PLAYER MAY CLAIM TO HAVE DRAWN, AND HOW FAST.  See the COMMAND_DRAW handler.
---
--- A per-packet ceiling alone is the wrong shape: a sender refused 100,000 in one packet can
--- send two hundred of 500.  What bounds the attack is the RATE, and what bounds the rate is
--- that an honest fill is one report per vessel - the client's own `__lgepSent` closes the
--- window after the first tick of the action, measured at one command per bottle.
---
--- So: a generous per-report ceiling, well above any vessel in the game, and a per-player
--- budget per second that a real player cannot reach but a flood empties instantly.
local MAX_REPORTED_DRAW = 100
local DRAW_PER_SECOND = 250
local drawWindow = {}

local function commandAllowed(player, x, y, z)
	if not player or not player.getX or not player.getY or not player.getZ then
		return true
	end

	local px, py, pz = player:getX(), player:getY(), player:getZ()
	if type(px) ~= "number" or type(py) ~= "number" or type(pz) ~= "number" then
		return true
	end

	px, py, pz = math.floor(px), math.floor(py), math.floor(pz)

	-- The whole building, however big it is.  EP.buildingAt resolves a roof or a
	-- balcony through the plan and a cellar through to the house over it, so a player
	-- on the roof and the sink in the basement are the same answer.
	local mine = EP.buildingAt(px, py, pz)
	local theirs = EP.buildingAt(x, y, z)
	if mine and theirs and EP.sameDef(mine, theirs) then return true end

	-- Otherwise near enough to have walked to it.  Covers the player standing in the
	-- street who right-clicks a barrel against the wall, the player in one house
	-- reaching the shed next to it, and every player-built base, which has no def to
	-- compare on a dedicated server at all.  Chebyshev, like Reach everywhere else.
	-- WITH THE SAME FLOOR `senderMayReach` HAS, and for the same reason it was given one.
	--
	-- `Reach` has `min = 1` in sandbox-options, and an honest player is at exactly 1: the menu
	-- walks them adjacent before it sends anything, and on a dedicated server this side's copy
	-- of where they are trails the client's by whatever the last movement packet said. A gate
	-- of `<= 1` has no slack for that at all.
	--
	-- The pipe acts got this floor when `senderMayReach` was written and this, the older gate
	-- on COMMAND_SERVICE, INCLUDE, RESERVE, FLUID and DRAW, did not - so at `Reach = 1` on a
	-- server, clicking *Plumb this barrel in* or a liquid row did nothing at all, and the
	-- refusal goes to `EP.log`, which is silent with Debug off. The same silent-refusal class
	-- as BR-LGEP-003.
	local reach = EP.getOption("Reach")
	if reach < 2 then reach = 2 end
	return math.max(math.abs(px - x), math.abs(py - y)) <= reach
end

Events.OnClientCommand.Add(function(module, command, player, args)
	if module ~= EP.COMMAND_MODULE then return end
	if command ~= EP.COMMAND_SERVICE and command ~= EP.COMMAND_INCLUDE
		and command ~= EP.COMMAND_RESERVE and command ~= EP.COMMAND_FLUID
		and command ~= EP.COMMAND_DRAW then return end

	-- Everything in here came off the wire, so none of it is trusted to be a
	-- number, in range, or present at all.
	if type(args) ~= "table" then return end
	local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
	if not x or not y or not z then return end
	if z < -32 or z > EP.MAX_LEVEL then return end

	-- Guarded, and fails open, for the same reason the check itself does.  This asks
	-- the metagrid two questions before the mod has done anything, and it runs
	-- outside the pcall below - so an error here would not cost one refused command,
	-- it would take the whole handler down and the mod would stop answering clients
	-- altogether.  A guard that can break the thing it guards is worse than no guard.
	local allowed, refusable = pcall(commandAllowed, player, x, y, z)
	if allowed and refusable == false then
		EP.log(("refused a %s command for %d,%d,%d: not the sender's building, and out of reach"):format(
			command, x, y, z))
		return
	end

	local ok, err
	if command == EP.COMMAND_DRAW then
		-- THE DRAW A CLIENT COULD NOT PERFORM, PERFORMED HERE.
		--
		-- Deliberately done by calling useFluid on the MIRROR rather than by charging the
		-- group directly.  On this side the engine's guard opens, so that one call removes
		-- the water, syncs the mirror to every client, and raises OnWaterAmountChange - and
		-- this mod's own handler turns that into a proportional charge across the group,
		-- with the debt and the liquid rules it has always applied.  It is the identical
		-- path singleplayer takes, which is the whole point: one route, not two that can
		-- drift, and nothing new to keep in step.
		--
		-- CLAMPED TO WHAT THE MIRROR ACTUALLY HOLDS, and that is not politeness - `amount`
		-- came off the wire.  useFluid clamps internally too, but a nonsense value would
		-- still be logged and reasoned about here, and a negative one would ADD water.
		local amount = tonumber(args.amount)
		if not amount or amount ~= amount or amount <= 0 then return end
		-- A DRAW IS A VESSEL BEING FILLED, NOT A TAP BEING OPENED.
		--
		-- The ceiling here was 100,000, which is not a bound on anything: the mirror holds the
		-- WHOLE building's supply, so the clamp below - to what the mirror has - is a clamp to
		-- "everything".  Measured: one packet naming amount = 100000, sent by a player standing
		-- at the fixture, took a building from 900 litres to zero.  No animation, no action,
		-- nothing in the log but the draw itself, repeatable as fast as the mirror refills.
		--
		-- Nothing ties this report to an action the sender actually ran, and nothing can
		-- cheaply: the honest path is a timed action whose transfer the engine performs. So
		-- the bound is what a VESSEL can hold.  The largest fluid container in the game is
		-- well under fifty litres; a hundred is generous and still refuses the attack
		-- outright, and the per-second budget below is what actually bounds a flood.
		-- A legitimate draw is a fraction of a litre per tick.
		if amount > MAX_REPORTED_DRAW then
			EP.log(("refused a draw of %.2f at %d,%d,%d: no vessel holds that"):format(
				amount, x, y, z))
			return
		end

		-- AND THE RATE.  One second's budget per player, refilled by the clock rather than
		-- decayed, because the cheapest correct thing here is also the one with no state to
		-- go wrong.  A player filling every container they own does not approach it.
		local who = (player and player.getUsername and player:getUsername()) or "*"
		local nowMs = getTimeInMillis and getTimeInMillis() or 0
		local w = drawWindow[who]
		if not w or nowMs - w.at >= 1000 then
			w = { at = nowMs, litres = 0 }
			drawWindow[who] = w
		end
		if w.litres + amount > DRAW_PER_SECOND then
			EP.log(("refused a draw of %.2f at %d,%d,%d: %s is over the per-second budget")
				:format(amount, x, y, z, tostring(who)))
			return
		end
		w.litres = w.litres + amount

		local ghost = ghostFor(x, y, z)
		if not ghost then
			EP.log(("a draw was reported for %d,%d,%d, which has no mirror"):format(x, y, z))
			return
		end

		-- A DORMANT MIRROR IS NOT A SOURCE AND MUST NOT BE READ AS ONE.  EP.sleepGhost sets
		-- usesExternalWaterSource on it so the engine's own scan steps past it (see the note
		-- there), and getFluidAmount on an object carrying that flag goes and finds somebody
		-- else's water to answer with.  A stale report arriving for a mirror that has since
		-- gone to sleep would then be charged against whatever is standing above it.
		if EP.isDormant(ghost) then return end

		local held = ghost:getFluidAmount()
		if held <= EP.EPS then return end
		if amount > held then amount = held end

		EP.log(("a client drew %.2f through the fixture at %d,%d,%d"):format(amount, x, y, z))
		ok, err = pcall(function() ghost:useFluid(amount) end)
	elseif command == EP.COMMAND_INCLUDE then
		ok, err = pcall(EP.setIncluded, x, y, z, args.included == true)
	elseif command == EP.COMMAND_RESERVE then
		ok, err = pcall(EP.setReserve, x, y, z, args.reserve == true)
	elseif command == EP.COMMAND_FLUID then
		-- An arbitrary string off the wire must never reach modData, where it would
		-- sit for ever describing a liquid that does not exist.  Fluid.Get is the
		-- engine's own registry and answers nil for anything it has not got - which
		-- covers a typo, a mod that has since been removed, and a deliberately
		-- malformed packet with the same test.  Length-capped first so a megabyte of
		-- text is refused before it is looked up.
		--
		-- EVERY COMPONENT IS CHECKED, because a liquid is a set of fluids now and a
		-- mixture arrives as their names joined by "+".  Checking the whole string
		-- against Fluid.Get would refuse every mixture outright; checking only the
		-- first component would let the rest through unread, which is precisely the
		-- hole this exists to close.
		--
		-- The two bounds are the engine's own, not round numbers.  A container refuses
		-- a ninth fluid, so a liquid with more components than that describes nothing
		-- that can exist; and eight of the longest fluid names in the game come well
		-- inside 256 characters, so the length cap still refuses a megabyte of text
		-- before anything is looked up.
		local fluid = args.fluid
		if type(fluid) ~= "string" or #fluid == 0 or #fluid > 256 then return end

		local parts = EP.liquidParts(fluid)
		if #parts == 0 or #parts > EP.MAX_PARTS then
			EP.log(("refused a fluid command naming %d component(s)"):format(#parts))
			return
		end
		for i = 1, #parts do
			if not Fluid.Get(parts[i]) then
				EP.log(("refused a fluid command naming the unknown liquid %q"):format(parts[i]))
				return
			end
		end
		ok, err = pcall(EP.setFixtureFluid, x, y, z, fluid)
	else
		-- THE EXPENSIVE ONE, AND THE NOTE ABOVE ALREADY SAID SO.  `commandAllowed` bounds
		-- WHERE a client may aim this and not HOW OFTEN; measured, fifty `wide` services in
		-- one tick all ran.  A wide pass is `noticeAt` plus a service of every fixture in the
		-- building, and it can reach `discover`.  A right-click is one ask, so a per-player
		-- floor of a quarter-second costs an honest client nothing.
		local who = (player and player.getUsername and player:getUsername()) or "*"
		local now = getTimeInMillis and getTimeInMillis() or 0
		if serviceLastAt[who] and now - serviceLastAt[who] < SERVICE_MIN_MS then return end
		serviceLastAt[who] = now

		ok, err = pcall(EP.serviceAround, x, y, z, args.wide == true)
	end
	if not ok then
		EP.settling = false
		EP.logFault("plumb-service-fixture", "ERROR servicing a fixture: " .. tostring(err))
	end
end)

--- THERE IS NO CLOCK-DRIVEN SETTLE PASS ANY MORE, of any period.
---
--- This went `EveryOneMinute -> sweep()`, then `EveryTenMinutes -> sweep(true)`, and it
--- existed for one thing: a mirror that ran dry while its barrel filled with rain.  Rain
--- raises no event, so the only way to see it is to look - and that much is still true.
--- What was not looked at is WHEN there is anything to see:
---
---   * FluidContainerUpdateSystem is the only path that moves a barrel's contents
---     without raising OnWaterAmountChange, and it is gated on
---     getPrecipitationIntensity() > 0.  With nothing falling, no barrel anywhere gains
---     a drop.  See silentDriftPossible, which is one field read.
---   * a barrel holding Petrol drains silently whatever the weather, so that is asked
---     too.
---   * everything else - a drink, a bottle emptied, a wash cycle's minute, a transfer,
---     a barrel dismantled - goes through IsoObject and is settled on the spot already.
---
--- Both of those answers are still right and neither needed a clock to act on.  The
--- maintenance cursor asks the same question at the top of every lap and does nothing at
--- all on the laps where nothing can have moved - which in a dry world is almost all of
--- them.  What changed is that a lap is about three seconds instead of ten game minutes,
--- so the cost the old note stated plainly is now much smaller than it was: an UNATTENDED
--- washing machine that ran its barrels dry restarts within a few seconds rather than
--- within ten game minutes.  A drink, a fill or a right-click still settles instantly.
---
--- Anything that wants a settle raises `settleWanted` and lets the cursor act on it.  That
--- is one line, it costs nothing at the call site, and it cannot hitch.

--------------------------------------------------------------------------------
-- the maintenance cursor
--------------------------------------------------------------------------------

--- THERE IS NO PERIODIC PASS AT ALL ANY MORE.  THIS IS A LOOP THAT NEVER STOPS.
---
--- `EveryTenMinutes -> sweep(true)` stood here, and before that `EveryOneMinute`.  Both
--- were the same shape: do nothing for a while, then do everything at once.  That shape is
--- what a player feels, because a hitch is not total work - it is work in ONE FRAME.
--- Measured over a town of 64 houses, one ten-minute pass was 1,991,168 operations landing
--- in a single frame while somebody was walking through it.
---
--- So the clock is gone and the work is a cursor instead.  It walks the three registries
--- in order, a few entries per tick, for ever, and starts again when it reaches the end.
--- There is no pass to be inside, nothing to be late for, and no burst to land anywhere.
---
--- It is not a compromise against the clock it replaces - it is better on both counts:
---
---   PROMPTNESS   at a step's purse (see UNITS_PER_SECOND), a base of 700 registry entries
---                covered in about three seconds of real time.  The pass this replaces
---                took ten GAME minutes, which is twenty-five real seconds at the default
---                day length, and on average a thing waited half of that.
---   PEAK COST    a tick's work is bounded by that purse whatever the world contains.
---                A mall does not cost more per frame than a shed; it takes more laps.
---
--- The deliberate acts do NOT go through here and must not.  A right-click, a placement, a
--- generator switched on, a drink - all keep their instant paths, because a player who
--- pulls a cord must not wait for a cursor to come round.  What is on the cursor is only
--- the work nobody is waiting for: settling drift, the repairs, and finding the fixture
--- that has no mirror yet.
--- WHAT A TICK MAY SPEND, and it is weighted rather than counted.
---
--- Counting entries was the first thing tried and it is not good enough, because the three
--- registries do not hold comparable work.  A collector is one grid lookup.  A mirror is a
--- whole supplyGroup - every collector its building can offer, resolved and tested.  Four
--- entries a tick therefore meant four cheap things in one stage and four expensive ones in
--- another: measured on a base of 200 barrels, a peak tick of 12,944 operations against a
--- mean of 193, which is a hitch that a per-entry budget cannot see because it is inside
--- one entry.
---
--- So an entry costs what it is worth and a tick has a purse.  The ghost stage costs the
--- whole purse, which makes it exactly one mirror a tick; the cheap stages get eight.
---
--- The purse is checked BEFORE an entry is taken, not after, so the bound is strict: a step
--- that has already spent on cheap entries will not also take an expensive one and overrun.
--- The mirror simply waits for the next step.
---
--- EXPRESSED PER SECOND, NOT PER TICK, AND THAT IS THE WHOLE OF THE SERVER FIX.
---
--- This was `TICK_BUDGET = 8`, spent once every four ticks - which is 120 units a second on
--- a client at sixty ticks and TWENTY on a dedicated server at ten.  Every dial on this
--- cursor was written that way and every one of them was sized on the sixty side, so the
--- machine that actually owns the water was running the whole loop at a sixth speed.
--- Measured with a clock (lgep_spec_rate.lua), thirty-six houses: a lap took 7.73 seconds
--- at sixty ticks a second and 49.87 at ten.  See EP.ticksPerSecond in LGEPCore.
---
--- So the purse is a rate, and how much of it belongs to one step is worked out from the
--- gap between steps and from what this machine really does.  At sixty ticks a second that
--- is a step every four ticks spending eight, exactly as before; at ten it is a step every
--- tick spending twelve.  Same work per SECOND, which is the unit the player is standing
--- in.
local UNITS_PER_SECOND = 120

local COST_STAGE_CHANGE = 1
local COST_SOURCE       = 1
--- A mirror's weight, and it is a constant rather than "the whole purse" now.
---
--- It was written as `= TICK_BUDGET` to mean "one mirror a tick, whatever else happens".
--- That reading only holds while the purse is a per-tick constant: tied to the purse, a
--- machine with a bigger per-step allowance would buy nothing with it, because one mirror
--- would still cost all of it.  Eight is what the purse was at sixty ticks a second, so a
--- client behaves exactly as it did and a server gets the mirrors its longer frames pay
--- for.
local COST_GHOST        = 8
local COST_FIXTURE      = 1
--- A listed fixture, and it is priced like a fixture for the identical reason: the settled
--- case is a grid lookup and two container reads, and the one call that finds room walks a
--- whole building.  A static weight cannot price that, so it is charged one unit up front
--- and the rest of the purse after the fact when it turns out to have done the walk.
local COST_FED          = 1

--- THERE IS NO SEPARATE IDLE RATE ANY MORE, and removing it is what made the loop keep up.
---
--- IDLE_EVERY used to slow the cursor to one tick in ten whenever nothing was pending, on
--- the grounds that a lap with no drift did almost nothing and was pure backstop.  That was
--- true while the settle was gated on the weather.  It is not true now: a mirror is settled
--- every time the cursor reaches it, so a "quiet" lap does exactly as much useful work as a
--- busy one and slowing it down only made the tap stale for longer.
---
--- With both throttles in place a dry lap of a thirty-six house town took about eight
--- thousand ticks and reached ten of its hundred and forty-four mirrors in three thousand.
--- The loop was not keeping up, which is the one thing it exists to do.
---
--- What remains is one floor - STEP_SECONDS - plus the proportional rest an expensive step
--- earns.  The real idling is elsewhere and is better: with nothing filed at all the
--- handler parks completely, which costs nothing and cannot go stale, because there is
--- nothing there to be stale about.
---
--- Ticks since the cursor last stepped.  ONE counter for both waits: they are the same
--- decision - "how long until the next step" - and having two of them meant they
--- multiplied rather than combined.
local sinceStep = 0

--- HOW FAR APART THE EXPENSIVE STEPS ARE SPACED, measured rather than assumed.
---
--- Bounding the peak tick is only half the job, and the half that stops a stutter.  The
--- other half is the SUSTAINED load, and a peak comfortably inside budget is still a
--- slowdown if it is paid sixty times a second for as long as the weather lasts.
---
--- Measured, hoarder's base of 200 barrels, raining, 900 ticks: peak 3,228 - perfectly
--- well behaved - against a MEAN OF 612 operations a tick, indefinitely.  Nothing hitches
--- and the game is slower the whole time it rains.  Only the mean can see that, which is
--- why the bench now measures maintenance under rain as well as dry.
---
--- So an expensive step is followed by a proportional rest.  EP.lastConsidered is what the
--- settle just walked - the candidates that got past the locality box, which is the inner
--- loop and what everything else scales with - and the cursor rests whatever holds the walk
--- to SPREAD_PER_SECOND candidates a second before spending again.
---
--- MEASURED AND NOT DERIVED FROM THE REGISTRY, which was the first attempt and is wrong
--- now: after the locality bound a tap in a terrace considers three collectors while one in
--- a hoard considers two hundred, and sourceCount counts the whole world either way.  Pacing
--- an ordinary base by it would have slowed it sixty times for nothing.
---
--- The cap matters as much as the ratio.  Without it a pathological base could space its
--- mirrors minutes apart, and a backstop that slow is one that has stopped.
---
--- IN SECONDS RATHER THAN TICKS, for the reason UNITS_PER_SECOND is.  The old pair were
--- "one tick of rest per eight candidates, capped at forty ticks", which is a sustained
--- 480 candidates a second and a cap of two thirds of a second - on a client.  On a server
--- the same two numbers meant 80 a second and a four-second cap, so the hoarder's base
--- this rule exists for was spaced six times further apart on the machine that had to do
--- the work.  Both are converted through EP.ticksFor at the point of use.
local SPREAD_PER_SECOND = 480
local MAX_REST_SECONDS = 40 / 60

--- THE FLOOR UNDER THAT REST, which applies to every step and not only the dear ones.
---
--- SPREAD_PER_SECOND above deals with a step that is individually expensive.  This deals with
--- general case: there is no reason for maintenance to advance sixty times a second in ANY
--- world.  Nobody is waiting on it - everything a player does has its own instant path -
--- and the only thing a faster cursor buys is a shorter lap, which was ten game minutes
--- until very recently.
---
--- At one step every four ticks a large town laps in roughly twenty seconds instead of
--- five, and the mod's steady cost falls by the same factor.  Twenty seconds is still
--- thirty times prompter than the pass this replaced, and it is spent on work whose whole
--- character is "notice eventually": rain that has landed, a barrel somebody spawned, a
--- sprite that came back wrong from a save.
---
--- This is the knob to turn if the mod is ever found to be costing more than it should.
--- Raising it is close to free in behaviour and linear in saving; the only thing it buys
--- back is lap time.
---
--- IN SECONDS, AND IT IS THE PERIOD RATHER THAN THE WAIT.  `MIN_REST = 3` meant "return for
--- three ticks, then step", which is a step every four ticks: fifteen steps a second on a
--- client and, unchanged, fifteen ticks - a second and a half - of every ten on a server.
--- Written as a period in seconds it converts, and what the purse holds converts with it,
--- so the product - work per second - is the same on both machines.
local STEP_SECONDS = 4 / 60
local restTicks = 0

--- WHAT A STEP DID NOT MANAGE TO SPEND, kept for the next one.
---
--- The purse and the entry weights are both integers, and they do not divide evenly on
--- every machine.  At sixty ticks a second a step gets eight units and a mirror costs
--- eight, so nothing is ever left over.  At ten it gets twelve: one mirror fits, a second
--- does not, and four units an step were being dropped on the floor - which is a third of
--- the allowance, and it showed up as the slow machine settling ten mirrors a second where
--- the fast one settles fourteen.
---
--- Carried rather than forgiven, so the rate is the rate.  Capped at one mirror's weight
--- for the obvious reason: a purse that could bank without limit would spend the whole of
--- a quiet minute in the frame after it, which is the burst this cursor exists to not be.
--- An OVERspend - the exemption that lets an entry dearer than the whole purse run on a
--- fresh step rather than deadlocking - is forgiven and not carried as debt, because a
--- cursor that owes itself is one that can stop.
local carry = 0

--- The gap between steps, in ticks of THIS machine.  Never less than one: a period shorter
--- than a frame is still one frame.
local function stepGap()
	return EP.ticksFor(STEP_SECONDS)
end

--- How much of a per-second allowance belongs to one step, given that gap.
---
--- This is EP.perTick's sibling and exists because the cursor does not act every tick - it
--- acts every `gap` ticks, so its allowance is a gap's worth rather than a tick's.  Floored
--- at one for the same reason: an allowance that divided to nothing is a cursor that never
--- advances.
---
--- EP.budgetRate and not EP.ticksPerSecond, for the reason set out on TICKS_DEFAULT in
--- LGEPCore: on a machine that DRAWS, a low tick rate means the frame is already full,
--- and dividing by it hands out a bigger step at exactly the moment there is least room
--- for one.  The gap between steps still comes from ticksFor, because a real second is
--- a real second however busy the machine is; only the allowance is floored.
local function perStep(perSecond, gap)
	local n = math.floor(perSecond * gap / EP.budgetRate() + 0.5)
	if n < 1 then n = 1 end
	return n
end

--- THE MOST ONE FRAME MAY COST, WHICH IS A DIFFERENT BOUND FROM THE RATE, and keeping the
--- two apart is the whole of why the carry above is safe.
---
--- The rate says how much work a SECOND holds.  This says how much a FRAME may hold, and a
--- hitch is per-frame - so on a machine whose frames are six times longer, a frame may
--- honestly hold six times as much and still be the same fraction of it.  One mirror per
--- sixtieth of a second of frame time is the rule, which is exactly the "one mirror a tick"
--- the cursor was written with, restated in a unit that survives the machine changing.
---
--- Without this the carry doubled the peak on a CLIENT: at sixty ticks a second a step's
--- allowance is eight and a mirror costs eight, so any step that broke early left change,
--- the change banked, and the step after it could afford TWO mirrors in one sixteen
--- millisecond frame.  lgep_spec_cursor caught it at once - peak 174 -> 319 against a
--- ceiling of 234 - which is the suite doing precisely the job it was written for.
---
--- AND "A LONGER FRAME MAY HOLD MORE" IS ONLY TRUE OF A FRAME THAT IS LONG BECAUSE IT IS
--- IDLE.  A dedicated server's hundred milliseconds are spare time and three mirrors in
--- one really is the same fraction of it.  A client at twenty frames a second has a long
--- frame because it is already full - it is drawing more, which is all zooming the camera
--- out does - and giving it three mirrors is three times the hitch, not the same one.  So
--- the divisor is floored wherever frames are drawn and this reads one mirror a frame
--- there, whatever the machine is managing.  See EP.budgetRate.
local function peakCap()
	local frames = math.floor(60 / EP.budgetRate() + 0.5)
	if frames < 1 then frames = 1 end
	return COST_GHOST * frames
end

--- Which registry the cursor is in.  Sources first, because rememberBarrelFluid decides
--- which liquid a barrel belongs to and the mirrors settled in stage 2 read that answer.
--- The collector stage is also what used to be `EveryHours -> reviewPumps`.  There is no
--- clock left in this mod at all now: a generator running dry, a generator breaking and the
--- town supply reaching its shutoff day are all noticed by the cursor coming round, exactly
--- like every other autonomous change.  The hour was never a cadence anybody needed - it
--- was the cheapest approximation available when the alternative was a whole-registry pass.
--- THREE STAGES, NOT FOUR.  The collector stage does both collector jobs.
---
--- There were separate SOURCES and PUMPS stages and they walked the same registry, one
--- after the other, each paying its own EP.sourceAt - a grid lookup and a walk of the
--- square's objects - for the same barrel twice a lap.  Remembering what a barrel holds and
--- noticing that its pump moved are two questions about one object, and one lookup answers
--- both.
---
--- There is only so much that genuinely needs walking: the collectors, the mirrors, the
--- fixtures that have not got a mirror yet, and the objects the supply FILLS.  Anything
--- queued beyond that is the loop being longer than the job.
---
--- THE LISTED FIXTURES COME LAST, AFTER THE MIRRORS, and the order is not arbitrary.  A
--- top-up charges barrels, which makes every mirror over them stale - so it hands the whole
--- group to EP.afterGroupCharged and settles them on the spot.  Running it before the
--- mirror stage would mean settling them twice a lap: once out of this stage's fan-out and
--- again when the cursor reached them.  Last means the fan-out lands on mirrors the lap has
--- already been past, and the next lap finds nothing to do.
local STAGE_SOURCES, STAGE_GHOSTS, STAGE_FIXTURES, STAGE_FED = 1, 2, 3, 4

local cursor = {
	stage = STAGE_FED,        -- so the first step wraps round into a fresh lap
	at    = 1,
	list  = {},
	drift = false,
}

--- How many complete laps the cursor has finished.
---
--- Exposed because "has the world been brought up to date" is no longer a question with a
--- synchronous answer, and the test harness has to be able to ask it.  See SWEEP() in
--- lgep_stub.lua, which drives real ticks until this moves rather than calling the sweep
--- directly - a helper that called the batch would be testing a path the game never takes.
EP.maintenanceLaps = 0

--- A registry flattened into a list the cursor can hold an index into across ticks.
---
--- It has to be a flat array and that is forced, not stylistic: Kahlua has no `next`, so a
--- `pairs` traversal cannot be suspended at the end of one tick and resumed on the next.
--- Taken once per stage rather than per tick, which is also what makes it safe to walk
--- while the mod files things - discover() and serviceFixtureAt both add to these tables.
---
--- This is the one part of a lap that is O(N) in a single tick, and it is deliberately the
--- cheap part: a table constructor per entry, no grid lookups and no Java crossings.
local function flatten(registry)
	local list = {}
	for key, pos in pairs(registry) do
		list[#list + 1] = { key = key, x = pos.x, y = pos.y, z = pos.z, pool = pos.pool }
	end
	return list
end

--- IS THAT ADDRESS STILL LOADED, asked once per CHUNK rather than once per entry.
---
--- Two registries -- `fixtures` and `fed` -- are filled by walking the world for a KIND of
--- object rather than by anything the player did: every sink, bath and washing machine
--- carrying `waterPiped`, and every water dispenser the map ships.  Both fill at a steady
--- rate as chunks stream (measured: 0.22 fixtures per chunk) and NEITHER ever gave an entry
--- back, so both were bounded by everywhere the player had ever been rather than by what was
--- loaded.  Over a long server's life that is unbounded growth in a table walked every lap.
---
--- The obvious place to release one is `ReuseGridsquare`, and it is the wrong place: it
--- fires for every square of every departing chunk, so anything there is a per-square cost
--- on the streaming path -- the very cost S2 above was removing.  Its own comment says so.
---
--- So it is done here instead, on the lap, where the walk is happening anyway.  The probe is
--- one `getGridSquare` per distinct (chunk, level) rather than per entry, because addresses
--- cluster: 2,000 fixtures over 250 chunks is 250 crossings once per lap, not 2,000.
---
--- Re-filing costs one `poolOf` when the chunk comes back, which is what `notice()` pays for
--- any fixture it has not seen -- and since the relaxIndex work that is a bounded lookup
--- rather than the linear plan scan the original objection was written against.
---
--- DELIBERATELY NOT USED FOR `sources` OR `ghosts`.  Those two are bounded by what a player
--- actually built, and a ghost carries a LEDGER: forgetting its address is not the same
--- cheap act as forgetting a sink's.
--- `keep` is optional and is asked only of entries that are still loaded, so a stage can
--- decline to QUEUE something without that being mistaken for the address having gone.  One
--- closure per lap, which is nothing; a predicate per entry would be the allocation this is
--- trying to avoid.
local function flattenLoaded(registry, forget, keep)
	local cell = getCell()
	local list, chunkLoaded = {}, {}
	local gone = nil

	for key, pos in pairs(registry) do
		-- Chunk and level together: one chunk spans every z, but getGridSquare also answers
		-- nil for a level the chunk does not have, and the two must not be confused.
		local ck = (math.floor(pos.x / 8) * 4096 + math.floor(pos.y / 8)) * 64 + (pos.z + 32)
		local loaded = chunkLoaded[ck]
		if loaded == nil then
			loaded = cell:getGridSquare(pos.x, pos.y, pos.z) ~= nil
			chunkLoaded[ck] = loaded
		end

		if loaded then
			if not keep or keep(key, pos) then
				list[#list + 1] = { key = key, x = pos.x, y = pos.y, z = pos.z, pool = pos.pool }
			end
		else
			-- Collected and removed after, never inside the traversal: pruning a table while
			-- walking it is what crashed reviewPumps, and the note there says so.
			gone = gone or {}
			gone[#gone + 1] = key
		end
	end

	if gone then
		for i = 1, #gone do forget(gone[i]) end
	end
	return list
end

--- Everything that used to be decided once per sweep, decided once per lap.
local function beginLap()
	EP.maintenanceLaps = EP.maintenanceLaps + 1

	-- The re-entrancy guard is raised and lowered around a pair of Java calls, so it can
	-- only be left up by one of them throwing.  Lua has no finally; being stuck up would
	-- silently stop every drink from being charged to a barrel again.
	EP.settling = false

	-- A new lap, so anything swept for a previous one is no longer an answer about now.
	--
	-- The purse is refilled here as well, so a sweep left half done by a player action is
	-- carried on by the lap rather than waiting for the player to click again.  The cursor
	-- itself never reaches discover() -- serviceFixtureEntry asks with mayDiscover false --
	-- so this only ever finishes work somebody else started.
	swept = nil
	sweepPurse = DISCOVER_PER_PASS

	-- AND THE PUMP LATCH, for the same reason `EP.settling` is rescued here: it is raised
	-- around calls that can throw, and a throw that escaped one of the pcalls around
	-- `EP.serviceAround` would leave it up for the session - every later `EP.reviewPumps`
	-- returning at its first line, so a generator stopping would stop re-pointing fixtures
	-- for good. A lap is the one place that knows nothing is in flight.
	reviewing = false

	-- WHETHER THERE IS ANYTHING TO SETTLE.
	--
	-- With nothing falling and no petrol standing about, every way water can move
	-- announces itself and has already been settled on the spot by OnWaterAmountChange.
	-- In a dry world this is what makes a lap almost free.
	local weather, why = silentDriftPossible()
	cursor.drift = weather or settleWanted

	-- Cleared HERE, at the top of the lap that will act on it, and not at the bottom.
	-- Something that raises it midway through a lap has not been covered by that lap - the
	-- cursor is already past most of the registry - so the flag must survive to be seen by
	-- the NEXT one.  Clearing at the end would drop exactly those.
	settleWanted = false

	if cursor.drift then
		EP.log("settling: " .. (weather and tostring(why) .. " can move water with no event"
			or "the world changed under a mirror"))
	end
end

--- Move to the next stage, taking its list.
local function enterStage(stage)
	cursor.stage = stage
	cursor.at = 1

	if stage == STAGE_SOURCES then
		-- Ungated, like the settle.  This used to run only when the weather said a barrel
		-- could have changed unannounced, which made a barrel's recorded liquid depend on
		-- the same accessor that turned out to be wrong.  It is one grid lookup per
		-- collector per lap; the queue can carry it.
		cursor.list = flatten(sources)
	elseif stage == STAGE_GHOSTS then
		cursor.list = flatten(ghosts)
	elseif stage == STAGE_FED then
		-- EVERY ONE OF THEM, EVERY LAP, unlike the fixture stage below, and the difference is
		-- what each stage is looking for.  That one hunts a fixture with no mirror, which is
		-- a state something else already recorded - so it can queue only the broken ones.
		-- This one is asking "is it full", and the only thing that knows is the container: a
		-- player drinking from a dispenser moves the level with nothing to say so on the
		-- authority, exactly like rain landing in a barrel.  There is no flag to queue by.
		--
		-- It is the same price as a settled collector.  A full dispenser costs one grid
		-- lookup, one object walk and two container reads, which is what the collector stage
		-- pays per barrel to ask what it is holding.
		-- PRUNED AS IT GOES, because `fed` is the other registry the world fills for
		-- itself: every water dispenser the map ships is filed by notice(), map-placed
		-- ones carry `Base.WaterDispenser` and answer isFedFixture, and nothing ever gave
		-- one back.  topUpFedEntry drops an address whose square holds nothing listed, but
		-- it cannot drop one whose CHUNK has closed - it returns early on exactly that.
		cursor.list = flattenLoaded(fed, forgetFed)
	else
		-- ONLY THE FIXTURES THAT HAVE NOT GOT A MIRROR ARE QUEUED AT ALL.
		--
		-- Making the check cheap was not enough.  A served fixture still occupied a place
		-- in the queue and still cost a step to skip, so a settled town queued two hundred
		-- and fifty-six of them every lap to discover, two hundred and fifty-six times, that
		-- there was nothing to do.  That is the loop being longer than the job.
		--
		-- In a settled base this list is EMPTY and the stage costs one stage change.  It
		-- fills only when something really is unserved: a fixture whose building has just
		-- gained its first barrel, one whose mirror was removed by a repair, or the residue
		-- no event covers - which is exactly what this stage was always for.
		--
		-- Everything a player does still has its own instant path and does not wait for
		-- this: placing a collector, right-clicking a tap and a pump moving all reach
		-- serviceFixtureAt directly.  This is the backstop, and a backstop should be
		-- proportional to what is actually broken rather than to how much is fine.
		-- NOTHING CAN BE SERVED IF THERE IS NO COLLECTOR AT ALL, so do not walk the registry
		-- at all -- not even to prune it.
		--
		-- The walk below is O(N) over the whole fixture registry and allocates a key string
		-- per entry, in ONE tick, charged one flat COST_STAGE_CHANGE - one unit of purse for
		-- N units of work.  The note above says "in a settled base this list is EMPTY", and
		-- that is right and exactly inverted in the state the reports describe: with nothing
		-- plumbed NO fixture has a mirror, so every entry is queued and the list is maximal.
		--
		-- And `fixtures` is not a record of what the player plumbed - it is filed from every
		-- object carrying `waterPiped`, which is every sink, bath and washing machine the
		-- player has streamed past, and it never shrinks.  Measured at 1.2 ms for 200 of
		-- them, 5.9 ms for 2,000 and 8.7 ms for 5,000, on a regular period, which is what a
		-- player reports as a periodic stall.
		--
		-- Costs nothing to be wrong: serviceFixtureEntry refuses every entry on the same
		-- fact one step later, so this removes work and no outcome.  A collector arriving
		-- raises worldChanged() in notice(), which is what brings the cursor back round.
		if sourceCount == 0 then
			cursor.list = {}
			return
		end

		-- THE LOCALITY TEST GOES FIRST, BEFORE THE KEY IS BUILT.
		--
		-- The `ghosts[...]` test needs an EP.key, which is a string allocation, and it was
		-- being paid for EVERY entry in the registry on every lap -- including the great
		-- majority that no collector could ever reach.  `sourceNear` answers that in at most
		-- nine numeric table lookups and allocates nothing, so ordering it first means a
		-- fixture out of reach of every barrel in the world costs nine lookups a lap instead
		-- of a string and a table.
		--
		-- Same answer either way: serviceFixtureEntry refuses on exactly this test one step
		-- later, so anything skipped here was going to be refused there.
		--
		-- And the walk PRUNES: an address whose chunk has closed is dropped rather than
		-- carried for the rest of the session.  See flattenLoaded.
		-- NOTHING HAS CHANGED SINCE THE LAST BUILD, so there is nothing to build.
		--
		-- Both counters, because two different things can make a refused fixture worth
		-- asking about again: the supply moved (a barrel, a pump), or the registry moved (a
		-- fixture filed or forgotten).  Neither moving means every entry would answer
		-- exactly as it did last lap, and the walk is O(N) over a registry that holds every
		-- sink the player has ever passed.
		if fixtureQueueSupply == supplyVersion and fixtureQueueEpoch == fixturesEpoch then
			cursor.list = {}
			return
		end
		fixtureQueueSupply, fixtureQueueEpoch = supplyVersion, fixturesEpoch

		local reach = EP.getOption("Reach")
		cursor.list = flattenLoaded(fixtures, forgetFixture, function(key, pos)
			-- ALREADY ASKED, AND NOTHING HAS CHANGED SINCE.  Cheapest first: one number
			-- compare, no lookup and no allocation.  See supplyVersion.
			if pos.triedAt == supplyVersion then return false end
			-- THE SAME GATE AS serviceFixtureEntry'S, AND IT HAS TO LEARN PIPES TOO.  This is
			-- an earlier copy of that test, run when the queue is built, so a fixture it drops
			-- never reaches the one below: a piped house with no barrels of its own was
			-- filtered out HERE, before the gate that knew about networks was ever asked.
			-- lgep_spec_pipes section 2 is that case.  The union box keeps it to four
			-- comparisons for every fixture no network is near.
			if not sourceNear(pos.x, pos.y, reachForStructure(pos.x, pos.y, pos.z))
				and not (EP.pipeFixtureSupplied and EP.pipeFixtureSupplied(pos.x, pos.y, pos.z)) then
				return false
			end
			return not ghosts[EP.key(pos.x, pos.y, pos.z + 1)]
		end)
	end
end

--- Spend this tick's budget.
---
--- Returns how many entries it actually got through, which is what the tick-budget suite
--- asserts against - the claim being defended is "no tick exceeds one step's purse", and a
--- claim about per-frame cost has to be measured per frame rather than in a total.
--- THE SETTLE, SPREAD OVER TICKS.
---
--- This is the last thing in the mod whose cost was unbounded in a number a player
--- controls.  A mirror's settle is linear in the barrels feeding it, and the locality bound
--- cannot help when they are all genuinely in the one building: measured at 6,025 operations
--- for six hundred barrels, in one frame, and there is nothing stopping somebody having a
--- thousand.  Spacing it out only decided how OFTEN that frame happened.
---
--- So the walk that finds the group is now resumable, and the cursor drives it a few
--- candidates at a time.  Two properties make that safe, and neither is an accident:
---
---   THE WALK ONLY READS.  Nothing is written to a barrel, a mirror or the registry while
---   it is in progress, so a walk abandoned half way leaves the world exactly as it found
---   it.  The one write it can make - pruning a collector that has gone - is deferred to
---   the end, and cannot affect a group it was never in.
---
---   THE APPLY IS STILL ATOMIC.  Everything that moves water happens in one frame, at the
---   end, from a group and a summary that were assembled under a single epoch.  A tap is
---   never seen half-settled, because nothing is published until it is all decided.
---
--- What the walk buys beyond spreading: it accumulates the summary as it goes, so the
--- atomic half no longer walks the members either.  See EP.summariseGroup.
---
--- PER SECOND, like everything else on this cursor.  It was 24 candidates a step, and a
--- step was every four ticks - 360 a second on a client, 60 on a server.  A hoarder's base
--- of eight hundred barrels is one mirror in two seconds at the first figure and thirteen
--- at the second, which is most of why a big base on a dedicated server looked stuck.
local WALK_PER_SECOND = 360

local walk = nil
local pendingSettle = nil

local function deferSettle(ghost)
	pendingSettle = ghost
end

--- Is a settle being assembled right now, and for which mirror?
---
--- Exposed for two reasons.  A deliberate settle has to be able to ABANDON the walk for the
--- mirror it just brought up to date - see EP.abandonWalkFor - and a diagnostic has to be
--- able to ask what the cursor is in the middle of without guessing from timings.
function EP.walkingGhost()
	return walk and walk.ghost or nil
end

--- Throw away the walk in progress for this mirror, because something just settled it
--- completely and by hand.
---
--- THE HAZARD THIS CLOSES.  A walk reads its members over many ticks and applies the total
--- at the end.  A right-click settles the same mirror at once, from live reads.  If the two
--- overlap - and with two hundred barrels the walk is open for tens of ticks, so they will -
--- the walk lands afterwards and writes ITS total, assembled partly from reads taken before
--- the click, straight over the fresh one.  The tap updates and then goes backwards, and the
--- player waits another lap for a number they already had.
---
--- The walk epoch does not cover this and should not: it is bumped by things that change WHO
--- IS IN a group, and a right-click changes what the mirror HOLDS.  Different question, and
--- conflating them would make every click discard every walk in the world.
---
--- Only the walk for THIS mirror is dropped.  Abandoning all of them would let a room full
--- of players right-clicking hold the cursor open for ever, which is a livelock rather than
--- a bug.  Nothing is lost by dropping it: the mirror has just been settled correctly, which
--- is what the walk was trying to achieve.
function EP.abandonWalkFor(ghost)
	if walk and ghost and walk.ghost == ghost then walk = nil end
end

--- Drop whatever walk is open, for a change too wide to name one mirror.
---
--- A collector joining or leaving the pool changes group membership for every fixture in the
--- building, and `walkEpoch`'s own header lists exactly that as something a walk in flight
--- must not survive. Dropping the one open walk rather than bumping the epoch keeps the
--- refusal memory - which the epoch also clears - and costs one restarted walk per wrench job.
function EP.abandonWalkNow()
	walk = nil
end

local function beginSettleWalk(ghost)
	local data = ghost:getModData()
	local fx, fy, fz = data[EP.KEY_FIX_X], data[EP.KEY_FIX_Y], data[EP.KEY_FIX_Z]
	if type(fx) ~= "number" or type(fy) ~= "number" or type(fz) ~= "number" then
		-- No fixture address, so there is no group to find.  Handled the old way; this is
		-- a repair state, not a hot path.
		EP.settleOrSleep(ghost)
		return nil
	end

	return { ghost = ghost, w = EP.beginGroupWalk(fx, fy, fz, EP.ghostFluidType(ghost)) }
end

--- Advance the settle in progress.  Returns true when the ghost stage is free again.
local function stepSettleWalk(budget)
	if not walk then return true end

	-- ABANDONED IF THE WORLD MOVED UNDER IT.  See walkEpoch: a group half-read from before
	-- a change and half from after describes a world that never existed, and in this mod
	-- that is duplicated or vanished water rather than an odd number.  Dropped rather than
	-- restarted, because whatever bumped the epoch raised settleWanted with it - so the
	-- next lap is already going to settle this mirror, and restarting here would only race
	-- the same change again.
	if walk.w.epoch ~= EP.walkEpochNow() then
		walk = nil
		return true
	end

	if not EP.stepGroupWalk(walk.w, budget) then return false end

	local group = walk.w.group
	local summary = walk.w.summary
	local ghost = walk.ghost
	-- Taken here, with the rest of the walk's results, because `walk` is cleared below
	-- before any of them are used.
	local supply = walk.w.supply
	local spoken = walk.w.spoken
	-- How much of the scope this walk could not see.  Retirement is the only reader; see
	-- retireIfUnsupplied for why `supply == 0` on its own is not an answer.
	local unresolved = walk.w.unresolved

	-- What the walk actually cost, published where the pacing reads it.  This used to be
	-- set by supplyGroup, and deferring the settle silently emptied it: every cursor settle
	-- reported nought considered, so every one of them earned no rest and SPREAD_PER_SECOND
	-- stopped doing anything at all.  A pacing rule fed by a counter nobody updates is
	-- indistinguishable from no pacing rule.
	EP.lastConsidered = walk.w.considered

	-- The rest this walk earned, worked out in SECONDS and then converted to ticks of this
	-- machine.  Deliberately not EP.ticksFor, which floors at one: a three-barrel cottage
	-- walks three candidates and has earned no rest at all, and rounding that up to a tick
	-- would space every ordinary base out for nothing.
	local rate = EP.ticksPerSecond()
	local rest = math.floor(walk.w.considered / SPREAD_PER_SECOND * rate)
	local cap = math.floor(MAX_REST_SECONDS * rate)
	if rest > cap then rest = cap end
	if rest > restTicks then restTicks = rest end

	walk = nil

	-- The whole of the mutation, in this one frame, from a group and a summary assembled
	-- under a single epoch.
	--
	-- The summary is the WALK's, gathered as it went, which is what makes the apply flat in
	-- barrels-per-building instead of linear.  It is very slightly stale by construction:
	-- its reads are spread over many ticks and rain can have landed since the first of
	-- them.  That is the one direction it is safe to be wrong in - rain only ADDS, so an
	-- old reading UNDER-reports, the water is still in the barrels, and the next lap finds
	-- it.  Over-reporting is the direction that would invent water, and only a deliberate
	-- movement can produce it: those raise OnWaterAmountChange, which bumps the epoch and
	-- throws this walk away before it can be applied.
	--
	-- RETIREMENT IS ASKED FIRST, and this is the one place in the mod that can ask it: the
	-- walk that has just landed is what counted the building's plumbing, and the cursor owns
	-- its own frame - unlike OnWaterAmountChange and OnObjectAboutToBeRemoved, which are
	-- raised from inside the engine's own iteration over a square and may not remove
	-- anything.  Those two go on sleeping a mirror that has run out of supply, exactly as
	-- before; this is where a mirror that has run out of PLUMBING is taken away.
	--
	-- It is asked on every settle rather than only on an empty group, because it is also
	-- what clears the latch when a building's plumbing comes back.
	if retireIfUnsupplied(ghost, supply, unresolved) then return true end

	EP.settleOrSleep(ghost, group, summary, spoken > 0)
	return true
end

local function stepCursor(budget)
	-- Resolved on first use rather than up front.  A tick that only changes stage does no
	-- grid work at all, and this is a Java crossing - paying it unconditionally meant
	-- crossing into the engine sixty times a second to hand the result to nobody.
	local cell
	local spent = 0

	local walkBudget = perStep(WALK_PER_SECOND, stepGap())

	-- A settle in progress owns the step until it is done.
	--
	-- A walk that FINISHES here no longer ends the step, and that is what lets a machine
	-- with a bigger per-step purse buy more mirrors with it rather than one either way.  It
	-- is charged COST_GHOST for the mirror it just landed, so at sixty ticks a second -
	-- where the purse IS COST_GHOST - the loop below does not run and the behaviour is
	-- exactly what it was.
	if walk then
		if not stepSettleWalk(walkBudget) then return budget end
		spent = COST_GHOST
	end

	while spent < budget do
		if cursor.at > #cursor.list then
			-- A stage change costs budget even though it does almost no work.  Without
			-- that, a world with three empty registries would spin this loop advancing
			-- stages until the purse was spent on nothing, once a tick, for ever - and an
			-- empty world is the commonest case there is.
			spent = spent + COST_STAGE_CHANGE

			local nextStage = cursor.stage + 1
			if nextStage > STAGE_FED then
				nextStage = STAGE_SOURCES
				beginLap()
			end
			enterStage(nextStage)
		else
			local cost = COST_FIXTURE
			if cursor.stage == STAGE_SOURCES then
				cost = COST_SOURCE
			elseif cursor.stage == STAGE_GHOSTS then
				cost = COST_GHOST
			elseif cursor.stage == STAGE_FED then
				cost = COST_FED
			end

			-- Checked before the entry is taken.  See UNITS_PER_SECOND: this is what makes the
			-- bound strict rather than approximate, and it is the difference between "a
			-- tick costs at most one mirror" and "a tick costs at most one mirror plus
			-- whatever it had already done".  `spent > 0` so an entry that costs the whole
			-- purse can still run on a fresh tick rather than deadlocking the cursor.
			if spent > 0 and spent + cost > budget then break end

			local entry = cursor.list[cursor.at]
			cursor.at = cursor.at + 1
			spent = spent + cost
			cell = cell or getCell()

			if cursor.stage == STAGE_SOURCES then
				-- ONE lookup, both questions.  See the stage list above.
				local source = EP.sourceAt(entry.x, entry.y, entry.z)

				-- A BARREL CAN STOP BEING A SUPPLY, AND START AGAIN, WITH NO EVENT EITHER WAY.
				--
				-- Extended Electricity stamps LGEEFuel on a drum somebody runs a fuel line off,
				-- and EP.isWaterSource refuses anything carrying it - deliberately, because a
				-- vessel does one job or the other.  Taking the line off again clears the key.
				-- Neither write raises anything this mod hears, and neither moves the object, so
				-- without this the barrel leaves the supply on the next settle and never comes
				-- back into it: the tap it used to feed is refused, the refusal is REMEMBERED
				-- against supplyVersion, and nothing bumps that counter.  Reported on the
				-- Discussions on 2026-08-18 as a barrel whose water would not come back.
				--
				-- The same shape covers an operator adding an id to FedFixtures mid-save, and any
				-- other mod that takes a vessel over by writing to it.
				--
				-- FREE IN THE ORDINARY DIRECTION: a barrel that is still a barrel costs one table
				-- read against a lookup this stage was making anyway.  The second lookup is paid
				-- only where the first came back empty.
				--
				-- AND AN UNLOADED CHUNK IS NOT A CHANGE.  This stage queues every address, loaded
				-- or not, so `sourceAt` answers nil for a barrel that has merely streamed out -
				-- and flipping on that would bump supplyChanged() for every barrel a moving
				-- player leaves behind, which is the one thing the refusal memory's own note says
				-- must not happen.  EP.collectorPresence is what tells "gone" from "cannot see".
				--
				-- TRI-STATE, so that the FIRST sighting of an address is recorded and not
				-- announced.  `qualified` is a plain table in this process, so every barrel in a
				-- freshly loaded world would otherwise read as "it changed" on lap one and bump
				-- the counters once apiece.  A change is only a change against something this
				-- process has already seen; a world being loaded is notice()'s business, and it
				-- bumps supplyChanged() itself for every collector it files.
				local seen = qualified[entry.key]
				local now = source ~= nil
				if not now and EP.collectorPresence(entry.x, entry.y, entry.z) == EP.AT_UNLOADED then
					-- Cannot see it.  Nothing is concluded and nothing is recorded - this is the
					-- whole of what keeps a moving player from flipping every address behind them.
				elseif seen == nil then
					qualified[entry.key] = now
				elseif seen ~= now then
					qualified[entry.key] = now
					supplyChanged()
					worldChanged()
					EP.log(("the collector at %d,%d,%d %s the water supply"):format(
						entry.x, entry.y, entry.z,
						now and "is back in" or "has been taken out of"))
				end

				if source then
					EP.rememberBarrelFluid(source)
					-- Charged after the fact like the fixture stage: a pump that has not
					-- moved is a boolean compare, and one that has re-services a building.
					if EP.reviewPumpEntry and EP.reviewPumpEntry(entry, source) then
						spent = budget
					end
				end
			elseif cursor.stage == STAGE_GHOSTS then
				-- Always inspecting, where the batch inspected a sixth per pass.  The
				-- cursor is the rotation now, so the slice it needed is gone.
				--
				-- The REPAIRS run here and now - they are a handful of table reads apiece
				-- and there is nothing to gain by spreading them.  What is deferred is the
				-- settle, which is the only part whose cost depends on how many barrels
				-- feed the mirror.  `pendingSettle` is what the seam hands back.
				pendingSettle = nil
				settleMirrorSquare(entry, true, cursor.drift, cell, deferSettle)

				-- The rest is charged where the walk FINISHES, not here.  See
				-- stepSettleWalk: this branch no longer knows what the settle will cost,
				-- because it no longer does the settle.

				-- A mirror that wants settling stops the cursor here and takes over the
				-- ghost stage until its walk is finished.  `cursor.at` was already
				-- advanced past it, which is right: the walk holds the ghost itself.
				if pendingSettle then
					walk = beginSettleWalk(pendingSettle)
					pendingSettle = nil

					-- TRIED TO FINISH IN THIS STEP, and for most mirrors it does.
					--
					-- Without this a mirror always cost TWO steps - one to inspect it and
					-- hand the walk over, another to run the walk - which doubled the
					-- length of a lap for every mirror in the world, including the great
					-- majority whose group is three barrels and whose walk finishes
					-- instantly.  The spreading is there for the hoarder's base; it should
					-- not be charged to the cottage.
					--
					-- The peak is not affected.  A ghost step costs COST_GHOST, which is
					-- the whole purse at sixty ticks a second, so the step was ending
					-- here either way; what changes is only whether the walk waits a
					-- tick before starting.  A group too big to finish returns false and
					-- carries on next step exactly as before.
					--
					-- ONLY AN UNFINISHED WALK ENDS THE STEP NOW.  One that lands inside
					-- it falls through to the loop condition, which stops on the purse
					-- like every other entry - so a machine whose frames are six times
					-- longer settles about six times as many mirrors in one, instead of
					-- one either way.  See the note at the head of stepCursor.
					if walk and not stepSettleWalk(walkBudget) then return spent end
				end
			elseif cursor.stage == STAGE_FED then
				-- Charged after the fact for the same reason the fixture stage is: a full
				-- dispenser is two container reads and one that has room is a whole
				-- supplyGroup plus a charge that fans out over every mirror in the building.
				-- Spending the rest of the purse ends the tick here, so at most one listed
				-- fixture is ever filled in a frame.
				if topUpFedEntry(entry, cell) then spent = budget end
			else
				-- Charged after the fact, because a fixture is a table read when it
				-- already has its mirror and a whole supplyGroup when it does not.  See
				-- the note on serviceFixtureEntry.  Spending the rest of the purse ends
				-- the tick here, so at most one fixture is ever serviced in a frame.
				if serviceFixtureEntry(entry, cell) then spent = budget end
			end
		end
	end

	return spent
end

--- The one place maintenance runs from.
---
--- OnTick is raised on a dedicated server exactly as it is on a client: GameServer
--- constructs an IngameState (GameServer.java:824) and calls statex.update() every cycle
--- (:1001), and UpdateStuff() sits inside it.  The one gate is `if (!this.paused ||
--- GameClient.client)`, and a server is only paused with no players connected and
--- PauseEmpty on - which is the one time there is nothing to maintain.
---
--- Guarded, and it has to be: this runs sixty times a second, so an unguarded throw is
--- sixty stack traces a second through ExceptionLogger for the rest of the session, and
--- the log it buries is the one somebody needs to read.
--- THE DIAGNOSTIC DUMP, and nothing else.
---
--- This is what is left of the ten-minute handler, and it was always a log rather than
--- maintenance - it ran at the foot of sweep() behind an EP.debugging() gate.  It stayed on
--- a ten-minute cadence rather than moving to the cursor for the obvious reason: the cursor
--- laps every few seconds, and a per-mirror dump at that rate would bury the log it exists
--- to fill.
---
--- It resolves every mirror's group, which is real work, so it is behind the gate and the
--- gate is checked before anything is assembled.
Events.EveryTenMinutes.Add(function()
	if not EP.isAuthority() then return end
	if not EP.debugging() then return end

	local ok, err = pcall(function()
		local cell = getCell()

		-- The first thing to look at when nothing is happening: if this says 0
		-- collectors, the problem is discovery and not plumbing, and the fixture
		-- count says whether the registry is being filled at all.
		EP.log(("state: %d collectors, %d fixtures, %d ghost squares, %d topped-up, %d cursor laps"):format(
			EP.count(sources), EP.count(fixtures), EP.count(ghosts), EP.count(fed),
			EP.maintenanceLaps))

		-- One line each, and it is the first thing to look at when somebody says a dispenser
		-- is not filling: the level against the capacity says whether it is working, and a
		-- dispenser that is not in this list at all means the id on the sandbox option does
		-- not match what the object is actually called.
		for _, pos in pairs(fed) do
			local sq = cell:getGridSquare(pos.x, pos.y, pos.z)
			local object = EP.fedOnSquare(sq)
			local fc = object and object:getFluidContainer() or nil
			EP.log(("  topped-up @%d,%d,%d %s water=%.1f/%.1f"):format(
				pos.x, pos.y, pos.z,
				object and tostring(object:getEntityFullTypeDebug()) or "(gone)",
				fc and fc:getAmount() or 0, fc and fc:getCapacity() or 0))
		end

		-- Every mirror, in full.  Guessing from the outside has cost more than one
		-- wrong fix: what matters is whether a mirror still knows which fixture it
		-- belongs to, how many collectors it is currently standing for, how much they
		-- hold between them, and whether it owes anything.  One line per mirror
		-- answers all of it at once.
		for _, pos in pairs(ghosts) do
			local sq = cell:getGridSquare(pos.x, pos.y, pos.z)
			for _, gh in ipairs(EP.ghostsOnSquare(sq)) do
				local d = gh:getModData()
				local grp = EP.groupForGhost(gh) or {}
				local reserves = 0
				for i = 1, #grp do
					if grp[i].reserve then reserves = reserves + 1 end
				end
				EP.log(("  mirror @%d,%d,%d fix=%s,%s,%s group=%d (%d reserve) dormant=%s debt=%.2f water=%.1f/%.1f"):format(
					pos.x, pos.y, pos.z,
					tostring(d[EP.KEY_FIX_X]), tostring(d[EP.KEY_FIX_Y]), tostring(d[EP.KEY_FIX_Z]),
					#grp, reserves, tostring(EP.isDormant(gh)),
					EP.ghostDebt(gh),
					gh:getFluidAmount(), gh:getFluidCapacity()))
			end
		end
	end)
	if not ok then
		EP.logFault("plumb-dump-state", "ERROR dumping state: " .. tostring(err))
	end
end)

--- THE SCALE THE FIGURES HAVE TO BE READ AGAINST, and for this mod it is the collector
--- count that matters most.
---
--- A drink costing forty milliseconds means one thing over a cottage with three collectors
--- and another over a base with eight hundred, and the measurement that started this work
--- (plans/rewrite-scoping-2026-08-16.md) is linear in exactly that number.  Printing it
--- beside the timings is what lets a report from a player be placed on the curve instead of
--- guessed at.
---
--- A hook rather than a print, because the window that calls it lives in the shared file -
--- see EP.reportPerfWindow.  This side owns the registries; a client has none and prints
--- no scale line at all, which is the honest thing for it to do.
--- POOLED AND POOL-LESS ARE COUNTED SEPARATELY, because they are two different costs.
---
--- A fixture with a pool asks `srcPool[pool]` - the collectors of its own building - and an
--- empty answer settles it.  A fixture with NO pool has to ask the world, and a
--- player-built structure has no pool at all on a dedicated server, nor in any mode when it
--- is raised within a tile of a map building.  So "how many of them are pool-less" is what
--- decides how much the fixture stage costs on a real save, and nothing could say.
---
--- Counted here rather than maintained, because this runs only when somebody has turned
--- Debug on and asked.
EP.perfScale = function()
	local pooled, loose = 0, 0
	for _, entry in pairs(fixtures) do
		if entry.pool then pooled = pooled + 1 else loose = loose + 1 end
	end
	return ("scale: %d collectors, %d mirrors, %d fixtures (%d pooled, %d loose), %d fed"):format(
		EP.count(sources), EP.count(ghosts), EP.count(fixtures), pooled, loose, EP.count(fed))
end

-- EP.maintenanceIdle is declared in LGEPCore, above every gate, because it has to be true
-- on the sides that never reach this file.  Only its per-tick maintenance is here.

--- The Reach the maintenance loop last worked against.  nil until the first enabled tick.
---
--- A REACH CHANGE IS A SCOPE CHANGE, AND NOTHING ELSE TOLD THE LOOP ABOUT IT.  The fixture
--- queue is rebuilt only when supplyVersion or fixturesEpoch moves, and its locality filter is
--- `sourceNear(pos.x, pos.y, reach)` - so a sink 14 tiles from its barrel, dropped at Reach 12,
--- stayed dropped after an operator raised Reach to 64, on every side, until somebody
--- right-clicked the tap.  That is the standing advice for BR-LGEE-005 and BR-LGEP-003, and it
--- did nothing in the background even on a server where the option itself was live.
--- Lowering it is the same fact the other way: a group assembled at the old Reach describes a
--- scope that no longer exists, so a walk in progress is thrown away and every mirror settles.
local seenReach = nil

Events.OnTick.Add(function()
	-- THE TICK RATE AND THE REPORTING WINDOW ARE NOT SAMPLED HERE ANY MORE.
	--
	-- Both moved to the OnTick handler in LGEPCore, and the reason is one this file's own
	-- header states without following: `if isClient() then return end` at the top means a
	-- multiplayer client never registers this handler at all.  Anything a client needs
	-- doing every tick therefore cannot live in this file - and both of those are things a
	-- client needs, the rate because it is a property of the machine and the window because
	-- the client's own handlers are timed under the same names and were being collected and
	-- never printed.
	--
	-- LGEPCore is required by this file, so its handler is registered first and runs first,
	-- which is what sampleTick has always needed.

	EP.maintenanceIdle = true
	if not EP.isAuthority() then return end

	if not EP.getOption("Enabled") then
		if EP.any(ghosts) then
			local ok, err = pcall(teardown)
			if not ok then
				EP.logFault("plumb-teardown", "ERROR tearing down: " .. tostring(err))
			end
		end
		return
	end

	-- One option read a tick, beside the Enabled read above; a change is an operator's act and
	-- happens a handful of times in the life of a save.  See seenReach.
	local reach = EP.getOption("Reach")
	if reach ~= seenReach then
		if seenReach ~= nil then
			EP.log("Reach changed from " .. tostring(seenReach) .. " to " .. tostring(reach)
				.. "; asking every fixture again")
			supplyChanged()
			worldChanged()
			if EP.reg then EP.reg.invalidate() end -- [Malcolm_Perf] reach boxes moved
		end
		seenReach = reach
	end

	-- NOTHING FILED AT ALL, SO THERE IS NOTHING TO MAINTAIN.
	--
	-- This is the commonest state there is and it was the most wasteful.  With all three
	-- registries empty the cursor still churned: every tick it spent its whole purse
	-- changing stage, flattening three empty tables and wrapping the lap - measured at
	-- 2.7 complete laps PER TICK, for ever, on a world with no plumbing in it.  None of
	-- that showed in the operation counters because none of it crosses into Java, which is
	-- exactly why it survived being measured the first time.
	--
	-- Three O(1) tests instead.  EP.any stops at the first key rather than counting, so
	-- this is a handful of table reads and no allocation at all.  Nothing can be missed by
	-- idling here: something has to be FILED before it can need maintaining, and the two
	-- things that file - LoadGridsquare and OnObjectAdded - both raise settleWanted on the
	-- way past.
	--
	-- `fed` is in the test for the case it exists for: an office with dispensers in it and
	-- barrels on the roof has collectors filed and would have woken anyway, but a building
	-- whose ONLY plumbing is a dispenser has nothing in the other three - and a dispenser
	-- with no supply is exactly what the cursor has to keep looking at, because the supply
	-- can arrive later.
	--
	-- `fixtures` IS NO LONGER IN THIS TEST, and taking it out is what makes the gate mean
	-- what it has always claimed to mean.
	--
	-- It is not a record of what the player plumbed.  notice() files an entry for anything
	-- carrying the `waterPiped` sprite flag - every sink, bath and washing machine on the
	-- map - so it is a record of where the player has BEEN, it never shrinks, and four
	-- untouched map sinks were enough to take this gate out of idle for the rest of the
	-- session.  Measured: one house.
	--
	-- And a fixture alone needs nothing doing.  It cannot be served without a collector, so
	-- if `sources` is empty there is no work that having fixtures could create; and the
	-- moment a collector appears, notice() files it into `sources` and this gate opens on
	-- the very next tick.  A fixture that already HAS a mirror is covered by `ghosts`.
	if not (EP.any(ghosts) or EP.any(sources) or EP.any(fed)) then return end
	EP.maintenanceIdle = false

	-- HOW LONG TO WAIT BEFORE THE NEXT STEP - ONE DECISION, NOT TWO.
	--
	-- There were two rate limiters here and they MULTIPLIED instead of combining.  The idle
	-- gate made the handler return for nine ticks out of ten; the rest counter then made it
	-- return for another three - but each of those three had to get past the idle gate
	-- first, so a three-tick rest cost thirty ticks.  A dry lap of a thirty-six house town
	-- came to about eight thousand ticks, over two minutes of real time, and only ten of a
	-- hundred and forty-four mirrors were reached in three thousand.  The loop was not
	-- keeping up, which is the one thing it exists to do.
	--
	-- They are the same decision - "how long until the next step" - so they are the MAXIMUM
	-- of the two, on one counter: an expensive mirror waits its proportional rest, and
	-- everything else waits the floor.  Never the product.
	--
	-- The floor is now the STEP PERIOD asked of this machine rather than a count of ticks,
	-- and the purse is a gap's worth of the per-second allowance rather than a constant.
	-- The two move together on purpose: their product is work per second, which is what has
	-- to be the same on a server at ten ticks and a client at sixty.
	local gap = stepGap()
	local wait = restTicks
	if wait < gap - 1 then wait = gap - 1 end

	if sinceStep < wait then
		sinceStep = sinceStep + 1
		return
	end
	sinceStep = 0

	-- Cleared once it has been served.  The proportional rest is earned by one expensive
	-- step and must not go on being charged after it: left standing it would compound with
	-- the next step's own rest and slow the lap without bound.
	restTicks = 0

	local purse = perStep(UNITS_PER_SECOND, gap) + carry
	local peak = peakCap()
	if purse > peak then purse = peak end

	local ok, result = EP.timed("maintenance step", pcall, stepCursor, purse)

	-- Only on the way out cleanly.  A step that threw has no honest figure for what it
	-- spent, and crediting it the whole purse would hand the next one a double allowance
	-- in the middle of whatever went wrong.
	if ok then
		carry = purse - (result or purse)
		if carry < 0 then carry = 0 end
		if carry > COST_GHOST then carry = COST_GHOST end
	end

	if not ok then
		-- Both re-entrancy guards released, for the same reason the sweep's handler
		-- released them: a throw halfway through a settle would otherwise leave the mod
		-- refusing to charge anything for the rest of the session.
		EP.settling = false
		reviewing = false
		EP.logFault("plumb-maintenance", "ERROR in maintenance: " .. tostring(result))
	end
end)

--- THERE IS NO HOURLY HANDLER ANY MORE, AND NO CLOCK OF ANY KIND LEFT IN THIS MOD.
---
--- `EveryHours -> reviewPumps` stood here.  Its reasoning was sound and is worth keeping
--- even though the code is gone: a generator only spends fuel, rolls condition and calls
--- setActivated(false) inside `if ((int)getWorldAgeHours() != this.lastHour)`, so the hour
--- was not an approximation of when a pump can change - it was exactly when.
---
--- What made it the right trigger was that the alternative was a whole-registry pass. The
--- cursor is not that: it reviews one collector per step, at a bounded cost, and comes
--- round continuously.  So the pump review is a stage of the loop like everything else
--- (the collector stage), and a generator running dry is noticed by the cursor arriving rather
--- than by a clock striking.
---
--- The deliberate acts keep their instant hooks in LGEPPower.lua and still call
--- EP.reviewPumps outright: somebody pulling a cord must not wait for a queue.

--- Rain stopping is the one weather event the engine really does raise.
---
--- RainManager.stopRaining() calls triggerEvent("OnRainStop") at RainManager.java:260.
--- Its apparent pair does NOT exist: OnRainStart is declared by LuaEventManager and has
--- no triggerEvent call site anywhere in the jar - RainManager.startRaining() is an
--- empty method - so rain cannot be caught on the way in and there is nothing to add
--- here for it.
---
--- Worth handling anyway, because it is the moment the last of the rain has landed.  It
--- used to matter much more than it does: a shower that began and ended between two
--- backstop passes would leave every mirror reading short until the next one, up to ten
--- game minutes.  The cursor comes round every few seconds, so this is now a small
--- promptness gain rather than the difference between right and wrong.  Kept because it
--- costs one assignment.
Events.OnRainStop.Add(function()
	if not EP.isAuthority() then return end
	EP.log("the rain stopped; settling what it left")
	worldChanged()
end)

--- SOMETHING WAS PLACED, AND THIS IS WHAT REPLACED THE FIXTURE PASS.
---
--- The long note on the fixture pass in sweep() has the whole story: vanilla raises
--- OnObjectAdded from its own Lua, on the authority, in all three modes, and one of the
--- seven sites is the rain collector's own build code.  So a barrel going up is serviced
--- now rather than within a minute, and a sink installed is too.
---
--- noticeAt files the ground first - the square itself and the nine above it, where a
--- mirror would live - and then serviceAround re-points every fixture in the building,
--- because a new barrel changes the answer for all of them and not only for whatever is
--- under the cursor.  That is the same `wide` pass a right-click on a collector already
--- triggers, so there is no new path to keep in step.
---
--- Filtered before it costs anything.  Every dropped shirt and every plank comes through
--- here - ISDropWorldItemAction raises it too - and only a collector or a plumbable
--- fixture is worth a look.
Events.OnObjectAdded.Add(function(object)
	if not EP.isAuthority() then return end
	if not EP.getOption("Enabled") then return end
	if not object then return end

	local ok, err = pcall(function()
		local square = object:getSquare()
		if not square then return end

		-- ANYTHING arriving on a square can unseat a mirror standing there, because a
		-- mirror has to be at index 0 to be reached before whatever else is on the square
		-- - see the note on FindWaterSourceOnSquare in LGEPCore.  So the square is marked
		-- for inspection whatever was added, before the qualifier below throws the object
		-- away.  One table write, and it is the difference between a mirror that lost its
		-- place being found now and being found on the slow rotation.
		repaired[EP.key(square:getX(), square:getY(), square:getZ())] = nil

		-- AND IF IT IS A COLLECTOR, IT IS NOT LEGACY.  This is the event a player putting a
		-- barrel down raises; a barrel arriving because its chunk opened raises
		-- LoadGridsquare instead. `EP.adoptLegacyPlumbing` reads this to tell them apart -
		-- see the note on EP.notePlacedCollector.
		if EP.notePlacedCollector and EP.isWaterSource(object) then
			EP.notePlacedCollector(square:getX(), square:getY(), square:getZ())
		end

		if EP.isGhost(object) then return end

		-- A LISTED FIXTURE IS FILED AND NOTHING ELSE, and skipping the pass below is the
		-- point rather than an omission.
		--
		-- Without this branch a dispenser somebody put down was invisible until its chunk
		-- next opened: it is not a collector and not a plumbable fixture, so the test under
		-- here threw it away, and the cursor only walks what is in a registry.  Placed in a
		-- base nobody leaves, that is never.
		--
		-- But it must not take the wide pass either.  serviceAround(wide) re-points every
		-- fixture in the building because a new BARREL changes what all of them can reach; a
		-- dispenser supplies nobody, so it changes the answer for nothing.  Filing it is the
		-- whole of what has to happen, and the top-up stage finds it within a lap.
		if EP.isFedFixture(object) then
			noticeAt(square:getX(), square:getY(), square:getZ())
			return
		end

		if not EP.isWaterSource(object) and not EP.isPlumbableFixture(object) then return end

		EP.log(("something plumbable was placed at %d,%d,%d"):format(
			square:getX(), square:getY(), square:getZ()))
		EP.serviceAround(square:getX(), square:getY(), square:getZ(), true)
	end)
	if not ok then
		EP.settling = false
		EP.logFault("plumb-placement", "ERROR handling a placement: " .. tostring(err))
	end
end)

--------------------------------------------------------------------------------
-- settling as it happens
--------------------------------------------------------------------------------

--- Every mirror that could be drawing on a given collector.
---
--- Asked by height and inclusion rather than by a recorded address, which is the
--- shape the collective forces and the shape it wanted anyway.  A mirror used to
--- name one barrel, so this was a coordinate comparison; a mirror stands for
--- everything its fixture can reach now, so the question is EP.eligible - the same
--- predicate that decided the group in the first place, which is what keeps this
--- from drifting away from it.
---
--- It answers the overlap case, which is the one that matters and the one an
--- address never could: a barrel on the roof is in the group of every floor below
--- it, so drinking at the ground-floor sink leaves the first-floor sink's mirror
--- stale, and both have to be told.
---
--- Filtered by building through a bounding box, and it did NOT used to be.
---
--- What stood here read "deliberately NOT filtered by building - over-including is free",
--- and the first half of that is no longer true while the second half never was.  A mirror
--- whose group does not contain this barrel does re-settle to the same number and does
--- charge nothing; what it is not is FREE, because reaching that conclusion costs a grid
--- lookup and a walk of the square either way.  At six mirrors that is invisible.  At 256
--- it was 1,988,366 operations on every drink.
---
--- The replacement is not a tighter rule, it is the same rule asked earlier: a mirror
--- outside the box provably cannot hold this barrel, so nothing that used to be included
--- is excluded now.  See the bound itself, below.  Under-including is still duplicated
--- water and that has not been traded away for anything.
---
--- `ignorePump` widens it to every mirror this barrel could feed if it were
--- powered, and exists for exactly one caller: reviewPumps, which is reacting to
--- the pump answer having just CHANGED.  Asked the ordinary way after a generator
--- stopped, EP.eligible would already say no for every fixture at or above the
--- barrel - which is precisely the set that has to be told, because they are the
--- ones still holding water it can no longer lift to them.  Being pumped is the
--- more permissive of the two states, so assuming it covers both sides of the
--- transition whichever way it went.
--- THE LIQUID TEST HERE MAY ONLY EVER NARROW WHEN IT IS CERTAIN, AND MUST WIDEN
--- WHENEVER IT IS NOT.  This is the one place in the mod where being too clever
--- costs water rather than a wasted pass, so the rule is written out rather than
--- left to be inferred from the code.
---
--- Over-including is free: a mirror handed a barrel its own group does not contain
--- re-settles to the same number and charges nothing.  Under-including is the
--- duplicated-water bug this function exists to prevent - two taps over one barrel,
--- one drinks, the other still believes in what it drank and pours it again.
---
--- So the barrel's liquid is compared against the mirror's CACHED one, and every
--- uncertainty resolves to "tell it anyway":
---
---   * no cache on the mirror - an old save, a mirror not yet settled once - is
---     treated as a match, never as a miss.
---   * an UNASSIGNED barrel matches every mirror.  It is empty, so it is in every
---     group at once as a receiver (EP.serves), and a pour into any tap can reach
---     it.
---
--- A stale cache is at most one settle old, because settleGhost rewrites it on the
--- way past, and the worst it can do is buy one extra settle that charges nothing.
--- It is a cost saving and nothing else - the FIXTURE is what decides a mirror's
--- liquid, and that is asked in EP.ghostFluidType, not here.  Resolving the fixture
--- object for every mirror in the world on every drink is exactly what this avoids.
--- Does THIS barrel feed THIS mirror?  The per-candidate half of the rule above.
---
--- Factored out because two callers need it and a second copy of a rule whose failure
--- mode is duplicated water is exactly the copy nobody thinks to check.  Every widening
--- documented above lives here and nowhere else.
---
--- `data` is the mirror's modData, read by the caller so a candidate tested against many
--- barrels reads it once.
local function barrelFeedsGhost(source, sz, own, data, ignorePump)
	local fz = data[EP.KEY_FIX_Z]
	if type(fz) ~= "number" then return false end

	local fed
	if ignorePump then
		fed = EP.isIncluded(source)
	else
		fed = EP.eligible(source, sz, fz)
	end

	if fed and own ~= nil then
		local cached = EP.canonicalFluidType(data[EP.KEY_FLUID])
		-- nil cache is a match, never a miss.  See above.
		fed = (cached == nil) or (cached == own)
	end

	return fed and true or false
end

--- Grow `box` to cover every mirror the barrel on this square could possibly feed.
---
--- The locality bound of the comment above, written once.  Returns the barrel's square
--- coordinates so the caller does not resolve the square twice, or nil when it has none.
local function widenByBarrel(source, box, reach)
	local square = source:getSquare()
	if not square then return nil end

	local sx, sy, sz = square:getX(), square:getY(), square:getZ()

	if sx - reach < box.minX then box.minX = sx - reach end
	if sy - reach < box.minY then box.minY = sy - reach end
	if sx + reach > box.maxX then box.maxX = sx + reach end
	if sy + reach > box.maxY then box.maxY = sy + reach end

	-- EP.buildingAt already falls through from the room to the plan, so it subsumes
	-- columnBuilding everywhere except the one split supplyGroup documents: a basement def
	-- whose parent did not resolve.  Asking again in every other case would be an
	-- O(buildings) miss bought for nothing.
	local sdef = EP.buildingAt(sx, sy, sz)
	local b = sdef and EP.buildingBounds(sdef) or nil
	if b then
		if b.minX - 2 < box.minX then box.minX = b.minX - 2 end
		if b.minY - 2 < box.minY then box.minY = b.minY - 2 end
		if b.maxX + 2 > box.maxX then box.maxX = b.maxX + 2 end
		if b.maxY + 2 > box.maxY then box.maxY = b.maxY + 2 end
	end

	if sdef and EP.isBasementDef(sdef) then
		local c = EP.canonicalDef(columnBuilding(sx, sy))
		local cb = c and EP.buildingBounds(c) or nil
		if cb then
			if cb.minX - 2 < box.minX then box.minX = cb.minX - 2 end
			if cb.minY - 2 < box.minY then box.minY = cb.minY - 2 end
			if cb.maxX + 2 > box.maxX then box.maxX = cb.maxX + 2 end
			if cb.maxY + 2 > box.maxY then box.maxY = cb.maxY + 2 end
		end
	end

	-- AND EVERY PIPE NETWORK THE BARREL IS ON, WHICH IS WHERE DUPLICATED WATER WOULD COME FROM.
	--
	-- A barrel in one house piped to a tap in another feeds a mirror that is outside
	-- everything above: not its building, not its Reach.  Leave it out and a drink straight
	-- from the barrel never re-settles that mirror, so the far tap goes on pouring water that
	-- has already gone - the exact failure the header of ghostsFed is written against.  The
	-- network's box is its pieces and every member building's bounds, so a mirror it could
	-- feed is inside it by construction.  lgep_spec_pipes asserts it, per liquid.
	--
	-- One table walk when nothing is laid, which is every world that has not used pipes.
	if EP.anyPipes and EP.anyPipes() then
		local nets = EP.pipeNetsAt(sx, sy, sz, false)
		local nb = nets and EP.pipeNetsBox(nets) or nil
		if nb then
			if nb.minX < box.minX then box.minX = nb.minX end
			if nb.minY < box.minY then box.minY = nb.minY end
			if nb.maxX > box.maxX then box.maxX = nb.maxX end
			if nb.maxY > box.maxY then box.maxY = nb.maxY end
		end
	end

	return sx, sy, sz
end

local function ghostsFed(source, ignorePump)
	local square = source:getSquare()
	if not square then return {} end

	local sz = square:getZ()
	local cell = getCell()
	local out = {}

	local own = EP.barrelFluidType(source)

	-- One table, reused for every square, rather than one per square.
	--
	-- EP.ghostsOnSquare takes an `into` and has since it was written; this call was the
	-- one place that did not pass it, and this loop runs over EVERY known mirror square on
	-- every barrel's OnWaterAmountChange - so a drink through a base allocated a table per
	-- mirror per charged barrel and threw them all away.
	--
	-- IT MUST BE EMPTIED BETWEEN SQUARES.  ghostsOnSquare APPENDS - `into[#into + 1]` -
	-- and does not clear, which is right for its other caller and lethal here: reused
	-- without emptying, every square would inherit the mirrors of every square before it,
	-- `out` would fill with duplicates, and each of those would be settled again.
	local into = {}

	-- THE LOCALITY BOUND, read from the BARREL's side.
	--
	-- "Over-including is free" is the rule above, and it was measured true when a base had
	-- six mirrors in it.  It is measured false across a town: at 256 mirrors and 192
	-- collectors this loop cost 1,988,366 operations on every drink, which is the same
	-- frame the whole settle pass cost.  Free was never a property of over-including - it
	-- was a property of G being small.
	--
	-- The bound is not a guess about which mirrors matter.  A mirror can only hold this
	-- barrel in its group if supplyGroup put it there, and supplyGroup only admits a
	-- collector standing inside the fixture's own building, or within Reach of it where
	-- there is no building.  Read backwards from the barrel, that is: the building this
	-- barrel resolves to, unioned with a Reach square for the player-built case.  A mirror
	-- outside it re-settles to the number it already holds, so skipping it is a PROVABLE
	-- NO-OP rather than an approximation - which is the only kind of shortcut this
	-- function may take, because the failure mode here is duplicated water.
	--
	-- Note what this is NOT doing: it is not deferring the far-away mirrors to a later
	-- tick.  There is no window in which another tap over-reports, because those mirrors
	-- were never going to change.
	local reach = EP.getOption("Reach")
	local box = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
	widenByBarrel(source, box, reach)

	for _, pos in pairs(ghosts) do
	  if pos.x >= box.minX and pos.x <= box.maxX and pos.y >= box.minY and pos.y <= box.maxY then
		for i = #into, 1, -1 do into[i] = nil end

		for _, ghost in ipairs(EP.ghostsOnSquare(cell:getGridSquare(pos.x, pos.y, pos.z), into)) do
			if barrelFeedsGhost(source, sz, own, ghost:getModData(), ignorePump) then
				out[#out + 1] = ghost
			end
		end
	  end
	end
	return out
end

--- Every mirror fed by ANY barrel in a group, deduplicated - in ONE walk of the registry.
---
--- THE FRAME THIS EXISTS FOR.  `afterGroupCharged` used to call `ghostsFed` once per
--- barrel and deduplicate the results, which asks the same question of the same world S
--- times to build a set that collapses to a handful of mirrors.  In a base where every
--- collector is in one building - which is the case the locality bound cannot help with,
--- and the case players actually build - that is S walks of the mirror registry, each
--- doing a grid lookup and an object scan per candidate.  Measured on `lgep_hitch.sh`:
--- 24,023 operations for one drink at 200 barrels, 47,823 at 400 and 95,423 at 800,
--- perfectly linear, in a frame a player is waiting on and which the design manual's own
--- §2 says may never be deferred.
---
--- The inversion is exact rather than approximate, and the reason is what the answer is
--- USED for: the caller wants the SET of mirrors to re-settle, not which barrel implicated
--- each one.  A mirror belongs in that set if ANY barrel in the group feeds it.  So:
---
---   * the box is the UNION of what each barrel would have produced, so no mirror any
---     single-barrel walk would have reached is out of range here;
---   * the registry is walked ONCE against that union;
---   * a candidate is tested against the barrels until one feeds it, then admitted.
---
--- Nothing is narrowed.  The mirrors admitted are exactly the union the old loop built,
--- which matters because under-including is the duplicated-water bug the whole of
--- `ghostsFed`'s header is about - two taps over one barrel, one drinks, the other still
--- believes in what it drank and pours it again.
---
--- What changes is the arithmetic: the Java crossings drop from O(S x G) to O(G), because
--- the grid lookup and the object scan are now paid once per mirror instead of once per
--- mirror per barrel.  The per-candidate test stays O(S) in the worst case, but it is pure
--- Lua and it exits on the first barrel that feeds - which in a real group is the first
--- one tried.
---
--- The union box costs one `EP.buildingAt` per barrel, which is the same call the old loop
--- made per barrel anyway, so that term is unchanged rather than traded.
local function ghostsFedByGroup(group)
	local cell = getCell()
	local out, seen = {}, {}
	if not group or #group == 0 then return out end

	local reach = EP.getOption("Reach")
	local box = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }

	-- Each member's own coordinates are kept from the widening pass, so the test loop
	-- below does not resolve eight hundred squares a second time.
	local members = {}
	for i = 1, #group do
		local source = group[i].object
		local sx, sy, sz = widenByBarrel(source, box, reach)
		if sx then
			members[#members + 1] = {
				object = source,
				z      = sz,
				fluid  = EP.barrelFluidType(source),
			}
		end
	end

	if #members == 0 then return out end

	local into = {}
	for _, pos in pairs(ghosts) do
	  if pos.x >= box.minX and pos.x <= box.maxX and pos.y >= box.minY and pos.y <= box.maxY then
		for i = #into, 1, -1 do into[i] = nil end

		for _, ghost in ipairs(EP.ghostsOnSquare(cell:getGridSquare(pos.x, pos.y, pos.z), into)) do
			if not seen[ghost] then
				local data = ghost:getModData()
				for m = 1, #members do
					local mem = members[m]
					if barrelFeedsGhost(mem.object, mem.z, mem.fluid, data, false) then
						seen[ghost] = true
						out[#out + 1] = ghost
						break
					end
				end
			end
		end
	  end
	end

	return out
end

--- Re-decide every fixture whose supply just gained or lost its pump.
---
--- Called on the generator hooks for an instant answer, and from the sweep as the
--- safety net for the ways power moves with no event at all: fuel running out, the
--- generator breaking, the town supply reaching its shutoff day.
---
--- The important part is HOW the affected fixtures are found.  An earlier version
--- built a box around the generator and serviced the fixtures inside it, and that
--- was simply wrong: generators usually stand outside, the box was measured from
--- the wrong object, and any fixture beyond it kept a mirror full of water from a
--- barrel that had stopped pumping.
---
--- A mirror records the fixture it belongs to, so the links can be walked directly
--- instead of searched for.  Every fixture actually fed by this collector is
--- re-serviced no matter how far away it is or how many floors up - which is the
--- radius the job really needs, and it costs nothing to have because it is a list,
--- not a search.  The neighbourhood pass afterwards is for the opposite case: a
--- barrel that just GAINED a pump and can now feed fixtures it was never linked to.
function EP.reviewPumps()
	if not EP.isAuthority() then return end
	if not EP.getOption("Enabled") then return end

	-- serviceAround calls this, and this calls serviceAround for a collector whose
	-- pump moved, so the two are mutually recursive.  It would terminate on its own
	-- - a transition is recorded before the call that could come back, so the inner
	-- pass finds nothing left to react to - but relying on that is relying on the
	-- order of two lines in different functions.  One flag says it outright.
	if reviewing then return end
	reviewing = true

	-- Snapshot first.  This loop reaches deep - serviceFixture, settleOrSleep,
	-- removeGhost - and several of those prune `sources`: supplyGroup drops a
	-- collector it can no longer resolve, and taking a ghost off a square raises
	-- OnObjectAboutToBeRemoved, whose handler drops the collector too.  Walking the
	-- live table while that happens handed this loop a key whose value had already
	-- gone, and `pos.x` on nil is the crash that followed.
	local snapshot = {}
	for key, pos in pairs(sources) do
		snapshot[#snapshot + 1] = { key = key, x = pos.x, y = pos.y, z = pos.z }
	end

	-- ONE ACTION FOR THE WHOLE SWITCH, not one per barrel that reacted to it.  See
	-- `asOneAction`: this is reached from the generator wrappers with no service above it, so
	-- without this every `EP.serviceAround` below was outermost and re-armed the purse.
	asOneAction("generator", function()
	for _, entry in ipairs(snapshot) do
		local key, pos = entry.key, entry
		local source = sources[key] and EP.sourceAt(pos.x, pos.y, pos.z) or nil
		if not source then
			pumped[key] = nil
		else
			local now = EP.isPumped(source)

			-- This comparison is only an edge detector if pumped[key] holds a real
			-- previous state, and for a long time it did not: the table started empty, so
			-- an unreviewed barrel compared NIL against a real boolean, `nil ~= false` came
			-- back true, and every collector in the world reported a transition it had
			-- never had - each one firing the WIDE serviceAround below over its whole
			-- building.  It is now seeded where the barrel is filed, in notice(); see the
			-- note there for what that cost and why it is fixed at that end rather than
			-- this one.
			if pumped[key] ~= now then
				pumped[key] = now
				-- A pump moving changes which fixtures this barrel is in the group of,
				-- which changes what those mirrors should read.  The walk below re-points
				-- everything it can reach; the flag covers a mirror whose chunk is away.
				worldChanged()
				EP.log(("collector at %d,%d,%d %s its pump"):format(
					pos.x, pos.y, pos.z, now and "gained" or "lost"))

				-- ignorePump, because the answer this walk is filtering on is the
				-- one that just changed.  See the note on ghostsFed.
				for _, ghost in ipairs(ghostsFed(source, true)) do
					local d = ghost:getModData()
					serviceFixtureAt(d[EP.KEY_FIX_X], d[EP.KEY_FIX_Y], d[EP.KEY_FIX_Z])
				end
				EP.serviceAround(pos.x, pos.y, pos.z, true)
			end
		end
	end
	end)

	reviewing = false
end

--- ONE collector's pump, reviewed.  The maintenance cursor's pump stage.
---
--- The body is EP.reviewPumps' loop, lifted out unchanged so the two cannot drift.  What
--- differs is only who drives it: reviewPumps still walks the whole registry in one frame
--- for the DELIBERATE acts - a generator switched on, a cord pulled - because a player who
--- does that must not wait, and the cursor walks it one collector at a time for the
--- autonomous cases that used to need a clock.
---
--- Returns whether it did the expensive branch, so the cursor can charge for it.  A
--- transition fires a wide serviceAround over a whole building; a non-transition is one
--- grid lookup and a boolean compare, which is every collector almost every time.
---
--- Hung on the EP table rather than declared local because the cursor is written far above
--- this and reaches ghostsFed and serviceFixtureAt, both of which are below it too.  A
--- local here would compile to a nil global at the call site.
function EP.reviewPumpEntry(entry, source)
	local key = entry.key
	if source == nil then
		source = sources[key] and EP.sourceAt(entry.x, entry.y, entry.z) or nil
	end
	if not source then
		pumped[key] = nil
		return false
	end

	local now = EP.isPumped(source)
	if pumped[key] == now then return false end

	pumped[key] = now
	worldChanged()
	-- A pump moving is the other thing that can turn a fixture's "no" into a "yes": a barrel
	-- on the tap's own floor gives no gravity and is the entire supply when it is pumped.
	supplyChanged()
	EP.log(("collector at %d,%d,%d %s its pump"):format(
		entry.x, entry.y, entry.z, now and "gained" or "lost"))

	-- THE SAME LATCH `EP.reviewPumps` HOLDS, AND FOR THE SAME REASON.
	--
	-- This is the cursor's one-collector-per-tick version and it was the one path that did
	-- not raise it - so the `EP.serviceAround` below reached `EP.reviewPumps`, found the
	-- latch down, and walked the WHOLE registry. A generator running dry overnight flips
	-- every barrel in the base at once; the cursor reached the first one, charged itself a
	-- whole frame's budget believing it had bounded the work, and that single entry then
	-- dragged the other hundred and ninety-nine through a wide pass each. There is no path
	-- that spreads them, which is the entire point of the cursor.
	--
	-- Saved and restored rather than set and cleared: `EP.reviewPumps` can reach here.
	local wasReviewing = reviewing
	reviewing = true

	-- AND ONE PURSE FOR THE STEP.  `asOneAction` with no mark: this is the cursor's
	-- background stage, not a player action, and bracketing it as one put maintenance time in
	-- the right-click row of the perf table.  Without it the step ran at depth 0 and handed
	-- itself a fresh 1,024-column sweep while charging itself a whole frame's budget.
	local ok, err = pcall(asOneAction, nil, function()
		-- ignorePump, because the answer this walk is filtering on is the one that just
		-- changed.  See the note on ghostsFed.
		for _, ghost in ipairs(ghostsFed(source, true)) do
			local d = ghost:getModData()
			serviceFixtureAt(d[EP.KEY_FIX_X], d[EP.KEY_FIX_Y], d[EP.KEY_FIX_Z])
		end
		EP.serviceAround(entry.x, entry.y, entry.z, true)
	end)

	reviewing = wasReviewing
	if not ok then error(err, 0) end
	return true
end

--- Whenever a mirror charges its group, bring every other mirror that can see any
--- of those barrels back into line.  Registered rather than called directly
--- because settleGhost lives in the shared file and the list of mirrors lives here.
---
--- This is what makes two taps over one barrel safe: without it the second tap
--- goes on believing in water the first tap has already drunk, and pours it.
---
--- The whole group is walked, not one barrel of it, because a proportional draw
--- takes something out of every member - so every member's readers are stale, and
--- a mirror only has to see ONE of them to be wrong.  Deduplicated first: with
--- twelve barrels and six taps the same mirror turns up a dozen times, and
--- settling it a dozen times is eleven rebuilds and possibly eleven packets for
--- nothing.
---
--- Each one is settled against its OWN group, which is the point.  Two fixtures on
--- different floors share the roof barrels and disagree about everything below
--- them, so handing them a group worked out for somebody else would be exactly the
--- fidelity bug this design exists to remove.
--- What a mirror's group is determined BY, cheaply.
---
--- Read out of walkBegin rather than guessed: a group is a pure function of the fixture's
--- square, its floor, the liquid wanted, the building def its own room resolves to, the
--- structure the region graph puts it in, the Reach option and the collector registry.  The
--- last two are constant across a frame, which leaves the first five.
---
--- THIS DROPS fx AND fy, and that is the entire risk, so it is written out:
---
---   * they reach the BOX, and the box narrows what is CONSIDERED and provably never what
---     is ACCEPTED - so two fixtures with different boxes still admit the same collectors;
---   * they reach `scope.column`, compared in step 3 of servesBuilding, and THAT can differ
---     between two fixtures of one building.
---
--- Measured before it was used, over five scenes in `lgep_probe_groupkey.lua` - fixtures
--- spread across a town, basements where canonicalDef can fail, two liquids, player-built
--- structures with no def at all, and a 200-barrel hoard.  **Zero disagreements in any of
--- them**, and 80-83% of group walks shared.  Everything in the key is compared by value,
--- so a def that has been destroyed and rebuilt with a fresh id simply misses.
local function groupKeyFor(ghost, fluid)
	local data = ghost:getModData()
	local fx, fy, fz = data[EP.KEY_FIX_X], data[EP.KEY_FIX_Y], data[EP.KEY_FIX_Z]
	if type(fx) ~= "number" or type(fy) ~= "number" or type(fz) ~= "number" then
		return nil
	end

	local square = getCell():getGridSquare(fx, fy, fz)
	local building = square and square:getBuilding()
	local def = building and EP.canonicalDef(building:getDef()) or nil
	local defId = def and tostring(def:getIDString()) or "-"

	-- Chunk-granularity structure identity, the same thing walkBegin asks for.  Sorted, so
	-- two fixtures in one structure cannot differ by table order.
	local regions = EP.regionsAt(fx, fy, fz)
	local ids = nil
	if regions then
		ids = {}
		for id in pairs(regions) do ids[#ids + 1] = tostring(id) end
		table.sort(ids)
		ids = table.concat(ids, "+")
	end

	-- A FIXTURE IN NEITHER IS SHARED WITH NOBODY, and that is the one case this key cannot
	-- describe.  With no def and no structure the group is decided by Reach, which is a
	-- square measured from the FIXTURE - so two taps in two different fields both keyed
	-- "-|-|0|Water" and the second would have been settled against the first one's barrels.
	-- The address is the only thing that separates them, so it goes in the key; anywhere
	-- else it is left out on purpose, because sharing is the whole point of the memo.
	if not def and not regions then
		return "@" .. EP.key(fx, fy, fz) .. "|" .. tostring(fluid)
	end

	return defId .. "|" .. (ids or "-") .. "|" .. fz .. "|" .. tostring(fluid)
end

EP.afterGroupCharged = function(group, except)
	-- ONE WALK OF THE MIRROR REGISTRY, NOT ONE PER BARREL.  See ghostsFedByGroup: the set
	-- built here is identical to the union the per-barrel loop produced, and the reason it
	-- may be built in one pass is that the caller wants the SET, not the attribution.
	local out = ghostsFedByGroup(group)

	-- AND ONE GROUP WALK PER DISTINCT GROUP, NOT PER MIRROR.
	--
	-- Six taps over one building's eight hundred barrels resolved the same eight hundred
	-- barrels six times, and after the fan-out and Q13 were dealt with that was the whole of
	-- what was left growing with the collector count.
	--
	-- THE CACHE LIVES FOR THIS CALL AND NOTHING LONGER, which is what makes it safe rather
	-- than merely measured.  A module-level cache of groups would need an invalidation rule
	-- covering every way a collector can be built, drained, plumbed, unplumbed or carried
	-- off, and getting one of those wrong silently shortens a water total - the failure this
	-- file's headers repeatedly warn is the quiet one.  A local table cannot go stale
	-- between frames because it does not survive one.
	local cache = {}

	for i = 1, #out do
		local ghost = out[i]
		if ghost ~= except then
			-- A WALK IN FLIGHT FOR THIS MIRROR IS NOW WRONG, AND LANDING IT PUTS WATER BACK.
			--
			-- The cursor opens a settle walk that takes tens of ticks over a big base. If a
			-- player draws from the kitchen tap while the bathroom mirror's walk is open,
			-- this line re-settles the bathroom mirror correctly to the new total - and then
			-- the walk lands carrying the group it read BEFORE the draw. Its delta is zero,
			-- so `settleGhost` keeps the walk's stale summary and fills the mirror back to
			-- what the building held a moment ago.
			--
			-- The tap then reads more than the barrels hold, and it goes UP after somebody
			-- drinks. Drawing those phantom litres charges barrels that cannot pay, which
			-- becomes a debt, which `retireIfUnsupplied` can later log and destroy.
			--
			-- `stepSettleWalk`'s own note says over-reporting "can only be produced by a
			-- deliberate movement", and that "those raise OnWaterAmountChange, which bumps
			-- the epoch and throws this walk away". `onWaterAmountChange` does not bump the
			-- epoch - `worldChanged()` is the only thing that does, and it is not on that
			-- path. Abandoning the one mirror is the targeted version of what the note
			-- claimed: bumping the epoch here would throw away every walk on the server for
			-- every sip anybody takes.
			if EP.abandonWalkFor then EP.abandonWalkFor(ghost) end

			-- Asked once and handed to both, because groupForGhost would otherwise resolve
			-- the fixture a second time to answer the same question.
			local fluid = EP.ghostFluidType(ghost)
			local key = groupKeyFor(ghost, fluid)
			local hit = key and cache[key] or nil

			local own, summary
			if hit then
				own, summary = hit.group, hit.summary
			else
				-- The walk's own summary comes back with it, per Q13.
				own, summary = EP.groupForGhost(ghost)
				if key then cache[key] = { group = own, summary = summary } end
			end

			if own and #own > 0 then
				local moved = EP.settleGhost(ghost, own, summary)

				-- THE WHOLE CACHE IS DROPPED THE MOMENT ANYTHING ACTUALLY MOVES, and the
				-- reason is membership rather than arithmetic.  An EMPTY collector is
				-- unassigned, and an unassigned collector is in every group at once as a
				-- receiver (EP.serves, and the note in ghostsFed's header).  So a settle
				-- that puts water into one stops it being unassigned and takes it out of
				-- groups it belonged to a moment ago - which means a remembered group is
				-- not merely stale in its totals, it can be wrong in its membership.
				--
				-- Settling a mirror that agrees with its group moves nothing and keeps the
				-- cache, which is the case this exists for: on a drink, every mirror except
				-- the one drunk from is being told about somebody else's draw.
				if moved then cache = {} end
			end
		end
	end
end

--- The moment anything moves.
---
--- A drink, a bottle filled, a wash cycle's minute of water: all of them end in
--- IsoObject.useFluid or addFluid, both of which raise this before returning.  So
--- the books are square again before the action that spent the water has even
--- finished, and a second fixture asking a moment later gets a true answer.
---
--- Nothing is removed from the world in here.  This runs inside the Java call
--- that raised it, with that object still on the stack; taking objects off
--- squares is left to the sweep, which owns no call frame but its own.
--- Guarded, because of where it runs.  IsoObject.useFluid raises this in the
--- middle of spending water, with the object still on the stack, so an error
--- escaping here does not lose a mirror update - it propagates out of the drink,
--- the wash or the wash cycle that was in progress.  A mirror that is briefly
--- wrong is recoverable; a drink that throws is not.  The next settle squares it.
---
--- THERE IS A THIRD OBJECT THIS CAN ARRIVE WITH AND IT IS NOT HANDLED.  See Q12 in
--- plans/lgep-open-questions.md.
---
--- IsoObject.transferFluidTo's external-source branch - the path a bottle filled at a
--- plumbed tap takes, and moveFluidToTemporaryContainer with it, which is drinking -
--- ends `triggerEvent("OnWaterAmountChange", this, sourceAvail)` where `this` is the
--- FIXTURE (IsoObject.java:2857).  A fixture is neither a ghost nor a water source, so
--- both branches below are skipped and this returns having done nothing.
---
--- It is late rather than wrong: the water genuinely left the mirror's own container,
--- so the mirror is now below its ledger and the next settle charges the group through
--- the path that already carries a multiplayer draw and an unloaded chunk.
--- Conservation holds, and lgep_spec_mixture asserts it per fluid.  What it costs is up
--- to a lap of staleness for any OTHER tap over the same barrels - which is exactly
--- what EP.afterGroupCharged closes for every other path, and this one is simply not
--- wired into it.
---
--- Not the same thing as EP.COMMAND_DRAW.  That is the engine refusing to move the
--- water at all on a multiplayer client; this fires in singleplayer and on the server,
--- where the guard is open and the water really does move.
local function onWaterAmountChange(object, prevAmount)
	if EP.settling then return end
	if not EP.getOption("Enabled") then return end
	if not EP.isAuthority() then return end
	if not object then return end

	if EP.isGhost(object) then
		-- Its own group, worked out now rather than remembered.  A tap that drains
		-- the building in one draw is charged across every barrel and then read back
		-- off those same barrels in the same call, so it reports what is actually
		-- left instead of the momentary zero the old main-barrel path produced.
		local group = EP.groupForGhost(object)
		if group and #group > 0 then
			EP.settleGhost(object, group)
		else
			-- Nothing can reach this fixture any more and something just drew
			-- through it.  sleepGhost keeps the draw as debt rather than forgiving
			-- it, so the building still owes it when a barrel comes back.
			EP.sleepGhost(object)
		end
	elseif EP.isWaterSource(object) then
		-- Whatever just went in decides what this barrel is, and this is the moment
		-- it happened.  ISAddFluidFromItemAction pours through
		-- IsoObject.transferFluidFrom, which raises this before returning, so
		-- emptying a bottle of whiskey into an empty barrel claims it for whiskey
		-- with nothing to poll for.  Rain is the silent one and the sweep has it.
		--
		-- BEFORE the mirrors are told, because ghostsFed reads the barrel's liquid to
		-- decide which of them care.
		EP.rememberBarrelFluid(object)

		-- Somebody drank straight from the barrel, or a mod moved its water.
		-- Every mirror that can see it is now wrong by exactly that much.
		for _, ghost in ipairs(ghostsFed(object)) do
			local own, summary = EP.groupForGhost(ghost)
			if own and #own > 0 then EP.settleGhost(ghost, own, summary) end
		end

	elseif EP.isPlumbableFixture(object) then
		-- A DRAW THROUGH THE TAP ITSELF, WHICH NOTHING USED TO LISTEN FOR.  Q12, closed
		-- 2026-08-16.
		--
		-- IsoObject.transferFluidTo's external-source branch ends
		-- `triggerEvent("OnWaterAmountChange", this, sourceAvail)` where `this` is the SINK,
		-- not the mirror the water actually came out of.  So filling a bottle at a plumbed
		-- tap - and drinking, through moveFluidToTemporaryContainer - arrived here as a
		-- FIXTURE, which is neither a ghost nor a water source, and the handler returned
		-- having done nothing.
		--
		-- IT WAS NEVER A CONSERVATION BUG and is not fixed as one: the water really does
		-- leave the mirror, because `fc` in that branch IS the ghost's container, so the
		-- mirror falls below KEY_LEDGER and the next settle charges the group proportionally
		-- with the debt rules intact.  What was wrong is that it was LATE - by up to a lap
		-- of the maintenance cursor, during which a second tap over the same barrels reads a
		-- total that has already been spent.  Every other path closes that window through
		-- EP.afterGroupCharged; this one simply was not wired to it.
		--
		-- Resolving the fixture to its mirror and settling that is the whole of it, and it
		-- reuses the predicates that already exist rather than adding a rule.  The mirror is
		-- found the way the engine found it - FindExternalWaterSource - so a fixture that is
		-- plumbed to something that is not ours is left alone.
		--
		-- REMOVES NOTHING FROM THE WORLD, which is the rule this handler runs under: it is
		-- called from inside the Java that raised it, with the object still on the stack.
		-- settleGhost only moves fluid between containers.
		local source = object.FindExternalWaterSource and object:FindExternalWaterSource()
		if source and EP.isGhost(source) then
			local own, summary = EP.groupForGhost(source)
			if own and #own > 0 then EP.settleGhost(source, own, summary) end
		end
	end
end

Events.OnWaterAmountChange.Add(function(object, prevAmount)
	-- THE FRAME THE WHOLE 2026-08-16 MEASUREMENT IS ABOUT.  A drink, a bottle filled or a
	-- wash cycle's minute of water all land here, it is Class B - a player is waiting and
	-- it cannot be deferred at any price - and on the bench it is linear in the number of
	-- collectors in the building: 24,023 ops at 200 barrels and 95,423 at 800.  This is
	-- the counter that says what that is in milliseconds on real hardware.
	local ok, err = EP.timed("water change", pcall, onWaterAmountChange, object, prevAmount)
	if not ok then
		EP.settling = false
		EP.logFault("plumb-settle-mirror", "ERROR settling a mirror: " .. tostring(err))
	end
end)

--- A collector being taken off its square.
---
--- The mirrors that could see it are re-settled here, and that is the whole of it -
--- nothing is emptied and nothing is removed.  A mirror is the sum of its group, so
--- dropping the barrel out of the registry first and settling second leaves every
--- affected tap reading the building's real remaining total, immediately.
---
--- Which is a straight improvement on what this used to have to do.  A mirror named
--- one barrel, so a dismantled barrel left mirrors standing for something that was
--- not there: they had to be emptied on the spot to stop four hundred litres of free
--- water being drinkable until the next sweep, and then destroyed and rebuilt
--- somewhere else.  None of that is needed when the answer is a sum.
---
--- Removing objects is still not safe from inside this event, which the engine
--- raises mid-iteration over the square's own object list - but nothing here wants
--- to any more.
--- Guarded, and for a sharper reason than most: IsoGridSquare raises this while
--- iterating its own object list and then *checks* that the handler did not remove
--- the object, throwing IllegalArgumentException if it did.  Nothing here removes
--- anything - the mirrors are only emptied, and the sweep clears the objects - but
--- an error escaping into that check would take the removal down with it.
local function onObjectAboutToBeRemoved(object)
	if not EP.getOption("Enabled") then return end
	if not EP.isAuthority() then return end
	if not object then return end

	local square = object:getSquare()
	if not square then return end
	local key = EP.key(square:getX(), square:getY(), square:getZ())

	if EP.isGhost(object) then
		ghosts[key] = nil
		supplyChanged()
		repaired[key] = nil
	elseif EP.isWaterSource(object) then
		-- The mirrors are found BEFORE the barrel leaves the registry and settled
		-- AFTER, and the order is the whole trick.  ghostsFed asks whether this
		-- barrel could feed each mirror, which needs the barrel; supplyGroup rebuilds
		-- each mirror's group out of `sources`, which must no longer hold it, or the
		-- tap would go on counting a barrel somebody is carrying away.
		--
		-- forgetSource and not `sources[key] = nil`, so its place in its pool's list
		-- goes with it.
		local affected = ghostsFed(object)
		forgetSource(key)

		for _, ghost in ipairs(affected) do
			local own, summary = EP.groupForGhost(ghost)
			if own and #own > 0 then
				EP.settleGhost(ghost, own, summary)
			else
				EP.sleepGhost(ghost)
			end
		end
		EP.log(("collector removed; %d mirror(s) re-settled without it"):format(#affected))
	elseif EP.isFedFixture(object) then
		-- DELIBERATELY NOTHING, and this used to call forgetFed(key).
		--
		-- Nothing else has to be undone: a listed fixture is in no group and no pool and no
		-- mirror reads it, so unlike a collector leaving there is nothing standing anywhere
		-- that is now describing it.  Its water goes with it, exactly as it would with this
		-- mod uninstalled.
		--
		-- And the address MUST NOT be dropped here, because this event cannot tell why the
		-- object is going.  Taking a bottle out removes the dispenser and stands another
		-- object in its place; picking the dispenser up removes it for good.  Both raise
		-- this, both raise it BEFORE the removal, and the square looks identical from in
		-- here.  Forgetting on the first would have cost a re-plumb after every bottle
		-- change - and worse, silently, because addWorkstationEntity raises no event to file
		-- the replacement with either.
		--
		-- topUpFedEntry asks the question one lap later, when the answer is in the world to
		-- read, and clears the square and the address there.  See EP.hasScriptedEntity.
	elseif EP.isPlumbableFixture(object) then
		forgetFixture(key)

		-- Its mirror is now standing over nothing, and taking one away is the sweep's
		-- job rather than this handler's - the engine raises this mid-iteration over the
		-- square's own object list and then checks the handler did not remove anything.
		-- So the mirror is marked for INSPECTION instead, which is what the repair pass
		-- is for; without this a mirror whose fixture had been dismantled would wait for
		-- its turn on the slow rotation.
		local above = EP.key(square:getX(), square:getY(), square:getZ() + 1)
		repaired[above] = nil
		worldChanged()
	end
end

--------------------------------------------------------------------------------
-- the one-litre sample clip
--------------------------------------------------------------------------------

--- A DRAW THROUGH A PLUMBED FIXTURE DESTROYS EVERYTHING PAST THE FIRST LITRE.
---
--- Vanilla, not this mod, and measured on the engine in
--- `tools/luatest/lgep_probe_smallpour.lua`: ask a plumbed sink for ten litres in one
--- call and the bucket gets **one**, while the supply is charged **ten**.  Nine litres
--- stop existing.
---
--- WHERE IT COMES FROM.  `IsoObject.transferFluidTo` serves an external source by taking
--- a SAMPLE of it and pouring the sample into the target:
---
---     FluidContainer tempFc = this.createSampleAndPurifyWater(fc, used);
---     FluidContainer.Transfer(tempFc, target);
---     float consumed = used - tempFc.getAmount();
---     fc.removeFluid(consumed);
---
--- and the sample container is a pooled one:
---
---     FluidContainer tempFc = FluidContainer.CreateContainer();   // reset() -> capacity 1.0
---     ...
---     tempFc.addFluid(fluidType, amount * fluidInstance.getAmount());
---
--- Nothing ever sets that container's capacity - `moveFluidToTemporaryContainer` three
--- methods away does, so the omission is local rather than intended - and `addFluid` stops
--- dead at `!this.isFull()`.  So a sample of more than a litre is CLIPPED, and then
--- `consumed` is worked out as `used` minus what is LEFT in the sample rather than what
--- actually reached the target.  The clipped litres were never in the sample to be left in
--- it, so they are charged to the supply and delivered to nobody.
---
--- AND A BLEND LOSES ITS TAIL, which is the same defect wearing a different face.  The
--- sample is filled fluid by fluid, so the first fluids take the whole litre and the ones
--- after it are dropped entirely - while `removeFluid` charges the source PROPORTIONALLY
--- across all of them.  Measured: whiskey 12 + wine 9 + beer 6, two litres asked for, and
--- the bottle gets whiskey 0.889 + wine 0.111 and no beer at all, against a supply charged
--- the full two litres.  That is Tier's report on the Discussions, 2026-08-25 - *"it would
--- only output whiskey, and when it ran out of whiskey it cleared the Tequila and Vodka
--- and started to pump water"* - exactly: the tail fluids drain without ever being poured,
--- and when the barrel is finally dry the tap falls back to the mains reserve.
---
--- WHY THIS MOD IS THE ONE PATCHING IT, and it is the washing-machine argument again.
--- Vanilla reaches this branch only where a rain collector happens to stand in the 3x3
--- above a sink; under this mod EVERY plumbed fixture in the building reads through a
--- mirror, and the mirror holds the whole supply - so a fault that costs vanilla a rare
--- bucket costs this mod's players their base's water, in the one liquid they chose it
--- for.
---
--- THE REPAIR IS GRANULARITY AND NOTHING ELSE.  `ISTakeWaterAction:transferFluid` is the
--- only caller in the game of `transferFluidTo` - filling a container and drinking from a
--- tap both run it - and it takes the amount as a real parameter.  Asking for the same
--- water in steps no bigger than the sample container can hold gives the identical result
--- with none of the loss, because every step now fits: nothing is clipped, so `consumed`
--- is right, and every fluid in a blend arrives in proportion.
---
--- Under the step size this changes nothing at all, which is nearly every call: the action
--- transfers what one tick of progress is worth, and a tick is worth thousandths of a
--- litre.  It is the whole-amount calls - `complete()`'s `updateUse(1)`, and an instant
--- timed action - that were losing water.
--------------------------------------------------------------------------------

--- A PLUMBED FIXTURE DESTROYS ANY FLUID THE ENGINE HAS NO `FluidType` CONSTANT FOR.
---
--- Vanilla, not this mod, and a DIFFERENT fault from the one above even though they live in
--- the same six lines.  That one is about SIZE and is fixed by asking in smaller pieces;
--- this one is about IDENTITY and no step size helps, because every step builds its own
--- sample and drops the fluid out of each.  They were once filed as one report and they are
--- not one bug.
---
--- WHERE IT COMES FROM.  `IsoObject.createSampleAndPurifyWater` throws a perfectly good
--- `Fluid` away for its `FluidType` and adds it back by enum:
---
---     FluidType t = inst.getFluid().getFluidType() == FluidType.TaintedWater
---                 ? FluidType.Water : inst.getFluid().getFluidType();
---     tempFc.addFluid(t, amount * inst.getAmount());
---
--- `FluidType` is a fixed enum of 33 names.  A `fluid` script block whose name is not one of
--- them gets `FluidType.Modded` and keeps its identity in a STRING instead
--- (FluidDefinitionScript:215).  `Fluid.Get(FluidType.Modded)` is null - `fluidEnumMap` has
--- one writer, called only for the 27 `public static final Fluid` fields - and
--- `FluidContainer.addFluid(null, x)` opens with `if (fluid != null)`.  So the fluid is
--- silently dropped, `consumed = used - tempFc.getAmount()` charges the WHOLE ask against an
--- empty sample, and `ISTakeWaterAction:updateUse` re-asks every tick because the item never
--- gains.  The barrel empties in front of the player and the can stays empty.
---
--- HOW MUCH OF THE GAME.  61 vanilla fluids, 27 with a constant and **34 without** - Cola,
--- ColaDiet, every juice, every soda but SodaPop, every spirit but Beer/Whiskey/Wine/Mead,
--- Perfume, Cologne, MilkChocolate.  And **every modded fluid is `Modded` by definition**, so
--- this is 100% of fluids added by any other mod.  A MIXTURE loses exactly its unservable
--- share and is charged for all of it, and then names itself after the half that survived -
--- so a cola-and-water tap reads "Water", looks healthy and eats half of every pour.
--- Measured over all 61 fluids and all 1267 legal pairs in
--- `tools/luatest/lgep_probe_enginematrix.lua`.
---
--- ONLY FOUR CALLS ARE BROKEN and all four go through that sample: `getPrimaryFluid`,
--- `getFluidUiName`, `transferFluidTo` and `moveFluidToTemporaryContainer`.  The other eight
--- on the same surface delegate straight to the source object and are sound for every fluid
--- in the game (`tools/luatest/lgep_probe_fixtureapi.lua`).  **So the whole repair is to stay
--- off those four**, and this is the one that moves fluid.
---
--- WHY THIS MOD IS THE ONE PATCHING IT, which is the washing-machine argument again.  Vanilla
--- reaches this branch only where a rain collector happens to stand in the 3x3 above a sink,
--- and only ever with water in it.  Under this mod every plumbed fixture in the building
--- reads through a mirror, and the whole point of the *Plumbed liquid* feature is that the
--- mirror holds something other than water.  This mod created the situation; it is this mod's
--- job to check.
---
--- THE REPAIR IS TO MOVE THE FLUID OURSELVES.  `FluidContainer.Transfer(from, to, amount)`
--- takes the fluid out of the source's own container with no sample anywhere near it.
--- Measured before a line of this was written: it carries a Modded fluid, carries a mixture
--- whole, does NOT inherit the one-litre clip, and is still refused exactly where vanilla
--- refuses - the blend rules stay the engine's, which is the part that matters, because a
--- bypass that skipped them would pour petrol into a teacup and that WOULD be our bug.
--- The servability test and the mixture rule both live in EP (LGEPCore), because the client
--- asks the same question to decide whether to put a Drink row back on the fixture.  Two
--- copies of that answer is two things to disagree.

--- Move `amount` out of `source` into `target`, the way `transferFluidTo` would have.
---
--- Returns what actually moved, which is measured off the containers rather than assumed -
--- `FluidContainer.Transfer` clamps against free capacity and against what is there, and the
--- caller has to charge for the truth.
---
--- THE TWO THINGS `FluidContainer.Transfer` DOES NOT DO FOR US, both measured:
---
---   * it raises NO `OnWaterAmountChange`.  The engine path raises one, and this mod's own
---     settle listens on it - as does anything else watching a rain barrel.  Without this
---     the level a client draws never moves.
---   * it syncs nothing.  `transferFluidTo` ends `this.sync(); object.sync();`.
--- AND IT PURIFIES, BECAUSE SKIPPING THE SAMPLE SKIPPED TWO THINGS AND ONLY ONE OF THEM
--- WAS THE BUG.
---
--- `IsoObject.createSampleAndPurifyWater` rebuilds each instance through its `FluidType`,
--- which destroys a `Modded` fluid - that is the whole reason for this bypass - and it also
--- rewrites `TaintedWater` to `Water` (`IsoObject.java:2812-2826`). That second half is the
--- only reason a plumbed sink over a dirty rain barrel is safe to drink from in vanilla.
---
--- `FluidContainer.Transfer` copies each instance AS IT IS (`FluidContainer.java:1169-1177`),
--- so the bypass was handing the player the tainted water itself.
---
--- MEASURED on the real engine (`tools/luatest/lgep_probe_tainted.lua`): a barrel of 120 L
--- tainted water with 8 L of cola in it filled a cup with **Cola 0.0625 + TaintedWater
--- 0.9375**. The same barrel without the cola - no bypass, vanilla's own sample - filled it
--- with **Water 1.0000**. The two scenes differ by one splash of cola, and one of them makes
--- the player ill. Rain collectors without `FillsWithCleanWater` fill with `TaintedWater`, and
--- any modded fluid at all turns the bypass on for every draw at that tap from then on.
---
--- Done AS the transfer and not after it, because `FluidContainer.removeFluid` takes a total
--- and removes proportionally across every instance - there is no per-fluid removal, so the
--- substitution cannot be undone once the water is in the cup.
---
--- The arithmetic is `Transfer`'s own: clamp to what the source has and what the target can
--- hold, give each instance its percentage of that, then take the total off the source. Only
--- TaintedWater is rewritten; every other fluid keeps its identity, which is the half that
--- must not regress.
local function bypassTransfer(fixture, sourceObject, target, amount)
	local fc = sourceObject:getFluidContainer()
	if not fc then return 0 end
	if not FluidContainer.CanTransfer(fc, target) then return 0 end

	local before = fc:getAmount()
	local room = target:getCapacity() - target:getAmount()
	local transfer = math.min(amount, before, room)
	if transfer <= EP.EPS then return 0 end

	EP.eachFluid(fc, function(_, fluid, held)
		if held <= 0 then return end
		local share = transfer * (held / before)
		if share <= 0 then return end
		local name = fluid and fluid.getFluidTypeString and tostring(fluid:getFluidTypeString())
		target:addFluid((name == "TaintedWater") and Fluid.Water or fluid, share)
	end)
	fc:removeFluid(transfer)

	local moved = before - fc:getAmount()
	if moved <= EP.EPS then return 0 end

	pcall(function() fixture:sync() end)
	pcall(function() sourceObject:sync() end)
	triggerEvent("OnWaterAmountChange", fixture, before)
	return moved
end

local DRAW_STEP = 0.9   -- the pooled sample container holds 1.0; the margin is for float drift
local DRAW_STEPS_MAX = 64

--- Serve the draw ourselves, standing in for the whole of vanilla's `transferFluid`.
---
--- BOTH ARMS, because both are broken.  Filling a container goes through
--- `transferFluidTo` and drinking goes through `moveFluidToTemporaryContainer`, and that
--- second one is `transferFluidTo` three lines further down - so a repair that covered only
--- the bottle would leave drinking destroying the supply.  Nobody has ever reported that,
--- for the good reason that vanilla withholds the Drink option on exactly these fixtures:
--- `doDrinkWaterMenu` gates on `getPrimaryFluid() ~= nil` and the sample is empty.  Two
--- faults cancelling into one silent absence - and this mod puts the row back, so the
--- cancellation ends here.
local function bypassDraw(self, sourceObject, amount)
	local fixture = self.waterObject
	if amount <= 0 or fixture:getFluidAmount() <= 0 then return end

	if self.item then
		local target = self.item:getFluidContainer()
		if not target then return end
		if bypassTransfer(fixture, sourceObject, target, amount) > 0 then
			self.item:syncItemFields()
			sendItemStats(self.item)
		end
		return
	end

	-- DRINKING.  Vanilla's `moveFluidToTemporaryContainer` sets the temporary container's
	-- capacity to the amount asked for and clamps that to what is available; both are
	-- reproduced here rather than referred to, because the method itself is one of the four
	-- that cannot carry the fluid.
	local want = amount
	local avail = fixture:getFluidAmount()
	if want > avail then want = avail end
	if want <= EP.EPS then return end

	local cup = FluidContainer.CreateContainer()
	cup:setCapacity(want)
	if bypassTransfer(fixture, sourceObject, cup, want) > 0 then
		self.character:DrinkFluid(cup, 1)
	end
	FluidContainer.DisposeContainer(cup)
end

require "TimedActions/ISTakeWaterAction"

--- MAY A DRAW AT THIS FIXTURE GO ON THROUGH ITS MIRROR?  Authority only.
---
--- THE SEAT TOKEN WAS BEING POURED OUT, AND POURING IT OUT OPENS THE SEAT.  A mirror over a
--- tap whose liquid has run out holds 0.00005 L so the engine stops at it (EP.defendSeat).
--- But the tap reads that token as water available, so a Fill or a Drink draws it - and the
--- moment the mirror is empty, IsoObject.checkExternalFluidSource searches again, finds the
--- neighbour holding a different liquid, and CACHES it.  The rest of that draw, and every
--- draw after it until the neighbour is empty, came out of the neighbour.  In
--- tools/luatest/lgep_probe_whisky.lua a water tap with no water poured the whisky barrel
--- beside it dry: the first bottle a mixture, the second pure whisky.  BR-LGEP-022's third
--- trial, and the "mixture of water and whisky" in it.
---
--- So a mirror holding nothing of its own is not drawn at all.  Nothing of the tap's liquid
--- is lost by refusing - there is none - and the seat is re-defended and the engine pointed
--- back at the mirror on the way out.  A mirror with something in it is drawn as before,
--- with the engine's cache refreshed first, so a stale neighbour cannot be what answers.
---
--- WHAT IS LEFT TO VANILLA, and on purpose: a mirror standing aside (EP.sleepGhost), where a
--- real barrel nobody plumbed is meant to win; and a dry mirror with nothing different
--- beside it, which is EP.poachedBy's definition of harmless and where the draw finds
--- nothing anyway.
--- The engine's own refresh of a fixture's cached source; see seatHolds.  Probed for, because
--- a harness fixture searches fresh on every read and has nothing to refresh.
local function repoint(water)
	if water.doFindExternalWaterSource then water:doFindExternalWaterSource() end
end

local function seatHolds(water)
	local square = water:getSquare()
	if not square then return true end

	local own = ghostFor(square:getX(), square:getY(), square:getZ())
	if not own then return true end
	if own.getUsesExternalWaterSource and own:getUsesExternalWaterSource() then return true end

	local fc = own:getFluidContainer()
	local held = fc and fc:getAmount() or 0
	if held > EP.EPS then
		repoint(water)
		return true
	end

	if held <= 0 and not EP.poachedBy(water, own) then
		repoint(water)
		return true
	end

	EP.defendSeat(own)
	repoint(water)
	return false
end

--- Installed at file scope rather than on OnGameStart, so that it sits UNDER the draw
--- reporter the client file installs there: the reporter must go on seeing the amount the
--- action asked for, not the pieces it is served in.  `server/` loads on every machine and
--- loads last (see the note at the top of this file), which is what makes one install here
--- cover singleplayer, a host, a client and a dedicated server.
if ISTakeWaterAction and type(ISTakeWaterAction.transferFluid) == "function" then
	local vanillaTransferFluid = ISTakeWaterAction.transferFluid

	ISTakeWaterAction.transferFluid = function(self, amount)
		-- EVERY GATE FAILS OPEN TO VANILLA.  This is a repair, and a repair that throws
		-- is worse than the fault: the player would not get their water at all.
		local split, bypass, sourceObject, refused, guarded = false, false, nil, false, false
		local ok = pcall(function()
			if not EP.getOption("Enabled") then return end
			if type(amount) ~= "number" or amount <= 0 then return end

			-- ONLY THE BRANCH THAT HAS THE BUGS.  A source read directly - a rain barrel
			-- right-clicked, a puddle, a river - goes through `fc.transferTo(target, used)`
			-- with no sample and neither fault, and touching that would only cost Java calls.
			local water = self.waterObject
			if not water or not water.getUsesExternalWaterSource then return end
			if not water:getUsesExternalWaterSource() then return end

			-- BEFORE ANYTHING ELSE ASKS WHERE THE WATER IS, so that the answer - the
			-- bypass's FindExternalWaterSource and vanilla's cached source alike - is the
			-- fixture's own mirror and not the neighbour an empty one lets in.  See seatHolds.
			-- Only where fluid really moves; a client's transfer is a no-op.
			--
			-- AND BEFORE THE SIZE TEST BELOW, which it used to follow.  A draw offered a seat
			-- token is sized off the token - ISTakeWaterAction:new caps waterUnit at what the
			-- tap reads - so every tick of it asks for millionths of a litre, all under EP.EPS,
			-- and all of it went straight to vanilla past this guard.  That is exactly the
			-- draw that spends the token.
			if EP.isAuthority() then
				guarded = true
				if not seatHolds(water) then refused = true; return end
			end

			if amount <= EP.EPS then return end

			-- THE IDENTITY FAULT IS ASKED ABOUT FIRST, because its repair REPLACES the draw
			-- rather than reshaping it: slicing a delivery of nothing into pieces would give
			-- five pieces of nothing and charge for all five.
			--
			-- Only where the engine's own body would run.  `transferFluidTo` is wrapped in
			-- `if (GameServer.server || !GameClient.client)`, which is EP.isAuthority()
			-- exactly; without the same guard an MP client would move fluid that the server
			-- is also moving - a double debit, and then a resync that hides it.  On a client
			-- this falls through to vanilla, whose body no-ops, which is what the client-side
			-- draw reporter is written against.
			if EP.getOption("FluidPatch") and EP.isAuthority() then
				local found = water:FindExternalWaterSource()
				local fc = found and found.getFluidContainer and found:getFluidContainer() or nil
				if fc and fc:getAmount() > EP.EPS and EP.containerNeedsBypass(fc) then
					bypass, sourceObject = true, found
					return
				end
			end

			if amount > DRAW_STEP then split = true end
		end)

		if not ok then return vanillaTransferFluid(self, amount) end
		if refused then return end

		if bypass then
			local served = pcall(bypassDraw, self, sourceObject, amount)
			-- A throw here has already been paid for by whatever it moved, so falling
			-- through to vanilla would charge the supply a second time.  Report and stop:
			-- the player has lost a draw, not their barrel.
			if not served then
				EP.logFault("fluid-bypass", "ERROR serving a draw by hand; the tap will "
					.. "look empty until the next attempt")
			end
			return
		end

		if not split then
			return vanillaTransferFluid(self, amount)
		end

		-- Vanilla's own two guards end this early and for free: transferFluid returns at
		-- once when the source is dry, and transferFluidTo clamps what it moves to the
		-- target's free capacity - so a step past the end of the fill is a no-op rather
		-- than a loss, and neither has to be predicted here.
		local left, steps = amount, 0
		while left > EP.EPS and steps < DRAW_STEPS_MAX do
			steps = steps + 1
			-- Asked again before every slice after the first: a slice can be the one that
			-- empties the mirror, and the next would then be served by the neighbour.
			if guarded and steps > 1 then
				local asked, holds = pcall(seatHolds, self.waterObject)
				if asked and not holds then break end
			end
			local step = left
			if step > DRAW_STEP then step = DRAW_STEP end
			vanillaTransferFluid(self, step)
			left = left - step
		end
	end
end

--------------------------------------------------------------------------------
-- the washing machine patch
--------------------------------------------------------------------------------

--- TWO ENGINE FAULTS, ONE SHAPE: THE AUTHORITY CHANGES A WASHER AND NOBODY IS TOLD.
---
--- Neither is caused by this mod and neither is about water reaching a fixture - the
--- server side of both is entirely correct.  Both are multiplayer only; in singleplayer
--- the authority IS the machine drawing the menu and there is nothing to tell.  The whole
--- account, with line numbers, is in plans\washing-machines.md.
---
--- **A washing machine cannot be plumbed at all.**  IsoClothingWasher.saveChange and
--- loadChange override IsoObject's without calling super and forward everything to
--- ClothingWasherLogic, which handles WASHER_STATE and nothing else.  So
--- USES_EXTERNAL_WATER_SOURCE - the change vanilla's own ISPlumbItem:complete() sends,
--- from the server, because LuaTimedActionNew.complete() is wrapped in
--- `if (!GameClient.client)` - writes zero bytes and is read as nothing.  The server is
--- plumbed; every client still has usesExternalWaterSource false, so
--- ISWorldObjectContextMenuLogic goes on offering Plumb (its second branch tests the flag
--- and never looks at modData) and getFluidAmount() answers 0, which greys out Turn On
--- with "Requires water supply".  The machine is unusable and plumbing it again cannot
--- help.  IsoCombinationWasherDryer re-adds the missing branch by hand and is the only
--- washer class that works; IsoStackedWasherDryer has the same hole and is saved from it
--- only by carrying no waterPiped flag.
---
--- **A washer does not stop when its supply runs dry.**  ClothingWasherLogic.update()
--- calls setActivated(false) on `getFluidAmount() <= 0` with no sendObjectChange beside
--- it - unlike cycleFinished(), three lines further down the same class, which does send.
--- So the normal end of a cycle syncs and the ran-out-of-water end does not: the machine
--- stops on the server and runs for ever on screen, and Turn Off makes it worse, because
--- ISToggleComboWasherDryer:complete() also runs on the server and toggles an already-off
--- machine back ON.  That is the "it will not turn off" loop.
---
--- WHY THIS MOD IS THE ONE PATCHING IT.  Vanilla can reach the first fault only with a
--- player-built rain collector on the floor above a player-placed washing machine, which
--- is rare; under this mod every plumbed fixture is fed that way, so it is every washing
--- machine.  The second is the same story: a supply that empties is unusual in vanilla and
--- ordinary here.
---
--- NOTHING BELOW CHANGES HOW A WASHING MACHINE BEHAVES.  It still fills, runs, spends a
--- unit a minute and stops exactly when the engine decides.  All that is added is telling
--- the other side what the engine decided - and it is behind its own sandbox option so it
--- can be taken out without taking the mod out.
require "TimedActions/ISPlumbItem"
require "TimedActions/ISToggleClothingWasher"
require "TimedActions/ISToggleComboWasherDryer"

--- Washers this side believes are RUNNING.  Square key -> {x,y,z}.
---
--- A watch list rather than a walk of the fixture registry, and that is the whole cost
--- argument: a machine only needs a broadcast when it goes from running to stopped, so
--- the only fixtures worth looking at are the ones somebody has switched on.  That is
--- normally none, and the pass below is then one `pairs` over an empty table.  Walking
--- every plumbed fixture once a minute to ask a question whose answer is "no" for all of
--- them would be a per-minute burst proportional to the size of the town.
---
--- Addresses rather than objects, for the reason every registry in this file keeps
--- addresses: the object can have been dismantled, picked up or streamed out since, and a
--- table of live IsoObjects would hold every one of them against collection.
local runningWashers = {}

--- Is this the kind of fixture that has an on switch?
---
--- No class list, deliberately, and for once the reason is not only taste: among objects
--- carrying waterPiped - which is everything this mod ever hands to these functions -
--- IsoObject has no isActivated at all, so having one IS being a washer.  A modded washer
--- that derives from either class is covered without being known about, exactly as
--- EP.isPlumbableFixture covers a modded sink.
local function hasOnSwitch(object)
	return object ~= nil and object.isActivated ~= nil and object.setActivated ~= nil
end

--- Which change carries this machine's on/off state.
---
--- A combo in dryer mode routes saveChange to ClothingDryerLogic, which answers to
--- DRYER_STATE and ignores WASHER_STATE - sending the wrong one would write zero bytes
--- and be exactly the fault this is here to fix.  A dryer cannot run out of water, so
--- this is reached only if somebody changed the mode while the watch was standing.
local function stateChangeFor(fixture)
	if fixture.isModeWasher ~= nil and not fixture:isModeWasher() then
		return IsoObjectChange.DRYER_STATE
	end
	return IsoObjectChange.WASHER_STATE
end

--- Start watching a machine, if it is one and if it is running.
local function watchWasher(fixture)
	if not EP.getOption("WasherPatch") then return end
	-- Singleplayer has nobody to tell, and the flag it would be telling them about is
	-- already right on the only copy there is.
	if not isServer() then return end
	if not hasOnSwitch(fixture) then return end
	if not fixture:isActivated() then return end

	local square = fixture:getSquare()
	if not square then return end

	local x, y, z = square:getX(), square:getY(), square:getZ()
	runningWashers[EP.key(x, y, z)] = { x = x, y = y, z = z }
end

--- Keep the modData copy of the plumb flag equal to the flag itself.
---
--- See EP.KEY_PIPED and EP.repairPipedFlag for the two halves of why the copy exists.
--- This is the writing half and it is the only place in this mod that writes to a
--- fixture at all.
---
--- Written only on a CHANGE.  serviceFixture calls this for every fixture it services,
--- which is every right-click on one, and transmitModData is a packet - re-sending an
--- unchanged key on every right-click would be the same waste the mirror sync is careful
--- about a few hundred lines above.
---
--- Cleared to nil rather than to false, like every other key in this mod: a save that
--- never plumbed anything to a collector gains no key, and rolling back to a build with
--- no patch in it lands on exactly the modData that build wrote.
reconcilePipedFlag = function(fixture)
	if not EP.getOption("WasherPatch") then return end
	if not fixture or fixture.getUsesExternalWaterSource == nil then return end

	-- Free, and it has to come first: watching is about the OTHER fault and must not
	-- depend on whether the plumb flag happened to need writing this pass.
	watchWasher(fixture)

	-- NOTHING IS WRITTEN IN SINGLEPLAYER, and the sandbox tooltip already says so - "fixes
	-- two base game bugs on servers [...] singleplayer does not need it".  The key exists
	-- for one reason: an object-change packet for a washing machine drops the plumb flag on
	-- the way to a client, so the copy travels where the flag does not.  With no wire there
	-- is nothing to carry, and writing it anyway put a key and a transmitModData on every
	-- fixture in a single-player save for no gain - and worse, gave EP.repairPipedFlag on
	-- this same machine a stale flag it could write back over the real one.
	if not isServer() then return end

	local piped = fixture:getUsesExternalWaterSource() == true
	local stated = fixture:hasModData() and fixture:getModData()[EP.KEY_PIPED] == true
	if piped == stated then return end

	fixture:getModData()[EP.KEY_PIPED] = piped or nil
	fixture:transmitModData()

	local square = fixture:getSquare()
	EP.log(("%s the plumb marker on the fixture at %d,%d,%d so a client can see it"):format(
		piped and "set" or "cleared",
		square and square:getX() or -1, square and square:getY() or -1,
		square and square:getZ() or -1))
end

--- Hang something on the end of a vanilla action's complete().
---
--- Wrapped rather than replaced, original called first, addition inside a pcall: none of
--- this may ever be the reason a vanilla action fails.  Installed only where complete()
--- actually runs, since this file returns early on a multiplayer client, so there is no
--- inert copy of the wrap on every player's machine.
---
--- Guarded on the action existing at all.  Every one of them is vanilla and every one is
--- required above, so in the game this cannot miss - but the test harness's `require` is a
--- no-op by design, and an unguarded wrap would be a nil index at load time that takes the
--- whole mod down before a single suite ran.
local function wrapComplete(action, site, after)
	if type(action) ~= "table" or type(action.complete) ~= "function" then return end

	local original = action.complete
	action.complete = function(self)
		local result = original(self)

		local ok, err = pcall(after, self)
		if not ok then
			EP.logFault(site, "ERROR after " .. site .. ": " .. tostring(err))
		end

		return result
	end
end

--- STAMPED THE MOMENT IT IS PLUMBED, not on the next lap, and that is worth ten lines.
---
--- serviceFixture reconciles too, and a right-click is what calls it - but the menu for
--- THAT click is built before the answer gets back across the wire, so without this the
--- player plumbs, right-clicks, and is offered Plumb one more time before it takes.  Which
--- is indistinguishable from the bug.
wrapComplete(ISPlumbItem, "plumb-stamp-marker", function(self)
	reconcilePipedFlag(self.itemToPipe)
end)

--- Both toggles, so a machine is watched from the instant it is switched on.
---
--- These run on the authority for the same engine reason ISPlumbItem:complete() does, so
--- this is the server hearing about its own decision at first hand.  A machine already
--- running when the server restarted is not caught here - the watch does not survive a
--- restart, by design, because a table of addresses saved across one is a fourth thing to
--- keep true - and is picked up instead by the next serviceFixture on it, which is the
--- next time anybody right-clicks it.  That is the one narrow case where the stale
--- display can outlive the stop, and it heals the moment somebody looks at the machine.
wrapComplete(ISToggleClothingWasher, "plumb-watch-washer", function(self)
	watchWasher(self.object)
end)
wrapComplete(ISToggleComboWasherDryer, "plumb-watch-combo", function(self)
	watchWasher(self.object)
end)

--- Tell the clients about a machine that stopped itself.
---
--- Once a game minute, which is the same clock the machine spends its water on -
--- ClothingWasherLogic.update() takes `1 * elapsedMinutes` - so this cannot be more than a
--- minute behind the stop it is reporting, and a game minute is a couple of seconds.
--- OnTick would be sixty times the work to be sixty times earlier than the thing it is
--- watching can possibly change.
---
--- The keys are collected before any of them is removed.  Deleting the current key inside
--- a `pairs` loop is defined in Lua 5.1 and this VM is Kahlua, which has already been
--- caught missing `next`; a second array costs nothing at these sizes and needs no faith.
local function sweepRunningWashers()
	local cell = getCell()
	if not cell then return end

	local finished = {}
	for key, pos in pairs(runningWashers) do
		local square = cell:getGridSquare(pos.x, pos.y, pos.z)
		local fixture = square and EP.fixtureOnSquare(square) or nil

		if not hasOnSwitch(fixture) then
			-- Gone, dismantled, or its chunk closed.  Dropped either way: nobody is
			-- watching a machine nobody can see, and a right-click files it again.
			finished[#finished + 1] = { key = key, fixture = nil }
		elseif not fixture:isActivated() then
			finished[#finished + 1] = { key = key, fixture = fixture, pos = pos }
		end
	end

	for i = 1, #finished do
		local done = finished[i]
		runningWashers[done.key] = nil

		if done.fixture then
			done.fixture:sendObjectChange(stateChangeFor(done.fixture))
			EP.log(("the washer at %d,%d,%d stopped itself; telling the clients, "
				.. "which the engine does not"):format(done.pos.x, done.pos.y, done.pos.z))
		end
	end
end

Events.EveryOneMinute.Add(function()
	if not EP.isAuthority() then return end
	if not isServer() then return end
	if not EP.getOption("WasherPatch") then return end

	local ok, err = pcall(sweepRunningWashers)
	if not ok then
		EP.logFault("plumb-washer-sweep", "ERROR reporting a stopped washer: " .. tostring(err))
	end
end)

--------------------------------------------------------------------------------
-- a lid is a new barrel
--------------------------------------------------------------------------------

--- OPENING OR CLOSING A LID UNPLUMBED THE BARREL.  BR-LGEP-091.
---
--- ISOpenCloseLid:complete() does not open anything.  It takes the barrel off its square
--- and stands a different entity in the same spot (42.21,
--- shared/TimedActions/ISOpenCloseLid.lua, complete):
---
---     self.square:transmitRemoveItemFromSquare(self.barrel);
---     self.square:RemoveTileObject(self.barrel);
---     local newbarrel = self.square:addWorkstationEntity(newName, self.sprite)
---     ... newbarrel:getFluidContainer():copyFluidsFrom(tempCont)
---
--- and it carries across the water, the health and the max health - nothing else.  The
--- wrench mark, the reserve flag and the remembered liquid were all on the old object's
--- modData, so every lid click handed the player back an unplumbed barrel.
---
--- IT LEFT THE REGISTRY TOO.  The removal raises OnObjectAboutToBeRemoved, whose handler
--- forgets the collector and re-settles its taps without it - correctly, since it cannot
--- tell a lid from a pickup.  addWorkstationEntity adds from Java and raises nothing, so the
--- replacement was not filed again until its chunk reloaded.
---
--- So the marks are copied OUT before vanilla runs and put back on whatever vanilla stood
--- there afterwards, and the square is noticed again.  Both lid states are collectors -
--- RainCollectorRoundClosed keeps its 600 L container with RainFactor 0 - so a closed
--- barrel stays plumbed, which is what closing a lid to keep the rain out means.  The
--- water dispenser is the same engine shape and keeps its flag on the SQUARE instead
--- (EP.KEY_FED), because with its bottle out it is briefly not a fixture at all.  A barrel
--- never stops being a collector, so the object can carry it straight across.
---
--- Only this mod's keys, the list LGEPCarry derives.  Whatever else was on the old barrel
--- belonged to somebody else, and vanilla dropping it is theirs to take up.
require "TimedActions/ISOpenCloseLid"

--- This mod's marks on a barrel, copied out.  nil when there are none, which is every
--- barrel nobody has taken a wrench to - and then the wrap does nothing else at all.
local function lidMarks(barrel)
	if not barrel or not barrel.hasModData or not barrel:hasModData() then return nil end
	if not EP.ownModDataKeys then return nil end

	local data, held, any = barrel:getModData(), {}, false
	local keys = EP.ownModDataKeys()
	for i = 1, #keys do
		local value = data[keys[i]]
		if value ~= nil then held[keys[i]] = value; any = true end
	end
	return any and held or nil
end

--- What stood on the square before vanilla ran, to find what it added by difference.
---
--- By difference and not by name or index: addWorkstationEntity decides where the new
--- object sits, and "the one that was not there a moment ago" is true wherever that is.
local function objectsOn(square)
	local out = {}
	local objects = square and square:getObjects()
	if not objects then return out end
	for i = 0, objects:size() - 1 do out[#out + 1] = objects:get(i) end
	return out
end

local function carryLidMarks(square, before, held)
	local objects = square:getObjects()
	local rebuilt = nil
	for i = 0, objects:size() - 1 do
		local o = objects:get(i)
		local old = false
		for j = 1, #before do
			if before[j] == o then old = true; break end
		end
		if not old then rebuilt = o; break end
	end

	local x, y, z = square:getX(), square:getY(), square:getZ()
	if not rebuilt then
		EP.log(("a lid moved at %d,%d,%d and nothing new stood there; its plumbing went with it")
			:format(x, y, z))
		return
	end

	local data = rebuilt:getModData()
	for key, value in pairs(held) do data[key] = value end

	-- The new barrel reached the clients whole when it was added, with an empty table, so
	-- this is the only way the Plumb row turns back into Disconnect on their side.
	rebuilt:transmitModData()

	-- Filed again, now, rather than when the chunk next reloads.  Same gate as the removal
	-- handler that forgot it: with the mod off nothing was forgotten, and the marks alone
	-- are all a switched-off mod should keep.
	if EP.getOption("Enabled") then noticeAt(x, y, z) end

	EP.log(("a lid moved at %d,%d,%d; the barrel keeps its plumbing"):format(x, y, z))
end

local function wrapLid(action)
	if type(action) ~= "table" or type(action.complete) ~= "function" then return end

	local original = action.complete
	action.complete = function(self)
		-- BEFORE, necessarily: once vanilla has run, the object carrying them is gone.
		local held, before = nil, nil
		local ok, err = pcall(function()
			held = lidMarks(self.barrel)
			if held then before = objectsOn(self.square) end
		end)
		if not ok then
			EP.logFault("lid-carry", "ERROR reading a barrel before its lid moved: " .. tostring(err))
			held = nil
		end

		local result = original(self)

		if held and self.square then
			local carried, err = pcall(carryLidMarks, self.square, before, held)
			if not carried then
				EP.logFault("lid-carry", "ERROR putting a barrel's plumbing back after its lid"
					.. " moved: " .. tostring(err))
			end
		end

		return result
	end
end

wrapLid(ISOpenCloseLid)

Events.OnObjectAboutToBeRemoved.Add(function(object)
	local ok, err = pcall(onObjectAboutToBeRemoved, object)
	if not ok then
		EP.settling = false
		EP.logFault("plumb-removal", "ERROR handling a removal: " .. tostring(err))
	end
end)

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
--
-- The `else` is not defensive tidiness, it is the direction the fault actually came in:
-- the reported install had the NEW server file and an OLD shared one, so the core is the
-- half that has no checkBuild in it and a bare `if EP.checkBuild then` would have said
-- nothing in exactly the case this exists for.  Printed directly there because EP.logFault
-- is in the same file that is missing.
if EP.checkBuild then
	EP.checkBuild("LGEPPlumbing.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPPlumbing.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
