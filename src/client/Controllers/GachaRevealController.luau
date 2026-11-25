--!strict
-- Gacha reveal: the full-screen "what did I get?!" moment for rod pulls and
-- bait crates.
--
-- Presentation only. The server has already rolled and granted everything by
-- the time PlayRods / PlayBaits is called (see GachaService); this controller
-- never talks to the server and never changes state.
--
--   GachaRevealController.PlayRods(response.results)  -- 1 result = crystal + big card, 2+ = card grid
--   GachaRevealController.PlayBaits(response.results) -- crate pops open, one card per result
--
-- Both return at once; reveals play one at a time from a queue. A press (click,
-- tap, Space, Enter, gamepad A) skips the build-up, fast-forwards a grid, and
-- dismisses a finished reveal.
--
-- Never-stuck rules: the only yields are bounded `task.wait`s (no waiting on
-- tween or instance signals), every reveal runs inside a pcall, cleanup runs on
-- every path, and a watchdog force-closes a reveal that outlives WATCHDOG_TIME.

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Format = require(Shared.Util.Format)
local Rarities = require(Shared.Config.Rarities)
local Rods = require(Shared.Config.Rods)
local Baits = require(Shared.Config.Baits)

local Kit = require(script.Parent.Parent.UI.Kit)
local ModelPreview = require(script.Parent.Parent.UI.ModelPreview)

type Rarity = Types.Rarity

export type RodResult = { rodId: string, isNew: boolean, starsGained: number, stars: number, refundGold: number }
export type BaitResult = { baitId: string, amount: number }

-- How big a moment each rarity gets on a single rod pull.
type Intensity = {
	buildUp: number, -- seconds the crystal shakes before it bursts
	hold: number, -- seconds the finished card stays up before a press can dismiss it
	shake: number, -- peak crystal shake, pixels
	rays: number, -- radial rays in the burst
	sparks: number, -- voxel confetti squares in the burst
	rings: number, -- expanding rings in the burst
	flash: number, -- peak opacity of the full-screen flash (0 = no screen flash)
	cardShake: number, -- pixels the card shakes as it lands (0 = none)
	godRays: number, -- slowly rotating god-ray layers behind the card (0 = none)
	pulseTitle: boolean, -- the rod name keeps pulsing
}

local Theme = Kit.Theme
local player = Players.LocalPlayer

-- Tunables ----------------------------------------------------------------------------

-- Overlay
local DISPLAY_ORDER = 50 -- above the HUD (10) and the reel UI (20)
local STAGE_SIZE = Vector2.new(1180, 820) -- design canvas; matches the viewport Kit.AutoScale scales against
local DIM_COLOR = Color3.fromRGB(3, 7, 16) -- colour of the layer that dims the game
local DIM_TRANSPARENCY = 0.12 -- nearly opaque, so the HUD underneath does not compete with the reveal
local FADE_IN_TIME = 0.2 -- seconds for the dim layer to arrive
local FADE_OUT_TIME = 0.2 -- seconds for the scene to shrink away on dismiss
local QUEUE_GAP = 0.15 -- breather between two queued reveals
local AUTO_DISMISS_TIME = 6 -- seconds a finished reveal waits for a press before closing itself
local WATCHDOG_TIME = 60 -- a reveal still running after this long is force-closed (longest real one is ~20 s)
local PLAYER_GUI_TIMEOUT = 5 -- seconds to wait for PlayerGui before giving up on building the overlay
local MAX_RESULTS = 10 -- most results one reveal will show (a ten-pull / ten crates)
local SINK_ACTION = "ReelItInGachaRevealPress" -- ContextActionService action that swallows the confirm keys

-- Layout (design pixels on the stage; y is measured from the top)
local HEADER_Y = 62 -- centre of the title line
local FOCUS_Y = 392 -- centre of the crystal / crate / single reveal card
local GRID_CENTER_Y = 385 -- centre of the result card grid
local SUMMARY_Y = 672 -- first summary line under the grid
local SUMMARY_LINE_GAP = 32 -- distance from the first summary line to the second
local HINT_Y = 754 -- "tap to continue" hint

-- Layers inside a scene (ZIndex)
local Z_BACK = 1 -- god-rays and the big burst, behind the focus
local Z_FOCUS = 3 -- crystal, crate, reveal card, grid cards
local Z_OVER = 8 -- mini bursts drawn over the grid
local Z_TEXT = 9 -- header, summary, hint

-- Shared shake shape (crystal, crate, charging grid card, landing card)
local SHAKE_MIN = 1 -- pixels of shake at the very start of a build-up
local SHAKE_FREQUENCY = Vector3.new(41, 37, 29) -- rad/s for x, y and tilt; mismatched so the shake never loops visibly
local SHAKE_Y_RATIO = 0.6 -- vertical shake as a fraction of horizontal
local SHAKE_TILT = 0.5 -- degrees of tilt per pixel of shake

-- Crystal build-up (single rod pull)
local CRYSTAL_SIZE = 230 -- crystal footprint in pixels
local CRYSTAL_IN_TIME = 0.25 -- seconds for the crystal to pop in
local BUILD_GROWTH = 0.18 -- extra crystal scale gained by the end of the build-up
local TEASE_BLEND_RATE = 14 -- how fast the glow chases the next rarity colour (1/s)
local TEASE_POP_SCALE = 0.14 -- scale kick each time the glow climbs a rarity tier
local TEASE_POP_TIME = 0.18 -- seconds that kick takes to settle
local GLOW_GROWTH = 0.5 -- extra glow scale gained by the end of the build-up
local GLOW_THROB = 0.08 -- glow breathing depth during the build-up
local GLOW_THROB_SPEED = 14 -- glow breathing speed (rad/s)

-- Burst
local BURST_SIZE = 620 -- size of the big burst in pixels (rays and confetti reach about 0.8x this from the centre)
local BURST_FLASH_TIME = 0.32 -- seconds the white core takes to bloom and fade
local BURST_RING_TIME = 0.55 -- seconds each ring takes to expand and fade
local BURST_RING_STAGGER = 0.09 -- delay between successive rings
local BURST_RAY_TIME = 0.5 -- seconds a ray takes to shoot out and fade
local BURST_SPARK_TIME = 0.9 -- seconds a confetti square flies for
local BURST_SPARK_DROP = 0.12 -- how far confetti sags downward, as a fraction of burst size
local BURST_LIFETIME = 1.6 -- seconds before a finished burst's instances are destroyed
local BURST_LEAD = 0.15 -- seconds between the burst firing and the card appearing out of it
local FLASH_WHITENESS = 0.5 -- how far the screen flash is pushed from the rarity colour toward white
local FLASH_TIME_MIN = 0.35 -- screen flash fade time at zero strength
local FLASH_TIME_PER_PEAK = 0.6 -- extra fade time per unit of flash strength (one slow fade, never a strobe)

-- God-rays (Legendary and Mythic)
local GODRAY_RADIUS = 540 -- length of the long rays in pixels
local GODRAY_COUNT = 12 -- rays in the main layer
local GODRAY_SPEED = 14 -- rotation in degrees per second
local GODRAY_TRANSPARENCY = 0.74 -- resting transparency of a ray at its base
local GODRAY_FADE_IN = 0.6 -- seconds for the rays to fade in
local GODRAY_INNER_RADIUS = 0.75 -- second (Mythic) layer: radius relative to the first
local GODRAY_INNER_SPEED = -1.6 -- second layer: speed relative to the first (negative = counter-rotating)

-- Single reveal card
local CARD_SIZE = Vector2.new(452, 524) -- big rod card
local CARD_POP_FROM = 0.3 -- scale the card pops in from
local CARD_IN_TIME = 0.45 -- seconds for the card to pop in
local CARD_SHAKE_TIME = 0.45 -- seconds an Epic+ card shakes as it lands
local STATUS_POP_TIME = 0.3 -- seconds for the status line to pop in once the card has landed
local TITLE_PULSE_DEPTH = 0.06 -- extra scale at the peak of the Legendary+ title pulse
local TITLE_PULSE_SPEED = 5 -- title pulse speed (rad/s)
local SKIP_HOLD = 0.5 -- hold after a skipped build-up: just long enough that a double-tap can't dismiss unseen
local STAR_EMPTY = Color3.fromRGB(58, 76, 112) -- colour of stars not yet earned

-- Result grid (ten-pull and bait crates)
local MINI_SIZE = Vector2.new(190, 230) -- one grid card
local GRID_COLUMNS = 5 -- cards per row
local GRID_GAP = 14 -- pixels between cards
local MINI_SOLO_SCALE = 1.5 -- a lone card (single bait crate) is shown this much bigger
local DEAL_TIME = 0.3 -- seconds for a face-down card to pop in
local DEAL_STAGGER = 0.04 -- delay between cards being dealt
local FLIP_INTERVAL = 0.25 -- seconds between one card starting to flip and the next
local FLIP_HALF = 0.1 -- seconds for a card to turn edge-on (the second half is the settle)
local FLIP_SETTLE = 1.5 -- second half of the flip, as a multiple of FLIP_HALF
local MINI_BURST_MIN: Rarity = "Epic" -- grid cards of this rarity or better get a charge-up and a mini burst
local MINI_CHARGE_TIME = 0.4 -- seconds an Epic+ grid card shakes before it flips
local MINI_CHARGE_SHAKE = 6 -- peak shake of a charging grid card, pixels
local MINI_BURST_SIZE = 300 -- size of a mini burst in pixels
local MINI_BURST_PAUSE = 0.55 -- pause after an Epic+ flip so it can be admired
local MINI_BURST_POP = 1.2 -- scale an Epic+ card kicks to as it flips
local MINI_FX_SCALE = 0.5 -- mini bursts use this fraction of the big burst's rays, sparks and flash
local FAST_POP_FROM = 0.85 -- scale fast-forwarded cards pop in from
local FAST_POP_TIME = 0.2 -- seconds for a fast-forwarded card to pop in
local FAST_STAGGER = 0.03 -- delay between fast-forwarded cards
local BEST_SCALE = 1.12 -- the best card in the summary grows to this
local BEST_PULSE_SPEED = 4 -- best card stroke pulse speed (rad/s)
local SUMMARY_GUARD = 0.5 -- seconds the summary is up before a press can dismiss it

