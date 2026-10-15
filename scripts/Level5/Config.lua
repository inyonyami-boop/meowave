-- 第五关：普通楼层 + 五金仓库；继承前关已安装的屋顶，不新增屋顶。
local fourth = require("Level4.Config")
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
---@type table<string, any>
local config = Copy(fourth)
config.number, config.catLimit = 5, 12 -- 原接猫目标成为本关全部猫的刷新上限X。
config.floorBlockCount, config.roofBlockCount, config.warehouseBlockCount = 2, 0, 1
config.warehouseDropChance = 0.5 -- 每次猫出现，各未领取仓库独立判定；三种道具等概率。
config.tutorial = "Level5/Text/level_5.txt"
config.buildTutorial = config.tutorial
return config
