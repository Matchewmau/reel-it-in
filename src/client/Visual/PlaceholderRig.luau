--!strict
-- Builds a blocky stand-in creature that follows the VoxelMorph rig standard
-- (GDD §6) for any species that has no authored model yet under
-- ReplicatedStorage/Assets/Creatures/<Biome>/<SpeciesId>.
--
-- Because it uses the same part and Motor6D names as authored rigs, the swim
-- animator and mutation VFX treat both identically.
--
-- Rig convention: the creature faces -Z. Every Motor6D is named after its
-- Part1 and its C0/C1 put the pivot at the joint, not the part centre.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Creatures = require(Shared.Config.Creatures)

local PlaceholderRig = {}

local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Anchored = false
	part.Parent = parent
	return part
end

local function joint(part0: BasePart, part1: BasePart, pivot: Vector3): Motor6D
	local motor = Instance.new("Motor6D")
	motor.Name = part1.Name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = part0.CFrame:ToObjectSpace(CFrame.new(pivot))
	motor.C1 = part1.CFrame:ToObjectSpace(CFrame.new(pivot))
	motor.Parent = part0
	return motor
end

local function weldDetail(bone: BasePart, name: string, size: Vector3, position: Vector3, color: Color3): Part
	local detail = makePart(name, size, position, color, bone)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = bone
	weld.Part1 = detail
	weld.Parent = detail
	return detail
end

function PlaceholderRig.Build(species: Creatures.Species): Model
	local L = species.length
	local palette = species.palette

	local model = Instance.new("Model")
	model.Name = species.id
	model:SetAttribute("SpeciesId", species.id)
	model:SetAttribute("Placeholder", true)

	local bodyLen = 0.5 * L
	local bodySize = Vector3.new(0.26 * L, 0.32 * L, bodyLen)
	local headLen = 0.22 * L
	local tailLen = 0.18 * L
	local finLen = 0.14 * L

	local root = makePart("RootPart", Vector3.new(0.3 * L, 0.36 * L, L), Vector3.zero, palette.primary, model)
	root.Transparency = 1
	root.Anchored = true
	model.PrimaryPart = root

	local aura = Instance.new("Attachment")
	aura.Name = "AuraAttachment"
	aura.Parent = root

	local body = makePart("Body", bodySize, Vector3.zero, palette.primary, model)
	weldDetail(
		body,
		"Belly",
		Vector3.new(bodySize.X * 0.9, bodySize.Y * 0.3, bodyLen * 0.9),
		Vector3.new(0, -bodySize.Y * 0.38, 0),
		palette.secondary
	)

	local headZ = -(bodyLen / 2 + headLen / 2)
	local head =
		makePart("Head", Vector3.new(0.24 * L, 0.28 * L, headLen), Vector3.new(0, 0, headZ), palette.primary, model)
	local eyeSize = math.max(0.04 * L, 0.12)
	for _, side in { -1, 1 } do
		weldDetail(
			head,
			"Eye",
			Vector3.new(eyeSize * 0.5, eyeSize, eyeSize),
			Vector3.new(side * 0.12 * L, 0.05 * L, headZ - headLen * 0.15),
			palette.accent
		)
	end

	local tailZ = bodyLen / 2 + tailLen / 2
	local tail =
		makePart("Tail", Vector3.new(0.16 * L, 0.2 * L, tailLen), Vector3.new(0, 0, tailZ), palette.secondary, model)
	local tailFinZ = bodyLen / 2 + tailLen + finLen / 2
	local tailFin =
		makePart("TailFin", Vector3.new(0.05 * L, 0.36 * L, finLen), Vector3.new(0, 0, tailFinZ), palette.accent, model)

	local finSize = Vector3.new(0.2 * L, 0.04 * L, 0.16 * L)
	local finX = bodySize.X / 2 + finSize.X / 2
	local leftFin = makePart("LeftFin", finSize, Vector3.new(-finX, -0.08 * L, -0.08 * L), palette.accent, model)
	local rightFin = makePart("RightFin", finSize, Vector3.new(finX, -0.08 * L, -0.08 * L), palette.accent, model)
	local dorsal = makePart(
		"DorsalFin",
		Vector3.new(0.05 * L, 0.14 * L, 0.24 * L),
		Vector3.new(0, bodySize.Y / 2 + 0.07 * L, 0.02 * L),
		palette.accent,
		model
	)

	joint(root, body, Vector3.zero)
	joint(body, head, Vector3.new(0, 0, -bodyLen / 2))
	joint(body, tail, Vector3.new(0, 0, bodyLen / 2))
	joint(tail, tailFin, Vector3.new(0, 0, bodyLen / 2 + tailLen))
	joint(body, leftFin, Vector3.new(-bodySize.X / 2, -0.08 * L, -0.08 * L))
	joint(body, rightFin, Vector3.new(bodySize.X / 2, -0.08 * L, -0.08 * L))
	joint(body, dorsal, Vector3.new(0, bodySize.Y / 2, 0.02 * L))

	return model
end

return PlaceholderRig
