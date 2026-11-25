--!strict
-- Shared nautical management window: riveted iron frame, brass corner brackets,
-- carved wood sign header with ribbon tail wings & braided rope caps,
-- glossy close button, real caught-fish Backpack grid, and bevelled item cards.
local TweenService = game:GetService("TweenService")

local Kit = require(script.Parent.Kit)
local ModelPreview = require(script.Parent.ModelPreview)
local PlacePreview = require(script.Parent.PlacePreview)

export type Action = { text: string, color: Color3?, onClick: () -> () }
export type Row = {
	title: string,
	subtitle: string?,
	color: Color3?,
	buttons: { Action }?,
	preview: ModelPreview.Spec?,
	landmark: string?,
	quality: string?,
	uid: string?,
	tag: string?,
	badge: string?,
}
type Card = { frame: Frame, row: Row }
type FishSlot = {
	button: TextButton,
	gradient: UIGradient,
	stroke: UIStroke,
	tagLabel: TextLabel,
	badgeLabel: TextLabel,
	preview: ViewportFrame?,
	previewKey: string,
	row: Row,
}
export type View = {
	root: Frame,
	scale: UIScale,
	popTween: Tween?,
	title: TextLabel,
	list: ScrollingFrame,
	backpackView: Frame,
	featuredCard: Frame,
	featuredRow: Row?,
	backpackGrid: ScrollingFrame,
	gridLayout: UIGridLayout,
	selectedUid: string?,
	fishSlots: { FishSlot },
	emptySlots: { Frame },
	backpackSignature: string,
	currentRows: { Row },
	currentCap: number,
	footer: TextLabel,
	count: TextLabel,
	tab: string,
	cards: { Card },
}

local ManagementPanel = {}
local theme = Kit.Theme
local brass = theme.Brass
local woodDark = Color3.fromRGB(64, 38, 22)
local metal = Color3.fromRGB(92, 108, 128)
local cream = Color3.fromRGB(255, 240, 194)
local subtitleColor = Color3.fromRGB(220, 230, 242) -- #DCE6F2
local slotTagColor = Color3.fromRGB(232, 240, 250) -- #E8F0FA
local goldStrokeColor = Color3.fromRGB(78, 42, 8)
local emptyWellBg = Color3.fromRGB(14, 22, 36) -- #0E1624
local emptyWellStroke = Color3.fromRGB(42, 59, 82) -- #2A3B52
local skyBadgeBg = Color3.fromRGB(36, 134, 232)
local dark = theme.PanelDark
local navy = theme.Panel

local POP_IN_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local function edgePanel(
	parent: Instance,
	name: string,
	position: UDim2,
	size: UDim2,
	top: Color3,
	bottom: Color3,
	rim: Color3,
	thickness: number?
): Frame
	local frame = Kit.Frame({
		Name = name,
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = parent,
	})
	Kit.Corner(frame, 8)
	Kit.Gradient(frame, top, bottom)
	Kit.Stroke(frame, rim, thickness or 2)
	return frame
end

local function specKey(spec: ModelPreview.Spec?): string
	if not spec then
		return ""
	end
	return `{spec.kind}:{spec.id}:{spec.mutation or "Normal"}`
end

