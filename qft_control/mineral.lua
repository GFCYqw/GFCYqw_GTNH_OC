--[[
  mineral.lua — 矿物处理核心模块
  维护矿物处理列表的循环切换，监控 QFT 运行状态，空闲超时自动切换。
]]

local MineralProcessor = {}
local redstone = nil       -- RedstoneControl 模块
local qftMachine = nil     -- QFT gt_machine 代理
local config = nil         -- 矿物列表配置

-- ==================== 内部状态 ====================

local state = {
    currentIndex = 1,          -- 当前矿物索引
    switchTime = 0,            -- 最近一次切换的时间 (computer.uptime)
    idleStartTime = nil,       -- QFT 开始空闲的时间
    active = false,            -- 矿物处理是否激活
    lastWorkProgress = 0,      -- 上次的工作进度
}

-- ==================== 初始化 ====================

function MineralProcessor.init(redstoneModule, qftProxy, mineralList, qftConfig)
    redstone = redstoneModule
    qftMachine = qftProxy
    config = {
        list = mineralList or {},
        checkInterval = (qftConfig and qftConfig.checkInterval) or 5,
        minRunTime = (qftConfig and qftConfig.minRunTime) or 10,
    }

    if #config.list == 0 then
        return false, "矿物处理列表为空"
    end

    state.currentIndex = 1
    state.switchTime = 0
    state.active = false

    return true, nil
end

-- ==================== QFT 状态检测 ====================

--- 检测 QFT 是否正在运行
--- @return boolean true=正在运行
function MineralProcessor.isQFTRunning()
    if not qftMachine then return false end

    local ok, progress = pcall(function()
        return qftMachine.getWorkProgress()
    end)

    if not ok then
        return false
    end

    -- getWorkProgress() 返回 > 0 表示机器正在处理配方
    state.lastWorkProgress = progress or 0
    return (progress or 0) > 0
end

--- 获取 QFT 工作进度
--- @return number 进度值
function MineralProcessor.getQFTProgress()
    if not qftMachine then return 0 end

    local ok, progress = pcall(function()
        return qftMachine.getWorkProgress()
    end)

    if not ok then return 0 end
    return progress or 0
end

--- 获取 QFT 最大工作进度
--- @return number
function MineralProcessor.getQFTMaxProgress()
    if not qftMachine then return 0 end

    local ok, maxProgress = pcall(function()
        return qftMachine.getWorkMaxProgress()
    end)

    if not ok then return 0 end
    return maxProgress or 0
end

-- ==================== 矿物切换 ====================

--- 切换到指定索引的矿物项目
--- @param index number 列表索引（1-based）
--- @return boolean, string
function MineralProcessor.switchTo(index)
    if index < 1 or index > #config.list then
        return false, "索引超出范围: " .. tostring(index)
    end

    local mineral = config.list[index]

    -- 使用红石模块切换到目标频率并开启输出
    local ok, err = redstone.switchToFrequency(mineral.wirelessFreq)
    if not ok then
        return false, "切换频率失败: " .. tostring(err)
    end

    state.currentIndex = index
    state.switchTime = require("computer").uptime()
    state.idleStartTime = nil
    state.active = true

    return true, string.format("切换到: %s (频率 %d)", mineral.displayName, mineral.wirelessFreq)
end

--- 切换到下一个矿物
--- @return boolean, string
function MineralProcessor.switchToNext()
    local nextIndex = state.currentIndex + 1
    if nextIndex > #config.list then
        nextIndex = 1
    end
    return MineralProcessor.switchTo(nextIndex)
end

--- 获取当前矿物项目信息
--- @return table|nil
function MineralProcessor.getCurrentMineral()
    if state.currentIndex < 1 or state.currentIndex > #config.list then
        return nil
    end
    return config.list[state.currentIndex]
end

--- 获取当前索引和总数
--- @return number, number
function MineralProcessor.getProgress()
    return state.currentIndex, #config.list
end

-- ==================== 超时检测 ====================

