-- 基于 scaffold-2d-physics：物理世界与玩法数据独立于界面。
-- 术语：“猫”与“球/ball”指同一下落物（变量沿用旧名 ball）；“栅栏”= 可放置板材道具。
---@class WorkshopGame : FloorBlocksGame, SpecialFloorsGame
---@field windows FloorBlocksWindow[]
---@field balls WorkshopBall[]
---@field drag WorkshopDrag
---@field paused boolean
---@field disposed boolean
---@field timer number
---@field clock number
---@field messageTime number
---@field pendingNextCat integer
---@field finishFinalized boolean
---@field restSamples table<WorkshopBall, WorkshopRestSample?>
---@field catOutcomes table<WorkshopBall, string?> 本局永久终态，不持久化。
---@field missedCats integer
---@field finishCount integer
---@field finishVictory boolean
---@field fallSpeedLimit number
---@field lastSpawnColumn integer? 上一只成功出生的窗列，不随猫咪移动/回收改变，不存档。
---@field supportContacts table<WorkshopBall, table<number, integer?>?>
---@field run ChallengeRun? 仅 L10 挑战配置注入，多个阶段共用一份实时累计账本。
local Game = {}
Game.__index = Game
local Rescuer = require("Global.Rescuer")
local Cats = require("Global.CatSpawner")
local FloorBlocks = require("Global.FloorBlocks")
local PropSystem = require("Global.PropSystem")
local VerticalView = require("Global.VerticalView")
local FlowerPots = require("Global.FlowerPots")
local WarehouseDrops = require("Global.WarehouseDrops")
local MagneticCats = require("Global.MagneticCats")
local CatWaves = require("Global.CatWaves")
local SecurityCapture = require("Global.SecurityCapture")
local SpecialFloors = require("Global.SpecialFloors")
local CatRules = require("Global.CatOutcomeRules")

---@class WorkshopBall
---@field id integer
---@field node Node
---@field body RigidBody2D
---@field shape CollisionCircle2D
---@field missed boolean
---@field caught boolean
---@field rolling boolean
---@field rollDirection integer
---@field rollAngle number
---@field radius number
---@field previousY number
---@field color integer
---@field waiting boolean
---@field window integer
---@field intercepted boolean
---@field flash number
---@field parachute boolean
---@field safe boolean
---@field previousX number
---@field magnetic boolean
---@field magneticWindowHeight number
---@field magneticTouchedCat boolean
---@field magneticHeld boolean
---@field magneticMotionApplied boolean? 本帧磁力已写入下一物理步的重力补偿速度。
---@field trapped boolean
---@field trapWindow integer?
---@field trapX number?
---@field trapY number?
---@field rescueCounted boolean
---@field resolvedCounted boolean
---@field removed boolean?
---@field pendingGround boolean?
---@field collecting boolean?
---@field matchmakingHeld boolean?
---@field matchmakingWindow integer?
---@field sourceFloorKey string? 首次创建后由宿主登记出生楼层。
---@field greenhouseOrigin string?
---@field pairResetPending boolean? 配对移列后的本帧零速提交。
---@field safeLanding boolean? 降落伞安全留地，等待实际人物接取。

---@class WorkshopRestSample
---@field node Node
---@field x number 稳定段起点；不随每帧微位移漂移。
---@field y number
---@field duration number

---@class WorkshopDrag
---@field active boolean
---@field pointerId number
---@field fenceId integer
---@field propId integer
---@field kind string
---@field x number
---@field y number
---@field angle number
---@field valid boolean
---@field originalX number
---@field originalY number
---@field originalAngle number
---@field offsetX number
---@field offsetY number

---@class WorkshopFence
---@field id integer
---@field node Node
---@field x number
---@field y number
---@field angle number
---@field length number
---@field thickness number
---@field flash number

---@class WorkshopParticle
---@field x number
---@field y number
---@field vx number
---@field vy number
---@field life number
---@field color integer

function Game.New(config)
    local self = setmetatable({}, Game)
    self:Init(config)
    return self
end

