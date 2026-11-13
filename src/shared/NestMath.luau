--!strict

-- A Nest's lay schedule: two same-tier parents lay an egg every lay time while fewer than the cap wait. Each egg is rolled when its lay
-- timer starts and held as the pending egg until the timer ends, so a result always exists before anyone pays to see it or speed it up.
-- Pure: the caller passes the time and a RollContext (a Random, a uuid callback and the weather), so the server, the offline catch-up
-- and the self-test share it.

local Genome = require("./Genome")
local GenomeRoll = require("./GenomeRoll")
local GenomeValue = require("./GenomeValue")
local HatchOdds = require("./HatchOdds")
local HatchWeather = require("./HatchWeather")

local NestMath = {}

-- the most eggs that wait in one Nest (the config's nests.eggCap); a full Nest stops laying until one is taken
function NestMath.getEggCap(odds: HatchOdds.Odds): number
	return odds.config.nests.eggCap or HatchOdds.DEFAULT_EGG_CAP
end

export type Egg = {
	genome: Genome.Genome, -- fully rolled at laying, so a skip or a disconnect can't reroll it
	laidAt: number,
}

export type Nest = {
	parentA: Genome.Genome,
	parentB: Genome.Genome,
	eggs: { Egg },
	pendingEgg: Genome.Genome?, -- rolled when the running timer started, it becomes an egg when the timer ends; nil while full
	nextLayAt: number?, -- nil while the Nest is full
	speedBoost: number, -- the speed boosts multiplied together, 1 for none
	isBroken: boolean?, -- the parents could not be rolled, so the Nest lays nothing more
}

-- what rolling an egg needs
export type RollContext = {
	rng: Random,
	makeUuid: () -> string,
	weather: HatchOdds.Weather?, -- the weather when the timer starts, nil for offline catch-up
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

-- Starts a lay timer at startAt: rolls the egg it will lay and sets the due time. A roll that fails (parents that can't breed)
-- marks the Nest broken so it stops instead of retrying every tick.
local function startTimer(odds: HatchOdds.Odds, nest: Nest, startAt: number, context: RollContext)
	local genome = GenomeRoll.rollGenome(odds, {
		parentA = nest.parentA,
		parentB = nest.parentB,
		weather = context.weather,
		uuid = context.makeUuid(),
		bornAt = startAt,
	}, context.rng)
	if not genome then
		nest.isBroken = true
		nest.pendingEgg = nil
		nest.nextLayAt = nil
		return
	end
	nest.pendingEgg = genome
	nest.nextLayAt = startAt + NestMath.getLayTimeSec(odds, nest)
end

-- a new Nest whose first egg is rolled now and due one lay time from now; nil (after a warn) when the pair is invalid
function NestMath.create(
	odds: HatchOdds.Odds,
	parentA: Genome.Genome,
	parentB: Genome.Genome,
	speedBoost: number,
	now: number,
	context: RollContext
): Nest?
	if parentA.tier ~= parentB.tier then
		warn("NestMath: parents of different tiers", parentA.uuid, parentB.uuid)
		return nil
	end

	local nest: Nest = {
		parentA = parentA,
		parentB = parentB,
		eggs = {},
		pendingEgg = nil,
		nextLayAt = nil,
		speedBoost = speedBoost,
	}
	startTimer(odds, nest, now, context)
	if nest.isBroken then
		return nil
	end
	return nest
end

-- Lays every egg that is due by params.now, up to the cap, and returns them. An egg is laid at its due time, so catching up after
-- being offline gives the same eggs as having been online; each laid egg starts the next timer, which rolls the next egg. A full Nest
-- has no timer and no pending egg.
function NestMath.advance(odds: HatchOdds.Odds, nest: Nest, params: AdvanceParams): { Egg }
	local laid: { Egg } = {}
	if nest.isBroken then
		return laid
	end

	local eggCap = NestMath.getEggCap(odds)

	-- a Nest saved full has no timer; if the cap has been raised since, it starts laying again from now
	if nest.nextLayAt == nil and #nest.eggs < eggCap then
		startTimer(odds, nest, params.now, params)
	end

	-- a Nest saved before eggs were rolled at timer start has a timer but no pending egg: roll it now and keep the due time
	if nest.nextLayAt ~= nil and nest.pendingEgg == nil and not nest.isBroken then
		local dueAt = nest.nextLayAt
		startTimer(odds, nest, params.now, params)
		if not nest.isBroken then
			nest.nextLayAt = dueAt
		end
	end

	while #nest.eggs < eggCap and not nest.isBroken do
		local dueAt = nest.nextLayAt
		local pending = nest.pendingEgg
		if dueAt == nil or pending == nil or dueAt > params.now then
			break
		end

		local egg: Egg = { genome = pending, laidAt = dueAt }
		table.insert(nest.eggs, egg)
		table.insert(laid, egg)
		nest.pendingEgg = nil
		if #nest.eggs >= eggCap then
			nest.nextLayAt = nil
		else
			startTimer(odds, nest, dueAt, params)
		end
	end

	if #nest.eggs >= eggCap then
		nest.nextLayAt = nil
		nest.pendingEgg = nil
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

-- The Diamonds to finish the running lay timer now: the minutes left x the flat rate, rounded up, at least 1 while any time is left.
-- 0 when there is no running timer or it has run out.
function NestMath.getSpeedUpCost(odds: HatchOdds.Odds, nextLayAt: number?, now: number): number
	if nextLayAt == nil or nextLayAt <= now then
		return 0
	end
	local economy = odds.config.economy
	local rate = if economy and economy.speedUpDiamondsPerMinute then economy.speedUpDiamondsPerMinute else HatchOdds.DEFAULT_SPEED_UP_DIAMONDS_PER_MINUTE
	return math.max(1, math.ceil((nextLayAt - now) / 60 * rate))
end

-- Finishes the running timer now: the pending egg, rolled when the timer started, is laid, and the next timer starts (and rolls) unless the
-- Nest is now full. Returns the egg, or nil when there is no running timer.
function NestMath.speedUp(odds: HatchOdds.Odds, nest: Nest, now: number, context: RollContext): Egg?
	local pending = nest.pendingEgg
	if nest.isBroken or nest.nextLayAt == nil or pending == nil then
		return nil
	end

	local egg: Egg = { genome = pending, laidAt = now }
	table.insert(nest.eggs, egg)
	nest.pendingEgg = nil
	if #nest.eggs >= NestMath.getEggCap(odds) then
		nest.nextLayAt = nil
	else
		startTimer(odds, nest, now, context)
	end
	return egg
end

-- Removes the egg at the index. A Nest that was full starts its next lay time now, since it was not laying while it waited.
function NestMath.takeEgg(odds: HatchOdds.Odds, nest: Nest, index: number, now: number, context: RollContext): Egg?
	local egg = table.remove(nest.eggs, index)
	if egg and nest.nextLayAt == nil and not nest.isBroken and #nest.eggs < NestMath.getEggCap(odds) then
		startTimer(odds, nest, now, context)
	end
	return egg
end

return NestMath
