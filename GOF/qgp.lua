local os = require("os")
local event = require("event")
local component = require("component")
local sides = require("sides")
 
local trans = component.transposer
local sideCacheBuffer = sides.north     -- 转运器对应的 大型原料缓存仓
local sideAEInfusion = sides.west       -- 转运器对应的 ae的物质聚合器
local sideInterface = sides.down        -- 转运器对应的 主网也是唯一的ae接口 用于设置流体的输出
local database = component.database
local mei = component.me_interface
local gtm = component.gt_machine        -- 太阳聚变异化器，用于检测配方是否开始执行

local running = true
local function onInterrupted()
    running = false
end
event.listen("interrupted", onInterrupted)
 
local cacheCount = 1
local cacheTable = {}
local cacheNames = {}  -- 保存原始材料名，用于打印对照
local savedCacheTable = {}  -- 保存当前配方需求量副本，用于 R 键重新输入
 
local fcFluidDrop = "ae2fc:fluid_drop"
local bartMaterial = {
    [3]="zirconium",
    [30]="thorium232",
    [64]="ruthenium",
    [78]="rhodium",
    [11000]="hafnium",
    [11012]="iodine"}  -- bart材料对应的等离子 分别是 锆 钍-232 钌 铑 铪 碘
 
function setAE2FCPlasma(materialName)    
    database.set( cacheCount, fcFluidDrop, 0, "{Fluid:plasma." .. materialName .. "}")
    cacheCount = cacheCount + 1
end
 
function setDatabase()
    for i=1,7 do        -- 先遍历获取 流体对应的等离子 并将其存储在数据库
        local fluid = trans.getFluidInTank(sideCacheBuffer,i)
        if not fluid or fluid.amount == 0 then break end       -- 流体检测完毕 直接提前跳出循环
        -- 跳过残留的等离子体（名称以 plasma. 开头），避免双重 plasma. 前缀导致下单失败
        if fluid.name:match("^plasma%.") then
            print("[WARN] 检测到残留等离子体: " .. fluid.name .. "，已移入聚合器")
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)
            goto ContinueFluid
        end
        cacheTable[cacheCount] = fluid.amount * 1000
        cacheNames[cacheCount] = "流体:" .. (fluid.label or fluid.name)
        setAE2FCPlasma(fluid.name)          -- 把等离子对应的 ae2fc液滴 写入数据库
        ::ContinueFluid::
    end
 
    for i=1,7 do
        if cacheCount == 8 then break end   -- 已经获取完毕 7种等离子 重置缓存同时跳出循环
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item == nil then goto ContinueEnd end
        cacheTable[cacheCount] = item.size * 1296    -- 设置数量
        cacheNames[cacheCount] = "物品:" .. (item.label or item.name)
        local materialName
        if item.name == "bartworks:gt.bwMetaGenerateddust" then     -- 特殊处理bart的材料系统生成的粉对应的GT++等离子
            materialName = bartMaterial[item.damage]
        elseif item.name:match("miscutils:itemDust*") ~= nil then   -- 对于GT++的材料进行处理 直接生成对应的液滴
            materialName = string.lower(string.match(item.name, "miscutils:itemDust" .. "(%w+)$"))
        elseif item.name == "gregtech:gt.metaitem.01" then              -- 对于GT材料系统生成的材料使用对应的的等离子单元进行标记
                                                                        -- 有对应的特征 粉的metaID + 29000 对应的物品就是等离子单元
            if item.damage == 382 then
                materialName = "ardite"        -- 由于阿迪特等离子单元比较特殊 故 需要特殊处理
            else
                database.set(cacheCount, "gregtech:gt.metaitem.01", 29000 + item.damage, "")
                cacheCount = cacheCount + 1
            end
        end
        if materialName ~= nil then setAE2FCPlasma(materialName) end
        ::ContinueEnd::
    end
 
end
 
