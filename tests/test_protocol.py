"""Verify the actual host and firmware implementations agree."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from send_card import CardSpec, HEADER, discover, make_packet, send


class FragmentedSerial:
    """Deliver a greeting/ack across read timeouts, as a real port may do."""

    def __init__(self):
        self.parts = iter([
            b"DESKIS", b"LE 1 1 512 288 JPEG 98304 3000\n",
            b"DESKISLE_ACK 99 0 0\n", b"DESKISLE_ACK 1 ", b"0 35\n",
        ])
        self.written = b""

    def read_until(self, terminator, size):
        return next(self.parts)

    def write(self, packet):
        self.written = packet
        return len(packet)


def main():
    port = FragmentedSerial()
    spec = discover(port)
    assert spec == CardSpec(1, 512, 288, 98304, 3000)
    jpeg = b"\xff\xd8\x12\x34\xff\xd9"
    frame = make_packet(spec, 1, jpeg)
    assert send(port, frame, 1) == 35 and port.written == frame
    corrupt = make_packet(spec, 2, jpeg)[:-1] + b"\x00"
    keepalive = make_packet(spec, 3)
    maximum = make_packet(spec, 4, b"\xff\xd8" + bytes(spec.max_bytes - 2))
    oversize = HEADER.pack(b"ISLE", 1, 1, 1, 5, spec.max_bytes + 1, 0, 512, 288)
    legacy = HEADER.pack(b"MIUC", 1, 1, 0, 6, 6, 0, 720, 1280) + jpeg
    pixels = spec.width * spec.height
    runs, tail = divmod(pixels - 510, 255)
    rle = bytes([255, 0, 255, 128]) + bytes([255, 255]) * runs + bytes([tail, 255])
    raw = bytes([0, 128, 255, 1]) * (pixels // 4)

    def alpha_packet(sequence, mask, jpeg_size=len(jpeg), *, width=512, height=288, card_id=1):
        payload = jpeg + mask + struct.pack("<I", jpeg_size)
        return HEADER.pack(b"ISLE", 1, 5, card_id, sequence, len(payload), zlib.crc32(payload), width, height) + payload

    large_raw = bytes([0, 128, 255, 1]) * (704 * 400 // 4)
    data = (b"garbageISLE" + legacy + oversize + frame + corrupt + keepalive + maximum
            + alpha_packet(7, rle) + alpha_packet(8, rle, 0) + alpha_packet(9, raw)
            + alpha_packet(10, large_raw, width=704, height=400))
    widget = b'{"v":1,"data":{"running":0,"waiting":0,"others":[]}}'
    control = HEADER.pack(b"ISLE", 1, 6, 0x8003, 11, len(widget), zlib.crc32(widget), 0, 0) + widget
    wallpaper = b"\xff\xd8" + bytes(337 * 1024) + b"\xff\xd9"
    control += HEADER.pack(b"ISLE", 1, 7, 0, 12, 512 * 1024 + 1, 0, 720, 1280)
    control += HEADER.pack(b"ISLE", 1, 7, 0, 13, len(wallpaper), 0, 1280, 721)
    control += HEADER.pack(b"ISLE", 1, 7, 0, 14, len(wallpaper), zlib.crc32(wallpaper), 720, 1280) + wallpaper
    glyphs = struct.pack("<HIIBbbBB", 1, (24 << 21) | ord("字"), 0, 24, 0, -18, 2, 2) + bytes([0x6f, 0xf3])
    glyph_packet = struct.pack("<H", len(widget)) + widget + glyphs
    control += HEADER.pack(b"ISLE", 1, 12, 0x8003, 19, 256 * 1024 + 1, 0, 0, 0)
    control += HEADER.pack(b"ISLE", 1, 12, 0x8003, 20, len(glyph_packet), zlib.crc32(glyph_packet), 1, 0)
    control += HEADER.pack(b"ISLE", 1, 12, 0x8003, 21, len(glyph_packet), zlib.crc32(glyph_packet), 0, 0) + glyph_packet
    control += HEADER.pack(b"ISLE", 1, 7, 0, 22, len(jpeg), zlib.crc32(jpeg), 1280, 720) + jpeg
    picture_runs, picture_tail = divmod(80 * 80 - 510, 255)
    picture_rle = bytes([255, 0, 255, 128]) + bytes([255, 255]) * picture_runs + bytes([picture_tail, 255])
    picture_raw = bytes([0, 128, 255, 1]) * (320 * 320 // 4)
    control += alpha_packet(98, picture_rle, width=80, height=80, card_id=0x8003)
    control += alpha_packet(99, picture_rle, width=80, height=160, card_id=0x8100)
    control += alpha_packet(23, picture_rle, width=80, height=80, card_id=0x8100)
    control += alpha_packet(24, picture_raw, width=320, height=320, card_id=0x81ff)
    backlight = bytes([42, 1])
    control += HEADER.pack(b"ISLE", 1, 13, 0, 25, 1, 0, 0, 0) + backlight[:1]
    control += HEADER.pack(b"ISLE", 1, 13, 1, 26, 2, zlib.crc32(backlight), 0, 0) + backlight
    control += HEADER.pack(b"ISLE", 1, 13, 0, 27, 2, zlib.crc32(backlight), 0, 0) + backlight
    control += HEADER.pack(b"ISLE", 1, 13, 0, 28, 2, zlib.crc32(backlight), 0, 0) + bytes([42, 0])

    def pet_packet(kind, sequence, payload, *, card_id=1, width=0):
        return HEADER.pack(b"ISLE", 1, kind, card_id, sequence, len(payload), zlib.crc32(payload), width, 0) + payload

    data += pet_packet(8, 95, bytes(8), card_id=2)
    data += pet_packet(9, 96, bytes(96 * 1024 + 5))
    data += pet_packet(11, 97, b'{}', width=512)
    for kind, payload in enumerate((bytes(8), bytes(96 * 1024 + 4), b'', b'{"now":42}'), 8):
        data += pet_packet(kind, kind + 7, payload)
    identity = struct.pack("<II", 12345, 0x12345678)
    data += pet_packet(14, 95, identity[:-1]) + pet_packet(14, 96, identity, card_id=2)
    data += pet_packet(15, 97, b"\x00") + pet_packet(15, 98, b"", width=512)
    data += pet_packet(14, 29, identity) + pet_packet(15, 30, b"")
    for i, payload in enumerate((bytes(8), bytes(32 * 1024 + 4), b"", bytes(2), b"", b"")):
        # Same kinds on the animation channel, wrong ID, and oversized payloads must be ignored.
        control += pet_packet(16 + i, 200 + i, payload, card_id=0x8008)
        control += pet_packet(16 + i, 100 + i, payload, card_id=0x8007)
    for i, payload in enumerate((bytes(8), bytes(32 * 1024 + 4), b"", bytes(1), b"", b"")):
        control += pet_packet(22 + i, 210 + i, payload, card_id=0x8007)
        control += pet_packet(22 + i, 110 + i, payload, card_id=0x8100)
    with tempfile.TemporaryDirectory() as temp:
        exe = Path(temp) / "protocol-test"
        subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-I", "main/transport", "-I", "shared/include",
                        "main/transport/protocol.c", "main/transport/uart_link.c", "tests/protocol_test.c", "-o", str(exe)],
                       cwd=ROOT, check=True)
        subprocess.run([str(exe), str(len(data))], input=data + control, check=True)
    print("PASS fragmented greeting and matching acknowledgement")


if __name__ == "__main__":
    main()
