-- 从 scaffold-2d-physics 的 WorkshopGame 提取波次调度；场景、碰撞及猫实体仍归 Game。
-- 宿主契约：SpawnCat(index, magnetic) 注册实体/出生数并立即通知仓库；
-- ProtectCat(ball, index) 仅记 trapped/rescueCounted 与救援计数，不 caught/删除实体。
-- Game 初始化完毕后 New；PrepareWave/ReleaseWave 分别代理 Prepare/Release；重试时 Reset。
local Cats = require("Global.CatSpawner")

---@class CatWaveLaboratory
---@field key string 同一实验室整局最多一次；不进入关卡存盘。
---@field window integer 唯一的中窗（FloorBlocks 注册 laboratory=true、slot=2）。
---@field x number 世界坐标中窗中心，单位米。

---@class CatWaves
---@field game any
---@field laboratoryUsed table<string, boolean>
---@field gateBall any
---@field normalSpawned integer
---@field magneticSpawned integer
---@field normalSinceMag integer
---@field releasedBalls table<any, boolean>
---@field disposed boolean
---@field additionalAt number L8起追加请求在上一成功出生后至少延后0.3秒。
---@field guaranteeDeferred boolean 本局只提示一次不可达保证。
local CatWaves = {}
CatWaves.__index = CatWaves

local MAX_BALLS = 220
local GATE_POLL_TIME = 0.1

---@param game any
---@return CatWaves
function CatWaves.New(game)
    local self = setmetatable({}, CatWaves)
    self:Init(game)
    return self
end

---@param game any
function CatWaves:Init(game)
    self.game = game
    self.disposed = false
    self:Reset()
end

-- 这些是本局生产计数，不与 Game 的 resolved/intercepted/rescuedCats 混用。
-- 宿主先清猫/重置 spawned 等游戏计数，再 Reset；恢复布局也不恢复 laboratoryUsed。
function CatWaves:Reset()
    self.laboratoryUsed = {}
    self.gateBall = nil
    self.normalSpawned, self.magneticSpawned, self.normalSinceMag = 0, 0, 0
    self.releasedBalls = {}
    self.additionalAt, self.guaranteeDeferred = 0, false
end

---@param ball any
---@return boolean
local function IsProtected(ball)
    return ball.trapped == true or ball.rescueCounted == true
end

---@param ball any
---@return boolean
local function IsSettled(ball)
    return IsProtected(ball) or ball.missed == true or ball.intercepted == true
        or ball.caught == true or ball.safe == true
end

---@param ball any
---@return boolean
function CatWaves:CanRelease(ball)
    return ball.waiting == true and not IsProtected(ball) and not ball.matchmakingHeld
        and not ball.caught and not ball.missed and not ball.released and not self.releasedBalls[ball]
end

---@return boolean
function CatWaves:HasWaiting()
    for _, ball in ipairs(self.game.balls) do
        if self:CanRelease(ball) then return true end
    end
    return false
end

-- gate 只读碰撞结果；不在 Contact 内改 body/墙体，也不读取已回收节点的属性。
---@return boolean
function CatWaves:HasGate()
    local ball = self.gateBall
    if not ball then return false end
    if not IsSettled(ball) then
        for _, current in ipairs(self.game.balls) do
            if current == ball then return true end
        end
    end
    self.gateBall = nil
    return false
end

---@return integer
function CatWaves:Capacity()
    -- 无尽段额度会超过220；已归类留窗猫不能堵死尚未刷出的名额。
    return self.game.run and math.max(MAX_BALLS, self.game.config.catLimit) or MAX_BALLS
end

---@return boolean
function CatWaves:HasRoom()
    return not self.disposed and not self.game.paused and not self.game:IsFinished()
        and self.game.spawned < self.game.config.catLimit and #self.game.balls < self:Capacity()
end

