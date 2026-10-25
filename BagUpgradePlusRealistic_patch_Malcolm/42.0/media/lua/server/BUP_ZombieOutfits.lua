print("[BUP] Zombie Outfit Script loaded")

local BAG_REPLACEMENTS                               = {
    ["Base.Bag_Schoolbag"]                           = "BagUpgradePlus.SchoolbagPlus",
    ["Base.Bag_ALICEpack"]                           = "BagUpgradePlus.ALICEpackPlus",
    ["Base.Bag_SWAT"]                                = "BagUpgradePlus.SWATPlus",
    ["Base.Bag_DuffelBag"]                           = "BagUpgradePlus.DuffelPlus",
    ["Base.Bag_MedicalBag"]                          = "BagUpgradePlus.MedicalPlus",
    ["Base.Bag_Military"]                            = "BagUpgradePlus.MilitaryPlus",
    ["Base.Bag_Police"]                              = "BagUpgradePlus.PolicePlus",
    ["Base.Bag_Sheriff"]                             = "BagUpgradePlus.SheriffPlus",
	["Base.Bag_BreakdownBag"]                        = "BagUpgradePlus.BreakdownBagPlus",
    ["Base.Bag_BurglarBag"]                          = "BagUpgradePlus.BurglarBagPlus",
    ["Base.Bag_BaseballBag"]                         = "BagUpgradePlus.BaseballBagPlus",
    ["Base.Bag_TennisBag"]                           = "BagUpgradePlus.TennisBagPlus",
    ["Base.Bag_WeaponBag"]                           = "BagUpgradePlus.WeaponBagPlus",
    ["Base.Bag_InmateEscapedBag"]                    = "BagUpgradePlus.InmateEscapedBagPlus",
    ["Base.Bag_MoneyBag"]                            = "BagUpgradePlus.MoneyBagPlus",
    ["Base.Bag_WorkerBag"]                           = "BagUpgradePlus.WorkerBagPlus",
    ["Base.Bag_ShotgunBag"]                          = "BagUpgradePlus.ShotgunBagPlus",
    ["Base.Bag_ShotgunSawnoffBag"]                   = "BagUpgradePlus.ShotgunSawnoffBagPlus",
    ["Base.Bag_ShotgunDblBag"]                       = "BagUpgradePlus.ShotgunDblBagPlus",
    ["Base.Bag_ShotgunDblSawnoffBag"]                = "BagUpgradePlus.ShotgunDblSawnoffBagPlus",
    ["Base.Bag_FoodCanned"]                          = "BagUpgradePlus.FoodCannedPlus",
    ["Base.Bag_FoodSnacks"]                          = "BagUpgradePlus.FoodSnacksPlus",
    ["Base.Bag_ToolBag"]                             = "BagUpgradePlus.ToolBagPlus",
    ["Base.Bag_FannyPackFront"]                      = "BagUpgradePlus.FannyPackFrontPlus",
    ["Base.Bag_FannyPackBack"]                       = "BagUpgradePlus.FannyPackBackPlus",
    ["Base.Bag_HydrationBackpack"]                   = "BagUpgradePlus.HydrationBackpackPlus",
    ["Base.Bag_HydrationBackpack_Camo"]              = "BagUpgradePlus.HydrationBackpackPlus_Camo",
    ["Base.Bag_NormalHikingBag"]                     = "BagUpgradePlus.HikingBagPlus",
    ["Base.Bag_BigHikingBag"]                        = "BagUpgradePlus.BigHikingBagplus",
    ["Base.Bag_HikingBag_Travel"]                    = "BagUpgradePlus.BigHikingBagPlus_Travel",
    ["Base.Bag_Satchel"]                             = "BagUpgradePlus.SatchelPlus",
    ["Base.Bag_Satchel_Fishing"]                     = "BagUpgradePlus.Satchel_FishingPlus",
    ["Base.Bag_Satchel_Medical"]                     = "BagUpgradePlus.Satchel_MedicalPlus",
    ["Base.Bag_Satchel_Military"]                    = "BagUpgradePlus.Satchel_MilitaryPlus",
}

-- Outfits we care about -- any bag found on these will be checked against BAG_REPLACEMENTS
local TRACKED_OUTFITS                                = {
    ["AmbulanceDriver"]                              = true,
    ["ArmyCamoDesert"]                               = true,
    ["ArmyCamoGreen"]                                = true,
    ["Backpacker"]                                   = true,
    ["Bandit"]                                       = true,
    ["Bandit_Early"]                                 = true,
    ["Bandit_Late"]                                  = true,
    ["Bandit_Mid"]                                   = true,
    ["Camper"]                                       = true,
    ["Cyclist"]                                      = true,
    ["Evacuee"]                                      = true,
    ["FiremanFullSuit"]                              = true,
    ["FitnessInstructor"]                            = true,
    ["Fisherman"]                                    = true,
    ["HonorStudent"]                                 = true,
    ["Hobbo"]                                        = true,
    ["Police"]                                       = true,
    ["Police_SWAT"]                                  = true,
    ["Retiree"]                                      = true,
    ["Sheriff_Deputy"]                               = true,
    ["StreetSports"]                                 = true,
    ["Student"]                                      = true,
    ["Survivalist"]                                  = true,
    ["Survivalist_Late"]                             = true,
    ["Survivalist_Mid"]                              = true,
    ["Survivalist02"]                                = true,
    ["Survivalist02_Late"]                           = true,
    ["Survivalist02_Mid"]                            = true,
    ["Survivalist03"]                                = true,
    ["Survivalist03_Late"]                           = true,
    ["Survivalist03_Mid"]                            = true,
    ["Survivalist04"]                                = true,
    ["Survivalist04_Late"]                           = true,
    ["Survivalist04_Mid"]                            = true,
    ["Survivalist05"]                                = true,
    ["Survivalist05_Late"]                           = true,
    ["Survivalist05_Mid"]                            = true,
    ["Teacher"]                                      = true,
    ["TutorialDad"]                                  = true,
}

