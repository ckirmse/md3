--!strict

-- Which legacy dragon item a genome is built on: the head shape's element picks the color, the rarity band the rarity, the tier the level.
-- The item supplies the model, rarity row and element the old dragon systems read; the genome supplies the look and the sell value.

local Genome = require("./Genome")
local GenomeValue = require("./GenomeValue")
local HatchOdds = require("./HatchOdds")

local GenomeItemName = {}

local COLOR: { [HatchOdds.Element]: string } = { fire = "Red", water = "Blue", nature = "Green" }

-- the legacy items have 4 rarities, so Legendary and Mythic share Epic
local RARITY_SUFFIX: { [HatchOdds.DragonBand]: string } = {
	common = "",
	uncommon = " UC",
	rare = " R",
	epic = " E",
	legendary = " E",
	mythic = " E",
}

-- e.g. "Red R Dragon Level 7"; nil (after a warn) when the genome names a piece or tier the config doesn't have
function GenomeItemName.get(odds: HatchOdds.Odds, genome: Genome.Genome): string?
	local head = odds.catalog.byId[genome.pieces.headShape]
	if not head then
		warn("GenomeItemName: unknown head shape", genome.pieces.headShape, "in", genome.uuid)
		return nil
	end
	local tier = odds.config.tiers[genome.tier]
	if not tier then
		warn("GenomeItemName: unknown tier", genome.tier, "in", genome.uuid)
		return nil
	end
	local band = GenomeValue.getBand(odds, genome)
	return ("%s%s Dragon Level %d"):format(COLOR[head.element], RARITY_SUFFIX[band], tier.dragonLevel)
end

return GenomeItemName
