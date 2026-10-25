--
-- Extended Plumbing - the ghost collector.
--
-- One object, made to answer the engine's four questions about a collector and
-- nothing else about anything.  Building one is a page; keeping its water honest
-- is the rest of the file.
--
-- Where the water lives
-- ---------------------
-- The real barrels' FluidContainers are the truth and the ghost's is a copy of
-- all of them added together.  They cannot be the same object:
-- zombie.entity.Component holds a single `owner`, and setOwner logs an error and
-- *reassigns* when one already exists, so attaching a barrel's container to a
-- second entity would take it off the barrel.  Nor can a ghost simply forward to
-- a barrel, because FindWaterSourceOnSquare rejects any object with
-- getUsesExternalWaterSource() set - that exclusion is there precisely to stop a
-- chain.  And there is nothing to forward TO in any case: a mirror stands for a
-- dozen barrels, not one.
--
-- So the ghost holds its own container and this squares the books.  Three things
-- can move water and each has its own way of announcing itself:
--
--   drawn through a fixture   ghost.useFluid()  -> OnWaterAmountChange(ghost)
--   drawn from a barrel       barrel.useFluid() -> OnWaterAmountChange(barrel)
--   rain into a barrel        FluidContainerUpdateSystem.updateEntity, which
--                             calls addFluid on the *component* and so raises
--                             nothing at all
--
-- The first two arrive as events and are settled the moment they happen.  Rain
-- is silent, which is why there is a sweep as well.  The ledger below is what
-- tells the three apart: it records what was in the ghost when the books were
-- last square, so any difference found later is the fixture's doing and only the
-- fixture's, whatever the barrels have been up to meanwhile.
--
-- Rain no longer needs moving anywhere.  The old design had one elected barrel
-- that every fixture drank from and every other barrel was drained into, so rain
-- falling on the wrong barrel had to be carried across the building before it was
-- any use.  A mirror is the sum of its group now, so rain landing anywhere in
-- that group is in the tap on the next settle with nothing transferred at all.
--

require "LGExtendedPlumbing/LGEPCore"

local EP = LGEP

local EPS = EP.EPS

--- Set while this file is moving water, so the OnWaterAmountChange raised by the
--- move does not come straight back in.
EP.settling = false

--------------------------------------------------------------------------------
-- building one
--------------------------------------------------------------------------------

--- Everything about an IsoThumpable that would otherwise make itself felt.
---
--- Also what a multiplayer client runs on a ghost arriving over the wire, since
--- none of it is saved or transmitted - only the modData that says what the
--- object is travels, which is enough for the client to know to do this.
---
--- Invisibility is setDoRender: it is the first gate in IsoObject.render, and the
--- branch it skips is also the one that calls updateRenderInfoForObjectPicker -
--- so a ghost is not merely undrawn, it is never handed to the picker and cannot
--- be moused over, outlined or clicked.
---
--- Nothing here is what makes it walk through.  Two separate things do that, and
--- both are structural rather than settings:
---
---   * IsoGridSquare.RecalcProperties skips any object whose sprite carries the
---     blueprint flag, so a ghost contributes nothing to the square's collision,
---     floor or vision aggregate.  That flag is set once, in the core.
---
---   * every caller of IsoThumpable.TestCollide in the game - the two in
---     IsoGridSquare and the two in SquareUpdateTask - walks `specialObjects`,
---     and AddTileObject puts an object in `objects` only.  A ghost is never
---     handed to a collision test at all, so it cannot block a step, block a
---     path, or raise OnObjectCollide.
---
--- canPassThrough and blockAllTheSquare are set regardless.  They cost nothing,
--- they state the intent, and if a future build ever does route a ghost through
--- TestCollide they are already the right answer.
---
--- The health and thump settings are there so that nothing can attack what it
--- cannot see: setIsThumpable(false) is what keeps zombies off it.
function EP.dressGhost(ghost)
	-- Before anything else, and on both sides.  The sprite has to carry a name or a
	-- mirror kills the world context menu of whoever right-clicks near it - see the
	-- long note in EP.ensureGhostSprite.  It is hooked to OnGameBoot as well, but a
	-- mirror must be safe because of what it IS, not because an event happened to
	-- have fired first: this runs on a client for every mirror arriving over the
	-- wire, which is the path where that ordering is least in our hands.
	--
	-- And it is not enough to fix the shared sprite: a mirror that has been through
	-- IsoObject.load - which is every mirror out of a save file and every mirror off
	-- the wire - is pointing at an anonymous one of its own instead.  EP.fitGhostSprite
	-- is what puts it back on ours, and the note there is the whole reading.
	EP.fitGhostSprite(ghost)

	ghost:setDoRender(false)
	ghost:setOutlineOnMouseover(false)
	ghost:setSpecialTooltip(false)
	ghost:setName("")

	ghost:setCanPassThrough(true)
	ghost:setBlockAllTheSquare(false)
	ghost:setCrossSpeed(1.0)

	ghost:setIsThumpable(false)
	ghost:setCanBarricade(false)
	ghost:setCanBePlastered(false)
	ghost:setIsDismantable(false)
	ghost:setIsHoppable(false)
	ghost:setIsContainer(false)
	ghost:setIsDoor(false)
	ghost:setIsDoorFrame(false)

	-- Never read: nothing can damage it.  Set anyway so a ghost that somehow
	-- reaches damage code is not a zero-health object about to be destroyed.
	ghost:setMaxHealth(10000)
	ghost:setHealth(10000)
end

--- The ghost's own store.
---
--- Shaped by the group rather than by any one barrel, so the capacity and the
--- contents are set by EP.fillFromGroup on every settle and nothing is decided
--- here.  What is decided here is the handful of things that are true of a mirror
--- whatever it is standing for.
---
--- setRainCatcher(0) is the one that matters most, and it is the whole answer to
--- "the ghost must not collect rain".  FluidContainerUpdateSystem.updateEntity
--- gates rainfall on `getRainCatcher() > 0`, so a zero there is not a lid closed
--- over the barrel, it is a barrel the weather cannot find.  A container made by
--- CreateContainer starts at zero anyway - FluidContainerScript.reset sets it,
--- and only the RainFactor line in an entity script raises it - but it is stated
--- rather than relied on, because it is the difference between one barrel of rain
--- and one barrel per fixture.
---
--- Unlocked and player-emptiable, always, and no longer copied off a barrel.
--- FluidContainer.canAddFluid refuses every add when inputLocked is set or
--- canPlayerEmpty is not, and a mirror has to accept adds from two directions:
--- EP.fillFromGroup rebuilding it, and vanilla pouring a bottle into the sink
--- above it.  A single barrel in the group that happened to be locked would
--- otherwise have made the whole building's tap read empty.
---
--- Building the component when it is missing is a repair, not the normal path, and
--- this used to claim the opposite.
---
--- The claim was that a ghost comes back from a restart with no water in it, on the
--- grounds that GameEntityManager.Save writes meta entities only.  That is true of
--- GameEntityManager and beside the point: IsoObject does its own component
--- serialisation and always has.  IsoObject.save ends with
---
---     if (this.requiresEntitySave()) { bits.addFlags(4096); this.saveEntity(output); }
---
--- and requiresEntitySave() is just hasComponents() (GameEntity.java:507), while
--- load reads it back at the matching flag.  The chunk goes through that same save
--- (IsoGridSquare.save calls objects.get(n).save), and so does the wire, because
--- AddItemToMapPacket.write is writeToRemoteBuffer is save.
---
--- So a mirror normally comes back WITH its container and its water, and with a
--- ledger in modData that matches it - delta zero, nothing charged, which is the
--- quiet correct outcome the accounting was already written for.  It is also why a
--- new mirror arrives on a client able to answer the engine's fourth question
--- immediately rather than waiting on the first sync.
---
--- The repair still has to exist.  A component can be missing - a save from a build
--- that never had one, a component that failed to load (GameEntity.loadEntity
--- swallows a per-component exception and carries on), a mirror rebuilt by hand -
--- and when it is, the ledger AND the debt are zeroed with it, always both or
--- neither.  modData survives independently, so last session's numbers against a
--- brand new empty container would read as the whole group having been drunk while
--- the game was shut down, and a surviving debt would charge the building a second
--- time for water it already paid for.  The container and the books start again
--- together or not at all.
local function fitContainer(ghost)
	local fc = ghost:getFluidContainer()
	if not fc then
		GameEntityFactory.AddComponent(ghost, true, ComponentType.FluidContainer:CreateComponent())
		fc = ghost:getFluidContainer()
		local data = ghost:getModData()
		data[EP.KEY_LEDGER] = 0
		data[EP.KEY_DEBT] = 0
		data[EP.KEY_DEBT_FLUID] = nil
	end
	if not fc then return nil end

	fc:setRainCatcher(0)
	fc:setInputLocked(false)
	fc:setCanPlayerEmpty(true)
	return fc
end

--- Where a ghost for this fixture stands: the centre square, always.
---
--- This used to hunt the nine squares for a free one and give up when they were
--- all occupied.  It does not any more, and the reason is the whole of the design.
---
--- FindExternalWaterSource tests the centre square at z+1 FIRST and returns the
--- instant it finds a source with fluid:
---
---     object = FindWaterSourceOnSquare(centre)
---     if (object != null) { if (object.hasFluid()) return object; empty = object; }
---     ...then, and only then, the eight neighbours
---
--- and FindWaterSourceOnSquare returns the FIRST object on a square answering its
--- four questions, with no opinion about fluid at all.  So a ghost seated at index
--- 0 of the centre square is the answer before a neighbour is ever considered -
--- whatever it is holding, and whatever is standing behind it.
---
--- That is what makes delivery unconditional.  There is no case analysis left: a
--- full barrel on the centre square, the main supply itself, a barrel the player
--- excluded - all of them sit behind the ghost and none of them are consulted.
---
--- It also disposes of two problems the neighbour fallback had.  A ghost on a
--- neighbour square only wins when nothing earlier in the walk has water, so a
--- collector spanning several squares, or a roof with a barrel on every one of the
--- nine, could beat it; and two fixtures whose centre squares were both blocked
--- would fight over the same free neighbour once a minute for ever.  A centre
--- square is (fx, fy, fz+1), which is one per fixture square, so neither can arise.
---
--- getOrCreateGridSquare rather than getGridSquare because the square above a
--- single-storey building is often nothing at all until something is put there.
---
--- The one refusal left is the top of the world: z+1 past IsoChunkMap's ceiling is
--- not a square that can be made.  A fixture up there is left to vanilla.
local function ghostSquare(cell, x, y, z)
	if z + 1 > EP.MAX_LEVEL then
		EP.log("the fixture is at the top of the world; no square above it to stand on")
		return nil
	end
	return cell:getOrCreateGridSquare(x, y, z + 1)
end

--- The seat a ghost must hold, and the one invariant this file has.
---
--- Index 0, so that it is reached before anything else the square is carrying.
--- Nothing in the engine ever reorders a square's object list - there is no sort of
--- `objects` anywhere in the jar, and fixPlacedItemRenderOffsets only adjusts zoff
--- on IsoWorldInventoryObject - so order changes solely through add, insert and
--- remove, and both persistence paths preserve it: IsoGridSquare.save writes in
--- list order and load appends in file order, while loadFromRemoteBuffer re-inserts
--- at the transmitted objIndex.
---
--- So this should never fire.  A barrel built after the ghost appends, landing
--- behind it, which is already right.  It is here because the cost of being wrong
--- is a fixture silently served by a barrel the mod is draining, and the cost of
--- checking is two integer reads on a pass that is already walking the object.
EP.GHOST_SEAT = 0

--- WHICH INDEX A MIRROR TAKES ON ITS SQUARE, and it is not the same answer on every machine.
---
--- ON THE AUTHORITY: index 0, and the seat is load bearing.  FindWaterSourceOnSquare returns
--- the FIRST object on a square answering its four questions and stops, with no opinion about
--- fluid, so a mirror at 0 is the answer before a real barrel standing behind it is ever
--- considered.  That is what makes delivery unconditional, and the insert is TRANSMITTED --
--- transmitAddObjectToSquare carries the index -- so every client inserts at 0 too and the
--- lists stay in step.
---
--- ON A MULTIPLAYER CLIENT: the back of the list, because there the same call is local only.
--- transmitAddObjectToSquare's send half is inside `if (GameServer.server)`, so a client's
--- call is a plain AddTileObject -- and an insert at 0 shifts every other object on that
--- square up by one for as long as the stand-in is up.  Every server-to-client update for an
--- object on a square is addressed by its INDEX in that square's list and by nothing else,
--- with no identity check in any of the three channels: ObjectChangePacket.parse,
--- ObjectModDataPacket and syncIsoObject alike.  So a stand-in at 0 made every packet the
--- server sent about anything on that square land one slot late -- a fluid container written
--- onto the wrong object, modData wiped onto something that never had any, or
--- usesExternalWaterSource set on a real rain barrel, which takes it out of vanilla's own
--- right-click menu and out of EP.isWaterSource with it.
---
--- Measured on the engine in lgep_probe_mpclient: a barrel at index 1 became index 2 while
--- the server went on addressing it as 1.
---
--- APPENDING COSTS THE CLIENT NOTHING, which is what makes this a fix and not a trade.
--- ensureLocalStandIn is the only client caller, and it returns early when ANY water source
--- already answers for the fixture -- `if not EP.isGhost(already) then return end` -- so on
--- that path there is, by construction, nothing on the square for a stand-in to have to beat.
--- And on an empty square, which is the ordinary case because the square above a
--- single-storey building is often nothing at all, appending IS index 0.
local function ghostSeat(square)
	if not EP.isNetworkClient() then return EP.GHOST_SEAT end
	local standing = square and square:getObjects()
	return standing and standing:size() or EP.GHOST_SEAT
end

function EP.isSeated(ghost)
	return ghost:getObjectIndex() == EP.GHOST_SEAT
