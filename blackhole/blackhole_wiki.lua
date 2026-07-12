local component = require("component")
local computer = require("computer")
local sides = require("sides")
local event = require("event")
 
-- ================= 方向配置 =================
local rsSideSpcaeTime = sides.south -- 时空红石信号输出方向
local sourceSide = sides.north      -- 转运输入方向
local targetSide = sides.south      -- 转运输出方向
local seedSlot = 1                  -- 黑洞种子的槽位
local collapseSlot = 2              -- 黑洞坍缩器的槽位
 
 
local maxTime = 300                 -- 黑洞稳定时间过长，重启黑洞的时间
-- ============================================
 
local machineList = {}
for address,_ in component.list("gt_machine") do
    if component.invoke(address, "getName") == "multimachine.blackholecompressor" then
        table.insert(machineList, address)
    end
end
 
local me_controller = component.me_controller
local redstone = component.redstone
local transposer = component.transposer
 
local time1, time2, maxProgress, timerID = 0, 0, 0, nil
local status, empty = "[空闲]", function() return "" end
local getInfo = empty
local gpu = component.gpu
gpu.setViewport(32, 10)
gpu.setForeground(0x00FF00)
local gpuTimerID = event.timer(0.5, function()
    local line = string.format("状态：%s", status)
    gpu.set(1, 2, line .. string.rep(" ", math.max(0, 32 - #line)))
    line = getInfo()
    gpu.set(1, 3, line .. string.rep(" ", math.max(0, 32 - #line)))
end, math.huge)
gpu.set(1, 1, "黑洞数量："..tostring(#machineList).."                     ")
for i=2,10 do
    gpu.set(1, i, string.rep(" ", 32))
end
 
local function setWorkAllowed(work)
    for _, address in ipairs(machineList) do
        component.invoke(address, "setWorkAllowed", work)
    end
end
 
local function getAnyProgress()
    for _, address in ipairs(machineList) do
        if component.invoke(address, "getWorkProgress") ~= 0 then
            return true
        end
    end
    return false
end
 
local function turnOff()
    for _, address in ipairs(machineList) do
        local progress = component.invoke(address, "getWorkMaxProgress") - component.invoke(address, "getWorkProgress")
        if progress > maxProgress then
            maxProgress = progress
        end
    end
    time2 = computer.uptime()
    transposer.transferItem(sourceSide, targetSide, #machineList, collapseSlot, 2) -- 先投入坍缩器，配方结束时自动关闭黑洞
    getInfo = function() return "等待配方结束 ("..tostring(math.floor(computer.uptime() - time2)).."/"..tostring(math.ceil(maxProgress/20))..")" end
    while getAnyProgress() do
        os.sleep(1)
    end
    getInfo = empty
    setWorkAllowed(false)
    if timerID then
        event.cancel(timerID)
        timerID = nil
    end
    redstone.setOutput(rsSideSpcaeTime, 0)
end
 
local function main()
    setWorkAllowed(false)
    redstone.setOutput(rsSideSpcaeTime, 0)
    while true do
        os.sleep(3)
        ::redo::
        if transposer.getSlotStackSize(sourceSide,seedSlot)<#machineList or transposer.getSlotStackSize(sourceSide,collapseSlot)<#machineList then
            status = "[错误]"
            getInfo = function() return "黑洞种子 或 黑洞坍缩器 数量不足" end
            while true do
                os.sleep(5)
                if transposer.getSlotStackSize(sourceSide,seedSlot)>=#machineList and transposer.getSlotStackSize(sourceSide,collapseSlot)>=#machineList then
                    status = "[空闲]"
                    getInfo = empty
                    break
                end
            end
        end
        if me_controller.getItemsInNetwork()[1] ~= nil or me_controller.getFluidsInNetwork()[1] ~= nil then
            transposer.transferItem(sourceSide, targetSide, #machineList, seedSlot, 2)
            setWorkAllowed(true)
            status = "[运行中]"
            time1 = computer.uptime()
            getInfo = function() return "等待稳定度下降 ("..tostring(math.floor(computer.uptime() - time1)).."/90)" end
            timerID = event.timer(90, function()
                redstone.setOutput(rsSideSpcaeTime, 15)
                timerID = nil
            end)
            while timerID do
                os.sleep(1)
                if me_controller.getItemsInNetwork()[1] == nil and me_controller.getFluidsInNetwork()[1] == nil then
                    status = "[关闭中]"
                    turnOff() -- 使用timer，确保等待最后一轮配方期间，在稳定度降到10时仍能开启时空输入
                    status = "[空闲]"
                    goto redo
                end
            end
            time1 = computer.uptime()
            getInfo = function() return "正在运行 ("..tostring(math.floor(computer.uptime() - time1)).."/"..tostring(maxTime)..")" end
            while me_controller.getItemsInNetwork()[1] ~= nil or me_controller.getFluidsInNetwork()[1] ~= nil do
                if computer.uptime() >= time1 + maxTime then
                    status = "[重启中]"
                    turnOff()
                    goto redo
                end
                os.sleep(1)
            end
            status = "[关闭中]"
            turnOff()
            status = "[空闲]"
        end
    end
end
 
local _, err = pcall(main)
event.cancel(gpuTimerID) 
setWorkAllowed(false)
while getAnyProgress() do
    os.sleep(0.5)
end
redstone.setOutput(rsSideSpcaeTime, 0)
gpu.setForeground(0xFFFFFF)
gpu.setViewport(gpu.getResolution())
error(err)