--
-- Extended Plumbing - the client's half.
--
-- Two jobs, both about a ghost being an object that really is there rather than
-- a local trick: make sure it is not drawn, and make sure it is not offered.
-- No decisions and no water; those are the server's, and in singleplayer this
-- file and the server's both load and the guards in each keep them apart.
--

require "LGExtendedPlumbing/LGEPGhost"

--- The timed action the collector menu queues.
---
--- Required rather than left to load order.  LoadDirBase walks a mod's client/ folder
--- alphabetically, so LGEPClient.lua is executed BEFORE LGEPPlumbAction.lua and
--- LGEPPlumbCollector would be nil at the moment the menu wants it - which is a nil call
--- inside OnFillWorldObjectContextMenu, swallowed by that event's pcall, showing up as an
--- option that quietly does nothing.  Requiring an already-loaded file is a no-op, so the
--- later folder walk costs nothing when it reaches the same file again.
require "LGExtendedPlumbing/LGEPPlumbAction"

-- Named because this file indexes ISWorldObjectContextMenu at file scope below, and a
-- file-scope throw costs everything after it in the same file: the wrapper would not be
-- installed, and neither would the two menu events.  LoadDirBase runs every vanilla
-- client/ file before any mod's, so the table is there - but that is an ordering this
-- file does not control, and the guard is one line.  Requiring an already-loaded file is
-- a no-op (RunLuaInternal returns early on `loaded.contains`), so it costs nothing.
--
-- Every other capture site in these mods already does this; this was the one that did not.
require "ISUI/ISWorldObjectContextMenu"

local EP = LGEP

--------------------------------------------------------------------------------
-- not drawn
--------------------------------------------------------------------------------

--- doRender is a private field with no save format and no wire format: it is not
--- written by IsoObject.save and not carried by any object-change packet.  So a
--- ghost reaching a client - through the AddItemToMapPacket when the server makes
--- one, or straight out of the chunk when it loads - arrives with doRender true
--- and would be drawn as a barrel standing in mid-air.
---
--- What does travel is modData, which is what says it is a ghost at all, so the
--- client can recognise one and turn it off for itself.  Both events fire
--- synchronously inside the code that put the object on the square, well before
--- anything renders.
local function hide(object)
	if not EP.isGhost(object) then return end
	EP.dressGhost(object)

	-- A real one has turned up, so this machine's stand-in has done its job.
	--
	-- Leaving it would mean two collectors on one square, and the empty one could
	-- win: FindExternalWaterSource prefers a source with fluid but falls back to an
	-- empty one, so the moment the barrel ran dry the stale stand-in could start
	-- answering for it.
	if object:getModData()[EP.KEY_LOCAL] then return end

	local data = object:getModData()
	local square = object:getSquare()
	if not square then return end

	for _, other in ipairs(EP.ghostsOnSquare(square)) do
		local od = other:getModData()
		if other ~= object and od[EP.KEY_LOCAL]
			and od[EP.KEY_FIX_X] == data[EP.KEY_FIX_X]
			and od[EP.KEY_FIX_Y] == data[EP.KEY_FIX_Y]
			and od[EP.KEY_FIX_Z] == data[EP.KEY_FIX_Z] then
			EP.removeLocalGhost(other)
			EP.log("the server's ghost arrived; dropping the local stand-in")
		end
	end
end

--- Guarded, and reported once, because of where this runs.  LoadGridsquare fires for
--- every square of every chunk that opens, so an error here is not one error - it is
--- one per square for the rest of the session, each one a stack trace through
--- ExceptionLogger, and the log it buries is the one somebody needs to read.  Event
--- callbacks are individually caught by the engine (Event.java), so a throw could never
--- have harmed another mod; it could only drown the log and cost frames.
---
--- The reported-once flag this used to keep of its own is now EP.logFault's, keyed on the
--- site - so it still reports once with Debug off, and reports EVERY failure with Debug on,
--- which is the setting somebody hunting this fault would have turned on.
--- ONE pcall PER SQUARE, NOT ONE PER OBJECT -- which is the fix this file's own note above
--- designed and declined to make without a number.  The number is in now: a pcall is
--- 0.25 us and a square carries 1.87 objects, so this is 0.47 us of a 21.3 us square.  Small,
--- free, and the isolation it gives up is the difference between "the rest of this square's
--- objects are skipped" and "this one object is skipped" -- on a path whose only failure
--- mode is a mirror that was not hidden, which the next chunk load fixes.
---
--- Both requirements of the note above still hold: an error cannot repeat per square for the
--- rest of the session (EP.logFault latches on the site), and it cannot escape into the
--- engine.
---
--- NAMED, not a closure.  `pcall(function() ... end)` would allocate one per square, which
--- is more than the per-object pcalls it replaced -- the allocation being removed, put back
--- with a bow on it.
local function hideAll(objects)
	-- [Malcolm_Perf] The test EP.isGhost asks first, asked here before the call: an object whose
	-- sprite has a name other than ours is never a hidden water store, so it is passed over
	-- without a function call.  Nameless objects and ours go to hide() exactly as before.  The
	-- single pcall stays around the whole square (hideSquareQuietly).  No network traffic.
	local ghostName = EP.GHOST_SPRITE
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		local name = object and object.getSpriteName and object:getSpriteName() or nil
		if name == nil or name == ghostName then
			hide(object)
		end
	end
end

--- The streaming path: a whole square at once.
local function hideSquareQuietly(objects)
	local ok, err = pcall(hideAll, objects)
	if not ok then
		EP.logFault("client-hide-mirror", "ERROR hiding a mirror: " .. tostring(err))
	end
end

--- The arrival path: ONE object, because OnObjectAdded hands over one.
---
--- A separate function rather than a second shape for the one above, and a DISTINCT fault
--- site, which is the rule this file states about itself: *"`site` must be distinct per call
--- site.  Two handlers sharing one key means the second fault to happen is never reported at
--- all"*.  They shared `client-hide-mirror` before this; they should not have.
local function hideOneQuietly(object)
	local ok, err = pcall(hide, object)
	if not ok then
		EP.logFault("client-hide-added", "ERROR hiding a mirror as it arrived: " .. tostring(err))
	end
end

--- THE CLIENT'S ONLY PER-SQUARE COST, AND IT IS NOW THE UNPRICED ONE.
---
--- Measured 2026-08-16 (plans/rewrite-scoping-2026-08-16.md).  The server half costs a
--- client nothing at all - `if isClient() then return end` at the top of LGEPPlumbing.lua
--- sees to that, and streaming nine two-storey houses through this harness confirms it:
--- 13,122 squares, zero grid lookups, zero object scans from that file.  What is left is
--- this handler, and what it does is one `getObjects()` per square plus **one pcall per
--- object standing on it**.
---
--- The count is exact and the PRICE is not, because a pcall is pure Lua: it allocates and
--- it crosses into no Java, so no operation counter in this harness can see it - the same
--- blindness that hid LGEP's empty-world cursor at 2.7 laps a tick and LGEE's registration
--- queue.  Nor can it be timed here: `lgep_stub` has no getTimeInMillis at all, and the
--- one `lgep_spec_rate` installs is a counter it drives by hand, not a clock.
---
--- So it is bracketed for the profiler instead, and the live server can answer what four
--- rounds of synthetic benchmarking structurally could not.  If `client chunk load` comes
--- back cheap, the pcall stays exactly where it is; if it does not, the fix already has a
--- shape - hoist the pcall out of the object loop, which changes the isolation granularity
--- from one object to one square and still satisfies everything the note above actually
--- needs (an error must not repeat per square for the rest of the session, and must not
--- escape into the engine).
Events.LoadGridsquare.Add(function(square)
	if not square then return end

	EP.markStart("client chunk load")
	hideSquareQuietly(square:getObjects())
	EP.markEnd("client chunk load")
end)

--------------------------------------------------------------------------------
-- not offered
--------------------------------------------------------------------------------

--- A ghost cannot be clicked - IsoObject.render skips
--- updateRenderInfoForObjectPicker along with everything else when doRender is
--- false, so it is never the object under the mouse.  But the world context menu
--- is built from the square rather than from the pick: ISWorldObjectContextMenu
--- gathers everything standing there and hands each one to
--- ISWorldObjectContextMenuLogic.fetch, which sorts by what an object *is* - and
--- a ghost has a fluid container, so fetch would file it under storeWater and
--- offer the player a drink from thin air.
---
--- It only comes up where a player can stand on the floor a ghost is on, which
--- means upstairs in a two-storey building, but it comes up.
---
--- Filtering the list on the way in rather than editing the menu on the way out:
--- one place, before anything has been decided from it, and nothing downstream
--- has to know ghosts exist.
--- CHECKED, because the cost of being wrong here is the ENTIRE world context menu dying for
--- every mod in the game, which is the one outcome the rest of this file is arranged against.
--- `require`ing the vanilla file above means it is present today; a future build that renames
--- it must cost a missing Plumb row and not a player who cannot right-click anything.
local vanillaCreateMenu = type(ISWorldObjectContextMenu.createMenu) == "function"
	and ISWorldObjectContextMenu.createMenu or nil

