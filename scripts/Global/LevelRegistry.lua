-- 关卡注册表：结算“继续”按编号查找下一关，未来新关卡在此登记即可接入。
local Registry = {}
---@type table<number, table>
Registry.configs = {}

function Registry.Register(number, config)
    Registry.configs[number] = config
end

function Registry.Get(number)
    return Registry.configs[number]
end

return Registry
