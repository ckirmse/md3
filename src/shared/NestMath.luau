--!strict

-- A Nest's lay schedule: two same-tier parents lay an egg every lay time while fewer than the cap wait, each rolled when it is laid.
-- Pure: the caller passes the time, a Random and the and uuid callback, so the server, the offline catch-up and the self-test share it.

local Genome = require("./Genome")
local GenomeRoll = require("./GenomeRoll")
local GenomeValue = require("./GenomeValue")
local HatchOdds = require("./HatchOdds")
local HatchWeather = require("./HatchWeather")

local NestMath = {}

-- the most eggs that wait in one Nest (the config's eggCap); a full Nest stops laying until one is taken
function NestMath.getEggCap(odds: HatchOdds.Odds): number
	return odds.config.eggCap or HatchOdds.DEFAULT_EGG_CAP
end

export type Egg = {
	genome: Genome.Genome, -- fully rolled at laying, so a skip or a disconnect can't reroll it
	laidAt: number,
}

export type Nest = {
	parentA: Genome.Genome,
	parentB: Genome.Genome,
	eggs: { Egg },
	nextLayAt: number?, -- nil while the Nest is full
	speedBoost: number, -- the speed boosts multiplied together, 1 for none
}

export type AdvanceParams = {
	now: number,
	rng: Random,
	makeUuid: () -> string,
	weather: HatchOdds.Weather?, -- the weather during this advance, nil for offline catch-up
}

-- seconds between eggs: the tier's lay time x the parents' average band x the speed boosts
function NestMath.getLayTimeSec(odds: HatchOdds.Odds, nest: Nest): number
	return GenomeValue.getPairLayTimeSec(odds, nest.parentA, nest.parentB, nest.speedBoost)
end

-- a new Nest whose first egg is due one lay time from now; nil (after a warn) when the pair is invalid
function NestMath.create(
	odds: HatchOdds.Odds,
	parentA: Genome.Genome,
	parentB: Genome.Genome,
	speedBoost: number,
	now: number
): Nest?
	if parentA.tier ~= parentB.tier then
		warn("NestMath: parents of different tiers", parentA.uuid, parentB.uuid)
		return nil
	end

	local nest: Nest = {
		parentA = parentA,
		parentB = parentB,
		eggs = {},
		nextLayAt = nil,
		speedBoost = speedBoost,
	}
	nest.nextLayAt = now + NestMath.getLayTimeSec(odds, nest)
	return nest
end

-- Lays every egg that is due by params.now, up to the cap, and returns them. An egg is laid at its due time, so catching up after
-- being offline gives the same eggs as having been online; a full Nest has no due time and lays nothing.
function NestMath.advance(odds: HatchOdds.Odds, nest: Nest, params: AdvanceParams): { Egg }
	local laid: { Egg } = {}
	local layTimeSec = NestMath.getLayTimeSec(odds, nest)

	local eggCap = NestMath.getEggCap(odds)

	-- a Nest saved full has no timer; if the cap has been raised since, it starts laying again from now
	if nest.nextLayAt == nil and #nest.eggs < eggCap then
		nest.nextLayAt = params.now + layTimeSec
	end

	while #nest.eggs < eggCap do
		local dueAt = nest.nextLayAt
		if dueAt == nil or dueAt > params.now then
			break
		end

		local genome = GenomeRoll.rollGenome(odds, {
			parentA = nest.parentA,
			parentB = nest.parentB,
			weather = params.weather,
			uuid = params.makeUuid(),
			bornAt = dueAt,
		}, params.rng)
		if not genome then
			-- the parents can't breed, so stop instead of retrying forever
			nest.nextLayAt = nil
			break
		end

		local egg: Egg = { genome = genome, laidAt = dueAt }
		table.insert(nest.eggs, egg)
		table.insert(laid, egg)
		nest.nextLayAt = dueAt + layTimeSec
	end

	if #nest.eggs >= eggCap then
		nest.nextLayAt = nil
	end
	return laid
end

-- Gives each waiting egg its chance at the weather's trait for dtSec of weather; returns how many eggs gained one.
-- Traits are rolled on waiting eggs only, so a full Nest is the gamble the spec describes.
function NestMath.growTraits(odds: HatchOdds.Odds, nest: Nest, weather: HatchOdds.Weather?, dtSec: number, rng: Random): number
	if not weather then
		return 0
	end
	local def = HatchWeather.getTraitDef(odds.config, weather)
	if not def then
		return 0
	end
	local gained = 0
	for _, egg in nest.eggs do
		if rng:NextNumber() < HatchWeather.getTraitChance(odds.config, egg.genome, weather, dtSec) then
			table.insert(egg.genome.traits, def.trait)
			gained += 1
		end
	end
	return gained
end

-- Removes the egg at the index. A Nest that was full starts its next lay time now, since it was not laying while it waited.
function NestMath.takeEgg(odds: HatchOdds.Odds, nest: Nest, index: number, now: number): Egg?
	local egg = table.remove(nest.eggs, index)
	if egg and nest.nextLayAt == nil and #nest.eggs < NestMath.getEggCap(odds) then
		nest.nextLayAt = now + NestMath.getLayTimeSec(odds, nest)
	end
	return egg
end

return NestMath
