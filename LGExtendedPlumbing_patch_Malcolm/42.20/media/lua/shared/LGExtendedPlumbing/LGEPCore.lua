--
-- Extended Plumbing - shared vocabulary.
--
-- The whole mod rests on one method: IsoObject.FindWaterSourceOnSquare.  It is
-- what decides whether a fixture has a collector above it, and it asks for four
-- things and nothing else:
--
--     object instanceof IsoThumpable
--     sprite == null or not solidfloor
--     not getUsesExternalWaterSource()
--     getFluidCapacity() > 0
--
-- No name, no sprite whitelist, no entity script, no global-object registration.
-- So anything answering those four is a collector as far as the engine is
-- concerned, and every water read on a plumbed fixture - getFluidAmount,
-- getFluidCapacity, useFluid, addFluid, emptyFluid, hasWater, isTaintedWater,
-- transferFluidTo/From - is routed through it by checkExternalFluidSource.
--
-- This mod puts a ghost collector on the square above the fixture and keeps its
-- water identical to a real barrel elsewhere in the building.  Vanilla then does
-- all of the work, unpatched: the Plumb option appears, the sink pours, the
-- washing machine runs, the bath fills.  Nothing in this mod touches a fixture,
-- a menu, or a timed action.
--
-- The ghost is invisible (setDoRender false), walks through (the blueprint flag
-- keeps it out of the square's collision aggregate), and cannot be clicked (a
-- non-rendering object is never handed to the object picker).
--

LGEP = LGEP or {}
local EP = LGEP

--------------------------------------------------------------------------------
-- names
--------------------------------------------------------------------------------

EP.MOD_ID = "LGExtendedPlumbing"

--- WHICH BUILD THIS FILE IS, so a HALF-UPDATED INSTALL says so instead of crashing.
---
--- Steam does not always deliver a whole item.  Two reports on 2026-08-27, both against
--- 3.2.6, are a Java trace whose LGEPPlumbing.lua line numbers match 3.2.6 exactly and
--- whose top frame is `Object tried to call nil in walkStep` on the line that calls
--- `EP.collectorPresence` - a function that was ADDED in 3.2.6.  So that machine had 3.2.6's
--- server file and an older shared one, and every lap of the maintenance cursor threw.
--- One reporter fixed it by unsubscribing and resubscribing; nobody could have known that
--- from the trace.
---
--- The check is at the foot of each of the other files rather than here, so a mismatch is
--- named by the file that disagrees.  It costs one string compare per file per boot and it
--- CANNOT be a version number read from mod.info: the whole point is that the two halves
--- come from different downloads, and mod.info is one file.
EP.BUILD = "3.3.1"

--- Say so once, from a file that has just loaded, if it does not agree with the core.
---
--- Never throws and never disables anything.  The mod may well work - which is exactly
--- what the reporters saw, right up until the one call that did not exist - and a mod
--- that refused to load would be a worse answer than one that says what is wrong.
function EP.checkBuild(file, build)
	if build == EP.BUILD then return true end
	EP.logFault("build-mismatch-" .. tostring(file),
		("%s is from %s and LGEPCore.lua is from build %s."
		.. " Steam has delivered half an update: unsubscribe from LG Extended Plumbing,"
		.. " restart the game, and subscribe again."):format(
			tostring(file),
			(type(build) == "string") and ("build " .. build) or "a build too old to say which",
			tostring(EP.BUILD)))
	return false
end

--- The ghost's sprite.  Registered rather than borrowed: IsoSprite instances are
--- shared singletons kept in IsoSpriteManager.namedMap, so setting the blueprint
--- flag on carpentry_02_122 would strip the collision off every rain barrel in
--- the world.  This one is ours and nothing else uses it.
EP.GHOST_SPRITE = "LGEP_ghost"

--- World z runs -32..31: IsoChunkMap.LEVELS is 64 and GROUND_LEVEL is 32.
EP.MAX_LEVEL = 31

--- modData on the ghost.  It is saved with the chunk and transmitted with the
--- object, so this is both the ghost's identity across a restart and how a
--- multiplayer client recognises one arriving over the wire.
EP.KEY_GHOST  = "LGEPGhost"      -- true: this object is a ghost
EP.KEY_FIX_X  = "LGEPFixX"       -- the fixture it was made for
EP.KEY_FIX_Y  = "LGEPFixY"
EP.KEY_FIX_Z  = "LGEPFixZ"
EP.KEY_LEDGER = "LGEPLedger"     -- what the mirror held when it was last squared
EP.KEY_DEBT   = "LGEPDebt"       -- drawn through the tap but not yet charged to any barrel
EP.KEY_DORMANT = "LGEPDormant"   -- kept, but dry: no supply can reach it just now
EP.KEY_LOCAL  = "LGEPLocal"      -- a client's own stand-in, see below
EP.KEY_INCLUDE = "LGEPInclude"   -- on a COLLECTOR: opted in/out by hand, nil = follow the sandbox
EP.KEY_RESERVE = "LGEPReserve"   -- on a COLLECTOR: held back, drawn on only when the rest are dry
EP.KEY_HOLDS   = "LGEPHolds"     -- on a COLLECTOR: the liquid it last held, read only while empty
EP.KEY_FLUID   = "LGEPFluid"     -- on a FIXTURE: the liquid it draws.  Also on a ghost, as a cache.
EP.KEY_DEBT_FLUID = "LGEPDebtFluid"  -- on a ghost: which liquid an unpaid debt is owed in
EP.KEY_SEATED = "LGEPSeated"      -- on a ghost: it is holding a token of its own liquid
                                  -- purely to keep the engine's search from handing its
                                  -- fixture the NEIGHBOUR's source; see EP.defendSeat
EP.KEY_ADOPTED = "LGEPAdopted"    -- on a ghost: its building's barrels have had the one-off
                                  -- legacy plumbing pass; see EP.adoptLegacyPlumbing
EP.KEY_ADOPT_SEEN = "LGEPAdoptSeen"  -- on a ghost: an adoption pass has RESOLVED this
                                  -- building's scope at least once, whether or not it found
                                  -- anything to adopt.  Not the same thing as KEY_ADOPTED
                                  -- and deliberately a second key; see the note there.

--- ON A FIXTURE, AND THE ONLY THING THIS MOD EVER WRITES TO ONE.
---
--- It is the authority's copy of vanilla's own usesExternalWaterSource, carried in modData
--- because for one class of fixture the field itself does not survive the wire.
--- IsoClothingWasher.saveChange forwards every change to ClothingWasherLogic, which handles
--- WASHER_STATE and nothing else, so USES_EXTERNAL_WATER_SOURCE writes zero bytes and a
--- washing machine plumbed on the server stays unplumbed on every client - Plumb never
--- leaves the menu and Turn On stays greyed out for ever.  modData syncs where the field
--- does not.  See plans\washing-machines.md and EP.repairPipedFlag.
---
--- Written for EVERY fixture rather than only the broken class, so there is no class list
--- to keep and no question about a modded fixture that inherits from one.  For a sink it
--- is a key nobody ever reads.
EP.KEY_PIPED = "LGEPPiped"        -- on a FIXTURE: the authority says it is plumbed to a collector

--- None of the three above is ever written when it would say the same thing as its
--- own default.  KEY_HOLDS is skipped for water, KEY_FLUID is cleared to nil for
--- water, and KEY_DEBT_FLUID goes with the debt it describes.  So a save that has
--- only ever carried water gains no keys at all, and a player who rolls back to a
--- build with no per-liquid code in it lands on exactly the modData that build
--- wrote.  Same reasoning as the two dead keys below, applied before the fact
--- rather than after.

--- Two keys written by older versions are deliberately absent from this list, and
--- deliberately never touched at runtime:
---
---     LGEPSrcX/Y/Z   the single collector a mirror used to be a copy of
---     LGEPMain       the building's elected main supply
---
--- Both are meaningless now - a mirror is a copy of a *group*, worked out from
--- LGEPFix* and the world - and nothing here reads them.  They are also not
--- cleared.  An upgrade that writes nothing cannot half-write anything, and a
--- player who rolls back to an older build lands on mirrors that still carry the
--- addresses that build reads, so a downgrade heals itself on the first
--- right-click instead of leaving a house dry.  Leaving two dead strings in
--- somebody's save file is the cheapest insurance there is.

--- The channel a client uses to ask the server to service a fixture.
EP.COMMAND_MODULE = "LGExtendedPlumbing"
EP.COMMAND_SERVICE = "service"
EP.COMMAND_INCLUDE = "include"
EP.COMMAND_RESERVE = "reserve"
EP.COMMAND_FLUID   = "fluid"

--- A PLAYER TOOK WATER OUT OF A FIXTURE, WHICH ON A CLIENT NOTHING ELSE WILL SAY.
---
--- IsoObject.useFluid ends `if ((GameServer.server || !GameClient.client) && used > 0.0F)`
--- around both the removal AND the OnWaterAmountChange it raises - and returns `used`
--- regardless, so the timed action that asked believes it got its water.  On a multiplayer
--- client the water therefore comes from nowhere: no barrel is charged, no event fires, and
--- the server is never told.  Every vanilla water action is a plain ISBaseTimedAction run by
--- the client, the server never runs one, and vanilla has no channel of its own for this -
--- the only fluid commands in its entire Lua tree are addFluidDebug and removeWaterDebug.
---
--- So this is the channel.  The client says what was drawn and the server performs the same
--- draw on the mirror, which raises the event there and charges the group through the path
--- singleplayer has always used.  See lgep_repro_mpdraw.lua, which fails without it.
EP.COMMAND_DRAW    = "draw"

--- THE WAY OUT (CLAUDE.md section 6): an admin switching the mod on or off, or asking for
--- everything to be put back before it is deleted. Answered with CMD_ADMIN_RESULT. See
--- client/LGEPAdmin.lua and EP.uninstallNow.
EP.CMD_ADMIN_ENABLE    = "adminenable"
EP.CMD_ADMIN_UNINSTALL = "adminuninstall"
EP.CMD_ADMIN_RESULT    = "adminresult"

--- Fluid amounts are floats and a wash cycle spends them a fraction at a time.
--- Below this, a difference is arithmetic rather than a drink.
EP.EPS = 0.0001

--------------------------------------------------------------------------------
-- housekeeping
--------------------------------------------------------------------------------

--- Sandbox options, with the file's own defaults repeated so a missing option -
--- an old save, a server that has not regenerated its ini - reads as the shipped
--- behaviour instead of nil.
--- A BARREL IS IN THE SUPPLY ONLY BECAUSE SOMEBODY PLUMBED IT IN.
---
--- There is no sandbox option behind this any more and no default to consult - see the
--- note further down on why the one that was here had to go.  EP.isIncluded reads the
--- barrel's own flag; nil means nobody has plumbed it in.
---
--- A barrel used to join the building's supply by standing in the right place.  That
--- over-applies, and it over-applies in the direction nobody can see: every barrel a
--- player had ever put down for its own sake - a decorative one, one they filled by hand
--- to keep separate, one standing against a wall because that is where it fitted - was
--- silently in the house's plumbing, and the only sign was a tap reading a number that
--- was too big.  There is no state a player could inspect to find out which barrels were
--- in and which were not, because they were all in.
---
--- So plumbing is now an ACT.  A barrel is outside the supply until somebody takes a pipe
--- wrench to it, and EP.canPlumbHere decides where that is even offered.
---
--- NOTHING IN THE SAVE FORMAT MOVED.  KEY_INCLUDE is the same key, tri-state exactly as
--- before: true is plumbed in by hand, false is disconnected by hand, and nil is "nobody
--- has said, follow the sandbox".  Only what the sandbox says has changed, so an existing
--- world needs no migration pass and cannot be half-migrated - a barrel somebody had
--- explicitly excluded stays excluded, one they had explicitly included stays plumbed, and
--- the great majority that were never touched read as unplumbed on the first right-click
--- after the update.
---
--- THAT IS A VISIBLE CHANGE TO AN EXISTING SAVE and it is deliberate: every tap in a
--- building goes dry until somebody walks round the barrels with a wrench.  It is the
--- honest version of the same fact - those barrels were never actually chosen - and it is
--- the only version that can be undone one barrel at a time.  The alternative, writing
--- `true` onto everything currently in a group, is a migration that guesses, cannot be
--- reversed, and bakes the over-application permanently into the save.
---
--- THE SANDBOX OPTION IS GONE, AND KEEPING IT WAS A MISTAKE THAT SHIPPED.
---
--- It was kept as an escape hatch: set back to true, the old behaviour returned, for a
--- server mid-game whose operator would rather not have their players re-plumb a town.
--- Two things were wrong with that.
---
--- The first is that EP.adoptLegacyPlumbing removed the need for it - nothing that was
--- actually working stops working, so there is no disruption left to opt out of.
---
--- The second is the one that mattered, and it made the whole feature inert on every
--- world that already had this mod.  A SANDBOX VALUE LIVES IN THE SAVE.  Changing a
--- shipped default only seeds a NEW world; an existing one keeps whatever it was created
--- with, and every existing one was created with true.  So the update landed on those
--- servers as: every barrel in the county already plumbed, the Plumb option never
--- appearing anywhere, and no indication that a setting three menus deep was the reason.
--- Found on a live server doing exactly that.
---
--- An option whose stale value silently disables the feature it guards is not a safety
--- net, it is a trapdoor.  Removed outright, so there is no value to be stale.  A leftover
--- IncludeByDefault key in an existing save is simply ignored by the game.
---
--- The DEFAULTS entry goes with it: EP.isIncluded now answers from the barrel's own flag
--- alone, and nil means "nobody has plumbed this in".
---
--- FedFixtures is the one option whose default is LOAD BEARING RATHER THAN A PREFERENCE,
--- and the reason is the trapdoor above.  A sandbox value lives in the save, so an
--- existing world has no FedFixtures key at all and never will; EP.getOption falls through
--- to this table, so that world reads the shipped list.  The repeat here is what makes the
--- feature reach a server that was created before it existed - exactly the case the
--- IncludeByDefault removal was about, arranged so it cannot happen again.
---
--- An operator who empties the string turns the feature off, which is an ACT and is
--- visible in their own ini.  A stale value cannot disable it, because there is no stale
--- value to have.
local DEFAULTS = {
	Enabled       = true,
	Reach         = 12,
	Debug         = false,
	FedFixtures   = "WaterDispenser",
	WasherPatch   = true,
	FluidPatch    = true,
}

--- THE ENGINE FIRST AND `SandboxVars` SECOND, AND THAT ORDER IS A BUG FIX (BR-LGEP-030).
---
--- `SandboxVars` is a SNAPSHOT, not the live value.  `SandboxOptions.toLua()` is the only
--- thing that writes that table, and it runs on world load, on connect and on server start
--- - nowhere else.  The singleplayer sandbox editor's apply is
--- `if not isClient() then getSandboxOptions():set(name, value) end`
--- (ISServerSandboxOptionsUI.lua:737-740), and `SandboxOptions.set` has no `toLua()` behind
--- it.  So in singleplayer every option this mod has - Enabled, Reach, FedFixtures, both
--- patches, Debug - was read at the value the save was loaded with for the rest of the
--- session.  "Raise Reach" was advice that did nothing until a reload.
---
--- A dedicated server and a co-op host were always fine: the editor's apply goes to
--- `GameServer.receiveSandboxOptions`, which calls `toLua()` and rebroadcasts.  This reads
--- the same number one step closer there.
---
--- The same fix as LGEE's EE.getOption (2026-08-23), carried over unchanged.  THE OPTION
--- OBJECT IS CACHED AND ITS VALUE IS NOT: the object is stable for a session and the value
--- is the thing that moves.  `optionByName` is keyed on the FULL dotted name
--- (SandboxOptions.java:556), `LGExtendedPlumbing.Reach`, not the short one.
---
--- FedFixtures's load-bearing default still holds.  A world created before that option
--- existed has no key in its save, so the Java option carries the sandbox-options.txt
--- default, which is the same string DEFAULTS holds.
local optionObjects = {}

--- Session-scoped: `SandboxOptions.Reset()` runs on the way back to the main menu and every
--- option object is built again for the next world.  Dropped from OnInitGlobalModData at the
--- foot of this file.  memory/caches-must-be-session-scoped-not-process-scoped.
function EP.clearOptionCache()
	optionObjects = {}
end

function EP.getOption(name)
	local option = optionObjects[name]
	if option == nil then
		local ok, found = pcall(function()
			return getSandboxOptions():getOptionByName(EP.MOD_ID .. "." .. name)
		end)

		-- A MISS IS ONLY REMEMBERED WHEN THERE WAS SOMEBODY TO ASK.  `getSandboxOptions`
		-- is absent in a harness and not necessarily ready while Lua files are loading, and
		-- caching `false` from that window would pin this mod to the snapshot for the whole
		-- session - the bug, reintroduced by its own fix.
		if ok then
			option = found or false
			optionObjects[name] = option
		else
			option = false
		end
	end

	if option then
		local ok, value = pcall(option.getValue, option)
		if ok and value ~= nil then return value end
	end

	local options = SandboxVars and SandboxVars[EP.MOD_ID]
	local value = options and options[name]
	if value == nil then return DEFAULTS[name] end
	return value
end

function EP.log(message)
	if not EP.getOption("Debug") then return end
	print("[LGExtendedPlumbing] " .. message)
end

--- A FAULT IS REPORTED ONCE PER SITE, UNLESS THE OPERATOR ASKED FOR ALL OF THEM.
---
--- Every `if not ok then` branch in this mod used to print unconditionally, and most of
--- them sit somewhere that repeats: the square reader is on LoadGridsquare, the mirror
--- settle is on OnWaterAmountChange, the menu builders run on every right-click.  One
--- broken call there is not one line in the log, it is one per square of a streaming
--- world - and a player with Debug off never asked this mod for a single line.
---
--- So the failing SITE is latched.  With Debug off the first failure at a site prints and
--- every later one at that same site is silent, which still tells somebody reading the log
--- that this mod broke and where, without the flood.  With Debug on nothing is latched and
--- every occurrence prints, because that is the setting you turn on to watch a fault.
---
--- `site` must be distinct per call site.  Two handlers sharing one key means the second
--- fault to happen is never reported at all - the same bug as sharing a "reported once"
--- boolean between two handlers, which this mod has had before.
local reportedFaults = {}

function EP.logFault(site, message)
	if EP.getOption("Debug") then
		print("[LGExtendedPlumbing] " .. message)
		return
	end
	if reportedFaults[site] then return end
	reportedFaults[site] = true
	print("[LGExtendedPlumbing] " .. message
		.. " (reported once; turn on the mod's Log plumbing decisions option for the rest)")
end

--- Suites drive many faults through one process and would otherwise see only the first.
function EP.clearFaultLatch()
	reportedFaults = {}
end

--- Is anybody listening?
---
--- EP.log checks the option, but Lua evaluates the argument first - so a log line
--- built from EP.count(sources), or from three getSquare() calls, is paid for on
--- every pass whether or not it is ever printed.  Two of those sat in the hottest
--- paths there are: one per refused fixture per sweep, and one per drink and per
--- wash-cycle minute.  Callers that assemble anything expensive ask this first.
function EP.debugging()
	return EP.getOption("Debug") == true
end

--- Fluid is only ever moved where IsoObject itself moves it: every mutating
--- method in the Java is wrapped in `GameServer.server || !GameClient.client`.
--- A multiplayer client that moved water too would pour the same litre twice.
--- The enclosed, roofed space a square belongs to - a BUILDING that a dedicated server can
--- actually see.
---
--- THIS IS THE ANSWER TO "CAN A SERVER IDENTIFY A PLAYER-BUILT BASE", AND IT IS YES.
---
--- The belief that it could not was about BuildingDef, and about that it is correct:
--- IsoRegions.update calls clientProcessBuildings() inside `if (!GameServer.server)`
--- (IsoRegions.java:213), so the def synthesised for a player structure - and the rooms
--- with it - exists in singleplayer and on every client and never on a server.  A fixture
--- in a player base therefore fails square:isInARoom() on a dedicated server, for ever.
---
--- But the def is not the data, it is a VIEW of the data.  The region graph underneath is
--- server-authoritative: IsoRegions.receiveClientRequestFullDataChunks answers a client's
--- request `if (GameServer.server)` (:194), and the server pushes region updates out to
--- clients.  The server has the regions.  Only the convenience layer over them is skipped.
---
--- So this asks the graph directly, using vanilla's OWN test for "this region is a
--- building" - the exact condition createBuildingsFromRegions uses before it will make a
--- BuildingDef out of one (WorldRegionToMetaGrid.java:184):
---
---     worldRegion.isEnclosed() && !(worldRegion.getRoofedPercentage() < 0.5F)
---
--- Enclosed and mostly roofed.  Without both, the outdoors is one enormous connected region
--- and every barrel in the county would pool together.
---
--- RETURNS THE REGION, NEVER AN ID TO REMEMBER.  IsoWorldRegion has a getID(), and it must
--- not be cached: removeUserDefinedBuildingsFromCell tears the regions of a cell down and
--- rebuilds them whenever a player lays a wall, and a new id comes with them.  That is the
--- same instability that makes poolOf refuse a user-defined def, and it is why this is only
--- ever used as a LIVE comparison between two squares asked in the same breath.
---
--- Guarded throughout.  This reaches into an engine subsystem no other part of the mod
--- touches, on a path that runs per collector, and a build where any of these three methods
--- is absent should cost the player the player-base case rather than the whole mod.
---
--- `evenUnloaded`: ASK THE REGION GRAPH ITSELF WHEN THE SQUARE IS NOT LOADED (BR-LGEP-083).
--- On a server `IsoGridSquare.getIsoWorldRegion` is nothing but
--- `IsoRegions.getIsoWorldRegion(x, y, z)` (`IsoGridSquare.java:10139-10140`), and that graph
--- is loaded from `isoregiondata` at boot and cleared only by a debug reset
--- (`IsoRegionWorker.java:173`) - so it knows a house whose chunk has streamed out. The pipe
--- derivation is the one caller that asks about squares nobody is standing near, and without
--- this a derivation that ran while the players were away cut every run off from the
--- player-built house it fed. Only that caller passes it; every other asker is looking at an
--- object, whose square is loaded by definition.
function EP.buildingRegionAt(x, y, z, evenUnloaded)
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	local region
	if square then
		if not square.getIsoWorldRegion then return nil end
		region = square:getIsoWorldRegion()
	elseif evenUnloaded and z >= 0 and IsoRegions and IsoRegions.getIsoWorldRegion then
		region = IsoRegions.getIsoWorldRegion(x, y, z)
	else
		return nil
	end
	if not region then return nil end
	if not region.isEnclosed or not region.getRoofedPercentage then return nil end
	if not region:isEnclosed() then return nil end
	if region:getRoofedPercentage() < 0.5 then return nil end

	return region
end

