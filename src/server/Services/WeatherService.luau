--!strict
-- Server weather + day/night cycle. State replicates through Workspace
-- attributes ("Weather", "WeatherEndsAt") and Lighting.ClockTime, so clients
-- need no remote traffic to render it.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Weather = require(Shared.Config.Weather)
local Weighted = require(Shared.Util.Weighted)

type WeatherId = Types.WeatherId

local WeatherService = {}

local rng = Random.new()
local current: WeatherId = "Clear"

function WeatherService.GetWeather(): WeatherId
	return current
end

function WeatherService.IsNight(): boolean
	return Weather.IsNight(Lighting.ClockTime)
end

function WeatherService.GetRarePlusBonus(): number
	return Weather.Defs[current].rarePlusBonus
end

local function setWeather(id: WeatherId, duration: number)
	current = id
	Workspace:SetAttribute("Weather", id)
	Workspace:SetAttribute("WeatherEndsAt", Workspace:GetServerTimeNow() + duration)
end

-- Overrides the current weather (Studio QA via DevService). The normal cycle
-- resumes when its own timer next fires.
function WeatherService.Force(id: WeatherId, duration: number)
	setWeather(id, duration)
end

function WeatherService.Init()
	Lighting.ClockTime = Weather.StartClockTime
	setWeather("Clear", Weather.Get("Clear").minDuration)
end

function WeatherService.Start()
	-- Weather cycle. The same weather never repeats back to back.
	task.spawn(function()
		task.wait(Weather.Get("Clear").minDuration)
		while true do
			local options: { WeatherId } = {}
			local weights: { number } = {}
			for _, id: WeatherId in Weather.Order do
				if id ~= current then
					table.insert(options, id)
					table.insert(weights, Weather.Defs[id].weight)
				end
			end
			local nextId: WeatherId = options[Weighted.PickIndex(rng, weights)]
			local def = Weather.Defs[nextId]
			local duration = rng:NextNumber(def.minDuration, def.maxDuration)
			setWeather(nextId, duration)
			task.wait(duration)
		end
	end)

	-- Day/night cycle, stepped once a second (clients tween between steps).
	task.spawn(function()
		local hoursPerSecond = 24 / Weather.DayLengthSeconds
		while true do
			local dt = task.wait(1)
			Lighting.ClockTime = (Lighting.ClockTime + hoursPerSecond * dt) % 24
		end
	end)
end

return WeatherService
