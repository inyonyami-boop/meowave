-- Home：铺满视口的原墙/透明窗、共享猫咪等待与跳窗，以及主题音乐。
-- 术语：本模块即“home界面”；“— 新的救援 —”是进入第一关的入口文字。
local UI = require("urhox-libs/UI")
local Art = require("Global.WorkshopArt")
local Cats = require("Global.CatSpawner")
local Fog = require("Global.WorkshopFog")
local Registry = require("Global.LevelRegistry")
local Progress = require("Global.LevelProgress")
local Themes = require("HomeThemes")
local Home = {}
---@type Scene?
local scene = nil
---@type Panel?
local canvas = nil
---@type Label?
local newRescue = nil
---@type Panel?
local rescueEntrance = nil
---@type Panel?
local challengeEntrance = nil
local DESIGN_W, DESIGN_H = 1280, 800
local UNIT = DESIGN_W / 12
-- 布局只在 Home 局部响应式扩展：保持全局 DESIGN_RESOLUTION(1280,800) 不动。
-- 整棵 canvas（Art、UI.Label、UI.Panel 真命中盒）使用同一均匀 scale / 左上原点。
-- 墙则按授权 fill 到 canvas 的全幅，源窗坐标始终用同一 wall.w / wall.h 映射。
---@type {w: number, h: number, scale: number, bottomInset: number}
local view = { w = DESIGN_W, h = DESIGN_H, scale = 1, bottomInset = 0 }
---@type SoundSource?
local musicSource = nil
local musicVolume = 0.35
local musicFadeIn = 1.0
---@type number
local musicClock = 0
local exiting = false
local resumeAudio = false

local function StopMusic()
    if not musicSource then return end
    -- StopImmediate 不依赖后续帧推进淡出；先静音，再从混音器移除并释放实例。
    musicSource:SetDeclickEnabled(false)
    musicSource:SetGain(0)
    musicSource:StopImmediate()
    musicSource:Dispose()
    musicSource = nil
    print("[Home] 音乐立即停止，关卡加载尚未开始")
end
---@type WorkshopBall[]
local balls = {}
---@type number
local clock = 0
local nextId = 1
---@type number
local timer = 0
-- 每批仍是快照中的不同通关数；只把本批出现时刻拆成逐只串行。
---@type integer[]
local batchOrder = {}
local batchCursor = 1
---@type table<number, number>
local releaseAt = {}
local spawnIntervals = { 0.4, 0.5, 0.6, 0.7, 0.8, 0.9 }
local dust = {}
-- 首页进入时读一次当前用户通关快照；刷新猫咪和绘图均不访问存档或原 statistics。
---@type table<string, boolean>
local completed = {}
---@type integer
local completedCount = 0
---@class HomeWindowEntrance
---@field number integer
---@field panel Panel
---@field label Label
---@field registered boolean
---@field window integer
---@type HomeWindowEntrance[]
local entrances = {}
-- 源墙是 2268×972；不改图、不裁边，填充整个局部逻辑画幅（包含旧 top=70 留白）。
---@type {x: number, y: number, w: number, h: number}
local wall = { x = 0, y = 0, w = DESIGN_W, h = DESIGN_H }
-- 每个品红连通区域是独立窗洞，包括管道和窗框分隔后的窄窗洞。
local windows = {
    { x = 1300, y = 172, w = 95, h = 133 }, { x = 1605, y = 188, w = 153, h = 173 },
    { x = 458, y = 242, w = 116, h = 461 }, { x = 1299, y = 343, w = 95, h = 136 },
    { x = 715, y = 403, w = 129, h = 136 }, { x = 904, y = 403, w = 137, h = 137 },
    { x = 1592, y = 412, w = 185, h = 53 }, { x = 1623, y = 518, w = 47, h = 60 },
    { x = 1724, y = 518, w = 53, h = 57 },
    { x = 716, y = 596, w = 129, h = 140 }, { x = 904, y = 596, w = 137, h = 139 },
}
-- 已核对原图 Home/Wall.png（2268 × 972）：口字是 [3]；田字四格是 [5,6,10,11]。
-- 不重排 windows：右侧其余笔画的窗洞继续参与猫咪随机选窗。
local levelWindows = {
    { number = 2, window = 3, text = "第二关" },
    { number = 3, window = 5, text = "第三关" }, -- 田左上
    { number = 4, window = 6, text = "第四关" }, -- 田右上
    { number = 5, window = 10, text = "第五关" }, -- 田左下
    { number = 6, window = 11, text = "第六关" }, -- 田右下
    { number = 7, window = 4, text = "第七关" }, -- 竖笔下窗，保留原窗顺序
    { number = 8, window = 1, text = "第八关" }, -- 竖笔上窗
    { number = 9, window = 2, text = "第九关" }, -- 右侧拱窗
}

