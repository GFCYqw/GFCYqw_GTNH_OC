"""
Bad Apple - 全息帧提取脚本
===========================
将视频转换为 OpenComputers 全息投影仪可播放的 RLE 压缩格式。

用法:
    python extract_frames.py <视频> [选项]

选项:
    --output, -o     输出文件 (默认: ba_frames.bin)
    --fps, -f        目标帧率 (默认: 15)
    --test           生成测试图案 (无需视频)
"""

import argparse
import os
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# =============================================================================
# 常量
# =============================================================================

MAGIC = b"BAHL"
VERSION = 1
WIDTH = 48  # 全息投影仪 X 分辨率
HEIGHT = 32  # 全息投影仪 Z 分辨率 (我们投影在 XZ 平面)

# Tier 2 全息投影仪有 3 色调色板 (0=关, 1/2/3=三色)
# 量化阈值: 将 0-255 灰度映射到 0-3
THRESHOLDS = [64, 128, 192]  # <=64→0, <=128→1, <=192→2, >192→3


# =============================================================================
# 视频处理
# =============================================================================


def check_ffmpeg() -> bool:
    """检查 FFmpeg 是否可用"""
    try:
        result = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True)
        return result.returncode == 0
    except FileNotFoundError:
        return False


def extract_frames_ffmpeg(video_path: str, output_dir: str, fps: int) -> int:
    """用 FFmpeg 从视频中提取帧, 缩放至 48×32, 返回帧数"""
    if not check_ffmpeg():
        print("\n" + "=" * 55)
        print("[错误] 未找到 FFmpeg!")
        print("")
        print("  FFmpeg 是提取视频帧所必需的工具。")
        print("  请按以下步骤安装:")
        print("")
        print("  Windows (推荐 winget):")
        print("    winget install ffmpeg")
        print("")
        print("  或手动下载:")
        print("    https://ffmpeg.org/download.html")
        print("")
        print("  安装后请重新打开终端并重试。")
        print("=" * 55)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        video_path,
        "-vf",
        f"fps={fps},scale={WIDTH}:{HEIGHT}",
        f"{output_dir}/frame_%05d.png",
    ]

    print(f"[FFmpeg] 正在提取帧 (FPS={fps}, {WIDTH}×{HEIGHT})...")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"[错误] FFmpeg 运行失败:\n{result.stderr}")
        sys.exit(1)

    # 统计帧数
    frame_files = sorted(Path(output_dir).glob("frame_*.png"))
    print(f"[FFmpeg] 提取完成, 共 {len(frame_files)} 帧")
    return len(frame_files)


# =============================================================================
# 图像量化
# =============================================================================


def quantize_frame(img: Image.Image) -> np.ndarray:
    """将单帧图像量化为 0-3 的值, 返回 flatten 的一维数组 (按行扫描)"""
    gray = img.convert("L")  # 灰度
    arr = np.array(gray)

    # 用 digitize 将像素值映射到 0-3
    # 0: [0, 64], 1: (64, 128], 2: (128, 192], 3: (192, 255]
    quantized = np.digitize(arr, THRESHOLDS).astype(np.uint8)

    # flatten: 按行优先 (C order), 即 z * WIDTH + x
    return quantized.flatten()


# =============================================================================
# RLE 压缩
# =============================================================================


def rle_encode(values: np.ndarray) -> bytes:
    """
    RLE 编码: 每字节 = (value << 6) | (count - 1)

    参数:
        values: 一维 uint8 数组, 每个元素 0-3

    返回:
        bytes: RLE 压缩数据
    """
    if len(values) == 0:
        return b""

    result = bytearray()
    prev = int(values[0])
    count = 1

    for i in range(1, len(values)):
        v = int(values[i])
        if v == prev and count < 64:
            count += 1
        else:
            result.append((prev << 6) | (count - 1))
            prev = v
            count = 1

    # 最后一个 run
    result.append((prev << 6) | (count - 1))

    return bytes(result)


# =============================================================================
# 文件打包
# =============================================================================


