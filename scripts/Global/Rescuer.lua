-- ==================== 救猫人模块：入场、移动、接猫 ====================
-- 术语：“救猫人”= 举竹篮角色（Global/Images/Rescuer.png）；“接猫”= TryCatch。
local Art = require("Global.WorkshopArt")
---@class Rescuer
---@field facing number
---@field hasCat boolean
---@field speed number
local Rescuer = {}
Rescuer.__index = Rescuer

function Rescuer.New(game)
    local self = setmetatable({}, Rescuer)
    self:Init(game)
    return self
end

function Rescuer:Init(game)
    local _, _, windowWidth = game:GetWindowRect(1)
    self.width = 0.7 -- 图片宽度，单位：米；不改变独立设置的碰撞箱宽度。
    self.height = self.width * 1658 / 874 -- 高度随图片比例增加。
    self.catchWidth = windowWidth * 1.10 -- 独立设定碰撞宽度，与窗户相当。
    self.speed = 4 -- 米/秒，后续调整移动速度只修改这里。
    self.groundY = game.groundY
    self.worldWidth = game.width
    self.node = game.scene:CreateChild("Rescuer")
    self.body = self.node:CreateComponent("RigidBody2D")
    self.body.bodyType = BT_KINEMATIC
    self.body.fixedRotation = true
    self.shape = self.node:CreateComponent("CollisionBox2D")
    self.shape:SetSize(self.catchWidth, self.height)
    self.shape.trigger = true -- 只检测接猫，不阻挡猫咪或推开栅栏。
    self.shape.categoryBits, self.shape.maskBits = 16, 8
    self:Reset(true)
    print(string.format("[救猫人] 图片宽 %.3f 米，接猫矩形宽 %.3f 米", self.width, self.catchWidth))
end

-- 碰撞设计（单位：米，画面 y 向下）：
--        ○ ↓ 接受下落中的猫，移动与静止共用同一判定
--      ┌─────┐  <- 矩形上沿 groundY - height
--     [ 竹篮  ] 图片宽 0.7 米，检测宽为窗户宽度 × 1.10
--       │人│   矩形高度随图片增高，可主动接住碰到的下落猫
-- ──────┴──┴──── 草地 groundY
-- 边缘：用圆到矩形最近点判断真实接触，不隔空接猫。
-- 上升/已漏过/已接住均不接；持续重叠每帧复查，避免首次擦边错过。
-- 接触回调只标记 caught，球节点的删除留给玩法 Update，避开物理锁定。
function Rescuer:Reset(entering)
    self.entering = entering
    self.facing = -1 -- 原图朝左；静止时不修改方向。
    self.hasCat = false
    self.touches = {}
    self.body.linearVelocity = Vector2(0, 0)
    self.node:SetPosition2D(entering and self.worldWidth + self.width or self.worldWidth / 2,
        -(self.groundY - self.height / 2))
end

function Rescuer:TouchDown(event, worldX)
    if not event:IsTouch() then return end
    self.touches[event.pointerId] = worldX < self.worldWidth / 2 and -1 or 1
end

function Rescuer:TouchMove(event, worldX)
    if self.touches[event.pointerId] then
        self.touches[event.pointerId] = worldX < self.worldWidth / 2 and -1 or 1
    end
end

function Rescuer:TouchUp(event)
    self.touches[event.pointerId] = nil
end

function Rescuer:Update(dt, paused, opening)
    if self.entering then
        -- 开场物理未启用，直接插值入场；完成后恢复用刚体速度移动。
        ---@type number
        local x = math.max(self.worldWidth / 2, self.node.position2D.x - self.speed * dt)
        self.node:SetPosition2D(x, -(self.groundY - self.height / 2))
        if x <= self.worldWidth / 2 then
            self.entering = false
            print("[救猫人] 入场完成")
        end
        return
    end
    if opening or paused then
        self.body.linearVelocity = Vector2(0, 0)
        if paused then self.touches = {} end -- 暂停时清除长按，避免继续后残留移动。
        return
    end
    local direction = 0
    if input:GetKeyDown(KEY_A) then direction = direction - 1 end
    if input:GetKeyDown(KEY_D) then direction = direction + 1 end
    for _, touchDirection in pairs(self.touches) do direction = direction + touchDirection end
    direction = direction < 0 and -1 or (direction > 0 and 1 or 0)
    if direction ~= 0 then self.facing = direction end
    local x = self.node.position2D.x
    local half = self.width / 2
    if x < half or x > self.worldWidth - half then
        self.node:SetPosition2D(math.max(half, math.min(x, self.worldWidth - half)),
            -(self.groundY - self.height / 2))
    end
    local velocity = direction * self.speed
    if direction < 0 then velocity = math.max(velocity, (half - x) / math.max(dt, 0.001)) end
    if direction > 0 then velocity = math.min(velocity, (self.worldWidth - half - x) / math.max(dt, 0.001)) end
    self.body.linearVelocity = Vector2(velocity, 0)
    self.body.awake = true
end

function Rescuer:TryCatch(ball, game, dt)
    if self.entering or ball.waiting or ball.matchmakingHeld or ball.missed or ball.caught then return end
    local position = ball.node.position2D
    local top = self.groundY - self.height
    -- 磁力可能已写入下一步重力补偿；还原下降方向，不把正的指令速度误判为上升。
    local vertical = ball.body.linearVelocity.y
    if ball.magneticMotionApplied and dt and dt > 0 then
        vertical = vertical + game.physics.gravity.y * ball.body.gravityScale * dt
    end
    -- 磁组里任一成员真正碰到人物即可接住；普通自由猫仍保持只接下落的规则。
    if not ball.magnetic and not ball.magneticHeld and not ball.trapped and not ball.safeLanding and vertical >= 0 then return end
    -- 圆形猫咪与角色矩形的最近点，保证必须真正接触。
    ---@type number
    local dx = math.max(0, math.abs(position.x - self.node.position2D.x) - self.catchWidth / 2)
    local y = -position.y
    ---@type number
    local dy = math.max(top - y, 0, y - self.groundY)
    if dx * dx + dy * dy > ball.radius * ball.radius then return end
    game:CollectCat(ball) -- 联组及每猫唯一计数由宿主完成；物理回调不删除任何实体。
end

function Rescuer:Render(vg, unit)
    local x = self.node.position2D.x * unit
    local top = (self.groundY - self.height) * unit
    local width, height = self.width * unit, self.height * unit
    nvgSave(vg)
    nvgTranslate(vg, x, top)
    if self.facing > 0 then nvgScale(vg, -1, 1) end
    Art.Image(vg, "Global/Images/Rescuer.png", -width / 2, 0, width, height)
    if self.hasCat then
        -- 只露出篮口上方半个猫头，不把完整猫身画在篮子前面。
        local radius = width * 0.24
        local rim = height * 0.045
        nvgSave(vg)
        nvgIntersectScissor(vg, -width / 2, -radius * 1.5, width, rim + radius * 1.5)
        Art.Ball(vg, 0, rim, radius, 1, false, 0, false, 0)
        nvgRestore(vg)
    end
    nvgRestore(vg)
end

return Rescuer
-- ==================== 救猫人模块结束 ====================

