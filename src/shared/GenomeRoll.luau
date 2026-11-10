--!strict

-- The offspring roll: one weighted pick per part, the mutation slot, size, tier jump and locks.
-- Pure: every function takes the HatchOdds.Odds and a Random, so the server rolls and the odds panel reads the same weights.

local HatchOdds = require("./HatchOdds")
local Genome = require("./Genome")
local GenomeValue = require("./GenomeValue")

local GenomeRoll = {}

export type Weighted = { id: string, weight: number }

export type RollParams = {
	parentA: Genome.Genome,
	parentB: Genome.Genome,
	locks: { [HatchOdds.Part]: string }?, -- part -> the piece id to copy, which one of the parents must have
	weather: HatchOdds.Weather?, -- the weather active when the egg is laid
	traits: { string }?,
	uuid: string,
	bornAt: number,
}

-- a baby's share of each element is the exact average of its parents'
function GenomeRoll.mixShares(a: Genome.Shares, b: Genome.Shares): Genome.Shares
	local shares: Genome.Shares = {}
	for _, element in HatchOdds.ELEMENTS do
		shares[element] = ((a[element] or 0) + (b[element] or 0)) / 2
	end
	return shares
end

-- w = the piece's weight x share of its element x (1 + its rarity's buff x parents that have it); pieces with a zero share can't roll
function GenomeRoll.getPieceWeights(odds: HatchOdds.Odds, part: HatchOdds.Part, shares: Genome.Shares, parentPieceIds: { string }): { Weighted }
	local config = odds.config
	local list: { Weighted } = {}
	for _, piece in odds.catalog.byPart[part] do
		local share = shares[piece.element] or 0
		if share > 0 then
			local parentsWithIt = 0
			for _, id in parentPieceIds do
				if id == piece.id then
					parentsWithIt += 1
				end
			end
			local weight = piece.weight * share * (1 + config.pieceParentBuff[piece.rarity] * parentsWithIt)
			table.insert(list, { id = piece.id, weight = weight })
		end
	end
	return list
end

-- Normal first, then each mutation; every non-Normal weight is capped and Normal takes what is left of mutationTotal
function GenomeRoll.getMutationWeights(
	odds: HatchOdds.Odds,
	shares: Genome.Shares,
	parentMutations: { HatchOdds.MutationId },
	weather: HatchOdds.Weather?
): { Weighted }
	local config = odds.config
	local list: { Weighted } = {}
	local used = 0
	for _, def in config.mutations do
		local share = 1
		if def.element ~= nil then
			share = shares[def.element] or 0
		end
		if share > 0 then
			local parentsWithIt = 0
			for _, id in parentMutations do
				if id == def.id then
					parentsWithIt += 1
				end
			end
			local weatherHit = weather ~= nil and def.weather == weather
			local buff = 1 + config.mutationParentBuff * parentsWithIt + (if weatherHit then config.weatherMutationBuff else 0)
			local weight = math.min(def.baseWeight * share * buff, config.mutationWeightCap)
			if weight > 0 then
				table.insert(list, { id = def.id, weight = weight })
				used += weight
			end
		end
	end
	table.insert(list, 1, { id = "normal", weight = math.max(config.mutationTotal - used, 0) })
	return list
end

