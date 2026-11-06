--!strict

-- The design spec's launch values as a Config, with its piece shape (3 Common, 1 Uncommon, 1 Rare, 1 Legendary per part and element).
-- The self-test checks the roll math against the spec's worked examples on this, so tuning the Studio table never breaks it.

local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")

local HatchOddsSpec = {}

local COMMON_COUNT = 3
local WEIGHT: { [HatchOdds.PieceRarity]: number } = { common = 2000, uncommon = 2500, rare = 1200, legendary = 300 }
local UPPER_RARITIES: { HatchOdds.PieceRarity } = { "uncommon", "rare", "legendary" }

local function buildPieces(): { [HatchOdds.Part]: { [HatchOdds.Element]: { HatchOdds.PieceRow } } }
	local pieces: { [HatchOdds.Part]: { [HatchOdds.Element]: { HatchOdds.PieceRow } } } = {}
	for partIndex = 1, #HatchOdds.PARTS do
		local part: HatchOdds.Part = HatchOdds.PARTS[partIndex]
		local byElement: { [HatchOdds.Element]: { HatchOdds.PieceRow } } = {}
		for elementIndex = 1, #HatchOdds.ELEMENTS do
			local element: HatchOdds.Element = HatchOdds.ELEMENTS[elementIndex]
			local rows: { HatchOdds.PieceRow } = {}
			for number = 1, COMMON_COUNT do
				table.insert(rows, { id = ("%s_%s_common%d"):format(element, part, number), rarity = "common", weight = WEIGHT.common })
			end
			for rarityIndex = 1, #UPPER_RARITIES do
				local rarity: HatchOdds.PieceRarity = UPPER_RARITIES[rarityIndex]
				table.insert(rows, { id = ("%s_%s_%s"):format(element, part, rarity), rarity = rarity, weight = WEIGHT[rarity] })
			end
			byElement[element] = rows
		end
		pieces[part] = byElement
	end
	return pieces
end

function HatchOddsSpec.build(): HatchOdds.Config
	return {
		version = 1,
		pieces = buildPieces(),
		pieceParentBuff = { common = 1, uncommon = 2, rare = 3, legendary = 6 },
		pieceScore = { common = 0, uncommon = 1, rare = 3, legendary = 10 },
		lockTokenCost = { common = 1, uncommon = 2, rare = 4, legendary = 10 },
		maxLocks = 2,
		dragonBands = {
			{ name = "common", minScore = 0 },
			{ name = "uncommon", minScore = 3 },
			{ name = "rare", minScore = 7 },
			{ name = "epic", minScore = 14 },
			{ name = "legendary", minScore = 24 },
			{ name = "mythic", minScore = 34 },
		},
		pureBonus = 5,
		tiers = {
			{ name = "Wyrmling", segments = 4, marketPrice = 100, baseValue = 15, layTimeSec = 30, growTimeSec = 60, baseScale = 1.00, dragonLevel = 5 },
			{ name = "Young", segments = 5, marketPrice = 2500, baseValue = 200, layTimeSec = 120, growTimeSec = 180, baseScale = 1.15, dragonLevel = 6 },
			{ name = "Adult", segments = 6, marketPrice = 60000, baseValue = 4000, layTimeSec = 300, growTimeSec = 480, baseScale = 1.32, dragonLevel = 7 },
			{ name = "Mature", segments = 7, marketPrice = 1500000, baseValue = 80000, layTimeSec = 900, growTimeSec = 1200, baseScale = 1.52, dragonLevel = 8 },
			{ name = "Elder", segments = 8, marketPrice = 40000000, baseValue = 1600000, layTimeSec = 2700, growTimeSec = 3600, baseScale = 1.75, dragonLevel = 9 },
			{ name = "Ancient", segments = 9, marketPrice = 1000000000, baseValue = 35000000, layTimeSec = 7200, growTimeSec = 10800, baseScale = 2.01, dragonLevel = 10 },
			{ name = "Great Wyrm", segments = 10, marketPrice = 25000000000, baseValue = 750000000, layTimeSec = 21600, growTimeSec = 28800, baseScale = 2.31, dragonLevel = 10 },
		},
		visibleMin = 0.94,
		visibleSpan = 0.12,
		visibleSizeCap = 2.0,
		giantVisible = 1.15,
		sizeParentWeight = 0.7,
		sizeBase = 0.3,
		sizeJitterMin = 0.9,
		sizeJitterMax = 1.1,
		giantChance = 0.01,
		giantMult = 1.5,
		sizeMin = 0.5,
		sizeMax = 3.0,
		mutationTotal = 10000,
		mutationParentBuff = 0.5,
		weatherMutationBuff = 1.0,
		mutationWeightCap = 1000,
		mutations = {
			{ id = "blazing", element = "fire", baseWeight = 200, valueMult = 5, weather = "heatwave" },
			{ id = "tidal", element = "water", baseWeight = 200, valueMult = 5, weather = "rain" },
			{ id = "verdant", element = "nature", baseWeight = 200, valueMult = 5, weather = "bloomStorm" },
			{ id = "gilded", baseWeight = 100, valueMult = 20 },
			{ id = "rainbow", baseWeight = 10, valueMult = 50 },
		},
		traitBonus = { soaked = 1, toasty = 2, flowered = 3, charged = 20 },
		tierJumpTotal = 10000,
		tierJumpBaseWeight = 50,
		tierJumpBonus = { common = 0, uncommon = 10, rare = 25, epic = 50, legendary = 100, mythic = 150 },
		layTimeMult = { common = 1.0, uncommon = 1.1, rare = 1.25, epic = 1.5, legendary = 2, mythic = 2.5 },
		layBoostFloor = 0.5,
	}
end

return HatchOddsSpec
