--!strict
-- Pond slots, pricing, Epic+ auras, social tunables and the pond income
-- formula (GDD §3 + §4 auras).
--
-- ComputeIncome / GetFishingModifiers are pure, so the server uses them as the
-- source of truth and the client can reuse them for previews.

local Types = require(script.Parent.Parent.Types)
local Creatures = require(script.Parent.Creatures)

type CreatureInstance = Types.CreatureInstance

export type AuraDef = {
	id: string,
	name: string,
	description: string,
	-- Only the fields an aura uses are set.
	adjacentIncomeBonus: number?, -- Regeneration
	surgeInterval: number?, -- Static Surge
	surgeChance: number?,
	luckBonus: number?, -- Dragon's Hoard
	weightBonus: number?,
	rarePlusBonus: number?, -- Lure Light
	incomePerUniqueSpecies: number?, -- Tidal Harmony
	starfallInterval: number?, -- Cosmic Tide
	starfallDuration: number?,
	starfallMultiplier: number?,
}

export type IncomeModifiers = {
	starfall: boolean?,
}

export type IncomeBreakdown = {
	perSlot: { [number]: number }, -- final gold/sec per slot (all aura bonuses applied)
	total: number,
	pondMultiplier: number,
	uniqueSpecies: number,
	activeAuras: { [string]: boolean },
}

export type FishingModifiers = {
	luckBonus: number, -- additive (0.25 = +25% rod luck)
	weightBonus: number, -- additive to weight power
	rarePlusBonus: number, -- additive to Rare+ hook weights
}

local PondConfig = {}

PondConfig.PlotCount = 6 -- one pond plot per player, 6-player servers
PondConfig.BackpackCap = 30 -- unslotted creatures a player can hold

-- Slots ---------------------------------------------------------------------------

PondConfig.FreeSlots = 3
PondConfig.MaxGoldSlots = 8
-- Slot prices exactly as written in the GDD (§3).
local GDD_SLOT_COSTS: { [number]: number } = {
	[4] = 500,
	[5] = 2_500,
	[6] = 12_000,
	[7] = 60_000,
	[8] = 250_000,
}

-- Balance refinement. tools/sim/economy.luau showed that with the GDD's gold/sec
-- bands a new player earned all five Gold slots in under 10 minutes at the GDD
-- prices, while the GDD's own target is ~5-10 minutes for slot 4 alone. Rather
-- than shrink the gold/sec numbers players see on every fish, all slot prices
-- are multiplied by one factor, which preserves the GDD's price ratios.
-- Simulated starter-rod pacing at 150x: slot 4 ~6 min, 5 ~12 min, 6 ~24 min,
-- 7 ~50 min, 8 ~1h45m. Re-run the sim after changing this or any income value.
PondConfig.PriceScale = 150

local slotCosts: { [number]: number } = {}
for slot, cost in GDD_SLOT_COSTS do
	slotCosts[slot] = cost * PondConfig.PriceScale
end
PondConfig.SlotCosts = slotCosts

-- Gamepasses. Id 0 = not yet created in Creator Hub (ownership checks skipped).
PondConfig.Gamepasses = {
	{
		key = "PondExpansionI",
		name = "Pond Expansion I",
		id = 0,
		robux = 199,
		slots = 2,
		goldAura = false,
	},
	{
		key = "MasterAquarium",
		name = "Master Aquarium Expansion",
		id = 0,
		robux = 499,
		slots = 2,
		goldAura = true, -- cosmetic gold aura VFX on the pond
	},
}

PondConfig.MaxSlots = PondConfig.MaxGoldSlots + 4

-- Selling -------------------------------------------------------------------------

-- The Fish Appraiser pays this many seconds of a creature's un-aura'd income.
PondConfig.SellSeconds = 40

-- Offline earnings (retention refinement): on return, the pond pays a reduced
-- rate for the time away, capped so idling never beats playing.
PondConfig.Offline = {
	Enabled = true,
	MaxSeconds = 2 * 3600,
	Rate = 0.25,
	MinSeconds = 120,
}

-- Social --------------------------------------------------------------------------

PondConfig.Blessing = {
	Cooldown = 600, -- one feed every 10 minutes
	LuckBonus = 0.15,
	Duration = 300,
	MaxDistance = 70, -- studs from the neighbour's pond water
}

-- Poaching is designed but disabled until it can be playtested. The safe design
-- from the GDD: a successful net never removes the victim's fish. The poacher is
-- paid SiphonSeconds of the target fish's income (minted, not taken), the victim
-- is notified, and a Pond Lock blocks it entirely.
PondConfig.Poaching = {
	Enabled = false,
	NetCost = 5_000,
	Cooldown = 900,
	SiphonSeconds = 30 * 60,
	LockCost = 2_000,
	LockDuration = 20 * 60,
}

-- Auras ---------------------------------------------------------------------------
-- Only Epic, Legendary and Mythic creatures carry an aura, and only while slotted.
-- Regeneration stacks per Axolotl; every other aura applies once per pond.

