--[[
  redstone.lua — WR-CBE 无线红石控制模块
  封装 T2 红石卡的无线红石功能，用于控制远处 ME 输出总线的开关。
]]

local RedstoneControl = {}
local rs = nil
local currentFrequency = nil
local outputEnabled = false

-- ==================== 初始化 ====================

function RedstoneControl.init(redstoneComponent)
    rs = redstoneComponent
    if not rs then
        return false, "红石卡组件为空"
    end

    -- 验证无线红石功能可用
    local ok, err = pcall(function()
        rs.getWirelessFrequency()
    end)
    if not ok then
        return false, "红石卡不支持无线红石功能，请使用 T2 红石卡"
    end

    -- 读取当前状态
    local okFreq, freq = pcall(function() return rs.getWirelessFrequency() end)
    if okFreq then
        currentFrequency = freq
    end

    local okOut, out = pcall(function() return rs.getWirelessOutput() end)
    if okOut then
        outputEnabled = out
    end

    return true, nil
end

-- ==================== 频率控制 ====================

--- 设置无线红石频率
--- @param freq number 频率值（整数）
--- @return boolean, string 成功标志和错误消息
function RedstoneControl.setFrequency(freq)
    if not rs then
        return false, "红石卡未初始化"
    end

    if currentFrequency == freq then
        return true, nil  -- 频率未变，无需操作
    end

    local ok, err = pcall(function()
        rs.setWirelessFrequency(freq)
    end)

    if not ok then
        return false, "设置无线频率失败: " .. tostring(err)
    end

    currentFrequency = freq
    return true, nil
end

--- 获取当前无线红石频率
--- @return number|nil 当前频率
function RedstoneControl.getFrequency()
    if not rs then return nil end
    local ok, freq = pcall(function() return rs.getWirelessFrequency() end)
    if ok then
        currentFrequency = freq
        return freq
    end
    return currentFrequency
end

-- ==================== 输出控制 ====================

--- 开启无线红石输出（打开输入总线）
--- @return boolean, string
function RedstoneControl.enableOutput()
    if not rs then
        return false, "红石卡未初始化"
    end

    if outputEnabled then
        return true, nil  -- 已经开启
    end

    local ok, err = pcall(function()
        rs.setWirelessOutput(true)
    end)

    if not ok then
        return false, "开启无线输出失败: " .. tostring(err)
    end

    outputEnabled = true
    return true, nil
end

--- 关闭无线红石输出（关闭输入总线）
--- @return boolean, string
function RedstoneControl.disableOutput()
    if not rs then
        return false, "红石卡未初始化"
    end

    if not outputEnabled then
        return true, nil  -- 已经关闭
    end

    local ok, err = pcall(function()
        rs.setWirelessOutput(false)
    end)

    if not ok then
        return false, "关闭无线输出失败: " .. tostring(err)
    end

    outputEnabled = false
    return true, nil
end

--- 切换输出状态
--- @param enable boolean true=开启, false=关闭
--- @return boolean, string
function RedstoneControl.setOutput(enable)
    if enable then
        return RedstoneControl.enableOutput()
    else
        return RedstoneControl.disableOutput()
    end
end

--- 获取当前输出状态
--- @return boolean
function RedstoneControl.isOutputEnabled()
    if not rs then return false end
    local ok, out = pcall(function() return rs.getWirelessOutput() end)
    if ok then
        outputEnabled = out
    end
    return outputEnabled
end

-- ==================== 综合控制 ====================

--- 切换到指定频率并开启输出（一次完成配方切换）
--- @param freq number WR-CBE 频率
--- @return boolean, string
function RedstoneControl.switchToFrequency(freq)
    -- 先关闭当前输出
    RedstoneControl.disableOutput()

    -- 设置频率
    local ok, err = RedstoneControl.setFrequency(freq)
    if not ok then
        return false, err
    end

    -- 短暂延迟后开启输出（让红石信号稳定）
    os.sleep(0.5)

    -- 开启输出
    ok, err = RedstoneControl.enableOutput()
    if not ok then
        return false, err
    end

    return true, nil
end

--- 安全关闭所有红石输出
function RedstoneControl.shutdown()
    if rs then
        pcall(function() rs.setWirelessOutput(false) end)
    end
    outputEnabled = false
end

-- ==================== 状态查询 ====================

function RedstoneControl.getStatus()
    return {
        frequency = currentFrequency,
        outputEnabled = outputEnabled,
        initialized = rs ~= nil,
    }
end

-- ==================== 导出 ====================

return RedstoneControl