--- Is this a place a fixture can be served at all?
---
--- THE ONE GATE, ASKED BY FOUR PLACES THAT MUST NOT DISAGREE.  serviceFixture decides
--- whether a mirror is built; the client decides whether to put up a stand-in, whether to
--- offer the liquid row, and whether to offer Plumb where vanilla will not.  Those four
--- used to be three transcriptions and one of them was short: the client asked
--- `square:isInARoom()` alone, which is the singleplayer half of the question, so a fixture
--- in a player-built structure got a mirror from the server and no menu from the client.
---
--- A ROOM, OR AN ENCLOSED ROOFED REGION.  The second half is what a dedicated server has
--- instead of rooms, and it is also what a client has when the engine threw the synthesised
--- room away - clientProcessBuildings discards any def adjacent to or overlapping a map
--- building (WorldRegionToMetaGrid.java:100-104), and removeRoomDef takes the IsoRoom with
--- it, so a base built against a house has no room in ANY mode.
---
--- Why the two are not the same question, and this is the fact the client half was missing:
--- IsoGridSquare.isInARoom() is `getRoom() != null || getIsoWorldRegion().isPlayerRoom()`
--- (:10429-10431), and isPlayerRoom() is isFogMask(), which is `isEnclosed() &&
--- isFullyRoofed()` - EVERY square roofed (IsoWorldRegion.java:146-158).  Vanilla's own
--- test for "this region is a building" is half roofed, so a structure with one unroofed
--- square in it - a stairwell, a connected porch, a floor laid outside a doorway - is a
--- building to the metagrid and NOT a room to isInARoom().
function EP.canServeHere(x, y, z)
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	if not square then return false end
	if square:isInARoom() then return true end
	-- OR A FLOOR PIPE UNDER IT, which is what a pipe outdoors is for.  This only lets the
	-- group be ASKED; whether anything reaches the fixture is still the group's answer, and a
	-- fixture on a white network, or at barrel height with no pump, gets an empty one.
	if EP.pipeAt and EP.pipeAt(x, y, z) then return true end
	return EP.buildingRegionAt(x, y, z) ~= nil
end

--- Are these two squares inside the same enclosed, roofed space?
---
--- The player-base equivalent of EP.sameDef, and the reason a dedicated server can now pool
--- a shack's barrels with its sink.  Compared by identity where the engine allows it and by
--- id as the fallback, because both ends are resolved in the same call and a rebuild
--- between them is not a case that exists.
function EP.sameBuildingRegion(a, b)
	if not a or not b then return false end
	if a == b then return true end
	if a.getID and b.getID then return a:getID() == b:getID() end
	return false
end

--- How far down a column is worth reading for a structure.
---
--- A barrel is on the roof of the thing it feeds, and the thing it feeds is under it.  Eight
--- covers a player tower without walking B42's whole 31 levels for every candidate, and it
--- is the same order as ROOF_DEPTH, which is the def path's answer to the same question.
local COLUMN_DEPTH = 8

--- The structure a square is IN, ON, or AGAINST, as a set of region ids.
---
--- ONE FUNCTION, ASKED FROM BOTH ENDS.  A fixture and a collector are in the same structure
--- when their two answers intersect - which is the whole membership rule, and the reason it
--- cannot drift the way three transcriptions of servesBuilding's three steps would.
---
--- WHY A SET AND NOT ONE REGION.  An IsoWorldRegion is one z LAYER.  DataChunk's
--- floodFillExpandWorldRegion (:630-651) expands over getConnectedNeighbors() only, and
--- DataChunk links those horizontally - `for (byte dir = 0; dir < 4; dir++)` at :406 - so
--- there is no vertical connectivity in the graph at all.  A two-storey base is two regions
--- and the engine joins them afterwards, by plan, in combineBuildingLevels.  Reading the
--- whole column is how that join is recovered without a second index to keep.
---
--- THE COLUMN DOES NOT STOP AT THE FIRST HIT, and that is deliberately unlike
--- servesBuilding's column walk.  That one stops early because it is deciding WHOSE roof a
--- barrel is on and a terrace must not pool.  This is not deciding whose anything: a column
--- is vertically above itself by construction and cannot cross into next door, so there is
--- nothing for an early stop to protect.  Taking all of it is what makes the relation
--- symmetric - a barrel on a roof and a sink two floors down both answer the same three
--- regions, from either end.
---
--- THE EIGHT NEIGHBOURS ARE THE OVERHANG ANSWER, and are reached only when the whole column
--- came back empty.  A barrel shoved against the outside of a wall stands on grass, which
--- has no solidfloor and so is in no region at all (IsoRegions.calculateSquareFlags:325);
--- the wall square it is leaning on is the room's own edge square and is.  Indoors, on a
--- roof or on a balcony this costs nothing, because the column answered.
---
--- KEYED BY ID AND VALUED BY THE REGION.  The id is what two answers are compared on -
--- Kahlua hands back a fresh wrapper per call, so two wrappers around one region are not
--- equal to each other while two ids are two integers - and the region itself is kept only
--- so EP.regionBounds can read its chunks without asking the graph a second time.  Neither
--- is held across calls: both ends are resolved inside one walk, and a region is rebuilt
--- with a fresh id the moment a player lays a wall.
---
--- Nothing below ground.  IsoGridSquare.getIsoWorldRegion() opens with
--- `if (this.z < 0) return null` (:10410), so a player-dug basement is in no region in any
--- mode.  A MAP basement has a real RoomDef and is answered by the def path instead.
--- THE RULE ITSELF, ONCE, with what to do about each region left to the caller.
---
--- Two consumers want the same three steps and want to stop at different moments:
--- EP.regionsAt wants every region, because a set is what the fixture end is compared
--- against; EP.regionsMeet wants the FIRST region that is already in that set, because a
--- yes is a yes and the rest of the column is work nobody will read.  Written twice they
--- would be two transcriptions of one rule, which is the drift this file complains about
--- everywhere else, so it is written once and the difference is `take`.
---
--- `take(region)` returns true to stop the walk.  Returns true if it stopped, and whether
--- anything at all was found.
local function walkRegions(x, y, z, take, evenUnloaded)
	local any = false

	local bottom = z - COLUMN_DEPTH
	if bottom < 0 then bottom = 0 end
	for cz = z, bottom, -1 do
		local region = EP.buildingRegionAt(x, y, cz, evenUnloaded)
		if region and region.getID then
			any = true
			if take(region) then return true, true end
		end
	end
	if any then return false, true end

	for dy = -1, 1 do
		for dx = -1, 1 do
			if dx ~= 0 or dy ~= 0 then
				local region = EP.buildingRegionAt(x + dx, y + dy, z, evenUnloaded)
				if region and region.getID then
					any = true
					if take(region) then return true, true end
				end
			end
		end
	end

	return false, any
end

--- `evenUnloaded` as EP.buildingRegionAt: the pipe derivation's question, and only its.
function EP.regionsAt(x, y, z, evenUnloaded)
	local found = {}
	local _, any = walkRegions(x, y, z, function(region)
		found[region:getID()] = region
		return false
	end, evenUnloaded)
	return any and found or nil
end

--- Is this square in the same structure as an answer already in hand?
---
--- EP.regionsAt followed by EP.regionsIntersect, with the walk stopped at the first
--- region that matches - which is what the group walk wants, on the one path in this mod
--- that is metered per candidate.
---
--- MEASURED, AND IT SAVES NOTHING AT AN ORDINARY BASE - which is worth writing down,
--- because the obvious reading of "early-out" is that it is a speed-up and here it is not.
--- One fixture settled against 60 collectors costs 182 square lookups at a player base and
--- 284 in the mixed case with the whole set collected, and exactly the same with this.  The
--- reason is that a barrel stands one storey over what it feeds, so its column is two deep
--- and the match is on the second lookup either way: there is nothing after the match to
--- skip.
---
--- It is kept for the shape that is not ordinary.  COLUMN_DEPTH is 8, so a barrel on top of
--- a player tower costs up to 8 lookups per candidate to reject and, without this, 8 to
--- ACCEPT as well.  This makes an accept cost only as much column as it had to read, which
--- bounds the worst case rather than improving the common one.  Re-derive both with
--- tools/luatest/lgep_measure_structures.sh; the table is in
--- plans/player-built-structures.md.
function EP.regionsMeet(x, y, z, set)
	if not set then return false end
	local hit = walkRegions(x, y, z, function(region)
		return set[region:getID()] ~= nil
	end)
	return hit
end

--- Do these two answers describe the same structure?
---
--- Written out rather than inlined because both callers - the group walk and the client's
--- stand-in - must agree, and "non-empty intersection" is the entire membership rule.
function EP.regionsIntersect(a, b)
	if not a or not b then return false end
	for id in pairs(a) do
		if b[id] then return true end
	end
	return false
end

--- The plan a set of regions covers, at CHUNK granularity, or nil.
---
--- For the locality box only - it decides what is CONSIDERED and never what is ACCEPTED, so
--- being loose is free and being expensive is not.  getChunkRegions() hands back the chunk
--- each piece of the structure lives in, so the box costs one pass over those pieces and not
--- one over its squares.
---
--- Returned in the shape EP.buildingBounds uses, so walkBegin's widen() takes either.
function EP.regionBounds(regions)
	if not regions then return nil end

	local bounds = nil
	for _, region in pairs(regions) do
		local chunks = region and region.getChunkRegions and region:getChunkRegions() or nil
		if chunks then
			for i = 0, chunks:size() - 1 do
				local chunk = chunks:get(i)
				local data = chunk and chunk.getDataChunk and chunk:getDataChunk() or nil
				if data then
					local x1 = data:getChunkX() * 8
					local y1 = data:getChunkY() * 8
					local x2, y2 = x1 + 7, y1 + 7
					if not bounds then
						bounds = { minX = x1, minY = y1, maxX = x2, maxY = y2, minZ = 0, maxZ = 0 }
					else
						if x1 < bounds.minX then bounds.minX = x1 end
						if y1 < bounds.minY then bounds.minY = y1 end
						if x2 > bounds.maxX then bounds.maxX = x2 end
						if y2 > bounds.maxY then bounds.maxY = y2 end
					end
				end
			end
		end
	end

	return bounds
end

function EP.isAuthority()
	return not (isClient() and not isServer())
end

--- THE THREE MODES, AND THERE ARE ONLY THREE.
---
---     mode                                isClient()   isServer()
---     singleplayer                        false        false
---     ANY multiplayer client              true         false
---     dedicated OR co-op child server     false        true
---
--- The co-op host has no row of its own, and this is the whole reason these two
--- functions exist rather than the predicates being written out at each call site.
--- Pressing Host in the main menu spawns a SEPARATE JVM - CoopMaster.launchServer
--- builds a ProcessBuilder for `zombie.network.GameServer -coop` - and the host's
--- own game then connects to it over the loopback through the ordinary client path,
--- Core.ResetLua("client") and all.  GameServer.server is set in exactly one place,
--- GameServer.main, so there is no arrangement in which one process is both.
---
--- So the host of a hosted game is a multiplayer client and nothing else.  What is
--- true of them and not of their friends is that they are an ADMIN, which is a
--- different axis entirely and not one this mod may branch on either.
---
--- `isCoopHost()` exists and must never appear in this mod.  It means "I was
--- connection #1 to a -coop server", it is false for everybody on a dedicated
--- server, and vanilla itself uses it twice, both times for cosmetic UI.
function EP.isNetworkClient()
	return isClient() and not isServer()
end

--- Neither end of a wire: the one mode where deciding and drawing are the same VM.
--- Vanilla has no isSinglePlayer(); it writes this double negative too.
function EP.isSingleplayer()
	return not isClient() and not isServer()
end

function EP.key(x, y, z)
	return x .. "," .. y .. "," .. z
end

--- Does this keyed table hold anything?
---
--- Written with pairs because Kahlua has no `next`.  It is standard Lua 5.1 and it
--- is simply absent from the VM Project Zomboid runs on, so `next(t) == nil` - the
--- ordinary way to ask - is a call on a nil value that only shows itself when the
--- line is reached.
function EP.any(t)
	for _ in pairs(t) do return true end
	return false
end

--- How many entries a keyed table holds.  # is no use: these are keyed by string.
function EP.count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

--------------------------------------------------------------------------------
-- how fast this machine actually ticks
--------------------------------------------------------------------------------

--- A DEDICATED SERVER RAISES OnTick TEN TIMES A SECOND.  A CLIENT RAISES IT SIXTY.
---
--- Measured off a real server's log, sustained over four minutes: ninety frames in nine
--- seconds, to three figures, every sample, against 689 frames in 11.9 seconds on the
--- client that was connected to it.  See memory/server-ticks-ten-a-second-client-sixty.md
--- and plans/raw/ee-join-latency-2026-08-14.md, where Extended Electricity found it.
---
--- EVERY DIAL ON THE MAINTENANCE CURSOR WAS A COUNT OF TICKS AND EVERY ONE OF THEM WAS
--- SIZED ON THE SIXTY SIDE, so on the machine that actually owns the water they were all
--- delivering a sixth of what their own comments claimed.  Measured on this harness with a
--- clock (lgep_spec_rate.lua), a thirty-six house town:
---
---     a lap at 60 ticks/s       7.73 s
---     a lap at 10 ticks/s      49.87 s        x6.45
---     mirrors settled/second   13.6 -> 2.5
---
--- A LAP IS EXACTLY HOW LONG A TAP CAN READ THE WRONG NUMBER FOR.  Everything a player
--- does has its own instant path, but the things nothing announces - rain landing, a
--- barrel an admin spawned, a pump that stopped, a mirror that came back from a save
--- wearing last session's ledger - are all noticed by the cursor arriving.  Fifty seconds
--- of that is the "why does it take so long to update on the server" this exists to fix,
--- and it was never the CPU: the same shape of log in Extended Electricity showed the
--- handler using one percent of a frame while the player stood waiting.
---
--- SO THE DIALS ARE EXPRESSED PER SECOND AND DIVIDED BY WHAT THIS MACHINE ACTUALLY DOES.
--- Op counts are kept - the whole reason the budgets are weighted counts and not
--- milliseconds is that a suite can assert on them - and only the divisor is measured.
---
--- Defaults to sixty, which is what everything was written against, so a machine with no
--- clock to ask (this harness, everywhere except lgep_spec_rate) behaves exactly as it
--- always did and every existing reading stays comparable.
---
--- THE FIRST SAMPLE IS TAKEN AT ITS WORD AND THE REST ARE EASED, and the asymmetry is the
--- whole of whether this helps at the moment it is needed.  Easing in from sixty would
--- take five or six samples to reach ten - the first ten seconds of a server's life, which
--- is exactly when a player is joining and every tap is showing last session's figure.
--- Afterwards a reading that says the machine got SLOWER is adopted slowly, because the
--- reward for believing it is a bigger purse per tick and handing a bigger purse to a
--- machine that is already struggling is how a stutter becomes a stall.  A reading that
--- says it got faster is taken at once: that direction only ever makes each tick cheaper.
---
--- AND EASING IS A DELAY RATHER THAN A GUARD, WHICH IS WHERE THE HITCH LIVES.
---
--- Sustain the slower frames for a few seconds - which is exactly what zooming the
--- camera out does - and the rate converges anyway, and then every purse below really
--- is bigger on the machine that could least afford one.
---
--- THE ERROR IS TREATING TWO DIFFERENT CAUSES OF A LOW TICK RATE AS ONE.  A dedicated
--- server raises ten ticks a second BECAUSE IT IS IDLE: it renders nothing, so a
--- hundred-millisecond frame really does hold ten times a sixtieth of a second's work
--- and a proportional purse is honest - that is what sections 1-5 of lgep_spec_rate
--- prove.  A machine that is DRAWING raises twenty ticks a second because the frame is
--- already full, and dividing by twenty hands out three times the work per frame at
--- precisely the moment there is least room for it.  It compounds, too: the longer
--- frame lowers the next reading, which raises the purse again.
---
--- So wherever frames are drawn the divisor gets a FLOOR - the target framerate, which
--- the engine exposes and vanilla already reads (`getPerformance():getFramerate()`,
--- MainOptions.lua:564).  A dropped frame can never buy a bigger purse.  What a
--- struggling machine gets instead is a longer lap, which is the right trade: it has
--- less to give per second, so it should do less per second rather than more per frame.
---
--- Transcribed from LGEECore, where it was measured; see
--- plans/hitch-the-divisor-inverts-under-load.md.
local TICKS_DEFAULT = 60
local TICK_SAMPLE_MS = 1000
local EASE_SLOWER = 0.35

local sampleStart, sampleTicks = nil, 0
local measuredRate = nil

--- The target framerate, re-read once a sample window rather than per budget.
---
--- A player can change it in the options mid-session, so it is not a constant; and the
--- cursor asks for a budget several times a step, so it is not something to cross into
--- Java for each time.  Once a second is both.
local targetRate = nil

local function refreshTargetRate()
	if not getPerformance then return end
	local ok, n = pcall(function() return getPerformance():getFramerate() end)
	if ok and type(n) == "number" and n >= 1 and n <= 240 then targetRate = n end
end

--- Called once per tick, first thing, from the maintenance handler.  Two additions and a
--- comparison.
function EP.sampleTick()
	if not getTimeInMillis then return end
	local now = getTimeInMillis()
	if not sampleStart then sampleStart = now end

	sampleTicks = sampleTicks + 1
	local elapsed = now - sampleStart
	if elapsed < TICK_SAMPLE_MS then return end

	local rate = sampleTicks * 1000 / elapsed
	-- Clamped either side of anything sane.  A machine that hitched through the whole
	-- sample would otherwise hand out a rate that made every purse enormous on the tick
	-- after it recovered, which is the one moment it can least afford one.
	if rate < 1 then rate = 1 end
	if rate > 240 then rate = 240 end

	if not measuredRate then
		measuredRate = rate
	elseif rate >= measuredRate then
		measuredRate = rate
	else
		measuredRate = measuredRate + (rate - measuredRate) * EASE_SLOWER
	end

	sampleStart, sampleTicks = now, 0
	refreshTargetRate()
end

--- How many ticks a second this machine really raises.
function EP.ticksPerSecond()
	return measuredRate or TICKS_DEFAULT
end

--- WHAT A PER-SECOND ALLOWANCE IS DIVIDED BY, WHICH IS NOT ALWAYS WHAT THE MACHINE DOES.
---
--- See the long note on TICKS_DEFAULT.  On a dedicated server the measured rate is the
--- honest divisor; anywhere a frame is drawn it is floored at the target framerate, so a
--- machine losing frames takes a longer lap rather than a longer frame.
---
--- `isServer()` and not `EP.isAuthority()`: singleplayer is an authority AND draws, and
--- it is the mode this was reported from.
function EP.budgetRate()
	local tps = EP.ticksPerSecond()
	if isServer() then return tps end

	local floor = targetRate or TICKS_DEFAULT
	if tps < floor then return floor end
	return tps
end

--- How much of a per-second allowance belongs to one tick.
---
--- Rounded up rather than down and floored at one: a rate that divided to nothing would be
--- a cursor that never advanced, which is worse in kind than one that advances slightly
--- fast.
function EP.perTick(perSecond)
	local n = math.ceil(perSecond / EP.budgetRate())
	if n < 1 then n = 1 end
	return n
end

--- How many ticks a number of REAL seconds is on this machine.
function EP.ticksFor(seconds)
	local n = math.floor(seconds * EP.ticksPerSecond() + 0.5)
	if n < 1 then n = 1 end
	return n
end

--------------------------------------------------------------------------------
-- handler time, in milliseconds

--- WHAT THIS MOD ACTUALLY COSTS, IN THE ONLY UNIT A PLAYER FEELS.
---
--- Every performance reading this mod has ever had is in OPERATIONS - a counter in the
--- test harness that ticks once per crossing into Java.  That unit is good for comparing
--- two builds on one bench and it cannot answer the only question that matters on a
--- low-end machine: how much of a frame did that take.  There is no conversion, because
--- an operation is a grid lookup here and a fluid-container read there and they are not
--- the same price.
---
--- Extended Electricity has had `EE.timed` in production for exactly this reason, and its
--- logs are why LGEE could be declared finished with a number rather than an opinion
--- (`sweep 10 calls, 14 ms total, 3 ms worst`).  This mod had nothing, so the live server
--- has never reported a single millisecond from it.  Transcribed from `LGEECore.lua:494`
--- including the two details below, both of which were bought with a defect there.
---
--- Off unless Debug is on, and the gate is the FIRST thing every wrapper does, so a
--- server running normally pays one boolean per call.
EP.perf = {}

local perfOrder = {}

