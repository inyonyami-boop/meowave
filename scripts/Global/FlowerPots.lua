-- 基于 scaffold-2d-physics 的独立玩法模块，复用宿主 UI 的绘图上下文，不新增刚体/事件/绘图帧。
-- 所有状态坐标以米计，画面 Y 向下；读取现有猫/救猫人节点时使用 (position2D.x, -position2D.y)。
-- 接入：扩建/布局恢复及救猫人 Reset 后、首波 PrepareWave 前 Spawn；每帧 ReleaseWave 后、删猫前 Update。
-- Render 位于宿主 arena 原点变换内，楼房之后绘制；unit 为米到宿主逻辑像素的比例，不再次处理 DPR。
--
-- 碰撞设计（先设计后实现，尺寸不包含黑线、枝叶等图饰）：
--               [上邻窗]
--                   |
--     [同层最近左窗] [盆所在窗] [同层最近右窗]  邻接只由世界 rect 推导，不用数组序号/每层窗数。
--                   |        花盆图片高 = 所在窗宽 * 2；盆主体宽/高 = 窗宽 * 0.9。
--               [下邻窗]     盆底轴心 (x, y+h)，idle/tilting 不伤人。
--
--        枝叶（只绘制）        花盆绕盆底原地倾斜 30 度，用时 0.8 秒。
--       +---------+           falling 保持角度，盆底 X 恒定，重力 +12 米/秒²。
--       |  盆主体 | \         检测使用主体旋转后的 AABB，不把整张高图当碰撞箱。
--       +----o----+  \        o 为盆底轴心；扫掠上一位置到本帧位置，防止穿过救猫人。
--            |       +---+
--            v       |人 |    救猫人使用现有 catchWidth/height，中心读取真实节点。
--                    +---+    相对运动扫掠而非两个运动包围盒的并集，避免隔空命中。
--   ========================= 草地 groundY；先截断到首次触地，再检测这段下落，落地碎片不伤人。
-- 边界：擦边算接触；猫等待/上升/已漏/已接不触发，Release 的零初始纵速单独识别。
--       大 dt 可跨越倾斜结束/地面，剩余时间准确推进；同盆 hit 标记只扣一次；暂停不推进任何状态。
--       击中只在 intercepted>0 时扣1且 leaked 加1；为0/负不改计数，盆仍锁定一次命中并落地碎裂。

local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local IMAGE_PATH = "Global/Images/FlowerPot.png"
local GRAVITY, TILT_TIME, TILT_ANGLE = 12, 0.8, math.pi / 6
local BROKEN_TIME, EPSILON = 0.6, 0.000001

---@class FlowerPotsConfig
---@field number number?
---@field flowerPotCount number? 默认 3；0 可禁用。与比例同时配置时数量优先。
---@field flowerPotRatio number? 按全部窗口数计算，范围 0..1，始终至少留一扇空窗。

---@class FlowerPotCat
---@field id integer
---@field node Node
---@field body RigidBody2D
---@field radius number
---@field previousY number?
---@field waiting boolean
---@field missed boolean
---@field caught boolean
---@field rolling boolean?
---@field safe boolean?
---@field trapped boolean?
---@field matchmakingHeld boolean?
---@field window integer

---@class FlowerPotRescuer
---@field node Node
---@field width number
---@field height number
---@field catchWidth number?
---@field entering boolean?

---@class FlowerPotsGame
---@field config FlowerPotsConfig
---@field run ChallengeRun?
---@field windows table[]
---@field balls FlowerPotCat[]
---@field groundY number
---@field paused boolean?
---@field intercepted number
---@field leaked number
---@field rescuer FlowerPotRescuer?
---@field GetWindowRect fun(self: FlowerPotsGame, index: integer): number, number, number, number

---@class FlowerPotWindow
---@field index integer 仅供 GetWindowRect 和日志使用，不参与邻接判定。
---@field x number
---@field y number
---@field w number
---@field h number

---@class FlowerPotCatSample
---@field x number
---@field y number
---@field waiting boolean

---@class FlowerPotRescuerSample
---@field x number
---@field y number
---@field halfW number
---@field halfH number

