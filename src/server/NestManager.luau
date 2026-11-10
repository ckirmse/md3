--!strict

-- Personal Nests for Hatch Dragons. A Nest holds two same-tier genome dragons and lays an egg on a timer (NestMath), up to 3 waiting.
-- The Nests are saved in PlayerData as plain genome records, so a parent leaves the inventory while it sits in a Nest.
-- Hatching reveals an egg's genome (rolled when it was laid); the player then sells it for Gold, which never creates a dragon,
-- or keeps it, which creates a ShadowDragon carrying the genome. Eggs laid while offline are caught up when the player joins.
-- As of 2026-november-10 not built: weather boosts and traits on waiting eggs, the first-Rare-piece and Gene Book lock unlocks, Incubators,
-- more than 2 Nests, the grow-up wait before kept dragons can breed, and the remotes and UI (the dev tools drive it for now).
local NestManager = {}
NestManager.__index = NestManager

local httpService = game:GetService("HttpService")
local players = game:GetService("Players")

local Types = require("./Types")
local gameController: Types.GameController -- injected via initClass(deps); typed through Types.luau to avoid the require cycle
local itemManager: Types.ItemManager -- injected via initClass(deps); typed through Types.luau to avoid the require cycle

local GenomeItemName = require("@game/ReplicatedStorage/Shared/GenomeItemName")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local NestMath = require("@game/ReplicatedStorage/Shared/NestMath")

local CurrencyGranter = require("./CurrencyGranter")
local hatchOddsManager = require("./HatchOddsManager")

-- the spec's personal Nests start at 2 and grow to 6 with Gold, a Gene Book milestone and a gamepass
local NEST_COUNT = 2
local TICK_SEC = 1

type NestManagerFields = {
	random: Random,
}

export type NestManager = typeof(setmetatable({} :: NestManagerFields, NestManager))

local function isNestIndex(nestIndex: any): boolean
	return type(nestIndex) == "number" and nestIndex == math.floor(nestIndex) and nestIndex >= 1 and nestIndex <= NEST_COUNT
end

local function makeUuid(): string
	return httpService:GenerateGUID(false)
end

-- the Nest in a slot, nil when the slot is empty; the slot index is the key as a string so the save has no holes
local function getNest(playerData: any, nestIndex: number): NestMath.Nest?
	return playerData:getNests()[tostring(nestIndex)]
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

-- Moves two of the player's genome dragons into an empty Nest. locks maps a part to a parent's piece id, up to the config's maximum.
-- Returns whether it worked and a short message; the arguments come from the client, so everything is checked.
function NestManager.setNest(self: NestManager, player: Player, nestIndex: any, itemIdA: any, itemIdB: any, locks: any): (boolean, string)
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData then
		return false, "Nests are not available"
	end
	if not isNestIndex(nestIndex) then
		return false, "That Nest does not exist"
	end
	if getNest(playerData, nestIndex) then
		return false, "That Nest already has dragons in it"
	end
	if type(itemIdA) ~= "number" or type(itemIdB) ~= "number" or itemIdA == itemIdB then
		return false, "Pick two different dragons"
	end

	local checkedLocks: { [HatchOdds.Part]: string } = {}
	if locks ~= nil then
		if type(locks) ~= "table" then
			return false, "Invalid locks"
		end
		for partIndex = 1, #HatchOdds.PARTS do
			local part: HatchOdds.Part = HatchOdds.PARTS[partIndex]
			local pieceId = locks[part]
			if pieceId ~= nil then
				if type(pieceId) ~= "string" then
					return false, "Invalid locks"
				end
				checkedLocks[part] = pieceId
			end
		end
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
	local nest = NestMath.create(odds, parentA, parentB, checkedLocks, 1, workspace:GetServerTimeNow())
	if not nest then
		return false, "Those dragons can't share a Nest (they need the same tier, and each lock must be a piece one of them has)"
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
	if not playerData or not isNestIndex(nestIndex) then
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

-- the genome of a waiting egg, for the reveal; nothing changes, since hatching rolls nothing
function NestManager.revealEgg(self: NestManager, player: Player, nestIndex: any, eggIndex: any): any?
	local playerData = gameController:getPlayerData(player)
	if not playerData or not isNestIndex(nestIndex) or type(eggIndex) ~= "number" then
		return nil
	end
	local nest = getNest(playerData, nestIndex)
	local egg = if nest then nest.eggs[eggIndex] else nil
	return if egg then egg.genome else nil
end

-- Sells the egg for its value in Gold (no dragon is created) or keeps it as a dragon; both end with the egg gone from the Nest.
function NestManager.hatchEgg(self: NestManager, player: Player, nestIndex: any, eggIndex: any, decision: any): (boolean, string)
	local odds = hatchOddsManager:getOdds()
	local playerData = gameController:getPlayerData(player)
	if not odds or not playerData then
		return false, "Nests are not available"
	end
	if not isNestIndex(nestIndex) or type(eggIndex) ~= "number" or eggIndex ~= math.floor(eggIndex) then
		return false, "That egg does not exist"
	end
	if decision ~= "sell" and decision ~= "keep" then
		return false, "Sell or keep the egg"
	end
	local nest = getNest(playerData, nestIndex)
	local egg = if nest then nest.eggs[eggIndex] else nil
	if not nest or not egg then
		return false, "That egg does not exist"
	end

	local genome = egg.genome
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

-- lays the eggs that are due in every Nest of the player; the Lock Tokens of a locked egg come out of the player's balance
function NestManager.tickPlayer(self: NestManager, player: Player, playerData: any)
	local odds = hatchOddsManager:getOdds()
	if not odds then
		return
	end

	local params: NestMath.AdvanceParams = {
		now = workspace:GetServerTimeNow(),
		rng = self.random,
		makeUuid = makeUuid,
		weather = nil,
		spendTokens = function(cost: number): boolean
			return CurrencyGranter.trySpendLockTokens(player, cost, "nestLock")
		end,
	}
	for _, nest in playerData:getNests() do
		NestMath.advance(odds, nest, params)
	end
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
	self:tickPlayer(player, playerData)
end

-- catches the Nests up for the time the player was away
function NestManager.notifyAddPlayer(self: NestManager, player: Player, playerData: any)
	self:tickPlayer(player, playerData)
end

function NestManager.getNestCount(self: NestManager): number
	return NEST_COUNT
end

function NestManager.init(self: NestManager)
	task.spawn(function()
		while true do
			task.wait(TICK_SEC)
			for _, player in players:GetPlayers() do
				local playerData = gameController:getPlayerData(player)
				if playerData then
					self:tickPlayer(player, playerData)
				end
			end
		end
	end)
end

function NestManager.new(): NestManager
	local self = setmetatable({} :: NestManagerFields, NestManager)
	self.random = Random.new()
	return self
end

function NestManager.initClass(deps: any)
	gameController = deps.gameController
	itemManager = deps.itemManager
end

local singleton = NestManager.new()

return singleton