local function perfRow(name)
	local row = EP.perf[name]
	if not row then
		row = { calls = 0, total = 0, worst = 0 }
		EP.perf[name] = row
		perfOrder[#perfOrder + 1] = name
	end
	return row
end

--- Run `fn(a, b, c)` and, with Debug on, remember what it cost.
---
--- THREE PASS-THROUGH ARGUMENTS AND NOT TWO, and this is not defensiveness.  The same
--- wrapper in LGEE was written with two, the sweep was called through it as
--- `pcall(EE.rebuild, budget, rotating)`, and the third argument was dropped silently -
--- so every lap ran with `rotating` nil, the net under the events stopped running, and
--- nothing errored and nothing showed.  A timing wrapper that changes behaviour when it
--- is switched on is worse than no timing wrapper.
---
--- getTimeInMillis is the coarsest useful clock the game exposes to Lua, so a single call
--- to something short reads as zero.  That is why the TOTAL over a reporting window is
--- printed rather than an average: a handler costing half a millisecond that runs four
--- hundred times a second is invisible per call and is a fifth of the frame budget, and
--- that shape is precisely what is being hunted.
function EP.timed(name, fn, a, b, c)
	if not EP.getOption("Debug") then return fn(a, b, c) end
	if not getTimeInMillis then return fn(a, b, c) end

	local started = getTimeInMillis()
	local result = fn(a, b, c)
	local spent = getTimeInMillis() - started

	local row = perfRow(name)
	row.calls = row.calls + 1
	row.total = row.total + spent
	if spent > row.worst then row.worst = spent end

	return result
end

--- The same thing for a stretch of code rather than a call.
---
--- EP.timed needs a function, and wrapping the phases inside a settle in closures would
--- allocate one per phase per settle for the sake of measuring them.  These two bracket a
--- block instead, so a phase costs two table lookups and a subtraction.
local marks = {}

--- WHETHER DEBUG IS ON, READ ONCE A TICK RATHER THAN TWICE A SQUARE.
---
--- markStart and markEnd bracket the streaming handlers, which run once per square of every
--- chunk that opens -- so `EP.getOption("Debug")` was being asked twice for every square in
--- the world, and it is two table lookups and a function call each time.  Measured at
--- 0.615 us a call, so 1.23 us of every 21.3 us square: SIX PER CENT of the streaming path
--- spent deciding not to measure anything, paid by every player who has Debug off, which is
--- all of them.
---
--- Refreshed from the shared OnTick handler at the foot of this file, which runs on every
--- machine and above every gate.  The cost of the staleness is that turning Debug on takes
--- effect on the next tick instead of the next square, which nobody can perceive.
---
--- Starts FALSE, so anything bracketed before the first tick is not measured.  That is the
--- honest default: a reading taken during load is not a reading of the game.
local debugOn = false

function EP.refreshDebugFlag()
	debugOn = EP.getOption("Debug") == true
end

function EP.markStart(name)
	if not debugOn then return end
	if not getTimeInMillis then return end
	marks[name] = getTimeInMillis()
end

function EP.markEnd(name)
	if not debugOn then return end
	if not getTimeInMillis then return end

	local started = marks[name]
	if not started then return end
	marks[name] = nil

	local row = perfRow(name)
	local spent = getTimeInMillis() - started
	row.calls = row.calls + 1
	row.total = row.total + spent
	if spent > row.worst then row.worst = spent end
end

--- What the figures should be read against, if this side knows.
---
--- Set by LGEPPlumbing, which owns the registries.  Absent on a multiplayer client, where
--- that file does not execute at all - and correctly so, because a client HAS no registry
--- to describe.  A client's lines stand on their own.
EP.perfScale = nil

--- Print what has been collected and start again.
---
--- `window` is how long the figures cover, in REAL seconds, so the "per second" column
--- means something on a machine whose tick rate is not sixty - which is every dedicated
--- server (`memory/server-ticks-ten-a-second-client-sixty.md`).
function EP.reportPerf(window)
	if not EP.getOption("Debug") then return end
	if #perfOrder == 0 then return end
	if not window or window <= 0 then return end

	print(("[LGExtendedPlumbing] --- %d s of handler time, %d ticks/s ---")
		:format(window, EP.ticksPerSecond()))
	for i = 1, #perfOrder do
		local name = perfOrder[i]
		local row = EP.perf[name]
		if row and row.calls > 0 then
			print(("[LGExtendedPlumbing]   %-22s %6d calls %7d ms total %5d ms worst %6.1f ms/s")
				:format(name, row.calls, row.total, row.worst, row.total / window))
			row.calls, row.total, row.worst = 0, 0, 0
		end
	end
end

--- How often the figures are printed, in REAL seconds.
---
--- Twenty-five, matching the window LGEE reports on, so the two mods' lines in one console
--- can be read against each other without arithmetic.
local PERF_WINDOW_SECONDS = 25
local perfWindowStarted = nil

--- Drive the reporting window.  Called once per tick from the handler below.
---
--- IN THE SHARED FILE, AND THAT IS THE WHOLE POINT OF IT BEING HERE.  It lived in
--- LGEPPlumbing's OnTick first, which is wrong in the one direction that matters:
--- `if isClient() then return end` at the top of that file means a MULTIPLAYER CLIENT
--- NEVER REGISTERS AN OnTick AT ALL - so the client's own timings were being collected into
--- EP.perf by markStart/markEnd and then never printed by anybody.  The side whose frames
--- are 16 ms instead of 100 was the side that could not report.
function EP.reportPerfWindow()
	if not EP.getOption("Debug") then
		perfWindowStarted = nil
		return
	end
	if not getTimeInMillis then return end

	local now = getTimeInMillis()
	if not perfWindowStarted then perfWindowStarted = now; return end

	local elapsed = (now - perfWindowStarted) / 1000
	if elapsed < PERF_WINDOW_SECONDS then return end
	perfWindowStarted = now

	if EP.perfScale then
		local ok, line = pcall(EP.perfScale)
		if ok and line then print("[LGExtendedPlumbing] " .. line) end
	end
	pcall(EP.reportPerf, elapsed)
end

--- Is maintenance parked, rather than merely between laps?
---
--- True when this side does not run maintenance at all, when the mod is switched off, or
--- when nothing whatever has been filed.  It exists because "has a lap completed" stops
--- being a meaningful question in those states - no lap will EVER complete - and anything
--- waiting on one would wait for ever.
---
--- DECLARED HERE, ABOVE EVERY GATE, for the same reason the reporting window above is.
--- It used to be declared in LGEPPlumbing, below that file's `if isClient() then return
--- end`, so on a multiplayer client - the one side the flag exists to describe - it was
--- never set at all.  It read nil, not true, and anything waiting for a lap on a client
--- waited for ever: the harness's SWEEP() spun to its 200000-tick ceiling and failed the
--- suite with a message about the cursor, which was not the thing that was wrong.
---
--- The authority overwrites this every tick; on any other side it simply stays true.
EP.maintenanceIdle = true

--- The one OnTick this mod registers on EVERY machine.
---
--- Two jobs, both of which are properties of the MACHINE rather than of what the mod is
--- doing, which is why they belong here rather than behind any gate:
---
---   * sample the tick rate - a dedicated server raises OnTick ten times a second and a
---     client sixty (memory/server-ticks-ten-a-second-client-sixty.md), and every dial in
---     the maintenance cursor is derived from it;
---   * drive the reporting window.
---
--- Registered in the SHARED file so a multiplayer client gets both.  Loaded before
--- LGEPPlumbing (which requires this file), so this handler runs first on the machines that
--- have both - which is what `sampleTick` has always needed.
Events.OnTick.Add(function()
	-- FIRST, because the two calls below are themselves bracketed by markStart/markEnd on
	-- some paths, and a flag refreshed after them would be a tick behind for no reason.
	EP.refreshDebugFlag()
	EP.sampleTick()
	EP.reportPerfWindow()
end)

--- The option objects belong to the world that built them; see EP.clearOptionCache.
--- OnInitGlobalModData because it is raised on every side, dedicated server included, and
--- before anything this mod does with an option.
Events.OnInitGlobalModData.Add(function()
	EP.clearOptionCache()
end)

--------------------------------------------------------------------------------
-- the ghost's sprite
--------------------------------------------------------------------------------

--- The one shared instance, remembered so EP.isGhost can compare against it without
--- going back to IsoSpriteManager for every object it is asked about.
---
--- Only ever written by EP.ensureGhostSprite, and written on every call rather than
--- only the first, so it cannot outlive the manager it came from: anything that
--- rebuilds IsoSpriteManager also runs OnGameBoot, which calls that function again.
--- A stale instance would be worse than none, because the comparison it feeds is an
--- identity test.
local ghostSprite = nil

--- IsoSpriteManager.getSprite creates the sprite when the name is unknown, and
--- LoadSingleTexture on a name with no texture behind it just leaves the texture
--- null - which is the normal state of every sprite on a dedicated server, so
--- there is nothing unusual about it.  The object never renders anyway.
---
--- The blueprint flag is the point of registering rather than letting the
--- IsoThumpable constructor conjure the sprite for itself.  IsoGridSquare
--- RecalcProperties skips any object whose sprite properties carry it, before
--- reading a single flag off them - so a ghost contributes nothing at all to its
--- square: no solid, no collideN/W, no solidfloor, no cutaway, no vision block.
--- (Whole-jar check: the only other reference to the flag is a debug draw in
--- ServerGUI.)
---
--- Run on both sides.  A client that had not registered it would still receive
--- the ghost and still not draw it, but the square it landed on would be built
--- from an empty property set rather than a skipped one - the same answer today,
--- and not something to leave resting on a coincidence.
function EP.ensureGhostSprite()
	local sprite = IsoSpriteManager.instance:getSprite(EP.GHOST_SPRITE)
	if not sprite then return nil end

	-- Name it, because the manager does not.
	--
	-- IsoSpriteManager.AddSprite is three lines - `new IsoSprite(this)`,
	-- `LoadSingleTexture(tex)`, `namedMap.put(tex, spr)` - and LoadSingleTexture
	-- assigns only `this.texture`.  The name it is filed under never reaches the
	-- sprite, so getName() stays null; IsoObject.getSpriteName() then falls through
	-- to the object's own spriteName field, which a Lua-built object has not got
	-- either, and answers null.
	--
	-- Null is not a cosmetic problem.  ISWorldObjectContextMenuLogic
	-- .doFluidContainerMenu opens with
	--
	--     Texture isTrough = Texture.trygetTexture(object.getSpriteName());
	--
	-- and trygetTexture dereferences before it checks: `name.endsWith(".png")`.  So
	-- right-clicking anywhere a mirror stands threw NullPointerException out of
	-- createMenuEntries - in Java, inside the world menu, where no pcall of ours sits
	-- between it and the player.  The whole context menu died, not just this mod's
	-- entries, and it read as the server being broken.
	--
	-- A name that resolves to no texture is perfectly safe: trygetTexture looks for
	-- media/textures/<name>.png, does not find it, and returns null, which is a
	-- result every caller already handles (`if (isTrough instanceof Texture)`).
	--
	-- Filtering mirrors out of the menu is kept as well, but it cannot be what this
	-- rests on: that filter is a wrapper on ISWorldObjectContextMenu.createMenu, and
	-- nothing stops another mod assigning straight over that field without calling
	-- through, which drops every wrapper already on it - load order decides.  A
	-- mirror has to be harmless to code that never heard of it.
	--
	-- (This used to say `require` re-derives the table.  It does not; requiring an
	-- already-loaded file is a no-op - see the note in LGEPPower.lua.)
	if sprite.setName and sprite:getName() == nil then
		sprite:setName(EP.GHOST_SPRITE)
	end

	local props = sprite:getProperties()
	if not props:has(IsoFlagType.blueprint) then
		props:set(IsoFlagType.blueprint)
		props:CreateKeySet()
	end

	ghostSprite = sprite
	return sprite
end

Events.OnGameBoot.Add(EP.ensureGhostSprite)

-- [Malcolm_Perf] Build the building plan index (relaxIndex below) at start, on the loading
-- screen, instead of inside the first chunk load that needs it.  A lookup at a square that is
-- not loaded takes the plan path, which is what builds it.
local function warmBuildingIndex()
	if not EP.buildingAt then return end
	local ok, err = pcall(EP.buildingAt, 0, 0, 0)
	if not ok then EP.log("building index warm-up failed (harmless): " .. tostring(err)) end
end
if Events.OnGameStart then Events.OnGameStart.Add(warmBuildingIndex) end
if Events.OnServerStarted then Events.OnServerStarted.Add(warmBuildingIndex) end

--- Put the registered sprite back on a mirror that has lost it.
---
--- It loses it on every save and every transmission, and that is the engine rather
--- than anything here.  IsoObject.save writes the sprite by NUMERIC ID
--- (`output.putInt(this.sprite.id)`), and IsoSpriteManager.AddSprite(String) - the
--- one getSprite() falls through to for a name it has never seen - neither assigns
--- an id nor files the sprite in intMap.  So ours keeps IsoSprite.DEFAULT_SPRITE_ID
--- (20000000), the load-side `intMap.get(id)` misses, and IsoObject.load ends with
---
---     if (this.sprite == null) {
---        this.sprite = IsoSprite.CreateSprite(IsoSpriteManager.instance);
---        this.sprite.LoadSingleTexture(this.spriteName);   // spriteName is null
---     }
---
--- A brand new private sprite: no name, and an empty property set.  Both halves
--- matter, and neither is cosmetic:
---
---   * getSpriteName() is null again, which is the NullPointerException out of
---     ISWorldObjectContextMenuLogic.doFluidContainerMenu that the long note in
---     EP.ensureGhostSprite exists to prevent.  Naming the SHARED sprite never
---     helped a mirror that is not pointing at it, so every mirror out of a save
---     file or off the wire had the fault the whole time - and the only thing
---     standing between a player and it was the two menu filters, which that same
---     note says must not be what this rests on.
---
---   * the blueprint flag is gone, so IsoGridSquare.RecalcProperties no longer
---     SKIPS the mirror.  It contributes nothing either way today, because an empty
---     property set adds no properties - but "contributes nothing" is supposed to be
---     structural here, not a coincidence about what happens to be in the container.
---
--- setSpriteFromName rather than setSprite: it resolves through namedMap, so it
--- hands back the one shared instance rather than conjuring another anonymous one
--- the way setSprite(String) does.
---
--- Compared before assigning, so a mirror that already holds the right sprite -
--- which is every mirror this session made - costs one pointer comparison.  Nothing
--- is recalculated afterwards on purpose: the square's aggregate is identical
--- either way, since what is being restored is an instruction to ignore the object.
function EP.fitGhostSprite(ghost)
	local sprite = EP.ensureGhostSprite()
	if not sprite then return end
	if ghost:getSprite() == sprite then return end
	ghost:setSpriteFromName(EP.GHOST_SPRITE)
end

--------------------------------------------------------------------------------
-- what things are
--------------------------------------------------------------------------------

--- Is this one of ours?
---
--- modData first, because it is what survives both the save file and the wire.
---
--- The fallback under it is NOT the sprite name.  A name is a weaker claim - another
--- mod could name one the same - and that objection is why this used to test modData
--- and nothing else.  It does not reach an identity test: IsoSpriteManager keeps one
--- shared instance per name in namedMap and EP.ensureGhostSprite hands back that
--- instance, so `getSprite() == ghostSprite` is true of our sprite and of nothing
--- else in the game, whatever anybody calls theirs.
---
--- It is here because this function is a load-bearing safety gate and was resting on
--- one field.  IsoObject.hasModData() is
---
---     return this.table != null && !this.table.isEmpty();      (IsoObject.java:1003)
---
--- so an EMPTY modData table answers false, not just a missing one - and every guard
--- in this mod is downstream of this call.  A mirror that arrived without its modData
--- was invisible to hide(), to prepareMenu, to stripGhostsFromFetch and to dressGhost
--- simultaneously, and a mirror invisible to all four is precisely the
--- NullPointerException out of doFluidContainerMenu that EP.fitGhostSprite exists to
--- prevent.  One answer standing between a player and a dead context menu is one too
--- few; a mirror has to be recognisable by what it IS.
---
--- Cost on the hot path is unchanged for the ordinary case - a mirror answers on the
--- first branch and never reaches the second.  The fallback is two local reads for
--- everything else, against a cached instance rather than a call into the sprite
--- manager, because discover()'s box walk asks this about every object it passes.
function EP.isGhost(object)
	if not object then return false end

	-- A REAL WORLD OBJECT IS NEVER ONE OF OURS, WHATEVER ITS modData SAYS.
	--
	-- This test is first because everything downstream of a wrong answer here is
	-- destructive and unrecoverable, and a single stray modData write was enough to get
	-- one.  What an object answering yes by mistake gets:
	--
	--   * EP.dressGhost, from the client's LoadGridsquare walk - setDoRender(false), which
	--     is the first gate in IsoObject.render AND the branch that calls
	--     updateRenderInfoForObjectPicker.  So the object is not merely undrawn, it is
	--     never handed to the picker: it cannot be moused over, outlined or clicked, and
	--     it is absent from `worldobjects`, so it gets NO rows in a menu that otherwise
	--     builds perfectly.  setIsContainer(false) and setName("") go with it.
	--   * EP.fitGhostSprite, which replaces its sprite with ours - and that is what makes
	--     the mistake PERMANENT.  From then on the identity test below answers yes on its
	--     own, so the object is re-dressed on every chunk load for the rest of the save.
	--     A relog cannot clear it; a server restart cannot clear it.
	--   * EP.sleepGhost and EP.removeGhost, which call fc:Empty() on what they are handed.
	--
	-- HOW A REAL OBJECT COULD GET THE KEY.  ObjectModDataPacket is addressed by the
	-- object's INDEX in its square's object list and carries no identity at all
	-- (MovingObject.set: `objectId = square.getObjects().indexOf(o)`), and its parse either
	-- loads the sender's whole table onto whatever is at that index or, when the sender's
	-- table is empty, calls `object.getModData().wipe()` on it.  So one misaddressed packet
	-- can hand a rain barrel a mirror's KEY_GHOST - or erase its KEY_INCLUDE, which reads
	-- to a player as the barrel quietly unplumbing itself.
	--
	-- THE TEST.  A mirror's sprite is ours or it is nothing: EP.spawnGhost builds it with
	-- EP.GHOST_SPRITE, and one that has been through IsoObject.load - off the disk or off
	-- the wire - carries an anonymous sprite whose getSpriteName() is null, because
	-- IsoObject.save writes the sprite by numeric id and ours never gets one.  A real rain
	-- barrel's is a named tile: carpentry_02_122.  So a NAME that is neither nil nor ours
	-- is proof the object is not a mirror, and it is proof no matter what its modData has
	-- been told.
	--
	-- Deliberately not a repair.  An object already dressed is pointing at our sprite and
	-- this cannot tell it from a real mirror any more; the recovery for one of those is
	-- still to pick it up and put it down, which builds a fresh object.  What this stops is
	-- the next one.
	if object.getSpriteName then
		local name = object:getSpriteName()
		if name ~= nil and name ~= EP.GHOST_SPRITE then return false end
	end

	if object:hasModData() and object:getModData()[EP.KEY_GHOST] == true then
		return true
	end

	-- Not `if not ghostSprite then ensureGhostSprite() end`: the cache is filled by
	-- OnGameBoot before any mirror can exist, and an object is not ours just because
	-- we have not looked yet.  Answering false until then is the same answer.
	return ghostSprite ~= nil and object:getSprite() == ghostSprite
end

--- An object the menu cannot safely be built from, whoever made it.
---
--- doFluidContainerMenu opens with `Texture.trygetTexture(object.getSpriteName())`
--- and trygetTexture dereferences before it checks - `name.endsWith(".png")` - so an
--- object with no sprite name is a NullPointerException thrown out of Java in the
--- middle of the menu.  ISWorldObjectContextMenu.getMoveableDisplayName reaches the
--- same kind of ground from Lua.  Whatever such an object is, it was never going to
--- draw: something is asking for its icon and there is no name to look one up by.
---
--- Deliberately not a test for one of ours.  The case that produced it was a mirror
--- this mod could not recognise as its own, and the fix that only covered our
--- objects would have missed exactly that one.  Declining any nameless object costs
--- a menu entry that could not have appeared.
---
--- Guarded rather than assumed, because this is called on objects that arrived from
--- somewhere else: getSpriteName is IsoObject's and is always there, but this reads
--- a table the engine owns and the whole point of the function is that its callers
--- are past the point of trusting what is in it.
function EP.isNameless(object)
	if not object or not object.getSpriteName then return false end

	local ok, name = pcall(object.getSpriteName, object)
	return ok and name == nil
end

--- A barrel Extended Electricity has taken over as a fuel holder.
---
--- The engine will not let one vessel be both anyway - Petrol's BlendWhiteList
--- admits only the Fuel category, so canAddFluid refuses petrol into water and
--- water into petrol - but that is about what is in it, and this is about what it
--- is FOR.  A barrel somebody has run a fuel line off is spoken for even while it
--- is empty, and quietly counting it toward a building's water would be a supply
--- that reads full and pours nothing.
---
--- Read off Extended Electricity's documented key rather than asked of it.  There
--- is nothing to detect and nothing to require: the key is simply absent when that
--- mod is not installed, and this file has no opinion about whether it is.
---
--- Deliberately here, in the qualifier, and not in the menu.  This one site is
--- what notice(), supplyGroup, visibleSupplyGroup, sourceOnSquare/sourceAt, the
--- menu loop and onWaterAmountChange all pass through - so a fuel barrel is not
--- merely un-offered, it is absent, and EP.setIncluded cannot be talked into
--- taking it back by a stale client either, because sourceAt returns nil for it.
--- hasModData() answering false for an empty table is the right answer here, unlike in
--- EP.isGhost above: a barrel nobody has run a fuel line off is an ordinary barrel, so
--- the fallible direction is "counts as water", which is what it already was.
local function isFuelHolder(object)
	if not object or not object:hasModData() then return false end
	return object:getModData().LGEEFuel == true
end

--------------------------------------------------------------------------------
-- the things the supply FEEDS instead of drawing from
--------------------------------------------------------------------------------

--- A WATER DISPENSER IS NOT A BARREL, AND UNTIL NOW THIS MOD COULD NOT TELL.
---
--- IsoGridSquare.addWorkstationEntity builds an IsoThumpable (:11365), and the water
--- dispenser's entity script gives it a FluidContainer of 15 litres - so a dispenser a
--- player has PUT DOWN answers every one of FindWaterSourceOnSquare's four questions and
--- was a collector as far as everything here was concerned.  Plumb it in and the office
--- cooler was feeding the taps.
---
--- That is backwards.  A dispenser is a thing you FILL, and this list is how an operator
--- says so: an id on it stops being a barrel and becomes a fixture that the building's
--- supply tops up, out of the same barrels a tap draws on.
---
--- ONLY A PLAYER-PLACED ONE WAS EVER A COLLECTOR, WHICH IS WORTH KNOWING BEFORE READING
--- THE REST.  CellLoader never constructs an IsoThumpable - every branch of it makes an
--- IsoObject, an IsoWindow, an IsoDoor or a fireplace (CellLoader.java:126-336) - so a
--- dispenser standing in an office off the map is a plain IsoObject, invisible to
--- FindWaterSourceOnSquare and invisible to this mod.  Being fed does NOT go through
--- IsoThumpable, so this list covers both, and a map dispenser gains a behaviour it never
--- had rather than losing one.
---
--- IT IS THE ENTITY SCRIPT, AND THE ENTITY SCRIPT IS THE ONLY ID THE OBJECT CARRIES.
---
--- `Mov_WaterDispenser` is the obvious string to reach for and it is the wrong one: it is
--- an ITEM in scripts/generated/items/moveable.txt, no tile in the game names it as its
--- CustomItem, and nothing on a placed dispenser has ever held it.  What the object holds
--- is EntityScriptInfo.originalScript, which setOriginalScript fills from
--- getScriptObjectFullType() - so `Base.WaterDispenser`, saved with the object and sent
--- over the wire with it.
---
--- BOTH SPELLINGS ARE ACCEPTED, and which one is "right" is a question the engine has
--- already answered inconsistently, so this follows it rather than picking a side:
---
---   * SpriteConfigManager.parseEntityScript writes `props.set("EntityScriptName",
---     entityScript.getName())` - the UNQUALIFIED name - onto every sprite an entity
---     claims (:138).  That is the string the engine itself looks the entity up by when a
---     cell loads.
---   * ScriptBucketCollection.getScript then resolves a name with no "." in module BASE
---     and nowhere else (:77-78).  So an entity outside Base whose short name collides
---     with a Base one cannot be instantiated from a sprite at all - vanilla would build
---     the Base one instead.  The short-name space is effectively flat because the engine
---     treats it as flat.
---   * getScriptObjectFullType is module-qualified all the same, and two mods really can
---     define `Whatever.WaterDispenser` and `Base.WaterDispenser` as different scripts.
---
--- So an entry with a "." in it is matched against the full type and an entry without one
--- against the short name.  An operator who has never heard of modules writes
--- `WaterDispenser` and gets the dispenser; one disambiguating two mods writes
--- `Base.WaterDispenser` and gets exactly that one.  Neither spelling can match the other
--- by accident, because the two are compared against different strings.
---
--- AN OBJECT WITH NO ENTITY SCRIPT CANNOT BE LISTED, deliberately, and there is no sprite
--- name fallback.  A FluidContainer comes from a `component FluidContainer` block on an
--- entity, so anything this list could usefully name has one; a second way to spell an id
--- would be a second thing to keep in step for a case that does not arise, and it would
--- cost a Java call per object on the chunk-streaming path to check.

--- THE PLUMBING LIVES ON THE SQUARE, NOT ON THE OBJECT, AND THE ENGINE LEAVES NO CHOICE.
---
--- Everywhere else in this mod a decision is recorded in the modData of the thing it is
--- about: KEY_INCLUDE on the barrel, KEY_FLUID on the fixture.  For a listed fixture that
--- would be thrown away by an ordinary act of play.
---
--- ISAddTakeDispenserBottle:complete() does not modify the dispenser when a bottle comes off
--- or goes on.  It DESTROYS it and builds another:
---
---     self.square:transmitRemoveItemFromSquare(self.waterdispenser)
---     self.square:RemoveTileObject(self.waterdispenser)
---     local newdispenser = self.square:addWorkstationEntity("WaterDispenserNoBottle", sprite)
---
--- addWorkstationEntity is `new IsoThumpable(...)` plus GameEntityFactory.CreateIsoObjectEntity
--- (IsoGridSquare.java:11365-11374), so what comes back is a brand new object with an empty
--- modData table.  Anything this mod had written on the old one is gone - and it goes twice,
--- because putting the bottle back builds a third object.  A player changing a bottle would
--- have had to re-plumb the dispenser and re-choose its liquid every time, for a reason
--- nothing in the game would explain to them.
---
--- The square survives all of it.  IsoGridSquare has its own modData and it is saved with
--- the chunk under bit 2 of the square's flags (:3001-3004) and read back at :3394, so it
--- outlives the object, the save file and the session.
---
--- WHAT THAT MEANS, STATED PLAINLY BECAUSE IT IS A REAL DIFFERENCE AND NOT A DETAIL: the
--- pipe is in the floor rather than in the appliance.  Take a plumbed dispenser away and
--- stand a different one in the same spot and it is plumbed, to the same liquid.  That is
--- the honest reading of what was actually done - somebody ran a pipe to that spot - and it
--- is undone by the same Disconnect row that undoes everything else here.
---
--- KEY_INCLUDE IS DELIBERATELY NOT REUSED.  It is the collector flag and it stays exactly
--- what it is: an object that was plumbed in as a barrel before its id went on the list
--- keeps that flag untouched, and gets it back the moment the id comes off again.  Two
--- questions, two keys, no object that has to be asked which one it is answering.
EP.KEY_FED       = "LGEPFed"        -- on the SQUARE: a listed fixture here is plumbed in
EP.KEY_FED_FLUID = "LGEPFedFluid"   -- on the SQUARE: which liquid it draws.  nil is water.

--- AND A COPY ON THE OBJECT, BECAUSE A SQUARE'S MODDATA NEVER REACHES A CLIENT.
---
--- This is the half the square cannot do, and leaving it out shipped a fault that was
--- invisible in singleplayer and total on a server: the dispenser filled correctly, because
--- the authority was reading the square and the square was right - and the Plumb row never
--- went away, because the client was reading the same square and had never been told.
---
--- IsoGridSquare has no transmit of any kind for its modData.  It is written into the chunk
--- (IsoGridSquare.save :3001-3004) and it reaches a client exactly once, when the chunk
--- does; nothing re-sends it, so a decision taken while somebody is standing there is a
--- decision they will not see until the chunk is streamed again.  IsoObject.transmitModData
--- is the channel that does work, and it is the one KEY_INCLUDE has always used.
---
--- SO THE SQUARE IS THE TRUTH AND THE OBJECT CARRIES A COPY OF IT.  Neither alone is
--- enough, and which is which is decided by what each side actually knows:
---
---     the SQUARE survives the object being destroyed and rebuilt, which the bottle does
---     twice per swap - so it is what the authority reads, and what a save keeps
---     the OBJECT is the only thing that can be pushed to a client mid-session - so it is
---     what a client reads
---
--- The copy is re-stamped by the maintenance pass rather than only at the moment of the
--- decision, which is what makes it self-healing: an object rebuilt by a bottle change comes
--- back blank and is stamped again on the next lap, and a stamp that disagrees with the
--- square is cleared on the same pass.
EP.KEY_FED_ON = "LGEPFedOn"          -- on the OBJECT: the transmitted copy of KEY_FED

--- Is a listed fixture standing here plumbed into the building's supply?
---
--- `object` is optional and is only consulted on a network client, where the square's own
--- modData is stale by construction.  Deliberately a mode branch rather than "read the
--- object, fall back to the square": on the AUTHORITY the object is wrong after every
--- rebuild until the next lap re-stamps it, and the authority is the side that decides.
---
--- hasModData() first, which answers false for an empty table as well as a missing one
--- (IsoObject.java:1003, and the square's is the same shape).  That is the right way round
--- here: the fallible direction is "not plumbed", which is what every square in the world
--- already is.
function EP.isFedPlumbed(square, object)
	if object and EP.isNetworkClient() then
		if not object:hasModData() then return false end
		return object:getModData()[EP.KEY_FED_ON] == true
	end

	if not square or not square.hasModData or not square:hasModData() then return false end
	return square:getModData()[EP.KEY_FED] == true
end

--- Which liquid a listed fixture standing here draws.  Absent means water, so a square that
--- has only ever carried water gains no key at all - the same rule KEY_FLUID follows on a
--- fixture, and for the same reason.  Same two sides as above.
function EP.fedFluidType(square, object)
	if object and EP.isNetworkClient() then
		if not object:hasModData() then return EP.FLUID_DEFAULT end
		return EP.canonicalFluidType(object:getModData()[EP.KEY_FED_FLUID]) or EP.FLUID_DEFAULT
	end

	if not square or not square.hasModData or not square:hasModData() then return EP.FLUID_DEFAULT end
	return EP.canonicalFluidType(square:getModData()[EP.KEY_FED_FLUID]) or EP.FLUID_DEFAULT
end

--- Record the decision, on the authority.
---
--- Cleared to nil rather than written false when a fixture is disconnected, and the liquid
--- goes with it: a square nobody has plumbed anything on should read exactly like every
--- other square in the world, so an uninstall or a rollback leaves nothing behind.  That is
--- the opposite of KEY_INCLUDE's tri-state, and deliberately - a barrel needs to remember
--- that somebody said NO, because the alternative was a sandbox default that would have
--- re-adopted it.  There is no such default here.
function EP.setFedPlumbed(square, plumbed, liquid)
	if not square then return end
	local data = square:getModData()
	if not data then return end

	if not plumbed then
		data[EP.KEY_FED] = nil
		data[EP.KEY_FED_FLUID] = nil
		-- [Malcolm_Perf] no longer a registered spot
		if EP.reg and EP.reg.ready() then EP.reg.remove(square:getX(), square:getY(), square:getZ(), EP.reg.BIT_FED) end
		return
	end

	data[EP.KEY_FED] = true
	-- [Malcolm_Perf] a topped-up fixture is a registered spot
	if EP.reg and EP.reg.ready() then EP.reg.add(square:getX(), square:getY(), square:getZ(), EP.reg.BIT_FED) end
	if liquid ~= nil then
		data[EP.KEY_FED_FLUID] = (liquid ~= EP.FLUID_DEFAULT) and liquid or nil
	end
end

--- Put the object's copy in step with its square, and tell the clients if it moved.
---
--- The whole of the sync, in one place, so the moment-of-decision path and the maintenance
--- pass cannot drift apart about what a client is told.
---
--- TRANSMITS ONLY ON A CHANGE, which matters because this is called once per listed fixture
--- per lap: an object already carrying the right stamp costs two table reads and no packet.
--- The settled state of every dispenser in an office block is therefore free.
---
--- Returns true when something was actually sent, for the log.
function EP.stampFed(object, square)
	if not EP.isAuthority() then return false end
	if not object or not object.getModData then return false end

	local plumbed = EP.isFedPlumbed(square) or nil
	local liquid = plumbed and EP.fedFluidType(square) or nil
	if liquid == EP.FLUID_DEFAULT then liquid = nil end

	local data = object:getModData()
	if data[EP.KEY_FED_ON] == plumbed and data[EP.KEY_FED_FLUID] == liquid then return false end

	data[EP.KEY_FED_ON] = plumbed
	data[EP.KEY_FED_FLUID] = liquid
	object:transmitModData()
	return true
end

--- The delimiter between ids.  A ";" cannot appear in a script name - they are parsed as
--- identifiers out of the script files - so no id can be split in half by one.
EP.FED_SEP = ";"

--- The parsed list, and the raw string it was parsed from.
---
--- Memoised on the STRING rather than on a flag, so an admin editing the sandbox value
--- mid-session is picked up on the next call without anything having to notice: the
--- comparison that decides whether to re-parse is the same read that fetches the value.
--- `fedEmpty` is kept beside it so the disabled case is one boolean and not a pairs walk.
local fedRaw, fedSet, fedEmpty = nil, {}, true

--- Whitespace at either end of an id, removed without a pattern.
---
--- string.gsub with "^%s*(.-)%s*$" is the ordinary way and it is not used here for the
--- same reason `next` is not used anywhere in this mod: this VM is Kahlua, its string
--- library is its own, and a pattern feature that is quietly absent shows up as a silent
--- wrong answer rather than an error.  Two string.sub calls cannot be absent.
---
--- Only spaces and tabs.  An operator separating ids with "; " is the case this exists
--- for; a newline inside a sandbox string is not a thing the ini format produces.
local function trim(s)
	local from = 1
	local to = #s
	while from <= to do
		local c = string.sub(s, from, from)
		if c ~= " " and c ~= "\t" then break end
		from = from + 1
	end
	while to >= from do
		local c = string.sub(s, to, to)
		if c ~= " " and c ~= "\t" then break end
		to = to - 1
	end
	return string.sub(s, from, to)
end

--- The ids an operator has listed, as a set.  Returns the set and whether it is empty.
function EP.fedIds()
	local raw = EP.getOption("FedFixtures")
	if type(raw) ~= "string" then raw = "" end
	if raw == fedRaw then return fedSet, fedEmpty end

	local set = {}
	local empty = true
	local at = 1
	while true do
		local sep = string.find(raw, EP.FED_SEP, at, true)
		local piece = trim(sep and string.sub(raw, at, sep - 1) or string.sub(raw, at))
		if piece ~= "" then
			set[piece] = true
			empty = false
		end
		if not sep then break end
		at = sep + 1
	end

	fedRaw, fedSet, fedEmpty = raw, set, empty
	return set, empty
end

--- What GameEntity.getEntityFullTypeDebug answers for an object with no Script component.
--- Matched rather than parsed: it is a literal in the Java (:134) and a list entry can
--- never equal it, so this is only here to save the split below.
local ANONYMOUS = "<anonymous>"

--- Is this one of the objects an operator has said the supply should FILL?
---
--- ONE JAVA CALL FOR THE OVERWHELMING MAJORITY, and that matters because notice() asks
--- this about every object of every square as a chunk streams in.  getEntityFullTypeDebug
--- is a hasComponent and a field read, it answers "<anonymous>" for anything that is not a
--- scripted entity - which is nearly everything on a square - and the string compare that
--- rejects it is Lua.  The container check below is reached only by an object whose id is
--- actually on the list.
---
--- getEntityFullTypeDebug and NOT getEntityScript():getFullName(), and the difference is
--- not style.  getFullName() goes through getScriptObjectFullType, which THROWS a
--- RuntimeException when the module or the name is missing (BaseScriptObject.java:117-131),
--- and this is called from inside LoadGridsquare - thousands of times as the world opens.
--- getEntityFullTypeDebug reads the string EntityScriptInfo already saved and cannot throw.
---
--- PROBED ONCE RATHER THAN pcall'ed PER OBJECT.  If a build does not expose the method the
--- feature is off and says so, which is a state somebody can see in the log; a pcall here
--- would be a cost on the streaming path paid for ever to hide it.  (Inherited GameEntity
--- methods ARE exposed on IsoObject in a shipping build - vanilla's own ISOpenCloseLid
--- calls barrel:getEntityScript():getName() - so this is a guard against a stub or a
--- future removal, not against today.)
local fedProbed, fedUsable = false, false

function EP.isFedFixture(object)
	if not object then return false end
	-- [Malcolm_Perf] The last test below, asked first: without a FluidContainer the answer is
	-- no whatever the name says, and asking it first spares every ordinary object the type
	-- string and its parsing.  Same answer for every object.
	if object.getFluidContainer and object:getFluidContainer() == nil then return false end

	local set, empty = EP.fedIds()
	if empty then return false end

	if not fedProbed then
		fedProbed = true
		fedUsable = object.getEntityFullTypeDebug ~= nil
		if not fedUsable then
			EP.log("this build does not expose getEntityFullTypeDebug;"
				.. " the topped-up fixture list can do nothing and is ignored")
		end
	end
	if not fedUsable then return false end

	local full = object:getEntityFullTypeDebug()
	if type(full) ~= "string" or full == ANONYMOUS then return false end

	if not set[full] then
		-- The unqualified half.  Only reached when the full type missed, so a list of
		-- dotted ids costs nothing here and a list of bare ones costs one find and one sub.
		local dot = nil
		local at = 1
		while true do
			local found = string.find(full, ".", at, true)
			if not found then break end
			dot = found
			at = found + 1
		end
		if not dot then return false end
		if not set[string.sub(full, dot + 1)] then return false end
	end

	-- IT HAS TO BE ABLE TO HOLD SOMETHING, and this is the last test rather than the first
	-- because it is the only Java call in here that an ordinary object would have paid.
	--
	-- The case it excludes is real and is one object away from the one this is for:
	-- WaterDispenserNoBottle is the same cooler with the bottle taken off and it has NO
	-- FluidContainer component at all, so it is a piece of furniture.  An operator who
	-- listed it would otherwise get a fixture the top-up walks a building for and can
	-- never fill.
	return object:getFluidContainer() ~= nil
end

--- IsoObject.FindWaterSourceOnSquare, transcribed.  Anything the engine would
--- accept as a collector, this accepts: every vanilla rain barrel and collector,
--- and any modded one, without a list to keep up to date.
---
--- The extra tests are exclusions the engine gets for free and this does not.
--- waterPiped keeps a fixture from being read as somebody else's supply, the
--- ghost test keeps a ghost from being mirrored into another ghost - the engine
--- never has that problem because vanilla makes neither - and the fuel test is
--- the note above.
--- THE CHEAPEST REJECTION FIRST, AND IT IS THE ONE THAT REJECTS ALMOST EVERYTHING.
---
--- `instanceof` was third, behind `EP.isGhost` (a `getSpriteName()` - a Java call that
--- allocates a string - plus a `hasModData()`) and `isFuelHolder` (another `hasModData()`).
--- So every fencepost, wall, tree and floor tile this was asked about paid three engine
--- crossings before the one test that could tell it apart.
---
--- A COLLECTOR IS ALWAYS AN IsoThumpable and nothing on the map ever is: CellLoader builds
--- an IsoObject, an IsoWindow, an IsoDoor or a fireplace and never a thumpable
--- (`CellLoader.java:126-336`), so this is a single call that says no to virtually every
--- object in the world.  A ghost and a fuel barrel are both thumpables, so both still reach
--- their own test one line later and no answer changes - only the order they are refused
--- in.
---
--- It matters because of where this is asked from: `EP.sourceOnSquare` asks it about EVERY
--- object on EVERY square of `EP.collectorsInScope`'s box, which is 5,625 squares at the
--- default Reach and 149,769 at the highest a player can set.  Measured in
--- `tools/luatest/lgep_probe_scopecost.lua`.
function EP.isWaterSource(object)
	if not object then return false end
	if not instanceof(object, "IsoThumpable") then return false end
	if EP.isGhost(object) then return false end
	if isFuelHolder(object) then return false end

	local sprite = object:getSprite()
	if sprite then
		local props = sprite:getProperties()
		if props:has(IsoFlagType.solidfloor) then return false end
		if props:has(IsoFlagType.waterPiped) then return false end
	end

	if object:getUsesExternalWaterSource() then return false end
	if object:getFluidCapacity() <= 0 then return false end

	-- LAST, AND THAT IS WHERE THE COST ARGUMENT PUTS IT.  Everything above is the engine's
	-- own four questions, so by here the object really is something the game would treat as
	-- a collector - a handful of objects in a building rather than every object on a
	-- square. The list is asked only about those.
	--
	-- Being on the list is a complete answer, not a preference: a dispenser must not be
	-- both a donor and a receiver, or the top-up would fill it out of itself and every
	-- litre in the building would read twice.  This one site is what notice(), the group
	-- walk, EP.sourceAt, EP.setIncluded and the collector menu all pass through, so a
	-- listed object is ABSENT from the supply rather than merely un-offered - the same
	-- reasoning, and the same seam, as the fuel-holder test above.
	--
	-- A flag an operator has already set is left alone.  Take an id off the list and the
	-- object is a collector again, still carrying whatever KEY_INCLUDE it had before -
	-- which is the reversible direction, and the reason nothing here writes to it.
	return not EP.isFedFixture(object)
end

--- Is this collector plumbed into the building's supply?
---
--- THE NAME IS `isIncluded` AND THE PLAYER'S WORD IS "PLUMBED IN", and they are the same
--- flag.  The name is kept rather than churned because it is the save key's own name
--- (KEY_INCLUDE), it is what six call sites and two dozen suites already say, and a second
--- name for one fact is precisely the drift EP.eligible's note exists to complain about.
--- Read "included in the building's plumbing" and the two are one sentence.
---
--- The barrel's own flag and nothing else.  It used to fall back to a sandbox option when
--- the flag was unset; that option is gone and the note on DEFAULTS says why at length.
--- nil now means what it reads as: nobody has plumbed this barrel in.
---
--- Still effectively tri-state in the SAVE, and EP.adoptLegacyPlumbing depends on that -
--- it promotes only an unset flag, so an explicit false (a barrel somebody disconnected)
--- is never quietly re-adopted.
---
--- Note what this does NOT do: an unplumbed barrel is still a rain barrel, still
--- collects rain, and vanilla will still plumb a fixture to it if it happens to be
--- in the nine squares above one.  That branch is engine code and not ours to
--- veto.  This only decides membership of the building-wide pool.
function EP.isIncluded(object)
	if not object or not object:hasModData() then return false end
	return object:getModData()[EP.KEY_INCLUDE] == true
end

--- Can this collector push water uphill?
---
--- A generator reaching the collector's square is a pump.  Unpowered, a collector
--- is gravity fed and only ever serves what is below it.
---
--- Grid power is deliberately NOT accepted, and that is a correction rather than
--- an omission.  IsoGridSquare.hasGridPower() is
--- `!isNoPower() && SandboxOptions.doesPowerGridExist()` - map-wide, not a
--- question about this square at all - so before the shutoff it is true
--- everywhere.  Counting it made every collector permanently pumped, which killed
--- the gravity rule outright and made the generator do nothing.
---
--- Nothing is lost by dropping it.  While the grid is up, fixtures draw infinite
--- mains water anyway (IsoObject.isWaterInfinite), so what a barrel could pump is
--- moot; once it goes down, hasGridPower() is false everywhere in any case.
---
--- haveElectricity() is the real test, and it is genuinely per square:
--- IsoChunk.isGeneratorPoweringSquare walks the generator positions registered on
--- THAT square's chunk.  It also honours the allowExteriorGenerator sandbox rule
--- on its own, so an outdoor barrel obeys the server's setting for free.
--- Is there a generator reaching this collector's square?
---
--- THE POWER QUESTION ON ITS OWN, with no opinion about whether the barrel is in the
--- network.  Split out of EP.isPumped below so that the legacy adoption pass can ask
--- "could this barrel have supplied the fixture, before plumbing became an act" without
--- re-deriving the electricity rule - and so that when it asks, it is asking THIS
--- function rather than a second copy of it that could drift.
---
--- Nothing else may call this in place of EP.isPumped.  The welding of pump to
--- membership is deliberate and is documented on that function; this is the half below
--- the weld, and using it as the eligibility test would resurrect exactly the bug that
--- note describes.
function EP.hasPump(object)
	if not object then return false end
	local square = object:getSquare()
	if not square then return false end
	return square:haveElectricity()
end

function EP.isPumped(object)
	if not object then return false end
	-- A collector nobody has opted into the network has no pump either.  Keeping
	-- the two answers welded together means there is one truth about whether a
	-- barrel is part of this system, rather than a barrel that is excluded from
	-- the plumbing but still counted as pumping for it.
	if not EP.isIncluded(object) then return false end

	return EP.hasPump(object)
end

--- Can this collector supply a fixture at height fz?
---
--- Strictly above, or pumped.  The strictness is vanilla's and not a choice:
--- FindExternalWaterSource looks at z+1 and its eight neighbours, so a collector
--- on the same floor as a sink is not a supply in vanilla either.
function EP.canSupply(object, sourceZ, fz)
	if sourceZ > fz then return true end
	return EP.isPumped(object)
end

--- Is this collector part of the supply a fixture at fz draws on?
---
--- The whole membership test, in one place, because there are now three callers
--- that must not drift apart: the server building a group, the client building
--- the same group for its stand-in, and the sweep asking whether a mirror still
--- has any business being fed.  Every one of them used to ask some of this and
--- not the rest - settleOrRemove re-checked height and forgot inclusion, so a
--- barrel excluded by hand went on filling mirrors above it for the rest of the
--- session.  One predicate, or it happens again.
function EP.eligible(object, sourceZ, fz)
	if not object then return false end
	if not EP.isIncluded(object) then return false end
	return EP.canSupply(object, sourceZ, fz)
end

--------------------------------------------------------------------------------
-- which building a square is part of
--------------------------------------------------------------------------------

--- A B42 basement is a building of its own, and the engine refuses to join it to
--- the house it is under.
---
--- Basements.createBasementBuildingDefs makes one BuildingDef per placement out of
--- the basement lot's own rooms, offset to where the placement put them and shifted
--- down to basementPlacement.z.  It is then offered to getBuildingToMergeWith,
--- which opens with
---
---     if (buildingDef.getMinLevel() < 0) { return mergeDef; }   // mergeDef == null
---
--- so a def whose rooms are all below ground never merges with anything.  Only the
--- *access* structures - the stairwell shed standing at ground level - take the
--- merge path; the basement proper is appended to metaGrid.buildings as a separate
--- building sharing the house's plan.
---
--- Everything downstream of "which building is this in" therefore saw a basement
--- sink and the barrel on the roof above it as two different buildings.  They went
--- into different pools, so the basement never had a main supply and its fixtures
--- were not in the list a barrel's placement walks; and the box a basement fixture
--- swept for collectors was built from the basement's own def, whose getMaxLevel()
--- is -1, so it stopped two floors below the roof the barrels were standing on.
---
--- This section is the one place that answers the question, so the two sides and
--- every caller answer it the same way.

--- Two defs being the same one.
---
--- By the string and not by getID().  BuildingID.makeID packs
--- `(cellX | cellY << 16) << 32 | index`, which for Knox County cell coordinates
--- lands around 9.9e15 - past 2^53, where a Lua number stops being able to hold
--- every integer.  The low bits it would drop are the building index, so two
--- neighbours in the same cell could compare equal.  getIDString does
--- String.valueOf on the true long inside Java, so the comparison is exact.
---
--- Kahlua identity would work too - vanilla compares two IsoBuildings from
--- separate calls with ~= in ISWorldObjectContextMenu - but the id is what the rest
--- of the mod keys its pools by, so asking the same question two ways is one way
--- too many.
function EP.sameDef(a, b)
	return a ~= nil and b ~= nil and a:getIDString() == b:getIDString()
end

--- Is this def entirely below ground?
---
--- getMaxLevel() is the highest ROOM in the def, so a basement answers -1 and a
--- house with a basement in it answers its top floor.  The empty test comes first
--- because getMaxLevel() returns its -100 sentinel when there are no rooms to
--- derive it from, and an emptyoutside-only def - a car park, a courtyard - would
--- otherwise read as a basement.
function EP.isBasementDef(def)
	if not def then return false end
	if def:getRooms():isEmpty() then return false end
	return def:getMaxLevel() < 0
end

--- basement id string -> the def above it, or false for "looked, found nothing".
--- Cleared when the metagrid is rebuilt, below.
local parentOf = {}

--- canonical id string -> the plan and levels of that building with its basements.
local boundsOf = {}

--- How far up to look for the building over a basement, when nothing overlaps it
--- in plan.  A basement is one storey down and its access shed is at ground level;
--- three covers a house on a slope without wandering into the next street.
local PARENT_LEVELS = 3

--- How much plan two defs share, in tiles.
local function planOverlap(a, b)
	local w = math.min(a:getX2(), b:getX2()) - math.max(a:getX(), b:getX())
	local h = math.min(a:getY2(), b:getY2()) - math.max(a:getY(), b:getY())
	if w <= 0 or h <= 0 then return 0 end
	return w * h
end

--- The above-ground building a basement belongs to, or nil for one that stands on
--- its own - a bunker, a storm drain, a mapper's stand-alone cellar.
---
--- getBuildingsIntersecting rather than a scan of metaGrid.buildings, and the box
--- is grown by a tile exactly the way Basements.getBuildingToMergeWith grows it, so
--- a basement whose wall lines up with the house's wall still finds it.  It is
--- indexed by chunk and deduplicated by the engine, which getBuildingAtRelax - a
--- linear walk of every building on the map returning whichever it met first - is
--- not.
local function findParent(def)
	local grid = getWorld():getMetaGrid()

	local list = ArrayList.new()
	grid:getBuildingsIntersecting(def:getX() - 1, def:getY() - 1, def:getW() + 2, def:getH() + 2, list)

	local best, bestOverlap = nil, -1
	for i = 0, list:size() - 1 do
		local candidate = list:get(i)
		if not EP.sameDef(candidate, def) and not EP.isBasementDef(candidate)
			and not candidate:getRooms():isEmpty() then
			local overlap = planOverlap(def, candidate)
			-- Most shared plan wins; the id string breaks a genuine tie, so a
			-- basement under the seam between two terraced houses picks the same one
			-- on every restart instead of following list order.
			if overlap > bestOverlap
				or (best and overlap == bestOverlap and candidate:getIDString() < best:getIDString()) then
				best, bestOverlap = candidate, overlap
			end
		end
	end
	if best then return best end

	-- Nothing adjacent in plan at all.  Look straight up instead: a basement
	-- reached by a corridor can sit clear of the footprint of the house it belongs
	-- to, and the room standing over its own middle answers that.
	local cx = math.floor((def:getX() + def:getX2()) / 2)
	local cy = math.floor((def:getY() + def:getY2()) / 2)
	for z = 0, PARENT_LEVELS do
		local candidate = grid:getBuildingAt(cx, cy, z)
		if candidate and not EP.isBasementDef(candidate) and not candidate:getRooms():isEmpty() then
			return candidate
		end
	end

	return nil
end

--- The building a def belongs to: itself, unless it is a basement, in which case
--- the building standing over it.
---
--- A player-built structure is returned untouched.  Its def is synthesised by
--- IsoRegions.clientProcessBuildings and can be rebuilt at any moment, so it is
--- neither worth caching nor safe to.
function EP.canonicalDef(def)
	if not def then return nil end
	if not EP.isBasementDef(def) then return def end
	if def:isUserDefined() then return def end

	local key = def:getIDString()
	local cached = parentOf[key]
	if cached ~= nil then
		if cached == false then return def end
		return cached
	end

	local parent = findParent(def)
	parentOf[key] = parent or false
	if parent then
		EP.log(("the basement %s belongs to the building %s"):format(key, parent:getIDString()))
	end
	return parent or def
end

--- Step 2 of buildingAt, without the linear scan it used to be.
---
--- IsoMetaGrid.getBuildingAtRelax walks the metagrid's ENTIRE building list, in order,
--- until a footprint grown by one contains the point.  That list is not the loaded
--- region: it is filled at world load from every lot header of every map file, so it is a
--- whole-map constant in the thousands from the first frame, everywhere, in every mode.
---
--- Every OUTDOOR object this mod files pays it - which is every barrel on a roof, and a
--- roof is where players put them.  Measured, streaming one chunk with three objects on
--- it, against a map carrying 15,000 buildings: 45,210 operations, of which 45,003 were
--- building entries walked.  Three lookups.  The per-square work everybody looks at -
--- getObjects, the string key - was 192 of it.  On a dedicated server that lands 64
--- chunks at a time in one frame, because a cell is loaded in one burst.
---
--- So the list is bucketed once and asked by bucket thereafter: 45,210 becomes 384, and
--- stops growing with the map at all.
---
--- MAP BUILDINGS ONLY, and a MISS FALLS THROUGH to the engine.  Both halves are needed
--- and together they are what makes this correct rather than merely fast:
---
---   * a map building's plan is immutable for the life of the world, so an index of them
---     can never go stale;
---   * a user-defined def is the opposite - IsoRegions.update -> clientProcessBuildings
---     destroys and rebuilds every one in a cell and its eight neighbours whenever a wall,
---     floor or door is laid, with a fresh id each time.  That is the same reason poolOf
---     refuses to pool them.
---
--- Indexing those too was tried and it went stale immediately: a player structure put up
--- after the index existed read as nothing at all.  Leaving them out means a bucket miss
--- is not "no building", it is "no MAP building" - which is exactly when a user-defined
--- def might be the answer, so the engine is asked.  Everything indexed is immutable and
--- everything mutable is asked fresh, so there is nothing to invalidate and no
--- construction event to hook.  There is no reliable authority-side one in all three
--- modes anyway.
---
--- Order is preserved within a bucket because the engine returns the FIRST match in load
--- order and buckets are filled in that order; two overlapping map buildings would
--- otherwise swap places.  One divergence remains and is accepted: the engine's first
--- match is taken across map and user-defined defs INTERLEAVED, so where both match this
--- answers the map building.  For this mod that is the better answer - poolOf discards
--- user-defined defs and scope wants the house - but it is a difference.
---
--- Empty on a procedurally generated world, where getBuildings() has nothing in it.  That
--- is correct: getBuildingAtRelax answers nothing there either.
---
--- 32 TILES A SIDE, AND THE FIGURE IS MEASURED RATHER THAN ARGUED.  Q8, closed 2026-08-16.
---
--- It was 64, chosen by the argument that it is "small enough that a bucket holds a handful
--- in a town, large enough that a big building lands in few buckets".  Both halves of that
--- are checkable and neither had been checked - and the first half turned out to be wrong.
---
--- The reason it went unnoticed for so long is the reason it needed a probe of its own: a
--- bucket hit walks the bucket comparing four integers per entry, which is PURE LUA.  It
--- crosses into no Java, so it appears in no operation counter in this harness - the same
--- blindness that hid the empty-world cursor at 2.7 laps a tick.  The index was built to
--- turn an O(B) engine walk into a short Lua one, and nobody had ever read how short.
---
--- `tools/luatest/lgep_probe_relaxgrid.lua`, 400 map buildings on a street grid with one in
--- eight a warehouse-sized block:
---
---     grid   entries visited per lookup   buckets per building   worst bucket
---       16                          1.7                    4.2             10
---       32                          3.2                    2.2             21
---       64                          9.7                    1.6             51
---      128                         31.1                    1.3            153
---
--- 32 walks a third of what 64 did for 38% more index, and the index is trivial either way
--- - 72 buckets against 25, for four hundred buildings.  16 is better again on the lookup
--- and was not taken: it doubles the placements once more for a saving of 1.5 entries, and
--- the build is a pass over every lot header of the whole map at load.
---
--- NOTHING ABOUT CORRECTNESS DEPENDS ON THIS NUMBER.  The bucket is a filter, not an
--- answer: relaxAt applies the same containment test to whatever the bucket holds, and
--- within-bucket order is still load order, which is what preserves the engine's
--- first-match semantics.  A wrong value here would be slow, never wrong.
---
--- No frame in `lgep_hitch.sh` moves, and that is expected rather than disappointing - the
--- cost is invisible to those counters by construction.  What the change buys is on the
--- path that resolves a building per barrel, which is walked once per collector on every
--- group walk.
local RELAX_GRID = 32
local relaxIndex = nil

local function buildRelaxIndex()
	relaxIndex = {}
	local all = getWorld():getMetaGrid():getBuildings()
	if not all then return end

	for i = 0, all:size() - 1 do
		local d = all:get(i)
		if not d:isUserDefined() then
			-- The plan grown by one, which is getBuildingAtRelax's own test.  The index
			-- must not be tighter than the thing it stands in for.
			local x1, y1 = d:getX() - 1, d:getY() - 1
			local x2, y2 = d:getX2() + 1, d:getY2() + 1
			for gx = math.floor(x1 / RELAX_GRID), math.floor(x2 / RELAX_GRID) do
				for gy = math.floor(y1 / RELAX_GRID), math.floor(y2 / RELAX_GRID) do
					local k = gx .. ":" .. gy
					local bucket = relaxIndex[k]
					if not bucket then bucket = {}; relaxIndex[k] = bucket end
					bucket[#bucket + 1] = d
				end
			end
		end
	end
end

--- MEASURED 2026-08-16, AND THE INDEX ABOVE IS DOING ITS JOB: the fallthrough below is
--- reached SEVEN times across the whole of `lgep_hitch.sh` - all six scenes, including the
--- one carrying 15,001 building defs.  It is not a hot path and it is not worth a memo.
---
--- Recorded because it looked like one.  A maintenance tick in the `decoy=15000` scene
--- peaks at 15,155 operations with `buildingsWalked 15001`, which reads exactly like this
--- function missing its bucket and walking the map.  It is not: that frame carries
--- `intersectScans 1` and no `buildingScans` at all, so the walk is
--- `getBuildingsIntersecting` inside `EP.buildingBounds` - Q10, once per building def per
--- session, and largely a harness artefact because the real
--- `IsoMetaGrid.getBuildingsIntersecting` (IsoMetaGrid.java:416) iterates only the
--- metacells the box touches where the stub walks the whole list.
---
--- The lesson is about the LEDGER rather than the code: `buildingsWalked` is incremented by
--- four different stub primitives, so it says how much linear walking happened and not
--- which call did it.  `buildingScans` is the one that names this function, and reading it
--- is what turned a plausible finding into a closed question.
---
--- A miss memo and a `isServer()` skip were both built here and both removed again.  The
--- skip is provable - GameServer.server means clientProcessBuildings never ran, so there
--- are no user-defined defs and a bucket miss can only be answered nil - and it is written
--- down here so it is ready if a production profile ever disagrees with the bench.  It was
--- not kept, because an invalidation rule on a path where a stale answer silently shortens
--- a water total is not something to carry for a cost measured at seven calls.
--- The bucket index alone: the MAP building whose plan grown by one holds (x, y), or nil.
local function relaxIndexAt(x, y)
	if not relaxIndex then buildRelaxIndex() end

	local bucket = relaxIndex[math.floor(x / RELAX_GRID) .. ":" .. math.floor(y / RELAX_GRID)]
	if bucket then
		for i = 1, #bucket do
			local d = bucket[i]
			-- ONE TILE LOOSER THAN THE ENGINE, EAST AND SOUTH, AND LEFT THAT WAY ON PURPOSE.
			--
			-- `IsoMetaGrid.getBuildingAtRelax` (`IsoMetaGrid.java:338-346`) solves to
			-- `x - 1 <= x <= x2`, and `BuildingDef.x2` is EXCLUSIVE (`:246-249`,
			-- `x2 = rect.x + rect.w`). So against the real engine this `+ 1` accepts two
			-- tiles past the last real one on the east and south, where the engine accepts
			-- one - and `servesBuilding`, which goes through the engine test, then refuses
			-- what `EP.canPlumbHere` offered.
			--
			-- IT IS NOT A ONE-LINE FIX, and tightening it alone makes things worse. The
			-- harness models `x2` as INCLUSIVE - `WORLD.addBuilding("A", 10, 10, 19, 19)`
			-- gives `getX2() = 19` where the engine would give 20 - so under the stub this
			-- `+ 1` is exactly the engine's rule, and every suite in the tree is written
			-- against that convention. Tightened here, `lgep_spec_pipes` loses ten
			-- assertions: a pipe run laid to touch a house's grown plan no longer touches it.
			--
			-- So the real defect is the STUB's `x2`, the fix is to make it exclusive like the
			-- engine's, and the fallout has to be walked through every suite that builds a
			-- building. That is its own change with its own gate run, not one slipped in
			-- beside a release. Recorded in BR-LGEP-065.
			if x >= d:getX() - 1 and x <= d:getX2() + 1
				and y >= d:getY() - 1 and y <= d:getY2() + 1 then return d end
		end
	end
	return nil
end

local function relaxAt(x, y)
	local d = relaxIndexAt(x, y)
	if d then return d end

	-- No MAP building here, so a player-built one may be the answer and only the engine
	-- knows.  See the note above.
	return getWorld():getMetaGrid():getBuildingAtRelax(x, y)
end

--- The building a square belongs to, basements resolved to the house above them.
---
--- Three sources in order, because the interesting squares are not all in a room:
---
---   1. the square's own room, for anything indoors - including a basement
---   2. the plan, for a roof, a balcony, or a barrel shoved against a wall
---   3. nothing, for open ground, which is the caller's cue to fall back to Reach
function EP.buildingAt(x, y, z)
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	local building = square and square:getBuilding()
	local def = building and building:getDef() or nil
	if not def then
		def = relaxAt(x, y)
	end
	return EP.canonicalDef(def)
end

--- EP.buildingAt for MAP buildings only, and never the engine's linear walk.
---
--- THE PIPE NETWORK'S BUILDING QUESTION, and the reason it is not EP.buildingAt is a number.
--- A pipe is laid in open ground - that is what it is for - and every tile of open ground
--- MISSES the bucket index, and a miss falls through to getBuildingAtRelax, which walks the
--- whole map's building list.  Measured (tools/luatest/lgep_measure_pipes.lua): one
--- derivation of a 218-piece run walked 14,560 building entries against a map of 42; a Knox
--- County map is tens of thousands, so one derivation would be millions.  And the same
--- fallthrough sat on the hot paths - every open-ground barrel's network test in a group
--- walk, in the supply summary and in the drink fan-out.
---
--- The fallthrough exists to find a player-built def, and the pipe network never uses one:
--- a user-defined def's id is rebuilt with every wall, so a player structure joins a
--- network through the region graph instead (see LGEPPipes' areaAt).  So dropping it here
--- changes no answer the network could use, and a room's own def is skipped for the same
--- reason - which is also what a dedicated server answers, having no user-defined defs at all.
function EP.mapBuildingAt(x, y, z)
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	local building = square and square:getBuilding()
	local def = building and building:getDef() or nil
	if def and def.isUserDefined and def:isUserDefined() then def = nil end
	if not def then def = relaxIndexAt(x, y) end
	return EP.canonicalDef(def)
end

--- Is this a place a building's plumbing could ever reach a collector?
---
--- THE GATE ON THE PLUMB OPTION, and the whole reason it exists is that an option which
--- is offered and then does nothing is worse than one that is absent.  A barrel standing
--- in a field is not going to join anything, whatever a player clicks; saying so by not
--- offering the row is the only honest answer, because there is no error to show them.
---
--- Three places, which is the same three the supply rules already accept:
---
---   inside the building        the square's own room, servesBuilding step 1
---   against the outside wall   the plan grown by a tile, servesBuilding step 3
---   on the roof               the plan again - a roof square stands over the footprint
---
--- All three fall out of EP.buildingAt, which asks the room first and the plan second, so
--- this is deliberately NOT a fourth transcription of the rule.  It is the same function
--- the scope walk uses, asked from the barrel instead of from the fixture, which is what
--- makes the menu and the supply agree by construction rather than by two people
--- remembering to change both.
---
--- The column walk servesBuilding does at step 2 is not repeated here on purpose.  It
--- exists to decide WHOSE roof a barrel is on, so a terrace does not pool - and this
--- question has no whose in it.  Any building at all is a yes, and a barrel over next
--- door's roof is over a building either way.
---
--- A USER-DEFINED DEF IS REFUSED ON A NETWORK CLIENT, for the reason set out at length in
--- EP.collectorsInScope: IsoRegions.update calls clientProcessBuildings inside
--- `if (!GameServer.server)`, so the def synthesised for a player-built structure exists
--- in singleplayer and on every client and NEVER on a server.  Left in, a client would
--- offer Plumb on a barrel the server is about to refuse, which is the dead option this
--- function exists to prevent - just with an extra round trip in front of it.
---
--- THE REGION FALLBACK NOW TAKES THE SAME THREE PLACES, through EP.regionsAt, and that is
--- what closed the gap this note used to record as a limit.  It said a player base on a
--- dedicated server offered Plumb indoors only, because the group walk admitted a candidate
--- only when its OWN square was in the region - so a barrel on a roof or against a wall was
--- outdoors, in no region, and refused.  The walk now asks EP.regionsAt from both ends and
--- this asks it from the barrel, so the two still agree by construction and all three
--- places answer in every mode.  See plans/player-built-structures.md.
---
--- THE DEF TEST IS STILL FIRST AND IS NOT REDUNDANT.  A map basement is below ground, where
--- getIsoWorldRegion() returns null outright, so the region test can never answer for one.
--- Neither is a superset of the other, which is why both are asked.
---
--- WHAT IT COSTS, measured rather than reasoned about: nothing at all for a barrel that
--- gets an option, because the bucket index inside EP.buildingAt answers roof, wall and
--- indoors without touching the engine's building list; and nothing for a barrel already
--- plumbed, which is never asked.  A barrel standing clear of any building misses the
--- index and walks the whole list, on every click - the one case that pays, and the one
--- case that produces no menu row.  See plans/lgep-plumb-gate-cost.md for the table and
--- for why the miss is not memoised (the fallthrough is what finds a player-built shack
--- in singleplayer, and a negative memo could not be invalidated safely).
--- Re-derive it with tools/luatest/lgep_measure_plumbgate.sh.
function EP.canPlumbHere(x, y, z)
	-- A FLOOR PIPE ON THE TILE IS A YES, blue or white.  Plumbing the barrel in is what turns
	-- a white network blue, so refusing on white would make the first barrel impossible.
	-- Asked first because it is one table read, and EP.pipeAt reads the saved rows on the
	-- authority and the broadcast copy on a client, so both sides answer the same.  See
	-- plans/lgep-pipe-network.md section 2.
	if EP.pipeAt and EP.pipeAt(x, y, z) then return true end

	local def = EP.buildingAt(x, y, z)
	if def and not (EP.isNetworkClient() and def.isUserDefined and def:isUserDefined()) then
		return true
	end

	return EP.regionsAt(x, y, z) ~= nil
end

--- The plan and the levels a building occupies, its basements included.
---
--- BuildingDef bounds are x and y only - CalculateBounds tracks nothing else - and
--- getMaxLevel/getMinLevel are the top and bottom ROOM.  So a box built from the
--- house alone starts at its ground floor and never reaches the cellar, and a box
--- built from the basement alone stops at -1 and never reaches the roof.  Every
--- search this mod runs wants the union, and works it out once per building.
function EP.buildingBounds(def)
	def = EP.canonicalDef(def)
	if not def then return nil end

	local key = def:getIDString()
	local cached = boundsOf[key]
	if cached then return cached end

	local empty = def:getRooms():isEmpty()
	local bounds = {
		minX = def:getX(), minY = def:getY(),
		maxX = def:getX2(), maxY = def:getY2(),
		minZ = empty and 0 or def:getMinLevel(),
		maxZ = empty and 0 or def:getMaxLevel(),
	}

	-- A player-built structure has no basement to find and a def that may not exist
	-- a moment from now, so it is measured and not remembered.
	if def:isUserDefined() then return bounds end

	local list = ArrayList.new()
	getWorld():getMetaGrid():getBuildingsIntersecting(
		def:getX() - 1, def:getY() - 1, def:getW() + 2, def:getH() + 2, list)

	for i = 0, list:size() - 1 do
		local other = list:get(i)
		if EP.isBasementDef(other) and EP.sameDef(EP.canonicalDef(other), def) then
			if other:getX() < bounds.minX then bounds.minX = other:getX() end
			if other:getY() < bounds.minY then bounds.minY = other:getY() end
			if other:getX2() > bounds.maxX then bounds.maxX = other:getX2() end
			if other:getY2() > bounds.maxY then bounds.maxY = other:getY2() end
			if other:getMinLevel() < bounds.minZ then bounds.minZ = other:getMinLevel() end
		end
	end

	boundsOf[key] = bounds
	return bounds
end

--- Forget everything worked out about the map's shape.
---
--- OnLoadedMapZones is raised straight after IsoWorld builds the metagrid and
--- Basements has finished adding its own defs to it, so it is both the earliest
--- moment these answers can be asked for and the moment any previous answer stopped
--- being about this world.
function EP.forgetBuildings()
	parentOf = {}
	boundsOf = {}

	-- The column memo lives in LGEPPlumbing, next to the only function that uses it, and
	-- is cleared from here so there is ONE place that forgets what this mod believes
	-- about the map's shape.  Reached through the EP table rather than by name so it is
	-- resolved when it is called: this file is loaded before the server one, so a direct
	-- local would be nil at load time, and the guard covers any future side that does not
	-- load LGEPPlumbing at all.
	if EP.forgetColumns then EP.forgetColumns() end

	-- The bucket index is rebuilt HERE rather than lazily on first use, and which of the
	-- two it is decides whether this costs anything a player can feel.
	--
	-- It is one pass over the metagrid's building list either way.  Left until first use,
	-- that pass lands inside whichever gameplay frame happens to need it - which is a
	-- chunk streaming in, the exact frame it exists to make cheap.  Measured: a peak
	-- streaming frame of 15,109 operations built lazily, against 384 built here.
	--
	-- OnLoadedMapZones is raised straight after IsoWorld assembles the metagrid and
	-- Basements has finished appending its defs, so it is both the earliest moment the
	-- list is complete and a moment nobody is playing through.
	buildRelaxIndex()
end

Events.OnLoadedMapZones.Add(EP.forgetBuildings)

--------------------------------------------------------------------------------
-- the collective supply
--------------------------------------------------------------------------------

--- Is this collector held in reserve?
---
--- A reserve barrel is part of the supply and counts toward what a tap reads, but
--- it is the last to give: nothing comes out of it until every other barrel the
--- fixture can reach is dry.  It is a store you keep, not a store you hide.
---
--- This is the flag that used to say "main supply", repurposed rather than
--- retired, because the thing it named no longer exists.  There is no election
--- and no stand-down any more - a building may have any number of reserves or
--- none, which is the normal state - so it is a plain property of a barrel,
--- alongside include/exclude.
---
--- Recorded in the collector's own modData because that is what survives the save
--- and travels to clients on its own, so a client can label the menu without
--- being told anything.
---
--- A barrel outside the network is not a reserve either, for the same reason it
--- has no pump: keeping the answers welded together means there is one truth
--- about whether a barrel is in this system.  Unlike the old main, the flag is
--- NOT cleared when a barrel is excluded - being held back is a property of the
--- barrel rather than a post it holds, so re-including it restores what the
--- player chose instead of silently forgetting it.
function EP.isReserve(object)
	if not object or not object:hasModData() then return false end
	if object:getModData()[EP.KEY_RESERVE] ~= true then return false end
	return EP.isIncluded(object)
end

--------------------------------------------------------------------------------
-- which liquid
--------------------------------------------------------------------------------

--- Water is what a fixture draws unless somebody has said otherwise, so it is also
--- what an absent key means everywhere below.  Naming it once means the default is
--- stated in one place rather than spelled out at six call sites.
EP.FLUID_DEFAULT = "Water"

--- Tainted water is not a liquid of its own here, and that is a decision rather
--- than a simplification.
---
--- IsoObject.createSampleAndPurifyWater is the whole of a plumbed fixture's fluid
--- path and it rewrites TaintedWater to Water per FluidInstance on the way through:
---
---     FluidType t = inst.getFluid().getFluidType() == FluidType.TaintedWater
---                 ? FluidType.Water : inst.getFluid().getFluidType();
---
--- so a tap fed tainted water pours clean water.  A "Tainted Water" entry in the
--- menu would therefore be an option that does not describe what comes out of the
--- tap, and there is no way to make it describe it without patching the engine.
---
--- Two more reasons, either of which would be enough on its own:
---
---   * Whether a collector fills clean or tainted is FillsWithCleanWater on its
---     entity script, so splitting them would carve a roof into two supplies by
---     accident of which barrels happened to have lids on.
---   * It is what already happens.  Today a clean barrel and a tainted one are one
---     supply and vanilla's own water code decides what the mixture means; keeping
---     them one liquid is that behaviour restated, so no existing save changes.
---
--- EP.fillFromGroup still adds every fluid the group holds in its own right, so a
--- 3:1 clean to tainted group is still a 3:1 mirror and this mod still has no
--- opinion about taint.  This is the ONLY substitution the mod makes anywhere, and
--- it is the same one the engine makes.
---
--- IT IS ALSO WHY A CLEAN-AND-TAINTED BARREL IS NOT A MIXTURE HERE.  Everything
--- below treats a liquid as a SET of fluids, and the set is built out of canonical
--- names - so Water and TaintedWater in one barrel deduplicate to the single name
--- "Water", exactly as they always have.  The barrel is a mixture as far as the
--- engine's FluidContainer is concerned and is one plain water barrel as far as
--- this mod is concerned, which is the behaviour every existing save was written
--- with.

--------------------------------------------------------------------------------
-- A LIQUID IS A SET OF FLUIDS
--------------------------------------------------------------------------------
--
-- A barrel can hold more than one thing at once.  Pour bleach into a rain barrel
-- and top it up from the tap and the engine keeps BOTH - FluidContainer holds an
-- ArrayList of up to MAX_FLUIDS (8) FluidInstances and blends them, subject only to
-- each fluid's own BlendWhiteList.  Nothing about that is unusual or a corner case;
-- it is how a player makes bleach solution, dilutes anything, or contaminates a
-- barrel by accident.
--
-- THIS MOD USED TO ANSWER "WHAT IS IN THAT BARREL" WITH getPrimaryFluid(), WHICH IS
-- THE LARGEST INSTANCE, AND THAT WAS A LIE IN THE ONE DIRECTION THAT COSTS THE
-- PLAYER SOMETHING.  A barrel of 300 water and 50 bleach read as a water barrel; it
-- joined the building's water supply; and EP.fillFromGroup then rebuilt the mirror
-- as 350 of pure WATER, because the fast path adds the group's primary fluid once to
-- reach a total it already knows.  The bleach was not merely mislabelled, it was
-- deleted - and a tap the player expected to be undrinkable poured clean water.
--
-- SO A LIQUID IS THE SET, AND THE SET IS THE IDENTITY.  Bleach-and-water is its own
-- plumbable liquid, listed in the menu beside Water and Whiskey; every barrel in the
-- building holding that same pair pools with it; and the mirror over a tap pointed at
-- it holds the exact blend those barrels add up to, litre for litre.
--
-- WRITTEN AS THE COMPONENT NAMES, CANONICALISED, DEDUPLICATED, SORTED, JOINED BY "+".
--
--     Water                a barrel of rain
--     Bleach+Water         bleach solution
--     Water                clean water and tainted water (see above)
--
-- Sorted so the name of a mixture does not depend on which barrel was looked at
-- first, or on Kahlua's pairs() order, either of which would split one supply into
-- two that never pool.  Deduplicated so the canonical form is unique.
--
-- IT IS THE SET AND NOT THE RATIO, and that is the one judgement in this section.
--
-- Keying on proportions is the obvious alternative and it does not survive contact
-- with the world: a barrel outdoors gains rain every few minutes and a tap takes
-- water out in fractions, so the ratio of every barrel in a building drifts
-- continuously and independently.  Two barrels a player filled from the same bucket
-- would be different liquids by the afternoon, each in a supply of one, and a tap
-- would go dry because its own barrel had moved out from under it.  The set is
-- stable under everything that does not add a NEW fluid, which is exactly the
-- boundary a player would draw themselves.
--
-- The consequence, stated plainly rather than discovered: a whiskey barrel standing
-- OUTSIDE becomes Water+Whiskey the moment it catches rain, and leaves the whiskey
-- supply.  That is what has actually happened to it.  Before this, rain quietly
-- turned it into a water barrel once the rain outweighed the whiskey, and the
-- whiskey was destroyed on the next settle; now it is diluted whiskey and says so.
--
-- ON DISK NOTHING MOVED.  A single-fluid liquid is written exactly as it was - the
-- bare fluid type name - so KEY_HOLDS, KEY_FLUID and KEY_DEBT_FLUID in every
-- existing save read back identically and no barrel, fixture or mirror is touched by
-- this change.  Only a genuine mixture writes a name with a "+" in it, and a build
-- with none of this code in it reads that as an unknown fluid, which it already
-- treats as "not the one I am looking for" rather than as corruption.

--- The separator in a stored liquid name, and the one shown to a player.
---
--- "+" cannot appear in a FluidType name: they come from `fluid <Name>` blocks in the
--- script files, which are parsed as identifiers.  EP.liquidFrom is the only place a
--- name is ever built and EP.liquidParts the only place one is taken apart, so if a
--- mod ever does register a fluid with a "+" in it, this is the one line to change.
EP.MIX_SEP  = "+"
EP.MIX_JOIN = " + "

--- FluidContainer.MAX_FLUIDS.  A container refuses a ninth fluid outright
--- (FluidContainer.java:900), so a liquid cannot have more components than this and a
--- name off the wire claiming more is not describing anything that can exist.
EP.MAX_PARTS = 8

--- Returned for a liquid with no components.  Shared, and never modified by anything
--- here; a caller that wants to keep an answer must copy it.
local NO_PARTS = {}

--- Two memos, both bounded, both holding nothing until a mixture actually exists.
---
--- The hot path is a bare fluid name - every barrel in a normal world - and it never
--- reaches either of these: EP.canonicalFluidType returns on a string.find that fails
--- and EP.liquidParts is not called at all.  A world with mixtures in it has a handful
--- of distinct ones, so the memos hold single figures.
---
--- CAPPED AND CLEARED WHOLESALE rather than evicted, because the only way to reach the
--- cap is a fault - a mod registering fluids in a loop, or a stream of malformed names
--- that got past the command handler - and in that case forgetting everything is both
--- correct and free.  Clearing rather than refusing to memoise keeps the bound on
--- memory rather than on behaviour.
local PARTS_MEMO_CAP = 64
local partsMemo, partsMemoCount = {}, 0
local canonMemo, canonMemoCount = {}, 0

--- The components of a liquid, in the order they were written.
---
--- Raw: this splits and does not canonicalise, because every liquid the mod stores is
--- already canonical and re-deriving it on every read would be work with no answer in
--- it.  EP.canonicalFluidType is what canonicalises, once, at the point a name arrives
--- from a save file, the wire, or a container.
---
--- DO NOT MODIFY THE RESULT.  It is memoised and shared.
function EP.liquidParts(liquid)
	if type(liquid) ~= "string" or liquid == "" then return NO_PARTS end

	local cached = partsMemo[liquid]
	if cached then return cached end

	local out = {}
	local at = 1
	while true do
		local sep = string.find(liquid, EP.MIX_SEP, at, true)
		if not sep then
			local last = string.sub(liquid, at)
			if last ~= "" then out[#out + 1] = last end
			break
		end
		local piece = string.sub(liquid, at, sep - 1)
		if piece ~= "" then out[#out + 1] = piece end
		at = sep + 1
	end

	if partsMemoCount >= PARTS_MEMO_CAP then partsMemo, partsMemoCount = {}, 0 end
	partsMemo[liquid] = out
	partsMemoCount = partsMemoCount + 1
	return out
end

--- There is deliberately no EP.isMixture(liquid) predicate.  Nothing needs to ask -
--- EP.fluidLabel branches on the component count it has already taken, and
--- EP.breakdownLines answers nil for a liquid with nothing to break down, which is the
--- single test its one caller uses.  A second way to ask the same question is the drift
--- the seams in this file are arranged against.

--- Build the canonical name of a liquid from a list of component names.
---
--- Deduplicated and sorted in one insertion pass.  `out` is kept sorted, so the first
--- entry that is not less than `n` is either `n` itself - a duplicate, and the only
--- place one can be - or the place `n` belongs.  At most eight components, so a hand
--- sort is cheaper than a comparator and cannot throw inside a menu, which is the same
--- reasoning EP.liquidsInScope's own sort is written out for.
---
--- nil for an empty list, which is what "this barrel belongs to no liquid" is spelled
--- as everywhere in this file.
function EP.liquidFrom(names)
	local out = {}

	for i = 1, #names do
		local n = names[i]
		if type(n) == "string" and n ~= "" then
			local at, dup = #out + 1, false
			for j = 1, #out do
				if out[j] == n then dup = true; break end
				if n < out[j] then at = j; break end
			end
			if not dup then table.insert(out, at, n) end
		end
	end

	if #out == 0 then return nil end
	if #out == 1 then return out[1] end
	return table.concat(out, EP.MIX_SEP)
end

--- A liquid name from anywhere - a save file, the wire, a container - in canonical form.
---
--- Two short-circuits before any work, and between them they cover every barrel in a
--- world that has never seen a mixture:
---
---   * TaintedWater is Water, which is the substitution the long note above is about
---   * a name with no separator in it is a single fluid and is already canonical
---
--- Only a name that really is a mixture reaches the split, and that answer is memoised.
function EP.canonicalFluidType(t)
	if type(t) ~= "string" or t == "" then return nil end
	if t == "TaintedWater" then return EP.FLUID_DEFAULT end
	if not string.find(t, EP.MIX_SEP, 1, true) then return t end

	local cached = canonMemo[t]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end

	local parts = EP.liquidParts(t)
	local names = {}
	for i = 1, #parts do
		local n = parts[i]
		names[#names + 1] = (n == "TaintedWater") and EP.FLUID_DEFAULT or n
	end
	local out = EP.liquidFrom(names)

	if canonMemoCount >= PARTS_MEMO_CAP then canonMemo, canonMemoCount = {}, 0 end
	canonMemo[t] = (out ~= nil) and out or false
	canonMemoCount = canonMemoCount + 1
	return out
end

--------------------------------------------------------------------------------
-- reading a container's contents without allocating one table per barrel
--------------------------------------------------------------------------------

--- Hand every fluid in a container to `take(context, fluid, amount)`.
---
--- THE ONE PLACE A CONTAINER'S CONTENTS ARE ENUMERATED, and there are three callers
--- that must not drift: the liquid a barrel belongs to, the summary a mirror is built
--- from, and the breakdown a tooltip prints.  All three want the same walk and only
--- one of them wants the amounts, so the walk is written once and the difference is
--- `take`.
---
--- A CALLBACK RATHER THAN A LIST, because the settle path runs this once per member
--- per mirror per lap.  A base with six hundred barrels would otherwise allocate six
--- hundred tables, and every one of them thrown away in the same frame - which is the
--- allocation pattern the maintenance cursor exists to keep out of a frame.
---
--- THE FAST PATH IS THE ONLY PATH MOST WORLDS TAKE.  FluidContainer.isMixture() is
--- `fluids.size() > 1`, so an ordinary barrel answers false and this is one extra Java
--- call against the getPrimaryFluid() the old code made anyway.
---
--- THE MIXED PATH GOES THROUGH FluidSample, because the ArrayList itself is private
--- and there is no getter for it.  createFluidSample copies the instances into a
--- pooled sample, and FluidSample IS an exposed class - FluidInstance is NOT, so
--- sample:getFluidInstance(i):getAmount() would fail at runtime and the amounts are
--- read back off the container by fluid instead.  (LuaManager.Exposer.shouldExpose is
--- `this.exposed.contains(clazz)`, and a class outside that set has none of its own
--- methods bound.)
---
--- The fluids are collected and the sample RELEASED before `take` is called even once,
--- so a throw inside a caller cannot strand a pooled object.  That costs one table on
--- the mixed path, which is the path that already costs a Java allocation.
---
--- Both engine methods are probed for.  They are ordinary FluidContainer members and
--- are always there in a shipping build; the guards mean a build without them costs
--- the mixture case rather than every water tap in the world.
function EP.eachFluid(fc, take, context, amount)
	if not fc then return end

	amount = amount or fc:getAmount()
	if amount <= EP.EPS then return end

	local mixed = fc.isMixture and fc:isMixture() and fc.createFluidSample
	if not mixed then
		local fluid = fc:getPrimaryFluid()
		if fluid then take(context, fluid, amount) end
		return
	end

	local sample = fc:createFluidSample()
	if not sample then return end

	local found = {}
	local n = sample:size()
	for i = 0, n - 1 do
		local fluid = sample:getFluid(i)
		if fluid then found[#found + 1] = fluid end
	end
	sample:release()

	for i = 1, #found do
		local fluid = found[i]
		local part = fc:getSpecificFluidAmount(fluid)
		if part > EP.EPS then take(context, fluid, part) end
	end
end

--- CAN THE ENGINE ACTUALLY SERVE THIS FLUID THROUGH A PLUMBED FIXTURE?
---
--- `IsoObject.createSampleAndPurifyWater` - the function every external-source read goes
--- through - throws the `Fluid` away for its `FluidType` and adds it back by enum.
--- `FluidType` is a fixed enum of 33 names, a `fluid` script block whose name is not one of
--- them gets `FluidType.Modded`, and `Fluid.Get(FluidType.Modded)` is null.
--- `FluidContainer.addFluid(null, x)` is a silent no-op.  So the fluid is destroyed and the
--- supply is charged for it.  61 vanilla fluids, 27 servable and **34 not** - and every
--- modded fluid is `Modded` by definition.  See plans/lgep-fluid-refusal-is-silent.md.
---
--- ASKED OF THE ENGINE, NOT COMPARED AGAINST THE STRING "Modded".  A build that promoted a
--- fluid to its own constant would leave a hardcoded test bypassing a fixture that had
--- started working by itself, and this needs no list at all.  Measured over all 61: it
--- answers 27 servable, throws for none, and Lua does pick the FluidType overload of
--- `Fluid.Get` rather than the String one - which per
--- memory/nil-picks-the-wrong-java-overload is not a thing to assume.
function EP.fluidIsServable(fluid)
	if not fluid then return true end
	local ok, resolved = pcall(Fluid.Get, fluid:getFluidType())
	return ok and resolved ~= nil
end

--- Does what this container holds have to be moved by hand?
---
--- True as soon as ONE component is unservable, because the charge is proportional across
--- the whole blend: water and cola together deliver the water, charge for both and destroy
--- the cola - and then the tap names itself "Water" and looks perfectly healthy.  Measured
--- on all 1267 legal pairs; every single mixed pair loses its unservable share.
function EP.containerNeedsBypass(fc)
	if not fc then return false end
	local unservable = false
	EP.eachFluid(fc, function(_, fluid)
		if not unservable and not EP.fluidIsServable(fluid) then unservable = true end
	end, nil)
	return unservable
end

--- Collect canonical component names.  Module level so EP.containerLiquid allocates
--- one table per call rather than one table and one closure.
local function takeName(names, fluid)
	names[#names + 1] = EP.canonicalFluidType(fluid:getFluidTypeString())
end

--- Which liquid a container's contents ARE, or nil for an empty one.
function EP.containerLiquid(fc, amount)
	local names = {}
	EP.eachFluid(fc, takeName, names, amount)
	return EP.liquidFrom(names)
end

--- Which liquid this collector belongs to, or nil for one nobody has filled yet.
---
--- DERIVED FIRST, ALWAYS, and remembered only as a fallback.  A barrel with
--- something in it simply *is* what it is holding, so the memory can never be wrong
--- about it - the worst a stale KEY_HOLDS can do is describe an empty barrel, and
--- the next pour corrects it in the same call.  That ordering is the whole safety
--- argument, and it is the lesson KEY_DORMANT cost a version: a cache may be read,
--- but it may never be the gate.
---
--- It also means the rule "a barrel keeps its liquid until it is empty AND
--- something new goes in" needs no transition detection and no event.  While the
--- barrel holds anything, a splash of something else blends in and getPrimaryFluid
--- goes on naming the majority holder; once it is empty the memory answers; the
--- first pour after that reassigns it by derivation.  So an emptied petrol barrel
--- is still a petrol barrel, and stops being one the moment somebody pours beer in.
---
--- nil is "waiting to be assigned" and is not the same as Water.  An unassigned
--- barrel joins whichever group asks for it, as a receiver - see EP.serves.
---
--- IT IS THE WHOLE OF THE CONTENTS AND NOT THE LARGEST PART, and that is the change
--- the section above is about.  getPrimaryFluid() is still what answers for an
--- ordinary barrel, because for a container holding one fluid it IS the whole of the
--- contents; a barrel holding two answers with both, as a mixture.
function EP.barrelFluidType(object)
	if not object then return nil end

	local fc = object:getFluidContainer()
	if not fc then return nil end

	local amount = fc:getAmount()
	if amount > EP.EPS then
		-- The single-fluid case, written out rather than left to EP.containerLiquid, so
		-- the ordinary barrel costs no table and no string work at all.  Same answer
		-- either way; EP.liquidFrom on a one-name list returns that name.
		if not (fc.isMixture and fc:isMixture()) then
			local fluid = fc:getPrimaryFluid()
			if fluid then return EP.canonicalFluidType(fluid:getFluidTypeString()) end
		else
			local liquid = EP.containerLiquid(fc, amount)
			if liquid then return liquid end
		end
	end

	if not object:hasModData() then return nil end
	return EP.canonicalFluidType(object:getModData()[EP.KEY_HOLDS])
end

--- Remember what a collector is holding, so it still knows once it is empty.
---
--- This is the only WRITE the claim system makes to a barrel, and it is guarded so
--- that a save which has only ever carried water never gains the key:
---
---   * a barrel holding nothing is left alone.  The absence of a memory IS the
---     memory - that is what keeps a drained petrol barrel a petrol barrel.
---   * a barrel holding water when the key is already absent is left alone, because
---     writing "Water" would say exactly what the default already says.
---   * a barrel that has come round to holding water again CLEARS the key rather
---     than setting it, which is the path rain takes: an emptied whiskey barrel
---     left out in the weather fills with water, and is a water barrel from then on.
---
--- So the key appears only on a barrel that genuinely holds something other than
--- water, and disappears again by itself.
---
--- The unchanged case is one table comparison, which matters because this is called
--- once per collector per settle pass.  Everything before it - the container, the
--- amount, the primary fluid - is what EP.barrelFluidType would have asked anyway.
function EP.rememberBarrelFluid(object)
	if not EP.isAuthority() then return end
	if not object then return end

	local fc = object:getFluidContainer()
	if not fc or fc:getAmount() <= EP.EPS then return end

	-- Asked of EP.barrelFluidType rather than derived a second time here.  The
	-- container is known to hold something, so that call cannot reach its KEY_HOLDS
	-- fallback and is pure derivation - which is the point: what gets REMEMBERED is
	-- by construction the same answer everything else DERIVES, so a mixture cannot be
	-- filed under one name and looked up under another.
	local liquid = EP.barrelFluidType(object)
	if not liquid then return end

	local data = object:getModData()
	local remembered = data[EP.KEY_HOLDS]
	if remembered == liquid then return end
	if liquid == EP.FLUID_DEFAULT and remembered == nil then return end

	data[EP.KEY_HOLDS] = (liquid ~= EP.FLUID_DEFAULT) and liquid or nil
	object:transmitModData()

	-- Guarded rather than left to EP.log: the square is asked for three times and
	-- may be nil for an object mid-removal, and none of that should be paid for -
	-- or risked - by a build with Debug off.
	if EP.debugging() then
		local square = object:getSquare()
		EP.log(("collector at %s is now a %s collector"):format(
			square and EP.key(square:getX(), square:getY(), square:getZ()) or "?", liquid))
	end
end

--- What to call a liquid in front of a player.
---
--- Fluid.getTranslatedName is the engine's own, so this costs NO translation keys:
--- all 61 vanilla fluids and every modded one name themselves in each of the 38
--- languages this mod ships, and a fluid added by a mod nobody here has heard of
--- names itself too.
---
--- Guarded end to end because it is only ever used to build a menu, and a menu is
--- the one place in this mod where throwing takes other people's entries down with
--- it.  An unknown type falls back to its own identifier, which is ugly and
--- harmless.
function EP.fluidName(liquid)
	if type(liquid) ~= "string" then return "?" end

	local ok, fluid = pcall(Fluid.Get, liquid)
	if not ok or not fluid then return liquid end

	local named, name = pcall(fluid.getTranslatedName, fluid)
	if not named or type(name) ~= "string" or name == "" then return liquid end
	return name
end

--- What to call a LIQUID in front of a player - one fluid, or a mixture of them.
---
--- A mixture is its components' own translated names joined by " + ", in the
--- canonical order, so "Bleach + Water" reads the same for every player and in every
--- language without this mod owning a single string for it.  The join is punctuation
--- rather than a word for exactly that reason: a translated conjunction would need a
--- key per language and would still have to be argued about in the ones that put it
--- somewhere other than between the two.
---
--- Costs nothing for the ordinary case: a name with no separator is one string.find
--- away from the old function above.
function EP.fluidLabel(liquid)
	if type(liquid) ~= "string" then return "?" end

	local parts = EP.liquidParts(liquid)
	if #parts <= 1 then return EP.fluidName(liquid) end

	local out = {}
	for i = 1, #parts do out[#out + 1] = EP.fluidName(parts[i]) end
	return table.concat(out, EP.MIX_JOIN)
end

--- WHAT THE MIXTURE ACTUALLY IS, in litres, as tooltip lines - or nil for a supply
--- that is only one fluid and has nothing to break down.
---
--- The whole reason a mixture is a liquid of its own is that the player can see what
--- is in it, so this is not decoration: "Bleach + Water" on the row says which supply
--- it is, and this says whether it is a barrel of bleach with a splash of rain in it
--- or the other way round.  There is nowhere else in the game that number appears -
--- vanilla's own tap tooltip prints one total.
---
--- Ordered by EP.summaryOrder, so the first line is the majority component and is also
--- the fluid the tap reports itself as.  The two agree by construction rather than by
--- being written to agree.
---
--- IT LISTS THE REAL FLUIDS, WHICH IS NOT ALWAYS THE ROW'S OWN COMPONENTS.  Clean and
--- tainted water are one liquid here and one row called Water, and a building holding
--- both breaks down as "Water: 270 L / Tainted Water: 30 L" - which is true, useful,
--- and something this mod could not say before.  It does not make tainted water a
--- separate plumbable liquid; see the long note on EP.canonicalFluidType.
---
--- Whole litres.  A supply is hundreds of litres across a dozen barrels and two
--- decimal places of it is noise; vanilla's own tap tooltip prints two because it is
--- describing one bottle.
function EP.breakdownLines(sum)
	if not sum then return nil end

	local order = EP.summaryOrder(sum)
	if #order <= 1 then return nil end

	local out = {}
	for i = 1, #order do
		local part = order[i]
		out[#out + 1] = getText("ContextMenu_LGEP_LiquidPart",
			EP.fluidName(part.name), string.format("%.0f", part.amount))
	end
	return table.concat(out, " <LINE> ")
end

--- Which liquid this fixture draws.  Absent means water, so every fixture in every
--- existing save answers the same thing it always did without being written to.
function EP.fixtureFluidType(fixture)
	if not fixture or not fixture:hasModData() then return EP.FLUID_DEFAULT end
	return EP.canonicalFluidType(fixture:getModData()[EP.KEY_FLUID]) or EP.FLUID_DEFAULT
end

--- Is this collector part of the supply a fixture at fz drawing `wantType` reads?
---
--- EP.eligible answers height, pumps and inclusion; this adds the one question
--- those never asked, which is whether the barrel holds the right thing.  It is
--- deliberately the same shape and the same single site: the server building a
--- group, the client building the same group for its stand-in, and the sweep asking
--- whether a mirror still has any business being fed all come through here, so they
--- cannot drift apart.  That is the note on EP.eligible, one question further on.
---
--- AN UNASSIGNED BARREL SERVES WATER, AND ONLY WATER.  This is the one rule here
--- that is a judgement rather than a deduction, so it is written out in full.
---
--- The obvious answer is that a barrel "waiting to be assigned" should serve
--- nothing until somebody fills it.  It is wrong, and the reason is that
--- "unassigned" is not only the state of a brand new barrel: because the memory is
--- deliberately never written for water, EVERY DRAINED WATER BARREL IS UNASSIGNED
--- TOO.  Serving nothing would therefore drop a house that had run out of water out
--- of its own water supply - the tap would read 0 / 0 rather than 0 / 1600, and a
--- bottle could no longer be emptied into the sink to prime the barrels, because
--- EP.pourIntoGroup shares a pour out by free space and there would be no group to
--- share it into.
---
--- The other obvious answer - serve every liquid - is what this used to do, and it
--- over-claims in the other direction: a whiskey tap in a building holding one
--- unclaimed empty barrel would report 0 / 400 of whiskey it has no way of getting.
---
--- Water is the honest middle.  An unclaimed collector is a rain barrel; rain is
--- water; left where it stands it fills with water and derives as water anyway.  So
--- it joins the supply it was always going to join, and a fixture on anything else
--- counts only barrels somebody has actually claimed for that liquid.  Starting a
--- whiskey supply means pouring whiskey into the barrel, which is the claiming
--- action in the first place.
---
--- Returns the collector's own liquid as a second value, so a caller that wants to
--- know whether it is assigned - EP.pourIntoGroup does, to fill claimed barrels
--- before unclaimed ones - gets it without asking twice.
--- There is deliberately no option to turn this off.  A barrel belonging to what is
--- in it is not a feature bolted onto the supply, it IS the supply - the same rule
--- vanilla already applies to the one barrel it can see, asked of all of them.  A
--- switch that made every barrel feed every fixture again would mean a beer barrel
--- contaminating the drinking water, which is the bug this replaced rather than a
--- mode anybody would choose.
--- Does this collector hold the right thing, whoever is asking and whatever else is true
--- of it?
---
--- The liquid half of EP.serves, split out for the same reason EP.hasPump is: the legacy
--- adoption pass has to ask it while deliberately ignoring the inclusion half, and it must
--- ask THIS rather than carry its own copy of the unassigned-barrel rule - which is the
--- one rule here that is a judgement rather than a deduction, spelled out at length below.
function EP.holdsFor(object, wantType)
	local own = EP.barrelFluidType(object)
	local wanted = EP.canonicalFluidType(wantType) or EP.FLUID_DEFAULT
	if own == nil then return wanted == EP.FLUID_DEFAULT, nil end
	return own == wanted, own
end

function EP.serves(object, sourceZ, fz, wantType)
	if not EP.eligible(object, sourceZ, fz) then return false, nil end
	return EP.holdsFor(object, wantType)
end

--------------------------------------------------------------------------------
-- what a group of collectors adds up to
--------------------------------------------------------------------------------

--- A group is a plain array of
--- { object = collector, x, y, z, reserve = bool, assigned = bool }.
--- Both sides build one - the server off its registry, a client off a box walk -
--- and everything below here works on the result without caring which.
---
--- Every member of a group holds the SAME LIQUID, or holds nothing at all:
--- EP.serves is what puts them in it.  `assigned` is the difference between the
--- two, and only EP.pourIntoGroup cares.
---
--- "The same liquid" is the same SET OF FLUIDS, which is not the same thing as the
--- same container contents.  A group of Bleach+Water barrels is every barrel holding
--- both, in whatever proportions each happens to be in; the mirror over it holds the
--- sum, fluid by fluid, which is the blend those barrels genuinely add up to.  So a
--- group's summary really can have several parts now, and everything below is written
--- for that rather than tolerating it as an edge case.

--- Everything a settle needs to know about a group, in ONE pass over it.
---
--- A maintenance settle used to walk its members three times: EP.groupTotals in
--- settleGhost, EP.groupTotals again inside fillFromGroup, and fillFromGroup's own loop
--- looking for the fluid and the container name.  Each of those is a getFluidContainer and
--- a getAmount per member - Java crossings - and on a group of six hundred barrels the
--- three passes were most of what a settle cost.
---
--- `parts` IS THE ANSWER, and it replaces the old fluid/mixed/biggest trio outright.
---
--- It is a FLUID-BY-FLUID total across the whole group - `parts[typeString] = { fluid,
--- amount }` - and it is what makes a mixture survive being mirrored.  What stood here
--- recorded one fluid, a flag saying whether a second had been seen, and the largest
--- member; from that, fillFromGroup could rebuild a single-liquid group exactly and
--- could only ever approximate anything else.  Per-fluid totals rebuild both exactly,
--- and they cost the same walk.
---
--- BOUNDED BY THE ENGINE, not by the group.  A container refuses a ninth fluid, so a
--- group of six hundred barrels still has at most eight parts and fillFromGroup still
--- makes at most eight addFluid calls - which is the "ONE addFluid, NOT ONE PER MEMBER"
--- property the old fast path had, generalised rather than given up.
---
--- IT IS ONLY VALID UNTIL SOMETHING MOVES.  A draw or a pour changes the very amounts this
--- records, so a summary taken before one is worthless after it - settleGhost throws it
--- away in exactly those cases rather than carrying a stale total into the rebuild.
function EP.newSummary()
	return { total = 0, capacity = 0, name = nil, parts = {}, partCount = 0 }
end

--- Add one fluid's contribution.  Module level, so EP.addToSummary hands EP.eachFluid a
--- function rather than building a closure per member per settle.
---
--- Keyed on the fluid's TYPE STRING rather than on the Fluid object, because Kahlua
--- hands back a fresh wrapper per call and two wrappers around one fluid are not equal
--- to each other - the same trap EP.regionsAt keys on ids for.  The object is kept
--- alongside because addFluid wants it.
---
--- The eighth part is the last: past MAX_FLUIDS the container would refuse the add
--- anyway, and what is dropped here shows up as a shortfall that fillFromGroup tops up
--- with the majority fluid rather than losing.
local function takeIntoSummary(s, fluid, amount)
	local key = fluid:getFluidTypeString()
	local part = s.parts[key]
	if part then
		part.amount = part.amount + amount
	elseif s.partCount < EP.MAX_PARTS then
		s.parts[key] = { fluid = fluid, amount = amount, name = key }
		s.partCount = s.partCount + 1
	end
end

--- Fold one container into a summary.  The unit both the walk and EP.summariseGroup
--- work in, written once so the two cannot drift - the maintenance cursor used to carry
--- a hand transcription of the loop below, and a change to one was a change to one.
function EP.addToSummary(s, fc)
	if not fc then return end

	local amount = fc:getAmount()
	s.total = s.total + amount
	s.capacity = s.capacity + fc:getCapacity()

	EP.eachFluid(fc, takeIntoSummary, s, amount)

	if not s.name then s.name = fc:getContainerName() end
end

--- A summary's parts, largest first, ties broken by name.
---
--- SORTED, AND THE ORDER IS NOT COSMETIC.  IsoObject.purifyExternalWaterSample builds
--- its sample in a container of capacity 1.0 (FluidContainer.reset sets it), so
--- addFluid's `!isFull()` guard drops everything after the first instance - which means
--- the FIRST fluid in the mirror's list is the one a plumbed tap reports as its primary
--- fluid and names itself after.  Adding the majority component first is what makes a
--- mostly-water bleach solution read as water at the tap rather than as whichever
--- barrel the walk happened to reach first.
---
--- It changes only the NAME.  transferFluidTo scales the whole blend into whatever is
--- being filled (`amount * fluidInstance.getAmount()` over a sample scaled to 1.0), so a
--- bottle filled from that tap gets bleach and water in the right proportion and the
--- drink is poisoned exactly as drinking from the barrel would be.
---
--- Ties broken on the name so the order is total.  Without it two components sitting at
--- the same amount would swap places on the whim of Kahlua's pairs(), and the tap would
--- rename itself between one lap and the next.
---
--- `into` is emptied and reused, so the settle path allocates nothing.
function EP.summaryOrder(s, into)
	into = into or {}
	for i = #into, 1, -1 do into[i] = nil end

	for _, part in pairs(s.parts) do
		local at = #into + 1
		for i = 1, #into do
			local other = into[i]
			if part.amount > other.amount
				or (part.amount == other.amount and part.name < other.name) then
				at = i
				break
			end
		end
		table.insert(into, at, part)
	end

	return into
end

function EP.summariseGroup(group)
	local s = EP.newSummary()
	for i = 1, #group do
		EP.addToSummary(s, group[i].object:getFluidContainer())
	end
	return s
end

--- What the group holds, and how much it could hold.
function EP.groupTotals(group)
	local amount, capacity = 0, 0
	for i = 1, #group do
		local sc = group[i].object:getFluidContainer()
		if sc then
			amount = amount + sc:getAmount()
			capacity = capacity + sc:getCapacity()
		end
	end
	return amount, capacity
end

--- Make a container read as the sum of the group, blended.
---
--- Not "copy the fullest and scale it", which was the cheap option and is a lie
--- the moment two barrels hold different things: one clean barrel among ten
--- tainted ones would have made the whole supply read clean.  Every fluid the group
--- holds is added in its own right, so three barrels of rain and one of tainted come
--- out as a 3:1 mixture and vanilla's own water code decides what that means.  This
--- mod has no opinion about taint and does not want one.
---
--- ONE addFluid PER FLUID, NOT ONE PER MEMBER, AND NOT ONE FOR THE WHOLE GROUP.
---
--- The middle of those three is what this is, and the other two are what it used to
--- be at different times.  Per member was two hundred Java crossings on a two hundred
--- barrel group to reach a total already known; one for the whole group was the fix,
--- and it was only correct because a group was a single liquid by construction, so it
--- destroyed anything else - a bleach solution poured into the mirror as pure water,
--- and the bleach gone from the building's books for good.
---
--- Per FLUID keeps the saving and drops the assumption.  EP.summariseGroup has already
--- totalled the group fluid by fluid in the walk it was doing anyway, and a container
--- cannot hold more than MAX_FLUIDS of them - so this is at most eight calls whatever
--- the group's size, and exactly one for the ordinary barrel of rainwater.
---
--- LARGEST FIRST.  IsoObject.purifyExternalWaterSample builds its sample in a container
--- of capacity 1.0, so the first FluidInstance fills it and the rest are dropped by
--- addFluid's own `!isFull()` guard - the mirror's FIRST fluid is what a plumbed tap
--- reports as its primary and names itself after.  See EP.summaryOrder; the ordering is
--- there and this only has to respect it.
---
--- `target` is what the container should end up holding, which is the group total
--- less any unpaid debt.  It is applied with adjustAmount, which scales every
--- FluidInstance proportionally - so the blend survives being scaled.
---
--- Two engine details this has to work around, both in FluidContainer.java:
---
---   * canAddFluid (:900) refuses everything when inputLocked or !canPlayerEmpty,
---     so both are cleared for the rebuild and put back after.  Refusing silently
---     would leave a mirror empty over a building full of water.
---   * MAX_FLUIDS is 8, and a fluid that cannot blend with what is already in
---     there is refused too.  Either would leave the total short, so the shortfall
---     is topped up with the largest part rather than quietly lost.  Neither can
---     arise from a group this mod builds - every member holds the same set of
---     fluids, so what blended in a barrel blends in the mirror - but the top-up is
---     the difference between an optimisation that relies on an invariant and one
---     that survives it being wrong.
---
--- The ORDER is load bearing and must not be rearranged: Empty first, then
--- setCapacity, then fill.  setCapacity (:683) scales the existing contents down
--- proportionally when the new capacity is below what is held, so setting it while
--- the old contents are still in there destroys water that no barrel was ever
--- credited for - which is exactly what happens every time a group shrinks,
--- because a barrel unloaded or a generator stopped.  Emptying first means there
--- is nothing to scale.
--- `summary` is EP.summariseGroup's answer, when the caller has already taken one.
--- Without it this takes its own, which is what every caller outside the settle does.

--- Reused rather than allocated per settle.  Safe because nothing between the two uses
--- of it re-enters this function: every call in the body goes into the engine's own
--- container methods, none of which calls back into Lua.
local fillOrder = {}

function EP.fillFromGroup(fc, group, target, summary)
	if not fc then return end
	summary = summary or EP.summariseGroup(group)

	local wasLocked, couldEmpty = fc:isInputLocked(), fc:canPlayerEmpty()
	fc:setInputLocked(false)
	fc:setCanPlayerEmpty(true)

	fc:Empty()

	local total, capacity = summary.total, summary.capacity
	fc:setCapacity(capacity)

	local order = EP.summaryOrder(summary, fillOrder)
	for i = 1, #order do
		local part = order[i]
		if part.amount > EP.EPS then fc:addFluid(part.fluid, part.amount) end
	end

	local short = total - fc:getAmount()
	if short > EP.EPS and order[1] then fc:addFluid(order[1].fluid, short) end

	if target and target < fc:getAmount() - EP.EPS then
		fc:adjustAmount(math.max(0, target))
	end

	if summary.name then fc:setContainerName(summary.name) end
	fc:setInputLocked(wasLocked)
	fc:setCanPlayerEmpty(couldEmpty)
end

--- Where the server's group builder is hung.  supplyGroupFor(fx, fy, fz, wantType)
---
--- The registry a group is built from lives in the server file, and this file is
--- loaded by clients too, so the delivery layer asks through a hook rather than
--- calling into something that may not be there.  A multiplayer client leaves it
--- nil and never reaches the code that needs it - everything that settles is
--- behind EP.isAuthority().
---
--- wantType is optional and defaults to water, so a caller that has not been taught
--- about liquids yet asks the question this mod has always asked.
EP.supplyGroupFor = nil

--- The same hook for a GENERATOR plumbed into a building.  generatorGroupFor(gx, gy, gz, wantType)
---
--- Asked by LG Extended Electricity's fuel line, and hung beside supplyGroupFor for the
--- same reason.  It is the same walk, gravity and pumps included, with one difference,
--- written at walkBegin: the building is resolved the way the Plumb generator row resolved
--- it, not from the generator's own square.  Nil on a build that predates it, which that
--- mod reads as "ask supplyGroupFor instead".
EP.generatorGroupFor = nil

--- Something the building's pipework reaches, that a ghost above could feed.
---
--- waterPiped is vanilla's own marker for it, and it is the flag every branch of
--- the water code keys off: sinks, baths, showers, toilets, washing machines and
--- combination washer/dryers all carry it, and nothing else does.  No class list
--- and no sprite list, so a modded fixture that carries the flag - which it must,
--- or vanilla would not plumb it either - is handled without being known about.
---
--- Deliberately *not* asking isInARoom() here.  This is the test the registry is
--- built with, and the registry is built from LoadGridsquare, where the square's
--- room is not necessarily settled yet.  Being in a room is vanilla's condition
--- for offering Plumb rather than a fact about the object, so it is asked later,
--- at the point a ghost is actually decided on.
function EP.isPlumbableFixture(object)
	if not object then return false end
	if EP.isGhost(object) then return false end

	local sprite = object:getSprite()
	if not sprite or not sprite:getProperties():has(IsoFlagType.waterPiped) then return false end
	return true
end

--- PUT BACK A PLUMB FLAG THE ENGINE DROPPED ON THE WAY TO THIS MACHINE.
---
--- Read the note on EP.KEY_PIPED first: for a washing machine the plumb flag is written
--- into the object change packet as zero bytes, so the authority is plumbed and this side
--- is not, for ever.  The key beside it went by modData, which syncs for every class.
---
--- Only ever sets the flag, never clears it.  A fixture plumbed before this key existed
--- carries no key at all, and a false key would then unplumb every sink in a save that
--- predates the patch.  Clearing is the authority's job and it does it by clearing the
--- KEY, in reconcilePipedFlag - so an unplumb reaches this side as "the key went away",
--- which this correctly does nothing about, and as the flag itself, which for every class
--- but the broken one syncs on its own.  For the broken one an unplumb is invisible here
--- until the chunk reloads; the cost of that is a washing machine that still looks plumbed
--- to somebody who was standing next to it while somebody else unplumbed it, which is a
--- great deal less than an unplumbed base.
---
--- Local rather than authoritative in every sense: this writes to this machine's own copy
--- of the object and transmits nothing.  setUsesExternalWaterSource is a plain field write
--- (IsoObject:2374), so there is no packet and no way for this to reach anybody else.
function EP.repairPipedFlag(fixture)
	if not fixture then return false end
	if not EP.getOption("WasherPatch") then return false end

	-- ONLY ON A NETWORK CLIENT, which is the only machine that can have lost the flag.
	-- The key exists because an object-change packet drops it on the way here; in
	-- singleplayer there is no packet and the flag on this object IS the truth, so a
	-- repair could only ever overwrite the truth with a stale copy of itself - and the
	-- authority reading its own repair back would then launder it into the record.
	-- reconcilePipedFlag writes nothing off a server for the matching reason.
	if not EP.isNetworkClient() then return false end

	if not fixture.getUsesExternalWaterSource or not fixture.setUsesExternalWaterSource then return false end

	if not fixture:hasModData() then return false end
	if fixture:getModData()[EP.KEY_PIPED] ~= true then return false end
	if fixture:getUsesExternalWaterSource() then return false end

	fixture:setUsesExternalWaterSource(true)
	return true
end

--- The first plumbable fixture standing on a square.
function EP.fixtureOnSquare(square)
	if not square then return nil end
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if EP.isPlumbableFixture(object) then return object end
	end
	return nil
end

--- The first collector standing on a square, ghost or otherwise.
function EP.sourceOnSquare(square)
	if not square then return nil end
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if EP.isWaterSource(object) then return object end
	end
	return nil
end

--- Is ANY scripted entity standing on this square?
---
--- THE TEST THAT TELLS A BOTTLE CHANGE FROM A DISPENSER BEING TAKEN AWAY, which is the one
--- thing the square-side plumbing flag needs and cannot get from an event.
---
--- Both look identical at the moment they happen: OnObjectAboutToBeRemoved is raised for the
--- dispenser either way, and it is raised BEFORE the removal, so nothing can be learnt by
--- looking at the square from inside it.  The difference only exists afterwards -
--- ISAddTakeDispenserBottle immediately stands a WaterDispenserNoBottle in the same spot,
--- and somebody picking the thing up stands nothing there at all - so the question is asked
--- later, by the maintenance stage, when the answer is in the world to read.
---
--- WHY "ANY SCRIPTED ENTITY" AND NOT SOMETHING TIGHTER.  WaterDispenserNoBottle is a
--- different entity from WaterDispenser and has no FluidContainer, so it is not on the list
--- and no list-based test can see it; and a rule based on the two names sharing a prefix
--- would be a coincidence of vanilla's naming rather than a fact about anything.  What IS
--- true of every such pair is that the replacement is a scripted entity - that is what
--- addWorkstationEntity builds - while bare floor and ordinary furniture are not.
---
--- IT ERRS TOWARD KEEPING THE PLUMBING, deliberately.  A square that keeps its flag when it
--- should have lost it costs one Disconnect; a square that loses it when it should have kept
--- it costs re-plumbing the dispenser and re-choosing its liquid after every bottle change,
--- which is precisely the fault this is here to prevent.  The residual case is narrow and
--- worth writing down: pick a plumbed dispenser up off a square that also has some other
--- scripted entity on it, and the flag stays until somebody disconnects it.
function EP.hasScriptedEntity(square)
	if not square then return false end
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if object and object.getEntityFullTypeDebug then
			local full = object:getEntityFullTypeDebug()
			if type(full) == "string" and full ~= ANONYMOUS then return true end
		end
	end
	return false
end

--- The first listed fixture standing on a square.
---
--- The same shape as EP.sourceOnSquare and for the same reason: the registry keeps an
--- ADDRESS, and an address has to be resolved back to an object every time it is used,
--- because the object it named can have been dismantled, picked up, or streamed out since.
--- Written out rather than folded into sourceOnSquare with a predicate argument - the two
--- are asked from different stages of the cursor and a shared walk would mean a closure per
--- call on both of them.
function EP.fedOnSquare(square)
	if not square then return nil end
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if EP.isFedFixture(object) then return object end
	end
	return nil
end

function EP.sourceAt(x, y, z)
	if not x or not y or not z then return nil end
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	return square and EP.sourceOnSquare(square) or nil
end

--- Is there still a barrel at this address, even if it is not answering as one?
---
--- The registry drops an address the moment EP.sourceAt stops resolving it, and that
--- is right for the case it was written for: a barrel whose chunk has unloaded, or one
--- somebody took away.  An unloaded barrel is re-noticed by LoadGridsquare when its
--- chunk comes back, so forgetting it costs nothing.
---
--- A barrel excluded by EP.isWaterSource is a different thing wearing the same face.
--- It is loaded, it is standing there, and NOTHING will re-notice it - LoadGridsquare
--- has already fired for that chunk and will not fire again, and discover() only sweeps
--- for a fixture whose supply came back empty.  So a barrel that stops qualifying and
--- later starts again was gone for the rest of the session: run a fuel line to one of
--- a building's barrels and take it off again, and the taps never saw it a second time.
---
--- This is the test that tells the two apart.  Loaded, carrying fluid capacity, not one
--- of our own mirrors - a thing that is still physically there, whatever it is doing
--- just now.  Deliberately weaker than EP.isWaterSource and deliberately not a second
--- copy of it: every question about whether a barrel may SUPPLY anything is still asked
--- in one place, and this only answers whether the address is worth keeping.
--- The same question in three answers instead of two, because one caller needs the third.
---
--- "Nothing is standing there" and "I cannot see whether anything is standing there" are
--- the same answer to somethingStandsAt and must not be to retirement: a base whose barrels
--- are in a chunk that has streamed out is indistinguishable from a base whose barrels have
--- all been disconnected, and a mirror torn down for the second reason takes its fixture's
--- water with it.  See retireIfUnsupplied in the server file and
--- plans/lgep-why-players-lost-their-water.md §3.
---
--- ONE grid lookup and one object walk for both callers.  somethingStandsAt is asked once
--- per unresolved candidate per lap and the whole point of the three-way is to not pay for
--- the lookup twice to get the extra bit.
EP.AT_UNLOADED = "unloaded"   -- the square is not in memory; nothing may be concluded
EP.AT_EMPTY    = "empty"      -- the square is loaded and holds no collector-shaped object
EP.AT_PRESENT  = "present"    -- something collector-shaped is standing there

function EP.collectorPresence(x, y, z)
	if not x or not y or not z then return EP.AT_EMPTY end
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	if not square then return EP.AT_UNLOADED end

	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if not EP.isGhost(object) and instanceof(object, "IsoThumpable")
			and object:getFluidCapacity() > 0 then
			return EP.AT_PRESENT
		end
	end
	return EP.AT_EMPTY
end

--------------------------------------------------------------------------------
-- giving a collector back the container the engine took off it
--------------------------------------------------------------------------------

--- A RAIN BARREL THAT COMES BACK FROM A CHUNK UNLOAD WITH NOTHING IN IT AT ALL.
---
--- Not empty of water - empty of COMPONENTS.  No FluidContainer, no MetaTag, nothing.
--- The sprite is untouched, so it still looks like a barrel and still draws; everything
--- else about it is gone.  It is out of both of `fetch`'s buckets, so it gets no rows in a
--- right-click menu that otherwise builds perfectly; getFluidCapacity() is 0, so
--- EP.isWaterSource refuses it and the taps it was feeding lose it; hasFluid() is false, so
--- vanilla will let you pick it up.  And it is saved that way, so it survives a restart.
---
--- WHERE IT COMES FROM, and it is the engine rather than this mod.
---
--- IsoObject.getEntityNetID() (:5859-5877) derives an entity's id from its square AND ITS
--- INDEX in that square's object list:
---
---     long newID = x + (y << 16) + (z << 32) + (objectIndex << 40);
---     GameEntityManager.checkEntityIDChange(this, this.isoEntityNetId, newID);
---
--- so anything that shifts an object's index re-ids it.  checkEntityIDChange then
--- reconciles idToEntityMap, and on a stale or colliding entry it reports the mismatch
--- with
---
---     DebugType.Entity.error("idToEntityMap(%ld)=%s, expected %s", ...)   -- :333, :343
---
--- `%ld` is a C conversion.  Java's Formatter does not have it, so the report itself throws
--- UnknownFormatConversionException - and the throw abandons the reconciliation half done,
--- which leaves the map MORE inconsistent than it was and makes the next one throw too.
---
--- When that throw lands inside GameEntityManager.UnregisterEntity's meta-offload block
--- (:279-291) the object is destroyed as a container.  That block moves EVERY component off
--- the object onto a MetaEntity and only afterwards gives the object a MetaTagComponent
--- pointing at where they went:
---
---     for (...) { gameEntity.removeComponent(component); metaEntity.addComponent(component); }
---     RegisterEntity(metaEntity);                       -- calls getEntityNetID
---     metaTag.setStoredID(metaEntity.getEntityNetID()); -- calls getEntityNetID
---     gameEntity.addComponent(metaTag);                 -- never runs if either threw
---
--- Every rain barrel goes through that block on every unload, because the test to qualify
--- is FluidContainer.isQualifiesForMetaStorage() and that is just `getRainCatcher() > 0`.
--- So a barrel takes the risk every time its chunk closes, and when it loses, the pointer
--- to its own contents is gone and nothing in the engine will ever rebuild it.
---
--- Filed with The Indie Stone; see BugReport/.  This mod is one of the things that can
--- trigger the re-id, because seating a mirror at index 0 shifts everything behind it -
--- but the seat is what makes delivery work at all, and the defect is in the reporting, so
--- what is left to do here is clean up after it.
---
--- WHAT THIS DOES.  Hands the object to the same vanilla function the moveables placement
--- path uses on every put-down (ISMoveableSpriteProps:2374), which rebuilds an object's
--- components from its own item or entity script.  That is exactly what picking the barrel
--- up and putting it down again does, and it is the only recovery anybody has had until
--- now - this just does it without the player having to know.
---
--- IT DOES NOT BRING THE WATER BACK, and saying so plainly matters: the litres are in a
--- MetaEntity that nothing points at any more.  What comes back is a working, empty barrel
--- that collects rain and can be plumbed in again, instead of a dead one.
---
--- THE GATES, cheapest first, and all four are needed.
---
---   * IsoThumpable, because every collector is one and most objects on a square are not.
---   * no FluidContainer - a healthy barrel has one and is none of this function's business.
---   * no MetaTag - an object that is LEGITIMATELY offloaded carries one, and rebuilding
---     its components would strand the real ones and double the building's water.
---   * a sprite that says the object is a placed moveable or a scripted entity, which is
---     the precondition GameEntityFactory.CreateIsoEntityFromCellLoading tests for anyway
---     (:84) - so without it the call is a no-op and the cost is paid for nothing.
---
--- GET THE WATER BACK, BY MAKING THE ENGINE FINISH THE JOB IT STARTED.
---
--- The components are not destroyed.  UnregisterEntity moved them onto a MetaEntity and
--- registered it; what it failed to do was attach the MetaTagComponent that says where they
--- went.  So the barrel is orphaned but the MetaEntity is intact, is in idToEntityMap, and
--- is written to entity_data.bin by MetaEntitySystem.saveMetaEntities - it survives
--- restarts.  Nothing points at it, and that is the whole of the damage.
---
--- THE POINTER IS RECONSTRUCTIBLE.  MetaEntity.alloc stamps `entityNetId` from the SOURCE
--- object (`metaEntity.entityNetId = entity.getEntityNetID()`, :31), and MetaEntity
--- .getEntityNetID() hands that same value back (:103).  So the id the missing tag should
--- have held is the BARREL'S OWN id at the moment it was offloaded, and IsoObject
--- .getEntityNetID derives that from the square and the index:
---
---     newID = x + (y << 16) + (z << 32) + (objectIndex << 40)
---
--- All four are readable from the barrel standing in front of us.
---
--- AND VANILLA DOES THE REST.  GameEntity.addComponent ends with
---
---     if (this.addedToWorldOrEquipped && !this.addedToEntityManager)
---        GameEntityManager.RegisterEntity(this);
---
--- and an orphan is in exactly that state, because RegisterEntity opens with
--- `if (gameEntity != null && gameEntity.hasComponents())` - an object with no components
--- is skipped, so `addedToEntityManager` was never set true when its chunk loaded.  So
--- attaching the tag IS the repair: RegisterEntity sees the MetaTag, reads the stored id,
--- finds the MetaEntity and moves every component back, water and all.  No packet, no
--- square churn, and no index change - the object is never taken off its square.
---
--- WHY A LOOP.  The index the barrel had when it was offloaded is almost always the index
--- it has now, but it need not be - anything added to or removed from that square before
--- the unload would have shifted it.  A wrong guess is cheap and self-clearing:
--- RegisterEntity removes the tag BEFORE the lookup (:177) and returns early when the id
--- misses, which leaves the object exactly as it was and `addedToEntityManager` still
--- false - so the next attempt triggers a register of its own.  The barrel's current index
--- is tried first because it is nearly always right.
---
--- SAFE BY CONSTRUCTION, and this is what makes it worth doing at all: the only objects
--- that reach here have no components and no tag, which is a state nothing legitimate is
--- ever in.  There is nothing to lose and no healthy object within reach of it.
---
--- Lua has no bitwise operators on this VM, so the shifts are multiplications.  The largest
--- id this can build is about 7e13, well inside a double's exact integer range, so nothing
--- is rounded on the way to a Java long.
---
--- Returns true when the container came back.
--- COLLECTORS SOMEBODY PUT DOWN IN THIS SESSION, and the one thing adoption may never take.
---
--- `EP.adoptLegacyPlumbing` exists to carry barrels that were ALREADY supplying a fixture
--- across the change that made plumbing an act. It must not carry a barrel the player has
--- just built - that would restore the old "everything in range is plumbed" behaviour for
--- exactly the bases most likely to have a mirror.
---
--- The mark used to do that job by being spent fast, and spending it fast is what left a
--- half-streamed base half-adopted for good. Now the mark waits for the chunks to settle and
--- THIS says what must not be taken meanwhile: a placement raises `OnObjectAdded`, and a
--- chunk arriving raises `LoadGridsquare`, so the two are told apart by the event that
--- brought the barrel rather than by a race.
---
--- Session-scoped by design. A barrel placed in an EARLIER session is legacy on the next
--- load, which is the same answer the durable mark gives.
local placedHere = {}

function EP.notePlacedCollector(x, y, z)
	placedHere[EP.key(x, y, z)] = true
end

function EP.wasPlacedThisSession(x, y, z)
	return placedHere[EP.key(x, y, z)] == true
end

--- A new world is a new set of placements.
function EP.forgetPlacements()
	placedHere = {}
end

--- A new world is a new set of placements, and a new wire.
--- memory/caches-must-be-session-scoped-not-process-scoped.md
Events.OnInitGlobalModData.Add(function()
	EP.forgetPlacements()
	if EP.forgetPacketAssembly then EP.forgetPacketAssembly() end
	if EP.forgetAdoptionCounts then EP.forgetAdoptionCounts() end
end)

--- How far past the square's current size to look for a seat it has lost.  See the loop.
local META_LOST_SEATS = 8

local META_SHIFT_INDEX = 1099511627776   -- 2^40
local META_SHIFT_Z     = 4294967296      -- 2^32
local META_SHIFT_Y     = 65536           -- 2^16

function EP.recoverStrandedComponents(object)
	if ComponentType == nil or ComponentType.MetaTag == nil then return false end
	if not GameEntityFactory or not GameEntityFactory.AddComponent then return false end

	local square = object:getSquare()
	if not square then return false end

	local x, y, z = square:getX(), square:getY(), square:getZ()
	local base = x + y * META_SHIFT_Y + z * META_SHIFT_Z

	-- A SEAT ANOTHER OBJECT IS SITTING IN IS THAT OBJECT'S ID, NOT A SPARE ONE.
	--
	-- This used to walk the barrel's own index and then EVERY OTHER INDEX THE SQUARE HAS,
	-- under a comment claiming that staying inside the square's current size kept the search
	-- away from other objects' MetaEntities. It is the other way round. The id built here is
	-- `x + y<<16 + z<<32 + index<<40`, which is exactly `IsoObject.getEntityNetID()`
	-- (`IsoObject.java:5859-5876`) - so the id for index `i` on this square IS the entity id
	-- of whatever object is standing at index `i`.
	--
	-- And presenting it is not a read. `GameEntityFactory.AddComponent` reaches
	-- `GameEntity.addComponent`, which calls `GameEntityManager.RegisterEntity` for an object
	-- that is in the world and not yet registered (`GameEntity.java:268-269`) - which is
	-- precisely a gutted barrel. `RegisterEntity` strips the MetaTag, looks the stored id up,
	-- and if it resolves to a `MetaEntity` it MOVES EVERY COMPONENT OFF IT onto our barrel
	-- and unregisters it (`GameEntityManager.java:176-205`).
	--
	-- So the loop could take a neighbour's contents. An index shift shifts every object after
	-- it, so when this barrel's seat moved its neighbours' did too and they are stranded in
	-- the same way - which makes it likely rather than theoretical. Two shapes, both bad: the
	-- stolen MetaEntity has a FluidContainer, so the barrel accepts it and logs a recovery
	-- while a modded tank or a still is empty for good; or it has none, and the loop strips
	-- only the MetaTag and leaves the stolen components attached to the barrel.
	--
	-- THE WIDER SEARCH IS ONLY SAFE WHEN THIS IS THE ONLY STRANDED ENTITY ON THE SQUARE.
	--
	-- The id built here is `x + y<<16 + z<<32 + index<<40`, which is exactly
	-- `IsoObject.getEntityNetID()` (`IsoObject.java:5859-5876`) - so the id for seat `i` is
	-- the entity id of whatever object HELD seat `i`. And presenting it is not a read:
	-- `GameEntityFactory.AddComponent` reaches `GameEntity.addComponent`, which calls
	-- `GameEntityManager.RegisterEntity` for an object that is in the world and not yet
	-- registered (`GameEntity.java:268-269`) - which is precisely a gutted barrel.
	-- `RegisterEntity` strips the MetaTag, looks the stored id up in the ONE id map the game
	-- has, and if it finds a `MetaEntity` it MOVES EVERY COMPONENT OFF IT onto our barrel and
	-- unregisters it (`GameEntityManager.java:187-205`). The source is gone; there is no
	-- putting it back.
	--
	-- And there is no way to tell whose it was. A MetaEntity under seat 0's id belongs to
	-- whoever HELD seat 0 when the square unloaded, which is not who is standing there now -
	-- so no test on the current occupant can separate "my old seat" from "the tank's old
	-- seat". An index shift moves every object after it, so a square that stranded one
	-- usually stranded several, and that is the ordinary case rather than the rare one.
	--
	-- So: when this is the only stranded entity here, every MetaEntity filed under this
	-- square's ids must be ours and the search may widen. When it is not, the search stays on
	-- our own seat and on the seats nobody can own. The cost of being careful is an empty
	-- barrel that still works, which this function's own note calls the better failure; the
	-- cost of being wrong is another mod's tank emptied for good.
	local objects = square:getObjects()
	local held = objects:size()

	--- Another object here that could itself own a MetaEntity: an entity by the same test
	--- `repairOrphanedCollector` uses, carrying no components at this moment.
	local function strandedNeighbour(i)
		local other = objects:get(i)
		if not other or other == object then return false end
		if other.hasComponents and other:hasComponents() then return false end
		local sprite = other.getSprite and other:getSprite()
		local props = sprite and sprite:getProperties()
		if not props then return false end
		return props:has("CustomItem") or props:has(IsoFlagType.EntityScript)
	end

	local alone = true
	for i = 0, held - 1 do
		if strandedNeighbour(i) then alone = false; break end
	end

	local order, seen = {}, {}
	local now = object.getObjectIndex and object:getObjectIndex() or -1
	if now and now >= 0 then order[#order + 1] = now; seen[now] = true end

	if alone then
		for i = 0, held - 1 do
			if not seen[i] then order[#order + 1] = i; seen[i] = true end
		end
	end

	-- The seats the square has LOST.  Nobody can own these: no object stands there now, so no
	-- live entity is registered under them, and no MetaEntity but ours can be filed there. A
	-- generous few past the end, because an object removed from a square takes every index
	-- after it down by one and nothing records how many have gone; each miss is one Java call
	-- that finds nothing.
	for i = held, held + META_LOST_SEATS do
		if not seen[i] then order[#order + 1] = i; seen[i] = true end
	end

	for i = 1, #order do
		local tag = ComponentType.MetaTag:CreateComponent()
		if tag == nil then return false end
		if tag.setStoredID == nil then return false end

		tag:setStoredID(base + order[i] * META_SHIFT_INDEX)

		-- This call is the repair; everything else here is working out its argument.
		GameEntityFactory.AddComponent(object, true, tag)

		if object:getFluidContainer() ~= nil then
			EP.log(("recovered a collector's stranded contents at %d,%d,%d (seat %d): %.2f"
				.. " litres were on a MetaEntity nothing was pointing at"):format(
				x, y, z, order[i], object:getFluidContainer():getAmount()))
			return true
		end

		-- Missed.  RegisterEntity has already taken the tag off again; clear any it left
		-- behind so the next attempt starts from the same state this one did.
		if object:hasComponent(ComponentType.MetaTag)
			and GameEntityFactory.RemoveComponentType then
			GameEntityFactory.RemoveComponentType(object, ComponentType.MetaTag)
		end
	end

	return false
end

--- Self-limiting rather than latched: a repaired barrel has a container, so the second gate
--- turns it away on every later chunk load.  An object the rebuild cannot help is refused by
--- the fourth gate before the Java crossing.
function EP.repairOrphanedCollector(object)
	if not EP.isAuthority() then return false end
	if not object then return false end
	if EP.isGhost(object) then return false end
	if not instanceof(object, "IsoThumpable") then return false end

	if object.getFluidContainer and object:getFluidContainer() ~= nil then return false end
	if not object.hasComponent then return false end

	-- BEFORE the first `ComponentType` read and not after it.  This guard used to sit five
	-- lines below the next line, so on the very build it exists to survive - one where
	-- `ComponentType` is missing - the line it was written to protect had already thrown,
	-- inside `LoadGridsquare`, once per square for the rest of the session.
	if ComponentType == nil then return false end
	if object:hasComponent(ComponentType.FluidContainer) then return false end

	-- Guarded rather than assumed: ComponentType.MetaTag is read off the engine's enum and
	-- a build without it must not take the repair down with it.  Missing means "cannot tell
	-- whether this is legitimately offloaded", and the safe answer there is to do nothing.
	if ComponentType.MetaTag == nil then return false end
	if object:hasComponent(ComponentType.MetaTag) then return false end

	local sprite = object:getSprite()
	local props = sprite and sprite:getProperties()
	if not props then return false end
	if not (props:has("CustomItem") or props:has(IsoFlagType.EntityScript)) then return false end

	-- IT MUST BE SOMETHING THAT WAS A COLLECTOR, and "a named moveable" was nowhere near
	-- narrow enough.  3.2.5 gated on CustomName alone, which is every crafted table, shelf
	-- and barricade in the world - so the rebuild below was attempted on all of them, on
	-- every chunk load, and each one logged a GameEntityException from Java.
	--
	-- The evidence used instead is this mod's own modData, which is written ONLY on real
	-- collectors and lives on the object rather than in a component - so it is still there
	-- after the engine has taken the components away.  Vanilla's own name test is accepted
	-- too, so a barrel nobody ever plumbed in is still repaired.
	local data = object:hasModData() and object:getModData() or nil
	local wasCollector = data ~= nil
		and (data[EP.KEY_INCLUDE] ~= nil or data[EP.KEY_RESERVE] ~= nil
			or data[EP.KEY_HOLDS] ~= nil)
	if not wasCollector then
		-- ISWorldObjectContextMenuLogic.fetch identifies vanilla's barrel exactly this way.
		wasCollector = props:has("CustomName")
			and props:get("CustomName") == "Rain Collector Barrel"
	end
	if not wasCollector then return false end

	-- THE WATER FIRST, AND ONLY THEN THE EMPTY DRUM.
	--
	-- The stranded FluidContainer still exists on a MetaEntity with everything that was in
	-- it; the only thing wrong is that nothing points at it.  Rebuilding from the script
	-- would give the barrel a NEW empty container and leave the real one stranded for good,
	-- so recovery has to be tried first and the rebuild kept as the fallback for when the
	-- MetaEntity really has gone - which is the case where UnregisterEntity threw before it
	-- managed to register it at all.
	if EP.recoverStrandedComponents(object) then return true end

	if not GameEntityFactory or not GameEntityFactory.CreateIsoEntityFromCellLoading then
		return false
	end

	-- THE PRECONDITION THE REBUILD ACTUALLY HAS, and missing it is what made 3.2.5 log a
	-- Java exception per object per chunk load:
	--
	--     private static void createEntity(GameEntity entity, GameEntityScript script, ...) {
	--        if (entity.hasComponents()) {
	--           throw new GameEntityException("Calling CreateEntity on entity that already
	--                                         has components.", entity);
	--
	-- It refuses an entity with ANY component, not merely one with a FluidContainer - so
	-- testing for those two types was never the same question.  The exception is caught and
	-- logged inside CreateIsoEntityFromCellLoading rather than thrown at us, which is why it
	-- cost a flooded log rather than a broken load, and why no pcall of ours ever saw it.
	--
	-- Asked HERE and not with the other gates, because EP.recoverStrandedComponents attaches
	-- a MetaTag on its way through: an attempt that failed can leave one behind, and that is
	-- a component like any other.
	if object.hasComponents == nil then return false end
	if object:hasComponents() then return false end

	GameEntityFactory.CreateIsoEntityFromCellLoading(object)

	-- Reported on what actually happened, not on having tried.  A rebuild that produced no
	-- container means the object never had one to lose and the gates want tightening; that
	-- is worth a line rather than a silent retry every time the chunk opens.
	if object:getFluidContainer() == nil then return false end

	local square = object:getSquare()
	EP.log(("gave a collector at %s a fresh container; the engine took its own during a chunk"
		.. " unload and the store it put them in is gone, so the contents could not be saved"
		):format(
		square and ("%d,%d,%d"):format(square:getX(), square:getY(), square:getZ()) or "?"))
	return true
end

function EP.somethingStandsAt(x, y, z)
	return EP.collectorPresence(x, y, z) == EP.AT_PRESENT
end

--- Every ghost standing on a square.  There is normally one, but a square that
--- was written by an older version, or by two fixtures that both wanted it, can
--- hold more - and the caller wants to see all of them so it can clear the spares.
function EP.ghostsOnSquare(square, into)
	into = into or {}
	if not square then return into end
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if EP.isGhost(object) then into[#into + 1] = object end
	end
	return into
end
