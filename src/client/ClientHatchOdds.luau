--!strict

-- The Hatch Dragons odds the server sent in NotifyInit (Control/HatchOdds), built into the Odds the shared roll and value functions take.
-- The odds and confirm screens read the weights from here; the server still decides every roll.
local ClientHatchOdds = {}
ClientHatchOdds.__index = ClientHatchOdds

local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")

type ClientHatchOddsFields = {
	odds: HatchOdds.Odds?,
}

export type ClientHatchOdds = typeof(setmetatable({} :: ClientHatchOddsFields, ClientHatchOdds))

-- nil until NotifyInit arrives, or when the server's table was invalid
function ClientHatchOdds.getOdds(self: ClientHatchOdds): HatchOdds.Odds?
	return self.odds
end

function ClientHatchOdds.setConfig(self: ClientHatchOdds, config: HatchOdds.Config?)
	if not config then
		return
	end
	self.odds = HatchOdds.build(config)
end

function ClientHatchOdds.new(): ClientHatchOdds
	local self = setmetatable({} :: ClientHatchOddsFields, ClientHatchOdds)
	return self
end

local singleton = ClientHatchOdds.new()

return singleton
