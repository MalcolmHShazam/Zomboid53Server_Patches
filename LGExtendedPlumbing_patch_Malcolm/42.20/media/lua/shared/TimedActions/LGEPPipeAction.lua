require "TimedActions/ISBaseTimedAction"
require "LGExtendedPlumbing/LGEPPipe"

--- Laying a pipe, lifting one, and the same two for a wall pipe.
---
--- THE PLUMB ACT'S OWN FEEL.  Plumbing a barrel in is a wrench and a hundred ticks of
--- RepairWithWrench, so laying a pipe is too, and lifting one is the fifty it takes to
--- disconnect a barrel.  A floor pipe is worked on crouching and a wall pipe standing,
--- which is the only difference between the four.
---
--- ONE ACTION WITH A MODE, like LGEEWireRelayAction: the four differ only in which authority
--- function runs at the end, and four copies of the rest would be four places to fix.
---
--- complete() IS THE WRITE, AND IT RUNS ON THE AUTHORITY.  LuaTimedActionNew carries the
--- action to the server and runs complete() there - never on a multiplayer client - and the
--- iron pipe has to move there, because a client cannot announce an item into existence.
--- In singleplayer it is the same call in the same process.
LGEPPipeAction = ISBaseTimedAction:derive("LGEPPipeAction")

local LAY_TICKS, LIFT_TICKS = 100, 50

--- The wrench must still be in hand, which is vanilla ISPlumbItem's whole isValid.  Every
--- other rule - a pipe there already, no wall, nothing in the bag - is the authority's, at
--- the moment of the write, where it can also say why.
function LGEPPipeAction:isValid()
	if LGEP.getOption("Enabled") ~= true then return false end
	return self.wrench ~= nil and self.character:isEquipped(self.wrench)
end

--- A wall pipe faces the MIDDLE OF ITS WALL, as vanilla's ISBuildAction does.  The owner
--- tile's centre is the wrong target from both sides: across the wall it is past the wall,
--- and standing on the owner it is the player's own feet, where faceLocation turns nobody
--- and logs "faceLocationF at itself!".
function LGEPPipeAction:face()
	if not self:isWall() then
		self.character:faceLocation(self.tx, self.ty)
	elseif self.north then
		self.character:faceLocationF(self.tx + 0.5, self.ty)
	else
		self.character:faceLocationF(self.tx, self.ty + 0.5)
	end
end

function LGEPPipeAction:waitToStart()
	self:face()
	return self.character:shouldBeTurning()
end

function LGEPPipeAction:update()
	self:face()
	if self.character.setMetabolicTarget and Metabolics then
		self.character:setMetabolicTarget(Metabolics.MediumWork)
	end
end

function LGEPPipeAction:isWall()
	return self.mode == LGEP.PIPE_ACT_LAY_WALL or self.mode == LGEP.PIPE_ACT_LIFT_WALL
end

function LGEPPipeAction:start()
	self:setActionAnim("Loot")
	self.character:SetVariable("LootPosition", self:isWall() and "Mid" or "Low")
	self.sound = self.character:playSound("RepairWithWrench")
end

function LGEPPipeAction:stop()
	if self.sound then self.character:stopOrTriggerSound(self.sound) end
	ISBaseTimedAction.stop(self)
end

function LGEPPipeAction:perform()
	if self.sound then self.character:stopOrTriggerSound(self.sound) end
	ISBaseTimedAction.perform(self)
end

--- THE WRITE.  In multiplayer this is the server's copy of the action, rebuilt from the
--- packet, so it re-derives everything and trusts nothing the client believed.  `self.sound`
--- is deliberately not touched: the server's copy never had start() called on it.
function LGEPPipeAction:complete()
	if not LGEP.getOption("Enabled") then return true end
	local mode, x, y, z = self.mode, self.tx, self.ty, self.tz
	if mode == LGEP.PIPE_ACT_LAY then
		if LGEP.layPipe then LGEP.layPipe(x, y, z, self.character) end
	elseif mode == LGEP.PIPE_ACT_LIFT then
		if LGEP.liftPipe then LGEP.liftPipe(x, y, z, self.character) end
	elseif mode == LGEP.PIPE_ACT_LAY_WALL then
		if LGEP.layWallPipe then LGEP.layWallPipe(x, y, z, self.north == true, self.character) end
	elseif mode == LGEP.PIPE_ACT_LIFT_WALL then
		if LGEP.liftWallPipe then LGEP.liftWallPipe(x, y, z, self.north == true, self.character) end
	end
	return true
end

function LGEPPipeAction:getDuration()
	if self.character:isTimedActionInstant() then return 1 end
	if self.mode == LGEP.PIPE_ACT_LIFT or self.mode == LGEP.PIPE_ACT_LIFT_WALL then return LIFT_TICKS end
	return LAY_TICKS
end

--- EVERY ONE OF THESE NAMES IS A WIRE KEY.  NetTimedAction reads the parameter names off
--- this prototype and rawgets each off the action table, so a parameter and its field are
--- one unit: rename one side and the server rebuilds the action with nil in that slot.  All
--- of them are numbers, strings, booleans or a bag item, which is everything the packet can
--- carry - a floor item or a closure would be dropped and every later argument shift left.
---
--- For a wall pipe (tx, ty) is the square that OWNS the wall and `north` which of its two
--- walls; the window resolves a south or east edge to its neighbour before it gets here.
function LGEPPipeAction:new(character, tx, ty, tz, north, mode, wrench)
	local o = ISBaseTimedAction.new(self, character)
	o.character = character
	o.tx, o.ty, o.tz = tx, ty, tz
	o.north = north == true
	o.mode = mode
	o.wrench = wrench
	o.maxTime = o:getDuration()
	return o
end

if LGEP.checkBuild then
	LGEP.checkBuild("LGEPPipeAction.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPPipeAction.lua is from build 3.3.1 and LGEPCore.lua"
		.. " is from a build too old to say which. Steam has delivered half an update: unsubscribe"
		.. " from LG Extended Plumbing, restart the game, and subscribe again.")
end
