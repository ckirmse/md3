--!strict

-- The Nests in the world, on the player's own plot. Each Nest model (put there by the server's NestWorldManager) shows its two parents on
-- the ParentSocketA and ParentSocketB parts, at their original size and facing the way the socket faces, and its waiting eggs on the
-- EggSocket1 to EggSocket3 parts, using the generic NestEgg (its Glow emitter is on for a tier-jump egg). A prompt on a Nest opens the Nests
-- screen, and a prompt on an egg asks the server to hatch it. The state comes from ClientNestManager; only the player's own Nests have data,
-- so other players' Nests show their model but no parents or eggs.
local ClientNestWorldManager = {}
ClientNestWorldManager.__index = ClientNestWorldManager

local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- the RemoteEvents children only exist in Studio, so they are untyped here
local RemoteEvents: any = ReplicatedStorage:WaitForChild("RemoteEvents")

local Level = workspace:WaitForChild("Level")

local Attributes = require("@game/ReplicatedStorage/Shared/Attributes")
local utils = require("@game/ReplicatedStorage/Shared/utils")

local clientDragonKit = require("./ClientDragonKit")
local clientHatchOdds = require("./ClientHatchOdds")
local ClientTicker = require("./ClientTicker")

local player = game:GetService("Players").LocalPlayer :: Player

local NEST_PROMPT_NAME = "NestPrompt"
local EGG_PROMPT_NAME = "NestEggPrompt"
local NEST_PROMPT_DISTANCE = 14
local EGG_PROMPT_DISTANCE = 12
local RESOLVE_SEC = 1

-- the Nest models and what is on them are Studio-authored, so they are untyped here
type EggView = {
	id: string,
	model: any,
	prompt: ProximityPrompt,
	promptConnect: RBXScriptConnection,
}

type NestView = {
	model: any,
	prompt: ProximityPrompt,
	promptConnect: RBXScriptConnection,
	parentIds: { string },
	parents: { any },
	eggs: { EggView },
}

type ClientNestWorldManagerFields = {
	state: any?,
	views: { [number]: NestView },
	openNest: ((nestIndex: number) -> ())?,
}

export type ClientNestWorldManager = typeof(setmetatable({} :: ClientNestWorldManagerFields, ClientNestWorldManager))

local function makePrompt(name: string, actionText: string, objectText: string, distance: number, parent: Instance): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = distance
	prompt.HoldDuration = 0
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.Parent = parent
	return prompt
end

-- the largest visible part, which is where a Nest's prompt sits
local function findPromptPart(model: any): any?
	local best: any? = nil
	local bestVolume = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Transparency < 1 then
			local volume = descendant.Size.X * descendant.Size.Y * descendant.Size.Z
			if volume > bestVolume or not best then
				best, bestVolume = descendant, volume
			end
		end
	end
	return best
end

-- the lowest point and the middle of a model in world space, from its parts' corners
local function measure(model: any): (number, number, number)
	local minX, maxX, minY, minZ, maxZ = math.huge, -math.huge, math.huge, math.huge, -math.huge
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local half = descendant.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = descendant.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
						minX, maxX = math.min(minX, corner.X), math.max(maxX, corner.X)
						minY = math.min(minY, corner.Y)
						minZ, maxZ = math.min(minZ, corner.Z), math.max(maxZ, corner.Z)
					end
				end
			end
		end
	end
	return (minX + maxX) / 2, minY, (minZ + maxZ) / 2
end

-- stands a parent on its socket: facing the way the socket faces, centered on it, with its lowest point at the socket's height
local function placeParent(dragon: any, socket: BasePart)
	local scale = clientHatchOdds:getOdds()
	local parentScale = if scale then scale.config.nestParentScale else 1
	if parentScale ~= 1 then
		dragon:ScaleTo(parentScale)
	end
	dragon:PivotTo(CFrame.new(socket.Position) * socket.CFrame.Rotation)
	local centerX, minY, centerZ = measure(dragon)
	dragon:PivotTo(dragon:GetPivot() + Vector3.new(socket.Position.X - centerX, socket.Position.Y - minY, socket.Position.Z - centerZ))