end

--- Put a ghost back in its seat.  Remove and re-add: there is no move.
---
--- Exact equality on the index, never "close enough", so a settled world cannot
--- emit a Remove and an Add packet per ghost per minute.
function EP.reseatGhost(ghost)
	if not EP.isAuthority() then return false end
	if EP.isSeated(ghost) then return false end

	local square = ghost:getSquare()
	if not square then return false end

	square:transmitRemoveItemFromSquare(ghost)
	square:transmitAddObjectToSquare(ghost, ghostSeat(square))

	EP.log(("the mirror at %d,%d,%d had lost its seat; put back at index %d"):format(
		square:getX(), square:getY(), square:getZ(), EP.GHOST_SEAT))
	return true
end

--- Put a ghost of `source` above the fixture standing at x,y,z.
---
--- transmitAddObjectToSquare rather than AddTileObject: it does the add itself and
--- then, on a server and only on a server, sends the object to the clients, so
--- one call is right in both singleplayer and multiplayer.  It also opens with
--- `if (!objects.contains(obj))`, so calling AddTileObject first would turn the
--- whole thing into a no-op and nothing would ever reach a client.
---
--- The index is EP.GHOST_SEAT and not -1, and that one argument is the difference
--- between a mirror that wins and a mirror that is never looked at.  AddTileObject
--- treats it as an insert - `if (index != -1 && index >= 0 && index <= size)
--- objects.add(index, obj)` - and placeWallAndDoorCheck leaves it alone for a sprite
--- that is not a door, a door frame or a wall.  It travels, too: the object's index
--- on its square is written into the packet and loadFromRemoteBuffer inserts at the
--- same position, so a client seats it identically without being told to.
---
--- The client gets it with doRender true, because doRender is neither saved nor
--- sent - it hides it on arrival, which it can do because the modData saying what
--- the object is does travel.  See the client file.
--- The construction on its own, with nothing decided about water.
---
--- Split out because there are now two reasons to put a mirror above a fixture and only
--- one of them is "there is a group to be a copy of"; see EP.spawnSeatGhost.
local function buildGhost(x, y, z)
	local cell = getCell()
	local square = ghostSquare(cell, x, y, z)
	if not square then return nil end

	local ghost = IsoThumpable.new(cell, square, EP.GHOST_SPRITE, false)
	EP.dressGhost(ghost)

	local data = ghost:getModData()
	data[EP.KEY_GHOST] = true
	data[EP.KEY_FIX_X] = x
	data[EP.KEY_FIX_Y] = y
	data[EP.KEY_FIX_Z] = z
	data[EP.KEY_LEDGER] = 0
	data[EP.KEY_DEBT] = 0

	-- STAMPED AT BIRTH so the legacy adoption pass never looks at a mirror this build
	-- made.  Adoption exists to carry a save across the moment plumbing stopped being
	-- automatic; a mirror created here is being created for a fixture whose barrels were
	-- plumbed in by hand, so there is nothing to carry and re-running it would silently
	-- re-adopt every barrel built afterwards.  See EP.adoptLegacyPlumbing.
	data[EP.KEY_ADOPTED] = true

	-- And SEEN with it: a mirror born here is born over a group that has just been walked,
	-- so adoption has nothing left to look for and retirement need not wait on it.  Both
	-- keys or neither - a mirror stamped adopted but not seen would never retire.
	data[EP.KEY_ADOPT_SEEN] = true

	if not fitContainer(ghost) then return nil end

	square:transmitAddObjectToSquare(ghost, ghostSeat(square))

	-- transmitAddObjectToSquare is a no-op when the square already holds the
	-- object, so confirm rather than assume: settling syncs, and syncing an object
	-- the square does not hold is refused by the engine.
	if ghost:getObjectIndex() < 0 then
		EP.log("the square would not take the mirror; abandoning it")
		return nil
	end

	-- [Malcolm_Perf] a hidden water store is a registered spot (authority only; a client's
	-- stand-in is never recorded)
	if EP.reg and EP.reg.ready() and EP.isAuthority() then
		EP.reg.add(square:getX(), square:getY(), square:getZ(), EP.reg.BIT_GHOST)
	end

	return ghost
end

--- A CLIENT'S STAND-IN FOR A FIXTURE WHOSE BARRELS IT CANNOT SEE.
---
--- A pipe network reaches past the chunks a client has loaded - that is what it is for - so
--- a tap in a house piped to another can have no barrel in view at all, and a stand-in built
--- from what is in view would never go up.  Vanilla offers Plumb on ANY source it finds,
--- empty included - FindWaterSourceOnSquare asks `getFluidCapacity() > 0` and nothing about
--- the amount - so an empty mirror is enough for the first right-click to be right.  The
--- server's own mirror displaces it a moment later with the real total.
---
--- THE CAPACITY IS SET, NOT ASSUMED.  A fresh FluidContainer is 1.0 in the engine
--- (FluidContainer.java:50), but the whole row turns on that one number being above zero,
--- and a default is the kind of thing a build changes without anybody noticing.  One litre,
--- holding nothing.
---
--- Gated by the caller on the authority's network summary (EP.pipeFixtureServesVisible), so
--- it goes up only where the authority WILL build a group - never merely on a blue tile.
function EP.spawnEmptyStandIn(x, y, z)
	if EP.isAuthority() then return nil end
	local ghost = buildGhost(x, y, z)
	local fc = ghost and ghost:getFluidContainer() or nil
	if fc and fc:getCapacity() < 1 then fc:setCapacity(1) end
	return ghost
end

