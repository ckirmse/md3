--!strict

-- The text and gui helpers the Hatch Dragons screens share (the Nests screen and the Restyle screen): piece and dragon names, rarity
-- colours, percent formatting, the list of the player's bred dragons, and small helpers for the Studio-authored guis.
local ClientGenomeUi = {}

local collectionService = game:GetService("CollectionService")
local httpService = game:GetService("HttpService")
local tweenService = game:GetService("TweenService")

local Attributes = require("@game/ReplicatedStorage/Shared/Attributes")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local Tags = require("@game/ReplicatedStorage/Shared/Tags")

local clientHatchOdds = require("./ClientHatchOdds")

local player = game:GetService("Players").LocalPlayer :: Player

-- a bred dragon the player has; isInWorld is true while it stands in the world instead of the backpack
export type Candidate = { itemId: number, genome: any, isInWorld: boolean }

ClientGenomeUi.PART_LABELS = {
	headShape = "Head shape",
	faceType = "Face type",
	headAttachment = "Head attachment",
	backSpikes = "Back spikes",
	wings = "Wings",
	tailSpike = "Tail spike",
	meshTexture = "Mesh texture",
} :: { [string]: string }

-- piece rarities and dragon bands share one palette
ClientGenomeUi.RARITY_COLORS = {
	common = Color3.fromRGB(190, 190, 190),
	uncommon = Color3.fromRGB(90, 220, 90),
	rare = Color3.fromRGB(70, 150, 255),
	epic = Color3.fromRGB(190, 90, 255),
	legendary = Color3.fromRGB(255, 160, 40),
	mythic = Color3.fromRGB(255, 70, 90),
} :: { [string]: Color3 }

-- a piece's display name ("Fire wings") and its rarity
function ClientGenomeUi.formatPiece(pieceId: string): (string, string)
	local odds = clientHatchOdds:getOdds()
	local piece = if odds then odds.catalog.byId[pieceId] else nil
	if not piece then
		return pieceId, "common"
	end
	local element = piece.element:sub(1, 1):upper() .. piece.element:sub(2)
	return ("%s %s"):format(element, (ClientGenomeUi.PART_LABELS[piece.part] or piece.part):lower()), piece.rarity
end

function ClientGenomeUi.getBandName(genome: any): string
	local odds = clientHatchOdds:getOdds()
	if not odds then
		return "common"
	end
	return GenomeValue.getBand(odds, genome)
end

function ClientGenomeUi.getTierName(genome: any): string
	local odds = clientHatchOdds:getOdds()
	local tier = if odds then odds.config.tiers[genome.tier] else nil
	return if tier then tier.name else "?"
end

function ClientGenomeUi.describeGenome(genome: any): string
	return ("%s  %s  (%s)"):format(genome.code, ClientGenomeUi.getBandName(genome), ClientGenomeUi.getTierName(genome))
end

-- { "soaked", "toasty" } as "Soaked + Toasty"
function ClientGenomeUi.formatTraits(traits: { string }): string
	local names = {}
	for _, trait in traits do
		table.insert(names, trait:sub(1, 1):upper() .. trait:sub(2))
	end
	return table.concat(names, " + ")
end

-- 0.0312 as "3.1%"; chances too small to show are "<0.1%", with the "<" escaped because the text is rich text
function ClientGenomeUi.formatPercent(chance: number): string
	if chance > 0 and chance < 0.001 then
		return "&lt;0.1%"
	end
	return ("%.1f%%"):format(chance * 100)
end

function ClientGenomeUi.capitalize(text: string): string
	return text:sub(1, 1):upper() .. text:sub(2)
end

-- the text in the colour of a rarity or band, for rich text labels
function ClientGenomeUi.colorText(text: string, rarity: string): string
	local color = ClientGenomeUi.RARITY_COLORS[rarity] or Color3.new(1, 1, 1)
	return ('<font color="#%s">%s</font>'):format(color:ToHex(), text)
end

-- the bred dragons the player has, in the backpack, in hand or in the world: the shadow parts carry the genome as an attribute
function ClientGenomeUi.findCandidates(): { Candidate }
	local candidates: { Candidate } = {}
	for _, shadow in collectionService:GetTagged(Tags.SHADOW_DRAGON) do
		local genomeJson = shadow:GetAttribute(Attributes.DRAGON_GENOME)
		local itemId = shadow:GetAttribute(Attributes.ITEM_ID)
		if shadow:GetAttribute(Attributes.USER_ID) == player.UserId and type(genomeJson) == "string" and type(itemId) == "number" then
			local isDecoded, genome = pcall(httpService.JSONDecode, httpService, genomeJson)
			if isDecoded and type(genome) == "table" then
				table.insert(candidates, { itemId = itemId, genome = genome, isInWorld = shadow.Parent == workspace })
			end
		end
	end
	table.sort(candidates, function(a: Candidate, b: Candidate)
		return a.itemId < b.itemId
	end)
	return candidates
end

function ClientGenomeUi.setVisible(inst: any?, isVisible: boolean)
	if inst then
		inst.Visible = isVisible
	end
end

function ClientGenomeUi.setText(inst: any?, text: string)
	if inst then
		inst.Text = text
	end
end

-- A button's text goes in its child Label when it has one: a gradient on the button would tint the button's own text, but not a child's.
function ClientGenomeUi.setButtonText(button: any?, text: string)
	if button then
		local label = button:FindFirstChild("Label")
		ClientGenomeUi.setText(label or button, text)
	end
