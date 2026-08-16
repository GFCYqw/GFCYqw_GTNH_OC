--[[
  crafting.lua — AE 合成下单模块
  参考 AutoCraft.lua 的完整实现：CPU管理、发起合成请求、追踪状态、失败重试。
]]

local CraftingManager = {}
local meNetwork = nil   -- me_controller 或 me_interface
local gpu = nil          -- 可选的 GPU 用于彩色输出

-- ==================== 配置 ====================

local CONFIG = {
    maxRetryHalf = 10,
    lowestOrderQuantity = 1000,
    singleCpuWaitTime = 10,
    multiCpuInterval = 3,
}

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

function CraftingManager.init(network, gpuComponent, config)
    meNetwork = network
    gpu = gpuComponent
    if config then
        CONFIG.maxRetryHalf = config.maxRetryHalf or CONFIG.maxRetryHalf
        CONFIG.lowestOrderQuantity = config.lowestOrderQuantity or CONFIG.lowestOrderQuantity
        CONFIG.singleCpuWaitTime = config.singleCpuWaitTime or CONFIG.singleCpuWaitTime
        CONFIG.multiCpuInterval = config.multiCpuInterval or CONFIG.multiCpuInterval
    end
    return meNetwork ~= nil
end

-- ==================== CPU 管理 ====================

--- 获取所有可用的合成 CPU
--- @return table CPU 列表
function CraftingManager.getAvailableCPUs()
    if not meNetwork then return {} end

    local ok, cpus = pcall(function()
        return meNetwork.getCpus()
    end)

    if not ok or not cpus then
        return {}
    end

    -- 过滤：只保留有合成监控器的 CPU
    local validCPUs = {}
    for _, cpu in ipairs(cpus) do
        if cpu.cpu then
            table.insert(validCPUs, cpu)
        end
    end

    return validCPUs
end

--- 获取 CPU 数量
--- @return number
function CraftingManager.getCPUCount()
    local cpus = CraftingManager.getAvailableCPUs()
    return #cpus
end

--- 检查是否有空闲 CPU
--- @return boolean
function CraftingManager.hasIdleCPU()
    local cpus = CraftingManager.getAvailableCPUs()
    for _, cpu in ipairs(cpus) do
        local busy = false
        pcall(function()
            busy = cpu.busy
        end)
        if not busy then
            return true
        end
    end
    return false
end

--- 检查是否有 CPU 正在合成指定物品
--- @param itemLabel string 物品显示名
--- @return boolean
function CraftingManager.isItemBeingCrafted(itemLabel)
    local cpus = CraftingManager.getAvailableCPUs()
    for _, cpu in ipairs(cpus) do
        local busy = false
        pcall(function() busy = cpu.busy end)
        if busy then
            local ok, output = pcall(function()
                return cpu.cpu.finalOutput()
            end)
            if ok and output and output.label == itemLabel then
                return true
            end
        end
    end
    return false
end

-- ==================== 合成请求 ====================

--- 获取指定物品的可合成项
--- @param itemLabel string
--- @return table|nil
local function getCraftable(itemLabel)
    local ok, craftables = pcall(function()
        return meNetwork.getCraftables({ label = itemLabel })
    end)
    if not ok or not craftables or #craftables == 0 then
        return nil
    end
    return craftables[1]
end

