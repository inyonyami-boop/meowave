-- 第三关：沿用第二关布局，但所有配置表为独立副本，重试/扩建不会污染前两关。
local second = require("Level2.Config")
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
---@type table<string, any>
local config = Copy(second)
config.number, config.catLimit, config.expansion = 3, 10, true
config.waitTime, config.nextWaveTime = 1.0, 1.9
config.buildOnly, config.flowerPots = true, true
config.tutorial = "Level3/Text/level_3.txt"
config.buildTutorial = config.tutorial -- 原文资源与第二/三关共用的平台过滤、高亮和逐字显示流程。
return config