--- 检查当前矿物项目是否超时
--- 逻辑：
---   1. 如果 QFT 正在运行 → 更新 idleStartTime 为 nil，不超时
---   2. 如果刚切换不久（< cycleTime）→ 不检测超时（给机器启动时间）
---   3. 如果 QFT 空闲时间 > timeout → 超时
--- @return boolean 是否超时
--- @return string 原因描述
function MineralProcessor.checkTimeout()
    if not state.active then
        return false, "矿物处理未激活"
    end

    local mineral = MineralProcessor.getCurrentMineral()
    if not mineral then
        return false, "无当前矿物项目"
    end

    local now = require("computer").uptime()
    local running = MineralProcessor.isQFTRunning()

    if running then
        -- QFT 正在运行，重置空闲计时
        state.idleStartTime = nil
        return false, "QFT 运行中"
    end

    -- QFT 空闲

    -- 检查是否还在最小运行时间保护期内
    local elapsedSinceSwitch = now - state.switchTime
    if elapsedSinceSwitch < (mineral.cycleTime or config.minRunTime) then
        return false, string.format("运行保护期内 (%d/%d 秒)",
            math.floor(elapsedSinceSwitch), mineral.cycleTime or config.minRunTime)
    end

    -- 记录空闲开始时间
    if state.idleStartTime == nil then
        state.idleStartTime = now
    end

    local idleDuration = now - state.idleStartTime
    local timeout = mineral.timeout or 120

    if idleDuration >= timeout then
        return true, string.format("QFT 空闲超时 (%d/%d 秒)", math.floor(idleDuration), timeout)
    end

    return false, string.format("QFT 空闲中 (%d/%d 秒)", math.floor(idleDuration), timeout)
end

--- 获取当前空闲持续时间
--- @return number 秒
function MineralProcessor.getIdleDuration()
    if state.idleStartTime == nil then return 0 end
    return require("computer").uptime() - state.idleStartTime
end

-- ==================== 矿物处理主循环 ====================

--- 执行一轮矿物处理检查
--- 如果 QFT 超时，自动切换到下一项
--- @return boolean 是否发生了切换
--- @return string 状态消息
function MineralProcessor.tick()
    if not state.active then
        -- 首次启动，切换到第一个项目
        local ok, msg = MineralProcessor.switchTo(1)
        if not ok then
            return false, msg
        end
        return true, msg
    end

    local timeout, reason = MineralProcessor.checkTimeout()
    if timeout then
        local ok, msg = MineralProcessor.switchToNext()
        if ok then
            return true, "超时切换: " .. reason .. " → " .. msg
        else
            return false, "超时但切换失败: " .. msg
        end
    end

    -- 未超时，返回当前状态
    return false, reason
end

-- ==================== 控制 ====================

--- 暂停矿物处理（产物维持激活时调用）
function MineralProcessor.pause()
    if state.active and redstone then
        redstone.disableOutput()
    end
    state.active = false
end

--- 恢复矿物处理
function MineralProcessor.resume()
    if not state.active then
        -- 恢复当前项目
        local mineral = MineralProcessor.getCurrentMineral()
        if mineral then
            redstone.setFrequency(mineral.wirelessFreq)
            redstone.enableOutput()
        end
        state.active = true
        state.switchTime = require("computer").uptime()
        state.idleStartTime = nil
    end
end

--- 安全关闭
function MineralProcessor.shutdown()
    if redstone then
        redstone.shutdown()
    end
    state.active = false
end

-- ==================== 状态查询 ====================

function MineralProcessor.getState()
    local mineral = MineralProcessor.getCurrentMineral()
    return {
        active = state.active,
        currentIndex = state.currentIndex,
        totalCount = #config.list,
        currentName = mineral and mineral.displayName or "无",
        currentFreq = mineral and mineral.wirelessFreq or 0,
        isRunning = MineralProcessor.isQFTRunning(),
        progress = state.lastWorkProgress,
        maxProgress = MineralProcessor.getQFTMaxProgress(),
        idleDuration = MineralProcessor.getIdleDuration(),
    }
end

-- ==================== 导出 ====================

return MineralProcessor
