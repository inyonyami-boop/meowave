-- 单机关卡磁猫生命周期；基于宿主 scaffold-2d-physics 的速度控制/延迟回收约定。
-- 不创建 Node、Scene、刚体、事件或绘图，不修改 Game 的救援/接猫/终态计数。
-- 米制，逻辑 y 向下；猫读取 node.position2D 后反转 y。普通猫 radius 永不改变。
--
-- 宿主顺序：Props.Update -> MagneticCats.Update -> Drops/Pots.Update -> TryCatch/删猫。
-- Contact(ballA,ballB) 在 Game 的猫终态过滤之前转发；只联组，不写物理或移除实体。
-- game:CollectCat(ball) 先 CollectGroup(ball)，再完成该 ball 的唯一计数/标 caught。
-- CollectGroup 先拆整组，再默认递归 game:CollectCat(其它猫)，因此不会循环计数。
-- Drops 提供 SetMotion(drop,vx,vy)、Claim(drop)；Pots 提供 GetFallingPots()、
-- SetFallingMotion(pot,vx,vy)、CollectPot(pot)。未接触只控速度，不能收取。
-- 实际接触后物件 magneticHeld=true，由本模块跟随；各物件模块跳过自身积分/伤害。
-- Drops 仍可检测已关联物件接触人物，并调用 CollectForDrop(drop) 收整组。
-- FinishPlaying 在冻结/保存前 Finalize；Dispose 在 Game Scene 释放前调用。
--
-- 碰撞设计（先设计后实现，边界容差 0.000001 米，不扩大普通猫半径）：
--                 .-----------------.    吸力圆 R = 出生窗实际 h * 3
--               .'     waiting ○     '.  欧式中心距 <= R 才吸/提前 Release
--              /          ↓            \ （不是三格楼高，不是方形范围）
--             |      ○---磁猫---[drop]   | 猫：原圆 r；drop：width x height AABB
--              \          \ [盆]       / 盆：旋转主体 AABB，不包括枝叶
--               '---------------------'
--          尚在 R 内但未接触 ○     -> 只有速度，绝不进入 CollectGroup
--          圆圆 / 圆到 AABB 最近点 / AABB-AABB 真实接触 -> 联组
--          多磁猫联组采用一个 root + 扁平 links，不互相作为 parent，不可能成环。
--          每实体仅属一组；root 改变时重算世界偏移，不把旧 root 偏移套到新 root。
--   ===================== groundY
--          caught/missed/safe/死亡停止；trapped 未 caught 可继续吸，rescueCounted 不停磁。
--          最后一个磁源终态 -> 解绑并释放全组；有其它活磁源 -> 重选 root。
--          暂停/非法 dt 不 Release、不控速度、不联新组；Finalize 只收已相接的 trapped drop。
--          新猫/替换 Node 按对象身份而非 id 注册；旧 Node 不复用、不保留跨局样本。

local Cats = require("Global.CatSpawner")
local EPSILON, SPEED, GRAVITY = 0.000001, 6, 12
-- 只用于速度目标的 4 毫米内穿行程，不是碰撞 EPS/半径扩张。
-- 终点若恰好等于圆边界，真实刚体 damping 会让每步少走一点而永远不相接。
local CONTACT_TRAVEL = 0.004

---@class MagneticCat : WorkshopBall
---@field magnetic boolean?
---@field trapped boolean?
---@field rescueCounted boolean?
---@field magneticTouchedCat boolean?
---@field magneticWindowHeight number? 建议 Cats.Create 保存出生 GetWindowRect 返回的 h。
---@field magneticRadius number? 本模块缓存 h * 3，供美术读，不是猫碰撞半径。
---@field magneticHeld boolean?
---@field dead boolean?
---@field removed boolean?
---@field disposed boolean?

---@class MagneticDrop : WarehouseDrop
---@field vx number?
---@field magneticHeld boolean?
---@field collected boolean?

---@class MagneticPot : FlowerPot
---@field vx number?
---@field magneticHeld boolean?
---@field collected boolean?

---@class MagneticDropsHost
---@field drops MagneticDrop[]
---@field claims table<string, boolean>?
---@field disposed boolean?
---@field SetMotion fun(self: MagneticDropsHost, drop: MagneticDrop, vx: number, vy: number): boolean?
---@field Claim fun(self: MagneticDropsHost, drop: MagneticDrop, reason: string?): boolean

---@class MagneticPotsHost
---@field pots MagneticPot[]
---@field disposed boolean?
---@field GetFallingPots fun(self: MagneticPotsHost): MagneticPot[]
---@field SetFallingMotion fun(self: MagneticPotsHost, pot: MagneticPot, vx: number, vy: number): boolean?
---@field CollectPot fun(self: MagneticPotsHost, pot: MagneticPot): boolean?

---@class MagneticGame
---@field balls MagneticCat[]
---@field windows table[]
---@field groundY number
---@field released number
---@field paused boolean?
---@field disposed boolean?
---@field warehouseDrops MagneticDropsHost?
---@field flowerPots MagneticPotsHost?
---@field specialFloors SpecialFloors?
---@field rescuer {node: Node?, catchWidth: number, height: number, entering: boolean?}?
---@field GetWindowRect fun(self: MagneticGame, index: integer): number, number, number, number
---@field CollectCat (fun(self: MagneticGame, ball: MagneticCat): boolean?)?

---@class MagneticCollection
---@field cats MagneticCat[]
---@field drops MagneticDrop[]
---@field pots MagneticPot[]

