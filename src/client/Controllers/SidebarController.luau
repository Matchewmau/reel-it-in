--!strict
-- Quest log and session records boards in riveted iron/steel nautical style.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared") :: typeof(ReplicatedStorage.Shared)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Format = require(Shared.Util.Format)
local Creatures = require(Shared.Config.Creatures)
local Rarities = require(Shared.Config.Rarities)
local ClientState = require(script.Parent.Parent.ClientState)
local Kit = require(script.Parent.Parent.UI.Kit)

local WIDTH = 282
local Theme = Kit.Theme
local INK = Theme.PanelDark
local ROW_BG = Color3.fromHex("#101622")
local STEEL = Theme.Steel
local STEEL_EDGE = Color3.fromRGB(112, 128, 150)
local BRASS = Theme.Brass
local SKY_TOP = Color3.fromRGB(92, 206, 255)
local SKY_BOT = Color3.fromRGB(38, 128, 210)
local GOLD_TOP = Color3.fromRGB(255, 214, 78)
local GOLD_BOT = Color3.fromRGB(204, 134, 28)
local GOOD_TOP = Color3.fromRGB(64, 218, 96)
local GOOD_BOT = Color3.fromRGB(28, 140, 56)
local MUTED = Theme.SubText

local MEDALS: { { top: Color3, bot: Color3, rim: Color3 } } = {
	{ top = Color3.fromRGB(255, 218, 86), bot = Color3.fromRGB(198, 132, 24), rim = Color3.fromRGB(255, 242, 174) },
	{ top = Color3.fromRGB(224, 234, 248), bot = Color3.fromRGB(132, 146, 166), rim = Color3.fromRGB(246, 250, 255) },
	{ top = Color3.fromRGB(232, 166, 112), bot = Color3.fromRGB(148, 86, 44), rim = Color3.fromRGB(248, 204, 164) },
}

local SidebarController = {}

local questList: Frame
local bestList: Frame
local bestPanel: Frame
local resetLabel: TextLabel
local toggle: TextButton
local scroll: ScrollingFrame
local openQuests = 0
local collapsed = false
local compact = false

local function clearRows(frame: Frame)
	for _, child in frame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function section(
	parent: Instance,
	name: string,
	title: string,
	order: number,
	edge: Color3
): (Frame, Frame, TextLabel)
	local panel = Kit.Frame({
		Name = name,
		BackgroundColor3 = Color3.fromRGB(58, 70, 88),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.Corner(panel, 8)
	Kit.Gradient(panel, Color3.fromRGB(76, 90, 110), Color3.fromRGB(36, 44, 58))
	Kit.Trim(panel, edge)

	local content = Kit.Frame({
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = panel,
	})
	Kit.Padding(content, 5, 5)
	Kit.List(content, Enum.FillDirection.Vertical, 3)

	local header = Kit.Frame({
		Name = "Header",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, 0, 0, 28),
		LayoutOrder = 1,
		Parent = content,
	})
	Kit.Corner(header, 5)
	Kit.Gradient(header, Color3.fromRGB(96, 112, 134), Color3.fromRGB(46, 56, 74))
	Kit.Stroke(header, INK, 1.5)
	Kit.Gloss(header)

	local heading = Kit.Label({
		Text = title,
		Font = Kit.FontHeavy,
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 1,
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -16, 1, 0),
		Parent = header,
	})
	Kit.TextStroke(heading, INK, 1.4)

	local note = Kit.Label({
		Text = "",
		Font = Kit.FontBody,
		TextColor3 = Color3.fromHex("#C8D4E4"),
		TextSize = 12,
		TextStrokeTransparency = 1,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.52, 0),
		Size = UDim2.new(0.48, -10, 1, 0),
		Parent = header,
	})
	local list = Kit.Frame({
		Name = "Rows",
		BackgroundColor3 = Theme.Panel,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = content,
	})
	Kit.Corner(list, 5)
	Kit.Stroke(list, INK, 1)
	Kit.Padding(list, 5, 5)
	Kit.List(list, Enum.FillDirection.Vertical, 5)
	return panel, list, note
end

