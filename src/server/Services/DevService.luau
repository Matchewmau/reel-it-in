--!strict
-- Studio-only QA commands (spawn a specific creature, grant gold, force weather).
--
-- Safety: the DevCommand remote is only created, and this handler only
-- registered, when RunService:IsStudio() is true on the SERVER. That check
-- cannot be spoofed by a client, so none of this exists in a live game.
--
-- Used by playtests driven through Studio MCP, e.g. from the client datamodel:
--   Net.Invoke("DevCommand", "GrantCreature", { speciesId = "AbyssalAngler", ratio = 1.5, mutation = "VoidTouched", slot = 2 })

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Creatures = require(Shared.Config.Creatures)
local PondConfig = require(Shared.Config.PondConfig)

local DataService = require(script.Parent.DataService)
local PondService = require(script.Parent.PondService)
local WeatherService = require(script.Parent.WeatherService)

type MutationId = Types.MutationId
type WeatherId = Types.WeatherId

local DevService = {}

local function fail(message: string): { [string]: any }
	return { ok = false, error = message }
end

-- Untrusted input -> precise literal-union type (or nil). Written as explicit
-- comparisons because the analyzer will not narrow a string through a table lookup.
local function toMutation(value: any): MutationId?
	if value == "Normal" then
		return "Normal"
	elseif value == "Albino" then
		return "Albino"
	elseif value == "Golden" then
		return "Golden"
	elseif value == "Bioluminescent" then
		return "Bioluminescent"
	elseif value == "StormCharged" then
		return "StormCharged"
	elseif value == "VoidTouched" then
		return "VoidTouched"
	end
	return nil
end

local function toWeather(value: any): WeatherId?
	if value == "Clear" then
		return "Clear"
	elseif value == "Rain" then
		return "Rain"
	elseif value == "Storm" then
		return "Storm"
	end
	return nil
end

local function handle(player: Player, command: any, args: any): { [string]: any }
	local profile = DataService.Get(player)
	if not profile then
		return fail("Profile not loaded.")
	end
	if type(command) ~= "string" then
		return fail("Invalid command.")
	end
	local options: { [string]: any } = if type(args) == "table" then args else {}

	if command == "GrantCreature" then
		local species = if type(options.speciesId) == "string" then Creatures.Get(options.speciesId) else nil
		if not species then
			return fail("Unknown speciesId.")
		end
		local ratio = if type(options.ratio) == "number"
			then math.clamp(options.ratio, Creatures.Weight.MinRatio, Creatures.Weight.ColossalMaxRatio)
			else 1
		local requested: MutationId? = toMutation(options.mutation)
		local mutation: MutationId = if requested then requested else "Normal"

		local uid = "c" .. profile.nextUid
		profile.nextUid += 1
		profile.creatures[uid] = {
			uid = uid,
			speciesId = species.id,
			weight = species.baseWeight * ratio,
			mutation = mutation,
			colossal = ratio >= Creatures.Weight.ColossalMinRatio,
			caughtAt = os.time(),
		}
		profile.discovered[species.id] = true

		local slot = options.slot
		if
			type(slot) == "number"
			and slot == math.floor(slot)
			and slot >= 1
			and slot <= PondService.GetMaxSlots(player)
		then
			profile.pond[tostring(slot)] = uid
		end
		PondService.Recompute(player)
		return { ok = true, uid = uid }
	elseif command == "GrantGold" then
		local amount = options.amount
		if type(amount) ~= "number" or amount <= 0 or amount > 1e12 then
			return fail("amount must be a positive number.")
		end
		DataService.AddGold(player, amount)
		DataService.MarkDirty(player)
		return { ok = true }
	elseif command == "SetSlots" then
		local slots = options.slots
		if type(slots) ~= "number" or slots ~= math.floor(slots) then
			return fail("slots must be an integer.")
		end
		profile.slotsUnlocked = math.clamp(slots, PondConfig.FreeSlots, PondConfig.MaxGoldSlots)
		PondService.Recompute(player)
		return { ok = true, slotsUnlocked = profile.slotsUnlocked }
	elseif command == "ClearPond" then
		table.clear(profile.pond)
		PondService.Recompute(player)
		return { ok = true }
	elseif command == "SetWeather" then
		local id: WeatherId? = toWeather(options.weather)
		if not id then
			return fail("Unknown weather.")
		end
		WeatherService.Force(
			id,
			if type(options.duration) == "number" then math.clamp(options.duration, 5, 3600) else 120
		)
		return { ok = true }
	elseif command == "SetClock" then
		local hours = options.hours
		if type(hours) ~= "number" then
			return fail("hours must be a number.")
		end
		Lighting.ClockTime = hours % 24
		return { ok = true }
	end

	return fail("Unknown command.")
end

function DevService.Init()
	if RunService:IsStudio() then
		Net.Handle(Net.StudioFunction, handle)
	end
end

function DevService.Start() end

return DevService
