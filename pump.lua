--[[
  综合脚本：AR眼镜流体监控 + 自动维持（太空钻机生产）
  功能：
    1. AR眼镜实时显示流体存量、变化率、阈值警告。
    2. 每30秒检查一次，若某流体低于阈值，自动调整所有太空钻机参数。
    3. 自动发现钻机。
    4. 终端以仪表板形式显示当前状态，展示每个流体的实际库存与阈值。
]]

local component = require("component")
local glasses = component.glasses
local me = component.me_interface
local event = require("event")
local os = require("os")
local term = require("term")

-- ==================== 配置 ====================
local textScale = 1
local offsetX = 3
local offsetY = 15
local lineSpacing = 1
local updateInterval = 10
local CHECK_INTERVAL = 60

-- 流体配置：{注册名, 阈值(mB), 行星参数, 气体参数, 显示名}
local FLUID_CONFIGS = {
    {"liquidair", "1g", 8, 2, "液态空气" },
    {"fluorine", "4g", 7, 2, "氟" },
    {"sulfuricacid", "1g", 4, 1, "硫酸" },
    {"helium", "2g", 5, 4, "氦" },
    {"oil", "1g", 4, 3, "石油" },
    {"ic2distilledwater", "1g", 8, 5, "蒸馏水" },
    {"chlorobenzene", "1g", 2, 1, "氯苯" },
    {"helium-3", "1g", 5, 2, "氦-3" },
    {"deuterium", "1g", 6, 1, "氘" },
    {"tritium", "1g", 6, 2, "氚" },
    {"lava", "10m", 3, 3, "熔岩" },
    {"methane", "10m", 5, 9, "甲烷" },
    {"argon", "100m", 5, 7, "氩" },
    {"radon", "100m", 8, 6, "氡" },
    {"krypton", "10m", 5, 8, "氪" },
    {"xenon", "2g", 6, 4, "氙" },
    -- {"ethylene", "1g", 6, 5, "乙烯" },
    -- {"molten.iron", "100m", 4, 2, "熔融铁" },
    -- {"molten.copper", "100m", 8, 3, "熔融铜" },
    -- {"molten.tin", "100m", 8, 7, "熔融锡" },
    -- {"molten.lead", "100m", 4, 5, "熔融铅" }
}

-- ==================== 内部状态 ====================
local meConnected = false
local statusKey = "me_status"
local machineKey = "machine_count"
local texts = {}
local lastAmounts = {}
local doContinue = true
local lastCheckTime = 0

local PROCESSED_FLUIDS = {}
local gt_machines = {}

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

local function updateGlasses()
    if not glasses then return end
    local statusText = meConnected and "ME: 在线" or "ME: 离线"
    local statusColor = meConnected and {85, 255, 85} or {255, 85, 85}
    setShadowText(statusKey, statusText, table.unpack(statusColor))

    local machineCount = #gt_machines
    local machineText = machineCount > 0 and ("钻机: " .. machineCount .. "台") or "钻机: 无"
    local machineColor = machineCount > 0 and {85, 255, 85} or {255, 85, 85}
    setShadowText(machineKey, machineText, table.unpack(machineColor))

    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        local amount = getFluidAmount(fluid.name)
        local key = "fluid_" .. fluid.name
        local last = lastAmounts[fluid.name] or amount
        local diff = (amount - last) / updateInterval
        lastAmounts[fluid.name] = amount
        local rateText = formatRate(diff)
        local text = string.format("%s: %s mB%s", fluid.display, formatFluidAmount(amount), rateText)

        local r, g, b = 255, 255, 255
        if amount == nil then
            r, g, b = 128, 128, 128
        elseif fluid.threshold and fluid.threshold > 0 and amount < fluid.threshold then
            r, g, b = 255, 85, 85
        else
            if diff > 0 then r, g, b = 85, 255, 85
            elseif diff < 0 then r, g, b = 255, 85, 85
            else r, g, b = 255, 255, 255 end
        end
        setShadowText(key, text, r, g, b)
    end
end

-- ==================== 钻机控制 ====================
local function safelyStopMachine(machine)
    if machine.isMachineActive() then
        machine.setWorkAllowed(false)
        local maxWait = 60
        local waitCount = 0
        while machine.isMachineActive() and waitCount < maxWait do
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

local function adjustMachineParameters(machine, param1, param2)
    if not safelyStopMachine(machine) then
        print("无法停止机器，参数调整取消")
        return false
    end
    local success = true
    for slot = 0, 6, 2 do
        success = success and pcall(machine.setParameters, slot, 0, param1)
        success = success and pcall(machine.setParameters, slot, 1, param2)
    end
    if success then
        machine.setWorkAllowed(true)
        return true
    else
        print("机器参数调整失败")
        return false
    end
end

local function adjustAllMachines(param1, param2)
    local successCount = 0
    for i, machine in ipairs(gt_machines) do
        if adjustMachineParameters(machine, param1, param2) then
            successCount = successCount + 1
        end
    end
    return successCount
end

-- ==================== 维持逻辑 ====================
local function findFluidToRefill()
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        if fluid.threshold ~= -1 then
            local amount = getFluidAmount(fluid.name)
            if amount ~= nil and amount < fluid.threshold then
                return fluid
            end
        end
    end
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        if fluid.threshold == -1 then
            return fluid
        end
    end
    return nil
