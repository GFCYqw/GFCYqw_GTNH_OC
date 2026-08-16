local component = require("component")
local event = require("event")
 
local me = nil
local craftingCPUs = {}
local levelMaintainers = {}
 
local function initComponents()
    me = component.me_interface
    if not me then error("未找到ME接口") end
 
    levelMaintainers = {}
    for address, name in component.list("level_maintainer") do
        local maintainer = component.proxy(address)
        table.insert(levelMaintainers, maintainer)
    end
 
    craftingCPUs = {}
    for _, cpu in ipairs(me.getCpus() or {}) do
        if cpu.coprocessors and cpu.coprocessors > 0 then
            table.insert(craftingCPUs, cpu)
        end
    end
 
    if #craftingCPUs == 0 then error("未找到有效合成CPU") end
end
 
local function getMonitoringTargets()
    local targets = {items = {}, fluids = {}}
    local processedCount = 0
 
    for _, maintainer in ipairs(levelMaintainers) do
        for slot = 1, 5 do
            local success, slotData = pcall(function()
                return maintainer.getSlot(slot)
            end)
 
            if success and slotData then
                if slotData.isEnable then
                    local target = {
                        id = slotData.name,
                        displayName = slotData.label or slotData.name,
                        buffer = slotData.quantity or 0,
                        craftAmount = slotData.batch or 1,
                        isFluid = slotData.isFluid or false
                    }
 
                    if target.isFluid then
                        target.id = slotData.fluid and slotData.fluid.name or slotData.name
                        table.insert(targets.fluids, target)
                        processedCount = processedCount + 1
                    else
                        target.damage = slotData.damage or 0
                        local nameFromID, damageFromID = target.id:match("^(.+):(%d+)$")
                        if nameFromID and damageFromID then
                            target.name = nameFromID
                            target.damage = tonumber(damageFromID)
                        else
                            target.name = target.id
                        end
                        if slotData.damage and slotData.damage > 0 then
                            target.damage = slotData.damage
                        end
                        target.id = target.name .. ":" .. target.damage
                        table.insert(targets.items, target)
                        processedCount = processedCount + 1
                    end
                end
            else
                if not success then
                    print(string.format("[警告] 获取缓存器槽位 %d 数据失败: %s", slot, tostring(slotData)))
                end
            end
        end
    end
 
    print(string.format("[缓存器] 已处理 %d 个监控目标 (%d 物品, %d 流体)",
          processedCount, #targets.items, #targets.fluids))
 
    return targets
end
 
local function getAllCPUCraftingContents()
    local allContents = {}
    local cpus = {}
    if me then
        for _, cpu in ipairs(me.getCpus() or {}) do
            if cpu.coprocessors and cpu.coprocessors > 0 then
                table.insert(cpus, cpu)
            end
        end
    end
 
    for idx, cpuInfo in ipairs(cpus) do
        local cpu = cpuInfo.cpu
        if cpu then
            local isBusy = cpuInfo.busy or false
            local cpuContents = {
                cpuIndex = idx,
                cpuName = cpuInfo.name or "未知CPU",
                coprocessors = cpuInfo.coprocessors or 0,
                contents = {},
                isBusy = isBusy,
                totalItems = 0,
                realItems = 0,
                _cpu = cpu
            }
 
            if isBusy then
                local outputSuccess, output = pcall(function() return cpu.finalOutput() end)
                if outputSuccess and output and output.size and output.size > 0 then
                    cpuContents.totalItems = 1
                    cpuContents.realItems = 1
 
                    local outputType = output.fluidDrop and "fluid" or "item"
                    local outputName = output.fluidDrop and output.fluidDrop.name or output.name
                    local outputDamage = output.damage or 0
 
                    local contentData = {
                        type = outputType,
                        name = outputName,
                        damage = outputDamage,
                        amount = output.size or 0,
                        source = "finalOutput",
                        rawData = output
                    }
 
                    table.insert(cpuContents.contents, contentData)
                end
            end
 
            table.insert(allContents, cpuContents)
        end
    end
 
    return allContents
end
 
local cpuContentsCache = nil
 
return {
    initComponents = initComponents,
    me = function() return me end,
    craftingCPUs = function() return craftingCPUs end,
    levelMaintainers = function() return levelMaintainers end,
    getMonitoringTargets = getMonitoringTargets,
    getAllCPUCraftingContents = function()
        if cpuContentsCache then
            return cpuContentsCache
        end
        cpuContentsCache = getAllCPUCraftingContents()
        return cpuContentsCache
    end,
    refreshCPUCache = function()
        cpuContentsCache = getAllCPUCraftingContents()
        return cpuContentsCache
    end
}