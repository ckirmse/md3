--!strict

-- Personal Nests for Hatch Dragons. A Nest holds two same-tier genome dragons and lays an egg on a timer (NestMath), up to 3 waiting.
-- The Nests are saved in PlayerData as plain genome records, so a parent leaves the inventory while it sits in a Nest.
-- Hatching reveals an egg's genome (rolled when it was laid); the player then sells it for Gold, which never creates a dragon,
-- or keeps it, which creates a ShadowDragon carrying the genome. Eggs laid while offline are caught up when the player joins.
-- The client talks through TryNestSet, TryNestClear, TryNestHatch and TryNestDecide (created in Studio) and hears NotifyNests (the whole state,
-- pushed after every change and every laid egg) and NotifyNestReveal. Eggs are named by their genome uuid, so a stale click can't hit another egg.
-- The Nest count is the config's nestBaseCount plus the Nests bought with Gold (nestGoldPrices, in order) and the bonus slots from other
-- sources, up to nestMaxCount; a Nest that holds dragons is never hidden if the count later drops.
-- As of 2026-november-11 not built: weather VFX on eggs, Incubators,
-- the Gene Book and gamepass Nests (the bonus slot is their hook).
local NestManager = {}
NestManager.__index = NestManager

local httpService = game:GetService("HttpService")
local players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- the RemoteEvents children only exist in Studio, so they are untyped here
local RemoteEvents: any = ReplicatedStorage:WaitForChild("RemoteEvents")

local Types = require("./Types")
local gameController: Types.GameController -- injected via initClass(deps); typed through Types.luau to avoid the require cycle
local itemManager: Types.ItemManager -- injected via initClass(deps); typed through Types.luau to avoid the require cycle

local GenomeItemName = require("@game/ReplicatedStorage/Shared/GenomeItemName")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local HatchWeather = require("@game/ReplicatedStorage/Shared/HatchWeather")
local NestMath = require("@game/ReplicatedStorage/Shared/NestMath")

local CurrencyGranter = require("./CurrencyGranter")
local hatchOddsManager = require("./HatchOddsManager")
local nestWorldManager = require("./NestWorldManager")
local plotsManager = require("./PlotsManager")
local weatherEventManager = require("./WeatherEventManager")

local TICK_SEC = 1

type NestManagerFields = {
	random: Random,
	lastWeather: HatchOdds.Weather?, -- the weather the players were last sent
}

export type NestManager = typeof(setmetatable({} :: NestManagerFields, NestManager))

-- the Nest slots the player has: the base count plus the Gold and bonus Nests, never below the highest Nest that holds dragons
local function getNestCount(playerData: any): number
	local odds = hatchOddsManager:getOdds()
	if not odds then
		return 0
	end
	local config = odds.config
	local count = math.min(config.nestBaseCount + playerData:getNestGoldPurchases() + playerData:getNestBonusSlots(), config.nestMaxCount)
	for key in playerData:getNests() do
		count = math.max(count, tonumber(key) or 0)
	end
	return count
end

local function isNestIndex(playerData: any, nestIndex: any): boolean
	return type(nestIndex) == "number" and nestIndex == math.floor(nestIndex) and nestIndex >= 1 and nestIndex <= getNestCount(playerData)
end

-- the Gold price of the next Nest the player can buy, nil when there is none left (the maximum, or no price set for it)
local function getNextNestPrice(odds: HatchOdds.Odds, playerData: any): number?
	if getNestCount(playerData) >= odds.config.nestMaxCount then
		return nil
	end
	return odds.config.nestGoldPrices[playerData:getNestGoldPurchases() + 1]
end

local function makeUuid(): string
	return httpService:GenerateGUID(false)
end

-- the Nest in a slot, nil when the slot is empty; the slot index is the key as a string so the save has no holes
local function getNest(playerData: any, nestIndex: number): NestMath.Nest?
	return playerData:getNests()[tostring(nestIndex)]
end

-- the index of the egg a client named: an egg's genome uuid, or a plain index for the dev tools; nil when there is no such egg
local function findEggIndex(nest: NestMath.Nest, eggRef: any): number?
	if type(eggRef) == "number" then
		return if nest.eggs[eggRef] then eggRef else nil
	end
	if type(eggRef) == "string" then
		for index, egg in nest.eggs do
			if egg.genome.uuid == eggRef then
				return index
			end
		end
	end
	return nil
end

