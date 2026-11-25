-- Headless dry run of tools/studio/BuildGear.luau, using Lune's Roblox instance
-- implementation. Runs the builder twice in a fake DataModel and checks the rod,
-- bait and bobber rig standards the client relies on, without touching a real place.
--
--   lune run tools/studio/dryrun_gear.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local BUILDER = "tools/studio/BuildGear.luau"
local GENERATOR = "BuildGear"
local RARITY_ORDER = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6 }
local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local Instance = roblox.Instance
local Vector3 = roblox.Vector3
local builderSource = fs.readFile(BUILDER)

local failures = 0
local function check(label: string, condition: boolean, detail: string?)
	if not condition then
		failures += 1
	end
	print(`  {if condition then "ok   " else "FAIL "} {label} {if condition then "" else detail or ""}`)
end

-- A fresh fake place; `place.run()` executes the builder in it.
local function newPlace()
	local dataModel = Instance.new("DataModel")
	local place = {
		replicatedStorage = dataModel:GetService("ReplicatedStorage"),
		printed = {} :: { string },
		began = 0,
		finished = 0,
		lastOperation = nil :: any,
	}
	local services = {
		ReplicatedStorage = place.replicatedStorage,
		ChangeHistoryService = {
			TryBeginRecording = function(_, _name: string)
				place.began += 1
				return "recording" .. place.began
			end,
			FinishRecording = function(_, recording: string, operation: any)
				if recording == "recording" .. place.began then
					place.finished += 1
				end
				place.lastOperation = operation
			end,
		},
	}
	local fakeGame = {
		GetService = function(_, name: string)
			return assert(services[name], "dryrun has no stand-in for service " .. name)
		end,
	}
	function place.run()
		local env = {
			game = fakeGame,
			Instance = Instance,
			Vector3 = Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			UDim2 = roblox.UDim2,
			Enum = roblox.Enum,
			print = function(...)
				local pieces = {}
				for index = 1, select("#", ...) do
					pieces[index] = tostring((select(index, ...)))
				end
				local line = table.concat(pieces, " ")
				table.insert(place.printed, line)
				print("  info  " .. line)
			end,
		}
		luau.load(builderSource, { debugName = BUILDER, environment = env })()
	end
	return place
end

-- Ids and rarities straight from the game config.
local function parseDefs(path: string): { { id: string, rarity: string } }
	local defs = {}
	local seen = {}
	local pattern = '%f[%a]id = "(%w+)",%s*name = "[^"]*",%s*rarity = "(%w+)"'
	for id, rarity in string.gmatch(fs.readFile(path), pattern) do
		if not seen[id] then
			seen[id] = true
			table.insert(defs, { id = id, rarity = rarity })
		end
	end
	return defs
end

-- Geometry helpers --------------------------------------------------------------------------------

local function partsOf(model: any): { any }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- World bounds of a list of parts, corner by corner (rotated parts included).
local function boundsOf(parts: { any }): ({ number }, { number })
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	for _, part in parts do
		local size = part.Size
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				for _, sz in { -0.5, 0.5 } do
					local corner = part.CFrame * Vector3.new(size.X * sx, size.Y * sy, size.Z * sz)
					local xyz = { corner.X, corner.Y, corner.Z }
					for axis = 1, 3 do
						lo[axis] = math.min(lo[axis], xyz[axis])
						hi[axis] = math.max(hi[axis], xyz[axis])
					end
				end
			end
		end
	end
	return lo, hi
end

local function without(parts: { any }, excluded: any): { any }
	local list = {}
	for _, part in parts do
		if part ~= excluded then
			table.insert(list, part)
		end
	end
	return list
end

local function worldPosition(attachment: any): any
	return (attachment.Parent.CFrame * attachment.CFrame).Position
end

local function named(model: any, className: string, name: string): { any }
	local found = {}
	for _, descendant in model:GetDescendants() do
		if descendant.ClassName == className and descendant.Name == name then
			table.insert(found, descendant)
		end
	end
	return found
end

