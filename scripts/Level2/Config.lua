-- 第二关沿用第一关的背景、原楼及九窗配置，仅覆盖扩建流程与投放节奏。
local first = require("Level1.Config")
---@type table<string, any>
local config = {}
for key, value in pairs(first) do config[key] = value end
-- 原窗坐标独立副本：新局追加 world 窗洞时不会污染第一关/后续重试。
config.windows = {}
for index, window in ipairs(first.windows) do
    local copy = {}
    for key, value in pairs(window) do copy[key] = value end
    config.windows[index] = copy
end
config.number, config.catLimit, config.expansion = 2, 10, true
config.waitTime, config.nextWaveTime = 1.2, 2.1
config.buildTutorial = { "这栋楼要扩建了。", "新的房间建在哪里呢？" }
config.propTutorial = { "有的住户购买了晾衣架。安装它，它们上面的被子能成为撞到它的猫的降落伞。" }
return config
