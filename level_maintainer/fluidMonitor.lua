local database = require("database")
local FLUID_DROP_ID = "ae2fc:fluid_drop"
local MAX_INT = 2147483647
 
local function getFluidAmount(fluidID)
    local me = database.me()
    local success, fluids = pcall(function() return me.getFluidsInNetwork() end)
    if not success then return 0 end
    fluids = fluids or {}
    for _, fluid in ipairs(fluids) do
        if fluid and fluid.name == fluidID then return fluid.amount or 0 end
    end
    return 0
end
 
local function findFluidCraftable(fluidID)
    local me = database.me()
    local success, craftables = pcall(function() return me.getCraftables({name = FLUID_DROP_ID}) end)
    if not success then return nil end
    craftables = craftables or {}
    for _, craftable in ipairs(craftables) do
        if craftable then
            local success, itemStack = pcall(function() return craftable.getItemStack() end)
            if success and itemStack and itemStack.fluidDrop and itemStack.fluidDrop.name == fluidID then return craftable end
        end
    end
 
    local success2, fluidCraftables = pcall(function() return me.getCraftables({name = fluidID}) end)
    if success2 and fluidCraftables and #fluidCraftables > 0 then return fluidCraftables[1] end
    return nil
end
 
local function batchCheckFluidsCrafting(fluidIDs)
    local craftingStatus = {}
    for _, fluidID in ipairs(fluidIDs) do craftingStatus[fluidID] = {isCrafting = false, amount = 0} end
 
    local allCPUsContents = database.getAllCPUCraftingContents()
    for _, cpuData in ipairs(allCPUsContents) do
        if cpuData.isBusy then
            for _, content in ipairs(cpuData.contents) do
                if content.type == "fluid" then
                    for fluidID, status in pairs(craftingStatus) do
                        if content.name == fluidID then
                            status.isCrafting = true
                            status.amount = math.max(status.amount, content.amount)
                        end
                    end
                end
            end
        end
    end
 
    return craftingStatus
end
 
local function checkFluids(fluidsConfig)
    local missingFluids = {}
    local me = database.me()
    if not me then return missingFluids end
 
    local fluidIDs = {}
    for _, fluid in ipairs(fluidsConfig) do table.insert(fluidIDs, fluid.id) end
 
    local craftingStatus = batchCheckFluidsCrafting(fluidIDs)
 
    for _, fluid in ipairs(fluidsConfig) do
        if craftingStatus[fluid.id].isCrafting then goto continue end
 
        local currentAmount = getFluidAmount(fluid.id) or 0
        if currentAmount < (fluid.buffer or 0) then
            local craftable = findFluidCraftable(fluid.id)
            if not craftable then goto continue end
 
            local needed = fluid.craftAmount or 1
 
            table.insert(missingFluids, {
                id = fluid.id,
                displayName = fluid.displayName,
                needed = needed,
                singleCraft = fluid.craftAmount or 1,
                craftable = craftable,
                currentAmount = currentAmount,
                buffer = fluid.buffer or 0
            })
        end
        ::continue::
    end
 
    return missingFluids
end
 
local function requestFluidCrafting(missingFluids)
    local craftedCount = 0
    for _, fluid in ipairs(missingFluids) do
        local requestAmount = fluid.needed
 
        if requestAmount > MAX_INT then
            local numRequests = math.ceil(requestAmount / MAX_INT)
            local remainingAmount = requestAmount
 
            print(string.format("  [大数值] %s: 需要拆分 %s mB 为 %d 次合成",
                  fluid.displayName,
                  requestAmount,
                  numRequests))
 
            for i = 1, numRequests do
                local chunkAmount = math.min(remainingAmount, MAX_INT)
                local ok, result = pcall(function() return fluid.craftable.request(chunkAmount) end)
                if ok and result then
                    craftedCount = craftedCount + 1
                    remainingAmount = remainingAmount - chunkAmount
                    local isCompOk, isComp = pcall(function() return result.isComputing() end)
                    local isDoneOk, isDone = pcall(function() return result.isDone() end)
                    local hasFailOk, hasFail = pcall(function() return result.hasFailed() end)
                    print(string.format("  [下单-%d] %s: 合成 %s mB (剩余 %s mB) job:computing=%s done=%s failed=%s",
                          i, fluid.displayName, chunkAmount, remainingAmount,
                          isCompOk and tostring(isComp) or "?",
                          isDoneOk and tostring(isDone) or "?",
                          hasFailOk and tostring(hasFail) or "?"))
                elseif ok then
                    print(string.format("  [警告] %s: request() 返回 nil, 下单可能无效", fluid.displayName))
                else
                    print(string.format("  [错误] %s: 第%d次合成请求失败: %s", fluid.displayName, i, tostring(result)))
                    break
                end
            end
        else
            local ok, result = pcall(function() return fluid.craftable.request(requestAmount) end)
            if ok and result then
                craftedCount = craftedCount + 1
                local isCompOk, isComp = pcall(function() return result.isComputing() end)
                local isDoneOk, isDone = pcall(function() return result.isDone() end)
                local hasFailOk, hasFail = pcall(function() return result.hasFailed() end)
                print(string.format("  [下单] %s: 当前=%s mB, 需求=%s mB, 合成=%s mB job:computing=%s done=%s failed=%s",
                      fluid.displayName,
                      fluid.currentAmount,
                      fluid.buffer,
                      requestAmount,
                      isCompOk and tostring(isComp) or "?",
                      isDoneOk and tostring(isDone) or "?",
                      hasFailOk and tostring(hasFail) or "?"))
            elseif ok then
                print(string.format("  [警告] %s: request() 返回 nil, 下单可能无效", fluid.displayName))
            else
                print(string.format("  [错误] %s: 合成请求失败: %s", fluid.displayName, tostring(result)))
            end
        end
    end
    return craftedCount
end
 
return {checkFluids = checkFluids, requestFluidCrafting = requestFluidCrafting}