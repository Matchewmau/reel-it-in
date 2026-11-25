--!strict
-- Small blocky world effects (splashes, sparkle bursts). Everything is a few
-- local, anchored, non-colliding cubes tweened and then destroyed: cheap, and
-- in keeping with the voxel look. Purely cosmetic and client-side.

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Effects = {}

local FOLDER_NAME = "Effects"
local WATER_COLORS = { Color3.fromRGB(236, 248, 255), Color3.fromRGB(150, 214, 255), Color3.fromRGB(86, 190, 236) }

local rng = Random.new()

local function folder(): Instance
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Workspace
	return created
end

local function cube(size: number, color: Color3, position: Vector3, neon: boolean): Part
	local part = Instance.new("Part")
	part.Size = Vector3.one * size
	part.Color = color
	part.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.new(position) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0)
	part.Parent = folder()
	return part
end

-- Tweens a part and destroys it when the tween ends.
local function fling(part: Part, info: TweenInfo, goal: { [string]: any })
	local tween = TweenService:Create(part, info, goal)
	tween.Completed:Once(function()
		part:Destroy()
	end)
	tween:Play()
end

-- Droplets thrown up and outward, plus a ring spreading across the surface.
-- `scale` 1 suits a bobber; use 2-3 for a big fish breaking the surface.
function Effects.Splash(position: Vector3, scale: number)
	local drops = math.clamp(math.floor(6 + scale * 4), 6, 18)
	for _ = 1, drops do
		local angle = rng:NextNumber(0, math.pi * 2)
		local reach = rng:NextNumber(1, 3) * scale
		local height = rng:NextNumber(1.5, 4) * scale
		local drop =
			cube(rng:NextNumber(0.25, 0.5) * scale, WATER_COLORS[rng:NextInteger(1, #WATER_COLORS)], position, false)
		local peak = position + Vector3.new(math.cos(angle) * reach * 0.6, height, math.sin(angle) * reach * 0.6)
		local land = position + Vector3.new(math.cos(angle) * reach, -0.3, math.sin(angle) * reach)
		local up = TweenService:Create(drop, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(peak),
		})
		up.Completed:Once(function()
			fling(drop, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				CFrame = CFrame.new(land),
				Transparency = 1,
				Size = Vector3.one * 0.1,
			})
		end)
		up:Play()
	end

	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.15, 1.2 * scale, 1.2 * scale)
	ring.CFrame = CFrame.new(position + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = WATER_COLORS[1]
	ring.Material = Enum.Material.SmoothPlastic
	ring.Transparency = 0.35
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Parent = folder()
	fling(ring, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, 6 * scale, 6 * scale),
		Transparency = 1,
	})
end

-- Glowing cubes bursting outward + a fast shockwave ring: catches, rare reveals, blessings.
function Effects.Burst(position: Vector3, color: Color3, scale: number)
	local count = math.clamp(math.floor(8 + scale * 4), 8, 20)
	for _ = 1, count do
		local direction = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.2, 1), rng:NextNumber(-1, 1))
		if direction.Magnitude < 0.05 then
			direction = Vector3.yAxis
		end
		local spark = cube(rng:NextNumber(0.2, 0.45) * scale, color, position, true)
		fling(spark, TweenInfo.new(rng:NextNumber(0.45, 0.8), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(position + direction.Unit * rng:NextNumber(2, 5) * scale),
			Transparency = 1,
			Size = Vector3.one * 0.08,
		})
	end

	local ring = Instance.new("Part")
	ring.Name = "BurstRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.14, 0.9 * scale, 0.9 * scale)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = color
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.25
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Parent = folder()
	fling(ring, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.05, 6.2 * scale, 6.2 * scale),
		Transparency = 1,
	})
end

-- Lightweight single expanding translucent cylinder ring on the water surface
-- (no flying cube parts, cheap for ambient rain/pond ripples).
function Effects.Ripple(position: Vector3, scale: number, color: Color3?)
	local ring = Instance.new("Part")
	ring.Name = "Ripple"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.08, 0.55 * scale, 0.55 * scale)
	ring.CFrame = CFrame.new(position + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = color or WATER_COLORS[1]
	ring.Material = Enum.Material.SmoothPlastic
	ring.Transparency = 0.45
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Parent = folder()
	fling(ring, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.04, 3.4 * scale, 3.4 * scale),
		Transparency = 1,
	})
end

return Effects
