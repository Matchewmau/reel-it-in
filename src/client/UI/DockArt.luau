--!strict
-- Crisp multi-layered procedural illustrations drawn in a 48x48 virtual square
-- for the bottom Navigation Tray (`reference/HUD design.jpeg`).

local Kit = require(script.Parent.Kit)

local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)

local DockArt = {}

-- Places a piece in 48x48 coordinates using proportional scale corners so icons
-- stay razor-sharp on both desktop (50x50) and compact mobile (34x34) tiles.
local function shape(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3,
	radius: number,
	angle: number?,
	alpha: number?
): Frame
	local part = Kit.Frame({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x / 48, y / 48),
		Size = UDim2.fromScale(w / 48, h / 48),
		BackgroundColor3 = color,
		BackgroundTransparency = alpha or 0,
		Rotation = angle or 0,
		Active = false,
		Parent = parent,
	})
	if radius > 0 then
		local corner = Instance.new("UICorner")
		local shortSide = math.max(0.001, math.min(w, h))
		corner.CornerRadius = UDim.new(math.clamp(radius / shortSide, 0, 0.5), 0)
		corner.Parent = part
	end
	return part
end

local function shaded(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	h: number,
	top: Color3,
	bottom: Color3,
	radius: number,
	strokeColor: Color3?,
	strokeThickness: number?,
	angle: number?
): Frame
	local piece = shape(parent, x, y, w, h, top, radius, angle)
	Kit.Gradient(piece, top, bottom)
	if strokeColor then
		Kit.Stroke(piece, strokeColor, strokeThickness or 1.4)
	end
	return piece
end

local function drawBackpack(parent: GuiObject)
	local outline = rgb(44, 24, 15)
	-- Soft drop shadow
	shape(parent, 24, 29.5, 36, 27, rgb(18, 10, 6), 7, 0, 0.55)

	-- Top stitched leather carry handle
	local handleOuter = shape(parent, 24, 10.8, 14.5, 10.5, outline, 5)
	handleOuter.BackgroundTransparency = 1
	Kit.Stroke(handleOuter, outline, 3.2)
	local handleInner = shape(parent, 24, 10.8, 14.5, 10.5, outline, 5)
	handleInner.BackgroundTransparency = 1
	Kit.Stroke(handleInner, rgb(164, 102, 54), 1.6)

	-- Side gusset pouches
	for _, x in { 7.8, 40.2 } do
		shaded(parent, x, 29.5, 6.2, 13.5, rgb(166, 104, 56), rgb(88, 48, 28), 3, outline, 1.4)
	end

	-- Plump main leather body + lower front pocket
	shaded(parent, 24, 28, 32.5, 25.5, rgb(198, 132, 72), rgb(102, 58, 34), 6.5, outline, 1.8)
	shaded(parent, 24, 33.2, 25.5, 10.5, rgb(174, 110, 58), rgb(92, 52, 30), 4, rgb(64, 36, 22), 1.1)

	-- Top curved flap with warm tan gradient, specular sheen, and golden stitching
	shaded(parent, 24, 19.8, 34.5, 13.2, rgb(236, 174, 98), rgb(156, 96, 48), 5.5, outline, 1.7)
	shape(parent, 24, 15.6, 27, 2.2, WHITE, 1.2, 0, 0.78)
	for i = 0, 4 do
		shape(parent, 13 + i * 5.5, 24.3, 2.6, 1.0, rgb(252, 214, 146), 0.5, 0, 0.2)
	end

	-- Twin dark-leather vertical straps + bright gold buckles
	for _, x in { 15.8, 32.2 } do
		shaded(parent, x, 28, 5.2, 17.5, rgb(78, 46, 30), rgb(46, 26, 16), 2, rgb(30, 16, 10), 1.1)
		shaded(parent, x, 28, 7.4, 5.6, rgb(255, 224, 104), rgb(196, 134, 34), 1.6, outline, 1.2)
		shape(parent, x, 28, 3.6, 2.4, rgb(62, 36, 22), 0.8)
		shape(parent, x, 28, 1.4, 3.8, rgb(255, 240, 162), 0.7)
	end
end

