-- 防盗窗捕获：复用宿主 scaffold-2d-physics 的 Node/刚体，不创建 Scene、刚体或事件。
-- 坐标米制、画面 y 向下；不绘图、不改库存/窗口，不在 Contact 物理锁内调用。
-- 宿主 PrepareWave 出生后调用 TrapFromWindow；每帧在猫回收/previousX/Y写回前调用 Update。
-- game:MarkRescued(ball, "security_window") 是唯一计数入口，本模块绝不直接改任何统计。
--
-- 精确碰撞设计（猫圆 r 对完整真实窗 AABB）：
--                 .------ 上边带 ------.
--              (角圆) +-------------+ (角圆)    猫中心路径 P(t)=P0+(P1-P0)*t
--               左带  |   真实窗    |  右带     窗矩形与半径 r 圆的 Minkowski 和
--              (角圆) +-------------+ (角圆)    = 两个正交边带矩形 + 四个角圆。
--                 '------ 下边带 ------'        禁止直接扩 AABB 收入角圆之外的猫。
-- 先算 edge slab 入时及 corner quadratic 首根，所有窗选最早 t，擦边也接触。
-- 首点已相交返回 t=0；水平/零长轨迹可检查已有重叠；上升且轨迹dy<0才排除。
-- 捕获后中心吸入窗内安全范围；窗小于猫直径时该轴取窗中心，不缩猫、不扩大保护。
-- 出生即拦保原出生中心。trapped 固定 trapX/Y，移动/删除窗不重开已计终态。
-- trapped 不置 caught/safe，不删除实体、不关闭 magnetic；磁猫仍可持续吸引其它物件。

---@class SecurityCaptureBall : WorkshopBall
---@field previousX number?
---@field trapped boolean?
---@field trapWindow integer?
---@field trapX number?
---@field trapY number?
---@field rescueCounted boolean?
---@field dead boolean?
---@field removed boolean?
---@field disposed boolean?

---@class SecurityCapture
---@field game any 宿主提供 balls/props/GetWindowRect/MarkRescued；不持有自己的 Scene。
---@field disposed boolean
local SecurityCapture = {}
SecurityCapture.__index = SecurityCapture

---@param value any
---@return boolean
local function Finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param ball SecurityCaptureBall
---@return boolean
local function Usable(ball)
    return ball.node ~= nil and ball.body ~= nil and ball.shape ~= nil
        and not ball.dead and not ball.removed and not ball.disposed
end

---@param ball SecurityCaptureBall
---@return boolean
local function Candidate(ball)
    return Usable(ball) and not ball.waiting and not ball.matchmakingHeld and not ball.missed and not ball.caught
        and not ball.safe and not ball.trapped and not ball.rolling
        and Finite(ball.radius) and ball.radius > 0
end

-- slab 保持两轴同一 t；不用扩大/epsilon替代角圆，也不把近水平当零长度。
---@param start number
---@param delta number
---@param low number
---@param high number
---@param enter number
---@param leave number
---@return boolean, number, number
local function Slab(start, delta, low, high, enter, leave)
    if delta == 0 then return start >= low and start <= high, enter, leave end
    local a, b = (low - start) / delta, (high - start) / delta
    local nextEnter = math.max(enter, math.min(a, b))
    local nextLeave = math.min(leave, math.max(a, b))
    return nextEnter <= nextLeave, nextEnter, nextLeave
end

---@return number? firstTime
local function BoxTime(x0, y0, dx, dy, left, top, right, bottom)
    local hitX, enter, leave = Slab(x0, dx, left, right, 0, 1)
    if not hitX then return nil end
    local hitY, first = Slab(y0, dy, top, bottom, enter, leave)
    return hitY and first or nil
end

-- |P0+tD-C|^2=r^2；用二维 cross 计算判别式，避免 b^2-a*c 大数相减。
---@return number? firstTime
local function CircleTime(x0, y0, dx, dy, cx, cy, radius)
    local qx, qy = x0 - cx, y0 - cy
    local radiusSquared = radius * radius
    if qx * qx + qy * qy <= radiusSquared then return 0 end
    local a = dx * dx + dy * dy
    if a == 0 then return nil end
    local b = qx * dx + qy * dy
    local cross = qx * dy - qy * dx
    local discriminant = a * radiusSquared - cross * cross
    if discriminant < 0 then return nil end
    local t = (-b - math.sqrt(discriminant)) / a
    if t < 0 or t > 1 then return nil end
    return t
end

---@param best number?
---@param candidate number?
---@return number?
local function Earlier(best, candidate)
    if candidate ~= nil and (best == nil or candidate < best) then return candidate end
    return best
end

---@param rect SecurityWindowRect
---@return number? firstTime
local function WindowTime(x0, y0, x1, y1, radius, rect)
    local left, top, right, bottom = rect.x, rect.y, rect.x + rect.w, rect.y + rect.h
    local dx, dy = x1 - x0, y1 - y0
    local first = BoxTime(x0, y0, dx, dy, left - radius, top, right + radius, bottom)
    first = Earlier(first, BoxTime(x0, y0, dx, dy, left, top - radius, right, bottom + radius))
    first = Earlier(first, CircleTime(x0, y0, dx, dy, left, top, radius))
    first = Earlier(first, CircleTime(x0, y0, dx, dy, right, top, radius))
    first = Earlier(first, CircleTime(x0, y0, dx, dy, left, bottom, radius))
    return Earlier(first, CircleTime(x0, y0, dx, dy, right, bottom, radius))