end

-- removes the clones made by cloneTemplate, keeping the template
function ClientGenomeUi.clearGenerated(container: any, template: any)
	for _, child in container:GetChildren() do
		if child ~= template and child:IsA("GuiObject") and child:GetAttribute("Generated") then
			child:Destroy()
		end
	end
end

local DISABLED_COLOR = Color3.fromRGB(110, 110, 110)

-- A button the player can't use is greyed out and can't be pressed. Its normal look is read once and kept as attributes, so it comes back
-- exactly when it can be used again.
function ClientGenomeUi.setButtonEnabled(button: any?, isEnabled: boolean)
	if not button then
		return
	end
	if button:GetAttribute("EnabledColor") == nil then
		button:SetAttribute("EnabledColor", button.BackgroundColor3)
		button:SetAttribute("EnabledTransparency", button.BackgroundTransparency)
	end
	button.Interactable = isEnabled
	button.BackgroundColor3 = if isEnabled then button:GetAttribute("EnabledColor") else DISABLED_COLOR
	button.BackgroundTransparency = if isEnabled then button:GetAttribute("EnabledTransparency") else 0.3
	local gradient = button:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Enabled = isEnabled
	end
	local label = button:FindFirstChild("Label") or (if button:IsA("TextButton") then button else nil)
	if label then
		label.TextTransparency = if isEnabled then 0 else 0.5
	end
end

local HOVER_SCALE = 1.06
local PRESS_SCALE = 0.95
local HOVER_LIFT = 0.25 -- how much more solid a list row or tab gets under the mouse
local HOVER_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad)

-- A button grows under the mouse and shrinks when pressed, through a UIScale, so its colours are never touched. A button a layout places
-- (a tab, a list row) can't grow, since its list clips it, so it gets more solid instead. resetHover puts everything back, because a button
-- the mouse was over when its screen closed would otherwise reopen changed.
function ClientGenomeUi.bindHover(button: any)
	if button:GetAttribute("HoverBound") then
		return
	end
	button:SetAttribute("HoverBound", true)

	local parent = button.Parent
	local isInLayout = parent ~= nil and (parent:FindFirstChildOfClass("UIListLayout") or parent:FindFirstChildOfClass("UIGridLayout")) ~= nil
	if isInLayout then
		local baseTransparency = button.BackgroundTransparency
		button:SetAttribute("HoverBaseTransparency", baseTransparency)
		local function liftTo(transparency: number)
			tweenService:Create(button, HOVER_TWEEN, { BackgroundTransparency = transparency }):Play()
		end
		button.MouseEnter:Connect(function()
			liftTo(math.max(0, baseTransparency - HOVER_LIFT))
		end)
		button.MouseLeave:Connect(function()
			liftTo(baseTransparency)
		end)
		return
	end

	-- a UIScale grows a button from its anchor point, so the anchor moves to the middle and the position shifts by half the size to keep the
	-- button where it was
	if button.AnchorPoint == Vector2.zero then
		local size, position = button.Size, button.Position
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.new(
			position.X.Scale + size.X.Scale * 0.5,
			position.X.Offset + size.X.Offset * 0.5,
			position.Y.Scale + size.Y.Scale * 0.5,
			position.Y.Offset + size.Y.Offset * 0.5
		)
	end

	local scale: any = button:FindFirstChild("HoverScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "HoverScale"
		scale.Parent = button
	end
	local function scaleTo(target: number)
		tweenService:Create(scale, HOVER_TWEEN, { Scale = target }):Play()
	end
	button.MouseEnter:Connect(function()
		scaleTo(HOVER_SCALE)
	end)
	button.MouseLeave:Connect(function()
		scaleTo(1)
	end)
	button.MouseButton1Down:Connect(function()
		scaleTo(PRESS_SCALE)
	end)
	button.MouseButton1Up:Connect(function()
		scaleTo(HOVER_SCALE)
	end)
end

-- binds every button under the root except those inside a hidden template, whose clones are bound as they are made
function ClientGenomeUi.bindHoverIn(root: any)
	for _, inst in root:GetDescendants() do
		if inst:IsA("TextButton") or inst:IsA("ImageButton") then
			local isInTemplate = false
			local ancestor = inst.Parent
			while ancestor and ancestor ~= root do
				if ancestor.Name:match("Template$") then
					isInTemplate = true
					break
				end
				ancestor = ancestor.Parent
			end
			if not isInTemplate and not inst.Name:match("Template$") then
				ClientGenomeUi.bindHover(inst)
			end
		end
	end
end

function ClientGenomeUi.resetHover(root: any?)
	if not root then
		return
	end
	for _, inst in root:GetDescendants() do
		if inst:IsA("UIScale") and inst.Name == "HoverScale" then
			inst.Scale = 1
		elseif inst:IsA("GuiButton") then
			local base = inst:GetAttribute("HoverBaseTransparency")
			if type(base) == "number" then
				inst.BackgroundTransparency = base
			end
		end
	end
end

function ClientGenomeUi.cloneTemplate(template: any, container: any, name: string): any
	local clone = template:Clone()
	clone.Name = name
	clone.Visible = true
	clone:SetAttribute("Generated", true)
	clone.Parent = container
	if clone:IsA("TextButton") or clone:IsA("ImageButton") then
		ClientGenomeUi.bindHover(clone)
	end
	ClientGenomeUi.bindHoverIn(clone)
	return clone
end

return ClientGenomeUi
