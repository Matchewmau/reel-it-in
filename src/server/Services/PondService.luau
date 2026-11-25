--!strict
-- Pond ownership, slotting, passive income, auras and social blessing.
--
-- The server owns every number here. Clients only receive PondSync snapshots
-- (for swimming visuals and inspection cards) and PondEvent VFX cues.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Creatures = require(Shared.Config.Creatures)
local Mutations = require(Shared.Config.Mutations)
local PondConfig = require(Shared.Config.PondConfig)

local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local GameEvents = require(script.Parent.Parent.Util.GameEvents)

type Profile = Types.Profile
type CreatureInstance = Types.CreatureInstance

type State = {
	plot: number,
	passes: { [string]: boolean },
	passSlots: number,
	goldAura: boolean,
	income: PondConfig.IncomeBreakdown,
	fishing: PondConfig.FishingModifiers,
	auraCounts: { [string]: number },
	starfallUntil: number, -- os.clock() deadline, 0 = inactive
	nextStarfall: number, -- 0 = no Leviathan timer running
	nextSurge: number,
	luckBuffUntil: number,
}

local PondService = {}

local rng = Random.new()
local states: { [Player]: State } = {}
local plotOwners: { [number]: Player } = {}

local function fail(message: string): { [string]: any }
	return { ok = false, error = message }
end

-- Pond resolution -----------------------------------------------------------------

function PondService.GetMaxSlots(player: Player): number
	local profile = DataService.Get(player)
	local state = states[player]
	if not profile or not state then
		return PondConfig.FreeSlots
	end
	return profile.slotsUnlocked + state.passSlots
end

-- slot number -> creature, for the slots the player can currently use.
local function resolvePond(profile: Profile, maxSlots: number): { [number]: CreatureInstance }
	local pond: { [number]: CreatureInstance } = {}
	for slotKey, uid in profile.pond do
		local slot = tonumber(slotKey)
		local creature = profile.creatures[uid]
		if slot and creature and slot >= 1 and slot <= maxSlots then
			pond[slot] = creature
		end
	end
	return pond
end

local function countBackpack(profile: Profile): number
	local total = 0
	for _ in profile.creatures do
		total += 1
	end
	local slotted = 0
	for _ in profile.pond do
		slotted += 1
	end
	return total - slotted
end

-- Plot number (1..PlotCount) the player owns, or 0 if they have none.
function PondService.GetPlot(player: Player): number
	local state = states[player]
	return if state then state.plot else 0
end

-- Current pond gold/sec (used to scale quest rewards).
function PondService.GetIncome(player: Player): number
	local state = states[player]
	return if state then state.income.total else 0
end

function PondService.GetPlotOwner(plot: number): Player?
	return plotOwners[plot]
end

function PondService.GetBackpackCount(player: Player): number
	local profile = DataService.Get(player)
	return if profile then countBackpack(profile) else 0
end

local function findSlotOf(profile: Profile, uid: string): string?
	for slotKey, slottedUid in profile.pond do
		if slottedUid == uid then
			return slotKey
		end
	end
	return nil
end

-- Replication ---------------------------------------------------------------------

local function buildPondSnapshot(player: Player): Types.PondSnapshot?
	local profile = DataService.Get(player)
	local state = states[player]
	if not profile or not state then
		return nil
	end
	local maxSlots = PondService.GetMaxSlots(player)
	local fish: { Types.PondFish } = {}
	for slot, creature in resolvePond(profile, maxSlots) do
		table.insert(fish, {
			slot = slot,
			uid = creature.uid,
			speciesId = creature.speciesId,
			weight = creature.weight,
			mutation = creature.mutation,
			colossal = creature.colossal,
			goldPerSec = state.income.perSlot[slot] or 0,
		})
	end
	return {
		plot = state.plot,
		ownerUserId = player.UserId,
		ownerName = player.DisplayName,
		maxSlots = maxSlots,
		total = state.income.total,
		starfallRemaining = math.max(0, state.starfallUntil - os.clock()),
		goldAura = state.goldAura,
		fish = fish,
	}
