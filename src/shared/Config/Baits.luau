--!strict
-- Bait roster, merchant prices and the Bait Crate gacha (GDD §5).
-- Bait is consumed per cast and reshapes the loot table for that cast.

local Types = require(script.Parent.Parent.Types)
local Weighted = require(script.Parent.Parent.Util.Weighted)

type Rarity = Types.Rarity
type Biome = Types.Biome
type MutationId = Types.MutationId

export type BaitDef = {
	id: string,
	name: string,
	rarity: Rarity,
	biome: Biome?, -- nil = works in any water
	luck: number, -- luck multiplier
	rarityMultipliers: { [Rarity]: number }?,
	mutationAffinity: { [MutationId]: number }?,
	unlocksMutations: { [MutationId]: boolean }?,
	minWeightRatio: number?, -- guaranteed minimum weight roll
	price: number?, -- gold per bundle at the Bait Merchant; nil = crate only
	bundle: number, -- units per merchant purchase
	description: string,
}

export type CrateEntry = {
	baitId: string,
	amount: number,
	weight: number, -- percent
}

local Baits = {}

Baits.Defs = {
	Earthworm = {
		id = "Earthworm",
		name = "Earthworm",
		rarity = "Common",
		biome = "Freshwater",
		luck = 1,
		price = 50,
		bundle = 10,
		description = "Balanced Freshwater pool.",
	},
	KrillPaste = {
		id = "KrillPaste",
		name = "Krill Paste",
		rarity = "Common",
		biome = "Saltwater",
		luck = 1,
		price = 50,
		bundle = 10,
		description = "Balanced Saltwater pool.",
	},
	GlowingFirefly = {
		id = "GlowingFirefly",
		name = "Glowing Firefly",
		rarity = "Rare",
		biome = "Freshwater",
		luck = 1,
		rarityMultipliers = { Epic = 2, Legendary = 2 },
		price = 15_000,
		bundle = 5,
		description = "Freshwater only. 2x Epic and Legendary odds.",
	},
	SquidInkCapsule = {
		id = "SquidInkCapsule",
		name = "Squid Ink Capsule",
		rarity = "Rare",
		biome = "Saltwater",
		luck = 1,
		mutationAffinity = { Bioluminescent = 2 },
		unlocksMutations = { Bioluminescent = true },
		price = 15_000,
		bundle = 5,
		description = "Saltwater only. 2x Bioluminescent odds, even in daylight.",
	},
	StarlightRoe = {
		id = "StarlightRoe",
		name = "Starlight Roe",
		rarity = "Mythic",
		luck = 1,
		rarityMultipliers = { Mythic = 4 },
		unlocksMutations = { VoidTouched = true },
		minWeightRatio = 1.5,
		bundle = 1,
		description = "Any water. 4x Mythic odds, minimum 1.5x weight, and a whisper of the Void.",
	},
} :: { [string]: BaitDef }

Baits.DisplayOrder = { "Earthworm", "KrillPaste", "GlowingFirefly", "SquidInkCapsule", "StarlightRoe" }

-- New players can fish both biomes immediately.
Baits.Starter = { Earthworm = 25, KrillPaste = 25 } :: { [string]: number }
Baits.DefaultEquipped = "Earthworm"

-- Casting with no usable bait is allowed (so nobody can soft-lock at 0 gold),
-- but at a luck penalty.
Baits.NoBaitLuck = 0.75

Baits.Crate = {
	Cost = 20_000,
	-- Published odds (percent). Shown in the shop UI.
	Entries = {
		{ baitId = "Earthworm", amount = 12, weight = 34 },
		{ baitId = "KrillPaste", amount = 12, weight = 34 },
		{ baitId = "GlowingFirefly", amount = 4, weight = 15 },
		{ baitId = "SquidInkCapsule", amount = 4, weight = 15 },
		{ baitId = "StarlightRoe", amount = 1, weight = 2 },
	} :: { CrateEntry },
}

function Baits.Get(baitId: string): BaitDef?
	return Baits.Defs[baitId]
end

function Baits.IsCompatible(baitId: string, biome: Biome): boolean
	local def = Baits.Defs[baitId]
	return def ~= nil and (def.biome == nil or def.biome == biome)
end

function Baits.RollCrate(rng: Random): CrateEntry
	return Weighted.Pick(rng, Baits.Crate.Entries, function(entry: CrateEntry): number
		return entry.weight
	end)
end

return Baits
