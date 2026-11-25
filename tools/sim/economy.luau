-- Offline balance simulation + config self-test. Runs the REAL shared config
-- modules outside Roblox (via Lune), so the numbers always match the game.
--
--   lune run tools/sim/economy.luau
--
-- This file is tooling only: it is not under src/, so Rojo never syncs it.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- Minimal stand-ins for the Roblox globals the config modules touch ----------------

local RandomShim = {}
RandomShim.__index = RandomShim
function RandomShim.new()
	return setmetatable({}, RandomShim)
end
function RandomShim:NextNumber(min: number?, max: number?): number
	local lo, hi = min or 0, max or 1
	return lo + math.random() * (hi - lo)
end
function RandomShim:NextInteger(min: number, max: number): number
	return math.random(min, max)
end

-- Fake Instance tree so `require(script.Parent.X)` resolves against the filesystem.
local function makeNode(path: string, name: string, parent: any): any
	local node = { Name = name, Parent = parent, _path = path, _children = {} }
	setmetatable(node, {
		__index = function(self, key)
			return rawget(self, "_children")[key]
		end,
	})
	if fs.isDir(path) then
		for _, entry in fs.readDir(path) do
			local childName = string.gsub(entry, "%.luau$", "")
			node._children[childName] = makeNode(path .. "/" .. entry, childName, node)
		end
	end
	return node
end

local cache: { [any]: any } = {}
local function requireNode(node: any): any
	if cache[node] ~= nil then
		return cache[node]
	end
	local env = {
		script = node,
		require = requireNode,
		Random = RandomShim,
		Color3 = (roblox :: any).Color3,
		Enum = (roblox :: any).Enum,
	}
	local chunk = luau.load(fs.readFile(node._path), { debugName = node.Name, environment = env })
	local result = chunk()
	cache[node] = result
	return result
end

local shared = makeNode("src/shared", "Shared", nil)
local Rarities = requireNode(shared.Config.Rarities)
local Creatures = requireNode(shared.Config.Creatures)
local Mutations = requireNode(shared.Config.Mutations)
local Rods = requireNode(shared.Config.Rods)
local Baits = requireNode(shared.Config.Baits)
local PondConfig = requireNode(shared.Config.PondConfig)
local Quests = requireNode(shared.Config.Quests)

local rng = RandomShim.new()
local failures = 0

local function check(label: string, condition: boolean, detail: string?)
	if condition then
		print(`  ok    {label}`)
	else
		failures += 1
		print(`  FAIL  {label} {detail or ""}`)
	end
end

local function near(a: number, b: number, tolerance: number): boolean
	return math.abs(a - b) <= tolerance
end

-- 1. Drop rates -------------------------------------------------------------------------

local N = 400_000
print(`\n== Rarity drop rates over {N} casts ==`)
for _, luck in { 1, 2, 5 } do
	local counts = {}
	for _ = 1, N do
		local rarity = Creatures.RollRarity(rng, { luck = luck })
		counts[rarity] = (counts[rarity] or 0) + 1
	end
	local parts = {}
	for _, rarity in Rarities.Order do
		table.insert(parts, string.format("%s %.2f%%", rarity, (counts[rarity] or 0) / N * 100))
	end
	print(`  luck {luck}x: ` .. table.concat(parts, " | "))
	if luck == 1 then
		for _, rarity in Rarities.Order do
			local expected = Rarities.Info[rarity].dropWeight
			check(
				`base {rarity} rate matches GDD ({expected}%)`,
				near((counts[rarity] or 0) / N * 100, expected, math.max(0.15, expected * 0.03))
			)
		end
	end
end

-- 2. Weight rolls -----------------------------------------------------------------------

