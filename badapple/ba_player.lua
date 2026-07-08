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
--      可选指定音频文件:
--          ba_player ba_frames.bin ba_audio.bin
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

local VERSION = "2.4"

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

-- 安全获取音频设备 (Computronics Noise Card / Sound Card)
local audioDevice = nil
local audioType = nil  -- "noise" or "sound"

-- Noise Card: play({{freq, duration}, ...})
local function tryNoiseCard()
    local ok, dev = pcall(function() return component.noise end)
    if ok and dev then return dev, "noise" end
end

-- Sound Card: setFrequency + open + delay + close + process
local function trySoundCard()
    local ok, dev = pcall(function() return component.sound end)
    if ok and dev then return dev, "sound" end
end

audioDevice, audioType = tryNoiseCard()
if not audioDevice then
    audioDevice, audioType = trySoundCard()
end

local hasAudio = (audioDevice ~= nil)
if hasAudio then
    print("[音频] 检测到: " .. audioType .. " 卡")
else
    print("[音频] 未检测到 Noise/Sound 卡, 将仅播放画面")
    print("[音频] 可用组件:")
    pcall(function()
        for addr, ctype in component.list() do
            print("  " .. ctype)
        end
    end)
end

-- 音符 → 频率 (Iron Note 0 = C4 = 261.63Hz)
local function noteToFreq(note)
    return 261.63 * 2 ^ (note / 12)
end

-- 音频缓冲 (批量发送，避免断裂)
local audioBuffer = {}       -- {{freq, duration_sec}, ...}
local lastPlayedNote = nil   -- 上一个音符 (用于音符保持)
local sustainFrames = 0      -- 剩余保持帧数
local SUSTAIN_MAX = 4        -- 静音后保持 4 帧 (~267ms @ 15fps)

local function flushAudioBuffer()
    if #audioBuffer == 0 then return end
    if audioType == "noise" then
        audioDevice.play(audioBuffer)
    elseif audioType == "sound" then
        -- Sound Card: 取第一个频率
        local freq = audioBuffer[1][1]
        audioDevice.setWave(1, 1)
        audioDevice.setFrequency(1, freq)
        audioDevice.setVolume(1, 0.4)
        audioDevice.open(1)
        for _, entry in ipairs(audioBuffer) do
            audioDevice.setFrequency(1, entry[1])
            audioDevice.delay(math.floor(entry[2] * 1000))
        end
        audioDevice.close(1)
        audioDevice.process()
    end
    audioBuffer = {}
end