--- DECLARED HERE, DEFINED FURTHER DOWN, because prepareMenu and collectorSubMenu both need
--- them and both run before the menu's own helpers are reached in file order.  A `local
--- function` further down would be a DIFFERENT local and these would be nil at the call -
--- memory/local-function-called-from-above-is-a-nil-call, which this mod has been bitten by.
local objectsInMenu
local fluidBlockEntries

--------------------------------------------------------------------------------
-- the right-click trigger
--------------------------------------------------------------------------------

--- Ask the server to service a fixture.
---
--- In singleplayer the server half of this mod is loaded in the same process, so
--- it is called outright and there is no round trip at all.
--- `wide` is for "something appeared", not "somebody looked".  A right-click asks
--- about one fixture; a collector being placed changes the answer for a building.
local function askServer(x, y, z, wide)
	if EP.isNetworkClient() then
		sendClientCommand(EP.COMMAND_MODULE, EP.COMMAND_SERVICE,
			{ x = x, y = y, z = z, wide = wide == true })
	elseif EP.serviceAround then
		EP.serviceAround(x, y, z, wide)
	end
end

--------------------------------------------------------------------------------
-- telling the server about a draw it cannot see
--------------------------------------------------------------------------------

--- REPORT WATER TAKEN OUT OF A PLUMBED FIXTURE.
---
--- On a multiplayer client the engine does not move the water and does not raise
--- OnWaterAmountChange - IsoObject.useFluid guards both with
--- `GameServer.server || !GameClient.client` - and yet it RETURNS the amount, so the timed
--- action carries on believing it was served.  The player gets their water and no barrel
--- pays for it, which is free water rather than merely late water, and it is invisible
--- because everything downstream behaves normally.  lgep_repro_mpdraw.lua is that bug,
--- measured: told 60.00, barrels moved 0.00.
---
--- Only sent from a NETWORK CLIENT.  In singleplayer the guard opens, the engine does all
--- of this itself, and reporting would charge the group a second time.
---
--- Only sent for a fixture this mod is actually feeding, which is what the isGhost test is:
--- a sink over a real barrel, or a mains tap, is vanilla's own water and none of our
--- business.
local function reportDraw(fixture, amount)
	if not EP.isNetworkClient() then return end
	if not fixture or type(amount) ~= "number" or amount <= 0 then return end
	if not EP.getOption("Enabled") then return end

	local source = fixture.FindExternalWaterSource and fixture:FindExternalWaterSource()
	if not source or not EP.isGhost(source) then return end

	local sq = fixture:getSquare()
	if not sq then return end

	sendClientCommand(EP.COMMAND_MODULE, EP.COMMAND_DRAW,
		{ x = sq:getX(), y = sq:getY(), z = sq:getZ(), amount = amount })
end

--- Wrap one vanilla action so a draw through it is reported.
---
--- WRAPPED RATHER THAN REPLACED, and the original is always called first: this must never
--- be the reason an action fails.  If the report throws, the player has still washed.
---
--- `amountOf` is given the action and whatever arguments the method got, and answers how
--- much water left the fixture.  It is a per-action question because vanilla computes the
--- amount as a LOCAL in each one - there is no shared field to read - so the seam has to be
--- chosen per action, at a point where the number is actually in hand.
--- ARGUMENTS ARE NAMED RATHER THAN VARARG, and that is Kahlua rather than taste: `...` is
--- illegal inside a nested closure, so `function(self, ...)` wrapping a pcall'd
--- `function() ... end` does not compile at all.  Three positional arguments cover every
--- seam wrapped here and leave room for the next one; anything beyond them would be dropped
--- silently, so the wrapper passes them on explicitly and the call sites stay honest.
local function wrapDraw(class, method, fixtureOf, amountOf)
	if not class or type(class[method]) ~= "function" then return end

	local original = class[method]
	class[method] = function(self, a, b, c)
		local result = original(self, a, b, c)

		local ok, err = pcall(function()
			local fixture = fixtureOf(self)
			if fixture then reportDraw(fixture, amountOf(self, a, b, c)) end
		end)
		if not ok then
			EP.logFault("client-report-draw", "ERROR reporting a draw: " .. tostring(err))
		end

		return result
	end
end

--- ISTakeWaterAction is the one that matters most and the one with the cleanest seam.
---
--- It is what "Take water" and drinking from a source both run, so it is the path the
--- reported fault was seen through.  transferFluid(_amount) takes the amount as a real Lua
--- PARAMETER rather than computing it into a local, which is why the wrap can be exact here
--- and has to be chosen more carefully elsewhere.
Events.OnGameStart.Add(function()
	if not EP.isNetworkClient() then return end

	local ok, err = pcall(function()
		-- THE AMOUNT IS CAPPED AT WHAT THE CONTAINER COULD ACTUALLY TAKE, and without that
		-- this reports the same draw over and over.
		--
		-- ISTakeWaterAction:updateUse works out how much is still owed by reading how much
		-- the ITEM has gained: `usedSoFar = currentUsedAmount - self.startUsedAmount`, where
		-- currentUsedAmount is the item's own fluid amount.  On a client the transfer never
		-- happens - transferFluidTo carries the same GameServer.server guard useFluid does -
		-- so the item never gains anything, usedSoFar stays nought, and the full outstanding
		-- amount is passed here on EVERY update tick of the action.  Reporting each one
		-- would have charged the barrels several times over for one bottle: an over-charge,
		-- which destroys a player's water rather than merely mis-drawing it.
		--
		-- So the running total is kept on the action and clipped to the container's free
		-- capacity, which is the most a fill can ever move.
		--
		-- DRINKING NEEDS NO CAP and correctly gets none: with no item the action measures
		-- progress from THIRST, which does fall on a client, so the amount it asks for
		-- shrinks by itself and the sum is bounded by the drink.
		wrapDraw(ISTakeWaterAction, "transferFluid",
			function(self) return self.waterObject end,
			function(self, amount)
				if type(amount) ~= "number" or amount <= 0 then return 0 end

				local fc = self.item and self.item.getFluidContainer
					and self.item:getFluidContainer() or nil
				if not fc then return amount end

				-- AND BOUNDED BY WHAT THE TAP HAS, not only by what the vessel could
				-- take.  The running total alone is the vessel's capacity, so a 10 L
				-- bucket held at a tap standing over 2 L of cola would report up to ten
				-- litres for a supply that has two.  The server clamps a draw to what the
				-- mirror holds before charging it, so this was never an over-charge -- but
				-- an amount that is wrong before it goes on the wire is wrong in the log
				-- too, and the clamp is the last line of defence rather than the first.
				local held = self.waterObject and self.waterObject.getFluidAmount
					and self.waterObject:getFluidAmount() or nil

				local sent = self.__lgepSent or 0
				local room = math.max(0, fc:getFreeCapacity() - sent)
				local send = math.min(amount, room)
				if held then send = math.min(send, math.max(0, held)) end
				self.__lgepSent = sent + send
				return send
			end)

		-- ISCleanBandage IS NOT REPORTED, AND REPORTING IT CHARGED THE BARRELS TWICE.
		--
		-- This used to wrap its `perform`.  `ISCleanBandage:perform()` does no fluid work at
		-- all - it stops a sound, clears the job delta and calls the base - and the litre is
		-- spent in `complete()` (`ISCleanBandage.lua:53-58`, `self.waterObject:useFluid(1)`).
		--
		-- `complete` is the half a client never runs (`LuaTimedActionNew.complete` is wrapped in
		-- `!GameClient.client`) and the half the SERVER does run: the action defines a `complete`,
		-- so `useCustomRemoteTimedActionSync` stays false, a NetTimedAction is created, and the
		-- server rebuilds the action and calls `complete` itself.  `useFluid` there delegates
		-- through the fixture to the mirror and charges the group the normal way.
		--
		-- So the client was reporting a draw it had not made, on top of one the server had
		-- already performed: two litres off the barrels for one cleaned bandage, in the
		-- over-charge direction this file calls worse than the bug it is fixing.
		--
		-- ISTakeWaterAction is different and still wrapped: its transfer runs from `update` on
		-- the client, where `transferFluidTo` is a no-op, so without the report the water comes
		-- from nowhere.  See EP.COMMAND_DRAW and lgep_repro_mpdraw.
	end)
	if not ok then
		EP.logFault("client-install-reporters", "ERROR installing the draw reporters: " .. tostring(err))
	end
end)

--- Whether vanilla offers Plumb is decided on the *client*: fetch runs inside
--- createMenu, at line 186 of ISWorldObjectContextMenu, and calls
--- FindExternalWaterSource against this machine's own copy of the world.  So on a
--- dedicated server it is not enough for the ghost to exist - it has to exist
--- here, and it has to be here before the menu is built.
---
--- A round trip cannot do that.  The command sent above will not come back for a
--- tick or more, by which time the menu is already open and wrong, and the option
--- would only appear on a second right-click.
---
--- So the client puts up its own stand-in first.  It is marked local, is never
--- transmitted, and holds no authority over anything: all it does is answer the
--- four questions FindWaterSourceOnSquare asks, which is enough to make the menu
--- correct on the first click.  The server's real ghost arrives a moment later and
--- displaces it - see hide() below - and from then on the water is the server's
--- business as it always was.
---
--- Nothing is charged here.  spawnGhost's accounting all sits behind
--- EP.isAuthority(), which a multiplayer client is not.
---
--- And nothing about a stand-in reaches the server, which is worth writing down
--- because two lines of it look like they would.  Both were read and both are shut:
---
---   * transmitAddObjectToSquare adds and then sends, but the send is inside
---     `if (GameServer.server)` - a client's call is the plain AddTileObject and
---     stops there.  (This is also why removeLocalGhost must use RemoveTileObject:
---     the REMOVE half has no such guard and would ask the server to delete an
---     object it has never heard of.)
---   * AddTileObject calls addToWorld, which reaches GameEntityManager.RegisterEntity
---     because the stand-in is carrying a FluidContainer by then, and the client
---     branch of that ends in sendRequestSyncGameEntity().  That is a no-op without a
---     MetaTag component, which a stand-in has not got, so no packet is written.
--- One box walk per fixture per right-click, shared by everything that needs one.
---
--- Per-liquid asks the same box two different questions - what this fixture can
--- draw right now, and which liquids it could be switched to - and they are asked
--- from two different places: the stand-in from the createMenu wrapper, the menu
--- from OnFillWorldObjectContextMenu.  Walking twice would double the one cost on
--- this path that anybody has ever measured (2787 square lookups for a two-storey
--- house), so the walk is done once and the two filters are applied to the result.
---
--- CLEARED AT BOTH ENDS, because one right-click reaches this mod twice and the
--- first of the two can be taken away.
---
--- The order in a right-click is: our createMenu wrapper (prepareMenu, which puts
--- up the stand-in), then vanilla's fetch, then OnPreFillWorldObjectContextMenu,
--- then OnFillWorldObjectContextMenu (the liquid submenu).  So the memo has to
--- survive from the first to the last, which rules out clearing it on the event in
--- between - that would throw away the walk prepareMenu just paid for and buy
--- nothing.
---
--- But prepareMenu lives in a wrapper on ISWorldObjectContextMenu.createMenu, and
--- another mod can assign straight over that field and drop it.  If that is the
--- only place the memo were cleared, it would then never be cleared at all and the
--- menu would show barrels that were there yesterday.
---
--- So prepareMenu clears it and says it did; the event clears it when prepareMenu
--- did not.  Whichever of the two runs, the memo lasts exactly one menu.
local scopeCache = {}
local scopeCleared = false

local function clearScopeCache()
	scopeCache = {}
end

--- KEYED ON THE BUILDING, not on the fixture, and that is the whole of the memo's value.
---
--- EP.collectorsInScope walks the fixture's BUILDING's bounding box; only the filter
--- afterwards depends on the fixture.  Keyed per fixture, four sinks in one bathroom
--- walked the same box up to four times over.
---
--- Measured, counting the walks rather than inferring them from a total: N plumbable
--- objects in `worldobjects` produced ceil(N/2) walks when they were adjacent and a full
--- N when they were not - four fixtures four tiles apart cost four walks and 20,556
--- operations.  The halving was not the memo working; it was a stand-in put up for one
--- fixture landing inside the nine squares its neighbour searches, so the neighbour
--- returned early without a box walk of its own.  Keyed on the building it is one walk,
--- whatever the spacing and whatever the fan-out.
---
--- The z is deliberately not in the key.  buildingBounds already unions a house with its
--- basements, so a cellar sink and a roof-level sink in the same building want the same
--- box - and the height rule that separates them is applied per collector by EP.eligible,
--- downstream of this.
---
--- A fixture with no building at all falls back to a square of Reach around ITSELF, which
--- is not shared, so those keep a per-fixture key.  On a dedicated server that is every
--- player base; on a client it is a shack on open ground.
local function scopeFor(fx, fy, fz)
	local def = EP.buildingAt(fx, fy, fz)
	local key = def and ("b:" .. def:getIDString()) or EP.key(fx, fy, fz)

	local found = scopeCache[key]
	if not found then
		found = EP.collectorsInScope(fx, fy, fz)
		scopeCache[key] = found
	end
	return found
end

--------------------------------------------------------------------------------
-- a stand-in may not outlive the menu it was put up for
--------------------------------------------------------------------------------

--- WHY A STAND-IN HAS A DEADLINE, and it is not tidiness.
---
--- EVERY server-to-client update for one object on a square is addressed by that object's
--- POSITION IN THE SQUARE'S OBJECT LIST and by nothing else.  All three channels:
---
---   ObjectChangePacket.parse    o = square.getObjects().get(index); o.loadChange(...)
---   ObjectModDataPacket         MovingObject.objectId = square.getObjects().indexOf(o)
---   GameServer.receiveSyncIsoObject / syncIsoObject    the same index
---
--- There is no identity check anywhere in any of them.
---
--- A stand-in is inserted at EP.GHOST_SEAT - index 0 - and is never transmitted:
--- transmitAddObjectToSquare's send half is inside `if (GameServer.server)`, so on a client
--- it is a plain local AddTileObject.  An INSERT at 0 shifts every other object on that
--- square up by one.  So for as long as a stand-in is standing, this machine's list for
--- that square is one longer than the server's, and every packet the server sends about
--- anything on it lands on the WRONG OBJECT - one slot late.  What that writes depends on
--- what is standing there: a fluid container copied onto a neighbour, modData wiped onto
--- something that never had any, or usesExternalWaterSource set on a real rain barrel,
--- which takes it out of vanilla's own right-click menu and out of EP.isWaterSource with it.
---
--- It cannot be fixed by moving the mirror off index 0.  Index 0 is what makes delivery
--- unconditional - FindWaterSourceOnSquare returns the FIRST object answering its four
--- questions and stops - and for a base whose barrels are nowhere near its fixtures that
--- seat is the whole reason the mod works at all.  It cannot be fixed by choosing a
--- different channel either, because all three are index-addressed.
---
--- So the only thing left to bound is the WINDOW.  A stand-in existed to make the FIRST
--- right-click correct, which is a job measured in one frame; it was then left standing
--- until the server's mirror displaced it or the same fixture was right-clicked again -
--- which, for a fixture the server never builds a mirror for, is the rest of the session.
--- This closes it to a handful of seconds.
---
--- NOT ONE FRAME, deliberately.  Vanilla re-resolves the source when the ACTION runs, not
--- when the menu is built - IsoObject.getFluidAmount goes through checkExternalFluidSource
--- every read - so tearing the stand-in down the instant createMenu returns would leave the
--- player a Drink row that does nothing.  A few seconds covers walking to the tap and the
--- action starting, and is still four orders of magnitude short of a session.
local STANDIN_SECONDS = 15

--- Squares this machine has a stand-in on, and when it went up.  Keyed by square so a
--- second right-click on the same fixture replaces rather than appends.
local standIns = {}

--- Take down any stand-in that has outlived its menu.
---
--- Guarded on an empty table first, because this runs on OnTick and a client ticks sixty
--- times a second: in the ordinary case - nobody has right-clicked a tap - it is one
--- `next`-free emptiness test and nothing else.  EP.any is the mod's own helper for that,
--- because this VM has no working `next`.
local function reapStandIns()
	if not EP.any(standIns) then return end
	if not getTimeInMillis then return end

	local now = getTimeInMillis()
	local due = nil

	for key, at in pairs(standIns) do
		if not at.ms then
			-- It went up on a machine that had no clock at the time.  Age it from the first
			-- tick that DOES have one rather than from zero: reading a missing timestamp as
			-- the epoch would make every such stand-in instantly overdue, which is the
			-- opposite of the deadline's purpose.
			at.ms = now
		elseif now - at.ms >= STANDIN_SECONDS * 1000 then
			due = due or {}
			due[#due + 1] = key
		end
	end

	if not due then return end

	-- Collected first and removed after, never inside the traversal: pruning a table while
	-- walking it is what crashed reviewPumps, and the note there says so.
	for i = 1, #due do
		local at = standIns[due[i]]
		standIns[due[i]] = nil

		local square = getCell() and getCell():getGridSquare(at.x, at.y, at.z)
		if square then
			for _, ghost in ipairs(EP.ghostsOnSquare(square)) do
				if ghost:getModData()[EP.KEY_LOCAL] then
					EP.removeLocalGhost(ghost)
					EP.log("a stand-in outlived its menu; taken down so the square"
						.. " lines up with the server's again")
				end
			end
		end
	end
end

--- Remember a stand-in so the reaper can find it again.
local function rememberStandIn(x, y, z)
	standIns[EP.key(x, y, z)] = { x = x, y = y, z = z,
		-- nil rather than 0 when there is no clock; the reaper stamps it on first sight.
		ms = getTimeInMillis and getTimeInMillis() or nil }
end

--- Forget one that has already been taken down by somebody else - hide(), or the clear at
--- the top of ensureLocalStandIn.  Cheap and idempotent; a key that is not there is fine.
local function forgetStandIn(x, y, z)
	standIns[EP.key(x, y, z)] = nil
end

EP.reapStandIns = reapStandIns

-- Guarded for the same reason every other handler in this file is: an error on OnTick is
-- one error per tick for the rest of the session, and the log it buries is the one somebody
-- needs.  logFault reports once with Debug off and every time with it on.
Events.OnTick.Add(function()
	local ok, err = pcall(reapStandIns)
	if not ok then
		EP.logFault("client-reap-standin", "ERROR taking down a stand-in: " .. tostring(err))
	end
end)

local function ensureLocalStandIn(fixture, playerNum)
	if not EP.isNetworkClient() then return end
	if not EP.getOption("Enabled") then return end
	if not EP.isPlumbableFixture(fixture) then return end

	local square = fixture:getSquare()
	if not square then return end

	-- THE SERVER'S GATE, NOT HALF OF IT.  This asked square:isInARoom() alone, which is the
	-- singleplayer half of the question: a player-built structure has a room only where the
	-- engine synthesised one, and it does not synthesise one on a dedicated server or for
	-- anything built within a tile of a map building.  serviceFixture accepts a room OR an
	-- enclosed roofed region, so this side stood down for exactly the fixtures the other
	-- side was building a mirror for, and the first right-click in a player base showed
	-- nothing at all.
	if not EP.canServeHere(square:getX(), square:getY(), square:getZ()) then return end

	local fx, fy, fz = square:getX(), square:getY(), square:getZ()

	-- Drop this machine's previous stand-in FIRST, every time, before anything is
	-- decided.
	--
	-- This is the bug that survived three server-side fixes.  A stand-in is a
	-- local object holding a copy of a barrel's water, and nothing on a client ever
	-- revisited it: reviewPumps, sleepGhost and the settle sweep are all behind
	-- EP.isAuthority(), which a multiplayer client is not.  So when the generator
	-- stopped, the server correctly emptied its own mirror - and the client went on
	-- showing a full one, and the fixture went on pouring from it.
	--
	-- Worse, it hid itself: the early-out below asks FindExternalWaterSource, and a
	-- stale stand-in with water in it *is* a water source, so the check passed and
	-- the stand-in was never reconsidered.  It could only ever be replaced, never
	-- corrected.
	--
	-- Clearing it first makes every right-click re-derive the answer from scratch,
	-- which is what the rest of the mod already does for everything else.
	for _, old in ipairs(EP.ghostsOnSquare(getCell():getGridSquare(fx, fy, fz + 1))) do
		local od = old:getModData()
		if od[EP.KEY_LOCAL] and od[EP.KEY_FIX_X] == fx
			and od[EP.KEY_FIX_Y] == fy and od[EP.KEY_FIX_Z] == fz then
			EP.removeLocalGhost(old)
			forgetStandIn(fx, fy, fz + 1)
		end
	end

	-- Something already answers for this fixture - but ONLY stand down for it if it is
	-- allowed to answer for THIS fixture.
	--
	-- FindExternalWaterSource searches the centre square at z+1 and its eight neighbours,
	-- so it reaches a mirror belonging to the sink NEXT DOOR.  Asking only "is there a
	-- source" therefore stood this fixture down whenever a neighbour had one, and the
	-- neighbour's mirror answered the menu in its place - with the neighbour's group and
	-- the neighbour's liquid.  Two adjacent sinks, one left on water and one pointed at
	-- whiskey, both read the same 300 out of the same stand-in.
	--
	-- Nothing is lost or duplicated by it: a stand-in holds no authority, settleGhost is
	-- behind EP.isAuthority(), and the server's real mirror lands on this fixture's own
	-- centre square and displaces it.  What is wrong is the menu, in the window before
	-- that packet arrives - and the menu is decided here, on the client, which is the
	-- whole reason a stand-in exists at all.
	--
	-- The server-side sweep removes neighbour mirrors for exactly this reason; this is the
	-- client's half of the same rule.
	--
	-- A REAL barrel answering is left alone, whatever square it stands on: that is
	-- vanilla's own water and vanilla's own answer, and the mod does not exist to
	-- second-guess it here.
	local already = fixture:FindExternalWaterSource()
	if already ~= nil then
		if not EP.isGhost(already) then return end

		local ad = already:getModData()
		if ad[EP.KEY_FIX_X] == fx and ad[EP.KEY_FIX_Y] == fy and ad[EP.KEY_FIX_Z] == fz then
			-- THE SERVER'S OWN MIRROR, REFRESHED FROM WHAT THIS CLIENT CAN SEE.
			--
			-- This used to stand down here and show whatever the last sync left behind,
			-- and that is where the complaint comes from: the Plumbed Liquid tooltip is a
			-- LIVE scan of the real barrels on this client (EP.liquidsInScope), while the
			-- tap reads the mirror, which is a server-maintained copy that arrives by
			-- ghost:sync().  Two numbers in one menu, from two sources, with different
			-- latencies - so a barrel you just built showed in the tooltip and not in the
			-- tap, and reopening the menu "fixed" it.
			--
			-- Asking the server is already done a few lines up and stays: it is what makes
			-- the answer AUTHORITATIVE.  This is what makes it IMMEDIATE, and the two are
			-- not the same job.  The server's packet lands a moment later and overwrites
			-- whatever this wrote, so the authority is unchanged.
			--
			-- No water can be created by this.  The container is a component, and a
			-- component write is deliberately not what the network watches - the long note
			-- in settleGhost is about exactly that.  So this moves nothing anywhere; it
			-- changes what this client draws until the server says otherwise.  Every actual
			-- draw is charged on the server, against the server's group.
			--
			-- It agrees with the tooltip BY CONSTRUCTION rather than by coincidence: both
			-- are built from this client's own scan of the same collectors, through the
			-- same eligibility test.  If they are ever both wrong they are wrong together,
			-- which is strictly better than disagreeing.
			local fc = already.getFluidContainer and already:getFluidContainer() or nil
			if fc then
				local seen = EP.visibleSupplyGroup(fx, fy, fz, EP.fixtureFluidType(fixture))
				if seen and #seen > 0 then EP.fillFromGroup(fc, seen) end
			end
			return
		end
		-- Somebody else's mirror.  Fall through and put up our own, which sits at index 0
		-- of this fixture's centre square and is therefore reached before any neighbour.
	end

	-- The fixture's OWN liquid, not water.  Without this the first right-click after
	-- a switch would put up a stand-in full of the wrong thing, and vanilla would
	-- offer a drink of it - the menu is decided on the client against the client's
	-- copy of the world, so being briefly wrong here is being wrong where it shows.
	local liquid = EP.fixtureFluidType(fixture)
	local group = EP.groupFrom(scopeFor(fx, fy, fz), fz, liquid)

	-- NOTHING IN VIEW, BUT A PIPE NETWORK THE AUTHORITY SAYS WILL FEED IT.  A network reaches
	-- past this client's loaded chunks by design, so the scan above can come back empty for a
	-- tap that is about to be served.  The summary is the authority's own answer - a barrel of
	-- this liquid above the tap, or a pumped one - so this goes up only where a group WILL be
	-- built, never merely because the tile is blue.  See plans/lgep-pipe-network.md section 7.
	local piped = false
	if #group == 0 then
		if not (EP.pipeFixtureServesVisible and EP.pipeFixtureServesVisible(fx, fy, fz, liquid)) then
			return
		end
		piped = true
	end

	local ghost
	if piped then
		ghost = EP.spawnEmptyStandIn(fx, fy, fz)
	else
		ghost = EP.spawnGhost(fx, fy, fz, group)
	end
	if not ghost then return end

	ghost:getModData()[EP.KEY_LOCAL] = true

	-- Filed the moment it goes up, so the reaper can take it down again.  See the long note
	-- on STANDIN_SECONDS: while this object stands, this machine's list for the square it
	-- stands on is one longer than the server's, and every index-addressed packet about that
	-- square lands one slot late.
	rememberStandIn(fx, fy, fz + 1)

	-- spawnGhost's settle is behind EP.isAuthority(), which this is not, so the
	-- stand-in comes out with a container and nothing in it - and an empty collector
	-- gets Plumb but no Drink.  Fill it from the group for the look of the thing, by
	-- the same function the server uses, so the number under the cursor is the one
	-- the server's mirror will show a tick later rather than one barrel's worth.
	--
	-- This is display only and cannot drift into the accounts: the ledger is only
	-- ever read by settleGhost, which returns before touching it on a client, and
	-- this object is never transmitted, never saved and gone the moment the
	-- server's own ghost lands.
	if not piped then EP.fillFromGroup(ghost:getFluidContainer(), group) end

	EP.log("put up a local stand-in so the menu is right on the first click")
end

--- Everything this mod wants to do on a right-click, in one place so it can be
--- run inside a pcall.
---
--- The whole world context menu is downstream of here.  An error thrown in this
--- function without the guard below does not produce a missing Plumb option, it
--- produces a player who cannot right-click anything, ever, until they restart -
--- and on a server they would blame the server.  Nothing this mod does is worth
--- that, so if any of it fails the menu is built from the untouched list and the
--- only cost is that a ghost is not made this click.
--- WHAT HAS TO HAPPEN BEFORE VANILLA'S FETCH RUNS, and it is asked of every square the menu
--- touches rather than of the caller's list (BR-LGEP-006).
---
--- `worldobjects` IS NOT THE SAME LIST FOR A MOUSE AND FOR A GAMEPAD, and everything below
--- depends on finding a fixture in it.  A mouse click hands over the picker's answer for one
--- square, which is the thing under the cursor.  A pad press hands over the FIRST object off
--- each of up to four squares - `ISButtonPrompt.getInteractOptionsButtonObjects`,
--- `ISButtonPrompt.lua:1076-1093`, one `objects:add(o); break` per square - and on any floored
--- square that first object is the FLOOR.  So on a gamepad this loop matched no fixture at
--- all, and none of the four things it exists to do happened: the washer's plumb marker was
--- not repaired, no stand-in went up, the engine's cached source was not refreshed, and the
--- authority was never asked about the fixture's square.
---
--- Measured in the harness: the same plumbed sink, in singleplayer, gives a mouse player a
--- row this mod added and a pad player `SitGround | Walk_to` and nothing else - and once the
--- mouse has been used on that sink the pad works, because the mouse click left the state
--- behind.  That is "several options of this mod will vanish randomly ... works fine with
--- mouse, only broken for controllers", word for word.
---
--- `fillMenu` has always walked squares (`objectsInMenu`), so the two halves of this file
--- disagreed about what a list means.  Now they do not.
---
--- `visible` is still built from the CALLER'S list and only ghost-filtered: it is what is
--- handed to `vanillaCreateMenu`, and vanilla's own `fetch` expands each entry's square
--- itself (`ISWorldObjectContextMenuLogic` :571-604).  Widening it here would put every
--- object on four squares into vanilla's menu, which is not ours to change.
---
--- `test` is the engine deciding whether to SHOW the prompt, not a player opening a menu.  A
--- pad press builds the menu twice - `getInteractOptionsButtonObjects` ends with
--- `createWorldMenu(..., true)` (`ISButtonPrompt.lua:1115`) and `interact` then builds it for
--- real - so without this guard every press did two square walks, two stand-in rebuilds and
--- two packets to the server.  `fillMenu` has always had the same guard.
local function prepareMenu(player, worldobjects, test)
	-- A new right-click, so last click's box walk is no longer an answer about now.
	clearScopeCache()
	scopeCleared = true

	local visible = {}
	for _, object in ipairs(worldobjects) do
		if EP.isGhost(object) then
			-- Keep it out of the menu: fetch files anything with fluid under
			-- storeWater, and would offer a drink from thin air.
			--
			-- hide() dresses it, and dressing it puts the shared sprite back on a
			-- mirror that came out of a save file or off the wire pointing at an
			-- anonymous one of its own.  That matters here and not only in the two
			-- events that usually do it: LoadGridsquare and OnObjectAdded cover a
			-- mirror arriving, and this covers one that is already there - which is
			-- every mirror on a chunk that opened before this file was listening,
			-- and any that reached the square by a path neither event describes.
			--
			-- The same argument discover() rests on.  Looking covers every path in
			-- one place; listening covers the paths somebody remembered to listen
			-- for, and this is the moment the answer is about to be used.
			hide(object)
		else
			visible[#visible + 1] = object
		end
	end

	if test then return visible end

	for _, object in ipairs(objectsInMenu(worldobjects)) do
		if EP.isPlumbableFixture(object) then
			-- BEFORE THE STAND-IN AND BEFORE VANILLA'S FETCH, WHICH IS THE WHOLE POINT
			-- OF DOING IT HERE.
			--
			-- fetch decides whether Plumb is offered by reading
			-- getUsesExternalWaterSource() on this machine's own copy, and it runs the
			-- moment this wrapper returns.  A washing machine's copy is wrong until
			-- this call - see EP.repairPipedFlag - so anywhere later than here is a
			-- menu that is still wrong for this click and right for the next one,
			-- which is exactly the "I keep plumbing it and nothing happens" this
			-- exists to end.
			EP.repairPipedFlag(object)
			ensureLocalStandIn(object, player)

			-- THE ENGINE'S CACHED SOURCE, REFRESHED FOR THE MENU ABOUT TO READ IT.  A fixture
			-- caches its external source and searches again only when that source is dry
			-- (IsoObject.checkExternalFluidSource), so a moment with an empty mirror leaves
			-- it cached on whatever neighbour had liquid - on this machine's copy, whatever
			-- the server's says.  The Fill and Drink rows, their amounts and the tap's name
			-- all come out of that cache.  One search of nine squares, per fixture, per
			-- right-click.  See seatHolds in LGEPPlumbing for the draw half.
			if object.getUsesExternalWaterSource and object:getUsesExternalWaterSource()
				and object.doFindExternalWaterSource then
				object:doFindExternalWaterSource()
			end

			local sq = object:getSquare()
			if sq then askServer(sq:getX(), sq:getY(), sq:getZ()) end
		end
	end
	return visible
end

--- Take mirrors out of the menu's own working set, from an event nothing can unwrap.
---
--- The filter below - a wrapper on ISWorldObjectContextMenu.createMenu - is the
--- tidy way to do this and it cannot be relied on.  It is a field on a vanilla
--- table, and nothing stops another mod assigning straight over it: a mod that
--- installs its own createMenu without first capturing and calling through drops
--- every wrapper already there, ours included, and load order decides who wins.
---
--- (This used to add "that is not theoretical - a crash log showed our frame missing
--- from a call we were supposed to be wrapping."  It was not evidence of it.  Only two
--- mods were loaded in that session, ours and Extended Electricity, and Electricity
--- touches ISActivateGenerator, ISPlugGenerator and ISGeneratorInfoWindow and nothing
--- else - there was nobody to clobber it.  The wrapper below ends in
--- `return vanillaCreateMenu(...)`, a tail call, which replaces the frame instead of
--- stacking on it, and that is the ordinary reason a wrapper is absent from a Lua
--- stack trace.  The defence is still right; the reason given for it was not, and it
--- was being cited in design arguments elsewhere in this mod.)
---
--- The reason given here used to be that `require` re-executes and re-derives the
--- table.  It does not: RunLuaInternal returns early on `loaded.contains(filename)`
--- (LuaManager.java:1344-1347), so requiring an already-loaded vanilla file is a
--- no-op.  The defence stays because the mechanism above is real and this one was
--- not; see the note in LGEPPower.lua for the full reading of the engine.
---
--- This is the same job done where it cannot be undone.  The sequence inside
--- vanilla's createMenu is:
---
---     for i,v in ipairs(worldobjects) do ISWorldObjectContextMenuLogic.fetch(...)
---     triggerEvent("OnPreFillWorldObjectContextMenu", ...)      <-- here
---     ISWorldObjectContextMenuLogic.createMenuEntries(fetch, ...)
---     triggerEvent("OnFillWorldObjectContextMenu", ...)
---
--- so this runs after the menu has sorted the world into buckets and before a single
--- entry is built from them.  OnFillWorldObjectContextMenu, where the rest of this
--- mod's menu code lives, is too late: createMenuEntries has already run by then.
---
--- Two buckets matter.  `fluidcontainer` holds anything carrying the component -
--- which every mirror does - and drives doFluidContainerMenu.  `storeWater` holds
--- anything answering hasFluid(), which a mirror with water in it does.  Removing a
--- mirror from both is the difference between a player being offered a drink from
--- thin air and the mirror not existing as far as the menu is concerned.
---
--- Nothing here assumes the buckets are present or are tables: this reads a
--- structure the engine owns, and reading it defensively costs two type checks.
--- (The buckets really are ordinary Lua arrays.  Vanilla builds them in Lua -
--- `fetch.fluidcontainer = {}` in clearFetch - and Java appends with
--- `rawset(size() + 1, v)`, whose int overload goes through KahluaUtil.toDouble, so
--- the keys are Lua numbers and `#` and table.remove are the right tools.)
---
--- The second test is not about this mod at all.
---
--- doFluidContainerMenu opens with `Texture.trygetTexture(object.getSpriteName())`
--- and trygetTexture dereferences before it checks - `name.endsWith(".png")` - so an
--- object in this bucket with no sprite name is a NullPointerException thrown out of
--- Java, inside createMenuEntries, three lines before vanilla fires
--- OnFillWorldObjectContextMenu.  Every mod's world menu entries go with it, and the
--- player sees an empty right-click and blames the server.
---
--- Whoever made that object, it was never going to draw: trygetTexture is being asked
--- for its icon and there is no name to look one up by.  Declining it costs a menu
--- entry that could not have appeared and saves the entire menu, so the test is on the
--- fault rather than on ownership - it does not ask whether the object is ours, and it
--- holds for a mirror that arrived with no modData and is therefore not recognisable
--- as ours at all.  That is the case the log caught: a right-click that threw 33 times
--- with both of this mod's filters installed and neither able to see the object.
---
--- Reported rather than done silently, because quietly removing another mod's object
--- from a menu is exactly the kind of thing that should be findable in a log, and
--- because a name-less object is a bug in whatever made it.
---
--- Once per session, not once per object.  A flag keyed on the object would hold a
--- reference to every world object it ever saw for as long as the session lasted, to
--- say a second time what it already said once; and this fires from a right-click, so
--- "once per object" would still be one line per barrel per menu on a base full of
--- them.  One line is enough to find it and fix whatever made the object.
local reportedNameless = false

