bad

# GFCYqw_GTNH_OC

```Shell
wget -f https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/fluids_AR.lua
wget -f https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/pump.lua

wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/pump.lua
```

## Badapple

```Shell
python extract_frames.py "Bad Apple but 4k 60fps.mp4" -f 15
python extract_audio2.py "Bad Apple but 4k 60fps.mp4" -f 15

# 1. 编码 DFPWM (约 8MB @ 48kHz, 3分39秒)
python encode_dfpwm.py "Bad Apple but 4k 60fps.mp4"
# → 生成 ba_audio.dfpwm

mkdir badapple
cd badapple
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_player.lua
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_frames.bin
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/GFCYqw/GFCYqw_GTNH_OC/main/badapple/ba_audio.dfpwm
# 首次: 写入磁带 (后续直接 play, 磁带数据持久化)
ba_player ba_frames.bin ba_audio.dfpwm

# 之后: 磁带已有数据, 可以直接运行
ba_player ba_frames.bin
```
