-- 第六关：电气实验室先放；三类楼层中随机一块附带固定款屋顶。
local previous = require("Level5.Config")
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
---@type table<string, any>
local config = Copy(previous)
config.number, config.catLimit = 6, 12
config.floorBlockCount, config.roofBlockCount = 3, 1
config.warehouseBlockCount, config.laboratoryBlockCount = 1, 1
config.magneticSpawnChance = 0.20
config.magneticGuarantee = true
config.tutorial = "Level6/Text/level_6.txt"
config.buildTutorial = config.tutorial
return config