local function updateToggle()
	toggle.Visible = compact
	scroll.Visible = not compact or not collapsed
	toggle.Text = if collapsed then `QUESTS  ({openQuests})  +` else "CLOSE QUESTS  −"
end

local function renderQuests(quests: { Types.QuestView })
	clearRows(questList)
	openQuests = 0
	for index, quest in quests do
		if not quest.done then
			openQuests += 1
		end
		local isGuide = quest.kind == "Guide"
		local row = Kit.Frame({
			BackgroundColor3 = ROW_BG,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = index,
			Parent = questList,
		})
		Kit.Corner(row, 5)
		Kit.Stroke(
			row,
			if isGuide and not quest.done then Color3.fromRGB(134, 104, 46) else Color3.fromRGB(36, 48, 66),
			1
		)
		Kit.Padding(row, 8, 6)
		Kit.List(row, Enum.FillDirection.Vertical, 3)

		local title = quest.title
		if isGuide then
			title = '<font color="#FFD044"><b>GUIDE</b></font> - '
				.. title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
		end
		Kit.Label({
			Name = "Objective",
			Text = title,
			Font = Kit.Font,
			RichText = isGuide,
			TextColor3 = if quest.done then MUTED else Theme.Text,
			TextSize = 14,
			TextStrokeTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = row,
		})

		local progress = Kit.Frame({
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 17),
			LayoutOrder = 2,
			Parent = row,
		})
		local track = Kit.Frame({
			BackgroundColor3 = Color3.fromRGB(34, 44, 58),
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.new(1, -78, 0, 8),
			Parent = progress,
		})
		Kit.Corner(track, 4)
		Kit.Stroke(track, INK, 1)

		local fraction = if quest.goal > 0 then math.clamp(quest.progress / quest.goal, 0, 1) else 0
		local fill = Kit.Frame({
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.fromScale(fraction, 1),
			Visible = fraction > 0,
			Parent = track,
		})
		Kit.Corner(fill, 4)
		local fillTop = if quest.done then GOOD_TOP elseif isGuide then GOLD_TOP else SKY_TOP
		local fillBot = if quest.done then GOOD_BOT elseif isGuide then GOLD_BOT else SKY_BOT
		Kit.Gradient(fill, fillTop, fillBot)

		local counterColor = if quest.done then Theme.Good elseif isGuide then Theme.Gold else SKY_TOP
		Kit.Label({
			Text = if quest.done then "DONE" else `{Format.Number(quest.progress)}/{Format.Number(quest.goal)}`,
			Font = Kit.Font,
			TextColor3 = counterColor,
			TextSize = 13,
			TextStrokeTransparency = 1,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 74, 1, 0),
			Parent = progress,
		})
		if not quest.done then
			Kit.Label({
				Text = "Reward: " .. quest.reward,
				Font = Kit.FontBody,
				TextColor3 = Color3.fromHex("#DAE2EE"),
				TextSize = 13,
				TextStrokeTransparency = 1,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 3,
				Parent = row,
			})
		end
	end
	updateToggle()
end

local function renderBest(catches: { Types.BestCatch })
	clearRows(bestList)
	bestPanel.Visible = #catches > 0
	for index, entry in catches do
		local species = Creatures.Get(entry.speciesId)
		local isSelf = entry.userId == Players.LocalPlayer.UserId
		local row = Kit.Frame({
			BackgroundColor3 = if isSelf then Color3.fromRGB(28, 40, 58) else ROW_BG,
			Size = UDim2.new(1, 0, 0, 42),
			LayoutOrder = index,
			Parent = bestList,
		})
		Kit.Corner(row, 5)
		Kit.Stroke(row, if isSelf then Color3.fromRGB(92, 128, 174) else Color3.fromRGB(36, 48, 66), 1)

		local medalStyle = MEDALS[index]
		local medal = Kit.Frame({
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 6, 0.5, 0),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = if medalStyle then Color3.new(1, 1, 1) else STEEL,
			Parent = row,
		})
		Kit.Corner(medal, 15)
		if medalStyle then
			Kit.Gradient(medal, medalStyle.top, medalStyle.bot)
			Kit.Stroke(medal, medalStyle.rim, 1.5)
		else
			Kit.Stroke(medal, INK, 1)
		end

		Kit.Label({
			Text = "#" .. index,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = if medalStyle then Color3.fromRGB(40, 26, 10) else Theme.Text,
			TextSize = 13,
			TextStrokeTransparency = 1,
			Font = Kit.FontHeavy,
			Size = UDim2.fromScale(1, 1),
			Parent = medal,
		})
		Kit.Label({
			Text = entry.name,
			Font = Kit.Font,
			TextSize = 14,
			TextStrokeTransparency = 1,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Position = UDim2.fromOffset(44, 3),
			Size = UDim2.new(1, -118, 0, 19),
			Parent = row,
		})
		Kit.Label({
			Text = if species then species.name else "Unknown",
			Font = Kit.FontBody,
			TextColor3 = if species then Rarities.Get(species.rarity).color else MUTED,
			TextSize = 13,
			TextStrokeTransparency = 1,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
			Position = UDim2.fromOffset(44, 21),
			Size = UDim2.new(1, -118, 0, 17),
			Parent = row,
		})
		Kit.Label({
			Text = Format.Weight(entry.weight),
			Font = Kit.Font,
			TextSize = 13,
			TextStrokeTransparency = 1,
			TextColor3 = Color3.fromRGB(246, 240, 224),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.new(0, 68, 1, 0),
			Parent = row,
		})
	end
