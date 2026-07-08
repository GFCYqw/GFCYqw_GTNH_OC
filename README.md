# GFCYqw_GTNH_OC

GTNH (GregTech New Horizons) OpenComputers 工具集。

---

## Bad Apple — 全息投影仪播放器

将 Bad Apple 视频在 Tier 1/2 全息投影仪上播放，支持 Computronics Tape Drive 原声音频。

### 硬件需求

| 设备 | 用途 | 模组 |
|---|---|---|
| 全息投影仪 (Tier 1/2) | 48×32 画面 | OpenComputers |
| 电脑 | 运行播放器 | OpenComputers |
| Tape Drive + 磁带 | 原声音频 (可选) | Computronics |

### 快速开始 (OC 端)

```shell
mkdir badapple && cd badapple

# 加速下载 (github.xutongxin.me 代理)
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_player.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_frames.bin
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_audio.dfpwm

# 写入磁带 (仅需一次)
ba_player write ba_audio.dfpwm

# 播放
ba_player ba_frames.bin
```

### OC 命令

```lua
ba_player                          -- 播放 (默认 ba_frames.bin)
ba_player <frames文件>              -- 播放指定文件
ba_player write [dfpwm文件]        -- 写入音频到磁带
```

### PC 端预处理

```bash
cd badapple
pip install -r requirements.txt

# 全息帧 (48×32, RLE 压缩, ~456KB)
python extract_frames.py "Bad Apple.mp4" -f 15

# DFPWM 音频 (32768Hz, ~0.84MB)
python encode_dfpwm.py "Bad Apple.mp4"
```

### 文件结构

```
badapple/
├── extract_frames.py    # PC: 视频 → 全息帧 (ba_frames.bin)
├── encode_dfpwm.py      # PC: 视频 → DFPWM 音频 (ba_audio.dfpwm)
├── ba_player.lua        # OC: 播放器 (write / play)
├── ba_frames.bin        # 全息帧数据 (~456KB)
├── ba_audio.dfpwm       # DFPWM 音频 (~0.84MB)
├── requirements.txt     # Python 依赖 (Pillow, numpy)
└── README.md
```

### 全息参数

| 参数 | 值 |
|---|---|
| 分辨率 | 48×32 (XY 平面, Z=24) |
| 色深 | 3 色调色板 (白/浅灰/深灰) |
| 帧率 | 15 FPS |
| 帧数 | 3286 帧 |
| 压缩 | RLE (~9%) |
| 音频 | DFPWM 1-bit @ 32768Hz |

---

## GTNH 机器自动化

```shell
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/g8.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/pump.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/fluids_AR.lua
```

| 脚本 | 用途 |
|---|---|
| `g8.lua` | 绝对重子完美净化单元自动化 |
| `purified_water_grade_8_wikli.lua` | 净化水 G8 控制 |
| `pump.lua` | 流体泵控制 |
| `fluids_AR.lua` | AR 流体处理 |

