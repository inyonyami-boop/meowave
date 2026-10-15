-- ==================== 共享通关判定与结局动画模块 ====================
-- 术语：“黑锦旗”= 失败横幅 FailureBanner.png；“威胁信”= 信封三段动画
-- （EnvelopeClosed→EnvelopeOpen→Letter）；“锦旗”未加颜色时指胜利横幅 VictoryBanner.png。
local UI = require("urhox-libs/UI")
local Art = require("Global.WorkshopArt")
local Text = require("Global.TextLines")
local Result = {}
---@type Panel?
local overlay = nil
---@type number
local clock = 0
local mode = "victory"
local selectedText = ""
---@type Panel?
local textPanel = nil
local actions = {}
---@type number
local buttonClock = 0
local bannerDuration, bannerRiseDistance = 1.1, 713
---@type Panel?
local homeButton = nil
---@type Panel?
local sideButton = nil
local scoreResult = false
local doneCalled = false
---@type string[]
local scoreLines = {}

-- 结算文字：不绘制椭圆光晕，仅使用 Home 救援入口相同的透明度周期。
local function PulseButton(id, left, text, fontSize, onClick)
    local label = UI.Label {
        id = id .. "Text", width = "100%", height = "100%", text = text,
        fontSize = fontSize, textAlign = "center", fontColor = { 255, 240, 205, 255 },
        pointerEvents = "none",
    }
    local panel = UI.Panel {
        id = id, position = "absolute", left = left, top = 742, width = 220, height = 46,
        pointerEvents = "box-only", opacity = 0.775, children = { label },
        onClick = function(self, event)
            if buttonClock < 0.5 or (scoreResult and (clock < 2.7 or actions.done))
                or (event and not event:IsPrimaryAction()) then return end
            onClick()
        end,
    }
    -- 点击容器保持透明；周期闪烁在 Update 中统一推进，不覆写文字绘制。
    function panel:Render(vg)
    end
    return panel
end

function Result.IsVictory(leaked, levelNumber)
    return leaked <= levelNumber
end

