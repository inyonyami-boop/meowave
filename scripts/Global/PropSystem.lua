-- 基于 scaffold-2d-physics 的独立道具模块：复用 game.scene、game.drag 与 UI 绘图上下文。
-- 坐标均为米；接口 y 向下，物理节点放在 (x, -y)。不创建场景、UI 根或 NanoVG 帧。
-- 接入约定：Game 先处理 Ground/终态，再调用 Contact；Update 在覆盖 ball.previousY 前调用。

-- ==================== 一、定义与工厂 ====================
---@class PropBall : WorkshopBall
---@field safe boolean?
---@field parachute boolean?
---@field parachuteWidth number?
---@field magnetic boolean?
---@field magneticTouchedCat boolean? 由磁猫模块在接触普通猫后置 true。
---@field trapped boolean? 防盗窗留猫态，不属于下落或开伞候选。

---@class PropDrag
---@field active boolean
---@field pointerId number
---@field kind string
---@field propId number
---@field fenceId number
---@field x number
---@field y number
---@field angle number
---@field valid boolean
---@field originalX number
---@field originalY number
---@field originalAngle number
---@field originalEnabled boolean
---@field offsetX number
---@field offsetY number
---@field windowKey string 当前吸附预览窗；提交前不改变原窗保护。
---@field originalWindowKey string
---@field rawX number 吸附前的世界坐标，Update 重新验证时不使用已吸附中心。
---@field rawY number

---@class PropBuildingSurface
---@field IsOnBuilding fun(self: PropBuildingSurface, x: number, y: number): boolean

---@class WarehousePropStock
---@field rack integer
---@field fence integer
---@field security_window integer

---@class PropInventory
---@field rack integer 尚未布置的教程晾衣架数量（0或1）
---@field tutorialGranted boolean 第二关教程已发放，不因删除或重试补发
---@field security integer 尚未布置的第四关教程防盗窗数量（0或1），与 rack 独立。
---@field securityGranted boolean 第四关建设后已发放，不因删除或重试补发。
---@field warehouseStock WarehousePropStock 独立掉落池；旧教程实体绝不清空此池。

---@class PropGame
---@field config table
---@field scene Scene
---@field width number
---@field height number
---@field groundY number
---@field nextId integer
---@field paused boolean?
---@field balls PropBall[]
---@field drag PropDrag
---@field buildingGrid BuildingGrid?
---@field view VerticalView?
---@field fenceLength number
---@field fenceThickness number
---@field windows {warehouse: boolean?}[]
---@field GetWindowKey fun(self: PropGame, index: integer): string?
---@field GetWindowRect fun(self: PropGame, index: integer): number, number, number, number
---@field GetBuildingRect fun(self: PropGame): number, number, number, number
---@field CanPlace fun(self: PropGame, x: number, y: number, angle: number): boolean
---@field CreateFence fun(self: PropGame, x: number, y: number, angle: number): WorkshopFence?
---@field BeginDrag fun(self: PropGame, pointerId: number, x: number, y: number, angle: number, fenceId: number?)
---@field MoveDrag fun(self: PropGame, pointerId: number, x: number, y: number)
---@field EndDrag fun(self: PropGame, pointerId: number, overTray: boolean?)
---@field CancelDrag fun(self: PropGame)

---@class PlaceableProp
---@field id integer
---@field kind string
---@field x number 横梁中心 x
---@field y number 横梁中心 y（不是图片左上角）
---@field width number
---@field height number 自横梁到床单下缘
---@field node Node?
---@field body RigidBody2D?
---@field shape CollisionBox2D?
---@field source string? tutorial / warehouse；旧 rack 无 source 按教程、旧防盗窗按仓库恢复。
---@field windowKey string? 防盗窗稳定宿主键，不保存可变窗口索引。
---@field dragging boolean
---@field deleted boolean
local PlaceableProp = {}
PlaceableProp.__index = PlaceableProp

function PlaceableProp:init(id, kind, x, y, width, height)
    self.id, self.kind = id, kind
    self.x, self.y, self.width, self.height = x, y, width, height
    ---@type Node?
    self.node = nil
    self.dragging, self.deleted = false, false
end

---@class ClothesRack : PlaceableProp
---@field node Node?
---@field body RigidBody2D?
---@field shape CollisionBox2D?
---@field collisionWidth number
---@field collisionHeight number
local ClothesRack = setmetatable({}, { __index = PlaceableProp })
ClothesRack.__index = ClothesRack

---@param system PropSystem
---@return ClothesRack
function ClothesRack.New(system, id, x, y)
    local self = setmetatable({}, ClothesRack)
    self:init(id, x, y, system.rackWidth, system.rackCollisionWidth)
    self:CreateNode(system.game.scene)
    return self
end

function ClothesRack:init(id, x, y, width, collisionWidth)
    PlaceableProp.init(self, id, "rack", x, y, width, width * 0.85)
    self.collisionWidth, self.collisionHeight = collisionWidth, 0.10
    ---@type RigidBody2D?
    self.body = nil
    ---@type CollisionBox2D?
    self.shape = nil
end

---@class SecurityWindow : PlaceableProp
---@field windowKey string
local SecurityWindow = setmetatable({}, { __index = PlaceableProp })
SecurityWindow.__index = SecurityWindow

---@param system PropSystem
---@param id integer
---@param windowKey string
---@param index integer
---@return SecurityWindow
function SecurityWindow.New(system, id, windowKey, index)
    local prop = setmetatable({}, SecurityWindow)
    local x, y, w, h = system.game:GetWindowRect(index)
    prop:init(id, windowKey, x + w / 2, y + h / 2, w, h)
    return prop
end

function SecurityWindow:init(id, windowKey, x, y, width, height)
    PlaceableProp.init(self, id, "security_window", x, y, width, height)
    self.windowKey, self.source = windowKey, "warehouse"
    -- 防盗窗是窗洞的安装状态，不造 fence、刚体或新的触发器。
end

---@class PropDefinition
---@field kind string
---@field title string
---@field toolbar boolean
---@field width number
---@field height number
---@field Create fun(system: PropSystem, x: number, y: number, angle: number?): ClothesRack|SecurityWindow|WorkshopFence|nil

---@class PropPosition
---@field kind string
---@field x number? rack 世界位置。
---@field y number?
---@field source string? rack 的 warehouse 来源；security_window 显式保存 tutorial / warehouse。
---@field windowKey string? security_window 的唯一持久定位字段。

---@class SecurityWindowRect
---@field x number 左上角世界坐标（米、画面 y 向下）。
---@field y number
---@field w number 完整真实窗洞宽度，不含额外扫掠 padding。
---@field h number
---@field windowKey string
---@field index integer 当前宿主窗索引，扫描结果不可用于持久化。
---@field propId integer

---@class PropBallSample
---@field x number
---@field y number

---@class PropSystem
---@field game PropGame
---@field drag PropDrag
---@field definitions table<string, PropDefinition>
---@field props (ClothesRack|SecurityWindow)[]
---@field byId table<number, ClothesRack|SecurityWindow>
---@field byNode table<number, ClothesRack>
---@field byWindow table<string, SecurityWindow>
---@field pendingNodes Node[]
---@field samples table<number, PropBallSample>
---@field rackWidth number
---@field rackHeight number
---@field rackCollisionWidth number
---@field windowCount integer
---@field selectedId number
---@field inventory PropInventory
local PropSystem = {}
PropSystem.__index = PropSystem

