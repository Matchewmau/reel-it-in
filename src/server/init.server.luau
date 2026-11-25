--!strict
-- Server bootstrap. All logic lives in the service modules; this script only
-- creates remotes and runs the two-phase startup (Init everything, then Start
-- everything) so services can reference each other safely.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

Net.SetupServer()

local Services = script.Services

-- Order matters for Start(): DataService fires profile-loaded callbacks that the
-- other services register during Init().
local ordered: { { Init: () -> (), Start: () -> () } } = {
	require(Services.WeatherService),
	require(Services.PondService),
	require(Services.FishingService),
	require(Services.GachaService),
	require(Services.TravelService),
	require(Services.QuestService),
	require(Services.BestCatchService),
	require(Services.ShowcaseService),
	require(Services.DevService),
	require(Services.DataService),
}

for _, service in ordered do
	service.Init()
end
for _, service in ordered do
	service.Start()
end

print("[ReelItIn] Server ready")