-- the Remote is made in Studio; until it exists nothing is sent
local function fireRemote(remoteName: string, player: Player, ...: any)
	local remote = RemoteEvents:FindFirstChild(remoteName)
	if remote then
		remote:FireClient(player, ...)
	end
end

-- an egg that will hatch a higher tier than its parents glows (the spec's tier jump)
local function isTierJump(nest: NestMath.Nest, egg: NestMath.Egg): boolean
	return egg.genome.tier > nest.parentA.tier
end

-- puts a dragon with this genome in the player's backpack; the genome goes on first, since identical dragons would stack there
function NestManager.giveGenomeDragon(self: NestManager, player: Player, genome: any): Types.ShadowDragon?
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData then
		return nil
	end

	local itemName = GenomeItemName.get(odds, genome)
	if not itemName then
		return nil
	end
	local item = itemManager:createItem(itemName, player.UserId)
	if not item then
		warn("NestManager: could not create", itemName)
		return nil
	end
	if item:getType() ~= "shadowDragon" then
		warn("NestManager: not a dragon item", itemName)
		itemManager:destroyItem(item)
		return nil
	end

	local dragon = item :: Types.ShadowDragon
	dragon:setGenome(genome)
	dragon:putInBackpack()
	playerData:notifyItemReceived(dragon)
	return dragon
end

-- the whole state the client draws: one entry per Nest slot, the parents' genomes, the next egg's server time and the waiting eggs
-- the Hatch weather now running in the world, nil when none counts
local function getCurrentWeather(): HatchOdds.Weather?
	local active = weatherEventManager:getActivePayload()
	return HatchWeather.fromGameWeather(if active then active.weather else nil)
end

function NestManager.getClientData(self: NestManager, player: Player, playerData: any): any?
	local odds = hatchOddsManager:getOdds()
	if not odds then
		return nil
	end

	local nests = {}
	for nestIndex = 1, getNestCount(playerData) do
		local nest = getNest(playerData, nestIndex)
		if not nest then
			table.insert(nests, { isEmpty = true })
			continue
		end
		local eggs = {}
		for _, egg in nest.eggs do
			table.insert(eggs, { id = egg.genome.uuid, laidAt = egg.laidAt, isTierJump = isTierJump(nest, egg), traits = egg.genome.traits })
		end
		table.insert(nests, {
			isEmpty = false,
			parentA = nest.parentA,
			parentB = nest.parentB,
			nextLayAt = nest.nextLayAt,
			layTimeSec = NestMath.getLayTimeSec(odds, nest),
			eggs = eggs,
		})
	end

	return {
		weather = getCurrentWeather(),
		nextNestPrice = getNextNestPrice(odds, playerData),
		plotIndex = plotsManager:getPlotIndexByUserId(player.UserId),
		nests = nests,
	}
end

function NestManager.pushNests(self: NestManager, player: Player)
	local playerData = gameController:getPlayerData(player)
	if playerData then
		-- the Nest models on the plot follow the count; this does nothing when they are already up to date
		nestWorldManager:syncNestModels(player, getNestCount(playerData))
	end
	local data = if playerData then self:getClientData(player, playerData) else nil
	if data then
		fireRemote("NotifyNests", player, data)
	end
end

-- Moves two of the player's genome dragons into an empty Nest.
-- Returns whether it worked and a short message; the arguments come from the client, so everything is checked.
function NestManager.setNest(self: NestManager, player: Player, nestIndex: any, itemIdA: any, itemIdB: any): (boolean, string)
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData then
		return false, "Nests are not available"
	end
	if not isNestIndex(playerData, nestIndex) then
		return false, "That Nest does not exist"
	end
	if getNest(playerData, nestIndex) then
		return false, "That Nest already has dragons in it"
	end
	if type(itemIdA) ~= "number" or type(itemIdB) ~= "number" or itemIdA == itemIdB then
		return false, "Pick two different dragons"
	end

	local dragons: { Types.ShadowDragon } = {}
	for _, itemId in { itemIdA, itemIdB } do
		local item = itemManager:getItemById(itemId)
		if not item or item:getUserId() ~= player.UserId or item:getType() ~= "shadowDragon" then
			return false, "That is not one of your dragons"
		end
		local dragon = item :: Types.ShadowDragon
		if not dragon:getGenome() then
			return false, "Only bred dragons can go in a Nest"
		end
		table.insert(dragons, dragon)
	end

	-- both dragons were checked above to have a genome
	local parentA, parentB = dragons[1]:getGenome() :: any, dragons[2]:getGenome() :: any
	local nest = NestMath.create(odds, parentA, parentB, 1, workspace:GetServerTimeNow())
	if not nest then
		return false, "Those dragons can't share a Nest (they need the same tier)"
	end

	for _, dragon in dragons do
		itemManager:destroyItem(dragon)
	end
	playerData:getNests()[tostring(nestIndex)] = nest
	return true, "The Nest is ready"
end

-- Gives the two parents back to the player and empties the Nest. A Nest with eggs waiting stays until they are hatched.
function NestManager.clearNest(self: NestManager, player: Player, nestIndex: any): (boolean, string)
	local playerData = gameController:getPlayerData(player)
	if not playerData or not isNestIndex(playerData, nestIndex) then
		return false, "That Nest does not exist"
	end
	local nest = getNest(playerData, nestIndex)
	if not nest then
		return false, "That Nest is empty"
	end
	if #nest.eggs > 0 then
		return false, "Hatch the waiting eggs first"
	end

	local dragonA = self:giveGenomeDragon(player, nest.parentA)
	local dragonB = self:giveGenomeDragon(player, nest.parentB)
	if not dragonA or not dragonB then
		-- never lose a parent: if one could not be recreated the Nest stays as it was
		for _, dragon in { dragonA, dragonB } do
			if dragon then
				itemManager:destroyItem(dragon)
			end
		end
		return false, "Could not return the dragons"
	end
	playerData:getNests()[tostring(nestIndex)] = nil
	return true, "The dragons are back in your backpack"
end

-- Everything the reveal screen shows about a waiting egg; nothing changes, since hatching rolls nothing.
function NestManager.getReveal(self: NestManager, player: Player, nestIndex: any, eggRef: any): any?
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData or not isNestIndex(playerData, nestIndex) then
		return nil
	end
	local nest = getNest(playerData, nestIndex)
	local eggIndex = if nest then findEggIndex(nest, eggRef) else nil
	if not nest or not eggIndex then
		return nil
	end

	local egg = nest.eggs[eggIndex]
	local genome = egg.genome
	return {
		nestIndex = nestIndex,
		eggId = genome.uuid,
		genome = genome,
		band = GenomeValue.getBand(odds, genome),
		score = GenomeValue.getScore(odds, genome),
		value = math.floor(GenomeValue.getValue(odds, genome)),
		isTierJump = isTierJump(nest, egg),
	}
end

-- Sells the egg for its value in Gold (no dragon is created) or keeps it as a dragon; both end with the egg gone from the Nest.
function NestManager.hatchEgg(self: NestManager, player: Player, nestIndex: any, eggRef: any, decision: any): (boolean, string)
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData then
		return false, "Nests are not available"
	end
	if not isNestIndex(playerData, nestIndex) then
		return false, "That egg does not exist"
	end
	if decision ~= "sell" and decision ~= "keep" then
		return false, "Sell or keep the egg"
	end
	local nest = getNest(playerData, nestIndex)
	local eggIndex = if nest then findEggIndex(nest, eggRef) else nil
	if not nest or not eggIndex then
		return false, "That egg does not exist"
	end

	local genome = nest.eggs[eggIndex].genome
	if decision == "keep" then
		-- the egg is removed only once the dragon exists
		if not self:giveGenomeDragon(player, genome) then
			return false, "Could not create the dragon"
		end
		NestMath.takeEgg(odds, nest, eggIndex, workspace:GetServerTimeNow())
		return true, "Kept a new dragon"
	end

	local value = math.floor(GenomeValue.getValue(odds, genome))
	NestMath.takeEgg(odds, nest, eggIndex, workspace:GetServerTimeNow())
	CurrencyGranter.grantCoins(player, value, "sellHatchling")
	return true, string.format("Sold the dragon for %d coins", value)
end

-- the client's four requests: each checks, answers with a short message and sends the new state
function NestManager.trySet(self: NestManager, player: Player, nestIndex: any, itemIdA: any, itemIdB: any)
	local _, message = self:setNest(player, nestIndex, itemIdA, itemIdB)
	gameController:sendSystemMessageToPlayer(player, message)
	self:pushNests(player)
end

function NestManager.tryClear(self: NestManager, player: Player, nestIndex: any)
	local _, message = self:clearNest(player, nestIndex)
	gameController:sendSystemMessageToPlayer(player, message)
	self:pushNests(player)
end

-- asks to see an egg; the reveal goes back through NotifyNestReveal
function NestManager.tryHatch(self: NestManager, player: Player, nestIndex: any, eggRef: any)
	local reveal = self:getReveal(player, nestIndex, eggRef)
	if reveal then
		fireRemote("NotifyNestReveal", player, reveal)
	else
		gameController:sendSystemMessageToPlayer(player, "That egg does not exist")
		self:pushNests(player)
	end
end

function NestManager.tryDecide(self: NestManager, player: Player, nestIndex: any, eggRef: any, decision: any)
	local _, message = self:hatchEgg(player, nestIndex, eggRef, decision)
	gameController:sendSystemMessageToPlayer(player, message)
	self:pushNests(player)
end

-- Lays the eggs that are due in every Nest and, while it is live, lets the running weather give the waiting eggs traits; returns how many
-- things changed. A catch-up (joining) rolls with no weather, as the spec says offline eggs gain nothing. elapsedSec is the weather time
-- the trait roll covers, one tick unless a dev skip says otherwise.
function NestManager.tickPlayer(self: NestManager, player: Player, playerData: any, isLive: boolean, elapsedSec: number?): number
	local odds = hatchOddsManager:getOdds()
	if not odds then
		return 0
	end

	local weather = if isLive then getCurrentWeather() else nil
	local params: NestMath.AdvanceParams = {
		now = workspace:GetServerTimeNow(),
		rng = self.random,
		makeUuid = makeUuid,
		weather = weather,
	}
	local changedCount = 0
	for _, nest in playerData:getNests() do
		changedCount += #NestMath.advance(odds, nest, params)
		changedCount += NestMath.growTraits(odds, nest, weather, elapsedSec or TICK_SEC, self.random)
	end
	return changedCount
end

-- dev only: moves every timer back so the Nests lay as if that many seconds had passed
function NestManager.devSkipTime(self: NestManager, player: Player, seconds: number)
	local playerData = gameController:getPlayerData(player)
	if not playerData then
		return
	end
	for _, nest in playerData:getNests() do
		if nest.nextLayAt then
			nest.nextLayAt -= seconds
		end
	end
	self:tickPlayer(player, playerData, true, seconds)
	self:pushNests(player)
end

-- catches the Nests up for the time the player was away, then tells the client
function NestManager.notifyAddPlayer(self: NestManager, player: Player, playerData: any)
	self:tickPlayer(player, playerData, false)
	self:pushNests(player)
end

function NestManager.getNestCount(self: NestManager, playerData: any): number
	return getNestCount(playerData)
end

-- Buys the next Nest with Gold at the config's price. Returns whether it worked and a short message.
function NestManager.buyNest(self: NestManager, player: Player): (boolean, string)
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData then
		return false, "Nests are not available"
	end

	local price = getNextNestPrice(odds, playerData)
	if not price then
		return false, "There is no Nest left to buy"
	end
	-- a price of 0 is a free Nest
	if price > 0 and not CurrencyGranter.trySpendCoins(player, price, "buyNest") then
		return false, string.format("You need %d coins for the next Nest", price)
	end
	playerData:addNestGoldPurchase()
	return true, "You bought a new Nest"
end

function NestManager.tryBuy(self: NestManager, player: Player)
	local _, message = self:buyNest(player)
	gameController:sendSystemMessageToPlayer(player, message)
	self:pushNests(player)
end

-- dev only: one more Nest slot, as if gained from a Gene Book milestone or a gamepass, up to the maximum
function NestManager.devAddSlot(self: NestManager, player: Player)
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData or getNestCount(playerData) >= odds.config.nestMaxCount then
		return
	end
	playerData:addNestBonusSlot()
	self:pushNests(player)
end

function NestManager.init(self: NestManager)
	task.spawn(function()
		while true do
			task.wait(TICK_SEC)
			-- everyone is told when the weather changes, so the pairing odds show its mutation boost
			local weather = getCurrentWeather()
			local isWeatherChanged = weather ~= self.lastWeather
			self.lastWeather = weather
			for _, player in players:GetPlayers() do
				local playerData = gameController:getPlayerData(player)
				if playerData and (self:tickPlayer(player, playerData, true) > 0 or isWeatherChanged) then
					self:pushNests(player)
				end
			end
		end
	end)
end

function NestManager.new(): NestManager
	local self = setmetatable({} :: NestManagerFields, NestManager)
	self.random = Random.new()
	self.lastWeather = nil
	return self
end

function NestManager.initClass(deps: any)
	gameController = deps.gameController
	itemManager = deps.itemManager
end

local singleton = NestManager.new()

return singleton
