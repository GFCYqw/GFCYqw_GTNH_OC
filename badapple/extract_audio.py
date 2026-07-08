"""
Bad Apple - 视频音频转 Iron Note Block 音符脚本
================================================
从视频文件直接提取音频, 用 FFT 逐帧分析音高,
映射为 Iron Note Block 可播放的音符序列。

用法:
    python extract_audio.py <视频文件> [选项]

选项:
    --output, -o     输出 .bin 文件路径 (默认: ba_audio.bin)
    --fps, -f        目标帧率, 需与视频处理一致 (默认: 15)
    --frames, -n     总帧数 (默认: 自动从视频时长计算)
    --threshold      音量阈值, 低于此值视为静音 (默认: 500)
    --instrument     Iron Note Block 乐器号 0-6 (默认: 0=harp)

输出格式 (ba_audio.bin):
    文件头 (11 字节):
        Magic:   "BAAU"  (4 bytes)
        Version: uint8   (1 byte)
        Frames:  uint32  (4 bytes, little-endian)
        FPS:     uint8   (1 byte)
        Reserved: uint8  (1 byte)

    音符数据 (frames 字节):
        每帧 1 字节:
          0x00 = 静音
          0x01-0xFF = (instrument << 5) | note
            instrument: 0-6
            note: 0-24 (C4 ~ C6, 共 25 个半音)

Iron Note Block 参数:
    instrument: 0=harp, 1=double bass, 2=snare, 3=hi-hat,
                4=bass drum, 5=bell, 6=flute
    note: 0-24
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile

# =============================================================================
# 常量
# =============================================================================

MAGIC = b"BAAU"
VERSION = 1

NOTE_MIN = 0
NOTE_MAX = 24

BASE_FREQ = 261.63  # C4 in Hz, iron note 0

FREQ_MIN = 80
FREQ_MAX = 2000

# =============================================================================
# 音频提取
# =============================================================================

def extract_audio_wav(video_path: str, output_wav: str, sample_rate: int = 8000):
    """用 FFmpeg 从视频提取单声道 WAV 音频"""
    cmd = [
        "ffmpeg", "-y",
        "-i", video_path,
        "-ac", "1",
        "-ar", str(sample_rate),
        "-f", "wav",
        output_wav
    ]
    print(f"[FFmpeg] 正在提取音频 (单声道, {sample_rate}Hz)...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[错误] FFmpeg 提取音频失败:\n{result.stderr}")
        sys.exit(1)
    print(f"[FFmpeg] 完成, {os.path.getsize(output_wav):,} 字节")


# =============================================================================
# 音高检测
# =============================================================================

def freq_to_note(freq: float) -> int:
    """频率 → Iron Note Block 音符号 (0-24), C4=0"""
    if freq <= 0:
        return 0
    midi_note = 69 + 12 * np.log2(freq / 440.0)
    iron_note = int(round(midi_note - 60))
    return max(NOTE_MIN, min(NOTE_MAX, iron_note))


def detect_pitch(samples: np.ndarray, sample_rate: int,
                 threshold: float) -> int | None:
    """检测音频片段的主频率, 返回 0-24 或 None (静音)"""
    n = len(samples)
    if n < 16:
        return None

    rms = np.sqrt(np.mean(samples.astype(np.float64) ** 2))
    if rms < threshold:
        return None

    windowed = samples.astype(np.float64) * np.hanning(n)
    fft = np.abs(np.fft.rfft(windowed))
    freqs = np.fft.rfftfreq(n, 1.0 / sample_rate)

    mask = (freqs >= FREQ_MIN) & (freqs <= FREQ_MAX)
    if not np.any(mask):
        return None

    peak_idx = np.argmax(fft[mask])
    peak_freq = freqs[mask][peak_idx]
    peak_mag = fft[mask][peak_idx]

    avg_mag = np.mean(fft[mask])
    if avg_mag > 0 and peak_mag / avg_mag < 2.0:
        return None

    return freq_to_note(peak_freq)


def analyze_audio(audio: np.ndarray, sample_rate: int, fps: int,
                  total_frames: int, threshold: float) -> list:
    """逐帧分析音频, 返回 frame_notes 数组 (0-24 或 None)"""
    frame_samples = int(sample_rate / fps)
    total_available = len(audio) // frame_samples
    actual_frames = min(total_frames, total_available)

    if actual_frames < total_frames:
        print(f"[警告] 音频长度仅够 {actual_frames} 帧 (需要 {total_frames})")

    notes = [None] * total_frames
    note_count = 0

    for i in range(actual_frames):
        start = i * frame_samples
        end = start + frame_samples
        note = detect_pitch(audio[start:end], sample_rate, threshold)
        notes[i] = note
        if note is not None:
            note_count += 1
        if (i + 1) % 500 == 0:
            print(f"  分析: {i+1}/{actual_frames} 帧")

    pct = 100 * note_count / max(actual_frames, 1)
    print(f"  检测到 {note_count} 个音符帧 ({pct:.1f}%)")
    return notes


# =============================================================================
# 文件生成
# =============================================================================

def build_audio_file(notes: list, total_frames: int, fps: int,
                     instrument: int, output_path: str):
    """生成 ba_audio.bin"""
    frame_data = bytearray(total_frames)
    for i, note in enumerate(notes):
        if note is not None and 0 <= note <= NOTE_MAX:
            frame_data[i] = (instrument << 5) | (note & 0x1F)

    with open(output_path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<B", VERSION))
        f.write(struct.pack("<I", total_frames))
        f.write(struct.pack("<B", fps))
        f.write(struct.pack("<B", 0))
        f.write(frame_data)

    note_count = sum(1 for b in frame_data if b != 0)

    note_dist = {}
    for b in frame_data:
        if b != 0:
            n = b & 0x1F
            note_dist[n] = note_dist.get(n, 0) + 1

    print(f"\n[完成] 输出文件: {output_path}")
    print(f"  总帧数:     {total_frames}")
    pct = 100 * note_count / total_frames
    print(f"  有音符帧:   {note_count} / {total_frames} ({pct:.1f}%)")
    print(f"  文件大小:   {os.path.getsize(output_path):,} 字节")
    if note_dist:
        top = sorted(note_dist.items(), key=lambda x: -x[1])[:5]
        items = [f"C4+{n}({c}次)" for n, c in top]
        print(f"  最常见音符: {', '.join(items)}")


# =============================================================================
# 主入口
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="视频音频 -> Iron Note Block 音符转换工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
    python extract_audio.py "Bad Apple.mp4"
    python extract_audio.py "Bad Apple.mp4" -f 15 --threshold 300
    python extract_audio.py "Bad Apple.mp4" --instrument 6
        """
    )
    parser.add_argument("video", help="输入视频文件路径")
    parser.add_argument("--output", "-o", default="ba_audio.bin",
                        help="输出 .bin 文件路径 (默认: ba_audio.bin)")
    parser.add_argument("--fps", "-f", type=int, default=15,
                        help="目标帧率 (默认: 15)")
    parser.add_argument("--frames", "-n", type=int, default=None,
                        help="总帧数 (默认: 自动计算)")
    parser.add_argument("--threshold", type=float, default=500,
                        help="音量阈值 (默认: 500)")
    parser.add_argument("--instrument", type=int, default=0,
                        choices=range(7),
                        help="Iron Note Block 乐器 0-6 (默认: 0=harp)")
    parser.add_argument("--sample-rate", type=int, default=8000,
                        help="音频采样率 Hz (默认: 8000)")

    args = parser.parse_args()

    if not os.path.exists(args.video):
        print(f"[错误] 找不到视频文件: {args.video}")
        sys.exit(1)

    if args.frames is None:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries",
             "format=duration", "-of", "csv=p=0", args.video],
            capture_output=True, text=True
        )
        try:
            duration = float(result.stdout.strip())
            args.frames = int(duration * args.fps)
            print(f"[探测] 视频时长: {duration:.1f}s"
                  f" -> {args.frames} 帧 @ {args.fps}fps")
        except ValueError:
            print("[错误] 无法获取视频时长, 请用 --frames 手动指定")
            sys.exit(1)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name

    try:
        extract_audio_wav(args.video, wav_path, args.sample_rate)

        sample_rate, audio = wavfile.read(wav_path)
        duration = len(audio) / sample_rate
        print(f"[WAV] {sample_rate}Hz, {len(audio)} 样本, {duration:.1f}s")

        if audio.dtype == np.int16:
            audio = audio.astype(np.float64)
        elif audio.dtype == np.int32:
            audio = audio.astype(np.float64)
        if audio.ndim > 1:
            audio = np.mean(audio, axis=1)

        notes = analyze_audio(audio, sample_rate, args.fps,
                              args.frames, args.threshold)
        build_audio_file(notes, args.frames, args.fps,
                         args.instrument, args.output)
    finally:
        if os.path.exists(wav_path):
            os.unlink(wav_path)


