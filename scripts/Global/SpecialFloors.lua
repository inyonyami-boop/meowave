-- 特殊楼层机制；沿用宿主 scaffold-2d-physics 的生命周期。
-- New 仅初始化本局数据；Start 在布局恢复完成后、首波之前抽爆率，冻结期间仍显示。
-- Update 在 Security/Ground 之前；AfterMagnetic 在所有磁力/伞速度写入之后执行最终控速。
-- 不创建 Scene/Node/碰撞体/事件/存档/图片/NanoVG 帧；宿主持有所有原生对象。
-- 长度单位米；逻辑 y 向下，node/body 的物理 y 向上。
--
-- 碰撞设计（普通猫圆半径始终不变）：
--                    slot1       slot2       slot3
-- 婚恋/原楼：       |<------- 实际窗水平横带 -------->|
--                  +---------------------------------+ 实际窗顶/窗高
--                  | O 途经暂存；第二 O 途经两只一起落 |
--                  +---------------------------------+
-- 垂植物：          |<------- 同实际窗横带 ---------->|
--                  |        窗上横板至藤蔓长尾         |
-- 左管：          [|] 喷口在本楼最高窗上方 ========> 水流矩形
--                  |       原猫圆真实扫掠接触水流       |
-- Ground ---------------------------------------------------------------
-- 窗/植物横带只允许猫中心 X 入带，仅纵向使用原半径接触，不横向扩窗。
-- 水流用精确圆-矩形 Minkowski 扫掠（边带+角圆），不将矩形方角误作圆角。
-- 大 dt 扫描 previous/current 全轨迹；配对释放重置 previous 为真实位置。
-- 出生同楼不捕获/播种/受同管推流。暂存不是 waiting/trapped/safe/resolved/rescued；
-- 清 pendingGround 后 kinematic pin。已真实联磁的自由猫不捕获，也不拆磁关联。
-- 流预算按真实已移动距离扣减，末段以 dt 平均速度推进而非瞬移；每猫每流一次。
-- 植物只在本猫首次下降触带时清零垂直速度一次；不缓存零上限，不抵消后续重力。
--        previous ○ → current ○  扫掠进入 [窗顶-r, 藤尾+r]（逻辑Y向下）
--        中心X须在实际窗横带内；仅纵向沿用原猫半径，擦边/大dt仍用既有BandTime。
--        plantPending排队 → 磁力/伞/横推之后一次提交(vx,0) → 下一物理步自然重力加速。
--        plantStopped按Node身份终身门闩；持续重叠、离开再进入均不逐帧清零。

---@class SpecialFloorBall : WorkshopBall
---@field matchmakingHeld boolean?
---@field matchmakingWindow integer?
---@field greenhouseOrigin string?
---@field sourceFloorKey string?
---@field released boolean?
---@field dead boolean?
---@field disposed boolean?
---@field collecting boolean?

---@class SpecialFloorWindow : FloorBlocksWindow
---@field matchmaking boolean?
---@field matchmakingKey string?
---@field greenhouse boolean?
---@field greenhouseKey string?

---@class SpecialFloorBlock : FloorBlock
---@field matchmaking boolean?
---@field greenhouse boolean?

---@class SpecialFloorRect
---@field x number
---@field y number
---@field w number
---@field h number

---@class SpecialFloorRecord : SpecialFloorRect
---@field key string
---@field col number
---@field row number
---@field windows integer[]
---@field band SpecialFloorRect?
---@field window integer
---@field matchmaking boolean
---@field greenhouse boolean
---@field marked boolean
---@field releaseCount integer
---@field plants SpecialFloorRect?
---@field plantArt SpecialFloorRect? 完整裁图矩形，与真实窗横带触区分别记录。
---@field waiting SpecialFloorBall?
---@field roof integer?

---@class SpecialFloorHeld
---@field floor SpecialFloorRecord
---@field x number
---@field y number
---@field gravity number
---@field mask integer
---@field category integer
---@field parachute boolean
---@field vx number
---@field vy number
---@field angular number

---@class SpecialFloorCatState
---@field node Node
---@field visited table<string, boolean>
---@field seeded table<string, boolean>
---@field jets table<string, boolean>
---@field slowCap number? 兼容既有分类读取；植物不再赋值或以此持续限速。
---@field plantPending boolean
---@field plantStopped boolean 本猫首次下降触植物的零速动作已消费，持续重叠不重触发。

---@class SpecialFloorPair
---@field cats SpecialFloorBall[]
---@field active boolean
---@field scorePairs ChallengePairToken[]? 独立真实婚介事件，联收组不是一对猫的身份。

---@class SpecialFloorPipe
---@field floor SpecialFloorRecord
---@field rect SpecialFloorRect
---@field nozzleX number
---@field nozzleY number
---@field active boolean
---@field direction number
---@field water SpecialFloorRect

---@class SpecialFloorPush
---@field pipe SpecialFloorPipe
---@field distance number
---@field remaining number
---@field duration number
---@field lastX number
---@field baseVX number
---@field commanded boolean
---@field commandVX number
---@field commandDT number