---@class FlowerPot
---@field window FlowerPotWindow
---@field neighbors FlowerPotWindow[]
---@field x number 盆底轴心；普通盆 falling 时 X 恒定，磁场可设置水平速度。
---@field y number 盆底轴心，初始为 window.y + window.h。
---@field width number 盆主体宽，不包含图饰。
---@field height number 盆主体高，不包含枝叶。
---@field imageHeight number
---@field state "idle"|"tilting"|"falling"|"broken"
---@field age number 当前阶段计时。
---@field angle number
---@field direction number
---@field vx number 画面向右的速度；普通盆为0，不创建刚体。
---@field vy number 画面向下的速度。
---@field magneticHeld boolean? 与磁猫固定组关联时，由磁模块跟随；自身不推进/伤人。
---@field magneticShakeX number? 仅显示偏移，不参与盆主体碰撞。
---@field magneticShakeY number?
---@field collected boolean? 已随固定组接取；不伤人、不入toolbar、不改任何计数。
---@field hit boolean

---@class FlowerPots
---@field game FlowerPotsGame?
---@field pots FlowerPot[]
---@field windows FlowerPotWindow[]
---@field catSamples table<FlowerPotCat, FlowerPotCatSample>
---@field rescuerSample FlowerPotRescuerSample?
---@field disposed boolean
---@field imageWarning boolean
local FlowerPots = {}
FlowerPots.__index = FlowerPots

---@param game FlowerPotsGame
---@return FlowerPots
function FlowerPots.New(game)
    local self = setmetatable({}, FlowerPots)
    self:Init(game)
    return self
end

---@param game FlowerPotsGame
function FlowerPots:Init(game)
    self.game = game
    self.pots, self.windows, self.catSamples = {}, {}, {}
    self.rescuerSample = nil
    self.disposed, self.imageWarning = false, false
end

---@param value number
---@return boolean
local function IsFinite(value)
    return value == value and value > -math.huge and value < math.huge
end

-- slab 法：线段与 AABB 的交时区间。两轴必须在同一时刻重叠，不用 swept union 的近似。
---@param start number
---@param delta number
---@param low number
---@param high number
---@param enter number
---@param leave number
---@return boolean, number, number
local function SweepAxis(start, delta, low, high, enter, leave)
    if math.abs(delta) <= EPSILON then
        return start >= low - EPSILON and start <= high + EPSILON, enter, leave
    end
    local a, b = (low - start) / delta, (high - start) / delta
    if a > b then a, b = b, a end
    local nextEnter, nextLeave = math.max(enter, a), math.min(leave, b)
    return nextEnter <= nextLeave + EPSILON, nextEnter, nextLeave
end

---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param left number
---@param top number
---@param right number
---@param bottom number
---@return boolean
local function SweptPoint(x0, y0, x1, y1, left, top, right, bottom)
    local hitX, enter, leave = SweepAxis(x0, x1 - x0, left, right, 0, 1)
    if not hitX then return false end
    local hitY = SweepAxis(y0, y1 - y0, top, bottom, enter, leave)
    return hitY
end

-- 原楼窗的顶边有 1~2 像素偏差，扩建窗也略有高差：用垂直重合和中心距判断同层。
---@param a FlowerPotWindow
---@param b FlowerPotWindow
---@return boolean
local function SameFloor(a, b)
    local overlap = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
    -- 原楼和扩建贴图的窗台略错层（约半个窗高），但仍属于同一真实楼层。
    return overlap >= math.min(a.h, b.h) * 0.4
        and math.abs(a.y + a.h / 2 - b.y - b.h / 2) <= math.max(a.h, b.h) * 0.65
end

