-- 基于OC实现请求器的被动下单 - GTNH中文维基 - https://gtnh.huijiwiki.com/p/79406

local database = require("database")
local itemMonitor = require("itemMonitor")
local fluidMonitor = require("fluidMonitor")
local os = require("os")
local serialization = require("serialization")
local component = require("component")
local computer = require("computer")
local event = require("event")
 
local config = {
    clearLog = true,
    clearLogInterval = 30,
    checkInterval = 60,
    maintainerComponentName = "level_maintainer",
    debug = true,  -- 设为 false 关闭诊断日志写入文件
}
local craftingTrackFile = "/tmp/crafting_track.dat"
local craftingItems = {}
local craftingFluids = {}
 
-- 诊断日志
local diagLog = {}
local diagFile = "diag_log.txt"
local cycleNum = 0
 
local function diag(msg)
    if not config.debug then return end
    local ts = os.time()
    local entry = string.format("[%s][C%d] %s", tostring(ts), cycleNum, msg)
    table.insert(diagLog, entry)
end
 
local function diagFlush()
    if not config.debug then return end
    local file = io.open(diagFile, "w")
    if file then
        file:write(table.concat(diagLog, "\n"))
        file:close()
    end
end
 
local function loadCraftingTrack()
    local file = io.open(craftingTrackFile, "r")
    if file then
        local data = file:read("*a")
        file:close()
        if data and data ~= "" then
            local ok, result = pcall(serialization.unserialize, data)
            if ok and result then
                craftingItems = result.items or {}
                craftingFluids = result.fluids or {}
            end
        end
    end
end
 
local function saveCraftingTrack()
    local data = serialization.serialize({items = craftingItems, fluids = craftingFluids})
    local file = io.open(craftingTrackFile, "w")
    if file then file:write(data); file:close() end
end
 
local function clearScreen()
    if config.clearLog then
        os.execute("cls")
        print("ME网络智能监控系统 - 自动缓存管理")
        print("==================================")
    end
end
 
local function formatNumber(num)
    if not num or type(num) ~= "number" then
        return "0"
    end
    if num >= 1000000000 then
        return string.format("%.2fB", num/1000000000)
    elseif num >= 1000000 then
        return string.format("%.2fM", num/1000000)
    elseif num >= 1000 then
        return string.format("%.1fK", num/1000)
    else
        return tostring(math.floor(num))
    end
end
 
local function printHeader()
    local me = database.me()
    local cpuCount = #(database.craftingCPUs() or {})
    local maintainerCount = #(database.levelMaintainers() or {})
    print(string.format("CPU数量: %d | 请求器: %d",
          cpuCount, maintainerCount))
    print("----------------------------------")
end
 