local function drawSingleRod(parent: GuiObject, angle: number, reelSide: number)
	local rig = Kit.Frame({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(24 / 48, 26 / 48),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Rotation = angle,
		Active = false,
		Parent = parent,
	})
	local dark = rgb(40, 22, 12)
	local brassTop = rgb(255, 224, 104)
	local brassBot = rgb(188, 128, 32)

	-- Delicate brass line guides along the shaft
	for _, spec in { { y = 10.2, w = 2.4, h = 2.0 }, { y = 16.8, w = 2.8, h = 2.2 } } do
		local eye = shape(rig, 24 + reelSide * 1.9, spec.y, spec.w, spec.h, brassTop, 1.2)
		eye.BackgroundTransparency = 1
		Kit.Stroke(eye, Kit.Theme.Brass, 1.1)
	end

	-- Golden spinning reel + stem + crank knob
	shape(rig, 24 + reelSide * 2.6, 31.2, 3.6, 2.2, rgb(132, 88, 32), 0.8)
	shaded(rig, 24 + reelSide * 5.0, 31.2, 6.6, 6.6, brassTop, brassBot, 3.3, dark, 1.2)
	shape(rig, 24 + reelSide * 5.0, 31.2, 3.0, 3.0, rgb(76, 48, 22), 1.5)
	shape(rig, 24 + reelSide * 7.2, 29.0, 2.2, 2.2, brassTop, 1.1)

	-- Tapered wooden rod blank (amber tip + mahogany butt section)
	shaded(rig, 24, 11.4, 2.4, 12.6, rgb(222, 156, 84), rgb(146, 88, 40), 1.0, dark, 1.1)
	shaded(rig, 24, 23.2, 3.4, 13.0, rgb(182, 110, 52), rgb(108, 58, 28), 1.2, dark, 1.2)
	shaded(rig, 24, 17.5, 4.2, 2.4, brassTop, brassBot, 0.8, dark, 1.0)
	shaded(rig, 24, 5.3, 3.0, 3.0, brassTop, brassBot, 1.5, dark, 1.0)

	-- Brass foregrip collar, warm cork grip with rings, and brass pommel
	shaded(rig, 24, 29.8, 5.0, 2.6, brassTop, brassBot, 1.0, dark, 1.0)
	shaded(rig, 24, 36.6, 5.4, 11.2, rgb(238, 188, 120), rgb(172, 116, 62), 2.0, dark, 1.3)
	shape(rig, 24, 34.4, 4.4, 0.9, rgb(138, 88, 44), 0.4, 0, 0.25)
	shape(rig, 24, 38.4, 4.4, 0.9, rgb(138, 88, 44), 0.4, 0, 0.25)
	shaded(rig, 24, 43.0, 5.6, 2.8, brassTop, brassBot, 1.4, dark, 1.1)
end

local function drawRods(parent: GuiObject)
	local lineCol = rgb(206, 244, 255)
	local dark = rgb(32, 20, 16)

	-- Curved silver-cyan fishing line from top-left tip (-38° rod) to classic red/white bobber
	shape(parent, 9.6, 12.6, 1.3, 6.2, lineCol, 0.6, 28, 0.1)
	shape(parent, 7.8, 18.0, 1.3, 5.8, lineCol, 0.6, 6, 0.1)
	shape(parent, 8.1, 22.8, 1.3, 4.8, lineCol, 0.6, -14, 0.1)

	shape(parent, 8.8, 26.8, 6.2, 6.2, dark, 3.1)
	shape(parent, 8.8, 27.0, 4.6, 4.6, rgb(248, 250, 255), 2.3)
	shape(parent, 8.8, 25.8, 4.4, 2.4, rgb(232, 62, 48), 1.2)
	shape(parent, 8.8, 24.0, 1.6, 1.8, Kit.Theme.Gold, 0.8)

	-- Curved silver-cyan fishing line from top-right tip (+38° rod) to gleaming J-hook
	shape(parent, 38.4, 12.6, 1.3, 6.2, lineCol, 0.6, -28, 0.1)
	shape(parent, 40.2, 18.0, 1.3, 5.8, lineCol, 0.6, -6, 0.1)
	shape(parent, 39.9, 22.8, 1.3, 4.8, lineCol, 0.6, 14, 0.1)

	shape(parent, 39.5, 24.4, 2.2, 2.2, Kit.Theme.Gold, 1.1)
	shape(parent, 39.4, 26.5, 1.5, 4.2, rgb(232, 242, 252), 0.7, 8)
	shape(parent, 38.0, 28.4, 3.4, 1.6, rgb(232, 242, 252), 0.8, -10)
	shape(parent, 36.7, 27.2, 1.4, 2.6, rgb(232, 242, 252), 0.7, -18)

	-- Crossed twin wooden/brass rods (-38° back, +38° front)
	drawSingleRod(parent, -38, 1)
	drawSingleRod(parent, 38, -1)
end

