--!strict
-- Rarity tiers shared by creatures and rods (GDD §4), plus the reeling
-- minigame difficulty each tier produces.

local Types = require(script.Parent.Parent.Types)

type Rarity = Types.Rarity

export type ReelDifficulty = {
	zoneSize: number, -- player catch-zone width as a fraction of the bar
	fishSpeed: number, -- max fish travel speed, bar-lengths per second
	retargetMin: number, -- seconds between fish direction changes
	retargetMax: number,
	dashChance: number, -- chance a retarget is a fast dash
	thrash: number, -- jitter amplitude (bar fraction), 0 = none
	gainRate: number, -- catch progress per second while the fish is in the zone
	drainRate: number, -- catch progress lost per second while it is not
	startProgress: number,
}

export type RarityInfo = {
	id: Rarity,
	order: number,
	dropWeight: number, -- base drop rate in percent
	goldMin: number, -- base gold/sec band for species of this tier
	goldMax: number,
	luckScaling: number, -- weight is multiplied by luck ^ luckScaling
	color: Color3,
	hasAura: boolean,
	announce: boolean, -- server-wide catch announcement
	reel: ReelDifficulty,
}

local Rarities = {}

Rarities.MaxZoneSize = 0.72 -- cap after rod barSizeBonus (was 0.6)

local ORDER: { Rarity } = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }
Rarities.Order = ORDER

Rarities.Info = {
	Common = {
		id = "Common",
		order = 1,
		dropWeight = 52.0,
		goldMin = 2,
		goldMax = 5,
		luckScaling = 0,
		color = Color3.fromRGB(205, 208, 214),
		hasAura = false,
		announce = false,
		reel = {
			zoneSize = 0.38, -- was 0.34
			fishSpeed = 0.35,
			retargetMin = 1.2,
			retargetMax = 2.0,
			dashChance = 0,
			thrash = 0,
			gainRate = 0.30,
			drainRate = 0.12,
			startProgress = 0.35,
		},
	},
	Uncommon = {
		id = "Uncommon",
		order = 2,
		dropWeight = 28.0,
		goldMin = 8,
		goldMax = 18,
		luckScaling = 0.25,
		color = Color3.fromRGB(64, 156, 255),
		hasAura = false,
		announce = false,
		reel = {
			zoneSize = 0.34, -- was 0.30
			fishSpeed = 0.5,
			retargetMin = 1.0,
			retargetMax = 1.8,
			dashChance = 0,
			thrash = 0,
			gainRate = 0.26,
			drainRate = 0.15,
			startProgress = 0.35,
		},
	},
	Rare = {
		id = "Rare",
		order = 3,
		dropWeight = 13.0,
		goldMin = 30,
		goldMax = 65,
		luckScaling = 0.6,
		color = Color3.fromRGB(72, 214, 104),
		hasAura = false,
		announce = false,
		reel = {
			zoneSize = 0.30, -- was 0.26
			fishSpeed = 0.7,
			retargetMin = 0.8,
			retargetMax = 1.5,
			dashChance = 0.15,
			thrash = 0,
			gainRate = 0.22,
			drainRate = 0.18,
			startProgress = 0.35,
		},
	},
	Epic = {
		id = "Epic",
		order = 4,
		dropWeight = 5.0,
		goldMin = 120,
		goldMax = 250,
		luckScaling = 1,
		color = Color3.fromRGB(178, 92, 255),
		hasAura = true,
		announce = false,
		reel = {
			zoneSize = 0.26, -- was 0.22
			fishSpeed = 0.95,
			retargetMin = 0.6,
			retargetMax = 1.2,
			dashChance = 0.3,
			thrash = 0.015,
			gainRate = 0.19,
			drainRate = 0.21,
			startProgress = 0.35,
		},
	},
	Legendary = {
		id = "Legendary",
		order = 5,
		dropWeight = 1.7,
		goldMin = 500,
		goldMax = 1200,
		luckScaling = 1,
		color = Color3.fromRGB(255, 176, 46),
		hasAura = true,
		announce = true,
		reel = {
			zoneSize = 0.22, -- was 0.18
			fishSpeed = 1.2,
			retargetMin = 0.45,
			retargetMax = 1.0,
			dashChance = 0.4,
			thrash = 0.025,
			gainRate = 0.16,
			drainRate = 0.24,
			startProgress = 0.35,
		},
	},
	Mythic = {
		id = "Mythic",
		order = 6,
		dropWeight = 0.3,
		goldMin = 2500,
		goldMax = 6000,
		luckScaling = 1,
		color = Color3.fromRGB(255, 72, 88),
		hasAura = true,
		announce = true,
		reel = {
			-- Boss-style tug-of-war: long fight, punishing drain.
			zoneSize = 0.20, -- was 0.16
			fishSpeed = 1.4,
			retargetMin = 0.35,
			retargetMax = 0.9,
			dashChance = 0.5,
			thrash = 0.035,
			gainRate = 0.13,
			drainRate = 0.26,
			startProgress = 0.4,
		},
	},
} :: { [Rarity]: RarityInfo }

-- Use Get("Epic") rather than Info.Epic: the analyzer rejects literal/dot access
-- on maps keyed by a string-literal union.
function Rarities.Get(rarity: Rarity): RarityInfo
	return Rarities.Info[rarity]
end

function Rarities.IsAtLeast(rarity: Rarity, minimum: Rarity): boolean
	return Rarities.Info[rarity].order >= Rarities.Info[minimum].order
end

-- Shortest time a perfect player could land a fish of this difficulty.
-- The server uses this to reject impossible "instant win" reports.
function Rarities.MinReelTime(reel: ReelDifficulty): number
	return (1 - reel.startProgress) / reel.gainRate
end

return Rarities