end

function ClientNestWorldManager.clearParents(self: ClientNestWorldManager, view: NestView)
	for _, dragon in view.parents do
		dragon:Destroy()
	end
	view.parents = {}
	view.parentIds = {}
end

function ClientNestWorldManager.updateParents(self: ClientNestWorldManager, view: NestView, nest: any)
	if nest.isEmpty then
		if #view.parentIds > 0 then
			self:clearParents(view)
		end
		return
	end

	-- the server can send the Nest state before the odds config has arrived with the join data, and a parent can't be built without it;
	-- nothing is marked as shown, so the periodic check in init tries again once the odds are there
	if not clientHatchOdds:getOdds() then
		return
	end

	local ids = { nest.parentA.uuid, nest.parentB.uuid }
	if view.parentIds[1] == ids[1] and view.parentIds[2] == ids[2] then
		return
	end

	self:clearParents(view)
	for index, genome in { nest.parentA, nest.parentB } do
		local socket = view.model:FindFirstChild(if index == 1 then "ParentSocketA" else "ParentSocketB", true)
		local dragon = clientDragonKit:createDisplayModel(genome)
		if dragon and socket and socket:IsA("BasePart") then
			placeParent(dragon, socket)
			dragon.Parent = view.model
			table.insert(view.parents, dragon)
		elseif dragon then
			dragon:Destroy()
			warn("ClientNestWorldManager: the Nest model has no ParentSocket" .. (if index == 1 then "A" else "B"))
		end
	end
	view.parentIds = ids
end

function ClientNestWorldManager.removeEgg(self: ClientNestWorldManager, egg: EggView)
	egg.promptConnect:Disconnect()
	egg.model:Destroy()
end

function ClientNestWorldManager.updateEggs(self: ClientNestWorldManager, view: NestView, nestIndex: number, nest: any)
	local wanted: { any } = if nest.isEmpty then {} else nest.eggs

	local wantedIds: { [string]: boolean } = {}
	for _, egg in wanted do
		wantedIds[egg.id] = true
	end

	-- eggs that were hatched or taken are gone from the Nest
	local kept: { EggView } = {}
	for _, egg in view.eggs do
		if wantedIds[egg.id] then
			table.insert(kept, egg)
		else
			self:removeEgg(egg)
		end
	end
	view.eggs = kept

	local byId: { [string]: EggView } = {}
	for _, egg in view.eggs do
		byId[egg.id] = egg
	end

	local template = utils.getGameAssetPathReference("Land.Nest.NestEgg")
	for position, eggData in wanted do
		local socket = view.model:FindFirstChild("EggSocket" .. position, true)
		if not socket or not socket:IsA("BasePart") then
			warn("ClientNestWorldManager: the Nest model has no EggSocket" .. position)
			continue
		end

		local eggView: EggView? = byId[eggData.id]
		if not eggView then
			if not template or not template:IsA("Model") then
				warn("ClientNestWorldManager: GameAssets.Land.Nest.NestEgg is missing")
				break
			end
			local model: any = template:Clone()
			model.Name = "NestEgg"
			for _, descendant in model:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Anchored = true
					descendant.CanCollide = false
				end
			end
			local promptPart = model.PrimaryPart or findPromptPart(model)
			local prompt = makePrompt(EGG_PROMPT_NAME, "Hatch", "Egg", EGG_PROMPT_DISTANCE, promptPart)
			local eggId: string = eggData.id
			local promptConnect = prompt.Triggered:Connect(function(triggerPlayer)
				if triggerPlayer ~= player then
					return
				end
				local hatchRemote = RemoteEvents:FindFirstChild("TryNestHatch")
				if hatchRemote then
					hatchRemote:FireServer(nestIndex, eggId)
				end
			end)
			model.Parent = view.model
			eggView = { id = eggData.id, model = model, prompt = prompt, promptConnect = promptConnect }
			table.insert(view.eggs, eggView :: EggView)
		end
		local shownEgg = eggView :: EggView

		-- a tier-jump egg glows, and the others don't
		local glow = shownEgg.model:FindFirstChild("Glow")
		if glow then
			for _, descendant in glow:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					descendant.Enabled = eggData.isTierJump == true
				end
			end
		end
		-- eggs slide to the next socket when one before them is taken
		shownEgg.model:PivotTo(CFrame.new(socket.Position))
	end
