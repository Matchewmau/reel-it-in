--!strict
-- Ambient map dressing: bobbing buoys, rocking moored boats, circling seagulls
-- and lamps that only burn at night.
--
-- The map build script (run in Studio) creates Workspace.Map.Decor and tags what
-- should move with attributes; this controller animates those instances. The
-- server never simulates decor: every pose here is local, cosmetic and computed
-- from the instance's original CFrame plus the clock, so nothing drifts.
--
-- Attribute contract (on a Model or BasePart under Workspace.Map.Decor):
--   AmbientBob    number, studs    bob up and down around the original position
--   AmbientSway   number, degrees  rock (roll + a little pitch) around the original pivot
--   AmbientOrbit  number, studs    circle the original pivot position, facing travel (-Z front)
--   AmbientPeriod number, seconds  optional cycle length (defaults below)
-- Bob and Sway combine; Orbit is exclusive and wins if it is set alongside them.
-- On a Light under the same folder:
--   NightLight    boolean = true   Enabled only while Weather.IsNight(Lighting.ClockTime)

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Weather = require(Shared.Config.Weather)

type Motion = {
	bob: number, -- studs, 0 = none
	bobPeriod: number,
	sway: number, -- radians, 0 = none
	swayPeriod: number,
	orbit: number, -- studs, 0 = none
	orbitPeriod: number,
}

type Entry = {
	instance: Instance,
	model: Model?, -- exactly one of model / part is set
	part: BasePart?,
	origin: CFrame, -- recorded once at registration; every pose derives from it
	phase: number, -- 0..1 fraction of a cycle, stable per position
	motion: Motion,
}

local MAP_NAME = "Map" -- Workspace child that holds the Studio-built world
local DECOR_NAME = "Decor" -- child of the map folder that holds the decoration
local ATTR_BOB = "AmbientBob" -- attribute: bob amplitude in studs
local ATTR_SWAY = "AmbientSway" -- attribute: sway amplitude in degrees
local ATTR_ORBIT = "AmbientOrbit" -- attribute: orbit radius in studs
local ATTR_PERIOD = "AmbientPeriod" -- attribute: optional cycle length in seconds
local ATTR_NIGHT_LIGHT = "NightLight" -- attribute: true on lights that only burn at night

local DEFAULT_BOB_PERIOD = 3 -- seconds per bob cycle when AmbientPeriod is absent
local DEFAULT_SWAY_PERIOD = 4 -- seconds per roll cycle when AmbientPeriod is absent
local DEFAULT_ORBIT_PERIOD = 14 -- seconds per lap when AmbientPeriod is absent
local MIN_PERIOD = 0.25 -- seconds; a shorter (or non-positive) AmbientPeriod falls back to the default
local ANIMATE_DISTANCE = 450 -- studs from the camera to the original position; farther instances are frozen
local MAX_ANIMATED = 30 -- instances moved per frame (budget: 30 models x 20 anchored parts)
local RESCAN_DELAY = 0.5 -- seconds after the last descendant arrives before re-reading attributes
local SWAY_PITCH_RATIO = 0.35 -- pitch amplitude as a fraction of the roll amplitude
local SWAY_PITCH_PERIOD_SCALE = 1.6 -- pitch cycle length relative to roll, so the rocking never loops exactly
local SWAY_PHASE_OFFSET = 0.31 -- cycle fraction between an instance's bob and its roll (moored boats)
local ORBIT_BANK = math.rad(12) -- roll into the turn while orbiting
local PHASE_HASH = Vector3.new(12.9898, 78.233, 37.719) -- projects the original position onto one hash input
local PHASE_HASH_SCALE = 43758.5453 -- spreads sin() of that input across the 0..1 phase range
local TAU = 2 * math.pi -- radians per cycle

local AmbientController = {}

local entries: { [Instance]: Entry } = {}
local entryCount = 0
local nightLights: { [Light]: boolean } = {}
local isNight = false
local warnedBudget = false

local boundMap: Instance? = nil
local boundDecor: Instance? = nil
local mapConnections: { RBXScriptConnection } = {}
local decorConnections: { RBXScriptConnection } = {}

local rescanDue = 0
local rescanWaiting = false

-- Attribute parsing ---------------------------------------------------------------------

