--!strict

-- The Hatch Dragons Nests screen. The HUD NestsButton opens the Nests overlay, a set of pages in one Dialog: the Nest page (tabs, parents, timer, eggs),
-- the pick page, the pairing confirm and the egg chances, plus the Egg Lens and a reveal popup that shows an egg's 7 pieces before the player
-- sells or keeps it. The server owns everything: the state arrives in the init data and again in NotifyNests after every change, and the
-- client only sends intent (TryNestSet, TryNestClear, TryNestHatch, TryNestDecide). The gui is authored in Studio; see setUpGui for its shape.
local ClientNestManager = {}
ClientNestManager.__index = ClientNestManager

local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- the RemoteEvents children only exist in Studio, so they are untyped here
local RemoteEvents: any = ReplicatedStorage:WaitForChild("RemoteEvents")

local ElementColor = require("@game/ReplicatedStorage/Shared/ElementColor")
local GenomeRoll = require("@game/ReplicatedStorage/Shared/GenomeRoll")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local NestMath = require("@game/ReplicatedStorage/Shared/NestMath")
local OddsFormat = require("@game/ReplicatedStorage/Shared/OddsFormat")
local PairOdds = require("@game/ReplicatedStorage/Shared/PairOdds")
local PlayerAttributeKeys = require("@game/ReplicatedStorage/Shared/PlayerAttributeKeys")

local clientDragonPreview = require("./ClientDragonPreview")
local ClientGenomeUi = require("./ClientGenomeUi")
local clientHatchOdds = require("./ClientHatchOdds")
local clientNestWorldManager = require("./ClientNestWorldManager")
local clientPlayerAttributesManager = require("./ClientPlayerAttributesManager")
local ClientTicker = require("./ClientTicker")
local overlayTracker = require("./OverlayTracker")
local Types = require("./Types")

local player = game:GetService("Players").LocalPlayer :: Player

local DISPLAY_ORDER = 20

