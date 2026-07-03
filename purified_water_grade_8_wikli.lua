local os = require("os")
local component = require("component")
local sides = require("sides")
 
local gtm = component.gt_machine
local trans = component.transposer
 
local sideInput = sides.north --Me接口的方向
local sideOutput = sides.down --输入总线的方向
 
local index = 1
local inputTable = { 1, 2, 3, 4, 5, 6, 2, 4, 6, 1, 3, 5, 1, 4, 6, 3, 2, 5 }
 
local function main()
    os.execute("cls")
 
    print("正在运行中...")
    while true do
        os.sleep(5)
        if index == 19 then index = 1 end
 
        local info = gtm.getSensorInformation()
        if gtm.getWorkProgress() > 1 and info[2] ~= nil then
            if tonumber(string.match(info[2], "%d+")) ~= 100 then   -- 读取机器当前成功率
                trans.transferItem(sideInput, sideOutput, 1, inputTable[index])
                index = index + 1
            end
        end
    end
end
 
main()