local function readPositive(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	if type(value) == "number" and value > 0 and value < math.huge then
		return value
	end
	return 0
end

local function readMotion(instance: Instance): Motion?
	local bob = readPositive(instance, ATTR_BOB)
	local sway = readPositive(instance, ATTR_SWAY)
	local orbit = readPositive(instance, ATTR_ORBIT)
	if bob == 0 and sway == 0 and orbit == 0 then
		return nil
	end
	local period = readPositive(instance, ATTR_PERIOD)
	local hasPeriod = period >= MIN_PERIOD
	return {
		bob = bob,
		bobPeriod = if hasPeriod then period else DEFAULT_BOB_PERIOD,
		sway = math.rad(sway),
		swayPeriod = if hasPeriod then period else DEFAULT_SWAY_PERIOD,
		orbit = orbit,
		orbitPeriod = if hasPeriod then period else DEFAULT_ORBIT_PERIOD,
	}
end

-- Stable pseudo-random cycle offset from where the instance was authored, so
-- neighbours never move in unison and the offset survives a map rebuild.
local function phaseOf(position: Vector3): number
	local hashed = math.sin(position:Dot(PHASE_HASH)) * PHASE_HASH_SCALE
	return hashed - math.floor(hashed)
end

-- Posing --------------------------------------------------------------------------------

local function place(entry: Entry, cframe: CFrame)
	local model = entry.model
	local part = entry.part
	if model then
		model:PivotTo(cframe)
	elseif part then
		part.CFrame = cframe
	end
end

local function poseOf(entry: Entry, now: number): CFrame
	local origin = entry.origin
	local motion = entry.motion

	if motion.orbit > 0 then
		-- Horizontal circle around the original pivot position. The heading is the
		-- circle's tangent; the centre is then on the model's right, so banking into
		-- the turn dips the right wing (negative roll about the -Z-forward axis).
		local angle = (now / motion.orbitPeriod + entry.phase) * TAU
		local sin, cos = math.sin(angle), math.cos(angle)
		local position = origin.Position + Vector3.new(cos * motion.orbit, 0, sin * motion.orbit)
		local heading = Vector3.new(-sin, 0, cos)
		return CFrame.lookAt(position, position + heading) * CFrame.Angles(0, 0, -ORBIT_BANK)
	end

	local pose = origin
	if motion.sway > 0 then
		local cycle = now / motion.swayPeriod + entry.phase + SWAY_PHASE_OFFSET
		local roll = math.sin(cycle * TAU) * motion.sway
		local pitch = math.sin(cycle / SWAY_PITCH_PERIOD_SCALE * TAU) * motion.sway * SWAY_PITCH_RATIO
		pose = pose * CFrame.Angles(pitch, 0, roll)
	end
	if motion.bob > 0 then
		local height = math.sin((now / motion.bobPeriod + entry.phase) * TAU) * motion.bob
		pose = pose + Vector3.new(0, height, 0)
	end
	return pose
end

-- Registration --------------------------------------------------------------------------

-- Drops an instance from the animated set. If it still exists somewhere (moved
-- out of Decor rather than destroyed) it is put back exactly where it was
-- authored, so registering it again later cannot record an animated pose.
local function forget(entry: Entry)
	if entries[entry.instance] ~= entry then
		return
	end
	entries[entry.instance] = nil
	entryCount -= 1
	if entry.instance.Parent ~= nil then
		place(entry, entry.origin)
	end
end

local function hasAnimatedAncestor(instance: Instance): boolean
	local parent = instance.Parent
	while parent and parent ~= boundDecor do
		if entries[parent] then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local function considerMover(instance: Instance, model: Model?, part: BasePart?)
	local motion = readMotion(instance)
	local existing: Entry? = entries[instance]
	if not motion then
		if existing then
			forget(existing)
		end
		return
	end
	if existing then
		-- Same instance seen again by a re-scan: pick up changed attributes, keep the origin.
		existing.motion = motion
		return
	end

	-- One animated instance never sits inside another: the outer one moves its
	-- parts every frame, which would fight an inner origin recorded in world space.
	if hasAnimatedAncestor(instance) then
		return
	end
	for _, other in entries do
		if other.instance:IsDescendantOf(instance) then
			forget(other)
		end
	end

	local origin: CFrame
	if model then
		origin = model:GetPivot()
	elseif part then
		origin = part.CFrame
	else
		return
	end

	entries[instance] = {
		instance = instance,
		model = model,
		part = part,
		origin = origin,
		phase = phaseOf(origin.Position),
		motion = motion,
	}
	entryCount += 1
	if entryCount > MAX_ANIMATED and not warnedBudget then
		warnedBudget = true
		warn(
			`[AmbientController] {entryCount} animated decor instances exceed the budget of {MAX_ANIMATED}; the rest stay still.`
		)
	end
end

local function considerLight(light: Light)
	if light:GetAttribute(ATTR_NIGHT_LIGHT) == true then
		nightLights[light] = true
		light.Enabled = isNight
	else
		nightLights[light] = nil
	end
end

local function consider(instance: Instance)
	local decor = boundDecor
	if not decor or not instance:IsDescendantOf(decor) then
		return -- removed again before this (possibly deferred) handler ran
	end
	if instance:IsA("Light") then
		considerLight(instance)
	elseif instance:IsA("Model") then
		considerMover(instance, instance, nil)
	elseif instance:IsA("BasePart") then
		considerMover(instance, nil, instance)
	end
end

local function scanDecor()
	local decor = boundDecor
	if not decor then
		return
	end
	for _, descendant in decor:GetDescendants() do
		consider(descendant)
	end
end

-- Attributes are normally set before parenting, but a builder may tag an
-- instance a moment after inserting it. Rather than a changed-signal per
-- instance, one trailing re-scan runs once the folder has been quiet for
-- RESCAN_DELAY and re-reads every descendant's attributes.
local function scheduleRescan()
	rescanDue = os.clock() + RESCAN_DELAY
	if rescanWaiting then
		return
	end
	rescanWaiting = true
	task.spawn(function()
		while os.clock() < rescanDue do
			task.wait(rescanDue - os.clock())
		end
		rescanWaiting = false
		scanDecor()
	end)
end

local function onDescendantAdded(instance: Instance)
	consider(instance)
	scheduleRescan()
end

local function onDescendantRemoving(instance: Instance)
	local entry: Entry? = entries[instance]
	if entry then
		forget(entry)
	end
	if instance:IsA("Light") then
		nightLights[instance] = nil
	end
end

-- Folder binding ------------------------------------------------------------------------

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function unbindDecor()
	disconnectAll(decorConnections)
	boundDecor = nil
	for _, entry in entries do
		if entry.instance.Parent ~= nil then
			place(entry, entry.origin)
		end
	end
	table.clear(entries)
	entryCount = 0
	table.clear(nightLights)
end

local function bindDecor(decor: Instance)
	boundDecor = decor
	table.insert(decorConnections, decor.DescendantAdded:Connect(onDescendantAdded))
	table.insert(decorConnections, decor.DescendantRemoving:Connect(onDescendantRemoving))
	scanDecor()
	scheduleRescan()
end

-- Re-resolves Workspace.Map.Decor by name and rebinds if either level is a
-- different instance than last time (missing, newly created, or destroyed and
-- rebuilt by the map script). Cheap enough to run on every child change.
local function refreshBinding()
	local map = Workspace:FindFirstChild(MAP_NAME)
	if map ~= boundMap then
		disconnectAll(mapConnections)
		boundMap = map
		if map then
			table.insert(mapConnections, map.ChildAdded:Connect(refreshBinding))
			table.insert(mapConnections, map.ChildRemoved:Connect(refreshBinding))
		end
	end

	local decor = if map then map:FindFirstChild(DECOR_NAME) else nil
	if decor ~= boundDecor then
		unbindDecor()
		if decor then
			bindDecor(decor)
		end
	end
end

-- Per-frame update ----------------------------------------------------------------------

local function updateNightLights()
	local night = Weather.IsNight(Lighting.ClockTime)
	if night == isNight then
		return
	end
	isNight = night
	for light in nightLights do
		light.Enabled = night
	end
end

local function updateMovers()
	local camera = Workspace.CurrentCamera
	if not camera or entryCount == 0 then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local now = os.clock()
	local animated = 0
	for _, entry in entries do
		if entry.instance.Parent ~= nil and (entry.origin.Position - cameraPosition).Magnitude <= ANIMATE_DISTANCE then
			place(entry, poseOf(entry, now))
			animated += 1
			if animated >= MAX_ANIMATED then
				break
			end
		end
	end
end

-- Lifecycle -----------------------------------------------------------------------------

function AmbientController.Init()
	isNight = Weather.IsNight(Lighting.ClockTime)
end

function AmbientController.Start()
	Workspace.ChildAdded:Connect(refreshBinding)
	Workspace.ChildRemoved:Connect(refreshBinding)
	refreshBinding()

	RunService.PreRender:Connect(function()
		updateNightLights()
		updateMovers()
	end)
end

return AmbientController
