-- Headless dry run of the Studio build scripts, using Lune's Roblox instance
-- implementation. Catches script errors and checks the contract the game code
-- relies on, without touching a real place.
--
--   lune run tools/studio/dryrun.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox") :: any

local game = roblox.Instance.new("DataModel")
local services = {
	Workspace = game:GetService("Workspace"),
	ReplicatedStorage = game:GetService("ReplicatedStorage"),
	ChangeHistoryService = {
		TryBeginRecording = function()
			return nil
		end,
		FinishRecording = function() end,
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

-- Greybox -----------------------------------------------------------------------------
run("tools/studio/BuildGreybox.luau")
run("tools/studio/BuildGreybox.luau") -- must be safely re-runnable

local map = services.Workspace:FindFirstChild("Map")
check("Workspace.Map exists exactly once", map ~= nil and #services.Workspace:GetChildren() == 1)
local ponds = map.Ponds:GetChildren()
check("6 pond plots", #ponds == 6, tostring(#ponds))
local hubSpread = true
for _, pond in ponds do
	local water = pond:FindFirstChild("Water")
	local label = pond:FindFirstChild("OwnerLabel", true)
	local blessPrompt = false
	for _, descendant in pond:GetDescendants() do
		if descendant.ClassName == "ProximityPrompt" and descendant:GetAttribute("Action") == "Bless" then
			blessPrompt = true
		end
	end
	check(
		`{pond.Name}: Plot attr, Water volume, OwnerLabel, Bless prompt`,
		type(pond:GetAttribute("Plot")) == "number" and water ~= nil and label ~= nil and blessPrompt
	)
	local radius = (water.CFrame.Position * roblox.Vector3.new(1, 0, 1)).Magnitude
	hubSpread = hubSpread and math.abs(radius - 158) < 0.5
end
check("ponds sit 158 studs from the hub", hubSpread)

local biomes = {}
for _, zone in map.FishingZones:GetChildren() do
	biomes[zone:GetAttribute("Biome")] = true
end
check("fishing zones cover Freshwater and Saltwater", biomes.Freshwater == true and biomes.Saltwater == true)

local panels = {}
for _, descendant in map.Vendors:GetDescendants() do
	if descendant.ClassName == "ProximityPrompt" then
		panels[descendant:GetAttribute("OpenPanel")] = true
	end
end
check("3 vendors open the Shop / Baits / Backpack panels", panels.Shop and panels.Baits and panels.Backpack)

local points = map.TravelPoints
check(
	"travel points Hub / Freshwater / Saltwater exist",
	points:FindFirstChild("Hub") ~= nil
		and points:FindFirstChild("Freshwater") ~= nil
		and points:FindFirstChild("Saltwater") ~= nil
)
local spawns = 0
for _, pond in ponds do
	if pond:FindFirstChild("Spawn") then
		spawns += 1
	end
end
check("every pond has a Spawn arrival marker", spawns == 6, tostring(spawns))

-- Layout v3 "The Basin": solid ground, one real drop (the Abyss), everything reachable ------
do
	-- Same numbers as BuildGreybox.luau.
	local ABYSS_X, ABYSS_Z, ABYSS_RAIL = 0, 115, 53.5
	local BASIN_RADIUS = 236
	local STEP = 2 -- walkability grid resolution
	local EXTENT = 240
	local COUNT = EXTENT * 2 / STEP

	local function cellOf(x: number, z: number): (number, number)
		return math.floor((x + EXTENT) / STEP) + 1, math.floor((z + EXTENT) / STEP) + 1
	end

	-- 1. The Abyss is completely ringed by a barrier.
	local barriers = {}
	for _, descendant in map:GetDescendants() do
		if descendant.Name == "Barrier" then
			table.insert(barriers, descendant)
		end
	end
	local function behindBarrier(x: number, z: number): boolean
		local point = roblox.Vector3.new(x, 2, z)
		for _, barrier in barriers do
			local localPoint = barrier.CFrame:PointToObjectSpace(point)
			if
				math.abs(localPoint.X) <= barrier.Size.X / 2 + 1
				and math.abs(localPoint.Z) <= barrier.Size.Z / 2 + 1
			then
				return true
			end
		end
		return false
	end
	local ringGaps = 0
	for step = 0, 1439 do
		local a = math.rad(step / 4)
		if not behindBarrier(ABYSS_X + math.cos(a) * ABYSS_RAIL, ABYSS_Z + math.sin(a) * ABYSS_RAIL) then
			ringGaps += 1
		end
	end
	check(`the Abyss is fully ringed by a barrier ({#barriers} barrier pieces)`, ringGaps == 0, `{ringGaps} gaps`)

	-- 2. Walkability: rasterise every flat, solid surface at ground level.
	local walkable: { { boolean } } = {}
	local blocked: { { boolean } } = {}
	for j = 1, COUNT do
		walkable[j] = table.create(COUNT, false)
		blocked[j] = table.create(COUNT, false)
	end
	local SURFACES = { Grass = true, Sand = true, PondRim = true, Boardwalk = true, Cover = true }
	for _, descendant in map:GetDescendants() do
		if descendant:IsA("BasePart") and SURFACES[descendant.Name] and descendant.CanCollide then
			local position, size = descendant.CFrame.Position, descendant.Size
			local i0, j0 = cellOf(position.X - size.X / 2 + 0.01, position.Z - size.Z / 2 + 0.01)
			local i1, j1 = cellOf(position.X + size.X / 2 - 0.01, position.Z + size.Z / 2 - 0.01)
			for j = math.max(j0, 1), math.min(j1, COUNT) do
				for i = math.max(i0, 1), math.min(i1, COUNT) do
					walkable[j][i] = true
				end
			end
		end
	end
	-- Barriers block movement; mark every cell they pass through.
	for _, barrier in barriers do
		local half = barrier.Size.Z / 2
		local t = -half
		while t <= half do
			local world = barrier.CFrame * roblox.Vector3.new(0, 0, t)
			for dx = -1, 1 do
				for dz = -1, 1 do
					local i, j = cellOf(world.X + dx, world.Z + dz)
					if i >= 1 and i <= COUNT and j >= 1 and j <= COUNT then
						blocked[j][i] = true
					end
				end
			end
			t += 1
		end
	end

	-- Flood fill from the hub spawn over walkable, unblocked cells (no swimming, no jumping).
	local reached: { { boolean } } = {}
	for j = 1, COUNT do
		reached[j] = table.create(COUNT, false)
	end
	local startI, startJ = cellOf(0, 10)
	local queue = { { startI, startJ } }
	reached[startJ][startI] = true
	local head = 1
	local reachedCount, insideRail = 0, 0
	while head <= #queue do
		local i, j = queue[head][1], queue[head][2]
		head += 1
		reachedCount += 1
		local x, z = -EXTENT + (i - 0.5) * STEP, -EXTENT + (j - 0.5) * STEP
		if math.sqrt((x - ABYSS_X) ^ 2 + (z - ABYSS_Z) ^ 2) < ABYSS_RAIL - 2 then
			insideRail += 1
		end
		for _, offset in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local ni, nj = i + offset[1], j + offset[2]
			if ni >= 1 and ni <= COUNT and nj >= 1 and nj <= COUNT then
				if walkable[nj][ni] and not blocked[nj][ni] and not reached[nj][ni] then
					reached[nj][ni] = true
					table.insert(queue, { ni, nj })
				end
			end
		end
	end
	check("no walkable ground is reachable inside the Abyss railing", insideRail == 0, `{insideRail} cells`)

	local function canReach(position): boolean
		local i, j = cellOf(position.X, position.Z)
		return i >= 1 and i <= COUNT and j >= 1 and j <= COUNT and reached[j][i]
	end
	local unreachable: { string } = {}
	for _, pond in ponds do
		if not canReach(pond.Spawn.CFrame.Position) then
			table.insert(unreachable, pond.Name .. " spawn")
		end
		if
			not canReach(pond.FeedNode.CFrame.Position + roblox.Vector3.new(0, 0, 0))
			and not canReach(pond.Spawn.CFrame.Position)
		then
			table.insert(unreachable, pond.Name .. " feed node")
		end
	end
	for _, point in map.TravelPoints:GetChildren() do
		if not canReach(point.CFrame.Position) then
			table.insert(unreachable, "travel point " .. point.Name)
		end
	end
	for _, vendorModel in map.Vendors:GetChildren() do
		if not canReach(vendorModel.Prompt.CFrame.Position) then
			table.insert(unreachable, vendorModel.Name)
		end
	end
	check(
		`every pond, vendor and travel point can be walked to from the hub on dry ground ({reachedCount} cells reachable)`,
		#unreachable == 0,
		table.concat(unreachable, ", ")
	)

	-- 3. Fishing spots: each zone must have fishable (non-colliding, queryable) water nearby.
	local fishable = {}
	for _, descendant in map:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and descendant.Name == "Water"
			and not descendant.CanCollide
			and descendant.CanQuery
		then
			table.insert(fishable, descendant)
		end
	end
	check("there is fishable water for the bobber to land on", #fishable > 10, tostring(#fishable))

	-- 4. The cliff ring closes the basin.
	local cliffParts = {}
	for _, descendant in map.Cliffs:GetChildren() do
		if descendant.Name == "Cliff" then
			table.insert(cliffParts, descendant)
		end
	end
	local open = 0
	for degrees = 0, 359 do
		local a = math.rad(degrees)
		local point = roblox.Vector3.new(math.cos(a) * (BASIN_RADIUS + 8), 10, math.sin(a) * (BASIN_RADIUS + 8))
		local inside = false
		for _, cliff in cliffParts do
			local localPoint = cliff.CFrame:PointToObjectSpace(point)
			if math.abs(localPoint.X) <= cliff.Size.X / 2 and math.abs(localPoint.Z) <= cliff.Size.Z / 2 then
				inside = true
				break
			end
		end
		if not inside then
			open += 1
		end
	end
	check(`cliff walls enclose the whole basin ({#cliffParts} segments)`, open == 0, `{open} degrees open`)
end

local unanchored = 0
for _, descendant in map:GetDescendants() do
	if descendant:IsA("BasePart") and not descendant.Anchored then
		unanchored += 1
	end
end
check("every map part is anchored", unanchored == 0, tostring(unanchored))

-- Abyssal Angler ------------------------------------------------------------------------
run("tools/studio/BuildAbyssalAngler.luau")
run("tools/studio/BuildAbyssalAngler.luau")

local saltwater = services.ReplicatedStorage.Assets.Creatures.Saltwater
check("exactly one AbyssalAngler under Assets/Creatures/Saltwater", #saltwater:GetChildren() == 1)
local angler = saltwater.AbyssalAngler
local root = angler.PrimaryPart
check(
	"PrimaryPart is RootPart with an AuraAttachment",
	root ~= nil and root.Name == "RootPart" and root:FindFirstChild("AuraAttachment") ~= nil
)

local expected = { "Body", "Head", "Jaw", "Tail", "TailFin", "LeftFin", "RightFin", "DorsalFin", "Lure" }
local motors = {}
for _, descendant in angler:GetDescendants() do
	if descendant.ClassName == "Motor6D" then
		motors[descendant.Name] = descendant
	end
end
for _, name in expected do
	local motor = motors[name]
	local bone = angler:FindFirstChild(name)
	local wired = motor ~= nil and bone ~= nil and motor.Part1 == bone and motor.Part0 ~= nil
	-- C0/C1 must describe the same world pivot, or the rig would snap when simulated.
	local aligned = false
	if wired then
		local pivot0 = motor.Part0.CFrame * motor.C0
		local pivot1 = motor.Part1.CFrame * motor.C1
		aligned = (pivot0.Position - pivot1.Position).Magnitude < 1e-3
	end
	check(`Motor6D "{name}" joins a bone part with matching pivots`, wired and aligned)
end

local minZ, maxZ, anchored, colliding = math.huge, -math.huge, 0, 0
for _, descendant in angler:GetDescendants() do
	if descendant:IsA("BasePart") then
		if descendant ~= root then
			minZ = math.min(minZ, descendant.CFrame.Position.Z - descendant.Size.Z / 2)
			maxZ = math.max(maxZ, descendant.CFrame.Position.Z + descendant.Size.Z / 2)
		end
		if descendant.Anchored then
			anchored += 1
		end
		if descendant.CanCollide then
			colliding += 1
		end
	end
end
check("only RootPart is anchored and nothing collides", anchored == 1 and colliding == 0)
print(string.format("  info  angler length %.2f studs (Creatures.luau length = 8.0)", maxZ - minZ))
check("model length matches the configured species length", math.abs((maxZ - minZ) - 8.0) < 0.75)

-- Full roster (BuildCreatures) -------------------------------------------------------------------
run("tools/studio/BuildCreatures.luau")
run("tools/studio/BuildCreatures.luau")

-- Expected species + lengths come straight from the game config.
local configSource = fs.readFile("src/shared/Config/Creatures.luau")
local REQUIRED_BONES = { "Body", "Head", "Tail", "LeftFin", "RightFin", "DorsalFin" }
local rosterCount = 0
for id, biome, lengthText in string.gmatch(configSource, 'id = "(%w+)",.-biome = "(%w+)",.-length = ([%d%.]+)') do
	rosterCount += 1
	local expectedLength = tonumber(lengthText) :: number
	local folder = services.ReplicatedStorage.Assets.Creatures:FindFirstChild(biome)
	local model = folder and folder:FindFirstChild(id)
	if not model then
		check(`{id}: authored model exists under Assets/Creatures/{biome}`, false)
		continue
	end

	local problems = {}
	local modelRoot = model.PrimaryPart
	if not modelRoot or modelRoot.Name ~= "RootPart" or not modelRoot:FindFirstChild("AuraAttachment") then
		table.insert(problems, "RootPart/AuraAttachment")
	end
	local modelMotors = {}
	for _, descendant in model:GetDescendants() do
		if descendant.ClassName == "Motor6D" then
			modelMotors[descendant.Name] = descendant
			local pivot0 = descendant.Part0.CFrame * descendant.C0
			local pivot1 = descendant.Part1.CFrame * descendant.C1
			if (pivot0.Position - pivot1.Position).Magnitude > 1e-3 or descendant.Part1.Name ~= descendant.Name then
				table.insert(problems, "joint " .. descendant.Name)
			end
		end
	end
	for _, bone in REQUIRED_BONES do
		if not model:FindFirstChild(bone) or not modelMotors[bone] then
			table.insert(problems, "missing " .. bone)
		end
	end
	local lo, hi, anchoredParts, collidingParts, partTotal = math.huge, -math.huge, 0, 0, 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			partTotal += 1
			if descendant ~= modelRoot then
				lo = math.min(lo, descendant.CFrame.Position.Z - descendant.Size.Z / 2)
				hi = math.max(hi, descendant.CFrame.Position.Z + descendant.Size.Z / 2)
			end
			anchoredParts += if descendant.Anchored then 1 else 0
			collidingParts += if descendant.CanCollide then 1 else 0
		end
	end
	if anchoredParts ~= 1 or collidingParts ~= 0 then
		table.insert(problems, "anchoring/collision")
	end
	if math.abs((hi - lo) - expectedLength) > expectedLength * 0.1 then
		table.insert(problems, string.format("length %.2f vs config %.2f", hi - lo, expectedLength))
	end
	check(
		string.format("%-19s rig ok (%d parts, %.2f studs long)", id, partTotal, hi - lo),
		#problems == 0,
		table.concat(problems, ", ")
	)
end
check("all 12 species in Creatures.luau have an authored model", rosterCount == 12, tostring(rosterCount))

print(if failures == 0 then "\nBuild scripts passed the dry run." else `\n{failures} dry-run check(s) FAILED.`)
if failures > 0 then
	error("dry run failed")
end