end

---@param value number
---@param low number
---@param size number
---@param radius number
---@return number
local function InsideCenter(value, low, size, radius)
    if size <= radius * 2 then return low + size / 2 end
    return math.max(low + radius, math.min(low + size - radius, value))
end

---@param rect SecurityWindowRect
---@return boolean
local function ValidRect(rect)
    return Finite(rect.x) and Finite(rect.y) and Finite(rect.w) and Finite(rect.h)
        and rect.w > 0 and rect.h > 0
end

---@param ball SecurityCaptureBall
local function Pin(ball)
    if not Usable(ball) or not Finite(ball.trapX) or not Finite(ball.trapY) then return end
    -- 仅由 Prepare/Update 调用，不在物理 Contact 回调修改刚体/碰撞组。
    ball.node.enabled = true
    ball.body.bodyType = BT_KINEMATIC
    ball.body.gravityScale = 0
    ball.shape.maskBits = 0
    local x, y = ball.trapX --[[@as number]], ball.trapY --[[@as number]]
    ball.node:SetPosition2D(x, -y)
    ball.body.linearVelocity = Vector2(0, 0)
    ball.body.angularVelocity = 0
    ball.body.awake = true
end

---@param game any
---@return SecurityCapture
function SecurityCapture.New(game)
    local self = setmetatable({}, SecurityCapture)
    self:Init(game)
    return self
end

---@param game any
function SecurityCapture:Init(game)
    self.game, self.disposed = game, false
end

---@param ball SecurityCaptureBall
---@param index integer
---@param x number
---@param y number
---@return boolean
function SecurityCapture:Trap(ball, index, x, y)
    local game = self.game
    if self.disposed or not game or not Usable(ball) or ball.trapped or ball.missed or ball.caught
        or ball.safe or not Finite(x) or not Finite(y) then return false end
    -- 先由宿主幂等记救援，再落 trapped；宿主不能因 waiting/安全窗状态拒绝出生即拦。
    game:MarkRescued(ball, "security_window") -- 已counted返回false仍锁窗，不重复统计。
    ball.trapped, ball.trapWindow, ball.waiting = true, index, false
    ball.safe, ball.caught = false, false
    ball.trapX, ball.trapY = x, y
    Pin(ball)
    print(string.format("[防盗窗捕获] 猫 #%d 固定于窗 %d：%.6f, %.6f（统计仅由MarkRescued写）",
        ball.id, index, x, y))
    return true
end

--- 猫真正出生后调用；保留原出生中心，不消费库存、不改出生/投放计数。
---@param ball SecurityCaptureBall
---@param index integer
---@return boolean
function SecurityCapture:TrapFromWindow(ball, index)
    local game = self.game
    if self.disposed or not game or not game.props or not Usable(ball)
        or not game.props:IsProtected(index) then return false end
    local position = ball.node.position2D
    return self:Trap(ball, index, position.x, -position.y)
end

--- 先固定所有 trapped，再对自由猫用previous/current真实轨迹扫掠；不覆盖previousX/Y。
---@return integer newlyTrapped 本次新捕获数，不重复包含已trapped猫。
function SecurityCapture:Update()
    local game = self.game
    if self.disposed or not game then return 0 end
    for _, ball in ipairs(game.balls or {}) do
        if ball.trapped then Pin(ball --[[@as SecurityCaptureBall]]) end
    end
    if game.paused or not game.props then return 0 end
    local rects = game.props:GetSecurityRects() -- 拖旧窗仍返回原窗，ghost不会进入扫描。
    local count = 0
    for _, item in ipairs(game.balls or {}) do
        local ball = item --[[@as SecurityCaptureBall]]
        if Candidate(ball) then
            local position = ball.node.position2D
            local x1, y1 = position.x, -position.y
            local x0 = Finite(ball.previousX) and ball.previousX or x1
            local y0 = Finite(ball.previousY) and ball.previousY or y1
            local velocity = ball.body.linearVelocity
            if Finite(x1) and Finite(y1) and (velocity.y < 0 or y1 - y0 >= 0) then
                ---@type SecurityWindowRect?
                local bestRect = nil
                ---@type number?
                local bestTime = nil
                for _, rect in ipairs(rects) do
                    if ValidRect(rect) then
                        local time = WindowTime(x0, y0, x1, y1, ball.radius, rect)
                        if time ~= nil and (bestTime == nil or time < bestTime) then
                            bestTime, bestRect = time, rect
                        end
                    end
                end
                if bestRect and bestTime ~= nil then
                    local hitX, hitY = x0 + (x1 - x0) * bestTime, y0 + (y1 - y0) * bestTime
                    local trapX = InsideCenter(hitX, bestRect.x, bestRect.w, ball.radius)
                    local trapY = InsideCenter(hitY, bestRect.y, bestRect.h, ball.radius)
                    if self:Trap(ball, bestRect.index, trapX, trapY) then count = count + 1 end
                end
            end
        end
    end
    return count
end

--- Scene/猫实体由宿主释放，本模块只解除宿主引用，不改已计终态或窗口保护。
function SecurityCapture:Dispose()
    self.game, self.disposed = nil, true
end

return SecurityCapture
