-- ==================== 共享教程模块：入场、平台文案、逐字显示 ====================
-- 术语：“天堂鸟女士”= 引导员图片（Global/Images/Guide.png）；“对话框”= Dialogue.png。
local UI = require("urhox-libs/UI")
local Art = require("Global.WorkshopArt")
local Text = require("Global.TextLines")
local Tutorial = {}
---@type Panel?
local overlay = nil
---@type Panel?
local guide = nil
---@type Panel?
local dialogue = nil
---@type Panel?
local skip = nil
---@type Label?
local skipText = nil
---@type string[]
local lines = {}
---@type string[]
local chars = {}
---@class TutorialTextSegment
---@field label Label
---@field first integer
---@field last integer
---@field highlighted boolean
---@type TutorialTextSegment[]
local segments = {}
---@type RGBAColor[]
local highlightColors = { { 220, 40, 40, 255 }, { 220, 40, 40, 255 } }
---@type number
local clock = 0
---@type number
local typingClock = 0
---@type integer
local lineIndex = 1
---@type integer
local shown = 0
local finished = false
local loading, loadGeneration = false, 0
---@type number
local guideY = 60
---@type fun()
local complete = function() end

local function ShowLine()
    typingClock, shown = 0, 0
    if lineIndex > #lines then
        finished = true
        return
    end
    if not dialogue then return end
    local value = lines[lineIndex]
    if not value then return end
    -- [] 先转换为可见字符，再排版；括号既不显示，也不占用逐字计时。
    local visible, highlights = Text.TutorialCharacters(value)
    local layoutChars, size, capacity = Text.Layout(table.concat(visible), 526, 240, 26)
    chars = layoutChars
    -- ClearChildren 仅解绑：显式销毁上一页控件，避免教程翻页堆积 Yoga 节点。
    for _, segment in ipairs(segments) do segment.label:Destroy() end
    dialogue:ClearChildren()
    segments = {}
    local fontFamily = UI.Theme.FontFamily()
    local fontFace = UI.Theme.FontFace(fontFamily, "normal")
    local pixelSize = UI.Theme.FontSize(size)
    for row = 1, math.ceil(#chars / capacity) do
        local rowFirst = (row - 1) * capacity + 1
        local rowLast = math.min(#chars, row * capacity)
        local first = rowFirst
        while first <= rowLast do
            local color = highlights[first] or 0
            local last = first
            while last < rowLast and highlights[last + 1] == color do last = last + 1 end
            -- 用完整行的字符前缀测量位置，而不是 UTF-8 字节数/猜测字宽。
            -- 每个片段宽度固定为完整文字的宽度，逐字 SetText 不会推动后面的片段。
            local prefix = first > rowFirst and table.concat(chars, "", rowFirst, first - 1) or ""
            local fullText = table.concat(chars, "", first, last)
            local left = UI.MeasureTextWidth(prefix, pixelSize, fontFace, 0)
            local width = UI.MeasureTextWidth(fullText, pixelSize, fontFace, 0)
            local label = UI.Label {
                position = "absolute", left = 54 + left, top = 48 + (row - 1) * size * 1.65,
                width = math.ceil(width) + 2, height = size * 1.65, text = "", fontSize = size,
                fontFamily = fontFamily, fontWeight = "normal", whiteSpace = "nowrap", letterSpacing = 0,
                fontColor = color > 0 and highlightColors[color] or { 45, 39, 34, 255 },
                opacity = color > 0 and 0.775 or 1, pointerEvents = "none",
            }
            -- 不覆写 Label.Render：文字始终由新 UI 组件的标准渲染管线绘制。
            segments[#segments + 1] = { label = label, first = math.floor(first), last = math.floor(last),
                highlighted = color > 0 }
            dialogue:AddChild(label)
            first = last + 1
        end
    end
end

local function FillSegments()
    for _, segment in ipairs(segments) do
        local last = math.min(shown, segment.last)
        segment.label:SetText(segment.first <= last
            and table.concat(chars, "", segment.first, last) or "")
    end
end

function Tutorial.Advance()
    if clock < 0.85 or finished or loading then return end
    if shown < #chars then
        -- 第一次点击只补齐当前页可见字符，[] 已在 ShowLine 移除，不跳页也不改红闪。
        shown, typingClock = #chars, #chars * 0.1
        FillSegments()
        return
    end
    lineIndex = lineIndex + 1
    ShowLine() -- 当前页已完全显示才翻页；新页仍按 0.1 秒一个字显示。
end

-- 右上角 SKIP：直接结束教程并触发后续入场，所有关卡共用。
function Tutorial.Skip()
    if not overlay then return end
    print("[教程] 玩家点击 SKIP，跳过教程")
    Tutorial.Stop()
    complete()
end

function Tutorial.Start(parent, path, windowHeight, mobile, onComplete, mobileLastLine)
    Tutorial.Stop()
    local function AppendMobileLine()
        if mobile and mobileLastLine and #lines > 0 then
            lines[#lines + 1] = mobileLastLine
        end
    end
    -- 先挂载教程，冷缓存保持加载页；原文就绪前点击正文不能提前进入关卡。
    loading = type(path) ~= "table"
    if loading then lines = { "正在加载教程，请稍候……" }
    else lines = Text.TutorialLines(path, mobile); AppendMobileLine() end
    if #lines == 0 then lines = { "教程文案为空，请检查对应关卡教程。" } end
    clock, typingClock, lineIndex, shown = 0, 0, 1, 0
    finished = false
    complete = onComplete
    guideY = 800 - 720 - windowHeight * 0.5
    local guidePanel = UI.Panel { id = "tutorialGuide", position = "absolute", left = -456,
        top = guideY, width = 455, height = 720, pointerEvents = "none" }
    function guidePanel:Render(vg)
        local r = self:GetAbsoluteLayout()
        Art.Image(vg, "Global/Images/Guide.png", r.x, r.y, r.w, r.h)
    end
    guide = guidePanel
    local dialoguePanel = UI.Panel { id = "tutorialDialogue", position = "absolute", left = 620, top = 225,
        width = 634, height = 377, pointerEvents = "none", overflow = "hidden", opacity = 0 }
    function dialoguePanel:Render(vg)
        local r = self:GetAbsoluteLayout()
        Art.Image(vg, "Global/Images/Dialogue.png", r.x, r.y, r.w, r.h)
    end
    dialogue = dialoguePanel
    overlay = UI.Panel { id = "tutorial", position = "absolute", left = 0, top = 0,
        width = 1280, height = 800, backgroundColor = { 0, 0, 0, 0 },
        pointerEvents = "auto", children = { guide, dialogue },
        onClick = function(self, event)
            if not event or event:IsPrimaryAction() then Tutorial.Advance() end
        end }
    skipText = UI.Label { id = "skipText", width = "100%", height = "100%", text = "SKIP",
        fontSize = 30, textAlign = "center", fontColor = { 255, 240, 205, 255 },
        pointerEvents = "none" }
    local skipPanel = UI.Panel { id = "tutorialSkip", position = "absolute", left = 1130, top = 20,
        width = 120, height = 48, pointerEvents = "box-only", opacity = 0.775,
        children = { skipText },
        onClick = function(self, event)
            if event and not event:IsPrimaryAction() then return end
            Tutorial.Skip()
        end }
    -- 只保留周期闪烁的文字，透明点击容器不绘制椭圆光晕。
    function skipPanel:Render(vg)
    end
    skip = skipPanel
    overlay:AddChild(skipPanel)
    parent:AddChild(overlay)
    ShowLine()
    if loading then
        local generation = loadGeneration
        Text.LoadLines(path, function(source, errorMessage)
            -- Skip/切关/新教程使代次失效，旧下载完成不能复活已销毁的控件树。
            if generation ~= loadGeneration or not overlay then return end
            loading = false
            lines = Text.TutorialLines(source, mobile)
            AppendMobileLine()
            if #lines == 0 then
                lines = { "教程加载失败，请重新进入关卡。" }
                print("[教程] 加载失败：" .. tostring(path) .. "，" .. tostring(errorMessage))
            end
            lineIndex, finished = 1, false
            ShowLine()
            print(string.format("[教程] 原文就绪：%s，%s文案共 %d 行", tostring(path),
                mobile and "手机" or "电脑", #lines))
        end)
    else
        print(string.format("[教程] 开始，%s文案共 %d 行", mobile and "手机" or "电脑", #lines))
    end
end

---@param dt number
function Tutorial.Update(dt)
    if not overlay or not guide or not dialogue then return end
    clock = clock + dt
    local opacity = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(clock * 4))
    if skip then skip:SetStyle({ opacity = opacity }) end
    for _, segment in ipairs(segments) do
        if segment.highlighted then segment.label:SetStyle({ opacity = opacity }) end
    end
    overlay:SetStyle({ backgroundColor = { 0, 0, 0, math.floor(165 * math.min(1, clock / 0.3)) } })
    local progress = math.max(0, math.min(1, (clock - 0.3) / 0.45))
    guide:SetStyle({ left = -456 + 576 * (1 - (1 - progress) ^ 3) })
    if clock >= 0.75 then dialogue:SetStyle({ opacity = math.min(1, (clock - 0.75) / 0.15) }) end
    if clock >= 0.85 then
        typingClock = typingClock + math.max(0, clock - math.max(0.85, clock - dt))
        if shown < #chars then
            local newShown = math.min(#chars, math.floor(typingClock / 0.1))
            if newShown > shown then
                shown = newShown
                FillSegments()
            end
        end
        if finished then
            Tutorial.Stop()
            complete()
        end
    end
end

function Tutorial.Stop()
    loadGeneration = loadGeneration + 1
    loading = false
    if overlay then overlay:Remove(); overlay:Destroy(); overlay = nil end
    guide, dialogue, skip, skipText = nil, nil, nil, nil
    segments, chars, lines = {}, {}, {}
end

return Tutorial
-- ==================== 共享教程模块结束 ====================