function clearCacheBuffer()
 
    local counter = 1
 
    for i=1,7 do        -- 先清除材料缓存器中的流体 之后用于存储需要精确输入的原料
        local fluid = trans.getFluidInTank(sideCacheBuffer, i)
        if not fluid or fluid.amount == 0 then break end     -- 已经没有流体了 就退出循环
        trans.transferFluid(sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)     -- 不考虑是否正确是输出流体 因为没必要
        counter = counter + 1
    end
 
    for i=1,7 do
        if counter == 8 then break end          -- 已经没有物品了 退出循环
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        trans.transferItem(sideCacheBuffer, sideAEInfusion, item.size, i)
        counter = counter + 1
    end
 
end
 
function requestItem(item)
 
    if item.name == "gregtech:gt.metaitem.01" then  -- 对于单元类的物品 需要下单的是液滴 需要转换一下
        database.set( 10, fcFluidDrop, 0, "{Fluid:" .. item.fluid.name .. "}")      -- 在数据库10号位置设置缓存 下单液体对应液滴
        item = database.get(10)
    end
 
    local tet = true
    local cacheN = 0        -- 用于检测下单失败的次数 同时作为用于 取消订单 的阈值
    ::retryRequest::
    local craftable = mei.getCraftables({name=item.name, label=item.label})[1]
 
    if trans.getFluidInTank(sideInterface, 1).amount >= 16000 then return end     -- 实测由于ae延迟什么的 导致的在这死循环问题
 
    if not craftable then   -- 等待玩家检查样板
        if tet then
            tet = false
            print("[WARN] 未找到可合成样板: ".. item.label .. "，等待检查...") 
        end
        os.sleep(5)
        goto retryRequest
    end
 
    local result = craftable.request(1, true)      -- 没有问题就执行下单
    tet = true
    print("[OK] 已下单: " .. item.label)
    os.sleep(2)
 
    if result.hasFailed() or result.isCanceled() then
        print("[WARN] 下单失败，5s 后重试...")
        cacheN = cacheN + 1
        if cacheN >= 12 then
            os.sleep(20)
            if cacheN > 15 then 
                print("[ERROR] 连续下单失败，请手动维护！")
                while true do os.sleep(5) end
            end
            local cpus = mei.getCpus()
            for i=1,#cpus do     -- 下单失败次数过多 ae那边可能出问题了 先尝试取消订单
                local out = cpus[i].cpu.finalOutput()
                if out == nil then break end
                if out.name == item.name and out.label == item.label then
                    cpus[i].cpu.cancel()
                end
            end
        end
        os.sleep(5)
        goto retryRequest
    end
 
    while not result.isDone() do
        os.sleep(2)
    end
end
 
