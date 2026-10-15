-- 固定桌面画幅；复用 scaffold-2d-physics 的场景/UI 生命周期，不创建新的绘图帧。
-- 所有关卡完整建设/安装后先刷新盆与管，再从顶端匀速下降到地面视角才游玩。
local UI = require("urhox-libs/UI")
local WorkshopGame = require("Global.WorkshopGame")
local Art = require("Global.WorkshopArt")
local Console = require("Global.ConsoleUI")
local Tutorial = require("Global.Tutorial")
local Result = require("Global.LevelResult")
local Registry = require("Global.LevelRegistry")
local LevelSave = require("Global.LevelSave")
local Progress = require("Global.LevelProgress")
local ChallengeRun = require("Global.ChallengeRun")
local ChallengeConfig = require("Level10.Config")
local ChallengeSupply = require("Global.ChallengeSupply")
local PlatformUtils = require("urhox-libs.Platform.PlatformUtils")
local Level = {}
local stage = "idle"
---@type ChallengeRun?
local run = nil
---@type string?
local pendingExit = nil
---@type string?
local resultExit = nil
local exitPaused, pendingRestart = false, false
local resumePaused, resumePhysics = false, false
---@type Panel?
local consolePanel = nil
---@type table?
local game = nil
---@type Panel?
local arena = nil
---@type Panel?
local gameArea = nil
---@type Label?
local buildHint = nil
---@type Label?
local catchProgress = nil
---@type fun()?
local nextAfterRise = nil
---@type number, number
local lastViewWidth, lastViewHeight = 0, 0
local previewCol, previewRow = -1, 0
local constructionPrepared = false
local wavePrepared = false
---@type number, number
local cameraReturnElapsed, cameraReturnOffset = 0, 0
local CAMERA_RETURN_SPEED = 8.0 -- 米/秒；不使用缓动，楼房更高时延长展示时间。
-- 兼容旧供给：0普通、1/2普通红瓦/铁皮、3仓库。
-- 组合编码：4/5仓库红瓦/铁皮、6实验室、7/8实验室红瓦/铁皮；不是把3当屋顶。
-- 追加兼容编码：9婚介所、10/11婚介屋顶；12温室、13/14温室屋顶。
---@type integer[] 仅内存重试携带；同一块的类型和屋顶独立解码，放置时不再随机。
local floorSupply = {}
local supplyIndex = 1
local supplyDeferred = false
---@type table<string, boolean>?
local warehouseClaims = nil

local function CurrentRoof()
    local kind = floorSupply[supplyIndex]
    if kind == 1 or kind == 4 or kind == 7 or kind == 10 or kind == 13 then return 1 end
    if kind == 2 or kind == 5 or kind == 8 or kind == 11 or kind == 14 then return 2 end
    return nil
end

local function CurrentWarehouse()
    local kind = floorSupply[supplyIndex]
    return kind == 3 or kind == 4 or kind == 5
end

local function CurrentLaboratory()
    local kind = floorSupply[supplyIndex]
    return kind == 6 or kind == 7 or kind == 8
end

local function CurrentMatchmaking()
    local kind = floorSupply[supplyIndex]
    return kind == 9 or kind == 10 or kind == 11
end

local function CurrentGreenhouse()
    local kind = floorSupply[supplyIndex]
    return kind == 12 or kind == 13 or kind == 14
end

local function PlacementKind()
    return game and game.config.number == 4 and "security_window" or "rack"
end

local function PlacementComplete(prop)
    if not game then return false end
    local kind = PlacementKind()
    if prop and prop.kind == kind then return true end
    if kind == "security_window" then return not game.props:HasStock(kind) end
    -- 已装道具不需要重新搬动确认；对应库存已消耗即可结束本关强制安装阶段。
    return not game.props:HasStock(kind)
end
-- 手机空白处先判定滑动意图；道具拖动始终优先，滑动不会误放楼层。
---@type {active: boolean, pointerId: number, startX: number, startY: number, lastY: number, scrolling: boolean, age: number, controlStarted: boolean, direction: number}
local pan = { active = false, pointerId = -1, startX = 0, startY = 0, lastY = 0,
    scrolling = false, age = 0, controlStarted = false, direction = 0 }
---@type {x: number, y: number, known: boolean}
local pointer = { x = 0, y = 0, known = false }

---@class RescueLevelLayout
---@field floors FloorBlockPlacement[]
---@field props PropPosition[]
---@field fences LevelSaveFencePosition[]?
---@field prepared boolean
---@field inventory PropInventory?
---@field pendingFloors integer[]? 仅内存未放配额，盘档不保留。
---@field deferredFloors integer[]? 仅无尽段跨段延期，固定编码不丢弃/不重抽，不写普通盘档。
---@field warehouseClaims table<string, boolean>? 同关重试保留领取锁，不写盘/继承到下一关。