local FRAME_RATIO = 264 / 595 -- 保留原安装/拾取边界，不改变道具物理尺寸。
local RACK_IMAGE_RATIO = 684 / 902 -- 完整挂被切图，包含横杠和被子。
local RACK_BAR_Y = 62 / 902 -- 切图横杠中心距顶边的比例，绘制时对齐安装点 y。
local SHEET_RATIO = 0.85
local FALL_GRAVITY = 0.08
local FALL_SPEED = 1.15
local EPSILON = 0.000001
local STOCK_LIMIT = 4096 -- 与LevelSave仓库池上限一致，合法发放必须能持久化。
local WAREHOUSE_KINDS = { rack = true, fence = true, security_window = true }

local function Finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function StockCount(value)
    return Finite(value) and value >= 0 and value <= STOCK_LIMIT and value % 1 == 0
end

---@return PropInventory
local function EmptyInventory()
    return { rack = 0, tutorialGranted = false, security = 0, securityGranted = false,
        warehouseStock = { rack = 0, fence = 0, security_window = 0 } }
end

---@param game PropGame
---@return PropSystem
function PropSystem.New(game)
    local self = setmetatable({}, PropSystem)
    self:init(game)
    return self
end

---@param game PropGame
function PropSystem:init(game)
    self.game, self.drag = game, game.drag -- 必须保留主游戏的同一张拖拽表。
    self.drag.kind = self.drag.kind or "fence"
    self.drag.propId = self.drag.propId or 0
    self.drag.originalEnabled = true
    self.drag.windowKey, self.drag.originalWindowKey = "", ""
    self.drag.rawX, self.drag.rawY = 0, 0
    local _, _, windowWidth, windowHeight = game:GetWindowRect(1)
    self.rackWidth, self.rackHeight = windowWidth * 2.6, windowWidth * 2.6 * SHEET_RATIO
    self.rackCollisionWidth, self.windowCount = self.rackWidth * 0.85 * 0.90, -1
    self.props, self.byId, self.byNode, self.byWindow = {}, {}, {}, {}
    self.pendingNodes, self.samples = {}, {}
    self.selectedId = 0
    self.inventory = EmptyInventory()
    self:RefreshRackCollision()
    self.definitions = {
        fence = {
            kind = "fence", title = "栅栏", toolbar = true,
            width = game.fenceLength, height = game.fenceThickness,
            Create = function(system, x, y, angle)
                return system.game:CreateFence(x, y, angle or 0)
            end,
        },
        rack = {
            kind = "rack", title = "晾衣架", toolbar = true,
            width = self.rackWidth, height = self.rackHeight,
            Create = function(system, x, y)
                return system:CreateRack(x, y)
            end,
        },
        security_window = {
            kind = "security_window", title = "防盗窗", toolbar = true,
            width = windowWidth, height = windowHeight,
            Create = function(system, x, y)
                local key = system:SnapWindow(x, y)
                return key and system:CreateSecurityWindow(key) or nil
            end,
        },
    }
    print(string.format("[道具] 晾衣架宽 %.3f 米，含床单高度 %.3f 米；教程与仓库库存独立初始化", self.rackWidth, self.rackHeight))
end

--- 物理 trigger 仅提供候选；真实伞激活还要求猫中心在水平带内，不扩张 radius。
--- 同排窗中心间距 d，有效带 W<=min(旧W*0.90,d-0.02)，故两列中心不能同时入带。
---              x-W/2 [──── 有效中心带 W ────] x+W/2
---                    ○↓                  ○↓   圆的外缘接触只是候选
---                  窗中心1 <──── d ────> 窗中心2
--- 窗 y 略错位（原图 1~2px）仍视同排；上下窗/仓库窗不参与水平邻距。
function PropSystem:RefreshRackCollision()
    local windows = self.game.windows or {}
    if self.windowCount == #windows then return end
    local distance = math.huge
    for i, window in ipairs(windows) do
        if window.warehouse ~= true then
            local x, y, w, h = self.game:GetWindowRect(i)
            for j = i + 1, #windows do
                if windows[j].warehouse ~= true then
                    local ox, oy, ow, oh = self.game:GetWindowRect(j)
                    local dx = math.abs(x + w / 2 - ox - ow / 2)
                    if dx > EPSILON and math.abs(y + h / 2 - oy - oh / 2) <= math.min(h, oh) * 0.25 then
                        distance = math.min(distance, dx)
                    end
                end
            end
        end
    end
    local original = self.rackWidth * 0.85
    self.rackCollisionWidth = math.max(0.001, math.min(original * 0.90, distance - 0.02))
    self.windowCount = #windows
    for _, prop in ipairs(self.props) do
        if prop.kind == "rack" then
            local rack = prop --[[@as ClothesRack]]
            rack.collisionWidth = self.rackCollisionWidth
            if rack.shape then rack.shape:SetSize(rack.collisionWidth, rack.collisionHeight) end
        end
    end
    print(string.format("[道具碰撞] 原横带 %.6f → %.6f 米；同排最小中心距 %.6f，中心带不扩张猫半径", original,
        self.rackCollisionWidth, distance))
end

---@param kind string
---@return integer
function PropSystem:Stock(kind)
    if not WAREHOUSE_KINDS[kind] then return 0 end
    local tutorial = 0
    if kind == "rack" and self.game.config.number ~= 1 and self.inventory.tutorialGranted then
        tutorial = self.inventory.rack
    elseif kind == "security_window" and self.game.config.number >= 4 and self.inventory.securityGranted then
        tutorial = self.inventory.security
    end
    local warehouse = self.game.config.number >= 5 and self.inventory.warehouseStock[kind] or 0
    return math.floor(tutorial + warehouse)
end

---@return boolean
function PropSystem:HasStock(kind)
    return self:Stock(kind) > 0
end

--- 仓库实际掉落的唯一发放接口；不在控制台构建、重试、加载时补发。
---@param kind string
---@param amount number?
---@return boolean
function PropSystem:GrantWarehouse(kind, amount)
    if amount == nil then amount = 1 end
    if self.game.config.number < 5 or not WAREHOUSE_KINDS[kind] or not StockCount(amount) or amount < 1 then
        print("[仓库库存] 拒绝发放：关卡/种类/数量不合法")
        return false
    end
    local stock = self.inventory.warehouseStock
    if stock[kind] > STOCK_LIMIT - amount then return false end
    stock[kind] = math.floor(stock[kind] + amount)
    print(string.format("[仓库库存] 获得 %s ×%d，掉落池剩余 %d", kind, amount, stock[kind]))
    return true
end

