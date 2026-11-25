-- Headless dry run of tools/studio/BuildEnvironment.luau, using Lune's Roblox
-- instance implementation. Builds the greybox map in a fake DataModel, dresses
-- it twice, and asserts the budget, the placement rules and the contract with
-- the client's AmbientController, without touching a real place.
--
--   lune run tools/studio/dryrun_environment.luau
--
-- The checks here are written independently of the builder (they only look at
-- the instances it produced), so a rule the builder forgets is a rule this fails.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox") :: any

local Vector3 = roblox.Vector3

local GREYBOX = "tools/studio/BuildGreybox.luau"
local BUILDER = "tools/studio/BuildEnvironment.luau"

-- The brief's numbers (studs). Kept literal here on purpose: they are the spec.
local BUDGET = { parts = 1300, lights = 40, animated = 30 }
local FLOOR_Y = 12 -- parts whose bottom is at or below this...
local FLOOR_RADIUS = 234 -- ...inside this radius are floor decor
local FOOT_MARGIN = 1.5
local HUB_RADIUS = 40
local MARKET_Z = -14
local MARKET_PROP_SIZE = 5 -- "small": footprint no wider than this on the plaza
local MARKET_PROP_HEIGHT = 12
local VENDOR_HUG = 16 -- plaza props and NPCs stay this close to a vendor prompt
local CLEAR_RADIUS = 7
local LANE_HALF = 4.5
local POND_VIEW_RADIUS = 34
local POND_VIEW_HEIGHT = 9
local ABYSS_HOLE = 50
local ABYSS_PROP_RADIUS = 46
local FALLS = { halfX = 22, z = -200 }
local NPCS = { ShrineKeeper = "RodGachaShrine", BaitMerchantNpc = "BaitMerchant", AppraiserNpc = "FishAppraiser" }
local EFFECTS = { "Atmosphere", "BloomEffect", "ColorCorrectionEffect", "SunRaysEffect" }
local AMBIENT = { "AmbientBob", "AmbientSway", "AmbientOrbit" }

local game = roblox.Instance.new("DataModel")
-- Unlike dryrun.luau this stand-in hands out a recording, so the builders' commit path runs too.
local recordings = { begun = 0, committed = 0 }
local services = {
	Workspace = game:GetService("Workspace"),
	Lighting = game:GetService("Lighting"),
	ChangeHistoryService = {
		TryBeginRecording = function(_, name: string)
			recordings.begun += 1
			return `recording {recordings.begun}: {name}`
		end,
		FinishRecording = function(_, recording: string, operation)
			if
				recording == nil
				or string.find(recording, `recording {recordings.begun}:`, 1, true) ~= 1
				or operation ~= roblox.Enum.FinishRecordingOperation.Commit
			then
				error("FinishRecording was not given the open recording and Commit")
			end
			recordings.committed += 1
		end,
	},
}
local fakeGame = {
	GetService = function(_, name: string)
		return assert(services[name], "dryrun has no stand-in for service " .. name)
	end,
}

local function run(path: string)
	local env = {
		game = fakeGame,
		workspace = services.Workspace,
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
	}
	luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local failures = 0
local function check(label: string, condition: boolean, detail: string?)
	if not condition then
		failures += 1
	end
	print(`  {if condition then "ok   " else "FAIL "} {label} {if condition then "" else detail or ""}`)
end

-- Collects up to a few offenders and formats them for a FAIL line.
local function offenders()
	local list = {}
	local count = 0
	return {
		add = function(text: string)
			count += 1
			if #list < 4 then
				table.insert(list, text)
			end
		end,
		none = function(): boolean
			return count == 0
		end,
		detail = function(): string
			return `{count}: {table.concat(list, "; ")}`
		end,
	}
end

-- Geometry ----------------------------------------------------------------------------------

type Bounds = {
	part: any,
	group: any,
	x: number,
	y: number,
	z: number,
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
}

