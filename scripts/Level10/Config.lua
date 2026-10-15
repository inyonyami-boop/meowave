-- 第十关是整次挑战入口；内部段号保留原 L1-9 玩法，不污染它们的配置或存档。
local configs = {
    require("Level1.Config"), require("Level2.Config"), require("Level3.Config"),
    require("Level4.Config"), require("Level5.Config"), require("Level6.Config"),
    require("Level7.Config"), require("Level8.Config"), require("Level9.Config"),
}
local Config = { number = 10, challenge = true }

local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end

---@param segment integer
---@return table<string, any>
function Config.GetStage(segment)
    assert(segment >= 1, "挑战段号必须为正整数")
    local config = Copy(configs[math.min(segment, 9)])
    config.challengeSegment = segment
    if segment > 9 then
        -- 仍采用 L9 的磁猫、管道、温室、波次规则；仅覆盖新段供给与猫额度。
        config.catLimit = 20 + segment - 10
        config.floorBlockCount, config.roofBlockCount = 3, 0
        config.warehouseBlockCount, config.laboratoryBlockCount = 0, 0
        config.matchmakingBlockCount, config.greenhouseBlockCount = 0, 0
        config.randomFloorBlockCount = 3
        config.randomFloorWeights = { 9, 1, 1, 1, 1 }
        config.challengeRandomSupply, config.challengeRoofChance = true, 1 / 20
    end
    return config
end

return Config
