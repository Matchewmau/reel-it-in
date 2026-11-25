--!strict
-- "Server Best Catches": each player's heaviest catch this server session,
-- ranked. Kept in memory only (it is a per-server brag board, not saved data)
-- and replicated to everyone whenever it changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Net = require(Shared.Net)

local GameEvents = require(script.Parent.Parent.Util.GameEvents)

type BestCatch = Types.BestCatch

local MAX_ENTRIES = 5

local BestCatchService = {}

-- userId -> that player's best. Entries stay after a player leaves: it is the
-- server's record board.
local best: { [number]: BestCatch } = {}

local function ranked(): { BestCatch }
	local list: { BestCatch } = {}
	for _, entry in best do
		table.insert(list, entry)
	end
	table.sort(list, function(a: BestCatch, b: BestCatch): boolean
		if a.weight == b.weight then
			return a.userId < b.userId
		end
		return a.weight > b.weight
	end)
	while #list > MAX_ENTRIES do
		table.remove(list)
	end
	return list
end

local function onEvent(player: Player, name: string, _amount: number, context: { [string]: any })
	if name ~= "Catch" then
		return
	end
	local weight = context.weight
	local speciesId = context.speciesId
	if type(weight) ~= "number" or type(speciesId) ~= "string" then
		return
	end
	local current = best[player.UserId]
	if current and current.weight >= weight then
		return
	end
	best[player.UserId] = {
		userId = player.UserId,
		name = player.DisplayName,
		speciesId = speciesId,
		weight = weight,
		mutation = context.mutation,
	}
	Net.Event("BestCatches"):FireAllClients(ranked())
end

function BestCatchService.Init()
	GameEvents.On(onEvent)
	Net.Handle("GetBestCatches", function(_player: Player): { [string]: any }
		return { ok = true, catches = ranked() }
	end)
end

-- Late joiners fetch the board themselves (GetBestCatches).
function BestCatchService.Start() end

return BestCatchService
