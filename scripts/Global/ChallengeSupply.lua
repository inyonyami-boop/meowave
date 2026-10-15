-- 无尽段供给排序：只查询真实网格规则，不改承托/屋顶、不抽随机、不消费配额。
-- 候选来自实楼四邻；屋顶装饰不是实楼，不能凭它制造承托。
local Supply = {}

---@class ChallengeSupplyCell
---@field col number
---@field row number

---@param grid BuildingGrid
---@return ChallengeSupplyCell[]
local function Candidates(grid)
    local cells, seen = {}, {}
    local directions = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
    for _, blocks in ipairs({ grid.seeds, grid.blocks }) do
        for _, block in ipairs(blocks) do
            for _, direction in ipairs(directions) do
                local col, row = block.col + direction[1], block.row + direction[2]
                local key = tostring(col) .. ":" .. tostring(row)
                if not seen[key] then
                    seen[key] = true
                    if grid:IsInBounds(col, row) and not grid:IsOccupied(col, row) then
                        cells[#cells + 1] = { col = col, row = row }
                    end
                end
            end
        end
    end
    return cells
end

---@param grid BuildingGrid
---@param cells ChallengeSupplyCell[]
---@param kind integer
---@return boolean
local function CanPlaceKind(grid, cells, kind)
    assert(kind >= 0 and kind <= 14, "挑战供给必须保留合法楼层编码")
    local floorType = kind - kind % 3
    local roofStyle = kind % 3
    local roof = roofStyle > 0 and roofStyle or nil
    for _, cell in ipairs(cells) do
        if grid:CanPlace(cell.col, cell.row, roof, nil, floorType == 3, floorType == 6,
            floorType == 9, floorType == 12) then return true end
    end
    return false
end

--- 仅建设开始/实楼放置后调用；缓存只活于此次检查，避免沿用旧邻接结果。
--- 当前不可放时选后续首个可放编码交换，其余供给与全部已消费前缀保持不变。
---@param grid BuildingGrid
---@param supply integer[]
---@param first integer
---@return boolean placeable
---@return boolean reordered
function Supply.SelectPlaceable(grid, supply, first)
    if first > #supply then return false, false end
    local cells = Candidates(grid)
    ---@type table<number, boolean>
    local available = {}
    for index = first, #supply do
        local kind = supply[index]
        if available[kind] == nil then available[kind] = CanPlaceKind(grid, cells, kind) end
        if available[kind] then
            if index == first then return true, false end
            supply[first], supply[index] = supply[index], supply[first]
            return true, true
        end
    end
    return false, false
end

--- 每段的新三份先独立抽完，再拼接旧延期。只复制编码，不重抽、不改输入。
---@param fresh integer[]
---@param deferred integer[]?
---@return integer[]
function Supply.Combine(fresh, deferred)
    local combined = {}
    for _, kind in ipairs(deferred or {}) do combined[#combined + 1] = kind end
    for _, kind in ipairs(fresh) do combined[#combined + 1] = kind end
    return combined
end

return Supply
