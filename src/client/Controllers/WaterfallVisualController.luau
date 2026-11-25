--!strict
-- Client-side waterfall and abyss environmental particle VFX and pool ripples.
--
-- Watches Workspace for Map and attaches cosmetic ParticleEmitters to proxy
-- BaseParts in Workspace.WaterfallVFX (never mutating the map parts directly).
--
-- Visual Targets:
--   Freshwater "TheFalls":
--     - Cascade parts: bright white/sky-cyan downward water streaks.
--     - Foam parts: billowing white-aqua mist/spray.
--   Saltwater "Abyss":
--     - Waterfall parts: dramatic deep-teal/bioluminescent cyan streaks.
--     - Foam parts: misty cyan-white plunge spray.
--     - Glow part: subtle slow-rising bioluminescent cyan/violet mist motes.
--
-- Also runs a lightweight 0.45s background loop spawning ambient surface
-- ripples (Effects.Ripple) on plunge pool foam bases within 260 studs.

local Workspace = game:GetService("Workspace")

local Effects = require(script.Parent.Parent.Visual.Effects)

type FoamTarget = {
	part: BasePart,
	scaleMin: number,
	scaleMax: number,
	color: Color3,
}

local MAP_NAME = "Map"
local VFX_FOLDER_NAME = "WaterfallVFX"

local RIPPLE_INTERVAL = 0.45 -- seconds between ripple checks
local RIPPLE_MAX_DISTANCE = 260 -- studs from camera
local RESCAN_DELAY = 0.15 -- seconds debounce for map descendant changes

local COLOR_FRESH_RIPPLE = Color3.fromRGB(220, 245, 255)
local COLOR_ABYSS_RIPPLE = Color3.fromRGB(90, 225, 240)

local WaterfallVisualController = {}

local rng = Random.new()
local vfxFolder: Folder? = nil
local boundMap: Instance? = nil
local mapConnections: { RBXScriptConnection } = {}
local foamTargets: { FoamTarget } = {}

local rescanWaiting = false

-- Hierarchy & Proxy Part Helpers --------------------------------------------------------

local function ensureVfxFolder(): Folder
	local existing = Workspace:FindFirstChild(VFX_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = VFX_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function clearVFX()
	if vfxFolder then
		vfxFolder:ClearAllChildren()
	end
	table.clear(foamTargets)
end

local function createProxyPart(target: BasePart, name: string): Part
	local folder = if vfxFolder then vfxFolder else ensureVfxFolder()
	local part = Instance.new("Part")
	part.Name = name
	part.Size = target.Size
	part.CFrame = target.CFrame
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = folder
	return part
end

-- Particle Emitter Factories ------------------------------------------------------------

-- Freshwater TheFalls: downward-streaming bright white/sky-cyan water streaks.
local function attachFallsCascadeEmitter(proxy: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "CascadeStreaks"
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Squash = NumberSequence.new(1.2)
	emitter.Rate = 45
	emitter.Speed = NumberRange.new(16, 26)
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 240, 255)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(0.8, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0.8),
	})
	emitter.LightEmission = 0.3
	emitter.LightInfluence = 0.4
	emitter.Parent = proxy
	return emitter
end

-- Freshwater TheFalls: billowing translucent white-aqua mist/spray.
local function attachFallsFoamEmitter(proxy: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "FoamMist"
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.Rate = 28
	emitter.Speed = NumberRange.new(3, 7)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.8),
		NumberSequenceKeypoint.new(1, 4.2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.7, 1.3)
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(250, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(195, 242, 250)),
	})
	emitter.LightEmission = 0.2
	emitter.LightInfluence = 0.5
	emitter.Parent = proxy
	return emitter
end

-- Saltwater Abyss: dramatic deep-teal / bioluminescent-cyan cascading streaks.
local function attachAbyssWaterfallEmitter(proxy: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "AbyssWaterfallStreaks"
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Squash = NumberSequence.new(1.2)
	emitter.Rate = 40
	emitter.Speed = NumberRange.new(20, 32)
	emitter.Lifetime = NumberRange.new(0.8, 1.3)
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 250, 245)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(18, 140, 185)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.8, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1.1),
	})
	emitter.LightEmission = 0.5
	emitter.LightInfluence = 0.2
	emitter.Parent = proxy
	return emitter
end

-- Saltwater Abyss: misty cyan-white plunge spray.
local function attachAbyssFoamEmitter(proxy: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "AbyssFoamSpray"
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(50, 50)
	emitter.Rate = 24
	emitter.Speed = NumberRange.new(4, 9)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.0),
		NumberSequenceKeypoint.new(1, 4.8),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(225, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 220, 235)),
	})
	emitter.LightEmission = 0.3
	emitter.LightInfluence = 0.4
	emitter.Parent = proxy
	return emitter
end

