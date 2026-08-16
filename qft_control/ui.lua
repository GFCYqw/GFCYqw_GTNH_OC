--[[
  ui.lua — 屏幕仪表板模块
  显示当前系统状态、矿物处理进度、产物维持状态、QFT 运行状态。
]]

local UI = {}
local gpu = nil
local term = nil
local event = nil

-- ==================== 状态数据 ====================

local displayState = {
    mode = "初始化中",           -- 当前模式
    mineralCurrent = "无",       -- 当前矿物项目
    mineralIndex = "0/0",        -- 矿物进度 (当前/总数)
    mineralTimer = 0,            -- 矿物处理计时器
    qftStatus = "未知",          -- QFT 状态
    qftProgress = 0,             -- QFT 进度
    maintenanceActive = false,   -- 是否有产物维持任务
    maintenanceCount = 0,        -- 维持任务数
    lastMaintenanceCheck = 0,    -- 上次维持检查时间
    redstoneFreq = 0,            -- 当前红石频率
    redstoneOutput = false,      -- 红石输出状态
    errors = {},                 -- 最近的错误消息（最多5条）
    uptime = "",                 -- 运行时间
}

-- ==================== 初始化 ====================

function UI.init(gpuComponent)
    gpu = gpuComponent
    term = require("term")
    event = require("event")

    -- 清屏
    if term then
        term.clear()
    end

    -- 如果有 GPU，设置高分辨率
    if gpu then
        local w, h = gpu.getResolution()
        if w < 80 then
            pcall(function() gpu.setResolution(80, 25) end)
        end
    end

    return true
end

-- ==================== 状态更新 ====================

function UI.updateState(state)
    if state.mode then displayState.mode = state.mode end
    if state.mineralCurrent then displayState.mineralCurrent = state.mineralCurrent end
    if state.mineralIndex then displayState.mineralIndex = state.mineralIndex end
    if state.mineralTimer then displayState.mineralTimer = state.mineralTimer end
    if state.qftStatus then displayState.qftStatus = state.qftStatus end
    if state.qftProgress then displayState.qftProgress = state.qftProgress end
    if state.maintenanceActive ~= nil then displayState.maintenanceActive = state.maintenanceActive end
    if state.maintenanceCount then displayState.maintenanceCount = state.maintenanceCount end
    if state.lastMaintenanceCheck then displayState.lastMaintenanceCheck = state.lastMaintenanceCheck end
    if state.redstoneFreq then displayState.redstoneFreq = state.redstoneFreq end
    if state.redstoneOutput ~= nil then displayState.redstoneOutput = state.redstoneOutput end
    if state.uptime then displayState.uptime = state.uptime end

    -- 添加错误消息
    if state.error then
        table.insert(displayState.errors, os.date("%H:%M:%S") .. " " .. state.error)
        if #displayState.errors > 5 then
            table.remove(displayState.errors, 1)
        end
    end
end

-- ==================== 渲染 ====================

local function setColor(hex)
    if not gpu then return end
    pcall(function()
        gpu.setForeground(hex)
    end)
end

local function resetColor()
    if not gpu then return end
    pcall(function()
        gpu.setForeground(0xFFFFFF)
    end)
end

local function writeAt(x, y, text, color)
    if gpu then
        if x and y then
            pcall(function()
                gpu.set(x, y, text)
            end)
        end
    else
        -- 回退到 term 输出
        print(text)
    end

    -- 颜色通过终端输出时无法逐行设置，这里仅用于 GPU 模式
    if color and gpu then
        setColor(color)
    end
end

local function drawSeparator(y, char)
    if not gpu then return end
    local w, h = gpu.getResolution()
    char = char or "="
    pcall(function()
        gpu.set(1, y, string.rep(char, w))
    end)
end

