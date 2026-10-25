--[[
local group = BodyLocations.getGroup("Human")

group:getOrCreateLocation(ItemBodyLocation["BagUpgradePlus:BUP_Satchel"])
]]

-- BUP_BodyLocations.lua
require "NPCs/BodyLocations"

local BodyAPI = BodyLocations
local SlotAPI = ItemBodyLocation
local RL = ResourceLocation

local function cloneLocationRules(sourceGroup, locationId, targetGroup)
    for i = 0, sourceGroup:size() - 1 do
        local otherId = sourceGroup:getLocationByIndex(i):getId()
        if sourceGroup:isExclusive(locationId, otherId) then
            targetGroup:setExclusive(locationId, otherId)
        end
        if sourceGroup:isHideModel(locationId, otherId) then
            targetGroup:setHideModel(locationId, otherId)
        end
        if sourceGroup:isAltModel(locationId, otherId) then
            targetGroup:setAltModel(locationId, otherId)
        end
    end
end

local function rebuildGroupWithInsertions(targetGroupId, insertions)
    local created = {}

    local groupView = BodyAPI.getAllGroups()
    local groupSnapshot = {}
    for i = 0, groupView:size() - 1 do
        groupSnapshot[#groupSnapshot + 1] = groupView:get(i)
    end

    BodyAPI.reset()

    for _, oldGroup in ipairs(groupSnapshot) do
        local newGroup = BodyAPI.getGroup(oldGroup:getId())

        for i = 0, oldGroup:size() - 1 do
            local existingId = oldGroup:getLocationByIndex(i):getId()

            -- Insert BEFORE anchor
            if oldGroup:getId() == targetGroupId then
                for _, def in ipairs(insertions) do
                    if def.before then
                        local anchorId = type(def.anchor) == "string"
                            and RL.of(def.anchor)
                            or def.anchor
                        if anchorId == existingId then
                            local newId = type(def.id) == "string"
                                and SlotAPI.get(RL.of(def.id))
                                or def.id
                            created[def.id] = newGroup:getOrCreateLocation(newId)
                        end
                    end
                end
            end

            -- Recreate original vanilla slot
            newGroup:getOrCreateLocation(existingId)

            -- Insert AFTER anchor
            if oldGroup:getId() == targetGroupId then
                for _, def in ipairs(insertions) do
                    if not def.before then
                        local anchorId = type(def.anchor) == "string"
                            and RL.of(def.anchor)
                            or def.anchor
                        if anchorId == existingId then
                            local newId = type(def.id) == "string"
                                and SlotAPI.get(RL.of(def.id))
                                or def.id
                            created[def.id] = newGroup:getOrCreateLocation(newId)
                        end
                    end
                end
            end
        end

        -- Restore vanilla behavior
        for i = 0, oldGroup:size() - 1 do
            local locId = oldGroup:getLocationByIndex(i):getId()
            newGroup:setMultiItem(locId, oldGroup:isMultiItem(locId))
            cloneLocationRules(oldGroup, locId, newGroup)
        end
    end

    return created
end

local function setupBUPBodyLocations()
    rebuildGroupWithInsertions("Human", {
        -- Insert BUP_Satchel AFTER the base:satchel slot
        { id = "BagUpgradePlusRealistic:BUP_Satchel", anchor = "base:fannypackback" }
    })
end

Events.OnGameBoot.Add(setupBUPBodyLocations)