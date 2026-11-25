--!strict
-- Per-player, per-action minimum interval. Every client -> server request goes
-- through one of these before any other work is done.

local Players = game:GetService("Players")

local RateLimiter = {}

local lastCall: { [Player]: { [string]: number } } = {}

-- Returns true if the action is allowed now (and records it).
function RateLimiter.Check(player: Player, action: string, minInterval: number): boolean
	local now = os.clock()
	local perPlayer = lastCall[player]
	if not perPlayer then
		perPlayer = {}
		lastCall[player] = perPlayer
	end
	local last = perPlayer[action]
	if last and now - last < minInterval then
		return false
	end
	perPlayer[action] = now
	return true
end

Players.PlayerRemoving:Connect(function(player: Player)
	lastCall[player] = nil
end)

return RateLimiter
