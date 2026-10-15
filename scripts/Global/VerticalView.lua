-- 纵向视角与双层视差：只改变渲染/指针换算，不移动物理世界。
---@class FarBackgroundRect
---@field x number
---@field y number
---@field w number
---@field h number
---@field progress number 原图区间归一化视角（0最低，1原图最高）；挑战延展保持1。

---@class VerticalView
---@field offset number
---@field minWorldY number
---@field maxOffset number
---@field wheelVelocity number
---@field farTravel number
---@field farCoverOffset number
---@field game FloorBlocksGame
---@field baseMaxOffset number 普通关原上限；挑战扩建不能重算原背景的视差速度。
local View = {}
View.__index = View

---@return VerticalView
function View.New(game)
    ---@type VerticalView
    local self = setmetatable({}, View)
    self:Init(game)
    return self
end

function View:Init(game)
    self.game = game
    self.width, self.groundY = game.width, game.groundY
    self.offset, self.wheelVelocity = 0, 0 -- 零为原有最低视角，正数表示向楼房高处看。
    -- 滚轮控制速度而不是目标视角；单个大增量/同帧事件突发也不会积压到顶部。
    -- 输入响应统一为原来的8倍；速度上限同倍放大，避免连续滚轮被旧上限裁掉。
    self.inputSensitivity = 8
    self.wheelImpulse, self.wheelSpeed, self.wheelDamping = 0.65 * self.inputSensitivity, 1.20 * self.inputSensitivity, 6.0
    self.middleFactor = 0.60
    self.imageWidth, self.imageHeight = 1080, 1920
    self.middleGroundPixel = 1880
    self.middleHeight = self.width * self.imageHeight / self.imageWidth
    self.middleTop = self.groundY - self.width * self.middleGroundPixel / self.imageWidth
    -- 中景顶边到达画面顶边时停止；仅放大输入响应，保留滚动边界和DPR换算。
    self.maxOffset = math.max(0, -self.middleTop / self.middleFactor)
    self.baseMaxOffset = self.maxOffset
    self.minWorldY = -self.maxOffset
    -- 源图实测：Middle全alpha<255包围(219,0)-(914,1880)，主连通域底1879。
    -- Far全alpha=255。按完整透明包围确定横向覆盖，不按整幅中景宽度放大远景。
    self.middleOpening = { left = 219, top = 0, right = 914, bottom = 1880 }
    self.farOverlap, self.farEdgeMargin = 0.12, 0.10 -- 米；约12.8px侧重叠/10.7px顶底余量。
    self.farLeft = self.width * self.middleOpening.left / self.imageWidth - self.farOverlap
    self.farWidth = self.width * (self.middleOpening.right - self.middleOpening.left)
        / self.imageWidth + self.farOverlap * 2
    self.farHeight = self.farWidth * self.imageHeight / self.imageWidth -- 1080:1920严格等比。
    self.middleOpeningBottom = self.middleTop + self.width * self.middleOpening.bottom / self.imageWidth
    -- 初始底5.50：略低于grass绘制上缘5.15，并覆盖花草透明尖端下面的中景洞底5.40。
    self.farBottom = self.middleOpeningBottom + self.farEdgeMargin
    self.farTop = self.farBottom - self.farHeight
    self.farTravel = math.max(0, -self.farEdgeMargin - self.farTop)
    self.farFactor = self.maxOffset > 0 and self.farTravel / self.maxOffset or 0
    -- 初段必须跟住透明洞底，直到它越过视口底；否则缩小后较慢远景会露中景下方空带。
    -- 余下行程由maxOffset算出速度：连续两段、始终正向，不使用猜测的固定0.25。
    self.farCoverOffset = math.min(self.maxOffset,
        math.max(0, (game.height - self.middleOpeningBottom) / self.middleFactor))
    self.farCoverTravel = math.min(self.farTravel, self.farCoverOffset * self.middleFactor)
    self.farTailFactor = self.maxOffset > self.farCoverOffset
        and (self.farTravel - self.farCoverTravel) / (self.maxOffset - self.farCoverOffset) or 0
    print(string.format("[纵向视角] 上限 %.3f 米，中景顶边 %.3f 米；远景rect %.3f,%.3f %.3fx%.3f，尾段速度 %.4f",
        self.maxOffset, self.middleTop, self.farLeft, self.farTop, self.farWidth, self.farHeight,
        self.farTailFactor))
