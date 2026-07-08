"""
Bad Apple - 音频 DFPWM 编码器
==============================
从视频提取音频并编码为 Computronics Tape Drive 的 DFPWM 格式。
压缩比 16:1 (16-bit PCM → 1-bit DFPWM), ~1.3MB / 3分39秒。

用法:
    python encode_dfpwm.py <视频文件> [选项]

选项:
    --output, -o     输出文件 (默认: ba_audio.dfpwm)
    --sample-rate    采样率 Hz (默认: 48000)
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile

STEPS = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768]
STEPS_MAX = len(STEPS) - 1


def extract_pcm(video_path, output_path, sample_rate=48000):
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        video_path,
        "-ac",
        "1",
        "-ar",
        str(sample_rate),
        "-f",
        "s16le",
        output_path,
    ]
    print(f"[FFmpeg] 提取 PCM ({sample_rate}Hz)...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"失败:\n{r.stderr}")
        sys.exit(1)
    size = os.path.getsize(output_path)
    print(f"  PCM: {size:,} 字节 ({size/(2*sample_rate):.1f}s)")


def encode_dfpwm(samples):
    idx = 0
    pred = 0
    prev = 0
    out = bytearray()
    byte = 0
    bp = 7
    total = len(samples)

    for i, s in enumerate(samples):
        bit = 1 if s >= pred else 0

        if bit:
            pred += STEPS[idx]
            if pred > 32767:
                pred = 32767
        else:
            pred -= STEPS[idx]
            if pred < -32768:
                pred = -32768

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

        if (i + 1) % 1000000 == 0:
            print(f"  编码: {i+1}/{total} ({100*(i+1)/total:.0f}%)")

    if bp < 7:
        out.append(byte)
    return bytes(out)


def main():
    p = argparse.ArgumentParser(description="视频 -> DFPWM 音频")
    p.add_argument("video")
    p.add_argument("-o", "--output", default="ba_audio.dfpwm")
    p.add_argument("-r", "--sample-rate", type=int, default=48000)
    args = p.parse_args()

    if not os.path.exists(args.video):
        print(f"找不到: {args.video}")
        sys.exit(1)

    with tempfile.NamedTemporaryFile(suffix=".pcm", delete=False) as t:
        pcm_path = t.name

    try:
        extract_pcm(args.video, pcm_path, args.sample_rate)

        with open(pcm_path, "rb") as f:
            raw = f.read()

        count = len(raw) // 2
        samples = struct.unpack(f"<{count}h", raw)
        print(f"[DFPWM] 编码 {len(samples):,} 样本...")
        dfpwm = encode_dfpwm(samples)

        with open(args.output, "wb") as f:
            f.write(dfpwm)

        pcm_mb = len(raw) / 1024 / 1024
        dfpwm_mb = len(dfpwm) / 1024 / 1024
        dur = len(samples) / args.sample_rate

        print(f"\n[完成] {args.output}")
        print(f"  时长:     {dur:.1f}s")
        print(f"  PCM:      {pcm_mb:.1f} MB")
        print(f"  DFPWM:    {dfpwm_mb:.2f} MB ({len(dfpwm):,} 字节)")
        print(f"  压缩比:   {len(raw)/max(len(dfpwm),1):.1f}:1")

    finally:
        os.unlink(pcm_path)


if __name__ == "__main__":
    main()
