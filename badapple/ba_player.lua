--------------------------------------------------------------------------------
--  Bad Apple - 全息投影仪播放器 (Tier 2)
--  ======================================
--  读取预处理后的 .bin 文件, 在 XY 平面 (Z=24) 上逐帧渲染全息动画。
--
--  用法:
--      将 ba_frames.bin 放在与本脚本相同的目录下, 然后运行:
--          ba_player
--      或指定文件路径:
--          ba_player /path/to/ba_frames.bin
--
--  依赖:
--      - Tier 2 全息投影仪 (component.hologram)
--      - 预处理后的 ba_frames.bin 文件
--
--  文件格式:
--      文件头 (11B): magic(4B) + version(1B) + frames(4B LE) + fps(1B) + reserved(1B)
--      偏移表 (frames×4B): 每帧数据偏移量 (uint32 LE)
--      帧数据: [长度 uint16 LE] [RLE 字节...]
--      RLE: 每字节 = (value << 6) | (count - 1), value=0-3, count=1-64
--------------------------------------------------------------------------------

local VERSION = "1.4"

local component = require("component")
local computer = require("computer")
local event = require("event")

-- 安全获取 filesystem (部分环境可能不可用)
local fs = {}
local fsOk, fsModule = pcall(require, "filesystem")
if fsOk then fs = fsModule end

-- 安全获取全息投影仪组件
local hologram
local holoOk, holoErr = pcall(function() return component.hologram end)
if not holoOk then
    print("[错误] 未检测到全息投影仪: " .. tostring(holoErr))
    print("请确保全息投影仪已连接到此电脑。")
    return
end
hologram = component.hologram

--------------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------------

local CONFIG = {
    -- 默认数据文件路径 (相对于脚本目录)
    dataFile   = "ba_frames.bin",
    -- 投影平面 Z 坐标 (0-47, XY 平面, 24=居中)
    zLevel     = 24,
    -- 缩放比例 (0.33 ~ 3.0)
    scale      = 2.0,
    -- 调色板 (索引 1/2/3, Tier 2 支持)
    palette    = {
        [1] = 0x555555,  -- 深灰
        [2] = 0xAAAAAA,  -- 浅灰
        [3] = 0xFFFFFF,  -- 白色
    },
    -- 是否自动循环播放
    loop       = false,
    -- Y 轴翻转: true=图像顶行→全息顶部, false=图像顶行→全息底部
    flipY      = false,
}

-- 全息投影分辨率常量
local WIDTH  = 48
local HEIGHT = 32
local TOTAL_VOXELS = WIDTH * HEIGHT  -- 1536

--------------------------------------------------------------------------------
-- 文件读取辅助
--------------------------------------------------------------------------------

local function readHeader(file)
    --[[
    读取并验证文件头, 返回 { frames, fps }
    文件头格式: magic(4B) version(1B) frames(4B LE) fps(1B) reserved(1B)
    ]]
    local header = file:read(11)
    if not header or #header < 11 then
        return nil, "文件头不完整"
    end

    local magic, version, frames, fps, reserved =
        string.unpack("<c4BIBB", header)

    if magic ~= "BAHL" then
        return nil, "无效的文件格式 (magic 不匹配)"
    end

    if version ~= 1 then
        return nil, "不支持的文件版本: " .. tostring(version)
    end

    return {
        frames = frames,
        fps    = fps,
    }
end

local function readOffsetTable(file, frameCount)
    --[[
    读取偏移表, 返回数组 offsets[1..frameCount]
    偏移表: frameCount 个 uint32 LE
    ]]
    local offsets = {}
    local raw = file:read(frameCount * 4)
    if not raw or #raw < frameCount * 4 then
        return nil, "偏移表不完整"
    end

    for i = 1, frameCount do
        local pos = (i - 1) * 4 + 1
        offsets[i] = string.unpack("<I4", raw, pos)
    end

    return offsets
end

--------------------------------------------------------------------------------
-- RLE 解码
--------------------------------------------------------------------------------