local PART_LABELS = ClientGenomeUi.PART_LABELS
local RARITY_COLORS = ClientGenomeUi.RARITY_COLORS
local formatPiece = ClientGenomeUi.formatPiece
local getTierName = ClientGenomeUi.getTierName
local describeGenome = ClientGenomeUi.describeGenome
local formatTraits = ClientGenomeUi.formatTraits
local capitalize = ClientGenomeUi.capitalize
local findCandidates = ClientGenomeUi.findCandidates
local setVisible = ClientGenomeUi.setVisible
local setText = ClientGenomeUi.setText
local setButtonText = ClientGenomeUi.setButtonText
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
	page: string, -- the page of the Dialog that is showing
	selectedNest: number,
	chancesReturn: string, -- the page the Back button of the chances page goes to
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
	if seconds >= 3600 then
		return ("%d:%02d:%02d"):format(seconds // 3600, seconds % 3600 // 60, seconds % 60)
	end
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

-- the dragon preview is an optional ViewportFrame named Preview inside a Lens, Reveal or parent card
local function getPreview(frame: any?): any?
	return if frame then frame:FindFirstChild("Preview") else nil
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

-- ===== the pages =====

local PAGE_NAMES = { "NestPage", "PickPage", "ConfirmPage", "ChancesPage" }

-- 1240000 as "1.24M", smaller numbers in full
local function formatCompact(value: number): string
	if value >= 1e6 then
		return ("%.2fM"):format(value / 1e6)
	end
	return formatNumber(value)
end

-- the slices of an egg-chances bar: parent A's piece, parent B's, a piece both have, and anything else
local SOURCE_COLORS: { [string]: Color3 } = {
	a = Color3.fromRGB(255, 226, 130),
	b = Color3.fromRGB(190, 232, 225),
	both = Color3.fromRGB(228, 205, 245),
	new = Color3.new(1, 1, 1),
}

local MYSTERY_EGG_COLOR = Color3.new(0, 0, 0)

local BAR_EDGE = 0.0005 -- the width of the blend between two slices of a bar, so the edge between them stays sharp

-- Paints a bar in slices of its width. The colours are one UIGradient with hard edges between slices, so they follow the bar's rounded
-- corners (a frame per slice would poke out past them). The bar's own colour is white and its Gradient child carries the slices.
local function paintBar(bar: any?, slices: { { share: number, color: Color3 } })
	local gradient = if bar then bar:FindFirstChild("Gradient") else nil
	if not gradient then
		return
	end
	local shown = {}
	local total = 0
	for _, slice in slices do
		if slice.share > BAR_EDGE * 4 then
			table.insert(shown, slice)
			total += slice.share
		end
	end
	if #shown == 0 then
		return
	end
	local points = {}
	local x = 0
	for index, slice in shown do
		local width = slice.share / total
		table.insert(points, ColorSequenceKeypoint.new(if index == 1 then 0 else x, slice.color))
		x += width
		table.insert(points, ColorSequenceKeypoint.new(if index == #shown then 1 else x - BAR_EDGE, slice.color))
	end
	gradient.Color = ColorSequence.new(points)
end

-- a pill coloured like a rarity band, softened so the dark text stays readable
local function setBandPill(pill: any?, band: string)
	if not pill then
		return
	end
	pill.Text = capitalize(band)
	pill.BackgroundColor3 = (RARITY_COLORS[band] or Color3.new(1, 1, 1)):Lerp(Color3.new(1, 1, 1), 0.55)
end

function ClientNestManager.getPage(self: ClientNestManager, name: string): any?
	return if self.dialog then self.dialog:FindFirstChild(name) else nil
end

-- The previews render every frame, so they only exist while their page is up.
function ClientNestManager.clearPreviews(self: ClientNestManager)
	local nestCard = self:getPage("NestPage") and self:getPage("NestPage"):FindFirstChild("Card")
	local confirmCard = self:getPage("ConfirmPage") and self:getPage("ConfirmPage"):FindFirstChild("Card")
	local panel = if nestCard then nestCard:FindFirstChild("BreedPanel") else nil
	for _, holder in { panel, confirmCard } do
		for _, side in { "A", "B" } do
			local parentCard = if holder then holder:FindFirstChild("Parent" .. side) or holder:FindFirstChild("Parent" .. side .. "Card") else nil
			if parentCard then
				clientDragonPreview.clear(getPreview(parentCard))
				parentCard:SetAttribute("ShownId", nil)
			end
		end
	end
	-- the mystery egg beside the timer and on the confirm page's egg card
	local eggBox = if panel then panel:FindFirstChild("EggBox") else nil
	clientDragonPreview.clear(getPreview(eggBox))
	if eggBox then
		eggBox:SetAttribute("ShownId", nil)
	end
	clientDragonPreview.clear(getPreview(confirmCard and confirmCard:FindFirstChild("EggCard")))
end

function ClientNestManager.showPage(self: ClientNestManager, name: string)
	self:clearPreviews()
	ClientGenomeUi.resetHover(self.dialog)
	self.page = name
	for _, pageName in PAGE_NAMES do
		setVisible(self:getPage(pageName), pageName == name)
	end
	self:refreshPage()
end

function ClientNestManager.refreshPage(self: ClientNestManager)
	local name = self.page
	if name == "NestPage" then
		self:refreshNestPage()
	elseif name == "PickPage" then
		self:refreshPick()
	elseif name == "ConfirmPage" then
		self:refreshConfirm()
	elseif name == "ChancesPage" then
		self:refreshChances()
	end
	self:refreshCurrencies()
end

function ClientNestManager.refreshCurrencies(self: ClientNestManager)
	local bar = if self.dialog then self.dialog:FindFirstChild("CurrencyBar") else nil
	if not bar then
		return
	end
	for _, entry in {
		{ "GoldLabel", PlayerAttributeKeys.COINS, "Gold" },
		{ "DiamondsLabel", PlayerAttributeKeys.DIAMONDS, "Diamonds" },
		{ "TokensLabel", PlayerAttributeKeys.RESTYLE_TOKENS, "Tokens" },
	} do
		local pill = bar:FindFirstChild(entry[1])
		local text = if pill then pill:FindFirstChild("Text") else nil
		setText(text, ("%s %s"):format(entry[3], formatCompact(clientPlayerAttributesManager:get(entry[2]) or 0)))
	end
end

-- the weather's short note for the odds screens, nil when none is running
local function getWeatherNote(weather: string?): string?
	if not weather then
		return nil
	end
	return ("<b>%s</b> is boosting its matching mutation for eggs laid now"):format(WEATHER_LABELS[weather] or weather)
end

-- ===== the Nest page =====

function ClientNestManager.getSelectedNest(self: ClientNestManager): any?
	local state = self.state
	return if state then state.nests[self.selectedNest] else nil
end

function ClientNestManager.selectNest(self: ClientNestManager, index: number)
	self.selectedNest = index
	self:clearPreviews()
	self:refreshPage()
end

-- the Nest's countdown, ring-like progress bar and skip price; runs every half second while the screen is up
function ClientNestManager.refreshTimers(self: ClientNestManager)
	self:refreshCurrencies()
	local odds = clientHatchOdds:getOdds()
	local nest = self:getSelectedNest()
	local page = self:getPage("NestPage")
	local card = if page and self.page == "NestPage" then page:FindFirstChild("Card") else nil
	if card and odds and nest and not nest.isEmpty then
		local now = workspace:GetServerTimeNow()
		local box = card.BreedPanel:FindFirstChild("EggBox")
		if box then
			if nest.nextLayAt then
				setText(box:FindFirstChild("TimerLabel"), formatDuration(nest.nextLayAt - now))
				setText(box:FindFirstChild("TimerCaption"), if nest.isRemoving then "then the dragons return" else "until the next egg")
				local layTime = math.max(1, nest.layTimeSec or 1)
				local fill = box.ProgressTrack:FindFirstChild("Fill")
				if fill then
					fill.Size = UDim2.fromScale(math.clamp(1 - (nest.nextLayAt - now) / layTime, 0, 1), 1)
				end
			else
				setText(box:FindFirstChild("TimerLabel"), "Full")
				setText(box:FindFirstChild("TimerCaption"), "hatch an egg to keep laying")
				local fill = box.ProgressTrack:FindFirstChild("Fill")
				if fill then
					fill.Size = UDim2.fromScale(1, 1)
				end
			end
		end
		local cost = NestMath.getSpeedUpCost(odds, nest.nextLayAt, now)
		setText(card:FindFirstChild("CostLabel"), if cost > 0 then ("%d Diamonds"):format(cost) else "")
	end
	self:refreshLens()
end

-- the tabs, the two parents, the egg strip and the buttons for the selected Nest
function ClientNestManager.refreshNestPage(self: ClientNestManager)
	local page, state = self:getPage("NestPage"), self.state
	local odds = clientHatchOdds:getOdds()
	local card = if page then page:FindFirstChild("Card") else nil
	if not card or not state or not odds then
		return
	end
	self.selectedNest = math.clamp(self.selectedNest, 1, math.max(1, #state.nests))
	local nestIndex = self.selectedNest
	local nest = state.nests[nestIndex]
	local isEmpty = nest == nil or nest.isEmpty

	setText(card:FindFirstChild("Title"), "Nest " .. nestIndex)

	local tabs = card:FindFirstChild("Tabs")
	local tabTemplate = if tabs then tabs:FindFirstChild("TabTemplate") else nil
	if tabs and tabTemplate then
		clearGenerated(tabs, tabTemplate)
		for index = 1, math.max(odds.config.nests.maxCount, #state.nests) do
			local tab = cloneTemplate(tabTemplate, tabs, "Tab" .. index)
			tab.LayoutOrder = index
			local isOpen = index <= #state.nests
			tab.Text = if isOpen then tostring(index) else "Lock"
			tab.BackgroundColor3 = if index == nestIndex then Color3.fromRGB(0, 249, 0) elseif isOpen then Color3.fromRGB(0, 0, 0) else Color3.fromRGB(60, 60, 60)
			tab.Interactable = isOpen
			tab.Activated:Connect(function()
				self:selectNest(index)
			end)
		end
	end

	local buyButton = card:FindFirstChild("BuyNestButton")
	self.buyNestButton = buyButton
	self:refreshHud()

	local panel = card:FindFirstChild("BreedPanel")
	if panel then
		for _, name in { "ParentA", "ParentB", "PlusLabel", "ArrowLabel", "EggBox" } do
			setVisible(panel:FindFirstChild(name), not isEmpty)
		end
		setVisible(panel:FindFirstChild("EmptyPanel"), isEmpty)
		if not isEmpty then
			for side, genome in { A = nest.parentA, B = nest.parentB } do
				local parentCard = panel:FindFirstChild("Parent" .. side)
				if parentCard and parentCard:GetAttribute("ShownId") ~= genome.uuid then
					parentCard:SetAttribute("ShownId", genome.uuid)
					clientDragonPreview.show(getPreview(parentCard), genome, "turn")
					setText(parentCard:FindFirstChild("Label"), ("Parent %s  %s"):format(side, genome.code))
				end
			end
		end
	end

	-- an egg nobody has looked inside is a black one; it is drawn once and kept while the Nest has the same pair
	local eggBox = if panel then panel:FindFirstChild("EggBox") else nil
	if eggBox and not isEmpty and eggBox:GetAttribute("ShownId") ~= nest.parentA.uuid .. nest.parentB.uuid then
		eggBox:SetAttribute("ShownId", nest.parentA.uuid .. nest.parentB.uuid)
		clientDragonPreview.showEgg(getPreview(eggBox), MYSTERY_EGG_COLOR)
	elseif eggBox and isEmpty then
		clientDragonPreview.clear(getPreview(eggBox))
		eggBox:SetAttribute("ShownId", nil)
	end

	local strip = card:FindFirstChild("EggStrip")
	local eggList = if strip then strip:FindFirstChild("EggList") else nil
	local eggTemplate = if eggList then eggList:FindFirstChild("EggTemplate") else nil
	local emptyTemplate = if eggList then eggList:FindFirstChild("EmptyTemplate") else nil
	setVisible(strip, not isEmpty)
	if strip and eggList and eggTemplate and emptyTemplate and not isEmpty then
		local eggCap = NestMath.getEggCap(odds)
		setText(strip:FindFirstChild("EggCountLabel"), ("%d of %d eggs"):format(#nest.eggs, eggCap))
		clearGenerated(eggList, eggTemplate)
		clearGenerated(eggList, emptyTemplate)
		-- every egg of a Nest has the pair's element mix, so they share one tint
		local eggTint = ElementColor.blend(GenomeRoll.mixShares(nest.parentA.shares, nest.parentB.shares))
		for slot = 1, eggCap do
			local egg = nest.eggs[slot]
			if egg then
				local frame = cloneTemplate(eggTemplate, eggList, "Egg" .. slot)
				frame.LayoutOrder = slot
				local glow = frame:FindFirstChild("Glow")
				if glow then
					glow.Enabled = egg.isTierJump == true
				end
				setVisible(frame:FindFirstChild("TierBadge"), egg.isTierJump == true)
				clientDragonPreview.showEgg(getPreview(frame), eggTint, true)
				local hasTraits = egg.traits ~= nil and #egg.traits > 0
				setText(frame:FindFirstChild("Traits"), if hasTraits then formatTraits(egg.traits) else "")
				setVisible(frame:FindFirstChild("Traits"), hasTraits)
				local hatchButton = frame:FindFirstChild("HatchButton")
				if hatchButton then
					hatchButton.Activated:Connect(function()
						RemoteEvents.TryNestHatch:FireServer(nestIndex, egg.id)
					end)
				end
			else
				local frame = cloneTemplate(emptyTemplate, eggList, "Slot" .. slot)
				frame.LayoutOrder = slot
			end
		end
	end

	local hasEggOnTheWay = not isEmpty and nest.pendingEgg ~= nil and nest.nextLayAt ~= nil
	setVisible(card:FindFirstChild("SkipButton"), hasEggOnTheWay)
	setVisible(card:FindFirstChild("CostLabel"), hasEggOnTheWay)
	setVisible(card:FindFirstChild("SeeChancesButton"), not isEmpty)
	local stopButton = card:FindFirstChild("StopButton")
	setVisible(stopButton, not isEmpty)
	-- while a removal is queued the same button cancels it
	setButtonText(stopButton, if not isEmpty and nest.isRemoving then "Keep breeding" else "Stop")
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
	if self.isOverlayOpen and (self.page == "NestPage" or self.page == "ChancesPage") then
		self:refreshPage()
	end
	clientNestWorldManager:setData(data)
end

-- ===== picking the parents =====

function ClientNestManager.refreshPick(self: ClientNestManager)
	local page = self:getPage("PickPage")
	local card = if page then page:FindFirstChild("Card") else nil
	local dragonList = if card then card:FindFirstChild("DragonList") else nil
	local template = if dragonList then dragonList:FindFirstChild("DragonTemplate") else nil
	if not card or not dragonList or not template then
		return
	end

	local selected = self.pickerSelected
	local firstTier = if selected[1] then selected[1].genome.tier else nil
	local hint = card:FindFirstChild("Hint")
	if #self.pickerCandidates == 0 then
		setText(hint, "You have no bred dragons yet")
	elseif #selected == 0 then
		setText(hint, "Pick two bred dragons of the same tier")
	elseif #selected == 1 then
		setText(hint, "Now pick one more of the same tier")
	else
		setText(hint, "Ready: press Next to see what they would lay")
	end
	setButtonEnabled(card:FindFirstChild("ConfirmButton"), #selected == 2)
	setButtonText(page:FindFirstChild("BackButton"), ("< Nest %d"):format(self.pickerNestIndex or self.selectedNest))

	clearGenerated(dragonList, template)
	for order, candidate in self.pickerCandidates do
		local button = cloneTemplate(template, dragonList, "Dragon" .. order)
		button.LayoutOrder = order
		local isSelected = table.find(selected, candidate) ~= nil
		-- another tier can't breed with the first pick, so it is greyed out
		local isOtherTier = firstTier ~= nil and candidate.genome.tier ~= firstTier
		local label = button:FindFirstChild("Label") or button
		label.Text = describeGenome(candidate.genome)
		label.TextTransparency = if isOtherTier and not isSelected then 0.6 else 0
		button.Interactable = isSelected or not isOtherTier
		setVisible(button:FindFirstChild("SelectedMark"), isSelected)
		button.Activated:Connect(function()
			local selectedIndex = table.find(self.pickerSelected, candidate)
			if selectedIndex then
				table.remove(self.pickerSelected, selectedIndex)
			elseif #self.pickerSelected < 2 then
				table.insert(self.pickerSelected, candidate)
			end
			self:refreshPick()
		end)
	end
end

function ClientNestManager.openPicker(self: ClientNestManager, nestIndex: number)
	self.pickerNestIndex = nestIndex
	self.pickerCandidates = findCandidates()
	self.pickerSelected = {}
	self:showPage("PickPage")
end

-- ===== the pairing confirm =====

function ClientNestManager.refreshConfirm(self: ClientNestManager)
	local page = self:getPage("ConfirmPage")
	local card = if page then page:FindFirstChild("Card") else nil
	local odds = clientHatchOdds:getOdds()
	local selected = self.pickerSelected
	if not card or not odds or #selected < 2 then
		return
	end
	local weather = if self.state then self.state.weather else nil
	local result = PairOdds.get(odds, selected[1].genome, selected[2].genome, weather :: any)
	if not result then
		self:showPage("PickPage")
		return
	end

	setButtonText(page:FindFirstChild("BackButton"), ("< Nest %d"):format(self.pickerNestIndex or self.selectedNest))
	for index, side in { "A", "B" } do
		local parentCard = card:FindFirstChild("Parent" .. side .. "Card")
		local genome = selected[index].genome
		if parentCard then
			clientDragonPreview.show(getPreview(parentCard), genome, "turn")
			setBandPill(parentCard:FindFirstChild("RarityPill"), ClientGenomeUi.getBandName(genome))
		end
	end

	clientDragonPreview.showEgg(getPreview(card:FindFirstChild("EggCard")), MYSTERY_EGG_COLOR)

	local colorTile = card:FindFirstChild("ColorTile")
	local slices = {}
	for _, element in HatchOdds.ELEMENTS do
		table.insert(slices, { share = result.shares[element] or 0, color = ElementColor.COLORS[element] })
	end
	paintBar(if colorTile then colorTile:FindFirstChild("Bar") else nil, slices)
	local mix = {}
	for _, element in HatchOdds.ELEMENTS do
		local share = result.shares[element] or 0
		if share > 0 then
			table.insert(mix, ("%d%% %s"):format(math.floor(share * 100 + 0.5), capitalize(element)))
		end
	end
	setText(colorTile and colorTile:FindFirstChild("Legend"), table.concat(mix, "   "))

	local likelyTile = card:FindFirstChild("LikelyTile")
	setBandPill(likelyTile and likelyTile:FindFirstChild("BandPill"), result.likelyBand)
	setText(likelyTile and likelyTile:FindFirstChild("ChanceLabel"), OddsFormat.aboutInTen(result.likelyBandChance))
	local timeTile = card:FindFirstChild("TimeTile")
	setText(timeTile and timeTile:FindFirstChild("TimeLabel"), formatDuration(result.layTimeSec))

	local valueTile, sizeTile, weatherTile = card:FindFirstChild("ValueTile"), card:FindFirstChild("SizeTile"), card:FindFirstChild("WeatherTile")
	setText(valueTile and valueTile:FindFirstChild("Text"), ("<b>Sells for about</b> %s Gold"):format(formatNumber(result.expectedValue)))
	setText(sizeTile and sizeTile:FindFirstChild("Text"), ("<b>Size</b> %.2f to %.2f, Giant up to %.2f"):format(result.sizeMin, result.sizeMax, result.giantSizeMax))
	local note = getWeatherNote(weather)
	setVisible(weatherTile, note ~= nil)
	setText(weatherTile and weatherTile:FindFirstChild("Text"), note or "")
end

function ClientNestManager.startBreeding(self: ClientNestManager)
	local nestIndex = self.pickerNestIndex
	if not nestIndex or #self.pickerSelected < 2 then
		return
	end
	RemoteEvents.TryNestSet:FireServer(nestIndex, self.pickerSelected[1].itemId, self.pickerSelected[2].itemId)
	self.selectedNest = nestIndex
	self.pickerNestIndex = nil
	self:showPage("NestPage")
end

-- ===== the egg chances =====

-- the parents the chances page reads: the picked pair while confirming, otherwise the selected Nest's pair
function ClientNestManager.getChancesParents(self: ClientNestManager): (any?, any?)
	if self.chancesReturn == "ConfirmPage" then
		local a, b = self.pickerSelected[1], self.pickerSelected[2]
		return if a then a.genome else nil, if b then b.genome else nil
	end
	local nest = self:getSelectedNest()
	if nest and not nest.isEmpty then
		return nest.parentA, nest.parentB
	end
	return nil, nil
end

function ClientNestManager.refreshChances(self: ClientNestManager)
	local page = self:getPage("ChancesPage")
	local card = if page then page:FindFirstChild("Card") else nil
	local list = if card then card:FindFirstChild("PartList") else nil
	local template = if list then list:FindFirstChild("PartTemplate") else nil
	local odds = clientHatchOdds:getOdds()
	local parentA, parentB = self:getChancesParents()
	if not card or not list or not template or not odds or not parentA or not parentB then
		self:showPage(if self.chancesReturn == "ConfirmPage" then "PickPage" else "NestPage")
		return
	end
	local weather = if self.state then self.state.weather else nil
	local result = PairOdds.get(odds, parentA, parentB, weather :: any)
	if not result then
		self:showPage("NestPage")
		return
	end

	setButtonText(page:FindFirstChild("BackButton"), if self.chancesReturn == "ConfirmPage" then "< Back" else ("< Nest %d"):format(self.selectedNest))
	setVisible(card:FindFirstChild("StartButton"), self.chancesReturn == "ConfirmPage")

	clearGenerated(list, template)
	for order, part in HatchOdds.PARTS do
		local row = cloneTemplate(template, list, "Part" .. order)
		row.LayoutOrder = order
		setText(row:FindFirstChild("Number"), tostring(order))
		setText(row:FindFirstChild("Name"), PART_LABELS[part] or part)
		local bar = row:FindFirstChild("Bar")
		local sources = result.partSources[part]
		if bar then
			local x = 0
			local slices = {}
			for _, entry in {
				{ "SegA", sources.a, "A", "a" },
				{ "SegB", sources.b, "B", "b" },
				{ "SegBoth", sources.both, "A+B", "both" },
				{ "SegNew", sources.new, "New", "new" },
			} do
				local seg = bar:FindFirstChild(entry[1])
				local share = entry[2] :: number
				table.insert(slices, { share = share, color = SOURCE_COLORS[entry[4]] })
				if seg then
					seg.Position = UDim2.fromScale(x, 0)
					seg.Size = UDim2.fromScale(share, 1)
					seg.Visible = share > 0.0005
					-- a slice too thin for its percentage shows only its letter, and a thinner one nothing
					local percent = ("%d%%"):format(math.floor(share * 100 + 0.5))
					local text = if share >= 0.14 then ("%s %s"):format(entry[3], percent) elseif share >= 0.05 then entry[3] else ""
					setText(seg:FindFirstChild("Text"), text)
				end
				x += share
			end
			paintBar(bar, slices)
		end
	end

	local lucky = card:FindFirstChild("LuckyPanel")
	if lucky then
		setText(lucky.MutationRow:FindFirstChild("Value"), OddsFormat.inHundred(result.mutationChance))
		setText(lucky.GiantRow:FindFirstChild("Value"), OddsFormat.inHundred(result.giantChance))
		setText(lucky.TierUpRow:FindFirstChild("Value"), OddsFormat.inHundred(result.tierJumpChance))
		setText(lucky:FindFirstChild("WeatherNote"), getWeatherNote(weather) or "")
	end
end

function ClientNestManager.openChances(self: ClientNestManager, returnPage: string)
	self.chancesReturn = returnPage
	self:showPage("ChancesPage")
end

-- ===== the reveal =====

-- ===== the Egg Lens and the lay speed-up =====

-- The Egg Lens shows the egg a Nest is about to lay (it was rolled when the timer started), in full and for free, and offers to finish the
-- timer now for Diamonds. Paying sends the egg's id, so the server charges only if that is still the egg the player looked at.

function ClientNestManager.closeLens(self: ClientNestManager)
	clientDragonPreview.clear(getPreview(self.lens))
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
	clientDragonPreview.show(getPreview(frame), genome)
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
	self.revealed = nil
	clientDragonPreview.clear(getPreview(self.reveal))
	setVisible(self.reveal, false)
end

-- the server's answer to TryNestHatch: the whole egg is shown at once, the banner's rarity coloring the screen
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
	self.revealed = { nestIndex = reveal.nestIndex, eggId = reveal.eggId }

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
	frame.Visible = true
	clientDragonPreview.show(getPreview(frame), genome)
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

	self:closeReveal()
	self:closeLens()
	self:refreshHud()
	ClientGenomeUi.resetHover(self.dialog)
	gui.Enabled = true
	self:showPage("NestPage")
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
	self:clearPreviews()
	self:closeReveal()
	self:closeLens()
	ClientGenomeUi.resetHover(self.dialog)
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
-- In StarterGui, a ScreenGui named Nests with ResetOnSpawn off and Enabled off, holding a Dialog with:
--   CurrencyBar: GoldLabel, DiamondsLabel, TokensLabel (each a frame with a Text label)
--   NestPage: BackButton and a Card with Title, BuyNestButton, Tabs (a list layout holding the hidden TabTemplate button), BreedPanel (ParentA and ParentB,
--     each with a Preview ViewportFrame and a Label; PlusLabel, ArrowLabel, EggBox with TimerLabel, TimerCaption and ProgressTrack/Fill; EmptyPanel with a
--     PairButton), EggStrip (EggCountLabel, EggList holding the hidden EggTemplate: Icon, Glow (a UIStroke), HatchButton, Traits, and EmptyTemplate), SkipButton,
--     CostLabel, SeeChancesButton, StopButton
--   PickPage: BackButton and a Card with Hint, DragonList holding the hidden DragonTemplate (Label, SelectedMark), CancelButton, ConfirmButton
--   ConfirmPage: BackButton and a Card with CloseButton, ParentACard and ParentBCard (Preview, RarityPill), ColorTile (Bar with FireSeg, WaterSeg, NatureSeg; Legend),
--     LikelyTile (BandPill, ChanceLabel), TimeTile (TimeLabel), ValueTile, SizeTile, WeatherTile (each with a Text), ChangeButton, ChancesButton, StartButton
--   ChancesPage: BackButton and a Card with CloseButton, PartList holding the hidden PartTemplate (Number, Name, Bar with SegA, SegB, SegBoth, SegNew, each with a
--     Text), LuckyPanel (MutationRow, GiantRow, TierUpRow, each with a Value; WeatherNote), a second BackButton, StartButton
--   Lens (hidden, optional) opened by the SkipButton: Banner, Subtitle, PieceList (hidden PieceTemplate: Label), Mutation, Size, Value, Info,
--     PayButton (with a Label), CloseButton and an optional Preview (a ViewportFrame showing the egg's dragon)
--   Reveal (hidden): Banner, Subtitle, PieceList holding the hidden PieceTemplate (Label), Mutation, Traits, Size, Value, SellButton, KeepButton,
--     CloseButton and an optional Preview (a ViewportFrame)
function ClientNestManager.setUpGui(self: ClientNestManager)
	local playerGui = player:WaitForChild("PlayerGui")
	local gui: any = playerGui:WaitForChild("Nests", 10)
	if not gui then
		warn("ClientNestManager: the Nests gui is missing from PlayerGui; the Nests screen is disabled")
		return
	end

	local dialog: any = gui:FindFirstChild("Dialog")
	local reveal: any = dialog and dialog:FindFirstChild("Reveal")
	local pages: { any } = {}
	for _, name in PAGE_NAMES do
		table.insert(pages, dialog and dialog:FindFirstChild(name))
	end
	if not dialog or not reveal or #pages < #PAGE_NAMES then
		warn("ClientNestManager: Nests needs Dialog with " .. table.concat(PAGE_NAMES, ", ") .. " and Reveal; the Nests screen is disabled")
		return
	end

	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = DISPLAY_ORDER
	reveal.Visible = false
	for _, hidden in {
		dialog.NestPage.Card.Tabs:FindFirstChild("TabTemplate"),
		dialog.NestPage.Card.EggStrip.EggList:FindFirstChild("EggTemplate"),
		dialog.NestPage.Card.EggStrip.EggList:FindFirstChild("EmptyTemplate"),
		dialog.PickPage.Card.DragonList:FindFirstChild("DragonTemplate"),
		dialog.ChancesPage.Card.PartList:FindFirstChild("PartTemplate"),
		reveal:FindFirstChild("PieceList") and reveal.PieceList:FindFirstChild("PieceTemplate"),
	} do
		if hidden then
			hidden.Visible = false
		end
	end

	self.gui = gui
	self.dialog = dialog
	self.reveal = reveal

	local function connect(parent: any, name: string, callback: () -> ())
		local button = parent:FindFirstChild(name)
		if button then
			button.Activated:Connect(callback)
		else
			warn("ClientNestManager: missing button " .. name .. " in " .. parent:GetFullName())
		end
	end

	local nestPage, pickPage, confirmPage, chancesPage = dialog.NestPage, dialog.PickPage, dialog.ConfirmPage, dialog.ChancesPage
	connect(nestPage, "BackButton", function()
		self:closeDialog()
	end)
	local nestCard = nestPage.Card
	self.buyNestButton = nestCard:FindFirstChild("BuyNestButton")
	connect(nestCard, "BuyNestButton", function()
		local buyRemote = RemoteEvents:FindFirstChild("TryNestBuy")
		if buyRemote then
			buyRemote:FireServer()
		else
			warn("ClientNestManager: RemoteEvents.TryNestBuy is missing, so Nests can't be bought")
		end
	end)
	connect(nestCard.BreedPanel.EmptyPanel, "PairButton", function()
		self:openPicker(self.selectedNest)
	end)
	connect(nestCard, "SkipButton", function()
		self:showLens(self.selectedNest)
	end)
	connect(nestCard, "SeeChancesButton", function()
		self:openChances("NestPage")
	end)
	connect(nestCard, "StopButton", function()
		RemoteEvents.TryNestClear:FireServer(self.selectedNest)
	end)

	connect(pickPage, "BackButton", function()
		self:showPage("NestPage")
	end)
	connect(pickPage.Card, "CancelButton", function()
		self:showPage("NestPage")
	end)
	connect(pickPage.Card, "ConfirmButton", function()
		if #self.pickerSelected == 2 then
			self:showPage("ConfirmPage")
		end
	end)

	connect(confirmPage, "BackButton", function()
		self:showPage("NestPage")
	end)
	connect(confirmPage.Card, "CloseButton", function()
		self:showPage("NestPage")
	end)
	connect(confirmPage.Card, "ChangeButton", function()
		self:showPage("PickPage")
	end)
	connect(confirmPage.Card, "ChancesButton", function()
		self:openChances("ConfirmPage")
	end)
	connect(confirmPage.Card, "StartButton", function()
		self:startBreeding()
	end)

	connect(chancesPage, "BackButton", function()
		self:showPage(self.chancesReturn)
	end)
	connect(chancesPage.Card, "BackButton", function()
		self:showPage(self.chancesReturn)
	end)
	connect(chancesPage.Card, "StartButton", function()
		self:startBreeding()
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

	ClientGenomeUi.bindHoverIn(dialog)
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
	self.page = "NestPage"
	self.selectedNest = 1
	self.chancesReturn = "NestPage"
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
	self.revealed = nil
	self.tickerDisconnect = nil
	return self
end

local singleton = ClientNestManager.new()

return singleton