local function batchCheckCraftingStatus(monitoringTargets, allCPUsContents)
    local craftingStatus = {items = {}, fluids = {}}
 
    diag(string.format("batchCheckCraftingStatus: 共 %d 个 CPU 数据", #allCPUsContents))
    for _, cpuData in ipairs(allCPUsContents) do
        if cpuData.isBusy then
            diag(string.format("  CPU#%d[%s] copro=%d busy contents=%d",
                cpuData.cpuIndex or 0, cpuData.cpuName,
                cpuData.coprocessors or 0, #cpuData.contents))
            if #cpuData.contents == 0 and cpuData._cpu then
                local aOk, ai = pcall(function() return cpuData._cpu.activeItems() end)
                if aOk and type(ai) == "table" then
                    diag(string.format("    activeItems 共 %d 个:", #ai))
                    for j, item in ipairs(ai) do
                        if j <= 5 and item then
                            if item.fluidDrop then
                                diag(string.format("      [%d] FLUID %s size=%s", j, item.fluidDrop.name, tostring(item.size)))
                            else
                                diag(string.format("      [%d] ITEM %s:%s size=%s", j, tostring(item.name), tostring(item.damage), tostring(item.size)))
                            end
                        end
                    end
                    if #ai > 5 then diag(string.format("      ... 共 %d 个", #ai)) end
                else
                    diag(string.format("    activeItems 查询失败: %s", aOk and tostring(ai) or tostring(ai)))
                end
            end
            for _, content in ipairs(cpuData.contents) do
                diag(string.format("    content type=%s name=%s damage=%s amount=%s",
                    content.type, content.name, tostring(content.damage), tostring(content.amount)))
                if content.type == "item" then
                    for _, item in ipairs(monitoringTargets.items) do
                        if content.name == item.name and content.damage == (item.damage or 0) then
                            if not craftingStatus.items[item.id] then
                                craftingStatus.items[item.id] = {isCrafting = true, amount = 0}
                            end
                            craftingStatus.items[item.id].amount = math.max(
                                craftingStatus.items[item.id].amount,
                                content.amount or 0
                            )
                            diag(string.format("      MATCH item id=%s display=%s", item.id, item.displayName))
                        end
                    end
                elseif content.type == "fluid" then
                    for _, fluid in ipairs(monitoringTargets.fluids) do
                        if content.name == fluid.id then
                            if not craftingStatus.fluids[fluid.id] then
                                craftingStatus.fluids[fluid.id] = {isCrafting = true, amount = 0}
                            end
                            craftingStatus.fluids[fluid.id].amount = math.max(
                                craftingStatus.fluids[fluid.id].amount,
                                content.amount or 0
                            )
                            diag(string.format("      MATCH fluid id=%s display=%s", fluid.id, fluid.displayName))
                        end
                    end
                end
            end
        end
    end
 
    local itemCnt, fluidCnt = 0, 0
    for id, s in pairs(craftingStatus.items) do if s.isCrafting then itemCnt = itemCnt + 1 end end
    for id, s in pairs(craftingStatus.fluids) do if s.isCrafting then fluidCnt = fluidCnt + 1 end end
    diag(string.format("batchCheckCraftingStatus 结果: %d items, %d fluids 正在合成", itemCnt, fluidCnt))
 
    return craftingStatus
end
 
local function checkCraftingStatus(monitoringTargets, allCPUsContents)
    local hasActiveCrafting = false
    local shown = {}
    local craftingStatus = batchCheckCraftingStatus(monitoringTargets, allCPUsContents)
 
    for _, item in ipairs(monitoringTargets.items) do
        local status = craftingStatus.items[item.id]
        if status and status.isCrafting and not shown[item.id] then
            shown[item.id] = true
            if not hasActiveCrafting then
                print("\n[合成状态] 正在合成中的物品:")
                hasActiveCrafting = true
            end
            print(string.format("- %s: %s/%s",
                  item.displayName or "未知物品",
                  formatNumber(status.amount or 0),
                  formatNumber(item.buffer or 0)))
        end
    end
 
    for _, fluid in ipairs(monitoringTargets.fluids) do
        local status = craftingStatus.fluids[fluid.id]
        if status and status.isCrafting and not shown[fluid.id] then
            shown[fluid.id] = true
            if not hasActiveCrafting then
                print("\n[合成状态] 正在合成中的流体:")
                hasActiveCrafting = true
            end
            print(string.format("- %s: %s/%s mB",
                  fluid.displayName or "未知流体",
                  formatNumber(status.amount or 0),
                  formatNumber(fluid.buffer or 0)))
        end
    end
    if not hasActiveCrafting then print("\n[合成状态] 当前没有正在合成的物品或流体") end
    return craftingStatus
end
 
local function cleanupOldTrack()
    local currentTime = os.time()
    for id, time in pairs(craftingItems) do if currentTime - time > 1800 then
        diag(string.format("cleanupOldTrack: 移除过期 item tracking id=%s (age=%s)", id, tostring(currentTime - time)))
        craftingItems[id] = nil
    end end
    for id, time in pairs(craftingFluids) do if currentTime - time > 1800 then
        diag(string.format("cleanupOldTrack: 移除过期 fluid tracking id=%s (age=%s)", id, tostring(currentTime - time)))
        craftingFluids[id] = nil
    end end
end
 
local function updateTrackingStatus(craftingStatus)
    for id, time in pairs(craftingItems) do
        local status = craftingStatus.items[id]
        if not status or not status.isCrafting then
            diag(string.format("updateTrackingStatus: 清除 item tracking id=%s (CPU上未检测到)", id))
            craftingItems[id] = nil
        end
    end
    for id, time in pairs(craftingFluids) do
        local status = craftingStatus.fluids[id]
        if not status or not status.isCrafting then
            diag(string.format("updateTrackingStatus: 清除 fluid tracking id=%s (CPU上未检测到)", id))
            craftingFluids[id] = nil
        end
    end
    saveCraftingTrack()
end
 
local function mainLoop()
    local ok, err = pcall(database.initComponents)
    if not ok then
        print("[错误] 初始化组件失败: " .. tostring(err))
        print("系统将在5秒后退出...")
        os.sleep(5)
        return
    end
 
    loadCraftingTrack()
 
    while true do
        cycleNum = cycleNum + 1
        diag(string.format("========== 周期 %d 开始 ==========", cycleNum))
        do
            local items = {}; for id in pairs(craftingItems) do table.insert(items, id) end
            local fluids = {}; for id in pairs(craftingFluids) do table.insert(fluids, id) end
            diag(string.format("tracking item ids: [%s]", table.concat(items, ", ")))
            diag(string.format("tracking fluid ids: [%s]", table.concat(fluids, ", ")))
        end
 
        clearScreen()
        printHeader()
        cleanupOldTrack()
 
        local monitoringTargets = database.getMonitoringTargets()
        print(string.format("\n[监控] 共发现 %d 个物品和 %d 个流体需要监控", #monitoringTargets.items, #monitoringTargets.fluids))
 
        local allCPUsContents = database.refreshCPUCache()
        diag(string.format("refreshCPUCache: 返回 %d 个 CPU", #allCPUsContents))
        do
            local busyCnt = 0
            for _, cd in ipairs(allCPUsContents) do
                if cd.isBusy and #cd.contents > 0 then busyCnt = busyCnt + 1 end
            end
            diag(string.format("其中 busy 且有内容: %d 个", busyCnt))
        end
 
        local craftingStatus = checkCraftingStatus(monitoringTargets, allCPUsContents)
        updateTrackingStatus(craftingStatus)
 
        -- 物品检查
        diag("--- 开始物品检查 ---")
        local missingItems = itemMonitor.checkItems(monitoringTargets.items)
        diag(string.format("checkItems 返回 %d 个 missing items", #missingItems))
        for _, mi in ipairs(missingItems) do
            diag(string.format("  missing: id=%s name=%s damage=%s current=%s buffer=%s needed=%s",
                mi.id, mi.name, tostring(mi.damage), tostring(mi.currentAmount),
                tostring(mi.buffer), tostring(mi.needed)))
        end
 
        if #missingItems > 0 then
            print("\n[物品检查]")
            for _, item in ipairs(missingItems) do
                local status = craftingStatus.items[item.id]
                if status and status.isCrafting then
                    print(string.format("- %s: 正在合成中 (%s/%s)",
                          item.displayName or "未知物品",
                          formatNumber(status.amount),
                          formatNumber(item.buffer)))
                    diag(string.format("  物品 %s: craftingStatus显示正在合成, 跳过下单", item.id))
                else
                    print(string.format("- %s: 需求=%s, 可合成=true",
                          item.displayName or "未知物品",
                          formatNumber(item.buffer)))
                    print(string.format("  下单: 缺少 %s 个 (单次合成: %s)",
                          formatNumber(item.needed),
                          formatNumber(item.singleCraft)))
                    diag(string.format("  物品 %s: 准备下单 needed=%s", item.id, tostring(item.needed)))
                    local crafted = itemMonitor.requestCrafting({item})
                    diag(string.format("  物品 %s: requestCrafting 返回 crafted=%s", item.id, tostring(crafted)))
                    if crafted > 0 then
                        craftingItems[item.id] = os.time()
                        diag(string.format("  物品 %s: 已记录 tracking, time=%s", item.id, tostring(os.time())))
                        saveCraftingTrack()
                    end
                end
            end
        else
            print("\n[状态] 所有物品库存充足")
        end
 
        -- 流体检查
        diag("--- 开始流体检查 ---")
        local missingFluids = fluidMonitor.checkFluids(monitoringTargets.fluids)
        diag(string.format("checkFluids 返回 %d 个 missing fluids", #missingFluids))
        for _, mf in ipairs(missingFluids) do
            diag(string.format("  missing: id=%s current=%s buffer=%s needed=%s",
                mf.id, tostring(mf.currentAmount), tostring(mf.buffer), tostring(mf.needed)))
        end
 
        if #missingFluids > 0 then
            print("\n[流体检查]")
            for _, fluid in ipairs(missingFluids) do
                local status = craftingStatus.fluids[fluid.id]
                if status and status.isCrafting then
                    print(string.format("- %s: 正在合成中 (%s/%s mB)",
                          fluid.displayName or "未知流体",
                          formatNumber(status.amount),
                          formatNumber(fluid.buffer)))
                    diag(string.format("  流体 %s: craftingStatus显示正在合成, 跳过下单", fluid.id))
                else
                    print(string.format("- %s: 需求=%s mB",
                          fluid.displayName or "未知流体",
                          formatNumber(fluid.buffer)))
                    print(string.format("  状态] %s 库存不足", fluid.displayName or "未知流体"))
                    print(string.format("  下单: 缺少 %s mB (单次合成: %s mB)",
                          formatNumber(fluid.needed),
                          formatNumber(fluid.singleCraft)))
                    diag(string.format("  流体 %s: 准备下单 needed=%s", fluid.id, tostring(fluid.needed)))
                    local crafted = fluidMonitor.requestFluidCrafting({fluid})
                    diag(string.format("  流体 %s: requestFluidCrafting 返回 crafted=%s", fluid.id, tostring(crafted)))
                    if crafted > 0 then
                        craftingFluids[fluid.id] = os.time()
                        diag(string.format("  流体 %s: 已记录 tracking, time=%s", fluid.id, tostring(os.time())))
                        saveCraftingTrack()
                    end
                end
            end
        else
            print("\n[状态] 所有流体库存充足")
        end
 
        diag(string.format("========== 周期 %d 结束 ==========", cycleNum))
        diagFlush()
 
        -- 检查按键退出
        print(string.format("\n下次检查将在 %d 秒后... (按 q 退出)", config.checkInterval))
        local deadline = computer.uptime() + config.checkInterval
        while computer.uptime() < deadline do
            local signalName, _, char = event.pull(0.5, "key_down")
            if signalName == "key_down" and (char == string.byte("q") or char == string.byte("Q")) then
                print("\n用户按 q 退出, 保存诊断日志到 " .. diagFile)
                diag("用户手动退出")
                diagFlush()
                return
            end
        end
    end
end
 
print("ME网络智能监控系统启动中...")
print("诊断日志将写入: " .. diagFile)
local ok, err = pcall(mainLoop)
if not ok then
    print("[严重错误] " .. tostring(err))
    diag("严重错误: " .. tostring(err))
    diagFlush()
    print("系统将在5秒后退出...")
    os.sleep(5)
end