function processFluid()
    for i=1,7 do       -- 处理 ae相关流体的发配
        mei.setFluidInterfaceConfiguration(0, database.address, i)
        os.sleep(0.15)      -- 需要一个缓冲的时间 用于ae补充标记的流体
        ::retryIfEmpty::
        if trans.getFluidInTank(sideInterface, 1).amount == 0 then       -- 流体不足 需要下单
            requestItem(database.get(i))
            if trans.getFluidInTank(sideInterface, 1).amount == 0 then  -- 防止一些问题 同时打印问题
                print("[WARN] 获取流体失败，重试中...")
                goto retryIfEmpty
            end    
        end
        local needed = cacheTable[i]
        while cacheTable[i] > 0 do     -- 消耗流体
            if trans.getFluidInTank(sideInterface, 1).amount == 0 then goto retryIfEmpty end
            local _, moved = trans.transferFluid(sideInterface, sideCacheBuffer, cacheTable[i], 0)
            moved = tonumber(moved) or 0
            if moved == 0 then os.sleep(0.5) end  -- 防止转运失败死循环
            cacheTable[i] = cacheTable[i] - moved
            os.sleep(0.35)
        end
        print(string.format("[OK] %d/%d 已输入: %s  x %d mB", i, #cacheTable, database.get(i).label, needed - cacheTable[i]))
    end
    mei.setFluidInterfaceConfiguration(0)       -- 将接口的流体设置为空
end
 
-- 清理缓存仓中残留的等离子体，防止下一轮原料堵塞
-- 使用 pcall 防止 transposer 调用异常导致程序卡死
function clearResidualPlasma()
    for i = 1, 7 do
        if not running then return end
        local ok, fluid = pcall(function()
            return trans.getFluidInTank(sideCacheBuffer, i)
        end)
        if not ok or not fluid then goto continue end
        if fluid.amount > 0 and fluid.name and fluid.name:match("^plasma%.") then
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)
            print("[INFO] 清理残留等离子体: " .. fluid.name .. " " .. fluid.amount .. " mB")
        end
        ::continue::
    end
end
 
-- 等待机器开始处理：3次自动重试（各5s），仍失败则进入手动等待
function waitForMachineAndClearPlasma()
    local maxRetries = 3
    local waitPerRetry = 5

    ::retryAll::
    for retry = 0, maxRetries do
        if retry > 0 then
            print(string.format("[INFO] 自动重试 %d/%d：清除残留并重新输入...", retry, maxRetries))
            clearResidualPlasma()
            for i = 1, #cacheTable do
                cacheTable[i] = savedCacheTable[i]
            end
            processFluid()
        end

        print(string.format("[INFO] 等待机器开始处理（第%d次）...", retry + 1))
        local timeout = 0
        while running do
            local ok, progress = pcall(function() return gtm.getWorkProgress() end)
            if ok and progress > 0 then
                print("[OK] 机器已开始处理，清理残留等离子体...")
                clearResidualPlasma()
                return
            end
            os.sleep(0.5)
            timeout = timeout + 0.5
            if timeout >= waitPerRetry then break end
        end
        if not running then return end
    end

    -- 3 次自动重试后进入手动等待
    print("[WARN] 3次自动重试后机器仍未处理")
    print("[WARN] [空格] 进入下一轮  [R] 重新输入当前等离子")
    clearResidualPlasma()
    while running do
        local _, _, char = event.pull("key_down")
        if char == 32 then  -- 空格：下一轮
            print("[INFO] 收到确认，开始新一轮...")
            return
        elseif char == 114 or char == 82 then  -- R：重新输入并重新计时
            print("[INFO] 重新输入当前等离子...")
            for i = 1, #cacheTable do
                cacheTable[i] = savedCacheTable[i]
            end
            processFluid()
            goto retryAll
        end
    end
end
 
function printFluidInfo()
    for i=1,#cacheTable do
        print(string.format("  %-30s =>  %-40s x %d mB",
            cacheNames[i],
            database.get(i).label,
            cacheTable[i]))
    end
end
 
function main()
 
    print("========================================")
    print("    QGP 自动化程序启动")
    print("========================================")
    print("[INFO] 启动清理：清除缓存仓残留等离子体...")
    clearResidualPlasma()
 
    local idlePrinted = false

    while running do
        cacheCount = 1
        cacheTable = {}
        cacheNames = {}

        local fluid = trans.getFluidInTank(sideCacheBuffer, 1)
        local item = trans.getStackInSlot(sideCacheBuffer, 1)

        -- 检测是否有新原料：流体槽或物品槽有内容（排除残留等离子体）
        local hasFluid = fluid and fluid.amount > 0 and fluid.amount <= 64 and not fluid.name:match("^plasma%.")
        local hasItem = item ~= nil

        if hasFluid or hasItem then
            idlePrinted = false
            print("")
            print("========================================")
            print("[INFO] 检测到新一批原料，正在初始化数据库...")
            setDatabase()

            local shouldProcess = true
            if #cacheTable ~= 7 then
                shouldProcess = false
            else
                for i=1,#cacheTable do
                    if cacheTable[i] == nil then
                        shouldProcess = false
                        break
                    end
                end
            end

            if shouldProcess then
                print("[INFO] 开始等离子体处理...")
                printFluidInfo()
                clearCacheBuffer()
                -- 保存需求量副本，用于 R 键重新输入
                for i = 1, #cacheTable do
                    savedCacheTable[i] = cacheTable[i]
                end
                processFluid()
                waitForMachineAndClearPlasma()
            end

        else
            if not idlePrinted then
                print("[INFO] 缓存仓空闲，等待新原料...")
                idlePrinted = true
            end
        end

        os.sleep(5)

    end

    event.ignore("interrupted", onInterrupted)
    print("[OK] 程序已安全退出")
end

main()