end

function ClientNestWorldManager.createView(self: ClientNestWorldManager, nestIndex: number, model: any): NestView?
	local promptPart = findPromptPart(model)
	if not promptPart then
		return nil
	end

	local prompt = makePrompt(NEST_PROMPT_NAME, "Open", "Nest " .. nestIndex, NEST_PROMPT_DISTANCE, promptPart)
	local promptConnect = prompt.Triggered:Connect(function(triggerPlayer)
		if triggerPlayer ~= player then
			return
		end
		local openNest = self.openNest
		if openNest then
			openNest(nestIndex)
		end
	end)

	return {
		model = model,
		prompt = prompt,
		promptConnect = promptConnect,
		parentIds = {},
		parents = {},
		eggs = {},
	}
end

function ClientNestWorldManager.removeView(self: ClientNestWorldManager, nestIndex: number)
	local view = self.views[nestIndex]
	if not view then
		return
	end
	view.promptConnect:Disconnect()
	for _, egg in view.eggs do
		egg.promptConnect:Disconnect()
	end
	-- the parents and eggs are children of the Nest model, so they go with it
	if view.model.Parent then
		for _, dragon in view.parents do
			dragon:Destroy()
		end
		for _, egg in view.eggs do
			egg.model:Destroy()
		end
		view.prompt:Destroy()
	end
	self.views[nestIndex] = nil
end

-- shows the state on the Nests that exist in the world; a Nest whose model has not arrived yet is picked up by the next refresh
function ClientNestWorldManager.refresh(self: ClientNestWorldManager)
	-- the server sends the player's plot index with the state, so this needs no other module (Teleporters would make a require cycle)
	local state = self.state
	local plotIndex = if state then state.plotIndex else nil
	if not state or not plotIndex then
		return
	end

	local nests: { any } = state.nests
	for nestIndex, view in self.views do
		if nestIndex > #nests or not view.model.Parent then
			self:removeView(nestIndex)
		end
	end

	for nestIndex, nest in nests do
		local view = self.views[nestIndex]
		if not view then
			local model = utils.findFirstDescendantWithNameAndAttribute(Level, "Nest" .. nestIndex, Attributes.INDEX, plotIndex)
			if not model then
				continue
			end
			view = self:createView(nestIndex, model)
			if not view then
				continue
			end
			self.views[nestIndex] = view
		end
		self:updateParents(view, nest)
		self:updateEggs(view, nestIndex, nest)
	end
end

-- the whole Nest state, from ClientNestManager
function ClientNestWorldManager.setData(self: ClientNestWorldManager, state: any)
	self.state = state
	self:refresh()
end

-- what a tap on a Nest does: ClientNestManager opens its screen
function ClientNestWorldManager.setOpenHandler(self: ClientNestWorldManager, handler: (nestIndex: number) -> ())
	self.openNest = handler
end

function ClientNestWorldManager.init(self: ClientNestWorldManager)
	-- a Nest model can arrive after the state does (it streams in with the plot), and the odds config can arrive after it too, so look
	-- again for the Nests that have no view yet and the filled ones whose parents are not shown yet
	ClientTicker.every(RESOLVE_SEC, function()
		local state = self.state
		if not state then
			return
		end
		for nestIndex, nest in state.nests do
			local view = self.views[nestIndex]
			if not view or (not nest.isEmpty and #view.parentIds == 0) then
				self:refresh()
				return
			end
		end
	end)
end

function ClientNestWorldManager.new(): ClientNestWorldManager
	local self = setmetatable({} :: ClientNestWorldManagerFields, ClientNestWorldManager)
	self.state = nil
	self.views = {}
	self.openNest = nil
	return self
end

local singleton = ClientNestWorldManager.new()

return singleton
