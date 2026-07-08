# Bad Apple — 全息投影仪播放器

将 Bad Apple 视频在 GTNH 全息投影仪上播放，支持 Tape Drive 原声音频。

## 快速开始 (OC 端)

```shell
mkdir badapple && cd badapple

# 下载 (github.xutongxin.me 加速)
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_player.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_frames.bin
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_audio.dfpwm

# 写入磁带 (仅需一次)
ba_player write ba_audio.dfpwm

# 播放
ba_player ba_frames.bin
```

## PC 端预处理

```bash
pip install -r requirements.txt

# 全息帧 (15fps, 48×32, RLE)
python extract_frames.py "Bad Apple.mp4" -f 15
# → ba_frames.bin (~456KB)

# DFPWM 音频 (32768Hz, aucmp 兼容)
python encode_dfpwm.py "Bad Apple.mp4"
# → ba_audio.dfpwm (~0.84MB)
```

## 命令

```lua
ba_player                        -- 播放 (默认 ba_frames.bin)
ba_player <frames文件>            -- 播放指定文件
ba_player write [dfpwm文件]      -- 写入音频到磁带
```

## 硬件

| 设备 | 用途 | 模组 |
|---|---|---|
| 全息投影仪 (Tier 1/2) | 48×32 画面 | OpenComputers |
| 电脑 | 运行播放器 | OpenComputers |
| Tape Drive + 磁带 | 原声音频 (可选) | Computronics |

## 参数

| 参数 | 值 |
|---|---|
| 分辨率 | 48×32 (XY 平面, Z=24) |
| 色深 | 3 色调色板 |
| 帧率/帧数 | 15 FPS / 3286 帧 |
| 全息数据 | ~456KB (RLE 压缩) |
| 音频数据 | ~0.84MB (DFPWM) |
| 音频采样率 | 32768 Hz |

## 文件

| 文件 | 说明 |
|---|---|
| `extract_frames.py` | 视频 → 全息帧 |
| `encode_dfpwm.py` | 视频 → DFPWM 音频 |
| `ba_player.lua` | OC 播放器 |
| `ba_frames.bin` | 全息数据 |
| `ba_audio.dfpwm` | 音频数据 |

