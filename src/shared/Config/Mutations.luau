--!strict
-- Mutation table and roll logic (GDD §4 "Mutations").
--
-- A creature carries at most one mutation. Rolls go from rarest to most
-- common so a lucky Void-Touched roll is never masked by an Albino one.

local Types = require(script.Parent.Parent.Types)
local Weather = require(script.Parent.Weather)

type MutationId = Types.MutationId
type WeatherId = Types.WeatherId

export type MutationVisual = {
	tint: Color3?, -- body colour the palette is blended toward
	tintStrength: number, -- 0..1 blend amount
	material: Enum.Material?, -- body material override
	finNeon: Color3?, -- fins / lure switch to Neon in this colour
	light: Color3?, -- PointLight on the RootPart
	particle: Color3?, -- sparkle emitter on AuraAttachment
}

export type MutationDef = {
	id: MutationId,
	name: string,
	multiplier: number,
	-- Chance when the mutation's condition is met.
	baseChance: number,
	-- "Always": no condition. "Night": needs night or an unlock.
	-- "Weather": chance comes from weatherChance. "Unlock": needs a rod/bait unlock.
	condition: "Always" | "Night" | "Weather" | "Unlock" | "Never",
	weatherChance: { [WeatherId]: number }?,
	description: string,
	visual: MutationVisual,
}

export type RollContext = {
	mutationBonus: number, -- rod "+X% Mutation", applied as a relative boost to every chance
	isNight: boolean,
	weather: WeatherId,
	affinity: { [MutationId]: number }?, -- per-mutation odds multipliers (rod x bait)
	unlocked: { [MutationId]: boolean }?, -- conditions bypassed by rod/bait
}

local Mutations = {}

Mutations.MaxChance = 0.9

Mutations.Defs = {
	Normal = {
		id = "Normal",
		name = "Normal",
		multiplier = 1.0,
		baseChance = 0,
		condition = "Never",
		description = "Standard VoxelMorph palette.",
		visual = { tintStrength = 0 },
	},
	Albino = {
		id = "Albino",
		name = "Albino",
		multiplier = 1.5,
		baseChance = 0.08,
		condition = "Always",
		description = "White/pastel body with a sparkle trail.",
		visual = {
			tint = Color3.fromRGB(250, 246, 255),
			tintStrength = 0.85,
			particle = Color3.fromRGB(255, 255, 255),
		},
	},
	Golden = {
		id = "Golden",
		name = "Golden",
		multiplier = 2.5,
		baseChance = 0.03,
		condition = "Always",
		description = "Reflective gold body shedding coin particles.",
		visual = {
			tint = Color3.fromRGB(255, 200, 40),
			tintStrength = 0.9,
			material = Enum.Material.Metal,
			particle = Color3.fromRGB(255, 221, 87),
		},
	},
	Bioluminescent = {
		id = "Bioluminescent",
		name = "Bioluminescent",
		multiplier = 4.0,
		baseChance = 0.025,
		condition = "Night",
		description = "Glowing cyan/magenta fins. Appears at night or with deep-water bait.",
		visual = {
			tintStrength = 0,
			finNeon = Color3.fromRGB(0, 240, 255),
			light = Color3.fromRGB(80, 220, 255),
			particle = Color3.fromRGB(255, 80, 230),
		},
	},
	StormCharged = {
		id = "StormCharged",
		name = "Storm-Charged",
		multiplier = 6.0,
		baseChance = 0,
		condition = "Weather",
		weatherChance = { Clear = 0, Rain = 0.06, Storm = 0.15 }, -- GDD/initial: Clear 0, Rain 0.005, Storm 0.02
		description = "Crackling with electricity. Only hooks during rain and thunderstorms.",
		visual = {
			tint = Color3.fromRGB(120, 170, 255),
			tintStrength = 0.35,
			finNeon = Color3.fromRGB(255, 244, 120),
			light = Color3.fromRGB(190, 220, 255),
			particle = Color3.fromRGB(255, 250, 170),
		},
	},
	VoidTouched = {
		id = "VoidTouched",
		name = "Void-Touched",
		multiplier = 10.0,
		baseChance = 0.005,
		condition = "Unlock",
		description = "Obsidian core wrapped in a purple glitch aura. Needs a Mythic rod or void-grade bait.",
		visual = {
			tint = Color3.fromRGB(22, 12, 34),
			tintStrength = 0.92,
			finNeon = Color3.fromRGB(190, 70, 255),
			light = Color3.fromRGB(170, 60, 255),
			particle = Color3.fromRGB(200, 90, 255),
		},
	},
} :: { [MutationId]: MutationDef }

-- Rarest first.
local ROLL_ORDER: { MutationId } = { "VoidTouched", "StormCharged", "Bioluminescent", "Golden", "Albino" }
Mutations.RollOrder = ROLL_ORDER

function Mutations.Get(id: MutationId): MutationDef
	return Mutations.Defs[id]
end

function Mutations.GetMultiplier(id: MutationId): number
	local def = Mutations.Defs[id]
	return if def then def.multiplier else 1
end

-- Final chance for one mutation under the given context (0 when unavailable).
function Mutations.GetChance(id: MutationId, ctx: RollContext): number
	local def = Mutations.Defs[id]
	local unlocked = ctx.unlocked ~= nil and ctx.unlocked[id] == true
	local chance = 0

	if def.condition == "Always" then
		chance = def.baseChance
	elseif def.condition == "Night" then
		if ctx.isNight or unlocked then
			chance = def.baseChance
		end
	elseif def.condition == "Weather" then
		chance = if def.weatherChance then def.weatherChance[ctx.weather] or 0 else 0
	elseif def.condition == "Unlock" then
		if unlocked then
			chance = def.baseChance
		end
	end

	if chance <= 0 then
		return 0
	end

	local affinity = if ctx.affinity then ctx.affinity[id] or 1 else 1
	local weatherMult = if def.condition ~= "Weather" then Weather.Get(ctx.weather).mutationMultiplier else 1
	return math.clamp(chance * weatherMult * affinity * (1 + ctx.mutationBonus), 0, Mutations.MaxChance)
end

function Mutations.Roll(rng: Random, ctx: RollContext): MutationId
	for _, id: MutationId in Mutations.RollOrder do
		local chance = Mutations.GetChance(id, ctx)
		if chance > 0 and rng:NextNumber() < chance then
			return id
		end
	end
	return "Normal"
end

return Mutations