-- Bait crate
local CRATE_SIZE = Vector2.new(216, 196) -- crate footprint in pixels
local CRATE_COLOR = Color3.fromRGB(176, 122, 68) -- crate planks top
local CRATE_WOOD_DARK = Color3.fromRGB(106, 66, 34) -- crate planks bottom
local CRATE_LID_COLOR = Color3.fromRGB(206, 148, 86) -- crate lid top
local CRATE_DARK = Color3.fromRGB(58, 34, 18) -- crate outlines and plank gaps
local WOOD_LIGHT = Color3.fromRGB(198, 142, 68) -- carved header sign top
local WOOD_DARK = Color3.fromRGB(112, 66, 30) -- carved header sign bottom
local WOOD_INK = Color3.fromRGB(48, 26, 12) -- warm dark stroke on wood/gold text
local CREAM = Color3.fromRGB(255, 242, 196) -- warm cream display text
local CRATE_SHAKE_TIME = 0.9 -- seconds the crate rattles before it pops (lighter than a rod pull)
local CRATE_SHAKE = 7 -- peak crate shake, pixels
local CRATE_LID_RATTLE = 1.2 -- degrees the lid rattles per pixel of shake
local CRATE_POP_TIME = 0.35 -- seconds for the lid to fly off and the crate to vanish
local CRATE_BURST_SIZE = 420 -- size of the crate's burst in pixels
local CRATE_RAYS = 10 -- rays in the crate's burst
local CRATE_SPARKS = 14 -- confetti squares in the crate's burst
local BAIT_CARD_INTERVAL = 0.18 -- seconds between bait cards popping in

-- Hint
local HINT_MIN_TRANSPARENCY = 0.1 -- hint text at its brightest
local HINT_MAX_TRANSPARENCY = 0.6 -- hint text at its dimmest
local HINT_PULSE_SPEED = 4 -- hint pulse speed (rad/s)

-- World touch
local FLAME_PULSE_SPEED = 6 -- shrine flame pulse speed (rad/s)
local FLAME_PULSE_DEPTH = 0.85 -- how far the flame swings toward the rarity colour at the peak

local WHITE = Color3.new(1, 1, 1)
local CENTER = Vector2.new(0.5, 0.5)

-- Soft glow faked with stacked translucent discs: diameter multiple and transparency of each.
local GLOW_LAYERS: { { size: number, transparency: number } } = {
	{ size = 1.0, transparency = 0.6 },
	{ size = 1.45, transparency = 0.78 },
	{ size = 1.95, transparency = 0.9 },
}

-- Per-rarity intensity of a single rod pull. Total time before the reveal can be
-- dismissed = buildUp + BURST_LEAD + CARD_IN_TIME + hold:
-- Common 2.5 s, Uncommon 2.6, Rare 2.9, Epic 3.4, Legendary 4.2, Mythic 5.0.
local INTENSITY = {
	Common = {
		buildUp = 1.0,
		hold = 0.9,
		shake = 4,
		rays = 8,
		sparks = 6,
		rings = 1,
		flash = 0,
		cardShake = 0,
		godRays = 0,
		pulseTitle = false,
	},
	Uncommon = {
		buildUp = 1.1,
		hold = 0.9,
		shake = 5,
		rays = 8,
		sparks = 8,
		rings = 1,
		flash = 0,
		cardShake = 0,
		godRays = 0,
		pulseTitle = false,
	},
	Rare = {
		buildUp = 1.2,
		hold = 1.1,
		shake = 6,
		rays = 16,
		sparks = 12,
		rings = 1,
		flash = 0,
		cardShake = 0,
		godRays = 0,
		pulseTitle = false,
	},
	Epic = {
		buildUp = 1.5,
		hold = 1.3,
		shake = 8,
		rays = 18,
		sparks = 18,
		rings = 2,
		flash = 0.45,
		cardShake = 7,
		godRays = 0,
		pulseTitle = false,
	},
	Legendary = {
		buildUp = 2.0,
		hold = 1.6,
		shake = 11,
		rays = 22,
		sparks = 26,
		rings = 2,
		flash = 0.7,
		cardShake = 9,
		godRays = 1,
		pulseTitle = true,
	},
	Mythic = {
		buildUp = 2.4,
		hold = 2.0,
		shake = 14,
		rays = 26,
		sparks = 34,
		rings = 3,
		flash = 0.85,
		cardShake = 11,
		godRays = 2,
		pulseTitle = true,
	},
} :: { [Rarity]: Intensity }

-- State -------------------------------------------------------------------------------

type RodEntry = { def: Rods.RodDef, isNew: boolean, starsGained: number, stars: number, refundGold: number }
type BaitEntry = { def: Baits.BaitDef, amount: number }
type Job = () -> ()
type AmbientStep = (now: number) -> ()

type Crystal = {
	root: Frame,
	scale: UIScale,
	glow: Frame,
	glowScale: UIScale,
	body: Frame,
	stroke: UIStroke,
}

type Crate = {
	root: Frame,
	scale: UIScale,
	glow: Frame,
	glowScale: UIScale,
	lid: Frame,
	lidStroke: UIStroke,
}

type RodCard = {
	root: Frame,
	scale: UIScale,
	nameScale: UIScale,
	statusScale: UIScale,
}

type MiniSpec = {
	kind: string, -- ModelPreview kind: "Rod" | "Bait"
	id: string,
	name: string,
	rarity: Rarity,
	badge: string,
	badgeColor: Color3,
}

type MiniCard = {
	spec: MiniSpec,
	home: UDim2,
	slot: Frame,
	scale: UIScale,
	flipper: Frame,
	back: Frame,
	backStroke: UIStroke,
	front: Frame,
	frontStroke: UIStroke,
	viewportHolder: Frame,
	revealed: boolean,
	hasHalo: boolean,
}

local GachaRevealController = {}

local rng = Random.new()
local queue: { Job } = {}
local playing = false -- a reveal is on screen or waiting in the queue
local runner: thread? = nil -- the thread draining the queue
local jobSerial = 0 -- identifies the current reveal for its watchdog
local overlayActive = false -- the overlay is up, so presses count
local pressPending = false -- a press arrived that no stage has consumed yet
local ambient: { AmbientStep } = {} -- per-frame effects of the current scene
local ambientConnection: RBXScriptConnection? = nil
local flameRestore: (() -> ())? = nil -- puts the shrine flame back the way it was
local started = false

local built = false
local gui: ScreenGui
local dim: TextButton
local flash: Frame
local stage: Frame
local hint: TextLabel
local scene: Frame? = nil -- everything belonging to the reveal on screen; destroyed on cleanup
local sceneScale: UIScale? = nil

-- AUDIO HOOK ---------------------------------------------------------------------------
-- There are no audio assets yet, so this deliberately does nothing. It is called at
-- every key beat of a reveal; wire sounds up here and nowhere else.
-- Names: "buildup" (crystal / crate starts shaking, grid is dealt), "tease" (glow
-- climbs a rarity tier), "burst", "reveal" (a card lands / summary appears), "flip"
-- (grid card turns over), "dismiss".
local function playSound(name: string)
	local _unused = name
end

-- Small helpers -----------------------------------------------------------------------

local function tween(
	instance: Instance,
	duration: number,
	goal: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?,
	delayTime: number?
): Tween
	local info = TweenInfo.new(
		duration,
		style or Enum.EasingStyle.Quad,
		direction or Enum.EasingDirection.Out,
		0,
		false,
		delayTime or 0
	)
	local created = TweenService:Create(instance, info, goal)
	created:Play()
	return created
end

-- Consumes a pending press. Reading through a function also stops the analyzer
-- narrowing `pressPending` to whatever the caller last assigned.
local function takePress(): boolean
	if pressPending then
		pressPending = false
		return true
	end
	return false
end

local function registerPress()
	if overlayActive then
		pressPending = true
	end
end

-- Waits up to `duration` seconds; returns true early if the player pressed.
local function waitOrPress(duration: number): boolean
	local deadline = os.clock() + duration
	while os.clock() < deadline do
		if takePress() then
			return true
		end
		task.wait()
	end
	return takePress()
end

local function addAmbient(step: AmbientStep)
	table.insert(ambient, step)
end

-- A point on the stage: x pixels from the centre line, y pixels from the top.
local function at(x: number, y: number): UDim2
	return UDim2.new(0.5, x, 0, y)
end

local function shakeOffset(elapsed: number, amplitude: number): UDim2
	return UDim2.fromOffset(
		math.sin(elapsed * SHAKE_FREQUENCY.X) * amplitude,
		math.cos(elapsed * SHAKE_FREQUENCY.Y) * amplitude * SHAKE_Y_RATIO
	)
end

local function shakeTilt(elapsed: number, amplitude: number): number
	return math.sin(elapsed * SHAKE_FREQUENCY.Z) * amplitude * SHAKE_TILT
end

local function addScale(parent: Instance, value: number): UIScale
	local scale = Instance.new("UIScale")
	scale.Scale = value
	scale.Parent = parent
	return scale
end

-- A centred label (Kit labels are left-aligned and top-left anchored by default).
local function centered(props: { [string]: any }): TextLabel
	props.TextXAlignment = Enum.TextXAlignment.Center
	props.AnchorPoint = props.AnchorPoint or CENTER
	return Kit.Label(props)
end