--- 仅成功的新放置消费；搬动/删除/取消/恢复不调用。rack / security 优先用各自教程配额。
---@param kind string
---@param amount number?
---@return boolean consumed
---@return string? source tutorial / warehouse（混合批量消费返回 mixed）；实体放置固定消费1。
function PropSystem:ConsumeStock(kind, amount)
    if amount == nil then amount = 1 end
    if not StockCount(amount) or amount < 1 or self:Stock(kind) < amount then return false, nil end
    local tutorial = 0
    if kind == "rack" and self.game.config.number ~= 1 and self.inventory.tutorialGranted then
        tutorial = self.inventory.rack
    elseif kind == "security_window" and self.game.config.number >= 4 and self.inventory.securityGranted then
        tutorial = self.inventory.security
    end
    local fromTutorial = math.min(tutorial, amount)
    local fromWarehouse = amount - fromTutorial
    if kind == "rack" then self.inventory.rack = math.floor(self.inventory.rack - fromTutorial)
    elseif kind == "security_window" then self.inventory.security = math.floor(self.inventory.security - fromTutorial) end
    if fromWarehouse > 0 then
        local stock = self.inventory.warehouseStock
        stock[kind] = math.floor(stock[kind] - fromWarehouse)
    end
    local source = fromTutorial == amount and "tutorial" or (fromTutorial == 0 and "warehouse" or "mixed")
    print(string.format("[道具库存] 使用 %s ×%d，来源 %s，可用剩余 %d", kind, amount, source, self:Stock(kind)))
    return true, source
end

--- 唯一发放事件：第二关开场教程；同局重试不会重置发放记录。
---@return boolean
function PropSystem:GrantTutorial()
    if self.game.config.number ~= 2 or self.inventory.tutorialGranted then return false end
    self.inventory.tutorialGranted, self.inventory.rack = true, 1
    print("[道具] 第二关开场教程发放 1 件晾衣架，后续关卡不补发")
    return true
end

--- 由宿主第四关完成建设后调用；与 L2 晾衣架事件完全独立，同局重试/删除不补发。
---@return boolean
function PropSystem:GrantSecurityTutorial()
    if self.game.config.number ~= 4 or self.inventory.securityGranted then return false end
    self.inventory.securityGranted, self.inventory.security = true, 1
    print("[道具] 第四关建设后发放 1 件防盗窗，后续关卡不补发")
    return true
end

---@return PropInventory
function PropSystem:ExportInventory()
    local stock = self.inventory.warehouseStock
    return { rack = self.inventory.rack, tutorialGranted = self.inventory.tutorialGranted,
        security = self.inventory.security, securityGranted = self.inventory.securityGranted,
        warehouseStock = { rack = stock.rack, fence = stock.fence, security_window = stock.security_window } }
end

---@param inventory PropInventory?
function PropSystem:RestoreInventory(inventory)
    self.inventory = EmptyInventory()
    if type(inventory) == "table" then
        if type(inventory.tutorialGranted) == "boolean" and (inventory.rack == 0 or inventory.rack == 1) then
            self.inventory.tutorialGranted = inventory.tutorialGranted
            self.inventory.rack = inventory.tutorialGranted and math.floor(inventory.rack) or 0
        end
        if self.game.config.number >= 4 and type(inventory.securityGranted) == "boolean"
            and (inventory.security == 0 or inventory.security == 1) then
            self.inventory.securityGranted = inventory.securityGranted
            self.inventory.security = inventory.securityGranted and math.floor(inventory.security) or 0
        end
        local stock = inventory.warehouseStock
        if self.game.config.number >= 5 and type(stock) == "table" then
            for kind in pairs(WAREHOUSE_KINDS) do
                if StockCount(stock[kind]) then self.inventory.warehouseStock[kind] = math.floor(stock[kind]) end
            end
        end
    end
    for _, prop in ipairs(self.props) do
        if prop.kind == "rack" and prop.source ~= "warehouse" then
            self.inventory.tutorialGranted, self.inventory.rack = true, 0
        elseif prop.kind == "security_window" and prop.source == "tutorial" then
            self.inventory.securityGranted, self.inventory.security = true, 0
        end -- 两个教程池独立归一化，绝不清 warehouseStock；不能提前 break 漏掉另一种实体。
    end
    print(string.format("[道具] 恢复教程 rack=%d/已发放 %s，security=%d/已发放 %s；仓库 rack=%d fence=%d security_window=%d",
        self.inventory.rack, tostring(self.inventory.tutorialGranted), self.inventory.security,
        tostring(self.inventory.securityGranted), self.inventory.warehouseStock.rack,
        self.inventory.warehouseStock.fence, self.inventory.warehouseStock.security_window))
end

--- 额外工厂入口；栅栏仍归 Game 管理，由宿主负责新建消费/内部恢复区分。
---@return ClothesRack|SecurityWindow|WorkshopFence|nil
function PropSystem:Create(kind, x, y, angle)
    local definition = self.definitions[kind]
    if not definition or not self:CanPlace(kind, x, y, angle) then return nil end
    return definition.Create(self, x, y, angle)
end