function ManagementPanel.Create(gui: ScreenGui, close: () -> ()): View
	local compact = Kit.IsCompact()
	local featuredHeight = if compact then 114 else 124

	local root = Kit.Frame({
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.472),
		Size = UDim2.new(0.76, -8, 0.70, -4),
		BackgroundColor3 = Color3.fromRGB(36, 44, 56),
		Visible = false,
		Active = true,
		ZIndex = 3,
		Parent = gui,
	})
	local limits = Instance.new("UISizeConstraint")
	limits.MaxSize = Vector2.new(576, 510)
	limits.Parent = root
	local rootScale = Instance.new("UIScale")
	rootScale.Scale = 1
	rootScale.Parent = root
	Kit.Corner(root, 11)
	Kit.Gradient(root, Color3.fromRGB(56, 68, 86), Color3.fromRGB(26, 33, 44))
	Kit.Trim(root, brass)

	edgePanel(
		root,
		"Inset",
		UDim2.fromOffset(11, 28),
		UDim2.new(1, -22, 1, -40),
		Color3.fromRGB(22, 33, 50),
		dark,
		metal,
		2
	)

	-- Wooden beam header rail (ZIndex 5 keeps the banner above scrolling cards)
	local rail = edgePanel(
		root,
		"HeaderRail",
		UDim2.fromOffset(10, 2),
		UDim2.new(1, -20, 0, 34),
		Color3.fromRGB(134, 86, 44),
		woodDark,
		Color3.fromRGB(48, 28, 16),
		2
	)
	rail.ZIndex = 5

	-- Angled/stepped wooden ribbon tail wings tucked behind CarvedSign (sibling ZIndex 4 < sign ZIndex 6)
	for _, isLeft in { true, false } do
		local sideSign = if isLeft then -1 else 1
		local wing = edgePanel(
			rail,
			if isLeft then "LeftRibbonWing" else "RightRibbonWing",
			UDim2.new(if isLeft then 0.22 else 0.78, sideSign * 24, 0.58, 0),
			UDim2.fromOffset(40, 34),
			Color3.fromRGB(162, 108, 52),
			Color3.fromRGB(88, 50, 24),
			brass:Lerp(woodDark, 0.35),
			2
		)
		wing.AnchorPoint = Vector2.new(if isLeft then 0 else 1, 0.5)
		wing.Rotation = sideSign * 6
		wing.Active = false
		wing.ZIndex = 4

		-- Outer stepped swallowtail tip extending past the main ribbon wing
		local tailTip = edgePanel(
			wing,
			"RibbonStep",
			UDim2.new(if isLeft then 0 else 1, sideSign * 8, 0.58, 0),
			UDim2.fromOffset(18, 22),
			Color3.fromRGB(136, 86, 40),
			Color3.fromRGB(68, 38, 18),
			Color3.fromRGB(52, 28, 14),
			1.5
		)
		tailTip.AnchorPoint = Vector2.new(if isLeft then 0 else 1, 0.5)
		tailTip.Active = false
		tailTip.ZIndex = 4

		-- Subtle wood grain line + fold shadow where the wing tucks beneath CarvedSign
		Kit.Frame({
			Name = "WingGrain",
			BackgroundColor3 = Color3.fromRGB(232, 182, 102),
			BackgroundTransparency = 0.76,
			Position = UDim2.fromOffset(5, 9),
			Size = UDim2.new(1, -10, 0, 2),
			Active = false,
			ZIndex = 5,
			Parent = wing,
		})
		Kit.Frame({
			Name = "FoldShadow",
			BackgroundColor3 = Color3.fromRGB(28, 14, 6),
			BackgroundTransparency = 0.45,
			AnchorPoint = Vector2.new(if isLeft then 1 else 0, 0),
			Position = UDim2.fromScale(if isLeft then 1 else 0, 0),
			Size = UDim2.new(0, 10, 1, 0),
			Active = false,
			ZIndex = 5,
			Parent = wing,
		})
	end

	-- Carved wooden sign plaque with wood-grain strips and braided gold/brass rope-post caps
	local sign = edgePanel(
		rail,
		"CarvedSign",
		UDim2.fromScale(0.5, 0.44),
		UDim2.new(0.56, 0, 0, 50),
		Color3.fromRGB(204, 148, 70),
		Color3.fromRGB(114, 68, 32),
		brass,
		3
	)
	sign.AnchorPoint = Vector2.new(0.5, 0.5)
	sign.ZIndex = 6
	Kit.Gloss(sign)

	-- Subtle horizontal carved-plank wood grain highlights and grooves
	local grainStrips = {
		{
			name = "GrainHighlightTop",
			pos = UDim2.fromOffset(14, 11),
			size = UDim2.new(1, -28, 0, 2),
			col = Color3.fromRGB(248, 206, 128),
			trans = 0.76,
		},
		{
			name = "GrainGrooveMid",
			pos = UDim2.fromOffset(20, 25),
			size = UDim2.new(0.66, -20, 0, 2),
			col = Color3.fromRGB(68, 36, 14),
			trans = 0.74,
		},
		{
			name = "GrainHighlightLow",
			pos = UDim2.new(0.34, 0, 0, 35),
			size = UDim2.new(0.60, -14, 0, 1),
			col = Color3.fromRGB(236, 186, 104),
			trans = 0.80,
		},
		{
			name = "GrainShadowBottom",
			pos = UDim2.new(0, 14, 1, -9),
			size = UDim2.new(1, -28, 0, 2),
			col = Color3.fromRGB(58, 30, 12),
			trans = 0.68,
		},
	}
	for _, spec in grainStrips do
		local strip = Kit.Frame({
			Name = spec.name,
			BackgroundColor3 = spec.col,
			BackgroundTransparency = spec.trans,
			Position = spec.pos,
			Size = spec.size,
			Active = false,
			ZIndex = 6,
			Parent = sign,
		})
		Kit.Corner(strip, 1)
	end

	local ropeInner = Kit.Frame({
		Name = "InnerBorder",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -20, 1, -8),
		Active = false,
		ZIndex = 7,
		Parent = sign,
	})
	Kit.Corner(ropeInner, 5)
	Kit.Stroke(ropeInner, Color3.fromRGB(82, 48, 22), 1.5)

	-- Braided gold/brass rope-post caps wrapping the left and right ends of CarvedSign
	for _, isLeft in { true, false } do
		local post = Kit.Frame({
			Name = if isLeft then "LeftRopePost" else "RightRopePost",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(if isLeft then 0 else 1, if isLeft then 4 else -4, 0.5, 0),
			Size = UDim2.new(0, 10, 1, 6),
			BackgroundColor3 = Color3.new(1, 1, 1),
			Active = false,
			ZIndex = 8,
			Parent = sign,
		})
		Kit.Corner(post, 4)
		Kit.Gradient(post, Color3.fromRGB(255, 220, 114), Color3.fromRGB(152, 96, 28))
		Kit.Stroke(post, Color3.fromRGB(54, 30, 12), 1.5)

		for _, isTop in { true, false } do
			local knot = Kit.Frame({
				Name = if isTop then "TopRopeKnot" else "BottomRopeKnot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, if isTop then 0.04 else 0.96),
				Size = UDim2.fromOffset(13, 6),
				BackgroundColor3 = Color3.new(1, 1, 1),
				Active = false,
				ZIndex = 9,
				Parent = post,
			})
			Kit.Corner(knot, 3)
			Kit.Gradient(knot, Color3.fromRGB(255, 232, 138), Color3.fromRGB(168, 106, 32))
			Kit.Stroke(knot, Color3.fromRGB(54, 30, 12), 1)
		end

		for twistIndex = 1, 4 do
			local strand = Kit.Frame({
				Name = "RopeStrand" .. twistIndex,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.14 + (twistIndex - 1) * 0.24),
				Size = UDim2.fromOffset(11, 5),
				Rotation = if isLeft then -22 else 22,
				BackgroundColor3 = Color3.new(1, 1, 1),
				Active = false,
				ZIndex = 9,
				Parent = post,
			})
			Kit.Corner(strand, 3)
			Kit.Gradient(strand, Color3.fromRGB(255, 236, 150), Color3.fromRGB(178, 116, 36))
			Kit.Stroke(strand, Color3.fromRGB(72, 40, 14), 1)
		end
	end

	local title = Kit.Label({
		Text = "",
		Font = Kit.FontHeavy,
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = cream,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -28, 1, 0),
		ZIndex = 9,
		Parent = sign,
	})
	Kit.TextStroke(title, Color3.fromRGB(48, 26, 12), 2.2)

	local count = Kit.Label({
		Text = "",
		Font = Kit.FontHeavy,
		TextSize = 13,
		TextColor3 = cream,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -48, 0.5, 0),
		Size = UDim2.fromOffset(50, 25),
		BackgroundTransparency = 0,
		BackgroundColor3 = dark,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 8,
		Parent = rail,
	})
	Kit.Corner(count, 6)
	Kit.Stroke(count, brass, 1.5)
	Kit.TextStroke(count, dark, 1.2)

	local dismiss = Kit.Button({
		Name = "Close",
		Text = "",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 4, 0.5, -2),
		Size = UDim2.fromOffset(40, 40),
		ZIndex = 9,
		Parent = rail,
	})
	Kit.Corner(dismiss, 9)
	Kit.Gradient(dismiss, Color3.fromRGB(238, 74, 64), Color3.fromRGB(152, 28, 24))
	Kit.Stroke(dismiss, brass, 2.5)
	Kit.Gloss(dismiss)
	Kit.HoverScale(dismiss, 1.08)
	local dismissLabel = Kit.Label({
		Text = "X",
		Font = Kit.FontHeavy,
		TextSize = 22,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Parent = dismiss,
	})
	Kit.TextStroke(dismissLabel, Color3.fromRGB(72, 12, 12), 1.8)
	dismiss.Activated:Connect(close)

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(18, 52)
	list.Size = UDim2.new(1, -36, 1, -96)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 5
	list.ScrollBarImageColor3 = brass
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ZIndex = 4
	list.Parent = root
	Kit.List(list, Enum.FillDirection.Vertical, 8)
	Kit.Padding(list, 4, 4)

	-- Dedicated Backpack container: Featured Inspector Card on top + real Caught-Fish Inventory Grid below
	local backpackView = Kit.Frame({
		Name = "BackpackView",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(18, 50),
		Size = UDim2.new(1, -36, 1, -94),
		Visible = false,
		ZIndex = 4,
		Parent = root,
	})

	local featuredCard = Kit.Frame({
		Name = "FeaturedCard",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 0, featuredHeight),
		ZIndex = 4,
		Parent = backpackView,
	})
	Kit.Corner(featuredCard, 8)

	local backpackGrid = Instance.new("ScrollingFrame")
	backpackGrid.Name = "BackpackGrid"
	backpackGrid.BackgroundTransparency = 1
	backpackGrid.BorderSizePixel = 0
	backpackGrid.Position = UDim2.fromOffset(0, featuredHeight + 8)
	backpackGrid.Size = UDim2.new(1, 0, 1, -(featuredHeight + 8))
	backpackGrid.CanvasSize = UDim2.new()
	backpackGrid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	backpackGrid.ScrollBarThickness = 5
	backpackGrid.ScrollBarImageColor3 = brass
	backpackGrid.ScrollingDirection = Enum.ScrollingDirection.Y
	backpackGrid.ZIndex = 4
	backpackGrid.Parent = backpackView
	Kit.Padding(backpackGrid, 3, 3)

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = if compact then UDim2.new(1 / 5, -6, 0, 72) else UDim2.new(1 / 6, -6, 0, 78)
	gridLayout.CellPadding = UDim2.fromOffset(6, 6)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = backpackGrid

	local footerBar = Kit.Frame({
		Name = "FooterBar",
		BackgroundColor3 = dark,
		BackgroundTransparency = 0.35,
		Position = UDim2.new(0, 16, 1, -40),
		Size = UDim2.new(1, -32, 0, 26),
		ZIndex = 4,
		Parent = root,
	})
	Kit.Corner(footerBar, 5)
	Kit.Stroke(footerBar, Color3.fromRGB(52, 66, 84), 1)
	local footer = Kit.Label({
		Text = "",
		Font = Kit.FontBody,
		TextSize = 13,
		TextColor3 = cream,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -16, 1, 0),
		ZIndex = 5,
		Parent = footerBar,
	})

	return {
		root = root,
		scale = rootScale,
		popTween = nil,
		title = title,
		list = list,
		backpackView = backpackView,
		featuredCard = featuredCard,
		featuredRow = nil,
		backpackGrid = backpackGrid,
		gridLayout = gridLayout,
		selectedUid = nil,
		fishSlots = {},
		emptySlots = {},
		backpackSignature = "",
		currentRows = {},
		currentCap = 30,
		footer = footer,
		count = count,
		tab = "",
		cards = {},
	}
