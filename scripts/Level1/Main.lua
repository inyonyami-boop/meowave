-- Level 1 入口；玩法和关卡入场动画调用 Global 中的共享程序。
-- 术语：关卡布局数据在 Level1/Config.lua；本文件不复制共享逻辑。
local RescueLevel = require("Global.RescueLevel")
local Config = require("Level1.Config")
local Level1 = {}

function Level1.Start()
    RescueLevel.Start(Config)
    print("[Level1] 进入第一关")
end

-- 注入结算“←主界面”回调，使共享关卡模块不必依赖入口实现。
function Level1.BindHome(handler)
    RescueLevel.OnGoHome = handler
end

function Level1.Update(dt)
    RescueLevel.Update(dt)
end

function Level1.Contact(nodeA, nodeB)
    RescueLevel.Contact(nodeA, nodeB)
end

function Level1.Stop()
    RescueLevel.Stop()
end

return Level1

