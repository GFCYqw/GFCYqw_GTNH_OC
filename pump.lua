--[[
  综合脚本：AR眼镜流体监控 + 自动维持（太空钻机生产）
  功能：
    1. 在AR眼镜上实时显示流体存量、变化率、阈值警告。
    2. 每30秒检查一次，若某流体低于阈值，自动调整所有太空钻机参数。
    3. 自动发现钻机（无需手动配置地址）。
    4. 终端显示当前目标、库存比例、机器数量等详细信息。
]]

local component = require("component")
local glasses = component.glasses
local me = component.me_interface
local event = require("event")
local os = require("os")
local term = require("term")

-- ==================== 配置区域 ====================

-- 眼镜显示参数
local textScale = 1
local offsetX = 3
local offsetY = 15
local lineSpacing = 1
local updateInterval = 1          -- 眼镜刷新间隔（秒）

-- 流体配置：{注册名, 阈值(mB), 行星参数, 气体参数}
-- 阈值支持单位后缀: k,m,g,t (如 "4g" 表示 40亿)
-- 若阈值设为 -1 则表示"持续获取"（当所有常规流体充足时生产）
-- 可添加第五个字段自定义显示名，否则使用注册名
local FLUID_CONFIGS = {
    {"liquidair", "4g", 8, 2},
    {"helium", "100g", 5, 4},
    {"fluorine", "4g", 7, 2},
    {"hydrofluoricacid_gt5u", "4g", 7, 1},
    {"sulfuricacid", "10g", 4, 1},
    {"oil", "100m", 4, 3},
    {"ic2distilledwater", "10g", 8, 5},
    {"chlorobenzene", "100m", 2, 1},
    {"helium-3", "10g", 5, 2},
    {"deuterium", "10g", 6, 1},
    {"tritium", "10g", 6, 2},
    {"lava", "1g", 3, 3},
    {"methane", "10g", 5, 9},
    {"ethylene", "100m", 6, 5},
    {"molten.iron", "10g", 4, 2},
    {"molten.copper", "10g", 8, 3},
    {"molten.tin", "100m", 8, 7},
    {"molten.lead", "100m", 4, 5},
    {"argon", "100m", 5, 7},
    {"radon", "10g", 8, 6},
    {"krypton", "100m", 5, 8},
    {"xenon", -1, 6, 4},
}

-- 维持检查间隔（秒）
local CHECK_INTERVAL = 30

-- ==================== 内部状态 ====================

local meConnected = false
local statusKey = "me_status"
local machineKey = "machine_count"
local texts = {}
local lastAmounts = {}
local doContinue = true
local lastCheckTime = 0

local PROCESSED_FLUIDS = {}
local gt_machines = {}      -- 自动发现的钻机列表

-- ==================== 辅助函数（解析后缀、格式化） ====================

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

local function formatNumberReadable(number)
    if number == -1 then return "-1 (持续获取)" end
    local absNumber = math.abs(number)
    if absNumber >= 1e12 then return string.format("%.1ft", number / 1e12)
    elseif absNumber >= 1e9 then return string.format("%.1fg", number / 1e9)
    elseif absNumber >= 1e6 then return string.format("%.1fm", number / 1e6)
    elseif absNumber >= 1e3 then return string.format("%.1fk", number / 1e3)
    else return tostring(number) end
end

-- 中文字符串显示宽度（用于对齐）
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

-- ==================== ME 流体读取 ====================

local function getFluidAmount(fluidName)
    if not me then return nil end
    local ok, fluids = pcall(me.getFluidsInNetwork, me)
    if not ok then
        meConnected = false
        return nil
    end
    meConnected = true
    for _, fluid in ipairs(fluids) do
        if fluid.name == fluidName then
            local amount = fluid.amount or fluid.size
            return tonumber(amount) or 0
        end
    end
    return 0
end

-- 获取所有目标流体的库存比例（用于终端显示）
local function getFluidRatios()
    local ratios = {}
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        local amount = getFluidAmount(fluid.name)
        if amount == nil then
            ratios[fluid.name] = nil
        elseif fluid.threshold and fluid.threshold > 0 then
            ratios[fluid.name] = amount / fluid.threshold
        else
            ratios[fluid.name] = 1  -- 无阈值视为充足
        end
    end
    return ratios
