--[[
  综合脚本：AR眼镜流体监控 + 自动维持（太空钻机生产）
  功能：
    1. 在AR眼镜上实时显示流体存量、变化率、阈值警告（红色低于阈值）。
    2. 每30秒检查一次，若某流体低于阈值，自动调整所有太空钻机参数生产该流体。
    3. 支持多台机器及不同等级（等级1与其他等级参数设置方式不同）。
    4. 优先生产最急需的流体（按配置顺序）。
    5. 眼镜上显示ME连接状态 + 钻机数量 + 各流体数据。
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
local offsetY = 15               -- 起始Y坐标（像素/10）
local lineSpacing = 1            -- 行间距（眼镜单位）
local updateInterval = 1         -- 眼镜刷新间隔（秒）

-- 流体配置：{注册名, 阈值(mB), 行星参数, 气体参数}
-- 阈值支持单位后缀: k,m,g,t (如 "4g" 表示 40亿)
-- 若阈值设为 -1 则表示"持续获取"（即当所有其他流体充足时，优先生产该流体）
-- 注意：显示名称默认使用注册名，若想自定义显示名，可在配置中添加第五个字段，见下方注释
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
    -- 若要自定义显示名，请写成 {注册名, 阈值, 行星, 气体, 显示名}
    -- 例如 {"plasma.helium", "10k", 8, 2, "氦等离子体"}
}

-- 机器配置：{地址, 等级}
local MACHINES = {
    {"24950641-92a7-480e-ba7e-ddf276f1012d", 1},
    -- {"你的机器地址2", 1},
}

-- 维持检查间隔（秒）
local CHECK_INTERVAL = 30

-- ==================== 内部状态 ====================

local meConnected = false
local statusKey = "me_status"
local machineKey = "machine_count"   -- 钻机数量标签的键
local texts = {}
local lastAmounts = {}
local doContinue = true
local lastCheckTime = 0

local PROCESSED_FLUIDS = {}
local gt_machines = {}
local machineLevels = {}

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

local function formatNumberReadable(number)
    if number == -1 then return "-1 (持续获取)" end
    local absNumber = math.abs(number)
    if absNumber >= 1e12 then return string.format("%.1ft", number / 1e12)
    elseif absNumber >= 1e9 then return string.format("%.1fg", number / 1e9)
    elseif absNumber >= 1e6 then return string.format("%.1fm", number / 1e6)
    elseif absNumber >= 1e3 then return string.format("%.1fk", number / 1e3)
    else return tostring(number) end
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
    -- 第一行：ME状态
    createShadowText(statusKey, offsetX, offsetY)
    -- 第二行：钻机数量
    createShadowText(machineKey, offsetX, offsetY + lineSpacing)
    -- 从第三行开始：流体列表
    for i, fluid in ipairs(PROCESSED_FLUIDS) do
        local y = offsetY + (i + 1) * lineSpacing   -- +1 跳过机器数量行
        createShadowText("fluid_" .. fluid.name, offsetX, y)
    end
end

local function updateGlasses()
    if not glasses then return end

    -- 1. ME状态
    local statusText = meConnected and "ME: 在线" or "ME: 离线"
    local statusColor = meConnected and {85, 255, 85} or {255, 85, 85}
    setShadowText(statusKey, statusText, table.unpack(statusColor))

    -- 2. 钻机数量
    local machineCount = #gt_machines
    local machineText = machineCount > 0 and ("钻机: " .. machineCount .. "台") or "钻机: 无"
    local machineColor = machineCount > 0 and {255, 255, 255} or {128, 128, 128}
    setShadowText(machineKey, machineText, table.unpack(machineColor))

    -- 3. 流体数据
    for i, fluid in ipairs(PROCESSED_FLUIDS) do
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

-- ===== 修正后的参数调整函数 =====
local function adjustMachineParameters(machine, level, param1, param2)
    if not safelyStopMachine(machine) then
        print("无法停止机器，参数调整取消")
        return false
    end

    local success
    if level == 1 then
        -- 等级1：使用 setParameters 设置槽位 0（与参考脚本一致）
        success = pcall(machine.setParameters, 0, 0, param1) and
                  pcall(machine.setParameters, 0, 1, param2)
    else
        -- 等级2+：多槽（0,2,4,6）
        success = pcall(machine.setParameters, 0, 0, param1) and
                  pcall(machine.setParameters, 0, 1, param2) and
                  pcall(machine.setParameters, 2, 0, param1) and
                  pcall(machine.setParameters, 2, 1, param2) and
                  pcall(machine.setParameters, 4, 0, param1) and
                  pcall(machine.setParameters, 4, 1, param2) and
                  pcall(machine.setParameters, 6, 0, param1) and
                  pcall(machine.setParameters, 6, 1, param2)
    end

    if success then
        machine.setWorkAllowed(true)
        return true
    else
        print("机器参数调整失败")
        return false
    end
end
-- ================================

local function adjustAllMachines(param1, param2)
    local successCount = 0
    for i, machine in ipairs(gt_machines) do
        local address = tostring(machine.address)
        local level = machineLevels[address] or 1
        if adjustMachineParameters(machine, level, param1, param2) then
            successCount = successCount + 1
            print(string.format("机器 %d (等级 %d) 参数调整成功", i, level))
        else
            print(string.format("机器 %d (等级 %d) 参数调整失败", i, level))
        end
    end
    return successCount
end

-- ==================== 维持逻辑 ====================

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

-- ==================== 初始化 ====================

-- 处理流体配置
for _, config in ipairs(FLUID_CONFIGS) do
    local name = config[1]
    local thresholdRaw = config[2]
    local param1 = config[3]
    local param2 = config[4]
    local display = config[5] or name   -- 若有第五项则使用自定义显示名，否则用注册名
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

-- 初始化机器
if not component.isAvailable("gt_machine") then
    print("警告：未检测到 GT 机器组件，维持功能将不可用")
else
    for _, machineInfo in ipairs(MACHINES) do
        local address = machineInfo[1]
        local level = machineInfo[2] or 1
        local success, machine = pcall(component.proxy, address)
        if success and machine and machine.type == "gt_machine" then
            table.insert(gt_machines, machine)
            machineLevels[address] = level
            print("找到机器: " .. address .. " (等级 " .. level .. ")")
        else
            print("警告: 无法访问机器 " .. address)
        end
    end
    if #gt_machines == 0 then
        print("警告：未找到任何可用的太空钻机，维持功能将无效")
    else
        print("成功初始化 " .. #gt_machines .. " 台钻机")
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
            if meConnected then
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