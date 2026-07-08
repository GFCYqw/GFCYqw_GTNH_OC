"""
Bad Apple - 视频音频转 Iron Note Block 音符脚本
================================================
从视频文件直接提取音频, 用 FFT 逐帧分析音高,
映射为 Iron Note Block 可播放的音符序列。

用法:
    python extract_audio2.py <视频文件> [选项]
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile

MAGIC = b"BAAU"
VERSION = 1
NOTE_MIN = 0
NOTE_MAX = 24
FREQ_MIN = 80
FREQ_MAX = 2000


def extract_audio_wav(video_path, output_wav, sample_rate=8000):
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
        "wav",
        output_wav,
    ]
    print(f"[FFmpeg] 提取音频...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"FFmpeg 失败:\n{r.stderr}")
        sys.exit(1)
    print(f"完成, {os.path.getsize(output_wav):,} 字节")


def freq_to_note(freq):
    if freq <= 0:
        return 0
    midi = 69 + 12 * np.log2(freq / 440.0)
    n = int(round(midi - 60))
    return max(NOTE_MIN, min(NOTE_MAX, n))


def detect_pitch(samples, sample_rate, threshold):
    n = len(samples)
    if n < 16:
        return None
    rms = np.sqrt(np.mean(samples.astype(np.float64) ** 2))
    if rms < threshold:
        return None
    win = samples.astype(np.float64) * np.hanning(n)
    fft = np.abs(np.fft.rfft(win))
    freqs = np.fft.rfftfreq(n, 1.0 / sample_rate)
    mask = (freqs >= FREQ_MIN) & (freqs <= FREQ_MAX)
    if not np.any(mask):
        return None
    idx = np.argmax(fft[mask])
    pf = freqs[mask][idx]
    pm = fft[mask][idx]
    avg = np.mean(fft[mask])
    if avg > 0 and pm / avg < 1.3:
        return None
    return freq_to_note(pf)


def analyze_audio(audio, sample_rate, fps, total_frames, threshold):
    fs = int(sample_rate / fps)
    avail = min(total_frames, len(audio) // fs)
    notes = [None] * total_frames
    nc = 0
    for i in range(avail):
        n = detect_pitch(audio[i * fs : (i + 1) * fs], sample_rate, threshold)
        notes[i] = n
        if n is not None:
            nc += 1
        if (i + 1) % 500 == 0:
            print(f"  分析: {i+1}/{avail}")
    print(f"  音符帧: {nc} ({100*nc/max(avail,1):.1f}%)")

    # 后处理: 填补短间隙 (连续 ≤2 帧的静音用前后音符填补)
    filled = 0
    for i in range(1, total_frames - 1):
        if notes[i] is None:
            # 单帧间隙: 前后都有相同音符则填补
            if notes[i - 1] is not None and notes[i + 1] is not None:
                if notes[i - 1] == notes[i + 1]:
                    notes[i] = notes[i - 1]
                    filled += 1
    for i in range(2, total_frames - 2):
        if notes[i] is None and notes[i - 1] is None and notes[i + 1] is None:
            if notes[i - 2] is not None and notes[i + 2] is not None:
                if notes[i - 2] == notes[i + 2]:
                    notes[i - 1] = notes[i - 2]
                    notes[i] = notes[i - 2]
                    notes[i + 1] = notes[i - 2]
                    filled += 3
    if filled > 0:
        print(f"  间隙填补: {filled} 帧")
    return notes


def build_audio_file(notes, total_frames, fps, instrument, output_path):
    data = bytearray(total_frames)
    for i, n in enumerate(notes):
        if n is not None and 0 <= n <= NOTE_MAX:
            data[i] = (instrument << 5) | (n & 0x1F)
    with open(output_path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<B", VERSION))
        f.write(struct.pack("<I", total_frames))
        f.write(struct.pack("<B", fps))
        f.write(struct.pack("<B", 0))
        f.write(data)
    nc = sum(1 for b in data if b != 0)
    print(f"\n[完成] {output_path}")
    print(f"  帧数: {total_frames}  音符帧: {nc} ({100*nc/total_frames:.1f}%)")
    print(f"  大小: {os.path.getsize(output_path):,} 字节")


def main():
    p = argparse.ArgumentParser(description="视频音频 -> Iron Note Block")
    p.add_argument("video")
    p.add_argument("-o", "--output", default="ba_audio.bin")
    p.add_argument("-f", "--fps", type=int, default=15)
    p.add_argument("-n", "--frames", type=int, default=None)
    p.add_argument(
        "--threshold", type=float, default=200, help="音量阈值 (默认: 200, 越低越敏感)"
    )
    p.add_argument("--instrument", type=int, default=0, choices=range(7))
    p.add_argument("--sample-rate", type=int, default=8000)
    args = p.parse_args()

    if not os.path.exists(args.video):
        print(f"找不到: {args.video}")
        sys.exit(1)

    if args.frames is None:
        r = subprocess.run(
            [
                "ffprobe",
                "-v",
                "quiet",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                args.video,
            ],
            capture_output=True,
            text=True,
        )
        try:
            dur = float(r.stdout.strip())
            args.frames = int(dur * args.fps)
            print(f"视频时长: {dur:.1f}s -> {args.frames} 帧")
        except ValueError:
            print("无法获取时长, 请用 --frames 指定")
            sys.exit(1)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as t:
        wp = t.name
    try:
        extract_audio_wav(args.video, wp, args.sample_rate)
        sr, audio = wavfile.read(wp)
        print(f"WAV: {sr}Hz, {len(audio)} 样本, {len(audio)/sr:.1f}s")
        if audio.dtype == np.int16:
            audio = audio.astype(np.float64)
        elif audio.dtype == np.int32:
            audio = audio.astype(np.float64)
        if audio.ndim > 1:
            audio = np.mean(audio, axis=1)
        notes = analyze_audio(audio, sr, args.fps, args.frames, args.threshold)
        build_audio_file(notes, args.frames, args.fps, args.instrument, args.output)
    finally:
        if os.path.exists(wp):
            os.unlink(wp)


if __name__ == "__main__":
    main()
