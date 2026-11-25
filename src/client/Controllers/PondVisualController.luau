--!strict
-- Client-side pond presentation: creature models swimming along cubic Bezier
-- paths inside each pond's water volume, mutation / aura VFX, inspection cards
-- and pond event effects.
--
-- The server never simulates swimming. It only replicates which creatures are
-- slotted (PondSync); every position here is cosmetic and local.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Rarities = require(Shared.Config.Rarities)
local Creatures = require(Shared.Config.Creatures)
local Mutations = require(Shared.Config.Mutations)

local ClientState = require(script.Parent.Parent.ClientState)
local Kit = require(script.Parent.Parent.UI.Kit)
local CreatureModel = require(script.Parent.Parent.Visual.CreatureModel)
local Effects = require(script.Parent.Parent.Visual.Effects)

local Theme = Kit.Theme

type PondSnapshot = Types.PondSnapshot
type PondFish = Types.PondFish

type FishVisual = {
	uid: string,
	signature: string, -- species/weight/mutation; a change forces a rebuild
	model: Model,
	root: BasePart,
	joints: { [string]: Motor6D },
	card: TextLabel?,
	-- Bezier segment in the water part's local space
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	t: number,
	duration: number,
	speed: number, -- studs / second
	phase: number,
	tempo: number, -- tail beat frequency multiplier
	halfExtents: Vector3,
}

type PondView = {
	plot: number,
	model: Instance,
	water: BasePart,
	fish: { [string]: FishVisual },
	starfallUntil: number,
	marker: BillboardGui?,
	markerOwner: number,
	markerSub: TextLabel?,
}

local ANIMATE_DISTANCE = 320 -- ponds farther than this from the camera are frozen
local CARD_DISTANCE = 55
local CARD_SIZE = Vector2.new(7.5, 3.4) -- studs
local MAX_CARD_OFFSET_Y = 11 -- studs: clamps 12x Colossal fish so cards stay on-screen
local MARKER_SIZE = Vector2.new(190, 78) -- pixels: constant on screen so it reads from across the map
local MARKER_HEIGHT = 36 -- studs above the water (clears the hub cliff from most angles)
local RIPPLE_DISTANCE = 220 -- studs from camera for ambient weather ripples
local RAIN_RIPPLE_INTERVAL = 0.30 -- seconds between ambient ripple ticks in Rain
local STORM_RIPPLE_INTERVAL = 0.15 -- seconds between ambient ripple ticks in Storm
local RAIN_RIPPLE_COLOR = Color3.fromRGB(205, 232, 255)
local STORM_RIPPLE_COLOR = Color3.fromRGB(185, 220, 255)
local CARD_GRADIENT_TOP = Color3.fromRGB(28, 40, 62)
local CARD_GRADIENT_BOTTOM = Color3.fromRGB(12, 18, 30)
local CARD_TEXT_STROKE = Color3.fromRGB(10, 14, 22)

local PondVisualController = {}

local rng = Random.new()
local views: { [number]: PondView } = {}
local pending: { [number]: PondSnapshot } = {}
local container: Folder

-- Inspection cards ---------------------------------------------------------------------

local function buildCard(species: Creatures.Species, root: BasePart, scale: number, colossal: boolean): TextLabel
	local info = Rarities.Get(species.rarity)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "InspectCard"
	billboard.Adornee = root
	billboard.Size = UDim2.fromScale(CARD_SIZE.X, CARD_SIZE.Y)
	billboard.StudsOffsetWorldSpace =
		Vector3.new(0, math.min(species.length * scale * 0.35 + 2.2, MAX_CARD_OFFSET_Y), 0)
	billboard.MaxDistance = CARD_DISTANCE
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.Parent = root

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = Color3.new(1, 1, 1)
	card.BackgroundTransparency = 0.08
	card.BorderSizePixel = 0
	card.Parent = billboard
	Kit.Gradient(card, CARD_GRADIENT_TOP, CARD_GRADIENT_BOTTOM)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.16, 0)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = if colossal then Theme.Gold else info.color
	stroke.Thickness = if colossal then 2.5 else 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Theme.Text
	label.TextStrokeColor3 = CARD_TEXT_STROKE
	label.TextStrokeTransparency = 0.3
	label.RichText = true
	label.TextWrapped = true
	label.Parent = card

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.07, 0)
	padding.PaddingBottom = UDim.new(0.07, 0)
	padding.PaddingLeft = UDim.new(0.05, 0)
	padding.PaddingRight = UDim.new(0.05, 0)
	padding.Parent = label

	return label
