--!strict
-- Quest progress and rewards (the HUD's "Active Quests" tracker).
--
-- Progress only ever moves in response to GameEvents fired by other server
-- services, so a client cannot advance or claim a quest. Rewards are granted
-- automatically the moment a quest completes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Quests = require(Shared.Config.Quests)
local Baits = require(Shared.Config.Baits)

local DataService = require(script.Parent.DataService)
local PondService = require(script.Parent.PondService)
local GameEvents = require(script.Parent.Parent.Util.GameEvents)

type Profile = Types.Profile
type QuestProgress = Types.QuestProgress
type QuestDef = Quests.QuestDef

local SECONDS_PER_DAY = 86400
local MAX_BAIT_STACK = 9999

local QuestService = {}

local rng = Random.new()

local function today(): number
	return os.time() // SECONDS_PER_DAY
end

local function rewardGoldFor(player: Player, def: QuestDef): number
	local scaled = PondService.GetIncome(player) * (def.rewardIncomeSeconds or 0)
	return math.max(def.rewardGold, math.floor(scaled))
end

local function rewardText(player: Player, def: QuestDef): string
	local text = `{Format.Number(rewardGoldFor(player, def))} Gold`
	local bait = def.rewardBait
	local baitDef = if bait then Baits.Get(bait.id) else nil
	if bait and baitDef then
		text ..= ` + {bait.amount}x {baitDef.name}`
	end
	return text
end

local function grant(player: Player, profile: Profile, def: QuestDef)
	-- Build the message before paying out, so it shows the amount actually granted.
	local text = rewardText(player, def)
	DataService.AddGold(player, rewardGoldFor(player, def))
	local bait = def.rewardBait
	if bait and Baits.Get(bait.id) then
		profile.baits[bait.id] = math.min(MAX_BAIT_STACK, (profile.baits[bait.id] or 0) + bait.amount)
	end
	Net.Event("Notify"):FireClient(player, `Quest complete: {def.title}\nReward: {text}`, "good")
end

-- Draws a fresh set of daily quests for the current UTC day.
local function rollDaily(player: Player, profile: Profile)
	local pool = table.clone(Quests.Daily)
	local picked: { QuestProgress } = {}
	for _ = 1, Quests.DailyCount do
		local def = table.remove(pool, rng:NextInteger(1, #pool)) :: QuestDef
		local goal = def.goal
		if def.goalIncomeSeconds then
			goal = math.max(goal, math.floor(PondService.GetIncome(player) * def.goalIncomeSeconds))
		end
		table.insert(picked, {
			id = def.id,
			progress = 0,
			goal = goal,
			-- EarnGold measures lifetime gold earned since the quest was rolled.
			baseline = profile.stats.goldEarned,
			done = false,
		})
	end
	profile.quests.day = today()
	profile.quests.daily = picked
end

local function ensureCurrent(player: Player, profile: Profile)
	local quests = profile.quests
	local stale = quests.day ~= today() or #quests.daily ~= Quests.DailyCount
	if not stale then
		-- A quest removed from the pool in an update would otherwise sit there forever.
		for _, entry in quests.daily do
			if not Quests.GetDaily(entry.id) then
				stale = true
			end
		end
	end
	if stale then
		rollDaily(player, profile)
		DataService.MarkDirty(player)
	end
end

local function advance(current: number, amount: number, absolute: boolean?): number
	if absolute then
		return math.max(current, amount)
	end
	return current + amount
end

-- Events whose amount is a current total rather than an increment.
local ABSOLUTE_EVENTS: { [string]: boolean } = { PondSlotted = true }

-- Pays out every guide step whose lifetime total is already met. Returns true
-- if at least one step completed.
local function completeGuideSteps(player: Player, profile: Profile): boolean
	local quests = profile.quests
	local completed = false
	while true do
		local step = Quests.Guide[quests.step]
		if not step or (quests.counts[step.event] or 0) < step.goal then
			break
		end
		grant(player, profile, step)
		quests.step += 1
		completed = true
	end
	return completed
end

local function onEvent(player: Player, name: string, amount: number, context: { [string]: any })
	local profile = DataService.Get(player)
	if not profile then
		return
	end
	ensureCurrent(player, profile)
	local quests = profile.quests
	-- Lifetime totals drive the guide chain. Counting from the start (rather than
	-- from when a step unlocks) means a player who already pulled a rod or bought
	-- a slot is credited the moment that step comes up, instead of being asked to
	-- pay for it twice.
	local absolute = ABSOLUTE_EVENTS[name] == true
	quests.counts[name] = advance(quests.counts[name] or 0, amount, absolute)
	completeGuideSteps(player, profile)

	for _, entry in quests.daily do
		local def = Quests.GetDaily(entry.id)
		if def and not entry.done and def.event == name and Quests.Matches(def, context) then
			entry.progress = math.min(entry.goal, advance(entry.progress, amount, def.absolute))
			if entry.progress >= entry.goal then
				entry.done = true
				grant(player, profile, def)
			end
		end
	end

	DataService.MarkDirty(player)
end

-- EarnGold quests read the profile's lifetime counter instead of hooking every
-- gold grant (income ticks once a second for every player).
local function tickEarnGold(player: Player, profile: Profile)
	for _, entry in profile.quests.daily do
		local def = Quests.GetDaily(entry.id)
		if def and def.event == "EarnGold" and not entry.done then
			local progress = math.min(entry.goal, math.floor(profile.stats.goldEarned - entry.baseline))
			-- Only resync when the bar would visibly move (2% steps).
			local before = math.floor(entry.progress / entry.goal * 50)
			local after = math.floor(progress / entry.goal * 50)
			entry.progress = progress
			if progress >= entry.goal then
				entry.done = true
				grant(player, profile, def)
				DataService.MarkDirty(player)
			elseif after ~= before then
				DataService.MarkDirty(player)
			end
		end
	end
end

local function buildViews(player: Player, profile: Profile): { Types.QuestView }
	local views: { Types.QuestView } = {}
	local quests = profile.quests
	local step = Quests.Guide[quests.step]
	if step then
		table.insert(views, {
			id = step.id,
			kind = "Guide",
			title = step.title,
			progress = math.min(quests.counts[step.event] or 0, step.goal),
			goal = step.goal,
			done = false,
			reward = rewardText(player, step),
		})
	end
	for _, entry in quests.daily do
		local def = Quests.GetDaily(entry.id)
		if def then
			table.insert(views, {
				id = def.id,
				kind = "Daily",
				title = def.title,
				progress = entry.progress,
				goal = entry.goal,
				done = entry.done,
				reward = rewardText(player, def),
			})
		end
	end
	return views
end

function QuestService.Init()
	GameEvents.On(onEvent)

	-- Registered after PondService's callback, so income is known when dailies roll.
	DataService.OnProfileLoaded(function(player: Player, profile: Profile)
		ensureCurrent(player, profile)
	end)

	DataService.RegisterSnapshotExtension(function(player: Player, snapshot: { [string]: any })
		local profile = DataService.Get(player)
		if not profile then
			return
		end
		snapshot.quests = buildViews(player, profile)
		snapshot.questResetIn = (today() + 1) * SECONDS_PER_DAY - os.time()
	end)
end

function QuestService.Start()
	task.spawn(function()
		while true do
			task.wait(2)
			for _, player in Players:GetPlayers() do
				local profile = DataService.Get(player)
				if profile then
					ensureCurrent(player, profile) -- also handles the midnight rollover
					tickEarnGold(player, profile)
				end
			end
		end
	end)
end

return QuestService
