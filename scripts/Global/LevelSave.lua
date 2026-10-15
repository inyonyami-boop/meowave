-- 独立客户端本地布局存档；require 时不读盘、不创建场景、不读取平台配置。
-- File 的相对路径由引擎按项目/用户隔离；不使用 io、绝对路径或云端存档。
-- 磁盘格式：{ version = 1, levels = { ["1"] = { floors, props, fences, inventory } } }。
-- prepared 不是持久化进度：每次读取固定 false，重新进入仍执行关卡强制操作。
local LevelSave = {}

local SAVE_DIR = "saves"
local SAVE_PATH = "saves/miaojang-layouts.json"
local BACKUP_PATH = "saves/miaojang-layouts.json.bak"
-- 本次用户要求清档：每个客户端沙箱更新后执行一次；标记成功后保留重新游玩的新存档。
local RESET_PATH = "saves/miaojang-layout-reset.txt"
local RESET_REVISION = "2026-10-10-previous-level-only"
local VERSION = 1
local MAX_FILE_BYTES = 2 * 1024 * 1024
local MAX_LIST_ITEMS = 4096
local MAX_LEVELS = 4096
local MAX_WAREHOUSE_STOCK = 4096
local MAX_WINDOW_KEY_BYTES = 128
-- 保证整数能经过 cjson 默认数值精度往返；实际关卡和楼层远小于此范围。
local MAX_INDEX = 2147483647

---@class LevelSaveFencePosition
---@field x number 世界坐标，米；画面 y 向下。
---@field y number
---@field angle number 弧度，与 WorkshopFence.angle 一致。

---@class LevelSaveLayout : RescueLevelLayout
---@field fences LevelSaveFencePosition[]

---@class LevelSaveDocument
---@field version integer
---@field levels table<string, LevelSaveLayout>
---@field completed table<string, boolean> 独立通关集合，不由布局存在与否推断。
---@field highScore10 integer? 可选 L10 挑战最高峰值；旧 version1 没有此字段仍有效。

---@param message string
local function Warn(message)
    print("[LevelSave] " .. message)
end

---@param value any
---@return boolean
local function Finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param value any
---@return boolean
local function CellIndex(value)
    return Finite(value) and value % 1 == 0 and math.abs(value) <= MAX_INDEX
end

---@param value any
---@return boolean
local function LevelNumber(value)
    return CellIndex(value) and value >= 1
end

---@param value any
---@return boolean
local function WarehouseStockCount(value)
    return Finite(value) and value % 1 == 0 and value >= 0 and value <= MAX_WAREHOUSE_STOCK
end

-- 缺失的仓库库存项补零，不补造教程库存或发放标志。
---@param value any
---@return WarehousePropStock?
local function CopyWarehouseStock(value)
    if value == nil then return { rack = 0, fence = 0, security_window = 0 } end
    if type(value) ~= "table" then return nil end
    local rack, fence, security = value.rack, value.fence, value.security_window
    if rack == nil then rack = 0 end
    if fence == nil then fence = 0 end
    if security == nil then security = 0 end
    if not WarehouseStockCount(rack) or not WarehouseStockCount(fence)
        or not WarehouseStockCount(security) then return nil end
    return { rack = math.floor(rack), fence = math.floor(fence), security_window = math.floor(security) }
end

-- 不用 # 或 ipairs 判定输入是否合法，避免孔洞、零索引、对象键被静默截断。
-- cjson 默认把空 Lua 表编码成 {}，因此无键空表同样表示空列表。
---@param value any
---@return integer? count
local function ListCount(value)
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in next, value do
        if not CellIndex(key) or key < 1 or key > MAX_LIST_ITEMS then return nil end
        count = count + 1
    end
    for index = 1, count do
        if rawget(value, index) == nil then return nil end
    end
    return count
end

