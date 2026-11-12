--!strict

-- The Hatch Dragons side of the world's weather: which game weather counts, the trait each one gives waiting eggs, and the chance of it.
-- As of 2026-november-11 the chances are the spec's numbers here, not designer tuning; the trait bonuses are in Control/HatchOdds.

local Enums = require("./Enums")
local Genome = require("./Genome")
local HatchOdds = require("./HatchOdds")

local HatchWeather = {}

export type TraitDef = {
	trait: string,
	element: HatchOdds.Element?, -- the element that doubles the chance, nil for none
}

-- the chance per minute of weather that a waiting egg gains the trait, doubled when it is mostly the matching element
HatchWeather.TRAIT_CHANCE_PER_MINUTE = 0.02
HatchWeather.MATCH_MULT = 2
HatchWeather.MATCH_SHARE = 0.5

local TRAITS: { [HatchOdds.Weather]: TraitDef } = {
	rain = { trait = "soaked", element = "water" },
	heatwave = { trait = "toasty", element = "fire" },
	bloomStorm = { trait = "flowered", element = "nature" },
	thunderstorm = { trait = "charged", element = nil },
}

-- the game's Enums.Weather as a Hatch weather; Wind, Starlight and anything else give eggs nothing
function HatchWeather.fromGameWeather(gameWeather: number?): HatchOdds.Weather?
	if gameWeather == Enums.Weather.RAIN then
		return "rain"
	elseif gameWeather == Enums.Weather.HEAT then
		return "heatwave"
	elseif gameWeather == Enums.Weather.BLOOM then
		return "bloomStorm"
	elseif gameWeather == Enums.Weather.THUNDERSTORM then
		return "thunderstorm"
	end
	return nil
end

function HatchWeather.getTraitDef(weather: HatchOdds.Weather): TraitDef
	return TRAITS[weather]
end

-- the chance that an egg gains the weather's trait over dtSec; 0 when it already has the trait
function HatchWeather.getTraitChance(genome: Genome.Genome, weather: HatchOdds.Weather, dtSec: number): number
	local def = TRAITS[weather]
	if table.find(genome.traits, def.trait) then
		return 0
	end
	local perMinute = HatchWeather.TRAIT_CHANCE_PER_MINUTE
	if def.element ~= nil and (genome.shares[def.element] or 0) >= HatchWeather.MATCH_SHARE then
		perMinute = math.min(perMinute * HatchWeather.MATCH_MULT, 1)
	end
	return 1 - (1 - perMinute) ^ (dtSec / 60)
end

return HatchWeather
