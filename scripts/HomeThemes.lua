-- 首页专用窗内主题；复用 UI 的 NanoVG 上下文/图片缓存，不创建帧、物理或游戏关卡。
local Art = require("Global.WorkshopArt")
local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local Themes = {}

local themePaths = {
    [2] = "Home/Theme2.png", -- 上传 1：晾衣长图，1040 × 2268。
    [3] = "Home/Theme3.png", -- 上传 2：猫形云，1536 × 1536。
    [4] = "Home/Theme4.png", -- 上传 3：防盗栏窗，1536 × 1536。
    [5] = "Home/Theme5.png", -- 用户上传 57be...，1536 × 1536，逐字节原图复制。
    [6] = "Home/Theme6.png", -- 用户上传 d0d6...，1536 × 1536，逐字节原图复制。
    [7] = "Home/Theme7.png", -- 用户上传 161bf783...，1536 × 1536；原图不生成/不重编码。
    [8] = "Home/Theme8.png", -- 用户上传 921ff206...，1536 × 1536；原图不生成/不重编码。
    [9] = "Home/Theme9.png", -- 用户上传 c71e14f3...，1248 × 1872；原图不生成/不重编码。
}

---@class HomeThemeLoad
---@field path string
---@field ready boolean
---@field loading boolean
---@field refresh boolean
---@field attempts integer
---@field retryAt number
---@type table<number, HomeThemeLoad>
local loads = {}
---@type integer
local generation = 0

---@param number integer
---@param clock number
local function Request(number, clock)
    local state = loads[number]
    if not state or state.ready or state.loading or state.attempts >= 3 or clock < state.retryAt then return end
    state.attempts = state.attempts + 1
    if cache:Exists(state.path) then
        state.ready, state.refresh = true, true
        return
    end
    state.loading = true
    local token = generation
    cache:DownloadResource(state.path, function(success, errorMessage)
        if token ~= generation or loads[number] ~= state then return end
        state.loading = false
        state.ready, state.refresh = success, success
        state.retryAt = clock + 1
        if success then
            print("[Home主题] 资源已就绪：" .. state.path)
        else
            print("[Home主题] 下载失败：" .. state.path .. "，" .. tostring(errorMessage))
        end
    end)
end

---@param numbers integer[]
function Themes.Prepare(numbers)
    generation = generation + 1
    loads = {}
    for _, number in ipairs(numbers) do
        local path = themePaths[number]
        if path then
            loads[number] = {path = path, ready = false, loading = false, refresh = true,
                attempts = 0, retryAt = 0}
            Request(number, 0)
        end
    end
end

function Themes.Stop()
    generation = generation + 1
    loads = {}
end

-- 依据 Theme2 原图定位三块前景布的下半内部；避开晾衣绳、夹子、布上缘与外轮廓。
-- 坐标为原图 1040 × 2268 像素，只对布纹理做微小条带变形，不让整幅街景摇晃。
local clothPatches = {
    { left = 216, right = 332, top = 1408, bottom = 1500, phase = 0.4 },
    { left = 431, right = 564, top = 1410, bottom = 1513, phase = 2.1 },
    { left = 688, right = 806, top = 1376, bottom = 1467, phase = 4.3 },
}

---@param vg NVGContextWrapper
---@param image integer
local function Paint(vg, image, x, y, w, h, originX, originY, imageW, imageH)
    nvgBeginPath(vg)
    nvgRect(vg, x, y, w, h)
    nvgFillPaint(vg, nvgImagePattern(vg, originX, originY, imageW, imageH, 0, image, 1))
    nvgFill(vg)
end

---@param vg NVGContextWrapper
---@param image integer
local function DrawCloth(vg, image, x, y, w, h, clock)
    Paint(vg, image, x, y, w, h, x, y, w, h)
    local strips = 14
    for _, patch in ipairs(clothPatches) do
        local left = x + patch.left / 1040 * w
        local top = y + patch.top / 2268 * h
        local patchW = (patch.right - patch.left) / 1040 * w
        local patchH = (patch.bottom - patch.top) / 2268 * h
        for strip = 1, strips do
            local t = (strip - 0.5) / strips
            -- 中段固定、下缘缓慢摆动；位移不足 1 首页基准像素，无额外悬空布片。
            local envelope = math.sin(t * math.pi) * t
            local dx = math.sin(clock * 1.45 + patch.phase + t * 3.2)
                * math.min(1.6, w * 0.025) * envelope
            local stripY = top + (strip - 1) / strips * patchH
            nvgSave(vg)
            nvgIntersectScissor(vg, left, stripY, patchW, patchH / strips)
            Paint(vg, image, left, stripY, patchW, patchH / strips, x + dx, y, w, h)
            nvgRestore(vg)
        end
    end