end

--- 挑战每段供给前/旧楼 Restore 后调用；只有 game.run 非nil才允许上移构建顶边。
--- 扩建幂等且只增长，不挪当前视角、不修改原楼映射，也不在此重建物理墙体。
---@param grid BuildingGrid
---@param reserveRows integer? 至少3份新楼层，Grid额外计入完整屋顶占格。
---@return boolean changed
function View:EnsureBuildSpace(grid, reserveRows)
    if self.game.run == nil or grid.game.run == nil or grid.disposed then return false end
    assert(grid.game == self.game, "挑战构建空间必须使用同一局的视角与网格")
    local top = grid:GetBuildTop(reserveRows)
    assert(top == top and top > -math.huge and top < math.huge, "挑战构建顶边必须为有限世界坐标")
    local maxOffset = math.max(self.baseMaxOffset, self.maxOffset, -top)
    local minWorldY = -maxOffset
    local minRow = math.ceil((minWorldY - grid.originY) / grid.cellHeight)
    local changed = maxOffset > self.maxOffset or minRow < grid.minRow
    self.maxOffset, self.minWorldY = maxOffset, minWorldY
    grid.minRow = math.min(grid.minRow, minRow)
    if changed then
        print(string.format("[挑战空间] 构建顶边 %.3f 米，合法最小行 %d，视角上限 %.3f 米",
            self.minWorldY, grid.minRow, self.maxOffset))
    end
    return changed
end

function View:SetOffset(value)
    if type(value) ~= "number" or value ~= value then return false end
    local offset = math.max(0, math.min(self.maxOffset, value))
    local changed = math.abs(offset - self.offset) > 0.000001
    self.offset, self.wheelVelocity = offset, 0
    return changed
end

function View:Scroll(wheel)
    if type(wheel) ~= "number" or wheel ~= wheel or wheel == 0
        or wheel <= -math.huge or wheel >= math.huge then return false end
    -- 平台可能给出刻度，也可能给出像素级大值；这里只取有限方向强度，不把原值当米数。
    local direction = wheel > 0 and 1 or -1
    if (direction < 0 and self.offset <= 0) or (direction > 0 and self.offset >= self.maxOffset) then
        self.wheelVelocity = 0
        return false
    end
    local velocity = self.wheelVelocity * direction < 0 and 0 or self.wheelVelocity
    self.wheelVelocity = math.max(-self.wheelSpeed, math.min(self.wheelSpeed,
        velocity + direction * math.min(1, math.abs(wheel)) * self.wheelImpulse))
    return true
end

function View:Update(dt)
    if type(dt) ~= "number" or dt ~= dt or dt <= 0 or dt >= math.huge then return false end
    if math.abs(self.wheelVelocity) < 0.002 * self.inputSensitivity then
        self.wheelVelocity = 0
        return false
    end
    -- 指数衰减的精确积分：连续逐帧移动，限速与帧率无关；停止滚轮后短距离自然停下。
    local decay = math.exp(-self.wheelDamping * dt)
    local distance = self.wheelVelocity * (1 - decay) / self.wheelDamping
    local offset = math.max(0, math.min(self.maxOffset, self.offset + distance))
    local changed = offset ~= self.offset
    self.offset = offset
    self.wheelVelocity = (offset <= 0 or offset >= self.maxOffset) and 0 or self.wheelVelocity * decay
    return changed
end

function View:Pan(deltaPixels, unit)
    return self:SetOffset(self.offset + deltaPixels / math.max(1, unit) * self.inputSensitivity)
end

function View:ScreenToWorld(x, y, rect)
    local unit = math.max(1, rect.w) / self.width
    return (x - rect.x) / unit, (y - rect.y) / unit - self.offset
end

function View:GetVisibleRows(grid, viewportHeight, unit)
    local top = -self.offset
    local bottom = math.min(self.groundY, viewportHeight / math.max(1, unit) - self.offset)
    return math.floor((top - grid.originY) / grid.cellHeight),
        math.floor((bottom - grid.originY) / grid.cellHeight)