end

local function cardText(fish: PondFish, species: Creatures.Species): string
	local info = Rarities.Get(species.rarity)
	local hex = info.color:ToHex()
	local mutationLine = ""
	if fish.mutation ~= "Normal" then
		mutationLine = ` · {Mutations.Get(fish.mutation).name}`
	end
	local header = if fish.colossal
		then `<font color="#FFCC40">★ COLOSSAL ★</font>\n{species.name}`
		else species.name
	return `{header}\n<font color="#{hex}">[{species.rarity}]{mutationLine}</font>\n<font color="#FFCC40">{Format.Rate(
		fish.goldPerSec
	)}</font> · {Format.Weight(fish.weight)}`
end

local function signatureOf(fish: PondFish): string
	return `{fish.speciesId}|{fish.weight}|{fish.mutation}|{fish.colossal}`
end

local function randomPoint(half: Vector3): Vector3
	return Vector3.new(
		rng:NextNumber(-half.X, half.X),
		rng:NextNumber(-half.Y, half.Y),
		rng:NextNumber(-half.Z, half.Z)
	)
end

local function clampToBox(point: Vector3, half: Vector3): Vector3
	return Vector3.new(
		math.clamp(point.X, -half.X, half.X),
		math.clamp(point.Y, -half.Y, half.Y),
		math.clamp(point.Z, -half.Z, half.Z)
	)
end

-- Starts the next Bezier segment. Mirroring the previous control point keeps the
-- heading continuous across segments, so fish never snap-turn.
local function nextSegment(visual: FishVisual)
	local half = visual.halfExtents
	local start = visual.p3
	local carry = (visual.p3 - visual.p2)
	local target = randomPoint(half)
	local distance = (target - start).Magnitude
	local handle = math.max(distance * 0.35, 1)

	local outDir = if carry.Magnitude > 0.05 then carry.Unit else (target - start + Vector3.new(0.01, 0, 0)).Unit
	visual.p0 = start
	visual.p1 = clampToBox(start + outDir * handle, half)
	visual.p2 = clampToBox(target + randomPoint(Vector3.new(handle, handle * 0.2, handle)), half)
	visual.p3 = target
	visual.t = 0

	-- Approximate arc length with the control polygon.
	local length = (visual.p1 - visual.p0).Magnitude
		+ (visual.p2 - visual.p1).Magnitude
		+ (visual.p3 - visual.p2).Magnitude
	visual.duration = math.max(length / visual.speed, 0.8)
end

local function createFish(view: PondView, fish: PondFish): FishVisual?
	local built = CreatureModel.Build(fish.speciesId, fish.weight, fish.mutation, true)
	if not built then
		return nil
	end
	local species, model, root, joints, scale = built.species, built.model, built.root, built.joints, built.scale

	-- Keep the whole body inside the water volume, however large the fish is.
	local length = built.length
	local size = view.water.Size
	local half = Vector3.new(
		math.max(size.X / 2 - length * 0.6 - 0.5, 0.5),
		math.max(size.Y / 2 - length * 0.22 - 0.4, 0.1),
		math.max(size.Z / 2 - length * 0.6 - 0.5, 0.5)
	)

	local label = buildCard(species, root, scale, fish.colossal)
	label.Text = cardText(fish, species)

	local start = randomPoint(half)
	local visual: FishVisual = {
		uid = fish.uid,
		signature = signatureOf(fish),
		model = model,
		root = root,
		joints = joints,
		card = label,
		p0 = start,
		p1 = start,
		p2 = start,
		p3 = start,
		t = 1,
		duration = 1,
		-- Small fish dart, giants cruise.
		speed = math.clamp(7 / math.sqrt(math.max(length, 0.5)), 1.6, 6.5),
		phase = rng:NextNumber(0, math.pi * 2),
		tempo = math.clamp(9 / math.sqrt(math.max(length, 0.5)), 2.5, 9),
		halfExtents = half,
	}
	nextSegment(visual)
	root.CFrame = view.water.CFrame * CFrame.new(start)
	model.Parent = container
	return visual
end

-- Pond views ----------------------------------------------------------------------------

local function findPlot(plot: number): (Instance?, BasePart?)
	local map = Workspace:FindFirstChild("Map")
	local ponds = map and map:FindFirstChild("Ponds")
	local model = ponds and ponds:FindFirstChild("Pond" .. plot)
	local water = model and model:FindFirstChild("Water")
	if model and water and water:IsA("BasePart") then
		return model, water
	end
	return nil, nil