local function playAudioFrame(audioNotes, frameIdx, fps)
    --[[
    音符保持 + 缓冲: 平滑连续的音频输出。
    即使当前帧无音符，也会短暂保持上一个音符。
    每 8 帧或音符变化时刷新缓冲区。
    ]]
    local frameDur = 1.0 / fps
    local hasNote = (audioNotes[frameIdx] ~= nil)
    local curNote = hasNote and audioNotes[frameIdx].note or nil

    if hasNote then
        -- 有音符: 加入缓冲, 重置保持计时器
        lastPlayedNote = curNote
        sustainFrames = SUSTAIN_MAX
        audioBuffer[#audioBuffer + 1] = {noteToFreq(curNote), frameDur}
    elseif sustainFrames > 0 then
        -- 音符保持: 延续上一个音符
        sustainFrames = sustainFrames - 1
        audioBuffer[#audioBuffer + 1] = {noteToFreq(lastPlayedNote), frameDur}
    else
        -- 静音: 刷新缓冲区 (断路)
        flushAudioBuffer()
        lastPlayedNote = nil
        return
    end

    -- 每 8 帧 (~0.5s) 或音符变化时刷新
    if #audioBuffer >= 8 then
        flushAudioBuffer()
    elseif hasNote and #audioBuffer > 1 then
        -- 检查音符是否变化
        local prevNote = audioNotes[frameIdx - 1]
        if prevNote and prevNote.note ~= curNote then
            flushAudioBuffer()
        end
    end
end

--------------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------------

local CONFIG = {
    -- 默认数据文件路径
    dataFile   = "ba_frames.bin",
    -- 音频文件路径 (可选, Iron Note Block 需要)
    audioFile  = "ba_audio.bin",
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
-- 音频数据读取
--------------------------------------------------------------------------------

local function loadAudioData(audioPath, expectedFrames)
    --[[
    读取 ba_audio.bin, 返回 frame_notes[1..frames] 数组。
    每帧: nil=静音, {instrument, note}=播放音符
    ]]
    local f, err = io.open(audioPath, "rb")
    if not f then
        return nil, err
    end

    local header = f:read(11)
    if not header or #header < 11 then
        f:close()
        return nil, "音频文件头不完整"
    end

    local magic, version, frames, fps, reserved =
        string.unpack("<c4BIBB", header)

    if magic ~= "BAAU" then
        f:close()
        return nil, "无效的音频格式"
    end

    local raw = f:read(frames)
    f:close()

    if not raw or #raw < frames then
        return nil, "音频数据不完整"
    end

    local notes = {}
    local count = 0
    for i = 1, frames do
        local byte = string.byte(raw, i)
        if byte ~= 0 then
            local instrument = byte >> 5
            local note = byte & 0x1F
            notes[i] = { instrument = instrument, note = note }
            count = count + 1
        end
    end

    return { notes = notes, frames = frames, count = count, fps = fps }
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
            local y = (HEIGHT - 1) - row  -- Y轴翻转: 图像顶行→全息顶部

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

    -- 调色板 (尝试设置 3 色, Tier 1 会自动忽略多余的)
    local depth = hologram.maxDepth()
    print(string.format("  全息投影仪色深: %d", depth))

    for idx = 1, 3 do
        local color = CONFIG.palette[idx]
        if color then
            pcall(function() hologram.setPaletteColor(idx, color) end)
        end
    end

    -- 偏移归零
    hologram.setTranslation(0, 0, 0)

    print("  调色板已设置:")
    print(string.format("    颜色 1: 0x%06X (深灰)", CONFIG.palette[1]))
    print(string.format("    颜色 2: 0x%06X (浅灰)", CONFIG.palette[2]))
    print(string.format("    颜色 3: 0x%06X (白色)", CONFIG.palette[3]))
    print(string.format("  缩放: %.1fx", CONFIG.scale))
    if hasAudio then
        print("  Speaker: 已检测到")
    end
end

--------------------------------------------------------------------------------
-- 主播放循环
--------------------------------------------------------------------------------

local function playLoop(file, offsets, meta, audio)
    local fps = meta.fps
    local frameCount = meta.frames
    local frameTime = 1.0 / fps

    -- 音频数据
    local audioNotes = nil
    local audioCount = 0
    if audio then
        audioNotes = audio.notes
        audioCount = audio.count
    end

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

        -- 播放音频 (缓冲批量发送，避免断裂)
        if audioNotes and audioDevice then
            pcall(playAudioFrame, audioNotes, i, fps)
        end

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
    if audioCount > 0 then
        print(string.format("  播放音符:   %d", audioCount))
    end
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

    -- 第二参数: 音频文件路径 (可选)
    if args and #args >= 2 and args[2] ~= "" then
        CONFIG.audioFile = args[2]
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

    -- 尝试加载音频
    local audio = nil
    if hasAudio then
        local audioPath = CONFIG.audioFile
        -- 尝试相对于视频文件所在目录
        local audioOk, audioData = pcall(loadAudioData, audioPath, meta.frames)
        if audioOk and audioData then
            audio = audioData
            print(string.format("  音频: %d 音符 | 文件: %s", audio.count, audioPath))
        else
            print("  音频: 未加载 (" .. tostring(audioData) .. ")")
        end
    end

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
    local ok, errMsg = pcall(playLoop, file, offsets, meta, audio)

    -- 清理
    cleanup(file)

    if not ok then
        print("\n[运行时错误] " .. tostring(errMsg))
    end
end

-- 启动
local args = {...}
main(args)
