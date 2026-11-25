--!strict
-- Shared type definitions. No runtime logic lives here.

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"
export type Biome = "Freshwater" | "Saltwater"
export type MutationId = "Normal" | "Albino" | "Golden" | "Bioluminescent" | "StormCharged" | "VoidTouched"
export type WeatherId = "Clear" | "Rain" | "Storm"

-- One caught creature. `weight` is the source of truth; the weight ratio
-- (weight / species.baseWeight) drives model scale and income.
export type CreatureInstance = {
	uid: string,
	speciesId: string,
	weight: number,
	mutation: MutationId,
	colossal: boolean,
	caughtAt: number,
}

export type RodState = {
	stars: number,
	shards: number,
}

-- One active daily quest (definition lives in Config/Quests.luau).
export type QuestProgress = {
	id: string,
	progress: number,
	goal: number,
	baseline: number,
	done: boolean,
}

-- A quest as shown in the HUD.
export type QuestView = {
	id: string,
	kind: string, -- "Guide" | "Daily"
	title: string,
	progress: number,
	goal: number,
	done: boolean,
	reward: string,
}

-- One row of the Server Best Catches board.
export type BestCatch = {
	userId: number,
	name: string,
	speciesId: string,
	weight: number,
	mutation: MutationId,
}

-- Persisted player data (DataStore). Slot maps use string keys because
-- DataStores and remotes both mangle sparse numeric keys.
export type Profile = {
	version: number,
	gold: number,
	slotsUnlocked: number,
	creatures: { [string]: CreatureInstance },
	pond: { [string]: string },
	nextUid: number,
	rods: { [string]: RodState },
	equippedRod: string,
	baits: { [string]: number },
	equippedBait: string,
	pity: { rod: number },
	stats: { catches: number, heaviestKg: number, goldEarned: number },
	discovered: { [string]: boolean },
	lastBlessAt: number,
	lastSeen: number,
	purchases: { string },
	-- `counts` = lifetime totals per gameplay event; the guide chain reads them, so
	-- anything a player did before a guide step unlocked still counts toward it.
	quests: { day: number, daily: { QuestProgress }, step: number, counts: { [string]: number } },
}

-- What the owning client receives over StateSync (profile + derived values).
export type Snapshot = {
	gold: number,
	slotsUnlocked: number,
	creatures: { [string]: CreatureInstance },
	pond: { [string]: string },
	rods: { [string]: RodState },
	equippedRod: string,
	baits: { [string]: number },
	equippedBait: string,
	pity: { rod: number },
	stats: { catches: number, heaviestKg: number, goldEarned: number },
	discovered: { [string]: boolean },
	-- Added by PondService
	plot: number,
	maxSlots: number,
	backpackCap: number,
	incomeTotal: number,
	incomePerSlot: { [string]: number },
	luckBuffRemaining: number,
	blessCooldownRemaining: number,
	starfallRemaining: number,
	-- Added by QuestService
	quests: { QuestView },
	questResetIn: number,
}

export type PondFish = {
	slot: number,
	uid: string,
	speciesId: string,
	weight: number,
	mutation: MutationId,
	colossal: boolean,
	goldPerSec: number,
}

-- Public pond state replicated to every client for visuals + inspection cards.
export type PondSnapshot = {
	plot: number,
	ownerUserId: number,
	ownerName: string,
	maxSlots: number,
	total: number,
	starfallRemaining: number,
	goldAura: boolean,
	fish: { PondFish },
}

return {}