end

local function getPlotModel(plot: number): Instance?
	local map = Workspace:FindFirstChild("Map")
	local ponds = map and map:FindFirstChild("Ponds")
	return ponds and ponds:FindFirstChild("Pond" .. plot)
end

-- Recomputes income + aura state after any pond change and replicates it.
function PondService.Recompute(player: Player)
	local profile = DataService.Get(player)
	local state = states[player]
	if not profile or not state then
		return
	end
	local now = os.clock()
	local pond = resolvePond(profile, PondService.GetMaxSlots(player))

	state.auraCounts = PondConfig.GetActiveAuras(pond)
	state.fishing = PondConfig.GetFishingModifiers(pond)
	state.income = PondConfig.ComputeIncome(pond, { starfall = state.starfallUntil > now })

	-- Aura timers start when the aura first appears. They are not reset by
	-- re-slotting, so swapping a fish in and out can't fast-forward them.
	if state.auraCounts.CosmicTide and state.nextStarfall == 0 then
		state.nextStarfall = now + (PondConfig.Auras.CosmicTide.starfallInterval :: number)
	end
	if state.auraCounts.StaticSurge and state.nextSurge == 0 then
		state.nextSurge = now + (PondConfig.Auras.StaticSurge.surgeInterval :: number)
	end

	player:SetAttribute("GoldPerSec", state.income.total)
	DataService.MarkDirty(player)

	local snapshot = buildPondSnapshot(player)
	if snapshot then
		Net.Event("PondSync"):FireAllClients(snapshot)
	end
end

-- Fishing hooks (used by FishingService) --------------------------------------------

export type FishingBonuses = {
	luckBonus: number,
	weightBonus: number,
	rarePlusBonus: number,
}

function PondService.GetFishingBonuses(player: Player): FishingBonuses
	local state = states[player]
	if not state then
		return { luckBonus = 0, weightBonus = 0, rarePlusBonus = 0 }
	end
	local blessed = state.luckBuffUntil > os.clock()
	return {
		luckBonus = state.fishing.luckBonus + (if blessed then PondConfig.Blessing.LuckBonus else 0),
		weightBonus = state.fishing.weightBonus,
		rarePlusBonus = state.fishing.rarePlusBonus,
	}
end

-- Aura ticks ----------------------------------------------------------------------

