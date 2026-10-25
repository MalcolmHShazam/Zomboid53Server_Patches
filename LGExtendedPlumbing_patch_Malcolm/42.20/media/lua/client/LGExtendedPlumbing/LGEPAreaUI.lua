--
-- Extended Plumbing - Show piped area.
--
-- LGEE's powered-area window, pointed at water.  It draws where plumbing reaches round the
-- player, and it lays and lifts pipes.  See plans/lgep-pipe-network.md section 6, and
-- plans/lgee-powered-area-view.md for the window it is a port of and the traps it already
-- paid for: `self.x` is the panel's, a highlight lives one frame, every rectangle gets a
-- white outline, and an ask is not an answer.
--
-- WHAT IS DRAWN, at the player's own level:
--
--   a building's plumbing area      faint     it is on a network, or holds a plumbed barrel
--   a pipe somebody laid            a pipe    bending tile to tile, flanged into a building
--   a vertical pipe                 a pipe    up the middle of its wall
--   a fixture a pipe is feeding     a drop    over the fixture, on a tee off the pipe
--
-- The pipes' shapes are LGEPPipeDraw.lua's; this window builds them when the answer moves and
-- projects them every frame.
--
-- BLUE when the network has a plumbed-in barrel on it, WHITE when it has none.  Blue says a
-- barrel is connected; it does not say a tap will pour - water still only runs downhill
-- unless a generator powers the barrel, and the legend says so, because that is the
-- question a blue pipe at barrel height will otherwise raise.
--
-- THE SERVER ANSWERS AND THIS DRAWS.  The window never derives a network: it holds the
-- answer the authority sent and asks again when the pipes move.
--

require "ISUI/ISPanelJoypad"
require "LGExtendedPlumbing/LGEPPipe"
require "LGExtendedPlumbing/LGEPPipeDraw"
require "TimedActions/LGEPPipeAction"

local EP = LGEP

local PAD = 10
local TITLEBAR_HGT = 16

--- Font metrics, asked when the window is built rather than when the file loads: a file
--- that calls into the text manager at load time takes the whole client folder down in a
--- harness with no text manager, and gains nothing by being early.
local function fontHeight()
	local tm = getTextManager and getTextManager()
	return tm and tm:getFontHeight(UIFont.Small) or 14
end

--- The two states.  Hue says supplied or not.  A building's area is a faint fill - every
--- rectangle also gets the engine's white outline, so WHITE there reads by its fill against a
--- blue neighbour rather than by its border.  A pipe is its own texture, tinted, and nearly
--- opaque, because it is a thing lying on the floor and not a highlight of one.
local BLUE  = { r = 0.25, g = 0.55, b = 1.0 }
local WHITE = { r = 0.95, g = 0.95, b = 0.95 }
local FAINT_A = 0.16
local SOLID_A = 0.50
local PIPE_A = 0.95

--- The wall tint's strength, for the cursor's own green and red on a wall.  IsoObject's
--- highlight is applied to a wall as a TINT (WallShaper.setTintColor), so alpha here is how
--- strongly the wall takes the colour.
local WALL_A = 0.85

--- How many fixtures a frame asks whether they are plumbed - pipe tiles and the fixtures found
--- in buildings, in one round.  A walk of the square's objects each where a fixture might be,
--- spread across frames so a long run never lands them all on one; a hundred of them are round
--- again in a third of a second.
local FEED_PER_FRAME = 6

--- How many squares of the buildings' areas a frame looks at for a fixture, and how long it
--- rests between passes.  One property read each (EP.pipeArtMayHoldFixture), so a house is
--- swept in a couple of frames and a mall's floor in a few seconds, and then nothing for two.
--- A sink put down with the window open is found by the next pass.  Written first as "once per
--- answer", and the suite put a sink down after the pass had finished: answers come every ten
--- seconds, so it waited ten.
local SWEEP_PER_FRAME = 100
local SWEEP_REST_MS = 2000

local OKAY = { r = 0.2, g = 1.0, b = 0.3, a = 0.40 }
local DENY = { r = 1.0, g = 0.2, b = 0.2, a = 0.40 }

--- When the window asks again.  On the pipe generation moving (a lay, a lift, a network
--- turning blue), on walking far enough, on its own act, and on a slow backstop.  The floor
--- is longer than the authority's own 900 ms drop, so a retry always gets through.
local ASK_SECONDS = 10
local ASK_MIN_SECONDS = 1
local RECENTRE_TILES = 32
local FALLBACK_REACH = 60

--- How often the bag is re-read.  getCountTypeEvalRecurse walks every container the player
--- carries, and the verdict is read every frame.
local CARRY_MS = 500

LGEPAreaUI = ISPanelJoypad:derive("LGEPAreaUI")
LGEPAreaUI.instance = nil

--------------------------------------------------------------------------------
-- what arrived
--------------------------------------------------------------------------------

--- The answer, unpacked.  Matched on the centre it was asked from: an answer can outlive
--- the window that asked, or land after the player has walked on.
---
--- Public because the authority calls it directly in singleplayer, where there is no wire.
function EP.onPipeAreaResult(args)
	local ui = LGEPAreaUI.instance
	if not ui or type(args) ~= "table" then return end
	if tonumber(args.x) ~= ui.centreX or tonumber(args.y) ~= ui.centreY
		or tonumber(args.z) ~= ui.centreZ then return end

	local nets = {}
	local n = args.nets
	for i = 1, tonumber(args.nn) or 0 do nets[i] = tonumber(n[i]) == 1 end

	local floors = {}
	local f = args.floors
	for i = 1, (tonumber(args.nf) or 0) - 3, 4 do
		floors[#floors + 1] = { x = tonumber(f[i]), y = tonumber(f[i + 1]), z = tonumber(f[i + 2]),
			net = tonumber(f[i + 3]) or 0 }
	end

	local walls = {}
	local w = args.walls
	for i = 1, (tonumber(args.nw) or 0) - 4, 5 do
		walls[#walls + 1] = { x = tonumber(w[i]), y = tonumber(w[i + 1]), z = tonumber(w[i + 2]),
			north = tonumber(w[i + 3]) == 1, net = tonumber(w[i + 4]) or 0 }
	end

	local areas = {}
	local a = args.areas
	for i = 1, (tonumber(args.na) or 0) - 6, 7 do
		areas[#areas + 1] = { x1 = tonumber(a[i]), y1 = tonumber(a[i + 1]), x2 = tonumber(a[i + 2]),
			y2 = tonumber(a[i + 3]), z1 = tonumber(a[i + 4]), z2 = tonumber(a[i + 5]),
			net = tonumber(a[i + 6]) or 0 }
	end

	ui.nets, ui.floors, ui.walls, ui.areas = nets, floors, walls, areas
	ui.heard = true
	-- WHAT THIS ANSWER COVERS is what the ask it replies to was about.  See LGEPAreaUI:ask.
	ui.seenGeneration = ui.pendingGeneration
	ui.version = (ui.version or 0) + 1
