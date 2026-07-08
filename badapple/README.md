# Bad Apple — 全息投影仪播放器

将 Bad Apple 视频在 GTNH 的 OpenComputers 全息投影仪上播放，支持 Computronics Tape Drive 原声音频。

## 硬件需求

| 设备                  | 用途             | 模组          |
| --------------------- | ---------------- | ------------- |
| 全息投影仪 (Tier 1/2) | 显示 48×32 画面 | OpenComputers |
| 电脑                  | 运行播放器       | OpenComputers |
| Tape Drive + 磁带     | 原声音频 (可选)  | Computronics  |

## 项目结构

```
badapple/
├── extract_frames.py    # PC: 视频 → 全息帧 (ba_frames.bin)
├── encode_dfpwm.py      # PC: 视频 → 原始 PCM (ba_audio.dfpwm)
├── ba_player.lua        # OC: 播放器 (write / play)
├── ba_holo.app          # OC: 应用包
├── requirements.txt     # Python 依赖
└── README.md
```

## PC 端

```bash
# 依赖
pip install -r requirements.txt

# 全息帧 (15fps, 48×32, RLE 压缩)
python extract_frames.py "Bad Apple but 4k 60fps.mp4" -f 15
# → ba_frames.bin (~456KB)

# 音频 (原始 PCM, 48kHz)
python encode_dfpwm.py "Bad Apple but 4k 60fps.mp4"
# → ba_audio.dfpwm (~21MB)
```

## OC 端

```lua
-- 下载播放器
wget -f https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_player.lua
wget -f https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_frames.bin
wget -f https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_audio.dfpwm

-- 写入磁带 (仅需一次)
ba_player write ba_audio.dfpwm

-- 播放
ba_player ba_frames.bin
```

### 命令

```lua
ba_player                        -- 播放 (默认 ba_frames.bin)
ba_player <文件>                  -- 播放指定文件
ba_player write [dfpwm文件]      -- 写入音频到磁带
```

## 全息参数

| 参数   | 值                     |
| ------ | ---------------------- |
| 分辨率 | 48×32 (XY 平面, Z=24) |
| 色深   | 3 色调色板             |
| 帧率   | 15 FPS                 |
| 压缩   | RLE (~9%)              |
| 数据量 | ~456KB (3286 帧)       |

## PC 工具详解

### extract_frames.py

```
python extract_frames.py <视频> [选项]

选项:
  -o, --output    输出路径 (默认: ba_frames.bin)
  -f, --fps       帧率 (默认: 15)
  --test          生成测试图案 (无需视频)
```

### encode_dfpwm.py

```
python encode_dfpwm.py <视频> [选项]

选项:
  -o, --output      输出路径 (默认: ba_audio.dfpwm)
  -r, --sample-rate 采样率 Hz (默认: 48000)
```
