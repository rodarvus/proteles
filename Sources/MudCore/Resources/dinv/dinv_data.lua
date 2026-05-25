----------------------------------------------------------------------------------------------------
-- Item locations and wearable locations
----------------------------------------------------------------------------------------------------

invItemLocUninitialized = "uninitialized"
invItemLocInventory     = "inventory"
invItemLocVault         = "vault"
invItemLocKeyring       = "keyring"
invItemLocWorn          = "worn"
invItemLocAuction       = "auction"
invItemLocShopkeeper    = "shopkeeper"

invIdLevelNone    = "none"  -- item has not be ID'ed in any way
invIdLevelPartial = "partial" -- item has been partially ID'ed  but more details are hidden
invIdLevelFull    = "full"  -- item has been ID'ed fully and no details are hidden

invWearableLocUndefined = -1
invWearableLocLight     = 0
invWearableLocHead      = 1
invWearableLocEyes      = 2
invWearableLocLear      = 3
invWearableLocRear      = 4
invWearableLocNeck1     = 5
invWearableLocNeck2     = 6
invWearableLocBack      = 7
invWearableLocMedal1    = 8
invWearableLocMedal2    = 9
invWearableLocMedal3    = 10
invWearableLocMedal4    = 11
invWearableLocTorso     = 12
invWearableLocBody      = 13
invWearableLocWaist     = 14
invWearableLocArms      = 15
invWearableLocLwrist    = 16
invWearableLocRwrist    = 17
invWearableLocHands     = 18
invWearableLocLfinger   = 19
invWearableLocRfinger   = 20
invWearableLocLegs      = 21
invWearableLocFeet      = 22
invWearableLocShield    = 23
invWearableLocWielded   = 24
invWearableLocSecond    = 25
invWearableLocHold      = 26
invWearableLocFloat     = 27
invWearableLocAbove     = 30
invWearableLocPortal    = 31
invWearableLocSleeping  = 32
invWearableLocReady     = 33

inv.wearLoc = {}
inv.wearLoc[invWearableLocUndefined] = "undefined"
inv.wearLoc[invWearableLocLight]     = "light"
inv.wearLoc[invWearableLocHead]      = "head"
inv.wearLoc[invWearableLocEyes]      = "eyes"
inv.wearLoc[invWearableLocLear]      = "lear"
inv.wearLoc[invWearableLocRear]      = "rear"
inv.wearLoc[invWearableLocNeck1]     = "neck1"
inv.wearLoc[invWearableLocNeck2]     = "neck2"
inv.wearLoc[invWearableLocBack]      = "back"
inv.wearLoc[invWearableLocMedal1]    = "medal1"
inv.wearLoc[invWearableLocMedal2]    = "medal2"
inv.wearLoc[invWearableLocMedal3]    = "medal3"
inv.wearLoc[invWearableLocMedal4]    = "medal4"
inv.wearLoc[invWearableLocTorso]     = "torso"
inv.wearLoc[invWearableLocBody]      = "body"
inv.wearLoc[invWearableLocWaist]     = "waist"
inv.wearLoc[invWearableLocArms]      = "arms"
inv.wearLoc[invWearableLocLwrist]    = "lwrist"
inv.wearLoc[invWearableLocRwrist]    = "rwrist"
inv.wearLoc[invWearableLocHands]     = "hands"
inv.wearLoc[invWearableLocLfinger]   = "lfinger"
inv.wearLoc[invWearableLocRfinger]   = "rfinger"
inv.wearLoc[invWearableLocLegs]      = "legs"
inv.wearLoc[invWearableLocFeet]      = "feet"
inv.wearLoc[invWearableLocShield]    = "shield"
inv.wearLoc[invWearableLocWielded]   = "wielded"
inv.wearLoc[invWearableLocSecond]    = "second"
inv.wearLoc[invWearableLocHold]      = "hold"
inv.wearLoc[invWearableLocFloat]     = "float"
inv.wearLoc[invWearableLocAbove]     = "above"
inv.wearLoc[invWearableLocPortal]    = "portal"
inv.wearLoc[invWearableLocSleeping]  = "sleeping"
inv.wearLoc[invWearableLocReady]     = "ready"

