local database = require("database")
local MAX_INT = 2147483647
 
local function batchCheckItemsCrafting(itemsConfig)
    local craftingStatus = {}
    for _, item in ipairs(itemsConfig) do craftingStatus[item.id] = {isCrafting = false, amount = 0} end
 
    local allCPUsContents = database.getAllCPUCraftingContents()
    for _, cpuData in ipairs(allCPUsContents) do
        if cpuData.isBusy then
            for _, content in ipairs(cpuData.contents) do
                if content.type == "item" then
                    for _, item in ipairs(itemsConfig) do
                        if content.name == item.name and content.damage == (item.damage or 0) then
                            craftingStatus[item.id].isCrafting = true
                            craftingStatus[item.id].amount = math.max(craftingStatus[item.id].amount, content.amount)
                        end
                    end
                end
            end
        end
    end
 
    return craftingStatus
end
 
local function checkItems(itemsConfig)
    local missingItems = {}
    local me = database.me()
    if not me then return missingItems end
 
    local craftingStatus = batchCheckItemsCrafting(itemsConfig)
 
    for _, item in ipairs(itemsConfig) do
        if craftingStatus[item.id].isCrafting then goto continue end
 
        local filter = {name = item.name}
        if item.damage and item.damage > 0 then filter.damage = item.damage end
 
        local success, items = pcall(function() return me.getItemsInNetwork(filter) end)
        if not success then goto continue end
 
        items = items or {}
        local currentAmount = 0
        local isCraftable = false
 
        for _, itemStack in ipairs(items) do
            if itemStack and itemStack.name == item.name then
                local stackDamage = itemStack.damage or 0
                local targetDamage = item.damage or 0
                if stackDamage == targetDamage then
                    currentAmount = currentAmount + (itemStack.size or 0)
                    if itemStack.isCraftable then isCraftable = true end
                end
            end
        end
 
        if currentAmount < (item.buffer or 0) then
            if not isCraftable then goto continue end
 
            local needed = item.craftAmount or 1
 
            table.insert(missingItems, {
                id = item.id,
                name = item.name,
                damage = item.damage or 0,
                displayName = item.displayName,
                needed = needed,
                singleCraft = item.craftAmount or 1,
                filter = filter,
                currentAmount = currentAmount,
                buffer = item.buffer or 0
            })
        end
        ::continue::
    end
 
    return missingItems
end
 
local function requestCrafting(missingItems)
    local craftedCount = 0
    local me = database.me()
 
    for _, item in ipairs(missingItems) do
        local success, craftables = pcall(function() return me.getCraftables(item.filter) end)
        if not success or #craftables == 0 then goto continue end
 
        local craftable = craftables[1]
        local requestAmount = item.needed
 
        -- 处理大数值合成请求
        if requestAmount > MAX_INT then
            -- 计算需要拆分成多少次请求
            local numRequests = math.ceil(requestAmount / MAX_INT)
            local remainingAmount = requestAmount
 
            print(string.format("  [大数值] %s: 需要拆分 %s 为 %d 次合成",
                  item.displayName,
                  requestAmount,
                  numRequests))
 
            for i = 1, numRequests do
                local chunkAmount = math.min(remainingAmount, MAX_INT)
                local ok, result = pcall(function() return craftable.request(chunkAmount) end)
                if ok and result then
                    craftedCount = craftedCount + 1
                    remainingAmount = remainingAmount - chunkAmount
                    local isCompOk, isComp = pcall(function() return result.isComputing() end)
                    print(string.format("  [下单-%d] %s: 合成 %s 个 (剩余 %s) job:computing=%s",
                          i, item.displayName, chunkAmount, remainingAmount,
                          isCompOk and tostring(isComp) or "?"))
                elseif ok then
                    print(string.format("  [警告] %s: request() 返回 nil, 下单可能无效", item.displayName))
                else
                    print(string.format("  [错误] %s: 第%d次合成请求失败: %s", item.displayName, i, tostring(result)))
                    break
                end
            end
        else
            -- 正常大小的请求
            local ok, result = pcall(function() return craftable.request(requestAmount) end)
            if ok and result then
                craftedCount = craftedCount + 1
                local isCompOk, isComp = pcall(function() return result.isComputing() end)
                print(string.format("  [下单] %s: 当前=%s, 需求=%s, 合成=%s个 job:computing=%s",
                      item.displayName,
                      item.currentAmount,
                      item.buffer,
                      requestAmount,
                      isCompOk and tostring(isComp) or "?"))
            elseif ok then
                print(string.format("  [警告] %s: request() 返回 nil, 下单可能无效", item.displayName))
            else
                print(string.format("  [错误] %s: 合成请求失败: %s", item.displayName, tostring(result)))
            end
        end
        ::continue::
    end
 
    return craftedCount
end
 
return {checkItems = checkItems, requestCrafting = requestCrafting}