local function stripGhostsFromFetch()
	local fetch = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars
	if type(fetch) ~= "table" then return end

	for _, name in ipairs({ "fluidcontainer", "storeWater" }) do
		local bucket = fetch[name]
		if type(bucket) == "table" then
			-- Backwards, so removing one does not skip the next.
			for i = #bucket, 1, -1 do
				local object = bucket[i]
				if EP.isGhost(object) then
					table.remove(bucket, i)
				elseif EP.isNameless(object) then
					table.remove(bucket, i)
					if not reportedNameless then
						reportedNameless = true
						EP.log("kept an object with no sprite name out of the "
							.. "fluid menu; it would have thrown out of doFluidContainerMenu and "
							.. "taken every mod's menu entries with it")
					end
				end
			end
		end
	end
end

Events.OnPreFillWorldObjectContextMenu.Add(function(player, context, worldobjects, test)
	-- The backstop half of the memo's lifetime; see the note on scopeCache.  If
	-- prepareMenu ran, it has already cleared it and this must not throw that away.
	if not scopeCleared then clearScopeCache() end
	scopeCleared = false

	local ok, err = pcall(stripGhostsFromFetch)
	if not ok then
		EP.logFault("client-clear-mirrors", "ERROR clearing mirrors from the menu: " .. tostring(err))
	end
end)

-- Installed only if there was something to call through to; see the capture above.
if vanillaCreateMenu then
ISWorldObjectContextMenu.createMenu = function(player, worldobjects, x, y, test)
	local visible = worldobjects
	if worldobjects then
		local ok, prepared = pcall(prepareMenu, player, worldobjects, test)
		if ok then
			visible = prepared
		else
			visible = worldobjects
			EP.logFault("client-prepare-menu", "ERROR preparing the world menu: " .. tostring(prepared))
		end
	end
	return vanillaCreateMenu(player, visible, x, y, test)
end
end

--------------------------------------------------------------------------------
-- the placement trigger
--------------------------------------------------------------------------------

--- Putting a collector down, or a fixture, should connect things without waiting
--- to be asked.
---
--- OnObjectAdded IS RAISED IN EVERY MODE, and this used to say it was not.
---
--- The ENGINE raises it only from `AddItemToMapPacket.processClient`, which is where the old
--- sentence came from - but vanilla's own Lua raises it as well, on the authority, in all
--- three modes: `ISMoveableSpriteProps.lua:1992` and `:2382`,
--- `RainCollectorBarrel.lua:29`, `ISDropWorldItemAction.lua:107`, `ISDropVehicleItemAction
--- .lua:73`, `ISTransferAction.lua:123`. `LGEPPlumbing`'s own handler was corrected months
--- ago and says so; this one was not, and the consequence was not cosmetic.
---
--- IN SINGLEPLAYER BOTH FILES ARE LOADED AND BOTH HANDLERS FIRE. `askServer` falls through
--- to `EP.serviceAround(x, y, z, true)` when there is no server to ask, so one barrel going
--- down ran the wide pass TWICE - two `noticeAt`s, two `EP.reviewPumps`, and (before today)
--- two full sweep purses. The removal handler below was worse: it added a wide pass that no
--- other mode runs at all, and it ran BEFORE the object had left the square
--- (`IsoGridSquare.java:6188`), so it settled every mirror in the building against a group
--- that still counted the barrel being carried away.
---
--- So the ask is for a NETWORK CLIENT only. In singleplayer the authority's own handler is
--- already there, in the same frame, doing exactly this.
--- Hiding is guarded separately from the rest, and deliberately so.  This is the path
--- a mirror arrives by, and hiding it is the half that must happen: a mirror that is
--- not hidden is a barrel drawn in mid-air and an object that can take the context menu
--- down.  Asking the server is the half that can be missed and healed later, because
--- the next right-click asks again.  Letting a fault in either one cost the other would
--- trade the important half for the recoverable one.
Events.OnObjectAdded.Add(function(object)
	if not object then return end
	hideOneQuietly(object)

	local ok, err = pcall(function()
		if not EP.getOption("Enabled") then return end
		if not EP.isWaterSource(object) and not EP.isPlumbableFixture(object) then return end

		-- A fixture arriving over the wire already plumbed - somebody else's washing
		-- machine, streaming in - carries the key and a flag the engine dropped.  Free
		-- here: the class test above has already been paid for.
		EP.repairPipedFlag(object)

		local square = object:getSquare()
		if square and EP.isNetworkClient() then
			askServer(square:getX(), square:getY(), square:getZ(), true)
		end
	end)
	if not ok then
		EP.logFault("client-placed-object", "ERROR servicing a placed object: " .. tostring(err))
	end
end)

--- A COLLECTOR OR FIXTURE BEING TAKEN AWAY, REPORTED TO THE SERVER.
---
--- The third of the three player-driven changes, and the last one that had no way across
--- the wire.  Everything a PLAYER does happens on their own machine; the server is told
--- only what somebody sends it.  Sorted by that rule, this mod's server-side handlers fall
--- into two groups:
---
---   engine-driven, and legitimately server-side:
---     LoadGridsquare, ReuseGridsquare, OnRainStop, OnTick, EveryTenMinutes, OnClientCommand
---
---   player-driven, and therefore CLIENT-ONLY in multiplayer:
---     OnObjectAdded             - covered, by the placement handler above
---     OnWaterAmountChange       - covered, by EP.COMMAND_DRAW
---     OnObjectAboutToBeRemoved  - THIS, and it was covered by nothing
---
--- What that cost: dismantle a barrel on a dedicated server and the server went on holding
--- it in `sources`, so every tap in the building kept counting water that was no longer
--- there.  It healed itself - supplyGroup prunes a collector it can no longer resolve when
--- the cursor next walks past - but "within a lap" is exactly the complaint, and until then
--- the tap offers water out of a barrel that has been carried away.
---
--- Sent WIDE, because a barrel leaving changes the answer for every fixture in the building
--- and not merely the nearest one - the same reasoning as the placement handler, which is
--- the same event running backwards.
---
--- The square is read BEFORE the object goes.  This fires while it is still on the square;
--- a moment later getSquare() answers nil and there is nothing left to name.
---
--- AND ONLY A NETWORK CLIENT SENDS IT.  In singleplayer `askServer` falls through to
--- `EP.serviceAround(..., true)` and `LGEPPlumbing`'s own handler for this event is already
--- registered - and that one is deliberately TARGETED (`ghostsFed`, `forgetSource`, a
--- re-settle) rather than wide, because this fires while the object is STILL on the square
--- (`IsoGridSquare.java:6188`). A wide pass here settles every mirror in the building against
--- a group that still counts the barrel being carried away, and no other mode ran one.
Events.OnObjectAboutToBeRemoved.Add(function(object)
	if not object then return end

	local ok, err = pcall(function()
		if not EP.getOption("Enabled") then return end
		if EP.isGhost(object) then return end
		if not EP.isWaterSource(object) and not EP.isPlumbableFixture(object) then return end

		local square = object:getSquare()
		if square and EP.isNetworkClient() then
			askServer(square:getX(), square:getY(), square:getZ(), true)
		end
	end)
	if not ok then
		EP.logFault("client-report-removal", "ERROR reporting a removal: " .. tostring(err))
	end
end)

--------------------------------------------------------------------------------
-- opting a collector in or out
--------------------------------------------------------------------------------