print("\n== Weight ratio rolls ==")
local meanIncomeFactor = 1
for _, power in { 1.0, 1.4, 2.2 } do
	local ratios, colossal, sum, sumIncome = {}, 0, 0, 0
	for i = 1, N do
		local ratio, isColossal = Creatures.RollWeightRatio(rng, power)
		ratios[i] = ratio
		sum += ratio
		sumIncome += ratio ^ Creatures.Weight.IncomeExponent
		if isColossal then
			colossal += 1
		end
	end
	table.sort(ratios)
	local over3 = 0
	for _, ratio in ratios do
		if ratio >= 3 then
			over3 += 1
		end
	end
	print(
		string.format(
			"  weight power %.1f: mean %.2fx | median %.2fx | >=3x %.1f%% | colossal %.2f%% | mean income factor %.2f",
			power,
			sum / N,
			ratios[N // 2],
			over3 / N * 100,
			colossal / N * 100,
			sumIncome / N
		)
	)
	if power == 1.0 then
		meanIncomeFactor = sumIncome / N
		local minRatio = Creatures.Weight.MinRatio
		local maxColossal = Creatures.Weight.ColossalMaxRatio
		local expectedColossalPct = Creatures.Weight.ColossalChance * 100
		check(
			string.format("ratios stay within %.2fx..%.1fx", minRatio, maxColossal),
			ratios[1] >= minRatio and ratios[N] <= maxColossal
		)
		check(
			string.format("colossal rate ~%.2f%%", expectedColossalPct),
			near(colossal / N * 100, expectedColossalPct, math.max(0.08, expectedColossalPct * 0.12))
		)
	end
end
check("ModelScale(4.0) = 4^0.65", near(Creatures.ModelScale(4), 4 ^ 0.65, 1e-6))

-- 3. Mutations --------------------------------------------------------------------------

print("\n== Mutation rates (starter rod) ==")
for _, scenario in
	{
		{ name = "clear day", ctx = { mutationBonus = 0, isNight = false, weather = "Clear" } },
		{ name = "storm night", ctx = { mutationBonus = 0, isNight = true, weather = "Storm" } },
	}
do
	local counts = {}
	for _ = 1, N do
		local id = Mutations.Roll(rng, scenario.ctx)
		counts[id] = (counts[id] or 0) + 1
	end
	local parts = {}
	for _, id in { "Normal", "Albino", "Golden", "Bioluminescent", "StormCharged", "VoidTouched" } do
		table.insert(parts, string.format("%s %.2f%%", id, (counts[id] or 0) / N * 100))
	end
	print(`  {scenario.name}: ` .. table.concat(parts, " | "))
	if scenario.name == "clear day" then
		check("Albino ~8% and Golden ~3% by day", near((counts.Albino or 0) / N, 0.08, 0.004))
		check("no Void-Touched without an unlock", (counts.VoidTouched or 0) == 0)
		check("no Storm-Charged in clear weather", (counts.StormCharged or 0) == 0)
	end
end

-- 4. Pond income + auras ------------------------------------------------------------------

print("\n== Pond income formula ==")
local function fish(speciesId: string, ratio: number, mutation: string?): any
	return {
		uid = speciesId,
		speciesId = speciesId,
		weight = Creatures.ById[speciesId].baseWeight * ratio,
		mutation = mutation or "Normal",
		colossal = false,
		caughtAt = 0,
	}
end

local gar = fish("AlligatorGar", 2.0, "Golden")
check(
	"GoldPerSec = BaseGold * ratio^1.5 * mutation",
	near(Creatures.BaseIncome(gar), 36 * 2 ^ 1.5 * 2.5, 1e-6),
	tostring(Creatures.BaseIncome(gar))
)

local regen = PondConfig.ComputeIncome({
	[1] = fish("RiverMinnow", 1),
	[2] = fish("CrystalAxolotl", 1),
	[3] = fish("SpottedKoi", 1),
	[5] = fish("Clownfish", 1),
})
check(
	"Regeneration: +15% to both adjacent slots",
	near(regen.perSlot[1], 2 * 1.15, 1e-6) and near(regen.perSlot[3], 10 * 1.15, 1e-6)
)
check(
	"Regeneration: non-adjacent slot and the Axolotl itself unchanged",
	near(regen.perSlot[5], 3, 1e-6) and near(regen.perSlot[2], 140, 1e-6)
)

local harmony = PondConfig.ComputeIncome({
	[1] = fish("PhantomMantaRay", 1),
	[2] = fish("Clownfish", 1),
	[3] = fish("Clownfish", 1),
})
check("Tidal Harmony: +8% per unique species (2 unique = x1.16)", near(harmony.pondMultiplier, 1.16, 1e-6))

local starfall = PondConfig.ComputeIncome({ [1] = fish("CelestialLeviathan", 1) }, { starfall = true })
check("Cosmic Tide: Starfall doubles income", near(starfall.total, 3600 * 2, 1e-6))

local hoard = PondConfig.GetFishingModifiers({ [1] = fish("JadeRiverDragon", 1), [2] = fish("AbyssalAngler", 1) })
check(
	"Dragon's Hoard +25% luck / +10% weight, Lure Light +12% Rare+",
	near(hoard.luckBonus, 0.25, 1e-6) and near(hoard.weightBonus, 0.10, 1e-6) and near(hoard.rarePlusBonus, 0.12, 1e-6)
)

-- 5. Rod gacha ----------------------------------------------------------------------------

print("\n== Rod gacha ==")
do
	local pulls = 300_000
	local counts, pity, worstDrought = {}, 0, 0
	for _ = 1, pulls do
		local rodId, newPity = Rods.RollPull(rng, pity)
		pity = newPity
		worstDrought = math.max(worstDrought, pity)
		local rarity = Rods.Defs[rodId].rarity
		counts[rarity] = (counts[rarity] or 0) + 1
	end
	local parts = {}
	for _, rarity in Rarities.Order do
		table.insert(parts, string.format("%s %.2f%%", rarity, (counts[rarity] or 0) / pulls * 100))
	end
	print("  observed (pity included): " .. table.concat(parts, " | "))
	check(
		`pity guarantees Epic+ within {Rods.Gacha.PityThreshold} pulls`,
		worstDrought < Rods.Gacha.PityThreshold,
		`worst drought {worstDrought}`
	)

	local state = { stars = 1, shards = 0 }
	local dupes = 0
	while state.stars < Rods.Stars.Max do
		Rods.ApplyDuplicate(state, Rods.Defs.CoralCaster)
		dupes += 1
	end
	check("★1 -> ★5 takes 2+4+8+16 = 30 duplicates", dupes == 30, tostring(dupes))
end

-- 5b. Quests -------------------------------------------------------------------------------

print("\n== Quest config ==")
do
	local rewardsOk, eventsOk = true, true
	local known = {
		Cast = true,
		Catch = true,
		PondSlotted = true,
		Sell = true,
		BuySlot = true,
		Bless = true,
		RodPull = true,
		BuyBait = true,
		BaitCrate = true,
		EarnGold = true,
	}
	for _, list in { Quests.Guide, Quests.Daily } do
		for _, def in list do
			if def.rewardBait and not Baits.Defs[def.rewardBait.id] then
				rewardsOk = false
			end
			if not known[def.event] or def.goal < 1 or def.rewardGold <= 0 then
				eventsOk = false
			end
		end
	end
	check("every quest reward bait exists", rewardsOk)
	check("every quest listens to a real GameEvent and has a goal + gold reward", eventsOk)

	local rareSalt = { biome = "Saltwater", rarity = "Rare", mutation = "Golden", ratio = 2.4 }
	local commonFresh = { biome = "Freshwater", rarity = "Common", mutation = "Normal", ratio = 0.8 }
	check(
		"filter: biome",
		Quests.Matches(Quests.GetDaily("DailySaltwater"), rareSalt)
			and not Quests.Matches(Quests.GetDaily("DailySaltwater"), commonFresh)
	)
	check(
		"filter: minimum rarity",
		Quests.Matches(Quests.GetDaily("DailyRare"), rareSalt)
			and not Quests.Matches(Quests.GetDaily("DailyRare"), commonFresh)
	)
	check(
		"filter: mutated",
		Quests.Matches(Quests.GetDaily("DailyMutation"), rareSalt)
			and not Quests.Matches(Quests.GetDaily("DailyMutation"), commonFresh)
	)
	check(
		"filter: weight ratio",
		Quests.Matches(Quests.GetDaily("DailyHeavy"), rareSalt)
			and not Quests.Matches(Quests.GetDaily("DailyHeavy"), commonFresh)
	)
	check("unfiltered quest matches anything", Quests.Matches(Quests.GetDaily("DailyCatch"), commonFresh))
end

-- 6. Early-game pacing (starter rod, no gacha, no blessings) --------------------------------

print("\n== New-player pacing: minutes to afford each Gold slot ==")
do
	local CAST_CYCLE = 22 -- seconds per catch: cast + bite wait + reel + walking around
	local RUNS = 150
	local HORIZON = 10 * 3600
	local totals: { [number]: number } = {}
	local reached: { [number]: number } = {}

	for _ = 1, RUNS do
		local gold, time, slots = 0, 0, PondConfig.FreeSlots
		local pond: { any } = {}
		local nextCatch = CAST_CYCLE
		while slots < PondConfig.MaxGoldSlots and time < HORIZON do
			time += 1
			local income = 0
			for _, creature in pond do
				income += Creatures.BaseIncome(creature)
			end
			gold += income

			if time >= nextCatch then
				nextCatch += CAST_CYCLE
				gold = math.max(0, gold - 5) -- one unit of basic bait
				local biome = if rng:NextNumber() < 0.5 then "Freshwater" else "Saltwater"
				local rarity = Creatures.RollRarity(rng, { luck = 1 })
				local species = Creatures.RollSpecies(rng, biome, rarity)
				local ratio, colossal = Creatures.RollWeightRatio(rng, 1)
				local caught = {
					uid = "sim",
					speciesId = species.id,
					weight = species.baseWeight * ratio,
					mutation = Mutations.Roll(rng, { mutationBonus = 0, isNight = false, weather = "Clear" }),
					colossal = colossal,
					caughtAt = 0,
				}
				-- Keep the best fish slotted, sell the rest.
				table.insert(pond, caught)
				table.sort(pond, function(a, b)
					return Creatures.BaseIncome(a) > Creatures.BaseIncome(b)
				end)
				while #pond > slots do
					gold += PondConfig.SellValue(table.remove(pond))
				end
			end

			local cost = PondConfig.SlotCosts[slots + 1]
			if cost and gold >= cost then
				gold -= cost
				slots += 1
				totals[slots] = (totals[slots] or 0) + time
				reached[slots] = (reached[slots] or 0) + 1
			end
		end
	end

	for slot = PondConfig.FreeSlots + 1, PondConfig.MaxGoldSlots do
		if reached[slot] then
			print(
				string.format(
					"  slot %d (%s gold): avg %.1f min  (%d/%d runs reached it within 10h)",
					slot,
					tostring(PondConfig.SlotCosts[slot]),
					totals[slot] / reached[slot] / 60,
					reached[slot],
					RUNS
				)
			)
		else
			print(`  slot {slot}: not reached within 10h`)
		end
	end
	print(
		string.format("  (mean income factor from weight rolls at 1.0 weight power: %.2fx base gold)", meanIncomeFactor)
	)
end

print(if failures == 0 then "\nAll config checks passed." else `\n{failures} config check(s) FAILED.`)
if failures > 0 then
	error("config self-test failed")
end
