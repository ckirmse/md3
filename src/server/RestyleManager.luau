--!strict

-- Restyle: a player re-rolls one appearance piece of a kept dragon for Restyle Tokens or Diamonds (see shared/Restyle for the roll and
-- the cost). The dragon's look and item name depend on its genome, so a restyle makes a new dragon item with the new genome and removes
-- the old one; the new dragon goes to the backpack. The request comes from the client, so every argument is checked.
-- As of 2026-november-12 not built: the restricted-region rule (restricted players pay with tokens only; PolicyService is not read yet).
local RestyleManager = {}
RestyleManager.__index = RestyleManager

local Types = require("./Types")
local gameController: Types.GameController -- injected via initClass(deps); typed through Types.luau to avoid the require cycle
local itemManager: Types.ItemManager -- injected via initClass(deps); typed through Types.luau to avoid the require cycle

local Genome = require("@game/ReplicatedStorage/Shared/Genome")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local Restyle = require("@game/ReplicatedStorage/Shared/Restyle")

local CurrencyGranter = require("./CurrencyGranter")
local hatchOddsManager = require("./HatchOddsManager")
local nestManager = require("./NestManager")
local tradeManager = require("./TradeManager")

type RestyleManagerFields = {
	random: Random,
}

export type RestyleManager = typeof(setmetatable({} :: RestyleManagerFields, RestyleManager))

-- Restyles the dragon's part and returns whether it worked and a short message. payWith is "tokens" or "diamonds".
function RestyleManager.restyle(self: RestyleManager, player: Player, itemId: any, part: any, payWith: any): (boolean, string)
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData then
		return false, "Restyle is not available"
	end
	if type(itemId) ~= "number" or type(part) ~= "string" or (payWith ~= "tokens" and payWith ~= "diamonds") then
		return false, "Invalid restyle request"
	end
	local partIndex = table.find(HatchOdds.PARTS, part :: any)
	if not partIndex then
		return false, "That part can't be restyled"
	end
	local restyledPart: HatchOdds.Part = HatchOdds.PARTS[partIndex]

	if tradeManager:isPlayerTrading(player) then
		return false, "Finish or cancel your trade before restyling"
	end

	local item = itemManager:getItemById(itemId)
	if not item or item:getUserId() ~= player.UserId or item:getType() ~= "shadowDragon" then
		return false, "That is not one of your dragons"
	end
	local dragon = item :: Types.ShadowDragon
	local genome: Genome.Genome? = dragon:getGenome()
	if not genome then
		return false, "Only bred dragons can be restyled"
	end
	-- the new dragon goes to the backpack, so a dragon standing in the world has to be picked up first
	if dragon:getObj().Parent == workspace then
		return false, "Pick the dragon up before restyling it"
	end

	local newPieceId = Restyle.roll(odds, genome, restyledPart, self.random)
	if not newPieceId then
		return false, "No other piece can roll for that part"
	end

	local tokenCost = Restyle.getTokenCost(genome)
	local diamondCost = Restyle.getDiamondCost(odds, genome)
	if payWith == "tokens" then
		if not CurrencyGranter.trySpendRestyleTokens(player, tokenCost, "restyle") then
			return false, string.format("You need %d Restyle Tokens", tokenCost)
		end
	else
		if not CurrencyGranter.trySpendDiamonds(player, diamondCost, "restyle") then
			return false, string.format("You need %d Diamonds", diamondCost)
		end
	end

	-- the new dragon exists before the old one goes, and a failure gives the payment back
	local restyled = Restyle.apply(genome, restyledPart, newPieceId)
	local newDragon = nestManager:giveGenomeDragon(player, restyled)
	if not newDragon then
		if payWith == "tokens" then
			CurrencyGranter.grantRestyleTokens(player, tokenCost, "restyleRefund")
		else
			CurrencyGranter.grantDiamonds(player, diamondCost, "restyleRefund")
		end
		return false, "Could not restyle the dragon, you were not charged"
	end
	itemManager:destroyItem(dragon)

	local oldPiece = odds.catalog.byId[genome.pieces[restyledPart]]
	local newPiece = odds.catalog.byId[newPieceId]
	return true,
		string.format(
			"Restyled %s: %s to %s (now %s)",
			part,
			if oldPiece then oldPiece.id else "?",
			if newPiece then newPiece.id else "?",
			GenomeValue.getBand(odds, restyled)
		)
end

-- the client's request: checks and answers with a short message; the Restyle screen sees the new dragon through its shadow
function RestyleManager.tryRestyle(self: RestyleManager, player: Player, itemId: any, part: any, payWith: any)
	local _, message = self:restyle(player, itemId, part, payWith)
	gameController:sendSystemMessageToPlayer(player, message)
end

function RestyleManager.new(): RestyleManager
	local self = setmetatable({} :: RestyleManagerFields, RestyleManager)
	self.random = Random.new()
	return self
end

function RestyleManager.initClass(deps: any)
	gameController = deps.gameController
	itemManager = deps.itemManager
end

local singleton = RestyleManager.new()

return singleton