local processed                                      = {}
local upgraded                                       = {}

local function doSwap(inventory, wornItems, vanillaBag, customBagType)
    local vanillaFullType                            = vanillaBag:getFullType()
    local vanillaBareName                            = vanillaFullType:match("%.(.+)$")

    wornItems:remove(vanillaBag)

    local invBag                                     = inventory:getFirstTypeRecurse(vanillaBareName)
    if invBag then inventory:Remove(invBag) end

    local added                                      = inventory:AddItem(customBagType)
    if added then
        wornItems:setItem(ItemBodyLocation.BACK, added)
        -- Clean up in case setItem restored the vanilla bag
        local invBag2                                = inventory:getFirstTypeRecurse(vanillaBareName)
        if invBag2 then inventory:Remove(invBag2) end
    end
    return added
end

local function findBag(wornItems)
    -- Primary: Back slot
    local item                                       = wornItems:getItem(ItemBodyLocation.BACK)
    if item and BAG_REPLACEMENTS[item:getFullType()] then
        return item, BAG_REPLACEMENTS[item:getFullType()]
    end
    -- Fallback: all worn slots
    for i                                            = 0, wornItems:size() - 1 do
        item                                         = wornItems:getItemByIndex(i)
        if item and BAG_REPLACEMENTS[item:getFullType()] then
            return item, BAG_REPLACEMENTS[item:getFullType()]
        end
    end
    return nil, nil
end

Events.OnZombieUpdate.Add(function(zombie)
    if zombie:isDead() then return end
    local id                                         = zombie:getOnlineID()
    if processed[id] then return end

    local outfitName                                 = zombie:getOutfitName()
    if not outfitName then return end
    if not TRACKED_OUTFITS[outfitName] then return end

    local wornItems                                  = zombie:getWornItems()
    if wornItems:size()                              == 0 then return end

    processed[id]                                    = true

    local spawnChance                                = SandboxVars.BagUpgradePlus.UpgradedBagSpawnChance
    if spawnChance                                   == 0 then return end
    if ZombRand(100) >= spawnChance then return end

    local vanillaBag, customBagType                  = findBag(wornItems)
    if not vanillaBag then return end

    local added                                      = doSwap(zombie:getInventory(), wornItems, vanillaBag, customBagType)
    if added then upgraded[id]                       = true end
end)

Events.OnZombieDead.Add(function(zombie)
    local outfitName                                 = zombie:getOutfitName()
    if not outfitName then return end
    if not TRACKED_OUTFITS[outfitName] then return end

    local id                                         = zombie:getOnlineID()
    local wasProcessed                               = processed[id]
    local wasUpgraded                                = upgraded[id]
    processed[id]                                    = nil
    upgraded[id]                                     = nil

    local inventory                                  = zombie:getInventory()
    local wornItems                                  = zombie:getWornItems()

    if not wasProcessed then
        local spawnChance                            = SandboxVars.BagUpgradePlus.UpgradedBagSpawnChance
        if spawnChance                               == 0 then return end
        if ZombRand(100) >= spawnChance then return end

        local vanillaBag, customBagType              = findBag(wornItems)
        if not vanillaBag then
            -- Try inventory directly if worn items empty at death
            for fullType, customType in pairs(BAG_REPLACEMENTS) do
                local bareName                       = fullType:match("%.(.+)$")
                local invBag                         = inventory:getFirstTypeRecurse(bareName)
                if invBag then
                    inventory:Remove(invBag)
                    local added                      = inventory:AddItem(customType)
                    if added then wornItems:setItem(ItemBodyLocation.BACK, added) end
                    return
                end
            end
            return
        end
        doSwap(inventory, wornItems, vanillaBag, customBagType)
    elseif wasUpgraded then
        -- Final cleanup: remove vanilla bag if it reappeared at death
        local vanillaBag, _                          = findBag(wornItems)
        if vanillaBag then
            local bareName                           = vanillaBag:getFullType():match("%.(.+)$")
            local invBag                             = inventory:getFirstTypeRecurse(bareName)
            if invBag then inventory:Remove(invBag) end
        end
    end
end)

print("[BUP] Zombie Outfit Events registered")