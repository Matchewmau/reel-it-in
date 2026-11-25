--!strict
-- Rod-in-hand, fishing line, bobber and water effects for EVERY player in the
-- server, so neighbours can see who is fishing and when someone has a bite.
--
-- The server only replicates two Player attributes ("RodId", "FishingState").
-- Everything drawn here is local and cosmetic, positioned each frame from the
-- character's hand: nothing is created or simulated on the server.
--
-- Rods and the bobber use the authored models under ReplicatedStorage/Assets
-- (Rods/<RodId>, Props/Bobber) when they exist, and plain blocky stand-ins
-- when they do not, so the game never depends on art being present.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Rarities = require(Shared.Config.Rarities)
local Rods = require(Shared.Config.Rods)

local Effects = require(script.Parent.Parent.Visual.Effects)

type Visual = {
	rodId: string,
	folder: Folder,
	rod: Model, -- parented to `folder` while shown
	handle: BasePart, -- the anchored part we position each frame
	reel: Motor6D?,
	bobber: Model,
	bobberRoot: BasePart,
	line: Beam,
	alert: BillboardGui,
	state: string,
	stateAt: number,
	castFrom: Vector3?, -- rod tip when the cast began (start of the arc)
	castPoint: Vector3?, -- where the bobber sits on the water
	landed: boolean,
	lastSplash: number,
	reelAngle: number,
}

local CAST_DISTANCES = { 14, 20, 26, 32 } -- studs out, tried in order
local CAST_ANGLES = { 0, 25, -25, 50, -50, 80, -80, 120, -120, 180 } -- degrees off the facing direction
local CAST_TIME = 0.55 -- seconds for the bobber to fly out
local CAST_ARC = 5 -- peak height of that flight, studs
local BITE_SPLASH_INTERVAL = 0.45 -- seconds between splashes while a fish is on
local REEL_SPEED = 16 -- radians per second while a fish is on
local RECENT_CAST_MEMORY = 3 -- seconds a finished cast's position is remembered
local FALLBACK_ROD_LENGTH = 5
local REST_TILT = math.rad(25) -- rod angle above horizontal when idle
local FISHING_TILT = math.rad(50) -- while the line is out
local CAST_BACK_TILT = math.rad(125) -- wind-up behind the shoulder at the start of a cast
local FIGHT_TILT = math.rad(64) -- hauled back against a hooked fish
local FIGHT_SHAKE = math.rad(4) -- shudder amplitude while it fights
local FIGHT_SHAKE_SPEED = 30 -- radians per second
local ARM_FOLLOW = 0.9 -- how much of the rod angle the arm takes up

local FishingVisualController = {}

local visuals: { [Player]: Visual } = {}
local recentCasts: { [Player]: { point: Vector3, at: number } } = {}
local container: Folder

-- Construction ----------------------------------------------------------------------------