---@class MagneticCollectCallbacks
---@field cat fun(cat: MagneticCat)? 缺省 game:CollectCat；false callbacks 禁用所有回调。
---@field drop fun(drop: MagneticDrop)? 缺省 WarehouseDrops:Claim。
---@field pot fun(pot: MagneticPot)? 缺省 FlowerPots:CollectPot。

---@alias MagneticKind "cat"|"drop"|"pot"

---@class MagneticLink
---@field kind MagneticKind
---@field entity MagneticCat|MagneticDrop|MagneticPot
---@field group MagneticGroup
---@field dx number 世界偏移，盆是轴心偏移而非主体中心偏移。
---@field dy number

---@class MagneticGroup
---@field root MagneticCat
---@field links MagneticLink[] 扁平唯一成员，root 也是 cat link。
---@field active boolean

---@class MagneticGeometry
---@field kind MagneticKind
---@field entity MagneticCat|MagneticDrop|MagneticPot
---@field x number 碰撞主体中心。
---@field y number
---@field halfW number
---@field halfH number
---@field radius number 圆形为原 radius，矩形为 0。

---@class MagneticCats
---@field game MagneticGame?
---@field groups MagneticGroup[]
---@field cats table<MagneticCat, MagneticLink?>
---@field drops table<MagneticDrop, MagneticLink>
---@field pots table<MagneticPot, MagneticLink>
---@field nodes table<MagneticCat, Node?>
---@field radii table<MagneticCat, number>
---@field stopped table<MagneticCat, boolean>
---@field warnings table<string, boolean>
---@field shaking table<MagneticDrop|MagneticPot, boolean>
---@field controlled table<MagneticCat|MagneticDrop|MagneticPot, MagneticCat?> 本步实际写速成功的磁源，不代表接触联组。
---@field shakeTime number
---@field disposed boolean
---@field finalized boolean
local MagneticCats = {}
MagneticCats.__index = MagneticCats

---@param value number?
---@return boolean
local function Finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@return MagneticCollection
local function EmptyCollection()
    return { cats = {}, drops = {}, pots = {} }
end

---@param cat MagneticCat
---@return boolean
local function Terminal(cat)
    if cat.caught or cat.missed or cat.dead or cat.removed or cat.disposed or cat.rolling then return true end
    -- 防盗窗已计救援但实体仍在窗内；不要用 rescueCounted 或 waiting 阻断其吸力。
    return cat.safe == true and cat.trapped ~= true
end

---@param cat MagneticCat
---@return boolean
local function HasReleased(cat)
    return not cat.waiting
end

---@param cat MagneticCat
---@return number?, number?
local function ReadCat(cat)
    if not cat.node or cat.dead or cat.removed or cat.disposed then return nil, nil end
    -- 外部若已 Dispose 而未来得及从 balls 删除，绑定 getter 失败也不继续碰旧 Node。
    local ok, position = pcall(function() return cat.node.position2D end)
    if not ok or not position or not Finite(position.x) or not Finite(position.y) then return nil, nil end
    return position.x, -position.y
end

---@param cat MagneticCat
---@return number, number
local function CatVelocity(cat)
    if cat.waiting or cat.trapped or cat.matchmakingHeld or not cat.body then return 0, 0 end
    local ok, velocity = pcall(function() return cat.body.linearVelocity end)
    if not ok or not velocity or not Finite(velocity.x) or not Finite(velocity.y) then return 0, 0 end
    return velocity.x, -velocity.y
end

---@param entity MagneticCat|MagneticDrop|MagneticPot
---@param kind MagneticKind
---@return number?, number?
local function Position(entity, kind)
    if kind == "cat" then return ReadCat(entity --[[@as MagneticCat]]) end
    local object = entity --[[@as MagneticDrop|MagneticPot]]
    if not Finite(object.x) or not Finite(object.y) then return nil, nil end
    return object.x, object.y
end

---@param cat MagneticCat
---@return boolean
local function UsableCat(cat)
    return not Terminal(cat) and cat.node ~= nil and cat.body ~= nil and Finite(cat.radius) and cat.radius > 0
end

---@param game MagneticGame
---@return MagneticCats
function MagneticCats.New(game)
    local self = setmetatable({}, MagneticCats)
    self:Init(game)
    return self
end

---@param game MagneticGame
function MagneticCats:Init(game)
    self.game = game
    self.groups, self.cats, self.drops, self.pots = {}, {}, {}, {}
    self.nodes, self.radii, self.stopped, self.warnings = {}, {}, {}, {}
    self.shaking, self.shakeTime = {}, 0
    self.controlled = {}
    self.disposed, self.finalized = false, false
end

---@param key string
---@param text string
function MagneticCats:WarnOnce(key, text)
    if self.warnings[key] then return end
    self.warnings[key] = true
    print("[磁猫] " .. text)
end

---@param cat MagneticCat
---@return boolean
function MagneticCats:IsSource(cat)
    return cat.magnetic == true and UsableCat(cat) and not self.stopped[cat]
end

---@param cat MagneticCat
---@return boolean
function MagneticCats:ContainsCat(cat)
    local game = self.game
    if not game then return false end
    for _, current in ipairs(game.balls) do if current == cat then return true end end
    return false
end

---@param entity MagneticCat|MagneticDrop|MagneticPot
---@param kind MagneticKind
---@return MagneticLink?
function MagneticCats:Link(entity, kind)
    if kind == "cat" then return self.cats[entity --[[@as MagneticCat]]] end
    if kind == "drop" then return self.drops[entity --[[@as MagneticDrop]]] end
    return self.pots[entity --[[@as MagneticPot]]]
end