end

-- ==================== 终端仪表板（显示数量/阈值） ====================
local function drawDashboard(target, adjustmentMsg)
    term.clear()
    -- 标题与状态行（添加 AR 眼镜状态 + 时间）
    local glassesStatus = glasses and "可用" or "不可用"
    local timeStr = os.date("%Y-%m-%d %H:%M:%S")
    print(string.format("========== 太空电梯流体监控与维持系统 [%s] ==========", timeStr))
    print(string.format("ME网络: %s  |  钻机数: %d 台  |  AR眼镜: %s", 
          meConnected and "在线" or "离线", #gt_machines, glassesStatus))
    print("--------------------------------------------------------------")

    -- 流体库存显示：名称 和 数量/阈值（每行4个，即按4个一组）
    if #PROCESSED_FLUIDS > 0 then
        for i = 1, #PROCESSED_FLUIDS, 4 do
            local lineLabel = "  "
            local lineValue = "  "
            for j = i, math.min(i+3, #PROCESSED_FLUIDS) do
                local fluid = PROCESSED_FLUIDS[j]
                local label = fluid.display
                local amount = getFluidAmount(fluid.name)
                local threshold = fluid.threshold
                local valueStr
                if amount == nil then
                    valueStr = "断连"
                elseif threshold == -1 then
                    valueStr = string.format("%s (持续)", formatFluidAmount(amount))
                else
                    valueStr = string.format("%s / %s", formatFluidAmount(amount), formatFluidAmount(threshold))
                end
                local space = 16 - GetUtf8Len(label)
                lineLabel = lineLabel .. label .. string.rep(" ", space > 0 and space or 0)
                lineValue = lineValue .. string.format("%-16s", valueStr)
            end
            print(lineLabel)
            print(lineValue)
        end
    end
    print("--------------------------------------------------------------")

    -- 当前目标
    if target then
        print(string.format("【当前目标】%s (行星=%d, 气体=%d)", target.display, target.param1, target.param2))
    else
        print("【当前目标】无（所有流体充足）")
    end

    -- 调整动作信息
    if adjustmentMsg and adjustmentMsg ~= "" then
        print("【操作日志】" .. adjustmentMsg)
    end
    print("==============================================================")
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

    local target = findFluidToRefill()
    local adjustmentMsg = ""
    
    if target then
        if target.threshold == -1 then
            adjustmentMsg = string.format("所有常规流体充足，开始持续获取 %s", target.display)
        else
            adjustmentMsg = string.format("检测到 %s 低于阈值，开始补充", target.display)
        end
        local successCount = adjustAllMachines(target.param1, target.param2)
        if successCount > 0 then
            adjustmentMsg = adjustmentMsg .. string.format(" | 已调整 %d 台机器 %s",
                successCount,
                target.threshold == -1 and "持续获取" or "补充")
        else
            adjustmentMsg = adjustmentMsg .. " | 所有机器参数调整失败"
        end
    else
        adjustmentMsg = "所有流体库存充足，无需调整"
    end

    drawDashboard(target, adjustmentMsg)
end

-- ==================== 初始化 ====================
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

print("正在扫描太空钻机...")
if not component.isAvailable("gt_machine") then
    print("警告：未检测到 GT 机器组件，维持功能将不可用")
else
    local count = 0
    for address, _ in component.list("gt_machine") do
        local machine = component.proxy(address)
        local name = machine.getName() or ""
        if name:lower():match("pump") or name:lower():match("projectmodulepump") then
            table.insert(gt_machines, machine)
            count = count + 1
            print(string.format("  发现钻机: %s (%s)", address, name))
        end
    end
    if count == 0 then
        print("警告：未找到任何钻机，维持功能将不可用")
    else
        print(string.format("成功初始化 %d 台钻机", count))
    end
end

-- ==================== 主循环 ====================
local function onInterrupted()
    doContinue = false
end

local function main()
    -- 优化：不再强制退出，仅警告并继续运行
    if not me then
        print("警告：未找到 ME 接口，流体监控将不可用")
    end
    if not glasses then
        print("警告：未找到 AR 眼镜，眼镜显示将不可用")
    end

    -- 如果存在眼镜则初始化，否则跳过
    if glasses then
        glassesSetup()
    end

    term.clear()
    print("===== 太空电梯流体监控与维持系统 Version 1.0 By GFCYqw =====")
    print(string.format("AR 眼镜刷新间隔: %ds, 维持检查间隔: %ds", updateInterval, CHECK_INTERVAL))
    print("按 Ctrl+C 退出")
    print("==================================")
    os.sleep(1)

    event.listen("interrupted", onInterrupted)

    local lastStatus = nil
    lastCheckTime = os.time()
    performMaintenance()  -- 立即显示初始状态
    lastCheckTime = os.time()

    while doContinue do
        -- 若眼镜存在则更新，否则跳过
        if glasses then
            updateGlasses()
        end

        if meConnected ~= lastStatus then
            lastStatus = meConnected
        end

        local now = os.time()
        if now - lastCheckTime >= CHECK_INTERVAL then
            performMaintenance()
            lastCheckTime = now
        end

        os.sleep(updateInterval)
    end

    event.ignore("interrupted", onInterrupted)
    print("用户手动中断")
end

main()