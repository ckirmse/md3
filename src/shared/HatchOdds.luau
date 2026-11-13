--!strict

-- Types, structural names and validation for the Hatch Dragons config, authored in Studio as three modules under GameData/Control:
-- HatchOdds (genetics, tiers and values), HatchPieces (the piece catalogue) and HatchSystems (nests, weather traits, economy).
-- The server assembles and validates them and sends the Config to clients; every roll and value function takes the Config as a parameter.

local HatchOdds = {}

export type Element = "fire" | "water" | "nature"
export type Part = "headShape" | "faceType" | "headAttachment" | "backSpikes" | "wings" | "tailSpike" | "meshTexture"
export type PieceRarity = "common" | "uncommon" | "rare" | "legendary"
export type DragonBand = "common" | "uncommon" | "rare" | "epic" | "legendary" | "mythic"
export type MutationId = "normal" | "blazing" | "tidal" | "verdant" | "gilded" | "rainbow"
export type Weather = "rain" | "heatwave" | "bloomStorm" | "thunderstorm"

export type Piece = {
	id: string,
	part: Part,
	element: Element,
	rarity: PieceRarity,
	weight: number, -- base chance to roll, before the element share and parent buff
}

export type Tier = {
	name: string,
	segments: number,
	marketPrice: number,
	baseValue: number,
	layTimeSec: number,
	baseScale: number,
	dragonLevel: number, -- the "Dragon Level N" legacy item whose model this tier is built from
}

export type MutationDef = {
	id: MutationId,
	element: Element?, -- nil for Gilded and Rainbow, which use a share of 1
	baseWeight: number,
	valueMult: number,
	weather: Weather?, -- the weather that boosts it
}

export type Band = { name: DragonBand, minScore: number }

-- a piece as authored: its part and element are the keys it sits under in Config.pieces
export type PieceRow = { id: string, rarity: PieceRarity, weight: number }

-- the trait a weather gives waiting eggs, and the element whose 50%+ share doubles the chance (nil for none)
export type WeatherTrait = { trait: string, element: Element? }

-- Control/HatchSystems: the settings of the systems around the dragons, one section each
export type NestsConfig = {
	baseCount: number, -- the personal Nests every player starts with
	maxCount: number, -- the most personal Nests, however they were gained
	goldPrices: { number }, -- Gold for each Nest bought with Gold, in order
	parentScale: number, -- how big the parents look on a Nest, 1 is their original size
	layTimeMult: { [DragonBand]: number }, -- lay time multiplier by the parents' average band
	layBoostFloor: number, -- speed boosts can't cut the lay time below this fraction
	-- Optional: when missing, the DEFAULT_ value below is used
	eggCap: number?, -- the most eggs that wait in one Nest; a full Nest stops laying
}

export type WeatherConfig = {
	traitChancePerMinute: number?, -- per waiting egg, per minute of weather
	traitMatchMult: number?, -- the chance is multiplied by this for an egg of the matching element
	traitMatchShare: number?, -- the element share that counts as matching
	traits: { [Weather]: WeatherTrait }?, -- weather -> trait; a weather with no entry gives no trait
}

export type EconomyConfig = {
	restyleDiamondsPerToken: number?, -- Diamonds that pay for one Restyle Token (the token pack rate)
	speedUpDiamondsPerMinute: number?, -- Diamonds per minute left on a Nest's lay timer, to finish the egg now
}

