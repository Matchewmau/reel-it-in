--!strict
-- Server weather + day/night cycle tunables. Weather gates the Storm-Charged
-- mutation and night gates Bioluminescent (see Mutations.luau).

local Types = require(script.Parent.Parent.Types)

type WeatherId = Types.WeatherId

export type WeatherVisual = {
	brightness: number,
	outdoorAmbient: Color3,
	ambient: Color3,
	fogColor: Color3,
	fogStart: number,
	fogEnd: number,
	atmosphereDensity: number,
	atmosphereOffset: number,
	atmosphereColor: Color3,
	atmosphereDecay: Color3,
	atmosphereHaze: number,
	cloudCover: number,
	cloudDensity: number,
	cloudColor: Color3,
	rainRate: number,
	rainSpeedMin: number,
	rainSpeedMax: number,
	rainWindX: number,
}

export type WeatherDef = {
	id: WeatherId,
	name: string,
	weight: number, -- selection weight
	minDuration: number, -- seconds
	maxDuration: number,
	rarePlusBonus: number, -- additive bonus to Rare+ hook weights while active
	mutationMultiplier: number, -- multiplier applied to non-weather mutation chances
	hudNote: string?,
	visual: WeatherVisual,
}

local Weather = {}

Weather.DayLengthSeconds = 720 -- one full in-game day
Weather.StartClockTime = 9
Weather.NightStart = 18.5
Weather.NightEnd = 5.5

-- Client environmental effect tunables (used by WeatherVisualController).
Weather.VisualConfig = {
	TransitionSeconds = 3.5,
	EmitterHeight = 32, -- studs above camera XZ
	EmitterSizeX = 72,
	EmitterSizeZ = 72,
	RainParticleSize = 0.18,
	RainParticleSquash = 2.6,
	RainLifetimeMin = 0.75,
	RainLifetimeMax = 1.05,
	RainLightEmission = 0.25,
	RainColor = Color3.fromRGB(205, 228, 255),
	LightningMinInterval = 8,
	LightningMaxInterval = 15,
	LightningFlashBrightness = 4.6,
	LightningFadeSeconds = 0.28,
	LightningBoltFadeSeconds = 0.25,
	LightningBoltDistanceMin = 210,
	LightningBoltDistanceMax = 290,
	LightningBoltTopY = 175,
	LightningBoltBottomY = 42,
	LightningBoltSegments = 5,
	LightningBoltJitter = 14,
	LightningBoltThickness = 1.6,
	LightningBoltColor = Color3.fromRGB(225, 240, 255),
}

Weather.Defs = {
	Clear = {
		id = "Clear",
		name = "Clear",
		weight = 48, -- was 60
		minDuration = 150, -- was 180
		maxDuration = 240, -- was 360
		rarePlusBonus = 0,
		mutationMultiplier = 1.0,
		visual = {
			brightness = 2.2,
			outdoorAmbient = Color3.fromRGB(140, 152, 168),
			ambient = Color3.fromRGB(90, 100, 112),
			fogColor = Color3.fromRGB(192, 214, 232),
			fogStart = 180,
			fogEnd = 1200,
			atmosphereDensity = 0.22,
			atmosphereOffset = 0.25,
			atmosphereColor = Color3.fromRGB(199, 224, 245),
			atmosphereDecay = Color3.fromRGB(106, 130, 160),
			atmosphereHaze = 0.5,
			cloudCover = 0.42,
			cloudDensity = 0.45,
			cloudColor = Color3.fromRGB(242, 246, 255),
			rainRate = 0,
			rainSpeedMin = 48,
			rainSpeedMax = 62,
			rainWindX = -6,
		},
	},
	Rain = {
		id = "Rain",
		name = "Rain",
		weight = 32, -- was 28
		minDuration = 240, -- was 120
		maxDuration = 420, -- was 240
		rarePlusBonus = 0.12, -- was 0.05
		mutationMultiplier = 1.5,
		hudNote = "Storm-Charged & +50% Mutations!",
		visual = {
			brightness = 1.45,
			outdoorAmbient = Color3.fromRGB(98, 114, 134),
			ambient = Color3.fromRGB(68, 78, 92),
			fogColor = Color3.fromRGB(132, 150, 170),
			fogStart = 90,
			fogEnd = 650,
			atmosphereDensity = 0.38,
			atmosphereOffset = 0.12,
			atmosphereColor = Color3.fromRGB(148, 166, 188),
			atmosphereDecay = Color3.fromRGB(76, 90, 112),
			atmosphereHaze = 2.0,
			cloudCover = 0.78,
			cloudDensity = 0.72,
			cloudColor = Color3.fromRGB(168, 178, 194),
			rainRate = 180,
			rainSpeedMin = 56,
			rainSpeedMax = 72,
			rainWindX = -10,
		},
	},
	Storm = {
		id = "Storm",
		name = "Storm",
		weight = 20, -- was 12
		minDuration = 240, -- was 90
		maxDuration = 360, -- was 180
		rarePlusBonus = 0.25, -- was 0.10
		mutationMultiplier = 2.0,
		hudNote = "Rare+ & 2x Mutations!",
		visual = {
			brightness = 0.95,
			outdoorAmbient = Color3.fromRGB(64, 76, 98),
			ambient = Color3.fromRGB(46, 54, 70),
			fogColor = Color3.fromRGB(78, 92, 116),
			fogStart = 55,
			fogEnd = 420,
			atmosphereDensity = 0.48,
			atmosphereOffset = 0.05,
			atmosphereColor = Color3.fromRGB(96, 112, 140),
			atmosphereDecay = Color3.fromRGB(48, 56, 78),
			atmosphereHaze = 3.5,
			cloudCover = 0.95,
			cloudDensity = 0.92,
			cloudColor = Color3.fromRGB(96, 106, 126),
			rainRate = 380,
			rainSpeedMin = 70,
			rainSpeedMax = 92,
			rainWindX = -18,
		},
	},
} :: { [WeatherId]: WeatherDef }

local ORDER: { WeatherId } = { "Clear", "Rain", "Storm" }
Weather.Order = ORDER

function Weather.Get(id: WeatherId): WeatherDef
	return Weather.Defs[id]
end

function Weather.IsNight(clockTime: number): boolean
	return clockTime >= Weather.NightStart or clockTime < Weather.NightEnd
end

return Weather