---@return RescueLevelLayout
local function SnapshotLayout()
    local current = game
    if not current then return { floors = {}, props = {}, fences = {}, prepared = false } end
    local fences = {}
    for _, fence in ipairs(current.fences) do
        fences[#fences + 1] = { x = fence.x, y = fence.y, angle = fence.angle }
    end
    local pending = {}
    for index = supplyIndex, #floorSupply do pending[#pending + 1] = floorSupply[index] end
    local claims = {}
    for key, claimed in pairs(warehouseClaims or current.warehouseDrops:ExportClaims()) do
        if claimed == true then claims[key] = true end
    end
    return { floors = current.buildingGrid:Export(), props = current.props:Export(), fences = fences,
        prepared = constructionPrepared, inventory = current.props:ExportInventory(), pendingFloors = pending,
        deferredFloors = supplyDeferred and ChallengeSupply.Combine({}, pending) or nil,
        warehouseClaims = claims }
end

local function SaveLayout()
    if game then
        Console.RefreshTools(game)
        -- 整次挑战只保内存布局，不覆盖真实 L1-9 的最后布局/教程发放记录。
        if not game.run then LevelSave.Save(game.config.number, SnapshotLayout()) end
    end
end

-- 主界面与引擎退出均由入口注入；共享玩法只负责冻结和先结算。
Level.OnGoHome = function() end
Level.OnOpenExitMenu = function() end
Level.OnExit = function(target)
    Level.Stop()
    if target == "exit" then engine:Exit() else Level.OnGoHome() end
end

local function SetStage(value)
    stage = value
    pan.active, pan.scrolling = false, false
    if catchProgress then
        catchProgress:SetVisible(value == "playing" and game ~= nil)
    end
    if not buildHint then return end
    if value == "building" then
        local controls = PlatformUtils.IsTouchSupported() and "上下滑动查看高处，轻点绿色网格" or "滚轮查看高处，点击绿色网格"
        local roof = CurrentRoof()
        local kind = CurrentMatchmaking() and "婚介所" or (CurrentGreenhouse() and "园艺温室"
            or (CurrentLaboratory() and "电气实验室" or (CurrentWarehouse() and "五金仓库" or "普通楼层")))
        if roof then kind = kind .. (roof == 1 and "（红瓦屋顶）" or "（铁皮屋顶）") end
        buildHint:SetText("待放置：" .. kind .. "（剩余" .. tostring(#floorSupply - supplyIndex + 1)
            .. "块）\n" .. controls .. "放置。" .. (roof and "只能放在侧面，正上方须空。" or ""))
    elseif value == "placing" then
        buildHint:SetText(PlacementKind() == "security_window"
            and "从右下工具槽拖出防盗窗，安装到住户窗洞上后开始救猫。"
            or "从右下工具槽拖出晾衣架，安装到楼房上后开始救猫。")
    end
    buildHint:SetVisible(value == "building" or value == "placing" or
        (supplyDeferred and (value == "camera_return" or value == "playing")))
end

local function WorldPoint(event)
    if not arena or not game then return 0, 0 end
    -- 指针事件已经是 UI 基准像素，不再除 DPR 或 UI.GetScale。
    return game.view:ScreenToWorld(event.x, event.y, arena:GetAbsoluteLayoutForHitTest())
end

local function RememberPointer(event)
    pointer.x, pointer.y, pointer.known = event.x, event.y, true
end

local function UpdateBuildPreview(x, y)
    if not game then return end
    previewCol, previewRow = game.buildingGrid:Snap(x, y)
end

local function RefreshPreview()
    if stage == "building" and pointer.known then
        local x, y = WorldPoint(pointer)
        UpdateBuildPreview(x, y)
    end
end

---@type fun()
local StartPlaying

-- 只在无尽建设开始/成功放置后检查，查询缓存不跨越实楼变化，不在 Update 每帧扫描。
---@return boolean placeable
local function PrepareSupply()
    if not game or not run or run.segment <= 9 then return true end
    local placeable, reordered = ChallengeSupply.SelectPlaceable(game.buildingGrid, floorSupply, supplyIndex)
    if placeable then
        if reordered then print("[挑战供给] 当前块无合法格，先放后续可放块；类型/屋顶保持原编码") end
        return true
    end
    supplyDeferred = true
    local remaining = math.max(0, #floorSupply - supplyIndex + 1)
    if buildHint then
        buildHint:SetText(string.format("剩余 %d 块暂无合法位置，已暂存至下一段；先继续救猫。", remaining))
    end
    print(string.format("[挑战供给] 全部剩余 %d 块无合法格，保留编码延期到下一段，不丢弃/不重抽", remaining))
    StartPlaying()
    return false
end

local function StartBuilding()
    if not game or not PrepareSupply() then return end
    local x, y, w, h = game.buildingGrid:GetRect(-1, 0)
    UpdateBuildPreview(x + w / 2, y + h / 2)
    SetStage("building")
    RefreshPreview()
    print("[Level] 控制台就绪，等待扩建楼层")
end

StartPlaying = function()
    local current = game
    if not current or wavePrepared then return end
    current:CancelDrag()
    current.selectedId, current.props.selectedId = 0, 0 -- 清掉最后道具的点选框及所有预览。
    current.physics.updateEnabled = false
    current.paused = false -- PrepareWave/仓库出生回调需要未暂停，物理始终保持冻结。
    current.rescuer:Reset(false)
    -- 完整布局下先建立全部花盆邻窗与水管状态；每局只初始化一次，不在回镜结束重抽。
    current.flowerPots:Spawn()
    current.warehouseDrops:Start(warehouseClaims)
    warehouseClaims = nil
    if current.specialFloors then current.specialFloors:Start() end
    current:PrepareWave() -- 首波可见但保持静止；回镜阶段不推进任何玩法时钟。
    cameraReturnElapsed, cameraReturnOffset = 0, current.view.maxOffset
    current.view:SetOffset(cameraReturnOffset) -- 刷新完成后立即移至顶端，并清掉滚轮惯性。
    current.view.target = current.view.offset
    SetStage("camera_return")
    current.paused, current.physics.updateEnabled = true, false
    current.rescuer.touches = {}
    wavePrepared, constructionPrepared = true, true -- 只有完整建设/安装结束后，重试才跳过操作。
    SaveLayout()
    print(string.format("[Level] 建设准备完成 Level %d，清除选中；从顶端 %.3f 米以 %.1f 米/秒下降",
        current.config.number, cameraReturnOffset, CAMERA_RETURN_SPEED))
end

local function BeginRise(onComplete)
    nextAfterRise = onComplete
    SetStage("starting")
    Console.Begin()
end

local function StartTutorial(lines, onComplete)
    local current = game
    if not current then return end
    -- 跳过的是引导显示，不是 L2/L4 的发放与安装阶段。
    if run then onComplete(); return end
    SetStage("tutorial")
    local _, _, _, windowHeight = current:GetWindowRect(1)
    Tutorial.Start(gameArea, lines, windowHeight * 1280 / current.width,
        PlatformUtils.IsTouchSupported(), onComplete,
        current.config.number == 1 and "按下红色按钮来退出游戏" or nil)
end

-- L4 的原开场文本已说明防盗窗，不重复播放继承来的 L2 晾衣架教程。
-- 最后一块楼层和防盗窗发放同一次存档提交；retry 只恢复库存/发放锁，绝不补发。
local function CompleteConstruction(saveFloor)
    if not game then return end
    local granted = game.config.number == 4 and game.props:GrantSecurityTutorial()
    if saveFloor or granted then SaveLayout() end
    if game.config.number == 4 then
        if game.props:HasStock("security_window") then SetStage("placing")
        else StartPlaying() end -- 已安装、已消费或已删除的防盗窗不会锁住重试。
    elseif game.config.buildOnly then
        StartPlaying()
    else
        StartTutorial(game.config.propTutorial, function()
            if game and game.props:HasStock("rack") then
                SetStage("placing")
            else
                StartPlaying() -- 道具已消耗/删除的重试不补发，也不锁死在安装阶段。
            end
        end)
    end
end

local function PlaceFloor(event)
    if not game or stage ~= "building" then return end
    local x, y = WorldPoint(event)
    UpdateBuildPreview(x, y)
    if not game.buildingGrid:Place(previewCol, previewRow, CurrentRoof(), nil,
        CurrentWarehouse(), CurrentLaboratory(), CurrentMatchmaking(), CurrentGreenhouse()) then return end
    supplyIndex = supplyIndex + 1
    if supplyIndex <= #floorSupply then
        SaveLayout()
        if not PrepareSupply() then return end
        SetStage("building")
        print("[Level] 楼层已放置，剩余 " .. tostring(#floorSupply - supplyIndex + 1) .. " 块")
        return
    end
    CompleteConstruction(true)
end

local function CanScroll()
    return not exitPaused and game and not game.drag.active and
        (stage == "building" or stage == "placing" or stage == "playing")
end

-- 直接消费引擎滚轮事件，不依赖教程/控制台动画之后可能失效的 UI hover 缓存。
---@param wheel number
function Level.Wheel(wheel)
    -- 收到的引擎滚轮事件已由平台路由；以画幅和关卡阶段判定，不重复依赖窗口焦点标志。
    if not CanScroll() or not game or not arena or wheel == 0 then return end
    local position = input:GetMousePosition()
    local scale = math.max(0.001, UI.GetScale())
    local x, y = position.x / scale, position.y / scale
    local rect = arena:GetAbsoluteLayoutForHitTest()
    -- 控制台也属于此画幅；鼠标在按钮上滚动仍能连续查看楼房，点击语义不变。
    if x < rect.x or x > rect.x + rect.w or y < rect.y or y > rect.y + rect.h then return end
    RememberPointer({ x = x, y = y })
    game.view:Scroll(wheel)
end

local function MovePointer(event)
    if not game or exitPaused or stage == "camera_return" then return end
    RememberPointer(event)
    if game.drag.active then
        pan.active, pan.scrolling = false, false
        if stage ~= "playing" and stage ~= "placing" then return end
        local x, y = WorldPoint(event)
        game.rescuer:TouchUp(event)
        game:MoveDrag(event.pointerId, x, y)
        return
    end
    if pan.active and pan.pointerId == event.pointerId and CanScroll() then
        local dx, dy = event.x - pan.startX, event.y - pan.startY
        if not pan.scrolling and math.abs(dy) > 12 and math.abs(dy) > math.abs(dx) * 1.2 then
            pan.scrolling = true
            game.rescuer:TouchUp(event)
        end
        if not pan.scrolling and not pan.controlStarted and stage == "playing"
            and math.abs(dx) > 12 and math.abs(dx) > math.abs(dy) * 1.2 then
            local worldX = WorldPoint(event)
            game.rescuer:TouchDown(event, worldX)
            pan.controlStarted = true
        end
        if pan.scrolling then
            if not arena then return end
            local rect = arena:GetAbsoluteLayoutForHitTest()
            game.view:Pan(event.y - pan.lastY, rect.w / game.width)
            pan.lastY = event.y
            RefreshPreview()
            return
        end
    end
    local x, y = WorldPoint(event)
    if stage == "building" then
        if event:IsTouch() and event.isPrimary == false then return end
        UpdateBuildPreview(x, y)
    elseif stage == "playing" then
        game.rescuer:TouchMove(event, x)
    end
end

local function EndPointer(event)
    if not game or exitPaused or stage == "camera_return" then return end
    RememberPointer(event)
    game.rescuer:TouchUp(event)
    if pan.active and pan.pointerId == event.pointerId then
        local scrolled = pan.scrolling
        -- 部分设备可能只发 down/up；松手位移也不能被当作轻点。
        local moved = math.abs(event.x - pan.startX) > 12 or math.abs(event.y - pan.startY) > 12
        pan.active, pan.scrolling = false, false
        if stage == "building" and not scrolled and not moved then PlaceFloor(event) end
        return
    end
    if stage ~= "playing" and stage ~= "placing" then return end
    if not game.drag.active or game.drag.pointerId ~= event.pointerId then return end
    MovePointer(event)
    local prop = game:EndDrag(event.pointerId, Console.IsOverTray(event))
    SaveLayout() -- 新放置/取消/非法落位均不存 ghost；已提交道具不再搬动。
    if stage == "placing" and PlacementComplete(prop) then StartPlaying() end
end

local function CancelPointer(event)
    if not game or exitPaused then return end
    game.rescuer:TouchUp(event)
    if pan.pointerId == event.pointerId then pan.active, pan.scrolling = false, false end
    if game.drag.active and game.drag.pointerId == event.pointerId then game:CancelDrag() end
end

local function BeginPan(event)
    if not event:IsTouch() or pan.active then return end
    pan.active, pan.pointerId = true, event.pointerId
    pan.startX, pan.startY, pan.lastY, pan.scrolling = event.x, event.y, event.y, false
    pan.age, pan.controlStarted = 0, false
    local worldX = WorldPoint(event)
    pan.direction = game and worldX < game.width / 2 and -1 or 1
end

local function DownPointer(event)
    if not game or exitPaused or stage == "camera_return" or Console.IsStarting() then return end
    RememberPointer(event)
    game.view:SetOffset(game.view.offset) -- 点击/拖拽开始时停止尚未完成的平滑滚动。
    local x, y = WorldPoint(event)
    if stage == "building" then
        if not event:IsPrimaryAction() or (event:IsTouch() and event.isPrimary == false) then return end
        UpdateBuildPreview(x, y)
        if event:IsTouch() then BeginPan(event) else PlaceFloor(event) end
        return
    end
    if stage ~= "playing" and stage ~= "placing" then return end
    if game.drag.active then return end
    local rack = game.props:Pick(x, y)
    local fence = not rack and stage == "playing" and game:PickFence(x, y) or nil
    if event:IsSecondaryButton() and not event:IsTouch() then
        if rack then game.props:Delete(rack.id)
        elseif fence then game:DeleteFence(fence.id) end
        if rack or fence then SaveLayout() end
        if stage == "placing" and PlacementComplete() then StartPlaying() end
        return
    end
    if not event:IsPrimaryAction() then return end
    -- 点选只保留删除入口，已放置道具不再隐藏碰撞体或进入移动事务。
    game.selectedId = fence and fence.id or 0
    game.props.selectedId = rack and rack.id or 0
    BeginPan(event) -- 在固定道具上也能纵向滑屏，手机端不会因命中道具而失去滑动。
end

local function CreateUI()
    arena = UI.Panel {
        id = "arena", position = "absolute", left = 0, top = 0, width = "100%", height = "100%",
        overflow = "hidden", pointerEvents = "auto",
        onPointerDown = DownPointer, onPointerMove = MovePointer,
        onPointerUp = EndPointer, onPointerCancel = CancelPointer,
    }
    function arena:Render(vg)
        if not game or not self then return end
        local rect = self:GetAbsoluteLayout()
        -- 建设帧只在Preview之后画一次支架，不重复合成纹理的半透明边缘。
        Art.Arena(vg, rect, game, stage == "starting" and Console.Shake() or { x = 0, y = 0 }, stage ~= "building")
        if stage == "building" and rect.w > 0 and rect.h > 0 then
            nvgSave(vg)
            nvgIntersectScissor(vg, rect.x, rect.y, rect.w, rect.h)
            local unit = rect.w / game.width
            -- 网格、预览与楼房用同一视角；HUD/控制台留在固定屏幕坐标。
            nvgTranslate(vg, rect.x, rect.y + game.view.offset * unit)
            game.buildingGrid:RenderGrid(vg, unit, CurrentRoof(), nil, CurrentWarehouse(), CurrentLaboratory(),
                CurrentMatchmaking(), CurrentGreenhouse())
            game.buildingGrid:Preview(vg, unit, previewCol, previewRow, CurrentRoof(), nil,
                CurrentWarehouse(), CurrentLaboratory(), CurrentMatchmaking(), CurrentGreenhouse())
            nvgRestore(vg)
        end
    end
    consolePanel = Console.Create(game, {
        worldPoint = WorldPoint, move = MovePointer, finish = EndPointer, cancel = CancelPointer,
        canPlace = function() return not exitPaused and (stage == "placing" or stage == "playing") end,
        canPlay = function() return not exitPaused and stage == "playing" end,
        restart = function() Level.RestartCurrent() end,
        exit = function() Level.OnOpenExitMenu() end,
    })
    consolePanel:SetVisible(false)
    buildHint = UI.Label {
        id = "buildHint", position = "absolute", left = 36, top = 506,
        width = 1208, height = 88, text = "", fontSize = 22, textAlign = "center",
        whiteSpace = "normal", wordBreak = "break-word", lineHeight = 1.2, verticalAlign = "top",
        fontColor = { 255, 240, 205, 255 }, textShadow = { offsetX = 1, offsetY = 1, blur = 0,
            color = { 30, 35, 30, 220 } }, pointerEvents = "none", visible = false,
    }
    catchProgress = UI.Label {
        id = "catchProgress", position = "absolute", left = 36, top = 20, width = 600, height = 42,
        text = game and string.format("已归类 %d / %d · 刷新上限%d只", game:GetOutcomeCount(),
            game.config.catLimit, game.config.catLimit) or "",
        fontSize = 22, fontColor = { 255, 240, 205, 255 },
        textShadow = { offsetX = 1, offsetY = 1, blur = 0, color = { 30, 35, 30, 220 } },
        pointerEvents = "none", visible = false,
    }
    gameArea = UI.Panel {
        position = "absolute", width = 1280, height = 800, pointerEvents = "box-none",
        overflow = "hidden", children = { arena, consolePanel, buildHint, catchProgress },
    }
    UI.SetRoot(UI.Panel {
        width = "100%", height = "100%", backgroundColor = { 26, 35, 33, 255 },
        pointerEvents = "box-none", children = { gameArea },
    }, true)
    UI.Layout()
end

function Level.AdaptLayout()
    local width, height = UI.GetViewportSize()
    if not gameArea or (math.abs(width - lastViewWidth) < 0.01 and
        math.abs(height - lastViewHeight) < 0.01) then return end
    lastViewWidth, lastViewHeight = width, height
    gameArea:SetStyle({ left = (width - 1280) / 2, top = (height - 800) / 2 })
    UI.Layout()
    print(string.format("[落球工坊] 固定画幅适配：%.0f × %.0f", width, height))
end

-- 普通楼层权重9，每种特殊楼层权重1（总13），各份随机供给独立抽取。
-- 只在新局生成供给时调用；retry 有 pendingFloors 时完全不触碰随机数。
---@param weights integer[]
---@return integer
local function RandomFloor(weights)
    local types = { 0, 3, 6, 9, 12 } -- 普通、仓库、实验室、婚介所、温室。
    local total = 0
    for index = 1, #types do total = total + math.max(0, math.floor(weights[index] or 0)) end
    if total == 0 then return 0 end
    local roll = math.random(1, total)
    for index, kind in ipairs(types) do
        roll = roll - math.max(0, math.floor(weights[index] or 0))
        if roll <= 0 then return kind end
    end
    return 0
end

local function CreateGame(config, layout)
    -- Stop 清理局部状态，但内部换段必须持有同一个挑战账本。
    local nextRun = config.challengeRun --[[@as ChallengeRun?]]
    Level.Stop()
    run = nextRun
    if run then run:BeginStage(config.challengeSegment) end
    -- 普通关先保存释放旧关，再读目标关；挑战永不读取普通关布局。
    if not layout and not run then
        local saved, source = LevelSave.GetForLevel(config.number)
        layout = saved
        if source then print(string.format("[Level] Level %d 导入 Level %d 布局", config.number, source)) end
    end
    if not run then Registry.Register(config.number, config) end
    local current = WorkshopGame.New(config)
    current.physics.updateEnabled = false
    current.rescuer:Reset(true)
    if layout then
        local floors = current.buildingGrid:Restore(layout.floors)
        local props = current.props:Restore(layout.props)
        current.props:RestoreInventory(layout.inventory)
        current:RestoreFences(layout.fences)
        constructionPrepared = layout.prepared == true
        print(string.format("[Level] 恢复 %d 块楼层、%d 件晾衣架、%d 道栅栏", floors, props, #current.fences))
    end
    if run then
        local deferredCount = config.challengeRandomSupply and #(layout and layout.deferredFloors or {}) or 0
        current.view:EnsureBuildSpace(current.buildingGrid, (config.floorBlockCount or 3) + deferredCount)
        -- Restore 可逐格扩高，墙体仍是 New 时的范围；出生前按最终视角上限重建。
        current:BuildWalls()
    end
    game = current
    warehouseClaims = layout and layout.warehouseClaims or nil
    floorSupply, supplyIndex = {}, 1
    if layout and layout.pendingFloors then
        for _, kind in ipairs(layout.pendingFloors) do floorSupply[#floorSupply + 1] = kind end
    elseif config.expansion and not constructionPrepared then
        local count = math.max(1, math.floor(config.floorBlockCount or 1))
        local roofs = math.max(0, math.min(count, math.floor(config.roofBlockCount or 0)))
        if config.challengeRandomSupply then
            -- L9之后三份独立抽类型和屋顶；屋顶附属于同块，不挤掉特殊楼名额。
            for index = 1, count do
                local kind = RandomFloor(config.randomFloorWeights or { 9, 1, 1, 1, 1 })
                if math.random() < (config.challengeRoofChance or 1 / 20) then
                    kind = kind + math.random(1, 2)
                end
                floorSupply[index] = kind
            end
            print(string.format("[挑战] 第 %d 段：三份随机楼层，各自 1/20 屋顶，猫额度 %d",
                config.challengeSegment, config.catLimit))
        elseif config.number == 6 then
            -- L6 固定三份类型配额，实验室必须第一；屋顶不是第四份供给，也不占掉仓库名额。
            floorSupply = { 6, 0, 3 }
            local roofIndex, roofStyle = math.random(1, #floorSupply), math.random(1, 2)
            local roofFloor = floorSupply[roofIndex]
            assert(roofFloor ~= nil, "屋顶供给索引必须对应已有楼层")
            floorSupply[roofIndex] = roofFloor + roofStyle
            print(string.format("[Level] L6 实验室→普通→仓库；第 %d 块固定屋顶款式 %d", roofIndex, roofStyle))
        elseif config.number == 7 then
            floorSupply = { 9, 3 } -- 婚介所一份、仓库一份；不新增屋顶。
            print("[Level] L7 婚介所→仓库；两份楼层不新增屋顶")
        elseif config.number == 8 or config.number == 9 then
            floorSupply = {}
            local firstRandom = 1
            if config.number == 9 then
                floorSupply[1], firstRandom = 12, 2 -- 温室永远第一份，屋顶只属于后四份随机供给。
            end
            for index = firstRandom, count do
                floorSupply[index] = RandomFloor(config.randomFloorWeights or { 9, 1, 1, 1, 1 })
            end
            if config.number == 9 then
                local roofIndex, roofStyle = math.random(firstRandom, count), math.random(1, 2)
                local roofFloor = floorSupply[roofIndex]
                assert(roofFloor ~= nil, "屋顶供给索引必须对应已有楼层")
                floorSupply[roofIndex] = roofFloor + roofStyle
                print(string.format("[Level] L9 温室→四份随机楼层；第 %d 块固定屋顶款式 %d", roofIndex, roofStyle))
            else
                print("[Level] L8 三份随机楼层（普通9、四种特殊各1），不新增屋顶")
            end
        else
            local warehouses = config.number >= 5 and math.max(0, math.min(count - roofs,
                math.floor(config.warehouseBlockCount or 0))) or 0
            for index = 1, count do
                if index <= count - roofs - warehouses then floorSupply[index] = 0
                elseif index <= count - roofs then floorSupply[index] = 3
                else floorSupply[index] = math.random(1, 2) end
            end
            print(string.format("[Level] 本次提供 %d 块楼层，%d 块随机屋顶，%d 块仓库", count, roofs, warehouses))
        end
    end
    if config.challengeRandomSupply and not constructionPrepared and not (layout and layout.pendingFloors) then
        -- fresh 已完整独立抽取；旧延期先尝试，合法排序仍可绕过暂时阻塞它的块。
        floorSupply = ChallengeSupply.Combine(floorSupply, layout and layout.deferredFloors)
    end
    lastViewWidth, lastViewHeight = 0, 0
    CreateUI()
    Level.AdaptLayout()
end

---@param segment integer
---@param layout RescueLevelLayout?
---@param activeRun ChallengeRun
local function BeginChallengeStage(segment, layout, activeRun)
    local config = ChallengeConfig.GetStage(segment)
    config.challengeRun = activeRun
    CreateGame(config, layout)
    if game and game.props:GrantTutorial() then SaveLayout() end
    if config.expansion then BeginRise(StartBuilding) else BeginRise(StartPlaying) end
    print(string.format("[挑战] 第 %d 段开始，沿用 L%d，X=%d（无教程/中间结算）",
        segment, config.number, config.catLimit))
end

function Level.Start(config)
    if config.challenge then
        local activeRun = ChallengeRun.New()
        -- 整次挑战从原始九窗开始，不读 L9/其它玩家布局。
        BeginChallengeStage(1, { floors = {}, props = {}, fences = {}, prepared = false }, activeRun)
        return
    end
    CreateGame(config)
    -- 发放绑定第二关开场教程，不绑定控制台创建、安装完成或 StartPlaying。
    if game and game.props:GrantTutorial() then SaveLayout() end
    if config.expansion then
        StartTutorial(config.buildTutorial, function() BeginRise(StartBuilding) end)
    else
        StartTutorial(config.tutorial, function() BeginRise(StartPlaying) end)
    end
    print("[Level] 场景已加载，等待教程结束")
end

local function RefreshCatchProgress()
    if catchProgress and game then
        catchProgress:SetText(string.format("已归类 %d / %d · 刷新上限%d只", game:GetOutcomeCount(),
            game.config.catLimit, game.config.catLimit))
    end
end

local function CompleteExit(target)
    Level.OnExit(target) -- 入口排队执行 Stop/换根，不在结果指针遍历内销毁控件。
end

---@param target string?
local function FinishChallenge(target)
    local activeRun, current = run, game
    if not activeRun or not current or stage == "result" then return end
    exitPaused = false
    current:CancelDrag()
    current:FinalizeRescues() -- 未满X的主动退出不补分类；已实时记录的真实接取积分仍保留。
    if current.specialFloors then current.specialFloors:Finalize() end
    if current.magnetic then current.magnetic:Finalize() end
    current.paused, current.physics.updateEnabled = true, false
    current.rescuer.touches = {}
    current.rescuer.body.linearVelocity = Vector2(0, 0)
    current.layoutDirty = false
    local score, highest, saved = activeRun:Finish()
    resultExit = target
    RefreshCatchProgress()
    Console.Update(0, current)
    SetStage("result")
    Result.StartScore(gameArea, score, highest, {
        home = function() if not resultExit then Level.RequestExit("home") end end,
        retry = function() if not exitPaused and not resultExit then pendingRestart = true end end,
        done = target and function()
            local destination = resultExit
            resultExit = nil
            if destination then CompleteExit(destination) end
        end or nil,
    }, saved)
    print(string.format("[挑战] 整次结束：出现 %d，实漏 %d，现分 %d，最高 %d，目标 %s",
        activeRun.spawned, activeRun.missed, score, highest, target or "结算"))
end

-- 退出菜单冻结所有阶段，不将原本暂停的游戏误恢复成运行。
---@return boolean
function Level.OpenExitPause()
    if pendingExit or resultExit or pendingRestart then return false end
    if not game or stage == "idle" then return false end
    if exitPaused then return true end
    resumePaused, resumePhysics = game.paused, game.physics.updateEnabled
    exitPaused = true
    game:CancelDrag()
    game.paused, game.physics.updateEnabled = true, false
    game.rescuer.touches = {}
    game.rescuer.body.linearVelocity = Vector2(0, 0)
    pan.active, pan.scrolling = false, false
    game.view:SetOffset(game.view.offset)
    return true
end

function Level.ResumeExitPause()
    if not exitPaused then return end
    exitPaused = false
    if game then game.paused, game.physics.updateEnabled = resumePaused, resumePhysics end
end

function Level.CloseExitPause()
    Level.ResumeExitPause()
end

---@param target string home / exit。
function Level.RequestExit(target)
    if target ~= "home" and target ~= "exit" then return end
    if pendingExit or resultExit then return end
    if not game or stage == "idle" then return end
    pendingRestart = false
    Level.OpenExitPause()
    pendingExit = target -- 在下一 Update 里销毁/换根，避免按钮回调内重入。
end

local function FinishPlaying()
    if not game then return end
    game:FinalizeRescues() -- 释放磁组前补记磁控/稳定栅栏猫，不冒充人物接取或隔空领取。
    if game.specialFloors then game.specialFloors:Finalize() end -- 保留末只婚介留猫的唯一救援。
    if game.magnetic then game.magnetic:Finalize() end -- 先领取已与窗内磁猫相接的物品，再保存库存。
    if run then
        if run:IsFailed() then FinishChallenge(); return end
        -- 跨段仅继承布局与库存。prepared/pendingFloors/claim 是同段重试状态，不能带过来。
        game:CancelDrag()
        local layout = SnapshotLayout()
        if run.segment > 9 then layout.deferredFloors = layout.pendingFloors end
        layout.prepared, layout.pendingFloors, layout.warehouseClaims = false, nil, nil
        local activeRun = run
        BeginChallengeStage(activeRun.segment + 1, layout, activeRun)
        return
    end
    local victory = game:IsVictory()
    RefreshCatchProgress()
    Console.Update(0, game)
    game:CancelDrag()
    game.layoutDirty = false
    SaveLayout()
    if victory and not Progress.Complete(game.config.number) then
        print("[Level] 通关成功，但本地通关记录未确认写入")
    end
    game.paused, game.physics.updateEnabled = true, false
    game.rescuer.touches = {}
    game.rescuer.body.linearVelocity = Vector2(0, 0)
    SetStage("result")
    Result.Start(gameArea, game.config.number, game.leaked, game.config.resultText, {
        home = function() Level.GoHome() end,
        retry = function() Level.RestartLevel() end,
        next = function() Level.NextLevel() end,
    }, victory)
    print(string.format("[Level] 分类 %d/%d，已漏过 %d（允许%d）；%s", game:GetOutcomeCount(),
        game.config.catLimit, game.leaked, math.floor(game.config.catLimit / 3), victory and "通关" or "未通关"))
end

function Level.Update(dt)
    if pendingRestart then
        pendingRestart = false
        Level.Start(ChallengeConfig)
        return
    end
    if pendingExit then
        local target = pendingExit
        pendingExit = nil
        exitPaused = false
        if run then
            if run.finished and stage == "result" then
                resultExit = target
                Result.RequestDone(function()
                    local destination = resultExit or target
                    resultExit = nil
                    CompleteExit(destination)
                end)
            else FinishChallenge(target) end
        else CompleteExit(target) end
        return
    end
    if stage == "idle" or not game then return end
    Level.AdaptLayout()
    if exitPaused then return end
    if stage == "camera_return" then
        -- 此阶段只推进等速下降；不更新人物/猫/盆/管/磁力，也不处理滑屏和玩法输入。
        local duration = cameraReturnOffset / CAMERA_RETURN_SPEED
        if dt > 0 and dt < math.huge then cameraReturnElapsed = math.min(duration, cameraReturnElapsed + dt) end
        local offset = math.max(0, cameraReturnOffset - cameraReturnElapsed * CAMERA_RETURN_SPEED)
        game.view:SetOffset(offset)
        game.view.target = game.view.offset
        Console.Update(dt, game)
        if cameraReturnElapsed >= duration then
            game.view:SetOffset(0)
            game.view.target = 0
            SetStage("playing")
            game.paused, game.physics.updateEnabled = false, true
            print("[Level] 回镜完成，开始救猫 Level " .. game.config.number)
        end
        return
    end
    if CanScroll() then
        if game.view:Update(dt) then RefreshPreview() end
    else
        game.view:SetOffset(game.view.offset)
    end
    if stage == "tutorial" then Tutorial.Update(dt); return end
    if stage == "result" then Result.Update(dt); return end
    -- 超漏过仍立即失败；正常终局统一等本帧猫、磁力、花盆和道具处理完。
    if stage == "playing" and game:IsFailed() then
        FinishPlaying()
        return
    end
    Console.Update(dt, game)
    if stage == "starting" then
        if not game.config.expansion then game.rescuer:Update(dt, game.paused, true) end
        if not Console.IsStarting() then
            local complete = nextAfterRise
            nextAfterRise = nil
            if complete then complete() end
        end
        return
    end
    if stage == "building" or stage == "placing" then
        if input:GetKeyPress(KEY_ESCAPE) then game:CancelDrag() end
        game.props:Update(0)
        if stage == "placing" and PlacementComplete() then StartPlaying() end
        return
    end
    if stage ~= "playing" then return end
    if input:GetKeyPress(KEY_SPACE) then game:TogglePause() end
    if input:GetKeyPress(KEY_ESCAPE) then game:CancelDrag() end
    if input:GetKeyPress(KEY_DELETE) and not game.drag.active then
        if game.props.selectedId ~= 0 then game.props:Delete(game.props.selectedId)
        else game:DeleteFence(game.selectedId) end
        SaveLayout()
    end
    if game.drag.active then
        pan.active, pan.scrolling = false, false -- 包括工具槽发起的另一根手指拖拽。
    elseif pan.active and not pan.scrolling and not pan.controlStarted then
        pan.age = pan.age + dt
        if pan.age >= 0.15 then
            game.rescuer.touches[pan.pointerId] = pan.direction
            pan.controlStarted = true
        end
    end
    game.rescuer:Update(dt, game.paused or game.drag.active, false)
    game:Update(dt) -- 所有关卡正常终局均在已在途实体更新后判定；生产仍由Game独立门控。
    RefreshCatchProgress()
    if not game.paused and game:IsFinished() then
        FinishPlaying() -- Finalize 磁接触领取之后再一次保存，避免先存半帧库存。
        return
    end
    if game.layoutDirty then
        game.layoutDirty = false
        SaveLayout() -- 收集物提交库存后同帧刷新控制台并保存，不在 Contact 写盘。
    end
end

---@param scene Scene
---@param dt number
function Level.BeforePhysics(scene, dt)
    if not exitPaused and game and stage == "playing" and game.scene == scene and not game.paused then game:ApplyFallLimit(dt) end
end

function Level.ContactEnd(nodeA, nodeB)
    if not exitPaused and game and stage == "playing" then game:SupportContact(nodeA, nodeB, false) end
end

function Level.Contact(nodeA, nodeB)
    if not exitPaused and game and stage == "playing" then game:Contact(nodeA, nodeB) end
end

---@return RescueLevelLayout
local function ExportLayout()
    if game then game:CancelDrag() end
    return SnapshotLayout()
end

function Level.RestartCurrent()
    if not game or exitPaused or stage == "idle" then return end
    if run then
        if not run.finished then FinishChallenge() else pendingRestart = true end
        return
    end
    Level.BeginPlay(game.config, ExportLayout())
end

function Level.RestartLevel()
    if stage ~= "result" or not game then return end
    Level.RestartCurrent()
end

function Level.NextLevel()
    if exitPaused or stage ~= "result" or not game then return end
    if run then Level.GoHome(); return end
    local nextConfig = Registry.Get(game.config.number + 1)
    if not nextConfig then Level.GoHome(); return end
    Level.Start(nextConfig)
end

function Level.GoHome()
    if exitPaused or resultExit or stage ~= "result" then return end
    CompleteExit("home")
end

-- 重试使用内存 prepared；选关的磁盘布局不保存 prepared，仍执行本关规定的开场操作。
---@param layout RescueLevelLayout?
function Level.BeginPlay(config, layout)
    if exitPaused then return end
    if config.challenge or config.challengeRun then Level.Start(ChallengeConfig); return end
    if not layout and game and game.config.number == config.number then layout = ExportLayout() end
    CreateGame(config, layout)
    if config.expansion and not constructionPrepared and #floorSupply > 0 then
        BeginRise(StartBuilding)
    elseif config.expansion and not constructionPrepared then
        BeginRise(function() CompleteConstruction(false) end)
    else BeginRise(StartPlaying) end
    print("[Level] 跳过教程重开 Level " .. config.number)
end

---@return string
function Level.GetState()
    return stage
end

---@return table?
function Level.GetGame()
    return game
end

function Level.Stop()
    if game then game:CancelDrag(); SaveLayout() end
    SetStage("idle")
    nextAfterRise = nil
    Tutorial.Stop()
    Result.Stop()
    Console.Stop()
    if game then game:Dispose(); game = nil end
    arena, gameArea, consolePanel, buildHint, catchProgress = nil, nil, nil, nil, nil
    constructionPrepared, wavePrepared = false, false
    cameraReturnElapsed, cameraReturnOffset = 0, 0
    warehouseClaims = nil
    floorSupply, supplyIndex, supplyDeferred = {}, 1, false
    previewCol, previewRow = -1, 0
    pan.active, pan.scrolling, pointer.known = false, false, false
    run, pendingExit, resultExit = nil, nil, nil
    exitPaused, pendingRestart, resumePaused, resumePhysics = false, false, false, false
end

return Level
