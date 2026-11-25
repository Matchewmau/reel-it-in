--!strict
-- Casting input + the reeling minigame overlay + caught fish celebration modal.
--
-- The minigame is simulated here for instant feedback: hold to push your catch
-- zone right, release to let it drift left, keep the fish inside the zone to
-- fill the bar. The server already knows what is on the line and only accepts
-- this client's win/lose report if it is plausible (see FishingService).

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Rarities = require(Shared.Config.Rarities)
local Creatures = require(Shared.Config.Creatures)
local Mutations = require(Shared.Config.Mutations)
local PondConfig = require(Shared.Config.PondConfig)

local HUDController = require(script.Parent.HUDController)
local Kit = require(script.Parent.Parent.UI.Kit)
local ModelPreview = require(script.Parent.Parent.UI.ModelPreview)

type ReelDifficulty = Rarities.ReelDifficulty
type BitePayload = {
	castId: number,
	speciesId: string,
	rarity: Types.Rarity,
	reel: ReelDifficulty,
}

local Theme = Kit.Theme
local player = Players.LocalPlayer

local ZONE_ACCEL = 2.6 -- bar-lengths / s^2
local ZONE_MAX_SPEED = 1.3
local BITE_GRACE = 0.6 -- seconds before progress can drain
local CLIENT_REEL_TIMEOUT = 60
local RESULT_TIME = 8 -- Unattended catches are kept. Casting again keeps one immediately.
local SINK_ACTION = "ReelItInReelSink"

local HOLD_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Space] = true,
	[Enum.KeyCode.E] = true,
	[Enum.KeyCode.ButtonA] = true,
	[Enum.KeyCode.ButtonR2] = true,
}

local PROGRESS_HEALTHY_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(238, 253, 255)),
	ColorSequenceKeypoint.new(0.45, Color3.fromRGB(132, 232, 250)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(58, 178, 224)),
})

local PROGRESS_LOW_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 168, 136)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(242, 86, 72)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(178, 36, 36)),
})

local TENSION_TRACK_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromHex("#2E141A")),
	ColorSequenceKeypoint.new(0.2, Color3.fromHex("#0D1420")),
	ColorSequenceKeypoint.new(0.8, Color3.fromHex("#0D1420")),
	ColorSequenceKeypoint.new(1, Color3.fromHex("#2E141A")),
})

local ZONE_INSIDE_GRADIENT = ColorSequence.new(Color3.fromHex("#52FF88"), Color3.fromHex("#1ED65A"))
local ZONE_OUTSIDE_GRADIENT = ColorSequence.new(Color3.fromHex("#26D45C"), Color3.fromHex("#138A38"))
local ZONE_EDGE_OUTSIDE = Color3.fromHex("#B8FFD0")
local ZONE_EDGE_INSIDE = Color3.fromHex("#FFFFFF")
local FISH_OUTSIDE_STROKE = Color3.fromHex("#0A101A")
local FISH_INSIDE_STROKE = Color3.fromHex("#FFFFFF")
local TEXT_INK = Color3.fromRGB(14, 19, 28)

local HOVER_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local ReelController = {}

local rng = Random.new()
type State = "Idle" | "Casting" | "Waiting" | "Reeling" | "Result"
local state: State = "Idle"
local castId = 0
local heldInputs = 0
local promptsShown = 0
local reelConnection: RBXScriptConnection? = nil

local gui: ScreenGui
local statusLabel: TextLabel

-- Reeling HUD refs
local reelFrame: Frame
local reelTitle: TextLabel
local reelBannerAccent: UIStroke
local progressLabel: TextLabel
local progressFill: Frame
local progressGradient: UIGradient
local track: Frame
local zoneFrame: Frame
local zoneGradient: UIGradient
local zoneStroke: UIStroke
local zoneLeftEdge: Frame
local zoneRightEdge: Frame
local fishNeedle: Frame
local fishMarker: Frame
local fishMarkerScale: UIScale
local fishMarkerStroke: UIStroke

-- Catch celebration modal refs
local card: Frame
local cardScale: UIScale
local previewGlow: Frame
local previewOuterStroke: UIStroke
local previewMountGradient: UIGradient
local previewStroke: UIStroke
local cardBanner: TextLabel
local cardTag: TextLabel
local cardTagStroke: UIStroke
local colossalBadge: TextLabel
local cardName: TextLabel
local cardDetail: TextLabel
local cardIncome: TextLabel
local cardPreview: Frame
local keepButton: TextButton
local sellButton: TextButton
local saleLabel: TextLabel

local catchUid: string? = nil
local selling = false
local previousSelection: GuiObject? = nil

type SavedMovement = {
	humanoid: Humanoid,
	walkSpeed: number,
	jumpPower: number,
	jumpHeight: number,
	useJumpPower: boolean,
}
local savedMovement: SavedMovement? = nil

local function setMovementLocked(locked: boolean)
	if locked then
		if savedMovement then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end
		savedMovement = {
			humanoid = humanoid,
			walkSpeed = humanoid.WalkSpeed,
			jumpPower = humanoid.JumpPower,
			jumpHeight = humanoid.JumpHeight,
			useJumpPower = humanoid.UseJumpPower,
		}
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
	else
		local saved = savedMovement
		savedMovement = nil
		if saved and saved.humanoid.Parent then
			saved.humanoid.UseJumpPower = saved.useJumpPower
			saved.humanoid.WalkSpeed = saved.walkSpeed
			saved.humanoid.JumpPower = saved.jumpPower
			saved.humanoid.JumpHeight = saved.jumpHeight
		end
	end