-- Aard is a bit inconsistent with the "ready" location.  Items such as quivers report their wearable
-- location as "ready" in identify but you can't wear an item at the "ready" location.  Instead, you
-- must wear it at the "readied" location.  Ugh.  This is a work-around for that issue.
invWearableLocReadyWorkaround = "readied"


inv.wearables = { light    = { "light" },
                  head     = { "head" },
                  eyes     = { "eyes" },
                  ear      = { "lear", "rear" },
                  neck     = { "neck1", "neck2" },
                  back     = { "back" },
                  medal    = { "medal1", "medal2", "medal3", "medal4" },
                  torso    = { "torso" },
                  body     = { "body" },
                  waist    = { "waist" },
                  arms     = { "arms" },
                  wrist    = { "lwrist", "rwrist" },
                  hands    = { "hands" },
                  finger   = { "lfinger", "rfinger" },
                  legs     = { "legs" },
                  feet     = { "feet" },
                  shield   = { "shield" },
                  wield    = { "wielded", "second" },
                  hold     = { "hold" },
                  float    = { "float" },
                  above    = { "above" },
                  portal   = { "portal" },
                  sleeping = { "sleeping" },
                  ready    = { "ready" } }              


----------------------------------------------------------------------------------------------------
-- Definitions for fields in identified items
----------------------------------------------------------------------------------------------------

inv.stats                 = {}
inv.stats.id              = { name = "id",
                              desc = "Unique identifier for the item" }
inv.stats.name            = { name = "name",
                              desc = "List of words in the name of the item" }
inv.stats.level           = { name = "level",
                              desc = "Level at which you may use the item (doesn't account for tier bonuses)" }
inv.stats.weight          = { name = "weight",
                              desc = "Base weight of the item" }
inv.stats.wearable        = { name = "wearable",
                              desc = "The item is wearable.  Run \"@Gwearable@W\" to see a list of locations." }
inv.stats.score           = { name = "score",
                              desc = "Item's score based on aard's priorities: see \"@Gcompare set@W\"" }
inv.stats.keywords        = { name = "keywords",
                              desc = "List of keywords representing the item" }
inv.stats.type            = { name = "type",
                              desc = "Type of item: see \"@Ghelp eqdata@W\" to see available types" }
inv.stats.worth           = { name = "worth",
                              desc = "How much gold this item is worth" }
inv.stats.flags           = { name = "flags",
                              desc = "List of flags assigned to the item" }
inv.stats.affectMods      = { name = "affectMods",
                              desc = "List of effects given by the item" }
inv.stats.material        = { name = "material",
                              desc = "Specifies what the item is made of" }
inv.stats.foundAt         = { name = "foundAt",
                              desc = "The item was found at this area" }
inv.stats.ownedBy         = { name = "ownedBy",
                              desc = "Character who owns this item" }
inv.stats.clan            = { name = "clan",
                              desc = "If this is a clan item, this indicates which clan made it" }
inv.stats.spells          = { name = "spells",
                              desc = "Spells that this item can cast" }
inv.stats.leadsTo         = { name = "leadsTo",
                              desc = "Target destination of a portal" }

inv.stats.capacity        = { name = "capacity",
                              desc = "How much weight the container can hold" }
inv.stats.holding         = { name = "holding",
                              desc = "Number of items held by the container" }
inv.stats.heaviestItem    = { name = "heaviestItem",
                              desc = "Weight of the heaviest item in the container" }
inv.stats.itemsInside     = { name = "itemsInside",
                              desc = "Number of items currently inside the container" }
inv.stats.totWeight       = { name = "totWeight",
                              desc = "Total weight of the container and its contents" }
inv.stats.itemBurden      = { name = "itemBurden",
                              desc = "Number of items in the container + 1 (for the container itself)" }
inv.stats.weightReduction = { name = "weightReduction",
                              desc = "Container reduces an item's weight to this % of the original weight" }