-- Chunky outline around the glyphs (Kit.Stroke outlines the label's box instead).
local function outline(label: TextLabel, color: Color3, thickness: number): UIStroke
	return Kit.TextStroke(label, color, thickness)
end

local function fitText(label: TextLabel, maxSize: number)
	label.TextScaled = true
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = maxSize
	constraint.MinTextSize = 8
	constraint.Parent = label
end

local function verticalGradient(frame: Frame, top: Color3, bottom: Color3)
	frame.BackgroundColor3 = WHITE
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = 90
	gradient.Parent = frame
end

-- A tiny invisible frame. Children placed on its centre turn around that point
-- when the pivot is rotated, which is how rays are aimed without image assets.
local function pivot(parent: Instance, position: UDim2, zIndex: number): Frame
	return Kit.Frame({
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = position,
		Size = UDim2.fromOffset(2, 2),
		ZIndex = zIndex,
		Parent = parent,
	})
end

local function disc(parent: Instance, color: Color3, diameter: number, transparency: number): Frame
	local frame = Kit.Frame({
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(diameter, diameter),
		Parent = parent,
	})
	Kit.Corner(frame, 0).CornerRadius = UDim.new(0.5, 0)
	return frame
end

local function makeGlow(parent: Instance, color: Color3, diameter: number): (Frame, UIScale)
	local holder = pivot(parent, UDim2.fromScale(0.5, 0.5), 0)
	for _, layer in GLOW_LAYERS do
		disc(holder, color, diameter * layer.size, layer.transparency)
	end
	return holder, addScale(holder, 1)
end

local function tintGlow(holder: Frame, color: Color3)
	for _, child in holder:GetChildren() do
		if child:IsA("Frame") then
			child.BackgroundColor3 = color
		end
	end
end

-- A beam of light standing on the holder's centre and pointing up (rotate the
-- holder to aim it). `inner` is how far from the centre it starts; it fades out
-- toward its tip.
local function beam(
	holder: Frame,
	color: Color3,
	width: number,
	length: number,
	inner: number,
	transparency: number
): Frame
	local frame = Kit.Frame({
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.5, -inner),
		Size = UDim2.fromOffset(width, length),
		Parent = holder,
	})
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new(1, 0)
	gradient.Parent = frame
	return frame
end

-- A spinning 3D preview filling `parent`. A missing or broken asset must not
-- take the reveal down, so failures only cost the picture.
local function addPreview(parent: Instance, kind: string, id: string): ViewportFrame?
	local spec: ModelPreview.Spec = { kind = kind, id = id }
	local ok, viewport = pcall(ModelPreview.Create, spec)
	if not ok then
		warn(`[GachaReveal] no preview for {kind} {id}: {viewport}`)
		return nil
	end
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.ZIndex = 2
	viewport.Parent = parent
	ModelPreview.SetSpin(viewport, true)
	return viewport
end

local function hintText(): string
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "TAP TO CONTINUE"
	elseif string.find(last.Name, "Gamepad", 1, true) then
		return "PRESS A TO CONTINUE"
	end
	return "CLICK OR PRESS SPACE TO CONTINUE"
end

-- Effects -----------------------------------------------------------------------------

-- One fade from a tinted flash back to clear. Reveals never flash faster than
-- about once a second, so this stays well away from strobing.
local function flashScreen(color: Color3, peak: number)
	if peak <= 0 then
		return
	end
	flash.BackgroundColor3 = color:Lerp(WHITE, FLASH_WHITENESS)
	flash.BackgroundTransparency = 1 - peak
	tween(flash, FLASH_TIME_MIN + peak * FLASH_TIME_PER_PEAK, { BackgroundTransparency = 1 })
end

-- Flash core + expanding rings + radial rays + blocky confetti, all in the rarity colour.
local function playBurst(
	parent: Instance,
	position: UDim2,
	color: Color3,
	size: number,
	rays: number,
	sparks: number,
	rings: number,
	zIndex: number
)
	local root = pivot(parent, position, zIndex)
	local bright = color:Lerp(WHITE, 0.6)
	local sparkColors = { color, bright, WHITE, Theme.Gold }

	local core = disc(root, bright, size * 0.3, 0.05)
	tween(core, BURST_FLASH_TIME, { Size = UDim2.fromOffset(size * 1.25, size * 1.25), BackgroundTransparency = 1 })

	for index = 1, rings do
		local ring = disc(root, color, size * 0.25, 1)
		local stroke = Kit.Stroke(ring, if index % 2 == 1 then color else bright, size * 0.04)
		local delayTime = (index - 1) * BURST_RING_STAGGER
		local reach = size * (1.5 + 0.35 * (index - 1))
		tween(ring, BURST_RING_TIME, { Size = UDim2.fromOffset(reach, reach) }, Enum.EasingStyle.Quart, nil, delayTime)
		tween(stroke, BURST_RING_TIME, { Thickness = 1, Transparency = 1 }, nil, nil, delayTime)
	end

	for index = 1, rays do
		local holder = pivot(root, UDim2.fromScale(0.5, 0.5), 1)
		holder.Rotation = (index + rng:NextNumber(-0.3, 0.3)) / rays * 360
		local length = size * rng:NextNumber(0.25, 0.5)
		local width = math.max(3, size * rng:NextNumber(0.012, 0.03))
		local ray = beam(holder, if index % 2 == 0 then bright else color, width, length * 0.3, size * 0.1, 0)
		tween(ray, BURST_RAY_TIME * rng:NextNumber(0.8, 1.2), {
			Size = UDim2.fromOffset(width, length),
			Position = UDim2.new(0.5, 0, 0.5, -size * 0.3),
			BackgroundTransparency = 1,
		}, Enum.EasingStyle.Quart)
	end

	for index = 1, sparks do
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = size * rng:NextNumber(0.25, 0.7)
		local side = math.max(5, size * rng:NextNumber(0.02, 0.045))
		local spin = rng:NextNumber(0, 90)
		local spark = Kit.Frame({
			BackgroundColor3 = sparkColors[(index - 1) % #sparkColors + 1],
			AnchorPoint = CENTER,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(side, side),
			Rotation = spin,
			ZIndex = 2,
			Parent = root,
		})
		local duration = BURST_SPARK_TIME * rng:NextNumber(0.75, 1.15)
		tween(spark, duration, {
			Position = UDim2.new(
				0.5,
				math.cos(angle) * distance,
				0.5,
				math.sin(angle) * distance + size * BURST_SPARK_DROP
			),
			Rotation = spin + rng:NextNumber(-220, 220),
		}, Enum.EasingStyle.Quart)
		tween(spark, duration, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end

	Debris:AddItem(root, BURST_LIFETIME)
end

-- A slowly turning fan of soft beams. `speed` is degrees per second (negative = anticlockwise).
local function makeGodRays(
	parent: Instance,
	position: UDim2,
	color: Color3,
	radius: number,
	count: number,
	speed: number
)
	local rotor = pivot(parent, position, Z_BACK)
	for index = 1, count do
		local holder = pivot(rotor, UDim2.fromScale(0.5, 0.5), 1)
		holder.Rotation = index / count * 360
		local long = index % 2 == 0
		local ray =
			beam(holder, color, radius * (if long then 0.17 else 0.1), radius * (if long then 1 else 0.72), 0, 1)
		tween(ray, GODRAY_FADE_IN, { BackgroundTransparency = GODRAY_TRANSPARENCY })
	end
	local startedAt = os.clock()
	addAmbient(function(now: number)
		rotor.Rotation = (now - startedAt) * speed
	end)
end

-- World touch: the shrine's flame pulses toward the rarity colour while a rod
-- reveal plays. Client-side only; the original colours come back on cleanup.
local function startFlamePulse(color: Color3)
	local map = Workspace:FindFirstChild("Map")
	local vendors = map and map:FindFirstChild("Vendors")
	local shrine = vendors and vendors:FindFirstChild("RodGachaShrine")
	local flame = shrine and shrine:FindFirstChild("Flame", true)
	if not flame or not flame:IsA("BasePart") or flameRestore then
		return
	end

	local part: BasePart = flame
	local partColor = part.Color
	local light = part:FindFirstChildWhichIsA("Light")
	local lightColor = if light then light.Color else partColor
	flameRestore = function()
		part.Color = partColor
		if light then
			light.Color = lightColor
		end
	end
	addAmbient(function(now: number)
		local alpha = (0.5 + 0.5 * math.sin(now * FLAME_PULSE_SPEED)) * FLAME_PULSE_DEPTH
		part.Color = partColor:Lerp(color, alpha)
		if light then
			light.Color = lightColor:Lerp(color, alpha)
		end
	end)
end

-- Scene pieces ------------------------------------------------------------------------

local function newScene(): Frame
	local frame = Kit.Frame({
		Name = "Scene",
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = stage,
	})
	sceneScale = addScale(frame, 1)
	scene = frame
	return frame
end

local function addHeader(parent: Instance, text: string)
	-- Flanking dark-wood ribbon beam behind the carved plaque
	local rail = Kit.Frame({
		Name = "HeaderRail",
		AnchorPoint = CENTER,
		Position = at(0, HEADER_Y),
		Size = UDim2.fromOffset(556, 34),
		ZIndex = Z_TEXT,
		Parent = parent,
	})
	Kit.Corner(rail, 8)
	Kit.Gradient(rail, Color3.fromRGB(128, 80, 40), Color3.fromRGB(58, 34, 18))
	Kit.Stroke(rail, Theme.Brass, 2)

	-- Carved wood & riveted brass plaque matching the redesigned HUD / Shop sign
	local plaque = Kit.Frame({
		Name = "HeaderPlaque",
		AnchorPoint = CENTER,
		Position = at(0, HEADER_Y),
		Size = UDim2.fromOffset(496, 54),
		ZIndex = Z_TEXT + 1,
		Parent = parent,
	})
	Kit.Corner(plaque, 10)
	Kit.Gradient(plaque, WOOD_LIGHT, WOOD_DARK)
	Kit.Trim(plaque, Theme.Brass)
	Kit.Gloss(plaque)

	local groove = Kit.Frame({
		Name = "InnerGroove",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(5, 5),
		Size = UDim2.new(1, -10, 1, -10),
		ZIndex = Z_TEXT + 2,
		Parent = plaque,
	})
	Kit.Corner(groove, 6)
	Kit.Stroke(groove, Color3.fromRGB(78, 44, 20), 1.5)

	local label = centered({
		Text = text,
		Font = Kit.FontHeavy,
		TextColor3 = CREAM,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -36, 1, -10),
		ZIndex = Z_TEXT + 3,
		Parent = plaque,
	})
	fitText(label, 27)
	Kit.TextStroke(label, WOOD_INK, 3)
end

local function addSummaryLine(parent: Instance, text: string, row: number, color: Color3, big: boolean): TextLabel
	local label = centered({
		Text = text,
		Font = if big then Kit.FontHeavy else Kit.Font,
		TextColor3 = color,
		Position = at(0, SUMMARY_Y + row * SUMMARY_LINE_GAP),
		Size = UDim2.fromOffset(1000, if big then 30 else 22),
		ZIndex = Z_TEXT,
		Parent = parent,
	})
	fitText(label, if big then 24 else 16)
	outline(label, Theme.PanelDark, if big then 3 else 2)
	return label
end

-- The sealed shrine crystal: a glowing diamond with a "?" on it.
local function buildCrystal(parent: Instance, position: UDim2): Crystal
	local root = Kit.Frame({
		Name = "Crystal",
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = position,
		Size = UDim2.fromOffset(CRYSTAL_SIZE, CRYSTAL_SIZE),
		ZIndex = Z_FOCUS,
		Parent = parent,
	})
	local scale = addScale(root, 0)
	local glow, glowScale = makeGlow(root, Theme.Stroke, CRYSTAL_SIZE * 1.1)

	local body = Kit.Frame({
		BackgroundColor3 = Theme.PanelLight,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.68, 0.68),
		Rotation = 45,
		ZIndex = 2,
		Parent = root,
	})
	Kit.Corner(body, 18)
	local stroke = Kit.Stroke(body, Theme.Brass, 5)
	local shading = Instance.new("UIGradient")
	shading.Color = ColorSequence.new(WHITE, Color3.fromRGB(140, 152, 178))
	shading.Rotation = 90
	shading.Parent = body

	local rim = Kit.Frame({
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.84, 0.84),
		Parent = body,
	})
	Kit.Corner(rim, 14)
	Kit.Stroke(rim, Theme.PanelDark, 2)

	local facet = Kit.Frame({
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.7,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.55, 0.55),
		Parent = body,
	})
	Kit.Corner(facet, 10)

	local mark = centered({
		Text = "?",
		Font = Kit.FontHeavy,
		TextColor3 = CREAM,
		TextSize = 64,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(90, 90),
		ZIndex = 3,
		Parent = root,
	})
	outline(mark, WOOD_INK, 3.5)

	return { root = root, scale = scale, glow = glow, glowScale = glowScale, body = body, stroke = stroke }
