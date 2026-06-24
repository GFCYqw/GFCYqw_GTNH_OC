--[[
  AR 眼镜流体监控脚本（修正版）
  修复：使用 fluid.amount 获取真实存量
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
local offsetY = 15
local lineSpacing = 1
local updateInterval = 1

-- 流体列表（请根据实际注册名填写，参考打印脚本的输出）
local FLUIDS = {
    { name = "plasma.heilum",           display = "氦等离子体",      threshold = 10000 },
    { name = "lava",            display = "岩浆",    threshold = 5000  },
    { name = "oil",             display = "石油",    threshold = 20000 },
    -- 添加更多
}

-- ============ 状态 ============
local meConnected = false
local statusKey = "me_status"
local texts = {}

-- ============ 辅助函数 ============
local function formatFluidAmount(amount)
    if amount == nil then return "断连" end
    if amount >= 1e9 then return string.format("%.1fB", amount / 1e9)
    elseif amount >= 1e6 then return string.format("%.1fM", amount / 1e6)
    elseif amount >= 1e3 then return string.format("%.1fK", amount / 1e3)
    else return tostring(math.floor(amount)) end
end

-- 修正：使用 fluid.amount（参考脚本已验证可行）
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
            -- 优先 amount，兼容 size
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

local function updateGlasses()
    if not glasses then return end

    -- 状态行
    local statusText = meConnected and "ME: 在线" or "ME: 离线"
    local statusColor = meConnected and {85, 255, 85} or {255, 85, 85}
    setShadowText(statusKey, statusText, table.unpack(statusColor))

    -- 流体数据
    for i, fluid in ipairs(FLUIDS) do
        local amount = getFluidAmount(fluid.name)
        local key = "fluid_" .. fluid.name
        local text = string.format("%s: %s mB", fluid.display, formatFluidAmount(amount))

        local r, g, b = 255, 255, 255
        if amount == nil then
            r, g, b = 128, 128, 128
        elseif fluid.threshold and fluid.threshold > 0 and amount < fluid.threshold then
            r, g, b = 255, 85, 85
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