--- Added through OnFillWorldObjectContextMenu rather than by editing the menu
--- inside the createMenu wrapper above.  That wrapper runs before vanilla has
--- built anything and exists to fix the world *before* it is read; this is an
--- ordinary menu entry and belongs on the ordinary hook, where every other mod
--- expects to find it and where a failure costs one missing option instead of the
--- whole menu.
--- Start the wrench job, the way vanilla starts its own.
---
--- ISWorldObjectContextMenu.onPlumbItem is three lines - find the wrench, equip it,
--- queue the action - and this is those three lines with our action on the end.  The
--- equip is not decoration: LGEPPlumbCollector:isValid asks `isEquipped(self.wrench)`
--- every tick, exactly as ISPlumbItem does, so an action queued without one would cancel
--- itself on the first update.
---
--- Nothing is equipped for a disconnect, because nothing is required for one.
--- WALK TO IT FIRST, BECAUSE THE AUTHORITY GATES ON WHERE YOU ARE STANDING.
---
--- A world right-click reaches any square on screen, and none of these rows asked where the
--- player was: they equipped, queued and sent from wherever the character happened to be. The
--- authority's `commandAllowed` then refuses `COMMAND_INCLUDE`, `COMMAND_RESERVE` and
--- `COMMAND_FLUID` outside the sender's own building and beyond Reach, and that refusal goes to
--- `EP.log` alone - silent with Debug off. There is no *done* channel for any of the three, so
--- nothing came back either.
---
--- What a player saw: right-click a barrel across the yard, *Plumb into house supply*, a
--- hundred ticks of wrench animation played where they stood, and nothing happened. **It works
--- in singleplayer**, where `EP.applyPlumbed` calls `EP.setIncluded` directly and never meets
--- the gate - so it is a server-only silent failure, which is the shape this mod's own notes
--- call the worst kind.
---
--- `luautils.walkAdj` is vanilla's own answer and what `LGEPAreaUI:act` already uses for a pipe:
--- it walks the character to a neighbouring square and answers false when there is nowhere to
--- stand. Returning on false costs nothing - the act could not have succeeded anyway.
local function walkToAct(playerObj, square)
	if not square then return false end
	if not (luautils and luautils.walkAdj) then return true end
	return luautils.walkAdj(playerObj, square) ~= false
end

local function onPlumbCollector(_worldobjects, source, plumb, playerNum)
	local playerObj = getSpecificPlayer(playerNum)
	if not playerObj then return end
	if not walkToAct(playerObj, source.getSquare and source:getSquare() or nil) then return end

	local wrench
	if plumb then
		wrench = EP.findPipeWrench(playerObj)
		if not wrench then return end
		ISWorldObjectContextMenu.equip(playerObj, playerObj:getPrimaryHandItem(), wrench, true)
	end

	ISTimedActionQueue.add(LGEPPlumbCollector:new(playerObj, source, plumb, wrench))
end

local function onToggleReserve(_worldobjects, source, reserve, playerNum)
	local sq = source:getSquare()
	if not sq then return end

	-- The same walk the plumb row does, for the same gate.  See `walkToAct`.
	local playerObj = playerNum and getSpecificPlayer(playerNum) or getPlayer()
	if playerObj and not walkToAct(playerObj, sq) then return end

	if EP.isNetworkClient() then
		sendClientCommand(EP.COMMAND_MODULE, EP.COMMAND_RESERVE,
			{ x = sq:getX(), y = sq:getY(), z = sq:getZ(), reserve = reserve })
	elseif EP.setReserve then
		EP.setReserve(sq:getX(), sq:getY(), sq:getZ(), reserve)
	end
end

--- The collector's own submenu, which vanilla has already built by the time this
--- runs.  Both of this mod's options belong in there, with the other things you can
--- do to this barrel, rather than floating at the top level next to Walk To.
---
--- It is doFluidContainerMenu's submenu and NOT doStoreWaterMenu's, which is the
--- opposite of what the names suggest and worth spelling out, because aiming at the
--- wrong one produces an option that silently never appears.
---
--- ISWorldObjectContextMenuLogic.fetch files an object under `storeWater` only
--- `if (v.hasFluid())`, and separately under `fluidcontainer` whenever
--- `v.hasComponent(ComponentType.FluidContainer)`.  doStoreWaterMenu then skips any
--- storeWater entry that is also in fluidcontainer:
---
---     if (storeWater != null && !tableContainsValue(fluidcontainer, storeWater))
---
--- A rain collector holds its water IN a FluidContainer component - that is what this
--- whole mod reads through getFluidContainer - so it is always in the fluidcontainer
--- bucket and therefore NEVER gets a storeWater submenu.  doFluidContainerMenu is the
--- one that builds it, with Fluid Info and Transfer Fluids inside, and it is built
--- unconditionally for every object carrying the component: no hasFluid() gate, so an
--- EMPTY barrel has one too.  That matters here more than anywhere - a barrel you just
--- built is empty, and naming it your main supply is exactly what you want to do to it.
---
--- The title is `getMoveableDisplayName(obj) or obj:getFluidUiName()`, which is
--- doFluidContainerMenu's own pair and the same idiom vanilla's own
--- ISFeedingTroughMenu uses from Lua.  ISWorldObjectContextMenu.getMoveableDisplayName
--- is the public Lua twin of the private Java method the menu itself called - same
--- CustomName/GroupName properties, same Translator call - so the two agree in every
--- language rather than only in English.
---
--- Every method used here is checked for rather than assumed, because this runs on
--- somebody else's table.  OnFillWorldObjectContextMenu is raised with whatever
--- context the caller built, and the world menu is not always built by vanilla's own
--- createMenu - other mods raise it, and so do a couple of vanilla's own UIs.  A nil
--- call here would not cost a missing option, it would throw out of the event and
--- take every later mod's entries with it.
--- THE BARREL'S OWN SUBMENU, FOUND BY IDENTITY AND NOT BY NAME (BR-LGEP-006).
---
--- This used to ask `context:getOptionFromName(displayName)`, and
--- `ISContextMenu:getOptionFromName` (`ISContextMenu.lua:889-895`) returns the FIRST option
--- whose name matches and stops.  Two rain collectors are two top-level rows both reading
--- "Rain Collector Barrel", so every row this mod adds - Plumb in, Disconnect, Set reserve,
--- Show piped area - went into the FIRST barrel's submenu, several times over, and the other
--- barrels got none.
---
--- WITH A MOUSE THAT ALMOST NEVER HAPPENS and with a gamepad it is the normal case, which is
--- the whole of why this was reported as a controller bug.  `ISButtonPrompt
--- .getInteractOptionsButtonObjects` (`ISButtonPrompt.lua:1076-1093`) builds the pad's list by
--- taking the first object off each of up to FOUR squares - one `objects:add(o); break` per
--- square - where the mouse picker answers for one square.  A row of barrels along a wall is
--- then several identically named entries in one menu.  And which squares are in the set
--- depends on the way the player is FACING (`:1062-1069`), so turning moves the rows from one
--- barrel to another: "vanish randomly", exactly as reported.
---
--- `fluidBlockEntries` already solved this for the fluid rows - it walks vanilla's options
--- with a forward cursor and claims each one once, so identical names pair off in order.  Its
--- own comment says matching by name alone "would answer the first one twice"; this function
--- was never converted.  Now it is, and there is one pairing rule in the file rather than two.
local function collectorSubMenu(context, source)
	if not context or not context.getSubMenu then return nil end
	if type(fluidBlockEntries) ~= "function" then return nil end

	for _, entry in ipairs(fluidBlockEntries(context)) do
		if entry.object == source and entry.option and entry.option.subOption then
			return context:getSubMenu(entry.option.subOption)
		end
	end
	return nil
end

--- One collector's two options.  Split out from the loop below so that it can be
--- called inside a pcall per object; see fillMenu.
local function addCollectorOptions(context, worldobjects, object, playerNum)
	local sq = object:getSquare()
	if not sq or not EP.isWaterSource(object) then return end

	local plumbed = EP.isIncluded(object)

	-- NOTHING AT ALL ON A BARREL NO BUILDING COULD REACH.
	--
	-- This is the whole of the change: a rain barrel standing in a field, in a car park,
	-- or three tiles clear of the nearest wall gets no row from this mod whatever, rather
	-- than an option that would put it in a pool with nothing in it.
	--
	-- `plumbed` IS NOW EXACTLY "somebody plumbed this barrel in", because EP.isIncluded
	-- reads the barrel's own flag and nothing else.  While it still fell back to a sandbox
	-- option this test was reached only when that option was false - so on every world
	-- that already had the mod, where it was true, EVERY barrel answered plumbed, the
	-- location was never asked, and a barrel in a field was offered Disconnect and a
	-- reserve setting.  The over-application this change exists to end, alive and well in
	-- the one configuration nothing was testing.  The option is gone; see LGEPCore.
	--
	-- The asymmetry is load-bearing and unchanged: a barrel somebody DID plumb in must
	-- always be able to leave, even if the house it was leaning on has since been
	-- demolished and the plan test stopped answering.  Gating that on location would
	-- strand it in a supply nothing can offer to remove it from.  Getting in is
	-- conditional; getting out never is.  LGEPPlumbCollector:isValid draws the same line.
	if not plumbed and not EP.canPlumbHere(sq:getX(), sq:getY(), sq:getZ()) then return end

	-- Both options go in this barrel's own submenu, alongside Fluid Info and
	-- Transfer Fluids.  They are about this collector, so they belong with the
	-- other things you can do to it.
	--
	-- Falling back to the top level rather than to nothing when there is no
	-- submenu, and that is a deliberate choice about which failure is worse.
	-- Every rain collector has one - doFluidContainerMenu builds it for
	-- anything carrying the component, empty or not - but isWaterSource accepts
	-- anything IsoThumpable with capacity, and a modded collector serving its
	-- water out of the pipe reserve instead of a component would have no
	-- submenu at all.  An option in a slightly worse place is recoverable; an
	-- option that silently is not there is what people file bug reports about.
	local menu = collectorSubMenu(context, object) or context

	-- PLUMBING IT IN.  Offered on its own: an unplumbed barrel has no reserve setting and
	-- is not being kept for any liquid's system, so the rows below would all be describing
	-- a supply this barrel is not in.  One decision at a time, and the rest appear when it
	-- has been taken.
	if not plumbed then
		local opt = menu:addOption(getText("ContextMenu_LGEP_Plumb"),
			worldobjects, onPlumbCollector, object, true, playerNum)

		local tip = ISWorldObjectContextMenu.addToolTip()
		tip.description = getText("ContextMenu_LGEP_Plumb_tooltip")

		-- GREYED OUT RATHER THAN HIDDEN WITHOUT A WRENCH, which is vanilla's own
		-- treatment of the identical case (ISWorldObjectContextMenuLogic:1527-1534) and
		-- the right one: the barrel CAN be plumbed, the player just has not got the tool,
		-- and hiding the row would make the answer to "why can I not plumb this" invisible
		-- again.  Vanilla's key and vanilla's item name, so this costs no translation.
		local playerObj = getSpecificPlayer(playerNum)
		if not EP.findPipeWrench(playerObj) then
			opt.notAvailable = true
			tip.description = getText("Tooltip_NeedWrench", getItemName("Base.PipeWrench"))
		end

		-- Vanilla's own icon for the job, so the row reads as the same kind of work.
		-- Probed for: a texture that is not there must not cost the option.
		if Texture and Texture.getSharedTexture then
			local icon = Texture.getSharedTexture("Item_PipeWrench")
			if icon then opt.iconTexture = icon end
		end

		opt.toolTip = tip
		return
	end

	-- ROW ORDER FROM HERE IS DELIBERATE: what the barrel IS, then how it serves, then
	-- the way out.  Disconnect is added LAST so it sits below the reserve setting.
	--
	-- It is the one row that undoes the others - a disconnected barrel has no reserve
	-- setting to speak of - so it belongs at the bottom of its own group rather than at
	-- the top of it, where it also stops sitting directly under the pointer when the
	-- submenu opens.  Asserted in lgep_spec_plumbmenu, because an order nobody checks is
	-- an order the next edit quietly changes.

	-- What an empty barrel is still spoken for.
	--
	-- Shown only when it is BOTH empty and remembered, because that is the one state
	-- nothing else in the world says out loud: the barrel reads 0 / 400 and is in the
	-- whiskey system, and without a line saying so that is invisible state - which is
	-- what people file bug reports about.  A barrel with something in it needs no
	-- line; what it holds is already on the tooltip vanilla builds.
	--
	-- Not selectable, and there is deliberately NO "clear this barrel's liquid"
	-- option beside it.  The rule is that the liquid claims the barrel through an
	-- action, so it is released by one too: pour something else in and it is that
	-- from the same moment.  Outdoors the weather does it unaided - an empty barrel
	-- passes canAddFluid(Water), so rain refills it and it is a water barrel again.
	local fc = object:getFluidContainer()
	local held = fc and fc:getAmount() or 0
	local kept = held <= EP.EPS and EP.barrelFluidType(object) or nil
	if kept then
		local keptOpt = menu:addOption(
			getText("ContextMenu_LGEP_KeptFor", EP.fluidLabel(kept)), worldobjects, nil)
		keptOpt.notAvailable = true
		local keptTip = ISWorldObjectContextMenu.addToolTip()
		keptTip.description = getText("ContextMenu_LGEP_KeptFor_tooltip")
		keptOpt.toolTip = keptTip
	end

	-- WHICH SUPPLY THIS BARREL IS IN, WHEN IT IS NOT THE ONE THE PLAYER ASSUMES (BR-LGEP-029).
	--
	-- A barrel belongs to the whole SET of what is in it, so a splash of anything takes it
	-- off every water tap in the building and puts it on its own row instead.  Measured on
	-- the engine (`lgep_probe_mixplumb`), two plumbed 100 L water barrels:
	--
	--     two barrels of water                the water tap reads 200 L
	--     one litre of whisky into barrel A   100 L
	--     one litre of cola into barrel B       0 L
	--
	-- The rule is deliberate and it is what keeps beer out of the drinking water.  What was
	-- wrong is that NOTHING SAID SO: the barrel's own menu still read "Disconnect from house
	-- supply", which is true and is not the question being asked, and the only place the
	-- water had gone was a row three menus deep on the sink.  LittleGroove reported it as
	-- barrels "going unplumbed", which is exactly what it looks like from the tap.
	--
	-- Only where it tells the player something they do not already know: a plain water
	-- barrel is the default and says nothing, and an empty one has its own row above.
	if not kept and held > EP.EPS then
		local liquid = EP.barrelFluidType(object)
		if liquid and liquid ~= EP.FLUID_DEFAULT then
			local inOpt = menu:addOption(
				getText("ContextMenu_LGEP_InSupply", EP.fluidLabel(liquid)), worldobjects, nil)
			inOpt.notAvailable = true
			local inTip = ISWorldObjectContextMenu.addToolTip()
			inTip.description = getText("ContextMenu_LGEP_InSupply_tooltip")
			inOpt.toolTip = inTip
		end
	end

	-- Holding it back as a reserve.
	--
	-- Unconditional now, because everything past the early return above is the plumbed
	-- case.  It used to carry its own `if included` test for exactly the reason this whole
	-- block is now gated: a barrel outside the network is not being drawn on in any order
	-- at all, so EP.isReserve answers false for one and the option would have said nothing
	-- true.
	--
	-- A plain toggle either way, unlike the option this replaced: naming the main supply
	-- took the job off whichever barrel held it, so it had to be greyed out on the one
	-- that already had it.  Being held back is a property of this barrel and nobody
	-- else's business.
	local reserve = EP.isReserve(object)
	local resOpt = menu:addOption(
		reserve and getText("ContextMenu_LGEP_ClearReserve")
		        or getText("ContextMenu_LGEP_SetReserve"),
		worldobjects, onToggleReserve, object, not reserve, playerNum)
	local resTip = ISWorldObjectContextMenu.addToolTip()
	resTip.description = reserve
		and getText("ContextMenu_LGEP_ClearReserve_tooltip")
		or getText("ContextMenu_LGEP_SetReserve_tooltip")
	resOpt.toolTip = resTip

	-- TAKING IT BACK OFF, last, and never greyed out - it needs no tool.  See the note on
	-- row order above the kept-for line.
	local offOpt = menu:addOption(getText("ContextMenu_LGEP_Disconnect"),
		worldobjects, onPlumbCollector, object, false, playerNum)
	local offTip = ISWorldObjectContextMenu.addToolTip()
	offTip.description = getText("ContextMenu_LGEP_Disconnect_tooltip")
	offOpt.toolTip = offTip
end

--------------------------------------------------------------------------------
-- choosing what a fixture is plumbed to
--------------------------------------------------------------------------------

local function onSetFluid(_worldobjects, fixture, liquid, playerNum)
	local sq = fixture:getSquare()
	if not sq then return end

	-- The same walk again.  See `walkToAct`.
	local playerObj = playerNum and getSpecificPlayer(playerNum) or getPlayer()
	if playerObj and not walkToAct(playerObj, sq) then return end

	if EP.isNetworkClient() then
		sendClientCommand(EP.COMMAND_MODULE, EP.COMMAND_FLUID,
			{ x = sq:getX(), y = sq:getY(), z = sq:getZ(), fluid = liquid })
	elseif EP.setFixtureFluid then
		EP.setFixtureFluid(sq:getX(), sq:getY(), sq:getZ(), liquid)
	end
end