end

---@return FarBackgroundRect
function View:GetFarRect()
    -- 原区间永远用初始上限：挑战增加maxOffset也不能改变低处背景位置/速度/progress。
    local offset = math.max(0, math.min(self.baseMaxOffset, self.offset))
    local rise = offset <= self.farCoverOffset and math.min(self.farCoverTravel, offset * self.middleFactor)
        or self.farCoverTravel + (offset - self.farCoverOffset) * self.farTailFactor
    local extra = self.game.run ~= nil and math.max(0, self.offset - self.baseMaxOffset) or 0
    -- 超出原图顶边后复用同一远景，取模避免把无尽世界坐标直接交给NanoVG。
    local extension = extra > 0 and (extra * self.farTailFactor) % self.farHeight or 0
    return { x = self.farLeft, y = self.farTop + rise + extension, w = self.farWidth, h = self.farHeight,
        progress = self.baseMaxOffset > 0 and offset / self.baseMaxOffset or 0 }
end

function View:DrawBackground(vg, art, game, unit, shake)
    local far = self:GetFarRect() -- world米单位；Art只消费此rect，不重新猜另一套scale/anchor。
    local extra = self.game.run ~= nil and math.max(0, self.offset - self.baseMaxOffset) or 0
    if extra <= 0 then
        -- 普通1–9及挑战原高度区间完全沿用原图/原公式/原绘制次序。
        art.FarBackground(vg, { x = far.x * unit, y = far.y * unit + shake.y * 0.35,
            w = far.w * unit, h = far.h * unit, progress = far.progress })
        local width, height = self.width * unit, self.middleHeight * unit
        art.Image(vg, "Global/Images/BackgroundMiddle.png", shake.x,
            (self.middleTop + self.offset * self.middleFactor) * unit + shake.y, width, height)
        return
    end
    -- 只画视口附近的远景tile，竖向镜像使相邻图边相接；跨整图时保持相同图案而不是闪回。
    local farCycle = math.floor(extra * self.farTailFactor / self.farHeight)
    local lastFar = math.ceil((game.height - far.y) / far.h)
    for tile = -1, lastFar do
        local y = (far.y + tile * far.h) * unit + shake.y * 0.35
        local flipped = (farCycle - tile) % 2 ~= 0
        nvgSave(vg)
        if flipped then nvgTranslate(vg, 0, y + far.h * unit); nvgScale(vg, 1, -1) end
        art.FarBackground(vg, { x = far.x * unit, y = flipped and 0 or y,
            w = far.w * unit, h = far.h * unit, progress = far.progress })
        nvgRestore(vg)
    end
    -- 原中景顶边越过y=0才追加上方内容。只复用原图顶部1/4，避免把地面花草铺到高空。
    -- 裁剪条带仅是运行时绘制，不改素材/缓存；往上条带首尾镜像，接缝复用同一原图边。
    local strip = self.middleHeight / 4
    local rise = extra * self.middleFactor
    local middleY = self.middleTop + self.baseMaxOffset * self.middleFactor + rise
    local firstStrip = math.max(1, math.floor((middleY - game.height) / strip) + 1)
    local lastStrip = math.ceil(middleY / strip)
    for tile = firstStrip, lastStrip do
        local y = (middleY - tile * strip) * unit + shake.y
        nvgSave(vg)
        nvgIntersectScissor(vg, shake.x, y, self.width * unit, strip * unit)
        nvgTranslate(vg, shake.x, tile % 2 == 1 and y + strip * unit or y)
        if tile % 2 == 1 then nvgScale(vg, 1, -1) end
        art.Image(vg, "Global/Images/BackgroundMiddle.png", 0, 0,
            self.width * unit, self.middleHeight * unit)
        nvgRestore(vg)
    end
    -- 原图保留在最低tile；远离视口时不把巨大的世界坐标交给NanoVG。
    if middleY <= game.height then
        art.Image(vg, "Global/Images/BackgroundMiddle.png", shake.x,
            middleY * unit + shake.y, self.width * unit, self.middleHeight * unit)
    end
end

return View
