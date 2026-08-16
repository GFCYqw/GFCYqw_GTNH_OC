--[[
  maintainer.lua — Level Maintainer（请求器）读取模块
  读取连接到 OC 的所有 ME 请求器，解析出需要维持的目标产物和阈值。
]]

local MaintainerReader = {}

-- ==================== 内部数据结构 ====================

--- @class MaintenanceTarget
--- @field name string          物品/流体注册名
--- @field displayName string   显示名 (label)
--- @field quantity number      维持阈值
--- @field batch number         单次合成批量
--- @field isFluid boolean      是否为流体
--- @field damage number        物品损伤值（仅物品）
--- @field isEnable boolean     是否启用

-- ==================== 请求器读取 ====================

--- 从单个请求器读取所有槽位的配置
--- @param maintainer userdata Level Maintainer 代理
--- @return table 目标列表
local function readMaintainerSlots(maintainer)
    local targets = {}

    for slot = 1, 9 do  -- Level Maintainer 通常有 9 个槽位
        local ok, slotData = pcall(function()
            return maintainer.getSlot(slot)
        end)

        if ok and slotData and slotData.isEnable then
            local target = {
                name = slotData.name or "",
                displayName = slotData.label or slotData.name or "未知",
                quantity = slotData.quantity or 0,
                batch = slotData.batch or 1,
                isFluid = slotData.isFluid or false,
                damage = slotData.damage or 0,
                isEnable = true,
                sourceSlot = slot,
            }

            -- 处理流体：取 fluid.name 作为标识
            if target.isFluid and slotData.fluid then
                target.name = slotData.fluid.name or target.name
            end

            -- 处理物品 ID 格式 "name:damage"
            if not target.isFluid and target.name then
                local nameFromID, damageFromID = target.name:match("^(.+):(%d+)$")
                if nameFromID and damageFromID then
                    target.name = nameFromID
                    target.damage = tonumber(damageFromID)
                end
            end

            table.insert(targets, target)
        end
    end

    return targets
end

-- ==================== 公开 API ====================

--- 扫描所有请求器，返回需维持的目标列表
--- @param maintainers table Level Maintainer 代理列表
--- @return table { items = {...}, fluids = {...} }
function MaintainerReader.scanAll(maintainers)
    local allTargets = { items = {}, fluids = {} }

    if not maintainers or #maintainers == 0 then
        return allTargets
    end

    for _, maintainer in ipairs(maintainers) do
        local ok, targets = pcall(readMaintainerSlots, maintainer)
        if ok then
            for _, target in ipairs(targets) do
                if target.isFluid then
                    table.insert(allTargets.fluids, target)
                else
                    table.insert(allTargets.items, target)
                end
            end
        end
    end

    -- 去重：同一物品/流体只保留一个（取最高阈值）
    allTargets.items = MaintainerReader.deduplicate(allTargets.items)
    allTargets.fluids = MaintainerReader.deduplicate(allTargets.fluids)

    return allTargets
end

--- 去重：同名目标合并，保留最高阈值
--- @param targets table 目标列表
--- @return table 去重后的列表
function MaintainerReader.deduplicate(targets)
    local seen = {}
    local result = {}

    for _, target in ipairs(targets) do
        local key = target.name
        if target.damage and target.damage > 0 then
            key = key .. ":" .. target.damage
        end

        if seen[key] then
            -- 保留较大的阈值和批量
            if target.quantity > seen[key].quantity then
                seen[key].quantity = target.quantity
            end
            if target.batch > seen[key].batch then
                seen[key].batch = target.batch
            end
        else
            seen[key] = target
            table.insert(result, target)
        end
    end

    return result
end

--- 格式化输出目标列表（调试用）
--- @param targets table
--- @return string
function MaintainerReader.formatTargets(targets)
    local lines = {}

    if #targets.items > 0 then
        table.insert(lines, string.format("--- 物品目标 (%d 项) ---", #targets.items))
        for _, t in ipairs(targets.items) do
            table.insert(lines, string.format("  %s | 阈值: %d | 批量: %d",
                t.displayName, t.quantity, t.batch))
        end
    end

    if #targets.fluids > 0 then
        table.insert(lines, string.format("--- 流体目标 (%d 项) ---", #targets.fluids))
        for _, t in ipairs(targets.fluids) do
            table.insert(lines, string.format("  %s | 阈值: %d | 批量: %d",
                t.displayName, t.quantity, t.batch))
        end
    end

    return table.concat(lines, "\n")
end

-- ==================== 导出 ====================

return MaintainerReader
