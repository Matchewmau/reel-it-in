--!strict
-- Shared UI construction kit and nautical wood-and-riveted-steel HUD theme.

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Kit = {}

Kit.Theme = {
	Panel = Color3.fromRGB(20, 29, 43), -- #141D2B deep navy-slate
	PanelLight = Color3.fromRGB(74, 90, 112), -- #4A5A70 brushed steel
	PanelDark = Color3.fromRGB(12, 18, 28),
	Stroke = Color3.fromRGB(108, 122, 140),
	Brass = Color3.fromRGB(229, 175, 69), -- #E5AF45 warm brass/gold
	Wood = Color3.fromRGB(158, 102, 48), -- #9E6630 carved wood
	Steel = Color3.fromRGB(74, 90, 112), -- #4A5A70 brushed steel
	Text = Color3.fromRGB(255, 250, 238),
	SubText = Color3.fromRGB(196, 206, 218),
	Gold = Color3.fromRGB(255, 208, 68),
	Good = Color3.fromRGB(46, 196, 77), -- #2EC44D emerald green
	Bad = Color3.fromRGB(240, 84, 78),
	Accent = Color3.fromRGB(46, 124, 246), -- #2E7CF6 royal blue
	Danger = Color3.fromRGB(217, 59, 50), -- #D93B32 ruby red
}

Kit.Font = Enum.Font.BuilderSansBold
Kit.FontHeavy = Enum.Font.FredokaOne
Kit.FontBody = Enum.Font.BuilderSansMedium

type Props = { [string]: any }

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function apply(instance: Instance, props: Props?)
	if not props then
		return
	end
	local parent = nil
	for key, value in props do
		if key == "Parent" then
			parent = value
		else
			(instance :: any)[key] = value
		end
	end
	-- Parent last so the instance replicates into the tree fully configured.
	if parent then
		instance.Parent = parent
	end
end

function Kit.Corner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