-- a weighted pick; nil when the list is empty or every weight is zero
function GenomeRoll.pick(list: { Weighted }, rng: Random): string?
	local total = 0
	for _, entry in list do
		total += entry.weight
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	for _, entry in list do
		roll -= entry.weight
		if roll < 0 then
			return entry.id
		end
	end
	return list[#list].id -- float rounding left a sliver of roll
end

-- (parents' average x sizeParentWeight + sizeBase) x jitter, a giantChance roll at x giantMult, clamped; returns the size and whether it is a Giant
function GenomeRoll.rollSize(odds: HatchOdds.Odds, parentSizes: { number }, rng: Random): (number, boolean)
	local config = odds.config
	local sum = 0
	for _, size in parentSizes do
		sum += size
	end
	local average = sum / math.max(#parentSizes, 1)
	local jitter = config.sizeJitterMin + (config.sizeJitterMax - config.sizeJitterMin) * rng:NextNumber()
	local size = (average * config.sizeParentWeight + config.sizeBase) * jitter
	local isGiant = rng:NextNumber() < config.giantChance
	if isGiant then
		size *= config.giantMult
	end
	return math.clamp(size, config.sizeMin, config.sizeMax), isGiant
end

function GenomeRoll.getTierJumpChance(odds: HatchOdds.Odds, averageBand: HatchOdds.DragonBand): number
	local config = odds.config
	return (config.tierJumpBaseWeight + config.tierJumpBonus[averageBand]) / config.tierJumpTotal
end

-- the baby's tier: the parents' tier, or one above on a jump; the top tier can't jump
function GenomeRoll.rollTier(odds: HatchOdds.Odds, tier: number, averageBand: HatchOdds.DragonBand, rng: Random): number
	if tier >= #odds.config.tiers then
		return tier
	end
	if rng:NextNumber() < GenomeRoll.getTierJumpChance(odds, averageBand) then
		return tier + 1
	end
	return tier
end

-- Lock Tokens charged per egg: each locked piece costs by its rarity
function GenomeRoll.getLockCost(odds: HatchOdds.Odds, locks: { [HatchOdds.Part]: string }): number
	local cost = 0
	for _, id in locks do
		local piece = odds.catalog.byId[id]
		if piece then
			cost += odds.config.lockTokenCost[piece.rarity]
		end
	end
	return cost
end

-- why these locks can't be used with these parents (a locked piece neither has, or too many); nil when they can
function GenomeRoll.getLockProblem(odds: HatchOdds.Odds, parentA: Genome.Genome, parentB: Genome.Genome, locks: { [HatchOdds.Part]: string }): string?
	local lockCount = 0
	for part, id in locks do
		lockCount += 1
		if id ~= parentA.pieces[part] and id ~= parentB.pieces[part] then
			return "locked piece is not from a parent: " .. part .. " " .. id
		end
	end
	if lockCount > odds.config.maxLocks then
		return "too many locks: " .. lockCount
	end
	return nil
end

-- the parents of a same-tier pair give a baby; nil (after a warn) when the pair or the locks are invalid
function GenomeRoll.rollGenome(odds: HatchOdds.Odds, params: RollParams, rng: Random): Genome.Genome?
	local config = odds.config
	local parentA, parentB = params.parentA, params.parentB
	if parentA.tier ~= parentB.tier then
		warn("GenomeRoll: parents of different tiers", parentA.uuid, parentB.uuid)
		return nil
	end

	local locks = params.locks or {}
	local lockProblem = GenomeRoll.getLockProblem(odds, parentA, parentB, locks)
	if lockProblem then
		warn("GenomeRoll:", lockProblem)
		return nil
	end

	local shares = GenomeRoll.mixShares(parentA.shares, parentB.shares)
	local pieces: { [HatchOdds.Part]: string } = {}
	for _, part in HatchOdds.PARTS do
		local locked = locks[part]
		if locked then
			pieces[part] = locked
		else
			local weights = GenomeRoll.getPieceWeights(odds, part, shares, { parentA.pieces[part], parentB.pieces[part] })
			local id = GenomeRoll.pick(weights, rng)
			if not id then
				warn("GenomeRoll: no piece can roll for", part)
				return nil
			end
			pieces[part] = id
		end
	end

	local mutationWeights = GenomeRoll.getMutationWeights(odds, shares, { parentA.mutation, parentB.mutation }, params.weather)
	local mutation = (GenomeRoll.pick(mutationWeights, rng) or "normal") :: HatchOdds.MutationId
	local size, isGiant = GenomeRoll.rollSize(odds, { parentA.size, parentB.size }, rng)
	local averageBand = GenomeValue.getAverageBand(odds, parentA, parentB)
	local tier = GenomeRoll.rollTier(odds, parentA.tier, averageBand, rng)

	return {
		uuid = params.uuid,
		code = Genome.makeCode(params.uuid),
		tier = tier,
		shares = shares,
		pieces = pieces,
		size = size,
		isGiant = isGiant,
		mutation = mutation,
		traits = table.clone(params.traits or {}),
		parents = { parentA.uuid, parentB.uuid },
		bornAt = params.bornAt,
		oddsVersion = config.version,
	}
end

-- a dragon with no parents (Market stock, dev grants): the same per-part roll with no parent buff, no weather and no tier jump
function GenomeRoll.rollFresh(odds: HatchOdds.Odds, shares: Genome.Shares, tier: number, uuid: string, bornAt: number, rng: Random): Genome.Genome?
	local pieces: { [HatchOdds.Part]: string } = {}
	for _, part in HatchOdds.PARTS do
		local id = GenomeRoll.pick(GenomeRoll.getPieceWeights(odds, part, shares, {}), rng)
		if not id then
			warn("GenomeRoll: no piece can roll for", part)
			return nil
		end
		pieces[part] = id
	end

	local mutation = (GenomeRoll.pick(GenomeRoll.getMutationWeights(odds, shares, {}, nil), rng) or "normal") :: HatchOdds.MutationId
	local size, isGiant = GenomeRoll.rollSize(odds, { 1 }, rng)

	return {
		uuid = uuid,
		code = Genome.makeCode(uuid),
		tier = tier,
		shares = table.clone(shares),
		pieces = pieces,
		size = size,
		isGiant = isGiant,
		mutation = mutation,
		traits = {},
		parents = {},
		bornAt = bornAt,
		oddsVersion = odds.config.version,
	}
end

return GenomeRoll
