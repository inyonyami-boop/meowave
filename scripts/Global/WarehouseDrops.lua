-- 基于 scaffold-2d / scaffold-2d-physics 的独立纯 Lua 玩法模块。
-- 不创建 Node、刚体、事件、UI 根或 NanoVG 帧，不 require WorkshopArt，避免循环依赖。
-- 状态以米计、画面 y 向下；救猫人节点读取 (position2D.x, -position2D.y)。
-- Render 复用宿主 arena 的原点/视图变换，unit 是逻辑像素/米，绝不再次处理 DPR。
--
-- 宿主接入顺序：
--   New(game) -> 恢复布局和救猫人 Reset -> Start(sameLevelRetryClaims?) -> 首波创建猫。
--   每只猫真正创建成功后 OnCatSpawn()，不是 PrepareWave 空转或 ReleaseWave 重复通知。
--   每帧（包括暂停）MagneticCats.Update(dt) -> 本模块 Update(dt) -> 波事件/新猫出生。
--   成功接取置 game.layoutDirty=true，宿主 Update 后统一 Save；出生帧绝不追溯推进 dt。
--   同关 retry 显式携带 ExportClaims()；下一关 Start() 缺省清空，绝不隐式继承。
--   Dispose() 先于宿主释放 scene；共享 ImageCache 的图片不由本模块释放。
--
-- 碰撞设计（先设计后实现；所有 kind 共用 0.28 x 0.25 米实体矩形）：
--   同一 warehouseKey='col:row' 的三扇窗 -> 一个仓库，可同时有任意多个在途 drop。
--   每只猫出现都独立尝试未领取仓库；接住并发放一件成功后立即清该仓库全部在途。
--             [窗1] [窗2] [窗3]     从随机一窗中心直接开始下落。
--                       +----+     初始 vy=0，g=+12 米/秒²，无倾斜/等待阶段。
--                       |物品|     自由物 x(t)=x0+vx*t，y(t)=y0+vy*t+6*t²。
--                       +----+     图像等比装入矩形，装饰不扩大碰撞范围。
--                         v
--          上帧人物 +-------+  ->  +-------+ 本帧人物（实际节点中心）
--                   | 接取  |      | 接取  | catchWidth x height
--                   +-------+      +-------+
--   ======================================================= groundY
--   先求 drop 底边首次触地时刻，裁掉触地后的时间；只对合法下落段扫掠人物。
--   矩形相对运动：X slab 求同一时间的重叠区间，再检查该区间 Y 相对抛物线极值。
--   不是两个运动包围盒的并集，也不把抛物线连成直线，避免横移人物隔空接取。
--   边界：擦边/恰好触地同时接取均算接住；已在地面下的物品绝不能晚收。
--   大 dt 一样先 catch 后 miss；dt=0/负数/NaN/无穷不推进，但更新人物样本。
--   暂停同样更新样本，不在恢复后扫过暂停前的位置；入场/禁用人物不接取。
--   磁组 held 物件由 MagneticCats 同步到当前 root；不积分/触地回收，但仍扫掠人物。
--   held 使用同对象上一 Update 落点 -> 当前点的 relative linear，两轴时间区间必须相交。
--   新 held/模式切换/人物替换不拼接旧出生位置；暂停/非法 dt 同步刷新双方样本。
--   catch 先 CollectForDrop 原子收整组，再在 seed 尚未 claimed 时 Claim，库存不重复计数。
--   Claim 先锁 claims[key]=true 再 GrantWarehouse；成功标 collected 并清同店全部在途，失败回退。
--   miss 只清当前在途物品，不锁仓库，可不限次数重掉；不碰猫计数、hasCat 或伤害。

local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local PropSystem = require("Global.PropSystem")
local GRAVITY, DROP_WIDTH, DROP_HEIGHT = 12, 0.28, 0.25
local EPSILON = 0.000001
local KINDS = { "fence", "rack", "security_window" }
local IMAGE_PATHS = {
    fence = "Global/Images/Fence.png",
    rack = "Global/Images/ClothesRack.png",
}

---@class WarehouseDropsConfig
---@field number number
---@field warehouseDropChance number? 默认 0.5；0/1 分别禁用/必定尝试掉落。

