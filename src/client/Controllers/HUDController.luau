--!strict
-- Exploration HUD: nautical brass gold card, dynamic riveted-steel weather banner,
-- focus [E] CAST CTA, illustrated navigation tray, and management panels.
--
-- Everything shown here comes from ClientState; every button sends a request
-- and waits for the server's answer. Nothing is predicted locally.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Rarities = require(Shared.Config.Rarities)
local Creatures = require(Shared.Config.Creatures)
local Mutations = require(Shared.Config.Mutations)
local Rods = require(Shared.Config.Rods)
local Baits = require(Shared.Config.Baits)
local PondConfig = require(Shared.Config.PondConfig)
local Travel = require(Shared.Config.Travel)
local WeatherConfig = require(Shared.Config.Weather)

local ClientState = require(script.Parent.Parent.ClientState)
local DockArt = require(script.Parent.Parent.UI.DockArt)
local Kit = require(script.Parent.Parent.UI.Kit)
local ManagementPanel = require(script.Parent.Parent.UI.ManagementPanel)
local GachaRevealController = require(script.Parent.GachaRevealController)

type Snapshot = Types.Snapshot
type CreatureInstance = Types.CreatureInstance
type Rarity = Types.Rarity
type WeatherId = Types.WeatherId

type RowButton = ManagementPanel.Action
type Row = ManagementPanel.Row

local Theme = Kit.Theme
local player = Players.LocalPlayer

local HUDController = {}

-- Set by ReelController: called when the cast button is pressed.
HUDController.OnCastPressed = nil :: (() -> ())?

local gui: ScreenGui
local goldLabel: TextLabel
local goldScale: UIScale
local rateLabel: TextLabel
local rateFill: Frame
local weatherLabel: TextLabel
local weatherIcon: TextLabel
local weatherNote: TextLabel
local weatherTimer: TextLabel
local weatherInteriorGradient: UIGradient
local weatherLeftWing: Frame
local weatherRightWing: Frame
local weatherSirenGlow: Frame
local weatherPulseTweens: { Tween } = {}
local buffPanel: Frame
local buffLabel: TextLabel
local castButton: TextButton
local castSubLabel: TextLabel
local toastHolder: Frame
local announceLabel: TextLabel
local panel: ManagementPanel.View
local menuLabels: { [string]: TextLabel } = {}

local currentTab: string? = nil
local announceToken = 0
local lastGold: number? = nil
local goldPopTween: Tween? = nil
local rateFillTween: Tween? = nil

local GOLD_POP_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RATE_FILL_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local CLEAR_PALETTE = { top = Color3.fromRGB(86, 174, 238), bottom = Color3.fromRGB(168, 218, 248) }
local WEATHER_PALETTES: { [WeatherId]: { top: Color3, bottom: Color3 } } = {
	Clear = CLEAR_PALETTE,
	Rain = { top = Color3.fromRGB(54, 82, 118), bottom = Color3.fromRGB(26, 40, 64) },
	Storm = { top = Color3.fromRGB(36, 48, 72), bottom = Color3.fromRGB(16, 23, 38) },
}

local TRAVEL_COLORS: { [string]: Color3 } = {
	Hub = Color3.fromRGB(196, 144, 72),
	Freshwater = Color3.fromRGB(56, 170, 244),
	Saltwater = Color3.fromRGB(88, 114, 242),
}

-- Toasts ------------------------------------------------------------------------------