function Game:Init(config)
    self.scene = Scene()
    self.scene:CreateComponent("Octree")
    self.scene:CreateComponent("DebugRenderer")
    self.physics = self.scene:CreateComponent("PhysicsWorld2D")
    self.physics.gravity = Vector2(0, -12)
    self.physics.continuousPhysics = true
    self.physics.velocityIterations = 10
    self.physics.positionIterations = 6
    self.physics.allowSleeping = true
    self.width, self.height = config.width, config.height
    self.groundY = config.groundY
    self.rollSpeed = 3
    self.config = config
    self.run = config.challengeRun --[[@as ChallengeRun?]]
    self.buildingWidth, self.buildingHeight = config.buildingWidth, config.buildingHeight
    -- 扩建只修改本局窗口，不污染 Config 或下一次重开的原楼配置。
    self.windows = {}
    for index, window in ipairs(config.windows) do
        self.windows[#self.windows + 1] = { x = window.x, y = window.y, w = window.w, h = window.h,
            key = "base:" .. tostring(index) }
    end
    self.view = VerticalView.New(self) --[[@as VerticalView]]
    self.buildingGrid = FloorBlocks.New(self)
    local _, _, windowWidth = self:GetWindowRect(1)
    self.fenceLength, self.fenceThickness = 2 * windowWidth, 0.20
    -- 两层楼高自由落体：v²=2gh，h=2*cellHeight；只限制下降，不限制横推/上升。
    self.fallSpeedLimit = math.sqrt(4 * math.abs(self.physics.gravity.y) * self.buildingGrid.cellHeight)
    ---@type WorkshopBall[]
    self.balls = {}
    ---@type WorkshopFence[]
    self.fences = {}
    ---@type WorkshopParticle[]
    self.particles = {}
    ---@type table<number, WorkshopBall?>
    self.ballByNode = {}
    ---@type table<number, WorkshopFence?>
    self.fenceByNode = {}
    ---@type Node[]
    self.walls = {}
    self.nextId, self.selectedId = 1, 0
    self.wave, self.intercepted, self.leaked, self.released = 0, 0, 0, 0
    self.spawned, self.resolved = 0, 0 -- 最终接住或落地的不同猫咪数量，不含栅栏重复拦截。
    self.caughtCats, self.protectedCats, self.rescuedCats = 0, 0, 0 -- 实际人物接取、窗拦截、唯一获救猫分开。
    self.finishFinalized, self.restSamples = false, {}
    self.catOutcomes, self.missedCats, self.finishCount, self.finishVictory = {}, 0, 0, false
    self.supportContacts = {}
    self.lastSpawnColumn = nil
    self.layoutDirty = false
    self.timer, self.clock, self.messageTime = 3, 0, 0
    self.phase, self.message = "ready", "从工具箱拖出栅栏，放在小球下方"
    self.paused = false
    self.drag = {
        active = false, pointerId = -1, fenceId = 0,
        x = 0, y = 0, angle = 0, valid = false,
        originalX = 0, originalY = 0, originalAngle = 0,
        offsetX = 0, offsetY = 0, kind = "fence", propId = 0,
    }
    self.props = PropSystem.New(self --[[@as PropGame]])
    self:BuildWalls()
    -- 救猫人模块接入：与猫咪共用固定物理世界。
    self.rescuer = Rescuer.New(self)
    self.flowerPots = FlowerPots.New(self --[[@as FlowerPotsGame]])
    self.warehouseDrops = WarehouseDrops.New(self --[[@as WarehouseDropsGame]])
    self.magnetic = MagneticCats.New(self --[[@as MagneticGame]])
    self.catWaves = CatWaves.New(self)
    self.securityCapture = SecurityCapture.New(self)
    self.specialFloors = SpecialFloors.New(self)
    self.pendingNextCat = 0
    self.disposed = false
    print(string.format("[玩法规则] 楼高 %.9f 米，两楼下降上限 %.6f 米/秒；栅栏 %.6f 米；X=%d，漏过>%g失败",
        self.buildingGrid.cellHeight, self.fallSpeedLimit, self.fenceLength, config.catLimit, config.catLimit / 3))
end