end

--------------------------------------------------------------------------------
-- opening
--------------------------------------------------------------------------------

--- One window at a time; a second replaces the first.
function EP.showPipedArea(player, barrel)
	if not player then return end
	if LGEPAreaUI.instance then LGEPAreaUI.instance:close() end

	local square = barrel and barrel.getSquare and barrel:getSquare() or nil
	local w = LGEPAreaUI:new(120, 220, 280, 160, player,
		square and square:getX() or nil, square and square:getY() or nil, square and square:getZ() or nil)
	w:initialise()
	w:addToUIManager()
	LGEPAreaUI.instance = w

	-- A PAD HAS NO MOUSE TO CLOSE IT WITH.  The row that opens this is offered on a
	-- controller like any other, and the only ways out were the Ok button and Escape - one
	-- needs a mouse and the other was dead (see `LGEPAreaUI:new`). A pad-only player was
	-- left with a window they could not close, asking the authority every ten seconds and
	-- drawing over the world for as long as the game ran. So the window takes the pad's
	-- focus the way vanilla's own ISPanelJoypad windows do when they open for a pad
	-- (`ISFluidInfoUI.lua:60-62`), and B closes it - see `onJoypadDown`.
	if getJoypadData and setJoypadFocus and getJoypadData(w.playerNum) then
		setJoypadFocus(w.playerNum, w)
	end

	w:ask()
	return w
end

function LGEPAreaUI:new(x, y, width, height, player, bx, by, bz)
	local o = ISPanelJoypad:new(x, y, width, height)
	-- ESCAPE, WHICH NEVER ARRIVED.  `UIManager.onKeyRelease` offers a key only to an element
	-- that wants key events (`UIManager.java:1475-1483`), and nothing here ever said so - so
	-- `LGEPAreaUI:onKeyRelease` was dead code, Escape went straight to the pause menu with
	-- the mode still armed, and the next click on the world spent an iron pipe. The field
	-- rather than `setWantKeyEvents`, because there is no Java element yet: this is what
	-- `ISUIElement:setWantKeyEvents` writes before there is one, and what `instantiate` hands
	-- over when `addToUIManager` makes it (`ISUIElement.lua:1003`).
	--
	-- `lgep_spec_pipeui` called `onKeyRelease` by hand and passed the whole time.
	-- memory/a-hand-rolled-caller-tests-nothing-about-the-caller.md
	o.wantKeyEvents = true
	setmetatable(o, self)
	self.__index = self
	o.player = player
	o.playerNum = player:getPlayerNum()

	-- bx/by/bz AND NOT x/y/z.  `x` and `y` are the WINDOW'S position on screen and every
	-- drag writes them.  The barrel is only the gate; it is kept for the log.
	o.bx, o.by, o.bz = bx, by, bz
	o.titlebarbkg = getTexture and getTexture("media/ui/Panel_TitleBar.png") or nil
	o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
	o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
	o.fontHgt = fontHeight()

	o.nets, o.floors, o.walls, o.areas = {}, {}, {}, {}
	o.heard = false
	o.version = 0

	o.builtVersion, o.builtLevel, o.builtX0, o.builtY0 = nil, nil, nil, nil
	o.faintBlue, o.faintWhite = {}, {}
	o.art, o.feedAt = nil, 1

	o.askAt, o.askNotBefore = 0, 0
	o.pendingGeneration, o.seenGeneration = nil, nil
	o.centreX, o.centreY, o.centreZ = nil, nil, nil

	o.mode = nil
	o.currentButton = nil
	o.hover = nil

	o.carrying, o.carryAt = 0, -1
	return o
end

--- Rows between the title bar and the buttons: three of legend, the downhill note, and one
--- for a warning.  Reserved rather than measured, because the panel is sized once and the
--- answer has not arrived yet.
local BODY_ROWS = 5

function LGEPAreaUI:initialise()
	ISPanelJoypad.initialise(self)

	local rowH = self.fontHgt + 4
	local btnH = self.fontHgt + 6
	local y = TITLEBAR_HGT + PAD + rowH * BODY_ROWS + PAD

	local function button(label, internal, atY)
		local b = ISButton:new(PAD, atY, 220, btnH, label, self, LGEPAreaUI.onClick)
		b.internal = internal
		b:initialise()
		b:instantiate()
		self:addChild(b)
		return b
	end

	-- The cost is in the label, because it is the one number weighed before pressing.
	local cost = tostring(EP.PIPE_COST)
	self.addBtn = button(getText("IGUI_LGEP_AddPipe", cost), "ADD", y)
	self.removeBtn = button(getText("IGUI_LGEP_RemovePipe"), "REMOVE", self.addBtn:getBottom() + 6)
	self.addWallBtn = button(getText("IGUI_LGEP_AddWallPipe", cost), "ADD_WALL", self.removeBtn:getBottom() + 6)
	self.removeWallBtn = button(getText("IGUI_LGEP_RemoveWallPipe"), "REMOVE_WALL",
		self.addWallBtn:getBottom() + 6)
	self.closeBtn = button(getText("UI_Ok"), "CLOSE", self.removeWallBtn:getBottom() + PAD)

	local buttons = { self.addBtn, self.removeBtn, self.addWallBtn, self.removeWallBtn, self.closeBtn }
	local width = self:setElementWidthToMaxOf(unpack(buttons))

	-- AS WIDE AS ITS WIDEST LINE, NOT ONLY ITS WIDEST BUTTON.  The legend, the downhill note and
	-- the warning are drawn rather than added, so shrinkWrap cannot see them.  The downhill note
	-- is about twice the widest English button, and a translation is usually longer again.
	-- Found translating: nothing had measured the text, and LGEE's lines are short enough that
	-- the port never showed it.
	local lines = self:widestLine()
	if lines > (width or 0) then
		for i = 1, #buttons do buttons[i]:setWidth(lines) end
	end
	self:shrinkWrap(PAD, PAD, nil)

	-- AND THE PAD HAS TO BE ABLE TO REACH THEM.
	--
	-- `addChild` puts a button on the panel; it does not put it in the panel's JOYPAD model.
	-- `ISPanelJoypad:new` leaves `joypadButtonsY = {}` and `joypadIndexY = 0`, and
	-- `ISPanelJoypad:onJoypadDown` reads `self:getVisibleChildren(self.joypadIndexY)`
	-- (`ISPanelJoypad.lua:310-312`), which is then nil - so A reached no button and the D-pad
	-- had nothing to navigate. The window takes the pad's focus when it opens, so a pad player
	-- got a panel with five buttons drawn on it and only B doing anything.
	--
	-- One row per button, because they are stacked vertically and that is what the D-pad's
	-- up/down walks.
	for i = 1, #buttons do self:insertNewLineOfButtons(buttons[i]) end
