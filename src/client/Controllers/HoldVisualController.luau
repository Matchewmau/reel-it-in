--!strict
-- Draws the creature each player is carrying, for every player in the server.
--
-- ShowcaseService (server) replicates what is held through Player attributes;
-- this controller builds the real creature model at its real size (weight
-- drives scale, so a 4x fish really is huge), puts it in the character's hands
-- and makes it flop. Small catches are cradled in front of the chest; anything
-- longer than BIG_LENGTH is hoisted overhead. A fish that came straight off the
-- line leaps out of the water into the player's hands first.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Format = require(Shared.Util.Format)
local Creatures = require(Shared.Config.Creatures)
local Mutations = require(Shared.Config.Mutations)
local Rarities = require(Shared.Config.Rarities)

local CreatureModel = require(script.Parent.Parent.Visual.CreatureModel)
local Effects = require(script.Parent.Parent.Visual.Effects)
local FishingVisualController = require(script.Parent.FishingVisualController)

type Held = {
	seq: number,
	built: CreatureModel.Built,
	size: Vector3, -- model extents at its real scale
	startedAt: number,
	from: Vector3?, -- where it leapt from, if it was just caught
	arrived: boolean,
	phase: number,
}

local BIG_LENGTH = 5 -- studs: longer than this is carried overhead
local LEAP_TIME = 0.75 -- seconds for a fresh catch to fly from the water to the hands
local LEAP_ARC = 7 -- peak height of that leap, studs
local FLOP_TEMPO = 11 -- tail-beat speed while held
local FLOP_INTENSITY = 1.5 -- how hard it thrashes compared with swimming
local CARD_DISTANCE = 70
local CARD_SIZE = Vector2.new(5.6, 2.15) -- studs
local COLOSSAL_GOLD = Color3.fromRGB(255, 208, 72)
local CARD_GOLD_BORDER = Color3.fromRGB(214, 174, 92)
local MUTATION_IDS: { Types.MutationId } =
	{ "Normal", "Albino", "Golden", "Bioluminescent", "StormCharged", "VoidTouched" }

local HoldVisualController = {}

local held: { [Player]: Held } = {}
local container: Folder

local function toMutation(value: any): Types.MutationId
	for _, id: Types.MutationId in MUTATION_IDS do
		if id == value then
			return id
		end
	end
	return "Normal"
end

local function destroy(player: Player)
	local existing = held[player]
	if existing then
		existing.built.model:Destroy()
		held[player] = nil
	end
end