end

local function tintCrystal(crystal: Crystal, color: Color3)
	crystal.body.BackgroundColor3 = Theme.PanelLight:Lerp(color, 0.6)
	crystal.stroke.Color = color:Lerp(WHITE, 0.25)
	tintGlow(crystal.glow, color)
end

-- Shakes the crystal harder and harder while its glow climbs the rarity ladder
-- one tier at a time (grey, blue, green...) up to the real rarity: "will it go
-- higher?". Returns true if the player skipped it.
local function playBuildUp(crystal: Crystal, home: UDim2, rarity: Rarity, fx: Intensity): boolean
	local ladder: { Color3 } = {}
	for _, tier: Rarity in Rarities.Order do
		table.insert(ladder, Rarities.Get(tier).color)
		if tier == rarity then
			break
		end
	end

	local steps = #ladder
	local startedAt = os.clock()
	local last = startedAt
	local shownStep = 1
	local popAt = -math.huge
	local color = ladder[1]

	while true do
		local now = os.clock()
		local elapsed = now - startedAt
		local dt = now - last
		last = now
		if elapsed >= fx.buildUp then
			return false
		end
		if takePress() then
			return true
		end

		local alpha = elapsed / fx.buildUp
		local step = math.min(steps, math.floor(alpha * steps) + 1)
		if step ~= shownStep then
			shownStep = step
			popAt = elapsed
			playSound("tease")
		end
		color = color:Lerp(ladder[step], 1 - math.exp(-dt * TEASE_BLEND_RATE))
		tintCrystal(crystal, color)

		local amplitude = SHAKE_MIN + (fx.shake - SHAKE_MIN) * alpha * alpha
		crystal.root.Position = home + shakeOffset(elapsed, amplitude)
		crystal.root.Rotation = shakeTilt(elapsed, amplitude)

		local intro = TweenService:GetValue(
			math.min(1, elapsed / CRYSTAL_IN_TIME),
			Enum.EasingStyle.Back,
			Enum.EasingDirection.Out
		)
		local pop = math.max(0, 1 - (elapsed - popAt) / TEASE_POP_TIME) * TEASE_POP_SCALE
		crystal.scale.Scale = intro * (1 + BUILD_GROWTH * alpha + pop)
		crystal.glowScale.Scale = 1 + GLOW_GROWTH * alpha + GLOW_THROB * math.sin(elapsed * GLOW_THROB_SPEED)
		task.wait()
	end
end

local function starsMarkup(stars: number): string
	local max = Rods.Stars.Max
	local filled = math.clamp(stars, 0, max)
	local markup = `<font color="#{Theme.Gold:ToHex()}">{string.rep("★", filled)}</font>`
	if filled < max then
		markup ..= `<font color="#{STAR_EMPTY:ToHex()}">{string.rep("★", max - filled)}</font>`
	end
	return markup
end

-- What the pull did for the player, for the big card.
local function rodStatus(entry: RodEntry): (string, Color3)
	if entry.isNew then
		return "NEW ROD!", Theme.Gold
	elseif entry.refundGold > 0 then
		return `Max ★ — refunded {Format.Number(entry.refundGold)} Gold`, Theme.Gold
	elseif entry.starsGained > 0 then
		return `★ UP! now ★{entry.stars}`, Theme.Good
	end
	return "+1 Rod Shard", Theme.SubText
end

-- The same, squeezed into a grid card's badge.
local function rodBadge(entry: RodEntry): (string, Color3)
	if entry.isNew then
		return "NEW!", Theme.Gold
	elseif entry.refundGold > 0 then
		return `+{Format.Number(entry.refundGold)} Gold`, Theme.Gold
	elseif entry.starsGained > 0 then
		return `★ UP! ★{entry.stars}`, Theme.Good
	end
	return "+1 Shard", Theme.SubText
end