---@class WarehouseDropsWindow
---@field warehouse boolean?
---@field warehouseKey string?

---@class WarehouseDropsRescuer
---@field node Node
---@field catchWidth number
---@field height number
---@field entering boolean?

---@class WarehouseDropsGame
---@field config WarehouseDropsConfig
---@field run ChallengeRun?
---@field windows WarehouseDropsWindow[]
---@field props PropSystem?
---@field magnetic MagneticCats?
---@field rescuer WarehouseDropsRescuer?
---@field groundY number
---@field paused boolean?
---@field layoutDirty boolean
---@field GetWindowRect fun(self: WarehouseDropsGame, index: integer): number, number, number, number

---@class WarehouseDropWindowRect
---@field index integer
---@field x number
---@field y number
---@field w number
---@field h number

---@class WarehouseDropEntry
---@field key string
---@field windows WarehouseDropWindowRect[]

---@class WarehouseDrop
---@field warehouse WarehouseDropEntry
---@field window integer 出生窗索引，仅用于日志。
---@field kind string fence / rack / security_window，与 PropSystem 库存键一致。
---@field x number 中心 x。
---@field y number 中心 y，画面向下。
---@field width number
---@field height number
---@field vx number 水平恒速度，出生为 0；由 SetMotion/磁组同步更新。
---@field vy number
---@field magneticHeld boolean? true 时位置由磁组同步，本模块仅检测人物接触。
---@field magneticShakeX number? 仅显示偏移，不参与运动/接取。
---@field magneticShakeY number?
---@field collected boolean? 仅 Claim 发放成功后置 true，供磁组 prune。

---@class WarehouseDropsDropSample
---@field x number 上一次 Update 返回时的物件位置（非出生/推进前位置）。
---@field y number
---@field magneticHeld boolean

---@class WarehouseDropsRescuerSample
---@field node Node 用于排除人物节点替换后的跨对象扫掠。
---@field x number
---@field y number
---@field halfW number
---@field halfH number

---@class WarehouseDrops
---@field game WarehouseDropsGame?
---@field warehouses WarehouseDropEntry[]
---@field byKey table<string, WarehouseDropEntry>
---@field claims table<string, boolean> 仅 key->true；不包含库存或在途物品。
---@field drops WarehouseDrop[]
---@field dropSamples table<WarehouseDrop, WarehouseDropsDropSample> 按对象身份保存，不跨局/不复用出生样本。
---@field rescuerSample WarehouseDropsRescuerSample?
---@field warnings table<string, boolean>
---@field started boolean
---@field disposed boolean
local WarehouseDrops = {}
WarehouseDrops.__index = WarehouseDrops

---@param game WarehouseDropsGame
---@return WarehouseDrops
function WarehouseDrops.New(game)
    local self = setmetatable({}, WarehouseDrops)
    self:Init(game)
    return self
end

---@param game WarehouseDropsGame
function WarehouseDrops:Init(game)
    self.game = game
    self.warehouses, self.byKey, self.claims, self.drops = {}, {}, {}, {}
    self.dropSamples = {}
    self.rescuerSample = nil
    self.warnings = {}
    self.started, self.disposed = false, false
end

---@param value number?
---@return boolean
local function Finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param key string
---@param text string
function WarehouseDrops:WarnOnce(key, text)
    if self.warnings[key] then return end
    self.warnings[key] = true
    print("[仓库掉落] " .. text)
end

---@param game WarehouseDropsGame
---@return WarehouseDropsRescuerSample?
local function ReadRescuer(game)
    local rescuer = game.rescuer
    if not rescuer or not rescuer.node or rescuer.entering or rescuer.node.enabled == false then return nil end
    local position = rescuer.node.position2D
    if not Finite(position.x) or not Finite(position.y) or not Finite(rescuer.catchWidth)
        or not Finite(rescuer.height) or rescuer.catchWidth <= 0 or rescuer.height <= 0 then return nil end
    return { node = rescuer.node, x = position.x, y = -position.y,
        halfW = rescuer.catchWidth / 2, halfH = rescuer.height / 2 }
end

