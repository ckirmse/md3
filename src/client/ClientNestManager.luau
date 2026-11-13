--!strict

-- The Hatch Dragons Nests screen. The HUD NestsButton opens the Nests overlay: one card per Nest with its parents, next-egg timer and
-- waiting eggs, a picker to put two bred dragons in, and a reveal popup where an egg's 7 pieces appear before the player
-- sells or keeps it. The server owns everything: the state arrives in the init data and again in NotifyNests after every change, and the
-- client only sends intent (TryNestSet, TryNestClear, TryNestHatch, TryNestDecide). The gui is authored in Studio; see setUpGui for its shape.
local ClientNestManager = {}
ClientNestManager.__index = ClientNestManager

local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- the RemoteEvents children only exist in Studio, so they are untyped here
local RemoteEvents: any = ReplicatedStorage:WaitForChild("RemoteEvents")

local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local NestMath = require("@game/ReplicatedStorage/Shared/NestMath")
local PairOdds = require("@game/ReplicatedStorage/Shared/PairOdds")
local PlayerAttributeKeys = require("@game/ReplicatedStorage/Shared/PlayerAttributeKeys")

local ClientGenomeUi = require("./ClientGenomeUi")
local clientHatchOdds = require("./ClientHatchOdds")
local clientNestWorldManager = require("./ClientNestWorldManager")
local clientPlayerAttributesManager = require("./ClientPlayerAttributesManager")
local ClientTicker = require("./ClientTicker")
local overlayTracker = require("./OverlayTracker")
local Types = require("./Types")

local player = game:GetService("Players").LocalPlayer :: Player

local DISPLAY_ORDER = 20
local REVEAL_STEP_SEC = 0.25

local PART_LABELS = ClientGenomeUi.PART_LABELS
local RARITY_COLORS = ClientGenomeUi.RARITY_COLORS
local formatPiece = ClientGenomeUi.formatPiece
local getTierName = ClientGenomeUi.getTierName
local describeGenome = ClientGenomeUi.describeGenome
local formatTraits = ClientGenomeUi.formatTraits
local formatPercent = ClientGenomeUi.formatPercent
local capitalize = ClientGenomeUi.capitalize
local colorText = ClientGenomeUi.colorText
local findCandidates = ClientGenomeUi.findCandidates
local setVisible = ClientGenomeUi.setVisible
local setText = ClientGenomeUi.setText
local clearGenerated = ClientGenomeUi.clearGenerated
local cloneTemplate = ClientGenomeUi.cloneTemplate
local setButtonEnabled = ClientGenomeUi.setButtonEnabled

local WEATHER_LABELS: { [string]: string } = {
	rain = "Rain",
	heatwave = "Heatwave",
	bloomStorm = "Bloom Storm",
	thunderstorm = "Thunderstorm",
}

type NestsState = {
	weather: string?, -- the Hatch weather running now, which boosts one mutation of the eggs laid during it
	nextNestPrice: number?, -- the Gold price of the next Nest the player can buy, nil when there is none
	plotIndex: number?, -- the player's plot, which the Nest models in the world are matched to
	nests: { any }, -- one per slot: { isEmpty = true } or { parentA, parentB, nextLayAt, isRemoving, pendingEgg, layTimeSec, eggs }
}

type Candidate = ClientGenomeUi.Candidate