local function tickAuras(player: Player, state: State, profile: Profile, now: number)
	-- Cosmic Tide: Starfall doubles income for a short window.
	if state.starfallUntil > 0 and now >= state.starfallUntil then
		state.starfallUntil = 0
		PondService.Recompute(player)
	end
	if state.auraCounts.CosmicTide and state.nextStarfall > 0 and now >= state.nextStarfall then
		local aura = PondConfig.Auras.CosmicTide
		local duration = aura.starfallDuration :: number
		state.starfallUntil = now + duration
		state.nextStarfall = now + (aura.starfallInterval :: number)
		Net.Event("PondEvent"):FireAllClients(state.plot, "Starfall", { duration = duration })
		Net.Event("Notify"):FireClient(player, "Starfall! Your pond income is doubled for 30 seconds.", "good")
		PondService.Recompute(player)
	end

	-- Static Surge: shock a random fish, small chance to make it Storm-Charged.
	if state.auraCounts.StaticSurge and state.nextSurge > 0 and now >= state.nextSurge then
		local aura = PondConfig.Auras.StaticSurge
		state.nextSurge = now + (aura.surgeInterval :: number)

		local slots: { number } = {}
		local pond = resolvePond(profile, PondService.GetMaxSlots(player))
		for slot in pond do
			table.insert(slots, slot)
		end
		if #slots > 0 then
			table.sort(slots)
			local slot = slots[rng:NextInteger(1, #slots)]
			local target = pond[slot]
			local stormMultiplier = Mutations.GetMultiplier("StormCharged")
			-- Never downgrade a better mutation (e.g. Void-Touched).
			local applied = Mutations.GetMultiplier(target.mutation) < stormMultiplier
				and rng:NextNumber() < (aura.surgeChance :: number)
			if applied then
				target.mutation = "StormCharged"
				local species = Creatures.Get(target.speciesId)
				local name = if species then species.name else "fish"
				Net.Event("Notify"):FireClient(player, `Static Surge! Your {name} is now Storm-Charged!`, "good")
				PondService.Recompute(player)
			end
			Net.Event("PondEvent"):FireAllClients(state.plot, "StaticSurge", { slot = slot, applied = applied })
		end
	end
end

-- Request handlers ----------------------------------------------------------------

local function handlePlace(player: Player, uid: any, slot: any): { [string]: any }
	if not RateLimiter.Check(player, "PondEdit", 0.15) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile or not states[player] then
		return fail("Still loading your data...")
	end
	if type(uid) ~= "string" or type(slot) ~= "number" or slot ~= math.floor(slot) then
		return fail("Invalid request.")
	end
	if not profile.creatures[uid] then
		return fail("You don't own that creature.")
	end
	if slot < 1 or slot > PondService.GetMaxSlots(player) then
		return fail("That slot is locked.")
	end

	-- Moving a creature that is already slotted swaps the two slots; placing from
	-- the backpack returns the previous occupant to the backpack (count unchanged).
	local slotKey = tostring(slot)
	local fromKey = findSlotOf(profile, uid)
	local previous = profile.pond[slotKey]
	if fromKey == slotKey then
		return { ok = true }
	end
	profile.pond[slotKey] = uid
	if fromKey then
		profile.pond[fromKey] = previous
	end

	PondService.Recompute(player)
	local slotted = 0
	for _ in profile.pond do
		slotted += 1
	end
	GameEvents.Fire(player, "PondSlotted", slotted)
	return { ok = true }
end

local function handleRemove(player: Player, slot: any): { [string]: any }
	if not RateLimiter.Check(player, "PondEdit", 0.15) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile or not states[player] then
		return fail("Still loading your data...")
	end
	if type(slot) ~= "number" or slot ~= math.floor(slot) then
		return fail("Invalid request.")
	end
	local slotKey = tostring(slot)
	if not profile.pond[slotKey] then
		return fail("That slot is empty.")
	end
	if countBackpack(profile) >= PondConfig.BackpackCap then
		return fail("Your backpack is full. Sell a fish first.")
	end

	profile.pond[slotKey] = nil
	PondService.Recompute(player)
	return { ok = true }
end

local function handleBuySlot(player: Player): { [string]: any }
	if not RateLimiter.Check(player, "BuySlot", 0.5) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile or not states[player] then
		return fail("Still loading your data...")
	end
	local nextSlot = profile.slotsUnlocked + 1
	local cost = PondConfig.GetSlotCost(nextSlot)
	if nextSlot > PondConfig.MaxGoldSlots or not cost then
		return fail("All Gold slots are unlocked.")
	end
	if not DataService.TrySpendGold(player, cost) then
		return fail(`You need {Format.Number(cost)} Gold.`)
	end

	profile.slotsUnlocked = nextSlot
	PondService.Recompute(player)
	GameEvents.Fire(player, "BuySlot", 1, { slot = nextSlot })
	return { ok = true, slotsUnlocked = nextSlot }
end

local function handleSell(player: Player, uid: any): { [string]: any }
	if not RateLimiter.Check(player, "Sell", 0.1) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail("Still loading your data...")
	end
	if type(uid) ~= "string" then
		return fail("Invalid request.")
	end
	local creature = profile.creatures[uid]
	if not creature then
		return fail("You don't own that creature.")
	end
	if findSlotOf(profile, uid) then
		return fail("Remove it from your pond before selling.")
	end

	local value = PondConfig.SellValue(creature)
	profile.creatures[uid] = nil
	DataService.AddGold(player, value)
	DataService.MarkDirty(player)
	GameEvents.Fire(player, "Sell", 1, { gold = value })
	return { ok = true, gold = value }
end

local function handleBless(player: Player, targetUserId: any): { [string]: any }
	if not RateLimiter.Check(player, "Bless", 1) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	local state = states[player]
	if not profile or not state then
		return fail("Still loading your data...")
	end
	if type(targetUserId) ~= "number" then
		return fail("Invalid request.")
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	local targetState = if target then states[target] else nil
	if not target or not targetState then
		return fail("That pond has no owner right now.")
	end
	if target == player then
		return fail("Visit a neighbour's pond to share a blessing.")
	end

	local cfg = PondConfig.Blessing
	local remaining = cfg.Cooldown - (os.time() - profile.lastBlessAt)
	if remaining > 0 then
		return fail(`You can feed again in {Format.Duration(remaining)}.`)
	end

	-- Must actually be standing at the neighbour's pond (when the map exists).
	local plotModel = getPlotModel(targetState.plot)
	local water = plotModel and plotModel:FindFirstChild("Water")
	if water and water:IsA("BasePart") then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return fail("You need to be at the pond.")
		end
		if (root.Position - water.Position).Magnitude > cfg.MaxDistance then
			return fail("Walk up to the pond to feed it.")
		end
	end

	profile.lastBlessAt = os.time()
	local buffUntil = os.clock() + cfg.Duration
	state.luckBuffUntil = math.max(state.luckBuffUntil, buffUntil)
	targetState.luckBuffUntil = math.max(targetState.luckBuffUntil, buffUntil)

	local pct = math.floor(cfg.LuckBonus * 100 + 0.5)
	local notify = Net.Event("Notify")
	notify:FireClient(player, `You fed {target.DisplayName}'s pond: +{pct}% Luck for you both!`, "good")
	notify:FireClient(target, `{player.DisplayName} fed your pond: +{pct}% Luck for you both!`, "good")
	Net.Event("PondEvent"):FireAllClients(targetState.plot, "Blessing", { by = player.UserId })

	DataService.MarkDirty(player)
	DataService.MarkDirty(target)
	GameEvents.Fire(player, "Bless", 1)
	return { ok = true }
end

-- Lifecycle -----------------------------------------------------------------------

local function ownsPass(player: Player, passId: number): boolean
	if passId == 0 then
		return false
	end
	local ok, owns = pcall(function(): boolean
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	return ok and owns
end

local function applyPasses(state: State)
	local slots = 0
	local goldAura = false
	for _, pass in PondConfig.Gamepasses do
		if state.passes[pass.key] then
			slots += pass.slots
			goldAura = goldAura or pass.goldAura
		end
	end
	state.passSlots = slots
	state.goldAura = goldAura
end

local function refreshPasses(player: Player, state: State)
	for _, pass in PondConfig.Gamepasses do
		if ownsPass(player, pass.id) then
			state.passes[pass.key] = true
		end
	end
	applyPasses(state)
end

local function claimPlot(player: Player): number
	for plot = 1, PondConfig.PlotCount do
		if not plotOwners[plot] then
			plotOwners[plot] = player
			return plot
		end
	end
	return 0 -- server over capacity; the pond still works, it just has no physical plot
end

local function setPlotOwner(plot: number, player: Player?)
	local model = getPlotModel(plot)
	if model then
		model:SetAttribute("OwnerUserId", if player then player.UserId else 0)
		model:SetAttribute("OwnerName", if player then player.DisplayName else "")
	end
end

local function grantOfflineEarnings(player: Player, profile: Profile, state: State)
	local cfg = PondConfig.Offline
	if not cfg.Enabled or profile.lastSeen <= 0 then
		return
	end
	local away = os.time() - profile.lastSeen
	if away < cfg.MinSeconds then
		return
	end
	local earned = math.floor(state.income.total * math.min(away, cfg.MaxSeconds) * cfg.Rate)
	if earned > 0 then
		DataService.AddGold(player, earned)
		Net.Event("Notify")
			:FireClient(
				player,
				`Welcome back! Your pond earned {Format.Number(earned)} Gold while you were away.`,
				"good"
			)
	end
end

local function onProfileLoaded(player: Player, profile: Profile)
	local state: State = {
		plot = claimPlot(player),
		passes = {},
		passSlots = 0,
		goldAura = false,
		income = PondConfig.ComputeIncome({}),
		fishing = { luckBonus = 0, weightBonus = 0, rarePlusBonus = 0 },
		auraCounts = {},
		starfallUntil = 0,
		nextStarfall = 0,
		nextSurge = 0,
		luckBuffUntil = 0,
	}
	states[player] = state
	player:SetAttribute("Plot", state.plot)
	setPlotOwner(state.plot, player)

	PondService.Recompute(player)
	grantOfflineEarnings(player, profile, state)

	-- Gamepass checks are web calls; don't hold up the rest of the load.
	task.spawn(function()
		refreshPasses(player, state)
		if states[player] == state and state.passSlots > 0 then
			PondService.Recompute(player)
		end
	end)
end

local function onProfileReleasing(player: Player, _profile: Profile)
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil
	if plotOwners[state.plot] == player then
		plotOwners[state.plot] = nil
		setPlotOwner(state.plot, nil)
		local empty: Types.PondSnapshot = {
			plot = state.plot,
			ownerUserId = 0,
			ownerName = "",
			maxSlots = 0,
			total = 0,
			starfallRemaining = 0,
			goldAura = false,
			fish = {},
		}
		Net.Event("PondSync"):FireAllClients(empty)
	end
end

function PondService.Init()
	DataService.OnProfileLoaded(onProfileLoaded)
	DataService.OnProfileReleasing(onProfileReleasing)

	DataService.RegisterSnapshotExtension(function(player: Player, snapshot: { [string]: any })
		local profile = DataService.Get(player)
		local state = states[player]
		if not profile or not state then
			return
		end
		local perSlot: { [string]: number } = {}
		for slot, income in state.income.perSlot do
			perSlot[tostring(slot)] = income
		end
		local now = os.clock()
		snapshot.plot = state.plot
		snapshot.maxSlots = PondService.GetMaxSlots(player)
		snapshot.backpackCap = PondConfig.BackpackCap
		snapshot.incomeTotal = state.income.total
		snapshot.incomePerSlot = perSlot
		snapshot.luckBuffRemaining = math.max(0, state.luckBuffUntil - now)
		snapshot.blessCooldownRemaining = math.max(0, PondConfig.Blessing.Cooldown - (os.time() - profile.lastBlessAt))
		snapshot.starfallRemaining = math.max(0, state.starfallUntil - now)
	end)

	Net.Handle("PondPlace", handlePlace)
	Net.Handle("PondRemove", handleRemove)
	Net.Handle("BuySlot", handleBuySlot)
	Net.Handle("SellCreature", handleSell)
	Net.Handle("Bless", handleBless)
	Net.Handle("GetPonds", function(_player: Player): { [string]: any }
		local ponds: { Types.PondSnapshot } = {}
		for owner in states do
			local snapshot = buildPondSnapshot(owner)
			if snapshot then
				table.insert(ponds, snapshot)
			end
		end
		return { ok = true, ponds = ponds }
	end)
end

function PondService.Start()
	-- Passive income + aura timers, once a second.
	task.spawn(function()
		while true do
			local dt = task.wait(1)
			local now = os.clock()
			for player, state in states do
				local profile = DataService.Get(player)
				if profile then
					tickAuras(player, state, profile, now)
					if state.income.total > 0 then
						DataService.AddGold(player, state.income.total * dt)
					end
				end
			end
		end
	end)

	-- Grant straight from the purchase event: UserOwnsGamePassAsync is cached and
	-- can still report false right after a purchase.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local state = states[player]
			if not purchased or not state or passId == 0 then
				return
			end
			for _, pass in PondConfig.Gamepasses do
				if pass.id == passId then
					state.passes[pass.key] = true
					applyPasses(state)
					PondService.Recompute(player)
				end
			end
		end
	)
end

return PondService