function EP.spawnGhost(x, y, z, group)
	if not group or #group == 0 then return nil end

	local ghost = buildGhost(x, y, z)
	if not ghost then return nil end

	EP.settleGhost(ghost, group)
	EP.log(("mirror above %d,%d,%d stands for %d collector(s)"):format(x, y, z, #group))
	return ghost
end

--- A MIRROR WITH NOTHING IN IT, PUT UP FOR THE ONE REASON THAT IS NOT ABOUT WATER.
---
--- A fixture set to a liquid its building has none of gets an empty group, and until now
--- that meant no mirror at all.  Which is right on its own terms - there is nothing to be a
--- copy of - and wrong about the square it leaves empty, because vanilla then goes looking
--- in the eight squares around it and hands the fixture the mirror belonging to the tap
--- NEXT DOOR.  That is BR-LGEP-021, reported on 2026-08-16 as "side by side fixtures with
--- different plumbed liquids will sometimes show others plumbed liquid", and the whole
--- account is on EP.defendSeat.
---
--- So this stands an empty, dormant mirror in the way, and EP.sleepGhost gives it the seat
--- token that makes the engine stop at it.  It holds nothing, it is charged nothing, and it
--- wakes into an ordinary mirror the day somebody fills a barrel with the right liquid -
--- there is no separate state and no second lifecycle, only a mirror whose group happens to
--- be empty, which the rest of this file already knows what to do with.
function EP.spawnSeatGhost(x, y, z)
	local ghost = buildGhost(x, y, z)
	if not ghost then return nil end

	-- `true` for spokenFor: the caller only reaches here when the building HAS plumbing, and
	-- that is what says this mirror keeps the seat rather than standing aside.
	EP.sleepGhost(ghost, true)
	EP.log(("mirror above %d,%d,%d holds the seat for a liquid the building has none of"):format(
		x, y, z))
	return ghost
end

--- Take a ghost out of the world, water and all.
---
--- Settled against its group first, so anything drawn through it since the last
--- settle is charged to the barrels it actually came out of rather than forgiven.
--- What the container holds after that is a copy of water still sitting in those
--- barrels, so emptying it loses nothing.
---
--- The group is asked for rather than passed in, because every caller reaches
--- here having decided something about the fixture and not about the supply.
--- A FIXTURE LEFT PLUMBED TO A MIRROR THAT HAS GONE, PUT BACK THE WAY IT WAS FOUND.
---
--- WHAT THE STATE COSTS.  Vanilla's Plumb sets usesExternalWaterSource on the fixture, and
--- IsoObject.getFluidAmount tests that flag FIRST (:2638-2647): a plumbed fixture reports
--- whatever its external source has and NOTHING ELSE IT MIGHT HAVE HAD.  Everything below
--- that branch is unreachable - the infinite-mains case, its own container, and
--- `isUnmovedPipedWaterSource() && hasReserveWater()`.
---
--- So a fixture plumbed to a mirror that has gone is drier than an unplumbed one standing
--- beside it: before the water shut-off it has lost the mains, and a TOILET has lost its
--- reserve.  Reading zero, it is also filed under nothing by `fetch`, which files a fixture
--- under storeWater only `if (v.hasFluid())` (ISWorldObjectContextMenuLogic:131) - so it is
--- out of the right-click menu as well.
---
--- WHAT IT DOES NOT COST, and an earlier version of this note had it wrong: the fixture is
--- NOT stuck.  checkExternalFluidSource re-runs doFindExternalWaterSource on every read
--- while its cached source is null or dry (:2626-2636), so the moment anything appears in
--- the nine squares above - a new mirror, a barrel somebody put there - it reconnects with
--- no help from anybody and no wrench.
---
--- WHICH IS WHY THIS IS CALLED FROM THE SANDBOX SWITCH AND NOWHERE ELSE.  A mirror taken
--- away by retirement can come back, and unplumbing the tap in the meantime would cost the
--- player a wrench job for a supply that was going to reconnect itself.  The switch is the
--- one moment the mod is being packed up on purpose and there is nothing to come back to -
--- and it is the moment the mod is documented as preparing for deletion.  See teardown().
---
--- ONLY WHEN NOTHING ELSE ANSWERS.  Asked after the mirror is off the square, so
--- FindExternalWaterSource is answering about the world the fixture is actually left in: a
--- real barrel still standing in the nine squares keeps the fixture plumbed to it, exactly
--- as vanilla would.  It is only the fixture with nothing at all that is put back.
---
--- The flag goes by sendObjectChange, which is vanilla's own channel for it and what
--- ISPlumbItem uses; the marker beside it goes by modData.  Clearing the marker here rather
--- than leaving it to reconcilePipedFlag is deliberate - a fixture with no mirror may never
--- be serviced again, so there would be nothing to run it.
function EP.unplumbStranded(fx, fy, fz)
	if not EP.isAuthority() then return false end
	if type(fx) ~= "number" or type(fy) ~= "number" or type(fz) ~= "number" then return false end

	local cell = getCell()
	local square = cell and cell:getGridSquare(fx, fy, fz)
	if not square then return false end

	local fixture = EP.fixtureOnSquare(square)
	if not fixture then return false end
	if fixture.getUsesExternalWaterSource == nil then return false end
	if not fixture:getUsesExternalWaterSource() then return false end
	if fixture.FindExternalWaterSource == nil then return false end
	if fixture:FindExternalWaterSource() ~= nil then return false end

	fixture:setUsesExternalWaterSource(false)
	if fixture.sendObjectChange then
		fixture:sendObjectChange(IsoObjectChange.USES_EXTERNAL_WATER_SOURCE, { value = false })
	end

	if fixture:hasModData() and fixture:getModData()[EP.KEY_PIPED] ~= nil then
		fixture:getModData()[EP.KEY_PIPED] = nil
		fixture:transmitModData()
	end

	EP.log(("the mirror above %d,%d,%d has gone and nothing else can reach it; "
		.. "putting the fixture back to unplumbed"):format(fx, fy, fz))
	return true
end

--- AUTHORITY ONLY, and it was not stated.
---
--- `square:transmitRemoveItemFromSquare(ghost)` on a client sends a `RemoveItemFromSquare`
--- packet asking the SERVER to delete the object (`IsoGridSquare.java:6385-6400`) - which is
--- exactly the trap `EP.removeLocalGhost` exists to avoid. Unreachable today, because the only
--- caller is behind `LGEPPlumbing`'s file-scope `isClient()` return; guarded so it stays that
--- way if anything ever calls it from `shared/`.
function EP.removeGhost(ghost)
	if not EP.isAuthority() then return end
	local square = ghost:getSquare()
	if not square then return end

	if EP.isAuthority() then
		local group = EP.groupForGhost(ghost)
		if group and #group > 0 then EP.settleGhost(ghost, group) end
	end

	local fc = ghost:getFluidContainer()
	if fc then fc:Empty() end

	square:transmitRemoveItemFromSquare(ghost)

	-- [Malcolm_Perf] forget the spot once no hidden store is left on it
	if EP.reg and EP.reg.ready() then
		local left = 0
		for _, other in ipairs(EP.ghostsOnSquare(square)) do
			if other ~= ghost then left = left + 1 end
		end
		if left == 0 then EP.reg.remove(square:getX(), square:getY(), square:getZ(), EP.reg.BIT_GHOST) end
	end
end

--------------------------------------------------------------------------------
-- finding a supply without a registry
--------------------------------------------------------------------------------

--- Every collector a fixture could draw on, found by looking rather than by
--- remembering.
---
--- Used by a client to decide whether to put up a stand-in so the Plumb option is
--- right on the first right-click, and to show the same total the server's mirror
--- will a moment later.  It is a scan, so it is only ever run on demand - a
--- right-click, or something being placed - never on a clock.
---
--- The region is the fixture's building where it has one and a plain square of
--- `Reach` where it does not, which is the same rule the server applies; the
--- server tests candidates it already knows about, this one goes and finds them.
--- Both keep exactly what EP.eligible accepts, so both reach the same set.
---
--- The two sides can still disagree for a moment - this walks a box and the
--- server walks its registry with a plan test - and that is accepted rather than
--- reconciled.  The server is authoritative, its mirror displaces this one within
--- a tick or two, and the cost of being briefly wrong is a number on a tooltip.
---
--- Split in two.  The BOX is a property of the building; the FILTER is a property
--- of the fixture standing in it.  A right-click needs the same box twice - once
--- filtered to the fixture's own liquid for the stand-in, once unfiltered to list
--- which liquids the building has anything of - and walking it twice would double
--- the one cost on this path that is actually measured in thousands of square
--- lookups.  EP.collectorsInScope walks; EP.groupFrom filters; the old signature is
--- kept below as the two composed, because that is what most callers want.
function EP.collectorsInScope(fx, fy, fz)
	local cell = getCell()
	local square = cell:getGridSquare(fx, fy, fz)
	if not square then return {} end

	local minX, minY, maxX, maxY, minZ, maxZ

	-- The whole building including its basements, from EP.buildingBounds.  A cellar
	-- sink asked its own def before this, and a basement def reports getMaxLevel()
	-- -1: the scan stopped at z 1 and never saw the barrels on the roof, so on a
	-- multiplayer client the Plumb option was simply missing on a fixture the server
	-- would happily have supplied.
	-- A PLAYER-BUILT DEF IS IGNORED ON A NETWORK CLIENT, because the authority cannot see it.
	--
	-- This is the one place the three modes genuinely disagree about the shape of the world.
	-- IsoRegions.update calls clientProcessBuildings inside `if (!GameServer.server)`, so a
	-- BuildingDef synthesised for an enclosed player structure exists in singleplayer and on
	-- every client, and NEVER on a server - dedicated or the child process a co-op host
	-- spawns.  Map buildings resolve everywhere; only these do not.
	--
	-- So on a player base the server scopes by Reach (supplyGroup's fallback, which exists
	-- for exactly this) while a client scoped by the building box - two different regions,
	-- two different groups, and a tap that reads one number and then snaps to another when
	-- the server's answer lands.  It was a latent disagreement for as long as the fallback
	-- has existed; it became visible when the menu started refreshing the mirror from what
	-- the client can see.
	--
	-- Matched to the authority rather than the other way round: the client is the side that
	-- can be wrong here, and the server's Reach answer is the one that decides where water
	-- actually goes.  In singleplayer the authority IS this process, sees the def like
	-- everything else, and keeps the building box - which is why this asks isNetworkClient()
	-- and not isUserDefined() alone.
	local building = square:getBuilding()
	local def = building and building:getDef() or nil
	if def and EP.isNetworkClient() and def.isUserDefined and def:isUserDefined() then
		def = nil
	end
	local bounds = def and EP.buildingBounds(def) or nil
	if bounds then
		minX, minY = bounds.minX - 2, bounds.minY - 2
		maxX, maxY = bounds.maxX + 2, bounds.maxY + 2
		-- Scan wide and let EP.eligible decide per collector: an unpowered one has
		-- to be above the fixture, a pumped one does not, and which is which cannot
		-- be known until the collector is in hand.
		minZ = math.max(-32, math.min(bounds.minZ, fz) - 2)
		maxZ = math.min(EP.MAX_LEVEL, math.max(bounds.maxZ, fz) + 2)
	else
		local reach = EP.getOption("Reach")
		minX, minY = fx - reach, fy - reach
		maxX, maxY = fx + reach, fy + reach
		minZ = math.max(-32, fz - 4)
		maxZ = math.min(EP.MAX_LEVEL, fz + 4)
	end

	-- AND THE STRUCTURE, unioned into whichever box the two branches above produced.
	--
	-- On THIS side the box is not a pre-filter, it is the scope: EP.groupFrom applies
	-- EP.serves and nothing else, so a collector outside the box is a collector that does not
	-- exist.  That makes this the client's transcription of walkBegin's locality bound, and
	-- the two now have to widen for the same three reasons.
	--
	-- It matters most exactly where the def branch cannot help.  A network client drops a
	-- user-defined def a few lines above, because the authority cannot see one - so before
	-- this, a player base on a client fell to a 12-tile square while the server scoped it by
	-- its structure, and the tap showed one number and then snapped to another.  And in
	-- singleplayer an extension bolted onto a house has no def at all to be dropped: the
	-- engine discards any it synthesises next to a map building, so the def branch above
	-- reports the house alone and stops at its wall.
	--
	-- Unioned rather than substituted, and the z band widened to the region rule's own +/-4,
	-- so this can only ever consider MORE than it did.  EP.serves still decides.
	local regions = EP.regionsAt(fx, fy, fz)
	local rb = regions and EP.regionBounds(regions) or nil
	if rb then
		if rb.minX - 2 < minX then minX = rb.minX - 2 end
		if rb.minY - 2 < minY then minY = rb.minY - 2 end
		if rb.maxX + 2 > maxX then maxX = rb.maxX + 2 end
		if rb.maxY + 2 > maxY then maxY = rb.maxY + 2 end
		if fz - 4 < minZ then minZ = math.max(-32, fz - 4) end
		if fz + 4 > maxZ then maxZ = math.min(EP.MAX_LEVEL, fz + 4) end
	end

	-- Every collector standing in the box, with no test applied at all.  What is
	-- eligible, what is pumped and what holds the right liquid are all decided by
	-- EP.groupFrom below, so this list can be reused for a different question.
	return EP.collectorsInBox(minX, minY, minZ, maxX, maxY, maxZ)
end

--- THE AUTHORITY HAS A REGISTRY AND MUST NOT WALK A BOX.
---
--- MEASURED, on the real engine, with `nanos()` (`tools/luatest/lgep_probe_scopecost.lua`):
--- the box is `(2 x Reach + 1)^2 x 9` squares and a grid lookup is about a microsecond, so
---
---     Reach  4        729 squares      4.0 ms
---     Reach 12 (default)  5,625        9.8 ms
---     Reach 24       21,609           38.6 ms
---     Reach 64 (the most a player can set)  149,769   125.5 ms
---
--- and `EP.adoptLegacyPlumbing` runs exactly this walk once per legacy mirror on EVERY lap
--- of the maintenance cursor - 352 ms, measured, charged one COST_GHOST of purse, for as
--- long as that mirror's building has no plumbed-in collector.  That is a stall nothing in
--- the tick-budget suites could see, because the ledger counts CALLS and this is one call
--- round a table walk (memory/a-ledger-that-counts-calls-misses-table-walks.md).
---
--- It is also unreachable advice made expensive: raising Reach is what BR-LGEP-003's
--- thirteen reporters are told to do when their barrels are not found, and Archery raised
--- it to the maximum.
---
--- SO THE AUTHORITY ANSWERS FROM `sources`, which is the registry `notice()` fills on every
--- LoadGridsquare and `discover()` sweeps into - the SAME set the group walk tests.  That is
--- not merely faster, it is the correctness half: this file's own note above admits the two
--- sides "can still disagree for a moment ... this walks a box and the server walks its
--- registry with a plan test", and on the authority they now cannot.
---
--- A CLIENT HAS NO REGISTRY and cannot cheaply be given one - filing collectors on the
--- streaming path is the cost BR-LGEP-001 was about, measured at 0.0034 ms a square for the
--- client's whole current handler.  So it still walks, but only over squares it could
--- possibly have: `IsoCell.getGridSquare` answers from the per-player chunk maps
--- (`IsoCell.java:3193-3211`), so a square outside every one of them was always going to be
--- nil and the lookup is pure loss.  Clipping to them changes no answer at all.
---
--- Sorted by address rather than left in `pairs` order, because two calls that see the same
--- world should hand back the same list - a suite that compares two answers should not be
--- comparing hash order.
function EP.collectorsInBox(minX, minY, minZ, maxX, maxY, maxZ)
	local cell = getCell()
	local found = {}

	if EP.eachCollector and EP.isAuthority() then
		EP.eachCollector(function(entry)
			if entry.x < minX or entry.x > maxX then return end
			if entry.y < minY or entry.y > maxY then return end
			if entry.z < minZ or entry.z > maxZ then return end
			local source = EP.sourceAt(entry.x, entry.y, entry.z)
			if source then
				found[#found + 1] = { object = source, x = entry.x, y = entry.y, z = entry.z }
			end
		end)
		table.sort(found, function(a, b)
			if a.z ~= b.z then return a.z < b.z end
			if a.x ~= b.x then return a.x < b.x end
			return a.y < b.y
		end)
		return found
	end

	local lx, ly, hx, hy = EP.loadedTileBounds()
	if lx then
		if lx > minX then minX = lx end
		if ly > minY then minY = ly end
		if hx < maxX then maxX = hx end
		if hy < maxY then maxY = hy end
	end

	for cz = minZ, maxZ do
		for cx = minX, maxX do
			for cy = minY, maxY do
				local source = EP.sourceOnSquare(cell:getGridSquare(cx, cy, cz))
				if source then
					found[#found + 1] = { object = source, x = cx, y = cy, z = cz }
				end
			end
		end
	end
	return found
end

--- The tiles this machine has chunks for, across every player's chunk map, or nil.
---
--- `IsoCell.getGridSquare` walks `chunkMap[0..numPlayers-1]` and answers nil for anything
--- outside all of them, so this is the same bound the engine applies one call later - which
--- is what makes clipping to it free of consequences.  Split screen is why it is a union
--- rather than player 0's: two players have two windows on the world and a menu belongs to
--- whichever of them opened it.
---
--- Returns nil where the engine offers no such thing (a dedicated server, which has
--- ServerMap and no chunk map, and every harness), and the caller then clips nothing.
function EP.loadedTileBounds()
	local cell = getCell()
	if not cell or not cell.getChunkMap then return nil end

	local minX, minY, maxX, maxY = nil, nil, nil, nil

	-- `IsoPlayer.numPlayers` is a public static int in Java and is NOT a number here: Kahlua
	-- exposes methods, not fields (memory/kahlua-exposes-methods-not-fields.md), so reading
	-- it hands back something arithmetic throws on.  Four is the engine's own ceiling on
	-- split screen and asking about a chunk map that is not there costs one guarded call.
	local players = 4
	if type(IsoPlayer) == "table" and type(IsoPlayer.numPlayers) == "number" then
		players = IsoPlayer.numPlayers
	end

	for n = 0, players - 1 do
		-- A CHUNK MAP WITH NO PLAYER IN IT IS THE ONE TO SKIP, and `ignore` cannot be read.
		--
		-- `IsoCell` keeps four chunk maps and marks three of them `ignore = n > 0` outside
		-- split screen (`IsoCell.java:367-370`). `ignore` is a public FIELD with no getter,
		-- and Kahlua exposes methods, not fields - so `not map.ignore` was `not nil`, always
		-- true, and this guard never fired once. (It only ever made the union LOOSER, so no
		-- answer was wrong; but the clip BR-LGEP-037 added to `EP.collectorsInBox` was doing
		-- nothing.)
		--
		-- `getSpecificPlayer(n)` is exposed and answers nil for a slot with nobody in it,
		-- which is the same question `ignore` answers and one this side can actually ask.
		local manned = true
		if getSpecificPlayer then manned = getSpecificPlayer(n) ~= nil end
		local ok, map = pcall(cell.getChunkMap, cell, n)
		if manned and ok and map and map.getWorldXMinTiles then
			-- EVERY ONE OF THE FOUR, AND ALL FOUR NUMBERS, or this map says nothing.  A
			-- harness has a cell with a chunk map on it that answers nil, and half an
			-- answer here would clip a real box against a bound that is not one.
			local got, x0, y0, x1, y1 = pcall(function()
				return map:getWorldXMinTiles(), map:getWorldYMinTiles(),
					map:getWorldXMaxTiles(), map:getWorldYMaxTiles()
			end)
			if got and type(x0) == "number" and type(y0) == "number"
				and type(x1) == "number" and type(y1) == "number" then
				x1, y1 = x1 - 1, y1 - 1
				if minX == nil or x0 < minX then minX = x0 end
				if minY == nil or y0 < minY then minY = y0 end
				if maxX == nil or x1 > maxX then maxX = x1 end
				if maxY == nil or y1 > maxY then maxY = y1 end
			end
		end
	end

	if minX == nil then return nil end
	return minX, minY, maxX, maxY
end

--------------------------------------------------------------------------------
-- what was already working keeps working
--------------------------------------------------------------------------------

--- ADOPT THE BARRELS THAT WERE ALREADY SUPPLYING THIS MIRROR'S FIXTURE.
---
--- The one-off cost of plumbing becoming an act rather than a position (see the note on
--- DEFAULTS in LGEPCore) is that every barrel in every existing save reads as unplumbed,
--- because nobody ever said otherwise about them.  Left alone that is a town of taps that
--- worked yesterday and are dry today, and the player has no way to tell that from the mod
--- breaking.  "Why did it stop working" is the complaint, and it is a fair one.
---
--- THE EVIDENCE IS THE MIRROR, and it is good evidence rather than a guess.  A mirror is
--- only ever created for a fixture that vanilla had accepted as plumbed AND that had a
--- non-empty group to be a copy of (serviceFixture returns before spawnGhost when
--- `#group == 0`).  So a mirror standing over a fixture is a durable record that this
--- building had a working supply and that these barrels were it.
---
--- It also cannot erase itself before this runs.  A fixture whose group has gone empty
--- gets sleepGhost, NOT removeGhost - deliberately, because a stopped generator is a state
--- that reverses in a second - so the first pass after the update puts every mirror to
--- sleep and leaves every one of them standing.  The evidence survives the update that
--- invalidates the thing it is evidence for, which is the only reason this is possible at
--- all.
---
--- THAT IS NO LONGER TRUE OF ITSELF, and the difference is guarded at the other end.  A
--- mirror over a building with no plumbing left in it IS taken away now - see
--- retireIfUnsupplied in the server file - and on the first load after this update every
--- barrel in the world reads as unplumbed, which is precisely the state that retires one.
--- Left alone, the pass below would have been racing the pass that destroys its evidence.
---
--- So retirement refuses to touch a mirror that has not been through this one.  The marker
--- it reads is the same KEY_ADOPTED written at the foot of this function and stamped at
--- birth by EP.spawnGhost, and the ghost stage runs this immediately before the settle that
--- can retire - so the ordering is not a race that usually comes out right, it is a gate.
---
--- WHAT IS ADOPTED, and the three exclusions are the whole difference between this and the
--- migration that was rejected as "a migration that guesses":
---
---   * only barrels in THIS fixture's scope, asked with THIS fixture's liquid.  A whiskey
---     barrel is adopted by the whiskey tap's mirror and not by the water tap's, because
---     each mirror asks for its own fixture's fluid - the same question serviceFixture
---     asks.
---   * only barrels whose flag is UNSET.  An explicit false - a barrel the player had
---     already excluded by hand - is never promoted, and neither is anything already true.
---     A player's stated choice outranks this, always.
---   * only barrels that would have supplied it under the OLD rule, which is eligibility
---     with the inclusion clause removed: high enough, or pumped, and holding the right
---     thing.  Asked through EP.hasPump and EP.holdsFor, which are the halves the live
---     predicates are themselves built from, so this cannot drift away from them.
---
--- A barrel standing in a building that never had a plumbed fixture is therefore NOT
--- adopted, and neither is one in a field.  That is exactly the over-application the
--- change exists to end: those barrels were never actually doing anything, so nothing
--- stops working when they stay unplumbed.
---
--- ONCE, EVER, AND MARKED ON THE MIRROR.  Without a durable marker this would re-run every
--- session and quietly re-adopt every barrel built since - which would restore the old
--- behaviour for any building that already has a mirror, defeating the change for exactly
--- the bases most likely to have one.  EP.spawnGhost stamps the key on every mirror it
--- makes, so a mirror created by this build or later never qualifies and a world that has
--- never seen an older build never runs this at all.
---
--- BUT "ONCE" MUST MEAN "ONCE IT COULD ACTUALLY SEE THE BUILDING", and until 2026-08-27 it
--- did not.  The mark was written unconditionally at the foot of this function, including
--- on a visit where `EP.collectorsInScope` had resolved NOTHING because the barrels' chunk
--- was not open yet - and the cursor reaches a mirror on the first lap after ITS chunk
--- opens, which is the worst possible moment to ask.  The guard above already says this in
--- so many words for the FIXTURE and stops; the collectors had no such guard.
---
--- What that cost is not "nothing was adopted".  With nothing adopted `walk.w.supply` is 0,
--- retireIfUnsupplied then removes the mirror, and the mirror was the evidence - so the
--- barrels can never be adopted again, serviceFixture refuses to build a mirror over an
--- empty group, and the fixture is left flagged plumbed with nothing to point at: dry, out
--- of the right-click menu, and with vanilla's own Plumb row gated off by the very flag
--- that stranded it.  The only way out was a wrench on the BARREL.  See
--- plans/lgep-why-players-lost-their-water.md §2.
---
--- THE RULE NOW.  Conclude nothing from a scope that resolved nothing, and stamp
--- permanently only once the building HAS some plumbing.  While a building has zero
--- plumbed-in collectors there is nothing for an over-eager adoption to over-apply onto -
--- that is the whole of why re-running is safe there - and the moment one barrel is in, the
--- player is in control and this stops for good.  A partial scope (some barrels in, some
--- still streaming) is covered by the same rule rather than by luck: whatever it adopts,
--- it goes on trying until the building genuinely has plumbing.
---
--- The honest cost is that "a barrel built afterwards is NOT adopted" now holds only once
--- the building has some plumbing, which is what lgep_spec_adopt §5 is rewritten to say.
---
--- Authority only.  It writes modData and transmits it, and a client doing that would be
--- inventing state the server has not agreed to.
---
--- Returns how many barrels were adopted, which is what the log line and the suite read.
--- How many consecutive laps a building must adopt NOTHING before adoption is called done.
--- See the stamp at the end of EP.adoptLegacyPlumbing.
local ADOPT_SETTLE_LAPS = 3
local adoptQuiet = {}

--- A NEW WORLD STARTS THE COUNT AGAIN, SAID OUT LOUD RATHER THAN LEFT TO AN ACCIDENT.
---
--- The header below says the count is session-scoped "on purpose - a restart starts the count
--- again, which is right, because a restart is exactly when the chunks stream in at different
--- times", and it was a file-local nothing reset.
---
--- It happens to have been true: `IngameState.exit()` calls `LuaManager.init()`
--- unconditionally (`IngameState.java:780, :981`), and that clears `loaded` and builds a fresh
--- environment (`LuaManager.java:1058-1072`), so quitting to the menu really does take every
--- file-local with it. (An audit pass claimed otherwise from `ActiveMods.requiresResetLua`;
--- that field has no Java caller at all - only `MainScreen.lua` reads it, to decide whether
--- the MENU needs a reset before loading.)
---
--- Reset explicitly anyway, for the reason `EP.forgetPacketAssembly`'s own header gives and
--- memory/caches-must-be-session-scoped-not-process-scoped.md states: what this would cost if
--- the accident ever stopped holding is a base whose count had reached 2 stamping
--- `KEY_ADOPTED` on its first quiet lap in the next world - and that flag is SAVED, so
--- BR-LGEP-056 would reopen permanently. One table assignment is cheap insurance against that.
function EP.forgetAdoptionCounts()
	adoptQuiet = {}
end

function EP.adoptLegacyPlumbing(ghost)
	if not EP.isAuthority() then return 0 end
	if not ghost then return 0 end

	local data = ghost:getModData()
	if data[EP.KEY_ADOPTED] then return 0 end

	local fx, fy, fz = data[EP.KEY_FIX_X], data[EP.KEY_FIX_Y], data[EP.KEY_FIX_Z]
	if not (fx and fy and fz) then return 0 end

	local cell = getCell()
	local square = cell and cell:getGridSquare(fx, fy, fz)
	local fixture = square and EP.fixtureOnSquare(square)

	-- NOT MARKED, and returning early rather than marking, because the fixture's chunk may
	-- simply not be open yet.  Marking here would spend this mirror's one chance on a
	-- moment when the answer could not be worked out, and the barrels it should have
	-- adopted would stay dry for good.  The repair pass reaches this mirror again.
	if not fixture then return 0 end

	local want = EP.fixtureFluidType(fixture)
	local found = EP.collectorsInScope(fx, fy, fz)

	-- NOT MARKED, for the same reason the fixture guard above is not marked: a scope that
	-- resolved nothing is a question that could not be answered, not an answer of "no".  The
	-- repair pass reaches this mirror again on the next lap, by which time the chunk it was
	-- waiting on is open.
	if #found == 0 then return 0 end

	-- THE SCOPE RESOLVED, so retirement may consider this mirror from now on even if
	-- adoption never stamps.  Two keys rather than one, because they answer two different
	-- questions and collapsing them re-creates the fault at the other end: gate retirement
	-- on KEY_ADOPTED and a building that legitimately has no plumbing could never retire its
	-- mirrors at all, because under the rule below such a building never stamps.
	data[EP.KEY_ADOPT_SEEN] = true

	local adopted, plumbed = 0, 0
	for i = 1, #found do
		local entry = found[i]
		local collector = entry.object
		local cd = collector:getModData()

		-- NOT SOMETHING SOMEBODY JUST BUILT.  See EP.notePlacedCollector: the stamp below
		-- now waits for the chunks to stop arriving, and this is what keeps that wait from
		-- becoming a window in which a newly built barrel is adopted.
		local placed = EP.wasPlacedThisSession
			and EP.wasPlacedThisSession(entry.x, entry.y, entry.z)

		if cd[EP.KEY_INCLUDE] == nil
			and not placed
			and (entry.z > fz or EP.hasPump(collector))
			and EP.holdsFor(collector, want) then
			cd[EP.KEY_INCLUDE] = true
			collector:transmitModData()
			adopted = adopted + 1
		end

		-- Counted AFTER the adopt above, so a barrel this pass has just taken in counts as
		-- plumbing and the building is finished with adoption in the same visit.
		if cd[EP.KEY_INCLUDE] == true then plumbed = plumbed + 1 end
	end

	-- STAMPED ONLY ONCE THE BUILDING HAS PLUMBING **AND THE SCOPE HAS STOPPED CHANGING**.
	--
	-- `plumbed > 0` alone was a one-off mark spent on a half-streamed base. On the authority
	-- `EP.collectorsInScope` answers from the `sources` registry, and that registry is filled
	-- one square at a time by `LoadGridsquare` - so it holds only the collectors whose chunk
	-- has already arrived. A chunk is eight squares; any base wider than that spans several,
	-- and the mirror lives in the sink's own chunk. So the first visit saw the sink's chunk,
	-- adopted the one barrel standing in it, stamped, and returned 0 for ever after. The
	-- barrels one chunk over - which arrive a frame or two later - were never looked at
	-- again, and `KEY_ADOPTED` is saved, so the decision was permanent.
	--
	-- The note above claims a partial scope is "covered by the same rule rather than by
	-- luck". It went on trying until it adopted ONE.
	--
	-- What a player saw: on the first load after the plumbing-is-an-act update, a base came
	-- back with some of its barrels in the supply and some silently out, no way to tell which,
	-- and a tap reading a fraction of yesterday's water. Worst on a dedicated server, where
	-- chunk arrival is staggered per player.
	--
	-- The rule now: a lap that adopts something resets the count; only after
	-- ADOPT_SETTLE_LAPS consecutive laps that adopt NOTHING is the building called finished.
	-- Session-scoped on purpose - a restart starts the count again, which is right, because a
	-- restart is exactly when the chunks stream in at different times. The cost of waiting is
	-- three laps of a registry read, which BR-LGEP-037 brought down to 0.3 ms.
	local settleKey = EP.key(fx, fy, fz)
	if adopted > 0 then
		adoptQuiet[settleKey] = 0
	else
		adoptQuiet[settleKey] = (adoptQuiet[settleKey] or 0) + 1
	end
	if plumbed > 0 and (adoptQuiet[settleKey] or 0) >= ADOPT_SETTLE_LAPS then
		data[EP.KEY_ADOPTED] = true
		adoptQuiet[settleKey] = nil
	end
	ghost:transmitModData()

	if adopted > 0 then
		EP.log(("adopted %d collector(s) that were already supplying the fixture at %d,%d,%d"
			):format(adopted, fx, fy, fz))
	elseif plumbed == 0 then
		EP.log(("nothing to adopt above %d,%d,%d yet and nothing plumbed in; will look again"
			):format(fx, fy, fz))
	end
	return adopted
end

--- Keep what a fixture at fz drawing `wantType` may actually draw on.
---
--- EP.serves and nothing else, so this reaches exactly the set the server's
--- supplyGroup reaches - which is the whole reason the client duplicates the walk
--- rather than guessing.
function EP.groupFrom(found, fz, wantType)
	local group = {}
	for i = 1, #found do
		local entry = found[i]
		local ok, own = EP.serves(entry.object, entry.z, fz, wantType)
		if ok then
			group[#group + 1] = {
				object = entry.object, x = entry.x, y = entry.y, z = entry.z,
				reserve = EP.isReserve(entry.object),
				assigned = own ~= nil,
			}
		end
	end
	return group
end

--- The two composed, which is what a caller wanting one group off one walk wants.
function EP.visibleSupplyGroup(fx, fy, fz, wantType)
	return EP.groupFrom(EP.collectorsInScope(fx, fy, fz), fz, wantType)
end

--- Which liquids a fixture could be pointed at, and how much of each is in reach.
---
--- Takes the walk's result rather than doing its own, so a right-click pays for one
--- box walk and asks it two questions: what this fixture can draw right now, and
--- what else it could be set to.
---
--- Only ASSIGNED collectors contribute.  An empty unclaimed barrel is in every
--- group at once as a receiver, so counting it would list every liquid in the game
--- as available in a building holding one empty barrel.
---
--- Water is always in the list even when the building has none.  Otherwise a player
--- who switched a tap to whiskey and drank the lot could never switch it back - the
--- list would be empty and the option would be a dead end.
---
--- A MIXTURE IS ONE ROW, AND ITS OWN ROW.  A building holding four barrels of rain
--- and two of bleach solution offers two liquids, not three and not one: Water, and
--- Bleach + Water.  Nothing is listed twice and nothing is folded into anything else,
--- because a barrel belongs to the whole of what is in it.
---
--- Each row carries a SUMMARY rather than two running totals, so the menu can print
--- what the mixture actually is - so many litres of water, so many of bleach - from
--- the same walk and through the same accumulator the mirror is built with.  A row's
--- breakdown therefore cannot disagree with what the tap would pour; they are the
--- same arithmetic.
---
--- Sorted by hand rather than with table.sort.  There are only ever a handful of
--- entries, and a comparator that throws inside a sort inside a context menu is a
--- long way from anywhere that could catch it.
function EP.liquidsInScope(fx, fy, fz, found)
	found = found or EP.collectorsInScope(fx, fy, fz)

	local byType = {}
	local function row(liquid)
		local r = byType[liquid]
		if not r then
			r = { type = liquid, label = EP.fluidLabel(liquid), count = 0,
			      sum = EP.newSummary() }
			byType[liquid] = r
		end
		return r
	end

	for i = 1, #found do
		local entry = found[i]
		if EP.eligible(entry.object, entry.z, fz) then
			local own = EP.barrelFluidType(entry.object)
			if own then
				local r = row(own)
				EP.addToSummary(r.sum, entry.object:getFluidContainer())
				r.count = r.count + 1
			end
		end
	end

	row(EP.FLUID_DEFAULT)

	local out = {}
	for _, r in pairs(byType) do
		-- Kept as plain fields as well as on the summary, because every caller outside
		-- this file reads them and a row is a menu's vocabulary rather than a settle's.
		r.amount = r.sum.total
		r.capacity = r.sum.capacity

		local at = #out + 1
		for i = 1, #out do
			if r.label < out[i].label then at = i; break end
		end
		table.insert(out, at, r)
	end
	return out
end

--------------------------------------------------------------------------------
-- moving water in and out of a group
--------------------------------------------------------------------------------

--- The members of a group on one side of the reserve line.
local function tier(group, reserve)
	local out = {}
	for i = 1, #group do
		if (group[i].reserve == true) == reserve then out[#out + 1] = group[i] end
	end
	return out
end

--- Take `want` out of these collectors, in proportion to what each is holding.
---
--- Proportional, and that is the whole of why no barrel is ever overdrawn.  A
--- barrel holding a_i out of a total of Sa gives want * a_i / Sa, and `want` is
--- clamped to Sa first, so every share is at most a_i by arithmetic rather than by
--- a check that could be wrong.  An almost-empty barrel gives almost nothing.
---
--- It also means every barrel in a group falls together and reaches empty
--- together, so none of them is ever sitting at capacity - and a barrel at
--- capacity cannot catch rain (FluidContainerUpdateSystem gates on free space).
--- The old design drained eleven barrels into a twelfth and then wondered why the
--- twelfth stopped collecting.
---
--- useFluid on the OBJECT rather than removeFluid on its container, deliberately:
--- IsoObject.useFluid ends with this.sync() and triggerEvent("OnWaterAmountChange"),
--- so the barrel tells the clients its new level and any other mod watching a rain
--- barrel hears it.  Our own handler for that event is suppressed while EP.settling
--- is up, which is where this always runs from.
---
--- What each barrel actually gave is MEASURED, never assumed.  useFluid clamps
--- against what is really in there and returns nothing; the container is the only
--- honest witness.
---
--- Returns what was really taken, which can be less than asked when the group is
--- part-unloaded.  The caller carries the difference as debt rather than losing it.
--- Where the sweep-up below starts.  Session state, not saved: which barrel pays a given
--- tick does not matter, only that it is not always the same one.
local sweepFrom = 0

local function drawTier(list, want)
	if want <= EPS then return 0 end

	local total = 0
	for i = 1, #list do total = total + list[i].object:getFluidAmount() end
	if total <= EPS then return 0 end

	local take = math.min(want, total)
	local taken = 0

	for i = 1, #list do
		local object = list[i].object
		local have = object:getFluidAmount()
		if have > EPS then
			local share = take * (have / total)
			if share > EPS then
				local before = have
				object:useFluid(share)
				taken = taken + (before - object:getFluidAmount())
			end
		end
	end

	-- THE SWEEP-UP STARTS SOMEWHERE NEW EACH TIME, AND ABOVE ABOUT A HUNDRED BARRELS IT IS
	-- THE WHOLE DRAW.
	--
	-- `take` is one TICK of a draw and not one bottle: `ISTakeWaterAction:updateUse` asks for
	-- a slice per tick and `maxTime` is `waterUnit * 100 + 30`, so filling a ten-litre bottle
	-- is about a thousand ticks of 0.0097 L. With N equal barrels the proportional share
	-- above is `take / N`, which falls under `EPS` (0.0001) once N is past about 97 - so the
	-- whole proportional pass is skipped and this sweep-up does all of it.
	--
	-- Starting at index 1 every time then meant ONE barrel paid for everything, then the
	-- next, and so on. That is precisely the fault the header above says was fixed: "every
	-- barrel in a group falls together and reaches empty together, so none of them is ever
	-- sitting at capacity - and a barrel at capacity cannot catch rain". A two-hundred-barrel
	-- base drained barrel 1 to nothing while the other 199 sat full and collected no rain,
	-- and the mod's own performance work uses bases that size as the realistic case.
	--
	-- Rotating the start costs one integer and gives the right answer on average: over the
	-- thousand ticks of one bottle each barrel is reached about five times and pays about
	-- `take / N` a tick, which is the proportional share the arithmetic could not express.
	-- The alternative - dropping the EPS gate - is N engine calls per tick instead of one.
	local short = take - taken
	if short > EPS and #list > 0 then
		for k = 0, #list - 1 do
			if short <= EPS then break end
			local i = ((sweepFrom + k) % #list) + 1
			local object = list[i].object
			local have = object:getFluidAmount()
			if have > EPS then
				object:useFluid(math.min(short, have))
				local got = have - object:getFluidAmount()
				taken = taken + got
				short = short - got
			end
		end
		sweepFrom = (sweepFrom + 1) % #list
	end

	return taken
end

--- Draw from the group: everything not held in reserve first, then the reserves.
function EP.drawFromGroup(group, want)
	if want <= EPS then return 0 end

	local taken = drawTier(tier(group, false), want)
	if want - taken > EPS then
		taken = taken + drawTier(tier(group, true), want - taken)
	end
	return taken
end

--- Push `want` into these collectors, in proportion to each one's free space.
---
--- The mirror image of the draw, and overflow-proof for the same reason: a share
--- is at most the free space it was measured from.
---
--- transferFluidFrom on the object, so fluid types travel intact and the barrel
--- announces itself.  Anything past the tier's total free space is clamped away,
--- exactly as vanilla clamps a pour into a full barrel.
local function pourTier(list, fc, want)
	if want <= EPS or not fc then return 0 end

	local free = 0
	for i = 1, #list do
		local sc = list[i].object:getFluidContainer()
		if sc then free = free + math.max(0, sc:getCapacity() - sc:getAmount()) end
	end
	if free <= EPS then return 0 end

	local give = math.min(want, free)
	local given = 0

	for i = 1, #list do
		local object = list[i].object
		local sc = object:getFluidContainer()
		local room = sc and math.max(0, sc:getCapacity() - sc:getAmount()) or 0
		if room > EPS then
			local share = give * (room / free)
			if share > EPS then
				local before = sc:getAmount()
				object:transferFluidFrom(fc, share)
				given = given + (sc:getAmount() - before)
			end
		end
	end

	-- AND THE SAME SWEEP-UP THE DRAW HAS, FOR THE SAME ARITHMETIC AND A WORSE CONSEQUENCE.
	--
	-- `share` here falls under EPS exactly as the draw's does once the group is big enough -
	-- `give / N` for N barrels with equal room - so above about a hundred barrels this loop
	-- placed NOTHING. The draw had a sweep-up to catch that and this never did, and the two
	-- ends are not symmetric in what it costs: a draw that comes up short carries the
	-- difference as a debt, while a pour that comes up short is simply lost. `settleGhost`
	-- rebuilds the mirror from the group's total the moment this returns, so whatever did not
	-- land in a barrel is gone with no record anywhere that it existed.
	--
	-- One pass, starting where the last one left off, and then it stops - never a loop, so
	-- float drift can cost a fraction of a litre but can never spin. What genuinely will not
	-- fit is still clamped away by `give`, which is what vanilla does with a pour into a full
	-- barrel and is not a loss.
	local short = give - given
	if short > EPS and #list > 0 then
		for k = 0, #list - 1 do
			if short <= EPS then break end
			local i = ((sweepFrom + k) % #list) + 1
			local object = list[i].object
			local sc = object:getFluidContainer()
			local room = sc and math.max(0, sc:getCapacity() - sc:getAmount()) or 0
			if room > EPS then
				local before = sc:getAmount()
				object:transferFluidFrom(fc, math.min(short, room))
				local put = sc:getAmount() - before
				given = given + put
				short = short - put
			end
		end
		sweepFrom = (sweepFrom + 1) % #list
	end

	return given
end

--- The members of a group on one side of the assigned line.
local function claimTier(group, assigned)
	local out = {}
	for i = 1, #group do
		if (group[i].assigned == true) == assigned then out[#out + 1] = group[i] end
	end
	return out
end

--- Push `want` back into the group: barrels that already hold this liquid first,
--- unclaimed empty ones only for what will not fit in them.
---
--- The tiering is not symmetry with the draw, it is the only thing standing between
--- a pour and a claim the player did not make.  An unassigned barrel is in every
--- group at once (see EP.serves), so without it, emptying a bottle of whiskey into
--- a sink over one whiskey barrel and three empty ones would share it four ways by
--- free space and claim all three - taking barrels the player was keeping for
--- something else, on an action that was meant to put a litre away.
---
--- Filling the claimed tier first also keeps the common case exactly as it was:
--- with nothing unassigned in range, this is one call and the old arithmetic.
---
--- Still no RESERVE tiering, deliberately.  A reserve barrel is a store you are
--- keeping, which is a rule about taking water out; there is nothing to protect
--- anybody from on the way in, and filling by free space is the one rule that
--- needs no explanation.
function EP.pourIntoGroup(group, fc, want)
	if want <= EPS or not fc then return 0 end

	local given = pourTier(claimTier(group, true), fc, want)
	if want - given > EPS then
		given = given + pourTier(claimTier(group, false), fc, want - given)
	end
	return given
end

--- Reused rather than allocated per top-up, on the same reasoning as fillOrder in LGEPCore:
--- nothing between the two uses of it re-enters this function, because everything in the
--- body goes into the engine's own container methods and none of those calls back into Lua.
local blendOrder = {}

--- ADD `want` LITRES OF WHAT THIS GROUP HOLDS, IN THE PROPORTIONS IT HOLDS THEM.
---
--- EP.fillFromGroup's sibling, and the difference is that this ADDS to whatever is already
--- in the container instead of emptying it and rebuilding it to the group's total.  A mirror
--- IS the group and is rewritten wholesale every settle; a topped-up fixture is a real
--- fifteen-litre vessel somebody drinks out of, and the water going into it is water that
--- has genuinely left the barrels.  Emptying it first would destroy what a player had.
---
--- TAINTED WATER GOES IN CLEAN, AND THAT IS THE ENGINE'S OWN SUBSTITUTION RATHER THAN A NEW
--- RULE.  IsoObject.createSampleAndPurifyWater - the whole of a plumbed tap's fluid path -
--- does exactly this, per FluidInstance, on the way through:
---
---     FluidType t = inst.getFluid().getFluidType() == FluidType.TaintedWater
---                 ? FluidType.Water : inst.getFluid().getFluidType();
---
--- so a tap fed tainted barrels already pours clean water and a dispenser fed the same
--- barrels now does the same.  The barrels are charged in whatever they really hold, because
--- EP.drawFromGroup goes through IsoObject.useFluid and that takes a proportional bite out
--- of each member's real blend.  This is the only substitution the mod makes anywhere.
---
--- LARGEST FIRST, through EP.summaryOrder, so the container names itself after the majority
--- component rather than after whichever barrel the walk reached first - the same ordering
--- argument EP.fillFromGroup spells out, and the same one function doing it.
---
--- The caller is expected to have cleared any input lock: this is deliberately a container
--- operation and has no opinion about the object's own settings.  Returns what actually went
--- in, MEASURED rather than assumed, because addFluid refuses silently when a fluid will not
--- blend with what is already there and the caller has to charge for the truth.
function EP.addBlendFrom(fc, summary, want)
	if not fc or not summary or want <= EPS then return 0 end

	local total = summary.total
	if total <= EPS then return 0 end

	local before = fc:getAmount()
	local order = EP.summaryOrder(summary, blendOrder)

	local clean = nil
	for i = 1, #order do
		local part = order[i]
		local share = want * (part.amount / total)
		if share > EPS then
			local fluid = part.fluid
			if part.name == "TaintedWater" then
				clean = clean or Fluid.Get(EP.FLUID_DEFAULT)
				fluid = clean or fluid
			end
			fc:addFluid(fluid, share)
		end
	end

	-- Float division over eight components does not land exactly on `want`.  One sweep-up
	-- with the majority fluid, never a loop, so drift can cost a fraction of a litre and can
	-- never spin.  Bounded by `want` so this cannot overshoot what the group is being charged.
	local added = fc:getAmount() - before
	local short = want - added
	if short > EPS and order[1] then
		local fluid = order[1].fluid
		if order[1].name == "TaintedWater" then
			clean = clean or Fluid.Get(EP.FLUID_DEFAULT)
			fluid = clean or fluid
		end
		fc:addFluid(fluid, short)
		added = fc:getAmount() - before
	end

	return added
end

--------------------------------------------------------------------------------
-- keeping the books
--------------------------------------------------------------------------------

--- WHAT IS OWED, AND IN WHAT.
---
--- A debt is water drawn through the tap that no barrel has been charged for yet,
--- because the barrel that should have paid it had its chunk unloaded mid-draw.  It
--- is retried on every settle until it is paid.
---
--- It has to carry a liquid now, and this is not bookkeeping neatness.  A fixture
--- can be switched from whiskey to water with a whiskey debt outstanding; paying it
--- out of the water barrels would take water nobody drank and hand the building a
--- shortfall it never incurred, and forgiving it would break the conservation the
--- accounting exists to keep.  So a debt in one liquid simply is not payable from a
--- group of another, and sits until the fixture is pointed back at its own barrels.
---
--- Held as liquid -> amount, because a stranded debt in one liquid and a fresh one
--- in another can both be true at once.  Rare - it takes an unloaded chunk on both
--- sides of a switch - but a single tagged scalar would have to answer it by
--- forgiving one of them, and that is the one thing this ledger may never do.
---
--- ON DISK IT IS STILL A NUMBER whenever it can be, and that is deliberate.  A
--- water-only debt writes exactly what every previous version wrote - a plain
--- number in LGEPDebt and no LGEPDebtFluid at all - so an unchanged save stays
--- unchanged and a build with none of this code in it reads its own format back.
--- The table form only appears for a mirror that genuinely owes two liquids at
--- once; an older build reading that lands on `type(debt) ~= "number"`, which it
--- already treats as nothing owed, so a rollback costs a fraction of a litre rather
--- than a corrupt ledger.
local function readDebt(data)
	local raw = data[EP.KEY_DEBT]
	local out = {}

	if type(raw) == "number" then
		if raw > EPS then
			out[EP.canonicalFluidType(data[EP.KEY_DEBT_FLUID]) or EP.FLUID_DEFAULT] = raw
		end
	elseif type(raw) == "table" then
		for liquid, amount in pairs(raw) do
			if type(liquid) == "string" and type(amount) == "number" and amount > EPS then
				out[liquid] = amount
			end
		end
	end

	return out
end

--- WHAT A MIRROR OWES, IN TOTAL, WHATEVER FORM IT IS WRITTEN IN.
---
--- `readDebt` above has understood two forms since per-liquid landed - a plain number with
--- `LGEPDebtFluid` beside it, and a TABLE of liquid to litres for a mirror that owes two at
--- once - but every reader outside this file was still `type(debt) == "number"`, which reads
--- the table form as nothing owed.  Three of them:
---
---   `retireIfUnsupplied`  the line that says what dies with a mirror being taken away.
---                         A two-liquid debt was removed in silence.
---   the maintenance gate  `owes`, now dead (`local _ = drift or owes`) but still computed.
---   the debug dump        one line per mirror, printing 0.0 for a mirror that owes.
---
--- None of them decides anything today, which is why this is a reporting fix and not a
--- water one - but "the mod knew and wrote it to a log that says nothing" is BR-LGEP-003's
--- whole shape, and the retire line is the only trace a destroyed debt leaves.
function EP.ghostDebt(ghost)
	if not ghost or not ghost.getModData then return 0 end
	local total = 0
	for _, amount in pairs(readDebt(ghost:getModData())) do total = total + amount end
	return total
end

local function writeDebt(data, debts)
	local only, count = nil, 0
	for liquid, amount in pairs(debts) do
		if amount > EPS then
			count = count + 1
			only = liquid
		end
	end

	if count == 0 then
		data[EP.KEY_DEBT] = 0
		data[EP.KEY_DEBT_FLUID] = nil
	elseif count == 1 then
		data[EP.KEY_DEBT] = debts[only]
		-- nil for water, so the ordinary case writes no new key at all
		data[EP.KEY_DEBT_FLUID] = (only ~= EP.FLUID_DEFAULT) and only or nil
	else
		local t = {}
		for liquid, amount in pairs(debts) do
			if amount > EPS then t[liquid] = amount end
		end
		data[EP.KEY_DEBT] = t
		data[EP.KEY_DEBT_FLUID] = nil
	end
end

--- The group a ghost stands for, worked out from the fixture it belongs to.
---
--- Every version of this mod has ever written LGEPFix*, so this answers for a
--- mirror out of any save without a migration step - which is the whole reason
--- the group is derived rather than recorded.  A mirror carries no list of
--- barrels and never has to be re-aimed when one is built, drained or taken away.
--- Returns the group AND the summary the walk built on the way past (Q13).  A caller that
--- writes `local group = EP.groupForGhost(g)` is unaffected; one that takes the second
--- value can hand it to settleGhost and save a whole extra pass over the group.
function EP.groupForGhost(ghost)
	if not EP.supplyGroupFor then return nil end

	local data = ghost:getModData()
	local fx, fy, fz = data[EP.KEY_FIX_X], data[EP.KEY_FIX_Y], data[EP.KEY_FIX_Z]
	if type(fx) ~= "number" or type(fy) ~= "number" or type(fz) ~= "number" then
		return nil
	end
	return EP.supplyGroupFor(fx, fy, fz, EP.ghostFluidType(ghost))
end

--- Which liquid a mirror is standing for.
---
--- The FIXTURE is the truth and is asked first, every time.  The copy kept on the
--- mirror is only consulted when the fixture cannot be resolved at all - which in
--- practice means it has been taken away, since a mirror at fz+1 and its fixture at
--- fz share a chunk in x and y and so load and unload together.
---
--- Answering water in that case would be worse than answering nothing: a whiskey
--- tap whose fixture went missing for one pass would settle against the building's
--- WATER barrels and charge them for whiskey somebody drank.  The last liquid it
--- actually served is the honest answer, and it is one table read.
function EP.ghostFluidType(ghost)
	local data = ghost:getModData()
	local fx, fy, fz = data[EP.KEY_FIX_X], data[EP.KEY_FIX_Y], data[EP.KEY_FIX_Z]

	if type(fx) == "number" and type(fy) == "number" and type(fz) == "number" then
		local square = getCell():getGridSquare(fx, fy, fz)
		local fixture = square and EP.fixtureOnSquare(square)
		if fixture then return EP.fixtureFluidType(fixture) end
	end

	return EP.canonicalFluidType(data[EP.KEY_FLUID]) or EP.FLUID_DEFAULT
end

--- Square the books between one ghost and the group it stands for.
---
--- The ledger holds what the ghost's container had in it when this last ran.  Any
--- difference since is something a fixture did through the ghost and nothing
--- else, because nothing else can reach it: the ghost is invisible, unclickable,
--- kept out of the context menu, and its rain catcher is zero.  Rain and drinking
--- straight from a barrel move that barrel, never the ghost, so they cannot be
--- mistaken for one another.
---
--- Both directions are handled by vanilla methods on the collectors rather than on
--- their containers, so each barrel syncs itself and raises its own
--- OnWaterAmountChange - which is what any other mod watching a rain barrel is
--- listening for, and what a client needs to see levels drop.
---
---     drawn   EP.drawFromGroup    proportional across the group, reserves last
---     poured  EP.pourIntoGroup    proportional to free space, nothing overflows
---
--- Then the ghost is rebuilt as the sum of the group, unconditionally - which is
--- where rain that fell since, and water somebody drank from a barrel by hand, and
--- a barrel that was built or dismantled, are all picked up at once.  There is no
--- refill step and no seam below this any more: the group IS the supply, so
--- "charge it and then make it good again" collapses into "charge it and then read
--- it".  EP.replenishSupply is gone with the main barrel it existed for.
---
--- THE ORDER BELOW IS LOAD BEARING.  Charge the group, then empty, then set the
--- capacity, then refill, then write the ledger.  FluidContainer.setCapacity
--- scales the contents down proportionally when the new capacity is under what is
--- held, so setting it while last settle's water is still in the container
--- destroys water that no barrel was ever credited for - and the capacity drops
--- every time a group shrinks, which is every unloaded chunk and every stopped
--- generator.  Emptying first means there is nothing there to scale.
---
--- The debt is the one place these books can be short.  A draw is charged against
--- whatever is loaded right now, and a member whose chunk went away between two
--- settles cannot be charged at all; the shortfall is carried rather than
--- forgiven, and retried on every settle until it is paid.  The alternative is
--- what the old code did, which was to let useFluid clamp the charge and say
--- nothing.
---
--- Returns true when any barrel's level actually moved, so the caller can tell a
--- settled account from a busy one.
--- Move a mirror in or out of the engine's own water search, and tell the clients.
---
--- THE FLAG IS THE THIRD OF FindWaterSourceOnSquare's FOUR QUESTIONS, and the whole of
--- what EP.sleepGhost's step-aside rests on; see the long note there.
---
--- sendObjectChange rather than sync(), and that is not interchangeable.  IsoObject.sync
--- writes the square, the reserve amount, the fluid container, durability and health
--- (IsoObject.java:907-928) and NOT this flag - so a mirror that stepped aside on the
--- server would go on hiding the barrel behind it on every client, which is the machine
--- the context menu is actually built on.  USES_EXTERNAL_WATER_SOURCE is vanilla's own
--- channel for exactly this field (:4668 out, :4743 in), it is what ISPlumbItem uses, and
--- IsoThumpable.saveChange calls super so a mirror is not one of the classes that drops
--- it.  On a machine that is not a server it writes nothing and costs nothing.
---
--- Only from its square: sendObjectChange addresses an object by its index there, so a
--- mirror that has not landed yet has nothing to be addressed by.  It is carried in the
--- add packet in that case anyway, because writeToRemoteBuffer is IsoObject.save and the
--- flag is bit 32 of it.
local function standAside(ghost, aside)
	if ghost.setUsesExternalWaterSource == nil then return end
	ghost:setUsesExternalWaterSource(aside)

	if ghost.sendObjectChange == nil then return end
	if ghost:getObjectIndex() < 0 then return end
	ghost:sendObjectChange(IsoObjectChange.USES_EXTERNAL_WATER_SOURCE, { value = aside })
end

--- WHO WOULD BE SERVED TO THIS FIXTURE INSTEAD OF THE MIRROR IT OUGHT TO HAVE.
---
--- The engine is asked outright - `fixture:FindExternalWaterSource()` IS the answer the
--- fixture would be given this instant - and then three things narrow it to the case that
--- is actually wrong.  See EP.defendSeat for what is done about it.
---
--- IT MUST HOLD SOMETHING WORTH TAKING.  A source with nothing in it is not poaching
--- anything, and this test is also what keeps two dry mirrors side by side from each
--- defending against the other's seat token for ever: a token is under EP.EPS, so a mirror
--- holding one is not a poacher, and the first of the two to be asked lets the seat go.
---
--- IT MUST BE A DIFFERENT LIQUID.  Two water taps side by side stand for the same building
--- supply and hold the same total, so being handed the neighbour's is harmless - it is the
--- same number - and defending against it would put a token in every kitchen in the world
--- the day its barrels ran dry.
---
--- AND IT MUST BE SOMETHING THIS MOD IS IN CHARGE OF: one of our own mirrors, or a
--- collector somebody has plumbed in.  A rain barrel nobody plumbed, standing in the nine
--- squares above a sink, is vanilla's own plumbing and not ours to veto - the same rule
--- EP.sleepGhost's step-aside keeps from the other side.
function EP.poachedBy(fixture, ownGhost)
	if not fixture or fixture.FindExternalWaterSource == nil then return nil end

	local found = fixture:FindExternalWaterSource()
	if not found or found == ownGhost then return nil end
	if found:getFluidAmount() <= EPS then return nil end

	local mine = EP.isGhost(found)
	if not mine and not EP.isIncluded(found) then return nil end

	local theirs = mine and EP.ghostFluidType(found) or EP.barrelFluidType(found)
	if theirs == EP.fixtureFluidType(fixture) then return nil end

	return found
end

--- A DRY MIRROR THAT IS PASSED OVER, AND THE TAP NEXT DOOR THAT IS SERVED INSTEAD.
---
--- Reported on the Discussions on 2026-08-16: *"Side by side fixtures with different
--- plumbed liquids will sometimes show others plumbed liquid"*, and again by Rodahtnov as
--- *"I think it plumbs to the barrel above the sink"*.  One fault, two reports.
---
--- THE CAUSE IS VANILLA'S SEARCH AND IT PREFERS FLUID OVER POSITION
--- (`IsoObject.FindExternalWaterSource`, :2411-2442):
---
---     object = FindWaterSourceOnSquare(square at z+1)
---     if (object != null) { if (object.hasFluid()) return object;  empty = object; }
---     for (the eight neighbours at z+1) { ... if (object.hasFluid()) return object; ... }
---     return empty
---
--- The centre square - where this mod's mirror stands - wins only while it HAS something.
--- An empty one is set aside and **the first neighbour with fluid wins outright**, and
--- nothing in that search knows which fixture a source belongs to.  There is no ownership
--- in it at all.  Proven on the engine in `tools/luatest/lgep_probe_neighbourliquid.lua`.
---
--- So a mirror that is empty *because the building holds none of the liquid its fixture is
--- set to* does not read dry.  It reads as whatever the fixture next door is holding - and
--- the dangerous direction is not the one that was reported: a tap set to water whose
--- supply has run out, standing next to a tap set to petrol, pours petrol.
---
--- THE ONLY LEVER THE ENGINE OFFERS IS `hasFluid()`, which is `getFluidAmount() > 0.0F`.
--- Stepping aside cannot help and makes it worse - stepping aside is precisely what lets
--- the neighbour be found - and capacity cannot help either, because setCapacity clamps at
--- 0.05.  So the mirror has to hold *something*.
---
--- A SEAT TOKEN: 0.00005 L of the fixture's own liquid.  Measured on the engine in
--- `tools/luatest/lgep_probe_seattoken.lua`, and it is chosen to sit in the one gap that
--- makes this safe rather than merely clever:
---
---   * above zero, so `hasFluid()` is true and the centre square wins outright;
---   * under `EP.EPS` (0.0001), so every ledger, debt, group and total in this mod already
---     reads it as nothing - no accounting anywhere had to learn about it;
---   * far under a hundredth of a litre, so the tap still reads 0.00 to a player, and a
---     draw from it yields 0.00005 L, which is nothing worth having.
---
--- And it names the right liquid: `getFluidUiName` samples the mirror, so a dry whiskey
--- tap now says whiskey and 0 litres instead of saying water and showing the neighbour's.
---
--- ONLY WHEN THERE IS SOMETHING TO DEFEND AGAINST, and the engine is asked rather than
--- guessed at.  `fixture:FindExternalWaterSource()` on an empty mirror IS the answer the
--- fixture would be given this instant; if it comes back as this mirror, or as nothing at
--- all, then nobody is poaching and no token is seated.  One Java call, exact, and no
--- eight-square scan of our own that could disagree with the engine's.
---
--- NEVER OVER A STEP-ASIDE.  A dormant mirror with a real rain barrel behind it stands
--- aside on purpose (see EP.sleepGhost), because an unplumbed barrel above a sink is
--- vanilla's own business and not ours to veto.  Seating a token there would take that
--- back and break the very rule the step-aside exists for.
local SEAT_TOKEN = 0.00005

function EP.defendSeat(ghost)
	if not EP.isAuthority() then return end
	if not ghost then return end

	local data = ghost:getModData()
	local seated = data[EP.KEY_SEATED] == true
	local fc = ghost:getFluidContainer()

	--- Give the seat up: no token, no flag, and tell the clients if either changed.
	local function release()
		local dropped = false
		if fc and fc:getAmount() > 0 and fc:getAmount() <= EPS then
			fc:Empty()
			dropped = true
		end
		if seated then
			data[EP.KEY_SEATED] = nil
			ghost:transmitModData()
		end
		if (dropped or seated) and ghost:getObjectIndex() >= 0 then ghost:sync() end
	end

	-- Stood aside on purpose: whatever is behind it is meant to win.
	if ghost.getUsesExternalWaterSource and ghost:getUsesExternalWaterSource() then
		return release()
	end

	if not fc then
		if seated then data[EP.KEY_SEATED] = nil; ghost:transmitModData() end
		return
	end

	-- It has real water in it, so it already wins the centre square on its own merits, and
	-- whoever filled it dropped any token along with the rest of the contents.
	if fc:getAmount() > EPS then return release() end

	-- LAST TIME'S TOKEN COMES OUT BEFORE THE QUESTION IS ASKED, or the answer would be
	-- about the token rather than about the world: a defended mirror wins its own centre
	-- square, so asking with the token still in it says "nobody is poaching" every time
	-- after the first and the seat could never be given up again.  It goes back in below if
	-- the neighbour is still there, and this is the whole of what makes the function
	-- idempotent - and what lets a mirror stop holding one when the tap next door runs dry.
	if fc:getAmount() > 0 then fc:Empty() end

	local fx, fy, fz = data[EP.KEY_FIX_X], data[EP.KEY_FIX_Y], data[EP.KEY_FIX_Z]
	if type(fx) ~= "number" or type(fy) ~= "number" or type(fz) ~= "number" then
		return release()
	end

	local square = getCell():getGridSquare(fx, fy, fz)
	local fixture = square and EP.fixtureOnSquare(square)
	if not fixture then return release() end

	-- The mirror is empty at this instant, so this is exactly the answer the engine would
	-- hand the fixture.
	if not EP.poachedBy(fixture, ghost) then return release() end

	-- The FIRST fluid of the liquid, which for a mixture is the one the tap reports itself
	-- as anyway (IsoObject.purifyExternalWaterSample builds its sample in a container of
	-- capacity 1.0, so a blend is named by its majority component).
	local liquid = EP.ghostFluidType(ghost)
	local parts = EP.liquidParts(liquid)
	local ok, fluid = pcall(Fluid.Get, parts[1] or liquid)
	if not ok or not fluid then return release() end

	-- ROOM FOR IT, SET RATHER THAN ASSUMED.  A mirror that has never held anything keeps
	-- whatever capacity its container was born with, and EP.fillFromGroup - the only thing
	-- that ever sets one - has not run on a mirror whose group has always been empty.  A
	-- container with no room silently accepts nothing, which would leave the seat undefended
	-- and nothing to say so.  setCapacity clamps at 0.05 (FluidContainer.java:686), so this
	-- asks for the token and gets a twentieth of a litre; the mirror is emptied and re-fitted
	-- by fillFromGroup the moment it has a group again.
	if fc:getCapacity() < SEAT_TOKEN then fc:setCapacity(SEAT_TOKEN) end

	fc:addFluid(fluid, SEAT_TOKEN)
	if fc:getAmount() <= 0 then return release() end

	-- AND THE FIXTURE IS TOLD, because the engine will not ask again on its own.
	--
	-- A fixture does not search for its source on every read.  `checkExternalFluidSource`
	-- (IsoObject.java:2624) CACHES the answer and searches again only while the cached source
	-- is gone or dry - so the instant this mirror was empty, the next read cached the
	-- neighbour, and a neighbour with liquid in it is never dry.  The token then went in and
	-- won the centre square for `FindExternalWaterSource`, which is what EP.poachedBy asks,
	-- while every Fill, Drink and amount the player saw still came out of the cached
	-- neighbour until it ran out.  Measured in tools/luatest/lgep_probe_whisky.lua: a water tap
	-- over 0 L of water, one tile from a litre of whisky, poured the whole litre.  That is
	-- 吾乃利刃's "drink 0L/600L water, I can get 1L pure whisky", word for word.
	--
	-- `doFindExternalWaterSource` is the engine's own refresh: it overwrites the cache with the
	-- search's answer this instant, which with the token in place is this mirror.
	if fixture.doFindExternalWaterSource then fixture:doFindExternalWaterSource() end

	if not seated then
		data[EP.KEY_SEATED] = true
		ghost:transmitModData()
		EP.log(("the mirror at %d,%d,%d keeps its seat: the tap would otherwise have been"
			.. " served the source next door"):format(fx, fy, fz + 1))
	end

	-- The clients decide their own context menus against their own copy of the world, so a
	-- token that only exists on the authority would leave them offering the neighbour's
	-- liquid.  Sent only on the flip, not on every settle of a dry mirror.
	if not seated and ghost:getObjectIndex() >= 0 then ghost:sync() end
end

function EP.settleGhost(ghost, group, summary)
	if not EP.isAuthority() then return false end
	if not group or #group == 0 then return false end

	-- Rebuilds it after a restart, when the object came back but the component
	-- did not, and zeroes the ledger and the debt with it.  Until this runs the
	-- ghost has no capacity, so FindWaterSourceOnSquare does not accept it and the
	-- fixture reads dry - for at most the minute between one sweep and the next.
	local fc = ghost:getFluidContainer() or fitContainer(ghost)
	if not fc then return false end

	-- AWAKE AGAIN, SO BACK INTO VANILLA'S SEARCH.  The other half of the step-aside in
	-- EP.sleepGhost: a mirror that is about to hold a group's water has to be findable by
	-- FindWaterSourceOnSquare, which skips anything carrying this flag.  Cleared here rather
	-- than in a wake() of its own, because being awake is not a state this file keeps - it
	-- is having a group, and this is the one function that has one.
	if ghost.getUsesExternalWaterSource and ghost:getUsesExternalWaterSource() then
		standAside(ghost, false)
	end

	local data = ghost:getModData()
	local held = fc:getAmount()

	local ledger = data[EP.KEY_LEDGER]
	if type(ledger) ~= "number" then ledger = held end

	-- Which liquid this group is.  Asked of the FIXTURE, which is why the switch
	-- protocol writes the fixture's new choice only AFTER settling against the old
	-- group: until it does, this still answers what the mirror has been serving, and
	-- the last draw is charged to the barrels it actually came out of.
	local liquid = EP.ghostFluidType(ghost)

	local debts = readDebt(data)
	local debt = debts[liquid] or 0

	local moved = false
	local delta = held - ledger

	-- Saved and restored rather than set and cleared, because the draw below
	-- touches a dozen barrels and each one raises OnWaterAmountChange.  A plain
	-- `= false` anywhere inside would drop the guard mid-charge, and the next
	-- barrel's event would come straight back in and settle this mirror's siblings
	-- against a half-debited group.
	local wasSettling = EP.settling
	EP.settling = true

	if delta < -EPS then
		local want = -delta + debt
		local taken = EP.drawFromGroup(group, want)
		debt = want - taken
		if debt < EPS then debt = 0 end
		moved = taken > EPS
		-- Guarded rather than left to EP.log, and this is the hottest line in the
		-- mod: a wash cycle reaches it once a game minute and a drink reaches it
		-- mid-action.  EP.log checks the option, but Lua builds the argument first,
		-- so without this every draw formatted a string and made three getSquare()
		-- calls that were then thrown away.
		if EP.debugging() then
			local sq = ghost:getSquare()
			EP.log(("%.2f drawn through the mirror at %d,%d,%d across %d collector(s)%s"):format(
				-delta, sq:getX(), sq:getY(), sq:getZ(),
				#group, debt > 0 and (", %.2f unpaid"):format(debt) or ""))
		end
	elseif delta > EPS then
		-- A POUR PAYS WHAT IS OWED BEFORE IT PAYS THE BARRELS, and leaving that out took
		-- the player's water twice.
		--
		-- A debt is water that left the mirror and that no barrel could be charged for -
		-- the barrels' chunk had streamed out.  Pour that water back in before they
		-- return and, as this was written, the barrels are credited with it (or, with
		-- nobody reachable, nothing is) AND the debt survives to be collected the moment
		-- they come back.  Traced: a group of 100 litres, unreachable; draw 30, so the
		-- mirror owes 30; pour the same 30 back; the chunk returns and the debt takes 30
		-- off the barrels.  Thirty litres drawn, thirty litres returned, thirty litres
		-- gone - and nothing anywhere says so.
		--
		-- With the group reachable the two orderings agree exactly (credit the barrels
		-- +delta then debit them -debt, or credit neither), so this changes only the case
		-- that was wrong.
		local credit = math.min(debt, delta)
		if credit > EPS then
			debt = debt - credit
			if debt < EPS then debt = 0 end
		else
			credit = 0
		end

		local rest = delta - credit
		local given = (rest > EPS) and EP.pourIntoGroup(group, fc, rest) or 0
		moved = given > EPS
		if EP.debugging() then
			local sq = ghost:getSquare()
			EP.log(("%.2f poured back through the mirror at %d,%d,%d%s"):format(
				given, sq:getX(), sq:getY(), sq:getZ(),
				credit > 0 and (", %.2f of it against what was owed"):format(credit) or ""))
		end
	elseif debt > EPS then
		-- Nothing was drawn this time, but something still owes.  A member's chunk
		-- coming back is exactly the moment this can finally be paid, and no event
		-- announces that - so every settle tries.
		local taken = EP.drawFromGroup(group, debt)
		debt = debt - taken
		if debt < EPS then debt = 0 end
		moved = taken > EPS
	end

	-- ONE pass over the members, not three.
	--
	-- This used to be EP.groupTotals here, EP.groupTotals again inside fillFromGroup, and
	-- fillFromGroup's own loop hunting the fluid and the container name - three walks, each
	-- a getFluidContainer and a getAmount per member, and on a group of six hundred barrels
	-- that was most of what a settle cost.
	--
	-- THE SUMMARY IS THROWN AWAY IF ANYTHING MOVED, and that is not caution, it is
	-- correctness: drawFromGroup and pourIntoGroup change the very amounts it recorded, so
	-- one taken before them describes the group as it was rather than as it is.  A
	-- maintenance settle - the case this exists for, and the one that runs on every mirror
	-- every lap - moves nothing and keeps it.  `caller` is the walk's summary where the
	-- maintenance cursor built one across ticks; nil everywhere else.
	if moved then summary = nil end
	summary = summary or EP.summariseGroup(group)

	local total = summary.total
	EP.fillFromGroup(fc, group, total - debt, summary)
	data[EP.KEY_LEDGER] = fc:getAmount()

	debts[liquid] = (debt > EPS) and debt or nil
	writeDebt(data, debts)

	-- What this mirror is standing for, kept where ghostsFed can read it without
	-- resolving a fixture per mirror per drink.
	--
	-- Written even when it is water, unlike every other key added for per-liquid.
	-- The "write nothing" rule is about objects the PLAYER owns - a barrel, a
	-- fixture - where a stray key has to survive a rollback and an uninstall.  A
	-- mirror is ours, it already carries six keys, and it is rebuilt from nothing
	-- whenever it is missing.  Writing the liquid out plainly is what lets ghostsFed
	-- tell "this is a water tap" from "this mirror has never been settled", which is
	-- the difference between the narrowing doing something and doing nothing.
	--
	-- AND A CLIENT NEVER GOT IT.  This was written on every settle and transmitted on none,
	-- so a client's copy of a mirror carried no liquid at all - `EP.ghostFluidType` there
	-- fell through to `EP.FLUID_DEFAULT`, which is water, whenever the fixture underneath
	-- could not be resolved from the client's own cell.  That is the chunk edge, and it is
	-- the same class as memory/washer-plumb-flag-is-dropped-on-the-wire.md.
	--
	-- Costs nothing in the steady state: it is sent when it CHANGES, and a mirror's liquid
	-- changes when somebody points the fixture at another one, not once per drink.
	local sendData = false
	if data[EP.KEY_FLUID] ~= liquid then
		data[EP.KEY_FLUID] = liquid
		sendData = true
	end

	-- Awake by definition: a group with something in it reached this line.  The
	-- flag is written for the debug dump and for clients, and is never read back as
	-- an input - see the note on EP.sleepGhost.
	local wasDormant = data[EP.KEY_DORMANT] == true
	if wasDormant then
		data[EP.KEY_DORMANT] = nil
		sendData = true
	end

	-- One packet for both, rather than one each: they change together on the settle that
	-- wakes a mirror up.
	if sendData then ghost:transmitModData() end

	EP.settling = wasSettling

	-- Without this a mirror is only ever RIGHT on the server.
	--
	-- The add packet does carry the container - IsoObject.save serialises components
	-- whenever hasComponents(), and writeToRemoteBuffer is that same save, so a
	-- client meets a new mirror already able to answer the engine's four questions.
	-- (This used to say the opposite, and the sentence it rested on was about
	-- GameEntityManager rather than about IsoObject; see the note on fitContainer.)
	--
	-- What the add packet cannot carry is every change afterwards.  EP.fillFromGroup
	-- writes to the component, and the component is not what the network watches -
	-- deliberately, and it must stay that way, because rebuilding a mirror through
	-- the IsoObject methods instead would raise OnWaterAmountChange and recurse
	-- straight back through the fan-out below.  So each settle moves the server's
	-- copy and nothing else, and a client would go on reading the level the mirror
	-- had when it arrived: the tap would show a number that never changed.
	--
	-- sync() is the channel that carries it. syncIsoObjectSend writes the container,
	-- and syncFluidContainerReceive on the far side *creates the component when the
	-- object has not got one* - so it is also the repair for a mirror that reached a
	-- client without one, and nothing has to be sent by hand either way.
	--
	-- It matters twice over, because whether the Plumb option and the drink option
	-- appear at all is decided on the client, against the client's copy of the
	-- world.
	--
	-- Only sync an object the square actually holds.  IsoObject.syncIsoObject
	-- refuses and logs "IsoThumpable not found on square" when getObjectIndex() is
	-- -1, which is every call made before the add has landed - at spawn, and again
	-- on the way out in removeGhost.  The log line was harmless but it was also
	-- true: those syncs went nowhere.
	--
	-- Only when something actually changed, too.  Every mirror is now re-settled
	-- whenever any barrel it can see is charged, so a house with six taps re-settles
	-- six times per drink; without this that would be six packets each time, on top
	-- of one per mirror per minute in a base where nothing is happening at all.
	if ghost:getObjectIndex() >= 0 and math.abs(fc:getAmount() - held) > EPS then
		ghost:sync()
	end

	-- Every other mirror that can see any of the barrels just charged is now wrong
	-- by what came out of them, and nothing will tell them: those barrels' own
	-- OnWaterAmountChange was raised inside the guard above and deliberately
	-- ignored, because it was this mod that moved the water.
	--
	-- Left alone that is not a display fault, it is duplicated water.  Two taps
	-- over one barrel, one player drinks 60 at the first; the second tap's mirror
	-- still reads full, so it pours what it believes it has, and the charge is
	-- clamped to what the barrel actually had left while the bottle keeps the lot.
	-- Simulated against the engine's own arithmetic: 160 poured out of a barrel
	-- that only lost 100.
	--
	-- The whole group is handed over, not one barrel of it: a proportional draw
	-- touches every member, so every member's readers are stale.
	--
	-- The sibling settle cannot recurse.  Nobody drew through those mirrors, so
	-- their delta is zero, so they charge nothing and raise nothing.
	if moved and EP.afterGroupCharged then
		EP.afterGroupCharged(group, ghost)
	end

	-- LAST, AND AFTER THE LEDGER.  A settle that leaves the mirror empty - the group is
	-- still there but every barrel in it is dry - is as poachable as a sleeping one, and
	-- the token has to go in after `data[EP.KEY_LEDGER]` was written or the next settle
	-- would read it as water that arrived from somewhere.  It is under EP.EPS, so it
	-- changes no arithmetic either way; see EP.defendSeat.
	EP.defendSeat(ghost)

	return moved
end

--- There is deliberately no repointGhost any more.
---
--- Re-aiming was the central act of the old design and it does not exist here.  A
--- mirror was a copy of one barrel, so building a barrel, draining one, excluding
--- one or losing a pump all meant working out which barrel it should be a copy of
--- NOW and moving it - and every one of those moves had to settle the old barrel
--- first or silently bill the new one for last minute's drinking.  A mirror is a
--- copy of whatever its fixture can reach, worked out fresh on every settle, so
--- the answer changes by itself and there is nothing to move.

--- Take a client's own stand-in off its square without telling anybody.
---
--- transmitRemoveItemFromSquare would send a RemoveItemFromSquare packet asking
--- the server to delete an object it has never heard of, because a stand-in is
--- built locally and never transmitted.  RemoveTileObject is the local half on its
--- own, which is all that is wanted.
function EP.removeLocalGhost(ghost)
	local square = ghost:getSquare()
	if not square then return end

	local fc = ghost:getFluidContainer()
	if fc then fc:Empty() end
	square:RemoveTileObject(ghost)
end

--- Put a mirror to sleep instead of tearing it down.
---
--- Used when nothing can supply this fixture JUST NOW - the generator stopped, so the
--- only collector in range lost its pump; the tap is pointed at a liquid the building
--- has none of; the barrel's chunk streamed out.  None of those mean the plumbing was
--- undone, and destroying the object would mean building and transmitting a new one the
--- moment the generator restarts.  A player cycling a generator would churn an object per
--- fixture per cycle.
---
--- SLEEPING IS FOR A SUPPLY THAT IS IDLE, AND THAT IS THE WHOLE OF WHEN IT IS RIGHT.  A
--- building whose barrels have all been carried away, or all been disconnected with a
--- wrench, is not idle - there is nothing left to come back - and a mirror standing over
--- one is a saved object with no purpose.  Those are RETIRED instead, and only the
--- maintenance cursor does it, because only the walk it drives knows how much of the
--- building is plumbed in as against how much of it can serve THIS tap today.  See
--- retireIfUnsupplied in the server file.
---
--- No caller of this has to know that.  The two handlers that may not remove anything at
--- all - OnWaterAmountChange and OnObjectAboutToBeRemoved, both raised from inside the
--- engine's own iteration over a square - go on sleeping a mirror whose supply has gone,
--- and the cursor takes it away a lap or two later if it has gone for good.
---
--- So the copy is emptied - it is only ever a copy, the real water is still in the
--- barrels - and the mirror stays where it is, holding its fixture address,
--- contributing nothing.  It reads as a collector with no water in it, which is
--- exactly what the situation is, and vanilla treats it accordingly: Plumb still
--- offered, nothing to drink.
---
--- THE FLAG IS NOT A GATE, and that is a correction rather than a detail.  It used
--- to be, and the consequences were ugly enough to be worth writing down.  The old
--- code opened with `if data[KEY_DORMANT] then return end` and the flag was cleared
--- in exactly one place, repointGhost, which only ran when a DIFFERENT barrel was
--- chosen.  So: generator stops, mirror sleeps; generator restarts, the same barrel
--- is chosen, the settle path runs instead of the repoint path, the mirror refills
--- and stays flagged dormant for ever.  From then on the sweep skipped it - no
--- rain, no re-check - and, worse, the next power cut hit this early-out and did
--- NOT empty it, so the tap went on pouring out of a barrel that had stopped
--- pumping.
---
--- Dormancy is derived now.  It means "the group is empty", it is recomputed on
--- every settle, and nothing reads the flag back: EP.settleGhost clears it whenever
--- a group turns up, this sets it whenever one does not, and both are safe to run
--- as often as anything likes.  The flag is written only so the debug dump and
--- clients can see the state.  This also means every mirror left dormant in an old
--- save wakes up by itself on the first sweep after the update.
---
--- Anything drawn but not yet charged is carried as debt rather than forgiven.  A
--- group can go empty with a drink still unsettled - the last barrel's chunk
--- unloaded mid-draw - and that water is owed by the building, not by nobody.  It
--- is charged the moment a group comes back.
function EP.sleepGhost(ghost, spokenFor)
	if not EP.isAuthority() then return end

	local data = ghost:getModData()
	local fc = ghost:getFluidContainer()
	local held = fc and fc:getAmount() or 0

	local ledger = data[EP.KEY_LEDGER]
	if type(ledger) ~= "number" then ledger = held end

	-- Banked against the liquid the mirror was serving, not against water.  This is
	-- also the second half of the switch protocol - settle against the old group,
	-- then sleep - so getting the liquid wrong here would tag a whiskey debt as
	-- water and pay it out of the drinking supply on the next settle.
	local liquid = EP.ghostFluidType(ghost)
	local debts = readDebt(data)
	local debt = debts[liquid] or 0

	-- NO CONTAINER, NO DEBT.  `fitContainer` states the rule this has to keep: the ledger and
	-- the debt are zeroed with the container, "always both or neither ... the container and
	-- the books start again together or not at all".  This read a MISSING container as
	-- `held = 0` and banked last session's whole ledger as a debt - a hundred litres owed
	-- against water nobody drank, written into the save.
	--
	-- Measured: a mirror carrying KEY_LEDGER 100 with no component, one sleepGhost, and
	-- LGEPDebt comes out 100.  It happened to be cancelled by the next settle, because
	-- settleGhost calls fitContainer and that zeroes both - so the damage needed a mirror
	-- whose component came back PRESENT and EMPTY, where fitContainer never runs and the
	-- delta charges the barrels the lot.
	if fc and held < ledger - EPS then debt = debt + (ledger - held) end

	-- WHETHER THIS MIRROR KEEPS THE SEAT, WHICH IS THE ONE DECISION SLEEPING MAKES.
	--
	-- A mirror stands at index 0 of the square above its fixture, and
	-- FindWaterSourceOnSquare returns the FIRST object on a square that answers its four
	-- questions and stops (IsoObject.java:2449-2463).  It has no opinion about fluid at
	-- all.  So a mirror holds the seat whether or not it has anything in it, and whatever
	-- is standing behind it - very often a real rain barrel directly above the sink - is
	-- never looked at.
	--
	-- BLOCKING IS USUALLY THE POINT, and this is where that was got backwards once.  A
	-- barrel joins a building's supply when somebody plumbs it in, and a barrel nobody
	-- plumbed in - or one they took a wrench to and disconnected - is meant to be unused.
	-- Letting the sink under it draw from it anyway would make Disconnect do nothing at
	-- all, and take away the choice the plumb-in act exists to give.  So a house WITH
	-- plumbing keeps the seat, dry or not, and the barrels outside that plumbing stay out.
	--
	-- WHAT IS NOT THE POINT is sitting on the seat with nothing to put in it and nothing to
	-- defend.  If no barrel in this fixture's scope is both plumbed in AND spoken for -
	-- holding something, or empty and kept for a liquid - then there is no house supply
	-- here in any meaningful sense, and a mirror in front of a real barrel is doing nothing
	-- but making the game worse than it is without this mod.  EP.isIncluded's own note says
	-- as much: an unplumbed barrel is still a rain barrel, and vanilla will still plumb a
	-- fixture to one in the nine squares above it - "that branch is engine code and not
	-- ours to veto".
	--
	-- `spokenFor` is that count, from the walk that has just finished.  nil means the caller
	-- did not walk and does not know, and the flag is then left exactly as it is rather than
	-- guessed at - a mirror does not change what it is doing because something asked it to
	-- sleep from a path with no answer.
	--
	-- AND ONLY WHEN THERE IS SOMETHING TO STEP ASIDE FOR.  A dormant mirror with an empty
	-- square behind it is still the answer to FindExternalWaterSource, and that answer is
	-- what keeps vanilla's Plumb row on the fixture (doWaterPipeMenu is gated on it).
	-- Standing aside there would take the row away from a fixture whose owner has plumbed
	-- barrels in and is waiting for rain, and buy nothing.
	--
	-- usesExternalWaterSource is the way out, and it is the THIRD of those four questions:
	-- `!object.getUsesExternalWaterSource()`.  Capacity cannot be used - setCapacity clamps
	-- at 0.05 (FluidContainer.java:685), so a zeroed container is still > 0 and still wins.
	--
	-- Symmetrical, so it reverses on its own: plumb a barrel back in, or let it rain into
	-- one, and the next pass puts the mirror back in front with no separate bookkeeping.
	local aside = nil
	if spokenFor ~= nil and ghost.getUsesExternalWaterSource and ghost.setUsesExternalWaterSource then
		local want = (spokenFor == false) and EP.sourceOnSquare(ghost:getSquare()) ~= nil
		if want ~= (ghost:getUsesExternalWaterSource() == true) then aside = want end
	end

	local wasDormant = data[EP.KEY_DORMANT] == true
	local changed = (not wasDormant) or held > EPS or aside ~= nil

	if fc then fc:Empty() end
	if aside ~= nil then standAside(ghost, aside) end
	data[EP.KEY_LEDGER] = 0
	debts[liquid] = (debt > EPS) and debt or nil
	writeDebt(data, debts)
	data[EP.KEY_DORMANT] = true

	if changed then
		ghost:transmitModData()
		if ghost:getObjectIndex() >= 0 then ghost:sync() end
		EP.log(("no supply in range; the mirror sleeps rather than being torn down%s"):format(
			debt > EPS and (" (%.2f of %s still owed)"):format(debt, liquid) or ""))
	end

	-- After the step-aside, which decides whether there is a seat worth keeping at all.
	EP.defendSeat(ghost)
end

function EP.isDormant(ghost)
	return ghost:getModData()[EP.KEY_DORMANT] == true
end

--- Keep one mirror honest: settle it against its group, or put it to sleep.
---
--- There is no "the collector is gone, remove the mirror" case any more, and that
--- is the collective paying for itself.  A mirror stood for one barrel before, so
--- a dismantled barrel left it standing for nothing and it had to be destroyed and
--- a new one built somewhere else.  A mirror stands for whatever its fixture can
--- reach now, so a dismantled barrel simply drops out of the sum; the group either
--- still has something in it, in which case nothing happened worth reacting to, or
--- it is empty, in which case the mirror sleeps and wakes again by itself the day
--- somebody builds another barrel.
---
--- SO THIS NEVER REMOVES ANYTHING, and it is the only settle path in the mod that is
--- reached from handlers which may not.  Removal is the maintenance cursor's, in two
--- cases and no others: the fixture has gone, and the building has no plumbing left at
--- all.  Both are decided in the server file - the first in settleMirrorSquare, the
--- second in retireIfUnsupplied - and neither of them can be decided from here, because
--- an empty group means "nothing can serve this tap today" and says nothing whatever
--- about whether the plumbing is still there.
---
--- Unloaded members need no special case either.  They are simply not in the group
--- this minute, so the sum is smaller and the tap reads lower; when the chunk comes
--- back they are in it again and the sum is whole.  The debt is what keeps that
--- honest across a draw that landed in between.
--- `group` and `summary` are the maintenance cursor's, built a few members per tick across
--- however many ticks it took.  Everything else calls this with neither and gets the group
--- resolved here, atomically, exactly as before.
--- `spokenFor` is the walk's count of plumbed-in, spoken-for collectors in this fixture's
--- scope, and it decides whether a sleeping mirror keeps the seat; see EP.sleepGhost.  The
--- maintenance cursor has it from the walk it has just finished.  A caller that has not
--- walked leaves it nil, and the mirror is left doing whatever it was doing.
function EP.settleOrSleep(ghost, group, summary, spokenFor)
	group = group or EP.groupForGhost(ghost)
	if not group or #group == 0 then
		EP.sleepGhost(ghost, spokenFor)
		return
	end
	EP.settleGhost(ghost, group, summary)
end

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
--
-- The `else` is not defensive tidiness, it is the direction the fault actually came in:
-- the reported install had the NEW server file and an OLD shared one, so the core is the
-- half that has no checkBuild in it and a bare `if EP.checkBuild then` would have said
-- nothing in exactly the case this exists for.  Printed directly there because EP.logFault
-- is in the same file that is missing.
if EP.checkBuild then
	EP.checkBuild("LGEPGhost.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPGhost.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
