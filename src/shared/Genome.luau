--!strict

-- The record of one dragon or egg: everything the server rolls and stores. Pieces are ids from the HatchOdds piece list.

local HatchOdds = require("./HatchOdds")

local Genome = {}

-- how many generations of ancestors a dragon carries: parents, grandparents, great-grandparents
Genome.LINEAGE_GENERATIONS = 3

export type Shares = { [HatchOdds.Element]: number } -- the element shares, adding up to 1

-- where a dragon with no parents came from; a bred dragon is "bred"
export type Origin = "bred" | "market" | "dev"

-- A parent as it was the moment its baby was laid, frozen so a later Restyle or a sale doesn't change the baby's family tree.
-- ancestry holds this ancestor's own parents, cut off after LINEAGE_GENERATIONS generations from the baby.
export type Ancestor = {
	uuid: string,
	code: string,
	tier: number,
	pieces: { [HatchOdds.Part]: string },
	mutation: HatchOdds.MutationId,
	origin: Origin,
	generation: number,
	ancestry: { Ancestor },
}

export type Genome = {
	uuid: string,
	code: string, -- 8-character display code
	tier: number, -- index into Config.tiers
	shares: Shares,
	pieces: { [HatchOdds.Part]: string },
	size: number,
	isGiant: boolean,
	mutation: HatchOdds.MutationId,
	traits: { string },
	parents: { string }, -- parent uuids, empty for a founder
	origin: Origin,
	restyleCount: number, -- how many times this dragon has been restyled; the next restyle costs tier x 2^restyleCount
	generation: number, -- 0 for a founder, otherwise the higher parent generation + 1
	ancestry: { Ancestor }, -- snapshots of the parents, which hold theirs, up to LINEAGE_GENERATIONS deep; empty for a founder
	bornAt: number,
	oddsVersion: number, -- Config.version it was rolled with
}

-- the first 8 letters and digits of the uuid, uppercase
function Genome.makeCode(uuid: string): string
	local clean = uuid:gsub("[^%w]", "")
	return clean:sub(1, 8):upper()
end

-- Genomes saved before lineage or restyles existed lack those fields: they count as founders (bred ones as bred) with no ancestry
-- to show, and as never restyled.
function Genome.fillLineage(genome: Genome)
	local loose: any = genome
	if loose.origin == nil then
		loose.origin = if #genome.parents > 0 then "bred" else "dev"
	end
	if loose.generation == nil then
		loose.generation = if #genome.parents > 0 then 1 else 0
	end
	if loose.ancestry == nil then
		loose.ancestry = {}
	end
	if loose.restyleCount == nil then
		loose.restyleCount = 0
	end
end

-- the frozen copy of a parent for its baby's ancestry; levels is how many generations (this one included) the copy may hold
function Genome.snapshot(genome: Genome, levels: number): Ancestor
	Genome.fillLineage(genome)
	local ancestry: { Ancestor } = {}
	if levels > 1 then
		for _, ancestor in genome.ancestry do
			table.insert(ancestry, Genome.snapshot(ancestor :: any, levels - 1))
		end
	end
	return {
		uuid = genome.uuid,
		code = genome.code,
		tier = genome.tier,
		pieces = table.clone(genome.pieces),
		mutation = genome.mutation,
		origin = genome.origin,
		generation = genome.generation,
		ancestry = ancestry,
	}
end

return Genome
