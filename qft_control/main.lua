--[[
  main.lua — QFT 矿物处理 & AE 产物维持 控制系统 主入口

  优先级调度：
    1. 产物维持检查（高优先级）— 读取请求器 → 查库存 → AE 下单
    2. 矿物处理循环（低优先级）— 无维持任务时循环切换矿物/QFT 超时切换

  用法：
    - 将此文件夹 (qft_control/) 复制到 OC 的 /home 目录
    - 在 OC 终端输入: cd /home/qft_control && main
]]

local component = require("component")
local computer = require("computer")
local event = require("event")
local os = require("os")
local term = require("term")
local shell = require("shell")

-- ==================== 加载本地模块 ====================
-- 使用 dofile 以确保在 OC 环境下可靠加载同目录的模块文件

local function loadModule(name)
    local path = shell.resolve(name .. ".lua")
    if not path then
        -- 尝试在当前目录直接加载
        path = name .. ".lua"
    end
    local ok, result = pcall(dofile, path)
    if not ok then
        print(string.format("[错误] 无法加载模块 %s: %s", name, tostring(result)))
        os.exit(1)
    end
    return result
end

local cfg = loadModule("config")
local comp = loadModule("components")
local UI = loadModule("ui")
local RedstoneControl = loadModule("redstone")
local MaintainerReader = loadModule("maintainer")
local InventoryChecker = loadModule("inventory")
local CraftingManager = loadModule("crafting")
local MineralProcessor = loadModule("mineral")

-- ==================== 全局状态 ====================

local running = true
local startTime = 0
local lastMaintenanceCheck = 0
local lastInventoryCheck = 0
local lastRequestRescan = 0
local cachedTargets = { items = {}, fluids = {} }
local maintenanceActive = false
local maintenanceStats = { ordersSuccess = 0, ordersFailed = 0, lastCheck = "" }

-- ==================== 辅助函数 ====================

local function formatTime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

-- ==================== 初始化 ====================

