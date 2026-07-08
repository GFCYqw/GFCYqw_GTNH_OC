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
ba_player --scale=3.0 --volume=0.5
```

## 机器自动化

```shell
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/g8.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/pump.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/fluids_AR.lua
```

| 脚本                                 | 用途                             |
| ------------------------------------ | -------------------------------- |
| `g8.lua`                           | 绝对重子完美净化单元（G8）自动化 |
| `purified_water_grade_8_wikli.lua` | 净化水 G8（Wiki 原版）           |
| `pump.lua`                         | 太空钻机模块流体自动维持         |
| `fluids_AR.lua`                    | 使用 AR 眼镜监控 ME 流体        |
