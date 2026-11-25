--!strict
-- One place that turns a creature (species + weight + mutation) into a model.
-- Used by the pond, by fish carried in hand, by the catch animation and by UI
-- previews, so a creature looks identical everywhere it appears.
--
-- Weight is reflected in size: ModelScale = (weight / baseWeight) ^ 0.65 (GDD §4).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Creatures = require(Shared.Config.Creatures)
local Mutations = require(Shared.Config.Mutations)
local Rarities = require(Shared.Config.Rarities)

local PlaceholderRig = require(script.Parent.PlaceholderRig)

export type Built = {
	model: Model,
	root: BasePart,
	joints: { [string]: Motor6D },
	species: Creatures.Species,
	scale: number,
	length: number, -- nose-to-tail length in studs at this scale
}

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local CreatureModel = {}

local function findTemplate(species: Creatures.Species): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local creatures = assets and assets:FindFirstChild("Creatures")
	local biome = creatures and creatures:FindFirstChild(species.biome)
	local template = biome and biome:FindFirstChild(species.id)
	if template and template:IsA("Model") and template.PrimaryPart then
		return template
	end
	return nil
end

-- The rig "bone" a part belongs to: the first-level child of the model it sits under.
local function boneNameOf(model: Model, part: BasePart): string
	local current: Instance = part
	while current.Parent and current.Parent ~= model do
		current = current.Parent
	end
	return current.Name
end

function CreatureModel.AddSparkles(attachment: Attachment, color: Color3, rate: number, size: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Sparkles"
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.8
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(0.6, 1.2)
	emitter.Speed = NumberRange.new(0.5, 1.5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = attachment
end

-- Recolours a rig for its mutation. `effects` adds the light and particle trail
-- (skipped for UI previews, where ViewportFrames cannot draw them anyway).
local function applyMutation(model: Model, root: BasePart, mutation: Types.MutationId, scale: number, effects: boolean)
	local visual = Mutations.Get(mutation).visual
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local bone = boneNameOf(model, descendant)
			local isGlowPart = string.find(bone, "Fin") ~= nil or bone == "Lure"
			if visual.finNeon and isGlowPart then
				descendant.Material = Enum.Material.Neon
				descendant.Color = visual.finNeon
			elseif descendant.Material ~= Enum.Material.Neon then
				-- Authored glow details (eyes, lure bulbs) keep their own colour.
				if visual.tint and visual.tintStrength > 0 then
					descendant.Color = descendant.Color:Lerp(visual.tint, visual.tintStrength)
				end
				if visual.material then
					descendant.Material = visual.material
				end
			end
		end
	end
	if not effects then
		return
	end

	if visual.light then
		local light = Instance.new("PointLight")
		light.Name = "MutationLight"
		light.Color = visual.light
		light.Range = 8 * scale
		light.Brightness = 1.5
		light.Parent = root
	end
	local aura = root:FindFirstChild("AuraAttachment")
	if visual.particle and aura and aura:IsA("Attachment") then
		CreatureModel.AddSparkles(aura, visual.particle, 8, 0.5 * scale)
	end
end

-- Builds an unparented, non-colliding creature model with an anchored RootPart.
-- Move it by setting `root.CFrame`; animate it with CreatureModel.AnimateSwim.
function CreatureModel.Build(speciesId: string, weight: number, mutation: Types.MutationId, effects: boolean): Built?
	local species = Creatures.Get(speciesId)
	if not species then
		return nil
	end
	local scale = Creatures.ModelScale(weight / species.baseWeight)

	local template = findTemplate(species)
	local model = if template then template:Clone() else PlaceholderRig.Build(species)
	local root = model.PrimaryPart
	if not root then
		model:Destroy()
		return nil
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Anchored = descendant == root
		end
	end
	model:ScaleTo(scale)
	applyMutation(model, root, mutation, scale, effects)

	local info = Rarities.Info[species.rarity]
	local aura = root:FindFirstChild("AuraAttachment")
	if effects and info.hasAura and aura and aura:IsA("Attachment") then
		CreatureModel.AddSparkles(aura, info.color, 4, 0.35 * scale)
	end

	local joints: { [string]: Motor6D } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			joints[descendant.Name] = descendant
		end
	end

	return {
		model = model,
		root = root,
		joints = joints,
		species = species,
		scale = scale,
		length = species.length * scale,
	}
end

local function setJoint(joints: { [string]: Motor6D }, name: string, transform: CFrame)
	local motor = joints[name]
	if motor then
		motor.Transform = transform
	end
end

-- Procedural sine-wave swim through the Motor6D chain (head -> tail lag).
-- `beat` drives the tail (radians), `now` drives slow idle motions, `intensity`
-- scales the amplitude (1 = cruising, higher = thrashing on the line / in hand).
-- Call during RunService.PreSimulation, where Motor6D.Transform writes are picked up.
function CreatureModel.AnimateSwim(
	joints: { [string]: Motor6D },
	beat: number,
	now: number,
	phase: number,
	intensity: number
)
	local k = intensity
	setJoint(joints, "Body", CFrame.Angles(0, math.sin(beat + 1.2) * 0.06 * k, 0))
	setJoint(joints, "Head", CFrame.Angles(0, math.sin(beat + 2.0) * -0.08 * k, 0))
	setJoint(joints, "Tail", CFrame.Angles(0, math.sin(beat) * 0.32 * k, 0))
	-- Extra tail segments (serpentine creatures) carry the wave further back.
	setJoint(joints, "Tail2", CFrame.Angles(0, math.sin(beat - 0.7) * 0.34 * k, 0))
	setJoint(joints, "Tail3", CFrame.Angles(0, math.sin(beat - 1.4) * 0.36 * k, 0))
	setJoint(joints, "TailFin", CFrame.Angles(0, math.sin(beat - 0.9) * 0.42 * k, 0))
	local flap = math.sin(beat * 0.5) * 0.28 * k
	setJoint(joints, "LeftFin", CFrame.Angles(0, 0, flap))
	setJoint(joints, "RightFin", CFrame.Angles(0, 0, -flap))
	setJoint(joints, "DorsalFin", CFrame.Angles(0, 0, math.sin(beat * 0.5 + 0.6) * 0.05 * k))
	setJoint(joints, "Jaw", CFrame.Angles((math.sin(now * 0.9 + phase) * 0.5 + 0.5) * -0.22, 0, 0))
	setJoint(joints, "Lure", CFrame.Angles(math.sin(now * 1.4 + phase) * 0.12, 0, math.sin(beat * 0.3) * 0.1))
end

return CreatureModel