end

local function sameAppearance(a: Row, b: Row): boolean
	if
		a.title ~= b.title
		or a.subtitle ~= b.subtitle
		or a.color ~= b.color
		or a.quality ~= b.quality
		or a.landmark ~= b.landmark
		or a.uid ~= b.uid
		or a.tag ~= b.tag
		or a.badge ~= b.badge
	then
		return false
	end
	local ap, bp = a.preview, b.preview
	if ap and bp then
		if ap.kind ~= bp.kind or ap.id ~= bp.id or ap.mutation ~= bp.mutation then
			return false
		end
	elseif ap ~= bp then
		return false
	end
	local aa: { Action } = a.buttons or {}
	local ba: { Action } = b.buttons or {}
	if #aa ~= #ba then
		return false
	end
	for i, button in aa do
		if button.text ~= ba[i].text or button.color ~= ba[i].color then
			return false
		end
	end
	return true
end

local GLYPHS: { [string]: string } = {
	Pond = "≈",
	Hub = "⌂",
	Freshwater = "≈",
	Saltwater = "◉",
	Shrine = "✦",
	Crate = "▣",
	Merchant = "⌂",
}

local function thumbnail(parent: Frame, row: Row, size: number, tint: Color3, spin: boolean?)
	local housing = edgePanel(
		parent,
		"Art",
		UDim2.fromOffset(4, 0),
		UDim2.fromOffset(size, size),
		tint:Lerp(Color3.fromRGB(48, 66, 86), 0.58),
		dark,
		tint:Lerp(Color3.new(1, 1, 1), 0.2),
		2
	)
	Kit.Gloss(housing)
	local art = if row.preview
		then ModelPreview.Create(row.preview)
		elseif row.landmark then PlacePreview.Create(row.landmark)
		else nil
	if art then
		art.Position = UDim2.fromOffset(3, 3)
		art.Size = UDim2.new(1, -6, 1, -6)
		art.Parent = housing
		if spin and row.preview and art:IsA("ViewportFrame") then
			ModelPreview.SetSpin(art, true)
		end
	elseif row.landmark then
		Kit.Label({
			Text = GLYPHS[row.landmark] or "◆",
			TextSize = 32,
			TextColor3 = tint,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			Parent = housing,
		})
	end
