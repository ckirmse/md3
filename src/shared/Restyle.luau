--!strict

-- Restyle: re-roll one appearance piece of a kept dragon. The piece comes from the dragon's own colour mix with no parent buff, the
-- current piece is left out so the result always changes, and each restyle on the same dragon costs double the last.
-- Pure: every function takes the HatchOdds.Odds, so the Restyle screen shows the same chances the server rolls on.

local Genome = require("./Genome")
local GenomeRoll = require("./GenomeRoll")
local HatchOdds = require("./HatchOdds")
local PairOdds = require("./PairOdds")

local Restyle = {}

-- Restyle Tokens for the dragon's next restyle: its tier number x 2^(restyles so far)
function Restyle.getTokenCost(genome: Genome.Genome): number
	Genome.fillLineage(genome)
	return genome.tier * 2 ^ genome.restyleCount
end

-- Diamonds for the same restyle, at the token pack rate
function Restyle.getDiamondCost(odds: HatchOdds.Odds, genome: Genome.Genome): number
	local economy = odds.config.economy
	local rate = if economy and economy.restyleDiamondsPerToken then economy.restyleDiamondsPerToken else HatchOdds.DEFAULT_RESTYLE_DIAMONDS_PER_TOKEN
	return Restyle.getTokenCost(genome) * rate
end

-- the part's piece weights from the dragon's own mix, with the piece it has now removed
local function getWeights(odds: HatchOdds.Odds, genome: Genome.Genome, part: HatchOdds.Part): { GenomeRoll.Weighted }
	local list: { GenomeRoll.Weighted } = {}
	for _, entry in GenomeRoll.getPieceWeights(odds, part, genome.shares, {}) do
		if entry.id ~= genome.pieces[part] then
			table.insert(list, entry)
		end
	end
	return list
end

-- every piece the part can become and its chance, highest first
function Restyle.getChances(odds: HatchOdds.Odds, genome: Genome.Genome, part: HatchOdds.Part): { PairOdds.Chance }
	return PairOdds.toChances(getWeights(odds, genome, part))
end

-- the new piece id; nil when nothing else can roll for this part
function Restyle.roll(odds: HatchOdds.Odds, genome: Genome.Genome, part: HatchOdds.Part, rng: Random): string?
	return GenomeRoll.pick(getWeights(odds, genome, part), rng)
end

-- the genome after the restyle: the same dragon with the new piece and one more restyle; the mutation, size and tier never change
function Restyle.apply(genome: Genome.Genome, part: HatchOdds.Part, pieceId: string): Genome.Genome
	Genome.fillLineage(genome)
	local restyled = table.clone(genome)
	restyled.pieces = table.clone(genome.pieces)
	restyled.pieces[part] = pieceId
	restyled.traits = table.clone(genome.traits)
	restyled.restyleCount = genome.restyleCount + 1
	return restyled
end

return Restyle
