-- 共享雾气图层：每个小云团是单独的水彩雾贴图，再按图层组合晃动；场景扩展后可复用。
-- 术语：“云团”= 单个半透明雾贴图实例；“雾气图层”= 云团组合，
-- front 层画在草地之上，back 层画在背景图与楼房之间。
-- 与 WorkshopArt 无 require 依赖（避免循环引用），图片绘制直接用 ImageCache。
local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local Fog = {}

local function DrawImage(vg, path, x, y, width, height)
    local image = ImageCache.Get(path)
    if image <= 0 then return end
    nvgBeginPath(vg); nvgRect(vg, x, y, width, height)
    nvgFillPaint(vg, nvgImagePattern(vg, x, y, width, height, 0, math.floor(image), 1))
    nvgFill(vg)
end

---@class FogBlob
---@field image string 云团贴图路径
---@field x number 基准横向位置（图层宽度比例）
---@field y number 基准纵向位置（图层高度比例）
---@field w number 基准宽度（1280 设计宽下的像素）
---@field h number 基准高度（800 设计高下的像素）
---@field alpha number 基准不透明度（0-255，仍会乘图层整体系数）
---@field drift number 水平晃动幅度（像素）
---@field bob number 垂直浮动幅度（像素）
---@field speed number 晃动速度
---@field phase number 相位偏移

local function Blob(image, x, y, w, h, alpha, drift, bob, speed, phase)
    return { image = image, x = x, y = y, w = w, h = h, alpha = alpha,
        drift = drift, bob = bob, speed = speed, phase = phase }
end

Fog.layers = {
    back = {
        alphaScale = 0.75,
        blobs = {
            Blob("Global/Images/Mist1.png", 0.02, 0.34, 620, 420, 120, 30, 8, 0.31, 0.0),
            Blob("Global/Images/Mist2.png", 0.36, 0.28, 700, 470, 105, 38, 10, 0.24, 1.7),
            Blob("Global/Images/Mist3.png", 0.68, 0.40, 640, 430, 115, 26, 7, 0.37, 3.1),
        },
    },
    front = {
        alphaScale = 0.60,
        blobs = {
            Blob("Global/Images/Mist1.png", -0.04, 0.70, 560, 380, 100, 34, 7, 0.29, 0.6),
            Blob("Global/Images/Mist4.png", 0.30, 0.78, 680, 450, 90, 42, 9, 0.22, 2.4),
            Blob("Global/Images/Mist2.png", 0.62, 0.68, 600, 400, 100, 30, 8, 0.33, 4.2),
            Blob("Global/Images/Mist3.png", 0.86, 0.80, 480, 330, 85, 24, 6, 0.40, 5.5),
        },
    },
}

-- 每帧调用：clock 用玩法时钟，云团位置只由比例与画幅推导，不依赖关卡坐标。
function Fog.Draw(vg, layerName, width, height, clock)
    local layer = Fog.layers[layerName]
    if not layer then return end
    local unit = width / 1280
    nvgSave(vg)
    for _, blob in ipairs(layer.blobs) do
        local sway = math.sin(clock * blob.speed + blob.phase)
        local lift = math.sin(clock * blob.speed * 0.63 + blob.phase * 1.7)
        local breathe = 1 + 0.07 * math.sin(clock * blob.speed * 0.8 + blob.phase * 2.3)
        local bw = blob.w * breathe * unit
        local bh = blob.h * breathe * (height / 800)
        local bx = blob.x * width + sway * blob.drift * unit - bw / 2
        local by = blob.y * height + lift * blob.bob * unit - bh / 2
        -- 整团呼吸明暗：贴图为带羽化边的水彩雾，乘 alpha 后不会遮挡画面。
        local alpha = blob.alpha * layer.alphaScale *
            (0.70 + 0.30 * math.sin(clock * blob.speed * 0.5 + blob.phase))
        nvgGlobalAlpha(vg, alpha / 255)
        DrawImage(vg, blob.image, bx, by, bw, bh)
    end
    nvgGlobalAlpha(vg, 1)
    nvgRestore(vg)
end

return Fog