-- key 是稳定窗位标识，不由运行中坐标重建；禁止同窗重复安装。
-- base:<正整数> / floor:<规范整数 col>:<规范整数 row>:<1..3>。
---@param value any
---@return boolean
local function WindowKey(value)
    if type(value) ~= "string" or #value > MAX_WINDOW_KEY_BYTES then return false end
    if value:match("^base:[1-9][0-9]*$") then return true end
    local colText, rowText = value:match("^floor:(%-?[0-9]+):(%-?[0-9]+):[1-3]$")
    if not colText or not rowText then return false end
    local col, row = tonumber(colText), tonumber(rowText)
    if col == nil or row == nil or not CellIndex(col) or not CellIndex(row) then return false end
    return tostring(math.floor(col)) == colText and tostring(math.floor(row)) == rowText
end

-- 只复制布局白名单；即使调用者传入 WorkshopFence / 运行中布局，也不编码
-- Node、ID、猫咪、计数、drag、触发状态、warehouseClaims 或 prepared/pendingFloors。
-- 任何非法布局整条拒绝；传关号后同时限制第五关才引入的仓库道具。
---@param value any
---@param levelNumber number?
---@return LevelSaveLayout?
local function CopyLayout(value, levelNumber)
    if type(value) ~= "table" or (levelNumber ~= nil and not LevelNumber(levelNumber)) then return nil end
    local warehouseAllowed = levelNumber == nil or levelNumber >= 5
    local securityAllowed = levelNumber == nil or levelNumber >= 4
    local laboratoryAllowed = levelNumber == nil or levelNumber >= 6
    local matchmakingAllowed = levelNumber == nil or levelNumber >= 7
    local greenhouseAllowed = levelNumber == nil or levelNumber >= 8
    local floorCount, propCount = ListCount(value.floors), ListCount(value.props)
    local fences = value.fences
    if fences == nil then fences = {} end -- 兼容尚未导出 fences 的布局。
    local fenceCount = ListCount(fences)
    if floorCount == nil or propCount == nil or fenceCount == nil then return nil end
    ---@type LevelSaveLayout
    local result = { floors = {}, props = {}, fences = {}, prepared = false }
    ---@type table<string, boolean>
    local occupied = {}
    for index = 1, floorCount do
        local entry = value.floors[index]
        if type(entry) ~= "table" or not CellIndex(entry.col) or not CellIndex(entry.row) then
            return nil
        end
        local col, row = math.floor(entry.col), math.floor(entry.row)
        local key = tostring(col) .. ":" .. tostring(row)
        if occupied[key] then return nil end
        occupied[key] = true
        if entry.roof ~= nil and entry.roof ~= 1 and entry.roof ~= 2 then return nil end
        if entry.roof ~= nil and (type(entry.roofFlip) ~= "boolean") then return nil end
        if entry.roofFlip ~= nil and (entry.roof == nil or type(entry.roofFlip) ~= "boolean") then return nil end
        if entry.warehouse ~= nil and type(entry.warehouse) ~= "boolean" then return nil end
        if entry.laboratory ~= nil and type(entry.laboratory) ~= "boolean" then return nil end
        if entry.matchmaking ~= nil and type(entry.matchmaking) ~= "boolean" then return nil end
        if entry.greenhouse ~= nil and type(entry.greenhouse) ~= "boolean" then return nil end
        local specialCount = (entry.warehouse == true and 1 or 0) + (entry.laboratory == true and 1 or 0)
            + (entry.matchmaking == true and 1 or 0) + (entry.greenhouse == true and 1 or 0)
        if specialCount > 1 or (entry.warehouse == true and not warehouseAllowed)
            or (entry.laboratory == true and not laboratoryAllowed)
            or (entry.matchmaking == true and not matchmakingAllowed)
            or (entry.greenhouse == true and not greenhouseAllowed) then return nil end
        -- 四类特殊互斥，均可叠加合法 roof；false 规范化省略，旧档无新字段仍原样有效。
        result.floors[index] = { col = col, row = row,
            roof = entry.roof and math.floor(entry.roof) or nil, roofFlip = entry.roofFlip,
            warehouse = entry.warehouse == true and true or nil,
            laboratory = entry.laboratory == true and true or nil,
            matchmaking = entry.matchmaking == true and true or nil,
            greenhouse = entry.greenhouse == true and true or nil }
    end
    local tutorialRackCount, tutorialSecurityCount = 0, 0
    ---@type table<string, boolean>
    local securedWindows = {}
    for index = 1, propCount do
        local entry = value.props[index]
        if type(entry) ~= "table" then return nil end
        if entry.kind == nil or entry.kind == "rack" then
            if not Finite(entry.x) or not Finite(entry.y)
                or (entry.source ~= nil and (entry.source ~= "warehouse" or not warehouseAllowed)) then
                return nil
            end
            if entry.source == nil then tutorialRackCount = tutorialRackCount + 1 end
            result.props[index] = { kind = "rack", x = entry.x, y = entry.y, source = entry.source }
        elseif entry.kind == "security_window" then
            local source = entry.source
            if source == nil then source = "warehouse" end -- L5旧防盗窗无source，保持旧仓库来源。
            if (source ~= "tutorial" and source ~= "warehouse")
                or (source == "tutorial" and not securityAllowed)
                or (source == "warehouse" and not warehouseAllowed)
                or not WindowKey(entry.windowKey) or securedWindows[entry.windowKey]
                or (entry.x ~= nil and not Finite(entry.x))
                or (entry.y ~= nil and not Finite(entry.y)) then return nil end
            if source == "tutorial" then tutorialSecurityCount = tutorialSecurityCount + 1 end
            if tutorialSecurityCount > 1 then return nil end -- 新L4教程配额永远仅一件；旧仓库窗不裁剪。
            securedWindows[entry.windowKey] = true
            result.props[index] = { kind = "security_window", windowKey = entry.windowKey, source = source }
        else
            return nil
        end
    end
    for index = 1, fenceCount do
        local entry = fences[index]
        if type(entry) ~= "table" or not Finite(entry.x) or not Finite(entry.y)
            or not Finite(entry.angle) then return nil end
        result.fences[index] = { x = entry.x, y = entry.y, angle = entry.angle }
    end
    if value.inventory ~= nil then
        local inventory = value.inventory
        if type(inventory) ~= "table" or type(inventory.tutorialGranted) ~= "boolean"
            or (inventory.rack ~= 0 and inventory.rack ~= 1)
            or (not inventory.tutorialGranted and (inventory.rack ~= 0 or tutorialRackCount > 0))
            or (inventory.rack > 0 and tutorialRackCount > 0) then return nil end
        local security, securityGranted = inventory.security, inventory.securityGranted
        if security == nil then security = 0 end
        if securityGranted == nil then securityGranted = tutorialSecurityCount > 0 end
        if type(securityGranted) ~= "boolean" or (security ~= 0 and security ~= 1)
            or (not securityGranted and (security ~= 0 or tutorialSecurityCount > 0))
            or (security > 0 and tutorialSecurityCount > 0)
            or (not securityAllowed and (security ~= 0 or securityGranted)) then return nil end
        local stock = CopyWarehouseStock(inventory.warehouseStock)
        if not stock or (not warehouseAllowed
            and (stock.rack ~= 0 or stock.fence ~= 0 or stock.security_window ~= 0)) then return nil end
        -- 两个教程来源独立检查；warehouse来源 rack / security_window 不改变教程配额。
        result.inventory = { rack = math.floor(inventory.rack), tutorialGranted = inventory.tutorialGranted,
            security = math.floor(security), securityGranted = securityGranted, warehouseStock = stock }
    end -- 老位置存档无 inventory 时仍保留 nil，由道具系统按旧晾衣架规则兼容恢复。
    return result