inv.stats.int             = { name = "int",
                              desc = "Intelligence points provided by the item" }
inv.stats.wis             = { name = "wis",
                              desc = "Wisdom points provided by the item" }
inv.stats.luck            = { name = "luck",
                              desc = "Luck points provided by the item" }
inv.stats.str             = { name = "str",
                              desc = "Strength points provided by the item" }
inv.stats.dex             = { name = "dex",
                              desc = "Dexterity points provided by the item" }
inv.stats.con             = { name = "con",
                              desc = "Constitution points provided by the item" }

inv.stats.hp              = { name = "hp",
                              desc = "Hit points provided by the item" }
inv.stats.mana            = { name = "mana",
                              desc = "Mana points provided by the item" }
inv.stats.moves           = { name = "moves",
                              desc = "Movement points provided by the item" }

inv.stats.hit             = { name = "hit",
                              desc = "Hit roll bonus due to the item" }
inv.stats.dam             = { name = "dam",
                              desc = "Damage roll bonus due to the item " }

inv.stats.allPhys         = { name = "allPhys",
                              desc = "Resistance provided against each of the physical resistance types" }
inv.stats.allMagic        = { name = "allMagic",
                              desc = "Resistance provided against each of the magical resistance types" }

inv.stats.acid            = { name = "acid",
                              desc = "Resistance provided against magical attacks of type \"acid\"" }
inv.stats.cold            = { name = "cold",
                              desc = "Resistance provided against magical attacks of type \"cold\"" }
inv.stats.energy          = { name = "energy",
                              desc = "Resistance provided against magical attacks of type \"energy\"" }
inv.stats.holy            = { name = "holy",
                              desc = "Resistance provided against magical attacks of type \"holy\"" }
inv.stats.electric        = { name = "electric",
                              desc = "Resistance provided against magical attacks of type \"electric\"" }
inv.stats.negative        = { name = "negative",
                              desc = "Resistance provided against magical attacks of type \"negative\"" }
inv.stats.shadow          = { name = "shadow",
                              desc = "Resistance provided against magical attacks of type \"shadow\"" }
inv.stats.magic           = { name = "magic",
                              desc = "Resistance provided against magical attacks of type \"magic\"" }
inv.stats.air             = { name = "air",
                              desc = "Resistance provided against magical attacks of type \"air\"" }
inv.stats.earth           = { name = "earth",
                              desc = "Resistance provided against magical attacks of type \"earth\"" }
inv.stats.fire            = { name = "fire",
                              desc = "Resistance provided against magical attacks of type \"fire\"" }
inv.stats.light           = { name = "light",
                              desc = "Resistance provided against magical attacks of type \"light\"" }
inv.stats.mental          = { name = "mental",
                              desc = "Resistance provided against magical attacks of type \"mental\"" }
inv.stats.sonic           = { name = "sonic",
                              desc = "Resistance provided against magical attacks of type \"sonic\"" }
inv.stats.water           = { name = "water",
                              desc = "Resistance provided against magical attacks of type \"water\"" }
inv.stats.poison          = { name = "poison",
                              desc = "Resistance provided against magical attacks of type \"poison\"" }
inv.stats.disease         = { name = "disease",
                              desc = "Resistance provided against magical attacks of type \"disease\"" }

inv.stats.slash           = { name = "slash",
                              desc = "Resistance provided against physical attacks of type \"slash\"" }
inv.stats.pierce          = { name = "pierce",
                              desc = "Resistance provided against physical attacks of type \"pierce\"" }
inv.stats.bash            = { name = "bash",
                              desc = "Resistance provided against physical attacks of type \"bash\"" }

inv.stats.aveDam          = { name = "aveDam",
                              desc = "Average damage from the weapon" }
inv.stats.inflicts        = { name = "inflicts",
                              desc = "Wound type from item: see Wset column in \"@Ghelp damage types@W\"" }
inv.stats.damType         = { name = "damType",
                              desc = "Damage type of item: see Damtype column in \"@Ghelp damage types@W\"" }