end

local function line(
	parent: Frame,
	text: string,
	color: Color3,
	size: number,
	order: number,
	font: Enum.Font,
	strokeThickness: number?
)
	local lbl = Kit.Label({
		Text = text,
		TextSize = size,
		TextColor3 = color,
		Font = font,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	if strokeThickness then
		Kit.TextStroke(lbl, dark, strokeThickness)
	end
end

local function qualityPill(parent: Frame, text: string, color: Color3, order: number)
	local wrap = Kit.Frame({
		Name = "QualityWrap",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = order,
		Parent = parent,
	})
	local pill = Kit.Frame({
		Name = "QualityPill",
		BackgroundColor3 = color:Lerp(dark, 0.78),
		Size = UDim2.fromOffset(0, 19),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = wrap,
	})
	Kit.Corner(pill, 5)
	Kit.Stroke(pill, color:Lerp(Color3.new(1, 1, 1), 0.15), 1.2)
	Kit.Padding(pill, 7, 1)
	Kit.Label({
		Text = text,
		Font = Kit.Font,
		TextSize = 12,
		TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.25),
		TextWrapped = false,
		Size = UDim2.fromOffset(0, 17),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = pill,
	})
end

local function createActionButton(
	parent: Instance,
	index: number,
	spec: Action,
	size: UDim2,
	getAction: () -> Action?
): TextButton
	local tint = spec.color or theme.Accent
	local isGold = tint == theme.Gold
	local button = Kit.Button({
		Name = "Button" .. index,
		Text = spec.text,
		TextTransparency = 1,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = size,
		LayoutOrder = index,
		Parent = parent,
	})
	Kit.Corner(button, 7)
	Kit.Gradient(
		button,
		tint:Lerp(Color3.new(1, 1, 1), 0.18),
		tint:Lerp(if isGold then Color3.fromRGB(168, 96, 16) else dark, 0.48)
	)
	Kit.Stroke(button, if isGold then brass else tint:Lerp(Color3.new(1, 1, 1), 0.25), 1.5)
	Kit.Gloss(button)
	Kit.HoverScale(button, 1.04)

	local btnLabel = Kit.Label({
		Text = spec.text,
		Font = Kit.FontHeavy,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.new(1, 1, 1),
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -8, 1, 0),
		Parent = button,
	})
	Kit.TextStroke(btnLabel, if isGold then goldStrokeColor else dark, 1.4)

	button.Activated:Connect(function()
		local action = getAction()
		if action then
			action.onClick()
		end
	end)
	return button
