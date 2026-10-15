-- 第九关：先放温室，再放四份随机楼层；仅后四份之一随机附带屋顶。
local previous = require("Level8.Config")
local function Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Copy(item) end
    return result
end
---@type table<string, any>
local config = Copy(previous)
config.number, config.catLimit = 9, 24
config.floorBlockCount, config.roofBlockCount = 5, 1
config.greenhouseBlockCount, config.randomFloorBlockCount = 1, 4
config.randomFloorWeights = { 9, 1, 1, 1, 1 }
config.magneticGuarantee = false
config.waveCatMin, config.waveCatMax = 1, 2 -- 同波最多两猫，磁猫也占总数及单波名额。
config.waitTime = 0 -- 同次 Prepare 尾释放；不会额外等待1.2秒再叠波间计时。
config.nextWaveMin, config.nextWaveMax = 1.5, 1.8 -- 本关原1.2—1.5秒独立加0.3。
config.nextWaveTime = 1.5 -- 后备值同步加0.3，不累加继承L8的改动。
config.buildOnly = true
config.tutorial = "Level9/Text/level_9.txt"
config.buildTutorial = config.tutorial
return config