end

local function updateSign(view: PondView, pond: PondSnapshot)
	local label = view.model:FindFirstChild("OwnerLabel", true)
	if label and label:IsA("TextLabel") then
		if pond.ownerUserId == 0 then
			label.Text = "Unclaimed Pond"
		else
			label.Text = `{pond.ownerName}'s Pond\n{Format.Rate(pond.total)}`
		end
	end
end

-- Floating owner marker (avatar + name) high above each claimed pond, visible
-- from anywhere on the map. Your own pond is gold and labelled "MY POND".
local function updateMarker(view: PondView, pond: PondSnapshot)
	if pond.ownerUserId == 0 then
		if view.marker then
			view.marker:Destroy()
			view.marker = nil
			view.markerSub = nil
			view.markerOwner = 0
		end
		return
	end

	local localPlayer = Players.LocalPlayer
	local mine = pond.ownerUserId == localPlayer.UserId
	local accent = if mine then Color3.fromRGB(255, 204, 64) else Color3.fromRGB(72, 132, 214)

	if not view.marker or view.markerOwner ~= pond.ownerUserId then
		if view.marker then
			view.marker:Destroy()
		end
		local scale = if mine then 1.15 else 1
		local marker = Instance.new("BillboardGui")
		marker.Name = "PondMarker" .. pond.plot
		marker.Adornee = view.water
		marker.Size = UDim2.fromOffset(MARKER_SIZE.X * scale, MARKER_SIZE.Y * scale)
		marker.StudsOffsetWorldSpace = Vector3.new(0, MARKER_HEIGHT, 0)
		marker.AlwaysOnTop = true
		marker.MaxDistance = 5000
		marker.LightInfluence = 0
		marker.ResetOnSpawn = false

		local pill = Instance.new("Frame")
		pill.Name = "Pill"
		pill.Size = UDim2.fromScale(1, 0.72)
		pill.BackgroundColor3 = Color3.new(1, 1, 1)
		pill.BackgroundTransparency = 0.08
		pill.BorderSizePixel = 0
		pill.Parent = marker
		Kit.Gradient(pill, CARD_GRADIENT_TOP, CARD_GRADIENT_BOTTOM)
		local pillCorner = Instance.new("UICorner")
		pillCorner.CornerRadius = UDim.new(0.5, 0)
		pillCorner.Parent = pill
		local pillStroke = Instance.new("UIStroke")
		pillStroke.Color = accent
		pillStroke.Thickness = if mine then 3 else 2
		pillStroke.Parent = pill

		-- The owner's avatar headshot, loaded straight from the thumbnail service.
		local face = Instance.new("ImageLabel")
		face.Name = "Face"
		face.AnchorPoint = Vector2.new(0, 0.5)
		face.Position = UDim2.fromScale(0.03, 0.5)
		face.Size = UDim2.fromScale(0.84, 0.84)
		face.SizeConstraint = Enum.SizeConstraint.RelativeYY
		face.BackgroundColor3 = Color3.fromRGB(40, 60, 100)
		face.BorderSizePixel = 0
		face.Image = `rbxthumb://type=AvatarHeadShot&id={pond.ownerUserId}&w=150&h=150`
		face.Parent = pill
		local faceCorner = Instance.new("UICorner")
		faceCorner.CornerRadius = UDim.new(0.5, 0)
		faceCorner.Parent = face

		local name = Instance.new("TextLabel")
		name.Name = "OwnerName"
		name.Position = UDim2.fromScale(0.33, 0.1)
		name.Size = UDim2.fromScale(0.62, 0.45)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamBlack
		name.Text = pond.ownerName
		name.TextScaled = true
		name.TextColor3 = Theme.Text
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Parent = pill
		Kit.TextStroke(name, CARD_TEXT_STROKE, 1.8)

		local sub = Instance.new("TextLabel")
		sub.Name = "Sub"
		sub.Position = UDim2.fromScale(0.33, 0.55)
		sub.Size = UDim2.fromScale(0.62, 0.33)
		sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.GothamBold
		sub.TextScaled = true
		sub.TextColor3 = accent
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.Parent = pill
		Kit.TextStroke(sub, CARD_TEXT_STROKE, 1.5)

		local arrow = Instance.new("TextLabel")
		arrow.Name = "Arrow"
		arrow.Position = UDim2.fromScale(0, 0.72)
		arrow.Size = UDim2.fromScale(1, 0.28)
		arrow.BackgroundTransparency = 1
		arrow.Font = Enum.Font.GothamBlack
		arrow.Text = "v"
		arrow.TextScaled = true
		arrow.TextColor3 = accent
		arrow.TextStrokeColor3 = CARD_TEXT_STROKE
		arrow.TextStrokeTransparency = 0.25
		arrow.Parent = marker

		marker.Parent = localPlayer:WaitForChild("PlayerGui")
		view.marker = marker
		view.markerOwner = pond.ownerUserId
		view.markerSub = sub
	end

	local sub = view.markerSub
	if sub then
		sub.Text = if mine then `MY POND · {Format.Rate(pond.total)}` else Format.Rate(pond.total)
	end