--- 发起合成请求并等待完成
--- @param itemLabel string 物品显示名
--- @param quantity number 请求合成的数量
--- @return boolean 是否成功
--- @return string 结果消息
function CraftingManager.craftItem(itemLabel, quantity)
    if not meNetwork then
        return false, "ME 网络未连接"
    end

    local craftable = getCraftable(itemLabel)
    if not craftable then
        return false, "物品 " .. itemLabel .. " 缺少合成配方"
    end

    local cpuCount = CraftingManager.getCPUCount()

    -- 单 CPU 模式：等待当前任务完成
    if cpuCount <= 1 then
        local cpus = CraftingManager.getAvailableCPUs()
        if #cpus > 0 then
            local busy = false
            pcall(function() busy = cpus[1].busy end)
            while busy do
                print("  ME 合成器忙碌中，等待 " .. CONFIG.singleCpuWaitTime .. " 秒...")
                os.sleep(CONFIG.singleCpuWaitTime)
                pcall(function() busy = cpus[1].busy end)
            end
        end
    else
        -- 多 CPU 模式：检查是否已有 CPU 在合成相同物品
        if CraftingManager.isItemBeingCrafted(itemLabel) then
            print("  已有 CPU 正在合成 " .. itemLabel .. "，跳过重复请求")
            return true, "已有 CPU 在处理"
        end

        -- 等待空闲 CPU
        while not CraftingManager.hasIdleCPU() do
            print("  ME 合成器全部忙碌中，等待 10 秒...")
            os.sleep(10)
        end
    end

    -- 尝试合成（带减半重试）
    local tryTimes = CONFIG.maxRetryHalf
    local requestQuantity = quantity

    while tryTimes > 0 do
        tryTimes = tryTimes - 1

        print(string.format("  请求合成: %s x %s (剩余重试: %d)",
            itemLabel, formatNumber(requestQuantity), tryTimes))

        local ok, craft = pcall(function()
            return craftable.request(requestQuantity)
        end)

        if not ok or not craft then
            print("  合成请求提交失败")
            return false, "请求提交失败"
        end

        -- 等待计算完成
        local computingTimeout = 30
        while computingTimeout > 0 do
            local isComputing = false
            pcall(function() isComputing = craft.isComputing() end)
            if not isComputing then break end
            os.sleep(1)
            computingTimeout = computingTimeout - 1
        end

        -- 检查失败
        local hasFailed = false
        pcall(function() hasFailed = craft.hasFailed() end)
        if hasFailed then
            print("  合成请求失败")

            -- 减半重试
            if requestQuantity > CONFIG.lowestOrderQuantity then
                local newQty = math.ceil(requestQuantity / 4)
                if newQty < CONFIG.lowestOrderQuantity then
                    newQty = CONFIG.lowestOrderQuantity
                end
                if newQty < requestQuantity then
                    print(string.format("  减少数量至 %s 后重试", formatNumber(newQty)))
                    requestQuantity = newQty
                else
                    print("  已达最低请求数量，放弃本次合成")
                    return false, "已达最低数量限制"
                end
            else
                print("  请求数量已达最低限制，放弃合成")
                return false, "已达最低数量限制"
            end
        else
            -- 成功提交
            if cpuCount <= 1 then
                -- 单 CPU：等待完成
                print("  等待合成完成...")
                while true do
                    local isDone = false
                    local isCanceled = false
                    pcall(function() isDone = craft.isDone() end)
                    pcall(function() isCanceled = craft.isCanceled() end)
                    if isDone then
                        print("  合成已完成")
                        break
                    end
                    if isCanceled then
                        print("  合成被取消")
                        return false, "合成被取消"
                    end
                    os.sleep(CONFIG.singleCpuWaitTime)
                end
            else
                -- 多 CPU：提交后立即返回
                print("  合成请求已提交（多 CPU 模式）")
                os.sleep(CONFIG.multiCpuInterval)
            end
            return true, "合成请求成功"
        end
    end

    return false, "多次重试后仍失败"
end

--- 处理产物维持订单（批量）
--- @param needsOrder table { items = {...}, fluids = {...} }
--- @return number 成功下单的数量
function CraftingManager.processMaintenanceOrders(needsOrder)
    local successCount = 0

    -- 注意：流体不能直接通过 AE 合成，这里只处理物品
    -- 流体维持需要通过其他方式（例如保持机器运行）

    for _, item in ipairs(needsOrder.items or {}) do
        local orderQuantity = item.deficit
        if orderQuantity > 0 then
            local ok, msg = CraftingManager.craftItem(item.displayName, orderQuantity)
            if ok then
                successCount = successCount + 1
                print(string.format("  [成功] %s 下单 %s", item.displayName, formatNumber(orderQuantity)))
            else
                print(string.format("  [失败] %s: %s", item.displayName, msg))
            end
        end
    end

    -- 流体目标：仅做警告提示
    if needsOrder.fluids and #needsOrder.fluids > 0 then
        print("  [提示] 以下流体低于阈值，需要人工处理：")
        for _, fluid in ipairs(needsOrder.fluids) do
            print(string.format("    %s: 差额 %s mB", fluid.displayName, formatNumber(fluid.deficit)))
        end
    end

    return successCount
end

-- ==================== 导出 ====================

return CraftingManager
