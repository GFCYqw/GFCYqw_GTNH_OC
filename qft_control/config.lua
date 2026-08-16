--[[
  config.lua — QFT矿物处理 + AE产物维持 配置文件
  修改此文件中的参数来适配你的实际搭建
]]

-- ==================== 矿物处理列表 ====================
-- 每个项目定义：
--   name         = 内部标识名
--   displayName  = 屏幕显示名
--   wirelessFreq = WR-CBE 无线红石频率（控制对应输入总线开关）
--   timeout      = QFT 空闲超时（秒），超过此时间未运行则切换到下一项
--   cycleTime    = 此项目至少运行的时间（秒），在此之前不检查超时
local MINERAL_LIST = {
    { name = "pt_metals",    displayName = "铂系金属",     wirelessFreq = 1,  timeout = 120, cycleTime = 30 },
    { name = "plastic",      displayName = "塑料聚合物",    wirelessFreq = 2,  timeout = 120, cycleTime = 30 },
    { name = "rubber",       displayName = "橡胶聚合物",    wirelessFreq = 3,  timeout = 120, cycleTime = 30 },
    { name = "radioactive",  displayName = "放射处理",      wirelessFreq = 4,  timeout = 120, cycleTime = 30 },
    { name = "ti_w_in",      displayName = "钛钨铟处理",    wirelessFreq = 5,  timeout = 120, cycleTime = 30 },
    { name = "adhesion",     displayName = "黏合促进",      wirelessFreq = 6,  timeout = 120, cycleTime = 30 },
    -- 按需添加更多项目...
}

-- ==================== QFT 相关配置 ====================
local QFT_CONFIG = {
    -- QFT 机器名称（用于在 gt_machine 列表中识别）
    machineName = "multimachine.quantumforcetransformer",
    -- 矿物处理循环间隔（秒）— 多久检查一次 QFT 状态
    checkInterval = 5,
    -- 机器启动后需要等待的最短时间（让配方有时间开始运行）
    minRunTime = 10,
}

-- ==================== 产物维持配置 ====================
local MAINTENANCE_CONFIG = {
    -- 请求器扫描间隔（秒）— 多久重新读取一次 Level Maintainer 配置
    rescanInterval = 60,
    -- 库存检查间隔（秒）— 多久检查一次物品/流体存量
    inventoryCheckInterval = 10,
    -- AE 合成单次请求的最大数量倍率 (阈值 * 倍率 - 当前库存 = 请求量)
    orderMultiplier = 1.0,
    -- 合成失败后减半重试的最大次数
    maxRetryHalf = 10,
    -- 最低合成请求数量
    lowestOrderQuantity = 1000,
    -- 单 CPU 模式下，合成完成后等待时间（秒）
    singleCpuWaitTime = 10,
    -- 多 CPU 模式下，请求间隔（秒）
    multiCpuInterval = 3,
}

-- ==================== UI 配置 ====================
local UI_CONFIG = {
    -- 屏幕刷新间隔（秒）
    refreshInterval = 1,
}

-- ==================== 通用配置 ====================
local GENERAL_CONFIG = {
    -- 主循环休眠间隔（秒）
    mainLoopSleep = 1,
    -- 是否启用详细日志
    verbose = false,
}

-- ==================== 导出 ====================
return {
    MINERAL_LIST = MINERAL_LIST,
    QFT_CONFIG = QFT_CONFIG,
    MAINTENANCE_CONFIG = MAINTENANCE_CONFIG,
    UI_CONFIG = UI_CONFIG,
    GENERAL_CONFIG = GENERAL_CONFIG,
}
