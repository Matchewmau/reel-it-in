--!strict
-- Creature roster, rarity rolls, and the weight / scale / income formulas
-- (GDD §4).

local Types = require(script.Parent.Parent.Types)
local Rarities = require(script.Parent.Rarities)
local Mutations = require(script.Parent.Mutations)
local Weighted = require(script.Parent.Parent.Util.Weighted)

type Rarity = Types.Rarity
type Biome = Types.Biome
type CreatureInstance = Types.CreatureInstance

export type Palette = {
	primary: Color3,
	secondary: Color3,
	accent: Color3,
}

export type Species = {
	id: string, -- also the model name under ReplicatedStorage/Assets/Creatures/<Biome>/
	name: string,
	rarity: Rarity,
	biome: Biome,
	baseWeight: number, -- kg at 1.0x
	baseGold: number, -- gold/sec at 1.0x weight, no mutation, no aura
	length: number, -- model length in studs at 1.0x (placeholder rigs + swim margins)
	aura: string?, -- key into PondConfig.Auras (Epic+ only)
	description: string,
	palette: Palette,
}

export type RarityRollContext = {
	luck: number, -- total luck multiplier (rod x buffs x bait)
	rarityMultipliers: { [Rarity]: number }?, -- bait odds multipliers
	rarePlusBonus: number?, -- additive bonus applied to Rare+ weights (Lure Light, storms)
}

local Creatures = {}