end

-- Reads `state` without the analyzer narrowing it to whatever the enclosing
-- function last assigned (deferred callbacks run after it has changed).
local function inState(expected: State): boolean
	return state == expected
end

local function setStatus(text: string?)
	statusLabel.Text = text or ""
	statusLabel.Visible = text ~= nil
end

local function isHoldInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
		or HOLD_KEYS[input.KeyCode] == true
end

-- Catch reveal ------------------------------------------------------------------------

local function dismissCatch()
	if selling or not catchUid then
		return
	end
	if GuiService.SelectedObject == keepButton or GuiService.SelectedObject == sellButton then
		GuiService.SelectedObject = if previousSelection and previousSelection.Parent then previousSelection else nil
	end
	previousSelection = nil
	catchUid = nil
	card.Visible = false
	cardPreview:ClearAllChildren()
	state = "Idle"
end

local function sellCatch()
	local uid = catchUid
	if selling or not uid then
		return
	end
	selling = true
	local priceLabel = saleLabel.Text
	saleLabel.Text = "SELLING…"
	local response = Net.Invoke("SellCreature", uid)
	selling = false
	saleLabel.Text = priceLabel
	if response.ok then
		dismissCatch()
		HUDController.Toast(`Sold for {Format.Number(response.gold)} Gold.`, "good")
	else
		HUDController.Toast(tostring(response.error or "Couldn't sell this catch."), "bad")
		if HUDController.IsPanelOpen() then
			dismissCatch()
		end
	end
end

local function celebrateCatch(rarityColor: Color3, count: number)
	local colors = {
		Theme.Gold,
		rarityColor,
		Color3.fromRGB(85, 224, 212),
		Color3.fromRGB(255, 134, 152),
		Color3.fromRGB(255, 244, 168),
	}
	for i = 1, count do
		local side = if i % 2 == 0 then -1 else 1
		local startX = 0.5 + side * rng:NextNumber(0.06, 0.44)
		local startY = rng:NextNumber(0.02, 0.22)
		local w = rng:NextInteger(5, 8)
		local h = rng:NextInteger(7, 12)
		local fleck = Kit.Frame({
			Name = "Confetti",
			BackgroundColor3 = colors[(i - 1) % #colors + 1],
			Position = UDim2.fromScale(startX, startY),
			Size = UDim2.fromOffset(w, h),
			Rotation = rng:NextNumber(-75, 75),
			ZIndex = 20,
			Parent = card,
		})
		Kit.Corner(fleck, 2)
		local duration = rng:NextNumber(0.65, 1.15)
		local driftX = side * rng:NextNumber(0.06, 0.2)
		local dropY = rng:NextNumber(0.32, 0.56)
		TweenService:Create(fleck, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(startX + driftX, startY + dropY),
			Rotation = fleck.Rotation + side * rng:NextNumber(120, 260),
			BackgroundTransparency = 1,
		}):Play()
		Debris:AddItem(fleck, duration)
	end
end

