--[[
  AR 眼镜流体监控脚本（带变化率显示）
  功能：实时显示 ME 网络流体存量，并在后方显示每秒变化量
  颜色规则：
    - 低于阈值 → 红色（警告）
    - 高于阈值 → 根据变化率：正=绿色，负=红色，零=白色
]]

local component = require("component")
local glasses = component.glasses
local me = component.me_interface
local event = require("event")
local os = require("os")
local term = require("term")

-- ============ 配置 ============
local textScale = 1
local offsetX = 3
local offsetY = 17
local lineSpacing = 1
local updateInterval = 1

-- 流体列表（请根据实际注册名填写）
local FLUIDS = {
    { name = "plasma.helium",   display = "氦等离子体", threshold = 10000 },
    { name = "exciteddtrc",            display = "激发的光辉超维度催化剂",       threshold = 5000  },
    { name = "lava",             display = "岩浆",       threshold = 20000 },
    -- 添加更多
}

-- ============ 状态变量 ============
local meConnected = false
local statusKey = "me_status"
local texts = {}
local lastAmounts = {}   -- 存储每个流体上次的值，用于计算变化率

-- ============ 辅助函数 ============
local function formatFluidAmount(amount)
    if amount == nil then return "断连" end
    if amount >= 1e12 then return string.format("%.1fT", amount / 1e12)
    elseif amount >= 1e9 then return string.format("%.1fG", amount / 1e9)
    elseif amount >= 1e6 then return string.format("%.1fM", amount / 1e6)
    elseif amount >= 1e3 then return string.format("%.1fk", amount / 1e3)
    else return tostring(math.floor(amount)) end
end

-- 格式化变化率（带符号）
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

-- 从 ME 网络获取流体存量（使用 fluid.amount）
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

-- ============ 眼镜文本管理 ============
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
    for i, fluid in ipairs(FLUIDS) do
        local y = offsetY + i * lineSpacing
        createShadowText("fluid_" .. fluid.name, offsetX, y)
    end
end

-- 更新眼镜数据（含变化率计算）
local function updateGlasses()
    if not glasses then return end

    -- 状态行（ME 连接状态）
    local statusText = meConnected and "ME: 在线" or "ME: 离线"
    local statusColor = meConnected and {85, 255, 85} or {255, 85, 85}
    setShadowText(statusKey, statusText, table.unpack(statusColor))

    -- 遍历每个流体
    for i, fluid in ipairs(FLUIDS) do
        local amount = getFluidAmount(fluid.name)
        local key = "fluid_" .. fluid.name

        -- 计算变化率（相对上次取值）
        local last = lastAmounts[fluid.name] or amount
        local diff = (amount - last) / updateInterval
        lastAmounts[fluid.name] = amount

        -- 构建显示文本
        local rateText = formatRate(diff)
        local text = string.format("%s: %s mB%s", fluid.display, formatFluidAmount(amount), rateText)

        -- 决定颜色：阈值警告优先，否则根据变化率
        local r, g, b = 255, 255, 255
        if amount == nil then
            r, g, b = 128, 128, 128          -- 灰色（断连）
        elseif fluid.threshold and fluid.threshold > 0 and amount < fluid.threshold then
            r, g, b = 255, 85, 85            -- 红色（低于阈值）
        else
            if diff > 0 then
                r, g, b = 85, 255, 85        -- 绿色（增加）
            elseif diff < 0 then
                r, g, b = 255, 85, 85        -- 红色（减少）
            else
                r, g, b = 255, 255, 255      -- 白色（不变）
            end
        end
        setShadowText(key, text, r, g, b)
    end
end

-- ============ 主循环 ============
local doContinue = true
local lastStatus = nil

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
    print("流体监控已启动，按 Ctrl+C 退出")

    event.listen("interrupted", onInterrupted)

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

        os.sleep(updateInterval)
    end

    event.ignore("interrupted", onInterrupted)
    print("监控已停止")
end

main()