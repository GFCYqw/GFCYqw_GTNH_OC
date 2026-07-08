local os = require("os")
local component = require("component")
local sides = require("sides")
local event = require("event")          -- 用于捕获 Ctrl+C 中断
local computer = require("computer")    -- 用于获取运行时间

local gtm = component.gt_machine
local trans = component.transposer

local sideInput = sides.north   -- ME接口的方向
local sideOutput = sides.down   -- 输入总线的方向

local index = 1
local inputTable = { 1, 2, 3, 4, 5, 6, 2, 4, 6, 1, 3, 5, 1, 4, 6, 3, 2, 5 }

local startTime = computer.uptime()     -- 记录程序启动时间

local function formatTime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function main()
    os.execute("cls")

    print("正在运行中... 按 Ctrl+C 可安全退出")
    print("")

    while true do
        -- 等待 5 秒，同时监听中断事件
        local evt = event.pull(5)

        -- 捕获 Ctrl+C 信号
        if evt == "interrupted" then
            os.execute("cls")
            print("程序已被用户中断，正在退出...")
            break
        end

        -- 重置 index（原有逻辑）
        if index == 19 then
            index = 1
        end

        local info = gtm.getSensorInformation()

        -- 提取当前成功率（原有逻辑）
        local successRate = "N/A"
        if info[2] ~= nil then
            local rateStr = string.match(info[2], "%d+")
            if rateStr then
                successRate = rateStr .. "%"
            end
        end

        -- 计算运行时间
        local elapsed = computer.uptime() - startTime
        local timeStr = formatTime(elapsed)

        -- 刷新屏幕显示
        os.execute("cls")
        print("========================================")
        print("  绝对重子完美净化单元 - 自动化控制")
        print("========================================")
        print("  运行时间   : " .. timeStr)
        print("  当前成功率 : " .. successRate)
        print("  当前步骤   : " .. index .. " / 18")
        print("========================================")
        print("")

        -- 原有核心逻辑：当机器工作进度 > 1 且成功率不为 100% 时，转移物品
        if gtm.getWorkProgress() > 1 and info[2] ~= nil then
            if tonumber(string.match(info[2], "%d+")) ~= 100 then
                trans.transferItem(sideInput, sideOutput, 1, inputTable[index])
                index = index + 1
            end
        end
    end
end

main()