local function showCatch(response: { [string]: any })
	local creature = response.creature :: Types.CreatureInstance
	local species = Creatures.Get(creature.speciesId)
	if not species then
		state = "Idle"
		return
	end
	local info = Rarities.Get(species.rarity)
	local mutation = Mutations.Get(creature.mutation)

	catchUid = creature.uid
	if creature.colossal then
		cardBanner.Text = "★ COLOSSAL CATCH! ★"
	elseif response.isNew then
		cardBanner.Text = "YOU CAUGHT A NEW CREATURE!"
	else
		cardBanner.Text = "YOU LANDED A CATCH!"
	end

	cardTag.Text = string.upper(species.rarity)
	cardTag.TextColor3 = info.color
	cardTagStroke.Color = info.color
	colossalBadge.Visible = creature.colossal

	cardName.Text = species.name
	local details = { `[{species.rarity}]`, Format.Weight(creature.weight) }
	if creature.mutation ~= "Normal" then
		table.insert(details, `{mutation.name} ×{mutation.multiplier}`)
	end
	cardDetail.Text = table.concat(details, "  •  ")
	cardIncome.Text = `{Format.Rate(response.goldPerSec :: number)} in your pond`

	previewGlow.BackgroundColor3 = info.color
	previewOuterStroke.Color = if creature.colossal then Theme.Gold else info.color
	previewStroke.Color = info.color:Lerp(Color3.new(1, 1, 1), 0.45)
	previewMountGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, info.color:Lerp(Color3.fromRGB(64, 74, 94), 0.55)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(48, 56, 72)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 30, 42)),
	})
	saleLabel.Text = `SELL FOR {Format.Number(PondConfig.SellValue(creature))}g`

	-- Spinning 3D model of the catch, in its mutation colours.
	cardPreview:ClearAllChildren()
	local preview = ModelPreview.Create({ kind = "Creature", id = species.id, mutation = creature.mutation })
	preview.Size = UDim2.fromScale(1, 1)
	preview.Parent = cardPreview
	ModelPreview.SetSpin(preview, true)

	card.Visible = true
	local isRarePlus = Rarities.IsAtLeast(species.rarity, "Rare")
	local isLegendaryPlus = Rarities.IsAtLeast(species.rarity, "Legendary")
	if creature.colossal or isLegendaryPlus then
		celebrateCatch(if creature.colossal then Theme.Gold else info.color, 30)
	elseif isRarePlus then
		celebrateCatch(info.color, 20)
	elseif response.isNew then
		celebrateCatch(info.color, 14)
	end

	if string.find(UserInputService:GetLastInputType().Name, "Gamepad") then
		previousSelection = GuiService.SelectedObject
		GuiService.SelectedObject = keepButton
	end
	cardScale.Scale = 0.65
	TweenService:Create(cardScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	-- Unattended catches stay in the backpack. Leave the choice open for gamepad focus.
	task.delay(RESULT_TIME, function()
		if
			catchUid == creature.uid
			and GuiService.SelectedObject ~= keepButton
			and GuiService.SelectedObject ~= sellButton
		then
			dismissCatch()
		end
	end)
end

-- Minigame ----------------------------------------------------------------------------

local function finishReel(success: boolean)
	if state ~= "Reeling" then
		return
	end
	state = "Result"
	setMovementLocked(false)
	ContextActionService:UnbindAction(SINK_ACTION)
	if reelConnection then
		reelConnection:Disconnect()
		reelConnection = nil
	end
	reelFrame.Visible = false

	local response = Net.Invoke("ReelFinish", castId, success)
	if response.ok and response.caught then
		showCatch(response)
	else
		HUDController.Toast(if success then "The line snapped!" else "It got away...", "bad")
		task.wait(0.6)
		state = "Idle"
	end
end

local function startReel(payload: BitePayload)
	local species = Creatures.Get(payload.speciesId)
	local info = Rarities.Get(payload.rarity)
	local reel = payload.reel

	state = "Reeling"
	HUDController.ClosePanel()
	heldInputs = 0
	-- Swallow the hold keys while reeling so Space doesn't also make the character
	-- jump. UserInputService still reports them (as processed), which is what the
	-- hold tracking below listens to.
	ContextActionService:BindActionAtPriority(
		SINK_ACTION,
		function(): Enum.ContextActionResult
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Space,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.ButtonR2
	)
	setStatus(nil)
	reelTitle.Text =
		`REELING: {string.upper(if species then species.name else "Unknown")} ({string.upper(payload.rarity)})`
	reelBannerAccent.Color = info.color
	zoneFrame.Size = UDim2.fromScale(reel.zoneSize, 1)
	zoneFrame.BackgroundTransparency = 0.03
	zoneStroke.Color = ZONE_EDGE_OUTSIDE
	zoneStroke.Thickness = 2.5
	zoneLeftEdge.BackgroundColor3 = ZONE_EDGE_OUTSIDE
	zoneRightEdge.BackgroundColor3 = ZONE_EDGE_OUTSIDE
	fishMarkerStroke.Color = FISH_OUTSIDE_STROKE
	fishNeedle.BackgroundColor3 = Color3.fromHex("#FFD45C")
	progressGradient.Color = PROGRESS_HEALTHY_GRADIENT
	zoneGradient.Color = ZONE_OUTSIDE_GRADIENT
	fishMarkerScale.Scale = 1
	reelFrame.Visible = true

	local fishPos = 0.5
	local fishTarget = 0.5
	local fishSpeed = reel.fishSpeed
	local retargetIn = 0.4
	local zonePos = 0.5
	local zoneVel = 0
	local progress = reel.startProgress
	local startedAt = os.clock()
	local half = reel.zoneSize / 2
	local wasInside = false
	local wasLow = false
	local markerScale = 1

	reelConnection = RunService.RenderStepped:Connect(function(dt: number)
		local elapsed = os.clock() - startedAt

		-- Fish: wanders between random targets, sometimes dashing.
		retargetIn -= dt
		if retargetIn <= 0 then
			local dash = rng:NextNumber() < reel.dashChance
			fishTarget = rng:NextNumber(0.04, 0.96)
			fishSpeed = reel.fishSpeed * (if dash then 2.2 else rng:NextNumber(0.5, 1))
			retargetIn = rng:NextNumber(reel.retargetMin, reel.retargetMax)
		end
		fishPos += math.clamp(fishTarget - fishPos, -fishSpeed * dt, fishSpeed * dt)
		local shownFish = math.clamp(fishPos + math.sin(elapsed * 18) * reel.thrash, 0, 1)

		-- Player zone: hold accelerates right, release accelerates left.
		zoneVel = math.clamp(
			zoneVel + (if heldInputs > 0 then ZONE_ACCEL else -ZONE_ACCEL) * dt,
			-ZONE_MAX_SPEED,
			ZONE_MAX_SPEED
		)
		zonePos += zoneVel * dt
		if zonePos < half then
			zonePos = half
			zoneVel = 0
		elseif zonePos > 1 - half then
			zonePos = 1 - half
			zoneVel = 0
		end

		local inside = math.abs(shownFish - zonePos) <= half
		if inside then
			progress += reel.gainRate * dt
		elseif elapsed > BITE_GRACE then
			progress -= reel.drainRate * dt
		end

		-- Micro-juice: crisp scale pop on entering the green zone + pulsing border glow.
		if inside ~= wasInside then
			wasInside = inside
			zoneGradient.Color = if inside then ZONE_INSIDE_GRADIENT else ZONE_OUTSIDE_GRADIENT
			zoneFrame.BackgroundTransparency = if inside then 0 else 0.03
			local edgeColor = if inside then ZONE_EDGE_INSIDE else ZONE_EDGE_OUTSIDE
			zoneLeftEdge.BackgroundColor3 = edgeColor
			zoneRightEdge.BackgroundColor3 = edgeColor
			fishMarkerStroke.Color = if inside then FISH_INSIDE_STROKE else FISH_OUTSIDE_STROKE
			fishNeedle.BackgroundColor3 = if inside then FISH_INSIDE_STROKE else Color3.fromHex("#FFD45C")
			if inside then
				markerScale = 1.15
			end
		end
		local targetScale = if inside then 1.05 else 1.0
		markerScale += (targetScale - markerScale) * math.min(1, dt * 14)
		fishMarkerScale.Scale = markerScale

		if inside then
			local pulse = 0.5 + 0.5 * math.sin(elapsed * 12)
			zoneStroke.Color = ZONE_EDGE_INSIDE
			zoneStroke.Thickness = 3.0 + pulse * 0.6
		else
			zoneStroke.Color = ZONE_EDGE_OUTSIDE
			zoneStroke.Thickness = 2.5
		end

		zoneFrame.Position = UDim2.fromScale(zonePos, 0.5)
		fishNeedle.Position = UDim2.fromScale(shownFish, 0.5)
		fishMarker.Position = UDim2.fromScale(shownFish, 0.5)

		local clampedProgress = math.clamp(progress, 0, 1)
		progressFill.Size = UDim2.fromScale(clampedProgress, 1)
		local isLow = clampedProgress < 0.25
		if isLow ~= wasLow then
			wasLow = isLow
			progressGradient.Color = if isLow then PROGRESS_LOW_GRADIENT else PROGRESS_HEALTHY_GRADIENT
		end
		progressLabel.Text = `Progress/Distance  {math.floor(clampedProgress * 100)}%`

		if progress >= 1 then
			task.spawn(finishReel, true)
		elseif progress <= 0 or elapsed > CLIENT_REEL_TIMEOUT then
			task.spawn(finishReel, false)
		end
	end)
end

-- Casting -----------------------------------------------------------------------------

local function cancelCast()
	if state ~= "Waiting" then
		return
	end
	state = "Idle"
	setMovementLocked(false)
	setStatus(nil)
	Net.Invoke("CancelCast")
	HUDController.Toast("Line reeled in.", "info")
end

local function tryCast()
	if state == "Waiting" then
		cancelCast()
		return
	end
	if catchUid and not selling then
		dismissCatch()
	end
	if state ~= "Idle" then
		return
	end
	state = "Casting"
	setMovementLocked(true)
	setStatus("Casting...")

	local response = Net.Invoke("Cast")
	if not response.ok then
		HUDController.Toast(tostring(response.error or "You can't cast right now."), "bad")
		setMovementLocked(false)
		setStatus(nil)
		state = "Idle"
		return
	end

	castId = response.castId
	state = "Waiting"
	setStatus(`Line's in the {string.lower(tostring(response.biome))}... Press [E] to cancel`)
	if response.baitId == nil then
		HUDController.Toast("No matching bait: casting a bare hook (less luck).", "info")
	end

	-- Safety net: if the bite never arrives, don't strand the player in Waiting.
	local thisCast = castId
	task.delay((response.biteDelay :: number) + 8, function()
		if inState("Waiting") and castId == thisCast then
			setMovementLocked(false)
			setStatus(nil)
			state = "Idle"
		end
	end)
end

-- Construction ------------------------------------------------------------------------

local function centeredText(
	parent: Instance,
	name: string,
	text: string,
	position: UDim2,
	size: UDim2,
	fontSize: number,
	strokeThickness: number?,
	font: Enum.Font?
): TextLabel
	local label = Kit.Label({
		Name = name,
		Text = text,
		Position = position,
		Size = size,
		TextSize = fontSize,
		Font = font or Kit.FontHeavy,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		TextStrokeTransparency = 1,
		Parent = parent,
	})
	if strokeThickness and strokeThickness > 0 then
		Kit.TextStroke(label, TEXT_INK, strokeThickness)
	end
	return label
end

-- Small drawn fish silhouette used both on the progress bar and inside FishMarker.
local function addFishIcon(parent: Instance, color: Color3, eyeColor: Color3, scale: number)
	local holder = Kit.Frame({
		Name = "FishSilhouette",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(math.floor(18 * scale), math.floor(11 * scale)),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	local tail = Kit.Frame({
		Name = "Tail",
		Rotation = 45,
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.18, 0.5),
		Size = UDim2.fromOffset(math.floor(6 * scale), math.floor(6 * scale)),
		Parent = holder,
	})
	Kit.Corner(tail, 1)
	local body = Kit.Frame({
		Name = "Body",
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.62, 0.5),
		Size = UDim2.fromOffset(math.floor(13 * scale), math.floor(9 * scale)),
		Parent = holder,
	})
	Kit.Corner(body, 5)
	local eye = Kit.Frame({
		Name = "Eye",
		BackgroundColor3 = eyeColor,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.76, 0.38),
		Size = UDim2.fromOffset(math.max(2, math.floor(2.4 * scale)), math.max(2, math.floor(2.4 * scale))),
		Parent = body,
	})
	Kit.Corner(eye, 2)