local function drawHeader()
    if not gpu then
        print("")
        print("╔══════════════════════════════════════════════════╗")
        print("║      QFT 矿物处理 & AE 产物维持 控制系统        ║")
        print("╚══════════════════════════════════════════════════╝")
        return
    end

    local w = gpu.getResolution()
    setColor(0x00FF00)
    gpu.set(1, 1, string.rep("=", w))
    local title = "  QFT 矿物处理 & AE 产物维持 控制系统  "
    local titleX = math.floor((w - #title) / 2) + 1
    gpu.set(titleX, 2, title)
    gpu.set(1, 3, string.rep("=", w))
    resetColor()
end

local function drawStatus()
    if not gpu then
        print(string.format("运行时间: %s", displayState.uptime))
        print(string.format("当前模式: %s", displayState.mode))
        print(string.format("矿物项目: %s (%s)", displayState.mineralCurrent, displayState.mineralIndex))
        print(string.format("QFT 状态: %s (进度: %d)", displayState.qftStatus, displayState.qftProgress))
        print(string.format("红石频率: %d | 输出: %s", displayState.redstoneFreq,
            displayState.redstoneOutput and "开启" or "关闭"))
        print(string.format("产物维持: %s | 任务数: %d",
            displayState.maintenanceActive and "活跃" or "空闲",
            displayState.maintenanceCount))
        print("")
        return
    end

    local row = 5
    setColor(0xFFFF00)
    gpu.set(1, row, string.format("  运行时间: %s", displayState.uptime)); row = row + 1
    resetColor()

    -- 模式指示
    local modeColor = displayState.maintenanceActive and 0xFF6600 or 0x00FF00
    setColor(modeColor)
    gpu.set(1, row, string.format("  当前模式: %s", displayState.mode)); row = row + 1
    resetColor()

    -- 矿物处理
    gpu.set(1, row, string.format("  矿物项目: %s (%s)", displayState.mineralCurrent, displayState.mineralIndex))
    row = row + 1

    -- QFT 状态
    local qftColor = 0xFFFFFF
    if displayState.qftStatus == "运行中" then qftColor = 0x00FF00
    elseif displayState.qftStatus == "空闲" then qftColor = 0xFF6600
    elseif displayState.qftStatus == "超时" then qftColor = 0xFF0000
    end
    setColor(qftColor)
    gpu.set(1, row, string.format("  QFT 状态: %s | 进度: %d", displayState.qftStatus, displayState.qftProgress))
    row = row + 1
    resetColor()

    -- 红石状态
    local rsColor = displayState.redstoneOutput and 0x00FF00 or 0x888888
    setColor(rsColor)
    gpu.set(1, row, string.format("  红石频率: %d | 输出: %s",
        displayState.redstoneFreq,
        displayState.redstoneOutput and "● 开启" or "○ 关闭"))
    row = row + 1
    resetColor()

    -- 产物维持
    local maintColor = displayState.maintenanceActive and 0xFF6600 or 0x888888
    setColor(maintColor)
    gpu.set(1, row, string.format("  产物维持: %s | 活跃任务: %d",
        displayState.maintenanceActive and "▲ 活跃中" or "△ 空闲",
        displayState.maintenanceCount))
    row = row + 1
    resetColor()

    -- 分隔线
    row = row + 1
    drawSeparator(row, "-")
    row = row + 1

    -- 矿物处理计时器
    if displayState.mineralTimer > 0 then
        gpu.set(1, row, string.format("  矿物计时: %d 秒", displayState.mineralTimer))
        row = row + 1
    end
end

local function drawErrors()
    if not gpu then
        if #displayState.errors > 0 then
            print("--- 最近消息 ---")
            for _, err in ipairs(displayState.errors) do
                print("  " .. err)
            end
        end
        return
    end

    local w = gpu.getResolution()
    local row = gpu.getResolution()
    row = row - math.min(#displayState.errors, 5) - 1

    drawSeparator(row, "-")
    row = row + 1

    setColor(0x888888)
    for i = #displayState.errors, math.max(1, #displayState.errors - 4), -1 do
        if row <= gpu.getResolution() then
            local text = "  " .. displayState.errors[i]
            if #text > w then text = text:sub(1, w - 3) .. "..." end
            gpu.set(1, row, text)
            row = row + 1
        end
    end
    resetColor()
end

--- 完整渲染所有内容
function UI.render()
    if term then term.clear() end
    drawHeader()
    drawStatus()
    drawErrors()
end

-- ==================== 简单屏幕输出（无 GPU 回退） ====================

function UI.printStatus(state)
    print("")
    print("==========================================")
    print("  QFT 矿物处理 & AE 产物维持 控制系统")
    print("==========================================")
    print("  运行时间  : " .. (state.uptime or "N/A"))
    print("  当前模式  : " .. (state.mode or "N/A"))
    print("  矿物项目  : " .. (state.mineralCurrent or "无") .. " (" .. (state.mineralIndex or "0/0") .. ")")
    print("  QFT 状态  : " .. (state.qftStatus or "未知"))
    print("  红石频率  : " .. tostring(state.redstoneFreq or 0))
    print("  红石输出  : " .. (state.redstoneOutput and "开启" or "关闭"))
    print("  产物维持  : " .. (state.maintenanceActive and "活跃" or "空闲"))
    print("  维持任务  : " .. tostring(state.maintenanceCount or 0))
    print("==========================================")
end

-- ==================== 导出 ====================

return UI
