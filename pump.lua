--[[
  综合脚本：AR眼镜流体监控 + 自动维持（太空钻机生产）
  功能：
    1. 在AR眼镜上实时显示流体存量、变化率、阈值警告。
    2. 每30秒检查一次，若某流体低于阈值，自动调整所有太空钻机参数。
    3. 自动发现钻机（无需手动配置地址）。
    4. 终端显示当前目标、库存比例等精简信息（已剔除重复的系统状态打印）。
]]

local component = require("component")
local glasses = component.glasses
local me = component.me_interface
local event = require("event")
local os = require("os")
local term = require("term")

-- ==================== 配置区域 ====================

local textScale = 1
local offsetX = 3
local offsetY = 15
local lineSpacing = 1
local updateInterval = 1
local CHECK_INTERVAL = 30

-- 流体配置：{注册名, 阈值(mB), 行星参数, 气体参数, 显示名(可选)}
-- 阈值支持 k/m/g/t 后缀，-1 表示“持续获取”
local FLUID_CONFIGS = {
    {"liquidair", "1g", 8, 2, "液态空气" },
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
    {"xenon", -1, 6, 4, "氙" },
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

local function getFluidRatios()
    local ratios = {}
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        local amount = getFluidAmount(fluid.name)
        if amount == nil then
            ratios[fluid.name] = nil
        elseif fluid.threshold and fluid.threshold > 0 then
            ratios[fluid.name] = amount / fluid.threshold
        else
            ratios[fluid.name] = 1
        end
    end
    return ratios
end

-- ==================== 眼镜显示 ====================

local function formatFluidAmount(amount)
    if amount == nil then return "断连" end
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
    local machineColor = machineCount > 0 and {255, 255, 255} or {128, 128, 128}
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
            print(string.format("机器 %d 参数调整成功", i))
        else
            print(string.format("机器 %d 参数调整失败", i))
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

-- ==================== 精简终端输出 ====================

local function printFluidStatus()
    if #PROCESSED_FLUIDS == 0 then return end
    local ratios = getFluidRatios()
    local total = #PROCESSED_FLUIDS
    print("\n【流体库存状态】")
    for i = 1, total, 7 do
        local lineLabel = "  "
        local lineRatio = "  "
        for j = i, math.min(i+6, total) do
            local fluid = PROCESSED_FLUIDS[j]
            local label = fluid.display
            local ratio = ratios[fluid.name]
            local ratioStr
            if ratio == nil then
                ratioStr = "断连"
            elseif ratio >= 1 then
                ratioStr = "充足"
            else
                ratioStr = string.format("%.1f%%", ratio * 100)
            end
            local space = 16 - GetUtf8Len(label)
            lineLabel = lineLabel .. label .. string.rep(" ", space > 0 and space or 0)
            lineRatio = lineRatio .. string.format("%-16s", ratioStr)
        end
        print(lineLabel)
        print(lineRatio)
    end
end

-- 只显示当前目标，不再重复输出 ME 状态、钻机数量、下次检查时间
local function printTarget(target)
    if target then
        print(string.format("【当前目标】%s (行星=%d, 气体=%d)", target.display, target.param1, target.param2))
    else
        print("【当前目标】无（所有流体充足）")
    end
end

-- ==================== 执行维持 ====================

local function performMaintenance()
    if #gt_machines == 0 then
        print("\n警告：没有可用的太空钻机，维持功能跳过")
        return
    end
    if not meConnected then
        print("\nME 离线，跳过维持检查")
        return
    end

    printFluidStatus()
    local target = findFluidToRefill()
    printTarget(target)

    if target then
        if target.threshold == -1 then
            print(string.format("\n所有常规流体充足，开始持续获取 %s", target.display))
        else
            print(string.format("\n检测到 %s 低于阈值，开始补充", target.display))
        end
        local successCount = adjustAllMachines(target.param1, target.param2)
        if successCount > 0 then
            print(string.format("已调整 %d 台机器%s", successCount,
                target.threshold == -1 and "持续获取 " .. target.display or "补充 " .. target.display))
        else
            print("所有机器参数调整失败")
        end
    else
        print("\n所有流体库存充足，无需调整")
    end
    print("==================================\n")
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
        print("警告：未找到任何钻机，维持功能将无效")
    else
        print(string.format("成功初始化 %d 台钻机", count))
    end
end

-- ==================== 主循环 ====================

local function onInterrupted()
    doContinue = false
end

local function main()
    if not me then
        print("错误：未找到 ME 接口")
        os.exit()
    end
    if not glasses then
        print("错误：未找到 AR 眼镜")
        os.exit()
    end

    glassesSetup()
    term.clear()
    print("综合监控与维持系统启动")
    print(string.format("眼镜刷新间隔: %ds, 维持检查间隔: %ds", updateInterval, CHECK_INTERVAL))
    print("按 Ctrl+C 退出")
    print("==================================")

    event.listen("interrupted", onInterrupted)

    local lastStatus = nil
    lastCheckTime = os.time()

    while doContinue do
        updateGlasses()

        if meConnected ~= lastStatus then
            if meConnected then
                print("ME 接口已连接")
            else
                print("警告：ME 接口断开")
            end
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
    print("系统已停止")
end

main()