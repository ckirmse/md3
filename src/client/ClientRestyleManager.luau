--!strict

-- The Restyle screen. The HUD RestyleButton opens a Restyle overlay: the player's bred dragons that are in the backpack, then the chosen
-- dragon's 7 pieces, then the odds for the chosen piece and the price, then pays with Restyle Tokens or Diamonds. The server rolls and charges
-- (TryRestyle sends only the dragon, the piece and how to pay); the odds and prices shown come from the same shared Restyle the server uses.
-- A restyle makes a new dragon item, so the screen re-reads the dragons every second while it is open and redraws when something changed.
-- The gui is authored in Studio; see setUpGui for its shape.
local ClientRestyleManager = {}
ClientRestyleManager.__index = ClientRestyleManager

local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- the RemoteEvents children only exist in Studio, so they are untyped here
local RemoteEvents: any = ReplicatedStorage:WaitForChild("RemoteEvents")

local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local PlayerAttributeKeys = require("@game/ReplicatedStorage/Shared/PlayerAttributeKeys")
local Restyle = require("@game/ReplicatedStorage/Shared/Restyle")

local ClientGenomeUi = require("./ClientGenomeUi")
local clientHatchOdds = require("./ClientHatchOdds")
local clientPlayerAttributesManager = require("./ClientPlayerAttributesManager")
local ClientTicker = require("./ClientTicker")
local overlayTracker = require("./OverlayTracker")
local Types = require("./Types")

local player = game:GetService("Players").LocalPlayer :: Player

local DISPLAY_ORDER = 20
local REFRESH_SEC = 1

local PART_LABELS = ClientGenomeUi.PART_LABELS
local RARITY_COLORS = ClientGenomeUi.RARITY_COLORS
local formatPiece = ClientGenomeUi.formatPiece
local describeGenome = ClientGenomeUi.describeGenome
local formatPercent = ClientGenomeUi.formatPercent
local colorText = ClientGenomeUi.colorText
local findCandidates = ClientGenomeUi.findCandidates
local setVisible = ClientGenomeUi.setVisible
local setText = ClientGenomeUi.setText
local clearGenerated = ClientGenomeUi.clearGenerated
local cloneTemplate = ClientGenomeUi.cloneTemplate

type Candidate = ClientGenomeUi.Candidate

-- the gui's shape only exists in Studio, so its instances are untyped here
type ClientRestyleManagerFields = {
	gui: any?,
	dialog: any?,
	content: any?,
	openButton: any?,
	isOverlayOpen: boolean,
	candidates: { Candidate },
	selected: Candidate?,
	selectedPart: HatchOdds.Part?,
	signature: string, -- what the screen last drew, so a refresh that changed nothing redraws nothing
	tickerDisconnect: (() -> ())?,
}

export type ClientRestyleManager = typeof(setmetatable({} :: ClientRestyleManagerFields, ClientRestyleManager))

local DISABLED_COLOR = Color3.fromRGB(110, 110, 110)

-- A pay button the player can't afford is greyed out and can't be pressed. Its normal look is read once and kept as attributes, so it
-- comes back exactly when the player can afford it again.
local function setButtonEnabled(button: any?, isEnabled: boolean)
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
	local label = button:FindFirstChild("Label")
	if label then
		label.TextTransparency = if isEnabled then 0 else 0.5
	end
end

local function buildOddsLines(odds: HatchOdds.Odds, genome: any, part: HatchOdds.Part): { string }
	local lines: { string } = {
		("<b>Restyle %s</b>: the new piece is rolled from this dragon's own mix, and the piece it has now is left out"):format(PART_LABELS[part] or part),
	}
	for _, entry in Restyle.getChances(odds, genome, part) do
		local name, rarity = formatPiece(entry.id)
		table.insert(lines, colorText(("%s %s"):format(name, formatPercent(entry.chance)), rarity))
	end
	return lines
end

