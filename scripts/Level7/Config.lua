-- 第七关：婚介所一份、五金仓库一份；不新增屋顶，继承已安装布局。
local previous = require("Level6.Config")
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
---@type table<string, any>
local config = Copy(previous)
config.number, config.catLimit = 7, 12
config.floorBlockCount, config.roofBlockCount = 2, 0
config.warehouseBlockCount, config.laboratoryBlockCount = 1, 0
config.matchmakingBlockCount, config.greenhouseBlockCount = 1, 0
config.magneticGuarantee = false -- 第六关的强制保证不继承；只有合法实验室邻窗概率触发。
config.buildOnly = true
config.tutorial = "Level7/Text/level_7.txt"
config.buildTutorial = config.tutorial
return config
