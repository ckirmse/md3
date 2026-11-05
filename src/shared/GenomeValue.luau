--!strict

-- Rarity score, band, sell value, visible scale and lay time of a genome. Pure: every function takes the HatchOdds.Odds.

local HatchOdds = require("./HatchOdds")
local Genome = require("./Genome")

local GenomeValue = {}

-- the sum of the 7 appearance pieces' points; the mutation slot is not scored
function GenomeValue.getScore(odds: HatchOdds.Odds, genome: Genome.Genome): number
	local score = 0
	for _, part in HatchOdds.PARTS do
		local piece = odds.catalog.byId[genome.pieces[part]]
		if piece then
			score += odds.config.pieceScore[piece.rarity]
		else
			warn("GenomeValue: unknown piece", genome.pieces[part], "in", genome.uuid)
		end
	end
	return score
end

-- the highest band whose minScore is at or below the score
function GenomeValue.getBandForScore(odds: HatchOdds.Odds, score: number): HatchOdds.DragonBand
	local result: HatchOdds.DragonBand = odds.config.dragonBands[1].name
	for _, band in odds.config.dragonBands do
		if score >= band.minScore then
			result = band.name
		end
	end
	return result
end

function GenomeValue.getBand(odds: HatchOdds.Odds, genome: Genome.Genome): HatchOdds.DragonBand
	return GenomeValue.getBandForScore(odds, GenomeValue.getScore(odds, genome))
end

-- the band of the parents' mean score, used by the tier jump and the lay time
function GenomeValue.getAverageBand(odds: HatchOdds.Odds, parentA: Genome.Genome, parentB: Genome.Genome): HatchOdds.DragonBand
	local mean = (GenomeValue.getScore(odds, parentA) + GenomeValue.getScore(odds, parentB)) / 2
	return GenomeValue.getBandForScore(odds, mean)
end

-- all 7 pieces from one element and every one Rare or better
function GenomeValue.isPure(odds: HatchOdds.Odds, genome: Genome.Genome): boolean
	local element: HatchOdds.Element? = nil
	for _, part in HatchOdds.PARTS do
		local piece = odds.catalog.byId[genome.pieces[part]]
		if not piece or piece.rarity == "common" or piece.rarity == "uncommon" then
			return false
		end
		if element ~= nil and piece.element ~= element then
			return false
		end
		element = piece.element
	end
	return true
end

function GenomeValue.getMutationMult(odds: HatchOdds.Odds, mutation: HatchOdds.MutationId): number
	for _, def in odds.config.mutations do
		if def.id == mutation then
			return def.valueMult
		end
	end
	return 1
end

function GenomeValue.getTraitBonus(odds: HatchOdds.Odds, traits: { string }): number
	local bonus = 0
	for _, trait in traits do
		bonus += odds.config.traitBonus[trait] or 0
	end
	return bonus
end

-- Base x (1 + Score + Pure) x Size^2 x Mutation x (1 + Traits); callers round
function GenomeValue.getValue(odds: HatchOdds.Odds, genome: Genome.Genome): number
	local config = odds.config
	local tier = config.tiers[genome.tier]
	if not tier then
		warn("GenomeValue: unknown tier", genome.tier, "in", genome.uuid)
		return 0
	end
	local pure = if GenomeValue.isPure(odds, genome) then config.pureBonus else 0
	local scoreFactor = 1 + GenomeValue.getScore(odds, genome) + pure
	local sizeFactor = genome.size * genome.size
	local mutationFactor = GenomeValue.getMutationMult(odds, genome.mutation)
	local traitFactor = 1 + GenomeValue.getTraitBonus(odds, genome.traits)
	return tier.baseValue * scoreFactor * sizeFactor * mutationFactor * traitFactor
end

-- the tier's base scale, moved within its range by the size stat (squeezed above visibleSizeCap), +15% for a Giant
function GenomeValue.getVisibleScale(odds: HatchOdds.Odds, genome: Genome.Genome): number
	local config = odds.config
	local tier = config.tiers[genome.tier]
	if not tier then
		warn("GenomeValue: unknown tier", genome.tier, "in", genome.uuid)
		return 1
	end
	local position = (math.min(genome.size, config.visibleSizeCap) - config.sizeMin) / (config.visibleSizeCap - config.sizeMin)
	local within = config.visibleMin + config.visibleSpan * math.clamp(position, 0, 1)
	return tier.baseScale * within * (if genome.isGiant then config.giantVisible else 1)
end

-- tier base x the parents' average band x speed boosts; the boosts multiply together and never go below layBoostFloor
function GenomeValue.getLayTimeSec(odds: HatchOdds.Odds, tier: number, averageBand: HatchOdds.DragonBand, speedBoost: number): number
	local config = odds.config
	local tierData = config.tiers[tier]
	if not tierData then
		warn("GenomeValue: unknown tier", tier)
		return 0
	end
	return tierData.layTimeSec * config.layTimeMult[averageBand] * math.max(speedBoost, config.layBoostFloor)
end

return GenomeValue