end

---@return LevelSaveDocument
local function EmptyDocument()
    return { version = VERSION, levels = {}, completed = {} }
end

---@param value any
---@return LevelSaveDocument?
local function CopyDocument(value)
    if type(value) ~= "table" or value.version ~= VERSION or type(value.levels) ~= "table" then
        return nil
    end
    local result = EmptyDocument()
    if value.highScore10 ~= nil then
        if not CellIndex(value.highScore10) or value.highScore10 < 0 then return nil end
        result.highScore10 = math.floor(value.highScore10)
    end
    local count = 0
    for key, layout in next, value.levels do
        if type(key) ~= "string" then return nil end
        local number = tonumber(key)
        if number == nil or not LevelNumber(number) or tostring(math.floor(number)) ~= key then return nil end
        local copy = CopyLayout(layout, number)
        if not copy then return nil end
        result.levels[key] = copy
        count = count + 1
        if count > MAX_LEVELS then return nil end
    end
    if value.completed ~= nil then
        if type(value.completed) ~= "table" then return nil end
        local completedCount = 0
        for key, done in pairs(value.completed) do
            local number = type(key) == "string" and tonumber(key) or nil
            if not number or not LevelNumber(number) or tostring(math.floor(number)) ~= key
                or done ~= true then return nil end
            result.completed[key] = true
            completedCount = completedCount + 1
            if completedCount > MAX_LEVELS then return nil end
        end
    end -- 旧存档没有通关证据，不凭已有布局或最高关号补造通关。
    return result