end

local function applyPond(pond: PondSnapshot)
	local view = views[pond.plot]
	if not view then
		local model, water = findPlot(pond.plot)
		if not model or not water then
			-- The map may not exist (or have streamed in) yet; retry later.
			pending[pond.plot] = pond
			return
		end
		view = {
			plot = pond.plot,
			model = model,
			water = water,
			fish = {},
			starfallUntil = 0,
			marker = nil,
			markerOwner = 0,
			markerSub = nil,
		}
		views[pond.plot] = view
	end
	assert(view, "pond view missing")
	pending[pond.plot] = nil

	local seen: { [string]: boolean } = {}
	for _, fish in pond.fish do
		seen[fish.uid] = true
		local existing: FishVisual? = view.fish[fish.uid]
		if existing and existing.signature ~= signatureOf(fish) then
			existing.model:Destroy()
			view.fish[fish.uid] = nil
			existing = nil
		end
		if existing then
			local species = Creatures.Get(fish.speciesId)
			if existing.card and species then
				existing.card.Text = cardText(fish, species)
			end
		else
			local created = createFish(view, fish)
			if created then
				view.fish[fish.uid] = created
			end
		end
	end
	for uid, visual in view.fish do
		if not seen[uid] then
			visual.model:Destroy()
			view.fish[uid] = nil
		end
	end

	if pond.starfallRemaining > 0 then
		view.starfallUntil = math.max(view.starfallUntil, os.clock() + pond.starfallRemaining)
	end
	updateSign(view, pond)
	updateMarker(view, pond)
end

-- Animation -----------------------------------------------------------------------------

local function bezier(visual: FishVisual, t: number): (Vector3, Vector3)
	local u = 1 - t
	local p0, p1, p2, p3 = visual.p0, visual.p1, visual.p2, visual.p3
	local position = p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
	local tangent = (p1 - p0) * (3 * u * u) + (p2 - p1) * (6 * u * t) + (p3 - p2) * (3 * t * t)
	return position, tangent
end

local function animateFish(view: PondView, visual: FishVisual, dt: number, now: number)
	visual.t += dt / visual.duration
	if visual.t >= 1 then
		nextSegment(visual)
	end

	-- Ease along each segment so fish glide out of turns.
	local eased = visual.t * visual.t * (3 - 2 * visual.t)
	local position, tangent = bezier(visual, eased)
	local facing = if tangent.Magnitude > 0.01 then tangent.Unit else Vector3.new(0, 0, -1)
	visual.root.CFrame = view.water.CFrame * CFrame.lookAt(position, position + facing)

	CreatureModel.AnimateSwim(visual.joints, now * visual.tempo + visual.phase, now, visual.phase, 1)
end

-- Event VFX -----------------------------------------------------------------------------

local function spawnPondRipple(view: PondView, storm: boolean)
	local water = view.water
	local size = water.Size
	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = math.sqrt(rng:NextNumber()) * 0.85
	local localSurface =
		Vector3.new(math.cos(angle) * (size.X * 0.5) * radius, size.Y * 0.5, math.sin(angle) * (size.Z * 0.5) * radius)
	local worldPos = (water.CFrame * CFrame.new(localSurface)).Position
	local scale = if storm then rng:NextNumber(0.75, 1.3) else rng:NextNumber(0.6, 1.0)
	local color = if storm then STORM_RIPPLE_COLOR else RAIN_RIPPLE_COLOR
	Effects.Ripple(worldPos, scale, color)
end

