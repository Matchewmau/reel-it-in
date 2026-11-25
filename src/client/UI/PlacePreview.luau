--!strict
-- Menu postcards use the same landmark geometry the player sees on arrival.
local PlacePreview = {}

local paths: { [string]: { string } } = {
	Pond = { "Ponds", "Pond1" },
	Hub = { "Decor", "Market", "MarketHut" },
	Freshwater = { "Cliffs", "TheFalls" },
	Saltwater = { "Abyss" },
	Shrine = { "Vendors", "RodGachaShrine" },
	Crate = { "Decor", "Market", "Crate" },
	Merchant = { "Vendors", "BaitMerchant" },
}

local function findSource(id: string): Instance?
	local source: Instance? = workspace:FindFirstChild("Map")
	for _, name in paths[id] do
		source = if source then source:FindFirstChild(name) else nil
	end
	return source
end

function PlacePreview.Create(id: string): ViewportFrame?
	local source = findSource(id)
	if not source then
		return nil
	end
	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(172, 180, 201)
	viewport.LightColor = Color3.fromRGB(255, 229, 183)
	viewport.LightDirection = Vector3.new(-0.5, -0.8, -1)
	local scene = Instance.new("Model")
	scene.Parent = viewport
	-- Copy visible geometry only; live pond prompts, fish and billboards belong in the world.
	local function add(part: BasePart)
		if part.Transparency >= 1 then
			return
		end
		local copy = part:Clone()
		copy:ClearAllChildren()
		copy.Anchored = true
		copy.Parent = scene
	end
	if source:IsA("BasePart") then
		add(source)
	else
		for _, child in source:GetChildren() do
			if child:IsA("BasePart") then
				add(child)
			end
		end
	end
	if #scene:GetChildren() == 0 then
		viewport:Destroy()
		return nil
	end
	local bounds, size = scene:GetBoundingBox()
	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	local direction = if id == "Freshwater" then Vector3.new(0.48, 0.35, 1) else Vector3.new(0.75, 0.85, 1)
	local distance = math.max(size.X, size.Y, size.Z) * 2.65
	camera.CFrame = CFrame.lookAt(bounds.Position + direction.Unit * distance, bounds.Position)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

return PlacePreview
