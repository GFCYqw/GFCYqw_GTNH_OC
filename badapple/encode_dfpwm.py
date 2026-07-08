"""
Bad Apple - 音频 DFPWM 编码器
==============================
将视频音频提取并编码为 Computronics Tape Drive 可播放的 DFPWM 格式。

DFPWM: 1-bit Delta Modulation with adaptive step size
用于 Computronics 的磁带驱动器 (Tape Drive)

用法:
    python encode_dfpwm.py <视频文件> [选项]

选项:
    --output, -o     输出 .dfpwm 文件路径 (默认: ba_audio.dfpwm)
    --sample-rate    输出采样率 Hz (默认: 48000, Computronics 标准)
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile

# DFPWM 步长表 (标准 ADPCM 变体)
STEP_TABLE = [
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
STEP_MAX = len(STEP_TABLE) - 1


def extract_audio_raw(video_path, output_raw, sample_rate=48000):
    """FFmpeg 提取 16-bit 单声道 PCM 原始音频"""
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
        output_raw,
    ]
    print(f"[FFmpeg] 提取原始 PCM ({sample_rate}Hz, 16-bit, mono)...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"FFmpeg 失败:\n{r.stderr}")
        sys.exit(1)
    size = os.path.getsize(output_raw)
    print(f"  完成: {size:,} 字节 ({size / (2*sample_rate):.1f}s)")


def encode_dfpwm(samples):
    """
    DFPWM 编码: 16-bit PCM → 1-bit DFPWM 字节流

    算法: 自适应增量调制
    - 预测下一个样本值
    - 输出 1-bit 差值方向
    - 根据连续相同/不同比特调整步长
    """
    index = 0
    prev_sample = 0
    prev_bit = False

    output = bytearray()
    current_byte = 0
    bit_pos = 7

    total = len(samples)
    for i, sample in enumerate(samples):
        diff = sample - prev_sample
        bit = diff >= 0

        # 更新预测值
        if bit:
            prev_sample = min(prev_sample + STEP_TABLE[index], 32767)
        else:
            prev_sample = max(prev_sample - STEP_TABLE[index], -32768)

        # 更新步长索引
        if bit == prev_bit:
            index = min(index + 1, STEP_MAX)
        else:
            index = max(index - 1, 0)
        prev_bit = bit

        # 打包比特 (MSB first)
        if bit:
            current_byte |= 1 << bit_pos
        bit_pos -= 1
        if bit_pos < 0:
            output.append(current_byte)
            current_byte = 0
            bit_pos = 7

        if (i + 1) % 500000 == 0:
            pct = 100 * (i + 1) / total
            print(f"  编码: {i+1}/{total} ({pct:.1f}%)")

    # 填充剩余比特
    if bit_pos < 7:
        output.append(current_byte)

    return bytes(output)


def main():
    p = argparse.ArgumentParser(description="音频 → DFPWM 编码器")
    p.add_argument("video", help="输入视频文件路径")
    p.add_argument("-o", "--output", default="ba_audio.dfpwm")
    p.add_argument(
        "-r", "--sample-rate", type=int, default=48000, help="采样率 Hz (默认: 48000)"
    )
    args = p.parse_args()

    if not os.path.exists(args.video):
        print(f"找不到: {args.video}")
        sys.exit(1)

    with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as t:
        raw_path = t.name

    try:
        # 提取 PCM
        extract_audio_raw(args.video, raw_path, args.sample_rate)

        # 读取 PCM
        with open(raw_path, "rb") as f:
            raw_data = f.read()

        samples = np.frombuffer(raw_data, dtype=np.int16).astype(np.int32)
        print(f"  PCM 样本数: {len(samples)}")
        print(f"[DFPWM] 开始编码...")

        # DFPWM 编码
        dfpwm_data = encode_dfpwm(samples)

        # 写入
        with open(args.output, "wb") as f:
            f.write(dfpwm_data)

        size = os.path.getsize(args.output)
        raw_mbps = len(raw_data) / (1024 * 1024) / (len(samples) / args.sample_rate)
        dfpwm_mbps = size / (1024 * 1024) / (len(samples) / args.sample_rate)

        print(f"\n[完成] {args.output}")
        print(f"  原始 PCM:  {len(raw_data):,} 字节 ({raw_mbps:.1f} MB/s)")
        print(f"  DFPWM:     {size:,} 字节 ({dfpwm_mbps:.1f} MB/s)")
        print(f"  压缩率:    {size/len(raw_data)*100:.1f}%")
        print(f"  时长:      {len(samples)/args.sample_rate:.1f}s")

    finally:
        if os.path.exists(raw_path):
            os.unlink(raw_path)


if __name__ == "__main__":
    main()
