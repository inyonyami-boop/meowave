-- 独立楼层网格模块；沿用 scaffold-2d 的 UI 自定义绘图生命周期，不创建场景或 NanoVG 帧。
-- 坐标单位为米，画面 Y 向下；unit 由宿主 UI 传入，沿用其逻辑像素/DPR 缩放。
local ImageCache = require("urhox-libs/UI/Core/ImageCache")

-- ============================================================================
-- 数据
-- ============================================================================

---@class FloorBlocksWindow
---@field x number
---@field y number
---@field w number
---@field h number
---@field world boolean? true 表示世界矩形；原楼窗口仍使用原图像素坐标。
---@field key string? 新楼层窗口的稳定标识；原楼窗口由宿主初始化。
---@field warehouse boolean? true 表示五金仓库窗口，宿主不得在此生成猫咪。
---@field warehouseKey string? 同一仓库三个窗口共用的 col:row 标识。
---@field laboratory boolean? true 表示电气实验室唯一的中窗；磁猫概率由宿主消费。
---@field laboratoryKey string? 同一实验室的 col:row 稳定标识。
---@field matchmaking boolean? true 表示婚恋中心唯一横宽窗，跨普通三窗但只注册 slot=2。
---@field matchmakingKey string? 同一婚恋中心的 col:row 稳定标识。
---@field greenhouse boolean? true 表示温室的三个真实窗，植物系统可按稳定窗位消费。
---@field greenhouseKey string? 同一温室的 col:row 稳定标识。
---@field col integer? 所属新增楼层列。
---@field row integer? 所属新增楼层行。
---@field slot integer? 原图窗位 1/2/3；实验室与婚恋中心只注册 slot=2。

---@class FloorBlocksConfig
---@field number integer?
---@field buildingRect {x:number, y:number, w:number, h:number}
---@field buildingHeight number
---@field windows FloorBlocksWindow[]

---@class FloorBlocksGame
---@field config FloorBlocksConfig
---@field width number
---@field groundY number
---@field height number
---@field run ChallengeRun? 非nil表示内存布局挑战；普通关布局仍走原存档校验。
---@field windows FloorBlocksWindow[]
---@field view VerticalView?

---@class FloorBlockPlacement
---@field col integer
---@field row integer
---@field roof integer? 1=瓦片屋顶，2=铁皮屋顶，nil=普通楼层；样式由提供时确定。
---@field roofFlip boolean? false=放在邻居左侧（原图），true=右侧（镜像）。
---@field warehouse boolean? true=五金仓库；可与 roof 组合，第五关起开放。
---@field laboratory boolean? true=电气实验室；第六关起开放。
---@field matchmaking boolean? true=婚恋中心；第七关起开放。
---@field greenhouse boolean? true=温室；第八关起开放。四类特殊互斥，均可与 roof 组合。

---@class FloorBlock
---@field col integer
---@field row integer
---@field roof integer?
---@field roofFlip boolean?
---@field warehouse boolean?
---@field laboratory boolean?
---@field matchmaking boolean?
---@field greenhouse boolean?
---@field hasWindows boolean
---@field isSeed boolean
---@field image string
---@field windowStart integer 新增窗洞在 game.windows 中的首索引；seed/已清理楼层为 0。
---@field windowEnd integer 新增窗洞在 game.windows 中的末索引，包含末项。
---@field windowCount integer
local FloorBlock = {}
FloorBlock.__index = FloorBlock

--- 四个独立布尔值只允许一个 true；false 与缺参仍表示普通楼层，roof 不参与互斥。
---@param warehouse boolean?
---@param laboratory boolean?
---@param matchmaking boolean?
---@param greenhouse boolean?
---@return boolean
local function HasValidSpecials(warehouse, laboratory, matchmaking, greenhouse)
    if warehouse ~= nil and type(warehouse) ~= "boolean" then return false end
    if laboratory ~= nil and type(laboratory) ~= "boolean" then return false end
    if matchmaking ~= nil and type(matchmaking) ~= "boolean" then return false end
    if greenhouse ~= nil and type(greenhouse) ~= "boolean" then return false end
    local count = (warehouse == true and 1 or 0) + (laboratory == true and 1 or 0)
        + (matchmaking == true and 1 or 0) + (greenhouse == true and 1 or 0)
    return count <= 1
end

---@param warehouse boolean?
---@param laboratory boolean?
---@param matchmaking boolean?
---@param greenhouse boolean?
---@return string
local function FloorImage(warehouse, laboratory, matchmaking, greenhouse)
    if greenhouse == true then return "Global/Images/Greenhouse.png" end
    if matchmaking == true then return "Global/Images/Matchmaking.png" end
    if laboratory == true then return "Global/Images/ElectricalLab.png" end
    if warehouse == true then return "Global/Images/Warehouse.png" end
    return "Global/Images/FloorBlock.png"
end