local function decodeFrame(rleData, frameLen)
    --[[
    解码一帧的 RLE 数据, 返回长度为 TOTAL_VOXELS 的数组 (值 0-3)。
    扫描顺序: z * WIDTH + x (按行)
    ]]
    local frame = {}  -- 1-indexed, frame[1..1536]
    local pos = 0      -- 当前在 1536 格中的位置 (0-indexed)

    -- 将 RLE 数据一次性转为字节表 (避免逐字节 string.byte)
    local bytes = { string.byte(rleData, 1, frameLen) }

    for i = 1, #bytes do
        local byte = bytes[i]
        local value = byte >> 6          -- bits 7-6
        local count = (byte & 0x3F) + 1  -- bits 5-0, +1

        -- 填充该 run 中所有位置
        for j = 1, count do
            pos = pos + 1
            frame[pos] = value
        end
    end

    -- 安全检查: RLE 应该覆盖全部 TOTAL_VOXELS 个位置
    if pos ~= TOTAL_VOXELS then
        -- 用 0 补齐 (容错)
        for i = pos + 1, TOTAL_VOXELS do
            frame[i] = 0
        end
    end

    return frame
end

--------------------------------------------------------------------------------
-- 渲染
--------------------------------------------------------------------------------

local function renderFrame(frame, prevFrame, zLevel)
    --[[
    Delta 渲染: 只更新与上一帧不同的体素。
    XY 平面投影 (Z 固定): pos -> (x, y) = (pos % 48, pos / 48)
    返回渲染的体素数。
    ]]
    local count = 0

    for pos = 1, TOTAL_VOXELS do
        local newVal = frame[pos] or 0
        local oldVal = prevFrame[pos] or 0

        if newVal ~= oldVal then
            local x = (pos - 1) % WIDTH
            local row = math.floor((pos - 1) / WIDTH)
            local y = CONFIG.flipY and ((HEIGHT - 1) - row) or row

            if newVal == 0 then
                hologram.set(x, y, zLevel, false)
            else
                hologram.set(x, y, zLevel, newVal)
            end

            prevFrame[pos] = newVal
            count = count + 1
        end
    end

    return count
end

--------------------------------------------------------------------------------
-- 屏幕 UI
--------------------------------------------------------------------------------

