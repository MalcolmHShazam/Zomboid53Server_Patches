-- Wesch's Better Wringing (Malcolm MP patch) v7 - client-side chain
-- The vanilla "Wring Out Wet Clothes" option (ISInventoryPaneContextMenu.onWringClothing) runs
-- the full chain: the clicked item(s) first, then every other wringable clothing item (worn, main
-- inventory, and one level inside bags). The vanilla option's visibility rules are untouched.
-- Wringable = wetness above its cap (shoes 60, others 10), see W_BWUtil in W_ISWringClothing.lua.
-- Each item is a queued planner (ISTimedActionQueue.queueActions); when it reaches the front it adds
--   [transfer] -> unequip (if worn) -> wring -> re-wear (if worn) -> [return-to-bag planner] -> next planner.
-- Items taken from a bag are moved back to that bag after a successful wring (if it is still carried,
-- accessible and has room; otherwise they stay in the main inventory).
-- Cancelling (Esc/walk) clears the queue: the cancelled piece stays in inventory and the chain stops.
require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISQueueActionsAction"
require "TimedActions/ISInventoryTransferAction"
require "ISUI/ISInventoryPaneContextMenu"
require "TimedActions/W_ISWringClothing"

W_BetterWringing = W_BetterWringing or {}

local function log(chain, msg)
    print(string.format("[W_BetterWringing][C] %d/%d %s", chain.idx, #chain.ids, msg))
end

local function wringable(item)
    return W_BWUtil.wringable(item)
end

local function findItem(player, id)
    local inv = player:getInventory()
    local item = inv:getItemById(id)
    if not item and inv.getItemWithIDRecursiv then item = inv:getItemWithIDRecursiv(id) end
    return item
end

local function isWorn(player, item)
    return player:isEquipped(item) or player:getWornItems():contains(item)
end

-- the bag container an item sits in, or nil if it is in the main inventory
local function bagOf(player, item)
    local c = item:getContainer()
    if c and c ~= player:getInventory() then return c end
    return nil
end

-- Runs after a successful wring (it is queued behind the wring, so a cancel clears it).
function W_BetterWringing.returnItem(player, chain, id)
    local dest = chain.src[id]
    local item = findItem(player, id)
    if not dest or not item then return end
    local reason
    local bag = dest:getContainingItem()
    if not bag or bag:getContainer() ~= player:getInventory() then
        reason = "bag no longer carried"
    elseif ISInventoryPaneContextMenu.getContainers then
        local ok, list = pcall(ISInventoryPaneContextMenu.getContainers, player)
        if ok and list and not list:contains(dest) then reason = "bag not accessible" end
    end
    if not reason and not dest:hasRoomFor(player, item) then reason = "bag full" end
    if not reason and item:getContainer() == dest then reason = "already in bag" end
    if reason then
        log(chain, string.format("id=%d return skipped (%s), stays in main inventory", id, reason))
        return
    end
    ISTimedActionQueue.add(ISInventoryTransferAction:new(player, item, item:getContainer(), dest))
    log(chain, string.format("id=%d return to %s queued", id, tostring(bag:getType())))
end

-- Runs inside ISQueueActionsAction:start(); ISTimedActionQueue.add() inserts right after it, in order.
function W_BetterWringing.planNext(player, chain)
    while true do
        chain.idx = chain.idx + 1
        local id = chain.ids[chain.idx]
        if not id then
            chain.idx = #chain.ids
            log(chain, "finished: all items done")
            return
        end
        local item = findItem(player, id)
        if item and wringable(item) then
            local worn = isWorn(player, item)
            if worn then chain.src[id] = nil end
            ISInventoryPaneContextMenu.transferIfNeeded(player, item)
            if worn then
                ISTimedActionQueue.add(ISUnequipAction:new(player, item, 50))
            end
            ISTimedActionQueue.add(ISWringClothing:new(player, item, item:getWetness()))
            if worn then
                ISTimedActionQueue.add(ISWearClothing:new(player, item))
            end
            local src = chain.src[id]
            log(chain, string.format("id=%d %s wet=%.0f worn=%s from=%s", id, tostring(item:getType()),
                item:getWetness(), tostring(worn), src and tostring(src:getType()) or "main"))
            if src then
                ISTimedActionQueue.queueActions(player, W_BetterWringing.returnItem, chain, id)
            end
            if chain.idx < #chain.ids then
                ISTimedActionQueue.queueActions(player, W_BetterWringing.planNext, chain)
            else
                log(chain, "finished: last item queued")
            end
            return
        end
        -- not found / no longer wringable: skip silently and try the next one
    end
end

-- all wringable clothing: main inventory (incl. worn) and one level inside bags
local function snapshot(character)
    local list = {}
    local items = character:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if wringable(it) then table.insert(list, it) end
        if instanceof(it, "InventoryContainer") then
            local sub = it:getInventory():getItems()
            for j = 0, sub:size() - 1 do
                if wringable(sub:get(j)) then table.insert(list, sub:get(j)) end
            end
        end
    end
    return list
end

function W_BetterWringing.start(player, clicked)
    local ids, seen, src = {}, {}, {}
    local function addItem(item)
        if wringable(item) then
            local id = item:getID()
            if not seen[id] then
                seen[id] = true
                table.insert(ids, id)
                if not isWorn(player, item) then src[id] = bagOf(player, item) end
            end
        end
    end
    local names = {}
    for _, item in ipairs(clicked or {}) do
        table.insert(names, string.format("%s(id=%d wet=%.0f%s)", tostring(item:getType()), item:getID(),
            item:getWetness(), wringable(item) and "" or " skip:at cap"))
        addItem(item)
    end
    for _, item in ipairs(snapshot(player)) do addItem(item) end
    local chain = { ids = ids, idx = 0, src = src }
    log(chain, "clicked: " .. table.concat(names, ", "))
    if #ids == 0 then
        log(chain, "finished: nothing to wring")
        return
    end
    ISTimedActionQueue.queueActions(player, W_BetterWringing.planNext, chain)
end

-- Hook the vanilla "Wring Out Wet Clothes" option (shown by vanilla only for clothing with wetness > 15).
ISInventoryPaneContextMenu.onWringClothing = function(items, player)
    local playerObj = getSpecificPlayer(player)
    W_BetterWringing.start(playerObj, ISInventoryPane.getActualItems(items))
end