-- 碰撞设计（单位：米，画面 y 向下，物理 y 向上）：
--  ┌──────────── 场地宽度 ────────────┐
--  │     [窗户] 等待 1.5 秒后下落     │  猫咪：半径固定 0.20 米的动态圆
--  │           ○                    │  栅栏：静态胶囊，长2个原住户窗宽，厚0.20
--  │      ╭══════════╮              │  中间 Box + 两端 Circle，均在同一节点
--  │────── 草地顶面 height × 0.72 ──│  草地：全宽静态矩形，延伸到画面底部
--  │     ← X眼猫滚出，或滚出 →       │  接触草地只计漏一次，Update 中切换滚动
--  └────────────────────────────────┘
-- 草地组为 2，墙和栅栏组为 1；普通猫与所有组碰撞，滚出猫仅与草地碰撞。
-- 边缘：草地额外延伸左右各 2 米，确保猫咪完全离开画面后才回收。
-- 擦边：圆角端头防卡住；高速：bullet + continuousPhysics 防穿透。
-- 接触回调只记状态和数量；刚体切换和删除放在 Update 中，避开物理世界锁定。
function Game:BuildWalls()
    for _, node in ipairs(self.walls) do node:Remove(); node:Dispose() end
    self.walls = {}
    local top = self.view.minWorldY - 1
    local wallHeight = self.height - top + 4
    local wallY = (self.height + top) / 2
    local specs = {
        { x = -0.15, y = wallY, w = 0.3, h = wallHeight },
        { x = self.width + 0.15, y = wallY, w = 0.3, h = wallHeight },
        { x = self.width / 2, y = top - 0.55, w = self.width + 0.6, h = 0.3 },
        { x = self.width / 2, y = (self.groundY + self.height) / 2,
            w = self.width + 4, h = self.height - self.groundY, ground = true },
    }
    for _, spec in ipairs(specs) do
        local node = self.scene:CreateChild(spec.ground and "Ground" or "Boundary")
        node:SetPosition2D(spec.x, -spec.y)
        local body = node:CreateComponent("RigidBody2D")
        body.bodyType = BT_STATIC
        local shape = node:CreateComponent("CollisionBox2D")
        shape:SetSize(spec.w, spec.h)
        shape.friction, shape.restitution = 0.25, spec.ground and 0 or 0.3
        shape.categoryBits = spec.ground and 2 or 1
        self.walls[#self.walls + 1] = node
    end
end

-- 关卡布局由 Config 提供，共享算法不硬编码楼房位置。
function Game:GetBuildingRect()
    local rect = self.config.buildingRect
    return rect.x, rect.y, rect.w, rect.h
end

---@param index integer
---@return number, number, number, number
function Game:GetWindowRect(index)
    local bx, by, bw, bh = self:GetBuildingRect()
    local window = assert(self.windows[index], "窗口索引不存在：" .. tostring(index))
    if window.world then return window.x, window.y, window.w, window.h end
    return bx + window.x * bw / self.buildingWidth, by + window.y * bh / self.buildingHeight,
        window.w * bw / self.buildingWidth, window.h * bh / self.buildingHeight
end

function Game:GetWindowKey(index)
    local window = self.windows[index]
    return window and window.key or ""
end

-- 静止判定用连续真实物理样本，并要求Box2D已休眠，不拿低速慢落/反弹顶点当拦截。
-- ○ r=.20  ═════════ 栅栏胶囊厚=.20；包括由猫堆叠承托的静止猫。
-- 连续 .5 秒低速（<=.05米/秒）且累计偏移 <=.005米；锚点不逐帧漂移。
-- 植物慢落即使靠近栅栏侧面/下方也仍清醒；搬动/删除支撑会清样本并唤醒。
local REST_TIME, REST_SPEED, REST_TRAVEL = 0.5, 0.05, 0.005

---@param dt number
function Game:SampleRestingCats(dt)
    if dt ~= dt or dt <= 0 or dt == math.huge then return end
    ---@type table<WorkshopBall, WorkshopRestSample?>
    local samples = {}
    for _, ball in ipairs(self.balls) do
        if not ball.removed and not ball.caught and not ball.missed and not ball.waiting
            and not ball.trapped and not ball.matchmakingHeld then
            local position, velocity = ball.node.position2D, ball.body.linearVelocity
            local sample = self.restSamples[ball]
            if velocity.x ^ 2 + velocity.y ^ 2 <= REST_SPEED ^ 2 then
                if sample and sample.node == ball.node
                    and (position.x - sample.x) ^ 2 + (position.y - sample.y) ^ 2 <= REST_TRAVEL ^ 2 then
                    samples[ball] = { node = ball.node, x = sample.x, y = sample.y,
                        duration = math.min(REST_TIME, sample.duration + dt) }
                else
                    samples[ball] = { node = ball.node, x = position.x, y = position.y, duration = 0 }
                end
            end
        end
    end
    self.restSamples = samples
end

---@param ball WorkshopBall
---@return boolean
function Game:IsStableCat(ball)
    local sample = self.restSamples[ball]
    if not sample or sample.node ~= ball.node or sample.duration < REST_TIME then return false end
    local position, velocity = ball.node.position2D, ball.body.linearVelocity
    if velocity.x ^ 2 + velocity.y ^ 2 > REST_SPEED ^ 2
        or (position.x - sample.x) ^ 2 + (position.y - sample.y) ^ 2 > REST_TRAVEL ^ 2 then return false end
    return true
end

---@param ball WorkshopBall
---@return boolean
function Game:IsRestingCat(ball)
    return self:IsStableCat(ball) and not ball.body.awake
end

function Game:IsFailed()
    if self.run then return self.run:IsFailed() end
    return self.leaked * 3 > self.config.catLimit
end

function Game:GetOutcomeCount()
    return CatRules.Count(self)
end

-- 纯查询：七类不同猫覆盖X才结束；已漏猫不必等滚出，道具不再阻塞。
function Game:IsFinished()
    if self:IsFailed() or self.finishFinalized then return true end
    return not self.paused and self.spawned == self.config.catLimit
        and self:GetOutcomeCount() == self.config.catLimit
end

-- 释放磁组前冻结同一分类快照；只补安全统计，不伪造人物接取。
---@return integer
function Game:FinalizeRescues()
    if self.finishFinalized or not self:IsFinished() then return 0 end
    self.finishCount = self:GetOutcomeCount()
    self.finishVictory = not self:IsFailed() and self.spawned == self.config.catLimit
        and self.finishCount == self.config.catLimit
    ---@type {ball: WorkshopBall, reason: string}[]
    local survivors = {}
    for _, ball in ipairs(self.balls) do
        local reason = CatRules.Category(self, ball)
        if reason and reason ~= "missed" and reason ~= "caught" and not ball.rescueCounted then
            survivors[#survivors + 1] = { ball = ball, reason = reason }
        end
    end
    self.finishFinalized = true
    local count = 0
    for _, survivor in ipairs(survivors) do
        if self:MarkRescued(survivor.ball, survivor.reason) then count = count + 1 end
    end
    print(string.format("[终局] 分类 %d/%d，实漏猫 %d，已漏过 %d，补记安全猫 %d；%s",
        self.finishCount, self.config.catLimit, self.missedCats, self.leaked, count,
        self.finishVictory and "通关" or "失败"))
    return count
end

function Game:IsVictory()
    if self:IsFailed() then return false end
    if self.finishFinalized then return self.finishVictory end
    return self.spawned == self.config.catLimit and self:GetOutcomeCount() == self.config.catLimit
end

function Game:MarkResolved(ball)
    if ball.resolvedCounted then return false end
    ball.resolvedCounted = true
    self.resolved = self.resolved + 1
    return true
end

function Game:MarkRescued(ball, reason)
    if ball.rescueCounted or ball.missed then return false end
    ball.rescueCounted = true
    -- 栅栏接触和终局/人物/防盗窗救援共用同猫拦截门闩，盆扣减仍按原规则保留。
    if not ball.intercepted then
        ball.intercepted = true
        self.intercepted = self.intercepted + 1
    end
    self.rescuedCats = self.rescuedCats + 1
    self:MarkResolved(ball)
    if reason == "security_window" then self.protectedCats = self.protectedCats + 1 end
    print(string.format("[救援] 猫咪 %d：%s，唯一获救 %d，已拦截 %d，已漏过 %d",
        ball.id, reason or "caught", self.rescuedCats, self.intercepted, self.leaked))
    return true
end

function Game:CollectCat(ball)
    if not ball or ball.caught or ball.missed or ball.collecting then return false end
    -- 配对与磁组可能交叉：内部重入保护 + 各模块原子拆组，始终每猫只计一次。
    ball.collecting = true
    self.specialFloors:CollectGroup(ball)
    self.magnetic:CollectGroup(ball --[[@as MagneticCat]])
    self:MarkRescued(ball, "caught")
    ball.caught, ball.collecting = true, false
    self.catOutcomes[ball] = "caught"
    self.caughtCats = self.caughtCats + 1
    self.rescuer.hasCat = true
    if self.run then self.run:OnCaught(ball) end -- caught 真提交后计分，已 MarkRescued 的猫也可真接取。
    return true
end

-- 每个楼块有左/中/右三个窗列；lab仅中窗也不压缩列号，原九窗保原数组顺序。
---@param index integer
---@return integer?
function Game:GetSpawnColumn(index)
    local window = self.windows[index]
    if not window then return nil end
    return 3 * (window.col or 0) + (window.slot or ((index - 1) % 3 + 1)) - 1
end

---@param index integer
---@param previous integer? 不传时使用本局上一成功出生列；调度可预检普通→实验室接续。
---@return boolean
function Game:IsSpawnNear(index, previous)
    local column = self:GetSpawnColumn(index)
    local last = previous == nil and self.lastSpawnColumn or previous
    return column ~= nil and (last == nil or math.abs(column - last) < 4)
end

---@param index integer
---@param magnetic boolean?
function Game:SpawnCat(index, magnetic)
    local window = self.windows[index]
    if self.paused or self:IsFinished() or self.spawned >= self.config.catLimit or not window
        or not self:IsSpawnNear(index) then return nil end
    local ball = Cats.Create(self.scene, self.windows,
        function(windowIndex) return self:GetWindowRect(windowIndex) end, self.nextId, 1, index, magnetic)
    ball.sourceFloorKey = tostring(window.col or 0) .. ":" .. tostring(window.row or math.floor((index - 1) / 3))
    if window.greenhouse then ball.greenhouseOrigin = ball.sourceFloorKey end
    ball.matchmakingHeld = false
    self.nextId = self.nextId + 1
    self.balls[#self.balls + 1] = ball
    self.spawned = self.spawned + 1
    self.lastSpawnColumn = self:GetSpawnColumn(index)
    self.catWaves.additionalAt = self.clock + (self.config.number >= 8 and 0.3 or 0)
    self.ballByNode[ball.node.ID] = ball
    if self.run then self.run:OnSpawn(ball) end
    self.warehouseDrops:OnCatSpawn() -- 出现即掉落；不追溯出生前时间。
    return ball
end

function Game:RequestNextCat()
    if self.disposed or self:IsFinished() then return end
    ---@type integer
    local catLimit = self.config.catLimit
    self.pendingNextCat = math.min(catLimit, self.pendingNextCat + 1)
end

function Game:ProtectCat(ball, index)
    local protected = self.securityCapture:TrapFromWindow(ball, index)
    if protected and self.config.number >= 7 then self:RequestNextCat() end
    return protected
end

function Game:SetMessage(text)
    self.message, self.messageTime = text, 3
end

function Game:PrepareWave()
    if self.paused or self:IsFinished() then return 0 end
    return self.catWaves:Prepare()
end

function Game:ReleaseWave()
    if self.paused or self:IsFinished() then return 0 end
    return self.catWaves:Release()
end

function Game:WakeBalls()
    self.restSamples = {}
    for _, ball in ipairs(self.balls) do
        if not ball.waiting then ball.body.awake = true end
    end
end

function Game:FindFence(id)
    for _, fence in ipairs(self.fences) do
        if fence.id == id then return fence end
    end
    return nil
end

function Game:PointDistance(x, y, cx, cy, angle, halfLength)
    local dx, dy = x - cx, y - cy
    local cosine, sine = math.cos(angle), math.sin(angle)
    local along = dx * cosine + dy * sine
    local across = -dx * sine + dy * cosine
    ---@type number
    local clamped = math.max(-halfLength, math.min(halfLength, along))
    return math.sqrt((along - clamped) ^ 2 + across ^ 2)
end

function Game:CanPlace(x, y, angle)
    local half = self.fenceLength / 2
    local radius = self.fenceThickness / 2
    local extentX = math.abs(math.cos(angle)) * (half - radius) + radius
    local extentY = math.abs(math.sin(angle)) * (half - radius) + radius
    -- 只限制完整道具在固定画幅内；不再限制投放区、草地或与猫咪重叠。
    return x - extentX >= 0 and x + extentX <= self.width and
        y - extentY >= self.view.minWorldY and y + extentY <= self.height
end

-- 仅恢复路径调用内部工厂；玩家创建走库存与位置双重检查。
---@param self WorkshopGame
---@param x number
---@param y number
---@param angle number
---@return WorkshopFence?
local function SpawnFence(self, x, y, angle)
    if #self.fences >= 40 then
        self:SetMessage("最多可放 40 道栅栏，可右键删除旧栅栏")
        return nil
    end
    local node = self.scene:CreateChild("Fence")
    node:SetPosition2D(x, -y)
    node.rotation2D = -angle * 180 / math.pi
    local body = node:CreateComponent("RigidBody2D")
    body.bodyType = BT_STATIC
    local radius = self.fenceThickness / 2
    local box = node:CreateComponent("CollisionBox2D")
    box:SetSize(self.fenceLength - self.fenceThickness, self.fenceThickness)
    box.friction, box.restitution = 0.55, 0.25
    for _, sign in ipairs({ -1, 1 }) do
        local cap = node:CreateComponent("CollisionCircle2D")
        cap.radius = radius
        cap.center = Vector2(sign * (self.fenceLength / 2 - radius), 0)
        cap.friction, cap.restitution = 0.55, 0.25
    end
    local fence = {
        id = self.nextId, node = node, x = x, y = y, angle = angle,
        length = self.fenceLength, thickness = self.fenceThickness, flash = 0,
    }
    self.nextId = self.nextId + 1
    self.fences[#self.fences + 1] = fence
    self.fenceByNode[node.ID] = fence
    self.selectedId = fence.id
    self:WakeBalls()
    print(string.format("[落球工坊] 放置栅栏：位置 %.2f, %.2f，角度 %.0f°", x, y, angle * 180 / math.pi))
    return fence
end

function Game:CreateFence(x, y, angle)
    if not self.props:HasStock("fence") or not self:CanPlace(x, y, angle) then return nil end
    local fence = SpawnFence(self, x, y, angle)
    if fence and not self.props:ConsumeStock("fence") then
        self:DeleteFence(fence.id)
        return nil
    end
    return fence
end

function Game:RestoreFences(entries)
    for _, entry in ipairs(entries or {}) do
        if self:CanPlace(entry.x, entry.y, entry.angle) then SpawnFence(self, entry.x, entry.y, entry.angle) end
    end
end

function Game:PickFence(x, y)
    for i = #self.fences, 1, -1 do
        local fence = self.fences[i]
        if self:PointDistance(x, y, fence.x, fence.y, fence.angle, fence.length / 2) < 0.30 then
            return fence
        end
    end
    return nil
end

function Game:BeginDrag(pointerId, x, y, angle, fenceId)
    if self.drag.active then return end
    -- 栅栏与其它道具一致：落位后不可搬动，恢复的旧栅栏也不能开启移动事务。
    if fenceId ~= nil and fenceId ~= 0 then return end
    if not self.props:HasStock("fence") then return end
    local drag = self.drag
    drag.active, drag.pointerId, drag.fenceId = true, pointerId, fenceId or 0
    drag.kind, drag.propId = "fence", 0
    drag.x, drag.y, drag.angle = x, y, angle
    drag.offsetX, drag.offsetY = 0, 0
    local fence = self:FindFence(drag.fenceId)
    if fence then
        drag.originalX, drag.originalY, drag.originalAngle = fence.x, fence.y, fence.angle
        drag.offsetX, drag.offsetY = fence.x - x, fence.y - y
        drag.x, drag.y, drag.angle = fence.x, fence.y, fence.angle
        fence.node.enabled = false
        self:WakeBalls() -- 拖走支撑即失效，不等松手才清静止证据。
        self.selectedId = fence.id
    end
    drag.valid = self:CanPlace(drag.x, drag.y, drag.angle)
end

function Game:MoveDrag(pointerId, x, y)
    if self.drag.kind ~= "fence" then self.props:MoveDrag(pointerId, x, y); return end
    local drag = self.drag
    if not drag.active or pointerId ~= drag.pointerId then return end
    drag.x, drag.y = x + drag.offsetX, y + drag.offsetY
    drag.valid = self:CanPlace(drag.x, drag.y, drag.angle)
end

function Game:EndDrag(pointerId, overToolbar)
    if self.drag.kind ~= "fence" then return self.props:EndDrag(pointerId, overToolbar) end
    local drag = self.drag
    if not drag.active or pointerId ~= drag.pointerId then return end
    -- 松开这一刻重新检查，不能依赖上一帧仍为绿色的预览。
    drag.valid = self:CanPlace(drag.x, drag.y, drag.angle)
    local fence = self:FindFence(drag.fenceId)
    local dx, dy = drag.x - drag.originalX, drag.y - drag.originalY
    local unchanged = fence and dx * dx + dy * dy < 0.0025
        and math.abs(drag.angle - drag.originalAngle) < 0.001
    if fence and overToolbar then
        self:DeleteFence(fence.id)
        self:SetMessage("已收回栅栏")
    elseif overToolbar then
        self:SetMessage("已取消新栅栏，不消耗库存")
    elseif fence and unchanged then
        -- 点选不搬动栅栏时，即使上方已有小球，也恢复原碰撞体并保持选中。
        fence.node.enabled = true
        self:WakeBalls()
    elseif drag.valid then
        if fence then
            fence.x, fence.y, fence.angle = drag.x, drag.y, drag.angle
            fence.node:SetPosition2D(fence.x, -fence.y)
            fence.node.rotation2D = -fence.angle * 180 / math.pi
            fence.node.enabled = true
            self:WakeBalls()
        else
            self:CreateFence(drag.x, drag.y, drag.angle)
        end
        self:SetMessage("栅栏已固定，放置后不可移动；右键或点选后 Delete 可删除")
    else
        if fence then fence.node.enabled = true end
        self:SetMessage("这里无法放置：请让整个道具留在游戏画面内")
    end
    drag.active = false
end

function Game:CancelDrag()
    if self.drag.kind ~= "fence" then self.props:CancelDrag(); return end
    if not self.drag.active then return end
    local fence = self:FindFence(self.drag.fenceId)
    if fence then fence.node.enabled = true end
    self.drag.active = false
    self:WakeBalls()
end

function Game:DeleteFence(id)
    for i = #self.fences, 1, -1 do
        local fence = self.fences[i]
        if fence.id == id then
            self.fenceByNode[fence.node.ID] = nil
            fence.node:Remove(); fence.node:Dispose()
            table.remove(self.fences, i)
            if self.selectedId == id then self.selectedId = 0 end
            self:WakeBalls()
            return
        end
    end
end

function Game:Restart()
    self:CancelDrag()
    self.specialFloors:Dispose()
    self.specialFloors = SpecialFloors.New(self)
    self.pendingNextCat = 0
    self.magnetic:Dispose()
    self.magnetic = MagneticCats.New(self --[[@as MagneticGame]])
    self.catWaves:Reset()
    self.securityCapture:Dispose()
    self.securityCapture = SecurityCapture.New(self)
    self.flowerPots:Clear()
    self.props:Clear()
    self.props:Update(0)
    while #self.fences > 0 do self:DeleteFence(self.fences[#self.fences].id) end
    for _, ball in ipairs(self.balls) do ball.node:Remove(); ball.node:Dispose() end
    self.balls, self.ballByNode, self.particles = {}, {}, {}
    self.wave, self.intercepted, self.leaked, self.released = 0, 0, 0, 0
    self.spawned, self.resolved = 0, 0 -- 最终接住或落地的不同猫咪数量，不含栅栏重复拦截。
    self.caughtCats, self.protectedCats, self.rescuedCats = 0, 0, 0 -- 实际人物接取、窗拦截、唯一获救猫分开。
    self.finishFinalized, self.restSamples = false, {}
    self.catOutcomes, self.missedCats, self.finishCount, self.finishVictory = {}, 0, 0, false
    self.supportContacts = {}
    self.lastSpawnColumn = nil
    self.layoutDirty = false
    self.selectedId, self.nextId = 0, 1
    self.paused, self.physics.updateEnabled = false, true
    self:SetMessage("从工具箱拖出栅栏，放在小球下方")
    self.rescuer:Reset(false)
    self.warehouseDrops:Start(self.warehouseDrops:ExportClaims())
    self.flowerPots:Spawn()
    self.specialFloors:Start()
    self:PrepareWave()
    print("[落球工坊] 重新开始")
end

function Game:TogglePause()
    self.paused = not self.paused
    self.physics.updateEnabled = not self.paused
    print("[落球工坊] " .. (self.paused and "暂停物理与倒计时" or "继续实验"))
end

-- Box2D真实接触引用计数，胶囊多个fixture分别begin/end；不在回调内改物理。
function Game:SupportContact(nodeA, nodeB, begin)
    for _, entry in ipairs({ {nodeA,nodeB}, {nodeB,nodeA} }) do
        local ball = self.ballByNode[entry[1].ID]
        if ball then
            local contacts = self.supportContacts[ball] or {}
            local id = entry[2].ID
            local count = (contacts[id] or 0) + (begin and 1 or -1)
            contacts[id] = count > 0 and count or nil
            self.supportContacts[ball] = contacts
        end
    end
end

---@param nodeA Node?
---@param nodeB Node?
function Game:Contact(nodeA, nodeB)
    if not nodeA or not nodeB then return end
    self:SupportContact(nodeA, nodeB, true)
    local ballA, ballB = self.ballByNode[nodeA.ID], self.ballByNode[nodeB.ID]
    local fenceA, fenceB = self.fenceByNode[nodeA.ID], self.fenceByNode[nodeB.ID]
    local ball = ballA or ballB
    local fence = fenceA or fenceB
    if ballA and ballB then self.magnetic:Contact(ballA --[[@as MagneticCat]], ballB --[[@as MagneticCat]]) end
    if not ball or ball.waiting or ball.matchmakingHeld or ball.missed or ball.caught or ball.safe or ball.trapped then return end
    -- 晾衣架回调只展开伞状态，不在物理锁定期间改速度或删除节点。
    if self.props:Contact(ball, nodeA, nodeB) then return end
    if nodeA.ID == self.rescuer.node.ID or nodeB.ID == self.rescuer.node.ID then
        -- 持续重叠在Update统一复查；先扫防盗窗/确定落地，再接猫，避免同物理步晚接死猫。
        return
    end
    if nodeA.name == "Ground" or nodeB.name == "Ground" then
        ball.pendingGround = true -- 先留给本帧防盗窗扫掠，避免高速猫越窗触地后被提前判漏。
        return
    end
    if fence and not ball.intercepted then
        ball.intercepted = true
        self.intercepted = self.intercepted + 1
        if self.intercepted <= 5 or self.intercepted % 20 == 0 then
            print("[落球工坊] 已拦截小球：" .. self.intercepted)
        end
    end
    if ball.flash > 0.10 then return end
    ball.flash = 0.30
    if ballB then ballB.flash = 0.30 end
    if fence then fence.flash = 0.30 end
    if #self.particles > 100 then return end
    local position = ball.node.position2D
    for i = 1, 5 do
        local angle = math.random() * math.pi * 2
        self.particles[#self.particles + 1] = {
            x = position.x, y = -position.y,
            vx = math.cos(angle) * 0.6, vy = math.sin(angle) * 0.6,
            life = 0.45, color = ball.color,
        }
    end
end

-- 降落伞猫安全留地，等玩家真实接取；不冒充caught，也不把安全猫计漏。
function Game:ResolveSafeLanding(ball)
    if ball.safeLanding or ball.missed or ball.caught then return end
    self:MarkRescued(ball, "parachute")
    ball.safe, ball.safeLanding, ball.pendingGround = true, true, false
    ---@type number
    local x = math.max(ball.radius, math.min(self.width - ball.radius, ball.node.position2D.x))
    ball.node:SetPosition2D(x, -(self.groundY - ball.radius))
    ball.body.bodyType, ball.body.gravityScale = BT_KINEMATIC, 0
    ball.body.linearVelocity, ball.body.angularVelocity = Vector2(0, 0), 0
    ball.shape.maskBits = 0
    ball.previousX, ball.previousY = x, self.groundY - ball.radius
    print(string.format("[晾衣架] 猫咪 %d 安全留地，等待人物接取：已拦截 %d，已漏过 %d",
        ball.id, self.intercepted, self.leaked))
end

function Game:MarkMissed(ball)
    if ball.missed or ball.caught or ball.safeLanding or self.catOutcomes[ball] then return false end
    ball.missed = true
    ball.rollDirection = math.random(0, 1) == 0 and -1 or 1
    self.catOutcomes[ball] = "missed"
    self.missedCats, self.leaked = self.missedCats + 1, self.leaked + 1
    self:MarkResolved(ball)
    if self.run then self.run:OnMiss(ball) end -- 只累计真漏猫；盆 leaked 惩罚不是猫出生/死亡。
    print(string.format("[漏猫] #%d，实际漏猫 %d，已漏过 %d", ball.id, self.missedCats, self.leaked))
    return true
end

function Game:ResolveGroundContacts()
    for _, ball in ipairs(self.balls) do
        if ball.pendingGround then
            ball.pendingGround = false
            if not ball.trapped and not ball.matchmakingHeld and not ball.caught and not ball.missed then
                if ball.parachute then self:ResolveSafeLanding(ball)
                else self:MarkMissed(ball) end
            end
        end
    end
end

function Game:ForgetSupport(ball)
    self.supportContacts[ball] = nil
    local id = ball.node.ID
    for _, contacts in pairs(self.supportContacts) do contacts[id] = nil end
end

-- 移列是状态转换而非飞行轨迹，单猫重置所有独立扫掠/静止样本。
function Game:ResetCatSamples(ball)
    local position = ball.node.position2D
    ball.previousX, ball.previousY = position.x, -position.y
    self:ForgetSupport(ball)
    self.restSamples[ball], self.props.samples[ball.node.ID], self.flowerPots.catSamples[ball] = nil, nil, nil
end

-- 最终写速：预测下一Box2D重力/阻尼步，只取天然/伞的最小下降上限。
-- 植物是SpecialFloors帧末一次清零动作，不并入持续cap（零cap会每帧抵消重力）。
function Game:ApplyFallLimit(dt, resetOnly)
    if self.paused or dt ~= dt or dt <= 0 or dt == math.huge then return end
    for _, ball in ipairs(self.balls) do
        if ball.pairResetPending then
            if not ball.removed and not ball.caught and not ball.missed and not ball.trapped then
                ball.body.linearVelocity, ball.body.angularVelocity = Vector2(0, 0), 0
                ball.body.awake = true
                ball.magneticMotionApplied = false
                self:ResetCatSamples(ball)
            end
            ball.pairResetPending = false
        elseif not resetOnly and not ball.waiting and not ball.trapped and not ball.matchmakingHeld and not ball.caught
            and not ball.missed and not ball.safe and not ball.removed then
            local cap = ball.parachute and math.min(self.fallSpeedLimit, 1.15) or self.fallSpeedLimit
            local velocity = ball.body.linearVelocity
            local damping = 1 + math.max(0, ball.body.linearDamping) * dt
            local gravityStep = self.physics.gravity.y * ball.body.gravityScale * dt
            local predicted = (velocity.y + gravityStep) / damping
            if predicted < -cap then
                ball.body.linearVelocity = Vector2(velocity.x, -cap * damping - gravityStep)
                ball.body.awake = true
            end
        end
    end
end

function Game:Update(dt)
    self.props:Update(dt)
    if self.paused then self.warehouseDrops:Update(dt); return end
    self.clock = self.clock + dt
    self.messageTime = math.max(0, self.messageTime - dt)
    self:SampleRestingCats(dt) -- 读本次真实物理步结果，早于磁力/植物写下一步补偿指令。
    -- 先完成这一帧已在途物品的扫掠；计时事件在帧末创建的新物品下一帧才推进。
    -- 不把出生前的 dt 或人物运动轨迹追溯给新物品。
    self.specialFloors:Update(dt)
    self.securityCapture:Update()
    self:ResolveGroundContacts()
    self.magnetic:Update(dt)
    self.warehouseDrops:Update(dt)
    self.flowerPots:Update(dt)
    self.timer = self.timer - dt
    for i = #self.balls, 1, -1 do
        local ball = self.balls[i]
        ball.flash = math.max(0, ball.flash - dt)
        -- 首次接触可能只是擦边，持续接触每帧复查，移动中也能救猫。
        self.rescuer:TryCatch(ball, self, dt)
        if ball.caught then
            self:ForgetSupport(ball)
            ball.removed = true
            self.ballByNode[ball.node.ID] = nil
            ball.node:Remove(); ball.node:Dispose()
            table.remove(self.balls, i)
        elseif not ball.waiting and not ball.trapped and not ball.matchmakingHeld and not ball.safeLanding then
            if ball.missed then
                if not ball.rolling then
                    -- 在物理回调之外切换为可控滚动，绕过侧墙、栅栏和其他猫咪。
                    ball.body.bodyType = BT_KINEMATIC
                    ball.shape.categoryBits, ball.shape.maskBits = 4, 2
                    ball.rolling = true
                end
                ball.node:SetPosition2D(ball.node.position2D.x, -(self.groundY - ball.radius))
                ball.body.linearVelocity = Vector2(ball.rollDirection * self.rollSpeed, 0)
                ball.body.awake = true
                ball.rollAngle = ball.rollAngle + ball.rollDirection * self.rollSpeed / ball.radius * dt
            end
            local position = ball.node.position2D
            ball.previousX, ball.previousY = position.x, -position.y -- 防盗窗与篮口复查使用上一真实位置。
            if -position.y > self.height + 0.7 or position.x < -1 or position.x > self.width + 1 then
                if ball.parachute then
                    self:ResolveSafeLanding(ball)
                elseif not ball.missed then self:MarkMissed(ball) end
                if not ball.safeLanding then
                    self:ForgetSupport(ball)
                    print(string.format("[落球工坊] 猫咪回收：ID %d，已漏过 %d", ball.id, self.leaked))
                    ball.removed = true
                    self.ballByNode[ball.node.ID] = nil
                    ball.node:Remove(); ball.node:Dispose()
                    table.remove(self.balls, i)
                end
            end
        end
    end
    -- 接猫先读这一帧真实速度；最终控速写的是下一物理步指令，不能误判为上升。
    self.specialFloors:AfterMagnetic(dt)
    self:ApplyFallLimit(dt, true) -- 这里只提交配对零速；限速在SceneUpdate用即将步进的真实dt。
    -- 暂存产生的额外刷新排到帧末，不给新猫追溯出生前的dt。
    local additionalSpawned = 0
    if self.pendingNextCat > 0 and not self:IsFinished() then
        additionalSpawned = self.catWaves:PrepareAdditional()
        if additionalSpawned > 0 then
            self.pendingNextCat = self.pendingNextCat - 1
            if self.config.number == 9 and self.timer <= 0 then
                self.phase, self.timer = "falling", self.catWaves:NextWaveDelay()
            end
        end
    end
    -- 一帧只走一个生产入口，追加刷新不能与到期常规波叠出四只。
    -- 盆伤害和真实接猫处理完才创建下一波；新猫/物品本帧年龄为0。
    if additionalSpawned == 0 and self.timer <= 0 and not self:IsFinished() then
        if self.phase == "ready" then self:ReleaseWave()
        elseif self.phase == "full" and #self.balls >= self.catWaves:Capacity() then self.timer = 1
        else self:PrepareWave() end
    end
    for _, fence in ipairs(self.fences) do fence.flash = math.max(0, fence.flash - dt) end
    for i = #self.particles, 1, -1 do
        local particle = self.particles[i]
        particle.life = particle.life - dt
        if particle.life <= 0 then table.remove(self.particles, i)
        else
            particle.x = particle.x + particle.vx * dt
            particle.y = particle.y + particle.vy * dt
            particle.vy = particle.vy + dt
        end
    end
    if self.drag.active and self.drag.kind == "fence" then
        self.drag.valid = self:CanPlace(self.drag.x, self.drag.y, self.drag.angle)
    end
end

function Game:Dispose()
    if self.disposed then return end
    self.disposed = true
    self:CancelDrag()
    self.specialFloors:Dispose()
    self.magnetic:Dispose()
    self.catWaves:Dispose()
    self.securityCapture:Dispose()
    self.flowerPots:Dispose()
    self.warehouseDrops:Dispose()
    self.props:Clear()
    self.props:Update(0)
    self.buildingGrid:Dispose()
    self.restSamples, self.catOutcomes, self.supportContacts = {}, {}, {}
    self.scene:Dispose()
    print("[落球工坊] 物理场景已释放")
end

return Game