local function localPart(name: string, size: Vector3, color: Color3, anchored: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = anchored
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	return part
end

local function weldTo(root: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
end

local function assetModel(folderName: string, id: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild(folderName)
	local template = folder and folder:FindFirstChild(id)
	if template and template:IsA("Model") and template.PrimaryPart then
		return template:Clone()
	end
	return nil
end

-- Makes a cloned asset safe to puppet: only its root is anchored, nothing collides.
local function prepare(model: Model, root: BasePart)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = descendant == root
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
end

-- Returns the rod model, its Handle, the Tip attachment and the optional Reel joint.
local function buildRod(rodId: string): (Model, BasePart, Attachment, Motor6D?)
	local authored = assetModel("Rods", rodId)
	local handle = if authored then authored.PrimaryPart else nil
	local tip = if authored then authored:FindFirstChild("Tip", true) else nil
	if authored and handle and tip and tip:IsA("Attachment") then
		prepare(authored, handle)
		local reel = handle:FindFirstChild("Reel")
		return authored, handle, tip, if reel and reel:IsA("Motor6D") then reel else nil
	end
	if authored then
		authored:Destroy()
	end

	-- Stand-in: a handle and a shaft tinted by the rod's rarity.
	local def = Rods.Get(rodId)
	local color = if def and def.rarity ~= "Common"
		then Rarities.Info[def.rarity].color
		else Color3.fromRGB(150, 108, 66)
	local model = Instance.new("Model")
	model.Name = rodId
	local fallbackHandle = localPart("Handle", Vector3.new(0.35, 0.35, 1.2), Color3.fromRGB(52, 40, 32), true)
	fallbackHandle.Parent = model
	model.PrimaryPart = fallbackHandle
	local shaft = localPart("Shaft", Vector3.new(0.18, 0.18, FALLBACK_ROD_LENGTH), color, false)
	shaft.CFrame = fallbackHandle.CFrame * CFrame.new(0, 0, -0.6 - FALLBACK_ROD_LENGTH / 2)
	if def and Rarities.IsAtLeast(def.rarity, "Epic") then
		shaft.Material = Enum.Material.Neon
	end
	shaft.Parent = model
	weldTo(fallbackHandle, shaft)
	local fallbackTip = Instance.new("Attachment")
	fallbackTip.Name = "Tip"
	fallbackTip.Position = Vector3.new(0, 0, -FALLBACK_ROD_LENGTH / 2)
	fallbackTip.Parent = shaft
	return model, fallbackHandle, fallbackTip, nil
end

-- Returns the bobber model, its root and the attachment the line ties to.
local function buildBobber(): (Model, BasePart, Attachment)
	local authored = assetModel("Props", "Bobber")
	local root = if authored then authored.PrimaryPart else nil
	local lineEnd = if authored then authored:FindFirstChild("Line", true) else nil
	if authored and root and lineEnd and lineEnd:IsA("Attachment") then
		prepare(authored, root)
		return authored, root, lineEnd
	end
	if authored then
		authored:Destroy()
	end

	local model = Instance.new("Model")
	model.Name = "Bobber"
	local base = localPart("RootPart", Vector3.new(0.9, 0.55, 0.9), Color3.fromRGB(245, 245, 245), true)
	base.Parent = model
	model.PrimaryPart = base
	local top = localPart("Top", Vector3.new(0.9, 0.55, 0.9), Color3.fromRGB(232, 64, 56), false)
	top.CFrame = base.CFrame * CFrame.new(0, 0.55, 0)
	top.Parent = model
	weldTo(base, top)
	local fallbackLine = Instance.new("Attachment")
	fallbackLine.Name = "Line"
	fallbackLine.Position = Vector3.new(0, 0.3, 0)
	fallbackLine.Parent = top
	return model, base, fallbackLine
end

local function build(player: Player, rodId: string): Visual
	local folder = Instance.new("Folder")
	folder.Name = "Fishing_" .. player.UserId
	folder.Parent = container

	local rod, handle, tip, reel = buildRod(rodId)
	local bobber, bobberRoot, lineEnd = buildBobber()

	local line = Instance.new("Beam")
	line.Attachment0 = tip
	line.Attachment1 = lineEnd
	line.Width0 = 0.06
	line.Width1 = 0.06
	line.FaceCamera = true
	line.Segments = 12
	line.Color = ColorSequence.new(Color3.fromRGB(240, 240, 240))
	line.Transparency = NumberSequence.new(0.2)
	line.LightInfluence = 0
	line.Enabled = false
	line.Parent = handle

	-- "!" over the bobber when a fish is on the line.
	local alert = Instance.new("BillboardGui")
	alert.Size = UDim2.fromScale(2.4, 2.4)
	alert.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	alert.AlwaysOnTop = true
	alert.MaxDistance = 140
	alert.Enabled = false
	alert.Adornee = bobberRoot
	alert.Parent = bobberRoot
	local mark = Instance.new("TextLabel")
	mark.Size = UDim2.fromScale(1, 1)
	mark.BackgroundTransparency = 1
	mark.Font = Enum.Font.GothamBlack
	mark.Text = "!"
	mark.TextScaled = true
	mark.TextColor3 = Color3.fromRGB(255, 220, 60)
	mark.TextStrokeTransparency = 0
	mark.Parent = alert

	return {
		rodId = rodId,
		folder = folder,
		rod = rod,
		handle = handle,
		reel = reel,
		bobber = bobber,
		bobberRoot = bobberRoot,
		line = line,
		alert = alert,
		state = "Idle",
		stateAt = os.clock(),
		castFrom = nil,
		castPoint = nil,
		landed = false,
		lastSplash = 0,
		reelAngle = 0,
	}
end

local function destroy(player: Player)
	local visual = visuals[player]
	if visual then
		visual.rod:Destroy()
		visual.bobber:Destroy()
		visual.folder:Destroy()
		visuals[player] = nil
	end
end

-- Placement -------------------------------------------------------------------------------

-- Where the bobber lands: the nearest open water in front of the character. Water
-- surfaces in the map are non-colliding parts, so a hit on something solid (a
-- boardwalk, a bank) means "cast further"; the last hit is the fallback.
local function findCastPoint(root: BasePart): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { container }
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(exclude, other.Character)
		end
	end
	params.FilterDescendantsInstances = exclude

	-- Straight ahead first, then fanning out to either side, so a cast made while
	-- facing along a boardwalk still finds the water beside it.
	local fallback: Vector3? = nil
	for _, degrees in CAST_ANGLES do
		local look = (root.CFrame * CFrame.Angles(0, math.rad(degrees), 0)).LookVector
		for _, distance in CAST_DISTANCES do
			local ahead = root.Position + look * distance
			local hit = Workspace:Raycast(ahead + Vector3.new(0, 12, 0), Vector3.new(0, -60, 0), params)
			if hit then
				if not hit.Instance.CanCollide then
					return hit.Position
				end
				fallback = fallback or hit.Position
			end
		end
	end
	return fallback or (root.Position + root.CFrame.LookVector * CAST_DISTANCES[1] - Vector3.new(0, 8, 0))
end

-- Lifts the rod arm with the rod while fishing, so the cast and the fight read on
-- the character and not just the rod. Runs after the Animator each frame, so it
-- only overrides this one joint and stops as soon as the line is in. Classic rigs
-- join limbs with Motor6D; newer avatars use AnimationConstraint (same Transform).
local function poseRodArm(character: Model, tilt: number)
	local upperArm = character:FindFirstChild("RightUpperArm")
	local shoulder = upperArm and upperArm:FindFirstChild("RightShoulder")
	if shoulder and (shoulder:IsA("Motor6D") or shoulder:IsA("AnimationConstraint")) then
		(shoulder :: any).Transform = CFrame.Angles(tilt * ARM_FOLLOW, 0, 0)
	end
end

local function getHand(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

local function show(model: Model, parent: Instance, visible: boolean)
	local target = if visible then parent else nil
	if model.Parent ~= target then
		model.Parent = target
	end
end

local function update(player: Player, visual: Visual, now: number, dt: number)
	local character = player.Character
	local hand = if character then getHand(character) else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	-- A player showing off a fish has their hands full: no rod.
	local carrying = player:GetAttribute("HeldSpecies") ~= nil
	if not hand or not root or not root:IsA("BasePart") or carrying then
		show(visual.rod, visual.folder, false)
		show(visual.bobber, visual.folder, false)
		visual.line.Enabled = false
		visual.alert.Enabled = false
		return
	end
	show(visual.rod, visual.folder, true)

	local rawState = player:GetAttribute("FishingState")
	local state = if type(rawState) == "string" then rawState else "Idle"
	local fishing = state == "Waiting" or state == "Biting"

	if state ~= visual.state then
		local previous = visual.state
		visual.state = state
		visual.stateAt = now
		if state == "Waiting" then
			-- A new cast: the bobber flies from the rod tip to the water.
			local tip = visual.line.Attachment0
			visual.castFrom = if tip then tip.WorldPosition else hand.Position
			visual.castPoint = findCastPoint(root)
			visual.landed = false
		elseif state == "Biting" then
			if visual.castPoint then
				Effects.Splash(visual.castPoint, 1.4)
			end
			visual.lastSplash = now
		elseif not fishing then
			local point = visual.castPoint
			if point then
				-- Remembered briefly so a caught fish can leap from here (HoldVisualController).
				recentCasts[player] = { point = point, at = now }
				if previous == "Biting" then
					Effects.Splash(point, 2)
				end
			end
			visual.castPoint = nil
		end
	end

	-- Rod pose: resting low; whipped from behind the shoulder to the front on a
	-- cast; held high while waiting; pulled back and shuddering while a fish fights.
	local sinceChange = now - visual.stateAt
	local tilt = REST_TILT
	if state == "Waiting" then
		if sinceChange < CAST_TIME then
			local t = sinceChange / CAST_TIME
			tilt = CAST_BACK_TILT + (FISHING_TILT - CAST_BACK_TILT) * (t * t)
		else
			tilt = FISHING_TILT
		end
	elseif state == "Biting" then
		tilt = FIGHT_TILT + math.sin(now * FIGHT_SHAKE_SPEED) * FIGHT_SHAKE
	end
	local castPoint = visual.castPoint
	if fishing and not castPoint then
		-- Joined mid-cast: no cast moment to anchor to, so place it now.
		castPoint = findCastPoint(root)
		visual.castPoint = castPoint
		visual.landed = true
	end

	local handleBase = CFrame.new(hand.Position, hand.Position + root.CFrame.LookVector)
	if fishing and castPoint then
		local flatTarget = Vector3.new(castPoint.X, hand.Position.Y, castPoint.Z)
		if (flatTarget - hand.Position).Magnitude > 0.1 then
			handleBase = CFrame.lookAt(hand.Position, flatTarget)
		end
	end
	visual.handle.CFrame = handleBase * CFrame.Angles(tilt, 0, 0)
	if fishing and character then
		poseRodArm(character, tilt)
	end

	if not fishing or not castPoint then
		show(visual.bobber, visual.folder, false)
		visual.line.Enabled = false
		visual.alert.Enabled = false
		return
	end
	show(visual.bobber, visual.folder, true)
	visual.line.Enabled = true

	local elapsed = now - visual.stateAt
	local castFrom = visual.castFrom
	if state == "Waiting" and not visual.landed and castFrom and elapsed < CAST_TIME then
		-- In flight: a parabola from the rod tip to the water.
		local t = elapsed / CAST_TIME
		local position = castFrom:Lerp(castPoint, t) + Vector3.new(0, math.sin(t * math.pi) * CAST_ARC, 0)
		visual.bobberRoot.CFrame = CFrame.new(position)
		visual.line.CurveSize0 = 0
		visual.line.CurveSize1 = 0
		visual.alert.Enabled = false
		return
	end
	if not visual.landed then
		visual.landed = true
		Effects.Splash(castPoint, 1)
	end

	local bob
	if state == "Biting" then
		-- Yanked under and thrashing, with spray while the fight goes on.
		bob = -0.45 + math.sin(elapsed * 22) * 0.18
		if now - visual.lastSplash >= BITE_SPLASH_INTERVAL then
			visual.lastSplash = now
			Effects.Splash(castPoint, 0.7)
		end
		local reel = visual.reel
		if reel then
			visual.reelAngle += REEL_SPEED * dt
			reel.Transform = CFrame.Angles(visual.reelAngle, 0, 0)
		end
	else
		bob = math.sin(elapsed * 2.4) * 0.08
	end
	visual.bobberRoot.CFrame = CFrame.new(castPoint + Vector3.new(0, bob, 0))
	visual.line.CurveSize0 = 0
	visual.line.CurveSize1 = 0
	visual.alert.Enabled = state == "Biting"
end

-- Where this player's line was in the water, if their cast ended within `maxAge`
-- seconds. Lets other visuals (a caught fish leaping into hand) start from there.
function FishingVisualController.GetRecentCastPoint(player: Player, maxAge: number): Vector3?
	-- The catch and the end of the cast replicate in the same frame, and whichever
	-- controller updates first must not matter: a line that is still drawn counts.
	local visual = visuals[player]
	if visual and visual.castPoint then
		return visual.castPoint
	end
	local recent = recentCasts[player]
	if recent and os.clock() - recent.at <= math.min(maxAge, RECENT_CAST_MEMORY) then
		return recent.point
	end
	return nil
end

function FishingVisualController.Init()
	container = Instance.new("Folder")
	container.Name = "FishingVisuals"
	container.Parent = Workspace
end

function FishingVisualController.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		destroy(player)
		recentCasts[player] = nil
	end)

	-- PreSimulation: the step where Motor6D.Transform writes (the reel) are picked up.
	RunService.PreSimulation:Connect(function(dt: number)
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			local rodId = player:GetAttribute("RodId")
			if type(rodId) == "string" then
				local existing: Visual? = visuals[player]
				if existing and existing.rodId == rodId then
					update(player, existing, now, dt)
				else
					destroy(player)
					local created = build(player, rodId)
					visuals[player] = created
					update(player, created, now, dt)
				end
			end
		end
	end)
end

return FishingVisualController