function HUDController.Toast(text: string, kind: string?)
	if not toastHolder then
		return
	end
	local color = if kind == "good" then Theme.Good elseif kind == "bad" then Theme.Bad else Theme.Brass
	local toast = Kit.Label({
		Text = text,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = toastHolder,
	})
	Kit.Corner(toast, 8)
	Kit.Stroke(toast, color, 2)
	Kit.Padding(toast, 12, 8)

	task.delay(3.5, function()
		local tween =
			TweenService:Create(toast, TweenInfo.new(0.4), { TextTransparency = 1, BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		toast:Destroy()
	end)
end

local function announce(text: string, rarity: string?)
	local info = if rarity then Rarities.Get(rarity :: Rarity) else nil
	announceToken += 1
	local token = announceToken
	announceLabel.Text = text
	announceLabel.TextColor3 = if info then info.color else Theme.Text
	announceLabel.Visible = true
	task.delay(6, function()
		if announceToken == token then
			announceLabel.Visible = false
		end
	end)
end

-- Requests ----------------------------------------------------------------------------

-- Sends a request off the UI thread; shows the server's error as a toast.
local function request(name: string, onSuccess: ((response: { [string]: any }) -> ())?, ...: any)
	local args = table.pack(...)
	task.spawn(function()
		local response = Net.Invoke(name, table.unpack(args, 1, args.n))
		if not response.ok then
			HUDController.Toast(tostring(response.error or "That didn't work."), "bad")
		elseif onSuccess then
			onSuccess(response)
		end
	end)
end

-- Text helpers ------------------------------------------------------------------------

local function creatureTitle(creature: CreatureInstance): (string, Color3, string)
	local species = Creatures.Get(creature.speciesId)
	if not species then
		return "Unknown", Theme.Text, ""
	end
	local tags = ""
	if creature.colossal then
		tags ..= " · ★ COLOSSAL"
	end
	if creature.mutation ~= "Normal" then
		tags ..= " · " .. Mutations.Get(creature.mutation).name
	end
	local rarityInfo = Rarities.Get(species.rarity)
	return species.name, rarityInfo.color, `[{species.rarity}]{tags}`
end

local function slottedUids(snapshot: Snapshot): { [string]: string }
	local map: { [string]: string } = {}
	for slotKey, uid in snapshot.pond do
		map[uid] = slotKey
	end
	return map
end

local function backpackCount(snapshot: Snapshot): number
	local total = 0
	for _ in snapshot.creatures do
		total += 1
	end
	local slotted = 0
	for _ in snapshot.pond do
		slotted += 1
	end
	return total - slotted
end

local function firstEmptySlot(snapshot: Snapshot): number?
	for slot = 1, snapshot.maxSlots do
		if not snapshot.pond[tostring(slot)] then
			return slot
		end
	end
	return nil
end

-- Panel tabs --------------------------------------------------------------------------

local function backpackRows(snapshot: Snapshot): ({ Row }, string)
	local slotted = slottedUids(snapshot)
	local list: { CreatureInstance } = {}
	for uid, creature in snapshot.creatures do
		if not slotted[uid] then
			table.insert(list, creature)
		end
	end
	table.sort(list, function(a: CreatureInstance, b: CreatureInstance): boolean
		local ia, ib = Creatures.BaseIncome(a), Creatures.BaseIncome(b)
		if ia == ib then
			return a.uid < b.uid
		end
		return ia > ib
	end)

	local rows: { Row } = {}
	for _, creature in list do
		local title, color, quality = creatureTitle(creature)
		local uid = creature.uid
		local sellValue = PondConfig.SellValue(creature)
		local holding = player:GetAttribute("HeldUid") == uid
		table.insert(rows, {
			uid = uid,
			tag = Format.Weight(creature.weight),
			badge = if holding then "HELD" elseif creature.colossal then "★" else nil,
			title = title,
			quality = quality,
			color = color,
			subtitle = `{Format.Weight(creature.weight)} · {Format.Rate(Creatures.BaseIncome(creature))}`,
			preview = { kind = "Creature", id = creature.speciesId, mutation = creature.mutation },
			buttons = {
				{
					-- Carry it in your hands so other players can see it at full size.
					text = if holding then "Put Away" else "Show Off",
					color = if holding then Theme.PanelLight else Theme.Accent,
					onClick = function()
						if holding then
							request("Hold", nil, false)
						else
							request("Hold", function()
								HUDController.ClosePanel()
							end, uid)
						end
					end,
				},
				{
					text = "Place",
					color = Theme.Good,
					onClick = function()
						local latest = ClientState.Snapshot
						local slot = if latest then firstEmptySlot(latest) else nil
						if not slot then
							HUDController.Toast("Your pond is full. Remove a fish or unlock a slot.", "bad")
							return
						end
						request("PondPlace", nil, uid, slot)
					end,
				},
				{
					text = `Sell {Format.Number(sellValue)}g`,
					color = Theme.Gold,
					onClick = function()
						request("SellCreature", function(response: { [string]: any })
							HUDController.Toast(`Sold for {Format.Number(response.gold)} Gold.`, "good")
						end, uid)
					end,
				},
			},
		})
	end
	return rows,
		`{#list}/{snapshot.backpackCap} creatures · the Fish Appraiser pays {PondConfig.SellSeconds}s of a fish's income`
end

local function rodRows(snapshot: Snapshot): ({ Row }, string)
	local owned: { Rods.RodDef } = {}
	for rodId in snapshot.rods do
		local def = Rods.Get(rodId)
		if def then
			table.insert(owned, def)
		end
	end
	table.sort(owned, function(a: Rods.RodDef, b: Rods.RodDef): boolean
		return Rarities.Get(a.rarity).order > Rarities.Get(b.rarity).order
	end)

	local rows: { Row } = {}
	for _, def in owned do
		local state = snapshot.rods[def.id]
		local stats = Rods.GetStats(def.id, state.stars)
		local shardText = if state.stars >= Rods.Stars.Max
			then "MAX"
			else `shards {state.shards}/{Rods.Stars.ShardsToNext[state.stars]}`
		local barText = if stats.barSizeBonus > 0
			then string.format(" · +%d%% Catch Bar", math.floor(stats.barSizeBonus * 100 + 0.5))
			else ""
		local equipped = snapshot.equippedRod == def.id
		local rodId = def.id
		table.insert(rows, {
			title = `{def.name} {string.rep("★", state.stars)}`,
			quality = `[{def.rarity}]`,
			preview = { kind = "Rod", id = def.id },
			color = Rarities.Get(def.rarity).color,
			subtitle = string.format(
				"%.2fx Luck · %.2fx Weight · +%d%% Mutation%s · %s\n%s",
				stats.luck,
				stats.weight,
				math.floor(stats.mutationBonus * 100 + 0.5),
				barText,
				shardText,
				def.description
			),
			buttons = {
				{
					text = if equipped then "Equipped" else "Equip",
					color = if equipped then Theme.PanelLight else Theme.Accent,
					onClick = function()
						if not equipped then
							request("Equip", nil, "Rod", rodId)
						end
					end,
				},
			},
		})
	end
	return rows, "Duplicate pulls become Rod Shards that raise a rod's ★ level."
end

local function baitRows(snapshot: Snapshot): ({ Row }, string)
	local rows: { Row } = {}
	for _, baitId in Baits.DisplayOrder do
		local def = Baits.Defs[baitId]
		local count = snapshot.baits[baitId] or 0
		local equipped = snapshot.equippedBait == baitId
		local buttons: { RowButton } = {
			{
				text = if equipped then "Equipped" else "Equip",
				color = if equipped then Theme.PanelLight else Theme.Accent,
				onClick = function()
					if not equipped then
						request("Equip", nil, "Bait", baitId)
					end
				end,
			},
		}
		if def.price then
			table.insert(buttons, {
				text = `Buy x{def.bundle} ({Format.Number(def.price)}g)`,
				color = Theme.Gold,
				onClick = function()
					request("BuyBait", nil, baitId, 1)
				end,
			})
		end
		table.insert(rows, {
			title = `{def.name} x{count}`,
			quality = `[{def.rarity}]`,
			preview = { kind = "Bait", id = baitId },
			color = Rarities.Get(def.rarity).color,
			subtitle = def.description,
			buttons = buttons,
		})
	end
	return rows, "Bait is used up each cast. If the equipped bait doesn't suit the water, a matching one is used."
end

-- Asks the server to move us; closes the panel on arrival.
local function travelTo(kind: string, plot: number?)
	request("Teleport", function(response: { [string]: any })
		HUDController.ClosePanel()
		HUDController.Toast(`Arrived at {tostring(response.name)}.`, "good")
	end, kind, plot)
end

local function travelRows(_snapshot: Snapshot): ({ Row }, string)
	local rows: { Row } = {
		{
			title = "My Pond",
			landmark = "Pond",
			color = Color3.fromRGB(232, 168, 56),
			subtitle = "Your own pond plot. Look for your face floating above it.",
			buttons = {
				{
					text = "Teleport",
					color = Theme.Good,
					onClick = function()
						travelTo("MyPond")
					end,
				},
			},
		},
	}
	for _, destination in Travel.Destinations do
		local id = destination.id
		table.insert(rows, {
			title = destination.name,
			landmark = id,
			color = TRAVEL_COLORS[id] or Theme.Accent,
			subtitle = destination.description,
			buttons = {
				{
					text = "Teleport",
					color = Theme.Good,
					onClick = function()
						travelTo(id)
					end,
				},
			},
		})
	end

	local plots: { number } = {}
	for plot, pond in ClientState.Ponds do
		if pond.ownerUserId ~= 0 and pond.ownerUserId ~= player.UserId then
			table.insert(plots, plot)
		end
	end
	table.sort(plots)
	for _, plot in plots do
		local pond = ClientState.Ponds[plot]
		table.insert(rows, {
			title = `{pond.ownerName}'s Pond`,
			landmark = "Pond",
			color = Theme.Brass,
			subtitle = `Pond {plot} · {Format.Rate(pond.total)} · feed it once every 10 minutes for +15% Luck each`,
			buttons = {
				{
					text = "Visit",
					color = Theme.Good,
					onClick = function()
						travelTo("Pond", plot)
					end,
				},
			},
		})
	end
	return rows, `Travel has a {Travel.Cooldown} second cooldown. Reel in your line before travelling.`
end

local function pondRows(snapshot: Snapshot): ({ Row }, string)
	local unique: { [string]: boolean } = {}
	local slottedCount = 0
	for slot = 1, snapshot.maxSlots do
		local uid = snapshot.pond[tostring(slot)]
		local creature = if uid then snapshot.creatures[uid] else nil
		if creature then
			slottedCount += 1
			unique[creature.speciesId] = true
		end
	end
	local uniqueCount = 0
	for _ in unique do
		uniqueCount += 1
	end

	local slotCap = math.max(PondConfig.MaxGoldSlots, snapshot.maxSlots)
	local plotText = if snapshot.plot > 0 then tostring(snapshot.plot) else "—"
	local rows: { Row } = {
		{
			title = `My Pond • Plot #{plotText}`,
			quality = `Total Income: {Format.Rate(snapshot.incomeTotal)}`,
			landmark = "Pond",
			color = Theme.Brass,
			subtitle = `Unlocked Slots: {snapshot.maxSlots}/{slotCap} • Active Fish: {slottedCount}/{snapshot.maxSlots} • {uniqueCount} unique species`,
			buttons = {
				{
					text = "Teleport to My Pond",
					color = Theme.Good,
					onClick = function()
						travelTo("MyPond")
					end,
				},
			},
		},
	}

	for slot = 1, snapshot.maxSlots do
		local slotKey = tostring(slot)
		local uid = snapshot.pond[slotKey]
		local creature = if uid then snapshot.creatures[uid] else nil
		if creature and uid then
			local creatureUid = uid
			local title, color, quality = creatureTitle(creature)
			local aura = PondConfig.GetAuraOf(creature)
			local auraLine = if aura then `\nAura [{aura.name}]: {aura.description}` else ""
			table.insert(rows, {
				title = `Slot {slot} • {title}`,
				quality = quality,
				preview = { kind = "Creature", id = creature.speciesId, mutation = creature.mutation },
				color = color,
				subtitle = `Weight: {Format.Weight(creature.weight)} • Gain: {Format.Rate(
					snapshot.incomePerSlot[slotKey] or 0
				)}{auraLine}`,
				buttons = {
					{
						text = "Show Off",
						color = Theme.Accent,
						onClick = function()
							local fState = player:GetAttribute("FishingState")
							if fState == "Waiting" or fState == "Biting" then
								HUDController.Toast("Reel in your line first.", "bad")
								return
							end
							request("PondRemove", function()
								request("Hold", function()
									HUDController.ClosePanel()
								end, creatureUid)
							end, slot)
						end,
					},
					{
						text = "Remove",
						color = Theme.Danger,
						onClick = function()
							request("PondRemove", nil, slot)
						end,
					},
				},
			})
		else
			table.insert(rows, {
				title = `Slot {slot} • Empty`,
				quality = "[OPEN SLOT]",
				color = Color3.fromRGB(112, 136, 166),
				subtitle = "Empty water slot — place a creature from your Backpack to earn passive Gold/s.",
				buttons = {
					{
						text = "+ Equip Creature",
						color = Theme.Accent,
						onClick = function()
							HUDController.OpenTab("Backpack")
						end,
					},
				},
			})
		end
	end

	local nextSlot = snapshot.slotsUnlocked + 1
	local nextCost = PondConfig.GetSlotCost(nextSlot)
	if nextSlot <= PondConfig.MaxGoldSlots and nextCost then
		table.insert(rows, {
			title = `Slot {nextSlot} • LOCKED`,
			quality = "[GOLD UPGRADE]",
			color = Theme.Gold,
			subtitle = `Expand your pond capacity ({snapshot.slotsUnlocked}/{PondConfig.MaxGoldSlots} Gold slots unlocked).`,
			buttons = {
				{
					text = `Unlock ({Format.Number(nextCost)} Gold)`,
					color = Theme.Gold,
					onClick = function()
						request("BuySlot", function()
							HUDController.Toast(`Slot {nextSlot} unlocked!`, "good")
						end)
					end,
				},
			},
		})
	end
	for _, pass in PondConfig.Gamepasses do
		local passId = pass.id
		table.insert(rows, {
			title = `{pass.name} • +{pass.slots} permanent slots`,
			quality = "[EXPANSION PASS]",
			color = Theme.Accent,
			subtitle = if pass.goldAura
				then "Premium expansion with a Gold Aura effect for your pond."
				else "Premium expansion.",
			buttons = {
				{
					text = `{pass.robux} Robux`,
					color = Theme.Good,
					onClick = function()
						if passId == 0 then
							HUDController.Toast("This expansion isn't on sale yet.", "info")
						else
							MarketplaceService:PromptGamePassPurchase(player, passId)
						end
					end,
				},
			},
		})
	end

	return rows,
		`Total Income: {Format.Rate(snapshot.incomeTotal)} • {uniqueCount} unique species • Epic+ creatures project pond auras`
end

local function oddsText(weights: { [Rarity]: number }): string
	local parts: { string } = {}
	for _, rarity: Rarity in Rarities.Order do
		if weights[rarity] then
			table.insert(parts, `{rarity} {weights[rarity]}%`)
		end
	end
	return table.concat(parts, " · ")
end

local function shopRows(snapshot: Snapshot): ({ Row }, string)
	local gacha = Rods.Gacha
	local crateOdds: { string } = {}
	for _, entry in Baits.Crate.Entries do
		table.insert(crateOdds, `{Baits.Defs[entry.baitId].name} x{entry.amount} {entry.weight}%`)
	end

	-- The server has already granted the pulls; hand the results to the reveal
	-- animation. The panel closes so the reveal has the whole screen.
	local function showPulls(response: { [string]: any })
		HUDController.ClosePanel()
		GachaRevealController.PlayRods(response.results)
	end

	local rows: { Row } = {
		{
			title = "Rod Gacha Shrine",
			landmark = "Shrine",
			color = Rarities.Get("Epic").color,
			subtitle = `Odds: {oddsText(gacha.RarityWeights)}\nEpic+ guaranteed within {gacha.PityThreshold} pulls (pity {snapshot.pity.rod}/{gacha.PityThreshold}).`,
			buttons = {
				{
					text = `1 Pull ({Format.Number(gacha.PullCost)}g)`,
					color = Theme.Gold,
					onClick = function()
						request("RodPull", showPulls, 1)
					end,
				},
				{
					text = `{gacha.MultiCount} Pulls ({Format.Number(gacha.MultiCost)}g)`,
					color = Theme.Gold,
					onClick = function()
						request("RodPull", showPulls, gacha.MultiCount)
					end,
				},
			},
		},
		{
			title = "Bait Crate",
			landmark = "Crate",
			color = Theme.Good,
			subtitle = "Odds: " .. table.concat(crateOdds, " · "),
			buttons = {
				{
					text = `Open ({Format.Number(Baits.Crate.Cost)}g)`,
					color = Theme.Gold,
					onClick = function()
						request("BaitCrate", function(response: { [string]: any })
							HUDController.ClosePanel()
							GachaRevealController.PlayBaits(response.results)
						end, 1)
					end,
				},
			},
		},
		{
			title = "Bait Merchant",
			landmark = "Merchant",
			color = Theme.Accent,
			subtitle = "Buy everyday bait by the bundle.",
			buttons = {
				{
					text = "Browse Baits",
					color = Theme.Accent,
					onClick = function()
						HUDController.OpenTab("Baits")
					end,
				},
			},
		},
	}
	return rows, "All odds are shown above. Gold pulls only - no surprises."
end

local TABS: { [string]: { title: string, build: (Snapshot) -> ({ Row }, string) } } = {
	Backpack = { title = "BACKPACK", build = backpackRows },
	Rods = { title = "RODS", build = rodRows },
	Baits = { title = "BAITS", build = baitRows },
	Pond = { title = "MY POND", build = pondRows },
	Shop = { title = "SHOP", build = shopRows },
	Travel = { title = "TRAVEL", build = travelRows },
}
local TAB_ORDER = { "Backpack", "Rods", "Baits", "Pond", "Shop" }

-- Panel rendering -----------------------------------------------------------------------

local function refreshPanel()
	local snapshot = ClientState.Snapshot
	local tabName = currentTab
	local tab = if tabName then TABS[tabName] else nil
	if not tab or not tabName or not snapshot then
		panel.root.Visible = false
		return
	end
	local rows, footer = tab.build(snapshot)
	local slottedCount = 0
	for _ in snapshot.pond do
		slottedCount += 1
	end
	local count = if tabName == "Backpack"
		then `{backpackCount(snapshot)}/{snapshot.backpackCap}`
		elseif tabName == "Pond" then `{slottedCount}/{snapshot.maxSlots}`
		else nil
	ManagementPanel.Render(panel, tabName, tab.title, rows, footer, count, snapshot.backpackCap)
end

function HUDController.OpenTab(tabName: string)
	if player:GetAttribute("FishingState") == "Biting" then
		return
	end
	if not TABS[tabName] then
		return
	end
	currentTab = tabName
	gui:SetAttribute("ActiveTab", tabName)
	panel.list.CanvasPosition = Vector2.zero
	refreshPanel()
end

function HUDController.ClosePanel()
	currentTab = nil
	gui:SetAttribute("ActiveTab", nil)
	panel.root.Visible = false
	ManagementPanel.Clear(panel)
end

function HUDController.IsPanelOpen(): boolean
	return currentTab ~= nil
end

-- Status widgets ------------------------------------------------------------------------

local function refreshGold()
	local gold = player:GetAttribute("Gold")
	local rate = player:GetAttribute("GoldPerSec")
	local numericGold = if type(gold) == "number" then gold else 0
	local numericRate = if type(rate) == "number" then rate else 0

	goldLabel.Text = Format.Number(numericGold)
	if type(gold) == "number" then
		if lastGold ~= nil and numericGold > lastGold and goldScale then
			if goldPopTween then
				goldPopTween:Cancel()
			end
			goldScale.Scale = 1.10
			local tween = TweenService:Create(goldScale, GOLD_POP_TWEEN, { Scale = 1 })
			goldPopTween = tween
			tween:Play()
		end
		lastGold = numericGold
	end

	rateLabel.Text = Format.Rate(numericRate)
	local fillScale = if numericRate > 0 then math.clamp(math.log10(numericRate + 1) / 4, 0.18, 1) else 0
	if rateFillTween then
		rateFillTween:Cancel()
		rateFillTween = nil
	end
	if fillScale > 0 then
		if not rateFill.Visible then
			rateFill.Size = UDim2.fromScale(0, 1)
			rateFill.Visible = true
		end
		local tween = TweenService:Create(rateFill, RATE_FILL_TWEEN, {
			Size = UDim2.fromScale(fillScale, 1),
		})
		rateFillTween = tween
		tween:Play()
	else
		rateFill.Visible = false
		rateFill.Size = UDim2.fromScale(0, 1)
	end
end

local function stopWeatherPulse()
	for _, tween in weatherPulseTweens do
		tween:Cancel()
	end
	table.clear(weatherPulseTweens)
end

local function refreshWeatherTimer()
	local endsAt = Workspace:GetAttribute("WeatherEndsAt")
	if type(endsAt) == "number" then
		local remaining = math.max(0, endsAt - Workspace:GetServerTimeNow())
		weatherTimer.Text = Format.Duration(remaining)
		weatherTimer.Visible = remaining > 0
	else
		weatherTimer.Visible = false
	end
end

local function refreshWeather()
	local id = Workspace:GetAttribute("Weather")
	local def = if type(id) == "string" then WeatherConfig.Defs[id :: WeatherId] else nil
	local weather = def or WeatherConfig.Get("Clear")
	local weatherId: WeatherId = weather.id

	weatherIcon.Text = if weatherId == "Storm" then "⛈️" elseif weatherId == "Rain" then "🌧️" else "☀️"
	weatherLabel.Text = "WEATHER: " .. string.upper(weather.name)

	local palette = WEATHER_PALETTES[weatherId] or CLEAR_PALETTE
	weatherInteriorGradient.Color = ColorSequence.new(palette.top, palette.bottom)

	local isAlert = weatherId == "Storm" or weatherId == "Rain"
	local noteText = if weatherId == "Storm"
		then "(RARE+ & 2X MUTATIONS!)"
		elseif weather.hudNote then `({string.upper(weather.hudNote)})`
		else ""
	weatherNote.Text = noteText
	weatherNote.Visible = noteText ~= ""
	weatherLabel.Position = UDim2.fromOffset(42, if noteText ~= "" then 1 else 10)

	stopWeatherPulse()
	weatherLeftWing.Visible = isAlert
	weatherRightWing.Visible = isAlert
	if isAlert then
		weatherSirenGlow.BackgroundTransparency = 0.15
		local pulseInfo = TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		local glowTween = TweenService:Create(weatherSirenGlow, pulseInfo, { BackgroundTransparency = 0.72 })
		glowTween:Play()
		table.insert(weatherPulseTweens, glowTween)
	end

	refreshWeatherTimer()
end

local function refreshBuffs()
	local snapshot = ClientState.Snapshot
	if not snapshot then
		buffPanel.Visible = false
		return
	end
	local parts: { string } = {}
	local luck = ClientState.Remaining(snapshot.luckBuffRemaining)
	if luck > 0 then
		table.insert(parts, `+{math.floor(PondConfig.Blessing.LuckBonus * 100 + 0.5)}% LUCK {Format.Duration(luck)}`)
	end
	local starfall = ClientState.Remaining(snapshot.starfallRemaining)
	if starfall > 0 then
		table.insert(parts, `STARFALL x2 {Format.Duration(starfall)}`)
	end
	buffLabel.Text = table.concat(parts, "  •  ")
	buffPanel.Visible = #parts > 0
end

local function refreshFromState(snapshot: Snapshot)
	local rod = Rods.Get(snapshot.equippedRod)
	local bait = Baits.Get(snapshot.equippedBait)
	local baitCount = snapshot.baits[snapshot.equippedBait] or 0
	castSubLabel.Text = `[{if rod then rod.name else "No Rod"} + {if bait then bait.name else "No Bait"} x{baitCount}]`

	local slotted = 0
	for _ in snapshot.pond do
		slotted += 1
	end
	menuLabels.Backpack.Text = `{backpackCount(snapshot)}/{snapshot.backpackCap}`
	menuLabels.Pond.Text = `{slotted}/{snapshot.maxSlots}`

	refreshBuffs()
	if currentTab then
		refreshPanel()
	end
end

-- Construction --------------------------------------------------------------------------

local function build()
	gui = Kit.ScreenGui("HUD", 10)
	Kit.AutoScale(gui)
	local compact = Kit.IsCompact()

	-- Top right: brass-framed gold card + active buffs pill underneath.
	local goldPanel = Kit.Panel({
		Name = "GoldPanel",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 12),
		Size = UDim2.fromOffset(214, 68),
		Parent = gui,
	})
	Kit.Gradient(goldPanel, Color3.fromRGB(146, 102, 42), Color3.fromRGB(48, 34, 24))
	Kit.Trim(goldPanel, Theme.Brass)
	Kit.Gloss(goldPanel)

	local wallet = Kit.Frame({
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 1, -12),
		Parent = goldPanel,
	})
	local goldTag = Kit.Label({
		Text = "GOLD",
		Font = Kit.FontHeavy,
		TextColor3 = Color3.fromRGB(255, 226, 132),
		TextSize = 13,
		Size = UDim2.fromOffset(60, 28),
		Parent = wallet,
	})
	Kit.TextStroke(goldTag, Theme.PanelDark, 1.4)

	goldLabel = Kit.Label({
		Text = "0",
		Font = Kit.FontHeavy,
		TextColor3 = Theme.Gold,
		TextSize = 27,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0, 15),
		Size = UDim2.new(1, -48, 0, 30),
		Parent = wallet,
	})
	Kit.TextStroke(goldLabel, Color3.fromRGB(46, 26, 8), 1.8)
	goldScale = Instance.new("UIScale")
	goldScale.Scale = 1
	goldScale.Parent = goldLabel

	local rateBar = Kit.Frame({
		Name = "RateBar",
		BackgroundColor3 = Theme.PanelDark,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 20),
		ClipsDescendants = true,
		Parent = wallet,
	})
	Kit.Corner(rateBar, 5)
	Kit.Stroke(rateBar, Color3.fromRGB(84, 72, 48), 1.5)

	rateFill = Kit.Frame({
		Name = "RateFill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.22,
		Size = UDim2.fromScale(0, 1),
		Visible = false,
		ZIndex = 2,
		Parent = rateBar,
	})
	Kit.Corner(rateFill, 4)
	local rateGradient = Instance.new("UIGradient")
	rateGradient.Rotation = 0
	rateGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 168, 196)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(42, 198, 132)),
	})
	rateGradient.Parent = rateFill
	Kit.Frame({
		Name = "FillSheen",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.82,
		Size = UDim2.fromScale(1, 0.45),
		Active = false,
		ZIndex = 3,
		Parent = rateFill,
	})
	Kit.Frame({
		Name = "LeadingGlow",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 2, 1, 0),
		BackgroundColor3 = Color3.fromRGB(255, 250, 206),
		BackgroundTransparency = 0.25,
		Active = false,
		ZIndex = 3,
		Parent = rateFill,
	})

	rateLabel = Kit.Label({
		Text = "+0.0/s",
		Font = Kit.Font,
		TextColor3 = Color3.fromRGB(248, 240, 210),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -12, 1, 0),
		ZIndex = 4,
		Parent = rateBar,
	})
	Kit.TextStroke(rateLabel, Theme.PanelDark, 1.4)

	-- Active buffs pill beneath the Gold Card (riveted steel styling)
	buffPanel = Kit.Frame({
		Name = "BuffPill",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 86),
		Size = UDim2.fromOffset(214, 28),
		Visible = false,
		Parent = gui,
	})
	Kit.Corner(buffPanel, 8)
	Kit.Gradient(buffPanel, Color3.fromRGB(64, 80, 102), Theme.PanelDark)
	Kit.Stroke(buffPanel, Color3.fromRGB(118, 138, 162), 2)
	Kit.Gloss(buffPanel)
	buffLabel = Kit.Label({
		Text = "",
		Font = Kit.FontHeavy,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(112, 236, 168),
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -16, 1, 0),
		Parent = buffPanel,
	})
	Kit.TextStroke(buffLabel, Theme.PanelDark, 1.2)

	-- Right-side TELEPORT Quick-Bar anchored below the Gold/Buff stack.
	local teleportPanel = Kit.Panel({
		Name = "TeleportPanel",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 114),
		Size = UDim2.fromOffset(168, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = gui,
	})
	Kit.Corner(teleportPanel, 10)
	Kit.Gradient(teleportPanel, Color3.fromRGB(52, 66, 86), Theme.PanelDark)
	Kit.Trim(teleportPanel, Color3.fromRGB(116, 132, 152))

	local teleportContent = Kit.Frame({
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = teleportPanel,
	})
	Kit.Padding(teleportContent, 8, 8)
	Kit.List(teleportContent, Enum.FillDirection.Vertical, 6)

	local teleportExpanded = not compact
	local teleportHeaderLabel: TextLabel
	local teleportButtons: Frame

	if compact then
		local headerBtn = Kit.Button({
			Name = "Header",
			Text = "",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = 1,
			Parent = teleportContent,
		})
		Kit.Corner(headerBtn, 6)
		Kit.Gradient(headerBtn, Color3.fromRGB(98, 114, 136), Color3.fromRGB(48, 58, 74))
		Kit.Stroke(headerBtn, Color3.fromRGB(132, 148, 170), 1.5)
		Kit.Gloss(headerBtn)
		Kit.HoverScale(headerBtn, 1.03)
		teleportHeaderLabel = Kit.Label({
			Name = "Label",
			Text = "TELEPORT +",
			Font = Kit.FontHeavy,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = headerBtn.ZIndex + 1,
			Parent = headerBtn,
		})
		Kit.TextStroke(teleportHeaderLabel, Theme.PanelDark, 1.3)
		headerBtn.Activated:Connect(function()
			teleportExpanded = not teleportExpanded
			teleportButtons.Visible = teleportExpanded
			teleportHeaderLabel.Text = if teleportExpanded then "TELEPORT −" else "TELEPORT +"
		end)
	else
		local headerStrip = Kit.Frame({
			Name = "Header",
			Size = UDim2.new(1, 0, 0, 26),
			LayoutOrder = 1,
			Parent = teleportContent,
		})
		Kit.Corner(headerStrip, 6)
		Kit.Gradient(headerStrip, Color3.fromRGB(98, 114, 136), Color3.fromRGB(48, 58, 74))
		Kit.Stroke(headerStrip, Color3.fromRGB(132, 148, 170), 1.5)
		Kit.Gloss(headerStrip)
		teleportHeaderLabel = Kit.Label({
			Name = "Label",
			Text = "TELEPORT",
			Font = Kit.FontHeavy,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = headerStrip.ZIndex + 1,
			Parent = headerStrip,
		})
		Kit.TextStroke(teleportHeaderLabel, Theme.PanelDark, 1.3)
	end

	teleportButtons = Kit.Frame({
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = teleportExpanded,
		LayoutOrder = 2,
		Parent = teleportContent,
	})
	Kit.List(teleportButtons, Enum.FillDirection.Vertical, 6)

	local quickDestinations = {
		{ name = "MyPond", label = "My Pond", kind = "MyPond", color = Color3.fromRGB(217, 155, 46) },
		{ name = "Hub", label = "Player Hub", kind = "Hub", color = Color3.fromRGB(184, 120, 58) },
		{ name = "Freshwater", label = "Freshwater", kind = "Freshwater", color = Color3.fromRGB(46, 150, 230) },
		{ name = "Saltwater", label = "The Abyss", kind = "Saltwater", color = Color3.fromRGB(90, 70, 200) },
	}
	local teleportBtnHeight = if compact then 42 else 32
	for index, dest in quickDestinations do
		local btn = Kit.Button({
			Name = dest.name .. "TeleportButton",
			Text = "",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(1, 0, 0, teleportBtnHeight),
			LayoutOrder = index,
			Parent = teleportButtons,
		})
		Kit.Corner(btn, 7)
		Kit.Gradient(btn, dest.color, dest.color:Lerp(Theme.PanelDark, 0.45))
		Kit.Stroke(btn, dest.color:Lerp(Color3.new(1, 1, 1), 0.35), 1.5)
		Kit.Gloss(btn)
		Kit.HoverScale(btn, 1.04)

		local lbl = Kit.Label({
			Name = "Label",
			Text = dest.label,
			Font = Kit.FontHeavy,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = btn.ZIndex + 1,
			Parent = btn,
		})
		Kit.TextStroke(lbl, Theme.PanelDark, 1.3)

		local destKind = dest.kind
		btn.Activated:Connect(function()
			travelTo(destKind)
		end)
	end

	-- Top centre: riveted steel weather banner with flanking warning & siren wings.
	local centerWidth = if compact then 224 else 300
	local wingWidth = if compact then 34 else 46
	local weatherHolder = Kit.Frame({
		Name = "WeatherHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(centerWidth + wingWidth * 2 + 12, 58),
		Parent = gui,
	})

	weatherLeftWing = Kit.Frame({
		Name = "WarningWing",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(wingWidth, 34),
		Visible = false,
		Parent = weatherHolder,
	})
	Kit.Corner(weatherLeftWing, 7)
	Kit.Gradient(weatherLeftWing, Color3.fromRGB(112, 86, 36), Color3.fromRGB(48, 36, 18))
	Kit.Stroke(weatherLeftWing, Theme.Brass, 2)
	local warnIcon = Kit.Label({
		Text = "⚠",
		Font = Kit.FontHeavy,
		TextSize = if compact then 16 else 20,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = weatherLeftWing,
	})
	Kit.TextStroke(warnIcon, Theme.PanelDark, 2)

	weatherRightWing = Kit.Frame({
		Name = "SirenWing",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(wingWidth, 34),
		Visible = false,
		Parent = weatherHolder,
	})
	Kit.Corner(weatherRightWing, 7)
	Kit.Gradient(weatherRightWing, Color3.fromRGB(142, 40, 36), Color3.fromRGB(64, 18, 18))
	Kit.Stroke(weatherRightWing, Color3.fromRGB(232, 88, 76), 2)
	weatherSirenGlow = Kit.Frame({
		Name = "SirenGlow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = Color3.fromRGB(255, 68, 56),
		BackgroundTransparency = 0.2,
		Parent = weatherRightWing,
	})
	Kit.Corner(weatherSirenGlow, 11)
	local sirenIcon = Kit.Label({
		Text = "🚨",
		Font = Kit.FontHeavy,
		TextSize = if compact then 15 else 18,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = weatherRightWing,
	})
	Kit.TextStroke(sirenIcon, Theme.PanelDark, 1.5)

	local weatherPanel = Kit.Panel({
		Name = "WeatherPanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(centerWidth, 56),
		Parent = weatherHolder,
	})
	Kit.Gradient(weatherPanel, Color3.fromRGB(98, 114, 134), Color3.fromRGB(46, 56, 72))
	Kit.Trim(weatherPanel, Color3.fromRGB(128, 144, 166))

	local weatherInterior = Kit.Frame({
		Name = "Interior",
		Position = UDim2.fromOffset(6, 5),
		Size = UDim2.new(1, -12, 1, -10),
		Parent = weatherPanel,
	})
	Kit.Corner(weatherInterior, 6)
	weatherInteriorGradient = Kit.Gradient(weatherInterior, CLEAR_PALETTE.top, CLEAR_PALETTE.bottom)
	Kit.Stroke(weatherInterior, Theme.PanelDark, 1.5)

	weatherIcon = Kit.Label({
		Text = "",
		TextSize = 27,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.fromOffset(40, 42),
		Parent = weatherInterior,
	})
	weatherLabel = Kit.Label({
		Text = "WEATHER: CLEAR",
		Font = Kit.FontHeavy,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = if compact then 13 else 17,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(42, 10),
		Size = UDim2.new(1, -92, 0, 22),
		Parent = weatherInterior,
	})
	Kit.TextStroke(weatherLabel, Theme.PanelDark, 1.6)

	weatherNote = Kit.Label({
		Text = "",
		Font = Kit.FontHeavy,
		TextSize = if compact then 10 else 11,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(42, 23),
		Size = UDim2.new(1, -92, 0, 17),
		Parent = weatherInterior,
	})
	Kit.TextStroke(weatherNote, Theme.PanelDark, 1.2)

	weatherTimer = Kit.Label({
		Text = "",
		Font = Kit.FontHeavy,
		TextSize = 11,
		TextColor3 = Color3.fromRGB(232, 240, 250),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.25,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(42, 20),
		Visible = false,
		Parent = weatherInterior,
	})
	Kit.Corner(weatherTimer, 5)
	Kit.Stroke(weatherTimer, Color3.fromRGB(96, 114, 138), 1)

	announceLabel = Kit.Label({
		Text = "",
		Font = Kit.FontHeavy,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 74),
		Size = UDim2.fromOffset(760, 60),
		Visible = false,
		Parent = gui,
	})
	Kit.TextStroke(announceLabel, Theme.PanelDark, 2.5)

	toastHolder = Kit.Frame({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 138),
		Size = UDim2.fromOffset(420, 300),
		Parent = gui,
	})
	local toastLayout = Kit.List(toastHolder, Enum.FillDirection.Vertical, 6)
	toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	-- Bottom left: Focus [E] CAST CTA.
	-- On touch screens the bottom-left corner belongs to the thumbstick, so the cast
	-- button moves to the right, above the jump button, where the thumb already is.
	castButton = Kit.Button({
		Name = "CastButton",
		Text = "",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = if compact then Vector2.new(1, 1) else Vector2.new(0, 1),
		Position = if compact then UDim2.new(1, -16, 1, -Kit.Compact.JumpClearance) else UDim2.new(0, 16, 1, -44),
		Size = if compact then UDim2.fromOffset(172, 52) else UDim2.fromOffset(244, 68),
		Parent = gui,
	})
	Kit.Corner(castButton, 11)
	local finish = Kit.Gradient(castButton, Color3.fromRGB(96, 232, 92), Color3.fromRGB(22, 146, 56))
	Kit.Trim(castButton, Theme.Gold)
	Kit.Gloss(castButton)
	Kit.HoverScale(castButton, 1.04)

	-- Braided gold rope accents along top & bottom rims + inner emerald highlight rim
	for _, isTop in { true, false } do
		local ropeBar = Kit.Frame({
			Name = if isTop then "TopGoldBraid" else "BottomGoldBraid",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, if isTop then 0 else 1),
			Size = UDim2.new(1, -28, 0, 5),
			BackgroundColor3 = Color3.new(1, 1, 1),
			Active = false,
			ZIndex = castButton.ZIndex + 1,
			Parent = castButton,
		})
		Kit.Corner(ropeBar, 3)
		Kit.Gradient(ropeBar, Color3.fromRGB(255, 236, 138), Color3.fromRGB(186, 124, 28))
		Kit.Stroke(ropeBar, Color3.fromRGB(64, 38, 12), 1)
	end

	local castInnerRim = Kit.Frame({
		Name = "InnerHighlight",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -8),
		Active = false,
		ZIndex = castButton.ZIndex + 1,
		Parent = castButton,
	})
	Kit.Corner(castInnerRim, 8)
	local castInnerStroke = Kit.Stroke(castInnerRim, Color3.fromRGB(174, 255, 186), 1.5)
	castInnerStroke.Transparency = 0.22

	if not compact then
		local focusLabel = Kit.Label({
			Name = "FocusLabel",
			Text = "Focus",
			Font = Kit.FontHeavy,
			TextColor3 = Theme.Text,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0, -6),
			Size = UDim2.new(1, 0, 0, 20),
			Active = false,
			Parent = castButton,
		})
		Kit.TextStroke(focusLabel, Theme.PanelDark, 1.5)
	end

	local castTitle = Kit.Label({
		Name = "Title",
		Text = if compact then "CAST" else "[E] CAST",
		Font = Kit.FontHeavy,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = if compact then 27 else 36,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = castButton.ZIndex + 2,
		Parent = castButton,
	})
	Kit.TextStroke(castTitle, Color3.fromRGB(12, 42, 18), 2.2)

	castSubLabel = Kit.Label({
		Text = "",
		Font = Kit.Font,
		TextColor3 = Color3.fromRGB(238, 242, 248),
		TextSize = 13,
		Position = UDim2.new(0, 2, 1, 6),
		BackgroundTransparency = 0.08,
		BackgroundColor3 = Theme.PanelDark,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, -4, 0, 24),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = castButton,
	})
	castSubLabel.TextStrokeTransparency = 1
	Kit.Corner(castSubLabel, 6)
	Kit.Stroke(castSubLabel, Color3.fromRGB(78, 92, 112), 1.5)

	local function refreshCast()
		local state = player:GetAttribute("FishingState")
		if state == "Waiting" then
			castButton.Interactable = true
			finish.Enabled = true
			finish.Color = ColorSequence.new(Color3.fromRGB(242, 159, 56), Color3.fromRGB(184, 90, 24))
			castInnerStroke.Color = Color3.fromRGB(255, 212, 148)
			castInnerStroke.Transparency = 0.22
			castButton.BackgroundColor3 = Color3.new(1, 1, 1)
			castTitle.Text = if compact then "CANCEL" else "[E] CANCEL"
		elseif state == "Biting" then
			castButton.Interactable = false
			finish.Enabled = false
			castInnerStroke.Color = Color3.fromRGB(168, 182, 198)
			castInnerStroke.Transparency = 0.52
			castButton.BackgroundColor3 = Theme.PanelLight
			castTitle.Text = "REELING"
		else
			castButton.Interactable = true
			finish.Enabled = true
			finish.Color = ColorSequence.new(Color3.fromRGB(96, 232, 92), Color3.fromRGB(22, 146, 56))
			castInnerStroke.Color = Color3.fromRGB(174, 255, 186)
			castInnerStroke.Transparency = 0.22
			castButton.BackgroundColor3 = Color3.new(1, 1, 1)
			castTitle.Text = if compact then "CAST" else "[E] CAST"
		end
	end
	refreshCast()
	player:GetAttributeChangedSignal("FishingState"):Connect(refreshCast)
	castButton.Activated:Connect(function()
		local callback = HUDController.OnCastPressed
		if callback and not currentTab then
			callback()
		end
	end)

	-- Bottom centre: riveted navy-steel Navigation Tray with illustrated tiles.
	local menuButtonWidth = if compact then 56 else 76
	local menu = Kit.Panel({
		Name = "Menu",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		-- Narrower buttons in compact mode so the bar fits between thumbstick and jump button.
		Size = UDim2.fromOffset(#TAB_ORDER * (menuButtonWidth + 7) + 12, if compact then 68 else 88),
		Parent = gui,
	})
	Kit.Corner(menu, 12)
	Kit.Gradient(menu, Color3.fromRGB(48, 60, 78), Theme.PanelDark)
	Kit.Trim(menu, Color3.fromRGB(114, 130, 152))

	local trayButtons = Kit.Frame({
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = menu,
	})
	Kit.Padding(trayButtons, 9, 7)
	Kit.List(trayButtons, Enum.FillDirection.Horizontal, 7)

	local tileTopColors = {
		Color3.fromRGB(168, 112, 70), -- Backpack (warm leather)
		Color3.fromRGB(64, 136, 186), -- Rods (ocean blue)
		Color3.fromRGB(186, 116, 62), -- Baits (amber earth)
		Color3.fromRGB(66, 162, 92), -- My Pond (lush green)
		Color3.fromRGB(172, 96, 66), -- Shop (market stall)
	}
	for index, tabName in TAB_ORDER do
		local button = Kit.Button({
			Name = tabName .. "Button", -- stable names so playtests can click by path
			Text = "",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(0, menuButtonWidth, 1, 0),
			LayoutOrder = index,
			Parent = trayButtons,
		})
		Kit.Corner(button, 10)
		local color = tileTopColors[index]
		Kit.Gradient(button, color, color:Lerp(Theme.PanelDark, 0.72))
		local baseRim = color:Lerp(Color3.new(1, 1, 1), 0.32)
		local rim = Kit.Stroke(button, baseRim, 1.5)
		Kit.Gloss(button)
		Kit.HoverScale(button, 1.05)

		gui:GetAttributeChangedSignal("ActiveTab"):Connect(function()
			local active = gui:GetAttribute("ActiveTab") == tabName
			rim.Color = if active then Theme.Gold else baseRim
			rim.Thickness = if active then 3 else 1.5
		end)

		local art = Kit.Frame({
			Name = "Art",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(if compact then 34 else 50, if compact then 34 else 50),
			Parent = button,
		})
		DockArt.Draw(art, tabName)

		local tileLabel = Kit.Label({
			Text = TABS[tabName].title,
			Font = Kit.FontHeavy,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = if compact then 9 else 11,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, -1),
			Size = UDim2.new(1, 0, 0, if compact then 16 else 20),
			Parent = button,
		})
		Kit.TextStroke(tileLabel, Theme.PanelDark, 1.2)

		if tabName == "Backpack" or tabName == "Pond" then
			local badge = Kit.Label({
				Text = "…",
				TextSize = if compact then 9 else 11,
				Font = Kit.FontHeavy,
				TextColor3 = Color3.new(1, 1, 1),
				TextXAlignment = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 4, 0, -4),
				Size = UDim2.fromOffset(if compact then 30 else 36, if compact then 15 else 17),
				BackgroundColor3 = Theme.Danger,
				BackgroundTransparency = 0,
				ZIndex = button.ZIndex + 2,
				Parent = button,
			})
			Kit.Corner(badge, 8)
			Kit.Stroke(badge, Theme.PanelDark, 1.5)
			Kit.TextStroke(badge, Theme.PanelDark, 1.1)
			menuLabels[tabName] = badge
		end
		button.Activated:Connect(function()
			if currentTab == tabName then
				HUDController.ClosePanel()
			else
				HUDController.OpenTab(tabName)
			end
		end)
	end

	-- Centre: management panel.
	panel = ManagementPanel.Create(gui, HUDController.ClosePanel)

	gui.Parent = player:WaitForChild("PlayerGui")
