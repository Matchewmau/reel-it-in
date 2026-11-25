--!strict
-- The cast -> bite -> reel -> catch loop.
--
-- Authority model:
--   * Every roll (rarity, species, weight, mutation) happens here, at cast time,
--     on the server's RNG. The client is never asked what it caught.
--   * The reeling minigame runs on the client for responsiveness. The server
--     owns the session and validates the reported result: the cast must exist,
--     be in the Biting state, be reported once, and a "success" can't arrive
--     faster than a perfect player could physically fill the bar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Rarities = require(Shared.Config.Rarities)
local Creatures = require(Shared.Config.Creatures)
local Mutations = require(Shared.Config.Mutations)
local Rods = require(Shared.Config.Rods)
local Baits = require(Shared.Config.Baits)
local PondConfig = require(Shared.Config.PondConfig)

local DataService = require(script.Parent.DataService)
local PondService = require(script.Parent.PondService)
local WeatherService = require(script.Parent.WeatherService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local GameEvents = require(script.Parent.Parent.Util.GameEvents)

type Profile = Types.Profile
type Biome = Types.Biome
type MutationId = Types.MutationId
type CreatureInstance = Types.CreatureInstance

type Session = {
	id: number,
	state: "Waiting" | "Biting",
	creature: CreatureInstance,
	reel: Rarities.ReelDifficulty,
	biteAt: number, -- os.clock() when the bite fired
	expiresAt: number,
}

local BITE_DELAY_MIN = 2.0
local BITE_DELAY_MAX = 5.0
local MAX_REEL_TIME = 75 -- seconds a bite stays valid
local MIN_TIME_TOLERANCE = 0.85 -- latency allowance on the minimum reel time
local ZONE_PADDING = 6 -- studs of slack around fishing zone volumes

local FishingService = {}

local rng = Random.new()
local sessions: { [Player]: Session } = {}
local nextSessionId = 0

-- Replicated to every client for rod / line / bobber visuals (FishingVisualController).
local function setFishingState(player: Player, state: "Idle" | "Waiting" | "Biting")
	player:SetAttribute("FishingState", state)
end

local function fail(message: string): { [string]: any }
	return { ok = false, error = message }
end

-- Zones -----------------------------------------------------------------------------

-- Returns (biome, zonesExist). Fishing zones are parts under
-- Workspace.Map.FishingZones carrying a "Biome" attribute.
local function getBiomeAt(position: Vector3): (Biome?, boolean)
	local map = Workspace:FindFirstChild("Map")
	local zones = map and map:FindFirstChild("FishingZones")
	if not zones then
		return nil, false
	end
	local pad = Vector3.new(ZONE_PADDING, ZONE_PADDING, ZONE_PADDING)
	for _, zone in zones:GetChildren() do
		if zone:IsA("BasePart") then
			local localPos = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size / 2 + pad
			local inside = math.abs(localPos.X) <= half.X
				and math.abs(localPos.Y) <= half.Y
				and math.abs(localPos.Z) <= half.Z
			if inside then
				local biome = zone:GetAttribute("Biome")
				if biome == "Freshwater" then
					return "Freshwater", true
				elseif biome == "Saltwater" then
					return "Saltwater", true
				end
			end
		end
	end
	return nil, true
end

-- Bait ------------------------------------------------------------------------------

-- The equipped bait if it works in this water, otherwise the cheapest owned
-- bait that does, otherwise nil (bare-hook cast at a luck penalty).
local function chooseBait(profile: Profile, biome: Biome): string?
	local equipped = profile.equippedBait
	if (profile.baits[equipped] or 0) > 0 and Baits.IsCompatible(equipped, biome) then
		return equipped
	end
	for _, baitId in Baits.DisplayOrder do
		if (profile.baits[baitId] or 0) > 0 and Baits.IsCompatible(baitId, biome) then
			return baitId
		end
	end
	return nil
end

-- Rod and bait mutation affinities multiply together; unlocks are OR-ed.
local function mergeAffinity(a: { [MutationId]: number }?, b: { [MutationId]: number }?): { [MutationId]: number }
	local merged: { [MutationId]: number } = {}
	if a then
		for id: MutationId, value in a do
			merged[id] = value
		end
	end
	if b then
		for id: MutationId, value in b do
			merged[id] = (merged[id] or 1) * value
		end
	end
	return merged
end

local function mergeUnlocks(a: { [MutationId]: boolean }?, b: { [MutationId]: boolean }?): { [MutationId]: boolean }
	local merged: { [MutationId]: boolean } = {}
	if a then
		for id: MutationId, value in a do
			merged[id] = value
		end
	end
	if b then
		for id: MutationId, value in b do
			merged[id] = merged[id] or value
		end
	end
	return merged
end

-- Requests --------------------------------------------------------------------------

local function handleCast(player: Player): { [string]: any }
	if not RateLimiter.Check(player, "Cast", 0.75) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail("Still loading your data...")
	end

	local now = os.clock()
	local existing = sessions[player]
	if existing and now < existing.expiresAt then
		return fail("Your line is already in the water.")
	end
	sessions[player] = nil

	if PondService.GetBackpackCount(player) >= PondConfig.BackpackCap then
		return fail("Backpack full! Sell a fish or place one in your pond.")
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return fail("You can't fish right now.")
	end

	-- Locals holding string-literal unions are annotated explicitly: the analyzer
	-- widens un-annotated call results to plain `string`.
	local zoneBiome: Biome?, zonesExist: boolean = getBiomeAt(root.Position)
	local biome: Biome = "Freshwater"
	if zoneBiome then
		biome = zoneBiome
	elseif zonesExist then
		return fail("Head to the river or the Abyss to cast.")
	else
		-- No map built yet: let the equipped bait pick the pool so the loop is testable.
		local equipped = Baits.Get(profile.equippedBait)
		local equippedBiome: Biome? = if equipped then equipped.biome else nil
		if equippedBiome then
			biome = equippedBiome
		end
	end

	-- Loadout
	local rodId = profile.equippedRod
	local rodState = profile.rods[rodId]
	local rodDef = Rods.Get(rodId)
	if not rodState or not rodDef then
		rodId = Rods.Starter
		rodState = profile.rods[rodId]
		rodDef = Rods.Get(rodId)
	end
	assert(rodState and rodDef, "player has no usable rod")
	local rodStats = Rods.GetStats(rodId, rodState.stars)

	local baitId = chooseBait(profile, biome)
	local baitDef = if baitId then Baits.Get(baitId) else nil
	if baitId and baitDef then
		profile.baits[baitId] -= 1
		if profile.baits[baitId] <= 0 then
			profile.baits[baitId] = nil
		end
	end

	-- Modifiers
	local bonuses = PondService.GetFishingBonuses(player)
	local luck = rodStats.luck * (1 + bonuses.luckBonus) * (if baitDef then baitDef.luck else Baits.NoBaitLuck)
	local weightPower = rodStats.weight * (1 + bonuses.weightBonus)

	-- Rolls (all server-side)
	local rarity: Types.Rarity = Creatures.RollRarity(rng, {
		luck = luck,
		rarityMultipliers = if baitDef then baitDef.rarityMultipliers else nil,
		rarePlusBonus = bonuses.rarePlusBonus + WeatherService.GetRarePlusBonus(),
	})
	local species = Creatures.RollSpecies(rng, biome, rarity)
	local ratio, colossal = Creatures.RollWeightRatio(rng, weightPower, if baitDef then baitDef.minWeightRatio else nil)
	local mutation: MutationId = Mutations.Roll(rng, {
		mutationBonus = rodStats.mutationBonus,
		isNight = WeatherService.IsNight(),
		weather = WeatherService.GetWeather(),
		affinity = mergeAffinity(rodDef.mutationAffinity, if baitDef then baitDef.mutationAffinity else nil),
		unlocked = mergeUnlocks(rodDef.unlocksMutations, if baitDef then baitDef.unlocksMutations else nil),
	})

	local uid = "c" .. profile.nextUid
	profile.nextUid += 1
	local creature: CreatureInstance = {
		uid = uid,
		speciesId = species.id,
		weight = species.baseWeight * ratio,
		mutation = mutation,
		colossal = colossal,
		caughtAt = os.time(),
	}

	-- Reel difficulty comes from the species' real rarity (after any pool fallback).
	local base = Rarities.Info[species.rarity].reel
	local reel = table.clone(base)
	reel.zoneSize = math.min(Rarities.MaxZoneSize, base.zoneSize * (1 + rodStats.barSizeBonus))

	nextSessionId += 1
	local sessionId = nextSessionId
	local biteDelay = rng:NextNumber(BITE_DELAY_MIN, BITE_DELAY_MAX) * rodStats.hookSpeed
	local session: Session = {
		id = sessionId,
		state = "Waiting",
		creature = creature,
		reel = reel,
		biteAt = 0,
		expiresAt = now + biteDelay + MAX_REEL_TIME,
	}
	sessions[player] = session
	setFishingState(player, "Waiting")
	DataService.MarkDirty(player)
	GameEvents.Fire(player, "Cast", 1, { biome = biome })

	task.delay(biteDelay, function()
		if sessions[player] ~= session then
			return
		end
		session.state = "Biting"
		session.biteAt = os.clock()
		setFishingState(player, "Biting")
		-- If the client never reports back, release the line when the bite expires.
		task.delay(MAX_REEL_TIME, function()
			if sessions[player] == session then
				sessions[player] = nil
				setFishingState(player, "Idle")
			end
		end)
		Net.Event("Bite"):FireClient(player, {
			castId = sessionId,
			speciesId = species.id,
			rarity = species.rarity,
			reel = reel,
		})
	end)

	return {
		ok = true,
		castId = sessionId,
		biome = biome,
		baitId = baitId,
		biteDelay = biteDelay,
	}
end

local function handleCancelCast(player: Player): { [string]: any }
	if not RateLimiter.Check(player, "CancelCast", 0.2) then
		return fail("Slow down!")
	end
	local session = sessions[player]
	if not session or session.state ~= "Waiting" then
		return fail("Nothing to cancel.")
	end
	sessions[player] = nil
	setFishingState(player, "Idle")
	return { ok = true }
end

local function handleReelFinish(player: Player, castId: any, success: any): { [string]: any }
	if not RateLimiter.Check(player, "ReelFinish", 0.25) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	local session = sessions[player]
	if not profile or not session then
		return fail("No fish on the line.")
	end
	if type(castId) ~= "number" or castId ~= session.id or session.state ~= "Biting" then
		return fail("No fish on the line.")
	end

	-- One report per cast, whatever the outcome.
	sessions[player] = nil
	setFishingState(player, "Idle")

	local now = os.clock()
	if success ~= true or now > session.expiresAt then
		return { ok = true, caught = false }
	end

	local elapsed = now - session.biteAt
	if elapsed < Rarities.MinReelTime(session.reel) * MIN_TIME_TOLERANCE then
		warn(`[FishingService] {player.Name} reported an impossible reel time ({string.format("%.2f", elapsed)}s)`)
		return { ok = true, caught = false }
	end

	local creature = session.creature
	local species = Creatures.Get(creature.speciesId)
	assert(species, "session creature has an unknown species")

	local isNew = profile.discovered[species.id] ~= true
	profile.creatures[creature.uid] = creature
	profile.discovered[species.id] = true
	profile.stats.catches += 1
	profile.stats.heaviestKg = math.max(profile.stats.heaviestKg, creature.weight)
	GameEvents.Fire(player, "Catch", 1, {
		uid = creature.uid,
		speciesId = species.id,
		rarity = species.rarity,
		biome = species.biome,
		mutation = creature.mutation,
		ratio = creature.weight / species.baseWeight,
		weight = creature.weight,
		colossal = creature.colossal,
	})
	DataService.MarkDirty(player)

	local info = Rarities.Info[species.rarity]
	if info.announce or creature.colossal then
		local mutationName = if creature.mutation ~= "Normal" then Mutations.Get(creature.mutation).name .. " " else ""
		local sizeTag = if creature.colossal then "COLOSSAL " else ""
		Net.Event("Announce"):FireAllClients(
			`{player.DisplayName} reeled in a {sizeTag}{mutationName}{species.name} ({Format.Weight(creature.weight)})!`,
			species.rarity
		)
	end

	return {
		ok = true,
		caught = true,
		creature = creature,
		goldPerSec = Creatures.BaseIncome(creature),
		isNew = isNew,
	}
end

local function handleEquip(player: Player, kind: any, id: any): { [string]: any }
	if not RateLimiter.Check(player, "Equip", 0.15) then
		return fail("Slow down!")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail("Still loading your data...")
	end
	if type(kind) ~= "string" or type(id) ~= "string" then
		return fail("Invalid request.")
	end

	if kind == "Rod" then
		if not profile.rods[id] or not Rods.Get(id) then
			return fail("You don't own that rod.")
		end
		profile.equippedRod = id
		player:SetAttribute("RodId", id)
	elseif kind == "Bait" then
		if not Baits.Get(id) then
			return fail("Unknown bait.")
		end
		profile.equippedBait = id
	else
		return fail("Invalid request.")
	end

	DataService.MarkDirty(player)
	return { ok = true }
end

-- True while the player has a line in the water or a fish on it.
function FishingService.IsFishing(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and os.clock() < session.expiresAt
end

function FishingService.Init()
	DataService.OnProfileLoaded(function(player: Player, profile: Profile)
		player:SetAttribute("RodId", profile.equippedRod)
		setFishingState(player, "Idle")
	end)
	Net.Handle("Cast", handleCast)
	Net.Handle("CancelCast", handleCancelCast)
	Net.Handle("ReelFinish", handleReelFinish)
	Net.Handle("Equip", handleEquip)
end

function FishingService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		sessions[player] = nil
	end)
end

return FishingService
