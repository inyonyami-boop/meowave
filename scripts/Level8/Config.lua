-- 第八关：三份独立随机楼层，普通权重9、仓库/实验室/婚介所/温室各1。
local previous = require("Level7.Config")
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
---@type table<string, any>
local config = Copy(previous)
config.number, config.catLimit = 8, 12
config.nextWaveTime = 2.2 -- 原固定1.9秒独立加0.3，不改等待跳窗时间。
config.floorBlockCount, config.roofBlockCount = 3, 0
config.warehouseBlockCount, config.laboratoryBlockCount = 0, 0
config.matchmakingBlockCount, config.greenhouseBlockCount = 0, 0
config.randomFloorBlockCount = 3
config.randomFloorWeights = { 9, 1, 1, 1, 1 } -- 普通、仓库、实验室、婚介所、温室，共13。
config.magneticGuarantee = false
config.buildOnly = true
config.tutorial = "Level8/Text/level_8.txt"
config.buildTutorial = config.tutorial
return config