--- 恢复实体只使用本文件内的工厂，不经过库存消费或教程发放。
---@param system PropSystem
---@return ClothesRack
local function SpawnRack(system, x, y, source)
    system:RefreshRackCollision()
    local id = system.game.nextId
    system.game.nextId = id + 1
    local rack = ClothesRack.New(system, id, x, y)
    rack.source = source or "tutorial"
    system.props[#system.props + 1] = rack
    system.byId[id] = rack
    if rack.node then system.byNode[rack.node.ID] = rack end
    system.selectedId = id
    print(string.format("[道具] 放置晾衣架 #%d，横梁中心 %.3f, %.3f，来源 %s", id, x, y, rack.source))
    return rack
end

---@return ClothesRack?
function PropSystem:CreateRack(x, y)
    if not self:HasStock("rack") or not self:CanPlace("rack", x, y) then return nil end
    local rack = SpawnRack(self, x, y)
    local consumed, source = self:ConsumeStock("rack") -- 只有创建成功才扣1，搬动不走这里。
    if not consumed then self:Delete(rack.id); return nil end
    rack.source = source
    return rack
end

-- 防盗窗吸附设计（米，y↓）：安装/拾取/绘制共用宿主 window rect。
--          margin  ┌────── w ──────┐ margin
--                  │ 窗洞窗栅      │ h     指针在窗洞或小外沿才吸附
--                  └──────────────┘       窗隙中点/远离窗洞不自动找全楼最近窗
-- warehouse=true 永远排除；已占窗可以显示红色预览，但不可重复安装。
-- 拖旧窗：byWindow[旧key]保持保护和唯一占位；只有commit才旧key→新key，取消原窗不变。
-- 不修改game.windows，不排除猫刷新；ReleaseWave查询IsProtected才阻止下落。
---@param index integer
---@return string?
function PropSystem:WindowKey(index)
    if not self.game.GetWindowKey then return nil end
    local key = self.game:GetWindowKey(index)
    return type(key) == "string" and key ~= "" and key or nil
end

--- 与宿主GetWindowKey命名一致；保留WindowKey旧接口供现有调用方使用。
---@param index integer
---@return string?
function PropSystem:GetWindowKey(index)
    return self:WindowKey(index)
end

---@param key string?
---@return integer?
function PropSystem:FindWindow(key)
    if type(key) ~= "string" or key == "" then return nil end
    ---@type integer?
    local found = nil
    for index in ipairs(self.game.windows or {}) do
        if self:WindowKey(index) == key then
            if found then return nil end -- 稳定键必须唯一，重复键不猜测归属。
            found = index
        end
    end
    return found
end

---@param key string?
---@param ignoreId number?
---@return boolean
function PropSystem:CanInstallWindow(key, ignoreId)
    if self.game.config.number < 4 then return false end
    local index = self:FindWindow(key)
    local window = index and self.game.windows[index] or nil
    if not index or not window or window.warehouse == true then return false end
    local x, y, w, h = self.game:GetWindowRect(index)
    if not Finite(x) or not Finite(y) or not Finite(w) or not Finite(h) or w <= 0 or h <= 0 then return false end
    local occupied = self.byWindow[key]
    return not occupied or occupied.deleted or occupied.id == ignoreId
end

---@param x number
---@param y number
---@return string? windowKey
---@return integer? index
function PropSystem:SnapWindow(x, y)
    if not Finite(x) or not Finite(y) then return nil, nil end
    ---@type string?
    local bestKey = nil
    ---@type integer?
    local bestIndex = nil
    local bestDistance = math.huge
    for index, window in ipairs(self.game.windows or {}) do
        if window.warehouse ~= true then
            local key = self:WindowKey(index)
            local wx, wy, w, h = self.game:GetWindowRect(index)
            if key and Finite(wx) and Finite(wy) and Finite(w) and Finite(h) and w > 0 and h > 0 then
                local margin = math.min(w, h) * 0.30
                if x >= wx - margin and x <= wx + w + margin and y >= wy - margin and y <= wy + h + margin then
                    local distance = ((x - wx - w / 2) / w) ^ 2 + ((y - wy - h / 2) / h) ^ 2
                    if distance < bestDistance then bestKey, bestIndex, bestDistance = key, index, distance end
                end
            end
        end
    end
    return bestKey, bestIndex
end

---@param index integer
---@return boolean
function PropSystem:IsProtected(index)
    local windows = self.game.windows or {}
    if not windows[index] or windows[index].warehouse == true then return false end
    local key = self:WindowKey(index)
    local prop = key and self.byWindow[key] or nil
    return prop ~= nil and not prop.deleted -- dragging仍保留原窗的保护。
end

--- 完整已安装真实窗矩形，供宿主连续扫掠；不留猫、不计数，不返回 ghost。
--- dragging 保留原 windowKey，所以旧保护在提交之前一直有效。
---@return SecurityWindowRect[]
function PropSystem:GetSecurityRects()
    ---@type SecurityWindowRect[]
    local result = {}
    for index in ipairs(self.game.windows or {}) do
        if self:IsProtected(index) then
            local key = self:WindowKey(index)
            local prop = key and self.byWindow[key] or nil
            local x, y, w, h = self.game:GetWindowRect(index)
            if key and prop and Finite(x) and Finite(y) and Finite(w) and Finite(h) and w > 0 and h > 0 then
                result[#result + 1] = { x = x, y = y, w = w, h = h,
                    windowKey = key, index = index, propId = prop.id }
            end
        end
    end
    return result
end

---@param system PropSystem
---@param key string
---@param index integer
---@param source string?
---@return SecurityWindow
local function SpawnSecurity(system, key, index, source)
    local id = system.game.nextId
    system.game.nextId = id + 1
    local prop = SecurityWindow.New(system, id, key, index)
    prop.source = source or "warehouse" -- 旧防盗窗无 source 保持仓库语义，不冒领 L4 教程配额。
    system.props[#system.props + 1] = prop
    system.byId[id], system.byWindow[key], system.selectedId = prop, prop, id
    print(string.format("[防盗窗] 安装 #%d，windowKey=%s，来源 %s（不改变猫刷新）", id, key, prop.source))
    return prop
end

---@param key string
---@return SecurityWindow?
function PropSystem:CreateSecurityWindow(key)
    if not self:HasStock("security_window") or not self:CanInstallWindow(key) then return nil end
    local index = self:FindWindow(key)
    if not index then return nil end
    local prop = SpawnSecurity(self, key, index)
    local consumed, source = self:ConsumeStock("security_window")
    if not consumed then self:Delete(prop.id); return nil end
    prop.source = source
    return prop
end

-- ==================== 二、自由放置与拖拽 ====================
-- frame 上缘 y - width×0.23，床单下缘 y + height；与 DrawRack/拾取使用同一边界。
-- 楼房条件只检查横梁中心是否在楼房上，不做格子取整，也不要求两侧挂点落在格线上。
function PropSystem:CanPlace(kind, x, y, angle)
    if not Finite(x) or not Finite(y) then return false end
    if kind == "fence" then
        if angle ~= nil and not Finite(angle) then return false end
        return self.game:CanPlace(x, y, angle or 0)
    end
    if kind == "security_window" then
        local key = self:SnapWindow(x, y)
        return key ~= nil and self:CanInstallWindow(key,
            self.drag.active and self.drag.kind == kind and self.drag.propId or nil)
    end
    if kind ~= "rack" then return false end
    local half = self.rackWidth / 2
    local above = math.max(self.rackWidth * FRAME_RATIO / 2, 0.05)
    local top = self.game.view and self.game.view.minWorldY or 0
    if x - half < 0 or x + half > self.game.width or y - above < top
        or y + self.rackHeight > self.game.height or y + self.rackHeight >= self.game.groundY then
        return false
    end
    local building = self.game.buildingGrid
    if building then return building:IsOnBuilding(x, y) end
    -- 独立模块可先于 BuildingGrid 接入；旧 Game 的矩形楼房保持等价中心判定。
    local bx, by, bw, bh = self.game:GetBuildingRect()
    return x >= bx and x <= bx + bw and y >= by and y <= by + bh
end

---@return ClothesRack|SecurityWindow|nil
function PropSystem:Find(id)
    return self.byId[id]
end

---@param prop SecurityWindow
---@return boolean
function PropSystem:SyncSecurityWindow(prop)
    local index = self:FindWindow(prop.windowKey)
    local window = index and self.game.windows[index] or nil
    if not index or not window or window.warehouse == true then return false end
    local x, y, w, h = self.game:GetWindowRect(index)
    prop.x, prop.y, prop.width, prop.height = x + w / 2, y + h / 2, w, h
    return true
end

--- 返回真实对象kind，宿主BeginDrag必须传prop.kind，不能硬编码rack。
---@return ClothesRack|SecurityWindow|nil
function PropSystem:Pick(x, y)
    if not Finite(x) or not Finite(y) then return nil end
    for i = #self.props, 1, -1 do
        local prop = self.props[i]
        if not prop.deleted and not prop.dragging then
            if prop.kind == "security_window" then
                if self:SyncSecurityWindow(prop --[[@as SecurityWindow]]) and x >= prop.x - prop.width / 2
                    and x <= prop.x + prop.width / 2 and y >= prop.y - prop.height / 2 and y <= prop.y + prop.height / 2 then
                    return prop
                end
            elseif x >= prop.x - prop.width / 2 and x <= prop.x + prop.width / 2
                and y >= prop.y - prop.width * FRAME_RATIO / 2 and y <= prop.y + prop.height then
                return prop
            end
        end
    end
    return nil
end

function PropSystem:RefreshDragPreview()
    local drag = self.drag
    if not drag.active then return end
    if drag.kind == "rack" then
        drag.valid = self:CanPlace("rack", drag.x, drag.y)
    elseif drag.kind == "security_window" then
        local key, index = self:SnapWindow(drag.rawX, drag.rawY)
        drag.windowKey, drag.x, drag.y = key or "", drag.rawX, drag.rawY
        if index then
            local x, y, w, h = self.game:GetWindowRect(index)
            drag.x, drag.y = x + w / 2, y + h / 2
        end
        drag.valid = key ~= nil and self:CanInstallWindow(key, drag.propId)
    end
end

---@return boolean
function PropSystem:BeginDrag(pointerId, x, y, kind, id)
    local drag = self.drag
    if drag.active or not Finite(pointerId) or not Finite(x) or not Finite(y) then return false end
    -- 已提交/存档恢复的道具固定位置；只有工具槽的 id=0 新预览能开始拖拽。
    if id ~= nil and id ~= 0 then return false end
    kind = kind or "rack"
    if kind == "fence" then
        drag.kind, drag.propId = "fence", 0
        self.game:BeginDrag(pointerId, x, y, drag.angle or 0, id or 0)
        return drag.active
    end
    if kind ~= "rack" and kind ~= "security_window" then return false end
    local propId = id or 0
    local prop = self:Find(propId)
    if not self:HasStock(kind) then return false end
    if prop and kind == "security_window" and not self:SyncSecurityWindow(prop --[[@as SecurityWindow]]) then return false end
    drag.active, drag.pointerId, drag.kind = true, pointerId, kind
    drag.propId, drag.fenceId, drag.angle = propId, 0, 0 -- 不隐藏/误选旧栅栏的同ID。
    drag.x, drag.y, drag.offsetX, drag.offsetY = x, y, 0, 0
    drag.originalX, drag.originalY, drag.originalAngle, drag.originalEnabled = x, y, 0, true
    drag.windowKey, drag.originalWindowKey = "", prop and prop.windowKey or ""
    if prop then
        drag.originalX, drag.originalY = prop.x, prop.y
        drag.offsetX, drag.offsetY = prop.x - x, prop.y - y
        drag.x, drag.y = prop.x, prop.y
        if prop.node then
            drag.originalEnabled = prop.node.enabled
            prop.node.enabled = false -- rack拖动不接猫；窗byWindow原key不变。
        end
        prop.dragging, self.selectedId = true, prop.id
    end
    drag.rawX, drag.rawY = drag.x, drag.y
    self:RefreshDragPreview()
    print(string.format("[道具拖拽] 开始 %s #%d，原窗=%s（旧保护直到提交）", kind, propId, drag.originalWindowKey))
    return true
end

function PropSystem:MoveDrag(pointerId, x, y)
    local drag = self.drag
    if not drag.active or pointerId ~= drag.pointerId then return end
    if drag.kind == "fence" then self.game:MoveDrag(pointerId, x, y); return end
    if not Finite(x) or not Finite(y) then
        drag.valid = false
        drag.rawX, drag.rawY, drag.x, drag.y = x, y, x, y
        return
    end
    drag.rawX, drag.rawY = x + drag.offsetX, y + drag.offsetY
    drag.x, drag.y = drag.rawX, drag.rawY
    self:RefreshDragPreview()
end

--- 仅合法rack/防盗窗提交返回实体；错误指针/非法/取消/收回返回nil。
---@return ClothesRack|SecurityWindow|nil
function PropSystem:EndDrag(pointerId, overTray)
    local drag = self.drag
    if not drag.active or pointerId ~= drag.pointerId then return nil end
    if drag.kind == "fence" then self.game:EndDrag(pointerId, overTray); return nil end
    local prop = self:Find(drag.propId)
    if overTray then
        if prop then self:Delete(prop.id) end
        print("[道具拖拽] 返回工具槽：新预览取消/旧实体删除，库存不返还")
        self:FinishDrag()
        return nil
    end
    self:RefreshDragPreview() -- 松手当帧重验唯一占位、warehouse排除及窗key。
    if not drag.valid then
        self:RestoreDraggedProp(prop)
        print("[道具拖拽] 非法落位，恢复旧实体/旧窗保护，未消费库存")
        self:FinishDrag()
        return nil
    end
    if prop then
        if prop.kind == "security_window" then
            if prop.windowKey and self.byWindow[prop.windowKey] == prop then self.byWindow[prop.windowKey] = nil end
            prop.windowKey = drag.windowKey
            self.byWindow[drag.windowKey] = prop --[[@as SecurityWindow]]
            self:SyncSecurityWindow(prop --[[@as SecurityWindow]])
            print(string.format("[防盗窗] 提交搬动 #%d：%s → %s，不扣库存", prop.id, drag.originalWindowKey, drag.windowKey))
        else
            prop.x, prop.y = drag.x, drag.y
            if prop.node then
                prop.node:SetPosition2D(prop.x, -prop.y)
                prop.node.enabled = drag.originalEnabled
            end
        end
        prop.dragging = false
    elseif drag.propId == 0 then
        if drag.kind == "security_window" then prop = self:CreateSecurityWindow(drag.windowKey)
        else prop = self:CreateRack(drag.x, drag.y) end
    end
    self:FinishDrag()
    return prop
end

---@param prop ClothesRack|SecurityWindow|nil
function PropSystem:RestoreDraggedProp(prop)
    if not prop then return end
    prop.x, prop.y, prop.dragging = self.drag.originalX, self.drag.originalY, false
    if prop.node then
        prop.node:SetPosition2D(prop.x, -prop.y)
        prop.node.enabled = self.drag.originalEnabled
    end
    -- SecurityWindow原key/占位未被预览改变，取消无需补回保护。
end

---@param rack ClothesRack?
function PropSystem:RestoreDraggedRack(rack)
    self:RestoreDraggedProp(rack) -- 保留旧接口语义。
end

function PropSystem:FinishDrag()
    -- 不替换game.drag；不碰栅栏旋转字段；清掉窗预览key以防后续路由误用。
    self.drag.active, self.drag.valid, self.drag.pointerId = false, false, -1
    self.drag.propId, self.drag.fenceId, self.drag.kind = 0, 0, "fence"
    self.drag.windowKey, self.drag.originalWindowKey = "", ""
end

function PropSystem:CancelDrag()
    if not self.drag.active then return end
    if self.drag.kind == "fence" then self.game:CancelDrag(); return end
    self:RestoreDraggedProp(self:Find(self.drag.propId))
    print("[道具拖拽] 取消：旧实体和原窗保护不变，未消费库存")
    self:FinishDrag()
end

-- ==================== 三、碰撞设计 ====================
-- 世界坐标（米，图中 y↓），rack 的 anchor 始终是横梁中心 (x,y)：
--                  猫圆 ○ radius=r（现有猫 r=0.20）
--                         ↓ 只接受下落；上升/等待/终态不触发
--        x-width/2 ┌──── 空架 width×0.46 ────┐ x+width/2
--                  │ ┌──────────────────┐  │
--     y-0.05 ──────┼─┤ trigger 横梁矩形  ├──┤
--       anchor y ──┼─┤ 有效横带 W × 0.10 ├──┤ node=(x,-y)
--     y+0.05 ──────┼─└──────────────────┘──┤ cat=32, mask=8
--     y+width×.08 ─┤    奶白床单（仅绘制）   │ 猫 cat=8，mask 须含 32
--                  │    │   │   │         │
--     y+height ────┴──── 波浪床单下缘 ──────┘ height=width×.85
--                  （整体必须在画幅内，床单底严格位于 groundY 之前）
-- ───────────────────── Ground groundY ─────────────────────
-- 检测目的：圆纵向真正触及横带，且猫中心X在横带内 -> parachute，Update持续限速。
-- 物理圆的外缘擦边只成为候选，不使用 radius 扩张水平有效带，避免两列中心同时触发。
-- 高速：previous/current 连续扫掠，X门控与Y重叠用同一时间片，避免斜飞隔空命中。
-- 首次圆边候选可能未入中心带；Update逐帧复查/扫掠，后续进入仍正常开伞。
-- 上升：velocity.y>=0 不触发；首次上升重叠后转下落，Update重叠检查仍能触发。
-- 同帧草地：Ground/终态优先；圆底已到 groundY 时不新开伞，不撤销 missed/safe。
-- 物理回调中只写 ball.parachute=true；不创建/删除节点、不改速度/重力/碰撞材质。

---@param scene Scene
function ClothesRack:CreateNode(scene)
    local node = scene:CreateChild("ClothesRack")
    node:SetPosition2D(self.x, -self.y)
    local body = node:CreateComponent("RigidBody2D")
    body.bodyType = BT_STATIC
    local shape = node:CreateComponent("CollisionBox2D")
    shape:SetSize(self.collisionWidth, self.collisionHeight)
    shape.trigger, shape.categoryBits, shape.maskBits = true, 32, 8
    shape.friction, shape.restitution = 0, 0
    self.node, self.body, self.shape = node, body, shape
end

local function CircleTouchesBox(x, y, radius, rack)
    local dx = math.max(0, math.abs(x - rack.x) - rack.collisionWidth / 2)
    local dy = math.max(0, math.abs(y - rack.y) - rack.collisionHeight / 2)
    return dx * dx + dy * dy <= radius * radius + EPSILON * EPSILON
end

local function SegmentTouchesBox(x0, y0, x1, y1, left, top, right, bottom)
    ---@type number, number
    local enter, leave = 0, 1
    local dx, dy = x1 - x0, y1 - y0
    if math.abs(dx) < EPSILON then
        if x0 < left or x0 > right then return false end
    else
        local a, b = (left - x0) / dx, (right - x0) / dx
        enter, leave = math.max(enter, math.min(a, b)), math.min(leave, math.max(a, b))
    end
    if math.abs(dy) < EPSILON then
        if y0 < top or y0 > bottom then return false end
    else
        local a, b = (top - y0) / dy, (bottom - y0) / dy
        enter, leave = math.max(enter, math.min(a, b)), math.min(leave, math.max(a, b))
    end
    return enter <= leave
end

---@param rack ClothesRack
local function SweepTouchesRack(x0, y0, x1, y1, radius, rack)
    -- 中心必须进横带；只在Y方向扩张猫半径。线段进/出时间同时约束X和Y。
    return SegmentTouchesBox(x0, y0, x1, y1, rack.x - rack.collisionWidth / 2,
        rack.y - rack.collisionHeight / 2 - radius, rack.x + rack.collisionWidth / 2,
        rack.y + rack.collisionHeight / 2 + radius)
end

---@param ball PropBall
local function Flying(ball)
    return not ball.waiting and not ball.missed and not ball.caught and not ball.safe and not ball.trapped
        and not ball.rolling and ball.node ~= nil and ball.body ~= nil
end

---@param ball PropBall
function PropSystem:CanOpenParachute(ball)
    if ball.magnetic and not ball.magneticTouchedCat then return false end
    if not Flying(ball) or ball.parachute or ball.body.linearVelocity.y >= 0 then return false end
    return -ball.node.position2D.y + ball.radius < self.game.groundY - EPSILON
end

--- 返回 true 仅表示此接触首次标记了降落伞；Ground 计数/回收全部交给 Game。
---@param ball PropBall?
---@param nodeA Node?
---@param nodeB Node?
---@return boolean
function PropSystem:Contact(ball, nodeA, nodeB)
    if not ball or not nodeA or not nodeB or not self:CanOpenParachute(ball) then return false end
    ---@type Node?
    local other = nil
    if nodeA.ID == ball.node.ID then other = nodeB
    elseif nodeB.ID == ball.node.ID then other = nodeA
    else return false end
    local rack = self.byNode[other.ID]
    if not rack or rack.deleted or rack.dragging or not rack.node or not rack.node.enabled then return false end
    local position = ball.node.position2D
    if math.abs(position.x - rack.x) > rack.collisionWidth / 2
        or not CircleTouchesBox(position.x, -position.y, ball.radius, rack) then return false end
    ball.parachute = true -- 唯一状态写入；回调中绝不写body/shape。
    print(string.format("[道具碰撞] 猫 #%d 中心进晾衣架 #%d 有效横带，展开降落伞", ball.id, rack.id))
    return true
end

-- ==================== 四、降落伞 ====================
function PropSystem:Update(dt)
    -- 删除队列即使暂停也要排空；编辑 API 不在 Contact 里调用。
    self:FlushDeletedNodes()
    self:RefreshRackCollision()
    self:RefreshDragPreview()
    if self.game.paused or not Finite(dt) or dt < 0 then return end
    ---@type table<number, PropBallSample>
    local samples = {}
    for _, ball in ipairs(self.game.balls) do
        if Flying(ball) then
            local position = ball.node.position2D
            local x, y = position.x, -position.y
            local previous = self.samples[ball.node.ID]
            local previousX = previous and previous.x or x
            local previousY = previous and previous.y or (Finite(ball.previousY) and ball.previousY or y)
            -- 不覆盖主游戏 previousY；本地采样也能防主游戏提前写回时丢失扫掠。
            if self:CanOpenParachute(ball) and y >= previousY then
                for _, prop in ipairs(self.props) do
                    local rack = prop --[[@as ClothesRack]]
                    if prop.kind == "rack" and not rack.deleted and not rack.dragging and rack.node and rack.node.enabled
                        and SweepTouchesRack(previousX, previousY, x, y, ball.radius, rack) then
                        ball.parachute = true
                        print(string.format("[道具] 猫 #%d 获得床单降落伞（晾衣架 #%d）", ball.id, rack.id))
                        break
                    end
                end
            end
            if ball.parachute then
                -- 只改物理参数，保留水平速度、猫咪半径和节点尺寸；触发器不会挡住猫。
                ball.parachuteWidth = self.rackWidth
                ball.body.gravityScale = FALL_GRAVITY
                local velocity = ball.body.linearVelocity
                ball.body.linearVelocity = Vector2(velocity.x, math.max(-FALL_SPEED, velocity.y))
                ball.shape.restitution = 0
                ball.body.awake = true
            end
            samples[ball.node.ID] = { x = x, y = y }
        end
    end
    self.samples = samples -- 已回收/终态猫不保留引用或采样，重开 ID 可安全复用。
end

--- 在主 Art.Ball 之后调用，vg 已处于场地坐标，unit 为 UI 基准像素/米。
---@param vg NVGContextWrapper
---@param ball PropBall
---@param unit number
function PropSystem.RenderParachute(vg, ball, unit)
    if not ball.parachute or not Flying(ball) or unit <= 0 then return end
    local position = ball.node.position2D
    local x, y, r = position.x * unit, -position.y * unit, ball.radius * unit
    local width = (ball.parachuteWidth or 0.7) * unit
    local head = y - r * 1.15
    local rim = head - width * 0.34
    local top = rim - width * 0.35
    local half = width / 2
    nvgSave(vg)
    -- 两根细黑绳只系到头顶，不重画/放大猫咪。
    nvgBeginPath(vg)
    nvgMoveTo(vg, x - half * 0.80, rim); nvgLineTo(vg, x - r * 0.28, head)
    nvgMoveTo(vg, x + half * 0.80, rim); nvgLineTo(vg, x + r * 0.28, head)
    nvgStrokeWidth(vg, math.max(0.8, width * 0.014))
    nvgStrokeColor(vg, nvgRGBA(15, 15, 15, 255)); nvgStroke(vg)
    -- 奶白床单撑成波浪伞盖；不依赖任何“伞图”资源。
    nvgBeginPath(vg)
    nvgMoveTo(vg, x - half, rim)
    nvgBezierTo(vg, x - width * 0.43, top, x + width * 0.43, top, x + half, rim)
    for i = 4, 1, -1 do
        local right = x - half + width * i / 4
        local left = right - width / 4
        nvgBezierTo(vg, right - width * 0.06, rim - width * 0.06,
            left + width * 0.06, rim - width * 0.06, left, rim)
    end
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(255, 252, 237, 255)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(12, 12, 12, 255))
    nvgStrokeWidth(vg, math.max(1, width * 0.017)); nvgStroke(vg)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x - width * 0.10, top + width * 0.10)
    nvgBezierTo(vg, x - width * 0.20, top + width * 0.16,
        x - width * 0.24, rim - width * 0.13, x - width * 0.25, rim - width * 0.02)
    nvgMoveTo(vg, x + width * 0.10, top + width * 0.10)
    nvgBezierTo(vg, x + width * 0.20, top + width * 0.16,
        x + width * 0.24, rim - width * 0.13, x + width * 0.25, rim - width * 0.02)
    nvgStrokeWidth(vg, math.max(0.7, width * 0.010))
    nvgStrokeColor(vg, nvgRGBA(30, 30, 27, 155)); nvgStroke(vg)
    nvgRestore(vg)