end

-- World prompts (vendors + neighbour feeding) ---------------------------------------------

local function onPromptTriggered(prompt: ProximityPrompt)
	local openPanel = prompt:GetAttribute("OpenPanel")
	if type(openPanel) == "string" then
		HUDController.OpenTab(openPanel)
		return
	end

	if prompt:GetAttribute("Action") == "Bless" then
		local pondModel = prompt:FindFirstAncestorWhichIsA("Model")
		while pondModel and pondModel:GetAttribute("Plot") == nil do
			pondModel = pondModel:FindFirstAncestorWhichIsA("Model")
		end
		local plot = if pondModel then pondModel:GetAttribute("Plot") else nil
		local pond = if type(plot) == "number" then ClientState.Ponds[plot] else nil
		if not pond or pond.ownerUserId == 0 then
			HUDController.Toast("This pond has no owner yet.", "info")
		elseif pond.ownerUserId == player.UserId then
			HUDController.Toast("Visit a neighbour's pond to share a blessing.", "info")
		else
			request("Bless", nil, pond.ownerUserId)
		end
	end
end

function HUDController.Init()
	build()
	refreshGold()
	refreshWeather()
end

function HUDController.Start()
	player:GetAttributeChangedSignal("Gold"):Connect(refreshGold)
	player:GetAttributeChangedSignal("GoldPerSec"):Connect(refreshGold)
	Workspace:GetAttributeChangedSignal("Weather"):Connect(refreshWeather)
	Workspace:GetAttributeChangedSignal("WeatherEndsAt"):Connect(refreshWeatherTimer)
	ClientState.OnState(refreshFromState)
	player:GetAttributeChangedSignal("HeldUid"):Connect(function()
		if currentTab == "Backpack" then
			refreshPanel()
		end
	end)
	-- The Travel tab lists neighbours' ponds, which change as players join and leave.
	ClientState.OnPond(function()
		if currentTab == "Travel" then
			refreshPanel()
		end
	end)

	Net.Event("Notify").OnClientEvent:Connect(function(text: string, kind: string?)
		HUDController.Toast(text, kind)
	end)
	Net.Event("Announce").OnClientEvent:Connect(announce)
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)

	task.spawn(function()
		while true do
			task.wait(1)
			refreshBuffs()
			refreshWeatherTimer()
		end
	end)
end

return HUDController