-- The big single-pull card: riveted brass frame, deep navy-slate body, framed 3D
-- preview with rarity glow, name, stars, 4-stat bar (with Catch Bar), and status.
local function buildRodCard(parent: Instance, position: UDim2, entry: RodEntry): RodCard
	local def = entry.def
	local rarity: Rarity = def.rarity
	local color = Rarities.Get(rarity).color
	local stats = Rods.GetStats(def.id, entry.stars)
	local innerWidth = CARD_SIZE.X - 44

	local root = Kit.Frame({
		Name = "RodCard",
		AnchorPoint = CENTER,
		Position = position,
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		ZIndex = Z_FOCUS,
		Parent = parent,
	})
	Kit.Corner(root, 14)
	verticalGradient(root, Color3.fromRGB(46, 58, 78), Theme.PanelDark)
	Kit.Trim(root, Theme.Brass)
	Kit.Gloss(root)
	local scale = addScale(root, 1)

	-- Recessed deep navy-slate interior well with rarity accent rim
	local inset = Kit.Frame({
		Name = "Inset",
		Position = UDim2.fromOffset(9, 9),
		Size = UDim2.new(1, -18, 1, -18),
		ZIndex = Z_FOCUS,
		Parent = root,
	})
	Kit.Corner(inset, 10)
	verticalGradient(inset, Color3.fromRGB(22, 33, 50), Theme.PanelDark)
	Kit.Stroke(inset, color:Lerp(Theme.Brass, 0.25), 2)

	-- Rarity ribbon plaque straddling the top edge
	local ribbon = Kit.Frame({
		Name = "RarityRibbon",
		AnchorPoint = CENTER,
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(224, 34),
		ZIndex = Z_FOCUS + 3,
		Parent = root,
	})
	Kit.Corner(ribbon, 10)
	Kit.Gradient(ribbon, color:Lerp(WHITE, 0.2), color:Lerp(Theme.PanelDark, 0.38))
	Kit.Stroke(ribbon, Theme.Brass, 2.5)
	Kit.Gloss(ribbon)
	local ribbonLabel = centered({
		Text = string.upper(rarity),
		Font = Kit.FontHeavy,
		TextColor3 = WHITE,
		TextSize = 17,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z_FOCUS + 4,
		Parent = ribbon,
	})
	Kit.TextStroke(ribbonLabel, Theme.PanelDark, 2.5)

	-- Framed 3D preview showcase box with multi-layer rarity glow
	local case = Kit.Frame({
		Name = "PreviewCase",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 28),
		Size = UDim2.fromOffset(innerWidth, 210),
		ZIndex = Z_FOCUS + 1,
		Parent = root,
	})
	Kit.Corner(case, 10)
	verticalGradient(case, Color3.fromRGB(14, 22, 36), Color3.fromRGB(8, 12, 20))
	Kit.Trim(case, color:Lerp(Theme.Brass, 0.35))
	disc(case, color, 196, 0.78)
	disc(case, color, 128, 0.72)
	disc(case, color:Lerp(WHITE, 0.45), 72, 0.84)
	addPreview(case, "Rod", def.id)

	local nameLabel = centered({
		Text = def.name,
		Font = Kit.FontHeavy,
		TextColor3 = if INTENSITY[rarity].pulseTitle then color:Lerp(WHITE, 0.38) else CREAM,
		Position = UDim2.new(0.5, 0, 0, 264),
		Size = UDim2.fromOffset(innerWidth, 38),
		ZIndex = Z_FOCUS + 1,
		Parent = root,
	})
	fitText(nameLabel, 32)
	Kit.TextStroke(nameLabel, Theme.PanelDark, 3)
	local nameScale = addScale(nameLabel, 1)

	local starLabel = centered({
		Text = starsMarkup(entry.stars),
		RichText = true,
		TextSize = 26,
		Position = UDim2.new(0.5, 0, 0, 298),
		Size = UDim2.fromOffset(innerWidth, 28),
		ZIndex = Z_FOCUS + 1,
		Parent = root,
	})
	Kit.TextStroke(starLabel, Theme.PanelDark, 2)

	-- 2x2 bevelled stat chips: Luck, Weight, Mutation, and +X% Catch Bar
	local statSpecs: { { text: string, tint: Color3 } } = {
		{ text = string.format("%.2fx Luck", stats.luck), tint = Theme.Gold },
		{ text = string.format("%.2fx Weight", stats.weight), tint = Color3.fromRGB(112, 212, 255) },
		{
			text = string.format("+%d%% Mutation", math.floor(stats.mutationBonus * 100 + 0.5)),
			tint = Color3.fromRGB(206, 148, 255),
		},
		{
			text = string.format("+%d%% Catch Bar", math.floor(stats.barSizeBonus * 100 + 0.5)),
			tint = Color3.fromRGB(116, 238, 152),
		},
	}
	local chipGap = 6
	local chipWidth = (innerWidth - chipGap) * 0.5
	local chipHeight = 27
	for idx, statSpec in statSpecs do
		local col = (idx - 1) % 2
		local row = (idx - 1) // 2
		local chip = Kit.Frame({
			BackgroundColor3 = Theme.PanelDark,
			BackgroundTransparency = 0.14,
			Position = UDim2.fromOffset(22 + col * (chipWidth + chipGap), 320 + row * (chipHeight + chipGap)),
			Size = UDim2.fromOffset(chipWidth, chipHeight),
			ZIndex = Z_FOCUS + 1,
			Parent = root,
		})
		Kit.Corner(chip, 6)
		Kit.Stroke(chip, statSpec.tint:Lerp(Theme.Steel, 0.45), 1.5)
		local chipLabel = centered({
			Text = statSpec.text,
			Font = Kit.FontHeavy,
			TextColor3 = statSpec.tint,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -10, 1, -2),
			ZIndex = Z_FOCUS + 2,
			Parent = chip,
		})
		fitText(chipLabel, 14)
		Kit.TextStroke(chipLabel, Theme.PanelDark, 1.8)
	end

	-- Warm brass divider rule
	Kit.Frame({
		BackgroundColor3 = Theme.Brass,
		BackgroundTransparency = 0.42,
		AnchorPoint = CENTER,
		Position = UDim2.new(0.5, 0, 0, 392),
		Size = UDim2.fromOffset(innerWidth - 24, 2),
		ZIndex = Z_FOCUS + 1,
		Parent = root,
	})

	-- Carved status banner (NEW ROD! / ★ UP! / +1 Rod Shard / Gold refund)
	local statusText, statusColor = rodStatus(entry)
	local statusLabel = centered({
		Text = statusText,
		Font = Kit.FontHeavy,
		TextColor3 = statusColor,
		Position = UDim2.new(0.5, 0, 0, 420),
		Size = UDim2.fromOffset(innerWidth, 34),
		ZIndex = Z_FOCUS + 2,
		Parent = root,
	})
	fitText(statusLabel, 25)
	Kit.TextStroke(statusLabel, Theme.PanelDark, 2.5)
	local statusScale = addScale(statusLabel, 0)

	local descLabel = centered({
		Text = def.description,
		Font = Kit.FontBody,
		TextColor3 = Theme.SubText,
		TextSize = 14,
		Position = UDim2.new(0.5, 0, 0, 472),
		Size = UDim2.fromOffset(innerWidth - 10, 44),
		ZIndex = Z_FOCUS + 1,
		Parent = root,
	})
	Kit.TextStroke(descLabel, Theme.PanelDark, 1.5)

	return { root = root, scale = scale, nameScale = nameScale, statusScale = statusScale }
end

-- A small two-faced card for the grid. It starts face-down and hidden (scale 0);
-- the 3D preview is only created when the card is turned over.
local function buildMiniCard(parent: Instance, position: UDim2, spec: MiniSpec): MiniCard
	local color = Rarities.Get(spec.rarity).color

	local slot = Kit.Frame({
		Name = "Card",
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = position,
		Size = UDim2.fromOffset(MINI_SIZE.X, MINI_SIZE.Y),
		ZIndex = Z_FOCUS,
		Parent = parent,
	})
	local scale = addScale(slot, 0)

	-- The flip squashes this frame's width to zero and back; it clips so the
	-- faces' text cannot spill out while the card is edge-on.
	local flipper = Kit.Frame({
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		Parent = slot,
	})

	-- Card back: deep navy-slate with riveted brass trim & carved wood diamond seal.
	local back = Kit.Frame({
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -8, 1, -8),
		Parent = flipper,
	})
	Kit.Corner(back, 11)
	verticalGradient(back, Color3.fromRGB(44, 58, 80), Theme.PanelDark)
	local backStroke = Kit.Stroke(back, Theme.Brass, 2.5)
	Kit.Trim(back, Theme.Brass)
	Kit.Gloss(back)

	local emblem = Kit.Frame({
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(60, 60),
		Rotation = 45,
		Parent = back,
	})
	Kit.Corner(emblem, 9)
	Kit.Gradient(emblem, WOOD_LIGHT, WOOD_DARK)
	Kit.Stroke(emblem, Theme.Brass, 2.5)
	local backMark = centered({
		Text = "?",
		Font = Kit.FontHeavy,
		TextColor3 = CREAM,
		TextSize = 32,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(50, 50),
		ZIndex = 2,
		Parent = back,
	})
	Kit.TextStroke(backMark, WOOD_INK, 2.5)

	-- Card front: deep navy-slate surface, riveted rarity-brass border, recessed preview well.
	local front = Kit.Frame({
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -8, 1, -8),
		Visible = false,
		Parent = flipper,
	})
	Kit.Corner(front, 11)
	verticalGradient(front, Color3.fromRGB(34, 48, 70), Theme.PanelDark)
	local frontTrimColor = color:Lerp(Theme.Brass, 0.28)
	local frontStroke = Kit.Stroke(front, frontTrimColor, 3)
	Kit.Trim(front, frontTrimColor)
	frontStroke.Thickness = 3
	Kit.Gloss(front)

	local band = Kit.Frame({
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 9),
		Size = UDim2.new(1, -28, 0, 4),
		Parent = front,
	})
	Kit.Corner(band, 2)

	local viewportHolder = Kit.Frame({
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.22,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 18),
		Size = UDim2.fromOffset(148, 108),
		Parent = front,
	})
	Kit.Corner(viewportHolder, 8)
	Kit.Stroke(viewportHolder, color:Lerp(Theme.Brass, 0.35), 1.5)
	disc(viewportHolder, color, 92, 0.78)

	local nameLabel = centered({
		Text = spec.name,
		Font = Kit.FontHeavy,
		TextColor3 = Theme.Text,
		Position = UDim2.new(0.5, 0, 0, 146),
		Size = UDim2.new(1, -14, 0, 32),
		Parent = front,
	})
	fitText(nameLabel, 16)
	Kit.TextStroke(nameLabel, Theme.PanelDark, 2)

	local rarityLabel = centered({
		Text = string.upper(spec.rarity),
		Font = Kit.FontHeavy,
		TextColor3 = color,
		TextSize = 11,
		Position = UDim2.new(0.5, 0, 0, 171),
		Size = UDim2.new(1, -14, 0, 14),
		Parent = front,
	})
	Kit.TextStroke(rarityLabel, Theme.PanelDark, 1.8)

	local badge = Kit.Frame({
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.16,
		AnchorPoint = CENTER,
		Position = UDim2.new(0.5, 0, 0, 198),
		Size = UDim2.new(1, -26, 0, 24),
		Parent = front,
	})
	Kit.Corner(badge, 10)
	Kit.Stroke(badge, spec.badgeColor, 1.6)
	local badgeLabel = centered({
		Text = spec.badge,
		Font = Kit.FontHeavy,
		TextColor3 = spec.badgeColor,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -10, 1, -4),
		Parent = badge,
	})
	fitText(badgeLabel, 14)
	Kit.TextStroke(badgeLabel, Theme.PanelDark, 1.8)

	return {
		spec = spec,
		home = position,
		slot = slot,
		scale = scale,
		flipper = flipper,
		back = back,
		backStroke = backStroke,
		front = front,
		frontStroke = frontStroke,
		viewportHolder = viewportHolder,
		revealed = false,
		hasHalo = false,
	}
end

-- Where each card of a centred grid goes (a short last row is centred too).
local function gridPositions(count: number, cellScale: number): { UDim2 }
	local positions: { UDim2 } = {}
	local rows = math.ceil(count / GRID_COLUMNS)
	local stepX = (MINI_SIZE.X + GRID_GAP) * cellScale
	local stepY = (MINI_SIZE.Y + GRID_GAP) * cellScale
	for index = 1, count do
		local row = (index - 1) // GRID_COLUMNS
		local column = (index - 1) % GRID_COLUMNS
		local inRow = if row == rows - 1 then count - row * GRID_COLUMNS else GRID_COLUMNS
		local x = (column - (inRow - 1) / 2) * stepX
		local y = (row - (rows - 1) / 2) * stepY
		table.insert(positions, at(x, GRID_CENTER_Y + y))
	end
	return positions
end

