--[[
	VoxelMorph gear builder: every fishing rod, every bait and the bobber.

	HOW TO RUN (edit mode): pass this file to the Studio MCP `execute_luau` tool,
	or paste it into the Command Bar. It creates no scripts. Output:

	  ReplicatedStorage/Assets/Rods/<RodId>      (Model, one per id in Config/Rods.luau)
	  ReplicatedStorage/Assets/Baits/<BaitId>    (Model, one per id in Config/Baits.luau)
	  ReplicatedStorage/Assets/Props/Bobber      (Model)

	Assets/Creatures is never touched. Every model carries the attribute
	GeneratedBy = "BuildGear"; a re-run replaces those and SKIPS any model of the
	same name that lacks the attribute (hand-authored work is never overwritten).
	Headless check: `lune run tools/studio/dryrun_gear.luau`.

	ROD RIG STANDARD (RigVersion 1) - the client relies on exactly this
	  * Model named by rod id, real size, pointing along -Z: butt at +Z, tip at -Z.
	    6.0 to 7.5 studs long, at most 2.4 wide (X) and 2.4 tall (Y).
	  * PrimaryPart = `Handle` (the grip, centred on the model origin). It is the
	    only anchored part and holds the Attachment `Grip` (handle centre, identity).
	  * `Shaft` (direct child, WeldConstraint to Handle) is the main rod body.
	  * Exactly one Attachment named `Tip`, on the foremost part, at the most -Z
	    point of the rod: the fishing line starts there.
	  * `Reel` (direct child) hangs under the shaft just ahead of the grip, joined
	    by the Motor6D `Reel` (in Handle, Part0 = Handle, Part1 = Reel, C0/C1 at
	    the axle centre, unrotated). Spin it about its local X axis through
	    `Motor6D.Transform`. The reel is seated on a bracket on the -X side; the
	    crank is on the +X side.
	  * Decorative voxels are children of the bone they ride on (Handle, Shaft or
	    Reel), joined by WeldConstraints. Nothing collides, casts shadows or
	    answers queries. SmoothPlastic everywhere, Neon for authored glow.
	  * Attributes: RodId, RigVersion, GeneratedBy.

	BAIT / BOBBER STANDARD
	  * PrimaryPart = `RootPart` (anchored, invisible). Baits: at the centre of the
	    model and the size of its bounds. Bobber: at the waterline centre.
	  * Every other part is a direct child of the Model, welded to RootPart.
	  * Bobber: Attachment `Line` at the top of the antenna (the line ends there).
	  * Attributes: BaitId (baits) / PropId (bobber), RigVersion, GeneratedBy.

	BUDGETS (enforced by the dry run)
	  rods 14-45 parts, baits 5-16, bobber 4-8. No meshes, textures or particles.
	  One PointLight per Epic+ rod (range 6-8) and none anywhere else.
	  Translucent parts are kept to a handful per model (overdraw on mobile).
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GENERATOR = "BuildGear"
local RIG_VERSION = 1
local HANDLE_LENGTH = 1.2

local V = Vector3.new
local rgb = Color3.fromRGB
local NEON = { neon = true }

-- Helpers -----------------------------------------------------------------------------------

-- CFrame at a position, optionally rotated (degrees, applied X then Y then Z).
local function at(x, y, z, rx, ry, rz)
	local cf = CFrame.new(x, y, z)
	if rx then
		cf = cf * CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
	end
	return cf
end

-- opts: neon (Neon material), alpha (Transparency), shine (Reflectance)
local function makePart(parent, name, sx, sy, sz, cf, color, opts)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = V(sx, sy, sz)
	part.CFrame = cf
	part.Color = color
	part.Material = if opts and opts.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	if opts and opts.alpha then
		part.Transparency = opts.alpha
	end
	if opts and opts.shine then
		part.Reflectance = opts.shine
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function weld(part0, part1)
	local constraint = Instance.new("WeldConstraint")
	constraint.Part0 = part0
	constraint.Part1 = part1
	constraint.Parent = part1
	return constraint
end

-- A decorative voxel that rides on a bone.
local function vox(bone, name, sx, sy, sz, cf, color, opts)
	local part = makePart(bone, name, sx, sy, sz, cf, color, opts)
	weld(bone, part)
	return part
end

-- A voxel beam from one point to another (its length runs along the part's Z axis).
-- Not for vertical beams: use an unrotated `vox` for those.
local function seg(bone, name, thickX, thickY, from, to, color, opts)
	local length = (to - from).Magnitude
	return vox(bone, name, thickX, thickY, length, CFrame.lookAt((from + to) / 2, to), color, opts)
end

-- An Attachment at a world position, with world-identity orientation.
local function attach(part, name, worldPosition)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = part.CFrame:ToObjectSpace(CFrame.new(worldPosition))
	attachment.Parent = part
	return attachment
end

local function glow(part, color, range)
	local light = Instance.new("PointLight")
	light.Name = "Glow"
	light.Color = color
	light.Range = range
	light.Brightness = 1.6
	light.Shadows = false
	light.Parent = part
	return light
end

local function countParts(model)
	local count = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

-- Rod skeleton --------------------------------------------------------------------------------

--[[
	Builds the bones every rod shares and returns model, handle, shaft, reel.
	  spec.handle = { sizeX, sizeY, color }          length is HANDLE_LENGTH, centred on the origin
	  spec.shaft  = { sizeX, sizeY, length, color }  starts at the front of the handle
	  spec.reel   = { sizeX, sizeY, sizeZ, color, y = , z = , clear = }
	                `clear` is how far the finished reel reaches on the -X side,
	                so the bracket can sit just outside it.
	  spec.seat, spec.bracket = colours of the reel seat parts
]]
local function beginRod(id, spec)
	local model = Instance.new("Model")
	model.Name = id
	model:SetAttribute("RodId", id)
	model:SetAttribute("RigVersion", RIG_VERSION)
	model:SetAttribute("GeneratedBy", GENERATOR)

	local handle = makePart(model, "Handle", spec.handle[1], spec.handle[2], HANDLE_LENGTH, at(0, 0, 0), spec.handle[3])
	handle.Anchored = true
	model.PrimaryPart = handle
	attach(handle, "Grip", V(0, 0, 0))

	local shaftX, shaftY, shaftLength = spec.shaft[1], spec.shaft[2], spec.shaft[3]
	local shaftZ = -HANDLE_LENGTH / 2 - shaftLength / 2
	local shaft = makePart(model, "Shaft", shaftX, shaftY, shaftLength, at(0, 0, shaftZ), spec.shaft[4])
	weld(handle, shaft)

	local r = spec.reel
	local reel = makePart(model, "Reel", r[1], r[2], r[3], at(0, r.y, r.z), r[4])
	local axle = CFrame.new(0, r.y, r.z)
	local motor = Instance.new("Motor6D")
	motor.Name = "Reel"
	motor.Part0 = handle
	motor.Part1 = reel
	motor.C0 = handle.CFrame:ToObjectSpace(axle)
	motor.C1 = reel.CFrame:ToObjectSpace(axle)
	motor.Parent = handle

	-- Reel seat: a saddle under the shaft and a bracket down the -X side to the axle.
	local left, right = -(r.clear + 0.1), shaftX / 2 + 0.02
	vox(shaft, "ReelSeat", right - left, 0.08, 0.34, at((left + right) / 2, -shaftY / 2 - 0.04, r.z), spec.seat)
	local top, bottom = -shaftY / 2 - 0.08, r.y - 0.09
	vox(shaft, "ReelBracket", 0.08, top - bottom, 0.18, at(-(r.clear + 0.06), (top + bottom) / 2, r.z), spec.bracket)

	return model, handle, shaft, reel
end

-- Rod designs -----------------------------------------------------------------------------------
-- Coordinates are model space: X right, Y up, -Z towards the tip, origin at the grip centre.

local ROD_ORDER =
	{ "DriftwoodRod", "CoralCaster", "TidebreakerRod", "GildedHarpoon", "AbyssalTrident", "ChronosSovereignRod" }
local ROD_BUILDERS = {}

-- Common: rough, crooked weathered wood, twine lashings, wooden spool, bent-nail eye.
function ROD_BUILDERS.DriftwoodRod(id)
	local c = {
		wood = rgb(139, 105, 74),
		dark = rgb(101, 76, 54),
		pale = rgb(171, 158, 140),
		twine = rgb(212, 190, 142),
		nail = rgb(128, 130, 138),
		rust = rgb(140, 84, 58),
	}
	local model, handle, shaft, reel = beginRod(id, {
		handle = { 0.38, 0.38, c.dark },
		shaft = { 0.26, 0.26, 2.6, c.wood },
		reel = { 0.3, 0.44, 0.44, c.wood, y = -0.72, z = -1.05, clear = 0.23 },
		seat = c.twine,
		bracket = c.dark,
	})

	vox(handle, "ButtKnot", 0.46, 0.46, 0.3, at(0, 0, 0.75), c.pale)
	vox(handle, "TwineWrap", 0.44, 0.44, 0.14, at(0, 0, -0.38), c.twine)
	vox(handle, "TwineWrap", 0.44, 0.44, 0.14, at(0, 0, 0.32), c.twine)

	-- The upper rod wanders off-axis and back; twine lashings cover the joints.
	seg(shaft, "ShaftMid", 0.22, 0.22, V(0, 0, -3.18), V(0.13, 0.1, -4.66), c.pale)
	seg(shaft, "ShaftTip", 0.16, 0.16, V(0.13, 0.1, -4.62), V(0.02, 0, -5.8), c.wood)
	vox(shaft, "TwineWrap", 0.32, 0.32, 0.16, at(0.01, 0.01, -3.2), c.twine)
	vox(shaft, "TwineWrap", 0.27, 0.27, 0.14, at(0.13, 0.1, -4.64), c.twine)
	vox(shaft, "Knot", 0.34, 0.3, 0.3, at(0.04, 0.03, -2.0), c.dark)
	seg(shaft, "BranchStub", 0.14, 0.14, V(0, 0.1, -2.6), V(-0.08, 0.42, -2.85), c.pale)

	-- Bent nail: driven up through the tip, folded forward, then down into an eye.
	vox(shaft, "NailStem", 0.07, 0.34, 0.07, at(0.02, 0.06, -5.78), c.rust)
	vox(shaft, "NailBend", 0.07, 0.07, 0.2, at(0.02, 0.23, -5.88), c.nail)
	local eye = vox(shaft, "NailEye", 0.07, 0.16, 0.07, at(0.02, 0.17, -5.96), c.nail)
	attach(eye, "Tip", V(0.02, 0.17, -5.995))

	local y, z = -0.72, -1.05
	vox(reel, "LineWrap", 0.2, 0.56, 0.56, at(0, y, z), c.twine)
	vox(reel, "Flange", 0.08, 0.7, 0.7, at(-0.19, y, z), c.dark)
	vox(reel, "Flange", 0.08, 0.7, 0.7, at(0.19, y, z), c.dark)
	vox(reel, "CrankArm", 0.06, 0.12, 0.42, at(0.26, y, z - 0.12), c.pale)
	vox(reel, "CrankKnob", 0.2, 0.14, 0.14, at(0.39, y, z - 0.28), c.wood)
	return model
end

-- Uncommon: coral branches growing off a pink shaft, spiral-shell reel, pearls.
function ROD_BUILDERS.CoralCaster(id)
	local c = {
		coral = rgb(255, 127, 130),
		deep = rgb(226, 84, 104),
		orange = rgb(255, 158, 96),
		blush = rgb(255, 190, 180),
		shell = rgb(250, 232, 208),
		peach = rgb(243, 178, 140),
		pearl = rgb(246, 242, 252),
		sea = rgb(64, 188, 180),
	}
	local model, handle, shaft, reel = beginRod(id, {
		handle = { 0.36, 0.36, c.shell },
		shaft = { 0.26, 0.26, 2.8, c.coral },
		reel = { 0.3, 0.56, 0.56, c.shell, y = -0.78, z = -1.1, clear = 0.15 },
		seat = c.sea,
		bracket = c.deep,
	})

	vox(handle, "ButtPearl", 0.42, 0.42, 0.42, at(0, 0, 0.81), c.pearl, { shine = 0.2 })
	vox(handle, "GripWrap", 0.4, 0.4, 0.16, at(0, 0, -0.36), c.sea)
	vox(handle, "GripWrap", 0.4, 0.4, 0.16, at(0, 0, 0.3), c.sea)

	vox(shaft, "ShaftMid", 0.2, 0.2, 1.4, at(0, 0, -4.1), c.orange)
	vox(shaft, "ShaftTip", 0.14, 0.14, 1.0, at(0, 0, -5.3), c.blush)
	local tip = vox(shaft, "TipPearl", 0.22, 0.22, 0.22, at(0, 0, -5.89), c.pearl, { shine = 0.2 })
	attach(tip, "Tip", V(0, 0, -6.0))

	-- Branch A: up and to the left, forked.
	seg(shaft, "Coral", 0.16, 0.16, V(-0.05, 0.1, -1.9), V(-0.3, 0.55, -2.0), c.deep)
	seg(shaft, "Coral", 0.12, 0.12, V(-0.3, 0.55, -2.0), V(-0.62, 0.72, -1.95), c.coral)
	seg(shaft, "Coral", 0.12, 0.12, V(-0.28, 0.5, -2.0), V(-0.22, 0.92, -2.15), c.orange)
	-- Branch B: up and to the right.
	seg(shaft, "Coral", 0.15, 0.15, V(0.05, 0.1, -2.9), V(0.28, 0.5, -3.0), c.deep)
	seg(shaft, "Coral", 0.11, 0.11, V(0.28, 0.5, -3.0), V(0.55, 0.62, -3.15), c.orange)
	seg(shaft, "Coral", 0.11, 0.11, V(0.26, 0.48, -3.0), V(0.25, 0.82, -2.9), c.coral)
	-- Branch C: a young sprig on the upper rod.
	seg(shaft, "Coral", 0.12, 0.12, V(0, 0.08, -4.0), V(-0.12, 0.38, -4.12), c.deep)
	seg(shaft, "Coral", 0.1, 0.1, V(-0.12, 0.38, -4.12), V(-0.3, 0.5, -4.05), c.coral)
	-- Branch D: hanging down on the right.
	seg(shaft, "Coral", 0.14, 0.14, V(0.05, -0.08, -2.4), V(0.3, -0.4, -2.5), c.deep)
	seg(shaft, "Coral", 0.1, 0.1, V(0.3, -0.4, -2.5), V(0.52, -0.42, -2.65), c.orange)
	vox(shaft, "Pearl", 0.14, 0.14, 0.14, at(-0.66, 0.74, -1.95), c.pearl, { shine = 0.2 })
	vox(shaft, "Pearl", 0.14, 0.14, 0.14, at(0.25, 0.88, -2.9), c.pearl, { shine = 0.2 })
	vox(shaft, "Pearl", 0.14, 0.14, 0.14, at(-0.34, 0.53, -4.04), c.pearl, { shine = 0.2 })

	-- Shell reel: whorls stepping down to an apex on the +X side, a flared lip below.
	local y, z = -0.78, -1.1
	vox(reel, "Whorl", 0.14, 0.42, 0.42, at(0.22, y, z), c.peach)
	vox(reel, "Whorl", 0.12, 0.28, 0.28, at(0.35, y, z), c.shell)
	vox(reel, "Apex", 0.1, 0.14, 0.14, at(0.46, y, z), c.pearl, { shine = 0.2 })
	vox(reel, "ShellLip", 0.3, 0.26, 0.3, at(0, y - 0.2, z - 0.3), c.peach)
	vox(reel, "CrankNub", 0.14, 0.12, 0.12, at(0.34, y + 0.16, z + 0.12), c.deep)
	return model
end

-- Rare: blue steel, wave-crest fins along the top, ship's-wheel reel, foam trim.
function ROD_BUILDERS.TidebreakerRod(id)
	local c = {
		steel = rgb(58, 104, 158),
		navy = rgb(32, 54, 96),
		light = rgb(128, 172, 214),
		foam = rgb(236, 246, 250),
		wave = rgb(84, 186, 226),
		brass = rgb(206, 168, 92),
	}
	local model, handle, shaft, reel = beginRod(id, {
		handle = { 0.38, 0.38, c.navy },
		shaft = { 0.28, 0.28, 3.0, c.steel },
		reel = { 0.3, 0.3, 0.3, c.navy, y = -0.78, z = -1.2, clear = 0.19 },
		seat = c.foam,
		bracket = c.navy,
	})

	vox(handle, "GripTrim", 0.44, 0.44, 0.12, at(0, 0, -0.5), c.foam)
	vox(handle, "GripTrim", 0.44, 0.44, 0.12, at(0, 0, 0.5), c.foam)
	vox(handle, "ButtCap", 0.46, 0.46, 0.26, at(0, 0, 0.73), c.steel)
	vox(handle, "ButtFoam", 0.3, 0.3, 0.12, at(0, 0, 0.92), c.foam)

	vox(shaft, "ShaftMid", 0.22, 0.22, 1.3, at(0, 0, -4.25), c.light)
	vox(shaft, "ShaftTip", 0.16, 0.16, 0.9, at(0, 0, -5.35), c.steel)
	vox(shaft, "TrimBand", 0.34, 0.34, 0.12, at(0, 0, -3.6), c.foam)
	vox(shaft, "TrimBand", 0.27, 0.27, 0.1, at(0, 0, -4.9), c.foam)
	local guide = vox(shaft, "TipGuide", 0.26, 0.26, 0.1, at(0, 0, -5.83), c.foam)
	attach(guide, "Tip", V(0, 0, -5.88))

	-- Wave crests: a rising base, a crest curling towards the tip, a foam lip.
	local function crest(z0, s, surface, withFoam)
		vox(shaft, "FinBase", 0.1, 0.26 * s, 0.5 * s, at(0, surface + 0.13 * s, z0), c.light)
		vox(shaft, "FinCrest", 0.1, 0.18 * s, 0.3 * s, at(0, surface + 0.35 * s, z0 - 0.22 * s), c.wave)
		if withFoam then
			vox(shaft, "FinFoam", 0.12, 0.1 * s, 0.16 * s, at(0, surface + 0.4 * s, z0 - 0.42 * s), c.foam)
		end
	end
	crest(-1.5, 1.1, 0.14, true)
	crest(-2.4, 1.0, 0.14, true)
	crest(-3.2, 0.85, 0.14, true)
	crest(-4.2, 0.6, 0.11, false)

	-- Ship's wheel in the YZ plane: square rim, eight spokes, four foam grips.
	local y, z = -0.78, -1.2
	vox(reel, "Rim", 0.14, 0.1, 0.74, at(0, y + 0.32, z), c.light)
	vox(reel, "Rim", 0.14, 0.1, 0.74, at(0, y - 0.32, z), c.light)
	vox(reel, "Rim", 0.14, 0.74, 0.1, at(0, y, z - 0.32), c.light)
	vox(reel, "Rim", 0.14, 0.74, 0.1, at(0, y, z + 0.32), c.light)
	vox(reel, "Spoke", 0.1, 1.0, 0.1, at(0, y, z), c.navy)
	vox(reel, "Spoke", 0.1, 0.1, 1.0, at(0, y, z), c.navy)
	vox(reel, "Spoke", 0.08, 0.08, 0.86, at(0, y, z, 45, 0, 0), c.steel)
	vox(reel, "Spoke", 0.08, 0.08, 0.86, at(0, y, z, -45, 0, 0), c.steel)
	vox(reel, "Grip", 0.14, 0.08, 0.14, at(0, y + 0.52, z), c.foam)
	vox(reel, "Grip", 0.14, 0.08, 0.14, at(0, y - 0.52, z), c.foam)
	vox(reel, "Grip", 0.14, 0.14, 0.08, at(0, y, z - 0.52), c.foam)
	vox(reel, "Grip", 0.14, 0.14, 0.08, at(0, y, z + 0.52), c.foam)
	vox(reel, "HubCap", 0.38, 0.18, 0.18, at(0, y, z), c.brass)
	vox(reel, "CrankKnob", 0.2, 0.12, 0.12, at(0.17, y + 0.32, z), c.foam)
	return model
end

-- Epic: a gold harpoon - barbed spear head, ornate bands, rope coil, neon glints.
function ROD_BUILDERS.GildedHarpoon(id)
	local c = {
		gold = rgb(244, 194, 62),
		dark = rgb(178, 126, 40),
		pale = rgb(255, 228, 138),
		glint = rgb(255, 214, 84),
		rope = rgb(216, 192, 142),
		ropeDark = rgb(172, 142, 98),
		leather = rgb(122, 38, 46),
	}
	local model, handle, shaft, reel = beginRod(id, {
		handle = { 0.36, 0.36, c.leather },
		shaft = { 0.26, 0.26, 3.4, c.gold },
		reel = { 0.34, 0.46, 0.46, c.dark, y = -0.74, z = -1.05, clear = 0.25 },
		seat = c.dark,
		bracket = c.gold,
	})

	for _, z in { -0.5, 0, 0.5 } do
		vox(handle, "GripBand", 0.42, 0.42, 0.1, at(0, 0, z), c.gold)
	end
	vox(handle, "Pommel", 0.46, 0.46, 0.26, at(0, 0, 0.73), c.gold)
	vox(handle, "PommelRing", 0.12, 0.3, 0.14, at(0, 0, 0.93), c.dark)

	for _, z in { -1.7, -2.9, -3.7 } do
		vox(shaft, "Band", 0.34, 0.34, 0.14, at(0, 0, z), c.dark)
		vox(shaft, "Glint", 0.1, 0.08, 0.1, at(0, 0.2, z), c.glint, NEON)
	end
	vox(shaft, "RopeCoil", 0.38, 0.38, 0.14, at(0, 0, -2.1), c.rope)
	vox(shaft, "RopeCoil", 0.38, 0.38, 0.14, at(0, 0, -2.25, 0, 0, 10), c.ropeDark)
	vox(shaft, "RopeCoil", 0.38, 0.38, 0.14, at(0, 0, -2.4, 0, 0, -8), c.rope)
	vox(shaft, "RopeEnd", 0.1, 0.36, 0.1, at(0.16, -0.33, -2.42), c.rope)

	-- Spear head: socket, neck, a blade stepping down to the point, four swept-back barbs.
	vox(shaft, "Socket", 0.36, 0.36, 0.4, at(0, 0, -4.2), c.dark)
	vox(shaft, "Neck", 0.18, 0.18, 0.5, at(0, 0, -4.65), c.gold)
	vox(shaft, "BladeWide", 0.14, 0.72, 0.45, at(0, 0, -5.1), c.gold)
	vox(shaft, "BladeMid", 0.14, 0.42, 0.42, at(0, 0, -5.52), c.pale)
	local point = vox(shaft, "BladePoint", 0.12, 0.18, 0.4, at(0, 0, -5.9), c.pale)
	attach(point, "Tip", V(0, 0, -6.1))
	for _, side in { -1, 1 } do
		seg(shaft, "Barb", 0.12, 0.14, V(0, side * 0.3, -4.95), V(0, side * 0.52, -4.5), c.gold)
		seg(shaft, "SideBarb", 0.1, 0.1, V(side * 0.07, 0, -5.0), V(side * 0.3, 0, -4.65), c.dark)
	end
	local ridge = vox(shaft, "BladeRidge", 0.18, 0.08, 0.7, at(0, 0, -5.25), c.glint, NEON)
	glow(ridge, c.glint, 7)

	-- Winch drum wound with rope.
	local y, z = -0.74, -1.05
	vox(reel, "RopeSpool", 0.26, 0.58, 0.58, at(0, y, z), c.rope)
	vox(reel, "Flange", 0.08, 0.72, 0.72, at(-0.21, y, z), c.gold)
	vox(reel, "Flange", 0.08, 0.72, 0.72, at(0.21, y, z), c.gold)
	vox(reel, "CrankArm", 0.06, 0.12, 0.44, at(0.28, y, z - 0.13), c.dark)
	vox(reel, "CrankKnob", 0.2, 0.14, 0.14, at(0.41, y, z - 0.31), c.pale)
	vox(reel, "FlangeGem", 0.1, 0.12, 0.12, at(0.27, y + 0.24, z + 0.2), c.glint, NEON)
	return model
end

-- Legendary: dark indigo trident (centre prong longest), neon veins and prong tips,
-- a tentacle wrapped round the reel. The rod in reference/reel it in.jpeg.
function ROD_BUILDERS.AbyssalTrident(id)
	local c = {
		indigo = rgb(40, 30, 80),
		abyss = rgb(24, 18, 50),
		violet = rgb(98, 64, 176),
		purple = rgb(178, 98, 255),
		magenta = rgb(255, 84, 222),
		tentacle = rgb(74, 46, 124),
		sucker = rgb(196, 166, 238),
		silver = rgb(176, 176, 204),
	}
	local model, handle, shaft, reel = beginRod(id, {
		handle = { 0.36, 0.36, c.abyss },
		shaft = { 0.28, 0.28, 3.6, c.indigo },
		reel = { 0.32, 0.5, 0.5, c.abyss, y = -0.76, z = -1.05, clear = 0.19 },
		seat = c.violet,
		bracket = c.abyss,
	})

	vox(handle, "GripRing", 0.42, 0.42, 0.1, at(0, 0, -0.5), c.silver)
	vox(handle, "GripRing", 0.42, 0.42, 0.1, at(0, 0, 0.5), c.silver)
	vox(handle, "Pommel", 0.44, 0.44, 0.24, at(0, 0, 0.72), c.violet)
	vox(handle, "PommelSpike", 0.2, 0.2, 0.2, at(0, 0, 0.94), c.magenta, NEON)

	-- Glowing veins running along the faces of the shaft.
	vox(shaft, "Vein", 0.06, 0.06, 0.6, at(-0.15, 0.03, -1.9), c.magenta, NEON)
	vox(shaft, "Vein", 0.06, 0.06, 0.8, at(0.05, 0.15, -2.05), c.purple, NEON)
	vox(shaft, "Vein", 0.06, 0.06, 0.7, at(0.15, -0.04, -2.95), c.magenta, NEON)
	vox(shaft, "Vein", 0.06, 0.06, 0.8, at(-0.05, 0.15, -3.45), c.purple, NEON)
	vox(shaft, "Ring", 0.34, 0.34, 0.1, at(0, 0, -2.5), c.silver)
	vox(shaft, "Ring", 0.34, 0.34, 0.1, at(0, 0, -3.95), c.silver)

	-- Trident head, spread across X.
	vox(shaft, "Collar", 0.4, 0.36, 0.3, at(0, 0, -4.33), c.violet)
	vox(shaft, "Crossbar", 1.3, 0.24, 0.26, at(0, 0, -4.6), c.indigo)
	vox(shaft, "CrossVein", 0.9, 0.06, 0.08, at(0, 0.13, -4.6), c.purple, NEON)
	vox(shaft, "CentreProng", 0.22, 0.2, 1.2, at(0, 0, -5.3), c.indigo)
	local centreTip = vox(shaft, "CentreTip", 0.16, 0.14, 0.42, at(0, 0, -6.07), c.magenta, NEON)
	attach(centreTip, "Tip", V(0, 0, -6.28))
	glow(centreTip, c.purple, 8)
	for _, side in { -1, 1 } do
		seg(shaft, "CentreBarb", 0.1, 0.1, V(side * 0.1, 0, -5.85), V(side * 0.3, 0, -5.5), c.violet)
		vox(shaft, "SideProng", 0.18, 0.18, 0.85, at(side * 0.56, 0, -5.12), c.indigo)
		vox(shaft, "SideTip", 0.14, 0.12, 0.34, at(side * 0.56, 0, -5.69), c.purple, NEON)
		seg(shaft, "SideBarb", 0.09, 0.09, V(side * 0.64, 0, -5.5), V(side * 0.82, 0, -5.2), c.violet)
	end

	-- A tentacle coils round the shaft ahead of the reel...
	vox(shaft, "TentacleCoil", 0.4, 0.4, 0.14, at(0, 0, -1.56), c.tentacle)
	vox(shaft, "TentacleCoil", 0.38, 0.38, 0.12, at(0, 0, -1.73, 0, 0, 12), c.tentacle)
	seg(shaft, "TentacleEnd", 0.1, 0.1, V(0.16, 0.16, -1.78), V(0.24, 0.34, -2.05), c.tentacle)

	-- ...and grips the drum; its curled end is the crank.
	local y, z = -0.76, -1.05
	vox(reel, "ReelCore", 0.38, 0.2, 0.2, at(0, y, z), c.purple, NEON)
	vox(reel, "TentacleWrap", 0.2, 0.6, 0.12, at(0.04, y, z - 0.27), c.tentacle)
	vox(reel, "TentacleWrap", 0.2, 0.12, 0.6, at(0.04, y - 0.27, z), c.tentacle)
	vox(reel, "TentacleWrap", 0.2, 0.4, 0.12, at(0.04, y - 0.05, z + 0.27), c.tentacle)
	vox(reel, "TentacleArm", 0.1, 0.12, 0.4, at(0.24, y, z - 0.12), c.tentacle)
	vox(reel, "TentacleCurl", 0.2, 0.16, 0.16, at(0.37, y, z - 0.3), c.violet)
	vox(reel, "Sucker", 0.06, 0.08, 0.08, at(0.16, y + 0.18, z - 0.27), c.sucker)
	vox(reel, "Sucker", 0.06, 0.08, 0.08, at(0.16, y - 0.06, z - 0.27), c.sucker)
	vox(reel, "Sucker", 0.06, 0.08, 0.08, at(0.16, y - 0.27, z - 0.1), c.sucker)
	return model
end

-- Mythic: white and gold ceremonial rod with clockwork - gear reel, hourglass pommel,
-- a halo floating round the upper rod with clock hands inside it, cyan energy.
function ROD_BUILDERS.ChronosSovereignRod(id)
	local c = {
		white = rgb(246, 246, 252),
		ivory = rgb(226, 224, 238),
		gold = rgb(242, 198, 72),
		dark = rgb(184, 136, 44),
		cyan = rgb(92, 236, 255),
		glass = rgb(176, 236, 250),
		sand = rgb(255, 224, 150),
	}
	local model, handle, shaft, reel = beginRod(id, {
		handle = { 0.36, 0.36, c.white },
		shaft = { 0.26, 0.26, 3.4, c.white },
		reel = { 0.3, 0.46, 0.46, c.gold, y = -0.78, z = -1.05, clear = 0.18 },
		seat = c.gold,
		bracket = c.ivory,
	})

	vox(handle, "GripBand", 0.42, 0.42, 0.1, at(0, 0, -0.3), c.gold)
	vox(handle, "GripBand", 0.42, 0.42, 0.1, at(0, 0, 0.3), c.gold)
	vox(handle, "Guard", 0.52, 0.52, 0.12, at(0, 0, -0.56), c.gold)
	-- Hourglass pommel, lying along the rod.
	vox(handle, "HourglassCap", 0.46, 0.46, 0.08, at(0, 0, 0.64), c.gold)
	vox(handle, "HourglassBulb", 0.3, 0.3, 0.18, at(0, 0, 0.77), c.glass, { alpha = 0.45 })
	vox(handle, "HourglassNeck", 0.12, 0.12, 0.08, at(0, 0, 0.9), c.cyan, NEON)
	vox(handle, "HourglassBulb", 0.3, 0.3, 0.18, at(0, 0, 1.03), c.glass, { alpha = 0.45 })
	vox(handle, "HourglassSand", 0.2, 0.2, 0.1, at(0, 0, 1.06), c.sand)
	vox(handle, "HourglassCap", 0.46, 0.46, 0.08, at(0, 0, 1.16), c.gold)

	for _, z in { -1.65, -2.65, -3.65 } do
		vox(shaft, "Band", 0.32, 0.32, 0.1, at(0, 0, z), c.gold)
	end
	vox(shaft, "EnergyStrip", 0.06, 0.06, 0.8, at(0, 0.14, -2.15), c.cyan, NEON)
	vox(shaft, "EnergyStrip", 0.06, 0.06, 0.8, at(0, 0.14, -3.15), c.cyan, NEON)
	vox(shaft, "ShaftTip", 0.18, 0.18, 1.5, at(0, 0, -4.75), c.ivory)
	vox(shaft, "Finial", 0.26, 0.26, 0.2, at(0, 0, -5.6), c.gold)
	local crystal = vox(shaft, "TipCrystal", 0.14, 0.14, 0.4, at(0, 0, -5.9), c.cyan, NEON)
	attach(crystal, "Tip", V(0, 0, -6.1))
	glow(crystal, c.cyan, 8)

	-- Halo: an octagonal ring floating clear of the upper rod, with hour pips.
	local haloZ, radius = -4.9, 0.56
	local diagonal = radius * math.sqrt(0.5)
	for _, side in { -1, 1 } do
		vox(shaft, "Halo", 0.48, 0.1, 0.1, at(0, side * radius, haloZ), c.gold)
		vox(shaft, "Halo", 0.1, 0.48, 0.1, at(side * radius, 0, haloZ), c.gold)
		vox(shaft, "Halo", 0.48, 0.1, 0.1, at(side * diagonal, side * diagonal, haloZ, 0, 0, -45), c.gold)
		vox(shaft, "Halo", 0.48, 0.1, 0.1, at(side * diagonal, -side * diagonal, haloZ, 0, 0, 45), c.gold)
		vox(shaft, "HaloPip", 0.14, 0.14, 0.14, at(0, side * radius, haloZ), c.cyan, NEON)
		vox(shaft, "HaloPip", 0.14, 0.14, 0.14, at(side * radius, 0, haloZ), c.cyan, NEON)
	end
	-- Clock hands reaching from the rod towards the halo.
	vox(shaft, "HourHand", 0.08, 0.3, 0.05, at(0, 0.24, haloZ), c.dark)
	vox(shaft, "MinuteHand", 0.44, 0.07, 0.05, at(0.29, 0.1, haloZ, 0, 0, 20), c.dark)

	-- A small idler gear fixed under the shaft, meshing with the reel.
	vox(shaft, "IdlerGear", 0.12, 0.32, 0.32, at(0, -0.36, -1.52, 45, 0, 0), c.dark)

	-- Gear reel: four crossed bars give eight teeth round a gold drum.
	local y, z = -0.78, -1.05
	vox(reel, "GearTeeth", 0.22, 0.78, 0.16, at(0, y, z), c.dark)
	vox(reel, "GearTeeth", 0.22, 0.16, 0.78, at(0, y, z), c.dark)
	vox(reel, "GearTeeth", 0.22, 0.78, 0.16, at(0, y, z, 45, 0, 0), c.dark)
	vox(reel, "GearTeeth", 0.22, 0.78, 0.16, at(0, y, z, -45, 0, 0), c.dark)
	vox(reel, "Hub", 0.36, 0.16, 0.16, at(0, y, z), c.cyan, NEON)
	vox(reel, "CrankArm", 0.06, 0.1, 0.4, at(0.22, y, z - 0.12), c.white)
	vox(reel, "CrankKnob", 0.18, 0.12, 0.12, at(0.33, y, z - 0.28), c.ivory)
	return model
end

-- Bait designs ----------------------------------------------------------------------------------
-- Each design is a list of voxels { name, sizeX, sizeY, sizeZ, cframe, color, opts } in any
-- convenient local space; the builder recentres them on the middle of their bounds.

local BAIT_ORDER = { "Earthworm", "KrillPaste", "GlowingFirefly", "SquidInkCapsule", "StarlightRoe" }
local BAIT_DESIGNS = {}

-- A segmented pink-brown worm in an S-curve on a few crumbs of dirt.
function BAIT_DESIGNS.Earthworm()
	local pinkA, pinkB, saddle = rgb(214, 128, 122), rgb(190, 104, 104), rgb(236, 164, 150)
	local dirt, dirtDark = rgb(92, 64, 44), rgb(66, 46, 34)
	local list = {}
	local segments = 7
	for index = 0, segments - 1 do
		local t = index / (segments - 1)
		local angle = t * 2 * math.pi
		local x, z = 0.26 * math.sin(angle), -0.6 + 1.2 * t
		-- Yaw each segment along the curve's tangent.
		local yaw = math.deg(math.atan2(0.26 * 2 * math.pi * math.cos(angle), 1.2))
		local name, size, y, color = "Segment", { 0.26, 0.22, 0.26 }, 0.11, if index % 2 == 0 then pinkA else pinkB
		if index == 0 then
			name, size, y = "Head", { 0.22, 0.2, 0.22 }, 0.15
		elseif index == 2 then
			name, size, y, color = "Saddle", { 0.3, 0.26, 0.24 }, 0.13, saddle
		elseif index == segments - 1 then
			name, size, y = "TailEnd", { 0.2, 0.18, 0.24 }, 0.09
		end
		table.insert(list, { name, size[1], size[2], size[3], at(x, y, z, 0, yaw, 0), color })
	end
	table.insert(list, { "DirtCrumb", 0.14, 0.14, 0.14, at(0.4, 0.07, 0.36, 0, 20, 0), dirt })
	table.insert(list, { "DirtCrumb", 0.1, 0.1, 0.1, at(-0.4, 0.05, -0.2, 0, 35, 0), dirtDark })
	table.insert(list, { "DirtCrumb", 0.12, 0.08, 0.12, at(0.3, 0.04, -0.5, 0, 10, 0), dirt })
	return list
end

-- An open tin of orange-pink paste, lid folded back, three tiny krill on top.
function BAIT_DESIGNS.KrillPaste()
	local tin, tinLight = rgb(156, 170, 186), rgb(196, 206, 218)
	local paste, pasteLight = rgb(255, 146, 118), rgb(255, 176, 150)
	local krill, krillDark = rgb(255, 112, 96), rgb(226, 78, 72)
	local list = {
		{ "TinBase", 0.9, 0.08, 0.9, at(0, 0.04, 0), tin },
		{ "TinWall", 0.9, 0.42, 0.08, at(0, 0.29, -0.41), tin },
		{ "TinWall", 0.9, 0.42, 0.08, at(0, 0.29, 0.41), tin },
		{ "TinWall", 0.08, 0.42, 0.74, at(-0.41, 0.29, 0), tin },
		{ "TinWall", 0.08, 0.42, 0.74, at(0.41, 0.29, 0), tin },
		{ "Paste", 0.74, 0.34, 0.74, at(0, 0.25, 0), paste },
		{ "PasteSwirl", 0.44, 0.1, 0.44, at(0, 0.46, 0, 0, 20, 0), pasteLight },
		-- Lid hinged on the back wall, opened 70 degrees.
		{ "Lid", 0.9, 0.06, 0.9, at(0, 0.923, 0.604, -70, 0, 0), tinLight },
	}
	for _, k in { { -0.17, 0.5, -0.14, 30 }, { 0.2, 0.5, 0.1, -55 }, { -0.02, 0.56, 0.1, 100 } } do
		local body = at(k[1], k[2], k[3], 0, k[4], 0)
		table.insert(list, { "KrillBody", 0.1, 0.1, 0.24, body, krill })
		table.insert(list, { "KrillTail", 0.08, 0.08, 0.12, body * at(0, -0.02, 0.16, -35, 0, 0), krillDark })
	end
	return list
end

-- A firefly: dark body, translucent wings, neon yellow-green abdomen. Faces -Z.
function BAIT_DESIGNS.GlowingFirefly()
	local dark, darker, wingCase = rgb(34, 30, 40), rgb(22, 20, 28), rgb(96, 40, 36)
	local amber, glowA, glowB = rgb(255, 170, 60), rgb(196, 255, 72), rgb(150, 235, 40)
	local wing = rgb(214, 236, 255)
	local list = {
		{ "Thorax", 0.32, 0.28, 0.34, at(0, 0, -0.12), dark },
		{ "Head", 0.26, 0.22, 0.2, at(0, -0.02, -0.39), darker },
		{ "Abdomen", 0.36, 0.32, 0.46, at(0, -0.02, 0.28), glowA, NEON },
		{ "AbdomenTip", 0.26, 0.22, 0.2, at(0, -0.04, 0.61), glowB, NEON },
	}
	for _, side in { -1, 1 } do
		table.insert(list, { "Eye", 0.08, 0.1, 0.1, at(side * 0.14, 0, -0.43), amber })
		table.insert(
			list,
			{ "Wing", 0.5, 0.04, 0.32, at(side * 0.36, 0.22, 0.12, 0, -side * 20, side * 18), wing, { alpha = 0.5 } }
		)
		table.insert(list, { "WingCase", 0.14, 0.05, 0.44, at(side * 0.2, 0.2, 0.1, 20, -side * 15, 0), wingCase })
		local from, to = V(side * 0.07, 0.08, -0.47), V(side * 0.16, 0.2, -0.68)
		table.insert(list, { "Antenna", 0.04, 0.04, (to - from).Magnitude, CFrame.lookAt((from + to) / 2, to), dark })
	end
	return list
end

-- A corked glass vial of black-violet ink with a small tentacle curled up its side.
function BAIT_DESIGNS.SquidInkCapsule()
	local metal, glass = rgb(58, 52, 84), rgb(198, 222, 240)
	local ink, sheen = rgb(20, 12, 38), rgb(88, 48, 150)
	local cork, corkDark = rgb(196, 154, 104), rgb(160, 120, 78)
	local tentacle, sucker = rgb(120, 70, 170), rgb(214, 180, 240)
	return {
		{ "Base", 0.66, 0.1, 0.66, at(0, 0.05, 0), metal },
		{ "Glass", 0.6, 0.86, 0.6, at(0, 0.53, 0), glass, { alpha = 0.6 } },
		{ "Ink", 0.46, 0.56, 0.46, at(0, 0.4, 0), ink },
		{ "InkSheen", 0.46, 0.06, 0.46, at(0, 0.71, 0), sheen },
		{ "Neck", 0.4, 0.12, 0.4, at(0, 1.02, 0), metal },
		{ "Cork", 0.32, 0.2, 0.32, at(0, 1.18, 0), cork },
		{ "CorkTop", 0.38, 0.08, 0.38, at(0, 1.32, 0), corkDark },
		-- Tentacle: up the side, forward, down, and curled back in.
		{ "Tentacle", 0.14, 0.4, 0.14, at(0.37, 0.3, -0.05), tentacle },
		{ "Tentacle", 0.14, 0.14, 0.42, at(0.37, 0.57, -0.19), tentacle },
		{ "Tentacle", 0.14, 0.16, 0.14, at(0.37, 0.42, -0.33), tentacle },
		{ "TentacleTip", 0.1, 0.1, 0.1, at(0.37, 0.39, -0.22), tentacle },
		{ "Sucker", 0.05, 0.07, 0.07, at(0.455, 0.22, -0.05), sucker },
		{ "Sucker", 0.05, 0.07, 0.07, at(0.455, 0.38, -0.05), sucker },
	}
end

-- Pearlescent purple-blue roe clustered round a neon star, with gold sparkles.
function BAIT_DESIGNS.StarlightRoe()
	local star, ray, sparkle = rgb(255, 236, 160), rgb(255, 246, 204), rgb(255, 214, 90)
	local roe = { rgb(150, 112, 255), rgb(112, 140, 255), rgb(196, 150, 255) }
	local list = {
		{ "StarCore", 0.34, 0.34, 0.34, at(0, 0, 0), star, NEON },
		{ "StarRay", 0.9, 0.12, 0.12, at(0, 0, 0), ray, NEON },
		{ "StarRay", 0.12, 0.9, 0.12, at(0, 0, 0), ray, NEON },
		{ "StarRay", 0.12, 0.12, 0.9, at(0, 0, 0), ray, NEON },
		{ "Sparkle", 0.08, 0.08, 0.08, at(0.48, 0.42, 0.1), sparkle, NEON },
		{ "Sparkle", 0.08, 0.08, 0.08, at(-0.46, -0.3, 0.44), sparkle, NEON },
		{ "Sparkle", 0.08, 0.08, 0.08, at(0.1, 0.5, -0.48), sparkle, NEON },
	}
	-- One egg per corner of a cube; the front upper-right corner is left open to show the star.
	local index = 0
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				if not (sx == 1 and sy == 1 and sz == -1) then
					index += 1
					local size = 0.28 + 0.03 * (index % 3)
					table.insert(list, {
						"Roe",
						size,
						size,
						size,
						at(sx * 0.27, sy * 0.27, sz * 0.27, 12 * index, 17 * index, 0),
						roe[index % 3 + 1],
						{ alpha = 0.2, shine = 0.25 },
					})
				end
			end
		end
	end
	return list
end

-- Classic red-over-white float. Model space origin = the waterline centre.
local BOBBER_DESIGN = {
	{ "FloatRed", 0.8, 0.32, 0.8, at(0, 0.16, 0), rgb(222, 48, 48) },
	{ "FloatRedCap", 0.5, 0.12, 0.5, at(0, 0.38, 0), rgb(222, 48, 48) },
	{ "FloatWhite", 0.8, 0.32, 0.8, at(0, -0.16, 0), rgb(245, 245, 245) },
	{ "FloatWhiteCap", 0.5, 0.12, 0.5, at(0, -0.38, 0), rgb(245, 245, 245) },
	{ "Waterline", 0.9, 0.07, 0.9, at(0, 0, 0), rgb(40, 40, 52) },
	{ "Antenna", 0.1, 0.28, 0.1, at(0, 0.58, 0), rgb(255, 96, 60) },
	{ "Ring", 0.06, 0.14, 0.2, at(0, -0.51, 0), rgb(170, 174, 184) },
}

-- Root-and-voxels models (baits, bobber) ----------------------------------------------------------

-- World-space bounds of a voxel list (rotated voxels included).
local function boundsOf(list)
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	for _, v in list do
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				for _, sz in { -0.5, 0.5 } do
					local corner = v[5] * V(v[2] * sx, v[3] * sy, v[4] * sz)
					local xyz = { corner.X, corner.Y, corner.Z }
					for axis = 1, 3 do
						lo[axis] = math.min(lo[axis], xyz[axis])
						hi[axis] = math.max(hi[axis], xyz[axis])
					end
				end
			end
		end
	end
	return V(lo[1], lo[2], lo[3]), V(hi[1], hi[2], hi[3])
end

-- `offset` is subtracted from every voxel; RootPart sits on the origin.
local function buildRooted(name, list, rootSize, offset)
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("RigVersion", RIG_VERSION)
	model:SetAttribute("GeneratedBy", GENERATOR)

	local root = makePart(model, "RootPart", rootSize.X, rootSize.Y, rootSize.Z, at(0, 0, 0), rgb(255, 255, 255))
	root.Transparency = 1
	root.Anchored = true
	model.PrimaryPart = root

	local shift = CFrame.new(-offset.X, -offset.Y, -offset.Z)
	local parts = {}
	for _, v in list do
		local part = makePart(model, v[1], v[2], v[3], v[4], shift * v[5], v[6], v[7])
		weld(root, part)
		parts[v[1]] = part
	end
	return model, parts
end

local function buildBait(id)
	local list = BAIT_DESIGNS[id]()
	local lo, hi = boundsOf(list)
	local model = buildRooted(id, list, hi - lo, (lo + hi) / 2)
	model:SetAttribute("BaitId", id)
	return model
end

local function buildBobber()
	local model, parts = buildRooted("Bobber", BOBBER_DESIGN, V(0.9, 1.3, 0.9), V(0, 0, 0))
	model:SetAttribute("PropId", "Bobber")
	local antenna = parts.Antenna
	attach(antenna, "Line", antenna.CFrame.Position + V(0, antenna.Size.Y / 2, 0))
	return model
end

-- Build -----------------------------------------------------------------------------------------

local function ensureFolder(parent, name)
	local found = parent:FindFirstChild(name)
	if not found then
		found = Instance.new("Folder")
		found.Name = name
		found.Parent = parent
	end
	return found
end

-- Builds one model into `folder` unless a model this script did not generate is in the way.
local function place(folder, name, build, notes)
	local existing = folder:FindFirstChild(name)
	if existing and existing:GetAttribute("GeneratedBy") ~= GENERATOR then
		table.insert(notes, `{name} SKIPPED (existing model was not generated by {GENERATOR})`)
		return
	end
	local model = build(name)
	if existing then
		existing:Destroy()
	end
	model.Parent = folder
	table.insert(notes, `{name} {countParts(model)}`)
end

local rodNotes, baitNotes, propNotes = {}, {}, {}
local function buildAll()
	local assets = ensureFolder(ReplicatedStorage, "Assets")
	local rods = ensureFolder(assets, "Rods")
	local baits = ensureFolder(assets, "Baits")
	local props = ensureFolder(assets, "Props")

	for _, id in ROD_ORDER do
		place(rods, id, ROD_BUILDERS[id], rodNotes)
	end
	for _, id in BAIT_ORDER do
		place(baits, id, buildBait, baitNotes)
	end
	place(props, "Bobber", buildBobber, propNotes)
end

local recording = ChangeHistoryService:TryBeginRecording("Build fishing gear (rods, baits, bobber)")
local ok, problem = pcall(buildAll)
if recording then
	ChangeHistoryService:FinishRecording(
		recording,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
end
if not ok then
	error(problem, 0)
end

print(
	`[BuildGear] parts per model - Rods: {table.concat(rodNotes, ", ")} | Baits: {table.concat(baitNotes, ", ")} | Props: {table.concat(
		propNotes,
		", "
	)}`
)
