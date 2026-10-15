-- 共享猫咪生成、随机选窗、等待与释放；Home 和各关卡使用同一程序。
-- 术语：“跳窗”= Release（等待后下落）；“窗洞”= 各场景的窗户矩形配置。
local Cats = {}
Cats.radius = 0.20 -- 直径 0.4 米。
Cats.waitTime = 1.5 -- Home 和关卡共用，从出现到下落等待 1.5 秒。
Cats.nextWaveTime = 2.6

function Cats.Create(scene, windows, getWindowRect, id, color, selectedWindow, magnetic)
    local windowIndex = selectedWindow or math.random(1, #windows)
    local x, y, w, h = getWindowRect(windowIndex)
    x, y = x + w / 2, y + h / 2
    local node = scene:CreateChild("Ball")
    node:SetPosition2D(x, -y)
    local body = node:CreateComponent("RigidBody2D")
    body.bodyType = BT_DYNAMIC
    body.bullet = true
    body.linearDamping, body.angularDamping = 0.09, 0.12
    local shape = node:CreateComponent("CollisionCircle2D")
    shape.radius = Cats.radius
    shape.categoryBits = 8
    shape.density, shape.friction, shape.restitution = 1, 0.38, 0.36
    node.enabled = false
    print(string.format("[猫咪] 刷新窗户 %d，位置 %.2f, %.2f", windowIndex, x, y))
    return {
        id = id, node = node, body = body, shape = shape, radius = Cats.radius, previousX = x, previousY = y,
        magnetic = magnetic == true, magneticWindowHeight = h, magneticTouchedCat = false,
        trapped = false, rescueCounted = false, resolvedCounted = false, magneticHeld = false,
        missed = false, caught = false, rolling = false, rollDirection = 0, rollAngle = 0,
        color = color or 1, waiting = true, window = windowIndex, intercepted = false, flash = 0,
        parachute = false, safe = false,
    }
end

function Cats.Release(ball)
    ball.waiting = false
    ball.node.enabled = true
    ball.body.awake = true
    ball.body.linearVelocity = Vector2((math.random() - 0.5) * 0.30, 0)
end

function Cats.Remove(ball)
    ball.node:Remove()
    ball.node:Dispose()
end

return Cats

