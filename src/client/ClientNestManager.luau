--!strict

-- The Hatch Dragons Nests screen. The HUD NestsButton opens the Nests overlay: one card per Nest with its parents, next-egg timer and
-- waiting eggs, a picker to put two bred dragons in, and a reveal popup where an egg's 7 pieces appear before the player
-- sells or keeps it. The server owns everything: the state arrives in the init data and again in NotifyNests after every change, and the
-- client only sends intent (TryNestSet, TryNestClear, TryNestHatch, TryNestDecide). The gui is authored in Studio; see setUpGui for its shape.
local ClientNestManager = {}
ClientNestManager.__index = ClientNestManager

local collectionService = game:GetService("CollectionService")
local httpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- the RemoteEvents children only exist in Studio, so they are untyped here
local RemoteEvents: any = ReplicatedStorage:WaitForChild("RemoteEvents")

local Attributes = require("@game/ReplicatedStorage/Shared/Attributes")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local PairOdds = require("@game/ReplicatedStorage/Shared/PairOdds")
local Tags = require("@game/ReplicatedStorage/Shared/Tags")

local clientHatchOdds = require("./ClientHatchOdds")
local clientNestWorldManager = require("./ClientNestWorldManager")
local ClientTicker = require("./ClientTicker")
local overlayTracker = require("./OverlayTracker")
local Types = require("./Types")

local player = game:GetService("Players").LocalPlayer :: Player

local DISPLAY_ORDER = 20
local REVEAL_STEP_SEC = 0.25

local PART_LABELS: { [string]: string } = {
	headShape = "Head shape",
	faceType = "Face",
	headAttachment = "Head attachment",
	backSpikes = "Back spikes",
	wings = "Wings",
	tailSpike = "Tail spike",
	meshTexture = "Texture",
}

-- piece rarities and dragon bands share one palette
local RARITY_COLORS: { [string]: Color3 } = {
	common = Color3.fromRGB(190, 190, 190),
	uncommon = Color3.fromRGB(90, 220, 90),
	rare = Color3.fromRGB(70, 150, 255),
	epic = Color3.fromRGB(190, 90, 255),
	legendary = Color3.fromRGB(255, 160, 40),
	mythic = Color3.fromRGB(255, 70, 90),
}

type NestsState = {
	nextNestPrice: number?, -- the Gold price of the next Nest the player can buy, nil when there is none
	plotIndex: number?, -- the player's plot, which the Nest models in the world are matched to
	nests: { any }, -- one per slot: { isEmpty = true } or { parentA, parentB, nextLayAt, layTimeSec, eggs }
}

type Candidate = { itemId: number, genome: any }

-- the gui's shape only exists in Studio, so its instances are untyped here
type ClientNestManagerFields = {
	state: NestsState?,
	gui: any?,
	dialog: any?,
	nestList: any?,
	nestTemplate: any?,
	picker: any?,
	reveal: any?,
	openButton: any?,
	buyNestButton: any?,
	isOverlayOpen: boolean,
	pickerNestIndex: number?,
	pickerCandidates: { Candidate },
	pickerSelected: { Candidate },
	revealToken: number,
	revealed: { nestIndex: number, eggId: string }?,
	tickerDisconnect: (() -> ())?,
}

export type ClientNestManager = typeof(setmetatable({} :: ClientNestManagerFields, ClientNestManager))

local function formatPiece(pieceId: string): (string, string)
	local odds = clientHatchOdds:getOdds()
	local piece = if odds then odds.catalog.byId[pieceId] else nil
	if not piece then
		return pieceId, "common"
	end
	local element = piece.element:sub(1, 1):upper() .. piece.element:sub(2)
	return ("%s %s"):format(element, (PART_LABELS[piece.part] or piece.part):lower()), piece.rarity
end

local function getBandName(genome: any): string
	local odds = clientHatchOdds:getOdds()
	if not odds then
		return "common"
	end
	return GenomeValue.getBand(odds, genome)
end

local function getTierName(genome: any): string
	local odds = clientHatchOdds:getOdds()
	local tier = if odds then odds.config.tiers[genome.tier] else nil
	return if tier then tier.name else "?"
