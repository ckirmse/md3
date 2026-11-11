--!strict

-- The Nests as models on each plot. Each plot gets clones of GameAssets.Land.Nest.Nest at the hand-placed NestMarker<N> positions (inside a model
-- in Level.PerPlotElements, plot 1's coordinates; read and removed at startup so they are not cloned into the plots), up to the owner's
-- Nest count. NestManager calls syncNestModels whenever it sends the state, which covers joining, buying a Nest and resets. What a Nest
-- holds (its parents and eggs) is drawn by the client from that state; this only puts the empty Nests in the world.
local NestWorldManager = {}
NestWorldManager.__index = NestWorldManager

local plotsManager = require("./PlotsManager")

local Attributes = require("@game/ReplicatedStorage/Shared/Attributes")
local PlotHelpers = require("@game/ReplicatedStorage/Shared/PlotHelpers")
local utils = require("@game/ReplicatedStorage/Shared/utils")

-- the Nest models live together in GameAssets.Land.Nest: the Nest, the generic NestEgg and the old EggSlotTemplate
local TEMPLATE_FOLDER_PATH = "Land.Nest"
local TEMPLATE_NAME = "Nest"

type NestWorldManagerFields = {
	template: Model?,
	markerCFrames: { [number]: CFrame }, -- in plot 1's coordinates, keyed by Nest index
	spawnedCounts: { [Player]: number },
}

export type NestWorldManager = typeof(setmetatable({} :: NestWorldManagerFields, NestWorldManager))

-- Reads the markers and removes them from the plot template. A marker's container model is removed too once it is empty.
function NestWorldManager.collectMarkers(self: NestWorldManager)
	local containers: { Instance } = {}
	for _, inst in plotsManager:getPerPlotElements():GetDescendants() do
		local indexText = string.match(inst.Name, "^NestMarker(%d+)$")
		if indexText and inst:IsA("BasePart") then
			self.markerCFrames[tonumber(indexText) :: number] = inst.CFrame
			if inst.Parent and inst.Parent ~= plotsManager:getPerPlotElements() then
				table.insert(containers, inst.Parent)
			end
		end
	end

	for _, inst in plotsManager:getPerPlotElements():GetDescendants() do
		if string.match(inst.Name, "^NestMarker%d+$") then
			inst:Destroy()
		end
	end
	for _, container in containers do
		if container.Parent and #container:GetChildren() == 0 then
			container:Destroy()
		end
	end

	local templateFolder = utils.getGameAssetPathReference(TEMPLATE_FOLDER_PATH)
	local template = if templateFolder then templateFolder:FindFirstChild(TEMPLATE_NAME) else nil
	if not template or not template:IsA("Model") or not template.PrimaryPart then
		warn("NestWorldManager: GameAssets." .. TEMPLATE_FOLDER_PATH .. "." .. TEMPLATE_NAME .. " with a PrimaryPart is missing, so the Nests have no model")
		return
	end
	self.template = template
end

-- Makes the plot have exactly the Nest models the player has: spawns the missing ones and removes the ones above a lowered count.
function NestWorldManager.syncNestModels(self: NestWorldManager, player: Player, nestCount: number)
	local template = self.template
	if not template then
		return
	end

	local plotIndex = plotsManager:getPlotIndexByUserId(player.UserId)
	if not plotIndex then
		return
	end

	local spawnedCount = self.spawnedCounts[player] or 0
	if spawnedCount == nestCount then
		return
	end
	self.spawnedCounts[player] = nestCount

	if spawnedCount > nestCount then
		for _, inst in plotsManager:getClonedPlotElements():GetChildren() do
			local indexText = string.match(inst.Name, "^Nest(%d+)$")
			local nestIndex = if indexText then tonumber(indexText) else nil
			if nestIndex and nestIndex > nestCount and inst:GetAttribute(Attributes.INDEX) == plotIndex then
				inst:Destroy()
			end
		end
		return
	end

	for nestIndex = spawnedCount + 1, nestCount do
		local markerCFrame = self.markerCFrames[nestIndex]
		if not markerCFrame then
			warn("NestWorldManager: no NestMarker" .. nestIndex .. " in the plot template, so Nest " .. nestIndex .. " has no model")
			continue
		end

		local model = template:Clone()
		model.Name = "Nest" .. nestIndex

		-- the template's primary part may be turned on its side, so the pivot is rebuilt upright at its center: the template is built in
		-- world axes, and the marker's orientation then says which way the Nest faces
		local primary = model.PrimaryPart :: BasePart
		local center = primary.Position
		model.PrimaryPart = nil
		model.WorldPivot = CFrame.new(center)

		model:SetAttribute(Attributes.INDEX, plotIndex)
		for _, descendant in model:GetDescendants() do
			descendant:SetAttribute(Attributes.INDEX, plotIndex)
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end

		local plotCFrame = PlotHelpers.translateCFrameWorldToPlot(markerCFrame, 1)
		model:PivotTo(PlotHelpers.translateCFramePlotToWorld(plotCFrame, plotIndex))
		model.Parent = plotsManager:getClonedPlotElements()
	end
end

function NestWorldManager.notifyRemovePlayer(self: NestWorldManager, player: Player)
	self.spawnedCounts[player] = nil
end

function NestWorldManager.init(self: NestWorldManager)
	self:collectMarkers()
end

function NestWorldManager.new(): NestWorldManager
	local self = setmetatable({
		template = nil,
		markerCFrames = {},
		spawnedCounts = {},
	} :: NestWorldManagerFields, NestWorldManager)
	return self
end

local singleton = NestWorldManager.new()

return singleton
