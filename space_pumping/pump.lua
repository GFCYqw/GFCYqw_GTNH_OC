--[[
  综合脚本：AR眼镜流体监控 + 自动维持（太空钻机生产） v2.0
  功能：
    1. AR眼镜实时显示流体存量、变化率、阈值警告。
    2. 按优先级分配不同流体到不同槽位，目标为阈值的200%。
    3. 自动发现钻机并检测等级（lv1/lv2/lv3），显示等级信息。
    4. 终端以仪表板形式显示当前状态，展示每个流体的实际库存与200%目标。
    5. 所有流体达到200%时自动关闭钻机；单流体达标后其槽位切换至其他流体。
    6. 空余槽位随机安排未达标流体抽取。
    7. 变化率基于眼镜刷新的实际间隔（computer.uptime）计算。
]]

local component = require("component")
local event = require("event")
local computer = require("computer")
local os = require("os")
local term = require("term")

-- ==================== 安全获取组件 ====================
local glasses = nil
for address in component.list("glasses") do
    glasses = component.proxy(address)
    break
end

local me = nil
for address in component.list("me_interface") do
    me = component.proxy(address)
    break
end

-- ==================== 配置 ====================
local textScale = 0.5
local offsetX = 3
local offsetY = 17
local lineSpacing = 0.5
local glassesInterval = 3          -- 眼镜刷新间隔（秒）
local checkInterval = 30           -- 维持检查间隔（秒）
local TARGET_RATIO = 2.0           -- 目标倍率（200%）

-- 泵等级常量
local PUMP_SLOTS = {[1]=1, [2]=4, [3]=4}
local PUMP_PARALLEL = {[1]=1, [2]=4, [3]=64}
local LV_NAMES = {[1]="LV1", [2]="LV2", [3]="LV3"}

-- 流体配置：{注册名, 阈值(mB), 行星参数, 气体参数, 显示名}
local FLUID_CONFIGS = {
    {"liquidair", "1g", 8, 2, "液态空气" },
    {"deuterium", "1g", 6, 1, "氘" },
    {"tritium", "1g", 6, 2, "氚" },
    {"helium-3", "1g", 5, 2, "氦-3" },
    {"fluorine", "4g", 7, 2, "氟" },
    {"sulfuricacid", "1g", 4, 1, "硫酸" },
    {"chlorobenzene", "1g", 2, 1, "氯苯" },
    {"ammonia", "1g", 6, 3, "氨气" },
    {"ic2distilledwater", "2g", 8, 5, "蒸馏水" },
    {"helium", "2g", 5, 4, "氦" },
    {"argon", "100m", 5, 7, "氩" },
    {"krypton", "100m", 5, 8, "氪" },
    {"xenon", "100m", 6, 4, "氙" },
    {"radon", "100m", 8, 6, "氡" },
    {"lava", "100m", 3, 3, "熔岩" },
    {"oil", "100m", 4, 3, "石油" },
    {"methane", "100m", 5, 9, "甲烷" },
    {"ethylene", "1g", 6, 5, "乙烯" },
    {"molten.iron", "100m", 4, 2, "熔融铁" },
    {"molten.copper", "100m", 8, 3, "熔融铜" },
    {"molten.tin", "100m", 8, 7, "熔融锡" },
    {"molten.lead", "100m", 4, 5, "熔融铅" },
}

-- ==================== 内部状态 ====================
local meConnected = false
local statusKey = "me_status"
local machineKey = "machine_count"
local texts = {}
local lastAmounts = {}          -- 存储上次的 amount
local doContinue = true
local lastGlassesTime = 0
local lastCheckTime = 0
local startTime = 0

local PROCESSED_FLUIDS = {}
local gt_machines = {}          -- {proxy, address, lv, name, slots={idx...}}
local slotAssignments = {}      -- {[address:slotIdx] = fluidName} 槽位分配跟踪
local totalSlots = 0            -- 总槽位数