end

local function describeGenome(genome: any): string
	return ("%s  %s  (%s)"):format(genome.code, getBandName(genome), getTierName(genome))
end

-- 50000 as "50,000"
local function formatNumber(value: number): string
	local text = tostring(math.floor(value))
	local replaced = 1
	while replaced > 0 do
		text, replaced = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
	end
	return text
end

local function formatDuration(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

-- the bred dragons the player has, in the backpack, in hand or in the world: the shadow parts carry the genome as an attribute
local function findCandidates(): { Candidate }
	local candidates: { Candidate } = {}
	for _, shadow in collectionService:GetTagged(Tags.SHADOW_DRAGON) do
		local genomeJson = shadow:GetAttribute(Attributes.DRAGON_GENOME)
		local itemId = shadow:GetAttribute(Attributes.ITEM_ID)
		if shadow:GetAttribute(Attributes.USER_ID) == player.UserId and type(genomeJson) == "string" and type(itemId) == "number" then
			local isDecoded, genome = pcall(httpService.JSONDecode, httpService, genomeJson)
			if isDecoded and type(genome) == "table" then
				table.insert(candidates, { itemId = itemId, genome = genome })
			end
		end
	end
	table.sort(candidates, function(a: Candidate, b: Candidate)
		return a.itemId < b.itemId
	end)
	return candidates
end

local function setVisible(inst: any?, isVisible: boolean)
	if inst then
		inst.Visible = isVisible
	end
end

local function setText(inst: any?, text: string)
	if inst then
		inst.Text = text
	end
end

local function clearGenerated(container: any, template: any)
	for _, child in container:GetChildren() do
		if child ~= template and child:IsA("GuiObject") and child:GetAttribute("Generated") then
			child:Destroy()
		end
	end
end

local function cloneTemplate(template: any, container: any, name: string): any
	local clone = template:Clone()
	clone.Name = name
	clone.Visible = true
	clone:SetAttribute("Generated", true)
	clone.Parent = container
	return clone
end

local function countEggs(state: NestsState?): number
	local count = 0
	if state then
		for _, nest in state.nests do
			if not nest.isEmpty then
				count += #nest.eggs
			end
		end
	end
	return count
end

-- ===== the Nest cards =====

function ClientNestManager.refreshTimers(self: ClientNestManager)
	local nestList, state = self.nestList, self.state
	if not nestList or not state then
		return
	end
	local now = workspace:GetServerTimeNow()
	for index, nest in state.nests do
		local card = nestList:FindFirstChild("Nest" .. index)
		local timer = if card and not nest.isEmpty then card:FindFirstChild("Timer", true) else nil
		if timer then
			timer.Text = if nest.nextLayAt then ("Next egg in %s"):format(formatDuration(nest.nextLayAt - now)) else "Full: hatch an egg"
		end
	end
end

function ClientNestManager.rebuildNests(self: ClientNestManager)
	local nestList, template, state = self.nestList, self.nestTemplate, self.state
	if not nestList or not template or not state then
		return
	end

	clearGenerated(nestList, template)
	for index, nest in state.nests do
		local card = cloneTemplate(template, nestList, "Nest" .. index)
		card.LayoutOrder = index
		setText(card:FindFirstChild("Title"), "Nest " .. index)

		local filled = card:FindFirstChild("FilledFrame")
		local pairButton = card:FindFirstChild("PairButton")
		setVisible(card:FindFirstChild("EmptyLabel"), nest.isEmpty)
		setVisible(pairButton, nest.isEmpty)
		setVisible(filled, not nest.isEmpty)

		if pairButton then
			pairButton.Activated:Connect(function()
				self:openPicker(index)
			end)
		end

		if not nest.isEmpty and filled then
			setText(filled:FindFirstChild("ParentA"), describeGenome(nest.parentA))
			setText(filled:FindFirstChild("ParentB"), describeGenome(nest.parentB))

			local clearButton = filled:FindFirstChild("ClearButton")
			if clearButton then
				clearButton.Activated:Connect(function()
					RemoteEvents.TryNestClear:FireServer(index)
				end)
			end

			local eggList = filled:FindFirstChild("EggList")
			local eggTemplate = if eggList then eggList:FindFirstChild("EggTemplate") else nil
			if eggList and eggTemplate then
				clearGenerated(eggList, eggTemplate)
				for eggIndex, egg in nest.eggs do
					local eggFrame = cloneTemplate(eggTemplate, eggList, "Egg" .. eggIndex)
					eggFrame.LayoutOrder = eggIndex
					setText(eggFrame:FindFirstChild("Label"), if egg.isTierJump then ("Egg %d: glowing!"):format(eggIndex) else ("Egg %d"):format(eggIndex))
					setVisible(eggFrame:FindFirstChild("Glow"), egg.isTierJump)
					local hatchButton = eggFrame:FindFirstChild("HatchButton")
					if hatchButton then
						hatchButton.Activated:Connect(function()
							RemoteEvents.TryNestHatch:FireServer(index, egg.id)
						end)
					end
				end
			end
		end
	end
	self:refreshTimers()
end

function ClientNestManager.refreshHud(self: ClientNestManager)
	local eggCount = countEggs(self.state)
	local button = self.openButton
	if button then
		local alert = button:FindFirstChild("Alert")
		if alert then
			alert.Visible = eggCount > 0
			if alert:IsA("TextLabel") then
				alert.Text = tostring(eggCount)
			end
		end
	end

	local state = self.state

	-- the Buy Nest button shows only while there is a Nest left to buy
	local buyButton = self.buyNestButton
	if buyButton then
		local price = if state then state.nextNestPrice else nil
		buyButton.Visible = price ~= nil
		if price then
			setText(buyButton:FindFirstChild("Label") or buyButton, ("Buy Nest (%s)"):format(formatNumber(price)))
		end
	end
end

-- the whole state: from the init data, and again after every change the server makes
function ClientNestManager.setData(self: ClientNestManager, data: any)
	if type(data) ~= "table" or type(data.nests) ~= "table" then
		return
	end

	self.state = data :: NestsState
	self:refreshHud()
	if self.isOverlayOpen then
		self:rebuildNests()
	end
	clientNestWorldManager:setData(data)
end

-- ===== the picker =====

-- 0.0312 as "3.1%"; chances too small to show are "<0.1%", with the "<" escaped because the text is rich text
local function formatPercent(chance: number): string
	if chance > 0 and chance < 0.001 then
		return "&lt;0.1%"
	end
	return ("%.1f%%"):format(chance * 100)
end

local function capitalize(text: string): string
	return text:sub(1, 1):upper() .. text:sub(2)
end

local function colorText(text: string, rarity: string): string
	local color = RARITY_COLORS[rarity] or Color3.new(1, 1, 1)
	return ('<font color="#%s">%s</font>'):format(color:ToHex(), text)
end

-- the lines of the pairing screen's odds panel: the baby's mix, rarity, value, size, then every part's and the mutation's chances
local function buildOddsLines(odds: HatchOdds.Odds, result: PairOdds.Result): { string }
	local lines: { string } = {}

	local mix = {}
	for _, element in HatchOdds.ELEMENTS do
		local share = result.shares[element] or 0
		if share > 0 then
			table.insert(mix, ("%s %d%%"):format(capitalize(element), math.floor(share * 100 + 0.5)))
		end
	end
	table.insert(lines, "<b>Mix</b>: " .. table.concat(mix, ", "))

	local bands = {}
	for _, band in HatchOdds.DRAGON_BANDS do
		local chance = result.bands[band] or 0
		if chance > 0 then
			table.insert(bands, colorText(("%s %s"):format(capitalize(band), formatPercent(chance)), band))
		end
	end
	table.insert(lines, "<b>Rarity</b>: " .. table.concat(bands, "  "))

	table.insert(lines, ("<b>About</b> %s Gold  |  <b>Size</b> %.2f to %.2f (%s Giant, up to %.2f)"):format(
		formatNumber(result.expectedValue),
		result.sizeMin,
		result.sizeMax,
		formatPercent(result.giantChance),
		result.giantSizeMax
	))
	table.insert(lines, ("<b>Tier jump</b>: %s  |  <b>An egg every</b> %s"):format(formatPercent(result.tierJumpChance), formatDuration(result.layTimeSec)))

	for _, part in HatchOdds.PARTS do
		local entries = {}
		for _, entry in result.parts[part] do
			local name, rarity = formatPiece(entry.id)
			table.insert(entries, colorText(("%s %s"):format(name, formatPercent(entry.chance)), rarity))
		end
		table.insert(lines, ("<b>%s</b>: %s"):format(PART_LABELS[part] or part, table.concat(entries, "  |  ")))
	end

	local mutations = {}
	for _, entry in result.mutations do
		table.insert(mutations, ("%s %s"):format(capitalize(entry.id), formatPercent(entry.chance)))
	end
	table.insert(lines, "<b>Mutation</b>: " .. table.concat(mutations, "  |  "))
	return lines
end

-- fills the odds panel for the two picked dragons, or empties it
function ClientNestManager.refreshPickerOdds(self: ClientNestManager)
	local picker = self.picker
	local oddsList = if picker then picker:FindFirstChild("OddsList") else nil
	local template = if oddsList then oddsList:FindFirstChild("OddsTemplate") else nil
	if not oddsList or not template then
		return
	end
	clearGenerated(oddsList, template)

	local odds = clientHatchOdds:getOdds()
	if not odds or #self.pickerSelected < 2 then
		return
	end
	local result = PairOdds.get(odds, self.pickerSelected[1].genome, self.pickerSelected[2].genome, nil)
	if not result then
		return
	end
	for order, line in buildOddsLines(odds, result) do
		local row = cloneTemplate(template, oddsList, "Odds" .. order)
		row.LayoutOrder = order
		row.RichText = true
		row.Text = line
	end
end

function ClientNestManager.refreshPickerHint(self: ClientNestManager)
	local picker = self.picker
	local hint = if picker then picker:FindFirstChild("Hint") else nil
	if #self.pickerSelected < 2 then
		setText(hint, "Pick two bred dragons of the same tier")
	elseif self.pickerSelected[1].genome.tier ~= self.pickerSelected[2].genome.tier then
		setText(hint, "They need the same tier")
	else
		setText(hint, "These are the odds for every egg. Confirm to put them in the Nest")
	end
	self:refreshPickerOdds()
end

function ClientNestManager.refreshPickerDragons(self: ClientNestManager)
	local picker = self.picker
	local dragonList = if picker then picker:FindFirstChild("DragonList") else nil
	local template = if dragonList then dragonList:FindFirstChild("DragonTemplate") else nil
	if not dragonList or not template then
		return
	end

	clearGenerated(dragonList, template)
	for order, candidate in self.pickerCandidates do
		local button = cloneTemplate(template, dragonList, "Dragon" .. order)
		button.LayoutOrder = order
		local label = button:FindFirstChild("Label") or button
		local isSelected = table.find(self.pickerSelected, candidate) ~= nil
		label.Text = (if isSelected then "[x] " else "") .. describeGenome(candidate.genome)
		local mark = button:FindFirstChild("SelectedMark")
		setVisible(mark, isSelected)
		button.Activated:Connect(function()
			local selectedIndex = table.find(self.pickerSelected, candidate)
			if selectedIndex then
				table.remove(self.pickerSelected, selectedIndex)
			elseif #self.pickerSelected < 2 then
				table.insert(self.pickerSelected, candidate)
			end
			self:refreshPickerDragons()
			self:refreshPickerHint()
		end)
	end
	if #self.pickerCandidates == 0 then
		setText(picker:FindFirstChild("Hint"), "You have no bred dragons yet")
	end
end

function ClientNestManager.openPicker(self: ClientNestManager, nestIndex: number)
	local picker = self.picker
	if not picker then
		return
	end
	self.pickerNestIndex = nestIndex
	self.pickerCandidates = findCandidates()
	self.pickerSelected = {}
	picker.Visible = true
	self:refreshPickerDragons()
	self:refreshPickerHint()
end

function ClientNestManager.closePicker(self: ClientNestManager)
	setVisible(self.picker, false)
	self.pickerNestIndex = nil
end

function ClientNestManager.confirmPicker(self: ClientNestManager)
	local nestIndex = self.pickerNestIndex
	if not nestIndex or #self.pickerSelected < 2 then
		return
	end
	RemoteEvents.TryNestSet:FireServer(nestIndex, self.pickerSelected[1].itemId, self.pickerSelected[2].itemId)
	self:closePicker()
end

-- ===== the reveal =====

function ClientNestManager.closeReveal(self: ClientNestManager)
	self.revealToken += 1
	self.revealed = nil
	setVisible(self.reveal, false)
end

-- the server's answer to TryNestHatch: the pieces appear one by one, then the banner's rarity colors the screen
function ClientNestManager.showReveal(self: ClientNestManager, reveal: any)
	local frame = self.reveal
	if not frame or type(reveal) ~= "table" or type(reveal.genome) ~= "table" then
		return
	end

	-- an egg tapped in the world opens the screen first, which also clears any earlier reveal
	if not self.isOverlayOpen then
		self:openDialog()
	end

	local genome = reveal.genome
	self.revealToken += 1
	local token = self.revealToken
	self.revealed = { nestIndex = reveal.nestIndex, eggId = reveal.eggId }

	local pieceList = frame:FindFirstChild("PieceList")
	local pieceTemplate = if pieceList then pieceList:FindFirstChild("PieceTemplate") else nil
	if pieceList and pieceTemplate then
		clearGenerated(pieceList, pieceTemplate)
	end
	setText(frame:FindFirstChild("Banner"), "")
	setText(frame:FindFirstChild("Subtitle"), "")
	setText(frame:FindFirstChild("Mutation"), "")
	setText(frame:FindFirstChild("Size"), "")
	setText(frame:FindFirstChild("Value"), "")
	frame.Visible = true

	task.spawn(function()
		if pieceList and pieceTemplate then
			for order, part in HatchOdds.PARTS do
				task.wait(REVEAL_STEP_SEC)
				if token ~= self.revealToken then
					return
				end
				local row = cloneTemplate(pieceTemplate, pieceList, "Piece" .. order)
				row.LayoutOrder = order
				local name, rarity = formatPiece(genome.pieces[part])
				local label = row:FindFirstChild("Label") or row
				label.Text = ("%s: %s (%s)"):format(PART_LABELS[part] or part, name, rarity)
				label.TextColor3 = RARITY_COLORS[rarity] or label.TextColor3
			end
		end
		task.wait(REVEAL_STEP_SEC)
		if token ~= self.revealToken then
			return
		end

		local banner = frame:FindFirstChild("Banner")
		if banner then
			banner.Text = string.upper(reveal.band)
			banner.TextColor3 = RARITY_COLORS[reveal.band] or banner.TextColor3
		end
		setText(frame:FindFirstChild("Subtitle"), (if reveal.isTierJump then "TIER JUMP! " else "") .. getTierName(genome))
		setText(frame:FindFirstChild("Mutation"), if genome.mutation == "normal" then "No mutation" else "Mutation: " .. genome.mutation)
		setText(frame:FindFirstChild("Size"), ("Size %.2f%s"):format(genome.size, if genome.isGiant then " (Giant!)" else ""))
		setText(frame:FindFirstChild("Value"), ("Sell value: %d coins"):format(reveal.value))
	end)
end

function ClientNestManager.decide(self: ClientNestManager, decision: string)
	local revealed = self.revealed
	if not revealed then
		return
	end
	RemoteEvents.TryNestDecide:FireServer(revealed.nestIndex, revealed.eggId, decision)
	self:closeReveal()
end

-- ===== the overlay =====

function ClientNestManager.openDialog(self: ClientNestManager)
	local gui = self.gui
	if self.isOverlayOpen then
		return
	end
	if not gui then
		warn("ClientNestManager: the Nests gui was not set up at startup, see the startup warning")
		return
	end

	self:closePicker()
	self:closeReveal()
	self:rebuildNests()
	self:refreshHud()
	gui.Enabled = true
	self.isOverlayOpen = true
	overlayTracker:notifyBeginOverlay((self :: any) :: Types.Overlay)

	-- the countdowns tick while the screen is up
	self.tickerDisconnect = ClientTicker.every(0.5, function()
		self:refreshTimers()
	end)
end

function ClientNestManager.toggleDialog(self: ClientNestManager)
	if self.isOverlayOpen then
		self:closeDialog()
	else
		self:openDialog()
	end
end

-- the HUD button lives in the main HUD ScreenGui, which ScreenGuiManager owns and wires up; its optional Alert child shows the waiting eggs
function ClientNestManager.setHudButton(self: ClientNestManager, button: any)
	self.openButton = button
	self:refreshHud()
end

function ClientNestManager.closeDialogGui(self: ClientNestManager)
	local gui = self.gui
	if gui then
		gui.Enabled = false
	end
	self:closePicker()
	self:closeReveal()
	local disconnect = self.tickerDisconnect
	if disconnect then
		disconnect()
		self.tickerDisconnect = nil
	end
end

function ClientNestManager.closeDialog(self: ClientNestManager)
	if not self.isOverlayOpen then
		return
	end
	self.isOverlayOpen = false
	self:closeDialogGui()
	overlayTracker:notifyEndOverlay((self :: any) :: Types.Overlay)
end

function ClientNestManager.getGuiRoot(self: ClientNestManager): any
	return self.dialog
end

function ClientNestManager.getHudElements(self: ClientNestManager): { number }
	return {}
end

function ClientNestManager.doesWantBlur(self: ClientNestManager): boolean
	return false
end

-- called by the overlay tracker when another overlay takes over
function ClientNestManager.notifyForceEnd(self: ClientNestManager)
	self.isOverlayOpen = false
	self:closeDialogGui()
end

function ClientNestManager.notifyClickOutside(self: ClientNestManager)
	self:closeDialog()
end

-- ===== setup =====

-- In the main HUD ScreenGui, a NestsFrame holding a NestsButton (an optional child Alert, a label or frame, shows the number of waiting eggs).
-- In StarterGui, a ScreenGui named Nests with ResetOnSpawn off and Enabled off:
--   Dialog, with CloseButton, an optional BuyNestButton (with a Label; shown while a Nest can be bought) and
--     NestList (a list layout) holding the hidden NestTemplate: Title, EmptyLabel, PairButton, and FilledFrame with ParentA, ParentB,
--       Timer, ClearButton and EggList (a list layout) holding the hidden EggTemplate: Label, HatchButton and an optional Glow
--     Picker (hidden): DragonList holding the hidden DragonTemplate (Label, optional SelectedMark), OddsList holding the hidden OddsTemplate (a rich text label), Hint, ConfirmButton, CancelButton
--     Reveal (hidden): Banner, Subtitle, PieceList holding the hidden PieceTemplate (Label), Mutation, Size, Value, SellButton, KeepButton,
--       CloseButton
function ClientNestManager.setUpGui(self: ClientNestManager)
	local playerGui = player:WaitForChild("PlayerGui")
	local gui: any = playerGui:WaitForChild("Nests", 10)
	if not gui then
		warn("ClientNestManager: the Nests gui is missing from PlayerGui; the Nests screen is disabled")
		return
	end

	local dialog: any = gui:FindFirstChild("Dialog")
	local nestList: any = dialog and dialog:FindFirstChild("NestList")
	local nestTemplate: any = nestList and nestList:FindFirstChild("NestTemplate")
	local picker: any = dialog and dialog:FindFirstChild("Picker")
	local reveal: any = dialog and dialog:FindFirstChild("Reveal")
	if not dialog or not nestList or not nestTemplate or not picker or not reveal then
		warn("ClientNestManager: Nests needs Dialog/NestList/NestTemplate, Dialog/Picker and Dialog/Reveal; the Nests screen is disabled")
		return
	end

	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = DISPLAY_ORDER
	nestTemplate.Visible = false
	picker.Visible = false
	reveal.Visible = false
	for _, hidden in {
		nestTemplate:FindFirstChild("FilledFrame") and nestTemplate.FilledFrame:FindFirstChild("EggList") and nestTemplate.FilledFrame.EggList:FindFirstChild("EggTemplate"),
		picker:FindFirstChild("DragonList") and picker.DragonList:FindFirstChild("DragonTemplate"),
		picker:FindFirstChild("OddsList") and picker.OddsList:FindFirstChild("OddsTemplate"),
		reveal:FindFirstChild("PieceList") and reveal.PieceList:FindFirstChild("PieceTemplate"),
	} do
		if hidden then
			hidden.Visible = false
		end
	end

	self.gui = gui
	self.dialog = dialog
	self.nestList = nestList
	self.nestTemplate = nestTemplate
	self.picker = picker
	self.reveal = reveal
	self.buyNestButton = dialog:FindFirstChild("BuyNestButton")
	if self.buyNestButton then
		self.buyNestButton.Activated:Connect(function()
			local buyRemote = RemoteEvents:FindFirstChild("TryNestBuy")
			if buyRemote then
				buyRemote:FireServer()
			else
				warn("ClientNestManager: RemoteEvents.TryNestBuy is missing, so Nests can't be bought")
			end
		end)
	end

	local function connect(parent: any, name: string, callback: () -> ())
		local button = parent:FindFirstChild(name)
		if button then
			button.Activated:Connect(callback)
		else
			warn("ClientNestManager: missing button " .. name .. " in " .. parent.Name)
		end
	end
	connect(dialog, "CloseButton", function()
		self:closeDialog()
	end)
	connect(picker, "ConfirmButton", function()
		self:confirmPicker()
	end)
	connect(picker, "CancelButton", function()
		self:closePicker()
	end)
	connect(reveal, "SellButton", function()
		self:decide("sell")
	end)
	connect(reveal, "KeepButton", function()
		self:decide("keep")
	end)
	connect(reveal, "CloseButton", function()
		self:closeReveal()
	end)

	self:refreshHud()
end

function ClientNestManager.init(self: ClientNestManager)
	-- the Remotes are made in Studio; without them the screen can't work
	local notifyNests = RemoteEvents:FindFirstChild("NotifyNests")
	local notifyReveal = RemoteEvents:FindFirstChild("NotifyNestReveal")
	if not notifyNests or not notifyReveal or not RemoteEvents:FindFirstChild("TryNestSet") then
		warn("ClientNestManager: the Nest RemoteEvents are missing (TryNestSet, TryNestClear, TryNestHatch, TryNestDecide, NotifyNests, NotifyNestReveal); the Nests screen is disabled")
		return
	end

	-- a tap on a Nest in the world opens this screen
	clientNestWorldManager:setOpenHandler(function()
		if not self.isOverlayOpen then
			self:openDialog()
		end
	end)
	clientNestWorldManager:init()

	notifyNests.OnClientEvent:Connect(function(data: any)
		self:setData(data)
	end)
	notifyReveal.OnClientEvent:Connect(function(reveal: any)
		self:showReveal(reveal)
	end)

	task.spawn(function()
		self:setUpGui()
	end)
end

function ClientNestManager.new(): ClientNestManager
	local self = setmetatable({} :: ClientNestManagerFields, ClientNestManager)
	self.state = nil
	self.gui = nil
	self.dialog = nil
	self.nestList = nil
	self.nestTemplate = nil
	self.picker = nil
	self.reveal = nil
	self.openButton = nil
	self.buyNestButton = nil
	self.isOverlayOpen = false
	self.pickerNestIndex = nil
	self.pickerCandidates = {}
	self.pickerSelected = {}
	self.revealToken = 0
	self.revealed = nil
	self.tickerDisconnect = nil
	return self
end

local singleton = ClientNestManager.new()

return singleton