end

--- The widest thing prerender draws, measured from the left padding the buttons start at.
--- A legend row starts after its swatch; the title is centred, so it needs its own width.
function LGEPAreaUI:widestLine()
	local tm = getTextManager()
	local function measure(key) return tm:MeasureStringX(UIFont.Small, getText(key)) end
	local swatch = self.fontHgt - 2 + 6
	local widest = 0
	for _, key in ipairs({ "IGUI_LGEP_PipeLegendSupplied", "IGUI_LGEP_PipeLegendDry",
		"IGUI_LGEP_PipeLegendBuilding" }) do
		widest = math.max(widest, swatch + measure(key))
	end
	for _, key in ipairs({ "IGUI_LGEP_PipeTitle", "IGUI_LGEP_PipeWorking", "IGUI_LGEP_PipeDownhill",
		"IGUI_LGEP_PipeNeedWrench", "IGUI_LGEP_PipeNeed" }) do
		widest = math.max(widest, measure(key))
	end
	return widest
end

function LGEPAreaUI:clearMode()
	if self.currentButton then
		self.currentButton:restoreDefaultColors()
		self.currentButton = nil
	end
	self.mode = nil
	self.hover = nil
end

--- Pressing the mode you are in turns it off; every stray click on the world in a mode
--- costs an iron pipe, so there has to be a way to be in none.
function LGEPAreaUI:onClick(button)
	if button.internal == "CLOSE" then
		self:close()
		return
	end
	local wasCurrent = self.currentButton == button
	self:clearMode()
	if wasCurrent then return end
	self.currentButton = button
	button:enableAcceptColor()
	self.mode = button.internal
end

--- Closing lets go of the pad's focus if it is ours, as `ISDesignationZonePanel:close` does -
--- and only if it is ours, so a player who has moved their pad to the inventory does not have
--- it taken off them by this window being replaced.
--- THE LIVE PLAYER, NOT THE ONE THIS WINDOW OPENED FOR.
---
--- `self.player` is captured once and held for the life of the window. After a death and a
--- respawn in multiplayer that object is the CORPSE's: `centreOn` reads a frozen position, so
--- the overlay stays where the player died - and `ask()` goes on sending that centre while the
--- authority compares it against the LIVE player (it answers only about where the asker is
--- standing). Respawn more than a window away from where you died and **every ask is refused
--- for ever**, silently, with the panel showing a dead picture because it has already heard.
---
--- Re-resolved per use rather than watched for, because there is no death event registered
--- anywhere in this mod and one more event handler is a second thing to keep in step.
--- `getSpecificPlayer` answers the machine's current player for that slot.
function LGEPAreaUI:livePlayer()
	if getSpecificPlayer then
		local now = getSpecificPlayer(self.playerNum)
		if now then
			self.player = now
			return now
		end
	end
	return self.player
end

function LGEPAreaUI:close()
	LGEPAreaUI.instance = nil
	if isJoypadFocusOnElementOrDescendant and setJoypadFocus
		and isJoypadFocusOnElementOrDescendant(self.playerNum, self) then
		setJoypadFocus(self.playerNum, nil)
	end
	self:setVisible(false)
	self:removeFromUIManager()
end

--- B closes, on any pad that has the window's focus.
---
--- Handled here rather than only through `setISButtonForB`, so closing does not rest on the
--- focus having arrived through `onGainJoypadFocus`; that is what draws the B on the Ok
--- button, which is how a pad player is told which button it is.
function LGEPAreaUI:onJoypadDown(button, joypadData)
	if button == Joypad.BButton then
		if self.mode then self:clearMode(); return end
		self:close()
		return
	end
	ISPanelJoypad.onJoypadDown(self, button, joypadData)
end

function LGEPAreaUI:onGainJoypadFocus(joypadData)
	ISPanelJoypad.onGainJoypadFocus(self, joypadData)
	if self.setISButtonForB then self:setISButtonForB(self.closeBtn) end
end

function LGEPAreaUI:onLoseJoypadFocus(joypadData)
	ISPanelJoypad.onLoseJoypadFocus(self, joypadData)
	if self.clearISButtons then self:clearISButtons() end
end

--------------------------------------------------------------------------------
-- asking
--------------------------------------------------------------------------------

--- Re-centre on the player once they have walked far enough.  Returns true when it moved.
--- The barrel is the gate and nothing more: the window is about where the player stands.
function LGEPAreaUI:centreOn()
	local who = self:livePlayer()
	local px = math.floor(who:getX())
	local py = math.floor(who:getY())
	local pz = who:getZi()
	if self.centreX ~= nil and self.centreZ == pz
		and math.abs(px - self.centreX) <= RECENTRE_TILES
		and math.abs(py - self.centreY) <= RECENTRE_TILES then
		return false
	end
	self.centreX, self.centreY, self.centreZ = px, py, pz
	return true
end

--- Ask the authority what is round the player.  A REQUEST, not a receipt: `pending` is what
--- the ask is about and `seen` moves only when an answer lands, so an ask the authority
--- dropped leaves the window behind and it asks again (lgee-relay-network-redesign.md §9a).
function LGEPAreaUI:ask()
	local now = getTimestampMs()
	self:centreOn()
	self.askAt = now + ASK_SECONDS * 1000
	self.askNotBefore = now + ASK_MIN_SECONDS * 1000
	self.pendingGeneration = EP.pipeGeneration

	if EP.isNetworkClient() then
		sendClientCommand(EP.COMMAND_MODULE, EP.COMMAND_PIPE_AREA,
			{ x = self.centreX, y = self.centreY, z = self.centreZ })
	elseif EP.requestPipeArea then
		EP.requestPipeArea(self.centreX, self.centreY, self.centreZ, self:livePlayer())
	end
end

--------------------------------------------------------------------------------
-- what is on screen
--------------------------------------------------------------------------------

