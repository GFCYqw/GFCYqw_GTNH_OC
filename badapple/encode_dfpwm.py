"""
Bad Apple - 音频提取 (原始 PCM, 无编码)
=========================================
从视频直接提取 16-bit 单声道原始 PCM,
不做任何编码处理, 直接写入磁带文件。

用法:
    python encode_dfpwm.py <视频文件> [选项]
"""

import argparse
import os
import subprocess
import sys


def extract_raw(video_path, output_path, sample_rate=48000):
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
    print(f"[FFmpeg] 提取 PCM ({sample_rate}Hz, 16-bit, mono)...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"失败:\n{r.stderr}")
        sys.exit(1)
    size = os.path.getsize(output_path)
    print(f"  完成: {size:,} 字节 ({size/(2*sample_rate):.1f}s)")


def main():
    p = argparse.ArgumentParser(description="视频 -> 原始 PCM")
    p.add_argument("video")
    p.add_argument("-o", "--output", default="ba_audio.dfpwm")
    p.add_argument("-r", "--sample-rate", type=int, default=48000)
    args = p.parse_args()

    if not os.path.exists(args.video):
        print(f"找不到: {args.video}")
        sys.exit(1)

    extract_raw(args.video, args.output, args.sample_rate)

    size = os.path.getsize(args.output)
    print(f"\n[完成] {args.output}")
    print(f"  大小: {size:,} 字节 ({size/1024/1024:.1f} MB)")


if __name__ == "__main__":
    main()