-- 同一源图 -> 逻辑坐标变换供主题、猫脸、盆、标签锚点和入口命中盒使用。
local function WindowPixels(index)
    local window = assert(windows[index], "Home窗口索引无效：" .. tostring(index))
    return wall.x + window.x * wall.w / 2268,
        wall.y + window.y * wall.h / 972,
        window.w * wall.w / 2268, window.h * wall.h / 972
end

local function WindowRect(index)
    local x, y, w, h = WindowPixels(index)
    return x / UNIT, y / UNIT, w / UNIT, h / UNIT
end

local function LabelGap()
    -- 随墙高同比避开窗台；保底 6px，竖屏时也比盆底的 2 源像素偏移更大。
    return math.max(6, wall.h * 8 / 972)
end

local function RefreshLayout()
    if not canvas then return end
    local viewportW, viewportH = UI.GetViewportSize()
    if viewportW <= 0 or viewportH <= 0 then return end
    local scale = math.min(viewportW / DESIGN_W, viewportH / DESIGN_H)
    local width, height = viewportW / scale, viewportH / scale
    local insets = UI.GetSafeAreaInsets()
    local bottomInset = (insets.bottom or 0) / scale
    if view.w == width and view.h == height and view.scale == scale
        and view.bottomInset == bottomInset then return end
    -- resize 时连存量猫的窗中心一起映射；不改共享半径、等待时间或释放速度。
    local ratioX, ratioY = width / wall.w, height / wall.h
    for _, ball in ipairs(balls) do
        local position = ball.node.position2D
        ball.node:SetPosition2D(position.x * ratioX, position.y * ratioY)
    end
    view.w, view.h, view.scale, view.bottomInset = width, height, scale, bottomInset
    wall.w, wall.h = width, height
    canvas:SetStyle({ left = 0, top = 0, width = width, height = height,
        scale = scale, transformOrigin = "top-left" })
    for _, entrance in ipairs(entrances) do
        local x, y, w, h = WindowPixels(entrance.window)
        entrance.panel:SetStyle({ left = x, top = y, width = w, height = h })
        -- 标签放窗台以下的实墙上；第三关盆底源 y=541，标签从源 y≥547 开始。
        -- 标签与命中窗均挂同一 canvas，既不挡花盆，也不被窄窗父盒缩成不可读文字。
        local labelW = math.max(96, w)
        entrance.label:SetStyle({ left = x + (w - labelW) / 2, top = y + h + LabelGap(),
            width = labelW, height = 24 })
    end
    if rescueEntrance then
        rescueEntrance:SetStyle({ left = (width - 500) / 2,
            top = math.min(height * 0.86, height - bottomInset - 88), width = 500, height = 72 })
    end
    if challengeEntrance then
        challengeEntrance:SetStyle({ left = (width - 420) / 2,
            top = math.min(height * 0.86, height - bottomInset - 88) - 56,
            width = 420, height = 48 })
    end
    -- 每次几何变化同步 Yoga，输入不会先用旧盒而显示新位置；非变化帧不做布局。
    UI.Layout()
    print(string.format("[Home] 全幅布局 %.1f×%.1f，统一 scale %.3f，墙/窗/文字/点击同变换",
        width, height, scale))
end