-- The assembled config: Control/HatchOdds (the genetics and values), Control/HatchPieces (pieces) and Control/HatchSystems (nests, weather,
-- economy), put together by HatchOdds.assemble. weather and economy are optional sections.
export type Config = {
	version: number,
	pieces: { [Part]: { [Element]: { PieceRow } } },
	pieceParentBuff: { [PieceRarity]: number }, -- by the piece's rarity, per parent that has the piece
	pieceScore: { [PieceRarity]: number },
	dragonBands: { Band }, -- ascending; a dragon's band is the highest one at or below its score
	pureBonus: number,
	tiers: { Tier },
	visibleMin: number, -- visible scale = baseScale x (visibleMin + visibleSpan x size position up to visibleSizeCap) x giantVisible
	visibleSpan: number,
	visibleSizeCap: number,
	giantVisible: number,
	sizeParentWeight: number, -- size = (sizeParentWeight x parents' average + sizeBase) x jitter, giantChance of x giantMult, clamped
	sizeBase: number,
	sizeJitterMin: number,
	sizeJitterMax: number,
	giantChance: number,
	giantMult: number,
	sizeMin: number,
	sizeMax: number,
	mutationTotal: number, -- Normal takes what is left of this after the capped mutation weights
	mutationParentBuff: number,
	weatherMutationBuff: number,
	mutationWeightCap: number,
	mutations: { MutationDef },
	traitBonus: { [string]: number },
	tierJumpTotal: number, -- the jump weight is taken from "same tier" out of this total
	tierJumpBaseWeight: number,
	tierJumpBonus: { [DragonBand]: number },
	nests: NestsConfig,
	weather: WeatherConfig?,
	economy: EconomyConfig?,
}

-- Structural names: the code branches on these, so they stay out of the designer's table.
local ELEMENTS: { Element } = { "fire", "water", "nature" }

-- the 7 appearance slots; the mutation is the 8th, rolled separately (not lockable, not scored)
local PARTS: { Part } = {
	"headShape",
	"faceType",
	"headAttachment",
	"backSpikes",
	"wings",
	"tailSpike",
	"meshTexture",
}

local PIECE_RARITIES: { PieceRarity } = { "common", "uncommon", "rare", "legendary" }
local DRAGON_BANDS: { DragonBand } = { "common", "uncommon", "rare", "epic", "legendary", "mythic" }

local WEATHERS: { Weather } = { "rain", "heatwave", "bloomStorm", "thunderstorm" }

-- the values used while Control/HatchSystems leaves an optional field out (the spec's numbers)
HatchOdds.DEFAULT_EGG_CAP = 3
HatchOdds.DEFAULT_RESTYLE_DIAMONDS_PER_TOKEN = 5 -- placeholder; the spec sets no pack rate yet
HatchOdds.DEFAULT_SPEED_UP_DIAMONDS_PER_MINUTE = 2 -- placeholder; the spec sets no speed-up rate yet
HatchOdds.DEFAULT_WEATHER_TRAIT_CHANCE_PER_MINUTE = 0.02
HatchOdds.DEFAULT_WEATHER_TRAIT_MATCH_MULT = 2
HatchOdds.DEFAULT_WEATHER_TRAIT_MATCH_SHARE = 0.5
HatchOdds.DEFAULT_WEATHER_TRAITS = {
	rain = { trait = "soaked", element = "water" },
	heatwave = { trait = "toasty", element = "fire" },
	bloomStorm = { trait = "flowered", element = "nature" },
	thunderstorm = { trait = "charged", element = nil },
} :: { [Weather]: WeatherTrait }

HatchOdds.WEATHERS = WEATHERS
HatchOdds.ELEMENTS = ELEMENTS
HatchOdds.PARTS = PARTS
HatchOdds.PIECE_RARITIES = PIECE_RARITIES
HatchOdds.DRAGON_BANDS = DRAGON_BANDS

export type Catalog = {
	byId: { [string]: Piece },
	byPart: { [Part]: { Piece } },
}

-- a Config with its piece index, what the roll and value functions take
export type Odds = {
	config: Config,
	catalog: Catalog,
}

function HatchOdds.indexPieces(config: Config): Catalog
	local byId: { [string]: Piece } = {}
	local byPart: { [Part]: { Piece } } = {}
	for partIndex = 1, #PARTS do
		local part: Part = PARTS[partIndex]
		local list: { Piece } = {}
		byPart[part] = list
		local byElement = config.pieces[part]
		for elementIndex = 1, #ELEMENTS do
			local element: Element = ELEMENTS[elementIndex]
			local rows = if byElement then byElement[element] else nil
			if rows then
				for _, row in rows do
					local piece: Piece = { id = row.id, part = part, element = element, rarity = row.rarity, weight = row.weight }
					byId[piece.id] = piece
					table.insert(list, piece)
				end
			end
		end
	end
	return { byId = byId, byPart = byPart }
end

-- Puts the three Control modules together into one Config (the shape the roll, value and Nest code read). The result is not checked;
-- HatchOdds.validate reports what is wrong and which file it is in.
function HatchOdds.assemble(oddsData: any, piecesData: any, systemsData: any): any
	if type(oddsData) ~= "table" then
		return oddsData
	end
	local config = table.clone(oddsData)
	-- every Control module returns its fields under their names: HatchPieces has pieces, HatchSystems has nests, weather and economy
	if type(piecesData) == "table" then
		config.pieces = piecesData.pieces
	end
	if type(systemsData) == "table" then
		config.nests = systemsData.nests
		config.weather = systemsData.weather
		config.economy = systemsData.economy
	end
	return config
end

function HatchOdds.build(config: Config): Odds
	return { config = config, catalog = HatchOdds.indexPieces(config) }
end

local function isFiniteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

-- Problems with a Config as strings, empty when it is sound; the server verifier warn()s each at startup.
function HatchOdds.validate(config: any): { string }
	local problems: { string } = {}
	local function problem(message: string)
		table.insert(problems, message)
	end

	if type(config) ~= "table" then
		return { "HatchOdds: the control module did not return a table" }
	end
	if not isFiniteNonNegative(config.version) then
		problem("HatchOdds: version must be a non-negative number")
	end

	for _, field in { "pieceParentBuff", "pieceScore" } do
		local map = config[field]
		for _, rarity in PIECE_RARITIES do
			if type(map) ~= "table" or not isFiniteNonNegative(map[rarity]) then
				problem(("HatchOdds: %s.%s must be a non-negative number"):format(field, rarity))
			end
		end
	end
	for _, field in { "tierJumpBonus" } do
		local map = config[field]
		for _, band in DRAGON_BANDS do
			if type(map) ~= "table" or not isFiniteNonNegative(map[band]) then
				problem(("HatchOdds: %s.%s must be a non-negative number"):format(field, band))
			end
		end
	end
	for _, field in {
		"pureBonus", "visibleMin", "visibleSpan", "visibleSizeCap", "giantVisible", "sizeParentWeight", "sizeBase",
		"sizeJitterMin", "sizeJitterMax", "giantChance", "giantMult", "sizeMin", "sizeMax", "mutationTotal", "mutationParentBuff",
		"weatherMutationBuff", "mutationWeightCap", "tierJumpTotal", "tierJumpBaseWeight",
	} do
		if not isFiniteNonNegative(config[field]) then
			problem(("HatchOdds: %s must be a non-negative number"):format(field))
		end
	end

	local bands = config.dragonBands
	if type(bands) ~= "table" or #bands ~= #DRAGON_BANDS then
		problem("HatchOdds: dragonBands must list every band, in ascending order")
	else
		for index, band in DRAGON_BANDS do
			if bands[index].name ~= band then
				problem(("HatchOdds: dragonBands[%d] must be %s"):format(index, band))
			elseif index > 1 and not (bands[index].minScore > bands[index - 1].minScore) then
				problem(("HatchOdds: dragonBands[%d].minScore must exceed the band below it"):format(index))
			end
		end
		if bands[1].minScore ~= 0 then
			problem("HatchOdds: the lowest band must start at score 0")
		end
	end

	-- Control/HatchSystems: nests is required; weather and economy are optional, and absent fields use the defaults
	local nests = config.nests
	if type(nests) ~= "table" then
		problem("HatchSystems: nests must be a table")
	else
		for _, field in { "baseCount", "maxCount", "parentScale", "layBoostFloor" } do
			if not isFiniteNonNegative(nests[field]) then
				problem(("HatchSystems: nests.%s must be a non-negative number"):format(field))
			end
		end
		local layTimeMult = nests.layTimeMult
		for _, band in DRAGON_BANDS do
			if type(layTimeMult) ~= "table" or not isFiniteNonNegative(layTimeMult[band]) then
				problem(("HatchSystems: nests.layTimeMult.%s must be a non-negative number"):format(band))
			end
		end
		if isFiniteNonNegative(nests.parentScale) and nests.parentScale <= 0 then
			problem("HatchSystems: nests.parentScale must be above 0")
		end
		if isFiniteNonNegative(nests.baseCount) and isFiniteNonNegative(nests.maxCount) then
			if nests.baseCount < 1 or nests.baseCount ~= math.floor(nests.baseCount) then
				problem("HatchSystems: nests.baseCount must be a whole number of at least 1")
			end
			if nests.maxCount < nests.baseCount or nests.maxCount ~= math.floor(nests.maxCount) then
				problem("HatchSystems: nests.maxCount must be a whole number, not below nests.baseCount")
			end
			if type(nests.goldPrices) ~= "table" then
				problem("HatchSystems: nests.goldPrices must be a list of Gold prices")
			else
				for index, price in nests.goldPrices do
					if not isFiniteNonNegative(price) then
						problem(("HatchSystems: nests.goldPrices[%d] must be a non-negative number"):format(index))
					end
				end
				if nests.baseCount + #nests.goldPrices > nests.maxCount then
					problem("HatchSystems: nests.baseCount plus the Gold Nests is more than nests.maxCount")
				end
			end
		end
		if nests.eggCap ~= nil and (type(nests.eggCap) ~= "number" or nests.eggCap < 1 or nests.eggCap ~= math.floor(nests.eggCap)) then
			problem("HatchSystems: nests.eggCap must be a whole number of at least 1")
		end
	end

	local weather = config.weather
	if weather ~= nil then
		if type(weather) ~= "table" then
			problem("HatchSystems: weather must be a table")
		else
			for _, field in { "traitChancePerMinute", "traitMatchShare" } do
				local value = weather[field]
				if value ~= nil and (not isFiniteNonNegative(value) or value > 1) then
					problem(("HatchSystems: weather.%s must be a number from 0 to 1"):format(field))
				end
			end
			if weather.traitMatchMult ~= nil and not isFiniteNonNegative(weather.traitMatchMult) then
				problem("HatchSystems: weather.traitMatchMult must be a non-negative number")
			end
			if weather.traits ~= nil then
				if type(weather.traits) ~= "table" then
					problem("HatchSystems: weather.traits must be a table of weathers")
				else
					for weatherName, def in weather.traits do
						if not table.find(WEATHERS, weatherName) then
							problem(("HatchSystems: weather.traits has an unknown weather %s"):format(tostring(weatherName)))
						elseif type(def) ~= "table" or type(def.trait) ~= "string" or def.trait == "" then
							problem(("HatchSystems: weather.traits.%s needs a trait name"):format(weatherName))
						elseif def.element ~= nil and not table.find(ELEMENTS, def.element) then
							problem(("HatchSystems: weather.traits.%s has an unknown element %s"):format(weatherName, tostring(def.element)))
						end
					end
				end
			end
		end
	end

	local economy = config.economy
	if economy ~= nil then
		if type(economy) ~= "table" then
			problem("HatchSystems: economy must be a table")
		else
			local rate = economy.restyleDiamondsPerToken
			if rate ~= nil and (type(rate) ~= "number" or rate < 1 or rate ~= math.floor(rate)) then
				problem("HatchSystems: economy.restyleDiamondsPerToken must be a whole number of at least 1")
			end
			local speedUpRate = economy.speedUpDiamondsPerMinute
			if speedUpRate ~= nil and (not isFiniteNonNegative(speedUpRate) or speedUpRate <= 0) then
				problem("HatchSystems: economy.speedUpDiamondsPerMinute must be a number above 0")
			end
		end
	end

	local tiers = config.tiers
	if type(tiers) ~= "table" or #tiers == 0 then
		problem("HatchOdds: tiers must list at least one tier")
	else
		for index, tier in tiers do
			for _, field in { "segments", "marketPrice", "baseValue", "layTimeSec", "baseScale", "dragonLevel" } do
				if not isFiniteNonNegative(tier[field]) then
					problem(("HatchOdds: tiers[%d].%s must be a non-negative number"):format(index, field))
				end
			end
		end
	end

	if type(config.mutations) ~= "table" then
		problem("HatchOdds: mutations must be a list")
	else
		local capped = 0
		for _, mutation in config.mutations do
			if mutation.id == "normal" then
				problem("HatchOdds: mutations must not list normal, it takes what is left")
			end
			if not isFiniteNonNegative(mutation.baseWeight) or not isFiniteNonNegative(mutation.valueMult) then
				problem(("HatchOdds: mutation %s needs a baseWeight and valueMult"):format(tostring(mutation.id)))
			end
			capped += config.mutationWeightCap or 0
		end
		-- Normal is mutationTotal minus the rest, so the capped weights must leave it positive
		if isFiniteNonNegative(config.mutationTotal) and capped >= config.mutationTotal then
			problem("HatchOdds: the mutation weight caps add up to mutationTotal or more, so Normal could go negative")
		end
	end

	if isFiniteNonNegative(config.tierJumpTotal) and isFiniteNonNegative(config.tierJumpBaseWeight) and type(config.tierJumpBonus) == "table" then
		for _, band in DRAGON_BANDS do
			local bonus = config.tierJumpBonus[band]
			if isFiniteNonNegative(bonus) and config.tierJumpBaseWeight + bonus > config.tierJumpTotal then
				problem(("HatchOdds: the tier jump weight for %s exceeds tierJumpTotal"):format(band))
			end
		end
	end

	if type(config.pieces) ~= "table" then
		problem("HatchPieces: pieces must be a table of parts")
	else
		local seen: { [string]: boolean } = {}
		for part, byElement in config.pieces do
			if not table.find(PARTS, part) or type(byElement) ~= "table" then
				problem(("HatchPieces: pieces has an unknown part %s"):format(tostring(part)))
				continue
			end
			for element, rows in byElement do
				if not table.find(ELEMENTS, element) or type(rows) ~= "table" then
					problem(("HatchPieces: pieces.%s has an unknown element %s"):format(part, tostring(element)))
					continue
				end
				for _, row in rows do
					if type(row.id) ~= "string" or seen[row.id] then
						problem(("HatchPieces: piece id %s under %s/%s is missing or duplicated"):format(tostring(row.id), part, element))
					else
						seen[row.id] = true
					end
					if not isFiniteNonNegative(row.weight) then
						problem(("HatchPieces: piece %s needs a weight of 0 or more"):format(tostring(row.id)))
					end
					if not table.find(PIECE_RARITIES, row.rarity) then
						problem(("HatchPieces: piece %s has an unknown rarity %s"):format(tostring(row.id), tostring(row.rarity)))
					end
				end
			end
		end
		-- a baby can hold any element's share, so every part needs a piece for every element
		for _, part in PARTS do
			for _, element in ELEMENTS do
				local byElement = config.pieces[part]
				local rows = type(byElement) == "table" and byElement[element]
				if type(rows) ~= "table" or #rows == 0 then
					problem(("HatchPieces: no %s piece for part %s"):format(element, part))
				end
			end
		end
	end

	return problems
end

return HatchOdds
