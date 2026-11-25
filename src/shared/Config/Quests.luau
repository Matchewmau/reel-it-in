--!strict
-- Quest definitions (not in the GDD text; the "Active Quests" tracker comes from
-- reference/UIUX.jpeg).
--
-- Two kinds run side by side:
--   * Guide    - a one-time ordered chain that walks a new player through the
--                core loop: catch -> place -> sell -> gacha -> expand.
--   * Daily    - DailyCount quests drawn at random each UTC day.
--
-- A quest listens for one gameplay event (see server/Util/GameEvents.luau) and
-- optionally filters on its context.
--
-- Rewards. Flat gold stops mattering within minutes in this economy, so a
-- reward pays the larger of `rewardGold` and `rewardIncomeSeconds` of the
-- player's current pond income, and the better quests add premium bait.

local Types = require(script.Parent.Parent.Types)
local Rarities = require(script.Parent.Rarities)

export type Filter = {
	biome: Types.Biome?,
	minRarity: Types.Rarity?,
	mutated: boolean?,
	minRatio: number?,
}

export type BaitReward = { id: string, amount: number }

export type QuestDef = {
	id: string,
	title: string,
	event: string,
	goal: number,
	absolute: boolean?, -- the event's amount IS the progress (state quests) rather than adding to it
	filter: Filter?,
	goalIncomeSeconds: number?, -- EarnGold only: goal = max(goal, income * seconds) when rolled
	rewardGold: number,
	rewardIncomeSeconds: number?,
	rewardBait: BaitReward?,
}

local Quests = {}

Quests.DailyCount = 3

-- New-player guide, in order. Guide steps are lifetime milestones: progress is
-- the player's all-time total for the step's event, so they cannot use filters.
Quests.Guide = {
	{
		id = "FirstCatch",
		title = "Catch your first creature (Travel > Freshwater River)",
		event = "Catch",
		goal = 1,
		rewardGold = 2_500,
	},
	{
		id = "FirstPlace",
		title = "Place a creature in your pond (Backpack > Place)",
		event = "PondSlotted",
		goal = 1,
		rewardGold = 2_500,
	},
	{
		id = "CatchFive",
		title = "Catch 5 creatures",
		event = "Catch",
		goal = 5,
		rewardGold = 7_500,
		rewardBait = { id = "GlowingFirefly", amount = 5 },
	},
	{
		id = "FillPond",
		title = "Fill 3 pond slots",
		event = "PondSlotted",
		goal = 3,
		rewardGold = 7_500,
	},
	{
		id = "FirstSale",
		title = "Sell a creature (Backpack > Sell)",
		event = "Sell",
		goal = 1,
		rewardGold = 5_000,
	},
	{
		id = "FirstWish",
		title = "Pull a rod at the Rod Gacha Shrine",
		event = "RodPull",
		goal = 1,
		rewardGold = 10_000,
		rewardBait = { id = "SquidInkCapsule", amount = 5 },
	},
	{
		id = "ExpandPond",
		title = "Unlock a new pond slot (My Pond)",
		event = "BuySlot",
		goal = 1,
		rewardGold = 15_000,
		rewardBait = { id = "StarlightRoe", amount = 1 },
	},
} :: { QuestDef }

-- Daily pool. Every quest here must be completable alone in one session.
Quests.Daily = {
	{
		id = "DailyCatch",
		title = "Catch 10 creatures",
		event = "Catch",
		goal = 10,
		rewardGold = 5_000,
		rewardIncomeSeconds = 60,
	},
	{
		id = "DailyFreshwater",
		title = "Catch 6 freshwater creatures",
		event = "Catch",
		goal = 6,
		filter = { biome = "Freshwater" },
		rewardGold = 4_000,
		rewardIncomeSeconds = 45,
	},
	{
		id = "DailySaltwater",
		title = "Catch 6 saltwater creatures",
		event = "Catch",
		goal = 6,
		filter = { biome = "Saltwater" },
		rewardGold = 4_000,
		rewardIncomeSeconds = 45,
	},
	{
		id = "DailyUncommon",
		title = "Catch 5 Uncommon or better",
		event = "Catch",
		goal = 5,
		filter = { minRarity = "Uncommon" },
		rewardGold = 6_000,
		rewardIncomeSeconds = 60,
	},
	{
		id = "DailyRare",
		title = "Catch 2 Rare or better",
		event = "Catch",
		goal = 2,
		filter = { minRarity = "Rare" },
		rewardGold = 8_000,
		rewardIncomeSeconds = 90,
		rewardBait = { id = "GlowingFirefly", amount = 3 },
	},
	{
		id = "DailyMutation",
		title = "Catch a mutated creature",
		event = "Catch",
		goal = 1,
		filter = { mutated = true },
		rewardGold = 8_000,
		rewardIncomeSeconds = 90,
		rewardBait = { id = "SquidInkCapsule", amount = 3 },
	},
	{
		id = "DailyHeavy",
		title = "Catch 2 creatures at 2x weight or more",
		event = "Catch",
		goal = 2,
		filter = { minRatio = 2 },
		rewardGold = 8_000,
		rewardIncomeSeconds = 90,
	},
	{
		id = "DailySell",
		title = "Sell 5 creatures",
		event = "Sell",
		goal = 5,
		rewardGold = 4_000,
		rewardIncomeSeconds = 45,
	},
	{
		id = "DailyEarn",
		title = "Earn Gold from any source",
		event = "EarnGold",
		goal = 20_000,
		goalIncomeSeconds = 300,
		rewardGold = 5_000,
		rewardIncomeSeconds = 60,
		rewardBait = { id = "StarlightRoe", amount = 1 },
	},
	{
		id = "DailyWish",
		title = "Pull a rod at the Rod Gacha Shrine",
		event = "RodPull",
		goal = 1,
		rewardGold = 5_000,
		rewardIncomeSeconds = 60,
	},
} :: { QuestDef }

for _, def in Quests.Guide do
	assert(def.filter == nil, `Guide quest {def.id} cannot use a filter`)
end

local dailyById: { [string]: QuestDef } = {}
for _, def in Quests.Daily do
	assert(dailyById[def.id] == nil, `Duplicate daily quest id {def.id}`)
	dailyById[def.id] = def
end
assert(#Quests.Daily >= Quests.DailyCount, "Daily pool is smaller than DailyCount")

function Quests.GetDaily(id: string): QuestDef?
	return dailyById[id]
end

-- Does an event's context satisfy the quest's filter? Context comes from the
-- server's own GameEvents, never from a client.
function Quests.Matches(def: QuestDef, context: { [string]: any }): boolean
	local filter = def.filter
	if not filter then
		return true
	end
	if filter.biome and context.biome ~= filter.biome then
		return false
	end
	if filter.minRarity then
		local order = 0
		for _, rarity: Types.Rarity in Rarities.Order do
			if rarity == context.rarity then
				order = Rarities.Info[rarity].order
			end
		end
		if order < Rarities.Get(filter.minRarity).order then
			return false
		end
	end
	if filter.mutated and (context.mutation == nil or context.mutation == "Normal") then
		return false
	end
	if filter.minRatio and (type(context.ratio) ~= "number" or context.ratio < filter.minRatio) then
		return false
	end
	return true
end

return Quests