---@param owner FlowerPotWindow
---@param windows FlowerPotWindow[]
---@return FlowerPotWindow[]
local function FindNeighbors(owner, windows)
    ---@type FlowerPotWindow?
    local left, right, above, below = nil, nil, nil, nil
    local ownerX, ownerY = owner.x + owner.w / 2, owner.y + owner.h / 2
    local leftDist, rightDist, aboveDist, belowDist = math.huge, math.huge, math.huge, math.huge
    local aboveAlign, belowAlign = math.huge, math.huge
    for _, candidate in ipairs(windows) do
        if candidate ~= owner then
            local dx = candidate.x + candidate.w / 2 - ownerX
            local dy = candidate.y + candidate.h / 2 - ownerY
            if SameFloor(owner, candidate) then
                if dx < -EPSILON and -dx < leftDist then left, leftDist = candidate, -dx end
                if dx > EPSILON and dx < rightDist then right, rightDist = candidate, dx end
            elseif math.min(owner.x + owner.w, candidate.x + candidate.w)
                - math.max(owner.x, candidate.x) > EPSILON then
                -- 上下须横向投影相交，不把斜对角当邻窗；最近层同距时选中心对齐更好的窗。
                local alignment = math.abs(dx)
                if dy < -EPSILON and (-dy < aboveDist - EPSILON
                    or (math.abs(-dy - aboveDist) <= EPSILON and alignment < aboveAlign)) then
                    above, aboveDist, aboveAlign = candidate, -dy, alignment
                elseif dy > EPSILON and (dy < belowDist - EPSILON
                    or (math.abs(dy - belowDist) <= EPSILON and alignment < belowAlign)) then
                    below, belowDist, belowAlign = candidate, dy, alignment
                end
            end
        end
    end
    ---@type FlowerPotWindow[]
    local neighbors = {}
    for _, candidate in pairs({ left = left, right = right, above = above, below = below }) do
        neighbors[#neighbors + 1] = candidate
    end
    return neighbors
end

---@param game FlowerPotsGame
---@return FlowerPotRescuerSample?
local function ReadRescuer(game)
    local rescuer = game.rescuer
    if not rescuer or rescuer.entering or not rescuer.node.enabled then return nil end
    local position = rescuer.node.position2D
    return { x = position.x, y = -position.y,
        halfW = (rescuer.catchWidth or rescuer.width) / 2, halfH = rescuer.height / 2 }
end

--- 每局只调用一次，而不是每波生成。先 Clear，Level1/2/Home 不生成；返回实际盆数。
---@return integer
function FlowerPots:Spawn()
    if self.disposed then return 0 end
    self:Clear()
    local game = self.game
    if not game or (game.config.number or 0) < 3 then return 0 end
    for index = 1, #game.windows do
        local x, y, w, h = game:GetWindowRect(index)
        if IsFinite(x) and IsFinite(y) and IsFinite(w) and IsFinite(h) and w > 0 and h > 0
            and y + h < game.groundY then
            self.windows[#self.windows + 1] = { index = index, x = x, y = y, w = w, h = h }
        end
    end
    local levelNumber = game.config.number or 0
    local count = game.config.flowerPotCount
    if levelNumber >= 4 then
        count = levelNumber -- 第四关起只由关号决定，旧 count/ratio 不再覆盖。
    elseif count == nil then
        local ratio = game.config.flowerPotRatio
        count = ratio and IsFinite(ratio) and math.ceil(#self.windows * math.max(0, math.min(1, ratio))) or 3
    end
    if not IsFinite(count) then count = 3 end
    local capacity = levelNumber >= 4 and #self.windows or math.max(0, #self.windows - 1)
    local desired = math.floor(math.max(0, math.min(count, capacity)))
    if levelNumber >= 4 and desired < count then
        print("[花盆] 有效窗台不足，无法达到关号规定数量：" .. tostring(count))
    end
    -- 在副本上做局部 Fisher-Yates 抽样，不打乱 game.windows 或几何邻接表。
    ---@type FlowerPotWindow[]
    local candidates = {}
    for index, window in ipairs(self.windows) do candidates[index] = window end
    for index = 1, desired do
        local pick = math.random(index, #candidates)
        candidates[index], candidates[pick] = candidates[pick], candidates[index]
        local window = candidates[index] --[[@as FlowerPotWindow]]
        -- 婚恋横宽窗仍是一扇窗：盆用原住户窗尺度，避免横窗把盆放大到整楼。
        local _, _, baseWidth = game:GetWindowRect(1)
        local sourceWindow = assert(game.windows[window.index], "花盆所属窗口不存在：" .. tostring(window.index))
        local potWidth = sourceWindow.matchmaking and math.min(window.w, baseWidth) or window.w
        self.pots[#self.pots + 1] = {
            window = window, neighbors = FindNeighbors(window, self.windows),
            x = window.x + window.w / 2, y = window.y + window.h,
            width = potWidth * 0.9, height = potWidth * 0.9, imageHeight = potWidth * 2,
            state = "idle", age = 0, angle = 0,
            direction = math.random(0, 1) == 0 and -1 or 1, vx = 0, vy = 0, hit = false, collected = false,
        }
        print(string.format("[花盆] 窗台 %d：盆底 %.3f, %.3f，主体 %.3f × %.3f 米，邻窗 %d 个",
            window.index, window.x + window.w / 2, window.y + window.h,
            window.w * 0.9, window.w * 0.9, #self.pots[#self.pots].neighbors))
    end
    self.rescuerSample = ReadRescuer(game)
    print(string.format("[花盆] Level %s 本局生成 %d 盆，%d 扇可用窗（包含扩建）",
        tostring(game.config.number), desired, #self.windows))
    return desired
end

--- 返回本模块实际 falling 实体引用（包含磁猫 fixed-group held）；列表副本不可删实体。
---@return FlowerPot[]
function FlowerPots:GetFallingPots()
    ---@type FlowerPot[]
    local result = {}
    if self.disposed then return result end
    for _, pot in ipairs(self.pots) do
        if pot.state == "falling" and not pot.collected then result[#result + 1] = pot end
    end
    return result
end

---@param system FlowerPots
---@param pot FlowerPot
---@return boolean
local function OwnsFallingPot(system, pot)
    if system.disposed or type(pot) ~= "table" or pot.state ~= "falling" or pot.collected then return false end
    for _, current in ipairs(system.pots) do
        if current == pot then return true end
    end
    return false
end

--- 纯Lua速度接口，米/秒、画面y向下；不挪位置/改采样、不创建刚体，不推进dt。
--- 未held的盆由本模块恒vx+g12解析扫掠；magneticHeld盆由磁模块跟随，本模块跳过伤害。
---@param pot FlowerPot
---@param vx number
---@param vy number
---@return boolean
function FlowerPots:SetFallingMotion(pot, vx, vy)
    if not OwnsFallingPot(self, pot) or type(vx) ~= "number" or type(vy) ~= "number"
        or not IsFinite(vx) or not IsFinite(vy) then return false end
    pot.vx, pot.vy = vx, vy
    return true
end

--- 仅将本模块有效falling盆收取终结，不产生伤害/漏猫/工具库存或碎片动画。
---@param pot FlowerPot
---@return boolean
function FlowerPots:CollectPot(pot)
    if not OwnsFallingPot(self, pot) then return false end
    pot.collected, pot.magneticHeld = true, false
    pot.state, pot.age, pot.vx, pot.vy = "broken", BROKEN_TIME, 0, 0
    print(string.format("[花盆] 窗台 %d 随磁猫组收取（不伤害、不改统计/库存）", pot.window.index))
    return true
end

---@param x number
---@param y number
---@param radius number
---@param window FlowerPotWindow
---@return boolean
local function NearWindow(x, y, radius, window)
    return x >= window.x - radius and x <= window.x + window.w + radius
        and y >= window.y - radius and y <= window.y + window.h + radius
end

-- 独立保存上一帧坐标，不写 ball.previousY（宿主的接猫系统也会使用它）。
---@param pot FlowerPot
---@param ball FlowerPotCat
---@param sample FlowerPotCatSample?
---@return boolean
local function CatTriggers(pot, ball, sample)
    if ball.waiting or ball.matchmakingHeld or ball.missed or ball.caught or ball.rolling or ball.safe or ball.trapped then return false end
    local position = ball.node.position2D
    local x, y = position.x, -position.y
    local velocityY = ball.body.linearVelocity.y
    local source = sample and sample.waiting
    -- 首帧刚 Release 时尚无样本且速度为零，也接受真正位于邻窗内的释放；不把上升猫当释放。
    local released = source or (not sample and math.abs(velocityY) <= EPSILON)
    local falling = velocityY < -EPSILON
    if not falling and not released then return false end
    local x0, y0 = sample and sample.x or x, sample and sample.y or (ball.previousY or y)
    if not sample and not falling then y0 = y end
    for _, neighbor in ipairs(pot.neighbors) do
        local padding = neighbor.w * 0.25 + ball.radius
        if (falling and SweptPoint(x0, y0, x, y, neighbor.x - padding, neighbor.y - padding,
            neighbor.x + neighbor.w + padding, neighbor.y + neighbor.h + padding))
            or (released and NearWindow(x, y, ball.radius, neighbor)) then
            pot.direction = x < pot.x - EPSILON and -1 or (x > pot.x + EPSILON and 1 or pot.direction)
            return true
        end
    end
    return false
end

-- 只包围下方盆主体；倾斜的中心偏移/外接尺寸与画面同一旋转，图饰永不扩大检测。
---@param pot FlowerPot
---@return number centerX, number centerY, number halfW, number halfH
local function PotBounds(pot)
    local sine, cosine = math.sin(pot.angle), math.cos(pot.angle)
    return pot.x + sine * pot.height / 2, pot.y - cosine * pot.height / 2,
        (math.abs(cosine) * pot.width + math.abs(sine) * pot.height) / 2,
        (math.abs(sine) * pot.width + math.abs(cosine) * pot.height) / 2
end

---@param a FlowerPotRescuerSample
---@param b FlowerPotRescuerSample
---@param t number
---@return number, number
local function RescuerAt(a, b, t)
    return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
end

---@param pot FlowerPot
---@param game FlowerPotsGame
local function HitRescuer(pot, game)
    if pot.hit then return end
    pot.hit = true -- 先锁定一次伤害；零/负拦截数也不在后续重复命中时补扣。
    if game.run and not game.run:OnPotHit(pot) then
        print("[挑战积分] 花盆命中免伤：积分或累计接猫数为零")
        return -- 已处理免伤，绝不落回旧 intercepted/leaked 玩家伤害。
    end
    if game.intercepted > 0 then
        game.intercepted = game.intercepted - 1
        game.leaked = game.leaked + 1
    end
    print(string.format("[花盆] 击中救猫人一次：已拦截 %s，已漏过 %s（仅正拦截数扣1，不改 resolved）",
        tostring(game.intercepted), tostring(game.leaked)))
end

-- 花盆纵向有加速度：先求相对横向重叠的时间区间，再检查这段时间内抛物线的纵向极值。
-- 不能把加速下落直线化，否则大 dt + 横移人物可能在不同时间经过同一点而被误判。
---@param x0 number
---@param y0 number
---@param vx number
---@param vy number
---@param step number
---@param rx0 number
---@param ry0 number
---@param rx1 number
---@param ry1 number
---@param halfW number
---@param halfH number
---@return boolean
local function SweptPot(x0, y0, vx, vy, step, rx0, ry0, rx1, ry1, halfW, halfH)
    -- 磁场只写速度：X线性相对位移，Y仍为准确重力抛物线；两轴使用同一时间区间。
    local hitX, enter, leave = SweepAxis(x0 - rx0, vx * step + rx0 - rx1, -halfW, halfW, 0, 1)
    if not hitX then return false end
    local a, b, c = GRAVITY * step * step / 2, vy * step - (ry1 - ry0), y0 - ry0
    local atEnter = (a * enter + b) * enter + c
    local atLeave = (a * leave + b) * leave + c
    local lowest, highest = math.min(atEnter, atLeave), math.max(atEnter, atLeave)
    local vertex = math.max(enter, math.min(leave, -b / (2 * a)))
    local minimum = math.min(lowest, (a * vertex + b) * vertex + c)
    return minimum <= halfH + EPSILON and highest >= -halfH - EPSILON
end

---@param pot FlowerPot
---@param game FlowerPotsGame
---@param dt number
---@param previous FlowerPotRescuerSample?
---@param current FlowerPotRescuerSample?
local function AdvancePot(pot, game, dt, previous, current)
    if pot.collected or pot.magneticHeld then return end
    if pot.state == "idle" then return end
    if pot.state == "broken" then pot.age = pot.age + dt; return end
    local fallingTime, startFraction = dt, 0.0
    if pot.state == "tilting" then
        local tiltStep = math.min(dt, math.max(0, TILT_TIME - pot.age))
        pot.age = math.min(TILT_TIME, pot.age + tiltStep)
        local progress = pot.age / TILT_TIME
        pot.angle = pot.direction * TILT_ANGLE * progress * progress * (3 - 2 * progress)
        if pot.age < TILT_TIME - EPSILON then return end
        pot.state, pot.age, pot.angle, pot.vy = "falling", 0, pot.direction * TILT_ANGLE, 0
        fallingTime, startFraction = dt - tiltStep, tiltStep / dt
        print(string.format("[花盆] 窗台 %d 倾斜完成，保持 30 度垂直下落", pot.window.index))
        if fallingTime <= 0 then return end
    end
    local x0, y0, halfW, halfH = PotBounds(pot)
    local distance = math.max(0, game.groundY - y0 - halfH)
    local groundTime = distance <= 0 and 0
        or (math.sqrt(pot.vy * pot.vy + 2 * GRAVITY * distance) - pot.vy) / GRAVITY
    local step = math.min(fallingTime, groundTime)
    local initialVx, initialVy = pot.vx or 0, pot.vy
    local deltaY = initialVy * step + GRAVITY * step * step / 2
    pot.x, pot.y, pot.vy = pot.x + initialVx * step, pot.y + deltaY, initialVy + GRAVITY * step
    if not pot.hit and current and previous and step > 0 then
        local rx0, ry0 = RescuerAt(previous, current, startFraction)
        local rx1, ry1 = RescuerAt(previous, current, math.min(1, startFraction + step / dt))
        local width = halfW + math.max(previous.halfW, current.halfW)
        local height = halfH + math.max(previous.halfH, current.halfH)
        if SweptPot(x0, y0, initialVx, initialVy, step, rx0, ry0, rx1, ry1, width, height) then
            HitRescuer(pot, game)
        end
    end
    if groundTime <= fallingTime then
        pot.state, pot.age, pot.vx, pot.vy = "broken", fallingTime - step, 0, 0
        print(string.format("[花盆] 窗台 %d 花盆落地碎裂，回收碎片", pot.window.index))
    end
end

--- 由宿主在实际游玩帧调用；必须在 ReleaseWave 后且猫节点回收前，不负责推进 Box2D。
---@param dt number
function FlowerPots:Update(dt)
    local game = self.game
    if self.disposed or not game or game.paused or not IsFinite(dt) or dt <= 0 then return end
    local current = ReadRescuer(game)
    local previous = self.rescuerSample or current
    for _, pot in ipairs(self.pots) do
        if pot.state == "idle" then
            for _, ball in ipairs(game.balls) do
                if CatTriggers(pot, ball, self.catSamples[ball]) then
                    pot.state, pot.age = "tilting", 0
                    print(string.format("[花盆] 猫咪 %d 经过邻窗，窗台 %d 开始倾斜", ball.id, pot.window.index))
                    break
                end
            end
        end
        AdvancePot(pot, game, dt, previous, current)
    end
    for index = #self.pots, 1, -1 do
        local pot = self.pots[index]
        if pot.collected or (pot.state == "broken" and pot.age >= BROKEN_TIME) then table.remove(self.pots, index) end
    end
    -- 重建轻量样本表：离场猫不保留 Node 引用，重试时也不依赖可能重用的猫 ID。
    ---@type table<FlowerPotCat, FlowerPotCatSample>
    local nextSamples = {}
    for _, ball in ipairs(game.balls) do
        if not ball.missed and not ball.caught and not ball.safe and not ball.trapped and not ball.matchmakingHeld then
            local position = ball.node.position2D
            nextSamples[ball] = { x = position.x, y = -position.y, waiting = ball.waiting }
        end
    end
    self.catSamples, self.rescuerSample = nextSamples, current
end

---@param vg NVGContextWrapper
---@param pot FlowerPot
---@param unit number
local function DrawBroken(vg, pot, unit)
    local t = math.min(BROKEN_TIME, pot.age)
    nvgSave(vg)
    nvgTranslate(vg, pot.x * unit, pot.y * unit)
    nvgGlobalAlpha(vg, math.max(0, 1 - t / BROKEN_TIME))
    for index = 1, 5 do
        local sign = index % 2 == 0 and -1 or 1
        local x = (index - 3) * pot.width * 0.22 + sign * t * pot.width
        local y = -math.sin(t / BROKEN_TIME * math.pi) * pot.height * (0.4 + index * 0.08)
        local size = pot.width * (0.11 + index * 0.01) * unit
        nvgSave(vg)
        nvgTranslate(vg, x * unit, y * unit)
        nvgRotate(vg, sign * t * 5)
        nvgBeginPath(vg)
        nvgMoveTo(vg, -size, size * 0.3)
        nvgLineTo(vg, size * 0.7, -size)
        nvgLineTo(vg, size, size * 0.7)
        nvgClosePath(vg)
        nvgFillColor(vg, nvgRGBA(164, 106, 70, 255)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(0, 0, 0, 255)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
        nvgRestore(vg)
    end
    nvgRestore(vg)
end

--- 共享 ImageCache 管理纹理；不要求 WorkshopArt，避免 Art -> Game/Rescuer -> Art 的 require 环。
---@param vg NVGContextWrapper
---@param unit number
function FlowerPots:Render(vg, unit)
    if self.disposed or #self.pots == 0 or not IsFinite(unit) or unit <= 0 then return end
    local image = ImageCache.Get(IMAGE_PATH)
    local sourceW, sourceH = ImageCache.GetSize(IMAGE_PATH)
    if image <= 0 and not self.imageWarning then
        self.imageWarning = true
        print("[花盆] 图片尚未就绪：" .. IMAGE_PATH .. "；使用可见占位，检测主体尺寸不变")
    end
    for _, pot in ipairs(self.pots) do
        if pot.collected then
            -- 收取后立即隐藏；清理留给 Update，不在磁模块回调中改列表。
        elseif pot.state == "broken" then
            DrawBroken(vg, pot, unit)
        else
            nvgSave(vg)
            nvgTranslate(vg, (pot.x + (pot.magneticShakeX or 0)) * unit,
                (pot.y + (pot.magneticShakeY or 0)) * unit)
            nvgRotate(vg, pot.angle)
            local height = pot.imageHeight * unit
            local width = sourceW > 0 and sourceH > 0 and height * sourceW / sourceH or pot.window.w * unit
            if image > 0 then
                nvgBeginPath(vg); nvgRect(vg, -width / 2, -height, width, height)
                nvgFillPaint(vg, nvgImagePattern(vg, -width / 2, -height, width, height, 0, math.floor(image), 1))
                nvgFill(vg)
            else
                -- 资源失败时也不能出现不可见伤人障碍；仅为占位，不生成/修改素材。
                nvgBeginPath(vg); nvgRect(vg, -pot.width * unit / 2, -pot.height * unit, pot.width * unit, pot.height * unit)
                nvgFillColor(vg, nvgRGBA(164, 106, 70, 255)); nvgFill(vg)
                nvgStrokeColor(vg, nvgRGBA(0, 0, 0, 255)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
                nvgBeginPath(vg); nvgMoveTo(vg, 0, -pot.height * unit); nvgLineTo(vg, 0, -height)
                nvgStrokeWidth(vg, 2); nvgStroke(vg)
                nvgBeginPath(vg); nvgEllipse(vg, width * 0.17, -height * 0.79, width * 0.23, height * 0.08)
                nvgFillColor(vg, nvgRGBA(94, 143, 83, 255)); nvgFill(vg)
            end
            nvgRestore(vg)
        end
    end
end

--- 重开前清理本模块状态，不改窗口、猫、主计数或共享纹理；之后可重新 Spawn。
function FlowerPots:Clear()
    self.pots, self.windows, self.catSamples = {}, {}, {}
    self.rescuerSample = nil
    self.imageWarning = false
end

--- 必须在宿主 Scene 释放前调用；幂等，之后 Spawn/Update/Render 均不再运行。
function FlowerPots:Dispose()
    self:Clear()
    self.game, self.disposed = nil, true
end

return FlowerPots
