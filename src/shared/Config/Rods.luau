--!strict
-- Rod roster, star upgrades and the Rod Gacha Shrine tables (GDD §5).

local Types = require(script.Parent.Parent.Types)
local Rarities = require(script.Parent.Rarities)
local Weighted = require(script.Parent.Parent.Util.Weighted)

type Rarity = Types.Rarity
type MutationId = Types.MutationId
type RodState = Types.RodState

export type RodDef = {
	id: string,
	name: string,
	rarity: Rarity,
	luck: number, -- luck multiplier
	weight: number, -- weight power (see Creatures.RollWeightRatio)
	mutationBonus: number, -- relative boost to every mutation chance (0.05 = +5%)
	barSizeBonus: number, -- reeling catch-zone size bonus (0.15 = +15%)
	hookSpeed: number, -- bite-delay multiplier (lower = faster)
	mutationAffinity: { [MutationId]: number }?,
	unlocksMutations: { [MutationId]: boolean }?,
	description: string,
}

export type RodStats = {
	luck: number,
	weight: number,
	mutationBonus: number,
	barSizeBonus: number,
	hookSpeed: number,
}

export type DuplicateResult = {
	starsGained: number,
	refundGold: number,
}

local Rods = {}

Rods.Starter = "DriftwoodRod"

Rods.Defs = {
	DriftwoodRod = {
		id = "DriftwoodRod",
		name = "Driftwood Rod",
		rarity = "Common",
		luck = 1.0,
		weight = 1.0,
		mutationBonus = 0,
		barSizeBonus = 0,
		hookSpeed = 1,
		description = "The trusty starter. Nothing fancy, never lets you down.",
	},
	CoralCaster = {
		id = "CoralCaster",
		name = "Coral Caster",
		rarity = "Uncommon",
		luck = 1.2,
		weight = 1.1,
		mutationBonus = 0.02,
		barSizeBonus = 0.10, -- GDD: 0
		hookSpeed = 1,
		description = "Reef-grown and a little lucky.",
	},
	TidebreakerRod = {
		id = "TidebreakerRod",
		name = "Tidebreaker Rod",
		rarity = "Rare",
		luck = 1.5,
		weight = 1.25,
		mutationBonus = 0.05,
		barSizeBonus = 0.22, -- GDD: 0.15
		hookSpeed = 1,
		description = "A steadier line: +22% reeling bar size.",
	},
	GildedHarpoon = {
		id = "GildedHarpoon",
		name = "Gilded Harpoon",
		rarity = "Epic",
		luck = 2.0,
		weight = 1.4,
		mutationBonus = 0.10,
		barSizeBonus = 0.30, -- GDD: 0
		hookSpeed = 1,
		mutationAffinity = { Golden = 2 },
		description = "Gold calls to gold: doubled Golden mutation odds.",
	},
	AbyssalTrident = {
		id = "AbyssalTrident",
		name = "Abyssal Trident",
		rarity = "Legendary",
		luck = 3.0,
		weight = 1.75,
		mutationBonus = 0.18,
		barSizeBonus = 0.42, -- GDD: 0
		hookSpeed = 0.85,
		mutationAffinity = { Bioluminescent = 2 },
		unlocksMutations = { Bioluminescent = true },
		description = "Forged in the trench. Hooks Bioluminescent catches day or night.",
	},
	ChronosSovereignRod = {
		id = "ChronosSovereignRod",
		name = "Chronos Sovereign Rod",
		rarity = "Mythic",
		luck = 5.0,
		weight = 2.2,
		mutationBonus = 0.30,
		barSizeBonus = 0.55, -- GDD: 0.10
		hookSpeed = 0.4,
		unlocksMutations = { VoidTouched = true },
		description = "Bends time for near-instant hooks and tears open the Void.",
	},
} :: { [string]: RodDef }

-- Star upgrades -----------------------------------------------------------------

Rods.Stars = {
	Max = 5,
	-- Shards needed to go from star N to star N+1.
	ShardsToNext = { 2, 4, 8, 16 },
	LuckPerStar = 0.08, -- +8% luck per star above 1
	WeightPerStar = 0.04,
	-- Gold returned for each duplicate pulled after a rod is already at max stars.
	OverflowRefund = {
		Common = 2_500,
		Uncommon = 5_000,
		Rare = 10_000,
		Epic = 25_000,
		Legendary = 100_000,
		Mythic = 500_000,
	} :: { [Rarity]: number },
}