inv.stats.weaponType      = { name = "weaponType",
                              desc = "Type of weapon: see \"@Ghelp weapons@W\" for a list" }
inv.stats.specials        = { name = "specials",
                              desc = "See \"@Ghelp weapon flags@W\" for an explanation of special behaviors" }

inv.stats.location        = { name = "location",
                              desc = "Item ID for the container holding this item" }
inv.stats.rlocation       = { name = "rlocation",
                              desc = "Relative name (e.g., \"3.bag\") for the container holding this item" }
inv.stats.rname           = { name = "rname",
                              desc = "Relative name (e.g., \"2.dagger\") for the item" }
inv.stats.organize        = { name = "organize",
                              desc = "Queries assigned to a container by \"@Gdinv organize ...@W\"" }
inv.stats.loc             = { name = "loc",
                              desc = "Shorthand for the \"@G" .. inv.stats.location.name .. "@W\" search key" }
inv.stats.rloc            = { name = "rloc",
                              desc = "Shorthand for the \"@G" .. inv.stats.rlocation.name .. "@W\" search key" }
inv.stats.key             = { name = "key",
                              desc = "Shorthand for the \"@G" .. inv.stats.keywords.name .. "@W\" search key" }
inv.stats.keyword         = { name = "keyword",
                              desc = "Shorthand for the \"@G" .. inv.stats.keywords.name .. "@W\" search key" }
inv.stats.flag            = { name = "flag",
                              desc = "Shorthand for the \"@G" .. inv.stats.flags.name .. "@W\" search key" }

invStatFieldId              = string.lower(inv.stats.id.name)
invStatFieldName            = string.lower(inv.stats.name.name)
invStatFieldLevel           = string.lower(inv.stats.level.name)
invStatFieldWeight          = string.lower(inv.stats.weight.name)
invStatFieldWearable        = string.lower(inv.stats.wearable.name)
invStatFieldScore           = string.lower(inv.stats.score.name)
invStatFieldKeywords        = string.lower(inv.stats.keywords.name)
invStatFieldType            = string.lower(inv.stats.type.name)
invStatFieldWorth           = string.lower(inv.stats.worth.name)
invStatFieldFlags           = string.lower(inv.stats.flags.name)
invStatFieldAffectMods      = string.lower(inv.stats.affectMods.name)
invStatFieldMaterial        = string.lower(inv.stats.material.name)
invStatFieldFoundAt         = string.lower(inv.stats.foundAt.name)
invStatFieldOwnedBy         = string.lower(inv.stats.ownedBy.name)
invStatFieldClan            = string.lower(inv.stats.clan.name)
invStatFieldSpells          = string.lower(inv.stats.spells.name)
invStatFieldLeadsTo         = string.lower(inv.stats.leadsTo.name)

invStatFieldCapacity        = string.lower(inv.stats.capacity.name)
invStatFieldHolding         = string.lower(inv.stats.holding.name)
invStatFieldHeaviestItem    = string.lower(inv.stats.heaviestItem.name)
invStatFieldItemsInside     = string.lower(inv.stats.itemsInside.name)
invStatFieldTotWeight       = string.lower(inv.stats.totWeight.name)
invStatFieldItemBurden      = string.lower(inv.stats.itemBurden.name)
invStatFieldWeightReduction = string.lower(inv.stats.weightReduction.name)

invStatFieldInt             = string.lower(inv.stats.int.name)
invStatFieldWis             = string.lower(inv.stats.wis.name)
invStatFieldLuck            = string.lower(inv.stats.luck.name)
invStatFieldStr             = string.lower(inv.stats.str.name)
invStatFieldDex             = string.lower(inv.stats.dex.name)
invStatFieldCon             = string.lower(inv.stats.con.name)

invStatFieldHP              = string.lower(inv.stats.hp.name)
invStatFieldMana            = string.lower(inv.stats.mana.name)
invStatFieldMoves           = string.lower(inv.stats.moves.name)

