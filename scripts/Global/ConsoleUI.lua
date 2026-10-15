-- 控制台界面：复用固定桌面画幅和现有玩法，不创建新的游戏管理器。
-- 术语：“控制台”= 本模块的底部机台（红按钮=退出菜单，绿按钮=暂停/继续，
-- 绿/红猫脸数字=已拦截/已漏过，右侧凹槽=道具栏，L4增防盗窗、L5起按库存展示三种道具）。
local UI = require("urhox-libs/UI")
local Art = require("Global.WorkshopArt")
local Props = require("Global.PropSystem")
local Console = {}
---@type Panel?
local panel = nil
---@type Label?
local caughtLabel = nil
---@type Label?
local leakedLabel = nil
---@type Label?
local scoreLabel = nil
---@type table<string, Panel>
local toolPanels = {}
---@type table<string, Label?>
local stockLabels = {}
---@type number
local elapsed = 0
local riseDuration = 1.8
local riseDistance = 240
local readyTop = 560
local redPress, greenPress = 0.5, 0.5

-- 全部切图与动画共用原图坐标系，1920×360 统一缩放到 1280×240。
local sourceWidth, sourceHeight = 1920, 360
local consoleWidth, consoleHeight = 1280, 240
local consoleScale = consoleWidth / sourceWidth
local redRect = { x = 104, y = 82, w = 183, h = 139 }
local greenRect = { x = 303, y = 81, w = 183, h = 140 }

-- ==================== 启动模块：控制台升起与分层震动 ====================
-- 后续调整启动动画，只需修改 riseDuration、riseDistance 和这里的震动幅度。
function Console.Begin()
    elapsed = 0
    redPress, greenPress = 0.5, 0.5
    if panel then
        -- 先重置整棵子树的公共位移，再同时显示底图、补片、工具与数字。
        panel.props.translateY = riseDistance
        panel:SetVisible(true)
    end
    print("[控制台] 启动动画开始：升起 1.8 秒，草地/楼栋/背景分层震动")
end

function Console.IsStarting()
    return elapsed < riseDuration
end

function Console.Shake()
    if not Console.IsStarting() then return { x = 0, y = 0 } end
    local fade = math.min(1, (riseDuration - elapsed) / 0.35)
    return { x = math.sin(elapsed * 47) * fade, y = math.sin(elapsed * 61) * fade }
end

-- 库存为0时同时隐藏图标及命中；L4增教程防盗窗，L5+才开放仓库栅栏。
---@class ConsoleToolGame
---@field config {number: number}
---@field props PropSystem
---@param game ConsoleToolGame
---@param kind string
---@return boolean
local function ToolAvailable(game, kind)
    local allowed = kind == "rack" or (kind == "security_window" and game.config.number >= 4)
        or (kind == "fence" and game.config.number >= 5)
    return allowed and game.props:HasStock(kind)
end

---@param game ConsoleToolGame
function Console.RefreshTools(game)
    for kind, tool in pairs(toolPanels) do
        tool:SetVisible(ToolAvailable(game, kind))
        local label = stockLabels[kind]
        if label then label:SetText("×" .. tostring(game.props:Stock(kind))) end
    end
end