---@class SpecialFloorsGame
---@field balls SpecialFloorBall[]
---@field windows SpecialFloorWindow[]
---@field config {number: number, windows: table[]}
---@field run ChallengeRun?
---@field buildingGrid BuildingGrid
---@field groundY number
---@field paused boolean?
---@field disposed boolean?
---@field magnetic any
---@field physics PhysicsWorld2D?
---@field GetWindowRect fun(self: SpecialFloorsGame, index: integer): number, number, number, number
---@field GetWindowKey fun(self: SpecialFloorsGame, index: integer): string
---@field MarkRescued fun(self: SpecialFloorsGame, ball: SpecialFloorBall, reason: string): boolean?
---@field CollectCat fun(self: SpecialFloorsGame, ball: SpecialFloorBall): boolean?
---@field RequestNextCat fun(self: SpecialFloorsGame)
---@field ResetCatSamples fun(self: SpecialFloorsGame, ball: SpecialFloorBall)

---@class SpecialFloors
---@field game SpecialFloorsGame?
---@field floors SpecialFloorRecord[]
---@field floorByKey table<string, SpecialFloorRecord?>
---@field windowFloors table<number, SpecialFloorRecord>
---@field states table<SpecialFloorBall, SpecialFloorCatState?>
---@field held table<SpecialFloorBall, SpecialFloorHeld?>
---@field pairs table<SpecialFloorBall, SpecialFloorPair?>
---@field pushes table<SpecialFloorBall, SpecialFloorPush?>
---@field released table<SpecialFloorBall, boolean>
---@field pipes SpecialFloorPipe[]
---@field started boolean
---@field finalized boolean
---@field disposed boolean
local SpecialFloors = {}
SpecialFloors.__index = SpecialFloors

local PIPE_CHANCE, PUSH_DURATION, EPSILON = 0.10, 0.45, 0.000001

---@param value any
---@return boolean
local function Finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param ball SpecialFloorBall
---@return boolean
local function Terminal(ball)
    return ball.caught == true or ball.missed == true or (ball.safe == true and not ball.safeLanding)
        or ball.rolling == true or ball.dead == true or ball.removed == true or ball.disposed == true
end

---@param ball SpecialFloorBall
---@return boolean
local function Usable(ball)
    return not Terminal(ball) and ball.node ~= nil and ball.body ~= nil and ball.shape ~= nil
        and Finite(ball.radius) and ball.radius > 0
end

---@param ball SpecialFloorBall
---@return number?, number?
local function Position(ball)
    if not ball.node or ball.removed or ball.disposed then return nil, nil end
    local ok, p = pcall(function() return ball.node.position2D end)
    if not ok or not p or not Finite(p.x) or not Finite(p.y) then return nil, nil end
    return p.x, -p.y
end

---@param ball SpecialFloorBall
---@return boolean
local function Flying(ball)
    return Usable(ball) and not ball.safeLanding and not ball.waiting and not ball.trapped and not ball.matchmakingHeld
end

---@param rect SpecialFloorRect
---@return boolean
local function ValidRect(rect)
    return Finite(rect.x) and Finite(rect.y) and Finite(rect.w) and Finite(rect.h)
        and rect.w > 0 and rect.h > 0
end

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
    local nextEnter, nextLeave = math.max(enter, math.min(a, b)), math.min(leave, math.max(a, b))
    return nextEnter <= nextLeave, nextEnter, nextLeave
end

---@return number?
local function BoxTime(x0, y0, dx, dy, left, top, right, bottom)
    local hitX, enter, leave = Slab(x0, dx, left, right, 0, 1)
    if not hitX then return nil end
    local hitY, first = Slab(y0, dy, top, bottom, enter, leave)
    return hitY and first or nil
end

---@param rect SpecialFloorRect
---@return number?
local function BandTime(x0, y0, x1, y1, radius, rect)
    return BoxTime(x0, y0, x1 - x0, y1 - y0,
        rect.x, rect.y - radius, rect.x + rect.w, rect.y + rect.h + radius)
end

---@return number?
local function CircleTime(x0, y0, dx, dy, cx, cy, radius)
    local qx, qy = x0 - cx, y0 - cy
    local squared = radius * radius
    if qx * qx + qy * qy <= squared then return 0 end
    local a = dx * dx + dy * dy
    if a == 0 then return nil end
    local b, cross = qx * dx + qy * dy, qx * dy - qy * dx
    local discriminant = a * squared - cross * cross
    if discriminant < 0 then return nil end
    local t = (-b - math.sqrt(discriminant)) / a
    return t >= 0 and t <= 1 and t or nil
end

---@param best number?
---@param candidate number?
---@return number?
local function Earlier(best, candidate)
    if candidate ~= nil and (best == nil or candidate < best) then return candidate end
    return best
end

---@param rect SpecialFloorRect
---@return number?
local function WaterTime(x0, y0, x1, y1, radius, rect)
    local dx, dy = x1 - x0, y1 - y0
    local left, top, right, bottom = rect.x, rect.y, rect.x + rect.w, rect.y + rect.h
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
local function Inside(value, low, size, radius)
    if size <= radius * 2 then return low + size / 2 end
    return math.max(low + radius, math.min(low + size - radius, value))
end

---@param game SpecialFloorsGame
---@return SpecialFloors
function SpecialFloors.New(game)
    local self = setmetatable({}, SpecialFloors)
    self:Init(game)
    return self
end

---@param game SpecialFloorsGame
function SpecialFloors:Init(game)
    self.game = game
    self.floors, self.floorByKey, self.windowFloors = {}, {}, {}
    self.states, self.held, self.pairs, self.pushes, self.released, self.pipes = {}, {}, {}, {}, {}, {}
    self.started, self.finalized, self.disposed = false, false, false