--- 每局开场调用；重建仓库索引/人物样本，清在途物品，拷贝同关 retry 的 claim。
--- 不写 windows，不清库存，不存档；不传 claims 意味着新关卡，不复用 self.claims。
---@param claims table<string, boolean>?
---@return integer 仓库数。
function WarehouseDrops:Start(claims)
    if self.disposed then return 0 end
    self.warehouses, self.byKey, self.claims, self.drops = {}, {}, {}, {}
    self.dropSamples = {}
    self.warnings = {}
    self.started = true
    local game = self.game
    self.rescuerSample = game and ReadRescuer(game) or nil
    if not game or not Finite(game.config.number) or game.config.number < 5 then return 0 end
    if not Finite(game.groundY) then
        self:WarnOnce("ground", "groundY 无效，本局不生成掉落")
        return 0
    end
    local restored = 0
    for index, window in ipairs(game.windows) do
        local key = window.warehouseKey
        if window.warehouse == true and type(key) == "string" and key:match("^%-?%d+:%-?%d+$") then
            local x, y, w, h = game:GetWindowRect(index)
            if Finite(x) and Finite(y) and Finite(w) and Finite(h) and w > 0 and h > 0
                and y + h / 2 + DROP_HEIGHT / 2 < game.groundY then
                local warehouse = self.byKey[key]
                if not warehouse then
                    warehouse = { key = key, windows = {} }
                    self.byKey[key] = warehouse
                    self.warehouses[#self.warehouses + 1] = warehouse
                    -- 只接受已收集=true；过滤其它关卡不存在的仓库、非法/伪 truthy 存档。
                    if type(claims) == "table" and claims[key] == true then
                        self.claims[key], restored = true, restored + 1
                    end
                end
                warehouse.windows[#warehouse.windows + 1] = { index = index, x = x, y = y, w = w, h = h }
            else
                self:WarnOnce("rect:" .. key, "仓库 " .. key .. " 有无效/触地窗口，已跳过")
            end
        elseif window.warehouse == true then
            self:WarnOnce("key", "仓库窗缺少合法 warehouseKey='col:row'，已跳过")
        end
    end
    print(string.format("[仓库掉落] Level %s：索引 %d 个仓库，恢复已领取 %d 个；在途清空",
        tostring(game.config.number), #self.warehouses, restored))
    return #self.warehouses
end

--- 只在真正出现一只猫时调用一次；每个未领取仓库独立按概率尝试，在途数量不限制机会。
--- 随机窗和 kind，不检查猫所在窗，不修改窗口 hasCat/实体/库存，绝不 seed 全局随机。
---@return integer 本次新增物品数。
function WarehouseDrops:OnCatSpawn()
    local game = self.game
    if self.disposed or not self.started or not game or game.paused or #self.warehouses == 0 then return 0 end
    ---@type number
    local chance = game.config.warehouseDropChance or 0.5
    if not Finite(chance) then chance = 0.5 end
    chance = math.max(0, math.min(1, chance))
    if chance <= 0 then return 0 end
    local count = 0
    for _, warehouse in ipairs(self.warehouses) do
        if not self.claims[warehouse.key] and (chance >= 1 or math.random() < chance) then
            local window = assert(warehouse.windows[math.random(#warehouse.windows)], "仓库索引必须含有效窗口")
            local kind = KINDS[math.random(#KINDS)] --[[@as string]]
            local drop = { warehouse = warehouse, window = window.index, kind = kind,
                x = window.x + window.w / 2, y = window.y + window.h / 2,
                width = DROP_WIDTH, height = DROP_HEIGHT, vx = 0, vy = 0 }
            self.drops[#self.drops + 1] = drop -- 不设在途锁；每次猫出现都有新的独立概率机会。
            count = count + 1
            print(string.format("[仓库掉落] %s 窗 %d 掉落 %s，中心 %.3f, %.3f 米",
                warehouse.key, window.index, kind, drop.x, drop.y))
        end
    end
    return count
end

--- 只改变本模块仍持有的未领取在途物件速度，不位移/领取，不限制每仓库在途数。
--- magneticHeld 的位置仍由磁组负责；本接口不会改变其 held 状态。
---@param drop WarehouseDrop
---@param vx number
---@param vy number
---@return boolean
function WarehouseDrops:SetMotion(drop, vx, vy)
    if self.disposed or not self.started or not self.game or type(drop) ~= "table"
        or not Finite(vx) or not Finite(vy) then return false end
    for _, pending in ipairs(self.drops) do
        if pending == drop then
            if drop.collected or self.claims[drop.warehouse.key] then return false end
            drop.vx, drop.vy = vx, vy
            return true
        end
    end
    return false -- 不接受相同 key 的伪造/旧对象或已触地移除的 drop。
end

-- 仅保存本次 Update 结束时仍在途的对象；出生不在 OnCatSpawn 设置跨帧样本。
-- 暂停/非法 dt/无效地面也走这里，held 不会从暂停前/失效前位置扫到恢复后。
function WarehouseDrops:SampleDrops()
    ---@type table<WarehouseDrop, WarehouseDropsDropSample>
    local samples = {}
    for _, drop in ipairs(self.drops) do
        if not drop.collected and not self.claims[drop.warehouse.key] and Finite(drop.x) and Finite(drop.y) then
            samples[drop] = { x = drop.x, y = drop.y, magneticHeld = drop.magneticHeld == true }
        end
    end
    self.dropSamples = samples
end

-- 参考 FlowerPots.SweepAxis：先得到 X 重叠时间区间，而非扫掠包围盒并集。
-- epsilon 扩张的是米单位的边界，不扩大合法时间，触地之后的时间不会被容差纳入。
---@param start number
---@param delta number
---@param low number
---@param high number
---@return boolean, number, number
local function SweepAxis(start, delta, low, high)
    if delta == 0 then return start >= low - EPSILON and start <= high + EPSILON, 0, 1 end
    local a, b = (low - EPSILON - start) / delta, (high + EPSILON - start) / delta
    if a > b then a, b = b, a end
    local enter, leave = math.max(0, a), math.min(1, b)
    return enter <= leave, enter, leave
end

-- 与 FlowerPots.SweptPot 相同的解析判定，额外处理极小 step 的 a=0 退化，避免除零。
-- u 为地面裁段内的 0..1：相对 Y = a*u²+b*u+c，X 重叠区间内取端点及顶点。
---@param drop WarehouseDrop
---@param step number
---@param previous WarehouseDropsRescuerSample
---@param current WarehouseDropsRescuerSample
---@param fraction number 当前人物插值到 step/dt，而不是触地后的帧末位置。
---@return boolean
local function SweptDrop(drop, step, previous, current, fraction)
    local rx1 = previous.x + (current.x - previous.x) * fraction
    local ry1 = previous.y + (current.y - previous.y) * fraction
    local halfW = drop.width / 2 + math.max(previous.halfW, current.halfW)
    local halfH = drop.height / 2 + math.max(previous.halfH, current.halfH)
    local hitX, enter, leave = SweepAxis(drop.x - previous.x, drop.vx * step + previous.x - rx1, -halfW, halfW)
    if not hitX then return false end
    local a, b, c = GRAVITY * step * step / 2, drop.vy * step - (ry1 - previous.y), drop.y - previous.y
    local atEnter = (a * enter + b) * enter + c
    local atLeave = (a * leave + b) * leave + c
    local minimum, maximum = math.min(atEnter, atLeave), math.max(atEnter, atLeave)
    if a > 0 then
        local vertex = math.max(enter, math.min(leave, -b / (2 * a)))
        minimum = math.min(minimum, (a * vertex + b) * vertex + c)
    end
    -- 连续函数的值域与 [-halfH,halfH] 相交，等价于存在同一时刻两轴同时接触。
    return minimum <= halfH + EPSILON and maximum >= -halfH - EPSILON
end

-- held 的两条世界线都属于同一 Update 段：drop 与人物分别线性插值，转到相对空间。
-- X/Y slab 的 enter/leave 必须相交，不能用两个 AABB 并集判定“曾经靠近”。
-- 新 held/上一样本仍 free/人物样本失效时只判本帧末真实接触，不扫过出生/吸附前位置。
---@param drop WarehouseDrop
---@param sample WarehouseDropsDropSample?
---@param previous WarehouseDropsRescuerSample?
---@param current WarehouseDropsRescuerSample
---@return boolean
local function SweptHeldDrop(drop, sample, previous, current)
    local x0, y0 = drop.x, drop.y
    local rescuer0 = current
    if sample and sample.magneticHeld and previous and previous.node == current.node then
        x0, y0, rescuer0 = sample.x, sample.y, previous
    end
    local halfW = drop.width / 2 + math.max(rescuer0.halfW, current.halfW)
    local halfH = drop.height / 2 + math.max(rescuer0.halfH, current.halfH)
    local hitX, enterX, leaveX = SweepAxis(x0 - rescuer0.x,
        drop.x - x0 - (current.x - rescuer0.x), -halfW, halfW)
    if not hitX then return false end
    local hitY, enterY, leaveY = SweepAxis(y0 - rescuer0.y,
        drop.y - y0 - (current.y - rescuer0.y), -halfH, halfH)
    return hitY and math.max(enterX, enterY) <= math.min(leaveX, leaveY)
end

-- y 向下的首次落地正根；负 vy 不有理化，避免 sqrt+vy 相消为 0。
-- 已在地面且向上飞必须先完成 -2vy/g 的回落，不能把起跳当作 miss。
---@param vy number
---@param distance number 非负，drop 底边到地面距离。
---@return number
local function GroundTime(vy, distance)
    if distance == 0 then return vy < 0 and -2 * vy / GRAVITY or 0 end
    local root = math.sqrt(vy * vy + 2 * GRAVITY * distance)
    if vy >= 0 then return 2 * distance / (root + vy) end
    return (root - vy) / GRAVITY
end

---@param drop WarehouseDrop
---@param reason string? 缺省为真实人物收取；finalize 仅发库存，不记挑战接取分。
---@return boolean 库存发放成功。
function WarehouseDrops:Claim(drop, reason)
    local game = self.game
    if self.disposed or not self.started or not game or type(drop) ~= "table"
        or type(drop.warehouse) ~= "table" or drop.collected then return false end
    local key = drop.warehouse.key
    if self.byKey[key] ~= drop.warehouse or self.claims[key] then return false end
    local owns = false
    for _, pending in ipairs(self.drops) do if pending == drop then owns = true; break end end
    if not owns then return false end
    self.claims[key] = true -- 必须先锁；GrantWarehouse 内即使再次触发 OnCatSpawn 也不能重复发放。
    local props = game.props
    if not props or type(props.GrantWarehouse) ~= "function" then
        self.claims[key] = nil
        self:WarnOnce("grant", "props:GrantWarehouse 尚未就绪；已回退领取锁，后续猫可重掉")
        return false
    end
    local ok, granted = pcall(props.GrantWarehouse, props, drop.kind)
    if not ok or granted ~= true then
        self.claims[key] = nil -- bool=false/异常均回退，不写脏标志，不吞掉仓库未来机会。
        print(string.format("[仓库掉落] %s 发放 %s 失败，领取锁已回退：%s",
            key, drop.kind, ok and "GrantWarehouse 返回非 true" or tostring(granted)))
        return false
    end
    -- 发放成功后立即原子清掉本仓库全部在途，不让同帧其它件重复领取。
    -- 新建数组而不是原数组 table.remove：Update 持有的遍历快照不会错位/跳过其它仓库。
    ---@type WarehouseDrop[]
    local remaining = {}
    local removed = 0
    drop.collected = true -- seed 也保留成功标记；失败路径绝不标同店其它件。
    for _, pending in ipairs(self.drops) do
        if pending.warehouse.key == key then
            pending.collected = true
            self.dropSamples[pending] = nil
            removed = removed + 1
        else remaining[#remaining + 1] = pending end
    end
    self.drops = remaining
    game.layoutDirty = true -- 只通知宿主 Update 后 Save，不在这里保存半帧状态。
    if game.run and reason ~= "finalize" then game.run:OnClaim(drop) end
    print(string.format("[仓库掉落] 接住 %s 的 %s，已锁定加入库存并清除同仓库在途 %d 件",
        key, drop.kind, removed))
    return true
end

-- 先原子 detach/收磁组，再看 seed 的领取锁；CollectForDrop 默认会 Claim seed。
-- 数领取锁的增量而不是数 result.drops（同店多件只发一件），始终返回整数库存数。
---@param drop WarehouseDrop
---@return integer
function WarehouseDrops:CollectTouchedDrop(drop)
    local before = 0
    for _, claimed in pairs(self.claims) do if claimed == true then before = before + 1 end end
    local game = self.game
    local magnetic = game and game.magnetic or nil
    if magnetic and type(magnetic.CollectForDrop) == "function" then magnetic:CollectForDrop(drop) end
    if not self.claims[drop.warehouse.key] then self:Claim(drop) end
    local after = 0
    for _, claimed in pairs(self.claims) do if claimed == true then after = after + 1 end end
    return math.max(0, after - before)
end

--- 暂停/无效 dt 也要调用以刷新双方样本；返回成功新增库存数，不涉及任何猫计数。
---@param dt number
---@return integer
function WarehouseDrops:Update(dt)
    local game = self.game
    if self.disposed or not self.started or not game then return 0 end
    local current = ReadRescuer(game)
    local previous = self.rescuerSample
    self.rescuerSample = current -- 放在所有早退之前，避免恢复/人物替换后的跨帧误收。
    if game.paused or not Finite(dt) or dt <= 0 then self:SampleDrops(); return 0 end
    if not Finite(game.groundY) then
        self:WarnOnce("ground", "groundY 无效，暂不推进在途物品")
        self:SampleDrops()
        return 0
    end
    local collected = 0
    -- Claim 成功会立即换掉 self.drops；遍历本帧快照，已领取同仓库后续项直接跳过。
    -- 失败/触地只标记当前件，帧末过滤当前数组，绝不误删除其它仓库或回调中新生的物品。
    local active = self.drops
    ---@type table<WarehouseDrop, boolean>
    local discarded = {}
    for index = #active, 1, -1 do
        local drop = active[index]
        local sample = self.dropSamples[drop]
        local finished = self.claims[drop.warehouse.key] == true or drop.collected == true
        if not finished then
            if drop.magneticHeld == true then
                -- Mag.Update 已同步到本帧 root：不再积分，也不因 root 触地回收 held 物件。
                if current and SweptHeldDrop(drop, sample, previous, current) then
                    collected = collected + self:CollectTouchedDrop(drop)
                    finished = true
                end
            else
                local distance = game.groundY - drop.y - drop.height / 2
                if distance < -EPSILON then
                    -- 例如宿主变更了地面：地面下的掉落直接漏掉，不向人物补做晚收扫掠。
                    finished = true
                else
                    local groundTime = GroundTime(drop.vy, math.max(0, distance))
                    local step = math.min(dt, groundTime)
                    local rescuer0 = previous
                    if current and (not rescuer0 or rescuer0.node ~= current.node
                        or (sample and sample.magneticHeld)) then
                        rescuer0 = current -- held->free 从当前位置重新起段，不拼接吸附/出生旧样本。
                    end
                    if current and rescuer0 and SweptDrop(drop, step, rescuer0, current, step / dt) then
                        collected = collected + self:CollectTouchedDrop(drop) -- 自由但已关联磁组也先收整组。
                        -- 发放失败只回收这一件；同仓库其它在途保留，领取锁回退也允许下一只猫重掉。
                        finished = true
                    else
                        drop.x = drop.x + drop.vx * step
                        drop.y = drop.y + drop.vy * step + GRAVITY * step * step / 2
                        drop.vy = drop.vy + GRAVITY * step
                        finished = groundTime <= dt
                    end
                end
            end
            if finished and not self.claims[drop.warehouse.key] then
                print(string.format("[仓库掉落] %s 的 %s 回收未领取，后续猫可重新掉落",
                    drop.warehouse.key, drop.kind))
            end
        end
        if finished then discarded[drop] = true end
    end
    ---@type WarehouseDrop[]
    local remaining = {}
    for _, drop in ipairs(self.drops) do
        if not discarded[drop] and not drop.collected and not self.claims[drop.warehouse.key] then
            remaining[#remaining + 1] = drop
        end
    end
    self.drops = remaining
    self:SampleDrops() -- 保存落点，而不是推进前起点；held 下帧扫线不会额外追溯一帧。
    return collected
end

-- 无资源时仍有可见小图；不创建纹理、不使用 Art，不以绘制线宽扩大碰撞箱。
---@param vg NVGContextWrapper
---@param x number 左上角，逻辑像素。
---@param y number
---@param w number
---@param h number
---@param kind string
local function DrawFallback(vg, x, y, w, h, kind)
    nvgBeginPath(vg)
    if kind == "rack" then
        nvgRect(vg, x + w * 0.15, y + h * 0.2, w * 0.7, h * 0.7)
        nvgFillColor(vg, nvgRGBA(255, 252, 237, 255)); nvgFill(vg)
    end
    nvgBeginPath(vg)
    nvgRect(vg, x + w * 0.08, y + h * 0.12, w * 0.84, h * 0.76)
    for bar = 1, 3 do
        local bx = x + w * (0.08 + 0.84 * bar / 4)
        nvgMoveTo(vg, bx, y + h * 0.12); nvgLineTo(vg, bx, y + h * 0.88)
    end
    nvgMoveTo(vg, x + w * 0.08, y + h * 0.5); nvgLineTo(vg, x + w * 0.92, y + h * 0.5)
    nvgStrokeColor(vg, nvgRGBA(30, 29, 27, 255))
    nvgStrokeWidth(vg, math.max(0.6, math.min(w, h) * 0.035)); nvgStroke(vg)
end

--- 仅绘制在途小物品；宿主已在 UI/NanoVGRender 绘图帧内，无自建上下文/缩放/字体。
---@param vg NVGContextWrapper
---@param unit number
function WarehouseDrops:Render(vg, unit)
    if self.disposed or not self.started or #self.drops == 0 or not Finite(unit) or unit <= 0 then return end
    for _, drop in ipairs(self.drops) do
        local w, h = drop.width * unit, drop.height * unit
        local x = (drop.x + (drop.magneticShakeX or 0)) * unit - w / 2
        local y = (drop.y + (drop.magneticShakeY or 0)) * unit - h / 2
        nvgSave(vg)
        if drop.kind == "security_window" and type(PropSystem.RenderSecurity) == "function" then
            PropSystem.RenderSecurity(vg, x, y, w, h) -- 静态接口，x/y 是矩形左上角，不是中心。
        else
            local path = IMAGE_PATHS[drop.kind]
            local image = path and ImageCache.Get(path) or 0
            if path and image > 0 then
                local sourceW, sourceH = ImageCache.GetSize(path)
                local iw, ih = w, h
                if sourceW > 0 and sourceH > 0 then
                    local scale = math.min(w / sourceW, h / sourceH)
                    iw, ih = sourceW * scale, sourceH * scale
                end
                local ix, iy = x + (w - iw) / 2, y + (h - ih) / 2
                nvgBeginPath(vg); nvgRect(vg, ix, iy, iw, ih)
                nvgFillPaint(vg, nvgImagePattern(vg, ix, iy, iw, ih, 0, math.floor(image), 1)); nvgFill(vg)
            else
                DrawFallback(vg, x, y, w, h, drop.kind)
                self:WarnOnce("image:" .. drop.kind, (path or "PropSystem.RenderSecurity") .. " 尚未就绪，使用小栅条兜底")
            end
        end
        nvgRestore(vg)
    end
end

--- 独立副本，仅同关 retry/save 使用；不会导出在途掉落、人物、Node 或库存。
---@return table<string, boolean>
function WarehouseDrops:ExportClaims()
    local result = {}
    for key, claimed in pairs(self.claims) do
        if claimed == true and self.byKey[key] then result[key] = true end
    end
    return result
end

--- 幂等；不释放宿主对象或共享图片。Dispose 后所有玩法接口不再运行。
function WarehouseDrops:Dispose()
    if self.disposed then return end
    self.warehouses, self.byKey, self.claims, self.drops = {}, {}, {}, {}
    self.dropSamples = {}
    self.rescuerSample, self.game = nil, nil
    self.warnings = {}
    self.started, self.disposed = false, true
    print("[仓库掉落] 已清理索引、在途物品与人物样本")
end

return WarehouseDrops