end

---@param text string
---@return LevelSaveDocument?
local function DecodeDocument(text)
    local decoded, value = pcall(function() return cjson.decode(text) end)
    if not decoded then return nil end
    local checked, document = pcall(CopyDocument, value)
    if not checked then return nil end
    return document
end

-- Dispose 关闭并释放 File；任何路径（含异常）都清理本模块创建的句柄。
---@param file File?
---@return boolean
local function ReleaseFile(file)
    if not file then return true end
    local ok = pcall(function() file:Dispose() end)
    if not ok then Warn("释放存档文件失败") end
    return ok
end

---@param path string 仅由本模块固定相对路径常量传入。
---@return string? text
---@return string status missing / invalid / error / ok
local function ReadText(path)
    local existsOK, exists = pcall(function() return fileSystem:FileExists(path) end)
    if not existsOK or type(exists) ~= "boolean" then return nil, "error" end
    if not exists then return nil, "missing" end
    ---@type File?
    local file = nil
    local ok, text = pcall(function()
        file = File(path, FILE_READ)
        if not file or not file:IsOpen() then return nil end
        local size = file:GetSize()
        if size <= 0 or size > MAX_FILE_BYTES then return nil end
        local content = file:ReadString()
        -- ReadString 可消费 WriteString 的末尾 NUL，但不接受 NUL 后的尾随数据。
        if file:GetPosition() ~= size then return nil end
        return content
    end)
    local released = ReleaseFile(file)
    if not ok or not released then return nil, "error" end
    if type(text) ~= "string" or text == "" then return nil, "invalid" end
    return text, "ok"
end

---@param path string
---@return LevelSaveDocument? document
---@return string? text 已校验的原始内容，用作恢复备份。
---@return string status
local function ReadDocument(path)
    local text, status = ReadText(path)
    if not text then return nil, nil, status end
    local document = DecodeDocument(text)
    if not document then return nil, nil, "invalid" end
    return document, text, "ok"
end

-- 每次读取当前用户沙箱，不缓存布局，避免切换用户后沿用旧内存存档。
-- 全文严格校验：版本不兼容、任一关布局损坏都尝试完整备份，不混合两份记录。
---@return LevelSaveDocument? document
---@return string? text
---@return string? sourcePath
local function ReadStore()
    local document, text, mainStatus = ReadDocument(SAVE_PATH)
    if document then return document, text, SAVE_PATH end
    local backup, backupText, backupStatus = ReadDocument(BACKUP_PATH)
    if backup then
        Warn("主存档不可用，使用已校验备份")
        return backup, backupText, BACKUP_PATH
    end
    if mainStatus == "missing" and backupStatus == "missing" then
        return EmptyDocument(), nil, nil
    end
    Warn("本地存档不可用（主文件 " .. mainStatus .. "，备份 " .. backupStatus .. "）")
    -- 读取返回 nil 由宿主使用默认关卡；禁止以空数据覆盖损坏/未知版本存档。
    return nil, nil, nil
