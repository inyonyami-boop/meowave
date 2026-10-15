-- 本局猫分类；沿用 WorkshopGame 物理脚手架，不保存到玩家档。
-- 七类按对象身份互斥归类，永久终态只来自真实接取/漏猫；盆罚不产生猫。
---@class CatOutcomeBall : WorkshopBall
---@field pairResetPending boolean?
---@class CatOutcomeGame : WorkshopGame
---@field balls CatOutcomeBall[]
---@field catOutcomes table<WorkshopBall, string?>
---@field finishCount integer
---@field magnetic MagneticCats
---@field specialFloors SpecialFloors
---@field IsStableCat fun(self: CatOutcomeGame, ball: WorkshopBall): boolean
---@field supportContacts table<WorkshopBall, table<number, integer?>?>
local Rules = {}

---@param game CatOutcomeGame
---@param ball CatOutcomeBall
---@return boolean
local function Live(game, ball)
    return not ball.removed and not ball.caught and not ball.missed and not ball.waiting
        and ball.node.enabled and game.ballByNode[ball.node.ID] == ball
end

-- 支撑设计（逻辑Y向下）：○猫 -> 当前启用栅栏胶囊，或下方休眠猫 -> 栅栏。
-- 检测真实圆/胶囊接触，且支撑点在猫下方；侧擦、悬空、失效ghost不算。
-- 猫堆只向下递归，seen防环；不得使用历史intercepted作为当前承托证据。
---@param game CatOutcomeGame
---@param ball CatOutcomeBall
---@param seen table<WorkshopBall, boolean>
---@return boolean
local function Supported(game, ball, seen)
    if not Live(game, ball) or ball.pairResetPending then return false end
    local link = game.magnetic.cats[ball --[[@as MagneticCat]]]
    local state = game.specialFloors.states[ball --[[@as SpecialFloorBall]]]
    local controlled = ball.parachute or (state and state.slowCap)
        or (ball.magnetic and link and link.group.active and link.group.root == ball)
    local stableControlled = controlled and game:IsStableCat(ball)
    -- 伞/植物/活磁组root可能被控制器唤醒；仍须稳定样本与当前实栏，不泛化自由低速猫。
    if seen[ball] or (not stableControlled and not game:IsRestingCat(ball)) then return false end
    seen[ball] = true
    local position = ball.node.position2D
    local x, y = position.x, -position.y
    for _, fence in ipairs(game.fences) do
        if fence.node.enabled then
            local cosine, sine = math.cos(fence.angle), math.sin(fence.angle)
            local half = (fence.length - fence.thickness) / 2
            local along = math.max(-half, math.min(half,
                (x - fence.x) * cosine + (y - fence.y) * sine))
            local sx, sy = fence.x + along * cosine, fence.y + along * sine
            local distance = ball.radius + fence.thickness / 2 + 0.015
            local contacts = game.supportContacts[ball]
            local actualContact = contacts and (contacts[fence.node.ID] or 0) > 0
            if sy > y + 0.02 and (sx - x)^2 + (sy - y)^2 <= distance^2
                and (not stableControlled or actualContact) then return true end
        end
    end
    for _, other in ipairs(game.balls) do
        if other ~= ball and not seen[other] and Live(game, other) then
            local below = other.node.position2D
            local dy, dx = -below.y - y, below.x - x
            local distance = ball.radius + other.radius + 0.015
            local contacts = game.supportContacts[ball]
            local actualContact = contacts and (contacts[other.node.ID] or 0) > 0
            if dy > 0.02 and dx^2 + dy^2 <= distance^2 and (not stableControlled or actualContact)
                and Supported(game, other, seen) then return true end
        end
    end
    return false
end

---@param game CatOutcomeGame
---@param ball CatOutcomeBall
---@return boolean
function Rules.OnFence(game, ball)
    return Supported(game, ball, {})
end

---@param game CatOutcomeGame
---@param ball CatOutcomeBall
---@return string?
function Rules.Category(game, ball)
    local terminal = game.catOutcomes[ball]
    if terminal then return terminal end
    if not Live(game, ball) or ball.pairResetPending then return nil end
    if ball.trapped then return "security_window" end
    if ball.matchmakingHeld then return "matchmaking" end
    if Rules.OnFence(game, ball) then return "fence" end
    local source = game.magnetic:GetAttractionSource(ball --[[@as MagneticCat]], "cat")
    if source then
        if source.trapped then return "security_magnetic" end
        if Rules.OnFence(game, source --[[@as WorkshopBall]]) then return "fence_magnetic" end
    end
    return nil
end

---@param game CatOutcomeGame
---@return integer
function Rules.Count(game)
    if game.finishFinalized then return game.finishCount end
    local count = 0
    for _ in pairs(game.catOutcomes) do count = count + 1 end
    for _, ball in ipairs(game.balls) do
        if not game.catOutcomes[ball] and Rules.Category(game, ball) then count = count + 1 end
    end
    return count
end

return Rules
