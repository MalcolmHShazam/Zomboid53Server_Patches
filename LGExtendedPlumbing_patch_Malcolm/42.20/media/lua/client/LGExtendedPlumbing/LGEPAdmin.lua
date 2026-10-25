--
-- THE WAY OUT, WHERE SOMEBODY IN TROUBLE WILL FIND IT.
--
-- The standing rule, 2026-09-22 (CLAUDE.md section 6): a mod that is not safe to remove ships
-- its own way out, in the game, in the debug context menu, beside a plain on/off toggle.
--
-- WHY THIS MOD IS NOT SAFE TO REMOVE. Every tap it serves beyond vanilla's own reach draws on a
-- MIRROR: a real object above the tap, saved with the chunk, whose sprite is saved by a numeric
-- id this mod registers from Lua. Delete the mod and each one loads back with a null sprite,
-- still holding a fluid container, still directly above its tap - which is exactly where
-- vanilla looks for a source. The tap stays plumbed to a barrel nothing will ever fill: dry, out
-- of the right-click menu, and not re-plumbable (plans/lgep-uninstall-leaves-mirrors.md,
-- measured by lgep_probe_uninstall; reported by lilkaos and WrongTypeOfHero on 08-16, and again
-- as BR-LGEP-073 on 3.3.0).
--
-- The cure already existed: switching Extended plumbing off in the sandbox takes every loaded
-- mirror away and puts its tap back. It was written on the Workshop page. That is the same
-- mitigation LGEE had, and four people still lost or rolled back a server over it (BR-LGEE-043).
-- The way out has to be where the trouble is.
--
-- WHAT IT CANNOT DO, AND SAYS. A mirror in a chunk that is not loaded cannot be touched by
-- anybody. The authority keeps an index of every mirror in the save, so the dialog says how
-- many are out there and where the first is. They go on their own as their chunks load, as long
-- as the mod is still installed and switched off.
--
-- WHERE IT IS PUT, AND THE TRAP UNDER IT. `context:addDebugOption` is a MARKER AND NOT A GATE: it
-- sets the bug icon and never asks whether debug mode is on, so an ungated call puts this menu
-- in every player's game (REDATA/current/05-contract/points/debug-ui-surfaces.md, field 1). The
-- gate is ours and it is the first line of the handler. The authority checks for itself as well
-- (EP.uninstallNow's command handler), because hiding a menu is not protecting a world.
--

require "LGExtendedPlumbing/LGEPCore"

local EP = LGEP

--------------------------------------------------------------------------------
-- saying what happened
--------------------------------------------------------------------------------

--- WHAT THE AUTHORITY LAST SAID. On a dedicated server the options reach a client when it
--- connects, so the admin's own copy of Enabled is stale the moment the server changes it; the
--- authority's answer wins while there is one. Session-scoped by being a file local
--- (memory/caches-must-be-session-scoped-not-process-scoped).
local authorityOn = nil

local function modIsOn()
	if authorityOn ~= nil then return authorityOn end
	return EP.getOption("Enabled") == true
end

--- A modal, because this is the one thing this mod says that a player must not miss: the
--- person reading it is about to delete the mod, and what it says decides whether their taps
--- survive it.
local function tell(text)
	local ok = pcall(function()
		local modal = ISModalDialog:new(0, 0, 420, 180, text, false)
		modal:initialise()
		modal:addToUIManager()
	end)
	if not ok then print("[LGExtendedPlumbing] " .. tostring(text)) end
end

--- What the authority managed, as the sentence the admin needs. "Nothing is left" has to be
--- unmistakable, because it is permission to delete the mod; anything else names a number and a
--- place.
function EP.onAdminResult(result)
	if type(result) ~= "table" then return end

	if result.action == EP.CMD_ADMIN_ENABLE then
		if not result.ok then
			tell("Could not change the setting. See console.txt.")
			return
		end
		authorityOn = result.on == true
		if result.on then
			tell("LG Extended Plumbing is now ON.\n\nTaps connect again as the mod finds them.")
		else
			tell(("LG Extended Plumbing is now OFF.\n\n%d tap(s) nearby were put back to vanilla.")
				:format(result.removed or 0))
		end
		return
	end

	if result.action ~= EP.CMD_ADMIN_UNINSTALL then return end
	if not result.ok then
		tell("The uninstall did not finish. See console.txt, and do not remove the mod yet.")
		return
	end
	authorityOn = false

	local lines = {}
	lines[#lines + 1] = "LG Extended Plumbing is switched off."
	lines[#lines + 1] = ""
	lines[#lines + 1] = ("%d tap(s) nearby were put back to vanilla."):format(result.removed or 0)

	local away = result.away or 0
	if away > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = ("Up to %d more are in parts of the map that are not loaded.")
			:format(away)
		if result.ax then
			lines[#lines + 1] = ("Go to %d,%d,%d and the rest follow on their own.")
				:format(result.ax, result.ay, result.az)
		end
		lines[#lines + 1] = "Remove the mod before then and those taps stay dry."
	else
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Nothing is left. It is safe to remove the mod now."
	end

	tell(table.concat(lines, "\n"))
end

Events.OnServerCommand.Add(function(module, command, args)
	if module ~= EP.COMMAND_MODULE or command ~= EP.CMD_ADMIN_RESULT then return end
	pcall(EP.onAdminResult, args)
end)

--------------------------------------------------------------------------------
-- the menu
--------------------------------------------------------------------------------

local function ask(command, args)
	local ok, err = pcall(sendClientCommand, EP.COMMAND_MODULE, command, args or {})
	if not ok then tell("Could not send that to the server: " .. tostring(err)) end
end

local function onToggle(_, on)
	ask(EP.CMD_ADMIN_ENABLE, { on = on })
end

local function onUninstallConfirmed(_, button)
	if not button or button.internal ~= "YES" then return end
	ask(EP.CMD_ADMIN_UNINSTALL, {})
end

local function onUninstall()
	local text = "Switch LG Extended Plumbing off and put every tap back?\n\n"
		.. "Taps it serves go back to vanilla. Your barrels, sinks and pipes are not removed,"
		.. " and you can switch it back on afterwards."
	local ok = pcall(function()
		local modal = ISModalDialog:new(0, 0, 460, 200, text, true, nil, onUninstallConfirmed)
		modal:initialise()
		modal:addToUIManager()
	end)
	if not ok then ask(EP.CMD_ADMIN_UNINSTALL, {}) end
end

--- THE SUBMENU, AND IT IS NOT GATED ON `Enabled`. Every other menu this mod builds returns when
--- the mod is off, which is right for them and would be a trap here: switching the mod off
--- would take away the only way to switch it back on.
local function adminMenu(context)
	-- OURS AND NOT addDebugOption's. See the header: the bug icon is paint.
	if not isDebugEnabled or not isDebugEnabled() then return end

	local parent = context:addDebugOption("LG Extended Plumbing")
	local menu = ISContextMenu:getNew(context)
	context:addSubMenu(parent, menu)

	local on = modIsOn()
	local status = menu:addOption(on and "Status: running" or "Status: switched off", nil, nil)
	status.notAvailable = true

	if on then
		menu:addOption("Switch the mod off", nil, onToggle, false)
	else
		menu:addOption("Switch the mod on", nil, onToggle, true)
	end

	local uninstall = menu:addOption("Uninstall: put every tap back", nil, onUninstall)
	if ISWorldObjectContextMenu and ISWorldObjectContextMenu.addToolTip then
		local tip = ISWorldObjectContextMenu.addToolTip()
		tip.description = "Switches the mod off and puts back every tap it serves that is"
			.. " loaded, then says how many are left and where. \n\nDo this before removing the"
			.. " mod, or those taps stay dry."
		uninstall.toolTip = tip
	end
end

--- EP.adminMenuForTest: `adminMenu` is a local and the suite's claim is about what the menu
--- offers, which only building it can show.
EP.adminMenuForTest = adminMenu

Events.OnFillWorldObjectContextMenu.Add(function(player, context, worldobjects, test)
	if test then return end
	local ok, err = pcall(adminMenu, context)
	if not ok then
		EP.logFault("client-admin-menu", "ERROR building the debug menu: " .. tostring(err))
	end
end)

-- HALF AN UPDATE IS A NIL CALL IN THE MIDDLE OF A LAP; see EP.BUILD.
if EP.checkBuild then
	EP.checkBuild("LGEPAdmin.lua", "3.3.1")
else
	print("[LGExtendedPlumbing] LGEPAdmin.lua is from build 3.3.1 and LGEPCore.lua is from a build too"
		.. " old to say which. Steam has delivered half an update: unsubscribe from LG Extended"
		.. " Plumbing, restart the game, and subscribe again.")
end
