--!strict

-- The Hatch Dragons side of the world's weather: which game weather counts, the trait each one gives waiting eggs, and the chance of it.
-- The trait table and chances are the optional weather section of Control/HatchSystems (the spec's numbers when absent); the trait bonuses are in Control/HatchOdds.

local Enums = require("./Enums")
local Genome = require("./Genome")
local HatchOdds = require("./HatchOdds")

local HatchWeather = {}

-- the numbers in use: the Studio config's, or the defaults for the fields it leaves out
export type Settings = {
	chancePerMinute: number,
	matchMult: number,
	matchShare: number,
	traits: { [HatchOdds.Weather]: HatchOdds.WeatherTrait },
}

function HatchWeather.getSettings(config: HatchOdds.Config): Settings
	local section: HatchOdds.WeatherConfig = config.weather or {}
	return {
		chancePerMinute = section.traitChancePerMinute or HatchOdds.DEFAULT_WEATHER_TRAIT_CHANCE_PER_MINUTE,
		matchMult = section.traitMatchMult or HatchOdds.DEFAULT_WEATHER_TRAIT_MATCH_MULT,
		matchShare = section.traitMatchShare or HatchOdds.DEFAULT_WEATHER_TRAIT_MATCH_SHARE,
		traits = section.traits or HatchOdds.DEFAULT_WEATHER_TRAITS,
	}
end

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

-- the trait a weather gives, nil when the config gives it none
function HatchWeather.getTraitDef(config: HatchOdds.Config, weather: HatchOdds.Weather): HatchOdds.WeatherTrait?
	return HatchWeather.getSettings(config).traits[weather]
end

-- the chance that an egg gains the weather's trait over dtSec; 0 when it already has the trait or the weather gives none
function HatchWeather.getTraitChance(config: HatchOdds.Config, genome: Genome.Genome, weather: HatchOdds.Weather, dtSec: number): number
	local settings = HatchWeather.getSettings(config)
	local def = settings.traits[weather]
	if not def or table.find(genome.traits, def.trait) then
		return 0
	end
	local perMinute = settings.chancePerMinute
	if def.element ~= nil and (genome.shares[def.element] or 0) >= settings.matchShare then
		perMinute = math.min(perMinute * settings.matchMult, 1)
	end
	return 1 - (1 - perMinute) ^ (dtSec / 60)
end

return HatchWeather
