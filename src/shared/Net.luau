--!strict
-- Single source of truth for remotes. The server creates them at boot; the
-- client waits for them. Nothing else may create or look up remotes by path.
--
-- Convention:
--   * RemoteFunctions are client -> server requests and return
--     { ok: boolean, error: string?, ... }. The server never invokes a client.
--   * RemoteEvents are server -> client only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"

local Net = {}

-- Server -> client
Net.Events = {
	"StateSync", -- (snapshot: Types.Snapshot) owner-only profile state
	"PondSync", -- (pond: Types.PondSnapshot) public pond state, all clients
	"PondEvent", -- (plot: number, kind: string, data: any) Starfall / Static Surge VFX
	"Bite", -- (payload) a fish is on the line: start the reeling minigame
	"Notify", -- (text: string, kind: string?) toast for one player
	"Announce", -- (text: string, rarity: string?) server-wide banner
	"BestCatches", -- (catches: { Types.BestCatch }) server best catches board
}

-- Client -> server
Net.Functions = {
	"GetState",
	"GetPonds",
	"Cast",
	"CancelCast",
	"ReelFinish",
	"Equip",
	"PondPlace",
	"PondRemove",
	"BuySlot",
	"SellCreature",
	"Bless",
	"RodPull",
	"BuyBait",
	"BaitCrate",
	"Teleport",
	"GetBestCatches",
	"Hold",
}

-- QA-only request, created by the server only when it is running inside Studio
-- (see DevService). It does not exist in a live game.
Net.StudioFunction = "DevCommand"

local function getFolder(): Instance
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		assert(folder, "Net.SetupServer() must run before remotes are used")
		return folder
	end
	return ReplicatedStorage:WaitForChild(FOLDER_NAME)
end

function Net.SetupServer()
	assert(RunService:IsServer(), "Net.SetupServer is server-only")
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		created.Parent = ReplicatedStorage
		folder = created
	end
	assert(folder, "Remotes folder missing")

	for _, name in Net.Events do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
	local functions = table.clone(Net.Functions)
	if RunService:IsStudio() then
		table.insert(functions, Net.StudioFunction)
	end
	for _, name in functions do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	end
end

function Net.Event(name: string): RemoteEvent
	local folder = getFolder()
	local remote = if RunService:IsServer() then folder:FindFirstChild(name) else folder:WaitForChild(name)
	assert(remote and remote:IsA("RemoteEvent"), `Unknown RemoteEvent "{name}"`)
	return remote
end

function Net.Function(name: string): RemoteFunction
	local folder = getFolder()
	local remote = if RunService:IsServer() then folder:FindFirstChild(name) else folder:WaitForChild(name)
	assert(remote and remote:IsA("RemoteFunction"), `Unknown RemoteFunction "{name}"`)
	return remote
end

-- Server: registers a request handler. Handler errors are caught so a bug can
-- never leave a client's InvokeServer hanging on a raw error.
function Net.Handle(name: string, handler: (player: Player, ...any) -> { [string]: any })
	assert(RunService:IsServer(), "Net.Handle is server-only")
	Net.Function(name).OnServerInvoke = function(player: Player, ...: any): { [string]: any }
		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(`[Net] {name} handler failed for {player.Name}: {result}`)
			return { ok = false, error = "Something went wrong. Try again." }
		end
		return result
	end
end

-- Client: invokes a request and always returns a response table.
function Net.Invoke(name: string, ...: any): { [string]: any }
	assert(RunService:IsClient(), "Net.Invoke is client-only")
	local ok, result = pcall(function(...: any): any
		return Net.Function(name):InvokeServer(...)
	end, ...)
	if not ok or type(result) ~= "table" then
		return { ok = false, error = "Connection problem. Try again." }
	end
	return result
end

return Net