end

---@param index integer
---@return string?
function SpecialFloors:WindowFloorKey(index)
    local game = self.game
    if not game then return nil end
    local window = game.windows[index]
    if not window then return nil end
    if Finite(window.col) and Finite(window.row) then
        return tostring(window.col) .. ":" .. tostring(window.row)
    end
    if window.matchmakingKey then return window.matchmakingKey end
    if window.greenhouseKey then return window.greenhouseKey end
    if window.laboratoryKey then return window.laboratoryKey end
    if window.warehouseKey then return window.warehouseKey end
    local key = game:GetWindowKey(index)
    local col, row = key:match("^floor:([%-]?%d+):([%-]?%d+):")
    if col and row then return col .. ":" .. row end
    -- 原楼九窗属于三个物理 seed 楼号，不能按几何 Snap 猜行号。
    if index <= #game.config.windows then return "0:" .. tostring(math.floor((index - 1) / 3)) end
    return nil
end

---@param block SpecialFloorBlock
function SpecialFloors:AddFloor(block)
    local game = self.game
    if not game then return end -- 无窗 seed row3 也有管，但不参与捕获/植物横带。
    local key = tostring(block.col) .. ":" .. tostring(block.row)
    if self.floorByKey[key] then return end
    local x, y, w, h = game.buildingGrid:GetRect(block.col, block.row)
    local floor = { key = key, col = block.col, row = block.row, x = x, y = y, w = w, h = h,
        windows = {}, window = 0, matchmaking = block.matchmaking == true,
        greenhouse = block.greenhouse == true, marked = false, releaseCount = 0, roof = block.roof,
    } --[[@as SpecialFloorRecord]]
    if not ValidRect(floor) then return end
    self.floors[#self.floors + 1], self.floorByKey[key] = floor, floor
end

---@param floor SpecialFloorRecord
function SpecialFloors:BuildBand(floor)
    local game = self.game
    if not game then return end
    ---@type SpecialFloorRect?
    local band = nil
    for _, index in ipairs(floor.windows) do
        local x, y, w, h = game:GetWindowRect(index)
        local rect = { x = x, y = y, w = w, h = h }
        if ValidRect(rect) then
            if not band then band = rect
            else
                local left, top = math.min(band.x, x), math.min(band.y, y)
                local right, bottom = math.max(band.x + band.w, x + w), math.max(band.y + band.h, y + h)
                band = { x = left, y = top, w = right - left, h = bottom - top }
            end
            local window = assert(game.windows[index], "特殊楼层窗口不存在：" .. tostring(index))
            if floor.window == 0 or window.slot == 2 then floor.window = index end
        end
    end
    floor.band = band
end

---@param floor SpecialFloorRecord
function SpecialFloors:AddPipe(floor)
    if floor.roof ~= nil then return end
    local band = floor.band
    local pipeWidth = floor.w * 0.075
    local nozzleX = floor.x + floor.w * 0.045 + pipeWidth / 2
    local nozzleY = (band and band.y or floor.y + floor.h * 0.35) - floor.h * 0.12
    local waterHeight, waterLength = floor.h * 0.14, floor.w * 1.75
    local pipe = { floor = floor, nozzleX = nozzleX, nozzleY = nozzleY,
        rect = { x = nozzleX - pipeWidth / 2, y = floor.y,
            w = pipeWidth, h = floor.h },
        active = false, direction = 1,
        water = { x = nozzleX, y = nozzleY - waterHeight * 0.35, w = waterLength, h = waterHeight },
    } --[[@as SpecialFloorPipe]]
    -- 地面向上数物理楼号：seed row2=一楼、row1=二楼、row0=三楼。
    -- 其它列同 row 同楼号；不按实际占用邻居数量或 #seeds 重新编号。
    if 3 - floor.row >= 3 then
        pipe.active = math.random() < PIPE_CHANCE -- 每根仅开局独立抽一次，不整列共用概率。
        if pipe.active then
            pipe.direction = math.random(0, 1) == 0 and -1 or 1
            if pipe.direction < 0 then pipe.water.x = nozzleX - waterLength end
        end
        print(string.format("[特殊楼层] 管 %s，物理楼号=%d，爆管=%s，朝%s喷流",
            floor.key, 3 - floor.row, tostring(pipe.active), pipe.direction < 0 and "左" or "右"))
    end
    self.pipes[#self.pipes + 1] = pipe
end

--- 幂等且允许暂停时调用：冻结期间显示已经抽出的爆管状态。
function SpecialFloors:Start()
    local game = self.game
    if self.disposed or self.started or not game or game.disposed then return end
    self.started = true
    for _, block in ipairs(game.buildingGrid.seeds) do self:AddFloor(block --[[@as SpecialFloorBlock]]) end
    for _, block in ipairs(game.buildingGrid.blocks) do self:AddFloor(block --[[@as SpecialFloorBlock]]) end
    for index, window in ipairs(game.windows) do
        local key = self:WindowFloorKey(index)
        local floor = key and self.floorByKey[key] or nil
        if floor then
            floor.windows[#floor.windows + 1] = index
            floor.matchmaking = floor.matchmaking or window.matchmaking == true
            floor.greenhouse = floor.greenhouse or window.greenhouse == true
            self.windowFloors[index] = floor
        end
    end
    for _, floor in ipairs(self.floors) do
        self:BuildBand(floor)
        if game.config.number >= 8 then self:AddPipe(floor) end
    end
    print(string.format("[特殊楼层] 初始化：%d 个实楼块，%d 根独立管（仅本局）",
        #self.floors, #self.pipes))
end

---@param ball SpecialFloorBall
---@return SpecialFloorCatState
function SpecialFloors:Register(ball)
    local state = self.states[ball]
    if state and state.node == ball.node then return state end
    -- 按 Node 对象身份登记，不按 ID，避免跨局或替换节点沿用旧样本。
    if state then
        local held = self.held[ball]
        if held and held.floor.waiting == ball then held.floor.waiting = nil end
        self.held[ball], self.pushes[ball], self.pairs[ball], self.released[ball] = nil, nil, nil, nil
        ball.matchmakingHeld, ball.matchmakingWindow = false, nil
    end
    local nextState = { node = ball.node, visited = {}, seeded = {}, jets = {},
        plantPending = false, plantStopped = false }
        --[[@as SpecialFloorCatState]]
    self.states[ball] = nextState
    local source = self.windowFloors[ball.window]
    if not ball.sourceFloorKey or ball.sourceFloorKey == "" then
        ball.sourceFloorKey = source and source.key or self:WindowFloorKey(ball.window)
    end
    local origin = ball.sourceFloorKey and self.floorByKey[ball.sourceFloorKey] or source
    if origin and origin.greenhouse and (not ball.greenhouseOrigin or ball.greenhouseOrigin == "") then
        ball.greenhouseOrigin = origin.key
    end
    return nextState
end

---@return boolean
function SpecialFloors:Running()
    local game = self.game
    return self.started and not self.finalized and not self.disposed and game ~= nil
        and not game.disposed and not game.paused
end

--- 宿主只入队、帧末消费下一猫请求；捕获处绝不递归出生。
---@return boolean
function SpecialFloors:RequestNext()
    local game = self.game
    if not self:Running() or not game then return false end
    game:RequestNextCat()
    return true
end

---@param ball SpecialFloorBall
---@return boolean
function SpecialFloors:HasMagneticLink(ball)
    local game = self.game
    local magnetic = game and game.magnetic or nil
    local link = magnetic and magnetic.cats and magnetic.cats[ball] or nil
    return link ~= nil and link.group ~= nil and link.group.active == true
end

---@param ball SpecialFloorBall
---@param held SpecialFloorHeld
local function Pin(ball, held)
    if not Usable(ball) then return end
    ball.pendingGround = false
    ball.node.enabled = true
    ball.body.bodyType, ball.body.gravityScale = BT_KINEMATIC, 0
    ball.shape.maskBits = 0
    ball.node:SetPosition2D(held.x, -held.y)
    ball.body.linearVelocity, ball.body.angularVelocity = Vector2(0, 0), 0
    ball.body.awake = true
    ball.previousX, ball.previousY = held.x, held.y
end

---@param ball SpecialFloorBall
---@param held SpecialFloorHeld
local function Restore(ball, held)
    if not Usable(ball) then return end
    ball.matchmakingHeld, ball.matchmakingWindow, ball.pendingGround = false, nil, false
    ball.waiting = false -- 独立暂存，不交给 Cats.Release 重复释放。
    ball.node.enabled = true
    ball.body.bodyType, ball.body.gravityScale = BT_DYNAMIC, held.gravity
    ball.shape.categoryBits, ball.shape.maskBits = held.category, held.mask
    ball.parachute = held.parachute
    -- 配对后立即下落，不额外等零速度帧；出生/首次释放次数不变。
    ball.body.linearVelocity = Vector2(held.vx, math.min(-0.35, held.vy))
    ball.body.angularVelocity, ball.body.awake = held.angular, true
    local x, y = Position(ball)
    if x and y then ball.previousX, ball.previousY = x, y end
end

---@param ball SpecialFloorBall
---@param floor SpecialFloorRecord
---@param x number
---@param y number
function SpecialFloors:Hold(ball, floor, x, y)
    local band = floor.band
    if not band then return end
    local velocity = ball.body.linearVelocity
    local held = { floor = floor,
        x = Inside(x, band.x, band.w, ball.radius), y = Inside(y, band.y, band.h, ball.radius),
        gravity = ball.body.gravityScale, mask = ball.shape.maskBits, category = ball.shape.categoryBits,
        parachute = ball.parachute == true, vx = velocity.x, vy = velocity.y, angular = ball.body.angularVelocity,
    } --[[@as SpecialFloorHeld]]
    self.held[ball], self.pushes[ball] = held, nil
    ball.matchmakingHeld, ball.matchmakingWindow = true, floor.window
    Pin(ball, held)
end

---@param ball SpecialFloorBall
---@param targetX number? 磁力出窗的实际宽窗最近横点。
---@return boolean
function SpecialFloors:OnMagneticRelease(ball, targetX)
    if not self:Running() then return false end
    local held = self.held[ball]
    if not held or not ball.matchmakingHeld or not Usable(ball) or ball.trapped then return false end
    if held.floor.waiting == ball then held.floor.waiting = nil end
    self.held[ball] = nil -- 恢复前先解除暂存，保留全部磁组/磁 held 标记。
    local band = held.floor.band
    if band and targetX ~= nil and Finite(targetX) then
        -- 仅用于指定宽窗出窗位置；水流推进永远不在此做瞬移。
        held.x = math.max(band.x, math.min(band.x + band.w, targetX))
        ball.node:SetPosition2D(held.x, -held.y)
    end
    Restore(ball, held)
    local game = self.game
    if game then game:ResetCatSamples(ball) end
    print(string.format("[婚恋楼] 猫 #%d 从楼 %s 被磁力拉出暂存", ball.id, held.floor.key))
    return true
end

---@param first SpecialFloorBall
---@param second SpecialFloorBall
---@param scoreToken ChallengePairToken? 仅 Capture 真婚介配对分支创建。
function SpecialFloors:Pair(first, second, scoreToken)
    ---@type SpecialFloorBall[]
    local cats = {}
    ---@type ChallengePairToken[]
    local scorePairs = {}
    ---@type table<ChallengePairToken, boolean>
    local tokenSeen = {}
    ---@type table<SpecialFloorBall, boolean>
    local seen = {}
    for _, seed in ipairs({ first, second }) do
        local group = self.pairs[seed]
        local members = group and group.active and group.cats or { seed }
        for _, cat in ipairs(members) do
            if not seen[cat] and not Terminal(cat) then seen[cat] = true; cats[#cats + 1] = cat end
        end
        for _, token in ipairs(group and group.active and group.scorePairs or {}) do
            if not tokenSeen[token] then tokenSeen[token] = true; scorePairs[#scorePairs + 1] = token end
        end
        if group then group.active = false end
    end
    if scoreToken then scorePairs[#scorePairs + 1] = scoreToken end
    local pair = { cats = cats, active = true, scorePairs = scorePairs } --[[@as SpecialFloorPair]]
    for _, cat in ipairs(cats) do self.pairs[cat] = pair end
end

-- 配对专用释放：第二猫移第一猫所在列，并留纵向直径间隔避免圆重叠弹开。
--       ○ 第二猫  （同X，零速）
--       ○ 第一猫  （原落列不变，零速）
-- 普通磁力出窗仍使用Restore原速度；配对最后由宿主帧末再次提交零速。
function SpecialFloors:ReleasePair(first, second, firstHeld, secondHeld)
    local game = self.game
    if not game then return end
    second.node:SetPosition2D(firstHeld.x, -(firstHeld.y - first.radius - second.radius - 0.006))
    first.node:SetPosition2D(firstHeld.x, -firstHeld.y)
    Restore(first, firstHeld)
    Restore(second, secondHeld)
    for _, ball in ipairs({ first, second }) do
        ball.body.linearVelocity, ball.body.angularVelocity = Vector2(0, 0), 0
        ball.magneticMotionApplied, ball.pairResetPending = false, true
        self.pushes[ball] = nil
        local state = self:Register(ball)
        state.plantPending = false
        game:ResetCatSamples(ball)
    end
    local magnetic = game.magnetic
    local link = magnetic and magnetic.cats and magnetic.cats[first]
    if link and link.group.active and magnetic.Reanchor then magnetic:Reanchor(link.group, link.group.root) end
end

---@param ball SpecialFloorBall
---@param floor SpecialFloorRecord
---@param x number
---@param y number
function SpecialFloors:Capture(ball, floor, x, y)
    local waiting = floor.waiting
    if waiting and (not Usable(waiting) or not self.held[waiting] or not waiting.matchmakingHeld) then
        floor.waiting = nil; waiting = nil
    end
    self:Hold(ball, floor, x, y)
    local incoming = self.held[ball]
    if not incoming then return end
    if waiting and waiting ~= ball then
        local partner = self.held[waiting]
        -- 改物理或递归收取前，先原子解除两只暂存引用。
        floor.waiting, self.held[waiting], self.held[ball] = nil, nil, nil
        local game = self.game
        local token = game and game.run and game.run:OnPair(waiting, ball) or nil
        self:Pair(waiting, ball, token)
        if partner then self:ReleasePair(waiting, ball, partner, incoming) end
        print(string.format("[婚恋楼] %s 配对猫 #%d + #%d 同时下落，尚未计救援",
            floor.key, waiting.id, ball.id))
    else
        floor.waiting = ball
        self:RequestNext()
        print(string.format("[婚恋楼] %s 暂存猫 #%d，已请求下一猫（不计解决/救援）", floor.key, ball.id))
    end
end

---@param floor SpecialFloorRecord
function SpecialFloors:Grow(floor)
    local game, band = self.game, floor.band
    if not game or not band or floor.plants then return end
    -- 裁图横板 y=.396*图高；对齐真实最高窗顶，不把藤蔓挂到下层墙面。
    local height = floor.h * 0.50
    local artY = band.y - height * 0.396
    floor.plantArt = { x = floor.x + floor.w * 0.09, y = artY,
        w = floor.w * 0.85, h = height }
    local bottom = math.min(artY + height, game.groundY)
    if bottom <= band.y then return end
    floor.plants = { x = band.x, y = band.y, w = band.w, h = bottom - band.y }
    print(string.format("[温室] %s 窗口实际释放 %d 次，长出垂挂植物", floor.key, floor.releaseCount))
end

--- 普通波次与磁力提前释放的真正首次 Release 回调；出生/途经不计。
---@param ball SpecialFloorBall
---@return boolean
function SpecialFloors:OnCatReleased(ball)
    if not self:Running() or self.released[ball] or not Usable(ball)
        or ball.waiting or ball.trapped or ball.matchmakingHeld then return false end
    self:Register(ball)
    self.released[ball] = true
    local floor = ball.sourceFloorKey and self.floorByKey[ball.sourceFloorKey] or self.windowFloors[ball.window]
    if floor and floor.marked and not floor.plants then
        floor.releaseCount = floor.releaseCount + 1
        if floor.releaseCount >= 2 then self:Grow(floor) end
    end
    return true
end

---@param ball SpecialFloorBall
---@param state SpecialFloorCatState
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param lastTime number
function SpecialFloors:SeedFloors(ball, state, x0, y0, x1, y1, lastTime)
    if not ball.greenhouseOrigin or ball.greenhouseOrigin == "" then return end
    for _, floor in ipairs(self.floors) do
        local band = floor.band
        if band and floor.key ~= ball.greenhouseOrigin and floor.key ~= ball.sourceFloorKey
            and not state.seeded[floor.key] then
            local time = BandTime(x0, y0, x1, y1, ball.radius, band)
            if time ~= nil and time <= lastTime then
                state.seeded[floor.key] = true
                if not floor.marked then
                    floor.marked, floor.releaseCount = true, 0
                    print(string.format("[温室] 源猫 #%d（%s）标记楼 %s，等待后续两次窗内释放",
                        ball.id, ball.greenhouseOrigin, floor.key))
                end
            end
        end
    end
end

---@param ball SpecialFloorBall
---@param state SpecialFloorCatState
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param lastTime number
function SpecialFloors:TouchPlants(ball, state, x0, y0, x1, y1, lastTime)
    -- 检测下降扫掠而不是持续重叠响应；已消费的猫不再排队，既有触区/半径不变。
    if state.plantStopped or state.plantPending or y1 < y0 or ball.body.linearVelocity.y >= 0 then return end
    for _, floor in ipairs(self.floors) do
        local rect = floor.plants
        if rect then
            local time = BandTime(x0, y0, x1, y1, ball.radius, rect)
            if time ~= nil and time <= lastTime then state.plantPending = true; return end
        end
    end
end

---@param ball SpecialFloorBall
---@param state SpecialFloorCatState
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param lastTime number
function SpecialFloors:TouchWater(ball, state, x0, y0, x1, y1, lastTime)
    if self.pushes[ball] then return end
    ---@type SpecialFloorPipe?
    local best = nil
    local bestTime = math.huge
    for _, pipe in ipairs(self.pipes) do
        if pipe.active and pipe.floor.key ~= ball.sourceFloorKey and not state.jets[pipe.floor.key] then
            local time = WaterTime(x0, y0, x1, y1, ball.radius, pipe.water)
            if time ~= nil and time <= lastTime and time < bestTime then best, bestTime = pipe, time end
        end
    end
    if not best then return end
    local distance = best.floor.w * (1 + math.random() * 0.5)
    state.jets[best.floor.key] = true
    self.pushes[ball] = { pipe = best, distance = distance, remaining = distance, duration = PUSH_DURATION,
        lastX = x1, baseVX = ball.body.linearVelocity.x, commanded = false, commandVX = 0, commandDT = 0 }
    print(string.format("[水流] 猫 #%d 触楼 %s 的流，计划 %.3f 米 / %.2f 秒，速度推进不瞬移",
        ball.id, best.floor.key, distance, PUSH_DURATION))
end

---@param ball SpecialFloorBall
---@param state SpecialFloorCatState
function SpecialFloors:StepBall(ball, state)
    if not Flying(ball) then return end
    local x1, y1 = Position(ball)
    if not x1 or not y1 then return end
    local x0 = Finite(ball.previousX) and ball.previousX or x1
    local y0 = Finite(ball.previousY) and ball.previousY or y1
    ---@type SpecialFloorRecord?
    local best = nil
    local bestTime = math.huge
    if y1 >= y0 and not self:HasMagneticLink(ball) then
        for _, floor in ipairs(self.floors) do
            local band = floor.band
            if floor.matchmaking and band and floor.key ~= ball.sourceFloorKey and not state.visited[floor.key] then
                local time = BandTime(x0, y0, x1, y1, ball.radius, band)
                if time ~= nil and time < bestTime then best, bestTime = floor, time end
            end
        end
    end
    local lastTime = best and bestTime or 1
    -- 大 dt 先遇到婚恋捕获，不能给其下方整段轨迹继续播种/触流。
    self:SeedFloors(ball, state, x0, y0, x1, y1, lastTime)
    self:TouchPlants(ball, state, x0, y0, x1, y1, lastTime)
    if not best then self:TouchWater(ball, state, x0, y0, x1, y1, 1) end
    if best then
        state.visited[best.key] = true -- forever for this cat/floor, including magnetic re-release.
        self:Capture(ball, best, x0 + (x1 - x0) * bestTime, y0 + (y1 - y0) * bestTime)
    end
end

--- 物理写入只在 Contact 之外；暂停/非法 dt 直接拒绝全部变化。
---@param dt number
function SpecialFloors:Update(dt)
    if not self:Running() or not Finite(dt) or dt <= 0 then return end
    local game = self.game
    if not game then return end
    ---@type table<SpecialFloorBall, boolean>
    local live = {}
    -- 请求仅入队；本帧不递归新生，避免把出生前 dt/轨迹追溯给新猫。
    for _, ball in ipairs(game.balls) do
        live[ball] = true
        if Usable(ball) then
            local state = self:Register(ball)
            local held = self.held[ball]
            if held then Pin(ball, held) else self:StepBall(ball, state) end
        end
    end
    for ball in pairs(self.states) do
        if not live[ball] or Terminal(ball) then
            local held = self.held[ball]
            if held and held.floor.waiting == ball then held.floor.waiting = nil end
            self.held[ball], self.pushes[ball], self.states[ball], self.released[ball] = nil, nil, nil, nil
            ball.matchmakingHeld, ball.matchmakingWindow = false, nil
            -- 失去/死亡伙伴只清关系，不因为晚接存活猫把已死伙伴补救。
            local pair = self.pairs[ball]
            self.pairs[ball] = nil
            if pair then
                for i = #pair.cats, 1, -1 do if pair.cats[i] == ball then table.remove(pair.cats, i) end end
                if #pair.cats <= 1 then
                    pair.active = false
                    for _, cat in ipairs(pair.cats) do self.pairs[cat] = nil end
                end
            end
        end
    end
end

---@param ball SpecialFloorBall
---@param push SpecialFloorPush
---@param dt number
function SpecialFloors:ApplyPush(ball, push, dt)
    local x = Position(ball)
    if not x then self.pushes[ball] = nil; return end
    if push.commanded then
        local traveled = math.max(0, (x - push.lastX) * push.pipe.direction)
        push.remaining = math.max(0, push.remaining - traveled)
    end
    local velocity = ball.body.linearVelocity
    if push.remaining <= EPSILON then
        -- 无磁力/控制器/碰撞改变最后指令时才恢复漂移，避免覆盖新速度。
        local damping = math.max(0, ball.body.linearDamping)
        local expected = push.commandVX / (1 + damping * push.commandDT)
        if math.abs(velocity.x - expected) <= EPSILON then
            ball.body.linearVelocity = Vector2(push.baseVX, velocity.y)
        end
        self.pushes[ball] = nil
        return
    end
    local speed = math.min(push.distance / push.duration, push.remaining / dt)
    -- Box2D 阻尼=1/(1+damping*dt)，补偿后实际行程才是计划米数。
    local vx = push.pipe.direction * speed * (1 + math.max(0, ball.body.linearDamping) * dt)
    ball.body.linearVelocity, ball.body.awake = Vector2(vx, velocity.y), true
    push.lastX, push.commanded, push.commandVX, push.commandDT = x, true, vx, dt
end

--- 暂存磁源经真实联组接到第二猫时配对；只吸到物品不自动离窗。
function SpecialFloors:PairMagneticGuests()
    local game = self.game
    local magnetic = game and game.magnetic
    if not game or not magnetic or not magnetic.cats then return end
    for _, root in ipairs(game.balls) do
        local held = self.held[root]
        local link = magnetic.cats[root]
        local group = link and link.group
        if held and held.floor.waiting == root and root.magnetic and Usable(root)
            and group and group.active and group.root == root then
            for _, guest in ipairs(game.balls) do
                local guestLink = magnetic.cats[guest]
                -- 同一个真实活组也可能通过物品接触链相连；不能只查两猫直接圆触。
                if guest ~= root and Flying(guest) and not guest.collecting
                    and guestLink and guestLink.group == group then
                    local x, y = Position(guest)
                    if x and y then
                        self:Register(guest).visited[held.floor.key] = true
                        self:Capture(guest, held.floor, x, y)
                        root.magneticMotionApplied, guest.magneticMotionApplied = false, false
                        if group.active and magnetic.Reanchor then magnetic:Reanchor(group, group.root) end
                        break -- 一次只释放这一对，其余成员跟随恢复下落的磁源。
                    end
                end
            end
        end
    end
end

--- 最终速度优先级：保留横推/磁关联；植物仅提交一次垂直零速，不维持零上限。
---@param dt number
function SpecialFloors:AfterMagnetic(dt)
    if not self:Running() or not Finite(dt) or dt <= 0 then return end
    local game = self.game
    if not game then return end
    self:PairMagneticGuests()
    for _, ball in ipairs(game.balls) do
        local held = self.held[ball]
        if held and Usable(ball) then Pin(ball, held) end
        if Flying(ball) and not ball.pairResetPending then
            local state = self:Register(ball)
            local push = self.pushes[ball]
            if push then self:ApplyPush(ball, push, dt) end
            if state.plantPending then
                local velocity = ball.body.linearVelocity
                local damping = 1 + math.max(0, ball.body.linearDamping) * dt
                local gravity = game.physics and game.physics.gravity.y or -12
                -- 磁力写的是下一步补偿指令，符号不代表实际运动方向；先还原其下降目标。
                local fallingY = ball.magneticMotionApplied
                    and (velocity.y + gravity * ball.body.gravityScale * dt) / damping or velocity.y
                if fallingY < 0 and not state.plantStopped then
                    state.plantStopped = true -- 先消费一次性门闩，重叠/再次进带不重复清零。
                    -- 只清垂直分量，保留水流/磁力的横速、磁关联、伞/重力/阻尼/原半径。
                    -- 不写slowCap=0、不补偿g*dt：下一Box2D步从0受重力重新加速。
                    ball.body.linearVelocity, ball.body.awake = Vector2(velocity.x, 0), true
                    ball.magneticMotionApplied = false -- 当前已不是磁力重力补偿指令。
                    print(string.format("[温室] 猫 #%d 首次下降触植物，垂直速度归零一次，随后恢复重力加速", ball.id))
                end
                state.plantPending = false
            end
        end
    end
end

--- Contact 安全：原子解除元数据后递归收其它猫，不在此改刚体。
--- 宿主在调用 Special/Magnetic 收取前设置 collecting 防交叉组重入。
---@param ball SpecialFloorBall
---@return SpecialFloorBall[]
function SpecialFloors:CollectGroup(ball)
    if self.disposed or self.finalized then return {} end
    local group = self.pairs[ball]
    if not group or not group.active then
        -- 单只暂存猫也可能被真实磁组收取，立即解除楼层等待引用，不碰 Contact 内物理。
        local held = self.held[ball]
        if held and held.floor.waiting == ball then held.floor.waiting = nil end
        self.held[ball], self.pushes[ball] = nil, nil
        ball.matchmakingHeld, ball.matchmakingWindow = false, nil
        return {}
    end
    local cats = group.cats
    local scoreGame = self.game
    if scoreGame and scoreGame.run then scoreGame.run:CapturePairs(group.scorePairs) end
    group.active, group.cats, group.scorePairs = false, {}, {}
    for _, cat in ipairs(cats) do
        self.pairs[cat] = nil
        local held = self.held[cat]
        if held and held.floor.waiting == cat then held.floor.waiting = nil end
        self.held[cat], self.pushes[cat] = nil, nil
        cat.matchmakingHeld, cat.matchmakingWindow = false, nil
    end
    local game = self.game
    if game then
        for _, cat in ipairs(cats) do
            if cat ~= ball and not cat.collecting and not Terminal(cat) then game:CollectCat(cat) end
        end
    end
    return cats
end

--- 胜负判定/冻结之前调用；只有此刻才把剩余暂存猫记作救援。
---@return integer newlyRescued
function SpecialFloors:Finalize()
    if self.disposed or self.finalized then return 0 end
    self.finalized = true -- 宿主回调前先关闭本局新增集合。
    local game = self.game
    if not game then return 0 end
    ---@type SpecialFloorBall[]
    local survivors = {}
    for ball in pairs(self.held) do
        if ball.matchmakingHeld and Usable(ball) and not ball.rescueCounted then survivors[#survivors + 1] = ball end
    end
    table.sort(survivors, function(a, b) return a.id < b.id end)
    local count = 0
    for _, ball in ipairs(survivors) do
        if game:MarkRescued(ball, "matchmaking") then count = count + 1 end
    end
    self.pushes = {}
    print(string.format("[婚恋楼] 结算：%d 只剩余暂存猫首次记救援", count))
    return count
end

--- 在宿主世界变换内绘制；Art/ImageCache 管理图片和 DPR，不另开帧。
---@param vg NVGContextWrapper
---@param unit number
---@param Art any
function SpecialFloors:Render(vg, unit, Art)
    if self.disposed or not self.started or not Finite(unit) or unit <= 0 then return end
    nvgSave(vg)
    for _, floor in ipairs(self.floors) do
        local plants = floor.plantArt
        if plants then
            Art.Image(vg, "Global/Images/HangingPlants.png", plants.x * unit, plants.y * unit,
                plants.w * unit, plants.h * unit)
        end
    end
    for _, pipe in ipairs(self.pipes) do
        local rect = pipe.rect
        Art.Image(vg, "Global/Images/Pipe.png", rect.x * unit, rect.y * unit, rect.w * unit, rect.h * unit)
        if pipe.active then
            local water = pipe.water
            nvgSave(vg)
            if pipe.direction < 0 then
                nvgTranslate(vg, (water.x + water.w) * unit, water.y * unit)
                nvgScale(vg, -1, 1)
            else nvgTranslate(vg, water.x * unit, water.y * unit) end
            Art.Image(vg, "Global/Images/WaterJet.png", 0, 0, water.w * unit, water.h * unit)
            nvgRestore(vg)
        end
    end
    nvgRestore(vg)
end

--- 窗内暂存猫；宿主普通猫/影子绘制排除 held，避免重复绘制。
---@param vg NVGContextWrapper
---@param unit number
---@param Art any
function SpecialFloors:RenderWaiting(vg, unit, Art)
    if self.disposed or not self.started or not Finite(unit) or unit <= 0 then return end
    for ball, held in pairs(self.held) do
        local band = held.floor.band
        if band and ball.matchmakingHeld and not Terminal(ball) then
            nvgSave(vg)
            nvgIntersectScissor(vg, band.x * unit, band.y * unit, band.w * unit, band.h * unit)
            Art.Cat(vg, ball, held.x * unit, held.y * unit, ball.radius * unit)
            nvgRestore(vg)
        end
    end
end

--- 幂等，不改计数，不 Dispose 宿主对象或共享图片。
function SpecialFloors:Dispose()
    if self.disposed then return end
    for ball, held in pairs(self.held) do
        if Usable(ball) then Restore(ball, held) end
        ball.matchmakingHeld, ball.matchmakingWindow = false, nil
    end
    self.floors, self.floorByKey, self.windowFloors = {}, {}, {}
    self.states, self.held, self.pairs, self.pushes, self.released, self.pipes = {}, {}, {}, {}, {}, {}
    self.game, self.disposed = nil, true
end

return SpecialFloors
