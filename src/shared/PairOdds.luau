--!strict

-- What a pair of parents will lay: every part's piece chances, the mutation chances, the rarity chances, the size range and the tier jump.
-- Pure: it reads the same weights the roll uses (GenomeRoll), so the pairing screen and the server's eggs can't disagree.

local Genome = require("./Genome")
local GenomeRoll = require("./GenomeRoll")
local GenomeValue = require("./GenomeValue")
local HatchOdds = require("./HatchOdds")

local PairOdds = {}

export type Chance = { id: string, chance: number }

export type Result = {
	tier: number,
	shares: Genome.Shares,
	parts: { [HatchOdds.Part]: { Chance } }, -- by chance, highest first
	mutations: { Chance }, -- by chance, highest first, with "normal" among them
	bands: { [HatchOdds.DragonBand]: number }, -- the chance of each rarity band
	expectedScore: number,
	expectedValue: number, -- a rough sell value: the average score and size, no mutation or Pure bonus
	sizeMin: number,
	sizeMax: number,
	giantChance: number,
	giantSizeMax: number,
	tierJumpChance: number,
	layTimeSec: number, -- before speed boosts
}

-- weights to chances that add up to 1, highest first
function PairOdds.toChances(list: { GenomeRoll.Weighted }): { Chance }
	local total = 0
	for _, entry in list do
		total += entry.weight
	end
	local chances: { Chance } = {}
	if total <= 0 then
		return chances
	end
	for _, entry in list do
		if entry.weight > 0 then
			table.insert(chances, { id = entry.id, chance = entry.weight / total })
		end
	end
	table.sort(chances, function(a: Chance, b: Chance): boolean
		if a.chance ~= b.chance then
			return a.chance > b.chance
		end
		return a.id < b.id
	end)
	return chances
end

-- nil when the parents can't breed (different tiers)
function PairOdds.get(odds: HatchOdds.Odds, parentA: Genome.Genome, parentB: Genome.Genome, weather: HatchOdds.Weather?): Result?
	if parentA.tier ~= parentB.tier then
		return nil
	end
	local config = odds.config
	local tier = config.tiers[parentA.tier]
	if not tier then
		return nil
	end

	local shares = GenomeRoll.mixShares(parentA.shares, parentB.shares)

	local parts: { [HatchOdds.Part]: { Chance } } = {}
	-- the chance of each total score over the 7 parts
	local scoreChances: { [number]: number } = { [0] = 1 }
	for _, part in HatchOdds.PARTS do
		local chances = PairOdds.toChances(GenomeRoll.getPieceWeights(odds, part, shares, { parentA.pieces[part], parentB.pieces[part] }))
		parts[part] = chances

		local next: { [number]: number } = {}
		for score, scoreChance in scoreChances do
			for _, entry in chances do
				local piece = odds.catalog.byId[entry.id]
				local points = if piece then config.pieceScore[piece.rarity] else 0
				next[score + points] = (next[score + points] or 0) + scoreChance * entry.chance
			end
		end
		scoreChances = next
	end

	local bands = {} :: { [HatchOdds.DragonBand]: number }
	for _, band in HatchOdds.DRAGON_BANDS do
		bands[band] = 0
	end
	local expectedScore = 0
	for score, chance in scoreChances do
		local band = GenomeValue.getBandForScore(odds, score)
		bands[band] += chance
		expectedScore += score * chance
	end

	local mutations = PairOdds.toChances(GenomeRoll.getMutationWeights(odds, shares, { parentA.mutation, parentB.mutation }, weather))

	local average = (parentA.size + parentB.size) / 2
	local base = average * config.sizeParentWeight + config.sizeBase
	local sizeMin = math.clamp(base * config.sizeJitterMin, config.sizeMin, config.sizeMax)
	local sizeMax = math.clamp(base * config.sizeJitterMax, config.sizeMin, config.sizeMax)
	local giantSizeMax = math.clamp(base * config.sizeJitterMax * config.giantMult, config.sizeMin, config.sizeMax)
	local meanSize = (sizeMin + sizeMax) / 2

	local averageBand = GenomeValue.getAverageBand(odds, parentA, parentB)
	return {
		tier = parentA.tier,
		shares = shares,
		parts = parts,
		mutations = mutations,
		bands = bands,
		expectedScore = expectedScore,
		expectedValue = tier.baseValue * (1 + expectedScore) * meanSize * meanSize,
		sizeMin = sizeMin,
		sizeMax = sizeMax,
		giantChance = config.giantChance,
		giantSizeMax = giantSizeMax,
		tierJumpChance = if parentA.tier >= #config.tiers then 0 else GenomeRoll.getTierJumpChance(odds, averageBand),
		layTimeSec = GenomeValue.getPairLayTimeSec(odds, parentA, parentB, 1),
	}
end

return PairOdds
