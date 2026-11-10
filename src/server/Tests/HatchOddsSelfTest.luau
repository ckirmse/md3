--!strict

-- Checks the roll and value math against the worked examples in the design spec, on the spec's own values (HatchOddsSpec).
-- The Studio HatchOdds table is only validated, so tuning it never fails the spec checks. Returns the failures.

local Genome = require("@game/ReplicatedStorage/Shared/Genome")
local GenomeItemName = require("@game/ReplicatedStorage/Shared/GenomeItemName")
local GenomeLook = require("@game/ReplicatedStorage/Shared/GenomeLook")
local GenomeRoll = require("@game/ReplicatedStorage/Shared/GenomeRoll")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local NestMath = require("@game/ReplicatedStorage/Shared/NestMath")

local HatchOddsSpec = require("./HatchOddsSpec")

local HatchOddsSelfTest = {}

local function weightOf(list: { GenomeRoll.Weighted }, id: string): number
	for _, entry in list do
		if entry.id == id then
			return entry.weight
		end
	end
	return 0
end

local function totalOf(list: { GenomeRoll.Weighted }): number
	local total = 0
	for _, entry in list do
		total += entry.weight
	end
	return total
end

-- the first piece of a part with this element and rarity
local function find(odds: HatchOdds.Odds, part: HatchOdds.Part, element: HatchOdds.Element, rarity: HatchOdds.PieceRarity): string
	for _, piece in odds.catalog.byPart[part] do
		if piece.element == element and piece.rarity == rarity then
			return piece.id
		end
	end
	return ""
end

local function makeGenome(odds: HatchOdds.Odds, element: HatchOdds.Element, rarity: HatchOdds.PieceRarity): Genome.Genome
	local pieces: { [HatchOdds.Part]: string } = {}
	for _, part in HatchOdds.PARTS do
		pieces[part] = find(odds, part, element, rarity)
	end
	return {
		uuid = "test-" .. element .. rarity,
		code = "TESTCODE",
		tier = 1,
		shares = { fire = 0, water = 0, nature = 0, [element] = 1 },
		pieces = pieces,
		size = 1,
		isGiant = false,
		mutation = "normal",
		traits = {},
		parents = {},
		bornAt = 0,
		oddsVersion = odds.config.version,
	}
end

-- the chance of each score over the 7 parts, given the parents' pieces per part
local function scoreDistribution(odds: HatchOdds.Odds, shares: Genome.Shares, parentPieces: { [HatchOdds.Part]: { string } }): { [number]: number }
	local distribution: { [number]: number } = { [0] = 1 }
	for _, part in HatchOdds.PARTS do
		local weights = GenomeRoll.getPieceWeights(odds, part, shares, parentPieces[part] or {})
		local total = totalOf(weights)
		local next: { [number]: number } = {}
		for score, chance in distribution do
			for _, entry in weights do
				local piece = odds.catalog.byId[entry.id]
				local points = odds.config.pieceScore[piece.rarity]
				next[score + points] = (next[score + points] or 0) + chance * entry.weight / total
			end
		end
		distribution = next
	end
	return distribution
end

