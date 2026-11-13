--!strict

-- Checks the roll and value math against the worked examples in the design spec, on the spec's own values (HatchOddsSpec).
-- The Studio HatchOdds table is only validated, so tuning it never fails the spec checks. Returns the failures.

local Genome = require("@game/ReplicatedStorage/Shared/Genome")
local GenomeItemName = require("@game/ReplicatedStorage/Shared/GenomeItemName")
local GenomeLook = require("@game/ReplicatedStorage/Shared/GenomeLook")
local GenomeRoll = require("@game/ReplicatedStorage/Shared/GenomeRoll")
local GenomeValue = require("@game/ReplicatedStorage/Shared/GenomeValue")
local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")
local HatchWeather = require("@game/ReplicatedStorage/Shared/HatchWeather")
local Enums = require("@game/ReplicatedStorage/Shared/Enums")
local NestMath = require("@game/ReplicatedStorage/Shared/NestMath")
local PairOdds = require("@game/ReplicatedStorage/Shared/PairOdds")
local Restyle = require("@game/ReplicatedStorage/Shared/Restyle")

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
		origin = "market",
		restyleCount = 0,
		generation = 0,
		ancestry = {},
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

-- the three Hatch Control modules put together the way HatchOddsManager does; a message instead when one is missing
local function loadLiveConfig(): (any, string?)
	local control: any = game:GetService("ServerScriptService"):FindFirstChild("GameData")
	control = if control then control:FindFirstChild("Control") else nil
	if not control then
		return nil, "ServerScriptService.GameData.Control is missing"
	end
	local data: { [string]: any } = {}
	for _, name in { "HatchOdds", "HatchPieces", "HatchSystems" } do
		local module = control:FindFirstChild(name)
		if not module then
			return nil, "Control/" .. name .. " is missing"
		end
		data[name] = require(module)
	end
	return HatchOdds.assemble(data.HatchOdds, data.HatchPieces, data.HatchSystems), nil
end