local function Spawn()
    if not scene or completedCount == 0 then return end
    if batchCursor > #batchOrder then
        -- Fisher–Yates：每批先用完不同窗洞再洗下一组；数量绝不截断为窗数。
        batchOrder, batchCursor = {}, 1
        local order = {}
        for index = 1, #windows do order[index] = index end
        for index = 1, completedCount do
            local slot = (index - 1) % #windows + 1
            if slot == 1 then
                for cursor = #order, 2, -1 do
                    local other = math.random(1, cursor)
                    order[cursor], order[other] = order[other], order[cursor]
                end
            end
            batchOrder[index] = order[slot]
        end
        print(string.format("[Home] 开始逐只刷新一批：%d 只（当前用户不同通关数）", completedCount))
    end
    local windowIndex = batchOrder[batchCursor]
    -- 单元素视图保留共享 Create 的原物理参数，恢复实际窗索引供绘图。
    local ball = Cats.Create(scene, { windows[windowIndex] }, function()
        return WindowRect(windowIndex)
    end, nextId, 1)
    ball.window = windowIndex
    balls[#balls + 1] = ball
    releaseAt[ball.id] = clock + Cats.waitTime
    nextId = nextId + 1
    batchCursor = batchCursor + 1
    -- 批间也使用同样的离散间隔；卡顿不补刷成同帧多猫，按实际出现时刻重新计时。
    timer = spawnIntervals[math.random(1, #spawnIntervals)] or 0.4
end

local function RefreshEntrances()
    for _, entrance in ipairs(entrances) do
        local registered = Registry.Get(entrance.number) ~= nil
        if registered ~= entrance.registered then
            entrance.registered = registered
            entrance.panel:SetStyle({ pointerEvents = registered and "box-only" or "none" })
            entrance.label:SetStyle({ pointerEvents = registered and "box-only" or "none" })
            entrance.label:SetVisible(registered)
        end
    end
end

---@param onNewRescue fun()
---@param onSelectLevel fun(number: integer)?
function Home.Start(onNewRescue, onSelectLevel)
    Home.FinishExit()
    StopMusic() -- 重进首页也只保留一个播放实例。
    scene = Scene()
    local physics = scene:CreateComponent("PhysicsWorld2D")
    physics.gravity = Vector2(0, -12)
    physics.continuousPhysics = true
    balls = {}
    completed, completedCount = {}, 0
    entrances = {}
    view.w, view.h, view.scale, view.bottomInset = 0, 0, 0, 0
    wall.w, wall.h = DESIGN_W, DESIGN_H
    local progress = Progress.Load()
    for number, value in pairs(progress.completed) do
        if value == true then
            completed[number] = true
            completedCount = completedCount + 1
        end
    end
    clock, timer, nextId = 0, 0, 1
    batchOrder, batchCursor, releaseAt = {}, 1, {}
    musicClock = 0
    exiting = false
    dust = {}
    for index = 1, 55 do
        dust[index] = { x = math.random() * 1280, y = math.random() * 800,
            speed = 5 + math.random() * 13, radius = 0.6 + math.random() * 1.3,
            alpha = math.random(18, 55), phase = math.random() * math.pi * 2 }
    end
    local visibleThemes = {}
    for _, entry in ipairs(levelWindows) do
        -- 新主题是已注册关卡的入口预览，不应等通关才显示；旧2—5主题规则保持。
        if (entry.number >= 6 and Registry.Get(entry.number)) or completed[tostring(entry.number)] then
            visibleThemes[#visibleThemes + 1] = entry.number
        end
    end
    Themes.Prepare(visibleThemes)
    local homeCanvas = UI.Panel {
        id = "home", position = "absolute", left = 0, top = 0, width = DESIGN_W, height = DESIGN_H,
        scale = 1, transformOrigin = "top-left", overflow = "hidden", pointerEvents = "box-none",
    }
    function homeCanvas:Render(vg)
        local rect = self:GetAbsoluteLayout()
        nvgSave(vg)
        nvgTranslate(vg, rect.x, rect.y)
        nvgIntersectScissor(vg, 0, 0, view.w, view.h)
        -- 背景/墙完整覆盖视口；透明窗保留且主题/猫脸均通过 WindowPixels 同映射。
        Art.Rect(vg, 0, 0, view.w, view.h, 0, { 20, 25, 27 })
        Fog.Draw(vg, "back", view.w, view.h, clock)
        for _, entry in ipairs(levelWindows) do
            if (entry.number >= 6 and Registry.Get(entry.number)) or completed[tostring(entry.number)] then
                local x, y, w, h = WindowPixels(entry.window)
                Themes.Draw(vg, entry.number, x, y, w, h, clock, view.w, view.h)
            end
        end
        for _, ball in ipairs(balls) do
            if ball.waiting then
                local x, y, w, h = WindowPixels(ball.window)
                Art.WindowCat(vg, x, y, w, h)
            end
        end
        Art.Image(vg, "Home/Wall.png", wall.x, wall.y, wall.w, wall.h)
        -- 花盆在墙/窗台绘完后叠画，枝叶允许跨窗框；不受窗内主题的 scissor 裁剪。
        if completed["3"] then
            local x, y, w, h = WindowPixels(5)
            Themes.DrawSill(vg, x, y, w, h, view.w, view.h)
        end
        for _, ball in ipairs(balls) do
            if not ball.waiting then
                local position = ball.node.position2D
                Art.Ball(vg, position.x * UNIT, -position.y * UNIT, ball.radius * UNIT,
                    ball.color, false, 0, false, 0)
            end
        end
        Fog.Draw(vg, "front", view.w, view.h, clock)
        -- Home 灰尘：少量半透明颗粒缓慢漂浮，不参与物理；随局部画幅同步铺满。
        for _, particle in ipairs(dust) do
            Art.Circle(vg, particle.x / DESIGN_W * view.w, particle.y / DESIGN_H * view.h,
                particle.radius, { 204, 190, 155, particle.alpha })
        end
        nvgRestore(vg)
    end
    -- UI 框架默认在父 scale 下启用 DPR-only；此局部响应式 scale 必须连文字一起缩放。
    -- 使用同一棵树的标准 renderFn，框架 inverseTransformPoint 也据此处理真实点击。
    function homeCanvas:CustomRenderChildren(vg, renderFn)
        local rect = self:GetAbsoluteLayout()
        nvgSave(vg)
        nvgTextScaleMode(vg, NVG_TEXT_SCALE_FULL)
        nvgIntersectScissor(vg, rect.x, rect.y, rect.w, rect.h)
        for _, child in ipairs(self:GetRenderChildren()) do renderFn(child, vg) end
        nvgRestore(vg)
    end
    canvas = homeCanvas
    -- 入口只依真实 Registry 启用，不拿通关状态伪造解锁；后来注册的关卡自动变为入口。
    if onSelectLevel then
        for _, entry in ipairs(levelWindows) do
            local number = entry.number
            local registered = Registry.Get(number) ~= nil
            local function activate(self, event)
                if exiting or (event and not event:IsPrimaryAction()) then return end
                if not Registry.Get(number) then return end
                if event then event:StopPropagation() end
                onSelectLevel(number)
            end
            local x, y, w, h = WindowPixels(entry.window)
            local labelW = math.max(96, w)
            local label = UI.Label {
                position = "absolute", left = x + (w - labelW) / 2, top = y + h + LabelGap(),
                width = labelW, height = 24, verticalAlign = "middle",
                text = entry.text, visible = registered, fontSize = 12, textAlign = "center",
                fontColor = { 235, 226, 197, 255 }, pointerEvents = registered and "box-only" or "none",
                onClick = activate,
                textShadow = { offsetX = 1, offsetY = 1, blur = 0, color = { 0, 0, 0, 220 } },
            }
            local panel = UI.Panel {
                id = "level" .. tostring(number) .. "Window", position = "absolute",
                left = x, top = y, width = w, height = h,
                pointerEvents = registered and "box-only" or "none", onClick = activate,
            }
            canvas:AddChild(panel)
            canvas:AddChild(label)
            entrances[#entrances + 1] = {
                number = number, window = entry.window, panel = panel, label = label, registered = registered,
            }
        end
    end
    newRescue = UI.Label {
        text = "— 新的救援 —", width = "100%", height = 68,
        fontSize = 36, fontColor = { 235, 226, 197, 255 }, textAlign = "center",
        pointerEvents = "none", position = "absolute", left = 0, top = 2,
    }
    -- 抖动与淡入保持在 Label 上；Render 显式 FULL 才能继承整棵 canvas 的同步字号缩放。
    local renderLabel = newRescue.Render
    function newRescue:Render(vg)
        nvgSave(vg)
        nvgTextScaleMode(vg, NVG_TEXT_SCALE_FULL)
        renderLabel(self, vg)
        nvgRestore(vg)
    end
    rescueEntrance = UI.Panel {
        id = "newRescue", position = "absolute", left = 390, top = 688, width = 500, height = 72,
        pointerEvents = "box-only", children = { newRescue },
        onPointerDown = function(event)
            if exiting or not event:IsPrimaryAction() then return end
            event:StopPropagation()
            Home.BeginExit() -- 按下即停，不等松开/click；先关闭声音，再通知入口排队切关。
            onNewRescue()
        end,
    }
    canvas:AddChild(rescueEntrance)
    if onSelectLevel and Registry.Get(10) then
        challengeEntrance = UI.Panel {
            id = "level10Entrance", position = "absolute", left = 430, top = 632,
            width = 420, height = 48, pointerEvents = "box-only",
            children = { UI.Label {
                text = "— 第十关 · 连续救援 —", width = "100%", height = "100%",
                fontSize = 22, fontColor = { 255, 217, 61, 255 }, textAlign = "center",
                verticalAlign = "middle", pointerEvents = "none",
            } },
            onPointerDown = function(event)
                if exiting or not event:IsPrimaryAction() then return end
                event:StopPropagation()
                Home.BeginExit()
                onSelectLevel(10)
            end,
        }
        canvas:AddChild(challengeEntrance)
    end
    UI.SetRoot(UI.Panel {
        width = "100%", height = "100%", backgroundColor = { 20, 25, 27, 255 },
        pointerEvents = "box-none", children = { canvas },
    })
    RefreshLayout()
    UI.Layout()
    Spawn()
    local path = "Global/Audio/Ravens Sound.mp3"
    if cache:Exists(path) then
        local music = cache:GetResource("Sound", path) --[[@as Sound?]]
        if music then
            music:SetLooped(true)
            local node = scene:CreateChild("HomeMusic")
            musicSource = node:CreateComponent("SoundSource")
            musicSource:SetSoundType(SOUND_MUSIC)
            musicSource:Play(music, 0, 0) -- 从静音开始，由 Update 在 1 秒内渐强。
            print(string.format("[Home] 主题音乐已启动：长度 %.1f 秒，循环 %s，音量 %.2f",
                music.length, tostring(music.looped), musicSource.gain))
        end
    else
        print("[Home] 主题音乐文件缺失：" .. path)
    end
    print("[Home] 进入首页，共享猫咪等待与跳窗程序已启动")
end

function Home.BeginExit()
    if exiting then return end
    exiting = true
    -- 首页只有这一处音乐；切关重加载期间暂停音频输出，防止设备重复播放旧缓冲。
    -- 仅在本次之前确实处于播放状态时，才在关卡加载完成后恢复输出。
    resumeAudio = audio:IsPlaying()
    audio:Stop()
    StopMusic()
    print("[Home] 按下入口后音频输出已停止：" .. tostring(not audio:IsPlaying()))
end

function Home.PauseForExit()
    if scene then scene.updateEnabled = false end
end

function Home.ExitFinished()
    return exiting and musicSource == nil and not audio:IsPlaying()
end

function Home.FinishExit()
    if not resumeAudio then return end
    resumeAudio = false
    if not audio:Play() then print("[Home] 音频输出恢复失败") end
end

function Home.Update(dt)
    if exiting then return end -- 点击后不再刷猫/做布局，停乐必须先于关卡程序。
    local fadeStep = math.min(dt, 0.05)
    musicClock = math.min(musicFadeIn, musicClock + fadeStep)
    if musicSource then musicSource:SetGain(musicVolume * musicClock / musicFadeIn) end
    clock = clock + dt
    for _, particle in ipairs(dust) do
        particle.x = (particle.x + (particle.speed + math.sin(clock + particle.phase) * 6) * dt) % 1280
        particle.y = (particle.y - particle.speed * 0.25 * dt) % 800
    end
    RefreshEntrances() -- 只查内存注册表，不在每帧读取通关存档。
    RefreshLayout()
    timer = timer - dt
    if newRescue then
        newRescue:SetStyle({ translateY = math.sin(clock * 3.5) * 5,
            opacity = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(clock * 4)) })
    end
    if timer <= 0 then Spawn() end -- 每次 Update 至多出现一只，不把逾期计时补成同帧批量。
    for index = #balls, 1, -1 do
        local ball = balls[index]
        if ball.waiting and clock >= (releaseAt[ball.id] or math.huge) then
            Cats.Release(ball)
            releaseAt[ball.id] = nil
        end
        if not ball.waiting and -ball.node.position2D.y > view.h / UNIT + 0.7 then
            Cats.Remove(ball)
            table.remove(balls, index)
        end
    end
end

function Home.Stop()
    StopMusic()
    Themes.Stop()
    canvas, newRescue, rescueEntrance, challengeEntrance = nil, nil, nil, nil
    balls, entrances = {}, {}
    batchOrder, batchCursor, releaseAt = {}, 1, {}
    completed, completedCount = {}, 0
    if scene then scene:Dispose(); scene = nil end
    print("[Home] 首页音乐与猫咪场景已释放")
end

return Home

