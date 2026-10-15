-- 首页只读通关快照；共享布局存储的严格校验与主备份，不新增跨用户内存缓存。
local Save = require("Global.LevelSave")
local Progress = {}

function Progress.Load()
    return { completed = Save.LoadCompleted() }
end

---@param number number
---@return boolean
function Progress.IsCompleted(number)
    return Save.LoadCompleted()[tostring(math.floor(number))] == true
end

---@return integer
function Progress.Count()
    local count = 0
    for _, done in pairs(Save.LoadCompleted()) do
        if done then count = count + 1 end
    end
    return count
end

---@param number number
---@return boolean
function Progress.Complete(number)
    return Save.MarkCompleted(number)
end

return Progress
