--!strict
-- Player data persistence.
--
--   * One DataStore key per player holding { data = Profile, lock = SessionLock }.
--   * Session locking through UpdateAsync: a profile that is live on another
--     server is never loaded here, so two servers can't overwrite each other.
--   * A failed load NEVER falls back to default data on a live server (the player
--     is kicked instead), so a DataStore outage can't wipe progress.
--   * In Studio without DataStore access, profiles are in-memory only ("mock").
--
-- Other services mutate the Profile table directly on the server and call
-- MarkDirty(player) to push a fresh snapshot to the owning client.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Rods = require(Shared.Config.Rods)
local Baits = require(Shared.Config.Baits)
local PondConfig = require(Shared.Config.PondConfig)

type Profile = Types.Profile

type SessionLock = { jobId: string, time: number }
type Envelope = { data: Profile?, lock: SessionLock? }
type Session = {
	profile: Profile,
	mock: boolean,
	dirty: boolean,
	lastSave: number,
}

local STORE_NAME = "PlayerData_v1"
local PROFILE_VERSION = 1
local LOCK_TIMEOUT = 15 * 60 -- a lock older than this is considered abandoned
local AUTOSAVE_INTERVAL = 90
local LOAD_ATTEMPTS = 4
local SAVE_ATTEMPTS = 3
local SYNC_INTERVAL = 0.25
local MAX_PURCHASE_HISTORY = 100
local STUDIO_SAVES_ATTRIBUTE = "StudioSavesEnabled" -- opt-in switch for saving during Studio playtests

local DataService = {}

local sessions: { [Player]: Session } = {}
local loading: { [Player]: boolean } = {}
local releasing: { [Player]: boolean } = {}
local loadedCallbacks: { (Player, Profile) -> () } = {}
local releasingCallbacks: { (Player, Profile) -> () } = {}
local snapshotExtensions: { (Player, { [string]: any }) -> () } = {}

local store: DataStore? = nil
local forceMock = false

local function defaultProfile(): Profile
	return {
		version = PROFILE_VERSION,
		gold = 0,
		slotsUnlocked = PondConfig.FreeSlots,
		creatures = {},
		pond = {},
		nextUid = 1,
		rods = { [Rods.Starter] = { stars = 1, shards = 0 } },
		equippedRod = Rods.Starter,
		baits = table.clone(Baits.Starter),
		equippedBait = Baits.DefaultEquipped,
		pity = { rod = 0 },
		stats = { catches = 0, heaviestKg = 0, goldEarned = 0 },
		discovered = {},
		lastBlessAt = 0,
		lastSeen = 0,
		purchases = {},
		quests = { day = 0, daily = {}, step = 1, counts = {} },
	}
end

-- Fills in fields added since the profile was last saved. Only top-level keys
-- (plus the fixed-shape pity/stats tables) are reconciled: dynamic maps such as
-- `baits` must not have starter values re-added once a player has used them up.
local function reconcile(profile: Profile)
	local template = defaultProfile() :: any
	local target = profile :: any
	for key, value in template do
		if target[key] == nil then
			target[key] = value
		end
	end
	for _, fixedKey in { "pity", "stats" } do
		for key, value in template[fixedKey] do
			if target[fixedKey][key] == nil then
				target[fixedKey][key] = value
			end
		end
	end
	-- Migrations go here: if profile.version < 2 then ... end
	profile.version = PROFILE_VERSION

	-- Repair anything that would break gameplay.
	if not profile.rods[Rods.Starter] then
		profile.rods[Rods.Starter] = { stars = 1, shards = 0 }
	end
	if not profile.rods[profile.equippedRod] then
		profile.equippedRod = Rods.Starter
	end
	profile.slotsUnlocked = math.clamp(profile.slotsUnlocked, PondConfig.FreeSlots, PondConfig.MaxGoldSlots)
	for slotKey, uid in profile.pond do
		if not profile.creatures[uid] then
			profile.pond[slotKey] = nil
		end
	end
end

local function keyFor(player: Player): string
	return "u_" .. player.UserId
end

local function lockIsForeign(lock: SessionLock?): boolean
	return lock ~= nil and lock.jobId ~= game.JobId and os.time() - lock.time < LOCK_TIMEOUT
end