end

local function ribbonBanner(
	parent: Frame,
	width: number,
	height: number,
	fontSize: number,
	withRibbonTails: boolean,
	strokeThickness: number
): (TextLabel, UIStroke)
	local woodDark = Color3.fromRGB(76, 46, 20)
	if withRibbonTails then
		for _, side in { -1, 1 } do
			local tail = Kit.Frame({
				Name = if side < 0 then "RibbonTailL" else "RibbonTailR",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, side * (width * 0.5 - 4), 0, 5),
				Size = UDim2.fromOffset(22, height - 10),
				Rotation = side * 8,
				ZIndex = 2,
				Parent = parent,
			})
			Kit.Corner(tail, 4)
			Kit.Gradient(tail, Color3.fromRGB(196, 134, 52), Color3.fromRGB(118, 68, 22))
			Kit.Stroke(tail, woodDark, 2)
		end
	end

	local plate = Kit.Frame({
		Name = "BrassPlaque",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 4,
		Parent = parent,
	})
	Kit.Corner(plate, 8)
	Kit.Stroke(plate, woodDark, 3)
	Kit.Gradient(plate, Color3.fromRGB(252, 212, 118), Color3.fromRGB(154, 92, 32))

	local innerRim = Kit.Frame({
		Name = "AccentRim",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = plate,
	})
	Kit.Corner(innerRim, 5)
	local accentStroke = Kit.Stroke(innerRim, Color3.fromRGB(255, 232, 152), 1.8)

	local heading =
		centeredText(plate, "Heading", "", UDim2.fromOffset(10, 0), UDim2.new(1, -20, 1, 0), fontSize, strokeThickness)
	heading.ZIndex = 6
	return heading, accentStroke