--- The loaded chunk map's own bounds, which FBORenderAreaHighlights culls against, so the
--- grid is 104 squares a side whatever the network's extent.  getWorldXMaxTiles is
--- exclusive.
local function windowBounds(playerNum, player)
	local cell = getCell()
	local map = cell and cell.getChunkMap and cell:getChunkMap(playerNum)
	-- `map.ignore` is a Java field and Kahlua exposes methods, not fields, so this read was
	-- always nil.  Harmless here - the map asked for is the live player's own - but it read as
	-- a guard, so it is gone rather than left looking like one.  See EP.loadedTileBounds.
	if map and map.getWorldXMinTiles then
		return map:getWorldXMinTiles(), map:getWorldYMinTiles(),
			map:getWorldXMaxTiles() - 1, map:getWorldYMaxTiles() - 1
	end
	local px, py = math.floor(player:getX()), math.floor(player:getY())
	return px - FALLBACK_REACH, py - FALLBACK_REACH, px + FALLBACK_REACH, py + FALLBACK_REACH
end

--- Is network `n`, as the last answer described it, supplied?  0 is a building held by a
--- plumbed barrel with no pipe touching it: a network of one, supplied by definition.
function LGEPAreaUI:supplied(n)
	if n == 0 then return true end
	return self.nets[n] == true
end

--- Rebuild what is drawn, only when the answer, the level or the window moved.
function LGEPAreaUI:refresh()
	local who = self:livePlayer()
	local level = who:getZi()
	local x0, y0, x1, y1 = windowBounds(self.playerNum, who)
	if self.builtVersion == self.version and self.builtLevel == level
		and self.builtX0 == x0 and self.builtY0 == y0 then
		return
	end
	self.builtVersion, self.builtLevel, self.builtX0, self.builtY0 = self.version, level, x0, y0
	self.level = level

	-- THE BUILDINGS, merged by rows so the engine's white outline draws round the area and
	-- not round every tile of it.  A tile two areas both claim draws once, in the stronger
	-- of their two states.
	local grid = EP.newPipeGrid(x0, y0, x1, y1)
	for i = 1, #self.areas do
		local a = self.areas[i]
		if level >= a.z1 and level <= a.z2 then
			EP.pipeGridMark(grid, a.x1, a.y1, a.x2, a.y2, self:supplied(a.net) and 2 or 1)
		end
	end
	self.faintBlue = EP.pipeGridRects(grid, 2)
	self.faintWhite = EP.pipeGridRects(grid, 1)
	self.grid = grid

	-- THE PIPES, as pipes: which way each tile runs, and the quads that draw it, relative to the
	-- window's corner.  Built here and not per frame - the doors are a neighbour walk per tile
	-- and the curves are arithmetic - and a pipe only moves when the answer or the level does.
	-- Whether a fixture on a tile is fed is the one thing that moves on its own, and
	-- LGEPAreaUI:checkFeeds asks it a few tiles a frame.
	local previous = self.art
	local art = EP.pipeArtBuild(level, self.floors, self.walls, self.areas,
		function(net) return self:supplied(net) end, x0, y0)
	self.art = art
	if previous and previous.level == level then
		-- Keep what was already known about the fixtures, so a rebuild does not blink every
		-- drop off until the round comes back to it.
		local fed = {}
		for i = 1, #previous.tiles do
			local g = previous.tiles[i]
			if g.fed then fed[g.x .. "," .. g.y] = true end
		end
		for i = 1, #art.tiles do
			local g = art.tiles[i]
			g.fed = fed[g.x .. "," .. g.y] == true
		end
		-- And the fixtures already found in buildings, in the colour the new answer gives their
		-- tile.  One now under a pipe is the pipe's; one no longer in any drawn area is nobody's.
		for i = 1, #previous.drops do
			local d = previous.drops[i]
			local value = EP.pipeGridAt(grid, d.x, d.y)
			if value and not art.links[d.key] then
				EP.pipeArtAddDrop(art, d.x, d.y, value == 2).fed = d.fed
			end
		end
	end
	self.feedAt = 1

	-- THE SWEEP starts over through the areas as drawn now: every faint rectangle, blue first.
	local rects = {}
	for i = 1, #self.faintBlue do rects[#rects + 1] = { r = self.faintBlue[i], blue = true } end
	for i = 1, #self.faintWhite do rects[#rects + 1] = { r = self.faintWhite[i], blue = false } end
	self.sweep = { rects = rects, at = 1, x = nil, y = nil }
end

--- A few squares a frame of the buildings' areas: is a fixture standing there?  Found ones get a
--- drop entry and join the round in checkFeeds; a square that had one and has none now loses it.
--- A pipe tile is skipped - a fixture on a pipe is the pipe's, with its tee.
---
--- Through the areas, a rest, and through again: what it finds is where fixtures STAND, which
--- changes only when somebody carries one, so it need not run every frame.  Whether they are
--- plumbed is checkFeeds', every frame, because that changes with a click.  A new answer starts
--- a pass at once, over the areas as they are drawn now.
function LGEPAreaUI:sweepAreas()
	local sweep, art = self.sweep, self.art
	if not sweep or not art or not EP.pipeArtMayHoldFixture then return end
	if sweep.at > #sweep.rects then
		local now = getTimestampMs()
		if not sweep.doneAt then sweep.doneAt = now end
		if now - sweep.doneAt < SWEEP_REST_MS then return end
		sweep.at, sweep.x, sweep.y, sweep.doneAt = 1, nil, nil, nil
		if #sweep.rects == 0 then return end
	end
	local cell = getCell()
	if not cell then return end
	local level = art.level
	local budget = SWEEP_PER_FRAME
	while budget > 0 and sweep.at <= #sweep.rects do
		local entry = sweep.rects[sweep.at]
		local r = entry.r
		if sweep.x == nil then sweep.x, sweep.y = r.x, r.y end
		local x, y = sweep.x, sweep.y
		local key = x .. "," .. y
		if not art.links[key] then
			local square = cell:getGridSquare(x, y, level)
			if square and EP.pipeArtMayHoldFixture(square) and EP.fixtureOnSquare(square) then
				EP.pipeArtAddDrop(art, x, y, entry.blue)
			elseif art.dropAt[key] then
				EP.pipeArtRemoveDrop(art, x, y)
			end
		end
		budget = budget - 1
		-- Along the row, then down, then the next rectangle.  w and h are counts of tiles.
		x = x + 1
		if x >= r.x + r.w then
			x = r.x
			y = y + 1
		end
		if y >= r.y + r.h then
			sweep.at = sweep.at + 1
			sweep.x, sweep.y = nil, nil
		else
			sweep.x, sweep.y = x, y
		end
	end
end

