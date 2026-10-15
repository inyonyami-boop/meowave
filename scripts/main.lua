-- 游戏入口负责 Home 与共享关卡的切换；每关只传独立配置，不复制玩法。
-- “— 新的救援 —”进入第一关，Home 最左侧窗洞进入第二关。
local UI = require("urhox-libs/UI")
local Home = require("Home")
local RescueLevel = require("Global.RescueLevel")
local Registry = require("Global.LevelRegistry")
local LevelSave = require("Global.LevelSave")
local Level1Config = require("Level1.Config")
local Level2Config = require("Level2.Config")
local Level3Config = require("Level3.Config")
local Level4Config = require("Level4.Config")
local Level5Config = require("Level5.Config")
local Level6Config = require("Level6.Config")
local Level7Config = require("Level7.Config")
local Level8Config = require("Level8.Config")
local Level9Config = require("Level9.Config")
local Level10Config = require("Level10.Config")
local ExitMenu = require("Global.ExitMenu")
local screen = "home"
---@type string?
local pendingAction = nil
---@type integer?
local pendingNumber = nil

---@param number integer
local function SelectLevel(number)
    if screen ~= "home" or pendingNumber or ExitMenu.IsOpen() or pendingAction then return end
    if not Registry.Get(number) then
        print("[入口] 未注册关卡：" .. tostring(number))
        return
    end
    pendingNumber = number
    Home.BeginExit()
end

local function StartHome()
    screen, pendingNumber = "home", nil
    Home.Start(function() SelectLevel(1) end, function(number) SelectLevel(number) end)
end

local function OpenExitMenu()
    if ExitMenu.IsOpen() or pendingAction or pendingNumber then return end
    if screen == "level" then
        if not RescueLevel.OpenExitPause() then return end
    else
        Home.BeginExit()
        Home.PauseForExit()
    end
    ExitMenu.Open()
end

local function PerformExit(target)
    ExitMenu.Close()
    if screen == "home" then Home.Stop() else RescueLevel.Stop() end
    pendingNumber, pendingAction = nil, nil
    UI.SetRoot(UI.Panel { width = "100%", height = "100%", pointerEvents = "none",
        backgroundColor = { 0, 0, 0, 255 } }, true)
    if target == "exit" then
        print("[入口] 退出游戏程序")
        engine:Exit()
    else
        StartHome()
        print("[入口] 返回标题界面")
    end
end

function Start()
    engine:SetAutoExit(false) -- Esc只打开菜单，不让引擎在结算前自动退出。
    pendingAction = nil
    graphics.windowTitle = ""
    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = true
    math.randomseed(os.time())
    -- 尚未创建关卡，清档后不会被旧关卡的 Stop 再写回；成功标记让以后启动保留新数据。
    if not LevelSave.ResetForUpdate() then print("[入口] 旧存档清理未完成，请查看 LevelSave 错误日志") end
    UI.Init({
        theme = "default-taptap", scale = UI.Scale.DESIGN_RESOLUTION(1280, 800),
        fonts = { { family = "sans", weights = {
            normal = "Fonts/MiSans-Regular.ttf", bold = "Fonts/MiSans-Regular.ttf",
        } } },
    })
    -- 启动时登记已构建关卡，首页窗口和结算“继续”均按编号取配置。
    Registry.Register(1, Level1Config)
    Registry.Register(2, Level2Config)
    Registry.Register(3, Level3Config)
    Registry.Register(4, Level4Config)
    Registry.Register(5, Level5Config)
    Registry.Register(6, Level6Config)
    Registry.Register(7, Level7Config)
    Registry.Register(8, Level8Config)
    Registry.Register(9, Level9Config)
    Registry.Register(10, Level10Config)
    RescueLevel.OnOpenExitMenu = OpenExitMenu
    RescueLevel.OnExit = function(target) pendingAction = target end
    -- 结果控件回调只排队，下一Update才销毁当前控件树。
    RescueLevel.OnGoHome = function()
        if pendingNumber or screen == "home" then return end
        pendingAction = "home"
    end
    StartHome()
    SubscribeToEvent("KeyDown", "HandleKeyDown")
    SubscribeToEvent("ExitRequested", "HandleExitRequested")
    SubscribeToEvent("SceneUpdate", "HandleSceneUpdate")
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("MouseWheel", "HandleWheel")
    SubscribeToEvent("PhysicsBeginContact2D", "HandleContact")
    SubscribeToEvent("PhysicsEndContact2D", "HandleContactEnd")
end

function HandleExitRequested()
    OpenExitMenu()
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    if eventData:GetInt("Key") == KEY_ESCAPE and not eventData:GetBool("Repeat") then
        OpenExitMenu()
    end
end

---@param eventType string
---@param eventData SceneUpdateEventData
function HandleSceneUpdate(eventType, eventData)
    if screen == "level" then
        RescueLevel.BeforePhysics(eventData:GetPtr("Scene"), eventData:GetFloat("TimeStep"))
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")
    if pendingAction then PerformExit(pendingAction); return end
    if ExitMenu.IsOpen() then
        local target = ExitMenu.Update(dt)
        if target then
            ExitMenu.Close()
            if screen == "level" then RescueLevel.RequestExit(target)
            else pendingAction = target end
        end
        return
    end
    if pendingNumber then
        -- 按下回调已立即停乐/停止输出；不再运行首页刷猫/布局后才开始关卡重加载。
        if not Home.ExitFinished() then return end
        local number = pendingNumber
        local config = Registry.Get(number)
        pendingNumber = nil
        if not config then
            Home.Stop()
            StartHome()
            print("[入口] 目标关卡配置缺失：" .. tostring(number))
            return
        end
        -- 音乐已在点击时结束；两个入口均先释放首页，再加载关卡。
        UI.SetRoot(UI.Panel { width = "100%", height = "100%", pointerEvents = "none" }, true)
        Home.Stop()
        screen = "level"
        RescueLevel.Start(config)
        Home.FinishExit() -- 旧音乐已移除，重加载完成才恢复音频输出，不重放首页音乐。
        print("[入口] Home -> Level " .. tostring(number))
        return
    end
    if screen == "home" then Home.Update(dt) else RescueLevel.Update(dt) end
end

---@param eventType string
---@param eventData MouseWheelEventData
function HandleWheel(eventType, eventData)
    if screen == "level" and not ExitMenu.IsOpen() then RescueLevel.Wheel(eventData:GetInt("Wheel")) end
end

---@param eventType string
---@param eventData PhysicsBeginContact2DEventData
function HandleContact(eventType, eventData)
    if screen == "level" then
        local nodeA = eventData:GetPtr("NodeA") --[[@as Node?]]
        local nodeB = eventData:GetPtr("NodeB") --[[@as Node?]]
        if nodeA and nodeB then RescueLevel.Contact(nodeA, nodeB) end
    end
end

---@param eventType string
---@param eventData PhysicsEndContact2DEventData
function HandleContactEnd(eventType, eventData)
    if screen == "level" then
        local nodeA = eventData:GetPtr("NodeA") --[[@as Node?]]
        local nodeB = eventData:GetPtr("NodeB") --[[@as Node?]]
        if nodeA and nodeB then RescueLevel.ContactEnd(nodeA, nodeB) end
    end
end

function Stop()
    ExitMenu.Close()
    UnsubscribeFromAllEvents()
    UI.Shutdown()
    if screen == "home" then Home.Stop() else RescueLevel.Stop() end
    Home.FinishExit() -- 按下后若停止整个脚本，也归还本次暂停的音频输出状态。
    pendingNumber, pendingAction = nil, nil
end