local function ofClass(model: any, className: string): { any }
	local found = {}
	for _, descendant in model:GetDescendants() do
		if descendant.ClassName == className then
			table.insert(found, descendant)
		end
	end
	return found
end

-- Names of the parts that cannot be reached from `root` through WeldConstraints / Motor6Ds.
local function unreachable(model: any, root: any): { string }
	local parts = partsOf(model)
	local function indexOf(instance: any): number?
		for index, part in parts do
			if part == instance then
				return index
			end
		end
		return nil
	end
	local edges = {}
	for _, descendant in model:GetDescendants() do
		if descendant.ClassName == "WeldConstraint" or descendant.ClassName == "Motor6D" then
			local a = descendant.Part0 and indexOf(descendant.Part0)
			local b = descendant.Part1 and indexOf(descendant.Part1)
			if a and b then
				table.insert(edges, { a, b })
			end
		end
	end
	local reached = {}
	local rootIndex = indexOf(root)
	if rootIndex then
		reached[rootIndex] = true
	end
	local grew = true
	while grew do
		grew = false
		for _, edge in edges do
			if reached[edge[1]] ~= reached[edge[2]] then
				reached[edge[1]], reached[edge[2]] = true, true
				grew = true
			end
		end
	end
	local missing = {}
	for index, part in parts do
		if not reached[index] then
			table.insert(missing, part.Name)
		end
	end
	return missing
end

-- Problems with the "nothing collides / decorative only" part properties.
local function propertyProblems(model: any, root: any): { string }
	local problems = {}
	for _, part in partsOf(model) do
		local bad = {}
		if part.CanCollide then
			table.insert(bad, "CanCollide")
		end
		if part ~= root then
			if part.Anchored then
				table.insert(bad, "Anchored")
			end
			if part.CanQuery then
				table.insert(bad, "CanQuery")
			end
			if part.CanTouch then
				table.insert(bad, "CanTouch")
			end
			if not part.Massless then
				table.insert(bad, "not Massless")
			end
			if part.CastShadow then
				table.insert(bad, "CastShadow")
			end
			local material = part.Material.Name
			if material ~= "SmoothPlastic" and material ~= "Neon" then
				table.insert(bad, "Material " .. material)
			end
		end
		if #bad > 0 and #problems < 6 then
			table.insert(problems, `{part.Name}: {table.concat(bad, "/")}`)
		end
	end
	return problems
end

local function anchoredCount(model: any): number
	local count = 0
	for _, part in partsOf(model) do
		if part.Anchored then
			count += 1
		end
	end
	return count
end

local function hasWeld(model: any, part0: any, part1: any): boolean
	for _, constraint in ofClass(model, "WeldConstraint") do
		if
			(constraint.Part0 == part0 and constraint.Part1 == part1)
			or (constraint.Part0 == part1 and constraint.Part1 == part0)
		then
			return true
		end
	end
	return false
end

local function colorKey(color: any): string
	return string.format("%d,%d,%d", math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))
end

local function inRange(value: number, low: number, high: number): boolean
	return value >= low - 1e-6 and value <= high + 1e-6
end

local function modelsNamed(folder: any, name: string): { any }
	local found = {}
	for _, child in folder:GetChildren() do
		if child.Name == name then
			table.insert(found, child)
		end
	end
	return found
end

-- Run the builder twice -------------------------------------------------------------------------

local rodDefs = parseDefs("src/shared/Config/Rods.luau")
local baitDefs = parseDefs("src/shared/Config/Baits.luau")

print("BuildGear dry run")
local place = newPlace()

-- Something that must survive: the creature library.
do
	local assets = Instance.new("Folder")
	assets.Name = "Assets"
	local creatures = Instance.new("Folder")
	creatures.Name = "Creatures"
	creatures.Parent = assets
	local saltwater = Instance.new("Folder")
	saltwater.Name = "Saltwater"
	saltwater.Parent = creatures
	local marker = Instance.new("Model")
	marker.Name = "AbyssalAngler"
	marker:SetAttribute("GeneratedBy", "BuildAbyssalAngler")
	marker.Parent = saltwater
	assets.Parent = place.replicatedStorage
end

place.run()
place.run() -- must be safely re-runnable

