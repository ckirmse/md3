--!strict

-- Shows a model turning slowly in a ViewportFrame: a genome's dragon (the Egg Lens, the hatch reveal, the Nest page and the pairing confirm) or the
-- mystery egg. The dragon comes from ClientDragonKit.createDisplayModel, so it looks like the dragon that egg will hatch.
local ClientDragonPreview = {}

local runService = game:GetService("RunService")

local utils = require("@game/ReplicatedStorage/Shared/utils")

local clientDragonKit = require("./ClientDragonKit")

local TURN_SPEED = math.rad(30) -- radians per second, anticlockwise seen from above
local SLOW_TURN_SPEED = math.rad(18) -- the slower turn of the Nest page and confirm page portraits and the mystery egg
local VIEW_HEIGHT = 0.8 -- the camera's height over the middle, as a share of the model's half height, for the slightly inclined view
local FIELD_OF_VIEW = 35
local FRAMING_MARGIN = 1.08 -- the fitted size is padded by this much so the model never touches the frame edge

-- how to stop what each viewport is showing; the viewports are Studio-authored, so they are untyped here
local active: { [any]: () -> () } = {}

function ClientDragonPreview.clear(viewport: any?)
	if not viewport then
		return
	end
	local stop = active[viewport]
	if stop then
		active[viewport] = nil
		stop()
	end
	viewport:ClearAllChildren()
	viewport.CurrentCamera = nil
end

-- The middle, half height and turning radius of what can be seen of the model: invisible parts (hitboxes, helpers) are ignored, since they
-- would shrink the dragon in the frame. The radius is the farthest a visible corner gets from the vertical axis through the middle.
local function measure(model: any): (Vector3?, number, number)
	local corners: { Vector3 } = {}
	local low, high = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 0.95 then
			local half = part.Size / 2
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local corner = part.CFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
						table.insert(corners, corner)
						low = low:Min(corner)
						high = high:Max(corner)
					end
				end
			end
		end
	end
	if #corners == 0 then
		return nil, 0, 0
	end
	local center = (low + high) / 2
	local radius = 0
	for _, corner in corners do
		radius = math.max(radius, Vector2.new(corner.X - center.X, corner.Z - center.Z).Magnitude)
	end
	return center, (high.Y - low.Y) / 2, radius
end

-- Puts the model in the viewport and turns it about its middle, anticlockwise seen from above, with a camera fitted to the frame's current shape
-- every frame (the frame's size isn't known until it is laid out). "turn" is the slower turn seen from a raised, inclined camera, "still" is
-- the same view with no turning; the default is the faster turn from a camera a little above the middle.
local function present(viewport: any, model: any, mode: string?)
	model.Parent = viewport

	local center, halfHeight, halfWidth = measure(model)
	if not center then
		model:Destroy()
		return
	end
	local basePivot = model:GetPivot()
	local halfTan = math.tan(math.rad(FIELD_OF_VIEW / 2))

	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local isSlow = mode == "turn" or mode == "still"
	local angle = 0
	local render: RBXScriptConnection = runService.RenderStepped:Connect(function(dt: number)
		local size = viewport.AbsoluteSize
		local aspect = if size.Y > 0 then size.X / size.Y else 1
		if mode ~= "still" then
			angle += (if isSlow then SLOW_TURN_SPEED else TURN_SPEED) * dt
			model:PivotTo(CFrame.new(center) * CFrame.Angles(0, angle, 0) * CFrame.new(-center) * basePivot)
		end
		local distance = (math.max(halfHeight / halfTan, halfWidth / (halfTan * aspect)) + halfWidth) * FRAMING_MARGIN
		local height = halfHeight * (if isSlow then VIEW_HEIGHT else 0.5)
		camera.CFrame = CFrame.lookAt(center + Vector3.new(0, height, distance), center)
	end)
	-- a viewport that is destroyed (a list rebuilt around it) stops its own rendering
	local destroying: RBXScriptConnection = viewport.Destroying:Connect(function()
		ClientDragonPreview.clear(viewport)
	end)
	active[viewport] = function()
		render:Disconnect()
		destroying:Disconnect()
	end
end

-- Replaces whatever the viewport shows with the dragon of this genome; nothing is shown when the genome has no model.
function ClientDragonPreview.show(viewport: any?, genome: any, mode: string?)
	if not viewport then
		return
	end
	ClientDragonPreview.clear(viewport)

	local model = clientDragonKit:createDisplayModel(genome)
	if model then
		present(viewport, model, mode)
	end
end

-- Replaces whatever the viewport shows with the placeholder Nest egg tinted one flat colour (black for an egg nobody has seen), turning slowly,
-- or standing still when isStill is set.
function ClientDragonPreview.showEgg(viewport: any?, tint: Color3, isStill: boolean?)
	if not viewport then
		return
	end
	ClientDragonPreview.clear(viewport)

	local template = utils.getGameAssetPathReference("Land.Nest.NestEgg")
	if not template or not template:IsA("Model") then
		warn("ClientDragonPreview: GameAssets.Land.Nest.NestEgg is missing")
		return
	end
	local model: any = template:Clone()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.Color = tint
			descendant.Material = Enum.Material.SmoothPlastic
			if descendant:IsA("MeshPart") then
				descendant.TextureID = ""
			end
		elseif descendant:IsA("SurfaceAppearance") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant:Destroy()
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("Beam") then
			descendant.Enabled = false
		end
	end
	present(viewport, model, if isStill then "still" else "turn")
end

return ClientDragonPreview
