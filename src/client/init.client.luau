--!strict
-- Client bootstrap. Controllers own all presentation; the server owns all state.

local Controllers = script.Controllers
local ClientState = require(script.ClientState)

local ordered: { { Init: () -> (), Start: () -> () } } = {
	require(Controllers.HUDController),
	require(Controllers.ReelController),
	require(Controllers.PondVisualController),
	require(Controllers.FishingVisualController),
	require(Controllers.HoldVisualController),
	require(Controllers.SidebarController),
	require(Controllers.AmbientController),
	require(Controllers.WeatherVisualController),
	require(Controllers.WaterfallVisualController),
	require(Controllers.GachaRevealController),
}

for _, controller in ordered do
	controller.Init()
end
for _, controller in ordered do
	controller.Start()
end

-- Start listening for server state only once every controller has subscribed.
ClientState.Start()