local assets = place.replicatedStorage:FindFirstChild("Assets")
local rodsFolder = assets and assets:FindFirstChild("Rods")
local baitsFolder = assets and assets:FindFirstChild("Baits")
local propsFolder = assets and assets:FindFirstChild("Props")

print("\nPlace")
check(
	"config parse: 6 rod ids in Rods.luau and 5 bait ids in Baits.luau",
	#rodDefs == 6 and #baitDefs == 5,
	`{#rodDefs} rods, {#baitDefs} baits`
)
check(
	"Assets has Rods, Baits and Props folders",
	rodsFolder ~= nil
		and baitsFolder ~= nil
		and propsFolder ~= nil
		and rodsFolder.ClassName == "Folder"
		and baitsFolder.ClassName == "Folder"
		and propsFolder.ClassName == "Folder"
)
if not (rodsFolder and baitsFolder and propsFolder) then
	print("\nThe builder did not create its folders; nothing else can be checked.")
	process.exit(1)
end
check(
	"after two runs: exactly one model per id (6 rods, 5 baits, 1 Bobber)",
	#rodsFolder:GetChildren() == #rodDefs
		and #baitsFolder:GetChildren() == #baitDefs
		and #propsFolder:GetChildren() == 1,
	`{#rodsFolder:GetChildren()} rods, {#baitsFolder:GetChildren()} baits, {#propsFolder:GetChildren()} props`
)
do
	local creatures = assets:FindFirstChild("Creatures")
	local saltwater = creatures and creatures:FindFirstChild("Saltwater")
	local marker = saltwater and saltwater:FindFirstChild("AbyssalAngler")
	check(
		"Assets/Creatures is untouched",
		#assets:GetChildren() == 4
			and creatures ~= nil
			and #creatures:GetChildren() == 1
			and #saltwater:GetChildren() == 1
			and marker ~= nil
			and marker:GetAttribute("GeneratedBy") == "BuildAbyssalAngler"
			and #marker:GetChildren() == 0
	)
end
do
	local scripts = 0
	for _, descendant in place.replicatedStorage:GetDescendants() do
		if SCRIPT_CLASSES[descendant.ClassName] then
			scripts += 1
		end
	end
	check("the builder creates no scripts", scripts == 0, tostring(scripts))