if __name__ == "__main__":
    main()
    1: 0,  # Bright Acoustic Piano → harp
    2: 0,  # Electric Grand Piano → harp
    3: 0,  # Honky-tonk Piano → harp
    4: 0,  # Electric Piano 1 → harp
    5: 0,  # Electric Piano 2 → harp
    6: 0,  # Harpsichord → harp
    7: 0,  # Clavinet → harp
    8: 0,  # Celesta → harp (bell-like but...)
    9: 0,  # Glockenspiel → harp
    10: 0,  # Music Box → harp
    11: 0,  # Vibraphone → harp
    12: 0,  # Marimba → harp
    13: 0,  # Xylophone → harp
    14: 0,  # Tubular Bells → harp
    15: 0,  # Dulcimer → harp
    # Bass range
    32: 1,  # Acoustic Bass → double bass
    33: 1,  # Electric Bass (finger) → double bass
    34: 1,  # Electric Bass (pick) → double bass
    35: 1,  # Fretless Bass → double bass
    36: 1,  # Slap Bass 1 → double bass
    37: 1,  # Slap Bass 2 → double bass
    38: 1,  # Synth Bass 1 → double bass
    39: 1,  # Synth Bass 2 → double bass
    # Strings/Synth → harp
    48: 0,  # String Ensemble 1 → harp
    49: 0,  # String Ensemble 2 → harp
    50: 0,  # Synth Strings 1 → harp
    51: 0,  # Synth Strings 2 → harp
    52: 0,  # Choir Aahs → harp
    53: 0,  # Voice Oohs → harp
    54: 0,  # Synth Voice → harp
    55: 0,  # Orchestra Hit → harp
    # Brass/Wind → flute
    56: 6,  # Trumpet → flute
    57: 6,  # Trombone → flute
    58: 6,  # Tuba → flute
    59: 6,  # Muted Trumpet → flute
    60: 6,  # French Horn → flute
    61: 6,  # Brass Section → flute
    62: 6,  # Synth Brass 1 → flute
    63: 6,  # Synth Brass 2 → flute
    64: 6,  # Soprano Sax → flute
    65: 6,  # Alto Sax → flute
    66: 6,  # Tenor Sax → flute
    67: 6,  # Baritone Sax → flute
    68: 6,  # Oboe → flute
    69: 6,  # English Horn → flute
    70: 6,  # Bassoon → flute
    71: 6,  # Clarinet → flute
    72: 6,  # Piccolo → flute
    73: 6,  # Flute → flute
    74: 6,  # Recorder → flute
    75: 6,  # Pan Flute → flute
    76: 6,  # Blown Bottle → flute
    77: 6,  # Shakuhachi → flute
    78: 6,  # Whistle → flute
    79: 6,  # Ocarina → flute
    # Synth Lead → harp
    80: 0,  # Lead 1 (square) → harp
    81: 0,  # Lead 2 (sawtooth) → harp
    82: 0,  # Lead 3 (calliope) → harp
    83: 0,  # Lead 4 (chiff) → harp
    84: 0,  # Lead 5 (charang) → harp
    85: 0,  # Lead 6 (voice) → harp
    86: 0,  # Lead 7 (fifths) → harp
    87: 0,  # Lead 8 (bass+lead) → harp
    # Synth Pad → harp
    88: 0,  # Pad 1 (new age) → harp
    89: 0,  # Pad 2 (warm) → harp
    90: 0,  # Pad 3 (polysynth) → harp
    91: 0,  # Pad 4 (choir) → harp
    92: 0,  # Pad 5 (bowed) → harp
    93: 0,  # Pad 6 (metallic) → harp
    94: 0,  # Pad 7 (halo) → harp
    95: 0,  # Pad 8 (sweep) → harp
}