-- Gacha -------------------------------------------------------------------------

export type ProductDef = {
	key: string,
	id: number, -- developer product id; 0 = not yet created in Creator Hub (purchases disabled)
	pulls: number,
	guaranteeEpic: boolean,
}

-- Published odds (percent). Shown in the shop UI.
local GACHA_WEIGHTS: { [Rarity]: number } = {
	Common = 45.0,
	Uncommon = 30.0,
	Rare = 17.0,
	Epic = 6.0,
	Legendary = 1.7,
	Mythic = 0.3,
}

local PRODUCTS: { ProductDef } = {
	{ key = "GuaranteedEpicPull", id = 0, pulls = 1, guaranteeEpic = true },
	{ key = "LuckyMultiPull", id = 0, pulls = 10, guaranteeEpic = true },
}

Rods.Gacha = {
	-- First-pass prices (the GDD sets none): one pull costs a third of pond slot 4,
	-- so the first "slot or rod?" choice lands around minute 3-6. Star upgrades
	-- (30 duplicates per rod) are the long-tail Gold sink. Needs live tuning.
	PullCost = 25_000,
	MultiCount = 10,
	MultiCost = 225_000, -- 10% multi-pull discount
	-- Pity: an Epic+ rod is guaranteed once this many pulls pass without one.
	PityThreshold = 40,
	RarityWeights = GACHA_WEIGHTS,
	Products = PRODUCTS,
}

local rodsByRarity: { [Rarity]: { RodDef } } = {}
for _, def in Rods.Defs do
	rodsByRarity[def.rarity] = rodsByRarity[def.rarity] or {}
	table.insert(rodsByRarity[def.rarity], def)
end
for _, list in rodsByRarity do
	table.sort(list, function(a: RodDef, b: RodDef): boolean
		return a.id < b.id
	end)
end

function Rods.Get(rodId: string): RodDef?
	return Rods.Defs[rodId]
end

-- Rod stats at a given star level.
function Rods.GetStats(rodId: string, stars: number): RodStats
	local def = Rods.Defs[rodId] or Rods.Defs[Rods.Starter]
	local extra = math.clamp(stars, 1, Rods.Stars.Max) - 1
	return {
		luck = def.luck * (1 + Rods.Stars.LuckPerStar * extra),
		weight = def.weight * (1 + Rods.Stars.WeightPerStar * extra),
		mutationBonus = def.mutationBonus,
		barSizeBonus = def.barSizeBonus,
		hookSpeed = def.hookSpeed,
	}
end

-- One gacha pull. Returns the rod id and the updated pity counter.
function Rods.RollPull(rng: Random, pity: number, guaranteeEpic: boolean?): (string, number)
	local forceEpic = guaranteeEpic == true or pity + 1 >= Rods.Gacha.PityThreshold

	local candidates: { Rarity } = {}
	local weights: { number } = {}
	for _, candidate: Rarity in Rarities.Order do
		if rodsByRarity[candidate] and (not forceEpic or Rarities.IsAtLeast(candidate, "Epic")) then
			table.insert(candidates, candidate)
			table.insert(weights, GACHA_WEIGHTS[candidate])
		end
	end

	local rarity: Rarity = candidates[Weighted.PickIndex(rng, weights)]
	local pool = rodsByRarity[rarity]
	local def = pool[rng:NextInteger(1, #pool)]

	local newPity = if Rarities.IsAtLeast(rarity, "Epic") then 0 else pity + 1
	return def.id, newPity
end

-- Adds one duplicate shard to an owned rod, levelling stars as thresholds are met.
function Rods.ApplyDuplicate(state: RodState, def: RodDef): DuplicateResult
	local result: DuplicateResult = { starsGained = 0, refundGold = 0 }
	if state.stars >= Rods.Stars.Max then
		result.refundGold = Rods.Stars.OverflowRefund[def.rarity]
		return result
	end

	state.shards += 1
	while state.stars < Rods.Stars.Max do
		local needed = Rods.Stars.ShardsToNext[state.stars]
		if state.shards < needed then
			break
		end
		state.shards -= needed
		state.stars += 1
		result.starsGained += 1
	end
	if state.stars >= Rods.Stars.Max then
		state.shards = 0
	end
	return result
end

return Rods
