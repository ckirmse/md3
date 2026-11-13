--!strict

-- The colour of an element mix: the elements' colours blended in OKLab, weighted by share, so a half Fire half Water mix is a clean purple and
-- not the muddy grey an RGB average gives. Pure.

local Genome = require("./Genome")
local HatchOdds = require("./HatchOdds")

local ElementColor = {}

ElementColor.COLORS = {
	fire = Color3.fromRGB(230, 80, 60),
	water = Color3.fromRGB(45, 125, 215),
	nature = Color3.fromRGB(70, 180, 90),
} :: { [HatchOdds.Element]: Color3 }

local function toLinear(value: number): number
	return if value <= 0.04045 then value / 12.92 else ((value + 0.055) / 1.055) ^ 2.4
end

local function toSrgb(value: number): number
	value = math.clamp(value, 0, 1)
	return if value <= 0.0031308 then 12.92 * value else 1.055 * value ^ (1 / 2.4) - 0.055
end

local function toOklab(color: Color3): (number, number, number)
	local r, g, b = toLinear(color.R), toLinear(color.G), toLinear(color.B)
	local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
	local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
	local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
	return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

local function fromOklab(lightness: number, a: number, b: number): Color3
	local l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ^ 3
	local m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ^ 3
	local s = (lightness - 0.0894841775 * a - 1.2914855480 * b) ^ 3
	return Color3.new(
		toSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
		toSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
		toSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
	)
end

-- the blend of the elements' colours, each weighted by its share; white for a mix with no shares
function ElementColor.blend(shares: Genome.Shares): Color3
	local total, lightness, a, b = 0, 0, 0, 0
	for _, element in HatchOdds.ELEMENTS do
		local share = shares[element] or 0
		if share > 0 then
			local l, ca, cb = toOklab(ElementColor.COLORS[element])
			total += share
			lightness += l * share
			a += ca * share
			b += cb * share
		end
	end
	if total <= 0 then
		return Color3.new(1, 1, 1)
	end
	return fromOklab(lightness / total, a / total, b / total)
end

return ElementColor