-- Pass nothing to check the live Control modules, or an assembled Config to check that. Returns the failures, empty when all pass.
function HatchOddsSelfTest.run(liveConfig: any?): { string }
	local live = liveConfig
	if live == nil then
		local loaded, message = loadLiveConfig()
		if not loaded then
			return { message :: string }
		end
		live = loaded
	end
	local failures = HatchOdds.validate(live)
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

	-- the pairing screen's numbers match the roll: same Mythic parents, read through PairOdds
	local mythicA = makeGenome(odds, "fire", "common")
	local mythicB = makeGenome(odds, "fire", "common")
	mythicB.uuid = "mythic-b"
	for _, part in HatchOdds.PARTS do
		mythicA.pieces[part] = parentPieces[part][1]
		mythicB.pieces[part] = parentPieces[part][1]
	end
	local pair = PairOdds.get(odds, mythicA, mythicB, nil)
	if not pair then
		table.insert(failures, "PairOdds returned nil for a valid pair")
	else
		check("PairOdds baby Mythic", pair.bands.mythic, 0.031, 0.0005)
		check("PairOdds baby Legendary", pair.bands.legendary, 0.1865, 0.0005)
		local bandTotal = 0
		for _, chance in pair.bands do
			bandTotal += chance
		end
		check("PairOdds band chances add up", bandTotal, 1, 0.0001)
		for _, part in HatchOdds.PARTS do
			local partTotal = 0
			for _, entry in pair.parts[part] do
				partTotal += entry.chance
			end
			check("PairOdds " .. part .. " chances add up", partTotal, 1, 0.0001)
		end
		local mutationTotal = 0
		for _, entry in pair.mutations do
			mutationTotal += entry.chance
		end
		check("PairOdds mutation chances add up", mutationTotal, 1, 0.0001)
		if pair.sizeMin > pair.sizeMax or pair.sizeMax > pair.giantSizeMax then
			table.insert(failures, "PairOdds size range is not ordered")
		end
	end
	local wrongTier = table.clone(mythicB)
	wrongTier.tier = 2
	if PairOdds.get(odds, mythicA, wrongTier, nil) ~= nil then
		table.insert(failures, "PairOdds accepted parents of different tiers")
	end

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

	-- a full roll: averaged shares, pieces from the allowed set
	local parentA = makeGenome(odds, "fire", "rare")
	local parentB = makeGenome(odds, "water", "common")
	parentB.uuid = "test-b"
	local baby = GenomeRoll.rollGenome(odds, {
		parentA = parentA,
		parentB = parentB,
		uuid = "00000000-1111-2222-3333-444444444444",
		bornAt = 0,
	}, rng)
	if not baby then
		table.insert(failures, "rollGenome returned nil for a valid pair")
	else
		check("baby Fire share", baby.shares.fire, 0.5, 0.0001)
		check("baby Water share", baby.shares.water, 0.5, 0.0001)
		check("baby Nature share", baby.shares.nature, 0, 0.0001)
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
	local rollContext: NestMath.RollContext = { rng = rng, makeUuid = makeUuid, weather = nil }
	local nestA = makeGenome(odds, "fire", "common")
	local nestB = makeGenome(odds, "fire", "common")
	nestB.uuid = "nest-b"
	local nest = NestMath.create(odds, nestA, nestB, 1, 1000, rollContext)
	if not nest then
		table.insert(failures, "NestMath.create returned nil for a valid pair")
	else
		check("nest first egg due", nest.nextLayAt or -1, 1030, 0)
		local firstPending = nest.pendingEgg
		if not firstPending then
			table.insert(failures, "a new Nest has no pending egg")
		end
		local params: NestMath.AdvanceParams = { now = 1029, rng = rng, makeUuid = makeUuid }
		check("no egg before it is due", #NestMath.advance(odds, nest, params), 0, 0)
		params.now = 1100
		local laid = NestMath.advance(odds, nest, params)
		check("eggs laid by the catch-up", #laid, 3, 0)
		if firstPending and laid[1] and laid[1].genome.uuid ~= firstPending.uuid then
			table.insert(failures, "the first laid egg is not the one rolled at timer start")
		end
		check("third egg is laid at its due time", if #laid == 3 then laid[3].laidAt else -1, 1090, 0)
		check("a full nest has no due time", if nest.nextLayAt == nil then 1 else 0, 1, 0)
		check("a full nest has no pending egg", if nest.pendingEgg == nil then 1 else 0, 1, 0)
		params.now = 5000
		check("a full nest lays nothing", #NestMath.advance(odds, nest, params), 0, 0)
		NestMath.takeEgg(odds, nest, 1, 5000, rollContext)
		check("taking an egg restarts the timer", nest.nextLayAt or -1, 5030, 0)
		local restartPending = nest.pendingEgg
		if not restartPending then
			table.insert(failures, "taking an egg did not roll the next pending egg")
		end
		params.now = 5030
		local afterTimer = NestMath.advance(odds, nest, params)
		check("one egg after the timer", #afterTimer, 1, 0)
		if restartPending and afterTimer[1] and afterTimer[1].genome.uuid ~= restartPending.uuid then
			table.insert(failures, "the egg laid after a restart is not the pending egg")
		end
	end

	-- a Nest saved before eggs were rolled at timer start gets its pending egg on the next advance and keeps its due time
	local migratedNest = NestMath.create(odds, nestA, nestB, 1, 2000, rollContext)
	if migratedNest then
		migratedNest.pendingEgg = nil
		NestMath.advance(odds, migratedNest, { now = 2010, rng = rng, makeUuid = makeUuid })
		if not migratedNest.pendingEgg then
			table.insert(failures, "an old Nest did not get a pending egg")
		end
		check("an old Nest keeps its due time", migratedNest.nextLayAt or -1, 2030, 0)
		check("an old Nest lays nothing before it is due", #migratedNest.eggs, 0, 0)
	end
	local slowA = makeGenome(odds, "fire", "uncommon") -- 7 Uncommon pieces score 7, the Rare band
	local slowB = makeGenome(odds, "fire", "uncommon")
	slowB.uuid = "slow-b"
	local slowNest = NestMath.create(odds, slowA, slowB, 1, 0, rollContext)
	check("lay time of Rare parents", if slowNest then NestMath.getLayTimeSec(odds, slowNest) else -1, 37.5, 0.001)
	local boosted = NestMath.create(odds, nestA, nestB, 0.75, 0, rollContext)
	check("lay time with a speed boost", if boosted then NestMath.getLayTimeSec(odds, boosted) else -1, 22.5, 0.001)
	local mismatchedTier = table.clone(nestB)
	mismatchedTier.tier = 2
	if NestMath.create(odds, nestA, mismatchedTier, 1, 0, rollContext) ~= nil then
		table.insert(failures, "NestMath.create accepted parents of different tiers")
	end

	-- lineage: a baby carries frozen snapshots of its parents, which carry theirs, 3 generations deep and no deeper
	local line: Genome.Genome = makeGenome(odds, "fire", "common")
	for generation = 1, 4 do
		local mate = makeGenome(odds, "fire", "common")
		mate.uuid = "mate-" .. generation
		local child = GenomeRoll.rollGenome(odds, { parentA = line, parentB = mate, uuid = "line-" .. generation, bornAt = 0 }, rng)
		if not child then
			table.insert(failures, "lineage roll returned nil")
			break
		end
		child.tier = 1
		check("lineage generation " .. generation, child.generation, generation, 0)
		check("lineage parents " .. generation, #child.ancestry, 2, 0)
		line = child
	end
	local depth, node = 0, line.ancestry[1]
	while node do
		depth += 1
		node = node.ancestry[1]
	end
	check("lineage depth is capped", depth, Genome.LINEAGE_GENERATIONS, 0)
	local frozen = Genome.snapshot(line, 1)
	local wingsBefore = line.pieces.wings
	line.pieces.wings = "changed"
	if frozen.pieces.wings ~= wingsBefore then
		table.insert(failures, "a snapshot changed with its dragon")
	end
	line.pieces.wings = wingsBefore
	check("snapshot of one level has no ancestors", #frozen.ancestry, 0, 0)

	-- weather traits: 2% per minute for a waiting egg, doubled for a 50%+ match, never twice, none without weather
	if HatchWeather.fromGameWeather(Enums.Weather.RAIN) ~= "rain" or HatchWeather.fromGameWeather(Enums.Weather.HEAT) ~= "heatwave"
		or HatchWeather.fromGameWeather(Enums.Weather.BLOOM) ~= "bloomStorm" or HatchWeather.fromGameWeather(Enums.Weather.THUNDERSTORM) ~= "thunderstorm" then
		table.insert(failures, "the game weathers did not map to the Hatch weathers")
	end
	if HatchWeather.fromGameWeather(Enums.Weather.WIND) ~= nil or HatchWeather.fromGameWeather(nil) ~= nil then
		table.insert(failures, "Wind or no weather gave a Hatch weather")
	end
	local waterEgg = makeGenome(odds, "water", "common")
	local fireEgg = makeGenome(odds, "fire", "common")
	check("trait chance, matching element", HatchWeather.getTraitChance(config, waterEgg, "rain", 60), 0.04, 0.0001)
	check("trait chance, other element", HatchWeather.getTraitChance(config, fireEgg, "rain", 60), 0.02, 0.0001)
	check("trait chance, half a minute", HatchWeather.getTraitChance(config, fireEgg, "rain", 30), 1 - 0.98 ^ 0.5, 0.0001)
	check("trait chance, thunderstorm has no matching element", HatchWeather.getTraitChance(config, waterEgg, "thunderstorm", 60), 0.02, 0.0001)
	waterEgg.traits = { "soaked" }
	check("trait chance, already has it", HatchWeather.getTraitChance(config, waterEgg, "rain", 60), 0, 0)

	local traitParentA = makeGenome(odds, "fire", "common")
	local traitParentB = makeGenome(odds, "fire", "common")
	traitParentB.uuid = "trait-b"
	local traitNest = NestMath.create(odds, traitParentA, traitParentB, 1, 0, rollContext)
	if traitNest then
		NestMath.advance(odds, traitNest, { now = 100000, rng = rng, makeUuid = makeUuid })
		check("no weather, no traits", NestMath.growTraits(odds, traitNest, nil, 6000, rng), 0, 0)
		check("a long rain gives every egg the trait", NestMath.growTraits(odds, traitNest, "rain", 100000, rng), #traitNest.eggs, 0)
		check("a second rain gives nothing new", NestMath.growTraits(odds, traitNest, "rain", 100000, rng), 0, 0)
		for _, egg in traitNest.eggs do
			if #egg.genome.traits ~= 1 or egg.genome.traits[1] ~= "soaked" then
				table.insert(failures, "an egg's traits were not just soaked")
			end
		end
	else
		table.insert(failures, "NestMath.create returned nil for the weather trait test")
	end

	-- optional config fields: a table that leaves them out uses the defaults, one that sets them wins, a bad one is a problem
	check("default egg cap", NestMath.getEggCap(odds), HatchOdds.DEFAULT_EGG_CAP, 0)
	local custom = table.clone(config)
	custom.nests = table.clone(config.nests)
	custom.nests.eggCap = 5
	custom.weather = { traitChancePerMinute = 0.5, traits = { rain = { trait = "drenched", element = "fire" } } }
	local customOdds = HatchOdds.build(custom)
	check("custom egg cap", NestMath.getEggCap(customOdds), 5, 0)
	check("custom trait chance, element now fire", HatchWeather.getTraitChance(custom, makeGenome(odds, "fire", "common"), "rain", 60), 1, 0.0001)
	check("custom trait chance, other element", HatchWeather.getTraitChance(custom, makeGenome(odds, "water", "common"), "rain", 60), 0.5, 0.0001)
	check("custom table has no heatwave trait", HatchWeather.getTraitChance(custom, makeGenome(odds, "fire", "common"), "heatwave", 60), 0, 0)
	if #HatchOdds.validate(custom) > 0 then
		table.insert(failures, "a valid custom config was rejected: " .. table.concat(HatchOdds.validate(custom), "; "))
	end
	-- a Nest saved full restarts its timer when the cap is raised, and fills to the new cap
	local capParentA = makeGenome(odds, "fire", "common")
	local capParentB = makeGenome(odds, "fire", "common")
	capParentB.uuid = "cap-b"
	local capNest = NestMath.create(odds, capParentA, capParentB, 1, 0, rollContext)
	if capNest then
		NestMath.advance(odds, capNest, { now = 100000, rng = rng, makeUuid = makeUuid })
		check("the Nest is full at the default cap", #capNest.eggs, 3, 0)
		if capNest.nextLayAt ~= nil then
			table.insert(failures, "a full Nest still had a timer")
		end
		NestMath.advance(customOdds, capNest, { now = 100000, rng = rng, makeUuid = makeUuid })
		if capNest.nextLayAt == nil then
			table.insert(failures, "raising the cap did not restart a full Nest's timer")
		end
		NestMath.advance(customOdds, capNest, { now = 200000, rng = rng, makeUuid = makeUuid })
		check("the Nest fills to the raised cap", #capNest.eggs, 5, 0)
	else
		table.insert(failures, "NestMath.create returned nil for the cap test")
	end

	check("default restyle Diamond rate", HatchOdds.DEFAULT_RESTYLE_DIAMONDS_PER_TOKEN, 5, 0)
	local badRate = table.clone(config)
	badRate.economy = { restyleDiamondsPerToken = 0 }
	if #HatchOdds.validate(badRate) < 1 then
		table.insert(failures, "a restyleDiamondsPerToken of 0 was not rejected")
	end

	-- the Control modules are assembled into one Config, and a missing nests section is reported under its file's name
	local assembled = HatchOdds.assemble({ version = 1 }, { pieces = { marker = true } }, { nests = config.nests, weather = {}, economy = {} })
	if not assembled.pieces or not assembled.pieces.marker or assembled.nests ~= config.nests or assembled.weather == nil or assembled.economy == nil then
		table.insert(failures, "HatchOdds.assemble did not put the three modules together")
	end
	local noNests = table.clone(config)
	noNests.nests = nil :: any
	local noNestsProblems = HatchOdds.validate(noNests)
	if #noNestsProblems ~= 1 or not string.find(noNestsProblems[1], "HatchSystems: nests", 1, true) then
		table.insert(failures, "a missing nests section was not reported as a HatchSystems problem: " .. table.concat(noNestsProblems, "; "))
	end

	-- genomes saved before restyles existed count as never restyled
	local oldGenome = makeGenome(odds, "fire", "common")
	local looseGenome: any = oldGenome
	looseGenome.restyleCount = nil
	Genome.fillLineage(oldGenome)
	check("old genome restyle count", oldGenome.restyleCount, 0, 0)

	local broken = table.clone(config)
	broken.nests = table.clone(config.nests)
	broken.nests.eggCap = 0
	broken.weather = { traitChancePerMinute = 2, traits = { hail = { trait = "icy" } } :: any }
	if #HatchOdds.validate(broken) < 3 then
		table.insert(failures, "a config with a bad eggCap, chance and weather was not rejected enough")
	end

	-- Restyle: tier x 2^restyles in tokens (spec: a Great Wyrm pays 7, 14, 28), Diamonds at the pack rate, and the piece always changes
	local restyleDragon = makeGenome(odds, "fire", "uncommon")
	check("restyle cost, Wyrmling first", Restyle.getTokenCost(restyleDragon), 1, 0)
	restyleDragon.tier = 7
	check("restyle cost, Great Wyrm first", Restyle.getTokenCost(restyleDragon), 7, 0)
	restyleDragon.restyleCount = 1
	check("restyle cost, Great Wyrm second", Restyle.getTokenCost(restyleDragon), 14, 0)
	restyleDragon.restyleCount = 2
	check("restyle cost, Great Wyrm third", Restyle.getTokenCost(restyleDragon), 28, 0)
	check(
		"restyle Diamond cost",
		Restyle.getDiamondCost(odds, restyleDragon),
		28 * HatchOdds.DEFAULT_RESTYLE_DIAMONDS_PER_TOKEN,
		0
	)
	restyleDragon.tier = 1
	restyleDragon.restyleCount = 0
	local currentWings = restyleDragon.pieces.wings
	local wingChances = Restyle.getChances(odds, restyleDragon, "wings")
	local wingTotal = 0
	for _, entry in wingChances do
		wingTotal += entry.chance
		local piece = odds.catalog.byId[entry.id]
		if entry.id == currentWings then
			table.insert(failures, "the restyle chances included the current piece")
		elseif not piece or piece.element ~= "fire" then
			table.insert(failures, "a pure Fire dragon could restyle into " .. entry.id)
		end
	end
	check("restyle chances add up", wingTotal, 1, 0.0001)
	check("restyle offers the other 5 Fire wings", #wingChances, 5, 0)
	local sameCount = 0
	for _ = 1, 300 do
		if Restyle.roll(odds, restyleDragon, "wings", rng) == currentWings then
			sameCount += 1
		end
	end
	check("a restyle never rolls the current piece", sameCount, 0, 0)
	local restyledGenome = Restyle.apply(restyleDragon, "wings", wingChances[1].id)
	check("restyle count goes up", restyledGenome.restyleCount, 1, 0)
	if restyledGenome.pieces.wings ~= wingChances[1].id or restyleDragon.pieces.wings ~= currentWings then
		table.insert(failures, "restyle changed the wrong genome or the wrong piece")
	end
	if restyledGenome.mutation ~= restyleDragon.mutation or restyledGenome.size ~= restyleDragon.size or restyledGenome.tier ~= restyleDragon.tier
		or restyledGenome.uuid ~= restyleDragon.uuid then
		table.insert(failures, "restyle changed the mutation, size, tier or uuid")
	end

	-- Diamond lay speed-up: minutes left x the flat rate rounded up (at least 1 while time is left), then the pending egg is laid at once
	local speedUpRate = HatchOdds.DEFAULT_SPEED_UP_DIAMONDS_PER_MINUTE
	check("speed-up cost, 3 minutes left", NestMath.getSpeedUpCost(odds, 1180, 1000), 3 * speedUpRate, 0)
	check("speed-up cost, 1 second left is at least 1", NestMath.getSpeedUpCost(odds, 1001, 1000), 1, 0)
	check("speed-up cost, timer already run out", NestMath.getSpeedUpCost(odds, 1000, 1000), 0, 0)
	check("speed-up cost, no timer", NestMath.getSpeedUpCost(odds, nil, 1000), 0, 0)
	local rateConfig = table.clone(config)
	rateConfig.economy = { speedUpDiamondsPerMinute = 10 }
	check("speed-up cost with a set rate", NestMath.getSpeedUpCost(HatchOdds.build(rateConfig), 1060, 1000), 10, 0)
	local badSpeedUp = table.clone(config)
	badSpeedUp.economy = { speedUpDiamondsPerMinute = 0 }
	if #HatchOdds.validate(badSpeedUp) < 1 then
		table.insert(failures, "a speedUpDiamondsPerMinute of 0 was not rejected")
	end

	local speedParentA = makeGenome(odds, "fire", "common")
	local speedParentB = makeGenome(odds, "fire", "common")
	speedParentB.uuid = "speed-b"
	local speedNest = NestMath.create(odds, speedParentA, speedParentB, 1, 1000, rollContext)
	if speedNest and speedNest.pendingEgg then
		local seenEgg = speedNest.pendingEgg
		local sped = NestMath.speedUp(odds, speedNest, 1005, rollContext)
		if not sped or sped.genome.uuid ~= seenEgg.uuid then
			table.insert(failures, "the sped-up egg is not the one that was pending")
		end
		check("a sped-up Nest has one egg", #speedNest.eggs, 1, 0)
		check("the next timer starts at the speed-up time", speedNest.nextLayAt or -1, 1035, 0)
		if not speedNest.pendingEgg or speedNest.pendingEgg.uuid == seenEgg.uuid then
			table.insert(failures, "the speed-up did not roll a new pending egg")
		end
		for _ = 1, 2 do
			NestMath.speedUp(odds, speedNest, 1006, rollContext)
		end
		check("the Nest fills to the cap through speed-ups", #speedNest.eggs, 3, 0)
		if speedNest.nextLayAt ~= nil or speedNest.pendingEgg ~= nil then
			table.insert(failures, "a full Nest kept a timer or a pending egg after a speed-up")
		end
		if NestMath.speedUp(odds, speedNest, 1007, rollContext) ~= nil then
			table.insert(failures, "a full Nest could be sped up")
		end
	else
		table.insert(failures, "NestMath.create gave no pending egg for the speed-up test")
	end

	-- a queued removal: the running egg is still laid, then no timer starts and no new egg is rolled
	local removeParentB = makeGenome(odds, "fire", "common")
	removeParentB.uuid = "remove-b"
	local removeNest = NestMath.create(odds, speedParentA, removeParentB, 1, 1000, rollContext)
	if removeNest and removeNest.pendingEgg then
		local queuedEgg = removeNest.pendingEgg
		removeNest.isRemoving = true
		local laidEgg = NestMath.speedUp(odds, removeNest, 1005, rollContext)
		if not laidEgg or laidEgg.genome.uuid ~= queuedEgg.uuid then
			table.insert(failures, "a queued removal changed the egg that was laid")
		end
		if removeNest.nextLayAt ~= nil or removeNest.pendingEgg ~= nil then
			table.insert(failures, "a Nest with a queued removal started another timer")
		end
		check("a queued removal keeps the laid egg", #removeNest.eggs, 1, 0)
		check("a queued removal lays nothing more", #NestMath.advance(odds, removeNest, { now = 100000, rng = rng, makeUuid = rollContext.makeUuid }), 0, 0)
	else
		table.insert(failures, "NestMath.create gave no pending egg for the removal test")
	end

	-- a fresh roll has no parents, keeps its mix and tier, and only rolls pieces of the elements it has
	local fresh = GenomeRoll.rollFresh(odds, { fire = 0.5, water = 0.5, nature = 0 }, 4, "00000000-1111-2222-3333-444444444444", 0, "market", rng)
	if not fresh then
		table.insert(failures, "rollFresh returned nil")
	else
		check("fresh Fire share", fresh.shares.fire, 0.5, 0.0001)
		check("fresh tier", fresh.tier, 4, 0)
		check("fresh parents", #fresh.parents, 0, 0)
		check("fresh generation", fresh.generation, 0, 0)
		check("fresh restyle count", fresh.restyleCount, 0, 0)
		check("fresh ancestry", #fresh.ancestry, 0, 0)
		if fresh.origin ~= "market" then
			table.insert(failures, "fresh origin was " .. fresh.origin)
		end
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
