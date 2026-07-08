# GFCYqw_GTNH_OC

GTNH (GregTech New Horizons) OpenComputers 工具集。

## Bad Apple 全息投影仪

→ [badapple/README.md](badapple/README.md)

```shell
mkdir badapple && cd badapple
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_player.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_frames.bin
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_audio.dfpwm
ba_player write ba_audio.dfpwm
ba_player ba_frames.bin
```

## 机器自动化

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