-- A rarity-coloured glow peeking out from behind a grid card.
local function addHalo(card: MiniCard)
	if card.hasHalo then
		return
	end
	card.hasHalo = true
	makeGlow(card.slot, Rarities.Get(card.spec.rarity).color, MINI_SIZE.X * 0.95)
end

local function showFront(card: MiniCard)
	if card.revealed then
		return
	end
	card.revealed = true
	card.back.Visible = false
	card.front.Visible = true
	if Rarities.IsAtLeast(card.spec.rarity, MINI_BURST_MIN) then
		addHalo(card)
	end
	addPreview(card.viewportHolder, card.spec.kind, card.spec.id)
end

-- Turns a card over. Yields for the first half of the flip only.
local function flipMini(card: MiniCard)
	playSound("flip")
	tween(card.flipper, FLIP_HALF, { Size = UDim2.fromScale(0, 1) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.wait(FLIP_HALF)
	showFront(card)
	tween(card.flipper, FLIP_HALF * FLIP_SETTLE, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Back)
end

-- An Epic+ card charges up before it flips: halo, coloured stroke, growing shake.
-- Returns true if the player pressed (fast-forward).
local function chargeMini(card: MiniCard): boolean
	local color = Rarities.Get(card.spec.rarity).color
	card.slot.ZIndex = Z_FOCUS + 1
	addHalo(card)
	tween(card.backStroke, MINI_CHARGE_TIME, { Color = color, Thickness = 4 })

	local startedAt = os.clock()
	local pressed = false
	while true do
		local elapsed = os.clock() - startedAt
		if elapsed >= MINI_CHARGE_TIME then
			break
		end
		if takePress() then
			pressed = true
			break
		end
		local amplitude = MINI_CHARGE_SHAKE * elapsed / MINI_CHARGE_TIME
		card.slot.Position = card.home + shakeOffset(elapsed, amplitude)
		card.slot.Rotation = shakeTilt(elapsed, amplitude)
		task.wait()
	end
	card.slot.Position = card.home
	card.slot.Rotation = 0
	return pressed
end

-- The little version of the big burst, fired from a grid card.
local function miniBurst(parent: Instance, card: MiniCard)
	local rarity: Rarity = card.spec.rarity
	local color = Rarities.Get(rarity).color
	local fx = INTENSITY[rarity]
	playSound("burst")
	playBurst(
		parent,
		card.home,
		color,
		MINI_BURST_SIZE,
		math.ceil(fx.rays * MINI_FX_SCALE),
		math.ceil(fx.sparks * MINI_FX_SCALE),
		1,
		Z_OVER
	)
	flashScreen(color, fx.flash * MINI_FX_SCALE)
end

-- Turns every card that is still face-down at once (a quick staggered pop).
-- Returns how long the pops take.
local function revealRemaining(cards: { MiniCard }, cellScale: number): number
	local count = 0
	for _, card in cards do
		if not card.revealed then
			showFront(card)
			card.flipper.Size = UDim2.fromScale(1, 1)
			card.scale.Scale = cellScale * FAST_POP_FROM
			-- Also replaces a deal-in tween that may still be waiting on this card.
			tween(card.scale, FAST_POP_TIME, { Scale = cellScale }, Enum.EasingStyle.Back, nil, count * FAST_STAGGER)
			count += 1
		end
	end
	if count == 0 then
		return 0
	end
	playSound("flip")
	return FAST_POP_TIME + count * FAST_STAGGER
end

-- Final beat of every reveal: show the hint, then wait for a press or the timeout.
local function waitForDismiss()
	pressPending = false
	hint.Text = hintText()
	hint.TextTransparency = HINT_MIN_TRANSPARENCY
	hint.Visible = true
	local shownAt = os.clock()
	addAmbient(function(now: number)
		local wave = 0.5 - 0.5 * math.cos((now - shownAt) * HINT_PULSE_SPEED)
		hint.TextTransparency = HINT_MIN_TRANSPARENCY + (HINT_MAX_TRANSPARENCY - HINT_MIN_TRANSPARENCY) * wave
	end)
	waitOrPress(AUTO_DISMISS_TIME)
	hint.Visible = false
	playSound("dismiss")
end

-- Reveals -----------------------------------------------------------------------------

local function revealSingleRod(entry: RodEntry)
	local rarity: Rarity = entry.def.rarity
	local color = Rarities.Get(rarity).color
	local fx = INTENSITY[rarity]
	local focus = at(0, FOCUS_Y)
	local frame = newScene()

	addHeader(frame, "ROD GACHA SHRINE")
	startFlamePulse(color)

	-- Build-up: the sealed crystal shakes and its glow climbs toward the rarity.
	local crystal = buildCrystal(frame, focus)
	playSound("buildup")
	local skipped = playBuildUp(crystal, focus, rarity, fx)
	crystal.root:Destroy()

	-- Burst.
	playSound("burst")
	playBurst(frame, focus, color, BURST_SIZE, fx.rays, fx.sparks, fx.rings, Z_BACK)
	flashScreen(color, fx.flash)
	if fx.godRays >= 1 then
		makeGodRays(frame, focus, color, GODRAY_RADIUS, GODRAY_COUNT, GODRAY_SPEED)
	end
	if fx.godRays >= 2 then
		makeGodRays(
			frame,
			focus,
			color:Lerp(WHITE, 0.5),
			GODRAY_RADIUS * GODRAY_INNER_RADIUS,
			GODRAY_COUNT - 4,
			GODRAY_SPEED * GODRAY_INNER_SPEED
		)
	end
	task.wait(BURST_LEAD)

	-- Reveal.
	playSound("reveal")
	local card = buildRodCard(frame, focus, entry)
	card.scale.Scale = CARD_POP_FROM
	tween(card.scale, CARD_IN_TIME, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(card.statusScale, STATUS_POP_TIME, { Scale = 1 }, Enum.EasingStyle.Back, nil, CARD_IN_TIME)

	local landedAt = os.clock()
	if fx.cardShake > 0 then
		addAmbient(function(now: number)
			local elapsed = now - landedAt
			local amplitude = fx.cardShake * math.max(0, 1 - elapsed / CARD_SHAKE_TIME)
			card.root.Position = focus + shakeOffset(elapsed, amplitude)
			card.root.Rotation = shakeTilt(elapsed, amplitude) * 0.5
		end)
	end
	if fx.pulseTitle then
		addAmbient(function(now: number)
			local wave = 0.5 - 0.5 * math.cos((now - landedAt) * TITLE_PULSE_SPEED)
			card.nameScale.Scale = 1 + TITLE_PULSE_DEPTH * wave
		end)
	end

	-- A player who skipped the build-up is in a hurry: keep only a short guard.
	local hold = if skipped then math.min(fx.hold, SKIP_HOLD) else fx.hold
	task.wait(CARD_IN_TIME + hold)
	waitForDismiss()
end

-- Highest rarity wins; a new rod beats a duplicate of the same rarity; earliest wins ties.
local function bestRodIndex(entries: { RodEntry }): number
	local best = 1
	for index, entry in entries do
		local current = entries[best]
		local order = Rarities.Get(entry.def.rarity).order
		local bestOrder = Rarities.Get(current.def.rarity).order
		if order > bestOrder or (order == bestOrder and entry.isNew and not current.isNew) then
			best = index
		end
	end
	return best
end

local function rodTally(entries: { RodEntry }): string
	local newRods, starUps, shards, refund = 0, 0, 0, 0
	for _, entry in entries do
		if entry.isNew then
			newRods += 1
		elseif entry.refundGold > 0 then
			refund += entry.refundGold
		else
			shards += 1
			if entry.starsGained > 0 then
				starUps += 1
			end
		end
	end
	local parts: { string } = {}
	if newRods > 0 then
		table.insert(parts, if newRods == 1 then "1 new rod" else `{newRods} new rods`)
	end
	if starUps > 0 then
		table.insert(parts, if starUps == 1 then "1 star-up" else `{starUps} star-ups`)
	end
	if shards > 0 then
		table.insert(parts, if shards == 1 then "+1 shard" else `+{shards} shards`)
	end
	if refund > 0 then
		table.insert(parts, `+{Format.Number(refund)} Gold refunded`)
	end
	return table.concat(parts, "  ·  ")
end

local function revealRodGrid(entries: { RodEntry })
	local count = #entries
	local bestIndex = bestRodIndex(entries)
	local bestDef = entries[bestIndex].def
	local bestRarity: Rarity = bestDef.rarity
	local bestColor = Rarities.Get(bestRarity).color
	local frame = newScene()

	addHeader(frame, `ROD GACHA SHRINE  ·  {count} PULLS`)
	startFlamePulse(bestColor)

	-- Deal the cards face-down.
	local positions = gridPositions(count, 1)
	local cards: { MiniCard } = {}
	for index, entry in entries do
		local badge, badgeColor = rodBadge(entry)
		local card = buildMiniCard(frame, positions[index], {
			kind = "Rod",
			id = entry.def.id,
			name = entry.def.name,
			rarity = entry.def.rarity,
			badge = badge,
			badgeColor = badgeColor,
		})
		tween(card.scale, DEAL_TIME, { Scale = 1 }, Enum.EasingStyle.Back, nil, (index - 1) * DEAL_STAGGER)
		table.insert(cards, card)
	end
	playSound("buildup")
	local fast = waitOrPress(DEAL_TIME + count * DEAL_STAGGER)

	-- Flip them one after another; Epic+ gets a charge-up, a mini burst and a pause.
	for _, card in cards do
		if fast then
			break
		end
		local big = Rarities.IsAtLeast(card.spec.rarity, MINI_BURST_MIN)
		if big then
			fast = chargeMini(card)
		end
		if not fast then
			flipMini(card)
			if big then
				miniBurst(frame, card)
				card.scale.Scale = MINI_BURST_POP
				tween(card.scale, FLIP_INTERVAL, { Scale = 1 }, Enum.EasingStyle.Back)
				fast = waitOrPress(MINI_BURST_PAUSE)
			else
				fast = waitOrPress(FLIP_INTERVAL - FLIP_HALF)
			end
		end
	end

	-- First press lands here: everything still face-down turns at once.
	task.wait(revealRemaining(cards, 1))

	-- Summary: all ten stay up, the best one is crowned.
	playSound("reveal")
	local bestCard = cards[bestIndex]
	bestCard.slot.ZIndex = Z_FOCUS + 2
	addHalo(bestCard)
	tween(bestCard.scale, DEAL_TIME, { Scale = BEST_SCALE }, Enum.EasingStyle.Back)
	makeGodRays(frame, bestCard.home, bestColor, MINI_SIZE.Y, GODRAY_COUNT - 2, GODRAY_SPEED)
	local crown = Kit.Frame({
		AnchorPoint = CENTER,
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(82, 24),
		ZIndex = 3,
		Parent = bestCard.slot,
	})
	Kit.Corner(crown, 10)
	Kit.Gradient(crown, Color3.fromRGB(255, 226, 112), Color3.fromRGB(196, 132, 34))
	Kit.Stroke(crown, WOOD_INK, 2)
	Kit.Gloss(crown)
	local crownLabel = centered({
		Text = "★ BEST",
		Font = Kit.FontHeavy,
		TextColor3 = CREAM,
		TextSize = 13,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = crown,
	})
	Kit.TextStroke(crownLabel, WOOD_INK, 2)
	local crownedAt = os.clock()
	addAmbient(function(now: number)
		bestCard.frontStroke.Thickness = 3 + 0.5 * (1 - math.cos((now - crownedAt) * BEST_PULSE_SPEED))
	end)

	addSummaryLine(frame, `BEST PULL  ·  {bestDef.name}  ·  {string.upper(bestRarity)}`, 0, bestColor, true)
	addSummaryLine(frame, rodTally(entries), 1, Theme.SubText, false)

	task.wait(SUMMARY_GUARD)
	waitForDismiss()
end

local function buildCrate(parent: Instance, position: UDim2): Crate
	local root = Kit.Frame({
		Name = "Crate",
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = position,
		Size = UDim2.fromOffset(CRATE_SIZE.X, CRATE_SIZE.Y),
		ZIndex = Z_FOCUS,
		Parent = parent,
	})
	local scale = addScale(root, 0)
	local glow, glowScale = makeGlow(root, Theme.Brass, CRATE_SIZE.X)

	local body = Kit.Frame({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.76),
		ZIndex = 2,
		Parent = root,
	})
	Kit.Corner(body, 9)
	Kit.Gradient(body, CRATE_COLOR, CRATE_WOOD_DARK)
	Kit.Stroke(body, CRATE_DARK, 4)

	-- Horizontal wood plank seams + sunlit plank top highlights
	for _, y in { 0.34, 0.67 } do
		Kit.Frame({
			BackgroundColor3 = CRATE_DARK,
			AnchorPoint = CENTER,
			Position = UDim2.fromScale(0.5, y),
			Size = UDim2.new(1, 0, 0, 4),
			ZIndex = 2,
			Parent = body,
		})
		Kit.Frame({
			BackgroundColor3 = Color3.fromRGB(232, 178, 108),
			BackgroundTransparency = 0.55,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, y, 2),
			Size = UDim2.new(1, -24, 0, 3),
			ZIndex = 2,
			Parent = body,
		})
	end

	-- Diagonal wooden cross-brace inside the recessed plank face
	local braceClip = Kit.Frame({
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -28, 1, -16),
		ClipsDescendants = true,
		ZIndex = 3,
		Parent = body,
	})
	local brace = Kit.Frame({
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1.35, 0, 0, 18),
		Rotation = -32,
		ZIndex = 3,
		Parent = braceClip,
	})
	Kit.Gradient(brace, Color3.fromRGB(194, 138, 78), Color3.fromRGB(122, 76, 38))
	Kit.Stroke(brace, CRATE_DARK, 2.5)

	-- Vertical wood corner stiles + riveted brass corner brackets
	for _, xAnchor in { 0, 1 } do
		local stile = Kit.Frame({
			AnchorPoint = Vector2.new(xAnchor, 0.5),
			Position = UDim2.fromScale(xAnchor, 0.5),
			Size = UDim2.new(0, 16, 1, 0),
			ZIndex = 4,
			Parent = body,
		})
		Kit.Corner(stile, 4)
		Kit.Gradient(stile, Color3.fromRGB(162, 108, 56), Color3.fromRGB(96, 58, 30))
		Kit.Stroke(stile, CRATE_DARK, 2)
	end
	Kit.Trim(body, Theme.Brass)

	-- Gleaming brass clasp latch with keyhole
	local latch = Kit.Frame({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -2),
		Size = UDim2.fromOffset(32, 36),
		ZIndex = 5,
		Parent = body,
	})
	Kit.Corner(latch, 6)
	Kit.Gradient(latch, Theme.Gold, Color3.fromRGB(176, 118, 32))
	Kit.Stroke(latch, CRATE_DARK, 3)
	Kit.Gloss(latch)
	local keyhole = Kit.Frame({
		BackgroundColor3 = CRATE_DARK,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.58),
		Size = UDim2.fromOffset(7, 11),
		ZIndex = 6,
		Parent = latch,
	})
	Kit.Corner(keyhole, 4)

	-- Planked wood crate lid with top bevel highlight and brass end-caps
	local lid = Kit.Frame({
		BackgroundColor3 = CRATE_LID_COLOR,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.28),
		Size = UDim2.fromScale(1.08, 0.22),
		ZIndex = 6,
		Parent = root,
	})
	Kit.Corner(lid, 8)
	Kit.Gradient(lid, CRATE_LID_COLOR, Color3.fromRGB(134, 84, 42))
	local lidStroke = Kit.Stroke(lid, CRATE_DARK, 4)
	Kit.Gloss(lid)
	for _, xAnchor in { 0, 1 } do
		local cap = Kit.Frame({
			AnchorPoint = Vector2.new(xAnchor, 0.5),
			Position = UDim2.new(xAnchor, if xAnchor == 0 then 3 else -3, 0.5, 0),
			Size = UDim2.new(0, 14, 1, -6),
			ZIndex = 7,
			Parent = lid,
		})
		Kit.Corner(cap, 4)
		Kit.Gradient(cap, Theme.Gold, Color3.fromRGB(168, 112, 32))
		Kit.Stroke(cap, CRATE_DARK, 1.5)
	end

	return { root = root, scale = scale, glow = glow, glowScale = glowScale, lid = lid, lidStroke = lidStroke }