-- ==================== 辅助函数 ====================
local function parseNumberWithSuffix(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" then error("无效的数字格式: " .. tostring(value)) end
    if value == "-1" then return -1 end
    local numPart, suffix = value:match("^([%d%.]+)([kmgt]?)$")
    if not numPart then error("无法解析数字: " .. value) end
    local number = tonumber(numPart)
    if not number then error("无效的数字: " .. numPart) end
    if suffix == "k" then return number * 1e3
    elseif suffix == "m" then return number * 1e6
    elseif suffix == "g" then return number * 1e9
    elseif suffix == "t" then return number * 1e12
    else return number end
end

local function GetUtf8Len(str)
    local len = 0
    local currentIndex = 1
    while currentIndex <= #str do
        local char = string.byte(str, currentIndex)
        currentIndex = currentIndex + (char > 240 and 4 or char > 225 and 3 or char > 192 and 2 or 1)
        len = len + (char > 192 and 2 or 1)
    end
    return len
end

local function getFluidAmount(fluidName)
    if not me then return nil end
    local ok, fluids = pcall(me.getFluidsInNetwork, me)
    if not ok then meConnected = false; return nil end
    meConnected = true
    for _, fluid in ipairs(fluids) do
        if fluid.name == fluidName then
            local amount = fluid.amount or fluid.size
            return tonumber(amount) or 0
        end
    end
    return 0
end

-- ==================== 时间格式化 ====================
local function formatUptime(seconds)
    local days = math.floor(seconds / 86400)
    seconds = seconds % 86400
    local hours = math.floor(seconds / 3600)
    seconds = seconds % 3600
    local mins = math.floor(seconds / 60)
    local secs = math.floor(seconds % 60)
    if days > 0 then
        return string.format("%d天%02d时%02d分%02d秒", days, hours, mins, secs)
    elseif hours > 0 then
        return string.format("%02d时%02d分%02d秒", hours, mins, secs)
    elseif mins > 0 then
        return string.format("%02d分%02d秒", mins, secs)
    else
        return string.format("%02d秒", secs)
    end
end

-- ==================== 眼镜显示 ====================
local function formatFluidAmount(amount)
    if amount == nil then return "NaN" end
    if amount >= 1e12 then return string.format("%.1fT", amount / 1e12)
    elseif amount >= 1e9 then return string.format("%.1fG", amount / 1e9)
    elseif amount >= 1e6 then return string.format("%.1fM", amount / 1e6)
    elseif amount >= 1e3 then return string.format("%.1fk", amount / 1e3)
    else return tostring(math.floor(amount)) end
end

local function formatRate(diff)
    if diff == 0 then return "" end
    local sign = diff > 0 and "+" or "-"
    local absDiff = math.abs(diff)
    local formatted
    if absDiff >= 1e12 then formatted = string.format("%.1fT", absDiff / 1e12)
    elseif absDiff >= 1e9 then formatted = string.format("%.1fG", absDiff / 1e9)
    elseif absDiff >= 1e6 then formatted = string.format("%.1fM", absDiff / 1e6)
    elseif absDiff >= 1e3 then formatted = string.format("%.1fk", absDiff / 1e3)
    else formatted = string.format("%.0f", absDiff) end
    return string.format(" (%s%s/s)", sign, formatted)
end

local function createShadowText(key, x, y)
    y = y * 10
    texts[key .. "shadow"] = glasses.addTextLabel()
    texts[key .. "shadow"].setPosition(x + 1, y + 1)
    texts[key .. "shadow"].setScale(textScale)
    texts[key .. "shadow"].setColor(63/255, 63/255, 63/255)

    texts[key] = glasses.addTextLabel()
    texts[key].setPosition(x, y)
    texts[key].setScale(textScale)
    texts[key].setColor(1, 1, 1)
end

local function setShadowText(key, text, r, g, b)
    texts[key .. "shadow"].setText(text)
    texts[key].setText(text)
    if r and g and b then
        texts[key .. "shadow"].setColor(r/1028, g/1028, b/1028)
        texts[key].setColor(r/255, g/255, b/255)
    end
end

local function glassesSetup()
    if not glasses then return end
    glasses.removeAll()
    createShadowText(statusKey, offsetX, offsetY)
    createShadowText(machineKey, offsetX, offsetY + lineSpacing)
    for i, fluid in ipairs(PROCESSED_FLUIDS) do
        local y = offsetY + (i + 1) * lineSpacing
        createShadowText("fluid_" .. fluid.name, offsetX, y)
    end
end

-- 构建机器状态文本（含等级信息）
local function buildMachineText()
    if #gt_machines == 0 then return "钻机: 无", {255, 85, 85} end
    -- 统计各等级数量
    local lvCount = {}
    for _, m in ipairs(gt_machines) do
        lvCount[m.lv] = (lvCount[m.lv] or 0) + 1
    end
    local parts = {}
    for lv = 1, 3 do
        if lvCount[lv] then
            table.insert(parts, string.format("%s×%d", LV_NAMES[lv], lvCount[lv]))
        end
    end
    return string.format("钻机: %d台 %s (%d槽)", #gt_machines, table.concat(parts, " "), totalSlots), {85, 255, 85}
end

-- 使用眼镜刷新的实际间隔计算变化率
local function updateGlasses(now)
    if not glasses then return end

    -- 更新状态和机器数（含等级）
    local statusText = meConnected and "ME: 在线" or "ME: 离线"
    local statusColor = meConnected and {85, 255, 85} or {255, 85, 85}
    setShadowText(statusKey, statusText, table.unpack(statusColor))

    local machineText, machineColor = buildMachineText()
    setShadowText(machineKey, machineText, table.unpack(machineColor))

    -- 计算时间差（两次眼镜刷新之间的间隔）
    local timeDiff = now - lastGlassesTime
    if timeDiff <= 0 then timeDiff = 0 end

    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        local amount = getFluidAmount(fluid.name)
        local key = "fluid_" .. fluid.name

        local diff = 0
        local lastAmount = lastAmounts[fluid.name]
        if amount ~= nil and lastAmount ~= nil and timeDiff > 0 then
            diff = (amount - lastAmount) / timeDiff
        end

        -- 更新记录
        if amount ~= nil then
            lastAmounts[fluid.name] = amount
        end

        local rateText = formatRate(diff)
        local text = string.format("%s: %s L%s", fluid.display, formatFluidAmount(amount), rateText)

        local r, g, b = 255, 255, 255
        if amount == nil then
            r, g, b = 128, 128, 128           -- 灰色：断连
        elseif fluid.threshold > 0 and amount < fluid.threshold then
            -- 低于100%阈值
            if diff < 0 then
                r, g, b = 255, 85, 85         -- 红色：低于阈值且在减少
            else
                r, g, b = 255, 165, 0         -- 橙色：低于阈值但在增加
            end
        elseif fluid.threshold > 0 and amount < fluid.threshold * TARGET_RATIO then
            -- 100%~200%之间
            if diff < 0 then
                r, g, b = 255, 255, 85        -- 黄色：收集中但在减少
            else
                r, g, b = 85, 255, 85         -- 绿色：收集中且在增加
            end
        else
            r, g, b = 255, 255, 255           -- 白色：已达200%目标
        end
        setShadowText(key, text, r, g, b)
    end
end

-- ==================== 钻机控制 ====================
local function safelyStopMachine(proxy)
    if proxy.isMachineActive() then
        proxy.setWorkAllowed(false)
        local maxWait = 60
        local waitCount = 0
        while proxy.isMachineActive() and waitCount < maxWait do
            os.sleep(1)
            waitCount = waitCount + 1
        end
        if waitCount >= maxWait then
            print("警告：机器停止超时")
            return false
        end
    end
    return true
end

local function shutdownAllMachines()
    local count = 0
    for _, m in ipairs(gt_machines) do
        if safelyStopMachine(m.proxy) then
            count = count + 1
        else
            print("关闭机器失败: " .. m.address:sub(1, 8))
        end
    end
    return count
end

-- ==================== 优先级槽位分配算法 ====================
local function assignSlots()
    if #gt_machines == 0 then return nil end

    -- 1. 收集所有槽位
    local allSlots = {}
    for _, m in ipairs(gt_machines) do
        for _, slotIdx in ipairs(m.slots) do
            table.insert(allSlots, {machine = m, slotIdx = slotIdx})
        end
    end

    -- 2. 筛选未达200%目标的流体，计算缺额（deficit = 目标 - 当前）
    local needy = {}
    local totalDeficit = 0
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        if fluid.threshold > 0 then
            local amount = getFluidAmount(fluid.name)
            if amount ~= nil then
                local target = fluid.threshold * TARGET_RATIO
                if amount < target then
                    local deficit = target - amount
                    table.insert(needy, {fluid = fluid, deficit = deficit})
                    totalDeficit = totalDeficit + deficit
                end
            end
        end
    end

    -- 3. 所有流体达标 → 返回 nil（信号：关机）
    if #needy == 0 then
        return nil
    end

    -- 4. 按缺额比例分配槽位数（最大余数法，参考 pump_wiki.lua）
    local nSlots = #allSlots
    local remainders = {}
    local allocatedTotal = 0

    for i, item in ipairs(needy) do
        local raw = nSlots * item.deficit / totalDeficit
        local base = math.floor(raw)
        item.slots = base
        remainders[i] = {idx = i, remainder = raw - base}
        allocatedTotal = allocatedTotal + base
    end

    -- 剩余槽位按余数从大到小分配
    table.sort(remainders, function(a, b) return a.remainder > b.remainder end)
    for i = 1, nSlots - allocatedTotal do
        needy[remainders[i].idx].slots = needy[remainders[i].idx].slots + 1
    end

    -- 5. 构建分配方案（按优先级顺序填充槽位）
    local assignments = {}
    local slotIdx = 1
    for _, item in ipairs(needy) do
        for _ = 1, item.slots do
            if slotIdx <= nSlots then
                table.insert(assignments, {
                    machine = allSlots[slotIdx].machine,
                    slotIdx = allSlots[slotIdx].slotIdx,
                    fluid = item.fluid
                })
                slotIdx = slotIdx + 1
            end
        end
    end

    return assignments
end

-- ==================== 槽位参数应用 ====================
local function applySlotAssignments(assignments)
    if not assignments or #assignments == 0 then
        return 0, 0
    end

    -- 按机器分组，减少启停次数
    local machineChanges = {}  -- {[machine] = {{slotIdx, fluid}, ...}}
    local changedSlotCount = 0

    for _, a in ipairs(assignments) do
        local key = a.machine.address .. ":" .. a.slotIdx
        if slotAssignments[key] ~= a.fluid.name then
            if not machineChanges[a.machine] then
                machineChanges[a.machine] = {}
            end
            table.insert(machineChanges[a.machine], {slotIdx = a.slotIdx, fluid = a.fluid})
            changedSlotCount = changedSlotCount + 1
        end
    end

    -- 对每台有变化的机器：停止 → 改参数 → 启动
    local changedMachineCount = 0
    for machine, changes in pairs(machineChanges) do
        if not safelyStopMachine(machine.proxy) then
            print(string.format("警告：机器 %s 停止失败", machine.address:sub(1, 8)))
        else
            local ok = true
            for _, ch in ipairs(changes) do
                ok = ok and pcall(machine.proxy.setParameters, ch.slotIdx, 0, ch.fluid.param1)
                ok = ok and pcall(machine.proxy.setParameters, ch.slotIdx, 1, ch.fluid.param2)
                if ok then
                    slotAssignments[machine.address .. ":" .. ch.slotIdx] = ch.fluid.name
                end
            end
            if ok then
                machine.proxy.setWorkAllowed(true)
                changedMachineCount = changedMachineCount + 1
            else
                print(string.format("警告：机器 %s 参数设置失败", machine.address:sub(1, 8)))
            end
        end
    end

    -- 确保所有有分配的机器都在运行（未变化的机器可能被手动关闭）
    for _, a in ipairs(assignments) do
        if not machineChanges[a.machine] then
            if not a.machine.proxy.isMachineActive() then
                a.machine.proxy.setWorkAllowed(true)
            end
        end
    end

    return changedMachineCount, changedSlotCount
end

-- ==================== 终端仪表板 ====================
local function drawDashboard(assignments, adjustmentMsg)
    term.clear()
    print("======================  太空电梯流体监控与维持系统 v2.0  =======================")
    local uptime = computer.uptime()
    local elapsed = uptime - startTime
    print(string.format("运行时间: %s", formatUptime(elapsed)))

    -- 等级统计
    local lvInfo = ""
    if #gt_machines > 0 then
        local lvCount = {}
        for _, m in ipairs(gt_machines) do
            lvCount[m.lv] = (lvCount[m.lv] or 0) + 1
        end
        local parts = {}
        for lv = 1, 3 do
            if lvCount[lv] then
                table.insert(parts, string.format("%s×%d", LV_NAMES[lv], lvCount[lv]))
            end
        end
        lvInfo = " (" .. table.concat(parts, " ") .. ")"
    end

    print(string.format("ME网络: %s  |  钻机: %d台%s (%d槽)  |  AR眼镜: %s",
          meConnected and "在线" or "离线",
          #gt_machines, lvInfo, totalSlots,
          glasses and "在线" or "离线"))
    print("--------------------------------------------------------------------------------")

    -- 流体状态（显示当前值 / 200%目标）
    if #PROCESSED_FLUIDS > 0 then
        for i = 1, #PROCESSED_FLUIDS, 4 do
            local lineLabel = "  "
            local lineValue = "  "
            for j = i, math.min(i+3, #PROCESSED_FLUIDS) do
                local fluid = PROCESSED_FLUIDS[j]
                local label = fluid.display
                local amount = getFluidAmount(fluid.name)
                local threshold = fluid.threshold
                local target = (threshold > 0) and (threshold * TARGET_RATIO) or threshold
                local valueStr
                if amount == nil then
                    valueStr = "断连"
                elseif threshold == -1 then
                    valueStr = string.format("%s (--)", formatFluidAmount(amount))
                else
                    -- 显示 当前值 / 200%目标
                    valueStr = string.format("%s/%s", formatFluidAmount(amount), formatFluidAmount(target))
                end
                local space = 16 - GetUtf8Len(label)
                lineLabel = lineLabel .. label .. string.rep(" ", space > 0 and space or 0)
                lineValue = lineValue .. string.format("%-16s", valueStr)
            end
            print(lineLabel)
            print(lineValue)
        end
    end
    print("--------------------------------------------------------------------------------")

    -- 槽位分配概况
    if assignments then
        -- 统计各流体分配了几个槽位
        local fluidSlotCount = {}
        local assignedFluids = {}
        for _, a in ipairs(assignments) do
            fluidSlotCount[a.fluid.name] = (fluidSlotCount[a.fluid.name] or 0) + 1
            assignedFluids[a.fluid.name] = a.fluid
        end
        local parts = {}
        for _, fluid in ipairs(PROCESSED_FLUIDS) do
            if fluidSlotCount[fluid.name] then
                table.insert(parts, string.format("%s×%d", fluid.display, fluidSlotCount[fluid.name]))
            end
        end
        print(string.format("【槽位分配】%d/%d 槽工作中: %s", #assignments, totalSlots, table.concat(parts, ", ")))
    else
        print("【槽位分配】0/" .. totalSlots .. " 槽工作中（全部达标，待关机）")
    end

    if adjustmentMsg and adjustmentMsg ~= "" then
        print("【操作日志】" .. adjustmentMsg)
    end
    print("================================================================================")
end

-- ==================== 执行维持 ====================
local function performMaintenance()
    if #gt_machines == 0 then
        drawDashboard(nil, "警告：太空钻机离线，跳过维持检查")
        return
    end
    if not meConnected then
        drawDashboard(nil, "警告：ME 离线，跳过维持检查")
        return
    end

    local assignments = assignSlots()
    local adjustmentMsg = ""

    if assignments == nil then
        -- 所有流体达到200%目标 → 强制关闭所有钻机
        adjustmentMsg = "所有流体已达200%目标，正在关闭所有钻机"
        local shutDownCount = shutdownAllMachines()
        adjustmentMsg = adjustmentMsg .. string.format(" | 已关闭 %d 台机器", shutDownCount)
        -- 清空槽位分配记录
        slotAssignments = {}
    else
        -- 应用槽位分配
        local changedMachines, changedSlots = applySlotAssignments(assignments)

        if changedSlots > 0 then
            -- 构建变更摘要
            local fluidNames = {}
            local seen = {}
            for _, a in ipairs(assignments) do
                if not seen[a.fluid.name] then
                    table.insert(fluidNames, a.fluid.display)
                    seen[a.fluid.name] = true
                end
            end
            adjustmentMsg = string.format("分配 %d 槽位 (%d 变更) → %d 种流体: %s",
                #assignments, changedSlots, #fluidNames, table.concat(fluidNames, ", "))
            adjustmentMsg = adjustmentMsg .. string.format(" | 调整 %d 台机器", changedMachines)
        else
            adjustmentMsg = string.format("槽位分配无变化，%d 槽位持续工作中", #assignments)
        end
    end

    drawDashboard(assignments, adjustmentMsg)
end

-- ==================== 初始化：流体配置 ====================
for _, config in ipairs(FLUID_CONFIGS) do
    local name = config[1]
    local thresholdRaw = config[2]
    local param1 = config[3]
    local param2 = config[4]
    local display = config[5] or name
    local threshold
    if type(thresholdRaw) == "string" then
        if thresholdRaw == "-1" then threshold = -1
        else threshold = parseNumberWithSuffix(thresholdRaw) end
    else
        threshold = thresholdRaw
    end
    table.insert(PROCESSED_FLUIDS, {
        name = name,
        display = display,
        threshold = threshold,
        param1 = param1,
        param2 = param2
    })
end

-- ==================== 初始化：扫描太空钻机（含等级检测） ====================
print("正在扫描太空钻机...")
if not component.isAvailable("gt_machine") then
    print("警告：未检测到 GT 机器组件，维持功能将不可用")
else
    local count = 0
    for address, _ in component.list("gt_machine") do
        local ok, proxy = pcall(component.proxy, address)
        if ok then
            local okName, rawName = pcall(proxy.getName)
            if okName then
                local name = rawName:lower()

                -- 等级检测：匹配 projectmodulepumpt1/2/3
                local lv = tonumber(name:match("projectmodulepumpt([123])"))
                if not lv then
                    -- 兼容旧命名（默认假定 lv2）
                    if name:match("pump") then
                        lv = 2
                    end
                end

                if lv then
                    local slotCount = PUMP_SLOTS[lv] or 4
                    local parallel = PUMP_PARALLEL[lv] or 4

                    -- 构建槽位列表
                    local slots = {}
                    if slotCount == 1 then
                        slots = {0}
                    else
                        for s = 0, (slotCount - 1) * 2, 2 do
                            table.insert(slots, s)
                        end
                    end

                    -- 设置并行度
                    for i = 0, slotCount - 1 do
                        pcall(proxy.setParameter, "recipe" .. i .. ".parallel", parallel)
                    end

                    table.insert(gt_machines, {
                        proxy = proxy,
                        address = address,
                        lv = lv,
                        name = rawName,
                        slots = slots
                    })
                    totalSlots = totalSlots + slotCount
                    count = count + 1
                    print(string.format("  发现钻机: %s %s (%s, %d槽, parallel=%d)",
                        address:sub(1, 8), rawName, LV_NAMES[lv], slotCount, parallel))
                end
            end
        end
    end

    if count == 0 then
        print("警告：未找到任何钻机，维持功能将不可用")
    else
        print(string.format("成功初始化 %d 台钻机，共 %d 个抽取槽位", count, totalSlots))
    end
end

-- ==================== 主循环 ====================
local function onInterrupted()
    doContinue = false
end

local function main()
    if not me then
        print("警告：未找到 ME 接口，流体监控将不可用")
    end
    if not glasses then
        print("警告：未找到 AR 眼镜，眼镜显示将不可用")
    end

    if glasses then
        glassesSetup()
    end

    term.clear()
    print("===== 太空电梯流体监控与维持系统 v2.0 By GFCYqw ======")
    print(string.format("AR 眼镜刷新间隔: %ds, 维持检查间隔: %ds, 目标倍率: %d%%",
          glassesInterval, checkInterval, math.floor(TARGET_RATIO * 100)))
    print("按 Ctrl+C 退出")
    print("==================================")
    os.sleep(1)

    event.listen("interrupted", onInterrupted)

    startTime = computer.uptime()
    lastGlassesTime = startTime
    lastCheckTime = startTime

    -- 首次执行维持
    performMaintenance()
    lastCheckTime = computer.uptime()

    while doContinue do
        local now = computer.uptime()

        -- 眼镜更新（使用眼镜间隔）
        if glasses and now - lastGlassesTime >= glassesInterval then
            updateGlasses(now)
            lastGlassesTime = now
        end

        -- 维持检查
        if now - lastCheckTime >= checkInterval then
            performMaintenance()
            lastCheckTime = now
        end

        os.sleep(1)
    end

    event.ignore("interrupted", onInterrupted)
    print("用户手动中断")
end

main()