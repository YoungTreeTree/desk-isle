#!/usr/bin/env python3
"""Send baseline JPEG frames to DeskIsle over the board's native USB port."""
import argparse
from dataclasses import dataclass
from pathlib import Path
import struct
import time
import zlib

VERSION = 1
FRAME = 1
KEEPALIVE = 2
HEADER = struct.Struct("<4sBBHIIIHH")


@dataclass(frozen=True)
class CardSpec:
    slot: int
    width: int
    height: int
    max_bytes: int
    lease_ms: int

    @classmethod
    def from_line(cls, line: bytes):
        fields = line.split()
        if not fields or fields[0] != b"DESKISLE":
            return None
        if len(fields) != 8 or fields[1] != b"1" or fields[5] != b"JPEG":
            raise ValueError("Unsupported DeskIsle protocol or image format")
        slot, width, height = map(int, fields[2:5])
        max_bytes, lease_ms = map(int, fields[6:8])
        if not (0 < slot <= 65535 and 0 < width <= 65535 and 0 < height <= 65535
                and max_bytes >= 4 and lease_ms > 0):
            raise ValueError("Invalid DeskIsle card specification")
        return cls(slot, width, height, max_bytes, lease_ms)


def make_packet(spec: CardSpec, sequence: int, jpeg: bytes | None = None) -> bytes:
    if jpeg is None:
        return HEADER.pack(b"ISLE", VERSION, KEEPALIVE, spec.slot, sequence, 0, 0, 0, 0)
    if not 4 <= len(jpeg) <= spec.max_bytes or not jpeg.startswith(b"\xff\xd8"):
        raise ValueError("Expected a JPEG within the device's frame size limit")
    return HEADER.pack(b"ISLE", VERSION, FRAME, spec.slot, sequence, len(jpeg),
                       zlib.crc32(jpeg), spec.width, spec.height) + jpeg


def incoming_lines(port, seconds):
    deadline = time.monotonic() + seconds
    pending = bytearray()
    while time.monotonic() < deadline:
        pending.extend(port.read_until(b"\n", size=128))
        if pending.endswith(b"\n"):
            yield bytes(pending)
            pending.clear()
        elif len(pending) >= 128:
            pending.clear()


def discover(port) -> CardSpec:
    for line in incoming_lines(port, 4):
        spec = CardSpec.from_line(line)
        if spec is not None:
            return spec
    raise TimeoutError("No DeskIsle greeting. Check the firmware and the native USB data port.")


def send(port, packet: bytes, sequence: int) -> int:
    if port.write(packet) != len(packet):
        raise OSError("Incomplete USB write")
    for line in incoming_lines(port, 3):
        fields = line.split()
        if len(fields) != 4 or fields[0] != b"DESKISLE_ACK" or int(fields[1]) != sequence:
            continue
        status, processing_ms = map(int, fields[2:])
        if status:
            raise RuntimeError(f"DeskIsle rejected frame {sequence}: status {status}")
        return processing_ms
    raise TimeoutError(f"No acknowledgement for packet {sequence}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="Native DeskIsle USB data port")
    parser.add_argument("--count", type=int, help="Number of frames to send, cycling the given images")
    parser.add_argument("jpeg", type=Path, nargs="+", help="Baseline JPEGs at the negotiated size")
    args = parser.parse_args()
    count = args.count if args.count is not None else len(args.jpeg)
    if not 1 <= count <= 10000:
        parser.error("--count must be between 1 and 10000")

    import serial

    images = [path.read_bytes() for path in args.jpeg]
    try:
        with serial.Serial(args.port, 115200, timeout=0.2, write_timeout=2, exclusive=True) as port:
            spec = discover(port)
            print(f"DeskIsle card {spec.slot}: {spec.width}×{spec.height} JPEG")
            started = time.monotonic()
            total_ms = 0
            for sequence in range(1, count + 1):
                jpeg = images[(sequence - 1) % len(images)]
                total_ms += send(port, make_packet(spec, sequence, jpeg), sequence)
            elapsed = time.monotonic() - started
            print(f"{count} frames in {elapsed:.2f}s ({count / elapsed:.1f} fps), "
                  f"board processing {total_ms / count:.1f} ms/frame")
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