local function AddVertical(parent, value, x)
    local chars = Text.Characters(value)
    local size = math.min(44, 405 / math.max(1, #chars) / 1.45)
    for index, char in ipairs(chars) do
        parent:AddChild(UI.Label { position = "absolute", left = x, top = 112 + (index - 1) * size * 1.45,
            width = 90, height = size * 1.45, text = char, fontSize = size, textAlign = "center",
            fontColor = { 235, 206, 123, 255 }, pointerEvents = "none" })
    end
end

local function Banner(parent)
    -- 固定最终布局，只平移公共父容器；图片与文字不各自计算入场坐标。
    local imagePath = mode == "victory" and "Global/Images/VictoryBanner.png"
        or "Global/Images/FailureBanner.png"
    local bannerPanel = UI.Panel { id = "resultBanner", position = "absolute", left = 399, top = 87,
        width = 482, height = 626, translateY = bannerRiseDistance,
        pointerEvents = "none", visible = false }
    function bannerPanel:Render(vg)
        local rect = self:GetAbsoluteLayout()
        Art.Image(vg, imagePath, rect.x, rect.y, rect.w, rect.h)
    end
    textPanel = bannerPanel
    local right, left = selectedText:match("^(.-)/(.*)$")
    if not right then right, left = selectedText, "" end
    AddVertical(textPanel, right, 282)
    AddVertical(textPanel, left, 112)
    parent:AddChild(textPanel)
    -- 完整子树建好后同时显示，不单独启用锦旗或任一列文字。
    textPanel:SetVisible(true)
end

local function Letter(parent)
    textPanel = UI.Panel { position = "absolute", left = 405, top = 75, width = 470, height = 680,
        pointerEvents = "none", overflow = "hidden", visible = false, opacity = 0,
        backgroundImage = "Global/Images/Letter.png" }
    if scoreResult then
        for index, value in ipairs(scoreLines) do
            textPanel:AddChild(UI.Label {
                id = "challengeResultLine" .. tostring(index), position = "absolute", left = 54,
                top = 170 + (index - 1) * 80, width = 362, height = 64,
                text = value, fontSize = math.min(24, 250 / math.max(1, utf8.len(value) or #value)),
                textAlign = "center", verticalAlign = "middle",
                fontColor = { 53, 39, 30, 255 }, pointerEvents = "none",
            })
        end
        parent:AddChild(textPanel)
        return
    end
    local chars, size, capacity = Text.Layout(selectedText, 362, 526, 28)
    for index = 1, math.ceil(#chars / capacity) do
        local first, last = (index - 1) * capacity + 1, math.min(#chars, index * capacity)
        textPanel:AddChild(UI.Label { position = "absolute", left = 54,
            top = 66 + (index - 1) * size * 1.65, width = 362, height = size * 1.65,
            text = table.concat(chars, "", first, last), fontSize = size,
            fontColor = { 53, 39, 30, 255 }, pointerEvents = "none" })
    end
    parent:AddChild(textPanel)
end

local function CreateOverlay(parent)
    local resultOverlay = UI.Panel { id = "result", position = "absolute", left = 0, top = 0,
        width = 1280, height = 800, overflow = "hidden", pointerEvents = "box-only" }
    function resultOverlay:Render(vg)
        local r = self:GetAbsoluteLayout()
        Art.Rect(vg, r.x, r.y, r.w, r.h, 0, { 0, 0, 0, math.floor(185 * math.min(1, clock / 0.35)) })
        if mode == "letter" and clock < 2.7 then
            ---@type number
            local progress = math.min(1, clock / 0.8)
            if clock < 1.35 then
                local y = -430 + 620 * progress * progress
                -- 落到中央后，在打开前抖动 0.3 秒，保持信封闭合状态。
                local shaking = clock >= 1.05
                ---@type number
                local shakeX = shaking and math.sin((clock - 1.05) * 95) * 7 or 0
                ---@type number
                local shakeY = shaking and math.sin((clock - 1.05) * 120) * 3 or 0
                Art.Image(vg, "Global/Images/EnvelopeClosed.png", r.x + 340 + shakeX,
                    r.y + y + shakeY, 600, 422)
            else
                -- 信纸淡入期间保留打开信封，并渐隐信封，避免末帧突然消失。
                nvgSave(vg)
                nvgGlobalAlpha(vg, 1 - math.max(0, math.min(1, (clock - 2.1) / 0.6)))
                Art.Image(vg, "Global/Images/EnvelopeOpen.png", r.x + 350, r.y + 90, 580, 573)
                nvgRestore(vg)
            end
        end
    end
    overlay = resultOverlay
    if mode == "letter" then Letter(resultOverlay) else Banner(resultOverlay) end
    parent:AddChild(overlay)
end

function Result.Start(parent, levelNumber, leaked, paths, callbacks, victoryOverride)
    Result.Stop()
    clock, buttonClock = 0, 0
    actions = callbacks or {}
    local victory = victoryOverride
    if victory == nil then victory = Result.IsVictory(leaked, levelNumber) end
    if victory then mode = "victory"
    else mode = math.random(1, 2) == 1 and "blackBanner" or "letter" end
    selectedText = Text.RandomLine(mode == "victory" and paths.victory or
        (mode == "blackBanner" and paths.blackBanner or paths.letter))
    CreateOverlay(parent)
    -- 左侧回主界面按钮字号略小；右侧按胜负显示“继续”或“重来”。
    homeButton = PulseButton("resultHome", 40, "←主界面", 28, function()
        if actions.home then actions.home() end
    end)
    local won = mode == "victory"
    sideButton = PulseButton("resultSide", 1020, won and "继续" or "重来", 34, function()
        if won then
            if actions.next then actions.next() end
        else
            if actions.retry then actions.retry() end
        end
    end)
    if overlay then overlay:AddChild(homeButton); overlay:AddChild(sideButton) end
    print(string.format("[结局] Level %d，漏过 %d，结果 %s", levelNumber, leaked, mode))
end

-- 积分信使用原信封动画，完全不读取/随机威胁信文案。
function Result.StartScore(parent, score, highest, callbacks, saved)
    Result.Stop()
    scoreResult, doneCalled = true, false
    clock, buttonClock, mode, selectedText = 0, 0, "letter", ""
    actions = callbacks or {}
    scoreLines = { "本次分数：" .. tostring(score), "历史最高：" .. tostring(highest) }
    if saved == false then scoreLines[3] = "记录保存失败，请保留本次成绩" end
    CreateOverlay(parent)
    if not actions.done then
        homeButton = PulseButton("resultHome", 40, "←主界面", 28, function()
            if actions.home then actions.home() end
        end)
        sideButton = PulseButton("resultSide", 1020, "重来", 34, function()
            if actions.retry then actions.retry() end
        end)
        if overlay then overlay:AddChild(homeButton); overlay:AddChild(sideButton) end
    end
    print(string.format("[第十关结算] 本次 %d，历史最高 %d，保存 %s", score, highest, tostring(saved ~= false)))
end

function Result.RequestDone(callback)
    if not scoreResult or doneCalled then return false end
    actions.done = callback
    if homeButton then homeButton:SetVisible(false) end
    if sideButton then sideButton:SetVisible(false) end
    return true
end

---@param dt number
function Result.Update(dt)
    if not overlay or not textPanel then return end
    -- 加载或截图造成的大 dt 不应跳过信封坠落和打开阶段。
    clock = clock + math.min(dt, 0.05)
    buttonClock = buttonClock + math.min(dt, 0.05)
    local opacity = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(buttonClock * 4))
    if homeButton then homeButton.props.opacity = opacity end
    if sideButton then sideButton.props.opacity = opacity end
    if mode == "letter" then
        if clock >= 2.1 then
            textPanel:SetVisible(true)
            textPanel:SetStyle({ opacity = math.min(1, (clock - 2.1) / 0.6) })
        end
    else
        local progress = math.min(1, clock / bannerDuration)
        -- 一份位移作用于锦旗与两列文字，结束时统一归零。
        textPanel.props.translateY = bannerRiseDistance * (1 - progress) ^ 3
    end
    if scoreResult and actions.done and not doneCalled and clock >= 4.2 then
        doneCalled = true
        local callback = actions.done
        actions.done = nil
        callback() -- 信纸完整显示并停留后才执行待退出目标，执行前锁定。
    end
end

function Result.Stop()
    if overlay then overlay:Remove(); overlay:Destroy(); overlay = nil end
    textPanel, homeButton, sideButton = nil, nil, nil
    actions, scoreLines = {}, {}
    scoreResult, doneCalled = false, false
end

return Result
-- ==================== 共享通关判定与结局动画模块结束 ====================

