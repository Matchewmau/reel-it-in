--!strict
-- Local environmental weather visuals: Lighting / Atmosphere / Clouds tweens,
-- camera-following rain particle streaks, and periodic Storm lightning flashes.
--
-- Driven solely by Workspace:GetAttribute("Weather") (set by WeatherService).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Weather = require(Shared.Config.Weather)

type WeatherId = Types.WeatherId

local WeatherVisualController = {}

local cfg = Weather.VisualConfig
local rng = Random.new()

local currentWeather: WeatherId = "Clear"
local stormGeneration = 0

local atmosphere: Atmosphere? = nil
local clouds: Clouds? = nil
local rainPart: Part? = nil
local rainEmitter: ParticleEmitter? = nil

local activeTweens: { Tween } = {}
local lightningTween: Tween? = nil

local function parseWeather(value: any): WeatherId
	if value == "Rain" then
		return "Rain"
	elseif value == "Storm" then
		return "Storm"
	end
	return "Clear"
end

local function cancelTweens(list: { Tween })
	for _, tween in list do
		tween:Cancel()
	end
	table.clear(list)
end

local function ensureAtmosphere(): Atmosphere
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	if existing then
		return existing
	end
	local created = Instance.new("Atmosphere")
	created.Name = "WeatherAtmosphere"
	created.Parent = Lighting
	return created
end

local function ensureClouds(): Clouds?
	local terrain = Workspace.Terrain
	if not terrain then
		return nil
	end
	local existing = terrain:FindFirstChildOfClass("Clouds")
	if existing then
		return existing
	end
	local ok, created = pcall(function()
		local c = Instance.new("Clouds")
		c.Parent = terrain
		return c
	end)
	if ok and created then
		return created :: Clouds
	end
	return nil
end