end

local function attachHoverScale(button: TextButton)
	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = button
	local hovered = false

	button.MouseEnter:Connect(function()
		hovered = true
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.04 }):Play()
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 0.97 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = if hovered then 1.04 else 1 }):Play()
	end)
end

local function addBrassCornerBrackets(parent: Frame, brass: Color3, darkWood: Color3)
	for _, corner in
		{
			{ x = 0, y = 0, dx = -3, dy = -3 },
			{ x = 1, y = 0, dx = 3, dy = -3 },
			{ x = 0, y = 1, dx = -3, dy = 3 },
			{ x = 1, y = 1, dx = 3, dy = 3 },
		}
	do
		local bracket = Kit.Frame({
			Name = "BrassBracket",
			AnchorPoint = Vector2.new(corner.x, corner.y),
			Position = UDim2.new(corner.x, corner.dx, corner.y, corner.dy),
			Size = UDim2.fromOffset(14, 14),
			ZIndex = 3,
			Parent = parent,
		})
		Kit.Corner(bracket, 4)
		Kit.Gradient(bracket, Color3.fromRGB(246, 206, 118), brass)
		Kit.Stroke(bracket, darkWood, 1.5)
	end
end

local function build()
	gui = Kit.ScreenGui("Reel", 20)
	Kit.AutoScale(gui)
	local compact = Kit.IsCompact()
	local brass = Color3.fromRGB(205, 158, 80)
	local darkWood = Color3.fromRGB(72, 44, 18)
	local steel = Color3.fromRGB(118, 134, 152)
	local dark = Color3.fromRGB(19, 25, 37)
	local bottom = if compact then 78 else 112

	statusLabel = centeredText(
		gui,
		"LineStatus",
		"",
		UDim2.new(0.5, 0, 1, -bottom),
		UDim2.fromOffset(if compact then 332 else 430, 34),
		if compact then 15 else 17,
		1.4
	)
	statusLabel.AnchorPoint = Vector2.new(0.5, 1)
	statusLabel.BackgroundTransparency = 0.08
	statusLabel.BackgroundColor3 = dark
	statusLabel.Visible = false
	Kit.Corner(statusLabel, 12)
	Kit.Stroke(statusLabel, brass, 1.5)

	-- Reeling Minigame Meter (reference/fishing.jpeg) ---------------------------------
	local reelWidth = if compact then 368 else 548
	local reelHeight = if compact then 124 else 156
	reelFrame = Kit.Frame({
		Name = "ReelMeter",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -bottom),
		Size = UDim2.fromOffset(reelWidth, reelHeight),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Visible = false,
		Parent = gui,
	})
	Kit.Corner(reelFrame, 12)
	Kit.Gradient(reelFrame, Color3.fromRGB(48, 60, 78), Color3.fromRGB(17, 23, 35))
	Kit.Trim(reelFrame, steel)
	reelTitle, reelBannerAccent = ribbonBanner(
		reelFrame,
		reelWidth - (if compact then 28 else 64),
		if compact then 26 else 32,
		if compact then 13 else 16,
		false,
		1.4
	)
	reelTitle.TextColor3 = Color3.fromRGB(255, 245, 206)

	local inset = if compact then 16 else 24
	local iconSlot = if compact then 22 else 28
	local progressY = if compact then 21 else 28
	local progressH = if compact then 15 else 19

	-- Left fish icon flanking the progress bar
	local leftIcon = Kit.Frame({
		Name = "ProgressFishIcon",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(inset, progressY - 2),
		Size = UDim2.fromOffset(iconSlot, progressH + 4),
		Parent = reelFrame,
	})
	addFishIcon(leftIcon, Color3.fromRGB(224, 234, 242), dark, if compact then 0.95 else 1.15)

	-- Right hook icon flanking the progress bar (procedural J-hook so every font renders it cleanly)
	local hookColor = Color3.fromRGB(224, 234, 242)
	local rightHook = Kit.Frame({
		Name = "ProgressHookIcon",
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -(inset + iconSlot), 0, progressY - 2),
		Size = UDim2.fromOffset(iconSlot, progressH + 4),
		Parent = reelFrame,
	})
	local hookScale = if compact then 0.85 else 1.05
	local hookEye = Kit.Frame({
		Name = "Eye",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.58, 0.08),
		Size = UDim2.fromOffset(math.floor(5 * hookScale), math.floor(5 * hookScale)),
		Parent = rightHook,
	})
	Kit.Corner(hookEye, 4)
	Kit.Stroke(hookEye, hookColor, 2)
	local shank = Kit.Frame({
		Name = "Shank",
		BackgroundColor3 = hookColor,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.58, 0.28),
		Size = UDim2.fromOffset(2, math.floor(11 * hookScale)),
		Parent = rightHook,
	})
	Kit.Corner(shank, 1)
	local bend = Kit.Frame({
		Name = "Bend",
		BackgroundColor3 = hookColor,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(0.62, 0.88),
		Size = UDim2.fromOffset(math.floor(8 * hookScale), 2),
		Parent = rightHook,
	})
	Kit.Corner(bend, 2)
	local point = Kit.Frame({
		Name = "Point",
		BackgroundColor3 = hookColor,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0.28, 0.88),
		Size = UDim2.fromOffset(2, math.floor(6 * hookScale)),
		Parent = rightHook,
	})
	Kit.Corner(point, 1)
	local barb = Kit.Frame({
		Name = "Barb",
		BackgroundColor3 = hookColor,
		Rotation = 35,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.35, 0.62),
		Size = UDim2.fromOffset(4, 2),
		Parent = rightHook,
	})
	Kit.Corner(barb, 1)

	local barInset = inset + iconSlot + 6
	local progressBack = Kit.Frame({
		Name = "Progress",
		BackgroundColor3 = Color3.fromRGB(14, 20, 30),
		Position = UDim2.fromOffset(barInset, progressY),
		Size = UDim2.new(1, -2 * barInset, 0, progressH),
		ClipsDescendants = true,
		Parent = reelFrame,
	})
	Kit.Corner(progressBack, 8)
	Kit.Stroke(progressBack, steel, 2)
	progressFill = Kit.Frame({
		Name = "ProgressFill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(0.35, 1),
		Parent = progressBack,
	})
	Kit.Corner(progressFill, 7)
	progressGradient = Instance.new("UIGradient")
	progressGradient.Rotation = 90
	progressGradient.Color = PROGRESS_HEALTHY_GRADIENT
	progressGradient.Parent = progressFill

	progressLabel = centeredText(
		reelFrame,
		"ProgressValue",
		"",
		UDim2.fromOffset(0, if compact then 39 else 51),
		UDim2.new(1, 0, 0, if compact then 17 else 21),
		if compact then 12 else 14,
		1.4
	)
	progressLabel.TextColor3 = Color3.fromRGB(255, 224, 128)

	-- Catch / Tension Track
	local trackY = if compact then 60 else 77
	local trackH = if compact then 28 else 38
	track = Kit.Frame({
		Name = "TensionTrack",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.fromOffset(inset, trackY),
		Size = UDim2.new(1, -2 * inset, 0, trackH),
		Parent = reelFrame,
	})
	Kit.Corner(track, 9)
	Kit.Stroke(track, steel, 2)
	local trackGradient = Instance.new("UIGradient")
	trackGradient.Rotation = 0
	trackGradient.Color = TENSION_TRACK_GRADIENT
	trackGradient.Parent = track

	-- Crisp dark recessed inner rim so the empty track reads as a deep channel.
	local trackRecess = Kit.Frame({
		Name = "InnerShadow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -2, 1, -2),
		BackgroundTransparency = 1,
		Parent = track,
	})
	Kit.Corner(trackRecess, 8)
	Kit.Stroke(trackRecess, Color3.fromHex("#060A11"), 1.5)

	-- Unclipped track container: zonePos is clamped to [half, 1 - half] so CatchZone
	-- never overflows horizontally, and leaving ClipsDescendants false keeps all 4
	-- sides of zoneStroke crisp and visible.
	local trackClip = Kit.Frame({
		Name = "TrackClip",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = track,
	})
	Kit.Corner(trackClip, 8)

	for tick = 1, 15 do
		Kit.Frame({
			Name = "Tick",
			Position = UDim2.fromScale(tick / 16, 0.16),
			Size = UDim2.new(0, 1, 0.68, 0),
			BackgroundColor3 = Color3.fromHex("#26354A"),
			BackgroundTransparency = 0.25,
			Parent = trackClip,
		})
	end

	zoneFrame = Kit.Frame({
		Name = "CatchZone",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.03,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.3, 1),
		ZIndex = 2,
		Parent = trackClip,
	})
	Kit.Corner(zoneFrame, 6)
	zoneStroke = Kit.Stroke(zoneFrame, ZONE_EDGE_OUTSIDE, 2.5)
	zoneGradient = Instance.new("UIGradient")
	zoneGradient.Rotation = 90
	zoneGradient.Color = ZONE_OUTSIDE_GRADIENT
	zoneGradient.Parent = zoneFrame

	local zoneGloss = Kit.Frame({
		Name = "Gloss",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.78,
		Position = UDim2.fromOffset(3, 2),
		Size = UDim2.new(1, -6, 0.42, 0),
		ZIndex = 3,
		Active = false,
		Parent = zoneFrame,
	})
	Kit.Corner(zoneGloss, 4)

	zoneLeftEdge = Kit.Frame({
		Name = "LeftEdge",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.new(0, 3, 1, -4),
		BackgroundColor3 = ZONE_EDGE_OUTSIDE,
		ZIndex = 3,
		Active = false,
		Parent = zoneFrame,
	})
	Kit.Corner(zoneLeftEdge, 2)

	zoneRightEdge = Kit.Frame({
		Name = "RightEdge",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -2, 0.5, 0),
		Size = UDim2.new(0, 3, 1, -4),
		BackgroundColor3 = ZONE_EDGE_OUTSIDE,
		ZIndex = 3,
		Active = false,
		Parent = zoneFrame,
	})
	Kit.Corner(zoneRightEdge, 2)

	fishNeedle = Kit.Frame({
		Name = "FishNeedle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 2, 1, 8),
		BackgroundColor3 = Color3.fromHex("#FFD45C"),
		ZIndex = 3,
		Active = false,
		Parent = track,
	})
	Kit.Corner(fishNeedle, 1)
	Kit.Stroke(fishNeedle, FISH_OUTSIDE_STROKE, 1)

	fishMarker = Kit.Frame({
		Name = "FishMarker",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(if compact then 28 else 34, if compact then 34 else 44),
		ZIndex = 4,
		Parent = track,
	})
	Kit.Corner(fishMarker, 11)
	fishMarkerStroke = Kit.Stroke(fishMarker, FISH_OUTSIDE_STROKE, 2.5)
	Kit.Gradient(fishMarker, Color3.fromHex("#FFFDF0"), Color3.fromHex("#FFD45C"))
	fishMarkerScale = Instance.new("UIScale")
	fishMarkerScale.Scale = 1
	fishMarkerScale.Parent = fishMarker
	addFishIcon(fishMarker, Color3.fromHex("#101A28"), Color3.fromHex("#FFFDF0"), if compact then 0.98 else 1.16)

	local hint = centeredText(
		reelFrame,
		"Controls",
		if compact
			then "HOLD →  •  RELEASE ←  •  keep the fish in the green zone"
			else "HOLD to pull right  •  RELEASE to drift left  •  keep the fish in the green zone",
		UDim2.fromOffset(8, if compact then 96 else 124),
		UDim2.new(1, -16, 0, 22),
		if compact then 13 else 14,
		0,
		Kit.Font
	)
	hint.TextColor3 = Color3.fromHex("#F4F7FC")

	-- Caught Fish Celebration Modal (reference/caught fish.jpeg) ----------------------
	local width = if compact then 346 else 442
	local height = if compact then 274 else 364
	card = Kit.Frame({
		Name = "CatchCard",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.46),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Visible = false,
		Parent = gui,
	})
	Kit.Corner(card, 14)
	Kit.Gradient(card, Color3.fromRGB(46, 54, 70), Color3.fromRGB(17, 22, 34))
	Kit.Trim(card, brass)
	addBrassCornerBrackets(card, brass, darkWood)
	cardScale = Instance.new("UIScale")
	cardScale.Parent = card

	cardBanner = ribbonBanner(
		card,
		width - (if compact then 26 else 36),
		if compact then 40 else 54,
		if compact then 17 else 22,
		true,
		2
	)
	cardBanner.TextColor3 = Color3.fromRGB(255, 244, 196)

	-- Soft rarity glow halo behind the SpecimenMount
	previewGlow = Kit.Frame({
		Name = "SpecimenGlow",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.115),
		Size = UDim2.fromScale(0.67, 0.365),
		BackgroundColor3 = Theme.Gold,
		BackgroundTransparency = 0.72,
		ZIndex = 1,
		Parent = card,
	})
	Kit.Corner(previewGlow, 15)

	local mount = Kit.Frame({
		Name = "SpecimenMount",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.125),
		Size = UDim2.fromScale(0.63, 0.345),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 2,
		Parent = card,
	})
	Kit.Corner(mount, 12)
	previewOuterStroke = Kit.Stroke(mount, brass, 3)
	previewMountGradient = Instance.new("UIGradient")
	previewMountGradient.Rotation = 90
	previewMountGradient.Color = ColorSequence.new(Color3.fromRGB(92, 102, 120), Color3.fromRGB(32, 38, 52))
	previewMountGradient.Parent = mount

	-- Crisp inner metallic border (double-border look)
	local innerBorder = Kit.Frame({
		Name = "InnerBorder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = mount,
	})
	Kit.Corner(innerBorder, 9)
	previewStroke = Kit.Stroke(innerBorder, Color3.fromRGB(218, 228, 240), 1.5)

	cardPreview = Kit.Frame({
		Name = "Specimen",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = mount,
	})

	-- Overlapping Rarity Pill Badge centered on the bottom edge of the preview frame
	cardTag = centeredText(
		mount,
		"Rarity",
		"",
		UDim2.fromScale(0.5, 1),
		UDim2.fromOffset(if compact then 110 else 128, if compact then 22 else 26),
		if compact then 12 else 14,
		1.4
	)
	cardTag.AnchorPoint = Vector2.new(0.5, 0.5)
	cardTag.BackgroundTransparency = 0
	cardTag.BackgroundColor3 = Color3.fromRGB(20, 26, 38)
	cardTag.ZIndex = 6
	Kit.Corner(cardTag, 8)
	cardTagStroke = Kit.Stroke(cardTag, steel, 2)

	-- Bright gold Colossal pill badge at the top-right of the preview frame
	colossalBadge = centeredText(
		mount,
		"ColossalBadge",
		"★ COLOSSAL ★",
		UDim2.new(1, 6, 0, -4),
		UDim2.fromOffset(if compact then 104 else 120, if compact then 22 else 25),
		if compact then 11 else 13,
		0
	)
	colossalBadge.AnchorPoint = Vector2.new(0.85, 0.25)
	colossalBadge.BackgroundTransparency = 0
	colossalBadge.TextColor3 = Color3.fromRGB(48, 26, 6)
	colossalBadge.Visible = false
	colossalBadge.ZIndex = 7
	Kit.Corner(colossalBadge, 8)
	Kit.Gradient(colossalBadge, Color3.fromRGB(255, 232, 112), Color3.fromRGB(222, 148, 28))
	Kit.Stroke(colossalBadge, darkWood, 2)

	cardName = centeredText(
		card,
		"Species",
		"",
		UDim2.fromScale(0.03, 0.515),
		UDim2.fromScale(0.94, 0.105),
		if compact then 24 else 32,
		2
	)
	cardName.TextColor3 = Color3.fromRGB(255, 214, 86)

	cardDetail = centeredText(
		card,
		"CatchDetails",
		"",
		UDim2.fromScale(0.03, 0.62),
		UDim2.fromScale(0.94, 0.072),
		if compact then 15 else 17,
		0,
		Kit.Font
	)
	cardDetail.TextColor3 = Color3.fromRGB(234, 238, 244)

	cardIncome = centeredText(
		card,
		"PondIncome",
		"",
		UDim2.fromScale(0.14, 0.71),
		UDim2.fromScale(0.72, 0.092),
		if compact then 15 else 19,
		1.4
	)
	cardIncome.BackgroundTransparency = 0
	cardIncome.BackgroundColor3 = Color3.fromRGB(16, 22, 34)
	cardIncome.TextColor3 = Theme.Gold
	Kit.Corner(cardIncome, 10)
	Kit.Stroke(cardIncome, brass, 1.8)

	local function action(name: string, x: number, top: Color3, base: Color3, borderColor: Color3): TextButton
		local button = Kit.Button({
			Name = name,
			Text = "",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(x, 0, 1, -10),
			Size = UDim2.new(0.43, 0, 0, Kit.Compact.ButtonHeight),
			BackgroundColor3 = Color3.new(1, 1, 1),
			ZIndex = 4,
			Parent = card,
		})
		Kit.Corner(button, 10)
		Kit.Gradient(button, top, base)
		Kit.Stroke(button, borderColor, 2.2)

		-- Subtle glossy top highlight strip
		local gloss = Kit.Frame({
			Name = "Gloss",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 3),
			Size = UDim2.new(1, -10, 0.38, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.76,
			ZIndex = 5,
			Parent = button,
		})
		Kit.Corner(gloss, 6)

		attachHoverScale(button)
		return button
	end

	keepButton =
		action("Keep", 0.27, Color3.fromRGB(98, 214, 88), Color3.fromRGB(30, 118, 52), Color3.fromRGB(34, 72, 34))
	sellButton = action("Sell", 0.73, Color3.fromRGB(255, 200, 78), Color3.fromRGB(172, 98, 24), darkWood)

	local keepCaption = centeredText(
		keepButton,
		"Caption",
		"KEEP",
		UDim2.fromOffset(0, 0),
		UDim2.fromScale(1, 1),
		if compact then 16 else 20,
		1.4
	)
	keepCaption.ZIndex = 6
	saleLabel = centeredText(
		sellButton,
		"Caption",
		"",
		UDim2.fromOffset(0, 0),
		UDim2.fromScale(1, 1),
		if compact then 15 else 19,
		1.4
	)
	saleLabel.ZIndex = 6

	keepButton.NextSelectionRight = sellButton
	sellButton.NextSelectionLeft = keepButton
	keepButton.Activated:Connect(dismissCatch)
	sellButton.Activated:Connect(sellCatch)

	gui.Parent = player:WaitForChild("PlayerGui")