end

-- ==================== 五、绘制 ====================
-- 所有绘制复用 UI 自定义 Panel 的上下文与缩放。严禁在这里 nvgBeginFrame/nvgCreate。
-- ImageCache 与 Art 无循环依赖，懒加载；每种图片只载入一次，不创建字体或新纹理。
local function RackImage()
    local ImageCache = require("urhox-libs/UI/Core/ImageCache")
    return math.floor(ImageCache.Get("Global/Images/ClothesRack.png"))
end

---@param vg NVGContextWrapper
---@param x number 横梁中心（绘制坐标）
---@param y number 横梁中心（绘制坐标）
---@param width number
---@param height number?
---@param selected boolean?
---@param ghost boolean?
---@param valid boolean?
function PropSystem.DrawRack(vg, x, y, width, height, selected, ghost, valid)
    if width <= 0 then return end
    height = height or width * SHEET_RATIO
    local frameHeight = width * FRAME_RATIO
    nvgSave(vg)
    if ghost then nvgGlobalAlpha(vg, 0.65) end
    if selected or ghost then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x - width / 2, y - frameHeight / 2,
            width, height + frameHeight / 2, width * 0.03)
        local invalid = ghost and not valid
        nvgFillColor(vg, invalid and nvgRGBA(236, 101, 92, 45) or nvgRGBA(74, 191, 152, 40))
        nvgFill(vg)
        nvgStrokeColor(vg, invalid and nvgRGBA(218, 80, 75, 200) or nvgRGBA(45, 157, 120, 200))
        nvgStrokeWidth(vg, math.max(1, width * 0.013)); nvgStroke(vg)
    end
    -- 完整挂被图一次绘制；横杠中心与物理安装点对齐，不再另叠一张悬空被子。
    local image = RackImage()
    if image > 0 then
        local imageTop = y - width * RACK_BAR_Y
        local imageHeight = width * RACK_IMAGE_RATIO
        nvgBeginPath(vg); nvgRect(vg, x - width / 2, imageTop, width, imageHeight)
        nvgFillPaint(vg, nvgImagePattern(vg, x - width / 2, imageTop,
            width, imageHeight, 0, image, 1))
        nvgFill(vg)
        nvgRestore(vg)
        return
    else
        -- 资源尚未就绪时的矢量兜底，同样让被子覆盖横杠并挂在其上。
        nvgBeginPath(vg)
        nvgMoveTo(vg, x - width * 0.46, y - width * 0.17)
        nvgLineTo(vg, x - width * 0.40, y + width * 0.20)
        nvgLineTo(vg, x + width * 0.40, y + width * 0.20)
        nvgLineTo(vg, x + width * 0.46, y - width * 0.17)
        nvgMoveTo(vg, x - width * 0.43, y); nvgLineTo(vg, x + width * 0.43, y)
        nvgStrokeColor(vg, nvgRGBA(16, 16, 16, 255))
        nvgStrokeWidth(vg, math.max(1, width * 0.025)); nvgStroke(vg)
    end
    -- 兜底被子上缘盖住横杠，避免下方留空；不改降落伞绘制及触发逻辑。
    local sheetTop, sheetBottom = y - width * 0.025, y + height
    local left, right = x - width * 0.35, x + width * 0.35
    nvgBeginPath(vg)
    nvgMoveTo(vg, left, sheetTop)
    nvgLineTo(vg, right, sheetTop)
    nvgBezierTo(vg, right - width * 0.025, sheetTop + height * 0.33,
        right + width * 0.01, sheetBottom - height * 0.20, right, sheetBottom)
    for i = 4, 1, -1 do
        local start = left + (right - left) * i / 4
        local finish = left + (right - left) * (i - 1) / 4
        nvgBezierTo(vg, start - width * 0.035, sheetBottom - width * 0.025,
            finish + width * 0.035, sheetBottom - width * 0.025, finish, sheetBottom)
    end
    nvgBezierTo(vg, left - width * 0.01, sheetBottom - height * 0.20,
        left + width * 0.025, sheetTop + height * 0.33, left, sheetTop)
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(255, 252, 237, 255)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(15, 15, 15, 255))
    nvgStrokeWidth(vg, math.max(1, width * 0.018)); nvgStroke(vg)
    nvgBeginPath(vg)
    for i = 1, 4 do
        local creaseX = left + (right - left) * i / 5
        nvgMoveTo(vg, creaseX, sheetTop + width * 0.025)
        nvgBezierTo(vg, creaseX + width * 0.02, sheetTop + height * 0.28,
            creaseX - width * 0.018, sheetBottom - height * 0.22, creaseX + width * 0.008, sheetBottom - width * 0.07)
    end
    nvgStrokeWidth(vg, math.max(0.65, width * 0.009))
    nvgStrokeColor(vg, nvgRGBA(20, 20, 18, 165)); nvgStroke(vg)
    nvgRestore(vg)