end

local function refreshReset()
	local snapshot = ClientState.Snapshot
	if snapshot and snapshot.questResetIn then
		resetLabel.Text = "Reset " .. Format.Duration(ClientState.Remaining(snapshot.questResetIn))
	end
end

function SidebarController.Init()
	local gui = Kit.ScreenGui("Sidebar", 5)
	local scale = Kit.AutoScale(gui)
	local column = Kit.Frame({
		Name = "Column",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(0, WIDTH + 8, 1, -160),
		Parent = gui,
	})

	toggle = Kit.Button({
		Name = "Toggle",
		Text = "QUESTS",
		Font = Kit.FontHeavy,
		TextSize = 14,
		TextStrokeTransparency = 1,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(156, 46),
		Parent = column,
	})
	Kit.TextStroke(toggle, INK, 1.4)
	Kit.Gradient(toggle, Color3.fromRGB(72, 86, 108), INK)
	Kit.Trim(toggle, BRASS)
	Kit.Gloss(toggle)
	Kit.HoverScale(toggle, 1.04)
	toggle.Activated:Connect(function()
		collapsed = not collapsed
		updateToggle()
	end)

	scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Boards"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 3
	scroll.ScrollBarImageColor3 = STEEL_EDGE
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.Parent = column
	Kit.Padding(scroll, 3, 3)
	local layout = Kit.List(scroll, Enum.FillDirection.Vertical, 8)

	local _, quests, reset = section(scroll, "Quests", "ACTIVE QUESTS", 1, BRASS)
	questList = quests
	resetLabel = reset
	local best, bestRows = section(scroll, "BestCatches", "SERVER BEST CATCHES", 2, STEEL_EDGE)
	bestPanel = best
	bestList = bestRows
	bestPanel.Visible = false

	local function resize()
		local newCompact = Kit.IsCompact()
		if compact ~= newCompact then
			compact = newCompact
			collapsed = compact
		end
		local top = if compact then 52 else 0
		local available = math.max(0, column.AbsoluteSize.Y / scale.Scale - top)
		local height = math.min(available, layout.AbsoluteContentSize.Y / scale.Scale + 8)
		scroll.Position = UDim2.fromOffset(0, top)
		scroll.Size = UDim2.new(1, 0, 0, height)
		updateToggle()
	end
	column:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)
	scale:GetPropertyChangedSignal("Scale"):Connect(resize)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	resize()
end

function SidebarController.Start()
	ClientState.OnState(function(snapshot: Types.Snapshot)
		renderQuests(snapshot.quests or {})
		refreshReset()
	end)
	Net.Event("BestCatches").OnClientEvent:Connect(renderBest)
	task.spawn(function()
		local response = Net.Invoke("GetBestCatches")
		if response.ok then
			renderBest(response.catches :: { Types.BestCatch })
		end
	end)
	task.spawn(function()
		while true do
			task.wait(30)
			refreshReset()
		end
	end)
end

return SidebarController