local function drawBaits(parent: GuiObject)
	-- Plump S-curved coral/orange earthworm from tail (bottom-right) to head (upper-left)
	local spine: { { x: number, y: number, s: number, band: boolean? } } = {
		{ x = 27.2, y = 39.2, s = 6.8 },
		{ x = 31.8, y = 38.0, s = 7.8 },
		{ x = 34.6, y = 34.4, s = 8.6 },
		{ x = 32.4, y = 30.2, s = 9.2 },
		{ x = 27.2, y = 28.8, s = 9.6 },
		{ x = 21.8, y = 28.2, s = 9.8 },
		{ x = 18.2, y = 25.0, s = 10.0 },
		{ x = 19.6, y = 20.2, s = 10.8, band = true }, -- Clitellum saddle band
		{ x = 23.2, y = 16.2, s = 11.0, band = true }, -- Clitellum saddle band
		{ x = 23.8, y = 12.2, s = 10.0 },
		{ x = 19.2, y = 10.6, s = 10.2 },
		{ x = 14.6, y = 12.6, s = 10.4 },
		{ x = 12.2, y = 17.0, s = 10.8 }, -- Head
	}

	-- Pass 1: Soft drop shadow
	for _, node in spine do
		shape(parent, node.x, node.y + 1.6, node.s + 3.2, node.s + 3.2, rgb(24, 12, 6), (node.s + 3.2) * 0.5, 0, 0.6)
	end

	-- Pass 2: Unified warm dark-chocolate outline
	local outline = rgb(54, 22, 14)
	for _, node in spine do
		local d = node.s + 3.4
		shape(parent, node.x, node.y, d, d, outline, d * 0.5)
	end

	-- Pass 3: Overlapping plump segments + lighter peach clitellum band
	for index, node in spine do
		if index > 1 then
			-- Subtle warm terracotta segment crease before each overlapping segment
			shape(parent, node.x, node.y, node.s + 0.8, node.s + 0.8, rgb(158, 48, 22), (node.s + 0.8) * 0.5)
		end
		local top = if node.band then rgb(255, 214, 152) else rgb(255, 152, 84)
		local bot = if node.band then rgb(236, 146, 76) else rgb(212, 76, 36)
		local seg = shape(parent, node.x, node.y, node.s, node.s, top, node.s * 0.5)
		Kit.Gradient(seg, top, bot)
	end

	-- Pass 4: Specular highlight dots & cute eye
	shape(parent, 18.8, 8.9, 4.2, 2.0, WHITE, 1.0, -8, 0.25)
	shape(parent, 22.0, 14.8, 3.4, 2.0, WHITE, 1.0, -35, 0.24)
	shape(parent, 26.8, 26.9, 4.4, 2.0, WHITE, 1.0, 8, 0.28)
	shape(parent, 34.4, 33.2, 2.4, 1.8, WHITE, 0.9, 30, 0.3)
	shape(parent, 10.6, 15.2, 3.4, 2.2, WHITE, 1.1, -24, 0.22)

	shape(parent, 13.8, 16.6, 2.4, 2.4, rgb(42, 16, 12), 1.2)
	shape(parent, 13.3, 16.1, 1.0, 1.0, WHITE, 0.5)
end

local function drawReed(parent: GuiObject, x: number, topY: number, height: number, angle: number)
	local dark = rgb(34, 54, 22)
	local rad = math.rad(angle)
	local dx = math.sin(rad)
	local dy = math.cos(rad)
	local midY = topY + height * 0.5

	-- Slender green stem + top spike
	shaded(
		parent,
		x - dx * (height * 0.1),
		midY,
		2.0,
		height,
		rgb(134, 192, 68),
		rgb(78, 132, 42),
		1.0,
		dark,
		0.9,
		angle
	)
	shape(parent, x + dx * (height * 0.48), topY - dy * 1.4, 1.2, 4.0, rgb(126, 178, 62), 0.6, angle)

	-- Plump velvety brown cattail cigar + warm highlight
	local headX = x + dx * (height * 0.22)
	local headY = topY + dy * 4.2
	shaded(parent, headX, headY, 3.8, 7.6, rgb(164, 98, 48), rgb(94, 50, 24), 1.9, dark, 1.1, angle)
	shape(parent, headX - 0.6, headY - 0.4, 1.1, 5.2, rgb(224, 164, 96), 0.6, angle, 0.35)
end