---@param previous integer? 指定出生列时用于预检磁猫之后还有普通窗可接续。
---@return integer[]
function CatWaves:NormalCandidates(previous)
    local candidates, held = {}, {}
    for _, ball in ipairs(self.game.balls) do
        if ball.matchmakingHeld and not ball.caught and not ball.missed then
            held[ball.matchmakingWindow or ball.window] = true
        end
    end
    for index, window in ipairs(self.game.windows) do
        -- 保留原窗号；仓库、实验室、婚介所不出普通猫，已留猫窗不回退到重复出生。
        if not window.warehouse and not window.laboratory and not window.matchmaking and not held[index]
            and self.game:IsSpawnNear(index, previous) then
            candidates[#candidates + 1] = index
        end
    end
    return candidates
end

---@param candidates integer[]
---@return integer?
function CatWaves:PickNormal(candidates)
    if #candidates == 0 then return nil end
    local occupied = {}
    for _, ball in ipairs(self.game.balls) do
        if (ball.waiting or ball.trapped or ball.matchmakingHeld) and not ball.caught and not ball.missed then
            occupied[ball.matchmakingHeld and (ball.matchmakingWindow or ball.window) or ball.window] = true
        end
    end
    local free = {}
    for _, index in ipairs(candidates) do
        if not occupied[index] then free[#free + 1] = index end
    end
    -- 避占只是偏好：全被 waiting/trapped 占住时仍从合法普通窗选，不会卡死。
    local choices = #free > 0 and free or candidates
    return choices[math.random(1, #choices)]
end

---@return CatWaveLaboratory[]
function CatWaves:Laboratories()
    local labs = {}
    if (self.game.config.number or 0) < 6 then return labs end
    local seen = {}
    for index, window in ipairs(self.game.windows) do
        if window.laboratory and window.slot == 2 then
            local key = window.laboratoryKey
            if key and not seen[key] and not self.laboratoryUsed[key] then
                local x, _, w = self.game:GetWindowRect(index)
                labs[#labs + 1] = { key = key, window = index, x = x + w / 2 }
                seen[key] = true
            end
        end
    end
    return labs
end

-- 磁猫触发区域（仅水平，不看 Y、不依赖其他猫下落）：
--    lab.x - 2*cellWidth        lab 中窗        lab.x + 2*cellWidth
--             |==================|==================|
--             普通窗中心在闭区间内 -> 此次出生有一次概率判定。
-- 边界含等号；不同楼层同列仍有效；每 lab 成功一次后本局永久排除。
-- 磁猫若不是末猫，必须仍有可接续普通窗，不能把出生序列送入孤立实验室。
---@param lab CatWaveLaboratory
---@return boolean
function CatWaves:CanContinueFrom(lab)
    return self.game.spawned + 1 >= self.game.config.catLimit
        or #self:NormalCandidates(self.game:GetSpawnColumn(lab.window)) > 0
end

---@param windowIndex integer
---@param labs CatWaveLaboratory[]
---@return CatWaveLaboratory[]
function CatWaves:NearbyLaboratories(windowIndex, labs)
    local x, _, w = self.game:GetWindowRect(windowIndex)
    local center = x + w / 2
    local distance = 2 * self.game.buildingGrid.cellWidth
    local nearby = {}
    for _, lab in ipairs(labs) do
        if not self.laboratoryUsed[lab.key] and math.abs(center - lab.x) <= distance
            and self.game:IsSpawnNear(lab.window, self.game:GetSpawnColumn(windowIndex))
            and self:CanContinueFrom(lab) then
            nearby[#nearby + 1] = lab
        end
    end
    return nearby
end

---@param candidates integer[]
---@param labs CatWaveLaboratory[]
---@return integer[]
function CatWaves:GuaranteeCandidates(candidates, labs)
    local nearby = {}
    for _, index in ipairs(candidates) do
        if #self:NearbyLaboratories(index, labs) > 0 then nearby[#nearby + 1] = index end
    end
    return nearby
end

---@param index integer
---@return any ball
---@return boolean protected
function CatWaves:SpawnNormal(index)
    if not self:HasRoom() then return nil, false end
    local ball = self.game:SpawnCat(index, false)
    if not ball then return nil, false end
    self.normalSpawned = self.normalSpawned + 1
    self.normalSinceMag = self.normalSinceMag + 1
    local protected = self.game:ProtectCat(ball, index)
    return ball, protected == true or IsProtected(ball)
end

---@param lab CatWaveLaboratory
---@param gate boolean
---@return WorkshopBall? ball
function CatWaves:SpawnMagnetic(lab, gate)
    -- 每个入口都检查总数；正常猫已占用最后一个名额时同步磁猫直接拒绝。
    if self.laboratoryUsed[lab.key] or not self:HasRoom()
        or not self.game:IsSpawnNear(lab.window) or not self:CanContinueFrom(lab) then return nil end
    local ball = self.game:SpawnCat(lab.window, true)
    if not ball then return nil end
    self.laboratoryUsed[lab.key] = true
    self.magneticSpawned = self.magneticSpawned + 1
    self.normalSinceMag = 0
    self.game:ProtectCat(ball, lab.window)
    if gate and not IsSettled(ball) then self.gateBall = ball end
    print(string.format("[猫波次] 实验室 %s 出现磁猫 %d%s", lab.key, ball.id,
        gate and "，进入磁猫门控" or "，与普通猫同波"))
    return ball
end

---@param index integer
---@param labs CatWaveLaboratory[]
---@param forced CatWaveLaboratory?
---@param limit integer? 本波剩余名额（包括磁猫）；旧关卡不限制单波数。
---@return integer
function CatWaves:SpawnNearbyMagnetics(index, labs, forced, limit)
    local count = 0
    -- 保证的实验室优先占名额；不能让随机命中的另一个 lab 抢掉同步保证。
    if (not limit or limit > 0) and forced and self:SpawnMagnetic(forced, false) then count = count + 1 end
    local chance = math.max(0, math.min(1, self.game.config.magneticSpawnChance or 0.20))
    for _, lab in ipairs(self:NearbyLaboratories(index, labs)) do
        if not self:HasRoom() or (limit and count >= limit) then break end
        if not self.laboratoryUsed[lab.key] and math.random() < chance then
            if self:SpawnMagnetic(lab, false) then count = count + 1 end
        end
    end
    return count
end

-- L9 单一出生节拍：waitTime=0 同帧释放，仅在此处随机一次波间时间。
-- 未配置范围的 L1-8 仍读取旧 nextWaveTime，不改变测试时序。
---@return number
function CatWaves:NextWaveDelay()
    local config = self.game.config
    if config.nextWaveMin and config.nextWaveMax then
        local minimum = math.max(0, config.nextWaveMin)
        local maximum = math.max(minimum, config.nextWaveMax)
        return minimum + math.random() * (maximum - minimum)
    end
    return config.nextWaveTime or Cats.nextWaveTime
end

-- 保留宿主 ready/full/falling 计时协议；仅无邻窗的直接磁猫使用 magnetic_gate。
---@param count integer
function CatWaves:FinishPrepare(count)
    local game = self.game
    if count > 0 then game.wave = game.wave + 1 end
    if self:HasGate() then
        game.phase = "magnetic_gate"
        game.timer = self.gateBall.waiting and (game.config.waitTime or Cats.waitTime) or GATE_POLL_TIME
    elseif self:HasWaiting() then
        game.phase, game.timer = "ready", game.config.waitTime or Cats.waitTime
    elseif game.spawned >= game.config.catLimit then
        game.phase, game.timer = "falling", 1
    else
        game.phase, game.timer = "full", (game.config.number or 0) >= 8 and 1.3 or 1
        game:SetMessage(#game.balls >= self:Capacity() and "场内猫咪已满，猫咪离场后继续生成，或重新开始"
            or "没有可刷新猫咪的住户窗口")
    end
    if count > 0 then
        print(string.format("[猫波次] 第 %d 波出现 %d 只；普通 %d、磁猫 %d，总计 %d/%d，阶段 %s",
            game.wave, count, self.normalSpawned, self.magneticSpawned,
            game.spawned, game.config.catLimit, game.phase))
    end
end

-- L7+ 不沿旧关卡的“受保护就同步循环补猫”：留猫由宿主计数请求，帧末消费。
-- 普通与邻近磁猫共享单波预算及总 catLimit，L9 两猫同时出现、不会多生第三只。
---@param normalLimit integer
---@param totalLimit integer
---@return integer
function CatWaves:SpawnConfigured(normalLimit, totalLimit)
    local count = 0
    for _ = 1, normalLimit do
        if not self:HasRoom() or count >= totalLimit then break end
        local candidates, labs = self:NormalCandidates(), self:Laboratories()
        local index = self:PickNormal(candidates)
        if not index then break end
        local ball = self:SpawnNormal(index)
        if not ball then break end
        count = count + 1
        count = count + self:SpawnNearbyMagnetics(index, labs, nil, totalLimit - count)
    end
    return count
end

---@return integer
function CatWaves:PrepareConfigured()
    local config = self.game.config
    local maximum = math.max(1, math.floor(config.waveCatMax or 1))
    local minimum = math.max(1, math.min(maximum, math.floor(config.waveCatMin or 1)))
    local budget = minimum == maximum and minimum or math.random(minimum, maximum)
    -- L7/8 保持一普通猫与合法邻近磁猫同波；L9 的预算包括全部磁猫。
    local totalLimit = config.waveCatMax and budget or self.game.config.catLimit
    local count = self:SpawnConfigured(budget, totalLimit)
    self:FinishPrepare(count)
    if count > 0 and (config.waitTime or Cats.waitTime) <= 0 then self:Release() end
    return count
end

-- 受限追加请求，仅 Game 帧末调用；另一只 waiting 不阻挡，且不刷新原波等待倒计时。
-- 返回出生数而非请求数，宿主只在 >0 时消费一份 pendingNextCat。
---@return integer
function CatWaves:PrepareAdditional()
    if self.disposed or (self.game.config.number or 0) < 7 or not self:HasRoom() or self:HasGate()
        or self.game.clock < self.additionalAt then return 0 end
    local game = self.game
    local phase, timer, waiting = game.phase, game.timer, self:HasWaiting()
    local limit = game.config.waveCatMax and math.max(1, math.floor(game.config.waveCatMax))
        or game.config.catLimit
    local count = self:SpawnConfigured(1, limit)
    if count == 0 then return 0 end
    if (game.config.waitTime or Cats.waitTime) <= 0 then
        game.wave = game.wave + 1
        self:Release(true) -- 不推迟已安排的下一出生时刻。
        game.phase, game.timer = phase, timer
    elseif waiting or not self:HasWaiting() then
        game.wave = game.wave + 1
        game.phase, game.timer = phase, timer
    else
        self:FinishPrepare(count) -- 原本无 waiting 的追加猫必须正常进入 ready 才会被释放。
    end
    print(string.format("[猫波次] 留猫追加请求出生 %d 只，总计 %d/%d，原波计时不重置", count,
        game.spawned, game.config.catLimit))
    return count
end

---@return integer count 本次出现数，包含磁猫和立即受保护的猫；不是 Release 数。
function CatWaves:Prepare()
    if self.disposed or self.game.paused or self.game:IsFinished() then return 0 end
    local game = self.game
    -- 旧 Game:Update 的非 ready 分支仍调用 Prepare。gate 在最后一只占满额度时
    -- 也必须先处理其释放，不能被下面的 catLimit 拒绝挡住。
    if self:HasGate() then
        game.phase = "magnetic_gate"
        if self.gateBall.waiting then
            if game.timer <= 0 then self:Release() else return 0 end
        else
            game.timer = GATE_POLL_TIME
            return 0
        end
        if self:HasGate() then return 0 end
    end
    -- 幂等：已有非保护 waiting 就等原波释放，不靠重复 Prepare 堆猫或重置倒计时。
    if self:HasWaiting() then
        if game.phase ~= "ready" then
            game.phase, game.timer = "ready", game.config.waitTime or Cats.waitTime
        end
        return 0
    end
    if game.spawned >= game.config.catLimit then
        game.phase, game.timer = "falling", 1
        return 0
    end
    if game.clock < self.additionalAt then return 0 end -- L8起不能由追加后到期的旧波绕过0.3秒。
    if (game.config.number or 0) >= 7 then return self:PrepareConfigured() end

    local count = 0
    -- 全安全窗也不会递归：每轮至多一普通，加若干磁；最多迭代 catLimit 次。
    -- 每次成功都由 SpawnCat 增加 Game.spawned，失败直接退出，不会忙等。
    for _ = 1, game.config.catLimit do
        if not self:HasRoom() then break end
        local candidates, labs = self:NormalCandidates(), self:Laboratories()
        local remaining = game.config.catLimit - game.spawned
        local guarantee = game.config.magneticGuarantee and self.magneticSpawned == 0 and #labs > 0
            and (self.normalSpawned >= 3 or remaining <= 1 or #candidates == 0)
        ---@type CatWaveLaboratory?
        local forced = nil
        ---@type integer?
        local index = nil
        if guarantee then
            local nearby = self:GuaranteeCandidates(candidates, labs)
            ---@type CatWaveLaboratory[]
            local direct = {}
            for _, lab in ipairs(labs) do
                if game:IsSpawnNear(lab.window) and self:CanContinueFrom(lab) then direct[#direct + 1] = lab end
            end
            if (#nearby == 0 or remaining < 2 or self:Capacity() - #game.balls < 2) and #direct > 0 then
                -- 直接保证也必须对上一真实出生列合法；末名额磁猫仍保留原门控。
                local lab = assert(direct[math.random(1, #direct)], "合法实验室候选不能为空")
                if self:SpawnMagnetic(lab, true) then count = count + 1 else break end
                if self:HasGate() then break end
                goto continue
            elseif #nearby > 0 and remaining >= 2 and self:Capacity() - #game.balls >= 2 then
                index = self:PickNormal(nearby)
                if not index then break end
                local eligible = self:NearbyLaboratories(index, labs)
                forced = eligible[math.random(1, #eligible)]
            else
                -- 新列距优先于旧强制保证：不可达时继续合法普通猫，不越距、不忙等。
                index = self:PickNormal(candidates)
                if not self.guaranteeDeferred then
                    self.guaranteeDeferred = true
                    print("[猫波次] 磁猫保证暂缓：没有满足相邻窗列限制的实验室")
                end
            end
        else
            index = self:PickNormal(candidates)
        end
        if not index then break end
        local ball, protected = self:SpawnNormal(index)
        if not ball then break end
        count = count + 1
        -- 出生即判定每个未出 lab，不以 Release、其它猫下落或 Y 距离为前提。
        count = count + self:SpawnNearbyMagnetics(index, labs, forced)
        -- 安全普通仍是真实体、已计出生：马上补下一普通；同步磁可累积 waiting。
        if not protected then break end
        ::continue::
    end
    self:FinishPrepare(count)
    return count
end

---@param preserveTimer boolean? 追加出生只释放，不随机/重置既定下一波计时。
---@return integer count 实际首次释放的猫数（包括磁猫），不含防盗窗/婚介所内猫。
function CatWaves:Release(preserveTimer)
    if self.disposed or self.game.paused or self.game:IsFinished() then return 0 end
    local game = self.game
    local count = 0
    for _, ball in ipairs(game.balls) do
        if game:IsFinished() then break end
        if self:CanRelease(ball) then
            -- 玩家在等待期新装防盗窗也有效；ProtectCat 幂等且不改物理实体。
            local protected = game:ProtectCat(ball, ball.window)
            if game:IsFinished() then break end
            if not protected and self:CanRelease(ball) then
                Cats.Release(ball)
                ball.released = true
                self.releasedBalls[ball] = true
                count = count + 1
                if game.specialFloors then game.specialFloors:OnCatReleased(ball) end
            end
        end
    end
    game.released = game.released + count
    if not preserveTimer then
        if self:HasGate() then
            game.phase, game.timer = "magnetic_gate", GATE_POLL_TIME
        else
            game.phase, game.timer = "falling", self:NextWaveDelay()
        end
    end
    if count > 0 then print(string.format("[猫波次] 首次释放 %d 只，累计释放 %d", count, game.released)) end
    return count
end

-- 只释放调度引用；Game 负责移除/Dispose 猫节点和物理场景。
function CatWaves:Dispose()
    if self.disposed then return end
    self:Reset()
    self.game = nil
    self.disposed = true
end

return CatWaves