---@param dt number
function Console.Update(dt, game)
    Console.RefreshTools(game)
    local wasStarting = Console.IsStarting()
    elapsed = math.min(riseDuration, elapsed + dt)
    if panel and wasStarting then
        local progress = elapsed / riseDuration
        local offset = riseDistance * (1 - progress) ^ 2
        -- 父级视觉变换包住自绘和全部子控件，不改变任何子项的布局坐标。
        panel.props.translateY = offset
        if not Console.IsStarting() then print("[控制台] 升起完成，开始投放猫咪") end
    end
    -- 按钮反馈独立于游戏暂停，暂停后仍完成回弹。
    redPress = math.min(0.5, redPress + dt)
    greenPress = math.min(0.5, greenPress + dt)
    if caughtLabel then caughtLabel:SetText(tostring(game.intercepted)) end
    if leakedLabel then leakedLabel:SetText(tostring(game.leaked)) end
    if scoreLabel and game.run then
        local value = tostring(game.run.score)
        scoreLabel:SetText(value)
        scoreLabel:SetFontSize(math.min(30, 120 / math.max(1, #value)))
    end
end
-- ==================== 启动模块结束 ====================

local function PressOffset(time)
    if time >= 0.5 then return 0 end
    if time < 0.25 then return 8 * time / 0.25 end
    return 8 * (0.5 - time) / 0.25
end

local function DrawButton(vg, rect, path, time, color, scaleY)
    local offset = PressOffset(time) * scaleY
    nvgSave(vg)
    if time < 0.5 then
        local alpha = math.floor(85 * math.sin(time / 0.5 * math.pi))
        nvgBeginPath(vg)
        nvgEllipse(vg, rect.x + rect.w / 2, rect.y + rect.h * 0.43 + offset,
            rect.w * 0.65, rect.h * 0.55)
        nvgFillPaint(vg, nvgRadialGradient(vg, rect.x + rect.w / 2, rect.y + rect.h * 0.43 + offset,
            rect.w * 0.18, rect.w * 0.65, nvgRGBA(color[1], color[2], color[3], alpha),
            nvgRGBA(color[1], color[2], color[3], 0)))
        nvgFill(vg)
    end
    -- 帽体保持原尺寸，只沿 Y 轴下沉；固定前缘在两枚按钮之后绘制。
    Art.Image(vg, path, rect.x, rect.y + offset, rect.w, rect.h)
    nvgRestore(vg)
end

local function Button(id, sourceRect, isRed, game, handlers)
    local button = UI.Panel {
        id = id, position = "absolute", left = sourceRect.x * consoleScale,
        top = sourceRect.y * consoleScale,
        width = sourceRect.w * consoleScale, height = sourceRect.h * consoleScale,
        pointerEvents = "box-only",
        onClick = function(self, event)
            if (event and not event:IsPrimaryAction()) then return end
            if isRed then
                if redPress < 0.5 then return end
                redPress = 0
                if handlers.exit then handlers.exit() end
                print("[控制台] 红按钮：退出菜单")
            else
                if Console.IsStarting() or (handlers.canPlay and not handlers.canPlay()) then return end
                if greenPress < 0.5 then return end
                greenPress = 0
                game:TogglePause()
                print("[控制台] 绿按钮：暂停/继续")
            end
        end,
    }
    -- 子面板只负责命中与点击，帽体和固定前缘由控制台统一按层绘制。
    function button:Render(vg)
    end
    return button
end

-- 固定工具格不随隐藏重排，仍在原460×78槽内；L1-4 rack保持left166/128×72原图尺寸，L4 security占left312。
-- L5+ [rack 128] gap18 [fence 128] gap18 [security 128]，不会覆盖底板/按钮/猫计数。
-- 数字使用UI.Label而非raw文本；Tool自绘只画图形，复用UI帧/缩放，不新建字体。
local function Tool(game, handlers, kind, id, left)
    local warehouse = game.config.number >= 5
    ---@type Label?
    local count = nil
    local children = {}
    if warehouse then
        count = UI.Label {
            id = id .. "Stock", position = "absolute", right = 4, bottom = 0,
            width = 48, height = 18, text = "×" .. tostring(game.props:Stock(kind)), fontSize = 11,
            textAlign = "right", fontColor = { 238, 245, 229, 255 }, pointerEvents = "none",
        }
        stockLabels[kind] = count
        children[1] = count
    end
    local tool = UI.Panel {
        id = id, position = "absolute", left = left, top = 0, width = 128, height = 72,
        pointerEvents = "box-only", visible = ToolAvailable(game, kind), children = children,
        onPointerDown = function(event)
            if Console.IsStarting() or (handlers.canPlace and not handlers.canPlace())
                or not ToolAvailable(game, kind) or not event:IsPrimaryAction() or game.drag.active then return end
            local wx, wy = handlers.worldPoint(event)
            -- fence仍属于原Game事务；非fence不绕进栅栏，库存只在成功commit消费。
            if kind == "fence" then game:BeginDrag(event.pointerId, wx, wy, 0, 0)
            else game.props:BeginDrag(event.pointerId, wx, wy, kind, 0) end
            print(string.format("[控制台] 开始拖出 %s，当前库存 %d（预览不扣除）", kind, game.props:Stock(kind)))
        end,
        onPointerMove = handlers.move,
        onPointerUp = handlers.finish,
        onPointerCancel = handlers.cancel,
    }
    function tool:Render(vg)
        if not ToolAvailable(game, kind) then return end
        ---@type {x: number, y: number, w: number, h: number}
        local rect = self:GetAbsoluteLayout()
        local iconHeight = warehouse and rect.h - 18 or rect.h
        if kind == "rack" then Props.DrawIcon(vg, rect.x, rect.y, rect.w, iconHeight)
        elseif kind == "fence" then
            Art.Fence(vg, rect.x + rect.w / 2, rect.y + iconHeight / 2, rect.w * 0.86,
                iconHeight * 0.24, 0, false, false, true, 0)
        elseif kind == "security_window" then
            local h = iconHeight * 0.84
            local w = h * 0.72
            Props.RenderSecurity(vg, rect.x + (rect.w - w) / 2, rect.y + (iconHeight - h) / 2, w, h)
        end
    end
    toolPanels[kind] = tool
    return tool
end

function Console.Create(game, handlers)
    caughtLabel = UI.Label {
        id = "caughtNumber", position = "absolute", left = 153, top = 168,
        width = 116, height = 44, text = "0", fontSize = 30,
        fontColor = { 110, 235, 107, 255 }, pointerEvents = "none",
    }
    leakedLabel = UI.Label {
        id = "leakedNumber", position = "absolute", left = 357, top = 168,
        width = 116, height = 44, text = "0", fontSize = 30,
        fontColor = { 240, 91, 77, 255 }, pointerEvents = "none",
    }
    scoreLabel = UI.Label {
        id = "scoreNumber", position = "absolute", left = 530, top = 168,
        width = 160, height = 44, text = game.run and tostring(game.run.score) or "0",
        visible = game.run ~= nil, fontSize = 30,
        fontColor = { 255, 217, 61, 255 }, pointerEvents = "none",
    }
    toolPanels, stockLabels = {}, {}
    local tools = {}
    if game.config.number >= 5 then
        tools[1] = Tool(game, handlers, "rack", "clothesRackTool", 20)
        tools[2] = Tool(game, handlers, "fence", "fenceTool", 166)
        tools[3] = Tool(game, handlers, "security_window", "securityWindowTool", 312)
    elseif game.config.number == 4 then
        tools[1] = Tool(game, handlers, "rack", "clothesRackTool", 166)
        tools[2] = Tool(game, handlers, "security_window", "securityWindowTool", 312)
    elseif game.config.number ~= 1 then
        tools[1] = Tool(game, handlers, "rack", "clothesRackTool", 166)
    end
    local consolePanel = UI.Panel {
        id = "console", position = "absolute", left = 0, top = readyTop,
        translateY = riseDistance, visible = false,
        width = consoleWidth, height = consoleHeight, pointerEvents = "box-none",
        children = {
            -- 透明图片仅显示；底板实心区域拦截指针，避免点击穿过控制台移动栅栏。
            UI.Panel { position = "absolute", left = 0, top = 120, width = "100%", height = 120,
                pointerEvents = "box-only" },
            caughtLabel, leakedLabel, scoreLabel,
            Button("restartButton", redRect, true, game, handlers),
            Button("pauseButton", greenRect, false, game, handlers),
            UI.Panel {
                id = "toolTray", position = "absolute", left = 716, top = 136, width = 460, height = 78,
                pointerEvents = "box-none",
                children = tools,
            },
        },
    }
    function consolePanel:Render(vg)
        local rect = self:GetAbsoluteLayout()
        local sx, sy = rect.w / sourceWidth, rect.h / sourceHeight
        Art.Image(vg, "Global/Images/Console.png", rect.x, rect.y, rect.w, rect.h)
        local red = { x = rect.x + redRect.x * sx, y = rect.y + redRect.y * sy,
            w = redRect.w * sx, h = redRect.h * sy }
        local green = { x = rect.x + greenRect.x * sx, y = rect.y + greenRect.y * sy,
            w = greenRect.w * sx, h = greenRect.h * sy }
        DrawButton(vg, red, "Global/Images/ConsoleRed.png", redPress, { 245, 82, 66 }, sy)
        DrawButton(vg, green, "Global/Images/ConsoleGreen.png", greenPress, { 92, 239, 118 }, sy)
        -- 前缘始终固定，遮住平移下沉的帽体，不让帽体盖住金属底座。
        Art.Image(vg, "Global/Images/ConsoleRims.png", rect.x, rect.y, rect.w, rect.h)
    end
    panel = consolePanel
    return consolePanel
end

function Console.IsOverTray(event)
    if not panel then return false end
    local tray = panel:FindById("toolTray")
    if not tray then return false end
    local rect = tray:GetAbsoluteLayoutForHitTest()
    return event.x >= rect.x and event.x <= rect.x + rect.w and
        event.y >= rect.y and event.y <= rect.y + rect.h
end

function Console.Stop()
    panel, caughtLabel, leakedLabel, scoreLabel = nil, nil, nil, nil
    toolPanels, stockLabels = {}, {}
    elapsed = riseDuration
    redPress, greenPress = 0.5, 0.5
end

return Console