local function boundsOf(part): Bounds
	local cframe, size = part.CFrame, part.Size
	local a = cframe:VectorToWorldSpace(Vector3.new(size.X / 2, 0, 0))
	local b = cframe:VectorToWorldSpace(Vector3.new(0, size.Y / 2, 0))
	local c = cframe:VectorToWorldSpace(Vector3.new(0, 0, size.Z / 2))
	local ex = math.abs(a.X) + math.abs(b.X) + math.abs(c.X)
	local ey = math.abs(a.Y) + math.abs(b.Y) + math.abs(c.Y)
	local ez = math.abs(a.Z) + math.abs(b.Z) + math.abs(c.Z)
	local p = cframe.Position
	return {
		part = part,
		group = nil,
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

local function rectDistance(b: Bounds, x: number, z: number): number
	local dx = math.max(b.minX - x, 0, x - b.maxX)
	local dz = math.max(b.minZ - z, 0, z - b.maxZ)
	return math.sqrt(dx * dx + dz * dz)
end

local function flat(x: number, z: number): number
	return math.sqrt(x * x + z * z)
end

local function where(b: Bounds): string
	return string.format("%s.%s (%.1f, %.1f, %.1f)", b.group.folder, b.group.name, b.x, b.y, b.z)
end

-- Contract: preconditions ---------------------------------------------------------------------

local workspace = services.Workspace
local lighting = services.Lighting

print("BuildEnvironment dry run")
do
	local ok = pcall(run, BUILDER)
	check(
		"refuses to run before BuildGreybox has made Workspace.Map",
		not ok and workspace:FindFirstChild("Map") == nil and #lighting:GetChildren() == 0 and recordings.begun == 0
	)
end

run(GREYBOX)
local map = workspace:FindFirstChild("Map")
assert(map and map:GetAttribute("GreyboxVersion") ~= nil, "BuildGreybox did not produce Workspace.Map")
local greyboxParts = 0
for _, descendant in map:GetDescendants() do
	if descendant:IsA("BasePart") then
		greyboxParts += 1
	end
end

do
	local foreign = roblox.Instance.new("Folder")
	foreign.Name = "Decor"
	local keepsake = roblox.Instance.new("Part")
	keepsake.Name = "HandPlaced"
	keepsake.Parent = foreign
	foreign.Parent = map
	local childrenBefore, recordingsBefore = #map:GetChildren(), recordings.begun
	local ok = pcall(run, BUILDER)
	check(
		"refuses to replace a Decor it did not make, and touches nothing",
		not ok
			and foreign.Parent == map
			and #foreign:GetChildren() == 1
			and #map:GetChildren() == childrenBefore
			and #lighting:GetChildren() == 0
			and recordings.begun == recordingsBefore
	)
	foreign:Destroy()
end

-- Build twice ---------------------------------------------------------------------------------

-- Stand in for the server's clock (Lune has no default for it), so a builder
-- that touches time of day is caught below.
local clockBefore = 9.5
lighting.ClockTime = clockBefore

local function fingerprint(): (number, number)
	local decor = map:FindFirstChild("Decor")
	local count, hash = 0, 0
	for _, descendant in decor:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
			local p, s = descendant.CFrame.Position, descendant.Size
			local value = math.floor(p.X * 100) + math.floor(p.Y * 100) * 7 + math.floor(p.Z * 100) * 13
			value += math.floor((s.X + s.Y * 3 + s.Z * 5) * 100)
			hash = (hash * 31 + value) % 2147483647
		end
	end
	return count, hash
end

local begunBefore, committedBefore = recordings.begun, recordings.committed
run(BUILDER)
local firstCount, firstHash = fingerprint()
run(BUILDER) -- must be safely re-runnable
local secondCount, secondHash = fingerprint()

local decorFolders = 0
for _, child in map:GetChildren() do
	if child.Name == "Decor" then
		decorFolders += 1
	end
end
local decor = map:FindFirstChild("Decor")
check(
	"exactly one Map.Decor with EnvironmentVersion after two runs",
	decorFolders == 1 and decor ~= nil and decor:GetAttribute("EnvironmentVersion") == 1,
	`{decorFolders} Decor folders`
)
check(
	"two runs produce the same layout (deterministic)",
	firstCount == secondCount and firstHash == secondHash,
	`{firstCount} parts / hash {firstHash} then {secondCount} parts / hash {secondHash}`
)
check(
	"each run opened one ChangeHistoryService recording and committed it",
	recordings.begun - begunBefore == 2 and recordings.committed - committedBefore == 2,
	`{recordings.begun - begunBefore} begun, {recordings.committed - committedBefore} committed`
)

local greyboxAfter = 0
for _, descendant in map:GetDescendants() do
	if descendant:IsA("BasePart") and not descendant:IsDescendantOf(decor) then
		greyboxAfter += 1
	end
end
check("the greybox map itself is untouched", greyboxAfter == greyboxParts, `{greyboxParts} -> {greyboxAfter}`)

-- Read the greybox (the same way the game would see it) -------------------------------------------

local STEP = 2
local EXTENT = 244
local COUNT = EXTENT * 2 / STEP
local TILES = { "Grass", "Sand", "PondRim", "Boardwalk", "Water" }
local grid: { [string]: { boolean } } = {}
for _, name in TILES do
	grid[name] = table.create(COUNT * COUNT, false)
end

local function cellOf(x: number, z: number): (number, number)
	return math.floor((x + EXTENT) / STEP) + 1, math.floor((z + EXTENT) / STEP) + 1
end

local waterSurface = -1.2
for _, tile in map:FindFirstChild("Terrain"):GetChildren() do
	local layer = grid[tile.Name]
	if layer and tile:IsA("BasePart") then
		local position, size = tile.CFrame.Position, tile.Size
		local i0, j0 = cellOf(position.X - size.X / 2 + 0.01, position.Z - size.Z / 2 + 0.01)
		local i1, j1 = cellOf(position.X + size.X / 2 - 0.01, position.Z + size.Z / 2 - 0.01)
		for j = math.max(j0, 1), math.min(j1, COUNT) do
			for i = math.max(i0, 1), math.min(i1, COUNT) do
				layer[(j - 1) * COUNT + i] = true
			end
		end
		if tile.Name == "Water" then
			waterSurface = position.Y + size.Y / 2
		end
	end
end

local function tileAt(name: string, i: number, j: number): boolean
	if i < 1 or i > COUNT or j < 1 or j > COUNT then
		return false
	end
	return grid[name][(j - 1) * COUNT + i]
end

local function tileAtPoint(name: string, x: number, z: number): boolean
	local i, j = cellOf(x, z)
	return tileAt(name, i, j)
end

-- Calls visit(i, j) for every grid cell under the rectangle.
local function eachCell(minX: number, maxX: number, minZ: number, maxZ: number, visit: (number, number) -> ())
	local i0, j0 = cellOf(minX + 1e-6, minZ + 1e-6)
	local i1, j1 = cellOf(maxX - 1e-6, maxZ - 1e-6)
	for j = j0, j1 do
		for i = i0, i1 do
			visit(i, j)
		end
	end
end

local abyssBounds = boundsOf(map.Abyss.Water)
local abyssX, abyssZ, abyssSurface = abyssBounds.x, abyssBounds.z, abyssBounds.maxY

local clearCircles: { { any } } = {} -- { label, x, z }
local clearLanes: { { any } } = {} -- { label, ax, az, bx, bz }
local pondCenters: { { any } } = {}
local stalls: { any } = {} -- greybox props decor must not stand inside

local function keepClear(label: string, part)
	local p = part.CFrame.Position
	table.insert(clearCircles, { label, p.X, p.Z })
end

local vendorPrompts: { [string]: any } = {}
for _, vendor in map.Vendors:GetChildren() do
	local prompt = vendor:FindFirstChild("Prompt")
	vendorPrompts[vendor.Name] = prompt.CFrame.Position
	keepClear(vendor.Name .. " prompt", prompt)
	for _, child in vendor:GetChildren() do
		if child:IsA("BasePart") and child ~= prompt then
			table.insert(stalls, child)
		end
	end
end
for _, child in map.Hub:GetChildren() do
	if child:IsA("SpawnLocation") then
		keepClear("hub spawn pad", child)
	end
end
for _, point in map.TravelPoints:GetChildren() do
	keepClear("travel point " .. point.Name, point)
end
for _, pond in map.Ponds:GetChildren() do
	local center = pond.Water.CFrame.Position
	table.insert(pondCenters, { pond.Name, center.X, center.Z })
	for _, child in pond:GetChildren() do
		if child:IsA("BasePart") then
			if
				child.Name == "Spawn"
				or child.Name == "FeedNode"
				or child.Name == "Sign"
				or child.Name == "GatePost"
			then
				keepClear(`{pond.Name} {child.Name}`, child)
			end
			if child.Name == "FeedNode" or child.Name == "GatePost" then
				table.insert(stalls, child)
			end
		end
	end
	local spawn = pond.Spawn.CFrame.Position
	table.insert(clearLanes, { pond.Name .. " spawn lane", spawn.X, spawn.Z, center.X, center.Z })
end

local cliffTops = {}
local cliffRock = {}
local highestCliff = 0
for _, child in map.Cliffs:GetChildren() do
	if child.Name == "CliffTop" then
		table.insert(cliffTops, child)
		highestCliff = math.max(highestCliff, child.CFrame.Position.Y + child.Size.Y / 2)
	elseif child.Name == "Cliff" or child.Name == "CliffLedge" then
		table.insert(cliffRock, child)
	end
end

local function cliffTopAt(x: number, z: number): number?
	local best: number? = nil
	for _, top in cliffTops do
		local offset = top.CFrame:PointToObjectSpace(Vector3.new(x, top.CFrame.Position.Y, z))
		if math.abs(offset.X) <= top.Size.X / 2 and math.abs(offset.Z) <= top.Size.Z / 2 then
			local height = top.CFrame.Position.Y + top.Size.Y / 2
			if not best or height > best then
				best = height
			end
		end
	end
	return best
end

local function insideBox(box, point, slack: number): boolean
	local offset = box.CFrame:PointToObjectSpace(point)
	return math.abs(offset.X) <= box.Size.X / 2 + slack
		and math.abs(offset.Y) <= box.Size.Y / 2 + slack
		and math.abs(offset.Z) <= box.Size.Z / 2 + slack
end

-- Gather the decor ----------------------------------------------------------------------------

type Group = {
	instance: any,
	name: string,
	folder: string,
	parts: { Bounds },
	bottom: number,
	top: number,
	lowest: Bounds,
	classes: { [string]: boolean },
}

local groups: { Group } = {}
local allParts: { Bounds } = {}
local structure = offenders()
local folderNames = {}

for _, folder in decor:GetChildren() do
	if folder.ClassName ~= "Folder" then
		structure.add(`{folder.Name} is a {folder.ClassName}`)
		continue
	end
	table.insert(folderNames, folder.Name)
	for _, child in folder:GetChildren() do
		local parts = {}
		if child:IsA("BasePart") then
			table.insert(parts, child)
		elseif child.ClassName == "Model" then
			for _, descendant in child:GetDescendants() do
				if descendant:IsA("BasePart") then
					table.insert(parts, descendant)
				end
			end
		end
		if #parts == 0 then
			structure.add(`{folder.Name}.{child.Name} ({child.ClassName}) holds no parts`)
			continue
		end
		local group: Group = {
			instance = child,
			name = child.Name,
			folder = folder.Name,
			parts = {},
			bottom = math.huge,
			top = -math.huge,
			lowest = nil :: any,
			classes = {},
		}
		for _, part in parts do
			local bounds = boundsOf(part)
			bounds.group = group
			table.insert(group.parts, bounds)
			table.insert(allParts, bounds)
			if bounds.minY < group.bottom then
				group.bottom = bounds.minY
				group.lowest = bounds
			end
			group.top = math.max(group.top, bounds.maxY)
		end
		table.insert(groups, group)
	end
end
table.sort(folderNames)
check(
	`Decor is folders of props ({table.concat(folderNames, ", ")})`,
	structure.none() and #folderNames >= 8,
	structure.detail()
)

-- Budgets and part hygiene -----------------------------------------------------------------------

local lights, animated = {}, {}
local scripts, humanoids = 0, 0
for _, descendant in decor:GetDescendants() do
	if descendant:IsA("Light") then
		table.insert(lights, descendant)
	end
	if descendant:IsA("LuaSourceContainer") then
		scripts += 1
	end
	if descendant.ClassName == "Humanoid" then
		humanoids += 1
	end
	for _, attribute in AMBIENT do
		if descendant:GetAttribute(attribute) ~= nil then
			table.insert(animated, descendant)
			break
		end
	end
end

check(`part budget: {#allParts} of {BUDGET.parts} BaseParts`, #allParts <= BUDGET.parts and #allParts == secondCount)
check(`light budget: {#lights} of {BUDGET.lights} lights`, #lights <= BUDGET.lights)
check(`animation budget: {#animated} of {BUDGET.animated} animated instances`, #animated <= BUDGET.animated)
check(
	"creates no scripts and no Humanoids",
	scripts == 0 and humanoids == 0,
	`{scripts} scripts, {humanoids} humanoids`
)

do
	local unanchored, material, surface, touch = offenders(), offenders(), offenders(), offenders()
	for _, b in allParts do
		local part = b.part
		if not part.Anchored then
			unanchored.add(where(b))
		end
		if part.Material ~= roblox.Enum.Material.SmoothPlastic and part.Material ~= roblox.Enum.Material.Neon then
			material.add(where(b))
		end
		if
			part.TopSurface ~= roblox.Enum.SurfaceType.Smooth
			or part.BottomSurface ~= roblox.Enum.SurfaceType.Smooth
		then
			surface.add(where(b))
		end
		if not part.CanCollide and part.CanQuery then
			touch.add(where(b))
		end
	end
	check("every decor part is anchored", unanchored.none(), unanchored.detail())
	check("every decor part is SmoothPlastic or Neon", material.none(), material.detail())
	check("every decor part has smooth surfaces", surface.none(), surface.detail())
	check("non-colliding decor is also invisible to raycasts (CanQuery off)", touch.none(), touch.detail())
end

-- Placement rules a-e ------------------------------------------------------------------------------

local MARKET_FOLDERS = { Hub = true, Npcs = true, Market = true, Lights = true }

local function classify(b: Bounds): string
	if flat(b.x - abyssX, b.z - abyssZ) < ABYSS_HOLE then
		return "abyss"
	elseif tileAtPoint("Water", b.x, b.z) and not tileAtPoint("Boardwalk", b.x, b.z) then
		return "water"
	end
	return "ground"
end

do
	local ruleA, ruleB, ruleC, ruleD, ruleE = offenders(), offenders(), offenders(), offenders(), offenders()
	local floorParts = 0
	for _, b in allParts do
		-- e. Tall things near ponds (any height: a floating canopy hides a pond too).
		if b.maxY > POND_VIEW_HEIGHT then
			for _, pond in pondCenters do
				if rectDistance(b, pond[2], pond[3]) < POND_VIEW_RADIUS then
					ruleE.add(`{where(b)} rises to {string.format("%.1f", b.maxY)} near {pond[1]}`)
				end
			end
		end

		if b.minY > FLOOR_Y or flat(b.x, b.z) >= FLOOR_RADIUS then
			continue
		end
		floorParts += 1
		local class = classify(b)
		b.group.classes[class] = true

		if class == "ground" then
			-- a. Stands on grass (market props may stand on sand), clear of everything else.
			local onGrass = tileAtPoint("Grass", b.x, b.z)
			local onSand = tileAtPoint("Sand", b.x, b.z) and MARKET_FOLDERS[b.group.folder] == true
			if not (onGrass or onSand) then
				ruleA.add(`{where(b)} is not over grass`)
			else
				local bad: string? = nil
				eachCell(
					b.minX - FOOT_MARGIN,
					b.maxX + FOOT_MARGIN,
					b.minZ - FOOT_MARGIN,
					b.maxZ + FOOT_MARGIN,
					function(i, j)
						if tileAt("Boardwalk", i, j) then
							bad = "a boardwalk"
						elseif tileAt("PondRim", i, j) then
							bad = "a pond rim"
						elseif tileAt("Water", i, j) then
							bad = "water"
						elseif not tileAt("Grass", i, j) and not tileAt("Sand", i, j) then
							bad = "a hole"
						end
					end
				)
				if bad then
					ruleA.add(`{where(b)} overlaps {bad}`)
				end
			end
		elseif class == "water" then
			-- b. Entirely over open river / lagoon water.
			local bad = false
			eachCell(b.minX, b.maxX, b.minZ, b.maxZ, function(i, j)
				if not tileAt("Water", i, j) or tileAt("Boardwalk", i, j) then
					bad = true
				end
			end)
			if bad then
				ruleB.add(`{where(b)} is not wholly over open water`)
			end
		else
			-- b. Inside the Abyss: within reach of the middle of its water.
			local dx = math.max(math.abs(b.minX - abyssX), math.abs(b.maxX - abyssX))
			local dz = math.max(math.abs(b.minZ - abyssZ), math.abs(b.maxZ - abyssZ))
			if flat(dx, dz) > ABYSS_PROP_RADIUS then
				ruleB.add(`{where(b)} is {string.format("%.1f", flat(dx, dz))} from the Abyss centre`)
			end
		end

		-- c. Keep-clear circles and pond spawn lanes.
		for _, circle in clearCircles do
			if rectDistance(b, circle[2], circle[3]) < CLEAR_RADIUS then
				ruleC.add(`{where(b)} crowds {circle[1]}`)
			end
		end
		for _, lane in clearLanes do
			local dx, dz = lane[4] - lane[2], lane[5] - lane[3]
			local steps = math.ceil(flat(dx, dz) * 2)
			for step = 0, steps do
				local t = step / steps
				if rectDistance(b, lane[2] + dx * t, lane[3] + dz * t) < LANE_HALF then
					ruleC.add(`{where(b)} blocks {lane[1]}`)
					break
				end
			end
		end

		-- d. The plaza holds only small market props against the vendors on its north side.
		if rectDistance(b, 0, 0) < HUB_RADIUS then
			local group = b.group
			local hug = math.huge
			for _, prompt in vendorPrompts do
				hug = math.min(hug, flat(group.lowest.x - prompt.X, group.lowest.z - prompt.Z))
			end
			if not MARKET_FOLDERS[group.folder] then
				ruleD.add(`{where(b)} is not a market prop`)
			elseif b.maxZ >= MARKET_Z then
				ruleD.add(`{where(b)} reaches south of z = {MARKET_Z}`)
			elseif b.maxX - b.minX > MARKET_PROP_SIZE or b.maxZ - b.minZ > MARKET_PROP_SIZE then
				ruleD.add(`{where(b)} is too big for the plaza`)
			elseif group.top > MARKET_PROP_HEIGHT then
				ruleD.add(`{where(b)} is too tall for the plaza`)
			elseif hug > VENDOR_HUG then
				ruleD.add(`{where(b)} is {string.format("%.1f", hug)} from the nearest vendor`)
			end
		end
	end

	-- b (height) and the resting rules, per prop.
	local waterline, restLand, grounded = offenders(), offenders(), offenders()
	local landProps, waterProps, abyssProps = 0, 0, 0
	for _, group in groups do
		local classes = group.classes
		local kinds = (if classes.ground then 1 else 0)
			+ (if classes.water then 1 else 0)
			+ (if classes.abyss then 1 else 0)
		if kinds > 1 then
			ruleB.add(`{where(group.lowest)} straddles land and water`)
		elseif classes.water then
			waterProps += 1
			if math.abs(group.bottom - waterSurface) > 1 then
				waterline.add(`{where(group.lowest)} bottom {string.format("%.2f", group.bottom)}`)
			end
		elseif classes.abyss then
			abyssProps += 1
			if math.abs(group.bottom - abyssSurface) > 1.5 then
				waterline.add(`{where(group.lowest)} bottom {string.format("%.2f", group.bottom)}`)
			end
		elseif classes.ground then
			if group.folder ~= "CliffFaces" and group.folder ~= "Wildlife" then
				landProps += 1
				if math.abs(group.bottom) > 0.6 then
					restLand.add(`{where(group.lowest)} bottom {string.format("%.2f", group.bottom)}`)
				end
			end
		elseif group.folder ~= "CliffTops" and group.folder ~= "CliffFaces" and group.folder ~= "Wildlife" then
			grounded.add(`{where(group.lowest)} is not on the basin floor`)
		end
	end

	check(
		`a. ground props stand on grass, clear of paths, rims, water and holes ({floorParts} floor parts)`,
		ruleA.none(),
		ruleA.detail()
	)
	check(
		`b. water props float on open water ({waterProps} on river/lagoon, {abyssProps} in the Abyss)`,
		ruleB.none() and waterProps > 0 and abyssProps > 0,
		ruleB.detail()
	)
	check(
		`b. water props sit at the surface (river y = {string.format("%.1f", waterSurface)}, Abyss y = {string.format(
			"%.1f",
			abyssSurface
		)})`,
		waterline.none(),
		waterline.detail()
	)
	check(
		`c. prompts, spawns, travel points, gates and pond spawn lanes are clear ({#clearCircles} circles, {#clearLanes} lanes)`,
		ruleC.none(),
		ruleC.detail()
	)
	check(
		"d. the hub plaza holds only small market props by the vendors, north of z = -14",
		ruleD.none(),
		ruleD.detail()
	)
	check("e. nothing taller than 9 studs within 34 studs of a pond centre", ruleE.none(), ruleE.detail())
	check(`land decor rests on y = 0 ({landProps} props)`, restLand.none() and landProps > 0, restLand.detail())
	check("every prop outside the cliffs and the sky is on the floor or the water", grounded.none(), grounded.detail())
end

do
	-- Decor may not stand inside a vendor stall, a gate post or a feed pedestal.
	local inside = offenders()
	for _, b in allParts do
		for _, stall in stalls do
			local s = boundsOf(stall)
			if b.minY < s.maxY and b.maxY > s.minY and rectDistance(b, s.x, s.z) < 12 then
				for step = 0, 24 do
					local x = b.minX + (b.maxX - b.minX) * (step % 5) / 4
					local z = b.minZ + (b.maxZ - b.minZ) * math.floor(step / 5) / 4
					if insideBox(stall, Vector3.new(x, s.y, z), 0) then
						inside.add(`{where(b)} is inside {stall.Parent.Name}.{stall.Name}`)
						break
					end
				end
			end
		end
	end
	check("no decor stands inside a vendor stall, gate post or feed node", inside.none(), inside.detail())
end

-- Cliffs ----------------------------------------------------------------------------------------

do
	local resting, collide = offenders(), offenders()
	local trees, props = 0, 0
	local quadrants = { 0, 0, 0, 0 }
	for _, group in groups do
		if group.folder ~= "CliffTops" then
			continue
		end
		props += 1
		local lowest = group.lowest
		local foot = lowest.part.CFrame * Vector3.new(0, -lowest.part.Size.Y / 2, 0)
		-- Every part that touches the ground (trunk, each rock of a cluster) must stand on
		-- the cliff top beneath it; the segments step, so a neighbour's height will not do.
		for _, b in group.parts do
			if b.minY <= group.bottom + 1 then
				local under = b.part.CFrame * Vector3.new(0, -b.part.Size.Y / 2, 0)
				local top = cliffTopAt(under.X, under.Z)
				if not top then
					resting.add(`{where(b)} is not over a cliff top`)
				elseif math.abs(b.minY - top) > 0.6 then
					resting.add(`{where(b)} bottom {string.format("%.2f", b.minY)} vs top {top}`)
				end
			end
		end
		for _, b in group.parts do
			if b.part.CanCollide or b.part.CanQuery then
				collide.add(where(b))
			end
		end
		if string.sub(group.name, 1, 4) == "Pine" then
			trees += 1
			local quadrant = (if foot.X >= 0 then 1 else 2) + (if foot.Z >= 0 then 0 else 2)
			quadrants[quadrant] += 1
		end
	end
	check(`cliff-top decor rests on its cliff top ({props} props)`, resting.none() and props > 0, resting.detail())
	check(`at least 100 cliff-top trees ({trees})`, trees >= 100)
	check(
		`cliff-top trees in all four quadrants (SE {quadrants[1]}, SW {quadrants[2]}, NE {quadrants[3]}, NW {quadrants[4]})`,
		quadrants[1] > 0 and quadrants[2] > 0 and quadrants[3] > 0 and quadrants[4] > 0
	)

	local attached = offenders()
	local faces = 0
	for _, group in groups do
		if group.folder ~= "CliffFaces" then
			continue
		end
		faces += 1
		local touching = false
		for _, b in group.parts do
			local part = b.part
			for step = 0, 26 do
				local point = part.CFrame
					* Vector3.new(
						(step % 3 - 1) * part.Size.X / 2,
						(math.floor(step / 3) % 3 - 1) * part.Size.Y / 2,
						(math.floor(step / 9) - 1) * part.Size.Z / 2
					)
				for _, rock in cliffRock do
					if insideBox(rock, point, 0.05) then
						touching = true
						break
					end
				end
				if touching then
					break
				end
			end
			if touching then
				break
			end
		end
		if not touching then
			attached.add(`{where(group.lowest)} floats free of the cliff`)
		elseif group.bottom < 6 or group.top > highestCliff then
			attached.add(`{where(group.lowest)} spans y {group.bottom}..{group.top}`)
		end
		for _, b in group.parts do
			if b.part.CanCollide or b.part.CanQuery then
				collide.add(where(b))
			end
		end
	end
	check(
		`cliff-face decor is attached to the wall between y = 6 and the rim ({faces} props)`,
		attached.none() and faces >= 24,
		attached.detail()
	)

	for _, group in groups do
		if group.classes.water or group.classes.abyss then
			for _, b in group.parts do
				if b.part.CanCollide or b.part.CanQuery then
					collide.add(where(b))
				end
			end
		end
	end
	for _, b in allParts do
		local name = b.part.Name
		if (name == "Needles" or name == "Leaves" or name == "LeavesTop") and b.part.CanCollide then
			collide.add(where(b))
		end
	end
	check("cliff, water and Abyss decor and all foliage is non-colliding", collide.none(), collide.detail())

	local corridor = offenders()
	for _, b in allParts do
		if b.minZ < FALLS.z and b.maxX > -FALLS.halfX and b.minX < FALLS.halfX then
			corridor.add(where(b))
		end
	end
	check("the Falls corridor (x -22..22, z < -200) is clear", corridor.none(), corridor.detail())
end

-- NPCs --------------------------------------------------------------------------------------------

do
	local npcs = decor:FindFirstChild("Npcs")
	for name, vendorName in NPCS do
		local npc = npcs and npcs:FindFirstChild(name)
		local problems = {}
		if not npc or npc.ClassName ~= "Model" then
			table.insert(problems, "missing")
		else
			local count = 0
			for _, descendant in npc:GetDescendants() do
				if descendant:IsA("BasePart") then
					count += 1
				end
			end
			if count < 6 or count > 10 then
				table.insert(problems, `{count} parts`)
			end
			local root = npc.PrimaryPart
			if not root then
				table.insert(problems, "no PrimaryPart")
			else
				local at = root.CFrame.Position
				local prompt = vendorPrompts[vendorName]
				local gap = flat(at.X - prompt.X, at.Z - prompt.Z)
				if gap > VENDOR_HUG then
					table.insert(problems, string.format("%.1f studs from its vendor", gap))
				end
				local toCentre = Vector3.new(-at.X, 0, -at.Z).Unit
				if root.CFrame.LookVector:Dot(toCentre) < 0.95 then
					table.insert(problems, "not facing the plaza centre")
				end
			end
		end
		check(
			`NPC {name} stands by {vendorName}, 6-10 parts, facing the plaza`,
			#problems == 0,
			table.concat(problems, ", ")
		)
	end
end

-- Ambient animation contract -------------------------------------------------------------------------

do
	local problems = offenders()
	local orbiting, bobbing, swaying = 0, 0, 0
	for _, instance in animated do
		local label = `{instance.Parent.Name}.{instance.Name}`
		local pivot
		if instance.ClassName == "Model" then
			local count = 0
			for _, descendant in instance:GetDescendants() do
				if descendant:IsA("BasePart") then
					count += 1
				end
			end
			if not instance.PrimaryPart or not instance.PrimaryPart:IsDescendantOf(instance) then
				problems.add(label .. " has no PrimaryPart")
			else
				pivot = instance.PrimaryPart.CFrame
			end
			if count > 20 then
				problems.add(`{label} has {count} parts`)
			end
		elseif instance:IsA("BasePart") then
			pivot = instance.CFrame
		else
			problems.add(`{label} is a {instance.ClassName}`)
		end
		for _, attribute in { "AmbientBob", "AmbientSway", "AmbientOrbit", "AmbientPeriod" } do
			local value = instance:GetAttribute(attribute)
			if value ~= nil and (type(value) ~= "number" or value <= 0) then
				problems.add(`{label}.{attribute} = {value}`)
			end
		end
		local ancestor = instance.Parent
		while ancestor and ancestor ~= decor do
			if table.find(animated, ancestor) then
				problems.add(label .. " is nested inside another animated instance")
			end
			ancestor = ancestor.Parent
		end
		local orbit, bob = instance:GetAttribute("AmbientOrbit"), instance:GetAttribute("AmbientBob")
		if orbit then
			orbiting += 1
			if pivot then
				local height = pivot.Position.Y
				local reach = flat(pivot.Position.X, pivot.Position.Z) + orbit
				if orbit < 15 or orbit > 40 or height < 60 or height > 110 or reach > FLOOR_RADIUS - 10 then
					problems.add(`{label} orbits {orbit} studs at y {height}`)
				end
				-- The client turns the pivot to face travel: the pivot must not be pre-tilted.
				if math.abs(pivot.UpVector.Y - 1) > 1e-3 then
					problems.add(label .. " has a tilted pivot")
				end
			end
		end
		if bob then
			bobbing += 1
			if bob > 0.6 then
				problems.add(`{label} bobs {bob} studs`)
			end
		end
		if instance:GetAttribute("AmbientSway") then
			swaying += 1
		end
	end
	check(
		`animated instances honour the Ambient contract ({bobbing} bob, {swaying} sway, {orbiting} orbit)`,
		problems.none() and bobbing > 0 and swaying > 0 and orbiting > 0,
		problems.detail()
	)

	-- Wildlife: every bird either flies (orbit) or sits on top of something.
	local birds = offenders()
	local flying, perched = 0, 0
	for _, group in groups do
		if group.folder ~= "Wildlife" then
			continue
		end
		if #group.parts < 3 or #group.parts > 5 then
			birds.add(`{where(group.lowest)} has {#group.parts} parts`)
		end
		if group.instance:GetAttribute("AmbientOrbit") then
			flying += 1
		else
			local seat = false
			for _, b in allParts do
				if
					b.group.folder ~= "Wildlife"
					and math.abs(b.maxY - group.bottom) <= 0.5
					and rectDistance(b, group.lowest.x, group.lowest.z) == 0
				then
					seat = true
					break
				end
			end
			if seat then
				perched += 1
			else
				birds.add(`{where(group.lowest)} perches on nothing`)
			end
		end
	end
	local total = flying + perched
	check(
		`5-7 birds, some perched and some flying ({perched} perched, {flying} flying)`,
		birds.none() and total >= 5 and total <= 7 and flying > 0 and perched > 0,
		birds.detail()
	)

	local dark = offenders()
	for _, light in lights do
		if light:GetAttribute("NightLight") ~= true then
			dark.add(`{light.Parent.Parent.Name}.{light.Parent.Name}`)
		end
	end
	check(`every light is tagged NightLight ({#lights} lights)`, dark.none() and #lights > 0, dark.detail())
end

-- Lighting mood ---------------------------------------------------------------------------------------

do
	local counts = {}
	for _, child in lighting:GetChildren() do
		counts[child.ClassName] = (counts[child.ClassName] or 0) + 1
	end
	local summary = {}
	local exact = true
	for _, className in EFFECTS do
		table.insert(summary, `{className} x{counts[className] or 0}`)
		exact = exact and counts[className] == 1
	end
	check("Lighting has exactly one of each mood effect after two runs", exact, table.concat(summary, ", "))
	check("ClockTime is left to the server", lighting.ClockTime == clockBefore, tostring(lighting.ClockTime))
end

-- Inventory (for the report) ----------------------------------------------------------------------------

do
	print("\n  Props by folder:")
	local byFolder: { [string]: { [string]: number } } = {}
	local partsByFolder: { [string]: number } = {}
	for _, group in groups do
		byFolder[group.folder] = byFolder[group.folder] or {}
		byFolder[group.folder][group.name] = (byFolder[group.folder][group.name] or 0) + 1
		partsByFolder[group.folder] = (partsByFolder[group.folder] or 0) + #group.parts
	end
	for _, folder in folderNames do
		local names = {}
		for name in byFolder[folder] or {} do
			table.insert(names, name)
		end
		table.sort(names)
		local items = {}
		for _, name in names do
			table.insert(items, `{name} x{byFolder[folder][name]}`)
		end
		print(string.format("    %-10s %4d parts  %s", folder, partsByFolder[folder] or 0, table.concat(items, ", ")))
	end

	print("\n  Animated instances:")
	local lines: { [string]: number } = {}
	local order = {}
	for _, instance in animated do
		local traits = {}
		for _, attribute in AMBIENT do
			if instance:GetAttribute(attribute) ~= nil then
				table.insert(traits, attribute)
			end
		end
		local key = `{instance.Parent.Name}.{instance.Name} ({table.concat(traits, " + ")})`
		if not lines[key] then
			lines[key] = 0
			table.insert(order, key)
		end
		lines[key] += 1
	end
	table.sort(order)
	for _, key in order do
		print(`    {key} x{lines[key]}`)
	end
end

print(if failures == 0 then "\nBuildEnvironment passed the dry run." else `\n{failures} dry-run check(s) FAILED.`)
if failures > 0 then
	error("dry run failed")
end
