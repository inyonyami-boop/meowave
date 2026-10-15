-- L10 无尽挑战账本：宿主只在真实成功事件后通知，不改猫/窗口/仓库身份或旧统计。
-- 每个正向事件独立更新 lastGain；联收递归不合并猫、婚介奖励和道具的加分。
-- 阶段配置/切换由 RescueLevel 管理；跨段只保累计值，不保上一段原生对象。
local Save = require("Global.LevelSave")

---@class ChallengePairToken
---@field first WorkshopBall
---@field second WorkshopBall
---@field firstNode Node
---@field secondNode Node
---@field captured boolean
---@field credited boolean

---@class ChallengeRun
---@field spawned integer
---@field missed integer
---@field caught integer
---@field score integer
---@field peak integer
---@field lastGain integer
---@field highest integer
---@field finished boolean
---@field saved boolean
---@field segment integer
---@field spawnSeen table<WorkshopBall, Node?>
---@field missSeen table<WorkshopBall, boolean>
---@field caughtSeen table<WorkshopBall, boolean>
---@field claimSeen table<string, boolean>
---@field potSeen table<FlowerPot, boolean>
---@field pairSeen table<ChallengePairToken, boolean>
---@field catPairs table<WorkshopBall, ChallengePairToken[]>
local Run = {}
Run.__index = Run

---@return ChallengeRun
function Run.New()
    local self = setmetatable({}, Run)
    self:init()
    return self
end

function Run:init()
    self.spawned, self.missed, self.caught = 0, 0, 0
    self.score, self.peak, self.lastGain = 0, 0, 0
    self.highest = Save.LoadHighScore() or 0
    self.finished, self.saved, self.segment = false, false, 0
    self.spawnSeen, self.missSeen, self.caughtSeen = {}, {}, {}
    self.claimSeen, self.potSeen, self.pairSeen, self.catPairs = {}, {}, {}, {}
end

--- 只在旧 Game 已停止后、新阶段出生前调用；不再次累计旧 Game 的计数。
---@param segment integer?
function Run:BeginStage(segment)
    if self.finished then return end
    self.segment = segment or (self.segment + 1)
    self.spawnSeen, self.missSeen, self.caughtSeen = {}, {}, {}
    self.claimSeen, self.potSeen, self.pairSeen, self.catPairs = {}, {}, {}, {}
end

---@param self ChallengeRun
---@param amount integer
local function AddGain(self, amount)
    self.score = self.score + amount
    self.lastGain = amount
    self.peak = math.max(self.peak, self.score)
    self.highest = math.max(self.highest, self.peak)
end

---@param ball WorkshopBall
---@return boolean
function Run:OnSpawn(ball)
    if self.finished or not ball or not ball.node or self.spawnSeen[ball] then return false end
    self.spawnSeen[ball] = ball.node
    self.spawned = self.spawned + 1
    return true
end

---@param ball WorkshopBall
---@return boolean
function Run:OnMiss(ball)
    if self.finished or self.spawnSeen[ball] ~= ball.node or not ball.missed
        or self.missSeen[ball] or self.caughtSeen[ball] then return false end
    self.missSeen[ball] = true
    self.missed = self.missed + 1
    return true
end

--- 每次真实婚介事件拥有独立 token；联收组的重建/合并不改变该事件的两个端点。
---@param first WorkshopBall
---@param second WorkshopBall
---@return ChallengePairToken?
function Run:OnPair(first, second)
    if self.finished or first == second or not first or not second
        or self.spawnSeen[first] ~= first.node or self.spawnSeen[second] ~= second.node
        or first.caught or first.missed or second.caught or second.missed then return nil end
    return { first = first, second = second, firstNode = first.node, secondNode = second.node,
        captured = false, credited = false }
end

---@param self ChallengeRun
---@param token ChallengePairToken
local function TryPair(self, token)
    if not token.captured or token.credited or self.spawnSeen[token.first] ~= token.firstNode
        or self.spawnSeen[token.second] ~= token.secondNode
        or not self.caughtSeen[token.first] or not self.caughtSeen[token.second] then return end
    token.credited = true -- 先锁定，再发独立 +2；递归的另一端无法再次兑现。
    AddGain(self, 2)
end

--- 在 SpecialFloors 原子 detach 前冻结真配对证据；不拿活组大小推算婚介次数。
---@param tokens ChallengePairToken[]?
function Run:CapturePairs(tokens)
    if self.finished then return end
    for _, token in ipairs(tokens or {}) do
        if not self.pairSeen[token] then
            self.pairSeen[token], token.captured = true, true
            for _, cat in ipairs({ token.first, token.second }) do
                local entries = self.catPairs[cat] or {}
                entries[#entries + 1] = token
                self.catPairs[cat] = entries
            end
        end
        TryPair(self, token)
    end
end

---@param ball WorkshopBall
---@return boolean
function Run:OnCaught(ball)
    if self.finished or self.spawnSeen[ball] ~= ball.node or not ball.caught
        or self.caughtSeen[ball] or self.missSeen[ball] then return false end
    self.caughtSeen[ball] = true
    self.caught = self.caught + 1
    AddGain(self, ball.magnetic and 8 or 5)
    for _, token in ipairs(self.catPairs[ball] or {}) do TryPair(self, token) end
    return true
end

--- 仅 WarehouseDrops 成功发放且属于人物真实收取时调用；同仓库多件只给一次。
---@param drop WarehouseDrop
---@return boolean
function Run:OnClaim(drop)
    local key = drop.warehouse.key
    if self.finished or not drop.collected or self.claimSeen[key] then return false end
    self.claimSeen[key] = true
    AddGain(self, 1)
    return true
end

--- 花盆命中已由宿主锁 pot.hit；独立于旧 intercepted，累计真 caught 为零时也免伤。
---@param pot FlowerPot
---@return boolean damaged false 时宿主必须拦截整个玩家伤害分支。
function Run:OnPotHit(pot)
    if self.finished or self.potSeen[pot] then return false end
    self.potSeen[pot] = true
    if self.score <= 0 or self.caught <= 0 then return false end
    self.score = math.max(0, self.score - self.lastGain)
    -- 惩罚不改 lastGain 或 peak；下一盆仍扣最近一次真实正向事件。
    return true
end

---@return boolean
function Run:IsFailed()
    return self.spawned > 0 and self.missed * 4 >= self.spawned
end

---@return {spawned: integer, missed: integer, caught: integer, score: integer, peak: integer, highest: integer, lastGain: integer}
function Run:Totals()
    return { spawned = self.spawned, missed = self.missed, caught = self.caught, score = self.score,
        peak = self.peak, highest = self.highest, lastGain = self.lastGain }
end

--- 整次挑战结束才调用；按 run 峰值而非盆扣后的结尾分保存，不记录旧通关/库存统计。
---@return integer score
---@return integer highest
---@return boolean saved
function Run:Finish()
    if self.finished then return self.score, self.highest, self.saved end
    self.finished = true
    local old = Save.LoadHighScore()
    self.highest = math.max(self.highest, old or 0, self.peak)
    self.saved = Save.SaveHighScore(self.peak)
    self.spawnSeen, self.missSeen, self.caughtSeen = {}, {}, {}
    self.claimSeen, self.potSeen, self.pairSeen, self.catPairs = {}, {}, {}, {}
    print(string.format("[挑战积分] 本次 %d，峰值 %d，最高 %d，保存=%s",
        self.score, self.peak, self.highest, tostring(self.saved)))
    return self.score, self.highest, self.saved
end

return Run