end

-- The crate rattles while its glow warms toward the best rarity inside.
-- Returns true if the player skipped it.
local function playCrateShake(crate: Crate, home: UDim2, color: Color3): boolean
	local startedAt = os.clock()
	while true do
		local elapsed = os.clock() - startedAt
		if elapsed >= CRATE_SHAKE_TIME then
			return false
		end
		if takePress() then
			return true
		end
		local alpha = elapsed / CRATE_SHAKE_TIME
		local amplitude = SHAKE_MIN + (CRATE_SHAKE - SHAKE_MIN) * alpha * alpha
		crate.root.Position = home + shakeOffset(elapsed, amplitude)
		crate.root.Rotation = shakeTilt(elapsed, amplitude)
		crate.lid.Rotation = math.sin(elapsed * SHAKE_FREQUENCY.X) * amplitude * CRATE_LID_RATTLE
		crate.scale.Scale = TweenService:GetValue(
			math.min(1, elapsed / CRYSTAL_IN_TIME),
			Enum.EasingStyle.Back,
			Enum.EasingDirection.Out
		)
		tintGlow(crate.glow, Theme.Stroke:Lerp(color, alpha))
		crate.glowScale.Scale = 0.6 + GLOW_GROWTH * alpha
		task.wait()
	end
end

local function baitTally(entries: { BaitEntry }): string
	local totals: { [string]: number } = {}
	local order: { string } = {}
	for _, entry in entries do
		if not totals[entry.def.id] then
			totals[entry.def.id] = 0
			table.insert(order, entry.def.id)
		end
		totals[entry.def.id] += entry.amount
	end
	local parts: { string } = {}
	for _, baitId in order do
		local def = Baits.Get(baitId)
		if def then
			table.insert(parts, `{def.name} x{totals[baitId]}`)
		end
	end
	return table.concat(parts, "  ·  ")
end