-- Returns (profile, isMock). nil profile = could not load safely.
local function loadProfile(player: Player): (Profile?, boolean)
	local dataStore = store
	if forceMock or not dataStore then
		return defaultProfile(), true
	end

	local key = keyFor(player)
	for attempt = 1, LOAD_ATTEMPTS do
		local locked = false
		local loaded: Profile? = nil

		local function transform(old: Envelope?): Envelope?
			local envelope: Envelope = old or {}
			if lockIsForeign(envelope.lock) then
				locked = true
				return nil -- cancel the write
			end
			locked = false
			envelope.lock = { jobId = game.JobId, time = os.time() }
			envelope.data = envelope.data or defaultProfile()
			loaded = envelope.data
			return envelope
		end
		local ok, err = pcall(function()
			-- Cast: the API types the transform as returning (value, userIds, metadata).
			dataStore:UpdateAsync(key, transform :: any)
		end)

		if ok and loaded then
			return loaded, false
		end
		if not ok then
			warn(`[DataService] Load attempt {attempt} failed for {player.Name}: {err}`)
		end
		if not player:IsDescendantOf(Players) then
			return nil, false
		end
		-- A foreign lock usually means the previous server is still saving.
		task.wait(if locked then 6 else 2 ^ attempt)
	end

	if RunService:IsStudio() then
		warn("[DataService] DataStore unavailable in Studio - using an in-memory profile (nothing will be saved).")
		return defaultProfile(), true
	end
	return nil, false
end

local function saveProfile(player: Player, release: boolean): boolean
	local session = sessions[player]
	if not session then
		return false
	end
	session.profile.lastSeen = os.time()
	session.lastSave = os.clock()

	local dataStore = store
	if session.mock or not dataStore then
		return true
	end

	local key = keyFor(player)
	local profile = session.profile
	for attempt = 1, SAVE_ATTEMPTS do
		local stolen = false
		local function transform(old: Envelope?): Envelope?
			local envelope: Envelope = old or {}
			if lockIsForeign(envelope.lock) then
				stolen = true
				return nil
			end
			envelope.data = profile
			envelope.lock = if release then nil else { jobId = game.JobId, time = os.time() }
			return envelope
		end
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, transform :: any)
		end)

		if ok and not stolen then
			return true
		end
		if stolen then
			-- Another server owns this profile now; writing would clobber it.
			warn(`[DataService] Session lock for {player.Name} was taken by another server - save skipped.`)
			return false
		end
		warn(`[DataService] Save attempt {attempt} failed for {player.Name}: {err}`)
		if attempt < SAVE_ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end
	return false
end

local function buildSnapshot(player: Player, profile: Profile): { [string]: any }
	local snapshot: { [string]: any } = {
		gold = profile.gold,
		slotsUnlocked = profile.slotsUnlocked,
		creatures = profile.creatures,
		pond = profile.pond,
		rods = profile.rods,
		equippedRod = profile.equippedRod,
		baits = profile.baits,
		equippedBait = profile.equippedBait,
		pity = profile.pity,
		stats = profile.stats,
		discovered = profile.discovered,
	}
	for _, extend in snapshotExtensions do
		extend(player, snapshot)
	end
	return snapshot
end

local function onPlayerAdded(player: Player)
	if sessions[player] or loading[player] then
		return
	end
	loading[player] = true
	local profile, mock = loadProfile(player)
	loading[player] = nil

	if not player:IsDescendantOf(Players) then
		-- Left while loading. Release the lock we may have taken.
		if profile and not mock then
			sessions[player] = { profile = profile, mock = false, dirty = false, lastSave = os.clock() }
			saveProfile(player, true)
			sessions[player] = nil
		end
		return
	end
	if not profile then
		player:Kick("We couldn't load your save data safely. Your progress is untouched - please rejoin in a moment.")
		return
	end

	reconcile(profile)
	sessions[player] = { profile = profile, mock = mock, dirty = true, lastSave = os.clock() }
	player:SetAttribute("Gold", math.floor(profile.gold))

	for _, callback in loadedCallbacks do
		local ok, err = pcall(function()
			callback(player, profile)
		end)
		if not ok then
			warn(`[DataService] ProfileLoaded callback failed: {err}`)
		end
	end
	player:SetAttribute("DataLoaded", true)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if not session or releasing[player] then
		return
	end
	releasing[player] = true
	for _, callback in releasingCallbacks do
		local ok, err = pcall(function()
			callback(player, session.profile)
		end)
		if not ok then
			warn(`[DataService] ProfileReleasing callback failed: {err}`)
		end
	end
	saveProfile(player, true)
	sessions[player] = nil
	releasing[player] = nil
