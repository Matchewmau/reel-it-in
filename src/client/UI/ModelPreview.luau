--!strict
-- 3D item previews for the UI: a ViewportFrame showing the real model of a
-- creature, rod or bait (the same assets used in the world), framed
-- automatically and optionally spinning. Used by the HUD lists, the catch
-- card and the gacha reveal.
--
--   local viewport = ModelPreview.Create({ kind = "Creature", id = "AbyssalAngler", mutation = "Golden" })
--   viewport.Size = UDim2.fromOffset(64, 64); viewport.Parent = someFrame
--   ModelPreview.SetSpin(viewport, true)
--
-- A preview cleans itself up when its ViewportFrame is destroyed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Creatures = require(Shared.Config.Creatures)
local Rarities = require(Shared.Config.Rarities)
local Rods = require(Shared.Config.Rods)
local Baits = require(Shared.Config.Baits)

local CreatureModel = require(script.Parent.Parent.Visual.CreatureModel)

export type Spec = {
	kind: string, -- "Creature" | "Rod" | "Bait"
	id: string,
	mutation: Types.MutationId?, -- creatures only
}

type Spinner = {
	model: Model,
	origin: CFrame, -- model pivot at creation
	center: Vector3, -- bounding-box centre the model turns around
	angle: number,
}

local FIELD_OF_VIEW = 30
local FRAME_PADDING = 1.15 -- >1 leaves a margin around the model
local SPIN_SPEED = math.rad(50) -- radians per second

local ModelPreview = {}

local spinners: { [ViewportFrame]: Spinner } = {}
local known: { [ViewportFrame]: Spinner } = {}
local spinConnection: RBXScriptConnection? = nil

-- A plain block stands in when an asset has not been built yet, so the UI never breaks.
local function fallbackModel(color: Color3, size: Vector3): Model
	local model = Instance.new("Model")
	local part = Instance.new("Part")
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.Parent = model
	model.PrimaryPart = part
	return model
end

local function assetClone(folderName: string, id: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild(folderName)
	local template = folder and folder:FindFirstChild(id)
	if template and template:IsA("Model") then
		return template:Clone()
	end
	return nil
end

-- Builds the model for a spec, and the direction the camera should look from.
local function buildModel(spec: Spec): (Model, Vector3, number)
	if spec.kind == "Creature" then
		local species = Creatures.Get(spec.id)
		local mutation: Types.MutationId = spec.mutation or "Normal"
		-- Previews are always shown at 1.0x so every species fills its icon.
		local built = if species then CreatureModel.Build(spec.id, species.baseWeight, mutation, false) else nil
		if built then
			-- Creatures face -Z: look from the front-left, slightly above.
			return built.model, Vector3.new(-0.9, 0.35, -1), 0
		end
		return fallbackModel(Color3.fromRGB(120, 140, 170), Vector3.new(2, 2, 4)), Vector3.new(-0.9, 0.35, -1), 0
	elseif spec.kind == "Rod" then
		local def = Rods.Get(spec.id)
		local color = if def then Rarities.Info[def.rarity].color else Color3.fromRGB(150, 108, 66)
		local model = assetClone("Rods", spec.id) or fallbackModel(color, Vector3.new(0.3, 0.3, 6))
		-- Rods lie along Z: view side-on and roll the camera so they sit on the diagonal.
		return model, Vector3.new(1, 0.15, 0.05), math.rad(38)
	end
	local def = Baits.Get(spec.id)
	local color = if def then Rarities.Info[def.rarity].color else Color3.fromRGB(200, 200, 200)
	local model = assetClone("Baits", spec.id) or fallbackModel(color, Vector3.new(1, 1, 1))
	return model, Vector3.new(-0.8, 0.6, -1), 0
end

local function ensureSpinLoop()
	if spinConnection then
		return
	end
	spinConnection = RunService.RenderStepped:Connect(function(dt: number)
		for _, spinner in spinners do
			spinner.angle += SPIN_SPEED * dt
			local turn = CFrame.new(spinner.center) * CFrame.Angles(0, spinner.angle, 0) * CFrame.new(-spinner.center)
			spinner.model:PivotTo(turn * spinner.origin)
		end
	end)
end

function ModelPreview.Create(spec: Spec): ViewportFrame
	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Ambient = Color3.fromRGB(190, 190, 200)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.6, -1, -0.5)

	local model, viewFrom, roll = buildModel(spec)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	model.Parent = viewport

	-- Frame the model: back the camera off far enough to fit its largest dimension.
	local boundsCFrame, boundsSize = model:GetBoundingBox()
	local center = boundsCFrame.Position
	local radius = boundsSize.Magnitude / 2
	local distance = radius * FRAME_PADDING / math.sin(math.rad(FIELD_OF_VIEW / 2))
	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.CFrame = CFrame.lookAt(center + viewFrom.Unit * distance, center) * CFrame.Angles(0, 0, roll)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local spinner: Spinner = { model = model, origin = model:GetPivot(), center = center, angle = 0 }
	known[viewport] = spinner
	viewport.Destroying:Connect(function()
		spinners[viewport] = nil
		known[viewport] = nil
	end)
	return viewport
end

-- Turns continuous rotation on or off for a preview made by Create.
function ModelPreview.SetSpin(viewport: ViewportFrame, enabled: boolean)
	local spinner = known[viewport]
	if not spinner then
		return
	end
	if enabled then
		spinners[viewport] = spinner
		ensureSpinLoop()
	else
		spinners[viewport] = nil
	end
end

return ModelPreview