end

local function makeCard(view: View, row: Row, index: number): Card
	local compact = Kit.IsCompact()
	local side = view.tab == "Travel" or view.tab == "Rods"
	local sideWidth = if view.tab == "Travel" then 96 else 92
	local height = if compact then Kit.Compact.ButtonHeight else 32
	local gap = 5
	local artSize = if view.tab == "Shop" then 78 else 60
	local hasArt = row.preview ~= nil or row.landmark ~= nil
	local ink = row.color or metal
	local isGoldCard = ink == theme.Gold

	local frame = Kit.Frame({
		Name = "Row" .. index,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, -6, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = index,
		Parent = view.list,
	})
	Kit.Corner(frame, 8)
	Kit.Gradient(
		frame,
		if isGoldCard then Color3.fromRGB(58, 46, 24) else navy:Lerp(ink, 0.16),
		if isGoldCard then Color3.fromRGB(28, 22, 14) else Color3.fromRGB(16, 22, 34)
	)
	Kit.Stroke(frame, if isGoldCard then theme.Gold else metal:Lerp(ink, 0.62), if isGoldCard then 2.5 else 2)
	Kit.Padding(frame, 9, 9)

	-- Subtle rarity/accent left glow bar
	local accentBar = Kit.Frame({
		Name = "AccentBar",
		BackgroundColor3 = ink,
		Position = UDim2.fromOffset(-5, 0),
		Size = UDim2.new(0, 3, 1, 0),
		Parent = frame,
	})
	Kit.Corner(accentBar, 2)

	local card: Card = { frame = frame, row = row }
	local left = if hasArt then artSize + 16 else 4
	if hasArt then
		thumbnail(frame, row, artSize, ink, false)
	end

	local actions: { Action } = row.buttons or {}
	local buttonArea = if side and #actions > 0 then sideWidth + 10 else 0
	local content = Kit.Frame({
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(left, 0),
		Size = UDim2.new(1, -left, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = frame,
	})
	local copy = Kit.Frame({
		Name = "Details",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -buttonArea, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = content,
	})
	Kit.List(copy, Enum.FillDirection.Vertical, 3)
	line(copy, row.title, ink:Lerp(Color3.new(1, 1, 1), 0.45), 17, 1, Kit.FontHeavy, 1.5)
	if row.quality then
		qualityPill(copy, row.quality, ink, 2)
	end
	if row.subtitle then
		line(copy, row.subtitle, subtitleColor, 14, 3, Kit.FontBody, nil)
	end

	if #actions > 0 then
		local buttons = Kit.Frame({ Name = "Buttons", BackgroundTransparency = 1, LayoutOrder = 2, Parent = content })
		if side then
			buttons.AnchorPoint = Vector2.new(1, 0)
			buttons.Position = UDim2.fromScale(1, 0)
			buttons.Size = UDim2.fromOffset(sideWidth, #actions * (height + gap) - gap)
			Kit.List(buttons, Enum.FillDirection.Vertical, gap)
		else
			Kit.List(content, Enum.FillDirection.Vertical, 6)
			copy.LayoutOrder = 1
			buttons.Size = UDim2.new(1, 0, 0, height)
			Kit.List(buttons, Enum.FillDirection.Horizontal, gap)
		end
		for i, spec in actions do
			local btnSize = if side
				then UDim2.new(1, 0, 0, height)
				else UDim2.new(1 / #actions, -gap * (#actions - 1) / #actions, 1, 0)
			createActionButton(buttons, i, spec, btnSize, function(): Action?
				local current = card.row.buttons
				return if current then current[i] else nil
			end)
		end
	end
	return card
end

local function clearFeaturedCard(featured: Frame)
	for _, child in featured:GetChildren() do
		if not child:IsA("UICorner") then
			child:Destroy()
		end
	end
end

local function renderFeaturedCard(view: View, selectedRow: Row?)
	if view.featuredRow == nil and selectedRow == nil and view.featuredCard:FindFirstChild("EmptyLabel") then
		return
	end
	if view.featuredRow and selectedRow and sameAppearance(view.featuredRow, selectedRow) then
		view.featuredRow = selectedRow
		return
	end
	view.featuredRow = selectedRow

	local card = view.featuredCard
	clearFeaturedCard(card)

	local compact = Kit.IsCompact()
	local featuredHeight = if compact then 114 else 124
	card.Size = UDim2.new(1, 0, 0, featuredHeight)

	if not selectedRow then
		Kit.Gradient(card, Color3.fromRGB(24, 34, 52), dark)
		Kit.Stroke(card, metal, 2)
		local emptyLabel = Kit.Label({
			Name = "EmptyLabel",
			Text = "Your backpack is empty — cast a line at the river or the Abyss!",
			Font = Kit.FontBody,
			TextSize = 15,
			TextColor3 = subtitleColor,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(18, 0),
			Size = UDim2.new(1, -36, 1, 0),
			Parent = card,
		})
		emptyLabel.TextYAlignment = Enum.TextYAlignment.Center
		return
	end

	local ink = selectedRow.color or metal
	Kit.Gradient(card, navy:Lerp(ink, 0.22), Color3.fromRGB(14, 20, 32))
	Kit.Stroke(card, metal:Lerp(ink, 0.72), 2)
	Kit.Padding(card, 10, 9)

	local accentBar = Kit.Frame({
		Name = "AccentBar",
		BackgroundColor3 = ink,
		Position = UDim2.fromOffset(-5, 0),
		Size = UDim2.new(0, 3, 1, 0),
		Parent = card,
	})
	Kit.Corner(accentBar, 2)

	local artSize = if compact then 80 else 92
	local housing = edgePanel(
		card,
		"Art",
		UDim2.new(0, 2, 0.5, 0),
		UDim2.fromOffset(artSize, artSize),
		ink:Lerp(Color3.fromRGB(48, 66, 86), 0.52),
		dark,
		ink:Lerp(Color3.new(1, 1, 1), 0.25),
		2
	)
	housing.AnchorPoint = Vector2.new(0, 0.5)
	Kit.Gloss(housing)
	if selectedRow.preview then
		local art = ModelPreview.Create(selectedRow.preview)
		art.Position = UDim2.fromOffset(3, 3)
		art.Size = UDim2.new(1, -6, 1, -6)
		art.Parent = housing
		ModelPreview.SetSpin(art, true)
	end

	local actions: { Action } = selectedRow.buttons or {}
	local buttonWidth = 112
	local leftOffset = artSize + 14
	local rightReserve = if #actions > 0 then buttonWidth + 10 else 0

	local details = Kit.Frame({
		Name = "Details",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, leftOffset, 0.5, 0),
		Size = UDim2.new(1, -(leftOffset + rightReserve), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = card,
	})
	Kit.List(details, Enum.FillDirection.Vertical, 4)

	local nameLabel = Kit.Label({
		Text = selectedRow.title,
		Font = Kit.FontHeavy,
		TextSize = if compact then 19 else 22,
		TextColor3 = ink:Lerp(Color3.new(1, 1, 1), 0.55),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Size = UDim2.new(1, 0, 0, if compact then 22 else 25),
		LayoutOrder = 1,
		Parent = details,
	})
	Kit.TextStroke(nameLabel, dark, 1.6)

	if selectedRow.quality then
		qualityPill(details, selectedRow.quality, ink, 2)
	end

	-- Weight + bright gold +X.X/s income line
	if selectedRow.subtitle then
		local weightPart, ratePart = string.match(selectedRow.subtitle, "^(.-)%s*·%s*(.+)$")
		if weightPart and ratePart then
			local statsRow = Kit.Frame({
				Name = "StatsRow",
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 20),
				LayoutOrder = 3,
				Parent = details,
			})
			local statsLayout = Kit.List(statsRow, Enum.FillDirection.Horizontal, 8)
			statsLayout.VerticalAlignment = Enum.VerticalAlignment.Center

			Kit.Label({
				Name = "WeightLabel",
				Text = weightPart,
				Font = Kit.Font,
				TextSize = 15,
				TextColor3 = slotTagColor,
				TextWrapped = false,
				Size = UDim2.fromOffset(0, 20),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = 1,
				Parent = statsRow,
			})
			local incomeLabel = Kit.Label({
				Name = "IncomeLabel",
				Text = ratePart,
				Font = Kit.Font,
				TextSize = 15,
				TextColor3 = theme.Gold,
				TextWrapped = false,
				Size = UDim2.fromOffset(0, 20),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = 2,
				Parent = statsRow,
			})
			Kit.TextStroke(incomeLabel, dark, 1.2)
		else
			line(details, selectedRow.subtitle, subtitleColor, 15, 3, Kit.Font, nil)
		end
	end

	if #actions > 0 then
		local gap = 4
		local btnHeight = math.floor((featuredHeight - 18 - gap * (#actions - 1)) / #actions)
		local buttons = Kit.Frame({
			Name = "Buttons",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(buttonWidth, #actions * btnHeight + gap * (#actions - 1)),
			Parent = card,
		})
		Kit.List(buttons, Enum.FillDirection.Vertical, gap)

		for i, spec in actions do
			createActionButton(buttons, i, spec, UDim2.new(1, 0, 0, btnHeight), function(): Action?
				local current = view.featuredRow
				local currentButtons = if current then current.buttons else nil
				return if currentButtons then currentButtons[i] else nil
			end)
		end
	end
end

local function updateSlotSelectionVisual(slot: FishSlot, selected: boolean)
	local ink = slot.row.color or metal
	slot.stroke.Color = if selected then theme.Gold else ink
	slot.stroke.Thickness = if selected then 3 else 1.8
end

local function buildBackpackSignature(rows: { Row }, selectedUid: string?, totalSlots: number, compact: boolean): string
	local parts: { string } = { `{if compact then "C" else "D"}|{totalSlots}|{selectedUid or ""}` }
	for _, r in rows do
		table.insert(parts, `{r.uid or ""}:{specKey(r.preview)}:{r.tag or ""}:{r.badge or ""}:{r.subtitle or ""}`)
	end
	return table.concat(parts, ";")
end

local function makeFishSlot(view: View, index: number, row: Row): FishSlot
	local ink = row.color or metal
	local slotBtn = Kit.Button({
		Name = "Slot" .. index,
		Text = "",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AutoButtonColor = false,
		LayoutOrder = index,
		Parent = view.backpackGrid,
	})
	Kit.Corner(slotBtn, 7)
	local gradient = Kit.Gradient(slotBtn, navy:Lerp(ink, 0.22), dark)
	local stroke = Kit.Stroke(slotBtn, ink, 1.8)
	Kit.HoverScale(slotBtn, 1.05)

	local tagLabel = Kit.Label({
		Name = "WeightTag",
		Text = row.tag or "",
		Font = Kit.Font,
		TextSize = 11,
		TextColor3 = slotTagColor,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -2),
		Size = UDim2.new(1, -6, 0, 15),
		ZIndex = slotBtn.ZIndex + 2,
		Parent = slotBtn,
	})
	Kit.TextStroke(tagLabel, dark, 1.1)

	local badgeLabel = Kit.Label({
		Name = "Badge",
		Text = "",
		Font = Kit.FontHeavy,
		TextSize = 10,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -3, 0, 3),
		Size = UDim2.fromOffset(0, 14),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 0.1,
		Visible = false,
		ZIndex = slotBtn.ZIndex + 3,
		Parent = slotBtn,
	})
	Kit.Corner(badgeLabel, 4)
	Kit.Padding(badgeLabel, 4, 0)
	Kit.TextStroke(badgeLabel, dark, 1.1)

	local slot: FishSlot = {
		button = slotBtn,
		gradient = gradient,
		stroke = stroke,
		tagLabel = tagLabel,
		badgeLabel = badgeLabel,
		preview = nil,
		previewKey = "",
		row = row,
	}

	slotBtn.Activated:Connect(function()
		local uid = slot.row.uid
		if uid and view.selectedUid ~= uid then
			view.selectedUid = uid
			for _, candidate in view.fishSlots do
				updateSlotSelectionVisual(candidate, candidate.row.uid == uid)
			end
			renderFeaturedCard(view, slot.row)
		end
	end)

	return slot
end

local function updateFishSlot(slot: FishSlot, index: number, row: Row, selectedUid: string?)
	slot.row = row
	slot.button.LayoutOrder = index
	local ink = row.color or metal
	slot.gradient.Color = ColorSequence.new(navy:Lerp(ink, 0.22), dark)
	updateSlotSelectionVisual(slot, row.uid ~= nil and row.uid == selectedUid)

	slot.tagLabel.Text = row.tag or ""

	local key = specKey(row.preview)
	if slot.previewKey ~= key then
		if slot.preview then
			slot.preview:Destroy()
			slot.preview = nil
		end
		slot.previewKey = key
		if row.preview then
			local art = ModelPreview.Create(row.preview)
			art.Position = UDim2.fromOffset(4, 2)
			art.Size = UDim2.new(1, -8, 1, -20)
			art.Parent = slot.button
			slot.preview = art
		end
	end

	local badge = row.badge
	if badge and badge ~= "" then
		slot.badgeLabel.Visible = true
		slot.badgeLabel.Text = badge
		if badge == "HELD" then
			slot.badgeLabel.BackgroundTransparency = 0.08
			slot.badgeLabel.BackgroundColor3 = skyBadgeBg
			slot.badgeLabel.TextColor3 = Color3.new(1, 1, 1)
		else
			slot.badgeLabel.BackgroundTransparency = 0.15
			slot.badgeLabel.BackgroundColor3 = Color3.fromRGB(58, 42, 12)
			slot.badgeLabel.TextColor3 = theme.Gold
		end
	else
		slot.badgeLabel.Visible = false
	end
end

local function makeEmptySlot(parent: Instance, slotNumber: number): Frame
	local well = Kit.Frame({
		Name = "EmptySlot" .. slotNumber,
		BackgroundColor3 = emptyWellBg,
		LayoutOrder = slotNumber,
		Parent = parent,
	})
	Kit.Corner(well, 7)
	Kit.Stroke(well, emptyWellStroke, 1)

	Kit.Label({
		Name = "SlotIndex",
		Text = tostring(slotNumber),
		Font = Kit.Font,
		TextSize = 11,
		TextColor3 = Color3.fromRGB(52, 70, 94),
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = well,
	})
	return well
end

local function renderBackpack(view: View, rows: { Row }, capacity: number?)
	local compact = Kit.IsCompact()
	local featuredHeight = if compact then 114 else 124
	view.featuredCard.Size = UDim2.new(1, 0, 0, featuredHeight)
	view.backpackGrid.Position = UDim2.fromOffset(0, featuredHeight + 8)
	view.backpackGrid.Size = UDim2.new(1, 0, 1, -(featuredHeight + 8))
	view.gridLayout.CellSize = if compact then UDim2.new(1 / 5, -6, 0, 72) else UDim2.new(1 / 6, -6, 0, 78)

	local fishRows: { Row } = {}
	for _, row in rows do
		if row.preview ~= nil then
			table.insert(fishRows, row)
		end
	end

	-- Resolve selectedUid (default to rows[1].uid if nil or sold/placed)
	local selectedRow: Row? = nil
	if #fishRows > 0 then
		if view.selectedUid then
			for _, row in fishRows do
				if row.uid == view.selectedUid then
					selectedRow = row
					break
				end
			end
		end
		if not selectedRow then
			selectedRow = fishRows[1]
			view.selectedUid = fishRows[1].uid
		end
	else
		view.selectedUid = nil
	end

	view.currentRows = fishRows
	local totalSlots = math.max(capacity or 30, #fishRows)
	view.currentCap = totalSlots

	renderFeaturedCard(view, selectedRow)

	local sig = buildBackpackSignature(fishRows, view.selectedUid, totalSlots, compact)
	if view.backpackSignature == sig then
		-- Refresh live closure references on existing slots without rebuilding UI/viewports
		for i, row in fishRows do
			local slot = view.fishSlots[i]
			if slot then
				slot.row = row
			end
		end
		return
	end
	view.backpackSignature = sig

	-- Caught-fish slots (1 .. #fishRows)
	for i, row in fishRows do
		local slot = view.fishSlots[i]
		if not slot then
			slot = makeFishSlot(view, i, row)
			view.fishSlots[i] = slot
		end
		updateFishSlot(slot, i, row, view.selectedUid)
	end
	for i = #view.fishSlots, #fishRows + 1, -1 do
		view.fishSlots[i].button:Destroy()
		table.remove(view.fishSlots, i)
	end

	-- Empty inventory wells (#fishRows + 1 .. totalSlots)
	local emptyNeeded = totalSlots - #fishRows
	for k = 1, emptyNeeded do
		local slotNum = #fishRows + k
		local well = view.emptySlots[k]
		if not well then
			well = makeEmptySlot(view.backpackGrid, slotNum)
			view.emptySlots[k] = well
		else
			well.LayoutOrder = slotNum
			local idxLabel = well:FindFirstChild("SlotIndex")
			if idxLabel and idxLabel:IsA("TextLabel") then
				idxLabel.Text = tostring(slotNum)
			end
		end
	end
	for k = #view.emptySlots, emptyNeeded + 1, -1 do
		view.emptySlots[k]:Destroy()
		table.remove(view.emptySlots, k)
	end
end

function ManagementPanel.Clear(view: View)
	for _, card in view.cards do
		card.frame:Destroy()
	end
	table.clear(view.cards)
end

function ManagementPanel.Render(
	view: View,
	tab: string,
	title: string,
	rows: { Row },
	footer: string,
	count: string?,
	capacity: number?
)
	if view.tab ~= tab then
		ManagementPanel.Clear(view)
		view.list.CanvasPosition = Vector2.zero
		if tab == "Backpack" then
			view.backpackGrid.CanvasPosition = Vector2.zero
		end
	end
	view.tab, view.title.Text, view.footer.Text = tab, title, footer
	view.count.Visible = count ~= nil
	view.count.Text = count or ""

	local isBackpack = tab == "Backpack"
	view.backpackView.Visible = isBackpack
	view.list.Visible = not isBackpack

	if isBackpack then
		renderBackpack(view, rows, capacity)
	else
		for i, row in rows do
			local card = view.cards[i]
			if card and sameAppearance(card.row, row) then
				card.row = row
			else
				if card then
					card.frame:Destroy()
				end
				view.cards[i] = makeCard(view, row, i)
			end
		end
		for i = #view.cards, #rows + 1, -1 do
			view.cards[i].frame:Destroy()
			table.remove(view.cards, i)
		end
	end

	local wasVisible = view.root.Visible
	view.root.Visible = true
	if not wasVisible then
		if view.popTween then
			view.popTween:Cancel()
		end
		view.scale.Scale = 0.92
		local tween = TweenService:Create(view.scale, POP_IN_TWEEN, { Scale = 1 })
		view.popTween = tween
		tween:Play()
	end
end

return ManagementPanel
