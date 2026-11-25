--!strict
-- Rod Gacha Shrine, Bait Merchant and Bait Crates.
--
-- All pulls roll on the server. Odds are published in the shared config so the
-- shop UI can disclose them, and rod pulls carry a pity counter.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Rarities = require(Shared.Config.Rarities)
local Rods = require(Shared.Config.Rods)
local Baits = require(Shared.Config.Baits)

local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local GameEvents = require(script.Parent.Parent.Util.GameEvents)

type Profile = Types.Profile

export type PullResult = {
	rodId: string,
	isNew: boolean,
	starsGained: number,
	stars: number,
	refundGold: number,
}

local MAX_BAIT_STACK = 9999

local GachaService = {}

local rng = Random.new()

local function fail(message: string): { [string]: any }
	return { ok = false, error = message }
end

-- Rods ------------------------------------------------------------------------------

local function grantRodPulls(player: Player, profile: Profile, count: number, guaranteeEpic: boolean): { PullResult }
	local results: { PullResult } = {}
	for index = 1, count do
		-- A guarantee applies to the first pull of the batch only.
		local rodId, pity = Rods.RollPull(rng, profile.pity.rod, guaranteeEpic and index == 1)
		profile.pity.rod = pity

		local def = Rods.Get(rodId)
		assert(def, "RollPull returned an unknown rod id")
		local state = profile.rods[rodId]
		local result: PullResult = { rodId = rodId, isNew = false, starsGained = 0, stars = 1, refundGold = 0 }
		if not state then
			profile.rods[rodId] = { stars = 1, shards = 0 }
			result.isNew = true
		else
			local duplicate = Rods.ApplyDuplicate(state, def)
			result.starsGained = duplicate.starsGained
			result.refundGold = duplicate.refundGold
			result.stars = state.stars
			if duplicate.refundGold > 0 then
				DataService.AddGold(player, duplicate.refundGold)
			end
		end
		table.insert(results, result)

		if result.isNew and Rarities.Info[def.rarity].announce then
			Net.Event("Announce"):FireAllClients(`{player.DisplayName} pulled the {def.name}!`, def.rarity)
		end
	end
	DataService.MarkDirty(player)
	return results
end

local function handleRodPull(player: Player, count: any): { [string]: any }
	if not RateLimiter.Check(player, "RodPull", 0.4) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail("Still loading your data...")
	end
	local gacha = Rods.Gacha
	if count ~= 1 and count ~= gacha.MultiCount then
		return fail("Invalid request.")
	end
	local cost = if count == 1 then gacha.PullCost else gacha.MultiCost
	if not DataService.TrySpendGold(player, cost) then
		return fail(`You need {Format.Number(cost)} Gold.`)
	end

	local results = grantRodPulls(player, profile, count, false)
	GameEvents.Fire(player, "RodPull", count)
	return { ok = true, results = results, pity = profile.pity.rod }
end

-- Bait ------------------------------------------------------------------------------

local function addBait(profile: Profile, baitId: string, amount: number)
	profile.baits[baitId] = math.min(MAX_BAIT_STACK, (profile.baits[baitId] or 0) + amount)
end

local function handleBuyBait(player: Player, baitId: any, bundles: any): { [string]: any }
	if not RateLimiter.Check(player, "BuyBait", 0.15) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail("Still loading your data...")
	end
	if type(baitId) ~= "string" then
		return fail("Invalid request.")
	end
	local quantity = if bundles == nil then 1 else bundles
	if type(quantity) ~= "number" or quantity ~= math.floor(quantity) or quantity < 1 or quantity > 100 then
		return fail("Invalid request.")
	end
	local def = Baits.Get(baitId)
	if not def or not def.price then
		return fail("The merchant doesn't sell that.")
	end
	local cost = def.price * quantity
	if not DataService.TrySpendGold(player, cost) then
		return fail(`You need {Format.Number(cost)} Gold.`)
	end

	addBait(profile, baitId, def.bundle * quantity)
	DataService.MarkDirty(player)
	GameEvents.Fire(player, "BuyBait", 1, { baitId = baitId })
	return { ok = true, baitId = baitId, amount = def.bundle * quantity }
end

local function handleBaitCrate(player: Player, count: any): { [string]: any }
	if not RateLimiter.Check(player, "BaitCrate", 0.3) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail("Still loading your data...")
	end
	local quantity = if count == nil then 1 else count
	if type(quantity) ~= "number" or quantity ~= math.floor(quantity) or quantity < 1 or quantity > 10 then
		return fail("Invalid request.")
	end
	local cost = Baits.Crate.Cost * quantity
	if not DataService.TrySpendGold(player, cost) then
		return fail(`You need {Format.Number(cost)} Gold.`)
	end

	local results: { { baitId: string, amount: number } } = {}
	for _ = 1, quantity do
		local entry = Baits.RollCrate(rng)
		addBait(profile, entry.baitId, entry.amount)
		table.insert(results, { baitId = entry.baitId, amount = entry.amount })
	end
	DataService.MarkDirty(player)
	GameEvents.Fire(player, "BaitCrate", quantity)
	return { ok = true, results = results }
end

-- Robux products ----------------------------------------------------------------------

local function processReceipt(receipt: { [string]: any }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local profile = if player then DataService.Get(player) else nil
	if not player or not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(receipt.PurchaseId)
	if DataService.HasPurchase(player, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	for _, product: Rods.ProductDef in Rods.Gacha.Products do
		if product.id ~= 0 and product.id == receipt.ProductId then
			DataService.RecordPurchase(player, purchaseId)
			local results = grantRodPulls(player, profile, product.pulls, product.guaranteeEpic)
			-- Only confirm once the grant is safely stored; otherwise Roblox retries later
			-- and the recorded purchase id stops a double grant.
			if not DataService.SaveNow(player) then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			local best = results[1]
			for _, result in results do
				local def = Rods.Get(result.rodId)
				local bestDef = Rods.Get(best.rodId)
				if def and bestDef and Rarities.Info[def.rarity].order > Rarities.Info[bestDef.rarity].order then
					best = result
				end
			end
			local bestDef = Rods.Get(best.rodId)
			if bestDef then
				Net.Event("Notify"):FireClient(player, `Shrine blessing received: {bestDef.name}!`, "good")
			end
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function GachaService.Init()
	Net.Handle("RodPull", handleRodPull)
	Net.Handle("BuyBait", handleBuyBait)
	Net.Handle("BaitCrate", handleBaitCrate)
end

function GachaService.Start()
	MarketplaceService.ProcessReceipt = processReceipt :: any
end

return GachaService
