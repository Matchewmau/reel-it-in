--[[
	Map builder: "The Basin" (layout v3), from reference/revised map.jpeg.

	A cliff-ringed basin of solid ground. North: The Falls feed a river that
	runs past the east side of the hub (the freshwater fishing area) and pours
	into the Abyss, a deep hole in the south that is the saltwater / deep-sea
	fishing spot. The Player Hub and market sit in the middle. Three sunken
	ponds line each side (P1-P3 east, P4-P6 west), each joined to the hub by a
	straight boardwalk and to its neighbours by a circulation loop.

	HOW TO RUN (edit mode, never during a playtest):
	  * Studio MCP: pass this whole file to the `execute_luau` tool, or
	  * paste it into Studio's Command Bar.
	  Then run BuildEnvironment.luau if it exists (set-dressing lives in
	  Map.Decor, which this script wipes along with the rest of the map).

	This is build tooling, not game code. It lives outside src/ so Rojo never
	syncs it, and it creates no scripts. It is idempotent: re-running replaces
	a Map that this script created, and refuses to touch one it did not.

	HOW IT WORKS
	  The floor is generated on a grid of CELL-sized squares. `classify`
	  decides what each cell is (grass, sand, boardwalk, river, pond hole,
	  abyss...) from a few shapes, and each kind is merged into as few boxes
	  as possible. Because the ground is solid everywhere except the pond
	  holes (covered by an invisible lid) and the Abyss (ringed by a railing
	  and an invisible barrier), there is nowhere to fall by accident. The
	  river is a shallow channel you can wade through or cross on bridges.

	Contract with the game code (do not rename without updating the services):
	  Workspace.Map.FishingZones.<any part>   attribute Biome = "Freshwater" | "Saltwater"
	  Workspace.Map.Ponds.Pond<1..6>          attributes Plot, OwnerUserId, OwnerName
	      .Water                              swim volume for PondVisualController
	      ...OwnerLabel (TextLabel)           sign text, set by the client
	      ...ProximityPrompt                  attribute Action = "Bless"
	      .Spawn                              where the owner (and visitors) arrive
	  Workspace.Map.TravelPoints.<id>         fast-travel markers: Hub, Freshwater, Saltwater
	  Workspace.Map.Vendors.<Vendor>          ProximityPrompt attribute OpenPanel = HUD tab
	  Fishable water is CanCollide = false and queryable (the bobber raycast
	  relies on it); pond water, rails and barriers are CanQuery = false.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Workspace = game:GetService("Workspace")

local VERSION = 3

-- Layout (studs). North is -Z, east is +X. Ground level is y = 0. ---------------------
local CELL = 4 -- terrain grid size
local EXTENT = 240 -- the grid spans -EXTENT..EXTENT on X and Z
local BASIN_RADIUS = 236 -- radius of the walkable floor
local HUB_RADIUS = 40 -- sand plaza
local LOOP_RADIUS = 105 -- circulation boardwalk linking all six ponds
local PATH_WIDTH = 14
local POND_RADIUS = 158 -- distance from the hub to each pond's centre
-- Compass angles (0 = east, 90 = south). Plot order matches the reference map:
-- P1 north-east, P2 east, P3 south-east, P4 north-west, P5 west, P6 south-west.
local POND_ANGLES = { 315, 0, 45, 225, 180, 135 }
local POND_HALF = 26 -- half-size of a pond hole (a rounded square)
local POND_RIM = 30 -- half-size including its stone rim
local POND_POWER = 8 -- superellipse exponent: higher = squarer corners
local WATER_SIZE = 46 -- pond swim volume (must fit inside the hole)
local WATER_DEPTH = 6.5
local ABYSS = { x = 0, z = 115, radius = 50, ring = 14, waterY = -38, floorY = -72 }
local LAGOON = { x = -70, z = 5, radiusX = 22, radiusZ = 45 } -- west lake
-- River centre line from The Falls to the Abyss: { x, z, width }.
local RIVER = {
	{ 0, -236, 24 },
	{ 0, -190, 22 },
	{ 20, -140, 16 },
	{ 48, -90, 16 },
	{ 66, -40, 24 },
	{ 70, 8, 30 },
	{ 58, 50, 18 },
	{ 34, 78, 16 },
}
local RIVER_BED_Y = -2.5
local RIVER_SURFACE_Y = -1.2
local RAIL_HEIGHT = 3.2
local RAIL_PIECE = 14
local BARRIER_HEIGHT = 14 -- invisible wall above the deck (jump height is ~7.2)
local ABYSS_RAIL = ABYSS.radius + 3.5 -- outside the stair-stepped edge of the hole
local CLIFF = { segments = 44, thickness = 44, height = 78, variance = 16 }

local COLOR = {
	Grass = Color3.fromRGB(104, 172, 88),
	Dirt = Color3.fromRGB(122, 88, 60),
	Stone = Color3.fromRGB(132, 136, 144),
	StoneDark = Color3.fromRGB(92, 96, 104),
	Cliff = Color3.fromRGB(118, 122, 130),
	CliffDark = Color3.fromRGB(96, 100, 110),
	Wood = Color3.fromRGB(156, 110, 66),
	WoodDark = Color3.fromRGB(108, 74, 46),
	Rope = Color3.fromRGB(214, 190, 140),
	Sand = Color3.fromRGB(222, 204, 156),
	RiverBed = Color3.fromRGB(150, 150, 132),
	Fresh = Color3.fromRGB(86, 190, 236),
	Pond = Color3.fromRGB(70, 170, 220),
	Deep = Color3.fromRGB(22, 70, 170),
	AbyssWall = Color3.fromRGB(46, 58, 96),
	Foam = Color3.fromRGB(236, 248, 255),
	Shrine = Color3.fromRGB(120, 230, 255),
	Sign = Color3.fromRGB(28, 40, 72),
}

local existing = Workspace:FindFirstChild("Map")
if existing and existing:GetAttribute("GreyboxVersion") == nil then
	error("Workspace.Map already exists and was not made by BuildGreybox - rename or remove it first.")
end

local recording = ChangeHistoryService:TryBeginRecording("Build Reel It In map")
if existing then
	existing:Destroy()
end

local partCount = 0

local function folder(name, parent)
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function model(name, parent)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function part(parent, name, size, cframe, color, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = true
	if props then
		for key, value in props do
			p[key] = value
		end
	end
	p.Parent = parent
	partCount += 1
	return p
end

-- Vertical disc: Roblox cylinders run along X, so rotate 90 degrees about Z.
local function disc(parent, name, radius, height, center, color, props)
	local p = part(
		parent,
		name,
		Vector3.new(height, radius * 2, radius * 2),
		CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		props
	)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function label(parent, name, text, face, textColor)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = parent
	local text_ = Instance.new("TextLabel")
	text_.Name = name
	text_.Size = UDim2.fromScale(1, 1)
	text_.BackgroundTransparency = 1
	text_.Font = Enum.Font.GothamBlack
	text_.TextScaled = true
	text_.TextColor3 = textColor or Color3.new(1, 1, 1)
	text_.Text = text
	text_.Parent = gui
	return text_
end

local function prompt(parent, objectText, actionText, distance)
	local p = Instance.new("ProximityPrompt")
	p.ObjectText = objectText
	p.ActionText = actionText
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.HoldDuration = 0
	p.MaxActivationDistance = distance
	p.RequiresLineOfSight = false
	p.Parent = parent
	return p
end

-- Unit direction for a compass angle in degrees.
local function radial(degrees)
	local a = math.rad(degrees)
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

-- Shapes ---------------------------------------------------------------------------

local pondCenters = {}
for plot, degrees in POND_ANGLES do
	pondCenters[plot] = radial(degrees) * POND_RADIUS
end

-- Distance from (x, z) to segment a-b, and how far along it (0..1) the nearest point is.
local function segmentDistance(x, z, ax, az, bx, bz)
	local dx, dz = bx - ax, bz - az
	local t = math.clamp(((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz), 0, 1)
	local px, pz = ax + dx * t, az + dz * t
	return math.sqrt((x - px) ^ 2 + (z - pz) ^ 2), t
end

local function inRiver(x, z)
	for index = 1, #RIVER - 1 do
		local a, b = RIVER[index], RIVER[index + 1]
		local distance, t = segmentDistance(x, z, a[1], a[2], b[1], b[2])
		if distance <= (a[3] + (b[3] - a[3]) * t) / 2 then
			return true
		end
	end
	return false
end

local function inLagoon(x, z)
	return ((x - LAGOON.x) / LAGOON.radiusX) ^ 2 + ((z - LAGOON.z) / LAGOON.radiusZ) ^ 2 <= 1
end

-- Which pond's rounded square (of the given half-size) contains (x, z), if any.
local function pondAt(x, z, half)
	for plot, center in pondCenters do
		local dx, dz = math.abs(x - center.X) / half, math.abs(z - center.Z) / half
		if dx ^ POND_POWER + dz ^ POND_POWER <= 1 then
			return plot
		end
	end
	return nil
end

local function abyssDistance(x, z)
	return math.sqrt((x - ABYSS.x) ^ 2 + (z - ABYSS.z) ^ 2)
end

-- Boardwalks: one straight spoke from the hub to every pond, a spoke south to the
-- Abyss, the circulation loop, and the ring around the Abyss.
local function onPath(x, z)
	local half = PATH_WIDTH / 2
	local r = math.sqrt(x * x + z * z)
	if math.abs(r - LOOP_RADIUS) <= half then
		return true
	end
	local toAbyss = abyssDistance(x, z)
	if toAbyss >= ABYSS.radius and toAbyss < ABYSS.radius + ABYSS.ring then
		return true
	end
	for _, degrees in POND_ANGLES do
		local direction = radial(degrees)
		local from, to = direction * (HUB_RADIUS - 4), direction * (POND_RADIUS - POND_RIM + 2)
		if segmentDistance(x, z, from.X, from.Z, to.X, to.Z) <= half then
			return true
		end
	end
	return segmentDistance(x, z, 0, HUB_RADIUS - 4, 0, ABYSS.z - ABYSS.radius) <= half
end

-- What is at (x, z)?
--   "none" outside the basin   "void" the Abyss        "pond" a pond hole
--   "rim" stone pond surround  "bridge" boardwalk over water
--   "path" boardwalk on land   "water" river / lagoon  "sand" hub plaza   "grass"
local function classify(x, z)
	local r = math.sqrt(x * x + z * z)
	if r > BASIN_RADIUS + CELL then
		return "none"
	end
	if abyssDistance(x, z) < ABYSS.radius then
		return "void"
	end
	if pondAt(x, z, POND_HALF) then
		return "pond"
	end
	local wet = inRiver(x, z) or inLagoon(x, z)
	if onPath(x, z) then
		return if wet then "bridge" else "path"
	end
	if pondAt(x, z, POND_RIM) then
		return "rim"
	end
	if wet then
		return "water"
	end
	if r < HUB_RADIUS then
		return "sand"
	end
	return "grass"
end

-- Terrain --------------------------------------------------------------------------

local map = folder("Map", Workspace)
map:SetAttribute("GreyboxVersion", VERSION)

local terrain = folder("Terrain", map)
local COUNT = EXTENT * 2 / CELL
local grid = table.create(COUNT)
for j = 1, COUNT do
	local row = table.create(COUNT)
	local z = -EXTENT + (j - 0.5) * CELL
	for i = 1, COUNT do
		row[i] = classify(-EXTENT + (i - 0.5) * CELL, z)
	end
	grid[j] = row
end

-- Greedy-merges every cell whose kind is in `kinds` into rectangles and calls
-- emit(centerX, centerZ, sizeX, sizeZ) for each.
local function merge(kinds, emit)
	local used = {}
	for j = 1, COUNT do
		used[j] = {}
	end
	for j = 1, COUNT do
		for i = 1, COUNT do
			if kinds[grid[j][i]] and not used[j][i] then
				local width = 1
				while i + width <= COUNT and kinds[grid[j][i + width]] and not used[j][i + width] do
					width += 1
				end
				local depth = 1
				while j + depth <= COUNT do
					local full = true
					for k = i, i + width - 1 do
						if not kinds[grid[j + depth][k]] or used[j + depth][k] then
							full = false
							break
						end
					end
					if not full then
						break
					end
					depth += 1
				end
				for jj = j, j + depth - 1 do
					for ii = i, i + width - 1 do
						used[jj][ii] = true
					end
				end
				emit(
					-EXTENT + (i - 1 + width / 2) * CELL,
					-EXTENT + (j - 1 + depth / 2) * CELL,
					width * CELL,
					depth * CELL
				)
			end
		end
	end
end

-- A layer of boxes between two heights for the given cell kinds.
local function layer(name, kinds, bottomY, topY, color, props)
	merge(kinds, function(x, z, sizeX, sizeZ)
		part(
			terrain,
			name,
			Vector3.new(sizeX, topY - bottomY, sizeZ),
			CFrame.new(x, (topY + bottomY) / 2, z),
			color,
			props
		)
	end)
end

local SOIL_BOTTOM = -18
layer("Soil", { grass = true, sand = true, rim = true, path = true }, SOIL_BOTTOM, -1, COLOR.Dirt)
layer("Grass", { grass = true }, -1, 0, COLOR.Grass)
layer("Sand", { sand = true }, -1, 0, COLOR.Sand)
layer("PondRim", { rim = true }, -1, 0.3, COLOR.Stone)
layer("Boardwalk", { path = true, bridge = true }, -1, 0.15, COLOR.Wood)
layer("RiverBed", { water = true, bridge = true }, SOIL_BOTTOM, RIVER_BED_Y, COLOR.RiverBed)
layer("Water", { water = true, bridge = true }, RIVER_BED_Y, RIVER_SURFACE_Y, COLOR.Fresh, {
	Transparency = 0.25,
	CanCollide = false,
	CastShadow = false,
})

-- Railings ---------------------------------------------------------------------------
-- A visible post-and-rope rail plus an invisible barrier. The rail is decoration
-- only (no collision, ignored by raycasts); the barrier does all the blocking.

local railings = folder("Railings", map)
local RAIL_PROPS = { CastShadow = false, CanCollide = false, CanQuery = false, CanTouch = false }

local function railPost(position)
	part(
		railings,
		"RailPost",
		Vector3.new(0.9, RAIL_HEIGHT + 0.5, 0.9),
		CFrame.new(position.X, (RAIL_HEIGHT + 0.5) / 2, position.Z),
		COLOR.WoodDark,
		RAIL_PROPS
	)
end

local function railPiece(a, b)
	local length = (b - a).Magnitude
	local mid = (a + b) / 2
	local facing = CFrame.lookAt(Vector3.new(mid.X, 0, mid.Z), Vector3.new(b.X, 0, b.Z))
	railPost(a)
	part(
		railings,
		"Rail",
		Vector3.new(0.5, 0.5, length),
		facing * CFrame.new(0, RAIL_HEIGHT, 0),
		COLOR.Rope,
		RAIL_PROPS
	)
	part(
		railings,
		"RailLow",
		Vector3.new(0.4, 0.4, length),
		facing * CFrame.new(0, RAIL_HEIGHT * 0.5, 0),
		COLOR.Rope,
		RAIL_PROPS
	)
	part(
		railings,
		"Barrier",
		Vector3.new(0.8, BARRIER_HEIGHT, length + 0.8),
		facing * CFrame.new(0, BARRIER_HEIGHT / 2, 0),
		COLOR.Rope,
		{
			Transparency = 1,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		}
	)
end

-- A closed ring of railing.
local function railRing(center, radius)
	local pieces = math.ceil(2 * math.pi * radius / RAIL_PIECE)
	for index = 0, pieces - 1 do
		local a = center + radial(index / pieces * 360) * radius
		local b = center + radial((index + 1) / pieces * 360) * radius
		railPiece(a, b)
	end
end

-- The Abyss (saltwater / deep-sea fishing) ---------------------------------------------

local abyss = model("Abyss", map)
local abyssCenter = Vector3.new(ABYSS.x, 0, ABYSS.z)
do
	-- Shaft walls below the soil layer.
	local segments = 32
	local wallRadius = ABYSS.radius + 7
	local wallHeight = SOIL_BOTTOM - ABYSS.floorY + 2
	local wallLength = 2 * math.pi * (wallRadius + 7) / segments + 0.5
	for index = 0, segments - 1 do
		local direction = radial(index / segments * 360)
		local position = abyssCenter + direction * wallRadius + Vector3.new(0, SOIL_BOTTOM - wallHeight / 2 + 1, 0)
		part(
			abyss,
			"ShaftWall",
			Vector3.new(wallLength, wallHeight, 14),
			CFrame.lookAt(position, position + direction),
			if index % 2 == 0 then COLOR.AbyssWall else COLOR.StoneDark
		)
	end
	disc(abyss, "Floor", ABYSS.radius + 8, 2, abyssCenter + Vector3.new(0, ABYSS.floorY, 0), COLOR.AbyssWall)
	-- Fishable water: non-colliding and queryable so bobbers land on it.
	disc(abyss, "Water", ABYSS.radius + 3, 4, abyssCenter + Vector3.new(0, ABYSS.waterY - 2, 0), COLOR.Deep, {
		Transparency = 0.2,
		CanCollide = false,
		CastShadow = false,
	})
	local glow = disc(
		abyss,
		"Glow",
		ABYSS.radius * 0.6,
		1,
		abyssCenter + Vector3.new(0, ABYSS.waterY - 12, 0),
		Color3.fromRGB(60, 120, 255),
		{
			Material = Enum.Material.Neon,
			Transparency = 0.4,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		}
	)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(80, 140, 255)
	light.Range = 60
	light.Brightness = 2
	light.Parent = glow

	-- Waterfalls pouring over the rim: the river mouth plus two decorative falls.
	local mouth = RIVER[#RIVER]
	local mouthAngle = math.deg(math.atan2(mouth[2] - ABYSS.z, mouth[1] - ABYSS.x))
	for _, fall in { { mouthAngle, 14 }, { mouthAngle + 150, 9 }, { mouthAngle - 140, 9 } } do
		local direction = radial(fall[1])
		local height = RIVER_SURFACE_Y - ABYSS.waterY
		local position = abyssCenter + direction * (ABYSS.radius - 1.5) + Vector3.new(0, ABYSS.waterY + height / 2, 0)
		part(
			abyss,
			"Waterfall",
			Vector3.new(fall[2], height, 1.2),
			CFrame.lookAt(position, position + direction),
			COLOR.Fresh,
			{
				Material = Enum.Material.Neon,
				Transparency = 0.2,
				CanCollide = false,
				CanQuery = false,
				CastShadow = false,
			}
		)
		part(
			abyss,
			"Foam",
			Vector3.new(fall[2] + 4, 1.5, 5),
			CFrame.lookAt(
				abyssCenter + direction * (ABYSS.radius - 4) + Vector3.new(0, ABYSS.waterY + 0.4, 0),
				abyssCenter + Vector3.new(0, ABYSS.waterY + 0.4, 0)
			),
			COLOR.Foam,
			{ CanCollide = false, CanQuery = false, CastShadow = false }
		)
	end

	-- The only real drop in the map: ring it completely.
	railRing(abyssCenter, ABYSS_RAIL)
end

-- Encircling cliff walls + The Falls -----------------------------------------------------

local cliffs = folder("Cliffs", map)
do
	local centerRadius = BASIN_RADIUS + CLIFF.thickness / 2 - 2
	local length = 2 * math.pi * (centerRadius + CLIFF.thickness / 2) / CLIFF.segments + 1
	local fallsHeight = CLIFF.height - 12
	for index = 0, CLIFF.segments - 1 do
		local degrees = index / CLIFF.segments * 360
		local direction = radial(degrees)
		local isFalls = math.abs(degrees - 270) < 360 / CLIFF.segments * 0.6
		-- Deterministic height variation so the rim looks craggy, not machined.
		local height = if isFalls
			then fallsHeight
			else CLIFF.height + math.floor((math.sin(index * 2.7) * 0.5 + 0.5) * CLIFF.variance)
		local base = direction * centerRadius
		local cframe = CFrame.lookAt(base, base + direction)
		part(
			cliffs,
			"Cliff",
			Vector3.new(length, height - SOIL_BOTTOM, CLIFF.thickness),
			cframe * CFrame.new(0, (height + SOIL_BOTTOM) / 2, 0),
			if index % 2 == 0 then COLOR.Cliff else COLOR.CliffDark
		)
		part(
			cliffs,
			"CliffTop",
			Vector3.new(length, 2, CLIFF.thickness),
			cframe * CFrame.new(0, height + 1, 0),
			if isFalls then COLOR.Fresh else COLOR.Grass,
			if isFalls then { Material = Enum.Material.Neon, Transparency = 0.2 } else nil
		)
		-- A stepped ledge at the foot of each wall breaks up the sheer face.
		if not isFalls then
			local ledge = 18 + (index % 3) * 10
			part(
				cliffs,
				"CliffLedge",
				Vector3.new(length, ledge, 10),
				cframe * CFrame.new(0, ledge / 2, CLIFF.thickness / 2 + 3),
				if index % 2 == 0 then COLOR.CliffDark else COLOR.Cliff
			)
		end
	end

	-- The Falls: three tiers stepping down the north wall into the river head.
	local falls = model("TheFalls", cliffs)
	local FALL = { Material = Enum.Material.Neon, Transparency = 0.2, CanCollide = false, CanQuery = false }
	local wallZ = -(BASIN_RADIUS - 2)
	local tiers = {
		{ top = fallsHeight + 2, bottom = 44, z = wallZ + 1, width = 26 },
		{ top = 44, bottom = 20, z = wallZ + 9, width = 30 },
		{ top = 20, bottom = RIVER_SURFACE_Y, z = wallZ + 18, width = 34 },
	}
	for index, tier in tiers do
		part(
			falls,
			"Cascade",
			Vector3.new(tier.width, tier.top - tier.bottom, 1.5),
			CFrame.new(0, (tier.top + tier.bottom) / 2, tier.z),
			COLOR.Fresh,
			FALL
		)
		-- Rock shelf each tier lands on, with foam along its lip.
		if index < #tiers then
			local nextZ = tiers[index + 1].z
			part(
				falls,
				"Shelf",
				Vector3.new(tier.width + 12, tier.bottom - SOIL_BOTTOM, nextZ - tier.z),
				CFrame.new(0, (tier.bottom + SOIL_BOTTOM) / 2 - 1, (tier.z + nextZ) / 2),
				COLOR.CliffDark
			)
			part(
				falls,
				"ShelfWater",
				Vector3.new(tier.width, 0.6, nextZ - tier.z),
				CFrame.new(0, tier.bottom - 0.6, (tier.z + nextZ) / 2),
				COLOR.Fresh,
				FALL
			)
		end
		part(
			falls,
			"Foam",
			Vector3.new(tier.width + 4, 2.5, 4),
			CFrame.new(0, tier.bottom + 1, tier.z + 2),
			COLOR.Foam,
			{ CanCollide = false, CanQuery = false, CastShadow = false }
		)
	end
end

-- Player Hub -------------------------------------------------------------------------

local hub = folder("Hub", map)

local spawn = Instance.new("SpawnLocation")
spawn.Name = "HubSpawn"
spawn.Size = Vector3.new(10, 1, 10)
spawn.CFrame = CFrame.new(0, 0.5, 10)
spawn.Anchored = true
spawn.Neutral = true
spawn.Color = COLOR.Stone
spawn.Material = Enum.Material.SmoothPlastic
spawn.TopSurface = Enum.SurfaceType.Smooth
spawn.Parent = hub
partCount += 1

-- Fishing zones: invisible volumes the server tests the player's position against.
local zones = folder("FishingZones", map)
local function zone(name, biome, size, position)
	local z = part(zones, name, size, CFrame.new(position), COLOR.Fresh, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
	})
	z:SetAttribute("Biome", biome)
	return z
end
zone("FreshwaterFalls", "Freshwater", Vector3.new(70, 24, 110), Vector3.new(8, 8, -175))
zone("FreshwaterRiver", "Freshwater", Vector3.new(60, 24, 150), Vector3.new(60, 8, -36))
zone("FreshwaterLagoon", "Freshwater", Vector3.new(64, 24, 110), Vector3.new(LAGOON.x, 8, LAGOON.z))
zone("SaltwaterAbyss", "Saltwater", Vector3.new(136, 24, 134), Vector3.new(ABYSS.x, 8, ABYSS.z + 2))

-- Fast-travel arrival markers (TravelService). Named by Travel.luau destination id;
-- the character arrives above the marker, facing the marker's -Z.
local travelPoints = folder("TravelPoints", map)
local function travelPoint(id, position, lookAt)
	local at = Vector3.new(position.X, 0.5, position.Z)
	return part(
		travelPoints,
		id,
		Vector3.new(4, 1, 4),
		CFrame.lookAt(at, Vector3.new(lookAt.X, at.Y, lookAt.Z)),
		COLOR.Stone,
		{
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		}
	)
end
travelPoint("Hub", Vector3.new(0, 0, 16), Vector3.new(0, 0, -30))
travelPoint("Freshwater", Vector3.new(46, 0, 6), Vector3.new(70, 0, 6))
travelPoint("Saltwater", Vector3.new(0, 0, ABYSS.z - ABYSS.radius - 9), abyssCenter)

-- Vendors: a market row along the north side of the plaza, facing the centre. --------

local vendors = folder("Vendors", map)

local function vendor(name, title, panel, position, build)
	local v = model(name, vendors)
	-- A vendor's front (prompt side) is its local -Z; this yaw points it at the origin.
	local origin = CFrame.new(position) * CFrame.Angles(0, math.atan2(position.X, position.Z), 0)
	build(v, origin)

	local board = part(v, "Sign", Vector3.new(10, 2.5, 0.4), origin * CFrame.new(0, 9, 0), COLOR.Sign)
	label(board, "Title", title, Enum.NormalId.Front)
	label(board, "TitleBack", title, Enum.NormalId.Back)
	part(v, "SignPost", Vector3.new(0.6, 8, 0.6), origin * CFrame.new(-4.5, 4, 0), COLOR.WoodDark)
	part(v, "SignPost", Vector3.new(0.6, 8, 0.6), origin * CFrame.new(4.5, 4, 0), COLOR.WoodDark)

	local anchor = part(v, "Prompt", Vector3.new(1, 1, 1), origin * CFrame.new(0, 3, -4), COLOR.Sign, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	local p = prompt(anchor, title, "Open", 12)
	p:SetAttribute("OpenPanel", panel)
	v.PrimaryPart = anchor
	return v
end

-- A: Rod Gacha Shrine
vendor("RodGachaShrine", "ROD GACHA SHRINE", "Shop", Vector3.new(-24, 0, -24), function(v, origin)
	part(v, "BaseLower", Vector3.new(12, 1, 12), origin * CFrame.new(0, 0.5, 0), COLOR.StoneDark)
	part(v, "BaseUpper", Vector3.new(8, 1, 8), origin * CFrame.new(0, 1.5, 0), COLOR.Stone)
	local flame = part(v, "Flame", Vector3.new(3, 4, 3), origin * CFrame.new(0, 4, 0), COLOR.Shrine, {
		Material = Enum.Material.Neon,
		CanCollide = false,
	})
	local light = Instance.new("PointLight")
	light.Color = COLOR.Shrine
	light.Range = 18
	light.Brightness = 2
	light.Parent = flame
	part(v, "FlameCore", Vector3.new(1.6, 2, 1.6), origin * CFrame.new(0, 7, 0), Color3.fromRGB(255, 120, 220), {
		Material = Enum.Material.Neon,
		CanCollide = false,
	})
end)

-- B: Bait Merchant & Crate Gacha
vendor("BaitMerchant", "BAIT MERCHANT", "Baits", Vector3.new(0, 0, -33), function(v, origin)
	part(v, "Counter", Vector3.new(10, 3, 3), origin * CFrame.new(0, 1.5, 0), COLOR.Wood)
	part(v, "Roof", Vector3.new(12, 0.8, 7), origin * CFrame.new(0, 7.4, 1), Color3.fromRGB(196, 70, 60))
	for _, x in { -5, 5 } do
		part(v, "RoofPost", Vector3.new(0.8, 7, 0.8), origin * CFrame.new(x, 3.5, 3.5), COLOR.WoodDark)
	end
	part(v, "Crate", Vector3.new(3, 3, 3), origin * CFrame.new(-8, 1.5, 1), COLOR.Wood)
	part(v, "CrateSmall", Vector3.new(2, 2, 2), origin * CFrame.new(-8, 4, 1), COLOR.WoodDark)
	part(v, "Crate", Vector3.new(3, 3, 3), origin * CFrame.new(8, 1.5, 2), COLOR.Wood)
end)

-- C: Fish Appraiser & Seller
vendor("FishAppraiser", "FISH APPRAISER", "Backpack", Vector3.new(24, 0, -24), function(v, origin)
	part(v, "Table", Vector3.new(9, 0.8, 4), origin * CFrame.new(0, 3, 0), COLOR.Wood)
	for _, x in { -4, 4 } do
		for _, z in { -1.5, 1.5 } do
			part(v, "TableLeg", Vector3.new(0.6, 2.6, 0.6), origin * CFrame.new(x, 1.3, z), COLOR.WoodDark)
		end
	end
	part(v, "ScaleBase", Vector3.new(1, 2, 1), origin * CFrame.new(0, 4.4, 0), COLOR.StoneDark)
	part(v, "ScaleBeam", Vector3.new(5, 0.4, 0.4), origin * CFrame.new(0, 5.6, 0), Color3.fromRGB(255, 204, 64))
	for _, x in { -2.3, 2.3 } do
		part(v, "ScalePan", Vector3.new(1.6, 0.3, 1.6), origin * CFrame.new(x, 4.6, 0), Color3.fromRGB(255, 204, 64))
	end
end)

-- Sunken player ponds ----------------------------------------------------------------

local ponds = folder("Ponds", map)
local pondFloorY = -1 - WATER_DEPTH - 0.5 -- top of the pond floor

for plot, center in pondCenters do
	local toHub = -center.Unit
	local side = Vector3.new(-toHub.Z, 0, toHub.X)

	local pond = model("Pond" .. plot, ponds)
	pond:SetAttribute("Plot", plot)
	pond:SetAttribute("OwnerUserId", 0)
	pond:SetAttribute("OwnerName", "")

	part(
		pond,
		"Floor",
		Vector3.new(POND_HALF * 2 + 2, 1, POND_HALF * 2 + 2),
		CFrame.new(center.X, pondFloorY - 0.5, center.Z),
		COLOR.StoneDark
	)

	-- Swim volume. PondVisualController keeps creatures inside this part's bounds.
	local water = part(
		pond,
		"Water",
		Vector3.new(WATER_SIZE, WATER_DEPTH, WATER_SIZE),
		CFrame.new(center.X, pondFloorY + WATER_DEPTH / 2, center.Z),
		COLOR.Pond,
		{
			Transparency = 0.78,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		}
	)
	pond.PrimaryPart = water

	-- Fills the rounded corners of the hole that the box-shaped swim volume leaves dry.
	part(
		pond,
		"WaterSurface",
		Vector3.new(POND_HALF * 2 + 1, 0.3, POND_HALF * 2 + 1),
		CFrame.new(center.X, -1.2, center.Z),
		COLOR.Pond,
		{
			Transparency = 0.6,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		}
	)

	-- Invisible lid so nobody falls into a pond they can't climb out of.
	part(
		pond,
		"Cover",
		Vector3.new(POND_HALF * 2 + 1, 0.5, POND_HALF * 2 + 1),
		CFrame.new(center.X, -0.25, center.Z),
		COLOR.Pond,
		{
			Transparency = 1,
			CanQuery = false,
			CastShadow = false,
		}
	)

	-- Claimable gate + signpost where the hub boardwalk arrives.
	local gate = center + toHub * (POND_RIM + 1)
	local facing = CFrame.lookAt(gate, gate + toHub) -- local -Z points at the hub
	for _, sign in { -1, 1 } do
		part(
			pond,
			"GatePost",
			Vector3.new(1.5, 11, 1.5),
			facing * CFrame.new(sign * (PATH_WIDTH / 2 + 1), 5.5, 0),
			COLOR.WoodDark
		)
	end
	local board = part(pond, "Sign", Vector3.new(PATH_WIDTH + 3.5, 3, 0.5), facing * CFrame.new(0, 10, 0), COLOR.Sign)
	label(board, "OwnerLabel", "Unclaimed Pond", Enum.NormalId.Front)

	-- Feeding / blessing node.
	local feedAt = gate + side * 13
	local pedestal = part(pond, "FeedNode", Vector3.new(3, 3, 3), CFrame.new(feedAt.X, 1.5, feedAt.Z), COLOR.Wood)
	part(
		pond,
		"FeedBowl",
		Vector3.new(2.2, 0.6, 2.2),
		CFrame.new(feedAt.X, 3.3, feedAt.Z),
		Color3.fromRGB(255, 204, 64)
	)
	local feed = prompt(pedestal, "Neighbour's Pond", "Feed (+15% Luck)", 10)
	feed:SetAttribute("Action", "Bless")

	-- Where the owner is dropped off (not a SpawnLocation; reserved for the service).
	local spawnAt = gate - side * 13 + toHub * 3
	part(pond, "Spawn", Vector3.new(4, 1, 4), CFrame.new(spawnAt.X, 0.5, spawnAt.Z), COLOR.Stone, {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

print(
	`[BuildGreybox] Built Workspace.Map v{VERSION} "The Basin": {partCount} parts, {#POND_ANGLES} sunken ponds, the Abyss, The Falls + river, 3 vendors, 4 fishing zones, 3 travel points.`
)