end

-- Public API ----------------------------------------------------------------------

function DataService.Get(player: Player): Profile?
	local session = sessions[player]
	return if session then session.profile else nil
end

function DataService.OnProfileLoaded(callback: (Player, Profile) -> ())
	table.insert(loadedCallbacks, callback)
end

-- Called just before a profile is saved and released (player leaving).
function DataService.OnProfileReleasing(callback: (Player, Profile) -> ())
	table.insert(releasingCallbacks, callback)
end

-- Lets another service add derived fields to the client snapshot.
function DataService.RegisterSnapshotExtension(extend: (Player, { [string]: any }) -> ())
	table.insert(snapshotExtensions, extend)
end

-- Queue a StateSync to the owning client (coalesced, at most ~4 per second).
function DataService.MarkDirty(player: Player)
	local session = sessions[player]
	if session then
		session.dirty = true
	end
end

function DataService.AddGold(player: Player, amount: number)
	local session = sessions[player]
	if not session or amount <= 0 then
		return
	end
	local profile = session.profile
	profile.gold += amount
	profile.stats.goldEarned += amount
	-- Gold replicates as an attribute so the HUD ticks without a full StateSync.
	player:SetAttribute("Gold", math.floor(profile.gold))
end

function DataService.TrySpendGold(player: Player, amount: number): boolean
	local session = sessions[player]
	if not session or amount < 0 or amount ~= amount then
		return false
	end
	local profile = session.profile
	if profile.gold < amount then
		return false
	end
	profile.gold -= amount
	player:SetAttribute("Gold", math.floor(profile.gold))
	session.dirty = true
	return true
end

-- Records a Robux purchase id. Returns false if it was already granted.
function DataService.RecordPurchase(player: Player, purchaseId: string): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	if table.find(profile.purchases, purchaseId) then
		return false
	end
	table.insert(profile.purchases, purchaseId)
	while #profile.purchases > MAX_PURCHASE_HISTORY do
		table.remove(profile.purchases, 1)
	end
	return true
end

function DataService.HasPurchase(player: Player, purchaseId: string): boolean
	local profile = DataService.Get(player)
	return profile ~= nil and table.find(profile.purchases, purchaseId) ~= nil
end

-- Immediate save (used after Robux purchases). Returns success.
function DataService.SaveNow(player: Player): boolean
	return saveProfile(player, false)
end

function DataService.Init()
	-- Studio playtests use throwaway in-memory profiles unless saving is switched on
	-- for the place, so test catches and DevService grants never land in real data.
	local studioSaves = Workspace:GetAttribute(STUDIO_SAVES_ATTRIBUTE) == true
	forceMock = RunService:IsStudio() and (game.GameId == 0 or not studioSaves)
	if forceMock then
		warn(
			`[DataService] Studio session - using in-memory profiles (nothing will be saved). Set Workspace attribute "{STUDIO_SAVES_ATTRIBUTE}" = true to test real saving.`
		)
	else
		local ok, result = pcall(function(): DataStore
			return DataStoreService:GetDataStore(STORE_NAME)
		end)
		if ok then
			store = result
		else
			warn(`[DataService] Could not open DataStore: {result}`)
			forceMock = RunService:IsStudio()
		end
	end

	Net.Handle("GetState", function(player: Player): { [string]: any }
		local profile = DataService.Get(player)
		if not profile then
			return { ok = false, error = "Still loading your data..." }
		end
		return { ok = true, state = buildSnapshot(player, profile) }
	end)
end

function DataService.Start()
	Players.PlayerAdded:Connect(function(player: Player)
		onPlayerAdded(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		onPlayerRemoving(player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- Coalesced state sync.
	local stateSync = Net.Event("StateSync")
	task.spawn(function()
		while true do
			task.wait(SYNC_INTERVAL)
			for player, session in sessions do
				if session.dirty then
					session.dirty = false
					stateSync:FireClient(player, buildSnapshot(player, session.profile))
				end
			end
		end
	end)

	-- Autosave, staggered so players don't all hit the DataStore budget together.
	task.spawn(function()
		while true do
			task.wait(10)
			for player, session in sessions do
				if os.clock() - session.lastSave >= AUTOSAVE_INTERVAL then
					task.spawn(saveProfile, player, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for player in sessions do
			pending += 1
			task.spawn(function()
				onPlayerRemoving(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
