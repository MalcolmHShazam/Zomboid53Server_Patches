--
-- Extended Plumbing - noticing the power the moment it moves.
--
-- A collector standing on a powered square is a pump: it can push water to its
-- own floor and above instead of only downhill.  EP.isPumped answers that live,
-- so the rule is never stale -- but the *decision* built on it only runs when
-- something triggers it, and switching a generator on is not one of the things
-- that did.  A player could start a generator beside a barrel and nothing would
-- happen until they right-clicked a fixture.
--
-- There is no OnGeneratorToggled event to hook.  Whole registry check:
-- LuaEventManager declares nothing for generators, power or the shutoff, and the
-- events.tsv dump agrees.  So the deliberate acts are caught by wrapping the two
-- timed actions that perform them, and everything else -- fuel running out, the
-- generator breaking, the town supply reaching its shutoff day -- is caught by
-- the pump-state comparison in the sweep, which watches for the change rather
-- than polling a decision.
--
-- Shared rather than client, deliberately.  LuaTimedActionNew.complete() is
-- wrapped in `if (!GameClient.client)`, so on a multiplayer client the Lua
-- complete never runs at all; the server rebuilds the action through
-- NetTimedAction and completes it there.  Loading this on the server is what
-- makes the hook fire on the side that owns the decision.  In singleplayer it
-- runs locally, which is the same side.
--

require "LGExtendedPlumbing/LGEPGhost"

-- Guarded, but NOT because require re-executes: it does not.  RunLuaInternal
-- returns early on `loaded.contains(filename)` (LuaManager.java:1344-1347), and
-- although :1351 reassigns filename through ZomboidFileSystem.getString before
-- `loaded.add` at :1392, getString (ZomboidFileSystem.java:322-339) maps any path
-- to the same canonical absolute string out of activeFileMap and is idempotent -
-- so the key written is the key checked.  The boot loader passes
-- getAbsolutePath(rel) (:1204) and require passes getString(getAbsolutePath(rel))
-- (:5661-5672), which land on that one key.  Requiring an already-loaded file is
-- a no-op.
--
-- Worth being exact about, because the opposite was written here for a long time
-- and it is a plausible-sounding claim: ISActivateGenerator.lua does open with
-- `ISActivateGenerator = ISBaseTimedAction:derive("ISActivateGenerator")`, a
-- brand new table that would throw away every wrapper already applied.  Only the
-- `loaded` check stops it, not anything in the file itself.
--
-- Extended Electricity wraps the same two actions.  Load order puts this file
-- first, so ours is the inner wrapper and theirs the outer; both capture and call
-- through, so both survive and neither guard is what makes that true.
--
-- LoadDirBase runs every vanilla file of a folder before any mod's file of that
-- folder - game files sorted, mod files appended after them - and these two live
-- in shared/TimedActions, so by the time this runs the table is always there.
-- The require stays as the answer to it one day not being.
if not ISActivateGenerator then require "TimedActions/ISActivateGenerator" end
if not ISPlugGenerator then require "TimedActions/ISPlugGenerator" end

local EP = LGEP

--- Re-decide everything that could have been feeding off this generator.
---
--- serviceAround already notices the ground first and then re-services every
--- fixture it knows about, so a generator started anywhere in a building re-points
--- that building's fixtures whether or not the barrel was the one nearest to it.
local function powerChanged(generator, what)
	if not EP.isAuthority() then return end
	if not EP.getOption("Enabled") then return end
	-- Lives in the server file; a client loads this one and never gets that far,
	-- but load order between the two folders is not promised, so ask.
	if not EP.reviewPumps then return end

	local square = generator and generator:getSquare()
	if not square then return end

	EP.log(("generator %s at %d,%d,%d; re-checking the pumps"):format(
		what, square:getX(), square:getY(), square:getZ()))

	-- Every collector, not the ones near this generator.  A generator stands where
	-- it stands; which collectors it powers is a question about squares, and
	-- reviewPumps asks that of each one directly and then walks the mirrors those
	-- collectors actually feed.  Measuring a box from the generator got this wrong.
	EP.reviewPumps()
end

--- Turning one on or off.
--- CHECKED, LIKE EVERY OTHER WRAP IN THIS MOD.  The guard above covers the TABLE and not the
--- method, and this was the one capture site that did not test what it got - so a build that
--- renames `complete`, or a mod that re-derives `ISActivateGenerator` before this file runs
--- (which resolves `.complete` through the metatable to `ISBaseTimedAction.complete`), gave a
--- wrong or nil inner function and the player's generator switch threw or did nothing.
---
--- AND THE FAULT IS REPORTED.  These two `pcall`s discarded the error outright: no
--- `EP.logFault`, no line even with Debug on, alone among this mod's wrappers. `powerChanged`
--- reaches `EP.reviewPumps`, which raises a latch - so a throw here used to be both silent
--- and permanent.
local vanillaActivate = type(ISActivateGenerator.complete) == "function"
	and ISActivateGenerator.complete or nil

local function announcePower(generator, what)
	local ok, err = pcall(powerChanged, generator, what)
	if not ok then
		EP.logFault("power-changed",
			("ERROR reacting to a generator being %s: %s"):format(what, tostring(err)))
	end
end

if vanillaActivate then
function ISActivateGenerator:complete()
	local ok = vanillaActivate(self)
	-- After the vanilla body, never before: setActivated has to have happened or
	-- isPumped would still be reading the old state.
	announcePower(self.generator, self.activate and "started" or "stopped")
	return ok
end
end

--- Connecting or disconnecting one changes which squares it reaches, which is the
--- same question asked a different way.
local vanillaPlug = type(ISPlugGenerator.complete) == "function"
	and ISPlugGenerator.complete or nil

if vanillaPlug then
function ISPlugGenerator:complete()
	local ok = vanillaPlug(self)
	announcePower(self.generator, self.plug and "connected" or "disconnected")
	return ok
end
end


-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
--
-- The `else` is not defensive tidiness, it is the direction the fault actually came in:
-- the reported install had the NEW server file and an OLD shared one, so the core is the
-- half that has no checkBuild in it and a bare `if EP.checkBuild then` would have said
-- nothing in exactly the case this exists for.  Printed directly there because EP.logFault
-- is in the same file that is missing.
if EP.checkBuild then
	EP.checkBuild("LGEPPower.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPPower.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
