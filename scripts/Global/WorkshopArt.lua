-- 场景为 UI.Panel 的自定义绘图，复用 UI 渲染上下文与缩放，不创建独立帧。
-- 术语：“窗洞”= 楼房图中的透明区域，等待猫脸在其中显示。
local Art = {}
local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local Fog = require("Global.WorkshopFog")
local Props = require("Global.PropSystem")

Art.palette = {
    { 245, 177, 75 }, { 89, 170, 222 }, { 236, 132, 137 },
    { 115, 186, 147 }, { 170, 146, 222 },
}

function Art.Color(color, alpha)
    return nvgRGBA(color[1], color[2], color[3], math.floor(alpha or 255))
end

function Art.Rect(vg, x, y, width, height, radius, color)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, width, height, radius)
    nvgFillColor(vg, Art.Color(color, color[4]))
    nvgFill(vg)
end

function Art.Line(vg, x1, y1, x2, y2, color, width)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x1, y1); nvgLineTo(vg, x2, y2)
    nvgStrokeColor(vg, Art.Color(color, color[4]))
    nvgStrokeWidth(vg, width or 1)
    nvgStroke(vg)
end

function Art.Circle(vg, x, y, radius, color)
    nvgBeginPath(vg); nvgCircle(vg, x, y, radius)
    nvgFillColor(vg, Art.Color(color, color[4])); nvgFill(vg)
end

function Art.Fence(vg, x, y, length, thickness, angle, selected, ghost, valid, flash)
    nvgSave(vg)
    nvgTranslate(vg, x, y)
    nvgRotate(vg, angle)
    if ghost then nvgGlobalAlpha(vg, 0.65) end
    local height = math.max(thickness, 10)
    -- 保留选中与放置有效性反馈，只替换栅栏本体外观。
    if selected or ghost then
        Art.Rect(vg, -length / 2 - 5, -height / 2 - 5, length + 10, height + 10,
            height / 2 + 5, ghost and not valid and { 239, 149, 139, 40 } or { 65, 191, 160, 40 })
    end
    Art.Image(vg, "Global/Images/Fence.png", -length / 2, -height / 2, length, height)
    if flash and flash > 0 then
        Art.Rect(vg, -length / 2, -height / 2, length, height, height / 2,
            { 230, 255, 222, math.floor(flash * 260) })
    end
    nvgRestore(vg)
end

-- 原彩色小球绘制完整保留；以后制作不同花色时可参考此代码。
--[=[
function Art.Ball(vg, x, y, radius, colorIndex, waiting, flash)
    local color = Art.palette[colorIndex]
    Art.Circle(vg, x + 1, y + 3, radius + 1, { 42, 71, 57, 25 })
    nvgBeginPath(vg); nvgCircle(vg, x, y, radius)
    local highlight = {
        math.min(255, color[1] + 35), math.min(255, color[2] + 35), math.min(255, color[3] + 35),
    }
    nvgFillPaint(vg, nvgRadialGradient(vg, x - radius * 0.32, y - radius * 0.40,
        radius * 0.03, radius * 1.2, Art.Color(highlight), Art.Color(color)))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(math.floor(color[1] * 0.82), math.floor(color[2] * 0.82),
        math.floor(color[3] * 0.82), 190))
    nvgStrokeWidth(vg, 1); nvgStroke(vg)
    Art.Circle(vg, x - radius * 0.32, y - radius * 0.40, radius * 0.20, { 255, 255, 255, 150 })
    if waiting then
        nvgBeginPath(vg); nvgCircle(vg, x, y, radius + 4)
        nvgStrokeColor(vg, Art.Color(color, 85)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
    end
    if flash > 0 then
        nvgBeginPath(vg); nvgCircle(vg, x, y, radius + (0.3 - flash) * 35)
        nvgStrokeColor(vg, Art.Color(color, math.floor(flash * 450)))
        nvgStrokeWidth(vg, 2); nvgStroke(vg)
    end
end
]=]