---@param col integer
---@param row integer
---@param hasWindows boolean
---@param isSeed boolean
---@param roof integer?
---@param roofFlip boolean?
---@param warehouse boolean?
---@param laboratory boolean?
---@param matchmaking boolean?
---@param greenhouse boolean?
---@return FloorBlock
function FloorBlock.New(col, row, hasWindows, isSeed, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    local block = setmetatable({}, FloorBlock)
    block:Init(col, row, hasWindows, isSeed, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    return block
end

---@param col integer
---@param row integer
---@param hasWindows boolean
---@param isSeed boolean
---@param roof integer?
---@param roofFlip boolean?
---@param warehouse boolean?
---@param laboratory boolean?
---@param matchmaking boolean?
---@param greenhouse boolean?
function FloorBlock:Init(col, row, hasWindows, isSeed, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    assert(HasValidSpecials(warehouse, laboratory, matchmaking, greenhouse), "四类特殊楼层必须为互斥布尔值")
    self.col, self.row = col, row
    self.roof, self.roofFlip, self.warehouse, self.laboratory = roof, nil, nil, nil
    self.matchmaking, self.greenhouse = nil, nil
    if warehouse == true then self.warehouse = true end
    if laboratory == true then self.laboratory = true end
    if matchmaking == true then self.matchmaking = true end
    if greenhouse == true then self.greenhouse = true end
    -- roof 是有窗楼层上的透明屋顶装饰，不另造墙体或改变楼层单元。
    -- false 不能用 and/or 保存，否则会被误转为 nil；动态 front mode 从不保存。
    if roof ~= nil then self.roofFlip = roofFlip == true end
    self.hasWindows, self.isSeed = hasWindows, isSeed
    self.image = FloorImage(self.warehouse, self.laboratory, self.matchmaking, self.greenhouse)
    self.windowStart, self.windowEnd, self.windowCount = 0, 0, 0
end

---@class BuildingGrid
---@field game FloorBlocksGame
---@field originX number
---@field originY number
---@field cellWidth number
---@field cellHeight number
---@field cells table<number, table<number, FloorBlock>?> 允许负列号和零行号的稀疏映射，不是数组。
---@field seeds FloorBlock[] 原楼占位，不额外绘制或注册窗洞。
---@field blocks FloorBlock[] 仅新增楼层，保持放置顺序供 Export/Restore 使用。
---@field ownedWindows table<FloorBlocksWindow, boolean> 对象身份集合，只清理本模块追加的窗洞。
---@field disposed boolean
local BuildingGrid = {}
BuildingGrid.__index = BuildingGrid

local SOURCE_WIDTH, SOURCE_HEIGHT = 258, 228
local ROOF_WIDTH_RATIO = 1.235
---@class FloorRoofArt
---@field path string
---@field frontPath string
---@field leftAnchor number
---@field rightAnchor number
---@field eave number
---@type FloorRoofArt[]
local ROOF_ART = {
    { path = "Global/Images/RoofTile.png", frontPath = "Global/Images/RoofTileFront.png",
        leftAnchor = 0.19, rightAnchor = 0.995, eave = 0.375 },
    { path = "Global/Images/RoofMetal.png", frontPath = "Global/Images/RoofMetalFront.png",
        leftAnchor = 0.19, rightAnchor = 0.995, eave = 0.465 },
}

-- front 裁图屋顶/管分段重采样为 eave=.375/.465，主体高度严格沿用旧侧面屋顶。
-- front 外框宽为一整格；屋檐基线=楼层顶，集水槽及左管全在下方楼层内部。
---@param roof integer
---@param flip boolean
---@param mode "front"|"side"
---@param x number
---@param y number
---@param w number
---@param h number
local function RoofRect(roof, flip, mode, x, y, w, h)
    local art = ROOF_ART[roof]
    assert(art ~= nil, "屋顶样式必须对应已有屋顶配置")
    local roofH = h / (1 - art.eave)
    if mode == "front" then return x, y - roofH * art.eave, w, roofH end
    local roofW = w * ROOF_WIDTH_RATIO
    local fitOffset = (w - (art.rightAnchor - art.leftAnchor) * roofW) / 2
    local anchor = flip and (1 - art.rightAnchor) or art.leftAnchor
    return x - anchor * roofW + fitOffset, y - roofH * art.eave, roofW, roofH
end
-- 仓库原图只按 alpha 外接框 (21,53)-(1527,1476) 裁外围，得到 1506×1423；不按黑色抠图或去浅色窗。
-- 原图三个实测浅色窗约为 (217,622,243,360)、(652,626,245,355)、(1091,624,241,359)。
-- 裁后归一化与普通窗的边界相差不超过单元 2%，统一使用 SOURCE_WINDOWS，保持窗台落点/安装尺度一致。
---@type FloorBlocksWindow[]
local SOURCE_WINDOWS = {
    { x = 36, y = 92, w = 41, h = 60 },
    { x = 110, y = 93, w = 41, h = 59 },
    { x = 185, y = 93, w = 39, h = 59 },
}
-- 实验室上传 alpha 主体裁 (22,91)-(1527,1454)，1505×1363。
-- 唯一中窗黑洞原图 (646,599)-(911,990) 单独转透明；不把其余黑色材质抠掉。
-- 可用窗内矩形保守内缩到裁后 (630,531,252,360)，该矩形逐像素 alpha=0，避免窗框压住猫。
local LAB_WIDTH, LAB_HEIGHT = 1505, 1363
local LAB_WINDOW = { x = 630, y = 531, w = 252, h = 360 }

-- 新原稿都是 1536×1536 RGB；只移除四边连通的近白(RGB最低225、色差<=16)，不误抠灰材质。
-- 婚恋主体裁 (24,35)-(1516,1506)，1492×1471；内米白窗口像素完整保留，不转透明。
-- 原图唯一真实窗的可用内矩形 (250,697,1044,419)，避开黑框/阴影与底沿。
-- 裁后归一化 (0.1514745308,0.4500339905,0.6997319035,0.2848402447)，横跨普通三窗，仅 slot2。
local MATCH_WIDTH, MATCH_HEIGHT = 1492, 1471
local MATCH_WINDOW = { x = 226, y = 662, w = 1044, h = 419 }
-- 温室主体裁 (27,59)-(1516,1494)，1489×1435；浅绿玻璃、藤叶和金属窗框全部保留。
-- 三个原图可用内窗 (211,612,240,368)/(653,612,243,368)/(1096,613,237,368)。
-- 对应裁后比例：(.1235728677,.3853658537,.1611820013,.2564459930)；
-- (.4204163868,.3853658537,.1631967764,.2564459930)；(.7179314976,.3860627178,.1591672263,.2564459930)。
local GREENHOUSE_WIDTH, GREENHOUSE_HEIGHT = 1489, 1435
---@type FloorBlocksWindow[]
local GREENHOUSE_WINDOWS = {
    { x = 184, y = 553, w = 240, h = 368 },
    { x = 626, y = 553, w = 243, h = 368 },
    { x = 1069, y = 554, w = 237, h = 368 },
}
-- HangingPlants.png 从 84a9e0af 原稿裁 (145,195)-(1424,1046)，1279×851，保留浅绿全主体。
-- 位置参考图从不作为植物纹理；实际挂植物交给宿主植物模块，不在网格层复制/生成实体。

---@param game FloorBlocksGame
---@return BuildingGrid
function BuildingGrid.New(game)
    local grid = setmetatable({}, BuildingGrid)
    grid:Init(game)
    return grid
end

---@param game FloorBlocksGame
function BuildingGrid:Init(game)
    self.game = game
    self.originX, self.originY = game.config.buildingRect.x, 0
    self.cellWidth = game.config.buildingRect.w
    local firstWindow, fourthWindow = game.config.windows[1], game.config.windows[4]
    assert(firstWindow ~= nil and fourthWindow ~= nil, "楼层网格需要原楼第一窗与第四窗确定层高")
    self.cellHeight = (fourthWindow.y - firstWindow.y)
        * game.config.buildingRect.h / game.config.buildingHeight
    assert(self.cellWidth > 0 and self.cellWidth < math.huge
        and self.cellHeight > 0 and self.cellHeight < math.huge, "楼层网格尺寸必须为有限正数")
    self.minRow = math.ceil(((game.view and game.view.minWorldY or 0) - self.originY) / self.cellHeight)
    self.maxRow = math.floor((game.groundY - self.originY) / self.cellHeight) - 1
    self.cells, self.seeds, self.blocks, self.ownedWindows = {}, {}, {}, {}
    self.highestOccupiedRow = 0 -- 缓存实楼/屋顶最高占格，Restore逐条扩顶不反复扫描整栋楼。
    self.disposed = false
    -- seed 无条件占位：row=3 即使越过 groundY 也保留，但不能作为有窗邻居。
    -- 构造过程不修改 game.windows；原楼的九个窗洞由 Game 自己维护。
    for row = 0, 3 do
        local block = FloorBlock.New(0, row, row < 3, true)
        self.seeds[#self.seeds + 1] = block
        self:SetBlock(block)
    end
    if game.run ~= nil and game.view then game.view:EnsureBuildSpace(self) end
    print(string.format("[楼层网格] 初始化：单元 %.3f × %.3f 米，原楼占位 4 层", self.cellWidth, self.cellHeight))
end

-- ============================================================================
-- 网格换算
-- ============================================================================

--- x/y 是待放楼层的中心点，不是左上角；负列也必须用 floor 而不是截断。
---@param x number
---@param y number
---@return integer col
---@return integer row
function BuildingGrid:Snap(x, y)
    return math.floor((x - self.originX) / self.cellWidth),
        math.floor((y - self.originY) / self.cellHeight)
end

---@param col number
---@param row number
---@return number x
---@return number y
---@return number w
---@return number h
function BuildingGrid:GetRect(col, row)
    return self.originX + col * self.cellWidth, self.originY + row * self.cellHeight,
        self.cellWidth, self.cellHeight
end

---@param value any
---@return boolean
local function IsCellIndex(value)
    -- 稀疏键/稳定窗key/世界坐标要能精确保留 row±1；拒绝Lua整数溢出和浮点相邻格合并。
    -- 这是数值安全界，不是楼层/猫咪额度上限。挑战布局不经过 LevelSave 的32位磁盘范围。
    return type(value) == "number" and value == value and value % 1 == 0
        and value >= -9007199254740990 and value <= 9007199254740990
end

--- 按已有实楼/屋顶最高占格预留至少三份新楼，再额外留一格容纳两款最大屋檐。
--- 不预创建空格、不改层高/列宽/原楼窗位；调用者只用此结果扩展 view 的构建顶边。
---@param reserveRows integer? 新供给可能增加的楼层数；nil或小于3仍预留3。
---@return number top
function BuildingGrid:GetBuildTop(reserveRows)
    local reserve = reserveRows or 3
    assert(IsCellIndex(reserve) and reserve >= 0, "挑战预留楼层数必须为安全非负整数")
    local rows = math.max(3, reserve)
    local targetRow = self.highestOccupiedRow - rows - 1
    assert(IsCellIndex(targetRow), "挑战构建顶边超过Lua精确相邻整数范围，不能静默裁掉供给")
    return self.originY + targetRow * self.cellHeight
end

--- 完整新楼层位于世界界内；高度延伸至视角上限，所有行共用相同单元尺寸。
---@param col number
---@param row number
---@return boolean
function BuildingGrid:IsInBounds(col, row)
    if not IsCellIndex(col) or not IsCellIndex(row) or row < self.minRow or row > self.maxRow then return false end
    local x, y, w, h = self:GetRect(col, row)
    local top = self.game.view and self.game.view.minWorldY or 0
    return x >= 0 and x + w <= self.game.width and y >= top and y + h <= self.game.groundY
end

-- ============================================================================
-- 占用邻接
-- ============================================================================

---@param block FloorBlock
function BuildingGrid:SetBlock(block)
    local column = self.cells[block.col]
    if not column then
        column = {}
        self.cells[block.col] = column
    end
    column[block.row] = block
    self.highestOccupiedRow = math.min(self.highestOccupiedRow, block.row - (block.roof ~= nil and 1 or 0))
end

---@param col number
---@param row number
---@return FloorBlock?
function BuildingGrid:GetBlock(col, row)
    local column = self.cells[col]
    if not column then return nil end
    return column[row]
end

--- 屋顶装饰的占格在宿主楼层 row-1；返回宿主块，但不写 cells、不作为实楼层或结构承托。
---@param col number
---@param row number 屋顶所在格，不是宿主楼层格。
---@return FloorBlock?
function BuildingGrid:GetRoofOccupant(col, row)
    local block = self:GetBlock(col, row + 1)
    if block and block.roof ~= nil then return block end
    return nil
end

--- 实块/屋顶联合占位仅供屋顶形态与空格门控；HasNeighbor/支架仍只读 GetBlock。
---@param col number
---@param row number
---@return boolean
function BuildingGrid:IsOccupied(col, row)
    return self:GetBlock(col, row) ~= nil or self:GetRoofOccupant(col, row) ~= nil
end

--- 查询宿主楼层的屋顶动态形态（也可用于尚未放置的预览），不更改固定 roofFlip。
--- 屋顶格 row-1 左右两邻格均有实块或屋顶才 front；单侧/均无保持旧 side。
---@param col number
---@param row number 宿主楼层格。
---@return "front"|"side"
function BuildingGrid:GetRoofMode(col, row)
    if self:IsOccupied(col - 1, row - 1) and self:IsOccupied(col + 1, row - 1) then return "front" end
    return "side"
end

--- Render/Preview/CanPlace 唯一屋顶完整外接矩形，单位为世界米；高度始终沿用该款旧屋顶。
---@param col number
---@param row number 宿主楼层格。
---@param roof integer 1/2。
---@param roofFlip boolean?
---@return number x
---@return number y
---@return number w
---@return number h
function BuildingGrid:GetRoofRect(col, row, roof, roofFlip)
    local x, y, w, h = self:GetRect(col, row)
    return RoofRect(roof, roofFlip == true, self:GetRoofMode(col, row), x, y, w, h)
end

---@param col number
---@param row number
---@return boolean
function BuildingGrid:HasWindowNeighbor(col, row)
    local left = self:GetBlock(col - 1, row)
    local right = self:GetBlock(col + 1, row)
    local above = self:GetBlock(col, row - 1)
    local below = self:GetBlock(col, row + 1)
    return (left ~= nil and left.hasWindows) or (right ~= nil and right.hasWindows)
        or (above ~= nil and above.hasWindows) or (below ~= nil and below.hasWindows)
end

function BuildingGrid:HasNeighbor(col, row)
    return self:GetBlock(col - 1, row) ~= nil or self:GetBlock(col + 1, row) ~= nil
        or self:GetBlock(col, row - 1) ~= nil or self:GetBlock(col, row + 1) ~= nil
end

---@param roof integer?
---@return boolean
local function IsRoofStyle(roof)
    return roof == nil or roof == 1 or roof == 2
end

-- 放置检测仅使用稀疏格子，不引入新物理/墙体；画面 row 越小越靠上。
--               col-1        col         col+1
-- row-1 及更高               空          屋顶本格整列上方不得占用（seed/roof 也算）。
-- row        [同层邻居]     [待放 roof]   [同层邻居]   至少一侧相邻；上下邻居不能代替。
-- row+1                    [实块/空]     宿主 roof 占 row-1，新真实块不可进入任何屋顶格。
-- 左放=右邻承接=原图；右放=左邻承接=镜像。固定 flip 不变，双侧屋顶格邻接只动态切 front。
--- 返回当前格合法的屋顶朝向；显式传 preferredFlip 时不擅自改向。
--- 宿主若只获取到 false 仍是合法方向，应使用 flip ~= nil 而不是 if flip。
---@param col number
---@param row number
---@param preferredFlip boolean?
---@return boolean? roofFlip false=左放，true=右放，nil=非法。
function BuildingGrid:GetPlacementRoofFlip(col, row, preferredFlip)
    if not self:CanPlace(col, row) then return nil end
    -- pairs 支持负行/零行和孔洞；不能用 ipairs/#，也不能只查相邻上一格。
    local column = self.cells[col]
    if column then
        for occupiedRow in pairs(column) do
            if occupiedRow < row then return nil end
        end
    end
    if preferredFlip ~= nil and type(preferredFlip) ~= "boolean" then return nil end
    local left = self:GetBlock(col - 1, row)
    local right = self:GetBlock(col + 1, row)
    if not left and not right then return nil end
    if preferredFlip ~= nil then
        if (preferredFlip and left ~= nil) or (not preferredFlip and right ~= nil) then
            return preferredFlip
        end
        return nil
    end
    if left and right then
        -- 已有侧邻屋顶可确定同一排朝向；冲突时选更靠近原楼的一側。
        if left.roof ~= nil and right.roof ~= nil and left.roofFlip == right.roofFlip then
            return left.roofFlip == true
        elseif left.roof ~= nil and right.roof == nil then
            return left.roofFlip == true
        elseif right.roof ~= nil and left.roof == nil then
            return right.roofFlip == true
        end
        return math.abs(col - 1) <= math.abs(col + 1)
    end
    return left ~= nil
end

---@param col number
---@param row number
---@param roof integer? nil 保持原普通楼层规则；1/2 使用屋顶规则。
---@param roofFlip boolean? 指定朝向必须有对应侧邻；nil 自动固定选向。
---@param warehouse boolean? true=仓库，可与 roof 组合；第五关起开放。
---@param laboratory boolean? 保留第六参；第六关起开放。
---@param matchmaking boolean? 追加第七参；第七关起开放。
---@param greenhouse boolean? 追加第八参；第八关起开放。四类特殊互斥，均可叠加 roof。
---@return boolean
function BuildingGrid:CanPlace(col, row, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    if not HasValidSpecials(warehouse, laboratory, matchmaking, greenhouse) then return false end
    local level = self.game.config.number or 0
    if warehouse == true and level < 5 then return false end
    if laboratory == true and level < 6 then return false end
    if matchmaking == true and level < 7 then return false end
    if greenhouse == true and level < 8 then return false end
    if self.disposed or not IsRoofStyle(roof) or not self:IsInBounds(col, row)
        or self:IsOccupied(col, row) then return false end
    if not self:HasNeighbor(col, row) then return false end
    if roof ~= nil then
        local flip = self:GetPlacementRoofFlip(col, row, roofFlip)
        if flip == nil then return false end
        local rx, ry, rw, rh = self:GetRoofRect(col, row, roof, flip)
        local top = self.game.view and self.game.view.minWorldY or 0
        return rx >= 0 and rx + rw <= self.game.width and ry >= top and ry + rh <= self.game.groundY
    end
    return true
end

---@param col number
---@param row number
---@param roof integer? 提供时随机选定 1/2 并持续传入；本模块从不随机样式。
---@param roofFlip boolean? nil=按侧邻确定；指定后原样保存，Restore 不重新选向。
---@param warehouse boolean?
---@param laboratory boolean?
---@param matchmaking boolean? 追加第七参，不移动仓库/实验室。
---@param greenhouse boolean? 追加第八参。
---@return FloorBlock?
function BuildingGrid:Place(col, row, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    if not self:CanPlace(col, row, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse) then return nil end
    ---@type boolean?
    local placementFlip = nil
    if roof ~= nil then placementFlip = self:GetPlacementRoofFlip(col, row, roofFlip) end
    local block = FloorBlock.New(math.floor(col), math.floor(row), true, false, roof, placementFlip,
        warehouse, laboratory, matchmaking, greenhouse)
    self:SetBlock(block)
    self.blocks[#self.blocks + 1] = block
    local windows = self:GetWindowRects(block)
    block.windowStart = #self.game.windows + 1
    for _, window in ipairs(windows) do
        self.game.windows[#self.game.windows + 1] = window
        self.ownedWindows[window] = true
    end
    block.windowEnd, block.windowCount = #self.game.windows, #windows
    print(string.format("[楼层网格] 放置 (%d,%d)，新增窗洞索引 %d..%d", block.col, block.row,
        block.windowStart, block.windowEnd))
    if block.roof ~= nil then
        print(string.format("[楼层网格] 屋顶样式 %d，%s侧放置（roofFlip=%s）", block.roof,
            block.roofFlip and "右" or "左", tostring(block.roofFlip)))
    end
    if block.warehouse then
        print(string.format("[楼层网格] 五金仓库 %d:%d，三个窗口已标记 warehouse", block.col, block.row))
    elseif block.laboratory then
        print(string.format("[楼层网格] 电气实验室 %d:%d，仅 slot=2 中窗，已标记 laboratory", block.col, block.row))
    elseif block.matchmaking then
        print(string.format("[楼层网格] 婚恋中心 %d:%d，仅 slot=2 横宽窗，已标记 matchmaking", block.col, block.row))
    elseif block.greenhouse then
        print(string.format("[楼层网格] 温室 %d:%d，三个实测窗口已标记 greenhouse", block.col, block.row))
    end
    return block
end

-- 安装判定设计：检测晾衣架安装点是否落在任何楼层实心外接矩形，不创建物理碰撞体。
--          col=-1       col=0       col=1
--        ┌────────┬────────────┬────────┐
-- row=0  │ 新楼层 │ 原楼 seed  │ 新楼层 │  含边界；接缝处安装有效。
--        └────────┴────────────┴────────┘
-- 空格不命中；窗洞仍算楼房；seed=3 超出地面的部分也按其占位矩形命中。
---@param x number
---@param y number
---@return boolean
function BuildingGrid:IsOnBuilding(x, y)
    if self.disposed then return false end
    for _, group in ipairs({ self.seeds, self.blocks }) do
        for _, block in ipairs(group) do
            local bx, by, bw, bh = self:GetRect(block.col, block.row)
            if x >= bx and x <= bx + bw and y >= by and y <= by + bh then return true end
        end
    end
    return false
end

-- ============================================================================
-- 窗洞
-- ============================================================================

--- 普通/仓库沿用 258×228 三窗；实验室、婚恋、温室分别使用各自裁图的实测内窗。
--- Game:GetWindowRect 遇到 world=true 时必须直接返回 x/y/w/h，不再套原楼图缩放。
---@param block FloorBlock
---@return FloorBlocksWindow[]
function BuildingGrid:GetWindowRects(block)
    ---@type FloorBlocksWindow[]
    local windows = {}
    if not block.hasWindows then return windows end
    local x, y, w, h = self:GetRect(block.col, block.row)
    local blockKey = block.col .. ":" .. block.row
    if block.matchmaking then
        windows[1] = {
            x = x + MATCH_WINDOW.x / MATCH_WIDTH * w,
            y = y + MATCH_WINDOW.y / MATCH_HEIGHT * h,
            w = MATCH_WINDOW.w / MATCH_WIDTH * w,
            h = MATCH_WINDOW.h / MATCH_HEIGHT * h,
            world = true,
            key = "floor:" .. blockKey .. ":2",
            matchmaking = true, matchmakingKey = blockKey,
            col = block.col, row = block.row, slot = 2,
        }
        return windows
    end
    if block.greenhouse then
        for slot, source in ipairs(GREENHOUSE_WINDOWS) do
            windows[#windows + 1] = {
                x = x + source.x / GREENHOUSE_WIDTH * w,
                y = y + source.y / GREENHOUSE_HEIGHT * h,
                w = source.w / GREENHOUSE_WIDTH * w,
                h = source.h / GREENHOUSE_HEIGHT * h,
                world = true,
                key = "floor:" .. blockKey .. ":" .. slot,
                greenhouse = true, greenhouseKey = blockKey,
                col = block.col, row = block.row, slot = slot,
            }
        end
        return windows
    end
    if block.laboratory then
        windows[1] = {
            x = x + LAB_WINDOW.x / LAB_WIDTH * w,
            y = y + LAB_WINDOW.y / LAB_HEIGHT * h,
            w = LAB_WINDOW.w / LAB_WIDTH * w,
            h = LAB_WINDOW.h / LAB_HEIGHT * h,
            world = true,
            key = "floor:" .. blockKey .. ":2",
            laboratory = true,
            laboratoryKey = blockKey,
            col = block.col, row = block.row, slot = 2,
        }
        return windows
    end
    for slot, source in ipairs(SOURCE_WINDOWS) do
        windows[#windows + 1] = {
            x = x + source.x / SOURCE_WIDTH * w,
            y = y + source.y / SOURCE_HEIGHT * h,
            w = source.w / SOURCE_WIDTH * w,
            h = source.h / SOURCE_HEIGHT * h,
            world = true,
            key = "floor:" .. blockKey .. ":" .. slot,
            warehouse = block.warehouse,
            warehouseKey = block.warehouse and blockKey or nil,
            col = block.col, row = block.row, slot = slot,
        }
    end
    return windows
end

-- ============================================================================
-- 支架
-- ============================================================================

-- 支架设计（Y 向下）：只检测实楼层，不把屋顶占格视为墙体/承托。
--                [ L ] [ A ] [ R ]  A 下方实块 -> 无支架。
--                [ l ] [空/roof] [ r ]
-- L+l 同时实块 -> left；R+r 同时实块 -> right；均满足 -> arch；均不满足 -> 无。
-- 单独 L/R 或上邻不能造支架；左右对角承托不满足也不能锚定。
---@param block FloorBlock
---@return "left"|"right"|"arch"|nil
function BuildingGrid:GetSupportSide(block)
    if block.isSeed or self.disposed or self:GetBlock(block.col, block.row + 1) then return nil end
    local left = self:GetBlock(block.col - 1, block.row) ~= nil
        and self:GetBlock(block.col - 1, block.row + 1) ~= nil
    local right = self:GetBlock(block.col + 1, block.row) ~= nil
        and self:GetBlock(block.col + 1, block.row + 1) ~= nil
    if left and right then return "arch" end
    if left then return "left" end
    if right then return "right" end
    return nil
end

---@param block FloorBlock
---@return boolean
function BuildingGrid:HasSupport(block)
    return self:GetSupportSide(block) ~= nil
end

-- ============================================================================
-- 绘制
-- ============================================================================

--- 本地图片绘制供 Preview 使用，不在这里引用 WorkshopArt，避免 require 环。
---@param vg NVGContextWrapper
---@param path string
---@param x number
---@param y number
---@param w number
---@param h number
---@param alpha number
local function DrawPreviewImage(vg, path, x, y, w, h, alpha)
    local image = ImageCache.Get(path)
    nvgBeginPath(vg)
    nvgRect(vg, x, y, w, h)
    if image > 0 then
        nvgFillPaint(vg, nvgImagePattern(vg, x, y, w, h, 0, math.floor(image), alpha))
    else
        -- 资源尚未就绪时仍保留半透明占位和合法性边框，不逐帧创建纹理。
        nvgFillColor(vg, nvgRGBA(230, 213, 185, math.floor(alpha * 255)))
    end
    nvgFill(vg)
end

-- 裁图的分款屋檐参数位于模块顶部，与 CanPlace 的完整边界判定共用。

--- side 保留原固定镜像，front 左管不镜像；传入 GetRoofRect 唯一完整矩形。
---@param vg NVGContextWrapper
---@param roof integer
---@param roofFlip boolean
---@param mode "front"|"side"
---@param roofX number
---@param roofY number
---@param roofW number
---@param roofH number
---@param alpha number
local function DrawRoofImage(vg, roof, roofFlip, mode, roofX, roofY, roofW, roofH, alpha)
    local art = ROOF_ART[roof]
    if not art then return end
    local path = mode == "front" and art.frontPath or art.path
    local image = ImageCache.Get(path)
    if image <= 0 then return end
    nvgSave(vg)
    if mode ~= "front" and roofFlip then
        nvgTranslate(vg, roofX + roofW, roofY)
        nvgScale(vg, -1, 1)
    else
        nvgTranslate(vg, roofX, roofY)
    end
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, roofW, roofH)
    nvgFillPaint(vg, nvgImagePattern(vg, 0, 0, roofW, roofH, 0, math.floor(image), alpha))
    nvgFill(vg)
    nvgRestore(vg)
end

--- 挑战只提交当前视口附近的真实楼层；两格余量覆盖屋檐上伸/下挂管与下方支架。
--- 普通关仍遍历全部新增楼层，保持原绘制行为。
---@param unit number
---@return integer first
---@return integer last
function BuildingGrid:GetDrawRows(unit)
    if self.game.run ~= nil and self.game.view then
        local first, last = self.game.view:GetVisibleRows(self, self.game.height * unit, unit)
        return first - 2, last + 2
    end
    return self.minRow, self.maxRow
end

--- 楼层结构最高绘制批次；正式屋顶及建设预览后均调用，seed 不重复绘图。
---@param vg NVGContextWrapper
---@param unit number
function BuildingGrid:RenderSupports(vg, unit)
    if self.disposed or unit <= 0 or #self.blocks == 0 then return end
    local Art = require("Global.WorkshopArt")
    local firstRow, lastRow = self:GetDrawRows(unit)
    nvgSave(vg)
    local top = self.game.view and self.game.view.minWorldY or 0
    nvgIntersectScissor(vg, 0, top * unit, self.game.width * unit, (self.game.groundY - top) * unit)
    for _, block in ipairs(self.blocks) do
        local visible = self.game.run == nil or (block.row >= firstRow and block.row <= lastRow)
        local side = visible and self:GetSupportSide(block) or nil
        if side then
            local x, y, w, h = self:GetRect(block.col, block.row)
            if side == "arch" then
                Art.Image(vg, "Global/Images/SupportArch.png", x * unit, (y + h) * unit, w * unit, h * unit)
            else
                local supportWidth, inset = w * 0.8, w * 0.04
                -- 原 SupportLeft 为右锚、向左悬挑；镜像 SupportRight 为左锚、向右悬挑。
                local supportX = side == "left" and (x - inset) or (x + w - supportWidth + inset)
                local path = side == "left" and "Global/Images/SupportRight.png" or "Global/Images/SupportLeft.png"
                Art.Image(vg, path, supportX * unit, (y + h) * unit, supportWidth * unit, h * unit)
            end
        end
    end
    nvgRestore(vg)
end

--- 窗洞底色/等待猫脸由 WorkshopArt.Building 统一绘制；全部主体→全部屋顶→全部支架。
---@param vg NVGContextWrapper
---@param unit number 世界米到宿主逻辑像素的比例。
---@param supports boolean? false表示宿主将在建设预览后统一画一次支架。
function BuildingGrid:Render(vg, unit, supports)
    if self.disposed or unit <= 0 or #self.blocks == 0 then return end
    local Art = require("Global.WorkshopArt")
    local firstRow, lastRow = self:GetDrawRows(unit)
    nvgSave(vg)
    local top = self.game.view and self.game.view.minWorldY or 0
    nvgIntersectScissor(vg, 0, top * unit, self.game.width * unit, (self.game.groundY - top) * unit)
    for _, block in ipairs(self.blocks) do
        if self.game.run == nil or (block.row >= firstRow and block.row <= lastRow) then
            local x, y, w, h = self:GetRect(block.col, block.row)
            Art.Image(vg, block.image, x * unit, y * unit, w * unit, h * unit)
        end
    end
    -- 屋顶在全部楼层之上、支架之下；保留固定屋檐/排水管与镜像。
    for _, block in ipairs(self.blocks) do
        if block.roof ~= nil and (self.game.run == nil or (block.row >= firstRow and block.row <= lastRow)) then
            local rx, ry, rw, rh = self:GetRoofRect(block.col, block.row, block.roof, block.roofFlip)
            DrawRoofImage(vg, block.roof, block.roofFlip == true, self:GetRoofMode(block.col, block.row),
                rx * unit, ry * unit, rw * unit, rh * unit, 1)
        end
    end
    nvgRestore(vg)
    if supports ~= false then self:RenderSupports(vg, unit) end
end

---@param vg NVGContextWrapper
---@param unit number
---@param col number
---@param row number
---@param roof integer?
---@param roofFlip boolean?
---@param warehouse boolean?
---@param laboratory boolean? 追加参数，不挪动旧 warehouse。
---@param matchmaking boolean? 新类型跟在 laboratory 后。
---@param greenhouse boolean? 新类型最后追加。
---@return boolean valid
function BuildingGrid:Preview(vg, unit, col, row, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    local valid = self:CanPlace(col, row, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    if self.disposed or unit <= 0 or not IsCellIndex(col) or not IsCellIndex(row) then return false end
    local x, y, w, h = self:GetRect(col, row)
    local path = FloorImage(warehouse, laboratory, matchmaking, greenhouse)
    nvgSave(vg)
    DrawPreviewImage(vg, path, x * unit, y * unit, w * unit, h * unit, 0.55)
    if roof ~= nil and IsRoofStyle(roof) then
        local previewFlip = roofFlip
        if previewFlip == nil then previewFlip = self:GetPlacementRoofFlip(col, row) end
        local rx, ry, rw, rh = self:GetRoofRect(col, row, roof, previewFlip)
        DrawRoofImage(vg, roof, previewFlip == true, self:GetRoofMode(col, row),
            rx * unit, ry * unit, rw * unit, rh * unit, 0.55)
    end
    nvgBeginPath(vg)
    nvgRect(vg, x * unit, y * unit, w * unit, h * unit)
    nvgStrokeColor(vg, valid and nvgRGBA(64, 190, 120, 230) or nvgRGBA(228, 77, 77, 230))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)
    nvgRestore(vg)
    self:RenderSupports(vg, unit) -- 候选屋顶也不能盖住已安装支架。
    return valid
end

---@param vg NVGContextWrapper
---@param unit number
---@param roof integer?
---@param roofFlip boolean? nil 时每格根据各自侧邻判断可选方向；保留原第四参。
---@param warehouse boolean? 追加第五参，不与旧 roofFlip 混用。
---@param laboratory boolean? 保留第六参，沿用统一网格范围。
---@param matchmaking boolean? 追加第七参。
---@param greenhouse boolean? 追加第八参。
function BuildingGrid:RenderGrid(vg, unit, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
    if self.disposed or unit <= 0 then return end
    local minCol = math.ceil(-self.originX / self.cellWidth)
    local maxCol = math.floor((self.game.width - self.originX - self.cellWidth) / self.cellWidth)
    local minDrawRow, maxDrawRow = self.minRow, self.maxRow
    if self.game.run ~= nil and self.game.view then
        local first, last = self.game.view:GetVisibleRows(self, self.game.height * unit, unit)
        -- 挑战只遍历当前视口及一格余量，不能让每帧网格成本随整栋楼/空白预留高度增长。
        minDrawRow = math.max(self.minRow, first - 1)
        maxDrawRow = math.min(self.maxRow, last + 1)
    end
    nvgSave(vg)
    local top = self.game.view and self.game.view.minWorldY or 0
    nvgIntersectScissor(vg, 0, top * unit, self.game.width * unit, (self.game.groundY - top) * unit)
    for col = minCol, maxCol do
        for row = minDrawRow, maxDrawRow do
            if self:IsInBounds(col, row) then
                local valid = self:CanPlace(col, row, roof, roofFlip, warehouse, laboratory, matchmaking, greenhouse)
                local x, y, w, h = self:GetRect(col, row)
                nvgBeginPath(vg)
                nvgRect(vg, x * unit, y * unit, w * unit, h * unit)
                if valid then
                    nvgFillColor(vg, nvgRGBA(68, 190, 132, 25))
                    nvgFill(vg)
                end
                nvgStrokeColor(vg, valid and nvgRGBA(68, 190, 132, 100) or nvgRGBA(75, 106, 98, 35))
                nvgStrokeWidth(vg, 1)
                nvgStroke(vg)
            end
        end
    end
    nvgBeginPath(vg)
    nvgRect(vg, 0, top * unit, self.game.width * unit, (self.game.groundY - top) * unit)
    nvgStrokeColor(vg, nvgRGBA(75, 106, 98, 55))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
    nvgRestore(vg)
end

-- ============================================================================
-- 销毁
-- ============================================================================

--- 明确重置方案：依据新增窗洞的对象身份逆序删除，而不是按数量截断窗口数组。
--- 保留所有 seed/其他模块窗口，也兼容 Game 已将 windows 换回初始副本的情况。
--- 宿主应在清理等待猫咪后调用 Reset，以免猫咪仍引用已删除的窗口索引。
function BuildingGrid:Reset()
    local count = #self.blocks
    for index = #self.game.windows, 1, -1 do
        if self.ownedWindows[self.game.windows[index]] then table.remove(self.game.windows, index) end
    end
    for _, block in ipairs(self.blocks) do
        local column = self.cells[block.col]
        if column and column[block.row] == block then
            column[block.row] = nil
            if next(column) == nil then self.cells[block.col] = nil end
        end
        block.windowStart, block.windowEnd, block.windowCount = 0, 0, 0
    end
    self.blocks, self.ownedWindows = {}, {}
    self.highestOccupiedRow = 0
    if count > 0 then print(string.format("[楼层网格] 已清理 %d 个新增楼层，保留原楼占位与窗口", count)) end
end

--- Export 导出新增坐标、楼层类型与固定屋顶样式/朝向；不导出动态 front mode。
---@return FloorBlockPlacement[]
function BuildingGrid:Export()
    ---@type FloorBlockPlacement[]
    local list = {}
    for _, block in ipairs(self.blocks) do
        list[#list + 1] = { col = block.col, row = block.row, roof = block.roof,
            roofFlip = block.roofFlip, warehouse = block.warehouse, laboratory = block.laboratory,
            matchmaking = block.matchmaking, greenhouse = block.greenhouse }
    end
    return list
end

--- 顺序使用 Place，重试保留布局时先 Reset，再 Restore(Export 的快照)。
--- 缺新字段的旧快照仍是普通楼层；保存的 false 朝向也原样传回，不随机或重选。
--- 四类特殊仍经 CanPlace 关号/互斥校验，均允许组合 roof；旧档新字段缺失视为普通。
---@param list FloorBlockPlacement[]
---@return integer restored
function BuildingGrid:Restore(list)
    local restored = 0
    for _, entry in ipairs(list) do
        -- 挑战跨段用内存快照：Place之前按已经恢复的最高楼预留，不能先被旧minRow拒绝。
        -- 邻接/屋顶完整外框仍统一走Place，非法远隔格不会凭快照绕过结构规则。
        if self.game.run ~= nil and self.game.view then self.game.view:EnsureBuildSpace(self) end
        -- 旧版仅普通坐标可直接恢复；屋顶快照缺朝向时拒绝，不能按新邻居重新选向。
        if entry.roof == nil or type(entry.roofFlip) == "boolean" then
            if self:Place(entry.col, entry.row, entry.roof, entry.roofFlip, entry.warehouse, entry.laboratory,
                entry.matchmaking, entry.greenhouse) then
                restored = restored + 1
            end
        end
    end
    if self.game.run ~= nil and self.game.view then self.game.view:EnsureBuildSpace(self) end
    return restored
end

--- 仅清理自身数据；图片属于 UI 的共享 ImageCache，不在此释放共享资源。
function BuildingGrid:Dispose()
    self:Reset()
    self.cells, self.seeds = {}, {}
    self.disposed = true
end

local FloorBlocks = BuildingGrid
return FloorBlocks
