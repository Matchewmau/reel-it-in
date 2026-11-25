--[[
	VoxelMorph creature builder: designs, models and rigs for the roster.

	HOW TO RUN (edit mode): pass this file to the Studio MCP `execute_luau` tool,
	or paste it into the Command Bar. It creates no scripts. Output:

	  ReplicatedStorage/Assets/Creatures/<Biome>/<SpeciesId>   (Model, one per species)

	Every model follows the rig standard in CLAUDE.md / GDD section 6:
	  RootPart (anchored, invisible, AuraAttachment) -> Body -> Head [-> Jaw]
	                                                  Body -> Tail [-> Tail2 -> Tail3] -> TailFin
	                                                  Body -> LeftFin, RightFin, DorsalFin
	  * faces -Z, one Motor6D per bone named after its Part1, pivot at the hinge
	  * decorative voxels are children of their bone, joined by WeldConstraints

	HOW A CREATURE IS DESIGNED
	  Each species is a `fish{...}` spec: proportions for the standard bones plus
	  `extras`, lists of voxels that give it its silhouette (snout, gills, horns,
	  spikes, markings). Designs are authored in arbitrary "design units"; the
	  builder scales the finished model so its nose-to-tail length equals
	  `length`, which must match the species' `length` in Creatures.luau.

	  Voxel tuple: { sizeX, sizeY, sizeZ,  x, y, z,  colorKey, flags }
	    position is relative to the centre of the bone it is listed under
	    flags: "m" also add a copy mirrored across X   "n" Neon (authored glow)
	  Colour keys: P/S/A = the species palette from Creatures.luau
	               (primary / secondary / accent); K black, W white, T tooth;
	               anything else is defined in the spec's `colors`.

	The Abyssal Angler keeps its own hand-built script (BuildAbyssalAngler.luau).
	Models this script did not generate are never overwritten.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GENERATOR = "BuildCreatures"
local V = Vector3.new
local rgb = Color3.fromRGB

local SHARED_COLORS = {
	K = rgb(18, 18, 24),
	W = rgb(250, 250, 255),
	T = rgb(240, 226, 170),
}

-- Rig intermediate representation ------------------------------------------------------

local function newRig(spec)
	local rig = { spec = spec, bones = {}, order = {} }
	function rig.bone(name, parent, pivot, size, pos, color)
		local bone = { name = name, parent = parent, pivot = pivot, size = size, pos = pos, color = color, voxels = {} }
		rig.bones[name] = bone
		table.insert(rig.order, bone)
		return bone
	end
	return rig
end

-- Adds voxel tuples to a bone. `flipX` negates X (used to mirror fin extras).
local function addVoxels(bone, list, flipX)
	if not bone or not list then
		return
	end
	for _, v in list do
		local flags = v[8] or ""
		local x = if flipX then -v[4] else v[4]
		local size = V(v[1], v[2], v[3])
		local neon = string.find(flags, "n") ~= nil
		table.insert(bone.voxels, { size = size, pos = bone.pos + V(x, v[5], v[6]), color = v[7], neon = neon })
		if string.find(flags, "m") then
			table.insert(bone.voxels, { size = size, pos = bone.pos + V(-x, v[5], v[6]), color = v[7], neon = neon })
		end
	end
end

-- The standard fish template ---------------------------------------------------------------

local function fish(spec)
	local rig = newRig(spec)
	local bw, bh, bl = spec.body[1], spec.body[2], spec.body[3]
	local thin = spec.thin or math.max(0.3, bw * 0.1)
	local finColor = spec.finColor or "A"

	-- Body
	local body = rig.bone("Body", "RootPart", V(0, 0, 0), V(bw, bh, bl), V(0, 0, 0), spec.bodyColor or "P")
	if spec.belly ~= false then
		addVoxels(body, { { bw * 0.86, bh * 0.28, bl * 0.94, 0, -bh * 0.4, 0, spec.bellyColor or "S" } })
	end

	-- Head (+ optional hinged jaw)
	local hw, hh, hl = spec.head[1], spec.head[2], spec.head[3]
	local hy = spec.headY or 0
	local head =
		rig.bone("Head", "Body", V(0, hy, -bl / 2), V(hw, hh, hl), V(0, hy, -bl / 2 - hl / 2), spec.headColor or "P")
	local eye = spec.eye
	if eye ~= false then
		eye = eye or {}
		local size = eye[1] or hh * 0.28
		local ey, ez = eye[2] or hh * 0.12, eye[3] or -hl * 0.15
		if eye.color then
			addVoxels(head, { { 0.25, size, size, hw / 2 + 0.05, ey, ez, eye.color, if eye.neon then "mn" else "m" } })
		else
			addVoxels(head, {
				{ 0.2, size, size, hw / 2 + 0.02, ey, ez, "W", "m" },
				{ 0.22, size * 0.55, size * 0.55, hw / 2 + 0.06, ey, ez - size * 0.1, "K", "m" },
			})
		end
	end
	if spec.jaw then
		local jh, jl = spec.jaw[1], spec.jaw[2]
		local jw = spec.jawWidth or hw * 0.94
		local jy = hy - hh / 2 - jh / 2 + (spec.jawOverlap or 0.25)
		local jz = -bl / 2 - jl / 2 - (spec.jawShift or 0)
		rig.bone("Jaw", "Head", V(0, jy + jh / 2, -bl / 2), V(jw, jh, jl), V(0, jy, jz), spec.jawColor or "S")
	end

	-- Tail chain: Tail, Tail2, Tail3...
	local tw, th, tl = spec.tail[1], spec.tail[2], spec.tail[3]
	local segments = spec.tailSegments or 1
	local taper = spec.taper or 0.8
	local z = bl / 2
	local previous = "Body"
	for index = 1, segments do
		local name = if index == 1 then "Tail" else "Tail" .. index
		local factor = taper ^ (index - 1)
		rig.bone(
			name,
			previous,
			V(0, 0, z),
			V(tw * factor, th * factor, tl),
			V(0, 0, z + tl / 2),
			spec.tailColor or "P"
		)
		z += tl
		previous = name
	end

	-- Tail fin: "fork" (two lobes), "round" (single paddle) or "fluke" (horizontal, whale-like)
	if spec.tailFin then
		local fh, fl = spec.tailFin[1], spec.tailFin[2]
		local style = spec.tailStyle or "fork"
		local tailFinColor = spec.tailFinColor or finColor
		if style == "fluke" then
			local bone = rig.bone(
				"TailFin",
				previous,
				V(0, 0, z),
				V(fh * 0.45, thin, fl * 0.5),
				V(0, 0, z + fl * 0.25),
				tailFinColor
			)
			addVoxels(bone, { { fh * 0.34, thin, fl * 0.65, fh * 0.36, 0, fl * 0.45, tailFinColor, "m" } })
		elseif style == "round" then
			local bone =
				rig.bone("TailFin", previous, V(0, 0, z), V(thin, fh, fl * 0.7), V(0, 0, z + fl * 0.35), tailFinColor)
			addVoxels(bone, { { thin, fh * 0.62, fl * 0.3, 0, 0, fl * 0.5, tailFinColor } })
		else
			local bone = rig.bone(
				"TailFin",
				previous,
				V(0, 0, z),
				V(thin, fh * 0.5, fl * 0.5),
				V(0, 0, z + fl * 0.25),
				tailFinColor
			)
			addVoxels(bone, {
				{ thin, fh * 0.3, fl * 0.62, 0, fh * 0.36, fl * 0.44, tailFinColor },
				{ thin, fh * 0.3, fl * 0.62, 0, -fh * 0.36, fl * 0.44, tailFinColor },
			})
		end
	end

	-- Dorsal fin
	local dh, dl, dz = spec.dorsal[1], spec.dorsal[2], spec.dorsal[3]
	rig.bone(
		"DorsalFin",
		"Body",
		V(0, bh / 2, dz),
		V(thin, dh, dl),
		V(0, bh / 2 + dh / 2, dz),
		spec.dorsalColor or finColor
	)

	-- Pectoral fins (wings / legs for some species)
	local pl, pw, pz, py = spec.pectoral[1], spec.pectoral[2], spec.pectoral[3], spec.pectoral[4]
	local pt = spec.finThick or thin
	local px = bw / 2 + pl / 2
	local left = rig.bone("LeftFin", "Body", V(-bw / 2, py, pz), V(pl, pt, pw), V(-px, py, pz), finColor)
	local right = rig.bone("RightFin", "Body", V(bw / 2, py, pz), V(pl, pt, pw), V(px, py, pz), finColor)
	addVoxels(left, spec.finExtras, false)
	addVoxels(right, spec.finExtras, true)

	for boneName, list in spec.extras or {} do
		assert(rig.bones[boneName], `{spec.id}: extras reference missing bone {boneName}`)
		addVoxels(rig.bones[boneName], list, false)
	end
	return rig
end

-- Species designs ----------------------------------------------------------------------------

local SPECIES = {
	-- FRESHWATER -------------------------------------------------------------------------------
	fish({
		-- Slim silver darter with a dark lateral stripe.
		id = "RiverMinnow",
		biome = "Freshwater",
		length = 1.6,
		colors = { P = rgb(160, 178, 190), S = rgb(226, 232, 236), A = rgb(90, 120, 140) },
		body = { 2, 2.8, 6 },
		head = { 1.8, 2.4, 2.2 },
		tail = { 1.3, 1.8, 2 },
		tailFin = { 3.2, 1.8 },
		dorsal = { 1.1, 2, 0.4 },
		pectoral = { 1.2, 1, -1.8, -0.7 },
		eye = { 0.75, 0.3, -0.3 },
		extras = {
			Body = { { 0.15, 0.5, 5.2, 1.0, 0.35, 0, "A", "m" } },
			Head = { { 1.3, 1.4, 0.6, 0, -0.2, -1.4, "S" } },
		},
	}),
	fish({
		-- White koi with orange saddles, black spots and little barbels.
		id = "SpottedKoi",
		biome = "Freshwater",
		length = 2.6,
		colors = { P = rgb(255, 132, 38), S = rgb(250, 246, 240), A = rgb(30, 30, 34) },
		body = { 3, 3.4, 6.4 },
		bodyColor = "S",
		headColor = "S",
		tailColor = "S",
		belly = false,
		finColor = "P",
		head = { 2.8, 3, 2.6 },
		tail = { 1.9, 2.3, 2.4 },
		tailFin = { 4.6, 2.8 },
		dorsal = { 1.2, 3.6, 0 },
		pectoral = { 1.8, 1.5, -2, -1 },
		extras = {
			Head = {
				{ 2.2, 0.5, 2, 0, 1.45, 0.1, "P" },
				{ 0.25, 0.25, 0.9, 0.9, -1.2, -1.5, "P", "m" },
			},
			Body = {
				{ 3.3, 1.5, 2.2, 0, 1.1, -1.6, "P" },
				{ 3.3, 1.3, 1.8, 0, 1.2, 1.7, "P" },
				{ 0.2, 1.4, 1.4, 1.55, -0.2, 0.3, "P", "m" },
				{ 0.2, 0.6, 0.6, 1.72, 0.9, -1.2, "K", "m" },
				{ 0.2, 0.5, 0.5, 1.55, -0.6, 2, "K", "m" },
				{ 0.7, 0.2, 0.7, 0.5, 1.92, -1.6, "K" },
				{ 0.6, 0.2, 0.6, -0.4, 1.92, 1.9, "K" },
			},
			Tail = { { 2.1, 2.5, 0.8, 0, 0, 0.3, "P" } },
		},
	}),
	fish({
		-- Long armoured body and a toothy, crocodile-like snout.
		id = "AlligatorGar",
		biome = "Freshwater",
		length = 5.2,
		colors = { P = rgb(92, 110, 72), S = rgb(196, 190, 150), A = rgb(52, 62, 44) },
		body = { 2.6, 2.6, 9 },
		head = { 2.4, 2.2, 2.4 },
		jaw = { 0.6, 6.2 },
		jawWidth = 1.5,
		tail = { 1.9, 2, 2.6 },
		tailFin = { 3.4, 2.2 },
		tailStyle = "round",
		dorsal = { 1.1, 1.8, 3.4 },
		pectoral = { 1.4, 1.1, -3.4, -1 },
		eye = { 0.55, 0.45, 0.2 },
		extras = {
			Head = {
				{ 1.5, 0.8, 4, 0, -0.35, -3.2, "P" },
				{ 1.5, 0.4, 0.6, 0, 0.25, -4.9, "A" },
				{ 0.18, 0.45, 0.18, 0.6, -0.95, -2, "T", "m" },
				{ 0.18, 0.45, 0.18, 0.6, -0.95, -3, "T", "m" },
				{ 0.18, 0.45, 0.18, 0.6, -0.95, -4, "T", "m" },
				{ 0.18, 0.45, 0.18, 0.6, -0.95, -5, "T", "m" },
			},
			Jaw = {
				{ 0.18, 0.4, 0.18, 0.55, 0.5, -2.6, "T", "m" },
				{ 0.18, 0.4, 0.18, 0.55, 0.5, -1.6, "T", "m" },
				{ 0.18, 0.4, 0.18, 0.55, 0.5, -0.6, "T", "m" },
				{ 0.18, 0.4, 0.18, 0.55, 0.5, 0.4, "T", "m" },
			},
			Body = {
				{ 1.6, 0.35, 1.4, 0, 1.45, -3, "A" },
				{ 1.6, 0.35, 1.4, 0, 1.45, -1, "A" },
				{ 1.6, 0.35, 1.4, 0, 1.45, 1, "A" },
				{ 1.6, 0.35, 1.4, 0, 1.45, 3, "A" },
				{ 0.15, 0.8, 7.6, 1.32, 0.2, 0, "A", "m" },
			},
		},
	}),
	fish({
		-- Wide-headed pink walker with feathery gills and glowing crystal growths.
		id = "CrystalAxolotl",
		biome = "Freshwater",
		length = 2.8,
		colors = { P = rgb(255, 170, 210), S = rgb(255, 224, 240), A = rgb(120, 230, 255), D = rgb(235, 110, 170) },
		body = { 3, 2.4, 5 },
		head = { 4.2, 2.6, 3 },
		tail = { 1.6, 2.2, 2.6 },
		tailSegments = 2,
		tailFin = { 3, 2.4 },
		tailStyle = "round",
		tailFinColor = "S",
		dorsal = { 0.9, 5.5, 1.2 },
		dorsalColor = "A",
		finColor = "P",
		finThick = 0.7,
		pectoral = { 1.6, 0.8, -1.5, -1 },
		eye = { 0.5, 0.4, -0.9, color = "K" },
		extras = {
			Head = {
				{ 1.4, 0.4, 0.4, 2.7, 1.0, 0.5, "D", "m" },
				{ 1.6, 0.4, 0.4, 2.8, 0.2, 0.8, "D", "m" },
				{ 1.4, 0.4, 0.4, 2.7, -0.6, 0.5, "D", "m" },
				{ 0.4, 0.5, 0.5, 3.5, 1.0, 0.5, "A", "mn" },
				{ 0.4, 0.5, 0.5, 3.7, 0.2, 0.8, "A", "mn" },
				{ 0.4, 0.5, 0.5, 3.5, -0.6, 0.5, "A", "mn" },
				{ 2.4, 0.2, 0.2, 0, -0.6, -1.52, "D" },
			},
			Body = {
				{ 1.5, 0.7, 0.8, 2.1, -1, 1.6, "P", "m" },
				{ 0.5, 0.6, 0.5, 0.9, 1.4, -0.8, "A", "mn" },
				{ 0.6, 0.9, 0.6, 0, 1.5, -1.9, "A", "n" },
			},
		},
	}),
	fish({
		-- Broad storm-grey bruiser: flat head, long barbels, lightning down its flanks.
		id = "ThunderheadCatfish",
		biome = "Freshwater",
		length = 6.0,
		colors = { P = rgb(70, 78, 96), S = rgb(150, 160, 180), A = rgb(255, 240, 110), D = rgb(46, 52, 68) },
		body = { 4, 3.4, 7 },
		head = { 5, 2.8, 3.2 },
		headY = -0.2,
		jaw = { 0.7, 3.4 },
		tail = { 2.6, 2.8, 3 },
		tailFin = { 4.8, 2.6 },
		dorsal = { 2.8, 2.4, -0.6 },
		finColor = "D",
		pectoral = { 2.2, 1.8, -2.4, -1.2 },
		eye = { 0.6, 0.7, -0.6, color = "A", neon = true },
		extras = {
			Head = {
				{ 2.6, 0.28, 0.28, 3.6, -1.0, -1.2, "S", "m" },
				{ 0.28, 0.28, 2.2, 4.8, -1.0, -0.2, "S", "m" },
				{ 0.25, 1.2, 0.25, 0.9, -2.2, -1.2, "S", "m" },
				{ 4.2, 0.4, 2.4, 0, 1.5, 0.2, "D" },
			},
			Body = {
				{ 0.2, 0.5, 1.6, 2.05, 0.8, -1.8, "A", "mn" },
				{ 0.2, 1.2, 0.5, 2.05, 0.3, -0.9, "A", "mn" },
				{ 0.2, 0.5, 1.6, 2.05, -0.2, 0, "A", "mn" },
				{ 0.2, 1.0, 0.5, 2.05, -0.6, 0.9, "A", "mn" },
				{ 2.8, 0.4, 6, 0, 1.85, 0, "D" },
			},
			DorsalFin = { { 0.45, 0.8, 1.0, 0, 1.6, 0.4, "A", "n" } },
		},
	}),
	fish({
		-- Serpentine jade dragon: antlers, whiskers, a pale mane and gold rings.
		id = "JadeRiverDragon",
		biome = "Freshwater",
		length = 8.0,
		colors = { P = rgb(40, 170, 120), S = rgb(190, 240, 200), A = rgb(255, 208, 70), D = rgb(24, 110, 80) },
		body = { 3, 3, 6 },
		head = { 3.2, 2.8, 3.2 },
		jaw = { 0.7, 4.8 },
		jawWidth = 2.2,
		tail = { 2.7, 2.7, 5 },
		tailSegments = 3,
		taper = 0.82,
		tailFin = { 4, 3 },
		dorsal = { 1.4, 5.2, 0 },
		dorsalColor = "S",
		finColor = "A",
		finThick = 0.8,
		pectoral = { 1.6, 0.9, -1.8, -1.3 },
		eye = { 0.6, 0.6, -0.4, color = "A", neon = true },
		extras = {
			Head = {
				{ 2.3, 1.6, 1.8, 0, -0.3, -2.5, "P" },
				{ 0.4, 0.3, 0.3, 0.6, 0.6, -3.2, "D", "m" },
				{ 0.5, 1.4, 0.5, 1, 2, 0.8, "A", "m" },
				{ 0.5, 0.5, 1.8, 1, 2.6, 1.6, "A", "m" },
				{ 0.4, 0.9, 0.4, 1, 3.2, 2.2, "A", "m" },
				{ 2.2, 0.22, 0.22, 2.6, -0.5, -3, "A", "m" },
				{ 0.22, 0.22, 2, 3.6, -0.5, -2.1, "A", "m" },
				{ 3.4, 0.5, 1, 0, 1.5, -0.6, "D" },
			},
			Jaw = {
				{ 0.2, 0.4, 0.2, 0.8, 0.5, -1.8, "T", "m" },
				{ 0.2, 0.4, 0.2, 0.8, 0.5, -1.0, "T", "m" },
			},
			Body = { { 3.15, 3.15, 0.5, 0, 0, 2.4, "A" } },
			Tail = {
				{ 0.5, 1.0, 3.6, 0, 1.8, 0, "S" },
				{ 1.5, 0.8, 0.9, 2.0, -1.2, 1, "A", "m" },
			},
			Tail2 = {
				{ 0.4, 0.8, 3.4, 0, 1.5, 0, "S" },
				{ 2.4, 2.4, 0.4, 0, 0, 2, "A" },
			},
			Tail3 = { { 0.35, 0.6, 3, 0, 1.25, 0, "S" } },
		},
	}),

	-- SALTWATER --------------------------------------------------------------------------------
	fish({
		-- Orange reef fish with three white bands trimmed in black.
		id = "Clownfish",
		biome = "Saltwater",
		length = 1.6,
		colors = { P = rgb(255, 120, 30), S = rgb(255, 255, 255), A = rgb(24, 24, 28) },
		body = { 2.6, 3.4, 5 },
		belly = false,
		finColor = "P",
		head = { 2.4, 3, 2 },
		tail = { 1.6, 2.2, 1.5 },
		tailFin = { 3.2, 1.8 },
		tailStyle = "round",
		dorsal = { 1.2, 3.2, 0 },
		pectoral = { 1.4, 1.3, -1.4, -0.9 },
		finExtras = { { 0.4, 0.34, 1.3, -0.6, 0, 0, "K" } },
		extras = {
			Body = {
				{ 2.8, 3.6, 0.9, 0, 0, -1.5, "S" },
				{ 2.8, 3.6, 0.9, 0, 0, 1.2, "S" },
				{ 2.82, 3.62, 0.2, 0, 0, -2.05, "K" },
				{ 2.82, 3.62, 0.2, 0, 0, -0.95, "K" },
				{ 2.82, 3.62, 0.2, 0, 0, 0.65, "K" },
				{ 2.82, 3.62, 0.2, 0, 0, 1.75, "K" },
			},
			Head = {
				{ 2.6, 3.2, 0.6, 0, 0, 0.5, "S" },
				{ 2.62, 3.22, 0.15, 0, 0, 0.12, "K" },
			},
			Tail = { { 1.8, 2.4, 0.5, 0, 0, 0.3, "S" } },
			DorsalFin = { { 0.34, 0.3, 3.2, 0, 0.7, 0, "K" } },
		},
	}),
	fish({
		-- Round, spiky and permanently surprised.
		id = "Pufferfish",
		biome = "Saltwater",
		length = 2.2,
		colors = { P = rgb(236, 210, 110), S = rgb(255, 248, 220), A = rgb(120, 92, 40) },
		body = { 5, 5, 5 },
		belly = false,
		finColor = "P",
		head = { 3.8, 3.6, 1.4 },
		headY = 0.2,
		tail = { 1.4, 1.6, 1.2 },
		tailFin = { 2.2, 1.4 },
		tailStyle = "round",
		dorsal = { 1, 1.4, 1.8 },
		pectoral = { 1.2, 1.4, -0.4, -0.2 },
		eye = { 1.3, 0.5, -0.1 },
		extras = {
			Body = {
				-- Three overlapping slabs round the cube off into a ball.
				{ 5.6, 3.4, 3.4, 0, 0.2, 0, "P" },
				{ 3.4, 5.6, 3.4, 0, 0, 0, "P" },
				{ 3.4, 3.4, 5.6, 0, 0.2, 0, "P" },
				{ 5.2, 1.4, 5.2, 0, -1.7, 0, "S" },
				{ 3.2, 0.5, 3.2, 0, -2.7, 0, "S" },
				{ 0.4, 0.9, 0.4, 1.2, 3.0, -1.2, "A", "m" },
				{ 0.4, 0.9, 0.4, 1.2, 3.0, 1.2, "A", "m" },
				-- Side spikes sit in a diamond: two-above-one-below read as a face.
				{ 0.9, 0.4, 0.4, 3.1, 1.5, 0, "A", "m" },
				{ 0.9, 0.4, 0.4, 3.1, 0.1, -1.5, "A", "m" },
				{ 0.9, 0.4, 0.4, 3.1, 0.1, 1.5, "A", "m" },
				{ 0.9, 0.4, 0.4, 3.1, -1.3, 0, "A", "m" },
				{ 0.4, 0.8, 0.4, 1.2, -3.1, -1.0, "A", "m" },
				{ 0.4, 0.8, 0.4, 1.2, -3.1, 1.0, "A", "m" },
				{ 0.4, 0.4, 0.8, 1.2, 1.0, 3.0, "A", "m" },
			},
			Head = { { 1.4, 0.9, 0.5, 0, -0.9, -0.9, "S" } },
		},
	}),
	fish({
		-- Pale pink deep-sea shark: blade-like rostrum and a jaw that juts forward.
		id = "GoblinShark",
		biome = "Saltwater",
		length = 6.5,
		colors = { P = rgb(226, 164, 170), S = rgb(244, 214, 216), A = rgb(110, 70, 84) },
		body = { 3, 3, 8 },
		head = { 2.8, 2.4, 2.8 },
		headY = 0.1,
		jaw = { 0.7, 3.4 },
		jawWidth = 2.0,
		jawShift = 0.8,
		tail = { 2.1, 2.2, 2.8 },
		tailSegments = 2,
		taper = 0.75,
		tailFin = { 2.4, 1.6 },
		tailStyle = "round",
		dorsal = { 2.2, 2.2, -0.8 },
		pectoral = { 2.6, 1.8, -2.4, -1.1 },
		finExtras = { { 1.2, 0.3, 1.2, -1.6, 0, 0.5, "A" } },
		eye = { 0.45, 0.2, -0.6, color = "K" },
		extras = {
			Head = {
				{ 2, 0.6, 4.6, 0, 0.9, -3.4, "P" },
				{ 1.6, 0.3, 4, 0, 0.5, -3.2, "S" },
				{ 0.15, 1.2, 0.2, 1.42, -0.1, 0.5, "A", "m" },
				{ 0.15, 1.2, 0.2, 1.42, -0.1, 0.9, "A", "m" },
				{ 0.16, 0.6, 0.16, 0.5, -1.4, -1.0, "T", "m" },
				{ 0.16, 0.5, 0.16, 0.9, -1.4, -0.4, "T", "m" },
			},
			Jaw = {
				{ 0.16, 0.7, 0.16, 0.3, 0.6, -1.4, "T", "m" },
				{ 0.16, 0.7, 0.16, 0.8, 0.6, -1.3, "T", "m" },
				{ 0.16, 0.6, 0.16, 0.85, 0.55, -0.6, "T", "m" },
				{ 0.16, 0.5, 0.16, 0.85, 0.5, 0.1, "T", "m" },
			},
			DorsalFin = { { 0.3, 1.0, 1.2, 0, 1.5, 0.4, "A" } },
			Tail = { { 0.3, 1, 1.2, 0, 1.5, 0.4, "A" } },
			TailFin = {
				{ 0.3, 1.4, 2.2, 0, 1.5, 1.2, "A" },
				{ 0.3, 1.0, 1.8, 0, 2.4, 2.4, "A" },
				{ 0.3, 0.8, 1, 0, -1.2, 0.4, "A" },
			},
		},
	}),
	fish({
		-- Flat ghostly glider: the "fins" are its wings, with glowing spectral markings.
		id = "PhantomMantaRay",
		biome = "Saltwater",
		length = 7.0,
		colors = { P = rgb(56, 66, 120), S = rgb(170, 190, 255), A = rgb(120, 255, 240) },
		body = { 6, 1.6, 6 },
		head = { 4, 1.4, 1.4 },
		tail = { 0.7, 0.7, 4 },
		tailSegments = 2,
		taper = 0.7,
		tailFin = { 1.0, 1.0 },
		tailStyle = "round",
		tailFinColor = "S",
		dorsal = { 0.8, 1.4, 2.4 },
		dorsalColor = "S",
		finColor = "P",
		finThick = 0.5,
		pectoral = { 5, 5, 0.2, 0 },
		finExtras = {
			{ 2.6, 0.4, 3, -3.6, 0, 0.9, "P" },
			{ 1.4, 0.3, 1.6, -5.4, 0, 1.8, "S" },
			{ 4.4, 0.2, 4.2, 0.1, -0.3, 0, "S" },
		},
		eye = { 0.5, 0.3, 0, color = "A", neon = true },
		extras = {
			Head = {
				{ 0.8, 0.8, 1.8, 1.7, -0.2, -1.4, "P", "m" },
				{ 2.2, 0.3, 0.3, 0, -0.5, -0.72, "S" },
			},
			Body = {
				{ 0.6, 0.15, 0.6, 1.6, 0.85, -1.2, "A", "mn" },
				{ 0.5, 0.15, 0.5, 1.0, 0.85, 0.6, "A", "mn" },
				{ 1.2, 0.15, 0.4, 0, 0.85, -2, "A", "n" },
				{ 0.3, 0.15, 3, 0, 0.85, 1, "A", "n" },
			},
		},
	}),
	fish({
		-- Star-flecked titan: huge jaw, golden crown, whale fluke, constellations on its hide.
		id = "CelestialLeviathan",
		biome = "Saltwater",
		length = 9.0,
		colors = { P = rgb(24, 26, 70), S = rgb(110, 90, 220), A = rgb(255, 236, 160), D = rgb(14, 14, 44) },
		body = { 5, 5, 8 },
		head = { 5.4, 4.8, 4.6 },
		jaw = { 1.2, 5.6 },
		jawWidth = 4.8,
		tail = { 4, 4, 5 },
		tailSegments = 3,
		taper = 0.78,
		tailFin = { 7, 3 },
		tailStyle = "fluke",
		dorsal = { 3, 6, 0 },
		finColor = "S",
		pectoral = { 3.6, 2.4, -2, -1.8 },
		eye = { 0.9, 0.6, -0.6, color = "A", neon = true },
		extras = {
			Head = {
				{ 0.5, 1.6, 0.5, 0, 3.1, 0.4, "A", "n" },
				{ 0.5, 1.1, 0.5, 1.2, 2.9, 0.8, "A", "mn" },
				{ 0.5, 0.8, 0.5, 2.1, 2.7, 1.3, "A", "mn" },
				{ 5.6, 0.6, 1.6, 0, 2.2, -0.8, "D" },
				{ 0.3, 0.8, 0.3, 0.8, -2.7, -2.0, "T", "m" },
				{ 0.3, 0.8, 0.3, 1.8, -2.7, -1.8, "T", "m" },
			},
			Jaw = {
				{ 0.3, 0.9, 0.3, 0.8, 1.0, -2.4, "T", "m" },
				{ 0.3, 0.9, 0.3, 1.8, 1.0, -2.2, "T", "m" },
				{ 0.3, 0.7, 0.3, 2.1, 0.9, -1.0, "T", "m" },
			},
			Body = {
				{ 0.25, 0.4, 0.4, 2.55, 1.2, -2.4, "W", "mn" },
				{ 0.25, 0.3, 0.3, 2.55, -0.4, -0.8, "A", "mn" },
				{ 0.25, 0.5, 0.5, 2.55, 0.6, 1.2, "W", "mn" },
				{ 0.25, 0.3, 0.3, 2.55, -1.2, 2.8, "A", "mn" },
				{ 0.4, 0.25, 0.4, 1.4, 2.55, -1.6, "W", "mn" },
				{ 0.3, 0.25, 0.3, 1.2, 2.55, 2, "A", "mn" },
			},
			Tail = { { 0.25, 0.4, 0.4, 2.05, 0.8, 0, "W", "mn" } },
			Tail2 = { { 0.25, 0.3, 0.3, 1.6, -0.4, 1, "A", "mn" } },
			Tail3 = { { 0.25, 0.3, 0.3, 1.25, 0.4, 0, "W", "mn" } },
		},
	}),
}

-- Instantiation ------------------------------------------------------------------------------

local function ensureFolder(parent, name)
	local found = parent:FindFirstChild(name)
	if not found then
		found = Instance.new("Folder")
		found.Name = name
		found.Parent = parent
	end
	return found
end

local function makePart(name, size, position, color, neon, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
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

local function instantiate(rig)
	local spec = rig.spec

	-- Bounding box of the design, to scale it to the species' length.
	local minV = V(math.huge, math.huge, math.huge)
	local maxV = V(-math.huge, -math.huge, -math.huge)
	local function grow(pos, size)
		local half = size / 2
		minV = V(math.min(minV.X, pos.X - half.X), math.min(minV.Y, pos.Y - half.Y), math.min(minV.Z, pos.Z - half.Z))
		maxV = V(math.max(maxV.X, pos.X + half.X), math.max(maxV.Y, pos.Y + half.Y), math.max(maxV.Z, pos.Z + half.Z))
	end
	for _, bone in rig.order do
		grow(bone.pos, bone.size)
		for _, voxel in bone.voxels do
			grow(voxel.pos, voxel.size)
		end
	end
	local scale = spec.length / (maxV.Z - minV.Z)
	local center = (minV + maxV) / 2
	local function place(v)
		return (v - center) * scale
	end
	local function colorOf(key)
		local color = spec.colors[key] or SHARED_COLORS[key]
		assert(color, `{spec.id}: unknown colour key {key}`)
		return color
	end

	local model = Instance.new("Model")
	model.Name = spec.id
	model:SetAttribute("SpeciesId", spec.id)
	model:SetAttribute("RigVersion", 1)
	model:SetAttribute("GeneratedBy", GENERATOR)
	model:SetAttribute("DesignLength", spec.length)

	local root = makePart("RootPart", (maxV - minV) * scale, V(0, 0, 0), colorOf("P"), false, model)
	root.Transparency = 1
	root.Anchored = true
	model.PrimaryPart = root
	local aura = Instance.new("Attachment")
	aura.Name = "AuraAttachment"
	aura.Parent = root

	local parts = { RootPart = root }
	local count = 1
	for _, bone in rig.order do
		local bonePart = makePart(bone.name, bone.size * scale, place(bone.pos), colorOf(bone.color), false, model)
		parts[bone.name] = bonePart
		count += 1
		for _, voxel in bone.voxels do
			local detail =
				makePart("Voxel", voxel.size * scale, place(voxel.pos), colorOf(voxel.color), voxel.neon, bonePart)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = bonePart
			weld.Part1 = detail
			weld.Parent = detail
			count += 1
		end
	end

	local motors = 0
	for _, bone in rig.order do
		local part0, part1 = parts[bone.parent], parts[bone.name]
		local pivot = CFrame.new(place(bone.pivot))
		local motor = Instance.new("Motor6D")
		motor.Name = bone.name
		motor.Part0 = part0
		motor.Part1 = part1
		motor.C0 = part0.CFrame:ToObjectSpace(pivot)
		motor.C1 = part1.CFrame:ToObjectSpace(pivot)
		motor.Parent = part0
		motors += 1
	end

	return model, count, motors
end

-- Build ----------------------------------------------------------------------------------------

local assets = ensureFolder(ReplicatedStorage, "Assets")
local creatures = ensureFolder(assets, "Creatures")
ensureFolder(creatures, "Freshwater")
ensureFolder(creatures, "Saltwater")

local recording = ChangeHistoryService:TryBeginRecording("Build VoxelMorph creatures")
local summary = {}
for _, rig in SPECIES do
	local spec = rig.spec
	local folder = creatures[spec.biome]
	local existing = folder:FindFirstChild(spec.id)
	if existing and existing:GetAttribute("GeneratedBy") ~= GENERATOR then
		table.insert(summary, `{spec.id}: SKIPPED (a model not made by this script already exists)`)
	else
		if existing then
			existing:Destroy()
		end
		local model, count, motors = instantiate(rig)
		model.Parent = folder
		table.insert(summary, `{spec.id}: {count} parts, {motors} joints`)
	end
end
if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

print("[BuildCreatures] " .. table.concat(summary, " | "))
