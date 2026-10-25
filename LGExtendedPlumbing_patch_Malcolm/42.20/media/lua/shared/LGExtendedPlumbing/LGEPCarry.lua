--
-- Extended Plumbing - what a thing forgets when somebody picks it up.
--
-- A BARREL CARRIED ACROSS TOWN ARRIVED STILL PLUMBED INTO THE HOUSE IT LEFT.
--
-- Everything this mod decides about an object is written into that object's modData:
-- KEY_INCLUDE is "somebody took a wrench to this barrel", KEY_RESERVE is "hold it
-- back", KEY_FLUID is "this tap draws whiskey".  Every one of them is a decision about
-- a thing standing in a particular building, and none of them survives that thing being
-- destroyed - which is what picking most objects up amounts to.
--
-- Except for an IsoThumpable, where vanilla copies the whole table onto the item and
-- puts it back on the other end:
--
--     -- ISMoveableSpriteProps.lua:1228, inside saveThumpableParameters
--     if _object:hasModData() then
--         _table.modData = copyTable(_object:getModData())
--     end
--
--     -- ISMoveableSpriteProps.lua:1244, inside restoreThumpableParameters
--     if type(modData.modData) == "table" then
--         for key,value in pairs(modData.modData) do
--             obj:getModData()[key] = value
--
-- And a rain collector IS an IsoThumpable - EP.isWaterSource tests for exactly that,
-- because IsoObject.FindWaterSourceOnSquare does.  So a barrel plumbed into one base,
-- emptied and carried to another came back down carrying the wrench mark, was adopted
-- into the new building's supply by nobody, and read as held-in-reserve there as well.
-- The same copy carries Extended Electricity's fuel-line flag, which that mod strips on
-- its own side for the same reason.
--
-- WHY THE ITEM AND NOT THE OBJECT.  The obvious place to wipe is the object on its way
-- off the square, and it is the wrong one twice over.  saveThumpableParameters runs
-- BEFORE the removal - the copy is already taken by the time OnObjectAboutToBeRemoved
-- is raised at :1406 - so a handler there is too late to stop it.  And the removal
-- handler in LGEPPlumbing.lua reads the object it is being told about, to work out which
-- mirrors could see it; blanking the object first would take that answer away.  So the
-- object goes to its grave exactly as it stood, and it is the COPY that is wiped.
--
-- BOTH ENDS, and the second is not redundant.  Wiping at pickup is what makes the item
-- in the rucksack clean, which is the honest state to save.  Wiping again at placement
-- is what covers an item that was picked up before this file existed, or by a build
-- without it - there is one sitting in somebody's storage unit right now, and it is
-- indistinguishable from a fresh one until it is put down.
--
-- KEY_HOLDS GOES WITH THE REST, which is worth saying out loud because it is the one key
-- that is a memory rather than a decision.  It records the last liquid a collector held,
-- and isFuelHolder-adjacent code reads it while the barrel is empty.  A barrel can only
-- be picked up empty - canPickUpMoveableInternal refuses one holding anything - so
-- forgetting is exactly right: what comes back down is a clean empty drum, and the first
-- thing poured into it claims it again through EP.rememberBarrelFluid.
--
-- Shared rather than client, deliberately.  Moveables are handled by whichever side the
-- player is on, and in singleplayer and on a co-op host that side is also the authority.
-- Nothing here needs to BE the authority - it edits a copy that belongs to whoever is
-- carrying it, sends no packet and touches no registry - so there is no isAuthority gate
-- and no server half.
--

require "LGExtendedPlumbing/LGEPCore"

-- Guarded, but not because require re-executes: it does not, and the note in
-- LGEPPower.lua has the whole account of why.  LoadDirBase runs every vanilla file of a
-- folder before any mod's file of it, so in the game this table is always already there;
-- the require is the answer to that one day not being true, and the harness's require is
-- a no-op by design, which is why installWraps below checks rather than assumes.
if not ISMoveableSpriteProps then require "Moveables/ISMoveableSpriteProps" end

local EP = LGEP

--------------------------------------------------------------------------------
-- which keys
--------------------------------------------------------------------------------

--- Every key this mod writes into modData, read off the constants rather than listed.
---
--- DERIVED ON PURPOSE.  A hand-kept list here is a second place to remember, and the
--- failure mode of forgetting is silent: a key added next year would go on riding across
--- town with no test able to notice, because a suite written against a list asserts the
--- list.  Every one of them is `EP.KEY_<something> = "LGEP<something>"` and always has
--- been, so the convention is the list.
---
--- KEY_FED is in here and is a SQUARE key rather than an object one, so it can never
--- appear in what this walks.  Left in rather than special-cased: an exception costs a
--- rule, and clearing a key that is never present costs one table read.
---
--- The two dead keys older builds wrote - LGEPSrcX/Y/Z and LGEPMain - are deliberately
--- NOT here, for the same reason nothing else touches them (see the note beside
--- KEY_PIPED).  Both only ever lived on a mirror, and nobody picks up a mirror.
---
--- Memoised, and the first call is a pickup rather than load: EP is fully populated by
--- then whatever order the shared folder happened to load in.
local carried = nil

