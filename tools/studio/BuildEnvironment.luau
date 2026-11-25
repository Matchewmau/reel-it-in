--[[
	Environment builder: dresses "The Basin" (reference/revised map.jpeg).

	BuildGreybox.luau makes the bare terrain; this script adds everything that
	makes it read as a place: the pine forest on top of the cliff ring, rock
	slabs and moss on the cliff faces, a thinner forest on the basin floor, the
	market huts and vendor NPCs, reeds and lily pads on the river and lagoon,
	crystals and lanterns round the Abyss, lamp posts, a few birds, and the
	Lighting mood. Everything lives in Workspace.Map.Decor.

	HOW TO RUN (edit mode, never during a playtest), AFTER BuildGreybox.luau:
	  * Studio MCP: pass this whole file to the `execute_luau` tool, or
	  * paste it into Studio's Command Bar.
	  Check it first with `lune run tools/studio/dryrun_environment.luau`.

	This is build tooling, not game code: it creates instances only, never
	scripts. It is idempotent: re-running replaces a Decor folder this script
	made and refuses to touch one it did not. The layout is generated from fixed
	seeds, so every run produces the same world.

	HOW IT WORKS
	  The script reads the map the greybox built instead of repeating its
	  numbers: the Map.Terrain tiles are rasterised into a grid (grass, sand,
	  boardwalk, pond rim, water; nothing = a pond hole or the Abyss), cliff tops
	  are read from the CliffTop parts, and ponds, vendors and travel markers are
	  found by name. Every prop is described as a list of boxes first, checked
	  against the placement rules below, and only then created.

	PLACEMENT RULES (asserted by dryrun_environment.luau)
	  For every decor part whose bottom is at or below y = 12 on the basin floor:
	  a. Ground props stand on grass (market props may stand on the plaza sand)
	     and stay 1.5 studs clear of boardwalks, pond rims, water and holes.
	  b. Water props sit on river / lagoon water at the surface, or on the Abyss
	     water far below, within 46 studs of its centre.
	  c. 7 studs stay clear around vendor prompts, the hub spawn pad, travel
	     markers and each pond's Spawn, FeedNode and gate, plus a 9-stud corridor
	     from each pond Spawn to its water.
	  d. The hub plaza stays empty apart from small market props hugging the
	     vendors on its north side.
	  e. Nothing taller than 9 studs stands within 34 studs of a pond centre.
	  Nothing is placed in the Falls corridor (x -22..22, z < -200).

	CONTRACT WITH THE CLIENT (AmbientController)
	  Attributes on a Model (with PrimaryPart, at most 20 parts) or BasePart:
	    AmbientBob (studs), AmbientSway (degrees), AmbientOrbit (studs),
	    AmbientPeriod (seconds)
	  Attribute on every Light created here:
	    NightLight = true
	  Nothing is animated by this script.

	BUDGET: at most 1,300 parts, 40 lights, 30 animated instances.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local VERSION = 1
local BUDGET = { parts = 1300, lights = 40, animated = 30 }

-- Placement rule numbers (studs). The dry run asserts the same values.
local HUB_RADIUS = 40 -- sand plaza, centred on the origin
local MARKET_Z = -14 -- plaza props must stay north of this line
local CLEAR_RADIUS = 7 -- kept free around prompts, spawns and travel markers
local CORRIDOR_HALF = 4.5 -- half-width of the lane from a pond Spawn to its water
local POND_VIEW_RADIUS = 34 -- nothing tall this close to a pond centre...
local POND_VIEW_HEIGHT = 9 -- ...where tall means above this
local FLOOR_SCOPE_Y = 12 -- parts whose bottom is at or below this are floor decor
local FLOOR_SCOPE_RADIUS = 234 -- ...when they are inside this radius
local FOOT_MARGIN = 1.5 -- gap between a ground prop and boardwalk / rim / water
local FALLS = { halfX = 22, z = -200 } -- corridor kept clear for The Falls
local ABYSS_PROP_RADIUS = 46 -- props on the Abyss water stay inside this
local SLACK = 0.1 -- extra clearance so float rounding never breaks a rule

-- How much of everything. Tuned against BUDGET.parts.
local COUNTS = {
	cliffPines = 122,
	cliffBushes = 26,
	cliffBoulders = 14,
	forestPines = 48,
	forestBushes = 28,
	forestBoulders = 20,
	forestFlowers = 14,
	riverReeds = 9,
	lagoonReeds = 5,
	riverRocks = 6,
	lagoonRocks = 3,
	riverWaterReeds = 2,
	lagoonWaterReeds = 3,
	riverLilies = 3,
	lagoonLilies = 9,
	steppingRocks = 5,
}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local COLOR = {
	Bark = rgb(96, 68, 46),
	-- Three pine palettes, each dark at the skirt and lighter toward the tip.
	Needles = {
		{ rgb(38, 92, 58), rgb(46, 104, 64), rgb(56, 118, 72) },
		{ rgb(32, 82, 62), rgb(40, 96, 70), rgb(50, 110, 80) },
		{ rgb(46, 100, 52), rgb(54, 112, 58), rgb(66, 126, 66) },
	},
	Bush = { rgb(98, 170, 84), rgb(120, 188, 92), rgb(86, 156, 92) },
	Rock = { rgb(132, 136, 144), rgb(110, 114, 124), rgb(150, 152, 158) },
	Moss = { rgb(78, 138, 72), rgb(92, 152, 78) },
	Bloom = { rgb(255, 214, 92), rgb(240, 110, 150), rgb(250, 250, 250), rgb(170, 120, 255), rgb(255, 140, 70) },
	Reed = rgb(110, 150, 70),
	ReedHead = rgb(112, 76, 48),
	LilyPad = { rgb(70, 150, 80), rgb(86, 168, 90) },
	Wood = rgb(156, 110, 66),
	WoodDark = rgb(108, 74, 46),
	WoodLight = rgb(196, 152, 102),
	Stone = rgb(132, 136, 144),
	StoneDark = rgb(92, 96, 104),
	Plaster = rgb(232, 220, 196),
	Paper = rgb(246, 240, 222),
	Glass = rgb(255, 226, 150),
	LampGlow = rgb(255, 214, 140),
	LampLight = rgb(255, 196, 120),
	Skin = rgb(236, 196, 160),
	Gold = rgb(255, 204, 64),
	Basalt = { rgb(58, 62, 78), rgb(44, 48, 64) },
	Crystal = { rgb(90, 220, 255), rgb(170, 120, 255), rgb(80, 255, 200) },
	AbyssGlow = rgb(110, 225, 255),
	BuoyRed = rgb(220, 70, 60),
	White = rgb(244, 244, 244),
	Terracotta = rgb(188, 104, 72),
}

-- Preconditions: fail before touching anything ------------------------------------------

local map = Workspace:FindFirstChild("Map")
if not map or map:GetAttribute("GreyboxVersion") == nil then
	error(
		"BuildEnvironment needs Workspace.Map made by BuildGreybox (attribute GreyboxVersion) - run BuildGreybox.luau first."
	)
end
local existing = map:FindFirstChild("Decor")
if existing and existing:GetAttribute("EnvironmentVersion") == nil then
	error("Workspace.Map.Decor already exists and was not made by BuildEnvironment - rename or remove it first.")
end

local function need(parent, name)
	local child = parent:FindFirstChild(name)
	if not child then
		error(`BuildEnvironment: Workspace.Map is missing {parent.Name}.{name} - re-run BuildGreybox.luau first.`)
	end
	return child
end

local terrainFolder = need(map, "Terrain")
local cliffsFolder = need(map, "Cliffs")
local pondsFolder = need(map, "Ponds")
local vendorsFolder = need(map, "Vendors")
local travelFolder = need(map, "TravelPoints")
local hubFolder = need(map, "Hub")
local abyssWater = need(need(map, "Abyss"), "Water")

-- Deterministic random numbers (Park-Miller; exact in doubles, same on every run) --------

local function newRng(seed)
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	local rng = {}
	function rng.next() -- [0, 1)
		state = (state * 48271) % 2147483647
		return (state - 1) / 2147483646
	end
	function rng.range(low, high)
		return low + (high - low) * rng.next()
	end
	function rng.int(low, high)
		return low + math.floor(rng.next() * (high - low + 1))
	end
	function rng.chance(probability)
		return rng.next() < probability
	end
	function rng.sign()
		return if rng.next() < 0.5 then -1 else 1
	end
	rng.next()
	rng.next()
	return rng
end

local function shuffle(list, rng)
	for index = #list, 2, -1 do
		local other = rng.int(1, index)
		list[index], list[other] = list[other], list[index]
	end
end

-- Geometry helpers ----------------------------------------------------------------------

-- Axis-aligned bounds of a box with the given CFrame and size.
local function boundsOf(cframe, size)
	local a = cframe:VectorToWorldSpace(Vector3.new(size.X / 2, 0, 0))
	local b = cframe:VectorToWorldSpace(Vector3.new(0, size.Y / 2, 0))
	local c = cframe:VectorToWorldSpace(Vector3.new(0, 0, size.Z / 2))
	local ex = math.abs(a.X) + math.abs(b.X) + math.abs(c.X)
	local ey = math.abs(a.Y) + math.abs(b.Y) + math.abs(c.Y)
	local ez = math.abs(a.Z) + math.abs(b.Z) + math.abs(c.Z)
	local p = cframe.Position
	return {
		cf = cframe,
		x = p.X,
		y = p.Y,
		z = p.Z,
		minX = p.X - ex,
		maxX = p.X + ex,
		minY = p.Y - ey,
		maxY = p.Y + ey,
		minZ = p.Z - ez,
		maxZ = p.Z + ez,
	}
end

-- Horizontal distance from a point to a footprint rectangle (0 when inside).
local function rectDistance(bounds, x, z)
	local dx = math.max(bounds.minX - x, 0, x - bounds.maxX)
	local dz = math.max(bounds.minZ - z, 0, z - bounds.maxZ)
	return math.sqrt(dx * dx + dz * dz)
end

local function polar(degrees, radius)
	local a = math.rad(degrees)
	return math.cos(a) * radius, math.sin(a) * radius
end

-- Terrain grid: what the greybox put at each spot ------------------------------------------

local STEP = 2 -- the greybox tiles are multiples of 4, so a 2-stud raster is exact
local GRID_EXTENT = 244
local GRID_COUNT = GRID_EXTENT * 2 / STEP
local GRASS, SAND, RIM, WALK, WATER = 1, 2, 4, 8, 16
local TILE_FLAG = { Grass = GRASS, Sand = SAND, PondRim = RIM, Boardwalk = WALK, Water = WATER }
local STANDABLE = bit32.bor(GRASS, SAND)
local BLOCKED = bit32.bor(RIM, WALK, WATER)

local cells = table.create(GRID_COUNT * GRID_COUNT, 0)
local waterSurfaceY = -1.2

local function cellOf(x, z)
	return math.floor((x + GRID_EXTENT) / STEP) + 1, math.floor((z + GRID_EXTENT) / STEP) + 1
end

local function cellCenter(i, j)
	return -GRID_EXTENT + (i - 0.5) * STEP, -GRID_EXTENT + (j - 0.5) * STEP
end

local function cellFlags(i, j)
	if i < 1 or i > GRID_COUNT or j < 1 or j > GRID_COUNT then
		return 0
	end
	return cells[(j - 1) * GRID_COUNT + i]
end

local function flagsAt(x, z)
	return cellFlags(cellOf(x, z))
end

for _, tile in terrainFolder:GetChildren() do
	local flag = TILE_FLAG[tile.Name]
	if flag and tile:IsA("BasePart") then
		local bounds = boundsOf(tile.CFrame, tile.Size)
		local i0, j0 = cellOf(bounds.minX + 0.01, bounds.minZ + 0.01)
		local i1, j1 = cellOf(bounds.maxX - 0.01, bounds.maxZ - 0.01)
		for j = math.max(j0, 1), math.min(j1, GRID_COUNT) do
			for i = math.max(i0, 1), math.min(i1, GRID_COUNT) do
				local index = (j - 1) * GRID_COUNT + i
				cells[index] = bit32.bor(cells[index], flag)
			end
		end
		if flag == WATER then
			waterSurfaceY = bounds.maxY
		end
	end
end

-- True when every cell under the rectangle has one of `wanted` and none of `forbidden`.
local function rectOnly(minX, maxX, minZ, maxZ, wanted, forbidden)
	local i0, j0 = cellOf(minX + 1e-4, minZ + 1e-4)
	local i1, j1 = cellOf(maxX - 1e-4, maxZ - 1e-4)
	for j = j0, j1 do
		for i = i0, i1 do
			local flags = cellFlags(i, j)
			if bit32.band(flags, wanted) == 0 or bit32.band(flags, forbidden) ~= 0 then
				return false
			end
		end
	end
	return true
end

-- True when any cell under the rectangle has one of `flags`.
local function rectTouches(minX, maxX, minZ, maxZ, flags)
	local i0, j0 = cellOf(minX, minZ)
	local i1, j1 = cellOf(maxX, maxZ)
	for j = j0, j1 do
		for i = i0, i1 do
			if bit32.band(cellFlags(i, j), flags) ~= 0 then
				return true
			end
		end
	end
	return false
end

-- Landmarks read from the greybox ----------------------------------------------------------

local clearCircles = {} -- { x, z }: rule c
local clearLanes = {} -- { ax, az, bx, bz }: rule c corridors
local obstacles = {} -- greybox props decor must not intersect: { cf, size, bounds }

local function keepClear(part)
	local p = part.CFrame.Position
	table.insert(clearCircles, { p.X, p.Z })
end

local function obstacle(part)
	table.insert(obstacles, { cf = part.CFrame, size = part.Size, bounds = boundsOf(part.CFrame, part.Size) })
end

-- The Abyss: centre and water level from its Water disc; the hole from the grid.
local abyss = {}
do
	local bounds = boundsOf(abyssWater.CFrame, abyssWater.Size)
	abyss.x, abyss.z, abyss.surfaceY = bounds.x, bounds.z, bounds.maxY
	local holeMin, edges = math.huge, {}
	for step = 0, 35 do
		local dx, dz = polar(step * 10, 1)
		local d = 0
		while d < 150 and flagsAt(abyss.x + dx * d, abyss.z + dz * d) == 0 do
			d += 1
		end
		holeMin = math.min(holeMin, d)
		while d < 150 and bit32.band(flagsAt(abyss.x + dx * d, abyss.z + dz * d), WALK) ~= 0 do
			d += 1
		end
		table.insert(edges, d)
	end
	table.sort(edges)
	abyss.holeRadius = holeMin
	abyss.ringRadius = edges[math.ceil(#edges / 2)] -- median: ignores spokes that run on outward
end

local ponds = {}
for _, pond in pondsFolder:GetChildren() do
	local water = pond:FindFirstChild("Water")
	if water and water:IsA("BasePart") then
		local center = water.CFrame.Position
		local sign = pond:FindFirstChild("Sign")
		local toHub = Vector3.new(-center.X, 0, -center.Z).Unit
		if sign then
			local gate = sign.CFrame.Position
			toHub = Vector3.new(gate.X - center.X, 0, gate.Z - center.Z).Unit
		end
		local record = {
			plot = pond:GetAttribute("Plot") or #ponds + 1,
			x = center.X,
			z = center.Z,
			toHub = toHub,
			side = Vector3.new(-toHub.Z, 0, toHub.X),
		}
		for _, child in pond:GetChildren() do
			if child:IsA("BasePart") then
				local name = child.Name
				if name == "Spawn" or name == "FeedNode" or name == "Sign" or name == "GatePost" then
					keepClear(child)
				end
				if name == "FeedNode" or name == "FeedBowl" or name == "Sign" or name == "GatePost" then
					obstacle(child)
				end
				if name == "Spawn" then
					local p = child.CFrame.Position
					table.insert(clearLanes, { p.X, p.Z, center.X, center.Z })
				end
			end
		end
		table.insert(ponds, record)
	end
end
table.sort(ponds, function(a, b)
	return a.plot < b.plot
end)

local vendors = {}
for _, vendor in vendorsFolder:GetChildren() do
	local prompt = vendor:FindFirstChild("Prompt")
	local sign = vendor:FindFirstChild("Sign")
	if prompt and sign then
		keepClear(prompt)
		local at = sign.CFrame.Position
		-- The stall's own frame: on the ground under its sign, front (-Z) to the plaza.
		vendors[vendor.Name] = { origin = sign.CFrame * CFrame.new(0, -at.Y, 0) }
		for _, child in vendor:GetChildren() do
			if child:IsA("BasePart") and child ~= prompt then
				obstacle(child)
			end
		end
	end
end

for _, point in travelFolder:GetChildren() do
	if point:IsA("BasePart") then
		keepClear(point)
	end
end
for _, child in hubFolder:GetChildren() do
	if child:IsA("SpawnLocation") then
		keepClear(child)
		obstacle(child)
	end
end

-- Cliff ring: tops to plant on, walls and foot ledges to hang rock and moss from.
local cliffTops, cliffWalls, cliffLedges = {}, {}, {}
for _, child in cliffsFolder:GetChildren() do
	if child:IsA("BasePart") then
		local p = child.CFrame.Position
		local record = {
			cf = child.CFrame,
			size = child.Size,
			x = p.X,
			z = p.Z,
			top = p.Y + child.Size.Y / 2,
			radius = math.sqrt(p.X * p.X + p.Z * p.Z),
			angle = math.atan2(p.Z, p.X),
		}
		if child.Name == "CliffTop" then
			table.insert(cliffTops, record)
		elseif child.Name == "Cliff" then
			table.insert(cliffWalls, record)
		elseif child.Name == "CliffLedge" then
			table.insert(cliffLedges, record)
		end
	end
end
if #cliffTops == 0 or #cliffWalls == 0 then
	error("BuildEnvironment: Workspace.Map.Cliffs has no Cliff / CliffTop parts - re-run BuildGreybox.luau first.")
end
local function byAngle(a, b)
	return a.angle < b.angle
end
table.sort(cliffTops, byAngle)
table.sort(cliffWalls, byAngle)
for _, wall in cliffWalls do
	for _, ledge in cliffLedges do
		if (wall.x * ledge.x + wall.z * ledge.z) / (wall.radius * ledge.radius) > 0.9995 then
			wall.ledge = ledge
		end
	end
end

local rim = { inner = math.huge, outer = 0 }
for _, top in cliffTops do
	rim.inner = math.min(rim.inner, top.radius - top.size.Z / 2)
	rim.outer = math.max(rim.outer, top.radius + top.size.Z / 2)
end

-- Height of the cliff top under (x, z): the highest segment covering the spot, or nil.
local function cliffTopAt(x, z)
	local best = nil
	for _, top in cliffTops do
		local offset = top.cf:PointToObjectSpace(Vector3.new(x, top.cf.Position.Y, z))
		if math.abs(offset.X) <= top.size.X / 2 and math.abs(offset.Z) <= top.size.Z / 2 then
			if not best or top.top > best then
				best = top.top
			end
		end
	end
	return best
end

-- Prop descriptions -------------------------------------------------------------------------
-- A prop is { name, parts = { entry... }, occ = footprint radius, attrs?, primary?, ghost? }.
-- An entry is one box in the prop's own frame (y = 0 is the ground or the water surface).
-- Kinds: "S" solid + shadow, "s" solid, "F" foliage (no collision, shadow),
--        "D" detail (no collision, no shadow), "N" neon glow.

local KIND = {
	S = { collide = true, shadow = true },
	s = { collide = true, shadow = false },
	F = { collide = false, shadow = true },
	D = { collide = false, shadow = false },
	N = { collide = false, shadow = false, neon = true },
}

local function box(name, sx, sy, sz, x, y, z, color, kind)
	return { name = name, size = Vector3.new(sx, sy, sz), cf = CFrame.new(x, y, z), color = color, kind = kind }
end

-- The same entry turned about its own centre (degrees).
local function turned(entry, rx, ry, rz)
	entry.cf = entry.cf * CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
	return entry
end

-- An upright cylinder (Roblox cylinders run along X).
local function drum(name, diameter, height, x, y, z, color, kind)
	local entry = box(name, height, diameter, diameter, x, y, z, color, kind)
	entry.cf = entry.cf * CFrame.Angles(0, 0, math.rad(90))
	entry.shape = "Cylinder"
	return entry
end

local function lit(entry, color, range, brightness)
	entry.light = { color = color, range = range, brightness = brightness }
	return entry
end

-- Moves a list of entries by `offset` and appends them to `into`.
local function append(into, entries, offset)
	for _, entry in entries do
		entry.cf = offset * entry.cf
		table.insert(into, entry)
	end
end

local PINES = {
	{ name = "PineSmall", trunk = { 1.2, 4 }, crown = 3, tiers = { { 6, 3.6 }, { 3.6, 3.4 } } }, -- 10 tall
	{ name = "PineMedium", trunk = { 1.6, 6 }, crown = 4.5, tiers = { { 8, 5.4 }, { 4.8, 5 } } }, -- 15 tall
	{ name = "PineTall", trunk = { 2, 8 }, crown = 6, tiers = { { 10, 5 }, { 7.2, 4.8 }, { 4.4, 4.6 } } }, -- 20 tall
}

-- Stacked-box pine. `distant` trees (cliff tops, ledges) drop collision and most shadows.
local function pineParts(rng, variant, scale, distant)
	local def = PINES[variant]
	local greens = COLOR.Needles[rng.int(1, #COLOR.Needles)]
	local width, height = def.trunk[1] * scale, def.trunk[2] * scale
	local parts = {
		box("Trunk", width, height + 0.2, width, 0, height / 2 - 0.1, 0, COLOR.Bark, if distant then "D" else "S"),
	}
	local y = def.crown * scale
	for index, tier in def.tiers do
		local w, h = tier[1] * scale, tier[2] * scale
		local kind = if index == 1 or not distant then "F" else "D"
		table.insert(parts, box("Needles", w, h, w, 0, y + h / 2, 0, greens[index], kind))
		y += h
	end
	return parts, def.tiers[1][1] * scale / 2
end

local function pineSpec(rng, variant, scale, distant)
	local parts, reach = pineParts(rng, variant, scale, distant)
	return {
		name = PINES[variant].name,
		parts = parts,
		occ = reach * 0.75, -- crowns may overlap a little, for a closed canopy
		reach = reach, -- half-width of the widest tier
		foot = PINES[variant].trunk[1] * scale / 2 + 0.3, -- half-width of ground the trunk needs
		ghost = distant,
	}
end

local function bushParts(rng, scale, distant)
	local w, h = rng.range(4, 5.6) * scale, rng.range(2.6, 3.4) * scale
	local d = w * rng.range(0.85, 1.1)
	local kind = if distant then "D" else "F"
	local parts = { box("Leaves", w, h + 0.2, d, 0, h / 2 - 0.1, 0, COLOR.Bush[rng.int(1, #COLOR.Bush)], kind) }
	if rng.chance(0.5) then
		local x, z = rng.sign() * w * 0.16, rng.sign() * d * 0.16
		table.insert(
			parts,
			box("LeavesTop", w * 0.55, h * 0.5, d * 0.55, x, h + h * 0.22, z, COLOR.Bush[rng.int(1, #COLOR.Bush)], "D")
		)
	end
	return parts, math.max(w, d) / 2
end

local function bushSpec(rng, scale, distant)
	local parts, reach = bushParts(rng, scale, distant)
	return { name = "Bush", parts = parts, occ = reach, ghost = distant }
end

-- One to three grey blocks. Returns the parts, their reach and the height of the main block.
local function boulderParts(rng, scale, pieces, distant, palette)
	palette = palette or COLOR.Rock
	local w, h, d = rng.range(4, 6) * scale, rng.range(2.6, 3.8) * scale, rng.range(3.6, 5) * scale
	local parts = {
		turned(
			box("Rock", w, h + 0.3, d, 0, h / 2 - 0.15, 0, palette[rng.int(1, #palette)], if distant then "F" else "S"),
			0,
			rng.range(0, 180),
			0
		),
	}
	local angle = rng.range(0, 360)
	for piece = 2, pieces do
		local shrink = if piece == 2 then 0.6 else 0.42
		local x, z = polar(angle + (piece - 2) * 150, w * 0.58)
		table.insert(
			parts,
			turned(
				box(
					"RockSmall",
					w * shrink,
					h * shrink + 0.3,
					d * shrink,
					x,
					h * shrink / 2 - 0.15,
					z,
					palette[rng.int(1, #palette)],
					if distant then "D" else "s"
				),
				0,
				rng.range(0, 180),
				0
			)
		)
	end
	return parts, if pieces > 1 then w * 0.95 else w * 0.62, h
end

local function boulderSpec(rng, scale, pieces, distant)
	local parts, reach, height = boulderParts(rng, scale, pieces, distant)
	return {
		name = if pieces > 1 then "BoulderCluster" else "Boulder",
		parts = parts,
		occ = reach,
		ghost = distant,
		perchY = height,
	}
end

local function flowerSpec(rng)
	local blooms = COLOR.Bloom
	return {
		name = "FlowerPatch",
		occ = 1.8,
		parts = {
			box("Leaves", 3.2, 0.5, 3, 0, 0.2, 0, COLOR.Bush[rng.int(1, #COLOR.Bush)], "D"),
			box("Bloom", 0.9, 0.9, 0.9, -0.8, 0.85, 0.5, blooms[rng.int(1, #blooms)], "D"),
			box("Bloom", 0.8, 0.8, 0.8, 0.7, 0.8, -0.6, blooms[rng.int(1, #blooms)], "D"),
		},
	}
end

local function reedSpec()
	return {
		name = "Reeds",
		occ = 1.1,
		parts = {
			box("Stalk", 0.4, 4.4, 0.4, 0, 2, 0, COLOR.Reed, "D"),
			box("Cattail", 0.7, 1.3, 0.7, 0, 3.9, 0, COLOR.ReedHead, "D"),
			turned(box("Stalk", 0.4, 3.2, 0.4, 0.7, 1.45, 0.3, COLOR.Reed, "D"), 0, 0, -10),
		},
	}
end

-- Reeds standing in the shallows; y = 0 is the water surface.
local function waterReedSpec()
	return {
		name = "WaterReeds",
		occ = 1,
		ghost = true,
		parts = {
			box("Stalk", 0.4, 4.2, 0.4, -0.3, 1.2, -0.1, COLOR.Reed, "D"),
			box("Cattail", 0.7, 1.3, 0.7, -0.3, 3, -0.1, COLOR.ReedHead, "D"),
			box("Stalk", 0.4, 3, 0.4, 0.35, 0.6, 0.25, COLOR.Reed, "D"),
		},
	}
end

local function lilySpec(rng)
	local parts = { box("Pad", 2.2, 0.3, 2.2, 0, 0.1, 0, COLOR.LilyPad[rng.int(1, 2)], "D") }
	if rng.chance(0.45) then
		table.insert(
			parts,
			box("Blossom", 0.7, 0.5, 0.7, 0.3, 0.5, -0.2, if rng.chance(0.5) then COLOR.Bloom[2] else COLOR.White, "D")
		)
	end
	return {
		name = "LilyPad",
		occ = 1.4,
		ghost = true,
		parts = parts,
		attrs = { AmbientBob = 0.15, AmbientPeriod = math.floor(rng.range(2.6, 4.2) * 10) / 10 },
	}
end

local function steppingRockSpec(rng)
	local w = rng.range(2.6, 3.2)
	return {
		name = "SteppingRock",
		occ = 1.8,
		ghost = true,
		parts = { box("Rock", w, 2, w * rng.range(0.85, 1), 0, 0.1, 0, COLOR.Rock[rng.int(1, 3)], "D") },
	}
end

local function lampSpec()
	return {
		name = "LampPost",
		occ = 1.2,
		parts = {
			box("Post", 0.7, 9.6, 0.7, 0, 4.7, 0, COLOR.WoodDark, "s"),
			lit(box("Lantern", 1.5, 1.5, 1.5, 0, 10.25, 0, COLOR.LampGlow, "N"), COLOR.LampLight, 26, 1.4),
			box("Cap", 2.1, 0.4, 2.1, 0, 11.2, 0, COLOR.StoneDark, "D"),
		},
	}
end

-- Short lantern for pond sides: under the 9-stud pond sightline limit.
local function pondLanternSpec()
	return {
		name = "PondLantern",
		occ = 1.1,
		parts = {
			box("Base", 1.4, 0.7, 1.4, 0, 0.25, 0, COLOR.Stone, "s"),
			box("Post", 0.5, 4, 0.5, 0, 2.6, 0, COLOR.WoodDark, "s"),
			lit(box("Lantern", 1.2, 1.2, 1.2, 0, 5.2, 0, COLOR.LampGlow, "N"), COLOR.LampLight, 16, 1.1),
			box("Cap", 1.6, 0.3, 1.6, 0, 5.95, 0, COLOR.StoneDark, "D"),
		},
	}
end

local function abyssLanternSpec()
	return {
		name = "AbyssLantern",
		occ = 1.2,
		parts = {
			box("Post", 0.8, 7.2, 0.8, 0, 3.5, 0, COLOR.Basalt[1], "s"),
			lit(box("Lantern", 1.5, 1.5, 1.5, 0, 7.85, 0, COLOR.AbyssGlow, "N"), COLOR.AbyssGlow, 24, 1.5),
			box("Cap", 2.1, 0.4, 2.1, 0, 8.8, 0, COLOR.Basalt[2], "D"),
		},
	}
end

local function barrelSpec()
	return {
		name = "Barrel",
		occ = 1.3,
		parts = {
			drum("Body", 2.2, 2.7, 0, 1.25, 0, COLOR.Wood, "s"),
			drum("Hoop", 2.36, 0.25, 0, 0.7, 0, COLOR.StoneDark, "D"),
			drum("Hoop", 2.36, 0.25, 0, 1.9, 0, COLOR.StoneDark, "D"),
		},
	}
end

local function crateStackSpec(rng)
	return {
		name = "CrateStack",
		occ = 2,
		parts = {
			box("Crate", 2.8, 2.8, 2.8, 0, 1.3, 0, COLOR.Wood, "s"),
			turned(box("CrateSmall", 1.9, 1.9, 1.9, 0.2, 3.65, -0.1, COLOR.WoodLight, "D"), 0, rng.range(10, 35), 0),
		},
	}
end

local function crateSpec()
	return {
		name = "Crate",
		occ = 1.6,
		parts = {
			box("Crate", 2.4, 2.4, 2.4, 0, 1.1, 0, COLOR.WoodLight, "s"),
			box("Lid", 2.6, 0.3, 2.6, 0, 2.45, 0, COLOR.WoodDark, "D"),
		},
	}
end

local function noticeBoardSpec()
	return {
		name = "NoticeBoard",
		occ = 3,
		parts = {
			box("Board", 5.6, 3, 0.3, 0, 3.6, 0, COLOR.WoodLight, "s"),
			box("Post", 0.5, 5.2, 0.5, -2.5, 2.5, 0.1, COLOR.WoodDark, "s"),
			box("Post", 0.5, 5.2, 0.5, 2.5, 2.5, 0.1, COLOR.WoodDark, "s"),
			box("Roof", 6.4, 0.4, 1.4, 0, 5.4, 0, COLOR.WoodDark, "D"),
			box("Notice", 1.1, 1.4, 0.1, -1.4, 3.7, -0.2, COLOR.Paper, "D"),
			turned(box("Notice", 1, 1.2, 0.1, 0.9, 3.5, -0.2, COLOR.Bloom[1], "D"), 0, 0, 6),
		},
	}
end

local function flowerPotSpec(rng)
	return {
		name = "FlowerPot",
		occ = 1.3,
		parts = {
			box("Pot", 1.8, 1.6, 1.8, 0, 0.7, 0, COLOR.Terracotta, "s"),
			box("Leaves", 1.5, 0.8, 1.5, 0, 1.85, 0, COLOR.Bush[rng.int(1, 3)], "D"),
			box("Bloom", 0.8, 0.8, 0.8, 0.2, 2.6, -0.1, COLOR.Bloom[rng.int(1, #COLOR.Bloom)], "D"),
		},
	}
end

local function crystalSpec(rng, glowing)
	local color = COLOR.Crystal[rng.int(1, #COLOR.Crystal)]
	local tall = turned(box("Shard", 1.3, 5, 1.3, 0, 3, 0, color, "N"), 8, rng.range(0, 90), -10)
	if glowing then
		lit(tall, color, 14, 1.2)
	end
	return {
		name = "CrystalCluster",
		occ = 2,
		parts = {
			box("Base", 3, 1, 2.6, 0, 0.3, 0, COLOR.Basalt[rng.int(1, 2)], "s"),
			tall,
			turned(box("Shard", 1, 3.2, 1, 1, 2.1, 0.3, color, "N"), -6, 30, 16),
			turned(box("Shard", 0.8, 2.2, 0.8, -0.9, 1.6, 0.5, color, "N"), 10, 15, -18),
		},
	}
end

local function abyssRockSpec(rng)
	local parts, reach = boulderParts(rng, rng.range(0.6, 0.85), rng.int(1, 2), false, COLOR.Basalt)
	return { name = "AbyssRock", parts = parts, occ = reach }
end

-- Marker buoy; y = 0 is the water surface.
local function buoySpec(rng)
	return {
		name = "Buoy",
		occ = 1.5,
		ghost = true,
		parts = {
			box("Float", 1.8, 1.6, 1.8, 0, 0.1, 0, COLOR.BuoyRed, "D"),
			box("Band", 1.9, 0.4, 1.9, 0, 0.5, 0, COLOR.White, "D"),
			box("Pole", 0.25, 2, 0.25, 0, 1.9, 0, COLOR.StoneDark, "D"),
			box("Lamp", 0.6, 0.6, 0.6, 0, 3.2, 0, COLOR.Bloom[1], "N"),
		},
		attrs = { AmbientBob = 0.3, AmbientPeriod = math.floor(rng.range(3, 4.6) * 10) / 10 },
	}
end

-- Small rowboat tied to its own mooring float; front is -Z, y = 0 is the water surface.
local function rowboatSpec()
	return {
		name = "Rowboat",
		occ = 5.5,
		ghost = true,
		parts = {
			box("Hull", 3, 0.4, 7, 0, -0.15, 0, COLOR.Wood, "D"),
			box("Side", 0.4, 1.2, 7, -1.5, 0.45, 0, COLOR.WoodDark, "D"),
			box("Side", 0.4, 1.2, 7, 1.5, 0.45, 0, COLOR.WoodDark, "D"),
			box("Stern", 3.4, 1.2, 0.4, 0, 0.45, 3.5, COLOR.WoodDark, "D"),
			box("Bow", 2.2, 1.2, 0.6, 0, 0.45, -3.7, COLOR.WoodDark, "D"),
			box("BowTip", 1.1, 1.2, 0.6, 0, 0.45, -4.3, COLOR.WoodDark, "D"),
			box("Bench", 2.6, 0.25, 0.9, 0, 0.55, -1.2, COLOR.WoodLight, "D"),
			box("Bench", 2.6, 0.25, 0.9, 0, 0.55, 1.4, COLOR.WoodLight, "D"),
			turned(box("Oar", 0.3, 0.3, 5, 0.4, 0.85, 0.1, COLOR.WoodLight, "D"), 0, 24, 0),
			box("MooringFloat", 1.2, 1.2, 1.2, 3.4, 0, -3.4, COLOR.BuoyRed, "D"),
			turned(box("MooringRope", 0.15, 0.15, 3.6, 1.9, 0.6, -3.7, COLOR.Paper, "D"), 0, 75, 0),
		},
		attrs = { AmbientBob = 0.25, AmbientSway = 4, AmbientPeriod = 4.5 },
	}
end

-- Tiny blocky bird, front -Z. Flying birds spread their wings and get an orbit.
local function birdSpec(scale, color, orbit, period)
	local k = scale
	local parts = {
		box("Body", 1 * k, 0.8 * k, 1.6 * k, 0, 0.4 * k, 0, color, "D"),
		box("Head", 0.7 * k, 0.7 * k, 0.7 * k, 0, 0.95 * k, -0.85 * k, color, "D"),
		box("Beak", 0.25 * k, 0.25 * k, 0.4 * k, 0, 0.9 * k, -1.4 * k, COLOR.Bloom[5], "D"),
	}
	local attrs = nil
	if orbit then
		table.insert(parts, box("Wing", 1.8 * k, 0.15 * k, 0.9 * k, -1.35 * k, 0.6 * k, 0, color, "D"))
		table.insert(parts, box("Wing", 1.8 * k, 0.15 * k, 0.9 * k, 1.35 * k, 0.6 * k, 0, color, "D"))
		attrs = { AmbientOrbit = orbit, AmbientPeriod = period }
	else
		table.insert(parts, box("Tail", 0.6 * k, 0.2 * k, 0.7 * k, 0, 0.5 * k, 1.1 * k, color, "D"))
	end
	return { name = if orbit then "FlyingBird" else "PerchedBird", parts = parts, attrs = attrs, ghost = true }
end

-- Market hut, 14 x 12 footprint, door on the -Z side.
local function hutSpec(style)
	local parts = {
		box("Foundation", 14, 0.8, 12, 0, 0.2, 0, COLOR.StoneDark, "S"),
		box("Walls", 12.8, 7, 10.8, 0, 4.1, 0, style.wall, "S"),
		box("Door", 2.6, 4.6, 0.3, 0, 2.9, -5.45, COLOR.WoodDark, "D"),
		lit(box("Window", 2.8, 2.2, 0.3, -3.9, 4.6, -5.45, COLOR.Glass, "D"), COLOR.LampLight, 14, 0.9),
		box("SideWindow", 0.3, 2.2, 2.8, 6.45, 4.6, 0.5, COLOR.Glass, "D"),
		turned(box("Awning", 9, 0.4, 3.6, 0, 6.2, -7.1, style.awning, "D"), -14, 0, 0),
		box("AwningPost", 0.4, 5.5, 0.4, -4.1, 2.75, -8.5, COLOR.WoodDark, "D"),
		box("AwningPost", 0.4, 5.5, 0.4, 4.1, 2.75, -8.5, COLOR.WoodDark, "D"),
		box("RoofEave", 15, 1, 13, 0, 8.1, 0, style.roof, "S"),
	}
	local perch
	if style.flat then
		table.insert(parts, box("RoofDeck", 11, 1.2, 9, 0, 9.2, 0, style.trim, "S"))
		table.insert(parts, box("ShopSign", 6, 2.4, 0.5, 0, 11, -3.6, COLOR.Gold, "D"))
		table.insert(parts, box("Vent", 1.4, 2, 1.4, 3.4, 10.8, 2, COLOR.StoneDark, "D"))
		perch = Vector3.new(1.6, 12.2, -3.6)
	else
		table.insert(parts, box("RoofMid", 15, 1.5, 9, 0, 9.35, 0, style.roof, "S"))
		table.insert(parts, box("RoofRidge", 15, 1.5, 4.6, 0, 10.85, 0, style.trim, "S"))
		table.insert(parts, box("Chimney", 1.6, 3.4, 1.6, 4.4, 11.3, 2.2, COLOR.Stone, "D"))
		perch = Vector3.new(-3.5, 11.6, 0)
	end
	return { name = "MarketHut", parts = parts, occ = 9.8, perch = perch }
end

-- Vendor NPCs: static blocky figures, front -Z, about 6 to 7 studs tall.
local function shrineKeeperSpec()
	local robe, robeLight, trim = rgb(64, 56, 128), rgb(80, 72, 152), rgb(120, 230, 255)
	return {
		name = "ShrineKeeper",
		occ = 2.4,
		primary = 2,
		parts = {
			box("Robe", 2.4, 2.6, 1.8, 0, 1.3, 0, robe, "S"),
			box("Torso", 2.1, 1.8, 1.2, 0, 3.5, 0, robeLight, "S"),
			box("Sash", 2.5, 0.35, 1.9, 0, 2.65, 0, trim, "N"),
			box("LeftSleeve", 0.9, 1.9, 1.1, -1.5, 3.45, 0, robe, "D"),
			box("RightSleeve", 0.9, 1.9, 1.1, 1.5, 3.45, 0, robe, "D"),
			box("Head", 1.3, 1.3, 1.3, 0, 5.05, 0, COLOR.Skin, "D"),
			box("HatBrim", 2.4, 0.3, 2.4, 0, 5.85, 0, robe, "D"),
			box("HatTop", 1.3, 0.6, 1.3, 0, 6.3, 0, robeLight, "D"),
			box("Staff", 0.3, 6.4, 0.3, 2.2, 3.2, -0.4, COLOR.WoodDark, "D"),
			box("StaffOrb", 0.9, 0.9, 0.9, 2.2, 6.85, -0.4, trim, "N"),
		},
	}
end

local function baitMerchantSpec()
	local trousers, shirt, straw = rgb(96, 72, 52), rgb(88, 150, 96), rgb(226, 196, 110)
	return {
		name = "BaitMerchantNpc",
		occ = 2.2,
		primary = 3,
		parts = {
			box("LeftLeg", 0.95, 2, 1, -0.52, 1, 0, trousers, "S"),
			box("RightLeg", 0.95, 2, 1, 0.52, 1, 0, trousers, "S"),
			box("Torso", 2, 2, 1, 0, 3, 0, shirt, "S"),
			box("Apron", 1.7, 2.6, 0.2, 0, 2.6, -0.6, COLOR.Plaster, "D"),
			box("LeftArm", 0.9, 2, 0.9, -1.45, 3, 0, shirt, "D"),
			box("RightArm", 0.9, 2, 0.9, 1.45, 3, 0, shirt, "D"),
			box("Head", 1.25, 1.25, 1.25, 0, 4.625, 0, COLOR.Skin, "D"),
			box("HatBrim", 2.3, 0.25, 2.3, 0, 5.37, 0, straw, "D"),
			box("HatCrown", 1.4, 0.6, 1.4, 0, 5.8, 0, straw, "D"),
			box("BaitBucket", 1, 1, 1, 1.45, 1.5, -0.1, rgb(150, 160, 170), "D"),
		},
	}
end

local function appraiserSpec()
	local trousers, vest, shirt, black = rgb(52, 52, 64), rgb(110, 72, 150), rgb(236, 236, 240), rgb(36, 36, 44)
	return {
		name = "AppraiserNpc",
		occ = 2.2,
		primary = 3,
		parts = {
			box("LeftLeg", 0.95, 2, 1, -0.52, 1, 0, trousers, "S"),
			box("RightLeg", 0.95, 2, 1, 0.52, 1, 0, trousers, "S"),
			box("Torso", 2, 2, 1, 0, 3, 0, vest, "S"),
			box("LeftArm", 0.9, 2, 0.9, -1.45, 3, 0, shirt, "D"),
			box("RightArm", 0.9, 2, 0.9, 1.45, 3, 0, shirt, "D"),
			box("Head", 1.25, 1.25, 1.25, 0, 4.625, 0, COLOR.Skin, "D"),
			box("Monocle", 0.5, 0.5, 0.15, 0.3, 4.75, -0.68, COLOR.Gold, "D"),
			box("HatBrim", 1.9, 0.2, 1.9, 0, 5.35, 0, black, "D"),
			box("HatCrown", 1.2, 1.1, 1.2, 0, 6, 0, black, "D"),
			box("HandScale", 0.5, 0.25, 1.9, 1.45, 1.85, -0.3, COLOR.Gold, "D"),
		},
	}
end

-- Checking a prop against the rules --------------------------------------------------------

local function worldBounds(spec, base)
	local list = table.create(#spec.parts)
	for index, entry in spec.parts do
		list[index] = boundsOf(base * entry.cf, entry.size)
	end
	return list
end

-- True when the footprint of `bounds` reaches into a greybox prop (stall, gate, pedestal).
local function hitsObstacle(bounds)
	for _, other in obstacles do
		local o = other.bounds
		if
			bounds.minY < o.maxY
			and bounds.maxY > o.minY
			and bounds.minX < o.maxX + 0.3
			and bounds.maxX > o.minX - 0.3
			and bounds.minZ < o.maxZ + 0.3
			and bounds.maxZ > o.minZ - 0.3
		then
			for step = 0, 24 do
				local x = bounds.minX + (bounds.maxX - bounds.minX) * (step % 5) / 4
				local z = bounds.minZ + (bounds.maxZ - bounds.minZ) * math.floor(step / 5) / 4
				local offset = other.cf:PointToObjectSpace(Vector3.new(x, other.cf.Position.Y, z))
				if math.abs(offset.X) <= other.size.X / 2 + 0.3 and math.abs(offset.Z) <= other.size.Z / 2 + 0.3 then
					return true
				end
			end
		end
	end
	return false
end

local function nearLane(bounds, lane)
	local dx, dz = lane[3] - lane[1], lane[4] - lane[2]
	local steps = math.ceil(math.sqrt(dx * dx + dz * dz))
	for step = 0, steps do
		local t = step / steps
		if rectDistance(bounds, lane[1] + dx * t, lane[2] + dz * t) < CORRIDOR_HALF + 0.3 then
			return true
		end
	end
	return false
end

-- Why the prop may not stand here, or nil when it may.
--   mode "ground": rules a, c, d, e    "water": rule b on river / lagoon
--   mode "abyss": rule b in the Abyss  anything else: only the universal rules
--   opts.hub = a small market prop allowed on the plaza; opts.margin = wider path gap
local function violation(boundsList, mode, opts)
	local margin = (opts.margin or FOOT_MARGIN) + SLACK
	for _, b in boundsList do
		if b.minZ < FALLS.z + 0.5 and b.maxX > -FALLS.halfX - 0.5 and b.minX < FALLS.halfX + 0.5 then
			return "falls corridor"
		end
		if b.maxY > POND_VIEW_HEIGHT - 0.05 then
			for _, pond in ponds do
				if rectDistance(b, pond.x, pond.z) < POND_VIEW_RADIUS + 0.3 then
					return "pond sightline"
				end
			end
		end
		local radius = math.sqrt(b.x * b.x + b.z * b.z)
		if b.minY <= FLOOR_SCOPE_Y + 0.5 and radius < FLOOR_SCOPE_RADIUS + 2 then
			if mode == "abyss" then
				local dx = math.max(math.abs(b.minX - abyss.x), math.abs(b.maxX - abyss.x))
				local dz = math.max(math.abs(b.minZ - abyss.z), math.abs(b.maxZ - abyss.z))
				if math.sqrt(dx * dx + dz * dz) > math.min(ABYSS_PROP_RADIUS, abyss.holeRadius - 3) - 0.3 then
					return "outside the abyss water"
				end
			else
				for _, circle in clearCircles do
					if rectDistance(b, circle[1], circle[2]) < CLEAR_RADIUS + 0.3 then
						return "keep-clear circle"
					end
				end
				for _, lane in clearLanes do
					if nearLane(b, lane) then
						return "pond spawn lane"
					end
				end
				if rectDistance(b, 0, 0) < HUB_RADIUS + 0.3 then
					if not opts.hub or b.maxZ > MARKET_Z - SLACK then
						return "hub plaza"
					end
					if b.maxX - b.minX > 5 or b.maxZ - b.minZ > 5 then
						return "too big for the plaza"
					end
				end
				if hitsObstacle(b) then
					return "greybox prop"
				end
				if mode == "water" then
					local pad = SLACK
					if
						not rectOnly(b.minX - pad, b.maxX + pad, b.minZ - pad, b.maxZ + pad, WATER, bit32.bnot(WATER))
					then
						return "not on open water"
					end
				else
					local flags = flagsAt(b.x, b.z)
					local floor = if opts.hub then STANDABLE else GRASS
					if bit32.band(flags, floor) == 0 or bit32.band(flags, BLOCKED) ~= 0 then
						return "not on grass"
					end
					if
						not rectOnly(
							b.minX - margin,
							b.maxX + margin,
							b.minZ - margin,
							b.maxZ + margin,
							STANDABLE,
							BLOCKED
						)
					then
						return "too close to a path, rim or water"
					end
				end
			end
		end
	end
	return nil
end

-- Building ---------------------------------------------------------------------------------

local recording = ChangeHistoryService:TryBeginRecording("Build Reel It In environment")
if existing then
	existing:Destroy()
end

local decor = Instance.new("Folder")
decor.Name = "Decor"
decor:SetAttribute("EnvironmentVersion", VERSION)

local folders = {}
for _, name in
	{
		"CliffTops",
		"CliffFaces",
		"Forest",
		"Hub",
		"Market",
		"Npcs",
		"Riverside",
		"Lagoon",
		"Abyss",
		"Ponds",
		"Lights",
		"Wildlife",
	}
do
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = decor
	folders[name] = folder
end

local partCount, lightCount, animatedCount, propCount = 0, 0, 0, 0
local skipped = {}

local function instantiate(folderName, spec, boundsList)
	local single = #spec.parts == 1 and not spec.attrs
	local model = nil
	if not single then
		model = Instance.new("Model")
		model.Name = spec.name
	end
	local primary = nil
	for index, entry in spec.parts do
		local kind = KIND[entry.kind]
		local collide = kind.collide and not spec.ghost
		local p = Instance.new("Part")
		p.Name = if single then spec.name else entry.name
		p.Size = entry.size
		p.CFrame = boundsList[index].cf
		p.Color = entry.color
		p.Material = if kind.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Anchored = true
		p.CanCollide = collide
		p.CanQuery = collide
		p.CanTouch = false
		p.CastShadow = kind.shadow
		if entry.shape then
			p.Shape = Enum.PartType[entry.shape]
		end
		if entry.light then
			local light = Instance.new("PointLight")
			light.Color = entry.light.color
			light.Range = entry.light.range
			light.Brightness = entry.light.brightness
			light.Shadows = false
			light:SetAttribute("NightLight", true)
			light.Parent = p
			lightCount += 1
		end
		p.Parent = model or folders[folderName]
		partCount += 1
		if index == (spec.primary or 1) then
			primary = p
		end
	end
	if model then
		model.PrimaryPart = primary
		if spec.attrs then
			for name, value in spec.attrs do
				model:SetAttribute(name, value)
			end
			animatedCount += 1
		end
		model.Parent = folders[folderName]
	end
	propCount += 1
	return model or primary
end

-- Footprints already taken, so props do not stand inside each other: { x, z, radius }.
local taken = { ground = {}, water = {}, top = {} }
local TAKEN_LIST = { ground = taken.ground, water = taken.water, abyss = taken.water, top = taken.top }

local function isFree(list, x, z, radius)
	for _, other in list do
		local dx, dz = x - other[1], z - other[2]
		local gap = radius + other[3]
		if dx * dx + dz * dz < gap * gap then
			return false
		end
	end
	return true
end

local NO_OPTS = {}

-- Creates the prop at `base` if every rule allows it. Returns the instance or nil.
local function place(folderName, spec, base, mode, opts)
	opts = opts or NO_OPTS
	local boundsList = worldBounds(spec, base)
	if violation(boundsList, mode, opts) then
		return nil
	end
	local list = TAKEN_LIST[mode]
	if list and spec.occ then
		local p = base.Position
		if not isFree(list, p.X, p.Z, spec.occ) then
			return nil
		end
		table.insert(list, { p.X, p.Z, spec.occ })
	end
	return instantiate(folderName, spec, boundsList)
end

local function upright(x, z)
	return CFrame.new(x, 0, z)
end

local function facingHub(x, z)
	return CFrame.lookAt(Vector3.new(x, 0, z), Vector3.new(0, 0, 0))
end

local function yawed(degrees)
	return function(x, z)
		return CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(degrees), 0)
	end
end

-- Tries (x, z), then rings of spots around it out to `reach`; the first legal one wins.
-- `accept(x, z)` can veto a spot. Records the prop as skipped when nothing fits.
local function placeNear(folderName, spec, x, z, mode, settings)
	settings = settings or NO_OPTS
	local facing = settings.facing or upright
	local reach, step = settings.reach or 6, settings.step or 1.5
	local distance = 0
	while distance <= reach do
		local spots = if distance == 0 then 1 else 8
		for index = 0, spots - 1 do
			local dx, dz = polar(index * 45, distance)
			local px, pz = x + dx, z + dz
			if not settings.accept or settings.accept(px, pz) then
				local instance = place(folderName, spec, facing(px, pz), mode, settings)
				if instance then
					return instance, px, pz
				end
			end
		end
		distance += step
	end
	table.insert(skipped, spec.name)
	return nil
end

-- Market: huts behind the vendor row, crates and barrels, a notice board -------------------

local hutPerches = {}
do
	local rng = newRng(1107)
	local styles = {
		{
			x = 0,
			z = -59,
			wall = COLOR.Plaster,
			roof = rgb(170, 78, 62),
			trim = rgb(142, 62, 50),
			awning = rgb(196, 70, 60),
		},
		{
			x = -23,
			z = -57,
			wall = COLOR.Wood,
			roof = rgb(88, 62, 44),
			trim = rgb(70, 50, 36),
			awning = rgb(86, 156, 92),
		},
		{
			x = 23,
			z = -57,
			wall = rgb(72, 110, 190),
			roof = rgb(48, 72, 140),
			trim = rgb(60, 90, 164),
			awning = COLOR.White,
			flat = true,
		},
	}
	for _, style in styles do
		local spec = hutSpec(style)
		-- Doors face the plaza (south).
		local hut, x, z =
			placeNear("Market", spec, style.x, style.z, "ground", { facing = yawed(180), reach = 8, step = 2 })
		if hut then
			local perch = yawed(180)(x, z) * spec.perch
			table.insert(hutPerches, perch)
		end
	end

	placeNear("Market", noticeBoardSpec(), -11.5, -46, "ground", { facing = facingHub })
	placeNear("Market", barrelSpec(), 11.5, -55.5, "ground")
	placeNear("Market", barrelSpec(), 12.3, -52.4, "ground")
	placeNear("Market", crateStackSpec(rng), -11.5, -55, "ground")
	placeNear("Market", crateSpec(), -10.8, -51.2, "ground", { facing = yawed(18) })
	placeNear("Market", barrelSpec(), -34, -56, "ground")
	placeNear("Market", crateStackSpec(rng), 34, -56, "ground")

	-- On the plaza sand, tucked in beside the stalls.
	placeNear("Hub", barrelSpec(), 11.5, -36.5, "ground", { hub = true, reach = 3, step = 0.75 })
	placeNear("Hub", crateStackSpec(rng), -11.5, -36.5, "ground", { hub = true, reach = 3, step = 0.75 })
	placeNear("Hub", crateSpec(), 17.5, -35.5, "ground", { hub = true, reach = 3, step = 0.75 })
end

-- Vendor NPCs: one figure beside each stall, facing the plaza centre -----------------------

do
	local cast = {
		{ vendor = "RodGachaShrine", spec = shrineKeeperSpec(), x = -11, z = -1 },
		{ vendor = "BaitMerchant", spec = baitMerchantSpec(), x = 0, z = 4.6 }, -- behind the counter
		{ vendor = "FishAppraiser", spec = appraiserSpec(), x = 11, z = -1 },
	}
	for _, member in cast do
		local vendor = vendors[member.vendor]
		if vendor then
			local at = vendor.origin * Vector3.new(member.x, 0, member.z)
			placeNear(
				"Npcs",
				member.spec,
				at.X,
				at.Z,
				"ground",
				{ facing = facingHub, hub = true, reach = 5, step = 0.5 }
			)
		else
			table.insert(skipped, member.spec.name)
		end
	end
end

-- Lamp posts: round the plaza edge and on the grass beside the boardwalks -----------------

do
	local lamps = {}
	local function spaced(x, z)
		-- Beside a boardwalk, and not crowding another lamp.
		if not rectTouches(x - 6, x + 6, z - 6, z + 6, bit32.bor(WALK, SAND)) then
			return false
		end
		return isFree(lamps, x, z, 16)
	end
	local function lamp(x, z)
		local _, px, pz = placeNear("Lights", lampSpec(), x, z, "ground", { accept = spaced, reach = 15, step = 1.5 })
		if px then
			table.insert(lamps, { px, pz, 0 })
		end
	end
	-- Walks along a boardwalk spoke: tries each distance from the hub, then each offset
	-- from the centre line, preferred side first. True once a lamp stands.
	local function lampAlong(out, side, distances, prefer)
		for _, distance in distances do
			for _, offset in { 10.5, 12, 13.5, 15 } do
				for _, flip in { prefer, -prefer } do
					local x = out.X * distance + side.X * offset * flip
					local z = out.Z * distance + side.Z * offset * flip
					if spaced(x, z) and place("Lights", lampSpec(), upright(x, z), "ground") then
						table.insert(lamps, { x, z, 0 })
						return true
					end
				end
			end
		end
		return false
	end

	-- Plaza edge, in the gaps between the boardwalk spokes.
	for _, degrees in { 22.5, 157.5, 202.5, 337.5, 252, 288 } do
		lamp(polar(degrees, HUB_RADIUS + 5))
	end
	-- Either side of the walk south to the Abyss.
	lamp(10.5, 46.5)
	lamp(-10.5, 46.5)

	-- The circulation loop is found by walking out from the plaza, between two spokes,
	-- until the first band of boardwalk has been crossed.
	local loopInner, loopOuter = nil, nil
	do
		local dx, dz = polar(22.5, 1)
		local distance = HUB_RADIUS + 10
		while distance < FLOOR_SCOPE_RADIUS and bit32.band(flagsAt(dx * distance, dz * distance), WALK) == 0 do
			distance += 1
		end
		local first = distance
		while distance < FLOOR_SCOPE_RADIUS and bit32.band(flagsAt(dx * distance, dz * distance), WALK) ~= 0 do
			distance += 1
		end
		if distance < FLOOR_SCOPE_RADIUS then
			loopInner, loopOuter = first, distance
		end
	end
	if loopInner then
		-- Each pond spoke gets a lamp about halfway to the loop (none where the spoke is
		-- a bridge the whole way) and one at the corner where it leaves the loop for the
		-- pond gate. Sides alternate from plot to plot.
		local middle = (HUB_RADIUS + loopInner) / 2
		local halfway = {}
		for step = 0, 5 do
			for _, direction in { 1, -1 } do
				local distance = middle + step * 4 * direction
				if distance > HUB_RADIUS + 16 and distance < loopInner - 8 and (step > 0 or direction == 1) then
					table.insert(halfway, distance)
				end
			end
		end
		local corner = { loopOuter + 3, loopOuter + 4, loopOuter + 2, loopOuter + 5, loopOuter + 1.5 }
		for index, pond in ponds do
			local prefer = if index % 2 == 0 then 1 else -1
			lampAlong(-pond.toHub, pond.side, halfway, prefer)
			if not lampAlong(-pond.toHub, pond.side, corner, -prefer) then
				table.insert(skipped, "LampPost")
			end
		end
		-- Outer edge of the loop, midway between the spokes.
		for _, degrees in { 22.5, 157.5, 202.5, 247.5, 270, 292.5, 337.5 } do
			lamp(polar(degrees, loopOuter + 3))
		end
	end
end

-- Ponds: two small props on the grass by each pond, different for every plot --------------

do
	local rng = newRng(606)
	local kits = {
		{ "lantern", "pot" },
		{ "barrel", "bush" },
		{ "lantern", "bush" },
		{ "pot", "barrel" },
		{ "lantern", "pot" },
		{ "bush", "barrel" },
	}
	local function make(kind)
		if kind == "lantern" then
			return pondLanternSpec()
		elseif kind == "pot" then
			return flowerPotSpec(rng)
		elseif kind == "barrel" then
			return barrelSpec()
		end
		return bushSpec(rng, 0.7, false)
	end
	for index, pond in ponds do
		local kit = kits[(index - 1) % #kits + 1]
		local flip = if index % 2 == 0 then 1 else -1
		-- One at a front corner beside the gate, one at the far back corner.
		local spots = { { 33, 25 * flip }, { -31, -31 * flip } }
		for slot, kind in kit do
			local along, across = spots[slot][1], spots[slot][2]
			local x = pond.x + pond.toHub.X * along + pond.side.X * across
			local z = pond.z + pond.toHub.Z * along + pond.side.Z * across
			placeNear("Ponds", make(kind), x, z, "ground", { reach = 9, step = 1.5 })
		end
	end
end

-- The Abyss: crystals, dark rock and lanterns round the ring; floats far below -------------

do
	local rng = newRng(8086)
	-- Ring props: one slot every 20 degrees, pushed out until it finds grass.
	local pattern =
		{ "crystal", "rock", "lantern", "rock", "crystal", "rock", "crystal", "lantern", "rock", "crystal", "rock" }
	local made = { crystal = 0, rock = 0, lantern = 0 }
	local limit = { crystal = 6, rock = 8, lantern = 3 }
	for slot = 0, 17 do
		local kind = pattern[slot % #pattern + 1]
		local degrees = slot * 20 + rng.range(-4, 4)
		local spec
		if kind == "crystal" then
			spec = crystalSpec(rng, made.crystal % 2 == 0)
		elseif kind == "rock" then
			spec = abyssRockSpec(rng)
		else
			spec = abyssLanternSpec()
		end
		if made[kind] < limit[kind] then
			for push = 3.5, 15.5, 1.5 do
				local dx, dz = polar(degrees, abyss.ringRadius + push)
				local base = CFrame.new(abyss.x + dx, 0, abyss.z + dz)
					* CFrame.Angles(0, math.rad(rng.int(0, 3) * 90), 0)
				if place("Abyss", spec, base, "ground") then
					made[kind] += 1
					break
				end
			end
		end
	end

	-- On the water at the bottom of the hole.
	local function afloat(spec, degrees, radius, yaw)
		local dx, dz = polar(degrees, radius)
		local base = CFrame.new(abyss.x + dx, abyss.surfaceY, abyss.z + dz) * CFrame.Angles(0, math.rad(yaw), 0)
		if not place("Abyss", spec, base, "abyss") then
			table.insert(skipped, spec.name)
		end
	end
	afloat(rowboatSpec(), 25, 28, 200)
	afloat(buoySpec(rng), 255, 30, 0)
	afloat(buoySpec(rng), 140, 33, 0)
	afloat(buoySpec(rng), 75, 37, 0)
	afloat(buoySpec(rng), 200, 13, 0)
end

-- River and lagoon: reeds and rocks on the banks, lily pads and stones on the water --------

do
	local rng = newRng(5150)

	-- Label connected bodies of water. The one that reaches furthest north (The Falls)
	-- is the river; anything else is still water (the lagoon).
	local body = {}
	local bodies = {}
	for start = 1, GRID_COUNT * GRID_COUNT do
		if bit32.band(cells[start], WATER) ~= 0 and not body[start] then
			local id = #bodies + 1
			local info = { minZ = math.huge }
			bodies[id] = info
			local queue, head = { start }, 1
			body[start] = id
			while head <= #queue do
				local index = queue[head]
				head += 1
				local i, j = (index - 1) % GRID_COUNT + 1, math.floor((index - 1) / GRID_COUNT) + 1
				local _, z = cellCenter(i, j)
				info.minZ = math.min(info.minZ, z)
				for _, step in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					local ni, nj = i + step[1], j + step[2]
					if ni >= 1 and ni <= GRID_COUNT and nj >= 1 and nj <= GRID_COUNT then
						local neighbour = (nj - 1) * GRID_COUNT + ni
						if bit32.band(cells[neighbour], WATER) ~= 0 and not body[neighbour] then
							body[neighbour] = id
							table.insert(queue, neighbour)
						end
					end
				end
			end
		end
	end
	local river = 1
	for id, info in bodies do
		if info.minZ < bodies[river].minZ then
			river = id
		end
	end

	-- Candidate cells: grass close to the water, water at the edge, and calm open water.
	local banks = { river = {}, lagoon = {} }
	local shallows = { river = {}, lagoon = {} }
	local calm = { river = {}, lagoon = {} }
	for j = 1, GRID_COUNT do
		for i = 1, GRID_COUNT do
			local flags = cells[(j - 1) * GRID_COUNT + i]
			if flags == GRASS then
				local found = nil
				for dj = -2, 2 do
					for di = -2, 2 do
						if cellFlags(i + di, j + dj) == WATER then
							found = body[(j + dj - 1) * GRID_COUNT + i + di]
						end
					end
				end
				if found then
					table.insert(banks[if found == river then "river" else "lagoon"], { cellCenter(i, j) })
				end
			elseif flags == WATER then
				local which = if body[(j - 1) * GRID_COUNT + i] == river then "river" else "lagoon"
				local open, edge = true, false
				for dj = -2, 2 do
					for di = -2, 2 do
						local near = cellFlags(i + di, j + dj)
						if near ~= WATER then
							open = false
							if near == GRASS and math.abs(di) + math.abs(dj) == 1 then
								edge = true
							end
						end
					end
				end
				if open then
					table.insert(calm[which], { cellCenter(i, j) })
				elseif edge then
					table.insert(shallows[which], { cellCenter(i, j) })
				end
			end
		end
	end

	-- Places up to `count` props from a shuffled candidate list, keeping them `apart`.
	local function strew(folderName, candidates, count, apart, mode, make, jitter)
		shuffle(candidates, rng)
		local chosen = {}
		for _, cell in candidates do
			if #chosen >= count then
				break
			end
			local x, z = cell[1] + rng.range(-jitter, jitter), cell[2] + rng.range(-jitter, jitter)
			if isFree(chosen, x, z, apart) then
				local y = if mode == "water" then waterSurfaceY else 0
				local base = CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(rng.int(0, 3) * 90), 0)
				if place(folderName, make(), base, mode) then
					table.insert(chosen, { x, z, 0 })
				end
			end
		end
	end

	local function bankRock()
		local parts, reach = boulderParts(rng, rng.range(0.45, 0.7), rng.int(1, 2), false)
		return { name = "BankRock", parts = parts, occ = reach }
	end
	local function lily()
		return lilySpec(rng)
	end

	strew("Riverside", banks.river, COUNTS.riverReeds, 22, "ground", reedSpec, 0.4)
	strew("Riverside", banks.river, COUNTS.riverRocks, 30, "ground", bankRock, 0.4)
	strew("Riverside", shallows.river, COUNTS.riverWaterReeds, 40, "water", waterReedSpec, 0)
	strew("Riverside", calm.river, COUNTS.riverLilies, 9, "water", lily, 0.5)
	strew("Lagoon", banks.lagoon, COUNTS.lagoonReeds, 18, "ground", reedSpec, 0.4)
	strew("Lagoon", banks.lagoon, COUNTS.lagoonRocks, 30, "ground", bankRock, 0.4)
	strew("Lagoon", shallows.lagoon, COUNTS.lagoonWaterReeds, 24, "water", waterReedSpec, 0)
	strew("Lagoon", calm.lagoon, COUNTS.lagoonLilies, 7, "water", lily, 0.5)

	-- Stepping rocks across the river in the north meadow: scan one row of the grid
	-- for the river and space rocks along the water found there.
	local rowZ = -151
	local firstX, lastX = nil, nil
	for x = -GRID_EXTENT + 1, GRID_EXTENT - 1, STEP do
		local i, j = cellOf(x, rowZ)
		if cellFlags(i, j) == WATER and body[(j - 1) * GRID_COUNT + i] == river then
			firstX = firstX or x
			lastX = x
		end
	end
	if firstX then
		local rocks = 0
		local x = firstX + 1
		while x <= lastX and rocks < COUNTS.steppingRocks do
			local base = CFrame.new(x, waterSurfaceY, rowZ + rng.range(-0.6, 0.6))
				* CFrame.Angles(0, math.rad(rng.int(0, 1) * 90), 0)
			if place("Riverside", steppingRockSpec(rng), base, "water") then
				rocks += 1
				x += 4.2
			else
				x += 1
			end
		end
	end
end

-- Basin floor forest: clusters of pines with undergrowth, dense at the cliff foot ---------

local perchBoulder = nil
do
	local rng = newRng(90210)
	local FLOOR_EDGE = rim.inner - 10 -- foot of the cliff ledges
	local TREE = { minRadius = 62, pondGap = 44, abyssGap = abyss.ringRadius + 14, waterGap = 8 }
	local TREE_OPTS = { margin = 3 } -- trees stand further off the boardwalks than small props

	-- Clusters are thin near the hub and thick in the outer band, so paths stay readable.
	local function density(radius)
		if radius < 98 then
			return 0.12
		elseif radius < 190 then
			return 0.12 + (radius - 98) / 92 * 0.5
		end
		return 1
	end

	local function treeAllowed(x, z, reach)
		local radius = math.sqrt(x * x + z * z)
		if radius < TREE.minRadius or radius + reach > FLOOR_EDGE then
			return false
		end
		for _, pond in ponds do
			if math.sqrt((x - pond.x) ^ 2 + (z - pond.z) ^ 2) < TREE.pondGap then
				return false
			end
		end
		if math.sqrt((x - abyss.x) ^ 2 + (z - abyss.z) ^ 2) < TREE.abyssGap then
			return false
		end
		-- Keep the banks open for casting.
		local gap = TREE.waterGap
		return not rectTouches(x - gap, x + gap, z - gap, z + gap, WATER)
	end

	local function onFloor(x, z, reach)
		return math.sqrt(x * x + z * z) + reach <= FLOOR_EDGE
	end

	local function randomSpot(minRadius)
		local radius = math.sqrt(rng.range((minRadius / FLOOR_EDGE) ^ 2, 1)) * FLOOR_EDGE
		local x, z = polar(rng.range(0, 360), radius)
		return x, z, radius
	end

	local function bush(x, z)
		local spec = bushSpec(rng, rng.range(0.8, 1.15), false)
		return onFloor(x, z, spec.occ) and place("Forest", spec, upright(x, z), "ground") ~= nil
	end

	local function boulder(x, z)
		local spec = boulderSpec(rng, rng.range(0.7, 1.15), rng.int(1, 2), false)
		if not onFloor(x, z, spec.occ) then
			return false
		end
		local rock = place("Forest", spec, upright(x, z), "ground")
		if rock and not perchBoulder then
			local radius = math.sqrt(x * x + z * z)
			if radius > 110 and radius < 200 then
				perchBoulder = Vector3.new(x, spec.perchY, z)
			end
		end
		return rock ~= nil
	end

	local pines, bushes, boulders, flowers = 0, 0, 0, 0
	local attempts = 0
	while pines < COUNTS.forestPines and attempts < 6000 do
		attempts += 1
		local cx, cz, radius = randomSpot(TREE.minRadius)
		if rng.next() <= density(radius) then
			local outer = radius > 185
			local size = if outer then rng.int(2, 4) else rng.int(1, 2)
			for index = 1, size do
				local dx, dz = polar(rng.range(0, 360), if index == 1 then 0 else rng.range(6, 12))
				local roll = rng.next()
				local variant
				if outer then
					variant = if roll < 0.35 then 3 elseif roll < 0.75 then 2 else 1
				else
					variant = if roll < 0.15 then 3 elseif roll < 0.55 then 2 else 1
				end
				local spec = pineSpec(rng, variant, rng.range(0.9, 1.2), false)
				local x, z = cx + dx, cz + dz
				if
					pines < COUNTS.forestPines
					and treeAllowed(x, z, spec.reach)
					and place("Forest", spec, upright(x, z), "ground", TREE_OPTS)
				then
					pines += 1
				end
			end
			local ux, uz = polar(rng.range(0, 360), rng.range(5, 10))
			if rng.chance(0.6) and bushes < COUNTS.forestBushes and bush(cx + ux, cz + uz) then
				bushes += 1
			end
			local rx, rz = polar(rng.range(0, 360), rng.range(5, 11))
			if rng.chance(0.35) and boulders < COUNTS.forestBoulders and boulder(cx + rx, cz + rz) then
				boulders += 1
			end
		end
	end

	-- Loose undergrowth between the clusters; low, so it can come closer to the hub.
	attempts = 0
	while (bushes < COUNTS.forestBushes or boulders < COUNTS.forestBoulders) and attempts < 4000 do
		attempts += 1
		local x, z, radius = randomSpot(HUB_RADIUS + 8)
		if rng.next() <= 0.35 + density(radius) * 0.65 then
			if bushes < COUNTS.forestBushes and attempts % 2 == 0 then
				if bush(x, z) then
					bushes += 1
				end
			elseif boulders < COUNTS.forestBoulders then
				if boulder(x, z) then
					boulders += 1
				end
			end
		end
	end
	attempts = 0
	while flowers < COUNTS.forestFlowers and attempts < 2000 do
		attempts += 1
		local x, z = randomSpot(HUB_RADIUS + 7)
		if onFloor(x, z, 2) and place("Forest", flowerSpec(rng), upright(x, z), "ground") then
			flowers += 1
		end
	end
end

-- Cliff tops: the pine forest round the rim -------------------------------------------------

do
	local rng = newRng(31337)
	local inner, depth = rim.inner, rim.outer - rim.inner

	-- Plants a prop on the cliff top under (x, z). `lean` tilts it out over the basin.
	-- The segments step up and down, so everything that touches the ground must stand
	-- on one level: no rock half-buried in the next segment, no bush hanging off a step.
	local function plant(spec, x, z, lean)
		local top = cliffTopAt(x, z)
		if not top then
			return false
		end
		local base
		if lean then
			local foot = Vector3.new(x, top + 0.3, z)
			base = CFrame.lookAt(foot, Vector3.new(0, top + 0.3, 0)) * CFrame.Angles(-math.rad(lean), 0, 0)
			for _, corner in { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } } do
				if cliffTopAt(x + corner[1] * spec.foot, z + corner[2] * spec.foot) ~= top then
					return false
				end
			end
		else
			base = CFrame.new(x, top, z)
			for _, b in worldBounds(spec, base) do
				if b.minY <= top + 0.5 then
					for _, corner in { { b.minX, b.minZ }, { b.minX, b.maxZ }, { b.maxX, b.minZ }, { b.maxX, b.maxZ } } do
						if cliffTopAt(corner[1], corner[2]) ~= top then
							return false
						end
					end
				end
			end
		end
		return place("CliffTops", spec, base, "top") ~= nil
	end

	local pines = 0
	-- A front row first: one tree near the lip of every segment, a few leaning out.
	for index, top in cliffTops do
		local degrees = math.deg(top.angle) + rng.range(-3.2, 3.2)
		local leaning = index % 7 == 3
		local roll = rng.next()
		local variant = if roll < 0.45 then 3 elseif roll < 0.85 then 2 else 1
		local spec = pineSpec(rng, if leaning then 3 else variant, rng.range(1.5, 1.9), true)
		local radius = inner + (if leaning then rng.range(3.4, 4.4) else rng.range(4, 9))
		if leaning then
			spec.name = "PineLeaning"
		end
		local x, z = polar(degrees, radius)
		if plant(spec, x, z, if leaning then rng.range(14, 20) else nil) then
			pines += 1
		end
	end
	-- Then fill the rest of the rim, weighted toward the lip where it is seen from below.
	local attempts = 0
	while pines < COUNTS.cliffPines and attempts < 5000 do
		attempts += 1
		local roll = rng.next()
		local variant = if roll < 0.3 then 3 elseif roll < 0.88 then 2 else 1
		local spec = pineSpec(rng, variant, rng.range(1.45, 1.85), true)
		local x, z = polar(rng.range(0, 360), inner + 4 + (depth - 14) * rng.next() ^ 1.3)
		if plant(spec, x, z, nil) then
			pines += 1
		end
	end

	local bushes, boulders = 0, 0
	attempts = 0
	while bushes < COUNTS.cliffBushes and attempts < 2000 do
		attempts += 1
		local x, z = polar(rng.range(0, 360), inner + 2.5 + 26 * rng.next() ^ 2)
		if plant(bushSpec(rng, rng.range(1.3, 1.8), true), x, z, nil) then
			bushes += 1
		end
	end
	attempts = 0
	while boulders < COUNTS.cliffBoulders and attempts < 2000 do
		attempts += 1
		local x, z = polar(rng.range(0, 360), inner + 4 + 20 * rng.next() ^ 2)
		if plant(boulderSpec(rng, rng.range(1.3, 2), rng.int(2, 3), true), x, z, nil) then
			boulders += 1
		end
	end
end

-- Cliff faces: rock slabs, outcrops, ledge plants and moss ---------------------------------

do
	local rng = newRng(4242)
	local LIMIT = 12 -- along-wall offset that stays clear of the neighbouring segments

	-- A frame on the inner face of `host`: X along the wall, Y up, +Z out into the basin.
	local function faceFrame(host, along, worldY)
		return host.cf * CFrame.new(along, worldY - host.cf.Position.Y, host.size.Z / 2)
	end

	local function mossCap(parts, w, h, d, sink)
		table.insert(
			parts,
			box("MossCap", w - 1, 0.5, d - 2.2, 0, h / 2 + 0.2, d / 2 - sink + 0.9, COLOR.Moss[rng.int(1, 2)], "D")
		)
	end

	for _, wall in cliffWalls do
		local ledge = wall.ledge
		if ledge then
			-- A slab jutting out of the main wall, above the foot ledge.
			local low, high = ledge.top + 8, wall.top - 12
			if rng.chance(0.55) and high > low then
				local w, h, d = rng.range(8, 15), rng.range(2.2, 4), rng.range(5, 8)
				local parts = { box("Slab", w, h, d, 0, 0, d / 2 - 1.5, COLOR.Rock[rng.int(1, 3)], "F") }
				if rng.chance(0.35) then
					table.insert(
						parts,
						box(
							"Step",
							w * 0.55,
							h * 0.8,
							d * 0.6,
							rng.sign() * w * 0.2,
							-h * 0.9,
							d * 0.3 - 1.5,
							COLOR.Rock[rng.int(1, 3)],
							"D"
						)
					)
				end
				if rng.chance(0.4) then
					mossCap(parts, w, h, d, 1.5)
				end
				local topper = rng.next()
				if topper < 0.2 then
					append(
						parts,
						bushParts(rng, 0.7, true),
						CFrame.new(rng.range(-w * 0.25, w * 0.25), h / 2, d / 2 - 0.6)
					)
				elseif topper < 0.32 then
					append(parts, pineParts(rng, 1, rng.range(0.8, 1), true), CFrame.new(0, h / 2, d / 2 - 0.8))
				end
				local base = faceFrame(wall, rng.range(-LIMIT, LIMIT), rng.range(low, high))
				place("CliffFaces", { name = "RockSlab", parts = parts, ghost = true }, base, "face")
			end

			-- A smaller outcrop on the face of the foot ledge, above head height.
			local outcropHigh = ledge.top - 4
			if rng.chance(0.28) and outcropHigh > 8.5 then
				local w, h, d = rng.range(5, 9), rng.range(2, 3), rng.range(3.5, 5)
				local parts = { box("Outcrop", w, h, d, 0, 0, d / 2 - 1.2, COLOR.Rock[rng.int(1, 3)], "F") }
				if rng.chance(0.4) then
					mossCap(parts, w, h, d, 1.2)
				end
				local base = faceFrame(ledge, rng.range(-LIMIT, LIMIT), rng.range(8.5, outcropHigh))
				place("CliffFaces", { name = "RockOutcrop", parts = parts, ghost = true }, base, "face")
			end

			-- Something growing on top of the foot ledge.
			if rng.chance(0.36) then
				local roll = rng.next()
				local parts, name
				if roll < 0.4 then
					parts, name = bushParts(rng, rng.range(1.1, 1.5), true), "LedgeBush"
				elseif roll < 0.7 then
					parts, name = pineParts(rng, 1, rng.range(1, 1.3), true), "LedgePine"
				else
					parts, name =
						{
							box("Tuft", 6, 0.7, 3.6, 0, 0.25, 3.3, COLOR.Moss[rng.int(1, 2)], "D"),
							box("TuftDrape", 5, 2.4, 0.6, 0, -1, 5.2, COLOR.Moss[rng.int(1, 2)], "D"),
						}, "LedgeTuft"
				end
				local base = ledge.cf * CFrame.new(rng.range(-LIMIT, LIMIT), ledge.size.Y / 2, rng.range(-1, 1))
				place("CliffFaces", { name = name, parts = parts, ghost = true }, base, "face")
			end

			-- Moss hanging on the main wall.
			local mossLow, mossHigh = ledge.top + 6, wall.top - 7
			if rng.chance(0.4) and mossHigh > mossLow then
				local spec = {
					name = "MossPatch",
					ghost = true,
					parts = {
						box(
							"MossPatch",
							rng.range(4, 8),
							rng.range(5, 11),
							1,
							0,
							0,
							0.2,
							COLOR.Moss[rng.int(1, 2)],
							"D"
						),
					},
				}
				place(
					"CliffFaces",
					spec,
					faceFrame(wall, rng.range(-LIMIT, LIMIT), rng.range(mossLow, mossHigh)),
					"face"
				)
			end
		end
	end
end

-- Wildlife: birds on rooftops and boulders, and circling high over the basin ---------------

do
	local rng = newRng(777)
	local feathers = { rgb(70, 130, 220), rgb(200, 90, 60), rgb(240, 240, 240), rgb(50, 50, 60) }
	-- Perches: the first and last hut roofs and a boulder out in the forest.
	local perches = {}
	for index, perch in hutPerches do
		if index == 1 or (index == #hutPerches and index > 1) then
			table.insert(perches, perch)
		end
	end
	if perchBoulder then
		table.insert(perches, perchBoulder)
	end
	for index, perch in perches do
		local spec = birdSpec(1.2, feathers[(index - 1) % #feathers + 1], nil, nil)
		local base = CFrame.new(perch) * CFrame.Angles(0, math.rad(rng.range(0, 360)), 0)
		if not place("Wildlife", spec, base, "air") then
			table.insert(skipped, spec.name)
		end
	end
	-- { x, height, z, orbit radius, seconds per lap }
	local flights = {
		{ -70, 84, -80, 34, 19 },
		{ 85, 96, 22, 28, 16 },
		{ abyss.x, 104, abyss.z, 30, 22 },
		{ -60, 76, 62, 22, 14 },
	}
	for index, flight in flights do
		local spec = birdSpec(2.2, feathers[(index + 1) % #feathers + 1], flight[4], flight[5])
		local base = CFrame.new(flight[1], flight[2], flight[3]) * CFrame.Angles(0, math.rad(rng.range(0, 360)), 0)
		if not place("Wildlife", spec, base, "air") then
			table.insert(skipped, spec.name)
		end
	end
end

decor.Parent = map

-- Lighting mood. Time of day belongs to WeatherService and is not touched here. -----------

local function effect(className, name, properties)
	local instance = Lighting:FindFirstChild(name)
	if not instance or instance.ClassName ~= className then
		instance = Lighting:FindFirstChildOfClass(className)
	end
	if not instance then
		instance = Instance.new(className)
		instance.Name = name
		instance.Parent = Lighting
	end
	for key, value in properties do
		instance[key] = value
	end
end

effect("Atmosphere", "Atmosphere", {
	Density = 0.24, -- light haze: the far cliff wall softens, the near one stays crisp
	Offset = 0.1,
	Color = rgb(245, 226, 196),
	Decay = rgb(140, 160, 180),
	Glare = 0.1,
	Haze = 1,
})
effect("BloomEffect", "Bloom", { Enabled = true, Intensity = 0.35, Size = 22, Threshold = 1.1 })
effect("ColorCorrectionEffect", "ColorCorrection", {
	Enabled = true,
	Brightness = 0,
	Contrast = 0.08,
	Saturation = 0.12,
	TintColor = rgb(255, 250, 242),
})
effect("SunRaysEffect", "SunRays", { Enabled = true, Intensity = 0.06, Spread = 0.6 })

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

local notes = ""
if #skipped > 0 then
	notes ..= ` Skipped (no legal spot): {table.concat(skipped, ", ")}.`
end
if partCount > BUDGET.parts or lightCount > BUDGET.lights or animatedCount > BUDGET.animated then
	notes ..= ` OVER BUDGET (max {BUDGET.parts} parts, {BUDGET.lights} lights, {BUDGET.animated} animated).`
end
print(
	`[BuildEnvironment] Dressed Workspace.Map.Decor v{VERSION}: {partCount} parts, {lightCount} lights, {animatedCount} animated instances ({propCount} props).{notes}`
)
