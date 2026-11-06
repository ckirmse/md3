--!strict

-- Hatch Dragons odds: loads Control/HatchOdds, validates it at startup and holds the built Odds every roll and value function takes.
-- The same Config goes to clients in NotifyInit, so the odds screens read the weights the server rolls with.
local HatchOddsManager = {}
HatchOddsManager.__index = HatchOddsManager

local hatchOddsData = require("@game/ServerScriptService/GameData/Control/HatchOdds")

local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")

type HatchOddsManagerFields = {
	odds: HatchOdds.Odds?,
}

export type HatchOddsManager = typeof(setmetatable({} :: HatchOddsManagerFields, HatchOddsManager))

-- nil when Control/HatchOdds is invalid (each problem was warned at startup), so callers nil-guard
function HatchOddsManager.getOdds(self: HatchOddsManager): HatchOdds.Odds?
	return self.odds
end

function HatchOddsManager.getClientConfig(self: HatchOddsManager): HatchOdds.Config?
	local odds = self.odds
	return if odds then odds.config else nil
end

function HatchOddsManager.init(self: HatchOddsManager)
	local problems = HatchOdds.validate(hatchOddsData)
	if #problems > 0 then
		for _, problem in problems do
			warn("HatchOddsManager:", problem)
		end
		warn("HatchOddsManager: Control/HatchOdds is invalid, so Hatch Dragons odds are off")
		return
	end

	self.odds = HatchOdds.build(hatchOddsData :: HatchOdds.Config)
end

function HatchOddsManager.new(): HatchOddsManager
	local self = setmetatable({} :: HatchOddsManagerFields, HatchOddsManager)
	return self
end

local singleton = HatchOddsManager.new()

return singleton