end

function ReelController.Init()
	build()
	HUDController.OnCastPressed = function()
		task.spawn(tryCast)
	end
end

function ReelController.Start()
	player.CharacterAdded:Connect(function()
		setMovementLocked(false)
	end)
	local hud = player:WaitForChild("PlayerGui"):WaitForChild("HUD")
	hud:GetAttributeChangedSignal("ActiveTab"):Connect(function()
		if hud:GetAttribute("ActiveTab") then
			dismissCatch()
		end
	end)
	Net.Event("Bite").OnClientEvent:Connect(function(payload: BitePayload)
		if state == "Waiting" and payload.castId == castId then
			startReel(payload)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if state == "Reeling" then
			if isHoldInput(input) then
				heldInputs += 1
			end
			return
		end
		if processed or promptsShown > 0 then
			return
		end
		-- [E] casts, unless a vendor / feed prompt is using the key right now.
		if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonX then
			task.spawn(tryCast)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if isHoldInput(input) then
			heldInputs = math.max(0, heldInputs - 1)
		end
	end)

	ProximityPromptService.PromptShown:Connect(function()
		promptsShown += 1
	end)
	ProximityPromptService.PromptHidden:Connect(function()
		promptsShown = math.max(0, promptsShown - 1)
	end)
end

return ReelController