invStatFieldHit             = string.lower(inv.stats.hit.name)
invStatFieldDam             = string.lower(inv.stats.dam.name)

invStatFieldAllPhys         = string.lower(inv.stats.allPhys.name)
invStatFieldAllMagic        = string.lower(inv.stats.allMagic.name)

invStatFieldAcid            = string.lower(inv.stats.acid.name)
invStatFieldCold            = string.lower(inv.stats.cold.name)
invStatFieldEnergy          = string.lower(inv.stats.energy.name)
invStatFieldHoly            = string.lower(inv.stats.holy.name)
invStatFieldElectric        = string.lower(inv.stats.electric.name)
invStatFieldNegative        = string.lower(inv.stats.negative.name)
invStatFieldShadow          = string.lower(inv.stats.shadow.name)
invStatFieldMagic           = string.lower(inv.stats.magic.name)
invStatFieldAir             = string.lower(inv.stats.air.name)
invStatFieldEarth           = string.lower(inv.stats.earth.name)
invStatFieldFire            = string.lower(inv.stats.fire.name)
invStatFieldLight           = string.lower(inv.stats.light.name)
invStatFieldMental          = string.lower(inv.stats.mental.name)
invStatFieldSonic           = string.lower(inv.stats.sonic.name)
invStatFieldWater           = string.lower(inv.stats.water.name)
invStatFieldPoison          = string.lower(inv.stats.poison.name)
invStatFieldDisease         = string.lower(inv.stats.disease.name)

invStatFieldSlash           = string.lower(inv.stats.slash.name)
invStatFieldPierce          = string.lower(inv.stats.pierce.name)
invStatFieldBash            = string.lower(inv.stats.bash.name)

invStatFieldAveDam          = string.lower(inv.stats.aveDam.name)
invStatFieldInflicts        = string.lower(inv.stats.inflicts.name)
invStatFieldDamType         = string.lower(inv.stats.damType.name)
invStatFieldWeaponType      = string.lower(inv.stats.weaponType.name)
invStatFieldSpecials        = string.lower(inv.stats.specials.name)


----------------------------------------------------------------------------------------------------
-- Plugin-specific query keys
--
-- Queries can use all of the invStatFieldXXX values as query keys.
-- Here are some other supported query keys that are convenient.
----------------------------------------------------------------------------------------------------

invQueryKeyLocation         = string.lower(inv.stats.location.name)
invQueryKeyRelativeLocation = string.lower(inv.stats.rlocation.name)
invQueryKeyRelativeName     = string.lower(inv.stats.rname.name)
invQueryKeyOrganize         = string.lower(inv.stats.organize.name)

invQueryKeyLoc              = string.lower(inv.stats.loc.name)
invQueryKeyRelativeLoc      = string.lower(inv.stats.rloc.name)
invQueryKeyKey              = string.lower(inv.stats.key.name)
invQueryKeyKeyword          = string.lower(inv.stats.keyword.name)
invQueryKeyFlag             = string.lower(inv.stats.flag.name)

invQueryKeyCustom           = "custom"
invQueryKeyAll              = "all"
invQueryKeyEquipped         = "equipped"
invQueryKeyWorn             = "worn" -- this is an alias for invQueryKeyEquipped
invQueryKeyUnequipped       = "unequipped"


----------------------------------------------------------------------------------------------------
-- The "affect mods" item fields (yes, I really think it should be "effect mods" but I'm sticking
-- with the aard terminology) include effects you get by wearing certain items.  For example, the
-- regen ring gives the "regeneration" ability.  However, some item effects are not included in
-- the "affect mods" field and they do not have official names.  We add a few custom ones here so
-- that we can have a way to prioritize items that prevent you from dropping weapons, allow you
-- to dual weapons, or get a defensive bonus because it is a shield.
----------------------------------------------------------------------------------------------------

invItemEffectsIronGrip     = "irongrip"
invItemEffectsDualWield    = "dualwield"
invItemEffectsShield       = "shield"
invItemEffectsHammerswing  = "hammerswing"