def build_binary(frames_dir: str, output_path: str, frame_count: int, fps: int):
    """
    打包帧数据为二进制文件。

    文件格式:
        [Header 11B] [OffsetTable frame_count×4B] [FrameData...]

    每帧: [Length uint16 LE] [RLE bytes...]
    """
    frame_files = sorted(Path(frames_dir).glob("frame_*.png"))

    if len(frame_files) != frame_count:
        print(f"[警告] 帧文件数 ({len(frame_files)}) 与预期 ({frame_count}) 不符")

    actual_count = len(frame_files)

    with open(output_path, "wb") as f:
        # ---- 文件头 (11 字节) ----
        f.write(MAGIC)  # 4B magic
        f.write(struct.pack("<B", VERSION))  # 1B version
        f.write(struct.pack("<I", actual_count))  # 4B frame count
        f.write(struct.pack("<B", fps))  # 1B fps
        f.write(struct.pack("<B", 0))  # 1B reserved

        # ---- 偏移表占位 ----
        offset_table_pos = f.tell()
        f.write(b"\x00" * (actual_count * 4))

        # ---- 逐帧写入 ----
        offsets = []
        total_rle_bytes = 0

        for i in range(actual_count):
            offsets.append(f.tell())

            img = Image.open(frame_files[i])
            vals = quantize_frame(img)
            rle_data = rle_encode(vals)
            total_rle_bytes += len(rle_data)

            # 帧长度 (uint16 LE) + RLE 数据
            f.write(struct.pack("<H", len(rle_data)))
            f.write(rle_data)

            if (i + 1) % 500 == 0:
                print(f"  处理进度: {i+1}/{actual_count} 帧")

        # ---- 回填偏移表 ----
        f.seek(offset_table_pos)
        for off in offsets:
            f.write(struct.pack("<I", off))

    # ---- 统计信息 ----
    file_size = os.path.getsize(output_path)
    avg_rle = total_rle_bytes / actual_count if actual_count > 0 else 0
    raw_size = WIDTH * HEIGHT * actual_count  # 每像素 1 字节 (0-3)

    print(f"\n[完成] 输出文件: {output_path}")
    print(f"  总帧数:     {actual_count}")
    print(f"  帧率:       {fps} FPS")
    print(f"  时长:       {actual_count / fps:.1f} 秒")
    print(f"  文件大小:   {file_size:,} 字节 ({file_size/1024:.1f} KB)")
    print(f"  平均RLE:    {avg_rle:.1f} 字节/帧")
    print(f"  压缩率:     {file_size / max(raw_size, 1) * 100:.1f}% (相对原始 4值位图)")


# =============================================================================
# 测试图案生成 (无需视频文件即可测试)
# =============================================================================


def generate_test_pattern(output_path: str, fps: int = 15, num_frames: int = 90):
    """
    生成测试图案: 一个白色方块在黑色背景上移动。
    用于验证格式和播放器是否正常工作。
    """
    print(f"[测试] 生成测试图案: {num_frames} 帧, {fps} FPS")

    temp_dir = "frames_test_temp"
    os.makedirs(temp_dir, exist_ok=True)

    for i in range(num_frames):
        # 创建一个 48×32 的黑色图像
        arr = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)

        # 白色方块位置随帧移动
        t = i / num_frames
        cx = int(16 + 20 * np.sin(t * 2 * np.pi * 2))  # 左右摆动
        cy = int(16 + 10 * np.cos(t * 2 * np.pi * 3))  # 上下摆动

        # 绘制白色方块 (8×8)
        half = 4
        x0 = max(0, cx - half)
        x1 = min(WIDTH, cx + half)
        y0 = max(0, cy - half)
        y1 = min(HEIGHT, cy + half)
        arr[y0:y1, x0:x1] = 3  # 白色

        # 绘制灰色边框 (1px)
        x0_b = max(0, cx - half - 1)
        x1_b = min(WIDTH, cx + half + 1)
        y0_b = max(0, cy - half - 1)
        y1_b = min(HEIGHT, cy + half + 1)
        # 浅灰边框
        arr[max(0, y0 - 1) : y0, x0_b:x1_b] = 2
        arr[y1 : min(HEIGHT, y1 + 1), x0_b:x1_b] = 2
        arr[y0_b:y1_b, max(0, x0 - 1) : x0] = 2
        arr[y0_b:y1_b, x1 : min(WIDTH, x1 + 1)] = 2

        img = Image.fromarray(arr * 85, mode="L")  # 可视化: 0→0, 1→85, 2→170, 3→255
        img.save(f"{temp_dir}/frame_{i+1:05d}.png")

    build_binary(temp_dir, output_path, num_frames, fps)

    # 清理
    import shutil

    shutil.rmtree(temp_dir)


# =============================================================================
# 主入口
# =============================================================================


def main():
    parser = argparse.ArgumentParser(
        description="Bad Apple 全息投影仪视频预处理工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
    python extract_frames.py bad_apple.mp4
    python extract_frames.py bad_apple.mp4 -f 20 -o ba_frames.bin
    python extract_frames.py --test -o test_frames.bin
        """,
    )
    parser.add_argument("video", nargs="?", default=None, help="输入视频文件路径")
    parser.add_argument(
        "--output",
        "-o",
        default="ba_frames.bin",
        help="输出 .bin 文件路径 (默认: ba_frames.bin)",
    )
    parser.add_argument("--fps", "-f", type=int, default=15, help="目标帧率 (默认: 15)")
    parser.add_argument("--test", action="store_true", help="生成测试图案而非处理视频")

    args = parser.parse_args()

    # ---- 测试模式 ----
    if args.test:
        generate_test_pattern(args.output, args.fps)
        return

    # ---- 视频处理模式 ----
    if not args.video:
        parser.error("请提供视频文件路径, 或使用 --test 生成测试图案")

    if not os.path.exists(args.video):
        print(f"[错误] 找不到视频文件: {args.video}")
        sys.exit(1)

    # 提取帧
    frame_count = extract_frames_ffmpeg(args.video, "frames_temp", args.fps)

    if frame_count == 0:
        print("[错误] 未提取到任何帧")
        sys.exit(1)

    # 打包
    build_binary("frames_temp", args.output, frame_count, args.fps)

    # 清理
    import shutil

    shutil.rmtree("frames_temp")
    print("[清理] 已删除临时帧图片目录")


if __name__ == "__main__":
    main()
