--!strict
-- Fast-travel destinations and tunables.
--
-- Fixed destinations are marker parts under Workspace.Map.TravelPoints named by
-- `id`. Pond destinations ("MyPond", or "Pond" + plot number) use each pond's
-- `Spawn` part. The server validates every request (see TravelService).

export type Destination = {
	id: string,
	name: string,
	description: string,
}

local Travel = {}

Travel.Cooldown = 3 -- seconds between teleports
Travel.SeaRescueY = -8 -- characters below this height have fallen into the Abyss (ground is y = 0, the river bed -2.5)
Travel.ArrivalHeight = 3 -- studs above a marker the character is placed
Travel.ArrivalSpread = 2.5 -- random horizontal offset so arrivals don't stack

Travel.Destinations = {
	{
		id = "Hub",
		name = "Player Hub",
		description = "The market: Rod Gacha Shrine, Bait Merchant and Fish Appraiser.",
	},
	{
		id = "Freshwater",
		name = "Freshwater River",
		description = "Freshwater fishing along the river below The Falls. Use Earthworms or Glowing Fireflies.",
	},
	{
		id = "Saltwater",
		name = "The Abyss",
		description = "Deep-sea (saltwater) fishing over the great hole. Use Krill Paste or Squid Ink Capsules.",
	},
} :: { Destination }

function Travel.Get(id: string): Destination?
	for _, destination in Travel.Destinations do
		if destination.id == id then
			return destination
		end
	end
	return nil
end

return Travel