end

--- 防盗窗左上角矩形绘制；窗洞/工具槽/仓库掉落共用同一图片，不重画矢量栅条。
---@param vg NVGContextWrapper
---@param x number
---@param y number
---@param w number
---@param h number
---@param selected boolean?
---@param ghost boolean?
---@param valid boolean?
function PropSystem.RenderSecurity(vg, x, y, w, h, selected, ghost, valid)
    if not Finite(x) or not Finite(y) or not Finite(w) or not Finite(h) or w <= 0 or h <= 0 then return end
    nvgSave(vg)
    if ghost then nvgGlobalAlpha(vg, 0.65) end
    local invalid = ghost and not valid
    if selected or ghost then
        nvgBeginPath(vg); nvgRect(vg, x, y, w, h)
        nvgFillColor(vg, invalid and nvgRGBA(236, 101, 92, 45) or nvgRGBA(74, 191, 152, 40)); nvgFill(vg)
    end
    -- 不做 contain/额外内缩：图片的完整矩形正好覆盖真实窗洞，保护/拾取同一个矩形。
    local ImageCache = require("urhox-libs/UI/Core/ImageCache")
    local image = math.floor(ImageCache.Get("Global/Images/SecurityWindow.png"))
    if image > 0 then
        nvgBeginPath(vg); nvgRect(vg, x, y, w, h)
        nvgFillPaint(vg, nvgImagePattern(vg, x, y, w, h, 0, image, 1)); nvgFill(vg)
    end
    if selected or ghost then
        local thickness = math.max(1, math.min(w, h) * 0.025)
        nvgBeginPath(vg)
        nvgRect(vg, x + thickness / 2, y + thickness / 2, w - thickness, h - thickness)
        nvgStrokeColor(vg, invalid and nvgRGBA(218, 80, 75, 220) or nvgRGBA(45, 157, 120, 220))
        nvgStrokeWidth(vg, thickness); nvgStroke(vg)
    end
    nvgRestore(vg)