local function carriedKeys()
	if carried then return carried end

	local found = {}
	for name, value in pairs(EP) do
		if type(value) == "string" and string.sub(name, 1, 4) == "KEY_" then
			found[#found + 1] = value
		end
	end
	carried = found
	return found
end

--- Take every one of this mod's marks off a modData table.  Returns how many went.
---
--- Cleared to nil rather than written false, like every write in this mod: what comes
--- out the other end is a table indistinguishable from one this mod has never seen.
function EP.stripCarriedState(data)
	if type(data) ~= "table" then return 0 end

	local keys = carriedKeys()
	local cleared = 0
	for i = 1, #keys do
		if data[keys[i]] ~= nil then
			data[keys[i]] = nil
			cleared = cleared + 1
		end
	end
	return cleared
end

--- An item's modData, and the nested copy of an object's that vanilla hides inside it.
---
--- Both, because they are two different tables and only one of them is read back:
--- restoreThumpableParameters spreads `modData.modData` onto the new object, and the
--- blanket copy thirty lines later (:2273-2282) puts the item's own top level on as
--- well.  Stripping the nested table IN PLACE is what makes the second one harmless -
--- it is the same table by reference, so it is already clean by the time it is copied.
function EP.stripCarriedItem(itemData)
	if not EP.getOption("Enabled") then return 0 end
	if type(itemData) ~= "table" then return 0 end

	return EP.stripCarriedState(itemData) + EP.stripCarriedState(itemData.modData)
end

--------------------------------------------------------------------------------
-- the two vanilla functions that carry it
--------------------------------------------------------------------------------

--- Wrapped rather than replaced, vanilla called on its own side of the strip, the
--- addition inside a pcall: none of this may ever be the reason a pickup fails.  A
--- player who cannot put their barrel down because this mod threw is worse off than one
--- whose barrel remembered the wrong house.
---
--- Installed ONCE.  Wrapping a wrapper would work - the strip is idempotent, a table
--- with nothing of ours in it is left alone - but it would log the same pickup twice,
--- and a flag that says what is intended costs nothing.
local installed = false

local function installWraps()
	if installed then return true end
	if type(ISMoveableSpriteProps) ~= "table" then return false end

	local save = ISMoveableSpriteProps.saveThumpableParameters
	local restore = ISMoveableSpriteProps.restoreThumpableParameters
	if type(save) ~= "function" or type(restore) ~= "function" then return false end

	installed = true

	--- INTO the inventory.  After the vanilla body, necessarily: the copy this is here
	--- to clean does not exist until it has run.
	function ISMoveableSpriteProps:saveThumpableParameters(_table, _object)
		local result = save(self, _table, _object)

		local ok, cleared = pcall(EP.stripCarriedItem, _table)
		if not ok then
			EP.logFault("carry-pickup", "ERROR wiping the plumbing off something"
				.. " picked up: " .. tostring(cleared))
		elseif cleared > 0 then
			EP.log(("%d plumbing mark(s) wiped off something picked up"):format(cleared))
		end

		return result
	end

	--- Back OUT of it.  BEFORE the vanilla body, equally necessarily: this one is not
	--- cleaning up after vanilla, it is stopping it putting the marks back.
	function ISMoveableSpriteProps:restoreThumpableParameters(modData, obj)
		local ok, cleared = pcall(EP.stripCarriedItem, modData)
		if not ok then
			EP.logFault("carry-place", "ERROR wiping the plumbing off something"
				.. " being put down: " .. tostring(cleared))
		elseif cleared > 0 then
			EP.log(("%d plumbing mark(s) wiped off something put down; it was carried"
				.. " before this build could clean it"):format(cleared))
		end

		return restore(self, modData, obj)
	end

	return true
end

--- Said in the log if it did not take, rather than not said at all.
---
--- The whole feature is a wrapper on somebody else's table.  If that table is missing or
--- has been replaced by something with a different shape, this mod goes on working and
--- goes on shipping the bug, and nothing a player can see would ever say so.
---
--- EP.log and not a raw print, and not EP.logFault either.  A player who has not turned
--- Debug on has not asked this mod for a single line, and a build without
--- ISMoveableSpriteProps is not a fault in this mod to report - it is a game that is not
--- the one this was written against.  Guard, carry on, and leave the sentence where
--- somebody looking for it will find it; that is what wrapComplete in LGEPPlumbing.lua
--- does with the same problem, bar the sentence.
if not installWraps() then
	EP.log("ISMoveableSpriteProps is not what this build expects; a barrel carried"
		.. " to a new base will arrive still plumbed into the old one")
end

--- Exposed for the suites, which load vanilla's real file and this one in whichever
--- order the runner puts them, and for a build where the table really did arrive late.
--- Idempotent, so calling it after a successful install is a no-op.
EP.installCarryWraps = installWraps

--- The same derived list, for the one place that has to CARRY the marks rather than strip
--- them: a barrel's lid, which vanilla implements as a brand new object (LGEPPlumbing.lua,
--- wrapLid).  One list, so a key added next year is carried across a lid and wiped off a
--- pickup by the same convention, with nothing to remember in either place.
EP.ownModDataKeys = carriedKeys


-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
--
-- The `else` is not defensive tidiness, it is the direction the fault actually came in:
-- the reported install had the NEW server file and an OLD shared one, so the core is the
-- half that has no checkBuild in it and a bare `if EP.checkBuild then` would have said
-- nothing in exactly the case this exists for.  Printed directly there because EP.logFault
-- is in the same file that is missing.
if EP.checkBuild then
	EP.checkBuild("LGEPCarry.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPCarry.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
