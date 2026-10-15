-- 退出菜单复用2D脚手架的UI根与竖排控件；不销毁被暂停的首页/关卡树。
local UI = require("urhox-libs/UI")
local Menu = {}
---@type Widget?
local previousRoot = nil
---@type Panel?
local overlay = nil
---@type Label[]
local labels = {}
---@type string?
local choice = nil
---@type number
local clock = 0

local function Option(id, text, target)
    local label = UI.Label {
        id = id .. "Text", width = "100%", height = "100%", text = text,
        fontSize = 36, fontColor = { 255, 217, 61, 255 }, textAlign = "center",
        verticalAlign = "middle", pointerEvents = "none",
    }
    labels[#labels + 1] = label
    return UI.Panel {
        id = id, width = 360, maxWidth = "100%", height = 84,
        pointerEvents = "box-only", children = { label },
        onClick = function(self, event)
            if choice or (event and not event:IsPrimaryAction()) then return end
            if event then event:StopPropagation() end
            choice = target -- 下一Update切换，不能在指针遍历中释放旧树。
        end,
    }
end

function Menu.IsOpen()
    return overlay ~= nil
end

function Menu.Open()
    if overlay then return false end
    previousRoot = UI.GetRoot()
    labels, choice, clock = {}, nil, 0
    overlay = UI.Panel {
        id = "exitMenu", width = "100%", height = "100%",
        backgroundColor = { 0, 0, 0, 255 }, pointerEvents = "auto",
        children = {
            UI.SafeAreaView {
                width = "100%", height = "100%", nativeMenuInset = true,
                justifyContent = "center", alignItems = "center", gap = 24,
                children = {
                    Option("exitMenuHome", "标题界面", "home"),
                    Option("exitMenuExit", "退出游戏", "exit"),
                },
            },
        },
    }
    UI.SetFocus(nil)
    UI.SetRoot(overlay)
    UI.PushOverlay(overlay)
    UI.Layout()
    print("[退出菜单] 黑屏，两项纵向黄色闪烁文字；玩法已冻结")
    return true
end

---@param dt number
---@return string?
function Menu.Update(dt)
    if not overlay then return nil end
    clock = clock + math.min(dt, 0.05)
    local opacity = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(clock * 4))
    for _, label in ipairs(labels) do label:SetOpacity(opacity) end
    return choice
end

function Menu.Close()
    if not overlay then return end
    local old = overlay
    UI.PopOverlay(old)
    if previousRoot then UI.SetRoot(previousRoot) end
    overlay, previousRoot, choice = nil, nil, nil
    labels = {}
    old:Destroy()
end

return Menu
