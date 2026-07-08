"""
Bad Apple - DFPWM 编码器 (aucmp 兼容)
=======================================
基于 Ben "GreaseMonkey" Russell 的 DFPWM 参考实现。
与 Computronics/aucmp 比特级兼容。

用法:
  python encode_dfpwm.py <视频文件>
"""

import argparse
import os
import subprocess
import sys
import tempfile

SAMPLE_RATE = 32768  # Computronics 标准


def extract_pcm(video_path, output_path):
    """FFmpeg: 8-bit signed PCM @ 32768Hz"""
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
        "s8",
        output_path,
    ]
    print(f"[FFmpeg] PCM ({SAMPLE_RATE}Hz, 8-bit signed)...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"失败:\n{r.stderr}")
        sys.exit(1)
    print(
        f"  {os.path.getsize(output_path):,} 字节 "
        f"({os.path.getsize(output_path)/SAMPLE_RATE:.1f}s)"
    )


def trim_silence(pcm, threshold=3):
    """裁剪首尾静音 (8-bit signed, 0=静音)"""

    def s(b):
        return b if b <= 127 else b - 256

    st = 0
    for i in range(len(pcm)):
        if abs(s(pcm[i])) > threshold:
            st = i
            break
    ed = len(pcm)
    for i in range(len(pcm) - 1, st, -1):
        if abs(s(pcm[i])) > threshold:
            ed = i + 1
            break
    t = pcm[st:ed]
    if st > 0 or ed < len(pcm):
        print(
            f"  裁剪静音: {st+len(pcm)-ed} 样本 "
            f"({(st+len(pcm)-ed)/SAMPLE_RATE:.1f}s)"
        )
    return t


def encode_dfpwm(samples_s8):
    """
    DFPWM 编码 (aucmp 兼容).
    参考: aucmp.c by Ben Russell, 2012

    q = charge (预测值), s = strength (适应速率)
    ri = 7 (strength increase), rd = 20 (strength decrease)
    lt = -128 (上一目标值)

    比特打包: LSB first (低比特位优先)
    """
    q = 0  # charge, 初始 0
    s = 1  # strength, 初始 1
    lt = -128  # 上一目标, 初始 -128
    ri = 7  # strength increase rate
    rd = 20  # strength decrease rate

    out = bytearray()
    total = len(samples_s8)

    # 处理每 8 个样本为一组
    for block_start in range(0, total, 8):
        d = 0
        block_end = min(block_start + 8, total)

        for j in range(block_end - block_start):
            # 8-bit unsigned → signed
            b = samples_s8[block_start + j]
            v = b if b <= 127 else b - 256

            # 确定输出比特和目标值
            t = 127 if (v >= q or v == -128) else -128

            # 比特打包: LSB first
            d >>= 1
            if t > 0:
                d |= 0x80

            # 更新 strength
            st = 255 if (t == lt) else 0
            sr = ri if (t == lt) else rd
            ns = s + ((sr * (st - s) + 128) >> 8)
            if ns == s and ns != st:
                ns += 1 if st == 255 else -1
            s = ns

            # 更新 charge
            nq = q + ((s * (t - q) + 128) >> 8)
            if nq == q and nq != t:
                nq += 1 if t == 127 else -1
            q = nq

            lt = t

        # 补齐剩余比特位移
        for j in range(8 - (block_end - block_start)):
            d >>= 1

        out.append(d)

        if (block_start + 8) % 2000000 == 0:
            pct = 100 * min(block_start + 8, total) / total
            print(f"  编码: {min(block_start+8, total)}/{total} ({pct:.0f}%)")

    return bytes(out)


def main():
    p = argparse.ArgumentParser(description="视频 -> DFPWM (aucmp 兼容)")
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
            pcm = f.read()
        pcm = trim_silence(pcm)
        print(f"[DFPWM] 编码 {len(pcm):,} 样本 (aucmp 兼容)...")
        dfpwm = encode_dfpwm(pcm)

        with open(args.output, "wb") as f:
            f.write(dfpwm)

        dur = len(pcm) / SAMPLE_RATE
        mb = len(dfpwm) / 1024 / 1024
        print(f"\n[完成] {args.output}")
        print(f"  时长: {dur:.1f}s  |  大小: {mb:.2f} MB  |  {SAMPLE_RATE}Hz")
    finally:
        os.unlink(pcm_path)


if __name__ == "__main__":
    main()