end

---@return boolean
local function EnsureDirectory()
    local ok, ready = pcall(function()
        if fileSystem:DirExists(SAVE_DIR) then return true end
        return fileSystem:CreateDir(SAVE_DIR) == true
    end)
    return ok and ready == true
end

-- Flush 没有成功返回值；WriteString 必须为 true，并关闭后重新读取比对原文。
-- 无 rename 原子性假设：写主文件前保住一份已校验备份，处理截断/短写/异常。
---@param path string
---@param text string
---@return boolean
local function WriteVerified(path, text)
    ---@type File?
    local file = nil
    local ok, written = pcall(function()
        file = File(path, FILE_WRITE)
        if not file or not file:IsOpen() then return false end
        if file:WriteString(text) ~= true then return false end
        file:Flush()
        return true
    end)
    local released = ReleaseFile(file)
    if not ok or written ~= true or not released then return false end
    local actual = ReadText(path)
    return actual == text
end

-- 布局与通关记录共用一次主备写入；更新任一部分都保留另一部分。
local function WriteStore(document, oldText, sourcePath)
    local stored = { version = VERSION, levels = {}, completed = document.completed, highScore10 = document.highScore10 }
    for key, entry in pairs(document.levels) do
        local copy = CopyLayout(entry, tonumber(key))
        if not copy then Warn("保存中止：布局白名单校验失败"); return false end
        stored.levels[key] = { floors = copy.floors, props = copy.props, fences = copy.fences,
            inventory = copy.inventory }
    end
    local encoded, text = pcall(function() return cjson.encode(stored) end)
    if not encoded or type(text) ~= "string" or #text + 1 > MAX_FILE_BYTES or not DecodeDocument(text) then
        Warn("保存中止：JSON 编码/往返校验失败或存档超限"); return false
    end
    if not EnsureDirectory() then Warn("保存中止：本地存档目录不可写"); return false end
    if sourcePath ~= BACKUP_PATH and not WriteVerified(BACKUP_PATH, oldText or text) then
        Warn("保存中止：备份写入/回读失败，未改动主文件"); return false
    end
    if not WriteVerified(SAVE_PATH, text) then
        Warn("保存失败：主文件写入/回读失败，后续读取尝试备份"); return false
    end
    return true
end

---@return table<string, boolean>
function LevelSave.LoadCompleted()
    local document = ReadStore()
    return document and document.completed or {}
end

--- 旧 version1 无 highScore10 时为0；不可恢复/未知版本档返回nil而不是伪造空档。
---@return integer? highest
function LevelSave.LoadHighScore()
    local document = ReadStore()
    if not document then return nil end
    return document.highScore10 or 0
end

--- 仅提高挑战峰值；复用布局主备读写事务，保留既有 completed、布局和库存白名单。
---@param peak integer
---@return boolean saved
function LevelSave.SaveHighScore(peak)
    if not CellIndex(peak) or peak < 0 then Warn("最高分拒绝：必须为可往返的非负整数"); return false end
    local document, oldText, sourcePath = ReadStore()
    if not document then Warn("最高分未写入，保留不可用原存档"); return false end
    local highest = document.highScore10 or 0
    if document.highScore10 ~= nil and peak <= highest and sourcePath == SAVE_PATH then return true end
    document.highScore10 = math.max(highest, math.floor(peak))
    if not WriteStore(document, oldText, sourcePath) then return false end
    print("[LevelSave] 挑战历史最高峰值 " .. tostring(document.highScore10))
    return true
end