function Kit.Stroke(parent: Instance, color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Kit.Theme.Stroke
	stroke.Thickness = thickness or 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function Kit.TextStroke(label: GuiObject, color: Color3?, thickness: number?): UIStroke
	if label:IsA("TextLabel") then
		label.TextStrokeTransparency = 1
	end
	if label:IsA("TextButton") then
		label.TextStrokeTransparency = 1
	end
	if label:IsA("TextBox") then
		label.TextStrokeTransparency = 1
	end
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Color3.fromRGB(14, 19, 28)
	stroke.Thickness = thickness or 1.4
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	return stroke
end

function Kit.Padding(parent: Instance, x: number, y: number?): UIPadding
	local padding = Instance.new("UIPadding")
	local vertical = y or x
	padding.PaddingLeft = UDim.new(0, x)
	padding.PaddingRight = UDim.new(0, x)
	padding.PaddingTop = UDim.new(0, vertical)
	padding.PaddingBottom = UDim.new(0, vertical)
	padding.Parent = parent
	return padding
end

function Kit.List(parent: Instance, direction: Enum.FillDirection, gap: number): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.Padding = UDim.new(0, gap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

function Kit.Frame(props: Props?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Kit.Theme.Panel
	frame.BorderSizePixel = 0
	apply(frame, props)
	return frame
end

-- Gradients tint the surface, leaving child labels and artwork at full brightness.
function Kit.Gradient(parent: GuiObject, top: Color3, bottom: Color3): UIGradient
	parent.BackgroundColor3 = Color3.new(1, 1, 1)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Parent = parent
	return gradient
end

-- Subtle top-half white highlight overlay so CTA buttons and plaques look beveled and tactile.
function Kit.Gloss(parent: GuiObject): Frame
	local gloss = Kit.Frame({
		Name = "Gloss",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.86,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 0.46, 0),
		ZIndex = parent.ZIndex,
		Active = false,
		Parent = parent,
	})
	Kit.Corner(gloss, 6)
	return gloss
end

-- Smooth hover (1.04x) and press (0.96x) scale feedback; cleanly disabled when not Interactable.
function Kit.HoverScale(button: GuiButton, hoverScale: number?): UIScale
	local targetHover = hoverScale or 1.04
	local targetPress = 0.96
	local existing = button:FindFirstChildOfClass("UIScale")
	local uiScale: UIScale
	if existing then
		uiScale = existing
	else
		local created = Instance.new("UIScale")
		created.Scale = 1
		created.Parent = button
		uiScale = created
	end
	local hovered = false
	local activeTween: Tween? = nil

	local function tweenTo(value: number, info: TweenInfo)
		if activeTween then
			activeTween:Cancel()
		end
		local tween = TweenService:Create(uiScale, info, { Scale = value })
		activeTween = tween
		tween:Play()
	end

	button.MouseEnter:Connect(function()
		hovered = true
		if button.Interactable then
			tweenTo(targetHover, HOVER_TWEEN)
		end
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		tweenTo(1, HOVER_TWEEN)
	end)
	button.MouseButton1Down:Connect(function()
		if button.Interactable then
			tweenTo(targetPress, PRESS_TWEEN)
		end
	end)
	button.MouseButton1Up:Connect(function()
		if button.Interactable then
			tweenTo(if hovered then targetHover else 1, HOVER_TWEEN)
		else
			tweenTo(1, HOVER_TWEEN)
		end
	end)
	button:GetPropertyChangedSignal("Interactable"):Connect(function()
		if not button.Interactable then
			tweenTo(1, HOVER_TWEEN)
		end
	end)

	return uiScale
end

-- Brass/iron edging with riveted corner brackets from the nautical HUD reference.
function Kit.Trim(parent: GuiObject, color: Color3?)
	local trimColor = color or Kit.Theme.Brass
	local edge = parent:FindFirstChildOfClass("UIStroke") or Kit.Stroke(parent)
	edge.Color = trimColor
	edge.Thickness = 2.5

	local topPlate = trimColor:Lerp(Color3.new(1, 1, 1), 0.22)
	local botPlate = trimColor:Lerp(Kit.Theme.PanelDark, 0.52)

	for _, anchor in { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) } do
		local cap = Kit.Frame({
			Name = "CornerPlate",
			AnchorPoint = anchor,
			Position = UDim2.new(anchor.X, if anchor.X == 0 then 2 else -2, anchor.Y, if anchor.Y == 0 then 2 else -2),
			Size = UDim2.fromOffset(9, 9),
			ZIndex = parent.ZIndex + 1,
			Active = false,
			Parent = parent,
		})
		Kit.Corner(cap, 2)
		Kit.Gradient(cap, topPlate, botPlate)
		Kit.Stroke(cap, Kit.Theme.PanelDark, 1)

		local rivet = Kit.Frame({
			Name = "Rivet",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(3, 3),
			BackgroundColor3 = Kit.Theme.PanelDark,
			ZIndex = parent.ZIndex + 2,
			Active = false,
			Parent = cap,
		})
		Kit.Corner(rivet, 2)
	end
end

-- A rounded, stroked panel.
function Kit.Panel(props: Props?): Frame
	local frame = Kit.Frame(props)
	Kit.Corner(frame, 10)
	Kit.Stroke(frame)
	return frame
end

function Kit.Label(props: Props?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Kit.Font
	label.TextColor3 = Kit.Theme.Text
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	apply(label, props)
	return label
end

function Kit.Button(props: Props?): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = true
	button.BackgroundColor3 = Kit.Theme.Accent
	button.BorderSizePixel = 0
	button.Font = Kit.Font
	button.TextColor3 = Kit.Theme.Text
	button.TextSize = 14
	apply(button, props)
	Kit.Corner(button, 8)
	return button
end

function Kit.ScreenGui(name: string, displayOrder: number): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	return gui
end

-- Scales fixed-pixel layouts down on small (mobile) viewports.
-- Compact mode = phones and other small or touch-only screens. Layouts are
-- authored for an 820-pixel-tall desktop viewport; shrinking that to a phone
-- (about 375 tall) would halve every button and make text unreadable, so in
-- compact mode the UI scale has a floor and controllers switch to a layout with
-- fewer, larger elements that keep clear of Roblox's thumbstick (bottom-left)
-- and jump button (bottom-right).
Kit.Compact = {
	MaxViewportHeight = 520, -- viewports shorter than this are compact
	MinPlausibleHeight = 100, -- below this the viewport has not been sized yet
	MinScale = 0.72, -- UI scale floor in compact mode
	ThumbstickClearance = 190, -- design pixels kept free at the bottom-left
	JumpClearance = 190, -- design pixels kept free at the bottom-right
	ButtonHeight = 46, -- row buttons, so they stay tappable after scaling
}

function Kit.IsCompact(): boolean
	local camera = workspace.CurrentCamera
	local height = if camera then camera.ViewportSize.Y else 0
	-- The camera reports a 1x1 viewport for the first frames of a session; a
	-- controller building its layout then must not mistake that for a phone.
	local viewportKnown = height >= Kit.Compact.MinPlausibleHeight
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	return touchOnly or (viewportKnown and height < Kit.Compact.MaxViewportHeight)
end

function Kit.AutoScale(gui: ScreenGui): UIScale
	local scale = Instance.new("UIScale")
	scale.Parent = gui
	local function update()
		local camera = workspace.CurrentCamera
		if camera then
			local size = camera.ViewportSize
			local minimum = if Kit.IsCompact() then Kit.Compact.MinScale else 0.5
			local raw = math.clamp(math.min(size.Y / 820, size.X / 1180), minimum, 1.15)
			local snapped = math.round(raw * 20) / 20
			if math.abs(snapped - 1) <= 0.05 then
				snapped = 1
			end
			scale.Scale = snapped
		end
	end
	update()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	end
	return scale
end

return Kit
