--!strict
-- Server-side gameplay event bus.
--
-- Gameplay services announce what happened ("Catch", "Sell", "RodPull"...);
-- systems that react to play (quests, leaderboards, later analytics) listen.
-- This keeps FishingService and friends from depending on every system that
-- cares about them, and avoids require cycles.
--
-- Events fired today (amount, context):
--   Cast         1      { biome }
--   Catch        1      { uid, speciesId, rarity, biome, mutation, ratio, weight, colossal }
--   PondSlotted  count  {}            amount = creatures now slotted (absolute)
--   Sell         1      { gold }
--   BuySlot      1      { slot }
--   Bless        1      {}
--   RodPull      pulls  {}
--   BuyBait      1      { baitId }
--   BaitCrate    crates {}

export type Context = { [string]: any }
export type Listener = (player: Player, name: string, amount: number, context: Context) -> ()

local GameEvents = {}

local listeners: { Listener } = {}

function GameEvents.On(listener: Listener)
	table.insert(listeners, listener)
end

function GameEvents.Fire(player: Player, name: string, amount: number, context: Context?)
	local payload: Context = context or {}
	for _, listener in listeners do
		local ok, err = pcall(function()
			listener(player, name, amount, payload)
		end)
		if not ok then
			warn(`[GameEvents] listener failed on "{name}": {err}`)
		end
	end
end

return GameEvents
