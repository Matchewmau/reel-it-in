--!strict
-- Read-only mirror of server state. Controllers subscribe here instead of
-- touching remotes directly; nothing in this module is ever sent back.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Net = require(Shared.Net)

type Snapshot = Types.Snapshot
type PondSnapshot = Types.PondSnapshot

local ClientState = {}

ClientState.Snapshot = nil :: Snapshot?
ClientState.SnapshotAt = 0 -- os.clock() when the snapshot arrived (for countdowns)
ClientState.Ponds = {} :: { [number]: PondSnapshot }

local stateListeners: { (Snapshot) -> () } = {}
local pondListeners: { (PondSnapshot) -> () } = {}

local function applySnapshot(snapshot: Snapshot)
	ClientState.Snapshot = snapshot
	ClientState.SnapshotAt = os.clock()
	for _, listener in stateListeners do
		task.spawn(listener, snapshot)
	end
end

local function applyPond(pond: PondSnapshot)
	if pond.plot <= 0 then
		return
	end
	ClientState.Ponds[pond.plot] = pond
	for _, listener in pondListeners do
		task.spawn(listener, pond)
	end
end

function ClientState.OnState(listener: (Snapshot) -> ())
	table.insert(stateListeners, listener)
	local snapshot = ClientState.Snapshot
	if snapshot then
		task.spawn(listener, snapshot)
	end
end

function ClientState.OnPond(listener: (PondSnapshot) -> ())
	table.insert(pondListeners, listener)
	for _, pond in ClientState.Ponds do
		task.spawn(listener, pond)
	end
end

-- Seconds left on a countdown that was `remaining` when the snapshot arrived.
function ClientState.Remaining(remaining: number): number
	return math.max(0, remaining - (os.clock() - ClientState.SnapshotAt))
end

function ClientState.Start()
	Net.Event("StateSync").OnClientEvent:Connect(applySnapshot)
	Net.Event("PondSync").OnClientEvent:Connect(applyPond)

	task.spawn(function()
		-- The profile may still be loading when we join; poll until it is ready.
		while not ClientState.Snapshot do
			local response = Net.Invoke("GetState")
			if response.ok and not ClientState.Snapshot then
				applySnapshot(response.state)
			end
			if not ClientState.Snapshot then
				task.wait(1)
			end
		end
	end)

	task.spawn(function()
		local response = Net.Invoke("GetPonds")
		if response.ok then
			for _, pond in response.ponds :: { PondSnapshot } do
				-- A live PondSync that arrived first is newer than this reply.
				if not ClientState.Ponds[pond.plot] then
					applyPond(pond)
				end
			end
		end
	end)
end

return ClientState