end

---@param vg NVGContextWrapper
---@param image integer
local function DrawCloud(vg, image, x, y, w, h, clock)
    -- 原图四边皆是天空，轻微 overscan 使纹理偏移时无露黑/复制云；窗框始终固定。
    local margin = 2
    local dx = math.sin(clock * 0.23) * 1.2
    local dy = math.sin(clock * 0.19 + 0.6) * 0.55
    Paint(vg, image, x, y, w, h, x - margin + dx, y - margin + dy,
        w + margin * 2, h + margin * 2)
end

---@param vg NVGContextWrapper
local function DrawAsh(vg, x, y, w, h, clock)
    -- 首页第四关窗内少量细灰尘，不复用全屏灰尘，也不创建可掉落物/碰撞体。
    for index = 1, 14 do
        local phase = index * 2.39996
        local px = x + ((index * 0.618034 + math.sin(clock * 0.37 + phase) * 0.035) % 1) * w
        local py = y + ((index * 0.381966 - clock * (0.025 + index % 3 * 0.008)) % 1) * h
        local alpha = math.floor(42 + (0.5 + 0.5 * math.sin(clock * 0.8 + phase)) * 38)
        Art.Circle(vg, px, py, 0.35 + index % 3 * 0.12, { 188, 178, 160, alpha })
    end
end

---@param vg NVGContextWrapper
---@param number integer
---@param viewportW number?
---@param viewportH number?
function Themes.Draw(vg, number, x, y, w, h, clock, viewportW, viewportH)
    local path = themePaths[number]
    if not path or w <= 0 or h <= 0 then return end
    if not loads[number] then
        loads[number] = {path = path, ready = false, loading = false, refresh = true,
            attempts = 0, retryAt = 0}
    end
    Request(number, clock)
    local state = loads[number]
    if not state or not state.ready then return end
    -- 图片未就绪时不污染UI负缓存；完成回调后在有效绘图上下文中清理旧失败句柄。
    if state.refresh then ImageCache.Release(path); state.refresh = false end
    local image = math.floor(ImageCache.Get(path))
    if image <= 0 then
        state.ready = false
        state.retryAt = clock + 1
        return
    end
    nvgSave(vg)
    -- 保留父级裁剪；使用 Home 实际局部画幅，不能再硬裁 1280×800 的旧画板。
    nvgIntersectScissor(vg, 0, 0, viewportW or 1280, viewportH or 800)
    nvgIntersectScissor(vg, x, y, w, h)
    if number == 2 then
        DrawCloth(vg, image, x, y, w, h, clock)
    elseif number == 3 then
        DrawCloud(vg, image, x, y, w, h, clock)
    else
        Paint(vg, image, x, y, w, h, x, y, w, h)
        if number == 4 then DrawAsh(vg, x, y, w, h, clock) end
    end
    nvgRestore(vg)
end

---@param vg NVGContextWrapper
---@param viewportW number?
---@param viewportH number?
function Themes.DrawSill(vg, x, y, w, h, viewportW, viewportH)
    -- Home 第三关静态花盆绘在 Wall/窗台之后；只裁画幅，叶尖/盆身不得被窗洞裁掉。
    -- Wall 原图该窗底框 y=539，花盆中心 x≈808 的台面 alpha 从 y=541 开始。
    -- 不调用 FlowerPots 玩法模块，因此没有掉落、伤害或全局状态。
    local path = "Global/Images/FlowerPot.png"
    if ImageCache.Get(path) <= 0 then return end
    local imageW, imageH = ImageCache.GetSize(path)
    if imageW <= 0 or imageH <= 0 then return end
    local potH = h * 0.75 -- 仅首页墙高 stretch；盆仍保持原图 589:1154 比例且贴实测窗台。
    local potW = potH * imageW / imageH
    local sillY = y + h + h * 2 / 136 -- 实测台面位置，盆底贴台，不埋进窗台。
    nvgSave(vg)
    nvgIntersectScissor(vg, 0, 0, viewportW or 1280, viewportH or 800)
    Art.Image(vg, path, x + w * 0.72 - potW / 2, sillY - potH, potW, potH)
    nvgRestore(vg)
end

return Themes
