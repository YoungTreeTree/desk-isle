#!/usr/bin/env python3
"""Rasterize Xiaomi's official MiSans-Regular.ttf for the DeskIsle screen."""

import argparse
from math import ceil
from pathlib import Path
import struct
import zlib

from PIL import Image, ImageDraw, ImageFont

FONT_SIZE = 32
# At this size MiSans needs 30 px above the baseline and 8 below it.
FONT_HEIGHT = 38
BASELINE = 30
ALPHA_2BIT = bytes((value * 3 + 127) // 255 for value in range(256))
ALPHA_4BIT = bytes((value * 15 + 127) // 255 for value in range(256))

# Fixed labels in widget.c, grouped by their physical pixel size. The Mac
# supplements these strikes with the glyphs used by each dynamic snapshot.
FIXED_LABELS = {
    11: "小时前采集时左右盒最近分钟桌屿MiucsCPUGPU",
    12: "重置时分评分已连接内存正常紧张严重最高温整机功耗CPU°CW",
    13: "上次同步睡眠身体电量静息心率夜间其他会话提醒运行中待审批待回复已完成失败已中断最近分钟最高温整机功耗内存已用",
    14: "暂无压力记录蓝牙设备信息暂不可用未连接正在读取已关闭本机用时分秒待处理运行中内存正常紧张严重桌屿",
    15: "今日本机统计账号订阅剩余额度目标提醒运行中待审批待回复已完成失败已中断已用",
    16: "每周小时步近压力",
    17: "蓝牙设备待处理运行中",
    18: "Mac负载",
    20: "佳明健康",
    21: ">_正在读取健康数据",
    23: "Mac负载",
    24: "",
    25: "",
    27: "Codex",
    28: "通知岛",
    30: "",
    43: "",
    48: "KMBTPE",
    56: "KMBTPE",
}
NUMBERS_AND_PUNCTUATION = " 0123456789.,:%/+-—–…·?×"
# Dynamic strings at these sizes also use this common ASCII set.
ASCII_STRIKES = {12, 13, 14, 15, 17, 21, 24}


def characters():
    result = set(chr(code) for code in range(32, 127))
    result.update("—–…·□✓×，。？！；：、（）【】《》「」『』￥")
    for first in range(0xA1, 0xF8):
        for second in range(0xA1, 0xFF):
            try:
                result.add(bytes((first, second)).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return sorted(result)


def exact_strikes(source):
    records = bytearray()
    masks = bytearray()
    count = 0
    for size, labels in sorted(FIXED_LABELS.items()):
        font = ImageFont.truetype(str(source), size)
        glyphs = set(labels + NUMBERS_AND_PUNCTUATION)
        if size in ASCII_STRIKES:
            glyphs.update(map(chr, range(32, 127)))
        for glyph in sorted(glyphs):
            left, top, right, bottom = font.getbbox(glyph, anchor="ls")
            width, height = right - left, bottom - top
            inset = max(0, -left)
            advance = ceil(max(right, font.getlength(glyph))) + inset
            key = (size << 21) | ord(glyph)
            records.extend(struct.pack("<IIBbbBB", key, len(masks), advance, left + inset, top, width, height))
            count += 1
            if not width or not height:
                continue
            image = Image.new("L", (width, height))
            ImageDraw.Draw(image).text((-left, -top), glyph, font=font, fill=255, anchor="ls")
            levels = image.tobytes().translate(ALPHA_4BIT) + b"\0"
            masks.extend(a | b << 4 for a, b in zip(levels[0::2], levels[1::2]))
    return struct.pack("<H", count) + records + masks


def make_font(source, destination):
    font = ImageFont.truetype(str(source), FONT_SIZE)
    if font.getname() != ("MiSans", "Regular"):
        raise ValueError("Use MiSans-Regular.ttf from Xiaomi's official MiSans download")
    glyphs = characters()
    records = bytearray(struct.pack("<H", len(glyphs)))
    ascii_pixels = bytearray()
    for character in glyphs:
        # MiSans does not include the Japanese middle dot in GB2312.
        glyph = "·" if character == "・" else character
        left, _, right, _ = font.getbbox(glyph, anchor="ls")
        inset = max(0, -left)
        advance = max(right, font.getlength(glyph)) + inset
        image = Image.new("L", (max(FONT_SIZE, ceil(advance)), FONT_HEIGHT))
        ImageDraw.Draw(image).text((inset, BASELINE), glyph, font=font, fill=255, anchor="ls")

        # The stored advance is in 1/128 em units. Keep the bitmap's gray edges.
        records.extend(struct.pack("<HB", ord(character), round(advance * 4)))
        small = image.resize((FONT_SIZE // 2, FONT_HEIGHT // 2), Image.Resampling.LANCZOS)
        levels = small.tobytes().translate(ALPHA_2BIT)
        records.extend(a | b << 2 | c << 4 | d << 6 for a, b, c, d in zip(
            levels[0::4], levels[1::4], levels[2::4], levels[3::4]
        ))
        if 32 <= ord(character) <= 126:
            large = image.resize((FONT_SIZE, FONT_HEIGHT), Image.Resampling.LANCZOS)
            levels = large.tobytes().translate(ALPHA_4BIT)
            ascii_pixels.extend(a | b << 4 for a, b in zip(levels[0::2], levels[1::2]))
    records.extend(ascii_pixels)
    records.extend(exact_strikes(source))
    destination.write_bytes(struct.pack("<I", len(records)) + zlib.compress(records, 9))
    print(f"{len(glyphs)} glyphs, {destination.stat().st_size} compressed bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    make_font(args.source, args.destination)