function HatchOddsSelfTest.run(liveConfig: HatchOdds.Config): { string }
	local failures = HatchOdds.validate(liveConfig)
	if #failures > 0 then
		return failures
	end

	local config = HatchOddsSpec.build()
	failures = HatchOdds.validate(config)
	if #failures > 0 then
		return failures
	end

	local odds = HatchOdds.build(config)
	local function check(name: string, actual: number, expected: number, tolerance: number)
		if math.abs(actual - expected) > tolerance then
			table.insert(failures, ("%s: got %s, expected %s"):format(name, tostring(actual), tostring(expected)))
		end
	end

	-- spec "Worked example: the Head attachment roll": a 75% Fire / 25% Water baby, Fire Uncommon from A, Fire Legendary from B
	local shares: Genome.Shares = { fire = 0.75, water = 0.25, nature = 0 }
	local uncommon = find(odds, "headAttachment", "fire", "uncommon")
	local legendary = find(odds, "headAttachment", "fire", "legendary")
	local weights = GenomeRoll.getPieceWeights(odds, "headAttachment", shares, { uncommon, legendary })
	check("head attachment total", totalOf(weights), 15100, 0.001)
	check("head attachment Fire Uncommon", weightOf(weights, uncommon), 5625, 0.001)
	check("head attachment Fire Legendary", weightOf(weights, legendary), 1575, 0.001)
	check("head attachment Water Uncommon", weightOf(weights, find(odds, "headAttachment", "water", "uncommon")), 625, 0.001)
	check("head attachment Nature can't roll", weightOf(weights, find(odds, "headAttachment", "nature", "rare")), 0, 0)

	-- spec "Mutation slot": two Tidal parents, 75% Water / 25% Fire, laid during Rain
	local mutationWeights = GenomeRoll.getMutationWeights(odds, { fire = 0.25, water = 0.75, nature = 0 }, { "tidal", "tidal" }, "rain")
	check("mutation Tidal", weightOf(mutationWeights, "tidal"), 450, 0.001)
	check("mutation Blazing", weightOf(mutationWeights, "blazing"), 50, 0.001)
	check("mutation Normal", weightOf(mutationWeights, "normal"), 9390, 0.001)
	check("mutation total", totalOf(mutationWeights), config.mutationTotal, 0.001)
	local plainWeights = GenomeRoll.getMutationWeights(odds, { fire = 1, water = 0, nature = 0 }, {}, nil)
	check("mutation Normal with no buffs", weightOf(plainWeights, "normal"), 9690, 0.001)

	-- spec "Mythic parents": a Pure Fire egg, 3 shared Legendary and 4 shared Rare pieces
	local pureFire: Genome.Shares = { fire = 1, water = 0, nature = 0 }
	local sharedLegendary = find(odds, "wings", "fire", "legendary")
	local sharedCommon = find(odds, "wings", "fire", "common")
	check("shared Legendary passes", weightOf(GenomeRoll.getPieceWeights(odds, "wings", pureFire, { sharedLegendary, sharedLegendary }), sharedLegendary)
		/ totalOf(GenomeRoll.getPieceWeights(odds, "wings", pureFire, { sharedLegendary, sharedLegendary })), 0.287, 0.001)
	check("shared Common passes", weightOf(GenomeRoll.getPieceWeights(odds, "wings", pureFire, { sharedCommon, sharedCommon }), sharedCommon)
		/ totalOf(GenomeRoll.getPieceWeights(odds, "wings", pureFire, { sharedCommon, sharedCommon })), 0.429, 0.001)

	local parentPieces: { [HatchOdds.Part]: { string } } = {}
	for index, part in HatchOdds.PARTS do
		local id = find(odds, part, "fire", if index <= 3 then "legendary" else "rare")
		parentPieces[part] = { id, id }
	end
	local mythicChance, legendaryChance = 0, 0
	for score, chance in scoreDistribution(odds, pureFire, parentPieces) do
		if GenomeValue.getBandForScore(odds, score) == "mythic" then
			mythicChance += chance
		elseif GenomeValue.getBandForScore(odds, score) == "legendary" then
			legendaryChance += chance
		end
	end
	check("Mythic parents: baby Mythic", mythicChance, 0.031, 0.0005)
	check("Mythic parents: baby Legendary", legendaryChance, 0.1865, 0.0005)

	-- spec "Rarity and value": the average fresh hatch scores about 6.4
	local mean = 0
	for score, chance in scoreDistribution(odds, pureFire, {}) do
		mean += score * chance
	end
	check("fresh hatch mean score", mean, 6.37, 0.01)

	-- spec "Tier jump" chance by the parents' average band
	local expectedJump = { common = 0.005, uncommon = 0.006, rare = 0.0075, epic = 0.01, legendary = 0.015, mythic = 0.02 }
	for band, expected in expectedJump do
		check("tier jump " .. band, GenomeRoll.getTierJumpChance(odds, band :: HatchOdds.DragonBand), expected, 0.00001)
	end

	-- rarity bands at their edges
	for score, expected in { [0] = "common", [2] = "common", [3] = "uncommon", [6] = "uncommon", [7] = "rare", [13] = "rare", [14] = "epic", [23] = "epic", [24] = "legendary", [33] = "legendary", [34] = "mythic", [70] = "mythic" } do
		if GenomeValue.getBandForScore(odds, score) ~= expected then
			table.insert(failures, ("band for score %d: got %s, expected %s"):format(score, GenomeValue.getBandForScore(odds, score), expected))
		end
	end

	-- value: Base x (1 + Score + Pure) x Size^2 x Mutation x (1 + Traits)
	local commons = makeGenome(odds, "fire", "common")
	check("value of a plain Wyrmling", GenomeValue.getValue(odds, commons), 15, 0.001)
	commons.size = 1.5
	check("value of a 1.5 size", GenomeValue.getValue(odds, commons), 15 * 2.25, 0.001)
	commons.size = 1
	commons.mutation = "rainbow"
	check("value of a Rainbow", GenomeValue.getValue(odds, commons), 15 * 50, 0.001)
	commons.mutation = "normal"
	commons.traits = { "soaked", "charged" }
	check("value of Soaked + Charged", GenomeValue.getValue(odds, commons), 15 * 22, 0.001)
	local legendaries = makeGenome(odds, "fire", "legendary")
	check("a Pure Legendary is Pure", if GenomeValue.isPure(odds, legendaries) then 1 else 0, 1, 0)
	check("value of a Pure Legendary", GenomeValue.getValue(odds, legendaries), 15 * (1 + 70 + config.pureBonus), 0.001)

	-- visible scale: the size stat moves it only within the tier's range
	local sized = makeGenome(odds, "fire", "common")
	sized.size = config.sizeMin
	check("visible scale at the floor", GenomeValue.getVisibleScale(odds, sized), config.tiers[1].baseScale * config.visibleMin, 0.0001)
	sized.size = config.sizeMax
	check("visible scale at the ceiling", GenomeValue.getVisibleScale(odds, sized), config.tiers[1].baseScale * (config.visibleMin + config.visibleSpan), 0.0001)
	sized.isGiant = true
	check("visible scale of a Giant", GenomeValue.getVisibleScale(odds, sized), config.tiers[1].baseScale * (config.visibleMin + config.visibleSpan) * config.giantVisible, 0.0001)

	-- size stays in range and Giants are about giantChance of rolls
	local rng = Random.new(1)
	local giants, samples = 0, 20000
	for _ = 1, samples do
		local size, isGiant = GenomeRoll.rollSize(odds, { 3, 3 }, rng)
		if size < config.sizeMin or size > config.sizeMax then
			table.insert(failures, "rolled size out of range: " .. tostring(size))
			break
		end
		if isGiant then
			giants += 1
		end
	end
	check("Giant rate", giants / samples, config.giantChance, 0.004)

	-- a full roll: averaged shares, pieces from the allowed set, locks honoured and charged
	local parentA = makeGenome(odds, "fire", "rare")
	local parentB = makeGenome(odds, "water", "common")
	parentB.uuid = "test-b"
	local lockedWings = parentA.pieces.wings
	local baby = GenomeRoll.rollGenome(odds, {
		parentA = parentA,
		parentB = parentB,
		locks = { wings = lockedWings },
		uuid = "00000000-1111-2222-3333-444444444444",
		bornAt = 0,
	}, rng)
	if not baby then
		table.insert(failures, "rollGenome returned nil for a valid pair")
	else
		check("baby Fire share", baby.shares.fire, 0.5, 0.0001)
		check("baby Water share", baby.shares.water, 0.5, 0.0001)
		check("baby Nature share", baby.shares.nature, 0, 0.0001)
		if baby.pieces.wings ~= lockedWings then
			table.insert(failures, "the locked wings were not copied")
		end
		for _, part in HatchOdds.PARTS do
			local piece = odds.catalog.byId[baby.pieces[part]]
			if not piece or piece.element == "nature" then
				table.insert(failures, "baby rolled a piece it can't have for " .. part)
			end
		end
		if baby.code ~= "00000000" then
			table.insert(failures, "display code was " .. baby.code)
		end
		if baby.tier ~= 1 and baby.tier ~= 2 then
			table.insert(failures, "baby tier was " .. tostring(baby.tier))
		end
	end
	check("lock cost of a Rare wing", GenomeRoll.getLockCost(odds, { wings = lockedWings }), config.lockTokenCost.rare, 0)
	local mismatched = table.clone(parentB)
	mismatched.tier = 2
	if GenomeRoll.rollGenome(odds, { parentA = parentA, parentB = mismatched, uuid = "x", bornAt = 0 }, rng) ~= nil then
		table.insert(failures, "rollGenome accepted parents of different tiers")
	end

	-- the legacy item a genome is built on: head element picks the color, band the rarity, tier the level
	local function checkItemName(genome: Genome.Genome, expected: string)
		local name = GenomeItemName.get(odds, genome)
		if name ~= expected then
			table.insert(failures, ("item name: got %s, expected %s"):format(tostring(name), expected))
		end
	end
	checkItemName(makeGenome(odds, "fire", "common"), "Red Dragon Level 5")
	checkItemName(makeGenome(odds, "water", "uncommon"), "Blue R Dragon Level 5") -- 7 Uncommon pieces score 7, which is Rare
	checkItemName(makeGenome(odds, "fire", "legendary"), "Red E Dragon Level 5") -- Mythic shares the Epic item
	local tierThree = makeGenome(odds, "nature", "rare")
	tierThree.tier = 3
	checkItemName(tierThree, "Green E Dragon Level 7") -- 21 points is Epic

	-- the look: each slot borrows the model of its piece's element; Legendary borrows the Epic model, the texture follows the piece's own rarity
	local function checkLook(slot: string, donor: GenomeLook.Donor?, color: string, rarity: string)
		if not donor or donor.color ~= color or donor.rarity ~= rarity then
			table.insert(failures, ("look %s: got %s, expected %s %s"):format(slot, if donor then donor.color .. " " .. donor.rarity else "nil", color, rarity))
		end
	end
	local waterRare = GenomeLook.get(odds, makeGenome(odds, "water", "rare"))
	checkLook("rare wings", waterRare and waterRare.wings, "Blue", "Common")
	checkLook("rare body texture", waterRare and waterRare.bodyTexture, "Blue", "Rare")
	local fireLegendary = GenomeLook.get(odds, makeGenome(odds, "fire", "legendary"))
	checkLook("legendary tail", fireLegendary and fireLegendary.tail, "Red", "Epic")
	checkLook("legendary body texture", fireLegendary and fireLegendary.bodyTexture, "Red", "Epic")
	local mixedGenome = makeGenome(odds, "fire", "uncommon")
	mixedGenome.pieces.wings = find(odds, "wings", "nature", "uncommon")
	local mixedLook = GenomeLook.get(odds, mixedGenome)
	checkLook("mixed wings", mixedLook and mixedLook.wings, "Green", "Common")
	checkLook("mixed head attachment", mixedLook and mixedLook.headAttachment, "Red", "Common")
	checkLook("legendary head attachment", fireLegendary and fireLegendary.headAttachment, "Red", "Epic")
	checkLook("mixed tail", mixedLook and mixedLook.tail, "Red", "Common")
	checkLook("mixed body texture", mixedLook and mixedLook.bodyTexture, "Red", "Uncommon")

	-- the Nest schedule: Wyrmling Common parents lay every 30 s, 3 eggs wait at most, and a full Nest restarts its timer when an egg is taken
	local eggCount = 0
	local function makeUuid(): string
		eggCount += 1
		return ("%08d-1111-2222-3333-444444444444"):format(eggCount)
	end
	local nestA = makeGenome(odds, "fire", "common")
	local nestB = makeGenome(odds, "fire", "common")
	nestB.uuid = "nest-b"
	local nest = NestMath.create(odds, nestA, nestB, {}, 1, 1000)
	if not nest then
		table.insert(failures, "NestMath.create returned nil for a valid pair")
	else
		check("nest first egg due", nest.nextLayAt or -1, 1030, 0)
		local params: NestMath.AdvanceParams = { now = 1029, rng = rng, makeUuid = makeUuid }
		check("no egg before it is due", #NestMath.advance(odds, nest, params), 0, 0)
		params.now = 1100
		local laid = NestMath.advance(odds, nest, params)
		check("eggs laid by the catch-up", #laid, 3, 0)
		check("third egg is laid at its due time", if #laid == 3 then laid[3].laidAt else -1, 1090, 0)
		check("a full nest has no due time", if nest.nextLayAt == nil then 1 else 0, 1, 0)
		params.now = 5000
		check("a full nest lays nothing", #NestMath.advance(odds, nest, params), 0, 0)
		NestMath.takeEgg(odds, nest, 1, 5000)
		check("taking an egg restarts the timer", nest.nextLayAt or -1, 5030, 0)
		params.now = 5030
		check("one egg after the timer", #NestMath.advance(odds, nest, params), 1, 0)
	end
	local slowA = makeGenome(odds, "fire", "uncommon") -- 7 Uncommon pieces score 7, the Rare band
	local slowB = makeGenome(odds, "fire", "uncommon")
	slowB.uuid = "slow-b"
	local slowNest = NestMath.create(odds, slowA, slowB, {}, 1, 0)
	check("lay time of Rare parents", if slowNest then NestMath.getLayTimeSec(odds, slowNest) else -1, 37.5, 0.001)
	local boosted = NestMath.create(odds, nestA, nestB, {}, 0.75, 0)
	check("lay time with a speed boost", if boosted then NestMath.getLayTimeSec(odds, boosted) else -1, 22.5, 0.001)
	local mismatchedTier = table.clone(nestB)
	mismatchedTier.tier = 2
	if NestMath.create(odds, nestA, mismatchedTier, {}, 1, 0) ~= nil then
		table.insert(failures, "NestMath.create accepted parents of different tiers")
	end

	-- the Lock Tokens are charged per egg, and when they run out the Nest keeps laying without the lock
	local lockParent = makeGenome(odds, "fire", "rare")
	local lockPartner = makeGenome(odds, "fire", "common")
	lockPartner.uuid = "lock-b"
	local lockedNest = NestMath.create(odds, lockParent, lockPartner, { wings = lockParent.pieces.wings }, 1, 0)
	if not lockedNest then
		table.insert(failures, "NestMath.create returned nil for a locked pair")
	else
		local tokens, charges = 5, 0
		local lockedEggs = NestMath.advance(odds, lockedNest, {
			now = 100000,
			rng = rng,
			makeUuid = makeUuid,
			spendTokens = function(cost: number): boolean
				charges += 1
				if tokens >= cost then
					tokens -= cost
					return true
				end
				return false
			end,
		})
		check("tokens left after one Rare lock", tokens, 1, 0)
		check("every egg asked for its tokens", charges, 3, 0)
		if lockedEggs[1] and lockedEggs[1].genome.pieces.wings ~= lockParent.pieces.wings then
			table.insert(failures, "the first locked egg did not copy the locked wings")
		end
	end

	-- a fresh roll has no parents, keeps its mix and tier, and only rolls pieces of the elements it has
	local fresh = GenomeRoll.rollFresh(odds, { fire = 0.5, water = 0.5, nature = 0 }, 4, "00000000-1111-2222-3333-444444444444", 0, rng)
	if not fresh then
		table.insert(failures, "rollFresh returned nil")
	else
		check("fresh Fire share", fresh.shares.fire, 0.5, 0.0001)
		check("fresh tier", fresh.tier, 4, 0)
		check("fresh parents", #fresh.parents, 0, 0)
		for _, part in HatchOdds.PARTS do
			local piece = odds.catalog.byId[fresh.pieces[part]]
			if not piece or piece.element == "nature" then
				table.insert(failures, "fresh dragon rolled a piece it can't have for " .. part)
			end
		end
		if fresh.size < config.sizeMin or fresh.size > config.sizeMax then
			table.insert(failures, "fresh size out of range: " .. tostring(fresh.size))
		end
	end

	return failures
end

return HatchOddsSelfTest