local function revealBaits(entries: { BaitEntry })
	local count = #entries
	local bestRarity: Rarity = entries[1].def.rarity
	for _, entry in entries do
		if Rarities.Get(entry.def.rarity).order > Rarities.Get(bestRarity).order then
			bestRarity = entry.def.rarity
		end
	end
	local bestColor = Rarities.Get(bestRarity).color
	local focus = at(0, FOCUS_Y)
	local frame = newScene()

	addHeader(frame, if count == 1 then "BAIT CRATE" else `BAIT CRATES  ·  x{count}`)

	-- Build-up: lighter than a rod pull.
	local crate = buildCrate(frame, focus)
	playSound("buildup")
	playCrateShake(crate, focus, bestColor)

	-- Pop: the lid flies off and the crate vanishes inside its own burst.
	playSound("burst")
	crate.root.Position = focus
	crate.root.Rotation = 0
	tween(crate.lid, CRATE_POP_TIME, {
		Position = UDim2.new(0.62, 0, 0.3, -190),
		Rotation = 40,
		BackgroundTransparency = 1,
	})
	tween(crate.lidStroke, CRATE_POP_TIME, { Transparency = 1 })
	tween(crate.scale, CRATE_POP_TIME, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	playBurst(frame, focus, bestColor, CRATE_BURST_SIZE, CRATE_RAYS, CRATE_SPARKS, 1, Z_BACK)
	flashScreen(bestColor, INTENSITY[bestRarity].flash * MINI_FX_SCALE)
	Debris:AddItem(crate.root, CRATE_POP_TIME)
	task.wait(CRATE_POP_TIME)

	-- One card per result, popping in face-up one after another.
	local cellScale = if count == 1 then MINI_SOLO_SCALE else 1
	local positions = gridPositions(count, cellScale)
	local cards: { MiniCard } = {}
	for index, entry in entries do
		table.insert(
			cards,
			buildMiniCard(frame, positions[index], {
				kind = "Bait",
				id = entry.def.id,
				name = entry.def.name,
				rarity = entry.def.rarity,
				badge = `x{entry.amount}`,
				badgeColor = Theme.Gold,
			})
		)
	end

	local fast = false
	for _, card in cards do
		if fast then
			break
		end
		playSound("reveal")
		showFront(card)
		tween(card.scale, DEAL_TIME, { Scale = cellScale }, Enum.EasingStyle.Back)
		if Rarities.IsAtLeast(card.spec.rarity, MINI_BURST_MIN) then
			miniBurst(frame, card)
		end
		fast = waitOrPress(BAIT_CARD_INTERVAL)
	end
	task.wait(revealRemaining(cards, cellScale))

	if count > 1 then
		addSummaryLine(frame, baitTally(entries), 0, Theme.Text, true)
	end

	task.wait(SUMMARY_GUARD)
	waitForDismiss()
end

-- Overlay lifecycle --------------------------------------------------------------------

local function build()
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", PLAYER_GUI_TIMEOUT)
	if not playerGui then
		error("PlayerGui is not available")
	end
	if built then
		gui:Destroy()
	end

	gui = Kit.ScreenGui("GachaReveal", DISPLAY_ORDER)
	gui.IgnoreGuiInset = true
	gui.Enabled = false

	-- Dims the game and swallows clicks/taps so nothing under the overlay reacts.
	-- Modal frees the mouse for players in first person or shift-lock.
	dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.Modal = true
	dim.BorderSizePixel = 0
	dim.BackgroundColor3 = DIM_COLOR
	dim.BackgroundTransparency = 1
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = gui

	stage = Kit.Frame({
		Name = "Stage",
		BackgroundTransparency = 1,
		AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(STAGE_SIZE.X, STAGE_SIZE.Y),
		ZIndex = 2,
		Parent = gui,
	})
	-- Kit.AutoScale puts its UIScale on the ScreenGui, which would shrink the
	-- full-screen dim and flash layers along with the content. Moved onto the
	-- centred stage it scales only the content, about the screen centre.
	Kit.AutoScale(gui).Parent = stage

	hint = centered({
		Name = "Hint",
		Text = "",
		Font = Kit.FontHeavy,
		TextColor3 = CREAM,
		TextSize = 16,
		Position = at(0, HINT_Y),
		Size = UDim2.fromOffset(700, 24),
		ZIndex = Z_TEXT,
		Visible = false,
		Parent = stage,
	})
	Kit.TextStroke(hint, Theme.PanelDark, 2)

	flash = Kit.Frame({
		Name = "Flash",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = gui,
	})

	gui.Parent = playerGui
	built = true
end

local function showOverlay()
	pressPending = false
	overlayActive = true
	hint.Visible = false
	flash.BackgroundTransparency = 1
	dim.BackgroundTransparency = 1
	gui.Enabled = true
	tween(dim, FADE_IN_TIME, { BackgroundTransparency = DIM_TRANSPARENCY })

	-- Space / Enter / gamepad A count as a press and are swallowed, so Space does
	-- not also make the character jump behind the overlay.
	ContextActionService:BindActionAtPriority(
		SINK_ACTION,
		function(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				registerPress()
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 1,
		Enum.KeyCode.Space,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter,
		Enum.KeyCode.ButtonA
	)

	ambientConnection = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		for index = #ambient, 1, -1 do
			-- A broken effect is dropped rather than erroring every frame.
			if not pcall(ambient[index], now) then
				table.remove(ambient, index)
			end
		end
	end)
end

-- Instant, yield-free teardown. Safe to call at any time, any number of times;
-- each step is isolated so one failure (say, a destroyed instance) cannot stop
-- the rest.
local function forceHide()
	overlayActive = false
	pressPending = false
	pcall(function()
		ContextActionService:UnbindAction(SINK_ACTION)
	end)
	if ambientConnection then
		ambientConnection:Disconnect()
		ambientConnection = nil
	end
	table.clear(ambient)

	local restore = flameRestore
	flameRestore = nil
	if restore then
		pcall(restore)
	end

	local oldScene = scene
	scene = nil
	sceneScale = nil
	if oldScene then
		pcall(function()
			oldScene:Destroy() -- also destroys the previews, which stops their spin
		end)
	end

	if built then
		pcall(function()
			hint.Visible = false
			flash.BackgroundTransparency = 1
			dim.BackgroundTransparency = 1
			gui.Enabled = false
		end)
	end
end

-- The normal exit: the scene shrinks away while the dim lifts.
local function fadeOut()
	overlayActive = false
	tween(dim, FADE_OUT_TIME, { BackgroundTransparency = 1 })
	tween(flash, FADE_OUT_TIME, { BackgroundTransparency = 1 })
	local scale = sceneScale
	if scale then
		tween(scale, FADE_OUT_TIME, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	end
	task.wait(FADE_OUT_TIME)
end

-- Queue -------------------------------------------------------------------------------

local startRunner: () -> ()

local function runJob(job: Job)
	if not built or gui.Parent == nil then
		build()
	end
	showOverlay()
	job()
	fadeOut()
end

-- Last line of defence: if a reveal is somehow still going after WATCHDOG_TIME,
-- kill its thread, tear the overlay down and carry on with the queue.
local function armWatchdog(serial: number)
	task.delay(WATCHDOG_TIME, function()
		if not playing or jobSerial ~= serial then
			return
		end
		warn("[GachaReveal] reveal timed out; closing it")
		local stuck = runner
		runner = nil
		if stuck then
			pcall(task.cancel, stuck)
		end
		forceHide()
		playing = false
		if #queue > 0 then
			startRunner()
		end
	end)
end

local function drainQueue()
	while #queue > 0 do
		local job = table.remove(queue, 1) :: Job
		jobSerial += 1
		armWatchdog(jobSerial)
		local ok, message = pcall(function()
			runJob(job)
		end)
		if not ok then
			warn(`[GachaReveal] reveal failed: {message}`)
		end
		forceHide()
		if #queue > 0 then
			task.wait(QUEUE_GAP)
		end
	end
end

function startRunner()
	if playing then
		return
	end
	playing = true
	task.spawn(function()
		runner = coroutine.running()
		local ok, message = pcall(function()
			drainQueue()
		end)
		if not ok then
			warn(`[GachaReveal] queue failed: {message}`)
			forceHide()
		end
		runner = nil
		playing = false
	end)
end

local function enqueue(job: Job)
	table.insert(queue, job)
	startRunner()
end

-- Input validation ----------------------------------------------------------------------
-- Results arrive straight from a remote response, so nothing about their shape is trusted.

local function finiteOr(value: any, fallback: number): number
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return value
	end
	return fallback
end

local function sanitizeRods(results: any): { RodEntry }
	local entries: { RodEntry } = {}
	if type(results) ~= "table" then
		return entries
	end
	for _, raw: any in ipairs(results :: { any }) do
		if #entries >= MAX_RESULTS then
			break
		end
		if type(raw) == "table" and type(raw.rodId) == "string" then
			local def = Rods.Get(raw.rodId)
			if def then
				table.insert(entries, {
					def = def,
					isNew = raw.isNew == true,
					starsGained = math.max(0, finiteOr(raw.starsGained, 0)),
					stars = math.clamp(math.floor(finiteOr(raw.stars, 1)), 1, Rods.Stars.Max),
					refundGold = math.max(0, finiteOr(raw.refundGold, 0)),
				})
			end
		end
	end
	return entries
end

local function sanitizeBaits(results: any): { BaitEntry }
	local entries: { BaitEntry } = {}
	if type(results) ~= "table" then
		return entries
	end
	for _, raw: any in ipairs(results :: { any }) do
		if #entries >= MAX_RESULTS then
			break
		end
		if type(raw) == "table" and type(raw.baitId) == "string" then
			local def = Baits.Get(raw.baitId)
			if def then
				table.insert(entries, {
					def = def,
					amount = math.max(1, math.floor(finiteOr(raw.amount, 1))),
				})
			end
		end
	end
	return entries
end

-- Public API ----------------------------------------------------------------------------

-- Plays the reveal for 1 (single pull) or up to 10 (multi-pull) rod results.
-- Returns immediately; queues behind a reveal that is already playing.
function GachaRevealController.PlayRods(results: { RodResult })
	local entries = sanitizeRods(results)
	if #entries == 0 then
		return
	end
	enqueue(function()
		if #entries == 1 then
			revealSingleRod(entries[1])
		else
			revealRodGrid(entries)
		end
	end)
end

-- Plays the reveal for 1..10 bait crate results. Returns immediately; queues
-- behind a reveal that is already playing.
function GachaRevealController.PlayBaits(results: { BaitResult })
	local entries = sanitizeBaits(results)
	if #entries == 0 then
		return
	end
	enqueue(function()
		revealBaits(entries)
	end)
end

-- True while a reveal is on screen or waiting in the queue.
function GachaRevealController.IsPlaying(): boolean
	return playing
end

function GachaRevealController.Init()
	if built then
		return
	end
	-- If PlayerGui is not ready yet the overlay is built on first use instead.
	local ok, message = pcall(function()
		build()
	end)
	if not ok then
		warn(`[GachaReveal] overlay not built yet: {message}`)
	end
end

function GachaRevealController.Start()
	if started then
		return
	end
	started = true
	-- Click / tap anywhere. The overlay's dim button has already swallowed the
	-- input by now, so `processed` is deliberately ignored; registerPress only
	-- counts presses while the overlay is up. Keys come through the sink action.
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			registerPress()
		end
	end)
end

return GachaRevealController
