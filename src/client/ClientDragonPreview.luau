--!strict

-- Shows a still model of a genome's dragon turning slowly in a ViewportFrame (the Egg Lens and the hatch reveal). The model comes from
-- ClientDragonKit.createDisplayModel, so it looks like the dragon that egg will hatch.
local ClientDragonPreview = {}

local runService = game:GetService("RunService")

local clientDragonKit = require("./ClientDragonKit")

local TURN_SPEED = math.rad(30) -- radians per second
local FIELD_OF_VIEW = 35
local FRAMING_MARGIN = 1.25 -- the model's size is padded by this much so it never touches the frame edge

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

	local boxCFrame, boxSize = model:GetBoundingBox()
	local center = boxCFrame.Position
	local basePivot = model:GetPivot()
	local radius = boxSize.Magnitude / 2 * FRAMING_MARGIN
	local distance = radius / math.tan(math.rad(FIELD_OF_VIEW / 2))

	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	-- looks from a little above the middle, so the wings and the back are readable
	camera.CFrame = CFrame.lookAt(center + Vector3.new(0, radius * 0.4, distance), center)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local angle = 0
	active[viewport] = runService.RenderStepped:Connect(function(dt: number)
		angle += TURN_SPEED * dt
		model:PivotTo(CFrame.new(center) * CFrame.Angles(0, angle, 0) * CFrame.new(-center) * basePivot)
	end)
end

return ClientDragonPreview
