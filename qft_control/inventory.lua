--[[
  inventory.lua — AE 网络库存查询模块
  查询 ME 网络中的物品和流体存量，判断是否低于阈值。
]]

local InventoryChecker = {}
local meNetwork = nil  -- me_controller 或 me_interface

-- ==================== 数值格式化 ====================

local function formatNumber(num)
    if type(num) ~= "number" then num = tonumber(num) or 0 end
    if num >= 1e12 then return string.format("%.2fT", num / 1e12)
    elseif num >= 1e9 then return string.format("%.2fG", num / 1e9)
    elseif num >= 1e6 then return string.format("%.2fM", num / 1e6)
    elseif num >= 1e3 then return string.format("%.2fk", num / 1e3)
    else return tostring(math.floor(num)) end
end

-- ==================== 初始化 ====================

--- 初始化库存检查器
--- @param network userdata ME 接口或 ME 控制器代理
function InventoryChecker.init(network)
    meNetwork = network
    return meNetwork ~= nil
end

-- ==================== 物品查询 ====================

--- 查询 ME 网络中指定物品的总量
--- @param itemLabel string 物品的显示名 (label)
--- @return number 总数量，失败返回 0
function InventoryChecker.getItemAmount(itemLabel)
    if not meNetwork then return 0 end

    local ok, items = pcall(function()
        return meNetwork.getItemsInNetwork({ label = itemLabel })
    end)

    if not ok or not items then
        return 0
    end

    local total = 0
    for _, item in ipairs(items) do
        if item.size then
            total = total + item.size
        end
    end

    return total
end

--- 按名称和损伤值查询物品
--- @param itemName string 物品注册名
--- @param damage number 损伤值
--- @return number
function InventoryChecker.getItemAmountByName(itemName, damage)
    if not meNetwork then return 0 end

    local filter = { name = itemName }
    if damage and damage > 0 then
        filter.damage = damage
    end

    local ok, items = pcall(function()
        return meNetwork.getItemsInNetwork(filter)
    end)

    if not ok or not items then
        return 0
    end

    local total = 0
    for _, item in ipairs(items) do
        if item.size then
            total = total + item.size
        end
    end

    return total
end

-- ==================== 流体查询 ====================

--- 查询 ME 网络中指定流体的总量
--- @param fluidName string 流体注册名
--- @return number 总数量（mB），失败返回 0
function InventoryChecker.getFluidAmount(fluidName)
    if not meNetwork then return 0 end

    local ok, fluids = pcall(function()
        return meNetwork.getFluidsInNetwork()
    end)

    if not ok or not fluids then
        return 0
    end

    for _, fluid in ipairs(fluids) do
        if fluid.name == fluidName then
            local amount = fluid.amount or fluid.size or 0
            return tonumber(amount) or 0
        end
    end

    return 0
end

-- ==================== 阈值检查 ====================

--- 检查目标是否低于阈值
--- @param target table 维持目标 { name, displayName, quantity, isFluid, damage }
--- @return boolean true=低于阈值需要补货
--- @return number 当前存量
--- @return number 差额
function InventoryChecker.isBelowThreshold(target)
    local current = 0

    if target.isFluid then
        current = InventoryChecker.getFluidAmount(target.name)
    else
        if target.damage and target.damage > 0 then
            current = InventoryChecker.getItemAmountByName(target.name, target.damage)
        else
            current = InventoryChecker.getItemAmount(target.displayName)
        end
    end

    local threshold = target.quantity or 0
    local deficit = threshold - current

    return current < threshold, current, math.max(0, deficit)
end

--- 批量检查目标列表，返回需要补货的项
--- @param targets table { items = {...}, fluids = {...} }
--- @return table 需要补货的目标列表
--- @return table 库存状态摘要
function InventoryChecker.checkAllTargets(targets)
    local needsOrder = { items = {}, fluids = {} }
    local summary = {}

    -- 检查物品
    for _, target in ipairs(targets.items or {}) do
        local needOrder, current, deficit = InventoryChecker.isBelowThreshold(target)
        if needOrder then
            local t = {
                name = target.name,
                displayName = target.displayName,
                quantity = target.quantity,
                batch = target.batch,
                isFluid = false,
                damage = target.damage,
                current = current,
                deficit = deficit,
            }
            table.insert(needsOrder.items, t)
            table.insert(summary, string.format("[物品] %s | 存量: %s | 阈值: %s | 差额: %s",
                target.displayName,
                formatNumber(current),
                formatNumber(target.quantity),
                formatNumber(deficit)))
        end
    end

    -- 检查流体
    for _, target in ipairs(targets.fluids or {}) do
        local needOrder, current, deficit = InventoryChecker.isBelowThreshold(target)
        if needOrder then
            local t = {
                name = target.name,
                displayName = target.displayName,
                quantity = target.quantity,
                batch = target.batch,
                isFluid = true,
                current = current,
                deficit = deficit,
            }
            table.insert(needsOrder.fluids, t)
            table.insert(summary, string.format("[流体] %s | 存量: %s mB | 阈值: %s mB | 差额: %s mB",
                target.displayName,
                formatNumber(current),
                formatNumber(target.quantity),
                formatNumber(deficit)))
        end
    end

    return needsOrder, summary
end

-- ==================== 导出 ====================

InventoryChecker.formatNumber = formatNumber
return InventoryChecker
