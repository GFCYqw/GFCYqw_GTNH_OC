--[[
  components.lua — 组件初始化与安全获取
  扫描所有连接的 OC 组件，返回统一的结构供其他模块使用
]]

local component = require("component")

local Components = {
    -- ME 网络接口（主网）
    me_interface = nil,
    -- ME 控制器（可选，如果有子网）
    me_controller = nil,
    -- 红石卡（T2，支持 WR-CBE 无线红石）
    redstone = nil,
    -- QFT 量子操纵者机器代理
    qft_machine = nil,
    -- 所有 Level Maintainer（请求器）列表
    level_maintainers = {},
    -- GPU（用于屏幕显示）
    gpu = nil,
    -- 转运器（如果有需要）
    transposer = nil,
    -- 初始化是否完整
    initialized = false,
    -- 错误信息列表
    errors = {},
    -- 警告信息列表
    warnings = {},
}

-- ==================== 辅助函数 ====================

local function logError(msg)
    table.insert(Components.errors, msg)
end

local function logWarning(msg)
    table.insert(Components.warnings, msg)
end

-- ==================== 组件扫描 ====================

local function scanAllComponents()
    local componentCount = 0
    for address, name in component.list() do
        componentCount = componentCount + 1
    end
    return componentCount
end

local function findMEInterface()
    -- 优先查找 me_interface
    if component.isAvailable("me_interface") then
        Components.me_interface = component.me_interface
        return true
    end

    -- 尝试通过 address 列表查找
    for address, name in component.list("me_interface") do
        Components.me_interface = component.proxy(address)
        return true
    end

    logError("未找到 ME 接口 (me_interface) — 无法查询网络库存和发起合成")
    return false
end

local function findMEController()
    -- 子网 ME 控制器（可选）
    for address, name in component.list("me_controller") do
        Components.me_controller = component.proxy(address)
        return true
    end
    logWarning("未找到 ME 控制器 (me_controller) — 将仅使用 ME 接口")
    return false
end

local function findRedstoneCard()
    if component.isAvailable("redstone") then
        Components.redstone = component.redstone
        -- 验证是否为 T2 红石卡（支持无线功能）
        local ok, freq = pcall(function() return Components.redstone.getWirelessFrequency() end)
        if ok then
            return true
        else
            logWarning("红石卡不支持无线功能 — 请使用 T2 红石卡以启用 WR-CBE 控制")
            return false
        end
    end

    for address, name in component.list("redstone") do
        local rs = component.proxy(address)
        local ok, freq = pcall(function() return rs.getWirelessFrequency() end)
        if ok then
            Components.redstone = rs
            return true
        end
    end

    logError("未找到红石卡 (redstone, T2) — 无法控制 WR-CBE 无线红石")
    return false
end

local function findQFTMachine(cfgName)
    for address, name in component.list("gt_machine") do
        local ok, machineName = pcall(function()
            return component.invoke(address, "getName")
        end)
        if ok and machineName and machineName:find(cfgName or "quantumforcetransformer") then
            Components.qft_machine = component.proxy(address)
            return true
        end
    end
    logError("未找到量子操纵者 (QFT) 机器 — 请确保已通过适配器/MFU 连接")
    return false
end

local function findLevelMaintainers()
    for address, name in component.list("level_maintainer") do
        local maintainer = component.proxy(address)
        table.insert(Components.level_maintainers, maintainer)
    end

    if #Components.level_maintainers == 0 then
        logWarning("未找到 Level Maintainer（请求器） — 产物维持功能将不可用")
    end
end

local function findGPU()
    if component.isAvailable("gpu") then
        Components.gpu = component.gpu
        return true
    end
    for address, name in component.list("gpu") do
        Components.gpu = component.proxy(address)
        return true
    end
    logWarning("未找到 GPU — 屏幕显示将使用 term 基础输出")
    return false
end

local function findTransposer()
    if component.isAvailable("transposer") then
        Components.transposer = component.transposer
        return true
    end
    for address, name in component.list("transposer") do
        Components.transposer = component.proxy(address)
        return true
    end
    -- transposer 是可选的
    return false
end

-- ==================== 初始化入口 ====================

local function init()
    if Components.initialized then
        return Components
    end

    -- 打印扫描概况
    local totalComponents = scanAllComponents()
    print(string.format("[组件扫描] 共检测到 %d 个组件", totalComponents))

    -- 按依赖顺序初始化
    findMEInterface()
    findMEController()
    findRedstoneCard()
    findQFTMachine()
    findLevelMaintainers()
    findGPU()
    findTransposer()

    -- 检查关键组件
    local criticalOk = true
    if not Components.me_interface then
        print("[错误] 缺少 ME 接口，程序无法运行")
        criticalOk = false
    end
    if not Components.redstone then
        print("[错误] 缺少 T2 红石卡，无法控制 WR-CBE")
        criticalOk = false
    end
    if not Components.qft_machine then
        print("[警告] 缺少 QFT 机器连接，矿物处理功能不可用")
        -- QFT 不是绝对必需的，产物维持功能仍然可以工作
    end

    -- 打印状态摘要
    print(string.format("ME 接口    : %s", Components.me_interface and "已连接" or "未找到"))
    print(string.format("ME 控制器  : %s", Components.me_controller and "已连接" or "未连接（可选）"))
    print(string.format("红石卡     : %s", Components.redstone and "已连接 (T2)" or "未找到"))
    print(string.format("QFT 机器   : %s", Components.qft_machine and "已连接" or "未找到"))
    print(string.format("请求器数量 : %d", #Components.level_maintainers))
    print(string.format("GPU        : %s", Components.gpu and "已连接" or "未连接"))
    print(string.format("转运器     : %s", Components.transposer and "已连接" or "未连接（可选）"))

    if #Components.errors > 0 then
        print("\n[初始化错误]")
        for _, err in ipairs(Components.errors) do
            print("  ! " .. err)
        end
    end

    if #Components.warnings > 0 then
        print("\n[初始化警告]")
        for _, warn in ipairs(Components.warnings) do
            print("  ~ " .. warn)
        end
    end

    Components.initialized = criticalOk
    return Components
end

-- ==================== 获取 ME 接口（优先用 controller，否则用 interface） ====================

local function getMENetwork()
    return Components.me_controller or Components.me_interface
end

-- ==================== 导出 ====================

return {
    init = init,
    get = function() return Components end,
    getMENetwork = getMENetwork,
    -- 便捷访问
    me = function() return Components.me_interface end,
    rs = function() return Components.redstone end,
    qft = function() return Components.qft_machine end,
    maintainers = function() return Components.level_maintainers end,
    gpu = function() return Components.gpu end,
    isReady = function() return Components.initialized end,
}
