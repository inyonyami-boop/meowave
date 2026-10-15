-- 第四关：独立深拷贝，继承前关布局；本关提供两块楼层，其中一块随机屋顶。
local third = require("Level3.Config")
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
---@type table<string, any>
local config = Copy(third)
config.number, config.catLimit = 4, 12
config.floorBlockCount, config.roofBlockCount = 2, 1
config.waitTime, config.nextWaveTime = third.waitTime, third.nextWaveTime
config.tutorial = "Level4/Text/level_4.txt"
config.buildTutorial = config.tutorial
return config