---@param link MagneticLink
function MagneticCats:IndexLink(link)
    if link.kind == "cat" then self.cats[link.entity --[[@as MagneticCat]]] = link
    elseif link.kind == "drop" then self.drops[link.entity --[[@as MagneticDrop]]] = link
    else self.pots[link.entity --[[@as MagneticPot]]] = link end
end

---@param link MagneticLink
function MagneticCats:UnindexLink(link)
    if link.kind == "cat" then self.cats[link.entity --[[@as MagneticCat]]] = nil
    elseif link.kind == "drop" then self.drops[link.entity --[[@as MagneticDrop]]] = nil
    else self.pots[link.entity --[[@as MagneticPot]]] = nil end
    link.entity.magneticHeld = false
end

---@param root MagneticCat
---@return MagneticGroup
function MagneticCats:MakeGroup(root)
    local group = { root = root, links = {}, active = true } --[[@as MagneticGroup]]
    self.groups[#self.groups + 1] = group
    self:AddLink(group, root, "cat")
    return group
end

---@param group MagneticGroup
---@param entity MagneticCat|MagneticDrop|MagneticPot
---@param kind MagneticKind
function MagneticCats:AddLink(group, entity, kind)
    if self:Link(entity, kind) then return end
    local x, y = Position(entity, kind)
    local rx, ry = ReadCat(group.root)
    local link = { kind = kind, entity = entity, group = group,
        dx = (x or 0) - (rx or 0), dy = (y or 0) - (ry or 0) } --[[@as MagneticLink]]
    group.links[#group.links + 1] = link
    self:IndexLink(link)
    entity.magneticHeld = entity ~= group.root
end

---@param group MagneticGroup
function MagneticCats:ReleaseGroup(group)
    if not group.active then return end
    group.active = false
    for _, link in ipairs(group.links) do self:UnindexLink(link) end
    group.links = {}
end

---@param group MagneticGroup
---@param root MagneticCat
function MagneticCats:Reanchor(group, root)
    local rx, ry = ReadCat(root)
    if not rx or not ry then self:ReleaseGroup(group); return end
    group.root = root
    for _, link in ipairs(group.links) do
        local x, y = Position(link.entity, link.kind)
        link.dx, link.dy = (x or rx) - rx, (y or ry) - ry
        link.entity.magneticHeld = link.entity ~= root
    end
end

-- Union 的 root 不指向其它组：直接将所有 links 换到一个组，再销毁旧组。
---@param first MagneticGroup
---@param second MagneticGroup
function MagneticCats:Union(first, second)
    if first == second or not first.active or not second.active then return end
    local rx, ry = ReadCat(first.root)
    for _, link in ipairs(second.links) do
        local x, y = Position(link.entity, link.kind)
        link.group, link.dx, link.dy = first, (x or 0) - (rx or 0), (y or 0) - (ry or 0)
        first.links[#first.links + 1] = link
        link.entity.magneticHeld = link.entity ~= first.root
    end
    local fixedRoot = second.root.trapped == true and second.root or first.root
    second.active, second.links = false, {}
    if fixedRoot ~= first.root then self:Reanchor(first, fixedRoot) end
end

---@param a MagneticCat|MagneticDrop|MagneticPot
---@param aKind MagneticKind
---@param b MagneticCat|MagneticDrop|MagneticPot
---@param bKind MagneticKind
---@return boolean 新联组/新成员；同组重复接触返回 false。
function MagneticCats:Join(a, aKind, b, bKind)
    if a == b then return false end
    local aLink, bLink = self:Link(a, aKind), self:Link(b, bKind)
    if aLink and bLink and aLink.group == bLink.group then return false end
    local aSource = aKind == "cat" and self:IsSource(a --[[@as MagneticCat]])
    local bSource = bKind == "cat" and self:IsSource(b --[[@as MagneticCat]])
    if not aLink and not bLink and not aSource and not bSource then return false end
    local first = aLink and aLink.group or (aSource and self:MakeGroup(a --[[@as MagneticCat]]) or nil)
    local second = bLink and bLink.group or (bSource and self:MakeGroup(b --[[@as MagneticCat]]) or nil)
    if first and second then self:Union(first, second)
    elseif first then self:AddLink(first, b, bKind)
    elseif second then self:AddLink(second, a, aKind)
    else return false end
    return true
end

---@param a MagneticCat
---@param b MagneticCat
local function MarkCatContact(a, b)
    if a.magnetic == true and b.magnetic ~= true then a.magneticTouchedCat = true end
    if b.magnetic == true and a.magnetic ~= true then b.magneticTouchedCat = true end
end

--- 仅真实猫接触回调调用；不读/写速度，不 Release，不删除，不执行收取回调。
---@param ballA MagneticCat?
---@param ballB MagneticCat?
---@return boolean
function MagneticCats:Contact(ballA, ballB)
    local game = self.game
    if self.disposed or self.finalized or not game or game.paused or game.disposed then return false end
    if not ballA or not ballB or not self:ContainsCat(ballA) or not self:ContainsCat(ballB)
        or not UsableCat(ballA) or not UsableCat(ballB) or ballA.waiting or ballB.waiting
        or ballA.matchmakingHeld or ballB.matchmakingHeld then return false end
    -- trapped 的 disabled/kinematic Node 无物理 contact，Update 的几何补检会联组。
    local joined = self:Join(ballA, "cat", ballB, "cat")
    if self:Link(ballA, "cat") or self:Link(ballB, "cat") then MarkCatContact(ballA, ballB) end
    return joined
end

---@param cat MagneticCat
function MagneticCats:Register(cat)
    local previousNode = self.nodes[cat]
    if previousNode ~= nil and previousNode == cat.node then return end
    -- 首次 Update 前的 PhysicsContact 已经建组，首次登记不能误拆该关系。
    -- 真正替换 Node 则整组释放，不将旧对象的偏移/held 状态移到新 Node。
    if previousNode then
        local old = self.cats[cat]
        if old then self:ReleaseGroup(old.group) end
    end
    self.nodes[cat], self.radii[cat], self.stopped[cat] = cat.node, nil, nil
    local game = self.game
    if cat.magnetic ~= true or not game then return end
    local height = cat.magneticWindowHeight
    if height == nil or not Finite(height) or height <= 0 then
        if type(cat.window) == "number" and game.windows[cat.window] then
            local _, _, _, actualHeight = game:GetWindowRect(cat.window)
            height = actualHeight
        end
    end
    if height == nil or not Finite(height) or height <= 0 then
        self:WarnOnce("height:" .. tostring(cat.id), "磁猫出生窗高度无效，不猜测吸力半径")
        return
    end
    self.radii[cat], cat.magneticRadius = height * 3, height * 3
    print(string.format("[磁猫] #%s 出生窗 h=%.6f 米，吸力 R=%.6f 米", tostring(cat.id), height, height * 3))
end

---@param entity MagneticCat|MagneticDrop|MagneticPot
---@param kind MagneticKind
---@return MagneticGeometry?
local function Geometry(entity, kind)
    local x, y = Position(entity, kind)
    if not x or not y then return nil end
    if kind == "cat" then
        local cat = entity --[[@as MagneticCat]]
        return { entity = cat, kind = kind, x = x, y = y, radius = cat.radius,
            halfW = cat.radius, halfH = cat.radius }
    end
    local object = entity --[[@as MagneticDrop|MagneticPot]]
    if not Finite(object.width) or not Finite(object.height) or object.width <= 0 or object.height <= 0 then return nil end
    local halfW, halfH = object.width / 2, object.height / 2
    if kind == "pot" then
        local pot = entity --[[@as MagneticPot]]
        if not Finite(pot.angle) then return nil end
        local sine, cosine = math.sin(pot.angle), math.cos(pot.angle)
        x, y = x + sine * pot.height / 2, y - cosine * pot.height / 2
        halfW = (math.abs(cosine) * pot.width + math.abs(sine) * pot.height) / 2
        halfH = (math.abs(sine) * pot.width + math.abs(cosine) * pot.height) / 2
    end
    return { entity = entity, kind = kind, x = x, y = y, radius = 0, halfW = halfW, halfH = halfH }
end

---@param a MagneticGeometry
---@param b MagneticGeometry
---@return boolean
local function Touches(a, b)
    if a.radius > 0 and b.radius > 0 then
        return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= (a.radius + b.radius + EPSILON) ^ 2
    end
    if a.radius == 0 and b.radius == 0 then
        return math.abs(a.x - b.x) <= a.halfW + b.halfW + EPSILON
            and math.abs(a.y - b.y) <= a.halfH + b.halfH + EPSILON
    end
    local circle, box = a.radius > 0 and a or b, a.radius > 0 and b or a
    local dx = math.max(0, math.abs(circle.x - box.x) - box.halfW)
    local dy = math.max(0, math.abs(circle.y - box.y) - box.halfH)
    return dx * dx + dy * dy <= (circle.radius + EPSILON) ^ 2
end

---@param dt number
---@param geometry MagneticGeometry
---@param source MagneticCat
---@param gap number
---@param sourceVX number
---@param sourceVY number
---@return number, number
local function Toward(dt, geometry, source, gap, sourceVX, sourceVY)
    local sx, sy = ReadCat(source)
    if not sx or not sy then return 0, 0 end
    local dx, dy = sx - geometry.x, sy - geometry.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance > EPSILON then
        -- 速度目标略进真实交界内；必须靠原生位移实际触圈后才由 Touches/Contact 联组。
        -- 不直接 setPosition，不放宽 Touches 的 EPS，不改普通猫 shape/radius。
        local targetGap = math.max(0, gap - math.min(CONTACT_TRAVEL, gap * 0.05))
        local speed = math.min(SPEED, math.max(0, distance - targetGap) / dt)
        return sourceVX + dx / distance * speed, sourceVY + dy / distance * speed
    end
    return sourceVX, sourceVY
end

---@param cat MagneticCat
---@param vx number
---@param vy number
---@param dt number
---@return boolean
local function MoveCat(cat, vx, vy, dt)
    if cat.waiting or cat.trapped or cat.matchmakingHeld or cat.pairResetPending or not UsableCat(cat) then return false end
    local scale = cat.body.gravityScale
    if not Finite(scale) then scale = 1 end
    -- Box2D 是半隐式积分：先 velocity += gravity*dt，再用新速度推进位置。
    -- 猫要补完整 g*dt，不能沿用纯 Lua drop/盆抛物线的半程 g*dt/2。
    -- 保留实际阻尼；Toward 的微小内穿速度让有阻尼的真实圆仍能相接，伞继续原限速。
    local physicalY = -vy + GRAVITY * scale * dt
    if cat.parachute then physicalY = math.max(-1.15, physicalY) end
    cat.body.linearVelocity = Vector2(vx, physicalY)
    cat.magneticMotionApplied = true
    cat.body.awake = true
    return true
end

---@param group MagneticGroup
---@param dt number
function MagneticCats:FollowGroup(group, dt)
    local rx, ry = ReadCat(group.root)
    if not rx or not ry then self:ReleaseGroup(group); return end
    local vx, vy = CatVelocity(group.root)
    for _, link in ipairs(group.links) do
        if link.entity ~= group.root then
            if link.kind == "cat" then
                local cat = link.entity --[[@as MagneticCat]]
                local x, y = ReadCat(cat)
                if x and y then
                    local dx, dy = rx + link.dx - x, ry + link.dy - y
                    local distance = math.sqrt(dx * dx + dy * dy)
                    local factor = distance > EPSILON and math.min(1 / dt, SPEED / distance) or 0
                    MoveCat(cat, vx + dx * factor, vy + dy * factor, dt)
                end
            else
                -- 仅已相接的纯 Lua 物件跟随；自由物件绝不在这里积分或瞬移。
                local object = link.entity --[[@as MagneticDrop|MagneticPot]]
                object.x, object.y, object.vx, object.vy = rx + link.dx, ry + link.dy, vx, vy
            end
        end
    end
end

-- 清理必须先于任何节点读取；身份替换/终态不得留下幽灵磁源或 held 物件。
---@param liveCats table<MagneticCat, boolean>
---@param liveDrops table<MagneticDrop, boolean>
---@param livePots table<MagneticPot, boolean>
function MagneticCats:Prune(liveCats, liveDrops, livePots)
    for _, group in ipairs(self.groups) do
        if group.active then
            ---@type MagneticLink[]
            local remaining = {}
            for _, link in ipairs(group.links) do
                local keep = false
                if link.kind == "cat" then
                    local cat = link.entity --[[@as MagneticCat]]
                    keep = liveCats[cat] == true and UsableCat(cat) and self.nodes[cat] == cat.node
                        and ReadCat(cat) ~= nil
                elseif link.kind == "drop" then keep = liveDrops[link.entity --[[@as MagneticDrop]]] == true
                else keep = livePots[link.entity --[[@as MagneticPot]]] == true end
                if keep then remaining[#remaining + 1] = link else self:UnindexLink(link) end
            end
            group.links = remaining
            local root = group.root
            if not liveCats[root] or not self:IsSource(root) or not self.cats[root] then
                ---@type MagneticCat?
                local replacement = nil
                for _, link in ipairs(remaining) do
                    if link.kind == "cat" and self:IsSource(link.entity --[[@as MagneticCat]]) then
                        replacement = link.entity --[[@as MagneticCat]]
                        break
                    end
                end
                if replacement then self:Reanchor(group, replacement) else self:ReleaseGroup(group) end
            end
        end
    end
    ---@type MagneticGroup[]
    local active = {}
    for _, group in ipairs(self.groups) do if group.active then active[#active + 1] = group end end
    self.groups = active
    for cat in pairs(self.nodes) do
        if not liveCats[cat] then self.nodes[cat], self.radii[cat], self.stopped[cat] = nil, nil, nil end
    end
end

---@param game MagneticGame?
---@param source MagneticCat
---@param geometry MagneticGeometry
---@return number, number
local function RangePoint(game, source, geometry)
    local cat = geometry.kind == "cat" and geometry.entity --[[@as MagneticCat?]] or nil
    if game and cat and cat.matchmakingHeld then
        local index = cat.matchmakingWindow or cat.window
        if game.windows[index] then
            local x, y, w, h = game:GetWindowRect(index)
            local sx = source.node.position2D.x
            return math.max(x, math.min(x + w, sx)), y + h / 2
        end
    end
    return geometry.x, geometry.y
end

---@param source MagneticCat
---@param geometry MagneticGeometry
---@param radius number
---@param game MagneticGame?
---@return boolean
local function InRange(source, geometry, radius, game)
    local x, y = ReadCat(source)
    local gx, gy = RangePoint(game, source, geometry)
    return x ~= nil and y ~= nil and (gx - x) ^ 2 + (gy - y) ^ 2 <= (radius + EPSILON) ^ 2
end

--- 只认本步成功控速或活组的非根成员；磁猫本体/范围内抖动不等于被吸引。
--- 结算前再验证来源仍活、实体仍在宿主中；源刚漏掉/被收取时不沿用旧快照。
---@param entity MagneticCat|MagneticDrop|MagneticPot
---@param kind MagneticKind
---@return MagneticCat?
function MagneticCats:GetAttractionSource(entity, kind)
    local game = self.game
    if self.disposed or self.finalized or not game or game.disposed then return nil end
    if kind == "cat" then
        local cat = entity --[[@as MagneticCat]]
        if not UsableCat(cat) or cat.waiting or cat.matchmakingHeld or not self:ContainsCat(cat) then return nil end
    elseif kind == "drop" then
        local drop = entity --[[@as MagneticDrop]]
        local host = game.warehouseDrops
        if not host or host.disposed or drop.collected or (host.claims and host.claims[drop.warehouse.key]) then return nil end
        local live = false
        for _, current in ipairs(host.drops) do if current == drop then live = true; break end end
        if not live then return nil end
    else
        local pot = entity --[[@as MagneticPot]]
        local host = game.flowerPots
        if not host or host.disposed or pot.collected or pot.state ~= "falling" then return nil end
        local live = false
        for _, current in ipairs(host.pots) do if current == pot then live = true; break end end
        if not live then return nil end
    end
    local link = self:Link(entity, kind)
    local source = link and link.group.active and link.group.root ~= entity and link.group.root or self.controlled[entity]
    if not source or not self:IsSource(source) or not self:ContainsCat(source)
        or self.nodes[source] ~= source.node or ReadCat(source) == nil then return nil end
    if link and link.group.active and link.group.root == source then return source end
    local geometry = Geometry(entity, kind)
    local radius = self.radii[source]
    if geometry and radius and InRange(source, geometry, radius, game) then return source end
    return nil
end

---@param entity MagneticCat|MagneticDrop|MagneticPot
---@param kind MagneticKind
---@return boolean
function MagneticCats:IsAttracted(entity, kind)
    return self:GetAttractionSource(entity, kind) ~= nil
end

function MagneticCats:ClearShakes()
    for object in pairs(self.shaking) do object.magneticShakeX, object.magneticShakeY = 0, 0 end
    self.shaking = {}
end

--- 仅设置显示偏移；paused不调用，离范围和终态下一次Update立即清除。
---@param entities MagneticGeometry[]
---@param sources MagneticCat[]
---@param dt number
function MagneticCats:UpdateShakes(entities, sources, dt)
    self:ClearShakes()
    self.shakeTime = self.shakeTime + dt
    for index, geometry in ipairs(entities) do
        if geometry.kind ~= "cat" then
            local object = geometry.entity --[[@as MagneticDrop|MagneticPot]]
            if not object.collected then
                for _, source in ipairs(sources) do
                    if self:IsSource(source) and InRange(source, geometry, self.radii[source], self.game) then
                        local amplitude = math.min(0.012, math.min(object.width, object.height) * 0.035)
                        local phase = self.shakeTime * 30 + index * 2.4
                        object.magneticShakeX = math.sin(phase) * amplitude
                        object.magneticShakeY = math.cos(phase * 1.3) * amplitude * 0.6
                        self.shaking[object] = true
                        break
                    end
                end
            end
        end
    end
end

--- 吸力与几何补检；不会把仅在吸力圆里的实体当作已经被接住。
---@param dt number
function MagneticCats:Update(dt)
    local game = self.game
    if self.disposed or self.finalized or not game or game.disposed or game.paused or not Finite(dt) or dt <= 0 then return end
    self.controlled = {}
    ---@type table<MagneticCat, boolean>
    local liveCats = {}
    ---@type table<MagneticDrop, boolean>
    local liveDrops = {}
    ---@type table<MagneticPot, boolean>
    local livePots = {}
    ---@type MagneticCat[]
    local sources = {}
    ---@type table<MagneticCat, {vx: number, vy: number}>
    local sourceVelocities = {}
    ---@type MagneticGeometry[]
    local entities = {}
    for _, cat in ipairs(game.balls) do
        cat.magneticMotionApplied = false
        liveCats[cat] = true
        self:Register(cat)
        if Terminal(cat) then self.stopped[cat] = true end
        if UsableCat(cat) then
            local geometry = Geometry(cat, "cat")
            if geometry then entities[#entities + 1] = geometry end
            if geometry and self:IsSource(cat) and self.radii[cat] then
                sources[#sources + 1] = cat
                local vx, vy = CatVelocity(cat)
                sourceVelocities[cat] = { vx = vx, vy = vy }
            end
        end
    end
    local dropsHost = game.warehouseDrops
    if dropsHost and not dropsHost.disposed then
        for _, drop in ipairs(dropsHost.drops) do
            if not drop.collected and not (dropsHost.claims and dropsHost.claims[drop.warehouse.key]) then
                local geometry = Geometry(drop, "drop")
                if geometry and geometry.y + geometry.halfH < game.groundY + EPSILON then
                    liveDrops[drop] = true; entities[#entities + 1] = geometry
                end
            end
        end
    end
    local potsHost = game.flowerPots
    if potsHost and not potsHost.disposed then
        local falling = potsHost.GetFallingPots and potsHost:GetFallingPots() or potsHost.pots
        for _, pot in ipairs(falling) do
            if pot.state == "falling" and not pot.collected then
                local geometry = Geometry(pot, "pot")
                if geometry and geometry.y + geometry.halfH < game.groundY + EPSILON then
                    livePots[pot] = true; entities[#entities + 1] = geometry
                end
            end
        end
    end
    self:Prune(liveCats, liveDrops, livePots)
    -- 窗内暂存猫等效覆盖三列；从离磁源最近的宽窗列出窗，然后仍靠真实圆接触联组。
    for _, geometry in ipairs(entities) do
        local cat = geometry.kind == "cat" and geometry.entity --[[@as MagneticCat?]] or nil
        if cat and cat.matchmakingHeld and game.specialFloors then
            for _, source in ipairs(sources) do
                if source ~= cat and InRange(source, geometry, self.radii[source], game) then
                    local targetX = RangePoint(game, source, geometry)
                    if game.specialFloors:OnMagneticRelease(cat --[[@as SpecialFloorBall]], targetX) then
                        local x, y = ReadCat(cat)
                        if x and y then geometry.x, geometry.y = x, y end
                    end
                    break
                end
            end
        end
    end
    -- 普通等待猫立即 Release 且仅加 released 一次；磁猫/已 trapped 猫绝不重新释放。
    for _, geometry in ipairs(entities) do
        if geometry.kind == "cat" then
            local cat = geometry.entity --[[@as MagneticCat]]
            if cat.waiting and cat.magnetic ~= true and not cat.trapped then
                for _, source in ipairs(sources) do
                    if InRange(source, geometry, self.radii[source], game) then
                        Cats.Release(cat)
                        if HasReleased(cat) then
                            game.released = game.released + 1
                            if game.specialFloors then game.specialFloors:OnCatReleased(cat --[[@as SpecialFloorBall]]) end
                        end
                        print(string.format("[磁猫] #%s 提前释放普通等待猫 #%s", tostring(source.id), tostring(cat.id)))
                        break
                    end
                end
            end
        end
    end
    -- 联组只允许真实形状接触。重复扫描完成接触链闭包，每成功一次必减少未关联/组数。
    -- 因此最多 #entities 轮，绝不由多磁猫 A->B->A 循环。
    for _ = 1, #entities do
        local changed = false
        for i, first in ipairs(entities) do
            local firstCat = first.kind == "cat" and first.entity --[[@as MagneticCat?]] or nil
            if not firstCat or ((not firstCat.matchmakingHeld or self:IsSource(firstCat)) and
                (not firstCat.waiting or firstCat.trapped or self:IsSource(firstCat))) then
                for j = i + 1, #entities do
                    local second = entities[j]
                    local secondCat = second.kind == "cat" and second.entity --[[@as MagneticCat?]] or nil
                    if (not secondCat or ((not secondCat.matchmakingHeld or self:IsSource(secondCat)) and
                        (not secondCat.waiting or secondCat.trapped or self:IsSource(secondCat))))
                        and Touches(first, second) then
                        if self:Join(first.entity, first.kind, second.entity, second.kind) then changed = true end
                        if firstCat and secondCat and (self.cats[firstCat] or self.cats[secondCat]) then
                            MarkCatContact(firstCat, secondCat)
                        end
                    end
                end
            end
        end
        if not changed then break end
    end
    -- 尚未联组才朝最近活磁猫控速度；不是距离满足就加入返回列表。
    for _, geometry in ipairs(entities) do
        if not self:Link(geometry.entity, geometry.kind) then
            local cat = geometry.kind == "cat" and geometry.entity --[[@as MagneticCat?]] or nil
            if not cat or (not cat.waiting and not cat.trapped and not cat.matchmakingHeld) then
                ---@type MagneticCat?
                local nearest = nil
                local closest = math.huge
                for _, source in ipairs(sources) do
                    if source ~= geometry.entity and InRange(source, geometry, self.radii[source], game) then
                        local sx, sy = ReadCat(source)
                        if sx and sy then
                            local distance = (geometry.x - sx) ^ 2 + (geometry.y - sy) ^ 2
                            if distance < closest then nearest, closest = source, distance end
                        end
                    end
                end
                if nearest then
                    local gap = geometry.radius > 0 and geometry.radius + nearest.radius or nearest.radius
                    -- 帧初源速度快照，避免 A 先被控速后 B 读取 A 新速度造成顺序偏差。
                    local sourceVelocity = sourceVelocities[nearest]
                    local vx, vy = Toward(dt, geometry, nearest, gap, sourceVelocity.vx, sourceVelocity.vy)
                    local applied = false
                    if cat then applied = MoveCat(cat, vx, vy, dt)
                    elseif geometry.kind == "drop" and dropsHost and dropsHost.SetMotion then
                        applied = dropsHost:SetMotion(geometry.entity --[[@as MagneticDrop]], vx, vy - GRAVITY * dt / 2) == true
                    elseif geometry.kind == "pot" and potsHost and potsHost.SetFallingMotion then
                        applied = potsHost:SetFallingMotion(geometry.entity --[[@as MagneticPot]], vx, vy - GRAVITY * dt / 2) == true
                    end
                    if applied then self.controlled[geometry.entity] = nearest end
                end
            end
        end
    end
    for _, group in ipairs(self.groups) do if group.active then self:FollowGroup(group, dt) end end
    self:CollectTouchingHeldPots()
    self:UpdateShakes(entities, sources, dt)
end

---@param result MagneticCollection
---@param seed MagneticCat?
---@param callbacks MagneticCollectCallbacks|false|nil
---@param includeSeed boolean
---@param claimReason string? finalize 领取不冒充人物接取。
function MagneticCats:Deliver(result, seed, callbacks, includeSeed, claimReason)
    if callbacks == false then return end
    local game = self.game
    if not game then return end
    local custom = type(callbacks) == "table" and callbacks or nil
    for _, cat in ipairs(result.cats) do
        if (includeSeed or cat ~= seed) and not Terminal(cat) then
            if custom and custom.cat then custom.cat(cat)
            elseif game.CollectCat then game:CollectCat(cat)
            else self:WarnOnce("collectCat", "宿主尚未提供 CollectCat；已返回关联猫，不猜测 Game 计数") end
        end
    end
    for _, drop in ipairs(result.drops) do
        if custom and custom.drop then custom.drop(drop)
        elseif game.warehouseDrops and not game.warehouseDrops.disposed then game.warehouseDrops:Claim(drop, claimReason) end
    end
    for _, pot in ipairs(result.pots) do
        if custom and custom.pot then custom.pot(pot)
        elseif game.flowerPots and not game.flowerPots.disposed and game.flowerPots.CollectPot then
            game.flowerPots:CollectPot(pot)
        else self:WarnOnce("collectPot", "宿主尚未提供 CollectPot；花盆不是 toolbar 库存") end
    end
end

---@param group MagneticGroup?
---@return MagneticCollection
function MagneticCats:TakeGroup(group)
    local result = EmptyCollection()
    if not group or not group.active then return result end
    local hasSource = false
    for _, link in ipairs(group.links) do
        if link.kind == "cat" then
            local cat = link.entity --[[@as MagneticCat]]
            if self:IsSource(cat) and self:ContainsCat(cat) and ReadCat(cat) ~= nil
                and (not self.nodes[cat] or self.nodes[cat] == cat.node) then hasSource = true; break end
        end
    end
    -- Ground/死亡可能刚在 Contact 中发生、还未到下一次 Update；不能晚收已经失磁的组。
    if not hasSource then self:ReleaseGroup(group); return result end
    for _, link in ipairs(group.links) do
        if link.kind == "cat" then result.cats[#result.cats + 1] = link.entity --[[@as MagneticCat]]
        elseif link.kind == "drop" then result.drops[#result.drops + 1] = link.entity --[[@as MagneticDrop]]
        else result.pots[#result.pots + 1] = link.entity --[[@as MagneticPot]] end
    end
    -- 先原子 detach 再调宿主：nested CollectCat/Claim 不会再次找到同一组。
    self:ReleaseGroup(group)
    for _, cat in ipairs(result.cats) do if cat.magnetic == true then self.stopped[cat] = true end end
    return result
end

--- cats 含 seed；默认只递归收其它猫，seed 由外层 game:CollectCat 负责唯一计数。
--- 无组返回三个空数组；callbacks=false 可让主自行处理所有返回对象。
---@param ball MagneticCat
---@param callbacks MagneticCollectCallbacks|false|nil
---@return MagneticCollection
function MagneticCats:CollectGroup(ball, callbacks)
    if self.disposed or self.finalized then return EmptyCollection() end
    local link = self.cats[ball]
    local result = self:TakeGroup(link and link.group or nil)
    self:Deliver(result, ball, callbacks, false)
    return result
end

--- 任何已关联 drop 被人物真正接住时，整组猫/物品一起收取，不需要磁猫先触人物。
---@param drop MagneticDrop
---@param callbacks MagneticCollectCallbacks|false|nil
---@return MagneticCollection
function MagneticCats:CollectForDrop(drop, callbacks)
    if self.disposed or self.finalized then return EmptyCollection() end
    local host = self.game and self.game.warehouseDrops or nil
    if not host or host.disposed or drop.collected or (host.claims and host.claims[drop.warehouse.key]) then
        return EmptyCollection()
    end
    local live = false
    for _, pending in ipairs(host.drops) do if pending == drop then live = true; break end end
    if not live then return EmptyCollection() end
    local link = self.drops[drop]
    local result = self:TakeGroup(link and link.group or nil)
    self:Deliver(result, nil, callbacks, true)
    return result
end

---@param pot MagneticPot
---@param callbacks MagneticCollectCallbacks|false|nil
---@return MagneticCollection
function MagneticCats:CollectForPot(pot, callbacks)
    if self.disposed or self.finalized then return EmptyCollection() end
    local link = self.pots[pot]
    local result = self:TakeGroup(link and link.group or nil)
    self:Deliver(result, nil, callbacks, true)
    return result
end

-- 已关联盆不再伤人：盆主体碰到人物可代替猫先入篮，仍然必须真实接触。
-- drop 的精确人物扫掠由 WarehouseDrops.Update 完成，不在这里重复用帧末范围收物。
function MagneticCats:CollectTouchingHeldPots()
    local game = self.game
    local rescuer = game and game.rescuer or nil
    if not game or not rescuer or not rescuer.node or rescuer.entering or rescuer.node.enabled == false then return end
    local position = rescuer.node.position2D
    if not Finite(position.x) or not Finite(position.y) or not Finite(rescuer.catchWidth)
        or not Finite(rescuer.height) or rescuer.catchWidth <= 0 or rescuer.height <= 0 then return end
    ---@type MagneticPot[]
    local pending = {}
    for pot in pairs(self.pots) do
        local geometry = Geometry(pot, "pot")
        if geometry and math.abs(geometry.x - position.x) <= geometry.halfW + rescuer.catchWidth / 2 + EPSILON
            and math.abs(geometry.y + position.y) <= geometry.halfH + rescuer.height / 2 + EPSILON then
            pending[#pending + 1] = pot
        end
    end
    for _, pot in ipairs(pending) do self:CollectForPot(pot) end
end

--- 结算不扩大吸力、不补接猫/盆；只收尚在防盗窗内活磁猫已关联的 drop。
--- 每仓库调用 Claim；同店多个 drop 依赖原子 claims 防重，不直接 GrantWarehouse。
---@return MagneticCollection
function MagneticCats:Finalize()
    if self.disposed or self.finalized then return EmptyCollection() end
    local result = EmptyCollection()
    ---@type table<MagneticDrop, boolean>
    local seen = {}
    for _, group in ipairs(self.groups) do
        if group.active then
            local trapped = false
            for _, link in ipairs(group.links) do
                if link.kind == "cat" then
                    local cat = link.entity --[[@as MagneticCat]]
                    if (cat.trapped or cat.matchmakingHeld) and self:IsSource(cat) and self:ContainsCat(cat) and ReadCat(cat) ~= nil then
                        trapped = true; break
                    end
                end
            end
            if trapped then
                for _, link in ipairs(group.links) do
                    if link.kind == "drop" then
                        local drop = link.entity --[[@as MagneticDrop]]
                        if not seen[drop] then seen[drop] = true; result.drops[#result.drops + 1] = drop end
                    end
                end
            end
        end
    end
    -- 先冻结磁力/释放关系，Claim 的回调即使触发 Update 也不能扩张结算集合。
    self.finalized = true
    self.controlled = {}
    self:ClearShakes()
    for _, group in ipairs(self.groups) do self:ReleaseGroup(group) end
    self.groups = {}
    self:Deliver(result, nil, nil, false, "finalize")
    return result
end

--- 幂等，只清本模块引用及 held 标志，不 Dispose 宿主 Node/Scene/Drop/Pot。
function MagneticCats:Dispose()
    if self.disposed then return end
    self:ClearShakes()
    for _, group in ipairs(self.groups) do self:ReleaseGroup(group) end
    self.groups, self.cats, self.drops, self.pots = {}, {}, {}, {}
    self.nodes, self.radii, self.stopped, self.warnings = {}, {}, {}, {}
    self.controlled = {}
    self.game, self.disposed = nil, true
end

return MagneticCats