-- Re-reads the dragons and the balances and redraws the lists, the odds and the price when anything changed (or when forced).
function ClientRestyleManager.refresh(self: ClientRestyleManager, isForced: boolean?)
	local content = self.content
	local odds = clientHatchOdds:getOdds()
	if not content or not odds then
		return
	end

	-- the kept dragons in the backpack; one standing in the world has to be picked up first
	local candidates: { Candidate } = {}
	for _, candidate in findCandidates() do
		if not candidate.isInWorld then
			table.insert(candidates, candidate)
		end
	end

	local previous = self.selected
	local selected: Candidate? = nil
	if previous then
		for _, candidate in candidates do
			if candidate.itemId == previous.itemId then
				selected = candidate
			end
		end
	end
	local part = if selected then self.selectedPart else nil
	local tokens = clientPlayerAttributesManager:get(PlayerAttributeKeys.RESTYLE_TOKENS) or 0
	local diamonds = clientPlayerAttributesManager:get(PlayerAttributeKeys.DIAMONDS) or 0

	local signatureParts: { string } = {}
	for _, candidate in candidates do
		table.insert(signatureParts, candidate.itemId .. ":" .. (candidate.genome.restyleCount or 0))
	end
	local signature = table.concat(signatureParts, ",")
		.. ("|%s|%s|%d|%d"):format(if selected then tostring(selected.itemId) else "-", part or "-", tokens, diamonds)
	if not isForced and signature == self.signature then
		return
	end
	self.signature = signature
	self.candidates = candidates
	self.selected = selected
	self.selectedPart = part

	local dragonList = content:FindFirstChild("DragonList")
	local dragonTemplate = if dragonList then dragonList:FindFirstChild("DragonTemplate") else nil
	if dragonList and dragonTemplate then
		clearGenerated(dragonList, dragonTemplate)
		for order, candidate in candidates do
			local button = cloneTemplate(dragonTemplate, dragonList, "Dragon" .. order)
			button.LayoutOrder = order
			local restyles = candidate.genome.restyleCount or 0
			local isSelected = selected ~= nil and selected.itemId == candidate.itemId
			local label = button:FindFirstChild("Label") or button
			label.Text = (if isSelected then "[x] " else "")
				.. describeGenome(candidate.genome)
				.. (if restyles > 0 then (" | restyled %d"):format(restyles) else "")
			setVisible(button:FindFirstChild("SelectedMark"), isSelected)
			button.Activated:Connect(function()
				self.selected = candidate
				self.selectedPart = nil
				self:refresh(true)
			end)
		end
	end

	local slotList = content:FindFirstChild("SlotList")
	local slotTemplate = if slotList then slotList:FindFirstChild("SlotTemplate") else nil
	if slotList and slotTemplate then
		clearGenerated(slotList, slotTemplate)
		if selected then
			for order, slotPart in HatchOdds.PARTS do
				local button = cloneTemplate(slotTemplate, slotList, "Slot" .. order)
				button.LayoutOrder = order
				local name, rarity = formatPiece(selected.genome.pieces[slotPart])
				local label = button:FindFirstChild("Label") or button
				label.Text = ("%s%s: %s (%s)"):format(if part == slotPart then "[x] " else "", PART_LABELS[slotPart] or slotPart, name, rarity)
				label.TextColor3 = RARITY_COLORS[rarity] or label.TextColor3
				button.Activated:Connect(function()
					self.selectedPart = slotPart
					self:refresh(true)
				end)
			end
		end
	end

	local oddsList = content:FindFirstChild("OddsList")
	local oddsTemplate = if oddsList then oddsList:FindFirstChild("OddsTemplate") else nil
	if oddsList and oddsTemplate then
		clearGenerated(oddsList, oddsTemplate)
		if selected and part then
			for order, line in buildOddsLines(odds, selected.genome, part) do
				local row = cloneTemplate(oddsTemplate, oddsList, "Odds" .. order)
				row.LayoutOrder = order
				row.RichText = true
				row.Text = line
			end
		end
	end

	if selected and part then
		local tokenCost = Restyle.getTokenCost(selected.genome)
		local diamondCost = Restyle.getDiamondCost(odds, selected.genome)
		setText(content:FindFirstChild("CostLabel"), ("Cost: %d Restyle Tokens (you have %d) or %d Diamonds (you have %d)"):format(tokenCost, tokens, diamondCost, diamonds))
		setText(content:FindFirstChild("Hint"), "Pick a piece to restyle, then pay. The dragon comes back to your backpack")
	else
		setText(content:FindFirstChild("CostLabel"), ("You have %d Restyle Tokens and %d Diamonds"):format(tokens, diamonds))
		setText(
			content:FindFirstChild("Hint"),
			if #candidates == 0 then "You have no bred dragons in your backpack" elseif selected then "Pick the piece to restyle" else "Pick a dragon to restyle"
		)
	end
	local isChosen = selected ~= nil and part ~= nil
	local tokensButton = content:FindFirstChild("TokensButton")
	local diamondsButton = content:FindFirstChild("DiamondsButton")
	setVisible(tokensButton, isChosen)
	setVisible(diamondsButton, isChosen)
	if selected and isChosen then
		setButtonEnabled(tokensButton, tokens >= Restyle.getTokenCost(selected.genome))
		setButtonEnabled(diamondsButton, diamonds >= Restyle.getDiamondCost(odds, selected.genome))
	end
end

-- sends the request; the old dragon is gone afterwards, so the selection is cleared and the next refresh shows the new one
function ClientRestyleManager.confirm(self: ClientRestyleManager, payWith: string)
	local selected, part = self.selected, self.selectedPart
	if not selected or not part then
		return
	end
	local remote = RemoteEvents:FindFirstChild("TryRestyle")
	if not remote then
		warn("ClientRestyleManager: RemoteEvents.TryRestyle is missing, so dragons can't be restyled")
		return
	end
	remote:FireServer(selected.itemId, part, payWith)
	self.selected = nil
	self.selectedPart = nil
	self:refresh(true)
end

-- ===== the overlay =====

