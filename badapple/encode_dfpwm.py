"""
Bad Apple - 音频 DFPWM 编码器 (Computronics 兼容)
===================================================
从视频提取音频并编码为 Computronics Tape Drive 兼容的 DFPWM。

格式: 32768Hz, 8-bit unsigned, mono → DFPWM (1-bit)
参考: Computronics AudioPacketClientHandlerDFPWM.java

用法:
    python encode_dfpwm.py <视频文件>
"""

import argparse
import os
import subprocess
import sys
import tempfile

# DFPWM 步长表, 适配 8-bit signed 范围 (-128 ~ 127)
# 原始表 for 16-bit 缩放为 8-bit: 除以 256
STEPS = [
    max(1, s // 256)
    for s in [
        1,
        2,
        4,
        8,
        16,
        32,
        64,
        128,
        256,
        512,
        1024,
        2048,
        4096,
        8192,
        16384,
        32768,
    ]
]
STEPS_MAX = len(STEPS) - 1

SAMPLE_RATE = 32768  # Computronics DFPWM 标准采样率


def extract_pcm(video_path, output_path):
    """FFmpeg: 8-bit unsigned mono PCM @ 32768Hz"""
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        video_path,
        "-ac",
        "1",
        "-ar",
        str(SAMPLE_RATE),
        "-f",
        "u8",
        output_path,
    ]
    print(f"[FFmpeg] 提取 PCM ({SAMPLE_RATE}Hz, 8-bit unsigned mono)...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"失败:\n{r.stderr}")
        sys.exit(1)
    size = os.path.getsize(output_path)
    print(f"  PCM: {size:,} 字节 ({size/SAMPLE_RATE:.1f}s)")


def encode_dfpwm(samples_u8):
    """
    DFPWM 编码: 8-bit unsigned PCM → 1-bit DFPWM (MSB first)
    参考: pl.asie.lib.audio.DFPWM (asie-lib)
    """
    idx = 0  # 步长索引
    pred = 0  # 预测值 (signed 8-bit 范围)
    prev = 0  # 上一个比特

    out = bytearray()
    byte = 0
    bp = 7
    total = len(samples_u8)

    for i, u8 in enumerate(samples_u8):
        # unsigned 0-255 → signed -128 to 127
        s = u8 - 128

        bit = 1 if s >= pred else 0

        if bit:
            pred += STEPS[idx]
            if pred > 127:
                pred = 127
        else:
            pred -= STEPS[idx]
            if pred < -128:
                pred = -128

        if bit == prev:
            idx = idx + 1 if idx < STEPS_MAX else STEPS_MAX
        else:
            idx = idx - 1 if idx > 0 else 0
        prev = bit

        byte |= bit << bp
        bp -= 1
        if bp < 0:
            out.append(byte)
            byte = 0
            bp = 7

        if (i + 1) % 2000000 == 0:
            print(f"  编码: {i+1}/{total} ({100*(i+1)/total:.0f}%)")

    if bp < 7:
        out.append(byte)
    return bytes(out)


def main():
    p = argparse.ArgumentParser(description="视频 -> DFPWM (Computronics)")
    p.add_argument("video")
    p.add_argument("-o", "--output", default="ba_audio.dfpwm")
    args = p.parse_args()

    if not os.path.exists(args.video):
        print(f"找不到: {args.video}")
        sys.exit(1)

    with tempfile.NamedTemporaryFile(suffix=".pcm", delete=False) as t:
        pcm_path = t.name

    try:
        extract_pcm(args.video, pcm_path)

        with open(pcm_path, "rb") as f:
            pcm_u8 = f.read()

        print(f"[DFPWM] 编码 {len(pcm_u8):,} 样本...")
        dfpwm = encode_dfpwm(pcm_u8)

        with open(args.output, "wb") as f:
            f.write(dfpwm)

        dur = len(pcm_u8) / SAMPLE_RATE
        dfpwm_mb = len(dfpwm) / 1024 / 1024

        print(f"\n[完成] {args.output}")
        print(f"  时长:     {dur:.1f}s")
        print(f"  PCM:      {len(pcm_u8)/1024/1024:.1f} MB")
        print(f"  DFPWM:    {dfpwm_mb:.2f} MB ({len(dfpwm):,} 字节)")
        print(f"  采样率:   {SAMPLE_RATE} Hz")

    finally:
        os.unlink(pcm_path)


if __name__ == "__main__":
    main()
