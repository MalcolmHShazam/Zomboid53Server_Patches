--
-- Extended Plumbing - running a pipe to a barrel, and pulling it off again.
--
-- Joining a collector to the building's supply used to be a menu toggle that took
-- effect between one frame and the next.  It is a job somebody does with a wrench, so
-- it is a timed action, modelled on vanilla's own ISPlumbItem - the action the game
-- already runs when a player plumbs a sink - rather than invented alongside it.
--
-- WHY THIS IS A PLAIN ISBaseTimedAction AND NOT A NetTimedAction.
--
-- The authority never runs a timed action at all.  Every water action in the game is an
-- ISBaseTimedAction started by the client that clicked, and this is one more of them: it
-- runs on the machine holding the mouse, in singleplayer and on a multiplayer client
-- alike, and on a dedicated server it is never constructed.
--
-- So the decision cannot be taken here.  complete() does exactly what the menu toggle it
-- replaced did - hands the change to EP.applyPlumbed, which sends a client command on a
-- network client and calls the authoritative EP.setIncluded directly in singleplayer.
-- An isAuthority() guard anywhere inside this file would mean the server was simply never
-- told, which is instant-and-correct in singleplayer and never on a server: the shape of
-- fault that reads as "it works in my game and not on the server".
--

require "TimedActions/ISBaseTimedAction"

local EP = LGEP

LGEPPlumbCollector = ISBaseTimedAction:derive("LGEPPlumbCollector")

--- Vanilla's own duration for plumbing a sink, and the same job.
---
--- Disconnecting is quicker and needs no tool, which is the shape the player asked for:
--- running a pipe is work, pulling one off is not.  It is still an action rather than a
--- toggle, because a barrel leaving the supply changes what every tap in the building
--- reads and that should cost a moment of somebody's time.
local PLUMB_TIME = 100
local UNPLUMB_TIME = 50

--- Not broken, which is vanilla's own predicate for a tool.
---
--- `predicateNotBroken` is a global defined in the vanilla client tree and is what
--- ISWorldObjectContextMenu.onPlumbItem passes.  It is reached through _G rather than
--- named directly so that a load order in which it is not yet there costs the exact
--- vanilla behaviour and not a nil call inside a menu - see the note in LGEPClient about
--- what a throw in that event costs every other mod.
local function notBroken(item)
	local vanilla = rawget(_G, "predicateNotBroken")
	if type(vanilla) == "function" then return vanilla(item) end
	return item and not item:isBroken()
end

--- The pipe wrench a player is carrying, by both of the routes vanilla accepts.
---
--- ISWorldObjectContextMenuLogic asks for the item TYPE and, failing that, for anything
--- carrying the PIPE_WRENCH tag - so a modded wrench that tags itself works here for the
--- same reason it works on a vanilla sink.  Both halves are probed for rather than
--- assumed: this is called while a context menu is being built, where a nil call takes
--- every later mod's entries down with it.
---
--- Shared with the menu, which greys the Plumb row out when this answers nil, so the row
--- and the action cannot disagree about what counts as a wrench.
function EP.findPipeWrench(playerObj)
	local inv = playerObj and playerObj.getInventory and playerObj:getInventory()
	if not inv then return nil end

	if inv.getFirstTypeEvalRecurse then
		local byType = inv:getFirstTypeEvalRecurse("PipeWrench", notBroken)
		if byType then return byType end
	end

	if inv.getFirstTagEvalRecurse and ItemTag and ItemTag.PIPE_WRENCH then
		return inv:getFirstTagEvalRecurse(ItemTag.PIPE_WRENCH, notBroken)
	end

	return nil
end

--- Hand a decision to whoever is allowed to take it.
---
--- The same two branches the menu toggle carried before this action existed, kept in one
--- place because both the action below and any future caller must not each grow their own
--- copy of the mode test.
function EP.applyPlumbed(x, y, z, plumbed)
	if EP.isNetworkClient() then
		sendClientCommand(EP.COMMAND_MODULE, EP.COMMAND_INCLUDE,
			{ x = x, y = y, z = z, included = plumbed })
	elseif EP.setIncluded then
		EP.setIncluded(x, y, z, plumbed)
	end
end

--- Still worth finishing?
---
--- Re-asked every tick by the engine, so all three questions are the cheap ones:
---
---   * the wrench is still equipped, which is vanilla's whole isValid for ISPlumbItem.
---     Only when plumbing - disconnecting needs no tool, so requiring one here would
---     cancel the action the moment a player put their wrench away mid-job.
---   * the barrel is still there.  It can be dismantled by somebody else while this
---     runs, and completing against an object that has left the world would send the
---     server an address with nothing at it.
---   * it is still somewhere a building can reach, which can stop being true while the
---     action runs if the wall it was leaning on comes down.  Asked only when PLUMBING:
---     a barrel already in the supply must always be able to leave it, whatever has
---     happened to the building around it, or a demolished house would leave barrels
---     permanently stuck in a supply nothing can offer to disconnect.
function LGEPPlumbCollector:isValid()
	if self.plumb and not self.character:isEquipped(self.wrench) then return false end
	if not self.collector or not self.collector:getSquare() then return false end

	-- The address was read at :new and is what complete() sends.  A collector with no
	-- square then would leave it nil, and a command carrying a nil coordinate is one the
	-- authority cannot resolve and will not report - it would simply do nothing, which is
	-- the silent failure this whole file is arranged against.
	if self.x == nil or self.y == nil or self.z == nil then return false end

	if self.plumb and not EP.canPlumbHere(self.x, self.y, self.z) then return false end
	return true