def map_instrument(midi_program: int) -> int:
    """MIDI 乐器号 → Iron Note Block 乐器号 (0-6)"""
    return MIDI_INSTRUMENT_MAP.get(midi_program, 0)  # 默认 harp


def map_note(midi_note: int, base_octave: int = 0) -> int:
    """
    MIDI 音符号 → Iron Note Block 音符号 (0-24)

    Iron Note Block 的 0-24 覆盖约 2 个八度。
    将 MIDI 音符映射到这个范围 (循环)。
    """
    # MIDI note 0 = C-1, note 60 = C4 (middle C)
    # Iron note block notes: 0 = F#0, each +1 = +1 semitone
    # 映射: 用 base_octave * 12 作为基准偏移
    base = base_octave * 12
    note = (midi_note - base) % 25
    return max(0, min(24, note))


def find_best_track(mid: mido.MidiFile) -> int:
    """找到第一个包含音符事件的音轨"""
    for i, track in enumerate(mid.tracks):
        for msg in track:
            if msg.type == "note_on" and msg.velocity > 0:
                return i
    return 0


def extract_notes(
    mid: mido.MidiFile, track_idx: int, fps: int, total_frames: int, base_octave: int
):
    """
    从 MIDI 提取音符, 量化到帧。

    返回: list[tuple[int, int, int]]  # [(frame_idx, instrument, note), ...]
    """
    track = mid.tracks[track_idx]

    # 计算总时长 (秒)
    total_ticks = 0
    tempo = 500000  # 默认 120 BPM (微秒/拍)
    ticks_per_beat = mid.ticks_per_beat

    # 先扫描一遍获取 tempo 变化和总时长
    current_tempo = tempo
    events = []  # (absolute_tick, msg)

    abs_tick = 0
    for msg in track:
        abs_tick += msg.time
        if msg.type == "set_tempo":
            current_tempo = msg.tempo
        elif msg.type == "note_on" and msg.velocity > 0:
            events.append((abs_tick, current_tempo, msg))
        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            events.append((abs_tick, current_tempo, msg))

    total_ticks = abs_tick

    # 将 tick 转为秒 (简化: 使用平均 tempo)
    # 更准确的做法是逐段计算, 但这里简化处理
    seconds_per_tick = tempo / (ticks_per_beat * 1_000_000)

    # 收集活跃音符
    frame_time = 1.0 / fps
    frame_notes = defaultdict(list)  # frame_idx → [(instrument, note)]

    active_notes = {}  # note → (instrument, start_tick)

    # 重新遍历
    abs_tick = 0
    current_tempo = tempo
    for msg in track:
        abs_tick += msg.time

        if msg.type == "set_tempo":
            current_tempo = msg.tempo

        elif msg.type == "note_on" and msg.velocity > 0:
            active_notes[msg.note] = (
                map_instrument(msg.channel),
                abs_tick,
                current_tempo,
            )

        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            if msg.note in active_notes:
                instrument, start_tick, start_tempo = active_notes.pop(msg.note)
                # 计算起始帧
                start_sec = start_tick * (start_tempo / (ticks_per_beat * 1_000_000))
                frame = int(start_sec / frame_time)
                if 0 <= frame < total_frames:
                    note = map_note(msg.note, base_octave)
                    frame_notes[frame].append((instrument, note))

    # 每帧只保留第一个音符 (Iron Note Block 是单音的)
    result = []
    for frame in range(total_frames):
        if frame_notes[frame]:
            instr, note = frame_notes[frame][0]  # 取第一个
            result.append((frame, instr, note))
        # 静音帧不记录

    return result