local function addCard(built: CreatureModel.Built, weight: number, mutation: Types.MutationId, size: Vector3)
	local info = Rarities.Info[built.species.rarity]
	local weightRatio = weight / built.species.baseWeight
	local isColossal = weightRatio >= Creatures.Weight.ColossalMinRatio

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HeldCard"
	billboard.Adornee = built.root
	billboard.Size = UDim2.fromScale(CARD_SIZE.X, CARD_SIZE.Y)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, size.Y / 2 + CARD_SIZE.Y / 2 + 0.45, 0)
	billboard.MaxDistance = CARD_DISTANCE
	billboard.LightInfluence = 0
	billboard.Parent = built.root

	local borderColor = if isColossal
		then COLOSSAL_GOLD
		elseif built.species.rarity == "Common" then CARD_GOLD_BORDER
		else info.color

	-- Crisp dark-navy rounded card (reference/HUD design.jpeg)
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.fromScale(0.5, 0.04)
	card.Size = UDim2.fromScale(0.96, 0.82)
	card.BackgroundColor3 = Color3.new(1, 1, 1)
	card.BackgroundTransparency = 0.06
	card.BorderSizePixel = 0
	card.ZIndex = 2
	card.Parent = billboard

	local cardGradient = Instance.new("UIGradient")
	cardGradient.Rotation = 90
	cardGradient.Color = ColorSequence.new(Color3.fromRGB(28, 38, 56), Color3.fromRGB(13, 19, 31))
	cardGradient.Parent = card

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.22, 0)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = borderColor
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card

	-- Subtle speech-bubble pointer notch centered below the card
	local notch = Instance.new("Frame")
	notch.Name = "Pointer"
	notch.AnchorPoint = Vector2.new(0.5, 0.5)
	notch.Position = UDim2.fromScale(0.5, 0.86)
	notch.Size = UDim2.fromScale(0.08, 0.2)
	notch.Rotation = 45
	notch.BackgroundColor3 = Color3.fromRGB(13, 19, 31)
	notch.BackgroundTransparency = 0.06
	notch.BorderSizePixel = 0
	notch.ZIndex = 1
	notch.Parent = billboard

	local notchStroke = Instance.new("UIStroke")
	notchStroke.Color = borderColor
	notchStroke.Thickness = 1.6
	notchStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	notchStroke.Parent = notch

	-- Sparkle accents matching HUD design.jpeg
	local sparkleRight = Instance.new("TextLabel")
	sparkleRight.Name = "SparkleRight"
	sparkleRight.BackgroundTransparency = 1
	sparkleRight.Position = UDim2.fromScale(0.87, 0.04)
	sparkleRight.Size = UDim2.fromScale(0.11, 0.42)
	sparkleRight.Font = Enum.Font.GothamBold
	sparkleRight.Text = "✦"
	sparkleRight.TextScaled = true
	sparkleRight.TextColor3 = Color3.fromRGB(255, 240, 178)
	sparkleRight.ZIndex = 4
	sparkleRight.Parent = card

	local sparkleLeft = Instance.new("TextLabel")
	sparkleLeft.Name = "SparkleLeft"
	sparkleLeft.BackgroundTransparency = 1
	sparkleLeft.Position = UDim2.fromScale(0.03, 0.14)
	sparkleLeft.Size = UDim2.fromScale(0.08, 0.3)
	sparkleLeft.Font = Enum.Font.GothamBold
	sparkleLeft.Text = "·"
	sparkleLeft.TextScaled = true
	sparkleLeft.TextColor3 = Color3.fromRGB(255, 244, 200)
	sparkleLeft.ZIndex = 4
	sparkleLeft.Parent = card

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "SpeciesName"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Position = UDim2.fromScale(0.06, 0.08)
	nameLabel.Size = UDim2.fromScale(0.88, 0.44)
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.Text = built.species.name
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = if isColossal then COLOSSAL_GOLD else Color3.fromRGB(255, 252, 244)
	nameLabel.TextStrokeColor3 = Color3.fromRGB(10, 14, 22)
	nameLabel.TextStrokeTransparency = 0.25
	nameLabel.ZIndex = 3
	nameLabel.Parent = card

	local detailParts = {
		`<font color="#{info.color:ToHex()}">[{built.species.rarity}]</font>  {Format.Weight(weight)}`,
	}
	if isColossal then
		table.insert(detailParts, `<font color="#{COLOSSAL_GOLD:ToHex()}">★ COLOSSAL</font>`)
	end
	if mutation ~= "Normal" then
		table.insert(detailParts, Mutations.Get(mutation).name)
	end

	local detailLabel = Instance.new("TextLabel")
	detailLabel.Name = "Details"
	detailLabel.BackgroundTransparency = 1
	detailLabel.Position = UDim2.fromScale(0.05, 0.54)
	detailLabel.Size = UDim2.fromScale(0.9, 0.36)
	detailLabel.Font = Enum.Font.GothamBold
	detailLabel.RichText = true
	detailLabel.Text = table.concat(detailParts, " · ")
	detailLabel.TextScaled = true
	detailLabel.TextColor3 = Color3.fromRGB(236, 240, 246)
	detailLabel.TextStrokeColor3 = Color3.fromRGB(10, 14, 22)
	detailLabel.TextStrokeTransparency = 0.3
	detailLabel.ZIndex = 3
	detailLabel.Parent = card
end

local function create(player: Player, seq: number, speciesId: string, weight: number, mutation: Types.MutationId): Held?
	local built = CreatureModel.Build(speciesId, weight, mutation, true)
	if not built then
		return nil
	end
	local size = built.model:GetExtentsSize()
	addCard(built, weight, mutation, size)

	local from: Vector3? = nil
	if player:GetAttribute("HeldFromCatch") == true then
		from = FishingVisualController.GetRecentCastPoint(player, 2)
		if from then
			Effects.Splash(from, 2.2)
		end
	end
	built.model.Parent = container
	return {
		seq = seq,
		built = built,
		size = size,
		startedAt = os.clock(),
		from = from,
		arrived = from == nil,
		phase = (player.UserId % 628) / 100,
	}
