--!strict

-- Hatch Dragons odds: loads Control/HatchOdds, Control/HatchPieces and Control/HatchSystems, puts them together, validates the result at
-- startup and holds the built Odds every roll and value function takes. The same Config goes to clients in NotifyInit, so the odds
-- screens read the weights the server rolls with.
local HatchOddsManager = {}
HatchOddsManager.__index = HatchOddsManager

local ServerScriptService = game:GetService("ServerScriptService")

local HatchOdds = require("@game/ReplicatedStorage/Shared/HatchOdds")

type HatchOddsManagerFields = {
	odds: HatchOdds.Odds?,
}

export type HatchOddsManager = typeof(setmetatable({} :: HatchOddsManagerFields, HatchOddsManager))

-- one of the three Hatch Control modules, or nil with a warning when it is missing; a missing module turns the odds off instead of
-- stopping the server from starting
local function loadControl(name: string): any?
	local control: any = ServerScriptService:FindFirstChild("GameData")
	control = if control then control:FindFirstChild("Control") else nil
	local module = if control then control:FindFirstChild(name) else nil
	if not module or not module:IsA("ModuleScript") then
		warn("HatchOddsManager: GameData/Control/" .. name .. " is missing")
		return nil
	end
	return require(module)
end

-- nil when the Hatch Control modules are invalid (each problem was warned at startup), so callers nil-guard
function HatchOddsManager.getOdds(self: HatchOddsManager): HatchOdds.Odds?
	return self.odds
end

function HatchOddsManager.getClientConfig(self: HatchOddsManager): HatchOdds.Config?
	local odds = self.odds
	return if odds then odds.config else nil
end

function HatchOddsManager.init(self: HatchOddsManager)
	local oddsData = loadControl("HatchOdds")
	local piecesData = loadControl("HatchPieces")
	local systemsData = loadControl("HatchSystems")
	if not oddsData or not piecesData or not systemsData then
		warn("HatchOddsManager: a Hatch Control module is missing, so Hatch Dragons odds are off")
		return
	end

	local config = HatchOdds.assemble(oddsData, piecesData, systemsData)
	local problems = HatchOdds.validate(config)
	if #problems > 0 then
		for _, problem in problems do
			warn("HatchOddsManager:", problem)
		end
		warn("HatchOddsManager: the Hatch Control modules (HatchOdds, HatchPieces, HatchSystems) are invalid, so Hatch Dragons odds are off")
		return
	end

	self.odds = HatchOdds.build(config :: HatchOdds.Config)
end

function HatchOddsManager.new(): HatchOddsManager
	local self = setmetatable({} :: HatchOddsManagerFields, HatchOddsManager)
	return self
end

local singleton = HatchOddsManager.new()

return singleton