end
check(
	"ChangeHistoryService recording begun and committed once per run",
	place.began == 2 and place.finished == 2 and place.lastOperation == roblox.Enum.FinishRecordingOperation.Commit,
	`began {place.began}, finished {place.finished}, last {tostring(place.lastOperation)}`
)
check(
	"one print summary line per run, identical on the re-run",
	#place.printed == 2
		and place.printed[1] == place.printed[2]
		and string.find(place.printed[1], "[BuildGear]", 1, true) == 1,
	`{#place.printed} line(s)`
)
local summaryLine = place.printed[#place.printed] or ""
local function inSummary(model: any): boolean
	return string.find(summaryLine, `{model.Name} {#partsOf(model)}`, 1, true) ~= nil
end

-- Rods ------------------------------------------------------------------------------------------

local rodStats: { { id: string, count: number, colors: string, colorCount: number } } = {}

for _, def in rodDefs do
	local id = def.id
	print(`\nRod {id} [{def.rarity}]`)
	local matches = modelsNamed(rodsFolder, id)
	local model = matches[1]
	check(
		`{id}: exactly one Model with GeneratedBy / RodId / RigVersion attributes, listed in the summary`,
		#matches == 1
			and model.ClassName == "Model"
			and model:GetAttribute("GeneratedBy") == GENERATOR
			and model:GetAttribute("RodId") == id
			and model:GetAttribute("RigVersion") == 1
			and inSummary(model),
		`{#matches} found`
	)
	if not model or model.ClassName ~= "Model" then
		continue
	end

	local parts = partsOf(model)
	local handle = model.PrimaryPart
	check(`{id}: {#parts} parts (14..45)`, inRange(#parts, 14, 45))

	local handleOk = handle ~= nil and handle.Name == "Handle" and handle.Parent == model
	check(
		`{id}: PrimaryPart is Handle (~0.35 x 0.35 x 1.2) and the only anchored part`,
		handleOk
			and handle.Anchored
			and anchoredCount(model) == 1
			and inRange(handle.Size.X, 0.3, 0.45)
			and inRange(handle.Size.Y, 0.3, 0.45)
			and inRange(handle.Size.Z, 1.1, 1.3),
		if handleOk then `size {tostring(handle.Size)}, {anchoredCount(model)} anchored` else "no Handle PrimaryPart"
	)
	if not handleOk then
		continue
	end

	do
		local grip = handle:FindFirstChild("Grip")
		local ok = grip ~= nil and grip.ClassName == "Attachment" and #named(model, "Attachment", "Grip") == 1
		if ok then
			local world = handle.CFrame * grip.CFrame
			ok = (world.Position - handle.CFrame.Position).Magnitude < 1e-3
				and (world.XVector - Vector3.new(1, 0, 0)).Magnitude < 1e-3
				and (world.YVector - Vector3.new(0, 1, 0)).Magnitude < 1e-3
		end
		check(`{id}: Grip attachment at the Handle centre, identity orientation`, ok)
	end

	local lo, hi = boundsOf(parts)
	local handleLo, handleHi = boundsOf({ handle })
	do
		local length, width, height = hi[3] - lo[3], hi[1] - lo[1], hi[2] - lo[2]
		check(
			string.format(
				"%s: %.2f long (6.0..7.5), %.2f wide and %.2f tall (<= 2.4), butt at +Z",
				id,
				length,
				width,
				height
			),
			inRange(length, 6.0, 7.5)
				and width <= 2.4
				and height <= 2.4
				-- the grip is at the +Z end: at most a pommel behind it, the whole rod ahead of it
				and hi[3] - handleHi[3] <= 0.8
				and handleLo[3] - lo[3] >= 4
		)
	end

	do
		local tips = named(model, "Attachment", "Tip")
		local ok, detail = #tips == 1, `{#tips} Tip attachments`
		if ok then
			local tip = tips[1]
			local carrier = tip.Parent
			if not carrier:IsA("BasePart") then
				ok, detail = false, "Tip is not parented to a part"
			else
				local tipZ = worldPosition(tip).Z
				local carrierLo = boundsOf({ carrier })
				detail = string.format("Tip z %.3f, rod min z %.3f, carrier min z %.3f", tipZ, lo[3], carrierLo[3])
				ok = math.abs(tipZ - lo[3]) <= 0.3 and math.abs(carrierLo[3] - lo[3]) <= 0.3
			end
		end
		check(`{id}: exactly one Tip attachment, on the foremost part, at the most -Z point (within 0.3)`, ok, detail)
	end

	local shaft = model:FindFirstChild("Shaft")
	check(
		`{id}: Shaft is a direct child, welded to Handle, running forward from the grip`,
		shaft ~= nil
			and shaft:IsA("BasePart")
			and hasWeld(model, handle, shaft)
			and shaft.Size.Z >= 2
			and shaft.Size.Z > shaft.Size.X
			and shaft.Size.Z > shaft.Size.Y
			and shaft.CFrame.Position.Z < handle.CFrame.Position.Z
	)

	local reel = model:FindFirstChild("Reel")
	do
		local motors = ofClass(model, "Motor6D")
		local motor = motors[1]
		local ok, detail = reel ~= nil and reel:IsA("BasePart") and #motors == 1, `{#motors} Motor6D`
		if ok then
			ok = motor.Name == "Reel" and motor.Parent == handle and motor.Part0 == handle and motor.Part1 == reel
			detail = "Motor6D name / parent / Part0 / Part1"
		end
		if ok then
			local pivot0 = handle.CFrame * motor.C0
			local pivot1 = reel.CFrame * motor.C1
			detail = "pivot mismatch or off the axle"
			ok = (pivot0.Position - pivot1.Position).Magnitude < 1e-3
				and (pivot0.XVector - pivot1.XVector).Magnitude < 1e-3
				and (pivot0.YVector - pivot1.YVector).Magnitude < 1e-3
				-- at the reel's centre, spinning about the reel's local X, which is across the rod
				and (pivot1.Position - reel.CFrame.Position).Magnitude < 1e-3
				and (pivot1.XVector - reel.CFrame.XVector).Magnitude < 1e-3
				and math.abs(reel.CFrame.XVector.Z) < 1e-3
		end
		check(
			`{id}: Reel joined by Motor6D "Reel" (in Handle, Handle -> Reel), C0/C1 on the same axle pivot`,
			ok,
			detail
		)
	end

	do
		local missing = unreachable(model, handle)
		local misplaced = {}
		for _, part in parts do
			local parent = part.Parent
			if part == handle or part == shaft or part == reel then
				if parent ~= model then
					table.insert(misplaced, part.Name)
				end
			elseif not (parent == handle or parent == shaft or parent == reel) or not hasWeld(model, parent, part) then
				table.insert(misplaced, part.Name)
			end
		end
		check(
			`{id}: every part reaches Handle through welds / the motor; voxels are welded children of their bone`,
			#missing == 0 and #misplaced == 0,
			`unreachable: {table.concat(missing, ",")} misplaced: {table.concat(misplaced, ",")}`
		)
	end

	do
		local problems = propertyProblems(model, handle)
		check(
			`{id}: nothing collides; non-root parts unanchored, massless, no query/touch/shadow, SmoothPlastic or Neon`,
			#problems == 0,
			table.concat(problems, "; ")
		)
	end

	do
		local lights = {}
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("Light") then
				table.insert(lights, descendant)
			end
		end
		if RARITY_ORDER[def.rarity] >= RARITY_ORDER.Epic then
			local light = lights[1]
			check(
				`{id}: one PointLight (range 6..8) on a Neon glow part`,
				#lights == 1
					and light.ClassName == "PointLight"
					and inRange(light.Range, 6, 8)
					and light.Parent:IsA("BasePart")
					and light.Parent.Material.Name == "Neon",
				`{#lights} light(s)`
			)
		else
			check(`{id}: no lights below Epic`, #lights == 0, `{#lights} light(s)`)
		end
	end

	local colorSet, colorList = {}, {}
	for _, part in parts do
		local key = colorKey(part.Color)
		if not colorSet[key] then
			colorSet[key] = true
			table.insert(colorList, key)
		end
	end
	table.sort(colorList)
	table.insert(rodStats, { id = id, count = #parts, colors = table.concat(colorList, " "), colorCount = #colorList })
end

print("\nRod roster")
do
	local clashes = {}
	for i = 1, #rodStats do
		for j = i + 1, #rodStats do
			local a, b = rodStats[i], rodStats[j]
			if a.count == b.count and a.colors == b.colors then
				table.insert(clashes, `{a.id} = {b.id}`)
			end
		end
	end
	for _, stats in rodStats do
		print(string.format("  info  %-20s %2d parts, %d colours", stats.id, stats.count, stats.colorCount))
	end
	check(
		"the six rods are distinct: no two share both a part count and a colour set",
		#rodStats == 6 and #clashes == 0,
		table.concat(clashes, "; ")
	)
end

-- Baits and bobber ----------------------------------------------------------------------------------

-- Checks shared by the root-and-voxels models. Returns the root when it is usable.
local function checkRooted(id: string, model: any, minParts: number, maxParts: number): any
	local parts = partsOf(model)
	-- Holds whether or not the invisible RootPart is counted as a part.
	check(
		`{id}: {#parts} parts incl. RootPart ({minParts}..{maxParts})`,
		inRange(#parts, minParts, maxParts) and inRange(#parts - 1, minParts, maxParts)
	)
	local root = model.PrimaryPart
	local rootOk = root ~= nil and root.Name == "RootPart" and root.Parent == model
	check(
		`{id}: PrimaryPart is RootPart: invisible and the only anchored part`,
		rootOk and root.Anchored and root.Transparency == 1 and anchoredCount(model) == 1
	)
	if not rootOk then
		return nil
	end

	local unwelded = {}
	for _, part in parts do
		if part ~= root and not hasWeld(model, root, part) then
			table.insert(unwelded, part.Name)
		end
	end
	local missing = unreachable(model, root)
	check(
		`{id}: every other part is welded to RootPart by a WeldConstraint`,
		#unwelded == 0 and #missing == 0 and #ofClass(model, "Motor6D") == 0,
		table.concat(unwelded, ",")
	)

	local problems = propertyProblems(model, root)
	local lights = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Light") then
			lights += 1
		end
	end
	check(
		`{id}: nothing collides; non-root parts unanchored, massless, no query/touch/shadow, SmoothPlastic or Neon; no lights`,
		#problems == 0 and lights == 0,
		table.concat(problems, "; ")
	)
	return root
end

for _, def in baitDefs do
	local id = def.id
	print(`\nBait {id} [{def.rarity}]`)
	local matches = modelsNamed(baitsFolder, id)
	local model = matches[1]
	check(
		`{id}: exactly one Model with GeneratedBy / BaitId / RigVersion attributes, listed in the summary`,
		#matches == 1
			and model.ClassName == "Model"
			and model:GetAttribute("GeneratedBy") == GENERATOR
			and model:GetAttribute("BaitId") == id
			and model:GetAttribute("RigVersion") == 1
			and inSummary(model),
		`{#matches} found`
	)
	if not model or model.ClassName ~= "Model" then
		continue
	end
	local root = checkRooted(id, model, 5, 16)
	if not root then
		continue
	end

	local lo, hi = boundsOf(without(partsOf(model), root))
	local size = { hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3] }
	local largest = math.max(size[1], size[2], size[3])
	check(
		string.format(
			"%s: %.2f x %.2f x %.2f fits a 1.6-stud cube, largest dimension >= 0.8",
			id,
			size[1],
			size[2],
			size[3]
		),
		largest <= 1.6 and largest >= 0.8
	)
	local centre = Vector3.new((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2)
	check(
		`{id}: RootPart sits at the model centre and matches its bounding size`,
		(root.CFrame.Position - centre).Magnitude < 0.02
			and math.abs(root.Size.X - size[1]) < 0.05
			and math.abs(root.Size.Y - size[2]) < 0.05
			and math.abs(root.Size.Z - size[3]) < 0.05,
		`root {tostring(root.Size)} at {tostring(root.CFrame.Position)}`
	)
end

print("\nProp Bobber")
do
	local matches = modelsNamed(propsFolder, "Bobber")
	local model = matches[1]
	check(
		"Bobber: exactly one Model with GeneratedBy / RigVersion attributes, listed in the summary",
		#matches == 1
			and model.ClassName == "Model"
			and model:GetAttribute("GeneratedBy") == GENERATOR
			and model:GetAttribute("RigVersion") == 1
			and inSummary(model),
		`{#matches} found`
	)
	local root = if model and model.ClassName == "Model" then checkRooted("Bobber", model, 4, 8) else nil
	if root then
		local visible = without(partsOf(model), root)
		local lo, hi = boundsOf(visible)
		local width, depth, height = hi[1] - lo[1], hi[3] - lo[3], hi[2] - lo[2]
		check(
			string.format("Bobber: %.2f wide (about 0.9) and %.2f tall (about 1.3)", width, height),
			inRange(width, 0.8, 1.0) and inRange(depth, 0.8, 1.0) and inRange(height, 1.2, 1.4)
		)

		-- Waterline: centred in X/Z, with the red float above it and the white float below.
		local rootPosition = root.CFrame.Position
		local above, below
		for _, part in visible do
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			local y = part.CFrame.Position.Y - rootPosition.Y
			if y > 0.05 and (not above or volume > above.volume) then
				above = { volume = volume, color = part.Color }
			elseif y < -0.05 and (not below or volume > below.volume) then
				below = { volume = volume, color = part.Color }
			end
		end
		check(
			"Bobber: RootPart at the waterline centre, red float above it, white float below",
			math.abs(rootPosition.X - (lo[1] + hi[1]) / 2) < 0.02
				and math.abs(rootPosition.Z - (lo[3] + hi[3]) / 2) < 0.02
				and rootPosition.Y - lo[2] > 0.3
				and hi[2] - rootPosition.Y > 0.3
				and above ~= nil
				and below ~= nil
				and above.color.R > 0.6
				and above.color.G < 0.4
				and above.color.B < 0.4
				and math.min(below.color.R, below.color.G, below.color.B) > 0.85
		)

		local lines = named(model, "Attachment", "Line")
		local ok, detail = #lines == 1, `{#lines} Line attachments`
		if ok then
			local carrier = lines[1].Parent
			local position = worldPosition(lines[1])
			detail = string.format("Line y %.3f, top %.3f", position.Y, hi[2])
			-- on a thin antenna, at the very top, on the centre line
			ok = carrier:IsA("BasePart")
				and carrier ~= root
				and carrier.Size.X <= 0.2
				and math.abs(position.Y - hi[2]) < 0.02
				and math.abs(position.X - rootPosition.X) < 0.05
				and math.abs(position.Z - rootPosition.Z) < 0.05
		end
		check("Bobber: exactly one Line attachment, at the top of the antenna", ok, detail)

		local lowest
		for _, part in visible do
			if not lowest or part.CFrame.Position.Y < lowest.CFrame.Position.Y then
				lowest = part
			end
		end
		check("Bobber: a small ring hangs underneath", lowest ~= nil and lowest.Size.X <= 0.3 and lowest.Size.Z <= 0.3)
	end
end

-- Hand-authored models are never overwritten ------------------------------------------------------

print("\nSkip guard (separate place: a hand-made DriftwoodRod and Bobber already exist)")
do
	local guarded = newPlace()
	local guardedAssets = Instance.new("Folder")
	guardedAssets.Name = "Assets"
	local guardedRods = Instance.new("Folder")
	guardedRods.Name = "Rods"
	guardedRods.Parent = guardedAssets
	local guardedProps = Instance.new("Folder")
	guardedProps.Name = "Props"
	guardedProps.Parent = guardedAssets
	local handMadeRod = Instance.new("Model")
	handMadeRod.Name = "DriftwoodRod"
	local keepsake = Instance.new("Part")
	keepsake.Name = "HandMade"
	keepsake.Parent = handMadeRod
	handMadeRod.Parent = guardedRods
	local handMadeBobber = Instance.new("Model")
	handMadeBobber.Name = "Bobber"
	handMadeBobber:SetAttribute("GeneratedBy", "SomeoneElse")
	handMadeBobber.Parent = guardedProps
	guardedAssets.Parent = guarded.replicatedStorage

	guarded.run()
	guarded.run()

	local rods = guardedAssets.Rods
	local rod = modelsNamed(rods, "DriftwoodRod")
	local bobber = modelsNamed(guardedAssets.Props, "Bobber")
	check(
		"models without GeneratedBy = BuildGear are left exactly as they were",
		#rod == 1
			and rod[1]:GetAttribute("GeneratedBy") == nil
			and #rod[1]:GetChildren() == 1
			and rod[1]:FindFirstChild("HandMade") ~= nil
			and #bobber == 1
			and bobber[1]:GetAttribute("GeneratedBy") == "SomeoneElse"
			and #bobber[1]:GetChildren() == 0
	)
	local builtAround = #rods:GetChildren() == #rodDefs and #guardedAssets.Baits:GetChildren() == #baitDefs
	for _, def in rodDefs do
		local model = rods:FindFirstChild(def.id)
		if def.id ~= "DriftwoodRod" and not (model and model:GetAttribute("GeneratedBy") == GENERATOR) then
			builtAround = false
		end
	end
	check("everything else is still built around them", builtAround)
	local line = guarded.printed[#guarded.printed] or ""
	check(
		"the summary line notes both skips",
		string.find(line, "DriftwoodRod SKIPPED", 1, true) ~= nil
			and string.find(line, "Bobber SKIPPED", 1, true) ~= nil
	)
end

print(if failures == 0 then "\nBuildGear passed the dry run." else `\n{failures} dry-run check(s) FAILED.`)
if failures > 0 then
	process.exit(1)
end