def build_audio_file(notes: list, total_frames: int, fps: int, output_path: str):
    """生成 ba_audio.bin 文件"""
    # 初始化: 全部静音 (0x00)
    frame_data = bytearray(total_frames)  # 全部初始化为 0

    for frame_idx, instrument, note in notes:
        if 0 <= frame_idx < total_frames:
            frame_data[frame_idx] = (instrument << 5) | (note & 0x1F)

    with open(output_path, "wb") as f:
        # Header
        f.write(MAGIC)
        f.write(struct.pack("<B", VERSION))
        f.write(struct.pack("<I", total_frames))
        f.write(struct.pack("<B", fps))
        f.write(struct.pack("<B", 0))

        # 音符数据
        f.write(frame_data)

    note_count = sum(1 for b in frame_data if b != 0)
    print(f"\n[完成] 输出文件: {output_path}")
    print(f"  总帧数:     {total_frames}")
    print(
        f"  有音符帧:   {note_count} / {total_frames} ({100*note_count/total_frames:.1f}%)"
    )
    print(f"  文件大小:   {os.path.getsize(output_path)} 字节")


def main():
    parser = argparse.ArgumentParser(
        description="MIDI → Iron Note Block 音频转换工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
    python extract_audio.py bad_apple.mid
    python extract_audio.py bad_apple.mid -f 15 -n 3286
    python extract_audio.py bad_apple.mid -t 1 --base-octave 3
        """,
    )
    parser.add_argument("midi", help="输入 MIDI 文件路径")
    parser.add_argument(
        "--output",
        "-o",
        default="ba_audio.bin",
        help="输出 .bin 文件路径 (默认: ba_audio.bin)",
    )
    parser.add_argument(
        "--fps", "-f", type=int, default=15, help="目标帧率, 需与视频一致 (默认: 15)"
    )
    parser.add_argument(
        "--frames",
        "-n",
        type=int,
        default=3286,
        help="总帧数, 需与视频一致 (默认: 3286)",
    )
    parser.add_argument(
        "--track", "-t", type=int, default=-1, help="MIDI 音轨索引 (默认: -1=自动选择)"
    )
    parser.add_argument(
        "--base-octave",
        type=int,
        default=4,
        help="基准八度偏移 (默认: 4, MIDI C4→iron note 0)",
    )

    args = parser.parse_args()

    if not os.path.exists(args.midi):
        print(f"[错误] 找不到 MIDI 文件: {args.midi}")
        sys.exit(1)

    print(f"[MIDI] 加载文件: {args.midi}")
    mid = mido.MidiFile(args.midi)
    print(f"  类型: {mid.type}, 拍速: {mid.ticks_per_beat} ticks/beat")
    print(f"  音轨数: {len(mid.tracks)}")

    # 选择音轨
    if args.track >= 0:
        track_idx = args.track
    else:
        track_idx = find_best_track(mid)
    print(f"  使用音轨: {track_idx}")

    # 提取音符
    notes = extract_notes(mid, track_idx, args.fps, args.frames, args.base_octave)

    # 生成文件
    build_audio_file(notes, args.frames, args.fps, args.output)


if __name__ == "__main__":
    main()