function ClientRestyleManager.openDialog(self: ClientRestyleManager)
	local gui = self.gui
	if self.isOverlayOpen then
		return
	end
	if not gui then
		warn("ClientRestyleManager: the Restyle gui was not set up at startup, see the startup warning")
		return
	end

	self.selected = nil
	self.selectedPart = nil
	self:refresh(true)
	gui.Enabled = true
	self.isOverlayOpen = true
	overlayTracker:notifyBeginOverlay((self :: any) :: Types.Overlay)

	-- a restyle changes the dragons and the balances, so they are re-read while the screen is up
	self.tickerDisconnect = ClientTicker.every(REFRESH_SEC, function()
		self:refresh()
	end)
end

function ClientRestyleManager.toggleDialog(self: ClientRestyleManager)
	if self.isOverlayOpen then
		self:closeDialog()
	else
		self:openDialog()
	end
end

-- the HUD button lives in the main HUD ScreenGui, which ScreenGuiManager owns and wires up
function ClientRestyleManager.setHudButton(self: ClientRestyleManager, button: any)
	self.openButton = button
end

function ClientRestyleManager.closeDialogGui(self: ClientRestyleManager)
	local gui = self.gui
	if gui then
		gui.Enabled = false
	end
	local disconnect = self.tickerDisconnect
	if disconnect then
		disconnect()
		self.tickerDisconnect = nil
	end
end

function ClientRestyleManager.closeDialog(self: ClientRestyleManager)
	if not self.isOverlayOpen then
		return
	end
	self.isOverlayOpen = false
	self:closeDialogGui()
	overlayTracker:notifyEndOverlay((self :: any) :: Types.Overlay)
end

function ClientRestyleManager.getGuiRoot(self: ClientRestyleManager): any
	return self.dialog
end

function ClientRestyleManager.getHudElements(self: ClientRestyleManager): { number }
	return {}
end

function ClientRestyleManager.doesWantBlur(self: ClientRestyleManager): boolean
	return false
end

-- called by the overlay tracker when another overlay takes over
function ClientRestyleManager.notifyForceEnd(self: ClientRestyleManager)
	self.isOverlayOpen = false
	self:closeDialogGui()
end

function ClientRestyleManager.notifyClickOutside(self: ClientRestyleManager)
	self:closeDialog()
end

-- ===== setup =====

-- In the main HUD ScreenGui, a RestyleFrame holding a RestyleButton.
-- In StarterGui, a ScreenGui named Restyle with ResetOnSpawn off and Enabled off:
--   Dialog, with CloseButton and Content, which holds: Hint, CostLabel, DragonList (hidden DragonTemplate: Label, optional SelectedMark),
--     SlotList (hidden SlotTemplate: Label), OddsList (hidden OddsTemplate, a rich text label), TokensButton, DiamondsButton, CancelButton
function ClientRestyleManager.setUpGui(self: ClientRestyleManager)
	local playerGui = player:WaitForChild("PlayerGui")
	local gui: any = playerGui:WaitForChild("Restyle", 10)
	if not gui then
		warn("ClientRestyleManager: the Restyle gui is missing from PlayerGui; the Restyle screen is disabled")
		return
	end

	local dialog: any = gui:FindFirstChild("Dialog")
	local content: any = dialog and dialog:FindFirstChild("Content")
	if not dialog or not content then
		warn("ClientRestyleManager: Restyle needs Dialog/Content; the Restyle screen is disabled")
		return
	end

	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = DISPLAY_ORDER
	for _, hidden in {
		content:FindFirstChild("DragonList") and content.DragonList:FindFirstChild("DragonTemplate"),
		content:FindFirstChild("SlotList") and content.SlotList:FindFirstChild("SlotTemplate"),
		content:FindFirstChild("OddsList") and content.OddsList:FindFirstChild("OddsTemplate"),
	} do
		if hidden then
			hidden.Visible = false
		end
	end

	self.gui = gui
	self.dialog = dialog
	self.content = content

	local function connect(parent: any, name: string, callback: () -> ())
		local button = parent:FindFirstChild(name)
		if button then
			button.Activated:Connect(callback)
		else
			warn("ClientRestyleManager: missing button " .. name .. " in " .. parent.Name)
		end
	end
	connect(dialog, "CloseButton", function()
		self:closeDialog()
	end)
	connect(content, "CancelButton", function()
		self:closeDialog()
	end)
	connect(content, "TokensButton", function()
		self:confirm("tokens")
	end)
	connect(content, "DiamondsButton", function()
		self:confirm("diamonds")
	end)
end

function ClientRestyleManager.init(self: ClientRestyleManager)
	-- the Remote is made in Studio; without it the screen can't do anything
	if not RemoteEvents:FindFirstChild("TryRestyle") then
		warn("ClientRestyleManager: RemoteEvents.TryRestyle is missing; the Restyle screen is disabled")
		return
	end
	self:setUpGui()
end

function ClientRestyleManager.new(): ClientRestyleManager
	local self = setmetatable({} :: ClientRestyleManagerFields, ClientRestyleManager)
	self.gui = nil
	self.dialog = nil
	self.content = nil
	self.openButton = nil
	self.isOverlayOpen = false
	self.candidates = {}
	self.selected = nil
	self.selectedPart = nil
	self.signature = ""
	self.tickerDisconnect = nil
	return self
end

local singleton = ClientRestyleManager.new()

return singleton
