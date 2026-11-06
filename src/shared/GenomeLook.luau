--!strict

-- What a dragon looks like, decided from its genome: for each visible slot, which existing dragon model it borrows the part from.
-- Pure, so the client builder and the self-test read the same rules; the builder (ClientDragonKit) does the Instance work.

local Genome = require("./Genome")
local HatchOdds = require("./HatchOdds")

local GenomeLook = {}

export type Color = "Red" | "Blue" | "Green"
export type ModelRarity = "Common" | "Uncommon" | "Rare" | "Epic"

-- the old dragon model (Dragon<Color><Rarity><Level>) a slot is taken from
export type Donor = { color: Color, rarity: ModelRarity }

export type Look = {
	wings: Donor,
	tail: Donor,
	spikes: Donor,
	eyes: Donor,
	bodyTexture: Donor,
	mutation: HatchOdds.MutationId,
}

local COLOR: { [HatchOdds.Element]: Color } = { fire = "Red", water = "Blue", nature = "Green" }

-- the art is the same for Common, Uncommon and Rare in every slot but the body texture, so a Legendary piece borrows the Epic model and the rest the Common one
local SHAPE_RARITY: { [HatchOdds.PieceRarity]: ModelRarity } = {
	common = "Common",
	uncommon = "Common",
	rare = "Common",
	legendary = "Epic",
}

local TEXTURE_RARITY: { [HatchOdds.PieceRarity]: ModelRarity } = {
	common = "Common",
	uncommon = "Uncommon",
	rare = "Rare",
	legendary = "Epic",
}

local function getDonor(odds: HatchOdds.Odds, genome: Genome.Genome, part: HatchOdds.Part, rarities: { [HatchOdds.PieceRarity]: ModelRarity }): Donor?
	local piece = odds.catalog.byId[genome.pieces[part]]
	if not piece then
		warn("GenomeLook: unknown piece", genome.pieces[part], "in", genome.uuid)
		return nil
	end
	return { color = COLOR[piece.element], rarity = rarities[piece.rarity] }
end

-- nil (after a warn) when the genome names a piece the config doesn't have
function GenomeLook.get(odds: HatchOdds.Odds, genome: Genome.Genome): Look?
	local wings = getDonor(odds, genome, "wings", SHAPE_RARITY)
	local tail = getDonor(odds, genome, "tailSpike", SHAPE_RARITY)
	local spikes = getDonor(odds, genome, "backSpikes", SHAPE_RARITY)
	local eyes = getDonor(odds, genome, "faceType", SHAPE_RARITY)
	local bodyTexture = getDonor(odds, genome, "meshTexture", TEXTURE_RARITY)
	if not (wings and tail and spikes and eyes and bodyTexture) then
		return nil
	end
	return {
		wings = wings,
		tail = tail,
		spikes = spikes,
		eyes = eyes,
		bodyTexture = bodyTexture,
		mutation = genome.mutation,
	}
end

return GenomeLook