local function initialize()
    print("==========================================")
    print("  QFT 矿物处理 & AE 产物维持 控制系统")
    print("  v1.0 — " .. os.date("%Y-%m-%d %H:%M:%S"))
    print("==========================================")
    print("")

    -- Step 1: 初始化组件
    print("[初始化] 扫描组件...")
    comp.init()
    if not comp.isReady() then
        print("\n[致命错误] 缺少关键组件，程序无法启动")
        print("请确保已连接：")
        print("  - ME 接口 (me_interface)")
        print("  - T2 红石卡 (redstone)")
        print("  - QFT 机器 (gt_machine via 适配器/MFU)")
        return false
    end
    print("")

    -- Step 2: 初始化红石控制
    print("[初始化] 设置红石控制...")
    local ok, err = RedstoneControl.init(comp.rs())
    if not ok then
        print("[错误] 红石控制初始化失败: " .. tostring(err))
        return false
    end
    print("  红石控制就绪")
    print("")

    -- Step 3: 初始化库存检查器
    print("[初始化] 设置库存检查...")
    local meNet = comp.getMENetwork()
    if not InventoryChecker.init(meNet) then
        print("[错误] 库存检查器初始化失败")
        return false
    end
    print("  库存检查器就绪 (使用 " .. (comp.get().me_controller and "ME控制器" or "ME接口") .. ")")
    print("")

    -- Step 4: 初始化合成管理器
    print("[初始化] 设置合成管理器...")
    if not CraftingManager.init(meNet, comp.gpu(), cfg.MAINTENANCE_CONFIG) then
        print("[错误] 合成管理器初始化失败")
        return false
    end
    local cpuCount = CraftingManager.getCPUCount()
    print(string.format("  合成管理器就绪 | CPU 数量: %d | 模式: %s",
        cpuCount, cpuCount <= 1 and "单CPU(阻塞)" or "多CPU(非阻塞)"))
    print("")

    -- Step 5: 初始化矿物处理器
    if comp.qft() then
        print("[初始化] 设置矿物处理器...")
        ok, err = MineralProcessor.init(RedstoneControl, comp.qft(), cfg.MINERAL_LIST, cfg.QFT_CONFIG)
        if not ok then
            print("[警告] 矿物处理器初始化失败: " .. tostring(err))
            print("  矿物处理功能不可用，仅运行产物维持")
        else
            print(string.format("  矿物处理器就绪 | 共 %d 个项目", #cfg.MINERAL_LIST))
        end
    else
        print("[警告] 未检测到 QFT，矿物处理功能不可用")
    end
    print("")

    -- Step 6: 初始化 UI
    UI.init(comp.gpu())

    -- Step 7: 注册中断处理
    event.listen("interrupted", function()
        running = false
        print("\n[中断] 收到 Ctrl+C，正在安全退出...")
    end)

    startTime = computer.uptime()
    print("[初始化] 系统就绪，开始主循环")
    print("  按 Ctrl+C 安全退出")
    print("")

    return true
end

-- ==================== 产物维持循环 ====================

local function runMaintenanceCycle()
    local now = computer.uptime()

    -- 定期重新扫描请求器
    if now - lastRequestRescan >= cfg.MAINTENANCE_CONFIG.rescanInterval then
        local maintainers = comp.maintainers()
        if maintainers and #maintainers > 0 then
            cachedTargets = MaintainerReader.scanAll(maintainers)
            lastRequestRescan = now

            if cfg.GENERAL_CONFIG.verbose then
                print(string.format("[请求器扫描] 物品: %d, 流体: %d",
                    #cachedTargets.items, #cachedTargets.fluids))
            end
        end
    end

    -- 定期检查库存并发起合成
    if now - lastInventoryCheck >= cfg.MAINTENANCE_CONFIG.inventoryCheckInterval then
        lastInventoryCheck = now

        if #cachedTargets.items > 0 or #cachedTargets.fluids > 0 then
            local needsOrder, summary = InventoryChecker.checkAllTargets(cachedTargets)

            if #needsOrder.items > 0 or #needsOrder.fluids > 0 then
                maintenanceActive = true

                if cfg.GENERAL_CONFIG.verbose then
                    print("\n[产物维持] 检测到需要补货:")
                    for _, line in ipairs(summary) do
                        print("  " .. line)
                    end
                end

                -- 暂停矿物处理
                MineralProcessor.pause()

                -- 发起合成订单
                local successCount = CraftingManager.processMaintenanceOrders(needsOrder)
                maintenanceStats.ordersSuccess = maintenanceStats.ordersSuccess + successCount
                maintenanceStats.ordersFailed = maintenanceStats.ordersFailed
                    + math.max(0, #needsOrder.items - successCount)
                maintenanceStats.lastCheck = os.date("%H:%M:%S")

                UI.updateState({ error = string.format("产物维持: %d 项下单 (%d 成功)",
                    #needsOrder.items, successCount) })

                if cfg.GENERAL_CONFIG.verbose then
                    print(string.format("[产物维持] 本周期: %d 次下单, %d 成功",
                        #needsOrder.items, successCount))
                end
            else
                maintenanceActive = false
                if cfg.GENERAL_CONFIG.verbose then
                    print("[产物维持] 所有产物库存充足")
                end
            end
        end
    end

    lastMaintenanceCheck = now
end

-- ==================== 矿物处理循环 ====================

local function runMineralCycle()
    if not comp.qft() then return end

    -- 如果产物维持不活跃，则执行矿物处理
    if not maintenanceActive then
        -- 确保矿物处理是激活状态
        if not MineralProcessor.getState().active then
            MineralProcessor.resume()
        end

        local switched, msg = MineralProcessor.tick()
        if switched and cfg.GENERAL_CONFIG.verbose then
            print("[矿物处理] " .. msg)
        end
    end
end

-- ==================== UI 更新 ====================

local function updateUI()
    local now = computer.uptime()
    local mineralState = MineralProcessor.getState()
    local rsStatus = RedstoneControl.getStatus()
    local cpuCount = CraftingManager.getCPUCount()

    UI.updateState({
        mode = maintenanceActive and "产物维持" or "矿物处理",
        mineralCurrent = mineralState.currentName,
        mineralIndex = string.format("%d/%d", mineralState.currentIndex, mineralState.totalCount),
        mineralTimer = mineralState.idleDuration,
        qftStatus = mineralState.isRunning and "运行中" or (mineralState.active and "空闲" or "已暂停"),
        qftProgress = mineralState.progress,
        maintenanceActive = maintenanceActive,
        maintenanceCount = maintenanceStats.ordersSuccess,
        lastMaintenanceCheck = math.floor(now - lastMaintenanceCheck),
        redstoneFreq = rsStatus.frequency or 0,
        redstoneOutput = rsStatus.outputEnabled,
        uptime = formatTime(now - startTime),
    })
end

-- ==================== 安全退出 ====================

local function shutdown()
    print("\n[退出] 正在安全关闭...")

    -- 关闭红石输出
    RedstoneControl.shutdown()
    print("  红石输出已关闭")

    -- 面板还原
    if comp.gpu() then
        pcall(function()
            comp.gpu().setForeground(0xFFFFFF)
            comp.gpu().setResolution(80, 25)
        end)
    end
    if term then
        term.clear()
    end

    print("[退出] 系统已安全停止")
    print(string.format("  总运行时间: %s", formatTime(computer.uptime() - startTime)))
    print(string.format("  合成订单: %d 成功", maintenanceStats.ordersSuccess))
end

-- ==================== 主循环 ====================

local function main()
    if not initialize() then
        print("\n按任意键退出...")
        os.sleep(9999)
        return
    end

    -- 预热：执行一次请求器扫描
    lastRequestRescan = 0  -- 强制立即扫描
    runMaintenanceCycle()

    print("\n" .. string.rep("-", 40))
    print("系统开始运行，按 Ctrl+C 退出")
    print(string.rep("-", 40) .. "\n")

    while running do
        local loopStart = computer.uptime()

        -- 1. 产物维持检查（高优先级）
        runMaintenanceCycle()

        -- 2. 矿物处理循环（低优先级，仅在无维持任务时运行）
        runMineralCycle()

        -- 3. 更新 UI
        updateUI()
        UI.render()

        -- 4. 休眠
        local elapsed = computer.uptime() - loopStart
        local sleepTime = math.max(0.1, cfg.GENERAL_CONFIG.mainLoopSleep - elapsed)

        -- 使用 event.pull 而不是 os.sleep，以便响应中断信号
        local evt = event.pull(sleepTime)
        if evt == "interrupted" then
            running = false
        end
    end

    shutdown()
end

-- ==================== 启动 ====================

local ok, err = pcall(main)
if not ok then
    print("\n[致命错误] 程序崩溃: " .. tostring(err))
    print(debug.traceback())
    RedstoneControl.shutdown()
end