-- Weight roll tunables (GDD: 0.5x-4.0x, 0.5% Colossal 5.0x-8.0x).
Creatures.Weight = {
	MinRatio = 0.75, -- GDD: 0.5
	MaxRatio = 6.0, -- GDD: 4.0
	ColossalChance = 0.015, -- GDD: 0.005 (1.5% so players regularly hit Colossal)
	ColossalMinRatio = 7.0, -- GDD: 5.0
	ColossalMaxRatio = 12.0, -- GDD: 8.0
	-- Design refinement: rolls are skewed toward the low end (ratio = min + range * u^Skew)
	-- so big rolls stay exciting. A rod's Weight stat divides the exponent,
	-- which shifts the whole curve upward without ever exceeding MaxRatio.
	SkewExponent = 1.9, -- was 2.5
	ScaleExponent = 0.65, -- ModelScale = ratio ^ 0.65
	IncomeExponent = 1.5, -- GoldPerSec scales with ratio ^ 1.5
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local SPECIES: { Species } = {
	-- Freshwater (River & Waterfall) ------------------------------------------------
	{
		id = "RiverMinnow",
		name = "River Minnow",
		rarity = "Common",
		biome = "Freshwater",
		baseWeight = 0.2,
		baseGold = 2,
		length = 1.6,
		description = "Small, fast-swimming starter fish.",
		palette = { primary = rgb(160, 178, 190), secondary = rgb(226, 232, 236), accent = rgb(90, 120, 140) },
	},
	{
		id = "SpottedKoi",
		name = "Spotted Koi",
		rarity = "Uncommon",
		biome = "Freshwater",
		baseWeight = 3,
		baseGold = 10,
		length = 2.6,
		description = "Vibrant orange and white voxel scales.",
		palette = { primary = rgb(255, 132, 38), secondary = rgb(250, 246, 240), accent = rgb(30, 30, 34) },
	},
	{
		id = "AlligatorGar",
		name = "Alligator Gar",
		rarity = "Rare",
		biome = "Freshwater",
		baseWeight = 30,
		baseGold = 36,
		length = 5.2,
		description = "Long armored snout and a heavy weight roll.",
		palette = { primary = rgb(92, 110, 72), secondary = rgb(196, 190, 150), accent = rgb(52, 62, 44) },
	},
	{
		id = "CrystalAxolotl",
		name = "Crystal Axolotl",
		rarity = "Epic",
		biome = "Freshwater",
		baseWeight = 1.5,
		baseGold = 140,
		length = 2.8,
		aura = "Regeneration",
		description = "A translucent pink healer that energises its neighbours.",
		palette = { primary = rgb(255, 170, 210), secondary = rgb(255, 224, 240), accent = rgb(120, 230, 255) },
	},
	{
		id = "ThunderheadCatfish",
		name = "Thunderhead Catfish",
		rarity = "Legendary",
		biome = "Freshwater",
		baseWeight = 45,
		baseGold = 600,
		length = 6.0,
		aura = "StaticSurge",
		description = "Storm-grey bruiser whose whiskers arc with static.",
		palette = { primary = rgb(70, 78, 96), secondary = rgb(150, 160, 180), accent = rgb(255, 240, 110) },
	},
	{
		id = "JadeRiverDragon",
		name = "Jade River Dragon",
		rarity = "Mythic",
		biome = "Freshwater",
		baseWeight = 180,
		baseGold = 3000,
		length = 8.0,
		aura = "DragonsHoard",
		description = "Serpentine guardian of the waterfall. Luck follows its owner.",
		palette = { primary = rgb(40, 170, 120), secondary = rgb(190, 240, 200), accent = rgb(255, 208, 70) },
	},

	-- Saltwater (Ocean Pier) --------------------------------------------------------
	{
		id = "Clownfish",
		name = "Clownfish",
		rarity = "Common",
		biome = "Saltwater",
		baseWeight = 0.25,
		baseGold = 3,
		length = 1.6,
		description = "Classic blocky reef swimmer.",
		palette = { primary = rgb(255, 120, 30), secondary = rgb(255, 255, 255), accent = rgb(24, 24, 28) },
	},
	{
		id = "Pufferfish",
		name = "Pufferfish",
		rarity = "Uncommon",
		biome = "Saltwater",
		baseWeight = 2,
		baseGold = 12,
		length = 2.2,
		description = "Inflates when other players come to inspect it.",
		palette = { primary = rgb(236, 210, 110), secondary = rgb(255, 248, 220), accent = rgb(120, 92, 40) },
	},
	{
		id = "GoblinShark",
		name = "Goblin Shark",
		rarity = "Rare",
		biome = "Saltwater",
		baseWeight = 150,
		baseGold = 45,
		length = 6.5,
		description = "Extended-jaw voxel rig with a high base weight.",
		palette = { primary = rgb(226, 164, 170), secondary = rgb(244, 214, 216), accent = rgb(110, 70, 84) },
	},
	{
		id = "AbyssalAngler",
		name = "Abyssal Angler",
		rarity = "Epic",
		biome = "Saltwater",
		baseWeight = 12,
		baseGold = 180,
		length = 8.0, -- matches the authored rig (tools/studio/BuildAbyssalAngler.luau)
		aura = "LureLight",
		description = "Deep-sea ambusher. Its lure draws rarer catches to your line.",
		palette = { primary = rgb(44, 34, 78), secondary = rgb(96, 70, 150), accent = rgb(120, 230, 255) },
	},
	{
		id = "PhantomMantaRay",
		name = "Phantom Manta Ray",
		rarity = "Legendary",
		biome = "Saltwater",
		baseWeight = 220,
		baseGold = 750,
		length = 7.0,
		aura = "TidalHarmony",
		description = "Ghostly glider that thrives in a diverse pond.",
		palette = { primary = rgb(56, 66, 120), secondary = rgb(170, 190, 255), accent = rgb(120, 255, 240) },
	},
	{
		id = "CelestialLeviathan",
		name = "Celestial Leviathan",
		rarity = "Mythic",
		biome = "Saltwater",
		baseWeight = 2000,
		baseGold = 3600,
		length = 9.0,
		aura = "CosmicTide",
		description = "A star-flecked titan that calls down Starfall on its pond.",
		palette = { primary = rgb(24, 26, 70), secondary = rgb(110, 90, 220), accent = rgb(255, 236, 160) },
	},
}

Creatures.List = SPECIES
Creatures.ById = {} :: { [string]: Species }

local pools: { [string]: { Species } } = {}

for _, species in SPECIES do
	assert(Creatures.ById[species.id] == nil, `Duplicate species id {species.id}`)
	local info = Rarities.Info[species.rarity]
	assert(
		species.baseGold >= info.goldMin and species.baseGold <= info.goldMax,
		`{species.id} baseGold is outside its rarity band`
	)
	assert(species.aura == nil or info.hasAura, `{species.id} has an aura but its rarity cannot carry one`)
	Creatures.ById[species.id] = species

	local key = species.biome .. "/" .. species.rarity
	pools[key] = pools[key] or {}
	table.insert(pools[key], species)
end

function Creatures.Get(speciesId: string): Species?
	return Creatures.ById[speciesId]
end

function Creatures.GetPool(biome: Biome, rarity: Rarity): { Species }
	return pools[biome .. "/" .. rarity] or {}
end

-- Rarity ----------------------------------------------------------------------------

-- Effective (unnormalised) drop weights.
--   weight = base * luck ^ luckScaling * baitMultiplier * (1 + rarePlusBonus for Rare+)
-- Luck never touches Common, lightly lifts Uncommon/Rare and fully scales Epic+,
-- so a 5x luck rod turns a 0.3% Mythic into ~0.9% rather than breaking the table.
function Creatures.GetRarityWeights(ctx: RarityRollContext): { [Rarity]: number }
	local luck = math.max(ctx.luck, 0.1)
	local weights: { [Rarity]: number } = {}
	for _, rarity: Rarity in Rarities.Order do
		local info = Rarities.Info[rarity]
		local weight = info.dropWeight * math.pow(luck, info.luckScaling)
		if ctx.rarityMultipliers and ctx.rarityMultipliers[rarity] then
			weight *= ctx.rarityMultipliers[rarity]
		end
		if ctx.rarePlusBonus and Rarities.IsAtLeast(rarity, "Rare") then
			weight *= 1 + ctx.rarePlusBonus
		end
		weights[rarity] = weight
	end
	return weights
end

-- Normalised odds (sum to 1) for UI disclosure.
function Creatures.GetRarityOdds(ctx: RarityRollContext): { [Rarity]: number }
	local weights = Creatures.GetRarityWeights(ctx)
	local total = 0
	for _, weight in weights do
		total += weight
	end
	local odds: { [Rarity]: number } = {}
	for _, rarity: Rarity in Rarities.Order do
		odds[rarity] = weights[rarity] / total
	end
	return odds
end

function Creatures.RollRarity(rng: Random, ctx: RarityRollContext): Rarity
	local weights = Creatures.GetRarityWeights(ctx)
	local ordered: { number } = {}
	for index, rarity: Rarity in Rarities.Order do
		ordered[index] = weights[rarity]
	end
	return Rarities.Order[Weighted.PickIndex(rng, ordered)]
end

-- Picks a species of the rolled rarity; if the biome has none at that tier,
-- steps down a tier at a time until it finds one.
function Creatures.RollSpecies(rng: Random, biome: Biome, rarity: Rarity): Species
	local order = Rarities.Info[rarity].order
	for index = order, 1, -1 do
		local pool = Creatures.GetPool(biome, Rarities.Order[index])
		if #pool > 0 then
			return pool[rng:NextInteger(1, #pool)]
		end
	end
	error(`No species available for biome {biome}`)
end

-- Weight / scale / income -----------------------------------------------------------

-- Returns (ratio, isColossal). `weightPower` is the combined rod/aura Weight stat.
function Creatures.RollWeightRatio(rng: Random, weightPower: number, minRatio: number?): (number, boolean)
	local cfg = Creatures.Weight
	if rng:NextNumber() < cfg.ColossalChance then
		return rng:NextNumber(cfg.ColossalMinRatio, cfg.ColossalMaxRatio), true
	end

	local exponent = cfg.SkewExponent / math.max(weightPower, 0.25)
	local ratio = cfg.MinRatio + (cfg.MaxRatio - cfg.MinRatio) * math.pow(rng:NextNumber(), exponent)
	if minRatio then
		ratio = math.max(ratio, minRatio)
	end
	return ratio, false
end

function Creatures.GetWeightRatio(creature: CreatureInstance): number
	local species = Creatures.ById[creature.speciesId]
	if not species then
		return 1
	end
	return creature.weight / species.baseWeight
end

-- ModelScale = (RolledWeight / BaseWeight) ^ 0.65
function Creatures.ModelScale(ratio: number): number
	return math.pow(math.max(ratio, 0.01), Creatures.Weight.ScaleExponent)
end

-- BaseGold * (RolledWeight / BaseWeight) ^ 1.5 * MutationMultiplier.
-- The AuraBonus term of the GDD formula is applied in PondConfig.ComputeIncome,
-- because it depends on what else is in the pond.
function Creatures.BaseIncome(creature: CreatureInstance): number
	local species = Creatures.ById[creature.speciesId]
	if not species then
		return 0
	end
	local ratio = creature.weight / species.baseWeight
	return species.baseGold
		* math.pow(ratio, Creatures.Weight.IncomeExponent)
		* Mutations.GetMultiplier(creature.mutation)
end

return Creatures