PondConfig.Auras = {
	Regeneration = {
		id = "Regeneration",
		name = "Regeneration",
		description = "+15% Gold/sec to adjacent pond slots.",
		adjacentIncomeBonus = 0.15,
	},
	StaticSurge = {
		id = "StaticSurge",
		name = "Static Surge",
		description = "Every 60s, shocks a random fish: 5% chance to make it Storm-Charged.",
		surgeInterval = 60,
		surgeChance = 0.05,
	},
	DragonsHoard = {
		id = "DragonsHoard",
		name = "Dragon's Hoard",
		description = "+25% Rod Luck and +10% Weight Boost while you fish.",
		luckBonus = 0.25,
		weightBonus = 0.10,
	},
	LureLight = {
		id = "LureLight",
		name = "Lure Light",
		description = "+12% chance to hook Rare+ creatures.",
		rarePlusBonus = 0.12,
	},
	TidalHarmony = {
		id = "TidalHarmony",
		name = "Tidal Harmony",
		description = "+8% total pond Gold/sec for every unique species slotted.",
		incomePerUniqueSpecies = 0.08,
	},
	CosmicTide = {
		id = "CosmicTide",
		name = "Cosmic Tide",
		description = "Every 5 minutes a Starfall doubles pond income for 30 seconds.",
		starfallInterval = 300,
		starfallDuration = 30,
		starfallMultiplier = 2,
	},
} :: { [string]: AuraDef }

-- Helpers -------------------------------------------------------------------------

function PondConfig.GetSlotCost(slot: number): number?
	return PondConfig.SlotCosts[slot]
end

function PondConfig.GetAuraOf(creature: CreatureInstance): AuraDef?
	local species = Creatures.ById[creature.speciesId]
	if species and species.aura then
		return PondConfig.Auras[species.aura]
	end
	return nil
end

function PondConfig.SellValue(creature: CreatureInstance): number
	return math.max(1, math.floor(Creatures.BaseIncome(creature) * PondConfig.SellSeconds))
end

-- Auras present in a pond, keyed by aura id -> number of carriers.
function PondConfig.GetActiveAuras(pond: { [number]: CreatureInstance }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, creature in pond do
		local aura = PondConfig.GetAuraOf(creature)
		if aura then
			counts[aura.id] = (counts[aura.id] or 0) + 1
		end
	end
	return counts
end

-- GoldPerSec = BaseGold * (Weight/BaseWeight)^1.5 * MutationMultiplier * AuraBonus
-- where AuraBonus = (1 + adjacent Regeneration bonuses) * pond-wide multiplier.
function PondConfig.ComputeIncome(pond: { [number]: CreatureInstance }, modifiers: IncomeModifiers?): IncomeBreakdown
	local adjacency: { [number]: number } = {}
	local species: { [string]: boolean } = {}
	local uniqueSpecies = 0
	local activeAuras: { [string]: boolean } = {}

	for slot, creature in pond do
		if not species[creature.speciesId] then
			species[creature.speciesId] = true
			uniqueSpecies += 1
		end

		local aura = PondConfig.GetAuraOf(creature)
		if aura then
			activeAuras[aura.id] = true
			if aura.adjacentIncomeBonus then
				adjacency[slot - 1] = (adjacency[slot - 1] or 0) + aura.adjacentIncomeBonus
				adjacency[slot + 1] = (adjacency[slot + 1] or 0) + aura.adjacentIncomeBonus
			end
		end
	end

	local pondMultiplier = 1
	if activeAuras.TidalHarmony then
		pondMultiplier *= 1 + (PondConfig.Auras.TidalHarmony.incomePerUniqueSpecies :: number) * uniqueSpecies
	end
	if modifiers and modifiers.starfall then
		pondMultiplier *= PondConfig.Auras.CosmicTide.starfallMultiplier :: number
	end

	local perSlot: { [number]: number } = {}
	local total = 0
	for slot, creature in pond do
		local income = Creatures.BaseIncome(creature) * (1 + (adjacency[slot] or 0)) * pondMultiplier
		perSlot[slot] = income
		total += income
	end

	return {
		perSlot = perSlot,
		total = total,
		pondMultiplier = pondMultiplier,
		uniqueSpecies = uniqueSpecies,
		activeAuras = activeAuras,
	}
end

-- Fishing bonuses the pond grants its owner (Dragon's Hoard, Lure Light).
function PondConfig.GetFishingModifiers(pond: { [number]: CreatureInstance }): FishingModifiers
	local auras = PondConfig.GetActiveAuras(pond)
	local modifiers: FishingModifiers = { luckBonus = 0, weightBonus = 0, rarePlusBonus = 0 }
	if auras.DragonsHoard then
		modifiers.luckBonus += PondConfig.Auras.DragonsHoard.luckBonus :: number
		modifiers.weightBonus += PondConfig.Auras.DragonsHoard.weightBonus :: number
	end
	if auras.LureLight then
		modifiers.rarePlusBonus += PondConfig.Auras.LureLight.rarePlusBonus :: number
	end
	return modifiers
end

return PondConfig