local function drawPond(parent: GuiObject)
	local bankDark = rgb(30, 56, 24)

	-- 3 cattail reeds + swaying grass blades rising behind the pond bank
	shape(parent, 8.6, 23.5, 2.0, 10.5, rgb(132, 194, 66), 1.0, -24)
	shape(parent, 20.0, 22.5, 1.8, 9.5, rgb(118, 182, 58), 0.9, 16)
	shape(parent, 39.4, 23.8, 2.0, 10.0, rgb(132, 194, 66), 1.0, 24)
	drawReed(parent, 11.4, 9.8, 18.0, -12)
	drawReed(parent, 16.2, 7.4, 20.0, -3)
	drawReed(parent, 36.2, 10.4, 17.5, 11)

	-- Drop shadow + grassy bank rim + side grass tufts
	shape(parent, 24, 33.8, 42, 20, rgb(16, 36, 20), 10, 0, 0.5)
	shape(parent, 6.4, 30.8, 6.2, 4.6, rgb(138, 202, 70), 2.3, -12)
	shape(parent, 41.6, 31.2, 6.2, 4.6, rgb(126, 188, 62), 2.3, 12)
	shaded(parent, 24, 32.0, 42, 19.6, rgb(156, 218, 80), rgb(74, 140, 44), 9.8, bankDark, 1.9)

	-- Sandy shoreline lip + lush turquoise water oval
	shaded(parent, 24, 32.5, 36.6, 14.8, rgb(212, 186, 116), rgb(148, 122, 68), 7.4)
	shaded(parent, 24, 32.8, 34.4, 13.2, rgb(108, 238, 248), rgb(22, 134, 176), 6.6, rgb(20, 96, 126), 1.2)
	shape(parent, 25.5, 33.6, 23, 7.4, rgb(28, 158, 198), 3.7, 0, 0.45)

	-- Golden sunlit water shimmer & aqua ripples
	shape(parent, 29.6, 30.4, 10.4, 2.1, rgb(255, 242, 154), 1.1, 0, 0.16)
	shape(parent, 32.6, 33.6, 6.6, 1.7, rgb(255, 228, 124), 0.9, 0, 0.24)
	shape(parent, 23.2, 36.4, 10.8, 1.5, rgb(198, 252, 248), 0.8, 0, 0.32)

	-- Plump lily pad with V-notch and pink lotus bud
	shaded(parent, 17.4, 33.0, 11.4, 6.0, rgb(146, 224, 84), rgb(66, 152, 44), 3.0, rgb(28, 76, 26), 1.1, -8)
	shape(parent, 22.0, 32.8, 2.8, 1.8, rgb(64, 194, 218), 0.6, 12)
	shape(parent, 16.6, 31.6, 3.4, 2.5, rgb(255, 156, 186), 1.2)
	shape(parent, 16.6, 31.3, 1.6, 1.5, rgb(255, 244, 196), 0.8)
end

local function drawShop(parent: GuiObject)
	local dark = rgb(40, 20, 12)
	-- Soft drop shadow + wooden booth frame
	shape(parent, 24, 27.5, 38, 34, rgb(24, 12, 8), 5, 0, 0.48)
	shaded(parent, 24, 27.0, 34, 26, rgb(124, 72, 38), rgb(76, 42, 22), 3, dark, 1.8)

	-- Dark counter interior with cozy merchant wares silhouettes
	shaded(parent, 24, 25.5, 28, 13, rgb(42, 28, 32), rgb(22, 14, 18), 1.5)
	shape(parent, 17.5, 27.8, 4.4, 5.0, rgb(218, 164, 62), 1.4, 0, 0.25)
	shape(parent, 29.5, 28.0, 3.8, 4.6, rgb(76, 178, 194), 1.2, 0, 0.28)

	-- Side support posts
	for _, x in { 9.2, 38.8 } do
		shaded(parent, x, 25.5, 3.6, 15, rgb(176, 114, 58), rgb(108, 62, 32), 1.0, dark, 1.1)
	end

	-- Carved wood stall front with vertical plank grooves
	shaded(parent, 24, 37.2, 33.4, 10.6, rgb(198, 134, 68), rgb(114, 66, 34), 2.2, dark, 1.6)
	for _, x in { 15.6, 24.0, 32.4 } do
		shape(parent, x, 37.2, 1.1, 9.0, rgb(74, 42, 22), 0.4, 0, 0.25)
	end

	-- Warm wood counter overhang + top sheen
	shaded(parent, 24, 31.8, 38.4, 4.6, rgb(242, 188, 108), rgb(172, 110, 52), 2.0, dark, 1.6)
	shape(parent, 24, 30.5, 35, 1.2, WHITE, 0.6, 0, 0.72)

	-- Top wooden header beam + under-awning shadow
	shaded(parent, 24, 8.8, 34, 3.2, rgb(186, 122, 62), rgb(118, 68, 34), 1.4, dark, 1.4)
	shape(parent, 24, 22.8, 35, 3.0, rgb(20, 10, 12), 1.5, 0, 0.45)

	-- 5 alternating red-and-cream striped awning panels with rounded scallops
	for i = 0, 4 do
		local cx = 9.6 + i * 7.2
		local isRed = i % 2 == 0
		local top = if isRed then rgb(228, 68, 52) else rgb(255, 244, 208)
		local bot = if isRed then rgb(162, 36, 28) else rgb(224, 192, 140)
		shaded(parent, cx, 20.6, 7.4, 6.4, bot, bot:Lerp(dark, 0.25), 3.6, dark, 1.3)
		shaded(parent, cx, 15.0, 7.4, 10.4, top, bot, 1.6, dark, 1.1)
	end
	shape(parent, 24, 11.6, 34, 2.0, WHITE, 1.0, 0, 0.8)