end

-- ==================== 格式化函数（眼镜显示） ====================

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

-- ==================== 眼镜文本管理 ====================

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
            if diff > 0 then
                r, g, b = 85, 255, 85
            elseif diff < 0 then
                r, g, b = 255, 85, 85
            else
                r, g, b = 255, 255, 255
            end
        end
        setShadowText(key, text, r, g, b)
    end
end

-- ==================== 太空钻机控制函数 ====================

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

-- 统一使用多槽设置（参考代码风格）
local function adjustMachineParameters(machine, param1, param2)
    if not safelyStopMachine(machine) then
        print("无法停止机器，参数调整取消")
        return false
    end

    local success = true
    -- 设置槽位 0,2,4,6 的行星和气体参数
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

-- 寻找需要补充的流体（按优先级）
local function findFluidToRefill()
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        local threshold = fluid.threshold
        if threshold ~= -1 then
            local amount = getFluidAmount(fluid.name)
            if amount == nil then
                -- 断连跳过
            elseif amount < threshold then
                return fluid
            end
        end
    end
    -- 所有常规充足，找持续获取目标
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        if fluid.threshold == -1 then
            return fluid
        end
    end
    return nil
end

local function performMaintenance()
    if #gt_machines == 0 then
        print("没有可用的太空钻机，维持功能跳过")
        return
    end

    local target = findFluidToRefill()
    if target then
        if target.threshold == -1 then
            print(string.format("所有常规流体充足，开始持续获取 %s", target.display))
        else
            print(string.format("检测到 %s 低于阈值，开始补充", target.display))
        end
        local successCount = adjustAllMachines(target.param1, target.param2)
        if successCount > 0 then
            print(string.format("已调整 %d 台机器%s", successCount,
                target.threshold == -1 and "持续获取 " .. target.display or "补充 " .. target.display))
        else
            print("所有机器参数调整失败")
        end
    else
        print("所有流体库存充足，无需调整")
    end
end

-- ==================== 终端信息显示（优化） ====================

-- 以表格形式显示当前各流体库存比例
local function showFluidStatus()
    local ratios = getFluidRatios()
    if #PROCESSED_FLUIDS == 0 then return end

    io.write("\n当前流体库存状态：\n")
    io.write("名称" .. string.rep(" ", 20) .. "比例\n")
    for _, fluid in ipairs(PROCESSED_FLUIDS) do
        local ratio = ratios[fluid.name]
        local ratioStr
        if ratio == nil then
            ratioStr = "断连"
        elseif ratio >= 1 then
            ratioStr = "充足 (>100%)"
        else
            ratioStr = string.format("%.1f%%", ratio * 100)
        end
        local name = fluid.display
        local pad = 24 - GetUtf8Len(name)
        io.write(name .. string.rep(" ", pad) .. ratioStr .. "\n")
    end
    print()
end

-- ==================== 初始化 ====================

-- 处理流体配置
for _, config in ipairs(FLUID_CONFIGS) do
    local name = config[1]
    local thresholdRaw = config[2]
    local param1 = config[3]
    local param2 = config[4]
    local display = config[5] or name
    local threshold
    if type(thresholdRaw) == "string" then
        if thresholdRaw == "-1" then
            threshold = -1
        else
            threshold = parseNumberWithSuffix(thresholdRaw)
        end
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

-- 自动发现钻机（匹配名称包含 pump 的 gt_machine）
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

    event.listen("interrupted", onInterrupted)

    local lastStatus = nil
    lastCheckTime = os.time()

    while doContinue do
        -- 刷新眼镜
        updateGlasses()

        -- 检测 ME 连接状态变化
        if meConnected ~= lastStatus then
            if meConnected then
                print("ME 接口已连接")
            else
                print("警告：ME 接口断开")
            end
            lastStatus = meConnected
        end

        -- 定期执行维持检查
        local now = os.time()
        if now - lastCheckTime >= CHECK_INTERVAL then
            if meConnected then
                -- 显示当前库存状态（终端）
                showFluidStatus()
                -- 执行维持
                performMaintenance()
            else
                print("ME 离线，跳过维持检查")
            end
            lastCheckTime = now
        end

        os.sleep(updateInterval)
    end

    event.ignore("interrupted", onInterrupted)
    print("系统已停止")
end

main()