local function printBanner()
    print("")
    print("  ╔══════════════════════════════════════╗")
    print("  ║   Bad Apple - 全息投影仪播放器      ║")
    print("  ║   OpenComputers Tier 2 Hologram     ║")
    print("  ║   v" .. VERSION .. string.rep(" ", 31 - #VERSION) .. "║")
    print("  ╚══════════════════════════════════════╝")
    print("")
end

local function formatTime(seconds)
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%d:%02d", m, s)
end

local function printProgress(frame, total, elapsed, fps)
    local progress = frame / total * 100
    local remaining = (total - frame) / fps
    print(string.format(
        "  帧: %5d / %-5d  |  进度: %5.1f%%  |  已播放: %s  |  剩余: %s",
        frame, total, progress, formatTime(elapsed), formatTime(remaining)
    ))
end

--------------------------------------------------------------------------------
-- 初始化全息投影仪
--------------------------------------------------------------------------------

local function initHologram()
    -- 清空
    hologram.clear()

    -- 缩放
    hologram.setScale(CONFIG.scale)

    -- 调色板 (Tier 2)
    local depth = hologram.maxDepth()
    print(string.format("  全息投影仪色深: %d (Tier %s)",
        depth, depth >= 3 and "2" or "1"))

    for idx, color in pairs(CONFIG.palette) do
        if idx <= depth then
            hologram.setPaletteColor(idx, color)
        end
    end

    -- 偏移归零
    hologram.setTranslation(0, 0, 0)

    print("  调色板已设置:")
    print(string.format("    颜色 1: 0x%06X (深灰)", CONFIG.palette[1]))
    print(string.format("    颜色 2: 0x%06X (浅灰)", CONFIG.palette[2]))
    print(string.format("    颜色 3: 0x%06X (白色)", CONFIG.palette[3]))
    print(string.format("  缩放: %.1fx", CONFIG.scale))
    print(string.format("  Y轴翻转: %s (修改 CONFIG.flipY 切换)", CONFIG.flipY and "是" or "否"))
end

--------------------------------------------------------------------------------
-- 主播放循环
--------------------------------------------------------------------------------

local function playLoop(file, offsets, meta)
    local fps = meta.fps
    local frameCount = meta.frames
    local frameTime = 1.0 / fps

    -- 前一帧状态 (用于 delta 渲染)
    local prevFrame = {}
    for i = 1, TOTAL_VOXELS do
        prevFrame[i] = 0
    end

    local totalChanges = 0
    local startTime = computer.uptime()

    print(string.format("\n  开始播放: %d 帧 @ %d FPS (%.1f 秒)", frameCount, fps, frameCount / fps))
    print("  按 Ctrl+C 停止播放\n")

    for i = 1, frameCount do
        -- 定位到帧数据
        file:seek("set", offsets[i])

        -- 读取帧长度
        local lenRaw = file:read(2)
        if not lenRaw or #lenRaw < 2 then
            print("\n[错误] 读取帧 " .. i .. " 长度失败")
            break
        end
        local frameLen = string.unpack("<I2", lenRaw)

        -- 读取 RLE 数据
        local rleData = file:read(frameLen)
        if not rleData or #rleData < frameLen then
            print("\n[错误] 读取帧 " .. i .. " RLE 数据失败")
            break
        end

        -- 解码
        local frame = decodeFrame(rleData, frameLen)

        -- 渲染 (delta)
        local changes = renderFrame(frame, prevFrame, CONFIG.zLevel)
        totalChanges = totalChanges + changes

        -- 帧率控制
        local elapsed = computer.uptime() - startTime
        local target = i * frameTime
        if target > elapsed then
            os.sleep(target - elapsed)
        end

        -- 进度显示 (每 100 帧或最后一帧)
        if i % 100 == 0 or i == frameCount then
            local realElapsed = computer.uptime() - startTime
            local realFps = i / realElapsed
            printProgress(i, frameCount, realElapsed, realFps)
        end

        -- 检查中断
        local evt = event.pull(0)
        if evt == "interrupted" then
            print("\n\n  [中断] 播放已停止")
            break
        end
    end

    local totalTime = computer.uptime() - startTime
    print(string.format("\n  播放完毕: %d 帧, 耗时 %s, 平均 %.1f FPS",
        math.min(frameCount, #offsets),
        formatTime(totalTime),
        math.min(frameCount, #offsets) / totalTime))
    print(string.format("  总更新体素: %d (每帧平均 %.0f)", totalChanges, totalChanges / frameCount))
end

--------------------------------------------------------------------------------
-- 清理
--------------------------------------------------------------------------------

local function cleanup(file)
    hologram.clear()
    if file then
        file:close()
    end
    print("\n  全息投影已清除。再见!")
end

--------------------------------------------------------------------------------
-- 主函数
--------------------------------------------------------------------------------

local function main(args)
    printBanner()

    -- 确定数据文件路径
    local dataPath = CONFIG.dataFile
    if args and #args > 0 and args[1] ~= "" then
        dataPath = args[1]
    end

    -- 命令行切换 Y 轴翻转: ba_player ba_frames.bin flip
    if args and #args >= 2 and args[2] == "flip" then
        CONFIG.flipY = not CONFIG.flipY
        print("  [参数] Y轴翻转已切换为: " .. (CONFIG.flipY and "开" or "关"))
    end

    print("  数据文件: " .. dataPath)

    -- 直接尝试打开 (OC 的 io.open 可以正确处理相对/绝对路径)
    local file, err = io.open(dataPath, "rb")
    if not file then
        print("\n[错误] 无法打开: " .. dataPath)
        print("  " .. tostring(err))
        print("  请确保文件在当前目录, 或使用绝对路径:")
        print("    ba_player /home/badapple/ba_frames.bin")
        return
    end

    -- 可选: 显示文件大小
    pcall(function()
        if fs.size then
            local sz = fs.size(dataPath)
            if sz then
                print(string.format("  文件大小: %d 字节 (%.1f KB)", sz, sz / 1024))
            end
        end
    end)

    -- 读取头信息
    local meta, err = readHeader(file)
    if not meta then
        print("\n[错误] " .. tostring(err))
        file:close()
        return
    end

    print(string.format("  帧数: %d | FPS: %d | 时长: %.1f 秒",
        meta.frames, meta.fps, meta.frames / meta.fps))

    -- 读取偏移表
    local offsets, err = readOffsetTable(file, meta.frames)
    if not offsets then
        print("\n[错误] " .. tostring(err))
        file:close()
        return
    end

    -- 初始化全息投影仪
    initHologram()

    -- 开始播放
    local ok, errMsg = pcall(playLoop, file, offsets, meta)

    -- 清理
    cleanup(file)

    if not ok then
        print("\n[运行时错误] " .. tostring(errMsg))
    end
end

-- 启动
local args = {...}
main(args)
