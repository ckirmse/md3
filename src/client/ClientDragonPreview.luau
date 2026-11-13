--!strict

-- Shows a still model of a genome's dragon turning slowly in a ViewportFrame (the Egg Lens and the hatch reveal). The model comes from
-- ClientDragonKit.createDisplayModel, so it looks like the dragon that egg will hatch.
local ClientDragonPreview = {}

local runService = game:GetService("RunService")

local clientDragonKit = require("./ClientDragonKit")

local TURN_SPEED = math.rad(30) -- radians per second
local FIELD_OF_VIEW = 35
local FRAMING_MARGIN = 1.08 -- the fitted size is padded by this much so the model never touches the frame edge

-- the turning of each viewport being shown; the viewports are Studio-authored, so they are untyped here
local active: { [any]: RBXScriptConnection } = {}

function ClientDragonPreview.clear(viewport: any?)
	if not viewport then
		return
	end
	local connection = active[viewport]
	if connection then
		connection:Disconnect()
		active[viewport] = nil
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

-- Replaces whatever the viewport shows with the dragon of this genome; nothing is shown when the genome has no model.
function ClientDragonPreview.show(viewport: any?, genome: any)
	if not viewport then
		return
	end
	ClientDragonPreview.clear(viewport)

	local model = clientDragonKit:createDisplayModel(genome)
	if not model then
		return
	end
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

	-- the camera is fitted to the frame's current shape every frame, since its size isn't known until it is laid out
	local angle = 0
	active[viewport] = runService.RenderStepped:Connect(function(dt: number)
		angle += TURN_SPEED * dt
		model:PivotTo(CFrame.new(center) * CFrame.Angles(0, angle, 0) * CFrame.new(-center) * basePivot)

		local size = viewport.AbsoluteSize
		local aspect = if size.Y > 0 then size.X / size.Y else 1
		local distance = (math.max(halfHeight / halfTan, halfWidth / (halfTan * aspect)) + halfWidth) * FRAMING_MARGIN
		-- looks from a little above the middle, so the wings and the back are readable
		camera.CFrame = CFrame.lookAt(center + Vector3.new(0, halfHeight * 0.5, distance), center)
	end)
end

return ClientDragonPreview