end

function PropSystem:Render(vg, unit)
    if unit <= 0 then return end
    for _, prop in ipairs(self.props) do
        if not prop.deleted then
            if prop.kind == "security_window" then
                -- 拖旧窗时原栅条仍在原窗绘制/保护，新位置仅是ghost，commit才换窗。
                if self:SyncSecurityWindow(prop --[[@as SecurityWindow]]) then
                    PropSystem.RenderSecurity(vg, (prop.x - prop.width / 2) * unit, (prop.y - prop.height / 2) * unit,
                        prop.width * unit, prop.height * unit, self.selectedId == prop.id, false, true)
                end
            elseif not prop.dragging then
                PropSystem.DrawRack(vg, prop.x * unit, prop.y * unit, prop.width * unit,
                    prop.height * unit, self.selectedId == prop.id, false, true)
            end
        end
    end
end

function PropSystem:RenderPreview(vg, unit)
    local drag = self.drag
    if not drag.active or unit <= 0 or not Finite(drag.x) or not Finite(drag.y) then return end
    if drag.kind == "rack" then
        PropSystem.DrawRack(vg, drag.x * unit, drag.y * unit, self.rackWidth * unit,
            self.rackHeight * unit, true, true, drag.valid)
    elseif drag.kind == "security_window" then
        local definition = self.definitions.security_window
        local w, h = definition.width, definition.height
        local index = self:FindWindow(drag.windowKey)
        if index then local _, _, ww, wh = self.game:GetWindowRect(index); w, h = ww, wh end
        PropSystem.RenderSecurity(vg, (drag.x - w / 2) * unit, (drag.y - h / 2) * unit,
            w * unit, h * unit, true, true, drag.valid)
    end