end

function LGEPPlumbCollector:update()
	self.character:faceThisObject(self.collector)
	self.character:setMetabolicTarget(Metabolics.MediumWork)
end

function LGEPPlumbCollector:start()
	self.sound = self.character:playSound("RepairWithWrench")
end

function LGEPPlumbCollector:stop()
	self.character:stopOrTriggerSound(self.sound)
	ISBaseTimedAction.stop(self)
end

--- THE WORK IS DONE HERE, IN perform, AND THERE IS DELIBERATELY NO complete().
---
--- This is the bug that shipped, and it is worth writing out in full because it is
--- invisible in singleplayer and total in multiplayer.
---
--- It was written the way vanilla's ISPlumbItem is written - cleanup in perform, the real
--- work in complete - and on a dedicated server the player got the whole timed action,
--- the sound, the progress bar, and then nothing at all.  The reason is one line of
--- LuaTimedActionNew:
---
---     public void complete() {
---        super.complete();
---        if (!GameClient.client) {
---           LuaManager.caller.pcall(thread, this.table.rawget("complete"), this.table);
---        }
---     }
---
--- A MULTIPLAYER CLIENT NEVER RUNS complete().  Vanilla's own actions survive that
--- because the engine puts them through a transaction: `if (table.getMetatable()
--- .rawget("complete") == null) this.useCustomRemoteTimedActionSync = true;` at :77, and
--- where that flag is FALSE the client registers with ActionManager, waits for
--- isDone(transactionId), and the SERVER is what actually calls complete - through
--- NetTimedAction, which rebuilds the action from the wire by :new PARAMETER NAME.  That
--- is a whole mechanism with its own serialisation contract, and this action was never
--- enrolled in it.
---
--- perform() carries no such guard.  It is pcall'd unconditionally at :158, so it runs on
--- every machine that actually runs the action - which for an ISBaseTimedAction is the
--- client, always, in every mode.  That is the same reading the rest of this mod is built
--- on: the authority never runs a timed action, so the client does the deciding and SAYS
--- so down its own channel.  EP.applyPlumbed is that channel, and it is the ordinary
--- client command every other player-driven change in this mod already uses.
---
--- Having no complete() at all is not a workaround, it is the engine's own way of saying
--- this: with nothing in the metatable, useCustomRemoteTimedActionSync goes TRUE and the
--- client stops trying to run a transaction it was never part of.  "Custom remote timed
--- action sync" is exactly what sendClientCommand is.
---
--- The address is used rather than the object, and it was read at :new.  EP.setIncluded
--- and the wire command both take x,y,z and resolve the barrel through EP.sourceAt, which
--- is what keeps a stale client from naming an object the authority has never heard of.
--- Reading the square here instead would be reading it after the action ran, when a
--- barrel that has just been dismantled answers nil and the job would be dropped at the
--- last step.
function LGEPPlumbCollector:perform()
	self.character:stopOrTriggerSound(self.sound)

	EP.applyPlumbed(self.x, self.y, self.z, self.plumb)

	-- needed to remove from queue / start next.
	ISBaseTimedAction.perform(self)
end

function LGEPPlumbCollector:getDuration()
	if self.character:isTimedActionInstant() then return 1 end
	return self.plumb and PLUMB_TIME or UNPLUMB_TIME
end

--- `wrench` is nil when disconnecting, and isValid above is what makes that safe.
function LGEPPlumbCollector:new(character, collector, plumb, wrench)
	local o = ISBaseTimedAction.new(self, character)
	o.character = character
	o.collector = collector
	o.plumb = plumb == true
	o.wrench = wrench

	local sq = collector and collector:getSquare()
	o.x, o.y, o.z = sq and sq:getX(), sq and sq:getY(), sq and sq:getZ()

	o.maxTime = o:getDuration()
	return o
end


-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
--
-- The `else` is not defensive tidiness, it is the direction the fault actually came in:
-- the reported install had the NEW server file and an OLD shared one, so the core is the
-- half that has no checkBuild in it and a bare `if EP.checkBuild then` would have said
-- nothing in exactly the case this exists for.  Printed directly there because EP.logFault
-- is in the same file that is missing.
if EP.checkBuild then
	EP.checkBuild("LGEPPlumbAction.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPPlumbAction.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
