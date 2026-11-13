--!strict

-- How the breeding screens say a chance in words: "5 in 100" for the lucky-egg odds, "about 4 in 10" for the likely rarity.
-- Pure, so the screens and the self-test read the same rules.

local OddsFormat = {}

-- "5 in 100", "under 1 in 100" for anything below 1%, "none" for 0, "every egg" for 100%
function OddsFormat.inHundred(chance: number): string
	if chance <= 0 then
		return "none"
	end
	if chance >= 0.995 then
		return "every egg"
	end
	if chance < 0.01 then
		return "under 1 in 100"
	end
	return ("%d in 100"):format(math.floor(chance * 100 + 0.5))
end

-- "about 4 in 10", clamped to 1 to 9 so neither "0 in 10" nor "10 in 10" shows; "almost every egg" from 95% up
function OddsFormat.aboutInTen(chance: number): string
	if chance >= 0.95 then
		return "almost every egg"
	end
	return ("about %d in 10"):format(math.clamp(math.floor(chance * 10 + 0.5), 1, 9))
end

return OddsFormat
