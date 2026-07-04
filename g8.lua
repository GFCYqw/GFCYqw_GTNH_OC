local os = require("os")
local component = require("component")
local sides = require("sides")
local term = require("term")

local gtm = component.gt_machine
local trans = component.transposer

local sideInput = sides.north  -- ME接口的方向
local sideOutput = sides.down  -- 输入总线的方向

local index = 1
-- 六种夸克的最短遍历序列（共18步），覆盖所有15种无序组合[reference:4]
local inputTable = { 1, 2, 3, 4, 5, 6, 2, 4, 6, 1, 3, 5, 1, 4, 6, 3, 2, 5 }

-- 记录上次成功率，初始设为-1表示未知
local lastSuccessRate = -1
-- 记录程序启动时间
local startTime = os.time()

local function main()
    os.execute("cls")

    while true do
        -- 清屏并重置光标到左上角，实现顶部信息实时刷新
        term.clear()
        term.setCursor(1, 1)

        -- 计算并显示运行时间
        local elapsed = os.time() - startTime
        local hours = math.floor(elapsed / 3600)
        local minutes = math.floor((elapsed % 3600) / 60)
        local seconds = elapsed % 60
        local timeStr = string.format("%02d:%02d:%02d", hours, minutes, seconds)

        -- 获取机器传感器信息
        local info = gtm.getSensorInformation()
        -- info[2] 通常包含成功率信息[reference:5]
        local currentRate = -1
        if info[2] ~= nil then
            currentRate = tonumber(string.match(info[2], "%d+")) or -1
        end

        -- 更新上次成功率（仅在有效时）
        if currentRate >= 0 then
            lastSuccessRate = currentRate
        end

        -- 在界面顶端显示状态信息
        print("=== 绝对重子完美净化单元 监控 ===")
        print(string.format("运行时间: %s", timeStr))
        if lastSuccessRate >= 0 then
            print(string.format("上次成功率: %d%%", lastSuccessRate))
        else
            print("上次成功率: 未知")
        end
        print("当前步骤: " .. index .. "/18")
        print("-----------------------------------")
        print("正在运行中...")

        -- 核心逻辑：当机器工作中且成功率不为100%时，输入下一个催化剂
        if gtm.getWorkProgress() > 1 and currentRate >= 0 and currentRate ~= 100 then
            trans.transferItem(sideInput, sideOutput, 1, inputTable[index])
            index = index + 1
            if index == 19 then
                index = 1  -- 序列循环
            end
        end

        os.sleep(5)
    end
end

main()