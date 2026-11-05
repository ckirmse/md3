--!strict

-- The record of one dragon or egg: everything the server rolls and stores. Pieces are ids from the HatchOdds piece list.

local HatchOdds = require("./HatchOdds")

local Genome = {}

export type Shares = { [HatchOdds.Element]: number } -- the element shares, adding up to 1

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
	parents: { string }, -- parent uuids, empty for a Market dragon
	bornAt: number,
	oddsVersion: number, -- Config.version it was rolled with
}

-- the first 8 letters and digits of the uuid, uppercase
function Genome.makeCode(uuid: string): string
	local clean = uuid:gsub("[^%w]", "")
	return clean:sub(1, 8):upper()
end

return Genome