--- A few fixtures a frame: is this one plumbed?  The pipe tiles, then the fixtures found in
--- buildings, as one round.  It can change with nothing about the pipes changing - a player
--- plumbs the sink - so it cannot wait for the next answer.
function LGEPAreaUI:checkFeeds()
	local art = self.art
	if not art or not EP.pipeArtFed then return end
	local tiles, drops = art.tiles, art.drops
	local total = #tiles + #drops
	if total == 0 then return end
	for _ = 1, math.min(FEED_PER_FRAME, total) do
		if self.feedAt > total then self.feedAt = 1 end
		local g = self.feedAt <= #tiles and tiles[self.feedAt] or drops[self.feedAt - #tiles]
		g.fed = EP.pipeArtFed(g.x, g.y, art.level) == true
		self.feedAt = self.feedAt + 1
	end
end

--------------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- the textures
--------------------------------------------------------------------------------

--- Loaded once per game, by number.  A texture that will not load is drawn as a flat quad -
--- the one thirteen-argument DrawTexture is the only overload that long, so nil cannot pick a
--- wrong one - and said once, because a half-delivered update is the likely reason.
local textures = nil
local function pipeTextures()
	if textures then return textures end
	textures = {}
	local files = EP.PIPE_TEX_FILES or {}
	local missing = {}
	for i = 1, #files do
		textures[i] = getTexture and getTexture(files[i]) or nil
		if not textures[i] then missing[#missing + 1] = files[i] end
	end
	if #missing > 0 and EP.logFault then
		EP.logFault("pipe-texture", "could not load " .. table.concat(missing, ", ")
			.. "; pipes are drawn flat. Steam may have delivered half an update.")
	end
	return textures
end

--- One quad, screen coordinates, on whatever this window can draw with.  The element's own
--- four-point DrawTexture takes ABSOLUTE screen coordinates - it adds nothing of the panel's
--- position - which is what the projection hands back; ISUIElement's Lua wrapper around it
--- is the same call with two more function calls in front of it, so it is only the fallback.
local function drawQuad(self, tex, a, b, c, d, e, f, g, h, colour, alpha)
	local jo = self.javaObject
	if jo then
		jo:DrawTexture(tex, a, b, c, d, e, f, g, h, colour.r, colour.g, colour.b, alpha)
	elseif self.drawTextureAllPoint then
		self:drawTextureAllPoint(tex, a, b, c, d, e, f, g, h, colour.r, colour.g, colour.b, alpha)
	end
end

--- A legend row.  A pipe row shows a short length of pipe with a coupling, drawn with the same
--- textures as the world; the building row keeps its faint square.
local function legendRow(self, at, colour, alpha, label, pipe)
	local s = self.fontHgt - 2
	if pipe then
		local tex = pipeTextures()
		local ax = (self.getAbsoluteX and self:getAbsoluteX() or self.x) + PAD
		local ay = (self.getAbsoluteY and self:getAbsoluteY() or self.y) + at
		local mid = ay + s / 2
		local half = math.max(2, s * 0.24)
		-- u runs ACROSS the pipe, so its first edge is the top of a pipe lying left to right.
		drawQuad(self, tex[EP.PIPE_TEX_BODY], ax, mid - half, ax, mid + half, ax + s, mid + half,
			ax + s, mid - half, colour, 1)
		local bw, bh = math.max(1, half * 0.9), half * 1.5
		drawQuad(self, tex[EP.PIPE_TEX_BAND], ax + s / 2 - bw, mid - bh, ax + s / 2 - bw, mid + bh,
			ax + s / 2 + bw, mid + bh, ax + s / 2 + bw, mid - bh, colour, 1)
	else
		self:drawRect(PAD, at, s, s, math.min(1, alpha + 0.25), colour.r, colour.g, colour.b)
		self:drawRectBorder(PAD, at, s, s, 0.6, 1, 1, 1)
	end
	self:drawText(label, PAD + s + 6, at - 1, 0.9, 0.9, 0.9, 1, UIFont.Small)
end

function LGEPAreaUI:prerender()
	self:drawRect(0, 0, self.width, self.height, self.backgroundColor.a,
		self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
	if self.titlebarbkg then
		self:drawTextureScaled(self.titlebarbkg, 2, 1, self:getWidth() - 4, TITLEBAR_HGT - 2, 1, 1, 1, 1)
	end
	self:drawRectBorder(0, 0, self.width, self.height, self.borderColor.a,
		self.borderColor.r, self.borderColor.g, self.borderColor.b)
	self:drawTextCentre(getText("IGUI_LGEP_PipeTitle"), self.width / 2, 1, 1, 1, 1, 1, UIFont.Small)

	local at = TITLEBAR_HGT + PAD
	local row = self.fontHgt + 4

	-- ALL THE COLOURS, EVEN ONES NOT ON SCREEN.  The legend is the only place blue and
	-- white are explained, and one that appeared only once you knew would teach nobody.
	if not self.heard then
		self:drawText(getText("IGUI_LGEP_PipeWorking"), PAD, at, 0.8, 0.8, 0.8, 1, UIFont.Small)
	else
		legendRow(self, at, BLUE, SOLID_A, getText("IGUI_LGEP_PipeLegendSupplied"), true)
		legendRow(self, at + row, WHITE, SOLID_A, getText("IGUI_LGEP_PipeLegendDry"), true)
		legendRow(self, at + row * 2, BLUE, FAINT_A, getText("IGUI_LGEP_PipeLegendBuilding"))
		self:drawText(getText("IGUI_LGEP_PipeDownhill"), PAD, at + row * 3, 0.75, 0.75, 0.75, 1,
			UIFont.Small)
	end

	-- The warning row: something the player can go and fix.
	local warn = self:warning()
	if warn then
		self:drawText(warn, PAD, at + row * (BODY_ROWS - 1), 0.9, 0.5, 0.4, 1, UIFont.Small)
	end

	-- BEHIND WHAT IT HAS HEARD, not behind what it has sent.  Walking counts as behind.
	local now = getTimestampMs()
	local behind = self.seenGeneration ~= EP.pipeGeneration
	if self:centreOn() then
		self.seenGeneration = nil
		behind = true
	end
	if now >= self.askAt or (behind and now >= self.askNotBefore) then
		self:ask()
	end

	if self.mode then self:updateHover() end
end

--- What the player needs to go and get, if anything, for the mode they are in.
function LGEPAreaUI:warning()
	if not self.mode then return nil end
	if not EP.findPipeWrench or not EP.findPipeWrench(self:livePlayer()) then
		return getText("IGUI_LGEP_PipeNeedWrench")
	end
	if (self.mode == "ADD" or self.mode == "ADD_WALL") and self:pipesCarried() < EP.PIPE_COST then
		return getText("IGUI_LGEP_PipeNeed")
	end
	return nil
end

--- Tint one wall for this frame.  renderOnce, re-applied every frame like vanilla's own
--- cursors: the persistent form is one flag per player per object with no owner, and the
--- context menu's own hover clears it the moment the player mouses over the wall.
local function tintWall(object, playerNum, colour, alpha)
	if not object or not object.setHighlighted then return end
	local ok = pcall(function()
		object:setHighlighted(playerNum, true, true)
		object:setHighlightColor(playerNum, colour.r, colour.g, colour.b, alpha)
	end)
	if not ok then
		-- A build without the per-player overloads: the all-players form, which the engine
		-- clears after every frame exactly the same way.
		pcall(function()
			object:setHighlighted(true, true)
			object:setHighlightColor(colour.r, colour.g, colour.b, alpha)
		end)
	end
end

--- Every highlight, every frame, because a highlight lives for one: the buildings' faint areas,
--- then the cursor on top of everything it is about to change.  The pipes are not here - see
--- LGEPAreaUI:drawPipes for where they are drawn and why.
function LGEPAreaUI:render()
	self:refresh()
	self:sweepAreas()
	self:checkFeeds()
	local level, num = self.level, self.playerNum

	local rects = self.faintWhite
	for i = 1, #rects do
		local r = rects[i]
		addAreaHighlightForPlayer(num, r.x, r.y, r.x + r.w, r.y + r.h, level, WHITE.r, WHITE.g, WHITE.b, FAINT_A)
	end
	rects = self.faintBlue
	for i = 1, #rects do
		local r = rects[i]
		addAreaHighlightForPlayer(num, r.x, r.y, r.x + r.w, r.y + r.h, level, BLUE.r, BLUE.g, BLUE.b, FAINT_A)
	end

	local h = self.hover
	if not h then return end
	local c = h.ok and OKAY or DENY
	if h.wallObject then
		tintWall(h.wallObject, num, c, WALL_A)
	else
		addAreaHighlightForPlayer(num, h.x, h.y, h.x + 1, h.y + 1, level, c.r, c.g, c.b, c.a)
	end
end

--- THE PIPES, drawn from OnPreUIDraw: after the world, before any window.
---
--- Not from render().  A window's render() draws in the UI's own order, so pipes drawn there
--- would lie over every panel opened before this one - across the player's inventory.  The
--- event fires once a UI frame, in the UI's render state, before the first element, so what
--- is drawn in it is on the world and under every window.
---
--- The price, and it needs a game to see: the UI can render at its own rate (Options, "UI
--- render FPS", into an offscreen buffer), and at the default of 60 it renders every frame at
--- 60 fps.  A player who turns it down will see the pipes trail the world by a frame while the
--- camera moves.  The building areas are drawn by the world itself and will not.
---
--- A THROW HERE WOULD BE A THROW EVERY FRAME.  So it is caught, said once, and the window stops
--- drawing pipes until it is opened again; the areas and the buttons carry on.
function LGEPAreaUI:drawPipes()
	if self.pipesBroken then return end
	local ok, err = pcall(function()
		self:refresh()
		local art = self.art
		if not art or (#art.tiles == 0 and #art.risers == 0) then return end
		if not isoToScreenX or not isoToScreenY then return end

		local tex = pipeTextures()
		local core = getCore and getCore() or nil
		local w = core and core.getScreenWidth and core:getScreenWidth() or nil
		local h = core and core.getScreenHeight and core:getScreenHeight() or nil
		local B = EP.pipeArtBasis(self.playerNum, art.bx, art.by, art.level)
		self.pipeQuads = EP.pipeArtDraw(art, B, function(t, a, b, c, d, e, f, g, hh, blue)
			drawQuad(self, tex[t], a, b, c, d, e, f, g, hh, blue and BLUE or WHITE, PIPE_A)
		end, w, h, getTimestampMs())
	end)
	if not ok then
		self.pipesBroken = true
		if EP.logFault then
			EP.logFault("pipe-draw", "ERROR drawing pipes; the window has stopped drawing them: " .. tostring(err))
		end
	end
end

--- One handler for the life of the game, not one per window: a window that went away without
--- removing its own would go on being asked to draw.  Closed, it costs a table read a frame.
if Events and Events.OnPreUIDraw then
	Events.OnPreUIDraw.Add(function()
		local ui = LGEPAreaUI.instance
		if ui then ui:drawPipes() end
	end)
end

--------------------------------------------------------------------------------
-- laying and lifting
--------------------------------------------------------------------------------

--- The tile under the cursor, and where in it: the fractions pick a wall edge.
function LGEPAreaUI:mouseWorld()
	local wx, wy = ISCoordConversion.ToWorld(getMouseXScaled(), getMouseYScaled(), self.level or 0)
	local tx, ty = math.floor(wx), math.floor(wy)
	return tx, ty, wx - tx, wy - ty
end

--- Iron pipes in the bag, on a timer.  Broken ones do not count: the authority will not
--- take one.
function LGEPAreaUI:pipesCarried()
	local now = getTimestampMs()
	if self.carryAt < 0 or now >= self.carryAt then
		self.carryAt = now + CARRY_MS
		local inventory = self:livePlayer():getInventory()
		local notBroken = function(item) return not item:isBroken() end
		if inventory and inventory.getCountTypeEvalRecurse then
			self.carrying = inventory:getCountTypeEvalRecurse(EP.PIPE_TYPE, notBroken)
		elseif inventory and inventory.getItemCountRecurse then
			self.carrying = inventory:getItemCountRecurse(EP.PIPE_TYPE)
		else
			self.carrying = 0
		end
	end
	return self.carrying or 0
end

--- What the click would do, and whether the authority will take it: the FAST no, from the
--- same facts the authority checks - a pipe there already, a floor, a wall, the bag, the
--- wrench.  The authority checks again and is the one that decides.
---
--- Returns a table: the tile clicked, the piece's own coordinates (the wall's OWNER for a
--- vertical pipe), the wall object to tint, whether it is ok, and why not.
function LGEPAreaUI:verdict(tx, ty, fx, fy)
	local z = self.level or 0
	local v = { x = tx, y = ty, z = z, tx = tx, ty = ty, north = false }
	local mode = self.mode
	local cell = getCell()
	local hasWrench = EP.findPipeWrench ~= nil and EP.findPipeWrench(self:livePlayer()) ~= nil

	if mode == "ADD" or mode == "REMOVE" then
		if mode == "ADD" then
			local square = cell and cell:getGridSquare(tx, ty, z)
			if EP.pipeAt(tx, ty, z) then v.why = EP.PIPE_OCCUPIED
			-- `TreatAsSolidFloor`, not `isSolidFloor`: the second is a stale cache field the
			-- engine only fills from the first, and it reads false on most of the world. See
			-- the long note on `floorBlocked` in LGEPPipes.
			elseif not square or (square.TreatAsSolidFloor and not square:TreatAsSolidFloor()) then
				v.why = EP.PIPE_NO_SQUARE
			elseif not hasWrench then v.why = EP.PIPE_NO_WRENCH
			elseif self:pipesCarried() < EP.PIPE_COST then v.why = EP.PIPE_NO_PIPE end
		else
			if not EP.pipeAt(tx, ty, z) then v.why = EP.PIPE_NOT_OURS
			elseif not hasWrench then v.why = EP.PIPE_NO_WRENCH end
		end
	else
		-- The edge nearest the cursor, resolved to the square that OWNS the wall - the
		-- south edge of this tile is the north wall of the one below it.
		local ox, oy, north = EP.wallOwner(tx, ty, EP.nearestEdge(fx, fy))
		v.tx, v.ty, v.north = ox, oy, north
		local square = cell and cell:getGridSquare(ox, oy, z)
		local wall = square and square.getWall and square:getWall(north) or nil
		v.wallObject = wall
		if mode == "ADD_WALL" then
			if EP.wallPipeAt(ox, oy, z, north) then v.why = EP.PIPE_OCCUPIED
			elseif not wall then v.why = EP.PIPE_NO_WALL
			elseif not hasWrench then v.why = EP.PIPE_NO_WRENCH
			elseif self:pipesCarried() < EP.PIPE_COST then v.why = EP.PIPE_NO_PIPE end
		else
			if not EP.wallPipeAt(ox, oy, z, north) then v.why = EP.PIPE_NOT_OURS
			elseif not hasWrench then v.why = EP.PIPE_NO_WRENCH end
		end
	end

	v.ok = v.why == nil
	return v
end

--- Recomputed every frame.  The verdict reads the bag and the pieces, neither of which is
--- in the cursor's position: a player who picks a pipe up off the floor without moving the
--- mouse must see the tile turn green.
function LGEPAreaUI:updateHover()
	local tx, ty, fx, fy = self:mouseWorld()
	self.hover = self:verdict(tx, ty, fx, fy)
end

--- The act that goes with each mode.
local ACT = {
	ADD = EP.PIPE_ACT_LAY,
	REMOVE = EP.PIPE_ACT_LIFT,
	ADD_WALL = EP.PIPE_ACT_LAY_WALL,
	REMOVE_WALL = EP.PIPE_ACT_LIFT_WALL,
}

--- Would this element have taken the click, had it been asked?
---
--- The same three questions `UIManager.isOverElement` asks (`UIManager.java:473-495`), in the
--- same order, and no others - a capture beats everything, a clipped element is only as tall
--- as its clip, and otherwise it is the element's own test.
local function takesClick(ui, mx, my)
	if not ui:isVisible() then return false end
	if ui.isConsumeMouseEvents and not ui:isConsumeMouseEvents() then return false end
	if ui:isCapture() then return true end
	local maxHeight = ui:getMaxDrawHeight()
	if maxHeight ~= nil and maxHeight ~= -1 then
		local ex, ey = ui:getX(), ui:getY()
		return mx >= ex and my >= ey and mx < ex + ui:getWidth()
			and my < ey + math.min(ui:getHeight(), maxHeight)
	end
	return ui:isOverElement(mx, my) == true
end

--- IS SOMEBODY ELSE'S WINDOW UNDER THE CURSOR?
---
--- "Outside" is not "on the world". `UIManager` walks its elements top down and tells every
--- one the click MISSED that it was outside, stopping only at the first that consumes it
--- (`UIManager.java:685-696`), and `isOverElement` answers "outside" for every visible
--- element the point does not hit (`:473-495`). This window is added last, so it sits on top
--- and is told first.
function LGEPAreaUI:clickTakenByOtherUI()
	if not (UIManager and UIManager.getUI and getMouseX and getMouseY) then return false end
	local listed, uis = pcall(UIManager.getUI)
	if not listed or not uis then return false end
	local mx, my = getMouseX(), getMouseY()
	local mine = self.javaObject
	for i = 0, uis:size() - 1 do
		local ui = uis:get(i)
		if ui and ui ~= mine then
			local asked, takes = pcall(takesClick, ui, mx, my)
			if asked and takes then return true end
		end
	end
	return false
end

--- A click on the world.  Nothing is spent here: the action carries itself to the
--- authority and the pipe moves there.  A click reported as outside while its coordinates
--- are inside the panel is ignored - it would lay a pipe underneath the window.
---
--- AND A CLICK ON SOMEBODY ELSE'S WINDOW IS NOT A CLICK ON THE WORLD.  Without the third
--- guard: arm *Add pipe*, open your bag to check you have iron pipes, click an item - and
--- the character drops what they were doing, walks to the tile underneath the inventory
--- window, crouches for a hundred ticks and spends a pipe. With *Remove pipe* armed it lifts
--- one instead. Hotbar, health panel, loot window and chat are all the same click. The
--- coordinate test above cannot see it: the click really is outside THIS panel.
function LGEPAreaUI:onMouseDownOutside(x, y)
	if not self.mode then return end
	if x >= 0 and x <= self:getWidth() and y >= 0 and y <= self:getHeight() then return end
	if self:clickTakenByOtherUI() then return end

	local tx, ty, fx, fy = self:mouseWorld()
	local v = self:verdict(tx, ty, fx, fy)
	-- THE REFUSAL COMES FIRST, before the walk and the hundred ticks.
	if not v.ok then
		self:refuse(v.why)
		return
	end
	self:act(ACT[self.mode], v)
end

--- Walk over, take the wrench out, and do it - the way vanilla walks you to a generator
--- before it lets you plug one in, and the way this mod's own Plumb equips the wrench.
---
--- A WALL IS WORKED FROM WHICHEVER SIDE IS NEARER, NOT FROM THE TILE UNDER THE CURSOR.
--- Reported by LG on the first test: upstairs, the outside of a wall is open air, and a
--- walk to the clicked tile's neighbours found nowhere to stand.  `luautils.walkAdjWall` is
--- vanilla's own answer - what building a wall uses - handed the wall's OWNER square: it
--- picks between the two sides, the one in the player's own room first, then the nearer,
--- and never a side with no floor.
function LGEPAreaUI:act(mode, v)
	-- SWITCHED OFF IS ANSWERED HERE, BECAUSE IT CANNOT BE ANSWERED ANYWHERE ELSE.
	--
	-- `EP.PIPE_DISABLED` was added to the refusal table with a string in all 28 languages, and
	-- it could never appear: the only sender is `lay()` on the authority, and the action never
	-- reaches it. `LGEPPipeAction:isValid` opens with `if LGEP.getOption("Enabled") ~= true
	-- then return false end` and is re-asked every tick, so the action is force-stopped on
	-- this machine - no halo, no line, nothing - and `complete()` returns early besides.
	--
	-- So the state the string was written for is the one state that still said nothing: lit
	-- buttons, a green cursor, a walk, the wrench out, the progress bar gone, silence. Asked
	-- before the walk, it costs one option read and the player is told.
	if not EP.getOption("Enabled") then
		self:refuse(EP.PIPE_DISABLED)
		return
	end

	local player = self:livePlayer()
	local cell = getCell()
	local wall = mode == EP.PIPE_ACT_LAY_WALL or mode == EP.PIPE_ACT_LIFT_WALL
	local square
	if wall then
		square = cell and cell:getGridSquare(v.tx, v.ty, v.z)
	else
		square = cell and cell:getGridSquare(v.x, v.y, v.z)
	end
	if not square then
		self:refuse(EP.PIPE_NO_SQUARE)
		return
	end
	local walked = true
	if wall then
		if luautils and luautils.walkAdjWall then walked = luautils.walkAdjWall(player, square, v.north) end
	elseif luautils and luautils.walkAdj then
		walked = luautils.walkAdj(player, square)
	end
	if not walked then
		self:refuse(EP.PIPE_NO_WALK)
		return
	end

	local wrench = EP.findPipeWrench and EP.findPipeWrench(player) or nil
	if not wrench then
		self:refuse(EP.PIPE_NO_WRENCH)
		return
	end
	if ISWorldObjectContextMenu and ISWorldObjectContextMenu.equip then
		ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), wrench, true)
	end

	ISTimedActionQueue.add(LGEPPipeAction:new(player, v.tx, v.ty, v.z, v.north, mode, wrench))
end

local REFUSAL = {
	-- Every reason `deliver` can send, including the one that was missing: a window already
	-- open when an admin switches the mod off kept its lit buttons and its green cursor, the
	-- character walked over and took the wrench out, and the act died with nothing said.
	-- memory/a-silent-refusal-is-reported-as-a-bug.md
	[EP.PIPE_DISABLED]  = "IGUI_LGEP_PipeDisabled",
	[EP.PIPE_NO_PIPE]   = "IGUI_LGEP_PipeNeed",
	[EP.PIPE_NO_WRENCH] = "IGUI_LGEP_PipeNeedWrench",
	[EP.PIPE_OCCUPIED]  = "IGUI_LGEP_PipeOccupied",
	[EP.PIPE_NOT_OURS]  = "IGUI_LGEP_PipeNotOurs",
	[EP.PIPE_NO_WALL]   = "IGUI_LGEP_PipeNoWall",
	[EP.PIPE_NO_SQUARE] = "IGUI_LGEP_PipeNoSquare",
	[EP.PIPE_NO_WALK]   = "IGUI_LGEP_PipeNoWalk",
}

--- Say no where the player is looking: a halo, not a line in the panel.
function LGEPAreaUI:refuse(reason)
	local player = self:livePlayer()
	if not player or not HaloTextHelper or not HaloTextHelper.addBadText then return end
	local key = REFUSAL[reason]
	if not key then return end
	HaloTextHelper.addBadText(player, getText(key))
end

--- The authority took it, or it did not.  The item has already moved on the authority;
--- this says no where the player is looking, and asks for a fresh picture until one lands.
function EP.onPipeDone(args)
	if type(args) ~= "table" then return end
	local ui = LGEPAreaUI.instance
	if args.ok ~= true then
		if ui then
			ui:refuse(args.reason)
		elseif HaloTextHelper and getPlayer and REFUSAL[args.reason] then
			HaloTextHelper.addBadText(getPlayer(), getText(REFUSAL[args.reason]))
		end
		return
	end
	if ui then
		ui.askAt, ui.askNotBefore = 0, 0
		ui.seenGeneration = nil
		ui.carryAt = -1
	end
end

--------------------------------------------------------------------------------
-- moving it about
--------------------------------------------------------------------------------

function LGEPAreaUI:onMouseDown(x, y)
	if not self:getIsVisible() then return end
	self.moving = true
	self:bringToTop()
end

function LGEPAreaUI:onMouseUp(x, y) self.moving = false end
function LGEPAreaUI:onMouseUpOutside(x, y) self.moving = false end

function LGEPAreaUI:onMouseMove(dx, dy)
	if self.moving then
		self:setX(self.x + dx)
		self:setY(self.y + dy)
		self:bringToTop()
	end
end

function LGEPAreaUI:onMouseMoveOutside(dx, dy)
	if self.moving then
		self:setX(self.x + dx)
		self:setY(self.y + dy)
		self:bringToTop()
	end
end

--- Right-click and Escape let go of the mode without closing the window.
function LGEPAreaUI:onRightMouseDownOutside(x, y)
	if self.mode then
		self:clearMode()
		return true
	end
	return false
end

--- ESCAPE IS OURS WHILE THE WINDOW IS UP.  What the engine goes by is `isKeyConsumed` and
--- not `onKeyRelease`'s answer (`UIElement.java:2238-2241`), and a key it is told is consumed
--- never reaches `OnKeyPressed`, which is where the pause menu opens. So Escape lets go of the
--- mode, then closes this, and only then pauses, as vanilla's own windows do.
---
--- Player one only, as `ISHutchUI` has it: the keyboard is player one's, and a pad player's
--- window in split-screen must not be closed by somebody else's Escape.
function LGEPAreaUI:isKeyConsumed(key)
	return self.playerNum == 0 and key == Keyboard.KEY_ESCAPE
end

function LGEPAreaUI:onKeyRelease(key)
	if key ~= Keyboard.KEY_ESCAPE or self.playerNum ~= 0 then return false end
	if self.mode then
		self:clearMode()
		return true
	end
	self:close()
	return true
end

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
if EP.checkBuild then
	EP.checkBuild("LGEPAreaUI.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPAreaUI.lua is from build 3.3.1 and LGEPCore.lua"
		.. " is from a build too old to say which. Steam has delivered half an update: unsubscribe"
		.. " from LG Extended Plumbing, restart the game, and subscribe again.")
end