function Art.Ball(vg, x, y, radius, colorIndex, waiting, flash, missed, rollAngle)
    local color = Art.palette[colorIndex] -- 仅用于原有的等待和碰撞反馈，不给猫咪染色。
    local r = radius
    nvgSave(vg)
    nvgTranslate(vg, x, y)
    if missed then nvgRotate(vg, rollAngle or 0) end
    -- 白色圆脸与尖耳连成一个轮廓；耳朵仅为装饰，圆形碰撞体不变。
    nvgBeginPath(vg)
    nvgMoveTo(vg, -0.64 * r, -0.77 * r)
    nvgLineTo(vg, -0.72 * r, -1.35 * r)
    nvgLineTo(vg, -0.36 * r, -0.93 * r)
    nvgBezierTo(vg, -0.12 * r, -1.03 * r, 0.18 * r, -1.03 * r, 0.44 * r, -0.90 * r)
    nvgLineTo(vg, 0.76 * r, -1.26 * r)
    nvgLineTo(vg, 0.72 * r, -0.70 * r)
    nvgBezierTo(vg, 1.12 * r, -0.35 * r, 1.14 * r, 0.25 * r, 0.80 * r, 0.60 * r)
    nvgBezierTo(vg, 0.43 * r, 1.12 * r, -0.40 * r, 1.16 * r, -0.82 * r, 0.58 * r)
    nvgBezierTo(vg, -1.15 * r, 0.16 * r, -1.03 * r, -0.38 * r, -0.64 * r, -0.77 * r)
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 255)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(0, 0, 0, 255))
    nvgStrokeWidth(vg, math.max(1, r * 0.045)); nvgStroke(vg)
    -- 落地后将黑点眼睛改成 X；嘴巴保持原样。
    if missed then
        for _, sign in ipairs({ -1, 1 }) do
            local ex, ey, size = sign * r * 0.35, -r * 0.24, r * 0.11
            Art.Line(vg, ex - size, ey - size, ex + size, ey + size, { 0, 0, 0 }, math.max(1, r * 0.06))
            Art.Line(vg, ex - size, ey + size, ex + size, ey - size, { 0, 0, 0 }, math.max(1, r * 0.06))
        end
    else
        Art.Circle(vg, -0.35 * r, -0.24 * r, r * 0.07, { 0, 0, 0 })
        Art.Circle(vg, 0.35 * r, -0.24 * r, r * 0.07, { 0, 0, 0 })
    end
    nvgBeginPath(vg)
    nvgMoveTo(vg, -0.50 * r, 0.26 * r)
    nvgBezierTo(vg, -0.45 * r, 0.55 * r, -0.10 * r, 0.66 * r, 0, 0.25 * r)
    nvgBezierTo(vg, 0.21 * r, 0.59 * r, 0.35 * r, 0.58 * r, 0.54 * r, 0.26 * r)
    nvgStroke(vg)
    if waiting then
        nvgBeginPath(vg); nvgCircle(vg, 0, 0, r + 4)
        nvgStrokeColor(vg, Art.Color(color, 85)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
    end
    if flash > 0 then
        nvgBeginPath(vg); nvgCircle(vg, 0, 0, r + (0.3 - flash) * 35)
        nvgStrokeColor(vg, Art.Color(color, math.floor(flash * 450)))
        nvgStrokeWidth(vg, 2); nvgStroke(vg)
    end
    nvgRestore(vg)
end

-- 窗内只画方形白色猫脸，不放大下落猫咪的圆形碰撞体。
function Art.WindowCat(vg, x, y, width, height)
    nvgSave(vg)
    nvgIntersectScissor(vg, x, y, width, height)
    Art.Rect(vg, x, y, width, height, 0, { 255, 255, 255 })
    Art.Circle(vg, x + width * 0.30, y + height * 0.38, width * 0.045, { 0, 0, 0 })
    Art.Circle(vg, x + width * 0.70, y + height * 0.38, width * 0.045, { 0, 0, 0 })
    nvgBeginPath(vg)
    nvgMoveTo(vg, x + width * 0.20, y + height * 0.64)
    nvgBezierTo(vg, x + width * 0.25, y + height * 0.85,
        x + width * 0.43, y + height * 0.88, x + width * 0.50, y + height * 0.64)
    nvgBezierTo(vg, x + width * 0.63, y + height * 0.88,
        x + width * 0.73, y + height * 0.84, x + width * 0.80, y + height * 0.64)
    nvgStrokeColor(vg, nvgRGBA(0, 0, 0, 255))
    nvgStrokeWidth(vg, math.max(1, width * 0.014)); nvgStroke(vg)
    nvgRestore(vg)
end

function Art.Image(vg, path, x, y, width, height)
    local image = ImageCache.Get(path) -- 使用 UI 原有缓存，不逐帧加载纹理。
    if image <= 0 then return end
    nvgBeginPath(vg); nvgRect(vg, x, y, width, height)
    nvgFillPaint(vg, nvgImagePattern(vg, x, y, width, height, 0, math.floor(image), 1))
    nvgFill(vg)
end

-- 远景placement只消费VerticalView提供的明确rect；不重新anchor/stretch，不改猫/玩法绘制。
---@param vg NVGContextWrapper
---@param rect FarBackgroundRect NanoVG逻辑像素，progress为归一化视角0..1。
function Art.FarBackground(vg, rect)
    Art.Image(vg, "Global/Images/BackgroundFar.png", rect.x, rect.y, rect.w, rect.h)
end

function Art.Cat(vg, ball, x, y, radius)
    if not ball.magnetic then
        Art.Ball(vg, x, y, radius, ball.color, false, ball.flash, ball.missed, ball.rollAngle)
        return
    end
    nvgSave(vg)
    nvgTranslate(vg, x, y)
    if ball.missed then nvgRotate(vg, ball.rollAngle or 0) end
    -- 图8只改变外观；原猫圆形碰撞半径仍为0.20米。
    Art.Image(vg, "Global/Images/MagneticCat.png", -radius, -radius, radius * 2, radius * 2)
    if ball.missed then
        for _, sign in ipairs({ -1, 1 }) do
            local ex, ey, size = sign * radius * 0.31, -radius * 0.08, radius * 0.09
            Art.Line(vg, ex - size, ey - size, ex + size, ey + size, { 0, 0, 0 }, math.max(1, radius * 0.05))
            Art.Line(vg, ex - size, ey + size, ex + size, ey - size, { 0, 0, 0 }, math.max(1, radius * 0.05))
        end
    end
    nvgRestore(vg)
end

function Art.Building(vg, game, unit, supports)
    local bx, by, bw, bh = game:GetBuildingRect()
    -- 先画窗内底色或等待猫脸，再叠加带透明窗洞的楼房，窗框与窗台位于最前面。
    for index = 1, #game.windows do
        local x, y, w, h = game:GetWindowRect(index)
        Art.Rect(vg, x * unit, y * unit, w * unit, h * unit, 0, { 240, 228, 204 })
    end
    for _, ball in ipairs(game.balls) do
        local window = game.windows[ball.window]
        if ball.waiting and not window.matchmaking and not window.greenhouse then
            local x, y, w, h = game:GetWindowRect(ball.window)
            if ball.magnetic then
                nvgSave(vg)
                nvgIntersectScissor(vg, x * unit, y * unit, w * unit, h * unit)
                local size = math.min(w, h) * unit
                Art.Image(vg, "Global/Images/MagneticCat.png", (x + w / 2) * unit - size / 2,
                    (y + h / 2) * unit - size / 2, size, size)
                nvgRestore(vg)
            else
                Art.WindowCat(vg, x * unit, y * unit, w * unit, h * unit)
            end
        end
    end
    Art.Image(vg, game.config.house, bx * unit, by * unit, bw * unit, bh * unit)
    if game.buildingGrid then game.buildingGrid:Render(vg, unit, supports) end
    -- 新楼稿内部保留米白/玻璃底色，等待脸必须在楼图之后裁到实际窗。
    for _, ball in ipairs(game.balls) do
        local window = game.windows[ball.window]
        if ball.waiting and (window.matchmaking or window.greenhouse) then
            local x, y, w, h = game:GetWindowRect(ball.window)
            if ball.magnetic then
                nvgSave(vg)
                nvgIntersectScissor(vg, x * unit, y * unit, w * unit, h * unit)
                local size = math.min(w, h) * unit
                Art.Image(vg, "Global/Images/MagneticCat.png", (x + w / 2) * unit - size / 2,
                    (y + h / 2) * unit - size / 2, size, size)
                nvgRestore(vg)
            else Art.WindowCat(vg, x * unit, y * unit, w * unit, h * unit) end
        end
    end
    if game.specialFloors then
        game.specialFloors:RenderWaiting(vg, unit, Art)
        game.specialFloors:Render(vg, unit, Art)
    end
end

-- 释放后投影到同一世界 X 的草地；只读猫状态，不创建刚体，也不改统计。
function Art.GroundShadows(vg, balls, groundY, unit)
    for _, ball in ipairs(balls) do
        if not ball.waiting and not ball.matchmakingHeld and not ball.caught and not ball.missed and not ball.safe and not ball.trapped then
            local position = ball.node.position2D
            nvgBeginPath(vg)
            nvgEllipse(vg, position.x * unit, (groundY + ball.radius * 0.3) * unit,
                ball.radius * unit * 1.3, ball.radius * unit * 0.34)
            nvgFillColor(vg, nvgRGBA(28, 35, 29, 100)); nvgFill(vg)
        end
    end
end

function Art.Arena(vg, rect, game, shake, supports)
    if rect.w <= 0 or rect.h <= 0 then return end
    shake = shake or { x = 0, y = 0 }
    local unit = rect.w / game.width
    nvgSave(vg)
    nvgIntersectScissor(vg, rect.x, rect.y, rect.w, rect.h)
    nvgTranslate(vg, rect.x, rect.y)
    -- 双层背景始终位于所有玩法图层之下；远景先画，中景后画。
    game.view:DrawBackground(vg, Art, game, unit, shake)
    -- 前景坐标统一平移，物理坐标与碰撞尺寸保持不变。
    nvgSave(vg)
    nvgTranslate(vg, 0, game.view.offset * unit)
    -- 后层雾气：背景之上、楼房之下，团块组合缓慢晃动增加层次。
    Fog.Draw(vg, "back", rect.w, rect.h, game.clock)
    nvgSave(vg)
    nvgTranslate(vg, shake.x * 3, shake.y * 3)
    Art.Building(vg, game, unit, supports)
    nvgRestore(vg)
    -- 草花突出约 0.25 米只影响画面，矩形草地碰撞仍从 groundY 开始。
    local grassTop = (game.groundY - 0.25) * unit
    nvgSave(vg)
    nvgTranslate(vg, shake.x * 6, shake.y * 6)
    Art.Image(vg, game.config.grass, -8, grassTop, rect.w + 16, rect.h - grassTop + 8)
    nvgRestore(vg)
    -- 前层雾气：草地之上，透明度低，不遮挡栅栏与猫咪的正常显示。
    Fog.Draw(vg, "front", rect.w, rect.h, game.clock)
    Art.GroundShadows(vg, game.balls, game.groundY, unit)
    for _, fence in ipairs(game.fences) do
        if not game.drag.active or game.drag.fenceId ~= fence.id then
            Art.Fence(vg, fence.x * unit, fence.y * unit, fence.length * unit,
                fence.thickness * unit, fence.angle, game.selectedId == fence.id, false, true, fence.flash)
        end
    end
    -- 卡在窗中的实体在栏杆后绘制，防盗窗图像仍完整覆盖真实窗。
    for _, ball in ipairs(game.balls) do
        if ball.trapped and not ball.caught then
            local position = ball.node.position2D
            local wx, wy, ww, wh = game:GetWindowRect(ball.trapWindow or ball.window)
            nvgSave(vg)
            nvgIntersectScissor(vg, wx * unit, wy * unit, ww * unit, wh * unit)
            Art.Cat(vg, ball, position.x * unit, -position.y * unit, ball.radius * unit)
            nvgRestore(vg)
        end
    end
    if game.props then game.props:Render(vg, unit) end
    if game.warehouseDrops then game.warehouseDrops:Render(vg, unit) end
    for _, ball in ipairs(game.balls) do
        if not ball.waiting and not ball.matchmakingHeld and not ball.caught and not ball.trapped then
            local position = ball.node.position2D
            Art.Cat(vg, ball, position.x * unit, -position.y * unit, ball.radius * unit)
            Props.RenderParachute(vg, ball, unit)
        end
    end
    for _, particle in ipairs(game.particles) do
        local color = assert(Art.palette[particle.color] or Art.palette[1])
        Art.Circle(vg, particle.x * unit, particle.y * unit, 1.7,
            { color[1], color[2], color[3], math.floor(particle.life * 400) })
    end
    if game.flowerPots then game.flowerPots:Render(vg, unit) end
    game.rescuer:Render(vg, unit)
    if game.drag.active and game.drag.kind ~= "fence" then
        game.props:RenderPreview(vg, unit)
    elseif game.drag.active then
        local drag = game.drag
        Art.Line(vg, drag.x * unit, 0, drag.x * unit, rect.h,
            { 75, 173, 142, 50 }, 1)
        Art.Fence(vg, drag.x * unit, drag.y * unit, game.fenceLength * unit,
            game.fenceThickness * unit, drag.angle, true, true, drag.valid, 0)
    end
    nvgRestore(vg) -- 前景视角变换
    nvgRestore(vg) -- arena 原点及裁剪
end

return Art

