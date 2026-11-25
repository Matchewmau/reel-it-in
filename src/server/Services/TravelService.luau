--!strict
-- Moves characters around the map: arriving at your own pond when you join or
-- respawn, the fast-travel menu, and fishing players back out of the Abyss.
--
-- Clients only ever send a destination name. The server decides whether the
-- trip is allowed and where exactly the character lands.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local PondConfig = require(Shared.Config.PondConfig)
local Travel = require(Shared.Config.Travel)

local DataService = require(script.Parent.DataService)
local PondService = require(script.Parent.PondService)
local FishingService = require(script.Parent.FishingService)

local TravelService = {}

local rng = Random.new()
local lastTravel: { [Player]: number } = {}
local welcomed: { [Player]: boolean } = {}

local function fail(message: string): { [string]: any }
	return { ok = false, error = message }
end

local function getMapFolder(name: string): Instance?
	local map = Workspace:FindFirstChild("Map")
	return map and map:FindFirstChild(name)
end

-- Standing on the pond's Spawn marker, facing the water.
local function plotArrival(plot: number): CFrame?
	local ponds = getMapFolder("Ponds")
	local pond = ponds and ponds:FindFirstChild("Pond" .. plot)
	local marker = pond and pond:FindFirstChild("Spawn")
	local water = pond and pond:FindFirstChild("Water")
	if not marker or not marker:IsA("BasePart") then
		return nil
	end
	local position = marker.Position + Vector3.new(0, Travel.ArrivalHeight, 0)
	if water and water:IsA("BasePart") then
		return CFrame.lookAt(position, Vector3.new(water.Position.X, position.Y, water.Position.Z))
	end
	return CFrame.new(position)
end

local function pointArrival(id: string): CFrame?
	if id == "Freshwater" then
		local cliffs = getMapFolder("Cliffs")
		if cliffs and cliffs:FindFirstChild("TheFalls") then
			return CFrame.lookAt(
				Vector3.new(-18, Travel.ArrivalHeight, -186),
				Vector3.new(0, Travel.ArrivalHeight, -214)
			)
		end
	end
	local points = getMapFolder("TravelPoints")
	local marker = points and points:FindFirstChild(id)
	if not marker or not marker:IsA("BasePart") then
		return nil
	end
	return marker.CFrame + Vector3.new(0, Travel.ArrivalHeight, 0)
end

local function getAliveRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function move(player: Player, target: CFrame): boolean
	local character = player.Character
	local root = getAliveRoot(player)
	if not character or not root then
		return false
	end
	local spread = Travel.ArrivalSpread
	local offset = Vector3.new(rng:NextNumber(-spread, spread), 0, rng:NextNumber(-spread, spread))
	character:PivotTo(target + offset)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

-- Sends a player to their own pond (or the hub if they have no plot / no map).
function TravelService.SendHome(player: Player): boolean
	local target = plotArrival(PondService.GetPlot(player)) or pointArrival("Hub")
	if not target then
		return false
	end
	return move(player, target)
end

local function handleTeleport(player: Player, kind: any, plot: any): { [string]: any }
	if not DataService.Get(player) then
		return fail("Still loading your data...")
	end
	if type(kind) ~= "string" then
		return fail("Invalid request.")
	end
	local now = os.clock()
	local remaining = Travel.Cooldown - (now - (lastTravel[player] or -math.huge))
	if remaining > 0 then
		return fail(`Travel is ready in {Format.Duration(remaining)}.`)
	end
	if not getAliveRoot(player) then
		return fail("You can't travel right now.")
	end
	if FishingService.IsFishing(player) then
		return fail("Reel in your line first.")
	end

	local target: CFrame? = nil
	local name = ""
	if kind == "MyPond" then
		target = plotArrival(PondService.GetPlot(player))
		name = "your pond"
	elseif kind == "Pond" then
		if type(plot) ~= "number" or plot ~= math.floor(plot) or plot < 1 or plot > PondConfig.PlotCount then
			return fail("Invalid request.")
		end
		local owner = PondService.GetPlotOwner(plot)
		if not owner then
			return fail("That pond has no owner right now.")
		end
		target = plotArrival(plot)
		name = if owner == player then "your pond" else `{owner.DisplayName}'s pond`
	else
		local destination = Travel.Get(kind)
		if not destination then
			return fail("Unknown destination.")
		end
		target = pointArrival(destination.id)
		name = destination.name
	end

	if not target then
		return fail("That destination isn't available yet.")
	end
	if not move(player, target) then
		return fail("You can't travel right now.")
	end
	lastTravel[player] = now
	return { ok = true, name = name }
end

local function onCharacterAdded(player: Player, character: Model)
	if not character:WaitForChild("HumanoidRootPart", 10) then
		return
	end
	-- Let the engine finish its own spawn placement before overriding it.
	task.wait()
	if player.Character ~= character or not DataService.Get(player) then
		return
	end
	if TravelService.SendHome(player) and not welcomed[player] and PondService.GetPlot(player) > 0 then
		welcomed[player] = true
		Net.Event("Notify"):FireClient(player, "Welcome! This pond is yours - catch something to fill it.", "good")
	end
end

function TravelService.Init()
	Net.Handle("Teleport", handleTeleport)

	-- Runs after PondService's own callback (registration order), so the plot is claimed.
	DataService.OnProfileLoaded(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
		local character = player.Character
		if character then
			task.spawn(onCharacterAdded, player, character)
		end
	end)
end

function TravelService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		lastTravel[player] = nil
		welcomed[player] = nil
	end)

	-- Rescue: the Abyss is railed off, but anyone who does get in is returned to
	-- their pond instead of being stranded at the bottom.
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, player in Players:GetPlayers() do
				local root = getAliveRoot(player)
				if root and root.Position.Y < Travel.SeaRescueY and DataService.Get(player) then
					if TravelService.SendHome(player) then
						Net.Event("Notify"):FireClient(player, "Splash! We fished you out of the Abyss.", "info")
					end
				end
			end
		end
	end)
end

return TravelService