local function ensureRainEmitter()
	if rainPart and rainPart.Parent ~= nil and rainEmitter then
		return
	end
	local part = Instance.new("Part")
	part.Name = "RainEmitterPart"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(cfg.EmitterSizeX, 1, cfg.EmitterSizeZ)
	part.CFrame = CFrame.new(0, cfg.EmitterHeight, 0)
	part.Parent = Workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RainStreaks"
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Size = NumberSequence.new(cfg.RainParticleSize)
	emitter.Squash = NumberSequence.new(cfg.RainParticleSquash)
	emitter.Color = ColorSequence.new(cfg.RainColor)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.75),
		NumberSequenceKeypoint.new(0.2, 0.35),
		NumberSequenceKeypoint.new(0.85, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(cfg.RainLifetimeMin, cfg.RainLifetimeMax)
	emitter.LightEmission = cfg.RainLightEmission
	emitter.Rate = 0
	emitter.Parent = part

	rainPart = part
	rainEmitter = emitter
end

local function spawnLightningBolt()
	local camera = Workspace.CurrentCamera
	local originXZ = if camera then Vector3.new(camera.CFrame.Position.X, 0, camera.CFrame.Position.Z) else Vector3.zero
	local angle = rng:NextNumber(0, math.pi * 2)
	local dist = rng:NextNumber(cfg.LightningBoltDistanceMin, cfg.LightningBoltDistanceMax)
	local base = originXZ + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

	local folder = Instance.new("Folder")
	folder.Name = "StormLightningBolt"
	folder.Parent = Workspace

	local segments = cfg.LightningBoltSegments
	local prev = Vector3.new(base.X, cfg.LightningBoltTopY, base.Z)
	local parts: { Part } = {}
	for i = 1, segments do
		local t = i / segments
		local y = cfg.LightningBoltTopY + (cfg.LightningBoltBottomY - cfg.LightningBoltTopY) * t
		local jitterX = if i < segments then rng:NextNumber(-cfg.LightningBoltJitter, cfg.LightningBoltJitter) else 0
		local jitterZ = if i < segments then rng:NextNumber(-cfg.LightningBoltJitter, cfg.LightningBoltJitter) else 0
		local nextPos = Vector3.new(base.X + jitterX, y, base.Z + jitterZ)

		local delta = nextPos - prev
		local length = delta.Magnitude
		if length > 0.1 then
			local seg = Instance.new("Part")
			seg.Name = "BoltSegment"
			seg.Anchored = true
			seg.CanCollide = false
			seg.CanQuery = false
			seg.CanTouch = false
			seg.CastShadow = false
			seg.Material = Enum.Material.Neon
			seg.Color = cfg.LightningBoltColor
			seg.Size = Vector3.new(cfg.LightningBoltThickness, cfg.LightningBoltThickness, length)
			seg.CFrame = CFrame.lookAt((prev + nextPos) * 0.5, nextPos)
			seg.Parent = folder
			table.insert(parts, seg)
		end
		prev = nextPos
	end

	local fadeInfo = TweenInfo.new(cfg.LightningBoltFadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, seg in parts do
		TweenService:Create(seg, fadeInfo, { Transparency = 1 }):Play()
	end
	task.delay(cfg.LightningBoltFadeSeconds + 0.05, function()
		folder:Destroy()
	end)
end

local function triggerLightningFlash()
	if currentWeather ~= "Storm" then
		return
	end
	if lightningTween then
		lightningTween:Cancel()
		lightningTween = nil
	end
	local stormVisual = Weather.Get("Storm").visual
	Lighting.Brightness = cfg.LightningFlashBrightness
	local tween = TweenService:Create(
		Lighting,
		TweenInfo.new(cfg.LightningFadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Brightness = stormVisual.brightness }
	)
	lightningTween = tween
	tween:Play()
	spawnLightningBolt()
end

local function startStormLoop(generation: number)
	task.spawn(function()
		while stormGeneration == generation and currentWeather == "Storm" do
			local delaySeconds = rng:NextNumber(cfg.LightningMinInterval, cfg.LightningMaxInterval)
			task.wait(delaySeconds)
			if stormGeneration ~= generation or currentWeather ~= "Storm" then
				break
			end
			triggerLightningFlash()
		end
	end)
end

local function applyWeather(id: WeatherId, instant: boolean)
	currentWeather = id
	stormGeneration += 1
	local generation = stormGeneration

	if lightningTween then
		lightningTween:Cancel()
		lightningTween = nil
	end
	cancelTweens(activeTweens)

	local visual = Weather.Get(id).visual
	local duration = if instant then 0 else cfg.TransitionSeconds

	if duration <= 0 then
		Lighting.Brightness = visual.brightness
		Lighting.OutdoorAmbient = visual.outdoorAmbient
		Lighting.Ambient = visual.ambient
		Lighting.FogColor = visual.fogColor
		Lighting.FogStart = visual.fogStart
		Lighting.FogEnd = visual.fogEnd
	else
		local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		local lightingTween = TweenService:Create(Lighting, info, {
			Brightness = visual.brightness,
			OutdoorAmbient = visual.outdoorAmbient,
			Ambient = visual.ambient,
			FogColor = visual.fogColor,
			FogStart = visual.fogStart,
			FogEnd = visual.fogEnd,
		})
		table.insert(activeTweens, lightingTween)
		lightingTween:Play()
	end

	local atmo = atmosphere
	if atmo then
		if duration <= 0 then
			atmo.Density = visual.atmosphereDensity
			atmo.Offset = visual.atmosphereOffset
			atmo.Color = visual.atmosphereColor
			atmo.Decay = visual.atmosphereDecay
			atmo.Haze = visual.atmosphereHaze
		else
			local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			local atmoTween = TweenService:Create(atmo, info, {
				Density = visual.atmosphereDensity,
				Offset = visual.atmosphereOffset,
				Color = visual.atmosphereColor,
				Decay = visual.atmosphereDecay,
				Haze = visual.atmosphereHaze,
			})
			table.insert(activeTweens, atmoTween)
			atmoTween:Play()
		end
	end

	local cloudObj = clouds
	if cloudObj then
		if duration <= 0 then
			cloudObj.Cover = visual.cloudCover
			cloudObj.Density = visual.cloudDensity
			cloudObj.Color = visual.cloudColor
		else
			local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			local cloudTween = TweenService:Create(cloudObj, info, {
				Cover = visual.cloudCover,
				Density = visual.cloudDensity,
				Color = visual.cloudColor,
			})
			table.insert(activeTweens, cloudTween)
			cloudTween:Play()
		end
	end

	local emitter = rainEmitter
	if emitter then
		emitter.Rate = visual.rainRate
		emitter.Speed = NumberRange.new(visual.rainSpeedMin, visual.rainSpeedMax)
		emitter.Acceleration = Vector3.new(visual.rainWindX, 0, 0)
	end

	if id == "Storm" then
		startStormLoop(generation)
	end
end

local function updateRainPosition()
	local part = rainPart
	local emitter = rainEmitter
	if not part or not emitter or emitter.Rate <= 0 then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local pos = camera.CFrame.Position
	part.CFrame = CFrame.new(pos.X, pos.Y + cfg.EmitterHeight, pos.Z)
end

function WeatherVisualController.Init()
	atmosphere = ensureAtmosphere()
	clouds = ensureClouds()
	ensureRainEmitter()
end

function WeatherVisualController.Start()
	local initial: WeatherId = parseWeather(Workspace:GetAttribute("Weather"))
	applyWeather(initial, true)

	Workspace:GetAttributeChangedSignal("Weather"):Connect(function()
		local nextWeather: WeatherId = parseWeather(Workspace:GetAttribute("Weather"))
		if nextWeather ~= currentWeather then
			applyWeather(nextWeather, false)
		end
	end)

	RunService.PreRender:Connect(updateRainPosition)
end

return WeatherVisualController