end

-- Raises both arms toward the fish. Runs after the Animator each frame, so it
-- overrides only these two joints and stops the moment the fish is put away.
local function poseArms(character: Model, overhead: boolean)
	local angle = if overhead then math.rad(165) else math.rad(80)
	for _, side in { "Right", "Left" } do
		local upperArm = character:FindFirstChild(side .. "UpperArm")
		local shoulder = upperArm and upperArm:FindFirstChild(side .. "Shoulder")
		-- Classic rigs join limbs with Motor6D; newer avatars use AnimationConstraint.
		-- Both take the same Transform.
		if shoulder and (shoulder:IsA("Motor6D") or shoulder:IsA("AnimationConstraint")) then
			(shoulder :: any).Transform = CFrame.Angles(angle, 0, 0)
		end
	end
end

local function update(player: Player, entry: Held, now: number)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not character or not root or not root:IsA("BasePart") then
		entry.built.model.Parent = nil
		return
	end
	if entry.built.model.Parent ~= container then
		entry.built.model.Parent = container
	end

	-- Carried sideways (the fish's length across the body), head to the player's left.
	local overhead = entry.built.length > BIG_LENGTH
	local carry
	if overhead then
		carry = root.CFrame * CFrame.new(0, 3.6 + entry.size.Y / 2, 0) * CFrame.Angles(0, math.rad(90), 0)
	else
		carry = root.CFrame
			* CFrame.new(0, 0.3, -(1.3 + entry.size.X / 2))
			* CFrame.Angles(0, math.rad(90), math.rad(8))
	end

	local from = entry.from
	local elapsed = now - entry.startedAt
	if from and not entry.arrived then
		if elapsed < LEAP_TIME then
			-- Fresh catch: arc out of the water, tumbling, into the hands.
			local t = elapsed / LEAP_TIME
			local eased = 1 - (1 - t) ^ 2
			local position = from:Lerp(carry.Position, eased) + Vector3.new(0, math.sin(t * math.pi) * LEAP_ARC, 0)
			entry.built.root.CFrame = CFrame.new(position) * carry.Rotation * CFrame.Angles(0, 0, t * math.pi * 2)
			CreatureModel.AnimateSwim(entry.built.joints, now * FLOP_TEMPO * 1.6, now, entry.phase, 2)
			return
		end
		entry.arrived = true
		Effects.Burst(carry.Position, Rarities.Info[entry.built.species.rarity].color, 1.2)
	end

	-- A little struggle so it reads as alive, not a prop.
	local wiggle = CFrame.Angles(0, math.sin(now * 5 + entry.phase) * 0.08, math.sin(now * 3.2 + entry.phase) * 0.06)
	entry.built.root.CFrame = carry * wiggle
	CreatureModel.AnimateSwim(entry.built.joints, now * FLOP_TEMPO + entry.phase, now, entry.phase, FLOP_INTENSITY)
	poseArms(character, overhead)
end

function HoldVisualController.Init()
	container = Instance.new("Folder")
	container.Name = "HeldCreatures"
	container.Parent = Workspace
end

function HoldVisualController.Start()
	Players.PlayerRemoving:Connect(destroy)

	-- PreSimulation: after the Animator, and where Motor6D.Transform writes are picked up.
	RunService.PreSimulation:Connect(function()
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			local speciesId = player:GetAttribute("HeldSpecies")
			local weight = player:GetAttribute("HeldWeight")
			local seq = player:GetAttribute("HeldSeq")
			if type(speciesId) ~= "string" or type(weight) ~= "number" or type(seq) ~= "number" then
				destroy(player)
			else
				local existing: Held? = held[player]
				if not existing or existing.seq ~= seq then
					destroy(player)
					existing = create(player, seq, speciesId, weight, toMutation(player:GetAttribute("HeldMutation")))
					if existing then
						held[player] = existing
					end
				end
				if existing then
					update(player, existing, now)
				end
			end
		end
	end)
end

return HoldVisualController