---@param number number
---@return boolean
function LevelSave.MarkCompleted(number)
    if not LevelNumber(number) then return false end
    local document, oldText, sourcePath = ReadStore()
    if not document then Warn("通关记录未写入，保留不可用原存档"); return false end
    local key = tostring(math.floor(number))
    if document.completed[key] then return true end
    document.completed[key] = true
    if not WriteStore(document, oldText, sourcePath) then return false end
    print("[LevelSave] 首次记录通关 Level " .. key)
    return true
end

--- 更新版首次启动时清空全部关卡布局及备份；只能在尚未创建关卡时调用。
--- 删除后逐一复验，并最后写标记；失败不标记成功，下一次启动仍可重试。
---@return boolean
function LevelSave.ResetForUpdate()
    local revision = ReadText(RESET_PATH)
    if revision == RESET_REVISION then return true end
    if not EnsureDirectory() then Warn("清档失败：存档目录不可写"); return false end
    local paths = { SAVE_PATH, BACKUP_PATH, "saves/miaojang-validation-layouts.json",
        "saves/miaojang-validation-layouts.json.bak" }
    for _, path in ipairs(paths) do
        local ok, cleared = pcall(function()
            if fileSystem:FileExists(path) and fileSystem:Delete(path) ~= true then return false end
            return not fileSystem:FileExists(path)
        end)
        if not ok or not cleared then Warn("清档失败：" .. path); return false end
    end
    if not WriteVerified(RESET_PATH, RESET_REVISION) then
        Warn("旧布局已清除，但一次性清档标记写入失败")
        return false
    end
    print("[LevelSave] 全部关卡旧存档及备份已清空，后续启动保留新的游玩布局")
    return true
end

--- 只读指定关存档；不存在/非法关号/不可用文件均返回 nil。
--- 返回脱离磁盘和调用方原表的白名单快照，prepared 永远为 false。
---@param number number 正整数关号。
---@return LevelSaveLayout?
function LevelSave.Load(number)
    if not LevelNumber(number) then Warn("读取拒绝：关号必须为有效正整数"); return nil end
    local document = ReadStore()
    if not document then return nil end
    return document.levels[tostring(math.floor(number))]
end

--- 进入第 L 关只继承 L-1 的最后布局；不读取 L 自身，也不回退到更早关卡。
--- 第一关或前一关没有布局时返回 nil, nil，使用默认初始布局。
---@param number number
---@return LevelSaveLayout? layout
---@return number? sourceNumber
function LevelSave.GetForLevel(number)
    if not LevelNumber(number) then Warn("读取拒绝：关号必须为有效正整数"); return nil, nil end
    local currentNumber = math.floor(number)
    if currentNumber <= 1 then return nil, nil end
    local document = ReadStore()
    if not document then return nil, nil end
    local previousNumber = currentNumber - 1
    ---@type LevelSaveLayout?
    local previous = document.levels[tostring(previousNumber)]
    if previous then return previous, previousNumber end
    return nil, nil
end

--- 保存已提交楼层和道具布局，不保存猫/计数，也不把 prepared 持久化。
--- false 表示未确认主文件写入成功；不抛出文件/cjson 异常、不修改调用者表。
---@param number number
---@param layout RescueLevelLayout|LevelSaveLayout
---@return boolean
function LevelSave.Save(number, layout)
    if not LevelNumber(number) then Warn("保存拒绝：关号必须为有效正整数"); return false end
    local valid, copy = pcall(CopyLayout, layout, number)
    if not valid or not copy then Warn("保存拒绝：楼层或道具布局非法"); return false end
    local document, oldText, sourcePath = ReadStore()
    if not document then Warn("保存中止，保留原文件以免覆盖不可恢复存档"); return false end
    document.levels[tostring(math.floor(number))] = copy
    if not WriteStore(document, oldText, sourcePath) then return false end
    print("[LevelSave] 已保存关卡 " .. tostring(math.floor(number)) .. " 的楼层和道具布局")
    return true
end

return LevelSave
