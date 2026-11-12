--!strict

-- Types, structural names and validation for the Hatch Dragons odds config, authored in Studio as GameData/Control/HatchOdds.
-- The server validates it and sends it to clients; every roll and value function takes the Config as a parameter.

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
	layTimeMult: { [DragonBand]: number }, -- by the parents' average band
	layBoostFloor: number,
	nestBaseCount: number, -- the personal Nests every player starts with
	nestMaxCount: number, -- the most personal Nests, however they were gained
	nestGoldPrices: { number }, -- Gold for each Nest bought with Gold, in order
	nestParentScale: number, -- how big the parents look on a Nest, 1 is their original size
	-- Optional: when a field is missing the DEFAULT_ value below is used, so these can be added to the Studio table whenever
	eggCap: number?, -- the most eggs that wait in one Nest; a full Nest stops laying
	weatherTraitChancePerMinute: number?, -- per waiting egg, per minute of weather
	weatherTraitMatchMult: number?, -- the chance is multiplied by this for an egg of the matching element
	weatherTraitMatchShare: number?, -- the element share that counts as matching
	weatherTraits: { [Weather]: WeatherTrait }?, -- weather -> trait; a weather with no entry gives no trait
	restyleDiamondsPerToken: number?, -- Diamonds that pay for one Restyle Token (the token pack rate)
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

-- the values used while the Studio table leaves an optional Config field out (the spec's numbers)
HatchOdds.DEFAULT_EGG_CAP = 3
HatchOdds.DEFAULT_RESTYLE_DIAMONDS_PER_TOKEN = 5 -- placeholder; the spec sets no pack rate yet
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
	for _, field in { "tierJumpBonus", "layTimeMult" } do
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
		"weatherMutationBuff", "mutationWeightCap", "tierJumpTotal", "tierJumpBaseWeight", "layBoostFloor", "nestBaseCount", "nestMaxCount", "nestParentScale",
	} do
		if not isFiniteNonNegative(config[field]) then
			problem(("HatchOdds: %s must be a non-negative number"):format(field))
		end
	end

	if isFiniteNonNegative(config.nestParentScale) and config.nestParentScale <= 0 then
		problem("HatchOdds: nestParentScale must be above 0")
	end

	if isFiniteNonNegative(config.nestBaseCount) and isFiniteNonNegative(config.nestMaxCount) then
		if config.nestBaseCount < 1 or config.nestBaseCount ~= math.floor(config.nestBaseCount) then
			problem("HatchOdds: nestBaseCount must be a whole number of at least 1")
		end
		if config.nestMaxCount < config.nestBaseCount or config.nestMaxCount ~= math.floor(config.nestMaxCount) then
			problem("HatchOdds: nestMaxCount must be a whole number, not below nestBaseCount")
		end
		if type(config.nestGoldPrices) ~= "table" then
			problem("HatchOdds: nestGoldPrices must be a list of Gold prices")
		else
			for index, price in config.nestGoldPrices do
				if not isFiniteNonNegative(price) then
					problem(("HatchOdds: nestGoldPrices[%d] must be a non-negative number"):format(index))
				end
			end
			if config.nestBaseCount + #config.nestGoldPrices > config.nestMaxCount then
				problem("HatchOdds: nestBaseCount plus the Gold Nests is more than nestMaxCount")
			end
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

	-- optional fields: absent is fine, present must make sense
	if config.eggCap ~= nil and (type(config.eggCap) ~= "number" or config.eggCap < 1 or config.eggCap ~= math.floor(config.eggCap)) then
		problem("HatchOdds: eggCap must be a whole number of at least 1")
	end
	for _, field in { "weatherTraitChancePerMinute", "weatherTraitMatchShare" } do
		local value = config[field]
		if value ~= nil and (not isFiniteNonNegative(value) or value > 1) then
			problem(("HatchOdds: %s must be a number from 0 to 1"):format(field))
		end
	end
	if config.restyleDiamondsPerToken ~= nil
		and (type(config.restyleDiamondsPerToken) ~= "number" or config.restyleDiamondsPerToken < 1 or config.restyleDiamondsPerToken ~= math.floor(config.restyleDiamondsPerToken)) then
		problem("HatchOdds: restyleDiamondsPerToken must be a whole number of at least 1")
	end
	if config.weatherTraitMatchMult ~= nil and not isFiniteNonNegative(config.weatherTraitMatchMult) then
		problem("HatchOdds: weatherTraitMatchMult must be a non-negative number")
	end
	if config.weatherTraits ~= nil then
		if type(config.weatherTraits) ~= "table" then
			problem("HatchOdds: weatherTraits must be a table of weathers")
		else
			for weather, def in config.weatherTraits do
				if not table.find(WEATHERS, weather) then
					problem(("HatchOdds: weatherTraits has an unknown weather %s"):format(tostring(weather)))
				elseif type(def) ~= "table" or type(def.trait) ~= "string" or def.trait == "" then
					problem(("HatchOdds: weatherTraits.%s needs a trait name"):format(weather))
				elseif def.element ~= nil and not table.find(ELEMENTS, def.element) then
					problem(("HatchOdds: weatherTraits.%s has an unknown element %s"):format(weather, tostring(def.element)))
				end
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
		problem("HatchOdds: pieces must be a table of parts")
	else
		local seen: { [string]: boolean } = {}
		for part, byElement in config.pieces do
			if not table.find(PARTS, part) or type(byElement) ~= "table" then
				problem(("HatchOdds: pieces has an unknown part %s"):format(tostring(part)))
				continue
			end
			for element, rows in byElement do
				if not table.find(ELEMENTS, element) or type(rows) ~= "table" then
					problem(("HatchOdds: pieces.%s has an unknown element %s"):format(part, tostring(element)))
					continue
				end
				for _, row in rows do
					if type(row.id) ~= "string" or seen[row.id] then
						problem(("HatchOdds: piece id %s under %s/%s is missing or duplicated"):format(tostring(row.id), part, element))
					else
						seen[row.id] = true
					end
					if not isFiniteNonNegative(row.weight) then
						problem(("HatchOdds: piece %s needs a weight of 0 or more"):format(tostring(row.id)))
					end
					if not table.find(PIECE_RARITIES, row.rarity) then
						problem(("HatchOdds: piece %s has an unknown rarity %s"):format(tostring(row.id), tostring(row.rarity)))
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
					problem(("HatchOdds: no %s piece for part %s"):format(element, part))
				end
			end
		end
	end

	return problems
end

return HatchOdds