-- the gui's shape only exists in Studio, so its instances are untyped here
type ClientNestManagerFields = {
	state: NestsState?,
	gui: any?,
	dialog: any?,
	nestList: any?,
	nestTemplate: any?,
	picker: any?,
	reveal: any?,
	lens: any?,
	lensNestIndex: number?,
	lensEggId: string?,
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
			if nest.nextLayAt then
				local format = if nest.isRemoving then "Removing in %s" else "Next egg in %s"
				timer.Text = format:format(formatDuration(nest.nextLayAt - now))
			else
				timer.Text = "Full: hatch an egg"
			end
		end
	end
	self:refreshLens()
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

			-- a running timer has an egg on the way: the button opens the Egg Lens on it
			local speedUpButton = filled:FindFirstChild("SpeedUpButton")
			setVisible(speedUpButton, nest.pendingEgg ~= nil and nest.nextLayAt ~= nil)
			if speedUpButton then
				speedUpButton.Activated:Connect(function()
					self:showLens(index)
				end)
			end

			local clearButton = filled:FindFirstChild("ClearButton")
			if clearButton then
				-- while a removal is queued the same button cancels it
				setText(clearButton:FindFirstChild("Label") or clearButton, if nest.isRemoving then "Keep breeding" else "Remove")
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
					local hasTraits = egg.traits ~= nil and #egg.traits > 0
					setText(eggFrame:FindFirstChild("Traits"), if hasTraits then formatTraits(egg.traits) else "")
					setVisible(eggFrame:FindFirstChild("Traits"), hasTraits)
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
	self:refreshLens()
	if self.picker and self.picker.Visible then
		self:refreshPickerOdds()
	end
	if self.isOverlayOpen then
		self:rebuildNests()
	end
	clientNestWorldManager:setData(data)
end

-- ===== the picker =====

-- the lines of the pairing screen's odds panel: the baby's mix, rarity, value, size, then every part's and the mutation's chances
local function buildOddsLines(odds: HatchOdds.Odds, result: PairOdds.Result, weather: string?): { string }
	local lines: { string } = {}
	if weather then
		table.insert(lines, ("<b>Weather now</b>: %s, which boosts its matching mutation for eggs laid during it"):format(WEATHER_LABELS[weather] or weather))
	end

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
	local weather = if self.state then self.state.weather else nil
	local result = PairOdds.get(odds, self.pickerSelected[1].genome, self.pickerSelected[2].genome, weather :: any)
	if not result then
		return
	end
	for order, line in buildOddsLines(odds, result, weather) do
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

-- ===== the Egg Lens and the lay speed-up =====

-- The Egg Lens shows the egg a Nest is about to lay (it was rolled when the timer started), in full and for free, and offers to finish the
-- timer now for Diamonds. Paying sends the egg's id, so the server charges only if that is still the egg the player looked at.

function ClientNestManager.closeLens(self: ClientNestManager)
	setVisible(self.lens, false)
	self.lensNestIndex = nil
	self.lensEggId = nil
end

function ClientNestManager.showLens(self: ClientNestManager, nestIndex: number)
	local frame, state = self.lens, self.state
	local odds = clientHatchOdds:getOdds()
	local nest = if state then state.nests[nestIndex] else nil
	if not frame or not odds or not nest or nest.isEmpty or not nest.pendingEgg then
		return
	end

	local genome = nest.pendingEgg
	self.lensNestIndex = nestIndex
	self.lensEggId = genome.uuid

	local pieceList = frame:FindFirstChild("PieceList")
	local pieceTemplate = if pieceList then pieceList:FindFirstChild("PieceTemplate") else nil
	if pieceList and pieceTemplate then
		clearGenerated(pieceList, pieceTemplate)
		for order, part in HatchOdds.PARTS do
			local row = cloneTemplate(pieceTemplate, pieceList, "Piece" .. order)
			row.LayoutOrder = order
			local name, rarity = formatPiece(genome.pieces[part])
			local label = row:FindFirstChild("Label") or row
			label.Text = ("%s: %s (%s)"):format(PART_LABELS[part] or part, name, rarity)
			label.TextColor3 = RARITY_COLORS[rarity] or label.TextColor3
		end
	end

	local band = GenomeValue.getBand(odds, genome)
	local banner = frame:FindFirstChild("Banner")
	if banner then
		banner.Text = string.upper(band)
		banner.TextColor3 = RARITY_COLORS[band] or banner.TextColor3
	end
	setText(frame:FindFirstChild("Subtitle"), (if genome.tier > nest.parentA.tier then "TIER JUMP! " else "") .. getTierName(genome))
	setText(frame:FindFirstChild("Mutation"), if genome.mutation == "normal" then "No mutation" else "Mutation: " .. genome.mutation)
	setText(frame:FindFirstChild("Size"), ("Size %.2f%s"):format(genome.size, if genome.isGiant then " (Giant!)" else ""))
	setText(frame:FindFirstChild("Value"), ("Sell value: %d coins"):format(math.floor(GenomeValue.getValue(odds, genome))))
	frame.Visible = true
	self:refreshLens()
end

-- keeps the price and the pay button current while the Lens is open, and closes it when its egg has been laid or the Nest has changed
function ClientNestManager.refreshLens(self: ClientNestManager)
	local frame, state = self.lens, self.state
	if not frame or not frame.Visible or not state then
		return
	end
	local odds = clientHatchOdds:getOdds()
	local nest = if self.lensNestIndex then state.nests[self.lensNestIndex] else nil
	if not odds or not nest or nest.isEmpty or not nest.pendingEgg or nest.pendingEgg.uuid ~= self.lensEggId or not nest.nextLayAt then
		self:closeLens()
		return
	end

	local now = workspace:GetServerTimeNow()
	local cost = NestMath.getSpeedUpCost(odds, nest.nextLayAt, now)
	if cost < 1 then
		self:closeLens()
		return
	end
	local diamonds = clientPlayerAttributesManager:get(PlayerAttributeKeys.DIAMONDS) or 0
	setText(frame:FindFirstChild("Info"), ("Ready in %s | you have %d Diamonds"):format(formatDuration(nest.nextLayAt - now), diamonds))
	local payButton = frame:FindFirstChild("PayButton")
	if payButton then
		setText(payButton:FindFirstChild("Label") or payButton, ("Speed up for %d Diamonds"):format(cost))
		setButtonEnabled(payButton, diamonds >= cost)
	end
end

function ClientNestManager.confirmLens(self: ClientNestManager)
	local nestIndex, eggId = self.lensNestIndex, self.lensEggId
	if not nestIndex or not eggId then
		return
	end
	local remote = RemoteEvents:FindFirstChild("TryNestSpeedUp")
	if not remote then
		warn("ClientNestManager: RemoteEvents.TryNestSpeedUp is missing, so Nests can't be sped up")
		return
	end
	remote:FireServer(nestIndex, eggId)
	self:closeLens()
end

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
	setText(frame:FindFirstChild("Traits"), "")
	setVisible(frame:FindFirstChild("Traits"), false)
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
		local hasTraits = genome.traits ~= nil and #genome.traits > 0
		setText(frame:FindFirstChild("Traits"), if hasTraits then "Traits: " .. formatTraits(genome.traits) else "")
		setVisible(frame:FindFirstChild("Traits"), hasTraits)
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
	self:closeLens()
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
	self:closeLens()
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
--       Timer, SpeedUpButton, ClearButton and EggList (a list layout) holding the hidden EggTemplate: Label, Traits, HatchButton and an optional Glow
--     Picker (hidden): DragonList holding the hidden DragonTemplate (Label, optional SelectedMark), OddsList holding the hidden OddsTemplate (a rich text label), Hint, ConfirmButton, CancelButton
--     Lens (hidden, optional) opened by a Nest's SpeedUpButton: Banner, Subtitle, PieceList (hidden PieceTemplate: Label), Mutation, Size, Value, Info,
--       PayButton (with a Label), CloseButton
--     Reveal (hidden): Banner, Subtitle, PieceList holding the hidden PieceTemplate (Label), Mutation, Traits, Size, Value, SellButton, KeepButton,
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
	-- the Egg Lens is optional: without it Nests work and can't be sped up
	local lens: any = dialog:FindFirstChild("Lens")
	if lens then
		lens.Visible = false
		local lensPieceTemplate = lens:FindFirstChild("PieceList") and lens.PieceList:FindFirstChild("PieceTemplate")
		if lensPieceTemplate then
			lensPieceTemplate.Visible = false
		end
		self.lens = lens
		connect(lens, "PayButton", function()
			self:confirmLens()
		end)
		connect(lens, "CloseButton", function()
			self:closeLens()
		end)
	end
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
	self.lens = nil
	self.lensNestIndex = nil
	self.lensEggId = nil
	self.revealToken = 0
	self.revealed = nil
	self.tickerDisconnect = nil
	return self
end

local singleton = ClientNestManager.new()

return singleton
