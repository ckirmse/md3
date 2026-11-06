--!strict

-- Builds a bred dragon's look onto a freshly cloned caster: the caster is the old model chosen by GenomeItemName, and each slot that
-- should look different takes the part from the matching old model (GenomeLook) and puts it on the same attachment.
-- Wings and the tail swap by attachment (the wing flapping reads those attachments, so swapped wings flap like the originals), back spikes
-- by their place on each body segment, eyes recolor, and the body segments take another model's texture (their mesh is shared by every model).
local ClientDragonKit = {}
ClientDragonKit.__index = ClientDragonKit

local httpService = game:GetService("HttpService")

local Attributes = require("@game/ReplicatedStorage/Shared/Attributes")
local GenomeLook = require("@game/ReplicatedStorage/Shared/GenomeLook")
local utils = require("@game/ReplicatedStorage/Shared/utils")

local clientHatchOdds = require("./ClientHatchOdds")

-- how ClientDragonManager poses the wings at rest: the left wing rotates by this about X, the right by 180 minus it
local WING_REST_ANGLE = 90

type ClientDragonKitFields = {}

export type ClientDragonKit = typeof(setmetatable({} :: ClientDragonKitFields, ClientDragonKit))

-- the casters and donors are Studio-authored models, so their parts are untyped here
local function getBodyNumber(name: string): number?
	local digits = name:match("^Body_(%d+)$")
	return if digits then tonumber(digits) else nil
end

local function getDonorModel(donor: GenomeLook.Donor, level: string): any?
	local name = "Dragon" .. donor.color .. donor.rarity .. level
	return utils.getGameAssetPathReference("Dragons." .. donor.color .. "." .. donor.rarity .. "." .. name)
end

-- points every constraint that used the old attachment at the new one
local function repointConstraints(caster: any, oldAttachment: any, newAttachment: any)
	for _, descendant in caster:GetDescendants() do
		if descendant:IsA("Constraint") then
			if descendant.Attachment0 == oldAttachment then
				descendant.Attachment0 = newAttachment
			end
			if descendant.Attachment1 == oldAttachment then
				descendant.Attachment1 = newAttachment
			end
		end
	end
end

local function swapWings(caster: any, donorModel: any)
	for _, side in { "Left", "Right" } do
		local name = "Wing_" .. side
		local old = caster:FindFirstChild(name)
		local donorWing = donorModel:FindFirstChild(name)
		local bodyAttachment = caster.Body_01:FindFirstChild(name)
		if not (old and donorWing and bodyAttachment) or old.MeshId == donorWing.MeshId then
			continue
		end

		local new = donorWing:Clone()
		new.Parent = caster
		local angle = if side == "Left" then WING_REST_ANGLE else 180 - WING_REST_ANGLE
		new.CFrame = bodyAttachment.WorldCFrame * CFrame.fromEulerAnglesXYZ(math.rad(angle), 0, 0) * new.Wing.CFrame:Inverse()
		new.Anchored = old.Anchored
		repointConstraints(caster, old.Wing, new.Wing)
		old:Destroy()
	end
end

local function swapTail(caster: any, donorModel: any)
	local old = caster:FindFirstChild("Tail")
	local donorTail = donorModel:FindFirstChild("Tail")
	if not (old and donorTail) or old.MeshId == donorTail.MeshId then
		return
	end

	-- the tail hangs off the last body segment
	local lastBody: any = nil
	local lastNumber = 0
	for _, child in caster:GetChildren() do
		local number = getBodyNumber(child.Name)
		if number and number > lastNumber then
			lastBody, lastNumber = child, number
		end
	end
	if not lastBody then
		return
	end

	local new = donorTail:Clone()
	new.Parent = caster
	new.CFrame = lastBody.BodyBack.WorldCFrame * new.Tail.CFrame:Inverse()
	new.Anchored = old.Anchored
	repointConstraints(caster, old.Tail, new.Tail)
	old:Destroy()
end

-- back spikes are one Horn_00 per body segment, welded to it
local function swapSpikes(caster: any, donorModel: any)
	for _, body in caster:GetChildren() do
		if not getBodyNumber(body.Name) then
			continue
		end
		local old = body:FindFirstChild("Horn_00")
		local donorBody = donorModel:FindFirstChild(body.Name)
		local donorSpike = donorBody and donorBody:FindFirstChild("Horn_00")
		if not (old and donorSpike) or old.MeshId == donorSpike.MeshId then
			continue
		end

		local new = donorSpike:Clone()
		new.Parent = body
		new.CFrame = body.CFrame * donorBody.CFrame:ToObjectSpace(donorSpike.CFrame)
		new.Anchored = old.Anchored
		for _, child in body:GetChildren() do
			if child:IsA("WeldConstraint") and child.Part1 == old then
				child.Part1 = new
			end
		end
		old:Destroy()
	end
end

local function recolorEyes(caster: any, donorModel: any)
	local head = caster:FindFirstChild("Head")
	local donorHead = donorModel:FindFirstChild("Head")
	if not (head and donorHead) then
		return
	end
	for _, name in { "Eye_Left", "Eye_Right" } do
		local eye = head:FindFirstChild(name)
		local donorEye = donorHead:FindFirstChild(name)
		if eye and donorEye then
			-- a union takes its children's colors unless it uses its own
			if eye:IsA("UnionOperation") then
				eye.UsePartColor = true
			end
			eye.Color = donorEye.Color
			eye.Material = donorEye.Material
		end
	end
end

local function retextureBody(caster: any, donorModel: any)
	for _, body in caster:GetChildren() do
		if not getBodyNumber(body.Name) then
			continue
		end
		local donorBody = donorModel:FindFirstChild(body.Name)
		if donorBody then
			body.TextureID = donorBody.TextureID
		end
	end
end

-- Applies the genome in the JSON attribute to the caster. Returns whether the look was built; a failure leaves the plain model.
function ClientDragonKit.apply(self: ClientDragonKit, caster: any, genomeJson: string): boolean
	local odds = clientHatchOdds:getOdds()
	if not odds then
		return false
	end

	local isDecoded, genome = pcall(httpService.JSONDecode, httpService, genomeJson)
	if not isDecoded or type(genome) ~= "table" then
		warn("ClientDragonKit: unreadable genome on", caster.Name)
		return false
	end

	local look = GenomeLook.get(odds, genome)
	if not look then
		return false
	end

	-- the donors are the same level as the caster, so their parts have the same size and place
	local level = caster.Name:match("(%d+)$")
	if not level then
		warn("ClientDragonKit: caster name has no level", caster.Name)
		return false
	end

	local isBuilt, errorMessage = pcall(function()
		local wings = getDonorModel(look.wings, level)
		local tail = getDonorModel(look.tail, level)
		local spikes = getDonorModel(look.spikes, level)
		local eyes = getDonorModel(look.eyes, level)
		local bodyTexture = getDonorModel(look.bodyTexture, level)
		if wings then
			swapWings(caster, wings)
		end
		if tail then
			swapTail(caster, tail)
		end
		if spikes then
			swapSpikes(caster, spikes)
		end
		if eyes then
			recolorEyes(caster, eyes)
		end
		if bodyTexture then
			retextureBody(caster, bodyTexture)
		end
	end)
	if not isBuilt then
		warn("ClientDragonKit: failed to build", caster.Name, errorMessage)
		return false
	end

	caster:SetAttribute(Attributes.GENOME_BUILT, true)
	return true
end

function ClientDragonKit.new(): ClientDragonKit
	local self = setmetatable({} :: ClientDragonKitFields, ClientDragonKit)
	return self
end

local singleton = ClientDragonKit.new()

return singleton