-- Saltwater Abyss Glow: subtle slow-rising bioluminescent deep-cyan/violet abyssal mist motes.
local function attachAbyssGlowEmitter(proxy: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "AbyssalMistMotes"
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.Rate = 16
	emitter.Speed = NumberRange.new(2, 5)
	emitter.Lifetime = NumberRange.new(3, 5)
	emitter.LightEmission = 0.8
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 210, 240)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 60, 230)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.5),
		NumberSequenceKeypoint.new(0.8, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.5),
		NumberSequenceKeypoint.new(0.5, 3.2),
		NumberSequenceKeypoint.new(1, 4.5),
	})
	emitter.Parent = proxy
	return emitter
end

-- Map Scanning & Binding ----------------------------------------------------------------

local function scanMap(map: Instance)
	clearVFX()

	-- Freshwater TheFalls (Workspace.Map.Cliffs.TheFalls)
	local theFalls: Instance? = nil
	local cliffs = map:FindFirstChild("Cliffs")
	if cliffs then
		theFalls = cliffs:FindFirstChild("TheFalls")
	end
	if not theFalls then
		theFalls = map:FindFirstChild("TheFalls")
	end

	if theFalls then
		local children: { Instance } = theFalls:GetChildren()
		for _, child in children do
			if child:IsA("BasePart") then
				if child.Name == "Cascade" then
					local proxy = createProxyPart(child, "TheFalls_CascadeVFX")
					attachFallsCascadeEmitter(proxy)
				elseif child.Name == "Foam" then
					local proxy = createProxyPart(child, "TheFalls_FoamVFX")
					attachFallsFoamEmitter(proxy)
					table.insert(foamTargets, {
						part = child,
						scaleMin = 1.4,
						scaleMax = 2.4,
						color = COLOR_FRESH_RIPPLE,
					})
				end
			end
		end
	end

	-- Saltwater Abyss (Workspace.Map.Abyss)
	local abyss = map:FindFirstChild("Abyss")
	if abyss then
		local children: { Instance } = abyss:GetChildren()
		for _, child in children do
			if child:IsA("BasePart") then
				if child.Name == "Waterfall" then
					local proxy = createProxyPart(child, "Abyss_WaterfallVFX")
					attachAbyssWaterfallEmitter(proxy)
				elseif child.Name == "Foam" then
					local proxy = createProxyPart(child, "Abyss_FoamVFX")
					attachAbyssFoamEmitter(proxy)
					table.insert(foamTargets, {
						part = child,
						scaleMin = 1.8,
						scaleMax = 2.8,
						color = COLOR_ABYSS_RIPPLE,
					})
				elseif child.Name == "Glow" then
					local proxy = createProxyPart(child, "Abyss_GlowVFX")
					attachAbyssGlowEmitter(proxy)
				end
			end
		end
	end
end

local function scheduleRescan()
	if rescanWaiting then
		return
	end
	rescanWaiting = true
	task.delay(RESCAN_DELAY, function()
		rescanWaiting = false
		if boundMap and boundMap.Parent ~= nil then
			scanMap(boundMap)
		end
	end)
end

local function refreshBinding()
	local map = Workspace:FindFirstChild(MAP_NAME)
	if map ~= boundMap then
		disconnectAll(mapConnections)
		boundMap = map
		if map then
			table.insert(mapConnections, map.ChildAdded:Connect(scheduleRescan))
			table.insert(mapConnections, map.ChildRemoved:Connect(scheduleRescan))
			table.insert(mapConnections, map.DescendantAdded:Connect(scheduleRescan))
			table.insert(mapConnections, map.DescendantRemoving:Connect(scheduleRescan))
			scanMap(map)
		else
			clearVFX()
		end
	end
end

-- Plunge Pool Surface Ripples -----------------------------------------------------------

local function startRippleLoop()
	task.spawn(function()
		while true do
			task.wait(RIPPLE_INTERVAL)
			local camera = Workspace.CurrentCamera
			if not camera or #foamTargets == 0 then
				continue
			end
			local cameraPosition = camera.CFrame.Position
			for _, foam in foamTargets do
				if foam.part.Parent ~= nil then
					local dist = (foam.part.Position - cameraPosition).Magnitude
					if dist <= RIPPLE_MAX_DISTANCE then
						-- Occasional ripple chance per interval
						if rng:NextNumber() < 0.65 then
							local xOffset = rng:NextNumber(-0.35, 0.35) * foam.part.Size.X
							local zOffset = rng:NextNumber(-0.35, 0.35) * foam.part.Size.Z
							local localPos = Vector3.new(xOffset, foam.part.Size.Y * 0.5, zOffset)
							local worldPos = foam.part.CFrame:PointToWorldSpace(localPos)
							local scale = rng:NextNumber(foam.scaleMin, foam.scaleMax)
							Effects.Ripple(worldPos, scale, foam.color)
						end
					end
				end
			end
		end
	end)
end

-- Lifecycle -----------------------------------------------------------------------------

function WaterfallVisualController.Init()
	vfxFolder = ensureVfxFolder()
end

function WaterfallVisualController.Start()
	Workspace.ChildAdded:Connect(refreshBinding)
	Workspace.ChildRemoved:Connect(refreshBinding)
	refreshBinding()

	startRippleLoop()
end

return WaterfallVisualController