end

--- 工具栏按 UI 基准像素传入矩形；只画图标，不创建按钮或改工具栏状态。
function PropSystem.DrawIcon(vg, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    local width = math.min(w * 0.88, h * 0.88 / (SHEET_RATIO + FRAME_RATIO / 2))
    local height = width * SHEET_RATIO
    local total = height + width * FRAME_RATIO / 2
    PropSystem.DrawRack(vg, x + w / 2, y + (h - total) / 2 + width * FRAME_RATIO / 2, width, height)
end

-- ==================== 六、生命周期 ====================
--- 编辑接口只能在输入/Update 中调用；删除物理节点排队到 Update，绝不在 Contact 中执行。
---@return boolean
function PropSystem:Delete(id)
    local prop = self:Find(id)
    if not prop then return false end
    if self.drag.active and self.drag.kind ~= "fence" and self.drag.propId == id then self:FinishDrag() end
    prop.deleted, prop.dragging = true, false
    self.byId[id] = nil
    if prop.windowKey and self.byWindow[prop.windowKey] == prop then self.byWindow[prop.windowKey] = nil end
    local node = prop.node
    if node then
        self.byNode[node.ID] = nil
        node.enabled = false
        self.pendingNodes[#self.pendingNodes + 1] = node
    end
    prop.node, prop.body, prop.shape = nil, nil, nil
    print(string.format("[道具] 删除 %s #%d，库存不返还", prop.kind, id))
    for i = #self.props, 1, -1 do
        if self.props[i].id == id then table.remove(self.props, i); break end
    end
    if self.selectedId == id then self.selectedId = 0 end
    return true
end

function PropSystem:FlushDeletedNodes()
    -- 唯一调用点在 Update（暂停时同样执行）；不持有已释放的组件。
    local nodes = self.pendingNodes
    self.pendingNodes = {}
    for _, node in ipairs(nodes) do node:Remove(); node:Dispose() end
end

function PropSystem:Clear()
    if self.drag.active and self.drag.kind ~= "fence" then self:CancelDrag() end
    while #self.props > 0 do self:Delete(self.props[#self.props].id) end
    self.byId, self.byNode, self.byWindow, self.samples, self.selectedId = {}, {}, {}, {}, 0
    -- 不清猫的 parachute，不操作旧 fences，不 Dispose 主 scene 或 UI 图片缓存。
    -- 游戏退出：Clear(); Update(0); 然后由 Game Dispose scene。
end

---@return PropPosition[]
function PropSystem:Export()
    ---@type PropPosition[]
    local result = {}
    for _, prop in ipairs(self.props) do
        -- 搬动尚未提交时仍导出原位置/原windowKey，绝不导出ghost/ID/节点。
        if prop.kind == "security_window" then
            result[#result + 1] = { kind = "security_window", windowKey = prop.windowKey,
                source = prop.source == "tutorial" and "tutorial" or "warehouse" }
        else
            local entry = { kind = "rack", x = prop.x, y = prop.y }
            if prop.source == "warehouse" then entry.source = "warehouse" end
            result[#result + 1] = entry
        end
    end
    return result
end

--- 内部恢复接受旧rack与稳定窗key；不消费，不发放，不清库存。
---@param list PropPosition[]?
---@return integer
function PropSystem:Restore(list)
    self:Clear()
    local count = 0
    if type(list) ~= "table" or self.game.config.number == 1 then return count end
    for _, item in ipairs(list) do
        if type(item) == "table" then
            if (item.kind == nil or item.kind == "rack") and (item.source == nil or item.source == "tutorial"
                or (item.source == "warehouse" and self.game.config.number >= 5)) and self:CanPlace("rack", item.x, item.y) then
                SpawnRack(self, item.x, item.y, item.source)
                if item.source ~= "warehouse" then self.inventory.tutorialGranted, self.inventory.rack = true, 0 end
                count = count + 1
            elseif item.kind == "security_window" and ((item.source == "tutorial" and self.game.config.number >= 4)
                or ((item.source == nil or item.source == "warehouse") and self.game.config.number >= 5))
                and self:CanInstallWindow(item.windowKey) then
                local index = self:FindWindow(item.windowKey)
                if index and item.windowKey then
                    SpawnSecurity(self, item.windowKey, index, item.source)
                    if item.source == "tutorial" then self.inventory.securityGranted, self.inventory.security = true, 0 end
                    count = count + 1
                end
            else
                print("[道具恢复] 跳过非法位置/未知来源/重复或不存在的窗key")
            end
        end
    end
    print(string.format("[道具恢复] 已恢复 %d 件（不消费教程或掉落库存）", count))
    return count
end

return PropSystem