end

local function drawContinent(parent: GuiObject, x: number, y: number, w: number, h: number, angle: number)
	local piece = shape(parent, x, y, w, h, rgb(144, 232, 96), math.min(w, h) * 0.46, angle)
	Kit.Gradient(piece, rgb(148, 236, 98), rgb(42, 148, 64))
end

local function drawTravel(parent: GuiObject)
	-- Soft drop shadow + crisp dark-stroked brass bezel
	shape(parent, 24, 25.8, 39, 39, rgb(12, 24, 36), 19.5, 0, 0.48)
	shaded(parent, 24, 24.5, 38, 38, rgb(246, 202, 96), rgb(144, 96, 34), 19, rgb(20, 30, 44), 2.0)

	-- Vibrant ocean-blue globe sphere with diagonal depth shading
	local ocean = shape(parent, 24, 24.5, 33.6, 33.6, rgb(78, 208, 252), 16.8)
	local oceanGrad = Kit.Gradient(ocean, rgb(84, 214, 255), rgb(18, 86, 166))
	oceanGrad.Rotation = 65

	-- Shallow turquoise coastal reefs
	shape(parent, 16.8, 18.2, 10.6, 8.0, rgb(108, 238, 242), 4.0, -18, 0.55)
	shape(parent, 19.4, 29.0, 8.0, 9.6, rgb(108, 238, 242), 4.0, -10, 0.55)
	shape(parent, 29.8, 18.0, 10.0, 7.6, rgb(108, 238, 242), 3.8, 15, 0.55)
	shape(parent, 30.4, 26.2, 8.0, 8.6, rgb(108, 238, 242), 4.0, 8, 0.55)

	-- Emerald-green continents (all bounded well within the r=16.8 sphere)
	drawContinent(parent, 16.8, 18.0, 9.2, 6.8, -18)
	drawContinent(parent, 17.4, 23.2, 3.8, 4.8, 18)
	drawContinent(parent, 19.4, 29.2, 6.8, 8.6, -10)
	drawContinent(parent, 29.8, 17.8, 8.8, 6.6, 15)
	drawContinent(parent, 26.8, 21.2, 5.2, 4.2, -8)
	drawContinent(parent, 30.4, 26.2, 6.8, 7.8, 8)
	drawContinent(parent, 25.4, 34.2, 3.8, 2.6, -12)

	-- Sunlit lime highland accents
	shape(parent, 16.2, 17.2, 5.0, 3.2, rgb(194, 248, 128), 1.6, -18, 0.45)
	shape(parent, 29.4, 17.0, 4.8, 3.0, rgb(194, 248, 128), 1.5, 15, 0.45)

	-- Polar cap, glossy specular highlights, and deep-ocean bottom shade
	shape(parent, 24.0, 10.2, 10.4, 2.6, WHITE, 1.3, 0, 0.48)
	shape(parent, 17.2, 14.8, 8.6, 4.0, WHITE, 2.0, -34, 0.42)
	shape(parent, 13.2, 19.4, 2.6, 2.6, WHITE, 1.3, 0, 0.5)
	shape(parent, 28.4, 30.6, 13.5, 7.5, rgb(10, 36, 82), 3.8, -28, 0.68)

	-- Razor-sharp inner dark ocean rim
	local innerRim = shape(parent, 24, 24.5, 33.6, 33.6, WHITE, 16.8)
	innerRim.BackgroundTransparency = 1
	Kit.Stroke(innerRim, rgb(16, 36, 62), 1.8)
end

function DockArt.Draw(parent: GuiObject, tab: string)
	if tab == "Backpack" then
		drawBackpack(parent)
	elseif tab == "Rods" then
		drawRods(parent)
	elseif tab == "Baits" then
		drawBaits(parent)
	elseif tab == "Pond" then
		drawPond(parent)
	elseif tab == "Shop" then
		drawShop(parent)
	else
		drawTravel(parent)
	end
end

return DockArt