--- Which liquid this fixture draws.
---
--- AT THE TOP LEVEL, NOT IN THE FIXTURE'S OWN SUBMENU, and that is not a style
--- choice - the submenu is not reliably there.
---
--- A plumbed fixture carries no FluidContainer component, so
--- ISWorldObjectContextMenuLogic.fetch never files it under `fluidcontainer`; it
--- files it under `storeWater` only `if (v.hasFluid())`.  The named submenu a
--- player sees on a sink is built by doWashClothingOrYourselfMenu off that bucket,
--- so it is ABSENT whenever the tap is dry - which is exactly the moment somebody
--- needs to switch away from a liquid the house has run out of.  Putting the entry
--- inside it would make it disappear precisely when it is wanted.
---
--- Anchored DIRECTLY BELOW the fixture's own fluid submenu, and put in the place
--- that submenu would have occupied when there is not one.  See placeBelowFixture
--- for how the second half of that is done and what it is worth.
---
--- ONLY on a fixture this mod is actually feeding.  Two questions, both needed:
--- `getUsesExternalWaterSource()` says a player has taken a wrench to it, and the
--- source being one of ours says it is drawing on the barrel system rather than on
--- a real collector sitting in the nine squares above it, which is vanilla's own
--- arrangement and none of this mod's business.
---
--- Without the pair, the entry appeared on every sink, bath and toilet in Knox
--- County - on mains-fed town plumbing that this mod never touches - which is noise
--- on a menu shared with every other mod.
---
--- The cost is a genuine chicken-and-egg in one case: a building whose ONLY
--- collector holds something other than water cannot be plumbed at all, because an
--- unplumbed fixture defaults to water, finds no water group, gets no mirror, and
--- so is never offered vanilla's Plumb.  Put water in a barrel, plumb the fixture,
--- then switch it - or see the note on serviceFixture if that ever needs solving
--- properly.
---
--- Every method is probed for before it is called, like collectorSubMenu above and
--- for the same reason: this runs on a context table somebody else built, and a nil
--- call takes every later mod's entries down with it.
--- Every plumbable fixture a right-click is about, found by walking the SQUARE.
---
--- Not by filtering `worldobjects`, and that distinction is the whole of the
--- white-sink bug.  `worldobjects` is what the object PICKER returned, and a
--- fixture built out of more than one sprite - a basin over a counter unit - can
--- put the counter under the cursor and leave the waterPiped half out of the list
--- entirely.  Vanilla is unaffected because its own Plumb option is built Java-side
--- in createMenuEntries from a square-level scan, so the vanilla entries appeared
--- and this mod's did not, on some sinks and not others.
---
--- LGMainsWater's findFixture already did it this way, and the comment beside it
--- says why in as many words: the two menus reach the fixture by different routes,
--- so they can disagree about which object it is.  This is that, with the result
--- deduplicated, because several objects in `worldobjects` usually share a square
--- and a fixture must not collect one option per neighbour.
--- AND IT IS NOT ONLY MULTI-SPRITE FIXTURES.  On a gamepad the list is not the
--- picker's answer either: ISButtonPrompt:getInteractOptionsButtonObjects builds
--- it from the player's own square plus the three they are FACING, and takes only
--- the FIRST object off each one - there is a literal `break` after the first
--- non-raindrop, and that first object is the floor tile almost every time.  So on
--- a controller a rain collector is essentially never in `worldobjects`, however
--- squarely the player is standing in front of it.
---
--- Vanilla is unaffected for the same reason as above: the engine expands each
--- entry's square for itself, at ISWorldObjectContextMenuLogic.fetch:576, but it
--- expands into `fetch` - Java-side, and not the table this event is handed.
---
--- One walker, and the two filters below it, so a fixture and a collector can
--- never disagree about which squares the right-click was about.
objectsInMenu = function(worldobjects)
	local seenSquare, seenObject, out = {}, {}, {}

	for _, object in ipairs(worldobjects) do
		local square = object and object:getSquare()
		if square then
			local key = EP.key(square:getX(), square:getY(), square:getZ())
			if not seenSquare[key] then
				seenSquare[key] = true
				local objects = square:getObjects()
				for i = 0, objects:size() - 1 do
					local candidate = objects:get(i)
					if not seenObject[candidate] and not EP.isNameless(candidate) then
						seenObject[candidate] = true
						out[#out + 1] = candidate
					end
				end
			end
		end
	end

	return out
end

local function fixturesInMenu(worldobjects)
	local out = {}
	for _, candidate in ipairs(objectsInMenu(worldobjects)) do
		if EP.isPlumbableFixture(candidate) then out[#out + 1] = candidate end
	end
	return out
end

--------------------------------------------------------------------------------
-- putting the entry where the fixture is, whether or not the fixture is there
--------------------------------------------------------------------------------

--- The name vanilla gives an object's own top-level entry, by the branch that built it.
---
--- Both branches start from the same helper - `getMoveableDisplayName`, which is
--- CustomName optionally prefixed with GroupName, put through
--- Translator.getMoveableDisplayName - and the Lua copy this calls
--- (ISWorldObjectContextMenu.lua:93-105) is line-for-line the private Java one
--- (ISWorldObjectContextMenuLogic.java:3887-3905).  So the string built here is the
--- same string the engine put in the option, not an approximation of it.
---
--- The FALLBACKS are where the two branches part, and getting them wrong means
--- failing to find an entry that is sitting right there:
---
---     doFluidContainerMenu:4160        name or object.getFluidUiName()
---     doWashClothingOrYourselfMenu:1313  name, or getFluidUiName() for a world item
---                                        carrying one, or ContextMenu_NaturalWaterSource
---
--- A plumbable fixture normally has a CustomName and never reaches either, but a
--- modded one without will, and it is the case where the entry exists under a name
--- nothing would have guessed.
local function vanillaEntryName(object, inFluidContainer)
	if not object then return nil end

	local name = ISWorldObjectContextMenu.getMoveableDisplayName
		and ISWorldObjectContextMenu.getMoveableDisplayName(object)
	if name then return name end

	if inFluidContainer then
		return object.getFluidUiName and object:getFluidUiName() or nil
	end

	if object.getItem and object:getItem() and object.getFluidUiName then
		return object:getFluidUiName()
	end
	return getText("ContextMenu_NaturalWaterSource")
end

--- Vanilla's fluid block, as OPTIONS paired with the objects they were built for.
---
--- createMenuEntries builds one contiguous run of top-level entries out of the two
--- fetch buckets, in this order and no other:
---
---     for fluidcontainer     -> doFluidContainerMenu      -- :912-927
---     doWashClothingOrYourselfMenu over storeWater        -- :933
---         minus anything already in fluidcontainer        -- :1312
---
--- so the block can be reconstructed by predicting each name and walking the menu
--- forwards looking for it.  `fetchVars` is still the live table here: clearFetch
--- runs at the top of createMenu and the next thing to touch it is the next
--- right-click, and OnFillWorldObjectContextMenu is raised from inside the same call.
---
--- Matched FORWARDS, each option claimed at most once.  Two fixtures on one square
--- with the same display name - a pair of identical sinks, which is a kitchen - are
--- two entries reading "Sink", and matching by name alone would answer the first one
--- twice and put both entries under the same tap.
---
--- An object in a bucket that produced no entry is simply not found and skipped.
--- That is not hypothetical: doFluidContainerMenu returns before adding anything for
--- an IsoWorldInventoryObject (:4157), and a feeding trough is redirected to its
--- master.  Skipping is right - the entry genuinely is not there to anchor to.
fluidBlockEntries = function(context)
	local out = {}

	local options = context.options
	if type(options) ~= "table" then return out end

	local fetch = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars
	if type(fetch) ~= "table" then return out end

	local containers = type(fetch.fluidcontainer) == "table" and fetch.fluidcontainer or {}
	local stored = type(fetch.storeWater) == "table" and fetch.storeWater or {}

	local inContainer = {}
	for _, o in ipairs(containers) do inContainer[o] = true end

	local expected = {}
	for _, o in ipairs(containers) do
		expected[#expected + 1] = { object = o, name = vanillaEntryName(o, true) }
	end
	for _, o in ipairs(stored) do
		if not inContainer[o] then
			expected[#expected + 1] = { object = o, name = vanillaEntryName(o, false) }
		end
	end

	local from = 1
	for _, want in ipairs(expected) do
		if want.name then
			for i = from, #options do
				local opt = options[i]
				if opt and opt.name == want.name then
					out[#out + 1] = { object = want.object, option = opt }
					from = i + 1
					break
				end
			end
		end
	end

	return out
end

--- The last two options createMenuEntries adds, whichever of them is present.
---
--- These are the only entries in the whole world menu that can be counted on, and
--- they are the reason tier 4 of placeBelowFixture works at all:
---
---     if (playerObj.getVehicle() == null && !isSitOnGround() && !isSittingOnFurniture())
---        addOption(ContextMenu_SitGround)                          -- :1118-1124
---     if (getJoypadState(player) == null && playerObj.getVehicle() == null)
---        addGetUpOption(ContextMenu_Walk_to)                       -- :1126-1138
---     return false;                                                -- :1140
---
--- Nothing follows them - createMenuEntries returns, and createMenu raises
--- OnFillWorldObjectContextMenu without adding anything of its own
--- (ISWorldObjectContextMenu.lua:209-213).  So for a mouse-and-keyboard player on
--- foot, which is the case this mod is used in, Walk to is the last vanilla row and
--- Sit on the ground is the row above it.
---
--- Everything BETWEEN the fluid block and these two is conditional - stove, bed,
--- light switch, tree, fishing, fuel, cleaning, safehouse, shovel, gardening,
--- disassemble, destroy - so this is the near end of the tail rather than the far
--- end of the block.  It is not the fixture's exact slot; it is the same slot every
--- time, which is what was actually being asked for, and it is above the tail
--- instead of below it, which is where the entry used to land.
local TAIL_KEYS = { "ContextMenu_SitGround", "ContextMenu_Walk_to" }

local function tailEntry(context)
	local options = context.options
	if type(options) ~= "table" then return nil end

	for _, key in ipairs(TAIL_KEYS) do
		local text = getText(key)
		if type(text) == "string" and text ~= "" then
			for i = 1, #options do
				if options[i] and options[i].name == text then return options[i] end
			end
		end
	end
	return nil
end

--- Move an option already in the menu to a known index.
---
--- Not insertOptionAfter, and the difference is the point.  That takes a NAME and
--- stops at the first option carrying it (ISContextMenu.lua:937-943), so two sinks
--- called "Sink" both anchor to the first one; and when the name is not found it
--- silently falls back to addOption at the end (:944-946), which is the behaviour
--- being fixed here rather than one to build on.  This anchors on the option TABLE,
--- which is the only thing that identifies an entry uniquely.
---
--- Shifted by hand rather than through table.remove/table.insert, and the ids are
--- renumbered afterwards, because that is precisely what insertOptionAfter does to
--- this same array (:947-958).  Half of `options` can have been written from Java -
--- `getOptions().rawset(getNumOptions(), option)`, numOptions being a Double - so the
--- keys are Lua doubles rather than integers; 1.0 and 1 are one key in Kahlua and it
--- makes no difference, but copying vanilla's own idiom means not having to be right
--- about that twice.  Same reading as the fetch buckets in stripGhostsFromFetch.
---
--- numOptions is untouched: nothing was added or removed.  calcHeight and setWidth
--- already ran inside addOption and neither depends on the order.
local function moveOptionTo(context, option, index)
	local options = context.options
	if type(options) ~= "table" then return end

	local n = #options
	local from
	for i = 1, n do
		if options[i] == option then from = i; break end
	end
	if not from then return end

	local to = index
	if to < 1 then to = 1 end
	if to > n then to = n end
	if to == from then return end

	if from > to then
		for i = from, to + 1, -1 do options[i] = options[i - 1] end
	else
		for i = from, to - 1 do options[i] = options[i + 1] end
	end
	options[to] = option

	for i = 1, n do
		if options[i] then options[i].id = i end
	end
end

--- Put this fixture's entry directly below the fixture, wherever the fixture is.
---
--- Four tiers, and the ladder exists because the thing being anchored to is not
--- reliably in the menu.  A plumbed fixture reaches `storeWater` only through
--- `fetch`'s `if (v.hasFluid())` (:131-141), hasFluid is `getFluidAmount() > 0`
--- (IsoObject.java:3026-3030), and getFluidAmount on a plumbed fixture is whatever
--- the external source has (:2641-2647).  So the fixture's own entry disappears the
--- moment the building runs dry - which is precisely the moment a player is looking
--- for this option, to switch back to something there is some of.
---
---   1. the fixture's own entry          - directly below it, the whole point
---   2. an entry we already placed here  - so two dry fixtures keep their order
---   3. the last entry of the fluid block - still in the block, one row further down
---   4. Sit on the ground / Walk to      - above the tail, the same row every time
---
--- Falling through all four leaves the option where addOption put it, at the end.
--- That is the old behaviour and it is deliberately the last resort rather than the
--- second: appending puts the entry BELOW Walk to, under the row that ends every
--- menu, which is where it does not look like it belongs to anything.
local function placeBelowFixture(context, option, fixture, placed)
	local block = fluidBlockEntries(context)

	local anchor
	for _, entry in ipairs(block) do
		if entry.object == fixture then anchor = entry.option; break end
	end

	if not anchor then anchor = placed.last end
	if not anchor and #block > 0 then anchor = block[#block].option end

	local below = true
	if not anchor then
		anchor = tailEntry(context)
		below = false
	end
	if not anchor then return end

	local at
	local options = context.options
	if type(options) ~= "table" then return end
	for i = 1, #options do
		if options[i] == anchor then at = i; break end
	end
	if not at then return end

	moveOptionTo(context, option, below and at + 1 or at)
	placed.last = option
end

--- THE "PLUMBED LIQUID" ROW AND ITS SUBMENU, BUILT ONCE FOR BOTH KINDS OF FIXTURE.
---
--- A tap and a topped-up dispenser ask the identical question - which of the liquids this
--- building holds should come out of this thing - so they ask it through one function.  The
--- rows, the tooltips, the breakdown lines, the greyed-out current entry and the "nothing to
--- choose, nothing to show" rule are all decided here; the callers differ only in what they
--- check BEFORE calling and where they put the option AFTER.
---
--- Extracted rather than copied: two transcriptions of a menu is the drift this file
--- complains about everywhere else, and the two would have gone out of step at the first
--- change to what a liquid row says.
---
--- Returns the option, or nil when there was nothing worth offering.
local function liquidOption(context, worldobjects, object, sq, playerNum)
	-- WHERE THE CURRENT ANSWER IS KEPT IS THE ONE THING THE TWO KINDS DIFFER ON, and it is
	-- one line rather than a parameter because it is derivable from the object itself.  A
	-- tap keeps its choice in its own modData; a topped-up fixture keeps it on the SQUARE,
	-- because the engine destroys and rebuilds a dispenser on every bottle change and a
	-- choice on the object would not survive one.  See EP.KEY_FED.
	local current = EP.isFedFixture(object) and EP.fedFluidType(sq, object)
		or EP.fixtureFluidType(object)
	local liquids = EP.liquidsInScope(sq:getX(), sq:getY(), sq:getZ(),
		scopeFor(sq:getX(), sq:getY(), sq:getZ()))

	-- NOTHING TO CHOOSE, NOTHING TO SHOW.
	--
	-- liquidsInScope always ends with a Water row whether or not the building holds
	-- any (see the note there: without it, a player who switched to whiskey and drank
	-- the lot could never switch back), so the list is never empty and the entry used
	-- to appear on every plumbed fixture in the world.  In the ordinary base - barrels
	-- of rainwater and nothing else - that is one row, already ticked and greyed out
	-- by the loop below, on a menu shared with every other mod.
	--
	-- Counted as SELECTABLE rows rather than as rows, because those are not the same
	-- when the list has shrunk to one: a fixture left pointing at whiskey after the
	-- last whiskey barrel was emptied and taken away has one row, Water, and it is not
	-- the current one - so it is a real choice and the only route back.  Hiding on
	-- "#liquids < 2" would have stranded that fixture.  Two or more rows always leaves
	-- at least one non-current, so this is the "at least two options" rule everywhere
	-- it can be, and strictly safer where it cannot.
	local choices = 0
	for i = 1, #liquids do
		if liquids[i].type ~= current then choices = choices + 1 end
	end
	if choices == 0 then return end

	local label = getText("ContextMenu_LGEP_PlumbedLiquid", EP.fluidLabel(current))

	-- Added at the end and MOVED afterwards, rather than inserted in place.
	--
	-- addOption is the one entry point that is certainly there and certainly works:
	-- it allocates out of the option pool, bumps numOptions and recalculates the
	-- menu's height and width, and none of that is repeated by moving the option
	-- within the array afterwards.  Building it correctly first and placing it second
	-- also means a fault in the placement costs a row in the wrong place instead of
	-- the option itself - the failure this whole file is arranged around.
	local option = context:addOption(label, worldobjects, nil)
	if not option then return end

	local tip = ISWorldObjectContextMenu.addToolTip()
	tip.description = getText("ContextMenu_LGEP_PlumbedLiquid_tooltip")

	-- WHAT THIS TAP IS ACTUALLY POURING, on the row that names it.
	--
	-- The row already says "Plumbed liquid: Bleach + Water"; without this there is
	-- nowhere at all a player can find out how much of each that is.  Vanilla's tap
	-- tooltip prints one total and has no idea the supply is a blend.
	--
	-- Read off the CURRENT liquid's own row rather than off the mirror, so it is the
	-- same number the submenu shows a line below and comes from the same walk.  A
	-- fixture pointed at a liquid the building has none of has no row to read and
	-- simply gets no breakdown, which is the honest answer for a dry tap.
	for i = 1, #liquids do
		if liquids[i].type == current then
			local lines = EP.breakdownLines(liquids[i].sum)
			if lines then tip.description = tip.description .. " <LINE> <LINE> " .. lines end
			break
		end
	end

	option.toolTip = tip

	local sub = ISContextMenu:getNew(context)
	context:addSubMenu(option, sub)

	for i = 1, #liquids do
		local row = liquids[i]
		local entry = sub:addOption(row.label, worldobjects, onSetFluid, object, row.type, playerNum)

		local rowTip = ISWorldObjectContextMenu.addToolTip()
		if row.count > 0 then
			rowTip.description = getText("ContextMenu_LGEP_LiquidAmount",
				string.format("%.0f", row.amount), string.format("%.0f", row.capacity), row.count)

			-- And, for a mixture, what it is made of.  The total above says how much
			-- Bleach + Water the building has; this says how much of it is bleach, which
			-- is the difference between a row a player can act on and a row they have to
			-- guess about.  nil for a single-fluid supply, where there is nothing to
			-- break down and the line above already said everything.
			local lines = EP.breakdownLines(row.sum)
			if lines then rowTip.description = rowTip.description .. " <LINE> " .. lines end
		else
			rowTip.description = getText("ContextMenu_LGEP_LiquidNone")
		end
		entry.toolTip = rowTip

		-- The one it is already on is shown and not selectable, rather than left out.
		-- A menu that silently drops the current answer reads as the setting having
		-- been lost.
		if row.type == current then
			entry.notAvailable = true
			entry.iconTexture = nil
		end
	end

	return option
end

--- WHERE VANILLA WOULD HAVE PUT A PLUMB ROW FOR THIS OBJECT.
---
--- createMenuEntries adds exactly one plumb row, at the TOP LEVEL, out of
--- doWaterPipeMenu (ISWorldObjectContextMenuLogic.java:886-889) - and it does it after the
--- padlock rows and BEFORE the loop that builds the fluid-container submenus (:911-927).
--- So the slot is "immediately above the first entry of the fluid block", and that is what
--- this reproduces rather than a row count or a guess.
---
--- fluidBlockEntries already reconstructs that block for the fixture's liquid row, by
--- predicting each entry's name out of the live fetch buckets and walking the menu forward.
--- Asking it from here means the two rows this mod adds are positioned by ONE piece of
--- knowledge about vanilla's menu order instead of two that could drift apart.
---
--- A listed fixture ALWAYS has an entry in that block: EP.isFedFixture ends by requiring a
--- FluidContainer, and doFluidContainerMenu builds a submenu for anything carrying the
--- component, full or empty.  The fallbacks are still written, because this runs on a menu
--- somebody else may have built - other mods raise OnFillWorldObjectContextMenu, and so do
--- two of vanilla's own UIs - and a row appended to the very end, below Walk to, is a row
--- that does not look like it belongs to anything.
local function placeAtPlumbSlot(context, option)
	local block = fluidBlockEntries(context)
	local anchor = block[1] and block[1].option or nil

	-- Nothing to sit above, so sit above the tail instead: the same slot every time, which
	-- is the property tailEntry exists to give.
	if not anchor then anchor = tailEntry(context) end
	if not anchor then return end

	local options = context.options
	if type(options) ~= "table" then return end
	for i = 1, #options do
		if options[i] == anchor then
			moveOptionTo(context, option, i)
			return
		end
	end
end

--- A LISTED FIXTURE'S TWO OPTIONS, AND IT IS THE COLLECTOR'S PAIR WITH THE MIDDLE TAKEN OUT.
---
--- Everything about the act is identical: the same wrench, the same LGEPPlumbCollector, the
--- same COMMAND_INCLUDE, the same KEY_INCLUDE flag, the same EP.canPlumbHere gate, and the
--- same asymmetry - getting in is conditional and getting out never is.  Written as its own
--- function rather than as three branches inside addCollectorOptions because the two differ
--- in where they GO and what they OFFER, and a shared function carrying a "which kind is
--- this" argument would put both differences in four places instead of one.
---
--- TOP LEVEL, IN VANILLA'S OWN PLUMB SLOT, AND NOT IN THE OBJECT'S SUBMENU - which is the
--- opposite of where a collector's rows go, deliberately.
---
--- A collector's rows are about a barrel a player already understands: they belong beside
--- Fluid Info and Transfer Fluids, with the other things you can do to that barrel.  This
--- row is the same JOB the game already has a row for - stand there with a pipe wrench and
--- connect a thing to a water supply - so it belongs where the player has already learnt to
--- look for it, and it says so in vanilla's own words.
---
--- ContextMenu_PlumbItem IS VANILLA'S KEY, so this costs no translation and reads as
--- "Plumb Dispenser" in all 28 languages, with the same wrench icon and the same greying.
--- There is no clash to worry about: a listed fixture carries no waterPiped flag, so
--- doWaterPipeMenu never offers one of its own for the same object.
---
--- NO RESERVE ROW, and that is the whole of what is missing next to a collector's pair.
--- Holding something back as a reserve is a rule about the order water is TAKEN in, and
--- nothing is ever taken out of a dispenser by this mod - it only ever receives.  The row
--- would describe nothing, which is the invisible state the mod is arranged against
--- everywhere else.  Nor a kept-for line: a listed fixture has no liquid of its own to be
--- claimed by, because it is filled with clean water and that is not anybody's choice.
local function addFedOptions(context, worldobjects, object, playerNum)
	local sq = object:getSquare()
	if not sq or not EP.isFedFixture(object) then return end
	if not context or not context.addOption then return end

	-- THE SQUARE IS THE TRUTH AND THE OBJECT CARRIES A COPY, and this side reads whichever
	-- it actually has.  See the long note on EP.KEY_FED: the square survives the engine
	-- destroying and rebuilding a dispenser on every bottle change, so it is what the
	-- authority keeps; but IsoGridSquare has no transmit for its modData, so a client only
	-- ever sees the copy stamped on the object.  Passing both lets one predicate answer for
	-- every mode instead of the menu quietly disagreeing with the mod on a server.
	local plumbed = EP.isFedPlumbed(sq, object)

	-- Nothing at all where a building could never reach it - a dispenser in a car park, or
	-- one somebody has dragged into a field.  Same reasoning as the collector's: an option
	-- that would do nothing is worse than no option, because there is no error to show.
	--
	-- And the same asymmetry: one already plumbed in must always be able to leave, even if
	-- the building around it has since come down.
	if not plumbed and not EP.canPlumbHere(sq:getX(), sq:getY(), sq:getZ()) then return end

	-- AND NOTHING UNLESS THERE IS ACTUALLY A SUPPLY TO JOIN.
	--
	-- EP.canPlumbHere answers "is this somewhere a building's plumbing could reach", which is
	-- a question about the PLACE.  It is the right gate for a collector, because a barrel is
	-- what a building's supply is MADE of - plumb the first one in and the house has a supply
	-- where it had none.  A dispenser is the other end of the pipe and makes nothing: plumbed
	-- into a house with no collectors in it, the row is work a player can do that has no
	-- effect they can ever see.
	--
	-- So this asks the second question too, and it asks it with the same walk the fixture
	-- rows use - scopeFor is memoised per building per menu, so a dispenser standing next to
	-- a sink costs nothing at all and one standing alone costs the one box walk that sink
	-- would have paid.  EP.groupFrom applies EP.serves, which is height, pumps, inclusion and
	-- liquid - so this counts exactly the collectors that would feed it and not one more.
	--
	-- A PLUMBED-IN BARREL THAT HAPPENS TO BE EMPTY STILL COUNTS, deliberately.  An empty rain
	-- barrel is a supply that has not rained yet - EP.serves admits an unassigned collector
	-- for water for precisely that reason - and gating on litres would make the row appear
	-- and vanish as the building drained, which is worse clutter than the row it removes.
	--
	-- ONLY ON THE WAY IN.  Disconnect is never gated on anything, here or on a collector: a
	-- house whose last barrel has been taken away must still be able to release what it
	-- plumbed in, or the flag is stuck on for good.
	if not plumbed then
		-- OR A PIPE NETWORK REACHES IT, which is the whole point of pipes and was the one
		-- gate of the three that did not ask.
		--
		-- `scopeFor` walks a box clipped to THIS machine's loaded chunks, and a network is
		-- by design the thing that reaches past them. The authority applies no such rule -
		-- its only gate is `EP.canPlumbHere`, which returns true on a pipe tile outright -
		-- so the server would fill the dispenser the moment a COMMAND_INCLUDE arrived, and
		-- this row is the only thing in the mod that can send one. No row, no route, and
		-- nothing said: the same silent refusal BR-LGEP-003 is about, worst exactly where
		-- pipes are the point.
		--
		-- The two sibling call sites that ask this same question, `ensureLocalStandIn` and
		-- `addNoSupplyReason`, both already carry the fallback.
		local supply = EP.groupFrom(
			scopeFor(sq:getX(), sq:getY(), sq:getZ()), sq:getZ(), EP.FLUID_DEFAULT)
		if #supply == 0
			and not (EP.pipeFixtureServesVisible and EP.pipeFixtureServesVisible(
				sq:getX(), sq:getY(), sq:getZ(), EP.FLUID_DEFAULT))
		then
			return
		end
	end

	-- vanillaEntryName rather than getMoveableDisplayName straight, so a modded fixture with
	-- no CustomName gets the same fallback vanilla's own menu would have given it instead of
	-- a row reading "Plumb ".
	local name = vanillaEntryName(object, true) or ""

	if not plumbed then
		local opt = context:addOption(getText("ContextMenu_PlumbItem", name),
			worldobjects, onPlumbCollector, object, true, playerNum)

		local tip = ISWorldObjectContextMenu.addToolTip()
		tip.description = getText("ContextMenu_LGEP_PlumbFed_tooltip")

		-- Greyed rather than hidden without a wrench, which is exactly what doWaterPipeMenu
		-- does to its own row (:1527-1534), down to the key and the item name - so the
		-- answer to "why can I not plumb this" looks the same as it does on a sink.
		local playerObj = getSpecificPlayer(playerNum)
		if not EP.findPipeWrench(playerObj) then
			opt.notAvailable = true
			tip.description = getText("Tooltip_NeedWrench", getItemName("Base.PipeWrench"))
		end

		-- Vanilla sets this unconditionally on its plumb row; probed for, because a texture
		-- that is not there must not cost the option.
		if Texture and Texture.getSharedTexture then
			local icon = Texture.getSharedTexture("Item_PipeWrench")
			if icon then opt.iconTexture = icon end
		end

		opt.toolTip = tip
		placeAtPlumbSlot(context, opt)
		return
	end

	-- WHICH LIQUID IT IS FILLED WITH, ON EXACTLY THE SAME ROW A TAP GETS IT ON.
	--
	-- Same question, same submenu, same builder - liquidOption - so a dispenser lists what
	-- the building holds, prints the litres and the mixture breakdown, and greys out the one
	-- it is already on, without a second copy of any of that.  It answers nil when there is
	-- nothing to choose, which in an ordinary base of rainwater is always, so the row does
	-- not appear at all until the building really does hold something else.
	--
	-- ONLY WHILE THE TANK IS EMPTY, and this is the one gate a tap does not have.
	--
	-- A tap holds nothing: switching it from water to whiskey changes where the next glass
	-- comes from and nothing else, and EP.setFixtureFluid settles the old group on the way
	-- past so no water is lost.  A dispenser is a real fifteen-litre vessel with real water
	-- in it.  Switching a half-full one would have the next top-up pour whiskey into water -
	-- and unlike a barrel, which a player can tip out, a mixture in here is theirs for good.
	--
	-- So the choice is offered at the one moment it is free, which is when there is nothing
	-- to spoil.  Emptying it is something the player can already do from vanilla's own
	-- Transfer Fluids in the same submenu, so this is a step rather than a dead end.  The
	-- authority refuses the same thing for the same reason; see EP.setFixtureFluid.
	--
	-- AND THERE IS DELIBERATELY NO DISCONNECT ROW, which is the one place this parts company
	-- with a collector's pair.
	--
	-- A collector needs one and cannot do without it.  A rain barrel is heavy, it is usually
	-- full, and picking it up is refused outright while it holds anything -
	-- canPickUpMoveableInternal is `if self.isWaterCollector and _object:hasFluid() then
	-- canPickUp = false`.  So without a row there would be no way at all to take a barrel
	-- back out of a building's supply, which is why getting out is never gated on anything.
	--
	-- A dispenser is not a water collector by that test - its tile carries no
	-- IsWaterCollector property - so it can be picked up full, and picking it up is already
	-- a complete undo: the square is cleared the moment nothing scripted is standing on it,
	-- so it comes back down unplumbed and on water.  A row that duplicates something the
	-- player can already do is clutter on a menu this mod shares with everybody else's.
	--
	-- THE SERVER STILL HONOURS A DISCONNECT if one arrives - see EP.setIncluded.  Nothing
	-- sends one now, but the command is not narrowed to match the menu: a client that is a
	-- version behind still has the row, and a request the authority silently ignored would
	-- be the timed action that plays out in full and does nothing.
	local fc = object:getFluidContainer()
	if fc and fc:getAmount() <= EP.EPS then
		local liquid = liquidOption(context, worldobjects, object, sq, playerNum)
		if liquid then placeAtPlumbSlot(context, liquid) end
	end
end

--- PLUMB THE FIXTURE, WHERE VANILLA WILL NOT OFFER TO.
---
--- THE GAP THIS CLOSES, and it is a vanilla gate rather than anything of ours.
--- doWaterPipeMenu is only reached when fetch has filed the object under canBeWaterPiped,
--- and the branch that files a sink, bath, shower, toilet or washing machine reads
--- (ISWorldObjectContextMenuLogic.java:558-564):
---
---     props.has(IsoFlagType.waterPiped)
---       && !v.getUsesExternalWaterSource()
---       && v.getSquare().isInARoom() && v.FindExternalWaterSource() != null
---
--- Three of those four are satisfied in a player-built base the moment a mirror stands
--- over the fixture.  The fourth is not, and cannot be made to be: isInARoom() is
--- `getRoom() != null || getIsoWorldRegion().isPlayerRoom()` (IsoGridSquare.java:10429),
--- getRoom() answers for a MAP room or for one the engine synthesised, and isPlayerRoom()
--- is isFogMask() - `isEnclosed() && isFullyRoofed()`, and isFullyRoofed() is
--- `roofCnt == squareSize`, EVERY square (IsoWorldRegion.java:146-158).
---
--- So a structure the metagrid itself calls a building - vanilla's own test there is
--- enclosed and HALF roofed - is not a room to this test if one square of it is open to
--- the sky.  One connected unroofed square does it: a stairwell, a porch, a floor laid
--- outside a doorway.  And a base built against a map house has no synthesised room at
--- all, in any mode, because clientProcessBuildings discards the def and removeRoomDef
--- takes the IsoRoom with it.
---
--- The result was a mod that supplied the fixture and a game that would not let anybody
--- connect it: the barrels took the Plumb row, the sink did not, and there was no error
--- anywhere to say why.  That is the report this exists to answer.
---
--- VANILLA'S OWN ROW, VANILLA'S OWN ACTION, VANILLA'S OWN WORDS.  ContextMenu_PlumbItem
--- is the game's key, ISWorldObjectContextMenu.onPlumbItem is the game's handler, and
--- ISPlumbItem is the game's timed action - so this is the same wrench, the same hundred
--- ticks, the same flag at the end of it, and it costs no translation.  Nothing here
--- decides anything about water; it only offers a row the engine refused to offer for a
--- reason that is about roofing.
---
--- OFFERED ONLY WHERE VANILLA IS NOT, so there can never be two.  isInARoom() true is
--- vanilla's own case and this returns at once.
---
--- AND ONLY WHERE THERE IS SOMETHING TO PLUMB TO, which is vanilla's fourth condition
--- kept exactly as it is: FindExternalWaterSource() has to answer.  A wrench job that
--- connects a fixture to nothing is the dead option this mod refuses to offer anywhere.
---
--- Deliberately NOT narrowed to one of our own mirrors, and that was the first draft.  A
--- rain barrel standing directly above the sink is the commonest arrangement there is,
--- and in a player-built structure it is refused by the room test just as a mirror is - so
--- narrowing to mirrors would have left exactly the base people build unable to plumb
--- anything.  It is the same fixture, the same wrench and the same engine flag whichever
--- of the two is standing up there.
local function addRoomlessPlumbOption(context, worldobjects, object, playerNum)
	if not EP.getOption("Enabled") then return end
	if not EP.isPlumbableFixture(object) then return end
	if not context or not context.addOption then return end
	if object.getUsesExternalWaterSource == nil then return end
	if object:getUsesExternalWaterSource() then return end

	local sq = object:getSquare()
	if not sq then return end
	if sq:isInARoom() then return end
	if not EP.canServeHere(sq:getX(), sq:getY(), sq:getZ()) then return end

	if object.FindExternalWaterSource == nil then return end
	if object:FindExternalWaterSource() == nil then return end

	-- Vanilla's handler, probed for rather than assumed.  It is the whole of what the row
	-- does, so a build that has not got it must not get a row that silently does nothing.
	if type(ISWorldObjectContextMenu.onPlumbItem) ~= "function" then return end

	-- vanillaEntryName rather than getMoveableDisplayName straight, so a modded fixture with
	-- no CustomName gets the fallback vanilla's own menu would have given it instead of a row
	-- reading "Plumb ".
	local name = vanillaEntryName(object, false) or ""

	local opt = context:addOption(getText("ContextMenu_PlumbItem", name),
		worldobjects, ISWorldObjectContextMenu.onPlumbItem, playerNum, object)

	-- Greyed rather than hidden without a wrench, down to the key and the item name, which
	-- is exactly what doWaterPipeMenu does to its own row (:1527-1534).
	local playerObj = getSpecificPlayer(playerNum)
	if not EP.findPipeWrench(playerObj) then
		opt.notAvailable = true
		local tip = ISWorldObjectContextMenu.addToolTip()
		tip.name = getText("ContextMenu_PlumbItem", name)
		tip.description = getText("Tooltip_NeedWrench", getItemName("Base.PipeWrench"))
		opt.toolTip = tip
	end

	-- Vanilla sets this unconditionally on its plumb row; probed for, because a texture that
	-- is not there must not cost the option.
	if Texture and Texture.getSharedTexture then
		local icon = Texture.getSharedTexture("Item_PipeWrench")
		if icon then opt.iconTexture = icon end
	end

	placeAtPlumbSlot(context, opt)
end

--- PUT DRINK BACK ON A TAP VANILLA HAS DECIDED IS EMPTY.
---
--- `doDrinkWaterMenu` (ISWorldObjectContextMenuLogic.java:4325) gates on
--- `fluid ~= nil and fluid:isCategory(Beverage)`, and `fluid` is
--- `IsoObject.getPrimaryFluid()` - which on a plumbed fixture is read out of the purify
--- sample, and the sample is EMPTY for any fluid the engine has no `FluidType` constant
--- for.  So a cola tap offers no Drink at all, in Java, where no Lua override reaches.
---
--- AND THAT ABSENCE HAS BEEN HIDING A SECOND FAULT.  Drinking runs
--- `moveFluidToTemporaryContainer`, which is `transferFluidTo` three lines down, so it
--- would have destroyed the supply exactly the way filling a bottle does.  Two bugs
--- cancelling into one silent absence: nobody could report the drink being ruinous because
--- nobody was ever offered the drink.  The bypass in LGEPPlumbing covers both arms of
--- `ISTakeWaterAction:transferFluid`, which is what makes putting the row back safe.
---
--- THE HANDLER IS VANILLA'S OWN.  `ISWorldObjectContextMenu.onDrink` walks the player to the
--- object and queues `ISTakeWaterAction:new(playerObj, nil, waterObject, isTaintedWater())`.
--- Reusing it means the mask, the walk and the tainted flag are all whatever vanilla does
--- today, and it costs this mod no timed action of its own.  `ContextMenu_Drink` is
--- vanilla's key too, so the row needs no string in any of the 38 languages this ships in.
---
--- THE TWO GATES ARE COPIED FROM `doDrinkWaterMenu` RATHER THAN INVENTED, so a fixture this
--- mod offers Drink on is one vanilla would have offered it on if the sample had worked:
--- the same building as the player, and a Beverage.  The Beverage test is the one that
--- matters - without it a plumbed petrol tap would grow a Drink row that vanilla never had.
--- It is asked of the GHOST'S OWN container, which is a real FluidContainer and answers
--- correctly for every fluid; only the fixture's view through the sample is broken.
---
--- IT GOES WHERE VANILLA WOULD HAVE PUT IT, which is inside the sink's own submenu and
--- directly above Fill - not at the top level beside this mod's other rows.  A player
--- looking for Drink opens the tap's entry, and a row that is not there is not a row that
--- has moved somewhere more convenient.  `doWashClothingOrYourselfMenu` (:1329-1337) builds
--- that submenu and fills it in a fixed order:
---
---     doWashClothingMenu + doRecipeUsingWaterMenu   -- only when hasWater()
---     doDrinkWaterMenu
---     doFillFluidMenu
---
--- so "immediately before Fill" is vanilla's own position, and it stays right if another mod
--- has added rows of its own.  With no Fill row - the player is carrying nothing to fill -
--- appending is what vanilla's order comes to.
---
--- Both halves of hasWater() are false here by construction, so the Wash and Recipe rows
--- vanilla would have put above Drink are absent for a reason rather than by omission: a
--- tap this function fires on is serving something that is not water, and
--- `hasWater()` ends at `isAllCategory(FluidCategory.Water)`.  See
--- memory/fixtures-serve-any-fluid.
local function drinkOption(context, worldobjects, object, sq, playerNum)
	if not EP.getOption("FluidPatch") then return nil end

	local source = object:FindExternalWaterSource()
	local fc = source and source.getFluidContainer and source:getFluidContainer() or nil
	if not fc or fc:getAmount() <= EP.EPS then return nil end
	if not EP.containerNeedsBypass(fc) then return nil end

	local fluid = fc:getPrimaryFluid()
	if not fluid or not fluid:isCategory(FluidCategory.Beverage) then return nil end

	local playerObj = getSpecificPlayer(playerNum)
	if not playerObj then return nil end
	if sq:getBuilding() ~= playerObj:getBuilding() then return nil end

	-- The fixture's OWN top-level entry, found the way every other anchor in this file is
	-- found.  Two identical sinks on one square are two entries reading "Sink", and
	-- fluidBlockEntries claims each option once and pairs it with the object it was built
	-- for - so this is the right tap's submenu and not the first tap's.
	local anchor
	for _, entry in ipairs(fluidBlockEntries(context)) do
		if entry.object == object then anchor = entry.option; break end
	end
	if not anchor or not anchor.subOption then return nil end
	if not context.getSubMenu then return nil end

	local subMenu = context:getSubMenu(anchor.subOption)
	if not subMenu or type(subMenu.options) ~= "table" or not subMenu.addGetUpOption then
		return nil
	end

	local option = subMenu:addGetUpOption(getText("ContextMenu_Drink"), worldobjects,
		ISWorldObjectContextMenu.onDrink, object, playerNum)
	if not option then return nil end

	-- The amount vanilla's own Drink tooltip carries, in the liquid's own translated name -
	-- which `getFluidUiName()` cannot give here, because it reads the same empty sample the
	-- missing option does.  EP.fluidLabel needs no translation key in any language.
	local tip = ISWorldObjectContextMenu.addToolTip()
	tip.description = string.format("%s: %.2fL / %.2fL",
		EP.fluidLabel(EP.barrelFluidType(source) or EP.FLUID_DEFAULT),
		object:getFluidAmount(), object:getFluidCapacity())
	option.toolTip = tip

	local fillName = getText("ContextMenu_Fill")
	for i = 1, #subMenu.options do
		if subMenu.options[i] ~= option and subMenu.options[i].name == fillName then
			moveOptionTo(subMenu, option, i)
			break
		end
	end
	return option
end

--------------------------------------------------------------------------------
-- why there is no water (BR-LGEP-003)
--------------------------------------------------------------------------------

--- THIRTEEN PEOPLE, AND THE MOD ALWAYS KNEW THE ANSWER.
---
--- `refuse()` on the authority names the gate that turned a fixture down, and writes it to
--- the log, and only with Debug on.  On the player's screen there is NOTHING: no row, no
--- greyed row, no tooltip.  A sink with a rain barrel standing beside it looks exactly like
--- a sink with no barrel for a hundred tiles, and both look exactly like a mod that is
--- broken - which is how it has been reported, thirteen times, since 2026-08-14.
---
--- Measured on the engine, one tap and one full 200 L barrel, one thing changed at a time
--- (`lgep_probe_serve_matrix`).  FIVE separate causes, and the player is told nothing in
--- any of them:
---
---     barrel one floor UP, plumbed in, in a room        water
---     barrel on the SAME floor as the tap               nothing
---     barrel one floor BELOW                            nothing
---     barrel one floor up but NOT plumbed in            nothing
---     barrel one floor up but 14 tiles away (Reach 12)  nothing
---     barrel one floor up but the tap is in NO ROOM     nothing
---
--- Row two is the one that matters most: a barrel standing next to the sink is how most
--- people would build it, and it gives nothing, because gravity gives nothing on the same
--- floor and there is no pump.
---
--- WORKED OUT FROM THE SAME SCOPE THE MENU ALREADY HAS, so this costs one table walk and no
--- lookups: `scopeFor` is memoised for the menu and is what the liquid submenu is built
--- from.  And it is worked out in the SAME ORDER the authority's own gates are asked in -
--- `EP.canServeHere`, then `EP.isIncluded`, then `EP.canSupply`, then `EP.holdsFor` - so the
--- reason a player reads is the reason the server had, and not a second opinion that can
--- drift away from it.
---
--- Returns a translation key and its arguments, or nil when there is nothing to explain.
local function noSupplyReason(fx, fy, fz, want, fixture)
	if not EP.canServeHere(fx, fy, fz) then
		return "ContextMenu_LGEP_NoSupply_NoRoom"
	end

	local found = scopeFor(fx, fy, fz)
	if #found == 0 then
		-- NOT ON EVERY SINK IN KNOX COUNTY.  With a collector in scope there is something
		-- specific to say and the player is plainly trying; with NOTHING in scope the same
		-- row would appear on every untouched sink, bath and toilet in every house anybody
		-- ever right-clicks, which is clutter rather than an answer.
		--
		-- So it is said only where the fixture itself claims to be plumbed - it worked once,
		-- or vanilla plumbed it - which is the player who has lost something and is asking
		-- why.  Every other case below has a collector in scope and is always said.
		if not (fixture and fixture.getUsesExternalWaterSource
			and fixture:getUsesExternalWaterSource()) then
			return nil
		end

		-- AND REACH IS NOT THE BOUND INSIDE A BUILDING, so it must not be quoted there.
		--
		-- `EP.collectorsInScope` uses the dial only when the fixture resolves to NO building;
		-- with one it uses the building's own bounds and ignores Reach entirely, which the
		-- sandbox tooltip already says ("Inside a real building the whole building is used and
		-- this does nothing"). Quoting "within 12 tiles" at a sink in a Muldraugh house whose
		-- barrels have been taken away tells the player to raise Reach - which is the advice
		-- every one of BR-LGEP-003's thirteen reporters was given, and it changes nothing,
		-- because the number was never the bound. A row with the wrong reason is worse than no
		-- row, and that is this row's own charter.
		if EP.buildingAt and EP.buildingAt(fx, fy, fz) then
			return "ContextMenu_LGEP_NoSupply_NoneHere"
		end
		return "ContextMenu_LGEP_NoSupply_None", tostring(EP.getOption("Reach"))
	end

	local plumbed, reaching, liquids = 0, 0, {}
	for i = 1, #found do
		local entry = found[i]
		if EP.isIncluded(entry.object) then
			plumbed = plumbed + 1
			if EP.canSupply(entry.object, entry.z, fz) then
				reaching = reaching + 1
				local own = EP.barrelFluidType(entry.object)
				if own then liquids[own] = true end
			end
		end
	end

	if plumbed == 0 then
		return "ContextMenu_LGEP_NoSupply_NotPlumbed", tostring(#found)
	end
	if reaching == 0 then
		return "ContextMenu_LGEP_NoSupply_Gravity", tostring(plumbed)
	end

	-- Something is plumbed in and can reach, so what is left is what it is holding.  Named
	-- rather than counted: "they hold whiskey and you asked for water" is the whole answer,
	-- and a number would not add to it.
	local names = {}
	for liquid in pairs(liquids) do names[#names + 1] = EP.fluidLabel(liquid) end
	table.sort(names)

	-- EMPTY AND UNCLAIMED IS STILL A REASON, and it used to be the one case this function
	-- answered with silence.
	--
	-- `liquids` is filled from `EP.barrelFluidType`, which is **nil** for an empty barrel that
	-- has never been told what it holds - water is deliberately never written. So a fixture
	-- pointed at any non-water liquid, over plumbed collectors that all reach it and are all
	-- dry, produced no names and returned nil. The caller's own early-out does not fire either,
	-- because `EP.holdsFor(nil, want)` is false for a non-water `want`, so the group is empty.
	--
	-- Take the whiskey barrel away and leave the rain barrels: a tap that pours nothing, and
	-- the function written to end BR-LGEP-003 saying nothing at all. It is the fifth cause the
	-- header claims to enumerate and the table never had.
	if #names == 0 then
		return "ContextMenu_LGEP_NoSupply_Empty", tostring(reaching), EP.fluidLabel(want)
	end
	return "ContextMenu_LGEP_NoSupply_Liquid",
		table.concat(names, ", "), EP.fluidLabel(want)
end

--- The red row (`notAvailable`, drawn in the game's bad-highlight color), where a player is
--- looking when they wonder why the tap is dry. Red because the tap cannot pour: this row is
--- the one place the mod shows a red row that is not an action, and it is there on purpose.
---
--- ONLY WHERE THE MENU WOULD OTHERWISE SAY NOTHING.  A fixture vanilla is already serving
--- from a real barrel overhead is vanilla's business and gets no row; one this mod is
--- serving has its own liquid row instead.  So this appears exactly when a player has a
--- fixture that gives them no water and no explanation, which is the complaint.
local function addNoSupplyReason(context, worldobjects, object, playerNum)
	if not EP.getOption("Enabled") then return end
	if not EP.isPlumbableFixture(object) then return end
	if not context or not context.addOption then return end

	local sq = object:getSquare()
	if not sq then return end

	-- Already served, by us or by vanilla: there is nothing to explain.
	--
	-- AN AWAKE MIRROR IS NOT A SERVED TAP WHEN IT HOLDS NOTHING. Empty barrels still hold
	-- "nothing yet", which `EP.holdsFor` counts as water, so they form a group and the
	-- mirror stays awake over them. Returning on "awake" alone skipped the commonest dry tap
	-- of all, the one under barrels it has not rained into (2026-09-30, lgep_spec_whydry
	-- case 8). `getFluidAmount` on a plumbed fixture is its source's amount
	-- (IsoObject.getFluidAmount, the usesExternalWaterSource branch), so it reads the mirror.
	local source = object.FindExternalWaterSource and object:FindExternalWaterSource()
	if source and not EP.isGhost(source) then return end
	if source and EP.isGhost(source) and not EP.isDormant(source)
		and object:getFluidAmount() > EP.EPS then return end

	local fx, fy, fz = sq:getX(), sq:getY(), sq:getZ()
	local want = EP.fixtureFluidType(object)

	-- THE ROOM GATE IS ASKED FIRST, in the authority's own order, and that ordering is the
	-- whole of whether this row is ever right.  `serviceFixture` refuses on `canServeHere`
	-- BEFORE it walks for a group; asking "can this client see a group" first instead reads
	-- a barrel standing in range of a tap in open ground as a supply, and says nothing -
	-- which is precisely the tap the player is asking about.
	local key, a, b
	if not EP.canServeHere(fx, fy, fz) then
		-- Same rule as the empty-scope case below: a fixture standing in the open with
		-- nothing near it and nothing plumbed to it is not a player asking a question.
		if #scopeFor(fx, fy, fz) == 0
			and not (object.getUsesExternalWaterSource and object:getUsesExternalWaterSource()) then
			return
		end
		key = "ContextMenu_LGEP_NoSupply_NoRoom"
	else
		-- A group this client can see WITH SOMETHING IN IT means the answer is on its way;
		-- saying no now would be wrong within a tick, which is worse than saying nothing.
		-- A group holding nothing is the opposite: every gate passed and there is nothing to
		-- pour, and that is a reason like any other.
		--
		-- Not covered: a supply that reaches this tap only by pipe. `pipeFixtureServesVisible`
		-- answers yes or no and nothing about what the net holds, so an empty piped supply
		-- still gets no row.
		local group = EP.groupFrom(scopeFor(fx, fy, fz), fz, want)
		if #group > 0 then
			if EP.groupTotals(group) > EP.EPS then return end
			key, a, b = "ContextMenu_LGEP_NoSupply_Empty", tostring(#group), EP.fluidLabel(want)
		else
			if EP.pipeFixtureServesVisible and EP.pipeFixtureServesVisible(fx, fy, fz, want) then return end
			key, a, b = noSupplyReason(fx, fy, fz, want, object)
		end
	end
	if not key then return end

	-- The row says which kind of dry it is. "No supply reaches this" is false of a supply
	-- that reaches and is empty, and the tooltip under it says they reach.
	local label = key == "ContextMenu_LGEP_NoSupply_Empty"
		and "ContextMenu_LGEP_NoSupplyEmpty" or "ContextMenu_LGEP_NoSupply"
	local opt = context:addOption(getText(label), worldobjects, nil)
	if not opt then return end
	opt.notAvailable = true

	local tip = ISWorldObjectContextMenu.addToolTip()
	tip.description = getText(key, a, b)
	opt.toolTip = tip

	placeAtPlumbSlot(context, opt)
end

local function addFixtureOptions(context, worldobjects, object, placed, playerNum)
	if not EP.isPlumbableFixture(object) then return end
	if not context or not context.addOption or not context.addSubMenu then return end

	local sq = object:getSquare()
	if not sq then return end
	-- The same gate the server serves by; see the note in ensureLocalStandIn.
	if not EP.canServeHere(sq:getX(), sq:getY(), sq:getZ()) then return end

	-- Plumbed, and plumbed to US.  See the note above.
	if not object:getUsesExternalWaterSource() then return end
	local source = object:FindExternalWaterSource()
	if not source or not EP.isGhost(source) then return end

	-- Its own row, in vanilla's own place: drinkOption puts it inside the sink's submenu
	-- above Fill, so it needs no placement here and must not be given one.
	drinkOption(context, worldobjects, object, sq, playerNum)

	local option = liquidOption(context, worldobjects, object, sq, playerNum)
	if not option then return end

	-- Last, so that everything above it has already happened.  The submenu is bound
	-- to the option by `option.subOption = menu.subOptionNums` (ISContextMenu.lua:1075)
	-- and resolved back through the player's context menu rather than by position
	-- (:1226-1232), so moving the option carries its submenu with it.
	placeBelowFixture(context, option, object, placed)
end

--- The three reported-once flags that used to live here are now EP.logFault keys -
--- "client-collector-options", "client-fed-options" and "client-fixture-liquids" - and the
--- reason they are three and not one is unchanged.  They used to share one flag, and that
--- is how a collector failing on some unrelated object could silence a fixture's report for
--- the rest of the session, so the white-sink bug produced no log line at all while it was
--- being looked for.  A latch may only ever silence the thing it is about, which is why
--- EP.logFault latches per SITE and never globally.
--- WHY THIS LIST IS NOT THE ONE prepareMenu HANDED OVER
---
--- `worldobjects` is not ours and is not vanilla's untouched either.  Vanilla raises
--- OnFillWorldObjectContextMenu once, and every handler registered on it sees the
--- SAME table - so a handler that ran earlier and appended to it has changed what
--- every later one reads.  Vanilla itself does this:
---
---     -- AdminContextMenu.lua:22-35
---     if not (isClient() and (isAdmin() or getAccessLevel() == "moderator")) then return true end
---     ...
---     for i=1,square:getObjects():size() do
---         table.insert(worldobjects, square:getObjects():get(i-1))
---     end
---     worldobjects = removeDuplicates(worldobjects)     -- rebinds the local ONLY
---
--- The last line looks like it undoes the loop and does not: it rebinds the local
--- name, and the caller's table keeps every object that was pushed into it.  Vanilla
--- knows this is a bug - DebugContextMenu.lua does the identical thing with an
--- explicit `worldobjects = copyTable(worldobjects)` above it and the comment "Avoid
--- changing the passed-in table" - AdminContextMenu is the copy that forgot it.  And
--- because LoadDirBase appends every mod file after every vanilla one, that handler
--- is always registered before ours and always runs first.
---
--- Two consequences, and the second is the one that produced a bug report:
---
---   * the list can hold every object on the clicked square, including ones
---     prepareMenu deliberately filtered out on the way in
---   * it only happens for an ADMIN - which on a hosted co-op game is the host, by
---     construction, and nobody else.  So the host loses this mod's options and
---     their friends do not, and it looks like a multiplayer bug.
---
--- An error thrown here is not a visible failure either.  Event.java wraps each
--- callback in protectedCallVoid and logs, so the handler simply stops: our options
--- are missing, everyone else's are built, and nothing tells the player why.
---
--- So each object is asked about on its own, behind its own pcall, and anything with
--- no sprite name is declined before it is touched - the same test stripGhostsFromFetch
--- applies to the fetch buckets, which is where the identical object took the WHOLE
--- menu down.  One bad object now costs one option.
--------------------------------------------------------------------------------
-- a supply too big for vanilla's tooltip
--------------------------------------------------------------------------------

--- WHY A TAP OVER 10,000 LITRES SAYS "UNLIMITED" AND HOW MUCH OF IT IS A LIE.
---
--- Vanilla formats a water tooltip like this:
---
---     private static String formatWaterAmount(IsoObject object, float amount, float max) {
---        return max >= 9999.0F
---           ? String.format("%s: %s", object.getFluidUiName(), getText("Tooltip_WaterUnlimited"))
---           : String.format("%s: %.2fL / %.2fL", object.getFluidUiName(), amount, max);
---     }
---         -- ISWorldObjectContextMenuLogic.java:4302
---
--- It branches on the CAPACITY and never looks at the amount, because 9999 is vanilla's
--- sentinel for "this is a water tile or a mains pipe" - `WaterAmount` is 9999 on water
--- and 10000 on piped water, per its own comment in ISWorldObjectContextMenu.lua.
---
--- A collective supply collides with that honestly.  A mirror's capacity is the sum of its
--- group, so a building with twenty-five 400-litre collectors really does have 10,000
--- litres of capacity - and a tap over it then reported "Unlimited" while holding thirty
--- litres, which is misleading in the one direction that matters.  Reported from a base
--- with 18,000 litres of barrels and 30 litres of water in them.
---
--- ONLY THE LABEL IS WRONG.  IsoObject.isWaterInfinite() reads the SPRITE's WaterAmount
--- property, or the un-plumbed branch, and never the container's capacity - so nothing
--- treats the supply as infinite and the water still drains exactly as it should.  Which
--- is why this is fixed here, in the menu, and nothing touches the capacity itself: a cap
--- on the mirror would be a number the water actually moves through.
---
--- The one thing besides the label that the sentinel really does change is vanilla hiding
--- the tap's *Empty* option above 9999 (`:4228`).  Left alone: emptying a building's
--- entire water supply from a tap by accident is not an option worth restoring.
local UNLIMITED = "Tooltip_WaterUnlimited"

--- Rewrite one option's tooltip, if it is a Drink option whose object trips the sentinel.
---
--- The object comes off the option rather than being guessed.  Vanilla builds the entry as
--- `addGetUpOption(getText("ContextMenu_Drink"), worldobjects, onDrink, object, player)`,
--- and ISContextMenu.addGetUpOption forwards to
--- `addOption(text, self, onGetUpAndThen, onSelect, target, p2, ...)` - so the IsoObject
--- lands in `param3`.  Taking it from there is what makes this correct when a menu holds
--- two taps: each option is repaired against its own object, not against whichever
--- fixture happened to be under the cursor.
---
--- Every step is guarded and every failure leaves the tooltip exactly as vanilla wrote it.
--- A wrong answer here is a cosmetic line; a throw would take every mod's entries
--- registered after this one down with it.
local function repairUnlimited(option)
	if type(option) ~= "table" then return end

	local tip = option.toolTip
	if not tip or type(tip.description) ~= "string" then return end

	local unlimited = getText(UNLIMITED)
	if type(unlimited) ~= "string" or unlimited == "" then return end

	-- Plain find, not a pattern: the localised string is somebody else's text and may
	-- hold a hyphen, a bracket or a percent in any of the languages this ships in.
	local at = string.find(tip.description, unlimited, 1, true)
	if not at then return end

	local object = option.param3
	if type(object) ~= "table" and type(object) ~= "userdata" then return end
	if not object.getFluidCapacity or not object.getFluidAmount then return end

	-- Ours, and only ours.  A real water tile or a mains pipe says Unlimited because it
	-- IS unlimited, and rewriting that would be inventing a number.
	if not object.getUsesExternalWaterSource or not object:getUsesExternalWaterSource() then return end
	local source = object.FindExternalWaterSource and object:FindExternalWaterSource()
	if not source or not EP.isGhost(source) then return end

	local capacity = object:getFluidCapacity()
	local amount = object:getFluidAmount()
	if type(capacity) ~= "number" or type(amount) ~= "number" then return end
	if capacity < 9999 then return end

	tip.description = string.sub(tip.description, 1, at - 1)
		.. string.format("%.2fL / %.2fL", amount, capacity)
		.. string.sub(tip.description, at + string.len(unlimited))
end

--- Every option in the menu and its submenus.
---
--- The Drink entry for a plumbed fixture is not at the top level: a sink has no
--- FluidContainer component of its own, so `fetch` files it under `storeWater` only, and
--- doStoreWaterMenu puts Drink inside a submenu titled after the object
--- (ISWorldObjectContextMenuLogic.java:1336).  Walking the tree rather than matching that
--- title is what keeps this working when the title is a display name in another language.
---
--- `option.subOption` is a NUMBER, not the submenu.  `ISContextMenu.addSubMenu` stores
--- `menu.subOptionNums` on the option and `getSubMenu(num)` resolves it back through
--- `getPlayerContextMenu(player):getSubInstance(num)` - which is the same pair
--- collectorSubMenu above already goes through, and the trap that would have made this
--- walk silently visit nothing.
---
--- Depth-limited, because this walks a structure another mod may also have been editing
--- and a cycle would hang the menu rather than break it.
local function repairUnlimitedIn(context, depth)
	if not context or depth > 4 then return end

	local options = context.options
	if type(options) ~= "table" then return end

	for i = 1, #options do
		local option = options[i]
		repairUnlimited(option)
		if option and option.subOption and context.getSubMenu then
			local sub = context:getSubMenu(option.subOption)
			if sub and sub ~= context then repairUnlimitedIn(sub, depth + 1) end
		end
	end
end

--------------------------------------------------------------------------------
-- pipes: the way into the window
--------------------------------------------------------------------------------

--- Open the piped-area window.  Declared above the row that calls it, because a local
--- function called from above its declaration is a nil call the menu's pcall swallows.
local function onShowPipedArea(_worldobjects, source, playerNum)
	local playerObj = getSpecificPlayer(playerNum)
	if not playerObj or not EP.showPipedArea then return end
	EP.showPipedArea(playerObj, source)
end

--- SHOW PIPED AREA, the last row of the barrel's own submenu.
---
--- On EVERY collector, plumbed or not and in a building or not - unlike the rows above it,
--- which are about joining a supply.  A barrel standing in a field is exactly the one a
--- player wants to run a pipe to, and the window is the only place a pipe can be laid.
--- The barrel is the gate and nothing more: the window is about where the player stands.
---
--- LAST, under everything that does something to the barrel, because this only looks.
--- Its own pcall at the call site and its own fault key.
local function addPipedAreaOption(context, worldobjects, object, playerNum)
	if not object:getSquare() or not EP.isWaterSource(object) then return end
	local menu = collectorSubMenu(context, object) or context
	local opt = menu:addOption(getText("ContextMenu_LGEP_ShowPipedArea"),
		worldobjects, onShowPipedArea, object, playerNum)
	local tip = ISWorldObjectContextMenu.addToolTip()
	tip.description = getText("ContextMenu_LGEP_ShowPipedArea_tooltip")
	opt.toolTip = tip
end

local function fillMenu(player, context, worldobjects, test)
	if test then return end
	if not EP.getOption("Enabled") then return end

	-- Before this mod's own entries, so a throw in the repair cannot cost the liquid
	-- submenu; it has its own pcall at the call site below.
	repairUnlimitedIn(context, 1)

	-- The SQUARES the right-click was about, not the list the caller happened to
	-- build -- see objectsInMenu.  A collector is almost never in `worldobjects` on
	-- a gamepad, so scanning that list directly was a barrel with no rows on a pad
	-- and every row on a mouse. Already deduplicated, and nameless objects (our own
	-- mirrors among them) are already out.
	for _, object in ipairs(objectsInMenu(worldobjects)) do
		local ok, err = pcall(addCollectorOptions, context, worldobjects, object, player)
		if not ok then
			EP.logFault("client-collector-options",
				"ERROR offering a collector's options: " .. tostring(err))
		end

		-- Its OWN pcall and its own logFault KEY, and not folded into the call above.
		-- The two never both answer for one object - the list is consulted at the foot
		-- of EP.isWaterSource, so exactly one of them can - but sharing a key would
		-- mean a collector throwing silenced every later report about a dispenser, which
		-- is precisely how the white-sink fault stayed invisible in the logs while
		-- somebody was hunting it.
		local fok, ferr = pcall(addFedOptions, context, worldobjects, object, player)
		if not fok then
			EP.logFault("client-fed-options",
				"ERROR offering a topped-up fixture's options: " .. tostring(ferr))
		end

		local sok, serr = pcall(addPipedAreaOption, context, worldobjects, object, player)
		if not sok then
			EP.logFault("client-piped-area-option",
				"ERROR offering Show piped area: " .. tostring(serr))
		end
	end

	-- Fixtures are found by walking the square rather than by filtering the list
	-- above; see fixturesInMenu.  Its own pcall, and its own logFault key: a
	-- collector throwing must not silence a fixture's report, which is how the
	-- white-sink bug stayed invisible in the logs while it was being hunted.
	-- One per menu, not one per fixture: it is how a fixture that found no anchor of
	-- its own keeps its place relative to the one before it.  See placeBelowFixture.
	local placed = {}
	for _, fixture in ipairs(fixturesInMenu(worldobjects)) do
		-- Its own pcall and its own key for the same reason as every other row here: the
		-- Plumb row and the liquid row are about the same fixture and answer in opposite
		-- states - one before it is plumbed, one after - so a throw in either must not cost
		-- the other, and a latch must not silence a report it is not about.
		local pok, perr = pcall(addRoomlessPlumbOption, context, worldobjects, fixture, player)
		if not pok then
			EP.logFault("client-roomless-plumb",
				"ERROR offering a fixture's plumb row: " .. tostring(perr))
		end

		local fok, ferr = pcall(addFixtureOptions, context, worldobjects, fixture, placed, player)
		if not fok then
			EP.logFault("client-fixture-liquids",
				"ERROR offering a fixture's liquids: " .. tostring(ferr))
		end

		-- WHY THERE IS NO WATER (BR-LGEP-003).  Last, so it lands under the rows a served
		-- fixture has and is the only thing an unserved one shows.  Its own fault site: a
		-- throw here must not take the liquid rows with it, and the other way round.
		local nok, nerr = pcall(addNoSupplyReason, context, worldobjects, fixture, player)
		if not nok then
			EP.logFault("client-no-supply-reason",
				"ERROR saying why a fixture has no supply: " .. tostring(nerr))
		end
	end
end

--- Guarded, for the same reason the createMenu wrapper above is guarded and with the
--- same trade.  Every mod's entries share this one event, and an error thrown out of
--- a handler stops the ones registered after it from ever running - so a mistake here
--- would read to a player as some other mod being broken.  If this fails, the cost is
--- our own two options missing from one menu.
Events.OnFillWorldObjectContextMenu.Add(function(player, context, worldobjects, test)
	local ok, err = pcall(fillMenu, player, context, worldobjects, test)
	if not ok then
		EP.logFault("client-add-collector-options", "ERROR adding collector options: " .. tostring(err))
	end
end)

--------------------------------------------------------------------------------
-- pipes: what the server says
--------------------------------------------------------------------------------

--- Whether this machine has ever been sent the pipe set.  An empty set is an answer, so
--- "nothing laid" cannot be told from "never heard" by looking at EP.floorPipes.
local pipesHeard = false

--- How long the ask loop below has waited and how many times it has asked.  Declared here
--- rather than beside the loop because the area-result handler above re-arms them when it
--- sees a newer generation, and a local declared further down would be a different local.
local pipeWaited, pipeAsked = 0, 0

--- THE ONLY OnServerCommand HANDLER THIS MOD HAS, and it is about pipes because pipes are
--- the first thing here the server has to TELL a client rather than let an object carry.
--- Every command routes from this one handler, so a second file cannot start swallowing
--- the first one's - the rule LGEE learned.  Each in its own pcall and its own fault key.
Events.OnServerCommand.Add(function(module, command, args)
	if module ~= EP.COMMAND_MODULE then return end

	if command == EP.COMMAND_PIPES then
		-- IN PARTS WHEN THE SERVER'S SET IS BIG (BR-LGEE-025).  A part on its own is not an
		-- answer and must not be read as one: `assemblePacket` hands back nil until the last
		-- of them lands, and hands back the packet itself when there was only ever one.
		--
		-- `pipesHeard` is only set once a WHOLE set has arrived, so the ask timer keeps
		-- asking while parts are still missing rather than going quiet on half a set.
		local ok, err = pcall(function()
			local whole = EP.assemblePacket(command, args, EP.PIPE_SET_FIELDS)
			if not whole then return end
			EP.receivePipeSet(whole)
			pipesHeard = true
		end)
		if not ok then EP.logFault("client-pipes", "ERROR taking in the pipe set: " .. tostring(err)) end
	elseif command == EP.COMMAND_PIPE_AREA_RESULT then
		if EP.onPipeAreaResult then
			local ok, err = pcall(function()
				local whole = EP.assemblePacket(command, args, EP.PIPE_AREA_FIELDS)
				if whole then
					-- THE ANSWER SAYS WHICH GENERATION THE AUTHORITY IS ON, so it is also how
					-- a client finds out its own copy of the SET is behind.
					--
					-- `pipesHeard` is latched on the first whole set and the ask loop returns
					-- for ever after it, so a broadcast that is lost - or dropped by the
					-- assembler, which has five paths that return nil - left the client on a
					-- stale set until the ten-minute heartbeat. That is BR-LGEP-041's symptom
					-- without BR-LGEP-041's cause: lifted pipes still drawn, a pipe just laid
					-- missing, and a tap on the new run refused.
					--
					-- Nothing compared the two generations, so the client could not tell it was
					-- behind and could not ask. Now it can.
					local gen = tonumber(whole.gen)
					if gen and EP.pipeGeneration and gen > EP.pipeGeneration then
						pipesHeard = false
						pipeAsked = 0
						pipeWaited = 0
					end
					EP.onPipeAreaResult(whole)
				end
			end)
			if not ok then EP.logFault("client-pipe-area", "ERROR reading the piped area: " .. tostring(err)) end
		end
	elseif command == EP.COMMAND_PIPE_DONE then
		if EP.onPipeDone then
			local ok, err = pcall(EP.onPipeDone, args)
			if not ok then EP.logFault("client-pipe-done", "ERROR hearing a pipe answer: " .. tostring(err)) end
		end
	end
end)

--- ASK FOR THE SET, FROM OnTick AND NOT FROM OnGameStart.  A client command sent from
--- OnGameStart goes down the singleplayer loopback to nobody - GameClient.ingame is not
--- set until the first update (memory/ongamestart-cannot-send-client-commands.md).  Asked
--- until answered, fast then slow, then it stops and says so.  In seconds, through
--- EP.ticksFor, so a struggling client does not also wait longer.
local PIPE_ASK_FAST, PIPE_ASK_SLOW = 0.5, 10
local PIPE_FAST_TRIES, PIPE_MAX_TRIES = 10, 40

Events.OnTick.Add(function()
	if pipesHeard or pipeAsked >= PIPE_MAX_TRIES then return end
	if not EP.isNetworkClient() then return end

	pipeWaited = pipeWaited + 1
	local wait = pipeAsked < PIPE_FAST_TRIES and PIPE_ASK_FAST or PIPE_ASK_SLOW
	if EP.ticksFor and pipeWaited < EP.ticksFor(wait) then return end
	pipeWaited = 0
	pipeAsked = pipeAsked + 1

	local ok, err = pcall(sendClientCommand, EP.COMMAND_MODULE, EP.COMMAND_PIPE_HELLO, {})
	if not ok then
		pipeAsked = PIPE_MAX_TRIES
		EP.logFault("client-ask-pipes", "ERROR asking the server for the pipe set: " .. tostring(err))
	elseif pipeAsked >= PIPE_MAX_TRIES then
		EP.log("the server has not sent the pipe set after " .. PIPE_MAX_TRIES .. " requests")
	end
end)

--- A set left over from a previous session is another world's coordinates.
Events.OnGameStart.Add(function()
	if not EP.isNetworkClient() then return end
	EP.floorPipes, EP.wallPipes, EP.pipeNets, EP.pipeDefNet = {}, {}, {}, {}
	pipesHeard, pipeWaited, pipeAsked = false, 0, 0

	-- AND THE HALF-ARRIVED PACKETS, which this had always left behind.
	--
	-- `EP.forgetPacketAssembly` was written with a header naming exactly what it prevents - an
	-- authority restarting `EP.packetSerial` under clients' live `assembledSet` values, after
	-- which every set is dropped as stale - and then nothing called it. Four separate passes of
	-- the 2026-09-17 audit found it unwired. Its own note says not to rest on
	-- `IngameState.exit()` rebuilding the Lua environment, and then rested on it.
	if EP.forgetPacketAssembly then EP.forgetPacketAssembly() end
end)

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
--
-- The `else` is not defensive tidiness, it is the direction the fault actually came in:
-- the reported install had the NEW server file and an OLD shared one, so the core is the
-- half that has no checkBuild in it and a bare `if EP.checkBuild then` would have said
-- nothing in exactly the case this exists for.  Printed directly there because EP.logFault
-- is in the same file that is missing.
if EP.checkBuild then
	EP.checkBuild("LGEPClient.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPClient.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
