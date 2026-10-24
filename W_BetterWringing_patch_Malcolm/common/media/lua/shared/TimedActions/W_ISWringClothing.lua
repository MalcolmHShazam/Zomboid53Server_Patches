-- Wesch's Better Wringing (Malcolm MP patch) v7
-- Shared timed action. Replaces vanilla ISWringClothing. MP-safe:
--  * isValid (client and server): item still exists and is in the player's inventory.
--    Wetness is only checked in isValidStart: the server's complete() sets wetness to 10
--    before the client finishes, so checking it mid-action used to false-cancel the queue.
--  * startWetness is passed as a ctor arg so the server copy gets the same duration
--  * no re-wear on cancel: a cancelled piece stays in inventory and the chain stops
--  * v7: an item is wringable only if wetness > its cap (shoes 60, others 10)
--  * shoe cap compares ItemBodyLocation.SHOES (42.21 enum) with string fallback
require "TimedActions/ISBaseTimedAction"

ISWringClothing = ISBaseTimedAction:derive("ISWringClothing")

W_BWDiag = W_BWDiag or {}
function W_BWDiag.log(msg)
    local side = isServer() and "S" or (isClient() and "C" or "SP")
    print("[W_BetterWringing][" .. side .. "] " .. msg)
end
local D = W_BWDiag

local function isShoes(item)
    local loc = item:getBodyLocation()
    if loc == nil then return false end
    if ItemBodyLocation and ItemBodyLocation.SHOES and loc == ItemBodyLocation.SHOES then return true end
    local s = string.lower(tostring(loc))
    return s == "shoes" or s:sub(-6) == ":shoes"
end

-- shared helpers (also used by the client chain)
W_BWUtil = W_BWUtil or {}
function W_BWUtil.capOf(item)
    if isShoes(item) then return 60 end
    return 10
end
function W_BWUtil.wringable(item)
    return item ~= nil and instanceof(item, "Clothing") and item:getWetness() > W_BWUtil.capOf(item)
end

local function idOf(item)
    if not item then return "nil" end
    local ok, id = pcall(item.getID, item)
    return ok and tostring(id) or "?"
end

function ISWringClothing:isValid()
    local inInv = self.item ~= nil and self.character:getInventory():contains(self.item)
    if not inInv then
        D.log("isValid=false id=" .. idOf(self.item) .. " (not in inventory)")
    end
    return inInv
end

function ISWringClothing:isValidStart()
    if isServer() then return true end
    return W_BWUtil.wringable(self.item)
end

function ISWringClothing:update()
    self.item:setJobDelta(self:getJobDelta())
    self.character:setMetabolicTarget(Metabolics.HeavyDomestic)
end

function ISWringClothing:start()
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "")
    self:setOverrideHandModels(nil, nil)
    self.sound = self.character:playSound("WringOutWetClothes")
    self.character:reportEvent("EventWashClothing")
end

function ISWringClothing:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end
end

function ISWringClothing:stop()
    D.log(string.format("stop id=%s delta=%.2f (cancelled; piece stays in inventory, chain stops)",
        idOf(self.item), self:getJobDelta() or 0))
    self:stopSound()
    if self.item then self.item:setJobDelta(0.0) end
    ISBaseTimedAction.stop(self) -- clears the queue: drops the re-wear and the rest of the chain
end

function ISWringClothing:perform()
    self:stopSound()
    self.item:setJobDelta(0.0)
    -- needed to remove from queue / start next.
    ISBaseTimedAction.perform(self)
end

function ISWringClothing:complete()
    if self.item == nil then
        return false
    end
    if instanceof(self.item, "Clothing") then
        self.item:setWetness(math.min(self.item:getWetness(), W_BWUtil.capOf(self.item)))
    end
    syncItemFields(self.character, self.item)
    return true
end

function ISWringClothing:getDuration()
    if self.item == nil then
        return 0
    end
    if self.character:isTimedActionInstant() then
        return 1
    end
    local w = self.startWetness
    if w == nil or w <= 0 then w = self.item:getWetness() end
    return math.max(1, math.ceil(w * 5))
end

function ISWringClothing:new(character, item, startWetness)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    if startWetness == nil and item then startWetness = item:getWetness() end
    o.startWetness = startWetness
    o.maxTime = o:getDuration()
    o.forceProgressBar = true
    return o
end
