-- Wait until ItemRarityUI is available, then inject our overrides
local function addMyModRarities()
    if not ItemRarityUI or not ItemRarityUI.rarityOverrides then
        print("[BagUpgradePlus] ItemRarityUI not found, skipping rarity overrides")
        return
    end

    -- Format: ["ModId.ItemName"]                                                                = "rarity"
    -- Valid rarity values: "legendary", "epic", "rare", "uncommon", "common", "crafted"
    ItemRarityUI.rarityOverrides["BagUpgradePlus.ALICEpackPlus"]                                 = "legendary"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.ALICEpack_DesertCamoPlus"]                      = "legendary"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.ALICEpack_CamoPlus"]                            = "legendary"
    ItemRarityUI.rarityOverrides["BagUpgradePlus.DuffelPlus"]                                    = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.MedicalPlus"]                                   = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.MilitaryPlus"]                                  = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.PolicePlus"]                                    = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.SheriffPlus"]                                   = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.SWATPlus"]                                      = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.BreakdownBagPlus"]                              = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.BurglarBagPlus"]                                = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.BaseballBagPlus"]                               = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.TennisBagPlus"]                                 = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.WeaponBagPlus"]                                 = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.InmateEscapedBagPlus"]                          = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.MoneyBagPlus"]                                  = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.WorkerBagPlus"]                                 = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.ShotgunBagPlus"]                                = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.ShotgunSawnoffBagPlus"]                         = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.ShotgunDblBagPlus"]                             = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.ShotgunDblSawnoffBagPlus"]                      = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.FoodCannedPlus"]                                = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.FoodSnacksPlus"]                                = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.ToolBagPlus"]                                   = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.HydrationBackpackPlus"]                         = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.HydrationBackpackPlus_Camo"]                    = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.HikingBagPlus"]                                 = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.BigHikingBagplus"]                              = "epic"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.BigHikingBagPlus_Travel"]                       = "epic"
    ItemRarityUI.rarityOverrides["BagUpgradePlus.FannyPackFrontPlus"]                            = "rare"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.FannyPackBackPlus"]                             = "rare"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.SchoolbagPlus"]                                 = "rare"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.SatchelPlus"]                                   = "rare"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.Satchel_FishingPlus"]                           = "rare"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.Satchel_MedicalPlus"]                           = "rare"
	ItemRarityUI.rarityOverrides["BagUpgradePlus.Satchel_MilitaryPlus"]                          = "rare"
    ItemRarityUI.rarityOverrides["Base.SheetSlingBagPlus"]                                       = "crafted"

    print("[BagUpgradePlus] Injected custom item rarities into ItemRarityUI")
end

-- Hook into game start, same as the mod itself does
Events.OnGameStart.Add(addMyModRarities)
Events.OnLoad.Add(addMyModRarities)