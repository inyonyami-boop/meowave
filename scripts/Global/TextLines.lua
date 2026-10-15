-- 文案读取与 UTF-8 字符处理：教程、锦旗和信纸共享，不编造缺失文案。
-- 教程：开头未标记的段落两版共享；“##”起电脑版段，“#”起手机版段，持续到下一标记。
-- 标记可独占一行，也可紧接正文（兼容 Level1）；[] 只标记强调内容，不占显示字符数。
local Text = {}

---@param value string
---@return string[]
function Text.Characters(value)
    local result = {}
    for _, code in utf8.codes(value) do result[#result + 1] = utf8.char(code) end
    return result
end

---@param path string
---@return string[]
function Text.Lines(path)
    local lines = {}
    if not cache:Exists(path) then
        print("[文案] 缺少文件：" .. path)
        return lines
    end
    local file = cache:GetFile(path)
    if not file then print("[文案] 无法读取：" .. path); return lines end
    while not file:IsEof() do
        local line = file:ReadLine():gsub("^\239\187\191", ""):gsub("\r$", "")
        if line:match("%S") then lines[#lines + 1] = line end
    end
    file:Close()
    file:Dispose()
    print(string.format("[文案] 读取成功：%s，共 %d 行", path, #lines))
    return lines
end

-- TXT 不属于启动阻塞资源；冷缓存下先下载再读取，不能把“尚未下载”当成缺失原文。
---@param path string
---@param onComplete fun(lines: string[], errorMessage: string?)
function Text.LoadLines(path, onComplete)
    if cache:Exists(path) then
        onComplete(Text.Lines(path), nil)
        return
    end
    print("[文案] 等待下载：" .. path)
    local completed = false
    ---@param lines string[]
    ---@param message string?
    local function Finish(lines, message)
        if completed then return end
        completed = true
        onComplete(lines, message)
    end
    local ok, message = pcall(function()
        cache:DownloadResource(path, function(success, errorMessage)
            if not success then Finish({}, errorMessage); return end
            local lines = Text.Lines(path)
            if #lines > 0 then Finish(lines, nil)
            else Finish(lines, "下载完成但文案为空或无法读取") end
        end)
    end)
    if not ok then Finish({}, tostring(message)) end
end

---@param lines string[]
---@param mobile boolean
---@return string[]
function Text.TutorialLines(lines, mobile)
    local result = {}
    local platform = "shared"
    for _, source in ipairs(lines) do
        local line = source:gsub("^\239\187\191", ""):gsub("\r$", "")
        -- 必须先判 ##：否则电脑版标记会误入手机版分支。
        if line:sub(1, 2) == "##" then
            platform = "pc"
            line = line:sub(3):gsub("^%s+", "")
        elseif line:sub(1, 1) == "#" then
            platform = "mobile"
            line = line:sub(2):gsub("^%s+", "")
        end
        local visible = platform == "shared" or (platform == "mobile" and mobile)
            or (platform == "pc" and not mobile)
        if visible and line:match("%S") then result[#result + 1] = line end
    end
    return result
end

-- 返回可见 UTF-8 字符和逐字符强调色编号；成对括号不参与排版和逐字计时。
-- 多个强调片段交替用色，普通正文编号为 0。未闭合括号保留原文，不吞掉正文。
---@param value string
---@return string[] chars
---@return integer[] highlights
function Text.TutorialCharacters(value)
    local chars, highlights = {}, {}
    local cursor, emphasis = 1, 0
    ---@param fragment string
    ---@param color integer
    local function Append(fragment, color)
        for _, char in ipairs(Text.Characters(fragment)) do
            chars[#chars + 1] = char
            highlights[#highlights + 1] = color
        end
    end
    while cursor <= #value do
        local first = value:find("[", cursor, true)
        local last = first and value:find("]", first + 1, true)
        if not first or not last then
            Append(value:sub(cursor), 0)
            break
        end
        Append(value:sub(cursor, first - 1), 0)
        emphasis = emphasis + 1
        Append(value:sub(first + 1, last - 1), (emphasis - 1) % 2 + 1)
        cursor = last + 1
    end
    return chars, highlights
end

---@param path string
---@return string
function Text.RandomLine(path)
    local lines = Text.Lines(path)
    if #lines == 0 then return "" end
    return lines[math.random(1, #lines)] or ""
end

-- 保守按字符宽度换行，预先为整句确定字号，逐字出现时不会反复跳行。
---@param value string
---@param width number
---@param height number
---@param fontSize number
---@return string[] chars
---@return number size
---@return integer capacity
function Text.Layout(value, width, height, fontSize)
    local chars = Text.Characters(value)
    local size = fontSize
    local capacity = math.max(1, math.floor(width / (size * 1.4)))
    while math.ceil(#chars / capacity) * size * 1.65 > height and size > 8 do
        size = size - 1
        capacity = math.max(1, math.floor(width / (size * 1.4)))
    end
    return chars, size, capacity
end

---@param rows Label[]
---@param chars string[]
---@param count integer
---@param capacity integer
function Text.FillRows(rows, chars, count, capacity)
    for index, row in ipairs(rows) do
        local first = (index - 1) * capacity + 1
        local last = math.min(count, index * capacity)
        row:SetText(first <= last and table.concat(chars, "", first, last) or "")
    end
end

return Text

