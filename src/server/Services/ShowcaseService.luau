--!strict
-- "Show off" a creature by carrying it in your hands.
--
-- The server only decides WHICH creature a player is holding and replicates it
-- through Player attributes; every client draws the model (HoldVisualController),
-- sized from its real weight, so neighbours see exactly what you caught.
--
--   HeldUid / HeldSpecies / HeldWeight / HeldMutation   set together, or all nil
--   HeldSeq                                             increments on every change
--   HeldFromCatch                                       true when it came straight off the line
--
-- A fresh catch goes into your hands automatically and stows away after the
-- celebration pose so your rod re-equips. Manual "Show Off" stays held until
-- you cast again, place or sell that creature, or choose "Put Away".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)

local DataService = require(script.Parent.DataService)
local FishingService = require(script.Parent.FishingService)
local GameEvents = require(script.Parent.Parent.Util.GameEvents)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ShowcaseService = {}

local CATCH_SHOWCASE_DURATION = 2.2 -- 0.75s leap + ~1.45s celebration pose before auto-stow

local sequence: { [Player]: number } = {}

local function fail(message: string): { [string]: any }
	return { ok = false, error = message }
end

local function isSlotted(profile: { pond: { [string]: string } }, uid: string): boolean
	for _, slottedUid in profile.pond do
		if slottedUid == uid then
			return true
		end
	end
	return false
end

local function bump(player: Player)
	local nextValue = (sequence[player] or 0) + 1
	sequence[player] = nextValue
	player:SetAttribute("HeldSeq", nextValue)
end

function ShowcaseService.Clear(player: Player)
	if player:GetAttribute("HeldUid") == nil then
		return
	end
	player:SetAttribute("HeldUid", nil)
	player:SetAttribute("HeldSpecies", nil)
	player:SetAttribute("HeldWeight", nil)
	player:SetAttribute("HeldMutation", nil)
	player:SetAttribute("HeldFromCatch", nil)
	bump(player)
end

-- Puts one of the player's unslotted creatures in their hands. Returns success.
function ShowcaseService.Hold(player: Player, uid: string, fromCatch: boolean): boolean
	local profile = DataService.Get(player)
	local creature = if profile then profile.creatures[uid] else nil
	if not profile or not creature or isSlotted(profile, uid) then
		return false
	end
	player:SetAttribute("HeldUid", uid)
	player:SetAttribute("HeldSpecies", creature.speciesId)
	player:SetAttribute("HeldWeight", creature.weight)
	player:SetAttribute("HeldMutation", creature.mutation)
	player:SetAttribute("HeldFromCatch", fromCatch)
	bump(player)
	if fromCatch then
		local holdSeq = sequence[player]
		task.delay(CATCH_SHOWCASE_DURATION, function()
			if
				player.Parent ~= nil
				and sequence[player] == holdSeq
				and player:GetAttribute("HeldFromCatch") == true
			then
				ShowcaseService.Clear(player)
			end
		end)
	end
	return true
end

-- Drops the creature if it is no longer in the backpack (sold or slotted).
local function validate(player: Player)
	local uid = player:GetAttribute("HeldUid")
	if type(uid) ~= "string" then
		return
	end
	local profile = DataService.Get(player)
	if not profile or not profile.creatures[uid] or isSlotted(profile, uid) then
		ShowcaseService.Clear(player)
	end
end

local function handleHold(player: Player, uid: any): { [string]: any }
	if not RateLimiter.Check(player, "Hold", 0.3) then
		return fail("Slow down!")
	end
	if not DataService.Get(player) then
		return fail("Still loading your data...")
	end
	-- Anything that is not a creature id means "put it away".
	if type(uid) ~= "string" or uid == "" then
		ShowcaseService.Clear(player)
		return { ok = true, holding = false }
	end
	if FishingService.IsFishing(player) then
		return fail("Reel in your line first.")
	end
	if not ShowcaseService.Hold(player, uid, false) then
		return fail("Take it out of your pond first.")
	end
	return { ok = true, holding = true }
end

function ShowcaseService.Init()
	Net.Handle("Hold", handleHold)

	GameEvents.On(function(player: Player, name: string, _amount: number, context: { [string]: any })
		if name == "Catch" and type(context.uid) == "string" then
			-- Straight off the line and into your hands.
			ShowcaseService.Hold(player, context.uid, true)
		elseif name == "Cast" then
			ShowcaseService.Clear(player)
		elseif name == "Sell" or name == "PondSlotted" then
			validate(player)
		end
	end)
end

function ShowcaseService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		sequence[player] = nil
	end)
end

return ShowcaseService