local function spawnStar(view: PondView)
	local water = view.water
	local size = water.Size
	local offset = Vector3.new(rng:NextNumber(-size.X / 2, size.X / 2), 0, rng:NextNumber(-size.Z / 2, size.Z / 2))
	local star = Instance.new("Part")
	star.Name = "Starfall"
	star.Size = Vector3.new(0.6, 0.6, 0.6)
	star.Material = Enum.Material.Neon
	star.Color = Color3.fromRGB(255, 236, 160)
	star.Anchored = true
	star.CanCollide = false
	star.CanQuery = false
	star.CanTouch = false
	star.CastShadow = false
	star.CFrame = water.CFrame * CFrame.new(offset + Vector3.new(6, 40, 0)) * CFrame.Angles(0.6, 0.8, 0.3)
	star.Parent = container

	local tween = TweenService:Create(star, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		CFrame = water.CFrame * CFrame.new(offset + Vector3.new(0, size.Y / 2, 0)),
		Transparency = 0.2,
	})
	tween:Play()
	tween.Completed:Once(function()
		star:Destroy()
	end)
end

local function flashAt(position: Vector3, color: Color3, size: number)
	local flash = Instance.new("Part")
	flash.Name = "Flash"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.one * size
	flash.Material = Enum.Material.Neon
	flash.Color = color
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Position = position
	flash.Parent = container
	local tween = TweenService:Create(flash, TweenInfo.new(0.45), { Size = Vector3.one * size * 3, Transparency = 1 })
	tween:Play()
	tween.Completed:Once(function()
		flash:Destroy()
	end)
end

local function onPondEvent(plot: number, kind: string, data: { [string]: any }?)
	local view = views[plot]
	if not view then
		return
	end
	if kind == "Starfall" then
		local duration = if data and type(data.duration) == "number" then data.duration else 30
		view.starfallUntil = os.clock() + duration
	elseif kind == "StaticSurge" then
		local pond = ClientState.Ponds[plot]
		local slot = if data then data.slot else nil
		if pond then
			for _, fish in pond.fish do
				local visual = view.fish[fish.uid]
				if fish.slot == slot and visual then
					flashAt(visual.root.Position, Color3.fromRGB(255, 244, 120), 3)
				end
			end
		end
	elseif kind == "Blessing" then
		flashAt(view.water.Position + Vector3.new(0, view.water.Size.Y / 2 + 2, 0), Color3.fromRGB(120, 255, 170), 6)
	end
end

-- Lifecycle -----------------------------------------------------------------------------

function PondVisualController.Init()
	container = Instance.new("Folder")
	container.Name = "PondVisuals"
	container.Parent = Workspace
end

function PondVisualController.Start()
	ClientState.OnPond(applyPond)
	Net.Event("PondEvent").OnClientEvent:Connect(onPondEvent)

	-- PreSimulation is the step where Motor6D.Transform writes are picked up.
	RunService.PreSimulation:Connect(function(dt: number)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local cameraPosition = camera.CFrame.Position
		local now = os.clock()
		for _, view in views do
			if (view.water.Position - cameraPosition).Magnitude <= ANIMATE_DISTANCE then
				for _, visual in view.fish do
					animateFish(view, visual, dt, now)
				end
			end
		end
	end)

	task.spawn(function()
		local retryTimer = 0
		local rippleTimer = 0
		while true do
			local dt = task.wait(0.15)
			local now = os.clock()
			for _, view in views do
				if view.starfallUntil > now then
					spawnStar(view)
				end
			end

			-- Ambient rain/storm surface ripples on nearby ponds.
			local weather = Workspace:GetAttribute("Weather")
			if weather == "Rain" or weather == "Storm" then
				local storm = weather == "Storm"
				local interval = if storm then STORM_RIPPLE_INTERVAL else RAIN_RIPPLE_INTERVAL
				rippleTimer += dt
				if rippleTimer >= interval then
					rippleTimer = 0
					local camera = Workspace.CurrentCamera
					if camera then
						local cameraPosition = camera.CFrame.Position
						for _, view in views do
							if (view.water.Position - cameraPosition).Magnitude <= RIPPLE_DISTANCE then
								local count = if storm then rng:NextInteger(1, 2) else 1
								for _ = 1, count do
									spawnPondRipple(view, storm)
								end
							end
						end
					end
				end
			else
				rippleTimer = 0
			end

			-- Retry ponds whose plot model wasn't available when the sync arrived.
			retryTimer += dt
			if retryTimer >= 2 then
				retryTimer = 0
				for _, pond in pending do
					applyPond(pond)
				end
			end
		end
	end)
end

return PondVisualController
